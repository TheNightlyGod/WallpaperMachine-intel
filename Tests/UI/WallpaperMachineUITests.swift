import AppKit
import CoreGraphics
import XCTest

/// Opt-in desktop tests of the real app: they drive the native control panel through the
/// accessibility tree, so they need a desktop run (`python3 scripts/test.py --ui`).
///
/// The panel is SwiftUI. Controls are found by the stable `accessibilityIdentifier` the shell gives
/// them (`scope-*`, `collection-*`, `now-playing-*`, `dismiss-error`, `settings-section-*`) or, for
/// the title bar's tabs and the pages, by the label VoiceOver reads (the same words the interface
/// shows).
final class WallpaperMachineUITests: XCTestCase {
  private var app: XCUIApplication!
  private var window: XCUIElement { app.windows.firstMatch }

  override func setUpWithError() throws {
    continueAfterFailure = false
    app = XCUIApplication(bundleIdentifier: "app.wallpapermachine")
    let identifier = UUID().uuidString
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("WallpaperMachine-ui-\(identifier)")
    let suite = "app.wallpapermachine.tests.ui.\(identifier)"
    let application = app!
    // Register before any throwing setup, and terminate before removing data so
    // a late preferences flush cannot recreate the test domain after cleanup.
    addTeardownBlock { [weak self] in
      if application.state != .notRunning {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = self?.name ?? "UI test"
        screenshot.lifetime = .keepAlways
        self?.add(screenshot)
        application.terminate()
      }
      let defaults = UserDefaults(suiteName: suite)
      defaults?.removePersistentDomain(forName: suite)
      defaults?.synchronize()
      if FileManager.default.fileExists(atPath: root.path) {
        try FileManager.default.removeItem(at: root)
      }
    }
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defaults.setPersistentDomain([
      "WallpaperMachine.appLanguage": "en", "AppleLanguages": ["en"],
      "WallpaperMachine.welcomeSeen": true,
    ], forName: suite)
    defaults.synchronize()
    app.launchEnvironment["WALLPAPER_MACHINE_HOME"] = root.path
    app.launchEnvironment["WALLPAPER_MACHINE_DEFAULTS_SUITE"] = suite
    // Foundation resolves native strings before the app's stores are created.
    // Process arguments affect this launch only, never the host's global domain.
    app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    if name.contains("testInvalidVideo") {
      let folder = root.appendingPathComponent("Library/broken-video")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try Data("not valid media".utf8).write(to: folder.appendingPathComponent("broken.mp4"))
      try JSONSerialization.data(withJSONObject: [
        "title": "Broken Video", "type": "video", "file": "broken.mp4",
      ])
      .write(to: folder.appendingPathComponent("project.json"))
    }
    app.launch()
    XCTAssertTrue(
      app.windows.firstMatch.waitForExistence(timeout: 30), "The client must open a real window")
    XCTAssertTrue(
      identified("scope-all").waitForExistence(timeout: 30),
      "The window must show the Library page")
  }

  // MARK: Finding things

  /// A control by its accessibility identifier, whatever kind of element SwiftUI made of it.
  private func identified(_ identifier: String) -> XCUIElement {
    window.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  /// A control by the label VoiceOver reads.
  private func labelled(_ label: String) -> XCUIElement {
    window.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
  }

  private func wallpaper(_ title: String) -> XCUIElement {
    window.descendants(matching: .any)
      .matching(NSPredicate(format: "label BEGINSWITH %@", "\(title), ")).firstMatch
  }

  /// A search field by its label, or by its prompt (`PageSearchBar` names each page's field).
  private func searchField(_ label: String) -> XCUIElement {
    window.descendants(matching: .any)
      .matching(
        NSPredicate(
          format: "(label == %@ OR placeholderValue == %@) AND (elementType == %d OR elementType == %d)",
          label, label, XCUIElement.ElementType.searchField.rawValue,
          XCUIElement.ElementType.textField.rawValue)
      ).firstMatch
  }

  private func pageText(_ prefix: String) -> XCUIElement {
    window.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
  }

  private func expectPage(_ number: Int, timeout: TimeInterval = 40) {
    let field = labelled("Page number")
    let loaded = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == true AND enabled == true AND value == %@", String(number)),
      object: field)
    XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: timeout), .completed,
      "The enabled page-number control must show page \(number)")
  }

  /// A tab of the title bar by its title: `Library`, `Steam Workshop`, `pixiv`, `Settings`.
  private func navigate(_ tab: String) {
    let item = window.toolbars.descendants(matching: .any)
      .matching(NSPredicate(format: "label == %@", tab)).firstMatch
    XCTAssertTrue(item.waitForExistence(timeout: 10), tab)
    item.click()
  }

  /// A view of the library by its chip: `all`, `favorites`.
  private func showLibrary(_ scope: String) {
    navigate("Library")
    let chip = identified("scope-\(scope)")
    XCTAssertTrue(chip.waitForExistence(timeout: 10), "scope-\(scope)")
    chip.click()
  }

  /// A Settings section by its title, from Settings' section list.
  private func openSection(_ title: String) {
    let row = window.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "settings-section-", title))
      .firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 10), title)
    row.click()
  }

  private func selectAurora() {
    let tile = wallpaper("Aurora Drift")
    XCTAssertTrue(tile.waitForExistence(timeout: 15))
    tile.click()
    XCTAssertTrue(labelled("Apply wallpaper").waitForExistence(timeout: 10))
  }

  private func applyAurora() {
    selectAurora()
    labelled("Apply wallpaper").click()
    XCTAssertTrue(
      labelled("Reapply wallpaper").waitForExistence(timeout: 30),
      "The selected wallpaper must become active on the target display")
  }

  // MARK: Tests

  func testLaunchHasNoBlankFloatingWindows() {
    XCTAssertTrue(wallpaper("Aurora Drift").waitForExistence(timeout: 15))
    // Empty native windows can be absent from the accessibility tree. Ignore
    // the menu bar and desktop wallpaper windows in the WindowServer check.
    let pid = NSRunningApplication.runningApplications(
      withBundleIdentifier: "app.wallpapermachine"
    )
    .max { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }?.processIdentifier
    XCTAssertNotNil(pid)
    let windows =
      CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    let clientWindows = windows.filter {
      $0[kCGWindowOwnerPID as String] as? pid_t == pid
        && $0[kCGWindowLayer as String] as? Int == 0
        && (($0[kCGWindowBounds as String] as? [String: Any])?["Height"] as? Double ?? 0) > 100
    }
    XCTAssertEqual(
      clientWindows.count, 1, "Launch should show only the control panel: \(clientWindows)")
    XCTAssertEqual(app.sheets.count, 0)
    XCTAssertEqual(app.dialogs.count, 0)
  }

  func testSettingsShortcutUsesExistingWindow() {
    XCTAssertTrue(searchField("Search wallpapers").waitForExistence(timeout: 15))
    window.click()
    app.typeKey(",", modifierFlags: .command)
    XCTAssertTrue(identified("settings-section-library").waitForExistence(timeout: 10))
    XCTAssertEqual(app.windows.count, 1)
    navigate("Library")
    XCTAssertTrue(identified("scope-all").waitForExistence(timeout: 10))
    app.typeKey(",", modifierFlags: .command)
    XCTAssertTrue(identified("settings-section-library").waitForExistence(timeout: 10))
    XCTAssertEqual(app.windows.count, 1)
  }

  func testFirstLaunchNavigationAndSettingsCategories() {
    XCTAssertTrue(wallpaper("Aurora Drift").waitForExistence(timeout: 15))
    XCTAssertEqual(window.title, "All wallpapers", "the window is named for the place on show")
    navigate("Settings")
    XCTAssertTrue(identified("settings-section-general").waitForExistence(timeout: 10))
    openSection("Displays")
    XCTAssertTrue(pageText("Display mode").waitForExistence(timeout: 10))
    openSection("Library & Steam")
    XCTAssertTrue(pageText("SteamCMD").waitForExistence(timeout: 10))
    navigate("Steam Workshop")
    XCTAssertTrue(searchField("Search Steam Workshop").waitForExistence(timeout: 10))
    XCTAssertEqual(window.title, "Steam Workshop")
    showLibrary("all")
    XCTAssertTrue(searchField("Search wallpapers").waitForExistence(timeout: 10))
    XCTAssertEqual(app.alerts.count, 0)
  }

  func testCommandFFocusesThePagesSearchField() {
    let search = searchField("Search wallpapers")
    XCTAssertTrue(search.waitForExistence(timeout: 15))
    window.click()
    app.typeKey("f", modifierFlags: .command)
    app.typeText("aurora")
    XCTAssertEqual(search.value as? String, "aurora", "Command-F put the keyboard in the search field")
  }

  func testCollectionsAreMadeRenamedAndDeletedInTheFiltersPanel() {
    XCTAssertTrue(identified("installed-filter").waitForExistence(timeout: 15))
    identified("installed-filter").click()
    XCTAssertTrue(identified("collection-new").waitForExistence(timeout: 15))
    identified("collection-new").click()
    let field = identified("collection-name")
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.typeText("Chill evenings\r")
    let row = window.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", "Chill evenings")).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 10), "the new collection is listed")
    XCTAssertEqual(window.title, "Chill evenings", "and shown")
    row.rightClick()
    app.menuItems["Rename…"].click()
    let rename = identified("collection-name")
    XCTAssertTrue(rename.waitForExistence(timeout: 5))
    rename.typeKey("a", modifierFlags: .command)
    rename.typeText("Evenings\r")
    XCTAssertTrue(
      window.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Evenings"))
        .firstMatch.waitForExistence(timeout: 10))
    window.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Evenings"))
      .firstMatch.rightClick()
    app.menuItems["Delete…"].click()
    XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5), "deleting asks first")
    app.sheets.firstMatch.buttons["Delete"].click()
    XCTAssertTrue(identified("collection-notice").waitForExistence(timeout: 5))
  }

  func testImportPanePickerCancelAndEmptyLibrarySearch() {
    XCTAssertTrue(labelled("Import").waitForExistence(timeout: 15))
    labelled("Import").click()
    XCTAssertTrue(pageText("Import wallpapers").waitForExistence(timeout: 5))
    XCTAssertTrue(labelled("Choose wallpapers").exists)
    XCTAssertEqual(app.sheets.count, 0, "Opening the import pane must not open the native picker")
    labelled("Choose wallpapers").click()
    let picker = app.sheets.firstMatch
    XCTAssertTrue(
      picker.waitForExistence(timeout: 10), "Choosing files must open the native picker")
    picker.buttons["Cancel"].click()
    XCTAssertFalse(picker.exists)
    labelled("Close import").click()
    XCTAssertFalse(pageText("Import wallpapers").exists)

    let search = searchField("Search wallpapers")
    XCTAssertTrue(search.waitForExistence(timeout: 10))
    search.click()
    search.typeText("no-local-wallpaper-with-this-title")
    XCTAssertTrue(pageText("No matching wallpapers").waitForExistence(timeout: 10))
    XCTAssertFalse(wallpaper("Aurora Drift").exists)
    labelled("Clear search").click()
    XCTAssertTrue(wallpaper("Aurora Drift").waitForExistence(timeout: 10))
    XCTAssertEqual(app.alerts.count, 0)
  }

  func testSelectionSurvivesLibraryRefreshWithoutApplying() {
    selectAurora()
    XCTAssertFalse(
      labelled("Reapply wallpaper").exists,
      "Selecting a tile must not activate the wallpaper")
    labelled("Refresh library").click()
    XCTAssertTrue(
      labelled("Apply wallpaper").waitForExistence(timeout: 30),
      "Refresh must retain the selected wallpaper without activating it")
    XCTAssertEqual(app.alerts.count, 0)
  }

  func testCloseAndReopenDoesNotQuitOrCrash() {
    app.windows.firstMatch.buttons[XCUIIdentifierCloseWindow].click()
    XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
    app.activate()
    XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    XCTAssertTrue(identified("scope-all").waitForExistence(timeout: 10))
    XCTAssertEqual(app.alerts.count, 0)
  }

  func testCommandWClosesLikeTheCloseButton() {
    app.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10), "Command-W must close the panel")
    app.activate()
    XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    XCTAssertTrue(identified("scope-all").waitForExistence(timeout: 10))
    XCTAssertEqual(app.alerts.count, 0)
  }

  func testApplyPauseResumeAndRelaunch() {
    applyAurora()
    let toggle = identified("now-playing-toggle")
    XCTAssertEqual(toggle.label, "Pause wallpaper playback")
    toggle.click()
    XCTAssertTrue(labelled("Resume wallpaper playback").waitForExistence(timeout: 5))
    XCTAssertEqual(
      identified("now-playing").value as? String, "Playback paused", "the bar says so")
    toggle.click()
    XCTAssertTrue(labelled("Pause wallpaper playback").waitForExistence(timeout: 5))
    XCTAssertEqual(identified("now-playing").value as? String, "Playback running")
    app.terminate()
    app.launch()
    XCTAssertTrue(identified("scope-all").waitForExistence(timeout: 30))
    XCTAssertTrue(labelled("Pause wallpaper playback").waitForExistence(timeout: 30))
    XCTAssertTrue(wallpaper("Aurora Drift").waitForExistence(timeout: 15))
    XCTAssertEqual(app.alerts.count, 0)
  }

  func testWorkshopSearchPaginationAndNavigationPersistence() {
    navigate("Steam Workshop")
    let search = searchField("Search Steam Workshop")
    XCTAssertTrue(search.waitForExistence(timeout: 10))
    search.click()
    search.typeText("forest")
    labelled("Search").click()
    expectPage(1)
    let next = labelled("Next page")
    XCTAssertTrue(next.waitForExistence(timeout: 40))
    XCTAssertTrue(
      next.isEnabled, "The Workshop query needs more than one page to exercise pagination")
    next.click()
    expectPage(2)
    showLibrary("all")
    navigate("Steam Workshop")
    XCTAssertEqual(searchField("Search Steam Workshop").value as? String, "forest")
    expectPage(2)
    XCTAssertEqual(app.alerts.count, 0)
  }

  func testInvalidVideoReportsFailureAndRemainsUsable() {
    let broken = wallpaper("Broken Video")
    XCTAssertTrue(broken.waitForExistence(timeout: 15))
    broken.click()
    XCTAssertTrue(labelled("Apply wallpaper").waitForExistence(timeout: 10))
    labelled("Apply wallpaper").click()
    XCTAssertTrue(
      identified("dismiss-error").waitForExistence(timeout: 30),
      "The invalid video must report an error in the panel")
    XCTAssertFalse(
      labelled("Reapply wallpaper").exists,
      "A failed activation must not mark the invalid video active")
    applyAurora()
    XCTAssertTrue(identified("now-playing-toggle").isEnabled)
  }
}
