import Foundation

struct AssistantSnapshot: Sendable {
    var segments: [Segment] = []
    var elapsed: TimeInterval = 0
    var meeting: String?
    var screenText: String?
    var recording = false
    var startedAt: Date?
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
}

struct ChatTurn: Sendable {
    let question: String
    let answer: String
    var images: [ChatImage] = []
}

struct AssistantConversation {
    private(set) var turns: [ChatTurn] = []
    private var startedAt: Date?

    @discardableResult
    mutating func update(for snapshot: AssistantSnapshot) -> Bool {
        guard let start = snapshot.startedAt, start != startedAt else { return false }
        turns = []
        startedAt = start
        return true
    }

    mutating func append(question: String, answer: String, images: [ChatImage] = []) {
        turns.append(ChatTurn(question: question, answer: answer, images: images))
        turns = Array(turns.suffix(6))
    }

    mutating func clear() { turns = [] }
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
    private let ai: [String: [String: String]]
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
                        target: AnalysisTarget? = nil) -> [String: Any] {
        let since = mode == .asked ? max(0, snapshot.elapsed - recentSeconds) : 0
        var request: [String: Any] = ["mode": mode.rawValue,
                       "question": question,
                       "elapsed": formatClock(snapshot.elapsed),
                       "transcript": MeetingText.lines(snapshot.segments, since: since)]
        if let meeting = snapshot.meeting { request["meeting"] = meeting }
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
        if mode == .analysis, let target { request["target"] = target.payload }
        return request
    }

    func ask(_ mode: CodexMode, question: String = "", snapshot: AssistantSnapshot,
             history: [ChatTurn] = [], images: [ChatImage] = [], requestID: String? = nil,
             target: AnalysisTarget? = nil) async throws -> CodexAnswer {
        let request = Self.request(mode, question: question, snapshot: snapshot, history: history,
                                   images: images, requestID: requestID, target: target)
        let output = try await call(request)
        do {
            return try JSONDecoder().decode(CodexAnswer.self, from: output)
        } catch {
            throw CodexError.failed("Antwort von Codex unlesbar.")
        }
    }

    func targets() async throws -> AnalysisTargets {
        let output = try await call(["mode": CodexMode.targets.rawValue])
        do {
            return try JSONDecoder().decode(AnalysisTargets.self, from: output)
        } catch {
            throw CodexError.failed("Projektliste von PandaOS unlesbar.")
        }
    }

    private func call(_ body: [String: Any]) async throws -> Data {
        var request = body
        request["ai"] = ai
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

@MainActor
final class AssistantPresentationGate {
    private(set) var hidden = false

    func setHidden(_ value: Bool) { hidden = value }

    @discardableResult
    func present(_ action: () -> Void) -> Bool {
        guard !hidden else { return false }
        action()
        return true
    }
}
