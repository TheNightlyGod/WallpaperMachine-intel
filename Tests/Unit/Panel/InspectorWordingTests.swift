import XCTest

@testable import WallpaperMachine

/// The inspector's sentences: the energy line and its conditions, the audio and media status, the
/// Compatibility summary, the Black bars findings and the values of sliders. None of these had a
/// page-level test; each is pinned here with the rule it follows.
@MainActor
final class InspectorWordingTests: InspectorTestCase {
  private let english = Locale(identifier: "en_US")

  // MARK: Header

  func testTheMetaLineIsTheTypeAndTheSizeOnceMeasured() {
    XCTAssertEqual(InspectorWording.meta(for: row(kind: .video, size: 1_258_291), locale: english), "Video · 1.2 MB")
    XCTAssertEqual(InspectorWording.meta(for: row(kind: .scene), locale: english), "Scene", "unmeasured: no size")
    XCTAssertEqual(InspectorWording.meta(for: row(kind: .web, size: 0), locale: english), "Web")
    XCTAssertEqual(InspectorWording.meta(for: row(kind: .unknown, size: 512), locale: english), "Unknown · 512 B")
  }

  private func rating(
    level: EnergyLevel = .medium, milliwatts: Double = 1_200, displays: Int = 1, cap: Int? = 60,
    scale: Double = 0.75, battery: Double? = nil
  ) -> LibraryEnergyRating {
    var snapshot: [String: Any] = [
      "level": level.rawValue, "milliwatts": milliwatts, "displays": displays, "renderScale": scale,
    ]
    if let cap { snapshot["frameRateCap"] = cap }
    if let battery { snapshot["batteryPercentPerHour"] = battery }
    return LibraryEnergyRating(snapshot: snapshot)!
  }

  func testTheEnergyLineNamesTheGradeThePowerAndTheConditionsItWasMeasuredUnder() {
    XCTAssertEqual(
      InspectorWording.energyLine(rating(), locale: english),
      "Medium energy use, about 1.2 W. Measured while it played alone on 1 display at 60 fps, 75% render scale, with this window closed."
    )
    XCTAssertEqual(
      InspectorWording.energyLine(
        rating(level: .low, milliwatts: 340, displays: 2, cap: nil, scale: 1), locale: english),
      "Low energy use, about 340 mW. Measured while it played alone on 2 displays at each display’s own frame rate, 100% render scale, with this window closed."
    )
  }

  func testTheBatterySentenceIsInsertedOnlyForAMacWithABattery() {
    XCTAssertEqual(
      InspectorWording.energyLine(rating(battery: 3.4), locale: english),
      "Medium energy use, about 1.2 W. About 3% of a full battery charge per hour. Measured while it played alone on 1 display at 60 fps, 75% render scale, with this window closed."
    )
    XCTAssertTrue(
      InspectorWording.energyLine(rating(battery: 0.4), locale: english)
        .contains("Less than 1% of a full battery charge per hour."))
    XCTAssertFalse(
      InspectorWording.energyLine(rating(), locale: english).contains("battery"),
      "a desktop Mac has no battery sentence")
  }

  // MARK: Audio and media

  private func options(
    kind: BridgeWallpaperKind = .webpage, audio: Bool = true, media: Bool = true,
    delivery: InspectorOptions.DeliveryReport = .unobserved
  ) -> InspectorOptions {
    InspectorOptions(
      wallpaperID: "wp", kind: kind, isSupported: true, isDirty: false, hasUnsentChanges: false,
      isLocked: false, volume: 1, isMuted: false, audioResponseEnabled: audio,
      mediaIntegrationEnabled: media, hiddenModified: false, delivery: delivery, displays: [],
      properties: [])
  }

  func testTheAudioStatusFollowsTheSettingThenTheKindThenWhatTheHostObserved() {
    XCTAssertEqual(InspectorWording.audioStatus(options(audio: false)), "Off. No audio is captured.")
    XCTAssertEqual(
      InspectorWording.audioStatus(options(kind: .projectScene)),
      "On. Parts of the wallpaper made to react to sound will respond.")
    XCTAssertEqual(
      InspectorWording.audioStatus(options(kind: .video)),
      "On. Parts of the wallpaper made to react to sound will respond.")
    func web(_ audio: InspectorOptions.DeliveryReport.Audio) -> String {
      InspectorWording.audioStatus(
        options(delivery: .init(audio: audio, media: .unknown, webOutput: nil)))
    }
    XCTAssertEqual(web(.delivering), "On. The wallpaper is receiving audio.")
    XCTAssertEqual(web(.subscribed), "On. Waiting for an audio frame.")
    XCTAssertEqual(web(.connecting), "On. Connecting to audio…")
    XCTAssertEqual(
      web(.failed), "Audio could not be connected. Turn Audio response off and on to retry.")
    XCTAssertEqual(web(.idle), "On, but this wallpaper doesn’t use audio.")
    XCTAssertEqual(
      web(.inactive), "On. Apply the wallpaper to see whether it uses audio.",
      "a host with nothing for this wallpaper says nothing was observed")
    XCTAssertEqual(
      web(.unknown), "On. Apply the wallpaper to see whether it uses audio.",
      "no host: nothing was observed either")
    XCTAssertEqual(
      InspectorWording.audioStatus(
        options(audio: false, delivery: .init(audio: .delivering, media: .unknown, webOutput: nil))),
      "Off. No audio is captured.", "the setting is never overwritten by what is delivered")
  }

  func testTheMediaStatusKeepsTheSettingTheAvailabilityAndTheReasonApart() {
    func status(
      media: Bool = true, _ report: InspectorOptions.DeliveryReport.Media
    ) -> String {
      InspectorWording.mediaStatus(
        options(media: media, delivery: .init(audio: .unknown, media: report, webOutput: nil)))
    }
    XCTAssertEqual(status(media: false, .available), "Off. The wallpaper gets no track information.")
    XCTAssertEqual(
      status(.available), "On. The wallpaper gets the track details macOS reports.")
    XCTAssertEqual(
      status(.unavailable(reason: "Spotify is not running.")),
      "On, but track information is unavailable: Spotify is not running.")
    XCTAssertEqual(
      status(.unavailable(reason: nil)),
      "On, but track information is unavailable: the system declined to report what is playing.")
    XCTAssertEqual(
      status(.unknown), "On. Apply the wallpaper to see whether track information is available.")
  }

  func testTheWebOutputSentencesNameWhatVolumeAndMuteReachAndWhatIsNotYetKnown() {
    typealias Output = InspectorOptions.DeliveryReport.WebOutput
    XCTAssertTrue(InspectorWording.webVolumeStatus(.mediaElements).hasPrefix("Volume sets the level"))
    XCTAssertTrue(InspectorWording.webVolumeStatus(.mediaElements).contains("only Mute does"))
    XCTAssertEqual(
      InspectorWording.webVolumeStatus(.unavailable),
      "Media volume cannot be changed for this page on this version of macOS.")
    XCTAssertEqual(
      InspectorWording.webVolumeStatus(.unknown),
      "How far Volume reaches is confirmed once the wallpaper is running.")
    XCTAssertEqual(
      InspectorWording.webMuteStatus(.available),
      "Mute silences the whole page, including sound made with Web Audio.")
    XCTAssertEqual(
      InspectorWording.webMuteStatus(.unavailable),
      "Whole-page mute is not available on this version of macOS, so this page cannot be muted reliably."
    )
    XCTAssertEqual(
      InspectorWording.webMuteStatus(.unknown),
      "Whether the whole page can be muted is confirmed once the wallpaper is running.")
  }

  // MARK: Sliders

  func testASliderShowsTheValueWithTheDecimalsItsStepAndPrecisionNeed() {
    func text(_ value: Double, step: Double?, precision: Int) -> String {
      InspectorWording.sliderValue(value, step: step, precision: precision, locale: english)
    }
    XCTAssertEqual(text(120, step: 10, precision: 0), "120")
    XCTAssertEqual(text(0.65, step: 0.05, precision: 2), "0.65")
    XCTAssertEqual(text(0.5, step: 0.05, precision: 0), "0.50", "the step needs two decimals")
    XCTAssertEqual(text(0.5, step: nil, precision: 1), "0.5")
    XCTAssertEqual(text(1_200, step: 1, precision: 0), "1200", "no grouping separators in a number field")
    XCTAssertEqual(text(.nan, step: nil, precision: 2), "")
    XCTAssertEqual(InspectorWording.percent(0.4, locale: english), "40%")
    XCTAssertEqual(InspectorWording.percent(1, locale: english), "100%")
    XCTAssertEqual(InspectorWording.zoom(1.5, locale: english), "1.50×")
    XCTAssertEqual(InspectorWording.zoom(3, locale: english), "3.00×")
    XCTAssertEqual(InspectorWording.factor(1.3400001, locale: english), "1.34")
    XCTAssertEqual(InspectorWording.factor(2, locale: english), "2")
    XCTAssertEqual(InspectorWording.factor(1.5, locale: english), "1.5")
  }

  // MARK: Compatibility

  private func compatibility(
    _ statuses: [WallpaperCompatibilityCheck.Status], checking: Bool = false, backend: String? = nil,
    reason: String? = nil, kind: WallpaperCompatibilityContext.Kind = .scene
  ) -> CompatibilityState {
    CompatibilityState(
      wallpaperID: "a", displayID: "primary", kind: kind, isChecking: checking,
      checks: statuses.enumerated().map {
        WallpaperCompatibilityCheck(id: "c\($0.offset)", status: $0.element, title: "t", detail: "d")
      }, backend: backend, fallbackReason: reason, canCheck: true)
  }

  func testTheSummaryCountsWhatIsWrongInOrderAndSaysWhenNothingIs() {
    XCTAssertNil(InspectorWording.compatibilitySummary(compatibility([])), "before the first check")
    XCTAssertEqual(
      InspectorWording.compatibilitySummary(compatibility([], checking: true)), "Checking…")
    XCTAssertEqual(
      InspectorWording.compatibilitySummary(compatibility([.ok, .ok])), "No problems found")
    XCTAssertEqual(
      InspectorWording.compatibilitySummary(compatibility([.unavailable, .warning, .unknown])),
      "1 unavailable · 1 warning · 1 unknown")
    XCTAssertEqual(
      InspectorWording.compatibilitySummary(
        compatibility([.warning, .warning, .unknown, .unknown, .unknown, .ok])),
      "2 warnings · 3 unknown")
    XCTAssertEqual(
      InspectorWording.compatibilitySummary(
        compatibility([.unavailable, .unavailable], checking: true)), "Checking…",
      "a check in progress replaces the counts")
  }

  func testTheBackendLineNamesTheBackendAndWhyItFellBack() {
    XCTAssertEqual(
      InspectorWording.backendLine(compatibility([], backend: "native")), "Drawn now by native")
    XCTAssertEqual(
      InspectorWording.backendLine(compatibility([], backend: "legacy", reason: "lit particles")),
      "Drawn now by legacy (fallback: lit particles)")
    XCTAssertNil(
      InspectorWording.backendLine(compatibility([])),
      "the absence of a report is never read as a backend")
  }

  /// A scene held by Native Metal only has no backend drawing it, so the card says so, with the stage in
  /// words and the renderer's reason, instead of naming "unknown" as if it were a renderer.
  func testTheBackendLineOfAHeldSceneSaysItIsNotDrawnAndWhy() {
    var state = compatibility([], backend: "unknown")
    state.failure = SceneFailureReport(stage: .compile, reason: "the shader did not link")
    XCTAssertEqual(
      InspectorWording.backendLine(state),
      "Not drawn — its shaders didn't compile for Metal (reason: the shader did not link). Showing its last picture.")
    state.failure = SceneFailureReport(stage: .unsupported, reason: nil)
    XCTAssertEqual(
      InspectorWording.backendLine(state),
      "Not drawn — it uses something Native Metal can't draw. Showing its last picture.")
  }

  /// Port of `ControlPanelLibraryTests.testCompatibilityCardOffersReinstallOnlyWhenTheInstalledFilesAreWhatIsUnavailable`:
  /// only the installed files are what a fresh copy repairs, for a wallpaper whose type is known.
  func testReinstallIsOfferedOnlyForUnavailableInstalledFiles() {
    func state(_ checks: [(String, WallpaperCompatibilityCheck.Status)], kind: WallpaperCompatibilityContext.Kind = .scene)
      -> CompatibilityState
    {
      CompatibilityState(
        wallpaperID: "a", displayID: "primary", kind: kind, isChecking: false,
        checks: checks.map { WallpaperCompatibilityCheck(id: $0.0, status: $0.1, title: "t", detail: "d") },
        backend: nil, fallbackReason: nil, canCheck: true)
    }
    XCTAssertTrue(state([("project", .unavailable)]).installedFilesAreUnavailable)
    XCTAssertTrue(state([("entry", .unavailable)]).installedFilesAreUnavailable)
    for other in ["lockScreen", "target", "nativeVideo", "sharedResources", "sceneCapability"] {
      XCTAssertFalse(
        state([(other, .unavailable)]).installedFilesAreUnavailable,
        "\(other) is unavailable for a reason a reinstall leaves as it is")
    }
    XCTAssertFalse(state([("project", .warning)]).installedFilesAreUnavailable)
    XCTAssertFalse(state([("project", .unavailable)], kind: .unknown).installedFilesAreUnavailable)
  }

  // MARK: Black bars

  private func letterbox(
    _ outcome: LetterboxState.Outcome, mode: BridgeScalingMode? = .fill, factor: Double? = 1
  ) -> LetterboxState {
    LetterboxState(
      wallpaperID: "a", displayID: "primary", isEligible: true, scalingMode: mode,
      scalingFactor: factor, outcome: outcome)
  }

  func testAFindingNamesTheSidesAndTheWidestBarInPercent() {
    typealias Bars = LetterboxDetector.Bars
    XCTAssertEqual(
      InspectorWording.letterboxFinding(
        LetterboxState.layout(of: Bars(top: 0.1, bottom: 0.12, left: 0.05, right: 0.04))),
      "Black bars found on all four sides, up to 12% of the picture.")
    XCTAssertEqual(
      InspectorWording.letterboxFinding(
        LetterboxState.layout(of: Bars(top: 0, bottom: 0, left: 0.125, right: 0.125))),
      "Black bars found at the left and right, about 13% of the picture on each side.")
    XCTAssertEqual(
      InspectorWording.letterboxFinding(
        LetterboxState.layout(of: Bars(top: 0.1, bottom: 0.1, left: 0, right: 0))),
      "Black bars found at the top and bottom, about 10% of the picture on each side.")
    XCTAssertEqual(
      InspectorWording.letterboxFinding(
        LetterboxState.layout(of: Bars(top: 0.001, bottom: 0.001, left: 0, right: 0))),
      "Black bars found at the top and bottom, about 1% of the picture on each side.",
      "never less than 1%")
  }

  func testWhatFillWouldDoDependsOnTheModeAndTheSuggestion() {
    let bars = LetterboxDetector.Bars(top: 0, bottom: 0, left: 0.125, right: 0.125)
    func detail(_ suggestion: LetterboxState.Suggestion?, mode: BridgeScalingMode?) -> String? {
      InspectorWording.letterboxResult(
        letterbox(
          .bars(bars, suggestion: suggestion, stage: .init(isAvailable: true, isApplied: false, isPending: false)),
          mode: mode)
      )?.detail
    }
    XCTAssertEqual(
      detail(.factor(1.34), mode: .fill), "With Fill on this display, a scale factor of ×1.34 hides them.")
    XCTAssertEqual(detail(.alreadyHidden, mode: .fill), "Fill on this display already crops them out.")
    XCTAssertEqual(
      detail(.implausible, mode: .fill), "The bars look too large to be reliable, so nothing is suggested.")
    XCTAssertEqual(
      detail(nil, mode: .match),
      "This display uses Fit scaling. Black bars can be hidden with Fill and a scale factor.")
    XCTAssertEqual(
      detail(nil, mode: BridgeScalingMode.none),
      "This display uses Original size scaling. Black bars can be hidden with Fill and a scale factor.")
    XCTAssertNil(detail(nil, mode: nil), "a display that cannot be found has nothing to say")
    XCTAssertNil(detail(nil, mode: .fill))
  }

  /// Port of `ControlPanelLetterboxTests.testCardShowsTheMeasuredBars...` (the card's words and
  /// glyphs for every finished outcome).
  func testEveryFinishedOutcomeHasItsWordsAndItsGlyph() {
    func result(_ outcome: LetterboxState.Outcome) -> InspectorWording.LetterboxResult? {
      InspectorWording.letterboxResult(letterbox(outcome))
    }
    XCTAssertNil(result(.idle))
    XCTAssertNil(result(.checking))
    XCTAssertEqual(result(.none)?.glyph, .ok)
    XCTAssertEqual(result(.none)?.headline, "No black bars found.")
    XCTAssertEqual(
      result(.uneven(.init(top: 0.1, bottom: 0, left: 0, right: 0)))?.headline,
      "The bars are uneven, so a scale factor could not hide them without cutting into the picture.")
    XCTAssertEqual(result(.uneven(.zero))?.glyph, .info)
    let unclear: [(LetterboxState.Unclear, String)] = [
      (.dark, "The sampled frames are too dark to tell."),
      (.disagree, "The sampled frames do not agree on where the bars are."),
      (.fewFrames, "Too few different frames could be sampled to tell."),
      (.implausible, "The bars look too large to be reliable, so nothing is suggested."),
    ]
    for (reason, words) in unclear {
      XCTAssertEqual(result(.unclear(reason))?.headline, words)
      XCTAssertEqual(result(.unclear(reason))?.glyph, .unclear)
    }
    let failures: [(LetterboxState.Failure, String)] = [
      (.timedOut, "Reading the video took too long."),
      (.changed, "The video changed while it was being checked. Look again."),
      (.unreadable, "This video cannot be read here, so it cannot be checked."),
      (.noVideo, "This video cannot be read here, so it cannot be checked."),
    ]
    for (failure, words) in failures {
      XCTAssertEqual(result(.failed(failure))?.headline, words)
      XCTAssertEqual(result(.failed(failure))?.glyph, .failed)
    }
  }

  func testTheStagingButtonAndItsNoteFollowTheStageOfTheFactor() {
    let bars = LetterboxDetector.Bars(top: 0, bottom: 0, left: 0.125, right: 0.125)
    func state(_ stage: LetterboxState.Stage, factor: Double? = 1.34) -> LetterboxState {
      letterbox(.bars(bars, suggestion: .factor(1.34), stage: stage), factor: factor)
    }
    let available = LetterboxState.Stage(isAvailable: true, isApplied: false, isPending: false)
    XCTAssertEqual(InspectorWording.stageableFactor(state(available)), 1.34)
    XCTAssertEqual(InspectorWording.letterboxStageNote(state(available)), .explains)

    let pending = LetterboxState.Stage(isAvailable: false, isApplied: true, isPending: true)
    XCTAssertNil(InspectorWording.stageableFactor(state(pending)), "already set: no button")
    XCTAssertEqual(
      InspectorWording.letterboxStageNote(state(pending)), .pending(factor: 1.34),
      "the factor this card set and that still waits for Apply changes")

    let saved = LetterboxState.Stage(isAvailable: false, isApplied: true, isPending: false)
    XCTAssertNil(InspectorWording.stageableFactor(state(saved)))
    XCTAssertEqual(
      InspectorWording.letterboxStageNote(state(saved)), .none,
      "a factor that was already saved stays quiet however many other edits the draft holds")

    XCTAssertNil(InspectorWording.stageableFactor(letterbox(.none)))
    XCTAssertEqual(InspectorWording.letterboxStageNote(letterbox(.none)), .none)
    XCTAssertEqual(
      InspectorWording.letterboxStageNote(
        letterbox(.bars(bars, suggestion: .alreadyHidden, stage: available))), .none)
  }
}
