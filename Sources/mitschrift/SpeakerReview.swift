import Foundation

struct SpeakerIdentity: Equatable, Sendable {
    enum Source: Equatable, Sendable { case teams, manual, profile, transcript }

    let name: String
    let source: Source
    var similarity: Float?
    var quote: String?

    var confirmed: Bool { source == .teams || source == .manual }

    static func validName(_ value: String) -> String? {
        let name = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard (2...80).contains(name.count),
              !name.contains(where: { "[]|*#<>".contains($0) || $0.isNewline }),
              name.contains(where: \.isLetter) else { return nil }
        return name
    }
}

struct SpeakerReviewRow: Identifiable, Equatable, Sendable {
    let id: Int
    let number: Int
    let identity: SpeakerIdentity?
    let conflictingCaptions: Bool
    let sampleCount: Int

    var title: String { id == -1 ? "Ich" : "Sprecher \(number)" }
}

struct SpeakerReviewResponse: Sendable {
    let message: String?
    var profiles: [SpeakerProfile]?

    static let done = Self(message: nil)
}

enum SpeakerReviewAction: Sendable {
    case confirm(recording: String, speaker: Int, name: String)
    case merge(recording: String, speaker: Int, into: Int)
    case remember(recording: String, speaker: Int, name: String, consent: Date)
    case suggest(recording: String)
    case profiles
    case delete(UUID)
}

struct SpeakerReview: Sendable {
    var manual: [Int: String] = [:]
    var aliases: [Int: Int] = [:]
    var profileMatches: [Int: SpeakerProfileMatch] = [:]
    var suggestions: [Int: SpeakerIdentity] = [:]
    var sampleCounts: [Int: Int] = [:]

    func representative(_ raw: Int) -> Int {
        var current = raw
        while let next = aliases[current] { current = next }
        return current
    }

    func apply(to segments: [Segment]) -> [Segment] {
        let numbers = displayNumbers(in: segments)
        let captions = captionNames(in: segments)
        return segments.map { segment in
            var segment = segment
            guard segment.track == .system, let raw = segment.rawSpeaker else { return segment }
            let group = representative(raw)
            if let number = numbers[group] { segment.speaker = number }
            if !segment.overlappingSpeakers, let name = manual[group] {
                segment.speakerName = name
                segment.speakerIdentity = SpeakerIdentity(name: name, source: .manual)
            } else if let name = segment.speakerName {
                segment.speakerIdentity = SpeakerIdentity(name: name, source: .teams)
            } else if !segment.overlappingSpeakers, captions[group, default: []].isEmpty {
                segment.speakerIdentity = identity(for: raw)
            }
            segment.speakerNameUncertain = segment.speakerName == nil
            return segment
        }
    }

    func rows(for segments: [Segment]) -> [SpeakerReviewRow] {
        let captions = captionNames(in: segments)
        let numbers = displayNumbers(in: segments)
        let mic = segments.contains(where: { $0.track == .mic && !$0.uncertain })
            ? [SpeakerReviewRow(id: -1, number: 0, identity: SpeakerIdentity(name: "Ich", source: .manual),
                                conflictingCaptions: false, sampleCount: sampleCounts[-1, default: 0])]
            : []
        return mic + numbers.sorted(by: { $0.value < $1.value }).map { raw, number in
            let names = captions[raw, default: []]
            let confirmation = manual[raw].map { SpeakerIdentity(name: $0, source: .manual) }
            let identity = confirmation ?? (names.count == 1 ? names.first.map {
                SpeakerIdentity(name: $0, source: .teams)
            } : nil) ?? (names.isEmpty ? self.identity(for: raw) : nil)
            return SpeakerReviewRow(id: raw, number: number, identity: identity,
                                    conflictingCaptions: confirmation == nil && names.count > 1,
                                    sampleCount: sampleCounts[raw, default: 0])
        }
    }

    private func identity(for raw: Int) -> SpeakerIdentity? {
        let group = representative(raw)
        if let match = profileMatches[raw] {
            return SpeakerIdentity(name: match.name, source: .profile, similarity: match.similarity)
        }
        return suggestions[group]
    }

    private func captionNames(in segments: [Segment]) -> [Int: Set<String>] {
        var names: [Int: Set<String>] = [:]
        for segment in segments where segment.track == .system {
            guard let index = segment.rawSpeaker, let name = segment.speakerName,
                  segment.speakerIdentity?.source != .manual else { continue }
            names[representative(index), default: []].insert(name)
        }
        return names
    }

    private func displayNumbers(in segments: [Segment]) -> [Int: Int] {
        var numbers: [Int: Int] = [:]
        for segment in segments {
            guard let raw = segment.rawSpeaker, let number = segment.speaker else { continue }
            let group = representative(raw)
            if raw == group || numbers[group] == nil { numbers[group] = number }
        }
        return numbers
    }
}
