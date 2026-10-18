import WebKit
import XCTest

@testable import WallpaperMachine

/// A web wallpaper that names a font stock Windows has (SimHei, Microsoft YaHei, Segoe UI)
/// must see it drawn in the face macOS has for it, as Wallpaper Engine's Chromium does on
/// Windows. Every page here is synthetic, loaded offscreen with no window.
@MainActor
final class WebWallpaperFontAliasTests: XCTestCase {
  private var views: [WKWebView] = []

  override func tearDown() async throws {
    views.removeAll()
  }

  /// A page with the font alias script, loaded from `base` (a local file URL by default).
  private func load(_ html: String, base: URL? = URL(fileURLWithPath: NSTemporaryDirectory()))
    async throws -> WKWebView
  {
    let configuration = WKWebViewConfiguration()
    configuration.userContentController.addUserScript(
      WKUserScript(
        source: WebWallpaperFontAliases.script, injectionTime: .atDocumentStart,
        forMainFrameOnly: false))
    let webView = WKWebView(frame: .zero, configuration: configuration)
    views.append(webView)
    webView.loadHTMLString(html, baseURL: base)
    let deadline = Date().addingTimeInterval(10)
    while webView.isLoading && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertFalse(webView.isLoading, "the page did not finish loading")
    return webView
  }

  /// JavaScript the checks share: canvas text widths, and how many pixels two canvas drawings
  /// of a string differ by.
  private static let helpers = """
    const width = (font, text) => {
      const context = document.createElement("canvas").getContext("2d");
      context.font = font;
      return context.measureText(text).width;
    };
    const draw = (font, text) => {
      const canvas = document.createElement("canvas");
      canvas.width = 600; canvas.height = 80;
      const context = canvas.getContext("2d");
      context.fillStyle = "#fff"; context.fillRect(0, 0, 600, 80);
      context.fillStyle = "#000"; context.font = font; context.textBaseline = "top";
      context.fillText(text, 4, 4);
      return Array.from(context.getImageData(0, 0, 600, 80).data);
    };
    const differ = (a, b) => { let n = 0; for (let i = 0; i < a.length; i += 4) if (a[i] !== b[i]) n++; return n; };
    // Whether this Mac has a family: Latin text set in it, over a fallback, measures other than the
    // fallback (a Han string would not, as the fallback draws Han in the same family).
    const has = (family, text) =>
      width(`40px "${family}", monospace`, text) !== width("40px monospace", text) ||
      width(`40px "${family}", serif`, text) !== width("40px serif", text);
    """

  private func evaluate(_ webView: WKWebView, _ body: String) async throws -> [String: Any] {
    let value = try await webView.callAsyncJavaScript(
      Self.helpers + body, arguments: [:], in: nil, contentWorld: .page)
    return try XCTUnwrap(value as? [String: Any])
  }

  private let page =
    "<!doctype html><html><head><meta charset=\"utf-8\"></head><body></body></html>"

  /// The heading of a calendar wallpaper, `900 26pt SimHei`, is a heavy sans in Wallpaper
  /// Engine. WebKit drew it as `700 Songti SC`, a thin Song face with wedge terminals, because
  /// a family it does not have falls to the standard font and CoreText's cascade takes Han
  /// from Songti.
  func testAChineseFamilyStockWindowsLacksDrawsHanInTheSansFace() async throws {
    let view = try await load(page)
    let result = try await evaluate(
      view,
      """
      const han = "十月晚安";
      return {
        pingFang: has("PingFang SC", "mmmmlli 0123"),
        simHei: differ(draw("900 40px SimHei", han), draw("600 40px \\"PingFang SC\\"", han)),
        simHeiVsSongti: differ(draw("900 40px SimHei", han), draw("700 40px \\"Songti SC\\"", han)),
        yaHei: differ(draw("400 40px \\"Microsoft YaHei\\"", han), draw("400 40px \\"PingFang SC\\"", han)),
        yaHeiBold: differ(draw("700 40px \\"Microsoft YaHei\\"", han), draw("600 40px \\"PingFang SC\\"", han)),
        localised: differ(draw("900 40px 黑体", han), draw("600 40px \\"PingFang SC\\"", han)),
        hidden: !Object.keys(window).includes("__mweFontAliases"),
      };
      """)
    guard result["pingFang"] as? Bool == true else { throw XCTSkip("PingFang SC is not installed") }
    XCTAssertEqual(result["simHei"] as? Int, 0, "SimHei at weight 900 is PingFang SC Semibold")
    XCTAssertGreaterThan(result["simHeiVsSongti"] as? Int ?? 0, 0, "and not Songti SC Bold")
    XCTAssertEqual(result["yaHei"] as? Int, 0)
    XCTAssertEqual(result["yaHeiBold"] as? Int, 0)
    XCTAssertEqual(result["localised"] as? Int, 0, "the localised name is the same family")
    XCTAssertEqual(
      result["hidden"] as? Bool, true, "the guard must not show up when a page lists its globals")
  }

  /// SimHei is a Han font: its Latin stays on the page's next family, as on Windows.
  func testAFamilyStockWindowsLacksLeavesLatinToTheNextFamily() async throws {
    let view = try await load(page)
    let result = try await evaluate(
      view,
      """
      return {
        pingFang: has("PingFang SC", "mmmmlli 0123"),
        latin: width('40px SimHei, "Times New Roman"', "Abc 0123"),
        times: width('40px "Times New Roman"', "Abc 0123"),
      };
      """)
    guard result["pingFang"] as? Bool == true else { throw XCTSkip("PingFang SC is not installed") }
    XCTAssertEqual(
      try XCTUnwrap(result["latin"] as? Double), try XCTUnwrap(result["times"] as? Double),
      accuracy: 0.01)
  }

  /// The Latin interface fonts are set to the real fonts' digit advances: Segoe UI's digits
  /// are 0.537 em wide and PT Sans's, which stands in for it, 0.545.
  func testSegoeUIIsFittedToItsDigitAdvance() async throws {
    let view = try await load(page)
    let result = try await evaluate(
      view,
      """
      const digits = "0123456789";
      return {
        ptSans: has("PT Sans", digits),
        segoe: width('40px "Segoe UI", serif', digits),
        ptSansWidth: width('40px "PT Sans"', digits),
        arial: width("40px Arial", digits),
        arialAlone: width('40px Arial, serif', digits),
      };
      """)
    guard result["ptSans"] as? Bool == true else { throw XCTSkip("PT Sans is not installed") }
    let segoe = try XCTUnwrap(result["segoe"] as? Double)
    let ptSans = try XCTUnwrap(result["ptSansWidth"] as? Double)
    XCTAssertEqual(segoe / ptSans, 0.987, accuracy: 0.001)
    XCTAssertEqual(segoe / 40 / 10, 0.5371, accuracy: 0.005, "Segoe UI's digits in em")
    // A font this Mac has is not touched.
    XCTAssertEqual(
      try XCTUnwrap(result["arial"] as? Double), try XCTUnwrap(result["arialAlone"] as? Double),
      accuracy: 0.01)
  }

  /// macOS answers some Windows names with a substitute of its own (Calibri is Helvetica
  /// here), which is wider than the font. The real digits of Calibri, Cambria, Consolas and
  /// Segoe UI are the ones that are drawn, whether this Mac has the font or not.
  func testTheLatinFontsDrawWithTheRealDigitAdvance() async throws {
    let view = try await load(page)
    let result = try await evaluate(
      view,
      """
      const digit = family => width(`1000px "${family}", monospace`, "0") / 1000;
      return {
        ptSans: has("PT Sans", "mmmmlli 0123"), charter: has("Charter", "mmmmlli 0123"),
        andale: has("Andale Mono", "mmmmlli 0123"),
        calibri: digit("Calibri"), cambria: digit("Cambria"), consolas: digit("Consolas"),
        segoe: digit("Segoe UI"),
      };
      """)
    guard result["ptSans"] as? Bool == true, result["charter"] as? Bool == true,
      result["andale"] as? Bool == true
    else { throw XCTSkip("PT Sans, Charter or Andale Mono is not installed") }
    for (family, advance) in [
      ("calibri", 1038.0 / 2048.0), ("cambria", 1135.0 / 2048.0), ("consolas", 1126.0 / 2048.0),
      ("segoe", 1100.0 / 2048.0),
    ] {
      XCTAssertEqual(try XCTUnwrap(result[family] as? Double), advance, accuracy: 0.003, family)
    }
  }

  func testAFontThePageDeclaresForTheSameNameWins() async throws {
    let view = try await load(
      """
      <!doctype html><html><head><meta charset="utf-8"><style>
      @font-face { font-family: "Segoe UI"; src: local("Arial"); }
      </style></head><body></body></html>
      """)
    let result = try await evaluate(
      view,
      """
      const digits = "0123456789";
      return { segoe: width('40px "Segoe UI"', digits), arial: width("40px Arial", digits) };
      """)
    XCTAssertEqual(
      try XCTUnwrap(result["segoe"] as? Double), try XCTUnwrap(result["arial"] as? Double),
      accuracy: 0.01)
  }

  /// The aliases are the first thing in the document, so a page's own style comes after them.
  func testTheAliasesComeFirstInTheDocument() async throws {
    let view = try await load(page)
    let result = try await evaluate(
      view,
      """
      const sheets = document.querySelectorAll("style[data-mwe-font-aliases]");
      return {
        count: sheets.length,
        first: document.documentElement.firstElementChild === sheets[0],
        faces: sheets.length ? sheets[0].sheet.cssRules.length : 0,
      };
      """)
    XCTAssertEqual(result["count"] as? Int, 1)
    XCTAssertEqual(result["first"] as? Bool, true)
    XCTAssertGreaterThan(result["faces"] as? Int ?? 0, 0)
  }

  func testASubframeGetsTheAliasesToo() async throws {
    let view = try await load(
      """
      <!doctype html><html><body><iframe id="frame" srcdoc="<!doctype html><html><body>x</body></html>"></iframe></body></html>
      """)
    // The frame loads after the parent finishes; wait for its document.
    let deadline = Date().addingTimeInterval(10)
    var result: [String: Any] = [:]
    while Date() < deadline {
      result = try await evaluate(
        view,
        """
        const frame = document.getElementById("frame").contentWindow;
        const ready = frame.document.readyState === "complete";
        return { ready, sheets: ready ? frame.document.querySelectorAll("style[data-mwe-font-aliases]").length : 0 };
        """)
      if result["ready"] as? Bool == true { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(result["sheets"] as? Int, 1)
  }

  /// A remote page a wallpaper embeds keeps the fonts its own browser gives it.
  func testRemoteDocumentsKeepTheirOwnFonts() async throws {
    let view = try await load(page, base: URL(string: "https://example.invalid/"))
    let result = try await evaluate(
      view,
      """
      return { protocol: location.protocol, sheets: document.querySelectorAll("style[data-mwe-font-aliases]").length };
      """)
    XCTAssertEqual(result["protocol"] as? String, "https:")
    XCTAssertEqual(result["sheets"] as? Int, 0)
  }

  /// Every web surface gets the aliases through the one list of user scripts.
  func testTheAliasesAreAmongTheUserScriptsEverySurfaceGets() {
    let sources = WebWallpaperProtocol.userScripts().map(\.source)
    XCTAssertTrue(sources.contains(WebWallpaperFontAliases.script))
  }

  /// The table names a face for every family and a range for the Chinese ones stock Windows lacks.
  func testTheTableIsWellFormed() {
    var seen = Set<String>()
    for alias in WebWallpaperFontAliases.aliases {
      XCTAssertFalse(alias.faces.isEmpty, "\(alias.families)")
      for family in alias.families {
        XCTAssertTrue(seen.insert(family).inserted, "\(family) is aliased twice")
      }
      for face in alias.faces {
        XCTAssertFalse(face.local.isEmpty, "\(alias.families)")
      }
    }
    let simHei = WebWallpaperFontAliases.aliases.first { $0.families.contains("SimHei") }
    XCTAssertEqual(simHei?.unicodeRange, WebWallpaperFontAliases.cjkRange)
    let yaHei = WebWallpaperFontAliases.aliases.first { $0.families.contains("Microsoft YaHei") }
    XCTAssertNil(yaHei?.unicodeRange)
  }
}
