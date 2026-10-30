import XCTest
import AppKit
@testable import mitschrift

@MainActor
final class ChatScrollTests: XCTestCase {
    func testReaderKeepsFullDocumentHeightForLongConversations() throws {
        let view = ChatTextView.reader()
        XCTAssertNil(view.textLayoutManager)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 400))
        view.isEditable = false
        view.textContainerInset = NSSize(width: 16, height: 16)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.autoresizingMask = [.width]
        scroll.documentView = view
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 6
        paragraph.paragraphSpacing = 12
        let text = NSMutableAttributedString()
        for index in 0..<60 {
            text.append(NSAttributedString(
                string: "Du\nFrage \(index) mit längerem Text, der umbrochen wird.\n\nLuna\nAntwort \(index) mit vielen Wörtern, damit der Absatz mehrere Zeilen füllt und das Fenster deutlich überragt.\n\n",
                attributes: [.font: NSFont.systemFont(ofSize: 16), .paragraphStyle: paragraph]))
        }
        view.textStorage?.setAttributedString(text)
        view.scrollToEndOfDocument(nil)
        scroll.layoutSubtreeIfNeeded()
        let container = try XCTUnwrap(view.textContainer)
        let manager = try XCTUnwrap(view.layoutManager)
        manager.ensureLayout(for: container)
        XCTAssertEqual(view.frame.height, manager.usedRect(for: container).height + 32, accuracy: 1)
        view.scrollToBeginningOfDocument(nil)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0, accuracy: 1)
    }
}
