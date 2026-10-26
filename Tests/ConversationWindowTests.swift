import AppKit
import XCTest
@testable import mitschrift

final class ConversationWindowTests: XCTestCase {
    @MainActor
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor
    private func fixture() throws -> ChatImage {
        let image = NSImage(size: NSSize(width: 480, height: 220), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: 30, y: 75, width: 100, height: 100)).fill()
            NSColor.systemBlue.setFill()
            NSBezierPath(rect: NSRect(x: 170, y: 75, width: 100, height: 100)).fill()
            ("Synthetisches Testbild" as NSString).draw(at: NSPoint(x: 30, y: 25), withAttributes: [
                .font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.black
            ])
            return true
        }
        return try ChatImage(data: XCTUnwrap(image.tiffRepresentation), name: "Formen, synthetischer Test")
    }

    @MainActor
    func testWindowLayoutAtMinimumInBothThemes() async throws {
        _ = NSApplication.shared
        let snapshot = AssistantSnapshot(segments: [Segment(track: .system, start: 10, end: 15,
            text: "Synthetischer Test: Bitte prüfe das angehängte Bild.")],
            elapsed: 20, meeting: "Synthetische Besprechung", recording: true, startedAt: Date())
        let assistant = AssistantPanel(presentation: AssistantPresentationGate(), snapshot: { snapshot })
        assistant.panel.setFrameAutosaveName("")
        assistant.show()
        defer { assistant.panel.orderOut(nil) }
        assistant.attach(Array(repeating: try fixture(), count: 4))
        let content = try XCTUnwrap(assistant.panel.contentView)
        let composer = try XCTUnwrap(descendants(content).compactMap { $0 as? ChatComposer }.first)
        composer.string = "Was ist auf dem Bild zu sehen?\nBitte fasse es kurz zusammen."
        composer.didChangeText()
        for theme in [NSAppearance.Name.aqua, .darkAqua] {
            assistant.panel.appearance = NSAppearance(named: theme)
            for size in [NSSize(width: 620, height: 700), NSSize(width: 460, height: 640)] {
                assistant.panel.setContentSize(size)
                content.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(120))
                for view in descendants(content) where !view.isHiddenOrHasHiddenAncestor &&
                    (view is NSButton || view is NSSegmentedControl || view === composer.enclosingScrollView) {
                    let bounds = view.convert(view.bounds, to: content)
                    XCTAssertGreaterThanOrEqual(bounds.minX, -1, "\(view)")
                    XCTAssertLessThanOrEqual(bounds.maxX, content.bounds.maxX + 1, "\(view)")
                    XCTAssertGreaterThanOrEqual(bounds.minY, -1, "\(view)")
                    XCTAssertLessThanOrEqual(bounds.maxY, content.bounds.maxY + 1, "\(view)")
                }
                XCTAssertGreaterThan(composer.enclosingScrollView!.frame.width, 300)
                if let folder = ProcessInfo.processInfo.environment["MITSCHRIFT_UI_EVIDENCE"] {
                    descendants(content).forEach { $0.needsDisplay = true }
                    assistant.panel.displayIfNeeded()
                    let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                    content.cacheDisplay(in: content.bounds, to: rep)
                    try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to:
                        URL(fileURLWithPath: folder).appendingPathComponent("layout-\(Int(size.width))-\(theme.rawValue).png"))
                }
            }
        }
        assistant.showLive()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(composer.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(descendants(content).compactMap { $0 as? NSTextView }
            .contains { $0.string.contains("Synthetischer Test: Bitte prüfe") })
        if let folder = ProcessInfo.processInfo.environment["MITSCHRIFT_UI_EVIDENCE"] {
            assistant.panel.appearance = NSAppearance(named: .aqua)
            assistant.panel.setContentSize(NSSize(width: 620, height: 700))
            content.layoutSubtreeIfNeeded()
            descendants(content).forEach { $0.needsDisplay = true }
            assistant.panel.displayIfNeeded()
            let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to:
                URL(fileURLWithPath: folder).appendingPathComponent("live-mitschrift.png"))
        }
    }

    @MainActor
    func testReadingSurfaceContrastInBothThemes() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            appearance.performAsCurrentDrawingAppearance {
                let background = NSColor.textBackgroundColor.usingColorSpace(.sRGB)!
                func luminance(_ color: NSColor) -> Double {
                    let rgb = color.usingColorSpace(.sRGB)!
                    let alpha = Double(rgb.alphaComponent)
                    let channels = zip([rgb.redComponent, rgb.greenComponent, rgb.blueComponent],
                                       [background.redComponent, background.greenComponent, background.blueComponent])
                        .map { foreground, back -> Double in
                            let value = Double(foreground) * alpha + Double(back) * (1 - alpha)
                            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
                        }
                    return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
                }
                for color in [ChatColors.ink, ChatColors.secondary] {
                    let first = luminance(color)
                    let second = luminance(background)
                    let ratio = (max(first, second) + 0.05) / (min(first, second) + 0.05)
                    print("Reading contrast \(name.rawValue): \(ratio)")
                    XCTAssertGreaterThanOrEqual(ratio, 4.5)
                }
            }
        }
    }

    @MainActor
    func testLiveCopyButtonAndAnalysisCommandValidation() async throws {
        _ = NSApplication.shared
        let snapshot = AssistantSnapshot(segments: [Segment(track: .system, start: 10, end: 15,
            text: "Synthetische kopierbare Mitschrift")], elapsed: 20, recording: true, startedAt: Date())
        let assistant = AssistantPanel(presentation: AssistantPresentationGate(), snapshot: { snapshot })
        assistant.showLive()
        defer { assistant.panel.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(100))
        let content = try XCTUnwrap(assistant.panel.contentView)
        let copy = try XCTUnwrap(descendants(content).compactMap { $0 as? NSButton }
            .first { $0.title == "Mitschrift kopieren" })
        XCTAssertTrue(copy.isEnabled)
        copy.performClick(nil)
        XCTAssertTrue(NSPasteboard.general.string(forType: .string)?.contains("Synthetische kopierbare Mitschrift") == true)
        assistant.show()
        let input = try XCTUnwrap(descendants(content).compactMap { $0 as? ChatComposer }.first)
        input.string = "/analyse"
        let send = try XCTUnwrap(descendants(content).compactMap { $0 as? NSButton }.first { $0.title == "Senden" })
        send.performClick(nil)
        XCTAssertTrue(send.isEnabled)
        XCTAssertTrue(descendants(content).compactMap { $0 as? NSTextField }
            .contains { $0.stringValue.contains("Schreib hinter /analyse") })
    }

    @MainActor
    func testRealImageChatAndWindowEvidence() async throws {
        guard let folder = ProcessInfo.processInfo.environment["MITSCHRIFT_UI_EVIDENCE"] else {
            throw XCTSkip("Echter Bildlauf und Fensterbelege nur mit MITSCHRIFT_UI_EVIDENCE")
        }
        _ = NSApplication.shared
        let assistant = AssistantPanel(presentation: AssistantPresentationGate(), snapshot: { AssistantSnapshot() })
        assistant.panel.setFrameAutosaveName("")
        assistant.panel.setContentSize(NSSize(width: 620, height: 700))
        assistant.show()
        defer { assistant.panel.orderOut(nil) }
        assistant.attach([try fixture()])
        let content = try XCTUnwrap(assistant.panel.contentView)
        let composer = try XCTUnwrap(descendants(content).compactMap { $0 as? ChatComposer }.first)
        let send = try XCTUnwrap(descendants(content).compactMap { $0 as? NSButton }.first { $0.title == "Senden" })
        composer.string = "Beschreibe die Farben und Formen im angehängten Bild. Keine Dateien lesen."
        composer.didChangeText()
        send.performClick(nil)
        for _ in 0..<120 where !send.isEnabled { try await Task.sleep(for: .seconds(1)) }
        XCTAssertTrue(send.isEnabled)
        let answer = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTextView }
            .first { $0 !== composer && $0.string.contains("Luna") })
        XCTAssertTrue(answer.string.localizedCaseInsensitiveContains("rot"), answer.string)
        XCTAssertTrue(answer.string.localizedCaseInsensitiveContains("blau"), answer.string)
        XCTAssertTrue(answer.string.localizedCaseInsensitiveContains("kreis"), answer.string)
        XCTAssertTrue(composer.string.isEmpty)
        let copy = try XCTUnwrap(descendants(content).compactMap { $0 as? NSButton }
            .first { $0.title == "Antwort kopieren" })
        copy.performClick(nil)
        XCTAssertTrue(NSPasteboard.general.string(forType: .string)?.localizedCaseInsensitiveContains("kreis") == true)
        composer.string = "Und wie unterscheiden sie sich?"
        composer.didChangeText()
        for theme in [NSAppearance.Name.aqua, .darkAqua] {
            assistant.panel.appearance = NSAppearance(named: theme)
            content.layoutSubtreeIfNeeded()
            descendants(content).forEach { $0.needsDisplay = true }
            assistant.panel.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(250))
            let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to:
                URL(fileURLWithPath: folder).appendingPathComponent("chat-\(theme.rawValue).png"))
            assistant.panel.sharingType = .readOnly
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String(assistant.panel.windowNumber),
                URL(fileURLWithPath: folder).appendingPathComponent("window-\(theme.rawValue).png").path]
            let problem = Pipe()
            capture.standardError = problem
            try capture.run()
            capture.waitUntilExit()
            assistant.panel.sharingType = .none
            print("Native window screenshot \(theme.rawValue): \(capture.terminationStatus), " +
                String(decoding: problem.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
    }

    @MainActor
    func testExplicitAnalysisStartsIndependentPandaOSSession() async throws {
        guard ProcessInfo.processInfo.environment["MITSCHRIFT_ANALYSIS_SMOKE"] == "1" else {
            throw XCTSkip("PandaOS-Session-Start nur mit MITSCHRIFT_ANALYSIS_SMOKE=1")
        }
        _ = NSApplication.shared
        let assistant = AssistantPanel(presentation: AssistantPresentationGate(), snapshot: { AssistantSnapshot() })
        assistant.show()
        defer { assistant.panel.orderOut(nil) }
        let content = try XCTUnwrap(assistant.panel.contentView)
        let input = try XCTUnwrap(descendants(content).compactMap { $0 as? ChatComposer }.first)
        input.string = "/analyse Synthetischer Mitschrift-Funktionstest: Was ist 2 plus 2? Antworte nur mit 4. Keine Aktionen außerhalb dieser Analyse ausführen."
        let send = try XCTUnwrap(descendants(content).compactMap { $0 as? NSButton }.first { $0.title == "Senden" })
        send.performClick(nil)
        for _ in 0..<90 where !send.isEnabled { try await Task.sleep(for: .seconds(1)) }
        XCTAssertTrue(send.isEnabled)
        let open = try XCTUnwrap(descendants(content).compactMap { $0 as? NSButton }
            .first { $0.title == "Analyse in PandaOS öffnen" })
        XCTAssertFalse(open.isHidden)
        XCTAssertTrue(input.string.isEmpty)
        open.performClick(nil)
        for _ in 0..<30 where !send.isEnabled { try await Task.sleep(for: .seconds(1)) }
        XCTAssertTrue(send.isEnabled)
        XCTAssertTrue(descendants(content).compactMap { $0 as? NSTextField }
            .contains { $0.stringValue == "Analyse in PandaOS geöffnet." })
    }
}
