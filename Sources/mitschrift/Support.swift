import Foundation

let stderrLock = NSLock()

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    stderrLock.lock()
    FileHandle.standardError.write(Data("[\(stamp)] \(message)\n".utf8))
    stderrLock.unlock()
}

func liveLog(_ segment: Segment) {
    let who = segment.track == .mic ? "Ich" : "Andere"
    print("[\(formatClock(segment.start))] \(who): \(segment.text)")
    fflush(stdout)
}

func formatClock(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "00:00" }
    let total = Int(seconds.rounded(.down))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
    return String(format: "%02d:%02d", minutes, secs)
}
