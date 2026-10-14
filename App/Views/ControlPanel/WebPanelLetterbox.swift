import AppKit
import Foundation

/// What the Black bars card set, so it can tell its own unsaved factor from any other. The
/// wallpaper's `dirty` flag covers every unsaved edit and says nothing about which one it is.
struct LetterboxStagedFactor: Equatable {
  let wallpaperID: String
  let displayID: String
  let factor: Double
}

@MainActor
extension WebPanelController {
  func performLetterbox(_ action: String, request: WebPanelRequest) async throws -> Bool {
    guard action == "videoLetterboxCheck" || action == "videoLetterboxStage" else { return false }
    let id = try wallpaperID(request)
    let displayID = try request.string("displayID")
    if action == "videoLetterboxStage" {
      try await stageLetterboxFactor(id: id, displayID: displayID)
      return true
    }
    guard let context = letterboxContext(), context.wallpaperID == id, context.displayID == displayID,
          context.eligible else { throw WebPanelRequest.invalid }
    await letterbox.check(wallpaperID: id, displayID: displayID, libraryRevision: store.libraryRefreshRevision)
    return true
  }

  /// Fills in the target display's Scale factor with the factor that hides the measured bars.
  /// The page sends only which wallpaper and display it means: the factor is recomputed here from
  /// the stored bars and the display's size, and goes through the call behind the Displays
  /// section's field, so Apply changes and Revert keep their meaning.
  private func stageLetterboxFactor(id: String, displayID: String) async throws {
    // Refused before the file is touched when the page's card is out of date.
    _ = try letterboxStage(id: id, displayID: displayID)
    do {
      _ = try await letterbox.confirmedReport(
        wallpaperID: id, displayID: displayID, libraryRevision: store.libraryRefreshRevision)
    } catch VideoLetterboxStore.Confirmation.fileChanged {
      throw WallpaperActionError(message: String(localized: "The video changed since it was checked. Look for black bars again."))
    } catch is VideoLetterboxStore.Confirmation {
      throw WebPanelRequest.invalid
    }
    // Confirming suspends while the file is found and read: judge the card again afterwards.
    let stage = try letterboxStage(id: id, displayID: displayID)
    try await store.editScalingFactorAsync(wallpaperId: id, displayId: displayID, factor: stage.factor)
    letterboxStaged = LetterboxStagedFactor(wallpaperID: id, displayID: displayID, factor: stage.factor)
    AppLog.info("Black bar check for \(id): staged scale factor \(stage.factor) on display \(displayID) for bars: \(stage.bars.summary)")
  }

  private struct LetterboxStage {
    let bars: LetterboxDetector.Bars
    let factor: Double
  }

  /// The factor a stage request may set right now, or an invalid-request error when the card it
  /// came from no longer matches what is selected, checked and configured. Only Fill turns a
  /// factor into a crop; both video backends apply it (`NativeVideoLayout`, Compatibility), so
  /// which one plays the clip does not matter.
  private func letterboxStage(id: String, displayID: String) throws -> LetterboxStage {
    guard let context = letterboxContext(), context.wallpaperID == id, context.displayID == displayID,
          context.eligible, context.scalingMode == .fill,
          case .done(let report) = letterbox.phase(for: id, revision: store.libraryRefreshRevision),
          case .bars(let bars) = report.verdict,
          let viewport = letterbox.viewportProvider(displayID),
          case .factor(let factor) = LetterboxZoom.outcome(bars: bars, aspect: report.aspect, viewport: viewport),
          !Self.letterboxApplied(current: context.scalingFactor, suggested: factor)
    else { throw WebPanelRequest.invalid }
    return LetterboxStage(bars: bars, factor: factor)
  }

  func trackLetterboxDependencies() {
    _ = letterbox.changes
  }

  /// The black-bar card for the selected installed video, or nil for anything else. Built from
  /// the in-memory result and the target display's size: no file is read and no probe starts
  /// here. The suggested scale factor is computed now, not stored, because it depends on which
  /// display is the target.
  func letterboxSnapshot() -> [String: Any]? {
    letterbox.select(store.appSnapshot.selectedWallpaperId)
    let context = letterboxContext()
    forgetLetterboxStagedFactor(unlessHeldIn: context)
    guard let context else { return nil }
    let id = context.wallpaperID, displayID = context.displayID
    var payload: [String: Any] = ["wallpaperID": id, "displayID": displayID, "eligible": context.eligible]
    if let mode = context.scalingMode, let factor = context.scalingFactor {
      payload["current"] = ["scalingMode": Self.scaling(mode), "scalingFactor": factor]
    }
    switch letterbox.phase(for: id, revision: store.libraryRefreshRevision) {
    case .idle:
      payload["state"] = "idle"
    case .checking:
      payload["state"] = "checking"
    case .failed(let failure):
      payload["state"] = "failed"
      switch failure {
      case .unreadable: payload["reason"] = "unreadable"
      case .noVideoTrack: payload["reason"] = "noVideo"
      case .timedOut: payload["reason"] = "timedOut"
      case .fileChanged: payload["reason"] = "changed"
      }
    case .done(let report):
      switch report.verdict {
      case .none:
        payload["state"] = "none"
      case .bars(let bars):
        payload["state"] = "bars"
        payload["bars"] = Self.barsPayload(bars)
        // Fill is the only mode in which a scale factor crops the bars off the display.
        var suggested: Double?
        if context.scalingMode == .fill, let viewport = letterbox.viewportProvider(displayID) {
          switch LetterboxZoom.outcome(bars: bars, aspect: report.aspect, viewport: viewport) {
          case .alreadyHidden: payload["suggestion"] = ["kind": "hidden"]
          case .factor(let factor):
            payload["suggestion"] = ["kind": "factor", "factor": factor]
            suggested = factor
          case .implausible: payload["suggestion"] = ["kind": "implausible"]
          }
        }
        payload["stage"] = stagePayload(context, suggested: suggested)
      case .uneven(let bars):
        payload["state"] = "uneven"
        payload["bars"] = Self.barsPayload(bars)
      case .indeterminate(let reason):
        payload["state"] = "unclear"
        switch reason {
        case .tooDark: payload["reason"] = "dark"
        case .tooFewFrames: payload["reason"] = "fewFrames"
        case .disagree: payload["reason"] = "disagree"
        case .implausible: payload["reason"] = "implausible"
        }
      }
    }
    return payload
  }

  /// Whether the suggestion can be staged, and whether the display already has it.
  /// `pending` means the display's factor is the one this card set and it is still in the draft
  /// that Apply changes would save: a factor that was already saved stays quiet however many
  /// other edits the draft holds.
  private func stagePayload(_ context: LetterboxContext, suggested: Double?) -> [String: Any] {
    let applied = suggested.map { Self.letterboxApplied(current: context.scalingFactor, suggested: $0) } ?? false
    return [
      "available": context.eligible && suggested != nil && !applied,
      "applied": applied,
      "pending": applied && letterboxStaged.map { Self.letterboxHolds($0, context) } == true,
    ]
  }

  /// The staged factor is remembered only while it can still be the unsaved part of the draft:
  /// for the same wallpaper and display, at the same factor, with changes waiting. Once the draft
  /// is applied or reverted, the factor edited, or the selection or target display moved, a later
  /// unrelated edit must not bring the claim back.
  private func forgetLetterboxStagedFactor(unlessHeldIn context: LetterboxContext?) {
    guard let staged = letterboxStaged else { return }
    if let context, Self.letterboxHolds(staged, context) { return }
    letterboxStaged = nil
  }

  private static func letterboxHolds(_ staged: LetterboxStagedFactor, _ context: LetterboxContext) -> Bool {
    guard staged.wallpaperID == context.wallpaperID, staged.displayID == context.displayID,
          context.draftPending, let current = context.scalingFactor else { return false }
    return abs(current - staged.factor) < 0.0005
  }

  /// The display already has a factor that hides the bars. The suggestion carries half a percent
  /// of overscan, so a hair under it still does, and a larger factor the user chose is kept.
  private static func letterboxApplied(current: Double?, suggested: Double) -> Bool {
    guard let current else { return false }
    return current >= suggested - 0.005
  }

  private struct LetterboxContext {
    let wallpaperID: String
    let displayID: String
    let eligible: Bool
    let scalingMode: BridgeScalingMode?
    let scalingFactor: Double?
    /// The wallpaper has changes that Apply changes would save.
    let draftPending: Bool
  }

  private func letterboxContext() -> LetterboxContext? {
    guard let id = store.appSnapshot.selectedWallpaperId,
          let entry = store.librarySnapshot.wallpapers.first(where: { $0.id == id }),
          entry.kind == .video else { return nil }
    let displayID = navigation.targetDisplayID
    let display = store.settingsSnapshot.displays.first { $0.displayId == displayID }
    let options = store.wallpaperOptionsSnapshot.flatMap { $0.wallpaperId == id ? $0 : nil }
    let configuration = options?.displayConfigurations.first { $0.displayId == displayID }
    return LetterboxContext(
      wallpaperID: id, displayID: displayID,
      eligible: display?.enabled == true && display?.mode == .standalone && options != nil,
      scalingMode: configuration?.scalingMode ?? display?.scalingMode,
      scalingFactor: configuration?.scalingFactor ?? display?.scalingFactor,
      draftPending: options?.dirty == true)
  }

  private static func barsPayload(_ bars: LetterboxDetector.Bars) -> [String: Double] {
    ["top": bars.top, "bottom": bars.bottom, "left": bars.left, "right": bars.right]
  }

  /// The installed video file for the check, found through the same library validation the live
  /// preview uses instead of a third copy of the path checks.
  static func letterboxStore(for store: BridgeStore) -> VideoLetterboxStore {
    let letterbox = VideoLetterboxStore(entry: { [weak store] id, displayID in
      guard let store else { throw CancellationError() }
      let request = try await store.wallpaperPreviewRequestAsync(id: id, displayID: displayID)
      let validated = try await WallpaperPreviewLoader().validate(request)
      guard validated.kind == .video else { throw VideoLetterboxProbe.Failure.noVideoTrack }
      return validated.projectURL.appendingPathComponent(validated.entryFile)
    })
    letterbox.viewportProvider = { [weak store] displayID in
      guard let store else { return nil }
      let title = store.settingsSnapshot.displays.first { $0.displayId == displayID }?.title ?? ""
      guard let screen = DisplayGeometry.screen(displayID: displayID, title: title),
            screen.frame.width > 0, screen.frame.height > 0 else { return nil }
      return screen.frame.size
    }
    return letterbox
  }
}
