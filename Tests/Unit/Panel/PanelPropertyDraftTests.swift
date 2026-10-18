import XCTest

@testable import WallpaperMachine

/// What counts as a pending change in the inspector, and what Apply, Revert, Restore and a commit do
/// about it: text typed and not yet committed, a value chosen and not yet taken, the values a
/// control may send, and the properties a visibility rule hides.
@MainActor
final class PanelPropertyDraftTests: XCTestCase {
  private func row(_ id: String, in context: PanelPropertyContext, of wallpaper: String = "wp")
    throws -> InspectorOptions.PropertyRow
  {
    let options = try XCTUnwrap(context.controller.inspectorOptions(for: wallpaper))
    return try XCTUnwrap(options.properties.first { $0.id == id }, id)
  }

  // MARK: Typed text

  func testTypedTextIsADraftThatCountsAsAChangeUntilItIsCommitted() async throws {
    try await PanelPropertyContext.with { context in
      let controller = context.controller
      var options = try XCTUnwrap(controller.inspectorOptions(for: "wp"))
      XCTAssertFalse(options.hasChanges)
      XCTAssertFalse(options.canApply)
      XCTAssertFalse(options.canRevert)
      XCTAssertEqual(controller.presetsState?.isDirty, false)

      controller.setPropertyText("typed", property: "note", in: "wp")

      options = try XCTUnwrap(controller.inspectorOptions(for: "wp"))
      XCTAssertEqual(try row("note", in: context).control, .text("typed"))
      XCTAssertTrue(try row("note", in: context).isModified, "the Modified mark follows the draft")
      XCTAssertFalse(try row("note", in: context).isDirty, "the bridge does not know of it")
      XCTAssertTrue(options.hasUnsentChanges)
      XCTAssertTrue(options.canApply, "Apply changes and Revert follow typed text")
      XCTAssertTrue(options.canRevert)
      XCTAssertTrue(options.canRestoreAll, "text not yet sent counts as a change")
      XCTAssertEqual(controller.presetsState?.isDirty, true)
      XCTAssertEqual(controller.presetsState?.canSave, false, "a preset waits for a clean draft")
      XCTAssertTrue(context.bridge.events.isEmpty, "nothing reached the bridge")

      try await controller.commitProperty("wp", property: "note", value: .string(value: "typed"))

      XCTAssertNil(controller.propertyTextDraft("note", in: "wp"), "the bridge holds it now")
      XCTAssertEqual(try row("note", in: context).control, .text("typed"))
      XCTAssertTrue(try row("note", in: context).isModified)
      XCTAssertTrue(try row("note", in: context).isDirty)
      XCTAssertEqual(context.bridge.edits, [.init(propertyId: "note", value: .string(value: "typed"))])
    }
  }

  func testACommitKeepsTextTypedWhileItWaitedAndTheDraftWhenTheEditIsRefused() async throws {
    try await PanelPropertyContext.with { context in
      let controller = context.controller
      let store = context.store
      var release: CheckedContinuation<Void, Never>?
      let running = Task { @MainActor in
        await store.commands.run { await withCheckedContinuation { release = $0 } }
      }
      for _ in 0..<200 where release == nil { await Task.yield() }

      controller.setPropertyText("hello", property: "note", in: "wp")
      let commit = Task { @MainActor in
        try await controller.commitProperty("wp", property: "note", value: .string(value: "hello"))
      }
      for _ in 0..<200 where store.commands.waiting.isEmpty { await Task.yield() }
      // The user goes on typing while the commit waits its turn.
      controller.setPropertyText("hello!", property: "note", in: "wp")
      release?.resume()
      _ = await running.value
      try await commit.value

      XCTAssertEqual(
        controller.propertyTextDraft("note", in: "wp"), "hello!",
        "what was typed after the commit was asked for is still a draft")
      XCTAssertEqual(try row("note", in: context).control, .text("hello!"))

      context.bridge.editFailure = InspectorTestRefusal()
      do {
        try await controller.commitProperty("wp", property: "note", value: .string(value: "hello!"))
        XCTFail("the bridge refused the edit")
      } catch is InspectorTestRefusal {}
      XCTAssertEqual(
        controller.propertyTextDraft("note", in: "wp"), "hello!", "refused text stays for another try")
    }
  }

  func testApplyChangesSendsTheTypedTextAndRefusesTextTooLongForAProperty() async throws {
    try await PanelPropertyContext.with { context in
      let controller = context.controller
      controller.setPropertyText(String(repeating: "x", count: 65_537), property: "note", in: "wp")
      await assertInspectorInvalidValue("a draft longer than a text property takes") {
        try await controller.apply("wp")
      }
      XCTAssertTrue(context.bridge.events.isEmpty, "nothing was sent")

      controller.setPropertyText("fits", property: "note", in: "wp")
      try await controller.apply("wp")
      XCTAssertEqual(context.bridge.events, ["edit wp", "apply wp"], "Apply sent the text it held")
      XCTAssertEqual(context.bridge.edits, [.init(propertyId: "note", value: .string(value: "fits"))])
      XCTAssertNil(controller.propertyTextDraft("note", in: "wp"), "and the draft is gone")
    }
  }

  func testRevertAndTheRestoresDropTypedText() async throws {
    try await PanelPropertyContext.with { context in
      let controller = context.controller
      controller.setPropertyText("typed", property: "note", in: "wp")
      try await controller.revert("wp")
      XCTAssertNil(controller.propertyTextDraft("note", in: "wp"), "Revert drops the draft first")
      XCTAssertEqual(context.bridge.events, ["cancel wp"])

      controller.setPropertyText("typed", property: "note", in: "wp")
      controller.setPropertyText("elsewhere", property: "note", in: "wp2")
      try await controller.restoreProperty("wp", property: "note")
      XCTAssertNil(controller.propertyTextDraft("note", in: "wp"))
      XCTAssertEqual(controller.propertyTextDraft("note", in: "wp2"), "elsewhere")
      XCTAssertEqual(context.bridge.restored, ["note"])

      controller.setPropertyText("typed", property: "note", in: "wp")
      try await controller.restoreAllProperties("wp")
      XCTAssertNil(controller.propertyTextDraft("note", in: "wp"))
      XCTAssertEqual(
        controller.propertyTextDraft("note", in: "wp2"), "elsewhere", "another wallpaper's text is its own")
      XCTAssertEqual(context.bridge.restored, ["note", "*"])
    }
  }

  /// Restore all defaults throws away unsent typed text, shows the defaults the bridge staged (the
  /// slider back at its default, the text back to the applied text), offers Apply (the staged state
  /// differs from what is applied) and has nothing left to restore.
  func testRestoreAllDropsUnsentTextAndShowsTheDefaultsTheBridgeStaged() async throws {
    try await PanelPropertyContext.with { context in
      let controller = context.controller
      func properties(size: Double, dirty: Bool) -> [BridgePropertyDescriptor] {
        [
          PanelPropertyContext.property(
            "size", .slider, .number(value: size),
            slider: .init(min: 0, max: 100, step: 1, precision: 0), dirty: dirty,
            defaultValue: .number(value: 10)),
          PanelPropertyContext.property(
            "message", .textInput, .string(value: "Saved"), defaultValue: .string(value: "Saved")),
        ]
      }
      let edited = BridgeSnapshotFixtures.options(
        wallpaperId: "wp", kind: .projectScene, properties: properties(size: 42, dirty: true))
      let staged = BridgeSnapshotFixtures.options(
        wallpaperId: "wp", kind: .projectScene, dirty: true,
        properties: properties(size: 10, dirty: false))
      context.bridge.options["wp"] = edited
      context.store.wallpaperOptionsSnapshot = edited
      context.bridge.restoreAllAnswer = staged

      XCTAssertEqual(try XCTUnwrap(controller.inspectorOptions(for: "wp")).canRestoreAll, true)
      controller.setPropertyText("Typed, not sent", property: "message", in: "wp")
      XCTAssertTrue(try row("message", in: context).isModified)
      XCTAssertTrue(try row("size", in: context).isModified)

      try await controller.restoreAllProperties("wp")

      XCTAssertEqual(context.bridge.restored, ["*"])
      XCTAssertFalse(try row("size", in: context).isModified)
      XCTAssertFalse(try row("message", in: context).isModified)
      XCTAssertEqual(try row("message", in: context).control, .text("Saved"))
      guard case .slider(let slider) = try row("size", in: context).control else {
        return XCTFail("the size is a slider")
      }
      XCTAssertEqual(slider.value, 10)
      let options = try XCTUnwrap(controller.inspectorOptions(for: "wp"))
      XCTAssertTrue(options.canApply, "the staged state differs from what is applied")
      XCTAssertFalse(options.canRestoreAll, "everything reads as its default, so nothing is left to restore")
    }
  }

  // MARK: A value on its way

  func testAChosenValueIsShownWhileItsEditWaitsAndTheBridgesValueReturnsWhenItIsRefused() async throws {
    try await PanelPropertyContext.with { context in
      let controller = context.controller
      let store = context.store
      var release: CheckedContinuation<Void, Never>?
      let running = Task { @MainActor in
        await store.commands.run { await withCheckedContinuation { release = $0 } }
      }
      for _ in 0..<200 where release == nil { await Task.yield() }

      let commit = Task { @MainActor in
        try await controller.commitProperty("wp", property: "mode", value: .bool(value: true))
      }
      for _ in 0..<200 where store.commands.waiting.isEmpty { await Task.yield() }

      XCTAssertEqual(
        try row("mode", in: context).control, .toggle(isOn: true),
        "the control shows what was just chosen, not the saved value, while the edit waits")
      XCTAssertTrue(try row("mode", in: context).isModified)
      XCTAssertTrue(try XCTUnwrap(controller.inspectorOptions(for: "wp")).hasUnsentChanges)
      XCTAssertTrue(controller.pendingPropertyValues.isEmpty == false)

      release?.resume()
      _ = await running.value
      try await commit.value
      XCTAssertTrue(controller.pendingPropertyValues.isEmpty, "the entry goes when the edit ends")
      XCTAssertEqual(try row("mode", in: context).control, .toggle(isOn: true), "now the bridge's")

      context.bridge.editFailure = InspectorTestRefusal()
      do {
        try await controller.commitProperty("wp", property: "mode", value: .bool(value: false))
        XCTFail("the bridge refused the edit")
      } catch is InspectorTestRefusal {}
      XCTAssertTrue(controller.pendingPropertyValues.isEmpty)
      XCTAssertEqual(
        try row("mode", in: context).control, .toggle(isOn: true),
        "a refused value is not left on show as a stale draft")
    }
  }

  // MARK: What a control may send

  func testACommitIsHeldToTheRulesOfItsControl() async throws {
    try await PanelPropertyContext.with { context in
      let controller = context.controller
      var combo = PanelPropertyContext.property("shape", .combo, .number(value: 1))
      combo.comboOptions = [
        BridgeComboOption(label: "Round", value: .number(value: 1)),
        BridgeComboOption(label: "Square", value: .string(value: "1")),
      ]
      let options = BridgeSnapshotFixtures.options(
        wallpaperId: "wp", kind: .projectScene,
        properties: PanelPropertyContext.properties + [
          combo,
          PanelPropertyContext.property("cover", .file, .empty),
          PanelPropertyContext.property("album", .directory, .empty),
        ])
      context.bridge.options["wp"] = options
      context.store.wallpaperOptionsSnapshot = options

      // A choice is one of the author's values, and a number and a string stay distinct.
      try await controller.commitProperty("wp", property: "shape", value: .string(value: "1"))
      try await controller.commitProperty("wp", property: "shape", value: .number(value: 1))
      for value in [BridgePropertyValue.number(value: 2), .string(value: "2"), .bool(value: true), .empty] {
        await assertInspectorInvalidValue("a shape of \(value)") {
          try await controller.commitProperty("wp", property: "shape", value: value)
        }
      }
      // A switch takes a switch; text and a picture take text, at most 65,536 characters.
      await assertInspectorInvalidValue("a number for a switch") {
        try await controller.commitProperty("wp", property: "mode", value: .number(value: 1))
      }
      try await controller.commitProperty(
        "wp", property: "note", value: .string(value: String(repeating: "x", count: 65_536)))
      await assertInspectorInvalidValue("text one character too long") {
        try await controller.commitProperty(
          "wp", property: "note", value: .string(value: String(repeating: "x", count: 65_537)))
      }
      await assertInspectorInvalidValue("a number for text") {
        try await controller.commitProperty("wp", property: "note", value: .number(value: 1))
      }
      try await controller.commitProperty("wp", property: "picture", value: .string(value: ""))
      // A file and a folder travel through their own picker, and a property a rule hides takes no edit.
      await assertInspectorInvalidValue("a path through the generic editor") {
        try await controller.commitProperty("wp", property: "cover", value: .string(value: "/a.png"))
      }
      await assertInspectorInvalidValue("a path through the generic editor") {
        try await controller.commitProperty("wp", property: "album", value: .string(value: "/a"))
      }
      await assertInspectorInvalidValue("a disabled property") {
        try await controller.commitProperty("wp", property: "locked", value: .number(value: 0.5))
      }
      await assertInspectorInvalidValue("an unknown property") {
        try await controller.commitProperty("wp", property: "nope", value: .number(value: 0.5))
      }
      XCTAssertEqual(
        context.bridge.edits.map(\.propertyId), ["shape", "shape", "note", "picture"],
        "only what a control offers reached the bridge")
      XCTAssertTrue(controller.pendingPropertyValues.isEmpty, "a refused value is not left shown")
    }
  }

  // MARK: Rules that hide properties

  func testPendingTextGoesWithThePropertyARuleHides() async throws {
    try await PanelPropertyContext.with { context in
      func options(detailEnabled: Bool) -> BridgeWallpaperOptionsSnapshot {
        BridgeSnapshotFixtures.options(
          wallpaperId: "wp", kind: .projectScene,
          properties: [
            PanelPropertyContext.property("gate", .bool, .bool(value: detailEnabled)),
            PanelPropertyContext.property(
              "detail", .textInput, .string(value: "x"), enabled: detailEnabled),
            PanelPropertyContext.property("title", .textInput, .string(value: "y")),
          ])
      }
      let open = options(detailEnabled: true)
      context.bridge.options["wp"] = open
      context.store.wallpaperOptionsSnapshot = open
      let controller = context.controller
      controller.setPropertyText("typed, not sent", property: "detail", in: "wp")
      controller.setPropertyText("also unsent", property: "title", in: "wp")
      let closed = options(detailEnabled: false)
      context.bridge.editAnswer = { _ in closed }

      try await controller.commitProperty("wp", property: "gate", value: .bool(value: false))

      XCTAssertNil(
        controller.propertyTextDraft("detail", in: "wp"),
        "text for a field that is gone cannot be applied, so it is not kept as a pending edit")
      XCTAssertEqual(controller.propertyTextDraft("title", in: "wp"), "also unsent")
    }
  }
}
