import XCTest

@testable import WallpaperMachine

/// The download region SteamCMD starts from: a mainland-China Mac asks Steam for its mainland
/// download servers, everyone else keeps Steam's own choice, and a saved sign-in's config keeps
/// everything but a far region.
@MainActor
final class SteamCMDDownloadRegionTests: DownloaderTestCase {
  private let cell = SteamCMDDownloadRegion.mainlandChinaCell

  /// A config the way SteamCMD saves it after a sign-in that Steam gave Singapore.
  private let savedConfig = """
    "InstallConfigStore"
    {
    \t"Software"
    \t{
    \t\t"valve"
    \t\t{
    \t\t\t"Steam"
    \t\t\t{
    \t\t\t\t"ConnectCache"
    \t\t\t\t{
    \t\t\t\t\t"7a1e"\t\t"opaque-token"
    \t\t\t\t}
    \t\t\t\t"CellIDServerOverride"\t\t"35"
    \t\t\t\t"RecentDownloadRate"\t\t"6777"
    \t\t\t}
    \t\t}
    \t}
    \t"SDL_GamepadBind"\t\t"// not a comment \\" still a value"
    }

    """

  private func cells(in config: String) -> [String] {
    // The values of every `CellIDServerOverride` line, as SteamCMD writes them: one per line.
    config.components(separatedBy: "\n")
      .filter { $0.contains("CellIDServerOverride") }
      .map { $0.components(separatedBy: "\"").dropLast().last ?? "" }
  }

  func testOnlyMainlandChinaTimeZonesAskForAMainlandRegion() throws {
    for zone in ["Asia/Shanghai", "Asia/Urumqi", "Asia/Chongqing", "Asia/Harbin"] {
      XCTAssertEqual(SteamCMDDownloadRegion.forTimeZone(try XCTUnwrap(TimeZone(identifier: zone))).cell, cell, zone)
    }
    for zone in ["Asia/Hong_Kong", "Asia/Macau", "Asia/Taipei", "Asia/Singapore", "Asia/Tokyo",
                 "America/Los_Angeles", "Europe/Berlin", "GMT"] {
      XCTAssertNil(SteamCMDDownloadRegion.forTimeZone(try XCTUnwrap(TimeZone(identifier: zone))).cell, zone)
    }
  }

  func testAFarRegionInASavedConfigIsReplacedAndNothingElseChanges() throws {
    let seeded = try XCTUnwrap(SteamCMDDownloadRegion.seeding(savedConfig, cell: cell))
    XCTAssertEqual(cells(in: seeded), ["\(cell)"])
    XCTAssertEqual(
      seeded, savedConfig.replacingOccurrences(of: "\"CellIDServerOverride\"\t\t\"35\"",
                                               with: "\"CellIDServerOverride\"\t\t\"\(cell)\""))
  }

  func testAMainlandRegionSteamAlreadyChoseIsKept() {
    let precise = savedConfig.replacingOccurrences(of: "\"35\"", with: "\"202\"")
    XCTAssertNil(SteamCMDDownloadRegion.seeding(precise, cell: cell))
  }

  func testAConfigWithoutARegionGetsOneInsideItsSteamBlock() throws {
    let withoutRegion = savedConfig.replacingOccurrences(of: "\t\t\t\t\"CellIDServerOverride\"\t\t\"35\"\n", with: "")
    let seeded = try XCTUnwrap(SteamCMDDownloadRegion.seeding(withoutRegion, cell: cell))
    XCTAssertEqual(cells(in: seeded), ["\(cell)"])
    // Now found where Steam reads it: a second pass leaves it alone.
    XCTAssertNil(SteamCMDDownloadRegion.seeding(seeded, cell: cell))
    XCTAssertEqual(
      seeded.replacingOccurrences(of: "\n\t\t\t\t\"CellIDServerOverride\"\t\t\"\(cell)\"", with: ""),
      withoutRegion)
    // A key of the same name outside the Steam block is not the region.
    let elsewhere = withoutRegion.replacingOccurrences(
      of: "\"RecentDownloadRate\"", with: "\"Other\" { \"CellIDServerOverride\" \"202\" }\n\"RecentDownloadRate\"")
    XCTAssertNotNil(SteamCMDDownloadRegion.seeding(elsewhere, cell: cell))
  }

  func testAMissingConfigBecomesOneAndAnUnreadableOneIsLeftAlone() throws {
    let fresh = try XCTUnwrap(SteamCMDDownloadRegion.seeding(nil, cell: cell))
    XCTAssertEqual(cells(in: fresh), ["\(cell)"])
    XCTAssertNil(SteamCMDDownloadRegion.seeding(fresh, cell: cell))
    XCTAssertNotNil(SteamCMDDownloadRegion.seeding("", cell: cell))
    XCTAssertNil(SteamCMDDownloadRegion.seeding("\"InstallConfigStore\"\n{\n\t\"Software\"\n", cell: cell))
    XCTAssertNil(SteamCMDDownloadRegion.seeding("\"InstallConfigStore\" { \"unterminated }", cell: cell))
  }

  /// A stand-in SteamCMD that downloads only when its config names `expected` as the region and
  /// still holds the restored token, the way Steam needs both.
  private func makeRegionRuntime(expectingCell expected: String, token: String?) throws -> URL {
    let tokenCheck = token.map { "grep -q '\"7a1e\"[[:space:]]*\"\($0)\"' \"$config\" || exit 91" } ?? ""
    return try makeRuntime(
      """
      set -eu
      install=''
      item=''
      while [ "$#" -gt 0 ]; do
          case "$1" in
              +force_install_dir) shift; install="$1" ;;
              +workshop_download_item) shift; shift; item="$1" ;;
          esac
          shift
      done
      config="$HOME/Library/Application Support/Steam/config/config.vdf"
      [ -f "$config" ] || exit 90
      grep -q '"CellIDServerOverride"[[:space:]]*"\(expected)"' "$config" || exit 92
      \(tokenCheck)
      printf 'Logging in using cached credentials\\nWaiting for user info...OK\\n'
      content="$install/steamapps/workshop/content/431960/$item"
      mkdir -p "$content"
      printf '{"type":"video","file":"movie.mp4"}' > "$content/project.json"
      printf 'region' > "$content/movie.mp4"
      printf 'Downloading item %s ...\\nSuccess. Downloaded item %s\\n' "$item" "$item"
      """)
  }

  func testAMainlandRunStartsSteamCMDInTheMainlandRegion() async throws {
    let root = try makeRegionRuntime(expectingCell: "\(cell)", token: nil)
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = startDownload(
      in: root, rememberSession: false, downloadRegion: SteamCMDDownloadRegion(cell: cell))
    try await assertImported(downloader, in: root, itemID: "123456")
  }

  func testASavedSignInFromAFarRegionKeepsItsTokenAndMovesToTheMainlandRegion() async throws {
    let root = try makeRegionRuntime(expectingCell: "\(cell)", token: "opaque-token")
    defer { try? FileManager.default.removeItem(at: root) }
    let session = root.appendingPathComponent("SteamSession")
    let config = SteamCMDDownloadRegion.configFile(home: session)
    try FileManager.default.createDirectory(
      at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(savedConfig.utf8).write(to: config)
    try Data("localtest".utf8).write(to: session.appendingPathComponent("account"))

    let downloader = startDownload(in: root, downloadRegion: SteamCMDDownloadRegion(cell: cell))
    try await assertImported(downloader, in: root, itemID: "123456")
    XCTAssertEqual(downloader.savedAccount, "localtest")
    let saved = try String(contentsOf: config, encoding: .utf8)
    XCTAssertEqual(cells(in: saved), ["\(cell)"])
    XCTAssertTrue(saved.contains("\"opaque-token\""))
  }

  func testOutsideMainlandChinaSteamsOwnRegionIsUntouched() async throws {
    let root = try makeRegionRuntime(expectingCell: "35", token: "opaque-token")
    defer { try? FileManager.default.removeItem(at: root) }
    let session = root.appendingPathComponent("SteamSession")
    let config = SteamCMDDownloadRegion.configFile(home: session)
    try FileManager.default.createDirectory(
      at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(savedConfig.utf8).write(to: config)
    try Data("localtest".utf8).write(to: session.appendingPathComponent("account"))

    let downloader = startDownload(in: root, downloadRegion: .steamsChoice)
    try await assertImported(downloader, in: root, itemID: "123456")
  }
}
