import Foundation

struct Structure {
    let config: Config

    private var queueDirectory: URL {
        Config.stateDirectory.appendingPathComponent("queue")
    }

    func enqueue(note: URL) {
        guard config.structureEnabled else { return }
        do {
            try FileManager.default.createDirectory(at: queueDirectory, withIntermediateDirectories: true)
            let name = ISO8601DateFormatter.filenameSafe.string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let job = ["note": note.path, "tries": "0"]
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

            switch structure(note: note) {
            case .success:
                try? FileManager.default.removeItem(at: file)
            case .failure(let reason):
                log("Struktur fuer \(note.lastPathComponent) vertagt: \(reason)")
                let next = ["note": path, "tries": String(tries + 1)]
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

    private func structure(note: URL) -> Outcome {
        guard let text = try? String(contentsOf: note, encoding: .utf8) else {
            return .failure("Notiz nicht lesbar")
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
