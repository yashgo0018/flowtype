import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var controller: AppStateController
    @State private var error: String?
    @State private var apiKeyDraft = ""
    @State private var microphones: [AudioInputDevice] = []
    @State private var confirmingDeleteHistory = false
    @State private var confirmingDeleteModels = false

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    ShortcutRecorder(shortcut: controller.settings.toggleShortcut, allowsClear: false) { value in
                        apply { $0.toggleShortcut = value }
                    }
                } label: {
                    Text("Hands-free dictation")
                    Text("Press to start, press again to finish. Hold it to talk only while pressed.")
                }

                Picker(selection: binding(\.holdKey)) {
                    ForEach(HoldKey.allCases) { key in
                        Text(key.title).tag(key)
                    }
                } label: {
                    Text("Push-to-talk key")
                    Text("Hold to talk, release to paste.")
                }

                LabeledContent {
                    ShortcutRecorder(shortcut: controller.settings.pasteLastShortcut, allowsClear: true) { value in
                        apply { $0.pasteLastShortcut = value }
                    }
                } label: {
                    Text("Paste last transcript")
                    Text("Re-inserts your most recent dictation.")
                }

                if let warning = controller.shortcutWarning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if let error {
                    Label(error, systemImage: "xmark.octagon")
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Shortcuts")
            } footer: {
                Text("Press Esc to cancel while dictating.")
                    .foregroundStyle(.secondary)
            }

            Section("Transcription") {
                Picker("Engine", selection: binding(\.transcriptionProvider)) {
                    ForEach(TranscriptionProvider.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                .pickerStyle(.segmented)

                switch controller.settings.transcriptionProvider {
                case .local:
                    localModelSettings
                case .groq:
                    groqSettings
                }

                Picker("Microphone", selection: binding(\.microphoneUID)) {
                    Text("System default").tag("")
                    ForEach(microphones) { device in
                        Text(device.name).tag(device.uid)
                    }
                    if !controller.settings.microphoneUID.isEmpty,
                       !microphones.contains(where: { $0.uid == controller.settings.microphoneUID }) {
                        Text("Unavailable device").tag(controller.settings.microphoneUID)
                    }
                }
            }

            Section("Dictation bar") {
                Picker("Position", selection: binding(\.flowBarPosition)) {
                    ForEach(FlowBarPosition.allCases) { position in
                        Text(position.title).tag(position)
                    }
                }
                Toggle(isOn: binding(\.showFlowBarWhenIdle)) {
                    Text("Show when not dictating")
                    Text("When off, the bar only appears while you dictate.")
                }
                Toggle("Play sounds", isOn: binding(\.playSounds))
            }

            Section("Privacy") {
                Picker("Transcript history", selection: binding(\.retentionPolicy)) {
                    ForEach(RetentionPolicy.allCases) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                Toggle(isOn: binding(\.restoreClipboardAfterPaste)) {
                    Text("Restore clipboard after pasting")
                    Text("Flowtype pastes through the clipboard, then puts back what you had copied.")
                }
                LabeledContent("Saved history") {
                    Button("Delete All History…", role: .destructive) { confirmingDeleteHistory = true }
                }
            }

            Section("Permissions") {
                PermissionRows()
                    .padding(.vertical, 4)
            }

            Section("About") {
                LabeledContent("Version") {
                    HStack(spacing: 12) {
                        Text(Self.versionString).foregroundStyle(.secondary)
                        Button("Check for Updates…") { controller.onCheckForUpdates?() }
                    }
                }
                LabeledContent("Privacy") {
                    Link("Privacy Policy", destination: URL(string: "https://github.com/yashgo0018/flowtype/blob/main/PRIVACY.md")!)
                }
                DisclosureGroup("Acknowledgements") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Self.acknowledgements, id: \.name) { item in
                            HStack {
                                Link(item.name, destination: URL(string: item.url)!)
                                Spacer()
                                Text(item.license).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .font(.callout)
                    .padding(.top, 4)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear {
            apiKeyDraft = controller.settings.groqAPIKey
            microphones = AudioDevices.inputDevices()
            controller.refreshModelStatus()
        }
        .onDisappear(perform: commitAPIKey)
        .confirmationDialog("Delete all history?", isPresented: $confirmingDeleteHistory) {
            Button("Delete All History", role: .destructive) { controller.deleteAllHistory() }
        } message: {
            Text("This permanently removes every saved transcript from this Mac.")
        }
        .confirmationDialog("Delete downloaded models?", isPresented: $confirmingDeleteModels) {
            Button("Delete Models", role: .destructive) { controller.deleteDownloadedModels() }
        } message: {
            Text("Frees disk space. The selected model downloads again the next time you dictate.")
        }
    }

    @ViewBuilder
    private var localModelSettings: some View {
        Picker(selection: binding(\.transcriptionModel)) {
            ForEach(WhisperModelOption.all) { option in
                Text(option.title).tag(option.id)
            }
        } label: {
            Text("Model")
            Text(WhisperModelOption.option(for: controller.settings.transcriptionModel)?.detail ?? "")
        }

        LabeledContent("Status") {
            HStack(spacing: 10) {
                if controller.modelActivity == nil {
                    Circle()
                        .fill(controller.modelStatus.isReady ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(controller.modelStatus.isReady ? "Downloaded" : "Not downloaded")
                        .foregroundStyle(.secondary)
                }
                ModelDownloadButton()
            }
        }
        if let modelError = controller.modelError {
            Label(modelError, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
        LabeledContent("Storage") {
            Button("Delete Downloaded Models…") { confirmingDeleteModels = true }
                .disabled(controller.modelActivity != nil)
        }
    }

    @ViewBuilder
    private var groqSettings: some View {
        LabeledContent {
            HStack {
                SecureField("gsk_…", text: $apiKeyDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commitAPIKey)
                Button("Save", action: commitAPIKey)
                    .disabled(apiKeyDraft.trimmingCharacters(in: .whitespaces) == controller.settings.groqAPIKey)
            }
        } label: {
            Text("Groq API key")
            Link("Get a free key", destination: URL(string: "https://console.groq.com/keys")!)
                .font(.caption)
        }
        LabeledContent("Model", value: AppSettings.groqTranscriptionModel)
        Label("Audio is sent to Groq for transcription. The key is stored in your Keychain.", systemImage: "lock.shield")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private func commitAPIKey() {
        let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key != controller.settings.groqAPIKey else { return }
        apply { $0.groqAPIKey = key }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { controller.settings[keyPath: keyPath] },
            set: { value in apply { $0[keyPath: keyPath] = value } }
        )
    }

    @discardableResult
    private func apply(_ change: (inout AppSettings) -> Void) -> String? {
        let result = controller.updateSettings(change)
        error = result
        return result
    }

    private static let acknowledgements: [(name: String, license: String, url: String)] = [
        ("OpenAI Whisper models", "MIT", "https://github.com/openai/whisper"),
        ("WhisperKit", "MIT", "https://github.com/argmaxinc/WhisperKit"),
        ("Sparkle", "MIT", "https://github.com/sparkle-project/Sparkle"),
        ("swift-transformers", "Apache 2.0", "https://github.com/huggingface/swift-transformers"),
        ("swift-jinja", "Apache 2.0", "https://github.com/huggingface/swift-jinja"),
        ("Swift Collections", "Apache 2.0", "https://github.com/apple/swift-collections"),
        ("Swift Crypto", "Apache 2.0", "https://github.com/apple/swift-crypto"),
        ("Swift ASN.1", "Apache 2.0", "https://github.com/apple/swift-asn1"),
        ("Swift Argument Parser", "Apache 2.0", "https://github.com/apple/swift-argument-parser"),
        ("yyjson", "MIT", "https://github.com/ibireme/yyjson")
    ]

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

/// Click, then press the new key combination. Esc cancels.
struct ShortcutRecorder: View {
    @EnvironmentObject private var controller: AppStateController
    let shortcut: String
    let allowsClear: Bool
    /// Returns an error message if the shortcut was rejected.
    let onChange: (String) -> String?

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Button(action: toggleRecording) {
                    Group {
                        if isRecording {
                            Text("Type shortcut…")
                                .foregroundStyle(Color.accentColor)
                        } else if shortcut.isEmpty {
                            Text("Not set")
                                .foregroundStyle(.secondary)
                        } else {
                            KeyCapsView(keys: ShortcutParser.symbols(shortcut))
                        }
                    }
                    .frame(minWidth: 110, minHeight: 22)
                }
                .help(isRecording ? "Press a key combination, or Esc to cancel" : "Click to change")

                if allowsClear, !shortcut.isEmpty, !isRecording {
                    Button {
                        message = onChange("")
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove shortcut")
                }
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        message = nil
        isRecording = true
        // Shortcuts are suspended so pressing the current combination doesn't start a dictation.
        controller.suspendShortcuts()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                handle(event)
            }
            return nil
        }
    }

    private func handle(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 53 && modifiers.isEmpty {
            stopRecording()
            return
        }
        guard let candidate = ShortcutParser.shortcut(from: event) else {
            message = "That key can't be used."
            NSSound.beep()
            return
        }
        do {
            _ = try ShortcutParser.parse(candidate)
        } catch {
            message = error.localizedDescription
            NSSound.beep()
            return
        }
        stopRecording()
        message = onChange(ShortcutParser.canonical(candidate))
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        if isRecording {
            isRecording = false
            controller.resumeShortcuts()
        }
    }
}
