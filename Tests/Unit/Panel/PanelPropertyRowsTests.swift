import XCTest

@testable import WallpaperMachine

/// The inspector's property rows and options envelope: what a label says, which rows are listed, how
/// each control is described, what Restore all and the footer offer, and what a chosen file or folder
/// reads as. Authored labels retain presentation without gaining panel privileges: plain names stay
/// available to pickers and unnamed controls never expose ids.
@MainActor
final class PanelPropertyRowsTests: PanelTestCase {
  private let english = PanelLocale(language: .english, region: nil)

  private func property(
    _ id: String, _ kind: BridgePropertyKind = .text, label: String? = nil, dirty: Bool = false,
    value: BridgePropertyValue? = nil, defaultValue: BridgePropertyValue = .empty,
    enabled: Bool = true
  ) -> BridgePropertyDescriptor {
    BridgePropertyDescriptor(
      id: id, kind: kind, labelHtml: label ?? id,
      value: value ?? (kind == .bool ? .bool(value: true) : .empty), defaultValue: defaultValue,
      slider: nil, comboOptions: [], fileFilter: nil, directoryMode: nil, dirty: dirty,
      canRestoreDefaults: false, enabled: enabled, assetManaged: false, assetMissing: false,
      assetSourcePath: nil)
  }

  private func make(
    _ properties: [BridgePropertyDescriptor], wallpaper: String = "scene-1",
    supported: Bool = true, dirty: Bool = false, configure: (inout InspectorOptions.Inputs) -> Void = { _ in }
  ) -> InspectorOptions {
    var inputs = InspectorOptions.Inputs()
    inputs.locale = english
    configure(&inputs)
    return InspectorOptions.make(
      BridgeSnapshotFixtures.options(
        wallpaperId: wallpaper, kind: .projectScene, supported: supported, dirty: dirty,
        properties: properties),
      inputs: inputs)
  }

  /// A controller over fixture stores, not started, always shut down afterwards.
  private func withController(_ body: (PanelFixture) async throws -> Void) async throws {
    let panel = try makeController()
    do { try await body(panel) } catch {
      await panel.shutdown()
      throw error
    }
    await panel.shutdown()
  }

  private func row(_ id: String, in options: InspectorOptions) throws -> InspectorOptions.PropertyRow {
    try XCTUnwrap(options.properties.first { $0.id == id }, id)
  }

  // MARK: Labels

  func testAuthorMarkupIsReducedToTheWordsItCarries() {
    let labels = [
      ("<font color=red>图1自定义", "图1自定义"),  // a colour tag is styling, not part of the name
      (
        "<center><big><b>Bilibili<br/><a href='https://space.bilibili.com/676093670'>和仓贤一的个人主页 (点击跳转)</a><big></p>",
        "Bilibili 和仓贤一的个人主页 (点击跳转)"
      ),  // a line break separates words rather than gluing them into one run
      ("&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp镜头位置X（默认0）<br/>", "镜头位置X（默认0）"),  // entities, with or without the semicolon
      ("&amp;lt;b&amp;gt; stays text", "&lt;b&gt; stays text"),  // decoded once: escaped markup stays text
      (
        "<img src=\"http://photogz.photo.store.qq.com/psc?/V12uhwIt3z28yp/bqQ!/b&bo=HgEIAA!&rf=viewer_4\" width=\"2000\" height=\"1\">",
        ""
      ),  // an image strip is decoration
      ("<hr>", ""),
    ]
    for (html, plain) in labels {
      XCTAssertEqual(PropertyLabels.plainLabel(html), plain, html)
    }
    let scheme = PropertyLabels.plainLabel("ui_browse_properties_scheme_color")
    XCTAssertNotEqual(scheme, "ui_browse_properties_scheme_color", "the editor's token never reaches a person")
    XCTAssertFalse(scheme.isEmpty)
  }

  func testAControlWhoseLabelIsPureDecorationStillHasANameThatIsNotTheEditorsSlug() throws {
    let slug = "imgsrchttpphotogzphotostoreqqcompscv12uhwit3z28ypviewer_4width2000height51"
    let options = make([
      property(slug, .bool, label: "<img src=\"http://photogz.photo.store.qq.com/x\">"),
      property("real", .slider, label: "Character size"),
    ])

    let unnamed = try row(slug, in: options)
    XCTAssertEqual(unnamed.name, english.string("Unnamed option"))
    XCTAssertFalse(unnamed.name.contains(slug))
    XCTAssertTrue(unnamed.label.isEmpty, "no words and no registered artwork: nothing to draw")
    XCTAssertEqual(try row("real", in: options).name, "Character size", "a real label is untouched")
    XCTAssertEqual(try row("real", in: options).label.markup, "Character size")
  }

  func testAuthorArtworkIsOfferedOnlyFromAllowlistedSources() throws {
    let allowed = "https://i.ibb.co/example/image.gif"
    let options = make([
      property(
        "art", .text,
        label:
          "<center><a href=\"https://space.bilibili.com/1/\"><img src=\"\(allowed)\" width=\"105%\"></a></center><hr>"),
      property("evil", .text, label: "<img src=\"https://evil.test/x\" onerror=\"alert(1)\">"),
    ])

    XCTAssertEqual(try row("art", in: options).label.images, [allowed: URL(string: allowed)!])
    XCTAssertFalse(try row("art", in: options).label.isEmpty, "artwork alone is something to show")
    XCTAssertTrue(try row("evil", in: options).label.images.isEmpty)
    XCTAssertTrue(try row("evil", in: options).label.isEmpty)
  }

  func testGroupAndTextRecordsAreHeadingsAndDescriptionsAndUnknownReadsAsText() throws {
    let options = make([
      property("section", .group, label: "Characters"), property("note", .text, label: "Characters"),
      property("other", .unknown, label: "Characters"), property("toggle", .bool, label: "Characters"),
    ])

    XCTAssertEqual(try row("section", in: options).control, .heading, "a group is a heading")
    XCTAssertEqual(try row("note", in: options).control, .description(detail: nil))
    XCTAssertEqual(
      try row("other", in: options).control, .description(detail: nil),
      "a record the app does not know is still a description")
    XCTAssertEqual(try row("toggle", in: options).control, .toggle(isOn: true))
  }

  func testADescriptionShowsItsValueOnlyWhenThatAddsWords() throws {
    let options = make([
      property("same", .text, label: "Hello", value: .string(value: "Hello")),
      property("more", .text, label: "Hello", value: .string(value: "A longer note")),
      property("none", .text, label: "Hello"),
    ])
    XCTAssertEqual(try row("same", in: options).control, .description(detail: nil))
    XCTAssertEqual(try row("more", in: options).control, .description(detail: "A longer note"))
    XCTAssertEqual(try row("none", in: options).control, .description(detail: nil))
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
      ("ui_editor_properties", "Properties"), ("ui_title", "Title"), ("ui_label_title", "Label"),
      ("ui_editor__effect___speed_", "Speed"),
      // Exactly the longest token the editor could have written.
      ("ui_" + String(repeating: "a", count: 93), String(repeating: "a", count: 93).capitalized),
    ]
    for (token, label) in words {
      XCTAssertEqual(PropertyLabels.engineTokenLabel(token), label, token)
    }
    let notTokens = [
      "", " ", "ui", "ui_", "ui___", "Speed", "Opacity ui_x", "ui_speed now", "ui_ speed",
      "<b>ui_speed</b>", "ui_速度", "ui_speed\nui_size", "Ui_speed", "xui_speed",
      "ui_" + String(repeating: "a", count: 94), "ui_" + String(repeating: "a", count: 197),
    ]
    for text in notTokens { XCTAssertNil(PropertyLabels.engineTokenLabel(text), text) }
  }

  func testTokensAreReadableInLabelsAndComboChoicesWithoutChangingValues() throws {
    var combo = property("mode", .combo, label: "ui_editor_properties_pivot_offset_x")
    combo.comboOptions = [
      BridgeComboOption(
        label: "ui_workshop_tags_customizable", value: .string(value: "ui_workshop_tags_customizable")),
      BridgeComboOption(label: "ui_browse_context_menu_default", value: .number(value: 2)),
      BridgeComboOption(label: "Night sky", value: .number(value: 3)),
    ]
    let options = make([combo, property("prose", .text, label: "Speed ui_note")])

    let mode = try row("mode", in: options)
    guard case .choice(_, let choices) = mode.control else { return XCTFail("a combo is a choice") }
    XCTAssertEqual(choices.map(\.label), ["Customizable", "Default", "Night sky"])
    XCTAssertEqual(
      choices.first?.value, .string(value: "ui_workshop_tags_customizable"),
      "a choice's value is what the wallpaper reads; only its label is rewritten")
    XCTAssertEqual(choices[1].value, .number(value: 2))
    XCTAssertEqual(mode.name, "Pivot offset X", "a curated phrase wins over the derived words")
    XCTAssertEqual(
      try row("prose", in: options).name, "Speed ui_note", "text that only mentions a token is the author's")
  }

  func testACuratedPhraseOrHumanisedWordsNamesEveryEngineToken() throws {
    var mode = property("mode", .combo, label: "ui_editor_properties_default")
    mode.value = .number(value: 1)
    mode.comboOptions = [
      BridgeComboOption(label: "ui_workshop_tags_customizable", value: .number(value: 1)),
      BridgeComboOption(label: "ui_browse_context_menu_default", value: .number(value: 2)),
    ]
    let options = make([
      property("pivot", .bool, label: "ui_editor_properties_pivot_offset_x"),
      property("clock", .bool, label: "ui_editor_properties_use_24h_format"),
      property(
        "effect", .bool, label: "ui_editor_effect_chromatic_abberation_title",
        defaultValue: .bool(value: false)),
      property("padded", .bool, label: " ui_editor_properties_size "),
      property("prose", .bool, label: "Speed ui_note"), mode,
    ])

    XCTAssertEqual(try row("pivot", in: options).name, "Pivot offset X")
    XCTAssertEqual(try row("clock", in: options).name, "Use 24-hour format")
    XCTAssertEqual(try row("effect", in: options).name, "Chromatic abberation")
    XCTAssertEqual(try row("padded", in: options).name, "Size", "padding does not hide a curated token")
    XCTAssertEqual(try row("prose", in: options).name, "Speed ui_note")
    XCTAssertTrue(try row("effect", in: options).canRestoreDefault)
    for id in ["pivot", "clock", "effect", "padded", "mode"] {
      let row = try row(id, in: options)
      XCTAssertNil(row.label.markup, "\(id): a phrase the app worded has no author markup to draw")
      XCTAssertFalse(row.name.contains("ui_"), "\(id): no built-in identifier reaches a person")
    }
    guard case .choice(_, let choices) = try row("mode", in: options).control else {
      return XCTFail("a combo is a choice")
    }
    XCTAssertEqual(choices.map(\.label), ["Customizable", "Default"])
    XCTAssertEqual(try row("mode", in: options).name, "Default")
  }

  func testDerivedWordsThatAreCatalogPhrasesAreTranslatedAndTheOthersStayEnglish() throws {
    let japanese = PanelLocale(language: AppLanguage.named("ja") ?? .english, region: nil)
    var mode = property("mode", .combo, label: "ui_editor_properties_default")
    mode.value = .number(value: 1)
    mode.comboOptions = [
      BridgeComboOption(label: "ui_workshop_tags_customizable", value: .number(value: 1)),
      BridgeComboOption(label: "ui_browse_context_menu_default", value: .number(value: 2)),
    ]
    let options = make(
      [
        property("pivot", .bool, label: "ui_editor_properties_pivot_offset_x"),
        property("clock", .bool, label: "ui_editor_properties_use_24h_format"),
        property("effect", .bool, label: "ui_editor_effect_chromatic_abberation_title"), mode,
      ]
    ) { $0.locale = japanese }

    func hasCJK(_ text: String) -> Bool {
      text.unicodeScalars.contains { $0.properties.isIdeographic || (0x3040...0x30FF).contains($0.value) }
    }
    for (id, english) in [("pivot", "Pivot offset X"), ("clock", "Use 24-hour format")] {
      let name = try row(id, in: options).name
      XCTAssertNotEqual(name, english, "\(id): a curated phrase follows the app language")
      XCTAssertTrue(hasCJK(name), name)
    }
    XCTAssertEqual(
      try row("effect", in: options).name, "Chromatic abberation",
      "words with no catalog entry stay English rather than showing the identifier")
    guard case .choice(_, let choices) = try row("mode", in: options).control else {
      return XCTFail("a combo is a choice")
    }
    for (choice, english) in zip(choices.map(\.label), ["Customizable", "Default"]) {
      XCTAssertNotEqual(choice, english, "a derived word that is a catalog phrase is translated")
      XCTAssertTrue(hasCJK(choice), choice)
    }
  }

  /// Port of `test_panel_localization.py::test_engine_property_labels_are_translated`: every phrase the
  /// app words for one of Wallpaper Engine's tokens is a catalog phrase in every shipped language, so
  /// one added without its translations cannot show English unnoticed.
  func testEveryCuratedEnginePhraseIsTranslatedInEveryShippedLanguage() throws {
    XCTAssertFalse(PropertyLabels.curatedPhrases.isEmpty)
    for language in AppLanguage.supported where language != .english {
      let tag = language.tag
      let locale = PanelLocale(language: language, region: nil)
      for phrase in Set(PropertyLabels.curatedPhrases.values).sorted() {
        let translated = locale.catalogString(phrase)
        XCTAssertNotEqual(translated, phrase, "\(tag): “\(phrase)” has no translation")
        XCTAssertFalse(translated.isEmpty, "\(tag): “\(phrase)”")
      }
    }
  }

  func testThePackagedStillLabelsAreCuratedOnlyForTheStillsThisAppPackages() throws {
    let japanese = PanelLocale(language: AppLanguage.named("ja") ?? .english, region: nil)
    let properties = [
      property("fit", .combo, label: "Image fit"), property("bg", .color, label: "Background color"),
    ]
    let still = make(properties, wallpaper: "image-photo.png") { $0.locale = japanese }
    let other = make(properties, wallpaper: "123456") { $0.locale = japanese }

    XCTAssertEqual(try row("fit", in: other).name, "Image fit", "an author's label is the author's")
    XCTAssertNotEqual(try row("fit", in: still).name, "Image fit", "ours is translated")
    XCTAssertNil(try row("fit", in: still).label.markup)
    XCTAssertNotNil(try row("fit", in: other).label.markup)
  }

  // MARK: Rows

  func testOnlyEnabledPropertiesAreListedInTheirAuthoredOrder() throws {
    let options = make([
      property("gate", .bool), property("detail", .textInput, enabled: false),
      property("shown", .directory), property("tucked", .directory, enabled: false),
      property("note", .text),
    ])
    XCTAssertEqual(
      options.properties.map(\.id), ["gate", "shown", "note"],
      "rows keep their authored order and a hidden one is not offered")
  }

  func testEachControlIsDescribedByItsKindAndTheValueItShows() throws {
    var color = property("tint", .color, value: .colorRgb(red: 0.25, green: 0.5, blue: 1))
    color.defaultValue = .colorRgb(red: 1, green: 1, blue: 1)
    var slider = property("alpha", .slider, value: .number(value: 0.4))
    slider.slider = BridgeSliderMetadata(min: 0, max: 2, step: 0.5, precision: 1)
    var stepless = property("gain", .slider, value: .number(value: 3))
    stepless.slider = BridgeSliderMetadata(min: 1, max: 9, step: 0, precision: 0)
    var combo = property("shape", .combo, value: .number(value: 7))
    combo.comboOptions = [BridgeComboOption(label: "Round", value: .number(value: 1))]
    let options = make([
      color, slider, stepless, property("bare", .slider), combo,
      property("name", .textInput, value: .string(value: "saved")),
      property("picture", .texture, value: .string(value: "/pics/a.png")),
    ])

    XCTAssertEqual(try row("tint", in: options).control, .color(red: 0.25, green: 0.5, blue: 1))
    XCTAssertEqual(
      try row("alpha", in: options).control,
      .slider(.init(value: 0.4, minimum: 0, maximum: 2, step: 0.5, precision: 1)))
    XCTAssertEqual(
      try row("gain", in: options).control,
      .slider(.init(value: 3, minimum: 1, maximum: 9, step: nil, precision: 0)),
      "an author's step of zero means any value")
    XCTAssertEqual(
      try row("bare", in: options).control,
      .slider(.init(value: 0, minimum: 0, maximum: 1, step: 0.01, precision: 0)),
      "a slider with no metadata keeps the defaults the page used")
    guard case .choice(let selection, let choices) = try row("shape", in: options).control else {
      return XCTFail("a combo is a choice")
    }
    XCTAssertNil(selection, "a value that matches no choice shows no selection and is never changed")
    XCTAssertEqual(choices.map(\.label), ["Round"])
    XCTAssertEqual(try row("name", in: options).control, .text("saved"))
    XCTAssertEqual(try row("picture", in: options).control, .image(path: "/pics/a.png"))
    XCTAssertTrue(try row("tint", in: options).canRestoreDefault)
    XCTAssertFalse(try row("alpha", in: options).canRestoreDefault, "a default the bridge reports as empty gives none")
  }

  func testTheChoiceMatchingTheCurrentValueIsSelected() throws {
    var combo = property("shape", .combo, value: .string(value: "1"))
    combo.comboOptions = [
      BridgeComboOption(label: "Number", value: .number(value: 1)),
      BridgeComboOption(label: "Text", value: .string(value: "1")),
    ]
    guard case .choice(let selection, _) = try row("shape", in: make([combo])).control else {
      return XCTFail("a combo is a choice")
    }
    XCTAssertEqual(selection, .string(value: "1"), "a number and a string stay distinct")
  }

  func testTheModifiedMarkFollowsTheBridgeTheDraftAndAValueOnItsWay() throws {
    let options = make(
      [
        property("saved", .bool), property("edited", .bool, dirty: true),
        property("typed", .textInput, value: .string(value: "x")), property("chosen", .bool),
      ]
    ) {
      $0.textDrafts = ["typed": "typed more"]
      $0.pendingValues = ["chosen": .bool(value: false)]
    }
    XCTAssertFalse(try row("saved", in: options).isModified)
    XCTAssertTrue(try row("edited", in: options).isModified)
    XCTAssertTrue(try row("typed", in: options).isModified)
    XCTAssertFalse(try row("typed", in: options).isDirty)
    XCTAssertEqual(try row("typed", in: options).control, .text("typed more"))
    XCTAssertTrue(try row("chosen", in: options).isModified)
    XCTAssertEqual(try row("chosen", in: options).control, .toggle(isOn: false))
    XCTAssertTrue(options.hasUnsentChanges)
  }

  // MARK: Restore all and the footer

  func testRestoreAllIsOfferedOnlyWhenSomethingDiffersFromDefault() throws {
    func options(
      slider: Bool = false, file: Bool = false, supported: Bool = true, hiddenText: Bool = false,
      hiddenFile: Bool = false, draft: Bool = false, locked: Bool = false
    ) -> InspectorOptions {
      make(
        [
          property("size", .slider, label: "Size", dirty: slider),
          property("title", .textInput, label: "Title"),
          property("clip", .file, label: "Clip", dirty: file, value: .string(value: "/chosen/clip.webm")),
          // Rows a visibility rule hides.
          property("secret", .textInput, label: "Secret", dirty: hiddenText, enabled: false),
          property(
            "vault", .file, label: "Vault", dirty: hiddenFile,
            value: .string(value: "/chosen/vault.webm"), enabled: false),
        ], supported: supported
      ) {
        if draft { $0.textDrafts = ["title": "typed, not sent yet"] }
        $0.isLocked = locked
      }
    }
    XCTAssertFalse(options().canRestoreAll, "nothing differs from the defaults")
    XCTAssertTrue(options(slider: true).canRestoreAll, "a modified slider can be restored")
    XCTAssertFalse(
      options(file: true).canRestoreAll,
      "a chosen file keeps its own Clear, so it alone gives restore all nothing to do")
    XCTAssertTrue(
      options(hiddenText: true).canRestoreAll,
      "a modified value behind a rule that hides its row still reaches the wallpaper, so it can be restored"
    )
    XCTAssertEqual(options(hiddenText: true).properties.map(\.id), ["size", "title", "clip"])
    XCTAssertFalse(options(hiddenFile: true).canRestoreAll, "a hidden file keeps its own Clear as well")
    XCTAssertFalse(
      options(slider: true, supported: false).canRestoreAll,
      "a wallpaper that cannot be rendered has no staging")
    XCTAssertTrue(options(draft: true).canRestoreAll, "text not yet sent counts as a change")
    XCTAssertFalse(options(slider: true, locked: true).canRestoreAll, "and nothing is offered while locked")
  }

  func testApplyAndRevertFollowTheDraftTheLockAndWhetherTheWallpaperCanRun() {
    let clean = make([property("a", .bool)])
    XCTAssertFalse(clean.canApply)
    XCTAssertFalse(clean.canRevert)

    let dirty = make([property("a", .bool)], dirty: true)
    XCTAssertTrue(dirty.canApply)
    XCTAssertTrue(dirty.canRevert)

    let unsupported = make([property("a", .bool)], supported: false, dirty: true)
    XCTAssertFalse(unsupported.canApply, "a wallpaper this Mac cannot render cannot be applied")
    XCTAssertTrue(unsupported.canRevert, "but its edits can be taken back")

    let locked = make([property("a", .bool)], dirty: true) { $0.isLocked = true }
    XCTAssertFalse(locked.canApply)
    XCTAssertFalse(locked.canRevert)
  }

  // MARK: Displays

  func testEachDisplayCardCarriesItsSettingsPositionAndWhetherANativePlayerDrawsIt() throws {
    func display(_ id: String, _ title: String, pan: BridgeFraming, fps: UInt32 = 30)
      -> BridgeDisplayConfigRow
    {
      BridgeDisplayConfigRow(
        displayId: id, title: title, enabled: true, scalingMode: .fill, scalingFactor: 1.25,
        framing: pan, targetFps: fps, maxFps: 60, muted: false, volume: 1, dirty: false,
        canRestoreDefaults: false)
    }
    let snapshot = BridgeSnapshotFixtures.options(
      wallpaperId: "video-1", kind: .video,
      displayConfigurations: [
        display("primary", "Studio Display (7 - Primary)", pan: .init(panX: 0.2, panY: 0.8)),
        display(
          "identity:{\"uuid\":\"AABB\"}", "Side Display (8 - Secondary)",
          pan: .init(panX: .nan, panY: 7), fps: 60),
      ])
    var inputs = InspectorOptions.Inputs()
    inputs.nativePlayerDisplays = [7]
    inputs.frameRateCeiling = FrameRateCeiling(savedCap: 45, effectiveCap: 45, causes: [])
    let options = InspectorOptions.make(snapshot, inputs: inputs)

    XCTAssertEqual(options.displays.count, 2)
    XCTAssertEqual(options.displays[0].position, .init(x: 0.2, y: 0.8))
    XCTAssertEqual(
      options.displays[1].position, .init(x: 0.5, y: 1),
      "a position that is not a number reads as centred and one outside the room is held to it")
    XCTAssertEqual(
      options.displays.map(\.isDrawnByNativePlayer), [true, false],
      "only the display this wallpaper's native player draws on ignores a position")
    XCTAssertEqual(
      options.displays.map(\.frameRateLimit?.fps), [nil, 45],
      "the cap shows only where it is below the saved rate")
    inputs.frameRateCeiling = FrameRateCeiling(savedCap: nil, effectiveCap: 30, causes: [.lowBattery])
    XCTAssertEqual(
      InspectorOptions.make(snapshot, inputs: inputs).displays.map(\.frameRateLimit?.source),
      [nil, .reducedQuality(.lowBattery)],
      "a limit the low-battery rule sets is put down to it, not to Performance")
    XCTAssertEqual(options.displays[0].scalingFactor, 1.25)
    XCTAssertEqual(options.displays[0].maximumFrameRate, 60)
    XCTAssertTrue(options.offersPosition)
    XCTAssertFalse(
      InspectorOptions.make(
        BridgeSnapshotFixtures.options(wallpaperId: "web", kind: .webpage, displayConfigurations: snapshot.displayConfigurations)
      ).offersPosition, "a web page always fills its window")
    XCTAssertFalse(
      InspectorOptions.make(
        BridgeSnapshotFixtures.options(wallpaperId: "s", kind: .projectScene, supported: false)
      ).offersPosition)
  }

  func testTheNativePlayerIsFoundOnlyForTheDisplayAndWallpaperItsReportNames() throws {
    let panel = try makeController()
    let controller = panel.controller
    let rows = [
      BridgeDisplayConfigRow(
        displayId: "primary", title: "Studio Display (7 - Primary)", enabled: true, scalingMode: .fill,
        scalingFactor: 1, framing: .centered, targetFps: 30, maxFps: 60, muted: false, volume: 1,
        dirty: false, canRestoreDefaults: false),
      BridgeDisplayConfigRow(
        displayId: "identity:{\"uuid\":\"AABB\"}", title: "Side Display (8 - Secondary)", enabled: true,
        scalingMode: .fill, scalingFactor: 1, framing: .centered, targetFps: 30, maxFps: 60,
        muted: false, volume: 1, dirty: false, canRestoreDefaults: false),
    ]
    panel.store.wallpaperOptionsSnapshot = BridgeSnapshotFixtures.options(
      wallpaperId: "video-1", kind: .video, displayConfigurations: rows)
    func report(_ wallpaper: String, display: UInt32, backend: String) -> BridgeVideoBackendReport {
      BridgeVideoBackendReport(
        displayId: display, displayName: "Display", wallpaperId: wallpaper, wallpaperTitle: wallpaper,
        backend: backend, fallbackReason: nil)
    }
    panel.store.settingsSnapshot.videoBackends = [
      report("video-1", display: 7, backend: "native"),
      // Another wallpaper's native player on the second display, and this one on Compatibility.
      report("video-2", display: 8, backend: "native"), report("video-1", display: 8, backend: "legacy"),
    ]
    XCTAssertEqual(
      controller.inspectorOptions(for: "video-1")?.displays.map(\.isDrawnByNativePlayer), [true, false])

    panel.store.settingsSnapshot.videoBackends = []
    XCTAssertEqual(
      controller.inspectorOptions(for: "video-1")?.displays.map(\.isDrawnByNativePlayer), [false, false],
      "with no backend report, nothing says the native player is drawing")
    XCTAssertNil(controller.inspectorOptions(for: "video-2"), "options for another wallpaper are not these")
  }

  /// Port of the inspector half of `ControlPanelSyncTests.testDisplayTitlesUseTheSystemName...`: a
  /// display card names the screen by its macOS name when one is known, and keeps the renderer's
  /// label for a screen macOS does not name.
  func testADisplayCardNamesTheScreenByItsMacOSName() throws {
    let panel = try makeController(
      displayTitles: DisplayTitleResolver(names: { ["primary": "Built-in Retina Display"] }))
    defer { Task { await panel.shutdown() } }
    func row(_ id: String, _ title: String) -> BridgeDisplayConfigRow {
      BridgeDisplayConfigRow(
        displayId: id, title: title, enabled: true, scalingMode: .fill, scalingFactor: 1,
        framing: .centered, targetFps: 30, maxFps: 60, muted: false, volume: 1, dirty: false,
        canRestoreDefaults: false)
    }
    panel.store.wallpaperOptionsSnapshot = BridgeSnapshotFixtures.options(
      wallpaperId: "video-1", kind: .video,
      displayConfigurations: [
        row("primary", "Vendor 1552 - Model 41055 (primary - Primary)"),
        row("secondary", "secondary"),
      ])
    XCTAssertEqual(
      panel.controller.inspectorOptions(for: "video-1")?.displays.map(\.title),
      ["Built-in Retina Display (primary - Primary)", "secondary"])
  }

  // MARK: Chosen files and folders

  /// Port of `WebPanelSceneSettingsTests.testAssetKeysDistinguishManagedFromExternalAndPresentFromMissing`:
  /// the bridge's provenance of a chosen file reaches its row as it was given, and only an external
  /// reference says where it is used in place.
  func testAChosenFilesProvenanceReachesItsRowAsTheBridgeGaveIt() throws {
    func file(_ id: String, managed: Bool, missing: Bool, source: String?) -> BridgePropertyDescriptor {
      BridgePropertyDescriptor(
        id: id, kind: .file, labelHtml: id, value: .string(value: "/staged/\(id).mp4"),
        defaultValue: .empty, slider: nil, comboOptions: [], fileFilter: .video, directoryMode: nil,
        dirty: false, canRestoreDefaults: false, enabled: true, assetManaged: managed,
        assetMissing: missing, assetSourcePath: source)
    }
    let options = make([
      file("managed", managed: true, missing: false, source: nil),
      file("external", managed: false, missing: false, source: "/Users/me/Movies/clip.mp4"),
      file("missing", managed: false, missing: true, source: "/Volumes/Gone/clip.mp4"),
    ]) { inputs in
      for id in ["managed", "external", "missing"] {
        inputs.assets[id] = PanelPropertyAsset(path: "/staged/\(id).mp4", name: "\(id).mp4")
      }
    }
    func state(_ id: String) throws -> InspectorOptions.PropertyRow.PathState {
      let control = try row(id, in: options).control
      guard case .file(let state) = control else {
        return try XCTUnwrap(nil, "\(id) is a file row, not \(control)")
      }
      return state
    }

    let managed = try state("managed")
    XCTAssertTrue(managed.isManaged)
    XCTAssertFalse(managed.isMissing)
    XCTAssertNil(managed.sourcePath)
    let external = try state("external")
    XCTAssertFalse(external.isManaged)
    XCTAssertFalse(external.isMissing)
    XCTAssertEqual(external.sourcePath, "/Users/me/Movies/clip.mp4")
    let missing = try state("missing")
    XCTAssertTrue(missing.isMissing)
    XCTAssertEqual(missing.sourcePath, "/Volumes/Gone/clip.mp4")

    PanelLocale.shared.bind(to: .english())
    defer { PanelLocale.shared.bind(to: .testHost) }
    XCTAssertFalse(
      AssetNotes.lines(state: managed, folder: nil).contains { $0.hasPrefix("Used in place from") },
      "a managed copy is not used in place")
    XCTAssertTrue(
      AssetNotes.lines(state: external, folder: nil)
        .contains("Used in place from /Users/me/Movies/clip.mp4. Moving or deleting it there breaks the wallpaper."))
  }

  func testAnUnsetFileAndAChosenFolderAreDescribed() async throws {
    try await withController { panel in
      let folder = panel.root.appendingPathComponent("slides")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      for name in ["a.png", "b.jpg", "notes.txt"] { try Data().write(to: folder.appendingPathComponent(name)) }
      // A folder whose name ends in an accepted extension, and a dotfile: both are screened out by the
      // importer, so neither may be counted as a file it would take.
      try FileManager.default.createDirectory(
        at: folder.appendingPathComponent("photos.png"), withIntermediateDirectories: true)
      try Data().write(to: folder.appendingPathComponent(".hidden.png"))
      var cover = property("cover", .file)
      cover.fileFilter = .image
      var album = property("album", .directory, value: .string(value: folder.path))
      album.fileFilter = .image
      album.directoryMode = .fetchAll
      panel.store.wallpaperOptionsSnapshot = BridgeSnapshotFixtures.options(
        wallpaperId: "web-1", kind: .webpage, properties: [cover, album])

      let options = try XCTUnwrap(panel.controller.inspectorOptions(for: "web-1"))
      guard case .file(let unset) = try row("cover", in: options).control,
        case .folder(let chosen, let folderState) = try row("album", in: options).control
      else { return XCTFail("a file and a folder") }

      XCTAssertNil(unset.name, "an unset path has no name to show")
      XCTAssertFalse(unset.isChosen)
      XCTAssertEqual(
        unset.acceptedTypes, UserAssetFilter.image.allowedExtensions.sorted(),
        "the accepted types come from the property's own filter")
      XCTAssertEqual(chosen.name, "slides")
      XCTAssertEqual(folderState.fileCount, 2, "only files the importer would take are counted")
      XCTAssertFalse(folderState.isTruncated)
      XCTAssertEqual(folderState.delivery, .wholeList)
      XCTAssertEqual(folderState.fileLimit, UserAssetStore.defaultDirectoryFileLimit)
      XCTAssertTrue(panel.controller.propertyAssets.isEmpty, "reading state remembers nothing by itself")
    }
  }

  func testAnUnreadableFolderIsUnknownRatherThanEmpty() async throws {
    try await withController { panel in
      let missing = panel.root.appendingPathComponent("gone")
      var album = property("album", .directory, value: .string(value: missing.path))
      album.directoryMode = .onDemand
      panel.store.wallpaperOptionsSnapshot = BridgeSnapshotFixtures.options(
        wallpaperId: "web-1", kind: .webpage, properties: [album])

      let options = try XCTUnwrap(panel.controller.inspectorOptions(for: "web-1"))
      guard case .folder(let state, let folder) = try row("album", in: options).control else {
        return XCTFail("a folder")
      }
      XCTAssertEqual(state.name, "gone")
      XCTAssertNil(folder.fileCount, "a folder that could not be read must not read as holding zero files")
      XCTAssertEqual(folder.delivery, .onDemand)
    }
  }

  func testMeasuringIsRememberedUntilTheChosenPathChangesAndNeverForAHiddenFolder() async throws {
    try await withController { panel in
      let controller = panel.controller
      let shown = panel.root.appendingPathComponent("shown")
      let tucked = panel.root.appendingPathComponent("tucked")
      for folder in [shown, tucked] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("a.png"))
      }
      let options = BridgeSnapshotFixtures.options(
        wallpaperId: "scene-1", kind: .projectScene,
        properties: [
          property("shown", .directory, value: .string(value: shown.path)),
          property("tucked", .directory, value: .string(value: tucked.path), enabled: false),
        ])

      XCTAssertEqual(
        Set(controller.measuredAssets(for: options).keys), ["shown"], "a folder nobody can see is not read")
      XCTAssertEqual(controller.propertyAssets["scene-1"]?["shown"]?.matches, 1)

      // A file added behind the remembered measurement is not seen until the path changes.
      try Data().write(to: shown.appendingPathComponent("b.png"))
      XCTAssertEqual(controller.measuredAssets(for: options)["shown"]?.matches, 1)
      var moved = options
      moved.properties[0].value = .string(value: tucked.path)
      XCTAssertEqual(controller.measuredAssets(for: moved)["shown"]?.matches, 1)
      XCTAssertEqual(controller.measuredAssets(for: options)["shown"]?.matches, 2, "a new path is measured afresh")
    }
  }

  func testReconcilingTheInspectorContextMeasuresTheOpenWallpapersFolders() async throws {
    try await withController { panel in
      let folder = panel.root.appendingPathComponent("album")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try Data().write(to: folder.appendingPathComponent("a.png"))
      panel.store.wallpaperOptionsSnapshot = BridgeSnapshotFixtures.options(
        wallpaperId: "scene-1", kind: .projectScene,
        properties: [property("album", .directory, value: .string(value: folder.path))])

      XCTAssertTrue(panel.controller.propertyAssets.isEmpty)
      panel.controller.reconcileInspectorContext()
      XCTAssertEqual(panel.controller.propertyAssets["scene-1"]?["album"]?.matches, 1)
    }
  }

  // MARK: Labels follow the bridge's language

  private static let japanese = AppLanguage.named("ja")!
  private static let chinese = AppLanguage.named("zh-Hans")!

  private func options(_ id: String, label: String) -> BridgeWallpaperOptionsSnapshot {
    BridgeSnapshotFixtures.options(
      wallpaperId: id, properties: [BridgeSnapshotFixtures.textProperty(id: "size", labelHtml: label)])
  }

  func testTheOpenInspectorIsReadAgainInTheNewLanguage() async throws {
    let (store, bridge) = makeStore()
    store.wallpaperOptionsSnapshot = options("scene-1", label: "Size")
    bridge.options["scene-1"] = options("scene-1", label: "Size")
    // The bridge relabels from its tables once it knows the language.
    bridge.onLabelLanguages = { locales in
      bridge.options["scene-1"] = self.options("scene-1", label: locales.first == "zh-chs" ? "大小" : "Size")
    }
    let revision = store.snapshotRevision

    try await store.setLabelLanguageAsync(Self.chinese)

    XCTAssertEqual(bridge.labelLanguageCalls, [["zh-chs", "en-us"]])
    XCTAssertEqual(store.wallpaperOptionsSnapshot?.properties.first?.labelHtml, "大小")
    XCTAssertNotEqual(store.snapshotRevision, revision, "the panel redraws on a new revision, not on new text")

    try await store.setLabelLanguageAsync(.english)
    XCTAssertEqual(bridge.labelLanguageCalls.last, ["en-us"])
    XCTAssertEqual(store.wallpaperOptionsSnapshot?.properties.first?.labelHtml, "Size")
  }

  func testNothingIsReadWhenNoInspectorIsOpen() async throws {
    let (store, bridge) = makeStore()
    store.wallpaperOptionsSnapshot = nil
    let revision = store.snapshotRevision

    try await store.setLabelLanguageAsync(Self.japanese)

    XCTAssertEqual(bridge.labelLanguageCalls, [["ja-jp", "en-us"]], "the next wallpaper still needs it")
    XCTAssertEqual(bridge.optionRequests, [])
    XCTAssertEqual(store.snapshotRevision, revision)
  }

  func testAFailedRequestLeavesTheInspectorAsItWas() async throws {
    let (store, bridge) = makeStore()
    store.wallpaperOptionsSnapshot = options("scene-1", label: "Size")
    bridge.failLabelLanguages = true
    let revision = store.snapshotRevision

    do {
      try await store.setLabelLanguageAsync(Self.chinese)
      XCTFail("the failure must reach the caller, which decides it is not worth failing over")
    } catch {}

    XCTAssertEqual(bridge.optionRequests, [])
    XCTAssertEqual(store.wallpaperOptionsSnapshot?.properties.first?.labelHtml, "Size")
    XCTAssertEqual(store.snapshotRevision, revision)
  }

  func testAReadThatFinishesAfterAnotherWallpaperOpenedIsDropped() async throws {
    let (store, bridge) = makeStore()
    store.wallpaperOptionsSnapshot = options("scene-1", label: "Size")
    bridge.holdOptions = true
    let revision = store.snapshotRevision

    let change = Task { try await store.setLabelLanguageAsync(Self.chinese) }
    var polls = 0
    while bridge.pendingOptions.isEmpty {
      polls += 1
      guard polls < 2_000 else { return XCTFail("the inspector was never read again") }
      await Task.yield()
    }
    // The user opens another wallpaper while the first one's labels are still on their way.
    store.wallpaperOptionsSnapshot = options("scene-2", label: "Speed")
    bridge.finishOption(options("scene-1", label: "大小"))
    try await change.value

    XCTAssertEqual(store.wallpaperOptionsSnapshot?.wallpaperId, "scene-2")
    XCTAssertEqual(store.wallpaperOptionsSnapshot?.properties.first?.labelHtml, "Speed")
    XCTAssertEqual(store.snapshotRevision, revision)
  }

  func testTheRowsOfTheOpenInspectorRelabelWhenTheBridgeRelabelsThem() async throws {
    try await withController { panel in
      panel.store.wallpaperOptionsSnapshot = options("scene-1", label: "Size")
      panel.bridge.options["scene-1"] = options("scene-1", label: "Size")
      panel.bridge.onLabelLanguages = { [bridge = panel.bridge] locales in
        bridge.options["scene-1"] = self.options("scene-1", label: locales.first == "ja-jp" ? "サイズ" : "Size")
      }
      @MainActor func names() -> [String]? {
        panel.controller.inspectorOptions(for: "scene-1")?.properties.map(\.name)
      }
      XCTAssertEqual(names(), ["Size"])

      try await panel.store.setLabelLanguageAsync(Self.japanese)

      XCTAssertEqual(panel.bridge.labelLanguageCalls, [["ja-jp", "en-us"]])
      XCTAssertEqual(names(), ["サイズ"])
    }
  }

  // MARK: Audio and media delivery

  private func report(
    kind: BridgeWallpaperKind = .webpage, host: WebWallpaperHost.DeliveryStatus?,
    sceneMedia: SystemMediaAvailability? = nil
  ) -> InspectorOptions.DeliveryReport {
    InspectorOptions.DeliveryReport.make(
      kind: kind, wallpaperID: "wallpaper", host: host, sceneMedia: sceneMedia)
  }

  func testNoRunningHostReportsNeitherDeliveringNorNotDelivering() {
    let delivery = report(host: nil)
    XCTAssertEqual(delivery.audio, .unknown, "with no host the panel has made no observation, so it must not publish one")
    XCTAssertEqual(delivery.media, .unknown)
  }

  func testOnlyAConfirmedAudioFrameIsReportedAsDelivering() {
    let delivery = report(
      host: .init(audioSubscribedDisplayIDs: [1], audioStates: ["wallpaper": .delivering], mediaUnavailableReason: nil))
    XCTAssertEqual(delivery.audio, .delivering)
  }

  func testAnEnabledSettingWithNoSubscriberIsReportedAsNotUsingAudio() {
    let delivery = report(
      host: .init(audioSubscribedDisplayIDs: [], audioStates: ["wallpaper": .idle], mediaUnavailableReason: nil))
    XCTAssertEqual(
      delivery.audio, .idle,
      "the user's setting is on, but nothing asked for data, and those are different claims")
  }

  func testAnotherWallpaperAndAnUnconfirmedSubscriptionNeverClaimDelivery() {
    XCTAssertEqual(
      report(host: .init(audioSubscribedDisplayIDs: [1], audioStates: ["other": .delivering])).audio,
      .inactive, "a host with nothing for this wallpaper is not the same as no host")
    let states: [(WebWallpaperHost.AudioDeliveryState, InspectorOptions.DeliveryReport.Audio)] = [
      (.connecting, .connecting), (.subscribed, .subscribed), (.failed, .failed),
    ]
    for (state, expected) in states {
      XCTAssertEqual(report(host: .init(audioStates: ["wallpaper": state])).audio, expected)
    }
  }

  func testAnAvailableMediaSourceIsDistinguishableFromAnUnknownOneAndAnUnavailableOneCarriesItsReason() {
    XCTAssertEqual(report(host: .init(mediaUnavailableReason: nil)).media, .available)
    XCTAssertEqual(report(host: nil).media, .unknown)
    XCTAssertEqual(
      report(host: .init(mediaUnavailableReason: "MediaRemote refused the request.")).media,
      .unavailable(reason: "MediaRemote refused the request."))
  }

  func testASceneTakesItsMediaFromTheSystemAndAWebPageHasOutputControls() {
    XCTAssertEqual(report(kind: .projectScene, host: nil, sceneMedia: .available).media, .available)
    XCTAssertEqual(
      report(kind: .projectScene, host: nil, sceneMedia: .unavailable(reason: "No source")).media,
      .unavailable(reason: "No source"))
    XCTAssertNil(report(kind: .projectScene, host: nil).webOutput, "only web wallpapers have output controls")

    XCTAssertEqual(
      report(host: nil).webOutput, .init(volume: .unknown, mute: .unknown),
      "how far Volume reaches is confirmed once the wallpaper is running")
    var controls = WebWallpaperAudioOutput.Capabilities(mediaVolume: true, pageMute: false)
    XCTAssertEqual(
      report(host: .init(audioOutputControls: ["wallpaper": controls])).webOutput,
      .init(volume: .mediaElements, mute: .unavailable))
    controls = WebWallpaperAudioOutput.Capabilities(mediaVolume: false, pageMute: true)
    XCTAssertEqual(
      report(host: .init(audioOutputControls: ["wallpaper": controls])).webOutput,
      .init(volume: .unavailable, mute: .available))
  }

  func testDeliveryStatusNeverOverwritesTheUsersOwnSettings() {
    var inputs = InspectorOptions.Inputs()
    inputs.delivery = .init(audioSubscribedDisplayIDs: [7], mediaUnavailableReason: nil)
    let options = InspectorOptions.make(
      BridgeSnapshotFixtures.options(
        kind: .webpage, audioResponseEnabled: false, mediaIntegrationEnabled: false),
      inputs: inputs)
    XCTAssertFalse(options.audioResponseEnabled)
    XCTAssertFalse(options.mediaIntegrationEnabled)
    XCTAssertEqual(options.delivery.media, .available)
    XCTAssertTrue(options.offersMediaIntegration)
  }
}
