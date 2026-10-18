import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest

@testable import WallpaperMachine

/// Shared fixture for the control-panel suites: a `BridgeStore` over a snapshot-only bridge, a
/// `PanelController` over fixture stores and no window, and the synthetic GIF frames the
/// previews are tested with.
@MainActor
class PanelTestCase: XCTestCase {
  override func setUp() async throws {
    try await super.setUp()
    await AccessibilityClient.connect()
  }

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

  /// A controller over this test's own temporary home, defaults and fixture stores, not yet
  /// started. `welcomeSeen` is on by default, as a returning user's is, so nothing waits for the
  /// first-run guide. The caller owns `shutdown()`.
  func makeController(
    displayTitles: DisplayTitleResolver = .renderer, supportPrompt: SupportPromptStore? = nil,
    spaces: WallpaperSpaceMonitor? = nil, welcomeSeen: Bool = true,
    letterbox: VideoLetterboxStore? = nil
  ) throws -> PanelFixture {
    let fixture = makeStore(supportPrompt: supportPrompt)
    return try PanelFixture(
      store: fixture.store, bridge: fixture.bridge, displayTitles: displayTitles, spaces: spaces,
      welcomeSeen: welcomeSeen, letterbox: letterbox)
  }

  /// `makeController` that is started, handed to `body` and always shut down afterwards.
  func withPanel(
    displayTitles: DisplayTitleResolver = .renderer, supportPrompt: SupportPromptStore? = nil,
    spaces: WallpaperSpaceMonitor? = nil, welcomeSeen: Bool = true,
    _ body: (PanelFixture) async throws -> Void
  ) async throws {
    let panel = try makeController(
      displayTitles: displayTitles, supportPrompt: supportPrompt, spaces: spaces,
      welcomeSeen: welcomeSeen)
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

/// Whether the scene assets look installed to the Workshop store; a test flips it.
@MainActor
final class PanelSceneAssets {
  var available = false
}

/// What a test answers for the user: confirmations and pickers without a window. Nothing is
/// shown; everything asked is recorded.
@MainActor
final class RecordingDialogs: PanelDialogs {
  var presentingWindow: NSWindow?
  /// Every confirmation asked, in order.
  private(set) var confirmations: [(title: String, detail: String, button: String)] = []
  /// What every confirmation answers. Off by default: a window-less panel refuses.
  var confirmAnswer = false
  /// What the next picker answers; nil is Cancel.
  var chosenURL: URL?
  var chosenURLs: [URL] = []
  private(set) var panels: [NSSavePanel] = []

  func confirm(_ title: String, detail: String, button: String) async -> Bool {
    confirmations.append((title, detail, button))
    return confirmAnswer
  }

  func choose(_ panel: NSSavePanel) async -> URL? {
    panels.append(panel)
    return chosenURL
  }

  func chooseMany(_ panel: NSOpenPanel) async -> [URL] {
    panels.append(panel)
    return chosenURLs
  }
}

/// The controller and every store it is built over, each on this fixture's own defaults, library
/// and support folders, so no test reaches the installed app. No window is ever ordered:
/// `presentation` stands in for one (`show()` and `hide()`).
@MainActor
final class PanelFixture {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("panel-fixture-\(UUID().uuidString)")
  let store: BridgeStore
  let bridge: LayoutSnapshotBridge
  let navigation = ControlPanelNavigation()
  let presentation = PanelPresentation()
  let dialogs = RecordingDialogs()
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
  let playlists: PlaylistStore
  let automations: WallpaperAutomationStore
  let solarLocationManager = FakeSolarLocationManager()
  lazy var solarLocationTracker = SolarLocationTracker(store: automations, manager: solarLocationManager)
  let spaces: WallpaperSpaceMonitor
  /// The condition rules engaged, as the app's monitor would publish them; empty until a test sets it.
  let systemConditions = SystemConditionState()
  let collections: WallpaperCollectionStore
  let presets: WallpaperPresetStore
  let backup: WallpaperBackupStore
  let imagePlacement: StillImagePlacementStore
  let compatibility: WallpaperCompatibilityStore
  /// What the backup file panels would answer; nil declines, as Cancel does.
  let pickers = PanelPickers()
  /// Whether the scene assets are installed, as the Workshop store's readiness check sees it.
  let sceneAssets = PanelSceneAssets()
  /// The controller under test, built over the stores above on first use.
  lazy var controller: PanelController = buildController()
  let executable: URL
  /// `ClientPaths.libraryURL` while this fixture's home is in effect.
  let library: URL
  /// The one-frame GIF every fixture image request answers.
  let image: Data
  let displayTitles: DisplayTitleResolver
  /// The Black bars store a test passes in; nil lets the controller build its own.
  let letterbox: VideoLetterboxStore?

  init(store: BridgeStore, bridge: LayoutSnapshotBridge, displayTitles: DisplayTitleResolver,
    pixivTransport: (any PixivTransport)? = nil, spaces: WallpaperSpaceMonitor? = nil,
    welcomeSeen: Bool = true, letterbox: VideoLetterboxStore? = nil) throws {
    self.store = store
    self.bridge = bridge
    self.displayTitles = displayTitles
    self.letterbox = letterbox
    library = root.appendingPathComponent("Library", isDirectory: true)
    let suite: String
    (defaults, suite) = TemporaryDefaults.makeForCurrentTest()
    defaults.set(root.appendingPathComponent("missing").path, forKey: "WallpaperMachineSteamCMDPath")
    if welcomeSeen { PanelPreferences.markWelcomeSeen(in: defaults) }
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
    // Steam never answers: a page that opens Steam Workshop searches offline, as pixiv does above,
    // and an update check finds nothing.
    workshop = WorkshopStore(
      service: WorkshopService(session: OfflineSteamProtocol.session()),
      downloader: downloader, supportDirectory: root, defaults: defaults,
      runtimeProvider: PanelRuntime(), updates: OfflineSteamProtocol.updates(defaults: defaults),
      sceneAssetsAvailable: { [sceneAssets] _ in sceneAssets.available })
    let image = try PanelTestCase.gif(frames: 1, brightness: 0.6)
    self.image = image
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
    let sceneAssetsFolder = root.appendingPathComponent("SceneAssets", isDirectory: true)
    compatibility = WallpaperCompatibilityStore(
      service: WallpaperCompatibilityService(
        libraryURL: library, assetsURL: { sceneAssetsFolder }))
  }

  /// A controller over this fixture's stores. The fixture builds one on first use; a test that
  /// needs the panel reopened over the same stores builds another.
  func buildController() -> PanelController {
    let library = self.library
    let image = self.image
    let controller = PanelController(
      store: store, navigation: navigation, workshop: workshop, pixiv: pixiv,
      presentation: presentation, theme: theme, displayTitles: displayTitles, defaults: defaults,
      images: PanelImagePipeline(
        thumbnailCache: WorkshopThumbnailCache(
          directory: root.appendingPathComponent("thumbnails"), fetcher: PreviewFetcher { _ in image }),
        pixivThumbnailCache: WorkshopThumbnailCache(
          directory: root.appendingPathComponent("pixiv-thumbnails"), fetcher: PreviewFetcher { _ in image }),
        libraryThumbnailCache: WorkshopThumbnailCache(
          directory: root.appendingPathComponent("library-thumbnails"), fetcher: LibraryPreviewFetcher(root: library),
          keepsAnimation: false),
        libraryRoot: { library }),
      dialogs: dialogs,
      appLanguage: .english(), playback: PlaybackPreferences(defaults: defaults), playlists: playlists,
      hotKeys: HotKeyPreferences(defaults: defaults), collections: collections, presets: presets,
      backup: backup, imagePlacement: imagePlacement, compatibility: compatibility, letterbox: letterbox,
      automations: automations, solarLocationTracker: solarLocationTracker,
      spaces: self.spaces, systemConditions: systemConditions)
    controller.signInToPixiv = { nil }
    return controller
  }


  /// Starts the controller and waits for what opening the panel kicks off: the SteamCMD lookup.
  func start() async throws {
    controller.start()
    try await waitUntil(timeout: 15) { !self.workshop.steamCMDSetup.isBusy }
  }

  /// The sign-in-only job once the guide has started it.
  func waitForSignIn() async throws -> WorkshopDownload {
    try await waitUntil(timeout: 5) { self.workshop.downloader.signIn != nil }
    return try XCTUnwrap(workshop.downloader.signIn)
  }

  /// Shows the panel to everything gated on visibility, as a window ordered front would.
  func show() { presentation.show(); controller.refreshVisibilityGatedWork() }
  func hide() { presentation.hide(); controller.refreshVisibilityGatedWork() }

  /// Waits for a state, never a duration: the deadline only matters when the machine is slow (the
  /// full suite runs test classes side by side), so it is generous.
  /// A timeout names the waiting line, since the condition itself cannot be printed.
  func waitUntil(
    timeout: TimeInterval = 10, file: StaticString = #fileID, line: UInt = #line,
    _ condition: () -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
      guard Date() < deadline else {
        throw WorkshopFailure(message: "Panel fixture timed out waiting at \(file):\(line)")
      }
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
    solarLocationTracker.stop()
    hide()
    controller.stop()
    compatibility.select(nil)
    for pending in bridge.pendingOptions { pending.resume(throwing: CancellationError()) }
    bridge.pendingOptions.removeAll()
    await workshop.downloader.shutdown()
    await workshop.steamCMDSetup.shutdown()
    await pixiv.downloads.shutdown()
    if let previousHome { setenv("WALLPAPER_MACHINE_HOME", previousHome, 1) }
    else { unsetenv("WALLPAPER_MACHINE_HOME") }
    try? FileManager.default.removeItem(at: root)
  }
}

/// Fails every request at once, as a Mac without a network does, so a routine test that opens
/// Steam Workshop never reaches Steam (live pages are the opt-in network layer). Counts what it
/// was asked, for a test that checks nothing went out.
final class OfflineSteamProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var answered = 0

  /// The requests failed so far in this test process.
  static var requests: Int { lock.withLock { answered } }

  /// A session whose every request this protocol fails.
  static func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OfflineSteamProtocol.self]
    return URLSession(configuration: configuration)
  }

  /// An update store whose checks fail the same way.
  @MainActor
  static func updates(defaults: UserDefaults) -> WorkshopUpdateStore {
    WorkshopUpdateStore(defaults: defaults, fetch: { _ in throw URLError(.notConnectedToInternet) })
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.lock.withLock { Self.answered += 1 }
    client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
  }
  override func stopLoading() {}
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
