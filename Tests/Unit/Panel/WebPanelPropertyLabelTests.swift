import AppKit
import WebKit
import XCTest

@testable import WallpaperMachine

/// Authored labels retain presentation without gaining panel privileges. Plain
/// names remain available to native pickers and unnamed controls never expose ids.
@MainActor
final class WebPanelPropertyLabelTests: XCTestCase {
  func testAuthorMarkupIsReducedToTheWordsItCarries() throws {
    let context = try Context()
    defer { context.tearDown() }
    let labels = [
      "tinted": "<font color=red>图1自定义",
      "linked":
        "<center><big><b>Bilibili<br/><a href='https://space.bilibili.com/676093670'>和仓贤一的个人主页 (点击跳转)</a><big></p>",
      "padded": "&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp镜头位置X（默认0）<br/>",
      "escaped": "&amp;lt;b&amp;gt; stays text",
      "strip":
        "<img src=\"http://photogz.photo.store.qq.com/psc?/V12uhwIt3z28yp/bqQ!/b&bo=HgEIAA!&rf=viewer_4\" width=\"2000\" height=\"1\">",
      "rule": "<hr>",
      "scheme": "ui_browse_properties_scheme_color",
    ]
    context.store.wallpaperOptionsSnapshot = BridgeSnapshotFixtures.options(
      wallpaperId: "scene-1", kind: .projectScene,
      properties: labels.keys.sorted().map { Self.property(id: $0, labelHtml: labels[$0] ?? "") })

    let rows = try XCTUnwrap(
      (context.controller.snapshot()["options"] as? [String: Any])?["properties"]
        as? [[String: Any]])
    let label = { (id: String) in rows.first { $0["id"] as? String == id }?["label"] as? String }

    XCTAssertEqual(label("tinted"), "图1自定义", "A colour tag is styling, not part of the name")
    XCTAssertEqual(
      label("linked"), "Bilibili 和仓贤一的个人主页 (点击跳转)",
      "A line break separates words rather than gluing them into one run")
    XCTAssertEqual(
      label("padded"), "镜头位置X（默认0）",
      "Indent entities — with or without the semicolon the author forgot — are whitespace")
    XCTAssertEqual(
      label("escaped"), "&lt;b&gt; stays text",
      "An escaped ampersand is decoded once, so escaped markup cannot come back as markup")
    XCTAssertEqual(
      label("strip"), "", "An image strip is decoration: it carries no word to show")
    XCTAssertEqual(label("rule"), "", "Nor does a rule")
    XCTAssertNotEqual(
      label("scheme"), "ui_browse_properties_scheme_color",
      "The editor's own token for the scheme colour must never reach the user")
    XCTAssertFalse(label("scheme")?.isEmpty ?? true)
  }

  func testPagePreservesPresentationAndRejectsAuthorControls() async throws {
    let context = try Context()
    defer { context.tearDown() }
    guard let (web, payload) = try await loadedPage(context) else { return }

    // The id an author ends up with when the editor slugs an image tag into a key.
    let slug = "imgsrchttpphotogzphotostoreqqcompscv12uhwit3z28ypviewer_4width2000height51"
    let result =
      try await web.callAsyncJavaScript(
        """
        const waitFor = async predicate => {
          const deadline = Date.now() + 5000;
          while (!predicate()) {
            if (Date.now() > deadline) throw new Error('The inspector did not settle');
            await new Promise(resolve => setTimeout(resolve, 20));
          }
        };
        const property = (id, kind, label) => ({
          id, kind, label, value: kind === 'boolean' ? true : '', defaultValue: null,
          enabled: true, dirty: false, min: 0, max: 1, step: 0.01, options: [] });
        const show = properties => window.wallpaperUI.receive(Object.assign({}, base, {
          page: 'installed', selectedID: 'scene-1',
          wallpapers: [{ id: 'scene-1', title: 'Scene one', kind: 'Scene', preview: null, active: false, supported: true, tags: [] }],
          options: { id: 'scene-1', kind: 'Scene', supported: true, dirty: false, volume: 1, muted: false,
            audioResponseEnabled: true, mediaIntegrationEnabled: false, displays: [], properties } }));
        const field = id => document.querySelector(`#inspector [data-key="${id}"]`);
        const section = () => [...document.querySelectorAll('#inspector summary')]
          .some(node => node.textContent.includes('Wallpaper properties'));

        show([property(slug, 'boolean', ''), property('deco', 'text', ''), property('real', 'slider', 'Character size')]);
        await waitFor(() => field('real'));
        const named = field(slug).querySelector('.field-title label');
        const mixed = {
          unnamedText: named.textContent,
          unnamedMentionsSlug: field(slug).textContent.includes(slug),
          unnamedControls: named.getAttribute('for') === field(slug).querySelector('input').id,
          wordlessTextRow: field('deco') !== null,
          namedRow: field('real').querySelector('.field-title label').textContent,
          section: section(),
        };

        show([property('deco', 'text', '')]);
        await waitFor(() => !field('real'));
        const decorationOnlySection = section();
        const rich = property('rich', 'boolean', 'Character');
        rich.labelHTML = '<h3>人物<br>Character</h3><font color="red">Tint</font><script>window.injected = true</script><input data-action="delete"><img src="https://evil.test/x" onerror="window.injected = true"><svg onload="window.injected = true"></svg><a href="javascript:alert(1)">Unsafe</a>';
        const art = property('art', 'text', '');
        art.labelHTML = '<center><a href="https://space.bilibili.com/111174060/"><img src="https://i.ibb.co/example/image.gif" width="105%" onerror="alert(1)"></a></center><hr>';
        art.labelImages = { 'https://i.ibb.co/example/image.gif': 'mwe-ui://property-image/' + 'a'.repeat(64) };
        const escaped = property('escaped', 'text', '<img src=x onerror=alert(1)>');
        const heading = property('heading', 'text', 'Effect settings');
        heading.labelHTML = '<h3>Effect settings</h3><a><h5>Instructions</h5></a>';
        show([rich, art, escaped, heading]);
        await waitFor(() => field('rich'));
        const label = field('rich').querySelector('.property-label');
        const image = field('art').querySelector('img');
        const link = field('art').querySelector('[data-action="openExternal"]');
        return Object.assign(mixed, {
          decorationOnlySection,
          heading: label.querySelector('h3')?.textContent,
          lineBreaks: label.querySelectorAll('br').length,
          color: label.querySelector('font')?.getAttribute('color'),
          injected: Boolean(window.injected),
          unsafeElements: label.querySelectorAll('script, input, svg, [onerror], [data-action]').length,
          escapedText: field('escaped').textContent,
          escapedImages: field('escaped').querySelectorAll('img').length,
          imageSource: image?.getAttribute('src'),
          imageWidth: image?.getAttribute('width'),
          authorRule: Boolean(field('art').querySelector('hr')),
          authorLink: link?.dataset.url,
          linkIsKeyboardControl: link?.tagName === 'BUTTON' && link.type === 'button',
          descriptionHeading: field('heading').querySelector('h3')?.textContent,
        });
        """, arguments: ["base": payload, "slug": slug], in: nil, contentWorld: .page)
      as? [String: Any]
    let page = try XCTUnwrap(result)

    XCTAssertEqual(
      page["unnamedText"] as? String, "Unnamed option",
      "A control whose label was pure decoration still needs a name a person can read")
    XCTAssertEqual(
      page["unnamedMentionsSlug"] as? Bool, false,
      "…and the editor's slug of the markup is not that name")
    XCTAssertEqual(
      page["unnamedControls"] as? Bool, true, "The stand-in name still labels the control")
    XCTAssertEqual(
      page["wordlessTextRow"] as? Bool, false,
      "A text property is only its label, so one with no words is left out")
    XCTAssertEqual(page["namedRow"] as? String, "Character size", "A real label is untouched")
    XCTAssertEqual(page["section"] as? Bool, true)
    XCTAssertEqual(
      page["decorationOnlySection"] as? Bool, false,
      "With every property left out, the empty disclosure goes too")
    XCTAssertEqual(page["heading"] as? String, "人物Character")
    XCTAssertEqual(page["lineBreaks"] as? Int, 1)
    XCTAssertEqual(page["color"] as? String, "red")
    XCTAssertEqual(page["injected"] as? Bool, false)
    XCTAssertEqual(page["unsafeElements"] as? Int, 0)
    XCTAssertEqual(page["escapedText"] as? String, "<img src=x onerror=alert(1)>")
    XCTAssertEqual(page["escapedImages"] as? Int, 0)
    XCTAssertEqual(page["imageSource"] as? String, "mwe-ui://property-image/" + String(repeating: "a", count: 64))
    XCTAssertEqual(page["imageWidth"] as? String, "100%")
    XCTAssertEqual(page["authorRule"] as? Bool, true)
    XCTAssertEqual(page["authorLink"] as? String, "https://space.bilibili.com/111174060/")
    XCTAssertEqual(page["linkIsKeyboardControl"] as? Bool, true)
    XCTAssertEqual(page["descriptionHeading"] as? String, "Effect settings")
  }

  func testGroupKindReachesThePageAsGroup() throws {
    let context = try Context()
    defer { context.tearDown() }
    let rows: [(id: String, kind: BridgePropertyKind)] = [
      ("section", .group), ("note", .text), ("other", .unknown), ("toggle", .bool),
    ]
    context.store.wallpaperOptionsSnapshot = BridgeSnapshotFixtures.options(
      wallpaperId: "scene-1", kind: .projectScene,
      properties: rows.map { Self.property(id: $0.id, kind: $0.kind, labelHtml: "Characters") })

    let payload = try XCTUnwrap(
      (context.controller.snapshot()["options"] as? [String: Any])?["properties"]
        as? [[String: Any]])
    let kinds = Dictionary(
      uniqueKeysWithValues: payload.compactMap { row -> (String, String)? in
        guard let id = row["id"] as? String, let kind = row["kind"] as? String else { return nil }
        return (id, kind)
      })

    XCTAssertEqual(kinds["section"], "group", "A group is a heading, not a description")
    XCTAssertEqual(kinds["note"], "text", "A text record is still a description")
    XCTAssertEqual(kinds["other"], "text", "So is a record the app does not know")
    XCTAssertEqual(kinds["toggle"], "boolean")
  }

  func testGroupsAreHeadingsAndEmptyOnesAreDropped() async throws {
    let context = try Context()
    defer { context.tearDown() }
    context.store.wallpaperOptionsSnapshot = BridgeSnapshotFixtures.options(
      wallpaperId: "scene-1", kind: .projectScene,
      properties: [
        Self.property(id: "chars", kind: .group, labelHtml: "Characters"),
        Self.property(id: "hair", kind: .bool, labelHtml: "Show hair"),
        Self.property(id: "blank", kind: .group, labelHtml: ""),
        Self.property(
          id: "light", kind: .group,
          labelHtml: "<font color=red>Lighting</font><script>window.injected = true</script>"),
        Self.property(id: "glow", kind: .bool, labelHtml: "Glow"),
      ])
    let options = try XCTUnwrap(context.controller.snapshot()["options"] as? [String: Any])
    guard let (web, base) = try await loadedPage(context) else { return }

    let result =
      try await web.callAsyncJavaScript(
        """
        window.wallpaperUI.receive(Object.assign({}, base, {
          page: 'installed', selectedID: 'scene-1',
          wallpapers: [{ id: 'scene-1', title: 'Scene one', kind: 'Scene', preview: null, active: false, supported: true, tags: [] }],
          options }));
        const field = id => document.querySelector(`#inspector [data-key="${id}"]`);
        const deadline = Date.now() + 5000;
        while (!field('glow')) {
          if (Date.now() > deadline) throw new Error('The inspector did not settle');
          await new Promise(resolve => setTimeout(resolve, 20));
        }
        const heading = id => {
          const node = field(id);
          return node && {
            role: node.getAttribute('role'),
            level: node.getAttribute('aria-level'),
            text: node.textContent,
            controls: node.querySelectorAll('input, button, select, textarea, [data-change], [data-action]').length,
            color: node.querySelector('font')?.getAttribute('color') ?? null,
            scripts: node.querySelectorAll('script').length,
          };
        };
        return {
          order: [...document.querySelectorAll('#inspector .property-group, #inspector .property-row')]
            .map(node => node.dataset.key),
          chars: heading('chars'),
          light: heading('light'),
          injected: Boolean(window.injected),
          hair: {
            label: field('hair').querySelector('.field-title label')?.textContent,
            checkbox: field('hair').querySelectorAll('input[type="checkbox"]').length,
            heading: field('hair').getAttribute('role'),
          },
        };
        """, arguments: ["base": base, "options": options], in: nil, contentWorld: .page)
      as? [String: Any]
    let page = try XCTUnwrap(result)

    XCTAssertEqual(
      page["order"] as? [String], ["chars", "hair", "light", "glow"],
      "Groups keep their place among the controls, and a group with no words is left out")
    let characters = try XCTUnwrap(page["chars"] as? [String: Any])
    XCTAssertEqual(characters["role"] as? String, "heading")
    XCTAssertEqual(characters["level"] as? String, "3")
    XCTAssertEqual(characters["text"] as? String, "Characters")
    XCTAssertEqual(characters["controls"] as? Int, 0, "A heading names controls; it is not one")
    let lighting = try XCTUnwrap(page["light"] as? [String: Any])
    XCTAssertEqual(lighting["role"] as? String, "heading")
    XCTAssertEqual(lighting["text"] as? String, "Lighting", "A script in the label is not text")
    XCTAssertEqual(lighting["color"] as? String, "red", "An author's colour is kept")
    XCTAssertEqual(lighting["scripts"] as? Int, 0)
    XCTAssertEqual(page["injected"] as? Bool, false)
    let hair = try XCTUnwrap(page["hair"] as? [String: Any])
    XCTAssertEqual(hair["label"] as? String, "Show hair", "A control after a group is unchanged")
    XCTAssertEqual(hair["checkbox"] as? Int, 1)
    XCTAssertNil(hair["heading"] as? String, "Only a group is a heading")
  }

  func testRestoreAllIsOfferedOnlyWhenSomethingDiffersFromDefault() async throws {
    let context = try Context()
    defer { context.tearDown() }
    func options(
      slider: Bool = false, file: Bool = false, supported: Bool = true, hiddenText: Bool = false,
      hiddenFile: Bool = false
    ) throws -> [String: Any] {
      context.store.wallpaperOptionsSnapshot = BridgeSnapshotFixtures.options(
        wallpaperId: "scene-1", kind: .projectScene, supported: supported,
        properties: [
          Self.property(id: "size", kind: .slider, labelHtml: "Size", dirty: slider),
          Self.property(id: "title", kind: .textInput, labelHtml: "Title"),
          Self.property(
            id: "clip", kind: .file, labelHtml: "Clip", dirty: file,
            value: .string(value: "/chosen/clip.webm")),
          // Rows a visibility rule hides: the page is never given them.
          Self.property(
            id: "secret", kind: .textInput, labelHtml: "Secret", dirty: hiddenText, enabled: false),
          Self.property(
            id: "vault", kind: .file, labelHtml: "Vault", dirty: hiddenFile,
            value: .string(value: "/chosen/vault.webm"), enabled: false),
        ])
      return try XCTUnwrap(context.controller.snapshot()["options"] as? [String: Any])
    }
    let clean = try options()
    let sliderEdited = try options(slider: true)
    let fileChosen = try options(file: true)
    let hiddenOnly = try options(hiddenText: true)
    let hiddenFileOnly = try options(hiddenFile: true)
    let unsupported = try options(slider: true, supported: false)
    guard let (web, base) = try await loadedPage(context) else { return }

    let result =
      try await web.callAsyncJavaScript(
        """
        const show = options => window.wallpaperUI.receive(Object.assign({}, base, {
          page: 'installed', selectedID: 'scene-1',
          wallpapers: [{ id: 'scene-1', title: 'Scene one', kind: 'Scene', preview: null, active: false, supported: true, tags: [] }],
          options }));
        const settled = async (predicate, what) => {
          const deadline = Date.now() + 5000;
          while (!predicate()) {
            if (Date.now() > deadline) throw new Error(`The inspector did not settle: ${what}`);
            await new Promise(resolve => setTimeout(resolve, 20));
          }
        };
        const button = () => document.querySelector('#inspector [data-action="restoreAllProperties"]');
        const modified = id => Boolean(document.querySelector(`#inspector [data-key="${id}"] .field-flag`));
        const log = {};

        show(clean);
        await settled(() => button() && document.querySelector('#inspector [data-key="clip"]'), 'clean');
        log.clean = { disabled: button().disabled };

        show(sliderEdited);
        await settled(() => modified('size'), 'slider edited');
        log.slider = { disabled: button().disabled };

        show(fileChosen);
        await settled(() => !modified('size') && modified('clip'), 'file chosen');
        log.file = { disabled: button().disabled };

        show(hiddenOnly);
        await settled(() => !modified('clip') && button().disabled === false, 'hidden value modified');
        log.hidden = { disabled: button().disabled, listed: Boolean(document.querySelector('#inspector [data-key="secret"]')) };

        show(hiddenFileOnly);
        await settled(() => button().disabled, 'hidden file chosen');
        log.hiddenFile = { disabled: button().disabled, listed: Boolean(document.querySelector('#inspector [data-key="vault"]')) };

        show(unsupported);
        await settled(() => modified('size') && document.querySelector('#inspector .notice.warning'), 'unsupported');
        log.unsupported = { disabled: button().disabled };

        show(clean);
        await settled(() => !modified('clip') && !modified('size'), 'clean again');
        const title = document.querySelector('#inspector [data-key="title"] input[data-input="property"]');
        title.value = 'typed, not sent yet';
        title.dispatchEvent(new Event('input', { bubbles: true }));
        await settled(() => modified('title'), 'draft');
        log.draft = { disabled: button().disabled, modified: modified('title') };
        return log;
        """,
        arguments: [
          "base": base, "clean": clean, "sliderEdited": sliderEdited, "fileChosen": fileChosen,
          "hiddenOnly": hiddenOnly, "hiddenFileOnly": hiddenFileOnly, "unsupported": unsupported,
        ], in: nil, contentWorld: .page) as? [String: [String: Bool]]
    let log = try XCTUnwrap(result)

    XCTAssertEqual(log["clean"]?["disabled"], true, "Nothing differs from the defaults")
    XCTAssertEqual(log["slider"]?["disabled"], false, "A modified slider can be restored")
    XCTAssertEqual(
      log["file"]?["disabled"], true,
      "A chosen file keeps its own Clear, so it alone gives restore all nothing to do")
    XCTAssertEqual(
      log["hidden"]?["disabled"], false,
      "A modified value behind a rule that hides its row still reaches the wallpaper, so it can be restored")
    XCTAssertEqual(log["hidden"]?["listed"], false, "The page is not given the hidden row")
    XCTAssertEqual(
      log["hiddenFile"]?["disabled"], true, "A hidden file keeps its own Clear as well")
    XCTAssertEqual(log["hiddenFile"]?["listed"], false)
    XCTAssertEqual(
      log["unsupported"]?["disabled"], true, "A wallpaper that cannot be rendered has no staging")
    XCTAssertEqual(log["draft"]?["modified"], true)
    XCTAssertEqual(log["draft"]?["disabled"], false, "Text not yet sent counts as a change")
  }

  func testEngineTokensBecomeReadableWords() {
    let words: [(token: String, label: String)] = [
      ("ui_editor_properties_pivot_offset_x", "Pivot offset x"),
      ("ui_editor_user_properties_type_color", "Color"),
      ("ui_browse_context_menu_default", "Default"),
      ("ui_workshop_tags_customizable", "Customizable"),
      ("ui_editor_effect_opacity_title", "Opacity"),
      ("ui_editor_effect_chromatic_abberation_title", "Chromatic abberation"),
      ("ui_24h_clock", "24h clock"),
      // Surrounding space is ignored, as it is where a wallpaper's own table is consulted.
      ("  ui_editor_properties_size\n", "Size"),
      // The area and caption words are dropped, but never the last word left.
      ("ui_editor_properties", "Properties"),
      ("ui_title", "Title"),
      ("ui_label_title", "Label"),
      ("ui_editor__effect___speed_", "Speed"),
      // Exactly the longest token the editor could have written.
      ("ui_" + String(repeating: "a", count: 93), String(repeating: "a", count: 93).capitalized),
    ]
    for (token, label) in words {
      XCTAssertEqual(WebPanelController.engineTokenLabel(token), label, token)
    }

    let notTokens = [
      "", " ", "ui", "ui_", "ui___", "Speed", "Opacity ui_x", "ui_speed now", "ui_ speed",
      "<b>ui_speed</b>", "ui_速度", "ui_speed\nui_size", "Ui_speed", "xui_speed",
      "ui_" + String(repeating: "a", count: 94),
      "ui_" + String(repeating: "a", count: 197),
    ]
    for text in notTokens {
      XCTAssertNil(WebPanelController.engineTokenLabel(text), text)
    }
  }

  func testTokensAreReadableInLabelsAndComboChoicesWithoutChangingValues() throws {
    let context = try Context()
    defer { context.tearDown() }
    var combo = Self.property(id: "mode", labelHtml: "ui_editor_properties_pivot_offset_x")
    combo.kind = .combo
    combo.comboOptions = [
      BridgeComboOption(label: "ui_workshop_tags_customizable", value: .string(value: "ui_workshop_tags_customizable")),
      BridgeComboOption(label: "ui_browse_context_menu_default", value: .number(value: 2)),
      BridgeComboOption(label: "Night sky", value: .number(value: 3)),
    ]
    context.store.wallpaperOptionsSnapshot = BridgeSnapshotFixtures.options(
      wallpaperId: "scene-1", kind: .projectScene,
      properties: [combo, Self.property(id: "prose", labelHtml: "Speed ui_note")])

    let rows = try XCTUnwrap(
      (context.controller.snapshot()["options"] as? [String: Any])?["properties"]
        as? [[String: Any]])
    let mode = try XCTUnwrap(rows.first { $0["id"] as? String == "mode" })
    let choices = try XCTUnwrap(mode["options"] as? [[String: Any]])

    XCTAssertEqual(choices.compactMap { $0["label"] as? String }, ["Customizable", "Default", "Night sky"])
    XCTAssertEqual(
      choices.first?["value"] as? String, "ui_workshop_tags_customizable",
      "A choice's value is what the wallpaper reads; only its label is rewritten")
    XCTAssertEqual(choices.dropFirst().first?["value"] as? Double, 2)
    XCTAssertEqual(mode["label"] as? String, "Pivot offset x")
    XCTAssertEqual(
      mode["labelHTML"] as? String, "ui_editor_properties_pivot_offset_x",
      "The page still needs the token to find its curated phrase")
    let prose = try XCTUnwrap(rows.first { $0["id"] as? String == "prose" })
    XCTAssertEqual(prose["label"] as? String, "Speed ui_note", "Text that only mentions a token is the author's")
  }

  func testPageShowsCuratedPhraseOrHumanisedWords() async throws {
    let readout = try await readout(of: Self.tokenProperties, language: nil)

    XCTAssertEqual(readout["pivot"]?.label, "Pivot offset X", "A curated phrase wins over the derived words")
    XCTAssertEqual(readout["clock"]?.label, "Use 24-hour format")
    XCTAssertEqual(readout["effect"]?.label, "Chromatic abberation")
    XCTAssertEqual(readout["padded"]?.label, "Size", "Padding does not hide a curated token")
    XCTAssertEqual(readout["prose"]?.label, "Speed ui_note")
    XCTAssertEqual(readout["mode"]?.options, ["Customizable", "Default"])
    for id in ["pivot", "clock", "effect", "padded", "mode"] {
      let row = try XCTUnwrap(readout[id], id)
      XCTAssertEqual(row.aria, row.label, "\(id): the control is named by what is shown")
      XCTAssertFalse(
        ([row.label, row.aria ?? ""] + row.titles + row.options).contains { $0.contains("ui_") },
        "\(id): no built-in identifier reaches a person")
    }
    XCTAssertEqual(readout["effect"]?.titles, ["Restore default: Chromatic abberation"])
  }

  func testPageTranslatesDerivedWordsThatAreCatalogPhrases() async throws {
    let readout = try await readout(of: Self.tokenProperties, language: "ja")

    for (id, english) in [("pivot", "Pivot offset X"), ("clock", "Use 24-hour format")] {
      let label = try XCTUnwrap(readout[id]?.label, id)
      XCTAssertNotEqual(label, english, "\(id): a curated phrase follows the app language")
      XCTAssertTrue(label.unicodeScalars.contains { Self.isCJK($0) }, label)
    }
    XCTAssertEqual(
      readout["effect"]?.label, "Chromatic abberation",
      "Words with no catalog entry stay English rather than showing the identifier")
    let choices = try XCTUnwrap(readout["mode"]?.options)
    XCTAssertEqual(choices.count, 2)
    for (choice, english) in zip(choices, ["Customizable", "Default"]) {
      XCTAssertNotEqual(choice, english, "A derived word that is a catalog phrase is translated")
      XCTAssertTrue(choice.unicodeScalars.contains { Self.isCJK($0) }, choice)
    }
  }

  private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
    scalar.properties.isIdeographic || (0x3040...0x30FF).contains(scalar.value)
  }

  private static var tokenProperties: [BridgePropertyDescriptor] {
    var rows = [
      property(id: "pivot", kind: .bool, labelHtml: "ui_editor_properties_pivot_offset_x"),
      property(id: "clock", kind: .bool, labelHtml: "ui_editor_properties_use_24h_format"),
      property(id: "effect", kind: .bool, labelHtml: "ui_editor_effect_chromatic_abberation_title"),
      property(id: "padded", kind: .bool, labelHtml: " ui_editor_properties_size "),
      property(id: "prose", kind: .bool, labelHtml: "Speed ui_note"),
    ]
    rows[2].defaultValue = .bool(value: false)
    var mode = property(id: "mode", kind: .combo, labelHtml: "ui_editor_properties_default")
    mode.value = .number(value: 1)
    mode.comboOptions = [
      BridgeComboOption(label: "ui_workshop_tags_customizable", value: .number(value: 1)),
      BridgeComboOption(label: "ui_browse_context_menu_default", value: .number(value: 2)),
    ]
    return rows + [mode]
  }

  /// What the person reading one row of the inspector is shown.
  private struct RowReadout {
    var label: String
    var aria: String?
    var options: [String]
    var titles: [String]
  }

  /// Shows `properties` through the real snapshot in the offscreen panel and reads each row back.
  private func readout(of properties: [BridgePropertyDescriptor], language: String?) async throws
    -> [String: RowReadout]
  {
    let context = try Context(language: language)
    defer { context.tearDown() }
    context.store.wallpaperOptionsSnapshot = BridgeSnapshotFixtures.options(
      wallpaperId: "scene-1", kind: .projectScene, properties: properties)
    let options = try XCTUnwrap(context.controller.snapshot()["options"] as? [String: Any])
    guard let (web, base) = try await loadedPage(context) else { return [:] }
    let result =
      try await web.callAsyncJavaScript(
        """
        window.wallpaperUI.receive(Object.assign({}, base, {
          page: 'installed', selectedID: 'scene-1',
          wallpapers: [{ id: 'scene-1', title: 'Scene one', kind: 'Scene', preview: null, active: false, supported: true, tags: [] }],
          options }));
        const field = id => document.querySelector(`#inspector [data-key="${id}"]`);
        const deadline = Date.now() + 5000;
        while (!ids.every(field)) {
          if (Date.now() > deadline) throw new Error('The inspector did not settle');
          await new Promise(resolve => setTimeout(resolve, 20));
        }
        return Object.fromEntries(ids.map(id => [id, {
          label: field(id).querySelector('.field-title label')?.textContent ?? '',
          aria: field(id).querySelector('[aria-label]')?.getAttribute('aria-label') ?? null,
          options: [...field(id).querySelectorAll('option')].map(option => option.textContent),
          titles: [...field(id).querySelectorAll('[title]')].map(node => node.getAttribute('title')),
        }]));
        """, arguments: ["base": base, "options": options, "ids": properties.map(\.id)],
        in: nil, contentWorld: .page) as? [String: [String: Any]]
    let rows = try XCTUnwrap(result)
    return rows.mapValues {
      RowReadout(
        label: $0["label"] as? String ?? "", aria: $0["aria"] as? String,
        options: $0["options"] as? [String] ?? [], titles: $0["titles"] as? [String] ?? [])
    }
  }

  /// Loads the panel offscreen, past its welcome, and returns the page with its first snapshot.
  private func loadedPage(_ context: Context) async throws -> (WKWebView, [String: Any])? {
    let web = context.controller.makeWebView()
    web.setFrameSize(NSSize(width: 960, height: 640))
    let deadline = Date().addingTimeInterval(15)
    while !context.controller.isReady && Date() < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertTrue(context.controller.isReady)
    guard context.controller.isReady else { return nil }
    XCTAssertNil(web.window)
    _ = try await web.callAsyncJavaScript("""
      document.querySelector('#welcome [data-action="go"][data-step="5"]').click();
      document.querySelector('#welcome [data-action="finish"]').click();
      """, arguments: [:], in: nil, contentWorld: .page)
    let ready =
      try await web.callAsyncJavaScript(
        "return await window.webkit.messageHandlers.native.postMessage({action:'ready'})",
        arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
    context.controller.stop()
    return (web, try XCTUnwrap(ready))
  }

  static func property(
    id: String, kind: BridgePropertyKind = .text, labelHtml: String, dirty: Bool = false,
    value: BridgePropertyValue? = nil, enabled: Bool = true
  ) -> BridgePropertyDescriptor {
    BridgePropertyDescriptor(
      id: id, kind: kind, labelHtml: labelHtml,
      value: value ?? (kind == .bool ? .bool(value: true) : .empty),
      defaultValue: .empty, slider: nil,
      comboOptions: [], fileFilter: nil, directoryMode: nil, dirty: dirty,
      canRestoreDefaults: false, enabled: enabled, assetManaged: false, assetMissing: false,
      assetSourcePath: nil)
  }

  @MainActor
  private final class Context {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "panel-labels-\(UUID().uuidString)")
    let bridge = LayoutSnapshotBridge(noPointer: .init())
    let store: BridgeStore
    let defaults: UserDefaults
    let workshop: WorkshopStore
    let controller: WebPanelController

    init(language: String? = nil) throws {
      store = BridgeStore(bridge: bridge)
      let defaults = TemporaryDefaults.makeForCurrentTest().defaults
      self.defaults = defaults
      workshop = WorkshopStore(
        downloader: WorkshopDownloadManager(sessionDirectory: root), supportDirectory: root,
        defaults: defaults)
      controller = WebPanelController(
        store: store, navigation: ControlPanelNavigation(), workshop: workshop, defaults: defaults,
        appLanguage: language.map { AppLanguageStore(defaults: defaults, systemLanguages: [$0]) }
          ?? .english())
      store.settingsSnapshot = BridgeSnapshotFixtures.settings()
      store.librarySnapshot = BridgeLibrarySnapshot(
        wallpapers: [
          BridgeWallpaperEntry(
            id: "scene-1", title: "Scene one", kind: .projectScene, supported: true, active: false,
            selected: true, previewPath: nil)
        ],
        scanStatus: BridgeLibraryScanStatus(scanning: false, done: 0, total: 0), sceneCount: 1,
        videoCount: 0, webpageCount: 0, unknownCount: 0)
    }

    func tearDown() {
      controller.stop()
      try? FileManager.default.removeItem(at: root)
    }
  }
}
