import Foundation

struct WindowSpeakerAttribution {
    private struct Observation {
        let at: TimeInterval
        let names: Set<String>
    }

    private struct Attribution {
        let speaker: Int
        let name: String
    }

    private var recent: [Observation] = []
    private var attributed: [SpeakerAttribution.Range: Attribution] = [:]

    mutating func observe(_ names: Set<String>, at: TimeInterval) {
        guard at.isFinite, at >= 0 else { return }
        recent.removeAll { at - $0.at > 45 }
        if !names.isEmpty { recent.append(Observation(at: at, names: names)) }
    }

    mutating func match(_ segments: [Segment], spans: [SpeakerSpan]) {
        guard !recent.isEmpty else { return }
        for segment in segments where segment.track == .system {
            let key = SpeakerAttribution.Range(segment)
            guard let raw = segment.rawSpeaker, !segment.overlappingSpeakers else {
                attributed[key] = nil
                continue
            }
            let candidates = recent.filter { sample in
                guard sample.at >= segment.start, sample.at <= segment.end else { return false }
                let inSpan = spans.filter { $0.start <= sample.at && sample.at < $0.end }
                return !inSpan.isEmpty && inSpan.allSatisfy { $0.speaker == raw }
            }
            guard !candidates.isEmpty else { continue }
            let unambiguous = Set(candidates.filter { $0.names.count == 1 }.compactMap { $0.names.first })
            if unambiguous.count == 1, let name = unambiguous.first,
               candidates.allSatisfy({ $0.names.contains(name) }) {
                attributed[key] = Attribution(speaker: raw, name: name)
            } else {
                attributed[key] = nil
            }
        }
    }

    func apply(to segments: [Segment]) -> [Segment] {
        segments.map { segment in
            guard segment.track == .system, segment.speakerName == nil, !segment.overlappingSpeakers,
                  let match = attributed[SpeakerAttribution.Range(segment)], match.speaker == segment.rawSpeaker else {
                return segment
            }
            var hint = segment
            hint.speakerIdentity = SpeakerIdentity(name: match.name, source: .window)
            return hint
        }
    }
}
