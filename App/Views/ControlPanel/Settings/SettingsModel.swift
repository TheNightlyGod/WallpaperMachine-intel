import Foundation
import Observation

/// Settings: the sections, the search, the rows and how they edit.
///
/// The navigation and search state of the Settings pages lives here: which section is on show, what
/// the search field says, which disclosures are open. The values the rows edit come from the
/// controller and its typed settings actions. It reads and acts through `controller`, which owns
/// every store.
///
/// Editing follows one model for every control (the web page's `drafts` and `pending`): a control
/// shows the value it just sent (its *draft*) until the change has run, then the value the stores
/// report, so a refused change snaps back. A change runs through `controller.launch`, one at a time
/// per setting, and its failure reaches the panel's error banner, which is the one place errors
/// show. While a wallpaper is changing or another change is running the other controls wait.
@MainActor
@Observable
final class SettingsModel {
  unowned let controller: PanelController

  // MARK: Navigation and search

  /// The section on show. A window starts on Quick Settings.
  private(set) var selectedSection = SettingsSection.quick
  /// Counts the times a section was chosen or revealed, so the page scrolls back to its top even
  /// when the choice is the section already on show.
  private(set) var scrollEpoch = 0
  /// What the search field says, as typed.
  var query = ""
  /// The disclosures the person opened. A search opens more for as long as it lasts.
  private(set) var openDisclosures = Set<String>()
  @ObservationIgnored private var cachedSearch:
    (query: String, tag: String, unoffered: Set<String>, live: [SettingsLiveUnit], search: SettingsSearch)?
  @ObservationIgnored private var indexes: [String: SettingsIndex] = [:]
  /// Where search phrases are read in, the panel's language.
  @ObservationIgnored var locale: PanelLocale = .shared

  // MARK: Editing

  /// A value a control has sent that the stores have not confirmed yet.
  struct Draft {
    let value: AnyHashable
    /// Tells this change from a newer one of the same setting, so an older one finishing does not
    /// take the newer one's value away.
    let token: UInt64
  }

  /// What each control shows until its change has run, by setting key. A Quick Settings tile and
  /// the full row of the same setting share a key, so they follow each other at once.
  private(set) var drafts: [String: Draft] = [:]
  @ObservationIgnored private var nextDraftToken: UInt64 = 0

  init(controller: PanelController) { self.controller = controller }

  /// What the query keeps. Cached for the query, the language, the rows this Mac draws now and
  /// the live rows, because every row of the page asks.
  ///
  /// Only the rows the pages draw now are searched (`SettingsIndex.offering`). While a query is
  /// typed, reading this reads the facts that decide which those are
  /// (`SettingsRegistry.unofferedItems`), so the results follow a battery appearing or a choice that
  /// adds rows. Without a query it reads nothing more: every row is drawn by its own rule.
  var search: SettingsSearch {
    let tag = locale.tag
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let unoffered = trimmed.isEmpty ? [] : SettingsRegistry.unofferedItems(controller)
    // The rows built from live data (display names, saved layouts, listed wallpapers) are read only
    // while a query is typed; the Displays model keeps them cached.
    let live = trimmed.isEmpty ? [] : controller.displaysSettings.searchUnits
    if let cachedSearch, cachedSearch.query == trimmed, cachedSearch.tag == tag,
      cachedSearch.unoffered == unoffered, cachedSearch.live == live
    {
      return cachedSearch.search
    }
    let index = indexes[tag] ?? SettingsIndex(locale: locale)
    indexes[tag] = index
    let search = SettingsSearch(
      query: trimmed, index: unoffered.isEmpty ? index : index.offering { !unoffered.contains($0.id) },
      live: live)
    cachedSearch = (trimmed, tag, unoffered, live, search)
    return search
  }

  /// A phrase of a row or section in the panel's language.
  func text(_ resource: LocalizedStringResource) -> String { locale.string(resolving: resource) }

  /// Shows a section, as a click on its row in the section list does: the search ends and the page starts at
  /// its top.
  func select(_ section: SettingsSection) {
    query = ""
    selectedSection = section
    scrollEpoch += 1
  }

  /// Shows the section the app asked to reveal, once. A reveal made before the window existed is
  /// picked up as the window opens; one a window already acted on is not repeated by the next
  /// window, which starts on Quick Settings.
  func adoptReveal() {
    let navigation = controller.navigation
    guard navigation.settingsSectionToken != navigation.handledSettingsRevealToken else { return }
    navigation.handledSettingsRevealToken = navigation.settingsSectionToken
    select(navigation.settingsSection)
  }

  func isOpen(_ disclosure: SettingsItem) -> Bool {
    openDisclosures.contains(disclosure.id) || search.opens(disclosure)
  }

  func setOpen(_ isOpen: Bool, for disclosure: SettingsItem) {
    if isOpen {
      openDisclosures.insert(disclosure.id)
    } else {
      openDisclosures.remove(disclosure.id)
    }
  }

  // MARK: Editing

  /// The key a setting's change is tracked under, for `controller.isBusy`.
  static func actionKey(_ setting: String) -> String {
    PanelActionCoordinator.key("setting", detail: setting)
  }

  /// The value to show for a setting: what its control just sent while that change is on its way,
  /// otherwise `saved`.
  func value<Value: Hashable>(_ key: String, saved: Value) -> Value {
    (drafts[key]?.value.base as? Value) ?? saved
  }

  /// No settings snapshot has arrived yet, so the renderer-backed controls have nothing true to
  /// show. Appearance and language live in the app and stay usable.
  var isUnavailable: Bool { controller.store.snapshotRevision == 0 }

  /// Whether a control that changes the renderer or a store has to wait.
  ///
  /// It waits while there is no snapshot, and while a wallpaper is changing or another change is
  /// running, so a second change is never submitted behind the first. The control whose own change
  /// is the one running stays enabled (its repeat is dropped), so a keyboard user's focus is not
  /// taken away by pressing it. `whileRunning` disables the control for its own change too, for a
  /// button that must not be pressed twice, such as Retry.
  func isLocked(_ key: String? = nil, whileRunning: Bool = false) -> Bool {
    if isUnavailable { return true }
    let own = key.map { controller.isBusy(Self.actionKey($0)) } ?? false
    if own { return whileRunning }
    return controller.isStoreBusy
  }

  /// Sends `value` for the setting `key`: the control shows it at once, `perform` runs queued, and the
  /// control shows what the stores say once it has (so a refusal puts the old value back).
  ///
  /// With `.dropDuplicates` a change that arrives while the setting's own is still running is
  /// ignored and nil is returned: one at a time, as the web page did. A slider or a field sends
  /// every value it settles on with `.latestWins` so the newest lands last.
  @discardableResult
  func commit<Value: Hashable>(
    _ key: String, to value: Value,
    policy: PanelActionCoordinator.Policy = .dropDuplicates,
    perform: @escaping @MainActor (Value) async throws -> Void
  ) -> Task<Void, Never>? {
    let actionKey = Self.actionKey(key)
    if policy == .dropDuplicates, controller.isBusy(actionKey) { return nil }
    nextDraftToken &+= 1
    let token = nextDraftToken
    drafts[key] = Draft(value: AnyHashable(value), token: token)
    return controller.launch(actionKey, policy: policy) { [weak self] in
      defer { self?.settle(key, token: token) }
      try await perform(value)
    }
  }

  /// Starts what a button of a Settings row does (Retry, Open Login Items, Add app), tracked under
  /// `name` so the button can disable itself with `isLocked(name, whileRunning: true)` and a second
  /// press is dropped.
  @discardableResult
  func perform(
    _ name: String, operation: @escaping @MainActor () async throws -> Void
  ) -> Task<Void, Never> {
    controller.launch(Self.actionKey(name), operation: operation)
  }

  /// Applies an appearance choice, which the app does at once: `change` runs now, and a value the
  /// store refuses (a control never offers one) goes to the error banner. Appearance has no draft
  /// and never waits for the Mac, so it stays usable whatever the renderer is doing.
  func applyTheme(_ change: () throws -> Void) {
    do {
      try change()
    } catch {
      controller.errors.report(error)
    }
  }

  private func settle(_ key: String, token: UInt64) {
    if drafts[key]?.token == token { drafts[key] = nil }
  }
}
