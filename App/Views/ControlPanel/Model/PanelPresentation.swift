import AppKit
import Observation

/// Whether the panel can be seen, and whether it has the keyboard.
///
/// Work whose result nobody would see is gated on `isVisible`: the per-display options fetch, the
/// energy sampler, the support prompt's offer, and anything that rebuilds a derived cache. A
/// window that is closed releases the whole controller; a hidden one (ordered out, minimized, or
/// entirely covered) only stops doing model work, and resumes the moment it is shown.
///
/// A real window drives it through `attach(to:)` and the notifications below. Tests never attach
/// one: they call `show()`, `hide()` and `becomeKey()`, which is also how a panel is injected as
/// visible without ordering a window front.
@MainActor
@Observable
final class PanelPresentation {
  /// The window is on screen: visible, not minimized and not occluded.
  private(set) var isVisible: Bool
  /// The window is the key window.
  private(set) var isKey: Bool
  /// The window sheets and pickers attach to; nil without one.
  private(set) weak var window: NSWindow?

  /// Runs each time the window becomes key (including `becomeKey()`): scene assets and a Login
  /// Items approval are read again because they change while the user is elsewhere.
  @ObservationIgnored var onBecameKey: (@MainActor () -> Void)?
  /// Runs when the window closes or the view loses it for good.
  @ObservationIgnored var onClose: (@MainActor () -> Void)?

  @ObservationIgnored private var observers: [NSObjectProtocol] = []

  init(isVisible: Bool = false, isKey: Bool = false) {
    self.isVisible = isVisible
    self.isKey = isKey
  }

  deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

  // MARK: Injection (tests, and previews without a window)

  func show() { isVisible = true }
  func hide() { isVisible = false }

  func becomeKey() {
    isKey = true
    onBecameKey?()
  }

  func resignKey() { isKey = false }

  // MARK: A real window

  /// Follows `window`. Attaching nil, or another window, ends the previous one's tracking; losing
  /// a window that was attached means the view was dismantled, which `onClose` hears.
  func attach(to window: NSWindow?) {
    guard window !== self.window else { return }
    let hadWindow = self.window != nil
    removeObservers()
    self.window = window
    guard let window else {
      isVisible = false
      isKey = false
      if hadWindow { onClose?() }
      return
    }
    for name in [
      NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
      NSWindow.didDeminiaturizeNotification, NSWindow.didEnterFullScreenNotification,
      NSWindow.didExitFullScreenNotification, NSWindow.didResignKeyNotification,
    ] {
      observe(name, window) { $0.windowChanged() }
    }
    observe(NSWindow.didBecomeKeyNotification, window) {
      $0.windowChanged()
      $0.onBecameKey?()
    }
    observe(NSWindow.willCloseNotification, window) { $0.windowClosed() }
    windowChanged()
  }

  /// AppKit posts window notifications on the main thread, so the handler runs before the post
  /// returns; one that arrives anywhere else hops.
  private func observe(
    _ name: Notification.Name, _ window: NSWindow,
    _ handler: @escaping @MainActor (PanelPresentation) -> Void
  ) {
    observers.append(
      NotificationCenter.default.addObserver(forName: name, object: window, queue: nil) {
        [weak self] _ in
        if Thread.isMainThread {
          MainActor.assumeIsolated { if let self { handler(self) } }
        } else {
          Task { @MainActor [weak self] in if let self { handler(self) } }
        }
      })
  }

  private func windowChanged() {
    guard let window else { return }
    isVisible = window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    isKey = window.isKeyWindow
  }

  private func windowClosed() {
    isVisible = false
    isKey = false
    removeObservers()
    window = nil
    onClose?()
  }

  private func removeObservers() {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers.removeAll()
  }
}
