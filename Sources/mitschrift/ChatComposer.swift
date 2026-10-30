import AppKit
import ImageIO

enum ChatColors {
    static let ink = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.95, green: 0.95, blue: 0.95, alpha: 1)
            : NSColor(srgbRed: 0.08, green: 0.08, blue: 0.08, alpha: 1)
    }
    static let secondary = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.82, green: 0.82, blue: 0.82, alpha: 1)
            : NSColor(srgbRed: 0.24, green: 0.24, blue: 0.24, alpha: 1)
    }
    static let surface = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 0.9)
            : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.9)
    }
}

struct ChatImage: Sendable, Identifiable {
    let id = UUID()
    let name: String
    let jpeg: Data

    init(data: Data, name: String) throws {
        guard data.count <= 20 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600
              ] as CFDictionary),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw CodexError.failed("Bild nicht lesbar oder zu groß. Bitte ein Bild unter 20 MB wählen.")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let flattened = context.makeImage(),
              let encoded = NSBitmapImageRep(cgImage: flattened).representation(using: .jpeg,
                properties: [.compressionFactor: 0.8]), encoded.count <= 2 * 1024 * 1024 else {
            throw CodexError.failed("Bild lässt sich nicht auf 2 MB verkleinern. Bitte einen kleineren Ausschnitt wählen.")
        }
        self.name = String(name.prefix(160))
        jpeg = encoded
    }

    var payload: [String: String] { ["name": name, "data": jpeg.base64EncodedString()] }
    var preview: NSImage { NSImage(data: jpeg)! }
}

struct SlashCommand: Equatable, Sendable {
    let name: String
    let summary: String
    let takesText: Bool

    static let all = [
        SlashCommand(name: "/analyse", summary: "Unabhängige Analyse in PandaOS. Dahinter schreiben, was geprüft werden soll.", takesText: true),
        SlashCommand(name: "/help", summary: "Zeigt alle Befehle.", takesText: false)
    ]

    static func matches(_ text: String) -> [SlashCommand] {
        guard text.hasPrefix("/"), !text.contains(where: \.isWhitespace) else { return [] }
        let typed = text.lowercased()
        return all.filter { $0.name.hasPrefix(typed) }
    }

    static var help: String {
        (all.map { "\($0.name)\($0.takesText ? " <Text>" : ""): \($0.summary)" }
            + ["Tab vervollständigt einen angefangenen Befehl."]).joined(separator: "\n")
    }
}

@MainActor
class ChatTextView: NSTextView {
    static func reader() -> ChatTextView { ChatTextView(usingTextLayoutManager: false) }

    override func keyDown(with event: NSEvent) {
        if !performKeyEquivalent(with: event) { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
              event.modifierFlags.intersection([.command, .control, .option]) == [.command] else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "v": if isEditable { paste(self) }
        case "c": copy(self)
        case "x": if isEditable { cut(self) }
        case "a": selectAll(self)
        case "z":
            if isEditable {
                if event.modifierFlags.contains(.shift) { undoManager?.redo() }
                else { undoManager?.undo() }
            }
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}

@MainActor
final class ChatComposer: ChatTextView {
    private let draftStorage = NSTextStorage()
    var onSend: (() -> Void)?
    var onImages: (([ChatImage]) -> Void)?
    var onError: ((String) -> Void)?
    var onTextChange: (() -> Void)?
    var onComplete: (() -> Bool)?
    let placeholder = NSTextField(labelWithString: "Nachricht schreiben oder ein Bild einfügen …")

    override init(frame: NSRect, textContainer: NSTextContainer? = nil) {
        let container = textContainer ?? NSTextContainer(size:
            NSSize(width: frame.width, height: CGFloat.greatestFiniteMagnitude))
        if textContainer == nil {
            let manager = NSLayoutManager()
            draftStorage.addLayoutManager(manager)
            manager.addTextContainer(container)
        }
        super.init(frame: frame, textContainer: container)
        isRichText = false
        allowsUndo = true
        importsGraphics = false
        font = .systemFont(ofSize: 15)
        textColor = ChatColors.ink
        drawsBackground = false
        textContainerInset = NSSize(width: 10, height: 10)
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        self.textContainer?.widthTracksTextView = true
        setAccessibilityLabel("Nachricht an Luna")
        placeholder.font = font
        placeholder.textColor = ChatColors.secondary
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
            placeholder.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10)
        ])
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func didChangeText() {
        super.didChangeText()
        placeholder.isHidden = !string.isEmpty
        onTextChange?()
    }

    override func insertTab(_ sender: Any?) {
        if onComplete?() != true { super.insertTab(sender) }
    }

    override func insertNewline(_ sender: Any?) {
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            super.insertNewline(sender)
        } else {
            onSend?()
        }
    }

    override func keyDown(with event: NSEvent) {
        if !hasMarkedText(), [UInt16(36), 76].contains(event.keyCode),
           !event.modifierFlags.contains(.command) {
            guard isEditable else { return }
            if event.modifierFlags.contains(.shift) { super.insertNewline(self) }
            else { onSend?() }
        } else {
            super.keyDown(with: event)
        }
    }

    override func paste(_ sender: Any?) {
        guard isEditable else { return }
        if !insertImages(from: .general) { super.paste(sender) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isEditable else { return [] }
        return sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self, NSImage.self], options: nil)
            ? .copy : super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isEditable else { return false }
        return insertImages(from: sender.draggingPasteboard) || super.performDragOperation(sender)
    }

    @discardableResult
    func insertImages(from pasteboard: NSPasteboard) -> Bool {
        do {
            if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
               !urls.isEmpty {
                try attach(urls)
                return true
            }
            if pasteboard.string(forType: .string) != nil { return false }
            if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
                onImages?([try ChatImage(data: data, name: "Eingefügtes Bild")])
                return true
            }
        } catch {
            onError?(error.localizedDescription)
            return true
        }
        return false
    }

    func attach(_ urls: [URL]) throws {
        guard urls.count <= 4 else { throw CodexError.failed("Bis zu vier Bilder pro Nachricht möglich.") }
        let images = try urls.map { url -> ChatImage in
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 20 * 1024 * 1024 else {
                throw CodexError.failed("\(url.lastPathComponent) ist größer als 20 MB.")
            }
            return try ChatImage(data: Data(contentsOf: url), name: url.lastPathComponent)
        }
        onImages?(images)
    }
}
