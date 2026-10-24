import SwiftUI

/// Settings › Displays: one card per display (power, mode, wallpaper, playlist, copy or swap,
/// automatic selection, playback and scaling), then the display layouts, the saved playlists and
/// the sunrise and sunset location.
///
/// A card repeats the same items for every display, so a search that finds one finds it on each
/// display that draws it (`DisplaysCardSearch`); a card also stays whole when the display's name is
/// what matched, and a saved layout or a wallpaper of a display's list is found by what it says.
struct DisplaysSettingsSection: View {
  // MARK: Groups

  static let card = SettingsItem.Group("display-card")
  static let layouts = SettingsItem.Group("layouts", title: "Display layouts")
  static let plans = SettingsItem.Group("plans", title: "Saved playlists")
  static let solar = SettingsItem.Group("solar", title: "Sunrise and sunset")

  // MARK: Page

  static let refresh = SettingsItem(id: "displays.refresh", section: .displays, title: "Refresh")

  // MARK: A display's card

  static let enable = SettingsItem(
    id: "displays.enable", section: .displays, group: card, title: "Enable wallpaper")
  static let mode = SettingsItem(
    id: "displays.mode", section: .displays, group: card, title: "Display mode",
    keywords: ["Independent", "Mirror another display"])
  static let mirrorSource = SettingsItem(
    id: "displays.mirror-source", section: .displays, group: card, title: "Mirror source",
    note: "No compatible display available.", keywords: ["Choose display"])
  static let wallpaper = SettingsItem(
    id: "displays.wallpaper", section: .displays, group: card, title: "Wallpaper",
    keywords: ["Choose…", "Eject", "None selected"])
  static let desktops = SettingsItem(
    id: "displays.desktops", section: .displays, group: card, title: "Different wallpaper for each desktop",
    note:
      "Each desktop keeps the wallpaper you apply while you are on it, and only the desktop you are on plays, so Mission Control shows the other desktops as still pictures. A desktop you have visited waits paused where you left it; one you have not visited yet shows a still picture until its first visit. Kept wallpapers use memory and are let go when the Mac runs short of it.",
    keywords: [
      "Desktop \(1)", "Keeps the current wallpaper", "Keep the current wallpaper", "Unavailable desktop",
      "Spaces", "Refresh Spaces",
      "Turning it on replaces this display’s automatic wallpaper selection.",
    ])

  // The playlist
  static let playlist = SettingsItem(
    id: "displays.playlist", section: .displays, group: card, title: "Playlist",
    keywords: ["Playlist paused", "Rotate wallpapers", "Day and night"])
  static let playlistMode = SettingsItem(
    id: "displays.playlist-mode", section: .displays, inside: playlist, title: "Changes on its own",
    note:
      "Only while wallpapers play. A change that falls due while they are paused, the screen is locked or the displays sleep happens once they play again.",
    keywords: ["Off", "Rotate wallpapers", "Day and night"])
  static let playlistHeld = SettingsItem(
    id: "displays.playlist-held", section: .displays, inside: playlist, title: "Playlist paused",
    note:
      "This display’s wallpaper was removed, so its playlist waits until you choose a wallpaper or resume it.",
    keywords: ["Resume playlist"])
  static let playlistSource = SettingsItem(
    id: "displays.playlist-source", section: .displays, inside: playlist, title: "Wallpapers",
    keywords: [
      "All wallpapers", "Favorites", "This display’s list (\(0))", "Collections",
      "A collection that no longer exists",
      "The collection this rotation used was deleted, so it plays nothing until you choose another source.",
      "Collections you make in Installed appear here too.",
    ])
  static let playlistOrder = SettingsItem(
    id: "displays.playlist-order", section: .displays, inside: playlist, title: "Order",
    keywords: ["In order", "Shuffle"])
  static let playlistInterval = SettingsItem(
    id: "displays.playlist-interval", section: .displays, inside: playlist, title: "How often",
    keywords: [
      "Every \(5) minutes", "Every \(10) minutes", "Every \(15) minutes", "Every \(30) minutes",
      "Every hour", "Every \(2) hours", "Every \(3) hours", "Every \(6) hours",
      "Every \(12) hours", "Every day", "Each time the Mac is unlocked", "Custom",
    ])
  static let playlistCustom = SettingsItem(
    id: "displays.playlist-custom", section: .displays, inside: playlist,
    title: "Minutes between changes", note: "Any whole number of minutes, up to \(10080).",
    keywords: ["min"])
  static let playlistNext = SettingsItem(
    id: "displays.playlist-next", section: .displays, inside: playlist, title: "Next change",
    keywords: [
      "Change now", "Changes when you unlock the Mac, while wallpapers are playing.",
      "Around \("12:00"), if wallpapers are playing then.",
      "Starts counting once wallpapers play.",
    ])
  static let playlistList = SettingsItem(
    id: "displays.playlist-list", section: .displays, inside: playlist, title: "Drag to reorder",
    note: "Drag wallpapers to reorder them, or use Move up and Move down.",
    keywords: [
      "Move up", "Move down",
      "The list is empty. In Installed, select wallpapers and choose Add to playlist, or use the list button in a wallpaper’s details.",
    ])
  static let playlistSkipped = SettingsItem(
    id: "displays.playlist-skipped", section: .displays, inside: playlist,
    title: "Temporarily skipped (\(0))",
    note: "Failed wallpapers are skipped for 15 minutes. You can still apply one manually.",
    keywords: ["Allow these wallpapers again"])
  static let playlistDay = SettingsItem(
    id: "displays.playlist-day", section: .displays, inside: playlist, title: "Day wallpaper",
    keywords: ["Leave as it is"])
  static let playlistDayStart = SettingsItem(
    id: "displays.playlist-day-start", section: .displays, inside: playlist, title: "Day starts at")
  static let playlistNight = SettingsItem(
    id: "displays.playlist-night", section: .displays, inside: playlist, title: "Night wallpaper",
    keywords: ["Leave as it is"])
  static let playlistNightStart = SettingsItem(
    id: "displays.playlist-night-start", section: .displays, inside: playlist,
    title: "Night starts at")
  static let playlistSwitch = SettingsItem(
    id: "displays.playlist-switch", section: .displays, inside: playlist, title: "Next switch",
    keywords: ["Around \("12:00")."])
  static let playlistPlan = SettingsItem(
    id: "displays.playlist-plan", section: .displays, inside: playlist, title: "Saved playlist",
    keywords: [
      "Choose a saved playlist…", "No saved playlists yet", "Save as…", "Playlist name",
      "Turn the playlist on to save it, or apply a saved one.",
      "Applying a saved playlist copies its settings to this display. Save as… keeps the settings above under a name.",
      "Using “\("Name")”. Changing a setting above keeps this display’s copy and detaches it from the saved playlist.",
    ])

  // Copy or swap
  static let transfer = SettingsItem(
    id: "displays.transfer", section: .displays, group: card, title: "Copy or swap wallpapers")
  static let transferPeer = SettingsItem(
    id: "displays.transfer-peer", section: .displays, inside: transfer, title: "Other display",
    note:
      "Only wallpaper choices are copied or swapped. Playlists and automatic rules keep running. Swapping needs a wallpaper on both displays.",
    keywords: ["Choose display", "Copy wallpaper", "Swap wallpapers"])

  // Automatic wallpaper selection
  static let automation = SettingsItem(
    id: "displays.automation", section: .displays, group: card,
    title: "Automatic wallpaper selection")
  static let automationMode = SettingsItem(
    id: "displays.automation-mode", section: .displays, inside: automation,
    title: "Automatic changes", note: "Manual choices stay until the next rule changes them.",
    keywords: [
      "Off", "Time schedule", "Follow system appearance", "Different wallpaper for each desktop",
      "Turn off animated lock-screen wallpaper to use desktop Space choices.",
      "Desktop information is unavailable. Refresh Spaces or choose another automatic mode.",
    ])
  static let automationLight = SettingsItem(
    id: "displays.automation-light", section: .displays, inside: automation,
    title: "In light appearance", keywords: ["Leave as it is", "Use wallpaper", "Use saved playlist"])
  static let automationDark = SettingsItem(
    id: "displays.automation-dark", section: .displays, inside: automation,
    title: "In dark appearance", keywords: ["Leave as it is", "Use wallpaper", "Use saved playlist"])
  static let automationSchedule = SettingsItem(
    id: "displays.automation-schedule", section: .displays, inside: automation,
    title: "Add time rule",
    note:
      "If times coincide, the later rule in this list wins. Missed changes wait until this display can play.",
    keywords: [
      "No time rules yet. Add one to choose when this display changes.", "Save rule",
      "Repeat on", "Weekdays", "Weekends", "Every day", "Switch to", "When", "At a time",
      "Sunrise", "Sunset", "Time", "Offset in minutes",
      "Negative offsets run before the sun event; positive offsets run after it. Set your location below.",
    ])
  static let automationFooter = SettingsItem(
    id: "displays.automation-footer", section: .displays, inside: automation,
    title: "Open Focus Settings…",
    note:
      "Choosing a wallpaper stops this display’s playlist. Choosing a saved playlist starts that plan. Focus choices temporarily override these rules.",
    keywords: [
      "Refresh Spaces", "Retry automatic change",
      "A Focus filter is active for this display. Manual choices remain available.",
    ])

  // Playback and scaling
  static let playback = SettingsItem(
    id: "displays.playback", section: .displays, group: card, title: "Playback & scaling",
    keywords: ["Choose a wallpaper to adjust playback."])
  static let scaling = SettingsItem(
    id: "displays.scaling", section: .displays, inside: playback, title: "Scaling",
    keywords: ["No scaling", "Stretch", "Match", "Fill"])
  static let scaleFactor = SettingsItem(
    id: "displays.scale-factor", section: .displays, inside: playback, title: "Scale factor")
  static let frameRate = SettingsItem(
    id: "displays.frame-rate", section: .displays, inside: playback, title: "Frame rate",
    keywords: [
      "Limited to \(60) fps by Performance settings", "Open Performance",
      "Limited to \(60) fps while the Mac is hot", "Limited to \(60) fps in Low Power Mode",
      "Limited to \(60) fps while the battery is low", "Limited to \(60) fps on battery",
    ])
  static let mute = SettingsItem(
    id: "displays.mute", section: .displays, inside: playback, title: "Mute audio")
  static let volume = SettingsItem(
    id: "displays.volume", section: .displays, inside: playback, title: "Volume")

  // MARK: Page-level groups

  static let layoutsSave = SettingsItem(
    id: "displays.layouts-save", section: .displays, group: layouts, title: "Save current layout…",
    note:
      "Save wallpaper choices for enabled independent displays. Empty and mirrored displays are left out. Playlists, automatic rules, properties and scaling are not saved in a layout.",
    keywords: [
      "Layout name", "Apply", "Rename…", "Delete…",
      "No saved layouts yet. Arrange your wallpapers, then save the layout.",
      "The limit of \(64) layouts is reached. Delete one before saving another.",
    ])
  static let plansList = SettingsItem(
    id: "displays.plans-list", section: .displays, group: plans, title: "Rename…",
    keywords: [
      "Delete…", "On 1 display",
      "No saved playlists yet. Set up a display’s playlist above, then choose Save as….",
    ])
  static let solarIntro = SettingsItem(
    id: "displays.solar-intro", section: .displays, group: solar, title: "Latitude",
    note:
      "Enter your coordinates. North and east are positive; south and west are negative. Times use your Mac’s time zone and are calculated locally.",
    keywords: [
      "Solar times are approximate. Near the poles, a day may have no sunrise or sunset.",
      "Some automatic wallpaper settings could not be read. Check your rules and Focus choices before using them.",
    ])
  static let solarLongitude = SettingsItem(
    id: "displays.solar-longitude", section: .displays, group: solar, title: "Longitude")
  static let solarSource = SettingsItem(
    id: "displays.solar-source", section: .displays, group: solar, title: "Time source",
    keywords: ["Coordinates", "Fixed times", "Automatic"])
  static let solarSunrise = SettingsItem(
    id: "displays.solar-sunrise", section: .displays, group: solar, title: "Sunrise time")
  static let solarSunset = SettingsItem(
    id: "displays.solar-sunset", section: .displays, group: solar, title: "Sunset time")
  static let solarActions = SettingsItem(
    id: "displays.solar-actions", section: .displays, group: solar, title: "Save location",
    keywords: ["Clear location", "Use current location"])

  /// The page's order.
  static let items: [SettingsItem] = [
    refresh, enable, mode, mirrorSource, wallpaper, desktops,
    playlist, playlistMode, playlistHeld, playlistSource, playlistOrder, playlistInterval,
    playlistCustom, playlistNext, playlistList, playlistSkipped, playlistDay, playlistDayStart,
    playlistNight, playlistNightStart, playlistSwitch, playlistPlan,
    transfer, transferPeer,
    automation, automationMode, automationLight, automationDark,
    automationSchedule, automationFooter,
    playback, scaling, scaleFactor, frameRate, mute, volume,
    layoutsSave, plansList, solarIntro, solarSource, solarSunrise, solarSunset,
    solarLongitude, solarActions,
  ]

  @Environment(PanelController.self) private var controller

  var body: some View {
    let rows = controller.displayRows
    SettingsPage(.displays) {
      VStack(alignment: .leading, spacing: 22) {
        if rows.isEmpty {
          DisplaysNoDisplays()
        } else {
          ForEach(rows) { DisplaysSettingsCard(display: $0) }
        }
        DisplaysLayoutsGroup()
        DisplaysPlansGroup()
        DisplaysSolarGroup()
      }
    } accessory: {
      DisplaysRefreshButton()
    }
    // Row buttons, menus, switches and fields share one size across Settings.
    .controlSize(.small)
  }
}

// MARK: - Pieces of the page

/// The page's one action, at the trailing edge of its header: read the displays again.
private struct DisplaysRefreshButton: View {
  @Environment(PanelController.self) private var controller

  var body: some View {
    let settings = controller.settings
    if settings.search.shows(DisplaysSettingsSection.refresh) {
      Button {
        controller.launch(PanelActionCoordinator.key("refreshDisplays")) {
          try await controller.refreshDisplays()
        }
      } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      .buttonStyle(.panelCapsule)
      .fixedSize()
      .disabled(controller.isStoreBusy || controller.isBusy(PanelActionCoordinator.key("refreshDisplays")))
      .accessibilityIdentifier(DisplaysSettingsSection.refresh.id)
    }
  }
}

/// What the page says when the renderer reports no display.
private struct DisplaysNoDisplays: View {
  @Environment(\.panelTheme) private var theme

  var body: some View {
    PanelCard {
      Text("No displays connected.")
        .font(.system(size: 13))
        .foregroundStyle(theme.surface.muted.color)
        .frame(maxWidth: .infinity, minHeight: 56)
    }
  }
}

/// The note of an item drawn as a line of its own, for the items that exist so the search can find
/// their text. Not drawn while the search leaves the item out.
struct DisplaysItemNote: View {
  let item: SettingsItem
  var forced = false

  @Environment(PanelController.self) private var controller

  var body: some View {
    let settings = controller.settings
    if (forced || settings.search.shows(item)), let note = item.note {
      DisplaysNote(text: settings.text(note))
    }
  }
}

/// The note of an item as a caption inside a row that has other things in it. Not drawn while the
/// search leaves the item out.
struct DisplaysCaption: View {
  let item: SettingsItem
  var forced = false

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let settings = controller.settings
    if (forced || settings.search.shows(item)), let note = item.note {
      Text(verbatim: settings.text(note))
        .font(.system(size: 11.5))
        .foregroundStyle(theme.surface.muted.color)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
