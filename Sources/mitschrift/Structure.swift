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

    private final class Box: @unchecked Sendable { var text = "" }

    private func structure(note: URL) -> Outcome {
        guard let text = try? String(contentsOf: note, encoding: .utf8) else {
            return .failure("Notiz nicht lesbar")
        }
        let transcript = spoken(in: text)
        guard transcript.count > 200 else { return .success }

        let prompt = """
        Strukturiere dieses Meeting-Transkript. Antworte auf Deutsch, nur in diesem Format, \
        keine Vorrede, keine Erklaerung:

        ### Kernpunkte
        - je ein Satz

        ### Entscheidungen
        - oder "keine"

        ### Aufgaben
        - [ ] Aufgabe (Verantwortlicher, Frist falls genannt)

        ### Offene Fragen
        - oder "keine"

        Erfinde nichts. Das Transkript ist automatisch erkannt und enthaelt Hoerfehler, \
        gib im Zweifel nichts an statt zu raten.

        Transkript:
        \(transcript)
        """

        let body: [String: Any] = [
            "model": config.structureModel,
            "prompt": prompt,
            "stream": false,
            "think": false,
            "options": ["temperature": 0.2, "num_predict": 900, "num_ctx": config.structureContext]
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            return .failure("Anfrage nicht baubar")
        }

        let box = Box()
        switch ask(payload: payload, into: box) {
        case .failure(let reason):
            return .failure(reason)
        case .success:
            let trimmed = box.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .failure("Modell hat nichts geliefert") }
            do {
                try insert(section: trimmed, into: note, text: text)
                log("Struktur ergaenzt: \(note.lastPathComponent)")
                return .success
            } catch {
                return .failure(error.localizedDescription)
            }
        }
    }

    private func ask(payload: Data, into box: Box) -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=8",
            config.structureHost,
            "curl -s -m \(config.structureTimeoutSeconds) -X POST http://localhost:11434/api/generate "
                + "-H 'Content-Type: application/json' --data-binary @-"
        ]

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            return .failure("ssh nicht startbar: \(error.localizedDescription)")
        }

        input.fileHandleForWriting.write(payload)
        try? input.fileHandleForWriting.close()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let problem = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            return .failure("Zotac nicht erreichbar (\(problem.trimmingCharacters(in: .whitespacesAndNewlines)))")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure("Antwort nicht lesbar")
        }
        if let message = object["error"] as? String {
            return .failure("Ollama: \(message)")
        }
        box.text = (object["response"] as? String) ?? ""
        return .success
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

    private func insert(section: String, into note: URL, text: String) throws {
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

        <sub>Automatisch aus dem Transkript, \(config.structureModel), \(stamp). Ungeprueft.</sub>

        """

        if let anchor = body.range(of: "## Transkript") {
            body.insert(contentsOf: block + "\n", at: anchor.lowerBound)
        } else {
            body += "\n\n" + block
        }
        try body.write(to: note, atomically: true, encoding: .utf8)
    }
}
