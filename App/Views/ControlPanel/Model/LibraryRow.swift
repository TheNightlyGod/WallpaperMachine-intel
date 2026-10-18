import Foundation

/// One installed wallpaper as the Installed grid, Now Playing, the history and the inspector's
/// header see it: the renderer's library entry joined with what is measured in the background.
///
/// A row is a plain value so a `ForEach` over thousands of them diffs cheaply. It carries nothing
/// that changes while a download runs or the selection moves; favorites, selection and the apply
/// state are asked of the controller beside it, which is what lets `LibraryRowsCache` keep the
/// rows between those changes.
struct LibraryRow: Identifiable, Equatable, Sendable {
  /// The wallpaper's type as Installed's filters and sort name it, Steam's own words. Never
  /// `Application`: an installed row is something the renderer can name.
  enum Kind: String, Comparable, Sendable {
    case scene = "Scene"
    case video = "Video"
    case web = "Web"
    case unknown = "Unknown"

    init(_ kind: BridgeWallpaperKind) {
      switch kind {
      case .projectScene: self = .scene
      case .video: self = .video
      case .webpage: self = .web
      case .unknown: self = .unknown
      }
    }

    /// The type sort compares the English words, so it orders the same in every language.
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
  }

  /// Where a tile's picture stands. A tile never shows the full-size preview in place of its
  /// cover, so `pending` shows nothing until the stamp is read.
  enum Cover: Equatable, Sendable {
    /// The wallpaper has no preview file.
    case none
    /// There is a preview file whose stamp the background read has not delivered yet.
    case pending
    /// The stamp of the preview file. A replaced preview has another stamp, which makes it another
    /// image to the cache and to the view, so only that tile is redone after a rescan.
    case stamped(UInt64)
  }

  let id: String
  var title: String
  var kind: Kind
  var previewFile: URL?
  var cover: Cover
  /// Whether the preview file can hold an animation. Judged by the extension alone so that
  /// building a row never touches the disk: a `.png` that is really an APNG shows as a still.
  var canAnimate: Bool
  /// Whether a non-mirror row of the target display shows it. The bridge's own `active` and
  /// `selected` flags are not used: they are not about the target display.
  var isActive: Bool
  var isSupported: Bool
  /// The manifest's tags, content rating and Workshop-style facts. Empty until measured.
  var tags: [String]
  var isApproved: Bool
  /// Bytes of the folder, nil until measured. Unmeasured rows sort last either way.
  var size: Int64?
  var addedAt: Date?
  /// The background energy rating, nil until the wallpaper has been rated.
  var energy: LibraryEnergyRating?
  var isUpdateAvailable: Bool
  /// When the author last changed it, while an update is available.
  var updatedAt: Date?

  /// The tile's still: its cover once the stamp is known. Nil while the cover is pending and for
  /// a wallpaper with no preview, so the view draws its placeholder.
  var coverSource: PanelImageSource? {
    guard case .stamped(let stamp) = cover, let previewFile else { return nil }
    return .libraryCover(file: previewFile, stamp: stamp)
  }

  /// The preview file itself, for the inspector's artwork and Now Playing.
  var previewSource: PanelImageSource? { previewFile.map { .libraryPreview(file: $0) } }

  /// The preview as an animation, only for a file that can hold one.
  var animationSource: PanelImageSource? { canAnimate ? previewSource : nil }

  /// What Now Playing and the history show for this wallpaper: the cover once stamped, and
  /// nothing before it (never the full-size preview while the cover is pending).
  var still: PanelImageSource? { coverSource }
}

extension LibraryRow {
  /// File extensions of previews that may hold an animation.
  static let animatedPreviewExtensions: Set<String> = ["gif", "webp", "apng"]

  /// The row for `entry`, joined with what the background services know of it.
  ///
  /// - Parameters:
  ///   - covers: Preview file stamps read so far, by wallpaper id.
  ///   - isActive: Whether the target display shows the wallpaper.
  ///   - energy: `WallpaperEnergyRatings.snapshot(for:kind:)`'s answer, nil until rated.
  static func make(
    _ entry: BridgeWallpaperEntry, isActive: Bool, covers: [String: UInt64],
    metrics: LibraryMetricsService.Metrics?, update: WorkshopItem?, energy: [String: Any]?
  ) -> LibraryRow {
    let file = entry.previewPath.map { URL(fileURLWithPath: $0) }
    let cover: Cover =
      file == nil ? .none : covers[entry.id].map(Cover.stamped) ?? .pending
    return LibraryRow(
      id: entry.id, title: entry.title, kind: Kind(entry.kind), previewFile: file, cover: cover,
      canAnimate: file.map { animatedPreviewExtensions.contains($0.pathExtension.lowercased()) }
        ?? false,
      isActive: isActive, isSupported: entry.supported, tags: metrics?.tags ?? [],
      isApproved: metrics?.approved ?? false, size: metrics?.size, addedAt: metrics?.addedAt,
      energy: energy.flatMap(LibraryEnergyRating.init(snapshot:)),
      isUpdateAvailable: update != nil, updatedAt: update?.timeUpdated)
  }
}

/// The energy a wallpaper was measured to cost, with the conditions it was measured under: a
/// rating taken on two displays with no limit says little about one display at 30 fps.
struct LibraryEnergyRating: Equatable, Sendable {
  var level: EnergyLevel
  var milliwatts: Double
  /// Displays that showed the wallpaper while it was measured.
  var displays: Int
  /// The frame-rate ceiling in force then; nil is no limit.
  var frameRateCap: Int?
  var renderScale: Double
  /// The share of a full charge the rated power uses per hour, on a Mac with a battery only.
  var batteryPercentPerHour: Double?

  /// Reads what `WallpaperEnergyRatings.snapshot(for:kind:)` reports. Nil for anything else.
  init?(snapshot: [String: Any]) {
    guard let level = (snapshot["level"] as? String).flatMap(EnergyLevel.init(rawValue:)),
      let milliwatts = snapshot["milliwatts"] as? Double, let displays = snapshot["displays"] as? Int,
      let renderScale = snapshot["renderScale"] as? Double
    else { return nil }
    self.level = level
    self.milliwatts = milliwatts
    self.displays = displays
    frameRateCap = snapshot["frameRateCap"] as? Int
    self.renderScale = renderScale
    batteryPercentPerHour = snapshot["batteryPercentPerHour"] as? Double
  }
}

/// Keeps the Installed rows between the changes that cannot alter them.
///
/// Building a row for each of 10,000 wallpapers is the one expensive derivation of the panel, so
/// it happens only when an input of the rows moved: the library or the displays, a rescan,
/// measured sizes and tags, cover stamps, the Workshop's update list, the energy ratings, the
/// target display (it decides which tile is Active) and the language (titles follow it). A
/// selection, a playback change, a download tick or an equal library handed over again leaves
/// the rows exactly as they were.
@MainActor
final class LibraryRowsCache {
  /// Everything that can change a row; the rows are rebuilt when it differs from the last build.
  struct Key: Equatable {
    var content: UInt64
    var refresh: UInt64
    var metrics: UInt64
    var covers: UInt64
    var updates: UInt64
    var energy: UInt64
    var target: String
    var language: String
  }

  private(set) var rows: [LibraryRow] = []
  private(set) var key: Key?
  /// How many times the rows were built, for the test that holds the cache to its promise.
  private(set) var rebuilds = 0
  private var positions: [String: Int] = [:]

  /// The rows for `key`: the ones kept if it is the key they were built for, else the result of
  /// `build`, which then is kept.
  func rows(for key: Key, build: () -> [LibraryRow]) -> [LibraryRow] {
    if self.key == key { return rows }
    let built = build()
    rows = built
    self.key = key
    rebuilds += 1
    positions = Dictionary(
      built.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
    return built
  }

  /// The row of `id` in the rows last kept; call `rows(for:build:)` first to make them current.
  func row(id: String) -> LibraryRow? { positions[id].map { rows[$0] } }
}
