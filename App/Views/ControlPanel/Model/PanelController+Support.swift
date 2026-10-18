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
}

/// The one-time prompts: when one is pending, which, and what its buttons do.
///
/// Whether a prompt may appear, and which, is the store's (`SupportPromptStore`: the performance
/// data question, the offer to import the Steam subscriptions, the support offer after a downloaded
/// wallpaper is applied, the later star request, one a day). Whether it is on screen is the panel's: a hidden or minimised panel must not report
/// one, because showing it spends it.
extension PanelController {
  /// The prompt the store names now, whether or not anyone can see the panel. Without a telemetry
  /// service there is nothing to offer, so the performance data question never comes up.
  var duePrompt: SupportPromptStore.Prompt? {
    store.supportPrompt?.pendingPrompt(
      welcomeSeen: welcomeSeen, telemetryOn: store.telemetry?.isEnabled ?? true,
      steamSignedIn: workshop.downloader.savedAccount != nil)
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
  /// either link counts as having chosen the star only when it is the repository. **Send performance
  /// data** turns sending on and opens nothing. **Import my subscriptions** spends the prompt at
  /// once and goes on without it: Steam's sign-in window, then the downloads, whose failure (or
  /// finding nothing to download) reaches the banner. Not now spends the prompt and opens nothing.
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
