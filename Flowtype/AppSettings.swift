import AppKit
import Foundation
import Security

enum RetentionPolicy: String, CaseIterable, Identifiable, Sendable {
    case normal
    case twentyFourHours = "24h"
    case never

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal: "Keep history"
        case .twentyFourHours: "Delete after 24 hours"
        case .never: "Don't save transcripts"
        }
    }
}

enum FlowBarPosition: String, CaseIterable, Identifiable, Sendable {
    case bottomCenter
    case bottomRight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bottomCenter: "Bottom center"
        case .bottomRight: "Bottom right"
        }
    }
}

enum TranscriptionProvider: String, CaseIterable, Identifiable, Sendable {
    /// Apple's built-in on-device model (macOS 26+). Raw value "apple".
    case apple
    /// Whisper via WhisperKit, on-device. Raw value kept as "local" for existing settings.
    case local
    case groq

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: "Apple"
        case .local: "Whisper"
        case .groq: "Groq cloud"
        }
    }

    /// Engines this Mac can run.
    static var available: [TranscriptionProvider] {
        AppleSpeech.isSupported ? allCases : allCases.filter { $0 != .apple }
    }

    /// Apple's model where supported (nothing to download), otherwise Whisper.
    static var recommended: TranscriptionProvider {
        AppleSpeech.isSupported ? .apple : .local
    }
}

/// A modifier key that is held down for push-to-talk.
enum HoldKey: String, CaseIterable, Identifiable, Sendable {
    case fn
    case rightOption
    case rightCommand
    case rightControl
    case off

    var id: String { rawValue }

    init(storedValue: String) {
        switch storedValue.lowercased() {
        case "fn", "function", "globe": self = .fn
        case "rightoption", "right_option": self = .rightOption
        case "rightcommand", "right_command": self = .rightCommand
        case "rightcontrol", "right_control": self = .rightControl
        case "off", "none", "": self = .off
        default: self = HoldKey(rawValue: storedValue) ?? .fn
        }
    }

    var title: String {
        switch self {
        case .fn: "Fn / Globe"
        case .rightOption: "Right Option"
        case .rightCommand: "Right Command"
        case .rightControl: "Right Control"
        case .off: "Off"
        }
    }

    var symbol: String {
        switch self {
        case .fn: "fn"
        case .rightOption: "Right ⌥"
        case .rightCommand: "Right ⌘"
        case .rightControl: "Right ⌃"
        case .off: ""
        }
    }

    /// Virtual key code reported by `flagsChanged` events for this key.
    var keyCode: UInt16? {
        switch self {
        case .fn: 63
        case .rightOption: 61
        case .rightCommand: 54
        case .rightControl: 62
        case .off: nil
        }
    }

    /// Device-dependent modifier bit (from IOLLEvent.h) that is set while this exact key is down.
    var deviceFlagMask: UInt {
        switch self {
        case .fn: NSEvent.ModifierFlags.function.rawValue
        case .rightOption: 0x40
        case .rightCommand: 0x10
        case .rightControl: 0x2000
        case .off: 0
        }
    }
}

struct WhisperModelOption: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let detail: String

    static let all: [WhisperModelOption] = [
        WhisperModelOption(id: "openai_whisper-base.en", title: "Base (English)", detail: "~140 MB · fastest, good for short notes"),
        WhisperModelOption(id: "openai_whisper-small.en", title: "Small (English)", detail: "~480 MB · balanced, recommended"),
        WhisperModelOption(id: "openai_whisper-large-v3-v20240930_turbo_632MB", title: "Large v3 Turbo", detail: "~630 MB · most accurate, slower on older Macs")
    ]

    static func option(for id: String) -> WhisperModelOption? {
        all.first { $0.id == id }
    }
}

struct AppSettings: Equatable, Sendable {
    static let defaultTranscriptionModel = "openai_whisper-small.en"
    static let groqTranscriptionModel = "whisper-large-v3-turbo"
    static let transcriptionLanguage = "en"

    var toggleShortcut: String
    var holdKey: HoldKey
    var pasteLastShortcut: String
    var transcriptionProvider: TranscriptionProvider
    var transcriptionModel: String
    var groqAPIKey: String
    var microphoneUID: String
    var flowBarPosition: FlowBarPosition
    var showInDock: Bool
    var showFlowBarWhenIdle: Bool
    var playSounds: Bool
    var restoreClipboardAfterPaste: Bool
    var retentionPolicy: RetentionPolicy

    static var defaults: AppSettings {
        AppSettings(
            toggleShortcut: "ctrl+option+space",
            holdKey: .fn,
            pasteLastShortcut: "cmd+ctrl+v",
            transcriptionProvider: .recommended,
            transcriptionModel: defaultTranscriptionModel,
            groqAPIKey: "",
            microphoneUID: "",
            flowBarPosition: .bottomCenter,
            showInDock: true,
            showFlowBarWhenIdle: true,
            playSounds: true,
            restoreClipboardAfterPaste: true,
            retentionPolicy: .normal
        )
    }

    var hasGroqAPIKey: Bool {
        !groqAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Shortcut bindings that must not collide with each other.
    var shortcutBindings: [String: String] {
        var bindings = ["Hands-free shortcut": toggleShortcut]
        if !pasteLastShortcut.isEmpty {
            bindings["Paste last transcript"] = pasteLastShortcut
        }
        return bindings
    }
}

final class SettingsStore {
    private enum Key {
        static let toggleShortcut = "shortcut.toggle"
        static let holdShortcut = "shortcut.hold"
        static let pasteLastShortcut = "shortcut.pasteLast"
        static let transcriptionProvider = "transcription.provider"
        static let transcriptionModel = "transcription.model"
        static let microphoneUID = "audio.microphoneUID"
        static let flowBarPosition = "flowBar.position"
        static let showFlowBarWhenIdle = "flowBar.showWhenIdle"
        static let showInDock = "app.showInDock"
        static let playSounds = "feedback.playSounds"
        static let restoreClipboardAfterPaste = "clipboard.restoreAfterPaste"
        static let retentionPolicy = "retention.policy"
        static let appleSpeechMigrationDone = "transcription.appleSpeechMigrationDone"
    }

    private let defaults: UserDefaults
    private let apiKeyStore: GroqAPIKeyStoring

    init(defaults: UserDefaults = .standard, apiKeyStore: GroqAPIKeyStoring = KeychainGroqAPIKeyStore()) {
        self.defaults = defaults
        self.apiKeyStore = apiKeyStore
    }

    /// Whether existing users have been considered for the switch to Apple speech (done once).
    var appleSpeechMigrationDone: Bool {
        get { defaults.bool(forKey: Key.appleSpeechMigrationDone) }
        set { defaults.set(newValue, forKey: Key.appleSpeechMigrationDone) }
    }

    func load() -> AppSettings {
        let fallback = AppSettings.defaults
        let toggle = defaults.string(forKey: Key.toggleShortcut).flatMap(Self.validShortcut) ?? fallback.toggleShortcut
        let pasteLast = defaults.string(forKey: Key.pasteLastShortcut).map { $0.isEmpty ? "" : (Self.validShortcut($0) ?? fallback.pasteLastShortcut) }
            ?? fallback.pasteLastShortcut
        return AppSettings(
            toggleShortcut: toggle,
            holdKey: defaults.string(forKey: Key.holdShortcut).map(HoldKey.init(storedValue:)) ?? fallback.holdKey,
            pasteLastShortcut: pasteLast == toggle ? "" : pasteLast,
            transcriptionProvider: Self.availableProvider(defaults.string(forKey: Key.transcriptionProvider)) ?? fallback.transcriptionProvider,
            transcriptionModel: Self.normalizeTranscriptionModel(defaults.string(forKey: Key.transcriptionModel) ?? fallback.transcriptionModel),
            groqAPIKey: apiKeyStore.loadAPIKey(),
            microphoneUID: defaults.string(forKey: Key.microphoneUID) ?? fallback.microphoneUID,
            flowBarPosition: FlowBarPosition(rawValue: defaults.string(forKey: Key.flowBarPosition) ?? "") ?? fallback.flowBarPosition,
            showInDock: defaults.object(forKey: Key.showInDock) as? Bool ?? fallback.showInDock,
            showFlowBarWhenIdle: defaults.object(forKey: Key.showFlowBarWhenIdle) as? Bool ?? fallback.showFlowBarWhenIdle,
            playSounds: defaults.object(forKey: Key.playSounds) as? Bool ?? fallback.playSounds,
            restoreClipboardAfterPaste: defaults.object(forKey: Key.restoreClipboardAfterPaste) as? Bool ?? fallback.restoreClipboardAfterPaste,
            retentionPolicy: RetentionPolicy(rawValue: defaults.string(forKey: Key.retentionPolicy) ?? "") ?? fallback.retentionPolicy
        )
    }

    func save(_ settings: AppSettings) {
        defaults.set(settings.toggleShortcut, forKey: Key.toggleShortcut)
        defaults.set(settings.holdKey.rawValue, forKey: Key.holdShortcut)
        defaults.set(settings.pasteLastShortcut, forKey: Key.pasteLastShortcut)
        defaults.set(settings.transcriptionProvider.rawValue, forKey: Key.transcriptionProvider)
        defaults.set(Self.normalizeTranscriptionModel(settings.transcriptionModel), forKey: Key.transcriptionModel)
        defaults.set(settings.microphoneUID, forKey: Key.microphoneUID)
        defaults.set(settings.flowBarPosition.rawValue, forKey: Key.flowBarPosition)
        defaults.set(settings.showInDock, forKey: Key.showInDock)
        defaults.set(settings.showFlowBarWhenIdle, forKey: Key.showFlowBarWhenIdle)
        defaults.set(settings.playSounds, forKey: Key.playSounds)
        defaults.set(settings.restoreClipboardAfterPaste, forKey: Key.restoreClipboardAfterPaste)
        defaults.set(settings.retentionPolicy.rawValue, forKey: Key.retentionPolicy)
        apiKeyStore.saveAPIKey(settings.groqAPIKey)
    }

    /// A stored engine this Mac can still run (settings may come from a newer macOS or another Mac).
    private static func availableProvider(_ stored: String?) -> TranscriptionProvider? {
        guard let provider = stored.flatMap(TranscriptionProvider.init(rawValue:)) else { return nil }
        return TranscriptionProvider.available.contains(provider) ? provider : nil
    }

    static func normalizeTranscriptionModel(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        // Older builds stored multilingual names such as "small"; map everything unknown to the
        // recommended English model so dictation never silently switches language.
        return WhisperModelOption.option(for: trimmed)?.id ?? AppSettings.defaultTranscriptionModel
    }

    private static func validShortcut(_ shortcut: String) -> String? {
        (try? ShortcutParser.parse(shortcut)) == nil ? nil : ShortcutParser.canonical(shortcut)
    }
}

protocol GroqAPIKeyStoring {
    func loadAPIKey() -> String
    func saveAPIKey(_ apiKey: String)
}

final class KeychainGroqAPIKeyStore: GroqAPIKeyStoring {
    private let service = "studio.infinitumlabs.flowtype"
    private let account = "groq-api-key"

    func loadAPIKey() -> String {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func saveAPIKey(_ apiKey: String) {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != loadAPIKey() else { return }
        let query = baseQuery()
        guard !trimmed.isEmpty else {
            SecItemDelete(query as CFDictionary)
            return
        }

        let data = Data(trimmed.utf8)
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

final class UserDefaultsGroqAPIKeyStore: GroqAPIKeyStoring {
    private let defaults: UserDefaults
    private let key = "transcription.groq.apiKey"

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func loadAPIKey() -> String {
        defaults.string(forKey: key) ?? ""
    }

    func saveAPIKey(_ apiKey: String) {
        defaults.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), forKey: key)
    }
}
