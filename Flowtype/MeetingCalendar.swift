import AppKit
import Combine
import CryptoKit
import EventKit
import Foundation

struct MeetingCalendarChoice: Identifiable { var id: String; var title: String }
struct MeetingEvent: Equatable, Identifiable {
    var id: String
    var calendarID: String
    var start: Date
    var end: Date
    var allDay = false
    var cancelled = false
    var hasConference = false
    var hasAttendees = false
    // Event titles/URLs/attendees are deliberately not retained by the scheduler.
}

enum MeetingOccurrenceID {
    static func make(itemIdentifier: String, originalOccurrence: Date?) -> String {
        let identity = itemIdentifier + "|" + (originalOccurrence.map { String($0.timeIntervalSince1970) } ?? "single")
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
protocol MeetingEventProviding: AnyObject {
    var authorized: Bool { get }
    func requestAccess() async throws -> Bool
    func calendars() -> [MeetingCalendarChoice]
    func events(from: Date, to: Date, calendarIDs: [String]) throws -> [MeetingEvent]
}

@MainActor
final class AppleMeetingEvents: MeetingEventProviding {
    private let store = EKEventStore()
    var authorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    func requestAccess() async throws -> Bool { try await store.requestFullAccessToEvents() }
    func calendars() -> [MeetingCalendarChoice] {
        guard authorized else { return [] }
        return store.calendars(for: .event).map { MeetingCalendarChoice(id: $0.calendarIdentifier, title: $0.title) }
    }
    func events(from: Date, to: Date, calendarIDs: [String]) throws -> [MeetingEvent] {
        guard authorized else { throw MeetingError.message("Calendar access is off. Enable it in System Settings or select Off.") }
        let selected = store.calendars(for: .event).filter { calendarIDs.contains($0.calendarIdentifier) }
        guard !selected.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: selected)
        return store.events(matching: predicate).compactMap { event in
            guard let identifier = event.calendarItemExternalIdentifier ?? event.eventIdentifier, !identifier.isEmpty else { return nil }
            let id = MeetingOccurrenceID.make(itemIdentifier: identifier,
                originalOccurrence: event.isDetached || event.hasRecurrenceRules ? (event.occurrenceDate ?? event.startDate) : nil)
            let strings = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }.joined(separator: " ").lowercased()
            let hosts = ["zoom.us/", "meet.google.com/", "teams.microsoft.com/", "teams.live.com/", "webex.com/", "whereby.com/", "facetime.apple.com/"]
            return MeetingEvent(id: id, calendarID: event.calendar.calendarIdentifier,
                start: event.startDate, end: event.endDate, allDay: event.isAllDay, cancelled: event.status == .canceled,
                hasConference: hosts.contains(where: strings.contains), hasAttendees: event.hasAttendees)
        }
    }
}

@MainActor
final class MeetingCalendarScheduler: ObservableObject {
    @Published private(set) var choices: [MeetingCalendarChoice] = []
    @Published private(set) var suggestion: MeetingEvent?
    @Published private(set) var message = "Calendar integration is off."
    private let events: MeetingEventProviding
    private let now: () -> Date
    private let defaults: UserDefaults
    private var handled: [String: Date]
    private var configuring = false
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var lastTick: Date?
    private let meetings: MeetingController
    private let microphoneUID: () -> String

    init(meetings: MeetingController, events: MeetingEventProviding = AppleMeetingEvents(),
         defaults: UserDefaults = .standard, now: @escaping () -> Date = { .now },
         microphoneUID: @escaping () -> String = { "" }) {
        self.meetings = meetings; self.events = events; self.defaults = defaults; self.now = now; self.microphoneUID = microphoneUID
        handled = defaults.dictionary(forKey: "meeting.calendar.handled.v1") as? [String: Date] ?? [:]
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        observers.append(NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.meetings.stop(reason: "Mac went to sleep. Restart capture manually after waking."); self?.suggestion = nil }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } })
        tick()
    }

    func setMode(_ mode: MeetingCalendarMode) {
        guard !configuring else { return }
        if mode == .off {
            meetings.preferences.calendarMode = .off; suggestion = nil; choices = []; message = "Calendar integration is off."; return
        }
        configuring = true
        Task {
            defer { configuring = false }
            do {
                let granted = events.authorized ? true : try await events.requestAccess()
                guard granted else {
                    meetings.preferences.calendarMode = .off; message = "Calendar permission was denied. Manual recording remains available."; return
                }
                meetings.preferences.calendarMode = mode
                choices = events.calendars(); tick()
            } catch { meetings.preferences.calendarMode = .off; message = "Calendar access failed. \(error.localizedDescription)" }
        }
    }

    static func eligible(_ event: MeetingEvent, preferences: MeetingPreferences) -> Bool {
        !event.allDay && !event.cancelled && event.end > event.start && preferences.calendarIDs.contains(event.calendarID)
            && (!preferences.requireConferenceLink || event.hasConference)
            && (!preferences.requireAttendees || event.hasAttendees)
    }

    private func claim(_ event: MeetingEvent) {
        handled[event.id] = now()
        let cutoff = now().addingTimeInterval(-90 * 86400)
        handled = handled.filter { $0.value >= cutoff }
        defaults.set(handled, forKey: "meeting.calendar.handled.v1")
    }

    func tick() {
        let preferences = meetings.preferences
        guard preferences.calendarMode != .off else { suggestion = nil; return }
        guard events.authorized else {
            suggestion = nil; choices = []
            if meetings.scheduledID != nil { meetings.stop(reason: "Calendar permission was revoked; scheduled capture stopped.") }
            message = "Calendar permission is unavailable. Scheduled capture is paused."
            return
        }
        let time = now()
        let resumed = lastTick.map { time.timeIntervalSince($0) > 60 } ?? true
        lastTick = time
        choices = events.calendars()
        do {
            let snapshot = try events.events(from: time.addingTimeInterval(-12 * 3600), to: time.addingTimeInterval(24 * 3600), calendarIDs: preferences.calendarIDs)
            if let activeID = meetings.scheduledID, preferences.stopAtEventEnd {
                if let active = snapshot.first(where: { $0.id == activeID && Self.eligible($0, preferences: preferences) }), active.start <= time, active.end > time {
                    meetings.scheduledEnd = active.end
                } else { meetings.stop(reason: "Scheduled event ended, moved, was cancelled, or is no longer eligible.") }
            }
            if let existing = suggestion {
                suggestion = snapshot.first { $0.id == existing.id && Self.eligible($0, preferences: preferences) && $0.end > time && $0.start <= time.addingTimeInterval(Double(preferences.leadMinutes) * 60) }
            }
            let lead = preferences.calendarMode == .suggest ? Double(max(0, min(30, preferences.leadMinutes))) * 60 : 0
            for event in snapshot.sorted(by: { $0.start < $1.start }) where Self.eligible(event, preferences: preferences) && handled[event.id] == nil {
                guard event.start <= time.addingTimeInterval(lead), event.end > time else { continue }
                // Do not record retrospectively after launch/wake or during a busy overlapping meeting.
                guard time.timeIntervalSince(event.start) < (resumed ? 15 : 60) else { claim(event); continue }
                if meetings.isBusy || suggestion != nil { claim(event); message = "An overlapping event was skipped."; continue }
                claim(event)
                if preferences.calendarMode == .suggest {
                    suggestion = event
                    message = "A calendar meeting is due. Choose Start or Skip. Scheduled time does not establish attendance or consent."
                    meetings.onAnnounce?()
                } else {
                    meetings.start(microphoneUID: microphoneUID(), automatic: true)
                    if meetings.isBusy { meetings.scheduledID = event.id; meetings.scheduledEnd = preferences.stopAtEventEnd ? event.end : nil }
                    message = meetings.isBusy ? "Scheduled capture announced. Stop or skip from Meetings." : meetings.message
                }
            }
            if preferences.calendarIDs.isEmpty { message = "Select calendars. No events are eligible yet." }
        } catch { suggestion = nil; message = error.localizedDescription }
    }

    func accept() {
        // Refresh before starting so a cancelled/moved event cannot start from a stale suggestion.
        tick()
        guard let event = suggestion else { return }
        suggestion = nil
        meetings.start(microphoneUID: microphoneUID())
        if meetings.isBusy { meetings.scheduledID = event.id; meetings.scheduledEnd = meetings.preferences.stopAtEventEnd ? event.end : nil }
    }
    func skip() { suggestion = nil; message = "Calendar suggestion skipped." }
}
