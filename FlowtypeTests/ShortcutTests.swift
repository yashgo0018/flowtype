import AppKit
import XCTest
@testable import Flowtype

final class ShortcutTests: XCTestCase {
    func testParseDefaultToggleShortcut() throws {
        let parsed = try ShortcutParser.parse("ctrl+option+space")
        XCTAssertEqual(parsed.keyCode, 49)
        XCTAssertEqual(parsed.modifiers, [.control, .option])
    }

    func testBareKeysNeedModifierExceptFunctionKeys() throws {
        XCTAssertThrowsError(try ShortcutParser.parse("v"))
        XCTAssertThrowsError(try ShortcutParser.parse("fn"))
        XCTAssertNoThrow(try ShortcutParser.parse("f5"))
        let escape = try ShortcutParser.parse("esc", allowBareKey: true)
        XCTAssertEqual(escape.keyCode, 53)
        XCTAssertTrue(escape.modifiers.isEmpty)
    }

    func testMinusKeyIsNotASeparator() throws {
        XCTAssertEqual(try ShortcutParser.parse("cmd+-").keyCode, 27)
    }

    func testCanonicalShortcutNormalizesAliasesAndModifierOrder() {
        XCTAssertEqual(ShortcutParser.canonical("control+cmd+v"), "cmd+ctrl+v")
        XCTAssertEqual(ShortcutParser.canonical("esc"), "escape")
    }

    func testSymbolsUseMacOrder() {
        XCTAssertEqual(ShortcutParser.symbols("cmd+shift+ctrl+option+space"), ["⌃", "⌥", "⇧", "⌘", "Space"])
        XCTAssertEqual(ShortcutParser.display("cmd+ctrl+v"), "⌃⌘V")
    }

    func testConflictDetection() {
        let conflicts = ShortcutParser.conflicts([
            "Paste last": "cmd+ctrl+v",
            "Other": "control+command+v",
            "Cancel": "escape"
        ])
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertTrue(conflicts[0].contains("conflicts with"))
    }

    func testHoldKeyParsesLegacyValues() {
        XCTAssertEqual(HoldKey(storedValue: "fn"), .fn)
        XCTAssertEqual(HoldKey(storedValue: "Globe"), .fn)
        XCTAssertEqual(HoldKey(storedValue: "rightOption"), .rightOption)
        XCTAssertEqual(HoldKey(storedValue: "off"), .off)
    }
}
