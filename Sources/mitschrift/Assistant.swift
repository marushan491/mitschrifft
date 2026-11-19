import Foundation

struct AssistantSnapshot: Sendable {
    var segments: [Segment] = []
    var elapsed: TimeInterval = 0
    var meeting: String?
    var screenText: String?
    var recording = false
    var startedAt: Date?
    var recordingID: String?
    var showsSpeakerIdentity = false
}
enum MeetingText {
    static func lines(_ segments: [Segment], since: TimeInterval = 0) -> String {
        segments.filter { $0.end >= since }
            .map { "[\(formatClock($0.start))] \(Speakers.name($0)): \($0.text)" }
            .joined(separator: "\n")
    }

    static func live(_ snapshot: AssistantSnapshot) -> String {
        guard snapshot.recording else { return "Gerade läuft keine Aufnahme." }
        let text = lines(snapshot.segments, since: max(0, snapshot.elapsed - 600))
        return text.isEmpty ? "Noch kein Text erkannt." : text.replacingOccurrences(of: "\n", with: "\n\n")
    }
}

enum CodexMode: String, Sendable {
    case asked
    case question
    case analysis
    case openAnalysis = "open-analysis"
    case targets
    case models
}

struct AssistantModel: Decodable, Equatable, Sendable {
    let id: String
    let title: String
    let efforts: [String]
    var provider: String? = nil
    var account: String? = nil
    var accountTitle: String? = nil
    var choiceID: String { account.map { $0 + "/" + id } ?? id }
}

struct AssistantModelGroup: Decodable, Sendable {
    let current: String
    let provider: String
    let account: String
    let models: [AssistantModel]
}

struct AssistantModels: Decodable, Sendable {
    let chat: AssistantModelGroup
    let analysis: AssistantModelGroup
}

struct AnalysisTarget: Decodable, Equatable, Sendable {
    let kind: String
    let id: String
    let name: String
    var detail: String? = nil

    var payload: [String: String] { ["kind": kind, "id": id] }
}

struct AnalysisTargets: Decodable, Sendable {
    let projects: [AnalysisTarget]
    let sessions: [AnalysisTarget]
}

struct CodexAnswer: Decodable, Sendable {
    let answer: String
    let model: String
    let account: String
    let effort: String
    let seconds: Double
    var sessionID: String? = nil
    var pending: Bool? = nil
}

struct ChatTurn: Sendable {
    let question: String
    let answer: String
    var images: [ChatImage] = []
    var model: String? = nil
}

struct AssistantConversation {
    private(set) var id = UUID().uuidString
    private(set) var turns: [ChatTurn] = []
    private var startedAt: Date?

    @discardableResult
    mutating func update(for snapshot: AssistantSnapshot) -> Bool {
        guard let start = snapshot.startedAt, start != startedAt else { return false }
        clear()
        startedAt = start
        return true
    }

    mutating func append(question: String, answer: String, images: [ChatImage] = [], model: String? = nil) {
        turns.append(ChatTurn(question: question, answer: answer, images: images, model: model))
        turns = Array(turns.suffix(6))
    }

    mutating func clear() { turns = []; id = UUID().uuidString }
}

enum CodexError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        }
    }
}

final class CodexAsk: @unchecked Sendable {
    static let recentSeconds: TimeInterval = 240

    private let host: String
    private let script: String
    private var ai: [String: [String: String]]
    private var selectionID = UUID().uuidString
    private let defaultConversationID = UUID().uuidString
    var choiceRevision: String { lock.withLock { selectionID } }
    private let lock = NSLock()
    private var process: Process?

    init(host: String, script: String = Config().bridgeScript, ai: [String: [String: String]] = [:]) {
        self.host = host
        self.script = script
        self.ai = ai
    }

    convenience init(config: Config) {
        self.init(host: config.structureHost, script: config.bridgeScript, ai: config.ai)
    }

    static func bridgeArguments(host: String, script: String) -> [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", host, "python3", script]
    }

    static func request(_ mode: CodexMode, question: String, snapshot: AssistantSnapshot,
                        history: [ChatTurn] = [], images: [ChatImage] = [], requestID: String? = nil,
                        target: AnalysisTarget? = nil, conversationID: String? = nil) -> [String: Any] {
        let since = mode == .asked ? max(0, snapshot.elapsed - recentSeconds) : 0
        var request: [String: Any] = ["mode": mode.rawValue,
                       "question": question,
                       "elapsed": formatClock(snapshot.elapsed),
                       "transcript": MeetingText.lines(snapshot.segments, since: since)]
        if let meeting = snapshot.meeting { request["meeting"] = meeting }
        if let recordingID = snapshot.recordingID { request["recordingID"] = recordingID }
        if let screen = snapshot.screenText { request["screen"] = screen }
        if mode == .question || mode == .analysis {
            request["history"] = history.suffix(6).map {
                ["question": $0.question + ($0.images.isEmpty ? "" : "\nBilder: " + $0.images.map(\.name).joined(separator: ", ")),
                 "answer": $0.answer]
            }
            let current = Array(images.prefix(4))
            let previous = history.suffix(6).flatMap(\.images).suffix(max(0, 4 - current.count))
            request["images"] = previous.map { image in
                ["name": "Frühere Nachricht: " + image.name, "data": image.jpeg.base64EncodedString()]
            } + current.map(\.payload)
        }
        if let requestID { request["requestID"] = requestID }
        if let conversationID { request["conversationID"] = conversationID }
        if mode == .analysis, let target { request["target"] = target.payload }
        return request
    }

    func ask(_ mode: CodexMode, question: String = "", snapshot: AssistantSnapshot,
             history: [ChatTurn] = [], images: [ChatImage] = [], requestID: String? = nil,
             target: AnalysisTarget? = nil, conversationID: String? = nil) async throws -> CodexAnswer {
        let request = Self.request(mode, question: question, snapshot: snapshot, history: history,
                                   images: images, requestID: requestID ?? UUID().uuidString, target: target,
                                   conversationID: conversationID ?? defaultConversationID)
        let output = try await call(request)
        do {
            return try JSONDecoder().decode(CodexAnswer.self, from: output)
        } catch {
            throw CodexError.failed("Antwort von Codex unlesbar.")
        }
    }

    func targets() async throws -> AnalysisTargets {
        let metadata = CodexAsk(host: host, script: script, ai: lock.withLock { ai })
        let output = try await metadata.call(["mode": CodexMode.targets.rawValue])
        do {
            return try JSONDecoder().decode(AnalysisTargets.self, from: output)
        } catch {
            throw CodexError.failed("Projektliste von PandaOS unlesbar.")
        }
    }

    func models() async throws -> AssistantModels {
        let metadata = CodexAsk(host: host, script: script, ai: lock.withLock { ai })
        let output = try await metadata.call(["mode": CodexMode.models.rawValue])
        return try JSONDecoder().decode(AssistantModels.self, from: output)
    }

    func modelID(for task: String) -> String {
        lock.withLock {
            ai[task]?["model"] ?? (ai[task]?["provider"] == "ollama" ? "qwen3.5:9b" :
                (task == "analysis" ? "gpt-6.1-sol" : "gpt-6-luna"))
        }
    }

    static func selecting(_ model: AssistantModel, task: String,
                          in ai: [String: [String: String]]) -> [String: [String: String]] {
        var updated = ai
        updated[task, default: [:]]["model"] = model.id
        if let provider = model.provider { updated[task, default: [:]]["provider"] = provider }
        if let account = model.account { updated[task, default: [:]]["account"] = account }
        let current = ai[task]?["effort"] ?? (task == "analysis" ? "high" : "low")
        if !model.efforts.isEmpty, !model.efforts.contains(current) {
            updated[task, default: [:]]["effort"] = model.efforts.contains("medium") ? "medium" : model.efforts[0]
        }
        return updated
    }

    func select(_ model: AssistantModel, task: String, file: URL = Config.file) throws {
        let updated = lock.withLock { Self.selecting(model, task: task, in: ai) }
        var config: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: file.path) {
            guard let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else {
                throw CodexError.failed("Modelleinstellung nicht gespeichert: Konfiguration unlesbar.")
            }
            config = raw
        }
        var saved = config["ai"] as? [String: [String: String]] ?? [:]
        saved[task, default: [:]]["model"] = model.id
        if let provider = model.provider { saved[task, default: [:]]["provider"] = provider }
        if let account = model.account { saved[task, default: [:]]["account"] = account }
        if let effort = updated[task]?["effort"] { saved[task, default: [:]]["effort"] = effort }
        config["ai"] = saved
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            .write(to: file, options: .atomic)
        lock.withLock {
            ai = updated
            if task == "chat" { selectionID = UUID().uuidString }
        }
    }

    private func call(_ body: [String: Any]) async throws -> Data {
        var request = body
        request["ai"] = lock.withLock { ai }
        request["selectionID"] = choiceRevision
        let input = try JSONSerialization.data(withJSONObject: request)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = Self.bridgeArguments(host: host, script: script)
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        defer { lock.withLock { self.process = nil } }

        let output: Data = try await withTaskCancellationHandler(operation: {
          try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { _ in }
            do {
                try lock.withLock {
                    try Task.checkCancellation()
                    try process.run()
                    self.process = process
                }
            } catch is CancellationError {
                continuation.resume(throwing: CancellationError())
                return
            } catch {
                continuation.resume(throwing: CodexError.failed("ssh nicht startbar: \(error.localizedDescription)"))
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try stdin.fileHandleForWriting.write(contentsOf: input)
                    try stdin.fileHandleForWriting.close()
                } catch {
                    try? stdin.fileHandleForWriting.close()
                }
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                let problem = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                if process.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: CancellationError())
                } else if process.terminationStatus != 0 {
                    let last = problem.split(separator: "\n").last.map(String.init) ?? "Exit \(process.terminationStatus)"
                    continuation.resume(throwing: CodexError.failed(last))
                } else {
                    continuation.resume(returning: data)
                }
            }
          }
        }, onCancel: { self.cancel() })
        return output
    }

    func cancel() {
        lock.withLock {
            if let process, process.isRunning { process.terminate() }
        }
    }
}
