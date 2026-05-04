import Foundation
import Security

enum RetentionPolicy: String, CaseIterable, Identifiable, Sendable {
    case normal
    case twentyFourHours = "24h"
    case never

    var id: String { rawValue }
}

enum FlowBarPosition: String, CaseIterable, Identifiable, Sendable {
    case bottomRight
    case bottomCenter

    var id: String { rawValue }
}

enum TranscriptionProvider: String, CaseIterable, Identifiable, Sendable {
    case local
    case groq

    var id: String { rawValue }
}

enum NotificationPreference: String, CaseIterable, Identifiable, Sendable {
    case tips
    case errors
    case pasteBlocked = "paste_blocked"
    case milestones
    case formatting
    case transcriptStatus = "transcript_status"

    var id: String { rawValue }
}

enum WritingStyleScope: String, CaseIterable, Identifiable, Sendable {
    case personal
    case work
    case email
    case other

    var id: String { rawValue }
}

struct AppSettings: Equatable, Sendable {
    static let defaultTranscriptionModel = "openai_whisper-small.en"
    static let groqTranscriptionModel = "whisper-large-v3-turbo"
    static let defaultTranscriptionLanguage = "en"

    var toggleShortcut: String
    var holdShortcut: String
    var cancelShortcut: String
    var pasteLastShortcut: String
    var scratchpadShortcut: String
    var commandModeShortcut: String
    var transcriptionProvider: TranscriptionProvider
    var transcriptionModel: String
    var groqAPIKey: String
    var transcriptionLanguage: String
    var flowBarPosition: FlowBarPosition
    var restoreClipboardAfterPaste: Bool
    var retentionPolicy: RetentionPolicy
    var notifications: [String: Bool]
    var stylePreferences: [String: String]

    static let defaults = AppSettings(
        toggleShortcut: "ctrl+option+space",
        holdShortcut: "fn",
        cancelShortcut: "escape",
        pasteLastShortcut: "cmd+ctrl+v",
        scratchpadShortcut: "option+s",
        commandModeShortcut: "cmd+shift+space",
        transcriptionProvider: .local,
        transcriptionModel: defaultTranscriptionModel,
        groqAPIKey: "",
        transcriptionLanguage: defaultTranscriptionLanguage,
        flowBarPosition: .bottomRight,
        restoreClipboardAfterPaste: true,
        retentionPolicy: .normal,
        notifications: Dictionary(uniqueKeysWithValues: NotificationPreference.allCases.map { ($0.rawValue, true) }),
        stylePreferences: Dictionary(uniqueKeysWithValues: WritingStyleScope.allCases.map {
            ($0.rawValue, $0 == .personal ? "Casual" : "Formal")
        })
    )
}

final class SettingsStore {
    private enum Key {
        static let toggleShortcut = "shortcut.toggle"
        static let holdShortcut = "shortcut.hold"
        static let cancelShortcut = "shortcut.cancel"
        static let pasteLastShortcut = "shortcut.pasteLast"
        static let scratchpadShortcut = "shortcut.scratchpad"
        static let commandModeShortcut = "shortcut.commandMode"
        static let transcriptionProvider = "transcription.provider"
        static let transcriptionModel = "transcription.model"
        static let transcriptionLanguage = "transcription.language"
        static let flowBarPosition = "flowBar.position"
        static let restoreClipboardAfterPaste = "clipboard.restoreAfterPaste"
        static let retentionPolicy = "retention.policy"
        static let notifications = "notifications.preferences"
        static let styles = "style.preferences"
    }

    private let defaults: UserDefaults
    private let apiKeyStore: GroqAPIKeyStoring

    init(defaults: UserDefaults = .standard, apiKeyStore: GroqAPIKeyStoring = KeychainGroqAPIKeyStore()) {
        self.defaults = defaults
        self.apiKeyStore = apiKeyStore
        registerDefaults()
    }

    func load() -> AppSettings {
        let fallback = AppSettings.defaults
        return AppSettings(
            toggleShortcut: defaults.string(forKey: Key.toggleShortcut) ?? fallback.toggleShortcut,
            holdShortcut: defaults.string(forKey: Key.holdShortcut) ?? fallback.holdShortcut,
            cancelShortcut: defaults.string(forKey: Key.cancelShortcut) ?? fallback.cancelShortcut,
            pasteLastShortcut: defaults.string(forKey: Key.pasteLastShortcut) ?? fallback.pasteLastShortcut,
            scratchpadShortcut: defaults.string(forKey: Key.scratchpadShortcut) ?? fallback.scratchpadShortcut,
            commandModeShortcut: defaults.string(forKey: Key.commandModeShortcut) ?? fallback.commandModeShortcut,
            transcriptionProvider: TranscriptionProvider(rawValue: defaults.string(forKey: Key.transcriptionProvider) ?? "") ?? fallback.transcriptionProvider,
            transcriptionModel: normalizeTranscriptionModel(defaults.string(forKey: Key.transcriptionModel) ?? fallback.transcriptionModel),
            groqAPIKey: apiKeyStore.loadAPIKey(),
            transcriptionLanguage: AppSettings.defaultTranscriptionLanguage,
            flowBarPosition: FlowBarPosition(rawValue: defaults.string(forKey: Key.flowBarPosition) ?? "") ?? fallback.flowBarPosition,
            restoreClipboardAfterPaste: defaults.object(forKey: Key.restoreClipboardAfterPaste) as? Bool ?? fallback.restoreClipboardAfterPaste,
            retentionPolicy: RetentionPolicy(rawValue: defaults.string(forKey: Key.retentionPolicy) ?? "") ?? fallback.retentionPolicy,
            notifications: defaults.dictionary(forKey: Key.notifications) as? [String: Bool] ?? fallback.notifications,
            stylePreferences: defaults.dictionary(forKey: Key.styles) as? [String: String] ?? fallback.stylePreferences
        )
    }

    func save(_ settings: AppSettings) {
        defaults.set(settings.toggleShortcut, forKey: Key.toggleShortcut)
        defaults.set(settings.holdShortcut, forKey: Key.holdShortcut)
        defaults.set(settings.cancelShortcut, forKey: Key.cancelShortcut)
        defaults.set(settings.pasteLastShortcut, forKey: Key.pasteLastShortcut)
        defaults.set(settings.scratchpadShortcut, forKey: Key.scratchpadShortcut)
        defaults.set(settings.commandModeShortcut, forKey: Key.commandModeShortcut)
        defaults.set(settings.transcriptionProvider.rawValue, forKey: Key.transcriptionProvider)
        defaults.set(normalizeTranscriptionModel(settings.transcriptionModel), forKey: Key.transcriptionModel)
        apiKeyStore.saveAPIKey(settings.groqAPIKey)
        defaults.set(AppSettings.defaultTranscriptionLanguage, forKey: Key.transcriptionLanguage)
        defaults.set(settings.flowBarPosition.rawValue, forKey: Key.flowBarPosition)
        defaults.set(settings.restoreClipboardAfterPaste, forKey: Key.restoreClipboardAfterPaste)
        defaults.set(settings.retentionPolicy.rawValue, forKey: Key.retentionPolicy)
        defaults.set(settings.notifications, forKey: Key.notifications)
        defaults.set(settings.stylePreferences, forKey: Key.styles)
    }

    private func registerDefaults() {
        let fallback = AppSettings.defaults
        defaults.register(defaults: [
            Key.toggleShortcut: fallback.toggleShortcut,
            Key.holdShortcut: fallback.holdShortcut,
            Key.cancelShortcut: fallback.cancelShortcut,
            Key.pasteLastShortcut: fallback.pasteLastShortcut,
            Key.scratchpadShortcut: fallback.scratchpadShortcut,
            Key.commandModeShortcut: fallback.commandModeShortcut,
            Key.transcriptionProvider: fallback.transcriptionProvider.rawValue,
            Key.transcriptionModel: fallback.transcriptionModel,
            Key.transcriptionLanguage: AppSettings.defaultTranscriptionLanguage,
            Key.flowBarPosition: fallback.flowBarPosition.rawValue,
            Key.restoreClipboardAfterPaste: fallback.restoreClipboardAfterPaste,
            Key.retentionPolicy: fallback.retentionPolicy.rawValue,
            Key.notifications: fallback.notifications,
            Key.styles: fallback.stylePreferences
        ])
    }

    private func normalizeTranscriptionModel(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return AppSettings.defaultTranscriptionModel }

        // v1 is English-only. Older settings such as "small" select multilingual
        // Whisper models, which can mis-detect English speech as another language.
        if trimmed == "small" || trimmed == "openai_whisper-small" {
            return AppSettings.defaultTranscriptionModel
        }
        if trimmed.contains(".en") {
            return trimmed
        }
        return AppSettings.defaultTranscriptionModel
    }
}

protocol GroqAPIKeyStoring {
    func loadAPIKey() -> String
    func saveAPIKey(_ apiKey: String)
}

final class KeychainGroqAPIKeyStore: GroqAPIKeyStoring {
    private let service = "com.yashgoyal.Flowtype"
    private let account = "groq-api-key"

    func loadAPIKey() -> String {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(baseQuery(returnData: true), &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func saveAPIKey(_ apiKey: String) {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = baseQuery(returnData: false)
        guard !trimmed.isEmpty else {
            SecItemDelete(query)
            return
        }

        let data = Data(trimmed.utf8)
        let updateStatus = SecItemUpdate(query, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQueryDictionary()
            addQuery[kSecValueData as String] = data
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    private func baseQuery(returnData: Bool) -> CFDictionary {
        var query = baseQueryDictionary()
        if returnData {
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
        }
        return query as CFDictionary
    }

    private func baseQueryDictionary() -> [String: Any] {
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
