import XCTest

@testable import WallpaperMachine

/// Exercises the support offer through bundled WebKit and its native reply bridge, offscreen.
@MainActor
final class WebPanelSupportPromptTests: ControlPanelTestCase {
  func testMatchingDownloadAndActivationShowsOnceAndDismissalSurvivesPageReload() async throws {
    try await withPromptPanel { panel, prompt, defaults in
      try await panel.finishWelcome()
      panel.show()

      prompt.recordSuccessfulActivation(wallpaperID: "local-import")
      try await self.pushSnapshot(panel)
      try await panel.expectJS("return document.getElementById('support-dialog').open", equals: false)

      prompt.recordDownload(wallpaperID: "downloaded")
      prompt.recordSuccessfulActivation(wallpaperID: "another-wallpaper")
      try await self.pushSnapshot(panel)
      try await panel.expectJS("return document.getElementById('support-dialog').open", equals: false)

      _ = try await panel.js("document.activeElement?.blur()")
      try await panel.expectJS("return document.activeElement === document.body", equals: true)
      prompt.recordSuccessfulActivation(wallpaperID: "downloaded")
      try await panel.waitJS("document.getElementById('support-dialog').open")
      try await panel.waitUntil { !prompt.isPending }
      let relaunched = SupportPromptStore(defaults: defaults)
      relaunched.recordDownload(wallpaperID: "second-download")
      relaunched.recordSuccessfulActivation(wallpaperID: "second-download")
      XCTAssertFalse(relaunched.isPending, "The visible page must acknowledge the offer durably")

      _ = try await panel.js("document.querySelector('#support-dialog [data-choice=\"dismiss\"]').click()")
      try await panel.waitJS("!document.getElementById('support-dialog').open")
      try await panel.expectJS("return document.activeElement === document.querySelector('.tabs [aria-current=\"page\"]')", equals: true)
      try await self.pushSnapshot(panel)
      try await panel.expectJS("return document.getElementById('support-dialog').open", equals: false)

      panel.controller.webViewWebContentProcessDidTerminate(panel.web)
      try await panel.waitUntil(timeout: 15) { panel.controller.isReady }
      try await self.setPageVisible(true, in: panel)
      try await panel.waitJS("document.getElementById('welcome').hidden")
      try await self.pushSnapshot(panel)
      try await panel.expectJS("return document.getElementById('support-dialog').open", equals: false)
    }
  }

  func testWelcomeRetainsPendingOfferUntilOnboardingFinishes() async throws {
    try await withPromptPanel { panel, prompt, defaults in
      panel.show()
      try await panel.waitJS("!document.getElementById('welcome').hidden")
      self.qualify(prompt)
      try await self.pushSnapshot(panel)
      try await panel.expectJS("return document.getElementById('support-dialog').open", equals: false)
      XCTAssertTrue(SupportPromptStore(defaults: defaults).isPending)

      try await panel.finishWelcome()
      try await panel.waitJS("document.getElementById('support-dialog').open")
      try await panel.waitUntil { !prompt.isPending }
    }
  }

  func testAnotherModalRetainsPendingOfferUntilItCloses() async throws {
    try await withPromptPanel { panel, prompt, defaults in
      try await panel.finishWelcome()
      panel.show()
      _ = try await panel.js("""
        const blocker = document.createElement('dialog');
        blocker.id = 'support-test-blocker';
        document.body.append(blocker);
        blocker.showModal();
        """)
      self.qualify(prompt)
      try await self.pushSnapshot(panel)
      try await panel.expectJS("return document.getElementById('support-dialog').open", equals: false)
      XCTAssertTrue(SupportPromptStore(defaults: defaults).isPending)

      _ = try await panel.js("""
        const blocker = document.getElementById('support-test-blocker');
        blocker.close();
        blocker.remove();
        """)
      try await self.pushSnapshot(panel)
      try await panel.waitJS("document.getElementById('support-dialog').open")
      try await panel.waitUntil { !prompt.isPending }
    }
  }

  func testHiddenNativePresentationDoesNotConsumePendingOffer() async throws {
    try await withPromptPanel { panel, prompt, defaults in
      try await panel.finishWelcome()
      self.qualify(prompt)
      try await self.pushSnapshot(panel)
      try await panel.expectJS("return document.getElementById('support-dialog').open", equals: false)
      XCTAssertTrue(SupportPromptStore(defaults: defaults).isPending)

      panel.show()
      try await panel.waitJS("document.getElementById('support-dialog').open")
      try await panel.waitUntil { !prompt.isPending }
    }
  }

  func testHiddenWebPageDoesNotConsumePendingOfferUntilVisibilityChanges() async throws {
    try await withPromptPanel { panel, prompt, defaults in
      try await panel.finishWelcome()
      try await self.setPageVisible(false, in: panel)
      panel.show()
      self.qualify(prompt)
      try await self.pushSnapshot(panel)
      try await panel.expectJS("return document.getElementById('support-dialog').open", equals: false)
      XCTAssertTrue(SupportPromptStore(defaults: defaults).isPending)

      try await self.setPageVisible(true, in: panel)
      try await panel.waitJS("document.getElementById('support-dialog').open")
      try await panel.waitUntil { !prompt.isPending }
    }
  }

  func testChoicesOpenRepositoryAndLocalizedPricingThroughInjectedOpener() async throws {
    for (choice, language, destination) in [
      ("star", "en", "https://github.com/WallpaperMachine/WallpaperMachine"),
      ("supporter", "en", "https://www.wallpapermachine.app/pricing/"),
      ("supporter", "zh-Hans", "https://www.wallpapermachine.app/zh/pricing/"),
    ] {
      try await withPromptPanel { panel, prompt, _ in
        var opened: [URL] = []
        panel.controller.openSupportURL = { opened.append($0); return true }
        try panel.controller.appLanguage.set(language)
        defer { try? panel.controller.appLanguage.set(AppLanguageStore.systemChoice) }
        try await panel.finishWelcome()
        panel.show()
        self.qualify(prompt)
        try await panel.waitJS("document.getElementById('support-dialog').open")
        _ = try await panel.js("document.querySelector('#support-dialog [data-choice=\"\(choice)\"]').click()")
        try await panel.waitJS("!document.getElementById('support-dialog').open")
        XCTAssertEqual(opened.map(\.absoluteString), [destination])
        XCTAssertFalse(prompt.isPending)
      }
    }
  }

  func testFailedLinkKeepsOfferAvailableForRetryOrEscape() async throws {
    for retry in [true, false] {
      try await withPromptPanel { panel, prompt, defaults in
        var allowsOpening = false
        var opened: [URL] = []
        panel.controller.openSupportURL = { opened.append($0); return allowsOpening }
        try await panel.finishWelcome()
        panel.show()
        self.qualify(prompt)
        try await panel.waitJS("document.getElementById('support-dialog').open")
        _ = try await panel.js("document.querySelector('#support-dialog [data-choice=\"star\"]').click()")
        try await panel.waitJS("document.querySelector('#support-dialog [role=\"alert\"]') && !document.querySelector('#support-dialog [data-choice=\"star\"]').disabled")
        try await panel.expectJS("return document.getElementById('support-dialog').open", equals: true)
        XCTAssertEqual(opened.count, 1)

        if retry {
          allowsOpening = true
          _ = try await panel.js("document.querySelector('#support-dialog [data-choice=\"star\"]').click()")
        } else {
          _ = try await panel.js("document.getElementById('support-dialog').dispatchEvent(new Event('cancel', {cancelable:true}))")
        }
        try await panel.waitJS("!document.getElementById('support-dialog').open")
        XCTAssertEqual(opened.count, retry ? 2 : 1)
        XCTAssertFalse(SupportPromptStore(defaults: defaults).isPending)
        try await self.pushSnapshot(panel)
        try await panel.expectJS("return document.getElementById('support-dialog').open", equals: false)
      }
    }
  }

  /// Someone who finished the guide before it had the switch is asked once, and the answer
  /// turns sending on without opening any link.
  func testExistingUserIsAskedOnceAboutPerformanceData() async throws {
    try await withPromptPanel { panel, prompt, _ in
      let folder = FileManager.default.temporaryDirectory.appendingPathComponent("telemetry-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: folder) }
      let telemetry = TelemetryService(
        preferences: TelemetryPreferences(defaults: try TemporaryDefaults.make(for: self).defaults),
        spool: TelemetrySpool(folder: folder), uploader: NoUploads(), sampler: nil,
        sleep: { _ in throw CancellationError() })
      panel.store.telemetry = telemetry
      // An existing user: the guide was finished by an earlier build, so this page never shows it.
      panel.controller.welcomeSeen = true
      panel.controller.webViewWebContentProcessDidTerminate(panel.web)
      try await panel.waitUntil(timeout: 15) { panel.controller.isReady }
      try await self.setPageVisible(true, in: panel)
      panel.show()
      try await self.pushSnapshot(panel)
      try await panel.waitJS("document.getElementById('support-dialog').open")
      try await panel.expectJS(
        "return !!document.querySelector('#support-dialog [data-choice=\"enableTelemetry\"]')", equals: true)

      _ = try await panel.js("document.querySelector('#support-dialog [data-choice=\"enableTelemetry\"]').click()")
      try await panel.waitJS("!document.getElementById('support-dialog').open")
      try await panel.waitUntil { telemetry.isEnabled }
      XCTAssertNil(prompt.pendingPrompt(welcomeSeen: true, telemetryOn: false, now: Date() + 2 * 86_400))
    }
  }

  private struct NoUploads: TelemetryUploading {
    func send(_ report: Data) async throws {}
    func delete(install: String) async throws {}
  }

  private func qualify(_ prompt: SupportPromptStore) {
    prompt.recordDownload(wallpaperID: "downloaded")
    prompt.recordSuccessfulActivation(wallpaperID: "downloaded")
  }

  private func pushSnapshot(_ panel: PanelFixture) async throws {
    _ = try await panel.js("""
      const snapshot = await window.webkit.messageHandlers.native.postMessage({action:'ready'});
      window.wallpaperUI.receive(snapshot);
      """)
  }

  private func setPageVisible(_ visible: Bool, in panel: PanelFixture) async throws {
    // A windowless WKWebView is always hidden. Simulate its visibility event while
    // leaving native presentation visibility independently controlled by panel.show().
    _ = try await panel.js("""
      Object.defineProperty(document, 'hidden', { configurable: true, get: () => \(!visible) });
      document.dispatchEvent(new Event('visibilitychange'));
      """)
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
      try await self.setPageVisible(true, in: panel)
      try await body(panel, prompt, defaults)
    }
  }
}
