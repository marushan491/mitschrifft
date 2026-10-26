import Foundation

struct Config: Codable {
    var locale: String = "de-DE"
    var vaultPath: String = NSHomeDirectory() + "/Documents/Second Brain"
    var notesFolder: String = "50 Resources/Transkripte"
    var startAfterSeconds: Int = 6
    var stopAfterSeconds: Int = 25
    var minimumSessionSeconds: Int = 45
    var giveUpAfterSilentSeconds: Int = 180
    var mergeWithinSeconds: Int = 900
    var finishTimeoutSeconds: Int = 30
    var structureEnabled: Bool = true
    var structureHost: String = "zotac"
    var structureModel: String = "qwen3.5:9b"
    var structureContext: Int = 16384
    var structureTimeoutSeconds: Int = 300
    var structureMaxTries: Int = 8
    var ignoreApps: [String] = [
        "replayd", "coreaudiod", "screencapture", "ScreenCaptureKit",
        "Mitschrift", "Spokenly", "Siri", "VoiceOver"
    ]
    var onlyApps: [String] = []
    var neverTriggerApps: [String] = []
    var meetingApps: [String] = [
        "Microsoft Teams", "Slack", "zoom.us", "Zoom", "Webex",
        "Discord", "FaceTime", "RingCentral", "GoTo"
    ]
    var photoHotKey: String = "cmd+shift+2"
    var keepScreenshots: Bool = true
    var imagesFolder: String = "50 Resources/Transkripte/Bilder"
    var recordVideo: Bool = true
    var videosFolder: String = "50 Resources/Transkripte/Videos"
    var videoFramesPerSecond: Int = 4
    var videoMaxWidth: Int = 1280
    var imageMaxWidth: Int = 1600
    var imageQuality: Double = 0.7
    var speakerMe: String = "Ich"
    var speakerOthers: String = "Andere"

    static let directory = URL(fileURLWithPath: NSHomeDirectory() + "/.config/mitschrift")
    static let file = directory.appendingPathComponent("config.json")
    static let stateDirectory = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/mitschrift")

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Config()

        func value<T: Decodable>(_ key: CodingKeys, _ standard: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) .flatMap { $0 } ?? standard
        }

        locale = value(.locale, fallback.locale)
        vaultPath = value(.vaultPath, fallback.vaultPath)
        notesFolder = value(.notesFolder, fallback.notesFolder)
        startAfterSeconds = value(.startAfterSeconds, fallback.startAfterSeconds)
        stopAfterSeconds = value(.stopAfterSeconds, fallback.stopAfterSeconds)
        minimumSessionSeconds = value(.minimumSessionSeconds, fallback.minimumSessionSeconds)
        giveUpAfterSilentSeconds = value(.giveUpAfterSilentSeconds, fallback.giveUpAfterSilentSeconds)
        mergeWithinSeconds = value(.mergeWithinSeconds, fallback.mergeWithinSeconds)
        finishTimeoutSeconds = value(.finishTimeoutSeconds, fallback.finishTimeoutSeconds)
        structureEnabled = value(.structureEnabled, fallback.structureEnabled)
        structureHost = value(.structureHost, fallback.structureHost)
        structureModel = value(.structureModel, fallback.structureModel)
        structureContext = value(.structureContext, fallback.structureContext)
        structureTimeoutSeconds = value(.structureTimeoutSeconds, fallback.structureTimeoutSeconds)
        structureMaxTries = value(.structureMaxTries, fallback.structureMaxTries)
        ignoreApps = value(.ignoreApps, fallback.ignoreApps)
        onlyApps = value(.onlyApps, fallback.onlyApps)
        neverTriggerApps = value(.neverTriggerApps, fallback.neverTriggerApps)
        meetingApps = value(.meetingApps, fallback.meetingApps)
        photoHotKey = value(.photoHotKey, fallback.photoHotKey)
        keepScreenshots = value(.keepScreenshots, fallback.keepScreenshots)
        imagesFolder = value(.imagesFolder, fallback.imagesFolder)
        recordVideo = value(.recordVideo, fallback.recordVideo)
        videosFolder = value(.videosFolder, fallback.videosFolder)
        videoFramesPerSecond = value(.videoFramesPerSecond, fallback.videoFramesPerSecond)
        videoMaxWidth = value(.videoMaxWidth, fallback.videoMaxWidth)
        imageMaxWidth = value(.imageMaxWidth, fallback.imageMaxWidth)
        imageQuality = value(.imageQuality, fallback.imageQuality)
        speakerMe = value(.speakerMe, fallback.speakerMe)
        speakerOthers = value(.speakerOthers, fallback.speakerOthers)
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: file) else { return Config() }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            log("Konfiguration \(file.path) ist unlesbar, es gelten die Vorgabewerte: \(error)")
            return Config()
        }
    }

    func save() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.file)
    }

    var notesDirectory: URL {
        URL(fileURLWithPath: vaultPath).appendingPathComponent(notesFolder)
    }

    var imagesDirectory: URL {
        URL(fileURLWithPath: vaultPath).appendingPathComponent(imagesFolder)
    }

    var videosDirectory: URL {
        URL(fileURLWithPath: vaultPath).appendingPathComponent(videosFolder)
    }

    var partialDirectory: URL {
        Self.stateDirectory.appendingPathComponent("partial")
    }
}
