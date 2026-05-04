import Foundation
import SwiftData

@Model
final class TranscriptHistoryItem {
    var transcript: String
    var wordCount: Int
    var pasted: Bool
    var statusMessage: String
    var createdAt: Date

    init(transcript: String, pasted: Bool, statusMessage: String, createdAt: Date = .now) {
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        self.transcript = cleaned
        self.wordCount = cleaned.split(whereSeparator: \.isWhitespace).count
        self.pasted = pasted
        self.statusMessage = statusMessage
        self.createdAt = createdAt
    }
}

@Model
final class DictionaryEntry {
    var phrase: String
    var replacement: String
    var pinned: Bool
    var usageCount: Int
    var createdAt: Date
    var updatedAt: Date

    init(phrase: String, replacement: String = "", pinned: Bool = false, usageCount: Int = 0, createdAt: Date = .now, updatedAt: Date = .now) {
        self.phrase = phrase
        self.replacement = replacement
        self.pinned = pinned
        self.usageCount = usageCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class Snippet {
    var trigger: String
    var expansion: String
    var scope: String
    var createdAt: Date
    var updatedAt: Date

    init(trigger: String, expansion: String, scope: String = WritingStyleScope.personal.rawValue, createdAt: Date = .now, updatedAt: Date = .now) {
        self.trigger = trigger
        self.expansion = expansion
        self.scope = scope
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class ScratchpadNote {
    var title: String
    var body: String
    var pinned: Bool
    var version: Int
    var createdAt: Date
    var updatedAt: Date

    init(title: String, body: String, pinned: Bool = false, version: Int = 1, createdAt: Date = .now, updatedAt: Date = .now) {
        self.title = title.isEmpty ? "Untitled" : title
        self.body = body
        self.pinned = pinned
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class DailyUsage {
    @Attribute(.unique) var day: String
    var words: Int
    var sessions: Int
    var pasted: Int
    var copied: Int

    init(day: String, words: Int = 0, sessions: Int = 0, pasted: Int = 0, copied: Int = 0) {
        self.day = day
        self.words = words
        self.sessions = sessions
        self.pasted = pasted
        self.copied = copied
    }
}

@Model
final class AppCategory {
    @Attribute(.unique) var pattern: String
    var category: String
    var createdAt: Date

    init(pattern: String, category: String, createdAt: Date = .now) {
        self.pattern = pattern
        self.category = category
        self.createdAt = createdAt
    }
}

enum NativeSchema {
    static let models: [any PersistentModel.Type] = [
        TranscriptHistoryItem.self,
        DictionaryEntry.self,
        Snippet.self,
        ScratchpadNote.self,
        DailyUsage.self,
        AppCategory.self
    ]
}

@MainActor
final class LocalStore {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func saveTranscript(_ transcript: String, pasted: Bool, statusMessage: String, retentionPolicy: RetentionPolicy) throws {
        try recordUsage(wordCount: transcript.split(whereSeparator: \.isWhitespace).count, pasted: pasted)
        switch retentionPolicy {
        case .normal:
            context.insert(TranscriptHistoryItem(transcript: transcript, pasted: pasted, statusMessage: statusMessage))
        case .twentyFourHours:
            try deleteHistory(olderThan: Date().addingTimeInterval(-24 * 60 * 60))
            context.insert(TranscriptHistoryItem(transcript: transcript, pasted: pasted, statusMessage: statusMessage))
        case .never:
            break
        }
        try context.save()
    }

    func recordUsage(wordCount: Int, pasted: Bool, date: Date = .now) throws {
        let day = Self.dayFormatter.string(from: date)
        let descriptor = FetchDescriptor<DailyUsage>(predicate: #Predicate { $0.day == day })
        let usage = try context.fetch(descriptor).first ?? DailyUsage(day: day)
        if usage.modelContext == nil {
            context.insert(usage)
        }
        usage.words += wordCount
        usage.sessions += 1
        usage.pasted += pasted ? 1 : 0
        usage.copied += pasted ? 0 : 1
    }

    func addDictionaryEntry(phrase: String, replacement: String, pinned: Bool) throws {
        context.insert(DictionaryEntry(phrase: phrase, replacement: replacement, pinned: pinned))
        try context.save()
    }

    func addSnippet(trigger: String, expansion: String, scope: String) throws {
        context.insert(Snippet(trigger: trigger, expansion: expansion, scope: scope))
        try context.save()
    }

    func saveNote(title: String, body: String) throws {
        context.insert(ScratchpadNote(title: title, body: body))
        try context.save()
    }

    func deleteHistory(olderThan cutoff: Date) throws {
        let descriptor = FetchDescriptor<TranscriptHistoryItem>(predicate: #Predicate { $0.createdAt < cutoff })
        let entries = try context.fetch(descriptor)
        for entry in entries {
            context.delete(entry)
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
