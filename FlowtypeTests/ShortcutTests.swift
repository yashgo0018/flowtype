import AppKit
import XCTest
@testable import Flowtype

final class ShortcutTests: XCTestCase {
    func testParseDefaultToggleShortcut() throws {
        let parsed = try ShortcutParser.parse("ctrl+option+space")
        XCTAssertEqual(parsed.keyCode, 49)
        XCTAssertTrue(parsed.modifiers.contains(.control))
        XCTAssertTrue(parsed.modifiers.contains(.option))
        XCTAssertFalse(parsed.modifiers.contains(.command))
    }

    func testCancelShortcutAllowsBareEscape() throws {
        let parsed = try ShortcutParser.parse("esc", allowBareEscape: true)
        XCTAssertEqual(parsed.keyCode, 53)
        XCTAssertTrue(parsed.modifiers.isEmpty)
        XCTAssertEqual(ShortcutParser.display("esc"), "Esc")
    }

    func testCanonicalShortcutNormalizesAliasesAndModifierOrder() {
        XCTAssertEqual(ShortcutParser.canonical("control+cmd+v"), "cmd+ctrl+v")
        XCTAssertEqual(ShortcutParser.canonical("esc"), "escape")
    }

    func testConflictDetection() {
        let conflicts = ShortcutParser.conflicts([
            "Paste last": "cmd+ctrl+v",
            "Other": "control+command+v",
            "Cancel": "escape"
        ])
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertTrue(conflicts[0].contains("conflicts with"))
        XCTAssertTrue(conflicts[0].contains("v"))
    }
}
