import AppKit
import Carbon
import Foundation

/// Registers the user's keyboard shortcuts with the system, so they work whichever app is in
/// front. Carbon's hot keys need no Accessibility permission and deliver only the registered
/// combinations; no other keystroke reaches the app.
@MainActor
final class GlobalHotKeys {
    var onPress: (@MainActor (HotKeyAction) -> Void)?

    private let preferences: HotKeyPreferences
    private var handler: EventHandlerRef?
    private var registered: [HotKeyAction: EventHotKeyRef] = [:]
    private var observer: NSObjectProtocol?
    /// Marks the app's own hot keys in the events the system sends back ("WMKY").
    private static let signature: OSType = 0x574D_4B59

    init(preferences: HotKeyPreferences) {
        self.preferences = preferences
    }

    func start() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var pressed = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &pressed)
                guard status == noErr else { return status }
                let hotKeys = Unmanaged<GlobalHotKeys>.fromOpaque(userData).takeUnretainedValue()
                // Carbon delivers hot keys on the main thread's event loop.
                return MainActor.assumeIsolated { hotKeys.fire(pressed) }
            },
            1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else {
            AppLog.error("keyboard shortcuts could not listen for presses (\(status))")
            return
        }
        observer = NotificationCenter.default.addObserver(
            forName: HotKeyPreferences.didChangeNotification, object: preferences, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        sync()
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        for ref in registered.values { UnregisterEventHotKey(ref) }
        registered.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    /// Registers exactly the saved shortcuts, recording any the system refuses.
    private func sync() {
        for action in HotKeyAction.allCases {
            let wanted = preferences.bindings[action]
            if let ref = registered.removeValue(forKey: action) { UnregisterEventHotKey(ref) }
            guard let wanted else {
                preferences.recordFailure(nil, for: action)
                continue
            }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                wanted.keyCode, wanted.modifiers, EventHotKeyID(signature: Self.signature, id: action.identifier),
                GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                registered[action] = ref
                preferences.recordFailure(nil, for: action)
            } else {
                AppLog.warn("keyboard shortcut \(wanted.label) for \(action.rawValue) was refused (\(status))")
                preferences.recordFailure(
                    status == OSStatus(eventHotKeyExistsErr)
                        ? String(localized: "Another app already uses this shortcut. Record a different one.")
                        : String(localized: "macOS did not accept this shortcut (error \(Int(status))). Record a different one."),
                    for: action)
            }
        }
    }

    private func fire(_ pressed: EventHotKeyID) -> OSStatus {
        guard pressed.signature == Self.signature,
              let action = HotKeyAction.allCases.first(where: { $0.identifier == pressed.id })
        else { return OSStatus(eventNotHandledErr) }
        onPress?(action)
        return noErr
    }

    /// The shortcut a key press in the panel names: `keyCode` is `NSEvent.keyCode`, the key's
    /// position as Carbon's virtual key codes name it, and only the four modifier flags count. A key
    /// needs ⌘, ⌥ or ⌃ with it, so a shortcut never takes a key away from typing; only F13 to F20,
    /// which type nothing, may stand alone.
    static func hotKey(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) throws -> HotKey {
        guard let label = keyLabels[Int(keyCode)] else {
            throw AutomationError(message: String(localized: "This key can’t be used for a shortcut. Try a letter, a number or a function key."))
        }
        let command = modifierFlags.contains(.command), option = modifierFlags.contains(.option)
        let control = modifierFlags.contains(.control), shift = modifierFlags.contains(.shift)
        guard command || option || control || standaloneKeys.contains(Int(keyCode)) else {
            throw AutomationError(message: String(localized: "Hold ⌘, ⌥ or ⌃ with the key, so the shortcut doesn’t take it away from typing."))
        }
        var modifiers = 0
        var prefix = ""
        if control { modifiers |= controlKey; prefix += "⌃" }
        if option { modifiers |= optionKey; prefix += "⌥" }
        if shift { modifiers |= shiftKey; prefix += "⇧" }
        if command { modifiers |= cmdKey; prefix += "⌘" }
        return HotKey(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers), label: prefix + label)
    }

    /// The keys that type nothing, which a shortcut may use without a modifier.
    private static let standaloneKeys: Set<Int> = [
        kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    /// The keys a shortcut can use, by Carbon virtual key code, and how its label writes them.
    /// Escape, Tab, Delete and the numeric keypad are left out, so ⌘Esc and the like are refused.
    private static let keyLabels: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
        kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
        kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
        kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
        kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",",
        kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/", kVK_ANSI_Grave: "`",
        kVK_Space: "Space", kVK_Return: "↩",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]
}
