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
    private var spans: [SpeakerSpan] = []
    private var origin: TimeInterval?
    private var fedSeconds: TimeInterval = 0
    private var pendingSeconds: TimeInterval = 0
    private var failed = false
    private var warnedFormat = false

    func start() async {
        do {
            let started = Date()
            diarizer = try await LSEENDDiarizer(variant: .dihard2)
            log("Sprechertrennung bereit nach \(Int(Date().timeIntervalSince(started)))s.")
        } catch {
            failed = true
            log("Sprechertrennung nicht verfuegbar, Spur bleibt ungetrennt: \(error.localizedDescription)")
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer, at offset: TimeInterval) {
        guard let diarizer, !failed else { return }
        guard let channels = buffer.floatChannelData, buffer.format.commonFormat == .pcmFormatFloat32 else {
            if !warnedFormat {
                warnedFormat = true
                log("Sprechertrennung: Format \(buffer.format) wird nicht unterstuetzt.")
            }
            return
        }
        let rate = buffer.format.sampleRate
        let frames = Int(buffer.frameLength)
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
        let gap = offset - (origin ?? offset) - fedSeconds
        do {
            if gap > 0.25 {
                let silence = min(gap, 30)
                try diarizer.addAudio([Float](repeating: 0, count: Int(silence * rate)), sourceSampleRate: rate)
                fedSeconds += silence
            }
            try diarizer.addAudio(mono, sourceSampleRate: rate)
            let seconds = Double(frames) / rate
            fedSeconds += seconds
            pendingSeconds += seconds
            if pendingSeconds >= 0.5 {
                pendingSeconds = 0
                if let update = try diarizer.process() { collect(update) }
            }
        } catch {
            failed = true
            log("Sprechertrennung abgebrochen: \(error.localizedDescription)")
        }
    }

    func finish() -> [SpeakerSpan] {
        if let diarizer, !failed, let update = try? diarizer.finalizeSession() { collect(update) }
        diarizer = nil
        let speakers = Set(spans.map(\.speaker)).count
        log("Sprechertrennung: \(speakers) Sprecher, \(spans.count) Abschnitte.")
        return spans
    }

    func current() -> [SpeakerSpan] { spans }

    private func collect(_ update: DiarizerTimelineUpdate) {
        let base = origin ?? 0
        for segment in update.finalizedSegments {
            let span = SpeakerSpan(speaker: segment.speakerIndex,
                                   start: base + Double(segment.startTime),
                                   end: base + Double(segment.endTime))
            spans.append(span)
            activeSink?.append(span: span)
        }
    }
}

enum Speakers {
    static func name(_ segment: Segment, me: String = "Ich", others: String = "Andere") -> String {
        if segment.track == .mic { return me }
        return segment.speaker.map { "Sprecher \($0)" } ?? others
    }

    static func label(_ segments: [Segment], spans: [SpeakerSpan]) -> [Segment] {
        guard !spans.isEmpty else { return segments }
        var numbering: [Int: Int] = [:]
        return segments.map { segment in
            guard segment.track == .system else { return segment }
            var overlap: [Int: TimeInterval] = [:]
            for span in spans {
                let shared = min(span.end, segment.end) - max(span.start, segment.start)
                if shared > 0 { overlap[span.speaker, default: 0] += shared }
            }
            guard let best = overlap.max(by: { $0.value < $1.value })?.key else { return segment }
            if numbering[best] == nil { numbering[best] = numbering.count + 1 }
            var labelled = segment
            labelled.speaker = numbering[best]
            return labelled
        }
    }
}
