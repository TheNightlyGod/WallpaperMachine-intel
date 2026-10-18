import AppKit
import SwiftUI
import XCTest

@testable import WallpaperMachine

/// The Settings controls as they are drawn, in a window that is never shown: what VoiceOver calls
/// each one and hints with, how the Quality preset shows Custom, and what the frame-rate slider draws
/// and sends. A page is hosted on its own rather than in its scrolling column, whose content offscreen
/// exposes only its AppKit controls to the accessibility tree.
@MainActor
final class SettingsControlsRenderTests: PanelTestCase {
  /// A Mac on battery with a Reduced quality choice (so the reduced profile's rows are drawn), a
  /// frame-rate limit and render scale that match no preset, and a login item that waits for the
  /// user's approval in System Settings.
  private func prepare(_ panel: PanelFixture) {
    panel.store.snapshotRevision = 1
    var settings = BridgeSnapshotFixtures.settings(
      displays: panel.store.settingsSnapshot.displays, batteryMode: .reducedQuality,
      renderScale: 1, preferredRenderScale: 1, frameRateCap: 45, onBatteryPower: true)
    settings.launchAtLoginAvailable = true
    settings.launchAtLoginNeedsApproval = true
    panel.store.settingsSnapshot = settings
  }

  /// `page` in an unordered window, its accessibility tree once it has settled, then the window is
  /// closed again.
  private func withPage(
    _ page: some View, _ controller: PanelController,
    _ body: (NSHostingController<AnyView>, AccessibilityElement) async throws -> Void
  ) async throws {
    let hosting = NSHostingController(
      rootView: AnyView(
        page.environment(controller)
          .panelTheme(theme: controller.theme, locale: PanelLocale.shared)))
    hosting.sizingOptions = []
    let window = ControlPanelWindow.make(contentViewController: hosting, delegate: nil)
    defer {
      window.contentViewController = nil
      window.close()
    }
    window.setContentSize(NSSize(width: 700, height: 1_000))
    hosting.view.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(250))
    hosting.view.layoutSubtreeIfNeeded()
    XCTAssertFalse(window.isVisible, "Rendering stays offscreen")
    try await body(hosting, AccessibilityElement(object: hosting.view))
  }

  /// The row of `item` in the tree, failing the test when it is not drawn.
  private func row(
    _ item: SettingsItem, in tree: AccessibilityElement, file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> AccessibilityElement {
    try XCTUnwrap(tree.first(identifier: item.id), "\(item.id) is not drawn", file: file, line: line)
  }

  /// The lead of a note: the part under the row's title, which is the control's hint.
  private func lead(_ note: String) -> String { SettingsNote.parts(note).lead }

  // MARK: VoiceOver

  /// Every control carries its row's name and the note under it as its hint, as the web page's
  /// `aria-label` and `aria-describedby` did, including a switch or a field that shares its row with
  /// another control, where the row's own label names the group around them. A pop-up is named
  /// once, not "Language, Language".
  func testEveryControlIsNamedAfterItsRowAndHintedWithTheNoteUnderIt() async throws {
    try pinPanelLanguageToEnglish()
    try await withRecordingPanel { panel, _ in
      prepare(panel)
      let controller = panel.controller
      let settings = controller.settings

      try await withPage(GeneralSettingsSection(), controller) { _, tree in
        // Launch at login waits for approval: Open Login Items… sits beside the switch.
        let login = try row(GeneralSettingsSection.launchAtLogin, in: tree)
        let toggle = try XCTUnwrap(login.first(role: "AXCheckBox"), "the switch of Launch at login")
        XCTAssertEqual(toggle.label, settings.text(GeneralSettingsSection.launchAtLogin.title))
        XCTAssertEqual(toggle.help, lead(try XCTUnwrap(controller.generalSettings.launchAtLogin.note)))

        let language = try XCTUnwrap(
          row(GeneralSettingsSection.language, in: tree).first(role: "AXPopUpButton"))
        XCTAssertEqual(language.label, settings.text(GeneralSettingsSection.language.title))
        XCTAssertEqual(
          language.help, lead(settings.text(try XCTUnwrap(GeneralSettingsSection.language.note))))
      }

      try await withPage(PlaybackSettingsSection(), controller) { _, tree in
        // The number field shares its row with its unit.
        let fps = try XCTUnwrap(
          row(PlaybackSettingsSection.batteryFps, in: tree).first(role: "AXTextField"),
          "the field of Frame rate when reduced")
        XCTAssertEqual(fps.label, settings.text(PlaybackSettingsSection.batteryFps.title))

        for item in [PlaybackSettingsSection.desktopCovered, PlaybackSettingsSection.displaySleep] {
          let menu = try XCTUnwrap(row(item, in: tree).first(role: "AXPopUpButton"), item.id)
          XCTAssertEqual(menu.label, settings.text(item.title), "\(item.id) is named once")
          XCTAssertEqual(menu.help, lead(settings.text(try XCTUnwrap(item.note))), item.id)
        }
      }

      try await withPage(PerformanceSettingsSection(), controller) { _, tree in
        let item = PerformanceSettingsSection.frameRateLimit
        let slider = try XCTUnwrap(row(item, in: tree).first(role: "AXSlider"))
        XCTAssertEqual(slider.label, settings.text(item.title))
        XCTAssertEqual(slider.help, lead(settings.text(try XCTUnwrap(item.note))))
      }
    }
  }

  // MARK: Quality preset

  /// Custom is the state when the saved values match no preset: it is drawn as the selection, yet it
  /// is never a control VoiceOver or the keyboard can press, while Low, Medium and High are.
  func testCustomIsShownAsTheQualityInForceButIsNeverAButton() async throws {
    try pinPanelLanguageToEnglish()
    try await withRecordingPanel { panel, _ in
      prepare(panel)
      let controller = panel.controller
      XCTAssertNil(controller.performanceSettings.activePreset, "45 fps at full scale is no preset")
      try await withPage(PerformanceSettingsSection(), controller) { _, tree in
        let preset = try row(PerformanceSettingsSection.preset, in: tree).all()
        let buttons = preset.filter { $0.role == "AXButton" }.map(\.text)
        for choice in QualityPreset.allCases {
          XCTAssertTrue(buttons.contains(choice.title), "\(choice.title) can be chosen: \(buttons)")
        }
        let custom = try XCTUnwrap(
          preset.first { $0.text == QualityPreset.customTitle }, "Custom is drawn")
        XCTAssertNotEqual(custom.role, "AXButton", "Custom is a state, not a choice")
      }
    }
  }

  // MARK: Frame rate limit

  /// The slider draws no tick marks, the dotted line a stepped SwiftUI slider draws under its track.
  /// An arrow key moves it one frame rate and is sent at once; a drag is sent once, where it is let
  /// go.
  func testTheFrameRateSliderDrawsNoTicksStepsOneRatePerKeyAndSendsADragWhereItStops() async throws {
    try await withRecordingPanel { panel, bridge in
      prepare(panel)
      let controller = panel.controller
      try await withPage(PerformanceSettingsSection(), controller) { hosting, _ in
        let slider = try XCTUnwrap(
          PanelNSSlider.all(in: hosting.view).first, "the frame-rate slider is drawn")
        XCTAssertEqual(slider.numberOfTickMarks, 0)
        XCTAssertEqual(slider.doubleValue, 45)

        slider.keyDown(with: Self.key(124))  // right
        try await panel.waitUntil { !bridge.frameRateCapCalls.isEmpty }
        XCTAssertEqual(bridge.frameRateCapCalls, [46], "One frame rate, sent at once")

        try await panel.waitUntil { controller.settings.drafts.isEmpty }
        slider.beginPointer()
        for value in [40.4, 33.2, 30.0] {
          slider.doubleValue = value
          slider.valueDidChange(nil)
          try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertEqual(bridge.frameRateCapCalls, [46], "Nothing is sent while the slider is dragged")
        slider.endPointer()
        try await panel.waitUntil { bridge.frameRateCapCalls.count == 2 }
        XCTAssertEqual(bridge.frameRateCapCalls, [46, 30], "The drag is sent where it stopped")
      }
    }
  }

  private static func key(_ code: UInt16) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
      context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
  }
}

extension PanelNSSlider {
  /// The panel sliders inside `view`, in drawing order.
  @MainActor
  static func all(in view: NSView) -> [PanelNSSlider] {
    ((view as? PanelNSSlider).map { [$0] } ?? []) + view.subviews.flatMap { all(in: $0) }
  }
}
