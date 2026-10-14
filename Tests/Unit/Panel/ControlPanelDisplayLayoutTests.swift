import AppKit
import XCTest
@testable import WallpaperMachine

@MainActor
final class ControlPanelDisplayLayoutTests: ControlPanelTestCase {
  private func withTransferPanel(_ body: (PanelFixture, DisplayTransferTestBridge) async throws -> Void) async throws {
    let bridge = DisplayTransferTestBridge(noPointer: .init())
    let store = BridgeStore(bridge: bridge)
    let panel = try PanelFixture(store: store, bridge: bridge, displayTitles: .renderer)
    do {
      try bridge.installProjects(in: panel.library)
      try await store.refreshAllAsync()
      try await panel.start()
      try await panel.finishWelcome()
      panel.navigation.selection = .settings; panel.show()
      try await panel.waitJS("powerProbe.received.at(-1)?.page === 'settings'")
      _ = try await panel.js("document.querySelector('[data-section=\"displays\"]').click()")
      try await panel.waitJS("document.querySelector('[data-action=\"layoutNew\"]').getClientRects().length > 0")
      try await body(panel, bridge)
    } catch { await panel.shutdown(); throw error }
    await panel.shutdown()
  }

  /// The Installed page with the inspector open on wallpaper "a", which only the main display shows.
  private func withInspectorPanel(_ body: (PanelFixture, DisplayTransferTestBridge) async throws -> Void) async throws {
    let bridge = DisplayTransferTestBridge(noPointer: .init())
    let store = BridgeStore(bridge: bridge)
    let panel = try PanelFixture(store: store, bridge: bridge, displayTitles: .renderer)
    do {
      try bridge.installProjects(in: panel.library)
      try await store.refreshAllAsync()
      try await panel.start()
      try await panel.finishWelcome()
      panel.navigation.selection = .wallpaper
      panel.show()
      try await panel.waitJS("document.querySelector('#inspector [data-action=\"reapplyWallpaper\"][data-id=\"a\"]')")
      try await body(panel, bridge)
    } catch { await panel.shutdown(); throw error }
    await panel.shutdown()
  }

  func testInspectorAppliesToEveryDisplayReportsAFailureAndHidesTheButtonWithOneDisplay() async throws {
    try await withInspectorPanel { panel, bridge in
      // Offered for the shown wallpaper too, since the other display can still take it.
      try await panel.expectJS("const b = document.querySelector('#inspector [data-action=\"activateAll\"]'); return Boolean(b) && !b.disabled", equals: true)

      _ = try await panel.js("document.querySelector('#wallpaper-grid [data-action=\"select\"][data-id=\"c\"]').click()")
      try await panel.waitJS("document.querySelector('#inspector [data-action=\"activateAll\"][data-id=\"c\"]')")
      bridge.failOnce = "secondary=c"; bridge.failAfterMutation = true
      _ = try await panel.js("document.querySelector('#inspector [data-action=\"activateAll\"]').click()")
      try await panel.waitJS("document.querySelector('#inspector .inspector-failure')?.textContent.trim().length > 0")
      XCTAssertEqual(bridge.assignments, ["primary": "a", "secondary": "b"], "the main display was put back")
      // Putting it back selected wallpaper a again; the panel returns to c, whose notice this is.
      try await panel.expectJS("return document.querySelector('#inspector [data-action=\"activateAll\"]')?.dataset.id", equals: "c")

      bridge.failAfterMutation = false
      _ = try await panel.js("document.querySelector('#inspector [data-action=\"activateAll\"]').click()")
      try await panel.waitUntil(timeout: 5) { bridge.assignments == ["primary": "c", "secondary": "c"] }
      try await panel.waitJS("document.querySelector('#inspector .inspector-failure') === null && document.querySelector('#inspector [data-action=\"activateAll\"]')?.disabled === true")

      // A mirror or a disabled display cannot take a wallpaper of its own: one display left, no button.
      bridge.eligible.remove("secondary")
      try await panel.store.refreshAllAsync()
      try await panel.waitJS("document.querySelector('#inspector [data-action=\"activateAll\"]') === null")
      bridge.eligible.insert("secondary")
      bridge.mirrors = ["secondary": "primary"]
      try await panel.store.refreshAllAsync()
      try await panel.waitJS("document.querySelector('#inspector [data-action=\"activateAll\"]') === null")
    }
  }

  func testSaveRenameApplyAndDeleteLayoutThroughTheRealPanel() async throws {
    try await withTransferPanel { panel, bridge in
      _ = try await panel.js("""
        document.querySelector('[data-action="layoutNew"]').click();
        const name = document.querySelector('[data-layout-name]'); name.value = 'Work <img src=x>'; name.dispatchEvent(new Event('input', { bubbles: true }));
        document.querySelector('[data-form="display-layout"]').requestSubmit();
        """)
      try await panel.waitUntil { panel.controller.displayLayouts.layouts.count == 1 }
      try await panel.waitJS("!document.querySelector('[data-layout-name]') && !document.querySelector('[data-action=\"displayLayoutApply\"]').disabled")
      XCTAssertEqual(panel.controller.displayLayouts.layouts[0].assignments.map(\.wallpaperID), ["a", "b"])
      try await panel.expectJS("return document.querySelectorAll('.settings-display-layout img').length", equals: 0)
      try await panel.expectJS("return document.querySelector('.settings-display-layout h4').textContent", equals: "Work <img src=x>")
      try await panel.expectJS("return document.activeElement.dataset.action", equals: "layoutNew")
      _ = try await panel.js("""
        document.querySelector('[data-action="layoutRename"]').click();
        const name = document.querySelector('[data-layout-name]'); name.value = 'Evening'; name.dispatchEvent(new Event('input', { bubbles: true }));
        document.querySelector('[data-form="display-layout"]').requestSubmit();
        """)
      try await panel.waitUntil { panel.controller.displayLayouts.layouts.first?.name == "Evening" }
      try await panel.waitJS("!document.querySelector('[data-layout-name]') && !document.querySelector('[data-action=\"displayLayoutApply\"]').disabled")
      try await panel.expectJS("return document.activeElement.dataset.action", equals: "layoutRename")
      bridge.assignments = ["primary": "c", "secondary": "a"]
      try await panel.store.refreshAllAsync()
      _ = try await panel.js("document.querySelector('[data-action=\"displayLayoutApply\"]').click()")
      try await panel.waitUntil { bridge.assignments == ["primary": "a", "secondary": "b"] }
      try await panel.waitJS("!document.querySelector('[data-action=\"displayLayoutApply\"]').disabled")
      _ = try await panel.js("document.querySelector('[data-action=\"layoutDeleteAsk\"]').click(); document.querySelector('[data-action=\"displayLayoutDelete\"]').click()")
      try await panel.waitUntil { panel.controller.displayLayouts.layouts.isEmpty }
      try await panel.waitJS("!document.querySelector('[data-layout-id]') && !document.querySelector('[data-action=\"layoutNew\"]').disabled")
      try await panel.expectJS("return document.activeElement.dataset.action", equals: "layoutNew")
      XCTAssertEqual(bridge.assignments, ["primary": "a", "secondary": "b"])
    }
  }

  func testCopySwapAndFailedSwapKeepFocusAndReportRecovery() async throws {
    try await withTransferPanel { panel, bridge in
      _ = try await panel.js("""
        document.querySelector('[data-key="display-transfer-primary"] > summary').click();
        const peer = document.querySelector('[data-layout-peer="primary"]'); peer.value = 'secondary'; peer.dispatchEvent(new Event('change', { bubbles: true }));
        document.querySelector('[data-key="display-transfer-primary"] [data-action="displayCopyWallpaper"]').click();
        """)
      try await panel.waitUntil { bridge.assignments["secondary"] == "a" }
      try await panel.waitJS("!document.querySelector('[data-action=\"displayCopyWallpaper\"]').disabled")
      try await panel.expectJS("return document.activeElement.closest('details').dataset.key", equals: "display-transfer-primary")
      bridge.assignments["secondary"] = "b"
      try await panel.store.refreshAllAsync()
      bridge.failOnce = "primary=b"; bridge.failAfterMutation = true
      _ = try await panel.js("document.querySelector('[data-key=\"display-transfer-primary\"] [data-action=\"displaySwapWallpapers\"]').click()")
      try await panel.waitJS("document.querySelector('.settings-layout-error')?.textContent.length > 0 && !document.querySelector('[data-action=\"displayCopyWallpaper\"]').disabled")
      XCTAssertEqual(bridge.assignments, ["primary": "a", "secondary": "b"])
      try await panel.expectJS("return document.activeElement.classList.contains('settings-layout-error')", equals: true)
      _ = try await panel.js("document.querySelector('[data-key=\"display-transfer-primary\"] [data-action=\"displaySwapWallpapers\"]').click()")
      try await panel.waitUntil { bridge.assignments == ["primary": "b", "secondary": "a"] }
    }
  }

  func testMissingDisplayDisablesSavedLayoutAndCancelRetainsKeyboardFocusInCompactLocales() async throws {
    try await withTransferPanel { panel, bridge in
      _ = try panel.controller.displayLayouts.save(name: String(repeating: "长い名称", count: 25), assignments: WallpaperDisplayTransfer.capture(panel.store.displayTransferSnapshot()))
      bridge.eligible.remove("secondary"); try await panel.store.refreshAllAsync()
      try await panel.waitJS("document.querySelector('[data-action=\"displayLayoutApply\"]')?.disabled === true")
      panel.web.setFrameSize(NSSize(width: 760, height: 640))
      for language in ["en", "zh-Hans", "ja"] {
        try await panel.controller.perform("languageSetting", body: ["value": language])
        panel.controller.scheduleUpdate()
        try await panel.waitJS("document.documentElement.lang === '\(language)'")
        try await panel.expectJS("const scroll = document.querySelector('.settings-scroll'); return scroll.scrollWidth <= scroll.clientWidth + 1", equals: true)
      }
      _ = try await panel.js("document.querySelector('[data-action=\"layoutRename\"]').click(); document.querySelector('[data-layout-name]').dispatchEvent(new KeyboardEvent('keydown', {key: 'Escape', bubbles: true}))")
      try await panel.expectJS("return document.querySelector('[data-layout-name]') === null", equals: true)
      try await panel.expectJS("return document.activeElement.dataset.action", equals: "layoutRename")
      XCTAssertEqual(bridge.assignments, ["primary": "a", "secondary": "b"])
    }
  }

  func testSavingTheLastAllowedLayoutReturnsFocusToAnEnabledAction() async throws {
    try await withTransferPanel { panel, _ in
      let assignments = try WallpaperDisplayTransfer.capture(panel.store.displayTransferSnapshot())
      for index in 1..<WallpaperDisplayLayoutStore.limit {
        try panel.controller.displayLayouts.save(name: "Layout \(index)", assignments: assignments)
      }
      try await panel.waitJS("document.querySelectorAll('[data-layout-id]').length === 63")
      _ = try await panel.js("""
        document.querySelector('[data-action="layoutNew"]').click();
        const name = document.querySelector('[data-layout-name]'); name.value = 'Last layout'; name.dispatchEvent(new Event('input', { bubbles: true }));
        document.querySelector('[data-form="display-layout"]').requestSubmit();
        """)
      try await panel.waitUntil { panel.controller.displayLayouts.layouts.count == 64 }
      try await panel.waitJS("!document.querySelector('[data-layout-name]') && document.querySelector('[data-action=\"layoutNew\"]').disabled")
      try await panel.expectJS("return document.activeElement.matches('button:not(:disabled)') && Boolean(document.activeElement.closest('[data-key=\"display-layouts\"]'))", equals: true)
    }
  }
}
