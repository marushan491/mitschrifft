import Foundation

struct PartialHeader: Codable {
    let id: String
    let startedAt: Date
    var apps: [String]
}

final class SegmentSink: @unchecked Sendable {
    let id: String
    let startedAt: Date
    private let url: URL
    private let lock = NSLock()
    private var handle: FileHandle?
    private var apps: Set<String> = []

    init(config: Config, apps: [String]) throws {
        self.id = ISO8601DateFormatter.filenameSafe.string(from: Date())
        self.startedAt = Date()
        self.apps = Set(apps)
        self.url = config.partialDirectory.appendingPathComponent("\(id).jsonl")

        try FileManager.default.createDirectory(at: config.partialDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        writeLine(["kind": "header",
                   "id": id,
                   "startedAt": ISO8601DateFormatter().string(from: startedAt),
                   "apps": Array(self.apps)])
    }

    func noteMeeting(_ title: String) {
        writeLine(["kind": "meeting", "title": title])
    }

    func noteApp(_ name: String) {
        lock.lock()
        let isNew = apps.insert(name).inserted
        lock.unlock()
        if isNew {
            writeLine(["kind": "app", "name": name])
        }
    }

    func append(_ segment: Segment) {
        writeLine([
            "kind": "segment",
            "track": segment.track.rawValue,
            "start": segment.start,
            "end": segment.end,
            "text": segment.text
        ])
    }

    func append(span: SpeakerSpan) {
        writeLine(["kind": "speaker", "speaker": span.speaker, "start": span.start, "end": span.end])
    }

    func append(screen: ScreenCapture) {
        var object: [String: Any] = [
            "kind": "screen",
            "at": screen.at,
            "app": screen.app,
            "text": screen.text
        ]
        if let file = screen.imageFile { object["imageFile"] = file }
        writeLine(object)
    }

    func append(video file: String) {
        writeLine(["kind": "video", "file": file])
    }

    func discard() {
        close()
        try? FileManager.default.removeItem(at: url)
    }

    func close() {
        lock.lock()
        try? handle?.close()
        handle = nil
        lock.unlock()
    }

    var partialURL: URL { url }

    var appNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return apps.sorted()
    }

    private func writeLine(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        lock.lock()
        handle?.write(data)
        handle?.write(Data("\n".utf8))
        lock.unlock()
    }
}

extension ISO8601DateFormatter {
    static let filenameSafe: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withColonSeparatorInTime]
        formatter.timeZone = .current
        return formatter
    }()
}

nonisolated(unsafe) var activeSink: SegmentSink?
