import SwiftData
import SwiftUI

// MARK: - History

struct HistoryView: View {
    @EnvironmentObject private var controller: AppStateController
    @Query(sort: \TranscriptHistoryItem.createdAt, order: .reverse) private var items: [TranscriptHistoryItem]
    @State private var search = ""
    @State private var confirmingClear = false

    private var filtered: [TranscriptHistoryItem] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return items }
        return items.filter { $0.transcript.localizedCaseInsensitiveContains(query) }
    }

    private var sections: [(day: Date, items: [TranscriptHistoryItem])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.createdAt) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        PageScrollView {
            PageHeader(title: "History", subtitle: historySubtitle) {
                Button("Clear All…", role: .destructive) { confirmingClear = true }
                    .disabled(items.isEmpty)
            }

            SearchField(text: $search, prompt: "Search transcripts")

            if filtered.isEmpty {
                Card {
                    EmptyStateView(
                        systemImage: search.isEmpty ? "clock" : "magnifyingglass",
                        title: search.isEmpty ? "No history yet" : "No matches",
                        message: search.isEmpty ? "Your dictations will show up here." : "Try a different word."
                    )
                }
            } else {
                LazyVStack(alignment: .leading, spacing: 8, pinnedViews: []) {
                    ForEach(sections, id: \.day) { section in
                        Text(dayTitle(section.day))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                        ForEach(section.items) { item in
                            TranscriptRow(item: item, showsDate: false)
                        }
                    }
                }
            }
        }
        .confirmationDialog("Delete all history?", isPresented: $confirmingClear) {
            Button("Delete All History", role: .destructive) { controller.deleteAllHistory() }
        } message: {
            Text("This permanently removes every saved transcript from this Mac. Your usage stats are kept.")
        }
    }

    private var historySubtitle: String {
        switch controller.settings.retentionPolicy {
        case .normal: "Everything you've dictated, stored only on this Mac."
        case .twentyFourHours: "Transcripts are deleted after 24 hours."
        case .never: "Saving is off. Change this in Settings → Privacy."
        }
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }
}

struct SearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1))
        )
    }
}

// MARK: - Dictionary

struct DictionaryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \DictionaryEntry.phrase) private var entries: [DictionaryEntry]
    @State private var phrase = ""
    @State private var replacement = ""
    @State private var search = ""
    @State private var editing: DictionaryEntry?
    @FocusState private var phraseFocused: Bool

    private var filtered: [DictionaryEntry] {
        guard !search.isEmpty else { return entries }
        return entries.filter {
            $0.phrase.localizedCaseInsensitiveContains(search) || $0.replacement.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        PageScrollView {
            PageHeader(
                title: "Dictionary",
                subtitle: "Names, jargon and spellings Flowtype should always get right."
            )

            Card {
                VStack(alignment: .leading, spacing: 12) {
                    CardTitle("Add a word", subtitle: "Leave “Replace with” empty to just fix capitalization, e.g. “kubernetes” → “Kubernetes”.")
                    HStack(spacing: 10) {
                        TextField("Word or phrase", text: $phrase)
                            .focused($phraseFocused)
                            .onSubmit(add)
                        Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                        TextField("Replace with (optional)", text: $replacement)
                            .onSubmit(add)
                        Button("Add", action: add)
                            .keyboardShortcut(.defaultAction)
                            .disabled(trimmedPhrase.isEmpty)
                    }
                    .textFieldStyle(.roundedBorder)
                }
            }

            if entries.count > 8 {
                SearchField(text: $search, prompt: "Search dictionary")
            }

            if filtered.isEmpty {
                Card {
                    EmptyStateView(
                        systemImage: "character.book.closed",
                        title: entries.isEmpty ? "Your dictionary is empty" : "No matches",
                        message: entries.isEmpty ? "Add product names, people, or acronyms you use often." : "Try a different word."
                    )
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(filtered) { entry in
                        DictionaryRow(entry: entry, onEdit: { editing = entry }, onDelete: { delete(entry) })
                        if entry.id != filtered.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(.vertical, 4)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
            }
        }
        .sheet(item: $editing) { entry in
            DictionaryEditSheet(entry: entry)
        }
    }

    private var trimmedPhrase: String {
        phrase.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func add() {
        let newPhrase = trimmedPhrase
        guard !newPhrase.isEmpty else { return }
        let newReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = entries.first(where: { $0.phrase.caseInsensitiveCompare(newPhrase) == .orderedSame }) {
            existing.replacement = newReplacement
            existing.updatedAt = .now
        } else {
            context.insert(DictionaryEntry(phrase: newPhrase, replacement: newReplacement))
        }
        try? context.save()
        phrase = ""
        replacement = ""
        phraseFocused = true
    }

    private func delete(_ entry: DictionaryEntry) {
        context.delete(entry)
        try? context.save()
    }
}

private struct DictionaryRow: View {
    let entry: DictionaryEntry
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Text(entry.phrase).fontWeight(.medium)
            if !entry.replacement.isEmpty {
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                Text(entry.replacement)
            }
            Spacer()
            if entry.usageCount > 0 {
                Text("Used \(entry.usageCount)×")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Button(action: onEdit) { Image(systemName: "pencil") }.help("Edit")
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }.help("Delete")
            }
            .buttonStyle(.borderless)
            .opacity(isHovering ? 1 : 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2, perform: onEdit)
        .contextMenu {
            Button("Edit…", action: onEdit)
            Button("Delete", role: .destructive, action: onDelete)
        }
    }
}

private struct DictionaryEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Bindable var entry: DictionaryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit word").font(.title3.weight(.semibold))
            Form {
                TextField("Word or phrase", text: $entry.phrase)
                TextField("Replace with", text: $entry.replacement, prompt: Text("Optional"))
            }
            .formStyle(.columns)
            HStack {
                Spacer()
                Button("Done") {
                    entry.phrase = entry.phrase.trimmingCharacters(in: .whitespacesAndNewlines)
                    entry.replacement = entry.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
                    entry.updatedAt = .now
                    try? context.save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(entry.phrase.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

// MARK: - Snippets

struct SnippetsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Snippet.trigger) private var snippets: [Snippet]
    @State private var trigger = ""
    @State private var expansion = ""
    @State private var editing: Snippet?
    @State private var error: String?

    var body: some View {
        PageScrollView {
            PageHeader(
                title: "Snippets",
                subtitle: "Say a short cue and Flowtype types the full text."
            )

            Card {
                VStack(alignment: .leading, spacing: 12) {
                    CardTitle("New snippet", subtitle: "Example: say “my calendar link” to insert your booking URL.")
                    TextField("When I say…", text: $trigger)
                        .textFieldStyle(.roundedBorder)
                    TextField("Type this", text: $expansion, axis: .vertical)
                        .lineLimit(2...6)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        if let error {
                            Text(error).font(.callout).foregroundStyle(.red)
                        }
                        Spacer()
                        Button("Add Snippet", action: add)
                            .disabled(trigger.trimmingCharacters(in: .whitespaces).isEmpty || expansion.isEmpty)
                    }
                }
            }

            if snippets.isEmpty {
                Card {
                    EmptyStateView(
                        systemImage: "text.badge.plus",
                        title: "No snippets yet",
                        message: "Great for email sign-offs, addresses, links and boilerplate replies."
                    )
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(snippets) { snippet in
                        SnippetRow(snippet: snippet, onEdit: { editing = snippet }, onDelete: {
                            context.delete(snippet)
                            try? context.save()
                        })
                    }
                }
            }
        }
        .sheet(item: $editing) { snippet in
            SnippetEditSheet(snippet: snippet)
        }
    }

    private func add() {
        let cue = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cue.isEmpty, !expansion.isEmpty else { return }
        guard !snippets.contains(where: { $0.trigger.caseInsensitiveCompare(cue) == .orderedSame }) else {
            error = "A snippet for “\(cue)” already exists."
            return
        }
        context.insert(Snippet(trigger: cue, expansion: expansion))
        try? context.save()
        trigger = ""
        expansion = ""
        error = nil
    }
}

private struct SnippetRow: View {
    let snippet: Snippet
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("“\(snippet.trigger)”")
                .fontWeight(.medium)
                .frame(width: 180, alignment: .leading)
            Text(snippet.expansion)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                Button(action: onEdit) { Image(systemName: "pencil") }.help("Edit")
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }.help("Delete")
            }
            .buttonStyle(.borderless)
            .opacity(isHovering ? 1 : 0)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2, perform: onEdit)
        .contextMenu {
            Button("Edit…", action: onEdit)
            Button("Delete", role: .destructive, action: onDelete)
        }
    }
}

private struct SnippetEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Bindable var snippet: Snippet

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit snippet").font(.title3.weight(.semibold))
            TextField("When I say…", text: $snippet.trigger)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $snippet.expansion)
                .font(.body)
                .frame(minHeight: 120)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
            HStack {
                Spacer()
                Button("Done") {
                    snippet.trigger = snippet.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
                    snippet.updatedAt = .now
                    try? context.save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(snippet.trigger.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

// MARK: - Notes

struct NotesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ScratchpadNote.updatedAt, order: .reverse) private var notes: [ScratchpadNote]
    @State private var selection: PersistentIdentifier?

    private var selectedNote: ScratchpadNote? {
        notes.first { $0.persistentModelID == selection }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Text("Notes").font(.title3.weight(.semibold))
                    Spacer()
                    Button(action: newNote) {
                        Image(systemName: "square.and.pencil")
                    }
                    .buttonStyle(.borderless)
                    .help("New note")
                    .keyboardShortcut("n", modifiers: .command)
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 8)

                List(selection: $selection) {
                    ForEach(notes) { note in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(note.displayTitle).font(.body.weight(.medium)).lineLimit(1)
                            Text(note.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                        .tag(note.persistentModelID)
                        .contextMenu {
                            Button("Delete", role: .destructive) { delete(note) }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
            .frame(width: 240)
            .background(Color.primary.opacity(0.03))

            Divider()

            Group {
                if let note = selectedNote {
                    NoteEditor(note: note, onDelete: { delete(note) })
                        .id(note.persistentModelID)
                } else {
                    VStack(spacing: 12) {
                        EmptyStateView(
                            systemImage: "note.text",
                            title: notes.isEmpty ? "No notes yet" : "Select a note",
                            message: "Notes are a scratchpad for drafts. Click into a note and dictate — the text lands right here."
                        )
                        Button("New Note", action: newNote)
                    }
                    .padding(40)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if selection == nil {
                selection = notes.first?.persistentModelID
            }
        }
    }

    private func newNote() {
        let note = ScratchpadNote(title: "", body: "")
        context.insert(note)
        try? context.save()
        selection = note.persistentModelID
    }

    private func delete(_ note: ScratchpadNote) {
        let wasSelected = note.persistentModelID == selection
        context.delete(note)
        try? context.save()
        if wasSelected {
            selection = notes.first { $0.persistentModelID != note.persistentModelID }?.persistentModelID
        }
    }
}

private struct NoteEditor: View {
    @Environment(\.modelContext) private var context
    @Bindable var note: ScratchpadNote
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TextField("Title", text: $note.title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .bold))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(note.body, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy note")
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .help("Delete note")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 10)

            TextEditor(text: $note.body)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 19)
                .padding(.bottom, 12)

            HStack {
                Text("\(TextMetrics.wordCount(note.body)) words")
                Spacer()
                Text("Edited \(note.updatedAt.formatted(.relative(presentation: .named)))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
        .onChange(of: note.title) { touch() }
        .onChange(of: note.body) { touch() }
        .onDisappear { try? context.save() }
    }

    private func touch() {
        note.updatedAt = .now
        note.version += 1
    }
}
