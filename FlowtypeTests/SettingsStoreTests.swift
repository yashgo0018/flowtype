import XCTest
@testable import Flowtype

final class SettingsStoreTests: XCTestCase {
    func testDefaultsAreRegistered() {
        let suiteName = "SettingsStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults, apiKeyStore: UserDefaultsGroqAPIKeyStore(defaults: defaults))

        let settings = store.load()

        XCTAssertEqual(settings.toggleShortcut, "ctrl+option+space")
        XCTAssertEqual(settings.holdShortcut, "fn")
        XCTAssertEqual(settings.cancelShortcut, "escape")
        XCTAssertEqual(settings.transcriptionProvider, .local)
        XCTAssertEqual(settings.transcriptionModel, "openai_whisper-small.en")
        XCTAssertEqual(settings.groqAPIKey, "")
        XCTAssertEqual(settings.transcriptionLanguage, "en")
        XCTAssertTrue(settings.restoreClipboardAfterPaste)
    }

    func testSaveAndReloadSettings() {
        let suiteName = "SettingsStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults, apiKeyStore: UserDefaultsGroqAPIKeyStore(defaults: defaults))
        var settings = store.load()
        settings.toggleShortcut = "cmd+shift+space"
        settings.flowBarPosition = .bottomCenter
        settings.retentionPolicy = .never
        settings.transcriptionProvider = .groq
        settings.groqAPIKey = "  test-key  "

        store.save(settings)
        let reloaded = store.load()

        XCTAssertEqual(reloaded.toggleShortcut, "cmd+shift+space")
        XCTAssertEqual(reloaded.flowBarPosition, .bottomCenter)
        XCTAssertEqual(reloaded.retentionPolicy, .never)
        XCTAssertEqual(reloaded.transcriptionProvider, .groq)
        XCTAssertEqual(reloaded.groqAPIKey, "test-key")
        XCTAssertEqual(reloaded.transcriptionLanguage, "en")
    }
}
