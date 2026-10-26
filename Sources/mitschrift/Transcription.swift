import AVFoundation
import CoreMedia
import Foundation
import Speech

enum MitschriftError: LocalizedError {
    case noDisplay
    case localeUnsupported(String)
    case noCompatibleFormat
    case converterFailed

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "Kein Display gefunden, ScreenCaptureKit kann keinen Filter bauen."
        case .localeUnsupported(let id):
            return "Sprache \(id) wird von der lokalen Spracherkennung nicht unterstuetzt."
        case .noCompatibleFormat:
            return "Kein kompatibles Audioformat fuer die Spracherkennung verfuegbar."
        case .converterFailed:
            return "Audioformat konnte nicht konvertiert werden."
        }
    }
}

struct Segment: Sendable {
    let track: Track
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    var speaker: Int? = nil
}

final class SegmentStore: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Segment] = []

    func add(_ segment: Segment) { lock.withLock { items.append(segment) } }
    func all() -> [Segment] { lock.withLock { items } }
}

final class ResultCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    private var living = true

    var count: Int { lock.withLock { value } }
    var alive: Bool { lock.withLock { living } }

    func bump() { lock.withLock { value += 1 } }
    func die() { lock.withLock { living = false } }
    func close() { lock.withLock { living = false } }
}

actor TrackTranscriber {
    private let track: Track
    private let analyzer: SpeechAnalyzer
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let analyzerFormat: AVAudioFormat
    private var converters: [String: AVAudioConverter] = [:]
    private var collector: Task<[Segment], Never>?
    private var nextAllowedStart: CMTime = .zero
    private var fed = 0
    private var dropped = 0
    private let counter = ResultCounter()
    private let store = SegmentStore()

    static func locale(for identifier: String) async throws -> Locale {
        let wanted = Locale(identifier: identifier)
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) {
            return match
        }
        throw MitschriftError.localeUnsupported(identifier)
    }

    static func ensureModelInstalled(locale: Locale) async throws {
        let probe = SpeechTranscriber(locale: locale, preset: .transcription)
        let installed = await SpeechTranscriber.installedLocales
        let ready = installed.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
        if ready { return }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            log("Lade Sprachmodell fuer \(locale.identifier(.bcp47)) herunter ...")
            try await request.downloadAndInstall()
            log("Sprachmodell installiert.")
        }
    }

    init(track: Track, locale: Locale) async throws {
        self.track = track

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )

        guard let format = await transcriber.availableCompatibleAudioFormats.first else {
            throw MitschriftError.noCompatibleFormat
        }
        self.analyzerFormat = format

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation
        self.analyzer = SpeechAnalyzer(
            inputSequence: stream,
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .whileInUse)
        )

        let capturedTrack = track
        let results = transcriber.results
        let counter = self.counter
        let store = self.store
        self.collector = Task {
            var segments: [Segment] = []
            do {
                for try await result in results {
                    counter.bump()
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let segment = Segment(
                        track: capturedTrack,
                        start: result.range.start.seconds,
                        end: result.range.end.seconds,
                        text: text
                    )
                    segments.append(segment)
                    store.add(segment)
                    activeSink?.append(segment)
                    liveLog(segment)
                }
            } catch {
                counter.die()
                log("Spur \(capturedTrack.rawValue) ABGEBROCHEN: \(error.localizedDescription)")
            }
            counter.close()
            return segments
        }
    }

    func report() -> (fed: Int, dropped: Int, results: Int, alive: Bool) {
        (fed, dropped, counter.count, counter.alive)
    }

    func currentSegments() -> [Segment] { store.all() }

    func feed(_ buffer: AVAudioPCMBuffer, at time: CMTime) {
        guard let converted = convert(buffer), converted.frameLength > 0 else {
            dropped += 1
            return
        }
        fed += 1

        let requested = time.isValid && time.seconds > nextAllowedStart.seconds ? time : nextAllowedStart
        let duration = CMTime(value: CMTimeValue(converted.frameLength),
                              timescale: CMTimeScale(analyzerFormat.sampleRate))
        nextAllowedStart = CMTimeAdd(requested, duration)

        continuation.yield(AnalyzerInput(buffer: converted, bufferStartTime: requested))
    }

    func finish(timeout: Int) async -> [Segment] {
        continuation.finish()

        let analyzer = self.analyzer
        let closed = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                try? await analyzer.finalizeAndFinishThroughEndOfInput()
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        if !closed {
            log("Spur \(track.rawValue): Abschluss ueberschritt \(timeout)s, nehme das bereits Erkannte.")
        }
        collector?.cancel()
        collector = nil
        return store.all()
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let source = buffer.format
        if source == analyzerFormat { return buffer }

        let key = "\(source.sampleRate)-\(source.channelCount)-\(source.commonFormat.rawValue)"
        let converter: AVAudioConverter
        if let existing = converters[key] {
            converter = existing
        } else {
            guard let made = AVAudioConverter(from: source, to: analyzerFormat) else { return nil }
            made.downmix = true
            converters[key] = made
            converter = made
        }

        let ratio = analyzerFormat.sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 2048
        guard let output = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return nil }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if status == .error || output.frameLength == 0 { return nil }
        return output
    }
}
