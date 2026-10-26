import AppKit
import Carbon.HIToolbox

@MainActor
final class HotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static var actions: [UInt32: @MainActor () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private let id: UInt32

    init?(shortcut: String, action: @escaping @MainActor () -> Void) {
        guard let parsed = Self.parse(shortcut) else {
            log("Tastenkuerzel \(shortcut) nicht verstanden, Foto nur ueber das Pet erreichbar.")
            return nil
        }

        id = Self.nextID
        Self.nextID += 1
        Self.actions[id] = action

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            MainActor.assumeIsolated { HotKey.actions[pressed.id]?() }
            return noErr
        }, 1, &spec, nil, &handler)

        let hotKeyID = EventHotKeyID(signature: OSType(0x4D545348), id: id)
        let status = RegisterEventHotKey(parsed.key, parsed.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &reference)
        if status != noErr {
            log("Tastenkuerzel \(shortcut) ist belegt oder wurde abgelehnt (Status \(status)).")
            Self.actions[id] = nil
            return nil
        }
        log("Tastenkuerzel \(shortcut) aktiv.")
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }

    private static let keyCodes: [String: UInt32] = [
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4, "i": 34,
        "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35, "q": 12,
        "r": 15, "s": 1, "t": 17, "u": 32, "v": 9, "w": 13, "x": 7, "y": 16, "z": 6,
        "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        "space": 49, "return": 36
    ]

    static func parse(_ shortcut: String) -> (key: UInt32, modifiers: UInt32)? {
        var modifiers: UInt32 = 0
        var key: UInt32?

        for part in shortcut.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "cmd", "command": modifiers |= UInt32(cmdKey)
            case "shift": modifiers |= UInt32(shiftKey)
            case "alt", "option", "opt": modifiers |= UInt32(optionKey)
            case "ctrl", "control": modifiers |= UInt32(controlKey)
            default: key = keyCodes[part]
            }
        }

        guard let key, modifiers != 0 else { return nil }
        return (key, modifiers)
    }
}
