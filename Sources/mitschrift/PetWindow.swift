import AppKit

@MainActor
final class PetWindow {
    let assistant: AssistantPanel
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 44),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let presentation: AssistantPresentationGate
    private let pandaView = NSImageView()
    private let recordButton = NSButton()
    private let photoButton = NSButton()
    private let videoButton = NSButton()
    private let label = NSTextField(labelWithString: "Bereit")
    private let onPhoto: @MainActor () -> Void
    private let onToggle: @MainActor () -> Void
    private let onRecord: @MainActor () -> Void

    var privacyHidden: Bool { presentation.hidden }

    init(onPhoto: @escaping @MainActor () -> Void,
         onToggle: @escaping @MainActor () -> Void,
         onRecord: @escaping @MainActor () -> Void,
         snapshot: @escaping @MainActor () async -> AssistantSnapshot) {
        self.onPhoto = onPhoto
        self.onToggle = onToggle
        self.onRecord = onRecord
        let visibility = AssistantPresentationGate()
        presentation = visibility
        assistant = AssistantPanel(presentation: visibility, snapshot: snapshot)
        pandaView.image = PandaIcon.glyph(.ready, size: 20, color: .labelColor)
        pandaView.setAccessibilityLabel("Mitschrift, bereit")
        pandaView.widthAnchor.constraint(equalToConstant: 20).isActive = true
        pandaView.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let question = assistant.questionButton
        let live = NSButton(image: NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: "Live-Transkript")!,
                            target: self, action: #selector(liveTapped))
        live.toolTip = "Live-Transkript einblenden oder schließen"
        live.setAccessibilityLabel("Live-Transkript einblenden oder schließen")
        recordButton.target = self
        recordButton.action = #selector(recordTapped)
        photoButton.image = NSImage(systemSymbolName: "camera", accessibilityDescription: "Screenshot erstellen")
        photoButton.toolTip = "Screenshot vom geteilten Bildschirm erstellen"
        photoButton.setAccessibilityLabel("Screenshot erstellen")
        photoButton.target = self
        photoButton.action = #selector(photoTapped)
        videoButton.target = self
        videoButton.action = #selector(toggleTapped)
        let privacy = NSButton(image: NSImage(systemSymbolName: "eye.slash", accessibilityDescription: "Panda und Antworten verbergen")!,
                               target: self, action: #selector(privacyTapped))
        privacy.toolTip = "Panda und Antworten verbergen, über die Menüleiste wieder anzeigen"
        for button in [recordButton, videoButton, photoButton, question, live, privacy] {
            button.imagePosition = .imageOnly
            button.bezelStyle = .texturedRounded
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.lineBreakMode = .byTruncatingTail
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 150).isActive = true
        let controls = NSStackView(views: [pandaView, label, recordButton, videoButton, photoButton, question, live, privacy])
        controls.spacing = 8
        let surface = NSVisualEffectView()
        surface.material = .hudWindow
        surface.blendingMode = .behindWindow
        surface.state = .active
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 12
        surface.layer?.masksToBounds = true
        panel.contentView = surface
        controls.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(controls)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 8),
            controls.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -8),
            controls.centerYAnchor.constraint(equalTo: surface.centerYAnchor)
        ])
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        assistant.panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        apply(recording: false, video: false, shots: 0, elapsed: nil)
    }

    func apply(recording: Bool, video: Bool, shots: Int, elapsed: String?,
               paused: Bool = false, permissionDenied: Bool = false) {
        recordButton.image = NSImage(systemSymbolName: recording ? "stop.circle.fill" : "record.circle",
                                     accessibilityDescription: nil)
        recordButton.contentTintColor = recording ? .systemRed : .labelColor
        recordButton.toolTip = recording ? "Audioaufnahme beenden und speichern" : "Audioaufnahme starten"
        recordButton.setAccessibilityLabel(recordButton.toolTip)
        videoButton.image = NSImage(systemSymbolName: video ? "video.fill" : "video", accessibilityDescription: nil)
        videoButton.contentTintColor = video ? .systemRed : .labelColor
        videoButton.toolTip = video ? "Video beenden" : "Video aufnehmen"
        videoButton.setAccessibilityLabel(videoButton.toolTip)
        let state: PandaState = recording ? .recording : (paused || permissionDenied ? .paused : .ready)
        pandaView.image = PandaIcon.glyph(state, size: 20, color: permissionDenied ? .systemOrange : .labelColor)
        let status = (permissionDenied ? "Freigabe fehlt" : (paused ? "Pausiert" : (recording ? "Aufnahme " + (elapsed ?? "") : "Bereit")))
        label.stringValue = status
        label.toolTip = status + (video ? ", Video" : "") + (shots > 0 ? ", \(shots) Fotos" : "")
        pandaView.setAccessibilityLabel("Mitschrift, " + label.toolTip!)
        label.setAccessibilityLabel(label.toolTip!)
    }

    func confirm(success: Bool, shots: Int) {
        label.stringValue = success ? "Foto gespeichert" : "Foto fehlgeschlagen"
        label.toolTip = label.stringValue + ", \(shots) Fotos"
    }

    func show() {
        presentation.present {
            guard !panel.isVisible else { return }
            if let screen = NSScreen.main?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: screen.maxX - panel.frame.width - 24, y: screen.minY + 24))
            }
            panel.orderFrontRegardless()
        }
    }

    func hide() { panel.orderOut(nil) }

    func showAssistant(justAsked: Bool = false) {
        presentation.present { assistant.show(justAsked: justAsked) }
    }

    func showLive() { presentation.present { assistant.showLive() } }
    func refreshLocalViews() { assistant.refreshLocalViews() }

    func setPrivacyHidden(_ hidden: Bool) {
        presentation.setHidden(hidden)
        if hidden {
            assistant.hideForSharing()
            panel.orderOut(nil)
        } else { show() }
    }

    @objc private func photoTapped() { onPhoto() }
    @objc private func toggleTapped() { onToggle() }
    @objc private func recordTapped() { onRecord() }
    @objc private func liveTapped() { showLive() }
    @objc private func privacyTapped() { setPrivacyHidden(true) }
}
