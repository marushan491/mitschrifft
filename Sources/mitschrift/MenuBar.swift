import AVFoundation
import AppKit
import CoreGraphics
import Foundation

@MainActor
final class MenuBarApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var supervisor: Supervisor?
    private var ticker: Timer?
    private var pet: PetWindow?
    private let presentation = AssistantPresentationGate()
    private(set) var trail: MeetingTrailState?
    var assistant: AssistantPanel? { pet?.assistant }
    private(set) var trailPilot: MeetingTrailPilot?
    private var shownRecording: String?
    private var photoHotKey: HotKey?
    private let config: Config

    init(config: Config) {
        self.config = config
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        SharedChat.clear()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self

        configureWindows()
        photoHotKey = HotKey(shortcut: config.photoHotKey) { [weak self] in self?.takePhoto() }

        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        let micText: String
        switch mic {
        case .authorized: micText = "erteilt"
        case .denied: micText = "ABGELEHNT"
        case .restricted: micText = "eingeschraenkt"
        case .notDetermined: micText = "NOCH NIE GEFRAGT"
        @unknown default: micText = "unbekannt"
        }
        log("Bildschirmrecht im Dienst: \(CGPreflightScreenCaptureAccess() ? "erteilt" : "FEHLT"), Mikrofonrecht: \(micText)")

        if mic == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                log("Mikrofonrecht nach Anfrage: \(granted ? "erteilt" : "abgelehnt")")
            }
        }

        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
        render()

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let locale = try await CLI.prepareLocale(self.config)
                let supervisor = Supervisor(config: self.config, locale: locale)
                supervisor.onChange = { [weak self] in self?.render() }
                supervisor.onRecordingEnded = { [weak self] id, saved in
                    self?.trailPilot?.recordingEnded(id, saved: saved)
                }
                supervisor.begin()
                self.supervisor = supervisor
                self.render()
            } catch {
                log("Start fehlgeschlagen: \(error.localizedDescription)")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        trailPilot?.stop()
        SharedChat.clear()
        LiveState.clear()
        ticker?.invalidate()
    }

    func configureWindows(trailFolder: URL = Config.stateDirectory.appendingPathComponent("meeting-trail"),
                          settings: MeetingTrailSettings? = MeetingTrailSettings.load(),
                          snapshot: (@MainActor () async -> AssistantSnapshot)? = nil) {
        try? FileManager.default.createDirectory(at: trailFolder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let trail = MeetingTrailState(file: trailFolder.appendingPathComponent("note.json"))
        self.trail = trail
        trail.reviewSpeaker = { [weak self] action in
            await self?.supervisor?.reviewSpeaker(action) ??
                SpeakerReviewResponse(message: "Mitschrift startet noch.")
        }
        if let settings {
            trailPilot = MeetingTrailPilot(settings: settings, state: trail)
            trailPilot?.onGlossary = { [weak self] id, terms in
                await self?.supervisor?.setGlossary(terms, recordingID: id)
            }
        } else {
            trail.status = "Notiz-Agent ist nicht eingerichtet."
        }
        pet = PetWindow(onPhoto: { [weak self] in self?.takePhoto() },
                        onToggle: { [weak self] in self?.toggleVideo() },
                        onRecord: { [weak self] in self?.toggleRecording() },
                        snapshot: snapshot ?? { [weak self] in
                            await self?.supervisor?.assistantSnapshot() ?? AssistantSnapshot()
                        },
                        presentation: presentation, trail: trail)
    }

    func renderTrail(recordingID: String?, title: String?) {
        guard let recordingID else { return }
        trailPilot?.recordingStarted(recordingID, title: title)
        if shownRecording != recordingID {
            shownRecording = recordingID
            assistant?.showTrail(automatic: true)
        }
    }

    private func render() {
        guard let button = statusItem.button else { return }
        guard let supervisor else {
            button.image = PandaIcon.menuBar(.paused)
            button.title = ""
            button.toolTip = "Mitschrift startet ..."
            return
        }

        let state: PandaState
        if supervisor.isRecording {
            state = .recording
        } else if !supervisor.automaticEnabled || supervisor.isPaused {
            state = .paused
        } else {
            state = .ready
        }

        button.image = PandaIcon.menuBar(state)

        if supervisor.isRecording, let start = supervisor.recordingStart {
            button.title = " " + formatClock(Date().timeIntervalSince(start))
        } else {
            button.title = ""
        }
        button.toolTip = "Mitschrift: \(supervisor.statusText)"

        let elapsed = supervisor.recordingStart.map { formatClock(Date().timeIntervalSince($0)) }
        pet?.apply(recording: supervisor.isRecording,
                   video: supervisor.videoRunning,
                   shots: supervisor.shotCount,
                   elapsed: elapsed,
                   paused: supervisor.isPaused || !supervisor.automaticEnabled,
                   permissionDenied: supervisor.screenPermissionDenied)
        pet?.refreshLocalViews()
        pet?.show()
        renderTrail(recordingID: supervisor.recordingID, title: supervisor.meetingTitle)
    }

    private func toggleRecording() {
        guard let supervisor else { return }
        Task {
            if supervisor.isRecording { await supervisor.stopAndSave() }
            else { await supervisor.startManually() }
        }
    }

    private func toggleVideo() {
        guard let supervisor else { return }
        Task { await supervisor.toggleVideo() }
    }

    private func takePhoto() {
        guard let supervisor else { return }
        Task {
            let result = await supervisor.capturePhoto()
            pet?.confirm(success: result.hasPrefix("Foto gemacht"), shots: supervisor.shotCount)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let trail {
            menu.addItem(action(assistant?.isShowingTrail == true ? "Gesprächsspur ausblenden" : "Gesprächsspur einblenden",
                                #selector(toggleTrail)))
            let opacity = action("Gesprächsspur leicht transparent", #selector(toggleTrailTransparency))
            opacity.state = trail.translucent ? .on : .off
            menu.addItem(opacity)
        }

        guard let supervisor else {
            let item = NSMenuItem(title: "Mitschrift startet ...", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return
        }

        let status = NSMenuItem(title: supervisor.statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        if supervisor.screenPermissionDenied {
            let hint = NSMenuItem(title: "Mitschrift darf den Bildschirm nicht aufnehmen",
                                  action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
            menu.addItem(action("Systemeinstellungen oeffnen", #selector(openScreenSettings)))
            menu.addItem(action("Erneut versuchen", #selector(resumeAutomatic)))
            menu.addItem(.separator())
        }

        if let error = supervisor.lastError, !supervisor.screenPermissionDenied {
            let item = NSMenuItem(title: "Letzter Fehler: \(error)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(action("Was wurde ich gerade gefragt?", #selector(assistantQuestion), key: "j"))
        menu.addItem(action("Chat…", #selector(assistantOpen)))
        menu.addItem(action("Live-Transkript anzeigen", #selector(assistantLive)))
        let privateDisplay = action("Mitschrift-Fenster beim Teilen verbergen", #selector(togglePrivateDisplay))
        privateDisplay.state = pet?.privacyHidden == true ? .on : .off
        menu.addItem(privateDisplay)

        if supervisor.isRecording {
            menu.addItem(action("Foto vom geteilten Bildschirm", #selector(photoFromMenu), key: "2"))
            menu.addItem(action(supervisor.videoRunning ? "Video beenden" : "Video aufnehmen", #selector(videoFromMenu)))
            menu.addItem(action("Aufnahme beenden und speichern", #selector(stopAndSave), key: "s"))
            menu.addItem(action("Aufnahme verwerfen", #selector(discard)))
        } else {
            menu.addItem(action("Jetzt aufnehmen", #selector(startNow), key: "r"))
        }

        menu.addItem(.separator())

        let automatic = action("Automatik bei Besprechungen", #selector(toggleAutomatic))
        automatic.state = supervisor.automaticEnabled && !supervisor.isPaused ? .on : .off
        menu.addItem(automatic)

        if supervisor.isPaused || !supervisor.automaticEnabled {
            menu.addItem(action("Automatik wieder einschalten", #selector(resumeAutomatic)))
        } else {
            let pause = NSMenu()
            for minutes in [30, 60, 120] {
                let item = action("\(minutes) Minuten", #selector(pauseFor))
                item.tag = minutes
                pause.addItem(item)
            }
            let parent = NSMenuItem(title: "Pause", action: nil, keyEquivalent: "")
            parent.submenu = pause
            menu.addItem(parent)
        }

        menu.addItem(.separator())

        let count = NSMenuItem(title: "Heute \(supervisor.notesToday) Transkripte", action: nil, keyEquivalent: "")
        count.isEnabled = false
        menu.addItem(count)

        if supervisor.lastNote != nil {
            menu.addItem(action("Letztes Transkript oeffnen", #selector(openLast)))
        }
        menu.addItem(action("Alle Transkripte in Obsidian", #selector(openVault), key: "o"))
        menu.addItem(action("Ordner im Finder zeigen", #selector(openFolder)))

        menu.addItem(.separator())
        menu.addItem(action("Mitschrift beenden", #selector(quit), key: "q"))
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func openScreenSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    @objc private func assistantQuestion() { pet?.showAssistant(justAsked: true) }

    @objc private func assistantOpen() { pet?.showAssistant() }
    @objc private func assistantLive() { pet?.showLive() }
    @objc private func toggleTrail() {
        guard let assistant else { return }
        if assistant.isShowingTrail { assistant.panel.orderOut(nil) }
        else { assistant.showTrail() }
    }
    @objc private func toggleTrailTransparency() {
        guard let trail else { return }
        let translucent = !trail.translucent
        assistant?.setTrailTransparency(translucent)
        UserDefaults.standard.set(translucent, forKey: "meetingTrail.translucent")
    }
    func setPrivacyHidden(_ value: Bool) { pet?.setPrivacyHidden(value) }
    @objc private func togglePrivateDisplay() { setPrivacyHidden(!presentation.hidden) }

    @objc private func photoFromMenu() {
        takePhoto()
    }

    @objc private func videoFromMenu() { toggleVideo() }

    @objc private func startNow() {
        guard let supervisor else { return }
        Task { await supervisor.startManually() }
    }

    @objc private func stopAndSave() {
        guard let supervisor else { return }
        Task { await supervisor.stopAndSave() }
    }

    @objc private func discard() {
        guard let supervisor else { return }
        Task { await supervisor.discardRecording() }
    }

    @objc private func toggleAutomatic() {
        guard let supervisor else { return }
        if supervisor.automaticEnabled && !supervisor.isPaused {
            supervisor.automaticEnabled = false
        } else {
            supervisor.resumeAutomatic()
        }
        render()
    }

    @objc private func resumeAutomatic() {
        guard let supervisor else { return }
        supervisor.resumeAutomatic()
        render()
    }

    @objc private func pauseFor(_ sender: NSMenuItem) {
        guard let supervisor else { return }
        supervisor.pause(minutes: sender.tag)
        render()
    }

    @objc private func openLast() {
        guard let note = supervisor?.lastNote else { return }
        openInObsidian(relativePath: relativeToVault(note)) 
    }

    @objc private func openVault() {
        let base = URL(fileURLWithPath: config.vaultPath)
            .appendingPathComponent(config.notesFolder + ".base")
        if FileManager.default.fileExists(atPath: base.path) {
            openInObsidian(relativePath: config.notesFolder + ".base")
        } else {
            NSWorkspace.shared.open(config.notesDirectory)
        }
    }

    @objc private func openFolder() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: config.notesDirectory.path)
    }

    @objc private func quit() {
        Task {
            await supervisor?.shutdown()
            NSApp.terminate(nil)
        }
    }

    private func relativeToVault(_ url: URL) -> String {
        let vault = URL(fileURLWithPath: config.vaultPath).standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(vault) else { return url.lastPathComponent }
        return String(path.dropFirst(vault.count).drop(while: { $0 == "/" }))
    }

    private func openInObsidian(relativePath: String) {
        let vaultName = URL(fileURLWithPath: config.vaultPath).lastPathComponent
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        components.queryItems = [
            URLQueryItem(name: "vault", value: vaultName),
            URLQueryItem(name: "file", value: relativePath)
        ]
        guard let url = components.url, NSWorkspace.shared.open(url) else {
            NSWorkspace.shared.open(config.notesDirectory)
            return
        }
    }
}
