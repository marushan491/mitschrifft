import AppKit
import ScreenCaptureKit
import SwiftUI

@main
@MainActor
final class PreviewApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let directory = Bundle.main.bundleURL.deletingLastPathComponent()
    private var trail: MeetingTrailWindow?
    private var pilot: MeetingTrailPilot?
    private var statusItem: NSStatusItem?
    private var fixtureActive = true
    private var noteFile: URL { directory.appendingPathComponent("note.json") }

    static func main() {
        let app = NSApplication.shared
        let preview = PreviewApp()
        app.delegate = preview
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(preview) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let modes = Set(CommandLine.arguments).intersection(["--proof", "--pilot-proof", "--capture-proof", "--layout-proof", "--answer-layout-proof"])
        guard !modes.isEmpty else {
            NSApp.terminate(nil)
            return
        }
        let trail = MeetingTrailWindow(file: noteFile)
        self.trail = trail
        trail.panel.delegate = self
        trail.show()
        NSApp.activate()
        if modes.contains("--answer-layout-proof") {
            Task {
                do {
                    try await verifyAnswerLayout(trail)
                    try writeReport("PASS lange Antwort, Rückfragebezug, Scrollen, Kopieren, Schließen, 414 und 350 pt",
                                    name: "answer-layout-result.txt")
                } catch {
                    try? writeReport("FAIL \(error.localizedDescription)", name: "answer-layout-result.txt")
                }
                NSApp.terminate(nil)
            }
        }
        if let settings = pilotSettings() {
            let pilot = MeetingTrailPilot(settings: settings, state: trail.state, presentPreview: { [weak trail] in trail?.show() })
            self.pilot = pilot
            installStatusItem()
            if CommandLine.arguments.contains("--pilot-proof") {
                Task {
                    do { try await verifyPilot(trail, pilot: pilot, settings: settings) }
                    catch { try? writeReport("FAIL \(error.localizedDescription)", name: "pilot-result.txt") }
                }
            }
            if CommandLine.arguments.contains("--capture-proof") {
                Task { await checkCapture(trail) }
            }
            if CommandLine.arguments.contains("--layout-proof") {
                Task {
                    do { try await verifyPilotLayout(trail) }
                    catch { try? writeReport("FAIL \(error.localizedDescription)", name: "layout-result.txt") }
                }
            }
        }
        if CommandLine.arguments.contains("--proof") {
            Task {
                do {
                    try await verify(trail)
                    try "PASS window=\(trail.panel.windowNumber) visible=\(trail.panel.isVisible) activeSpace=\(trail.panel.isOnActiveSpace) pid=\(ProcessInfo.processInfo.processIdentifier)\n"
                        .write(to: directory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
                } catch {
                    try? "FAIL \(error)\n".write(to: directory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
                }
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        if pilot == nil { NSApp.terminate(nil) }
        else { trail?.setHidden(true) }
    }

    private func pilotSettings() -> MeetingTrailSettings? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("pilot.json")) else { return nil }
        return try? JSONDecoder().decode(MeetingTrailSettings.self, from: data)
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "list.bullet.rectangle", accessibilityDescription: "Gesprächsspur")
        let menu = NSMenu()
        let toggle = NSMenuItem(title: "Gesprächsspur ein- oder ausblenden", action: #selector(toggleWindow), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        let quit = NSMenuItem(title: "Gesprächsspur beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    @objc private func toggleWindow() {
        guard let trail else { return }
        trail.setHidden(trail.panel.isVisible)
    }

    private func verifyPilot(_ trail: MeetingTrailWindow, pilot: MeetingTrailPilot,
                             settings: MeetingTrailSettings) async throws {
        let state = settings.recordingDirectory
        try require(state.deletingLastPathComponent() == directory, "Eigener Test-Aufnahmeordner erforderlich")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withColonSeparatorInTime]
        let rid = formatter.string(from: Date())
        let file = state.appendingPathComponent("partial/\(rid).jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let header = try JSONSerialization.data(withJSONObject: ["kind": "header", "id": rid,
            "startedAt": rid, "apps": ["Microsoft Teams (synthetisch)"]])
        try (header + Data([10])).write(to: file, options: .withoutOverwriting)
        try appendFixture("Für die fiktive Raumstation wurde die runde Landemarke beschlossen. Jo entwirft die Markierung. Die Entscheidung über den Durchmesser steht jetzt an.", seconds: 8, file: file)
        try pulse(state: state, rid: rid)
        let heartbeat = Task {
            while !Task.isCancelled {
                try? pulse(state: state, rid: rid)
                do { try await Task.sleep(for: .seconds(3)) }
                catch { return }
            }
        }
        defer { heartbeat.cancel() }
        trail.state.project = settings.projects.first ?? ""
        pilot.arm()
        try await waitFor(seconds: 100) { pilot.updates.count == 1 }
        try require(trail.panel.isVisible && trail.panel.isOnActiveSpace, "Fenster im Mac-Login")
        try require(trail.state.note?.hasProjectContext == false, "Ausfall Projektwissen")
        let firstHint = trail.state.hint == "Eine Entscheidung steht an"
        try await screenshot(trail, "21-entscheidung")
        try writeReport("Erstes Update da. Warte auf Zweiminutentakt.", name: "pilot-progress.txt")
        try appendFixture("Themenwechsel: Beleuchtung des Modellhangars. Alex, gleich entscheiden wir zwischen Dauerlicht und Pulsen. Die Wartung ist noch offen.", seconds: 133, file: file)
        try await waitFor(seconds: 190) { pilot.updates.count == 2 }
        try require(pilot.updates[0].id == pilot.updates[1].id, "Ein Agent für beide Aktualisierungen")
        try require(trail.state.note?.topics.count == 2, "Zwei Themen in der Zeitspur")
        try require(trail.state.hint == "Dein Name ist gefallen", "Lautloser Namenshinweis")
        try await screenshot(trail, "22-name")
        pilot.ask("Welche Landemarke wurde beschlossen?")
        try await waitFor(seconds: 100) { trail.state.answer != nil }
        try require(trail.state.answer?.localizedCaseInsensitiveContains("rund") == true, "Antwort zur Landemarke in der Blase")
        try require(pilot.recentSession != nil && pilot.recentSession != pilot.updates[0].id, "Eigene Sol-Sitzung für die Frage")
        try await screenshot(trail, "23-antwort")
        fixtureActive = false
        try pulse(state: state, rid: rid)
        try await waitFor(seconds: 20) { trail.state.note?.ended == true }
        try require(trail.state.note?.recapSaved == true, "Abschluss in Projekt-Testnotiz")
        try require(!trail.state.canAsk && !trail.state.armed, "Zeitplan nach Ende gestoppt")
        try await screenshot(trail, "24-abschluss")
        let interval = Int(pilot.updates[1].at.timeIntervalSince(pilot.updates[0].at))
        try writeReport("PASS window=\(trail.panel.windowNumber) session=\(pilot.updates[0].id) recording=\(rid) interval=\(interval)s decisionHint=\(firstHint) ended=true",
                        name: "pilot-result.txt")
    }

    private func appendFixture(_ text: String, seconds: Int, file: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "kind": "segment", "track": "system", "start": seconds, "end": seconds + 7, "text": text])
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data + Data([10]))
    }

    private func verifyPilotLayout(_ trail: MeetingTrailWindow) async throws {
        try require(!trail.state.armed, "Keine automatische Aktivierung durch den Start")
        trail.setHidden(true)
        trail.show()
        try require(!trail.panel.isVisible, "Ausgeblendet bleibt ausgeblendet")
        trail.setHidden(false)
        try require(trail.panel.isVisible && trail.panel.isOnActiveSpace, "Einblenden am Mac")
        try await screenshot(trail, trail.state.note?.ended == true ? "26-abschluss" : "27-bereit")
        try writeReport("PASS Mac-Fenster, Aktivierung aus, manueller Freigabeschutz", name: "layout-result.txt")
    }

    private func verifyAnswerLayout(_ trail: MeetingTrailWindow) async throws {
        let point = "Die Landemarke muss bei schwachem Licht erkennbar bleiben."
        let topic = MeetingTrailNote.Topic(id: "signal", seconds: 16, title: "Sichtbarkeit der Landemarke",
            points: [point, "Der Hangar hat zwei Lichtzonen."],
            suggestion: "Können wir die Markierung in beiden Lichtzonen ausprobieren?",
            reason: "So sehen wir, ob sie überall lesbar bleibt.")
        var note = MeetingTrailNote(version: 1, meetingID: "antwort-layout", goal: "Markierung für das Modell festlegen",
                                   project: "Testprojekt", hasProjectContext: true, topics: [topic])
        note.meetingTitle = "Synthetische Hangarprobe"
        note.contextLabel = "Testprojekt / Projektnotiz / Glossar"
        note.terms = ["Landemarke bezeichnet hier die sichtbare Markierung im Hangar."]
        note.decisions = ["Die Lage der Markierung bleibt gleich."]
        note.openPoints = ["Wie wirkt der Kontrast bei Dämmerung?"]
        note.tasks = ["Eine Probe in beiden Zonen machen."]
        note.basis = ["Das Modell hat eine helle und eine dunkle Zone."]
        try JSONEncoder().encode(note).write(to: noteFile, options: .atomic)
        trail.state.refresh()
        try await Task.sleep(for: .milliseconds(200))
        trail.state.canAsk = true
        let question = "Wie überprüfen wir, ob die markierte Stelle in beiden Zonen sichtbar bleibt?"
        let answer = """
        Beginnt mit derselben Markierung in beiden Lichtzonen. Beurteilt sie aus der Position, aus der sie später erkannt werden soll.

        Haltet Abstand und Blickwinkel konstant. Prüft zuerst, ob sich die Umrisse klar vom Boden abheben, und anschließend, ob die Form bei gedämpftem Licht verständlich bleibt.

        Wenn die schlechte Beleuchtung den Kontrast zu stark senkt, testet eine hellere Kante mit demselben Material. Eine Aufnahme aus gleicher Position macht die beiden Varianten vergleichbar.

        Schlussprüfung: Wiederholt den Test mit der freigegebenen Einstellung.
        """
        var prompt = ""
        trail.state.ask = { prompt = $0 }
        func submit() {
            trail.state.prepareQuestion(about: point)
            trail.state.questionDraft = question
            trail.state.submitQuestion()
            trail.state.answer = answer
        }
        submit()
        try require(prompt.contains(question) && prompt.contains(point), "Frage und Bezug werden gemeinsam gesendet")
        try require(trail.state.submittedQuestion?.text == question, "Gesendete Frage bleibt sichtbar")
        try require(trail.state.submittedQuestion?.reference == point, "Stichpunkt bleibt am Antwortbezug")
        try await screenshot(trail, "31-antwort")

        trail.panel.appearance = NSAppearance(named: .aqua)
        trail.panel.setContentSize(NSSize(width: 350, height: 486))
        trail.state.answer = nil
        try await Task.sleep(for: .milliseconds(200))
        submit()
        try await screenshot(trail, "32-schmal-oben")
        guard let content = trail.panel.contentView, let scroll = firstScroll(in: content),
              let document = scroll.documentView else { throw CocoaError(.fileReadUnknown) }
        let clip = scroll.contentView
        let start = clip.bounds.minY
        let maximum = max(document.bounds.minY, document.bounds.maxY - clip.bounds.height)
        let end = document.isFlipped ? maximum : document.bounds.minY
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: end))
        scroll.reflectScrolledClipView(clip)
        try require(abs(clip.bounds.minY - start) > 8, "Lange Antwort ist zusätzlich scrollbar")
        try await screenshot(trail, "33-schmal-unten")
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        trail.state.copy(answer, to: pasteboard)
        try require(pasteboard.string(forType: .string) == answer, "Vollständige Antwort kopiert")
        trail.state.dismissAnswer()
        try require(trail.state.answer == nil && trail.state.submittedQuestion == nil && trail.state.canAsk, "Schließen lässt das Fragefeld verfügbar")
        try await screenshot(trail, "34-geschlossen")
    }

    private func firstScroll(in view: NSView) -> NSScrollView? {
        (view as? NSScrollView) ?? view.subviews.lazy.compactMap(firstScroll(in:)).first
    }

    private func pulse(state: URL, rid: String) throws {
        var payload: [String: Any] = [
            "status": fixtureActive ? "recording" : "idle",
            "pid": ProcessInfo.processInfo.processIdentifier, "instance_id": "synthetic-preview",
            "updated_at": Date().timeIntervalSince1970]
        if fixtureActive { payload["recording_id"] = rid }
        try JSONSerialization.data(withJSONObject: payload)
            .write(to: state.appendingPathComponent("live-state.json"), options: .atomic)
    }

    private func checkCapture(_ trail: MeetingTrailWindow) async {
        let frame = trail.panel.frame.insetBy(dx: -22, dy: -22)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Synthetische Fensterfreigabe"
        window.collectionBehavior = [.moveToActiveSpace]
        window.isReleasedWhenClosed = false
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor(srgbRed: 0.08, green: 0.22, blue: 0.26, alpha: 1).cgColor
        let label = NSTextField(labelWithString: "Mitschrift Testfenster")
        label.font = .systemFont(ofSize: 28, weight: .semibold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        if let content = window.contentView {
            content.addSubview(label)
            NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                                         label.centerYAnchor.constraint(equalTo: content.centerYAnchor)])
        }
        window.setFrame(frame, display: true)
        window.orderFront(nil)
        trail.panel.orderFrontRegardless()
        defer { window.close() }
        do {
            try await Task.sleep(for: .milliseconds(350))
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let source = content.windows.first(where: { $0.windowID == window.windowNumber }) else {
                throw NSError(domain: "Gesprächsspur", code: 2, userInfo: [NSLocalizedDescriptionKey: "Testfenster fehlt im Aufnahmedienst"])
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
            try data.write(to: directory.appendingPathComponent("25-fensterfreigabe.png"), options: .atomic)
            try writeReport("PASS Filter für das eigene Testfenster; Gesprächsspur-Fenster sichtbar=\(trail.panel.isVisible)",
                            name: "capture-result.txt")
        } catch {
            try? writeReport("FAIL \(error.localizedDescription)", name: "capture-result.txt")
        }
    }

    private func writeReport(_ message: String, name: String) throws {
        try (message + "\n").write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func verify(_ trail: MeetingTrailWindow) async throws {
        try require(trail.panel.isVisible && trail.panel.isOnActiveSpace, "Fenster auf aktivem Schreibtisch")
        try require(trail.state.waiting && trail.state.note == nil, "Wartezustand")

        let intro = MeetingTrailNote.Topic(id: "layers", seconds: 817, title: "ADR-0032: Ebenen",
            points: ["Schnittstellen wirken als Sammelmodul zu breit.", "Abhängigkeiten sollen nach unten zeigen."],
            suggestion: nil, reason: nil)
        let work = MeetingTrailNote.Topic(id: "processes", seconds: 2108, title: "Geschäftsvorfälle",
            points: ["Ein Vorgang kann mehrere Fachmodule aufrufen.", "Die Zuordnung beim Abschluss ist offen."],
            suggestion: "Können wir die Ebenen am Abschluss erklären?", reason: "Am Beispiel wird die Grenze greifbar.")
        let export = MeetingTrailNote.Topic(id: "export", seconds: 2335, title: "GDV-Export",
            points: ["Exporte können Daten aus mehreren Modulen brauchen.", "Die konkrete Zuordnung bleibt offen."],
            suggestion: "Welche Fachmodule liefern die Daten für den GDV-Export?",
            reason: "Die Datenquellen helfen bei der Zuordnung.")

        try publish([intro, work], hasContext: true)
        try await waitFor { trail.state.latest == work }
        trail.panel.appearance = NSAppearance(named: .aqua)
        try await screenshot(trail, "01-gerade")
        try require(trail.panel.contentView?.bounds.height == 486, "Ausgeklappte Ansicht bleibt sichtbar")
        trail.state.select(intro)
        try publish([intro, work, export], hasContext: false)
        try await waitFor { trail.state.latest == export }
        try require(trail.state.selected == intro, "Rückblick übersteht neues Thema")
        try require(trail.state.hasNewTopic, "Punkt meldet neues Thema")
        try require(trail.state.note?.hasProjectContext == false, "Projektwissen fehlt")
        try await screenshot(trail, "02-rueckblick")

        trail.toggle()
        try require(!trail.state.expanded && trail.panel.frame.height < 100, "Schmale Leiste")
        try await screenshot(trail, "03-leiste")
        trail.toggle()
        trail.state.select(export)
        try require(!trail.state.hasNewTopic && trail.state.selected == export, "Zurück zu Jetzt")
        try await screenshot(trail, "04-ohne-projektwissen")

        try Data("{".utf8).write(to: noteFile, options: .atomic)
        try await waitFor { trail.state.waiting }
        try require(trail.state.latest == export, "Letzter guter Stand bei ungültiger Datei")
        try await screenshot(trail, "05-notiz-fehlt")
        try publish([intro, work, export], hasContext: false)
        try await waitFor { !trail.state.waiting }

        let size = trail.panel.contentView?.bounds.size ?? NSSize(width: 414, height: 486)
        trail.panel.appearance = NSAppearance(named: .darkAqua)
        trail.panel.setContentSize(NSSize(width: 342, height: size.height))
        try await screenshot(trail, "06-schmal-dunkel")
        trail.panel.setContentSize(size)
        trail.panel.appearance = nil
        trail.show()
    }

    private func publish(_ topics: [MeetingTrailNote.Topic], hasContext: Bool) throws {
        let note = MeetingTrailNote(version: 1, meetingID: "architektur-vorschau", goal: "ADRs abstimmen",
                                    project: nil, hasProjectContext: hasContext, topics: topics)
        try JSONEncoder().encode(note).write(to: noteFile, options: .atomic)
    }

    private func waitFor(seconds: Int = 3, _ ready: () -> Bool) async throws {
        for _ in 0..<(seconds * 8) {
            if ready() { return }
            try await Task.sleep(for: .milliseconds(125))
        }
        try require(false, "Dateiaktualisierung")
    }

    private func screenshot(_ trail: MeetingTrailWindow, _ name: String) async throws {
        try await Task.sleep(for: .milliseconds(180))
        guard let view = trail.panel.contentView else { throw CocoaError(.fileWriteUnknown) }
        view.layoutSubtreeIfNeeded()
        trail.panel.displayIfNeeded()
        guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        view.cacheDisplay(in: view.bounds, to: image)
        guard let data = image.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
    }

    private func require(_ passed: Bool, _ check: String) throws {
        guard passed else {
            throw NSError(domain: "Gesprächsspur", code: 1, userInfo: [NSLocalizedDescriptionKey: check])
        }
    }
}

@MainActor
final class MeetingTrailWindow {
    let panel: NSPanel
    let state: MeetingTrailState
    private var manuallyHidden = false
    private let presentation: AssistantPresentationGate

    init(file: URL, presentation: AssistantPresentationGate? = nil) {
        self.presentation = presentation ?? AssistantPresentationGate()
        state = MeetingTrailState(file: file)
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 414, height: 486),
                        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "Gesprächsspur"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.sharingType = .none
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 340, height: 68)
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let hosting = NSHostingController(rootView: MeetingTrailView(
            state: state, toggle: { [weak self] in self?.toggle() },
            resize: { [weak self] in self?.resizeToContents() }))
        hosting.sizingOptions = []
        panel.contentViewController = hosting
        panel.setContentSize(NSSize(width: 414, height: contentHeight))
    }

    func show(focus: Bool = true) {
        guard !presentation.hidden, !manuallyHidden else { return }
        if let frame = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - panel.frame.width - 24, y: frame.maxY - 36))
        }
        if focus { panel.makeKeyAndOrderFront(nil) }
        else { panel.orderFrontRegardless() }
    }

    func setHidden(_ hidden: Bool) {
        manuallyHidden = hidden
        if hidden { panel.orderOut(nil) }
        else { show() }
    }

    func toggle() {
        state.toggle()
        resizeToContents()
    }

    private var contentHeight: CGFloat {
        if !state.expanded { return 46 }
        return state.note?.topics.isEmpty != false && state.note?.ended != true ? 206 : 486
    }

    private func resizeToContents() {
        let oldFrame = panel.frame
        let content = NSRect(x: 0, y: 0, width: oldFrame.width, height: contentHeight)
        let height = panel.frameRect(forContentRect: content).height
        panel.setFrame(NSRect(x: oldFrame.minX, y: oldFrame.maxY - height, width: oldFrame.width, height: height),
                       display: true)
    }
}
