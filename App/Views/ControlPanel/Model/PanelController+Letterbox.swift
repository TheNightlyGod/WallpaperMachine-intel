import Foundation

/// The Black bars card of the selected installed video on the target display: what an explicit check
/// found, and what Fill with a scale factor would do about it on this display.
///
/// Built from the in-memory result and the display's size: no file is read and no probe starts. The
/// suggested factor is worked out on read, not stored, because it depends on which display is the
/// target.
struct LetterboxState: Equatable {
  enum Outcome: Equatable {
    /// Not checked, or the library was refreshed since (the file may have been replaced).
    case idle
    case checking
    case failed(Failure)
    /// No bar on any side.
    case none
    /// Bars on one or both axes, each pair matching, so a centred zoom can hide them.
    case bars(LetterboxDetector.Bars, suggestion: Suggestion?, stage: Stage)
    /// Bars exist but one side is missing or lopsided, so a scale factor would also cut picture.
    case uneven(LetterboxDetector.Bars)
    case unclear(Unclear)
  }

  enum Failure: Equatable { case unreadable, noVideo, timedOut, changed }
  enum Unclear: Equatable { case dark, fewFrames, disagree, implausible }

  /// What Fill and a scale factor would do about the bars, in Fill only: it is the one mode in which
  /// a factor crops them off the display.
  enum Suggestion: Equatable {
    case alreadyHidden
    case factor(Double)
    case implausible
  }

  /// Whether the suggested factor can be set, and whether the display has it already. `pending`
  /// means the display's factor is the one this card set and it is still in the draft that Apply
  /// changes would save: a factor that was already saved stays quiet however many other edits the
  /// draft holds.
  struct Stage: Equatable {
    let isAvailable: Bool
    let isApplied: Bool
    let isPending: Bool
  }

  /// Where the bars sit and how wide the widest is, as the card words them.
  enum Layout: Equatable {
    case allFourSides(percent: Int)
    case leftAndRight(percent: Int)
    case topAndBottom(percent: Int)
  }

  let wallpaperID: String
  let displayID: String
  /// The target is an enabled independent display with the wallpaper's options loaded: the check can
  /// run and a factor can be staged.
  let isEligible: Bool
  /// What the display does with the video now.
  let scalingMode: BridgeScalingMode?
  let scalingFactor: Double?
  let outcome: Outcome

  /// How the card describes `bars`: both vertical bars and both horizontal ones is all four sides,
  /// a matching left and right pair is the sides, anything else the top and bottom. The percent is
  /// that of the widest bar, at least 1.
  static func layout(of bars: LetterboxDetector.Bars) -> Layout {
    func percent(_ value: Double) -> Int { max(1, Int((value * 100).rounded())) }
    let vertical = bars.top > 0 && bars.bottom > 0
    let horizontal = bars.left > 0 && bars.right > 0
    if vertical && horizontal { return .allFourSides(percent: percent(bars.widest)) }
    if horizontal { return .leftAndRight(percent: percent(max(bars.left, bars.right))) }
    return .topAndBottom(percent: percent(max(bars.top, bars.bottom)))
  }
}

extension PanelController {
  /// The card for the selected installed video, or nil for anything else: a scene has no baked-in
  /// bars to look for.
  var letterboxState: LetterboxState? {
    startInspectorContextObservation()
    _ = letterbox.changes
    guard let context = letterboxContext() else { return nil }
    let id = context.wallpaperID
    let displayID = context.displayID
    let outcome: LetterboxState.Outcome
    switch letterbox.phase(for: id, revision: store.libraryRefreshRevision) {
    case .idle:
      outcome = .idle
    case .checking:
      outcome = .checking
    case .failed(let failure):
      switch failure {
      case .unreadable: outcome = .failed(.unreadable)
      case .noVideoTrack: outcome = .failed(.noVideo)
      case .timedOut: outcome = .failed(.timedOut)
      case .fileChanged: outcome = .failed(.changed)
      }
    case .done(let report):
      switch report.verdict {
      case .none:
        outcome = .none
      case .bars(let bars):
        var suggestion: LetterboxState.Suggestion?
        var suggested: Double?
        // Fill is the only mode in which a scale factor crops the bars off the display.
        if context.scalingMode == .fill, let viewport = letterbox.viewportProvider(displayID) {
          switch LetterboxZoom.outcome(bars: bars, aspect: report.aspect, viewport: viewport) {
          case .alreadyHidden: suggestion = .alreadyHidden
          case .factor(let factor):
            suggestion = .factor(factor)
            suggested = factor
          case .implausible: suggestion = .implausible
          }
        }
        outcome = .bars(
          bars, suggestion: suggestion, stage: letterboxStage(context, suggested: suggested))
      case .uneven(let bars):
        outcome = .uneven(bars)
      case .indeterminate(let reason):
        switch reason {
        case .tooDark: outcome = .unclear(.dark)
        case .tooFewFrames: outcome = .unclear(.fewFrames)
        case .disagree: outcome = .unclear(.disagree)
        case .implausible: outcome = .unclear(.implausible)
        }
      }
    }
    return LetterboxState(
      wallpaperID: id, displayID: displayID, isEligible: context.eligible,
      scalingMode: context.scalingMode, scalingFactor: context.scalingFactor, outcome: outcome)
  }

  /// `videoLetterboxCheck`: samples a few frames of the file for bars baked into the picture, and
  /// changes nothing. Leaves the banner alone and does not wait for the command queue. A card for
  /// another wallpaper or display than the ones selected and targeted now, or a target that is not
  /// an enabled independent display, is refused without decoding anything. Results are kept for the
  /// last 16 wallpapers and read as not checked after a library refresh.
  func checkLetterbox(_ wallpaperID: String, display displayID: String) async throws {
    try await run(.immediate) {
      let id = try installedWallpaperID(wallpaperID)
      guard let context = letterboxContext(), context.wallpaperID == id,
        context.displayID == displayID, context.eligible
      else { throw InvalidControlValue() }
      await letterbox.check(
        wallpaperID: id, displayID: displayID, libraryRevision: store.libraryRefreshRevision)
    }
  }

  /// `videoLetterboxStage`: fills in the target display's Scale factor with the factor that hides
  /// the measured bars. The control sends only which wallpaper and display it means: the factor is
  /// worked out here from the stored bars and the display's size, so nothing the control sends can
  /// change it, and it goes through the call behind the Displays card's field, so Apply changes and
  /// Revert keep their meaning. Leaves the banner alone and does not wait for the command queue.
  func stageLetterboxFactor(_ wallpaperID: String, display displayID: String) async throws {
    try await run(.immediate) {
      let id = try installedWallpaperID(wallpaperID)
      // Refused before the file is touched when the card is out of date.
      _ = try stagedLetterboxFactor(id: id, displayID: displayID)
      do {
        _ = try await letterbox.confirmedReport(
          wallpaperID: id, displayID: displayID, libraryRevision: store.libraryRefreshRevision)
      } catch VideoLetterboxStore.Confirmation.fileChanged {
        throw WallpaperActionError(
          message: L("The video changed since it was checked. Look for black bars again."))
      } catch is VideoLetterboxStore.Confirmation {
        throw InvalidControlValue()
      }
      // Confirming suspends while the file is found and read: judge the card again afterwards.
      let stage = try stagedLetterboxFactor(id: id, displayID: displayID)
      try await store.editScalingFactorAsync(
        wallpaperId: id, displayId: displayID, factor: stage.factor)
      letterboxStaged = LetterboxStagedFactor(
        wallpaperID: id, displayID: displayID, factor: stage.factor)
      AppLog.info(
        "Black bar check for \(id): staged scale factor \(stage.factor) on display \(displayID) for bars: \(stage.bars.summary)"
      )
    }
  }

  private struct LetterboxStage {
    let bars: LetterboxDetector.Bars
    let factor: Double
  }

  /// The factor a stage request may set right now, or the refusal when the card it came from no
  /// longer matches what is selected, checked and configured. Only Fill turns a factor into a
  /// crop; both video players apply it (`NativeVideoLayout`), so which one plays the clip does
  /// not matter.
  private func stagedLetterboxFactor(id: String, displayID: String) throws -> LetterboxStage {
    guard let context = letterboxContext(), context.wallpaperID == id,
      context.displayID == displayID, context.eligible, context.scalingMode == .fill,
      case .done(let report) = letterbox.phase(for: id, revision: store.libraryRefreshRevision),
      case .bars(let bars) = report.verdict,
      let viewport = letterbox.viewportProvider(displayID),
      case .factor(let factor) = LetterboxZoom.outcome(
        bars: bars, aspect: report.aspect, viewport: viewport),
      !Self.letterboxApplied(current: context.scalingFactor, suggested: factor)
    else { throw InvalidControlValue() }
    return LetterboxStage(bars: bars, factor: factor)
  }

  private func letterboxStage(_ context: LetterboxContext, suggested: Double?)
    -> LetterboxState.Stage
  {
    let applied =
      suggested.map { Self.letterboxApplied(current: context.scalingFactor, suggested: $0) }
      ?? false
    return LetterboxState.Stage(
      isAvailable: context.eligible && suggested != nil && !applied, isApplied: applied,
      isPending: applied && letterboxStaged.map { Self.letterboxHolds($0, context) } == true)
  }

  /// The staged factor is remembered only while it can still be the unsaved part of the draft: for
  /// the same wallpaper and display, at the same factor, with changes waiting. Once the draft is
  /// applied or reverted, the factor edited, or the selection or target display moved, a later
  /// unrelated edit must not bring the claim back.
  func forgetLetterboxStagedFactor(unlessHeldIn context: LetterboxContext?) {
    guard let staged = letterboxStaged else { return }
    if let context, Self.letterboxHolds(staged, context) { return }
    letterboxStaged = nil
  }

  private static func letterboxHolds(_ staged: LetterboxStagedFactor, _ context: LetterboxContext)
    -> Bool
  {
    guard staged.wallpaperID == context.wallpaperID, staged.displayID == context.displayID,
      context.draftPending, let current = context.scalingFactor
    else { return false }
    return abs(current - staged.factor) < 0.0005
  }

  /// The display already has a factor that hides the bars. The suggestion carries half a percent of
  /// overscan, so a hair under it still does, and a larger factor the user chose is kept.
  private static func letterboxApplied(current: Double?, suggested: Double) -> Bool {
    guard let current else { return false }
    return current >= suggested - 0.005
  }

  struct LetterboxContext {
    let wallpaperID: String
    let displayID: String
    let eligible: Bool
    let scalingMode: BridgeScalingMode?
    let scalingFactor: Double?
    /// The wallpaper has changes that Apply changes would save.
    let draftPending: Bool
  }

  /// The selected installed video on the target display, or nil for anything else.
  func letterboxContext() -> LetterboxContext? {
    guard let id = store.appSnapshot.selectedWallpaperId,
      let entry = store.librarySnapshot.wallpapers.first(where: { $0.id == id }),
      entry.kind == .video
    else { return nil }
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
}
