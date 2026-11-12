import SwiftUI

struct MeetingsView: View {
    @EnvironmentObject private var controller: AppStateController
    @ObservedObject var meetings: MeetingController
    @ObservedObject var calendar: MeetingCalendarScheduler
    @State private var selection: UUID?
    @State private var deletion: MeetingSession?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(meetings.isBusy ? "Meeting capture active" : "Meetings", systemImage: meetings.isBusy ? "record.circle.fill" : "person.2.wave.2")
                    .font(.title2.bold()).foregroundStyle(meetings.isBusy ? .red : .primary)
                Spacer()
                Button(meetings.isBusy ? "Stop meeting" : "Start meeting") {
                    meetings.toggle(microphoneUID: controller.settings.microphoneUID)
                }.disabled(meetings.phase == .finalizing)
                if meetings.phase == .preparing || meetings.phase == .finalizing { ProgressView().controlSize(.small) }
                if meetings.phase == .finalizing {
                    Button("Cancel remaining transcription") { meetings.cancelPendingTranscription() }
                }
            }
            Text(meetings.message).font(.callout).textSelection(.enabled).accessibilityAddTraits(.updatesFrequently)
            Text("Captures your microphone and audio from all apps. Use headphones to reduce echo. Labels show sources, not participant identities. A transcript is not a playable recording. Get permission from participants before recording.")
                .font(.caption).foregroundStyle(.secondary)
            if let session = meetings.current, meetings.isBusy {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text("\(MeetingSession.timestamp(meetings.elapsed)) · \(session.segments.count) transcript segments saved so far")
                        .monospacedDigit().font(.caption)
                }
            }
            if calendar.suggestion != nil {
                HStack {
                    Text("Calendar meeting due")
                    Button("Start") { calendar.accept() }
                    Button("Skip") { calendar.skip() }
                }.padding().background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            }
            Divider()
            HSplitView {
                List(meetings.sessions, selection: $selection) { session in
                    VStack(alignment: .leading) {
                        Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                        Text(session.status).font(.caption).foregroundStyle(.secondary)
                    }.tag(session.id)
                }.frame(minWidth: 180, idealWidth: 220, maxWidth: 280)
                if let session = meetings.sessions.first(where: { $0.id == selection }) ?? meetings.current ?? meetings.sessions.first {
                    VStack(alignment: .leading) {
                        HStack {
                            Button("Export transcript…") { meetings.export(session) }
                            if session.retainsAudio { Button("Delete audio", role: .destructive) { meetings.deleteAudio(session) } }
                            Button("Delete…", role: .destructive) { deletion = session }
                        }.disabled(meetings.isBusy)
                        ScrollView {
                            Text(session.markdown).font(.body.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }
                    }.frame(minWidth: 320)
                } else { Text("Your local meeting transcripts appear here.").foregroundStyle(.secondary).frame(maxWidth: .infinity) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .alert("Delete meeting and any retained audio?", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } })) {
                Button("Delete", role: .destructive) { if let deletion { meetings.delete(deletion) }; deletion = nil }
                Button("Cancel", role: .cancel) { deletion = nil }
            }
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
