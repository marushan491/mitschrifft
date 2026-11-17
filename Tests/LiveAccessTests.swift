import Foundation
import XCTest
@testable import mitschrift

final class LiveAccessTests: XCTestCase {
    func testModelSelectionPreservesAccountAndUnknownConfig() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config.json")
        try Data("{\"custom\":true,\"ai\":{\"chat\":{\"account\":\"chosen\",\"provider\":\"codex\",\"effort\":\"low\"}}}".utf8).write(to: file)
        let ai = ["chat": ["account": "chosen", "provider": "codex", "effort": "low"]]
        let codex = CodexAsk(host: "unused", ai: ai)
        let model = AssistantModel(id: "test-model", title: "Test Model", efforts: ["medium", "high"])
        try codex.select(model, task: "chat", file: file)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(saved["custom"] as? Bool, true)
        let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: file))
        XCTAssertEqual(config.ai["chat"]?["model"], "test-model")
        XCTAssertEqual(config.ai["chat"]?["account"], "chosen")
        XCTAssertEqual(config.ai["chat"]?["provider"], "codex")
        XCTAssertEqual(config.ai["chat"]?["effort"], "medium")
        XCTAssertNil(config.ai["analysis"])
        XCTAssertEqual(codex.modelID(for: "chat"), model.id)
        XCTAssertEqual(CodexAsk(host: "unused", ai: ["chat": ["provider": "ollama"]]).modelID(for: "chat"), "qwen3.5:9b")
    }

    func testPandaOSChoiceChangesAccountAndKeepsOtherTasks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config.json")
        let codex = CodexAsk(host: "unused", ai: ["cleanup": ["provider": "ollama"]])
        let initialRevision = codex.choiceRevision
        let model = AssistantModel(id: "same-model", title: "Model", efforts: ["high"],
                                   provider: "pandaos", account: "second-account", accountTitle: "Second")
        try codex.select(model, task: "chat", file: file)
        let saved = try JSONDecoder().decode(Config.self, from: Data(contentsOf: file))
        XCTAssertEqual(saved.ai["chat"]?["provider"], "pandaos")
        XCTAssertEqual(saved.ai["chat"]?["account"], "second-account")
        XCTAssertNotEqual(codex.choiceRevision, initialRevision)
        let chatRevision = codex.choiceRevision
        try codex.select(model, task: "analysis", file: file)
        XCTAssertEqual(codex.choiceRevision, chatRevision)
        var conversation = AssistantConversation()
        let previous = conversation.id
        conversation.clear()
        XCTAssertNotEqual(conversation.id, previous)
    }

    func testLiveStatePublishesRecordingThenIdleAndClears() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("live-state.json")
        LiveState.write(recordingID: "20260101T12:00:00", file: file)
        let active = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(active["recording_id"] as? String, "20260101T12:00:00")
        XCTAssertEqual(active["status"] as? String, "recording")
        LiveState.write(recordingID: nil, file: file)
        let idle = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(idle["status"] as? String, "idle")
        XCTAssertNil(idle["recording_id"])
        XCTAssertEqual(idle["instance_id"] as? String, active["instance_id"] as? String)
        LiveState.clear(file: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testChatExportConsentAndLifecycleClear() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.json")
        let shared = directory.appendingPathComponent("shared")
        let file = shared.appendingPathComponent("snapshot.json")
        try Data("{\"shareChat\":true}".utf8).write(to: config)
        let turns = (0..<8).map { ChatTurn(question: "Synthetic \($0)", answer: "Answer") }
        SharedChat.write(turns, recordingID: "2026-01-01T12:00:00", configFile: config, directory: shared)
        let data = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual((data["turns"] as? [[String: String]])?.count, 6)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        SharedChat.clear(file: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        SharedChat.write(turns, recordingID: "2026-01-01T12:00:00", configFile: config, directory: shared)
        try Data("{}".utf8).write(to: config)
        SharedChat.write(turns, recordingID: "2026-01-01T12:00:00", configFile: config, directory: shared)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testAnalysisUsesExactRecordingIdentityWithoutGuessing() throws {
        var snapshot = AssistantSnapshot()
        XCTAssertNil(CodexAsk.request(.analysis, question: "test", snapshot: snapshot)["recordingID"])
        snapshot.recordingID = "2026-01-01T12:00:00"
        let request = CodexAsk.request(.analysis, question: "test", snapshot: snapshot)
        XCTAssertEqual(request["recordingID"] as? String, snapshot.recordingID)
    }

    func testChatSharingRequiresExplicitTrue() throws {
        XCTAssertFalse(try JSONDecoder().decode(Config.self, from: Data("{}".utf8)).shareChat)
        XCTAssertTrue(try JSONDecoder().decode(Config.self, from: Data("{\"shareChat\":true}".utf8)).shareChat)
    }
}
