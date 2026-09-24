import AppKit
import Carbon.HIToolbox

struct ParsedShortcut: Equatable {
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags

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
            "The key '\(key)' can't be used in a shortcut."
        case .missingModifier(let shortcut):
            "Shortcut '\(ShortcutParser.display(shortcut))' needs a modifier such as ⌃, ⌥ or ⌘."
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
        "return": 36, "tab": 48, "delete": 51,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98,
        "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111, "f13": 105,
        "f14": 107, "f15": 113, "f16": 106, "f17": 64, "f18": 79, "f19": 80, "f20": 90
    ]

    private static let keyNames: [UInt16: String] = Dictionary(uniqueKeysWithValues: keyCodes.map { ($1, $0) })

    private static let modifierAliases = [
        "ctrl": "ctrl", "control": "ctrl",
        "cmd": "cmd", "command": "cmd", "super": "cmd",
        "opt": "option", "option": "option", "alt": "option",
        "shift": "shift"
    ]

    static func parse(_ shortcut: String, allowBareKey: Bool = false) throws -> ParsedShortcut {
        var modifiers = NSEvent.ModifierFlags()
        var keyName: String?

        for part in shortcutParts(shortcut) {
            switch modifierAliases[part] {
            case "ctrl": modifiers.insert(.control)
            case "cmd": modifiers.insert(.command)
            case "option": modifiers.insert(.option)
            case "shift": modifiers.insert(.shift)
            default: keyName = keyAlias(part)
            }
        }

        guard let keyName else { throw ShortcutError.missingKey(shortcut) }
        guard let keyCode = keyCodes[keyName] else { throw ShortcutError.unsupportedKey(keyName) }
        if modifiers.isEmpty && !isFunctionKey(keyName) && !allowBareKey {
            throw ShortcutError.missingModifier(shortcut)
        }

        return ParsedShortcut(keyCode: keyCode, modifiers: modifiers)
    }

    /// Builds a shortcut string from a key event, e.g. while the user records a new shortcut.
    static func shortcut(from event: NSEvent) -> String? {
        guard let keyName = keyNames[event.keyCode] else { return nil }
        var parts: [String] = []
        let flags = event.modifierFlags
        if flags.contains(.command) { parts.append("cmd") }
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.option) { parts.append("option") }
        if flags.contains(.shift) { parts.append("shift") }
        parts.append(keyName)
        return parts.joined(separator: "+")
    }

    static func canonical(_ shortcut: String) -> String {
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
        for (label, shortcut) in bindings.sorted(by: { $0.key < $1.key }) {
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

    /// Mac-style key cap symbols in the conventional ⌃⌥⇧⌘ order, e.g. ["⌃", "⌥", "Space"].
    static func symbols(_ shortcut: String) -> [String] {
        let canonicalParts = canonical(shortcut).split(separator: "+").map(String.init)
        guard !canonicalParts.isEmpty else { return [] }
        let modifierSymbols = ["ctrl": "⌃", "option": "⌥", "shift": "⇧", "cmd": "⌘"]
        var result = ["ctrl", "option", "shift", "cmd"]
            .filter { canonicalParts.contains($0) }
            .compactMap { modifierSymbols[$0] }
        if let key = canonicalParts.last, modifierSymbols[key] == nil {
            result.append(keySymbol(key))
        }
        return result
    }

    static func display(_ shortcut: String) -> String {
        symbols(shortcut).joined()
    }

    private static func keySymbol(_ key: String) -> String {
        switch key {
        case "space": "Space"
        case "escape": "Esc"
        case "return": "↩"
        case "tab": "⇥"
        case "delete": "⌫"
        case "left": "←"
        case "right": "→"
        case "up": "↑"
        case "down": "↓"
        default: key.uppercased()
        }
    }

    private static func isFunctionKey(_ key: String) -> Bool {
        key.count > 1 && key.hasPrefix("f") && Int(key.dropFirst()) != nil
    }

    private static func shortcutParts(_ shortcut: String) -> [String] {
        // Only "+" separates parts: "-" is a real key ("cmd+-").
        shortcut
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    private static func keyAlias(_ key: String) -> String {
        switch key {
        case " ", "spacebar": "space"
        case "esc": "escape"
        case "enter": "return"
        case "backspace": "delete"
        default: key
        }
    }
}
