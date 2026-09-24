import Foundation

enum TranscriptPostProcessor {
    struct Result: Equatable {
        let text: String
        /// Lowercased dictionary phrases that matched, for usage counts.
        let matchedPhrases: Set<String>
    }

    /// Removes Whisper artifacts: special tokens, non-speech annotations and extra whitespace.
    static func clean(_ raw: String) -> String {
        var text = raw
        // Special tokens such as <|startoftranscript|> or <|endoftext|>.
        text = text.replacingOccurrences(of: "<\\|[^|>]*\\|>", with: " ", options: .regularExpression)
        // Non-speech annotations such as [BLANK_AUDIO], [Music], (silence) or *coughs*.
        text = text.replacingOccurrences(of: "\\[[^\\]]*\\]", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(
            of: "\\((?i:silence|music|applause|laughter|laughs|coughs?|inaudible|blank audio|background noise|noise|static|sighs?|breathing)\\)",
            with: " ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(of: "\\*[^*]{1,40}\\*", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "[♪♫]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: " ([,.!?;:])", with: "$1", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func process(_ raw: String, rules: TextReplacementRules) -> Result {
        var text = clean(raw)
        guard !text.isEmpty else { return Result(text: "", matchedPhrases: []) }

        // A transcript that is only a snippet trigger ("my address.") becomes the expansion verbatim.
        let bare = text.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces)).lowercased()
        if let snippet = rules.snippets.first(where: { $0.trigger.lowercased() == bare }) {
            return Result(text: snippet.expansion, matchedPhrases: [])
        }

        var matched = Set<String>()
        // Longer phrases first so "Visual Studio Code" wins over "Code".
        for entry in rules.vocabulary.sorted(by: { $0.phrase.count > $1.phrase.count }) {
            let target = entry.replacement.isEmpty ? entry.phrase : entry.replacement
            let (replaced, count) = replacingPhrase(entry.phrase, with: target, in: text)
            if count > 0 {
                matched.insert(entry.phrase.lowercased())
            }
            text = replaced
        }

        for snippet in rules.snippets.sorted(by: { $0.trigger.count > $1.trigger.count }) {
            text = replacingPhrase(snippet.trigger, with: snippet.expansion, in: text).text
        }

        return Result(text: text, matchedPhrases: matched)
    }

    /// Case-insensitive whole-word replacement. Whitespace inside the phrase matches any whitespace.
    static func replacingPhrase(_ phrase: String, with replacement: String, in text: String) -> (text: String, count: Int) {
        let words = phrase.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !words.isEmpty else { return (text, 0) }
        let body = words.joined(separator: "[\\s-]+")
        // Lookarounds instead of \b so phrases that start or end with punctuation ("C++") still match.
        let pattern = "(?<![\\w])\(body)(?![\\w])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return (text, 0) }
        let range = NSRange(text.startIndex..., in: text)
        let count = regex.numberOfMatches(in: text, range: range)
        guard count > 0 else { return (text, 0) }
        let replaced = regex.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
        )
        return (replaced, count)
    }

    /// Adds a separating space when inserting after a word so consecutive dictations don't run together.
    static func applySmartSpacing(_ text: String, precedingCharacter: Character?) -> String {
        guard let previous = precedingCharacter, let first = text.first else { return text }
        if previous.isWhitespace || previous.isNewline { return text }
        if "([{\"'“‘/-@#".contains(previous) { return text }
        if ".,!?;:)]}".contains(first) { return text }
        return " " + text
    }
}
