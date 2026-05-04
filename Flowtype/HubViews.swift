import SwiftData
import SwiftUI

enum HubPage: String, CaseIterable, Identifiable {
    case home = "Home"
    case activity = "Recent Activity"
    case insights = "Insights"
    case dictionary = "Dictionary"
    case snippets = "Snippets"
    case styles = "Styles"
    case scratchpad = "Scratchpad"
    case settings = "Settings"

    var id: String { rawValue }
}

struct HubRootView: View {
    @EnvironmentObject private var controller: AppStateController
    @State private var selection: HubPage? = .home

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Flowtype")
                        .font(.title3.bold())
                    Text("Local Whisper - Signed out")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.top, 16)

                List(HubPage.allCases, selection: $selection) { page in
                    Text(page.rawValue)
                        .tag(page)
                }
                .scrollContentBackground(.hidden)

                Text("Local dictation")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
            .frame(minWidth: 210)
            .background(Color(nsColor: .windowBackgroundColor))
        } detail: {
            Group {
                switch selection ?? .home {
                case .home:
                    HomePage()
                case .activity:
                    ActivityPage()
                case .insights:
                    InsightsPage()
                case .dictionary:
                    DictionaryPage()
                case .snippets:
                    SnippetsPage()
                case .styles:
                    StylesPage()
                case .scratchpad:
                    ScratchpadPage()
                case .settings:
                    SettingsPage()
                }
            }
            .environmentObject(controller)
            .frame(minWidth: 760, minHeight: 560)
        }
    }
}

struct HomePage: View {
    @EnvironmentObject private var controller: AppStateController
    @Query(sort: \TranscriptHistoryItem.createdAt, order: .reverse) private var history: [TranscriptHistoryItem]

    var body: some View {
        PageContainer(title: "Good day. Ready when you are.") {
            PermissionBanner()
            HStack {
                MetricCard(title: "Words dictated", value: "\(history.reduce(0) { $0 + $1.wordCount })")
                MetricCard(title: "Sessions", value: "\(history.count)")
                MetricCard(title: "Voice profile", value: "Local")
            }
            InfoCard(title: "Current shortcut", body: "Hands-free: \(controller.settings.toggleShortcut) - Push-to-talk: \(controller.settings.holdShortcut)")
            SectionHeader("Recent activity")
            if history.isEmpty {
                EmptyState(title: "No recent dictations", body: "Place your cursor in any app and start speaking.")
            } else {
                VStack(spacing: 8) {
                    ForEach(history.prefix(5)) { item in
                        TranscriptRow(item: item)
                    }
                }
            }
        }
    }
}

struct ActivityPage: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \TranscriptHistoryItem.createdAt, order: .reverse) private var history: [TranscriptHistoryItem]
    @State private var query = ""

    var filtered: [TranscriptHistoryItem] {
        guard !query.isEmpty else { return history }
        return history.filter { $0.transcript.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        PageContainer(title: "Recent Activity") {
            HStack {
                TextField("Search transcripts", text: $query)
                    .textFieldStyle(.roundedBorder)
                Button("Clear history") {
                    for item in history {
                        context.delete(item)
                    }
                    saveContext(context)
                }
            }
            if filtered.isEmpty {
                EmptyState(title: "No matching transcripts", body: "History is local to this native app.")
            } else {
                Table(filtered) {
                    TableColumn("Time") { Text($0.createdAt.formatted(date: .abbreviated, time: .shortened)) }
                    TableColumn("Result") { Text($0.pasted ? "Pasted" : "Copied") }
                    TableColumn("Words") { Text("\($0.wordCount)") }
                    TableColumn("Transcript") { Text($0.transcript).lineLimit(2) }
                }
                .frame(minHeight: 360)
            }
        }
    }
}

struct InsightsPage: View {
    @Query private var usage: [DailyUsage]
    @Query private var history: [TranscriptHistoryItem]
    @State private var tab = "Your Usage"

    var body: some View {
        PageContainer(title: "Insights") {
            Picker("Tab", selection: $tab) {
                Text("Your Usage").tag("Your Usage")
                Text("Leaderboard").tag("Leaderboard")
            }
            .pickerStyle(.segmented)

            if tab == "Your Usage" {
                HStack {
                    MetricCard(title: "Total words", value: "\(history.reduce(0) { $0 + $1.wordCount })")
                    MetricCard(title: "Dictations", value: "\(history.count)")
                    MetricCard(title: "Words/min", value: "Local")
                    MetricCard(title: "Streak", value: "\(currentStreak) days")
                }
                InfoCard(title: "Desktop usage", body: "Pasted \(history.filter(\.pasted).count) - Copied \(history.filter { !$0.pasted }.count)")
                InfoCard(title: "Usage heatmap", body: usage.sorted { $0.day > $1.day }.prefix(42).map { $0.words > 0 ? "■" : "□" }.joined(separator: " "))
            } else {
                EmptyState(title: "No leaderboard available", body: "Usage insights are currently limited to this Mac.")
            }
        }
    }

    private var currentStreak: Int {
        let days = Set(usage.map(\.day)).sorted(by: >)
        guard !days.isEmpty else { return 0 }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        var previous: Date?
        var streak = 0
        for day in days {
            guard let date = formatter.date(from: day) else { continue }
            if previous == nil || Calendar.current.dateComponents([.day], from: date, to: previous!).day == 1 {
                streak += 1
                previous = date
            } else {
                break
            }
        }
        return streak
    }
}

struct DictionaryPage: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \DictionaryEntry.phrase) private var entries: [DictionaryEntry]
    @State private var phrase = ""
    @State private var replacement = ""
    @State private var query = ""

    var filtered: [DictionaryEntry] {
        guard !query.isEmpty else { return entries }
        return entries.filter { $0.phrase.localizedCaseInsensitiveContains(query) || $0.replacement.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        PageContainer(title: "Dictionary") {
            InfoCard(title: "Teach Flow your words", body: "Add words and corrections you want Flowtype to recognize consistently.")
            HStack {
                TextField("Search dictionary", text: $query).textFieldStyle(.roundedBorder)
                TextField("Phrase", text: $phrase).textFieldStyle(.roundedBorder)
                TextField("Correction", text: $replacement).textFieldStyle(.roundedBorder)
                Button("Add") {
                    context.insert(DictionaryEntry(phrase: phrase, replacement: replacement))
                    phrase = ""
                    replacement = ""
                    saveContext(context)
                }
                .disabled(phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Table(filtered) {
                TableColumn("Phrase", value: \.phrase)
                TableColumn("Correction", value: \.replacement)
                TableColumn("Uses") { Text("\($0.usageCount)") }
            }
            .frame(minHeight: 360)
        }
    }
}

struct SnippetsPage: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Snippet.trigger) private var snippets: [Snippet]
    @State private var trigger = ""
    @State private var expansion = ""

    var body: some View {
        PageContainer(title: "Snippets") {
            InfoCard(title: "Say it once", body: "Voice triggers expand into saved text blocks stored on this Mac.")
            HStack {
                TextField("Trigger", text: $trigger).textFieldStyle(.roundedBorder)
                TextField("Expansion", text: $expansion).textFieldStyle(.roundedBorder)
                Button("Add") {
                    context.insert(Snippet(trigger: trigger, expansion: expansion))
                    trigger = ""
                    expansion = ""
                    saveContext(context)
                }
                .disabled(trigger.isEmpty || expansion.isEmpty)
            }
            Table(snippets) {
                TableColumn("Scope", value: \.scope)
                TableColumn("Trigger", value: \.trigger)
                TableColumn("Expansion", value: \.expansion)
            }
            .frame(minHeight: 360)
        }
    }
}

struct StylesPage: View {
    @EnvironmentObject private var controller: AppStateController
    @State private var category = WritingStyleScope.personal

    private let styles = ["Formal", "Casual", "Very Casual", "Excited"]

    var body: some View {
        PageContainer(title: "Styles") {
            InfoCard(title: "English-only personalization", body: "Choose a tone preference for each app category.")
            Picker("Category", selection: $category) {
                ForEach(WritingStyleScope.allCases) { scope in
                    Text(scope.rawValue.capitalized).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220))], spacing: 12) {
                ForEach(styles, id: \.self) { style in
                    Button {
                        var next = controller.settings
                        next.stylePreferences[category.rawValue] = style
                        controller.saveSettings(next)
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(style).font(.headline)
                            Text(stylePreview(style)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }
}

struct ScratchpadPage: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ScratchpadNote.updatedAt, order: .reverse) private var notes: [ScratchpadNote]
    @State private var title = ""
    @State private var bodyText = ""

    var body: some View {
        PageContainer(title: "Scratchpad") {
            InfoCard(title: "Quick notes", body: "Capture drafts and notes locally while dictating.")
            HStack(alignment: .top, spacing: 16) {
                List(notes) { note in
                    VStack(alignment: .leading) {
                        Text(note.title).font(.headline)
                        Text(note.updatedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 220)
                .frame(minHeight: 420)
                VStack {
                    TextField("Title", text: $title).textFieldStyle(.roundedBorder)
                    TextEditor(text: $bodyText)
                        .frame(minHeight: 320)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                    HStack {
                        ForEach(["More concise", "Professional", "Casual", "List", "Polish"], id: \.self) { chip in
                            Button(chip) {}
                                .disabled(true)
                        }
                        Spacer()
                        Button("Save") {
                            context.insert(ScratchpadNote(title: title, body: bodyText))
                            title = ""
                            bodyText = ""
                            saveContext(context)
                        }
                    }
                }
            }
        }
    }
}

struct SettingsPage: View {
    @EnvironmentObject private var controller: AppStateController
    @State private var draft = AppSettings.defaults

    var body: some View {
        PageContainer(title: "Settings") {
            TabView {
                Form {
                    Picker("Flow Bar position", selection: $draft.flowBarPosition) {
                        Text("Bottom right").tag(FlowBarPosition.bottomRight)
                        Text("Bottom center").tag(FlowBarPosition.bottomCenter)
                    }
                }
                .tabItem { Text("General") }

                Form {
                    TextField("Hands-free toggle", text: $draft.toggleShortcut)
                    TextField("Push-to-talk", text: $draft.holdShortcut)
                    TextField("Cancel", text: $draft.cancelShortcut)
                    TextField("Paste last", text: $draft.pasteLastShortcut)
                    TextField("Open Scratchpad", text: $draft.scratchpadShortcut)
                    TextField("Command Mode", text: $draft.commandModeShortcut)
                }
                .tabItem { Text("Shortcuts") }

                Form {
                    Section("Transcription") {
                        Picker("Provider", selection: $draft.transcriptionProvider) {
                            Text("Local WhisperKit").tag(TranscriptionProvider.local)
                            Text("Groq").tag(TranscriptionProvider.groq)
                        }
                        if draft.transcriptionProvider == .local {
                            TextField("Whisper model", text: $draft.transcriptionModel)
                        } else {
                            LabeledContent("Groq model") {
                                Text(AppSettings.groqTranscriptionModel)
                                    .textSelection(.enabled)
                            }
                            SecureField("Groq API key", text: $draft.groqAPIKey)
                        }
                        LabeledContent("Language") {
                            Text("English")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ModelDownloadSection(draft: $draft)
                }
                .tabItem { Text("Audio") }

                Form {
                    Toggle("Restore previous clipboard after paste", isOn: $draft.restoreClipboardAfterPaste)
                    Picker("Data Storage", selection: $draft.retentionPolicy) {
                        Text("Store normally").tag(RetentionPolicy.normal)
                        Text("Auto-delete after 24 hours").tag(RetentionPolicy.twentyFourHours)
                        Text("Never store transcripts").tag(RetentionPolicy.never)
                    }
                }
                .tabItem { Text("Data & Privacy") }

                VStack(alignment: .leading) {
                    InfoCard(title: "Signed out", body: "Account features are unavailable in this local build.")
                    InfoCard(title: "Local data", body: "Transcription history stays on this device and does not sync.")
                }
                .padding()
                .tabItem { Text("Account") }
            }
            .frame(minHeight: 430)
            HStack {
                Button("Request permissions") { controller.requestPermissions() }
                Spacer()
                Button("Save and apply") { controller.saveSettings(draft) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear {
            draft = controller.settings
            controller.refreshModelStatus(for: draft)
        }
        .onChange(of: draft.transcriptionModel) {
            controller.refreshModelStatus(for: draft)
        }
        .onChange(of: draft.transcriptionProvider) {
            controller.refreshModelStatus(for: draft)
        }
        .onChange(of: draft.groqAPIKey) {
            controller.refreshModelStatus(for: draft)
        }
    }
}

struct ModelDownloadSection: View {
    @EnvironmentObject private var controller: AppStateController
    @Binding var draft: AppSettings

    var body: some View {
        Section(draft.transcriptionProvider == .local ? "Local model" : "Groq") {
            LabeledContent(draft.transcriptionProvider == .local ? "Resolved model" : "Selected model") {
                Text(controller.modelStatus.modelName)
                    .textSelection(.enabled)
            }
            LabeledContent("Status") {
                HStack(spacing: 8) {
                    Circle()
                        .fill(controller.modelStatus.isDownloaded ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(statusText)
                        .foregroundStyle(controller.modelStatus.isDownloaded ? .primary : .secondary)
                }
            }
            if let localPath = controller.modelStatus.localPath, controller.modelStatus.isDownloaded {
                LabeledContent("Local path") {
                    Text(localPath)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            if !controller.modelDownloadMessage.isEmpty {
                Text(controller.modelDownloadMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Refresh status") {
                    controller.refreshModelStatus(for: draft)
                }
                Spacer()
                if draft.transcriptionProvider == .local {
                    Button {
                        controller.downloadModel(for: draft)
                    } label: {
                        if controller.isDownloadingModel {
                            ProgressView()
                                .controlSize(.small)
                            Text("Downloading...")
                        } else {
                            Text("Download model")
                        }
                    }
                    .disabled(controller.modelStatus.isDownloaded || controller.isDownloadingModel)
                }
            }
        }
    }

    private var statusText: String {
        switch draft.transcriptionProvider {
        case .local:
            controller.modelStatus.isDownloaded ? "Downloaded" : "Will download on next dictation"
        case .groq:
            controller.modelStatus.isDownloaded ? "API key configured" : "API key required"
        }
    }
}

struct PermissionBanner: View {
    @EnvironmentObject private var controller: AppStateController

    var body: some View {
        if controller.permissionsMessage.isEmpty {
            InfoCard(title: "Ready to Flow", body: "Place your cursor in any app, then use your shortcut or hold-to-talk.")
        } else {
            InfoCard(title: "Permission needed", body: controller.permissionsMessage)
        }
    }
}

struct PageContainer<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(title)
                    .font(.largeTitle.bold())
                content
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct MetricCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title.bold())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
    }
}

struct InfoCard: View {
    let title: String
    let message: String

    init(title: String, body: String) {
        self.title = title
        self.message = body
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(message).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.blue.opacity(0.12)))
    }
}

struct TranscriptRow: View {
    let item: TranscriptHistoryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.pasted ? "Pasted" : "Copied")
                    .font(.caption.bold())
                Spacer()
                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(item.transcript).lineLimit(2)
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
    }
}

struct EmptyState: View {
    let title: String
    let message: String

    init(title: String, body: String) {
        self.title = title
        self.message = body
    }

    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.headline)
            Text(message).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
    }
}

struct SectionHeader: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text).font(.headline)
    }
}

private func stylePreview(_ style: String) -> String {
    switch style {
    case "Formal":
        "Thank you for your message. I will follow up shortly."
    case "Casual":
        "Thanks, I'll get back to you soon."
    case "Very Casual":
        "sounds good, i'll reply soon"
    case "Excited":
        "Thanks! I'll take a look and follow up soon!"
    default:
        ""
    }
}

private func saveContext(_ context: ModelContext) {
    do {
        try context.save()
    } catch {
        NSLog("Flowtype local data save failed: \(error.localizedDescription)")
    }
}
