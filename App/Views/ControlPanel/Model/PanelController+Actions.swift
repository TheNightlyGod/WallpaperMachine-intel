import Foundation

/// How an action relates to the error banner and the command queue.
///
/// The web panel routed every action through one switch whose position decided both, and the
/// behavior is part of the contract: a banner for one failure must not vanish because the user
/// browsed Discover, and one wallpaper switch must not wait behind a Workshop search. Each typed
/// action picks the disposition its original had (the `D`, `Q` and `E` of the action catalog in
/// the inventory) and runs through `PanelController.run`.
enum ActionDisposition: Sendable {
  /// `E`: browsing, cancelling, settings the renderer never waits for, and the like. Leaves an
  /// older banner showing and never waits behind a running command.
  case immediate
  /// `E`, but sequenced: edits that must keep their order (a playlist edit, a Position slider's
  /// save, releasing a held wallpaper). Leaves an older banner showing, waits its turn.
  case immediateQueued
  /// `D` without a queue: clears the banner first, then runs now.
  case direct
  /// `Q`, and `D` with a slot (select, apply): clears the banner first, then waits its turn. With
  /// a `slot`, a newer command in the same slot replaces one still waiting.
  case queued

  var clearsBanner: Bool {
    switch self {
    case .direct, .queued: true
    case .immediate, .immediateQueued: false
    }
  }

  var waitsInQueue: Bool {
    switch self {
    case .immediateQueued, .queued: true
    case .immediate, .direct: false
    }
  }
}

extension PanelController {
  // MARK: Starting actions

  /// What a view calls: runs `operation` as a task and returns it (tests await it). A thrown error
  /// reaches the banner, the key is released whether it succeeded or not, and `policy` says what a
  /// repeat of a pending key means. A control disables itself on `isBusy(_:)`.
  ///
  /// ```swift
  /// Button("Apply") {
  ///   controller.launch(PanelActionCoordinator.key("activate", id: id)) {
  ///     try await controller.activate(id)
  ///   }
  /// }
  /// ```
  @discardableResult
  func launch(
    _ key: String? = nil, policy: PanelActionCoordinator.Policy = .dropDuplicates,
    operation: @escaping @MainActor () async throws -> Void
  ) -> Task<Void, Never> {
    actions.launch(key, policy: policy, operation: operation)
  }

  /// Whether the keyed action waits or runs.
  func isBusy(_ key: String) -> Bool { actions.isBusy(key) }

  /// Whether a command is running or waiting, or a wallpaper is being activated or applied:
  /// what locks Apply, Revert and property editing, and holds the support prompt.
  var isStoreBusy: Bool {
    store.commands.isBusy || store.activatingWallpaperID != nil || store.applyingWallpaperID != nil
  }

  // MARK: Running actions

  /// Runs `operation` the way its `disposition` says. Typed actions call this, so the order of the
  /// banner clear, the queue and the work is kept in one place.
  ///
  /// `slot`, `subject`, `origin` and `choosing` are `UserCommandQueue`'s: the slots in use are
  /// `BridgeStore.selectionSlot`, `BridgeStore.activationSlot(displayId:)` and `"preview"`.
  /// Returns false, without running, when a newer command in `slot` replaced this one while it
  /// waited; every disposition that does not wait returns true.
  ///
  /// A picker or a confirmation inside `operation` holds the queue while its sheet is open. Ask
  /// first and queue the work after (as delete always did) unless the original kept the order.
  @discardableResult
  func run(
    _ disposition: ActionDisposition, slot: String? = nil, subject: String? = nil,
    origin: ActivationOrigin = .user, choosing: [String] = [],
    _ operation: @MainActor () async throws -> Void
  ) async throws -> Bool {
    if disposition.clearsBanner { errors.clearAction() }
    guard disposition.waitsInQueue else {
      try await operation()
      return true
    }
    return try await store.commands.run(
      slot: slot, subject: subject, origin: origin, choosing: choosing, operation)
  }

  // MARK: Id resolvers

  /// `id` if it is an installed wallpaper, else the refusal every action gives for a tile that
  /// vanished while the user looked at it.
  func installedWallpaperID(_ id: String) throws -> String {
    guard store.librarySnapshot.wallpapers.contains(where: { $0.id == id }) else {
      throw WallpaperActionError(
        message: L("This wallpaper is no longer installed. Refresh your library."))
    }
    return id
  }

  /// The distinct installed ids of `ids`, in request order. Empty or more than 4,096 is invalid,
  /// and any id that is not installed refuses the whole batch.
  func installedWallpaperIDs(_ ids: [String]) throws -> [String] {
    guard !ids.isEmpty, ids.count <= 4096 else { throw InvalidControlValue() }
    let installed = Set(store.librarySnapshot.wallpapers.map(\.id))
    var seen = Set<String>()
    let distinct = ids.filter { seen.insert($0).inserted }
    guard distinct.allSatisfy(installed.contains) else {
      throw WallpaperActionError(
        message: String(
          localized: "Some selected wallpapers are no longer installed. Refresh your library."))
    }
    return distinct
  }

  /// The display a per-display action means: `displayID`, or the target display when it names
  /// none. Only an enabled display that shows a wallpaper of its own has a playlist, an apply
  /// target or a position.
  func standaloneDisplayID(_ displayID: String? = nil) throws -> String {
    let id = displayID ?? navigation.targetDisplayID
    guard
      store.settingsSnapshot.displays.contains(where: {
        $0.displayId == id && $0.enabled && $0.mode == .standalone
      })
    else { throw InvalidControlValue() }
    return id
  }
}
