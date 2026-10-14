import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import XCTest

@testable import WallpaperMachine

/// Shared fixture for the offscreen control-panel suites: a `BridgeStore` over a snapshot-only
/// bridge, a `WebPanelController` driven through its real `WKWebView` without a window, and the
/// synthetic GIF frames the Discover previews are tested with.
@MainActor
class ControlPanelTestCase: XCTestCase {
  func makeStore(supportPrompt: SupportPromptStore? = nil) -> (store: BridgeStore, bridge: LayoutSnapshotBridge) {
    let bridge = LayoutSnapshotBridge(noPointer: .init())
    let store = BridgeStore(bridge: bridge, supportPrompt: supportPrompt)
    store.settingsSnapshot.displays = [
      BridgeDisplaySettingsRow(
        displayId: "primary",
        title: String(
          repeating: "Studio Display — 外接显示器 with a very long display name · ", count: 8),
        enabled: true, mode: .standalone, mirrorTargets: [], selectedMirrorTarget: nil,
        scalingMode: .fill, scalingFactor: 1, targetFps: 30, maxFps: 60, muted: false, volume: 1
      )
    ]
    return (store, bridge)
  }

  func withPanel(
    displayTitles: DisplayTitleResolver = .renderer, supportPrompt: SupportPromptStore? = nil,
    spaces: WallpaperSpaceMonitor? = nil,
    _ body: (PanelFixture) async throws -> Void
  ) async throws {
    let fixture = makeStore(supportPrompt: supportPrompt)
    let panel = try PanelFixture(
      store: fixture.store, bridge: fixture.bridge, displayTitles: displayTitles, spaces: spaces)
    do {
      try await panel.start()
      try await body(panel)
    } catch {
      await panel.shutdown()
      throw error
    }
    await panel.shutdown()
  }

  /// `closing`, when given, is the brightness of a last frame shown for a fiftieth of a second
  /// between seconds-long frames of `brightness`.
  static func gif(frames: Int, brightness: Double, closing: Double? = nil) throws -> Data {
    let output = NSMutableData()
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithData(output, UTType.gif.identifier as CFString, frames, nil))
    for frame in 0..<frames {
      let context = try XCTUnwrap(
        CGContext(
          data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.setFillColor(gray: frame == frames - 1 ? closing ?? brightness : brightness, alpha: 1)
      context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
      let delay = closing == nil ? 0.1 : frame == frames - 1 ? 0.02 : 1.0
      let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]]
      CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), properties as CFDictionary)
    }
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return output as Data
  }
}

class LayoutSnapshotBridge: WallpaperBridge {
  var snapshot: BridgeSnapshotBundle?
  @MainActor var options: [String: BridgeWallpaperOptionsSnapshot] = [:]
  @MainActor var optionRequests: [String] = []
  @MainActor var failedOptionIDs = Set<String>()
  @MainActor var holdOptions = false
  @MainActor var pendingOptions: [CheckedContinuation<BridgeWallpaperOptionsSnapshot, Error>] = []
  /// Settings writes the panel commits; a provider stands in for the engine's reply.
  @MainActor var batteryModeCalls: [BridgeBatteryMode] = []
  @MainActor var renderScaleCalls: [Float] = []
  @MainActor var frameRateCapCalls: [UInt32?] = []
  @MainActor var hostStartupCalls: [(display: UInt32, wallpaper: String, revision: UInt64, admission: UInt64?, ready: Bool)] = []
  @MainActor var bundleProvider: (@MainActor () -> BridgeSnapshotBundle)?
  /// Wallpapers the panel asked to release from the load journal's hold, in order.
  @MainActor var releaseHeldCalls: [String] = []
  /// What a release throws instead of answering, for a test that needs the bridge to refuse it.
  @MainActor var releaseHeldFailure: Error?
  /// The label-language lists the app sent, in order. `onLabelLanguages` runs when one arrives,
  /// as the bridge's own relabelling would, and `failLabelLanguages` makes the request fail.
  @MainActor var labelLanguageCalls: [[String]] = []
  @MainActor var onLabelLanguages: (@MainActor ([String]) -> Void)?
  @MainActor var failLabelLanguages = false

  override func setLabelLanguages(locales: [String]) async throws {
    try await recordLabelLanguages(locales)
  }

  /// The wallpapers the panel asked to restore every default for, in order. `restoreAllProvider`
  /// answers with the state the engine would report afterwards.
  @MainActor var restoreAllCalls: [String] = []
  @MainActor var restoreAllProvider: (@MainActor (String) -> BridgeWallpaperMutationBundle)?

  override func restoreAllPropertyDefaults(wallpaperId: String) async throws
    -> BridgeWallpaperMutationBundle
  {
    try await restoreAll(wallpaperId)
  }

  @MainActor private func restoreAll(_ id: String) throws -> BridgeWallpaperMutationBundle {
    restoreAllCalls.append(id)
    guard let provider = restoreAllProvider else { throw CancellationError() }
    return provider(id)
  }

  @MainActor private func recordLabelLanguages(_ locales: [String]) throws {
    labelLanguageCalls.append(locales)
    if failLabelLanguages { throw CancellationError() }
    onLabelLanguages?(locales)
  }
  /// Scale-factor edits the panel sends, in order.
  @MainActor var scalingFactorCalls: [(wallpaperId: String, displayId: String, factor: Double)] = []
  /// Stands in for the engine's reply to a scale-factor edit. Without one the usual bundle is
  /// returned, which needs the wallpaper's options in the snapshot.
  @MainActor var scalingFactorReply: (@MainActor (_ wallpaperId: String, _ displayId: String, _ factor: Double) throws -> BridgeWallpaperMutationBundle)?

  override func setBatteryMode(mode: BridgeBatteryMode) async throws -> BridgeSnapshotBundle {
    try await reply { $0.batteryModeCalls.append(mode) }
  }

  override func setRenderScale(scale: Float) async throws -> BridgeSnapshotBundle {
    try await reply { $0.renderScaleCalls.append(scale) }
  }

  override func setFrameRateCap(cap: UInt32?) async throws -> BridgeSnapshotBundle {
    try await reply { $0.frameRateCapCalls.append(cap) }
  }

  override func reportHostWallpaperStartup(displayId: UInt32, wallpaperId: String,
    startupRevision: UInt64, nativeAdmissionKey: UInt64?, ready: Bool) async throws -> BridgeSnapshotBundle {
    try await reply {
      $0.hostStartupCalls.append((displayId, wallpaperId, startupRevision, nativeAdmissionKey, ready))
    }
  }

  override func releaseHeldWallpaper(wallpaperId: String) async throws -> BridgeSnapshotBundle {
    try await releaseReply(wallpaperId)
  }

  @MainActor private func releaseReply(_ wallpaperId: String) throws -> BridgeSnapshotBundle {
    releaseHeldCalls.append(wallpaperId)
    if let releaseHeldFailure { throw releaseHeldFailure }
    return try reply { _ in }
  }

  override func editScalingFactor(wallpaperId: String, displayId: String, factor: Double) async throws -> BridgeWallpaperMutationBundle {
    try await recordScalingFactor(wallpaperId: wallpaperId, displayId: displayId, factor: factor)
  }

  @MainActor private func recordScalingFactor(wallpaperId: String, displayId: String, factor: Double) throws -> BridgeWallpaperMutationBundle {
    scalingFactorCalls.append((wallpaperId, displayId, factor))
    if let scalingFactorReply { return try scalingFactorReply(wallpaperId, displayId, factor) }
    guard let bundle = bundleProvider?() ?? snapshot, let options = bundle.wallpaperOptions else { throw CancellationError() }
    return BridgeWallpaperMutationBundle(
      app: bundle.app, library: bundle.library, wallpaperOptions: options,
      monitorInformation: bundle.monitorInformation, settings: bundle.settings)
  }

  @MainActor private func reply(_ record: @MainActor (LayoutSnapshotBridge) -> Void) throws -> BridgeSnapshotBundle {
    record(self)
    guard let bundle = bundleProvider?() ?? snapshot else { throw CancellationError() }
    return bundle
  }

  override func wallpaperOptionsSnapshot(wallpaperId: String) async throws -> BridgeWallpaperOptionsSnapshot {
    try await option(wallpaperId)
  }

  @MainActor private func option(_ id: String) async throws -> BridgeWallpaperOptionsSnapshot {
    optionRequests.append(id)
    if holdOptions {
      return try await withCheckedThrowingContinuation { pendingOptions.append($0) }
    }
    guard !failedOptionIDs.contains(id), let value = options[id] else { throw CancellationError() }
    return value
  }

  @MainActor func finishOption(_ value: BridgeWallpaperOptionsSnapshot) {
    pendingOptions.removeFirst().resume(returning: value)
  }

  /// How many times the store re-read every snapshot from the bridge.
  var snapshotReads = 0

  override func allSnapshots() async throws -> BridgeSnapshotBundle {
    snapshotReads += 1
    guard let snapshot else { throw CancellationError() }
    return snapshot
  }

  /// A rescan of the library answers with whatever `bundleProvider` (or `snapshot`) holds.
  override func refreshLibrary() async throws -> BridgeSnapshotBundle {
    try await reply { _ in }
  }
}

final class PanelUpdateClient: AppUpdateClient, @unchecked Sendable {
  var release: GitHubRelease?
  var fetchCalls = 0
  var downloadCalls = 0

  func fetchLatestRelease() async throws -> GitHubRelease? {
    fetchCalls += 1
    return release
  }

  func download(
    _ asset: GitHubReleaseAsset, to destination: URL,
    progress: @escaping @Sendable (Int64, Int64, Int64) -> Void
  ) async throws {
    downloadCalls += 1
    progress(asset.size, asset.size, 0)
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("dmg".utf8).write(to: destination)
  }

  /// A release body in the shape `scripts/release_notes.py --release-body` writes.
  static let notesBody = """
    ### Fixed

    - **scene** — Stop a crash ([`bbb2222`](https://github.com/o/r/commit/bbb2222))

    Plus 2 documentation, test and tooling commits.

    **Full changelog**: https://github.com/o/r/compare/v1.0.0...v1.1.0

    \(ReleaseNotes.boundary)

    ### Install

    1. Open `WallpaperMachine-1.1.0-arm64.dmg` and drag WallpaperMachine to Applications.
    """

  static func release(version: String, notes: String = "") -> GitHubRelease {
    GitHubRelease(
      version: SemanticVersion(version)!,
      htmlURL: URL(
        string: "https://github.com/bobbyhuang-dev/WallpaperMachine/releases/tag/v\(version)")!,
      prerelease: false,
      assets: [
        GitHubReleaseAsset(
          name: "WallpaperMachine-\(version)-arm64.dmg",
          downloadURL: URL(
            string:
              "https://github.com/bobbyhuang-dev/WallpaperMachine/releases/download/v\(version)/WallpaperMachine-\(version)-arm64.dmg"
          )!,
          size: 1_000, digest: nil)
      ], notes: notes)
  }
}

final class PanelUpdateInstaller: AppUpdateInstalling, @unchecked Sendable {
  var canInstallInPlace = true
  var installCalls = 0
  func prepareInstallation(archive: URL) async throws -> URL { archive }
  func install(extractedApp: URL, replacing destination: URL) throws -> any AppUpdateInstallationTask {
    installCalls += 1
    return Installation()
  }
  private struct Installation: AppUpdateInstallationTask {
    func cancel() async -> Bool { true }
  }
}

struct UnavailableRuntime: SteamCMDRuntimeProviding {
  func resolve(executable: URL) throws -> SteamCMDRuntime {
    throw WorkshopFailure(message: "fixture")
  }
  func prepare(executable: URL, staging: URL) async throws -> URL {
    throw WorkshopFailure(message: "fixture")
  }
  func validate(at root: URL) async throws { throw WorkshopFailure(message: "fixture") }
}

@MainActor
final class PanelFixture {
  final class Visibility { var visible = false }
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("panel-power-\(UUID().uuidString)")
  let store: BridgeStore
  let bridge: LayoutSnapshotBridge
  let navigation = ControlPanelNavigation()
  let visibility = Visibility()
  let defaults: UserDefaults
  let previousHome: String?
  let workshop: WorkshopStore
  /// Answers from fixtures: a three-work ranking whose works have two pages, and a one-frame
  /// GIF for every image, so no panel test reaches pixiv. `PixivFixtures.session` signs in as
  /// "Tester", and R-18 rankings answer that session only.
  let pixiv: PixivStore
  /// Stands in for the keychain; signing in never opens a window unless a test says what the
  /// window would answer through `controller.signInToPixiv`.
  let pixivSessions = PixivMemorySessionStore()
  let theme: AppThemeStore
  /// The feature stores the panel edits, each over this fixture's own defaults, library and
  /// support folder, so no test reaches the app's shared instances.
  let playlists: PlaylistStore
  let automations: WallpaperAutomationStore
  let spaces: WallpaperSpaceMonitor
  let collections: WallpaperCollectionStore
  let presets: WallpaperPresetStore
  let backup: WallpaperBackupStore
  let imagePlacement: StillImagePlacementStore
  let compatibility: WallpaperCompatibilityStore
  /// What the backup file panels would answer; nil declines, as Cancel does.
  let pickers = PanelPickers()
  let controller: WebPanelController
  var web: WKWebView
  let executable: URL
  /// `ClientPaths.libraryURL` while this fixture's home is in effect.
  let library: URL

  init(store: BridgeStore, bridge: LayoutSnapshotBridge, displayTitles: DisplayTitleResolver,
    pixivTransport: (any PixivTransport)? = nil, spaces: WallpaperSpaceMonitor? = nil,
    letterbox: VideoLetterboxStore? = nil) throws {
    self.store = store
    self.bridge = bridge
    library = root.appendingPathComponent("Library", isDirectory: true)
    let suite: String
    (defaults, suite) = TemporaryDefaults.makeForCurrentTest()
    defaults.set(root.appendingPathComponent("missing").path, forKey: "WallpaperMachineSteamCMDPath")
    previousHome = ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_HOME"]
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    executable = root.appendingPathComponent("steamcmd")
    // A download prints its password prompt and blocks until `advance` appears; a sign-in-only
    // session (no `+workshop_download_item`) reads the password, records it and signs in.
    try Data("""
      #!/bin/sh
      mode=signin
      for argument in "$@"; do [ "$argument" = +workshop_download_item ] && mode=download; done
      printf 'Password:\\n'
      if [ "$mode" = signin ]; then
        IFS= read -r password
        printf '%s' "$password" > "\(root.path)/password"
        printf 'Waiting for user info...OK\\n'
        if [ -f "\(root.path)/ownership" ]; then
          cat "\(root.path)/ownership"
        else
          printf 'License packageID 12345:\\n - State : Active( flags 512 )\\n - Apps : 431960, (1 in total)\\n'
        fi
        exit 0
      fi
      while [ ! -e "\(root.path)/advance" ]; do /bin/sleep 0.02; done
      printf 'Downloading item 222\\n'
      IFS= read -r hold

      """.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    setenv("WALLPAPER_MACHINE_HOME", root.path, 1)
    let downloader = WorkshopDownloadManager(
      sessionDirectory: root.appendingPathComponent("session"), runtimeProvider: PanelRuntime())
    workshop = WorkshopStore(
      downloader: downloader, supportDirectory: root, defaults: defaults,
      runtimeProvider: PanelRuntime(), sceneAssetsAvailable: { _ in false })
    let image = try ControlPanelTestCase.gif(frames: 1, brightness: 0.6)
    let transport = PixivFixtureTransport(respondingToSession: { url, session in
      if url.host == "i.pximg.net" { return image }
      if url.path.hasSuffix("/pages") {
        return PixivFixtures.pages(workID: Int(url.pathComponents.dropLast().last ?? "") ?? 0, count: 2)
      }
      if url.path == "/touch/ajax/user/self/status" {
        return PixivFixtures.status(signedIn: session == PixivFixtures.session)
      }
      if url.query?.contains("_r18") == true, session != PixivFixtures.session { throw PixivFixtures.forbidden }
      return PixivFixtures.ranking([
        PixivFixtures.rankingEntry(.init(id: 301, pages: 2), rank: 1),
        PixivFixtures.rankingEntry(.init(id: 302, sexual: 1), rank: 2),
        PixivFixtures.rankingEntry(.init(id: 303, pages: 2), rank: 3),
      ])
    })
    pixiv = PixivStore(
      service: PixivService(transport: pixivTransport ?? transport, minimumInterval: .zero),
      packager: PixivWallpaperPackager(library: library),
      sessions: pixivSessions)
    let visibility = self.visibility
    theme = AppThemeStore(defaults: defaults)
    playlists = PlaylistStore(defaults: defaults)
    automations = WallpaperAutomationStore(defaults: defaults)
    self.spaces = spaces ?? WallpaperSpaceMonitor()
    collections = WallpaperCollectionStore(defaults: defaults)
    presets = WallpaperPresetStore(
      defaults: defaults, managed: ManagedUserAssetStore(root: root.appendingPathComponent("UserAssets")))
    let pickers = self.pickers
    backup = WallpaperBackupStore(
      service: WallpaperBackupService(supportRoot: root), defaults: defaults, domainName: suite,
      exportDestination: { await pickers.exportBackup() }, restoreSource: { await pickers.restoreBackup() })
    imagePlacement = StillImagePlacementStore(defaults: defaults, library: library)
    let sceneAssets = root.appendingPathComponent("SceneAssets", isDirectory: true)
    compatibility = WallpaperCompatibilityStore(
      service: WallpaperCompatibilityService(
        libraryURL: library, assetsURL: { sceneAssets }))
    controller = WebPanelController(
      store: store, navigation: navigation, workshop: workshop, pixiv: pixiv,
      isPresentationVisible: { visibility.visible }, theme: theme, displayTitles: displayTitles,
      defaults: defaults,
      assets: WebPanelAssets(
        pixivThumbnailCache: WorkshopThumbnailCache(
          directory: root.appendingPathComponent("pixiv-thumbnails"), fetcher: PreviewFetcher { _ in image })),
      appLanguage: .english(), playback: PlaybackPreferences(defaults: defaults), playlists: playlists,
      hotKeys: HotKeyPreferences(defaults: defaults), collections: collections, presets: presets,
      backup: backup, imagePlacement: imagePlacement, compatibility: compatibility, letterbox: letterbox,
      automations: automations, spaces: self.spaces)
    controller.signInToPixiv = { nil }
    web = controller.makeWebView()
    web.setFrameSize(NSSize(width: 960, height: 640))
  }

  func start() async throws {
    try await waitUntil(timeout: 15) { self.controller.isReady && !self.workshop.steamCMDSetup.isBusy }
    try await quiet()
    // Native "ready" only acknowledges the message. The page can still reject its first
    // snapshot, so require a real render and report its error before any feature flow begins.
    try await waitJS("""
      (() => {
        const error = document.getElementById('error-banner');
        if (error && !error.hidden) throw new Error(`Panel startup failed: ${error.textContent.trim()}`);
        return Boolean(document.querySelector('.tabs [aria-current="page"]'));
      })()
      """)
    try await installRecorder()
  }

  func finishWelcome() async throws {
    _ = try await js("""
      const welcome = document.getElementById('welcome');
      if (!welcome.hidden) {
        welcome.querySelector('[data-action="go"][data-step="5"]').click();
        welcome.querySelector('[data-action="finish"]').click();
      }
      """)
    try await waitJS("document.getElementById('welcome').hidden")
    try await quiet()
  }

  func installRecorder() async throws {
    _ = try await js("""
      window.powerProbe = {received:[], active:0, maxActive:0, pending:[], hold:false, measureWire:false, wire:[]};
      const receive = window.wallpaperUI.receive;
      window.wallpaperUI.receive = state => {
        const probe = window.powerProbe;
        probe.active++;
        probe.maxActive = Math.max(probe.maxActive, probe.active);
        probe.received.push(state);
        if (probe.measureWire) probe.wire.push({
          bytes:new TextEncoder().encode(JSON.stringify(state)).byteLength,
          hasLibrary:Array.isArray(state.wallpapers), revision:state.libraryRevision,
          count:state.wallpapers?.length ?? null
        });
        const finish = () => { const result = receive(state); probe.active--; return result; };
        if (probe.hold) return new Promise(resolve => probe.pending.push(() => resolve(finish())));
        return finish();
      };
      """)
  }

  /// The sign-in-only job once the guide has started it.
  func waitForSignIn() async throws -> WorkshopDownload {
    try await waitUntil(timeout: 5) { self.workshop.downloader.signIn != nil }
    return try XCTUnwrap(workshop.downloader.signIn)
  }

  func show() { visibility.visible = true; controller.scheduleUpdate() }
  func hide() { visibility.visible = false; controller.scheduleUpdate() }

  func js(_ script: String) async throws -> Any? {
    XCTAssertNil(web.window, "Every panel behavior check must remain offscreen")
    let generation = controller.pageGeneration
    do {
      return try await web.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
    } catch {
      // Tie JavaScript failures to the document they ran in. AppKit run-loop errors during
      // native view teardown are separate and do not pass through this catch.
      let webView = controller.webView === web ? "current" : "replaced"
      throw WorkshopFailure(
        message: "JavaScript call failed: \(error) (page generation \(generation) → "
          + "\(controller.pageGeneration), ready \(controller.isReady), web view \(webView), "
          + "visible \(visibility.visible))")
    }
  }

  func expectJS<T: Equatable>(
    _ script: String, equals expected: T, file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    let actual = try await js(script) as? T
    XCTAssertEqual(actual, expected, file: file, line: line)
  }

  func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
      guard Date() < deadline else { throw WorkshopFailure(message: "Panel fixture timed out") }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  func waitJS(_ condition: String) async throws {
    let deadline = Date().addingTimeInterval(2)
    while try await js("return Boolean(\(condition))") as? Bool != true {
      guard Date() < deadline else { throw WorkshopFailure(message: "Page did not satisfy: \(condition)") }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  func quiet() async throws { try await Task.sleep(for: .milliseconds(120)) }

  /// What the bridge answers the next time the store reads every snapshot: the store's own
  /// snapshots with `settings` swapped in.
  func reportFromBridge(_ settings: BridgeSettingsSnapshot) {
    bridge.snapshot = BridgeSnapshotBundle(
      app: store.appSnapshot, library: store.librarySnapshot, wallpaperOptions: nil,
      monitorInformation: store.monitorInformationSnapshot, settings: settings)
  }

  func configureDisplays() {
    store.settingsSnapshot.displays = ["primary", "secondary"].map { id in
      BridgeDisplaySettingsRow(
        displayId: id, title: id, enabled: true, mode: .standalone, mirrorTargets: [],
        selectedMirrorTarget: nil, scalingMode: .fill, scalingFactor: 1,
        targetFps: 30, maxFps: 60, muted: false, volume: 1)
    }
    store.monitorInformationSnapshot.rows = [
      ("primary", "first"), ("secondary", "second"),
    ].map { display, wallpaper in
      BridgeMonitorInfoRow(
        displayId: display, title: display, wallpaperId: wallpaper, wallpaperTitle: wallpaper,
        mirrorTargetDisplayId: nil, mirrorTargetTitle: nil, scalingMode: "fill",
        targetFps: "30", audioResponse: false)
    }
    for (display, id, fps, volume) in [
      ("primary", "first", UInt32(24), Float(0.2)),
      ("secondary", "second", UInt32(48), Float(0.7)),
    ] {
      bridge.options[id] = BridgeSnapshotFixtures.options(
        wallpaperId: id, title: id,
        displayConfigurations: [
          BridgeDisplayConfigRow(
            displayId: display, title: display, enabled: true, scalingMode: .fill,
            scalingFactor: 1, framing: .centered, targetFps: fps, maxFps: 60, muted: false,
            volume: volume, dirty: false, canRestoreDefaults: false)
        ], audioResponseEnabled: false, volume: volume)
    }
    store.wallpaperOptionsSnapshot = bridge.options["first"]
    store.snapshotRevision &+= 1
  }

  func shutdown() async {
    hide()
    let inFlightPush = controller.updateTask
    _ = try? await js("""
      if (window.powerProbe) {
        powerProbe.hold = false;
        while (powerProbe.pending.length) powerProbe.pending.shift()();
      }
      """)
    controller.stop()
    compatibility.select(nil)
    for pending in bridge.pendingOptions { pending.resume(throwing: CancellationError()) }
    bridge.pendingOptions.removeAll()
    await inFlightPush?.value
    await workshop.downloader.shutdown()
    await workshop.steamCMDSetup.shutdown()
    await pixiv.downloads.shutdown()
    if let previousHome { setenv("WALLPAPER_MACHINE_HOME", previousHome, 1) }
    else { unsetenv("WALLPAPER_MACHINE_HOME") }
    try? FileManager.default.removeItem(at: root)
  }
}

final class PreviewFetcher: WorkshopThumbnailFetching, @unchecked Sendable {
  private let lock = NSLock()
  private let respond: @Sendable (URL) throws -> Data
  private let delay: @Sendable (URL) -> Duration
  private var recorded: [URL] = []
  var requests: [URL] { lock.withLock { recorded } }

  init(
    delay: @escaping @Sendable (URL) -> Duration = { _ in .zero },
    respond: @escaping @Sendable (URL) throws -> Data
  ) {
    self.delay = delay
    self.respond = respond
  }

  func fetch(_ url: URL) async throws -> Data {
    lock.withLock { recorded.append(url) }
    let wait = delay(url)
    if wait > .zero { try await Task.sleep(for: wait) }
    return try respond(url)
  }
}

struct PanelRuntime: SteamCMDRuntimeProviding {
  func resolve(executable: URL) throws -> SteamCMDRuntime {
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
      throw SteamCMDSetupIssue(kind: .invalidSelection, detail: "Missing local fixture")
    }
    return SteamCMDRuntime(rootURL: executable.deletingLastPathComponent(), executableURL: executable)
  }
  func prepare(executable: URL, staging: URL) async throws -> URL { executable }
  func validate(at root: URL) async throws {}
}

/// The native file panels of the backup card, answered by a test instead of a window.
@MainActor
final class PanelPickers {
  /// Where Export… writes the package; nil is the save panel's Cancel.
  var exportBackup: () async -> URL? = { nil }
  /// The package Choose backup… opens; nil is the open panel's Cancel.
  var restoreBackup: () async -> URL? = { nil }
}
