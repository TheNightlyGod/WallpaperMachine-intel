import Foundation

/// The rules that decide which controls the Installed inspector offers and when they are enabled,
/// as pure functions of the wallpaper, the target display and the downloads, so each one is tested
/// without a view. They are the page's (`panel.js:794-853`), unchanged.
@MainActor
enum InspectorPolicy {
  // MARK: Running

  /// Whether the wallpaper's type is one this app runs. The renderer names every type it cannot run
  /// `unknown`, Wallpaper Engine's Application wallpapers among them (the page told those apart as
  /// `Application`, which an installed row cannot), so for an installed wallpaper an unknown type
  /// is the page's "cannot run on macOS".
  static func canRun(_ kind: LibraryRow.Kind) -> Bool { kind != .unknown }

  // MARK: Apply

  /// Apply (or Reapply) is offered to a wallpaper whose type is known, on a target display that is
  /// enabled and not a mirror. Whether the Mac can render it is not part of the rule: the
  /// wallpaper's own notice says so, and the button stays.
  static func canActivate(kind: LibraryRow.Kind, target: TargetDisplayOption?) -> Bool {
    canRun(kind) && target?.isSelectable == true
  }

  /// Applying what the target display already shows does nothing, so that button restarts it.
  static func reapplies(_ wallpaperID: String, target: TargetDisplayOption?) -> Bool {
    target?.wallpaperID == wallpaperID
  }

  /// One step for every display, offered only where there is more than one to put it on. A mirror
  /// follows its source and a disabled display shows nothing, so neither counts.
  static func offersApplyToAll(_ row: LibraryRow, sharedDisplayCount: Int) -> Bool {
    row.isSupported && canRun(row.kind) && sharedDisplayCount >= 2
  }

  /// Apply to all displays has nothing to do when every shared display already shows the wallpaper.
  static func appliesEverywhereAlready(_ wallpaperID: String, sharedDisplayWallpapers: [String?])
    -> Bool
  {
    !sharedDisplayWallpapers.isEmpty && sharedDisplayWallpapers.allSatisfy { $0 == wallpaperID }
  }

  /// The live preview needs the preview window and a wallpaper of a known type.
  static func offersPreview(kind: LibraryRow.Kind, previewAvailable: Bool) -> Bool {
    previewAvailable && canRun(kind)
  }

  // MARK: Playlist

  enum PlaylistToggle: Equatable {
    case hidden
    /// The wallpaper can be listed, but the target display has no playlist of its own to edit.
    case disabled(isListed: Bool)
    case enabled(isListed: Bool)
  }

  /// The list button adds the wallpaper to or removes it from the target display's own list, for a
  /// wallpaper the Mac can render; a mirror or a disabled target has no list to change.
  static func playlistToggle(_ row: LibraryRow, target: TargetDisplayOption?, listedIDs: [String])
    -> PlaylistToggle
  {
    guard row.isSupported else { return .hidden }
    let listed = listedIDs.contains(row.id)
    return target?.isSelectable == true ? .enabled(isListed: listed) : .disabled(isListed: listed)
  }

  // MARK: Reinstall

  /// An installed Workshop wallpaper (its id is the Workshop's number) that can run on macOS can be
  /// downloaded again to repair or refresh it, unless a download for it is under way or a request
  /// for it waits for setup (the page's `canReinstall`).
  static func canReinstall(_ row: LibraryRow, hasPendingDownload: Bool, hasRequest: Bool) -> Bool {
    isWorkshopID(row.id) && canRun(row.kind) && !hasPendingDownload && !hasRequest
  }

  static func isWorkshopID(_ id: String) -> Bool {
    !id.isEmpty && id.utf8.allSatisfy { (0x30...0x39).contains($0) }
  }

  // MARK: Problem report

  /// The problem report the inspector offers for an installed wallpaper.
  enum IssueReport: Equatable {
    /// None: nothing failed, and the wallpaper's type cannot run on macOS, which its own sentence
    /// already says; or it is a scene waiting for the shared resources, whose notice offers the
    /// fix instead.
    case none
    /// **Not working? Report on GitHub** under the type sentence, and the menu's report.
    case plain
    /// Applying it just failed: the failure notice carries the report, prefilled with the failure,
    /// and the plain link steps aside. The menu's report carries the failure too.
    case failure(String)
  }

  /// The page's `failureReport` and `report`: a failure always comes with its report; otherwise
  /// only a wallpaper that can run gets the plain one. A scene that cannot play because the shared
  /// scene resources are missing gets none, whatever failed: that is setup for the user to do, not
  /// a problem to report, and a report link beside it is read as the way out.
  static func issueReport(
    for row: LibraryRow, failure: String?, sceneResourcesMissing: Bool
  ) -> IssueReport {
    if sceneResourcesMissing, row.kind == .scene { return .none }
    if let failure { return .failure(failure) }
    return canRun(row.kind) ? .plain : .none
  }

  // MARK: Packaged stills

  /// A still image this app packaged: saved from pixiv or imported from disk.
  static func isPackagedStill(_ id: String) -> Bool {
    id.hasPrefix("pixiv-") || id.hasPrefix("image-")
  }

  /// The artwork id of a pixiv-packaged still (`pixiv-<artwork>-p<page>`).
  static func pixivArtworkID(of id: String) -> String? {
    guard id.hasPrefix("pixiv-") else { return nil }
    let parts = id.dropFirst("pixiv-".count).split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 2, !parts[0].isEmpty, parts[0].utf8.allSatisfy({ (0x30...0x39).contains($0) }),
      parts[1].hasPrefix("p"), parts[1].count > 1,
      parts[1].dropFirst().utf8.allSatisfy({ (0x30...0x39).contains($0) })
    else { return nil }
    return String(parts[0])
  }

  /// Which sentence describes the wallpaper under its header.
  enum KindNote: Equatable {
    case pixivStill, importedStill, scene, video, web, unsupported
  }

  static func kindNote(for row: LibraryRow) -> KindNote {
    if pixivArtworkID(of: row.id) != nil { return .pixivStill }
    if row.id.hasPrefix("image-") { return .importedStill }
    switch row.kind {
    case .scene: return .scene
    case .video: return .video
    case .web: return .web
    case .unknown: return .unsupported
    }
  }

  // MARK: Position

  /// What the note under a display's Position sliders says.
  enum PositionNote: Equatable {
    /// The native video player draws the wallpaper on this display and keeps it centred, with
    /// **Open Performance** to choose Compatibility instead. The sliders stay: the position is kept
    /// for when another player draws it.
    case nativePlayer
    /// What the sliders do.
    case explains
  }

  /// Only the display the native player draws on gets its note; another display of the same
  /// wallpaper is moved as usual.
  static func positionNote(for display: InspectorOptions.DisplayRow) -> PositionNote {
    display.isDrawnByNativePlayer ? .nativePlayer : .explains
  }

  // MARK: Sections

  /// Displays opens by itself once the wallpaper is on a display. The state is the person's from the
  /// first draw on, so a later change of the rows never opens or closes it.
  static func displaysOpenByDefault(_ options: InspectorOptions) -> Bool { !options.displays.isEmpty }

  /// Collections opens for a wallpaper that belongs to one.
  static func collectionsOpenByDefault(_ collections: [CollectionRow], wallpaperID: String) -> Bool {
    collections.contains { $0.wallpaperIDs.contains(wallpaperID) }
  }

  // MARK: Properties section

  /// Whether a property row has anything to draw: a control row always does (its name stands in for
  /// an empty label), a group or description only when its label has words, artwork or a rule.
  static func drawsRow(_ row: InspectorOptions.PropertyRow) -> Bool {
    switch row.control {
    case .heading, .description(detail: nil):
      return !labelDocument(for: row).isEmpty
    case .description:
      return true
    default:
      return true
    }
  }

  /// The rows the properties section shows, in the author's order.
  static func visibleProperties(_ options: InspectorOptions) -> [InspectorOptions.PropertyRow] {
    options.properties.filter(drawsRow)
  }

  /// The parsed label of a row: the author's markup, or the app's words as one plain paragraph.
  @MainActor
  static func labelDocument(for row: InspectorOptions.PropertyRow) -> PropertyLabelDocument {
    labelDocument(row.label)
  }

  @MainActor
  static func labelDocument(_ label: PropertyLabels.Presentation) -> PropertyLabelDocument {
    guard let markup = label.markup else {
      guard !label.text.isEmpty else { return PropertyLabelDocument(blocks: []) }
      return PropertyLabelDocument(blocks: [
        .paragraph(
          .init(runs: [.init(text: label.text)], heading: nil, isCentered: false, marker: nil))
      ])
    }
    return PropertyLabelCache.document(markup: markup, images: label.images)
  }
}

/// Parsed labels, kept like the page kept its 256 rendered ones: the inspector reads its rows
/// whenever anything it shows changes, and a label's parse is the one costly step.
@MainActor
enum PropertyLabelCache {
  private struct Key: Hashable {
    let markup: String
    let images: [String: URL]
  }
  private static var documents: [Key: PropertyLabelDocument] = [:]
  private static let limit = 256

  static func document(markup: String, images: [String: URL]) -> PropertyLabelDocument {
    let key = Key(markup: markup, images: images)
    if let known = documents[key] { return known }
    let document = PropertyLabelDocument.parse(markup, images: images)
    if documents.count >= limit { documents.removeAll(keepingCapacity: true) }
    documents[key] = document
    return document
  }
}
