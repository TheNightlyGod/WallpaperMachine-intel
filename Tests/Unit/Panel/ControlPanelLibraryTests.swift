import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import XCTest

@testable import WallpaperMachine

/// Installed page: sorting, tile marks, filter sidebar, download setup and error dismissal.
@MainActor
final class ControlPanelLibraryTests: ControlPanelTestCase {
  private func finishWelcome(in web: WKWebView) async throws {
    XCTAssertNil(web.window, "Every panel behavior check must remain offscreen")
    _ = try await web.callAsyncJavaScript(
      """
      const welcome = document.getElementById('welcome');
      if (!welcome.hidden) {
        welcome.querySelector('[data-action="go"][data-step="5"]').click();
        welcome.querySelector('[data-action="finish"]').click();
      }
      const deadline = Date.now() + 5000;
      while (!welcome.hidden || !(await window.webkit.messageHandlers.native.postMessage({action:'ready'})).welcomeSeen) {
        if (Date.now() > deadline) throw new Error('Welcome did not finish');
        await new Promise(resolve => setTimeout(resolve, 20));
      }
      """, arguments: [:], in: nil, contentWorld: .page)
  }

  /// Both library pages share one right-hand filter sidebar whose only switch is the
  /// toolbar's Filter button: no rail, no collapse control inside the sidebar, and no
  /// popover on Installed. Each page remembers its own choice natively because the
  /// page's website data store is not persistent. The inspector's width is a function of
  /// the window width alone: there is no drag handle, nothing is stored, and a width
  /// left behind by an earlier build is discarded rather than applied.
  func testFilterSidebarTogglesFromTheToolbarPerPageAndInspectorFollowsWindowWidth() async throws {
    let fixture = makeStore()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "web-filters-\(UUID().uuidString)")
    let defaults = try TemporaryDefaults.make(for: self).defaults
    defer { try? FileManager.default.removeItem(at: root) }
    let workshop = WorkshopStore(
      downloader: WorkshopDownloadManager(sessionDirectory: root), supportDirectory: root,
      defaults: defaults)
    let navigation = ControlPanelNavigation()
    // A width dragged in an earlier build must neither be applied nor kept.
    defaults.set(320.0, forKey: WebPanelController.legacyInspectorWidthKey)
    let controller = WebPanelController(
      store: fixture.store, navigation: navigation, workshop: workshop, defaults: defaults,
      appLanguage: .english())
    XCTAssertNil(
      defaults.object(forKey: WebPanelController.legacyInspectorWidthKey),
      "A stored inspector width from an earlier build is cleared on launch")
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
    let script = """
      const waitFor = async predicate => {
        const deadline = Date.now() + 5000;
        while (!predicate()) {
          if (Date.now() > deadline) throw new Error('Filter sidebar did not settle');
          await new Promise(resolve => setTimeout(resolve, 20));
        }
      };
      const native = { postMessage: async body => {
        try { return await window.webkit.messageHandlers.native.postMessage(body); }
        catch (error) { throw new Error(`${body.action} failed: ${error?.message || error}`); }
      } };
      const showDiscover = snapshot => window.wallpaperUI.receive(Object.assign({}, snapshot, {
        page: 'discover',
        workshop: Object.assign({}, snapshot.workshop, {
          page: 1, totalPages: 1, loaded: true, loading: false, items: [], error: null
        })
      }));
      const columns = () => getComputedStyle(document.getElementById('library-page')).gridTemplateColumns.split(' ').map(v => Math.round(parseFloat(v)));
      const toggle = () => document.querySelector('.browser-toolbar [data-action="toggleFilters"]');
      const measure = () => {
        const sidebar = document.getElementById('filter-sidebar');
        const bar = document.querySelector('.browser-toolbar').getBoundingClientRect();
        const button = toggle();
        const rect = button.getBoundingClientRect();
        return {
          hidden: sidebar.hidden,
          expanded: button.getAttribute('aria-expanded'),
          glyph: !!button.querySelector('svg'),
          // The button leads the toolbar and sits beside the sidebar it opens.
          first: Math.round(rect.left - bar.left) <= 17,
          besideSidebar: sidebar.hidden ? null : Math.round(sidebar.getBoundingClientRect().right) <= Math.round(rect.left),
          sidebarLeftOfGrid: sidebar.hidden ? null : sidebar.getBoundingClientRect().right <= document.querySelector('.browser-column').getBoundingClientRect().left + 1,
          sidebarAtLeftEdge: sidebar.hidden ? null : Math.round(sidebar.getBoundingClientRect().left) === 0,
          insideToggles: sidebar.querySelectorAll('[data-action="toggleFilters"], .filter-rail, .filter-toggle').length,
          popover: document.querySelectorAll('.installed-filter, .filter-popover').length,
          direction: !!document.querySelector('.browser-toolbar [data-action="toggleSortDirection"]'),
          selects: sidebar.querySelectorAll('select').length,
          filterCount: document.querySelector('.browser-toolbar .filter-count')?.textContent ?? null,
          columns: columns()
        };
      };
      await waitFor(() => Math.round(window.innerWidth) === 960);
      showDiscover(await native.postMessage({action:'ready'}));
      const before = measure();
      toggle().click();
      // The native reply re-renders on its own page (Installed, whose sidebar is still
      // open), so the round trip is complete once native reports Discover's choice.
      let reply;
      const settle = Date.now() + 5000;
      while (!(reply = await native.postMessage({action:'ready'})).filtersCollapsed?.discover) {
        if (Date.now() > settle) throw new Error('Filter choice did not reach native');
        await new Promise(resolve => setTimeout(resolve, 20));
      }
      showDiscover(reply);
      const after = measure();
      window.wallpaperUI.receive(Object.assign({}, reply, {page: 'installed'}));
      const installed = measure();
      showDiscover(reply);
      const inspector = document.getElementById('inspector');
      return {before, after, installed,
              separators: document.querySelectorAll('[role="separator"], [class*="resizer"]').length,
              snapshotWidth: 'inspectorWidth' in reply,
              inspectorWidth: Math.round(inspector.getBoundingClientRect().width),
              inspectorCursor: getComputedStyle(inspector).cursor};
      """
    XCTAssertNil(web.window, "Every panel behavior check must remain offscreen")
    let result =
      try await web.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
      as? [String: Any]
    let before = result?["before"] as? [String: Any]
    XCTAssertEqual(before?["hidden"] as? Bool, false)
    XCTAssertEqual(before?["expanded"] as? String, "true")
    XCTAssertEqual(before?["glyph"] as? Bool, true, "…with a filter glyph beside the label")
    XCTAssertEqual(before?["first"] as? Bool, true, "…leading the toolbar, beside the sidebar")
    XCTAssertEqual(before?["besideSidebar"] as? Bool, true)
    XCTAssertEqual(before?["sidebarLeftOfGrid"] as? Bool, true, "The sidebar is on the left of the grid")
    XCTAssertEqual(before?["sidebarAtLeftEdge"] as? Bool, true, "…at the window's left edge; the inspector keeps the right")
    XCTAssertEqual(before?["insideToggles"] as? Int, 0, "The sidebar carries no collapse control of its own")
    XCTAssertEqual((before?["columns"] as? [Int])?.count, 3, "Discover starts with the sidebar column")
    XCTAssertEqual((before?["columns"] as? [Int])?.first, 160, "The sidebar is the first column (160px below 1040px)")
    XCTAssertEqual((before?["columns"] as? [Int])?.last, 290, "A 960px window gets a 290px inspector (15vw + 146px)")
    let after = result?["after"] as? [String: Any]
    XCTAssertEqual(after?["hidden"] as? Bool, true, "Closing removes the sidebar entirely; no rail remains")
    XCTAssertEqual(after?["expanded"] as? String, "false")
    XCTAssertEqual(after?["first"] as? Bool, true, "The Filter button stays where it was so it can reopen the sidebar")
    XCTAssertEqual((after?["columns"] as? [Int])?.count, 2, "Closed, the grid takes the sidebar's column")
    XCTAssertEqual(result?["separators"] as? Int, 0, "The inspector edge is not a drag handle")
    XCTAssertEqual(result?["snapshotWidth"] as? Bool, false, "The snapshot carries no inspector width")
    XCTAssertEqual(result?["inspectorWidth"] as? Int, 290, "The grid column and the rendered inspector agree")
    XCTAssertEqual(result?["inspectorCursor"] as? String, "auto", "Nothing invites resizing")
    let installed = result?["installed"] as? [String: Any]
    XCTAssertEqual(installed?["hidden"] as? Bool, false, "Installed has its own sidebar, still open after Discover's was closed")
    XCTAssertEqual(installed?["expanded"] as? String, "true")
    XCTAssertEqual(installed?["first"] as? Bool, true)
    XCTAssertEqual(installed?["popover"] as? Int, 0, "The old Filters popover is gone")
    XCTAssertEqual(installed?["insideToggles"] as? Int, 0)
    XCTAssertEqual((installed?["columns"] as? [Int])?.count, 3)
    XCTAssertEqual(installed?["direction"] as? Bool, true, "…and a direction switch beside it")
    XCTAssertEqual(installed?["selects"] as? Int, 0, "No type menu on Installed either")
    XCTAssertNil(installed?["filterCount"] as? String)
    XCTAssertEqual(before?["direction"] as? Bool, false, "Discover's Steam sorts have no direction")
    XCTAssertEqual(before?["selects"] as? Int, 0, "No type menu: types are boxes like Wallpaper Engine's")
    XCTAssertNil(before?["filterCount"] as? String, "Defaults count as no active filter")
    XCTAssertNil(controller.actionError)
    XCTAssertNil(defaults.object(forKey: WebPanelController.legacyInspectorWidthKey))
    let relaunched = WebPanelController(
      store: fixture.store, navigation: ControlPanelNavigation(), workshop: workshop,
      defaults: defaults, appLanguage: .english())
    XCTAssertEqual(relaunched.filtersCollapsed["discover"], true,
      "Discover's collapsed choice must survive a relaunch")
    XCTAssertEqual(relaunched.filtersCollapsed["installed"], false,
      "Collapsing Discover must leave Installed open after relaunch")
    XCTAssertNil(relaunched.snapshot()["inspectorWidth"], "No inspector width is published")

    // The width is the same function of the window on both pages: 260px at the 760px
    // minimum, 15vw + 146px in between, 420px from about 1830px on. The window is
    // widened and narrowed in turn so the value cannot be an artefact of the order.
    let expectations: [(width: Double, page: String, inspector: Int)] = [
      (1600, "discover", 386), (760, "discover", 260), (760, "installed", 260),
      (2000, "installed", 420), (1040, "installed", 302), (1040, "discover", 302),
    ]
    for expectation in expectations {
      web.setFrameSize(NSSize(width: expectation.width, height: 900))
      XCTAssertNil(web.window, "Every panel behavior check must remain offscreen")
      let measured =
        try await web.callAsyncJavaScript(
          """
          const snapshot = await window.webkit.messageHandlers.native.postMessage({action:'ready'});
          window.wallpaperUI.receive(Object.assign({}, snapshot, {
            page, workshop: Object.assign({}, snapshot.workshop, {page: 1, totalPages: 1, loaded: true, loading: false, items: [], error: null})
          }));
          const deadline = Date.now() + 5000;
          while (Math.round(window.innerWidth) !== expected) {
            if (Date.now() > deadline) throw new Error(`Viewport did not reach ${expected}px`);
            await new Promise(resolve => setTimeout(resolve, 20));
          }
          const columns = getComputedStyle(document.getElementById('library-page')).gridTemplateColumns.split(' ').map(v => Math.round(parseFloat(v)));
          return {inspector: Math.round(document.getElementById('inspector').getBoundingClientRect().width),
                  last: columns.at(-1), sum: columns.reduce((a, b) => a + b, 0)};
          """, arguments: ["page": expectation.page, "expected": expectation.width], in: nil,
          contentWorld: .page) as? [String: Any]
      XCTAssertEqual(
        measured?["inspector"] as? Int, expectation.inspector,
        "At \(Int(expectation.width))px on \(expectation.page) the inspector is \(expectation.inspector)px wide")
      XCTAssertEqual(measured?["last"] as? Int, expectation.inspector, "The grid column matches the inspector")
      XCTAssertEqual(
        measured?["sum"] as? Int, Int(expectation.width),
        "The columns fill the window exactly at \(Int(expectation.width))px on \(expectation.page)")
    }
    XCTAssertNil(web.window)
    await workshop.steamCMDSetup.shutdown()
  }

  /// Installed sorts by name, type, favorites, folder size or date added, in either
  /// direction: picking a key starts in the direction people ask for it (names A→Z,
  /// the rest largest / newest / starred first), the direction button flips it, names
  /// break ties, and wallpapers whose folder has not been measured yet sort last.
  func testInstalledSortsByEveryKeyInBothDirectionsWithoutWindow() async throws {
    try await withPanel { panel in
      try await panel.finishWelcome()
      panel.show()
      try await panel.waitJS("powerProbe.received.length >= 1")
      let order = try await panel.js("""
        const base = window.powerProbe.received.at(-1);
        const wallpaper = (id, title, kind, size, addedAt) => ({ id, title, kind, size, addedAt, preview: null, active: false, supported: true, tags: [] });
        const wallpapers = [
          wallpaper('b', 'Beta', 'Video', 300, 3000), wallpaper('a', 'alpha', 'Scene', 100, null),
          wallpaper('c', 'Gamma', 'Scene', null, 1000), wallpaper('d', 'Delta', 'Web', 200, 2000),
        ];
        window.wallpaperUI.receive(Object.assign({}, base, { page: 'installed', wallpapers, favorites: ['c', 'a'] }));
        const titles = () => [...document.querySelectorAll('.tile-title')].map(node => node.textContent);
        const sort = document.getElementById('browser-sort');
        const pick = value => { sort.value = value; sort.dispatchEvent(new Event('change', { bubbles: true })); };
        const flip = () => document.querySelector('[data-action="toggleSortDirection"]').click();
        const result = { initial: titles() };
        for (const key of ['type', 'favorites', 'size', 'added', 'title']) {
          pick(key);
          result[key] = titles();
          flip();
          result[`${key}Flipped`] = titles();
        }
        return result;
        """) as? [String: Any]
      XCTAssertEqual(order?["initial"] as? [String], ["alpha", "Beta", "Delta", "Gamma"], "Names A→Z by default, case-insensitively")
      XCTAssertEqual(order?["type"] as? [String], ["alpha", "Gamma", "Beta", "Delta"], "Type, names breaking ties")
      XCTAssertEqual(order?["typeFlipped"] as? [String], ["Delta", "Beta", "alpha", "Gamma"])
      XCTAssertEqual(order?["favorites"] as? [String], ["alpha", "Gamma", "Beta", "Delta"], "Favorites first")
      XCTAssertEqual(order?["favoritesFlipped"] as? [String], ["Beta", "Delta", "alpha", "Gamma"])
      XCTAssertEqual(order?["size"] as? [String], ["Beta", "Delta", "alpha", "Gamma"], "Largest first; an unmeasured folder sorts last")
      XCTAssertEqual(order?["sizeFlipped"] as? [String], ["alpha", "Delta", "Beta", "Gamma"], "…in both directions")
      XCTAssertEqual(order?["added"] as? [String], ["Beta", "Delta", "Gamma", "alpha"], "Newest first; no date sorts last")
      XCTAssertEqual(order?["addedFlipped"] as? [String], ["Gamma", "Delta", "Beta", "alpha"])
      XCTAssertEqual(order?["title"] as? [String], ["alpha", "Beta", "Delta", "Gamma"], "Choosing a key resets to its natural direction")
      XCTAssertEqual(order?["titleFlipped"] as? [String], ["Gamma", "Delta", "Beta", "alpha"])
    }
  }

  /// Installed's sidebar filters the library with Discover's rules: a ticked Show only box
  /// requires its tag (Favorites and Active on top of Steam's three), an unticked box
  /// excludes wallpapers carrying that tag, the type boxes read the wallpaper's kind, a
  /// wallpaper without a genre counts as Unspecified, and Clear puts every box back.
  func testInstalledFiltersTheLibraryWithDiscoverBoxesWithoutWindow() async throws {
    try await withPanel { panel in
      try await panel.finishWelcome()
      panel.show()
      try await panel.waitJS("powerProbe.received.length >= 1")
      let result = try await panel.js("""
        const base = window.powerProbe.received.at(-1);
        const wallpaper = (id, kind, tags, approved = false) => ({ id, title: id, kind, tags, approved, preview: null, active: false, supported: true, size: 1, addedAt: 1 });
        const wallpapers = [
          wallpaper('anime', 'Scene', ['anime', 'Everyone', 'Audio responsive'], true),
          wallpaper('nature', 'Video', ['Nature', 'Mature']),
          wallpaper('plain', 'Web', ['Everyone', 'Customizable']),
          wallpaper('bare', 'Unknown', []),
        ];
        const display = Object.assign({}, base.displays[0], { wallpaperID: 'nature' });
        window.wallpaperUI.receive(Object.assign({}, base, { page: 'installed', wallpapers, favorites: ['plain'], displays: [display], targetDisplayID: display.id }));
        const sidebar = document.getElementById('filter-sidebar');
        const titles = () => [...document.querySelectorAll('.tile-title')].map(node => node.textContent);
        const box = value => sidebar.querySelector(`input[value="${value}"]`);
        const tick = (value, on) => { const input = box(value); input.checked = on; input.dispatchEvent(new Event('change', { bubbles: true })); };
        const count = () => document.querySelector('.browser-toolbar .filter-count')?.textContent ?? null;
        const result = { all: titles() };
        tick('Favorite', true); result.favorites = titles(); result.favoritesCount = count();
        tick('Favorite', false); tick('Active', true); result.active = titles();
        tick('Active', false); tick('Approved', true); result.approved = titles();
        tick('Approved', false); tick('Audio responsive', true); result.audio = titles();
        tick('Audio responsive', false); tick('Customizable', true); result.customizable = titles();
        tick('Customizable', false); tick('Anime', false); result.noAnime = titles();
        tick('Unspecified', false); result.noUnspecified = titles(); result.noneCount = count();
        document.querySelector('.filter-heading [data-action="clearInstalled"]').click();
        result.cleared = titles(); result.clearedCount = count();
        tick('Mature', false); result.noMature = titles();
        tick('Video', false); tick('Web', false); result.noVideoWeb = titles();
        sidebar.querySelector('.filter-section[data-key="genre"] [data-action="excludeSection"]').click();
        result.noGenre = titles();
        document.querySelector('.filter-heading [data-action="clearInstalled"]').click();
        document.getElementById('wallpaper-search').value = 'nat';
        document.getElementById('wallpaper-search').dispatchEvent(new Event('input', { bubbles: true }));
        result.searched = titles();
        return result;
        """) as? [String: Any]
      XCTAssertEqual(result?["all"] as? [String], ["anime", "bare", "nature", "plain"], "Nothing is hidden by default")
      XCTAssertEqual(result?["favorites"] as? [String], ["plain"], "Favorites is a Show only box")
      XCTAssertEqual(result?["favoritesCount"] as? String, "1")
      XCTAssertEqual(result?["active"] as? [String], ["nature"], "So is Active on target display")
      XCTAssertEqual(result?["approved"] as? [String], ["anime"], "Approved reads the snapshot's approval")
      XCTAssertEqual(result?["audio"] as? [String], ["anime"], "Audio responsive and Customizable read the manifest tags")
      XCTAssertEqual(result?["customizable"] as? [String], ["plain"])
      XCTAssertEqual(result?["noAnime"] as? [String], ["bare", "nature", "plain"], "Unticking a tag hides wallpapers carrying it, whatever its case")
      XCTAssertEqual(result?["noUnspecified"] as? [String], ["nature"], "A wallpaper without a genre is Unspecified")
      XCTAssertEqual(result?["noneCount"] as? String, "2", "Each unticked box counts as one active filter")
      XCTAssertEqual(result?["cleared"] as? [String], ["anime", "bare", "nature", "plain"], "Clear ticks every box again")
      XCTAssertNil(result?["clearedCount"] as? String)
      XCTAssertEqual(result?["noMature"] as? [String], ["anime", "bare", "plain"], "Age rating reads the manifest's content rating")
      XCTAssertEqual(result?["noVideoWeb"] as? [String], ["anime", "bare"], "Type boxes read the kind; a kind Steam has no box for stays")
      XCTAssertEqual(result?["noGenre"] as? [String], [], "None on Tags hides every wallpaper, Unspecified included")
      XCTAssertEqual(result?["searched"] as? [String], ["nature"], "Search still narrows by title and tags")
    }
  }

  /// Tiles wear Wallpaper Engine's corner marks: a green trophy for a staff-approved
  /// wallpaper and a heart for a favorite, on Installed and Discover alike, plus the
  /// library check on Discover. The marks step aside with the Active badge while the
  /// select check is showing, and the favorite toggle itself no longer stays lit.
  func testTilesWearApprovedAndFavoriteMarksWithoutWindow() async throws {
    try await withPanel { panel in
      try await panel.finishWelcome()
      panel.show()
      try await panel.waitJS("powerProbe.received.length >= 1")
      let result = try await panel.js("""
        const base = window.powerProbe.received.at(-1);
        const wallpaper = (id, title, approved) => ({ id, title, kind: 'Scene', approved, preview: null, active: false, supported: true, tags: [], size: 1, addedAt: 1 });
        const wallpapers = [wallpaper('a', 'Approved', true), wallpaper('b', 'Loved', false), wallpaper('c', 'Both', true), wallpaper('d', 'Plain', false)];
        const display = Object.assign({}, base.displays[0], { wallpaperID: 'c' });
        window.wallpaperUI.receive(Object.assign({}, base, { page: 'installed', wallpapers, favorites: ['b', 'c'], displays: [display], targetDisplayID: display.id }));
        const tile = id => document.querySelector(`.wallpaper-tile [data-id="${id}"]`).closest('.wallpaper-tile');
        const marks = id => [...tile(id).querySelectorAll('.tile-mark')].map(node => node.className.replace('tile-mark', '').trim());
        const clears = (following, preceding) => following.getBoundingClientRect().left >= preceding.getBoundingClientRect().right;
        const installed = {
          a: marks('a'), b: marks('b'), c: marks('c'), d: marks('d'),
          announced: tile('c').querySelector('.tile-select').getAttribute('aria-label').split(', ').length - tile('d').querySelector('.tile-select').getAttribute('aria-label').split(', ').length,
          toggleHidden: getComputedStyle(tile('b').querySelector('.tile-favorite')).opacity === '0',
          badgeAfterMarks: clears(tile('c').querySelector('.active-badge'), tile('c').querySelector('.tile-marks')),
        };
        tile('c').querySelector('.tile-select').focus();
        tile('c').querySelector('.tile-check').click();
        await new Promise(resolve => setTimeout(resolve, 50));
        // The marks slide into place (`transition: left`), and an offscreen web view never
        // services a transition, so the measured position would stay at its start value.
        document.getAnimations().forEach(animation => animation.finish());
        const checked = {
          marksClearCheck: clears(tile('c').querySelector('.tile-marks'), tile('c').querySelector('.tile-check')),
          badgeClearMarks: clears(tile('c').querySelector('.active-badge'), tile('c').querySelector('.tile-marks')),
        };
        const item = (id, tags) => ({ id, title: id, creator: 'Test', summary: '', preview: null, thumbnail: null, tags, size: 1, subscriptions: 0, kind: 'Scene', approved: tags.includes('Approved') });
        window.wallpaperUI.receive(Object.assign({}, base, { page: 'discover', wallpapers, favorites: ['b', 'c'], downloads: [], downloadRequests: [],
          workshop: Object.assign({}, base.workshop, { items: [item('c', ['Approved', 'Scene']), item('x', ['Approved']), item('y', ['Scene'])], loaded: true }) }));
        const discover = { c: marks('c'), x: marks('x'), y: marks('y'), noCheck: !tile('x').querySelector('.tile-check') };
        return { installed, checked, discover };
        """) as? [String: Any]
      let installed = result?["installed"] as? [String: Any]
      XCTAssertEqual(installed?["a"] as? [String], ["approved"], "An approved wallpaper wears the trophy")
      XCTAssertEqual(installed?["b"] as? [String], ["favorite"], "A favorite wears the heart")
      XCTAssertEqual(installed?["c"] as? [String], ["approved", "favorite"], "Both stack, trophy first")
      XCTAssertEqual(installed?["d"] as? [String], [], "A plain wallpaper wears nothing")
      XCTAssertEqual(installed?["announced"] as? Int, 2, "Screen readers hear both marks on the tile's own label")
      XCTAssertEqual(installed?["toggleHidden"] as? Bool, true, "The favorite toggle waits for hover; the heart mark carries the state")
      XCTAssertEqual(installed?["badgeAfterMarks"] as? Bool, true, "The Active badge sits after the marks")
      let checked = result?["checked"] as? [String: Any]
      XCTAssertEqual(checked?["marksClearCheck"] as? Bool, true, "Selection must not obscure a tile's marks")
      XCTAssertEqual(checked?["badgeClearMarks"] as? Bool, true, "The active badge must not overlap the marks")
      let discover = result?["discover"] as? [String: Any]
      XCTAssertEqual(discover?["c"] as? [String], ["installed", "approved", "favorite"], "Discover adds the library check ahead of the marks")
      XCTAssertEqual(discover?["x"] as? [String], ["approved"], "Steam's Approved tag marks a Discover tile")
      XCTAssertEqual(discover?["y"] as? [String], [])
      XCTAssertEqual(discover?["noCheck"] as? Bool, true, "Discover tiles have no select check to step past")
    }
  }

  /// Holding a tile and sweeping across others selects the whole run between them in grid
  /// order; sweeping back gives the overshoot back, the click that ends the press changes
  /// nothing, and a quick drag outside a selection is ignored. From a checked tile the sweep
  /// clears instead. The selection row teaches the gesture until it has been used once, and
  /// that is remembered natively.
  func testHoldAndDragSelectsARunOfTilesWithoutWindow() async throws {
    try await withPanel { panel in
      try await panel.finishWelcome()
      panel.show()
      try await panel.waitJS("powerProbe.received.length >= 1")
      XCTAssertFalse(panel.controller.dragSelectLearned)
      let result = try await panel.js("""
        const base = window.powerProbe.received.at(-1);
        const wallpaper = id => ({ id, title: id.toUpperCase(), kind: 'Scene', approved: false, preview: null, active: false, supported: true, tags: [], size: 1, addedAt: 1 });
        window.wallpaperUI.receive(Object.assign({}, base, { page: 'installed', libraryLoading: false, selectedID: null, dragSelectLearned: false, wallpapers: ['a', 'b', 'c', 'd', 'e', 'f'].map(wallpaper) }));
        document.getAnimations().forEach(animation => animation.finish());
        const tile = id => document.querySelector(`#wallpaper-grid .wallpaper-tile[data-key="${id}"]`);
        const centre = (id, dx = 0) => { const box = tile(id).getBoundingClientRect(); return { clientX: box.left + box.width / 2 + dx, clientY: box.top + box.height / 2 }; };
        const pointer = (type, at, buttons = 1) => document.elementFromPoint(at.clientX, at.clientY).dispatchEvent(new PointerEvent(type, { bubbles: true, cancelable: true, pointerId: 1, isPrimary: true, button: 0, buttons, ...at }));
        const checked = () => [...document.querySelectorAll('#wallpaper-grid .wallpaper-tile.checked')].map(node => node.dataset.key);
        const tip = () => !!document.querySelector('#browser-summary .selection-tip');
        const hold = () => new Promise(resolve => setTimeout(resolve, 450));

        pointer('pointerdown', centre('a'));
        pointer('pointermove', centre('d'));
        await hold();
        pointer('pointerup', centre('d'), 0);
        const strayDrag = checked();

        pointer('pointerdown', centre('a'));
        const arming = tile('a').classList.contains('arming');
        pointer('pointermove', centre('a', 2));
        await hold();
        const held = checked();
        const tipWhileHeld = tip();
        pointer('pointermove', centre('d'));
        const swept = checked();
        pointer('pointermove', centre('b'));
        const sweptBack = checked();
        pointer('pointerup', centre('b'), 0);
        tile('b').querySelector('.tile-select').click();
        const afterClick = checked();
        const inspectorUntouched = !document.querySelector('#wallpaper-grid .tile-select[aria-pressed="true"]');

        pointer('pointerdown', centre('a'));
        pointer('pointermove', centre('b'));
        pointer('pointerup', centre('b'), 0);
        const cleared = checked();
        return { strayDrag, arming, held, tipWhileHeld, swept, sweptBack, afterClick, inspectorUntouched, cleared };
        """) as? [String: Any]
      XCTAssertEqual(result?["strayDrag"] as? [String], [], "A drag that does not hold first selects nothing")
      XCTAssertEqual(result?["arming"] as? Bool, true, "The pressed tile shows the hold in progress")
      XCTAssertEqual(result?["held"] as? [String], ["a"], "Holding still checks the pressed tile")
      XCTAssertEqual(result?["tipWhileHeld"] as? Bool, true, "The selection row teaches the sweep until it is used")
      XCTAssertEqual(result?["swept"] as? [String], ["a", "b", "c", "d"], "The sweep covers every tile between, in grid order")
      XCTAssertEqual(result?["sweptBack"] as? [String], ["a", "b"], "Sweeping back gives the overshoot back")
      XCTAssertEqual(result?["afterClick"] as? [String], ["a", "b"], "The click ending the press does not toggle the tile")
      XCTAssertEqual(result?["inspectorUntouched"] as? Bool, true)
      XCTAssertEqual(result?["cleared"] as? [String], [], "With a selection under way, sweeping from a checked tile clears at once")
      try await panel.waitUntil { panel.controller.dragSelectLearned }
      XCTAssertTrue(panel.defaults.bool(forKey: WebPanelController.dragSelectLearnedKey), "Learning the sweep is stored")
      XCTAssertEqual(panel.controller.snapshot()["dragSelectLearned"] as? Bool, true)
      try await panel.expectJS("""
        const base = window.powerProbe.received.at(-1);
        const wallpaper = id => ({ id, title: id.toUpperCase(), kind: 'Scene', approved: false, preview: null, active: false, supported: true, tags: [], size: 1, addedAt: 1 });
        window.wallpaperUI.receive(Object.assign({}, base, { page: 'installed', libraryLoading: false, dragSelectLearned: true, wallpapers: ['a', 'b', 'c'].map(wallpaper) }));
        document.querySelector('#wallpaper-grid .tile-check').click();
        return !!document.querySelector('#browser-summary .selection-count') && !document.querySelector('#browser-summary .selection-tip');
        """, equals: true)
    }
  }

  /// An installed wallpaper that can run offers a GitHub report beneath its compatibility note,
  /// prefilled with the running app's version and the backend drawing it. When applying it
  /// fails, the failure takes that link's place and its report carries the error.
  func testInspectorReportLinkCarriesRendererAndApplyFailureWithoutWindow() async throws {
    try await withPanel { panel in
      try await panel.finishWelcome()
      panel.show()
      try await panel.waitJS("powerProbe.received.length >= 1")
      let result = try await panel.js("""
        const waitFor = async predicate => {
          const deadline = Date.now() + 5000;
          while (!predicate()) {
            if (Date.now() > deadline) throw new Error('The inspector did not show the failure');
            await new Promise(resolve => setTimeout(resolve, 20));
          }
        };
        const base = window.powerProbe.received.at(-1);
        const wallpaper = (id, title, kind) => ({ id, title, kind, size: 100, preview: null, active: false, supported: true, tags: [] });
        const wallpapers = [wallpaper('tool', 'Tool', 'Application'), wallpaper('ghost', 'Ghost', 'Scene')];
        const settings = Object.assign({}, base.settings, { sceneRenderers: [
          { displayId: 1, display: 'Main', wallpaperId: 'ghost', wallpaperTitle: 'Ghost', backend: 'legacy_vulkan', fallbackReason: 'lit particles', videoPath: 'none', optimizationApplied: null },
        ] });
        const select = id => window.wallpaperUI.receive(Object.assign({}, base, { page: 'installed', wallpapers, selectedID: id, settings, targetDisplayID: 'primary' }));
        const plainReport = () => document.querySelector('#inspector .inspector-report')?.dataset.url || '';
        select('tool');
        const application = plainReport();
        select('ghost');
        const plain = plainReport();
        // Native knows no 'ghost', so applying it fails for real; held pushes keep this snapshot on screen.
        window.powerProbe.hold = true;
        document.querySelector('#inspector [data-action="activate"]').click();
        await waitFor(() => document.querySelector('#inspector .inspector-failure'));
        const failure = document.querySelector('#inspector .inspector-failure');
        return { application, plain, plainAfter: plainReport(),
                 failureText: failure.querySelector('p').textContent,
                 failureReport: failure.querySelector('[data-action="openExternal"]')?.dataset.url || '' };
        """) as? [String: Any]
      // URLSearchParams writes spaces as `+`, which GitHub's form reads back as spaces.
      let body = { (link: Any?) -> String in
        let query = (link as? String ?? "").replacingOccurrences(of: "+", with: "%20")
        return URLComponents(string: query)?.queryItems?.first { $0.name == "body" }?.value ?? ""
      }
      let version = try XCTUnwrap(
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
      XCTAssertEqual(result?["application"] as? String, "", "Application wallpapers cannot run, so none is offered")
      let plain = body(result?["plain"])
      XCTAssertTrue(plain.contains("**App version:** \(version)"), plain)
      XCTAssertTrue(plain.contains("**Renderer:** legacy_vulkan (fallback: lit particles)"), plain)
      XCTAssertFalse(plain.contains("**Error:**"), plain)
      let failureText = try XCTUnwrap(result?["failureText"] as? String)
      XCTAssertFalse(failureText.isEmpty, "The inspector names why applying failed")
      XCTAssertTrue(body(result?["failureReport"]).contains("**Error:** \(failureText)"), "The report carries the failure")
      XCTAssertEqual(result?["plainAfter"] as? String, "", "The failure's report replaces the plain link")
    }
  }

  /// An installed Workshop wallpaper can be downloaded again from its inspector, and from the
  /// compatibility card when a check found something its files cannot supply. A wallpaper that
  /// did not come from the Workshop, cannot run on macOS, or already has a download gets neither.
  func testReinstallIsOfferedOnlyForAnInstalledWorkshopWallpaperWithNoDownloadUnderWay() async throws {
    try await withPanel { panel in
      try await panel.finishWelcome()
      panel.show()
      try await panel.waitJS("powerProbe.received.length >= 1")
      let result = try await panel.js("""
        const base = window.powerProbe.received.at(-1);
        const wallpaper = (id, kind = 'Video') => ({ id, title: 'W' + id, kind, size: 100, preview: null, active: false, supported: true, tags: [] });
        const wallpapers = [wallpaper('111'), wallpaper('handmade'), wallpaper('222', 'Application'), wallpaper('333'), wallpaper('444')];
        const download = id => ({ id, wallpaperID: id, title: 'W' + id, status: '', preview: null, thumbnail: null, account: '', phase: null, progress: null, pending: true, queued: true, paused: false, cancelled: false, error: null });
        const request = id => ({ id, wallpaperID: id, title: 'W' + id, preview: null, thumbnail: null, account: '', rememberSession: true, stage: 'setup', paused: false });
        const compat = (id, status = 'unavailable') => ({ wallpaperID: id, displayID: 'primary', checking: false, checks: [{ id: 'entry', title: 'Entry file', status, detail: 'Missing' }] });
        const show = (id, extra = {}) => {
          window.wallpaperUI.receive(Object.assign({}, base, { page: 'installed', wallpapers, selectedID: id, targetDisplayID: 'primary', downloads: [], downloadRequests: [], wallpaperCompatibility: compat(id) }, extra));
          return { inspector: !!document.querySelector('#inspector .inspector-actions [data-action="workshopReinstall"][data-id="' + id + '"]'),
                   card: !!document.querySelector('#inspector .compat [data-action="workshopReinstall"][data-id="' + id + '"]') };
        };
        return { workshop: show('111'), warningOnly: show('111', { wallpaperCompatibility: compat('111', 'warning') }),
                 handmade: show('handmade'), application: show('222'),
                 downloading: show('333', { downloads: [download('333')] }),
                 waiting: show('444', { downloadRequests: [request('444')] }) };
        """) as? [String: Any]
      func offered(_ key: String) -> [Bool]? {
        (result?[key] as? [String: Bool]).map { [$0["inspector"] ?? false, $0["card"] ?? false] }
      }
      XCTAssertEqual(offered("workshop"), [true, true], "Both places offer it when a check found something missing")
      XCTAssertEqual(offered("warningOnly"), [true, false], "A warning alone is not what a fresh copy repairs")
      XCTAssertEqual(offered("handmade"), [false, false], "Only the Workshop has a copy to download again")
      XCTAssertEqual(offered("application"), [false, false], "Application wallpapers cannot run on macOS")
      XCTAssertEqual(offered("downloading"), [false, false], "A download under way is where the user looks")
      XCTAssertEqual(offered("waiting"), [false, false], "A request waiting for setup is continued, not repeated")
    }
  }

  /// The card offers a fresh copy only for what a fresh copy repairs: the installed files. A real
  /// report for a healthy web wallpaper always carries an unavailable lock-screen check, and a scene
  /// without shared resources reports those as unavailable; neither is damage in the wallpaper.
  func testCompatibilityCardOffersReinstallOnlyWhenTheInstalledFilesAreWhatIsUnavailable() async throws {
    try await withPanel { panel in
      try await panel.finishWelcome()
      panel.show()
      try await panel.waitJS("powerProbe.received.length >= 1")
      let result = try await panel.js("""
        const base = window.powerProbe.received.at(-1);
        const kinds = { web: 'Web', scene: 'Scene', video: 'Video', unknown: 'Unknown' };
        const ids = { healthyWeb: ['9001', 'web'], sceneWithoutSharedResources: ['9002', 'scene'], videoWithoutNativeAdmission: ['9003', 'video'],
                      entryMissing: ['9004', 'video'], manifestMissing: ['9005', 'scene'], unknownType: ['9006', 'unknown'] };
        const wallpapers = Object.values(ids).map(([id, kind]) => ({ id, title: 'W' + id, kind: kinds[kind], size: 100, preview: null, active: false, supported: true, tags: [] }));
        const check = (id, status) => ({ id, status, title: id, detail: id });
        const show = (key, checks) => {
          const id = ids[key][0];
          window.wallpaperUI.receive(Object.assign({}, base, { page: 'installed', wallpapers, selectedID: id, targetDisplayID: 'primary', downloads: [], downloadRequests: [],
            wallpaperCompatibility: { wallpaperID: id, displayID: 'primary', checking: false, checks } }));
          return { inspector: !!document.querySelector('#inspector .inspector-actions [data-action="workshopReinstall"][data-id="' + id + '"]'),
                   card: !!document.querySelector('#inspector .compat [data-action="workshopReinstall"][data-id="' + id + '"]') };
        };
        return {
          healthyWeb: show('healthyWeb', [check('target', 'ok'), check('lockScreen', 'unavailable'), check('project', 'ok'), check('entry', 'ok'), check('webRuntime', 'unknown')]),
          sceneWithoutSharedResources: show('sceneWithoutSharedResources', [check('target', 'ok'), check('lockScreen', 'warning'), check('project', 'ok'), check('entry', 'ok'), check('sharedResources', 'unavailable'), check('sceneCapability', 'unknown')]),
          videoWithoutNativeAdmission: show('videoWithoutNativeAdmission', [check('target', 'ok'), check('lockScreen', 'warning'), check('project', 'ok'), check('entry', 'ok'), check('nativeVideo', 'unavailable')]),
          entryMissing: show('entryMissing', [check('target', 'ok'), check('lockScreen', 'warning'), check('project', 'ok'), check('entry', 'unavailable'), check('nativeVideo', 'unavailable')]),
          manifestMissing: show('manifestMissing', [check('target', 'ok'), check('lockScreen', 'warning'), check('project', 'unavailable')]),
          unknownType: show('unknownType', [check('target', 'ok'), check('lockScreen', 'unavailable'), check('project', 'unavailable'), check('entry', 'ok'), check('capability', 'unavailable')]),
        };
        """) as? [String: Any]
      func offered(_ key: String) -> [Bool]? {
        (result?[key] as? [String: Bool]).map { [$0["inspector"] ?? false, $0["card"] ?? false] }
      }
      XCTAssertEqual(offered("healthyWeb"), [true, false], "A web wallpaper's lock screen is never supported; nothing is damaged")
      XCTAssertEqual(offered("sceneWithoutSharedResources"), [true, false], "Missing shared resources are fetched separately, not by a fresh copy")
      XCTAssertEqual(offered("videoWithoutNativeAdmission"), [true, false], "Native video admission depends on the target, not on the files")
      XCTAssertEqual(offered("entryMissing"), [true, true], "A missing entry file is what a fresh copy repairs")
      XCTAssertEqual(offered("manifestMissing"), [true, true], "A missing manifest is what a fresh copy repairs")
      XCTAssertEqual(offered("unknownType"), [true, false], "A fresh copy does not teach macOS a type it has no renderer for")
    }
  }

  func testRejectedDownloadAccountStaysVisibleAndLateErrorsDoNotLeakIntoReopenedDialog() async throws {
    try await withPanel { panel in
      try await panel.finishWelcome()
      panel.workshop.steamCMDSetup.selectExisting(at: panel.executable)
      try await panel.waitUntil { panel.workshop.steamCMDSetup.selectedRuntime != nil }
      panel.workshop.selectedItem = WorkshopItem(
        id: "222", title: "Local video", creator: "Fixture", summary: "",
        previewURL: nil, tags: ["Video"], size: 0, subscriptions: 0)
      panel.show()
      try await panel.waitJS("powerProbe.received.at(-1)?.setup.ready === true")
      _ = try await panel.js("""
        const snapshot = await window.webkit.messageHandlers.native.postMessage({action:'requestDownload', id:'222'});
        window.wallpaperUI.receive(snapshot);
        document.querySelector('#top-actions [data-action="openDownloads"]').click();
        document.querySelector('#queue-popover [data-action="continueSetup"][data-id="222"]').click();
        """)
      try await panel.waitJS("document.getElementById('download-dialog').open && document.getElementById('download-dialog').dataset.stage === 'account'")
      _ = try await panel.js("""
        const dialog = document.getElementById('download-dialog');
        const account = dialog.querySelector('[data-input="account"]');
        account.focus();
        account.value = 'anonymous';
        account.dispatchEvent(new Event('input', {bubbles:true}));
        const remember = dialog.querySelector('[data-change="rememberSession"]');
        if (remember.checked) remember.click();
        dialog.querySelector('[data-form="dialogContinue"]').requestSubmit();
        """)
      try await panel.waitUntil {
        panel.controller.actionError != nil && panel.workshop.downloadRequests.first?.refused == true
      }
      try await panel.waitJS("document.querySelector('#download-dialog [data-input=\"account\"]')?.disabled === false")
      let rejected = try await panel.js("""
        const dialog = document.getElementById('download-dialog');
        const alert = dialog.querySelector('[role="alert"]');
        const bounds = alert?.getBoundingClientRect();
        const modal = dialog.getBoundingClientRect();
        return {open: dialog.open, stage: dialog.dataset.stage,
                visibleAlert: !!alert && bounds.height > 0 && bounds.top >= modal.top && bounds.bottom <= modal.bottom,
                accountPreserved: dialog.querySelector('[data-input="account"]').value === 'anonymous',
                rememberPreserved: !dialog.querySelector('[data-change="rememberSession"]').checked};
        """) as? [String: Any]
      XCTAssertEqual(rejected?["open"] as? Bool, true)
      XCTAssertEqual(rejected?["stage"] as? String, "account")
      XCTAssertEqual(rejected?["visibleAlert"] as? Bool, true, "A rejected native action must be readable inside the modal")
      XCTAssertEqual(rejected?["accountPreserved"] as? Bool, true)
      XCTAssertEqual(rejected?["rememberPreserved"] as? Bool, true)
      let request = try XCTUnwrap(panel.workshop.downloadRequests.first)
      XCTAssertEqual(request.id, "222")
      XCTAssertEqual(request.account, "anonymous")
      XCTAssertFalse(request.rememberSession)
      XCTAssertTrue(request.refused)
      XCTAssertTrue(panel.workshop.downloader.downloads.isEmpty, "Anonymous is rejected before starting even the local executable")

      _ = try await panel.js("""
        document.querySelector('#download-dialog [data-action="dismissDialog"]').click();
        const snapshot = await window.webkit.messageHandlers.native.postMessage({action:'ready'});
        window.wallpaperUI.receive(snapshot);
        """)
      try await panel.expectJS("return document.getElementById('download-dialog').open", equals: false)
      try await panel.expectJS("return document.getElementById('error-banner').hidden", equals: false)
      _ = try await panel.js("""
        document.querySelector('#top-actions [data-action="openDownloads"]').click();
        document.querySelector('#queue-popover [data-action="continueSetup"][data-id="222"]').click();
        """)
      try await panel.waitJS("document.getElementById('download-dialog').open && document.getElementById('download-dialog').dataset.stage === 'account'")
      try await panel.expectJS("return document.querySelector('#download-dialog [data-input=\"account\"]').value === 'anonymous'", equals: true)
      try await panel.expectJS("return document.querySelector('#download-dialog [role=\"alert\"]') === null", equals: true)

      // Hold only a second continuation locally so its failure can arrive after this dialog
      // session was closed and reopened. The first rejection above uses the actual native path.
      _ = try await panel.js("""
        const native = window.webkit.messageHandlers.native;
        const original = native.postMessage.bind(native);
        native.postMessage = message => message.action === 'continueDownload'
          ? new Promise((resolve, reject) => {
              window.rejectPreviousDialog = () => {
                native.postMessage = original;
                delete window.rejectPreviousDialog;
                reject(new Error('Delayed fixture rejection'));
              };
            })
          : original(message);
        document.querySelector('#download-dialog [data-form="dialogContinue"]').requestSubmit();
        """)
      try await panel.waitJS("typeof window.rejectPreviousDialog === 'function'")
      _ = try await panel.js("""
        document.querySelector('#download-dialog [data-action="dismissDialog"]').click();
        document.querySelector('#top-actions [data-action="openDownloads"]').click();
        document.querySelector('#queue-popover [data-action="continueSetup"][data-id="222"]').click();
        window.rejectPreviousDialog();
        """)
      try await panel.waitJS("document.querySelector('#download-dialog [data-input=\"account\"]')?.disabled === false && document.getElementById('error-banner').textContent.includes('Delayed fixture rejection')")
      try await panel.expectJS("return document.getElementById('download-dialog').open", equals: true)
      try await panel.expectJS("return document.querySelector('#download-dialog [role=\"alert\"]') === null", equals: true)
      try await panel.expectJS("return document.querySelector('#download-dialog [data-input=\"account\"]').value === 'anonymous'", equals: true)
      XCTAssertEqual(panel.workshop.downloadRequests.map(\.id), ["222"])
      XCTAssertTrue(panel.workshop.downloader.downloads.isEmpty)
    }
  }

  func testDownloadSetupCanBeDismissedAndResumedWithoutLosingIntent() async throws {
    let fixture = makeStore()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "download-ui-\(UUID().uuidString)")
    let defaults = try TemporaryDefaults.make(for: self).defaults
    defaults.set(
      root.appendingPathComponent("missing-steamcmd").path, forKey: "WallpaperMachineSteamCMDPath"
    )
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
    web.setFrameSize(NSSize(width: 760, height: 560))
    let deadline = Date().addingTimeInterval(15)
    while !controller.isReady && Date() < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertTrue(controller.isReady)
    guard controller.isReady else { return }
    try await finishWelcome(in: web)
    XCTAssertNil(web.window, "Every panel behavior check must remain offscreen")
    let result =
      try await web.callAsyncJavaScript(
        """
        const waitFor = async predicate => {
          const deadline = Date.now() + 5000;
          while (!predicate()) {
            if (Date.now() > deadline) throw new Error('Download interface did not reach expected state');
            await new Promise(resolve => setTimeout(resolve, 20));
          }
        };
        await waitFor(() => Math.round(window.innerWidth) === 760);
        const snapshot = await window.webkit.messageHandlers.native.postMessage({action:'requestDownload',id:null});
        window.wallpaperUI.receive(snapshot);
        document.querySelector('#top-actions [data-action="openDownloads"]').click();
        await waitFor(() => document.querySelector('[data-action="continueSetup"][data-id="scene-assets"]'));
        document.querySelector('[data-action="continueSetup"][data-id="scene-assets"]').click();
        const dialog = document.getElementById('download-dialog');
        await waitFor(() => dialog.open);
        const firstStage = dialog.dataset.stage;
        dialog.querySelector('[data-action="dismissDialog"]').click();
        await waitFor(() => !dialog.open);
        const refreshed = await window.webkit.messageHandlers.native.postMessage({action:'ready'});
        window.wallpaperUI.receive(refreshed);
        const stayedClosed = !dialog.open;
        document.querySelector('#top-actions [data-action="openDownloads"]').click();
        await waitFor(() => document.querySelector('[data-action="continueSetup"][data-id="scene-assets"]'));
        document.querySelector('[data-action="continueSetup"][data-id="scene-assets"]').click();
        await waitFor(() => dialog.open);
        const resumed = dialog.dataset.stage === firstStage;
        dialog.querySelector('[data-action="dismissDialog"]').click();
        document.querySelector('#top-actions [data-action="openDownloads"]').click();
        await waitFor(() => document.querySelector('[data-action="removeDownloadRequest"][data-id="scene-assets"]'));
        document.querySelector('[data-action="removeDownloadRequest"][data-id="scene-assets"]').click();
        await waitFor(() => !document.querySelector('[data-action="removeDownloadRequest"][data-id="scene-assets"]'));
        const final = await window.webkit.messageHandlers.native.postMessage({action:'ready'});
        return {firstStage,stayedClosed,resumed,retained:refreshed.downloadRequests.some(x=>x.id==='scene-assets'),removed:!final.downloadRequests.some(x=>x.id==='scene-assets')};
        """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
    XCTAssertEqual(result?["firstStage"] as? String, "setup")
    XCTAssertEqual(result?["stayedClosed"] as? Bool, true)
    XCTAssertEqual(result?["retained"] as? Bool, true)
    XCTAssertEqual(result?["resumed"] as? Bool, true)
    XCTAssertEqual(result?["removed"] as? Bool, true)
    XCTAssertNil(web.window)
    await workshop.steamCMDSetup.shutdown()
  }

  /// Dismissing an error must actually dismiss it: library and download failures
  /// live in persistent native state, so a snapshot that keeps reporting them
  /// makes the close button a no-op.
  func testDismissingAnErrorSuppressesLibraryAndDownloadFailuresUntilTheyRecur() async throws {
    let fixture = makeStore()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "web-errors-\(UUID().uuidString)")
    let defaults = try TemporaryDefaults.make(for: self).defaults
    defer { try? FileManager.default.removeItem(at: root) }
    let workshop = WorkshopStore(
      downloader: WorkshopDownloadManager(sessionDirectory: root), supportDirectory: root,
      defaults: defaults)
    let controller = WebPanelController(
      store: fixture.store, navigation: ControlPanelNavigation(), workshop: workshop,
      defaults: defaults,
      appLanguage: .english())

    try? await fixture.store.refreshAllAsync()
    workshop.downloader.installAssets(
      username: "anonymous", executable: root.appendingPathComponent("missing"),
      destination: root.appendingPathComponent("assets"), rememberSession: false, onInstalled: {})
    let downloadFailure = try XCTUnwrap(workshop.downloader.errorMessage)
    XCTAssertNotNil(controller.snapshot()["error"] as? String, "The library failure must surface")
    XCTAssertEqual(controller.snapshot()["downloadError"] as? String, downloadFailure)

    try await controller.perform("dismissError", body: ["action": "dismissError"])
    controller.reconcileDismissedErrors()
    XCTAssertNil(
      controller.snapshot()["error"] as? String, "A dismissed library failure must stay dismissed")
    XCTAssertNil(controller.snapshot()["downloadError"] as? String)

    fixture.bridge.snapshot = BridgeSnapshotBundle(
      app: fixture.store.appSnapshot, library: fixture.store.librarySnapshot,
      wallpaperOptions: nil, monitorInformation: fixture.store.monitorInformationSnapshot,
      settings: fixture.store.settingsSnapshot)
    try await fixture.store.refreshAllAsync()
    controller.reconcileDismissedErrors()
    fixture.bridge.snapshot = nil
    try? await fixture.store.refreshAllAsync()
    controller.reconcileDismissedErrors()
    XCTAssertNotNil(
      controller.snapshot()["error"] as? String,
      "A failure that happens again after recovery must surface instead of staying hidden")
    await workshop.steamCMDSetup.shutdown()
  }

  // MARK: Still covers and hover animation

  private func png(width: Int, height: Int) throws -> Data {
    let output = NSMutableData()
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return output as Data
  }

  /// Library folders `a` and `b` with an animated preview, `c` with a picture, and `d` with none.
  private func installPreviews(_ panel: PanelFixture) throws {
    let gif = try Self.gif(frames: 3, brightness: 0.6)
    var entries: [BridgeWallpaperEntry] = []
    for (id, file, bytes) in [("a", "preview.gif", gif), ("b", "preview.gif", gif), ("c", "preview.png", try png(width: 64, height: 64))] {
      let path = panel.library.appendingPathComponent("\(id)/\(file)")
      try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
      try bytes.write(to: path)
      entries.append(
        BridgeWallpaperEntry(
          id: id, title: id.uppercased(), kind: .video, supported: true, active: false, selected: false,
          previewPath: path.path))
    }
    entries.append(
      BridgeWallpaperEntry(
        id: "d", title: "D", kind: .video, supported: true, active: false, selected: false, previewPath: nil))
    panel.store.librarySnapshot.wallpapers = entries
  }

  /// The addresses the snapshot gives the covers of `installPreviews`' wallpapers `ids`.
  private func coverAddresses(_ panel: PanelFixture, _ ids: [String]) throws -> [String] {
    try ids.map { id in
      let file = panel.library.appendingPathComponent("\(id)/preview.\(id == "c" ? "png" : "gif")")
      return "mwe-ui://library-thumbnail/\(id)?v=\(try XCTUnwrap(LibraryPreviewFetcher.coverStamp(of: file)))"
    }
  }

  func testSnapshotOffersACoverForEveryPreviewAndAnimationOnlyToThoseThatCanMove() async throws {
    try await withPanel { panel in
      func entry(_ id: String, _ file: String?) -> BridgeWallpaperEntry {
        BridgeWallpaperEntry(
          id: id, title: id, kind: .video, supported: true, active: false, selected: false,
          previewPath: file.map { panel.library.appendingPathComponent("\(id)/\($0)").path })
      }
      let previews: [(String, String?)] = [
        ("gif", "preview.gif"), ("webp", "preview.WEBP"), ("apng", "preview.apng"), ("png", "preview.png"),
        ("jpg", "preview.jpg"), ("none", nil),
      ]
      for (id, file) in previews {
        guard let file else { continue }
        let path = panel.library.appendingPathComponent("\(id)/\(file)")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("\(id) preview".utf8).write(to: path)
      }
      panel.store.librarySnapshot.wallpapers = previews.map { entry($0.0, $0.1) }

      // The preview files' stamps are read in the background: until they are, a tile has no cover
      // address and says so, so the page shows nothing rather than the full-size preview.
      let pending = try XCTUnwrap(panel.controller.snapshot()["wallpapers"] as? [[String: Any]])
      for (id, file) in previews {
        let tile = try XCTUnwrap(pending.first { $0["id"] as? String == id }, id)
        XCTAssertTrue(tile["thumbnail"] is NSNull, id)
        XCTAssertEqual(tile["coverPending"] as? Bool, file != nil, id)
      }
      await panel.controller.libraryCovers.settled()

      let wallpapers = try XCTUnwrap(panel.controller.snapshot()["wallpapers"] as? [[String: Any]])
      func tile(_ id: String) throws -> [String: Any] {
        try XCTUnwrap(wallpapers.first { $0["id"] as? String == id }, id)
      }

      for (id, file) in previews where file != nil {
        let tile = try tile(id)
        XCTAssertEqual(tile["preview"] as? String, "mwe-ui://preview/\(id)", id)
        let source = panel.library.appendingPathComponent("\(id)/\(file!)")
        let stamp = try XCTUnwrap(LibraryPreviewFetcher.coverStamp(of: source), id)
        let cover = try XCTUnwrap(tile["thumbnail"] as? String, id)
        XCTAssertEqual(cover, "mwe-ui://library-thumbnail/\(id)?v=\(stamp)")
        XCTAssertEqual(tile["coverPending"] as? Bool, false, id)
        let route = panel.controller.assets.route(try XCTUnwrap(URL(string: cover)))
        XCTAssertEqual(route, .libraryThumbnail(URL(fileURLWithPath: source.path)), id)
      }
      for id in ["gif", "webp", "apng"] {
        XCTAssertEqual(try tile(id)["animated"] as? String, "mwe-ui://preview/\(id)", "\(id) can move")
      }
      for id in ["png", "jpg", "none"] {
        XCTAssertTrue(try tile(id)["animated"] is NSNull, "\(id) is a still picture")
      }
      let none = try tile("none")
      XCTAssertTrue(none["preview"] is NSNull)
      XCTAssertTrue(none["thumbnail"] is NSNull)
      XCTAssertEqual(none["coverPending"] as? Bool, false, "A wallpaper without a preview waits for no cover")
      XCTAssertNil(panel.controller.assets.route(try XCTUnwrap(URL(string: "mwe-ui://library-thumbnail/none"))))
    }
  }

  func testInstalledTilesShowCoversAndOnlyThePointedAtTileAnimates() async throws {
    try await withPanel { panel in
      try installPreviews(panel)
      try await panel.finishWelcome()
      panel.show()
      // A windowless page reports itself hidden, and a hidden page animates nothing.
      _ = try await panel.js("Object.defineProperty(document, 'hidden', { configurable: true, get: () => false })")
      try await panel.waitJS("document.querySelectorAll('#wallpaper-grid .wallpaper-tile').length === 4")
      let waitFor = """
        const grid = document.getElementById('wallpaper-grid');
        const tile = id => grid.querySelector(`.wallpaper-tile[data-key="${id}"]`);
        const select = id => tile(id).querySelector('.tile-select');
        const liveIDs = () => [...grid.querySelectorAll('img.tile-live')].map(image => image.closest('.wallpaper-tile').dataset.key);
        const playingIDs = () => [...grid.querySelectorAll('.wallpaper-tile.playing')].map(node => node.dataset.key);
        const waitFor = async (predicate, what) => {
          const deadline = Date.now() + 8000;
          while (!predicate()) {
            if (Date.now() > deadline) throw new Error(`Timed out: ${what}; live=${liveIDs()} playing=${playingIDs()}`);
            await new Promise(resolve => setTimeout(resolve, 20));
          }
        };
        const point = (type, id, from) => select(id).dispatchEvent(new PointerEvent(type, { bubbles: true, relatedTarget: from ? select(from) : null }));
        """
      let result = try await panel.js(waitFor + """
        await waitFor(() => ['a', 'b', 'c'].every(id => tile(id).querySelector('img.tile-still')?.complete && tile(id).querySelector('img.tile-still').naturalWidth > 0), 'covers to load');
        const covers = ['a', 'b', 'c'].map(id => tile(id).querySelector('img.tile-still').getAttribute('src'));
        const restingLive = liveIDs().length;

        point('pointerover', 'a');
        const beforeDwell = liveIDs().length;
        await waitFor(() => playingIDs().join() === 'a', 'the pointed-at tile to play');
        const aSource = tile('a').querySelector('img.tile-live').getAttribute('src');

        // Moving to the next tile stops the first at once and starts the second after the dwell.
        point('pointerout', 'a', 'b');
        const afterLeave = liveIDs().length;
        point('pointerover', 'b');
        await waitFor(() => playingIDs().join() === 'b', 'the next tile to play');
        const onlyB = liveIDs().join();

        // A picture has nothing to animate.
        point('pointerout', 'b', 'c');
        point('pointerover', 'c');
        await new Promise(resolve => setTimeout(resolve, 350));
        const pictureLive = liveIDs().length;

        // Sweeping across tiles without stopping starts nothing.
        point('pointerout', 'c', 'a'); point('pointerover', 'a');
        point('pointerout', 'a', 'b'); point('pointerover', 'b');
        point('pointerout', 'b');
        await new Promise(resolve => setTimeout(resolve, 350));
        const afterSweep = liveIDs().length;

        // A held button (a selection drag) never starts one either.
        select('a').dispatchEvent(new PointerEvent('pointerover', { bubbles: true, buttons: 1 }));
        await new Promise(resolve => setTimeout(resolve, 350));
        const afterDrag = liveIDs().length;
        point('pointerout', 'a');

        // The tile still plays while the pointer moves between its own controls.
        point('pointerover', 'a');
        await waitFor(() => playingIDs().join() === 'a', 'a to play again');
        grid.querySelector('.wallpaper-tile[data-key="a"] .tile-favorite').dispatchEvent(new PointerEvent('pointerover', { bubbles: true, relatedTarget: select('a') }));
        select('a').dispatchEvent(new PointerEvent('pointerout', { bubbles: true, relatedTarget: grid.querySelector('.wallpaper-tile[data-key="a"] .tile-favorite') }));
        await new Promise(resolve => setTimeout(resolve, 350));
        const whileOnFavorite = playingIDs().join();

        // Keyboard focus animates a tile like the pointer does; a focus that is not keyboard focus (a
        // click) does not. WebKit decides :focus-visible from real input, so the answer is stated here.
        const matches = Element.prototype.matches;
        const focusIn = (id, visible) => {
          Element.prototype.matches = function(selector) { return selector === ':focus-visible' ? visible : matches.call(this, selector); };
          try { select(id).dispatchEvent(new FocusEvent('focusin', { bubbles: true })); } finally { Element.prototype.matches = matches; }
        };
        point('pointerout', 'a');
        focusIn('b', false);
        await new Promise(resolve => setTimeout(resolve, 350));
        const clickFocus = liveIDs().length;
        focusIn('b', true);
        await waitFor(() => playingIDs().join() === 'b', 'the focused tile to play');
        point('pointerover', 'a');
        await waitFor(() => playingIDs().join() === 'a', 'the pointer to take over from focus');
        point('pointerout', 'a');
        await waitFor(() => playingIDs().join() === 'b', 'the focused tile to play again');
        select('b').dispatchEvent(new FocusEvent('focusout', { bubbles: true, relatedTarget: select('c') }));
        const afterFocusOut = liveIDs().length;

        // Losing window focus releases it, and so does hiding the page.
        point('pointerover', 'a');
        await waitFor(() => playingIDs().join() === 'a', 'a to play before the blur');
        window.dispatchEvent(new Event('blur'));
        const afterBlur = liveIDs().length;
        point('pointerover', 'b');
        await waitFor(() => playingIDs().join() === 'b', 'b to play');
        Object.defineProperty(document, 'hidden', { configurable: true, get: () => true });
        document.dispatchEvent(new Event('visibilitychange'));
        const afterHide = liveIDs().length;
        Object.defineProperty(document, 'hidden', { configurable: true, get: () => false });
        return { covers, restingLive, beforeDwell, aSource, afterLeave, onlyB, pictureLive, afterSweep, afterDrag, whileOnFavorite, clickFocus, afterFocusOut, afterBlur, afterHide };
        """) as? [String: Any]

      XCTAssertEqual(
        result?["covers"] as? [String],
        try coverAddresses(panel, ["a", "b", "c"]),
        "Installed tiles show the cover, not the preview file")
      XCTAssertEqual(result?["restingLive"] as? Int, 0, "No tile animates at rest")
      XCTAssertEqual(result?["beforeDwell"] as? Int, 0, "The pointer must settle before anything loads")
      XCTAssertEqual(result?["aSource"] as? String, "mwe-ui://preview/a")
      XCTAssertEqual(result?["afterLeave"] as? Int, 0, "Leaving a tile releases its animation at once")
      XCTAssertEqual(result?["onlyB"] as? String, "b")
      XCTAssertEqual(result?["pictureLive"] as? Int, 0, "A single picture is never animated")
      XCTAssertEqual(result?["afterSweep"] as? Int, 0, "Sweeping across the grid starts no animation")
      XCTAssertEqual(result?["afterDrag"] as? Int, 0, "Dragging with a button held starts no animation")
      XCTAssertEqual(result?["whileOnFavorite"] as? String, "a", "Moving between a tile's own controls keeps it playing")
      XCTAssertEqual(result?["clickFocus"] as? Int, 0, "A focus that is not keyboard focus starts no animation")
      XCTAssertEqual(result?["afterFocusOut"] as? Int, 0, "Moving focus away releases the animation")
      XCTAssertEqual(result?["afterBlur"] as? Int, 0, "A window that lost focus plays nothing")
      XCTAssertEqual(result?["afterHide"] as? Int, 0, "A hidden page plays nothing")

      // Only the covers were made: no original animation and no marker beside them.
      let cache = try FileManager.default.contentsOfDirectory(atPath: ClientPaths.libraryThumbnailCacheURL.path)
      XCTAssertEqual(cache.filter { $0.hasSuffix(".jpg") }.count, 3)
      XCTAssertEqual(cache.filter { !$0.hasSuffix(".jpg") }, [])

      // Leaving the page while a tile plays releases it; coming back shows a resting grid.
      _ = try await panel.js(waitFor + """
        const hover = (id) => select(id).dispatchEvent(new PointerEvent('pointerover', { bubbles: true }));
        hover('a');
        await waitFor(() => playingIDs().join() === 'a', 'a to play before leaving');
        """)
      panel.navigation.selection = .settings
      try await panel.waitJS("powerProbe.received.at(-1)?.page === 'settings'")
      try await panel.expectJS("return document.querySelectorAll('img.tile-live').length", equals: 0)
      panel.navigation.selection = .wallpaper
      try await panel.waitJS("powerProbe.received.at(-1)?.page === 'installed' && document.querySelectorAll('#wallpaper-grid .wallpaper-tile').length === 4")
      try await panel.expectJS("return document.querySelectorAll('img.tile-live, .wallpaper-tile.playing').length", equals: 0)
    }
  }

  func testTileFallsBackToThePreviewFileWhenItsCoverCannotBeMade() async throws {
    try await withPanel { panel in
      // A file where the cache folder's parent should be: no cover can be written.
      let cache = panel.root.appendingPathComponent("Cache")
      try? FileManager.default.removeItem(at: cache)
      try Data().write(to: cache)
      try installPreviews(panel)
      try await panel.finishWelcome()
      panel.show()
      try await panel.waitJS("document.querySelectorAll('#wallpaper-grid .wallpaper-tile').length === 4")
      try await panel.waitJS("""
        ['a', 'c'].every(id => {
          const still = document.querySelector(`#wallpaper-grid .wallpaper-tile[data-key="${id}"] img.tile-still`);
          return still?.getAttribute('src') === `mwe-ui://preview/${id}` && still.complete && still.naturalWidth > 0;
        })
        """)
      // The next snapshot keeps showing the preview file instead of asking for the cover again.
      panel.store.librarySnapshot.wallpapers[3].title = "D renamed"
      try await panel.waitJS("document.querySelector('#wallpaper-grid .wallpaper-tile[data-key=\"d\"]')?.textContent.includes('D renamed')")
      try await panel.expectJS(
        "return document.querySelector('#wallpaper-grid .wallpaper-tile[data-key=\"a\"] img.tile-still').getAttribute('src')",
        equals: "mwe-ui://preview/a")
    }
  }

  /// The page has nothing to show a tile with while its cover's stamp is being read, and must not
  /// reach for the full-size preview the cover stands for.
  func testATileWhoseCoverIsStillPendingShowsNoImageUntilItsStampArrives() async throws {
    try await withPanel { panel in
      try await panel.finishWelcome()
      panel.show()
      try await panel.waitJS("powerProbe.received.length >= 1")
      let result = try await panel.js("""
        const base = window.powerProbe.received.at(-1);
        const wallpaper = extra => Object.assign({ id: 'w', title: 'W', kind: 'Video', preview: 'mwe-ui://preview/w', thumbnail: null, coverPending: false, animated: null, active: false, supported: true, tags: [], approved: false, size: 1, addedAt: null, energy: null, updateAvailable: false, updatedAt: null }, extra);
        const show = extra => {
          window.wallpaperUI.receive(Object.assign({}, base, { page: 'installed', wallpapers: [wallpaper(extra)] }));
          return [...document.querySelectorAll('#wallpaper-grid img.tile-still')].map(image => image.getAttribute('src'));
        };
        return { pending: show({ coverPending: true }), stamped: show({ thumbnail: 'mwe-ui://library-thumbnail/w?v=7' }), noPreview: show({ preview: null }) };
        """) as? [String: Any]
      XCTAssertEqual(result?["pending"] as? [String], [], "No cover yet means no image, not the preview file")
      XCTAssertEqual(result?["stamped"] as? [String], ["mwe-ui://library-thumbnail/w?v=7"])
      XCTAssertEqual(result?["noPreview"] as? [String], [])
    }
  }

  /// A rescan follows every Workshop download, import and delete. One that replaced no preview
  /// must leave every tile's image as it was: the same address, and the same node in the page.
  func testARescanThatReplacedNoPreviewLeavesEveryCoverAlone() async throws {
    try await withPanel { panel in
      let ids = try await showInstalledCovers(panel)
      let covers = try coverAddresses(panel, ids)
      let stamps = panel.controller.libraryCovers.stamps
      let changes = panel.controller.libraryCovers.contentRevision
      _ = try await panel.js("for (const image of document.querySelectorAll('#wallpaper-grid img.tile-still')) image.sameNode = true;")

      try await rescan(panel)
      await panel.controller.libraryCovers.settled()
      try await panel.quiet()

      XCTAssertEqual(panel.controller.libraryCovers.stamps, stamps)
      XCTAssertEqual(panel.controller.libraryCovers.contentRevision, changes, "Nothing changed, so nothing was announced")
      let page = try await panel.js(Self.coverStates) as? [String: Any]
      XCTAssertEqual(page?["sources"] as? [String], covers)
      XCTAssertEqual(page?["sameNodes"] as? [Bool], [true, true, true], "No tile's image was thrown away and made again")
    }
  }

  func testAPreviewThatWasReplacedGetsANewCoverAndTheOthersKeepTheirs() async throws {
    try await withPanel { panel in
      let ids = try await showInstalledCovers(panel)
      let before = try coverAddresses(panel, ids)
      _ = try await panel.js("for (const image of document.querySelectorAll('#wallpaper-grid img.tile-still')) image.sameNode = true;")

      // An update replaced a's preview with a different picture.
      try Self.gif(frames: 5, brightness: 0.3).write(to: panel.library.appendingPathComponent("a/preview.gif"))
      try await rescan(panel)
      let after = try coverAddresses(panel, ids)
      XCTAssertNotEqual(after[0], before[0])
      XCTAssertEqual(Array(after.dropFirst()), Array(before.dropFirst()))
      try await panel.waitJS("""
        (() => {
          const still = document.querySelector('#wallpaper-grid .wallpaper-tile[data-key="a"] img.tile-still');
          return still?.getAttribute('src') === '\(after[0])' && still.complete && still.naturalWidth > 0;
        })()
        """)

      let page = try await panel.js(Self.coverStates) as? [String: Any]
      XCTAssertEqual(page?["sources"] as? [String], after)
      XCTAssertEqual(page?["sameNodes"] as? [Bool], [false, true, true], "Only the replaced preview's tile was redone")
    }
  }

  /// The Installed grid with the covers of `installPreviews` loaded; returns the wallpaper ids.
  private func showInstalledCovers(_ panel: PanelFixture) async throws -> [String] {
    try installPreviews(panel)
    try await panel.finishWelcome()
    panel.show()
    try await panel.waitJS("document.querySelectorAll('#wallpaper-grid .wallpaper-tile').length === 4")
    try await panel.waitJS("""
      ['a', 'b', 'c'].every(id => {
        const still = document.querySelector(`#wallpaper-grid .wallpaper-tile[data-key="${id}"] img.tile-still`);
        return still?.complete && still.naturalWidth > 0;
      })
      """)
    return ["a", "b", "c"]
  }

  /// The renderer rescanning the library: the same wallpapers come back, with a new refresh
  /// revision. Returns once the page has been given the rescanned library.
  private func rescan(_ panel: PanelFixture) async throws {
    let store = panel.store
    panel.bridge.bundleProvider = {
      BridgeSnapshotBundle(
        app: store.appSnapshot, library: store.librarySnapshot, wallpaperOptions: store.wallpaperOptionsSnapshot,
        monitorInformation: store.monitorInformationSnapshot, settings: store.settingsSnapshot)
    }
    let delivered = try await panel.js("return window.powerProbe.received.at(-1).libraryRevision") as? String
    try await store.refreshLibraryAsync()
    try await panel.waitJS("window.powerProbe.received.at(-1).libraryRevision !== \(delivered.map { "'\($0)'" } ?? "undefined")")
  }

  private static let coverStates = """
    const stills = ['a', 'b', 'c'].map(id => document.querySelector(`#wallpaper-grid .wallpaper-tile[data-key="${id}"] img.tile-still`));
    return { sources: stills.map(image => image.getAttribute('src')), sameNodes: stills.map(image => image.sameNode === true) };
    """

}
