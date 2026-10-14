import Foundation
import XCTest

@testable import WallpaperMachine

@MainActor
final class WallpaperPresetStoreTests: XCTestCase {
  func testDirtyAndDraftEditsCannotBecomeSavedAppliedState() async throws {
    let context = try Context()
    defer { context.close() }
    await assertFailure { _ = try await context.store.save(name: "Evening", options: self.options(dirty: true), hasPendingEdits: false) }
    await assertFailure { _ = try await context.store.save(name: "Evening", options: self.options(), hasPendingEdits: true) }
    XCTAssertTrue(context.store.items.isEmpty)
  }

  func testRenameAndDeletionPersistAcrossStoreInstances() async throws {
    let context = try Context()
    defer { context.close() }
    let saved = try await context.store.save(name: " Morning ", options: options(properties: [property("active", .bool, .bool(value: true))]), hasPendingEdits: false)
    try context.store.rename(id: saved.id, name: "Evening")
    let reopened = context.reopen()
    XCTAssertEqual(try reopened.preset(id: saved.id).name, "Evening")
    XCTAssertEqual(try reopened.preset(id: saved.id).properties.first?.value, .bool(true))
    try await reopened.delete(id: saved.id)
    XCTAssertTrue(context.reopen().presets(wallpaperID: "wallpaper").isEmpty)
  }

  func testAuthoredDefaultsAreResolvedAtApplyRatherThanFrozen() async throws {
    let context = try Context()
    defer { context.close() }
    let original = property("active", .bool, .bool(value: true), usesDefault: true)
    let saved = try await context.store.save(name: "Default", options: options(properties: [original]), hasPendingEdits: false)
    var updated = property("active", .bool, .bool(value: true))
    updated.defaultValue = .bool(value: false)
    let plan = try context.store.mutations(for: saved, options: options(properties: [updated]))
    XCTAssertEqual(plan.map(\.propertyID), ["active"])
    guard case .restoreDefault = plan[0].operation else { return XCTFail("The new authored default must be restored by the existing API") }
  }

  func testUnknownOrChangedTypeRejectsTheWholePlan() async throws {
    let context = try Context()
    defer { context.close() }
    let saved = try await context.store.save(name: "Both", options: options(properties: [
      property("active", .bool, .bool(value: true)), property("label", .textInput, .string(value: "hello")),
    ]), hasPendingEdits: false)
    XCTAssertThrowsError(try context.store.mutations(for: saved, options: options(properties: [property("active", .bool, .bool(value: false))])))
    XCTAssertThrowsError(try context.store.mutations(for: saved, options: options(properties: [
      property("active", .bool, .bool(value: false)), property("label", .bool, .bool(value: true)),
    ])))
  }

  func testChangedRangeAndComboChoicesRejectOldValues() async throws {
    let context = try Context()
    defer { context.close() }
    var slider = property("speed", .slider, .number(value: 8))
    slider.slider = BridgeSliderMetadata(min: 0, max: 10, step: 1, precision: 0)
    let saved = try await context.store.save(name: "Fast", options: options(properties: [slider]), hasPendingEdits: false)
    slider.slider = BridgeSliderMetadata(min: 0, max: 5, step: 1, precision: 0)
    XCTAssertThrowsError(try context.store.mutations(for: saved, options: options(properties: [slider])))
    var combo = property("mode", .combo, .string(value: "a"))
    combo.comboOptions = [BridgeComboOption(label: "A", value: .string(value: "a"))]
    let selected = try await context.store.save(name: "A", options: options(properties: [combo]), hasPendingEdits: false)
    combo.comboOptions = [BridgeComboOption(label: "B", value: .string(value: "b"))]
    XCTAssertThrowsError(try context.store.mutations(for: selected, options: options(properties: [combo])))
  }

  func testManagedFileSurvivesPropertyReplacementAndPortableImport() async throws {
    let context = try Context()
    defer { context.close() }
    let source = context.root.appendingPathComponent("cover ü%?#.png")
    let bytes = Data("first image".utf8)
    try bytes.write(to: source)
    let asset = try context.managed.adopt(readingFrom: source, fileName: source.lastPathComponent,
      sourcePath: source.path, wallpaperId: "wallpaper", propertyId: "cover", known: nil)
    try context.managed.write(UserAssetManifest(wallpaperId: "wallpaper", properties: [
      "cover": ManagedUserAssetProperty(kind: .file, sourcePath: source.path, assets: [asset]),
    ]))
    var descriptor = property("cover", .file, .string(value: source.path))
    descriptor.fileFilter = .image
    descriptor.assetManaged = true
    let saved = try await context.store.save(name: "Cover", options: options(properties: [descriptor]), hasPendingEdits: false)
    try context.managed.write(UserAssetManifest(wallpaperId: "wallpaper"))
    context.managed.removeProperty(wallpaperId: "wallpaper", propertyId: "cover")
    try FileManager.default.removeItem(at: source)
    let retained = try XCTUnwrap(saved.properties.first?.retainedPath)
    _ = try await UserAssetStorage.purgeUnreferencedDerivedCaches(store: context.managed)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: retained)), bytes)
    let exported = try await context.reopen().exportDocument(id: saved.id)
    let imported = try await context.store.importDocument(exported, options: options(properties: [descriptor]))
    let importedPath = try XCTUnwrap(imported.properties.first?.retainedPath)
    XCTAssertNotEqual(saved.id, imported.id)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: importedPath)), bytes)
    try await context.store.delete(id: saved.id)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: importedPath)), bytes)
    let plan = try context.store.mutations(for: imported, options: options(properties: [descriptor]))
    let operation = try XCTUnwrap(plan.first).operation
    guard case .path(let path) = operation else { return XCTFail("A file must use the path API, not generic values") }
    XCTAssertEqual(path, importedPath)
  }

  func testPortableDirectoryKeepsAllMembersAndUsesDirectoryPath() async throws {
    let context = try Context()
    defer { context.close() }
    let preset = WallpaperPropertyPreset(id: UUID().uuidString, wallpaperID: "wallpaper", name: "Slides", properties: [
      WallpaperPresetProperty(id: "slides", kind: "directory", value: .string(""), usesDefault: false),
    ])
    let document = WallpaperPresetDocument(preset: preset, assets: ["slides": [
      .init(name: "a.png", bytes: Data("a".utf8)), .init(name: "b.jpg", bytes: Data("b".utf8)),
    ]])
    var descriptor = property("slides", .directory, .empty)
    descriptor.fileFilter = .image
    let imported = try await context.store.importDocument(JSONEncoder().encode(document), options: options(properties: [descriptor]))
    let path = try XCTUnwrap(imported.properties.first?.retainedPath)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("b.jpg")), Data("b".utf8))
    try Data("Finder metadata".utf8).write(to: URL(fileURLWithPath: path).appendingPathComponent(".DS_Store"))
    let exported = try await context.store.exportDocument(id: imported.id)
    let portable = try JSONDecoder().decode(WallpaperPresetDocument.self, from: exported)
    XCTAssertEqual(portable.assets["slides"]?.map(\.name), ["a.png", "b.jpg"])
    let roundtrip = try await context.store.importDocument(exported, options: options(properties: [descriptor]))
    let roundtripPath = try XCTUnwrap(roundtrip.properties.first?.retainedPath)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: roundtripPath).appendingPathComponent("b.jpg")), Data("b".utf8))
    let plan = try context.store.mutations(for: imported, options: options(properties: [descriptor]))
    guard case .path(let selection) = plan[0].operation else { return XCTFail("Directory selection semantics were lost") }
    XCTAssertEqual(selection, path)
    let liveFolder = context.root.appendingPathComponent("Live slides")
    try FileManager.default.createDirectory(at: liveFolder, withIntermediateDirectories: true)
    var livePreset = imported
    livePreset.properties[0].value = .string(liveFolder.path)
    let livePlan = try context.store.mutations(for: livePreset, options: options(properties: [descriptor]))
    guard case .path(let liveSelection) = livePlan[0].operation else { return XCTFail("A live directory must retain its watched source") }
    XCTAssertEqual(liveSelection, liveFolder.path)
  }

  func testImportRejectsVersionWrongWallpaperTraversalAndExternalReference() async throws {
    let context = try Context()
    defer { context.close() }
    let property = WallpaperPresetProperty(id: "cover", kind: "file", value: .string(""), usesDefault: false)
    let preset = WallpaperPropertyPreset(id: UUID().uuidString, wallpaperID: "wallpaper", name: "Cover", properties: [property])
    var document = WallpaperPresetDocument(preset: preset, assets: ["cover": [.init(name: "cover.png", bytes: Data([1]))]])
    var descriptor = self.property("cover", .file, .empty)
    descriptor.fileFilter = .image
    let target = options(properties: [descriptor])
    document.version = 99
    await assertFailure { _ = try await context.store.importDocument(JSONEncoder().encode(document), options: target) }
    document.version = 1
    document.preset.wallpaperID = "other"
    await assertFailure { _ = try await context.store.importDocument(JSONEncoder().encode(document), options: target) }
    document.preset.wallpaperID = "wallpaper"
    document.assets["cover"] = [.init(name: "../escape.png", bytes: Data([1]))]
    await assertFailure { _ = try await context.store.importDocument(JSONEncoder().encode(document), options: target) }
    document.assets = [:]
    document.preset.properties[0].value = .string("/private/secret.png")
    await assertFailure { _ = try await context.store.importDocument(JSONEncoder().encode(document), options: target) }
    XCTAssertTrue(context.store.items.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: context.root.appendingPathComponent("escape.png").path))
  }

  func testImportRejectsOversizedDocumentsAndDuplicateAttachmentsWithoutPublishing() async throws {
    let context = try Context()
    defer { context.close() }
    let oversized = Data(repeating: 32, count: WallpaperPresetStore.maximumDocumentBytes + 1)
    await assertFailure { _ = try await context.store.importDocument(oversized, options: self.options()) }
    let preset = WallpaperPropertyPreset(id: UUID().uuidString, wallpaperID: "wallpaper", name: "Slides", properties: [
      .init(id: "slides", kind: "directory", value: .string(""), usesDefault: false),
    ])
    let document = WallpaperPresetDocument(preset: preset, assets: ["slides": [
      .init(name: "same.png", bytes: Data([1])), .init(name: "same.png", bytes: Data([2])),
    ]])
    await assertFailure { _ = try await context.store.importDocument(JSONEncoder().encode(document),
      options: self.options(properties: [self.property("slides", .directory, .empty)])) }
    XCTAssertTrue(context.store.items.isEmpty)
    XCTAssertNil(context.defaults.data(forKey: WallpaperPresetStore.preferenceKey))
  }

  func testMissingFileAndDisabledPropertyDoNotProducePartialPlan() async throws {
    let context = try Context()
    defer { context.close() }
    let file = context.root.appendingPathComponent("cover.png")
    try Data([1]).write(to: file)
    var cover = property("cover", .file, .string(value: file.path))
    cover.fileFilter = .image
    let saved = try await context.store.save(name: "Cover", options: options(properties: [property("active", .bool, .bool(value: true)), cover]), hasPendingEdits: false)
    try FileManager.default.removeItem(at: file)
    XCTAssertThrowsError(try context.store.mutations(for: saved, options: options(properties: [property("active", .bool, .bool(value: false)), cover])))
    var disabled = property("active", .bool, .bool(value: false))
    disabled.enabled = false
    let boolPreset = WallpaperPropertyPreset(id: UUID().uuidString, wallpaperID: "wallpaper", name: "On", properties: [
      .init(id: "active", kind: "bool", value: .bool(true), usesDefault: false),
    ])
    XCTAssertThrowsError(try context.store.mutations(for: boolPreset, options: options(properties: [disabled])))
  }

  func testSavingKeepsTheListedPropertiesAndLeavesRuleHiddenOnesOut() async throws {
    let context = try Context()
    defer { context.close() }
    var hidden = property("detail", .textInput, .string(value: "tucked away"))
    hidden.enabled = false
    var legacy = property("legacy", .unknown, .empty)
    legacy.enabled = false
    let saved = try await context.store.save(
      name: "Listed", options: options(properties: [property("mode", .bool, .bool(value: true)), hidden, legacy]),
      hasPendingEdits: false)
    XCTAssertEqual(saved.properties.map(\.id), ["mode"], "A preset holds what the panel lists, and a hidden unknown type does not block saving")
  }

  func testAHiddenPropertyStaysKnownToAPresetThatNamesIt() async throws {
    let context = try Context()
    defer { context.close() }
    var hidden = property("detail", .textInput, .string(value: "before"))
    hidden.enabled = false
    let preset = WallpaperPropertyPreset(id: UUID().uuidString, wallpaperID: "wallpaper", name: "Detail", properties: [
      .init(id: "detail", kind: "textInput", value: .string("after"), usesDefault: false),
    ])
    let hiding = options(properties: [hidden])
    XCTAssertEqual(
      try context.store.mutations(for: preset, options: hiding, allowConditional: true).map(\.propertyID), ["detail"],
      "A rule hiding the field now is what apply and import resolve with the preset's own mode changes")
    XCTAssertThrowsError(try context.store.mutations(for: preset, options: hiding), "Outside that, a hidden field is disabled, not changed")
    XCTAssertThrowsError(try context.store.mutations(for: preset, options: options(), allowConditional: true), "A field the wallpaper no longer defines is still unknown")
  }

  func testCorruptArchiveCannotBeOverwrittenByNewSave() async throws {
    let context = try Context()
    defer { context.close() }
    let corrupt = Data("not json".utf8)
    context.defaults.set(corrupt, forKey: WallpaperPresetStore.preferenceKey)
    let reopened = context.reopen()
    XCTAssertNotNil(reopened.error)
    await assertFailure { _ = try await reopened.save(name: "New", options: self.options(), hasPendingEdits: false) }
    XCTAssertEqual(context.defaults.data(forKey: WallpaperPresetStore.preferenceKey), corrupt)
  }

  func testCaseAndUnicodeAliasesRejectImportWithoutChangingSavedBytes() async throws {
    let context = try Context()
    defer { context.close() }
    let preset = WallpaperPropertyPreset(id: UUID().uuidString, wallpaperID: "wallpaper", name: "Slides", properties: [
      .init(id: "slides", kind: "directory", value: .string(""), usesDefault: false),
    ])
    let target = options(properties: [property("slides", .directory, .empty)])
    let original = WallpaperPresetDocument(preset: preset, assets: ["slides": [.init(name: "cover.png", bytes: Data("original".utf8))]])
    let saved = try await context.store.importDocument(JSONEncoder().encode(original), options: target)
    let source = URL(fileURLWithPath: try XCTUnwrap(saved.properties[0].retainedPath)).appendingPathComponent("cover.png")
    let archive = context.defaults.data(forKey: WallpaperPresetStore.preferenceKey)
    for names in [["cover.png", "COVER.PNG"], ["é.png", "E\u{301}.PNG"]] {
      let colliding = WallpaperPresetDocument(preset: preset, assets: ["slides": [
        .init(name: names[0], bytes: Data("first".utf8)), .init(name: names[1], bytes: Data("second".utf8)),
      ]])
      await assertFailure { _ = try await context.store.importDocument(JSONEncoder().encode(colliding), options: target) }
      XCTAssertEqual(context.defaults.data(forKey: WallpaperPresetStore.preferenceKey), archive)
      XCTAssertEqual(try Data(contentsOf: source), Data("original".utf8))
      XCTAssertEqual(context.reopen().items.map(\.id), [saved.id])
    }
  }

  func testDeletingAppliedDirectoryPreservesWatchedBytesAndReplacementReclaimsOrphan() async throws {
    let context = try Context()
    defer { context.close() }
    let preset = WallpaperPropertyPreset(id: UUID().uuidString, wallpaperID: "wallpaper", name: "Slides", properties: [
      .init(id: "slides", kind: "directory", value: .string(""), usesDefault: false),
    ])
    let document = WallpaperPresetDocument(preset: preset, assets: ["slides": [
      .init(name: "a.png", bytes: Data("a".utf8)), .init(name: "b.png", bytes: Data("b".utf8)),
    ]])
    let imported = try await context.store.importDocument(JSONEncoder().encode(document), options: options(properties: [property("slides", .directory, .empty)]))
    let source = URL(fileURLWithPath: try XCTUnwrap(imported.properties[0].retainedPath))
    let project = context.root.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    var watcher: PresetManualWatcher?
    let assets = UserAssetStore(projectURL: project, wallpaperId: "wallpaper", managed: context.managed, watcherFactory: { url, callback in
      let made = PresetManualWatcher(url: url, callback: callback)
      watcher = made
      return made
    })
    let initial = try await assets.importDirectory(at: source, propertyId: "slides", filter: .image, limit: 4096)
    // Reopening proves the active-source protection is not transient preset UI state.
    try await context.reopen().delete(id: imported.id)
    try XCTUnwrap(watcher).fire()
    XCTAssertEqual(assets.stagedFiles(propertyId: "slides"), initial)
    for file in initial {
      let name = URL(fileURLWithPath: file.stagedPath).lastPathComponent
      XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: file.stagedPath)), Data((name == "a.png" ? "a" : "b").utf8))
    }
    XCTAssertTrue(context.reopen().items.isEmpty)
    XCTAssertEqual(try context.managed.manifest(wallpaperId: "wallpaper").properties["slides"]?.sourcePath, source.path)

    let replacement = context.root.appendingPathComponent("replacement")
    try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
    try Data("new".utf8).write(to: replacement.appendingPathComponent("c.png"))
    let changed = try await assets.importDirectory(at: replacement, propertyId: "slides", filter: .image, limit: 4096)
    let currentFile = URL(fileURLWithPath: try XCTUnwrap(changed.first).stagedPath)
    XCTAssertEqual(try Data(contentsOf: currentFile), Data("new".utf8), "replacement is readable before orphan cleanup")
    try await context.reopen().pruneRetainedAssets(options: options(properties: [property("slides", .directory, .string(value: replacement.path))]))
    XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(changed.first).stagedPath)), Data("new".utf8))
  }

  func testDeletingPresetBeforeHostRestagePreservesCommittedSource() async throws {
    let context = try Context()
    defer { context.close() }
    let preset = WallpaperPropertyPreset(id: UUID().uuidString, wallpaperID: "wallpaper", name: "Slides", properties: [
      .init(id: "slides", kind: "directory", value: .string(""), usesDefault: false),
    ])
    let document = WallpaperPresetDocument(preset: preset, assets: ["slides": [.init(name: "a.png", bytes: Data("kept".utf8))]])
    let imported = try await context.store.importDocument(JSONEncoder().encode(document), options: options(properties: [property("slides", .directory, .empty)]))
    let source = URL(fileURLWithPath: try XCTUnwrap(imported.properties[0].retainedPath))
    let committed = options(properties: [property("slides", .directory, .string(value: source.path))])
    try await context.store.delete(id: imported.id, preservingPaths: WallpaperPresetStore.resourcePaths(committed))
    XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("a.png")), Data("kept".utf8))
    try await context.store.pruneRetainedAssets(options: committed)
    XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("a.png")), Data("kept".utf8))
    try await context.store.forget(wallpaperIDs: ["wallpaper"])
    XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
  }

  func testArchiveValidatorRejectsMalformedTypedValuesAndUnsafeRetainedMetadata() async throws {
    let id = UUID().uuidString
    let base = WallpaperPropertyPreset(id: id, wallpaperID: "wallpaper", name: "Valid", properties: [
      .init(id: "cover", kind: "file", value: .string("/tmp/cover.png"), usesDefault: false,
        retainedPath: "/tmp/PresetAssets/\(id)/cover/cover.png"),
    ])
    try WallpaperPresetStore.validateArchiveData(JSONEncoder().encode(PresetTestArchive(items: [base])))
    var invalid = base
    invalid.properties[0].retainedPath = "/private/secret.png"
    XCTAssertThrowsError(try WallpaperPresetStore.validateArchiveData(JSONEncoder().encode(PresetTestArchive(items: [invalid]))))
    invalid = base
    invalid.properties[0].usesDefault = true
    XCTAssertThrowsError(try WallpaperPresetStore.validateArchiveData(JSONEncoder().encode(PresetTestArchive(items: [invalid]))))
    invalid = base
    invalid.properties = [.init(id: "bad", kind: "bool", value: .number(1), usesDefault: false)]
    XCTAssertThrowsError(try WallpaperPresetStore.validateArchiveData(JSONEncoder().encode(PresetTestArchive(items: [invalid]))))
    invalid.properties = [.init(id: "bad", kind: "color", value: .color(red: 1.1, green: 0, blue: 0), usesDefault: false)]
    XCTAssertThrowsError(try WallpaperPresetStore.validateArchiveData(JSONEncoder().encode(PresetTestArchive(items: [invalid]))))
    invalid.properties = [.init(id: "Name", kind: "textInput", value: .string("a"), usesDefault: false),
                          .init(id: "name", kind: "textInput", value: .string("b"), usesDefault: false)]
    XCTAssertThrowsError(try WallpaperPresetStore.validateArchiveData(JSONEncoder().encode(PresetTestArchive(items: [invalid]))))
    XCTAssertThrowsError(try WallpaperPresetStore.validateArchiveData(JSONEncoder().encode(PresetTestArchive(version: 2, items: [base]))))
    XCTAssertThrowsError(try WallpaperPresetStore.validateArchiveData(JSONEncoder().encode(PresetTestArchive(items: [base, base]))))
  }

  func testSavingRetainedOnlyRestoreNeverPrefersExistingOriginalProvenance() async throws {
    let context = try Context()
    defer { context.close() }
    let backedUp = context.root.appendingPathComponent("backed-up.png")
    let original = context.root.appendingPathComponent("private-original.png")
    try Data("restored bytes".utf8).write(to: backedUp)
    try Data("not selected".utf8).write(to: original)
    let asset = try context.managed.adopt(readingFrom: backedUp, fileName: "cover.png", sourcePath: original.path,
      wallpaperId: "wallpaper", propertyId: "cover", known: nil)
    var record = ManagedUserAssetProperty(kind: .file, sourcePath: original.path, assets: [asset])
    record.originalSourceUnauthorized = true
    try context.managed.write(UserAssetManifest(wallpaperId: "wallpaper", properties: ["cover": record]))
    var descriptor = property("cover", .file, .string(value: original.path))
    descriptor.assetManaged = true
    descriptor.fileFilter = .image
    let selected = try await context.store.save(name: "Restored", options: options(properties: [descriptor]), hasPendingEdits: false)
    let path = try XCTUnwrap(selected.properties[0].retainedPath)
    XCTAssertEqual(selected.properties[0].value, .string(path))
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data("restored bytes".utf8))
    let plan = try context.store.mutations(for: selected, options: options(properties: [descriptor]))
    guard case .path(let source) = try XCTUnwrap(plan.first).operation else { return XCTFail("A restored selection needs retained bytes") }
    XCTAssertEqual(source, path)
    XCTAssertEqual(try context.managed.manifest(wallpaperId: "wallpaper").properties["cover"]?.originalSourceUnauthorized, true)
    let data = try await context.store.exportDocument(id: selected.id)
    let exported = try JSONDecoder().decode(WallpaperPresetDocument.self, from: data)
    XCTAssertEqual(exported.assets["cover"]?.first?.bytes, Data("restored bytes".utf8))
  }

  func testSuccessfulRetainedGrantReadsOwnedBytesAndStillRejectsOriginal() async throws {
    let context = try Context()
    defer { context.close() }
    let original = context.root.appendingPathComponent("original")
    let project = context.root.appendingPathComponent("project")
    for directory in [original, project] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    try Data("private original".utf8).write(to: original.appendingPathComponent("a.png"))
    let restoredFile = context.root.appendingPathComponent("restored.png")
    try Data("old retained".utf8).write(to: restoredFile)
    let asset = try context.managed.adopt(readingFrom: restoredFile, fileName: "a.png", sourcePath: original.appendingPathComponent("a.png").path,
      wallpaperId: "wallpaper", propertyId: "slides", known: nil)
    var record = ManagedUserAssetProperty(kind: .directory, sourcePath: original.path, assets: [asset])
    record.originalSourceUnauthorized = true
    try context.managed.write(UserAssetManifest(wallpaperId: "wallpaper", properties: ["slides": record]))
    let target = options(properties: [property("slides", .directory, .string(value: original.path))])
    let template = WallpaperPropertyPreset(id: UUID().uuidString, wallpaperID: "wallpaper", name: "Owned", properties: [
      .init(id: "slides", kind: "directory", value: .string(""), usesDefault: false),
    ])
    let document = WallpaperPresetDocument(preset: template, assets: ["slides": [.init(name: "a.png", bytes: Data("new owned".utf8))]])
    let selected = try await context.store.importDocument(JSONEncoder().encode(document), options: target)
    let retained = URL(fileURLWithPath: try XCTUnwrap(selected.properties[0].retainedPath))
    let assets = UserAssetStore(projectURL: project, wallpaperId: "wallpaper", managed: context.managed,
      watcherFactory: { PresetManualWatcher(url: $0, callback: $1) })
    try await UserAssetSelectionAuthorization.perform(managed: context.managed, wallpaperID: "wallpaper", selections: ["slides": retained.path]) {
      _ = try await assets.importDirectory(at: retained, propertyId: "slides", filter: .image, limit: 4096)
    }
    let served = try await assets.importDirectory(at: original, propertyId: "slides", filter: .image, limit: 4096)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(served.first).stagedPath)), Data("new owned".utf8))
    XCTAssertEqual(try context.managed.manifest(wallpaperId: "wallpaper").properties["slides"]?.authorizedSourcePath, retained.path)
    XCTAssertEqual(try Data(contentsOf: original.appendingPathComponent("a.png")), Data("private original".utf8))
  }

  func testAuthorizationRollbackPreservesUnrelatedImportsAndNewerSelectionScope() async throws {
    for newerSelection in [false, true] {
      let context = try Context()
      defer { context.close() }
      let original = context.root.appendingPathComponent("private-original")
      let project = context.root.appendingPathComponent("project")
      for directory in [original, project] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
      try Data("not selected".utf8).write(to: original.appendingPathComponent("a.png"))
      let actual = context.root.appendingPathComponent("restored.png")
      try Data("restored old".utf8).write(to: actual)
      let asset = try context.managed.adopt(readingFrom: actual, fileName: "a.png", sourcePath: original.appendingPathComponent("a.png").path,
        wallpaperId: "wallpaper", propertyId: "slides", known: nil)
      var record = ManagedUserAssetProperty(kind: .directory, sourcePath: original.path, assets: [asset])
      record.originalSourceUnauthorized = true
      try context.managed.write(UserAssetManifest(wallpaperId: "wallpaper", properties: ["slides": record]))
      let current = options(properties: [property("slides", .directory, .string(value: original.path))])
      let template = WallpaperPropertyPreset(id: UUID().uuidString, wallpaperID: "wallpaper", name: "Retained", properties: [
        .init(id: "slides", kind: "directory", value: .string(""), usesDefault: false),
      ])
      let document = WallpaperPresetDocument(preset: template, assets: ["slides": [.init(name: "a.png", bytes: Data("owned new".utf8))]])
      let selected = try await context.store.importDocument(JSONEncoder().encode(document), options: current)
      let retained = try XCTUnwrap(selected.properties[0].retainedPath)
      let assets = UserAssetStore(projectURL: project, wallpaperId: "wallpaper", managed: context.managed,
        watcherFactory: { PresetManualWatcher(url: $0, callback: $1) })
      if newerSelection {
        let newer = context.root.appendingPathComponent("newer-selection")
        try FileManager.default.createDirectory(at: newer, withIntermediateDirectories: true)
        try Data("newer bytes".utf8).write(to: newer.appendingPathComponent("a.png"))
        var staged = [UserAssetImport]()
        var latest: ManagedUserAssetProperty?
        await assertFailure {
          try await UserAssetSelectionAuthorization.perform(managed: context.managed, wallpaperID: "wallpaper", selections: ["slides": retained]) {
            try context.managed.authorizeSelection(wallpaperId: "wallpaper", propertyId: "slides", selectedSourcePath: newer.path)
            staged = try await assets.importDirectory(at: newer, propertyId: "slides", filter: .image, limit: 4096)
            latest = try context.managed.manifest(wallpaperId: "wallpaper").properties["slides"]
            throw CancellationError()
          }
        }
        XCTAssertEqual(try context.managed.manifest(wallpaperId: "wallpaper").properties["slides"], latest)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(staged.first).stagedPath)), Data("newer bytes".utf8))
      } else {
        let other = context.root.appendingPathComponent("other.png")
        try Data("other user's bytes".utf8).write(to: other)
        var imported: UserAssetImport?
        var latestOther: ManagedUserAssetProperty?
        await assertFailure {
          try await UserAssetSelectionAuthorization.perform(managed: context.managed, wallpaperID: "wallpaper", selections: ["slides": retained]) {
            imported = try await assets.importFile(at: other, propertyId: "other", filter: .image)
            latestOther = try context.managed.manifest(wallpaperId: "wallpaper").properties["other"]
            throw CancellationError()
          }
        }
        let restored = try context.managed.manifest(wallpaperId: "wallpaper")
        XCTAssertEqual(restored.properties["other"], latestOther)
        XCTAssertEqual(restored.properties["slides"]?.originalSourceUnauthorized, true)
        XCTAssertNil(restored.properties["slides"]?.authorizedSourcePath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(imported).stagedPath)), Data("other user's bytes".utf8))
        let old = try await assets.importDirectory(at: original, propertyId: "slides", filter: .image, limit: 4096)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(old.first).stagedPath)), Data("restored old".utf8))
      }
    }
  }

  func testNoOpRetainedApplyStillAppliesAndRollsBackPermissionOnFailure() async throws {
    let context = try Context()
    defer { context.close() }
    let wallpaperID = UUID().uuidString
    var initial = options(properties: [property("slides", .directory, .empty)])
    initial.wallpaperId = wallpaperID
    let template = WallpaperPropertyPreset(id: UUID().uuidString, wallpaperID: wallpaperID, name: "Retained", properties: [
      .init(id: "slides", kind: "directory", value: .string(""), usesDefault: false),
    ])
    let document = WallpaperPresetDocument(preset: template, assets: ["slides": [.init(name: "a.png", bytes: Data("retained".utf8))]])
    let selected = try await context.store.importDocument(JSONEncoder().encode(document), options: initial)
    let retained = URL(fileURLWithPath: try XCTUnwrap(selected.properties[0].retainedPath))
    let asset = try context.managed.adopt(readingFrom: retained.appendingPathComponent("a.png"), fileName: "a.png", sourcePath: retained.appendingPathComponent("a.png").path,
      wallpaperId: wallpaperID, propertyId: "slides", known: nil)
    var record = ManagedUserAssetProperty(kind: .directory, sourcePath: retained.path, assets: [asset])
    record.originalSourceUnauthorized = true
    try context.managed.write(UserAssetManifest(wallpaperId: wallpaperID, properties: ["slides": record]))
    initial.properties[0].value = .string(value: retained.path)
    let bridge = PresetTransactionBridge(noPointer: .init())
    let engineStore = BridgeStore(bridge: bridge)
    bridge.hostStore = engineStore
    let config = context.root.appendingPathComponent("committed.json")
    try bridge.initialize(initial, config: config)
    let manifest = try context.managed.wallpaperRoot(wallpaperID).appendingPathComponent(UserAssetManifest.fileName)
    let original = try Data(contentsOf: manifest)
    // A permission-only Apply still reaches real validation of the missing project.
    await assertFailure { try await context.store.apply(selected, options: initial, bridge: engineStore) }
    XCTAssertEqual(try Data(contentsOf: manifest), original)
    XCTAssertEqual(try context.managed.manifest(wallpaperId: wallpaperID).properties["slides"]?.originalSourceUnauthorized, true)
    XCTAssertNil(try context.managed.manifest(wallpaperId: wallpaperID).properties["slides"]?.authorizedSourcePath)
  }

  func testSetterAndFinalApplyFailureKeepCommittedPathsAndAssetBytes() async throws {
    for failLaterSetter in [true, false] {
      let context = try Context()
      defer { context.close() }
      let wallpaperID = UUID().uuidString
      let project = context.root.appendingPathComponent("project")
      let oldSource = context.root.appendingPathComponent("original")
      for directory in [project, oldSource] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      }
      try Data("original image".utf8).write(to: oldSource.appendingPathComponent("same.png"))
      let assets = UserAssetStore(projectURL: project, wallpaperId: wallpaperID, managed: context.managed,
        watcherFactory: { PresetManualWatcher(url: $0, callback: $1) })
      let staged = try await assets.importDirectory(at: oldSource, propertyId: "slides", filter: .image, limit: 4096)
      var restored = try context.managed.manifest(wallpaperId: wallpaperID)
      restored.properties["slides"]?.originalSourceUnauthorized = true
      try context.managed.write(restored)
      var active = property("active", .bool, .bool(value: false))
      active.defaultValue = .bool(value: true)
      var initial = options(properties: [property("slides", .directory, .string(value: oldSource.path)), active])
      initial.wallpaperId = wallpaperID
      let bridge = PresetTransactionBridge(noPointer: .init())
      let engineStore = BridgeStore(bridge: bridge)
      bridge.hostStore = engineStore
      bridge.assets = assets
      bridge.failedProperty = failLaterSetter ? "active" : nil
      let config = context.root.appendingPathComponent("committed.json")
      try bridge.initialize(initial, config: config)
      let committedBytes = try Data(contentsOf: config)
      let manifestURL = try context.managed.wallpaperRoot(wallpaperID).appendingPathComponent(UserAssetManifest.fileName)
      let manifestBytes = try Data(contentsOf: manifestURL)
      let template = WallpaperPropertyPreset(id: UUID().uuidString, wallpaperID: wallpaperID, name: "Replacement", properties: [
        .init(id: "slides", kind: "directory", value: .string(""), usesDefault: false),
        .init(id: "active", kind: "bool", value: .bool(true), usesDefault: !failLaterSetter),
      ])
      let document = WallpaperPresetDocument(preset: template, assets: ["slides": [.init(name: "same.png", bytes: Data("replacement image".utf8))]])
      let selected = try await context.store.importDocument(JSONEncoder().encode(document), options: initial)
      // The second variant reaches actual BridgeStore final-Apply validation:
      // this unique wallpaper has no Library project, rather than a mock apply error.
      await assertFailure { try await context.store.apply(selected, options: initial, bridge: engineStore) }
      XCTAssertEqual(try Data(contentsOf: config), committedBytes)
      XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBytes)
      let reverted = try await bridge.wallpaperOptionsSnapshot(wallpaperId: wallpaperID)
      XCTAssertEqual(reverted, initial)
      XCTAssertEqual(assets.stagedFiles(propertyId: "slides"), staged)
      XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(staged.first).stagedPath)), Data("original image".utf8))
      XCTAssertEqual(try context.managed.manifest(wallpaperId: wallpaperID).properties["slides"]?.sourcePath, oldSource.path)
      XCTAssertEqual(try context.managed.manifest(wallpaperId: wallpaperID).properties["slides"]?.originalSourceUnauthorized, true)
      XCTAssertNil(try context.managed.manifest(wallpaperId: wallpaperID).properties["slides"]?.authorizedSourcePath)
    }
  }

  func testRollbackFailureSurfacesBothErrorsWithoutClaimingCancellation() async throws {
    let context = try Context()
    defer { context.close() }
    let initial = options(properties: [property("first", .bool, .bool(value: false)), property("second", .bool, .bool(value: false))])
    let bridge = PresetTransactionBridge(noPointer: .init())
    let engineStore = BridgeStore(bridge: bridge)
    bridge.hostStore = engineStore
    try bridge.initialize(initial, config: context.root.appendingPathComponent("committed.json"))
    bridge.failedProperty = "second"
    bridge.refuseCancel = true
    let preset = WallpaperPropertyPreset(id: UUID().uuidString, wallpaperID: "wallpaper", name: "Both", properties: [
      .init(id: "first", kind: "bool", value: .bool(true), usesDefault: false),
      .init(id: "second", kind: "bool", value: .bool(true), usesDefault: false),
    ])
    do {
      try await context.store.apply(preset, options: initial, bridge: engineStore)
      XCTFail("A failed rollback cannot report a completed application")
    } catch let error as WallpaperPresetError {
      XCTAssertTrue(error.message.contains("setter-boundary"))
      XCTAssertTrue(error.message.contains("cancel-boundary"))
    }
    let pending = try await bridge.wallpaperOptionsSnapshot(wallpaperId: "wallpaper")
    XCTAssertTrue(pending.dirty)
    XCTAssertEqual(WallpaperPresetValue(pending.properties[0].value), .bool(true))
  }

  func testConditionalPresetEnablesItsTargetFieldsAndRollsBackAnUnreachableTarget() async throws {
    let context = try Context()
    let previousHome = ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_HOME"]
    setenv("WALLPAPER_MACHINE_HOME", context.root.path, 1)
    defer {
      if let previousHome { setenv("WALLPAPER_MACHINE_HOME", previousHome, 1) }
      else { unsetenv("WALLPAPER_MACHINE_HOME") }
      context.close()
    }
    let project = ClientPaths.libraryURL.appendingPathComponent("wallpaper")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try Data("{\"type\":\"web\",\"file\":\"index.html\"}".utf8).write(to: project.appendingPathComponent("project.json"))
    try Data("<!doctype html>".utf8).write(to: project.appendingPathComponent("index.html"))
    for reachable in [true, false] {
      var detail = property("detail", .textInput, .string(value: "before"))
      detail.enabled = false
      let initial = options(properties: [detail, property("mode", .bool, .bool(value: false))])
      let bridge = PresetTransactionBridge(noPointer: .init())
      let store = BridgeStore(bridge: bridge)
      bridge.hostStore = store
      bridge.enableDetailWithMode = reachable
      let config = context.root.appendingPathComponent("committed.json")
      try bridge.initialize(initial, config: config)
      let original = try Data(contentsOf: config)
      let preset = WallpaperPropertyPreset(id: UUID().uuidString, wallpaperID: "wallpaper", name: "Mode", properties: [
        .init(id: "detail", kind: "textInput", value: .string("after"), usesDefault: false),
        .init(id: "mode", kind: "bool", value: .bool(true), usesDefault: false),
      ])
      var followed: [String] = []
      store.onPropertyDraftChanged = { followed.append($0) }
      if reachable {
        try await context.store.apply(preset, options: initial, bridge: store)
        XCTAssertGreaterThanOrEqual(followed.count, 3, "each edit of the preset and its apply reach whatever follows the draft")
        XCTAssertEqual(Set(followed), ["wallpaper"])
        let committed = try await bridge.wallpaperOptionsSnapshot(wallpaperId: "wallpaper")
        XCTAssertEqual(WallpaperPresetValue(committed.properties[0].value), .string("after"))
        XCTAssertTrue(committed.properties[0].enabled)
        XCTAssertFalse(committed.dirty)
        XCTAssertNotEqual(try Data(contentsOf: config), original)
      } else {
        await assertFailure { try await context.store.apply(preset, options: initial, bridge: store) }
        let unchanged = try await bridge.wallpaperOptionsSnapshot(wallpaperId: "wallpaper")
        XCTAssertEqual(unchanged, initial)
        XCTAssertEqual(try Data(contentsOf: config), original)
      }
    }
  }

  private func assertFailure(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
    do { try await operation(); XCTFail("Expected the operation to fail", file: file, line: line) }
    catch {}
  }

  private func options(dirty: Bool = false, properties: [BridgePropertyDescriptor] = []) -> BridgeWallpaperOptionsSnapshot {
    BridgeSnapshotFixtures.options(dirty: dirty, properties: properties)
  }

  private func property(_ id: String, _ kind: BridgePropertyKind, _ value: BridgePropertyValue,
                        usesDefault: Bool = false) -> BridgePropertyDescriptor {
    BridgePropertyDescriptor(id: id, kind: kind, labelHtml: id, value: value, defaultValue: value,
      slider: nil, comboOptions: [], fileFilter: nil, directoryMode: nil, dirty: false,
      canRestoreDefaults: !usesDefault, enabled: true, assetManaged: false, assetMissing: false, assetSourcePath: nil)
  }

  @MainActor
  private struct Context {
    let root: URL
    let defaults: UserDefaults
    let managed: ManagedUserAssetStore
    let store: WallpaperPresetStore

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defaults = TemporaryDefaults.makeForCurrentTest().defaults
      managed = ManagedUserAssetStore(root: root.appendingPathComponent("UserAssets"))
      store = WallpaperPresetStore(defaults: defaults, managed: managed)
    }

    func reopen() -> WallpaperPresetStore { WallpaperPresetStore(defaults: defaults, managed: managed) }
    func close() {
      try? FileManager.default.removeItem(at: root)
    }
  }
}

private struct PresetTestArchive: Codable {
  var version = 1
  var items: [WallpaperPropertyPreset]
}

private final class PresetManualWatcher: DirectoryWatching {
  let url: URL
  private let callback: @MainActor () -> Void
  private(set) var isStopped = false
  init(url: URL, callback: @escaping @MainActor () -> Void) { self.url = url; self.callback = callback }
  @MainActor func fire() { if !isStopped { callback() } }
  func stop() { isStopped = true }
}

/// Stateful boundary with persisted committed values and real managed assets.
/// Its immediate path setter actually replaces/prunes served bytes, so tests
/// observe the committed file and page-readable bytes rather than call echoes.
private final class PresetTransactionBridge: WallpaperBridge {
  @MainActor weak var hostStore: BridgeStore?
  @MainActor var assets: UserAssetStore?
  @MainActor var failedProperty: String?
  @MainActor var refuseCancel = false
  @MainActor var enableDetailWithMode = false
  @MainActor private var committed: BridgeWallpaperOptionsSnapshot?
  @MainActor private var draft: BridgeWallpaperOptionsSnapshot?
  @MainActor private var config: URL?

  @MainActor func initialize(_ options: BridgeWallpaperOptionsSnapshot, config: URL) throws {
    self.committed = options
    self.draft = options
    self.config = config
    try persist(options)
  }

  override func wallpaperOptionsSnapshot(wallpaperId: String) async throws -> BridgeWallpaperOptionsSnapshot {
    try await current()
  }

  override func editProperty(wallpaperId: String, propertyId: String, value: BridgePropertyValue) async throws -> BridgeWallpaperMutationBundle {
    try await change(propertyId, value: value, immediate: false)
  }

  override func setPropertyPath(wallpaperId: String, propertyId: String, path: String?) async throws -> BridgeWallpaperMutationBundle {
    try await change(propertyId, value: .string(value: path ?? ""), immediate: true)
  }

  override func restorePropertyDefault(wallpaperId: String, propertyId: String) async throws -> BridgeWallpaperMutationBundle {
    try await restoreDefault(propertyId)
  }

  override func cancelWallpaperOptions(wallpaperId: String) async throws -> BridgeWallpaperMutationBundle {
    try await cancel()
  }

  override func applyWallpaperOptions(wallpaperId: String, userInitiated: Bool) async throws -> BridgeWallpaperMutationBundle {
    try await commit()
  }

  @MainActor private func commit() throws -> BridgeWallpaperMutationBundle {
    var current = try self.current()
    current.dirty = false
    for index in current.properties.indices { current.properties[index].dirty = false }
    committed = current
    draft = current
    try persist(current)
    return try reply(current)
  }

  @MainActor private func current() throws -> BridgeWallpaperOptionsSnapshot {
    try XCTUnwrap(draft)
  }

  @MainActor private func change(_ id: String, value: BridgePropertyValue, immediate: Bool) async throws -> BridgeWallpaperMutationBundle {
    if failedProperty == id { throw failure("setter-boundary") }
    var current = try self.current()
    let index = try XCTUnwrap(current.properties.firstIndex { $0.id == id })
    guard current.properties[index].enabled else { throw failure("disabled-property") }
    current.properties[index].value = value
    if enableDetailWithMode, id == "mode", case .bool(let enabled) = value,
       let dependent = current.properties.firstIndex(where: { $0.id == "detail" }) {
      current.properties[dependent].enabled = enabled
    }
    if immediate {
      var applied = try XCTUnwrap(committed)
      applied.properties[index].value = value
      committed = applied
      try persist(applied)
      if case .string(let path) = value, !path.isEmpty {
        _ = try await assets?.importDirectory(at: URL(fileURLWithPath: path), propertyId: id, filter: .image, limit: 4096)
      }
    }
    current.dirty = current.properties != committed?.properties
    draft = current
    return try reply(current)
  }

  @MainActor private func restoreDefault(_ id: String) async throws -> BridgeWallpaperMutationBundle {
    let current = try self.current()
    return try await change(id, value: try XCTUnwrap(current.properties.first { $0.id == id }).defaultValue, immediate: false)
  }

  @MainActor private func cancel() throws -> BridgeWallpaperMutationBundle {
    if refuseCancel { throw failure("cancel-boundary") }
    draft = committed
    return try reply(current())
  }

  @MainActor private func persist(_ options: BridgeWallpaperOptionsSnapshot) throws {
    let values = Dictionary(uniqueKeysWithValues: options.properties.map { ($0.id, WallpaperPresetValue($0.value)) })
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(values).write(to: XCTUnwrap(config), options: .atomic)
  }

  @MainActor private func reply(_ options: BridgeWallpaperOptionsSnapshot) throws -> BridgeWallpaperMutationBundle {
    let store = try XCTUnwrap(hostStore)
    return BridgeWallpaperMutationBundle(app: store.appSnapshot, library: store.librarySnapshot, wallpaperOptions: options,
      monitorInformation: store.monitorInformationSnapshot, settings: store.settingsSnapshot)
  }

  private func failure(_ message: String) -> NSError {
    NSError(domain: "PresetTransactionTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
