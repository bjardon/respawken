import AppKit
import Carbon

/// A global key combo. `modifiers` is the Cocoa mask (⌘⌥⌃⇧ only).
struct KeyCombo: Codable, Equatable, Sendable {
    var keyCode: UInt16
    var modifiers: UInt

    static let defaultPanelToggle = KeyCombo(keyCode: 32, modifiers: [.control, .option]) // ⌃⌥U

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection([.command, .option, .control, .shift]).rawValue
    }

    var carbonModifiers: UInt32 {
        var value: UInt32 = 0
        if flags.contains(.command) { value |= UInt32(cmdKey) }
        if flags.contains(.option) { value |= UInt32(optionKey) }
        if flags.contains(.shift) { value |= UInt32(shiftKey) }
        if flags.contains(.control) { value |= UInt32(controlKey) }
        return value
    }

    var display: String {
        var parts = ""
        if flags.contains(.control) { parts += "⌃" }
        if flags.contains(.option) { parts += "⌥" }
        if flags.contains(.shift) { parts += "⇧" }
        if flags.contains(.command) { parts += "⌘" }
        return parts + Self.keyName(keyCode)
    }

    static func isValid(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        if isFunctionKey(keyCode) { return true }
        return modifiers.contains(.command) || modifiers.contains(.option) || modifiers.contains(.control)
    }

    private static func isFunctionKey(_ keyCode: UInt16) -> Bool {
        [
            122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
            105, 107, 113, 106, 64, 79, 80,
        ].contains(keyCode)
    }

    static func keyName(_ keyCode: UInt16) -> String {
        let special: [UInt16: String] = [
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
            117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
            105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19",
            114: "Help", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        ]
        if let name = special[keyCode] { return name }

        var source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        var dataPtr = source.flatMap { TISGetInputSourceProperty($0, kTISPropertyUnicodeKeyLayoutData) }
        if dataPtr == nil {
            source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
            dataPtr = source.flatMap { TISGetInputSourceProperty($0, kTISPropertyUnicodeKeyLayoutData) }
        }
        guard let dataPtr else { return "Key \(keyCode)" }
        let data = Unmanaged<CFData>.fromOpaque(dataPtr).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return "Key \(keyCode)"
            }
            var dead: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(
                layout,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &dead,
                4,
                &length,
                &chars
            )
            guard status == noErr, length > 0 else { return "Key \(keyCode)" }
            return String(utf16CodeUnits: chars, count: length).uppercased()
        }
    }
}

/// Carbon global hotkey for the panel. No Accessibility permission needed.
@MainActor
final class PanelHotKey {
    static let shared = PanelHotKey()

    private var combo: KeyCombo?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var paused = false

    private let hotKeyID = EventHotKeyID(signature: 0x7273_776B, id: 1) // 'rswk'

    @discardableResult
    func install(_ combo: KeyCombo?) -> Bool {
        self.combo = combo
        guard !paused else { return true }
        return reregister()
    }

    func pause() {
        paused = true
        unregister()
    }

    func resume() {
        paused = false
        _ = reregister()
    }

    private func reregister() -> Bool {
        unregister()
        installHandlerIfNeeded()
        guard let combo else { return true }

        var ref: EventHotKeyRef?
        let err = RegisterEventHotKey(
            UInt32(combo.keyCode),
            combo.carbonModifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        guard err == noErr, let ref else { return false }
        hotKeyRef = ref
        return true
    }

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetEventDispatcherTarget(),
            panelHotKeyHandler,
            1,
            &spec,
            nil,
            &handlerRef
        )
    }
}

private func panelHotKeyHandler(
    _: EventHandlerCallRef?,
    _: EventRef?,
    _: UnsafeMutableRawPointer?
) -> OSStatus {
    DispatchQueue.main.async { PanelToggle.toggle() }
    return noErr
}

/// SwiftUI MenuBarExtra has no public show/hide API; click the status item instead.
@MainActor
enum PanelToggle {
    static func toggle() {
        guard let item = statusItem() else { return }
        if !isPanelVisible() {
            NSApp.activate(ignoringOtherApps: true)
        }
        if toggleExpandedSession(item) { return }
        item.button?.performClick(nil)
    }

    /// Notification clicks should open the panel, not toggle it shut.
    static func show() {
        guard let item = statusItem() else { return }
        if isPanelVisible() { return }
        NSApp.activate(ignoringOtherApps: true)
        if toggleExpandedSession(item) { return }
        item.button?.performClick(nil)
    }

    private static func isPanelVisible() -> Bool {
        NSApp.windows.contains {
            $0.className.contains("MenuBarExtraWindow")
                && $0.isVisible
                && $0.occlusionState.contains(.visible)
        }
    }

    private static func statusItem() -> NSStatusItem? {
        for window in NSApp.windows where window.className.contains("NSStatusBarWindow") {
            if let item = statusItem(from: window), !item.className.contains("Replicant") {
                return item
            }
        }
        return nil
    }

    private static func statusItem(from window: NSWindow) -> NSStatusItem? {
        window.value(forKey: "statusItem") as? NSStatusItem
            ?? Mirror(reflecting: window).descendant("statusItem") as? NSStatusItem
    }

    /// macOS 27+ window-style MenuBarExtra ignores `performClick`; talk to the session SPI.
    private static func toggleExpandedSession(_ item: NSStatusItem) -> Bool {
        let begin = NSSelectorFromString("_beginExpandedInterfaceSession:")
        let sessionSel = NSSelectorFromString("expandedInterfaceSession")
        let delegateSel = NSSelectorFromString("expandedInterfaceDelegate")
        guard item.responds(to: begin),
              item.responds(to: delegateSel),
              item.perform(delegateSel) != nil
        else { return false }

        if let session = item.perform(sessionSel)?.takeUnretainedValue() as? NSObject,
           session.responds(to: NSSelectorFromString("cancel")) {
            session.perform(NSSelectorFromString("cancel"))
            return true
        }
        guard let implementation = item.method(for: begin) else { return false }
        typealias Begin = @convention(c) (NSStatusItem, Selector, TimeInterval) -> Void
        unsafeBitCast(implementation, to: Begin.self)(item, begin, .greatestFiniteMagnitude)
        return true
    }
}
