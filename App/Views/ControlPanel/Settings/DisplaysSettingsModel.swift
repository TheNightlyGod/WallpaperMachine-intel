import Foundation
import Observation
import SwiftUI

/// Settings › Displays, and the page state the other four sections of settings-b keep with it.
///
/// What the stores and the controller's typed actions do not hold lives here: the values a control
/// shows while its change is on the way, the drafts of the editors (the Custom interval, the time
/// rule, the name forms), the status and error line of the layouts group, the choice of display to
/// copy to, and where keyboard focus goes when an editor closes. It reads and acts through
/// `controller`, which owns every store. The methods are `async` and `throws` the way the
/// controller's are, so a view runs them through `controller.launch` and a test awaits them.
@MainActor
@Observable
final class DisplaysSettingsModel {
  unowned let controller: PanelController

  init(controller: PanelController) { self.controller = controller }

  /// Page state of Settings › Storage that must outlive the page being rebuilt: the choices made
  /// between choosing a backup and restoring it.
  @ObservationIgnored lazy var backup = StorageBackupModel(controller: controller)

  // MARK: Disclosures

  /// The disclosures the person opened, by display and item: each display's Playlist is its own.
  private(set) var openDisclosures = Set<String>()

  /// Whether the disclosure of `item` on `display` is open: the person's choice, or a search that
  /// found something inside it. `searchOpens` is what the search decided for this display, which a
  /// display card works out from the rows it draws (`DisplaysCardSearch.opens(_:)`); without it, a
  /// match inside the item opens it.
  func isOpen(_ item: SettingsItem, display: String, searchOpens: Bool? = nil) -> Bool {
    openDisclosures.contains(Self.disclosureKey(item, display))
      || (searchOpens ?? controller.settings.search.opens(item))
  }

  func setOpen(_ isOpen: Bool, _ item: SettingsItem, display: String) {
    let key = Self.disclosureKey(item, display)
    if isOpen {
      openDisclosures.insert(key)
    } else {
      openDisclosures.remove(key)
    }
  }

  private static func disclosureKey(_ item: SettingsItem, _ display: String) -> String {
    "\(display)|\(item.id)"
  }

  // MARK: Search

  @ObservationIgnored private var cachedSearchUnits: (key: DisplaysSearchUnits.Key, units: [SettingsLiveUnit])?

  /// The page's rows built from live data, which the Settings search counts as it counts items: the
  /// display cards, the saved layouts and the wallpapers of each display's own list
  /// (`DisplaysSearchUnits`). Rebuilt only when what they are made of changes, because every row of
  /// the page asks the search while a query is typed.
  var searchUnits: [SettingsLiveUnit] {
    let key = DisplaysSearchUnits.Key(controller)
    if let cachedSearchUnits, cachedSearchUnits.key == key { return cachedSearchUnits.units }
    let units = DisplaysSearchUnits.make(controller)
    cachedSearchUnits = (key, units)
    return units
  }

  // MARK: Frame rate

  /// The ceiling that holds `display` below the frame rate it is set to, and the setting that sets
  /// it, for the note under its Frame rate row; nil when nothing limits it. The display's own saved
  /// rate is what is compared, never rewritten.
  func frameRateLimit(of display: DisplayRow) -> FrameRateCeiling? {
    controller.frameRateLimit(saved: Int(display.fps))
  }

  // MARK: Values on the way

  /// What a control shows from the moment it is changed until its change has run, by control key.
  /// A refused change takes the old value back, which is the stored one again.
  private(set) var drafts: [String: AnyHashable] = [:]

  /// A binding for a switch, menu or slider. Setting it shows the value at once and runs `commit`
  /// under `key`, so a second change of the same control waits for the first; an error reaches the
  /// banner, and the control shows what is stored once the change has run.
  func binding<Value: Hashable>(
    _ key: String, current: Value, commit: @escaping @MainActor (Value) async throws -> Void
  ) -> Binding<Value> {
    Binding(
      get: { (self.drafts[key] as? Value) ?? current },
      set: { newValue in
        self.drafts[key] = newValue
        self.controller.launch(key) {
          defer { self.drafts[key] = nil }
          try await commit(newValue)
        }
      })
  }

  /// Shows `value` for the control of `key` until its change has run, or takes it back with nil.
  /// For a control that makes its own change (the target menus), where `binding` does not fit.
  func setDraft(_ key: String, to value: AnyHashable?) { drafts[key] = value }

  // MARK: Display layouts, copy and swap

  enum LayoutEditor: Equatable {
    case new
    case rename(String)
  }

  /// Where keyboard focus goes next in the layouts group and the copy-or-swap rows.
  enum LayoutFocus: Hashable {
    case new
    case rename(String)
    case confirmDelete(String)
    case delete(String)
    case apply(String)
    case error
  }

  var layoutEditor: LayoutEditor?
  var layoutName = DisplaysNameForm()
  /// The layout whose Delete… was pressed and is waiting for its confirmation.
  var layoutDeleteArmed: String?
  /// "Display layout saved.", "Wallpaper arrangement applied.": the result of the last layout, copy
  /// or swap action, kept until the next one.
  private(set) var layoutStatus: String?
  /// Why the last layout, copy or swap action failed.
  private(set) var layoutError: String?
  /// The display whose Copy or swap gave `layoutStatus` or `layoutError`; nil when a layout action
  /// did. Only that display's Copy or swap disclosure repeats the result.
  private(set) var transferSource: String?
  /// The control that should take focus: the view moves it there and then calls `consumeLayoutFocus`.
  private(set) var layoutFocus: LayoutFocus?
  /// The display chosen to copy to or swap with, by source display. Not sent until a button is pressed.
  var peers: [String: String] = [:]

  func consumeLayoutFocus() { layoutFocus = nil }

  /// The peer chosen for `display`, or nil when none is, or the one chosen is no longer eligible.
  func peer(of display: String) -> DisplayRow? {
    guard let id = peers[display] else { return nil }
    return controller.transferPeers(of: display).first { $0.id == id }
  }

  func beginNewLayout() {
    planEditor = nil
    layoutEditor = .new
    layoutName = DisplaysNameForm()
    layoutDeleteArmed = nil
  }

  func beginRenaming(_ layout: DisplayLayoutsState.Layout) {
    planEditor = nil
    layoutEditor = .rename(layout.id)
    layoutName = DisplaysNameForm(layout.name)
    layoutDeleteArmed = nil
  }

  /// Closes the name form and returns focus to the button that opened it.
  func cancelLayoutEditor() {
    switch layoutEditor {
    case .new: layoutFocus = .new
    case .rename(let id): layoutFocus = .rename(id)
    case nil: break
    }
    layoutEditor = nil
  }

  func askToDelete(_ id: String) {
    layoutEditor = nil
    layoutDeleteArmed = id
    layoutFocus = .confirmDelete(id)
  }

  func cancelDelete() {
    if let id = layoutDeleteArmed { layoutFocus = .delete(id) }
    layoutDeleteArmed = nil
  }

  /// Saves the current arrangement or renames a layout, as the open name form says. A name the
  /// store refuses leaves the form open with the reason in the error box.
  func submitLayoutEditor() async {
    guard let editor = layoutEditor, layoutName.canSubmit else { return }
    let name = layoutName.trimmed
    await performLayoutAction {
      switch editor {
      case .new:
        try await controller.saveDisplayLayout(name: name)
      case .rename(let id):
        try await controller.renameDisplayLayout(id, to: name)
      }
    } onSuccess: {
      layoutEditor = nil
      switch editor {
      case .new:
        layoutStatus = L("Display layout saved.")
        // The limit disables Save current layout…, so focus lands on an action that still works.
        let state = controller.displayLayoutsState
        layoutFocus =
          state.isFull
          ? state.layouts.first { $0.unavailableReason == nil }.map { .apply($0.id) } ?? .error
          : .new
      case .rename(let id):
        layoutStatus = L("Layout renamed.")
        layoutFocus = .rename(id)
      }
    }
  }

  func deleteLayout(_ id: String) async {
    await performLayoutAction {
      try await controller.deleteDisplayLayout(id)
    } onSuccess: {
      layoutDeleteArmed = nil
      layoutStatus = L("Layout deleted. Current wallpapers are unchanged.")
      layoutFocus = .new
    }
  }

  func applyLayout(_ id: String) async {
    await performLayoutAction {
      try await controller.applyDisplayLayout(id)
    } onSuccess: {
      layoutStatus = L("Wallpaper arrangement applied.")
    }
  }

  func copyWallpaper(from source: String, to target: String) async {
    await performLayoutAction(from: source) {
      try await controller.copyWallpaper(from: source, to: target)
    } onSuccess: {
      layoutStatus = L("Wallpaper arrangement applied.")
    }
  }

  func swapWallpapers(_ first: String, _ second: String) async {
    await performLayoutAction(from: first) {
      try await controller.swapWallpapers(first, second)
    } onSuccess: {
      layoutStatus = L("Wallpaper arrangement applied.")
    }
  }

  /// Runs a layout, copy or swap action: the status and error of the previous one go, a failure
  /// lands in the group's error box and takes focus, and a success runs `onSuccess`. `source` is the
  /// display a copy or swap was started from.
  private func performLayoutAction(
    from source: String? = nil, _ action: () async throws -> Void, onSuccess: () -> Void
  ) async {
    layoutStatus = nil
    layoutError = nil
    transferSource = source
    do {
      try await action()
      onSuccess()
    } catch is CancellationError {
      return
    } catch {
      layoutError = error.localizedDescription
      layoutFocus = .error
    }
  }

  // MARK: Saved playlists

  enum PlanEditor: Equatable {
    /// Naming a copy of the display's playlist.
    case save(display: String)
    case rename(String)
  }

  var planEditor: PlanEditor?
  var planName = DisplaysNameForm()
  /// The saved playlist whose Delete… was pressed and is waiting for its confirmation.
  private(set) var planDeleteArmed: String?

  /// Where keyboard focus goes next in the Saved playlists group.
  enum PlanFocus: Hashable {
    case rename(String)
    case confirmDelete(String)
    case delete(String)
  }

  /// The control that should take focus: the view moves it there and then calls `consumePlanFocus`.
  private(set) var planFocus: PlanFocus?

  func consumePlanFocus() { planFocus = nil }

  /// Arms the delete of a saved playlist: the row asks to confirm, and focus moves to its Delete.
  func askToDeletePlan(_ id: String) {
    planEditor = nil
    planDeleteArmed = id
    planFocus = .confirmDelete(id)
  }

  /// Takes the armed delete back, and focus with it to the row's Delete….
  func cancelPlanDelete() {
    if let id = planDeleteArmed { planFocus = .delete(id) }
    planDeleteArmed = nil
  }

  // One name form is open at a time on the page: each takes the keyboard when it opens, and two
  // that did at once would take it from each other.
  func beginSavingPlan(of display: String) {
    layoutEditor = nil
    planEditor = .save(display: display)
    planName = DisplaysNameForm()
    planDeleteArmed = nil
  }

  func beginRenaming(_ plan: PlaylistPlanRow) {
    layoutEditor = nil
    planEditor = .rename(plan.id)
    planName = DisplaysNameForm(plan.name)
    planDeleteArmed = nil
  }

  /// Closes the name form; a rename returns focus to the row's Rename….
  func cancelPlanEditor() {
    if case .rename(let id) = planEditor { planFocus = .rename(id) }
    planEditor = nil
  }

  /// Saves or renames, as the open name form says; the form closes once the change has run.
  func submitPlanEditor() async throws {
    guard let editor = planEditor, planName.canSubmit else { return }
    let name = planName.trimmed
    switch editor {
    case .save(let display):
      try await controller.savePlaylistPlan(name: name, display: display)
    case .rename(let id):
      // Renaming to the name it has is not a change.
      if controller.playlistPlanRows.first(where: { $0.id == id })?.name != name {
        try await controller.renamePlaylistPlan(id, to: name)
      }
    }
    guard planEditor == editor else { return }
    planEditor = nil
    if case .rename(let id) = editor { planFocus = .rename(id) }
  }

  func deletePlan(_ id: String) async throws {
    try await controller.deletePlaylistPlan(id)
    planDeleteArmed = nil
  }

  // MARK: How often

  /// The Custom interval's draft, by display.
  private(set) var intervalDrafts: [String: DisplaysIntervalDraft] = [:]
  /// The display whose minutes field should take focus: the view moves it there and then calls
  /// `consumeIntervalFocus`.
  private(set) var intervalFocus: String?

  func intervalDraft(of display: String) -> DisplaysIntervalDraft { intervalDrafts[display] ?? .init() }

  func consumeIntervalFocus() { intervalFocus = nil }

  /// What the minutes field says now. Typing something new ends a refusal's alert. The field
  /// writing back the text it already holds (as it takes focus or lays out) changes nothing: a write
  /// of the same draft would draw the field again, and the field would write again.
  func setIntervalText(_ text: String, display: String) {
    var draft = intervalDraft(of: display)
    guard draft.text != text else { return }
    draft.text = text
    draft.isInvalid = false
    intervalDrafts[display] = draft
  }

  /// Chooses an entry of the How often menu. Custom sends nothing: it shows the minutes field.
  func chooseInterval(_ option: DisplaysIntervalOption, display: String) async throws {
    switch option {
    case .custom:
      intervalDrafts[display] = DisplaysIntervalDraft(customChosen: true, text: nil)
      intervalFocus = display
    case .preset(let minutes):
      intervalDrafts[display] = nil
      try await controller.editPlaylist(.interval(.preset(minutes)), display: display)
    case .unlock:
      intervalDrafts[display] = nil
      try await controller.editPlaylist(.interval(.unlock), display: display)
    }
  }

  /// Saves the typed minutes, as Return does. A text that is not a whole number of minutes in range
  /// sends nothing and stays in the field, which keeps the keyboard and says what it accepts;
  /// nothing typed is no change at all. A number the store refuses stays in the field too, next to
  /// the banner that says why.
  @discardableResult
  func commitCustomInterval(display: String) async throws -> Bool {
    guard let text = intervalDraft(of: display).text else { return false }
    guard let minutes = DisplaysIntervalDraft.minutes(from: text, locale: PanelLocale.shared.locale) else {
      intervalDrafts[display]?.isInvalid = true
      intervalFocus = display
      return false
    }
    try await controller.editPlaylist(.interval(.custom(minutes)), display: display)
    intervalDrafts[display] = nil
    return true
  }

  /// The minutes field was left: a number is saved; anything else, or nothing typed, ends both
  /// drafts, so the menu and the field show the saved interval again (the page's focus-out rule).
  /// Only leaving discards what was typed.
  func leaveCustomInterval(display: String) async throws {
    let draft = intervalDraft(of: display)
    guard draft.customChosen || draft.text != nil else { return }
    guard let text = draft.text,
      DisplaysIntervalDraft.minutes(from: text, locale: PanelLocale.shared.locale) != nil
    else {
      intervalDrafts[display] = nil
      return
    }
    try await commitCustomInterval(display: display)
  }

  // MARK: The display's own list

  /// What a screen reader is told after a move: "B moved to position 2 of 3."
  private(set) var listAnnouncement: String?

  /// A Move up, Move down or Remove button of one row of a display's list.
  struct ListFocus: Hashable {
    let display: String
    let id: String
    let button: DisplaysPlaylistList.Button
  }

  /// The button that should take focus after a move: the view moves it there and then calls
  /// `consumeListFocus`.
  private(set) var listFocus: ListFocus?

  func consumeListFocus() { listFocus = nil }

  /// Moves one wallpaper of the display's list a place up (-1) or down (+1) among the wallpapers
  /// the library still holds. `expected` is the order the press started from.
  func moveListWallpaper(_ id: String, by direction: Int, display: String) async throws {
    let installed = Set(controller.store.librarySnapshot.wallpapers.map(\.id))
    let stored = controller.playlistState(for: display).playlist.wallpaperIDs
    guard let order = PlaylistOrdering.moved(id, by: direction, in: stored, installed: installed)
    else { return }
    try await controller.reorderPlaylist(order, expected: stored, display: display)
    announceMove(of: id, in: order, installed: installed)
    // The pressed button can be disabled now that the row is first or last; focus then goes to the
    // row's other one rather than nowhere.
    listFocus = ListFocus(
      display: display, id: id,
      button: DisplaysPlaylistList.focusAfterMove(
        of: id, pressed: direction < 0 ? .up : .down, in: order.filter(installed.contains)))
  }

  /// A drag ended on `target`: the wallpaper takes its place. `expected` is the order the drag
  /// started from, so a list that changed meanwhile refuses the change instead of being overwritten.
  func dropListWallpaper(
    _ id: String, onto target: String, expected: [String], display: String
  ) async throws {
    let order = DisplaysPlaylistList.dropped(expected, moving: id, onto: target)
    guard order != expected else { return }
    try await controller.reorderPlaylist(order, expected: expected, display: display)
    announceMove(of: id, in: order, installed: Set(controller.store.librarySnapshot.wallpapers.map(\.id)))
  }

  private func announceMove(of id: String, in order: [String], installed: Set<String>) {
    let visible = order.filter(installed.contains)
    guard let index = visible.firstIndex(of: id) else { return }
    let title = controller.store.librarySnapshot.wallpapers.first { $0.id == id }?.title ?? id
    listAnnouncement = L("\(title) moved to position \(index + 1) of \(visible.count).")
  }

  // MARK: Time rules

  /// The time rule being edited and the display it belongs to.
  var ruleEditor: DisplaysRuleDraft?
  private(set) var ruleEditorDisplay: String?

  /// Where keyboard focus goes next in the automatic selection rows.
  enum AutomationFocus: Hashable {
    case addRule(display: String)
    case editRule(display: String, id: String)
    case firstDay
    case modePicker(display: String)
    case forget(display: String, desktop: String)
    /// The editor's first control, When, as the editor opens.
    case ruleEvent(display: String)
  }

  private(set) var automationFocus: AutomationFocus?

  func consumeAutomationFocus() { automationFocus = nil }

  /// Opens the editor for a new rule, or for `rule` when one is given.
  func beginRule(display: String, editing rule: WallpaperAutomationRule? = nil) {
    ruleEditorDisplay = display
    ruleEditor = rule.map(DisplaysRuleDraft.init(editing:)) ?? DisplaysRuleDraft()
    automationFocus = .ruleEvent(display: display)
  }

  /// Closes the editor and returns focus to the button that opened it.
  func cancelRule() {
    if let display = ruleEditorDisplay { automationFocus = Self.restoreFocus(display, ruleEditor?.id) }
    ruleEditor = nil
    ruleEditorDisplay = nil
  }

  /// Saves the open rule. A rule with no weekday is not sent: the editor says so, and focus goes to
  /// its first day.
  func saveRule() async throws {
    guard let draft = ruleEditor, let display = ruleEditorDisplay else { return }
    switch draft.edit(locale: PanelLocale.shared.locale) {
    case .failure(.noWeekday):
      ruleEditor?.showsDaysError = true
      automationFocus = .firstDay
    case .failure:
      return
    case .success(let edit):
      try await controller.saveAutomationRule(edit, display: display)
      ruleEditor = nil
      ruleEditorDisplay = nil
      automationFocus = Self.restoreFocus(display, draft.id)
    }
  }

  func removeRule(_ id: String, display: String) async throws {
    try await controller.removeAutomationRule(id, display: display)
    if ruleEditor?.id == id {
      ruleEditor = nil
      ruleEditorDisplay = nil
    }
    automationFocus = .addRule(display: display)
  }

  private static func restoreFocus(_ display: String, _ id: String?) -> AutomationFocus {
    id.map { .editRule(display: display, id: $0) } ?? .addRule(display: display)
  }

  /// Forgets the choice saved for a desktop that is gone. Focus goes to the next Forget button of
  /// the display, else to its mode menu.
  func forgetDesktop(_ desktop: String, display: String) async throws {
    let missing = controller.automationState(for: display).missingDesktops.map(\.id)
    try await controller.setAutomationDesktop(desktop, to: nil, display: display)
    let next = missing.drop { $0 != desktop }.dropFirst().first
    automationFocus =
      next.map { .forget(display: display, desktop: $0) } ?? .modePicker(display: display)
  }

  // MARK: Sunrise and sunset

  /// Where the sun rules take their times from.
  var solarSource: WallpaperSolarSource { controller.solarSettings.source }
  var solarSunriseMinute: Int { controller.solarSettings.fixedSunriseMinute }
  var solarSunsetMinute: Int { controller.solarSettings.fixedSunsetMinute }

  /// What the automatic source has to show: the position it keeps up to date, or that it
  /// has none yet.
  var solarAutomaticStatus: String {
    let tracker = controller.solarLocationTracker
    guard tracker.servicesEnabled else {
      return L("Location Services is turned off on this Mac. Turn it on in System Settings → Privacy & Security → Location Services.")
    }
    if tracker.isDenied {
      return L("Location access has not been granted yet. Allow it in System Settings → Privacy & Security → Location Services.")
    }
    if tracker.authorizationStatus == .notDetermined {
      return L("Allow location access to calculate sunrise and sunset for this Mac.")
    }
    guard let location = controller.solarSettings.location else {
      return L("Waiting for the current location…")
    }
    return String(
      format: L("Using the current location: %.4f, %.4f"), locale: PanelLocale.shared.locale,
      location.latitude, location.longitude)
  }

  /// True once the user has refused location access, where asking again would do nothing.
  var solarLocationDenied: Bool { controller.solarLocationTracker.isDenied }

  func setSolarSource(_ source: WallpaperSolarSource) async throws {
    try await controller.setSolarSource(source)
  }

  /// Updates one of the two fixed times, keeping the other as it is.
  func setSolarFixedTimes(sunrise: Int? = nil, sunset: Int? = nil) async throws {
    let current = controller.solarSettings
    try await controller.setSolarFixedTimes(
      sunriseMinute: sunrise ?? current.fixedSunriseMinute,
      sunsetMinute: sunset ?? current.fixedSunsetMinute)
  }

  /// Retries the permission request without changing the current source.
  func startAutomaticLocation() async throws {
    try await controller.requestSolarLocation()
  }

  /// What was typed in the coordinate fields; nil follows the saved location.
  var latitudeText: String?
  var longitudeText: String?

  /// Saves the typed coordinates, which both fields must hold as numbers within their range.
  /// Anything else sends nothing and puts the saved location back in the fields.
  @discardableResult
  func saveLocation() async throws -> Bool {
    let locale = PanelLocale.shared.locale
    let saved = controller.solarLocation
    let latitude = DisplaysNumberInput.parse(
      latitudeText ?? saved.map { DisplaysNumberInput.text($0.latitude, digits: 6, locale: locale) } ?? "",
      locale: locale)
    let longitude = DisplaysNumberInput.parse(
      longitudeText ?? saved.map { DisplaysNumberInput.text($0.longitude, digits: 6, locale: locale) } ?? "",
      locale: locale)
    guard let latitude, let longitude, (-90...90).contains(latitude),
      (-180...180).contains(longitude)
    else {
      latitudeText = nil
      longitudeText = nil
      return false
    }
    try await controller.setSolarLocation(latitude: latitude, longitude: longitude)
    latitudeText = nil
    longitudeText = nil
    return true
  }

  func clearLocation() async throws {
    try await controller.clearSolarLocation()
    latitudeText = nil
    longitudeText = nil
  }
}
