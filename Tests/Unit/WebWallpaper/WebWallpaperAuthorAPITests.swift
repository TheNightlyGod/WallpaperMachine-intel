import WebKit
import XCTest

@testable import WallpaperMachine

/// The Wallpaper Engine author APIs as a page actually sees them: audio, the
/// five media listeners, random-file requests and directory callbacks, driven
/// against a real offscreen `WKWebView`. No desktop window is created and the
/// page is never put in a window tree.
@MainActor
final class WebWallpaperAuthorAPITests: XCTestCase {
  private var project: URL!

  override func setUpWithError() throws {
    project = FileManager.default.temporaryDirectory.appendingPathComponent(
      "web-author-api-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    // Registration is driven from the test rather than from the page, so the
    // order of registration against host delivery is exact.
    try """
      <!doctype html><html><body><script>
      window.__received = {
        audio: [], status: [], properties: [], thumbnail: [], playback: [], timeline: [],
        random: [], dirAdded: [], dirRemoved: [],
      };
      </script></body></html>
      """.write(to: project.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: project)
  }

  // MARK: - audio

  func testReRegisteringTheAudioListenerNeitherDoublesDeliveryNorReopensTheTap() async throws {
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    var demands: [Bool] = []
    page.onAudioDemandChanged = { demands.append($0) }
    page.setAudioResponseEnabled(true)
    page.load()
    try await waitUntilLoaded(page)

    try await eval(page, "window.wallpaperRegisterAudioListener(b => window.__received.audio.push(b[0]));")
    try await eval(page, "window.wallpaperRegisterAudioListener(b => window.__received.audio.push(b[0]));")
    try await poll { demands == [true] }
    XCTAssertEqual(demands, [true], "a second registration replaces the first; it does not subscribe again")

    page.deliverAudio(Self.spectrum(first: 0.25))
    let delivered = try await pollState(page) { ($0["audio"] as? [Double])?.count == 1 }
    XCTAssertEqual((delivered["audio"] as? [Double])?.first, 0.25)
    try await Task.sleep(for: .milliseconds(300))
    var settled = try await state(page)
    XCTAssertEqual(
      (settled["audio"] as? [Double])?.count, 1,
      "one frame must reach the page once, not once per registration")

    try await eval(page, "window.wallpaperRegisterAudioListener(null);")
    try await poll { demands == [true, false] }
    page.deliverAudio(Self.spectrum(first: 0.5))
    try await Task.sleep(for: .milliseconds(300))
    settled = try await state(page)
    XCTAssertEqual((settled["audio"] as? [Double])?.count, 1)
  }

  func testAudioDeliveryStopsWhileSuspendedAndResumes() async throws {
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    var demands: [Bool] = []
    page.onAudioDemandChanged = { demands.append($0) }
    page.setAudioResponseEnabled(true)
    page.load()
    try await waitUntilLoaded(page)
    try await eval(page, "window.wallpaperRegisterAudioListener(b => window.__received.audio.push(b[0]));")
    try await poll { demands.last == true }

    page.setPresentationSuspended(true)
    XCTAssertEqual(demands.last, false, "a suspended page must not be fed audio")
    page.deliverAudio(Self.spectrum(first: 0.25))
    try await Task.sleep(for: .milliseconds(300))
    let suspended = try await state(page)
    XCTAssertEqual((suspended["audio"] as? [Double])?.count ?? 0, 0)

    page.setPresentationSuspended(false)
    XCTAssertEqual(demands.last, true)
    page.deliverAudio(Self.spectrum(first: 0.75))
    let resumed = try await pollState(page) { ($0["audio"] as? [Double])?.count == 1 }
    XCTAssertEqual((resumed["audio"] as? [Double])?.first, 0.75)
  }

  /// The renderer captures nothing for a wallpaper the user paused, so the page stops asking
  /// for audio and the shared pump stops polling until it plays again.
  func testUserPauseDropsAudioDemandUntilPlaybackResumes() async throws {
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    var demands: [Bool] = []
    page.onAudioDemandChanged = { demands.append($0) }
    page.setAudioResponseEnabled(true)
    page.load()
    try await waitUntilLoaded(page)
    try await eval(page, "window.wallpaperRegisterAudioListener(b => window.__received.audio.push(b[0]));")
    try await poll { demands == [true] }

    page.setPaused(true)
    XCTAssertEqual(demands, [true, false])
    page.setPaused(false)
    XCTAssertEqual(demands, [true, false, true])
  }

  func testAudioIsNotDeliveredWhileTheUserSettingIsOff() async throws {
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    var demands: [Bool] = []
    page.onAudioDemandChanged = { demands.append($0) }
    page.load()
    try await waitUntilLoaded(page)
    try await eval(page, "window.wallpaperRegisterAudioListener(b => window.__received.audio.push(b[0]));")
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertTrue(demands.isEmpty, "a page that registered must not open the tap while the setting is off")
    page.deliverAudio(Self.spectrum(first: 0.25))
    try await Task.sleep(for: .milliseconds(200))
    let ignored = try await state(page)
    XCTAssertEqual((ignored["audio"] as? [Double])?.count ?? 0, 0)

    page.setAudioResponseEnabled(true)
    try await poll { demands == [true] }
    page.deliverAudio(Self.spectrum(first: 0.25))
    _ = try await pollState(page) { ($0["audio"] as? [Double])?.count == 1 }
  }

  // MARK: - media

  func testAnUnchangedMediaStateSendsNothingAndFieldsAreIndependent() async throws {
    let page = try await mediaPage()
    page.deliverMediaEvent(slot: .properties, event: Self.properties(title: "First"))
    page.deliverMediaEvent(slot: .thumbnail, event: Self.thumbnail)
    _ = try await pollState(page) {
      ($0["properties"] as? [[String: Any]])?.count == 1 && ($0["thumbnail"] as? [[String: Any]])?.count == 1
    }

    // Same values again: the protocol fires a listener only when its own part
    // changed, so a replay of unchanged state must be silent.
    page.deliverMediaEvent(slot: .properties, event: Self.properties(title: "First"))
    page.deliverMediaEvent(slot: .thumbnail, event: Self.thumbnail)
    try await Task.sleep(for: .milliseconds(300))
    var received = try await state(page)
    XCTAssertEqual((received["properties"] as? [[String: Any]])?.count, 1)
    XCTAssertEqual((received["thumbnail"] as? [[String: Any]])?.count, 1)

    page.deliverMediaEvent(slot: .properties, event: Self.properties(title: "Second"))
    received = try await pollState(page) { ($0["properties"] as? [[String: Any]])?.count == 2 }
    XCTAssertEqual(
      (received["thumbnail"] as? [[String: Any]])?.count, 1,
      "a properties change must not re-send the artwork")
    XCTAssertEqual(
      ((received["properties"] as? [[String: Any]])?.last)?["title"] as? String, "Second")
  }

  func testAMediaListenerRegisteredLateReceivesTheCurrentStateOnce() async throws {
    let page = try await mediaPage()
    page.deliverMediaEvent(slot: .playback, event: ["state": 0])
    _ = try await pollState(page) { ($0["playback"] as? [[String: Any]])?.count == 1 }

    try await eval(page, "window.wallpaperRegisterMediaPlaybackListener(e => window.__received.playback.push(e));")
    var received = try await pollState(page) { ($0["playback"] as? [[String: Any]])?.count == 2 }
    XCTAssertEqual(((received["playback"] as? [[String: Any]])?.last)?["state"] as? Int, 0)

    // The replacement listener already holds the current state, so re-sending
    // it must still change nothing.
    page.deliverMediaEvent(slot: .playback, event: ["state": 0])
    try await Task.sleep(for: .milliseconds(300))
    received = try await state(page)
    XCTAssertEqual((received["playback"] as? [[String: Any]])?.count, 2)
  }

  func testMediaDeliveryStopsWhileSuspendedAndTheNewStateArrivesOnResume() async throws {
    let page = try await mediaPage()
    page.deliverMediaEvent(slot: .properties, event: Self.properties(title: "Before"))
    _ = try await pollState(page) { ($0["properties"] as? [[String: Any]])?.count == 1 }

    page.setPresentationSuspended(true)
    page.deliverMediaEvent(slot: .properties, event: Self.properties(title: "During"))
    try await Task.sleep(for: .milliseconds(300))
    let suspended = try await state(page)
    XCTAssertEqual(
      ((suspended["properties"] as? [[String: Any]])?.last)?["title"] as? String, "Before",
      "a suspended page must not be fed media")

    // Resume replays whatever is current, which is what the host does with the
    // relay's state; the page must then see the value it missed.
    page.setPresentationSuspended(false)
    page.deliverMediaEvent(slot: .properties, event: Self.properties(title: "During"))
    let resumed = try await pollState(page) { ($0["properties"] as? [[String: Any]])?.count == 2 }
    XCTAssertEqual(((resumed["properties"] as? [[String: Any]])?.last)?["title"] as? String, "During")
  }

  func testPlaybackConstantsAreExposedUnderBothDocumentedSpellings() async throws {
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    page.load()
    try await waitUntilLoaded(page)
    let values = try await eval(page, """
      const m = window.wallpaperMediaIntegration;
      return [m.PLAYBACK_PLAYING, m.PLAYBACK_PAUSED, m.PLAYBACK_STOPPED,
              m.playback.PLAYING, m.playback.PAUSED, m.playback.STOPPED];
      """) as? [Int]
    XCTAssertEqual(values, [0, 1, 2, 0, 1, 2])
  }

  func testStoppingThePageWithdrawsEveryDemand() async throws {
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    var audio: [Bool] = []
    var media: [WebWallpaperPage.MediaDemand] = []
    page.onAudioDemandChanged = { audio.append($0) }
    page.onMediaDemandChanged = { media.append($0) }
    page.setAudioResponseEnabled(true)
    page.setMediaIntegrationEnabled(true)
    page.load()
    try await waitUntilLoaded(page)
    try await eval(page, "window.wallpaperRegisterAudioListener(() => {});")
    try await eval(page, "window.wallpaperRegisterMediaStatusListener(() => {});")
    try await poll { audio.last == true && media.last?.consuming == true }

    page.stop()
    XCTAssertEqual(audio.last, false)
    XCTAssertEqual(media.last, WebWallpaperPage.MediaDemand())
  }

  // MARK: - random file

  func testARandomFileAnswerForAnOldDocumentIsDropped() async throws {
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    var requests: [(token: String, property: String)] = []
    page.onRandomFileRequest = { requests.append((token: $0, property: $1)) }
    page.load()
    try await waitUntilLoaded(page)
    try await requestRandomFile(page, property: "gallery")
    try await poll { requests.count == 1 }
    let stale = requests[0].token

    // A reload restarts the page's own request numbering from one, so the stale
    // answer carries an identifier the new document will also hand out.
    page.load()
    try await waitUntilLoaded(page)
    try await requestRandomFile(page, property: "gallery")
    try await poll { requests.count == 2 }
    XCTAssertNotEqual(stale, requests[1].token)

    page.deliverRandomFile(requestId: stale, property: "gallery", path: "tmp/old.png")
    try await Task.sleep(for: .milliseconds(300))
    let afterStale = try await state(page)
    XCTAssertEqual(
      (afterStale["random"] as? [[Any]])?.count ?? 0, 0,
      "the previous document's answer must not reach the new page")

    page.deliverRandomFile(requestId: requests[1].token, property: "gallery", path: "tmp/new.png")
    let answered = try await pollState(page) { ($0["random"] as? [[Any]])?.count == 1 }
    let reply = try XCTUnwrap((answered["random"] as? [[Any]])?.first)
    XCTAssertEqual(reply[0] as? String, "gallery")
    XCTAssertEqual(reply[1] as? String, "tmp/new.png")
  }

  func testARandomFileRequestWithNothingStagedStillCallsBack() async throws {
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    var requests: [String] = []
    page.onRandomFileRequest = { token, _ in requests.append(token) }
    page.load()
    try await waitUntilLoaded(page)
    try await requestRandomFile(page, property: "gallery")
    try await poll { requests.count == 1 }

    // What the host answers when no directory is staged. A wallpaper waiting on
    // this callback would never draw if it simply never fired.
    page.deliverRandomFile(requestId: requests[0], property: "gallery", path: "")
    let answered = try await pollState(page) { ($0["random"] as? [[Any]])?.count == 1 }
    XCTAssertEqual((answered["random"] as? [[Any]])?.first?[1] as? String, "")
  }

  // MARK: - directory properties

  func testDirectoryChangesReachTheListenerAndSurviveASuspension() async throws {
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    page.load()
    try await waitUntilLoaded(page)
    try await eval(page, """
      window.wallpaperPropertyListener = {
        userDirectoryFilesAddedOrChanged(name, files) { window.__received.dirAdded.push([name, files]); },
        userDirectoryFilesRemoved(name, files) { window.__received.dirRemoved.push([name, files]); },
      };
      """)

    page.deliverDirectoryFiles(property: "gallery", added: ["a.png", "b.png"], removed: [])
    var received = try await pollState(page) { ($0["dirAdded"] as? [[Any]])?.count == 1 }
    XCTAssertEqual((received["dirAdded"] as? [[Any]])?.first?[1] as? [String], ["a.png", "b.png"])

    // Removals are ordered against additions, so a suspension has to hold them
    // rather than collapse them into "whatever is current on resume".
    page.setPresentationSuspended(true)
    page.deliverDirectoryFiles(property: "gallery", added: [], removed: ["a.png"])
    page.deliverDirectoryFiles(property: "gallery", added: ["c.png"], removed: [])
    try await Task.sleep(for: .milliseconds(300))
    received = try await state(page)
    XCTAssertEqual((received["dirRemoved"] as? [[Any]])?.count ?? 0, 0)
    XCTAssertEqual((received["dirAdded"] as? [[Any]])?.count, 1)

    page.setPresentationSuspended(false)
    received = try await pollState(page) {
      ($0["dirAdded"] as? [[Any]])?.count == 2 && ($0["dirRemoved"] as? [[Any]])?.count == 1
    }
    XCTAssertEqual((received["dirRemoved"] as? [[Any]])?.first?[1] as? [String], ["a.png"])
    XCTAssertEqual((received["dirAdded"] as? [[Any]])?.last?[1] as? [String], ["c.png"])
  }

  func testAPropertyListenerRegisteredAfterTheFilesArrivedStillSeesThem() async throws {
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    page.load()
    try await waitUntilLoaded(page)
    page.deliverDirectoryFiles(property: "gallery", added: ["a.png", "b.png"], removed: [])
    page.deliverDirectoryFiles(property: "gallery", added: [], removed: ["a.png"])
    try await Task.sleep(for: .milliseconds(300))

    try await eval(page, """
      window.wallpaperPropertyListener = {
        userDirectoryFilesAddedOrChanged(name, files) { window.__received.dirAdded.push([name, files]); },
      };
      """)
    let received = try await pollState(page) { ($0["dirAdded"] as? [[Any]])?.count == 1 }
    XCTAssertEqual(
      (received["dirAdded"] as? [[Any]])?.first?[1] as? [String], ["b.png"],
      "a late listener is given what the directory currently holds, not the deltas it missed")
  }

  // MARK: - property delivery

  /// Wallpaper Engine documents `applyUserProperties` as one call with every
  /// property at load and afterwards one call per edit with only what changed.
  func testFirstUserPropertiesDeliveryIsTheWholeSetAndLaterOnesOnlyWhatChanged() async throws {
    let page = try await listenerPage()
    page.applyUserProperties(
      json: #"{"theme":{"value":"dark"},"tint":{"value":"1 0.5 0"},"crop":{"value":{"x":0.5,"zoom":1}}}"#)
    var received = try await pollState(page) { ($0["user"] as? [[String: Any]])?.count == 1 }
    XCTAssertEqual(try keys(received, "user", 0), ["crop", "theme", "tint"], "the first delivery carries every property")

    // A change nested inside a value is a change; the untouched properties are not resent.
    page.applyUserProperties(
      json: #"{"theme":{"value":"dark"},"tint":{"value":"1 0.5 0"},"crop":{"value":{"x":0.5,"zoom":2}}}"#)
    received = try await pollState(page) { ($0["user"] as? [[String: Any]])?.count == 2 }
    let edit = try payload(received, "user", 1)
    XCTAssertEqual(edit.keys.sorted(), ["crop"])
    let crop = (edit["crop"] as? [String: Any])?["value"] as? [String: Any]
    XCTAssertEqual(crop?["zoom"] as? Int, 2)

    // A property the page has not seen yet counts as changed.
    page.applyUserProperties(
      json: #"{"theme":{"value":"light"},"tint":{"value":"1 0.5 0"},"crop":{"value":{"x":0.5,"zoom":2}},"mode":{"value":3}}"#)
    received = try await pollState(page) { ($0["user"] as? [[String: Any]])?.count == 3 }
    XCTAssertEqual(try keys(received, "user", 2), ["mode", "theme"])
  }

  func testIdenticalPropertiesAreNotDeliveredAgain() async throws {
    let page = try await listenerPage()
    page.applyUserProperties(json: #"{"a":{"type":"slider","value":1},"b":{"type":"text","value":"x"}}"#)
    // The bridge builds this object from a dictionary: key order, top level and
    // nested, is not part of its contract and must never read as an edit.
    page.applyUserProperties(json: #"{"b":{"value":"x","type":"text"},"a":{"value":1,"type":"slider"}}"#)
    page.applyUserProperties(json: #"{"b":{"value":"y","type":"text"},"a":{"value":1,"type":"slider"}}"#)
    // Calls reach the page in order, so once the last edit is there the one
    // before it either was or was not delivered.
    let received = try await pollState(page) {
      (($0["user"] as? [[String: Any]])?.last?.keys.sorted()) == ["b"]
    }
    XCTAssertEqual((received["user"] as? [[String: Any]])?.count, 2, "re-applying the same values calls nobody")
  }

  /// As in Wallpaper Engine, assigning another listener is not a delivery: the page
  /// already holds the values, so the new listener hears only what changes after it.
  func testAReplacedListenerHearsOnlyWhatChangesAfterIt() async throws {
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    page.load()
    try await waitUntilLoaded(page)
    try await installUserRecorder(page, as: "first")
    page.applyUserProperties(json: #"{"a":{"value":1},"b":{"value":2}}"#)
    page.applyUserProperties(json: #"{"a":{"value":1},"b":{"value":3}}"#)
    var received = try await pollState(page) { ($0["first"] as? [[String: Any]])?.count == 2 }
    XCTAssertEqual(try keys(received, "first", 1), ["b"])

    try await installUserRecorder(page, as: "second")
    page.applyUserProperties(json: #"{"a":{"value":1},"b":{"value":3},"c":{"value":4}}"#)
    received = try await pollState(page) { ($0["second"] as? [[String: Any]])?.count == 1 }
    XCTAssertEqual(try keys(received, "second", 0), ["c"])
    XCTAssertEqual((received["first"] as? [[String: Any]])?.count, 2, "a replaced listener hears nothing more")
  }

  /// A React component that assigns `wallpaperPropertyListener` in its body assigns it
  /// on every render, and React renders a component again, up to a limit, when it sets
  /// state while rendering. The fixture keeps that rule without React. A listener called
  /// from its own assignment set state inside every render until the limit, which left
  /// such a page blank.
  func testAPageThatAssignsItsListenerWhileRenderingSettlesAndHearsEachValueOnce() async throws {
    try """
      <!doctype html><html><body><script>
      window.__received = { user: [], paused: [], files: [], passes: [], error: null };
      let rendering = false, again = false, scheduled = false;
      const setState = () => {
        if (rendering) { again = true; return; }
        if (!scheduled) { scheduled = true; setTimeout(() => { scheduled = false; render(); }); }
      };
      function render() {
        let passes = 0;
        do {
          again = false;
          if (++passes > 25) { window.__received.error = "too many re-renders"; return; }
          rendering = true;
          try {
            window.wallpaperPropertyListener = {
              applyUserProperties(p) { window.__received.user.push(Object.keys(p).sort()); setState(); },
              setPaused(paused) { window.__received.paused.push(paused); setState(); },
              userDirectoryFilesAddedOrChanged(name, files) { window.__received.files.push(files); setState(); },
            };
          } finally { rendering = false; }
        } while (again);
        window.__received.passes.push(passes);
      }
      </script></body></html>
      """.write(to: project.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    page.load()
    try await waitUntilLoaded(page)
    // Everything arrives before the first render, so the first listener is a late one.
    try await deliverUser(page, #"{"a":{"value":1},"b":{"value":2}}"#)
    try await eval(page, """
      window.__mweWallpaperHost.setPaused(false);
      window.__mweWallpaperHost.userDirectoryFilesAddedOrChanged("gallery", ["a.png"]);
      render();
      """)
    var received = try await pollState(page) { ($0["passes"] as? [Int])?.count == 2 || $0["error"] is String }
    XCTAssertNil(received["error"] as? String, "the page never finished a render")
    XCTAssertEqual(received["user"] as? [[String]], [["a", "b"]], "the late listener is handed the whole set once")
    XCTAssertEqual(received["paused"] as? [Bool], [false])
    XCTAssertEqual(received["files"] as? [[String]], [["a.png"]])

    // Every render assigns a new listener; an edit reaches the current one with only the change.
    try await deliverUser(page, #"{"a":{"value":1},"b":{"value":3}}"#)
    received = try await pollState(page) { ($0["passes"] as? [Int])?.count == 3 || $0["error"] is String }
    XCTAssertNil(received["error"] as? String)
    XCTAssertEqual(received["user"] as? [[String]], [["a", "b"], ["b"]])
    XCTAssertEqual(received["passes"] as? [Int], [1, 1, 1], "no render had to run again")
  }

  /// A handler that assigns another listener during the replay can hand over to one
  /// with a handler the first lacked; what that handler is owed must not wait for the host.
  func testAListenerAssignedDuringTheReplayGetsWhatTheOneBeforeItLacked() async throws {
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    page.load()
    try await waitUntilLoaded(page)
    try await eval(page, """
      window.__received.user = [];
      window.__received.general = [];
      window.__mweWallpaperHost.applyGeneralProperties({ fps: 30 });
      window.__mweWallpaperHost.applyUserProperties({ a: { value: 1 } });
      const full = {
        applyUserProperties(p) { window.__received.user.push(Object.keys(p)); },
        applyGeneralProperties(p) { window.__received.general.push(p.fps); },
      };
      window.wallpaperPropertyListener = {
        applyUserProperties(p) { window.__received.user.push(Object.keys(p)); window.wallpaperPropertyListener = full; },
      };
      """)
    let received = try await pollState(page) { ($0["general"] as? [Int])?.count == 1 }
    XCTAssertEqual(received["general"] as? [Int], [30])
    XCTAssertEqual(received["user"] as? [[String]], [["a"]], "the new listener replaces one that took them in")
  }

  func testAListenerThatGainsItsHandlerLaterStillGetsTheWholeSet() async throws {
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    page.load()
    try await waitUntilLoaded(page)
    try await eval(page, "window.wallpaperPropertyListener = {}; window.__received.user = [];")
    // Delivered straight to the script: a main-actor hop in between would leave a
    // test no way to order the next call against this one.
    try await deliverUser(page, #"{"a":{"value":1},"b":{"value":2}}"#)
    try await eval(
      page, "window.wallpaperPropertyListener.applyUserProperties = p => window.__received.user.push(Object.keys(p).sort());")
    try await deliverUser(page, #"{"a":{"value":1},"b":{"value":2}}"#)
    let received = try await state(page)
    XCTAssertEqual(
      received["user"] as? [[String]], [["a", "b"]],
      "nothing was delivered while the handler was missing, so nothing may count as delivered")
  }

  func testAReloadedDocumentStartsFromTheWholeSet() async throws {
    let page = try await listenerPage(loading: false)
    page.applyUserProperties(json: #"{"a":{"value":1},"b":{"value":2}}"#)
    page.load()
    try await waitUntilLoaded(page)
    _ = try await pollState(page) { ($0["user"] as? [[String: Any]])?.count == 1 }
    page.applyUserProperties(json: #"{"a":{"value":1},"b":{"value":5}}"#)
    _ = try await pollState(page) { ($0["user"] as? [[String: Any]])?.count == 2 }

    // The last thing the old document took in was one changed key; the new one
    // has taken in nothing and gets the committed values in full.
    page.load()
    let received = try await pollState(page) { ($0["user"] as? [[String: Any]])?.count == 1 }
    let whole = try payload(received, "user", 0)
    XCTAssertEqual(whole.keys.sorted(), ["a", "b"])
    XCTAssertEqual((whole["b"] as? [String: Any])?["value"] as? Int, 5)
  }

  func testAThrowingFirstHandlerIsRetriedWithTheWholeSet() async throws {
    let page = try await listenerPage(throwingFirstCall: true)
    page.applyUserProperties(json: #"{"a":{"value":1},"b":{"value":2}}"#)
    _ = try await pollState(page) { $0["throwNext"] as? Bool == false }

    // The page never took the first set in, so measuring the next apply against it
    // would hide `a` from the page for good.
    page.applyUserProperties(json: #"{"a":{"value":1},"b":{"value":3}}"#)
    var received = try await pollState(page) { ($0["user"] as? [[String: Any]])?.count == 1 }
    XCTAssertEqual(try keys(received, "user", 0), ["a", "b"])

    page.applyUserProperties(json: #"{"a":{"value":1},"b":{"value":4}}"#)
    received = try await pollState(page) { ($0["user"] as? [[String: Any]])?.count == 2 }
    XCTAssertEqual(try keys(received, "user", 1), ["b"])
  }

  /// A file reselected after its bytes changed is staged under the same path, so its
  /// value reads as before; the host says it was restaged, and the page hears it once.
  func testARestagedFileIsDeliveredAgainThoughItsValueReadsTheSame() async throws {
    let page = try await listenerPage()
    let json = #"{"cover":{"type":"file","value":"p/cover.png"},"size":{"value":3}}"#
    page.applyUserProperties(json: json)
    page.applyUserProperties(json: json)
    page.applyUserProperties(json: json, restaged: ["cover"])
    var received = try await pollState(page) { ($0["user"] as? [[String: Any]])?.count == 2 }
    XCTAssertEqual(try keys(received, "user", 0), ["cover", "size"])
    XCTAssertEqual(
      try keys(received, "user", 1), ["cover"],
      "only the restaged file is resent; the unchanged apply before it called nobody")

    // Owed once: the next apply is measured against what the page holds again.
    page.applyUserProperties(json: json)
    page.applyUserProperties(json: #"{"cover":{"type":"file","value":"p/cover.png"},"size":{"value":4}}"#)
    received = try await pollState(page) { ($0["user"] as? [[String: Any]])?.count == 3 }
    XCTAssertEqual(try keys(received, "user", 2), ["size"])
  }

  func testARestagedFileTheHandlerFailedToTakeInIsOwedAgain() async throws {
    let page = try await listenerPage()
    let json = #"{"cover":{"type":"file","value":"p/cover.png"},"size":{"value":3}}"#
    page.applyUserProperties(json: json)
    _ = try await pollState(page) { ($0["user"] as? [[String: Any]])?.count == 1 }
    _ = try await eval(page, "window.__received.throwNext = true;")

    page.applyUserProperties(json: json, restaged: ["cover"])
    _ = try await pollState(page) { $0["throwNext"] as? Bool == false }

    // The handler threw on the restaged copy, so the page never took it in: the value
    // matching what it accepted earlier must not hide the new bytes from it for good.
    page.applyUserProperties(json: json)
    let received = try await pollState(page) { ($0["user"] as? [[String: Any]])?.count == 2 }
    XCTAssertEqual(try keys(received, "user", 1), ["cover"])
  }

  func testARestagedFileThatArrivedWithNoHandlerIsOwedToTheNextListener() async throws {
    let page = try await listenerPage()
    let json = #"{"cover":{"type":"file","value":"p/cover.png"},"size":{"value":3}}"#
    page.applyUserProperties(json: json)
    _ = try await pollState(page) { ($0["user"] as? [[String: Any]])?.count == 1 }

    // The new bytes arrive while the page has no handler; its next listener is owed them.
    try await eval(page, """
      window.wallpaperPropertyListener = {};
      window.__mweWallpaperHost.applyUserProperties(\(json), ["cover"]);
      """)
    try await installUserRecorder(page, as: "next")
    let received = try await pollState(page) { ($0["next"] as? [[String: Any]])?.count == 1 }
    XCTAssertEqual(try keys(received, "next", 0), ["cover"])
  }

  func testGeneralPropertiesAreDeduplicatedToo() async throws {
    let page = try await listenerPage()
    page.applyGeneralProperties(fps: 30)
    page.applyGeneralProperties(fps: 30)
    page.applyGeneralProperties(fps: 24)
    let received = try await pollState(page) { ($0["general"] as? [[String: Any]])?.count == 2 }
    XCTAssertEqual((received["general"] as? [[String: Int]]), [["fps": 30], ["fps": 24]])
  }

  // MARK: - helpers

  private static func spectrum(first: Float) -> [Float] {
    var bins = [Float](repeating: 0, count: 128)
    bins[0] = first
    return bins
  }

  private static func properties(title: String) -> [String: Any] {
    [
      "title": title, "artist": "Artist", "subTitle": "", "albumTitle": "Album",
      "albumArtist": "", "genres": "", "contentType": "music",
    ]
  }

  private static let thumbnail: [String: Any] = [
    "thumbnail": "data:image/png;base64,iVBORw0KGgo=",
    "primaryColor": "rgb(10, 20, 30)", "secondaryColor": "rgb(40, 50, 60)",
    "tertiaryColor": "rgb(70, 80, 90)", "textColor": "rgb(255, 255, 255)",
    "highContrastColor": "rgb(255, 255, 255)",
  ]

  /// A loaded page with every media listener registered and the user setting on.
  private func mediaPage() async throws -> WebWallpaperPage {
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    var demands: [WebWallpaperPage.MediaDemand] = []
    page.onMediaDemandChanged = { demands.append($0) }
    page.setMediaIntegrationEnabled(true)
    page.load()
    try await waitUntilLoaded(page)
    for slot in ["Status", "Properties", "Thumbnail", "Playback", "Timeline"] {
      try await eval(page, """
        window.wallpaperRegisterMedia\(slot)Listener(
          e => window.__received.\(slot.lowercased()).push(e));
        """)
    }
    try await poll { demands.last?.consuming == true }
    return page
  }

  /// A page that assigns its listener while parsing and records a copy of each
  /// payload it is handed. `throwNext` makes the first user-properties call throw.
  private func listenerPage(throwingFirstCall: Bool = false, loading: Bool = true) async throws -> WebWallpaperPage {
    try """
      <!doctype html><html><body><script>
      window.__received = { user: [], general: [], throwNext: \(throwingFirstCall) };
      const copy = value => JSON.parse(JSON.stringify(value));
      window.wallpaperPropertyListener = {
        applyUserProperties(p) {
          if (window.__received.throwNext) { window.__received.throwNext = false; throw new Error("first handler fails"); }
          window.__received.user.push(copy(p));
        },
        applyGeneralProperties(p) { window.__received.general.push(copy(p)); },
      };
      </script></body></html>
      """.write(to: project.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    if loading {
      page.load()
      try await waitUntilLoaded(page)
    }
    return page
  }

  /// Replaces the page's listener with one that records copies of its user-properties payloads
  /// under `window.__received.<name>`.
  private func installUserRecorder(_ page: WebWallpaperPage, as name: String) async throws {
    try await eval(
      page,
      """
      window.__received.\(name) = [];
      window.wallpaperPropertyListener = {
        applyUserProperties(p) { window.__received.\(name).push(JSON.parse(JSON.stringify(p))); },
      };
      """)
  }

  private func deliverUser(_ page: WebWallpaperPage, _ json: String) async throws {
    _ = try await page.webView.callAsyncJavaScript(
      "window.__mweWallpaperHost.applyUserProperties(JSON.parse(json))", arguments: ["json": json],
      in: nil, contentWorld: .page)
  }

  private func payload(_ received: [String: Any], _ list: String, _ index: Int) throws -> [String: Any] {
    let calls = try XCTUnwrap(received[list] as? [[String: Any]])
    XCTAssertTrue(calls.indices.contains(index), "\(list) has \(calls.count) calls, wanted index \(index)")
    return calls[index]
  }

  private func keys(_ received: [String: Any], _ list: String, _ index: Int) throws -> [String] {
    try payload(received, list, index).keys.sorted()
  }

  private func requestRandomFile(_ page: WebWallpaperPage, property: String) async throws {
    try await eval(page, """
      window.wallpaperRequestRandomFileForProperty(
        "\(property)", (name, path) => window.__received.random.push([name, path]));
      """)
  }

  @discardableResult
  private func eval(_ page: WebWallpaperPage, _ script: String) async throws -> Any? {
    try await page.webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
  }

  private func state(_ page: WebWallpaperPage) async throws -> [String: Any] {
    guard page.isLoaded,
      let received = try? await page.webView.callAsyncJavaScript(
        "return window.__received", arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
    else { return [:] }
    return received
  }

  private func waitUntilLoaded(_ page: WebWallpaperPage, timeout: TimeInterval = 10) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !page.isLoaded && Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
    XCTAssertTrue(page.isLoaded, "the page did not load")
  }

  private func poll(timeout: TimeInterval = 5, until condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTFail("condition not met before timeout")
  }

  @discardableResult
  private func pollState(
    _ page: WebWallpaperPage, timeout: TimeInterval = 5,
    until condition: ([String: Any]) -> Bool
  ) async throws -> [String: Any] {
    let deadline = Date().addingTimeInterval(timeout)
    var last: [String: Any] = [:]
    while Date() < deadline {
      last = try await state(page)
      if condition(last) { return last }
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTFail("condition not met before timeout; last state: \(last)")
    return last
  }
}
