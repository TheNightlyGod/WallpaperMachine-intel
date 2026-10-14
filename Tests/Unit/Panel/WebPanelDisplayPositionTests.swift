import XCTest

@testable import WallpaperMachine

/// The inspector's Position sliders: the requests the page sends, the fields the snapshot gives
/// it, and the controls it draws, against a bridge that moves a display row the way the engine
/// does. Whether the wallpaper visibly moves on a display is a desktop check, not one made here.
@MainActor
final class WebPanelDisplayPositionTests: XCTestCase {
  // MARK: Requests

  func testOneAxisReachesTheBridgeAndTheOtherKeepsItsSavedValue() async throws {
    let context = Context()
    defer { context.tearDown() }

    try await context.controller.perform(
      "displayPosition", body: ["id": "scene-1", "displayID": "primary", "x": 0.25])

    XCTAssertEqual(
      context.bridge.calls,
      [.init(wallpaperID: "scene-1", displayID: "primary", panX: 0.25, panY: nil)],
      "A horizontal slider must not send the vertical position along with it")
    let row = try context.rows().first
    XCTAssertEqual(row?["panX"] as? Double, 0.25)
    XCTAssertEqual(
      row?["panY"] as? Double, 0.8,
      "The axis that was not sent keeps the value the display already had")

    try await context.controller.perform(
      "displayPosition", body: ["id": "scene-1", "displayID": "primary", "y": 0.1, "x": 0])
    XCTAssertEqual(
      context.bridge.calls.last,
      .init(wallpaperID: "scene-1", displayID: "primary", panX: 0, panY: 0.1),
      "Both axes may be sent together, and the edges of the range are positions too")
  }

  func testARequestNamingNoAxisIsRefused() async throws {
    let context = Context()
    defer { context.tearDown() }

    for body: [String: Any] in [
      ["id": "scene-1", "displayID": "primary"],
      ["id": "scene-1", "displayID": "primary", "z": 0.5],
    ] {
      await assertInvalid { try await context.controller.perform("displayPosition", body: body) }
    }
    XCTAssertTrue(context.bridge.calls.isEmpty)
  }

  func testValuesThatAreNotAFractionAreRefusedWithoutAnyBridgeCall() async throws {
    let context = Context()
    defer { context.tearDown() }
    let bad: [Any] = [-0.1, 1.1, true, "0.5", Double.nan, Double.infinity, NSNull(), [0.5]]

    for (axis, other) in [("x", "y"), ("y", "x")] {
      for value in bad {
        await assertInvalid(
          "\(axis) = \(value)",
          {
            try await context.controller.perform(
              "displayPosition",
              body: ["id": "scene-1", "displayID": "primary", axis: value, other: 0.5])
          })
      }
    }

    XCTAssertTrue(
      context.bridge.calls.isEmpty,
      "A value outside the display must be refused, not moved to the nearest edge")
    let row = try context.rows().first
    XCTAssertEqual(row?["panX"] as? Double, 0.2)
    XCTAssertEqual(row?["panY"] as? Double, 0.8)
  }

  func testOnlySceneAndVideoWallpapersOnTheirOwnDisplaysCanBeMoved() async throws {
    let context = Context()
    defer { context.tearDown() }

    for body: [String: Any] in [
      // A web page always fills its window; there is nothing to move.
      ["id": "web-1", "displayID": "primary", "x": 0.5],
      // The wallpaper has no row for this display.
      ["id": "scene-1", "displayID": "gone", "x": 0.5],
      ["id": "nope", "displayID": "primary", "x": 0.5],
      ["id": "scene-1", "x": 0.5],
    ] {
      do {
        try await context.controller.perform("displayPosition", body: body)
        XCTFail("A position for \(body) must be refused")
      } catch {}
      do {
        try await context.controller.perform("displayPositionReset", body: body)
        XCTFail("A reset for \(body) must be refused")
      } catch {}
    }
    XCTAssertTrue(context.bridge.calls.isEmpty)

    try await context.controller.perform(
      "displayPosition", body: ["id": "video-1", "displayID": "primary", "x": 0.6])
    XCTAssertEqual(context.bridge.calls.map(\.wallpaperID), ["video-1"], "A video can be moved too")
  }

  func testResetCentresBothAxesAndReportsTheChangeOnce() async throws {
    let context = Context()
    defer { context.tearDown() }
    var changes: [String] = []
    context.store.onDisplayFramingChanged = { wallpaper, display in changes.append("\(wallpaper)@\(display)") }

    try await context.controller.perform(
      "displayPositionReset", body: ["id": "scene-1", "displayID": "primary"])

    XCTAssertEqual(
      context.bridge.calls,
      [.init(wallpaperID: "scene-1", displayID: "primary", panX: 0.5, panY: 0.5)])
    XCTAssertEqual(changes, ["scene-1@primary"])
    let row = try context.rows().first
    XCTAssertEqual(row?["panX"] as? Double, 0.5)
    XCTAssertEqual(row?["panY"] as? Double, 0.5)

    context.bridge.failure = Refused()
    do {
      try await context.controller.perform(
        "displayPosition", body: ["id": "scene-1", "displayID": "primary", "x": 0.9])
      XCTFail("The bridge's refusal must reach the page")
    } catch is Refused {}
    XCTAssertEqual(changes, ["scene-1@primary"], "A move the bridge refused changed nothing to report")
    XCTAssertEqual(try context.rows().first?["panX"] as? Double, 0.5)
  }

  func testAMoveWaitsItsTurnBehindTheCommandThatIsRunning() async throws {
    let context = Context()
    defer { context.tearDown() }
    var release: CheckedContinuation<Void, Never>?
    let running = Task { @MainActor in
      await context.store.commands.run {
        await withCheckedContinuation { release = $0 }
      }
    }
    for _ in 0..<200 where release == nil { await Task.yield() }
    XCTAssertNotNil(release, "The first command must be running before the move is sent")

    let move = Task {
      try await context.controller.perform(
        "displayPosition", body: ["id": "scene-1", "displayID": "primary", "x": 0.4])
    }
    for _ in 0..<200 where context.store.commands.waiting.isEmpty { await Task.yield() }
    XCTAssertEqual(context.store.commands.waiting.count, 1)
    XCTAssertTrue(
      context.bridge.calls.isEmpty,
      "A move that arrives mid-activation must not reach the engine ahead of it")

    release?.resume()
    _ = await running.value
    try await move.value
    XCTAssertEqual(context.bridge.calls.map(\.panX), [0.4])
  }

  // MARK: Drag previews

  func testAPreviewShowsThePositionAndNeitherSavesItNorReportsAMove() async throws {
    let context = Context()
    defer { context.tearDown() }
    var changes: [String] = []
    context.store.onDisplayFramingChanged = { wallpaper, display in changes.append("\(wallpaper)@\(display)") }

    try await context.controller.perform(
      "displayPositionPreview", body: ["id": "scene-1", "displayID": "primary", "x": 0.25])
    try await context.controller.perform(
      "displayPositionPreview", body: ["id": "video-1", "displayID": "primary", "y": 0, "x": 1])

    XCTAssertEqual(
      context.bridge.previews,
      [
        .init(wallpaperID: "scene-1", displayID: "primary", panX: 0.25, panY: nil),
        .init(wallpaperID: "video-1", displayID: "primary", panX: 1, panY: 0),
      ],
      "Each step reaches the bridge's preview alone, with the axis it moved")
    XCTAssertTrue(context.bridge.calls.isEmpty, "A step is not a position the bridge keeps")
    XCTAssertTrue(changes.isEmpty, "Nothing was moved for good, so nothing retakes the desktop picture")
    let row = try context.rows().first
    XCTAssertEqual(row?["panX"] as? Double, 0.2)
    XCTAssertEqual(row?["panY"] as? Double, 0.8, "The page is still told where the wallpaper is saved")
  }

  func testAPreviewIsRefusedForWhatTheMoveItselfIsRefusedFor() async throws {
    let context = Context()
    defer { context.tearDown() }
    let bad: [Any] = [-0.1, 1.1, true, "0.5", Double.nan, Double.infinity, NSNull(), [0.5]]

    for value in bad {
      await assertInvalid(
        "x = \(value)",
        {
          try await context.controller.perform(
            "displayPositionPreview",
            body: ["id": "scene-1", "displayID": "primary", "x": value, "y": 0.5])
        })
    }
    for body: [String: Any] in [
      ["id": "scene-1", "displayID": "primary"],
      ["id": "scene-1", "displayID": "primary", "z": 0.5],
      ["id": "scene-1", "x": 0.5],
    ] {
      await assertInvalid { try await context.controller.perform("displayPositionPreview", body: body) }
    }
    do {
      try await context.controller.perform(
        "displayPositionPreview", body: ["id": "nope", "displayID": "primary", "x": 0.5])
      XCTFail("A wallpaper the library no longer has must be refused")
    } catch {}

    XCTAssertTrue(
      context.bridge.previews.isEmpty,
      "A value outside the display must never reach the renderer, not even as a step")
  }

  func testAFailedPreviewReachesThePageAndMovesNothing() async throws {
    let context = Context()
    defer { context.tearDown() }
    context.bridge.previewFailure = Refused()

    do {
      try await context.controller.perform(
        "displayPositionPreview", body: ["id": "scene-1", "displayID": "primary", "x": 0.4])
      XCTFail("The bridge's refusal must reach the page, which ignores it")
    } catch is Refused {}

    XCTAssertEqual(context.bridge.previews.count, 1)
    XCTAssertTrue(context.bridge.calls.isEmpty)
    XCTAssertEqual(try context.rows().first?["panX"] as? Double, 0.2)
  }

  func testAPreviewDoesNotWaitBehindTheCommandThatIsRunning() async throws {
    let context = Context()
    defer { context.tearDown() }
    var release: CheckedContinuation<Void, Never>?
    let running = Task { @MainActor in
      await context.store.commands.run {
        await withCheckedContinuation { release = $0 }
      }
    }
    for _ in 0..<200 where release == nil { await Task.yield() }
    XCTAssertNotNil(release, "The first command must be running before the step is sent")

    try await context.controller.perform(
      "displayPositionPreview", body: ["id": "scene-1", "displayID": "primary", "x": 0.4])

    XCTAssertEqual(
      context.bridge.previews.map(\.panX), [0.4],
      "A step that waited for a wallpaper switch would reach the display long after the thumb moved on")
    XCTAssertTrue(context.store.commands.waiting.isEmpty)

    release?.resume()
    _ = await running.value
  }

  // MARK: Snapshot

  func testSnapshotGivesThePageEachDisplaysPositionAndWhetherANativePlayerDrawsIt() throws {
    let context = Context()
    defer { context.tearDown() }
    let rows = [
      Self.row("primary", "Studio Display (7 - Primary)", pan: .init(panX: 0.2, panY: 0.8)),
      Self.row("identity:{\"uuid\":\"AABB\"}", "Side Display (8 - Secondary)", pan: .init(panX: 1, panY: 0)),
    ]
    context.store.wallpaperOptionsSnapshot = Self.options("video-1", .video, rows: rows)
    func report(_ wallpaper: String, display: UInt32, backend: String) -> BridgeVideoBackendReport {
      BridgeVideoBackendReport(
        displayId: display, displayName: "Display", wallpaperId: wallpaper, wallpaperTitle: wallpaper,
        backend: backend, fallbackReason: nil)
    }
    context.store.settingsSnapshot.videoBackends = [
      report("video-1", display: 7, backend: "native"),
      // Another wallpaper's native player on the second display, and this one on Compatibility.
      report("video-2", display: 8, backend: "native"),
      report("video-1", display: 8, backend: "legacy"),
    ]

    let options = try XCTUnwrap(context.controller.snapshot()["options"] as? [String: Any])
    let displays = try XCTUnwrap(options["displays"] as? [[String: Any]])

    XCTAssertEqual(displays.count, 2)
    XCTAssertEqual(displays[0]["panX"] as? Double, 0.2)
    XCTAssertEqual(displays[0]["panY"] as? Double, 0.8)
    XCTAssertEqual(displays[1]["panX"] as? Double, 1)
    XCTAssertEqual(displays[1]["panY"] as? Double, 0)
    XCTAssertEqual(
      displays.map { $0["nativePlayer"] as? Bool }, [true, false],
      "Only the display this wallpaper's native player draws on ignores a position")

    context.store.settingsSnapshot.videoBackends = []
    let none = try XCTUnwrap(context.controller.snapshot()["options"] as? [String: Any])
    XCTAssertEqual(
      (none["displays"] as? [[String: Any]])?.map { $0["nativePlayer"] as? Bool }, [false, false],
      "With no backend report, nothing says the native player is drawing")
  }

  // MARK: Page

  func testInspectorDrawsSlidersForAScenePostsOnlyTheMovedAxisAndCentres() async throws {
    try await withPositionPanel { panel, bridge in
      try await show(panel, Self.options("scene-1", .projectScene, rows: [Self.row("primary", "Studio Display (7 - Primary)")]))
      let x = "#inspector [data-change=\"displayPosition\"][data-axis=\"x\"]"
      let y = "#inspector [data-change=\"displayPosition\"][data-axis=\"y\"]"
      try await panel.waitJS("document.querySelector('\(x)') && document.querySelector('\(y)')")

      try await panel.expectJS("return document.querySelector('\(x)').value", equals: "20")
      try await panel.expectJS("return document.querySelector('\(y)').value", equals: "80")
      try await panel.expectJS(
        "return document.querySelector('\(y)').parentElement.querySelector('output').textContent",
        equals: "80%")
      try await panel.expectJS(
        "return document.querySelector('\(x)').disabled || document.querySelector('\(y)').disabled",
        equals: false)
      try await panel.expectJS(
        "return document.querySelector('#inspector [data-action=\"displayPositionReset\"]').disabled",
        equals: false)

      _ = try await panel.js("""
        const input = document.querySelector('\(x)');
        input.value = '30';
        input.dispatchEvent(new Event('input', { bubbles: true }));
        """)
      try await panel.expectJS(
        "return document.querySelector('\(x)').parentElement.querySelector('output').textContent",
        equals: "30%")
      XCTAssertTrue(bridge.calls.isEmpty, "Dragging alone sends nothing; the value is sent when the slider settles")
      _ = try await panel.js("document.querySelector('\(x)').dispatchEvent(new Event('change', { bubbles: true }))")

      try await panel.waitUntil { bridge.calls.count == 1 }
      XCTAssertEqual(
        bridge.calls,
        [.init(wallpaperID: "scene-1", displayID: "primary", panX: 0.3, panY: nil)])
      try await panel.waitJS("document.querySelector('\(x)').value === '30'")
      try await panel.expectJS("return document.querySelector('\(y)').value", equals: "80")

      _ = try await panel.js("document.querySelector('#inspector [data-action=\"displayPositionReset\"]').click()")
      try await panel.waitUntil { bridge.calls.count == 2 }
      XCTAssertEqual(bridge.calls.last?.panX, 0.5)
      XCTAssertEqual(bridge.calls.last?.panY, 0.5)
      try await panel.waitJS("document.querySelector('\(x)').value === '50' && document.querySelector('\(y)').value === '50'")
      try await panel.waitJS("document.querySelector('#inspector [data-action=\"displayPositionReset\"]').disabled")
    }
  }

  func testInspectorOffersNoSlidersForAWebWallpaper() async throws {
    try await withPositionPanel { panel, _ in
      try await show(panel, Self.options("web-1", .webpage, rows: [Self.row("primary", "Studio Display (7 - Primary)")]))
      // The Displays section is drawn, so the missing sliders are the page's choice.
      try await panel.waitJS("document.querySelector('#inspector .display-options')")
      try await panel.expectJS(
        "return document.querySelectorAll('#inspector [data-change=\"displayPosition\"], #inspector [data-action=\"displayPositionReset\"]').length",
        equals: 0)
    }
  }

  func testInspectorSaysWhenTheNativePlayerKeepsAVideoCentred() async throws {
    try await withPositionPanel { panel, _ in
      let rows = [
        Self.row("primary", "Studio Display (7 - Primary)"),
        Self.row("identity:{\"uuid\":\"AABB\"}", "Side Display (8 - Secondary)"),
      ]
      panel.store.settingsSnapshot.videoBackends = [
        BridgeVideoBackendReport(
          displayId: 7, displayName: "Studio", wallpaperId: "video-1", wallpaperTitle: "Video",
          backend: "native", fallbackReason: nil)
      ]
      try await show(panel, Self.options("video-1", .video, rows: rows))
      func block(_ display: Int) -> String {
        "#inspector .display-options:nth-of-type(\(display)) .position-rows"
      }
      try await panel.waitJS("document.querySelector('\(block(1))')")

      try await panel.expectJS(
        "return Boolean(document.querySelector('\(block(1)) [data-action=\"openPerformance\"]'))",
        equals: true)
      try await panel.expectJS(
        "return Boolean(document.querySelector('\(block(2)) [data-action=\"openPerformance\"]'))",
        equals: false)
      // The note explains; it does not take the sliders away or switch them off.
      try await panel.expectJS(
        "return [...document.querySelectorAll('\(block(1)) input[type=\"range\"]')].filter(input => !input.disabled).length",
        equals: 2)
    }
  }

  func testADragShowsTheNewestStepAtMostOnceAHundredMillisecondsThenSavesOnRelease() async throws {
    try await withPositionPanel { panel, bridge in
      try await show(panel, Self.options("scene-1", .projectScene, rows: [Self.row("primary", "Studio Display (7 - Primary)")]))
      let x = Self.slider("x")
      try await panel.waitJS("document.querySelector('\(x)')")

      // The delays the page asks its timers for while the drag is going on.
      _ = try await panel.js("""
        window.timerDelays = [];
        const setTimer = window.setTimeout.bind(window);
        window.setTimeout = (callback, delay, ...rest) => {
          window.timerDelays.push(delay);
          return setTimer(callback, delay, ...rest);
        };
        """)
      // Five steps inside one animation frame: the first is shown at once, the rest are
      // collapsed into the newest, which follows when the interval is up.
      _ = try await panel.js(Self.drag(x, [31, 32, 33, 34, 35]))

      try await panel.waitUntil { bridge.previews.count == 2 }
      XCTAssertEqual(
        bridge.previews,
        [
          .init(wallpaperID: "scene-1", displayID: "primary", panX: 0.31, panY: nil),
          .init(wallpaperID: "scene-1", displayID: "primary", panX: 0.35, panY: nil),
        ])
      let delayed = try await panel.js("return window.timerDelays.filter(delay => delay > 0 && delay <= 100).length") as? Int
      XCTAssertGreaterThanOrEqual(
        delayed ?? 0, 1,
        "The newest step waits out the interval since the last one instead of following the reply at once")
      try await Task.sleep(for: .milliseconds(300))
      XCTAssertEqual(bridge.previews.count, 2, "Nothing is sent while the thumb is still")
      XCTAssertTrue(bridge.calls.isEmpty, "Dragging saves nothing")

      _ = try await panel.js(Self.release(x))
      try await panel.waitUntil { bridge.calls.count == 1 }
      try await Task.sleep(for: .milliseconds(250))
      XCTAssertEqual(
        bridge.calls,
        [.init(wallpaperID: "scene-1", displayID: "primary", panX: 0.35, panY: nil)],
        "The release saves the value it settled on, once")
      XCTAssertEqual(bridge.previews.count, 2, "and no step follows it")
      try await panel.waitJS("document.querySelector('\(x)').value === '35'")
    }
  }

  func testReleasingBeforeTheFollowingStepCancelsItAndSavesTheNewestValue() async throws {
    try await withPositionPanel { panel, bridge in
      try await show(panel, Self.options("scene-1", .projectScene, rows: [Self.row("primary", "Studio Display (7 - Primary)")]))
      let x = Self.slider("x")
      try await panel.waitJS("document.querySelector('\(x)')")

      _ = try await panel.js(Self.drag(x, [31, 35]) + Self.release(x))

      try await panel.waitUntil { bridge.calls.count == 1 }
      try await Task.sleep(for: .milliseconds(300))
      XCTAssertEqual(bridge.calls.map(\.panX), [0.35])
      XCTAssertEqual(
        bridge.previews.map(\.panX), [0.31],
        "The step that was waiting for its turn is dropped: the release carries its value")
    }
  }

  func testTheReleaseWaitsForTheStepStillOnItsWay() async throws {
    try await withPositionPanel { panel, bridge in
      try await show(panel, Self.options("scene-1", .projectScene, rows: [Self.row("primary", "Studio Display (7 - Primary)")]))
      let x = Self.slider("x")
      try await panel.waitJS("document.querySelector('\(x)')")
      bridge.holdPreviews = true

      _ = try await panel.js(Self.drag(x, [31, 35]) + Self.release(x))
      try await panel.waitUntil { bridge.previews.count == 1 }
      try await Task.sleep(for: .milliseconds(300))

      XCTAssertTrue(
        bridge.calls.isEmpty,
        "A step the bridge has not answered could still land after the release if the release did not wait for it")
      bridge.releasePreviews()
      try await panel.waitUntil { bridge.calls.count == 1 }
      XCTAssertEqual(bridge.calls.map(\.panX), [0.35])
      XCTAssertEqual(bridge.previews.count, 1)
    }
  }

  func testADragThatEndsWhereItBeganSavesThatValueEvenThoughNoChangeFires() async throws {
    try await withPositionPanel { panel, bridge in
      try await show(panel, Self.options("scene-1", .projectScene, rows: [Self.row("primary", "Studio Display (7 - Primary)")]))
      let x = Self.slider("x")
      try await panel.waitJS("document.querySelector('\(x)')")

      // Out to 70% and back to the 20% it started at: the browser fires no change event for
      // that, so the wallpaper would stay at the last step shown unless the release settles it.
      _ = try await panel.js(Self.drag(x, [70]))
      try await panel.waitUntil { bridge.previews.count == 1 }
      _ = try await panel.js(Self.drag(x, [20], press: false))
      try await panel.waitUntil { bridge.previews.count == 2 }
      XCTAssertTrue(bridge.calls.isEmpty)
      _ = try await panel.js("document.dispatchEvent(new PointerEvent('pointerup', { bubbles: true }))")

      try await panel.waitUntil { bridge.calls.count == 1 }
      XCTAssertEqual(
        bridge.calls,
        [.init(wallpaperID: "scene-1", displayID: "primary", panX: 0.2, panY: nil)],
        "The value the slider shows is sent, so the bridge can put the scene back")
      XCTAssertEqual(bridge.previews.map(\.panX), [0.7, 0.2])
    }
  }

  func testAPointerThatIsCancelledSavesTheLastStepShownAndNothingMoreAfterIt() async throws {
    try await withPositionPanel { panel, bridge in
      try await show(panel, Self.options("scene-1", .projectScene, rows: [Self.row("primary", "Studio Display (7 - Primary)")]))
      let x = Self.slider("x")
      try await panel.waitJS("document.querySelector('\(x)')")

      _ = try await panel.js(Self.drag(x, [60]))
      try await panel.waitUntil { bridge.previews.count == 1 }
      _ = try await panel.js("document.dispatchEvent(new PointerEvent('pointercancel', { bubbles: true }))")

      try await panel.waitUntil { bridge.calls.count == 1 }
      try await Task.sleep(for: .milliseconds(250))
      XCTAssertEqual(bridge.calls.map(\.panX), [0.6])
      XCTAssertEqual(bridge.previews.count, 1)
      // The drag is over: another step on the slider without a press is a key press.
      _ = try await panel.js(Self.drag(x, [61], press: false))
      try await Task.sleep(for: .milliseconds(250))
      XCTAssertEqual(bridge.previews.count, 1)
    }
  }

  func testAKeyPressSavesAtOnceWithoutShowingAStepFirst() async throws {
    try await withPositionPanel { panel, bridge in
      try await show(panel, Self.options("scene-1", .projectScene, rows: [Self.row("primary", "Studio Display (7 - Primary)")]))
      let x = Self.slider("x")
      try await panel.waitJS("document.querySelector('\(x)')")

      // An arrow key fires input and change together, with no pointer down.
      _ = try await panel.js("""
        const input = document.querySelector('\(x)');
        input.value = '21';
        input.dispatchEvent(new Event('input', { bubbles: true }));
        input.dispatchEvent(new Event('change', { bubbles: true }));
        """)

      try await panel.waitUntil { bridge.calls.count == 1 }
      try await Task.sleep(for: .milliseconds(250))
      XCTAssertEqual(bridge.calls.map(\.panX), [0.21])
      XCTAssertTrue(bridge.previews.isEmpty, "A single step has nothing to follow")
    }
  }

  func testEachSliderOfADisplayShowsItsOwnAxisAlone() async throws {
    try await withPositionPanel { panel, bridge in
      try await show(panel, Self.options("scene-1", .projectScene, rows: [Self.row("primary", "Studio Display (7 - Primary)")]))
      let y = Self.slider("y")
      try await panel.waitJS("document.querySelector('\(y)')")

      _ = try await panel.js(Self.drag(y, [10]) + Self.release(y))

      try await panel.waitUntil { bridge.calls.count == 1 }
      XCTAssertEqual(bridge.previews, [.init(wallpaperID: "scene-1", displayID: "primary", panX: nil, panY: 0.1)])
      XCTAssertEqual(bridge.calls, [.init(wallpaperID: "scene-1", displayID: "primary", panX: nil, panY: 0.1)])
    }
  }

  // MARK: Fixtures

  private static func slider(_ axis: String) -> String {
    "#inspector [data-change=\"displayPosition\"][data-axis=\"\(axis)\"]"
  }

  /// Presses the slider (unless `press` is false) and steps it through `percentages` as
  /// consecutive input events, the way a pointer drag does.
  private static func drag(_ slider: String, _ percentages: [Int], press: Bool = true) -> String {
    """
    const slider = document.querySelector('\(slider)');
    \(press ? "slider.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, buttons: 1 }));" : "")
    for (const value of \(percentages)) {
      slider.value = String(value);
      slider.dispatchEvent(new Event('input', { bubbles: true }));
    }
    """
  }

  /// The pointer comes up, and the browser then fires the slider's change event.
  private static func release(_ slider: String) -> String {
    """
    document.dispatchEvent(new PointerEvent('pointerup', { bubbles: true }));
    document.querySelector('\(slider)').dispatchEvent(new Event('change', { bubbles: true }));
    """
  }

  private func show(_ panel: PanelFixture, _ options: BridgeWallpaperOptionsSnapshot) async throws {
    panel.store.librarySnapshot.wallpapers = [Self.entry(options.wallpaperId, options.kind)]
    panel.store.appSnapshot = .init(
      playbackState: .playing, selectedWallpaperId: options.wallpaperId, activeWallpaperIds: [],
      errors: [], heldWallpaperIds: [])
    panel.bridge.options[options.wallpaperId] = options
    panel.store.wallpaperOptionsSnapshot = options
    try await panel.finishWelcome()
    panel.show()
  }

  private func withPositionPanel(
    _ body: (PanelFixture, PositionBridge) async throws -> Void
  ) async throws {
    let bridge = PositionBridge(noPointer: .init())
    let store = BridgeStore(bridge: bridge)
    bridge.bundleProvider = { [store] in
      BridgeSnapshotBundle(
        app: store.appSnapshot, library: store.librarySnapshot, wallpaperOptions: nil,
        monitorInformation: store.monitorInformationSnapshot, settings: store.settingsSnapshot)
    }
    let panel = try PanelFixture(store: store, bridge: bridge, displayTitles: .renderer)
    do {
      try await panel.start()
      try await body(panel, bridge)
    } catch {
      await panel.shutdown()
      throw error
    }
    await panel.shutdown()
  }

  private func assertInvalid(
    _ what: String = "", _ work: () async throws -> Void, file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    do {
      try await work()
      XCTFail("Accepted \(what)", file: file, line: line)
    } catch let error as WallpaperActionError {
      XCTAssertEqual(error.message, WebPanelRequest.invalid.message, what, file: file, line: line)
    } catch {
      XCTFail("Refused \(what) with \(error)", file: file, line: line)
    }
  }

  fileprivate static func entry(_ id: String, _ kind: BridgeWallpaperKind) -> BridgeWallpaperEntry {
    BridgeWallpaperEntry(
      id: id, title: id, kind: kind, supported: true, active: false, selected: false, previewPath: nil)
  }

  fileprivate static func row(
    _ id: String, _ title: String, pan: BridgeFraming = .init(panX: 0.2, panY: 0.8)
  ) -> BridgeDisplayConfigRow {
    BridgeDisplayConfigRow(
      displayId: id, title: title, enabled: true, scalingMode: .fill, scalingFactor: 1, framing: pan,
      targetFps: 30, maxFps: 60, muted: false, volume: 1, dirty: false, canRestoreDefaults: false)
  }

  fileprivate static func options(
    _ id: String, _ kind: BridgeWallpaperKind, rows: [BridgeDisplayConfigRow]
  ) -> BridgeWallpaperOptionsSnapshot {
    BridgeSnapshotFixtures.options(
      wallpaperId: id, title: id, kind: kind, displayConfigurations: rows)
  }

  private struct Refused: Error {}

  /// The panel's controller over a store whose bridge answers like the engine, with a scene, a
  /// video and a web page installed and one display showing each.
  @MainActor
  private final class Context {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "panel-position-\(UUID().uuidString)")
    let bridge = PositionBridge(noPointer: .init())
    let store: BridgeStore
    let controller: WebPanelController

    init() {
      let defaults = TemporaryDefaults.makeForCurrentTest().defaults
      store = BridgeStore(bridge: bridge)
      let kinds: [(String, BridgeWallpaperKind)] = [
        ("scene-1", .projectScene), ("video-1", .video), ("web-1", .webpage),
      ]
      store.librarySnapshot.wallpapers = kinds.map { WebPanelDisplayPositionTests.entry($0.0, $0.1) }
      for (id, kind) in kinds {
        bridge.options[id] = WebPanelDisplayPositionTests.options(
          id, kind, rows: [WebPanelDisplayPositionTests.row("primary", "Studio Display (7 - Primary)")])
      }
      store.wallpaperOptionsSnapshot = bridge.options["scene-1"]
      bridge.bundleProvider = { [store] in
        BridgeSnapshotBundle(
          app: store.appSnapshot, library: store.librarySnapshot, wallpaperOptions: nil,
          monitorInformation: store.monitorInformationSnapshot, settings: store.settingsSnapshot)
      }
      let workshop = WorkshopStore(
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

    /// The display rows of the options the page would be given now.
    func rows() throws -> [[String: Any]] {
      let options = try XCTUnwrap(controller.snapshot()["options"] as? [String: Any])
      return try XCTUnwrap(options["displays"] as? [[String: Any]])
    }
  }
}

/// A bridge that moves a display row's position and answers with the wallpaper's options as they
/// are then, which is what the engine does; one that returned the old options could not tell a
/// move that happened from a click that was dropped.
private final class PositionBridge: LayoutSnapshotBridge {
  struct Call: Equatable {
    var wallpaperID: String
    var displayID: String
    var panX: Double?
    var panY: Double?
  }

  @MainActor var calls: [Call] = []
  /// What the next move fails with, when a test needs the bridge to refuse it.
  @MainActor var failure: Error?
  /// The positions shown for a drag in progress: they move nothing the double keeps.
  @MainActor var previews: [Call] = []
  @MainActor var previewFailure: Error?
  /// While set, a preview is received but not answered until `releasePreviews()`, which is how a
  /// test holds a step on its way.
  @MainActor var holdPreviews = false
  @MainActor private var heldPreviews: [CheckedContinuation<Void, Never>] = []

  @MainActor func releasePreviews() {
    holdPreviews = false
    let held = heldPreviews
    heldPreviews = []
    for continuation in held { continuation.resume() }
  }

  override func previewDisplayPosition(
    wallpaperId: String, displayId: String, panX: Double?, panY: Double?
  ) async throws {
    try await receivePreview(
      Call(wallpaperID: wallpaperId, displayID: displayId, panX: panX, panY: panY))
  }

  @MainActor private func receivePreview(_ call: Call) async throws {
    previews.append(call)
    if holdPreviews { await withCheckedContinuation { heldPreviews.append($0) } }
    if let previewFailure { throw previewFailure }
  }

  override func setDisplayPosition(
    wallpaperId: String, displayId: String, panX: Double?, panY: Double?
  ) async throws -> BridgeWallpaperMutationBundle {
    try await move(
      Call(wallpaperID: wallpaperId, displayID: displayId, panX: panX, panY: panY))
  }

  @MainActor private func move(_ call: Call) throws -> BridgeWallpaperMutationBundle {
    calls.append(call)
    if let failure { throw failure }
    guard var moved = options[call.wallpaperID], let base = bundleProvider?() else {
      throw CancellationError()
    }
    moved.displayConfigurations = moved.displayConfigurations.map { row in
      guard row.displayId == call.displayID else { return row }
      var row = row
      row.framing = BridgeFraming(
        panX: call.panX ?? row.framing.panX, panY: call.panY ?? row.framing.panY)
      return row
    }
    options[call.wallpaperID] = moved
    return BridgeWallpaperMutationBundle(
      app: base.app, library: base.library, wallpaperOptions: moved,
      monitorInformation: base.monitorInformation, settings: base.settings)
  }
}
