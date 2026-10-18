import AppKit
import SwiftUI
import XCTest

@testable import WallpaperMachine

/// The whole panel hosted the way the app hosts it, over a fixture controller, in a window that is
/// never shown: for the guide's layout tests, in any language, size and appearance. Nothing is
/// ordered front and `NSApp.appearance` is never touched; dark is the hosting view's own.
@MainActor
final class WelcomeRenderHarness {
  let panel: PanelFixture
  let hosting: NSHostingController<AnyView>
  let window: NSWindow
  var controller: PanelController { panel.controller }

  /// - Parameter content: what to host instead of the whole panel, given the same environment.
  init(
    panel: PanelFixture, language: String = "en", dark: Bool = false,
    content: ((PanelController) -> AnyView)? = nil
  ) throws {
    self.panel = panel
    let controller = panel.controller
    if language != "en" { try controller.appLanguage.set(language) }
    PanelLocale.shared.bind(to: controller.appLanguage)
    let root = content?(controller) ?? AnyView(PanelRootView())
    hosting = NSHostingController(
      rootView: AnyView(
        root
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .environment(controller)
          .environment(\.panelImages, controller.images)))
    hosting.sizingOptions = []
    hosting.sceneBridgingOptions = [.toolbars, .title]
    window = ControlPanelWindow.make(contentViewController: hosting, delegate: nil)
    hosting.view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
  }

  /// Lays the window out at `size` and lets SwiftUI settle.
  func layout(at size: NSSize) async throws {
    window.setContentSize(size)
    window.layoutIfNeeded()
    hosting.view.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(250))
    window.layoutIfNeeded()
    hosting.view.layoutSubtreeIfNeeded()
  }

  /// The widest split view in the window's content: wider than the window means the panel asks
  /// for more room than it was given.
  var widestSplitView: CGFloat {
    func widest(_ view: NSView) -> CGFloat {
      let own = (view as? NSSplitView)?.frame.width ?? 0
      return view.subviews.map(widest).reduce(own, max)
    }
    return widest(window.contentView!)
  }

  /// Everything the accessibility tree of the hosted content exposes.
  func accessibilityElements() -> [AnyObject] {
    var found = [AnyObject]()
    func visit(_ element: AnyObject, depth: Int) {
      guard depth < 40 else { return }
      found.append(element)
      let children = (element as? NSAccessibilityProtocol)?.accessibilityChildren() ?? []
      for child in children { visit(child as AnyObject, depth: depth + 1) }
    }
    visit(hosting.view, depth: 0)
    return found
  }

  /// The labelled buttons of the accessibility tree with their frames, in screen coordinates.
  func buttons() -> [(label: String, frame: NSRect, element: AnyObject)] {
    accessibilityElements().compactMap { element in
      guard let ax = element as? NSAccessibilityProtocol,
        ax.accessibilityRole() == .button, let label = ax.accessibilityLabel()
      else { return nil }
      return (label, ax.accessibilityFrame(), element)
    }
  }

  /// Every label and text value of the accessibility tree: what VoiceOver can reach.
  func accessibilityTexts() -> Set<String> {
    var texts = Set<String>()
    for element in accessibilityElements() {
      guard let ax = element as? NSAccessibilityProtocol else { continue }
      if let label = ax.accessibilityLabel(), !label.isEmpty { texts.insert(label) }
      if let value = ax.accessibilityValue() as? String, !value.isEmpty { texts.insert(value) }
      if let title = ax.accessibilityTitle(), !title.isEmpty { texts.insert(title) }
    }
    return texts
  }

  /// The editable text fields of the hosted content, top to bottom. Search fields are left out.
  func textFields() -> [NSTextField] {
    views(of: NSTextField.self).filter { $0.isEditable && !($0 is NSSearchField) }.sorted {
      $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY
    }
  }

  /// The search fields of the hosted content (the toolbar's live outside it).
  func searchFields() -> [NSSearchField] { views(of: NSSearchField.self) }

  /// The lists of the hosted content, which AppKit draws as table views: the sidebar's.
  func lists() -> [NSTableView] { views(of: NSTableView.self) }

  private func views<View: NSView>(of type: View.Type) -> [View] {
    func collect(_ view: NSView) -> [View] {
      ((view as? View).map { [$0] } ?? []) + view.subviews.flatMap(collect)
    }
    return collect(hosting.view)
  }

  /// Gives a list the keyboard and presses the down arrow in it.
  func pressDownArrow(in list: NSTableView) {
    window.makeFirstResponder(list)
    let down = String(UnicodeScalar(UInt16(NSDownArrowFunctionKey)).map(Character.init) ?? " ")
    guard
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: down,
        charactersIgnoringModifiers: down, isARepeat: false, keyCode: 125)
    else { return XCTFail("No key event") }
    list.keyDown(with: event)
  }

  /// Return in a field: what submits it.
  func pressReturn(in field: NSTextField) {
    if field.currentEditor() == nil { window.makeFirstResponder(field) }
    (field.currentEditor() as? NSTextView)?.insertNewline(nil)
  }

  /// Types into a field the way the keyboard does: it takes the keyboard and its field editor
  /// inserts the text, which tells the field's SwiftUI binding.
  func type(_ text: String, into field: NSTextField, file: StaticString = #filePath, line: UInt = #line) {
    window.makeFirstResponder(field)
    guard let editor = field.currentEditor() as? NSTextView else {
      return XCTFail("The field took no field editor", file: file, line: line)
    }
    editor.insertText(text, replacementRange: editor.selectedRange())
  }

  /// Whether `field` has the keyboard.
  func isEditing(_ field: NSTextField) -> Bool {
    guard let editor = field.currentEditor() else { return false }
    return window.firstResponder === editor
  }

  func close() {
    window.contentViewController = nil
    window.close()
    PanelLocale.shared.bind(to: .testHost)
  }
}

extension PanelFixture {
  /// Selects the fake SteamCMD, as Locate a copy does, and waits until it is the one in use. The
  /// look-up a started panel makes may still be running, and a selection made meanwhile is
  /// ignored, so it is made again whenever SteamCMD is idle without it.
  func selectFakeSteamCMD() async throws {
    let setup = workshop.steamCMDSetup
    try await waitUntil(timeout: 10) {
      if !setup.isBusy && setup.selectedRuntime?.executableURL != executable {
        setup.selectExisting(at: executable)
      }
      return !setup.isBusy && setup.selectedRuntime?.executableURL == executable
    }
  }
}

/// A sign-in job a test changes by hand, as the downloads pipeline would.
@MainActor
@Observable
final class WelcomeJobBox {
  var job: DownloadRow
  init(_ job: DownloadRow) { self.job = job }
}

/// The guide's host under the root's popover rule: a change of page closes the popover that was
/// open (`PanelRootView`), without the pages themselves.
struct WelcomePageChangeHost: View {
  @Environment(PanelController.self) private var controller

  var body: some View {
    Color.clear
      .onChange(of: controller.shell.selection) { controller.shell.closePopover() }
      .overlay { WelcomeOverlayHost() }
  }
}

/// The Steam page's prompt form on its own, over a job the test moves.
struct WelcomePromptHost: View {
  let box: WelcomeJobBox
  @FocusState private var focus: SteamField?

  var body: some View {
    WelcomePromptForm(job: box.job, guide: SteamGuardGuide.guide(for: box.job), focus: $focus)
      .padding(20)
  }
}

/// The Steam page's sign-in form on its own.
struct WelcomeSignInFormHost: View {
  @FocusState private var focus: SteamField?

  var body: some View {
    WelcomeSignInForm(jobFailure: nil, focus: $focus).padding(20)
  }
}

extension View {
  /// What a piece of the guide finds around it in the panel: the guide's model and the theme.
  func welcomeTestEnvironment(_ controller: PanelController) -> some View {
    environment(controller.welcome)
      .panelTheme(theme: controller.theme, locale: PanelLocale.shared)
  }
}
