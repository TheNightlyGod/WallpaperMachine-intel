import XCTest

@testable import WallpaperMachine

/// A refusal a bridge double throws.
struct InspectorTestRefusal: Error {}

/// The panel's controller over a store whose bridge keeps each wallpaper's pending state the way the
/// engine does and records the order of what it was asked: one scene, one video and one web page
/// installed, each with a switch, a text field, a slider, a colour, a picture and a disabled slider.
@MainActor
final class PanelPropertyContext {
  let panel: PanelFixture
  let bridge: InspectorPreviewBridge
  let sleeper = ManualSleeper()
  /// What the store sent to its log about the desktop previews.
  var log: [String] = []

  var store: BridgeStore { panel.store }
  var controller: PanelController { panel.controller }
  var defaults: UserDefaults { panel.defaults }

  /// Wallpapers `wp`, `wp2` and `wp3` are scenes, `web` a web page and `clip` a video.
  nonisolated static let kinds: [(String, BridgeWallpaperKind)] = [
    ("wp", .projectScene), ("wp2", .projectScene), ("wp3", .projectScene), ("web", .webpage),
    ("clip", .video),
  ]

  init() throws {
    let bridge = InspectorPreviewBridge(noPointer: .init())
    let store = BridgeStore(bridge: bridge)
    bridge.store = store
    self.bridge = bridge
    panel = try PanelFixture(store: store, bridge: bridge, displayTitles: .renderer)
    // Applying validates the wallpaper's files; a web page is the cheapest project that passes.
    // The kind the options report is what decides whether the desktop can show an edit.
    for (id, kind) in Self.kinds {
      let project = panel.library.appendingPathComponent(id)
      try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
      try Data(#"{"type":"web","file":"index.html"}"#.utf8).write(
        to: project.appendingPathComponent("project.json"))
      try Data("<!doctype html>".utf8).write(to: project.appendingPathComponent("index.html"))
      bridge.options[id] = BridgeSnapshotFixtures.options(
        wallpaperId: id, title: id, kind: kind, properties: Self.properties)
    }
    store.librarySnapshot.wallpapers = Self.kinds.map {
      BridgeWallpaperEntry(
        id: $0.0, title: $0.0, kind: $0.1, supported: true, active: false, selected: false,
        previewPath: nil)
    }
    store.appSnapshot.selectedWallpaperId = "wp"
    store.wallpaperOptionsSnapshot = bridge.options["wp"]
    let defaults = panel.defaults
    store.showsPropertyEditsOnDesktop = { LivePropertyEditing.isEnabled(defaults: defaults) }
    store.desktopPropertyPreviews = PropertyPreviewScheduler(
      delay: .milliseconds(150), sleep: sleeper.closure)
    store.desktopPropertyPreviewLog = { [unowned self] in log.append($0) }
  }

  nonisolated static var properties: [BridgePropertyDescriptor] {
    [
      property("mode", .bool, .bool(value: false)),
      property("note", .textInput, .string(value: "")),
      property(
        "alpha", .slider, .number(value: 1),
        slider: .init(min: 0, max: 1, step: 0.01, precision: 2)),
      property("tint", .color, .colorRgb(red: 1, green: 1, blue: 1)),
      property("picture", .texture, .string(value: "")),
      property(
        "locked", .slider, .number(value: 0),
        slider: .init(min: 0, max: 1, step: 0.01, precision: 2), enabled: false),
    ]
  }

  nonisolated static func property(
    _ id: String, _ kind: BridgePropertyKind, _ value: BridgePropertyValue,
    slider: BridgeSliderMetadata? = nil, enabled: Bool = true, dirty: Bool = false,
    defaultValue: BridgePropertyValue? = nil, label: String? = nil
  ) -> BridgePropertyDescriptor {
    BridgePropertyDescriptor(
      id: id, kind: kind, labelHtml: label ?? id, value: value, defaultValue: defaultValue ?? value,
      slider: slider, comboOptions: [], fileFilter: nil, directoryMode: nil, dirty: dirty,
      canRestoreDefaults: true, enabled: enabled, assetManaged: false, assetMissing: false,
      assetSourcePath: nil)
  }

  func shutdown() async {
    store.desktopPropertyPreviews.cancelAll()
    await panel.shutdown()
  }

  /// Runs `body` over a fresh context and always shuts it down.
  static func with(_ body: (PanelPropertyContext) async throws -> Void) async throws {
    let context = try PanelPropertyContext()
    do { try await body(context) } catch {
      await context.shutdown()
      throw error
    }
    await context.shutdown()
  }

  // MARK: Doing what the inspector does

  /// A step of a slider or colour being dragged.
  func drag(_ property: String, _ value: PropertyDragValue, id: String = "wp") async throws {
    try await controller.previewProperty(id, property: property, value: value.bridgeValue)
  }

  /// The switch property is flipped.
  func edit(_ value: Bool, id: String = "wp") async throws {
    try await controller.commitProperty(id, property: "mode", value: .bool(value: value))
  }

  func switchOn() {
    LivePropertyEditing.setEnabled(true, defaults: defaults, center: NotificationCenter())
  }

  /// What turning the Settings switch off does: put the saved look back on what the displays were
  /// shown, leaving the edits pending.
  func switchOff() async {
    LivePropertyEditing.setEnabled(false, defaults: defaults, center: NotificationCenter())
    await store.stopShowingPropertyEditsOnDesktopAsync()
  }

  /// Displays 1 and 2 show "wp" (2 mirrors 1), display 3 shows "wp2" and display 4 shows nothing.
  func showWallpapersOnDisplays() {
    func row(_ id: String, _ title: String, _ wallpaper: String, mirroring target: String? = nil)
      -> BridgeMonitorInfoRow
    {
      BridgeMonitorInfoRow(
        displayId: id, title: title, wallpaperId: wallpaper, wallpaperTitle: wallpaper,
        mirrorTargetDisplayId: target, mirrorTargetTitle: nil, scalingMode: "fill",
        targetFps: "30", audioResponse: false)
    }
    store.monitorInformationSnapshot = BridgeMonitorInformationSnapshot(rows: [
      row("1", "Left (1 - Primary)", "wp"),
      row("2", "Right (2 - Mirror)", "wp", mirroring: "1"),
      row("3", "Other (3 - Secondary)", "wp2"),
      row("4", "Empty (4 - Secondary)", ""),
    ])
  }

  /// The displays of `showWallpapersOnDisplays` that currently draw a pending edit.
  func displaysShowingEdits() -> [String] {
    ["1", "2", "3", "4"].filter { store.isShowingPropertyEdits(onDisplay: $0) }
  }

  func settle() async { for _ in 0..<60 { await Task.yield() } }

  /// Lets the quiet period pass, once for every time an edit started it over.
  func letTheEditsPause() async {
    for _ in 0..<8 {
      await settle()
      if sleeper.finishWaits() == 0 { break }
    }
    await settle()
  }
}

/// Answers a wallpaper's options as the engine would after each call and records, in order, what the
/// panel and the store asked of the displays and of the draft.
final class InspectorPreviewBridge: LayoutSnapshotBridge {
  struct Preview: Hashable {
    var wallpaperID: String
    var show: Bool
    /// The values being dragged that the displays were told to show on top of the draft.
    var pending: [BridgePropertyEdit] = []
    /// The Wallpaper Engine option values being dragged, likewise.
    var pendingEngineOptions: [BridgeEngineOptionEdit] = []
  }

  @MainActor weak var store: BridgeStore?
  /// What the displays were asked to show, in order.
  @MainActor var previews: [Preview] = []
  /// Edits, reverts and applies the bridge received, in order, as "edit wp".
  @MainActor var events: [String] = []
  /// The values of every edit the draft took, in order.
  @MainActor var edits: [BridgePropertyEdit] = []
  @MainActor var previewFailure: Error?
  /// What the next edit fails with, when a test needs the bridge to refuse it.
  @MainActor var editFailure: Error?
  /// While set, an apply is received but not answered until `releaseApply()`, which is how a test
  /// holds a wallpaper in the middle of being applied.
  @MainActor var holdApply = false
  @MainActor private var heldApplies: [CheckedContinuation<Void, Never>] = []
  /// Paths the draft was given, and the properties restored, in order.
  @MainActor var paths: [(wallpaperId: String, propertyId: String, path: String?)] = []
  @MainActor var restored: [String] = []
  /// What the engine reports after an edit, when a test needs it to differ from taking the value.
  @MainActor var editAnswer: (@MainActor (BridgeWallpaperOptionsSnapshot) -> BridgeWallpaperOptionsSnapshot)?
  /// What the engine reports once every default is staged.
  @MainActor var restoreAllAnswer: BridgeWallpaperOptionsSnapshot?

  @MainActor func releaseApply() {
    holdApply = false
    let held = heldApplies
    heldApplies = []
    for continuation in held { continuation.resume() }
  }

  override func wallpaperOptionsSnapshot(wallpaperId: String) async throws
    -> BridgeWallpaperOptionsSnapshot
  {
    try await current(wallpaperId)
  }

  override func editProperty(wallpaperId: String, propertyId: String, value: BridgePropertyValue)
    async throws -> BridgeWallpaperMutationBundle
  {
    try await edit(wallpaperId, BridgePropertyEdit(propertyId: propertyId, value: value))
  }

  @MainActor private func edit(_ id: String, _ edit: BridgePropertyEdit) throws
    -> BridgeWallpaperMutationBundle
  {
    if let editFailure { throw editFailure }
    edits.append(edit)
    var changed = try current(id)
    changed.properties = changed.properties.map { property in
      var property = property
      if property.id == edit.propertyId { property.value = edit.value; property.dirty = true }
      return property
    }
    if let editAnswer { changed = editAnswer(changed) }
    return try reply("edit", id, changed: changed, dirty: true)
  }

  override func setPropertyPath(wallpaperId: String, propertyId: String, path: String?)
    async throws -> BridgeWallpaperMutationBundle
  {
    try await recordPath(wallpaperId, propertyId, path)
  }

  @MainActor private func recordPath(_ id: String, _ property: String, _ path: String?) throws
    -> BridgeWallpaperMutationBundle
  {
    paths.append((id, property, path))
    return try reply("path", id, dirty: true)
  }

  override func restorePropertyDefault(wallpaperId: String, propertyId: String) async throws
    -> BridgeWallpaperMutationBundle
  {
    try await restore(wallpaperId, propertyId)
  }

  @MainActor private func restore(_ id: String, _ property: String) throws
    -> BridgeWallpaperMutationBundle
  {
    restored.append(property)
    return try reply("restore", id, dirty: true)
  }

  override func restoreAllPropertyDefaults(wallpaperId: String) async throws
    -> BridgeWallpaperMutationBundle
  {
    try await restoreEverything(wallpaperId)
  }

  @MainActor private func restoreEverything(_ id: String) throws -> BridgeWallpaperMutationBundle {
    restored.append("*")
    return try reply("restoreAll", id, changed: try restoreAllAnswer ?? current(id), dirty: true)
  }

  override func cancelWallpaperOptions(wallpaperId: String) async throws
    -> BridgeWallpaperMutationBundle
  {
    try await reply("cancel", wallpaperId, dirty: false)
  }

  override func applyWallpaperOptions(wallpaperId: String, userInitiated: Bool) async throws
    -> BridgeWallpaperMutationBundle
  {
    await holdIfAsked()
    return try await reply("apply", wallpaperId, dirty: false)
  }

  @MainActor private func holdIfAsked() async {
    if holdApply { await withCheckedContinuation { heldApplies.append($0) } }
  }

  override func previewWallpaperProperties(
    wallpaperId: String, show: Bool, pending: [BridgePropertyEdit],
    pendingEngineOptions: [BridgeEngineOptionEdit]
  ) async throws {
    try await receivePreview(
      Preview(
        wallpaperID: wallpaperId, show: show, pending: pending,
        pendingEngineOptions: pendingEngineOptions))
  }

  /// The Wallpaper Engine option edits the draft took, in order; `restore <option>` and
  /// `restoreAll` for the restores.
  @MainActor var engineEdits: [String] = []

  override func editEngineOption(
    wallpaperId: String, option: BridgeEngineOptionId, value: BridgePropertyValue
  ) async throws -> BridgeWallpaperMutationBundle {
    try await editEngine(wallpaperId, option, value)
  }

  @MainActor private func editEngine(
    _ id: String, _ option: BridgeEngineOptionId, _ value: BridgePropertyValue
  ) throws -> BridgeWallpaperMutationBundle {
    if let editFailure { throw editFailure }
    engineEdits.append("\(option) \(value)")
    return try reply("edit", id, changed: try changingEngineOption(id, option, to: value), dirty: true)
  }

  override func restoreEngineOptionDefault(wallpaperId: String, option: BridgeEngineOptionId)
    async throws -> BridgeWallpaperMutationBundle
  {
    try await restoreEngine(wallpaperId, option)
  }

  @MainActor private func restoreEngine(_ id: String, _ option: BridgeEngineOptionId) throws
    -> BridgeWallpaperMutationBundle
  {
    engineEdits.append("restore \(option)")
    let options = try current(id)
    let defaultValue = options.engineOptions?.rows.first { $0.id == option }?.defaultValue ?? .empty
    return try reply("restore", id, changed: try changingEngineOption(id, option, to: defaultValue), dirty: true)
  }

  override func restoreAllEngineOptionDefaults(wallpaperId: String) async throws
    -> BridgeWallpaperMutationBundle
  {
    try await restoreAllEngine(wallpaperId)
  }

  @MainActor private func restoreAllEngine(_ id: String) throws -> BridgeWallpaperMutationBundle {
    engineEdits.append("restoreAll")
    var changed = try current(id)
    changed.engineOptions = changed.engineOptions.map {
      BridgeSnapshotFixtures.engineOptions(
        parallax: $0.rows.contains { $0.id == .mouseParallax }, imageFilters: $0.imageFilters)
    }
    return try reply("restoreAll", id, changed: changed, dirty: true)
  }

  /// The options of `id` with `option` at `value`, rows enabled as the bridge enables them.
  @MainActor private func changingEngineOption(
    _ id: String, _ option: BridgeEngineOptionId, to value: BridgePropertyValue
  ) throws -> BridgeWallpaperOptionsSnapshot {
    var changed = try current(id)
    guard let engine = changed.engineOptions else { return changed }
    var values = Dictionary(uniqueKeysWithValues: engine.rows.map { ($0.id, $0.value) })
    values[option] = value
    changed.engineOptions = BridgeSnapshotFixtures.engineOptions(
      parallax: engine.rows.contains { $0.id == .mouseParallax }, imageFilters: engine.imageFilters,
      values: values)
    return changed
  }

  override func refreshLibrary() async throws -> BridgeSnapshotBundle {
    try await library()
  }

  @MainActor private func current(_ id: String) throws -> BridgeWallpaperOptionsSnapshot {
    guard let options = options[id] else { throw CancellationError() }
    return options
  }

  @MainActor private func receivePreview(_ preview: Preview) throws {
    previews.append(preview)
    if let previewFailure { throw previewFailure }
  }

  @MainActor private func reply(_ event: String, _ id: String, dirty: Bool) throws
    -> BridgeWallpaperMutationBundle
  {
    try reply(event, id, changed: try current(id), dirty: dirty)
  }

  /// The engine's reply to a call that changes the draft: the wallpaper's options afterwards. Only a
  /// call that edits is recorded under its name; the others do not matter to a test.
  @MainActor private func reply(
    _ event: String, _ id: String, changed: BridgeWallpaperOptionsSnapshot, dirty: Bool
  ) throws -> BridgeWallpaperMutationBundle {
    if ["edit", "cancel", "apply"].contains(event) { events.append("\(event) \(id)") }
    var changed = changed
    changed.dirty = dirty
    options[id] = changed
    let store = try XCTUnwrap(store)
    return BridgeWallpaperMutationBundle(
      app: store.appSnapshot, library: store.librarySnapshot, wallpaperOptions: changed,
      monitorInformation: store.monitorInformationSnapshot, settings: store.settingsSnapshot)
  }

  @MainActor private func library() throws -> BridgeSnapshotBundle {
    let store = try XCTUnwrap(store)
    return BridgeSnapshotBundle(
      app: store.appSnapshot, library: store.librarySnapshot, wallpaperOptions: nil,
      monitorInformation: store.monitorInformationSnapshot, settings: store.settingsSnapshot)
  }
}

extension XCTestCase {
  /// Asserts that `work` is refused as a control sending a value it never offers.
  @MainActor
  func assertInspectorInvalidValue(
    _ what: String, file: StaticString = #filePath, line: UInt = #line,
    _ work: () async throws -> Void
  ) async {
    do {
      try await work()
      XCTFail("Accepted \(what)", file: file, line: line)
    } catch is InvalidControlValue {
    } catch {
      XCTFail("Refused \(what) with \(error)", file: file, line: line)
    }
  }
}
