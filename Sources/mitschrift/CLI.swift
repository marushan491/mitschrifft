import AVFoundation
import AppKit
import CoreGraphics
import Darwin
import Foundation

@main
struct CLI {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        let args = Array(CommandLine.arguments.dropFirst())
        let command = args.first ?? "menu"

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        if command == "menu" {
            guard startMenuMode() else { return }
            app.run()
            return
        }

        let finished = StopFlag()
        Task {
            do {
                try await dispatch(command: command, args: args)
            } catch {
                log("Fehler: \(error.localizedDescription)")
                finished.set()
                exit(1)
            }
            finished.set()
        }

        while !finished.isSet {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    @MainActor
    static func startMenuMode() -> Bool {
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.anpalahan.mitschrift"
        ).filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }

        if !running.isEmpty {
            log("Mitschrift laeuft bereits, das Symbol ist in der Menueleiste.")
            running.first?.activate()
            return false
        }

        let controller = MenuBarApp(config: Config.load())
        NSApp.delegate = controller
        menuController = controller
        return true
    }

    nonisolated(unsafe) static var menuController: MenuBarApp?

    static func dispatch(command: String, args: [String]) async throws {
        switch command {
        case "shot":
            try await shot(app: args.count > 1 ? args[1] : "Microsoft Teams")
        case "structure":
            let config = Config.load()
            let structure = Structure(config: config)
            if args.count > 1 {
                structure.enqueue(note: URL(fileURLWithPath: args[1]))
            }
            print("Offene Auftraege: \(structure.pending())")
            structure.drain()
            print("Danach offen: \(structure.pending())")
        case "title":
            let app = args.count > 1 ? args[1] : "Microsoft Teams"
            if let title = await WindowShot.meetingTitle(matching: [app]) {
                print("Terminname: \(title)")
            } else {
                print("Kein Terminname lesbar.")
            }
        case "video":
            try await videoTest(app: args.count > 1 ? args[1] : "Microsoft Teams",
                                seconds: Double(args.count > 2 ? args[2] : "8") ?? 8)
        case "icons":
            try await renderIcons(directory: args.count > 1 ? args[1] : ".")
        case "probe":
            try await probe(seconds: Double(args.count > 1 ? args[1] : "12") ?? 12)
        case "run":
            try await run(maxSeconds: args.count > 1 ? Double(args[1]) : nil)
        case "watch":
            try await watch()
        case "micusers":
            micusers()
        case "status":
            await status()
        case "config":
            try showConfig()
        case "recover":
            recover()
        case "ask":
            try await ask(args: Array(args.dropFirst()))
        case "speakers":
            try await speakers(path: args.count > 1 ? args[1] : "")
        case "install":
            try install()
        case "uninstall":
            try uninstall()
        default:
            help()
        }
    }

    static func help() {
        print("""
        mitschrift - lokales Mithoeren und Transkribieren, unabhaengig von Teams, Slack, Zoom

          menu               Menueleisten-Symbol mit Status und Steuerung (Standard)
          watch              Hintergrunddienst ohne Menueleiste
          run [sekunden]     Sofort aufnehmen, Strg-C beendet und schreibt die Notiz
          probe [sekunden]   Kurztest, gibt das Transkript nur auf der Konsole aus
          micusers           Zeigt, welche Apps gerade das Mikro benutzen
          shot <app>         Testet Fensterfoto und OCR fuer eine App
          status             Rechte, Dienstzustand, Konfiguration
          config             Konfigurationsdatei anzeigen oder anlegen
          recover            Abgebrochene Sitzungen zu Notizen verarbeiten
          ask <jsonl> [frage] Codex zu einer Sitzung fragen, ohne Frage: Was wurde ich gefragt?
          speakers <datei>   Testet die Sprechertrennung an einer Audiodatei
          install            Als Anmeldedienst einrichten
          uninstall          Anmeldedienst entfernen
        """)
    }

    static func prepareLocale(_ config: Config) async throws -> Locale {
        let locale = try await TrackTranscriber.locale(for: config.locale)
        try await TrackTranscriber.ensureModelInstalled(locale: locale)
        return locale
    }

    static func probe(seconds: Double) async throws {
        let config = Config.load()
        let locale = try await prepareLocale(config)
        let session = RecordingSession(locale: locale)
        try await session.start()
        log("Aufnahme laeuft, \(Int(seconds)) Sekunden.")

        try await Task.sleep(for: .seconds(seconds))
        let counts = await session.frameCounts()
        let result = await session.finish(timeout: config.finishTimeoutSeconds)
        log("Frames: Mikro \(counts.mic), System \(counts.system), Segmente \(result.segments.count)")
        for segment in result.segments {
            let who = segment.track == .mic ? config.speakerMe : config.speakerOthers
            print("[\(formatClock(segment.start))] \(who): \(segment.text)")
        }
    }

    static func run(maxSeconds: Double?) async throws {
        let config = Config.load()
        let locale = try await prepareLocale(config)
        let supervisor = await Supervisor(config: config, locale: locale)
        await supervisor.begin()
        await supervisor.startManually()
        log("Aufnahme laeuft. Strg-C beendet und schreibt die Notiz. SIGUSR1 macht ein Foto.")

        let stop = installStopHandler()
        let photo = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        signal(SIGUSR1, SIG_IGN)
        photo.setEventHandler {
            Task { @MainActor in
                let result = await supervisor.capturePhoto()
                log(result)
            }
        }
        photo.resume()

        if let maxSeconds {
            let deadline = Date().addingTimeInterval(maxSeconds)
            while !stop.isSet, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(300))
            }
        } else {
            while !stop.isSet { try? await Task.sleep(for: .milliseconds(300)) }
        }

        await supervisor.stopAndSave()
        await supervisor.shutdown()
    }

    static func videoTest(app: String, seconds: Double) async throws {
        let config = Config.load()
        guard let window = try await WindowShot.meetingWindow(matching: [app]) else {
            log("Kein Fenster von \(app) gefunden.")
            return
        }
        let name = "test \(ISO8601DateFormatter.filenameSafe.string(from: Date())).mp4"
            .replacingOccurrences(of: ":", with: "-")
        let recorder = WindowVideo(url: config.videosDirectory.appendingPathComponent(name))
        try await recorder.start(window: window,
                                 fps: config.videoFramesPerSecond,
                                 maxWidth: config.videoMaxWidth)
        try await Task.sleep(for: .seconds(seconds))
        if let file = await recorder.finish() {
            print(config.videosDirectory.appendingPathComponent(file).path)
        } else {
            print("Kein Video entstanden.")
        }
    }

    static func shot(app: String) async throws {
        let config = Config.load()
        guard let window = try await WindowShot.meetingWindow(matching: [app]) else {
            log("Kein Fenster von \(app) gefunden.")
            return
        }
        let owner = window.owningApplication?.applicationName ?? "?"
        log("Fenster: \(owner), \(Int(window.frame.width))x\(Int(window.frame.height))")

        let image = try await WindowShot.capture(window)
        log("Aufgenommen: \(image.width)x\(image.height) Pixel")

        let text = await WindowShot.readText(from: image, locale: config.locale)
        let words = text.split(whereSeparator: \.isWhitespace).count
        log("OCR: \(words) Woerter, \(text.split(separator: "\n").count) Zeilen")
        print(text.split(separator: "\n").prefix(12).joined(separator: "\n"))
    }

    @MainActor
    static func renderIcons(directory: String) async throws {
        let base = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        try PandaIcon.writePNG(PandaIcon.previewStrip(),
                               to: base.appendingPathComponent("menubar-preview.png"))
        for size in [CGFloat(512), 1024] {
            try PandaIcon.writePNG(PandaIcon.appIcon(size: size),
                                   to: base.appendingPathComponent("app-\(Int(size)).png"))
        }
        for size in [CGFloat(16), 32, 64, 128, 256, 512, 1024] {
            try PandaIcon.writePNG(PandaIcon.appIcon(size: size),
                                   to: base.appendingPathComponent("icon_\(Int(size)).png"))
        }
        print("Symbole geschrieben nach \(base.path)")
    }

    static func watch() async throws {
        let config = Config.load()
        let locale = try await prepareLocale(config)
        let supervisor = await Supervisor(config: config, locale: locale)
        await supervisor.begin()

        log("Dienst laeuft ohne Menueleiste. Start nach \(config.startAfterSeconds)s, Stopp nach \(config.stopAfterSeconds)s Stille.")
        let stop = installStopHandler()
        while !stop.isSet {
            try? await Task.sleep(for: .milliseconds(300))
        }
        await supervisor.shutdown()
    }

    static func finalize(session: RecordingSession,
                         sink: SegmentSink,
                         config: Config,
                         enforceMinimum: Bool) async throws {
        let result = await session.finish(timeout: config.finishTimeoutSeconds)
        activeSink = nil
        sink.close()

        let duration = result.duration
        if result.segments.isEmpty {
            log("Keine Sprache erkannt, nichts gespeichert.")
            sink.discard()
            return
        }
        if enforceMinimum, duration < Double(config.minimumSessionSeconds) {
            log("Nur \(Int(duration))s, unter der Mindestdauer, nichts gespeichert.")
            sink.discard()
            return
        }

        let url = try NoteWriter(config: config).write(
            segments: result.segments,
            startedAt: result.startedAt,
            endedAt: result.endedAt,
            apps: sink.appNames
        )
        log("Notiz geschrieben: \(url.path)")
        sink.discard()
    }

    static func micusers() {
        let detector = MeetingDetector(config: Config.load())
        let all = detector.allUsers()
        let relevant = detector.startCandidates()

        if all.isEmpty {
            print("Audio aktiv: niemand")
        } else {
            let described = all.map { user -> String in
                var kinds: [String] = []
                if user.input { kinds.append("Mikro") }
                if user.output { kinds.append("Ton raus") }
                return "\(user.name) [\(kinds.joined(separator: "+"))]"
            }
            print("Audio aktiv: \(described.joined(separator: ", "))")
        }
        print("Loest Aufnahme aus: \(relevant.isEmpty ? "niemand" : relevant.map(\.name).joined(separator: ", "))")
    }

    static func status() async {
        let config = Config.load()
        print("Konfiguration: \(Config.file.path)")
        print("Notizen:       \(config.notesDirectory.path)")
        print("Sprache:       \(config.locale)")
        print("Ignoriert:     \(config.ignoreApps.joined(separator: ", "))")
        print("Konferenz-Apps: \(config.meetingApps.joined(separator: ", "))")

        let screen = CGPreflightScreenCaptureAccess()
        print("Bildschirmrecht: \(screen ? "erteilt" : "FEHLT, Systemeinstellungen, Datenschutz, Bildschirm- und Systemtonaufnahme")")

        let installed = await SpeechTranscriberStatus.installedDescription(for: config.locale)
        print("Sprachmodell:  \(installed)")

        let plist = launchAgentURL
        let loaded = FileManager.default.fileExists(atPath: plist.path)
        print("Anmeldedienst: \(loaded ? "eingerichtet (\(plist.lastPathComponent))" : "nicht eingerichtet")")
        micusers()
    }

    static func showConfig() throws {
        if !FileManager.default.fileExists(atPath: Config.file.path) {
            try Config().save()
            print("Angelegt: \(Config.file.path)")
        }
        print(try String(contentsOf: Config.file, encoding: .utf8))
    }

    static func recover() {
        let writer = NoteWriter(config: Config.load())
        let urls = writer.recoverPartials()
        if urls.isEmpty {
            print("Keine abgebrochenen Sitzungen gefunden.")
        } else {
            urls.forEach { print("Nachgetragen: \($0.path)") }
        }
    }

    static func ask(args: [String]) async throws {
        guard let path = args.first, let partial = PartialSession(url: URL(fileURLWithPath: path)) else {
            print("Aufruf: mitschrift ask <sitzung.jsonl> [frage]")
            return
        }
        let segments = Echo.removeMicEcho(partial.segments)
        let snapshot = AssistantSnapshot(segments: segments,
                                         elapsed: segments.map(\.end).max() ?? 0,
                                         meeting: partial.meeting,
                                         screenText: partial.screens.last?.text,
                                         recording: true)
        let question = args.dropFirst().joined(separator: " ")
        let started = Date()
        let reply = try await CodexAsk(host: Config.load().structureHost)
            .ask(question.isEmpty ? .asked : .question, question: question, snapshot: snapshot)
        print("\(reply.account), \(reply.model) (\(reply.effort)), \(Int(Date().timeIntervalSince(started))) s gesamt")
        print("Mikro-Echo entfernt: \(partial.segments.count - segments.count) Stuecke, Sprecher: \(Set(segments.compactMap(\.speaker)).count)")
        print("")
        print(reply.answer)
    }

    static func speakers(path: String) async throws {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let tracker = SpeakerTracker()
        await tracker.start()
        var offset: TimeInterval = 0
        while let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4800),
              (try? file.read(into: buffer)) != nil, buffer.frameLength > 0 {
            await tracker.feed(buffer, at: offset)
            offset += Double(buffer.frameLength) / file.processingFormat.sampleRate
        }
        for span in await tracker.finish() {
            print("Sprecher \(span.speaker + 1): \(formatClock(span.start))-\(formatClock(span.end))")
        }
    }

    static var launchAgentURL: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/LaunchAgents/com.anpalahan.mitschrift.plist")
    }

    static func install() throws {
        let binary = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        let logDir = NSHomeDirectory() + "/Library/Logs"
        try FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        try Config().saveIfMissing()

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>com.anpalahan.mitschrift</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(binary)</string>
                <string>menu</string>
            </array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
            <key>ProcessType</key><string>Interactive</string>
            <key>StandardOutPath</key><string>\(logDir)/mitschrift.log</string>
            <key>StandardErrorPath</key><string>\(logDir)/mitschrift.log</string>
        </dict>
        </plist>
        """

        try plist.write(to: launchAgentURL, atomically: true, encoding: .utf8)

        let label = "gui/\(getuid())/com.anpalahan.mitschrift"
        shell("/bin/launchctl", ["bootout", label])

        var attempt = 0
        while shell("/bin/launchctl", ["print", label]) == 0, attempt < 20 {
            usleep(200_000)
            attempt += 1
        }

        var bootstrapped = false
        for _ in 0..<5 {
            if shell("/bin/launchctl", ["bootstrap", "gui/\(getuid())", launchAgentURL.path]) == 0 {
                bootstrapped = true
                break
            }
            usleep(400_000)
        }

        guard bootstrapped, shell("/bin/launchctl", ["print", label]) == 0 else {
            print("Dienst konnte nicht gestartet werden. Von Hand:")
            print("  launchctl bootstrap gui/\(getuid()) \(launchAgentURL.path)")
            return
        }
        print("Dienst eingerichtet und gestartet. Log: \(logDir)/mitschrift.log")
    }

    static func uninstall() throws {
        shell("/bin/launchctl", ["bootout", "gui/\(getuid())/com.anpalahan.mitschrift"])
        try? FileManager.default.removeItem(at: launchAgentURL)
        print("Dienst entfernt.")
    }

    @discardableResult
    static func shell(_ path: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    static func installStopHandler() -> StopFlag {
        let flag = StopFlag()
        for signalNumber in [SIGINT, SIGTERM] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { flag.set() }
            source.resume()
            flag.keep(source)
        }
        return flag
    }
}

final class StopFlag: @unchecked Sendable {
    private var value = false
    private let lock = NSLock()
    private var sources: [DispatchSourceSignal] = []

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock(); value = true; lock.unlock()
    }

    func keep(_ source: DispatchSourceSignal) {
        lock.lock(); sources.append(source); lock.unlock()
    }
}

extension Config {
    func saveIfMissing() throws {
        if !FileManager.default.fileExists(atPath: Config.file.path) {
            try save()
        }
    }
}

enum SpeechTranscriberStatus {
    static func installedDescription(for identifier: String) async -> String {
        do {
            let locale = try await TrackTranscriber.locale(for: identifier)
            return "installiert (\(locale.identifier(.bcp47)))"
        } catch {
            return "nicht verfuegbar: \(error.localizedDescription)"
        }
    }
}
