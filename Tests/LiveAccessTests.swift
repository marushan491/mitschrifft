import Foundation
import XCTest
@testable import mitschrift

final class LiveAccessTests: XCTestCase {
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
