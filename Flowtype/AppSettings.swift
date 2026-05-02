import Foundation

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

struct AppSettings: Equatable, Sendable {
    static let defaultTranscriptionModel = "openai_whisper-small.en"

    var toggleShortcut: String
    var holdShortcut: String
    var cancelShortcut: String
    var pasteLastShortcut: String
    var scratchpadShortcut: String
    var commandModeShortcut: String
    var transcriptionModel: String
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
        transcriptionModel: defaultTranscriptionModel,
        transcriptionLanguage: "en",
        flowBarPosition: .bottomRight,
        restoreClipboardAfterPaste: true,
        retentionPolicy: .normal,
        notifications: [
            "tips": true,
            "errors": true,
            "paste_blocked": true,
            "milestones": true,
            "formatting": true,
            "transcript_status": true
        ],
        stylePreferences: [
            "personal": "Casual",
            "work": "Formal",
            "email": "Formal",
            "other": "Formal"
        ]
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
        static let transcriptionModel = "transcription.model"
        static let transcriptionLanguage = "transcription.language"
        static let flowBarPosition = "flowBar.position"
        static let restoreClipboardAfterPaste = "clipboard.restoreAfterPaste"
        static let retentionPolicy = "retention.policy"
        static let notifications = "notifications.preferences"
        static let styles = "style.preferences"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
            transcriptionModel: normalizeTranscriptionModel(defaults.string(forKey: Key.transcriptionModel) ?? fallback.transcriptionModel),
            transcriptionLanguage: "en",
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
        defaults.set(normalizeTranscriptionModel(settings.transcriptionModel), forKey: Key.transcriptionModel)
        defaults.set("en", forKey: Key.transcriptionLanguage)
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
            Key.transcriptionModel: fallback.transcriptionModel,
            Key.transcriptionLanguage: "en",
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
