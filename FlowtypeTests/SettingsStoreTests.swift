import XCTest
@testable import Flowtype

final class SettingsStoreTests: XCTestCase {
    func testDefaultsAreRegistered() {
        let suiteName = "SettingsStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)

        let settings = store.load()

        XCTAssertEqual(settings.toggleShortcut, "ctrl+option+space")
        XCTAssertEqual(settings.holdShortcut, "fn")
        XCTAssertEqual(settings.cancelShortcut, "escape")
        XCTAssertEqual(settings.transcriptionModel, "openai_whisper-small.en")
        XCTAssertEqual(settings.transcriptionLanguage, "en")
        XCTAssertTrue(settings.restoreClipboardAfterPaste)
    }

    func testSaveAndReloadSettings() {
        let suiteName = "SettingsStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)
        var settings = store.load()
        settings.toggleShortcut = "cmd+shift+space"
        settings.flowBarPosition = .bottomCenter
        settings.retentionPolicy = .never

        store.save(settings)
        let reloaded = store.load()

        XCTAssertEqual(reloaded.toggleShortcut, "cmd+shift+space")
        XCTAssertEqual(reloaded.flowBarPosition, .bottomCenter)
        XCTAssertEqual(reloaded.retentionPolicy, .never)
        XCTAssertEqual(reloaded.transcriptionLanguage, "en")
    }
}
