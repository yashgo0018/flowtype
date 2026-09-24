import AppKit
import Carbon.HIToolbox

@MainActor
final class HotKeyService {
    var onTogglePressed: (() -> Void)?
    var onToggleReleased: (() -> Void)?
    var onPasteLast: (() -> Void)?
    var onCancel: (() -> Void)?
    var onHoldDown: (() -> Void)?
    var onHoldUp: (() -> Void)?
    /// Another key was pressed while the hold key was down (e.g. Fn+←), so it wasn't push-to-talk.
    var onHoldInterrupted: (() -> Void)?

    private enum HotKeyID: UInt32 {
        case toggle = 1
        case pasteLast = 2
        case cancel = 3
    }

    private var handlerRef: EventHandlerRef?
    private var registered: [HotKeyID: EventHotKeyRef] = [:]
    private var globalMonitor: Any?
    private var localMonitor: Any?

    private var toggleShortcut: ParsedShortcut?
    private var toggleShortcutName = ""
    private var pasteLastShortcut: ParsedShortcut?
    private var holdKey: HoldKey = .off
    /// Set when Carbon couldn't register the toggle shortcut, so event monitors detect it instead.
    private var toggleNeedsMonitor = false
    private var toggleIsDown = false
    private var holdActive = false
    private var cancelEnabled = false
    private var suspended = false

    /// Registers shortcuts. Returns a warning when a shortcut could only be partially registered.
    @discardableResult
    func configure(settings: AppSettings) throws -> String? {
        let toggle = try ShortcutParser.parse(settings.toggleShortcut)
        let pasteLast = settings.pasteLastShortcut.isEmpty ? nil : try ShortcutParser.parse(settings.pasteLastShortcut)
        toggleShortcut = toggle
        toggleShortcutName = settings.toggleShortcut
        pasteLastShortcut = pasteLast
        holdKey = settings.holdKey
        holdActive = false
        toggleIsDown = false

        installHandlerIfNeeded()
        return registerAll()
    }

    func setCancelEnabled(_ enabled: Bool) {
        guard enabled != cancelEnabled else { return }
        cancelEnabled = enabled
        // Nothing is registered until configure() runs; it picks up cancelEnabled then.
        guard !suspended, handlerRef != nil else { return }
        if enabled {
            let escape = ParsedShortcut(keyCode: UInt16(kVK_Escape), modifiers: [])
            _ = register(escape, id: .cancel)
        } else {
            unregister(.cancel)
        }
    }

    /// Temporarily disables all shortcuts, e.g. while the user records a new one.
    func suspend() {
        suspended = true
        for id in registered.keys {
            unregister(id)
        }
        holdActive = false
    }

    func resume() {
        guard suspended else { return }
        suspended = false
        registerAll()
    }

    /// Global key monitors only start delivering events after Accessibility is granted, so they
    /// are reinstalled whenever that permission changes.
    func restartMonitors() {
        removeMonitors()
        installMonitors()
    }

    // MARK: - Registration

    @discardableResult
    private func registerAll() -> String? {
        for id in registered.keys {
            unregister(id)
        }
        guard !suspended else { return nil }

        var warnings: [String] = []
        if let toggleShortcut {
            toggleNeedsMonitor = !register(toggleShortcut, id: .toggle)
            if toggleNeedsMonitor {
                warnings.append("\(ShortcutParser.display(toggleShortcutName)) is taken by another app, so it only works while Accessibility is allowed.")
            }
        }
        if let pasteLastShortcut, !register(pasteLastShortcut, id: .pasteLast) {
            warnings.append("The paste-last shortcut is already used by another app.")
        }
        if cancelEnabled {
            _ = register(ParsedShortcut(keyCode: UInt16(kVK_Escape), modifiers: []), id: .cancel)
        }
        restartMonitors()
        return warnings.isEmpty ? nil : warnings.joined(separator: " ")
    }

    private func register(_ shortcut: ParsedShortcut, id: HotKeyID) -> Bool {
        unregister(id)
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id.rawValue)
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            Log.hotkeys.error("Could not register hotkey \(String(describing: id), privacy: .public): \(status)")
            return false
        }
        registered[id] = ref
        return true
    }

    private func unregister(_ id: HotKeyID) {
        if let ref = registered.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
    }

    private static let signature: OSType = "FLTY".utf8.reduce(0) { ($0 << 8) + OSType($1) }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }
                let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
                let service = Unmanaged<HotKeyService>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated {
                    service.handleHotKey(id: hotKeyID.id, pressed: pressed)
                }
                return noErr
            },
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        if status != noErr {
            Log.hotkeys.error("Could not install hotkey handler: \(status)")
        }
    }

    private func handleHotKey(id: UInt32, pressed: Bool) {
        guard !suspended, let hotKey = HotKeyID(rawValue: id) else { return }
        switch hotKey {
        case .toggle:
            handleToggle(pressed: pressed)
        case .pasteLast:
            if pressed { onPasteLast?() }
        case .cancel:
            if pressed { onCancel?() }
        }
    }

    private func handleToggle(pressed: Bool) {
        if pressed {
            // Ignore auto-repeat while the shortcut is held.
            guard !toggleIsDown else { return }
            toggleIsDown = true
            onTogglePressed?()
        } else {
            guard toggleIsDown else { return }
            toggleIsDown = false
            onToggleReleased?()
        }
    }

    // MARK: - Event monitors (push-to-talk key and toggle fallback)

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handle(event)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handle(event)
            }
            return event
        }
    }

    private func removeMonitors() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
    }

    private func handle(_ event: NSEvent) {
        guard !suspended else { return }
        switch event.type {
        case .flagsChanged:
            handleFlagsChanged(event)
        case .keyDown:
            if holdActive {
                holdActive = false
                onHoldInterrupted?()
            }
            if toggleNeedsMonitor, !event.isARepeat, let toggleShortcut, ShortcutParser.matches(event, shortcut: toggleShortcut) {
                handleToggle(pressed: true)
            }
        case .keyUp:
            if toggleNeedsMonitor, let toggleShortcut, event.keyCode == toggleShortcut.keyCode {
                handleToggle(pressed: false)
            }
        default:
            break
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard holdKey != .off else { return }
        let isDown: Bool
        if holdKey == .fn {
            isDown = event.modifierFlags.contains(.function)
        } else {
            guard event.keyCode == holdKey.keyCode || holdActive else { return }
            isDown = event.modifierFlags.rawValue & holdKey.deviceFlagMask != 0
        }

        if isDown && !holdActive {
            // Only a bare hold key counts; Fn+Shift etc. are someone else's shortcut.
            let others: NSEvent.ModifierFlags = holdKey == .fn ? [.command, .control, .option, .shift] : []
            guard event.modifierFlags.intersection(others).isEmpty else { return }
            holdActive = true
            onHoldDown?()
        } else if !isDown && holdActive {
            holdActive = false
            onHoldUp?()
        }
    }
}

extension ShortcutParser {
    static func matches(_ event: NSEvent, shortcut: ParsedShortcut) -> Bool {
        guard event.keyCode == shortcut.keyCode else { return false }
        let relevant: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        return event.modifierFlags.intersection(relevant) == shortcut.modifiers
    }
}
