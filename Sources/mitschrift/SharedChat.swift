import Foundation

enum SharedChat {
    private static var generation = UUID().uuidString
    private static let directory = Config.stateDirectory.appendingPathComponent("shared-chat")
    private static let file = directory.appendingPathComponent("snapshot.json")

    static func clear(file: URL = SharedChat.file) {
        generation = UUID().uuidString
        try? FileManager.default.removeItem(at: file)
    }

    static func write(_ turns: [ChatTurn], recordingID: String?, configFile: URL = Config.file,
                      directory: URL = SharedChat.directory) {
        let file = directory.appendingPathComponent("snapshot.json")
        guard let data = try? Data(contentsOf: configFile),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              config["shareChat"] as? Bool == true,
              let recordingID else {
            clear(file: file)
            return
        }
        let snapshot: [String: Any] = [
            "recording_id": recordingID,
            "generation": generation,
            "revision": UUID().uuidString,
            "turns": turns.suffix(6).map {
                ["question": String($0.question.prefix(500)), "answer": String($0.answer.prefix(1500))]
            }
        ]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let data = try JSONSerialization.data(withJSONObject: snapshot)
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            clear(file: file)
            log("Chat-Freigabe konnte nicht geschrieben werden.")
        }
    }
}
