import ApplicationServices
import Foundation
import ScreenCaptureKit

enum MeetingSpeakerApp: Hashable, Sendable {
    case teams, slack

    static let teamsName = "Microsoft Teams"

    init?(appName: String) {
        switch appName.lowercased() {
        case Self.teamsName.lowercased(): self = .teams
        case "slack": self = .slack
        default: return nil
        }
    }

    var bundleID: String {
        self == .teams ? "com.microsoft.teams2" : "com.tinyspeck.slackmacgap"
    }

    func isCallTitle(_ title: String) -> Bool {
        if self == .slack {
            return title.localizedCaseInsensitiveContains("Huddle") ||
                title.localizedCaseInsensitiveContains("Zusammenkunft")
        }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !title.isEmpty && title.caseInsensitiveCompare(Self.teamsName) != .orderedSame &&
            !MeetingSpeakerReader.isCaptionTitle(title) &&
            !WindowShot.ignoredTitles.contains(where: title.localizedCaseInsensitiveContains)
    }
}

struct MeetingSpeakerSample: Sendable {
    var captions: [TeamsCaption]?
    var activeNames: Set<String> = []
    var observedUptime: TimeInterval
}

actor MeetingSpeakerReader {
    private typealias OCRLine = (text: String, box: CGRect)

    private struct AXNode {
        let parent: Int?
        let role: String
        let label: [String]
        let marker: String
        var last: Int
    }

    private let app: MeetingSpeakerApp
    private var nextOCR = Date.distantPast

    init(app: MeetingSpeakerApp) { self.app = app }

    func read(locale: String, meetingTitle: String?) async -> MeetingSpeakerSample? {
        guard let visible = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        else { return nil }
        let windows = visible.windows.filter {
            $0.owningApplication?.bundleIdentifier == app.bundleID && $0.windowLayer == 0 &&
                $0.frame.width > 200 && $0.frame.height > 140
        }
        let calls = windows.filter { app.isCallTitle($0.title ?? "") }
        let separate = windows.filter { Self.isCaptionTitle($0.title ?? "") }
        let titled = meetingTitle.map { expected in
            calls.filter { WindowShot.clean($0.title) == expected }
        } ?? []
        guard let call = titled.count == 1 ? titled.first : (calls.count == 1 ? calls.first : nil)
        else { return nil }
        let captionsWindow = app == .teams && separate.count == 1 ? separate.first : nil
        var sample = MeetingSpeakerSample(observedUptime: ProcessInfo.processInfo.systemUptime)
        let callTree = Self.axTree(for: call)
        sample.activeNames = Set(Self.activeSpeakers(in: callTree))
        if app == .teams {
            let nodes = captionsWindow.map { Self.axTree(for: $0) } ?? callTree
            let captions = Self.axCaptions(in: nodes, wholeWindow: captionsWindow != nil)
            if !captions.isEmpty { sample.captions = captions }
        }
        let needFrame = sample.activeNames.isEmpty
        let needCaptions = app == .teams && sample.captions == nil
        guard needFrame || needCaptions, Date() >= nextOCR else { return sample }
        nextOCR = Date().addingTimeInterval(4)
        if needFrame || needCaptions && captionsWindow == nil,
           let image = try? await WindowShot.capture(call, scale: 1) {
            let uptime = ProcessInfo.processInfo.systemUptime
            let lines = await WindowShot.readLines(from: image, locale: locale)
            if needFrame {
                sample.activeNames = Set(MeetingSpeakerFrame.names(in: image, lines: lines,
                    style: app == .teams ? .teams : .slack))
                sample.observedUptime = uptime
            }
            if needCaptions && captionsWindow == nil {
                let captions = Self.ocrCaptions(lines, wholeWindow: false)
                if !captions.isEmpty { sample.captions = captions }
            }
        }
        if needCaptions, let captionsWindow, let image = try? await WindowShot.capture(captionsWindow, scale: 1) {
            let captions = Self.ocrCaptions(await WindowShot.readLines(from: image, locale: locale), wholeWindow: true)
            if !captions.isEmpty { sample.captions = captions }
        }
        return sample
    }

    static func isCaptionTitle(_ text: String) -> Bool {
        let compact = text.lowercased().filter(\.isLetter)
        return ["liveuntertitel", "livecaptions", "closedcaption", "closedcaptions"].contains(compact)
    }

    private static func axTree(for window: SCWindow) -> [AXNode] {
        guard AXIsProcessTrusted(), let owner = window.owningApplication, let title = window.title,
              !title.isEmpty else { return [] }
        let application = AXUIElementCreateApplication(owner.processID)
        AXUIElementSetMessagingTimeout(application, 0.08)
        let windows: [AXUIElement] = attribute(kAXWindowsAttribute, of: application) ?? []
        let exact = windows.filter { (attribute(kAXTitleAttribute, of: $0) as String?) == title }
        guard exact.count == 1, let root = exact.first else { return [] }
        let deadline = ProcessInfo.processInfo.systemUptime + 1.0
        let fields = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
                      "AXValueDescription", kAXIdentifierAttribute, "AXDOMIdentifier", kAXChildrenAttribute]
        var nodes: [AXNode] = []
        func walk(_ element: AXUIElement, depth: Int, parent: Int?) {
            guard depth <= 26, nodes.count < 600, ProcessInfo.processInfo.systemUptime < deadline else { return }
            var raw: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, fields as CFArray, [], &raw) == .success,
                  let data = raw as? [Any], data.count == fields.count else { return }
            let role = data[0] as? String ?? ""
            let title = data[1] as? String ?? ""
            let description = data[2] as? String ?? ""
            let value = data[3] as? String ?? ""
            let valueDescription = data[4] as? String ?? ""
            let identifier = data[5] as? String ?? ""
            let dom = data[6] as? String ?? ""
            let index = nodes.count
            nodes.append(AXNode(parent: parent, role: role,
                label: [value, title, description, valueDescription].filter { !$0.isEmpty },
                marker: (identifier + " " + dom).lowercased(), last: index + 1))
            let children = data[7] as? [AXUIElement] ?? []
            for child in children { walk(child, depth: depth + 1, parent: index) }
            nodes[index].last = nodes.count
        }
        walk(root, depth: 0, parent: nil)
        return nodes
    }

    private static func attribute<T>(_ name: String, of element: AXUIElement) -> T? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result as? T
    }

    private static func axCaptions(in nodes: [AXNode], wholeWindow: Bool) -> [TeamsCaption] {
        var scopes: Set<Int> = wholeWindow && !nodes.isEmpty ? [0] : []
        for index in nodes.indices {
            let node = nodes[index]
            guard node.role != kAXButtonRole else { continue }
            let heading = node.label.contains(where: isCaptionTitle)
            if node.marker.contains("caption"), node.last > index + 2 {
                scopes.insert(index)
            } else if heading {
                let container = node.role == kAXStaticTextRole || node.role == "AXHeading"
                    ? node.parent ?? index : index
                if container != 0 || wholeWindow { scopes.insert(container) }
            }
        }
        var captions: Set<TeamsCaption> = []
        for scope in scopes {
            let lines = (scope..<nodes[scope].last).filter { nodes[$0].role == kAXStaticTextRole }
            for index in lines.indices {
                let node = nodes[lines[index]]
                guard let line = node.label.first else { continue }
                if let inline = inlineCaption(line) { captions.insert(inline); continue }
                guard let name = TeamsCaption.personName(line), let parent = node.parent else { continue }
                let following = lines.dropFirst(index + 1).prefix(6).prefix { $0 < nodes[parent].last }
                    .compactMap { nodes[$0].label.first }
                let nearby = following.prefix {
                    TeamsCaption.personName($0) == nil && !isAvatarInitials($0) && !isCaptionTitle($0)
                }.joined(separator: " ")
                if let caption = TeamsCaption(name: name, text: nearby) {
                    captions.insert(caption)
                } else if lines.indices.contains(index + 1), let next = nodes[lines[index + 1]].label.first,
                          TeamsCaption.personName(next) == nil, let caption = TeamsCaption(name: name, text: next) {
                    captions.insert(caption)
                }
            }
        }
        return Array(captions)
    }

    private static func activeSpeakers(in nodes: [AXNode]) -> [String] {
        let beginning = #"^(?:aktiver sprecher|active speaker|currently speaking|spricht gerade)\s*[:,–-]\s*"#
        let ending = #"\s*(?:[,–-]\s*)?(?:is speaking|is currently speaking|currently speaking|spricht(?: gerade)?)\.?$"#
        return nodes.indices.compactMap { index in
            let node = nodes[index]
            if [kAXStaticTextRole, kAXTextFieldRole, kAXTextAreaRole, "AXWebArea"].contains(node.role) {
                return nil
            }
            for text in node.label where text.count < 120 {
                let value = text.replacingOccurrences(of: beginning, with: "", options: [.regularExpression, .caseInsensitive])
                    .replacingOccurrences(of: ending, with: "", options: [.regularExpression, .caseInsensitive])
                if value != text, let name = TeamsCaption.personName(value) { return name }
            }
            let explicit = node.label.contains { ["speaking", "is speaking", "spricht", "spricht gerade"].contains($0.lowercased()) } ||
                node.marker.contains("is-speaking") || node.marker.contains("active-speaker")
            guard explicit else { return nil }
            for scope in [index, node.parent].compactMap({ $0 }) {
                let names = Set(nodes[scope..<min(nodes[scope].last, scope + 12)].flatMap(\.label)
                    .compactMap(TeamsCaption.personName))
                if names.count == 1 { return names.first }
            }
            return nil
        }
    }

    private static func ocrCaptions(_ lines: [OCRLine], wholeWindow: Bool) -> [TeamsCaption] {
        let heading = lines.first { isCaptionTitle($0.text) }
        let minimumX = !wholeWindow && (heading?.box.minX ?? 0) >= 0.45
            ? max(0.40, (heading?.box.minX ?? 0) - 0.12) : 0
        let top = heading?.box.minY ?? (wholeWindow ? 1 : 0.53)
        let panel = lines.filter { $0.box.minX >= minimumX && $0.box.midY < top }
        let anchors: [(index: Int, name: String, box: CGRect)] = panel.indices.compactMap { index in
            let line = panel[index]
            if let separator = line.text.firstIndex(of: " ") {
                let prefix = String(line.text[..<separator])
                let remainder = String(line.text[line.text.index(after: separator)...])
                if isAvatarInitials(prefix), let candidate = TeamsCaption.personName(remainder),
                   nameInitials(candidate) == prefix {
                    return (index, candidate, line.box)
                }
            }
            guard let name = TeamsCaption.personName(line.text) else { return nil }
            let initials = nameInitials(name)
            let nearbyAvatar = panel.contains {
                $0.text == initials && $0.box.maxX <= line.box.minX + 0.008 &&
                    line.box.minX - $0.box.maxX < 0.10 &&
                    abs(line.box.midY - $0.box.midY) <= max(0.025, line.box.height * 1.6)
            }
            guard nearbyAvatar else { return nil }
            return (index, name, line.box)
        }
        var captions: [TeamsCaption] = []
        for (position, anchor) in anchors.enumerated() {
            let limit = anchors.indices.contains(position + 1) ? anchors[position + 1].index : panel.count
            var previous = anchor.box
            let text = panel[(anchor.index + 1)..<limit].filter { !isAvatarInitials($0.text) }.prefix(6).prefix { line in
                let gap = previous.minY - line.box.maxY
                previous = line.box
                return gap >= -0.012 && gap < 0.055 && abs(line.box.minX - anchor.box.minX) < 0.10
            }.map(\.text).joined(separator: " ")
            if let caption = TeamsCaption(name: anchor.name, text: text) { captions.append(caption) }
        }
        return captions
    }

    private static func inlineCaption(_ line: String) -> TeamsCaption? {
        guard let separator = line.firstIndex(of: ":") else { return nil }
        return TeamsCaption(name: String(line[..<separator]), text: String(line[line.index(after: separator)...]))
    }

    private static func isAvatarInitials(_ value: String) -> Bool {
        value.count == 2 && value.allSatisfy(\.isUppercase)
    }

    private static func nameInitials(_ name: String) -> String {
        let parts = name.split(separator: " ")
        return [parts.first?.first, parts.last?.first].compactMap { $0 }.map(String.init).joined()
    }
}
