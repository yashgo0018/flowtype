import SwiftUI

struct MeetingsView: View {
    @EnvironmentObject private var controller: AppStateController
    @ObservedObject var meetings: MeetingController
    @ObservedObject var calendar: MeetingCalendarScheduler
    @State private var search = ""
    @State private var deletion: MeetingSession?
    @State private var deletingAudio = false

    init(meetings: MeetingController, calendar: MeetingCalendarScheduler, search: String = "") {
        self.meetings = meetings
        self.calendar = calendar
        _search = State(initialValue: search)
    }

    private var filtered: [MeetingSession] { meetings.sessions.filter { $0.matches(search) } }
    private var sections: [(day: Date, sessions: [MeetingSession])] {
        let grouped = Dictionary(grouping: filtered) { Calendar.current.startOfDay(for: $0.startedAt) }
        return grouped.keys.sorted(by: >).map { ($0, (grouped[$0] ?? []).sorted { $0.startedAt > $1.startedAt }) }
    }

    var body: some View {
        PageScrollView {
            PageHeader(title: "Meetings", subtitle: "Your meeting transcripts, stored only on this Mac.") {
                MeetingRecordButton(meetings: meetings, calendar: calendar)
            }
            if meetings.isBusy {
                ActiveMeetingCard(meetings: meetings)
            } else if let event = calendar.controlEvent {
                CalendarMeetingCard(event: event, meetings: meetings, calendar: calendar)
            }
            if !meetings.isBusy && hasActionableNotice {
                Label(meetings.message, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
            SearchField(text: $search, prompt: "Search all meeting transcripts")
                .accessibilityLabel("Search all meeting transcripts")
            if filtered.isEmpty {
                Card {
                    EmptyStateView(systemImage: search.isEmpty ? "person.2.wave.2" : "magnifyingglass",
                        title: search.isEmpty ? "No meetings yet" : "No matches",
                        message: search.isEmpty ? "Start a meeting to transcribe your microphone and audio from all apps." : "Try another word or phrase from a transcript.")
                }
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(sections, id: \.day) { section in
                        Text(dayTitle(section.day)).font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary).padding(.top, 8)
                        ForEach(section.sessions) { session in
                            MeetingTranscriptRow(session: session, query: search, isBusy: meetings.isBusy,
                                export: { meetings.export(session) },
                                copy: { controller.copyToClipboard(session.transcriptText) },
                                delete: { deletingAudio = false; deletion = session },
                                deleteAudio: { deletingAudio = true; deletion = session })
                        }
                    }
                }
            }
            Text("Records your microphone and audio from all apps. Get participants’ permission before recording. Use headphones to reduce echo.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .alert(deletingAudio ? "Delete retained audio?" : "Delete meeting and any retained audio?",
               isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } })) {
            Button("Delete", role: .destructive) {
                if let deletion {
                    if deletingAudio { meetings.deleteAudio(deletion) } else { meetings.delete(deletion) }
                }
                deletion = nil
            }
            Button("Cancel", role: .cancel) { deletion = nil }
        } message: {
            Text(deletingAudio ? "The transcript will remain available." : "This permanently removes the transcript and any saved source audio from this Mac.")
        }
    }

    private var hasActionableNotice: Bool {
        ["Meeting did not start", "Could not", "Storage failed", "Meeting retention", "Finish dictation"].contains { meetings.message.hasPrefix($0) }
    }
    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }
}

/// One start/stop action across Home, Meetings and the floating bar.
struct MeetingRecordButton: View {
    @EnvironmentObject private var controller: AppStateController
    @ObservedObject var meetings: MeetingController
    @ObservedObject var calendar: MeetingCalendarScheduler
    var idleTitle = "Start meeting"

    var body: some View {
        Button {
            controller.toggleMeetingFromControl()
        } label: {
            Label(title, systemImage: meetings.isBusy ? "stop.fill" : "person.2.wave.2")
        }
        .disabled(meetings.phase == .finalizing || (!meetings.isBusy && !meetings.canStart()))
        .help(meetings.isBusy ? "Stop meeting capture and finish the transcript" : "Transcribe your microphone and audio from all apps locally")
        .accessibilityIdentifier("meeting-record-control")
    }
    private var title: String {
        switch meetings.phase {
        case .idle: idleTitle
        case .preparing: "Cancel start"
        case .recording: "Stop meeting"
        case .finalizing: "Finishing…"
        }
    }
}

struct ActiveMeetingCard: View {
    @ObservedObject var meetings: MeetingController
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    if meetings.phase == .recording {
                        Circle().fill(.red).frame(width: 8, height: 8).accessibilityHidden(true)
                        Text("Recording meeting").font(.headline)
                        Spacer()
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(MeetingSession.timestamp(meetings.elapsed)).monospacedDigit()
                        }
                    } else {
                        ProgressView().controlSize(.small)
                        Text(meetings.phase == .preparing ? "Preparing your meeting…" : "Finishing your transcript…").font(.headline)
                    }
                }
                Text(meetings.message).font(.callout).foregroundStyle(.secondary)
                if let session = meetings.current {
                    Text("\(session.wordCount.formatted()) words transcribed · Microphone + system audio")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if meetings.phase == .finalizing {
                    Button("Cancel remaining transcription") { meetings.cancelPendingTranscription() }
                        .font(.callout)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

struct CalendarMeetingCard: View {
    let event: MeetingEvent
    @ObservedObject var meetings: MeetingController
    @ObservedObject var calendar: MeetingCalendarScheduler
    var body: some View {
        Card {
            HStack(spacing: 12) {
                Image(systemName: "calendar").font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        Text(event.start <= context.date ? "A calendar meeting is in progress" : "A calendar meeting starts at \(event.start.formatted(date: .omitted, time: .shortened))")
                            .font(.headline)
                    }
                    Text("Start recording when you’re ready. Calendar time does not establish consent.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if calendar.suggestion != nil { Button("Skip") { calendar.skip() } }
            }
        }
    }
}

struct MeetingTranscriptRow: View {
    let session: MeetingSession
    let query: String
    let isBusy: Bool
    let export: () -> Void
    let copy: () -> Void
    let delete: () -> Void
    let deleteAudio: () -> Void
    @State private var expanded = false
    @State private var hovering = false
    @FocusState private var focusedAction: Action?
    private enum Action: Hashable { case copy, export, delete }

    init(session: MeetingSession, query: String, isBusy: Bool, export: @escaping () -> Void,
         copy: @escaping () -> Void, delete: @escaping () -> Void, deleteAudio: @escaping () -> Void,
         initiallyExpanded: Bool = false) {
        self.session = session; self.query = query; self.isBusy = isBusy
        self.export = export; self.copy = copy; self.delete = delete; self.deleteAudio = deleteAudio
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if expanded {
                                Text("Meeting at \(session.startedAt.formatted(date: .omitted, time: .shortened))").font(.headline)
                            } else {
                                Text(session.preview(matching: query).isEmpty ? "No speech transcript" : session.preview(matching: query))
                                    .lineLimit(3).multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                        MeetingTranscriptMetadata(session: session)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(expanded ? "Collapse" : "Open") meeting transcript, \(session.startedAt.formatted(date: .abbreviated, time: .shortened)), \(session.durationText), \(session.wordCount) words, \(session.status)")
                HStack(spacing: 6) {
                    Button(action: copy) { Image(systemName: "doc.on.doc") }
                        .focused($focusedAction, equals: .copy).help("Copy transcript").accessibilityLabel("Copy meeting transcript")
                    Button(action: export) { Image(systemName: "square.and.arrow.up") }
                        .focused($focusedAction, equals: .export).help("Export transcript…").accessibilityLabel("Export meeting transcript")
                    Button(role: .destructive, action: delete) { Image(systemName: "trash") }
                        .focused($focusedAction, equals: .delete).help("Delete meeting…").accessibilityLabel("Delete meeting")
                }
                .buttonStyle(.borderless)
                .disabled(isBusy)
                .opacity(hovering || focusedAction != nil ? 1 : 0)
            }
            if expanded {
                Divider()
                if session.segments.isEmpty {
                    Text("No speech was transcribed. Review the capture notices below.")
                        .foregroundStyle(.secondary).font(.callout)
                }
                ForEach(session.orderedSegments) { segment in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text(segment.source.title).font(.caption.weight(.semibold))
                                .foregroundStyle(segment.source == .microphone ? Color.accentColor : Color.secondary)
                            Text("\(MeetingSession.timestamp(segment.start))–\(MeetingSession.timestamp(segment.end))")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Text(segment.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 3)
                }
                if !session.issues.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Capture notices", systemImage: "exclamationmark.circle").font(.callout.weight(.medium))
                        ForEach(Array(session.issues.enumerated()), id: \.offset) { _, issue in
                            Text("\(MeetingSession.timestamp(issue.start)) · \(issue.message)")
                                .font(.callout).textSelection(.enabled)
                        }
                    }.foregroundStyle(.secondary).padding(.top, 4)
                }
                HStack {
                    Text("\(session.engine) · \(session.locale)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if !session.savesTranscript { Text("Not saved · export before quitting").font(.caption).foregroundStyle(.orange) }
                    if session.retainsAudio { Button("Delete retained audio…", role: .destructive, action: deleteAudio).font(.caption).disabled(isBusy) }
                }
                Text("Source labels show microphone or all-app system audio, not participant identities. Timestamps are estimates. A transcript is not a playable recording.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy transcript", action: copy)
            Button("Export transcript…", action: export).disabled(isBusy)
            Button("Delete meeting…", role: .destructive, action: delete).disabled(isBusy)
            if session.retainsAudio { Button("Delete retained audio…", role: .destructive, action: deleteAudio).disabled(isBusy) }
        }
    }
}

private struct MeetingTranscriptMetadata: View {
    let session: MeetingSession
    var body: some View {
        HStack(spacing: 6) {
            Text(session.startedAt.formatted(date: .omitted, time: .shortened))
            Text("·")
            Text(session.durationText)
            Text("·")
            Text("\(session.wordCount.formatted()) words")
            Text("·")
            Text(session.status).foregroundStyle(session.issues.isEmpty ? Color.secondary : Color.orange).lineLimit(1)
        }.font(.caption).foregroundStyle(.secondary)
    }
}

struct MeetingSettingsView: View {
    @ObservedObject var meetings: MeetingController
    @ObservedObject var calendar: MeetingCalendarScheduler
    private func binding<T>(_ path: WritableKeyPath<MeetingPreferences, T>) -> Binding<T> {
        Binding(get: { meetings.preferences[keyPath: path] }, set: { meetings.preferences[keyPath: path] = $0 })
    }
    var body: some View {
        Section("Meeting transcription — local only") {
            Picker("Meeting engine", selection: binding(\.engine)) {
                Text("Apple when available, otherwise Whisper").tag(MeetingEngine.automatic)
                Text("Whisper").tag(MeetingEngine.whisper)
            }
            TextField("Meeting language (for example en-US, de-DE)", text: binding(\.locale))
            Picker("Meeting Whisper model", selection: binding(\.whisperModel)) {
                ForEach(WhisperModelOption.all) { Text($0.title).tag($0.id) }
            }
            Text("Meeting settings are independent of dictation. No meeting audio is sent to Groq. Apple language support is checked before capture. English Whisper models require an English language; choose Large v3 Turbo for other languages. Fixed 20-second chunks may split words at boundaries.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Save meeting transcripts", isOn: binding(\.saveTranscript))
            Picker("Meeting transcript retention", selection: binding(\.transcriptRetentionHours)) {
                Text("Keep until deleted").tag(0); Text("24 hours after completion").tag(24)
            }
            Toggle("Keep meeting audio on this Mac", isOn: binding(\.retainAudio))
            Picker("Audio retention", selection: binding(\.audioRetentionDays)) {
                Text("1 day").tag(1); Text("7 days").tag(7); Text("30 days").tag(30)
            }
            Text("Audio stays in bounded memory by default; there are no temporary audio files. Enabling Keep audio saves separate 20-second source WAV chunks for processed intervals. Missing intervals are reported. Delete audio from a meeting’s detail view. Audio is not a synchronized playable meeting recording. Retention runs while Flowtype is open. Changing retention affects new sessions. With saving off, transcripts exist only until quit; export before closing.")
                .font(.caption).foregroundStyle(.secondary)
            Stepper("Maximum capture: \(meetings.preferences.maximumMinutes) minutes", value: binding(\.maximumMinutes), in: 1...480, step: 15)
        }.disabled(meetings.isBusy)

        Section("Apple Calendar — optional") {
            Picker("Calendar recording", selection: Binding(get: { meetings.preferences.calendarMode }, set: { calendar.setMode($0) })) {
                Text("Off").tag(MeetingCalendarMode.off)
                Text("Suggest recording").tag(MeetingCalendarMode.suggest)
                Text("Auto-start (explicit opt-in)").tag(MeetingCalendarMode.autoStart)
            }
            Text("Reading event details requires Calendar Full Access on macOS 14+. Flowtype only reads events and does not change them. Scheduled time cannot establish attendance or participant consent. Auto-start requires a successful manual source check in this app launch, visibly opens Meetings, and always stops at the maximum duration. Review participant consent before enabling it.")
                .font(.caption).foregroundStyle(.secondary)
            if meetings.preferences.calendarMode == .autoStart {
                Label(meetings.automaticReady ? "Sources checked for this launch" : "Manual source check needed with the current settings", systemImage: meetings.automaticReady ? "checkmark.circle" : "exclamationmark.circle")
                    .font(.caption)
            }
            if meetings.preferences.calendarMode != .off {
                ForEach(calendar.choices) { choice in
                    Toggle(choice.title, isOn: Binding(get: { meetings.preferences.calendarIDs.contains(choice.id) }, set: { enabled in
                        meetings.preferences.calendarIDs.removeAll { $0 == choice.id }
                        if enabled { meetings.preferences.calendarIDs.append(choice.id) }
                        calendar.tick()
                    }))
                }
                Toggle("Require a recognized conferencing link", isOn: binding(\.requireConferenceLink))
                Toggle("Require attendees", isOn: binding(\.requireAttendees))
                Stepper("Suggestion lead time: \(meetings.preferences.leadMinutes) minutes", value: binding(\.leadMinutes), in: 0...30)
                Toggle("Stop at calendar event end (also on cancellation or move)", isOn: binding(\.stopAtEventEnd))
                Text("All-day events are excluded. Filters combine when both are enabled. Conferencing links are recognized for Zoom, Meet, Teams, Webex, Whereby and FaceTime. Overlapping or missed events are skipped. Suggestions appear in Meetings; no notification permission is requested.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(calendar.message).font(.caption)
        }.disabled(meetings.isBusy)
    }
}
