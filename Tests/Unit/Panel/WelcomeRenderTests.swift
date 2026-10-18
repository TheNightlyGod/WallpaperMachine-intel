import AppKit
import SwiftUI
import XCTest

@testable import WallpaperMachine

/// The first-run guide and the support prompt drawn in a window that is never shown: each page lays
/// out in the smallest window and the default one, light and dark, in every shipped language,
/// without asking for more room and without an AppKit exception, and the host follows the guide's
/// flag. What an offscreen window cannot show (focus rings, hover, VoiceOver, the real dimming of
/// the title bar) is listed in the guide's contract.
@MainActor
final class WelcomeRenderTests: PanelTestCase {
  override func tearDown() async throws {
    // Each harness bound the shared panel language to its own store.
    PanelLocale.shared.bind(to: .testHost)
    try await super.tearDown()
  }

  private let sizes = [NSSize(width: 760, height: 560), NSSize(width: 1240, height: 800)]

  private func assertFits(
    _ harness: WelcomeRenderHarness, at size: NSSize, _ context: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let measured = harness.hosting.sizeThatFits(in: size)
    XCTAssertEqual(
      measured.width, size.width, accuracy: 1, "\(context): the root must accept the window width",
      file: file, line: line)
    XCTAssertLessThanOrEqual(
      measured.height, size.height + 1, "\(context): the guide must not force a taller window",
      file: file, line: line)
    XCTAssertLessThanOrEqual(
      harness.widestSplitView, size.width + 1, "\(context): the panel must fit the window",
      file: file, line: line)
    XCTAssertFalse(harness.window.isVisible, "\(context): layout must stay offscreen", file: file, line: line)
  }

  /// Every page, in the two sizes that matter, in every language: no page asks for a larger window
  /// (a page that is taller than its card scrolls), and the guide the host shows is the one asked for.
  func testEveryPageFitsTheSmallestAndTheDefaultWindowInEveryLanguage() async throws {
    try await withPanel(welcomeSeen: false) { panel in
      for language in AppLanguage.supported.map(\.tag) {
        let harness = try WelcomeRenderHarness(panel: panel, language: language)
        for size in sizes {
          try await harness.layout(at: size)
          XCTAssertTrue(panel.controller.welcome.isOpen, "The host opens the guide by itself")
          for step in WelcomeStep.allCases {
            panel.controller.welcome.go(to: step)
            try await harness.layout(at: size)
            XCTAssertEqual(panel.controller.welcome.step, step)
            assertFits(harness, at: size, "\(language) \(step) at \(Int(size.width))")
          }
          panel.controller.welcome.go(to: .language)
        }
        harness.close()
      }
    }
  }

  func testEveryPageFitsInDarkAppearanceToo() async throws {
    try await withPanel(welcomeSeen: false) { panel in
      let harness = try WelcomeRenderHarness(panel: panel, dark: true)
      for size in sizes {
        for step in WelcomeStep.allCases {
          panel.controller.welcome.go(to: step)
          try await harness.layout(at: size)
          assertFits(harness, at: size, "dark \(step) at \(Int(size.width))")
        }
      }
      harness.close()
    }
  }

  /// With drafts, a failure on the page and an unfinished Steam sign-in the pages still fit.
  func testPagesWithDraftsAndMessagesStillFit() async throws {
    try await withPanel(welcomeSeen: false) { panel in
      let harness = try WelcomeRenderHarness(panel: panel)
      let model = panel.controller.welcome
      model.choosePreset(.low)
      model.setFrameRatePosition(24)
      model.preferences.set(.batteryMode(.pause))
      model.go(to: .preferences)
      await model.setLockScreen(true)  // refused: a message on the page
      XCTAssertNotNil(model.error)
      for size in sizes {
        for step in [WelcomeStep.performance, .preferences, .start] {
          model.go(to: step)
          if step == .preferences { await model.setLockScreen(true) }
          try await harness.layout(at: size)
          assertFits(harness, at: size, "drafts \(step) at \(Int(size.width))")
        }
      }
      harness.close()
    }
  }

  // MARK: The host

  /// The host opens the guide while the first-run flag is unset or Settings asked for it, starts it
  /// over each time, and closes it for good with the flag.
  func testTheHostFollowsTheFlagAndTheRequest() async throws {
    try await withPanel(welcomeSeen: true) { panel in
      let harness = try WelcomeRenderHarness(panel: panel)
      let controller = panel.controller
      try await harness.layout(at: sizes[1])
      XCTAssertFalse(controller.welcome.isOpen, "A returning user sees no guide")

      controller.shell.isWelcomeRequested = true
      try await harness.layout(at: sizes[1])
      XCTAssertTrue(controller.welcome.isOpen, "Show again opens it")
      XCTAssertEqual(controller.welcome.step, .language)

      controller.welcome.go(to: .start)
      controller.welcome.finish()
      try await harness.layout(at: sizes[1])
      XCTAssertFalse(controller.welcome.isOpen)
      XCTAssertFalse(controller.shell.isWelcomeOpen)
      XCTAssertTrue(controller.welcomeSeen)

      controller.shell.isWelcomeRequested = true
      try await harness.layout(at: sizes[1])
      XCTAssertEqual(controller.welcome.step, .language, "Each replay starts over")
      harness.close()
    }
  }

  func testAFirstRunGuideCoversTheWindowUntilItEnds() async throws {
    try await withPanel(welcomeSeen: false) { panel in
      let harness = try WelcomeRenderHarness(panel: panel)
      try await harness.layout(at: sizes[1])
      XCTAssertTrue(panel.controller.shell.isWelcomeOpen)
      XCTAssertTrue(panel.controller.welcome.isOpen)
      panel.controller.welcome.finish()
      try await harness.layout(at: sizes[1])
      XCTAssertFalse(panel.controller.shell.isWelcomeOpen)
      XCTAssertFalse(panel.controller.welcome.isOpen)
      harness.close()
    }
  }

  // MARK: The window under the guide

  /// While the guide is up nothing behind it looks usable or can be reached: the toolbar with the
  /// tabs is hidden (not emptied, so its items are never inserted again), the title bar names
  /// nothing, and the panel is out of the accessibility tree. Finishing brings all of it back.
  func testTheGuideHidesTheToolbarAndLocksThePanelBehindItUntilItEnds() async throws {
    try await withPanel(welcomeSeen: false) { panel in
      let harness = try WelcomeRenderHarness(panel: panel)
      try await harness.layout(at: sizes[1])
      let window = harness.window
      let library = panel.controller.library
      let toolbar = try XCTUnwrap(window.toolbar, "The panel's toolbar is bridged into the window")
      let items = toolbar.items.map(\.itemIdentifier)
      XCTAssertFalse(toolbar.isVisible, "No toolbar control shows above the scrim")
      XCTAssertNotEqual(window.title, "All wallpapers", "The title bar does not name the page behind")
      let content = AccessibilityElement(object: try XCTUnwrap(window.contentView))
      XCTAssertNil(content.first(identifier: "scope-all"), "The library's views are hidden from VoiceOver")

      panel.controller.welcome.finish()
      try await harness.layout(at: sizes[1])
      XCTAssertTrue(window.toolbar === toolbar, "The same toolbar")
      XCTAssertTrue(toolbar.isVisible, "The toolbar shows again")
      XCTAssertEqual(toolbar.items.map(\.itemIdentifier), items, "with the same items, never re-inserted")
      XCTAssertEqual(window.title, "All wallpapers")
      XCTAssertNotNil(content.first(identifier: "scope-all"), "The library's views are back")
      library.show(.favorites)
      try await harness.layout(at: sizes[1])
      XCTAssertEqual(window.title, "Favorites")

      // Moving between two pages that share the search bar still works (PageSearchBar).
      panel.navigation.selection = .pixiv
      try await harness.layout(at: sizes[1])
      panel.navigation.selection = .wallpaper
      try await harness.layout(at: sizes[1])
      XCTAssertEqual(window.title, "Favorites")
      harness.close()
    }
  }

  /// A guide replayed from Settings leaves the Settings behind it alone: the search field is
  /// disabled and the section list ignores the arrow keys, until the guide ends.
  func testTheSettingsBehindAReplayedGuideCanBeNeitherSearchedNorChosen() async throws {
    try await withPanel(welcomeSeen: true) { panel in
      panel.navigation.selection = .settings
      let settings = panel.controller.settings
      let harness = try WelcomeRenderHarness(panel: panel)
      try await harness.layout(at: sizes[1])
      panel.controller.shell.isWelcomeRequested = true
      try await harness.layout(at: sizes[1])
      let search = try XCTUnwrap(harness.searchFields().first)
      XCTAssertFalse(search.isEnabled, "The Settings search waits behind the guide")
      let section = settings.selectedSection
      let list = try XCTUnwrap(harness.lists().first)
      harness.pressDownArrow(in: list)
      try await harness.layout(at: sizes[1])
      XCTAssertEqual(settings.selectedSection, section, "and no section is chosen")

      panel.controller.welcome.finish()
      try await harness.layout(at: sizes[1])
      XCTAssertTrue(try XCTUnwrap(harness.searchFields().first).isEnabled)
      harness.pressDownArrow(in: try XCTUnwrap(harness.lists().first))
      try await harness.layout(at: sizes[1])
      XCTAssertNotEqual(settings.selectedSection, section, "The sections work again")
      harness.close()
    }
  }

  /// Import wallpapers from a guide replayed on Settings shows Installed with the Import popover
  /// open, and the window knows it is open: the popover opens after the page change has closed the
  /// popovers of the page that was left, as the root does.
  func testImportFromAReplayedGuideOpensTheImportPopoverAfterThePageChange() async throws {
    try await withPanel(welcomeSeen: true) { panel in
      let controller = panel.controller
      panel.navigation.selection = .settings
      // The root's rule, without the library page itself (whose popover a test never presents):
      // a change of page closes the popover that was open.
      let harness = try WelcomeRenderHarness(panel: panel) { controller in
        AnyView(WelcomePageChangeHost().panelTheme(theme: controller.theme, locale: PanelLocale.shared))
      }
      try await harness.layout(at: sizes[1])
      controller.shell.isWelcomeRequested = true
      try await harness.layout(at: sizes[1])
      XCTAssertTrue(controller.welcome.isOpen)

      controller.welcome.go(to: .start)
      await controller.welcome.importWallpapers().value
      try await harness.layout(at: sizes[1])
      XCTAssertFalse(controller.shell.isWelcomeOpen)
      XCTAssertEqual(panel.navigation.selection, .wallpaper)
      XCTAssertEqual(controller.library.importAnchor, .page, "The Import button's popover is open")
      XCTAssertTrue(controller.shell.isPopoverOpen, "and the window knows a popover is open")
      harness.close()
    }
  }

  // MARK: Typing on the Steam page

  /// A Steam Guard code being typed survives every job update that does not change what Steam asks,
  /// with the cursor where it was and the field still focused; only a different question brings a
  /// new, empty field.
  func testATypedSteamGuardCodeSurvivesProgressUpdates() async throws {
    try await withPanel(welcomeSeen: false) { panel in
      let box = WelcomeJobBox(
        DownloadRow(
          id: WorkshopStore.signInRequestID, title: "Steam sign-in", status: "Waiting for the code",
          account: "localtest", isPending: true, isSignInOnly: true, isAuthenticating: true,
          prompt: .guardCode, challenge: .emailCode))
      let harness = try WelcomeRenderHarness(panel: panel) { controller in
        AnyView(WelcomePromptHost(box: box).welcomeTestEnvironment(controller))
      }
      try await harness.layout(at: sizes[0])
      let field = try XCTUnwrap(harness.textFields().first)
      harness.type("R4K", into: field)
      XCTAssertEqual(field.stringValue, "R4K")

      for status in ["Still waiting for the code", "Waiting for Steam Guard"] {
        box.job = DownloadRow(
          id: WorkshopStore.signInRequestID, title: "Steam sign-in", status: status,
          account: "localtest", progress: 0.2, isPending: true, isSignInOnly: true,
          isAuthenticating: true, prompt: .guardCode, challenge: .emailCode)
        try await harness.layout(at: sizes[0])
        let kept = try XCTUnwrap(harness.textFields().first)
        XCTAssertEqual(kept.stringValue, "R4K", "\(status): the typed code stays")
        XCTAssertTrue(harness.isEditing(kept), "and the field keeps the keyboard")
        XCTAssertEqual(kept.currentEditor()?.selectedRange, NSRange(location: 3, length: 0))
      }

      box.job = DownloadRow(
        id: WorkshopStore.signInRequestID, title: "Steam sign-in", account: "localtest",
        isPending: true, isSignInOnly: true, isAuthenticating: true, prompt: .password)
      try await harness.layout(at: sizes[0])
      let replaced = try XCTUnwrap(harness.textFields().first)
      XCTAssertTrue(replaced is NSSecureTextField, "Steam now asks for the password")
      XCTAssertEqual(replaced.stringValue, "", "A different question starts empty")
      harness.close()
    }
  }

  /// Show and Hide password keep what was typed, through updates of the page; Sign in empties the
  /// field before anything is sent, and the password reaches Steam's prompt once.
  func testShowingAndHidingThePasswordKeepsItAndSigningInEmptiesTheField() async throws {
    try await withPanel(welcomeSeen: false) { panel in
      let model = panel.controller.welcome
      try await panel.selectFakeSteamCMD()
      // The form on its own; the open guide around it is what answers Steam's password prompt.
      model.open()
      defer { model.close() }
      let harness = try WelcomeRenderHarness(panel: panel) { controller in
        AnyView(WelcomeSignInFormHost().welcomeTestEnvironment(controller))
      }
      try await harness.layout(at: sizes[1])
      model.signInAccount = "localtest"
      try await harness.layout(at: sizes[1])
      let secure = try XCTUnwrap(harness.textFields().compactMap { $0 as? NSSecureTextField }.first)
      harness.type("hunter2-secret", into: secure)

      model.revealsPassword = true  // what the eye button does
      model.remembersSession = false  // and the page redraws in between
      try await harness.layout(at: sizes[1])
      XCTAssertTrue(
        harness.textFields().allSatisfy { !($0 is NSSecureTextField) }, "The password shows as text")
      XCTAssertTrue(
        harness.textFields().contains { $0.stringValue == "hunter2-secret" }, "with what was typed")

      model.revealsPassword = false
      model.remembersSession = true
      try await harness.layout(at: sizes[1])
      let hidden = try XCTUnwrap(harness.textFields().compactMap { $0 as? NSSecureTextField }.first)
      XCTAssertEqual(hidden.stringValue, "hunter2-secret", "Hidden again, still typed")

      model.revealsPassword = true
      try await harness.layout(at: sizes[1])
      let revealed = try XCTUnwrap(harness.textFields().last)
      harness.pressReturn(in: revealed)
      try await harness.layout(at: sizes[1])
      XCTAssertFalse(model.revealsPassword, "Sign in puts the dots back")
      let job = try await panel.waitForSignIn()
      try await panel.waitUntil(timeout: 10) { !job.isPending }
      try await harness.layout(at: sizes[1])
      let fields = harness.textFields()
      XCTAssertFalse(fields.contains { $0.stringValue == "hunter2-secret" }, "No field keeps the password")
      XCTAssertEqual(
        try String(contentsOf: panel.root.appendingPathComponent("password"), encoding: .utf8),
        "hunter2-secret", "Steam's prompt got it")
      XCTAssertFalse(model.holdsSecret)
      harness.close()
    }
  }

  // MARK: VoiceOver

  /// A change of the Steam page's status is announced, once per change and never on arrival.
  func testAChangeOfTheSteamStatusIsAnnounced() async throws {
    try await withPanel(welcomeSeen: false) { panel in
      let model = panel.controller.welcome
      var announced = [String]()
      model.announce = { announced.append($0) }
      let harness = try WelcomeRenderHarness(panel: panel)
      try await harness.layout(at: sizes[1])
      model.go(to: .steam)
      try await panel.selectFakeSteamCMD()
      try await harness.layout(at: sizes[1])
      XCTAssertEqual(announced, [], "Arriving on the form announces nothing")

      model.signInAccount = "localtest"
      _ = await model.submitSignIn(password: "fixture-password")
      let job = try await panel.waitForSignIn()
      try await panel.waitUntil(timeout: 10) { !job.isPending }
      try await harness.layout(at: sizes[1])
      XCTAssertEqual(announced.last, L("Signed in as localtest"))
      XCTAssertFalse(announced.contains { $0.contains("fixture-password") })
      let count = announced.count
      try await harness.layout(at: sizes[1])
      XCTAssertEqual(announced.count, count, "Nothing changed, nothing more is said")
      harness.close()
    }
  }

  // MARK: The support prompt

  /// The sheet keeps to its width and a sensible height in every language, with and without the
  /// error line.
  func testTheSupportSheetFitsItsWidthInEveryLanguage() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      for language in AppLanguage.supported.map(\.tag) {
        for failing in [false, true] {
          try controller.appLanguage.set(language)
          PanelLocale.shared.bind(to: controller.appLanguage)
          if failing {
            controller.openSupportURL = { _ in false }
            await controller.supportPrompt.choose(.star)
          }
          let hosting = NSHostingView(
            rootView: SupportPromptSheet(presenter: controller.supportPrompt)
              .panelTheme(theme: controller.theme, locale: PanelLocale.shared))
          hosting.layoutSubtreeIfNeeded()
          let size = hosting.fittingSize
          XCTAssertEqual(size.width, 440, accuracy: 1, "\(language): the sheet keeps its width")
          XCTAssertLessThan(size.height, 480, "\(language): the sheet stays small")
          XCTAssertGreaterThan(size.height, 200, "\(language): and shows its content")
        }
      }
    }
  }
}
