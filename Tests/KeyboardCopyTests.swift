import AppKit
import XCTest
@testable import mitschrift

final class KeyboardCopyTests: XCTestCase {
    @MainActor
    func testWindowDeliversCopyToSelectedReadingTextAndComposer() async throws {
        _ = NSApplication.shared
        let assistant = AssistantPanel(presentation: AssistantPresentationGate(), snapshot: { AssistantSnapshot() })
        assistant.show()
        defer { assistant.panel.orderOut(nil) }
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        let content = try XCTUnwrap(assistant.panel.contentView)
        let views = descendants(content)
        let composer = try XCTUnwrap(views.compactMap { $0 as? ChatComposer }.first)
        let saved: [NSPasteboardItem] = NSPasteboard.general.pasteboardItems?.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        } ?? []
        defer {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(saved)
        }
        func copySelection(_ text: ChatTextView) throws {
            text.string = "Anfang Silvia Ende"
            XCTAssertTrue(assistant.panel.makeFirstResponder(text))
            text.setSelectedRange(NSRange(location: 7, length: 6))
            NSPasteboard.general.clearContents()
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [.command], timestamp: 0, windowNumber: assistant.panel.windowNumber,
                context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
            NSApp.sendEvent(event)
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Silvia")
            XCTAssertEqual(text.string, "Anfang Silvia Ende")
        }
        for live in [false, true] {
            if live { assistant.showLive() }
            try await Task.sleep(for: .milliseconds(100))
            let reading = try XCTUnwrap(views.compactMap { $0 as? ChatTextView }
                .first { !$0.isEditable && !$0.isHiddenOrHasHiddenAncestor })
            try copySelection(reading)
            if let folder = ProcessInfo.processInfo.environment["MITSCHRIFT_UI_EVIDENCE"] {
                content.layoutSubtreeIfNeeded()
                assistant.panel.displayIfNeeded()
                let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                content.cacheDisplay(in: content.bounds, to: rep)
                try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to:
                    URL(fileURLWithPath: folder).appendingPathComponent(live ? "copy-live.png" : "copy-chat.png"))
            }
        }
        try copySelection(composer)
    }
}
