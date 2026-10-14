import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import XCTest

@testable import WallpaperMachine

/// Discover page: pagination, grid columns, download rings, telemetry and animated previews.
@MainActor
final class ControlPanelDiscoverTests: ControlPanelTestCase {
  /// Previous/Next page controls also carry a numeric page, which must not be
  /// treated as a Discover/Installed/Settings navigation value.
  func testWorkshopPaginationDoesNotNavigateWithThePageNumber() async throws {
    let fixture = makeStore()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "web-page-\(UUID().uuidString)")
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
    XCTAssertTrue(controller.isReady)
    guard controller.isReady else { return }
    XCTAssertNil(web.window)
    _ = try await web.callAsyncJavaScript("""
      document.querySelector('#welcome [data-action="go"][data-step="5"]').click();
      document.querySelector('#welcome [data-action="finish"]').click();
      """, arguments: [:], in: nil, contentWorld: .page)
    let result =
      try await web.callAsyncJavaScript(
        """
        const waitFor = async predicate => {
          const deadline = Date.now() + 5000;
          while (!predicate()) {
            if (Date.now() > deadline) throw new Error('Workshop pagination did not settle');
            await new Promise(resolve => setTimeout(resolve, 20));
          }
        };
        const snapshot = await window.webkit.messageHandlers.native.postMessage({action:'ready'});
        window.wallpaperUI.receive(Object.assign({}, snapshot, {
          page: 'discover',
          workshop: Object.assign({}, snapshot.workshop, {
            page: 1, totalPages: 4, loaded: true, loading: false, items: [], error: null
          })
        }));
        const next = document.querySelector('[data-action="workshopPage"][title="Next page"]');
        if (!next) throw new Error('Next page control missing');
        if (next.hasAttribute('data-page')) throw new Error('Pagination must not reuse the main tab data-page attribute');
        if (next.closest('.tabs [data-page]')) throw new Error('Pagination was treated as a main tab');
        next.click();
        await waitFor(() => {
          const banner = document.getElementById('error-banner');
          return (banner && !banner.hidden) || !document.querySelector('[title="Next page"]');
        });
        const banner = document.getElementById('error-banner');
        return {error: banner.hidden ? '' : banner.textContent, workshopPage: next.dataset.workshopPage};
        """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
    XCTAssertEqual(
      result?["error"] as? String, "",
      "Clicking Next page must request that Workshop page, not navigate with its page number")
    XCTAssertEqual(result?["workshopPage"] as? String, "2")
    XCTAssertNil(controller.actionError)
    XCTAssertEqual(navigation.selection, .wallpaper)
    XCTAssertNil(web.window)
    await workshop.steamCMDSetup.shutdown()
  }

  /// Steam clamps every public query to 1,000 pages of 30, so the panel must let people
  /// jump straight to a page and clamp typed numbers to that range instead of pretending
  /// millions of results are reachable.
  func testWorkshopPageJumpClampsToSteamsPageLimit() async throws {
    let fixture = makeStore()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "web-page-jump-\(UUID().uuidString)")
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
    XCTAssertTrue(controller.isReady)
    guard controller.isReady else { return }
    XCTAssertNil(web.window)
    _ = try await web.callAsyncJavaScript("""
      document.querySelector('#welcome [data-action="go"][data-step="5"]').click();
      document.querySelector('#welcome [data-action="finish"]').click();
      """, arguments: [:], in: nil, contentWorld: .page)
    let result =
      try await web.callAsyncJavaScript(
        """
        const snapshot = await window.webkit.messageHandlers.native.postMessage({action:'ready'});
        const sent = [];
        const original = window.webkit.messageHandlers.native.postMessage.bind(window.webkit.messageHandlers.native);
        window.webkit.messageHandlers.native.postMessage = message => { sent.push(message); return original(message); };
        const show = workshop => window.wallpaperUI.receive(Object.assign({}, snapshot, {
          page: 'discover',
          workshop: Object.assign({}, snapshot.workshop, {
            page: 1, totalPages: 1000, totalCount: 2891159, pageSize: 30,
            loaded: true, loading: false, items: [], error: null
          }, workshop)
        }));
        show({});
        const form = document.querySelector('form[data-form="workshopPage"]');
        if (!form) throw new Error('Page jump form missing');
        const input = form.elements.page;
        const max = input.getAttribute('max');
        input.value = '5000';
        form.requestSubmit();
        await new Promise(resolve => setTimeout(resolve, 50));
        const request = sent.find(message => message.action === 'workshopPage');
        show({ totalPages: 1, totalCount: 12 });
        const single = document.querySelector('form[data-form="workshopPage"] input[name="page"]');
        return { requestedPage: request ? request.page : null, max, disabled: Boolean(single && single.disabled) };
        """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
    XCTAssertEqual(result?["max"] as? String, "1000")
    XCTAssertEqual(result?["requestedPage"] as? Int, 1000, "Typed pages must clamp to Steam's last page")
    XCTAssertEqual(result?["disabled"] as? Bool, true, "A single page leaves nothing to jump to")
    XCTAssertNil(controller.actionError)
    await workshop.steamCMDSetup.shutdown()
  }

  /// A link pasted whole is looked up at once, but a bare id waits for Return: searching as it is
  /// typed would look up every prefix of it. Words keep their short pause. The summary stops
  /// counting results while the grid shows an item looked up from a link, and only the
  /// wallpapers list invites a link.
  func testPastedLinksSearchAtOnceAndIdsWaitForReturnWithoutWindow() async throws {
    let fixture = makeStore()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "web-paste-link-\(UUID().uuidString)")
    let defaults = try TemporaryDefaults.make(for: self).defaults
    defer { try? FileManager.default.removeItem(at: root) }
    let workshop = WorkshopStore(
      downloader: WorkshopDownloadManager(sessionDirectory: root), supportDirectory: root,
      defaults: defaults)
    let controller = WebPanelController(
      store: fixture.store, navigation: ControlPanelNavigation(), workshop: workshop,
      defaults: defaults, appLanguage: .english())
    let web = controller.makeWebView()
    defer { controller.stop() }
    web.setFrameSize(NSSize(width: 960, height: 640))
    let deadline = Date().addingTimeInterval(15)
    while !controller.isReady && Date() < deadline {
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertTrue(controller.isReady)
    guard controller.isReady else { return }
    _ = try await web.callAsyncJavaScript("""
      document.querySelector('#welcome [data-action="go"][data-step="5"]').click();
      document.querySelector('#welcome [data-action="finish"]').click();
      """, arguments: [:], in: nil, contentWorld: .page)
    // Messages are recorded and answered with nothing, so no search reaches Steam, and the
    // short pause before a search is recorded instead of waited for.
    let result =
      try await web.callAsyncJavaScript(
        """
        const snapshot = await window.webkit.messageHandlers.native.postMessage({action:'ready'});
        const sent = [];
        // The page drops the wrapper, and the override on it, once it collects garbage unless
        // something holds the wrapper.
        window.heldBridge = window.webkit.messageHandlers.native;
        window.webkit.messageHandlers.native.postMessage = message => { sent.push(message); return Promise.resolve(null); };
        const pauses = [];
        const realSetTimeout = window.setTimeout.bind(window);
        window.setTimeout = (callback, delay, ...rest) => {
          if (delay === 450) { pauses.push(delay); return 0; }
          return realSetTimeout(callback, delay, ...rest);
        };
        const show = workshop => window.wallpaperUI.receive(Object.assign({}, snapshot, {
          page: 'discover',
          workshop: Object.assign({}, snapshot.workshop, {
            page: 1, totalPages: 1000, totalCount: 2891159, pageSize: 30,
            loaded: true, loading: false, items: [], error: null, lookup: false,
            source: { key: 'browse', id: null, name: null, searchable: true, canGoBack: false }
          }, workshop)
        }));
        // Native pushes can replace the snapshot between turns, so each step shows Discover again
        // first and reads what it caused straight away: handlers post their message at once.
        const turn = () => new Promise(resolve => realSetTimeout(resolve, 0));
        const field = () => document.getElementById('wallpaper-search');
        const searches = () => sent.filter(message => message.action === 'workshopSearch').map(message => message.text);
        const begin = async text => {
          await turn(); show({});
          sent.length = 0; pauses.length = 0;
          if (text !== undefined) field().value = text;
        };
        const enter = async (text, inputType) => {
          await begin(text);
          field().dispatchEvent(new InputEvent('input', { bubbles: true, inputType }));
          return { searches: searches(), pauses: pauses.length };
        };
        const summary = () => document.getElementById('browser-summary').textContent.trim();
        show({});
        const result = { placeholder: field().placeholder, plainSummary: summary() };
        const link = 'https://steamcommunity.com/sharedfiles/filedetails/?id=3632513108';
        result.pastedLink = await enter(link, 'insertFromPaste');
        result.typedLink = await enter(link, 'insertText');
        result.typedId = await enter('3632513108', 'insertText');
        result.pastedId = await enter('3632513108', 'insertFromPaste');
        result.shortNumber = await enter('12345', 'insertText');
        result.words = await enter('forest', 'insertText');
        result.wordsPasted = await enter('forest', 'insertFromPaste');
        await enter('3632513108', 'insertFromPaste');
        await begin();
        field().form.requestSubmit();
        result.submitted = searches();
        await turn(); show({ lookup: true, totalPages: 1, totalCount: 1 });
        result.lookupSummary = summary();
        show({ source: { key: 'collections', id: null, name: null, searchable: true, canGoBack: false } });
        result.collectionsPlaceholder = field().placeholder;
        return result;
        """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
    let link = "https://steamcommunity.com/sharedfiles/filedetails/?id=3632513108"
    func entry(_ name: String) -> (searches: [String], pauses: Int) {
      let value = result?[name] as? [String: Any]
      return (value?["searches"] as? [String] ?? ["missing"], value?["pauses"] as? Int ?? -1)
    }
    XCTAssertEqual(entry("pastedLink").searches, [link], "a link pasted whole is looked up at once")
    XCTAssertEqual(entry("pastedLink").pauses, 0)
    XCTAssertEqual(entry("typedLink").searches, [], "a link typed by hand waits for a pause like words")
    XCTAssertEqual(entry("typedLink").pauses, 1)
    for name in ["typedId", "pastedId"] {
      XCTAssertEqual(entry(name).searches, [], "an id is not looked up as it is entered")
      XCTAssertEqual(entry(name).pauses, 0, "and no pause is left running to look it up")
    }
    XCTAssertEqual(entry("shortNumber").pauses, 1, "a short number is searched for like words")
    XCTAssertEqual(entry("words").pauses, 1)
    XCTAssertEqual(entry("wordsPasted").searches, [])
    XCTAssertEqual(entry("wordsPasted").pauses, 1)
    XCTAssertEqual(result?["submitted"] as? [String], ["3632513108"], "Return looks the id up")
    let plain = result?["plainSummary"] as? String ?? ""
    let looked = result?["lookupSummary"] as? String ?? ""
    XCTAssertNotNil(plain.rangeOfCharacter(from: .decimalDigits), "a list counts its results")
    XCTAssertFalse(looked.isEmpty)
    XCTAssertNil(looked.rangeOfCharacter(from: .decimalDigits), "an item looked up from a link is not counted among results")
    XCTAssertNotEqual(result?["placeholder"] as? String, result?["collectionsPlaceholder"] as? String,
      "only the wallpapers list invites a pasted link")
    XCTAssertFalse((result?["collectionsPlaceholder"] as? String ?? "").isEmpty)
    XCTAssertNil(controller.actionError)
    await workshop.steamCMDSetup.shutdown()
  }

  /// The sort menu is the web page's own table of keys, and the native side refuses a key it
  /// does not know, so each option must be one `WorkshopSort` reads and none may be left out.
  /// Choosing one asks for a search sorted by that key.
  func testDiscoverSortMenuOffersEveryWorkshopSortAndSearchesByTheChosenOne() async throws {
    let fixture = makeStore()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "web-sort-menu-\(UUID().uuidString)")
    let defaults = try TemporaryDefaults.make(for: self).defaults
    defer { try? FileManager.default.removeItem(at: root) }
    let workshop = WorkshopStore(
      downloader: WorkshopDownloadManager(sessionDirectory: root), supportDirectory: root,
      defaults: defaults)
    let controller = WebPanelController(
      store: fixture.store, navigation: ControlPanelNavigation(), workshop: workshop,
      defaults: defaults, appLanguage: .english())
    let web = controller.makeWebView()
    defer { controller.stop() }
    web.setFrameSize(NSSize(width: 960, height: 640))
    let deadline = Date().addingTimeInterval(15)
    while !controller.isReady && Date() < deadline {
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertTrue(controller.isReady)
    guard controller.isReady else { return }
    _ = try await web.callAsyncJavaScript("""
      document.querySelector('#welcome [data-action="go"][data-step="5"]').click();
      document.querySelector('#welcome [data-action="finish"]').click();
      """, arguments: [:], in: nil, contentWorld: .page)
    // Messages are recorded and answered with nothing, so no search reaches Steam.
    let result =
      try await web.callAsyncJavaScript(
        """
        const snapshot = await window.webkit.messageHandlers.native.postMessage({action:'ready'});
        const sent = [];
        // WebKit hands the page a wrapper that is dropped, with the override on it, once nothing
        // in the page refers to it and the page collects garbage; the next message would then
        // reach the real handler. Holding the wrapper keeps the override for the whole run.
        window.heldBridge = window.webkit.messageHandlers.native;
        window.webkit.messageHandlers.native.postMessage = message => { sent.push(message); return Promise.resolve(null); };
        const show = () => window.wallpaperUI.receive(Object.assign({}, snapshot, {
          page: 'discover',
          workshop: Object.assign({}, snapshot.workshop, {
            page: 1, totalPages: 1000, totalCount: 2891159, pageSize: 30,
            loaded: true, loading: false, items: [], error: null, lookup: false,
            source: { key: 'browse', id: null, name: null, searchable: true, canGoBack: false }
          })
        }));
        // Native pushes can replace the snapshot between turns, and one that arrives while the
        // page is not on Discover turns a sort choice into an Installed sort that searches
        // nothing. So each choice shows Discover again just before it and reads what it caused
        // in the same turn: the handler posts its message at once. The page redraws after a
        // choice, so the menu is looked up again for each one.
        const turn = () => new Promise(resolve => setTimeout(resolve, 0));
        const menu = () => document.getElementById('browser-sort');
        show();
        const keys = [...menu().options].map(option => option.value);
        const labels = [...menu().options].map(option => option.textContent.trim());
        const choices = {};
        for (const key of keys) {
          await turn(); show();
          sent.length = 0;
          menu().value = key;
          menu().dispatchEvent(new Event('change', { bubbles: true }));
          choices[key] = sent.filter(message => message.action === 'workshopSearch').map(message => message.sort);
        }
        return { keys, labels, choices };
        """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
    let keys = result?["keys"] as? [String] ?? []
    XCTAssertEqual(Set(keys), Set(WorkshopSort.allCases.map(\.rawValue)), "every sort has a menu entry and no entry is unknown to Swift")
    XCTAssertEqual(keys.count, Set(keys).count, "no sort is offered twice")
    let labels = result?["labels"] as? [String] ?? []
    XCTAssertEqual(labels.count, Set(labels).count, "entries are told apart by their labels")
    XCTAssertFalse(labels.contains(where: \.isEmpty))
    let choices = result?["choices"] as? [String: [String]] ?? [:]
    for key in keys {
      XCTAssertEqual(choices[key], [key], "choosing \(key) searches sorted by it")
    }
    XCTAssertNil(controller.actionError)
    await workshop.steamCMDSetup.shutdown()
  }

  /// Discover's lists are tabs, so subscriptions can be found without opening a menu, even at
  /// the 760px window minimum; signed in, downloading what the library lacks leads the list.
  func testDiscoverListsAreTabsAndSubscriptionsLeadWithTheirDownload() async throws {
    let fixture = makeStore()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "web-source-tabs-\(UUID().uuidString)")
    let defaults = try TemporaryDefaults.make(for: self).defaults
    defer { try? FileManager.default.removeItem(at: root) }
    let workshop = WorkshopStore(
      downloader: WorkshopDownloadManager(sessionDirectory: root), supportDirectory: root,
      defaults: defaults)
    let controller = WebPanelController(
      store: fixture.store, navigation: ControlPanelNavigation(), workshop: workshop,
      defaults: defaults, appLanguage: .english())
    let web = controller.makeWebView()
    defer { controller.stop() }
    web.setFrameSize(NSSize(width: 760, height: 640))
    let deadline = Date().addingTimeInterval(15)
    while !controller.isReady && Date() < deadline {
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertTrue(controller.isReady)
    guard controller.isReady else { return }
    _ = try await web.callAsyncJavaScript("""
      document.querySelector('#welcome [data-action="go"][data-step="5"]').click();
      document.querySelector('#welcome [data-action="finish"]').click();
      """, arguments: [:], in: nil, contentWorld: .page)
    let result =
      try await web.callAsyncJavaScript(
        """
        const snapshot = await window.webkit.messageHandlers.native.postMessage({action:'ready'});
        const sent = [];
        const original = window.webkit.messageHandlers.native.postMessage.bind(window.webkit.messageHandlers.native);
        window.webkit.messageHandlers.native.postMessage = message => { sent.push(message); return original(message); };
        const show = (source, workshop = {}) => window.wallpaperUI.receive(Object.assign({}, snapshot, {
          page: 'discover',
          workshop: Object.assign({}, snapshot.workshop, {
            page: 1, totalPages: 1, totalCount: 0, loaded: true, loading: false, items: [], error: null,
            source: Object.assign({ id: null, name: null, searchable: false, canGoBack: false }, source)
          }, workshop)
        }));
        const tabs = () => [...document.querySelectorAll('#browser-toolbar .source-tabs button')];
        const current = () => tabs().filter(tab => tab.getAttribute('aria-current') === 'page').map(tab => tab.dataset.source);
        show({ key: 'browse', searchable: true });
        const labels = tabs().map(tab => tab.textContent.trim());
        const oneRow = new Set(tabs().map(tab => tab.getBoundingClientRect().top)).size === 1;
        const browsing = current();
        show({ key: 'subscriptions' }, { steamSignedIn: false });
        const signIn = document.querySelector('#browser-empty [data-action="steamWebSignIn"]');
        const signedOut = { current: current(), signIn: Boolean(signIn && !document.getElementById('browser-empty').hidden) };
        show({ key: 'subscriptions' }, { steamSignedIn: true, totalCount: 48, totalPages: 2 });
        const summary = document.getElementById('browser-summary');
        const download = summary.querySelector('[data-action="workshopDownloadSubscribed"]');
        const signedIn = { text: summary.textContent, primary: Boolean(download && download.classList.contains('primary')),
          signOut: Boolean(summary.querySelector('[data-action="steamWebSignOut"]')),
          steamPage: Boolean(summary.querySelector('[data-action="openExternal"]')),
          screened: Boolean(document.querySelector('#browser-empty [data-action="workshopPage"][data-workshop-page="2"]')),
          browse: Boolean(document.querySelector('#browser-empty [data-action="workshopSource"][data-source="browse"]')) };
        const downloadEnabled = !download.disabled;
        show({ key: 'subscriptions' }, { steamSignedIn: true, totalCount: 0 });
        const nothingToDownload = summary.querySelector('[data-action="workshopDownloadSubscribed"]').disabled;
        const browseWhenEmpty = Boolean(document.querySelector('#browser-empty [data-action="workshopSource"][data-source="browse"]'));
        show({ key: 'browse', searchable: true });
        tabs()[0].focus();
        tabs()[0].dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }));
        const arrowed = document.activeElement.dataset.source;
        show({ key: 'creator', id: '76561198000000001', name: 'Fixture Author', canGoBack: true });
        const opened = { current: current(), back: Boolean(document.querySelector('#browser-toolbar [data-action="workshopBack"]')) };
        show({ key: 'browse', searchable: true });
        tabs().find(tab => tab.dataset.source === 'subscriptions').click();
        await new Promise(resolve => setTimeout(resolve, 50));
        const request = sent.find(message => message.action === 'workshopSource');
        return { labels, oneRow, browsing, signedOut, signedIn, downloadEnabled, nothingToDownload, browseWhenEmpty, arrowed, opened, requested: request ? request.source : null };
        """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
    XCTAssertEqual(result?["labels"] as? [String], ["Wallpapers", "Collections", "Your subscriptions"])
    XCTAssertEqual(result?["oneRow"] as? Bool, true, "The tabs must fit one row at the window minimum")
    XCTAssertEqual(result?["browsing"] as? [String], ["browse"])
    let signedOut = result?["signedOut"] as? [String: Any]
    XCTAssertEqual(signedOut?["current"] as? [String], ["subscriptions"])
    XCTAssertEqual(signedOut?["signIn"] as? Bool, true, "Signed out, subscriptions offer the sign-in")
    let signedIn = result?["signedIn"] as? [String: Any]
    XCTAssertTrue((signedIn?["text"] as? String)?.contains("48") == true, "Signed in, the list says how many")
    XCTAssertEqual(signedIn?["primary"] as? Bool, true, "Downloading what is missing is the list's main action")
    XCTAssertEqual(signedIn?["signOut"] as? Bool, true)
    XCTAssertEqual(signedIn?["steamPage"] as? Bool, true, "The list links to its Steam page")
    XCTAssertEqual(
      signedIn?["screened"] as? Bool, true,
      "Subscriptions the default filters hide from this page lead on to the next page")
    XCTAssertEqual(signedIn?["browse"] as? Bool, false, "48 subscriptions are not an empty list")
    XCTAssertEqual(result?["downloadEnabled"] as? Bool, true)
    XCTAssertEqual(result?["nothingToDownload"] as? Bool, true, "With no subscriptions there is nothing to download")
    XCTAssertEqual(result?["browseWhenEmpty"] as? Bool, true, "No subscriptions lead back to browsing")
    XCTAssertEqual(result?["arrowed"] as? String, "collections", "Arrow keys move between the list tabs")
    let opened = result?["opened"] as? [String: Any]
    XCTAssertEqual(opened?["current"] as? [String], [], "An opened author is none of the lists")
    XCTAssertEqual(opened?["back"] as? Bool, true)
    XCTAssertEqual(result?["requested"] as? String, "subscriptions")
    XCTAssertNil(controller.actionError)
    await workshop.steamCMDSetup.shutdown()
  }

  /// Discover tiles are exactly square, never fewer than three to a row (even at the 760px
  /// window minimum with the filter sidebar open), and gain columns as the window widens.
  /// A page is a fixed 30 tiles that scroll, so the panel never reports a page size, and the
  /// column count settles at once after a resize instead of flapping.
  func testDiscoverGridKeepsSquareTilesInAtLeastThreeStableColumns() async throws {
    let fixture = makeStore()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "grid-columns-\(UUID().uuidString)")
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
    XCTAssertTrue(controller.isReady)
    guard controller.isReady else { return }
    XCTAssertNil(web.window)
    _ = try await web.callAsyncJavaScript("""
      document.querySelector('#welcome [data-action="go"][data-step="5"]').click();
      document.querySelector('#welcome [data-action="finish"]').click();
      """, arguments: [:], in: nil, contentWorld: .page)
    let setup = """
      const original = window.webkit.messageHandlers.native.postMessage.bind(window.webkit.messageHandlers.native);
      window.__sent = [];
      window.webkit.messageHandlers.native.postMessage = message => { window.__sent.push(message); return original(message); };
      window.__snapshot = await original({action:'ready'});
      window.__items = Array.from({ length: 30 }, (_, index) => ({ id: `item-${index}`, title: `Tile ${index}`, kind: 'Scene' }));
      window.__show = page => window.wallpaperUI.receive(Object.assign({}, window.__snapshot, { page,
        wallpapers: window.__items.map(item => Object.assign({ preview: null, active: false, supported: true, tags: [] }, item)),
        workshop: Object.assign({}, window.__snapshot.workshop, {
        page: 1, totalPages: 1000, totalCount: 1576662, reachable: 30000, pageSize: 30, maxPages: 1000,
        loaded: true, loading: false, items: window.__items, error: null }) }));
      window.__show('discover');
      return window.__snapshot.workshop.pageSize;
      """
    let pageSize = try await web.callAsyncJavaScript(
      setup, arguments: [:], in: nil, contentWorld: .page) as? Int
    XCTAssertEqual(pageSize, WorkshopStore.pageSize, "A page is one Steam page of 30")
    let probe = """
      const deadline = Date.now() + 5000;
      while (Math.round(document.documentElement.clientWidth) !== expected) {
        if (Date.now() > deadline) throw new Error(`Viewport did not reach ${expected}px`);
        await new Promise(resolve => setTimeout(resolve, 20));
      }
      window.__show(page);
      const grid = document.getElementById('wallpaper-grid');
      const columnsNow = () => getComputedStyle(grid).gridTemplateColumns.split(' ').length;
      // Sample the column count over a few hundred milliseconds: it must not flap after a resize.
      const samples = [];
      for (let index = 0; index < 8; index += 1) {
        samples.push(columnsNow());
        await new Promise(resolve => setTimeout(resolve, 40));
      }
      const tiles = [...grid.querySelectorAll('.tile-select')].map(tile => tile.getBoundingClientRect());
      const first = tiles[0];
      const widths = new Set(tiles.map(tile => Math.round(tile.width)));
      return { columns: samples[0], stable: samples.every(count => count === samples[0]), tiles: tiles.length,
               square: Math.abs(first.height - first.width), uniform: widths.size === 1,
               pageSizeRequests: window.__sent.filter(message => message.action === 'workshopPageSize').length,
               scrolls: grid.scrollHeight > grid.clientHeight, gridWidth: grid.clientWidth };
      """
    var previous = 0
    for (page, width, height, minimum) in [
      ("discover", 760, 560, 3), ("installed", 760, 560, 3), ("discover", 960, 640, 3),
      ("discover", 1400, 900, 5), ("discover", 1900, 1000, 6),
    ] {
      web.setFrameSize(NSSize(width: width, height: height))
      let result = try await web.callAsyncJavaScript(
        probe, arguments: ["page": page, "expected": width], in: nil, contentWorld: .page)
        as? [String: Any] ?? [:]
      let context = "\(page) at \(width)×\(height): \(result)"
      let columns = result["columns"] as? Int ?? 0
      XCTAssertGreaterThanOrEqual(columns, minimum, "At least \(minimum) columns: \(context)")
      XCTAssertEqual(result["stable"] as? Bool, true, "Columns must not flap: \(context)")
      XCTAssertLessThanOrEqual(result["square"] as? Double ?? 1, 0.5, "Tiles must be square: \(context)")
      XCTAssertEqual(result["uniform"] as? Bool, true, "Every tile shares one width: \(context)")
      XCTAssertEqual(result["pageSizeRequests"] as? Int, 0, "The grid never negotiates a page size: \(context)")
      if page == "discover" {
        XCTAssertEqual(result["tiles"] as? Int, 30, "A page shows all 30 tiles: \(context)")
        XCTAssertGreaterThanOrEqual(columns, previous, "Columns never drop as the window widens: \(context)")
        previous = columns
      }
    }
    XCTAssertNil(controller.actionError)
    await workshop.steamCMDSetup.shutdown()
  }

  func testDiscoverTilesCarryDownloadRingsAndOnlySteamRequestsOpenTheDialogWithoutWindow()
    async throws
  {
    let fixture = makeStore()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "web-rings-\(UUID().uuidString)")
    let defaults = try TemporaryDefaults.make(for: self).defaults
    defer { try? FileManager.default.removeItem(at: root) }
    let workshop = WorkshopStore(
      downloader: WorkshopDownloadManager(sessionDirectory: root), supportDirectory: root,
      defaults: defaults)
    let controller = WebPanelController(
      store: fixture.store, navigation: ControlPanelNavigation(), workshop: workshop,
      defaults: defaults,
      appLanguage: .english())
    let web = controller.makeWebView()
    defer { controller.stop() }
    web.setFrameSize(NSSize(width: 960, height: 640))
    let deadline = Date().addingTimeInterval(15)
    while !controller.isReady && Date() < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertTrue(controller.isReady)
    guard controller.isReady else { return }
    XCTAssertNil(web.window)
    _ = try await web.callAsyncJavaScript("""
      document.querySelector('#welcome [data-action="go"][data-step="5"]').click();
      document.querySelector('#welcome [data-action="finish"]').click();
      """, arguments: [:], in: nil, contentWorld: .page)
    let base =
      try await web.callAsyncJavaScript(
        "return await window.webkit.messageHandlers.native.postMessage({action:'ready'})",
        arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
    XCTAssertNotNil(base)
    guard let base else { return }
    controller.stop()

    let result =
      try await web.callAsyncJavaScript(
        """
        const waitFor = async predicate => {
          const deadline = Date.now() + 5000;
          while (!predicate()) {
            if (Date.now() > deadline) throw new Error('Download ring did not settle');
            await new Promise(resolve => setTimeout(resolve, 20));
          }
        };
        const item = { id: 'ring-fixture', title: 'Ring fixture', creator: 'Test', summary: '', preview: null,
          thumbnail: null, tags: ['Video'], size: 2048, subscriptions: 0, kind: 'Video' };
        const job = { id: 'ring-fixture', wallpaperID: 'ring-fixture', title: 'Ring fixture',
          status: 'Downloading Workshop files…', preview: null, thumbnail: null, account: 'fixture',
          progress: 0.42, pending: true, queued: false, bytesReceived: 860, bytesExpected: 2048,
          bytesPerSecond: 600000, authenticating: false, cancelled: false, error: null, prompt: null,
          securePrompt: false, challenge: null, warning: null };
        const push = (downloads, extra = {}) => window.wallpaperUI.receive(Object.assign({}, base, {
          page: 'discover', workshop: Object.assign({}, base.workshop, { items: [item], loaded: true, selectedID: 'ring-fixture' }),
          downloads, downloadRequests: [], setup: Object.assign({}, base.setup, { ready: true }) }, extra));
        const grid = document.getElementById('wallpaper-grid');
        const dialog = document.getElementById('download-dialog');
        const ring = () => grid.querySelector('.tile-download');
        push([]);
        await waitFor(() => grid.querySelector('.wallpaper-tile'));
        const idle = { noRing: !ring(), noQueueButton: !document.querySelector('#top-actions [data-action="openDownloads"]') };
        push([job]);
        await waitFor(() => ring()?.classList.contains('progress'));
        const progress = {
          percent: ring().querySelector('.ring-label').textContent.trim(),
          speed: ring().querySelector('.ring-speed')?.textContent.trim(),
          cancel: ring().dataset.action === 'downloadCancel' && ring().dataset.id === 'ring-fixture',
          drawn: Number(ring().querySelector('.ring-value').getAttribute('stroke-dashoffset')) > 0,
          queueButton: !!document.querySelector('#top-actions [data-action="openDownloads"]'),
          inspectorCancel: !!document.querySelector('#inspector [data-action="downloadCancel"]'),
          dialogClosed: !dialog.open };
        push([Object.assign({}, job, { progress: null, authenticating: true, status: 'Waiting for Steam authentication…' })]);
        const authenticating = { busy: ring().classList.contains('busy'), speed: ring().querySelector('.ring-speed')?.textContent.trim(), dialogClosed: !dialog.open };
        push([Object.assign({}, job, { progress: null, bytesPerSecond: null, authenticating: true, phase: 'signingIn', status: 'Waiting for Steam authentication…' })]);
        const phased = { busy: ring().classList.contains('busy'), word: ring().querySelector('.ring-label.ring-phase')?.textContent.trim(), phase: ring().dataset.phase, noSpeed: !ring().querySelector('.ring-speed') };
        push([Object.assign({}, job, { progress: 1, bytesPerSecond: null, authenticating: false, phase: 'finishing', status: 'Validating and adding to your library…' })]);
        const finishing = { progress: ring().classList.contains('progress'), word: ring().querySelector('.ring-label').textContent.trim(), full: Number(ring().querySelector('.ring-value').getAttribute('stroke-dashoffset')) === 0 };
        push([Object.assign({}, job, { progress: null, authenticating: true, prompt: 'Steam password', securePrompt: true, status: 'Enter your Steam password below' })]);
        await waitFor(() => dialog.open);
        const prompted = { attention: ring().classList.contains('attention'), passwordField: !!dialog.querySelector('input[type="password"]'),
          guide: !!dialog.querySelector('.dialog-guide') };
        dialog.querySelector('[data-action="dismissDialog"]').click();
        await waitFor(() => !dialog.open);
        push([Object.assign({}, job, { progress: null, authenticating: true, prompt: 'Steam password', securePrompt: true })]);
        const dismissedStaysClosed = !dialog.open;
        push([Object.assign({}, job, { progress: null, authenticating: true, prompt: null, challenge: 'mobileApproval', status: 'Approve the sign-in in the Steam mobile app' })]);
        await waitFor(() => dialog.open);
        const guided = { steps: dialog.querySelectorAll('.dialog-steps li').length, icon: !!dialog.querySelector('.dialog-guide-icon svg'),
          noField: !dialog.querySelector('input'), stage: dialog.dataset.stage };
        push([Object.assign({}, job, { progress: null, authenticating: false, status: 'Downloading Workshop files…' })]);
        await waitFor(() => dialog.dataset.stage === 'started');
        const handoff = { open: dialog.open, progress: !!dialog.querySelector('.dialog-guide progress'), status: dialog.querySelector('.dialog-guide [role="status"]')?.textContent.includes('Ring fixture'),
          done: !!dialog.querySelector('.dialog-actions .primary[data-action="dismissDialog"]'), ringBusy: ring().classList.contains('busy') };
        push([Object.assign({}, job, { progress: 0.1, authenticating: false, status: 'Downloading Workshop files…' })]);
        const handoffStays = dialog.open && dialog.dataset.stage === 'started' && Number(dialog.querySelector('.dialog-guide progress').value) > 0;
        dialog.querySelector('.dialog-actions .primary[data-action="dismissDialog"]').click();
        await waitFor(() => !dialog.open);
        push([Object.assign({}, job, { progress: 0.2, authenticating: false, status: 'Downloading Workshop files…' })]);
        const resumed = ring().classList.contains('progress') && !dialog.open;
        push([Object.assign({}, job, { pending: false, progress: null, error: 'Steam denied this download.', status: 'Download could not finish' })]);
        const failed = ring()?.dataset.action === 'downloadRetry' && ring().classList.contains('failed');
        push([], { wallpapers: [{ id: 'ring-fixture', title: 'Ring fixture', kind: 'Video', preview: null, active: false, supported: true, tags: [] }] });
        const installed = { check: !!grid.querySelector('.tile-mark.installed'), noRing: !ring() };
        return { idle, progress, authenticating, phased, finishing, prompted, dismissedStaysClosed, guided, handoff, handoffStays, resumed, failed, installed };
        """, arguments: ["base": base], in: nil, contentWorld: .page) as? [String: Any]
    let idle = result?["idle"] as? [String: Any]
    XCTAssertEqual(idle?["noRing"] as? Bool, true, "An untouched tile carries no ring")
    XCTAssertEqual(
      idle?["noQueueButton"] as? Bool, true,
      "The top-bar downloads button only appears once there is download activity")
    let progress = result?["progress"] as? [String: Any]
    XCTAssertEqual(progress?["percent"] as? String, "42%", "The ring shows the measured percentage")
    XCTAssertEqual(progress?["speed"] as? String, "600 KB/s", "The ring shows the transfer speed under the percentage")
    XCTAssertEqual(progress?["cancel"] as? Bool, true, "Clicking the ring cancels that download")
    XCTAssertEqual(progress?["drawn"] as? Bool, true, "The ring stroke follows the progress value")
    XCTAssertEqual(progress?["queueButton"] as? Bool, true)
    XCTAssertEqual(
      progress?["inspectorCancel"] as? Bool, true, "The inspector offers Cancel while downloading")
    XCTAssertEqual(
      progress?["dialogClosed"] as? Bool, true, "A running download opens no dialog by itself")
    let authenticating = result?["authenticating"] as? [String: Any]
    XCTAssertEqual(authenticating?["busy"] as? Bool, true, "Sign-in without a prompt spins the ring")
    XCTAssertEqual(
      authenticating?["speed"] as? String, "600 KB/s",
      "Without a percentage the ring still carries the transfer speed")
    XCTAssertEqual(
      authenticating?["dialogClosed"] as? Bool, true,
      "A saved sign-in handoff must not open the dialog")
    let phased = result?["phased"] as? [String: Any]
    XCTAssertEqual(phased?["busy"] as? Bool, true)
    XCTAssertEqual(
      phased?["word"] as? String, "Signing in",
      "Before bytes move the ring names the SteamCMD step instead of spinning empty")
    XCTAssertEqual(phased?["phase"] as? String, "signingIn")
    XCTAssertEqual(phased?["noSpeed"] as? Bool, true)
    let finishing = result?["finishing"] as? [String: Any]
    XCTAssertEqual(finishing?["progress"] as? Bool, true)
    XCTAssertEqual(finishing?["full"] as? Bool, true, "The ring stays full while the files are validated")
    XCTAssertEqual(
      finishing?["word"] as? String, "Finishing",
      "Validation and import read as a step, not a frozen 100%")
    let prompted = result?["prompted"] as? [String: Any]
    XCTAssertEqual(prompted?["attention"] as? Bool, true, "A Steam request marks the tile")
    XCTAssertEqual(
      prompted?["passwordField"] as? Bool, true, "A password request opens the dialog by itself")
    XCTAssertEqual(
      result?["dismissedStaysClosed"] as? Bool, true,
      "Not now silences the same request until Steam asks for something else")
    XCTAssertEqual(
      prompted?["guide"] as? Bool, false, "A password request shows only the field, no guide card")
    let guided = result?["guided"] as? [String: Any]
    XCTAssertEqual(guided?["stage"] as? String, "auth")
    XCTAssertGreaterThanOrEqual(
      guided?["steps"] as? Int ?? 0, 3,
      "Mobile approval lists the phone steps, including what to answer Steam")
    XCTAssertEqual(guided?["icon"] as? Bool, true)
    XCTAssertEqual(guided?["noField"] as? Bool, true, "Mobile approval asks for nothing to type")
    let handoff = result?["handoff"] as? [String: Any]
    XCTAssertEqual(
      handoff?["open"] as? Bool, true,
      "Once Steam is satisfied the dialog confirms the download instead of vanishing")
    XCTAssertEqual(handoff?["progress"] as? Bool, true, "The confirmation carries live progress")
    XCTAssertEqual(handoff?["status"] as? Bool, true, "The confirmation names the wallpaper")
    XCTAssertEqual(handoff?["done"] as? Bool, true, "Done is the primary way out")
    XCTAssertEqual(handoff?["ringBusy"] as? Bool, true, "The tile reports meanwhile")
    XCTAssertEqual(
      result?["handoffStays"] as? Bool, true,
      "Later progress updates the confirmation instead of closing it")
    XCTAssertEqual(
      result?["resumed"] as? Bool, true,
      "After Done the dialog stays closed and the tile keeps reporting")
    XCTAssertEqual(result?["failed"] as? Bool, true, "A failed download offers retry on its tile")
    let installed = result?["installed"] as? [String: Any]
    XCTAssertEqual(installed?["check"] as? Bool, true, "A wallpaper in the library shows a check")
    XCTAssertEqual(installed?["noRing"] as? Bool, true)
  }

  func testDownloadTelemetryShowsIndeterminateProgressAndNetworkUnitsWithoutWindow() async throws {
    let fixture = makeStore()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "web-telemetry-\(UUID().uuidString)")
    let defaults = try TemporaryDefaults.make(for: self).defaults
    defer { try? FileManager.default.removeItem(at: root) }
    let workshop = WorkshopStore(
      downloader: WorkshopDownloadManager(sessionDirectory: root), supportDirectory: root,
      defaults: defaults)
    let controller = WebPanelController(
      store: fixture.store, navigation: ControlPanelNavigation(), workshop: workshop,
      defaults: defaults,
      appLanguage: .english())
    let web = controller.makeWebView()
    defer { controller.stop() }
    web.setFrameSize(NSSize(width: 960, height: 640))
    let deadline = Date().addingTimeInterval(15)
    while !controller.isReady && Date() < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertTrue(controller.isReady)
    guard controller.isReady else { return }
    let base =
      try await web.callAsyncJavaScript(
        "return await window.webkit.messageHandlers.native.postMessage({action:'ready'})",
        arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
    XCTAssertNotNil(base)
    guard let base else { return }
    controller.stop()

    let result =
      try await web.callAsyncJavaScript(
        """
        const waitFor = async predicate => {
          const deadline = Date.now() + 5000;
          while (!predicate()) {
            if (Date.now() > deadline) throw new Error('Download telemetry did not settle');
            await new Promise(resolve => setTimeout(resolve, 20));
          }
        };
        const job = {
          id: 'telemetry-fixture', wallpaperID: 'telemetry-fixture', title: 'Telemetry fixture',
          status: 'Downloading Workshop files…', preview: null, account: 'fixture',
          progress: null, pending: true, queued: false,
          bytesReceived: null, bytesExpected: null, bytesPerSecond: 600000,
          authenticating: false, cancelled: false, error: null, prompt: null,
          securePrompt: false, challenge: null, warning: null
        };
        const push = extra => window.wallpaperUI.receive(Object.assign({}, base, {
          downloads: [Object.assign({}, job, extra)], downloadRequests: [] }));
        const activity = document.getElementById('activity-bar');
        const queue = document.getElementById('queue-popover');
        push({});
        document.querySelector('#top-actions [data-action="openDownloads"]').click();
        await waitFor(() => !queue.hidden);
        const indeterminate = {
          activityProgress: !!activity.querySelector('progress') && !activity.querySelector('progress').hasAttribute('value'),
          queueProgress: !!queue.querySelector('progress') && !queue.querySelector('progress').hasAttribute('value'),
          rate: activity.textContent.includes('Network speed: 600 KB/s') && queue.textContent.includes('Network speed: 600 KB/s'),
          noPercentOrBytes: !queue.textContent.includes('%') && !queue.textContent.includes(' of ')
        };
        push({bytesPerSecond: 0});
        const zeroRate = activity.textContent.includes('Network speed: 0 B/s');
        push({bytesPerSecond: null});
        const noRate = !activity.textContent.includes('Network speed:') && !queue.textContent.includes('Network speed:');
        push({status: 'Validating and adding to your library…', bytesPerSecond: null});
        const validating = activity.textContent.includes('Validating') && !activity.textContent.includes('Network speed:');
        push({id: 'scene-assets', wallpaperID: null, status: 'Downloading Wallpaper Engine files…', progress: 0.25, bytesReceived: 250, bytesExpected: 1000, bytesPerSecond: null});
        await waitFor(() => !!activity.querySelector('progress') && activity.querySelector('progress').value === 0.25);
        const byteProgress = activity.querySelector('progress').value === 0.25 && activity.textContent.includes('25%');
        return {indeterminate, zeroRate, noRate, validating, byteProgress};
        """, arguments: ["base": base], in: nil, contentWorld: .page) as? [String: Any]
    let indeterminate = result?["indeterminate"] as? [String: Any]
    XCTAssertEqual(
      indeterminate?["activityProgress"] as? Bool, true,
      "Activity bar must render a valueless progress bar while pending")
    XCTAssertEqual(
      indeterminate?["queueProgress"] as? Bool, true,
      "Queue row must render a valueless progress bar while pending")
    XCTAssertEqual(
      indeterminate?["rate"] as? Bool, true, "Both surfaces must show the measured network speed")
    XCTAssertEqual(
      indeterminate?["noPercentOrBytes"] as? Bool, true,
      "A Workshop download without measured bytes reports neither percentage nor byte totals")
    XCTAssertEqual(result?["zeroRate"] as? Bool, true, "A measured idle rate must render as 0 B/s")
    XCTAssertEqual(
      result?["noRate"] as? Bool, true, "An unavailable rate must be omitted, not shown as zero")
    XCTAssertEqual(
      result?["validating"] as? Bool, true,
      "The validating phase must show its status without a network speed")
    XCTAssertEqual(
      result?["byteProgress"] as? Bool, true,
      "Explicit app-update bytes may still drive determinate progress")
    XCTAssertNil(web.window, "This regression must not open a desktop window")
    await workshop.steamCMDSetup.shutdown()
  }

  func testDownloadTimeLeftShowsWhenEveryRunningJobHasAnEstimate() async throws {
    let fixture = makeStore()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "web-time-left-\(UUID().uuidString)")
    let defaults = try TemporaryDefaults.make(for: self).defaults
    defer { try? FileManager.default.removeItem(at: root) }
    let workshop = WorkshopStore(
      downloader: WorkshopDownloadManager(sessionDirectory: root), supportDirectory: root,
      defaults: defaults)
    let controller = WebPanelController(
      store: fixture.store, navigation: ControlPanelNavigation(), workshop: workshop,
      defaults: defaults,
      appLanguage: .english())
    let web = controller.makeWebView()
    defer { controller.stop() }
    web.setFrameSize(NSSize(width: 960, height: 640))
    let deadline = Date().addingTimeInterval(15)
    while !controller.isReady && Date() < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertTrue(controller.isReady)
    guard controller.isReady else { return }
    let base =
      try await web.callAsyncJavaScript(
        "return await window.webkit.messageHandlers.native.postMessage({action:'ready'})",
        arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
    XCTAssertNotNil(base)
    guard let base else { return }
    controller.stop()

    let result =
      try await web.callAsyncJavaScript(
        """
        const waitFor = async predicate => {
          const deadline = Date.now() + 5000;
          while (!predicate()) {
            if (Date.now() > deadline) throw new Error('Time left did not settle');
            await new Promise(resolve => setTimeout(resolve, 20));
          }
        };
        const job = (id, extra = {}) => Object.assign({
          id, wallpaperID: id, title: id, status: 'Downloading Workshop files…', preview: null, account: 'fixture',
          progress: 0.4, pending: true, queued: false, bytesReceived: 400, bytesExpected: 1000, bytesPerSecond: 600000,
          secondsRemaining: null, authenticating: false, cancelled: false, error: null, prompt: null,
          securePrompt: false, challenge: null, warning: null }, extra);
        const push = downloads => window.wallpaperUI.receive(Object.assign({}, base, { downloads, downloadRequests: [] }));
        const activity = document.getElementById('activity-bar');
        const queue = document.getElementById('queue-popover');
        push([job('one')]);
        document.querySelector('#top-actions [data-action="openDownloads"]').click();
        await waitFor(() => !queue.hidden);
        const both = text => activity.textContent.includes(text) && queue.textContent.includes(text);
        const neither = text => !activity.textContent.includes(text) && !queue.textContent.includes(text);
        const none = neither(' left');
        push([job('one', { secondsRemaining: 45 })]);
        const seconds = both('45 sec left');
        push([job('one', { secondsRemaining: 600 })]);
        const minutes = both('10 min left');
        push([job('one', { secondsRemaining: 9000 })]);
        const hours = both('2.5 hr left');
        push([job('one', { secondsRemaining: null })]);
        const cleared = neither(' left');
        push([job('one', { secondsRemaining: 600 }), job('two', { secondsRemaining: 120 })]);
        const slowest = activity.textContent.includes('2 downloading') && activity.textContent.includes('10 min left')
          && !activity.textContent.includes('2 min left');
        push([job('one', { secondsRemaining: 600 }), job('two', { secondsRemaining: null })]);
        const unknownJob = activity.textContent.includes('2 downloading') && !activity.textContent.includes(' left');
        return {none, seconds, minutes, hours, cleared, slowest, unknownJob};
        """, arguments: ["base": base], in: nil, contentWorld: .page) as? [String: Any]
    XCTAssertEqual(result?["none"] as? Bool, true, "No estimate means no time left on screen")
    XCTAssertEqual(result?["seconds"] as? Bool, true, "Under a minute and a half reads in seconds, on both surfaces")
    XCTAssertEqual(result?["minutes"] as? Bool, true, "Minutes follow")
    XCTAssertEqual(result?["hours"] as? Bool, true, "Past an hour and a half it reads in hours")
    XCTAssertEqual(result?["cleared"] as? Bool, true, "An estimate that goes away is removed, not left stale")
    XCTAssertEqual(result?["slowest"] as? Bool, true, "Several jobs finish when the slowest does")
    XCTAssertEqual(
      result?["unknownJob"] as? Bool, true,
      "A running job without an estimate keeps the batch from promising one")
    XCTAssertNil(web.window, "This regression must not open a desktop window")
    await workshop.steamCMDSetup.shutdown()
  }

  func testDiscoverPreviewsPlayWithoutCanvasReadbackAndReleaseOffscreenImages() async throws {
    let fixture = makeStore()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "web-live-\(UUID().uuidString)")
    let defaults = try TemporaryDefaults.make(for: self).defaults
    defer { try? FileManager.default.removeItem(at: root) }
    let bright = try Self.gif(frames: 3, brightness: 0.9)
    let black = try Self.gif(frames: 9, brightness: 0, closing: 0.9)
    let still = try Self.gif(frames: 1, brightness: 0.9)
    // One download yields both the still and the animation, including an authored dark fade.
    // `c`'s still arrives last; no animation may start before it.
    let fetcher = PreviewFetcher(delay: { $0.path.contains("/c/") ? .milliseconds(400) : .zero }) { url in
      if url.path.contains("/c/") { return still }
      if url.path.contains("/b/") { return black }
      return bright
    }
    let assets = WebPanelAssets(
      thumbnailCache: WorkshopThumbnailCache(
        directory: root.appendingPathComponent("thumbs"), fetcher: fetcher))
    let workshop = WorkshopStore(
      downloader: WorkshopDownloadManager(sessionDirectory: root), supportDirectory: root,
      defaults: defaults)
    let controller = WebPanelController(
      store: fixture.store, navigation: ControlPanelNavigation(), workshop: workshop,
      defaults: defaults, assets: assets, appLanguage: .english())
    let web = controller.makeWebView()
    defer { controller.stop() }
    web.setFrameSize(NSSize(width: 960, height: 640))
    let deadline = Date().addingTimeInterval(15)
    while !controller.isReady && Date() < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertTrue(controller.isReady)
    guard controller.isReady else { return }
    let base =
      try await web.callAsyncJavaScript(
        "return await window.webkit.messageHandlers.native.postMessage({action:'ready'})",
        arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
    XCTAssertNotNil(base)
    guard let base else { return }
    controller.stop()
    assets.thumbnails = [
      "a": try XCTUnwrap(URL(string: "https://images.steamusercontent.com/ugc/a/preview/")),
      "b": try XCTUnwrap(URL(string: "https://images.steamusercontent.com/ugc/b/preview/")),
      "c": try XCTUnwrap(URL(string: "https://images.steamusercontent.com/ugc/c/preview/")),
    ]
    // `a` is also installed; the library serves its own preview for the Installed tile.
    let previousHome = ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_HOME"]
    setenv("WALLPAPER_MACHINE_HOME", root.path, 1)
    defer {
      if let previousHome { setenv("WALLPAPER_MACHINE_HOME", previousHome, 1) } else { unsetenv("WALLPAPER_MACHINE_HOME") }
    }
    let installedPreview = ClientPaths.libraryURL.appendingPathComponent("a/preview.gif")
    try FileManager.default.createDirectory(
      at: installedPreview.deletingLastPathComponent(), withIntermediateDirectories: true)
    try still.write(to: installedPreview)
    assets.previews = ["a": installedPreview]

    let result =
      try await web.callAsyncJavaScript(
        """
        const waitFor = async (predicate, what) => {
          const deadline = Date.now() + 10000;
          while (!predicate()) {
            if (Date.now() > deadline) throw new Error(`Timed out: ${what}`);
            await new Promise(resolve => setTimeout(resolve, 25));
          }
        };
        // A stalled graphics backend must not be consulted to reveal a preview. Throw rather
        // than actually hanging WebKit so the old synchronous canvas path fails deterministically.
        let canvasRequests = 0;
        HTMLCanvasElement.prototype.getContext = function() {
          canvasRequests++;
          throw new Error('Canvas rendering unavailable');
        };
        const item = id => ({ id, title: `Tile ${id}`, creator: 'Test', summary: '', preview: `https://images.steamusercontent.com/ugc/${id}/preview/`,
          thumbnail: `mwe-ui://thumbnail/${id}`, animated: `mwe-ui://animated/${id}`, tags: ['Scene'], size: 1, subscriptions: 0, kind: 'Scene' });
        const grid = document.getElementById('wallpaper-grid');
        // Records, for every animation layer the moment it is inserted, whether every still on the page had settled.
        const insertions = [];
        new MutationObserver(records => { for (const record of records) for (const node of record.addedNodes) {
          for (const live of node.nodeType === 1 ? [...(node.matches('img.tile-live') ? [node] : node.querySelectorAll('img.tile-live'))] : []) {
            const stills = [...grid.querySelectorAll('img.tile-still')];
            insertions.push(stills.length === 3 && stills.every(still => still.complete && still.naturalWidth > 0));
          } } }).observe(grid, { childList: true, subtree: true });
        window.wallpaperUI.receive(Object.assign({}, base, { page: 'discover',
          workshop: Object.assign({}, base.workshop, { items: [item('a'), item('b'), item('c')], loaded: true }), downloads: [], downloadRequests: [] }));
        const tile = id => grid.querySelector(`.wallpaper-tile[data-key="${id}"]`);
        const stillOf = id => tile(id)?.querySelector('img.tile-still');
        const liveOf = id => tile(id)?.querySelector('img.tile-live');
        const diagnose = () => `canvas requests=${canvasRequests}; ` + ['a', 'b', 'c'].map(id => `${id}: still=${stillOf(id)?.complete}/${stillOf(id)?.naturalWidth} live=${!!liveOf(id)}/${liveOf(id)?.complete}/${liveOf(id)?.naturalWidth} playing=${tile(id)?.classList.contains('playing')}`).join('; ');
        // A windowless page is hidden. First prove no animation loads, then make it visible
        // without opening a window and let real image-load events reveal the previews.
        let hiddenPlayed = null;
        try {
          if (!document.hidden) return { error: 'expected a windowless page to report itself hidden' };
          await waitFor(() => ['a', 'b', 'c'].every(id => stillOf(id)?.complete && stillOf(id).naturalWidth > 0), 'stills to load');
          hiddenPlayed = tile('a').classList.contains('playing');
          if (grid.querySelector('img.tile-live')) throw new Error('hidden previews must not load animations');
          Object.defineProperty(document, 'hidden', { configurable: true, get: () => false });
          document.dispatchEvent(new Event('visibilitychange'));
          await waitFor(() => tile('a')?.classList.contains('playing') && tile('b')?.classList.contains('playing'), 'both animations to play without canvas access');
          await waitFor(() => !liveOf('c'), 'single-frame preview to keep its still');
        } catch (error) { return { error: `${error.message} — ${diagnose()}` }; }
        await new Promise(resolve => setTimeout(resolve, 700));
        const discover = {
          stillsFirst: insertions.length >= 2 && insertions.every(Boolean),
          eagerStills: ['a', 'b', 'c'].every(id => stillOf(id).loading !== 'lazy'),
          aPlaying: tile('a').classList.contains('playing'), aStillKept: !!stillOf('a'),
          bLoaded: !!liveOf('b'), bPlaying: tile('b').classList.contains('playing'),
          cLive: !!liveOf('c'), cStill: !!stillOf('c'), hiddenPlayed,
        };
        // A failed animation returns to the cached still instead of leaving an empty tile.
        liveOf('b').dispatchEvent(new Event('error'));
        discover.failedAnimationFallback = !liveOf('b') && !!stillOf('b') && !tile('b').classList.contains('playing');
        // Shrink to one visible tile. Scrolling releases offscreen decoders, but returning
        // to a tile reuses the disk cache. A failed/single-frame animation is not retried.
        grid.style.gridTemplateColumns = '1fr'; grid.style.maxHeight = '160px';
        grid.scrollTop = 0;
        window.dispatchEvent(new Event('resize'));
        try {
          await waitFor(() => !!liveOf('a') && !liveOf('b'), 'offscreen animation to retire');
          const previous = liveOf('a');
          grid.scrollTop = grid.scrollHeight;
          grid.dispatchEvent(new Event('scroll'));
          await waitFor(() => !liveOf('a'), 'scrolled animation to retire');
          discover.retiredSource = !previous.hasAttribute('src') && !previous.isConnected;
          discover.failedPreviewRetried = !!liveOf('c');
          grid.scrollTop = 0;
          grid.dispatchEvent(new Event('scroll'));
          await waitFor(() => liveOf('a')?.complete && tile('a').classList.contains('playing'), 'animation to resume after scrolling');
          Object.defineProperty(document, 'hidden', { configurable: true, get: () => true });
          document.dispatchEvent(new Event('visibilitychange'));
          discover.hiddenAnimations = grid.querySelectorAll('img.tile-live').length;
          Object.defineProperty(document, 'hidden', { configurable: true, get: () => false });
          document.dispatchEvent(new Event('visibilitychange'));
          await waitFor(() => tile('a').classList.contains('playing'), 'animation to resume after hiding');
          window.wallpaperUI.receive(Object.assign({}, base, { page: 'settings' }));
          discover.settingsAnimations = grid.querySelectorAll('img.tile-live').length;
        } catch (error) { return { error: `${error.message} — ${diagnose()}` }; }
        // Leaving Discover while `a` plays: its Installed tile must show the library still.
        window.wallpaperUI.receive(Object.assign({}, base, { page: 'installed',
          wallpapers: [{ id: 'a', title: 'Tile a', kind: 'Scene', preview: 'mwe-ui://preview/a', active: false, supported: true, tags: [] }] }));
        try {
          await waitFor(() => stillOf('a')?.getAttribute('src') === 'mwe-ui://preview/a' && stillOf('a').complete && stillOf('a').naturalWidth > 0, 'the installed still to load');
        } catch (error) { return { error: `${error.message} — ${diagnose()}` }; }
        await new Promise(resolve => setTimeout(resolve, 500));
        return Object.assign(discover, {
          canvasRequests,
          installedStillOpacity: getComputedStyle(stillOf('a')).opacity, installedLive: !!liveOf('a'),
        });
        """, arguments: ["base": base], in: nil, contentWorld: .page) as? [String: Any]
    XCTAssertNil(result?["error"], (result?["error"] as? String) ?? "")
    XCTAssertEqual(
      result?["stillsFirst"] as? Bool, true,
      "No animation starts before every still on the page has arrived")
    XCTAssertEqual(result?["eagerStills"] as? Bool, true, "Discover stills are not lazy-loaded")
    XCTAssertEqual(
      result?["hiddenPlayed"] as? Bool, false,
      "A hidden page does not load or reveal animations")
    XCTAssertEqual(result?["canvasRequests"] as? Int, 0, "Preview playback never waits on synchronous canvas rendering")
    XCTAssertEqual(result?["failedAnimationFallback"] as? Bool, true, "A failed animation reveals its cached still")
    XCTAssertEqual(result?["retiredSource"] as? Bool, true, "Offscreen images release their source and leave the DOM")
    XCTAssertEqual(result?["failedPreviewRetried"] as? Bool, false, "Scrolling does not retry a single-frame preview")
    XCTAssertEqual(result?["hiddenAnimations"] as? Int, 0, "Hiding the page releases all animation sources")
    XCTAssertEqual(result?["settingsAnimations"] as? Int, 0, "Settings retains no Discover animation sources")
    XCTAssertEqual(result?["aPlaying"] as? Bool, true, "A loaded animation replaces its still")
    XCTAssertEqual(result?["aStillKept"] as? Bool, true, "The still stays available as a fallback")
    XCTAssertEqual(result?["bLoaded"] as? Bool, true, "A dark animation also loads")
    XCTAssertEqual(
      result?["bPlaying"] as? Bool, true, "Authored dark frames play without synchronous brightness checks")
    XCTAssertEqual(result?["cLive"] as? Bool, false, "A single-frame preview gets no animation layer")
    XCTAssertEqual(result?["cStill"] as? Bool, true)
    XCTAssertEqual(
      result?["installedStillOpacity"] as? String, "1",
      "A wallpaper whose animation played on Discover shows its still on the Installed page")
    XCTAssertEqual(result?["installedLive"] as? Bool, false, "Installed tiles carry no animation layer")
    XCTAssertEqual(
      Set(fetcher.requests).count, fetcher.requests.count,
      "Each preview is downloaded once: its still and its animation share the bytes")
    XCTAssertEqual(fetcher.requests.count, 3)
    XCTAssertNil(web.window, "This regression must not open a desktop window")
    await workshop.steamCMDSetup.shutdown()
  }

  /// **Download and apply** sits under Download for a wallpaper that can run and a target display
  /// that can show it, says what is pending while the choice stands, and explains a wallpaper that
  /// arrived and was left alone. One click asks Swift to apply it on arrival.
  func testDownloadAndApplyIsOfferedOnlyWhereItCanApplyAndTheInspectorSaysWhatIsPending() async throws {
    try await withPanel { panel in
      try await panel.finishWelcome()
      panel.workshop.selectedItem = WorkshopItem(
        id: "111", title: "W111", creator: "Test", summary: "", previewURL: nil, tags: ["Video"],
        size: 2048, subscriptions: 0)
      panel.show()
      try await panel.waitJS("powerProbe.received.length >= 1")
      let result = try await panel.js("""
        const base = window.powerProbe.received.at(-1);
        const item = (id, kind = 'Video', extra = {}) => Object.assign({ id, title: 'W' + id, creator: 'Test', summary: '', preview: null, thumbnail: null, animated: null, tags: [kind], approved: false, size: 2048, subscriptions: 0, kind, creatorID: null, collection: false, collectionSize: 0 }, extra);
        const items = [item('111'), item('222', 'Application'), item('333', 'Video', { collection: true, collectionSize: 4 }), item('444'), item('555'), item('666')];
        const installed = [{ id: '444', title: 'W444', kind: 'Video', size: 100, preview: null, active: false, supported: true, tags: [] }];
        const job = (id, extra = {}) => Object.assign({ id, wallpaperID: id, title: 'W' + id, status: '', preview: null, thumbnail: null, account: '', phase: null, progress: null, pending: true, queued: true, paused: false, cancelled: false, error: null, applyOnArrival: false }, extra);
        const request = (id, extra = {}) => Object.assign({ id, wallpaperID: id, title: 'W' + id, preview: null, thumbnail: null, account: '', rememberSession: true, stage: 'setup', paused: false, applyOnArrival: false }, extra);
        const show = (id, extra = {}) => {
          window.wallpaperUI.receive(Object.assign({}, base, { page: 'discover', targetDisplayID: 'primary',
            workshop: Object.assign({}, base.workshop, { items, loaded: true, selectedID: id }),
            wallpapers: [], downloads: [], downloadRequests: [], applyNotes: {} }, extra));
          const inspector = document.getElementById('inspector');
          return { apply: !!inspector.querySelector('[data-action="requestDownloadAndApply"][data-id="' + id + '"]'),
                   plain: !!inspector.querySelector('[data-action="requestDownload"][data-id="' + id + '"]'),
                   pending: inspector.querySelector('.inspector-apply-intent')?.textContent.trim() || '',
                   note: inspector.querySelector('.inspector-apply-note')?.textContent.trim() || '' };
        };
        const mirrored = base.displays.map(display => Object.assign({}, display, { mode: 'mirror', mirrorTarget: 'other' }));
        const showing = base.displays.map(display => Object.assign({}, display, { wallpaperID: '111' }));
        const note = 'Downloaded, but not applied because you chose another wallpaper.';
        const facts = {
          video: show('111'), application: show('222'), collection: show('333'),
          installed: show('444', { wallpapers: installed }),
          downloading: show('555', { downloads: [job('555')] }),
          downloadingToApply: show('555', { downloads: [job('555', { applyOnArrival: true })] }),
          waitingToApply: show('666', { downloadRequests: [request('666', { applyOnArrival: true })] }),
          mirrorTarget: show('111', { displays: mirrored }),
          withNote: show('111', { applyNotes: { '111': note } }),
          noteOnceShown: show('111', { applyNotes: { '111': note }, displays: showing }),
        };
        // Choosing it asks native to apply it on arrival; the plain button asks for nothing more.
        window.sent = [];
        const native = window.webkit.messageHandlers.native;
        const original = native.postMessage.bind(native);
        native.postMessage = message => { window.sent.push(message); return original(message); };
        show('111');
        document.querySelector('#inspector [data-action="requestDownloadAndApply"]').click();
        return { facts, note };
        """) as? [String: Any]
      let facts = try XCTUnwrap(result?["facts"] as? [String: [String: Any]])
      func offered(_ key: String) -> Bool? { facts[key]?["apply"] as? Bool }
      XCTAssertEqual(offered("video"), true)
      XCTAssertEqual(facts["video"]?["plain"] as? Bool, true, "Download stays as it was beside it")
      XCTAssertEqual(offered("application"), false, "An Application cannot run on macOS")
      XCTAssertEqual(offered("collection"), false, "A collection is opened, not downloaded")
      XCTAssertEqual(offered("installed"), false, "An installed wallpaper is applied, not downloaded")
      XCTAssertEqual(offered("downloading"), false, "A download under way is where the person looks")
      XCTAssertEqual(offered("waitingToApply"), false)
      XCTAssertEqual(offered("mirrorTarget"), false, "A display mirroring another shows no wallpaper of its own")

      XCTAssertEqual(facts["downloading"]?["pending"] as? String, "", "A plain download promises no apply")
      XCTAssertNotEqual(facts["downloadingToApply"]?["pending"] as? String, "", "A running download says it will apply")
      XCTAssertNotEqual(facts["waitingToApply"]?["pending"] as? String, "", "So does one waiting for setup")
      XCTAssertEqual(facts["withNote"]?["note"] as? String, result?["note"] as? String, "A wallpaper left alone says why")
      XCTAssertEqual(facts["noteOnceShown"]?["note"] as? String, "", "The reason is moot once the display shows it")

      try await panel.waitUntil { panel.workshop.appliesOnArrival("111") }
      let sent = try await panel.js("return window.sent.map(message => ({ action: message.action, id: message.id, apply: message.apply }))")
        as? [[String: Any]]
      let request = sent?.first { $0["action"] as? String == "requestDownload" }
      XCTAssertEqual(request?["id"] as? String, "111")
      XCTAssertEqual(request?["apply"] as? Bool, true)
    }
  }

  /// `closing`, when given, is the brightness of a last frame shown for a fiftieth of a second
  /// between seconds-long frames of `brightness`.
}
