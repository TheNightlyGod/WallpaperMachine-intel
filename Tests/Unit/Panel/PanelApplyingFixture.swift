import XCTest

@testable import WallpaperMachine

extension PanelTestCase {
  /// A started panel over `DisplayTransferTestBridge`, which really selects, applies and ejects:
  /// wallpaper `a` on `primary`, `b` on `secondary` and `c` on neither, all installed in the
  /// fixture's library. `log` collects the store's activation log lines.
  func withApplyingPanel(
    supportPrompt: SupportPromptStore? = nil,
    _ body: (PanelFixture, DisplayTransferTestBridge, ReapplyLog) async throws -> Void
  ) async throws {
    let bridge = DisplayTransferTestBridge(noPointer: .init())
    let store = BridgeStore(bridge: bridge, supportPrompt: supportPrompt)
    let log = ReapplyLog()
    store.activationLogWriter = { line, isFailure in log.add(line, isFailure: isFailure) }
    let panel = try PanelFixture(store: store, bridge: bridge, displayTitles: .renderer)
    do {
      try bridge.installProjects(in: panel.library)
      try await store.refreshAllAsync()
      try await panel.start()
      try await body(panel, bridge, log)
    } catch {
      await panel.shutdown()
      throw error
    }
    await panel.shutdown()
  }
}
