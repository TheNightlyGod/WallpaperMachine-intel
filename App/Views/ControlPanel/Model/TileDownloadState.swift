import Foundation

/// The ring a Discover or pixiv tile wears over its picture while the wallpaper is on its way:
/// live progress, one click to cancel, a shield when Steam needs the user, a retry mark after a
/// failure. Once the wallpaper is in the library the tile's corner mark carries it instead and no
/// ring is made.
///
/// The cases are those of Wallpaper Engine's own library, and the first matching rule wins:
/// a retained request, then a queued job, a job waiting for Steam, a running one, a paused one and
/// a failed or cancelled one. `action` says what a click does; the view applies it to the tile's
/// item id (Workshop) or to `jobID` (pixiv, whose job ids are library ids).
struct TileDownloadState: Equatable {
  enum Kind: Equatable {
    /// Waiting or paused, drawn dim.
    case queued
    /// Steam needs the user: a setup step, a sign-in or a Steam Guard answer.
    case attention
    /// A transfer with a measured fraction.
    case progress
    /// Under way with no fraction yet: a sweeping arc.
    case busy
    case failed
  }

  /// The mark in the ring's centre when it has no text.
  enum Glyph: Equatable {
    case play, shield, download, refresh
  }

  enum Action: Equatable {
    case resume, continueSetup, cancel, retry
  }

  let kind: Kind
  let glyph: Glyph?
  /// A click cancels, so hovering swaps the centre for a close mark.
  let showsCloseOnHover: Bool
  /// The fraction drawn, 0...1, for `.progress`.
  let progress: Double?
  /// The centre's text: a percentage, or the word for the step SteamCMD is on.
  let text: String
  /// `text` is a step word (Preparing, Finishing...), not a percentage.
  let isStepWord: Bool
  /// The transfer speed under the text; empty when there is none.
  let speed: String
  let phase: WorkshopDownloader.Phase?
  let action: Action
  /// The tooltip and the accessibility label.
  let label: String
  /// A retry waits for SteamCMD to be set up.
  let isEnabled: Bool

  // MARK: Workshop

  /// The ring of a Workshop tile, or nil when it wears none. `title` is the item's.
  @MainActor
  static func workshop(
    title: String, request: DownloadRequestRow?, job: DownloadRow?, setupIsReady: Bool,
    locale: Locale? = nil
  ) -> TileDownloadState? {
    let locale = locale ?? PanelLocale.shared.locale
    if let request {
      return request.isPaused
        ? TileDownloadState(
          kind: .queued, glyph: .play, action: .resume, label: L("Resume download"))
        : TileDownloadState(
          kind: .attention, glyph: .shield, action: .continueSetup,
          label: L("Continue setup to download \(title)"))
    }
    guard let job else { return nil }
    if job.isPending {
      if job.isQueued {
        return TileDownloadState(
          kind: .queued, glyph: .download, showsCloseOnHover: true, action: .cancel,
          label: L("\(title) is waiting to download. Click to remove it from the queue"))
      }
      if job.prompt != nil || job.challenge != nil {
        return TileDownloadState(
          kind: .attention, glyph: .shield, action: .continueSetup,
          label: L("Finish the Steam sign-in to download \(title)"))
      }
      return transferring(job, title: title, locale: locale)
    }
    if job.isPaused {
      return TileDownloadState(
        kind: .queued, glyph: .play, action: .resume, label: L("Resume download"))
    }
    if job.needsReview {
      let reason = job.hasError ? job.errorMessage ?? "" : L("Download cancelled.")
      return TileDownloadState(
        kind: .failed, glyph: .refresh, action: .retry, label: L("\(reason) Click to try again"),
        isEnabled: setupIsReady)
    }
    return nil
  }

  /// A running job: its percentage and speed, or the step it is on while no byte has moved.
  ///
  /// Bytes only move once Steam has been contacted, signed in and asked for the item. Until then
  /// the ring sweeps and its word names that step, so the wait never reads as a stall; a transfer
  /// that is measuring but has no percentage yet shows its speed instead. After the last byte,
  /// "Finishing" replaces a frozen 100% while the files are validated and imported.
  @MainActor
  private static func transferring(_ job: DownloadRow, title: String, locale: Locale)
    -> TileDownloadState
  {
    let progress = job.clampedProgress
    let percent = progress.map { Int(($0 * 100).rounded()) }
    let pace = TransferFormat.speed(job.bytesPerSecond, locale: locale)
    let phaseWord = job.phase.map(Self.stepWord) ?? ""
    let progressText =
      percent.map { L("Downloading \($0)%") }
      ?? (job.status.isEmpty ? L("Downloading") : job.status)
    let finishing = job.phase == .finishing && percent == 100
    let word =
      finishing ? phaseWord : percent == nil && (job.phase != .transferring || pace.isEmpty) ? phaseWord : ""
    let described = pace.isEmpty ? progressText : L("\(progressText) at \(pace)")
    return TileDownloadState(
      kind: percent == nil ? .busy : .progress, progress: progress,
      text: word.isEmpty ? (percent.map { "\($0)%" } ?? "") : word, isStepWord: !word.isEmpty,
      speed: pace, phase: job.phase, showsCloseOnHover: true, action: .cancel,
      label: L("\(described): \(title). Click to cancel"))
  }

  /// One short word per SteamCMD step, sized to sit inside the ring; the full sentence stays in
  /// the tooltip, the inspector and the Downloads list.
  @MainActor
  static func stepWord(_ phase: WorkshopDownloader.Phase) -> String {
    switch phase {
    case .preparing: L("Preparing")
    case .connecting: L("Connecting")
    case .updating: L("Updating")
    case .signingIn: L("Signing in")
    case .requesting: L("Requesting")
    case .transferring: L("Downloading")
    case .finishing: L("Finishing")
    }
  }

  // MARK: pixiv

  /// The ring of a pixiv tile, or nil when it wears none. `jobs` are the downloads of the work's
  /// pages and `savedPages` the pages already in the library.
  ///
  /// A pending job comes first; otherwise the first failed, cancelled or paused one whose page is
  /// not saved, so a retry mark never outlives the page it was for. The job's id is the library id
  /// the action names.
  @MainActor
  static func pixiv(title: String, jobs: [PixivDownloadRow], savedPages: [Int])
    -> (state: TileDownloadState, jobID: String)?
  {
    let job =
      jobs.first { $0.isPending }
      ?? jobs.first {
        switch $0.status {
        case .failed, .cancelled, .paused: !savedPages.contains($0.pageIndex)
        case .waiting, .downloading, .installing, .finished: false
        }
      }
    guard let job else { return nil }
    let state: TileDownloadState
    switch job.status {
    case .paused:
      state = TileDownloadState(
        kind: .queued, glyph: .play, action: .resume, label: L("Resume download"))
    case .waiting:
      state = TileDownloadState(
        kind: .queued, glyph: .download, showsCloseOnHover: true, action: .cancel,
        label: L("\(title) is waiting to download. Click to remove it from the queue"))
    case .installing:
      let saving = L("Saving to your library…")
      state = TileDownloadState(
        kind: .busy, text: L("Finishing"), isStepWord: true, showsCloseOnHover: true,
        action: .cancel, label: L("\(saving): \(title). Click to cancel"))
    case .downloading:
      let percent = job.percent
      let described = percent.map { L("Downloading \($0)%") } ?? L("Downloading")
      state = TileDownloadState(
        kind: percent == nil ? .busy : .progress, progress: percent.map { Double($0) / 100 },
        text: percent.map { "\($0)%" } ?? "", showsCloseOnHover: true, action: .cancel,
        label: L("\(described): \(title). Click to cancel"))
    case .failed, .cancelled, .finished:
      let reason = job.errorMessage ?? L("Download cancelled.")
      state = TileDownloadState(
        kind: .failed, glyph: .refresh, action: .retry, label: L("\(reason) Click to try again"))
    }
    return (state, job.id)
  }

  private init(
    kind: Kind, glyph: Glyph? = nil, progress: Double? = nil, text: String = "",
    isStepWord: Bool = false, speed: String = "", phase: WorkshopDownloader.Phase? = nil,
    showsCloseOnHover: Bool = false, action: Action, label: String, isEnabled: Bool = true
  ) {
    self.kind = kind
    self.glyph = glyph
    self.showsCloseOnHover = showsCloseOnHover
    self.progress = progress
    self.text = text
    self.isStepWord = isStepWord
    self.speed = speed
    self.phase = phase
    self.action = action
    self.label = label
    self.isEnabled = isEnabled
  }
}
