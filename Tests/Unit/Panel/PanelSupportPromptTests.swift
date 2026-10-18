import XCTest

@testable import WallpaperMachine

/// The first-wallpaper support offer: when the panel reports it, what spends it and what its buttons
/// open. Replaces the model half of `WebPanelSupportPromptTests`; whether the dialog may appear over
/// the welcome guide, a popover or a download dialog is the presenter's.
@MainActor
final class PanelSupportPromptTests: PanelTestCase {
  private func qualify(_ prompt: SupportPromptStore) {
    prompt.recordDownload(wallpaperID: "downloaded")
    prompt.recordSuccessfulActivation(wallpaperID: "downloaded")
  }

  private func withPromptPanel(
    _ body: (PanelFixture, SupportPromptStore, UserDefaults) async throws -> Void
  ) async throws {
    let defaults = try TemporaryDefaults.make(for: self).defaults
    let prompt = SupportPromptStore(defaults: defaults)
    try await withPanel(supportPrompt: prompt) { panel in
      panel.controller.openSupportURL = { _ in
        XCTFail("Unexpected external link")
        return false
      }
      try await body(panel, prompt, defaults)
    }
  }

  /// Only a downloaded wallpaper that is then applied qualifies, and once the offer is shown it never
  /// returns, not even after a relaunch.
  func testAMatchingDownloadAndActivationOffersOnceAndTheOfferIsSpentForGood() async throws {
    try await withPromptPanel { panel, prompt, defaults in
      panel.show()
      let controller = panel.controller

      prompt.recordSuccessfulActivation(wallpaperID: "local-import")
      XCTAssertFalse(controller.supportPromptPending, "A local import does not qualify")

      prompt.recordDownload(wallpaperID: "downloaded")
      prompt.recordSuccessfulActivation(wallpaperID: "another-wallpaper")
      XCTAssertFalse(controller.supportPromptPending, "Another wallpaper than the downloaded one does not qualify")

      prompt.recordSuccessfulActivation(wallpaperID: "downloaded")
      XCTAssertTrue(controller.supportPromptPending)

      controller.supportPromptShown()
      XCTAssertFalse(prompt.isPending, "The shown offer is acknowledged durably")
      XCTAssertFalse(controller.supportPromptPending)
      let relaunched = SupportPromptStore(defaults: defaults)
      relaunched.recordDownload(wallpaperID: "second-download")
      relaunched.recordSuccessfulActivation(wallpaperID: "second-download")
      XCTAssertFalse(relaunched.isPending, "After a shown offer it never returns automatically")

      // A reopened panel does not bring it back either.
      let reopened = panel.buildController()
      XCTAssertFalse(reopened.supportPromptPending)
      reopened.stop()
    }
  }

  /// A hidden, minimised or covered panel must not report the offer, and showing it spends it, so a
  /// panel nobody can see never consumes it.
  func testAHiddenPanelDoesNotConsumeThePendingOffer() async throws {
    try await withPromptPanel { panel, prompt, defaults in
      let controller = panel.controller
      qualify(prompt)

      XCTAssertFalse(controller.supportPromptPending, "The window is not presented")
      controller.supportPromptShown()
      XCTAssertTrue(prompt.isPending, "A panel nobody can see cannot spend the offer")
      XCTAssertTrue(SupportPromptStore(defaults: defaults).isPending)

      panel.show()
      XCTAssertTrue(controller.supportPromptPending)
      panel.hide()
      XCTAssertFalse(controller.supportPromptPending, "Hiding the panel withdraws it again")
      panel.show()
      controller.supportPromptShown()
      XCTAssertFalse(prompt.isPending)
    }
  }

  func testTheOfferWaitsWhileAWallpaperSwitchRunsOrIsQueued() async throws {
    try await withPromptPanel { panel, prompt, _ in
      qualify(prompt)
      panel.show()
      XCTAssertFalse(panel.controller.supportPromptDeferredBySwitch)
      var release: CheckedContinuation<Void, Never>?
      let held = Task {
        try await panel.store.commands.run { await withCheckedContinuation { release = $0 } }
      }
      try await panel.waitUntil { release != nil }
      XCTAssertTrue(panel.controller.supportPromptDeferredBySwitch)
      release?.resume()
      _ = try await held.value
      XCTAssertFalse(panel.controller.supportPromptDeferredBySwitch)
    }
  }

  /// Star opens the repository and Become a Supporter the pricing page, in Chinese for a Chinese
  /// interface; either spends the offer.
  func testChoicesOpenTheRepositoryAndLocalizedPricingThroughTheInjectedOpener() async throws {
    for (choice, language, destination) in [
      (SupportPromptChoice.star, "en", "https://github.com/WallpaperMachine/WallpaperMachine"),
      (.supporter, "en", "https://www.wallpapermachine.app/pricing/"),
      (.supporter, "zh-Hans", "https://www.wallpapermachine.app/zh/pricing/"),
      (.supporter, "zh-Hant", "https://www.wallpapermachine.app/zh/pricing/"),
      (.supporter, "ja", "https://www.wallpapermachine.app/pricing/"),
    ] {
      try await withPromptPanel { panel, prompt, _ in
        var opened = [URL]()
        panel.controller.openSupportURL = { opened.append($0); return true }
        try panel.controller.appLanguage.set(language)
        panel.show()
        qualify(prompt)
        try await panel.controller.supportPromptChoice(choice)
        XCTAssertEqual(opened.map(\.absoluteString), [destination], "\(choice) in \(language)")
        XCTAssertFalse(prompt.isPending)
      }
    }
  }

  func testNotNowSpendsTheOfferAndOpensNothing() async throws {
    try await withPromptPanel { panel, prompt, _ in
      panel.show()
      qualify(prompt)
      try await panel.controller.supportPromptChoice(.dismiss)
      XCTAssertFalse(prompt.isPending)
    }
  }

  /// A link the Mac refuses to open leaves the offer available for another try or Escape.
  func testAFailedLinkKeepsTheOfferAvailableForRetryOrEscape() async throws {
    try pinPanelLanguageToEnglish()
    for retry in [true, false] {
      try await withPromptPanel { panel, prompt, defaults in
        var allowsOpening = false
        var opened = [URL]()
        panel.controller.openSupportURL = { opened.append($0); return allowsOpening }
        panel.show()
        qualify(prompt)

        do {
          try await panel.controller.supportPromptChoice(.star)
          XCTFail("The link could not be opened")
        } catch let error as WallpaperActionError {
          XCTAssertEqual(error.localizedDescription, "The link could not be opened. Please try again.")
        }
        XCTAssertEqual(opened.count, 1)
        XCTAssertTrue(prompt.isPending, "A failed link leaves the offer")
        XCTAssertTrue(panel.controller.supportPromptPending)

        if retry {
          allowsOpening = true
          try await panel.controller.supportPromptChoice(.star)
        } else {
          try await panel.controller.supportPromptChoice(.dismiss)
        }
        XCTAssertEqual(opened.count, retry ? 2 : 1)
        XCTAssertFalse(SupportPromptStore(defaults: defaults).isPending)
      }
    }
  }
}
