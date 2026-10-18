import AppKit
import Carbon
import Observation

/// Records a global keyboard shortcut for one row of Settings › Keyboard shortcuts.
///
/// While a row records, every key press goes to the recorder instead of the app: a local key
/// monitor sees what the system would otherwise handle (⌘Q, ⌘W, Tab) and swallows it, and the
/// recorder takes the press of a shortcut that is already registered as the combination it names,
/// so recording one never runs its action. Escape without ⌘, ⌃ or ⌥ cancels. The press is handed
/// to `PanelController.setHotKey` as the key's position and modifiers, which owns the rules about
/// what a shortcut may be.
///
/// A recording ends with the first press, with Cancel, with a click anywhere else, when the window
/// loses focus, and when the page leaves.
@MainActor
@Observable
final class ShortcutsRecorderModel {
  /// The row that is recording.
  private(set) var recording: HotKeyAction?
  /// The row whose first button should take focus: the view moves it there and then calls
  /// `consumeFocus`.
  private(set) var focus: HotKeyAction?

  @ObservationIgnored weak var controller: PanelController?
  @ObservationIgnored private let installsMonitors: Bool
  @ObservationIgnored private var session: ShortcutsRecorderSession?

  /// - Parameter installsMonitors: Whether recording listens to the keyboard. A test turns it off
  ///   and feeds `handle(keyCode:modifierFlags:)` itself.
  init(controller: PanelController? = nil, installsMonitors: Bool = true) {
    self.controller = controller
    self.installsMonitors = installsMonitors
  }

  func consumeFocus() { focus = nil }

  /// Starts recording for `action`. A row that was recording gives way.
  func begin(_ action: HotKeyAction) {
    end()
    recording = action
    focus = action
    guard installsMonitors, let controller else { return }
    let session = ShortcutsRecorderSession(
      bindings: { controller.hotKeys.bindings },
      onKey: { [weak self] keyCode, flags in self?.handle(keyCode: keyCode, modifierFlags: flags) ?? false },
      onRegisteredPress: { [weak self] action in self?.handleRegisteredPress(of: action) },
      onEnd: { [weak self] in self?.end() })
    session.start()
    self.session = session
  }

  /// Stops recording and changes nothing.
  func cancel() {
    if let recording { focus = recording }
    end()
  }

  /// Ends the recording without moving focus: the page left, or the window lost focus.
  func end() {
    recording = nil
    session?.stop()
    session = nil
  }

  /// Reads a key-down while a row records. Returns whether the recorder used the press, which the
  /// monitor then swallows: a modifier on its own is not used (the recorder keeps waiting).
  @discardableResult
  func handle(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Bool {
    guard let action = recording, let controller else { return false }
    switch HotKeyRecording.press(keyCode: keyCode, modifierFlags: modifierFlags) {
    case .ignored:
      return false
    case .cancelled:
      cancel()
      return true
    case .recorded:
      focus = action
      end()
      // A refusal (a key that cannot be a shortcut, a combination already used) reaches the banner.
      controller.launch(PanelActionCoordinator.key("hotkeySet", id: action.rawValue)) {
        try await controller.setHotKey(action, keyCode: keyCode, modifierFlags: modifierFlags)
      }
      return true
    }
  }

  /// The press of a shortcut that is registered with the system arrived while recording: the
  /// system takes such a press before the app sees it as a key, so it is read as the combination
  /// that shortcut stands for, and its own action does not run.
  func handleRegisteredPress(of registered: HotKeyAction) {
    guard let binding = controller?.hotKeys.bindings[registered] else { return }
    handle(keyCode: UInt16(binding.keyCode), modifierFlags: Self.modifierFlags(carbon: binding.modifiers))
  }

  /// The modifier flags a Carbon modifier mask stands for.
  static func modifierFlags(carbon: UInt32) -> NSEvent.ModifierFlags {
    var flags: NSEvent.ModifierFlags = []
    if carbon & UInt32(cmdKey) != 0 { flags.insert(.command) }
    if carbon & UInt32(optionKey) != 0 { flags.insert(.option) }
    if carbon & UInt32(controlKey) != 0 { flags.insert(.control) }
    if carbon & UInt32(shiftKey) != 0 { flags.insert(.shift) }
    return flags
  }
}

/// The system hooks of one recording: a local key monitor, a mouse monitor, and a handler that
/// takes the press of an already registered shortcut before the app's own handler runs. All are
/// installed when the recording starts and removed when it ends, so nothing listens otherwise.
@MainActor
final class ShortcutsRecorderSession {
  private let bindings: () -> [HotKeyAction: HotKey]
  private let onKey: (UInt16, NSEvent.ModifierFlags) -> Bool
  private let onRegisteredPress: (HotKeyAction) -> Void
  private let onEnd: () -> Void
  private var monitors: [Any] = []
  private var observers: [NSObjectProtocol] = []
  private var handler: EventHandlerRef?
  /// Marks the app's own hot keys in the events the system sends back ("WMKY").
  private static let signature: OSType = 0x574D_4B59

  init(
    bindings: @escaping () -> [HotKeyAction: HotKey], onKey: @escaping (UInt16, NSEvent.ModifierFlags) -> Bool,
    onRegisteredPress: @escaping (HotKeyAction) -> Void, onEnd: @escaping () -> Void
  ) {
    self.bindings = bindings
    self.onKey = onKey
    self.onRegisteredPress = onRegisteredPress
    self.onEnd = onEnd
  }

  func start() {
    if let monitor = NSEvent.addLocalMonitorForEvents(
      matching: .keyDown,
      handler: { [weak self] event in
        guard let self else { return event }
        // A key held down repeats; only the first press is the shortcut.
        if event.isARepeat { return nil }
        return MainActor.assumeIsolated {
          self.onKey(event.keyCode, event.modifierFlags.intersection([.command, .option, .control, .shift]))
            ? nil : event
        }
      })
    {
      monitors.append(monitor)
    }
    // A click on anything but the row's own buttons ends the recording; the click still goes through.
    if let monitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown],
      handler: { [weak self] event in
        if let self { MainActor.assumeIsolated { self.endAfterClick() } }
        return event
      })
    {
      monitors.append(monitor)
    }
    let center = NotificationCenter.default
    observers.append(
      center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) {
        [weak self] _ in MainActor.assumeIsolated { self?.onEnd() }
      })
    observers.append(
      center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) {
        [weak self] _ in MainActor.assumeIsolated { self?.onEnd() }
      })
    installRegisteredPressHandler()
  }

  func stop() {
    for monitor in monitors { NSEvent.removeMonitor(monitor) }
    monitors = []
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
    if let handler { RemoveEventHandler(handler) }
    handler = nil
  }

  /// Ends on the next turn, so a click on the row's own Cancel button still reaches it.
  private func endAfterClick() {
    Task { @MainActor [weak self] in self?.onEnd() }
  }

  /// A handler on the application's event target installed after `GlobalHotKeys`' own is asked
  /// first, so while recording it takes a registered shortcut's press and keeps it from running.
  private func installRegisteredPressHandler() {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let status = InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, userData -> OSStatus in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }
        var pressed = EventHotKeyID()
        let status = GetEventParameter(
          event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
          MemoryLayout<EventHotKeyID>.size, nil, &pressed)
        guard status == noErr, pressed.signature == ShortcutsRecorderSession.signature,
          let action = HotKeyAction.allCases.first(where: { $0.identifier == pressed.id })
        else { return OSStatus(eventNotHandledErr) }
        let session = Unmanaged<ShortcutsRecorderSession>.fromOpaque(userData).takeUnretainedValue()
        MainActor.assumeIsolated { session.onRegisteredPress(action) }
        return noErr
      },
      1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    if status != noErr { handler = nil }
  }
}
