import Foundation

struct TeamsCaption: Hashable, Sendable {
    let name: String
    let text: String

    init?(name: String, text: String) {
        guard let name = Self.personName(name), text.count <= 1000,
              Set(Self.words(text)).count >= 4 else { return nil }
        self.name = name
        self.text = text
    }

    static func personName(_ value: String) -> String? {
        let name = value.replacingOccurrences(of: "\u{200e}", with: "")
            .replacingOccurrences(of: "\u{200f}", with: "")
            .replacingOccurrences(of: #"\s*\((?:Gast|Guest|Extern|External)\)\s*$"#,
                                  with: "", options: [.regularExpression, .caseInsensitive])
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let parts = name.split(separator: " ")
        guard (2...5).contains(parts.count), name.count <= 80,
              parts.allSatisfy({ part in
                  (part.first?.isUppercase == true || ["von", "van", "de", "der", "da", "del"].contains(String(part))) &&
                      part.allSatisfy { $0.isLetter || "-’'.".contains($0) }
              }),
              !parts.contains(where: { ["speaker", "sprecher", "participant", "teilnehmer", "anonymous",
                                        "anonym", "unbekannt", "unknown", "teams"].contains($0.lowercased()) })
        else { return nil }
        return name
    }

    static func words(_ text: String) -> [Substring] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
    }
}

struct SpeakerAttribution {
    struct Range: Hashable {
        let start: TimeInterval
        let end: TimeInterval

        init(_ segment: Segment) {
            self.init(start: segment.start, end: segment.end)
        }

        init(start: TimeInterval, end: TimeInterval) {
            self.start = start
            self.end = end
        }
    }

    private struct Observation {
        let caption: TeamsCaption
        let at: TimeInterval
        let words: Set<Substring>
        let phrases: Set<[Substring]>
    }

    private var visible: Set<TeamsCaption> = []
    private var recent: [Observation] = []
    private var names: [Range: Set<String>] = [:]

    mutating func observe(_ captions: [TeamsCaption]?, at: TimeInterval) {
        recent.removeAll { at - $0.at > 35 }
        guard let captions else { return }
        let next = Set(captions)
        for caption in next.subtracting(visible) {
            let words = TeamsCaption.words(caption.text)
            recent.append(Observation(caption: caption, at: at, words: Set(words), phrases: Self.phrases(words)))
        }
        visible = next
    }

    @discardableResult
    mutating func add(_ name: String, at range: Range) -> Bool {
        names[range, default: []].insert(name).inserted
    }

    mutating func match(_ segments: [Segment], at now: TimeInterval, sink: SegmentSink?) {
        guard !recent.isEmpty else { return }
        for segment in segments.reversed() where segment.track == .system && segment.end >= now - 52 {
            let tokens = TeamsCaption.words(segment.text)
            let words = Set(tokens)
            guard words.count >= 4 else { continue }
            let phrases = Self.phrases(tokens)
            for item in recent where (-2...14).contains(item.at - segment.end) {
                let common = words.intersection(item.words).count
                guard common >= 4, Double(common) >= 0.80 * Double(max(words.count, item.words.count)),
                      !phrases.isDisjoint(with: item.phrases) else { continue }
                let range = Range(segment)
                if add(item.caption.name, at: range) {
                    sink?.appendSpeakerName(item.caption.name, start: range.start, end: range.end)
                }
            }
        }
    }

    func apply(to segments: [Segment]) -> [Segment] {
        segments.map { segment in
            guard segment.track == .system else { return segment }
            var result = segment
            if !segment.overlappingSpeakers, let matches = names[Range(segment)], matches.count == 1 {
                result.speakerName = matches.first
            } else {
                result.speakerNameUncertain = true
            }
            return result
        }
    }

    private static func phrases(_ words: [Substring]) -> Set<[Substring]> {
        guard words.count >= 4 else { return [] }
        return Set((0...words.count - 4).map { Array(words[$0..<$0 + 4]) })
    }
}
