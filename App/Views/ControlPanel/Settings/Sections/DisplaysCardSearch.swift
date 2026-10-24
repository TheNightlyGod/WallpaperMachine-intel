import Foundation

/// What a Settings search keeps of one display's card.
///
/// Every card declares the same items, but a display draws only some of them: a mirror has no
/// playlist, a day-and-night playlist has no Order, a display with no other display to copy to has
/// no Copy or swap. The search knows only the items, so on its own a match on Order would keep every
/// card and every Playlist disclosure, empty wherever the display does not draw that row. This
/// decides per display, from the rows the display draws (the web page matched each display's
/// rendered rows): a card or a disclosure stays while something it draws stays, or while its own
/// words matched. A card whose display's name matched keeps everything, as a card whose title
/// matched did on the web page, and a wallpaper of the display's own list is found by its title.
struct DisplaysCardSearch {
  /// What decides which rows a display's card draws.
  struct Rows: Equatable {
    var isMirror = false
    var playlistMode = PlaylistMode.off
    /// The playlist waits after its wallpaper was removed, so Resume playlist shows.
    var showsResume = false
    /// How often reads Custom, so the minutes field shows.
    var showsCustomInterval = false
    /// A rotation draws from the display's own list, so the list shows.
    var listsOwnWallpapers = false
    var hasSkipped = false
    /// The next day-and-night switch is dated.
    var showsNextSwitch = false
    /// There is another display to copy to or swap with.
    var hasPeers = false
    var automationMode = DisplayWallpaperAutomation.Mode.off
  }

  let search: SettingsSearch
  /// The display's name matched: the card keeps every row.
  let forced: Bool
  /// The wallpapers of the display's own list whose titles match, while the list is drawn.
  let listMatches: Set<String>
  let rows: Rows

  /// - Parameters:
  ///   - title: What the card's heading says (`titleText(of:)`).
  ///   - listTitles: The display's own list as it is drawn: the wallpapers the library holds.
  init(search: SettingsSearch, title: String, rows: Rows, listTitles: [(id: String, title: String)] = []) {
    self.search = search
    self.rows = rows
    forced = search.isActive && search.matches(title)
    listMatches =
      search.isActive && rows.listsOwnWallpapers && rows.playlistMode == .rotate && !rows.isMirror
      ? Set(listTitles.filter { search.matches($0.title) }.map(\.id)) : []
  }

  /// Whether the card is drawn: always without a search, otherwise while its name matched or
  /// anything it draws stays.
  var showsCard: Bool {
    !search.isActive || forced || holdsMatch(nil)
  }

  /// Whether a row of the card is drawn.
  func shows(_ item: SettingsItem) -> Bool { forced || search.shows(item) }

  /// Whether a disclosure of the card is drawn: while its own words matched, or something it draws
  /// stays.
  func showsDisclosure(_ item: SettingsItem) -> Bool {
    !search.isActive || forced || search.matchesItself(item) || holdsMatch(item)
  }

  /// Whether a search opens the disclosure on this display: something it draws matched. A
  /// disclosure that stays only for its own words, or for the display's name, stays folded.
  func opens(_ item: SettingsItem) -> Bool {
    guard search.isActive else { return false }
    if item.id == DisplaysSettingsSection.playlist.id, !listMatches.isEmpty { return true }
    return children(of: item).contains { child in
      search.matchesItself(child) || (Self.isDisclosure(child) && opens(child))
    }
  }

  /// Whether the display's own list keeps every row, or only the wallpapers in `listMatches`.
  var showsWholeList: Bool { shows(DisplaysSettingsSection.playlistList) }

  /// Whether a part of the card (the card itself for nil) draws something the search keeps.
  private func holdsMatch(_ disclosure: SettingsItem?) -> Bool {
    if disclosure?.id == DisplaysSettingsSection.playlist.id, !listMatches.isEmpty { return true }
    return children(of: disclosure).contains { child in
      Self.isDisclosure(child) ? showsDisclosure(child) : search.shows(child)
    }
  }

  /// The items the display draws directly in `disclosure`, or in the card itself for nil, in the
  /// card's order. Each follows the view's own condition for drawing the row.
  func children(of disclosure: SettingsItem?) -> [SettingsItem] {
    typealias S = DisplaysSettingsSection
    switch disclosure?.id {
    case nil:
      return [S.enable, S.mode] + (rows.isMirror ? [S.mirrorSource] : [S.wallpaper, S.desktops])
        + (rows.isMirror ? [] : [S.playlist]) + (rows.hasPeers ? [S.transfer] : [])
        + [S.automation, S.playback]
    case S.playlist.id:
      var items = [S.playlistMode]
      if rows.showsResume { items.append(S.playlistHeld) }
      switch rows.playlistMode {
      case .rotate:
        items += [S.playlistSource, S.playlistOrder, S.playlistInterval]
        if rows.showsCustomInterval { items.append(S.playlistCustom) }
        if rows.listsOwnWallpapers { items.append(S.playlistList) }
        if rows.hasSkipped { items.append(S.playlistSkipped) }
        items.append(S.playlistNext)
      case .dayNight:
        items += [S.playlistDay, S.playlistDayStart, S.playlistNight, S.playlistNightStart]
        if rows.showsNextSwitch { items.append(S.playlistSwitch) }
      case .off:
        break
      }
      return items + [S.playlistPlan]
    case S.transfer.id:
      return [S.transferPeer]
    case S.automation.id:
      let body: [SettingsItem]
      switch rows.automationMode {
      case .off: body = []
      case .appearance: body = [S.automationLight, S.automationDark]
      case .spaces: body = []
      case .schedule: body = [S.automationSchedule]
      }
      return [S.automationMode] + body + [S.automationFooter]
    case S.playback.id:
      return [S.scaling, S.scaleFactor, S.frameRate, S.mute, S.volume]
    default:
      return []
    }
  }

  private static let disclosures: Set<String> = [
    DisplaysSettingsSection.playlist.id, DisplaysSettingsSection.playlistSkipped.id,
    DisplaysSettingsSection.transfer.id, DisplaysSettingsSection.automation.id,
    DisplaysSettingsSection.playback.id,
  ]

  private static func isDisclosure(_ item: SettingsItem) -> Bool { disclosures.contains(item.id) }

  /// What a display's card heading says, which a search finds the card by: its name, and "Primary
  /// display" beside the primary display's.
  @MainActor
  static func titleText(of display: DisplayRow) -> String {
    display.isPrimary ? "\(display.title)\n\(L("Primary display"))" : display.title
  }
}

extension DisplaysCardSearch {
  /// The card search of `display` as the controller and the page state have it now. Without a query
  /// nothing is read: every row shows.
  @MainActor
  static func make(_ display: DisplayRow, controller: PanelController) -> DisplaysCardSearch {
    let search = controller.settings.search
    guard search.isActive else {
      return DisplaysCardSearch(search: search, title: display.title, rows: Rows())
    }
    let playlist = controller.playlistState(for: display.id)
    let rows = Rows(
      isMirror: display.isMirror, playlistMode: playlist.playlist.mode, showsResume: playlist.showsResume,
      showsCustomInterval:
        controller.displaysSettings.intervalDraft(of: display.id).selection(for: playlist.playlist) == .custom,
      listsOwnWallpapers: playlist.playlist.source == .list, hasSkipped: !playlist.skipped.isEmpty,
      showsNextSwitch: playlist.nextChangeText(locale: PanelLocale.shared.locale) != nil,
      hasPeers: !controller.transferPeers(of: display.id).isEmpty,
      automationMode: controller.automationState(for: display.id).mode)
    return DisplaysCardSearch(
      search: search, title: titleText(of: display), rows: rows,
      listTitles: rows.listsOwnWallpapers ? DisplaysSearchUnits.listTitles(playlist.playlist, controller: controller) : [])
  }
}

/// The rows of Settings › Displays built from live data, as the Settings search counts them: each
/// display's card (by its heading), each saved layout (its name, what goes where, why it cannot be
/// applied), and each wallpaper of a display's own list while the list is drawn.
enum DisplaysSearchUnits {
  @MainActor
  static func make(_ controller: PanelController) -> [SettingsLiveUnit] {
    var units: [SettingsLiveUnit] = []
    for display in controller.displayRows {
      units.append(SettingsLiveUnit(section: .displays, text: DisplaysCardSearch.titleText(of: display)))
      guard !display.isMirror else { continue }
      let playlist = controller.playlists.playlist(for: display.id)
      guard playlist.mode == .rotate, playlist.source == .list else { continue }
      for wallpaper in listTitles(playlist, controller: controller) {
        units.append(SettingsLiveUnit(section: .displays, text: wallpaper.title))
      }
    }
    for layout in controller.displayLayoutsState.layouts {
      units.append(
        SettingsLiveUnit(section: .displays, group: DisplaysSettingsSection.layouts, text: text(of: layout)))
    }
    return units
  }

  /// A display's own list as the order editor draws it: the wallpapers the library still holds, in
  /// the list's order, with their titles. One pass over the library.
  @MainActor
  static func listTitles(_ playlist: DisplayPlaylist, controller: PanelController) -> [(id: String, title: String)] {
    let listed = Set(playlist.wallpaperIDs)
    guard !listed.isEmpty else { return [] }
    var titles: [String: String] = [:]
    for wallpaper in controller.store.librarySnapshot.wallpapers where listed.contains(wallpaper.id) {
      titles[wallpaper.id] = wallpaper.title
    }
    return DisplaysPlaylistList.rows(of: playlist.wallpaperIDs, titles: titles).map { ($0.id, $0.title) }
  }

  /// Everything a saved layout's row says, which a search finds it by.
  @MainActor
  static func text(of layout: DisplayLayoutsState.Layout) -> String {
    ([layout.name] + layout.assignments.map { L("\($0.displayTitle): \($0.wallpaperTitle)") }
      + [layout.unavailableReason].compactMap { $0 }).joined(separator: "\n")
  }

  /// What the units are made of, so they are rebuilt only when one of these changes rather than each
  /// time a row of the page asks the search. The names macOS gives the screens are not read here:
  /// asking the screens for every row would cost more than the rows, and a screen that comes, goes
  /// or changes arrives as a new list of displays anyway.
  struct Key: Equatable {
    let displays: [BridgeDisplaySettingsRow]
    let library: UInt64
    let playlists: UInt64
    let layouts: UInt64
    let language: String

    @MainActor
    init(_ controller: PanelController) {
      displays = controller.store.settingsSnapshot.displays
      library = controller.store.libraryPresentationRevision
      playlists = controller.revisions.playlists
      layouts = controller.revisions.displayLayouts
      language = controller.settings.locale.tag
    }
  }
}
