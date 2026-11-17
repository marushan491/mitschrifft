import XCTest
@testable import mitschrift

final class ParticipantsTests: XCTestCase {
    func testHelperProcessesResolveToTheirApp() {
        XCTAssertEqual(AudioProcesses.outermostApp(inPath:
            "/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper"), "Slack")
        XCTAssertEqual(AudioProcesses.outermostApp(inPath:
            "/Applications/Microsoft Teams.app/Contents/Helpers/Microsoft Teams ModuleHost.app/Contents/MacOS/Microsoft Teams ModuleHost"),
            "Microsoft Teams")
        XCTAssertEqual(AudioProcesses.outermostApp(inPath:
            "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper (Alerts).app/Contents/MacOS/Google Chrome Helper (Alerts)"),
            "Google Chrome")
        XCTAssertNil(AudioProcesses.outermostApp(inPath: "/usr/libexec/replayd"))
    }

    func testMeetingTitleFromRealWindowTitles() {
        XCTAssertEqual(WindowShot.clean("Regelmeeting Riesling-Projekt | 9elf26 | marushan.anpalahan@9elf26.com | Microsoft Teams"),
                       "Regelmeeting Riesling-Projekt")
        XCTAssertEqual(WindowShot.clean("Daily | 9elf26 | marushan.anpalahan@9elf26.com | Microsoft Teams"), "Daily")
        XCTAssertEqual(WindowShot.clean("Tets | Microsoft Teams"), "Tets")
        XCTAssertEqual(WindowShot.clean("\u{200E}Asaph – WhatsApp-Sprachanruf"), "Asaph – WhatsApp-Sprachanruf")
        XCTAssertNil(WindowShot.clean("Timo - 9elf26 - Slack"))
        XCTAssertNil(WindowShot.clean("Timo (DM) - 9elf26 - 8 neue Elemente - Slack 🎤"))
        XCTAssertNil(WindowShot.clean("Window"))
    }

    func testModelAnswerIsParsedAndCleaned() throws {
        let found = try Participants.parse("""
        ```json
        {"meeting": "Huddle mit Rebar Hassan", "participants": ["Rebar Hassan", " Rebar Hassan ", "X"]}
        ```
        """)
        XCTAssertEqual(found, Participants(meeting: "Huddle mit Rebar Hassan", participants: ["Rebar Hassan"]))
        XCTAssertThrowsError(try Participants.parse("keine Ahnung"))
    }

    func testParticipantsLandInFrontmatterAndFillUnknownMeeting() {
        let note = """
        ---
        type: transcript
        apps: ["Slack"]
        meeting: unbekannt
        tags: [transkript]
        ---

        # 2026-11-17 1635 Slack
        """
        let updated = Structure.withParticipants(
            Participants(meeting: "Huddle mit \"Rebar\"", participants: ["Rebar Hassan", "Lisa Mack"]), in: note)
        XCTAssertTrue(updated.contains("meeting: \"Huddle mit \\\"Rebar\\\"\"\nteilnehmer: [\"Rebar Hassan\", \"Lisa Mack\"]\ntags:"))
        XCTAssertEqual(Structure.frontmatterValue("teilnehmer", in: updated), "[\"Rebar Hassan\", \"Lisa Mack\"]")
        XCTAssertTrue(updated.hasSuffix("# 2026-11-17 1635 Slack"))

        let known = note.replacingOccurrences(of: "meeting: unbekannt", with: "meeting: \"Daily\"")
        let kept = Structure.withParticipants(Participants(meeting: "Anderes", participants: []), in: known)
        XCTAssertTrue(kept.contains("meeting: \"Daily\"\nteilnehmer: []\n"))
    }

    func testRosterLinesAreDeduplicated() {
        XCTAssertEqual(Structure.uniqueLines(["Lisa Mack\nXaver", "Xaver\n \nJohannes Pfann"]),
                       "Lisa Mack\nXaver\nJohannes Pfann")
    }
}
