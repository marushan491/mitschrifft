import Foundation

enum Echo {
    static let window: TimeInterval = 4
    static let minimumKeptWords = 3
    static let echoShareForDrop = 0.6

    static func removeMicEcho(_ segments: [Segment]) -> [Segment] {
        let system = segments.filter { $0.track == .system }
        guard !system.isEmpty else { return segments }
        return segments.compactMap { segment in
            guard segment.track == .mic else { return segment }
            let nearby = system.filter {
                $0.end >= segment.start - window && $0.start <= segment.end + window
            }
            guard let text = strip(segment.text, against: nearby.map(\.text).joined(separator: " ")) else {
                return nil
            }
            return Segment(track: .mic, start: segment.start, end: segment.end, text: text, speaker: segment.speaker)
        }
    }

    static func strip(_ text: String, against reference: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init).filter { !normalize($0).isEmpty }
        let keys = words.map(normalize)
        let referenceKeys = reference.split(whereSeparator: \.isWhitespace).map { normalize(String($0)) }.filter { !$0.isEmpty }
        guard keys.count > 1, referenceKeys.count > 1 else { return text }
        let pairs = Set(zip(referenceKeys, referenceKeys.dropFirst()).map { "\($0) \($1)" })
        var echoed = Array(repeating: false, count: words.count)
        for index in 0..<(keys.count - 1) where pairs.contains("\(keys[index]) \(keys[index + 1])") {
            echoed[index] = true
            echoed[index + 1] = true
        }
        guard echoed.contains(true) else { return text }
        if Double(echoed.filter { $0 }.count) / Double(words.count) >= echoShareForDrop { return nil }

        var kept: [String] = []
        var run: [String] = []
        func close() {
            if run.count >= minimumKeptWords { kept.append(run.joined(separator: " ")) }
            run = []
        }
        for (word, isEcho) in zip(words, echoed) {
            if isEcho { close() } else { run.append(word) }
        }
        close()
        return kept.isEmpty ? nil : kept.joined(separator: " … ")
    }

    static func normalize(_ word: String) -> String {
        word.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "de_DE"))
            .filter { $0.isLetter || $0.isNumber }
    }
}
