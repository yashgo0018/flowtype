import Foundation
import SwiftData

@Model
final class TranscriptHistoryItem {
    var transcript: String
    var wordCount: Int
    var pasted: Bool
    var statusMessage: String
    var createdAt: Date
    var durationSeconds: Double = 0

    init(transcript: String, pasted: Bool, statusMessage: String, durationSeconds: Double = 0, createdAt: Date = .now) {
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        self.transcript = cleaned
        self.wordCount = TextMetrics.wordCount(cleaned)
        self.pasted = pasted
        self.statusMessage = statusMessage
        self.durationSeconds = durationSeconds
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
        self.phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        self.replacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
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

    init(trigger: String, expansion: String, scope: String = "personal", createdAt: Date = .now, updatedAt: Date = .now) {
        self.trigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
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
        self.title = title
        self.body = body
        self.pinned = pinned
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let firstLine = body.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return firstLine.isEmpty ? "New note" : String(firstLine.prefix(60))
    }
}

@Model
final class DailyUsage {
    @Attribute(.unique) var day: String
    var words: Int
    var sessions: Int
    var pasted: Int
    var copied: Int
    var dictationSeconds: Double = 0

    init(day: String, words: Int = 0, sessions: Int = 0, pasted: Int = 0, copied: Int = 0) {
        self.day = day
        self.words = words
        self.sessions = sessions
        self.pasted = pasted
        self.copied = copied
    }
}

/// Retained so stores created by earlier builds keep opening without a migration.
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

    /// Opens the on-disk store. If it cannot be opened (for example a corrupt file), the old
    /// store is moved aside and a fresh one is created instead of crashing at launch.
    static func makeContainer() -> ModelContainer {
        let schema = Schema(models)
        let configuration = ModelConfiguration("Flowtype", schema: schema)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            NSLog("Flowtype could not open its data store: \(error). Moving it aside.")
            moveStoreAside(configuration.url)
        }
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            NSLog("Flowtype falling back to an in-memory store: \(error)")
            let memory = ModelConfiguration("Flowtype-memory", schema: schema, isStoredInMemoryOnly: true)
            // An in-memory store with a valid schema cannot fail to open.
            return try! ModelContainer(for: schema, configurations: [memory])
        }
    }

    private static func moveStoreAside(_ url: URL) {
        let stamp = Int(Date().timeIntervalSince1970)
        let manager = FileManager.default
        for suffix in ["", "-shm", "-wal"] {
            let source = URL(fileURLWithPath: url.path + suffix)
            guard manager.fileExists(atPath: source.path) else { continue }
            let destination = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-broken-\(stamp).\(url.pathExtension)\(suffix)")
            try? manager.moveItem(at: source, to: destination)
        }
    }
}

enum TextMetrics {
    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// Local calendar day key, e.g. "2026-09-24".
    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    static func date(fromDayKey key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Consecutive days with dictation ending today (or yesterday, so a streak survives until you dictate today).
    static func streak(dayKeys: Set<String>, today: Date = .now, calendar: Calendar = .current) -> Int {
        var day = calendar.startOfDay(for: today)
        if !dayKeys.contains(dayKey(for: day, calendar: calendar)) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
        }
        var streak = 0
        while dayKeys.contains(dayKey(for: day, calendar: calendar)) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return streak
    }
}

struct TextReplacementRules: Sendable {
    var vocabulary: [(phrase: String, replacement: String)] = []
    var snippets: [(trigger: String, expansion: String)] = []

    /// Words Whisper should be biased towards spelling correctly.
    var promptTerms: [String] {
        vocabulary.map { $0.replacement.isEmpty ? $0.phrase : $0.replacement }
    }
}

@MainActor
final class LocalStore {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func saveTranscript(_ transcript: String, pasted: Bool, statusMessage: String, durationSeconds: Double, retentionPolicy: RetentionPolicy) throws {
        try recordUsage(wordCount: TextMetrics.wordCount(transcript), pasted: pasted, durationSeconds: durationSeconds)
        switch retentionPolicy {
        case .normal, .twentyFourHours:
            context.insert(TranscriptHistoryItem(
                transcript: transcript,
                pasted: pasted,
                statusMessage: statusMessage,
                durationSeconds: durationSeconds
            ))
        case .never:
            break
        }
        try applyRetention(retentionPolicy)
        try context.save()
    }

    func recordUsage(wordCount: Int, pasted: Bool, durationSeconds: Double, date: Date = .now) throws {
        let day = TextMetrics.dayKey(for: date)
        let descriptor = FetchDescriptor<DailyUsage>(predicate: #Predicate { $0.day == day })
        let usage: DailyUsage
        if let existing = try context.fetch(descriptor).first {
            usage = existing
        } else {
            usage = DailyUsage(day: day)
            context.insert(usage)
        }
        usage.words += wordCount
        usage.sessions += 1
        usage.pasted += pasted ? 1 : 0
        usage.copied += pasted ? 0 : 1
        usage.dictationSeconds += durationSeconds
    }

    /// Deletes history that the retention policy no longer allows. Safe to call at any time.
    func applyRetention(_ policy: RetentionPolicy, now: Date = .now) throws {
        switch policy {
        case .normal, .never:
            // "Never" stops saving new transcripts; existing history is only removed on request.
            return
        case .twentyFourHours:
            try deleteHistory(olderThan: now.addingTimeInterval(-24 * 60 * 60))
        }
        if context.hasChanges {
            try context.save()
        }
    }

    func deleteAllHistory() throws {
        try context.delete(model: TranscriptHistoryItem.self)
        try context.save()
    }

    func latestTranscript() -> String? {
        var descriptor = FetchDescriptor<TranscriptHistoryItem>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.transcript
    }

    func replacementRules() -> TextReplacementRules {
        let entries = (try? context.fetch(FetchDescriptor<DictionaryEntry>())) ?? []
        let snippets = (try? context.fetch(FetchDescriptor<Snippet>())) ?? []
        return TextReplacementRules(
            vocabulary: entries.filter { !$0.phrase.isEmpty }.map { ($0.phrase, $0.replacement) },
            snippets: snippets.filter { !$0.trigger.isEmpty && !$0.expansion.isEmpty }.map { ($0.trigger, $0.expansion) }
        )
    }

    func recordDictionaryUsage(phrases: Set<String>) {
        guard !phrases.isEmpty else { return }
        let entries = (try? context.fetch(FetchDescriptor<DictionaryEntry>())) ?? []
        for entry in entries where phrases.contains(entry.phrase.lowercased()) {
            entry.usageCount += 1
        }
        try? context.save()
    }

    private func deleteHistory(olderThan cutoff: Date) throws {
        try context.delete(model: TranscriptHistoryItem.self, where: #Predicate { $0.createdAt < cutoff })
    }
}
