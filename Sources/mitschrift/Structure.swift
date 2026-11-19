import Foundation

struct Structure {
    let config: Config

    private var queueDirectory: URL {
        Config.stateDirectory.appendingPathComponent("queue")
    }

    static func uniqueLines(_ texts: [String], limit: Int = 12_000) -> String {
        var seen = Set<String>()
        var lines: [String] = []
        for line in texts.joined(separator: "\n").split(separator: "\n") {
            let clean = line.trimmingCharacters(in: .whitespaces)
            if clean.count > 1, seen.insert(clean).inserted { lines.append(clean) }
        }
        return String(lines.joined(separator: "\n").prefix(limit))
    }

    static func localParticipantHints(_ screen: String, knownNames: [String]) -> [String] {
        let lines = screen.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let normalize: (String) -> String = { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let visible = Set(lines.map(normalize))
        var names = knownNames.filter { visible.contains(normalize($0)) }
        let headings = ["teilnehmer", "participants", "personen", "people", "in dieser besprechung", "in this meeting"]
        if let start = lines.firstIndex(where: { line in
            let title = normalize(line).split(separator: "(").first?.trimmingCharacters(in: .whitespaces) ?? ""
            return headings.contains(title)
        }) {
            for line in lines.dropFirst(start + 1).prefix(40) {
                guard let name = TeamsCaption.personName(line) else {
                    if line.count > 50 { break }
                    continue
                }
                names.append(name)
            }
        }
        return Array(Set(names).sorted().prefix(50))
    }

    func speakerSuggestions(evidence: [Int: String], screen: String, meeting: String?, apps: [String]) throws
        -> [Int: SpeakerIdentity] {
        struct Suggestion: Decodable {
            let speaker: Int
            let name: String
            let quote: String
        }
        struct Result: Decodable { var suggestions: [Suggestion]? }

        guard config.structureEnabled else { throw CodexError.failed("Die Codex-Auswertung ist ausgeschaltet.") }
        let selected = evidence.sorted(by: { $0.key < $1.key }).prefix(8)
        let excerpts = Dictionary(uniqueKeysWithValues: selected.map { (String($0.key), $0.value) })
        guard !excerpts.isEmpty else { return [:] }
        let request: [String: Any] = [
            "mode": "participants", "speakerEvidence": excerpts,
            "screen": screen, "meeting": meeting ?? "unbekannt", "apps": apps.joined(separator: ", "),
            "ai": config.ai
        ]
        let payload = try JSONSerialization.data(withJSONObject: request)
        let reply = try ask(payload: payload).answer
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end else {
            throw CodexError.failed("Sprechervorschläge sind nicht lesbar.")
        }
        let result = try JSONDecoder().decode(Result.self, from: Data(reply[start...end].utf8))
        var candidates: [Int: SpeakerIdentity] = [:]
        var ambiguous: Set<Int> = []
        for item in (result.suggestions ?? []).prefix(16) {
            let quote = item.quote.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (12...200).contains(quote.count), let excerpt = excerpts[String(item.speaker)],
                  excerpt.range(of: quote, options: [.literal, .caseInsensitive]) != nil,
                  let name = SpeakerIdentity.validName(item.name) else { continue }
            if let current = candidates[item.speaker], current.name != name { ambiguous.insert(item.speaker) }
            candidates[item.speaker] = SpeakerIdentity(name: name, source: .transcript, quote: quote)
        }
        return candidates.filter { !ambiguous.contains($0.key) }
    }

    func enqueue(note: URL, roster: String = "") {
        guard config.structureEnabled else { return }
        do {
            try FileManager.default.createDirectory(at: queueDirectory, withIntermediateDirectories: true)
            let name = ISO8601DateFormatter.filenameSafe.string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let job = ["note": note.path, "tries": "0", "roster": roster]
            let data = try JSONSerialization.data(withJSONObject: job)
            try data.write(to: queueDirectory.appendingPathComponent("\(name).json"))
        } catch {
            log("Auftrag fuer die Struktur konnte nicht abgelegt werden: \(error.localizedDescription)")
        }
    }

    func pending() -> Int {
        let files = try? FileManager.default.contentsOfDirectory(at: queueDirectory, includingPropertiesForKeys: nil)
        return files?.filter { $0.pathExtension == "json" }.count ?? 0
    }

    func drain() {
        guard config.structureEnabled else { return }
        guard let files = try? FileManager.default.contentsOfDirectory(at: queueDirectory,
                                                                      includingPropertiesForKeys: nil)
        else { return }

        for file in files.sorted(by: { $0.path < $1.path }) where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let job = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let path = job["note"]
            else {
                try? FileManager.default.removeItem(at: file)
                continue
            }

            let note = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: note.path) else {
                try? FileManager.default.removeItem(at: file)
                continue
            }

            let tries = Int(job["tries"] ?? "0") ?? 0
            if tries >= config.structureMaxTries {
                log("Struktur fuer \(note.lastPathComponent) nach \(tries) Versuchen aufgegeben.")
                try? FileManager.default.removeItem(at: file)
                continue
            }

            switch structure(note: note, roster: job["roster"] ?? "") {
            case .success:
                try? FileManager.default.removeItem(at: file)
            case .failure(let reason):
                log("Struktur fuer \(note.lastPathComponent) vertagt: \(reason)")
                let next = ["note": path, "tries": String(tries + 1), "roster": job["roster"] ?? ""]
                if let data = try? JSONSerialization.data(withJSONObject: next) {
                    try? data.write(to: file)
                }
                return
            }
        }
    }

    private enum Outcome {
        case success
        case failure(String)
    }

    private func structure(note: URL, roster: String) -> Outcome {
        guard var text = try? String(contentsOf: note, encoding: .utf8) else {
            return .failure("Notiz nicht lesbar")
        }
        if Self.frontmatterValue("teilnehmer", in: text) == nil {
            do {
                text = try addParticipants(to: note, text: text, roster: roster)
            } catch {
                log("Teilnehmer fuer \(note.lastPathComponent) nicht bestimmt: \(error.localizedDescription)")
            }
        }
        let transcript = spoken(in: text)
        guard transcript.count > 200 else { return .success }

        guard let payload = try? JSONSerialization.data(withJSONObject: ["mode": "structure",
                                                                        "transcript": transcript,
                                                                        "ai": config.ai] as [String: Any])
        else {
            return .failure("Anfrage nicht baubar")
        }

        do {
            let answer = try ask(payload: payload)
            let trimmed = answer.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .failure("Modell hat nichts geliefert") }
            try insert(section: trimmed, model: answer.model, into: note, text: text)
            log("Struktur ergaenzt: \(note.lastPathComponent)")
            return .success
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func addParticipants(to note: URL, text: String, roster: String) throws -> String {
        let screen = roster.isEmpty ? Self.uniqueLines([screenSection(of: text)]) : roster
        let found: Participants
        if screen.isEmpty {
            found = Participants(meeting: nil, participants: [])
        } else {
            let request: [String: Any] = ["mode": "participants",
                                          "screen": screen,
                                          "meeting": Self.frontmatterValue("meeting", in: text) ?? "unbekannt",
                                          "apps": Self.frontmatterValue("apps", in: text) ?? "",
                                          "transcript": String(spoken(in: text).prefix(6000)),
                                          "ai": config.ai]
            let payload = try JSONSerialization.data(withJSONObject: request)
            found = try Participants.parse(try ask(payload: payload).answer)
        }
        let updated = Self.withParticipants(found, in: text)
        try updated.write(to: note, atomically: true, encoding: .utf8)
        log("Teilnehmer fuer \(note.lastPathComponent): \(found.participants.isEmpty ? "keine erkannt" : found.participants.joined(separator: ", "))")
        return updated
    }

    private func screenSection(of text: String) -> String {
        guard let start = text.range(of: "\n## Geteilter Bildschirm") else { return "" }
        return text[start.upperBound...].split(separator: "\n")
            .filter { !$0.hasPrefix("![[") && !$0.hasPrefix("### ") }
            .joined(separator: "\n")
    }

    static func frontmatterValue(_ key: String, in text: String) -> String? {
        guard text.hasPrefix("---\n"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex)
        else { return nil }
        for line in text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound].split(separator: "\n")
        where line.hasPrefix("\(key):") {
            var value = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            return value
        }
        return nil
    }

    static func withParticipants(_ found: Participants, in text: String) -> String {
        guard text.hasPrefix("---\n"),
              let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex)
        else { return text }
        var lines = text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound]
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.removeAll { $0.hasPrefix("teilnehmer:") }
        let list = "teilnehmer: [" + found.participants.map(yaml).joined(separator: ", ") + "]"
        if let index = lines.firstIndex(where: { $0.hasPrefix("meeting:") }) {
            if lines[index] == "meeting: unbekannt", let meeting = found.meeting {
                lines[index] = "meeting: " + yaml(meeting)
            }
            lines.insert(list, at: index + 1)
        } else {
            lines.append(list)
        }
        return "---\n" + lines.joined(separator: "\n") + text[end.lowerBound...]
    }

    private static func yaml(_ value: String) -> String {
        let flat = value.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + flat + "\""
    }

    private func ask(payload: Data) throws -> CodexAnswer {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = CodexAsk.bridgeArguments(host: config.structureHost, script: config.bridgeScript)

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            throw CodexError.failed("ssh nicht startbar: \(error.localizedDescription)")
        }

        input.fileHandleForWriting.write(payload)
        try? input.fileHandleForWriting.close()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let problem = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let last = problem.split(separator: "\n").last.map(String.init) ?? "Exit \(process.terminationStatus)"
            throw CodexError.failed(last)
        }
        do {
            return try JSONDecoder().decode(CodexAnswer.self, from: data)
        } catch {
            throw CodexError.failed("Antwort von Codex unlesbar")
        }
    }

    private func spoken(in text: String) -> String {
        var lines: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let raw = String(line)
            if raw.hasPrefix("---") || raw.hasPrefix("![[") { continue }
            if raw.hasPrefix("## ") || raw.hasPrefix("### ") || raw.hasPrefix("# ") { continue }
            lines.append(raw)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func insert(section: String, model: String, into note: URL, text: String) throws {
        let marker = "## Struktur"
        var body = text

        if let start = body.range(of: marker) {
            let rest = body[start.upperBound...]
            if let next = rest.range(of: "\n## ") {
                body.removeSubrange(start.lowerBound..<next.lowerBound)
            } else {
                body.removeSubrange(start.lowerBound..<body.endIndex)
            }
        }

        let stamp = ISO8601DateFormatter().string(from: Date())
        let block = """
        \(marker)

        \(section)

        <sub>Automatisch aus dem Transkript, \(model), \(stamp). Ungeprueft.</sub>

        """

        if let anchor = body.range(of: "## Transkript") {
            body.insert(contentsOf: block + "\n", at: anchor.lowerBound)
        } else {
            body += "\n\n" + block
        }
        try body.write(to: note, atomically: true, encoding: .utf8)
    }
}

struct Participants: Decodable, Equatable {
    let meeting: String?
    let participants: [String]

    static func parse(_ answer: String) throws -> Participants {
        guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"),
              let data = String(answer[start...end]).data(using: .utf8),
              let raw = try? JSONDecoder().decode(Participants.self, from: data)
        else { throw CodexError.failed("Teilnehmerantwort unlesbar") }
        let names = raw.participants
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { (2...80).contains($0.count) }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let meeting = raw.meeting
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.count > 2 && $0 != "unbekannt" ? String($0.prefix(120)) : nil }
        return Participants(meeting: meeting, participants: Array(names.prefix(30)))
    }
}
