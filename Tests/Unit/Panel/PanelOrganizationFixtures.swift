import Foundation
import XCTest

@testable import WallpaperMachine

/// Snapshot rows for the organization suites (collections, playlists, displays, automation).
enum OrganizationFixtures {
  static func wallpaper(_ id: String, title: String? = nil, supported: Bool = true) -> BridgeWallpaperEntry {
    BridgeWallpaperEntry(
      id: id, title: title ?? id, kind: supported ? .video : .unknown, supported: supported, active: false,
      selected: false, previewPath: nil)
  }

  static func display(
    _ id: String, title: String? = nil, enabled: Bool = true, mode: BridgeDisplayMode = .standalone,
    mirrorTargets: [String] = [], selectedMirrorTarget: String? = nil, scalingMode: BridgeScalingMode = .fill,
    scalingFactor: Double = 1, targetFps: UInt32 = 30, maxFps: UInt32 = 60, muted: Bool = false,
    volume: Float = 1
  ) -> BridgeDisplaySettingsRow {
    BridgeDisplaySettingsRow(
      displayId: id, title: title ?? id, enabled: enabled, mode: mode, mirrorTargets: mirrorTargets,
      selectedMirrorTarget: selectedMirrorTarget, scalingMode: scalingMode, scalingFactor: scalingFactor,
      targetFps: targetFps, maxFps: maxFps, muted: muted, volume: volume)
  }

  static func monitor(_ display: String, wallpaper: String, mirroring source: String? = nil) -> BridgeMonitorInfoRow {
    BridgeMonitorInfoRow(
      displayId: display, title: display, wallpaperId: wallpaper, wallpaperTitle: wallpaper,
      mirrorTargetDisplayId: source, mirrorTargetTitle: source, scalingMode: "fill", targetFps: "30",
      audioResponse: false)
  }

  /// A library folder `ClientPaths` finds, which is what applying a wallpaper checks.
  static func installWebProject(_ id: String, in library: URL) throws {
    let folder = library.appendingPathComponent(id)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(#"{"type":"web","title":"Fixture","file":"index.html"}"#.utf8).write(
      to: folder.appendingPathComponent("project.json"))
    try Data("<!doctype html><title>Fixture</title>".utf8).write(to: folder.appendingPathComponent("index.html"))
  }
}

extension PanelTestCase {
  /// A started panel over `DisplayTransferTestBridge`'s two independent displays, "primary" showing
  /// wallpaper a and "secondary" showing b, with the library's projects on disk. `configure` runs
  /// before the store reads the bridge, for a test that wants mirrors or live display ids.
  func withTwoDisplayPanel(
    configure: (DisplayTransferTestBridge) -> Void = { _ in },
    _ body: (PanelFixture, DisplayTransferTestBridge) async throws -> Void
  ) async throws {
    let bridge = DisplayTransferTestBridge(noPointer: .init())
    configure(bridge)
    let store = BridgeStore(bridge: bridge)
    let panel = try PanelFixture(store: store, bridge: bridge, displayTitles: .renderer)
    do {
      try bridge.installProjects(in: panel.library)
      try await store.refreshAllAsync()
      try await panel.start()
      try await body(panel, bridge)
    } catch {
      await panel.shutdown()
      throw error
    }
    await panel.shutdown()
  }
}

/// Holds a command in the queue until a test opens it.
@MainActor
final class QueueGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func open() {
    isOpen = true
    let waiting = waiters
    waiters = []
    for waiter in waiting { waiter.resume() }
  }
}

/// A bridge for Settings › Displays: every setter the panel calls is recorded in `calls`, applied to
/// the displays and wallpaper options it holds, and answered with the snapshot the store then reads.
@MainActor
final class DisplaySettingsBridge: LayoutSnapshotBridge {
  /// Every setter that reached the bridge, in order, written as `name arguments`.
  private(set) var calls: [String] = []
  var displays: [BridgeDisplaySettingsRow] = []
  var monitorRows: [BridgeMonitorInfoRow] = []
  var wallpapers: [BridgeWallpaperEntry] = []
  /// What the engine answers a call that fails; nil answers normally.
  var failure: Error?

  private var app: BridgeAppSnapshot {
    BridgeAppSnapshot(
      playbackState: .paused, selectedWallpaperId: nil, activeWallpaperIds: [], errors: [], heldWallpaperIds: [])
  }

  private var library: BridgeLibrarySnapshot {
    BridgeLibrarySnapshot(
      wallpapers: wallpapers, scanStatus: BridgeLibraryScanStatus(scanning: false, done: 0, total: 0),
      sceneCount: 0, videoCount: UInt64(wallpapers.count), webpageCount: 0, unknownCount: 0)
  }

  private var monitorInformation: BridgeMonitorInformationSnapshot { BridgeMonitorInformationSnapshot(rows: monitorRows) }
  private var settings: BridgeSettingsSnapshot { BridgeSnapshotFixtures.settings(displays: displays) }

  private var displayBundle: BridgeDisplayMutationBundle {
    BridgeDisplayMutationBundle(app: app, library: library, monitorInformation: monitorInformation, settings: settings)
  }

  private func record(_ call: String) throws {
    calls.append(call)
    if let failure { throw failure }
  }

  private func change(_ display: String, _ edit: (inout BridgeDisplaySettingsRow) -> Void) throws {
    guard let index = displays.firstIndex(where: { $0.displayId == display }) else { throw CancellationError() }
    edit(&displays[index])
  }

  private func wallpaperBundle(_ id: String) throws -> BridgeWallpaperMutationBundle {
    guard let options = options[id] else { throw CancellationError() }
    return BridgeWallpaperMutationBundle(
      app: app, library: library, wallpaperOptions: options, monitorInformation: monitorInformation,
      settings: settings)
  }

  private func edit(_ wallpaper: String, _ change: (inout BridgeWallpaperOptionsSnapshot) -> Void) throws {
    guard var value = options[wallpaper] else { throw CancellationError() }
    change(&value)
    options[wallpaper] = value
  }

  private func editConfig(
    _ wallpaper: String, _ display: String, _ change: (inout BridgeDisplayConfigRow) -> Void
  ) throws {
    try edit(wallpaper) { options in
      guard let index = options.displayConfigurations.firstIndex(where: { $0.displayId == display }) else { return }
      change(&options.displayConfigurations[index])
    }
  }

  override func allSnapshots() async throws -> BridgeSnapshotBundle {
    BridgeSnapshotBundle(
      app: app, library: library, wallpaperOptions: nil, monitorInformation: monitorInformation,
      settings: settings)
  }

  override func refreshDisplays() async throws -> BridgeSnapshotBundle {
    try record("refreshDisplays")
    return try await allSnapshots()
  }

  override func setDisplayEnabled(displayId: String, enabled: Bool) async throws -> BridgeDisplayMutationBundle {
    try record("setDisplayEnabled \(displayId) \(enabled)")
    try change(displayId) { $0.enabled = enabled }
    return displayBundle
  }

  override func setDisplayMode(displayId: String, mode: BridgeDisplayMode) async throws -> BridgeDisplayMutationBundle {
    try record("setDisplayMode \(displayId) \(mode)")
    try change(displayId) { $0.mode = mode }
    return displayBundle
  }

  override func setMirrorTarget(displayId: String, targetDisplayId: String) async throws -> BridgeDisplayMutationBundle {
    try record("setMirrorTarget \(displayId) \(targetDisplayId)")
    try change(displayId) { $0.selectedMirrorTarget = targetDisplayId }
    return displayBundle
  }

  override func setMirrorScalingMode(displayId: String, mode: BridgeScalingMode) async throws -> BridgeDisplayMutationBundle {
    try record("setMirrorScalingMode \(displayId) \(mode)")
    try change(displayId) { $0.scalingMode = mode }
    return displayBundle
  }

  override func setMirrorScalingFactor(displayId: String, factor: Double) async throws -> BridgeDisplayMutationBundle {
    try record("setMirrorScalingFactor \(displayId) \(factor)")
    try change(displayId) { $0.scalingFactor = factor }
    return displayBundle
  }

  override func setMirrorTargetFps(displayId: String, fps: UInt32) async throws -> BridgeDisplayMutationBundle {
    try record("setMirrorTargetFps \(displayId) \(fps)")
    try change(displayId) { $0.targetFps = fps }
    return displayBundle
  }

  override func setMirrorVolume(displayId: String, volume: Float) async throws -> BridgeDisplayMutationBundle {
    try record("setMirrorVolume \(displayId) \(volume)")
    try change(displayId) { $0.volume = volume }
    return displayBundle
  }

  override func setMirrorMuted(displayId: String, muted: Bool) async throws -> BridgeDisplayMutationBundle {
    try record("setMirrorMuted \(displayId) \(muted)")
    try change(displayId) { $0.muted = muted }
    return displayBundle
  }

  override func setVolume(wallpaperId: String, volume: Float) async throws -> BridgeWallpaperMutationBundle {
    try record("setVolume \(wallpaperId) \(volume)")
    try edit(wallpaperId) { $0.volume = volume }
    return try wallpaperBundle(wallpaperId)
  }

  override func setMuted(wallpaperId: String, muted: Bool) async throws -> BridgeWallpaperMutationBundle {
    try record("setMuted \(wallpaperId) \(muted)")
    try edit(wallpaperId) { $0.muted = muted }
    return try wallpaperBundle(wallpaperId)
  }

  override func setScalingMode(
    wallpaperId: String, displayId: String, mode: BridgeScalingMode
  ) async throws -> BridgeWallpaperMutationBundle {
    try record("setScalingMode \(wallpaperId) \(displayId) \(mode)")
    try editConfig(wallpaperId, displayId) { $0.scalingMode = mode }
    return try wallpaperBundle(wallpaperId)
  }

  override func editScalingFactor(
    wallpaperId: String, displayId: String, factor: Double
  ) async throws -> BridgeWallpaperMutationBundle {
    try record("editScalingFactor \(wallpaperId) \(displayId) \(factor)")
    try editConfig(wallpaperId, displayId) { $0.scalingFactor = factor }
    return try wallpaperBundle(wallpaperId)
  }

  override func setTargetFps(
    wallpaperId: String, displayId: String, fps: UInt32
  ) async throws -> BridgeWallpaperMutationBundle {
    try record("setTargetFps \(wallpaperId) \(displayId) \(fps)")
    try editConfig(wallpaperId, displayId) { $0.targetFps = fps }
    return try wallpaperBundle(wallpaperId)
  }

  override func applyWallpaperOptions(
    wallpaperId: String, userInitiated: Bool
  ) async throws -> BridgeWallpaperMutationBundle {
    try record("applyWallpaperOptions \(wallpaperId) \(userInitiated)")
    return try wallpaperBundle(wallpaperId)
  }

  override func ejectWallpaperFromDisplay(displayId: String, wallpaperId: String) async throws -> BridgeDisplayMutationBundle {
    try record("eject \(displayId) \(wallpaperId)")
    monitorRows.removeAll { $0.displayId == displayId }
    return displayBundle
  }
}
