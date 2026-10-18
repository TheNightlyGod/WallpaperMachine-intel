import AppKit
import SwiftUI
import XCTest

@testable import WallpaperMachine

/// Settings drawn the way the person sees it: inside the whole panel, in an unordered
/// `ControlPanelWindow`, with the shell's sidebar and the inspector the detail column always carries.
/// `SettingsSectionsRenderTests` measures the pages alone; only here does a page meet the split view
/// it has to fit in.
@MainActor
final class SettingsWindowRenderTests: PanelTestCase {
  override func tearDown() async throws {
    restoreSharedPanelLanguage()
    try await super.tearDown()
  }

  /// The smallest window's width at the heights where a page that asked for width made AppKit loop
  /// over the window's constraints.
  private static let heights: [CGFloat] = [560, 760, 900, 1100]

  /// Every section, opened first and then reached from its neighbours either way, keeps the split
  /// view inside the smallest window: a page that asks for width on top of the inspector's minimum
  /// clips the sidebar and the card edges, and at some heights crashes the panel.
  func testEverySectionFitsTheSmallestWindowAtEveryHeightWhileMovingBetweenSections() async throws {
    let (store, bridge) = makeStore()
    try await ShellFixtures.seed(store, bridge: bridge)
    let sections = SettingsSection.allCases
    for language in ["en", "ja"] {
      for height in Self.heights {
        try await withShellHost(store: store, language: language, selection: .settings) { host in
          let size = NSSize(width: 760, height: height)
          host.layout(at: size)
          // Performance and Appearance first, the two pages that once asked for the most.
          for section in [.performance, .appearance] + sections + sections.reversed() {
            host.navigation.revealSettingsSection(section)
            try await host.settle(60)
            host.layout(at: size)
            XCTAssertLessThanOrEqual(
              host.widestSplitView, size.width + 1,
              "\(language) \(section) at 760x\(Int(height)): the panel must fit the window")
          }
        }
      }
    }
  }

  // MARK: The keyboard

  /// The section list is the system sidebar list, so Up and Down move to the neighbouring section
  /// and open it, keeping the keyboard in the list. The web panel wrapped from one end to the other;
  /// a native list stops at either end, as System Settings does (docs/features/control-panel.md).
  func testTheArrowKeysOpenTheNeighbouringSectionAndStopAtEitherEnd() async throws {
    try PanelTestSupport.skipBeforeMacOS27(
      "macOS 26's sidebar list ignores arrow keys sent to an unshown window")
    try await withPanel { panel in
      try await ShellFixtures.seed(panel.store, bridge: panel.bridge)
      panel.navigation.selection = .settings
      let host = ShellFixtureHost(panel: panel)
      let settings = panel.controller.settings
      // General is chosen before the list is drawn, so the list starts on it: a list drawn on Quick
      // Settings first would be one row behind the model, and Down would land on General.
      settings.select(.general)
      host.layout(at: NSSize(width: 1240, height: 800))
      try await panel.waitUntil {
        Self.sectionList(in: host.window).map { $0.selectedRow >= 0 } ?? false
      }
      let list = try XCTUnwrap(Self.sectionList(in: host.window))
      XCTAssertTrue(host.window.makeFirstResponder(list))

      try await press(down: true, in: list, panel) { settings.selectedSection == .appearance }
      try await press(down: false, in: list, panel) { settings.selectedSection == .general }
      try await press(down: false, in: list, panel) { settings.selectedSection == .quick }
      let quickTitle = settings.text(SettingsSection.quick.title)
      try await panel.waitUntil { host.window.title == quickTitle }
      XCTAssertTrue(host.window.firstResponder === list, "The keyboard stays in the list")

      // Up on the first section stays there: had it wrapped to About, Down could not reach General.
      list.keyDown(with: Self.arrow(down: false, in: host.window))
      try await press(down: true, in: list, panel) { settings.selectedSection == .general }

      let last = try XCTUnwrap(SettingsSection.allCases.last)
      let beforeLast = SettingsSection.allCases[SettingsSection.allCases.count - 2]
      settings.select(last)
      try await panel.waitUntil { list.selectedRow == list.numberOfRows - 1 }
      // Down on the last section stays there: had it wrapped to Quick Settings, Up could not reach
      // the section before the last.
      list.keyDown(with: Self.arrow(down: true, in: host.window))
      try await press(down: false, in: list, panel) { settings.selectedSection == beforeLast }
      host.close()
    }
  }

  /// Presses an arrow key in the section list and waits until `arrived` holds.
  private func press(
    down: Bool, in list: NSOutlineView, _ panel: PanelFixture, until arrived: () -> Bool
  ) async throws {
    list.keyDown(with: Self.arrow(down: down, in: list.window!))
    try await panel.waitUntil(arrived)
  }

  /// The Settings sidebar's list: the only outline in the window while Settings is open.
  private static func sectionList(in window: NSWindow) -> NSOutlineView? {
    func find(_ view: NSView) -> NSOutlineView? {
      (view as? NSOutlineView) ?? view.subviews.lazy.compactMap(find).first
    }
    return window.contentView.flatMap(find)
  }

  /// An arrow key as the keyboard delivers it, with the function-key character the list reads.
  private static func arrow(down: Bool, in window: NSWindow) -> NSEvent {
    let text = String(Character(UnicodeScalar(down ? NSDownArrowFunctionKey : NSUpArrowFunctionKey)!))
    return NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: text,
      charactersIgnoringModifiers: text, isARepeat: false, keyCode: down ? 125 : 126)!
  }
}
