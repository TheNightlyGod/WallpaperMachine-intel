import Foundation
import XCTest

@testable import WallpaperMachine

final class LockScreenWallpaperTests: XCTestCase {
  private var root: URL!
  private var store: URL { root.appendingPathComponent("Index.plist") }
  private var journal: URL { root.appendingPathComponent("journal.plist") }

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "lock-wallpaper-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

  private func choice(_ name: String) -> [String: Any] {
    [
      "Content": [
        "Choices": [["Provider": name, "Configuration": Data(name.utf8), "Files": [String]()]],
        "Shuffle": "$null",
      ], "LastSet": Date(timeIntervalSince1970: 1),
    ]
  }
  private func node(_ name: String) -> [String: Any] {
    [
      "Desktop": choice(name + "-desktop"), "Idle": choice(name + "-idle"), "Type": "individual",
      "Unrelated": name,
    ]
  }
  private func fixture() -> [String: Any] {
    [
      "SystemDefault": node("system"),
      "Displays": ["one": node("display-one"), "two": node("display-two")],
      "Spaces": [
        "space-a": [
          "Default": node("default-a"),
          "Displays": ["one": node("space-one"), "two": node("space-two")],
        ]
      ],
      "Unrelated": "keep",
    ]
  }
  private func write(_ value: [String: Any]) throws {
    try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0).write(
      to: store, options: .atomic)
  }
  private func readStore() throws -> [String: Any] {
    try XCTUnwrap(
      PropertyListSerialization.propertyList(from: Data(contentsOf: store), format: nil)
        as? [String: Any])
  }
  private func provider(_ node: [String: Any], key: String) -> String? {
    let content = (node[key] as? [String: Any])?["Content"] as? [String: Any]
    return (content?["Choices"] as? [[String: Any]])?.first?["Provider"] as? String
  }

  @MainActor
  private func assertDiskRecovery(restores original: [String: Any]) throws {
    let copy = root.appendingPathComponent("recovery-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
    let copiedStore = copy.appendingPathComponent("Index.plist")
    let copiedJournal = copy.appendingPathComponent("journal.plist")
    try FileManager.default.copyItem(at: store, to: copiedStore)
    try FileManager.default.copyItem(at: journal, to: copiedJournal)
    let recovered = LockScreenWallpaperSelection(
      storeURL: copiedStore, journalURL: copiedJournal, reload: {})
    try recovered.recover()
    let restored = try XCTUnwrap(
      PropertyListSerialization.propertyList(from: Data(contentsOf: copiedStore), format: nil)
        as? [String: Any])
    XCTAssertEqual(restored as NSDictionary, original as NSDictionary)
    XCTAssertFalse(FileManager.default.fileExists(atPath: copiedJournal.path))
  }

  @MainActor
  func testNativeSelectionTargetsOnlyOwnedDisplaysAndRestoresIndependentOriginals() throws {
    let original = fixture()
    try write(original)
    let selection = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
    try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: ["one"])
    let selected = try readStore()
    let displays = try XCTUnwrap(selected["Displays"] as? [String: [String: Any]])
    XCTAssertEqual(
      provider(try XCTUnwrap(displays["one"]), key: "Desktop"),
      LockScreenConfiguration.extensionIdentifier)
    XCTAssertEqual(
      provider(try XCTUnwrap(displays["one"]), key: "Idle"),
      LockScreenConfiguration.extensionIdentifier)
    XCTAssertEqual(
      displays["two"] as NSDictionary?,
      (original["Displays"] as? [String: Any])?["two"] as? NSDictionary)
    XCTAssertEqual(
      selected["AllSpacesAndDisplays"] as? NSDictionary,
      original["AllSpacesAndDisplays"] as? NSDictionary)
    try selection.synchronize(desktopDisplays: [], screenSaverDisplays: [])
    XCTAssertEqual(try readStore() as NSDictionary, original as NSDictionary)
    XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
  }

  @MainActor
  func testWallpaperRevisionInvalidatesEverySpaceAndKeepsRestorationOriginals() throws {
    var original = fixture()
    var spaces = try XCTUnwrap(original["Spaces"] as? [String: Any])
    spaces["space-b"] = ["Default": node("default-b"), "Displays": ["one": node("other-space")]]
    original["Spaces"] = spaces
    try write(original)
    var reloads = 0
    let selection = LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal, reload: { reloads += 1 })
    try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: ["one"], revision: "wallpaper-a")
    let first = try readStore()
    try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: ["one"], revision: "wallpaper-b")
    let second = try readStore()
    func configurations(_ root: [String: Any]) throws -> [Data] {
      let displays = try XCTUnwrap(root["Displays"] as? [String: [String: Any]])
      let spaces = try XCTUnwrap(root["Spaces"] as? [String: [String: Any]])
      var nodes = [try XCTUnwrap(displays["one"])]
      for key in spaces.keys.sorted() {
        let perDisplay = try XCTUnwrap(spaces[key]?["Displays"] as? [String: [String: Any]])
        nodes.append(try XCTUnwrap(perDisplay["one"]))
      }
      return try nodes.flatMap { node in
        try ["Desktop", "Idle"].map { key in
          let value = try XCTUnwrap(node[key] as? [String: Any])
          let content = try XCTUnwrap(value["Content"] as? [String: Any])
          let choices = try XCTUnwrap(content["Choices"] as? [[String: Any]])
          return try XCTUnwrap(choices.first?["Configuration"] as? Data)
        }
      }
    }
    let before = try configurations(first)
    let after = try configurations(second)
    for (old, new) in zip(before, after) { XCTAssertNotEqual(old, new) }
    XCTAssertEqual(reloads, 2)
    try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: ["one"], revision: "wallpaper-b")
    XCTAssertEqual(reloads, 2, "Unchanged publication must not reload WallpaperAgent")
    XCTAssertEqual(try readStore() as NSDictionary, second as NSDictionary)
    let recovered = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
    try recovered.recover()
    XCTAssertEqual(try readStore() as NSDictionary, original as NSDictionary)
  }

  @MainActor
  func testExternalDesktopEditSurvivesWhileOwnedIdleSelectionRestores() throws {
    try write(fixture())
    let selection = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
    try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: ["one"])
    var external = try readStore()
    var displays = try XCTUnwrap(external["Displays"] as? [String: [String: Any]])
    displays["one"]?["Desktop"] = choice("user-selected")
    displays["one"]?["Unrelated"] = "new-user-value"
    external["Displays"] = displays
    try write(external)
    XCTAssertThrowsError(try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: ["one"]))
    try selection.synchronize(desktopDisplays: [], screenSaverDisplays: [])
    let restored = try XCTUnwrap((try readStore()["Displays"] as? [String: [String: Any]])?["one"])
    XCTAssertEqual(provider(restored, key: "Desktop"), "user-selected")
    XCTAssertEqual(provider(restored, key: "Idle"), "display-one-idle")
    XCTAssertEqual(restored["Unrelated"] as? String, "new-user-value")
  }

  @MainActor
  func testReloadFailureLeavesRecoverableJournalInsteadOfLosingOriginals() throws {
    let original = fixture()
    try write(original)
    let failing = LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal, reload: { throw CocoaError(.executableRuntimeMismatch) }
    )
    XCTAssertThrowsError(try failing.synchronize(desktopDisplays: ["one"], screenSaverDisplays: ["one"]))
    XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
    let recovered = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
    try recovered.recover()
    XCTAssertEqual(try readStore() as NSDictionary, original as NSDictionary)
    XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
  }

  @MainActor
  func testNewSpaceInheritedSelectionIsRemovedRatherThanInventingAnOriginal() throws {
    var original = fixture()
    original["Spaces"] = ["space-a": ["Default": node("default-a"), "Displays": [String: Any]()]]
    try write(original)
    let selection = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
    try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: ["one"])
    try selection.synchronize(desktopDisplays: [], screenSaverDisplays: [])
    XCTAssertEqual(try readStore() as NSDictionary, original as NSDictionary)
  }
  @MainActor
  func testInheritedDisplayChoicesRemainCompleteWithEitherModeEnabled() throws {
    for linked in [false, true] {
      for missingDisplay in [false, true] {
        for saver in [false, true] {
          let baseline = linked ? linkedDefault() : node("inherited")
          let original: [String: Any] = [
            "SystemDefault": baseline,
            "Displays": missingDisplay ? [:] : ["one": baseline],
            "Spaces": ["space-a": ["Default": baseline, "Displays": [String: Any]()]],
          ]
          try write(original)
          let selection = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
          func assertComplete(desktop: Bool, idle: Bool) throws {
            let selected = try readStore()
            let space = try XCTUnwrap((selected["Spaces"] as? [String: [String: Any]])?["space-a"])
            for container in [selected, space] {
              let display = try XCTUnwrap((container["Displays"] as? [String: [String: Any]])?["one"])
              XCTAssertEqual(display["Type"] as? String, "individual")
              for (key, enabled) in [("Desktop", desktop), ("Idle", idle)] {
                // WallpaperAgent rejects the entire Index when either required
                // field is absent, even for an inactive Space.
                XCTAssertNotNil(display[key] as? [String: Any])
                XCTAssertEqual(provider(display, key: key), enabled
                  ? LockScreenConfiguration.extensionIdentifier
                  : linked ? "default" : "inherited-" + key.lowercased())
              }
            }
          }
          try selection.synchronize(
            desktopDisplays: saver ? [] : ["one"], screenSaverDisplays: saver ? ["one"] : [])
          try assertComplete(desktop: !saver, idle: saver)
          try assertDiskRecovery(restores: original)
          try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: ["one"])
          try assertComplete(desktop: true, idle: true)
          try selection.synchronize(
            desktopDisplays: saver ? ["one"] : [], screenSaverDisplays: saver ? [] : ["one"])
          try assertComplete(desktop: saver, idle: !saver)
          try assertDiskRecovery(restores: original)
          try selection.synchronize(desktopDisplays: [], screenSaverDisplays: [])
          XCTAssertEqual(try readStore() as NSDictionary, original as NSDictionary)
        }
      }
    }
  }

  @MainActor
  func testExternalChoiceOnSynthesizedSpaceSurvivesRecovery() throws {
    for saver in [false, true] {
      var original = fixture()
      original["Spaces"] = ["space-a": ["Default": node("default-a"), "Displays": [String: Any]()]]
      try write(original)
      let selection = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
      try selection.synchronize(
        desktopDisplays: saver ? [] : ["one"], screenSaverDisplays: saver ? ["one"] : [])
      var external = try readStore()
      var spaces = try XCTUnwrap(external["Spaces"] as? [String: [String: Any]])
      var displays = try XCTUnwrap(spaces["space-a"]?["Displays"] as? [String: [String: Any]])
      let untouched = saver ? "Desktop" : "Idle"
      displays["one"]?[untouched] = choice("user-choice")
      spaces["space-a"]?["Displays"] = displays
      external["Spaces"] = spaces
      try write(external)
      let recovered = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
      try recovered.recover()
      let space = try XCTUnwrap((try readStore()["Spaces"] as? [String: [String: Any]])?["space-a"])
      let restored = try XCTUnwrap((space["Displays"] as? [String: [String: Any]])?["one"])
      XCTAssertEqual(provider(restored, key: untouched), "user-choice")
      XCTAssertEqual(provider(restored, key: saver ? "Idle" : "Desktop"),
        saver ? "display-one-idle" : "display-one-desktop")
    }
  }

  @MainActor
  func testInheritedChoicesStayRecoverableIfReloadFails() throws {
    for saver in [false, true] {
      var original = fixture()
      original["Spaces"] = ["space-a": ["Default": node("default-a"), "Displays": [String: Any]()]]
      try write(original)
      let selection = LockScreenWallpaperSelection(
        storeURL: store, journalURL: journal, reload: { throw CocoaError(.executableRuntimeMismatch) })
      XCTAssertThrowsError(try selection.synchronize(
        desktopDisplays: saver ? [] : ["one"], screenSaverDisplays: saver ? ["one"] : []))
      try assertDiskRecovery(restores: original)
    }
  }

  @MainActor
  func testSystemCopiedFallbackIsRestoredWithoutOverwritingOtherAppGlobalChoice() throws {
    let original = fixture()
    try write(original)
    let selection = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
    try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: ["one"])
    var systemChanged = try readStore()
    let owned = try XCTUnwrap((systemChanged["Displays"] as? [String: [String: Any]])?["one"])
    var copied = try XCTUnwrap(systemChanged["SystemDefault"] as? [String: Any])
    copied["Desktop"] = owned["Desktop"]
    copied["Idle"] = owned["Idle"]
    systemChanged["SystemDefault"] = copied
    systemChanged["AllSpacesAndDisplays"] = ["Linked": choice("another-app"), "Type": "linked"]
    try write(systemChanged)
    try selection.synchronize(desktopDisplays: [], screenSaverDisplays: [])
    let restored = try readStore()
    XCTAssertEqual(
      restored["SystemDefault"] as? NSDictionary, original["SystemDefault"] as? NSDictionary)
    XCTAssertEqual(
      restored["AllSpacesAndDisplays"] as? NSDictionary,
      systemChanged["AllSpacesAndDisplays"] as? NSDictionary)
  }

  @MainActor
  func testConflictingGlobalLinkedWallpaperIsRejectedWithoutChangingStore() throws {
    var original = fixture()
    original["AllSpacesAndDisplays"] = ["Linked": choice("another-app"), "Type": "linked"]
    try write(original)
    let selection = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
    XCTAssertThrowsError(try selection.checkCompatibility())
    XCTAssertEqual(try readStore() as NSDictionary, original as NSDictionary)
    XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
  }

  private func linkedDefault() -> [String: Any] {
    ["Type": "linked", "Linked": choice("default"), "Unrelated": "keep"]
  }

  @MainActor
  func testDefaultLinkedWallpaperSupportsIndependentModesAndExactRecovery() throws {
    for populated in [false, true] {
      for firstSaver in [false, true] {
        for remainingSaver in [false, true] {
          let linked = linkedDefault()
          let original: [String: Any] = [
            "AllSpacesAndDisplays": linked, "SystemDefault": linked,
            "Displays": populated ? ["one": linked, "two": linked] : [:],
            "Spaces": populated ? ["space-a": ["Default": linked, "Displays": ["one": linked]]] : [:],
          ]
          try write(original)
          var reloads = 0
          let selection = LockScreenWallpaperSelection(
            storeURL: store, journalURL: journal, reload: { reloads += 1 })
          try selection.checkCompatibility()
          try selection.synchronize(
            desktopDisplays: firstSaver ? [] : ["one"], screenSaverDisplays: firstSaver ? ["one"] : [])
          var selected = try readStore()
          var display = try XCTUnwrap((selected["Displays"] as? [String: [String: Any]])?["one"])
          XCTAssertEqual(provider(display, key: firstSaver ? "Idle" : "Desktop"),
            LockScreenConfiguration.extensionIdentifier)
          XCTAssertEqual(provider(display, key: firstSaver ? "Desktop" : "Idle"), "default")
          let global = try XCTUnwrap(selected["AllSpacesAndDisplays"] as? [String: Any])
          XCTAssertEqual(global["Type"] as? String, firstSaver ? "desktop" : "idle")
          XCTAssertNil(global[firstSaver ? "Idle" : "Desktop"])
          XCTAssertEqual(provider(global, key: firstSaver ? "Desktop" : "Idle"), "default")
          try assertDiskRecovery(restores: original)
          try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: ["one"])
          XCTAssertNil(try readStore()["AllSpacesAndDisplays"])
          try assertDiskRecovery(restores: original)
          try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: ["one"])
          XCTAssertEqual(reloads, 2, "An unchanged selection must not reload the system service")
          try selection.synchronize(
            desktopDisplays: remainingSaver ? [] : ["one"],
            screenSaverDisplays: remainingSaver ? ["one"] : [])
          selected = try readStore()
          display = try XCTUnwrap((selected["Displays"] as? [String: [String: Any]])?["one"])
          XCTAssertEqual(provider(display, key: remainingSaver ? "Idle" : "Desktop"),
            LockScreenConfiguration.extensionIdentifier)
          XCTAssertEqual(provider(display, key: remainingSaver ? "Desktop" : "Idle"), "default")
          try assertDiskRecovery(restores: original)
          try selection.synchronize(desktopDisplays: [], screenSaverDisplays: [])
          XCTAssertEqual(try readStore() as NSDictionary, original as NSDictionary)
        }
      }
    }
  }

  @MainActor
  func testLinkedDefaultPreservesExternalChangesToUnownedChoices() throws {
    for saver in [false, true] {
      for enableBoth in [false, true] {
        let linked = linkedDefault()
        let original: [String: Any] = [
          "AllSpacesAndDisplays": linked, "SystemDefault": linked,
          "Displays": ["one": linked], "Spaces": [String: Any](),
        ]
        try write(original)
        let selection = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
        try selection.synchronize(
          desktopDisplays: saver ? [] : ["one"], screenSaverDisplays: saver ? ["one"] : [])
        let untouched = saver ? "Desktop" : "Idle"
        var external = try readStore()
        var global = try XCTUnwrap(external["AllSpacesAndDisplays"] as? [String: Any])
        global[untouched] = choice("user-global")
        global["Unrelated"] = "new-global-metadata"
        external["AllSpacesAndDisplays"] = global
        var displays = try XCTUnwrap(external["Displays"] as? [String: [String: Any]])
        displays["one"]?[untouched] = choice("user-display")
        displays["one"]?["Unrelated"] = "new-display-metadata"
        external["Displays"] = displays
        try write(external)
        if enableBoth {
          try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: ["one"])
        }
        try selection.synchronize(desktopDisplays: [], screenSaverDisplays: [])
        let restored = try readStore()
        let restoredGlobal = try XCTUnwrap(restored["AllSpacesAndDisplays"] as? [String: Any])
        let restoredDisplay = try XCTUnwrap((restored["Displays"] as? [String: [String: Any]])?["one"])
        XCTAssertEqual(provider(restoredGlobal, key: untouched), "user-global")
        XCTAssertEqual(provider(restoredDisplay, key: untouched), "user-display")
        XCTAssertEqual(provider(restoredGlobal, key: saver ? "Idle" : "Desktop"), "default")
        XCTAssertEqual(provider(restoredDisplay, key: saver ? "Idle" : "Desktop"), "default")
        XCTAssertEqual(restoredGlobal["Unrelated"] as? String, "new-global-metadata")
        XCTAssertEqual(restoredDisplay["Unrelated"] as? String, "new-display-metadata")
      }
    }
  }

  @MainActor
  func testExternalGlobalLinkedChoiceSurvivesDisablingBothModes() throws {
    for name in ["default", "another-app"] {
      let linked = linkedDefault()
      try write([
        "AllSpacesAndDisplays": linked, "SystemDefault": linked,
        "Displays": ["one": linked], "Spaces": [String: Any](),
      ])
      let selection = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
      try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: ["one"])
      var external = try readStore()
      let replacement: [String: Any] = [
        "Type": "linked", "Linked": choice(name), "Unrelated": "user-change",
      ]
      external["AllSpacesAndDisplays"] = replacement
      try write(external)
      XCTAssertThrowsError(try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: ["one"]))
      try selection.synchronize(desktopDisplays: [], screenSaverDisplays: [])
      XCTAssertEqual(try readStore()["AllSpacesAndDisplays"] as? NSDictionary, replacement as NSDictionary)
    }
  }

  @MainActor
  func testNewGlobalDesktopIsSavedWhenLockScreenJoinsAnActiveSaver() throws {
    try write(fixture())
    let selection = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
    try selection.synchronize(desktopDisplays: [], screenSaverDisplays: ["one"])
    var external = try readStore()
    let desktop: [String: Any] = ["Type": "desktop", "Desktop": choice("user-desktop")]
    external["AllSpacesAndDisplays"] = desktop
    try write(external)
    try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: ["one"])
    var expected = fixture()
    expected["AllSpacesAndDisplays"] = desktop
    try assertDiskRecovery(restores: expected)
    try selection.synchronize(desktopDisplays: [], screenSaverDisplays: [])
    XCTAssertEqual(try readStore() as NSDictionary, expected as NSDictionary)
  }

  @MainActor
  func testCopiedDefaultFallbackReturnsToLinkedAfterNativeSelectionEnds() throws {
    let linked = linkedDefault()
    let original: [String: Any] = [
      "AllSpacesAndDisplays": linked, "SystemDefault": linked,
      "Displays": ["one": linked], "Spaces": [String: Any](),
    ]
    try write(original)
    let selection = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
    try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: ["one"])
    var copied = try readStore()
    copied["SystemDefault"] = (copied["Displays"] as? [String: Any])?["one"]
    try write(copied)
    try assertDiskRecovery(restores: original)
    try selection.synchronize(desktopDisplays: [], screenSaverDisplays: [])
    XCTAssertEqual(try readStore() as NSDictionary, original as NSDictionary)
  }

  @MainActor
  func testLegacyGlobalJournalWithoutAnOriginalDoesNotCreateAnEmptyOverride() throws {
    let original = fixture()
    try write(original)
    let selection = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
    try selection.synchronize(desktopDisplays: [], screenSaverDisplays: ["one"])
    var saved = try XCTUnwrap(PropertyListSerialization.propertyList(
      from: Data(contentsOf: journal), format: nil) as? [[String: Any]])
    let index = try XCTUnwrap(saved.firstIndex { $0["path"] as? [String] == ["AllSpacesAndDisplays"] })
    saved[index].removeValue(forKey: "globalWasPresent")
    saved[index]["created"] = false
    try PropertyListSerialization.data(fromPropertyList: saved, format: .binary, options: 0)
      .write(to: journal, options: .atomic)
    try assertDiskRecovery(restores: original)
  }

  @MainActor
  func testDefaultLinkedSelectionsRecoverAfterReloadFailure() throws {
    let linked = linkedDefault()
    let original: [String: Any] = [
      "AllSpacesAndDisplays": linked, "SystemDefault": linked,
      "Displays": ["one": linked], "Spaces": [String: Any](),
    ]
    try write(original)
    let selection = LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal, reload: { throw CocoaError(.executableRuntimeMismatch) })
    XCTAssertThrowsError(try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: ["one"]))
    try assertDiskRecovery(restores: original)
  }

  @MainActor
  func testOrphanedSpaceIdleRecoversFromDisplayAndPreservesDesktop() throws {
    var original = fixture()
    var spaces = try XCTUnwrap(original["Spaces"] as? [String: [String: Any]])
    var space = try XCTUnwrap(spaces["space-a"])
    var displays = try XCTUnwrap(space["Displays"] as? [String: [String: Any]])
    displays["one"]?["Idle"] = choice(LockScreenConfiguration.extensionIdentifier)
    var fallback = node("default-a")
    fallback["Idle"] = choice(LockScreenConfiguration.extensionIdentifier)
    space["Default"] = fallback
    space["Displays"] = displays
    spaces["space-a"] = space
    original["Spaces"] = spaces
    try write(original)
    let selection = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
    try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: ["one"])
    let recovered = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
    try recovered.recover()
    let restoredSpaces = try XCTUnwrap(try readStore()["Spaces"] as? [String: [String: Any]])
    let restored = try XCTUnwrap(restoredSpaces["space-a"])
    let restoredDisplays = try XCTUnwrap(restored["Displays"] as? [String: [String: Any]])
    let display = try XCTUnwrap(restoredDisplays["one"])
    XCTAssertEqual(provider(display, key: "Desktop"), "space-one-desktop")
    XCTAssertEqual(provider(display, key: "Idle"), "display-one-idle")
    let restoredFallback = try XCTUnwrap(restored["Default"] as? [String: Any])
    XCTAssertEqual(provider(restoredFallback, key: "Desktop"), "default-a-desktop")
    XCTAssertEqual(provider(restoredFallback, key: "Idle"), "system-idle")
    XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
  }

  @MainActor
  func testSystemCopiedSpaceDefaultRestoresAcrossRelaunch() throws {
    let original = fixture()
    try write(original)
    let selection = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
    try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: ["one"])
    var copied = try readStore()
    var spaces = try XCTUnwrap(copied["Spaces"] as? [String: [String: Any]])
    var fallback = node("default-a")
    fallback["Desktop"] = choice(LockScreenConfiguration.extensionIdentifier)
    fallback["Idle"] = choice(LockScreenConfiguration.extensionIdentifier)
    spaces["space-a"]?["Default"] = fallback
    copied["Spaces"] = spaces
    try write(copied)
    let recovered = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
    try recovered.recover()
    XCTAssertEqual(try readStore() as NSDictionary, original as NSDictionary)
  }

  /// macOS copies the extension's selection into the fallbacks it reloads
  /// (SystemDefault, each Space's Default), and a Space created afterwards, a
  /// full-screen app's included, starts from those copies. Its nodes have no
  /// native choice left in the live store; the fallbacks' journaled originals
  /// still hold one, so the new Space must be taken over instead of turning the
  /// feature off, and restored to what those fallbacks had.
  @MainActor
  func testSpaceCreatedAfterSystemCopiedTheSelectionRestoresFromJournaledFallbacks() throws {
    var original = fixture()
    // As on a Mac where another app sets only the global idle choice.
    original["AllSpacesAndDisplays"] = ["Idle": choice("another-app-idle"), "Type": "idle"]
    try write(original)
    let selection = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
    try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: ["one"])

    var copied = try readStore()
    let owned = try XCTUnwrap((copied["Displays"] as? [String: [String: Any]])?["one"])
    var system = try XCTUnwrap(copied["SystemDefault"] as? [String: Any])
    system["Desktop"] = owned["Desktop"]
    system["Idle"] = owned["Idle"]
    copied["SystemDefault"] = system
    var spaces = try XCTUnwrap(copied["Spaces"] as? [String: [String: Any]])
    var inherited = node("new-space")
    inherited["Desktop"] = owned["Desktop"]
    inherited["Idle"] = owned["Idle"]
    spaces["space-new"] = ["Default": inherited, "Displays": ["one": inherited]]
    copied["Spaces"] = spaces
    try write(copied)

    try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: ["one"])
    try selection.synchronize(desktopDisplays: [], screenSaverDisplays: [])

    let restored = try readStore()
    XCTAssertEqual(
      restored["SystemDefault"] as? NSDictionary, original["SystemDefault"] as? NSDictionary)
    let newSpace = try XCTUnwrap((restored["Spaces"] as? [String: [String: Any]])?["space-new"])
    let newDefault = try XCTUnwrap(newSpace["Default"] as? [String: Any])
    XCTAssertEqual(provider(newDefault, key: "Desktop"), "system-desktop")
    XCTAssertEqual(provider(newDefault, key: "Idle"), "system-idle")
    let newDisplay = try XCTUnwrap((newSpace["Displays"] as? [String: [String: Any]])?["one"])
    XCTAssertEqual(provider(newDisplay, key: "Desktop"), "display-one-desktop")
    XCTAssertEqual(provider(newDisplay, key: "Idle"), "display-one-idle")
    XCTAssertEqual(newDisplay["Unrelated"] as? String, "new-space", "fields macOS set are kept")
    XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
  }

  /// A Space created after the last check while the feature was on was never
  /// journaled. Turning the feature off must still give it back its native
  /// choices rather than leave it pointing at the extension.
  @MainActor
  func testSpaceCreatedJustBeforeTurningOffIsRestoredToo() throws {
    var original = fixture()
    original["AllSpacesAndDisplays"] = ["Idle": choice("another-app-idle"), "Type": "idle"]
    try write(original)
    let selection = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
    try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: ["one"])

    var copied = try readStore()
    let owned = try XCTUnwrap((copied["Displays"] as? [String: [String: Any]])?["one"])
    var system = try XCTUnwrap(copied["SystemDefault"] as? [String: Any])
    system["Desktop"] = owned["Desktop"]
    system["Idle"] = owned["Idle"]
    copied["SystemDefault"] = system
    var spaces = try XCTUnwrap(copied["Spaces"] as? [String: [String: Any]])
    var inherited = node("new-space")
    inherited["Desktop"] = owned["Desktop"]
    inherited["Idle"] = owned["Idle"]
    spaces["space-new"] = ["Default": inherited, "Displays": ["one": inherited]]
    copied["Spaces"] = spaces
    try write(copied)

    try selection.synchronize(desktopDisplays: [], screenSaverDisplays: [])

    let restored = try readStore()
    XCTAssertEqual(
      restored["SystemDefault"] as? NSDictionary, original["SystemDefault"] as? NSDictionary)
    let newSpace = try XCTUnwrap((restored["Spaces"] as? [String: [String: Any]])?["space-new"])
    let newDefault = try XCTUnwrap(newSpace["Default"] as? [String: Any])
    XCTAssertEqual(provider(newDefault, key: "Desktop"), "system-desktop")
    XCTAssertEqual(provider(newDefault, key: "Idle"), "system-idle")
    let newDisplay = try XCTUnwrap((newSpace["Displays"] as? [String: [String: Any]])?["one"])
    XCTAssertEqual(provider(newDisplay, key: "Desktop"), "display-one-desktop")
    XCTAssertEqual(provider(newDisplay, key: "Idle"), "display-one-idle")
    XCTAssertEqual(newDisplay["Unrelated"] as? String, "new-space", "fields macOS set are kept")
    XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
  }

  @MainActor
  func testOrphanWithoutNativeFallbackDoesNotChangeStore() throws {
    var original = fixture()
    original["SystemDefault"] = [:] as [String: Any]
    original["AllSpacesAndDisplays"] = [:] as [String: Any]
    original["Spaces"] = [:] as [String: Any]
    var display = node("display-one")
    display["Idle"] = choice(LockScreenConfiguration.extensionIdentifier)
    original["Displays"] = ["one": display]
    try write(original)
    let selection = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
    XCTAssertThrowsError(try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: ["one"]))
    XCTAssertEqual(try readStore() as NSDictionary, original as NSDictionary)
    XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
  }

  @MainActor
  func testUnchangedJournalIsNotRewrittenForRepeatedOrRevisionOnlySynchronization() throws {
    let original = fixture()
    try write(original)
    var writes = 0
    var removes = 0
    var reloads = 0
    let selection = LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal, reload: { reloads += 1 },
      persistJournal: { url, data in
        try LockScreenWallpaperSelection.persistJournalFile(url, data)
        if data == nil { removes += 1 } else { writes += 1 }
      })
    try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: ["one"], revision: "first")
    let journalBytes = try Data(contentsOf: journal)
    let firstStore = try Data(contentsOf: store)
    try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: ["one"], revision: "first")
    XCTAssertEqual(try Data(contentsOf: store), firstStore)
    try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: ["one"], revision: "second")
    XCTAssertNotEqual(try Data(contentsOf: store), firstStore)
    XCTAssertEqual(try Data(contentsOf: journal), journalBytes)
    XCTAssertEqual(writes, 1)
    XCTAssertEqual(reloads, 2)
    try selection.synchronize(desktopDisplays: [], screenSaverDisplays: [])
    try selection.synchronize(desktopDisplays: [], screenSaverDisplays: [])
    XCTAssertEqual(writes, 1)
    XCTAssertEqual(removes, 1)
    XCTAssertEqual(try readStore() as NSDictionary, original as NSDictionary)
  }

  @MainActor
  func testExpansionFailureCannotCommitStoreAndRetryKeepsBothOriginals() throws {
    let original = fixture()
    try write(original)
    var failExpansion = false
    var writes = 0
    var reloads = 0
    var storeBeforeCommit = try Data(contentsOf: store)
    let selection = LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal,
      reload: {
        XCTAssertTrue(FileManager.default.fileExists(atPath: self.journal.path))
        XCTAssertNotEqual(try Data(contentsOf: self.store), storeBeforeCommit)
        reloads += 1
      },
      persistJournal: { url, data in
        XCTAssertEqual(try Data(contentsOf: self.store), storeBeforeCommit)
        if failExpansion { throw CocoaError(.fileWriteOutOfSpace) }
        try LockScreenWallpaperSelection.persistJournalFile(url, data)
        writes += 1
      })
    try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: ["one"])
    storeBeforeCommit = try Data(contentsOf: store)
    let firstJournal = try Data(contentsOf: journal)
    failExpansion = true
    XCTAssertThrowsError(try selection.synchronize(desktopDisplays: ["one", "two"], screenSaverDisplays: ["one", "two"]))
    XCTAssertEqual(try Data(contentsOf: store), storeBeforeCommit)
    XCTAssertEqual(try Data(contentsOf: journal), firstJournal)
    XCTAssertEqual(reloads, 1)
    try assertDiskRecovery(restores: original)
    failExpansion = false
    try selection.synchronize(desktopDisplays: ["one", "two"], screenSaverDisplays: ["one", "two"])
    XCTAssertEqual(writes, 2)
    XCTAssertEqual(reloads, 2)
    let recovered = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
    try recovered.recover()
    XCTAssertEqual(try readStore() as NSDictionary, original as NSDictionary)
  }

  @MainActor
  func testConcurrentStoreChangeRetainsUnionWithoutOverwritingExternalBytes() throws {
    var external = fixture()
    try write(external)
    external["Unrelated"] = "concurrent external update"
    var reloads = 0
    let selection = LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal, reload: { reloads += 1 },
      persistJournal: { url, data in
        try LockScreenWallpaperSelection.persistJournalFile(url, data)
        try self.write(external)
      })
    XCTAssertThrowsError(try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: ["one"]))
    XCTAssertEqual(reloads, 0)
    XCTAssertEqual(try readStore() as NSDictionary, external as NSDictionary)
    XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
    let recovered = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
    try recovered.recover()
    XCTAssertEqual(try readStore() as NSDictionary, external as NSDictionary)
    XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
  }

  /// WallpaperAgent writes its store in bursts; an attempt that lost that race wrote nothing, so
  /// the next one takes the displays over rather than reporting a change made outside the app.
  @MainActor
  func testRetryAfterConcurrentStoreChangeTakesOverInsteadOfReportingAnExternalChange() throws {
    var external = fixture()
    try write(external)
    external["Unrelated"] = "concurrent external update"
    var raced = false
    var reloads = 0
    let selection = LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal, reload: { reloads += 1 },
      persistJournal: { url, data in
        try LockScreenWallpaperSelection.persistJournalFile(url, data)
        if !raced {
          raced = true
          try self.write(external)
        }
      })
    XCTAssertThrowsError(try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: ["one"])) {
      XCTAssertEqual(($0 as? LockScreenWallpaperFailure)?.reason, .transient)
    }
    try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: ["one"])
    XCTAssertEqual(reloads, 1)
    let taken = try readStore()
    let display = try XCTUnwrap((taken["Displays"] as? [String: Any])?["one"] as? [String: Any])
    XCTAssertEqual(provider(display, key: "Desktop"), LockScreenConfiguration.extensionIdentifier)
    XCTAssertEqual(taken["Unrelated"] as? String, "concurrent external update")
    try selection.synchronize(desktopDisplays: [], screenSaverDisplays: [])
    XCTAssertEqual(try readStore() as NSDictionary, external as NSDictionary)
  }

  @MainActor
  func testReloadRetryUsesPersistedUnionWithoutRewritingIt() throws {
    let original = fixture()
    try write(original)
    var failReload = true
    var writes = 0
    var reloads = 0
    let selection = LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal,
      reload: {
        reloads += 1
        if failReload { throw CocoaError(.executableRuntimeMismatch) }
      },
      persistJournal: { url, data in
        try LockScreenWallpaperSelection.persistJournalFile(url, data)
        writes += 1
      })
    XCTAssertThrowsError(try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: ["one"]))
    let committedStore = try Data(contentsOf: store)
    let committedJournal = try Data(contentsOf: journal)
    try assertDiskRecovery(restores: original)
    failReload = false
    try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: ["one"])
    XCTAssertEqual(reloads, 2)
    XCTAssertEqual(writes, 1)
    XCTAssertEqual(try Data(contentsOf: store), committedStore)
    XCTAssertEqual(try Data(contentsOf: journal), committedJournal)
    let recovered = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
    try recovered.recover()
    XCTAssertEqual(try readStore() as NSDictionary, original as NSDictionary)
  }

  @MainActor
  func testPruneFailureKeepsRecoveryUnionOnDisk() throws {
    let original = fixture()
    try write(original)
    var failPrune = false
    var reloads = 0
    let selection = LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal, reload: { reloads += 1 },
      persistJournal: { url, data in
        if failPrune {
          XCTAssertEqual(reloads, 2, "Prune must follow the successful store reload")
          throw CocoaError(.fileWriteOutOfSpace)
        }
        try LockScreenWallpaperSelection.persistJournalFile(url, data)
      })
    try selection.synchronize(desktopDisplays: ["one", "two"], screenSaverDisplays: ["one", "two"])
    let union = try Data(contentsOf: journal)
    failPrune = true
    XCTAssertThrowsError(try selection.synchronize(desktopDisplays: ["two"], screenSaverDisplays: ["two"]))
    XCTAssertEqual(try Data(contentsOf: journal), union)
    let displays = try XCTUnwrap(try readStore()["Displays"] as? [String: [String: Any]])
    XCTAssertEqual(provider(try XCTUnwrap(displays["one"]), key: "Idle"), "display-one-idle")
    XCTAssertEqual(
      provider(try XCTUnwrap(displays["two"]), key: "Idle"),
      LockScreenConfiguration.extensionIdentifier)
    let recovered = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
    try recovered.recover()
    XCTAssertEqual(try readStore() as NSDictionary, original as NSDictionary)
  }

  @MainActor
  func testRemoveFailureRetainsMemoryAndDiskUntilRetrySucceeds() throws {
    let original = fixture()
    try write(original)
    var failRemove = true
    var removeAttempts = 0
    var reloads = 0
    let selection = LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal, reload: { reloads += 1 },
      persistJournal: { url, data in
        if data == nil {
          removeAttempts += 1
          XCTAssertEqual(try self.readStore() as NSDictionary, original as NSDictionary)
          if failRemove { throw CocoaError(.fileWriteNoPermission) }
        }
        try LockScreenWallpaperSelection.persistJournalFile(url, data)
      })
    try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: ["one"])
    let union = try Data(contentsOf: journal)
    XCTAssertThrowsError(try selection.synchronize(desktopDisplays: [], screenSaverDisplays: []))
    XCTAssertEqual(try Data(contentsOf: journal), union)
    XCTAssertEqual(try readStore() as NSDictionary, original as NSDictionary)
    try assertDiskRecovery(restores: original)
    failRemove = false
    try selection.synchronize(desktopDisplays: [], screenSaverDisplays: [])
    XCTAssertEqual(removeAttempts, 2)
    XCTAssertEqual(reloads, 2, "Retrying journal removal alone must not reload the store")
    XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
  }

  @MainActor
  func testNewAndDisappearingSpacesAreReconciledWithUnchangedInputs() throws {
    try write(fixture())
    var writes = 0
    let selection = LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal, reload: {},
      persistJournal: { url, data in
        try LockScreenWallpaperSelection.persistJournalFile(url, data)
        if data != nil { writes += 1 }
      })
    try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: ["one"], revision: "same")
    var changed = try readStore()
    var spaces = try XCTUnwrap(changed["Spaces"] as? [String: Any])
    spaces["space-b"] = ["Default": node("new-default"), "Displays": [String: Any]()]
    changed["Spaces"] = spaces
    try write(changed)
    try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: ["one"], revision: "same")
    XCTAssertEqual(writes, 2)
    var selected = try readStore()
    var selectedSpaces = try XCTUnwrap(selected["Spaces"] as? [String: [String: Any]])
    let newDisplays = try XCTUnwrap(selectedSpaces["space-b"]?["Displays"] as? [String: [String: Any]])
    XCTAssertEqual(
      provider(try XCTUnwrap(newDisplays["one"]), key: "Idle"),
      LockScreenConfiguration.extensionIdentifier)
    selectedSpaces.removeValue(forKey: "space-a")
    selected["Spaces"] = selectedSpaces
    try write(selected)
    try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: ["one"], revision: "same")
    try selection.synchronize(desktopDisplays: [], screenSaverDisplays: [])
    let restoredSpaces = try XCTUnwrap(try readStore()["Spaces"] as? [String: [String: Any]])
    XCTAssertNil(restoredSpaces["space-a"])
    XCTAssertEqual(
      restoredSpaces["space-b"]?["Default"] as? NSDictionary, node("new-default") as NSDictionary)
    XCTAssertTrue(
      try XCTUnwrap(restoredSpaces["space-b"]?["Displays"] as? [String: Any]).isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
  }

  @MainActor
  func testUnrelatedStoreWritesNeverRewriteJournaledBaselines() throws {
    // A suppressed global override, a separated linked display and a synthesized
    // Space display each journal a multi-key baseline.
    var original = fixture()
    original["AllSpacesAndDisplays"] = [
      "Type": "individual", "Desktop": choice("global-desktop"), "Idle": choice("default"),
      "Unrelated": "keep",
    ]
    original["Displays"] = ["one": node("display-one"), "two": linkedDefault()]
    var spaces = try XCTUnwrap(original["Spaces"] as? [String: Any])
    spaces["space-b"] = ["Default": node("default-b"), "Displays": [String: Any]()]
    original["Spaces"] = spaces
    try write(original)
    var writes = 0
    var reloads = 0
    let selection = LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal, reload: { reloads += 1 },
      persistJournal: { url, data in
        try LockScreenWallpaperSelection.persistJournalFile(url, data)
        writes += 1
      })
    try selection.synchronize(
      desktopDisplays: ["one", "two"], screenSaverDisplays: ["one", "two"], revision: "same")
    let journalBytes = try Data(contentsOf: journal)
    XCTAssertEqual(writes, 1)
    for check in 0..<20 {
      var external = try readStore()
      external["Unrelated"] = "external write \(check)"
      try write(external)
      try selection.synchronize(
        desktopDisplays: ["one", "two"], screenSaverDisplays: ["one", "two"], revision: "same")
    }
    XCTAssertEqual(writes, 1, "An unchanged selection must not rewrite its journal")
    XCTAssertEqual(reloads, 1)
    XCTAssertEqual(try Data(contentsOf: journal), journalBytes)
    let current = try readStore()["Unrelated"]
    try selection.synchronize(desktopDisplays: [], screenSaverDisplays: [])
    original["Unrelated"] = current
    XCTAssertEqual(try readStore() as NSDictionary, original as NSDictionary)
  }

  @MainActor
  func testSettledCheckStillReactsToEveryLaterStoreWrite() throws {
    try write(fixture())
    var reloads = 0
    let selection = LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal, reload: { reloads += 1 })
    func check() throws {
      try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: ["one"], revision: "same")
    }
    try check()
    try check()
    XCTAssertEqual(reloads, 1)
    // macOS replaces the store when a Space is created.
    var created = try readStore()
    var spaces = try XCTUnwrap(created["Spaces"] as? [String: Any])
    spaces["space-b"] = ["Default": node("default-b"), "Displays": [String: Any]()]
    created["Spaces"] = spaces
    try write(created)
    try check()
    try check()
    XCTAssertEqual(reloads, 2)
    let space = try XCTUnwrap((try readStore()["Spaces"] as? [String: [String: Any]])?["space-b"])
    XCTAssertEqual(
      provider(try XCTUnwrap((space["Displays"] as? [String: [String: Any]])?["one"]), key: "Desktop"),
      LockScreenConfiguration.extensionIdentifier)
    // System Settings may write in place, keeping the file's inode.
    var external = try readStore()
    var displays = try XCTUnwrap(external["Displays"] as? [String: [String: Any]])
    displays["one"]?["Desktop"] = choice("user-selected")
    external["Displays"] = displays
    try PropertyListSerialization.data(fromPropertyList: external, format: .binary, options: 0)
      .write(to: store)
    XCTAssertThrowsError(try check())
  }

  @MainActor
  func testInvalidLinkedOriginalPreservesStoreAndRecoveryJournal() throws {
    try assertInvalidBaselinePreservesRecovery(field: "linkedOriginal", linked: true)
  }

  @MainActor
  func testInvalidInheritedOriginalPreservesStoreAndRecoveryJournal() throws {
    try assertInvalidBaselinePreservesRecovery(field: "inheritedOriginal", linked: false)
  }

  @MainActor
  private func assertInvalidBaselinePreservesRecovery(field: String, linked: Bool) throws {
    let invalidPayloads = [
      try PropertyListSerialization.data(fromPropertyList: ["not a dictionary"], format: .binary, options: 0),
      Data("not a property list".utf8),
    ]
    for payload in invalidPayloads {
      let displays: [String: Any] = linked ? ["one": linkedDefault()] : [:]
      let original: [String: Any] = [
        "SystemDefault": node("system"),
        "Displays": displays,
        "Spaces": [String: Any](),
      ]
      try write(original)
      let selection = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
      try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: [])
      let validJournal = try Data(contentsOf: journal)
      let selectedStore = try Data(contentsOf: store)
      var saved = try XCTUnwrap(PropertyListSerialization.propertyList(
        from: validJournal, format: nil) as? [[String: Any]])
      let index = try XCTUnwrap(saved.firstIndex { $0["path"] as? [String] == ["Displays", "one"] })
      XCTAssertNotNil(saved[index][field])
      saved[index][field] = payload
      let invalidJournal = try PropertyListSerialization.data(fromPropertyList: saved, format: .binary, options: 0)
      try invalidJournal.write(to: journal, options: .atomic)

      var reloads = 0
      let recovered = LockScreenWallpaperSelection(
        storeURL: store, journalURL: journal, reload: { reloads += 1 })
      XCTAssertThrowsError(try recovered.recover())
      XCTAssertEqual(try Data(contentsOf: store), selectedStore)
      XCTAssertEqual(try Data(contentsOf: journal), invalidJournal)
      XCTAssertEqual(reloads, 0)

      try validJournal.write(to: journal, options: .atomic)
      try recovered.recover()
      XCTAssertEqual(try readStore() as NSDictionary, original as NSDictionary)
      XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
      XCTAssertEqual(reloads, 1)
    }
  }

  @MainActor
  func testDecodedEmptyJournalIsRemovedAndMalformedJournalIsPreserved() throws {
    try write(fixture())
    try PropertyListEncoder().encode([String]()).write(to: journal)
    var removes = 0
    let selection = LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal, reload: {},
      persistJournal: { url, data in
        if data == nil { removes += 1 }
        try LockScreenWallpaperSelection.persistJournalFile(url, data)
      })
    try selection.recover()
    XCTAssertEqual(removes, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    let malformed = Data("not a property list".utf8)
    try malformed.write(to: journal)
    XCTAssertThrowsError(try selection.recover())
    XCTAssertEqual(try Data(contentsOf: journal), malformed)
    XCTAssertEqual(removes, 1)
  }

  @MainActor
  func testSaverOnlyPreservesDesktopAndMetadataAcrossRevisionAndRecovery() throws {
    var original = fixture()
    var displays = try XCTUnwrap(original["Displays"] as? [String: [String: Any]])
    displays["one"]?["Unknown"] = ["nested": "keep"]
    original["Displays"] = displays
    try write(original)
    let selection = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
    try selection.synchronize(desktopDisplays: [], screenSaverDisplays: ["one"], revision: "first")
    try selection.synchronize(desktopDisplays: [], screenSaverDisplays: ["one"], revision: "second")
    let selected = try readStore()
    let selectedDisplays = try XCTUnwrap(selected["Displays"] as? [String: [String: Any]])
    var actual = try XCTUnwrap(selectedDisplays["one"])
    XCTAssertEqual(provider(actual, key: "Idle"), LockScreenConfiguration.extensionIdentifier)
    actual["Idle"] = displays["one"]?["Idle"]
    XCTAssertEqual(actual as NSDictionary, displays["one"] as NSDictionary?)
    let spaces = try XCTUnwrap(selected["Spaces"] as? [String: [String: Any]])
    let spaceDisplays = try XCTUnwrap(spaces["space-a"]?["Displays"] as? [String: [String: Any]])
    XCTAssertEqual(provider(try XCTUnwrap(spaceDisplays["one"]), key: "Desktop"), "space-one-desktop")
    try assertDiskRecovery(restores: original)
    try selection.synchronize(desktopDisplays: [], screenSaverDisplays: [])
    XCTAssertEqual(try readStore() as NSDictionary, original as NSDictionary)
  }

  @MainActor
  func testGlobalIdleOverrideYieldsToDisplaySaversAndRestoresOnDisableOrCrash() throws {
    for type in ["idle", "individual"] {
      var original = fixture()
      var global: [String: Any] = [
        "Type": type, "Idle": choice("default"), "Unrelated": "keep",
      ]
      if type == "individual" { global["Desktop"] = choice("global-desktop") }
      original["AllSpacesAndDisplays"] = global
      try write(original)
      var reloads = 0
      let selection = LockScreenWallpaperSelection(
        storeURL: store, journalURL: journal, reload: { reloads += 1 })
      try selection.synchronize(desktopDisplays: [], screenSaverDisplays: ["one"])
      let selected = try readStore()
      let activeGlobal = selected["AllSpacesAndDisplays"] as? [String: Any]
      if type == "idle" {
        XCTAssertNil(activeGlobal, "A global Idle selection overrides every display")
      } else {
        XCTAssertEqual(activeGlobal?["Type"] as? String, "desktop")
        XCTAssertNil(activeGlobal?["Idle"])
        XCTAssertEqual(activeGlobal?["Desktop"] as? NSDictionary, global["Desktop"] as? NSDictionary)
      }
      let displays = try XCTUnwrap(selected["Displays"] as? [String: [String: Any]])
      XCTAssertEqual(provider(try XCTUnwrap(displays["one"]), key: "Idle"),
        LockScreenConfiguration.extensionIdentifier)
      XCTAssertEqual(displays["two"] as NSDictionary?,
        (original["Displays"] as? [String: Any])?["two"] as? NSDictionary)
      try selection.synchronize(desktopDisplays: [], screenSaverDisplays: ["one"])
      XCTAssertEqual(reloads, 1)
      try assertDiskRecovery(restores: original)
      try selection.synchronize(desktopDisplays: [], screenSaverDisplays: [])
      XCTAssertEqual(try readStore() as NSDictionary, original as NSDictionary)
    }
  }

  @MainActor
  func testGlobalIdleRestoresWhenSaverDisablesWhileLockScreenRemainsEnabled() throws {
    var original = fixture()
    original["AllSpacesAndDisplays"] = ["Type": "idle", "Idle": choice("default")]
    try write(original)
    let selection = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
    try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: [])
    XCTAssertEqual(try readStore()["AllSpacesAndDisplays"] as? NSDictionary,
      original["AllSpacesAndDisplays"] as? NSDictionary)
    try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: ["one"])
    XCTAssertNil(try readStore()["AllSpacesAndDisplays"])
    try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: [])
    let selected = try readStore()
    XCTAssertEqual(selected["AllSpacesAndDisplays"] as? NSDictionary,
      original["AllSpacesAndDisplays"] as? NSDictionary)
    let display = try XCTUnwrap((selected["Displays"] as? [String: [String: Any]])?["one"])
    XCTAssertEqual(provider(display, key: "Desktop"), LockScreenConfiguration.extensionIdentifier)
    try selection.synchronize(desktopDisplays: [], screenSaverDisplays: [])
    XCTAssertEqual(try readStore() as NSDictionary, original as NSDictionary)
  }

  @MainActor
  func testNewGlobalSaverIsPreservedAndReportedInsteadOfSilentlyOverridden() throws {
    for hadGlobalSaver in [false, true] {
      var original = fixture()
      if hadGlobalSaver {
        original["AllSpacesAndDisplays"] = ["Type": "idle", "Idle": choice("default")]
      }
      try write(original)
      let selection = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
      try selection.synchronize(desktopDisplays: [], screenSaverDisplays: ["one"])
      var external = try readStore()
      let newGlobal: [String: Any] = ["Type": "idle", "Idle": choice("user-selected")]
      external["AllSpacesAndDisplays"] = newGlobal
      try write(external)
      XCTAssertThrowsError(try selection.synchronize(desktopDisplays: [], screenSaverDisplays: ["one"]))
      XCTAssertEqual(try readStore() as NSDictionary, external as NSDictionary)
      original["AllSpacesAndDisplays"] = newGlobal
      try assertDiskRecovery(restores: original)
      try selection.synchronize(desktopDisplays: [], screenSaverDisplays: [])
      XCTAssertEqual(try readStore() as NSDictionary, original as NSDictionary)
    }
  }

  @MainActor
  func testGlobalDesktopChangesSurviveRestoringTheScreenSaver() throws {
    for type in ["idle", "individual"] {
      var original = fixture()
      var global: [String: Any] = ["Type": type, "Idle": choice("default")]
      if type == "individual" { global["Desktop"] = choice("old-desktop") }
      original["AllSpacesAndDisplays"] = global
      try write(original)
      let selection = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
      try selection.synchronize(desktopDisplays: [], screenSaverDisplays: ["one"])
      var external = try readStore()
      external["AllSpacesAndDisplays"] = [
        "Type": "desktop", "Desktop": choice("new-desktop"), "Unrelated": "new-metadata",
      ]
      try write(external)
      try selection.synchronize(desktopDisplays: [], screenSaverDisplays: ["one"])
      global["Type"] = "individual"
      global["Desktop"] = choice("new-desktop")
      global["Unrelated"] = "new-metadata"
      original["AllSpacesAndDisplays"] = global
      try assertDiskRecovery(restores: original)
      try selection.synchronize(desktopDisplays: [], screenSaverDisplays: [])
      XCTAssertEqual(try readStore() as NSDictionary, original as NSDictionary)
    }
  }

  @MainActor
  func testGlobalIdleSuppressionRemainsRecoverableWhenReloadFails() throws {
    var original = fixture()
    original["AllSpacesAndDisplays"] = ["Type": "idle", "Idle": choice("default")]
    try write(original)
    let selection = LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal, reload: { throw CocoaError(.executableRuntimeMismatch) })
    XCTAssertThrowsError(try selection.synchronize(desktopDisplays: [], screenSaverDisplays: ["one"]))
    XCTAssertNil(try readStore()["AllSpacesAndDisplays"])
    try assertDiskRecovery(restores: original)
  }

  @MainActor
  func testDesktopOnlyDoesNotClaimOrRepairIdle() throws {
    var original = fixture()
    original["SystemDefault"] = [:] as [String: Any]
    original["AllSpacesAndDisplays"] = [:] as [String: Any]
    original["Spaces"] = [:] as [String: Any]
    var display = node("display-one")
    display["Idle"] = choice(LockScreenConfiguration.extensionIdentifier)
    original["Displays"] = ["one": display]
    try write(original)
    let selection = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
    try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: [])
    let selected = try XCTUnwrap((try readStore()["Displays"] as? [String: [String: Any]])?["one"])
    XCTAssertEqual(selected["Idle"] as? NSDictionary, display["Idle"] as? NSDictionary)
    try assertDiskRecovery(restores: original)
    try selection.synchronize(desktopDisplays: [], screenSaverDisplays: [])
    XCTAssertEqual(try readStore() as NSDictionary, original as NSDictionary)
  }

  @MainActor
  func testBothModesCanBeEnabledAndDisabledInEitherOrder() throws {
    for firstSaver in [false, true] {
      for remainingSaver in [false, true] {
        let original = fixture()
        try write(original)
        let selection = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
        try selection.synchronize(
          desktopDisplays: firstSaver ? [] : ["one"],
          screenSaverDisplays: firstSaver ? ["one"] : [])
        try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: ["one"])
        try assertDiskRecovery(restores: original)
        try selection.synchronize(
          desktopDisplays: remainingSaver ? [] : ["one"],
          screenSaverDisplays: remainingSaver ? ["one"] : [])
        let selected = try XCTUnwrap((try readStore()["Displays"] as? [String: [String: Any]])?["one"])
        XCTAssertEqual(
          provider(selected, key: "Desktop"),
          remainingSaver ? "display-one-desktop" : LockScreenConfiguration.extensionIdentifier)
        XCTAssertEqual(
          provider(selected, key: "Idle"),
          remainingSaver ? LockScreenConfiguration.extensionIdentifier : "display-one-idle")
        try assertDiskRecovery(restores: original)
        try selection.synchronize(desktopDisplays: [], screenSaverDisplays: [])
        XCTAssertEqual(try readStore() as NSDictionary, original as NSDictionary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
      }
    }
  }

  @MainActor
  func testUnmanagedExternalFieldCanChangeAndItsLatestChoiceIsJournaledOnActivation() throws {
    for saver in [false, true] {
      try write(fixture())
      let selection = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
      try selection.synchronize(
        desktopDisplays: saver ? [] : ["one"], screenSaverDisplays: saver ? ["one"] : [])
      let externalKey = saver ? "Desktop" : "Idle"
      var external = try readStore()
      var displays = try XCTUnwrap(external["Displays"] as? [String: [String: Any]])
      displays["one"]?[externalKey] = choice("latest-user-choice")
      displays["one"]?["Unrelated"] = "latest-user-metadata"
      external["Displays"] = displays
      try write(external)
      try selection.synchronize(
        desktopDisplays: saver ? [] : ["one"], screenSaverDisplays: saver ? ["one"] : [],
        revision: "refresh")
      let refreshed = try XCTUnwrap((try readStore()["Displays"] as? [String: [String: Any]])?["one"])
      XCTAssertEqual(provider(refreshed, key: externalKey), "latest-user-choice")
      try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: ["one"])
      try selection.synchronize(desktopDisplays: [], screenSaverDisplays: [])
      let restored = try XCTUnwrap((try readStore()["Displays"] as? [String: [String: Any]])?["one"])
      XCTAssertEqual(provider(restored, key: externalKey), "latest-user-choice")
      XCTAssertEqual(provider(restored, key: saver ? "Idle" : "Desktop"),
        saver ? "display-one-idle" : "display-one-desktop")
      XCTAssertEqual(restored["Unrelated"] as? String, "latest-user-metadata")
    }
  }

  @MainActor
  func testExternalOwnedFieldCanBeReleasedWhileOtherModeContinues() throws {
    for saver in [false, true] {
      try write(fixture())
      let selection = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
      try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: ["one"])
      let externalKey = saver ? "Desktop" : "Idle"
      var external = try readStore()
      var displays = try XCTUnwrap(external["Displays"] as? [String: [String: Any]])
      displays["one"]?[externalKey] = choice("foreign-choice")
      external["Displays"] = displays
      try write(external)
      XCTAssertThrowsError(
        try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: ["one"]))
      try selection.synchronize(
        desktopDisplays: saver ? [] : ["one"], screenSaverDisplays: saver ? ["one"] : [],
        revision: "other-mode-keeps-running")
      let selected = try XCTUnwrap((try readStore()["Displays"] as? [String: [String: Any]])?["one"])
      XCTAssertEqual(provider(selected, key: externalKey), "foreign-choice")
      XCTAssertEqual(provider(selected, key: saver ? "Idle" : "Desktop"),
        LockScreenConfiguration.extensionIdentifier)
      try selection.synchronize(desktopDisplays: [], screenSaverDisplays: [])
      let restored = try XCTUnwrap((try readStore()["Displays"] as? [String: [String: Any]])?["one"])
      XCTAssertEqual(provider(restored, key: externalKey), "foreign-choice")
      XCTAssertEqual(provider(restored, key: saver ? "Idle" : "Desktop"),
        saver ? "display-one-idle" : "display-one-desktop")
    }
  }

  @MainActor
  func testNewSpaceFallbackCopiesRestoreOneModeAtATime() throws {
    for remainingSaver in [false, true] {
      let original = fixture()
      try write(original)
      let selection = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
      try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: ["one"])
      var copied = try readStore()
      let owned = try XCTUnwrap((copied["Displays"] as? [String: [String: Any]])?["one"])
      var system = try XCTUnwrap(copied["SystemDefault"] as? [String: Any])
      system["Desktop"] = owned["Desktop"]
      system["Idle"] = owned["Idle"]
      copied["SystemDefault"] = system
      var spaces = try XCTUnwrap(copied["Spaces"] as? [String: Any])
      var inherited = node("new-space")
      inherited["Desktop"] = owned["Desktop"]
      inherited["Idle"] = owned["Idle"]
      spaces["new"] = ["Default": inherited, "Displays": ["one": inherited]]
      copied["Spaces"] = spaces
      try write(copied)
      try selection.synchronize(
        desktopDisplays: remainingSaver ? [] : ["one"],
        screenSaverDisplays: remainingSaver ? ["one"] : [])
      let newSpace = try XCTUnwrap((try readStore()["Spaces"] as? [String: [String: Any]])?["new"])
      let newDisplay = try XCTUnwrap((newSpace["Displays"] as? [String: [String: Any]])?["one"])
      let newDefault = try XCTUnwrap(newSpace["Default"] as? [String: Any])
      let removedKey = remainingSaver ? "Desktop" : "Idle"
      XCTAssertEqual(provider(newDisplay, key: removedKey),
        remainingSaver ? "display-one-desktop" : "display-one-idle")
      XCTAssertEqual(provider(newDefault, key: removedKey),
        remainingSaver ? "system-desktop" : "system-idle")
      XCTAssertEqual(provider(newDisplay, key: remainingSaver ? "Idle" : "Desktop"),
        LockScreenConfiguration.extensionIdentifier)
      let recovered = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
      try recovered.recover()
      let restoredSpace = try XCTUnwrap((try readStore()["Spaces"] as? [String: [String: Any]])?["new"])
      let restoredDisplay = try XCTUnwrap((restoredSpace["Displays"] as? [String: [String: Any]])?["one"])
      let restoredDefault = try XCTUnwrap(restoredSpace["Default"] as? [String: Any])
      XCTAssertEqual(provider(restoredDisplay, key: "Desktop"), "display-one-desktop")
      XCTAssertEqual(provider(restoredDisplay, key: "Idle"), "display-one-idle")
      XCTAssertEqual(provider(restoredDefault, key: "Desktop"), "system-desktop")
      XCTAssertEqual(provider(restoredDefault, key: "Idle"), "system-idle")
      XCTAssertEqual(restoredDisplay["Unrelated"] as? String, "new-space")
    }
  }

  @MainActor
  func testLegacyBothFieldJournalRecoversWithoutClaimingExternalChanges() throws {
    let original = fixture()
    try write(original)
    let selection = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
    try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: ["one"])
    var legacy = try XCTUnwrap(
      PropertyListSerialization.propertyList(from: Data(contentsOf: journal), format: nil)
        as? [[String: Any]])
    legacy.removeAll { $0["path"] as? [String] == ["AllSpacesAndDisplays"] }
    for index in legacy.indices {
      legacy[index].removeValue(forKey: "fields")
      legacy[index].removeValue(forKey: "typeOwned")
      let path = try XCTUnwrap(legacy[index]["path"] as? [String])
      var saved = original
      for key in path { saved = try XCTUnwrap(saved[key] as? [String: Any]) }
      legacy[index]["original"] = try PropertyListSerialization.data(
        fromPropertyList: saved.filter { ["Desktop", "Idle", "Type"].contains($0.key) },
        format: .binary, options: 0)
    }
    try PropertyListSerialization.data(fromPropertyList: legacy, format: .binary, options: 0)
      .write(to: journal, options: .atomic)
    var expected = original
    var external = try readStore()
    var displays = try XCTUnwrap(external["Displays"] as? [String: [String: Any]])
    displays["one"]?["Desktop"] = choice("foreign-choice")
    external["Displays"] = displays
    try write(external)
    var expectedDisplays = try XCTUnwrap(expected["Displays"] as? [String: [String: Any]])
    expectedDisplays["one"]?["Desktop"] = choice("foreign-choice")
    expected["Displays"] = expectedDisplays
    let recovered = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
    try recovered.recover()
    XCTAssertEqual(try readStore() as NSDictionary, expected as NSDictionary)
    XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
  }

  @MainActor
  func testSameDisplayFieldExpansionReloadFailureRetainsBothRestorationChoices() throws {
    let original = fixture()
    try write(original)
    var failReload = false
    let selection = LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal,
      reload: { if failReload { throw CocoaError(.executableRuntimeMismatch) } })
    try selection.synchronize(desktopDisplays: [], screenSaverDisplays: ["one"])
    failReload = true
    XCTAssertThrowsError(
      try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: ["one"]))
    try assertDiskRecovery(restores: original)
    failReload = false
    try selection.synchronize(desktopDisplays: ["one"], screenSaverDisplays: ["one"])
    try selection.synchronize(desktopDisplays: [], screenSaverDisplays: ["one"])
    try assertDiskRecovery(restores: original)
    try selection.synchronize(desktopDisplays: [], screenSaverDisplays: [])
    XCTAssertEqual(try readStore() as NSDictionary, original as NSDictionary)
  }

  @MainActor
  func testNonIndividualDisplayConfigurationIsRejectedWithoutChangingEitherChoice() throws {
    for type in ["linked", "idle", "unknown"] {
      for saver in [false, true] {
        var original = fixture()
        var displays = try XCTUnwrap(original["Displays"] as? [String: [String: Any]])
        displays["one"]?["Type"] = type
        displays["one"]?["Linked"] = choice("effective-linked-choice")
        original["Displays"] = displays
        try write(original)
        let selection = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
        XCTAssertThrowsError(try selection.synchronize(
          desktopDisplays: saver ? [] : ["one"], screenSaverDisplays: saver ? ["one"] : []))
        XCTAssertEqual(try readStore() as NSDictionary, original as NSDictionary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
      }
    }
  }

  // MARK: The scene the extension is handed

  private func publishedScene(
    framing: LockScreenFraming? = nil, scalingMode: Int32 = 3
  ) -> LockScreenScene {
    LockScreenScene(
      displayID: 1, title: "t", projectPath: "revisions/a/project.json",
      assetsPath: "revisions/a", previewPath: nil, fps: 30, scalingMode: scalingMode,
      scalingFactor: 1, propertiesJSON: nil, paused: false, framing: framing)
  }

  /// A configuration an app that predates the position wrote has no `framing` key.
  /// The extension has to read it as centred, not refuse the file.
  func testAConfigurationWrittenBeforePositionsExistedReadsAsCentred() throws {
    let json = """
      {"version":2,"revision":"r","lockScreenEnabled":true,"screenSaverEnabled":false,\
      "scenes":[{"displayID":1,"title":"t","projectPath":"revisions/a/project.json",\
      "assetsPath":"revisions/a","fps":30,"scalingMode":3,"scalingFactor":1,"paused":false}]}
      """
    let scene = try XCTUnwrap(
      try JSONDecoder().decode(LockScreenConfiguration.self, from: Data(json.utf8)).scenes.first)
    XCTAssertNil(scene.framing)
    XCTAssertEqual(scene.effectiveFraming, .centered)
    XCTAssertTrue(scene.effectiveFraming.isValid)
  }

  func testAPositionTravelsInTheFileAndAnUnmovedSceneKeepsTheOldShape() throws {
    let encoder = JSONEncoder()
    let moved = publishedScene(framing: LockScreenFraming(panX: 0.2, panY: 0.8))
    let decoded = try JSONDecoder().decode(LockScreenScene.self, from: encoder.encode(moved))
    XCTAssertEqual(decoded.framing, LockScreenFraming(panX: 0.2, panY: 0.8))
    XCTAssertEqual(decoded, moved)

    // Nothing is written for a scene without a position, so a web page's entry and the
    // file an older extension copy reads stay exactly what they were before.
    let plain = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: encoder.encode(publishedScene())) as? [String: Any])
    XCTAssertNil(plain["framing"])
  }

  func testAMovedPictureReplacesTheRendererButPlaybackSettingsDoNot() {
    let base = publishedScene(framing: LockScreenFraming(panX: 0.2, panY: 0.8))
    var other = base
    other.framing = LockScreenFraming(panX: 0.2, panY: 0.9)
    XCTAssertFalse(base.sharesRenderer(with: other), "the other axis moved")
    other.framing = LockScreenFraming(panX: 0.7, panY: 0.8)
    XCTAssertFalse(base.sharesRenderer(with: other), "one axis moved")
    other.framing = nil
    XCTAssertFalse(base.sharesRenderer(with: other), "back to the middle")
    XCTAssertFalse(publishedScene().sharesRenderer(with: base), "out of the middle")

    // Only the frame rate, the title, the pause and the preview apply to a running renderer.
    other = base
    other.fps = 60
    other.title = "renamed"
    other.paused = true
    other.previewPath = "revisions/a/preview.png"
    XCTAssertTrue(base.sharesRenderer(with: other))
    XCTAssertTrue(other.sharesRenderer(with: base))

    // The renderer reads these when it is built, so a change of any one replaces it.
    let changes: [(String, (inout LockScreenScene) -> Void)] = [
      ("project", { $0.projectPath = "revisions/b/project.json" }),
      ("assets", { $0.assetsPath = "revisions/b" }),
      ("web entry", { $0.webEntryFile = "index.html" }),
      ("properties", { $0.propertiesJSON = #"{"speed":2}"# }),
      ("scaling mode", { $0.scalingMode = 2 }),
      ("scaling factor", { $0.scalingFactor = 1.5 }),
      ("position", { $0.framing = LockScreenFraming(panX: 0, panY: 1) }),
    ]
    for (name, change) in changes {
      var changed = base
      change(&changed)
      XCTAssertFalse(base.sharesRenderer(with: changed), name)
    }
  }

  /// A file without the key and a file that names the middle describe the same
  /// picture, so republishing one for the other must not rebuild the renderer.
  func testNoPositionAndTheMiddleAreTheSamePicture() {
    let unset = publishedScene()
    let middle = publishedScene(framing: LockScreenFraming(panX: 0.5, panY: 0.5))
    XCTAssertTrue(unset.sharesRenderer(with: middle))
    XCTAssertTrue(middle.sharesRenderer(with: unset))
    XCTAssertEqual(unset.effectiveFraming, middle.effectiveFraming)
  }

  func testAPositionOutsideTheRoomIsInvalidInsteadOfDrawnSomewhereElse() {
    for (panX, panY) in [(0.0, 0.0), (1.0, 1.0), (0.5, 0.0), (0.0, 1.0)] {
      XCTAssertTrue(LockScreenFraming(panX: panX, panY: panY).isValid, "\(panX), \(panY)")
    }
    for (panX, panY) in [
      (-0.001, 0.5), (0.5, 1.001), (2, 0.5), (0.5, -1), (.nan, 0.5), (0.5, .nan),
      (.infinity, 0.5), (0.5, -.infinity),
    ] {
      XCTAssertFalse(LockScreenFraming(panX: panX, panY: panY).isValid, "\(panX), \(panY)")
    }
  }

  // MARK: The scene renderer is no longer a choice

  /// A configuration an older app wrote may carry a `sceneRenderer` key naming any of the three old
  /// renderers, or a name nobody knows. The extension reads past it: there is one renderer, so the key
  /// decides nothing and the file is not refused.
  func testAnOldSceneRendererKeyIsReadPastWhateverItNames() throws {
    for name in ["compatibility", "native_metal_preferred", "native_metal_only", "somethingNew"] {
      let json = """
        {"version":2,"revision":"r","lockScreenEnabled":true,"screenSaverEnabled":false,\
        "scenes":[{"displayID":1,"title":"t","projectPath":"revisions/a/project.json",\
        "assetsPath":"revisions/a","fps":30,"scalingMode":3,"scalingFactor":1,"paused":false,\
        "sceneRenderer":"\(name)"}]}
        """
      let configuration = try JSONDecoder().decode(LockScreenConfiguration.self, from: Data(json.utf8))
      XCTAssertEqual(configuration.version, LockScreenConfiguration.supportedVersion, name)
      XCTAssertEqual(configuration.scenes.first, publishedScene(), name)
    }
  }

  func testTheSceneWrittenNowCarriesNoRendererKey() throws {
    let plain = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(publishedScene())) as? [String: Any])
    XCTAssertNil(plain["sceneRenderer"], "there is no renderer to name")
  }

  // MARK: The native video player the extension may use

  func testTheNativeVideoFileTravelsInTheFileAndAnOlderFileKeepsTheOldShape() throws {
    let encoder = JSONEncoder()
    var scene = publishedScene()
    scene.plainVideo = true
    scene.nativeVideoFile = "clip.mp4"
    let decoded = try JSONDecoder().decode(LockScreenScene.self, from: encoder.encode(scene))
    XCTAssertEqual(decoded.nativeVideoFile, "clip.mp4")
    XCTAssertEqual(decoded.plainVideo, true)
    XCTAssertEqual(decoded, scene)
    let plain = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: encoder.encode(publishedScene())) as? [String: Any])
    XCTAssertNil(plain["nativeVideoFile"], "without the choice no key is written")
    XCTAssertNil(plain["plainVideo"], "a scene writes no video key")
    let json = Data(#"{"displayID":1,"title":"t","projectPath":"p","assetsPath":"a","fps":30,"scalingMode":3,"scalingFactor":1,"paused":false}"#.utf8)
    let older = try JSONDecoder().decode(LockScreenScene.self, from: json)
    XCTAssertNil(older.nativeVideoFile)
    XCTAssertNil(older.plainVideo)
  }

  func testBeingAVideoOrNotAndTheFileItPlaysReplaceTheRenderer() {
    let scene = publishedScene()
    var native = scene
    native.plainVideo = true
    native.nativeVideoFile = "clip.mp4"
    XCTAssertFalse(scene.sharesRenderer(with: native))
    XCTAssertFalse(native.sharesRenderer(with: scene))
    var missing = native
    missing.nativeVideoFile = nil
    XCTAssertFalse(native.sharesRenderer(with: missing), "a clip that appeared is played, not held")
    var other = native
    other.nativeVideoFile = "other.mp4"
    XCTAssertFalse(native.sharesRenderer(with: other))
  }

  /// A clip plays at its own rate, so no frame rate decides whether the native player may play
  /// it: a new rate keeps the running player, and the scene engine takes the new rate while it
  /// runs.
  func testANewFrameRateKeepsTheNativePlayerAndTheSceneEngine() {
    var native = publishedScene()
    native.nativeVideoFile = "clip.mp4"
    var faster = native
    faster.fps = 60
    XCTAssertTrue(native.sharesRenderer(with: faster))
    let engine = publishedScene()
    var engineFaster = engine
    engineFaster.fps = 60
    XCTAssertTrue(engine.sharesRenderer(with: engineFaster))
    // Pause and title still apply to a running player.
    var paused = native
    paused.paused = true
    paused.title = "renamed"
    XCTAssertTrue(native.sharesRenderer(with: paused))
  }
}
