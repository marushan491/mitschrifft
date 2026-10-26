import AppKit
import XCTest
@testable import mitschrift

final class PanelTests: XCTestCase {
    @MainActor
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor
    func testPandaHasDirectCaptureControlsWithoutPopupMenu() throws {
        _ = NSApplication.shared
        var photos = 0
        var videos = 0
        var recordings = 0
        let pet = PetWindow(onPhoto: { photos += 1 }, onToggle: { videos += 1 },
                            onRecord: { recordings += 1 }, snapshot: { AssistantSnapshot() })
        let controls = descendants(try XCTUnwrap(pet.panel.contentView)).compactMap { $0 as? NSButton }
        func button(_ label: String) throws -> NSButton {
            try XCTUnwrap(controls.first { $0.accessibilityLabel() == label })
        }
        try button("Audioaufnahme starten").performClick(nil)
        try button("Screenshot erstellen").performClick(nil)
        try button("Video aufnehmen").performClick(nil)
        XCTAssertEqual([recordings, photos, videos], [1, 1, 1])
        XCTAssertFalse(controls.contains { $0.action == NSSelectorFromString("moreTapped") || $0.menu != nil })
        pet.apply(recording: true, video: true, shots: 1, elapsed: "00:20")
        try button("Audioaufnahme beenden und speichern").performClick(nil)
        try button("Video beenden").performClick(nil)
        XCTAssertEqual([recordings, videos], [2, 2])
        try button("Chat mit Luna öffnen").performClick(nil)
        XCTAssertTrue(pet.assistant.panel.isVisible)
        XCTAssertEqual(pet.panel.sharingType, .none)
        XCTAssertEqual(pet.assistant.panel.sharingType, .none)
        pet.setPrivacyHidden(true)
        XCTAssertTrue(pet.privacyHidden)
        XCTAssertFalse(pet.assistant.panel.isVisible)
    }

    @MainActor
    func testChatHasBottomComposerAndKeyboardActions() throws {
        _ = NSApplication.shared
        let panel = AssistantPanel(presentation: AssistantPresentationGate(), snapshot: { AssistantSnapshot() })
        panel.show()
        defer { panel.panel.orderOut(nil) }
        panel.panel.contentView?.layoutSubtreeIfNeeded()
        let views = descendants(try XCTUnwrap(panel.panel.contentView))
        let input = try XCTUnwrap(views.compactMap { $0 as? ChatComposer }
            .first { $0.accessibilityLabel() == "Nachricht an Luna" })
        let send = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "Senden" })
        let cancel = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "Abbrechen" })
        let clear = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "Neuer Chat" })
        XCTAssertEqual(send.keyEquivalent, "\r")
        XCTAssertEqual(send.keyEquivalentModifierMask, [])
        XCTAssertEqual(cancel.keyEquivalent, "\u{1b}")
        XCTAssertTrue(cancel.isHidden)
        send.performClick(nil)
        XCTAssertTrue(send.isEnabled)
        clear.performClick(nil)
        let text = try XCTUnwrap(views.compactMap { $0 as? NSTextView }
            .first { $0.string.contains("Stell Luna eine Frage") })
        XCTAssertLessThan(input.convert(input.bounds, to: nil).maxY, text.enclosingScrollView!.convert(text.enclosingScrollView!.bounds, to: nil).minY)
        XCTAssertTrue(text.isSelectable)
    }

    @MainActor
    func testLiveLunaChatAndFollowUp() async throws {
        guard ProcessInfo.processInfo.environment["MITSCHRIFT_CHAT_SMOKE"] == "1" else {
            throw XCTSkip("Echter Business/Luna-Lauf nur mit MITSCHRIFT_CHAT_SMOKE=1")
        }
        _ = NSApplication.shared
        var snapshot = AssistantSnapshot(segments: [Segment(track: .system, start: 10, end: 15,
            text: "Für den synthetischen Test heißt das Paket KIESEL. Die Lieferung ist am Dienstag.")],
            elapsed: 20, recording: true, startedAt: Date())
        let panel = AssistantPanel(presentation: AssistantPresentationGate(), snapshot: { snapshot })
        panel.show()
        defer { panel.panel.orderOut(nil) }
        let views = descendants(try XCTUnwrap(panel.panel.contentView))
        let input = try XCTUnwrap(views.compactMap { $0 as? ChatComposer }
            .first { $0.accessibilityLabel() == "Nachricht an Luna" })
        let send = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "Senden" })
        let answer = try XCTUnwrap(views.compactMap { $0 as? NSTextView }
            .first { $0.string.contains("Stell Luna eine Frage") })
        input.string = "Wie heißt das Paket? Antworte nur aus dem Transkript."
        send.performClick(nil)
        XCTAssertFalse(send.isEnabled)
        for _ in 0..<120 where !send.isEnabled { try await Task.sleep(for: .seconds(1)) }
        XCTAssertTrue(send.isEnabled)
        XCTAssertTrue(answer.string.contains("KIESEL"), answer.string)
        snapshot.segments.append(Segment(track: .system, start: 30, end: 35,
                                         text: "Korrektur: Die Lieferung ist jetzt am Donnerstag."))
        snapshot.elapsed = 40
        input.string = "Und wann kommt es nach der Korrektur? Nenne auch den Paketnamen aus unserem Chat."
        send.performClick(nil)
        for _ in 0..<120 where !send.isEnabled { try await Task.sleep(for: .seconds(1)) }
        XCTAssertTrue(send.isEnabled)
        XCTAssertTrue(answer.string.contains("Donnerstag"), answer.string)
        XCTAssertTrue(answer.string.contains("KIESEL"), answer.string)
        XCTAssertLessThan(try XCTUnwrap(answer.string.range(of: "Wie heißt")) .lowerBound,
                          try XCTUnwrap(answer.string.range(of: "Und wann")) .lowerBound)
        let clear = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "Neuer Chat" })
        clear.performClick(nil)
        XCTAssertTrue(answer.string.contains("Stell Luna eine Frage"))
        XCTAssertFalse(answer.string.contains("KIESEL"))
    }
}
