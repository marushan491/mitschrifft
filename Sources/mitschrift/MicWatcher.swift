import AppKit
import CoreAudio
import Darwin
import Foundation

struct AudioUser: Equatable {
    let pid: pid_t
    let name: String
    let input: Bool
    let output: Bool
}

enum AudioProcesses {
    static func active(excluding ownPid: pid_t) -> [AudioUser] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0
        else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var objects = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr
        else { return [] }

        var users: [AudioUser] = []
        for object in objects {
            let input = boolProperty(object, kAudioProcessPropertyIsRunningInput)
            let output = boolProperty(object, kAudioProcessPropertyIsRunningOutput)
            guard input || output else { continue }
            guard let pid = pidProperty(object), pid != ownPid else { continue }
            users.append(AudioUser(pid: pid, name: appName(for: pid), input: input, output: output))
        }
        return users
    }

    private static func boolProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    private static func pidProperty(_ object: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func appName(for pid: pid_t) -> String {
        if let app = NSRunningApplication(processIdentifier: pid),
           let name = app.localizedName ?? app.bundleIdentifier {
            return name
        }
        var buffer = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
            return URL(fileURLWithPath: String(cString: buffer)).lastPathComponent
        }
        return "PID \(pid)"
    }
}

struct MeetingDetector {
    let config: Config
    private let ownPid = ProcessInfo.processInfo.processIdentifier

    func allUsers() -> [AudioUser] {
        AudioProcesses.active(excluding: ownPid)
    }

    static let systemDaemons = [
        "historicalaudiod", "coreaudiod", "replayd", "audiomxd", "corespeechd",
        "SystemUIServer", "loginwindow", "mediaanalysisd", "universalaccessd",
        "screencapture", "Mitschrift"
    ]

    func startCandidates() -> [AudioUser] {
        candidates().filter { user in
            if matches(user.name, config.meetingApps) { return user.output }
            return user.input && (config.onlyApps.isEmpty || matches(user.name, config.onlyApps))
        }
    }

    func stillTalking() -> [AudioUser] {
        candidates().filter { user in
            if matches(user.name, config.meetingApps) { return user.input || user.output }
            return user.input && (config.onlyApps.isEmpty || matches(user.name, config.onlyApps))
        }
    }

    static let mediaPlayers = [
        "Spotify", "Music", "iTunes", "TV", "Podcasts", "VLC", "IINA", "QuickTime",
        "Netflix", "Plex", "Infuse", "Audacity", "GarageBand", "Logic Pro", "mpv"
    ]

    private func candidates() -> [AudioUser] {
        allUsers().filter { user in
            if matches(user.name, Self.systemDaemons) { return false }
            if exactly(user.name, Self.mediaPlayers) { return false }
            if matches(user.name, config.neverTriggerApps) { return false }
            if matches(user.name, config.ignoreApps) { return false }
            return true
        }
    }

    private func exactly(_ name: String, _ patterns: [String]) -> Bool {
        let clean = name.trimmingCharacters(in: .whitespaces)
        return patterns.contains { $0.caseInsensitiveCompare(clean) == .orderedSame }
    }

    private func matches(_ name: String, _ patterns: [String]) -> Bool {
        patterns.contains { name.localizedCaseInsensitiveContains($0) }
    }
}
