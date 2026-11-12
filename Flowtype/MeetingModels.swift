import Foundation

enum MeetingSource: String, Codable, CaseIterable, Sendable {
    case microphone, system
    var title: String { self == .microphone ? "You" : "System audio" }
}

struct MeetingSegment: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var source: MeetingSource
    var start: Double
    var end: Double
    var text: String
}

struct MeetingIssue: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
    var message: String
}

struct MeetingSession: Codable, Identifiable, Equatable, Sendable {
    var version = 1
    var id = UUID()
    var startedAt: Date
    var endedAt: Date?
    var duration: Double = 0
    var status = "Recording"
    var engine: String
    var locale: String
    var savesTranscript = true
    var retainsAudio = false
    var transcriptRetentionHours = 0
    var audioRetentionDays = 7
    var segments: [MeetingSegment] = []
    var issues: [MeetingIssue] = []

    var orderedSegments: [MeetingSegment] {
        segments.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.source != $1.source { return $0.source.rawValue < $1.source.rawValue }
            return $0.end < $1.end
        }
    }

    var markdown: String {
        var lines = ["# Meeting transcript", "", "Started: \(startedAt.ISO8601Format())", "Status: \(status)",
                     "Engine: \(engine) · Language: \(locale)",
                     "", "Source labels indicate capture origin, not speaker identity. Timestamps are estimates on the session timeline. Overlapping sources may overlap in time.", ""]
        for segment in orderedSegments {
            lines.append("[\(Self.timestamp(segment.start))–\(Self.timestamp(segment.end))] **\(segment.source.title):** \(segment.text)")
            lines.append("")
        }
        if !issues.isEmpty {
            lines += ["## Capture and transcription notices", ""]
            lines += issues.map { "- [\(Self.timestamp($0.start))–\(Self.timestamp($0.end))] \($0.message)" }
        }
        return lines.joined(separator: "\n")
    }

    static func timestamp(_ seconds: Double) -> String {
        let value = Int(max(0, seconds.isFinite ? seconds : 0))
        return String(format: "%02d:%02d:%02d", value / 3600, (value / 60) % 60, value % 60)
    }
}

enum MeetingEngine: String, Codable, CaseIterable { case automatic, whisper }
enum MeetingCalendarMode: String, Codable, CaseIterable { case off, suggest, autoStart }

struct MeetingPreferences: Codable, Equatable {
    var engine: MeetingEngine = .automatic
    var locale = "en-US"
    var whisperModel = AppSettings.defaultTranscriptionModel
    var saveTranscript = true
    var transcriptRetentionHours = 0
    var retainAudio = false
    var audioRetentionDays = 7
    var maximumMinutes = 120
    var calendarMode: MeetingCalendarMode = .off
    var calendarIDs: [String] = []
    var requireConferenceLink = true
    var requireAttendees = false
    var leadMinutes = 0
    var stopAtEventEnd = true

    static func load(_ defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: "meeting.preferences.v1"),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: "meeting.preferences.v1")
    }
}

@MainActor
protocol MeetingStoring: AnyObject {
    func load() throws -> [MeetingSession]
    func save(_ session: MeetingSession) throws
    func saveAudio(_ chunk: MeetingChunk, session: MeetingSession) throws
    func delete(_ id: UUID) throws
    func deleteAudio(_ id: UUID) throws
    func applyRetention(now: Date, excluding: UUID?) throws
}

/// Independent versioned files deliberately leave the existing SwiftData schema/store untouched.
@MainActor
final class MeetingFileStore: MeetingStoring {
    let root: URL
    init(root: URL? = nil) throws {
        self.root = try root ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true)
            .appendingPathComponent("Flowtype/Meetings", isDirectory: true)
        try Self.privateDirectory(self.root)
    }

    private static func privateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutable.setResourceValues(values)
    }

    private func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }

    func load() throws -> [MeetingSession] {
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        return try folders.filter { UUID(uuidString: $0.lastPathComponent) != nil }.map { folder in
            // Fail visibly; never move or replace an unreadable transcript.
            let session = try JSONDecoder().decode(MeetingSession.self, from: Data(contentsOf: folder.appendingPathComponent("session.json")))
            guard session.version == 1 else { throw MeetingError.message("A meeting uses a newer file format. Its files have been preserved.") }
            return session
        }.sorted { $0.startedAt > $1.startedAt }
    }

    func save(_ session: MeetingSession) throws {
        guard session.savesTranscript || session.retainsAudio else { return }
        let directory = folder(session.id)
        try Self.privateDirectory(directory)
        var persisted = session
        if !session.savesTranscript { persisted.segments = [] }
        let data = try JSONEncoder().encode(persisted)
        let url = directory.appendingPathComponent("session.json")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func saveAudio(_ chunk: MeetingChunk, session: MeetingSession) throws {
        guard session.retainsAudio else { return }
        let directory = folder(session.id).appendingPathComponent("Audio", isDirectory: true)
        try Self.privateDirectory(directory)
        let url = directory.appendingPathComponent("\(chunk.source.rawValue)-\(Int(chunk.start * 1000))-\(UUID().uuidString).wav")
        try RecordedAudio(samples: chunk.samples, peakLevel: chunk.peak).wavData().write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func delete(_ id: UUID) throws {
        let url = folder(id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    func deleteAudio(_ id: UUID) throws {
        let url = folder(id).appendingPathComponent("Audio")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    func applyRetention(now: Date, excluding: UUID?) throws {
        for var session in try load() where session.id != excluding {
            let age = now.timeIntervalSince(session.endedAt ?? session.startedAt)
            let textExpired = session.transcriptRetentionHours > 0 && age > Double(session.transcriptRetentionHours) * 3600
            if textExpired { session.segments = []; session.savesTranscript = false }
            if session.retainsAudio && session.audioRetentionDays > 0 && age > Double(session.audioRetentionDays) * 86400 {
                try deleteAudio(session.id)
                session.retainsAudio = false
            }
            if !session.savesTranscript && !session.retainsAudio { try delete(session.id) }
            else { try save(session) }
        }
    }
}

enum MeetingError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}
