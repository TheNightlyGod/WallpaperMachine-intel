import Darwin
import XCTest

@testable import WallpaperMachine

/// Reading `file` and `directory` properties out of the bridge's
/// `applyUserProperties` payload, and rewriting a `file` value to the staged
/// path the page is allowed to load. Optional keys are genuinely optional: an
/// author may declare no file-type option and no directory mode.
@MainActor
final class WebWallpaperPropertyPayloadTests: XCTestCase {
  private let payload = """
    {
      "scheme": { "value": "dark", "type": "combo" },
      "cover": { "value": "/Users/x/Pictures/a b+c.png", "type": "file", "fileFilter": "image" },
      "clip": { "value": "", "type": "file" },
      "gallery": { "value": "/Users/x/Pictures", "type": "directory", "mode": "fetchall", "fileFilter": "image" },
      "picks": { "value": "/Users/x/Movies", "type": "directory", "mode": "ondemand" },
      "loose": { "value": "/Users/x/Any", "type": "directory" },
      "surface": { "value": "materials/x.tex", "type": "texture" },
      "odd": { "value": "1", "type": "hologram" },
      "broken": "not an object"
    }
    """

  func testOnlyFileAndDirectoryPropertiesAreTreatedAsPaths() {
    let properties = WebWallpaperHost.pathProperties(in: payload)
    XCTAssertEqual(
      properties.map(\.id), ["clip", "cover", "gallery", "loose", "picks"],
      "a texture picker has no directory semantics and an unknown kind is not a path")
  }

  func testAnAbsentFileFilterRestrictsNothingRatherThanMeaningImages() {
    let properties = WebWallpaperHost.pathProperties(in: payload)
    XCTAssertEqual(properties.first { $0.id == "cover" }?.filter, .image)
    XCTAssertEqual(
      properties.first { $0.id == "clip" }?.filter, .any,
      "the author declared no file-type option, which is not the same as declaring images")
  }

  func testDirectoryModeDefaultsToOnDemand() {
    let properties = WebWallpaperHost.pathProperties(in: payload)
    XCTAssertEqual(properties.first { $0.id == "gallery" }?.fetchAll, true)
    XCTAssertEqual(properties.first { $0.id == "picks" }?.fetchAll, false)
    XCTAssertEqual(
      properties.first { $0.id == "loose" }?.fetchAll, false,
      "a directory with no declared mode is ondemand")
  }

  func testAnUnsetPropertyHasNoSourcePath() {
    let properties = WebWallpaperHost.pathProperties(in: payload)
    XCTAssertEqual(properties.first { $0.id == "cover" }?.source, "/Users/x/Pictures/a b+c.png")
    XCTAssertEqual(properties.first { $0.id == "clip" }?.source, "")
  }

  func testSubstitutionRewritesOnlyTheNamedValues() async throws {
    let rewritten = try XCTUnwrap(
      WebWallpaperHost.substituting(
        ["cover": "Users/x/staged/a b+c.png", "clip": ""], in: payload))
    let root = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: XCTUnwrap(rewritten.data(using: .utf8)))
        as? [String: Any])

    let cover = try XCTUnwrap(root["cover"] as? [String: Any])
    XCTAssertEqual(cover["value"] as? String, "Users/x/staged/a b+c.png")
    XCTAssertEqual(cover["type"] as? String, "file", "the kind must survive the rewrite")
    XCTAssertEqual(cover["fileFilter"] as? String, "image")
    XCTAssertEqual(
      (root["gallery"] as? [String: Any])?["value"] as? String, "/Users/x/Pictures",
      "a directory value stays the user's own path; the page only uses it to detect 'not set'")
    XCTAssertEqual((root["scheme"] as? [String: Any])?["value"] as? String, "dark")
    XCTAssertEqual(root["broken"] as? String, "not an object")
  }

  func testAMalformedPayloadYieldsNothingRatherThanThrowing() {
    XCTAssertTrue(WebWallpaperHost.pathProperties(in: "not json").isEmpty)
    XCTAssertTrue(WebWallpaperHost.pathProperties(in: "[]").isEmpty)
    XCTAssertNil(WebWallpaperHost.substituting(["a": "b"], in: "[]"))
  }

  // MARK: - staging

  /// A page may only read inside its own project folder, so a `file` property
  /// has to reach it as a staged path under the project rather than as the
  /// path the user picked.
  func testAFilePropertyIsStagedIntoTheProjectAndRewrittenForThePage() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let host = WebWallpaperHost(
      fetch: { [] }, screens: { [] },
      assetStore: { UserAssetStore(projectURL: $0, wallpaperId: $1) })

    let staged = await host.stageAssets(for: fixture.wallpaper)
    XCTAssertTrue(staged.restaged)
    let root = try Fixture.object(staged.json)
    let cover = try XCTUnwrap((root["cover"] as? [String: Any])?["value"] as? String)
    XCTAssertFalse(cover.hasPrefix("/"), "the page prepends file:///, so the value carries no leading slash")
    let stagedPath = "/" + cover.replacingOccurrences(of: "%25", with: "%")
    XCTAssertTrue(
      stagedPath.hasPrefix(fixture.project.standardizedFileURL.path),
      "the staged file must be inside the folder WebKit grants the page")
    XCTAssertTrue(FileManager.default.fileExists(atPath: stagedPath))
    XCTAssertEqual(
      (root["gallery"] as? [String: Any])?["value"] as? String, fixture.source.path,
      "a directory value stays the user's own path; the page only uses it to detect 'not set'")
  }

  func testAnUnchangedSelectionIsNotStagedAgain() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let host = WebWallpaperHost(
      fetch: { [] }, screens: { [] },
      assetStore: { UserAssetStore(projectURL: $0, wallpaperId: $1) })
    let first = await host.stageAssets(for: fixture.wallpaper)
    let second = await host.stageAssets(for: fixture.wallpaper)
    XCTAssertFalse(second.restaged, "re-linking a whole folder on every reconcile is not free")
    XCTAssertEqual(second.json, first.json)
  }

  func testClearingASelectionReachesThePageAsAnEmptyValue() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let host = WebWallpaperHost(
      fetch: { [] }, screens: { [] },
      assetStore: { UserAssetStore(projectURL: $0, wallpaperId: $1) })
    _ = await host.stageAssets(for: fixture.wallpaper)

    var cleared = fixture.wallpaper
    cleared.propertiesJson = """
      {
        "cover": { "value": "", "type": "file", "fileFilter": "image" },
        "gallery": { "value": "", "type": "directory", "mode": "fetchall", "fileFilter": "image" }
      }
      """
    let staged = await host.stageAssets(for: cleared)
    XCTAssertTrue(staged.restaged)
    let root = try Fixture.object(staged.json)
    XCTAssertEqual((root["cover"] as? [String: Any])?["value"] as? String, "")
  }

  func testExplicitReselectionOfTheSamePathRestagesChangedBytes() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let host = WebWallpaperHost(fetch: { [] }, screens: { [] },
      assetStore: { UserAssetStore(projectURL: $0, wallpaperId: $1) })
    defer { host.shutdown() }
    let first = await host.stageAssets(for: fixture.wallpaper)
    XCTAssertEqual(first.restagedFiles, ["cover"], "a restaged folder is not a restaged file")
    let root = try Fixture.object(first.json)
    let pagePath = try XCTUnwrap((root["cover"] as? [String: Any])?["value"] as? String)
    let source = try XCTUnwrap(WebWallpaperHost.pathProperties(in: fixture.wallpaper.propertiesJson)
      .first { $0.id == "cover" }?.source)
    let bytes = Data("same path with new content".utf8)
    try bytes.write(to: URL(fileURLWithPath: source), options: .atomic)
    host.invalidateAsset(wallpaperID: fixture.wallpaper.wallpaperId, propertyID: "cover")
    let second = await host.stageAssets(for: fixture.wallpaper)
    XCTAssertTrue(second.restaged)
    XCTAssertEqual(second.restagedFiles, ["cover"])
    XCTAssertEqual(
      try Fixture.object(second.json)["cover"] as? NSDictionary, try Fixture.object(first.json)["cover"] as? NSDictionary,
      "the same name stages to the same path, so the payload alone cannot tell the page the bytes changed")
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: "/" + pagePath.replacingOccurrences(of: "%25", with: "%"))), bytes)
    let unchanged = await host.stageAssets(for: fixture.wallpaper)
    XCTAssertFalse(unchanged.restaged)
    XCTAssertTrue(unchanged.restagedFiles.isEmpty)
  }

  /// The whole path from the user's reselection to the page: the host restages, the staged
  /// path and so the payload stay the same, and the page's listener is still told.
  func testReselectingTheSameFileAfterItsBytesChangedReachesThePageAgain() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try """
      <!doctype html><html><head><script>
      window.__calls = [];
      window.wallpaperPropertyListener = {
        applyUserProperties(p) {
          window.__calls.push({ keys: Object.keys(p).sort(), cover: p.cover && p.cover.value });
        },
      };
      </script></head><body></body></html>
      """.write(to: fixture.project.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    var surfaces: [InertSurface] = []
    let host = WebWallpaperHost(
      fetch: { [] }, screens: { [(id: UInt32(1), frame: NSRect(x: 0, y: 0, width: 320, height: 200))] },
      assetStore: { UserAssetStore(projectURL: $0, wallpaperId: $1) }, pointerMonitor: InertPointerMonitor(),
      makeSurface: { frame, page in
        let surface = InertSurface(frame: frame, page: page)
        surfaces.append(surface)
        return surface
      })
    defer { host.shutdown() }
    await host.apply([fixture.wallpaper])
    let page = try XCTUnwrap(surfaces.first?.page)
    func calls() async -> [[String: Any]] {
      guard page.isLoaded,
        let value = try? await page.webView.callAsyncJavaScript(
          "return window.__calls", arguments: [:], in: nil, contentWorld: .page)
      else { return [] }
      return (value as? [[String: Any]]) ?? []
    }
    func waitForCalls(_ count: Int) async throws -> [[String: Any]] {
      let deadline = Date().addingTimeInterval(10)
      var current = await calls()
      while current.count < count, Date() < deadline {
        try await Task.sleep(for: .milliseconds(25))
        current = await calls()
      }
      return current
    }
    let first = try await waitForCalls(1)
    XCTAssertEqual(first.first?["keys"] as? [String], ["cover", "gallery"], "the first delivery carries every property")

    let source = fixture.source.appendingPathComponent("a b+c.png")
    try Data("same path with new content".utf8).write(to: source, options: .atomic)
    host.invalidateAsset(wallpaperID: fixture.wallpaper.wallpaperId, propertyID: "cover")
    await host.apply([fixture.wallpaper])

    let second = try await waitForCalls(2)
    XCTAssertEqual(second.count, 2, "the reselection reaches the page: \(second)")
    XCTAssertEqual(second.last?["keys"] as? [String], ["cover"], "and only the restaged file is resent")
    XCTAssertEqual(second.last?["cover"] as? String, first.first?["cover"] as? String)
  }

  private final class InertPointerMonitor: WebWallpaperPointerMonitoring {
    var isActive = false
    func setActive(_ active: Bool) { isActive = active }
  }

  private final class InertSurface: WebWallpaperSurface {
    let page: WebWallpaperPage
    var frame: NSRect
    var posterLayer: CALayer? = CALayer()
    var windowNumber: Int { ObjectIdentifier(self).hashValue }
    init(frame: NSRect, page: WebWallpaperPage) {
      self.frame = frame
      self.page = page
    }
    func setScreenFrame(_ frame: NSRect) { self.frame = frame }
    func present() {}
    func retire() {}
  }

  func testStagingFixtureRestoresTheCallersHomeIncludingSetupFailure() async throws {
    let previous = ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_HOME"]
    defer {
      if let previous { setenv("WALLPAPER_MACHINE_HOME", previous, 1) }
      else { unsetenv("WALLPAPER_MACHINE_HOME") }
    }
    let marker = FileManager.default.temporaryDirectory.appendingPathComponent("caller-home-\(UUID().uuidString)")
    setenv("WALLPAPER_MACHINE_HOME", marker.path, 1)
    let fixture = try Fixture()
    fixture.remove()
    XCTAssertEqual(ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_HOME"], marker.path)

    let file = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-directory-\(UUID().uuidString)")
    try Data("fixture setup must fail".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    XCTAssertThrowsError(try Fixture(base: file))
    XCTAssertEqual(ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_HOME"], marker.path)
  }

  /// A project folder and a separate folder of the user's own files, the way a
  /// real selection arrives: the source is never inside the project.
  private struct Fixture {
    let home: URL
    let project: URL
    let source: URL
    let wallpaper: BridgeWebWallpaper
    let previousHome: String?

    init(base: URL = FileManager.default.temporaryDirectory) throws {
      previousHome = ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_HOME"]
      home = base.appendingPathComponent("web-home-\(UUID().uuidString)", isDirectory: true)
      project = base.appendingPathComponent("web-staging-\(UUID().uuidString)", isDirectory: true)
      source = base.appendingPathComponent("web-source-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
      let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
      // A name with a space and a plus: both load unescaped and must survive.
      try png.write(to: source.appendingPathComponent("a b+c.png"))
      try png.write(to: source.appendingPathComponent("second.png"))
      wallpaper = BridgeWebWallpaper(
        displayId: 1, startupRevision: 0, displayKey: "1", audioSourceDisplayId: 1,
        wallpaperId: "w", title: "Test", projectPath: project.path,
        entryFile: "index.html", fps: 30, renderScale: 1, paused: false, volume: 1, muted: false,
        audioResponseEnabled: false,
        mediaIntegrationEnabled: false,
        propertiesJson: """
          {
            "cover": {
              "value": "\(source.appendingPathComponent("a b+c.png").path)",
              "type": "file", "fileFilter": "image"
            },
            "gallery": { "value": "\(source.path)", "type": "directory", "mode": "fetchall" }
          }
          """)
      // Change process state only once every throwing setup operation succeeded.
      setenv("WALLPAPER_MACHINE_HOME", home.path, 1)
    }

    func remove() {
      if let previousHome { setenv("WALLPAPER_MACHINE_HOME", previousHome, 1) }
      else { unsetenv("WALLPAPER_MACHINE_HOME") }
      try? FileManager.default.removeItem(at: home)
      try? FileManager.default.removeItem(at: project)
      try? FileManager.default.removeItem(at: source)
    }

    static func object(_ json: String) throws -> [String: Any] {
      try XCTUnwrap(
        try JSONSerialization.jsonObject(with: XCTUnwrap(json.data(using: .utf8)))
          as? [String: Any])
    }
  }
}
