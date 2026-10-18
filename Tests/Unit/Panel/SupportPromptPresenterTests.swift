import XCTest

@testable import WallpaperMachine

/// When the first-wallpaper support offer may be on screen and what its choices do. Replaces the
/// page half of `WebPanelSupportPromptTests` (the store half is `PanelSupportPromptTests`): the
/// guide, other modals, a switch in progress and a hidden window hold the offer without spending
/// it; only a visible sheet spends it; a link that fails keeps it; leaving always works.
@MainActor
final class SupportPromptPresenterTests: PanelTestCase {
  private func qualify(_ prompt: SupportPromptStore) {
    prompt.recordDownload(wallpaperID: "downloaded")
    prompt.recordSuccessfulActivation(wallpaperID: "downloaded")
  }

  private func withPresenter(
    welcomeSeen: Bool = true,
    _ body: (PanelFixture, SupportPromptPresenter, SupportPromptStore, UserDefaults) async throws -> Void
  ) async throws {
    let defaults = try TemporaryDefaults.make(for: self).defaults
    let prompt = SupportPromptStore(defaults: defaults)
    try await withPanel(supportPrompt: prompt, welcomeSeen: welcomeSeen) { panel in
      panel.controller.openSupportURL = { _ in
        XCTFail("Unexpected external link")
        return false
      }
      try await body(panel, panel.controller.supportPrompt, prompt, defaults)
    }
  }

  // MARK: The gate

  func testEveryHoldKeepsTheOfferBackAndNoneLetsItThrough() {
    let open = SupportPromptGate(windowIsVisible: true)
    XCTAssertTrue(open.allowsPresentation)
    XCTAssertFalse(SupportPromptGate().allowsPresentation, "A window nobody sees")
    var holds = [SupportPromptGate]()
    for change: (inout SupportPromptGate) -> Void in [
      { $0.welcomeIsOpen = true }, { $0.popoverIsOpen = true }, { $0.downloadDialogIsOpen = true },
      { $0.switchIsInProgress = true }, { $0.pixivIsSigningIn = true }, { $0.downloadAwaitsSteam = true },
    ] {
      var gate = open
      change(&gate)
      holds.append(gate)
    }
    XCTAssertEqual(holds.count, 6)
    XCTAssertTrue(holds.allSatisfy { !$0.allowsPresentation })
  }

  // MARK: What holds the offer

  /// While the guide is open the offer stays pending, and shows when the guide ends.
  func testTheGuideHoldsTheOfferUntilItEnds() async throws {
    try await withPresenter(welcomeSeen: false) { panel, presenter, prompt, _ in
      qualify(prompt)
      panel.show()
      XCTAssertTrue(panel.controller.supportPromptPending)
      XCTAssertFalse(presenter.wantsPresentation, "The guide keeps priority")
      XCTAssertTrue(prompt.isPending, "and the offer stays pending")

      panel.controller.welcome.open()
      panel.controller.welcome.finish()
      XCTAssertTrue(presenter.wantsPresentation)
    }
  }

  /// Another popover, the download dialog, a wallpaper switch or a Steam sign-in each hold the offer;
  /// it resumes, unspent, when they are over.
  func testAnotherModalOrASwitchHoldsTheOfferAndItResumes() async throws {
    try await withPresenter { panel, presenter, prompt, _ in
      qualify(prompt)
      panel.show()
      XCTAssertTrue(presenter.wantsPresentation)

      panel.controller.shell.isPopoverOpen = true
      XCTAssertFalse(presenter.wantsPresentation, "A popover is open")
      panel.controller.shell.isPopoverOpen = false
      XCTAssertTrue(presenter.wantsPresentation)

      var release: CheckedContinuation<Void, Never>?
      let held = Task {
        try await panel.store.commands.run { await withCheckedContinuation { release = $0 } }
      }
      try await panel.waitUntil { release != nil }
      XCTAssertFalse(presenter.wantsPresentation, "A wallpaper switch is running")
      release?.resume()
      _ = try await held.value
      XCTAssertTrue(presenter.wantsPresentation)
      XCTAssertTrue(prompt.isPending, "Nothing above spent the offer")
    }
  }

  /// The real download dialog holds the offer while it is open, and the offer resumes, unspent,
  /// when it closes.
  func testTheDownloadDialogHoldsTheOfferUntilItCloses() async throws {
    try await withPresenter { panel, presenter, prompt, _ in
      let downloads = panel.controller.downloads
      qualify(prompt)
      panel.show()
      XCTAssertTrue(presenter.wantsPresentation)

      // The shared scene resources wait for SteamCMD, which is not set up: the dialog opens on them.
      await downloads.requestSceneAssets().value
      XCTAssertTrue(downloads.isDialogOpen)
      XCTAssertFalse(presenter.wantsPresentation, "The download dialog comes first")

      downloads.closeDialog()
      XCTAssertFalse(downloads.isDialogOpen)
      XCTAssertTrue(presenter.wantsPresentation, "The offer comes back once the dialog is closed")
      XCTAssertTrue(prompt.isPending, "and nothing spent it")
    }
  }

  /// A hidden window reports no offer and shows none, so nobody who cannot see it spends it.
  func testAHiddenWindowNeitherShowsNorSpendsTheOffer() async throws {
    try await withPresenter { panel, presenter, prompt, defaults in
      qualify(prompt)
      XCTAssertFalse(presenter.wantsPresentation, "The window is not on screen")
      presenter.sheetDidAppear()
      XCTAssertTrue(prompt.isPending, "A sheet nobody could see does not spend the offer")
      XCTAssertTrue(SupportPromptStore(defaults: defaults).isPending)
    }
    try await withPresenter { panel, presenter, prompt, _ in
      qualify(prompt)
      panel.show()
      XCTAssertTrue(presenter.wantsPresentation)
      panel.hide()
      XCTAssertFalse(presenter.wantsPresentation, "Hiding the window withdraws the sheet")
      panel.show()
      XCTAssertTrue(presenter.wantsPresentation)
    }
  }

  // MARK: Showing, spending, resuming

  /// The offer is spent by a sheet that was seen; the presenter keeps that presentation when
  /// something takes the window and brings it back, and a deliberate answer ends it for good.
  func testASeenOfferIsSpentOnceAndTheSamePresentationResumesAfterABlock() async throws {
    try await withPresenter { panel, presenter, prompt, defaults in
      let controller = panel.controller
      prompt.recordSuccessfulActivation(wallpaperID: "local-import")
      panel.show()
      XCTAssertFalse(presenter.wantsPresentation, "A local import never qualifies")
      qualify(prompt)
      XCTAssertTrue(presenter.wantsPresentation)
      XCTAssertTrue(prompt.isPending, "Wanting is not showing")

      presenter.sheetDidAppear()
      XCTAssertFalse(prompt.isPending, "Seen: spent for good")
      XCTAssertFalse(controller.supportPromptPending)
      XCTAssertTrue(presenter.wantsPresentation, "The presentation stays up though the store is spent")

      controller.shell.isPopoverOpen = true
      XCTAssertFalse(presenter.wantsPresentation, "Something took the window")
      XCTAssertFalse(presenter.isDismissed, "but nobody dismissed the offer")
      controller.shell.isPopoverOpen = false
      XCTAssertTrue(presenter.wantsPresentation, "The same presentation resumes")

      presenter.sheetDidAppear()
      XCTAssertTrue(presenter.hasBeenShown)
      await presenter.dismiss().value
      XCTAssertFalse(presenter.wantsPresentation, "Not now ends it")
      XCTAssertFalse(SupportPromptStore(defaults: defaults).isPending, "and it never returns")

      let reopened = panel.buildController()
      XCTAssertFalse(reopened.supportPromptPending, "A reopened window does not show it again")
      XCTAssertFalse(reopened.supportPrompt.wantsPresentation)
      reopened.stop()
    }
  }

  func testAnUnrelatedActivationOffersNothing() async throws {
    try await withPresenter { panel, presenter, prompt, _ in
      panel.show()
      prompt.recordDownload(wallpaperID: "downloaded")
      prompt.recordSuccessfulActivation(wallpaperID: "another")
      XCTAssertFalse(presenter.wantsPresentation, "Another wallpaper than the downloaded one")
    }
  }

  // MARK: Choices

  /// Star opens the repository and Become a Supporter the pricing page, in Chinese for a Chinese
  /// interface; either answer ends the offer.
  func testChoicesOpenTheRightPageAndEndTheOffer() async throws {
    for (choice, language, destination) in [
      (SupportPromptChoice.star, "en", "https://github.com/WallpaperMachine/WallpaperMachine"),
      (.supporter, "en", "https://www.wallpapermachine.app/pricing/"),
      (.supporter, "zh-Hans", "https://www.wallpapermachine.app/zh/pricing/"),
      (.supporter, "zh-Hant", "https://www.wallpapermachine.app/zh/pricing/"),
      (.supporter, "ja", "https://www.wallpapermachine.app/pricing/"),
    ] {
      try await withPresenter { panel, presenter, prompt, _ in
        var opened = [URL]()
        panel.controller.openSupportURL = { opened.append($0); return true }
        try panel.controller.appLanguage.set(language)
        panel.show()
        qualify(prompt)
        presenter.sheetDidAppear()
        await presenter.choose(choice)
        XCTAssertEqual(opened.map(\.absoluteString), [destination], "\(choice) in \(language)")
        XCTAssertTrue(presenter.isDismissed)
        XCTAssertFalse(presenter.wantsPresentation, "The sheet closes after a link opened")
        XCTAssertNil(presenter.error)
      }
    }
  }

  /// A link the Mac refuses to open keeps the sheet up with the reason; the other row, a retry and
  /// Not now (or Escape) all still work.
  func testAFailedLinkKeepsTheOfferForARetryOrEscape() async throws {
    try pinPanelLanguageToEnglish()
    for retry in [true, false] {
      try await withPresenter { panel, presenter, prompt, defaults in
        var allowsOpening = false
        var opened = [URL]()
        panel.controller.openSupportURL = { opened.append($0); return allowsOpening }
        panel.show()
        qualify(prompt)
        presenter.sheetDidAppear()

        await presenter.choose(.star)
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(presenter.error, "The link could not be opened. Please try again.")
        XCTAssertFalse(presenter.isDismissed)
        XCTAssertFalse(presenter.isChoosing, "The rows are enabled again")
        XCTAssertTrue(presenter.wantsPresentation, "The offer stays up")

        if retry {
          allowsOpening = true
          await presenter.choose(.star)
          XCTAssertEqual(opened.count, 2)
          XCTAssertNil(presenter.error)
          XCTAssertTrue(presenter.isDismissed)
        } else {
          await presenter.dismiss().value
          XCTAssertEqual(opened.count, 1, "Leaving opens nothing")
          XCTAssertTrue(presenter.isDismissed)
        }
        XCTAssertFalse(SupportPromptStore(defaults: defaults).isPending)
      }
    }
  }

  /// A second click while a link is being opened is ignored, and a dismissed offer ignores clicks.
  func testAChoiceAfterTheOfferEndedDoesNothing() async throws {
    try await withPresenter { panel, presenter, prompt, _ in
      var opened = 0
      panel.controller.openSupportURL = { _ in opened += 1; return true }
      panel.show()
      qualify(prompt)
      presenter.sheetDidAppear()
      await presenter.dismiss().value
      await presenter.choose(.star)
      XCTAssertEqual(opened, 0)
    }
  }
}
