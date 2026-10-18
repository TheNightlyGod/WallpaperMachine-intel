import Foundation

/// The presets bar's own state: the preset picked in the menu, a name being typed, and a Delete
/// waiting for its second click. The controller owns the presets and every file they touch; the bar
/// keeps only this, per wallpaper (a new wallpaper starts with none of it).
///
/// The rules are `presets.js`': the picked, edited and armed presets follow the list, so a preset
/// that was deleted, or another wallpaper's list arriving, drops them; picking another preset
/// disarms Delete; saving picks the preset it created. Arming Delete moves keyboard focus to the
/// confirming **Delete**, and Cancel takes it back to **Delete…**.
struct PresetsBarState: Equatable {
  /// A control that is to take keyboard focus once it is drawn: the one that replaced the control
  /// that had it.
  enum Focus: Hashable {
    case confirmDelete
    case deleteLink
  }

  struct Editor: Equatable {
    enum Mode: Equatable {
      case save
      case rename(presetID: String)
    }
    var mode: Mode
    var name: String

    /// The name as it would be saved: trimmed, and nil when there is nothing to save.
    var trimmedName: String? {
      let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
  }

  /// The longest preset name the field takes.
  static let maximumNameLength = 120

  /// The preset chosen in the menu, for Apply, Rename, Export and Delete; empty for none.
  private(set) var picked = ""
  private(set) var editor: Editor?
  /// The preset whose Delete has been pressed once; empty for none.
  private(set) var armed = ""
  /// Where focus goes next; the card hands it to its focus state when that control appears.
  private(set) var focusRequest: Focus?

  /// Follows the list: what no longer exists is dropped.
  mutating func sync(items: [PresetsState.Item]) {
    let ids = Set(items.map(\.id))
    if !picked.isEmpty, !ids.contains(picked) { picked = "" }
    if case .rename(let id)? = editor?.mode, !ids.contains(id) { editor = nil }
    if !armed.isEmpty, !ids.contains(armed) { disarm() }
  }

  mutating func pick(_ id: String) {
    picked = id
    disarm()
  }

  mutating func beginSave() {
    editor = Editor(mode: .save, name: "")
    disarm()
  }

  mutating func beginRename(of preset: PresetsState.Item) {
    editor = Editor(mode: .rename(presetID: preset.id), name: preset.name)
    disarm()
  }

  mutating func setName(_ name: String) {
    editor?.name = String(name.prefix(Self.maximumNameLength))
  }

  /// Escape, Cancel, or the end of a send that took the name.
  mutating func closeEditor() { editor = nil }

  /// Delete… was pressed: the confirmation shows, and its **Delete** takes focus from the link that
  /// went away.
  mutating func beginDelete(of preset: PresetsState.Item) {
    armed = preset.id
    focusRequest = .confirmDelete
  }

  /// The confirmation's Cancel: focus goes back to **Delete…**, which shows again.
  mutating func cancelDelete() {
    armed = ""
    focusRequest = .deleteLink
  }

  /// Delete is no longer armed, and nothing waits for focus that it asked for.
  mutating func disarm() {
    armed = ""
    if focusRequest == .confirmDelete { focusRequest = nil }
  }

  /// The control `focus` names has taken focus, or could not, which ends the request.
  mutating func focusTaken(_ focus: Focus) {
    if focusRequest == focus { focusRequest = nil }
  }

  /// A preset was deleted: Delete is no longer armed, and the menu forgets it if it was picked.
  mutating func didDelete(_ id: String) {
    disarm()
    if picked == id { picked = "" }
  }

  /// A save went through: the editor closes and the new preset is picked.
  mutating func didSave(created id: String?) {
    editor = nil
    if let id { picked = id }
  }

  // MARK: What the bar offers

  /// The picked preset, when it is still in the list.
  func chosen(in items: [PresetsState.Item]) -> PresetsState.Item? {
    items.first { $0.id == picked }
  }

  /// Delete is waiting for its confirmation.
  func isConfirmingDelete(in items: [PresetsState.Item]) -> Bool {
    chosen(in: items).map { armed == $0.id } == true && editor == nil
  }

  /// Pending edits block both directions: the wallpaper does not have them yet, so they are not
  /// worth saving, and a preset applied over them would throw them away unasked.
  func canApply(_ state: PresetsState, isPending: Bool) -> Bool {
    !isPending && chosen(in: state.items) != nil && !state.isDirty
  }

  func canSave(_ state: PresetsState, isPending: Bool) -> Bool {
    !isPending && state.canSave && !state.isDirty
  }

  func canPick(_ state: PresetsState, isPending: Bool) -> Bool {
    !isPending && !state.items.isEmpty
  }

  /// The link row is hidden while the name editor or the delete confirmation shows.
  func showsTools(in items: [PresetsState.Item]) -> Bool {
    editor == nil && !isConfirmingDelete(in: items)
  }

  func showsDirtyNote(_ state: PresetsState) -> Bool { state.isDirty && editor == nil }
}
