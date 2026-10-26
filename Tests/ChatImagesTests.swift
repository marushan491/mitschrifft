import AppKit
import XCTest
@testable import mitschrift

final class ChatImagesTests: XCTestCase {
    @MainActor
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor
    private func image() throws -> ChatImage {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 60,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        return try ChatImage(data: data, name: "Testbild.png")
    }

    @MainActor
    func testImageNormalizationAndBoundedFollowUpPayload() throws {
        let picture = try image()
        XCTAssertEqual(picture.preview.size, NSSize(width: 80, height: 60))
        XCTAssertEqual(Array(picture.jpeg.prefix(3)), [255, 216, 255])
        XCTAssertThrowsError(try ChatImage(data: Data("not an image".utf8), name: "kaputt.png"))
        let history = [ChatTurn(question: "Bildfrage", answer: "Ein Bild", images: [picture, picture, picture])]
        let request = CodexAsk.request(.question, question: "Und jetzt?", snapshot: AssistantSnapshot(),
                                       history: history, images: [picture, picture])
        let images = try XCTUnwrap(request["images"] as? [[String: String]])
        XCTAssertEqual(images.count, 4)
        XCTAssertTrue(images[0]["name"]!.hasPrefix("Frühere Nachricht:"))
        XCTAssertEqual(images[3]["name"], "Testbild.png")
        XCTAssertNil(CodexAsk.request(.asked, question: "", snapshot: AssistantSnapshot(), images: [picture])["images"])
    }

    @MainActor
    func testComposerPasteRemovalAndLiveKeepsInput() throws {
        _ = NSApplication.shared
        let assistant = AssistantPanel(presentation: AssistantPresentationGate(), snapshot: { AssistantSnapshot() })
        assistant.show()
        defer { assistant.panel.orderOut(nil) }
        let views = descendants(try XCTUnwrap(assistant.panel.contentView))
        let composer = try XCTUnwrap(views.compactMap { $0 as? ChatComposer }.first)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setData(try image().jpeg, forType: .png)
        XCTAssertTrue(composer.insertImages(from: pasteboard))
        var images = descendants(assistant.panel.contentView!).compactMap { $0 as? NSImageView }
        XCTAssertTrue(images.contains { $0.accessibilityLabel() == "Eingefügtes Bild" })
        let remove = try XCTUnwrap(descendants(assistant.panel.contentView!).compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel() == "Eingefügtes Bild entfernen" })
        remove.performClick(nil)
        images = descendants(assistant.panel.contentView!).compactMap { $0 as? NSImageView }
        XCTAssertFalse(images.contains { $0.accessibilityLabel() == "Eingefügtes Bild" })
        assistant.showLive()
        XCTAssertFalse(composer.isHiddenOrHasHiddenAncestor)
        composer.string = "Zwei\nZeilen"
        XCTAssertEqual(composer.string.components(separatedBy: "\n").count, 2)
        var sends = 0
        composer.onSend = { sends += 1 }
        composer.insertNewline(nil)
        XCTAssertEqual(sends, 1)
        assistant.panel.makeFirstResponder(composer)
        let selectAll = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: 0, windowNumber: assistant.panel.windowNumber, context: nil,
            characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        XCTAssertTrue(composer.performKeyEquivalent(with: selectAll))
        XCTAssertEqual(composer.selectedRange().length, (composer.string as NSString).length)
        composer.setSelectedRange(NSRange(location: (composer.string as NSString).length, length: 0))
        let newline = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift],
            timestamp: 0, windowNumber: assistant.panel.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        composer.keyDown(with: newline)
        XCTAssertTrue(composer.string.hasSuffix("\n"))
        XCTAssertEqual(sends, 1)
        assistant.attach(Array(repeating: try image(), count: 5))
        XCTAssertTrue(descendants(assistant.panel.contentView!).compactMap { $0 as? NSTextField }
            .contains { $0.stringValue.contains("Bis zu vier Bilder") })
    }

    @MainActor
    func testFailedQuestionPreservesImageDraft() async throws {
        _ = NSApplication.shared
        let assistant = AssistantPanel(presentation: AssistantPresentationGate(), snapshot: { AssistantSnapshot() })
        assistant.show()
        defer { assistant.panel.orderOut(nil) }
        let content = try XCTUnwrap(assistant.panel.contentView)
        let composer = try XCTUnwrap(descendants(content).compactMap { $0 as? ChatComposer }.first)
        composer.string = "Diesen Entwurf behalten"
        assistant.attach([try image()])
        let asked = try XCTUnwrap(descendants(content).compactMap { $0 as? NSButton }
            .first { $0.title == "Was wurde ich gerade gefragt?" })
        asked.performClick(nil)
        for _ in 0..<30 where !asked.isEnabled { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertTrue(asked.isEnabled)
        XCTAssertEqual(composer.string, "Diesen Entwurf behalten")
        XCTAssertTrue(descendants(content).compactMap { $0 as? NSImageView }
            .contains { $0.accessibilityLabel() == "Testbild.png" })
        XCTAssertTrue(descendants(content).compactMap { $0 as? NSTextField }
            .contains { $0.stringValue.contains("Fehler:") })
    }

    @MainActor
    func testFileURLPasteWinsOverFilenameButTextWinsOverPreviewImage() throws {
        let composer = ChatComposer(frame: .zero)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mitschrift-test-\(UUID()).jpg")
        defer { try? FileManager.default.removeItem(at: file) }
        try image().jpeg.write(to: file)
        var received: [ChatImage] = []
        composer.onImages = { received = $0 }
        pasteboard.writeObjects([file as NSURL])
        pasteboard.setString(file.lastPathComponent, forType: .string)
        XCTAssertTrue(composer.insertImages(from: pasteboard))
        XCTAssertEqual(received.first?.name, file.lastPathComponent)
        received = []
        pasteboard.clearContents()
        pasteboard.setString("Text aus einer Tabelle", forType: .string)
        pasteboard.setData(try image().jpeg, forType: .png)
        XCTAssertFalse(composer.insertImages(from: pasteboard))
        XCTAssertTrue(received.isEmpty)
    }

    @MainActor
    func testImagePickerOpensAndCanBeCancelled() async throws {
        _ = NSApplication.shared
        let assistant = AssistantPanel(presentation: AssistantPresentationGate(), snapshot: { AssistantSnapshot() })
        assistant.show()
        defer { assistant.panel.orderOut(nil) }
        let content = try XCTUnwrap(assistant.panel.contentView)
        let button = try XCTUnwrap(descendants(content).compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel() == "Bild anhängen" })
        button.performClick(nil)
        try await Task.sleep(for: .milliseconds(200))
        let picker = try XCTUnwrap(assistant.panel.attachedSheet as? NSOpenPanel)
        XCTAssertTrue(picker.allowsMultipleSelection)
        XCTAssertFalse(picker.canChooseDirectories)
        picker.cancel(nil)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(assistant.panel.attachedSheet)
    }

    @MainActor
    func testImageRequestCancelAndConnectionFailureDoNotCrash() async throws {
        signal(SIGPIPE, SIG_IGN)
        let pictures = Array(repeating: try image(), count: 4)
        let codex = CodexAsk(host: "mitschrift-test.invalid")
        codex.cancel()
        let pending = Task {
            try await codex.ask(.question, question: "Test", snapshot: AssistantSnapshot(), images: pictures)
        }
        pending.cancel()
        do {
            _ = try await pending.value
            XCTFail("Abgebrochene Anfrage darf nicht erfolgreich sein")
        } catch {}
        do {
            _ = try await codex.ask(.question, question: "Test", snapshot: AssistantSnapshot(), images: pictures)
            XCTFail("Reservierte .invalid-Domain darf nicht erreichbar sein")
        } catch {}
    }
}
