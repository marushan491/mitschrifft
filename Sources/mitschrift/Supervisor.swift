import Foundation
import ScreenCaptureKit

@MainActor
final class Supervisor {
    private(set) var isRecording = false
    private(set) var recordingStart: Date?
    private(set) var recordingApps: [String] = []
    private(set) var lastNote: URL?
    private(set) var lastNoteAt: Date?
    private(set) var lastError: String?
    private(set) var notesToday = 0

    var automaticEnabled = true { didSet { announce() } }
    var pausedUntil: Date? { didSet { announce() } }
    var onChange: (@MainActor () -> Void)?

    private let config: Config
    private let locale: Locale
    private let detector: MeetingDetector
    private var session: RecordingSession?
    private var sink: SegmentSink?
    private var manual = false
    private var startedDuringMeeting = false
    private var activeSeconds = 0
    private var idleSeconds = 0
    private var loop: Task<Void, Never>?
    private var screens: [ScreenCapture] = []
    private var lastSeen = "?"
    private(set) var screenPermissionDenied = false
    private var ticks = 0
    private var suppressAuto = false
    private var starting = false
    private var seenTicks = 0
    private var video: WindowVideo?
    private var savedVideoFiles: [String] = []
    private var videoTask: Task<Void, Never>?
    private var silentSeconds = 0
    private var lastResultCount = 0
    private(set) var meetingTitle: String?
    private(set) var detectedApps: [String] = []

    private let tick = 2

    init(config: Config, locale: Locale) {
        self.config = config
        self.locale = locale
        self.detector = MeetingDetector(config: config)
    }

    var isPaused: Bool {
        guard let pausedUntil else { return false }
        if pausedUntil <= Date() {
            return false
        }
        return true
    }

    var shotCount: Int { screens.count }

    var videoRunning: Bool { video != nil }

    var meetingDetected: Bool {
        !detectedApps.isEmpty && seenTicks >= 2
    }

    var automaticSuppressed: Bool { suppressAuto }

    var statusText: String {
        if screenPermissionDenied {
            return "Bildschirmaufnahme nicht erlaubt"
        }
        if isRecording {
            let elapsed = Date().timeIntervalSince(recordingStart ?? Date())
            let who = recordingApps.first ?? "Gespraech"
            return manual ? "Nimmt auf, \(formatClock(elapsed)), von Hand gestartet"
                          : "Nimmt auf, \(formatClock(elapsed)), \(who)"
        }
        if !automaticEnabled {
            return meetingDetected ? "Automatik aus, Termin laeuft (\(detectedApps.joined(separator: ", ")))"
                                   : "Automatik aus"
        }
        if suppressAuto { return "Von Hand gestoppt, Termin laeuft noch" }
        if meetingDetected { return "Termin erkannt: \(detectedApps.joined(separator: ", "))" }
        if let pausedUntil, isPaused {
            let rest = pausedUntil.timeIntervalSinceNow
            return "Pausiert, noch \(formatClock(rest))"
        }
        return "Bereit, wartet auf eine Besprechung"
    }

    func begin() {
        let structure = Structure(config: config)
        for url in NoteWriter(config: config).recoverPartials() {
            log("Abgebrochene Sitzung nachgetragen: \(url.lastPathComponent)")
            structure.enqueue(note: url)
            lastNote = url
            lastNoteAt = Date()
        }
        if structure.pending() > 0 {
            Task.detached(priority: .background) { structure.drain() }
        }
        countNotesToday()

        log("Erkennung gestartet, Takt \(tick)s.")
        loop = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                await self?.step()
                ticks += 1
                if ticks % 30 == 0 { log("Erkennung lebt, \(ticks) Takte.") }
                try? await Task.sleep(for: .seconds(2))
            }
            log("Erkennungsschleife beendet.")
        }
        announce()
    }

    func shutdown() async {
        loop?.cancel()
        loop = nil
        if session != nil {
            await finish(enforceMinimum: false, reason: "Dienst wird beendet")
        }
    }

    func startManually(withVideo: Bool = false) async {
        guard session == nil, !starting else { return }
        suppressAuto = false
        manual = true
        startedDuringMeeting = !detectedApps.isEmpty
        await beginRecording(apps: detector.stillTalking().map(\.name), withVideo: withVideo)
    }

    func stopAndSave() async {
        guard session != nil else { return }
        if !detectedApps.isEmpty {
            suppressAuto = true
            log("Von Hand gestoppt, Automatik ruht bis der Termin endet.")
        }
        await finish(enforceMinimum: false, reason: "von Hand gestoppt")
    }

    func discardRecording() async {
        await videoTask?.value
        guard let session, let sink else { return }
        let recorder = video
        video = nil
        if let file = await recorder?.finish() {
            savedVideoFiles.append(file)
        }
        for file in savedVideoFiles {
            try? FileManager.default.removeItem(at: config.videosDirectory.appendingPathComponent(file))
        }
        savedVideoFiles = []
        screens = []
        _ = await session.finish(timeout: config.finishTimeoutSeconds)
        activeSink = nil
        sink.discard()
        self.session = nil
        self.sink = nil
        isRecording = false
        recordingStart = nil
        recordingApps = []
        manual = false
        idleSeconds = 0
        log("Aufnahme verworfen, nichts gespeichert.")
        announce()
    }

    @discardableResult
    func capturePhoto() async -> String {
        if !isRecording {
            log("Foto verlangt, es lief keine Aufnahme. Transkript startet mit, ohne Video.")
            await startManually(withVideo: false)
        }
        guard isRecording, let sink, let start = recordingStart else {
            return "Aufnahme liess sich nicht starten, kein Foto."
        }

        do {
            guard let window = try await conferenceWindow() else {
                lastError = "Kein Konferenzfenster gefunden."
                announce()
                return lastError ?? ""
            }

            let image = try await WindowShot.capture(window)
            let text = await WindowShot.readText(from: image, locale: config.locale)
            let app = window.owningApplication?.applicationName ?? "Konferenz"
            let at = Date().timeIntervalSince(start)

            var imageFile: String?
            if config.keepScreenshots {
                let name = "\(sink.id) \(Int(at))s.jpg"
                    .replacingOccurrences(of: ":", with: "-")
                try WindowShot.writeImage(image,
                                          to: config.imagesDirectory.appendingPathComponent(name),
                                          maxWidth: config.imageMaxWidth,
                                          quality: config.imageQuality)
                imageFile = name
            }

            let capture = ScreenCapture(at: at, app: app, text: text, imageFile: imageFile)
            screens.append(capture)
            sink.append(screen: capture)
            lastError = nil
            announce()

            let words = text.split(whereSeparator: \.isWhitespace).count
            log("Foto von \(app): \(words) Woerter erkannt\(imageFile == nil ? ", Bild verworfen" : ", Bild gespeichert").")
            return words == 0 ? "Foto gemacht, kein Text erkannt." : "Foto gemacht, \(words) Woerter erkannt."
        } catch {
            lastError = error.localizedDescription
            log("Foto fehlgeschlagen: \(error.localizedDescription)")
            announce()
            return "Foto fehlgeschlagen."
        }
    }

    func pause(minutes: Int) {
        pausedUntil = Date().addingTimeInterval(TimeInterval(minutes * 60))
        log("Automatik pausiert bis \(pausedUntil!)")
    }

    func resumeAutomatic() {
        pausedUntil = nil
        automaticEnabled = true
        screenPermissionDenied = false
    }

    private func step() async {
        let seen = session == nil ? detector.startCandidates() : detector.stillTalking()
        detectedApps = seen.map(\.name)
        seenTicks = detectedApps.isEmpty ? 0 : seenTicks + 1
        ticks += 1
        let names = detectedApps.sorted().joined(separator: ", ")
        if names != lastSeen || ticks <= 3 {
            lastSeen = names
            log("Audio-Erkennung (Takt \(ticks)): \(names.isEmpty ? "niemand" : names)")
        }

        if session == nil, ticks % 90 == 0 {
            let structure = Structure(config: config)
            if structure.pending() > 0 {
                Task.detached(priority: .background) { structure.drain() }
            }
        }

        if detectedApps.isEmpty, suppressAuto {
            suppressAuto = false
            log("Termin beendet, Automatik ist wieder scharf.")
        }

        if session == nil {
            guard automaticEnabled, !isPaused, !suppressAuto else {
                activeSeconds = 0
                announce()
                return
            }
            let users = seen
            if users.isEmpty {
                activeSeconds = 0
            } else {
                activeSeconds += tick
                if activeSeconds >= config.startAfterSeconds {
                    activeSeconds = 0
                    manual = false
                    startedDuringMeeting = true
                    log("Audio belegt von \(users.map(\.name).joined(separator: ", ")), Aufnahme startet.")
                    await beginRecording(apps: users.map(\.name), withVideo: false)
                }
            }
        } else {
            let users = seen
            if ticks % 10 == 0, let session {
                log("Aufnahme laeuft: \(await session.healthLine())")
            }
            if video == nil, let session {
                let count = await session.resultCount()
                if count != lastResultCount {
                    lastResultCount = count
                    silentSeconds = 0
                } else {
                    silentSeconds += tick
                }
                if silentSeconds >= config.giveUpAfterSilentSeconds {
                    await finish(enforceMinimum: false,
                                 reason: "\(silentSeconds)s kein neues Wort")
                    return
                }
            } else {
                silentSeconds = 0
            }
            if manual, !startedDuringMeeting {
                idleSeconds = 0
            } else if users.isEmpty {
                idleSeconds += tick
            } else {
                idleSeconds = 0
                users.forEach { sink?.noteApp($0.name) }
                recordingApps = sink?.appNames ?? recordingApps
            }

            if idleSeconds >= config.stopAfterSeconds,
               !manual || startedDuringMeeting {
                await finish(enforceMinimum: true, reason: "\(idleSeconds)s kein Konferenzton")
            }
        }
        announce()
    }

    private func beginRecording(apps: [String], withVideo: Bool) async {
        guard session == nil, !starting else { return }
        starting = true
        defer { starting = false }
        do {
            let newSink = try SegmentSink(config: config, apps: apps)
            activeSink = newSink
            let newSession = RecordingSession(locale: locale)
            try await newSession.start()
            session = newSession
            sink = newSink
            isRecording = true
            recordingStart = Date()
            recordingApps = apps
            screens = []
            savedVideoFiles = []
            idleSeconds = 0
            silentSeconds = 0
            lastResultCount = 0
            lastError = nil
            await noteMeetingTitle(sink: newSink, apps: apps)
            if withVideo { await startVideo(sink: newSink, apps: apps) }
        } catch {
            lastError = error.localizedDescription
            let text = error.localizedDescription
            if text.contains("TCC") || text.localizedCaseInsensitiveContains("declined")
                || text.localizedCaseInsensitiveContains("abgelehnt") {
                screenPermissionDenied = true
                automaticEnabled = false
                log("Bildschirmaufnahme ist fuer Mitschrift nicht erlaubt. Automatik ausgesetzt, bis das Recht erteilt ist.")
            } else {
                log("Start fehlgeschlagen: \(text)")
            }
            activeSink?.discard()
            activeSink = nil
            sink = nil
            session = nil
            isRecording = false
            manual = false
        }
        announce()
    }

    func toggleVideo() async {
        guard videoTask == nil else { return }
        let work = Task { await changeVideo() }
        videoTask = work
        await work.value
        videoTask = nil
    }

    private func changeVideo() async {
        if video != nil {
            await stopVideoOnly()
            return
        }
        if session == nil {
            await startManually(withVideo: true)
            return
        }
        guard let sink else { return }
        log("Video wird zur laufenden Aufnahme dazugeschaltet.")
        await startVideo(sink: sink, apps: recordingApps)
        announce()
    }

    private func stopVideoOnly() async {
        let recorder = video
        video = nil
        if let file = await recorder?.finish() {
            savedVideoFiles.append(file)
            sink?.append(video: file)
            log("Video beendet, Transkript laeuft weiter.")
        }
        announce()
    }

    private func noteMeetingTitle(sink: SegmentSink, apps: [String]) async {
        guard !apps.isEmpty else {
            log("Kein Terminname, keine ausloesende Anwendung bekannt.")
            return
        }
        meetingTitle = await WindowShot.meetingTitle(matching: apps)
        if let meetingTitle {
            sink.noteMeeting(meetingTitle)
            log("Termin erkannt als: \(meetingTitle)")
        } else {
            log("Kein Terminname aus dem Fenstertitel lesbar.")
        }
    }

    private func conferenceWindow() async throws -> SCWindow? {
        if !recordingApps.isEmpty,
           let own = try await WindowShot.meetingWindow(matching: recordingApps) {
            return own
        }
        return try await WindowShot.meetingWindow(matching: config.meetingApps)
    }

    private func startVideo(sink: SegmentSink, apps: [String]) async {
        do {
            guard let window = try await conferenceWindow() else {
                log("Kein Konferenzfenster gefunden, Video wird nicht aufgenommen.")
                return
            }
            let name = "\(sink.id)-\(UUID().uuidString).mp4".replacingOccurrences(of: ":", with: "-")
            let recorder = WindowVideo(url: config.videosDirectory.appendingPathComponent(name))
            try await recorder.start(window: window,
                                     fps: config.videoFramesPerSecond,
                                     maxWidth: config.videoMaxWidth)
            video = recorder
        } catch {
            log("Video konnte nicht starten: \(error.localizedDescription)")
            video = nil
        }
    }

    private func finish(enforceMinimum: Bool, reason: String) async {
        await videoTask?.value
        guard let session, let sink else { return }
        log("Aufnahme endet, Grund: \(reason).")
        self.session = nil
        self.sink = nil
        isRecording = false
        recordingStart = nil
        let wasManual = manual
        manual = false
        startedDuringMeeting = false
        idleSeconds = 0
        let title = meetingTitle
        meetingTitle = nil

        let recorder = video
        video = nil
        var videoFiles = savedVideoFiles
        savedVideoFiles = []
        if let file = await recorder?.finish() {
            videoFiles.append(file)
            sink.append(video: file)
        }

        let result = await session.finish(timeout: config.finishTimeoutSeconds)
        activeSink = nil
        sink.close()

        defer { announce() }

        let captured = screens
        screens = []

        if result.segments.isEmpty, captured.isEmpty, videoFiles.isEmpty {
            log("Keine Sprache erkannt, nichts gespeichert.")
            sink.discard()
            return
        }
        if enforceMinimum, !wasManual, captured.isEmpty, videoFiles.isEmpty,
           result.duration < Double(config.minimumSessionSeconds) {
            log("Nur \(Int(result.duration))s, unter der Mindestdauer, nichts gespeichert.")
            sink.discard()
            return
        }

        do {
            let url = try NoteWriter(config: config).write(
                segments: result.segments,
                screens: captured,
                videoFiles: videoFiles,
                meeting: title,
                startedAt: result.startedAt,
                endedAt: result.endedAt,
                apps: sink.appNames
            )
            lastNote = url
            lastNoteAt = Date()
            notesToday += 1
            log("Notiz geschrieben: \(url.path)")
            let structure = Structure(config: config)
            structure.enqueue(note: url)
            Task.detached(priority: .background) { structure.drain() }
        } catch {
            lastError = error.localizedDescription
            log("Notiz konnte nicht geschrieben werden: \(error.localizedDescription)")
        }
        sink.discard()
    }

    private func countNotesToday() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: config.notesDirectory,
                                                      includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let calendar = Calendar.current
        notesToday = files.filter { url in
            guard url.pathExtension == "md",
                  let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            else { return false }
            return calendar.isDateInToday(date)
        }.count
    }

    private func announce() {
        onChange?()
    }

    var notesDirectory: URL { config.notesDirectory }

    func assistantSnapshot() async -> AssistantSnapshot {
        guard let session, isRecording else { return AssistantSnapshot() }
        var snapshot = await session.assistantSnapshot()
        snapshot.meeting = meetingTitle
        snapshot.screenText = screens.last?.text
        return snapshot
    }
}
