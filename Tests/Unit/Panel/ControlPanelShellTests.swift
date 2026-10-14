import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import XCTest

@testable import WallpaperMachine

/// Window sizing, bundled asset routing, language, appearance, About/update and the top bar.
@MainActor
final class ControlPanelShellTests: ControlPanelTestCase {
  func testControlPanelAcceptsSmallWindowProposalsWithLongDisplayTitle() async throws {
    let fixture = makeStore()
    fixture.bridge.snapshot = BridgeSnapshotBundle(
      app: fixture.store.appSnapshot, library: fixture.store.librarySnapshot,
      wallpaperOptions: nil, monitorInformation: fixture.store.monitorInformationSnapshot,
      settings: fixture.store.settingsSnapshot
    )
    try await fixture.store.refreshAllAsync()
    let session = FileManager.default.temporaryDirectory.appendingPathComponent(
      "layout-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: session) }
    let defaults = try TemporaryDefaults.make(for: self).defaults
    let workshop = WorkshopStore(
      downloader: WorkshopDownloadManager(sessionDirectory: session),
      supportDirectory: session, defaults: defaults)
    let updater = AppUpdateStore(currentVersion: "0.1.0", client: DisabledAppUpdateClient())

    for language in AppLanguage.supported.map(\.tag) {
      let controller = NSHostingController(
        rootView:
          ControlPanelView(
            store: fixture.store, navigation: ControlPanelNavigation(), workshop: workshop,
            pixiv: PixivStore(), updater: updater, imports: LibraryImportStore()
          )
          .environment(\.locale, Locale(identifier: language))
          .defaultAppStorage(defaults)
      )
      controller.sizingOptions = []
      for size in [
        NSSize(width: 760, height: 560), NSSize(width: 960, height: 640),
        NSSize(width: 1240, height: 800),
      ] {
        controller.view.setFrameSize(size)
        controller.view.layoutSubtreeIfNeeded()
        let measured = controller.sizeThatFits(in: size)
        XCTAssertEqual(
          measured.width, size.width, accuracy: 1,
          "\(language): the root must accept the window width")
        XCTAssertLessThanOrEqual(
          measured.height, size.height + 1, "\(language): content must not force a taller window")
        XCTAssertNil(controller.view.window, "Layout measurement must stay offscreen")
      }
    }
  }

  func testBundledWebKitInterfaceLoadsAndRoutesSettingsWithoutWindow() async throws {
    let fixture = makeStore()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "web-panel-\(UUID().uuidString)")
    let defaults = try TemporaryDefaults.make(for: self).defaults
    defer { try? FileManager.default.removeItem(at: root) }
    let workshop = WorkshopStore(
      downloader: WorkshopDownloadManager(sessionDirectory: root), supportDirectory: root,
      defaults: defaults)
    let navigation = ControlPanelNavigation()
    let controller = WebPanelController(
      store: fixture.store, navigation: navigation, workshop: workshop,
      defaults: defaults, appLanguage: .english())
    let web = controller.makeWebView()
    defer { controller.stop() }
    web.setFrameSize(NSSize(width: 960, height: 640))
    let deadline = Date().addingTimeInterval(15)
    while !controller.isReady && Date() < deadline {
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertTrue(
      controller.isReady,
      "Bundled ES modules must load under the custom scheme and reach the native reply bridge")
    guard controller.isReady else { return }
    try await finishWelcome(in: web)
    let result =
      try await web.callAsyncJavaScript(
        """
        const state = await window.webkit.messageHandlers.native.postMessage({action:'navigate',page:'settings'});
        window.wallpaperUI.receive(state);
        return {page:state.page, visible:!document.getElementById('settings-content').hidden};
        """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
    XCTAssertEqual(result?["page"] as? String, "settings")
    XCTAssertEqual(result?["visible"] as? Bool, true)
    XCTAssertEqual(navigation.selection, .settings)
    let denied =
      try await web.callAsyncJavaScript(
        """
        try { await window.webkit.messageHandlers.native.postMessage({action:'openExternal',url:'file:///etc/passwd'}); return false; }
        catch { return true; }
        """, arguments: [:], in: nil, contentWorld: .page) as? Bool
    XCTAssertEqual(denied, true)
    XCTAssertNil(web.window, "This regression must not open a desktop window")
    await workshop.steamCMDSetup.shutdown()
  }

  func testSettingsKeyboardNavigationResetsScrollAndPreservesDisclosureState() async throws {
    try await withPanel { panel in
      try await panel.finishWelcome()
      panel.web.setFrameSize(NSSize(width: 760, height: 560))
      try await panel.waitJS("window.innerWidth === 760")
      let result = try await panel.js("""
        const state = await window.webkit.messageHandlers.native.postMessage({action:'navigate', page:'settings'});
        window.wallpaperUI.receive(state);
        const tab = name => document.querySelector(`[data-section="${name}"]`);
        tab('performance').click();
        const advanced = document.querySelector('[data-key="performance-advanced"]');
        advanced.querySelector('summary').click();
        const scroll = document.querySelector('.settings-scroll');
        scroll.scrollTop = scroll.scrollHeight;
        const startedScrolled = scroll.scrollTop > 0;
        tab('performance').focus({preventScroll:true});
        tab('performance').dispatchEvent(new KeyboardEvent('keydown', {key:'ArrowUp', bubbles:true}));
        const navigated = !document.getElementById('settings-about').hidden
          && document.activeElement === tab('about');
        const reset = scroll.scrollTop === 0;
        tab('about').dispatchEvent(new KeyboardEvent('keydown', {key:'ArrowDown', bubbles:true}));
        const input = advanced.querySelector('input');
        input.focus();
        window.wallpaperUI.receive(state);
        return {
          startedScrolled, navigated, reset,
          keptDisclosure: advanced.open && advanced.isConnected,
          keptFocus: document.activeElement === input && input.isConnected,
          selectedTabs: document.querySelectorAll('.settings-nav [aria-selected="true"]').length
        };
        """) as? [String: Any]
      XCTAssertEqual(result?["startedScrolled"] as? Bool, true)
      XCTAssertEqual(result?["navigated"] as? Bool, true)
      XCTAssertEqual(result?["reset"] as? Bool, true)
      XCTAssertEqual(result?["keptDisclosure"] as? Bool, true)
      XCTAssertEqual(result?["keptFocus"] as? Bool, true)
      XCTAssertEqual(result?["selectedTabs"] as? Int, 1)
    }
  }

  func testPanelRendersInTheControllerLanguage() async throws {
    XCTAssertEqual(WebPanelController.pageLanguage("zh-Hans"), "zh-Hans")
    XCTAssertEqual(WebPanelController.pageLanguage(nil), "en")
    XCTAssertEqual(
      WebPanelController.pageLanguage("en';alert(1);//"), "en",
      "Only a plain language tag may be spliced into the user script")
    let fixture = makeStore()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "web-panel-language-\(UUID().uuidString)")
    let defaults = try TemporaryDefaults.make(for: self).defaults
    defer { try? FileManager.default.removeItem(at: root) }
    let workshop = WorkshopStore(
      downloader: WorkshopDownloadManager(sessionDirectory: root), supportDirectory: root,
      defaults: defaults)
    var rendered: [String: [String: Any]] = [:]
    for language in AppLanguage.supported.map(\.tag) {
      let controller = WebPanelController(
        store: fixture.store, navigation: ControlPanelNavigation(), workshop: workshop,
        defaults: defaults,
        appLanguage: AppLanguageStore(defaults: defaults, systemLanguages: [language]))
      let web = controller.makeWebView()
      defer { controller.stop() }
      web.setFrameSize(NSSize(width: 960, height: 640))
      let deadline = Date().addingTimeInterval(15)
      while !controller.isReady && Date() < deadline {
        try await Task.sleep(for: .milliseconds(100))
      }
      guard controller.isReady else { return XCTFail("\(language): panel did not become ready") }
      try await finishWelcome(in: web)
      rendered[language] =
        try await web.callAsyncJavaScript(
          """
          const bridge = window.webkit.messageHandlers.native;
          window.wallpaperUI.receive(await bridge.postMessage({action:'navigate',page:'installed'}));
          const summary = document.getElementById('browser-summary').textContent;
          window.wallpaperUI.receive(await bridge.postMessage({action:'navigate',page:'settings'}));
          return {
            lang: document.documentElement.lang,
            tab: document.querySelector('.tabs [data-page="discover"]').textContent,
            navLabel: document.querySelector('.tabs').getAttribute('aria-label'),
            section: document.querySelector('#settings-tab-general').textContent,
            summary,
          };
          """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
      let contracts = try await web.callAsyncJavaScript(
        """
        const {t, setLanguage} = await import('./i18n.js');
        const cases = [['zh-CN','zh-Hans'], ['zh-Hans-TW','zh-Hans'], ['zh','zh-Hans'],
          ['zh-TW','zh-Hant'], ['zh-Hant','zh-Hant'], ['zh-Hant-CN','zh-Hant'], ['zh-HK','zh-Hant'],
          ['ja','ja'], ['ja-JP','ja'], ['en-CN','en'], ['en-GB','en'],
          ['fr','en'], ['zhgarbage','en'], ['','en'], [undefined,'en']];
        const resolved = cases.every(([tag, expected]) => setLanguage(tag) === expected);
        setLanguage('zh-Hans');
        const payload = '<img src=x onerror=alert(1)> {count} $&';
        const interpolated = t('Select: {title}', {title: payload});
        const safeSubstitution = interpolated.includes(payload);
        const fallback = t('Uncatalogued {value}', {value: 'value'}) === 'Uncatalogued value';
        const missing = t('Select: {title}').includes('{title}');
        setLanguage(window.__appLanguage);
        return resolved && safeSubstitution && fallback && missing;
        """, arguments: [:], in: nil, contentWorld: .page) as? Bool
      XCTAssertEqual(contracts, true, "Language fallback and literal interpolation must stay predictable")
      XCTAssertNil(web.window, "This regression must not open a desktop window")
    }
    let english = try XCTUnwrap(rendered["en"])
    XCTAssertEqual(english["lang"] as? String, "en")
    for language in AppLanguage.supported.map(\.tag) where language != "en" {
      let translated = try XCTUnwrap(rendered[language], language)
      XCTAssertEqual(translated["lang"] as? String, language)
      for key in ["tab", "navLabel", "section", "summary"] {
        let en = try XCTUnwrap(english[key] as? String, key)
        let text = try XCTUnwrap(translated[key] as? String, "\(language) \(key)")
        XCTAssertFalse(en.isEmpty, key)
        XCTAssertNotEqual(en, text, "\(language) \(key): the page must render the controller's language, not English")
        // Han characters for Chinese; Han or kana for Japanese.
        XCTAssertTrue(
          text.unicodeScalars.contains { $0.properties.isIdeographic || (0x3040...0x30FF).contains($0.value) },
          "\(language) \(key): expected CJK text, got \(text)")
      }
    }
    await workshop.steamCMDSetup.shutdown()
  }

  func testLanguageSettingSwitchesThePanelInPlaceAndOffersEveryShippedLanguage() async throws {
    let fixture = makeStore()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "web-panel-language-switch-\(UUID().uuidString)")
    let defaults = try TemporaryDefaults.make(for: self).defaults
    defer { try? FileManager.default.removeItem(at: root) }
    let workshop = WorkshopStore(
      downloader: WorkshopDownloadManager(sessionDirectory: root), supportDirectory: root,
      defaults: defaults)
    let languages = AppLanguageStore(defaults: defaults, systemLanguages: ["en"])
    let controller = WebPanelController(
      store: fixture.store, navigation: ControlPanelNavigation(), workshop: workshop,
      defaults: defaults,
      appLanguage: languages)
    let web = controller.makeWebView()
    defer { controller.stop() }
    web.setFrameSize(NSSize(width: 960, height: 640))
    let deadline = Date().addingTimeInterval(15)
    while !controller.isReady && Date() < deadline {
      try await Task.sleep(for: .milliseconds(100))
    }
    guard controller.isReady else { return XCTFail("panel did not become ready") }
    try await finishWelcome(in: web)
    let probe = """
      const bridge = window.webkit.messageHandlers.native;
      window.wallpaperUI.receive(await bridge.postMessage({action:'navigate',page:'settings'}));
      const reply = await bridge.postMessage({action:'languageSetting', value});
      window.wallpaperUI.receive(reply);
      const select = document.querySelector('[data-language-setting]');
      return {
        lang: document.documentElement.lang,
        tab: document.querySelector('.tabs [data-page="discover"]').textContent,
        navLabel: document.querySelector('.tabs').getAttribute('aria-label'),
        section: document.querySelector('#settings-tab-general').textContent,
        selected: select.value,
        options: Array.from(select.options).map(option => [option.value, option.textContent]),
        effective: reply.language.effective,
      };
      """
    let chineseReply = try await web.callAsyncJavaScript(
      probe, arguments: ["value": "zh-Hans"], in: nil, contentWorld: .page)
    let chinese = try XCTUnwrap(chineseReply as? [String: Any])
    XCTAssertEqual(chinese["lang"] as? String, "zh-Hans")
    XCTAssertEqual(chinese["selected"] as? String, "zh-Hans")
    XCTAssertEqual(chinese["effective"] as? String, "zh-Hans")
    XCTAssertEqual(languages.preference, "zh-Hans")
    XCTAssertEqual(controller.language, "zh-Hans")
    for key in ["tab", "navLabel", "section"] {
      let text = try XCTUnwrap(chinese[key] as? String, key)
      XCTAssertTrue(
        text.unicodeScalars.contains { $0.properties.isIdeographic },
        "\(key): the page must switch without a reload, got \(text)")
    }
    let options = try XCTUnwrap(chinese["options"] as? [[String]])
    XCTAssertEqual(options.first?.first, "system")
    XCTAssertEqual(
      options.dropFirst().map { $0[0] }, AppLanguage.supported.map(\.tag),
      "Every shipped language is offered after System")
    for language in AppLanguage.supported {
      XCTAssertTrue(
        options.contains { $0[0] == language.tag && $0[1] == language.name },
        "\(language.tag) is listed under its own name in any interface language")
    }

    let englishReply = try await web.callAsyncJavaScript(
      probe, arguments: ["value": "system"], in: nil, contentWorld: .page)
    let english = try XCTUnwrap(englishReply as? [String: Any])
    XCTAssertEqual(english["lang"] as? String, "en")
    XCTAssertEqual(english["selected"] as? String, "system")
    XCTAssertEqual(languages.preference, AppLanguageStore.systemChoice)
    for key in ["tab", "navLabel", "section"] {
      let text = try XCTUnwrap(english[key] as? String, key)
      XCTAssertNotEqual(text, chinese[key] as? String, key)
      XCTAssertFalse(text.unicodeScalars.contains { $0.properties.isIdeographic }, key)
    }

    let refused =
      try await web.callAsyncJavaScript(
        """
        try { await window.webkit.messageHandlers.native.postMessage({action:'languageSetting', value:'zh-TW'}); return false; }
        catch { return document.documentElement.lang === 'en'; }
        """, arguments: [:], in: nil, contentWorld: .page) as? Bool
    XCTAssertEqual(refused, true, "A language the app does not ship is refused and changes nothing")
    XCTAssertNil(web.window, "This regression must not open a desktop window")
    await workshop.steamCMDSetup.shutdown()
  }

  func testUpdateSnapshotExposesCheckDownloadAndReadyActions() async throws {
    let fixture = makeStore()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "update-snap-\(UUID().uuidString)")
    let defaults = try TemporaryDefaults.make(for: self).defaults
    defer { try? FileManager.default.removeItem(at: root) }
    let workshop = WorkshopStore(
      downloader: WorkshopDownloadManager(sessionDirectory: root), supportDirectory: root,
      defaults: defaults)
    let client = PanelUpdateClient()
    client.release = PanelUpdateClient.release(version: "1.1.0")
    let installer = PanelUpdateInstaller()
    let updater = AppUpdateStore(
      currentVersion: "1.0.0", client: client, installer: installer,
      workspace: AppUpdateWorkspace(
        archiveURL: { _, _ in root.appendingPathComponent("update.dmg") },
        reveal: { _ in }, open: { _ in }),
      scheduleInstall: { _ in }, terminate: {})
    let navigation = ControlPanelNavigation()
    let controller = WebPanelController(
      store: fixture.store, navigation: navigation, workshop: workshop, updater: updater,
      defaults: defaults,
      appLanguage: .english())
    let idle = try XCTUnwrap(controller.snapshot()["update"] as? [String: Any])
    XCTAssertEqual(idle["status"] as? String, "idle")
    XCTAssertEqual(idle["action"] as? String, "checkForUpdates")
    XCTAssertEqual(idle["showsAction"] as? Bool, true)

    navigation.revealSettingsSection(.about)
    XCTAssertEqual(controller.snapshot()["settingsSection"] as? String, "about")
    XCTAssertEqual(controller.snapshot()["settingsSectionToken"] as? Int, 1)

    await updater.checkForUpdates()
    let available = try XCTUnwrap(controller.snapshot()["update"] as? [String: Any])
    XCTAssertEqual(available["status"] as? String, "available")
    XCTAssertEqual(available["action"] as? String, "downloadUpdate")

    await updater.downloadUpdate()
    let ready = try XCTUnwrap(controller.snapshot()["update"] as? [String: Any])
    XCTAssertEqual(ready["status"] as? String, "ready")
    XCTAssertEqual(ready["action"] as? String, "installUpdate")
    XCTAssertEqual(ready["showsReveal"] as? Bool, true)

    try await controller.perform("installUpdate", body: ["action": "installUpdate"])
    XCTAssertEqual(
      updater.state, .ready(currentVersion: "1.0.0", availableVersion: "1.1.0"),
      "Install confirmation requires a window, so an offscreen panel must not replace the app")
    XCTAssertEqual(installer.installCalls, 0)
    await workshop.steamCMDSetup.shutdown()
  }

  func testAboutUpdateControlsCheckDownloadAndBlockInstallWithoutWindow() async throws {
    let fixture = makeStore()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "update-ui-\(UUID().uuidString)")
    let defaults = try TemporaryDefaults.make(for: self).defaults
    defer { try? FileManager.default.removeItem(at: root) }
    let workshop = WorkshopStore(
      downloader: WorkshopDownloadManager(sessionDirectory: root), supportDirectory: root,
      defaults: defaults)
    let client = PanelUpdateClient()
    let installer = PanelUpdateInstaller()
    let updater = AppUpdateStore(
      currentVersion: "1.0.0", client: client, installer: installer,
      workspace: AppUpdateWorkspace(
        archiveURL: { _, _ in root.appendingPathComponent("update.dmg") },
        reveal: { _ in }, open: { _ in }),
      scheduleInstall: { _ in }, terminate: {})
    let navigation = ControlPanelNavigation()
    let controller = WebPanelController(
      store: fixture.store, navigation: navigation, workshop: workshop, updater: updater,
      defaults: defaults,
      appLanguage: .english())
    let web = controller.makeWebView()
    defer { controller.stop() }
    web.setFrameSize(NSSize(width: 960, height: 640))
    let deadline = Date().addingTimeInterval(15)
    while !controller.isReady && Date() < deadline {
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertTrue(controller.isReady)
    guard controller.isReady else { return }
    try await finishWelcome(in: web)

    let noRelease = try await web.callAsyncJavaScript(
      """
      const waitFor = async predicate => {
        const deadline = Date.now() + 5000;
        while (!predicate()) {
          if (Date.now() > deadline) throw new Error('No-release update check did not settle');
          await new Promise(resolve => setTimeout(resolve, 20));
        }
      };
      window.wallpaperUI.receive(await window.webkit.messageHandlers.native.postMessage({action:'ready'}));
      document.querySelector('.tabs [data-page="settings"]').click();
      await waitFor(() => !document.getElementById('settings-content').hidden);
      document.querySelector('[data-section="about"]').click();
      const card = document.querySelector('[data-key="about-updates"]');
      card.querySelector('[data-action="checkForUpdates"]').click();
      await waitFor(() => card.getAttribute('aria-busy') === 'false'
        && card.querySelector('[data-action="checkForUpdates"]')?.disabled === false);
      const reply = await window.webkit.messageHandlers.native.postMessage({action:'ready'});
      return {status:reply.update.status,
        canCheckAgain:card.querySelector('[data-action="checkForUpdates"]').getClientRects().length > 0,
        offersInstall:!!card.querySelector('[data-action="downloadUpdate"], [data-action="installUpdate"]'),
        offersManualRecovery:!!card.querySelector('[data-action="openReleases"]')};
      """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
    XCTAssertEqual(noRelease?["status"] as? String, "noRelease")
    XCTAssertEqual(noRelease?["canCheckAgain"] as? Bool, true)
    XCTAssertEqual(noRelease?["offersInstall"] as? Bool, false)
    XCTAssertEqual(noRelease?["offersManualRecovery"] as? Bool, false)

    client.release = PanelUpdateClient.release(version: "1.1.0", notes: PanelUpdateClient.notesBody)
    let byTab =
      try await web.callAsyncJavaScript(
        """
        const waitFor = async predicate => {
          const deadline = Date.now() + 5000;
          while (!predicate()) {
            if (Date.now() > deadline) throw new Error('About updates did not settle');
            await new Promise(resolve => setTimeout(resolve, 20));
          }
        };
        window.wallpaperUI.receive(await window.webkit.messageHandlers.native.postMessage({action:'ready'}));
        document.querySelector('.tabs [data-page="settings"]').click();
        await waitFor(() => !document.getElementById('settings-content').hidden);
        document.querySelector('[data-section="about"]').click();
        await waitFor(() => !document.getElementById('settings-about').hidden);
        const appVersion = document.querySelector('[data-key="app-version"] .settings-version').textContent;
        const check = document.querySelector('[data-key="about-updates"] [data-action="checkForUpdates"]');
        if (!check) throw new Error('Check for Updates missing from Settings → About');
        check.click();
        await waitFor(() => document.querySelector('[data-key="about-updates"] [data-action="downloadUpdate"]'));
        document.querySelector('[data-key="about-updates"] [data-action="downloadUpdate"]').click();
        await waitFor(() => document.querySelector('[data-key="about-updates"] [data-action="installUpdate"]'));
        document.querySelector('[data-key="about-updates"] [data-action="installUpdate"]').click();
        const ready = await window.webkit.messageHandlers.native.postMessage({action:'ready'});
        document.querySelector('[data-section="general"]').click();
        await waitFor(() => !document.getElementById('settings-general').hidden);
        const notes = Array.from(document.querySelectorAll('[data-key="about-notes"] li')).map(node => node.textContent);
        const headings = Array.from(document.querySelectorAll('[data-key="about-notes"] h4')).map(node => node.textContent);
        const notesTitle = document.querySelector('[data-key="about-notes"] summary').textContent;
        return {status: ready.update.status, action: ready.update.action, notes, headings, notesTitle, appVersion};
        """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
    XCTAssertEqual(byTab?["status"] as? String, "ready")
    XCTAssertEqual(byTab?["action"] as? String, "installUpdate")
    XCTAssertEqual(client.fetchCalls, 2)
    XCTAssertEqual(client.downloadCalls, 1)
    XCTAssertEqual(installer.installCalls, 0)
    XCTAssertEqual(
      updater.state, .ready(currentVersion: "1.0.0", availableVersion: "1.1.0"))
    XCTAssertEqual(byTab?["notesTitle"] as? String, "What’s new in 1.1.0")
    XCTAssertEqual(byTab?["headings"] as? [String], ["Fixed"])
    XCTAssertEqual(
      byTab?["notes"] as? [String],
      ["scene — Stop a crash", "Plus 2 documentation, test and tooling commits."],
      "The card shows the release's own words and stops at the install footer")
    let bundleVersion = try XCTUnwrap(
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
    XCTAssertEqual(
      byTab?["appVersion"] as? String, bundleVersion,
      "About shows the version a GitHub report is filed with")

    navigation.revealSettingsSection(.about)
    let restored =
      try await web.callAsyncJavaScript(
        """
        const waitFor = async predicate => {
          const deadline = Date.now() + 5000;
          while (!predicate()) {
            if (Date.now() > deadline) throw new Error('Native About reveal did not settle');
            await new Promise(resolve => setTimeout(resolve, 20));
          }
        };
        window.wallpaperUI.receive(await window.webkit.messageHandlers.native.postMessage({action:'ready'}));
        await waitFor(() => !document.getElementById('settings-about').hidden
          && !!document.querySelector('[data-key="about-updates"] [data-action="installUpdate"]'));
        return !document.getElementById('settings-about').hidden;
        """, arguments: [:], in: nil, contentWorld: .page) as? Bool
    XCTAssertEqual(restored, true)
    XCTAssertNil(web.window, "This regression must not open a desktop window")
    await workshop.steamCMDSetup.shutdown()
  }

  func testAppearanceControlsPersistAndFollowNativeAppearanceWithoutWindow() async throws {
    let fixture = makeStore()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "theme-ui-\(UUID().uuidString)")
    let defaults = try TemporaryDefaults.make(for: self).defaults
    defer { try? FileManager.default.removeItem(at: root) }
    let theme = AppThemeStore(defaults: defaults)
    try theme.set("mode", value: "light")
    let workshop = WorkshopStore(
      downloader: WorkshopDownloadManager(sessionDirectory: root), supportDirectory: root,
      defaults: defaults)
    let controller = WebPanelController(
      store: fixture.store, navigation: ControlPanelNavigation(), workshop: workshop, theme: theme,
      defaults: defaults,
      appLanguage: .english())
    let web = controller.makeWebView()
    defer { controller.stop() }
    web.setFrameSize(NSSize(width: 760, height: 560))
    let deadline = Date().addingTimeInterval(15)
    while !controller.isReady && Date() < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertTrue(controller.isReady)
    guard controller.isReady else { return }
    try await finishWelcome(in: web)
    let resized = try await web.callAsyncJavaScript(
      """
      const deadline = Date.now() + 5000;
      while (Math.round(window.innerWidth) !== 760) {
        if (Date.now() > deadline) throw new Error('Panel resize did not settle');
        await new Promise(resolve => setTimeout(resolve, 20));
      }
      return true;
      """, arguments: [:], in: nil, contentWorld: .page) as? Bool
    XCTAssertEqual(resized, true)

    let interactions =
      try await web.callAsyncJavaScript(
        """
        const waitFor = async predicate => {
          const deadline = Date.now() + 5000;
          while (!predicate()) {
            if (Date.now() > deadline) throw new Error('Theme control did not settle');
            await new Promise(resolve => setTimeout(resolve, 20));
          }
        };
        const root = document.documentElement;
        const initialBackground = getComputedStyle(root).backgroundColor;
        document.querySelector('.tabs [data-page="settings"]').click();
        await waitFor(() => !document.getElementById('settings-content').hidden);
        document.querySelector('[data-section="appearance"]').click();
        const change = async (key, value) => {
          const input = document.querySelector(`[data-theme-setting="${key}"]`);
          await waitFor(() => !input.disabled);
          input.value = value;
          input.dispatchEvent(new Event('input', {bubbles:true}));
          input.dispatchEvent(new Event('change', {bubbles:true}));
          await waitFor(() => !input.disabled);
        };
        await change('mode', 'dark');
        await waitFor(() => root.dataset.theme === 'dark');
        const darkBackground = getComputedStyle(root).backgroundColor;
        await change('accent', '#b43271');
        await change('tone', 'warm');
        await waitFor(() => root.dataset.tone === 'warm');
        const night = document.querySelector('[data-theme-setting="icon"][value="night"]');
        night.click();
        await waitFor(() => !night.disabled && night.checked);
        await Promise.all(Array.from(document.querySelectorAll('.settings-icon-option img'), image => image.decode()));
        const saved = await window.webkit.messageHandlers.native.postMessage({action:'ready'});
        document.querySelector('[data-action="resetTheme"]').click();
        await waitFor(() => root.dataset.themeMode === 'system' && root.dataset.tone === 'neutral');
        const reset = await window.webkit.messageHandlers.native.postMessage({action:'ready'});
        return {initialBackground, darkBackground, saved:saved.theme, reset:reset.theme,
                resetIcon:document.querySelector('[data-theme-setting="icon"]:checked')?.value};
        """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
    XCTAssertEqual(interactions?["initialBackground"] as? String, "rgb(255, 255, 255)")
    XCTAssertNotEqual(interactions?["darkBackground"] as? String, "rgb(255, 255, 255)")
    let saved = interactions?["saved"] as? [String: Any]
    XCTAssertEqual(saved?["mode"] as? String, "dark")
    XCTAssertEqual(saved?["accent"] as? String, "#b43271")
    XCTAssertEqual(saved?["tone"] as? String, "warm")
    XCTAssertEqual(saved?["icon"] as? String, "night")
    let reset = interactions?["reset"] as? [String: Any]
    XCTAssertEqual(reset?["mode"] as? String, "system")
    XCTAssertEqual(reset?["tone"] as? String, "neutral")
    XCTAssertEqual(reset?["icon"] as? String, "day")
    XCTAssertEqual(interactions?["resetIcon"] as? String, "day")
    XCTAssertEqual(AppThemeStore(defaults: defaults).preferences, theme.preferences)

    // Override only this detached view to simulate live macOS appearance changes.
    // Never change NSApp appearance or the user's global system preference.
    for appearance in [NSAppearance.Name.darkAqua, .aqua] {
      web.appearance = NSAppearance(named: appearance)
      let expected = appearance == .darkAqua ? "dark" : "light"
      let resolved =
        try await web.callAsyncJavaScript(
          """
          const deadline = Date.now() + 5000;
          while (document.documentElement.dataset.theme !== expected) {
            if (Date.now() > deadline) throw new Error('System appearance was not followed');
            await new Promise(resolve => setTimeout(resolve, 20));
          }
          return getComputedStyle(document.documentElement).colorScheme;
          """, arguments: ["expected": expected], in: nil, contentWorld: .page) as? String
      XCTAssertEqual(resolved, expected)
    }
    try theme.set("mode", value: "light")
    web.appearance = NSAppearance(named: .darkAqua)
    let override =
      try await web.callAsyncJavaScript(
        """
        const deadline = Date.now() + 5000;
        while (document.documentElement.dataset.themeMode !== 'light'
               || !matchMedia('(prefers-color-scheme: dark)').matches) {
          if (Date.now() > deadline) throw new Error('Appearance override was not applied');
          await new Promise(resolve => setTimeout(resolve, 20));
        }
        return document.documentElement.dataset.theme;
        """, arguments: [:], in: nil, contentWorld: .page) as? String
    XCTAssertEqual(override, "light", "Explicit Light must win over a dark native appearance")
    try theme.set("accent", value: "#b43271")
    try theme.set("tone", value: "cool")
    try theme.set("icon", value: "minimal")
    controller.webViewWebContentProcessDidTerminate(web)
    let recoveryDeadline = Date().addingTimeInterval(15)
    while !controller.isReady && Date() < recoveryDeadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertTrue(controller.isReady)
    let recovered =
      try await web.callAsyncJavaScript(
        """
        return {mode:document.documentElement.dataset.theme,
                tone:document.documentElement.dataset.tone,
                accent:getComputedStyle(document.documentElement).getPropertyValue('--accent-base').trim(),
                icon:document.querySelector('[data-theme-setting="icon"]:checked')?.value};
        """, arguments: [:], in: nil, contentWorld: .page) as? [String: String]
    XCTAssertEqual(recovered?["mode"], "light")
    XCTAssertEqual(recovered?["tone"], "cool")
    XCTAssertEqual(recovered?["accent"], "#b43271")
    XCTAssertEqual(recovered?["icon"], "minimal")
    XCTAssertNil(web.window)
    await workshop.steamCMDSetup.shutdown()
  }

  func testTopBarCentersTheBrandAndOwnsTitleBarGesturesWithoutWindow()
    async throws
  {
    try await withPanel { panel in
      // The default window width; narrower panels hide the identity entirely.
      panel.web.setFrameSize(NSSize(width: 1240, height: 640))
      panel.show()
      try await panel.finishWelcome()
      try await panel.waitJS("Math.round(window.innerWidth) === 1240")
      try await panel.waitJS("document.querySelector('#app-identity .app-name') !== null")
      let link = try await panel.js("""
        const bar = document.querySelector('.topbar');
        const barRect = bar.getBoundingClientRect();
        const identity = document.getElementById('app-identity').getBoundingClientRect();
        return {
          inset: getComputedStyle(document.documentElement).getPropertyValue('--window-controls-inset').trim(),
          offCenter: Math.abs((identity.left + identity.right) / 2 - (barRect.left + barRect.right) / 2),
          title: bar.querySelector('.app-name').textContent,
          identityControls: document.querySelectorAll('#app-identity button, #app-identity a').length,
        };
        """) as? [String: Any]
      XCTAssertEqual(link?["identityControls"] as? Int, 0, "The brand shows no version or repository button")
      XCTAssertEqual(link?["inset"] as? String, "0px", "No window means no traffic lights to clear")
      XCTAssertLessThanOrEqual(
        link?["offCenter"] as? Double ?? .infinity, 1,
        "The product name must sit on the window's horizontal center, not after the tabs")
      XCTAssertEqual(link?["title"] as? String, "WallpaperMachine")
      XCTAssertEqual(panel.controller.windowControlsInset, 0)
      // Title-bar gestures reply without a snapshot and never fail when there is no window.
      for action in ["dragWindow", "titleDoubleClick"] {
        let reply = try await panel.js(
          "return await window.webkit.messageHandlers.native.postMessage({action:'\(action)'});")
        XCTAssertNil(reply, "\(action) must not push a state snapshot")
      }
      try await panel.expectJS(
        """
        const before = window.powerProbe.received.length;
        document.querySelector('.topbar').dispatchEvent(new MouseEvent('mousedown', {bubbles: true, button: 0}));
        document.getElementById('app-identity').dispatchEvent(new MouseEvent('mousedown', {bubbles: true, button: 0}));
        await new Promise(resolve => setTimeout(resolve, 150));
        return window.powerProbe.received.length - before;
        """, equals: 0)
      XCTAssertNil(panel.controller.actionError)
    }
  }

  func testTopBarNeverOverlapsAtTheMinimumWindowWidth() async throws {
    try await withPanel { panel in
      panel.show()
      try await panel.finishWelcome()
      try await panel.waitJS("document.querySelector('#app-identity .app-name') !== null")
      // From the minimum content width up to the default, with a download in flight so the queue button is present too.
      let widths: [Double] = [760, 840, 900, 1040, 1240]
      for width in widths {
        panel.web.setFrameSize(NSSize(width: width, height: 640))
        // The frame change reaches the page asynchronously. Measuring straight
        // after setting it reads the previous layout, which is why this only
        // ever failed on a busy machine and always by a whole reflow.
        try await panel.waitJS("Math.round(window.innerWidth) === \(Int(width))")
        let layout = try await panel.js("""
          const base = window.powerProbe.received.at(-1);
          const job = { id: 'bar-fixture', wallpaperID: 'bar-fixture', title: 'Bar fixture',
            status: 'Downloading Workshop files…', preview: null, thumbnail: null, account: 'fixture',
            progress: 0.5, pending: true, queued: false, bytesReceived: 1, bytesExpected: 2,
            bytesPerSecond: 1, authenticating: false, cancelled: false, error: null, prompt: null,
            securePrompt: false, challenge: null, warning: null };
          // A real window clears its traffic lights with the same inset the app reports.
          window.wallpaperUI.receive(Object.assign({}, base, { downloads: [job], downloadRequests: [], windowControlsInset: 70 }));
          const bar = document.querySelector('.topbar');
          const barRect = bar.getBoundingClientRect();
          const rect = element => element.getBoundingClientRect();
          const controls = [...bar.querySelectorAll('button, select')].filter(element => element.getClientRects().length);
          const overlaps = [];
          for (let i = 0; i < controls.length; i += 1) for (let j = i + 1; j < controls.length; j += 1) {
            const a = rect(controls[i]), b = rect(controls[j]);
            if (a.left < b.right - 0.5 && b.left < a.right - 0.5 && a.top < b.bottom - 0.5 && b.top < a.bottom - 0.5)
              overlaps.push(`${controls[i].textContent || controls[i].getAttribute('aria-label')} × ${controls[j].textContent || controls[j].getAttribute('aria-label')}`);
          }
          const outside = controls.filter(element => rect(element).left < barRect.left - 0.5 || rect(element).right > barRect.right + 0.5)
            .map(element => element.textContent || element.getAttribute('aria-label'));
          const name = document.querySelector('.app-name');
          return {
            width: barRect.width,
            overlaps, outside,
            queue: !!document.querySelector('#top-actions [data-action="openDownloads"]')?.getClientRects().length,
            nameVisible: !!name && name.getClientRects().length > 0,
          };
          """) as? [String: Any]
        XCTAssertEqual(layout?["width"] as? Double, width, "Top bar must span the panel at \(width)px")
        XCTAssertEqual(layout?["overlaps"] as? [String], [], "Top bar controls must not overlap at \(width)px")
        XCTAssertEqual(layout?["outside"] as? [String], [], "Top bar controls must stay inside the bar at \(width)px")
        XCTAssertEqual(layout?["queue"] as? Bool, true, "The downloads button stays available at \(width)px")
        XCTAssertEqual(
          layout?["nameVisible"] as? Bool, width > 840,
          "The name hides in a narrow window and returns once there is room (\(width)px)")
      }
    }
  }

  /// The first-run guide covers the whole window and walks six pages: language and appearance
  /// (applied at once, put back by Skip), Steam sign-in (a real sign-in-only session whose
  /// password prompt is answered from the form), performance and preferences (drafts committed
  /// by Continue), tips with the GitHub links, and the closing choice. It is shown on its own
  /// once per Mac and again from Settings.
  func testFirstRunGuideCoversTheWindowWalksSixPagesAndReturnsFromSettings() async throws {
    try await withPanel { panel in
      XCTAssertFalse(panel.controller.welcomeSeen, "A fresh install has not seen the guide")
      XCTAssertEqual(panel.controller.snapshot()["welcomeSeen"] as? Bool, false)
      panel.show()
      try await panel.waitJS("!document.getElementById('welcome').hidden && !!document.querySelector('#welcome .welcome-page')")
      let first = try await panel.js("""
        const region = document.getElementById('welcome');
        const rect = region.getBoundingClientRect();
        const style = getComputedStyle(region);
        return {
          step: region.querySelector('.welcome-page').dataset.step,
          covers: style.position === 'fixed' && rect.width === window.innerWidth && rect.height === window.innerHeight,
          background: style.backgroundColor,
          windowBackground: getComputedStyle(document.documentElement).backgroundColor,
          title: region.querySelector('#welcome-title').textContent,
          languages: [...region.querySelectorAll('[data-action="language"]')].map(b => b.dataset.value),
          themes: [...region.querySelectorAll('[data-action="theme"]')].map(b => b.dataset.value),
          checked: [...region.querySelectorAll('[aria-checked="true"]')].map(b => `${b.dataset.action}:${b.dataset.value}`),
          steps: region.querySelectorAll('.welcome-progress li').length,
          modal: document.querySelectorAll('dialog[open]').length,
          focusedTitle: document.activeElement === region.querySelector('#welcome-title'),
        };
        """) as? [String: Any]
      XCTAssertEqual(first?["step"] as? String, "language")
      XCTAssertEqual(first?["covers"] as? Bool, true, "The guide covers the whole window, top bar included")
      let background = first?["background"] as? String
      XCTAssertEqual(background, first?["windowBackground"] as? String, "The guide sits on the library's window surface")
      XCTAssertTrue(background?.hasPrefix("rgb(") == true, "The guide is opaque, never translucent: \(background ?? "nil")")
      XCTAssertEqual(first?["title"] as? String, "Welcome to WallpaperMachine")
      XCTAssertEqual(first?["languages"] as? [String], ["system"] + AppLanguage.supported.map(\.tag))
      XCTAssertEqual(first?["themes"] as? [String], ["system", "light", "dark"])
      XCTAssertEqual(first?["checked"] as? [String], ["language:system", "theme:system"], "Defaults are selected")
      XCTAssertEqual(first?["steps"] as? Int, 6)
      XCTAssertEqual(first?["modal"] as? Int, 0, "The guide is a page, not a modal dialog")
      XCTAssertEqual(first?["focusedTitle"] as? Bool, true, "Focus lands on the page title")

      // A choice applies at once; Skip puts the opening values back and moves on.
      _ = try await panel.js("document.querySelector('#welcome [data-action=\"theme\"][data-value=\"dark\"]').click();")
      try await panel.waitUntil { panel.theme.preferences.mode == .dark }
      try await panel.waitJS("document.documentElement.dataset.themeMode === 'dark' && document.querySelector('#welcome [data-action=\"theme\"][data-value=\"dark\"]').getAttribute('aria-checked') === 'true'")
      _ = try await panel.js("document.querySelector('#welcome [data-action=\"skipLanguage\"]').click();")
      try await panel.waitUntil { panel.theme.preferences.mode == .system }
      try await panel.waitJS("document.querySelector('#welcome .welcome-page')?.dataset.step === 'steam'")

      // Steam: the two links the requirement implies, plain validation, then a real sign-in.
      //
      // Settle first. The count below is latched and then read 50 ms later, so
      // a snapshot already in flight when it was latched lands inside that
      // window and is indistinguishable from one the submit caused — which is
      // what made this assertion fail whenever the machine was busy enough to
      // delay an unrelated push into it.
      try await panel.quiet()
      let steam = try await panel.js("""
        const region = document.getElementById('welcome');
        const links = [...region.querySelectorAll('.welcome-steam-links [data-action="openExternal"]')].map(link => link.dataset.url);
        const before = window.powerProbe.received.length;
        region.querySelector('form[data-form="signIn"]').requestSubmit();
        await new Promise(resolve => setTimeout(resolve, 50));
        return {
          links,
          fields: ['welcome-account', 'welcome-password'].map(id => document.getElementById(id)?.type),
          remember: region.querySelector('input[name="remember"]').checked,
          error: region.querySelector('form .notice.error')?.textContent || '',
          snapshots: window.powerProbe.received.length - before,
          skip: !!region.querySelector('[data-action="skipSteam"]'),
        };
        """) as? [String: Any]
      let links = try XCTUnwrap(steam?["links"] as? [String])
      XCTAssertEqual(links.count, 2, "Register and buy: the two links the Steam requirement implies")
      for link in links {
        let url = try XCTUnwrap(URL(string: link))
        XCTAssertTrue(WebPanelController.allowedExternalURL(url), "\(link) must pass the external allowlist")
      }
      XCTAssertTrue(links.contains { $0.contains("/join") }, "One link registers a Steam account")
      XCTAssertTrue(links.contains { $0.contains("/app/431960") }, "One link buys Wallpaper Engine")
      XCTAssertEqual(steam?["fields"] as? [String], ["text", "password"])
      XCTAssertEqual(steam?["remember"] as? Bool, true, "Keep me signed in is on by default")
      XCTAssertFalse((steam?["error"] as? String ?? "").isEmpty, "An empty account is refused before anything reaches native")
      XCTAssertEqual(steam?["snapshots"] as? Int, 0)
      XCTAssertEqual(steam?["skip"] as? Bool, true, "Signing in is optional")

      panel.workshop.steamCMDSetup.selectExisting(at: panel.executable)
      try await panel.waitUntil(timeout: 5) { panel.workshop.steamCMDSetup.selectedRuntime != nil }
      try await panel.waitJS("document.querySelector('#welcome form[data-form=\"signIn\"] button[type=\"submit\"] .button-label')?.textContent === 'Sign in'")
      _ = try await panel.js("""
        const region = document.getElementById('welcome');
        const account = region.querySelector('#welcome-account');
        account.value = 'LocalTest';
        account.dispatchEvent(new Event('input', { bubbles: true }));
        region.querySelector('#welcome-password').value = 'hunter2-secret';
        region.querySelector('form[data-form="signIn"]').requestSubmit();
        """)
      let job = try await panel.waitForSignIn()
      try await panel.waitUntil(timeout: 10) { !job.isPending }
      XCTAssertNil(job.errorMessage, "The sign-in-only session succeeds")
      XCTAssertTrue(
        try String(contentsOf: panel.root.appendingPathComponent("password"), encoding: .utf8) == "hunter2-secret",
        "The password typed into the guide answers Steam's own prompt")
      try await panel.waitJS("!!document.querySelector('#welcome .welcome-status.success')")
      let signedIn = try await panel.js("""
        const region = document.getElementById('welcome');
        return {
          title: region.querySelector('.welcome-status.success .welcome-status-title').textContent,
          dialog: document.querySelectorAll('dialog[open]').length,
          passwordField: !!document.getElementById('welcome-password'),
          continueLabel: region.querySelector('.welcome-footer .primary .button-label')?.textContent,
          queue: !!document.querySelector('#top-actions [data-action="openDownloads"]'),
        };
        """) as? [String: Any]
      XCTAssertEqual(signedIn?["title"] as? String, "Signed in as localtest")
      XCTAssertEqual(signedIn?["dialog"] as? Int, 0, "The guide answers the prompt itself; the download dialog stays closed")
      XCTAssertEqual(signedIn?["passwordField"] as? Bool, false, "The password field is gone with the form")
      XCTAssertEqual(signedIn?["continueLabel"] as? String, "Continue")
      XCTAssertEqual(signedIn?["queue"] as? Bool, false, "A finished sign-in is not listed as a download")

      // Performance comes before the preferences. High is the default: no limit, so every display
      // runs at its own frame rate. Presets and the slider are drafts until Continue.
      _ = try await panel.js("document.querySelector('#welcome [data-action=\"continue\"]').click();")
      try await panel.waitJS("document.querySelector('#welcome .welcome-page')?.dataset.step === 'performance'")
      panel.bridge.bundleProvider = {
        BridgeSnapshotBundle(
          app: panel.store.appSnapshot, library: panel.store.librarySnapshot, wallpaperOptions: nil,
          monitorInformation: panel.store.monitorInformationSnapshot, settings: panel.store.settingsSnapshot)
      }
      let performance = try await panel.js("""
        const region = document.getElementById('welcome');
        const read = () => ({
          checked: [...region.querySelectorAll('[data-action="preset"][aria-checked="true"]')].map(b => b.dataset.value),
          readout: region.querySelector('[data-performance-readout]').textContent,
        });
        const initial = read();
        region.querySelector('[data-action="preset"][data-value="low"]').click();
        const low = read();
        const slider = region.querySelector('input[data-performance="frameRateCap"]');
        slider.value = String(Number(slider.max) - 1);
        slider.dispatchEvent(new Event('input', { bubbles: true }));
        const refresh = read();
        slider.value = '24';
        slider.dispatchEvent(new Event('change', { bubbles: true }));
        return { initial, low, refresh, custom: read() };
        """) as? [String: [String: Any]]
      XCTAssertEqual(performance?["refresh"]?["readout"] as? String, "60 fps",
        "The display's full refresh is a cap of its own, below No limit")
      XCTAssertEqual(performance?["initial"]?["checked"] as? [String], ["high"])
      XCTAssertEqual(performance?["initial"]?["readout"] as? String, "No limit")
      XCTAssertEqual(performance?["low"]?["checked"] as? [String], ["low"])
      XCTAssertEqual(performance?["low"]?["readout"] as? String, "30 fps")
      XCTAssertEqual(performance?["custom"]?["checked"] as? [String], [], "A limit no preset uses is Custom")
      XCTAssertEqual(performance?["custom"]?["readout"] as? String, "24 fps")
      XCTAssertEqual(panel.bridge.frameRateCapCalls, [], "Choosing a preset or a limit is a draft")
      XCTAssertEqual(panel.bridge.renderScaleCalls, [])
      _ = try await panel.js("document.querySelector('#welcome [data-action=\"savePerformance\"]').click();")
      try await panel.waitJS("document.querySelector('#welcome .welcome-page')?.dataset.step === 'preferences'")
      XCTAssertEqual(panel.bridge.renderScaleCalls, [0.5], "The Low preset's render scale is kept")
      XCTAssertEqual(panel.bridge.frameRateCapCalls, [24], "The slider replaces the preset's limit")

      // Preferences are drafts: nothing reaches native until Continue.
      let preferences = try await panel.js("""
        const region = document.getElementById('welcome');
        const select = region.querySelector('select[data-pref="batteryMode"]');
        select.value = 'pause';
        select.dispatchEvent(new Event('change', { bubbles: true }));
        await new Promise(resolve => setTimeout(resolve, 30));
        return { prefs: region.querySelectorAll('[data-pref]').length, value: select.value };
        """) as? [String: Any]
      // Launch at login, On battery, Keep windows in place and Send performance data.
      XCTAssertEqual(preferences?["prefs"] as? Int, 4)
      XCTAssertEqual(preferences?["value"] as? String, "pause")
      XCTAssertEqual(panel.bridge.batteryModeCalls, [], "Changing the menu is a draft")

      // The lock screen is off by default and, unlike the drafts, applies at once. This fixture
      // has no lock-screen service, so native refuses: the switch stays off and the reason shows.
      let lock = try await panel.js("""
        const region = document.getElementById('welcome');
        const input = () => region.querySelector('input[data-lock-screen]');
        const unavailable = { checked: input().checked, disabled: input().disabled };
        const base = window.powerProbe.received.at(-1);
        window.wallpaperUI.receive({...base, settings: {...base.settings, lockScreenAvailable: true, lockScreenStatus: 'Off', lockScreenEnabled: false, lockScreenBusy: false}});
        input().click();
        const deadline = Date.now() + 5000;
        while (!region.querySelector('.notice.error') && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 20));
        return { unavailable, checked: input().checked, error: region.querySelector('.notice.error')?.textContent || '' };
        """) as? [String: Any]
      XCTAssertEqual(lock?["unavailable"] as? [String: Bool], ["checked": false, "disabled": true])
      XCTAssertEqual(lock?["checked"] as? Bool, false, "A refused change does not leave the switch on")
      XCTAssertFalse((lock?["error"] as? String ?? "").isEmpty, "The refusal is shown on the page")
      XCTAssertEqual(panel.bridge.batteryModeCalls, [], "Applying the lock screen does not commit the drafts")
      _ = try await panel.js("document.querySelector('#welcome [data-action=\"savePreferences\"]').click();")
      try await panel.waitUntil { panel.bridge.batteryModeCalls == [.pause] }
      try await panel.waitJS("document.querySelector('#welcome .welcome-page')?.dataset.step === 'tips'")

      // Tips: three lines, then the compatibility note with its GitHub links through the same allowlist as every other link.
      let tips = try await panel.js("""
        const region = document.getElementById('welcome');
        const github = [...region.querySelectorAll('.welcome-support [data-action="openExternal"]')].map(link => link.dataset.url);
        return { tips: region.querySelectorAll('.welcome-tips li').length, github };
        """) as? [String: Any]
      _ = try await panel.js("document.querySelector('#welcome [data-action=\"continue\"]').click();")
      try await panel.waitJS("document.querySelector('#welcome .welcome-page')?.dataset.step === 'start'")
      let start = try await panel.js("""
        const region = document.getElementById('welcome');
        return { step: region.querySelector('.welcome-page').dataset.step, recap: [...region.querySelectorAll('.welcome-recap dd')].map(node => node.textContent) };
        """) as? [String: Any]
      XCTAssertEqual(tips?["tips"] as? Int, 3)
      let github = try XCTUnwrap(tips?["github"] as? [String])
      XCTAssertEqual(github.count, 2, "Issue tracker and repository")
      for link in github {
        let url = try XCTUnwrap(URL(string: link))
        XCTAssertEqual(url.host, "github.com", link)
        XCTAssertTrue(WebPanelController.allowedExternalURL(url), "\(link) must pass the external allowlist")
      }
      XCTAssertEqual(start?["step"] as? String, "start")
      XCTAssertEqual(start?["recap"] as? [String], ["System (Auto)", "System (Auto)", "Signed in as localtest"])

      // The closing choice puts the guide away, tells native, and lands on Discover.
      _ = try await panel.js("document.querySelector('#welcome [data-action=\"browse\"]').click();")
      try await panel.waitUntil { panel.controller.welcomeSeen && panel.navigation.selection == .workshop }
      XCTAssertTrue(panel.defaults.bool(forKey: WebPanelController.welcomeSeenKey), "The choice is stored")
      try await panel.waitJS("document.getElementById('welcome').hidden")
      try await panel.quiet()
      try await panel.expectJS(
        """
        const base = window.powerProbe.received.at(-1);
        window.wallpaperUI.receive(Object.assign({}, base, { welcomeSeen: true }));
        return document.getElementById('welcome').hidden;
        """, equals: true)
      XCTAssertNil(panel.controller.actionError)

      // A relaunch with the same defaults never shows it on its own again.
      let relaunched = WebPanelController(
        store: panel.store, navigation: ControlPanelNavigation(), workshop: panel.workshop,
        theme: panel.theme, defaults: panel.defaults, appLanguage: .english())
      XCTAssertTrue(relaunched.welcomeSeen)
      XCTAssertEqual(relaunched.snapshot()["welcomeSeen"] as? Bool, true)

      // Settings → Library & Steam brings it back from the first page; finishing it then asks native nothing.
      let replay = try await panel.js("""
        const base = window.powerProbe.received.at(-1);
        window.wallpaperUI.receive(Object.assign({}, base, { page: 'settings', welcomeSeen: true }));
        document.querySelector('#settings-content [data-section="library"]').click();
        const button = document.querySelector('#settings-content [data-action="openWelcome"]');
        const bridge = window.webkit.messageHandlers.native;
        const original = bridge.postMessage;
        const actions = [];
        bridge.postMessage = message => { actions.push(message.action); return original.call(bridge, message); };
        try {
          button.click();
          const region = document.getElementById('welcome');
          const reopened = !region.hidden && region.querySelector('.welcome-page').dataset.step === 'language';
          const before = window.powerProbe.received.length;
          region.querySelector('[data-action="go"][data-step="5"]').click();
          const last = region.querySelector('.welcome-page').dataset.step;
          region.querySelector('[data-action="finish"]').click();
          // Native can publish an unrelated background snapshot at any time. It must not
          // reopen the guide, and is not evidence that closing it sent another request.
          window.wallpaperUI.receive(Object.assign({}, window.powerProbe.received.at(-1), { welcomeSeen: true }));
          await new Promise(resolve => setTimeout(resolve, 0));
          return { hasButton: !!button, reopened, last, closed: region.hidden, actions, snapshots: window.powerProbe.received.length - before };
        } finally { bridge.postMessage = original; }
        """) as? [String: Any]
      XCTAssertEqual(replay?["hasButton"] as? Bool, true, "Library & Steam offers the guide again")
      XCTAssertEqual(replay?["reopened"] as? Bool, true)
      XCTAssertEqual(replay?["last"] as? String, "start", "The step indicator jumps between pages")
      XCTAssertEqual(replay?["closed"] as? Bool, true)
      XCTAssertGreaterThanOrEqual(replay?["snapshots"] as? Int ?? 0, 1, "The replay tolerates unsolicited native snapshots")
      XCTAssertEqual(replay?["actions"] as? [String], [], "An already-seen guide closes without another native request")
    }
  }

  func testNarrowSettingsKeepLongControlsAndReportsInsideTheViewport() async throws {
    try await withPanel { panel in
      try await panel.finishWelcome()
      panel.web.setFrameSize(NSSize(width: 760, height: 560))
      try await panel.waitJS("Math.round(window.innerWidth) === 760")
      let result = try await panel.js("""
        const base = await window.webkit.messageHandlers.native.postMessage({action:'ready'});
        const long = 'External studio display with a detailed compatibility explanation '.repeat(8);
        const settings = {...base.settings, videoBackend:'native_preferred', sceneRenderer:'native_metal_preferred',
          videoBackends:[{displayId:'primary', displayName:long, wallpaperTitle:long, backend:'Compatibility', fallbackReason:long}],
          sceneRenderers:[{displayId:'primary', display:long, wallpaperTitle:long, backend:'legacy_vulkan', fallbackReason:long}]};
        const displays = [{...base.displays[0], id:'secondary', title:long, enabled:true, mode:'mirror',
          mirrorTarget:'primary', mirrorTargets:[{id:'primary', title:long}]}];
        window.wallpaperUI.receive({...base, page:'settings', settings, displays});
        const failures = [];
        for (const section of ['performance', 'displays']) {
          document.querySelector(`[data-section="${section}"]`).click();
          const page = document.getElementById(`settings-${section}`);
          const scroll = document.querySelector('.settings-scroll');
          for (const node of page.querySelectorAll('select, .settings-label, .settings-note, .settings-list')) {
            if (!node.getClientRects().length) continue;
            const rect = node.getBoundingClientRect();
            if (rect.left < -1 || rect.right > window.innerWidth + 1)
              failures.push(section + ':' + node.tagName);
          }
          if (scroll.scrollWidth > scroll.clientWidth + 1 || document.documentElement.scrollWidth > window.innerWidth + 1)
            failures.push(section + ':horizontal-scroll');
        }
        return failures;
        """) as? [String]
      XCTAssertEqual(result, [], "Long selected options, labels and live reports must wrap within the minimum panel width")
    }
  }

  /// A scene whose renderer stopped after a failure is not paused and not still
  /// starting, even when it never drew a first frame: both of those would send the
  /// user looking for something they did not do. It is also the one reading with
  /// something to do about it, so it, and only it, offers Retry.
  func testASceneThatStoppedAfterAFailureIsNeverWordedAsAPauseOrAsStarting() async throws {
    try await withPanel { panel in
      try await panel.finishWelcome()
      let lines = try await panel.js("""
        const base = await window.webkit.messageHandlers.native.postMessage({action:'ready'});
        const report = (displayId, mode, reasons) => ({displayId, display:`Display ${displayId}`,
          wallpaperId:`w${displayId}`, wallpaperTitle:`Wallpaper ${displayId}`, mode, reasons});
        window.wallpaperUI.receive({...base, page:'settings', settings:{...base.settings, sceneUpdateModes:[
          report(1, 'stopped_after_failure', ['no_frame_yet']),
          report(2, 'stopped_after_failure', ['video']),
          report(3, 'user_paused', []),
          report(4, 'continuous', ['no_frame_yet']),
        ]}});
        document.querySelector('[data-section="performance"]').click();
        return [...document.querySelectorAll('[data-key="scene-update-report"] li')].map(item => ({
          text: [...item.childNodes].filter(node => node.nodeType === Node.TEXT_NODE).map(node => node.textContent).join('').trim(),
          retry: [...item.querySelectorAll('button')].map(button => `${button.dataset.action} ${button.dataset.args}`),
        }));
        """) as? [[String: Any]]

      let rows = try XCTUnwrap(lines)
      XCTAssertEqual(rows.count, 4)
      let text = rows.map { $0["text"] as? String ?? "" }
      XCTAssertEqual(
        text[0], "Display 1 — Wallpaper 1: stopped after a rendering failure",
        "A scene that failed before its first frame is stopped, not starting")
      XCTAssertEqual(
        text[1], "Display 2 — Wallpaper 2: stopped after a rendering failure",
        "Why the clock was needed is moot once the scene has stopped")
      XCTAssertTrue(text[2].hasSuffix("paused by you"), text[2])
      XCTAssertTrue(
        text[3].hasSuffix("starting — no frame drawn yet"),
        "A scene that is genuinely starting keeps its own wording: \(text[3])")
      XCTAssertEqual(
        rows.map { $0["retry"] as? [String] },
        [[#"sceneRetry {"displayId":1}"#], [#"sceneRetry {"displayId":2}"#], [], []],
        "Both stopped scenes, including the one that never drew, offer Retry for their own display; a pause or a start is not a fault to retry")
    }
  }

  func testSettingsSnapshotPreservesActiveDraftDisclosureAndScroll() async throws {
    try await withPanel { panel in
      try await panel.finishWelcome()
      panel.web.setFrameSize(NSSize(width: 760, height: 560))
      try await panel.waitJS("Math.round(window.innerWidth) === 760")
      let result = try await panel.js("""
        const base = await window.webkit.messageHandlers.native.postMessage({action:'ready'});
        const state = {...base, page:'settings', settings:{...base.settings, batteryMode:'reducedQuality', batteryTargetFps:30}};
        window.wallpaperUI.receive(state);
        document.querySelector('[data-section="performance"]').click();
        const details = document.querySelector('[data-key="performance-context"]');
        details.querySelector('summary').click();
        const input = document.querySelector('[data-setting="batteryTargetFps"]');
        input.focus();
        input.value = '47';
        input.dispatchEvent(new Event('input', {bubbles:true}));
        const scroll = document.querySelector('.settings-scroll');
        scroll.scrollTop = Math.min(120, scroll.scrollHeight - scroll.clientHeight);
        const before = scroll.scrollTop;
        window.wallpaperUI.receive({...state, settings:{...state.settings, batteryTargetFps:24, onBatteryPower:true}});
        return {focused:document.activeElement === input, value:input.value,
          disclosure:document.querySelector('[data-key="performance-context"]').open,
          scrolled:before > 0, scrollKept:Math.abs(scroll.scrollTop - before) < 1};
        """) as? [String: Any]
      XCTAssertEqual(result?["focused"] as? Bool, true)
      XCTAssertEqual(result?["value"] as? String, "47", "A live report must not replace the user's unsaved numeric input")
      XCTAssertEqual(result?["disclosure"] as? Bool, true)
      XCTAssertEqual(result?["scrolled"] as? Bool, true)
      XCTAssertEqual(result?["scrollKept"] as? Bool, true)
    }
  }

  /// Reduced quality for Low Power Mode, a hot Mac and a low battery shares the battery profile's
  /// scale and frame rate, so those rows follow any of the four choices, and the page names the
  /// reason the quality is lower: heat first, then Low Power Mode, a low battery and the battery.
  func testReducedQualityShowsItsProfileAndNamesItsCause() async throws {
    try await withPanel { panel in
      try await panel.finishWelcome()
      let result = try await panel.js("""
        const base = await window.webkit.messageHandlers.native.postMessage({action:'ready'});
        const quiet = {...base.settings, renderScaleSupported:true, renderScale:0.75, preferredRenderScale:1,
          batteryMode:'keepRunning', lowPowerModeAction:'keepRunning', thermalAction:'keepRunning',
          lowBatteryAction:'keepRunning', batteryPercent:null, onBatteryPower:false, qualityThrottle:[]};
        window.wallpaperUI.receive({...base, page:'settings', settings:quiet});
        document.querySelector('[data-section="performance"]').click();
        const look = overrides => {
          window.wallpaperUI.receive({...base, page:'settings', settings:{...quiet, ...overrides}});
          const key = name => document.querySelector(`[data-key="${name}"]`);
          return {
            profile: Boolean(key('battery-scale')) && Boolean(key('battery-fps')) && Boolean(document.querySelector('[data-setting="batteryTargetFps"]')),
            cause: key('reduced-quality-state') ? key('reduced-quality-state').querySelector('.settings-status').dataset.cause : null,
            status: key('reduced-quality-state')?.querySelector('.settings-status').textContent ?? null,
            effective: key('render-scale-effective')?.querySelector('.settings-status').textContent ?? null,
            thermalNote: document.getElementById('settings-note-thermal')?.textContent ?? null,
          };
        };
        const offered = name => [...document.querySelectorAll(`select[data-setting="${name}"] option`)].map(option => option.value);
        const out = {
          none: look({}),
          batteryMode: look({batteryMode:'reducedQuality'}),
          lowPowerChosen: look({lowPowerModeAction:'reduceQuality'}),
          heatChosen: look({thermalAction:'reduceQuality'}),
          lowBatteryChosenWithoutABattery: look({lowBatteryAction:'reduceQuality'}),
          lowBatteryChosen: look({lowBatteryAction:'reduceQuality', batteryPercent:50}),
          heat: look({thermalAction:'reduceQuality', qualityThrottle:['heat']}),
          lowPower: look({lowPowerModeAction:'reduceQuality', qualityThrottle:['lowPowerMode']}),
          lowBattery: look({lowBatteryAction:'reduceQuality', batteryPercent:10, qualityThrottle:['lowBattery']}),
          battery: look({batteryMode:'reducedQuality', onBatteryPower:true}),
          heatAndLowPower: look({thermalAction:'reduceQuality', lowPowerModeAction:'reduceQuality', qualityThrottle:['lowPowerMode', 'heat']}),
          heatAndBattery: look({thermalAction:'reduceQuality', batteryMode:'reducedQuality', onBatteryPower:true, qualityThrottle:['heat']}),
        };
        window.wallpaperUI.receive({...base, page:'settings', settings:{...quiet, batteryPercent:50}});
        out.offered = {lowPowerModeAction:offered('lowPowerModeAction'), thermalAction:offered('thermalAction'),
          lowBatteryAction:offered('lowBatteryAction'), batteryMode:offered('batteryMode'), displaySleepAction:offered('displaySleepAction')};
        return out;
        """) as? [String: Any]

      let cases = try XCTUnwrap(result)
      func look(_ name: String) throws -> [String: Any] {
        try XCTUnwrap(cases[name] as? [String: Any], name)
      }
      XCTAssertEqual(try look("none")["profile"] as? Bool, false, "No reduced choice, no profile to edit")
      XCTAssertNil(try look("none")["status"] as? String)
      for name in ["batteryMode", "lowPowerChosen", "heatChosen", "lowBatteryChosen"] {
        XCTAssertEqual(try look(name)["profile"] as? Bool, true, "\(name) chose Reduced quality")
      }
      XCTAssertEqual(
        try look("lowBatteryChosenWithoutABattery")["profile"] as? Bool, false,
        "A Mac without a battery never shows the low-battery choice, so it cannot ask for the profile")

      // Chosen but nothing holds: the generic reading, and the scale is not claimed as reduced.
      XCTAssertEqual(try look("heatChosen")["cause"] as? String, "")
      XCTAssertEqual(try look("heat")["cause"] as? String, "heat")
      XCTAssertEqual(try look("lowPower")["cause"] as? String, "lowPowerMode")
      XCTAssertEqual(try look("lowBattery")["cause"] as? String, "lowBattery")
      XCTAssertEqual(try look("battery")["cause"] as? String, "battery")
      XCTAssertEqual(try look("heatAndLowPower")["cause"] as? String, "heat", "Heat is named before Low Power Mode")
      XCTAssertEqual(try look("heatAndBattery")["cause"] as? String, "heat", "A throttle is named before the battery")

      // Effective now fills the engine's scale and the saved one into whichever sentence names the
      // cause, so a reading with a placeholder left in it or a missing value is the failure.
      for name in ["heatChosen", "heat", "lowPower", "lowBattery", "battery"] {
        let text = try XCTUnwrap(
          try look(name)["effective"] as? String, "Effective now is shown while 75% differs from 100%")
        XCTAssertTrue(text.contains("75%") && text.contains("100%"), text)
        XCTAssertFalse(text.contains("{"), "\(name) left a placeholder unfilled: \(text)")
        XCTAssertFalse(
          try XCTUnwrap(try look(name)["status"] as? String, name).isEmpty, "\(name) says nothing about the quality in use")
      }
      for name in ["none", "heatChosen"] {
        let note = try XCTUnwrap(try look(name)["thermalNote"] as? String, "\(name) shows the note for the heat row")
        XCTAssertFalse(note.contains("{"), "\(name) left a placeholder unfilled: \(note)")
      }

      let offered = try XCTUnwrap(cases["offered"] as? [String: [String]])
      for name in ["lowPowerModeAction", "thermalAction", "lowBatteryAction"] {
        XCTAssertEqual(offered[name], ["keepRunning", "reduceQuality", "pause", "stop"], name)
      }
      XCTAssertEqual(
        offered["batteryMode"], ["keepRunning", "reducedQuality", "pause"],
        "The battery mode keeps its own name")
      XCTAssertEqual(offered["displaySleepAction"], ["pause", "stop"])
    }
  }

  /// A display's frame rate is held to the ceiling the engine reports, whatever lowered it, so the
  /// note appears for a throttle as it did for the battery profile.
  func testDisplayFrameRateNoteCountsTheThrottle() async throws {
    try await withPanel { panel in
      try await panel.finishWelcome()
      let result = try await panel.js("""
        const base = await window.webkit.messageHandlers.native.postMessage({action:'ready'});
        const displays = [{...base.displays[0], id:'primary', enabled:true, fps:30, maxFps:60}];
        const look = overrides => {
          window.wallpaperUI.receive({...base, page:'settings', displays, settings:{...base.settings, ...overrides}});
          return document.querySelector('[data-key="display-primary-fps-limit"]')?.textContent ?? null;
        };
        window.wallpaperUI.receive({...base, page:'settings', displays, settings:base.settings});
        document.querySelector('[data-section="displays"]').click();
        return {
          unlimited: look({frameRateCap:null, effectiveFrameRateCap:null}),
          below: look({frameRateCap:null, effectiveFrameRateCap:24, qualityThrottle:['heat']}),
          equal: look({frameRateCap:null, effectiveFrameRateCap:30}),
          above: look({frameRateCap:null, effectiveFrameRateCap:45}),
          battery: look({frameRateCap:null, effectiveFrameRateCap:20, batteryMode:'reducedQuality', onBatteryPower:true}),
        };
        """) as? [String: Any]

      let notes = try XCTUnwrap(result)
      XCTAssertTrue(notes["unlimited"] is NSNull, "No ceiling, no note")
      XCTAssertTrue(notes["equal"] is NSNull, "A ceiling that does not lower the rate is not a limit")
      XCTAssertTrue(notes["above"] is NSNull)
      XCTAssertTrue((notes["below"] as? String)?.contains("24") == true, "\(String(describing: notes["below"]))")
      XCTAssertTrue(
        (notes["battery"] as? String)?.contains("20") == true,
        "The battery profile reaches the page through the same ceiling")
    }
  }

  /// A <select> yields a string, and Swift accepts only an integer in range, so the choice must
  /// cross the bridge as a number to reach the queue at all.
  func testDownloadsAtOnceChoiceReachesTheQueueAndSurvivesTheNextSnapshot() async throws {
    try await withPanel { panel in
      try await panel.finishWelcome()
      _ = try await panel.js("""
        const base = await window.webkit.messageHandlers.native.postMessage({action:'ready'});
        window.wallpaperUI.receive({...base, page:'settings'});
        document.querySelector('[data-section="library"]').click();
        const select = document.querySelector('[data-setting="concurrentDownloads"]');
        select.value = '5';
        select.dispatchEvent(new Event('change', {bubbles:true}));
        """)
      try await panel.waitUntil { panel.workshop.downloader.maximumConcurrentDownloads == 5 }
      XCTAssertEqual(panel.workshop.downloader.slotLimit, 5)
      try await panel.expectJS("""
        const base = await window.webkit.messageHandlers.native.postMessage({action:'ready'});
        window.wallpaperUI.receive({...base, page:'settings'});
        const select = document.querySelector('[data-setting="concurrentDownloads"]');
        return `${select.value}/${select.options.length}`;
        """, equals: "5/\(WorkshopDownloadManager.concurrentDownloadRange.upperBound)")
    }
  }

  func testSamePageSnapshotPreservesSearchDraftAndCaret() async throws {
    try await withPanel { panel in
      try await panel.finishWelcome()
      let result = try await panel.js("""
        const base = await window.webkit.messageHandlers.native.postMessage({action:'navigate', page:'installed'});
        window.wallpaperUI.receive(base);
        const input = document.getElementById('wallpaper-search');
        input.focus();
        input.value = 'unfinished search draft';
        input.setSelectionRange(3, 11, 'backward');
        input.dispatchEvent(new Event('input', {bubbles:true}));
        window.wallpaperUI.receive({...base, paused:!base.paused});
        const current = document.getElementById('wallpaper-search');
        return {focused:document.activeElement === current, value:current.value,
          start:current.selectionStart, end:current.selectionEnd, direction:current.selectionDirection};
        """) as? [String: Any]
      XCTAssertEqual(result?["focused"] as? Bool, true)
      XCTAssertEqual(result?["value"] as? String, "unfinished search draft")
      XCTAssertEqual(result?["start"] as? Int, 3)
      XCTAssertEqual(result?["end"] as? Int, 11)
      XCTAssertEqual(result?["direction"] as? String, "backward")
    }
  }

  /// Closing the panel releases its page, yet Installed's search, sort, boxes and scroll position
  /// come back when it is reopened: the page reports them, native keeps the last valid report on
  /// the navigation that outlives the window, and the next page restores them from the reply to
  /// its first `ready`. A required tag that nothing in the library carries any more is dropped,
  /// while a hidden type stays hidden.
  func testInstalledFiltersAndScrollComeBackWhenThePanelIsReopened() async throws {
    let fixture = makeStore()
    let entries = (0..<80).map { index in
      BridgeWallpaperEntry(
        id: "wallpaper-\(index)", title: String(format: "Wallpaper %02d", index),
        kind: index.isMultiple(of: 2) ? .projectScene : .video, supported: true, active: false,
        selected: false, previewPath: nil)
    }
    fixture.store.librarySnapshot.wallpapers = entries
    // A finished library load: the page keeps a restored tag while the library is loading.
    fixture.bridge.snapshot = BridgeSnapshotBundle(
      app: fixture.store.appSnapshot, library: fixture.store.librarySnapshot,
      wallpaperOptions: nil, monitorInformation: fixture.store.monitorInformationSnapshot,
      settings: fixture.store.settingsSnapshot)
    try await fixture.store.refreshAllAsync()
    let panel = try PanelFixture(
      store: fixture.store, bridge: fixture.bridge, displayTitles: .renderer)
    var reopened: WebPanelController?
    do {
      try await panel.start()
      try await panel.finishWelcome()
      // Every wallpaper is a favorite while the first page is open, so requiring Favorite
      // keeps the whole library on show and leaves it tall enough to scroll.
      panel.controller.favoriteIDs = Set(entries.map(\.id))
      panel.show()
      try await panel.waitJS("powerProbe.received.at(-1)?.favorites?.length === 80")
      let before = try await panel.js("""
        const change = (node, type) => node.dispatchEvent(new Event(type, { bubbles: true }));
        const titles = () => [...document.querySelectorAll('.wallpaper-tile .tile-title')].map(node => node.textContent);
        const initial = titles();
        const sort = document.getElementById('browser-sort');
        sort.value = 'type'; change(sort, 'change');
        document.querySelector('[data-action="toggleSortDirection"]').click();
        const sidebar = document.getElementById('filter-sidebar');
        const favorite = sidebar.querySelector('input[value="Favorite"]'); favorite.checked = true; change(favorite, 'change');
        const web = sidebar.querySelector('input[value="Web"]'); web.checked = false; change(web, 'change');
        const search = document.getElementById('wallpaper-search'); search.value = 'wallpaper'; change(search, 'input');
        const grid = document.getElementById('wallpaper-grid');
        grid.scrollTop = 900;
        grid.dispatchEvent(new Event('scroll'));
        return { initial: initial.slice(0, 6), shown: titles().slice(0, 6), count: titles().length, scrollTop: grid.scrollTop };
        """) as? [String: Any]
      XCTAssertEqual(before?["count"] as? Int, 80, "Requiring Favorite keeps every favorite")
      XCTAssertEqual(before?["scrollTop"] as? Double, 900, "The library is tall enough to scroll")
      let initialOrder = try XCTUnwrap(before?["initial"] as? [String])
      let order = try XCTUnwrap(before?["shown"] as? [String])
      XCTAssertNotEqual(order, initialOrder, "Sorting by type, descending, changed the order")
      let expected = PanelViewState(
        installed: .init(
          text: "wallpaper", sort: "type", descending: true, tags: ["Favorite"],
          excludedTags: ["Web"]),
        scroll: ["installed": 900])
      try await panel.waitUntil(timeout: 5) { panel.navigation.viewState == expected }

      // The window closes: its page and controller go, the navigation stays. The library has
      // lost its favorites by the time the panel comes back.
      panel.controller.stop()
      let controller = WebPanelController(
        store: panel.store, navigation: panel.navigation, workshop: panel.workshop,
        pixiv: panel.pixiv, isPresentationVisible: { false }, theme: panel.theme,
        defaults: panel.defaults, appLanguage: .english(),
        playback: PlaybackPreferences(defaults: panel.defaults), playlists: panel.playlists,
        hotKeys: HotKeyPreferences(defaults: panel.defaults), collections: panel.collections,
        presets: panel.presets, backup: panel.backup, imagePlacement: panel.imagePlacement,
        compatibility: panel.compatibility, automations: panel.automations, spaces: panel.spaces)
      reopened = controller
      XCTAssertTrue(controller.favoriteIDs.isEmpty)
      panel.web = controller.makeWebView()
      panel.web.setFrameSize(NSSize(width: 960, height: 640))
      try await panel.waitUntil(timeout: 15) { controller.isReady }
      // The sidebar is drawn by the render that follows the first snapshot, restore included.
      try await panel.waitJS("document.querySelector('#filter-sidebar input[value=\"Favorite\"]')")
      let after = try await panel.js("""
        const sidebar = document.getElementById('filter-sidebar');
        const grid = document.getElementById('wallpaper-grid');
        return {
          search: document.getElementById('wallpaper-search').value,
          sort: document.getElementById('browser-sort').value,
          favorite: sidebar.querySelector('input[value="Favorite"]').checked,
          web: sidebar.querySelector('input[value="Web"]').checked,
          mature: sidebar.querySelector('input[value="Mature"]').checked,
          titles: [...document.querySelectorAll('.wallpaper-tile .tile-title')].map(node => node.textContent),
          scrollTop: grid.scrollTop
        };
        """) as? [String: Any]
      XCTAssertEqual(after?["search"] as? String, "wallpaper")
      XCTAssertEqual(after?["sort"] as? String, "type")
      XCTAssertEqual(after?["web"] as? Bool, false, "A hidden type stays hidden")
      XCTAssertEqual(after?["mature"] as? Bool, true, "A box nobody touched stays ticked")
      XCTAssertEqual(
        after?["favorite"] as? Bool, false,
        "No wallpaper is a favorite any more, so the stale required tag is dropped")
      let titles = try XCTUnwrap(after?["titles"] as? [String])
      XCTAssertEqual(titles.count, 80, "…and nothing is left hiding the library")
      XCTAssertEqual(Array(titles.prefix(6)), order, "The descending type order returns")
      XCTAssertEqual(try XCTUnwrap(after?["scrollTop"] as? Double), 900, accuracy: 1)

      // A second `ready` (Reconnect) hands over the old report again; it must not undo what the
      // person has done to the page since.
      let later = try await panel.js("""
        const search = document.getElementById('wallpaper-search');
        search.value = 'newer search'; search.dispatchEvent(new Event('input', { bubbles: true }));
        window.wallpaperUI.receive(await window.webkit.messageHandlers.native.postMessage({action:'ready'}));
        return document.getElementById('wallpaper-search').value;
        """) as? String
      XCTAssertEqual(later, "newer search")
      XCTAssertNil(controller.actionError)
    } catch {
      reopened?.stop()
      await panel.shutdown()
      throw error
    }
    reopened?.stop()
    await panel.shutdown()
  }

  /// The page reports its view state while the person types and scrolls, so the reply carries
  /// no snapshot and no push follows. A report outside the limits is dropped, and the one
  /// before it stays.
  func testViewStateReportsAreStoredSilentlyAndInvalidOnesAreIgnored() async throws {
    try await withPanel { panel in
      try await panel.finishWelcome()
      panel.show()
      try await panel.waitJS("powerProbe.received.length >= 1")
      try await panel.quiet()
      let pushes = try await panel.js("return powerProbe.received.length") as? Int
      let replies = try await panel.js("""
        const post = body => window.webkit.messageHandlers.native.postMessage({ action: 'viewState', ...body });
        const filters = { text: 'night', sort: 'size', descending: true, tags: [], excludedTags: ['Mature'] };
        const valid = await post({ installed: filters, scroll: { installed: 320 } });
        const bogus = await post({ installed: { ...filters, sort: 'random' }, scroll: {} });
        const negative = await post({ installed: filters, scroll: { installed: -5 } });
        return { valid: valid ?? null, bogus: bogus ?? null, negative: negative ?? null };
        """) as? [String: Any]
      XCTAssertTrue(replies?["valid"] is NSNull, "The reply carries no snapshot")
      XCTAssertTrue(replies?["bogus"] is NSNull)
      XCTAssertTrue(replies?["negative"] is NSNull)
      XCTAssertEqual(
        panel.navigation.viewState,
        PanelViewState(
          installed: .init(
            text: "night", sort: "size", descending: true, tags: [], excludedTags: ["Mature"]),
          scroll: ["installed": 320]),
        "Only the valid report was kept")
      XCTAssertNil(panel.controller.actionError, "An invalid report is dropped without an error banner")
      try await panel.quiet()
      try await panel.expectJS("return powerProbe.received.length", equals: pushes ?? -1)
    }
  }

  /// Issue #30: a tab click whose busy render threw once left its request marked pending with
  /// nothing sent. Every later tab click then waited on it in an endless microtask loop, and
  /// the whole page, Dismiss included, stopped responding.
  func testTabsStayUsableAfterARenderThrowsWhileSending() async throws {
    try await withPanel { panel in
      try await panel.finishWelcome()
      let before = panel.navigation.selection
      XCTAssertNotEqual(before, .settings)
      let failed = try await panel.js("""
        const query = document.querySelectorAll;
        let armed = true;
        document.querySelectorAll = function (selector) {
          if (armed && selector === '.tabs [data-page]') { armed = false; throw new Error('render failed'); }
          return query.call(this, selector);
        };
        document.querySelector('.tabs [data-page="settings"]').click();
        return !armed;
        """) as? Bool
      XCTAssertEqual(failed, true, "the first tab click must reach the failing render")
      XCTAssertEqual(panel.navigation.selection, before)

      _ = try await panel.js("document.querySelector('.tabs [data-page=\"settings\"]').click()")
      try await panel.waitUntil { panel.navigation.selection == .settings }
      try await panel.waitJS(
        "document.querySelector('.tabs [aria-current=\"page\"]')?.dataset.page === 'settings'")
    }
  }

  /// A request queued behind one that fails is still sent: the newer value is what the user
  /// chose last. The other tabs also stay clickable while a page is opening.
  func testQueuedRequestIsSentAfterTheOneBeforeItFails() async throws {
    try await withPanel { panel in
      try await panel.finishWelcome()
      XCTAssertNotEqual(panel.navigation.selection, .settings)
      let queued = try await panel.js("""
        const bridge = window.webkit.messageHandlers.native;
        const original = bridge.postMessage.bind(bridge);
        let first = true;
        bridge.postMessage = message => {
          if (first && message.action === 'navigate') {
            first = false;
            return new Promise((_, reject) => setTimeout(() => reject(new Error('fixture rejection')), 100));
          }
          return original(message);
        };
        document.querySelector('.tabs [data-page="pixiv"]').click();
        const settings = document.querySelector('.tabs [data-page="settings"]');
        const clickable = !settings.disabled;
        settings.click();
        return clickable;
        """) as? Bool
      XCTAssertEqual(queued, true, "another tab stays clickable while a page is opening")
      try await panel.waitUntil { panel.navigation.selection == .settings }
    }
  }

  func testUnavailableRendererSettingsKeepAppearanceUsableButBlockUnavailableLockScreen() async throws {
    try await withPanel { panel in
      try await panel.finishWelcome()
      try await panel.expectJS("""
        const base = await window.webkit.messageHandlers.native.postMessage({action:'ready'});
        window.wallpaperUI.receive({...base, page:'settings', settings:null});
        document.querySelector('[data-section="appearance"]').click();
        const mode = document.querySelector('[data-theme-setting="mode"]');
        const enabled = !mode.disabled && mode.getClientRects().length > 0;
        mode.value = 'dark';
        mode.dispatchEvent(new Event('change', {bubbles:true}));
        return enabled;
        """, equals: true)
      try await panel.waitUntil { panel.theme.preferences.mode == .dark }
      try await panel.waitJS("document.documentElement.dataset.themeMode === 'dark'")
      try await panel.expectJS("""
        const base = await window.webkit.messageHandlers.native.postMessage({action:'ready'});
        window.wallpaperUI.receive({...base, page:'settings', settings:{...base.settings,
          lockScreenAvailable:false, lockScreenStatus:'Unavailable fixture', lockScreenEnabled:false, lockScreenBusy:false}});
        document.querySelector('[data-section="general"]').click();
        const toggle = document.querySelector('[data-setting="lockScreenEnabled"]');
        const disabled = toggle.disabled;
        if (!disabled) return false; // A failing baseline must not attempt to enable lock-screen integration.
        toggle.click();
        return disabled && !toggle.checked;
        """, equals: true)
    }
  }

  func testWelcomePreventsBackgroundFocusAndRestoresItAfterFinish() async throws {
    try await withPanel { panel in
      try await panel.waitJS("!document.getElementById('welcome').hidden")
      try await panel.expectJS("""
        const title = document.getElementById('welcome-title');
        title.focus();
        const background = document.querySelector('.tabs [data-page="settings"]');
        background.focus();
        return document.activeElement === title;
        """, equals: true)
      try await panel.finishWelcome()
      try await panel.expectJS("""
        const background = document.querySelector('.tabs [data-page="settings"]');
        background.focus();
        return document.activeElement === background;
        """, equals: true)
    }
  }

  func testWelcomeSteamPromptTransitionsPreserveTypingAndUserFocus() async throws {
    try await withPanel { panel in
      let result = try await panel.js("""
        const base = await window.webkit.messageHandlers.native.postMessage({action:'ready'});
        document.querySelector('#welcome [data-action="go"][data-step="1"]').click();
        document.getElementById('welcome-password').focus();
        const job = {id:'steam-sign-in', account:'fixture', pending:true, queued:false, authenticating:true,
          status:'Connecting fixture', progress:null, prompt:null, challenge:null, securePrompt:false,
          error:null, cancelled:false};
        const receive = patch => window.wallpaperUI.receive({...base, downloads:[{...job, ...patch}], downloadRequests:[]});
        receive({});
        const waitingFocused = document.activeElement === document.getElementById('welcome-title');
        receive({prompt:'Steam Guard code', challenge:'emailCode'});
        const response = document.getElementById('welcome-response');
        const promptFocused = document.activeElement === response && !response.disabled;
        response.value = 'fixture-code';
        response.setSelectionRange(2, 7);
        receive({prompt:'Steam Guard code', challenge:'emailCode', progress:0.4, status:'Still waiting fixture'});
        const typingKept = document.activeElement === response && response.value === 'fixture-code'
          && response.selectionStart === 2 && response.selectionEnd === 7;
        const cancel = document.querySelector('#welcome [data-action="cancelSignIn"]');
        cancel.focus();
        receive({prompt:'Steam Guard code', challenge:'emailCode', progress:0.7});
        const actionFocusKept = document.activeElement === cancel;
        response.focus();
        receive({prompt:'New verification code', challenge:'emailCode'});
        const replacement = document.getElementById('welcome-response');
        return {waitingFocused, promptFocused, typingKept, actionFocusKept,
          replacementFocused:document.activeElement === replacement && !replacement.disabled};
        """) as? [String: Bool]
      for key in ["waitingFocused", "promptFocused", "typingKept", "actionFocusKept", "replacementFocused"] {
        XCTAssertEqual(result?[key], true, key)
      }
    }
  }

  func testWelcomeOwnershipNoticeAllowsContinuingAndRecheckingAfterPurchase() async throws {
    for (output, ownership) in [("No active license found for appID 431960.\n", "notOwned"), ("", "unknown")] {
      try await withPanel { panel in
        try Data(output.utf8).write(to: panel.root.appendingPathComponent("ownership"))
        panel.show()
        panel.workshop.steamCMDSetup.selectExisting(at: panel.executable)
        try await panel.waitUntil(timeout: 5) { panel.workshop.steamCMDSetup.selectedRuntime != nil }
        _ = try await panel.js("""
          window.wallpaperUI.receive(await window.webkit.messageHandlers.native.postMessage({action:'ready'}));
          document.querySelector('#welcome [data-action="go"][data-step="1"]').click();
          const account = document.getElementById('welcome-account');
          account.value = 'localtest';
          account.dispatchEvent(new Event('input', {bubbles:true}));
          document.getElementById('welcome-password').value = 'fixture-password';
          document.querySelector('#welcome form[data-form="signIn"]').requestSubmit();
          """)
        let job = try await panel.waitForSignIn()
        try await panel.waitUntil(timeout: 10) { !job.isPending }
        XCTAssertNil(job.errorMessage)
        let downloads = try XCTUnwrap(panel.controller.snapshot()["downloads"] as? [[String: Any]])
        XCTAssertEqual(downloads.first { $0["id"] as? String == job.id }?["wallpaperEngineOwnership"] as? String, ownership)
        try await panel.waitJS("!!document.querySelector('#welcome [data-action=\"checkOwnership\"]')")
        let notice = try await panel.js("""
          const region = document.getElementById('welcome');
          const buy = region.querySelector('.welcome-status [data-action="openExternal"]');
          return {
            purchase: buy?.dataset.url || '',
            alternatives: region.querySelector('.welcome-status-text').textContent.includes('Pixiv'),
            success: !!region.querySelector('.welcome-status.success'),
            continueEnabled: !region.querySelector('[data-action="continue"]').disabled,
          };
          """) as? [String: Any]
        XCTAssertEqual(notice?["alternatives"] as? Bool, true)
        XCTAssertEqual(notice?["success"] as? Bool, false)
        XCTAssertEqual(notice?["continueEnabled"] as? Bool, true)
        XCTAssertEqual((notice?["purchase"] as? String ?? "").contains("/app/431960"), ownership == "notOwned")
        _ = try await panel.js("document.querySelector('#welcome [data-action=\"continue\"]').click();")
        try await panel.waitJS("document.querySelector('#welcome .welcome-page')?.dataset.step === 'performance'")

        // A fresh query after purchase replaces the notice, even without a reusable sign-in.
        try Data("License packageID 12345:\n - State : Active( flags 512 )\n - Apps : 431960, (1 in total)\n".utf8)
          .write(to: panel.root.appendingPathComponent("ownership"))
        _ = try await panel.js("""
          document.querySelector('#welcome [data-action="go"][data-step="1"]').click();
          document.querySelector('#welcome [data-action="checkOwnership"]').click();
          """)
        try await panel.waitUntil { panel.workshop.downloader.signIn !== job }
        try await panel.waitJS("!!document.getElementById('welcome-response')")
        _ = try await panel.js("""
          document.getElementById('welcome-response').value = 'fixture-password';
          document.querySelector('#welcome form[data-form="prompt"]').requestSubmit();
          """)
        try await panel.waitJS("!!document.querySelector('#welcome .welcome-status.success')")
        XCTAssertEqual(panel.workshop.downloader.signIn?.worker.wallpaperEngineOwnership, .owned)
        let hasRetry = try await panel.js("return !!document.querySelector('#welcome [data-action=\"checkOwnership\"]');") as? Bool
        XCTAssertEqual(hasRetry, false)
      }
    }
  }

  func testWelcomeRevealedPasswordSurvivesSnapshotsWithoutHTMLEchoAndClearsOnSubmit() async throws {
    try await withPanel { panel in
      panel.show()
      panel.workshop.steamCMDSetup.selectExisting(at: panel.executable)
      try await panel.waitUntil(timeout: 5) { panel.workshop.steamCMDSetup.selectedRuntime != nil }
      let result = try await panel.js("""
        const base = await window.webkit.messageHandlers.native.postMessage({action:'ready'});
        window.wallpaperUI.receive(base);
        document.querySelector('#welcome [data-action="go"][data-step="1"]').click();
        const region = document.getElementById('welcome');
        const account = document.getElementById('welcome-account');
        account.value = 'LocalTest';
        account.dispatchEvent(new Event('input', {bubbles:true}));
        const password = document.getElementById('welcome-password');
        const secret = 'panel-only-synthetic-secret';
        password.focus();
        password.value = secret;
        region.querySelector('[data-action="reveal"]').click();
        const shown = password.type === 'text';
        account.focus();
        window.wallpaperUI.receive({...base, paused:!base.paused});
        const shownKept = password.value === secret;
        const noEchoShown = !password.hasAttribute('value') && !document.documentElement.innerHTML.includes(secret);
        password.focus();
        region.querySelector('[data-action="reveal"]').click();
        const hidden = password.type === 'password';
        account.focus();
        window.wallpaperUI.receive(base);
        const hiddenKept = password.value === secret;
        const noEchoHidden = !password.hasAttribute('value') && !document.documentElement.innerHTML.includes(secret);
        // Exercise explicit clearing independently even if preservation regresses.
        password.value = secret;
        region.querySelector('form[data-form="signIn"]').requestSubmit();
        return {shown, shownKept, noEchoShown, hidden, hiddenKept, noEchoHidden, cleared:password.value === ''};
        """) as? [String: Bool]
      for key in ["shown", "shownKept", "noEchoShown", "hidden", "hiddenKept", "noEchoHidden", "cleared"] {
        XCTAssertEqual(result?[key], true, key)
      }
      let job = try await panel.waitForSignIn()
      try await panel.waitUntil(timeout: 10) { !job.isPending }
      XCTAssertNil(job.errorMessage, "Only the isolated fake Steam runtime is used")
    }
  }

  private func finishWelcome(in web: WKWebView) async throws {
    XCTAssertNil(web.window, "Finishing onboarding must remain offscreen")
    let finished = try await web.callAsyncJavaScript(
      """
      const region = document.getElementById('welcome');
      if (!region.hidden) {
        region.querySelector('[data-action="go"][data-step="5"]').click();
        const finish = region.querySelector('[data-action="finish"]');
        if (!finish || finish.disabled || !finish.getClientRects().length)
          throw new Error('Welcome Finish is not available');
        finish.click();
      }
      const deadline = Date.now() + 5000;
      while (!region.hidden || !(await window.webkit.messageHandlers.native.postMessage({action:'ready'})).welcomeSeen) {
        if (Date.now() > deadline) throw new Error('Welcome did not finish');
        await new Promise(resolve => setTimeout(resolve, 20));
      }
      return region.hidden;
      """, arguments: [:], in: nil, contentWorld: .page) as? Bool
    XCTAssertEqual(finished, true)
  }

}
