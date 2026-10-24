import Foundation

/// The inspector's sentences, worked out from typed state. Every literal is a catalog key written
/// the way `strings-map.tsv` says; the sentences that carry a wallpaper's, a display's or a file's
/// own words take them as arguments and are shown with `Text(verbatim:)`.
@MainActor
enum InspectorWording {
  // MARK: Header

  /// "Video · 124 MB": the wallpaper's type, then its size once measured. The inspector never had
  /// an author for an installed wallpaper, so none is shown.
  static func meta(for row: LibraryRow, locale: Locale? = nil) -> String {
    var parts = [PanelLocale.shared.catalogString(row.kind.rawValue)]
    if let size = row.size, size > 0 {
      let text = TransferFormat.bytes(Double(size), locale: locale ?? PanelLocale.shared.locale)
      if !text.isEmpty { parts.append(text) }
    }
    return parts.joined(separator: " · ")
  }

  /// The background recorder's rating with the conditions it was measured under: a rating taken on
  /// two displays with no limit says little about one display at 30 fps. The battery sentence is
  /// there only on a Mac with a battery.
  static func energyLine(_ rating: LibraryEnergyRating, locale: Locale? = nil) -> String {
    let locale = locale ?? PanelLocale.shared.locale
    let level = EnergyReadout.title(for: rating.level)
    let power = EnergyReadout.milliwatts(rating.milliwatts, locale: locale)
    let displays = rating.displays == 1 ? L("1 display") : L("\(rating.displays) displays")
    let rate =
      rating.frameRateCap.map { L("\($0) fps") } ?? L("each display’s own frame rate")
    let scale = "\(Int((rating.renderScale * 100).rounded()))%"
    if let share = rating.batteryPercentPerHour.flatMap(EnergyReadout.batteryShareNote(percentPerHour:)) {
      return L(
        "\(level), about \(power). \(share) Measured while it played alone on \(displays) at \(rate), \(scale) render scale, with this window closed."
      )
    }
    return L(
      "\(level), about \(power). Measured while it played alone on \(displays) at \(rate), \(scale) render scale, with this window closed."
    )
  }

  // MARK: Host status

  /// What the host reports for one display: "Studio Display · Wallpaper could not load". The display's
  /// name is the system's, the phrase the app's.
  static func hostStatus(_ row: HostStateRow) -> String {
    let words: String
    switch row.phase {
    case .failed: words = L("Wallpaper could not load")
    case .ready: words = L("Wallpaper content is ready")
    default: words = L("Loading wallpaper content…")
    }
    return "\(row.displayTitle) · \(words)"
  }

  // MARK: Audio and media

  /// What the Audio response switch amounts to. Three facts stay apart: what the user switched on,
  /// whether anything is delivered, and whether the panel can tell at all.
  static func audioStatus(_ options: InspectorOptions) -> String {
    guard options.audioResponseEnabled else { return L("Off. No audio is captured.") }
    guard options.kind == .webpage else {
      return L("On. Parts of the wallpaper made to react to sound will respond.")
    }
    switch options.delivery.audio {
    case .delivering: return L("On. The wallpaper is receiving audio.")
    case .subscribed: return L("On. Waiting for an audio frame.")
    case .connecting: return L("On. Connecting to audio…")
    case .failed: return L("Audio could not be connected. Turn Audio response off and on to retry.")
    case .idle: return L("On, but this wallpaper doesn’t use audio.")
    case .unknown, .inactive: return L("On. Apply the wallpaper to see whether it uses audio.")
    }
  }

  static func mediaStatus(_ options: InspectorOptions) -> String {
    guard options.mediaIntegrationEnabled else {
      return L("Off. The wallpaper gets no track information.")
    }
    switch options.delivery.media {
    case .available: return L("On. The wallpaper gets the track details macOS reports.")
    case .unavailable(let reason):
      let words = reason ?? L("the system declined to report what is playing.")
      return L("On, but track information is unavailable: \(words)")
    case .unknown: return L("On. Apply the wallpaper to see whether track information is available.")
    }
  }

  static func webVolumeStatus(_ volume: InspectorOptions.DeliveryReport.WebOutput.Volume) -> String {
    switch volume {
    case .mediaElements:
      return L(
        "Volume sets the level of the audio and video the page plays through media elements. Sound the page makes with Web Audio does not follow it; only Mute does."
      )
    case .unavailable: return L("Media volume cannot be changed for this page on this version of macOS.")
    case .unknown: return L("How far Volume reaches is confirmed once the wallpaper is running.")
    }
  }

  static func webMuteStatus(_ mute: InspectorOptions.DeliveryReport.WebOutput.Mute) -> String {
    switch mute {
    case .available: return L("Mute silences the whole page, including sound made with Web Audio.")
    case .unavailable:
      return L("Whole-page mute is not available on this version of macOS, so this page cannot be muted reliably.")
    case .unknown: return L("Whether the whole page can be muted is confirmed once the wallpaper is running.")
    }
  }

  // MARK: Slider values

  /// A property slider's value in the words of its own step and precision: as many decimals as the
  /// author meant, and at least as many as the step needs.
  static func sliderValue(_ value: Double, step: Double?, precision: Int, locale: Locale? = nil)
    -> String
  {
    let locale = locale ?? PanelLocale.shared.locale
    guard value.isFinite else { return "" }
    var digits = max(0, min(precision, 6))
    if let step, step > 0, step < 1 {
      var needed = 0
      var scaled = step
      while needed < 6, abs(scaled - scaled.rounded()) > 1e-9 {
        scaled *= 10
        needed += 1
      }
      digits = max(digits, needed)
    }
    return value.formatted(
      .number.precision(.fractionLength(digits)).grouping(.never).locale(locale))
  }

  /// "40%" for a fraction or percentage slider.
  static func percent(_ fraction: Double, locale: Locale? = nil) -> String {
    let locale = locale ?? PanelLocale.shared.locale
    return (fraction * 100).rounded().formatted(
      .number.precision(.fractionLength(0)).grouping(.never).locale(locale)) + "%"
  }

  /// "1.50×": the placement zoom, two decimals.
  static func zoom(_ value: Double, locale: Locale? = nil) -> String {
    let locale = locale ?? PanelLocale.shared.locale
    return value.formatted(.number.precision(.fractionLength(2)).grouping(.never).locale(locale))
      + "×"
  }

  /// A scale factor as the Black bars card words it: two decimals at most, none that are zero.
  static func factor(_ value: Double, locale: Locale? = nil) -> String {
    let locale = locale ?? PanelLocale.shared.locale
    return value.formatted(
      .number.precision(.fractionLength(0...2)).grouping(.never).locale(locale))
  }

  // MARK: Compatibility

  /// The status line beside the card's title: counts in the order unavailable, warning, unknown;
  /// "No problems found" after a clean check; nothing before the first one.
  static func compatibilitySummary(_ state: CompatibilityState) -> String? {
    if state.isChecking { return L("Checking…") }
    var parts: [String] = []
    let unavailable = state.unavailableCount
    let warnings = state.warningCount
    let unknown = state.unknownCount
    if unavailable > 0 { parts.append(unavailable == 1 ? L("1 unavailable") : L("\(unavailable) unavailable")) }
    if warnings > 0 { parts.append(warnings == 1 ? L("1 warning") : L("\(warnings) warnings")) }
    if unknown > 0 { parts.append(unknown == 1 ? L("1 unknown") : L("\(unknown) unknown")) }
    if !parts.isEmpty { return parts.joined(separator: " · ") }
    return state.checks.isEmpty ? nil : L("No problems found")
  }

  /// The word a screen reader reads for a check's glyph.
  static func statusWord(_ status: WallpaperCompatibilityCheck.Status) -> String {
    switch status {
    case .ok: L("OK")
    case .warning: L("Warning")
    case .unavailable: L("Unavailable")
    case .unknown: L("Unknown")
    }
  }

  /// "Drawn now by metal", with its fallback reason when it has one, or the held-scene sentence when
  /// Native Metal is the only renderer and could not draw it: nothing draws it, so no backend is named.
  static func backendLine(_ state: CompatibilityState) -> String? {
    if let failure = state.failure {
      let sentence = failure.stage.sentence(reason: failure.reason)
      return sentence.prefix(1).uppercased() + sentence.dropFirst()
    }
    guard let backend = state.backend else { return nil }
    if let reason = state.fallbackReason, !reason.isEmpty {
      return L("Drawn now by \(backend) (fallback: \(reason))")
    }
    return L("Drawn now by \(backend)")
  }

  // MARK: Black bars

  enum LetterboxGlyph: Equatable { case ok, info, unclear, failed }

  /// The finished result of a Black bars check in words: its glyph, a headline and a detail.
  struct LetterboxResult: Equatable {
    let glyph: LetterboxGlyph
    let headline: String
    let detail: String?
  }

  /// The result card for a finished check, or nil while idle or checking.
  static func letterboxResult(_ state: LetterboxState) -> LetterboxResult? {
    switch state.outcome {
    case .idle, .checking:
      return nil
    case .none:
      return LetterboxResult(glyph: .ok, headline: L("No black bars found."), detail: nil)
    case .bars(let bars, let suggestion, _):
      return LetterboxResult(
        glyph: .info, headline: letterboxFinding(LetterboxState.layout(of: bars)),
        detail: letterboxAdvice(suggestion, mode: state.scalingMode))
    case .uneven:
      return LetterboxResult(
        glyph: .info,
        headline: L(
          "The bars are uneven, so a scale factor could not hide them without cutting into the picture."
        ), detail: nil)
    case .unclear(let reason):
      let words: String
      switch reason {
      case .dark: words = L("The sampled frames are too dark to tell.")
      case .disagree: words = L("The sampled frames do not agree on where the bars are.")
      case .fewFrames: words = L("Too few different frames could be sampled to tell.")
      case .implausible: words = L("The bars look too large to be reliable, so nothing is suggested.")
      }
      return LetterboxResult(glyph: .unclear, headline: words, detail: nil)
    case .failed(let failure):
      let words: String
      switch failure {
      case .timedOut: words = L("Reading the video took too long.")
      case .changed: words = L("The video changed while it was being checked. Look again.")
      case .unreadable, .noVideo: words = L("This video cannot be read here, so it cannot be checked.")
      }
      return LetterboxResult(glyph: .failed, headline: words, detail: nil)
    }
  }

  static func letterboxFinding(_ layout: LetterboxState.Layout) -> String {
    switch layout {
    case .allFourSides(let percent):
      L("Black bars found on all four sides, up to \(percent)% of the picture.")
    case .leftAndRight(let percent):
      L("Black bars found at the left and right, about \(percent)% of the picture on each side.")
    case .topAndBottom(let percent):
      L("Black bars found at the top and bottom, about \(percent)% of the picture on each side.")
    }
  }

  /// What Fill and a scale factor would do about found bars on this display; with no suggestion,
  /// which mode the display uses instead.
  static func letterboxAdvice(_ suggestion: LetterboxState.Suggestion?, mode: BridgeScalingMode?)
    -> String?
  {
    switch suggestion {
    case .factor(let factor)?:
      return L("With Fill on this display, a scale factor of ×\(Self.factor(factor)) hides them.")
    case .alreadyHidden?: return L("Fill on this display already crops them out.")
    case .implausible?: return L("The bars look too large to be reliable, so nothing is suggested.")
    case nil:
      guard let mode, mode != .fill else { return nil }
      return L(
        "This display uses \(scalingModeName(mode)) scaling. Black bars can be hidden with Fill and a scale factor."
      )
    }
  }

  static func scalingModeName(_ mode: BridgeScalingMode) -> String {
    switch mode {
    case .none: L("Original size")
    case .stretch: L("Stretch")
    case .match: L("Fit")
    case .fill: L("Fill")
    case .matchBlurred: L("Fit with blurred backdrop")
    }
  }

  /// The factor the Black bars card may stage, when there is one to set.
  static func stageableFactor(_ state: LetterboxState) -> Double? {
    guard case .bars(_, .factor(let factor)?, let stage) = state.outcome, !stage.isApplied
    else { return nil }
    return factor
  }

  /// The note under the staging button: that the factor is in the draft, or what the button does.
  enum LetterboxStageNote: Equatable {
    case none
    /// The display's factor is the one this card set and it waits for Apply changes.
    case pending(factor: Double)
    case explains
  }

  static func letterboxStageNote(_ state: LetterboxState) -> LetterboxStageNote {
    guard case .bars(_, .factor?, let stage) = state.outcome else { return .none }
    if stage.isApplied {
      guard stage.isPending, let factor = state.scalingFactor else { return .none }
      return .pending(factor: factor)
    }
    return .explains
  }
}

/// The SF Symbols the inspector draws for a state, so each mapping is one place and every name is
/// held to the symbol set by a test.
enum InspectorGlyphs {
  /// The glyph of a compatibility check's status.
  static func compatibility(_ status: WallpaperCompatibilityCheck.Status) -> String {
    switch status {
    case .ok: "checkmark.circle.fill"
    case .warning: "exclamationmark.triangle.fill"
    case .unavailable: "xmark.circle.fill"
    case .unknown: "questionmark.circle.fill"
    }
  }

  /// The glyph of a finished Black bars check.
  static func letterbox(_ glyph: InspectorWording.LetterboxGlyph) -> String {
    switch glyph {
    case .ok: "checkmark.circle.fill"
    case .info: "info.circle.fill"
    case .unclear: "questionmark.circle.fill"
    case .failed: "exclamationmark.triangle.fill"
    }
  }
}
