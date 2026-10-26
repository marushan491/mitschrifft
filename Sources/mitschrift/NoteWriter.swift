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
                      title: String) -> String {
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
            guard let head = try? String(contentsOf: url, encoding: .utf8).prefix(700) else { continue }
            guard value(of: "meeting", in: String(head)) == meeting else { continue }
            guard let stamp = value(of: "ended", in: String(head)),
                  let ended = ISO8601DateFormatter().date(from: stamp) else { continue }
            let gap = start.timeIntervalSince(ended)
            guard gap >= -60, gap <= window else { continue }
            if best == nil || ended > best!.ended { best = (url, ended) }
        }
        return best?.url
    }

    private func value(of key: String, in text: String) -> String? {
        for line in text.split(separator: "\n") where line.hasPrefix("\(key):") {
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
        if let old = value(of: "ended", in: text) {
            text = text.replacingOccurrences(of: "ended: \(old)", with: "ended: \(iso.string(from: endedAt))")
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
    }
}
