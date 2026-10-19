import AppKit
import SwiftUI
import XCTest

@testable import WallpaperMachine

/// The five sections of settings-b drawn in a window that is never shown: they take the size the
/// window gives them without asking for a larger one, in light and dark and in every shipped
/// language, with the editors and disclosures that make them widest open.
@MainActor
final class SettingsBRenderTests: SettingsBTestCase {
  private let sections: [SettingsSection] = [.displays, .shortcuts, .library, .storage, .about]
  private let sizes = [NSSize(width: 760, height: 560), NSSize(width: 1240, height: 800)]

  private func assertFits(
    _ host: SettingsBHost, at size: NSSize, _ context: String, file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    try await host.settle(size)
    let measured = host.hosting.sizeThatFits(in: size)
    let split = host.widestSplitView
    // The root accepts the window width, asks for no taller window and lays its split view out
    // within the window; one message carries all three figures.
    if abs(measured.width - size.width) > 1 || measured.height > size.height + 1 || split > size.width + 1 {
      XCTFail(
        "\(context): window \(Int(size.width))x\(Int(size.height)), the root measures \(measured), the split view is \(split) wide",
        file: file, line: line)
    }
    XCTAssertFalse(host.window.isVisible, "layout measurement must stay offscreen", file: file, line: line)
  }

  // One test per shipped language, so that each has its own time allowance: a page is laid out
  // thirty-odd times in each.
  func testEverySectionAcceptsBothWindowSizesLightAndDarkInEnglish() async throws { try await everySection("en") }
  func testEverySectionAcceptsBothWindowSizesLightAndDarkInJapanese() async throws { try await everySection("ja") }
  func testEverySectionAcceptsBothWindowSizesLightAndDarkInKorean() async throws { try await everySection("ko") }
  func testEverySectionAcceptsBothWindowSizesLightAndDarkInSimplifiedChinese() async throws {
    try await everySection("zh-Hans")
  }
  func testEverySectionAcceptsBothWindowSizesLightAndDarkInTraditionalChinese() async throws {
    try await everySection("zh-Hant")
  }

  func testTheEditorsAndOpenDisclosuresStillFitTheNarrowestWindowInEnglish() async throws { try await openStates("en") }
  func testTheEditorsAndOpenDisclosuresStillFitTheNarrowestWindowInJapanese() async throws { try await openStates("ja") }
  func testTheEditorsAndOpenDisclosuresStillFitTheNarrowestWindowInKorean() async throws { try await openStates("ko") }
  func testTheEditorsAndOpenDisclosuresStillFitTheNarrowestWindowInSimplifiedChinese() async throws {
    try await openStates("zh-Hans")
  }
  func testTheEditorsAndOpenDisclosuresStillFitTheNarrowestWindowInTraditionalChinese() async throws {
    try await openStates("zh-Hant")
  }

  /// A language added to the app has to be added to the tests above.
  func testEveryShippedLanguageIsTestedAbove() {
    XCTAssertEqual(Set(AppLanguage.supported.map(\.tag)), ["en", "ja", "ko", "zh-Hans", "zh-Hant"])
  }

  private func everySection(_ language: String) async throws {
    try await withPanel { panel in
      try SettingsBFixtures.populate(panel)
      panel.show()
      let host = SettingsBHost(panel: panel)
      for dark in [false, true] {
        host.use(language: language, dark: dark, panel: panel)
        for section in sections {
          for size in sizes {
            try await host.show(section, size: size)
            try await assertFits(host, at: size, "\(section) \(language) \(dark ? "dark" : "light") \(Int(size.width))")
          }
        }
      }
      host.close()
    }
  }

  private func openStates(_ language: String) async throws {
    try await withPanel { panel in
      try SettingsBFixtures.populate(panel)
      panel.show()
      let model = panel.controller.displaysSettings
      for item in [
        DisplaysSettingsSection.playlist, DisplaysSettingsSection.transfer, DisplaysSettingsSection.automation,
        DisplaysSettingsSection.playback, DisplaysSettingsSection.playlistSkipped,
      ] {
        for display in ["primary", "2", "3"] { model.setOpen(true, item, display: display) }
      }
      model.peers["primary"] = "2"
      // The second display follows the system appearance, so its light and dark choices are drawn
      // in their open disclosure too: a wallpaper for light, a saved playlist for dark.
      let plan = try XCTUnwrap(panel.controller.playlistPlanRows.first)
      try panel.automations.update("2") {
        $0.mode = .appearance
        $0.light = .init(kind: .wallpaper, id: "w8")
        $0.dark = .init(kind: .playlist, id: plan.id)
      }
      XCTAssertEqual(panel.controller.automationState(for: "2").mode, .appearance)
      model.beginRule(display: "primary")
      model.ruleEditor?.showsDaysError = true
      model.ruleEditor?.weekdays = []
      // A name form takes the keyboard when it opens, and only one is open at a time.
      if language == "ja" || language == "zh-Hant" {
        model.beginSavingPlan(of: "2")
        model.planName = DisplaysNameForm(String(repeating: "长い名称", count: 25))
      } else {
        model.beginNewLayout()
        model.layoutName = DisplaysNameForm(String(repeating: "长い名称", count: 25))
      }
      for item in [LibrarySettingsSection.context, StorageSettingsSection.context, ShortcutsSettingsSection.links] {
        panel.controller.settings.setOpen(true, for: item)
      }
      let host = SettingsBHost(panel: panel)
      let size = NSSize(width: 760, height: 560)
      host.use(language: language, dark: false, panel: panel)
      for section in sections {
        try await host.show(section, size: size)
        try await assertFits(host, at: size, "\(section) \(language) open")
      }
      host.close()
    }
  }

  func testASearchLeavesOnlyTheMatchingRowsAndTheResultsStillFit() async throws {
    try await withPanel { panel in
      try SettingsBFixtures.populate(panel)
      panel.show()
      let host = SettingsBHost(panel: panel)
      // A display's name, a saved layout's name and a wallpaper of a display's list each find the
      // Displays page, as a row's words do.
      for query in ["Shuffle", "Studio", "Work", "Aurora", "Locate", "Export", "Latitude", "Record", "zzz-nothing"] {
        panel.controller.settings.query = query
        for size in sizes {
          try await host.show(.displays, size: size)
          panel.controller.settings.query = query
          try await host.layout(at: size)
          try await assertFits(host, at: size, "search \(query) \(Int(size.width))")
        }
        let search = panel.controller.settings.search
        if ["Shuffle", "Studio", "Work", "Aurora", "Latitude"].contains(query) {
          XCTAssertTrue(search.shows(.displays), "\(query) keeps the Displays page")
          XCTAssertGreaterThan(search.count(in: .displays), 0, "\(query) is counted in the sidebar")
        }
        XCTAssertEqual(search.hasNoResults, query == "zzz-nothing", query)
      }
      panel.controller.settings.query = ""
      host.close()
    }
  }

  func testTheDisplaysPageWithNoDisplayStillSaysSoAndFits() async throws {
    try await withPanel { panel in
      try SettingsBFixtures.populate(panel)
      panel.store.settingsSnapshot.displays = []
      panel.show()
      let host = SettingsBHost(panel: panel)
      for size in sizes {
        try await host.show(.displays, size: size)
        try await assertFits(host, at: size, "no display \(Int(size.width))")
      }
      XCTAssertTrue(panel.controller.displayRows.isEmpty)
      host.close()
    }
  }

  func testTheCardsOfAMirrorAndADisabledDisplayDrawWithoutTheRowsTheyDoNotHave() async throws {
    try await withPanel { panel in
      try SettingsBFixtures.populate(panel)
      panel.store.settingsSnapshot.displays[1].enabled = false
      panel.show()
      let host = SettingsBHost(panel: panel)
      for size in sizes {
        try await host.show(.displays, size: size)
        try await assertFits(host, at: size, "mirror and disabled \(Int(size.width))")
      }
      let rows = panel.controller.displayRows
      XCTAssertTrue(rows[2].isMirror)
      XCTAssertFalse(rows[1].enabled)
      XCTAssertTrue(panel.controller.transferPeers(of: "primary").isEmpty, "no peer to copy to while the other is off")
      host.close()
    }
  }
}
