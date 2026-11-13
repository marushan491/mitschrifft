import Foundation

enum LiveState {
    private static let instanceID = UUID().uuidString
    private static let file = Config.stateDirectory.appendingPathComponent("live-state.json")

    static func write(recordingID: String?, file: URL = LiveState.file) {
        var state: [String: Any] = ["status": recordingID == nil ? "idle" : "recording",
                                    "pid": ProcessInfo.processInfo.processIdentifier,
                                    "instance_id": instanceID,
                                    "updated_at": Date().timeIntervalSince1970]
        if let recordingID { state["recording_id"] = recordingID }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: state).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            clear(file: file)
        }
    }

    static func clear(file: URL = LiveState.file) {
        try? FileManager.default.removeItem(at: file)
    }
}
