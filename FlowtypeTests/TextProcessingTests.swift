import XCTest
@testable import Flowtype

final class TextProcessingTests: XCTestCase {
    func testCleanRemovesWhisperArtifacts() {
        XCTAssertEqual(
            TranscriptPostProcessor.clean("<|startoftranscript|><|en|><|transcribe|><|notimestamps|> Hello world.<|endoftext|>"),
            "Hello world."
        )
        XCTAssertEqual(TranscriptPostProcessor.clean("[BLANK_AUDIO]"), "")
        XCTAssertEqual(TranscriptPostProcessor.clean(" (silence) "), "")
        XCTAssertEqual(TranscriptPostProcessor.clean("Hi  there ,  friend ."), "Hi there, friend.")
    }

    func testDictionaryFixesCasingAndReplacements() {
        let rules = TextReplacementRules(
            vocabulary: [("kubernetes", ""), ("Kubernetes", ""), ("jason", "JSON"), ("visual studio code", "VS Code")],
            snippets: []
        )
        let result = TranscriptPostProcessor.process("Deploy to kubernetes and parse the jason in Visual Studio Code.", rules: rules)
        XCTAssertEqual(result.text, "Deploy to Kubernetes and parse the JSON in VS Code.")
        XCTAssertTrue(result.matchedPhrases.contains("jason"))
        XCTAssertTrue(result.matchedPhrases.contains("visual studio code"))
    }

    func testDictionaryMatchesWholeWordsOnly() {
        let rules = TextReplacementRules(vocabulary: [("art", "ART")], snippets: [])
        XCTAssertEqual(TranscriptPostProcessor.process("Start the art show.", rules: rules).text, "Start the ART show.")
    }

    func testSnippetExpansion() {
        let rules = TextReplacementRules(vocabulary: [], snippets: [("my email", "me@example.com")])
        XCTAssertEqual(TranscriptPostProcessor.process("My email.", rules: rules).text, "me@example.com")
        XCTAssertEqual(
            TranscriptPostProcessor.process("Send it to my email please.", rules: rules).text,
            "Send it to me@example.com please."
        )
    }

    func testReplacementTemplatesAreLiteral() {
        let rules = TextReplacementRules(vocabulary: [], snippets: [("price", "$10 \\o/")])
        XCTAssertEqual(TranscriptPostProcessor.process("The price is fine", rules: rules).text, "The $10 \\o/ is fine")
    }

    func testSmartSpacing() {
        XCTAssertEqual(TranscriptPostProcessor.applySmartSpacing("Hello", precedingCharacter: "d"), " Hello")
        XCTAssertEqual(TranscriptPostProcessor.applySmartSpacing("Hello", precedingCharacter: " "), "Hello")
        XCTAssertEqual(TranscriptPostProcessor.applySmartSpacing("Hello", precedingCharacter: nil), "Hello")
        XCTAssertEqual(TranscriptPostProcessor.applySmartSpacing(", then", precedingCharacter: "d"), ", then")
        XCTAssertEqual(TranscriptPostProcessor.applySmartSpacing("Hello", precedingCharacter: "("), "Hello")
    }

    func testWAVEncodingHeader() {
        let audio = RecordedAudio(samples: [0, 0.5, -0.5, 1], peakLevel: 1)
        let data = audio.wavData()
        XCTAssertEqual(data.count, 44 + 8)
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data.subdata(in: 8..<12), encoding: .ascii), "WAVE")
        XCTAssertEqual(audio.duration, 4.0 / 16_000, accuracy: 1e-9)
    }

    func testStreakCountsConsecutiveDaysEndingTodayOrYesterday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let today = calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 12))!
        let key = { (offset: Int) in
            TextMetrics.dayKey(for: calendar.date(byAdding: .day, value: -offset, to: today)!, calendar: calendar)
        }
        XCTAssertEqual(TextMetrics.streak(dayKeys: [key(0), key(1), key(2), key(4)], today: today, calendar: calendar), 3)
        XCTAssertEqual(TextMetrics.streak(dayKeys: [key(1), key(2)], today: today, calendar: calendar), 2)
        XCTAssertEqual(TextMetrics.streak(dayKeys: [key(2)], today: today, calendar: calendar), 0)
    }
}
