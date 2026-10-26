import XCTest
@testable import mitschrift

final class VideoNotesTests: XCTestCase {
    func testAllClipsRemainLinkedWhenMeetingContinues() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        var config = Config()
        config.vaultPath = folder.path
        let writer = NoteWriter(config: config)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let first = try writer.write(segments: [], videoFiles: ["first.mp4", "second.mp4"],
                                     meeting: "Synthetischer Test", startedAt: start,
                                     endedAt: start.addingTimeInterval(30), apps: [])
        let next = try writer.write(segments: [], videoFiles: ["third.mp4"],
                                    meeting: "Synthetischer Test", startedAt: start.addingTimeInterval(40),
                                    endedAt: start.addingTimeInterval(60), apps: [])
        XCTAssertEqual(first.resolvingSymlinksInPath(), next.resolvingSymlinksInPath())
        let text = try String(contentsOf: first, encoding: .utf8)
        for clip in ["first.mp4", "second.mp4", "third.mp4"] { XCTAssertTrue(text.contains("![[\(clip)]]")) }
    }

    func testPartialSessionKeepsEveryCompletedClipAndReadsLegacyEntries() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let lines = ["first.mp4", "second.mp4", "first.mp4"].map {
            "{\"kind\":\"video\",\"file\":\"\($0)\"}"
        }.joined(separator: "\n")
        try lines.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(PartialSession(url: file)?.videoFiles, ["first.mp4", "second.mp4"])
        try "{\"kind\":\"video\",\"file\":\"legacy.mp4\"}".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(PartialSession(url: file)?.videoFiles, ["legacy.mp4"])
    }
}
