import AppKit
import Darwin
import Foundation

struct MeetingTrailSettings: Decodable {
    let host: String
    let script: String
    let config: String?
    let projects: [String]
    let stateDirectory: String?
    let preferredProject: String?

    static func load() -> Self? {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/.config/mitschrift/meeting-trail.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    var recordingDirectory: URL {
        URL(fileURLWithPath: stateDirectory ?? NSHomeDirectory() + "/Library/Application Support/mitschrift")
    }
}

@MainActor
final class MeetingTrailPilot {
    private struct Pulse: Decodable {
        let status: String
        let recording_id: String?
        let updated_at: Double
        let pid: Int32
    }

    private struct Reply: Decodable {
        let note: MeetingTrailNote?
        let answer: String?
        let error: String?
        let sessionID: String?
    }

    private let settings: MeetingTrailSettings
    private let state: MeetingTrailState
    private let presentPreview: (() -> Void)?
    private var integrated: Bool { presentPreview == nil }
    private var task: Task<Void, Never>?
    private var current: String?
    private var nextTick = Date.distantPast
    private var busy = false
    private var project: String?
    private var observedID: String?
    private var observedTitle: String?
    private var ending: (id: String, saved: Bool)?
    private(set) var recentSession: String?
    private(set) var updates: [(id: String, at: Date)] = []
    var onGlossary: ((String, [String]) async -> Void)?

    init(settings: MeetingTrailSettings, state: MeetingTrailState, presentPreview: (() -> Void)? = nil) {
        self.settings = settings
        self.state = state
        self.presentPreview = presentPreview
        state.armed = false
        state.projects = settings.projects
        if let preferred = settings.preferredProject, settings.projects.contains(preferred) {
            state.project = preferred
        }
        state.arm = { [weak self] in self?.arm() }
        state.ask = { [weak self] question in self?.ask(question) }
    }

    func recordingStarted(_ id: String, title: String?) {
        guard observedID != id || observedTitle != title else { return }
        if observedID != id { state.expect(id) }
        observedID = id
        observedTitle = title
    }

    func recordingEnded(_ id: String, saved: Bool) {
        guard observedID == id || current == id else { return }
        if observedID == id {
            observedID = nil
            observedTitle = nil
        }
        guard current == id else {
            stop()
            state.armed = false
            return
        }
        ending = (id, saved)
        state.canAsk = false
    }

    func arm() {
        guard task == nil else { return }
        project = state.project.isEmpty ? nil : state.project
        state.armed = true
        state.status = "Warte auf die Aufnahme"
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.step()
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        state.canAsk = false
    }

    func ask(_ question: String) {
        guard let id = current, state.canAsk, !busy, !state.asking else { return }
        state.asking = true
        state.answer = nil
        Task { [weak self] in
            guard let self else { return }
            defer { state.asking = false }
            let reply = await request("ask", id: id, question: question)
            state.answerFailed = reply?.answer == nil
            state.answer = reply?.answer ?? reply?.error ?? "Die Antwort ist gerade nicht verfügbar."
        }
    }

    private func pulse() -> Pulse? {
        let file = settings.recordingDirectory.appendingPathComponent("live-state.json")
        guard let data = try? Data(contentsOf: file), data.count < 16_384,
              let pulse = try? JSONDecoder().decode(Pulse.self, from: data),
              Date().timeIntervalSince1970 - pulse.updated_at >= 0,
              Date().timeIntervalSince1970 - pulse.updated_at < 15,
              pulse.pid > 0, kill(pulse.pid, 0) == 0 else { return nil }
        return pulse
    }

    private func isTeams(_ id: String) -> Bool {
        guard id.range(of: "^[0-9T:+.\\-]{10,80}$", options: .regularExpression) != nil else { return false }
        let file = settings.recordingDirectory.appendingPathComponent("partial/\(id).jsonl")
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: 32_768),
              let line = prefix.split(separator: 10, maxSplits: 1).first,
              let header = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
              header["kind"] as? String == "header", header["id"] as? String == id,
              let apps = header["apps"] as? [String] else { return false }
        return apps.contains { $0.localizedCaseInsensitiveContains("Microsoft Teams") }
    }

    private func step() async {
        guard !busy, !Task.isCancelled else { return }
        if let ending {
            if await finish(ending.id, saved: ending.saved) { self.ending = nil }
            return
        }
        let active: String?
        if integrated {
            active = observedID
        } else if let pulse = pulse() {
            active = pulse.status == "recording" ? pulse.recording_id : nil
        } else {
            if current != nil {
                state.status = "Aufnahmestatus gerade nicht verfügbar"
                state.canAsk = false
            }
            return
        }
        if !integrated, let id = current, id != active {
            _ = await finish(id, saved: true)
            return
        }
        guard let id = active, integrated || current == id || isTeams(id) else { return }
        if current != id {
            current = id
            nextTick = .distantPast
            state.dismissAnswer()
            state.status = "Hole die erste Gesprächsnotiz"
            presentPreview?()
        }
        guard nextTick <= Date() else { return }
        nextTick = Date().addingTimeInterval(120)
        let reply = await request("tick", id: id)
        state.status = reply?.error ?? (reply == nil ? "Notiz-Agent nicht erreichbar" : nil)
        state.canAsk = reply?.note?.topics.isEmpty == false && current == id &&
            (integrated ? observedID == id : pulse()?.recording_id == id)
        if let session = reply?.sessionID {
            updates.append((session, Date()))
        } else if reply?.error == nil, reply?.note?.topics.isEmpty == true {
            nextTick = Date().addingTimeInterval(10)
        }
    }

    private func finish(_ id: String, saved: Bool) async -> Bool {
        state.canAsk = false
        guard let reply = await request(saved ? "finish" : "discard", id: id), reply.note?.ended == true else { return false }
        if !saved { state.discard(id) }
        current = nil
        state.armed = false
        state.status = nil
        stop()
        return true
    }

    private func request(_ op: String, id: String, question: String? = nil) async -> Reply? {
        guard !busy else { return nil }
        busy = true
        state.requestBusy = true
        defer {
            busy = false
            state.requestBusy = false
        }
        let settings = self.settings
        var request = ["op": op, "recordingID": id]
        request["project"] = project
        request["title"] = observedTitle
        request["question"] = question
        if question != nil { request["requestID"] = UUID().uuidString }
        let body = request
        let result = await Task.detached(priority: .utility) { () -> Data? in
            guard let data = try? JSONEncoder().encode(body) else { return nil }
            return Self.exchange(settings: settings, input: data)
        }.value
        guard let result, let reply = try? JSONDecoder().decode(Reply.self, from: result) else { return nil }
        if let note = reply.note, note.meetingID == id, let encoded = try? JSONEncoder().encode(note) {
            do {
                try encoded.write(to: state.file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: state.file.path)
                state.refresh()
                if observedID == id, let terms = note.glossaryTerms {
                    await onGlossary?(id, Array(terms.prefix(50)))
                }
            } catch {
                state.status = "Gesprächsnotiz konnte lokal nicht gespeichert werden"
            }
        }
        if let session = reply.sessionID { recentSession = session }
        return reply
    }

    nonisolated private static func exchange(settings: MeetingTrailSettings, input: Data) -> Data? {
        guard !settings.host.hasPrefix("-") else { return nil }
        let process = Process()
        let source = Pipe()
        let target = Pipe()
        var command = "python3 -B " + shellQuote(settings.script)
        if let config = settings.config { command += " --config " + shellQuote(config) }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-T", "-o", "BatchMode=yes", "-o", "ClearAllForwardings=yes", "-o", "ConnectTimeout=7",
                             "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=2", settings.host, command]
        process.standardInput = source
        process.standardOutput = target
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            try source.fileHandleForWriting.write(contentsOf: input)
            try source.fileHandleForWriting.close()
            let data = target.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return data.count <= 300_000 ? data : nil
        } catch {
            if process.isRunning { process.terminate() }
            return nil
        }
    }

    nonisolated private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
