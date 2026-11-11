import AppKit
import SwiftUI
import XCTest

@testable import WallpaperMachine

/// The menu bar panel drawn offscreen: what VoiceOver finds in it, and that it keeps its width in
/// every language, as a popover under the menu bar must.
@MainActor
final class StatusPanelRenderTests: PanelTestCase {
  typealias Source = StatusPanelControllerTests.Source

  /// Long enough to wrap, as Workshop titles are.
  private static func title(_ id: String) -> String { "A very long wallpaper title that will not fit on one line \(id)" }

  private func input(displays: Int, muted: Bool = false) -> StatusPanelModel.Input {
    let ids = (1...12).map { "w\($0)" }
    let all: [StatusMenuModel.Display] = (1...displays).map { index in
      StatusMenuModel.Display(
        id: index == 1 ? "primary" : "\(index)", title: "Studio Display (\(index) - Role)",
        wallpaperID: "w\(index)", canPrevious: true, canNext: true, canRandom: true,
        recent: ["w\(index)", "w10", "w11"].map { .init(id: $0, title: "Wallpaper \($0)") })
    }
    return StatusPanelModel.Input(
      menu: .init(playbackIsCurrent: true, hasActiveWallpapers: true, paused: false, wallpapersMuted: muted,
                  displays: all, canLockScreen: true),
      library: ids.map { .init(id: $0, title: Self.title($0), kind: .scene, previewFile: nil, isPlayable: true) },
      hold: .rule(stopped: false))
  }

  private func host(_ source: Source) -> (NSHostingView<StatusPanelRoot>, StatusPanelController) {
    let controller = StatusPanelController(source: source, random: PlaylistPlannerTests.SplitMix(state: 1))
    controller.start()
    addTeardownBlock { @MainActor in
      controller.stop()
      withExtendedLifetime(source) {}
    }
    let hosting = NSHostingView(rootView: StatusPanelRoot(controller: controller))
    hosting.layoutSubtreeIfNeeded()
    return (hosting, controller)
  }

  func testVoiceOverFindsEveryControlAndTheDisplayPickerOnlyWithTwoDisplays() throws {
    try pinPanelLanguageToEnglish()
    let (two, _) = host(Source(input(displays: 2)))
    let elements = AccessibilityElement.everything(in: two)
    for identifier in [
      "status-panel-displays", "status-panel-previous", "status-panel-toggle", "status-panel-next",
      "status-panel-random", "status-panel-favorite", "status-panel-mute", "status-panel-shuffle",
      "status-panel-control-panel", "status-panel-settings", "status-panel-quit",
    ] {
      XCTAssertTrue(elements.contains { $0.identifier == identifier }, "\(identifier) is reachable")
    }
    XCTAssertTrue(elements.contains { $0.text == Self.title("w10") }, "Recently used names its wallpapers")
    XCTAssertTrue(elements.contains { $0.text == "Quit WallpaperMachine" }, "The icon-only Quit is named")

    let (one, _) = host(Source(input(displays: 1)))
    XCTAssertFalse(AccessibilityElement.everything(in: one).contains { $0.identifier == "status-panel-displays" },
                   "One display needs no picker")
  }

  func testThePanelKeepsItsWidthInEveryLanguage() throws {
    let languages = AppLanguageStore(
      defaults: try TemporaryDefaults.make(for: self).defaults, systemLanguages: ["en"])
    PanelLocale.shared.bind(to: languages)
    addTeardownBlock { @MainActor in PanelLocale.shared.bind(to: .testHost) }
    for language in AppLanguage.supported.map(\.tag) {
      try languages.set(language)
      let (hosting, _) = host(Source(input(displays: 3, muted: true)))
      let size = hosting.fittingSize
      XCTAssertEqual(size.width, StatusPanelView.width, accuracy: 1, "\(language): the panel keeps its width")
      XCTAssertLessThan(size.height, 820, "\(language): the panel fits under the menu bar of a small screen")
    }
  }
}
