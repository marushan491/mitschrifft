import AppKit
import UniformTypeIdentifiers

private final class AssistantWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class ComposerSurface: NSStackView {
    override func draw(_ dirtyRect: NSRect) {
        (NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            ? NSColor.textBackgroundColor : ChatColors.surface).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()
        super.draw(dirtyRect)
    }
}

@MainActor
final class AssistantPanel: NSObject, NSWindowDelegate {
    let panel: NSPanel
    let questionButton = NSButton()
    private let presentation: AssistantPresentationGate
    private let snapshot: @MainActor () async -> AssistantSnapshot
    private let codex = CodexAsk(config: Config.load())
    private let panes = NSSegmentedControl()
    private let liveView = ChatTextView.reader()
    private let liveScroll = NSScrollView()
    private let askedButton = NSButton(title: "Was wurde ich gerade gefragt?", target: nil, action: nil)
    private let query = ChatComposer(frame: .zero)
    private let sendButton = NSButton(title: "Fragen", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Abbrechen", target: nil, action: nil)
    private let clearButton = NSButton(title: "Neuer Chat", target: nil, action: nil)
    private let copyButton = NSButton(title: "Antwort kopieren", target: nil, action: nil)
    private let analysisButton = NSButton(title: "Analyse in PandaOS öffnen", target: nil, action: nil)
    private let targetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var targetsLoadedAt: Date?
    private var loadingTargets = false
    private var analysisSessionID: String?
    private var analysisRequestKey = ""
    private var analysisRequestID: String?
    private let status = NSTextField(labelWithString: "")
    private let answerView = ChatTextView.reader()
    private let answerScroll = NSScrollView()
    private let surface = NSVisualEffectView()
    private let meetingStatus = NSTextField(labelWithString: "Bereit für deine Frage")
    private let imageButton = NSButton(title: "Bild", target: nil, action: nil)
    private let shotButton = NSButton(title: "Screenshot", target: nil, action: nil)
    private let previews = NSStackView()
    private let commandHints = NSStackView()
    private var showingHelp = false
    private var draftImages: [ChatImage] = []
    private var pendingImages: [ChatImage] = []
    private var capturing = false
    private var restoreAfterCapture = false
    private var screenshotProcess: Process?
    private var task: Task<Void, Never>?
    private var ticker: Timer?
    private var conversation = AssistantConversation()
    private var pendingQuestion: String?
    private var refreshing = false

    init(presentation: AssistantPresentationGate,
         snapshot: @escaping @MainActor () async -> AssistantSnapshot) {
        self.presentation = presentation
        self.snapshot = snapshot
        panel = AssistantWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 700),
                                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        panel.delegate = self
        panel.title = "Mitschrift"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.sharingType = .none
        panel.minSize = NSSize(width: 460, height: 660)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.titlebarAppearsTransparent = true
        surface.material = .hudWindow
        surface.blendingMode = .behindWindow
        surface.state = .active
        surface.wantsLayer = true
        panel.contentView = surface
        updateTransparency()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(updateTransparency),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)

        panes.segmentCount = 2
        panes.setLabel("Live-Mitschrift", forSegment: 0)
        panes.setLabel("Chat", forSegment: 1)
        panes.selectedSegment = 1
        panes.target = self
        panes.action = #selector(paneChanged)
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        copyButton.imagePosition = .imageLeading
        copyButton.bezelStyle = .rounded
        copyButton.target = self
        copyButton.action = #selector(copyTapped)
        analysisButton.bezelStyle = .rounded
        analysisButton.target = self
        analysisButton.action = #selector(openAnalysisTapped)
        analysisButton.isHidden = true

        configure(liveView, in: liveScroll)
        configure(answerView, in: answerScroll)

        questionButton.image = NSImage(systemSymbolName: "questionmark.bubble",
                                       accessibilityDescription: "Was wurde ich gerade gefragt?")
        questionButton.toolTip = "Chat mit Luna öffnen"
        questionButton.target = self
        questionButton.action = #selector(chatTapped)
        questionButton.setAccessibilityLabel("Chat mit Luna öffnen")
        askedButton.image = NSImage(systemSymbolName: "questionmark.bubble", accessibilityDescription: nil)
        askedButton.imagePosition = .imageLeading
        askedButton.bezelStyle = .rounded
        askedButton.target = self
        askedButton.action = #selector(askedTapped)

        query.onSend = { [weak self] in self?.sendTapped() }
        query.onImages = { [weak self] in self?.attach($0) }
        query.onError = { [weak self] in self?.status.stringValue = $0 }
        query.onTextChange = { [weak self] in self?.updateCommandHints() }
        query.onComplete = { [weak self] in self?.completeCommand() ?? false }
        sendButton.bezelStyle = .rounded
        sendButton.keyEquivalent = "\r"
        sendButton.keyEquivalentModifierMask = []
        sendButton.target = self
        sendButton.action = #selector(sendTapped)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.isHidden = true
        clearButton.bezelStyle = .rounded
        clearButton.target = self
        clearButton.action = #selector(clearTapped)
        sendButton.title = "Senden"
        sendButton.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: nil)
        sendButton.imagePosition = .imageTrailing
        sendButton.bezelColor = .controlAccentColor
        sendButton.setAccessibilityLabel("Nachricht senden")
        for (button, symbol, action, label) in [
            (imageButton, "paperclip", #selector(imageTapped), "Bild anhängen"),
            (shotButton, "camera", #selector(shotTapped), "Screenshot anhängen")
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
            button.setAccessibilityLabel(label)
            button.toolTip = label
        }
        imageButton.keyEquivalent = "o"
        imageButton.keyEquivalentModifierMask = [.command]
        shotButton.keyEquivalent = "s"
        shotButton.keyEquivalentModifierMask = [.command, .shift]
        status.textColor = ChatColors.secondary
        status.font = .systemFont(ofSize: 12)
        status.stringValue = "Luna nutzt Mitschrift, Bilder und Second Brain erst beim Senden."
        status.lineBreakMode = .byWordWrapping
        status.maximumNumberOfLines = 2

        let panda = NSImageView(image: PandaIcon.glyph(.ready, size: 30, color: .labelColor))
        panda.widthAnchor.constraint(equalToConstant: 30).isActive = true
        panda.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let title = NSTextField(labelWithString: "Dein Gespräch")
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        meetingStatus.font = .systemFont(ofSize: 12)
        meetingStatus.textColor = ChatColors.secondary
        meetingStatus.lineBreakMode = .byTruncatingTail
        meetingStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let heading = NSStackView(views: [title, meetingStatus])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 3
        let header = NSStackView(views: [panda, heading, NSView(), clearButton])
        header.spacing = 12

        let body = NSView()
        for scroll in [answerScroll, liveScroll] {
            scroll.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(scroll)
            NSLayoutConstraint.activate([
                scroll.leadingAnchor.constraint(equalTo: body.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: body.trailingAnchor),
                scroll.topAnchor.constraint(equalTo: body.topAnchor),
                scroll.bottomAnchor.constraint(equalTo: body.bottomAnchor)
            ])
        }
        body.setContentHuggingPriority(.defaultLow, for: .vertical)

        let editor = NSScrollView()
        editor.documentView = query
        editor.drawsBackground = false
        editor.hasVerticalScroller = true
        editor.heightAnchor.constraint(equalToConstant: 64).isActive = true
        query.minSize = NSSize(width: 0, height: 64)
        query.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        previews.spacing = 8
        previews.alignment = .top
        previews.isHidden = true
        let tools = NSStackView(views: [imageButton, shotButton, NSView(), cancelButton, sendButton])
        tools.spacing = 8
        commandHints.orientation = .vertical
        commandHints.alignment = .leading
        commandHints.spacing = 2
        commandHints.isHidden = true
        let compose = ComposerSurface(views: [previews, commandHints, editor, tools])
        compose.orientation = .vertical
        compose.alignment = .leading
        compose.spacing = 10
        compose.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        compose.wantsLayer = true
        compose.layer?.cornerRadius = 14
        for view in [previews, commandHints, editor, tools] {
            view.widthAnchor.constraint(equalTo: compose.widthAnchor, constant: -24).isActive = true
        }
        let hint = NSTextField(labelWithString: "Enter sendet, ⇧ Enter für eine neue Zeile. /help zeigt alle Befehle.")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = ChatColors.secondary
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 2
        let navigation = NSStackView(views: [panes, NSView(), copyButton])
        navigation.spacing = 8
        let actions = NSStackView(views: [askedButton, NSView(), analysisButton])
        actions.spacing = 8
        let targetLabel = NSTextField(labelWithString: "Analyse in")
        targetLabel.font = .systemFont(ofSize: 12)
        targetLabel.textColor = ChatColors.secondary
        targetPopup.controlSize = .small
        targetPopup.font = .systemFont(ofSize: 12)
        targetPopup.setAccessibilityLabel("Ziel für /analyse")
        targetPopup.toolTip = "Neue Session, Projekt oder bestehende PandaOS-Session für /analyse"
        targetPopup.addItem(withTitle: Self.defaultTargetTitle)
        targetPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let targetRow = NSStackView(views: [targetLabel, targetPopup])
        targetRow.spacing = 8
        let stack = NSStackView(views: [header, navigation, body, actions, targetRow, status, compose, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(stack)
        if let content = panel.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
            ])
        }
        for view in [header, navigation, body, actions, targetRow, status, compose, hint] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        panel.setFrameAutosaveName("MitschriftGespräch")
        render()
        paneChanged()
    }

    private func configure(_ text: NSTextView, in scroll: NSScrollView) {
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 16, height: 16)
        text.font = .systemFont(ofSize: 16)
        text.textColor = ChatColors.ink
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 6
        paragraph.paragraphSpacing = 12
        text.defaultParagraphStyle = paragraph
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.autoresizingMask = [.width]
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            ? .textBackgroundColor : ChatColors.surface
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 12
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
    }

    private static let defaultTargetTitle = "Neue Session (Standard)"

    private var selectedTarget: AnalysisTarget? {
        targetPopup.selectedItem?.representedObject as? AnalysisTarget
    }

    private func loadTargets() {
        guard !loadingTargets, targetsLoadedAt.map({ Date().timeIntervalSince($0) > 300 }) ?? true else { return }
        loadingTargets = true
        Task { @MainActor in
            defer { loadingTargets = false }
            guard let list = try? await codex.targets() else { return }
            targetsLoadedAt = Date()
            fillTargetMenu(list)
        }
    }

    private func fillTargetMenu(_ list: AnalysisTargets) {
        let keep = selectedTarget
        let menu = NSMenu()
        menu.addItem(withTitle: Self.defaultTargetTitle, action: nil, keyEquivalent: "")
        for (header, items) in [("Projekt, neue Session", list.projects), ("Bestehende Session", list.sessions)]
        where !items.isEmpty {
            menu.addItem(.separator())
            menu.addItem(NSMenuItem.sectionHeader(title: header))
            for target in items {
                let item = NSMenuItem(title: target.name, action: nil, keyEquivalent: "")
                item.representedObject = target
                item.toolTip = target.detail
                menu.addItem(item)
            }
        }
        targetPopup.menu = menu
        if let keep, let index = menu.items.firstIndex(where: {
            ($0.representedObject as? AnalysisTarget).map { $0.kind == keep.kind && $0.id == keep.id } ?? false
        }) {
            targetPopup.selectItem(at: index)
        } else {
            targetPopup.selectItem(at: 0)
        }
    }

    func show(justAsked: Bool = false) {
        panes.selectedSegment = 1
        paneChanged()
        present(focus: !justAsked)
        loadTargets()
        if justAsked { run(.asked) }
    }

    func showLive() {
        if panel.isVisible, panes.selectedSegment == 0 {
            panel.orderOut(nil)
            return
        }
        panes.selectedSegment = 0
        paneChanged()
        present(focus: false)
    }

    func hideForSharing() {
        restoreAfterCapture = false
        cancelTapped()
        panel.orderOut(nil)
    }

    func refreshLocalViews() {
        guard panel.isVisible, !refreshing else { return }
        refreshing = true
        Task { @MainActor in
            defer { refreshing = false }
            let current = await snapshot()
            meetingStatus.stringValue = current.recording
                ? "\(current.meeting ?? "Besprechung")   \(formatClock(current.elapsed))"
                : "Ohne Aufnahme mit Luna schreiben"
            if task == nil, conversation.update(for: current) { render() }
            guard panes.selectedSegment == 0 else { return }
            let atBottom = (liveScroll.documentVisibleRect.maxY >= (liveView.frame.height - 24))
            let text = MeetingText.live(current)
            if liveView.string != text {
                liveView.string = text
                if atBottom { liveView.scrollToEndOfDocument(nil) }
            }
            copyButton.isEnabled = current.recording && !current.segments.isEmpty
        }
    }

    private func present(focus: Bool) {
        presentation.present {
            if !panel.isVisible { panel.center() }
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            if focus, panes.selectedSegment == 1 { panel.makeFirstResponder(query) }
        }
        refreshLocalViews()
    }

    @objc private func paneChanged() {
        let live = panes.selectedSegment == 0
        liveScroll.isHidden = !live
        answerScroll.isHidden = live
        copyButton.title = live ? "Mitschrift kopieren" : "Antwort kopieren"
        copyButton.setAccessibilityLabel(copyButton.title)
        copyButton.isEnabled = live ? !liveView.string.isEmpty : !conversation.turns.isEmpty
        refreshLocalViews()
    }

    @objc private func copyTapped() {
        let text = panes.selectedSegment == 0 ? liveView.string : conversation.turns.last?.answer ?? ""
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copyButton.title = "Kopiert"
        copyButton.setAccessibilityLabel(panes.selectedSegment == 0 ? "Mitschrift kopiert" : "Antwort kopiert")
        status.stringValue = panes.selectedSegment == 0 ? "Mitschrift kopiert." : "Antwort kopiert."
    }

    @objc private func chatTapped() { show() }

    @objc private func clearTapped() {
        guard task == nil, !capturing else { return }
        conversation.clear()
        showingHelp = false
        analysisSessionID = nil
        analysisRequestID = nil
        analysisButton.isHidden = true
        draftImages = []
        query.string = ""
        query.undoManager?.removeAllActions()
        query.didChangeText()
        renderPreviews()
        render()
        panel.makeFirstResponder(query)
    }

    @objc private func askedTapped() {
        if !panel.isVisible || panes.selectedSegment != 1 {
            show(justAsked: true)
        } else {
            run(.asked)
        }
    }

    @objc private func sendTapped() {
        let question = query.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty || !draftImages.isEmpty else { return }
        if question == "/help" {
            showHelp()
            return
        }
        if let command = question.split(whereSeparator: \.isWhitespace).first.map(String.init),
           command.dropFirst().allSatisfy(\.isLetter), command.count > 1, command.hasPrefix("/"),
           !SlashCommand.all.contains(where: { $0.name == command.lowercased() }) {
            if command == question, completeCommand() { return }
            status.stringValue = "Unbekannter Befehl \(command). /help zeigt alle Befehle."
            return
        }
        if question == "/analyse" || question.hasPrefix("/analyse ") || question.hasPrefix("/analyse\n") {
            let topic = String(question.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !topic.isEmpty else {
                status.stringValue = "Schreib hinter /analyse, was geprüft werden soll."
                return
            }
            let key = question + draftImages.map { $0.id.uuidString }.joined() + (selectedTarget.map { $0.kind + $0.id } ?? "")
            if analysisRequestID == nil || analysisRequestKey != key {
                analysisRequestKey = key
                analysisRequestID = UUID().uuidString
            }
            panes.selectedSegment = 1
            paneChanged()
            run(.analysis, question: topic)
            return
        }
        panes.selectedSegment = 1
        paneChanged()
        run(.question, question: question.isEmpty ? "Was ist auf diesen Bildern zu sehen?" : question)
    }

    @objc private func cancelTapped() {
        task?.cancel()
        codex.cancel()
        screenshotProcess?.terminate()
    }

    @objc private func openAnalysisTapped() {
        guard task == nil, let analysisSessionID else { return }
        setBusy(true)
        task = Task { @MainActor in
            defer { task = nil; setBusy(false) }
            do {
                let reply = try await codex.ask(.openAnalysis, question: analysisSessionID, snapshot: AssistantSnapshot())
                status.stringValue = reply.answer
            } catch {
                status.stringValue = "PandaOS nicht geöffnet: \(error.localizedDescription)"
            }
        }
    }

    private func run(_ mode: CodexMode, question: String = "") {
        guard task == nil, !capturing else { return }
        showingHelp = false
        setBusy(true)
        let title = mode == .asked ? "Was wurde ich gerade gefragt?" : (mode == .analysis ? "/analyse " : "") + question
        let started = Date()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                let state = mode == .analysis ? "PandaOS startet die Analyse" : "Codex denkt nach"
                self?.status.stringValue = "\(state), \(Int(Date().timeIntervalSince(started))) s …"
            }
        }
        status.stringValue = mode == .analysis ? "Analyse wird in PandaOS gestartet …" : "Codex denkt nach …"
        task = Task { @MainActor in
            let current = await snapshot()
            let analysisTarget = selectedTarget
            conversation.update(for: current)
            pendingQuestion = title
            pendingImages = mode == .asked ? [] : draftImages
            render()
            do {
                try Task.checkCancellation()
                guard current.recording || mode != .asked else {
                    throw CodexError.failed("Gerade läuft keine Aufnahme, es gibt kein Transkript.")
                }
                let reply = try await codex.ask(mode, question: question, snapshot: current,
                                                history: conversation.turns, images: pendingImages,
                                                requestID: mode == .analysis ? analysisRequestID : nil,
                                                target: mode == .analysis ? analysisTarget : nil)
                try Task.checkCancellation()
                if let sessionID = reply.sessionID {
                    analysisSessionID = sessionID
                    analysisButton.isHidden = false
                }
                let latest = await snapshot()
                guard mode == .analysis || latest.startedAt == nil || latest.startedAt == current.startedAt else {
                    conversation.update(for: latest)
                    throw CodexError.failed("Neue Aufnahme gestartet. Bitte sende die Frage erneut.")
                }
                if mode != .asked {
                    query.string = ""
                    query.didChangeText()
                    draftImages = []
                    renderPreviews()
                    analysisRequestID = nil
                }
                status.stringValue = "\(reply.account), \(reply.model) (\(reply.effort)), \(Int(reply.seconds.rounded())) s"
                conversation.append(question: title, answer: reply.answer, images: pendingImages)
            } catch is CancellationError {
                status.stringValue = mode == .analysis
                    ? "Abgebrochen. Eine Analyse kann bereits in PandaOS laufen."
                    : "Abgebrochen."
            } catch {
                status.stringValue = "Fehler: \(error.localizedDescription)"
            }
            ticker?.invalidate()
            ticker = nil
            pendingQuestion = nil
            pendingImages = []
            render()
            task = nil
            setBusy(false)
        }
    }

    private func setBusy(_ busy: Bool) {
        askedButton.isEnabled = !busy
        questionButton.isEnabled = !busy
        sendButton.isEnabled = !busy
        cancelButton.isHidden = !busy
        clearButton.isEnabled = !busy
        analysisButton.isEnabled = !busy
        targetPopup.isEnabled = !busy
        query.isEditable = !busy
        imageButton.isEnabled = !busy
        shotButton.isEnabled = !busy
        previews.subviews.forEach { view in
            (view as? NSStackView)?.arrangedSubviews.compactMap { $0 as? NSButton }.forEach { $0.isEnabled = !busy }
        }
    }

    private func entry(title: String, body: String, images: [ChatImage]) -> NSAttributedString {
        let user = NSMutableParagraphStyle()
        user.alignment = .left
        user.headIndent = 24
        user.firstLineHeadIndent = 24
        user.paragraphSpacing = 8
        user.lineSpacing = 4
        let out = NSMutableAttributedString(string: "Du\n", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: ChatColors.secondary, .paragraphStyle: user
        ])
        out.append(NSAttributedString(string: title + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 16, weight: .medium),
            .foregroundColor: ChatColors.ink, .paragraphStyle: user,
            .backgroundColor: NSColor.controlBackgroundColor
        ]))
        for image in images {
            let attachment = NSTextAttachment()
            attachment.image = image.preview
            let size = image.preview.size
            let scale = min(1, 220 / max(size.width, size.height))
            attachment.bounds = NSRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
            let visual = NSMutableAttributedString(attachment: attachment)
            visual.addAttribute(.paragraphStyle, value: user, range: NSRange(location: 0, length: visual.length))
            out.append(visual)
            out.append(NSAttributedString(string: "\nBild: " + image.name + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: ChatColors.secondary,
                .paragraphStyle: user
            ]))
        }
        out.append(NSAttributedString(string: "\nLuna\n", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: ChatColors.secondary
        ]))
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let parsed = (try? NSMutableAttributedString(AttributedString(markdown: body, options: options)))
            ?? NSMutableAttributedString(string: body)
        parsed.addAttribute(.foregroundColor, value: ChatColors.ink, range: NSRange(location: 0, length: parsed.length))
        parsed.addAttribute(.font, value: NSFont.systemFont(ofSize: 16), range: NSRange(location: 0, length: parsed.length))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 6
        paragraph.paragraphSpacing = 12
        parsed.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: parsed.length))
        parsed.enumerateAttribute(.inlinePresentationIntent, in: NSRange(location: 0, length: parsed.length)) { value, range, _ in
            guard let raw = value as? UInt, InlinePresentationIntent(rawValue: raw).contains(.stronglyEmphasized) else { return }
            parsed.addAttribute(.font, value: NSFont.systemFont(ofSize: 16, weight: .semibold), range: range)
        }
        out.append(parsed)
        out.append(NSAttributedString(string: "\n\n"))
        return out
    }

    private func render() {
        let text = NSMutableAttributedString()
        if conversation.turns.isEmpty, pendingQuestion == nil, !showingHelp {
            text.append(NSAttributedString(string: "Stell Luna eine Frage.\n\nWas wurde besprochen? Was zeigt der Bildschirm?\nSchreib deine Frage oder hänge ein Bild an.\n\nMitschrift und Second Brain liefern den Kontext, auch für Rückfragen.", attributes: [
                .font: NSFont.systemFont(ofSize: 15),
                .foregroundColor: ChatColors.secondary
            ]))
        }
        conversation.turns.forEach { text.append(entry(title: $0.question, body: $0.answer, images: $0.images)) }
        if let pendingQuestion { text.append(entry(title: pendingQuestion, body: "Antwort wird vorbereitet …", images: pendingImages)) }
        if showingHelp { text.append(entry(title: "/help", body: SlashCommand.help, images: [])) }
        answerView.textStorage?.setAttributedString(text)
        answerView.scrollToEndOfDocument(nil)
        if panes.selectedSegment == 1 {
            copyButton.isEnabled = !conversation.turns.isEmpty
            copyButton.title = "Antwort kopieren"
            copyButton.setAccessibilityLabel(copyButton.title)
        }
    }

    func windowWillClose(_ notification: Notification) {
        restoreAfterCapture = false
        cancelTapped()
    }

    @objc private func updateTransparency() {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        surface.blendingMode = reduce ? .withinWindow : .behindWindow
        surface.state = reduce ? .inactive : .active
        surface.layer?.backgroundColor = reduce ? NSColor.windowBackgroundColor.cgColor : nil
        for scroll in [liveScroll, answerScroll] {
            scroll.backgroundColor = reduce ? .textBackgroundColor : ChatColors.surface
        }
    }

    func attach(_ images: [ChatImage]) {
        guard task == nil, !capturing else { return }
        guard draftImages.count + images.count <= 4 else {
            status.stringValue = "Bis zu vier Bilder pro Nachricht. Entferne zuerst einen Anhang."
            return
        }
        draftImages.append(contentsOf: images)
        renderPreviews()
    }

    private func updateCommandHints() {
        commandHints.arrangedSubviews.forEach { commandHints.removeArrangedSubview($0); $0.removeFromSuperview() }
        let matches = SlashCommand.matches(query.string)
        for command in matches {
            let title = NSMutableAttributedString(string: command.name, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: ChatColors.ink])
            title.append(NSAttributedString(string: "  " + command.summary, attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: ChatColors.secondary]))
            let row = NSButton(title: command.name, target: self, action: #selector(commandTapped(_:)))
            row.isBordered = false
            row.attributedTitle = title
            row.alignment = .left
            row.lineBreakMode = .byTruncatingTail
            row.identifier = NSUserInterfaceItemIdentifier(command.name)
            row.toolTip = command.summary
            row.setAccessibilityLabel("\(command.name): \(command.summary)")
            row.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            commandHints.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: commandHints.widthAnchor).isActive = true
        }
        commandHints.isHidden = matches.isEmpty
    }

    private func completeCommand() -> Bool {
        let matches = SlashCommand.matches(query.string)
        guard let command = matches.first, matches.count == 1 || matches.contains(where: { $0.name == query.string.lowercased() })
        else { return false }
        apply(matches.first { $0.name == query.string.lowercased() } ?? command)
        return true
    }

    @objc private func commandTapped(_ sender: NSButton) {
        guard let command = SlashCommand.all.first(where: { $0.name == sender.identifier?.rawValue }) else { return }
        apply(command)
    }

    private func apply(_ command: SlashCommand) {
        guard command.takesText else {
            showHelp()
            return
        }
        query.string = command.name + " "
        query.didChangeText()
        panel.makeFirstResponder(query)
    }

    private func showHelp() {
        query.string = ""
        query.didChangeText()
        showingHelp = true
        panes.selectedSegment = 1
        paneChanged()
        render()
        panel.makeFirstResponder(query)
    }

    private func renderPreviews() {
        previews.arrangedSubviews.forEach { previews.removeArrangedSubview($0); $0.removeFromSuperview() }
        for (index, image) in draftImages.enumerated() {
            let preview = NSImageView(image: image.preview)
            preview.imageScaling = .scaleProportionallyUpOrDown
            preview.imageFrameStyle = .grayBezel
            preview.setAccessibilityLabel(image.name)
            preview.heightAnchor.constraint(equalToConstant: 58).isActive = true
            preview.widthAnchor.constraint(equalToConstant: 66).isActive = true
            let remove = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)!,
                                  target: self, action: #selector(removeImage(_:)))
            remove.tag = index
            remove.bezelStyle = .rounded
            remove.contentTintColor = ChatColors.ink
            remove.widthAnchor.constraint(equalToConstant: 44).isActive = true
            remove.heightAnchor.constraint(equalToConstant: 28).isActive = true
            remove.setAccessibilityLabel("\(image.name) entfernen")
            remove.toolTip = "\(image.name) entfernen"
            let item = NSStackView(views: [preview, remove])
            item.orientation = .vertical
            item.spacing = 2
            previews.addArrangedSubview(item)
        }
        previews.isHidden = draftImages.isEmpty
    }

    @objc private func removeImage(_ sender: NSButton) {
        guard task == nil, !capturing, draftImages.indices.contains(sender.tag) else { return }
        draftImages.remove(at: sender.tag)
        renderPreviews()
    }

    @objc private func imageTapped() {
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.image]
        picker.allowsMultipleSelection = true
        picker.canChooseDirectories = false
        picker.prompt = "Anhängen"
        picker.beginSheetModal(for: panel) { [weak self] response in
            guard response == .OK else { return }
            MainActor.assumeIsolated {
                do { try self?.query.attach(picker.urls) }
                catch { self?.status.stringValue = error.localizedDescription }
            }
        }
    }

    @objc private func shotTapped() {
        guard task == nil, !capturing else { return }
        guard draftImages.count < 4 else {
            status.stringValue = "Bis zu vier Bilder pro Nachricht. Entferne zuerst einen Anhang."
            return
        }
        capturing = true
        restoreAfterCapture = true
        setBusy(true)
        panel.orderOut(nil)
        Task { @MainActor in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mitschrift-chat-\(UUID().uuidString)")
            defer {
                try? FileManager.default.removeItem(at: folder)
                screenshotProcess = nil
                capturing = false
                setBusy(false)
                if restoreAfterCapture { present(focus: true) }
            }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                       attributes: [.posixPermissions: 0o700])
                let file = folder.appendingPathComponent("Screenshot.png")
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-i", "-x", "-t", "png", file.path]
                screenshotProcess = process
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    process.terminationHandler = { _ in continuation.resume() }
                    do { try process.run() } catch { continuation.resume(throwing: error) }
                }
                guard FileManager.default.fileExists(atPath: file.path) else {
                    status.stringValue = "Kein Screenshot übernommen. Auswahl abgebrochen oder Bildschirmrecht fehlt."
                    return
                }
                let image = try ChatImage(data: Data(contentsOf: file), name: "Screenshot")
                draftImages.append(image)
                renderPreviews()
                status.stringValue = "Screenshot angehängt. Er wird erst beim Senden übertragen."
            } catch {
                status.stringValue = "Screenshot nicht möglich: \(error.localizedDescription)"
            }
        }
    }
}
