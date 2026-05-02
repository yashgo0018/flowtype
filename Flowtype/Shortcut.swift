import AppKit
import Carbon.HIToolbox

struct ParsedShortcut: Equatable {
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags
    let display: String

    var carbonModifiers: UInt32 {
        var value: UInt32 = 0
        if modifiers.contains(.command) {
            value |= UInt32(cmdKey)
        }
        if modifiers.contains(.shift) {
            value |= UInt32(shiftKey)
        }
        if modifiers.contains(.option) {
            value |= UInt32(optionKey)
        }
        if modifiers.contains(.control) {
            value |= UInt32(controlKey)
        }
        return value
    }
}

enum ShortcutError: LocalizedError, Equatable {
    case missingKey(String)
    case unsupportedKey(String)
    case missingModifier(String)
    case registrationFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingKey(let shortcut):
            "Shortcut '\(shortcut)' is missing a non-modifier key."
        case .unsupportedKey(let key):
            "Shortcut key '\(key)' is not supported yet."
        case .missingModifier(let shortcut):
            "Shortcut '\(shortcut)' needs a modifier unless it is a function key."
        case .registrationFailed(let message):
            message
        }
    }
}

enum ShortcutParser {
    static let keyCodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
        "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "space": 49, "`": 50, "escape": 53,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98,
        "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111, "f13": 105,
        "f14": 107, "f15": 113, "f16": 106, "f17": 64, "f18": 79, "f19": 80, "f20": 90
    ]

    static func parse(_ shortcut: String, allowBareEscape: Bool = false) throws -> ParsedShortcut {
        let parts = shortcutParts(shortcut)
        var modifiers = NSEvent.ModifierFlags()
        var keyName: String?

        for part in parts {
            switch part {
            case "ctrl", "control":
                modifiers.insert(.control)
            case "cmd", "command", "super":
                modifiers.insert(.command)
            case "opt", "option", "alt":
                modifiers.insert(.option)
            case "shift":
                modifiers.insert(.shift)
            default:
                keyName = keyAlias(part)
            }
        }

        guard let keyName else { throw ShortcutError.missingKey(shortcut) }
        guard let keyCode = keyCodes[keyName] else { throw ShortcutError.unsupportedKey(keyName) }
        if modifiers.isEmpty && !keyName.hasPrefix("f") && !(allowBareEscape && keyName == "escape") {
            throw ShortcutError.missingModifier(shortcut)
        }

        return ParsedShortcut(keyCode: keyCode, modifiers: modifiers, display: display(shortcut))
    }

    static func canonical(_ shortcut: String) -> String {
        let modifierAliases = [
            "ctrl": "ctrl", "control": "ctrl",
            "cmd": "cmd", "command": "cmd", "super": "cmd",
            "opt": "option", "option": "option", "alt": "option",
            "shift": "shift"
        ]
        let modifierOrder = ["cmd", "ctrl", "option", "shift"]
        var modifiers = Set<String>()
        var keyName: String?

        for part in shortcutParts(shortcut) {
            if let modifier = modifierAliases[part] {
                modifiers.insert(modifier)
            } else {
                keyName = keyAlias(part)
            }
        }

        var ordered = modifierOrder.filter { modifiers.contains($0) }
        if let keyName {
            ordered.append(keyName)
        }
        return ordered.joined(separator: "+")
    }

    static func conflicts(_ bindings: [String: String]) -> [String] {
        var seen: [String: String] = [:]
        var conflicts: [String] = []
        for (label, shortcut) in bindings {
            let canonical = canonical(shortcut)
            guard !canonical.isEmpty else { continue }
            if let previous = seen[canonical] {
                conflicts.append("\(label) conflicts with \(previous) (\(display(shortcut)))")
            } else {
                seen[canonical] = label
            }
        }
        return conflicts.sorted()
    }

    static func matches(_ event: NSEvent, shortcut: ParsedShortcut) -> Bool {
        guard event.keyCode == shortcut.keyCode else { return false }
        let relevant: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        return event.modifierFlags.intersection(relevant) == shortcut.modifiers
    }

    static func display(_ shortcut: String) -> String {
        let labels = [
            "ctrl": "Ctrl", "control": "Ctrl",
            "cmd": "Cmd", "command": "Cmd", "super": "Cmd",
            "opt": "Option", "option": "Option", "alt": "Option",
            "shift": "Shift", "space": "Space", "spacebar": "Space",
            "fn": "Fn", "function": "Fn", "globe": "Fn",
            "esc": "Esc", "escape": "Esc"
        ]
        return shortcutParts(shortcut)
            .map { labels[$0] ?? ($0.hasPrefix("f") ? $0.uppercased() : $0) }
            .joined(separator: "+")
    }

    private static func shortcutParts(_ shortcut: String) -> [String] {
        shortcut.replacingOccurrences(of: "-", with: "+")
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    private static func keyAlias(_ key: String) -> String {
        switch key {
        case " ", "spacebar":
            "space"
        case "esc":
            "escape"
        case "function", "globe":
            "fn"
        default:
            key
        }
    }
}
