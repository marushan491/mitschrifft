import ApplicationServices
import Foundation
import ScreenCaptureKit

struct TeamsCaption: Hashable, Sendable {
    let name: String
    let text: String

    init?(name: String, text: String) {
        guard let name = Self.personName(name), text.count <= 1000,
              Set(Self.words(text)).count >= 4 else { return nil }
        self.name = name
        self.text = text
    }

    static func personName(_ value: String) -> String? {
        let name = value.replacingOccurrences(of: "\u{200e}", with: "")
            .replacingOccurrences(of: "\u{200f}", with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let parts = name.split(separator: " ")
        guard (2...5).contains(parts.count), name.count <= 80,
              parts.allSatisfy({ part in
                  part.first?.isUppercase == true &&
                      part.allSatisfy { $0.isLetter || "-’'.".contains($0) }
              }),
              !parts.contains(where: { ["speaker", "sprecher", "participant", "teilnehmer", "anonymous",
                                        "anonym", "unbekannt", "unknown", "teams"].contains($0.lowercased()) })
        else { return nil }
        return name
    }

    static func words(_ text: String) -> [Substring] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
    }
}

actor TeamsCaptionReader {
    static let appName = "Microsoft Teams"
    private var nextOCR = Date.distantPast

    func read(locale: String) async -> [TeamsCaption]? {
        guard let window = try? await WindowShot.meetingWindow(matching: [Self.appName], logSelection: false),
              let owner = window.owningApplication, owner.bundleIdentifier == "com.microsoft.teams2" else {
            return nil
        }
        let visible = accessibility(in: window, pid: owner.processID)
        if !visible.isEmpty { return visible }
        guard Date() >= nextOCR else { return nil }
        nextOCR = Date().addingTimeInterval(4)
        guard let image = try? await WindowShot.capture(window, scale: 1),
              let crop = image.cropping(to: CGRect(
                x: 0, y: image.height / 2, width: image.width, height: image.height * 47 / 100
              )) else { return nil }
        let lines = await WindowShot.readLines(from: crop, locale: locale)
        return lines.indices.compactMap { index in
            let line = lines[index]
            if let caption = Self.inline(line.text) { return caption }
            guard let name = TeamsCaption.personName(line.text) else { return nil }
            var previous = line.box
            let utterance = lines.dropFirst(index + 1).prefix(3).prefix { below in
                let gap = previous.minY - below.box.maxY
                previous = below.box
                return gap >= -0.006 && gap < 0.060 && abs(line.box.minX - below.box.minX) < 0.04 &&
                    Self.inline(below.text) == nil && TeamsCaption.personName(below.text) == nil
            }.map(\.text).joined(separator: " ")
            return TeamsCaption(name: name, text: utterance)
        }
    }

    private func accessibility(in window: SCWindow, pid: pid_t) -> [TeamsCaption] {
        guard AXIsProcessTrusted(), let title = window.title, !title.isEmpty else { return [] }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.12)
        let windows: [AXUIElement] = Self.attribute(kAXWindowsAttribute, of: app) ?? []
        let exact = windows.filter { (Self.attribute(kAXTitleAttribute, of: $0) as String?) == title }
        guard exact.count == 1, let window = exact.first else { return [] }
        let deadline = Date().addingTimeInterval(0.45)
        var budget = 350
        var regions: [[String]] = []
        func walk(_ element: AXUIElement, depth: Int, region: Int?) {
            guard depth <= 24, budget > 0, Date() < deadline else { return }
            budget -= 1
            let role: String = Self.attribute(kAXRoleAttribute, of: element) ?? ""
            let identifier: String = Self.attribute(kAXIdentifierAttribute, of: element) ?? ""
            let domIdentifier: String = Self.attribute("AXDOMIdentifier", of: element) ?? ""
            let marker = (identifier + " " + domIdentifier).lowercased()
            let description: String = Self.attribute(kAXDescriptionAttribute, of: element) ?? ""
            var activeRegion = region
            if activeRegion == nil, role != kAXButtonRole,
               marker.contains("caption") || role == kAXGroupRole &&
               ["live captions", "liveuntertitel", "live-untertitel", "untertitel"].contains(description.lowercased()) {
                activeRegion = regions.count
                regions.append([])
            }
            if let activeRegion, role == kAXStaticTextRole {
                let value: String = Self.attribute(kAXValueAttribute, of: element)
                    ?? Self.attribute(kAXTitleAttribute, of: element) ?? description
                if !value.isEmpty { regions[activeRegion].append(value) }
            }
            let children: [AXUIElement] = Self.attribute(kAXChildrenAttribute, of: element) ?? []
            for child in children { walk(child, depth: depth + 1, region: activeRegion) }
        }
        walk(window, depth: 0, region: nil)
        return regions.flatMap { region in
            region.indices.compactMap { index in
                if let caption = Self.inline(region[index]) { return caption }
                guard region.indices.contains(index + 1) else { return nil }
                return TeamsCaption(name: region[index], text: region[index + 1])
            }
        }
    }

    private static func attribute<T>(_ name: String, of element: AXUIElement) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func inline(_ line: String) -> TeamsCaption? {
        guard let separator = line.firstIndex(of: ":") else { return nil }
        return TeamsCaption(name: String(line[..<separator]), text: String(line[line.index(after: separator)...]))
    }
}

struct SpeakerAttribution {
    struct Range: Hashable {
        let start: TimeInterval
        let end: TimeInterval

        init(_ segment: Segment) {
            self.init(start: segment.start, end: segment.end)
        }

        init(start: TimeInterval, end: TimeInterval) {
            self.start = start
            self.end = end
        }
    }

    private struct Observation {
        let caption: TeamsCaption
        let at: TimeInterval
        let words: Set<Substring>
        let phrases: Set<[Substring]>
    }

    private var visible: Set<TeamsCaption> = []
    private var recent: [Observation] = []
    private var names: [Range: Set<String>] = [:]

    mutating func observe(_ captions: [TeamsCaption]?, at: TimeInterval) {
        recent.removeAll { at - $0.at > 35 }
        guard let captions else { return }
        let next = Set(captions)
        for caption in next.subtracting(visible) {
            let words = TeamsCaption.words(caption.text)
            recent.append(Observation(caption: caption, at: at, words: Set(words), phrases: Self.phrases(words)))
        }
        visible = next
    }

    @discardableResult
    mutating func add(_ name: String, at range: Range) -> Bool {
        names[range, default: []].insert(name).inserted
    }

    mutating func match(_ segments: [Segment], at now: TimeInterval, sink: SegmentSink?) {
        guard !recent.isEmpty else { return }
        for segment in segments.reversed() where segment.track == .system && segment.end >= now - 52 {
            let tokens = TeamsCaption.words(segment.text)
            let words = Set(tokens)
            guard words.count >= 4 else { continue }
            let phrases = Self.phrases(tokens)
            for item in recent where (-2...14).contains(item.at - segment.end) {
                let common = words.intersection(item.words).count
                guard common >= 4, Double(common) >= 0.80 * Double(max(words.count, item.words.count)),
                      !phrases.isDisjoint(with: item.phrases) else { continue }
                let range = Range(segment)
                if add(item.caption.name, at: range) {
                    sink?.appendSpeakerName(item.caption.name, start: range.start, end: range.end)
                }
            }
        }
    }

    func apply(to segments: [Segment]) -> [Segment] {
        segments.map { segment in
            guard segment.track == .system else { return segment }
            var result = segment
            if !segment.overlappingSpeakers, let matches = names[Range(segment)], matches.count == 1 {
                result.speakerName = matches.first
            } else {
                result.speakerNameUncertain = true
            }
            return result
        }
    }

    private static func phrases(_ words: [Substring]) -> Set<[Substring]> {
        guard words.count >= 4 else { return [] }
        return Set((0...words.count - 4).map { Array(words[$0..<$0 + 4]) })
    }
}
