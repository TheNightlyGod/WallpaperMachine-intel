import Foundation
import Observation

/// The inline name field of the Collections section, and the delete confirmation: what the window
/// is doing with collections right now. The collections themselves, and every refusal, are the
/// model's (`createCollection`, `renameCollection`, `deleteCollection`).
///
/// A refusal of the name (empty after trimming is not one: nothing happens) stays in the field as
/// `failure` instead of going to the window's error banner, so the person sees it where they typed.
/// Any other failure goes to the banner, as a failed action always does.
@MainActor
@Observable
final class CollectionEditorModel {
  /// What the name field is for.
  enum Mode: Equatable {
    case create
    case rename(String)
  }

  unowned let controller: PanelController

  /// The field's purpose; nil while it is closed.
  private(set) var mode: Mode?
  /// What the field says, as typed.
  var name = ""
  /// Why the last submit was refused, shown under the field until the person types again.
  private(set) var failure: String?

  init(controller: PanelController) { self.controller = controller }

  var isOpen: Bool { mode != nil }

  /// Whether a collection change is in flight, which disables every collection control.
  var isChanging: Bool {
    [Self.createKey, Self.renameKey, Self.deleteKey].contains { controller.isBusy($0) }
  }

  static var createKey: String { PanelActionCoordinator.key("collectionCreate") }
  static var renameKey: String { PanelActionCoordinator.key("collectionRename") }
  static var deleteKey: String { PanelActionCoordinator.key("collectionDelete") }

  // MARK: Editing

  /// The "+" of the Collections heading: an empty field to name a new collection. The window has
  /// one collection name field at a time: the selection bar's closes.
  func beginCreate() {
    controller.library.cancelNewCollection()
    mode = .create
    name = ""
    failure = nil
  }

  /// A collection's Rename…: the field holds its current name. A collection that is gone opens
  /// nothing.
  func beginRename(_ id: String) {
    guard let row = controller.collectionRows.first(where: { $0.id == id }) else { return }
    controller.library.cancelNewCollection()
    mode = .rename(id)
    name = row.name
    failure = nil
  }

  /// Closes the field and drops what was typed.
  func cancel() {
    mode = nil
    name = ""
    failure = nil
  }

  /// The person typed: a refusal no longer describes what the field says.
  func clearFailure() { failure = nil }

  /// Return, or the field's Create or Save. Creating shows the new collection in the library and
  /// opens Installed; renaming closes the field. A refusal leaves the field open with its reason.
  /// An empty name does nothing.
  @discardableResult
  func submit() -> Task<Void, Never> {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let mode, !trimmed.isEmpty else { return Task {} }
    let controller = controller
    let key: String
    switch mode {
    case .create: key = Self.createKey
    case .rename: key = Self.renameKey
    }
    return controller.launch(key) { [self] in
      failure = nil
      var created: WallpaperCollection?
      do {
        switch mode {
        case .create:
          created = try await controller.createCollection(name: trimmed)
        case .rename(let id):
          try await controller.renameCollection(id, to: trimmed)
        }
      } catch is CancellationError {
        return
      } catch {
        // Only this editor's own: another field opened meanwhile has nothing to explain.
        if self.mode == mode { failure = error.localizedDescription }
        return
      }
      if self.mode == mode { cancel() }
      if let created {
        controller.library.show(.collection(created.id))
        if controller.navigation.selection != .wallpaper { try await controller.navigate(.wallpaper) }
      }
    }
  }

  // MARK: Deleting

  /// A collection's Delete…: asks first, and deleting leaves its wallpapers in the library. The
  /// library goes back to All wallpapers when the collection was the one shown, and the result is
  /// said aloud. Without a window nothing is asked and nothing is deleted.
  @discardableResult
  func requestDelete(_ id: String) -> Task<Void, Never> {
    guard let row = controller.collectionRows.first(where: { $0.id == id }) else { return Task {} }
    let controller = controller
    return controller.launch(Self.deleteKey) { [self] in
      let confirmed = await controller.dialogs.confirm(
        L("Delete “\(row.name)”? Its wallpapers stay in your library."), detail: "",
        button: L("Delete"))
      guard confirmed else { return }
      try await controller.deleteCollection(id)
      if controller.library.scope == .collection(id) { controller.library.show(.all) }
      if mode == .rename(id) { cancel() }
      controller.shell.say(L("Deleted “\(row.name)”."))
    }
  }

  /// A collection that was deleted elsewhere takes its rename with it.
  func reconcile() {
    if case .rename(let id) = mode, !controller.collectionRows.contains(where: { $0.id == id }) {
      cancel()
    }
  }
}
