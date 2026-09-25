import Charts
import SwiftData
import SwiftUI

struct HubRootView: View {
    @EnvironmentObject private var controller: AppStateController

    private var selection: Binding<HubPage?> {
        Binding(
            get: { controller.hubPage },
            set: { if let page = $0 { controller.hubPage = page } }
        )
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                Section {
                    ForEach([HubPage.home, .history]) { page in
                        Label(page.title, systemImage: page.systemImage).tag(page)
                    }
                }
                Section("Personalize") {
                    ForEach([HubPage.dictionary, .snippets, .notes]) { page in
                        Label(page.title, systemImage: page.systemImage).tag(page)
                    }
                }
                Section {
                    Label(HubPage.settings.title, systemImage: HubPage.settings.systemImage).tag(HubPage.settings)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) {
                SidebarStatusView()
                    .padding(12)
            }
        } detail: {
            Group {
                switch controller.hubPage {
                case .home: HomeView()
                case .history: HistoryView()
                case .dictionary: DictionaryView()
                case .snippets: SnippetsView()
                case .notes: NotesView()
                case .settings: SettingsView()
                }
            }
            .frame(minWidth: 600, maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}

private struct SidebarStatusView: View {
    @EnvironmentObject private var controller: AppStateController

    var body: some View {
        Button {
            controller.hubPage = controller.needsSetup ? .home : .settings
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(statusTitle)
                        .font(.callout.weight(.medium))
                    Text(engineTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var statusTitle: String {
        switch controller.phase {
        case .recording: "Listening…"
        case .transcribing: "Transcribing…"
        default: controller.needsSetup ? "Setup needed" : "Ready"
        }
    }

    private var statusColor: Color {
        if controller.phase.isRecording { return .red }
        return controller.needsSetup ? .orange : .green
    }

    private var engineTitle: String {
        switch controller.settings.transcriptionProvider {
        case .local:
            let model = WhisperModelOption.option(for: controller.settings.transcriptionModel)?.title ?? "Whisper"
            return "On-device · \(model)"
        case .groq:
            return "Groq cloud · Whisper Turbo"
        }
    }
}

// MARK: - Home

struct HomeView: View {
    @EnvironmentObject private var controller: AppStateController
    @Query(sort: \DailyUsage.day, order: .reverse) private var usage: [DailyUsage]
    @Query(sort: \TranscriptHistoryItem.createdAt, order: .reverse) private var history: [TranscriptHistoryItem]

    var body: some View {
        PageScrollView(spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text(greeting)
                    .font(.system(size: 30, weight: .bold))
                HowToDictateView()
            }

            if showsSetup {
                SetupChecklist()
            }

            StatsGrid(usage: usage)

            Card {
                VStack(alignment: .leading, spacing: 12) {
                    CardTitle("Words per day", subtitle: "Last 14 days")
                    UsageChart(usage: usage)
                        .frame(height: 160)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Recent")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    if !history.isEmpty {
                        Button("View all") { controller.hubPage = .history }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                if history.isEmpty {
                    Card {
                        EmptyStateView(
                            systemImage: "waveform",
                            title: "No dictations yet",
                            message: "Click into any text field, then use your shortcut and start talking."
                        )
                    }
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

    private var showsSetup: Bool {
        controller.needsSetup || !controller.permissions.microphoneGranted
            || (controller.settings.transcriptionProvider == .local && !controller.modelStatus.isReady)
            || controller.modelActivity != nil
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }
}

struct HowToDictateView: View {
    @EnvironmentObject private var controller: AppStateController

    var body: some View {
        HStack(spacing: 6) {
            if controller.settings.holdKey != .off {
                Text("Hold")
                KeyCapsView(keys: [controller.settings.holdKey.symbol])
                Text("to talk, or press")
            } else {
                Text("Press")
            }
            KeyCapsView(keys: ShortcutParser.symbols(controller.settings.toggleShortcut))
            Text("to start and stop.")
        }
        .font(.body)
        .foregroundStyle(.secondary)
    }
}

private struct StatsGrid: View {
    let usage: [DailyUsage]

    var body: some View {
        let stats = UsageStats(usage: usage)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
            StatTile(title: "Words dictated", value: stats.totalWords.formatted(), systemImage: "text.word.spacing")
            StatTile(title: "Speaking pace", value: stats.wordsPerMinute.map { "\($0) wpm" } ?? "—", systemImage: "speedometer")
            StatTile(title: "Time saved", value: stats.timeSavedText, systemImage: "hourglass")
            StatTile(title: "Day streak", value: "\(stats.streak)", systemImage: "flame")
        }
    }
}

struct UsageStats {
    let totalWords: Int
    let wordsPerMinute: Int?
    let timeSavedMinutes: Double
    let streak: Int

    /// Average typing speed used to estimate time saved.
    static let typingWordsPerMinute = 40.0

    init(usage: [DailyUsage], now: Date = .now, calendar: Calendar = .current) {
        totalWords = usage.reduce(0) { $0 + $1.words }

        // Older rows have no recorded duration; leave them out of pace calculations.
        let timed = usage.filter { $0.dictationSeconds > 0 }
        let timedWords = Double(timed.reduce(0) { $0 + $1.words })
        let timedMinutes = timed.reduce(0) { $0 + $1.dictationSeconds } / 60
        wordsPerMinute = timedMinutes > 0.25 ? Int((timedWords / timedMinutes).rounded()) : nil
        timeSavedMinutes = max(0, timedWords / Self.typingWordsPerMinute - timedMinutes)
        streak = TextMetrics.streak(dayKeys: Set(usage.filter { $0.words > 0 }.map(\.day)), today: now, calendar: calendar)
    }

    var timeSavedText: String {
        let minutes = Int(timeSavedMinutes.rounded())
        if minutes < 1 { return "—" }
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}

private struct UsageChart: View {
    let usage: [DailyUsage]

    private struct Point: Identifiable {
        let date: Date
        let words: Int
        var id: Date { date }
    }

    private var points: [Point] {
        let calendar = Calendar.current
        let byDay = Dictionary(usage.map { ($0.day, $0.words) }, uniquingKeysWith: +)
        let today = calendar.startOfDay(for: .now)
        return (0..<14).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return Point(date: date, words: byDay[TextMetrics.dayKey(for: date)] ?? 0)
        }
    }

    var body: some View {
        Chart(points) { point in
            BarMark(
                x: .value("Day", point.date, unit: .day),
                y: .value("Words", point.words)
            )
            .foregroundStyle(Color.accentColor.gradient)
            .cornerRadius(4)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine()
                AxisValueLabel()
            }
        }
    }
}

// MARK: - Setup

struct SetupChecklist: View {
    @EnvironmentObject private var controller: AppStateController

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                CardTitle("Finish setting up", subtitle: "Flowtype needs a couple of permissions to type for you.")
                PermissionRows()
                Divider()
                ModelSetupRow()
                if controller.settings.holdKey == .fn, FnKeyUsage.opensSystemFeature {
                    Divider()
                    SetupRow(
                        systemImage: "globe",
                        title: "Stop the Fn key opening emoji",
                        detail: "In Keyboard settings, set “Press 🌐 key to” to “Do Nothing” so holding Fn only dictates.",
                        isDone: false
                    ) {
                        Button("Open Keyboard Settings") { PermissionService.openKeyboardSettings() }
                    }
                }
            }
        }
    }
}

struct PermissionRows: View {
    @EnvironmentObject private var controller: AppStateController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SetupRow(
                systemImage: "mic",
                title: "Microphone",
                detail: "To hear what you say. Audio never leaves your Mac with on-device transcription.",
                isDone: controller.permissions.microphoneGranted
            ) {
                Button(controller.permissions.microphone == .notDetermined ? "Allow" : "Open Settings") {
                    controller.requestMicrophoneAccess()
                }
            }
            SetupRow(
                systemImage: "keyboard",
                title: "Accessibility",
                detail: "To paste text into the app you're using and listen for your shortcut.",
                isDone: controller.permissions.accessibility
            ) {
                HStack(spacing: 8) {
                    Button("Allow") { controller.requestAccessibilityAccess() }
                    Button("Already on?") { controller.resetAccessibilityAccess() }
                        .help("If Flowtype is already switched on in System Settings but still not working, this clears the stale entry and asks again.")
                }
            }
        }
    }
}

private struct ModelSetupRow: View {
    @EnvironmentObject private var controller: AppStateController

    var body: some View {
        switch controller.settings.transcriptionProvider {
        case .local:
            let option = WhisperModelOption.option(for: controller.settings.transcriptionModel)
            SetupRow(
                systemImage: "cpu",
                title: "Speech model",
                detail: controller.modelError ?? "\(option?.title ?? "Whisper") runs privately on your Mac. \(option?.detail ?? "")",
                isDone: controller.modelStatus.isReady && controller.modelActivity == nil
            ) {
                ModelDownloadButton()
            }
        case .groq:
            SetupRow(
                systemImage: "cloud",
                title: "Groq API key",
                detail: "Needed for cloud transcription.",
                isDone: controller.settings.hasGroqAPIKey
            ) {
                Button("Add Key") { controller.hubPage = .settings }
            }
        }
    }
}

struct ModelDownloadButton: View {
    @EnvironmentObject private var controller: AppStateController

    var body: some View {
        switch controller.modelActivity {
        case .downloading(let fraction):
            HStack(spacing: 8) {
                ProgressView(value: fraction)
                    .frame(width: 110)
                Text("\(Int(fraction * 100))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading…").foregroundStyle(.secondary)
            }
        case nil:
            if !controller.modelStatus.isReady {
                Button("Download") { controller.prepareModel() }
            }
        }
    }
}

struct SetupRow<Accessory: View>: View {
    let systemImage: String
    let title: String
    let detail: String
    let isDone: Bool
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: isDone ? "checkmark.circle.fill" : systemImage)
                .font(.system(size: 18))
                .foregroundStyle(isDone ? Color.green : Color.accentColor)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if !isDone {
                accessory
            }
        }
    }
}

enum FnKeyUsage {
    /// Whether pressing Fn/Globe also triggers a system feature (emoji picker, input source, Apple dictation).
    static var opensSystemFeature: Bool {
        let value = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString) as? Int
        return value != 0
    }
}

// MARK: - Shared components

struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07))
            )
    }
}

struct CardTitle: View {
    let title: String
    let subtitle: String?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            if let subtitle {
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: systemImage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }
}

struct KeyCapsView: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 22, minHeight: 20)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.18))
                    )
                    .shadow(color: .black.opacity(0.08), radius: 0, y: 1)
            }
        }
    }
}

/// Scrolling page body with the Hub's standard padding and readable width.
struct PageScrollView<Content: View>: View {
    @Environment(\.pageScrollingDisabled) private var scrollingDisabled
    var spacing: CGFloat = 20
    @ViewBuilder let content: Content

    var body: some View {
        let page = VStack(alignment: .leading, spacing: spacing) {
            content
        }
        .padding(28)
        .frame(maxWidth: 900, alignment: .leading)
        .frame(maxWidth: .infinity)

        if scrollingDisabled {
            page.frame(maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView { page }
        }
    }
}

extension EnvironmentValues {
    /// Lays pages out without a scroll view. Used to render website screenshots, since
    /// ImageRenderer can't draw scroll views.
    @Entry var pageScrollingDisabled = false
}

struct PageHeader<Accessory: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 26, weight: .bold))
                Text(subtitle).foregroundStyle(.secondary)
            }
            Spacer()
            accessory
        }
    }
}

extension PageHeader where Accessory == EmptyView {
    init(title: String, subtitle: String) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

struct TranscriptRow: View {
    @EnvironmentObject private var controller: AppStateController
    @Environment(\.modelContext) private var context
    let item: TranscriptHistoryItem
    var showsDate = true
    @State private var isHovering = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.transcript)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(showsDate
                         ? item.createdAt.formatted(date: .abbreviated, time: .shortened)
                         : item.createdAt.formatted(date: .omitted, time: .shortened))
                    Text("·")
                    Text("\(item.wordCount) words")
                    if !item.pasted {
                        Text("·")
                        Text("Copied")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Button {
                    controller.copyToClipboard(item.transcript)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .frame(width: 16)
                }
                .help("Copy")
                Button(role: .destructive) {
                    context.delete(item)
                    try? context.save()
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete")
            }
            .buttonStyle(.borderless)
            .opacity(isHovering || copied ? 1 : 0)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07))
        )
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Copy") { controller.copyToClipboard(item.transcript) }
            Button("Delete", role: .destructive) {
                context.delete(item)
                try? context.save()
            }
        }
    }
}
