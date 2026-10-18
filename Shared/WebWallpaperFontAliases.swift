import Foundation

/// The Windows font names a web wallpaper asks for, drawn in faces macOS has.
///
/// Wallpaper Engine runs a web wallpaper in Chromium on Windows, which finds the fonts a
/// stock Windows has: `SimHei` or `Microsoft YaHei` for Chinese text, `Segoe UI` or
/// `Consolas` for an interface. WebKit on a Mac finds none of them. A family it does not
/// have falls to the page's next family or the standard font, and CoreText's cascade then
/// takes Chinese from Songti, a serif capped at bold, so a heading set in `900 26pt SimHei`
/// comes out as a thin Song face where Wallpaper Engine draws a heavy sans, and a stack
/// that starts with `Segoe UI` draws its separators a third wider than Wallpaper Engine.
///
/// The script this builds runs at document start in every frame of a local page, before the
/// page's own style. For each font below that this Mac does not have, it declares an
/// `@font-face` for each of the font's names that maps it to the macOS face that stands in
/// for it, so the family resolves the way it does on Windows. A font that is installed is left
/// alone (Office for Mac installs Calibri, Cambria and Consolas), and a font the page declares
/// for the same name later in its own style takes precedence, as it would anywhere.
///
/// Whether a font is installed is asked of its first name. For the Latin fonts it is told by the
/// advance of a digit, because macOS answers some Windows names with a substitute of its own
/// (Calibri is Helvetica here) that a width test against the fallback would take for the font;
/// for the others, by whether text set in the name, over a fallback, measures other than the
/// fallback does.
///
/// The Latin stand-ins are fitted to the real fonts' digit advances with `size-adjust`,
/// the same numbers the scene renderer's text system uses for the same fonts
/// (`SystemFontResolver.cpp`). Not covered: the generic families (`sans-serif`,
/// `monospace`, `system-ui`), which differ between Chromium on Windows and WebKit and have
/// not been measured, and the real fonts' line metrics (`ascent-override` and its
/// siblings), whose support in the shipped WebKit is not established.
enum WebWallpaperFontAliases {
  /// One face of an alias: the weights and style it answers and the macOS faces that draw
  /// it, by PostScript or full name (the first that exists is used).
  struct Face: Encodable, Equatable {
    var weight: String
    var style: String
    var local: [String]
  }

  struct Alias: Encodable, Equatable {
    /// The Windows names of the font, the English one first, then the localised and the
    /// related ones.
    var families: [String]
    var faces: [Face]
    /// The code points the alias answers; nil is all of them. A Chinese family that stock
    /// Windows lacks keeps its Latin on the page's next family, as it does there.
    var unicodeRange: String?
    /// Scales the stand-in's glyphs and advances (`size-adjust`), e.g. "98.7%".
    var sizeAdjust: String?
    /// The width of a digit in the real font, in em, where it tells the real font from what
    /// macOS answers the name with.
    var digitAdvance: Double? = nil
  }

  /// Han, CJK punctuation, the compatibility ideographs and the full-width forms.
  static let cjkRange =
    "U+2E80-2FDF, U+3000-303F, U+3400-4DBF, U+4E00-9FFF, U+F900-FAFF, U+FF00-FFEF"

  /// A family set in one regular and one heavy face, the heavy for weights from 550.
  private static func twoWeights(regular: [String], heavy: [String]) -> [Face] {
    [
      Face(weight: "100 549", style: "normal", local: regular),
      Face(weight: "550 900", style: "normal", local: heavy),
    ]
  }

  private static let pingFangSC = twoWeights(
    regular: ["PingFangSC-Regular", "PingFang SC Regular"],
    heavy: ["PingFangSC-Semibold", "PingFang SC Semibold"])
  private static let pingFangTC = twoWeights(
    regular: ["PingFangTC-Regular", "PingFang TC Regular"],
    heavy: ["PingFangTC-Semibold", "PingFang TC Semibold"])
  private static let songtiSC = twoWeights(
    regular: ["STSongti-SC-Regular", "Songti SC Regular"],
    heavy: ["STSongti-SC-Bold", "Songti SC Bold"])
  private static let kaitiSC = twoWeights(
    regular: ["STKaitiSC-Regular", "Kaiti SC Regular"],
    heavy: ["STKaitiSC-Bold", "Kaiti SC Bold"])
  private static let hiraginoSans = twoWeights(
    regular: ["HiraginoSans-W3", "Hiragino Sans W3", "HiraKakuProN-W3"],
    heavy: ["HiraginoSans-W6", "Hiragino Sans W6", "HiraKakuProN-W6"])
  private static let hiraginoMincho = twoWeights(
    regular: ["HiraMinProN-W3", "Hiragino Mincho ProN W3"],
    heavy: ["HiraMinProN-W6", "Hiragino Mincho ProN W6"])
  private static let appleSDGothicNeo = twoWeights(
    regular: ["AppleSDGothicNeo-Regular", "Apple SD Gothic Neo Regular"],
    heavy: ["AppleSDGothicNeo-Bold", "Apple SD Gothic Neo Bold"])

  /// A Latin family set in four faces.
  private static func fourFaces(
    regular: String, bold: String, italic: String, boldItalic: String
  ) -> [Face] {
    [
      Face(weight: "100 549", style: "normal", local: [regular]),
      Face(weight: "550 900", style: "normal", local: [bold]),
      Face(weight: "100 549", style: "italic", local: [italic]),
      Face(weight: "550 900", style: "italic", local: [boldItalic]),
    ]
  }

  private static let ptSans = fourFaces(
    regular: "PTSans-Regular", bold: "PTSans-Bold", italic: "PTSans-Italic",
    boldItalic: "PTSans-BoldItalic")
  private static let charter = fourFaces(
    regular: "Charter-Roman", bold: "Charter-Bold", italic: "Charter-Italic",
    boldItalic: "Charter-BoldItalic")

  static let aliases: [Alias] = [
    // Chinese. The families stock Windows ships answer every code point; the ones it does not
    // (SimHei, KaiTi) answer the Han range only.
    Alias(
      families: ["Microsoft YaHei", "微软雅黑", "Microsoft YaHei UI"], faces: pingFangSC,
      unicodeRange: nil, sizeAdjust: nil),
    Alias(families: ["DengXian", "等线"], faces: pingFangSC, unicodeRange: nil, sizeAdjust: nil),
    Alias(
      families: ["SimHei", "黑体"], faces: pingFangSC, unicodeRange: cjkRange, sizeAdjust: nil),
    Alias(
      families: ["Microsoft JhengHei", "微軟正黑體", "Microsoft JhengHei UI"], faces: pingFangTC,
      unicodeRange: nil, sizeAdjust: nil),
    Alias(
      families: ["SimSun", "宋体", "NSimSun", "新宋体"], faces: songtiSC, unicodeRange: nil,
      sizeAdjust: nil),
    Alias(
      families: ["KaiTi", "楷体", "KaiTi_GB2312"], faces: kaitiSC, unicodeRange: cjkRange,
      sizeAdjust: nil),
    // Japanese and Korean.
    Alias(
      families: [
        "Yu Gothic", "Yu Gothic UI", "Meiryo", "Meiryo UI", "MS Gothic", "MS PGothic",
        "MS UI Gothic",
      ], faces: hiraginoSans, unicodeRange: nil, sizeAdjust: nil),
    Alias(
      families: ["MS Mincho", "MS PMincho", "Yu Mincho"], faces: hiraginoMincho,
      unicodeRange: nil, sizeAdjust: nil),
    Alias(
      families: ["Malgun Gothic"], faces: appleSDGothicNeo, unicodeRange: nil, sizeAdjust: nil),
    // Latin interface fonts, fitted to the real fonts' digit advances (1100/2048 em for Segoe UI,
    // 1038/2048 for Calibri, 1135/2048 for Cambria, 1126/2048 for Consolas).
    Alias(
      families: ["Segoe UI"], faces: ptSans, unicodeRange: nil, sizeAdjust: "98.7%",
      digitAdvance: 1100.0 / 2048.0),
    Alias(
      families: ["Calibri"], faces: ptSans, unicodeRange: nil, sizeAdjust: "93%",
      digitAdvance: 1038.0 / 2048.0),
    Alias(
      families: ["Cambria"], faces: charter, unicodeRange: nil, sizeAdjust: "99.6%",
      digitAdvance: 1135.0 / 2048.0),
    Alias(
      families: ["Consolas"],
      faces: [Face(weight: "400", style: "normal", local: ["AndaleMono", "Andale Mono"])],
      unicodeRange: nil, sizeAdjust: "91.6%", digitAdvance: 1126.0 / 2048.0),
  ]

  /// The user script: it is idempotent per document and does nothing in a document that
  /// has every family already.
  static let script: String = {
    let encoder = JSONEncoder()
    let table = (try? encoder.encode(aliases)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    return """
      (() => {
        if (window.__mweFontAliases) return;
        Object.defineProperty(window, "__mweFontAliases", { value: true });
        // A remote page a wallpaper embeds keeps the fonts its own browser gives it.
        if (location.protocol === "http:" || location.protocol === "https:") return;
        const aliases = \(table);
        let measure;
        try {
          const canvas = typeof OffscreenCanvas === "function" ? new OffscreenCanvas(8, 8) : document.createElement("canvas");
          const context = canvas.getContext("2d");
          measure = (font, text) => { context.font = font; return context.measureText(text).width; };
        } catch (error) { return; }
        const probe = "mmmmmmmmmmlli 0123";
        const monospace = measure("72px monospace", probe), serif = measure("72px serif", probe);
        // Text set in a family that is installed, over a fallback, measures other than the
        // fallback alone: over two fallbacks, so that one the family happens to share a width
        // with does not hide it.
        const present = family =>
          measure(`72px "${family}", monospace`, probe) !== monospace ||
          measure(`72px "${family}", serif`, probe) !== serif;
        // A font whose digit advance is known is installed when the family's digits are that wide.
        const installed = alias => alias.digitAdvance
          ? Math.abs(measure(`1000px "${alias.families[0]}", monospace`, "0") / 1000 - alias.digitAdvance) < 0.0008
          : present(alias.families[0]);
        const quote = text => `"${text.replace(/["\\\\]/g, "")}"`;
        let css = "";
        for (const alias of aliases) {
          if (installed(alias)) continue;
          for (const family of alias.families) {
            for (const face of alias.faces) {
              css += `@font-face{font-family:${quote(family)};` +
                `src:${face.local.map(name => `local(${quote(name)})`).join(",")};` +
                `font-weight:${face.weight};font-style:${face.style};` +
                (alias.unicodeRange ? `unicode-range:${alias.unicodeRange};` : "") +
                (alias.sizeAdjust ? `size-adjust:${alias.sizeAdjust};` : "") + "}";
            }
          }
        }
        if (!css) return;
        const sheet = document.createElement("style");
        sheet.setAttribute("data-mwe-font-aliases", "");
        sheet.textContent = css;
        // First in the document, so that a font the page declares for the same name wins.
        const place = () => {
          const root = document.documentElement;
          if (!root) return false;
          root.insertBefore(sheet, root.firstChild);
          return true;
        };
        if (place()) return;
        const observer = new MutationObserver(() => { if (place()) observer.disconnect(); });
        observer.observe(document, { childList: true });
      })();
      """
  }()
}
