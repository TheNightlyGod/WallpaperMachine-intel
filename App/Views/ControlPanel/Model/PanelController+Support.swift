import Foundation

/// What the user chooses in one of the one-time prompts.
enum SupportPromptChoice: Sendable {
  /// Not now: the prompt is spent and nothing opens.
  case dismiss
  /// Star the repository on GitHub (the support and star prompts).
  case star
  /// The supporter pricing page, in Chinese for a Chinese interface (the support prompt).
  case supporter
  /// Turn on **Send performance data** (the performance data question).
  case enableTelemetry
  /// **Import my subscriptions** (the subscriptions offer).
  case importSubscriptions
  /// **Join Discord**: MMFoundation's Discord invite (the Discord invitation).
  case joinDiscord
  /// **Pause while I use other apps**: "When another app is in front" becomes Pause on battery
  /// (the battery question).
  case pauseWhileUsingOtherApps
  /// **Lower quality on battery**: On battery becomes Reduced quality (the battery question).
  case reduceQualityOnBattery
  /// **Always pause on battery**: On battery becomes Pause (the battery question). Named apart from
  /// the app-in-front choice **Pause on battery**, which the first row sets.
  case alwaysPauseOnBattery
}

/// What the battery question says about the Mac and its settings, read when the sheet is drawn.
struct BatteryQuestionFacts: Equatable {
  /// The share of a full charge the wallpaper playing now uses per hour, from its energy rating;
  /// nil without one, or when the displays play different wallpapers.
  var percentPerHour: Double?
  /// The reduced-quality profile every Reduced quality choice shares.
  var reducedFrameRate: Int
  var reducedRenderScale: Float

  /// "The wallpaper playing now uses about 9% of a full battery charge per hour.", worded as the
  /// energy readout words a share under 1%; nil without a figure.
  @MainActor var energyLine: String? {
    guard let percent = percentPerHour, percent.isFinite, percent >= 0 else { return nil }
    if percent < 1 {
      return L("The wallpaper playing now uses less than 1% of a full battery charge per hour.")
    }
    return L(
      "The wallpaper playing now uses about \(Int(percent.rounded()))% of a full battery charge per hour.")
  }

  /// The question's lead: nothing changes until a choice is made, and the energy line when there is one.
  @MainActor var lead: String {
    let lead = L(
      "Wallpapers now play on battery just as they do plugged in. Nothing changes unless you choose.")
    return energyLine.map { lead + " " + $0 } ?? lead
  }

  /// "Plays at 30 fps and 75% render scale.": the reduced profile, under Lower quality on battery.
  @MainActor var reducedQualityNote: String {
    let scale = Int((Double(reducedRenderScale) * 100).rounded())
    return L("Plays at \(reducedFrameRate) fps and \(scale)% render scale.")
  }
}

/// The one-time prompts: when one is pending, which, and what its buttons do.
///
/// Whether a prompt may appear, and which, is the store's (`SupportPromptStore`: the performance
/// data question, the battery question, the offer to import the Steam subscriptions, the support
/// offer after a downloaded wallpaper is applied, the later star request, the still later Discord
/// invitation, one a day).
/// Whether it is on screen is the panel's: a hidden or minimised panel must not report
/// one, because showing it spends it.
extension PanelController {
  /// The prompt the store names now, whether or not anyone can see the panel. Without a telemetry
  /// service there is nothing to offer, so the performance data question never comes up.
  var duePrompt: SupportPromptStore.Prompt? {
    store.supportPrompt?.pendingPrompt(
      welcomeSeen: welcomeSeen, telemetryOn: store.telemetry?.isEnabled ?? true,
      steamSignedIn: workshop.downloader.savedAccount != nil, battery: batteryPromptFacts)
  }

  /// What the battery question depends on: the battery the panel last read, the engine's power
  /// source and battery choice, whether a wallpaper plays, and "When another app is in front".
  var batteryPromptFacts: SupportPromptStore.BatteryFacts {
    _ = revisions.playback
    let settings = store.settingsSnapshot
    return SupportPromptStore.BatteryFacts(
      hasBattery: batteryPercent != nil, onBattery: settings.onBatteryPower,
      wallpaperPlaying: !store.appSnapshot.activeWallpaperIds.isEmpty && !isPlaybackPaused,
      batteryMode: settings.batteryMode, otherAppInFront: playback.otherAppInFrontAction)
  }

  /// What the battery question's sheet says: the energy rating of the wallpaper playing now, when
  /// one wallpaper plays and it has one, and the reduced profile.
  var batteryQuestionFacts: BatteryQuestionFacts {
    let settings = store.settingsSnapshot
    let playing = Set(store.appSnapshot.activeWallpaperIds)
    var percent: Double?
    if playing.count == 1, let id = playing.first,
      let entry = store.librarySnapshot.wallpapers.first(where: { $0.id == id }),
      let snapshot = store.wallpaperEnergyRatings?.snapshot(for: id, kind: entry.kind)
    {
      percent = LibraryEnergyRating(snapshot: snapshot)?.batteryPercentPerHour
    }
    return BatteryQuestionFacts(
      percentPerHour: percent, reducedFrameRate: Int(settings.batteryTargetFps),
      reducedRenderScale: settings.batteryRenderScale)
  }

  /// The prompt that is waiting while the panel can show it. The presenter adds its own deferrals
  /// (the welcome guide, a download dialog or popover, a switch in flight, a sign-in) before it
  /// presents.
  var pendingPrompt: SupportPromptStore.Prompt? {
    presentation.isVisible ? duePrompt : nil
  }

  /// A prompt is waiting and the panel can show it.
  var supportPromptPending: Bool { pendingPrompt != nil }

  /// A wallpaper switch is running or queued, which holds the offer back until it settles.
  var supportPromptDeferredBySwitch: Bool {
    isStoreBusy || !store.waitingActivationIDs.isEmpty
  }

  /// `supportPromptShown`: `prompt` is now on screen, so it is spent and never returns, even after a
  /// restart. Does nothing while the panel is not visible, which keeps a hidden panel from consuming it.
  func supportPromptShown(_ prompt: SupportPromptStore.Prompt = .support) {
    guard presentation.isVisible else { return }
    store.supportPrompt?.markPresented(prompt)
  }

  /// `supportPromptChoice`. Star opens the repository, Become a Supporter the pricing page (the Chinese
  /// one for a Chinese interface), through the `openSupportURL` seam and not the external-link allowlist;
  /// either link counts as having chosen the star only when it is the repository. **Join Discord**
  /// opens MMFoundation's invite through the same seam, after the external-link allowlist.
  /// **Send performance data** turns sending on and opens nothing. **Import my subscriptions** spends
  /// the prompt at once and goes on without it: Steam's sign-in window, then the downloads, whose
  /// failure (or finding nothing to download) reaches the banner. The battery question's three
  /// choices each make one setting through its Settings setter and open nothing; a setting the engine
  /// refuses throws and keeps the sheet up. Not now (and the battery question's Keep running) spends
  /// the prompt and opens nothing.
  ///
  /// A link that cannot be opened throws and leaves the prompt available for another try or Escape, so
  /// call this directly from the prompt (not through `launch`) to keep the error in the dialog.
  func supportPromptChoice(
    _ choice: SupportPromptChoice, for prompt: SupportPromptStore.Prompt = .support
  ) async throws {
    let url: URL
    switch (prompt, choice) {
    case (_, .dismiss):
      store.supportPrompt?.markPresented(prompt)
      return
    case (.telemetry, .enableTelemetry):
      store.telemetry?.setEnabled(true)
      store.supportPrompt?.markPresented(.telemetry)
      return
    case (.subscriptions, .importSubscriptions):
      store.supportPrompt?.markPresented(.subscriptions)
      steamWebSignInTask = Task { @MainActor [weak self] in
        guard let self else { return }
        do {
          if try await self.importSteamSubscriptions() == 0 {
            throw WallpaperActionError(
              message: L("Every wallpaper you subscribe to is already in your library."))
          }
        } catch {
          self.errors.report(error)
        }
      }
      return
    case (.discord, .joinDiscord):
      try await joinDiscord()
      store.supportPrompt?.markPresented(.discord)
      return
    case (.battery, .pauseWhileUsingOtherApps):
      try await setOtherAppInFrontAction(.pauseOnBattery)
      store.supportPrompt?.markPresented(.battery)
      return
    case (.battery, .reduceQualityOnBattery):
      try await setBatteryMode(.reducedQuality)
      store.supportPrompt?.markPresented(.battery)
      return
    case (.battery, .alwaysPauseOnBattery):
      try await setBatteryMode(.pause)
      store.supportPrompt?.markPresented(.battery)
      return
    case (.support, .star), (.star, .star):
      url = AppUpdateConfiguration.repositoryURL
    case (.support, .supporter):
      let path = appLanguage.effective.tag.hasPrefix("zh") ? "zh/pricing/" : "pricing/"
      url = URL(string: "https://www.wallpapermachine.app/\(path)")!
    default:
      throw InvalidControlValue()
    }
    guard openSupportURL(url) else {
      throw WallpaperActionError(message: L("The link could not be opened. Please try again."))
    }
    if url == AppUpdateConfiguration.repositoryURL { store.supportPrompt?.recordStarChosen() }
    store.supportPrompt?.markPresented(prompt)
  }
}
