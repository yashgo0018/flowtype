import AppKit
import Combine
import Sparkle
import SwiftData
import SwiftUI

@main
struct FlowtypeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The Hub window is managed by AppDelegate so it can be reopened from the menu bar.
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appDelegate.controller.showHub(.settings)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {}
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    let controller = AppStateController()

    private var modelContainer: ModelContainer?
    private var flowBarController: FlowBarPanelController?
    private var hubWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var cancellables: Set<AnyCancellable> = []
    private let updateReminders = GentleUpdateReminders()
    private var updaterController: SPUStandardUpdaterController?

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard !Self.isRunningTests else { return }
        terminateOtherInstances()

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: updateReminders
        )

        let container = NativeSchema.makeContainer()
        modelContainer = container
        controller.onShowHub = { [weak self] in self?.showHub() }
        controller.onCheckForUpdates = { [weak self] in self?.checkForUpdates() }
        controller.start(localStore: LocalStore(context: container.mainContext))

        let flowBar = FlowBarPanelController(controller: controller)
        flowBarController = flowBar
        flowBar.show()
        installStatusItem()

        if !controller.hasCompletedOnboarding || !controller.permissions.accessibility {
            controller.showHub(.home)
            controller.hasCompletedOnboarding = true
        }
    }

    /// Two copies (e.g. an old download and a new install) would both react to the push-to-talk
    /// key and paste every dictation twice. The most recently launched copy takes over.
    private func terminateOtherInstances() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let current = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != current }
        for app in others {
            Log.app.info("Asking another running copy (pid \(app.processIdentifier)) to quit")
            if !app.terminate() {
                app.forceTerminate()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showHub()
        return false
    }

    func checkForUpdates() {
        NSApp.activate()
        updaterController?.checkForUpdates(nil)
    }

    // MARK: - Hub window

    func showHub() {
        guard let modelContainer else { return }
        if hubWindow == nil {
            let root = HubRootView()
                .environmentObject(controller)
                .modelContainer(modelContainer)
            let hosting = NSHostingController(rootView: root)
            let window = NSWindow(contentViewController: hosting)
            window.title = "Flowtype"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.setContentSize(NSSize(width: 980, height: 680))
            window.contentMinSize = NSSize(width: 820, height: 560)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setFrameAutosaveName("FlowtypeHub")
            if !window.setFrameUsingName("FlowtypeHub") {
                window.center()
            }
            hubWindow = window
        }
        NSApp.activate()
        hubWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Menu bar

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateStatusIcon(phase: controller.phase)

        controller.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in self?.updateStatusIcon(phase: phase) }
            .store(in: &cancellables)
        controller.$permissions
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateStatusIcon(phase: self.controller.phase)
            }
            .store(in: &cancellables)
    }

    private func updateStatusIcon(phase: DictationPhase) {
        let symbol: String
        switch phase {
        case .recording: symbol = "waveform.circle.fill"
        case .transcribing: symbol = "ellipsis.circle"
        case .idle, .finished: symbol = controller.needsSetup ? "exclamationmark.bubble" : "waveform"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Flowtype")
        image?.isTemplate = true
        statusItem?.button?.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if controller.needsSetup {
            menu.addItem(actionItem("Finish setup…", image: "exclamationmark.triangle") { [weak self] in
                self?.controller.showHub(.home)
            })
            menu.addItem(.separator())
        }

        let isRecording = controller.phase.isRecording
        let dictate = actionItem(isRecording ? "Stop Dictation" : "Start Dictation", image: isRecording ? "stop.circle" : "mic") { [weak self] in
            self?.controller.toggleFromFlowBar()
        }
        dictate.isEnabled = controller.phase != .transcribing
        applyShortcut(controller.settings.toggleShortcut, to: dictate)
        menu.addItem(dictate)

        let pasteLast = actionItem("Paste Last Transcript", image: "doc.on.clipboard") { [weak self] in
            self?.controller.pasteLastTranscript()
        }
        pasteLast.isEnabled = controller.lastTranscript != nil
        applyShortcut(controller.settings.pasteLastShortcut, to: pasteLast)
        menu.addItem(pasteLast)

        menu.addItem(.separator())
        menu.addItem(actionItem("Open Flowtype", image: "macwindow") { [weak self] in
            self?.controller.showHub()
        })
        menu.addItem(actionItem("History", image: "clock.arrow.circlepath") { [weak self] in
            self?.controller.showHub(.history)
        })
        let settings = actionItem("Settings…", image: "gearshape") { [weak self] in
            self?.controller.showHub(.settings)
        }
        settings.keyEquivalent = ","
        menu.addItem(settings)
        menu.addItem(actionItem("Check for Updates…", image: "arrow.triangle.2.circlepath") { [weak self] in
            self?.checkForUpdates()
        })
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Flowtype", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func actionItem(_ title: String, image: String, action: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, action: action)
        item.image = NSImage(systemSymbolName: image, accessibilityDescription: nil)
        return item
    }

    /// Shows a shortcut next to a menu item for reference (menu key equivalents only fire while the menu is open).
    private func applyShortcut(_ shortcut: String, to item: NSMenuItem) {
        guard let parsed = try? ShortcutParser.parse(shortcut),
              let name = ShortcutParser.canonical(shortcut).split(separator: "+").last else { return }
        let key: String
        switch name {
        case "space": key = " "
        case "return": key = "\r"
        case "tab": key = "\t"
        default: key = name.count == 1 ? String(name) : ""
        }
        guard !key.isEmpty else { return }
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = parsed.modifiers
    }
}

/// Flowtype lives in the menu bar, so scheduled update prompts are shown without stealing focus
/// from whatever the user is typing in.
private final class GentleUpdateReminders: NSObject, SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        true
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func run() {
        handler()
    }
}
