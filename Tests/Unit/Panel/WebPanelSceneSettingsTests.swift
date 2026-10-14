import AppKit
import WebKit
import XCTest

@testable import WallpaperMachine

/// The panel half of whole-scene on-demand updating, the scene renderer choice,
/// and the managed-asset storage row.
///
/// Two things are worth a permanent test here. The dispatcher must refuse a
/// renderer name the Rust side would also refuse, rather than substituting
/// Compatibility behind the user's back. And the live status the page renders
/// must keep `unknown` — a scene that is running and could not be read — apart
/// from `continuous`, `user_paused` and `policy_suspended`. Collapsing those is
/// the round-6 failure repeated: an absent reading dressed up as a real state.
@MainActor
final class WebPanelSceneSettingsTests: XCTestCase {
  func testSceneOnDemandDefaultsOffAndRoundTripsThroughTheEngine() async throws {
    let context = try Context()
    defer { context.tearDown() }
    context.store.settingsSnapshot = BridgeSnapshotFixtures.settings()

    let shipped = try XCTUnwrap(context.controller.snapshot()["settings"] as? [String: Any])
    XCTAssertEqual(
      shipped["sceneOnDemand"] as? Bool, false,
      "Stopping a scene's tick ships off; a page rendering it on would invert the default")

    try await context.controller.perform("setting", body: ["key": "sceneOnDemand", "value": true])

    XCTAssertEqual(context.bridge.sceneOnDemand, [true])
    let on = try XCTUnwrap(context.controller.snapshot()["settings"] as? [String: Any])
    XCTAssertEqual(
      on["sceneOnDemand"] as? Bool, true,
      "The page must re-render from the snapshot the engine returned, not from the click")

    try await context.controller.perform("setting", body: ["key": "sceneOnDemand", "value": false])
    XCTAssertEqual(context.bridge.sceneOnDemand, [true, false])
  }

  func testNonBooleanSceneOnDemandValueIsRefused() async throws {
    let context = try Context()
    defer { context.tearDown() }

    do {
      try await context.controller.perform("setting", body: ["key": "sceneOnDemand", "value": 1])
      XCTFail("A numeric value must not be accepted for a switch")
    } catch {}
    XCTAssertTrue(context.bridge.sceneOnDemand.isEmpty)
  }

  func testUnknownSceneRendererIsRefusedInsteadOfSilentlyDefaulting() async throws {
    let context = try Context()
    defer { context.tearDown() }

    for rejected in ["metal", "native_preferred", "NativeMetalPreferred", ""] {
      do {
        try await context.controller.perform(
          "setting", body: ["key": "sceneRenderer", "value": rejected])
        XCTFail("An unrecognised renderer name must not be applied: \(rejected)")
      } catch {}
    }
    XCTAssertTrue(
      context.bridge.sceneRenderers.isEmpty,
      "A rejected name must not fall back to Compatibility behind the user's back")

    try await context.controller.perform(
      "setting", body: ["key": "sceneRenderer", "value": "native_metal_preferred"])
    XCTAssertEqual(context.bridge.sceneRenderers, ["native_metal_preferred"])
    let applied = try XCTUnwrap(context.controller.snapshot()["settings"] as? [String: Any])
    XCTAssertEqual(applied["sceneRenderer"] as? String, "native_metal_preferred")
  }

  func testSceneUpdateModesKeepUnknownApartFromEveryRealState() throws {
    let context = try Context()
    defer { context.tearDown() }
    context.store.settingsSnapshot = BridgeSnapshotFixtures.settings(
      sceneUpdateModes: [
        BridgeSceneUpdateModeReport(
          displayId: 1, displayName: "Display 1", wallpaperId: "forest", wallpaperTitle: "Forest",
          mode: "waiting_for_event", reasons: []),
        BridgeSceneUpdateModeReport(
          displayId: 2, displayName: "Display 2", wallpaperId: "rain", wallpaperTitle: "Rain",
          mode: "continuous", reasons: ["video", "audio_response"]),
        BridgeSceneUpdateModeReport(
          displayId: 3, displayName: "Display 3", wallpaperId: "city", wallpaperTitle: "City",
          mode: "user_paused", reasons: []),
        BridgeSceneUpdateModeReport(
          displayId: 4, displayName: "Display 4", wallpaperId: "dunes", wallpaperTitle: "Dunes",
          mode: "policy_suspended", reasons: []),
        BridgeSceneUpdateModeReport(
          displayId: 5, displayName: "Display 5", wallpaperId: "sea", wallpaperTitle: "Sea",
          mode: "unknown", reasons: ["unknown_input"]),
        BridgeSceneUpdateModeReport(
          displayId: 6, displayName: "Display 6", wallpaperId: "ice", wallpaperTitle: "Ice",
          mode: "stopped_after_failure", reasons: []),
      ])

    let settings = try XCTUnwrap(context.controller.snapshot()["settings"] as? [String: Any])
    let rows = try XCTUnwrap(settings["sceneUpdateModes"] as? [[String: Any]])

    XCTAssertEqual(
      rows.map { $0["mode"] as? String },
      [
        "waiting_for_event", "continuous", "user_paused", "policy_suspended", "unknown",
        "stopped_after_failure",
      ],
      "Each state has to survive the trip intact; an unreadable scene must not become continuous, "
        + "and a failure must not become a pause")
    XCTAssertEqual(rows[0]["display"] as? String, "Display 1")
    XCTAssertEqual(rows[1]["reasons"] as? [String], ["video", "audio_response"])
    XCTAssertEqual(
      rows[4]["reasons"] as? [String], ["unknown_input"],
      "An input the renderer could not account for is the whole diagnosis and must reach the page")

    context.store.settingsSnapshot = BridgeSnapshotFixtures.settings()
    let empty = try XCTUnwrap(context.controller.snapshot()["settings"] as? [String: Any])
    XCTAssertEqual(
      (empty["sceneUpdateModes"] as? [[String: Any]])?.isEmpty, true,
      "No scene running is an empty list, which the page words differently from unknown")
  }

  /// Retry reloads a scene on its display, so the page can only name a display that can run
  /// one: a live physical id of an enabled display. Anything else is a stale or forged
  /// request, and nothing may be ejected for it.
  func testSceneRetryRejectsAnUnknownDisplayId() async throws {
    try await withRetryPanel { panel, bridge in
      let invalid: [Any] = [99, -7, 7.5, "7", true, NSNull(), 4_294_967_296.0]
      for rejected in invalid {
        do {
          try await panel.controller.perform("sceneRetry", body: ["displayId": rejected])
          XCTFail("A display id that names no live display must be refused: \(rejected)")
        } catch {}
      }
      do {
        try await panel.controller.perform("sceneRetry", body: [:])
        XCTFail("A retry that names no display must be refused")
      } catch {}

      bridge.eligible = ["secondary"]
      try await panel.store.refreshAllAsync()
      do {
        try await panel.controller.perform("sceneRetry", body: ["displayId": 7])
        XCTFail("A display that is switched off has nothing to retry")
      } catch {}

      XCTAssertEqual(bridge.events, [], "A refused retry must not take a wallpaper off any display")
    }
  }

  /// The one row that reads "stopped after a rendering failure" carries the control, and
  /// pressing it reloads that wallpaper on that display and no other. The page and the native
  /// side are both real here, so the id the button carries is the one the dispatcher resolves.
  func testSceneRetryRunsTheReloadForAKnownDisplay() async throws {
    try await withRetryPanel { panel, bridge in
      _ = try await panel.js("document.querySelector('[data-section=\"performance\"]').click()")
      let read = try await panel.js("""
        return [...document.querySelectorAll('[data-key="scene-update-report"] li')].map(item => ({
          text: [...item.childNodes].filter(node => node.nodeType === Node.TEXT_NODE)
            .map(node => node.textContent).join('').trim(),
          retry: [...item.querySelectorAll('button')].map(button => `${button.dataset.action} ${button.dataset.args}`),
        }));
        """)
      let rows = try XCTUnwrap(read as? [[String: Any]])

      XCTAssertEqual(rows.count, 2)
      XCTAssertEqual(rows[0]["text"] as? String, "Display 7 — a: stopped after a rendering failure")
      XCTAssertEqual(
        rows[0]["retry"] as? [String], [#"sceneRetry {"displayId":7}"#],
        "A scene that stopped after a failure offers Retry, naming its display")
      XCTAssertEqual(
        rows[1]["retry"] as? [String], [],
        "A scene that is running has nothing to retry")

      _ = try await panel.js(
        "document.querySelector('[data-key=\"scene-update-report\"] [data-action=\"sceneRetry\"]').click()")
      try await panel.waitUntil(timeout: 10) { bridge.events.count == 2 }

      XCTAssertEqual(
        bridge.events, ["eject primary a", "apply primary a"],
        "Display 7 is the panel's primary display; display 8 keeps its wallpaper untouched")
      XCTAssertEqual(bridge.assignments, ["primary": "a", "secondary": "a"])
      XCTAssertNil(panel.controller.actionError)
    }
  }

  /// A display that mirrors another presents a scene of its own and can stop drawing like any
  /// other, but holds no assignment: nothing can be ejected from it. Its Retry reloads the
  /// display it mirrors, which is the only place that wallpaper can be taken off and applied.
  func testSceneRetryOnAMirroringDisplayReloadsTheDisplayItMirrors() async throws {
    try await withRetryPanel(mirroring: true) { panel, bridge in
      _ = try await panel.js("document.querySelector('[data-section=\"performance\"]').click()")
      let read = try await panel.js("""
        return [...document.querySelectorAll('[data-key="scene-update-report"] li')].map(item => ({
          retry: [...item.querySelectorAll('button')].map(button => `${button.dataset.action} ${button.dataset.args}`),
        }));
        """)
      let rows = try XCTUnwrap(read as? [[String: Any]])
      XCTAssertEqual(
        rows.map { $0["retry"] as? [String] }, [[], [#"sceneRetry {"displayId":8}"#]],
        "The stopped scene is the mirror's, and it offers Retry")

      _ = try await panel.js(
        "document.querySelector('[data-key=\"scene-update-report\"] [data-action=\"sceneRetry\"]').click()")
      try await panel.waitUntil(timeout: 10) { bridge.events.count == 2 }

      XCTAssertEqual(
        bridge.events, ["eject primary a", "apply primary a"],
        "Display 8 mirrors the primary display, so the wallpaper is reloaded there and never ejected from the mirror")
      XCTAssertEqual(bridge.assignments, ["primary": "a"])
      XCTAssertNil(panel.controller.actionError)
    }
  }

  /// A reload in progress disables the control instead of letting a second one queue up.
  func testRetryIsDisabledWhileTheReloadRuns() async throws {
    try await withRetryPanel { panel, bridge in
      _ = try await panel.js("document.querySelector('[data-section=\"performance\"]').click()")
      var release: CheckedContinuation<Void, Never>?
      bridge.beforeApply = {
        bridge.beforeApply = nil
        await withCheckedContinuation { release = $0 }
      }
      _ = try await panel.js(
        "document.querySelector('[data-key=\"scene-update-report\"] [data-action=\"sceneRetry\"]').click()")
      try await panel.waitUntil(timeout: 10) { release != nil }

      try await panel.waitJS(
        "document.querySelector('[data-key=\"scene-update-report\"] [data-action=\"sceneRetry\"]').disabled")
      release?.resume()
      try await panel.waitUntil(timeout: 10) { bridge.events.count == 2 }
      try await panel.waitJS(
        "!document.querySelector('[data-key=\"scene-update-report\"] [data-action=\"sceneRetry\"]').disabled")
    }
  }

  /// A real panel over a two-display bridge that applies and ejects for real. Both displays
  /// show wallpaper `a`; display 7 (the primary) reports a scene that stopped drawing and
  /// display 8 one that is running. With `mirroring`, display 8 shows the primary's wallpaper
  /// by mirroring it, and it is display 8 whose scene stopped.
  private func withRetryPanel(
    mirroring: Bool = false,
    _ body: (PanelFixture, DisplayTransferTestBridge) async throws -> Void
  ) async throws {
    let bridge = DisplayTransferTestBridge(noPointer: .init())
    bridge.assignments = mirroring ? ["primary": "a"] : ["primary": "a", "secondary": "a"]
    bridge.mirrors = mirroring ? ["secondary": "primary"] : [:]
    bridge.physicalIDs = ["primary": 7, "secondary": 8]
    bridge.sceneUpdateModes = [
      BridgeSceneUpdateModeReport(
        displayId: 7, displayName: "Display 7", wallpaperId: "a", wallpaperTitle: "a",
        mode: mirroring ? "continuous" : "stopped_after_failure", reasons: mirroring ? ["video"] : []),
      BridgeSceneUpdateModeReport(
        displayId: 8, displayName: "Display 8", wallpaperId: "a", wallpaperTitle: "a",
        mode: mirroring ? "stopped_after_failure" : "continuous", reasons: mirroring ? [] : ["video"]),
    ]
    let store = BridgeStore(bridge: bridge)
    let panel = try PanelFixture(store: store, bridge: bridge, displayTitles: .renderer)
    do {
      try bridge.installProjects(in: panel.library)
      try await store.refreshAllAsync()
      try await panel.start()
      try await panel.finishWelcome()
      panel.navigation.selection = .settings
      panel.show()
      try await panel.waitJS("powerProbe.received.at(-1)?.page === 'settings'")
      try await body(panel, bridge)
    } catch {
      await panel.shutdown()
      throw error
    }
    await panel.shutdown()
  }

  func testSceneRendererReportNamesTheBackendInUseAndOnlyRealFallbacks() throws {
    let context = try Context()
    defer { context.tearDown() }
    context.store.settingsSnapshot = BridgeSnapshotFixtures.settings(
      sceneRenderer: "native_metal_preferred",
      sceneRenderers: [
        BridgeSceneBackendReport(
          displayId: 1, displayName: "Display 1", wallpaperId: "forest", wallpaperTitle: "Forest",
          backend: "native_metal", fallbackReason: nil, videoPath: "none",
          optimizationApplied: true),
        BridgeSceneBackendReport(
          displayId: 2, displayName: "Display 2", wallpaperId: "rain", wallpaperTitle: "Rain",
          backend: "legacy_vulkan", fallbackReason: "the scene uses a puppet", videoPath: "none",
          optimizationApplied: true),
        BridgeSceneBackendReport(
          displayId: 3, displayName: "Display 3", wallpaperId: "sea", wallpaperTitle: "Sea",
          backend: "unknown", fallbackReason: nil, videoPath: "none",
          optimizationApplied: true),
      ])

    let settings = try XCTUnwrap(context.controller.snapshot()["settings"] as? [String: Any])
    let rows = try XCTUnwrap(settings["sceneRenderers"] as? [[String: Any]])

    XCTAssertEqual(rows[0]["backend"] as? String, "native_metal")
    XCTAssertNil(
      rows[0]["fallbackReason"] as? String,
      "A scene that got what was asked for did not fall back")
    XCTAssertEqual(rows[1]["backend"] as? String, "legacy_vulkan")
    XCTAssertEqual(rows[1]["fallbackReason"] as? String, "the scene uses a puppet")
    XCTAssertEqual(
      rows[2]["backend"] as? String, "unknown",
      "A backend the renderer could not name must not be shown as the preference")
    XCTAssertNotEqual(
      rows[2]["backend"] as? String, settings["sceneRenderer"] as? String,
      "Reporting the preference as the backend in use would make a preference look like evidence")
  }

  /// The path a scene's video textures took is a read-back, and so is whether
  /// the scene optimisation setting has actually reached that scene. Both have
  /// to arrive as their own values: reporting the saved preference in their
  /// place is what would make a preference look like evidence.
  func testSceneRendererReportCarriesTheVideoPathAndTheAppliedSetting() throws {
    let context = try Context()
    defer { context.tearDown() }
    context.store.settingsSnapshot = BridgeSnapshotFixtures.settings(
      sceneOptimizationEnabled: true,
      sceneRenderer: "native_metal_preferred",
      sceneRenderers: [
        BridgeSceneBackendReport(
          displayId: 1, displayName: "Display 1", wallpaperId: "forest", wallpaperTitle: "Forest",
          backend: "native_metal", fallbackReason: nil, videoPath: "nv12_direct",
          optimizationApplied: true),
        BridgeSceneBackendReport(
          displayId: 2, displayName: "Display 2", wallpaperId: "rain", wallpaperTitle: "Rain",
          backend: "native_metal", fallbackReason: nil, videoPath: "nv12_converted",
          optimizationApplied: false),
        BridgeSceneBackendReport(
          displayId: 3, displayName: "Display 3", wallpaperId: "sea", wallpaperTitle: "Sea",
          backend: "legacy_vulkan", fallbackReason: "the scene uses a puppet", videoPath: "none",
          optimizationApplied: nil),
      ])

    let settings = try XCTUnwrap(context.controller.snapshot()["settings"] as? [String: Any])
    let rows = try XCTUnwrap(settings["sceneRenderers"] as? [[String: Any]])

    XCTAssertEqual(rows[0]["videoPath"] as? String, "nv12_direct")
    XCTAssertEqual(rows[1]["videoPath"] as? String, "nv12_converted")
    XCTAssertEqual(
      rows[2]["videoPath"] as? String, "none",
      "A scene with no video says none rather than reporting a path it never took")
    XCTAssertEqual(rows[0]["optimizationApplied"] as? Bool, true)
    XCTAssertEqual(
      rows[1]["optimizationApplied"] as? Bool, false,
      "A change that has not reached a scene yet must be visible as not yet applied")
    XCTAssertNil(
      rows[2]["optimizationApplied"] as? Bool,
      "A scene the renderer could not answer for is unknown, which is not the same as applied")
  }

  /// No GPU backend exists until the scene has been read and one has been
  /// chosen, so a report without a backend is a phase the user can see rather
  /// than a reading that failed. It must reach the page as its own value,
  /// carrying no fallback reason, and the fell-back row next to it must carry
  /// the renderer's own reason: those are the two rows the page words
  /// differently from one another and from the saved preference.
  func testPreparingAndFellBackScenesReachThePageAsDistinctRows() throws {
    let context = try Context()
    defer { context.tearDown() }
    context.store.settingsSnapshot = BridgeSnapshotFixtures.settings(
      sceneRenderer: "native_metal_preferred",
      sceneRenderers: [
        BridgeSceneBackendReport(
          displayId: 1, displayName: "Display 1", wallpaperId: "sea", wallpaperTitle: "Sea",
          backend: "unknown", fallbackReason: nil, videoPath: "none",
          optimizationApplied: true),
        BridgeSceneBackendReport(
          displayId: 2, displayName: "Display 2", wallpaperId: "rain", wallpaperTitle: "Rain",
          backend: "legacy_vulkan", fallbackReason: "the scene uses a puppet", videoPath: "none",
          optimizationApplied: true),
        BridgeSceneBackendReport(
          displayId: 3, displayName: "Display 3", wallpaperId: "dunes", wallpaperTitle: "Dunes",
          backend: "legacy_vulkan", fallbackReason: nil, videoPath: "none",
          optimizationApplied: true),
      ])

    let settings = try XCTUnwrap(context.controller.snapshot()["settings"] as? [String: Any])
    let rows = try XCTUnwrap(settings["sceneRenderers"] as? [[String: Any]])

    XCTAssertEqual(rows.count, 3, "A scene still choosing a backend is a running scene")
    XCTAssertEqual(rows[0]["backend"] as? String, "unknown")
    XCTAssertTrue(
      rows[0]["fallbackReason"] is NSNull,
      "Nothing has been chosen yet, so nothing has fallen back")
    XCTAssertEqual(rows[0]["display"] as? String, "Display 1")
    XCTAssertEqual(rows[0]["wallpaperTitle"] as? String, "Sea")

    XCTAssertEqual(rows[1]["backend"] as? String, "legacy_vulkan")
    XCTAssertEqual(
      rows[1]["fallbackReason"] as? String, "the scene uses a puppet",
      "The renderer's own reason is the only one the page may show")

    XCTAssertEqual(rows[2]["backend"] as? String, rows[1]["backend"] as? String)
    XCTAssertTrue(
      rows[2]["fallbackReason"] is NSNull,
      "A fallback the renderer gave no reason for must not acquire an invented one")
    XCTAssertNotEqual(
      rows[0]["backend"] as? String, rows[1]["backend"] as? String,
      "Preparing and Compatibility are different answers and must stay different values")
  }

  func testStoragePublishesTheManagedAssetDirectory() throws {
    let context = try Context()
    defer { context.tearDown() }
    context.store.settingsSnapshot = BridgeSnapshotFixtures.settings(
      userAssetsPath: "/Users/someone/Library/Application Support/app/UserAssets")

    let settings = try XCTUnwrap(context.controller.snapshot()["settings"] as? [String: Any])

    XCTAssertEqual(
      settings["userAssetsPath"] as? String,
      "/Users/someone/Library/Application Support/app/UserAssets")
    XCTAssertTrue(
      settings["userAssetsReleasedBytes"] is NSNull,
      "No purge has run; that is not the same answer as a purge that released nothing")

    context.controller.userAssetsReleasedBytes = 0
    let afterEmptyPurge = try XCTUnwrap(
      context.controller.snapshot()["settings"] as? [String: Any])
    XCTAssertEqual(
      afterEmptyPurge["userAssetsReleasedBytes"] as? UInt64, 0,
      "A purge that found nothing reports zero, which must not be published as never-run")
  }

  func testSceneInspectorShowsMediaIntegration() async throws {
    let context = try Context()
    defer { context.tearDown() }
    let web = context.controller.makeWebView()
    web.setFrameSize(NSSize(width: 960, height: 640))
    let deadline = Date().addingTimeInterval(15)
    while !context.controller.isReady && Date() < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertTrue(context.controller.isReady)
    guard context.controller.isReady else { return }
    XCTAssertNil(web.window)
    _ = try await web.callAsyncJavaScript("""
      document.querySelector('#welcome [data-action="go"][data-step="5"]').click();
      document.querySelector('#welcome [data-action="finish"]').click();
      """, arguments: [:], in: nil, contentWorld: .page)
    let base =
      try await web.callAsyncJavaScript(
        "return await window.webkit.messageHandlers.native.postMessage({action:'ready'})",
        arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
    let payload = try XCTUnwrap(base)
    context.controller.stop()

    let result =
      try await web.callAsyncJavaScript(
        """
        const waitFor = async predicate => {
          const deadline = Date.now() + 5000;
          while (!predicate()) {
            if (Date.now() > deadline) throw new Error('The inspector did not settle');
            await new Promise(resolve => setTimeout(resolve, 20));
          }
        };
        window.wallpaperUI.receive(Object.assign({}, base, {
          page: 'installed', selectedID: 'scene-1',
          wallpapers: [{ id: 'scene-1', title: 'Scene one', kind: 'Scene', preview: null, active: true, supported: true, tags: [] }],
          options: { id: 'scene-1', kind: 'Scene', supported: true, dirty: false, volume: 0.5, muted: false,
            audioResponseEnabled: true, mediaIntegrationEnabled: false, displays: [], properties: [] }
        }));
        await waitFor(() => document.querySelector('#inspector [data-setting="mediaIntegrationEnabled"]'));
        return {
          mediaToggle: document.querySelector('#inspector [data-setting="mediaIntegrationEnabled"]') !== null,
          mediaChecked: document.querySelector('#inspector [data-setting="mediaIntegrationEnabled"]').checked,
        };
        """, arguments: ["base": payload], in: nil, contentWorld: .page)
      as? [String: Any]
    let page = try XCTUnwrap(result)
    XCTAssertEqual(page["mediaToggle"] as? Bool, true)
    XCTAssertEqual(page["mediaChecked"] as? Bool, false)
    XCTAssertNil(web.window, "This check must stay offscreen")
  }

  @MainActor
  private final class Context {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "panel-scene-\(UUID().uuidString)")
    let bridge = SceneRecordingBridge(noPointer: .init())
    let store: BridgeStore
    let defaults: UserDefaults
    let workshop: WorkshopStore
    let controller: WebPanelController

    init() throws {
      store = BridgeStore(bridge: bridge)
      defaults = TemporaryDefaults.makeForCurrentTest().defaults
      workshop = WorkshopStore(
        downloader: WorkshopDownloadManager(sessionDirectory: root), supportDirectory: root,
        defaults: defaults)
      controller = WebPanelController(
        store: store, navigation: ControlPanelNavigation(), workshop: workshop, defaults: defaults,
        appLanguage: .english())
      bridge.snapshots = { [store] in
        BridgeSnapshotBundle(
          app: store.appSnapshot, library: store.librarySnapshot, wallpaperOptions: nil,
          monitorInformation: store.monitorInformationSnapshot, settings: store.settingsSnapshot)
      }
    }

    func tearDown() {
      controller.stop()
      try? FileManager.default.removeItem(at: root)
    }
  }
}

private final class SceneRecordingBridge: WallpaperBridge {
  @MainActor var snapshots: (() -> BridgeSnapshotBundle)?
  @MainActor var sceneOnDemand: [Bool] = []
  @MainActor var sceneRenderers: [String] = []

  /// Both overrides return the setting applied, the way the engine does: a
  /// double that returned the old value could not tell acceptance from a
  /// silently dropped click.
  override func setSceneOnDemandEnabled(enabled: Bool) async throws -> BridgeSnapshotBundle {
    var bundle = await record { $0.sceneOnDemand.append(enabled) }
    bundle.settings.sceneOnDemandEnabled = enabled
    return bundle
  }

  override func setSceneRenderer(mode: String) async throws -> BridgeSnapshotBundle {
    var bundle = await record { $0.sceneRenderers.append(mode) }
    bundle.settings.sceneRenderer = mode
    return bundle
  }

  @MainActor private func record(_ note: @MainActor (SceneRecordingBridge) -> Void)
    -> BridgeSnapshotBundle
  {
    note(self)
    guard let snapshots else { fatalError("The fixture must publish a snapshot") }
    return snapshots()
  }
}

/// The wallpaper inspector's view of where a file or directory property's asset
/// actually lives. App-managed and external reference are different situations
/// for the user, and a missing asset is the only one that needs an action, so
/// the three must not collapse into a single "has a path" boolean.
@MainActor
final class WebPanelAssetProvenanceTests: XCTestCase {
  func testAssetKeysDistinguishManagedFromExternalAndPresentFromMissing() throws {
    let context = try Context()
    defer { context.tearDown() }
    let file = context.root.appendingPathComponent("chosen.png")
    try FileManager.default.createDirectory(
      at: context.root, withIntermediateDirectories: true)
    try Data([0x89, 0x50]).write(to: file)

    context.store.wallpaperOptionsSnapshot = Self.options(properties: [
      Self.property(id: "managed", value: .string(value: file.path), assetManaged: true),
      Self.property(
        id: "external", value: .string(value: file.path), assetManaged: false,
        assetSourcePath: "/Volumes/Photos/chosen.png"),
      Self.property(
        id: "gone", value: .string(value: file.path), assetManaged: true, assetMissing: true,
        assetSourcePath: "/Volumes/Photos/chosen.png"),
    ])

    let options = try XCTUnwrap(context.controller.snapshot()["options"] as? [String: Any])
    let rows = try XCTUnwrap(options["properties"] as? [[String: Any]])
    let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0["id"] as! String, $0) })

    XCTAssertEqual(byID["managed"]?["assetManaged"] as? Bool, true)
    XCTAssertEqual(byID["managed"]?["assetMissing"] as? Bool, false)
    XCTAssertNil(
      byID["managed"]?["assetSourcePath"] as? String,
      "A copied asset has no original worth showing once the copy is the truth")

    XCTAssertEqual(
      byID["external"]?["assetManaged"] as? Bool, false,
      "A reference the app does not own must not be reported as app-managed")
    XCTAssertEqual(byID["external"]?["assetMissing"] as? Bool, false)
    XCTAssertEqual(
      byID["external"]?["assetSourcePath"] as? String, "/Volumes/Photos/chosen.png",
      "The user's own path is what makes an external reference recognisable")

    XCTAssertEqual(
      byID["gone"]?["assetMissing"] as? Bool, true,
      "An asset that can no longer be resolved is the one state needing a reselect")
    XCTAssertEqual(byID["gone"]?["assetSourcePath"] as? String, "/Volumes/Photos/chosen.png")
  }

  static func property(
    id: String, value: BridgePropertyValue, assetManaged: Bool = false,
    assetMissing: Bool = false, assetSourcePath: String? = nil
  ) -> BridgePropertyDescriptor {
    BridgePropertyDescriptor(
      id: id, kind: .file, labelHtml: id, value: value, defaultValue: .empty, slider: nil,
      comboOptions: [], fileFilter: nil, directoryMode: nil, dirty: false,
      canRestoreDefaults: false, enabled: true, assetManaged: assetManaged,
      assetMissing: assetMissing, assetSourcePath: assetSourcePath)
  }

  static func options(properties: [BridgePropertyDescriptor]) -> BridgeWallpaperOptionsSnapshot {
    BridgeWallpaperOptionsSnapshot(
      wallpaperId: "scene-1", title: "Scene one", kind: .projectScene, supported: true, dirty: false,
      properties: properties, displayConfigurations: [], audioResponseEnabled: true,
      mediaIntegrationEnabled: false, muted: false, volume: 0.5)
  }

  @MainActor
  private final class Context {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "panel-provenance-\(UUID().uuidString)")
    let bridge = SceneRecordingBridge(noPointer: .init())
    let store: BridgeStore
    let defaults: UserDefaults
    let workshop: WorkshopStore
    let controller: WebPanelController

    init() throws {
      store = BridgeStore(bridge: bridge)
      defaults = TemporaryDefaults.makeForCurrentTest().defaults
      workshop = WorkshopStore(
        downloader: WorkshopDownloadManager(sessionDirectory: root), supportDirectory: root,
        defaults: defaults)
      controller = WebPanelController(
        store: store, navigation: ControlPanelNavigation(), workshop: workshop, defaults: defaults,
        appLanguage: .english())
    }

    func tearDown() {
      controller.stop()
      try? FileManager.default.removeItem(at: root)
    }
  }
}
