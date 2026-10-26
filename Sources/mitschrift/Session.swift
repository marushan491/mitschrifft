import AVFoundation
import CoreMedia
import Foundation

struct SessionResult: Sendable {
    let startedAt: Date
    let endedAt: Date
    let segments: [Segment]

    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
}

actor RecordingSession {
    private let locale: Locale
    private var mic: TrackTranscriber?
    private var system: TrackTranscriber?
    private var tap: AudioTap?
    private var origin: CMTime?
    private var startedAt = Date()
    private var micFrames = 0
    private var systemFrames = 0
    private var feeder: AsyncStream<TappedBuffer>.Continuation?
    private var pump: Task<Void, Never>?
    private var seenFormats: Set<String> = []
    private var micRate = 48_000.0
    private var systemRate = 48_000.0
    private var streamStopped = false
    private let speakers = SpeakerTracker()

    init(locale: Locale) {
        self.locale = locale
    }

    func start() async throws {
        startedAt = Date()
        mic = try await TrackTranscriber(track: .mic, locale: locale)
        system = try await TrackTranscriber(track: .system, locale: locale)
        Task { [speakers] in await speakers.start() }

        let (queued, continuation) = AsyncStream<TappedBuffer>.makeStream(bufferingPolicy: .unbounded)
        feeder = continuation
        pump = Task { [weak self] in
            for await tapped in queued {
                await self?.handle(tapped)
            }
        }

        let tap = AudioTap(
            sink: { [continuation] tapped in
                continuation.yield(tapped)
            },
            onStop: { error in
                log("Audio-Stream gestoppt: \(error.localizedDescription)")
                Task { await self.markStreamStopped() }
            }
        )
        self.tap = tap
        try await tap.start()
    }

    private func handle(_ tapped: TappedBuffer) async {
        if origin == nil { origin = tapped.hostTime }
        let base = origin ?? tapped.hostTime
        let relative = CMTimeSubtract(tapped.hostTime, base)
        let offset = relative.isValid && relative.seconds >= 0 ? relative : CMTime.zero

        let shape = "\(tapped.track.rawValue) \(Int(tapped.buffer.format.sampleRate))Hz \(tapped.buffer.format.channelCount)ch"
        if seenFormats.insert(shape).inserted {
            log("Tonspur da: \(shape), \(tapped.buffer.frameLength) Rahmen pro Paket")
            if tapped.track == .mic { micRate = tapped.buffer.format.sampleRate }
            else { systemRate = tapped.buffer.format.sampleRate }
        }

        switch tapped.track {
        case .mic:
            micFrames += Int(tapped.buffer.frameLength)
            await mic?.feed(tapped.buffer, at: offset)
        case .system:
            systemFrames += Int(tapped.buffer.frameLength)
            await system?.feed(tapped.buffer, at: offset)
            await speakers.feed(tapped.buffer, at: offset.seconds)
        }
    }

    func resultCount() async -> Int {
        let a = await mic?.report().results ?? 0
        let b = await system?.report().results ?? 0
        return a + b
    }

    func frameCounts() -> (mic: Int, system: Int) {
        (micFrames, systemFrames)
    }

    private func markStreamStopped() { streamStopped = true }

    func assistantSnapshot() async -> AssistantSnapshot {
        let segments = (await mic?.currentSegments() ?? []) + (await system?.currentSegments() ?? [])
        let labelled = Speakers.label(segments.sorted { $0.start < $1.start }, spans: await speakers.current())
        return AssistantSnapshot(segments: Echo.removeMicEcho(labelled),
                                 elapsed: Date().timeIntervalSince(startedAt),
                                 recording: true, startedAt: startedAt)
    }

    func healthLine() async -> String {
        let micReport = await mic?.report() ?? (fed: 0, dropped: 0, results: 0, alive: false)
        let sysReport = await system?.report() ?? (fed: 0, dropped: 0, results: 0, alive: false)
        return "Mikro \(Int(Double(micFrames) / micRate))s/\(micReport.results) Ergebnisse\(micReport.alive ? "" : ", SPUR TOT")"
            + ", System \(Int(Double(systemFrames) / systemRate))s/\(sysReport.results) Ergebnisse\(sysReport.alive ? "" : ", SPUR TOT")"
            + (micReport.dropped + sysReport.dropped > 0
               ? ", verworfen \(micReport.dropped + sysReport.dropped)" : "")
    }

    func finish(timeout: Int) async -> SessionResult {
        await tap?.stop()
        tap = nil

        feeder?.finish()
        feeder = nil
        await pump?.value
        pump = nil

        var segments: [Segment] = []
        if let mic { segments += await mic.finish(timeout: timeout) }
        if let system { segments += await system.finish(timeout: timeout) }
        self.mic = nil
        self.system = nil

        log("Aufnahme abgeschlossen: Mikro \(Int(Double(micFrames) / micRate))s, System \(Int(Double(systemFrames) / systemRate))s, \(segments.count) Textstuecke.")

        segments.sort { $0.start < $1.start }
        segments = Speakers.label(segments, spans: await speakers.finish())
        return SessionResult(startedAt: startedAt, endedAt: Date(), segments: segments)
    }
}
