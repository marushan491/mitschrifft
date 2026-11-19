import AppKit
import ScreenCaptureKit
import Vision

struct ScreenCapture: Sendable {
    let at: TimeInterval
    let app: String
    let text: String
    let imageFile: String?
}

enum WindowShot {
    static let ignoredTitles = ["kalender", "calendar", "chat", "aktivität", "activity",
                                "teams und kanäle", "einstellungen", "settings", "dateien", "files"]

    static func meetingWindow(matching names: [String], logSelection: Bool = true) async throws -> SCWindow? {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)

        let candidates = content.windows.filter { window in
            guard let owner = window.owningApplication?.applicationName else { return false }
            guard names.contains(where: { owner.localizedCaseInsensitiveContains($0) }) else { return false }
            guard window.windowLayer == 0, window.frame.width > 320, window.frame.height > 240 else { return false }
            let title = window.title ?? ""
            return !ignoredTitles.contains { title.localizedCaseInsensitiveContains($0) }
        }
        guard !candidates.isEmpty else { return nil }

        let order = frontToBackWindowIDs()
        let ranked = candidates.sorted { a, b in
            let ia = order.firstIndex(of: a.windowID) ?? Int.max
            let ib = order.firstIndex(of: b.windowID) ?? Int.max
            if ia != ib { return ia < ib }
            return a.frame.width * a.frame.height > b.frame.width * b.frame.height
        }

        if logSelection, let chosen = ranked.first {
            let titles = ranked.map { "\($0.owningApplication?.applicationName ?? "?") / \($0.title ?? "ohne Titel")" }
            log("Fensterwahl: \(titles.joined(separator: " ; "))")
            return chosen
        }
        return nil
    }

    private static func frontToBackWindowIDs() -> [CGWindowID] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return list.compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
    }

    static func meetingTitle(matching names: [String]) async -> String? {
        guard let window = try? await meetingWindow(matching: names) else { return nil }
        return clean(window.title)
    }

    static func clean(_ raw: String?) -> String? {
        let title = (raw ?? "").replacingOccurrences(of: "\u{200E}", with: "").trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, !title.hasSuffix(" - Slack"), !title.contains(" - Slack ") else { return nil }

        let appSuffixes = ["Microsoft Teams", "Slack", "Zoom", "Zoom Workplace", "Webex", "Discord"]
        let noise = ["besprechung beitreten", "join meeting", "meeting", "besprechung", "window"]
        let parts = title.components(separatedBy: " | ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { part in
                !part.contains("@")
                    && !appSuffixes.contains { part.caseInsensitiveCompare($0) == .orderedSame }
                    && !noise.contains { part.caseInsensitiveCompare($0) == .orderedSame }
            }
        guard let first = parts.first, first.count > 2 else { return nil }
        return first
    }

    static func capture(_ window: SCWindow, scale: Double = 2) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        config.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    static func readText(from image: CGImage, locale: String) async -> String {
        await readLines(from: image, locale: locale).map(\.text).joined(separator: "\n")
    }

    static func readLines(from image: CGImage, locale: String) async -> [(text: String, box: CGRect)] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = [Locale.Language(identifier: locale), Locale.Language(identifier: "en-US")]

        guard let observations = try? await request.perform(on: image) else { return [] }

        return observations
            .sorted { $0.boundingBox.cgRect.minY > $1.boundingBox.cgRect.minY }
            .compactMap { observation in
                guard let line = observation.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces),
                      !line.isEmpty else { return nil }
                return (line, observation.boundingBox.cgRect)
            }
    }

    static func writeImage(_ image: CGImage, to url: URL, maxWidth: Int, quality: Double) throws {
        let source = shrink(image, maxWidth: maxWidth) ?? image
        let rep = NSBitmapImageRep(cgImage: source)
        guard let data = rep.representation(using: .jpeg,
                                            properties: [.compressionFactor: NSNumber(value: quality)])
        else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private static func shrink(_ image: CGImage, maxWidth: Int) -> CGImage? {
        guard image.width > maxWidth, maxWidth > 0 else { return nil }
        let scale = Double(maxWidth) / Double(image.width)
        let width = maxWidth
        let height = max(1, Int(Double(image.height) * scale))
        guard let space = image.colorSpace,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
