import Foundation
import XCTest
@testable import WallpaperMachine

@MainActor
final class ControlPanelPlaybackToolsTests: ControlPanelTestCase {
  private func installLibrary(_ panel: PanelFixture) {
    panel.store.librarySnapshot.wallpapers = ["a", "b", "c", "d"].map { id in
      BridgeWallpaperEntry(id: id, title: id == "b" ? "B <img src=x onerror=alert(1)>" : id,
        kind: .webpage, supported: true, active: false, selected: false, previewPath: nil)
    }
  }

  /// What a JavaScript expression that evaluates to an array of strings reads now; none may be empty.
  private func texts(_ panel: PanelFixture, _ expression: String,
                     file: StaticString = #filePath, line: UInt = #line) async throws -> [String] {
    let read = try await panel.js("return \(expression)")
    let values = try XCTUnwrap(read as? [String], file: file, line: line)
    XCTAssertFalse(values.isEmpty, file: file, line: line)
    for value in values { XCTAssertFalse(value.isEmpty, file: file, line: line) }
    return values
  }

  /// The strings as a JavaScript array literal.
  private func arrayLiteral(_ values: [String]) throws -> String {
    String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
  }

  func testButtonsAndDragReorderTheNativePlaylistAndRefuseAStaleDrag() async throws {
    try await withPanel { panel in
      installLibrary(panel)
      panel.playlists.update("primary") {
        $0.mode = .rotate; $0.source = .list; $0.wallpaperIDs = ["a", "b", "c"]
      }
      try await panel.finishWelcome()
      panel.navigation.selection = .settings
      panel.show()
      try await panel.waitJS("powerProbe.received.at(-1)?.page === 'settings'")
      _ = try await panel.js("document.querySelector('[data-section=\"displays\"]').click()")
      try await panel.waitJS("document.querySelectorAll('[data-playlist-item]').length === 3")
      _ = try await panel.js("document.querySelector('[data-key=\"display-primary-playlist\"] > summary').click()")
      try await panel.waitJS("document.querySelector('[data-playlist-item] button').getClientRects().length > 0")
      try await panel.expectJS("return document.querySelectorAll('.settings-playlist img').length", equals: 0)
      _ = try await panel.js("""
        const row = document.querySelector('[data-playlist-item="a"]');
        const down = [...row.querySelectorAll('[data-action="playlistMove"]')].find(button => JSON.parse(button.dataset.args).direction === 1);
        down.focus(); down.click();
        """)
      try await panel.waitUntil { panel.playlists.playlist(for: "primary").wallpaperIDs == ["b", "a", "c"] }
      try await panel.waitJS("[...document.querySelectorAll('[data-playlist-item]')].map(row => row.dataset.playlistItem).join(',') === 'b,a,c' && !document.querySelector('[data-action=\"playlistRemove\"]').disabled")
      try await panel.expectJS("return JSON.parse(document.activeElement.dataset.args).id", equals: "a")
      try await panel.expectJS("return JSON.parse(document.activeElement.dataset.args).direction", equals: 1)
      _ = try await panel.js("document.activeElement.click()")
      try await panel.waitUntil { panel.playlists.playlist(for: "primary").wallpaperIDs == ["b", "c", "a"] }
      try await panel.waitJS("document.activeElement.dataset.action === 'playlistMove' && JSON.parse(document.activeElement.dataset.args).direction === -1")
      try await panel.expectJS("return JSON.parse(document.activeElement.dataset.args).id", equals: "a")
      _ = try await panel.js("document.activeElement.click()")
      try await panel.waitUntil { panel.playlists.playlist(for: "primary").wallpaperIDs == ["b", "a", "c"] }
      try await panel.waitJS("[...document.querySelectorAll('[data-playlist-item]')].map(row => row.dataset.playlistItem).join(',') === 'b,a,c' && !document.querySelector('[data-action=\"playlistRemove\"]').disabled")
      try await panel.expectJS("return Boolean(document.querySelector('.settings-playlist + [role=\"status\"]').textContent.trim())", equals: true)
      _ = try await panel.js("""
        const source = document.querySelector('[data-playlist-item="b"]');
        const target = document.querySelector('[data-playlist-item="c"]');
        const rect = target.getBoundingClientRect();
        const dataTransfer = new DataTransfer();
        source.dispatchEvent(new DragEvent('dragstart', { bubbles: true, dataTransfer }));
        target.dispatchEvent(new DragEvent('dragover', { bubbles: true, cancelable: true, clientY: rect.bottom - 1, dataTransfer }));
        target.dispatchEvent(new DragEvent('drop', { bubbles: true, cancelable: true, clientY: rect.bottom - 1, dataTransfer }));
        """)
      try await panel.waitUntil { panel.playlists.playlist(for: "primary").wallpaperIDs == ["a", "c", "b"] }
      XCTAssertEqual(PlaylistStore(defaults: panel.defaults).playlist(for: "primary").wallpaperIDs, ["a", "c", "b"])
      try await panel.waitJS("[...document.querySelectorAll('[data-playlist-item]')].map(row => row.dataset.playlistItem).join(',') === 'a,c,b' && !document.querySelector('[data-action=\"playlistRemove\"]').disabled")
      _ = try await panel.js("document.querySelector('[data-playlist-item=\"a\"]').dispatchEvent(new DragEvent('dragstart', { bubbles: true, dataTransfer: new DataTransfer() }))")
      panel.playlists.add(["d"], to: "primary")
      try await panel.waitJS("document.querySelectorAll('[data-playlist-item]').length === 4")
      _ = try await panel.js("""
        const target = document.querySelector('[data-playlist-item="b"]');
        target.dispatchEvent(new DragEvent('drop', { bubbles: true, cancelable: true, clientY: target.getBoundingClientRect().bottom - 1 }));
        """)
      try await panel.waitJS("Boolean(document.querySelector('#settings-content [role=\"alert\"]'))")
      XCTAssertEqual(panel.playlists.playlist(for: "primary").wallpaperIDs, ["a", "c", "b", "d"])
    }
  }

  /// A playlist that waits because the user emptied the display says so, offers Resume only
  /// while it waits, and does so in the page's language.
  func testTheResumeRowShowsOnlyWhileAPlaylistWaitsAndAsksToResumeIt() async throws {
    try await withPanel { panel in
      installLibrary(panel)
      panel.playlists.update("primary") { $0.mode = .rotate }
      try await panel.finishWelcome()
      panel.navigation.selection = .settings
      panel.show()
      try await panel.waitJS("powerProbe.received.at(-1)?.page === 'settings'")
      _ = try await panel.js("document.querySelector('[data-section=\"displays\"]').click()")
      _ = try await panel.js("document.querySelector('[data-key=\"display-primary-playlist\"] > summary').click()")
      try await panel.waitJS("document.querySelector('[data-key=\"display-primary-playlist-mode-row\"]').getClientRects().length > 0")
      let row = "document.querySelector('[data-key=\"display-primary-playlist-held-row\"]')"
      let note = "document.querySelector('[data-key=\"display-primary-playlist\"] .settings-disclosure-title .settings-note')"
      try await panel.expectJS("return \(row) === null", equals: true)
      try await panel.expectJS("return \(note) === null", equals: true)

      var resumed: [String] = []
      panel.playlists.resumeHandler = { resumed.append($0) }
      panel.playlists.setHold(.removedWallpaper, on: "primary")
      try await panel.waitJS("\(row) !== null")
      let rowTexts = """
        [\(row).querySelector('.settings-label').firstChild.textContent, \(row).querySelector('button').textContent,
         \(note).textContent, \(row).querySelector('.settings-note').textContent]
        """
      try await panel.expectJS("return \(row).querySelector('button').disabled", equals: false)
      let english = try await texts(panel, rowTexts)

      // The same page in Chinese: every string of the row is translated, not left in English.
      _ = try await panel.js("""
        const bridge = window.webkit.messageHandlers.native;
        await window.wallpaperUI.receive(await bridge.postMessage({action:'languageSetting', value:'zh-Hans'}));
        """)
      let chinese = try await texts(panel, rowTexts)
      XCTAssertEqual(chinese.count, english.count)
      for (index, text) in chinese.enumerated() { XCTAssertNotEqual(text, english[index]) }
      _ = try await panel.js("""
        const bridge = window.webkit.messageHandlers.native;
        await window.wallpaperUI.receive(await bridge.postMessage({action:'languageSetting', value:'system'}));
        """)
      let englishLiteral = try arrayLiteral(english)
      try await panel.waitJS("JSON.stringify(\(rowTexts)) === JSON.stringify(\(englishLiteral))")

      _ = try await panel.js("\(row).querySelector('button').click()")
      try await panel.waitUntil { resumed == ["primary"] }

      // Anything that ends the wait takes the row away again.
      panel.playlists.setHold(nil, on: "primary")
      try await panel.waitJS("\(row) === null && \(note) === null")
    }
  }

  /// The How often menu offers changing on unlock beside the times: choosing it stores the
  /// trigger and takes the minutes field away, and choosing a time brings the timer back.
  func testTheHowOftenMenuOffersTheUnlockChoiceAndSelectingItStoresTheTrigger() async throws {
    try await withPanel { panel in
      installLibrary(panel)
      panel.playlists.update("primary") { $0.mode = .rotate }
      try await panel.finishWelcome()
      panel.navigation.selection = .settings
      panel.show()
      try await panel.waitJS("powerProbe.received.at(-1)?.page === 'settings'")
      _ = try await panel.js("document.querySelector('[data-section=\"displays\"]').click()")
      _ = try await panel.js("document.querySelector('[data-key=\"display-primary-playlist\"] > summary').click()")
      let menu = "document.querySelector('[data-key=\"display-primary-playlist-interval\"]')"
      let custom = "document.querySelector('[data-key=\"display-primary-playlist-custom-interval-row\"]')"
      let next = "document.querySelector('[data-key=\"display-primary-playlist-next-row\"] .settings-note')"
      try await panel.waitJS("\(menu) !== null && \(menu).getClientRects().length > 0")
      try await panel.expectJS("return [...\(menu).options].map(option => option.value).slice(-2)", equals: ["unlock", "custom"])
      let unlockOption = "[...\(menu).options].find(option => option.value === 'unlock').textContent"
      let englishOption = try await texts(panel, "[\(unlockOption)]")
      try await panel.expectJS("return \(menu).value", equals: "30")

      _ = try await panel.js("\(menu).value = 'unlock'; \(menu).dispatchEvent(new Event('change', { bubbles: true }))")
      try await panel.waitUntil { panel.playlists.playlist(for: "primary").trigger == .unlock }
      XCTAssertEqual(panel.playlists.playlist(for: "primary").interval, 30, "the interval is not rewritten")
      try await panel.waitJS("\(menu).value === 'unlock'")
      try await panel.expectJS("return \(custom) === null", equals: true)
      let englishNext = try await texts(panel, "[\(next).textContent]")

      // Another time brings the timer back, and its minutes field is not shown for a preset.
      _ = try await panel.js("\(menu).value = '60'; \(menu).dispatchEvent(new Event('change', { bubbles: true }))")
      try await panel.waitUntil { panel.playlists.playlist(for: "primary").trigger == .interval }
      XCTAssertEqual(panel.playlists.playlist(for: "primary").interval, 60)
      try await panel.waitJS("\(menu).value === '60'")
      try await panel.expectJS("return \(custom) === null", equals: true)

      // The page in Chinese names the choice and explains it, in words other than the English ones.
      panel.playlists.update("primary") { $0.trigger = .unlock }
      _ = try await panel.js("""
        const bridge = window.webkit.messageHandlers.native;
        await window.wallpaperUI.receive(await bridge.postMessage({action:'languageSetting', value:'zh-Hans'}));
        """)
      try await panel.waitJS("\(menu).value === 'unlock'")
      let chineseChoice = try await texts(panel, "[\(menu).selectedOptions[0].textContent, \(next).textContent]")
      XCTAssertNotEqual(chineseChoice[0], englishOption[0])
      XCTAssertNotEqual(chineseChoice[1], englishNext[0])
      _ = try await panel.js("""
        const bridge = window.webkit.messageHandlers.native;
        await window.wallpaperUI.receive(await bridge.postMessage({action:'languageSetting', value:'system'}));
        """)
    }
  }

  func testRecentHistoryEscapesTitlesAndClearsOnlyTheTargetDisplay() async throws {
    try await withPanel { panel in
      installLibrary(panel)
      panel.store.history.recordSwitch(from: "a", to: "b", on: "primary")
      panel.store.history.recordSwitch(from: "b", to: "c", on: "primary")
      panel.store.history.recordSwitch(from: "d", to: "a", on: "secondary")
      panel.store.monitorInformationSnapshot.rows = [BridgeMonitorInfoRow(
        displayId: "primary", title: "Primary", wallpaperId: "c", wallpaperTitle: "c",
        mirrorTargetDisplayId: nil, mirrorTargetTitle: nil, scalingMode: "fill", targetFps: "30", audioResponse: false)]
      try await panel.finishWelcome()
      panel.show()
      try await panel.waitJS("document.querySelector('[data-action=\"previousWallpaper\"]')?.disabled === false")
      _ = try await panel.js("document.querySelector('[data-action=\"openHistory\"]').click()")
      try await panel.waitJS("!document.getElementById('history-popover').hidden && document.querySelectorAll('.history-item').length === 3")
      try await panel.expectJS("return [...document.querySelectorAll('.history-item')].map(item => item.dataset.id)", equals: ["c", "b", "a"])
      try await panel.expectJS("return document.querySelector('.history-item[data-id=\"c\"]').getAttribute('aria-current')", equals: "true")
      try await panel.expectJS("return document.querySelector('.history-item[data-id=\"b\"] .history-title').textContent", equals: "B <img src=x onerror=alert(1)>")
      try await panel.expectJS("return document.querySelectorAll('#history-popover img').length", equals: 0)
      _ = try await panel.js("document.querySelector('#history-popover [data-action=\"historyClear\"]').click()")
      try await panel.waitUntil { panel.store.history.entries["primary"] == nil }
      try await panel.waitJS("document.querySelectorAll('.history-item').length === 0 && document.querySelector('[data-action=\"previousWallpaper\"]').disabled")
      XCTAssertEqual(panel.store.history.recent(on: "secondary", available: ["a", "d"]), ["a", "d"])
      _ = try await panel.js("document.querySelector('#history-popover [data-action=\"closePopover\"]').click()")
      try await panel.waitJS("document.getElementById('history-popover').hidden")
      try await panel.expectJS("return document.activeElement.dataset.action", equals: "openHistory")
    }
  }
}
