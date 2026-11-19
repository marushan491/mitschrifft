import AVFoundation
import FluidAudio
import Foundation

struct SpeakerSpan: Sendable, Equatable {
    let speaker: Int
    let start: TimeInterval
    let end: TimeInterval
}

actor SpeakerTracker {
    private var diarizer: LSEENDDiarizer?
    private var diarizerConverter: AudioConverter?
    private var spans: [SpeakerSpan] = []
    private var origin: TimeInterval?
    private var fedFrames = 0
    private var pendingSeconds: TimeInterval = 0
    private var failed = false
    private var warnedFormat = false
    private var finished = false
    private var voiceSampling = VoiceSampling()
    private let voiceExtractor = VoiceEmbeddingExtractor.shared
    private var voiceTask: Task<Void, Never>?
    private var voiceFailed = false

    func start() async {
        guard !finished else { return }
        do {
            let started = Date()
            let model = try await LSEENDDiarizer(variant: .dihard2)
            guard !finished else { return }
            if let rate = model.targetSampleRate {
                diarizerConverter = AudioConverter(sampleRate: Double(rate))
            }
            diarizer = model
            log("Sprechertrennung bereit nach \(Int(Date().timeIntervalSince(started)))s.")
        } catch {
            failed = true
            log("Sprechertrennung nicht verfuegbar, Spur bleibt ungetrennt: \(error.localizedDescription)")
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer, at offset: TimeInterval) {
        guard let diarizer, let diarizerConverter, let targetRate = diarizer.targetSampleRate,
              !failed else { return }
        guard let channels = buffer.floatChannelData, buffer.format.commonFormat == .pcmFormatFloat32 else {
            if !warnedFormat {
                warnedFormat = true
                log("Sprechertrennung: Format \(buffer.format) wird nicht unterstuetzt.")
            }
            return
        }
        let rate = buffer.format.sampleRate
        let frames = Int(buffer.frameLength)
        guard rate.isFinite, rate >= 1, frames > 0 else { return }
        let count = Int(buffer.format.channelCount)
        let interleaved = buffer.format.isInterleaved
        var mono = [Float](repeating: 0, count: frames)
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<count {
                sum += interleaved ? channels[0][frame * count + channel] : channels[channel][frame]
            }
            mono[frame] = sum / Float(max(count, 1))
        }

        if origin == nil { origin = offset }
        let diarizerRate = Double(targetRate)
        let gap = offset - (origin ?? offset) - Double(fedFrames) / diarizerRate
        do {
            if gap > 0.25 {
                let silenceFrames = Int(min(gap, 30) * diarizerRate)
                try diarizer.addAudio([Float](repeating: 0, count: silenceFrames))
                fedFrames += silenceFrames
            }
            let diarizerSamples = try diarizerConverter.resample(mono, from: rate)
            try diarizer.addAudio(diarizerSamples)
            let diarizerStart = Double(fedFrames) / diarizerRate
            fedFrames += diarizerSamples.count
            if !voiceFailed {
                voiceSampling.append(mono, sampleRate: rate, at: diarizerStart,
                                     until: Double(fedFrames) / diarizerRate, captureTime: offset)
            }
            let seconds = Double(frames) / rate
            pendingSeconds += seconds
            if pendingSeconds >= 0.5 {
                pendingSeconds = 0
                if let update = try diarizer.process() { collect(update, from: diarizer) }
            }
        } catch {
            failed = true
            log("Sprechertrennung abgebrochen: \(error.localizedDescription)")
        }
    }

    func finish() -> [SpeakerSpan] {
        if !finished {
            finished = true
            if let diarizer, !failed, let update = try? diarizer.finalizeSession() {
                collect(update, from: diarizer)
            }
            diarizer = nil
            let speakers = Set(spans.map(\.speaker)).count
            log("Sprechertrennung: \(speakers) Sprecher, \(spans.count) Abschnitte.")
        }
        voiceSampling.discardAudio()
        return spans
    }

    func current() -> [SpeakerSpan] { spans }

    func voiceReferences() async -> [Int: [[Float]]] {
        if finished { await voiceTask?.value }
        return voiceSampling.references
    }

    private func collect(_ update: DiarizerTimelineUpdate, from diarizer: LSEENDDiarizer) {
        let base = origin ?? 0
        for segment in update.finalizedSegments {
            let span = SpeakerSpan(speaker: segment.speakerIndex,
                                   start: base + Double(segment.startTime),
                                   end: base + Double(segment.endTime))
            spans.append(span)
            activeSink?.append(span: span)
        }
        guard !voiceFailed, let targetRate = diarizer.targetSampleRate else { return }
        let rate = Double(targetRate)
        let frameDuration = Double(diarizer.timeline.config.frameDurationSeconds)
        voiceSampling.update(update, frameDuration: (frameDuration * rate).rounded() / rate)
        if voiceTask == nil, let candidate = voiceSampling.takeCandidate() {
            voiceTask = Task(priority: .utility) { await extractReferences(startingWith: candidate) }
        }
    }

    private func extractReferences(startingWith first: VoiceSampling.Candidate) async {
        defer { voiceTask = nil }
        var candidate: VoiceSampling.Candidate? = first
        do {
            while let current = candidate {
                if let embedding = try await voiceExtractor.embedding(for: current) {
                    voiceSampling.store(embedding, for: current)
                }
                candidate = voiceSampling.takeCandidate()
            }
        } catch {
            voiceFailed = true
            voiceSampling.discardAudio()
            log("Stimmreferenzen nicht verfügbar: \(error.localizedDescription)")
        }
    }
}

enum Speakers {
    static let uncertainMic = "Mikrofon (unsicher)"

    static func name(_ segment: Segment, me: String = "Ich", others: String = "Andere") -> String {
        if segment.track == .mic { return segment.uncertain ? uncertainMic : me }
        if let name = segment.speakerName { return name }
        let label = segment.speaker.map { "Sprecher \($0)" } ?? others
        return segment.speakerNameUncertain ? label + " ?" : label
    }

    static func label(_ segments: [Segment], spans: [SpeakerSpan]) -> [Segment] {
        var labelled = segments
        assignNumbers(segments, spans: spans) { index, raw, speaker, overlapping in
            labelled[index].rawSpeaker = raw
            labelled[index].speaker = speaker
            if let overlapping { labelled[index].overlappingSpeakers = overlapping }
        }
        return labelled
    }

    static func numbering(_ segments: [Segment], spans: [SpeakerSpan]) -> [Int: Int] {
        assignNumbers(segments, spans: spans)
    }

    @discardableResult
    private static func assignNumbers(_ segments: [Segment], spans: [SpeakerSpan],
                                      assign: ((Int, Int, Int, Bool?) -> Void)? = nil) -> [Int: Int] {
        guard !spans.isEmpty else { return [:] }
        var numbering: [Int: Int] = [:]
        for (index, segment) in segments.enumerated() where segment.track == .system {
            var overlap: [Int: TimeInterval] = [:]
            for span in spans {
                let shared = min(span.end, segment.end) - max(span.start, segment.start)
                if shared > 0 { overlap[span.speaker, default: 0] += shared }
            }
            let ranked = overlap.sorted {
                $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
            }
            guard let strongest = ranked.first else { continue }
            let best = strongest.key
            let speaker = numbering[best] ?? numbering.count + 1
            numbering[best] = speaker
            let overlapping = ranked.dropFirst().first.map {
                $0.value >= 0.25 && $0.value >= strongest.value * 0.30
            }
            assign?(index, best, speaker, overlapping)
        }
        return numbering
    }
}
