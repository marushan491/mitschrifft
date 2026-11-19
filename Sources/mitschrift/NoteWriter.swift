import Foundation

struct NoteWriter {
    let config: Config

    func write(segments: [Segment],
               screens: [ScreenCapture] = [],
               videoFiles: [String] = [],
               meeting: String? = nil,
               startedAt: Date,
               endedAt: Date,
               apps: [String]) throws -> URL {
        let segments = Echo.removeMicEcho(segments)
        try FileManager.default.createDirectory(at: config.notesDirectory, withIntermediateDirectories: true)

        if let meeting, let existing = openNote(forMeeting: meeting, startingAt: startedAt) {
            try appendPart(to: existing, segments: segments, screens: screens,
                           videoFiles: videoFiles, startedAt: startedAt, endedAt: endedAt)
            log("An bestehende Notiz angehaengt: \(existing.lastPathComponent)")
            return existing
        }

        let titleFormatter = DateFormatter()
        titleFormatter.dateFormat = "yyyy-MM-dd HHmm"
        titleFormatter.locale = Locale(identifier: "de_DE")

        let appLabel = sanitize(meeting ?? apps.first ?? "Gespraech")
        var base = "\(titleFormatter.string(from: startedAt)) \(appLabel)"
        var url = config.notesDirectory.appendingPathComponent("\(base).md")
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            base = "\(titleFormatter.string(from: startedAt)) \(appLabel) \(suffix)"
            url = config.notesDirectory.appendingPathComponent("\(base).md")
            suffix += 1
        }

        try body(segments: segments, screens: screens, videoFiles: videoFiles, meeting: meeting,
                 startedAt: startedAt, endedAt: endedAt, apps: apps, title: base)
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func body(segments: [Segment],
                      screens: [ScreenCapture],
                      videoFiles: [String],
                      meeting: String?,
                      startedAt: Date,
                      endedAt: Date,
                      apps: [String],
                      title: String) throws -> String {
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        let duration = endedAt.timeIntervalSince(startedAt)

        var out = """
        ---
        type: transcript
        source: mitschrift
        created: \(iso.string(from: startedAt))
        ended: \(iso.string(from: endedAt))
        duration: \(formatClock(duration))
        apps: [\(apps.map { "\"\($0)\"" }.joined(separator: ", "))]
        meeting: \(meeting.map { "\"\($0)\"" } ?? "unbekannt")
        \(try speakerProperty(speakerLinks(in: segments)))
        tags: [transkript]
        ---

        # \(title)

        Lokal transkribiert, ohne Audioaufnahme. Dauer \(formatClock(duration)), erkannte Anwendung: \(apps.isEmpty ? "unbekannt" : apps.joined(separator: ", ")).

        ## Transkript

        """

        if segments.isEmpty {
            out += "\n(Keine Sprache erkannt.)\n"
            return out + videoSection(videoFiles) + screenSection(screens)
        }

        out += blocks(segments)
        return out + videoSection(videoFiles) + screenSection(screens)
    }

    private func speakerLinks(in segments: [Segment]) -> [String] {
        var seen = Set<String>()
        return segments.compactMap { segment in
            guard segment.track == .system, !segment.speakerNameUncertain, !segment.overlappingSpeakers,
                  let name = segment.speakerName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty, !name.contains(where: \.isNewline), !name.contains(where: "[]|#^".contains),
                  seen.insert(name).inserted else { return nil }
            return "[[\(name)]]"
        }
    }

    private func speakerProperty(_ links: [String]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let values = try links.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        return "sprecher: [" + values.joined(separator: ", ") + "]"
    }

    private func mergeSpeakers(_ added: [String], into lines: inout [String]) throws {
        let key = "sprecher:"
        guard let index = lines.firstIndex(where: { $0.hasPrefix(key) }) else {
            lines.append(try speakerProperty(added))
            return
        }
        guard !added.isEmpty else { return }

        let decoder = JSONDecoder()
        let value = lines[index].dropFirst(key.count).trimmingCharacters(in: .whitespaces)
        var end = index + 1
        let existing: [String]
        if value.isEmpty {
            let entries = lines[end...].prefix { line in
                line.first?.isWhitespace == true || line.hasPrefix("- ") || line.isEmpty
            }
            var links: [String] = []
            for position in entries.indices {
                let item = entries[position].trimmingCharacters(in: .whitespaces)
                if item.isEmpty { continue }
                guard item.hasPrefix("- ") else { return }
                let scalar = item.dropFirst(2).trimmingCharacters(in: .whitespaces)
                if let link = try? decoder.decode(String.self, from: Data(scalar.utf8)) {
                    links.append(link)
                } else if scalar.count >= 2, scalar.hasPrefix("'"), scalar.hasSuffix("'") {
                    links.append(scalar.dropFirst().dropLast().replacingOccurrences(of: "''", with: "'"))
                } else {
                    return
                }
                end = position + 1
            }
            existing = links
        } else {
            guard let links = try? decoder.decode([String].self, from: Data(value.utf8)) else { return }
            existing = links
        }
        var seen = Set<String>()
        let merged = (existing + added).filter { seen.insert($0).inserted }
        guard merged != existing else { return }
        lines.replaceSubrange(index..<end, with: [try speakerProperty(merged)])
    }

    private func blocks(_ segments: [Segment]) -> String {
        var out = ""
        var current: String?
        var buffer: [String] = []
        var blockStart: TimeInterval = 0
        func flush() {
            guard let current, !buffer.isEmpty else { return }
            out += "\n**\(current)** (\(formatClock(blockStart)))\n\n\(buffer.joined(separator: " "))\n"
            buffer = []
        }
        for segment in segments {
            let name = Speakers.name(segment, me: config.speakerMe, others: config.speakerOthers)
            if name != current {
                flush()
                current = name
                blockStart = segment.start
            }
            buffer.append(segment.text)
        }
        flush()
        return out
    }

    private func videoSection(_ files: [String]) -> String {
        guard !files.isEmpty else { return "" }
        return "\n## Mitschnitt ohne Ton\n\n" + files.map { "![[\($0)]]\n" }.joined(separator: "\n")
    }

    private func screenSection(_ screens: [ScreenCapture]) -> String {
        guard !screens.isEmpty else { return "" }
        var out = "\n## Geteilter Bildschirm\n"
        for screen in screens.sorted(by: { $0.at < $1.at }) {
            out += "\n### \(formatClock(screen.at)) \(screen.app)\n"
            if let file = screen.imageFile {
                out += "\n![[\(file)]]\n"
            }
            if !screen.text.isEmpty {
                out += "\n\(screen.text)\n"
            }
        }
        return out
    }

    private func openNote(forMeeting meeting: String, startingAt start: Date) -> URL? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: config.notesDirectory,
                                                      includingPropertiesForKeys: [.contentModificationDateKey])
        else { return nil }

        let window = TimeInterval(config.mergeWithinSeconds)
        var best: (url: URL, ended: Date)?

        for url in files where url.pathExtension == "md" {
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let header = frontmatter(in: text) else { continue }
            let lines = text[header.range].split(separator: header.newline)
            guard value(of: "meeting", in: lines) == meeting else { continue }
            guard let stamp = value(of: "ended", in: lines),
                  let ended = ISO8601DateFormatter().date(from: stamp) else { continue }
            let gap = start.timeIntervalSince(ended)
            guard gap >= -60, gap <= window else { continue }
            if best == nil || ended > best!.ended { best = (url, ended) }
        }
        return best?.url
    }

    private func frontmatter(in text: String) -> (range: Range<String.Index>, newline: Character)? {
        guard let firstBreak = text.firstIndex(where: \.isNewline), text[..<firstBreak] == "---" else { return nil }
        let newline = text[firstBreak]
        let start = text.index(after: firstBreak)
        guard let end = text.range(of: "\(newline)---\(newline)", range: start..<text.endIndex) else { return nil }
        return (start..<end.lowerBound, newline)
    }

    private func value(of key: String, in lines: [Substring]) -> String? {
        for line in lines where line.hasPrefix("\(key):") {
            var raw = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("\"") { raw = String(raw.dropFirst().dropLast()) }
            return raw.isEmpty ? nil : raw
        }
        return nil
    }

    private func appendPart(to url: URL,
                            segments: [Segment],
                            screens: [ScreenCapture],
                            videoFiles: [String],
                            startedAt: Date,
                            endedAt: Date) throws {
        var text = try String(contentsOf: url, encoding: .utf8)

        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        if let header = frontmatter(in: text) {
            var lines = text[header.range].split(separator: header.newline, omittingEmptySubsequences: false)
                .map(String.init)
            if let index = lines.firstIndex(where: { $0.hasPrefix("ended:") }) {
                lines[index] = "ended: \(iso.string(from: endedAt))"
            }
            try mergeSpeakers(speakerLinks(in: segments), into: &lines)
            text.replaceSubrange(header.range, with: lines.joined(separator: String(header.newline)))
        }

        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"
        var part = "\n\n---\n\n## Fortsetzung ab \(clock.string(from: startedAt))\n"

        if segments.isEmpty {
            part += "\n(Keine Sprache erkannt.)\n"
        } else {
            part += blocks(segments)
        }

        part += videoSection(videoFiles)
        part += screenSection(screens)

        try (text + part).write(to: url, atomically: true, encoding: .utf8)
    }

    func recoverPartials() -> [URL] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: config.partialDirectory, includingPropertiesForKeys: nil)
        else { return [] }

        var recovered: [URL] = []
        for file in files where file.pathExtension == "jsonl" {
            guard let partial = PartialSession(url: file) else { continue }
            let segments = partial.segments
            let screens = partial.screens
            let videoFiles = partial.videoFiles

            if segments.isEmpty, screens.isEmpty, videoFiles.isEmpty {
                try? fm.removeItem(at: file)
                continue
            }

            let endedAt = (try? fm.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) ?? Date()
            if let url = try? write(segments: segments,
                                    screens: screens,
                                    videoFiles: videoFiles,
                                    meeting: partial.meeting,
                                    startedAt: partial.startedAt,
                                    endedAt: endedAt,
                                    apps: partial.apps) {
                recovered.append(url)
                try? fm.removeItem(at: file)
            }
        }
        return recovered
    }

    private func sanitize(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
    }
}

struct PartialSession {
    var segments: [Segment] = []
    var screens: [ScreenCapture] = []
    var videoFiles: [String] = []
    var meeting: String?
    var startedAt = Date()
    var apps: [String] = []

    init?(url: URL) {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var spans: [SpeakerSpan] = []
        var attribution = SpeakerAttribution()
        var review = SpeakerReview()
        for line in content.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let kind = object["kind"] as? String
            else { continue }

            switch kind {
            case "header":
                if let stamp = object["startedAt"] as? String,
                   let date = ISO8601DateFormatter().date(from: stamp) { startedAt = date }
                if let list = object["apps"] as? [String] { apps = list }
            case "app":
                if let name = object["name"] as? String, !apps.contains(name) { apps.append(name) }
            case "segment":
                guard let track = (object["track"] as? String).flatMap(Track.init(rawValue:)),
                      let text = object["text"] as? String,
                      let start = object["start"] as? Double,
                      let end = object["end"] as? Double
                else { continue }
                segments.append(Segment(track: track, start: start, end: end, text: text))
            case "speaker":
                guard let speaker = object["speaker"] as? Int,
                      let start = object["start"] as? Double,
                      let end = object["end"] as? Double
                else { continue }
                spans.append(SpeakerSpan(speaker: speaker, start: start, end: end))
            case "speaker_name":
                guard let rawName = object["name"] as? String,
                      let name = TeamsCaption.personName(rawName),
                      let start = object["start"] as? Double, let end = object["end"] as? Double,
                      start.isFinite, end.isFinite, start >= 0, end >= start else { continue }
                attribution.add(name, at: .init(start: start, end: end))
            case "speaker_review":
                guard let raw = object["speaker"] as? Int, raw >= 0,
                      let input = object["name"] as? String,
                      let name = SpeakerIdentity.validName(input) else { continue }
                review.manual[review.representative(raw)] = name
            case "speaker_merge":
                guard let raw = object["speaker"] as? Int, raw >= 0,
                      let target = object["into"] as? Int, target >= 0 else { continue }
                let from = review.representative(raw)
                let to = review.representative(target)
                guard from != to else { continue }
                review.aliases[from] = to
                review.manual[to] = review.manual[to] ?? review.manual.removeValue(forKey: from)
                review.manual[from] = nil
            case "screen":
                guard let at = object["at"] as? Double,
                      let app = object["app"] as? String
                else { continue }
                screens.append(ScreenCapture(at: at,
                                             app: app,
                                             text: (object["text"] as? String) ?? "",
                                             imageFile: object["imageFile"] as? String))
            case "video":
                if let file = object["file"] as? String, !videoFiles.contains(file) { videoFiles.append(file) }
            case "meeting":
                meeting = object["title"] as? String
            default:
                break
            }
        }
        segments = Speakers.label(segments.sorted { $0.start < $1.start }, spans: spans)
        if apps.contains(MeetingSpeakerApp.teamsName) { segments = attribution.apply(to: segments) }
        segments = review.apply(to: segments)
    }
}
