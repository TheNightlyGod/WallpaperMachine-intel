import SwiftUI
import XCTest

@testable import WallpaperMachine

/// The rich label of a property: author markup reduced to an allowlist of presentation. The inputs
/// are the fixtures of `WebPanelPropertyLabelTests` and the page's `property-label.js` rules; the
/// outputs are typed blocks, so no author can add a control, run a script or reach a host the panel
/// does not name.
@MainActor
final class PropertyLabelDocumentTests: XCTestCase {
  private func parse(_ html: String, images: [String: URL] = [:]) -> PropertyLabelDocument {
    PropertyLabelDocument.parse(html, images: images)
  }

  private func paragraph(_ block: PropertyLabelDocument.Block?) -> PropertyLabelDocument.Paragraph? {
    if case .paragraph(let paragraph)? = block { return paragraph }
    return nil
  }

  // MARK: Text

  func testPlainTextIsOneParagraphAndEmptyMarkupIsNothing() {
    let document = parse("Character size")
    XCTAssertEqual(document.blocks.count, 1)
    XCTAssertEqual(paragraph(document.blocks.first)?.runs.map(\.text), ["Character size"])
    XCTAssertEqual(document.plainText, "Character size")
    XCTAssertTrue(parse("").isEmpty)
    XCTAssertTrue(parse("   \n  ").isEmpty)
  }

  func testAnEscapedTagStaysTextAndIsDecodedOnce() {
    XCTAssertEqual(parse("&amp;lt;b&amp;gt; stays text").plainText, "&lt;b&gt; stays text")
    XCTAssertEqual(parse("&lt;b&gt;bold&lt;/b&gt;").plainText, "<b>bold</b>", "decoded once, as characters")
    XCTAssertEqual(parse("Fish &amp; chips").plainText, "Fish & chips")
    let escapedInjection = parse("<img src=x onerror=alert(1)>")
    XCTAssertTrue(escapedInjection.isEmpty, "an unregistered image with no alt text is nothing")
    XCTAssertEqual(parse("&#60;img src=x onerror=alert(1)&#62;").plainText, "<img src=x onerror=alert(1)>")
  }

  func testEntitiesAreDecodedWithOrWithoutTheSemicolonTheAuthorForgot() {
    XCTAssertEqual(parse("a&nbsp;b").plainText, "a b")
    XCTAssertEqual(parse("&#x41;&#66;&#x1F600;").plainText, "AB😀")
    // The page's fixture: indentation entities, one without its semicolon.
    let padded = parse("&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp镜头位置X（默认0）<br/>")
    XCTAssertEqual(padded.plainText, "镜头位置X（默认0）")
    XCTAssertEqual(parse("&unknown; &amp").plainText, "&unknown; &")
    XCTAssertEqual(parse("a & b").plainText, "a & b")
  }

  func testWhitespaceCollapsesLikeAPageAndBlocksAreTrimmed() {
    XCTAssertEqual(parse("  a \n\t b   c  ").plainText, "a b c")
    XCTAssertEqual(paragraph(parse("<p>one</p><p>two</p>").blocks.last)?.plainText, "two")
    XCTAssertEqual(parse("<p>one</p><p>two</p>").blocks.count, 2)
    XCTAssertEqual(parse("<div>one</div>two").blocks.count, 2, "a block element ends the line")
  }

  func testEmphasisSizesAndColoursBecomeRunAttributes() throws {
    let document = parse(
      "<b>bold</b> <i>it</i> <u>un</u> <s>st</s> <small>sm</small> <big>bg</big> x<sub>2</sub> y<sup>3</sup>")
    let runs = try XCTUnwrap(paragraph(document.blocks.first)).runs
    func run(_ text: String) -> PropertyLabelDocument.Run? { runs.first { $0.text == text } }
    XCTAssertEqual(run("bold")?.isBold, true)
    XCTAssertEqual(run("it")?.isItalic, true)
    XCTAssertEqual(run("un")?.isUnderlined, true)
    XCTAssertEqual(run("st")?.isStruck, true)
    XCTAssertLessThan(try XCTUnwrap(run("sm")?.scale), 1)
    XCTAssertGreaterThan(try XCTUnwrap(run("bg")?.scale), 1)
    XCTAssertEqual(run("2")?.baseline, .subscripted)
    XCTAssertEqual(run("3")?.baseline, .superscripted)

    // The page's fixture: a colour tag is styling, not part of the name, and the author's colour is
    // kept when it is a valid spelling.
    let tinted = try XCTUnwrap(paragraph(parse("<font color=red>图1自定义").blocks.first))
    XCTAssertEqual(tinted.runs.first?.color, "red")
    XCTAssertEqual(tinted.plainText, "图1自定义")
    let hex = try XCTUnwrap(paragraph(parse("<font color=\"#ff8800\" size=5>x</font>").blocks.first)).runs[0]
    XCTAssertEqual(hex.color, "#ff8800")
    XCTAssertEqual(hex.scale, 1.5)
    let invalid = try XCTUnwrap(
      paragraph(parse("<font color=\"red;background:url(x)\" size=\"99\">x</font>").blocks.first)
    ).runs[0]
    XCTAssertNil(invalid.color, "only a hex value or a name is a colour")
    XCTAssertEqual(invalid.scale, 1, "only sizes 1 to 7 count")
  }

  func testLabelColoursResolveFromHexAndNamesOnly() {
    let red = LabelColor.components("red")
    XCTAssertEqual(red?.red, 1)
    XCTAssertEqual(red?.green, 0)
    XCTAssertNotNil(LabelColor.components("#abc"))
    XCTAssertEqual(LabelColor.components("#abc")?.red ?? 0, 170.0 / 255, accuracy: 0.001)
    XCTAssertEqual(LabelColor.components("#11223344")?.alpha ?? 0, 68.0 / 255, accuracy: 0.001)
    XCTAssertNil(LabelColor.components("#abcde"), "five digits is no colour")
    XCTAssertNil(LabelColor.components("notacolour"))
    XCTAssertNil(LabelColor.components("#zzz"))
  }

  // MARK: Structure

  func testHeadingsRulesBreaksAndListsKeepTheirPlace() throws {
    let document = parse("<h3>人物<br>Character</h3><hr><ul><li>one</li><li>two</li></ul><ol><li>a</li><li>b</li></ol>")
    let heading = try XCTUnwrap(paragraph(document.blocks.first))
    XCTAssertEqual(heading.heading, 3)
    XCTAssertEqual(heading.runs.filter(\.isLineBreak).count, 1, "the line break is kept")
    XCTAssertEqual(heading.runs.first?.isBold, true)
    XCTAssertEqual(document.blocks[1], .rule)
    let markers = document.blocks.compactMap { paragraph($0)?.marker }
    XCTAssertEqual(markers, ["•", "•", "1.", "2."])
  }

  func testACentredLabelIsCentred() throws {
    let document = parse("<center>Title</center>after")
    XCTAssertEqual(paragraph(document.blocks.first)?.isCentered, true)
    XCTAssertEqual(paragraph(document.blocks.last)?.isCentered, false)
  }

  func testMarkupThatIsBrokenIsReadTheWayABrowserWouldRepairIt() {
    // The page's fixture: unclosed tags, a stray close and a break.
    let document = parse(
      "<center><big><b>Bilibili<br/><a href='https://space.bilibili.com/676093670'>和仓贤一的个人主页 (点击跳转)</a><big></p>"
    )
    XCTAssertEqual(document.plainText, "Bilibili 和仓贤一的个人主页 (点击跳转)")
    XCTAssertEqual(parse("a < b and c > d").plainText, "a < b and c > d")
    XCTAssertEqual(parse("<b>unclosed").plainText, "unclosed")
    XCTAssertEqual(parse("text</span></div>more").plainText, "textmore")
  }

  // MARK: What an author cannot do

  func testControlsScriptsAndForeignContentAreDroppedWithTheirChildren() {
    let html =
      "<h3>人物<br>Character</h3><font color=\"red\">Tint</font><script>window.injected = true</script>"
      + "<input data-action=\"delete\"><svg onload=\"window.injected = true\"><text>vector</text></svg>"
      + "<button>Click</button><style>p { color: red }</style><iframe src=\"https://evil.test\">frame</iframe>"
      + "<form>form text</form><textarea>area</textarea><select><option>choice</option></select><math>m</math>"
    let document = parse(html)
    XCTAssertEqual(document.plainText, "人物 Character\nTint")
    XCTAssertFalse(document.plainText.contains("injected"))
    XCTAssertFalse(document.plainText.contains("vector"))
    XCTAssertFalse(document.plainText.contains("Click"))
    XCTAssertFalse(document.plainText.contains("p {"))
    XCTAssertFalse(document.plainText.contains("frame"))
    XCTAssertFalse(document.plainText.contains("choice"))
  }

  func testUnknownElementsKeepTheirChildrenButNotTheTag() {
    XCTAssertEqual(parse("<table><tr><td>cell</td></tr></table>").plainText, "cell")
    XCTAssertEqual(parse("<blink onclick=\"x()\">words</blink>").plainText, "words")
  }

  func testLinksSurviveOnlyForAllowedHostsAndNeverNested() throws {
    func link(_ html: String) throws -> URL? {
      try XCTUnwrap(paragraph(parse(html).blocks.first)).runs.first { $0.link != nil }?.link
    }
    let bilibili = try link("<a href=\"https://space.bilibili.com/111174060/\">me</a>")
    XCTAssertEqual(bilibili?.absoluteString, "https://space.bilibili.com/111174060/")
    XCTAssertNotNil(try link("<a href=\"https://steamcommunity.com/id/x\">x</a>"))
    XCTAssertNotNil(try link("<a href=\"https://github.com/o/r\">x</a>"))
    for refused in [
      "javascript:alert(1)", "http://steamcommunity.com/x", "https://evil.test/x",
      "https://user:pass@github.com/x", "https://github.com:8443/x", "https://www.pixiv.net/artworks/1",
      "https://help.steampowered.com/x", "file:///etc/passwd", "",
    ] {
      XCTAssertNil(try link("<a href=\"\(refused)\">x</a>"), "\(refused) is not a link")
    }
    // The text of a link the panel will not open stays, drawn as emphasised text.
    let unsafe = try XCTUnwrap(paragraph(parse("<a href=\"javascript:alert(1)\">Unsafe</a>").blocks.first))
    XCTAssertEqual(unsafe.plainText, "Unsafe")
    XCTAssertEqual(unsafe.runs.first?.isAccented, true)
    // A link inside a link is not a second link.
    let nested = try XCTUnwrap(
      paragraph(
        parse("<a href=\"https://github.com/a\">outer <a href=\"https://github.com/b\">inner</a></a>")
          .blocks.first))
    XCTAssertEqual(nested.runs.compactMap(\.link).map(\.absoluteString).filter { $0.hasSuffix("/b") }, [])
    XCTAssertTrue(PropertyLabelDocument.allowedLink("https://github.com/a") != nil)
  }

  func testOnlyARegisteredImageIsDrawnAndItsSizeIsHeld() throws {
    let registered = URL(string: "https://i.ibb.co/example/image.gif")!
    let images = ["https://i.ibb.co/example/image.gif": registered]
    let document = parse(
      "<center><a href=\"https://space.bilibili.com/111174060/\"><img src=\"https://i.ibb.co/example/image.gif\" width=\"105%\" onerror=\"alert(1)\"></a></center><hr>",
      images: images)
    guard case .image(let image) = document.blocks.first else {
      return XCTFail("the registered picture is a block")
    }
    XCTAssertEqual(image.url, registered)
    XCTAssertEqual(image.width, .percent(100), "a share is held to 1...100")
    XCTAssertEqual(image.link?.absoluteString, "https://space.bilibili.com/111174060/")
    XCTAssertTrue(image.isCentered)
    XCTAssertEqual(document.blocks.last, .rule, "the author's rule is kept")

    let sized = parse("<img src=\"https://i.ibb.co/example/image.gif\" width=\"5000\" height=\"90\">", images: images)
    guard case .image(let large) = sized.blocks.first else { return XCTFail("a block") }
    XCTAssertEqual(large.width, .pixels(2048))
    XCTAssertEqual(large.height, 90)

    // An address that is not registered is its alt text, or nothing; the page's image strip is decoration.
    let strip = parse(
      "<img src=\"http://photogz.photo.store.qq.com/psc?/V12uhwIt3z28yp/bqQ!/b&bo=HgEIAA!&rf=viewer_4\" width=\"2000\" height=\"1\">",
      images: images)
    XCTAssertTrue(strip.isEmpty)
    XCTAssertEqual(
      parse("<img src=\"https://evil.test/x\" alt=\"A picture\">", images: images).plainText, "A picture")
  }

  func testTheLimitsOfTheSourceTheNodesAndTheDepthHold() {
    let long = String(repeating: "a", count: PropertyLabelDocument.maximumSource + 500)
    XCTAssertEqual(parse(long).plainText.count, PropertyLabelDocument.maximumSource)

    let many = String(repeating: "<b>x</b>", count: 2_000)
    XCTAssertLessThanOrEqual(
      parse(many).plainText.count, PropertyLabelDocument.maximumNodes,
      "no more than a thousand nodes are read")

    let nested =
      String(repeating: "<span>", count: PropertyLabelDocument.maximumDepth + 8) + "deep"
      + String(repeating: "</span>", count: PropertyLabelDocument.maximumDepth + 8)
    XCTAssertEqual(parse(nested).plainText, "", "text more than 24 levels down is not drawn")
    let shallow =
      String(repeating: "<span>", count: PropertyLabelDocument.maximumDepth - 1) + "ok"
      + String(repeating: "</span>", count: PropertyLabelDocument.maximumDepth - 1)
    XCTAssertEqual(parse(shallow).plainText, "ok")
  }

  // MARK: Attributed text

  func testTheAttributedTextCarriesTheRunsAttributesAndOnlyAllowedLinks() throws {
    let document = parse(
      "<b>Bold</b> and <font color=red>red</font> <a href=\"https://github.com/o/r\">link</a>")
    let paragraph = try XCTUnwrap(paragraph(document.blocks.first))
    let attributed = PropertyLabelView.attributed(
      paragraph, baseSize: 13, baseWeight: .regular, accent: .blue)
    XCTAssertEqual(String(attributed.characters), "Bold and red link")
    let links = attributed.runs.compactMap(\.link)
    XCTAssertEqual(links.map(\.absoluteString), ["https://github.com/o/r"])
    XCTAssertNotNil(attributed.runs.first { $0.foregroundColor != nil })
  }
}
