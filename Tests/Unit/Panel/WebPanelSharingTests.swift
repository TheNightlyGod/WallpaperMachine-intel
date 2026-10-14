import XCTest

@testable import WallpaperMachine

/// Sharing builds its links in Swift from a Workshop id; the page only names the id and
/// where its button is.
@MainActor
final class WebPanelSharingTests: ControlPanelTestCase {
  private func post(_ panel: PanelFixture, _ message: String) async throws -> Any? {
    try await panel.js("return await window.webkit.messageHandlers.native.postMessage(\(message))")
  }

  func testWallpaperIsSharedAsItsWorkshopPageAndTheAppLink() async throws {
    try await withPanel { panel in
      var shared: [(items: [Any], rect: NSRect)] = []
      panel.controller.presentSharePicker = { shared.append(($0, $1)) }
      try await panel.finishWelcome()
      _ = try await post(panel, "{action:'shareWallpaper', id:'2873461829', rect:{x:10, y:20, width:30, height:40}}")

      let share = try XCTUnwrap(shared.first)
      XCTAssertEqual(share.rect, NSRect(x: 10, y: 20, width: 30, height: 40))
      XCTAssertEqual(share.items.compactMap { $0 as? URL }.map(\.absoluteString),
                     ["https://steamcommunity.com/sharedfiles/filedetails/?id=2873461829"])
      let text = try XCTUnwrap(share.items.compactMap { $0 as? String }.first)
      XCTAssertTrue(text.contains(panel.controller.websiteURL.absoluteString))
    }
  }

  func testOnlyAWorkshopIdCanBeShared() async throws {
    try await withPanel { panel in
      var shared = 0
      panel.controller.presentSharePicker = { _, _ in shared += 1 }
      try await panel.finishWelcome()
      for id in ["pixiv-123-p0", "image-cat", "../../etc", "https://evil.example/"] {
        do {
          _ = try await post(panel, "{action:'shareWallpaper', id:'\(id)', rect:{x:0, y:0, width:1, height:1}}")
          XCTFail("\(id) must be refused")
        } catch {}
      }
      XCTAssertEqual(shared, 0)
    }
  }

  func testAppIsSharedWithTheWebsiteInThePanelsLanguage() async throws {
    try await withPanel { panel in
      var shared: [[Any]] = []
      panel.controller.presentSharePicker = { items, _ in shared.append(items) }
      try panel.controller.appLanguage.set("zh-Hans")
      defer { try? panel.controller.appLanguage.set(AppLanguageStore.systemChoice) }
      try await panel.finishWelcome()
      _ = try await post(panel, "{action:'shareApp', rect:{x:0, y:0, width:1, height:1}}")
      XCTAssertEqual(shared.first?.compactMap { $0 as? URL }.map(\.absoluteString), ["https://www.wallpapermachine.app/zh/"])
    }
  }
}
