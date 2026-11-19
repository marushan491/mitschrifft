#if MEETING_TRAIL_PROOF
import AppKit
import ScreenCaptureKit

@MainActor
enum MeetingTrailProof {
    static func run(in folder: URL) {
        Task {
            do {
                let result = if FileManager.default.fileExists(atPath: folder.appendingPathComponent("pilot.json").path) {
                    try await verify(in: folder)
                } else {
                    try await verifyPanel(in: folder)
                }
                try write(result, as: "result.txt", in: folder)
            } catch {
                try? write("FAIL \(error.localizedDescription)", as: "result.txt", in: folder)
            }
            NSApp.terminate(nil)
        }
        NSApp.run()
    }

    private static func verifyPanel(in folder: URL) async throws -> String {
        let title = "Synthetischer Termin zum Modellhangar"
        let app = MenuBarApp(config: Config())
        app.configureWindows(trailFolder: folder.appendingPathComponent("cache"), settings: nil, snapshot: {
            AssistantSnapshot(elapsed: 55, meeting: title, recording: true, recordingID: "test")
        })
        guard let trail = app.trail, let assistant = app.assistant else { throw CocoaError(.fileReadUnknown) }
        let panel = assistant.panel
        panel.setFrameAutosaveName("")
        panel.setContentSize(NSSize(width: 620, height: 650))
        panel.appearance = NSAppearance(named: .darkAqua)
        assistant.setTrailTransparency(false)
        trail.status = nil
        let point = "Die Landemarke muss in beiden Lichtzonen zu erkennen sein."
        let note = MeetingTrailNote(version: 1, meetingID: "test", goal: "Markierung für den Modellhangar festlegen",
                                    project: "Modellhangar", hasProjectContext: true, topics: [
            .init(id: "A", seconds: 12, title: "Größe der Markierung",
                  points: ["Die Markierung soll auf die Modellplatte passen."], suggestion: nil, reason: nil),
            .init(id: "B", seconds: 47, title: "Sichtbarkeit der Landemarke",
                  points: [point, "Der Hangar hat zwei Lichtzonen."],
                  suggestion: "Können wir die Markierung in beiden Lichtzonen ausprobieren?",
                  reason: "So sehen wir, ob sie überall lesbar bleibt.")
        ], terms: ["Landemarke: sichtbarer Bezugspunkt für die Landung."],
           decisions: ["Die Markierung wird rund."], contextLabel: "Modellhangar / Projektnotiz / Glossar",
           meetingTitle: title)
        try JSONEncoder().encode(note).write(to: trail.file, options: .atomic)
        trail.refresh()
        trail.canAsk = true
        app.renderTrail(recordingID: "test", title: title)
        NSApp.activate()
        try require(assistant.isShowingTrail && panel.sharingType == .none, "Spur öffnet im geschützten Chatfenster")
        let windowNumber = panel.windowNumber
        try await screenshot(panel, name: "01-spur", in: folder)
        guard let tabs = panel.contentView.flatMap(segmentedControl), let change = tabs.action else {
            throw CocoaError(.fileReadUnknown)
        }
        try require((0..<tabs.segmentCount).compactMap { tabs.label(forSegment: $0) } == ["Live", "Chat", "Spur"], "Drei Reiter")
        tabs.selectedSegment = 1
        try require(NSApp.sendAction(change, to: tabs.target, from: tabs), "Chat auswählen")
        try require(panel.isVisible && !assistant.isShowingTrail && panel.windowNumber == windowNumber, "Chat nutzt dasselbe Fenster")
        try await screenshot(panel, name: "02-chat", in: folder)
        tabs.selectedSegment = 0
        try require(NSApp.sendAction(change, to: tabs.target, from: tabs) && panel.windowNumber == windowNumber, "Live nutzt dasselbe Fenster")
        try await screenshot(panel, name: "04-live", in: folder)
        let menu = NSMenu()
        menu.autoenablesItems = false
        app.menuNeedsUpdate(menu)
        try require(sendFirst(menu) && assistant.isShowingTrail && panel.windowNumber == windowNumber, "Menü öffnet Spur im selben Fenster")
        trail.prepareQuestion(about: point)
        trail.questionDraft = "Wie prüfen wir die Sichtbarkeit in beiden Lichtzonen?"
        let answer = """
        Stellt in beiden Lichtzonen dieselbe Markierung auf. Betrachtet sie aus dem Abstand, aus dem sie später erkannt werden soll.

        Haltet Abstand und Blickwinkel konstant. Prüft zuerst, ob sich die Umrisse klar vom Boden abheben. Wiederholt die Prüfung bei gedämpftem Licht.

        Wenn der Kontrast zu stark sinkt, vergleicht eine hellere Kante aus demselben Material. Fotografiert beide Varianten aus gleicher Position.
        """
        var sent = ""
        trail.ask = { sent = $0; trail.answer = answer }
        trail.submitQuestion()
        try require(sent.contains(point) && trail.answer == answer, "Punktfrage und Antwort bleiben im Spur-Reiter")
        trail.ask = nil
        panel.appearance = NSAppearance(named: .aqua)
        panel.setContentSize(NSSize(width: 460, height: 530))
        assistant.setTrailTransparency(true)
        try await screenshot(panel, name: "03-punktfrage-schmal", in: folder)
        trail.dismissAnswer()
        let capture = await captureWindow(beneath: panel, in: folder)
        try write(capture, as: "capture-result.txt", in: folder)
        try require(capture.hasPrefix("PASS"), capture)
        app.setPrivacyHidden(true)
        assistant.showTrail(automatic: true)
        try require(!panel.isVisible, "Datenschutz blockiert das erneute Öffnen")
        return "PASS Live, Chat und Spur im selben Fenster. Punktfrage, Menü, Transparenz und Datenschutz geprüft."
    }

    private static func segmentedControl(in view: NSView) -> NSSegmentedControl? {
        (view as? NSSegmentedControl) ?? view.subviews.lazy.compactMap { segmentedControl(in: $0) }.first
    }

    private static func verify(in folder: URL) async throws -> String {
        let settings = try JSONDecoder().decode(MeetingTrailSettings.self,
            from: Data(contentsOf: folder.appendingPathComponent("pilot.json")))
        let source = settings.recordingDirectory
        try require(source.deletingLastPathComponent() == folder, "Testquelle außerhalb des Privattests")
        try require(source.lastPathComponent == "fixture", "Synthetische Aufnahme erforderlich")

        let app = MenuBarApp(config: Config())
        app.configureWindows(trailFolder: folder.appendingPathComponent("cache"), settings: settings)
        guard let trail = app.trail, let assistant = app.assistant, let pilot = app.trailPilot else {
            throw NSError(domain: "Mitschrift", code: 1, userInfo: [NSLocalizedDescriptionKey: "Gesprächsspur fehlt"])
        }
        defer { pilot.stop() }
        let id = String(Int(Date().timeIntervalSince1970))
        let title = "Synthetischer Termin zum Modellhangar"
        let partial = source.appendingPathComponent("partial/\(id).jsonl")
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        let header = try JSONSerialization.data(withJSONObject: ["kind": "header", "id": id, "apps": ["Teams-Test"]])
        try (header + Data([10])).write(to: partial, options: .withoutOverwriting)
        try append("Das Testmodell bekommt eine runde Landemarke. Die Markierung ist entschieden.", at: 12, to: partial)

        app.renderTrail(recordingID: id, title: title)
        NSApp.activate()
        try await Task.sleep(for: .milliseconds(240))
        try require(assistant.panel.isVisible && assistant.panel.isOnActiveSpace && !trail.armed, "Automatisches Öffnen ohne Datentransfer")
        try require(assistant.panel.sharingType == .none, "Window-Sharing-Flag")
        let menu = NSMenu()
        menu.autoenablesItems = false
        app.menuNeedsUpdate(menu)
        try require(menu.items.first?.title == "Gesprächsspur ausblenden", "Menü-Eintrag")
        try require(sendFirst(menu), "Menü-Eintrag ausführen")
        try require(!assistant.panel.isVisible, "Menü blendet aus")
        app.menuNeedsUpdate(menu)
        try require(menu.items.first?.title == "Gesprächsspur einblenden", "Menü-Eintrag aktualisiert")
        try require(sendFirst(menu) && assistant.panel.isVisible, "Menü blendet ein")
        app.setPrivacyHidden(true)
        assistant.showTrail()
        try require(!assistant.panel.isVisible, "Gemeinsamer Datenschutz blockiert erneutes Öffnen")
        app.setPrivacyHidden(false)
        assistant.showTrail()
        let capture = await captureWindow(beneath: assistant.panel, in: folder)
        try write(capture, as: "capture-result.txt", in: folder)

        try pulse(source: source, id: id)
        let heartbeat = Task {
            while !Task.isCancelled {
                try? pulse(source: source, id: id)
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
        defer { heartbeat.cancel() }
        trail.project = settings.projects.first ?? ""
        pilot.arm()
        try await wait("Luna-Kontext", state: trail) { !pilot.updates.isEmpty }
        guard let note = trail.note, let point = note.topics.first?.points.first,
              let workspace = note.workspaceID, let label = note.contextLabel else {
            throw NSError(domain: "Mitschrift", code: 2, userInfo: [NSLocalizedDescriptionKey: "Projektquelle oder Notiz fehlt"])
        }
        try require(label.contains("Projektnotiz") && label.contains("Glossar") && label.contains("1 PR"), "Kontextzeile")
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        trail.copy(point, to: pasteboard)
        try require(pasteboard.string(forType: .string) == point, "Stichpunkt in Zwischenablage")
        try append("Neue Meldung. Der Live-Code lautet ZINN.", at: 41, to: partial)
        trail.prepareQuestion(about: point)
        try require(trail.questionReference == String(point.prefix(220)), "Dazu fragen übernimmt den Stichpunkt")
        try await screenshot(assistant.panel, name: "02-punktfrage", in: folder)
        trail.questionDraft = "Lies Live-Code per Mitschrift-MCP, Werkstatt-Code aus Werkstatt.txt und Projektcode per read_project_note. Nenne alle drei Werte."
        trail.submitQuestion()
        try await wait("Sol-Antwort", state: trail) { trail.answer != nil }
        let answer = trail.answer ?? ""
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write(answer, as: "answer.txt", in: folder)
        try require(["ZINN", "KIESEL", "BRONZE"].allSatisfy { answer.localizedCaseInsensitiveContains($0) }, "Antwort aus Live-MCP, Workspace und Vault")
        let luna = pilot.updates[0].id
        guard let sol = pilot.recentSession, sol != luna else {
            throw NSError(domain: "Mitschrift", code: 3, userInfo: [NSLocalizedDescriptionKey: "Sol-Sitzung fehlt"])
        }
        try await screenshot(assistant.panel, name: "03-sol-antwort", in: folder)
        assistant.panel.appearance = NSAppearance(named: .aqua)
        assistant.setTrailTransparency(true)
        let size = assistant.panel.contentView!.bounds.size
        assistant.panel.setContentSize(NSSize(width: 460, height: size.height))
        try await screenshot(assistant.panel, name: "04-schmal-hell", in: folder)
        return "PASS menu=true privacy=true clipboard=true project=\(workspace) luna=\(luna) sol=\(sol) capture=\(capture.hasPrefix("PASS"))"
    }

    private static func sendFirst(_ menu: NSMenu) -> Bool {
        guard let item = menu.items.first, let action = item.action else { return false }
        return NSApp.sendAction(action, to: item.target, from: item)
    }

    private static func pulse(source: URL, id: String) throws {
        let values: [String: Any] = ["status": "recording", "recording_id": id, "instance_id": "fixture",
                                    "updated_at": Date().timeIntervalSince1970, "pid": ProcessInfo.processInfo.processIdentifier]
        try JSONSerialization.data(withJSONObject: values)
            .write(to: source.appendingPathComponent("live-state.json"), options: .atomic)
    }

    private static func append(_ text: String, at seconds: Int, to file: URL) throws {
        let content = try JSONSerialization.data(withJSONObject: ["kind": "segment", "start": seconds,
            "end": seconds + 4, "track": "system", "text": text])
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: content + Data([10]))
    }

    private static func wait(_ phase: String, state: MeetingTrailState, ready: () -> Bool) async throws {
        for _ in 0..<440 {
            if ready() { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        try require(false, "\(phase): \(state.status ?? "Zeitlimit")")
    }

    private static func screenshot(_ panel: NSPanel, name: String, in folder: URL) async throws {
        try await Task.sleep(for: .milliseconds(250))
        guard let view = panel.contentView else { throw CocoaError(.fileWriteUnknown) }
        view.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: folder.appendingPathComponent(name + ".png"), options: .atomic)
    }

    private static func captureWindow(beneath panel: NSPanel, in folder: URL) async -> String {
        let frame = panel.frame.insetBy(dx: -22, dy: -22)
        let target = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        target.title = "Synthetische Mitschrift-Fensterfreigabe"
        target.isReleasedWhenClosed = false
        target.setFrame(frame, display: true)
        let label = NSTextField(labelWithString: "Geteiltes Testfenster")
        label.font = .systemFont(ofSize: 25, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        if let content = target.contentView {
            content.addSubview(label)
            NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                                         label.centerYAnchor.constraint(equalTo: content.centerYAnchor)])
        }
        target.orderFront(nil)
        panel.orderFrontRegardless()
        defer { target.close() }
        do {
            try await Task.sleep(for: .milliseconds(350))
            let shareable = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let source = shareable.windows.first(where: { $0.windowID == target.windowNumber }) else {
                return "FAIL Testfenster fehlt in ScreenCaptureKit"
            }
            let config = SCStreamConfiguration()
            config.width = Int(source.frame.width)
            config.height = Int(source.frame.height)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: source), configuration: config)
            guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try data.write(to: folder.appendingPathComponent("01-fensteraufnahme.png"), options: .atomic)
            return "PASS echte ScreenCaptureKit-Fensteraufnahme; Blase lokal sichtbar=\(panel.isVisible)"
        } catch {
            return "FAIL \(error.localizedDescription)"
        }
    }

    private static func require(_ passed: Bool, _ message: String) throws {
        guard passed else { throw NSError(domain: "Gesprächsspur", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    private static func write(_ value: String, as name: String, in folder: URL) throws {
        try (value + "\n").write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}
#endif
