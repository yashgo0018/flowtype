import XCTest
@testable import Flowtype

final class SettingsStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "SettingsStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeStore() -> SettingsStore {
        SettingsStore(defaults: defaults, apiKeyStore: UserDefaultsGroqAPIKeyStore(defaults: defaults))
    }

    func testDefaults() {
        let settings = makeStore().load()

        XCTAssertEqual(settings, AppSettings.defaults)
        XCTAssertEqual(settings.toggleShortcut, "ctrl+option+space")
        XCTAssertEqual(settings.holdKey, .fn)
        XCTAssertEqual(settings.transcriptionProvider, TranscriptionProvider.recommended)
        XCTAssertEqual(settings.transcriptionModel, "openai_whisper-small.en")
        XCTAssertEqual(settings.groqAPIKey, "")
        XCTAssertTrue(settings.restoreClipboardAfterPaste)
        XCTAssertTrue(settings.showInDock)
    }

    func testSaveAndReloadSettings() {
        let store = makeStore()
        var settings = store.load()
        settings.toggleShortcut = "cmd+shift+space"
        settings.holdKey = .rightOption
        settings.pasteLastShortcut = ""
        settings.flowBarPosition = .bottomRight
        settings.retentionPolicy = .never
        settings.transcriptionProvider = .groq
        settings.transcriptionModel = "openai_whisper-base.en"
        settings.groqAPIKey = "  test-key  "
        settings.playSounds = false
        settings.showFlowBarWhenIdle = false
        settings.showInDock = false

        store.save(settings)
        let reloaded = makeStore().load()

        XCTAssertEqual(reloaded.toggleShortcut, "cmd+shift+space")
        XCTAssertEqual(reloaded.holdKey, .rightOption)
        XCTAssertEqual(reloaded.pasteLastShortcut, "")
        XCTAssertEqual(reloaded.flowBarPosition, .bottomRight)
        XCTAssertEqual(reloaded.retentionPolicy, .never)
        XCTAssertEqual(reloaded.transcriptionProvider, .groq)
        XCTAssertEqual(reloaded.transcriptionModel, "openai_whisper-base.en")
        XCTAssertEqual(reloaded.groqAPIKey, "test-key")
        XCTAssertFalse(reloaded.playSounds)
        XCTAssertFalse(reloaded.showFlowBarWhenIdle)
        XCTAssertFalse(reloaded.showInDock)
    }

    func testLegacyAndInvalidValuesFallBack() {
        defaults.set("small", forKey: "transcription.model")
        defaults.set("globe", forKey: "shortcut.hold")
        defaults.set("banana", forKey: "shortcut.toggle")
        defaults.set("control+command+v", forKey: "shortcut.pasteLast")

        let settings = makeStore().load()

        XCTAssertEqual(settings.transcriptionModel, AppSettings.defaultTranscriptionModel)
        XCTAssertEqual(settings.holdKey, .fn)
        XCTAssertEqual(settings.toggleShortcut, AppSettings.defaults.toggleShortcut)
        XCTAssertEqual(settings.pasteLastShortcut, "cmd+ctrl+v")
    }

    func testMeetingShortcutIsAvailableWithoutChangingDictationDefaults() {
        let settings = makeStore().load()

        XCTAssertEqual(settings.shortcutBindings["Meeting capture"], "cmd+ctrl+m")
        XCTAssertEqual(settings.toggleShortcut, "ctrl+option+space")
        XCTAssertEqual(settings.pasteLastShortcut, "cmd+ctrl+v")
    }

    func testStoredMeetingShortcutIsCanonicalizedAndSurvivesSavingOtherSettings() {
        defaults.set("control+command+shift+m", forKey: "meeting.shortcut")
        let store = makeStore()
        var settings = store.load()
        XCTAssertEqual(settings.shortcutBindings["Meeting capture"], "cmd+ctrl+shift+m")

        settings.playSounds = false
        store.save(settings)
        let reloaded = makeStore().load()

        XCTAssertEqual(reloaded.shortcutBindings["Meeting capture"], "cmd+ctrl+shift+m")
        XCTAssertEqual(defaults.string(forKey: "meeting.shortcut"), "cmd+ctrl+shift+m")
        XCTAssertFalse(reloaded.playSounds)
    }

    func testMeetingShortcutConflictDisablesOnlyMeetingBinding() {
        for existing in [AppSettings.defaults.toggleShortcut, AppSettings.defaults.pasteLastShortcut] {
            defaults.set(existing, forKey: "meeting.shortcut")
            let settings = makeStore().load()

            XCTAssertNil(settings.shortcutBindings["Meeting capture"])
            XCTAssertEqual(settings.toggleShortcut, AppSettings.defaults.toggleShortcut)
            XCTAssertEqual(settings.pasteLastShortcut, AppSettings.defaults.pasteLastShortcut)
            XCTAssertTrue(ShortcutParser.conflicts(settings.shortcutBindings).isEmpty)
        }
    }

    func testDisabledOrInvalidMeetingShortcutStaysUnregisteredAfterSaving() {
        for shortcut in ["", "cmd+fn", "fn+cmd", "banana"] {
            defaults.set(shortcut, forKey: "meeting.shortcut")
            let store = makeStore()
            let settings = store.load()
            XCTAssertNil(settings.shortcutBindings["Meeting capture"])

            store.save(settings)

            XCTAssertEqual(defaults.string(forKey: "meeting.shortcut"), "")
            XCTAssertNil(makeStore().load().shortcutBindings["Meeting capture"])
        }
    }

    func testMeetingDefaultCannotHijackAnExistingDictationBinding() {
        defaults.set("control+command+m", forKey: "shortcut.toggle")
        let settings = makeStore().load()

        XCTAssertEqual(settings.toggleShortcut, "cmd+ctrl+m")
        XCTAssertNil(settings.shortcutBindings["Meeting capture"])
        XCTAssertTrue(ShortcutParser.conflicts(settings.shortcutBindings).isEmpty)
    }
}
