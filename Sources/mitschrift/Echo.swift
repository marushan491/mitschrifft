import Foundation

enum Echo {
    static let window: TimeInterval = 4
    static let minimumKeptWords = 3
    static let echoShareForDrop = 0.6
    static let loudspeakerWindow: TimeInterval = 300
    static let loudspeakerShare = 0.5
    static let loudspeakerMinimum = 4

    static func removeMicEcho(_ segments: [Segment]) -> [Segment] {
        let system = segments.filter { $0.track == .system }
        guard !system.isEmpty else { return segments }
        let checks: [(share: Double, reference: String)?] = segments.map { segment in
            guard segment.track == .mic else { return nil }
            let reference = system.filter {
                $0.end >= segment.start - window && $0.start <= segment.end + window
            }.map(\.text).joined(separator: " ")
            return (share(segment.text, against: reference), reference)
        }
        let mic = zip(segments, checks).compactMap { segment, check in
            check.map { (start: segment.start, share: $0.share) }
        }
        return zip(segments, checks).compactMap { segment, check in
            guard let check else { return segment }
            let around = mic.filter { abs($0.start - segment.start) <= loudspeakerWindow }
            let echoes = around.filter { $0.share >= echoShareForDrop }.count
            let loudspeaker = around.count >= loudspeakerMinimum
                && Double(echoes) / Double(around.count) >= loudspeakerShare
            if loudspeaker, check.share >= echoShareForDrop { return nil }
            guard let text = strip(segment.text, against: check.reference) else { return nil }
            return Segment(track: .mic, start: segment.start, end: segment.end, text: text,
                           speaker: segment.speaker, uncertain: segment.uncertain || loudspeaker)
        }
    }

    static func share(_ text: String, against reference: String) -> Double {
        let keys = words(text).map(normalize)
        let referenceKeys = words(reference).map(normalize)
        guard !keys.isEmpty, !referenceKeys.isEmpty else { return 0 }
        if keys.count == 1 { return referenceKeys.contains(keys[0]) ? 1 : 0 }
        return Double(marks(keys, against: referenceKeys).filter { $0 }.count) / Double(keys.count)
    }

    static func strip(_ text: String, against reference: String) -> String? {
        let tokens = words(text)
        let keys = tokens.map(normalize)
        let referenceKeys = words(reference).map(normalize)
        guard keys.count > 1, referenceKeys.count > 1 else { return text }
        let echoed = marks(keys, against: referenceKeys)
        guard echoed.contains(true) else { return text }
        if Double(echoed.filter { $0 }.count) / Double(tokens.count) >= echoShareForDrop { return nil }

        var kept: [String] = []
        var run: [String] = []
        func close() {
            if run.count >= minimumKeptWords { kept.append(run.joined(separator: " ")) }
            run = []
        }
        for (word, isEcho) in zip(tokens, echoed) {
            if isEcho { close() } else { run.append(word) }
        }
        close()
        return kept.isEmpty ? nil : kept.joined(separator: " … ")
    }

    static func normalize(_ word: String) -> String {
        word.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "de_DE"))
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init).filter { !normalize($0).isEmpty }
    }

    private static func marks(_ keys: [String], against referenceKeys: [String]) -> [Bool] {
        var echoed = Array(repeating: false, count: keys.count)
        guard keys.count > 1, referenceKeys.count > 1 else { return echoed }
        let pairs = Set(zip(referenceKeys, referenceKeys.dropFirst()).map { "\($0) \($1)" })
        for index in 0..<(keys.count - 1) where pairs.contains("\(keys[index]) \(keys[index + 1])") {
            echoed[index] = true
            echoed[index + 1] = true
        }
        return echoed
    }
}
