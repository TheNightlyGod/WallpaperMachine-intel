import XCTest

@testable import WallpaperMachine

final class LockScreenExtensionRegistrationTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Caches/extension-registration-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: root)
  }

  private func makeApp(_ name: String, identifier: String = "app.wallpapermachine") throws -> URL {
    let app = root.appendingPathComponent(name + ".app")
    let ext = app.appendingPathComponent(LockScreenExtensionRegistration.extensionPath)
    for (bundle, id, executable) in [
      (app, identifier, "WallpaperMachine"),
      (ext, LockScreenConfiguration.extensionIdentifier, "WallpaperMachineExtension"),
    ] {
      let contents = bundle.appendingPathComponent("Contents")
      let binary = contents.appendingPathComponent("MacOS/" + executable)
      try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
      try PropertyListSerialization.data(fromPropertyList: [
        "CFBundleIdentifier": id, "CFBundleExecutable": executable,
        "CFBundlePackageType": bundle.pathExtension == "app" ? "APPL" : "XPC!",
      ], format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
      try Data().write(to: binary)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    }
    return app
  }

  private func registration(
    _ app: URL, registry: Registry, processes: LockScreenExtensionProcesses = .inert,
    timeline: Timeline? = nil
  ) -> LockScreenExtensionRegistration {
    LockScreenExtensionRegistration(
      currentAppURL: app,
      command: { tool, arguments in
        timeline?.add("registry")
        return try await registry.run(tool, arguments)
      },
      processes: processes)
  }

  /// The table's processes, with every signal noted on the timeline next to registry commands.
  private func recording(_ table: FakeExtensionProcessTable, on timeline: Timeline) -> LockScreenExtensionProcesses {
    var processes = table.processes
    let signal = processes.signal
    processes.signal = { process, number in
      timeline.add("signal")
      return signal(process, number)
    }
    return processes
  }

  func testSoleCurrentRegistrationIsIdempotentWithoutMutations() async throws {
    let app = try makeApp("Current")
    let ext = app.appendingPathComponent(LockScreenExtensionRegistration.extensionPath)
    let registry = Registry(paths: [ext])
    let service = registration(app, registry: registry)
    try await service.prepare()
    try await service.prepare()
    let state = await registry.state()
    XCTAssertEqual(state.paths, [ext])
    XCTAssertTrue(state.commands.allSatisfy { $0.arguments.first == "-m" })
  }

  func testOtherCopiesAreUnregisteredButTheirBundlesStayIntact() async throws {
    let app = try makeApp("Release/WallpaperMachine")
    let old = try makeApp("work tree/调试 (copy)/WallpaperMachine")
    let gone = root.appendingPathComponent("Removed.app/" + LockScreenExtensionRegistration.extensionPath)
    let intended = app.appendingPathComponent(LockScreenExtensionRegistration.extensionPath)
    let duplicate = old.appendingPathComponent(LockScreenExtensionRegistration.extensionPath)
    let registry = Registry(paths: [duplicate, gone, intended])
    try await registration(app, registry: registry).prepare()
    let state = await registry.state()
    XCTAssertEqual(state.paths, [intended])
    let mutations = state.commands.filter { $0.arguments.first != "-m" }
    XCTAssertEqual(mutations.prefix(2).map(\.arguments), [["-f", app.path], ["-a", intended.path]])
    XCTAssertEqual(Set(mutations.filter { $0.arguments.first == "-r" }.map { $0.arguments[1] }),
      Set([duplicate.path, gone.path]))
    XCTAssertEqual(mutations.filter { $0.arguments.first == "-u" }.map(\.arguments), [["-u", old.path]])
    XCTAssertTrue(FileManager.default.fileExists(atPath: old.appendingPathComponent("Contents/Info.plist").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: duplicate.appendingPathComponent("Contents/MacOS/WallpaperMachineExtension").path))
    XCTAssertEqual(state.commands.last?.arguments.first, "-m", "Re-query the registry before claiming success")
  }

  func testUnregisteredCurrentAppIsAdded() async throws {
    let app = try makeApp("Current")
    let registry = Registry(paths: [])
    try await registration(app, registry: registry).prepare()
    let state = await registry.state()
    XCTAssertEqual(state.paths, [app.appendingPathComponent(LockScreenExtensionRegistration.extensionPath)])
    XCTAssertFalse(state.commands.contains { ["-r", "-u"].contains($0.arguments[0]) })
  }

  func testParentUnregistrationMayAlreadyRemoveTheExtension() async throws {
    let current = try makeApp("Current")
    let other = try makeApp("Other")
    let registry = Registry(paths: [other.appendingPathComponent(LockScreenExtensionRegistration.extensionPath)],
      failureFlag: "-r", removeWithParent: true)
    try await registration(current, registry: registry).prepare()
    let state = await registry.state()
    XCTAssertEqual(state.paths, [current.appendingPathComponent(LockScreenExtensionRegistration.extensionPath)])
    XCTAssertEqual(state.commands.last?.arguments.first, "-m")
  }

  func testInvalidCurrentBundleCannotUnregisterWorkingCopies() async throws {
    let current = try makeApp("Current", identifier: "unrelated.app")
    let other = try makeApp("Other")
    let registry = Registry(paths: [other.appendingPathComponent(LockScreenExtensionRegistration.extensionPath)])
    do {
      try await registration(current, registry: registry).prepare()
      XCTFail("An invalid current bundle must fail")
    } catch { XCTAssertTrue(error is LockScreenWallpaperFailure) }
    let state = await registry.state()
    XCTAssertTrue(state.commands.isEmpty)
  }

  func testAnUnrelatedBundleAtAStalePathIsNeverUnregistered() async throws {
    let current = try makeApp("Current")
    let other = try makeApp("Other", identifier: "unrelated.app")
    let registry = Registry(paths: [other.appendingPathComponent(LockScreenExtensionRegistration.extensionPath)])
    do {
      try await registration(current, registry: registry).prepare()
      XCTFail("A stale path occupied by another app must fail safely")
    } catch { XCTAssertTrue(error is LockScreenWallpaperFailure) }
    let state = await registry.state()
    XCTAssertTrue(state.commands.allSatisfy { $0.arguments.first == "-m" })
  }

  func testSymlinkAliasOfCurrentBundleIsNotRemoved() async throws {
    let app = try makeApp("Current")
    let alias = root.appendingPathComponent("Alias.app")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: app)
    let registry = Registry(paths: [alias.appendingPathComponent(LockScreenExtensionRegistration.extensionPath)])
    try await registration(app, registry: registry).prepare()
    let state = await registry.state()
    XCTAssertTrue(state.commands.allSatisfy { $0.arguments.first == "-m" })
  }

  func testSuccessfulCommandsDoNotHideAnUnresolvedConflict() async throws {
    let current = try makeApp("Current")
    let other = try makeApp("Other")
    let registry = Registry(paths: [other.appendingPathComponent(LockScreenExtensionRegistration.extensionPath)], ignoreRemoval: true)
    do {
      try await registration(current, registry: registry).prepare()
      XCTFail("The registration must actually converge")
    } catch { XCTAssertTrue(error is LockScreenWallpaperFailure) }
    let state = await registry.state()
    XCTAssertEqual(state.paths.count, 2)
    XCTAssertEqual(state.commands.filter { $0.arguments.first == "-r" }.count, 1, "Do not loop on mutations")
  }

  func testFailureRegisteringCurrentCopyLeavesOthersRegistered() async throws {
    let current = try makeApp("Current")
    let other = try makeApp("Other")
    let ext = other.appendingPathComponent(LockScreenExtensionRegistration.extensionPath)
    let registry = Registry(paths: [ext], failureFlag: "-a")
    do {
      try await registration(current, registry: registry).prepare()
      XCTFail("Registration failure must reach the caller")
    } catch { XCTAssertTrue(error is LockScreenWallpaperFailure) }
    let state = await registry.state()
    XCTAssertEqual(state.paths, [ext])
    XCTAssertFalse(state.commands.contains { ["-r", "-u"].contains($0.arguments[0]) })
  }

  func testCancellationDoesNotRemoveOtherCopiesOrBecomeAUserError() async throws {
    let current = try makeApp("Current")
    let registry = Registry(paths: [], failureFlag: "-a", cancel: true)
    do {
      try await registration(current, registry: registry).prepare()
      XCTFail("Cancellation must propagate")
    } catch { XCTAssertTrue(error is CancellationError) }
    let state = await registry.state()
    XCTAssertFalse(state.commands.contains { ["-r", "-u"].contains($0.arguments[0]) })
  }

  func testPrepareEndsStaleProcessesOnlyAfterTheRegistryConverges() async throws {
    let app = try makeApp("Current")
    let old = try makeApp("Old")
    let intended = app.appendingPathComponent(LockScreenExtensionRegistration.extensionPath)
    let oldExtension = old.appendingPathComponent(LockScreenExtensionRegistration.extensionPath)

    // Once through the idempotent early return and once through a real reconciliation.
    for registered in [[intended], [oldExtension]] {
      let timeline = Timeline()
      let table = FakeExtensionProcessTable([
        FakeExtensionProcessTable.process(1, bundle: oldExtension.path),
        FakeExtensionProcessTable.process(2, bundle: intended.path),
      ])
      let registry = Registry(paths: registered)
      try await registration(app, registry: registry, processes: recording(table, on: timeline), timeline: timeline)
        .prepare()

      // Only the process of the other copy goes: the intended copy's own helper is untouched,
      // which also shows the intended extension, not the app, was the copy kept.
      XCTAssertEqual(table.signals, [.init(pid: 1, number: SIGTERM)])
      let events = timeline.events
      XCTAssertGreaterThan(
        try XCTUnwrap(events.firstIndex(of: "signal")), try XCTUnwrap(events.lastIndex(of: "registry")),
        "A process may only be ended after the registry was confirmed to name the intended copy")
      let state = await registry.state()
      XCTAssertEqual(state.paths, [intended])
    }
  }

  func testPrepareEndsTheHelperOfAnUpdatedAppThatNoLongerHasFiles() async throws {
    // The in-app updater replaces the app and deletes the old copy, so its helper keeps
    // running with no path. It goes because it runs another build than the registered one.
    let app = try makeApp("Current")
    let intended = app.resolvingSymlinksInPath().standardizedFileURL
      .appendingPathComponent(LockScreenExtensionRegistration.extensionPath)
    let old = UUID()
    let current = UUID()
    let table = FakeExtensionProcessTable([
      FakeExtensionProcessTable.deletedProcess(1, image: old),
      FakeExtensionProcessTable.deletedProcess(2, image: current),
    ])
    table.setImages([current], for: LockScreenExtensionProcesses.executable(in: intended))
    try await registration(app, registry: Registry(paths: [intended]), processes: table.processes).prepare()
    XCTAssertEqual(table.signals, [.init(pid: 1, number: SIGTERM)])
  }

  func testFailedRegistrationNeverTerminatesAnything() async throws {
    let current = try makeApp("Current")
    let invalid = try makeApp("Invalid", identifier: "unrelated.app")
    let other = try makeApp("Other")
    let otherExtension = other.appendingPathComponent(LockScreenExtensionRegistration.extensionPath)
    let cases: [(String, URL, Registry)] = [
      ("invalid current bundle", invalid, Registry(paths: [otherExtension])),
      ("unresolved conflict", current, Registry(paths: [otherExtension], ignoreRemoval: true)),
      ("cancellation", current, Registry(paths: [], failureFlag: "-a", cancel: true)),
      ("command failure", current, Registry(paths: [], failureFlag: "-a")),
    ]
    for (name, app, registry) in cases {
      let table = FakeExtensionProcessTable([
        FakeExtensionProcessTable.process(1, bundle: otherExtension.path)
      ])
      do {
        try await registration(app, registry: registry, processes: table.processes).prepare()
        XCTFail("\(name) must fail")
      } catch {}
      XCTAssertTrue(table.signals.isEmpty, name)
      XCTAssertEqual(table.lists, 0, "\(name): the process table must not even be read")
    }
  }

  func testDiscoveryParsesVersionsFlagsSpacesAndUnicodeWithoutDroppingCopies() throws {
    let paths = ["/Applications/WallpaperMachine.app", "/a b/调试 (new).app"].map {
      URL(fileURLWithPath: $0 + "/" + LockScreenExtensionRegistration.extensionPath)
    }
    let output = Registry.output(paths).replacingOccurrences(of: "     app.", with: "=    app.")
      .replacingOccurrences(of: "(1.2.5)", with: "(99.2.5)")
    XCTAssertEqual(Set(try LockScreenExtensionRegistration.parseRecords(output).map(\.url)), Set(paths))
    XCTAssertEqual(try LockScreenExtensionRegistration.parseRecords("  (no matches)\n"), [])
    XCTAssertEqual(
      try LockScreenExtensionRegistration.parseRecords(Registry.output([paths[0]])).map(\.url), [paths[0]])
  }

  func testEmptyTruncatedAndForeignDiscoveryOutputIsRejected() throws {
    let output = Registry.output([URL(fileURLWithPath: "/Applications/A.app/" + LockScreenExtensionRegistration.extensionPath)])
    for invalid in ["", "pkd unavailable", output.replacingOccurrences(of: " (1 plug-in)\n", with: ""),
      output.replacingOccurrences(of: "(1 plug-in)", with: "(2 plug-ins)"),
      output.replacingOccurrences(of: LockScreenConfiguration.extensionIdentifier, with: "unrelated.extension")] {
      XCTAssertThrowsError(try LockScreenExtensionRegistration.parseRecords(invalid))
    }
  }

  func testElectionMarksAreParsedAndOnlyIgnoredBlocksActivation() async throws {
    let app = try makeApp("Current")
    let ext = app.appendingPathComponent(LockScreenExtensionRegistration.extensionPath)
    let other = try makeApp("Other")
    let otherExt = other.appendingPathComponent(LockScreenExtensionRegistration.extensionPath)

    // Every mark pluginkit(8) can print, with spaces and Unicode in the path.
    let spaced = URL(fileURLWithPath: "/a b/调试 (new).app/" + LockScreenExtensionRegistration.extensionPath)
    let marks: [(Character, LockScreenExtensionRegistration.Mark)] = [
      (" ", .blank), ("+", .elected), ("-", .ignored), ("=", .superseded), ("!", .debugger), ("?", .unknown),
    ]
    for (character, mark) in marks {
      let records = try LockScreenExtensionRegistration.parseRecords(
        Registry.output([spaced], marks: [spaced.path: character]))
      XCTAssertEqual(records, [.init(url: spaced, mark: mark)], "mark \(character)")
    }
    // `-A` lists every version at one path. A superseded older one does not hide the current
    // one's election, and versions that disagree are not treated as ignored.
    func versions(_ older: Character, _ newer: Character) throws -> [LockScreenExtensionRegistration.Mark] {
      let line = { (mark: Character, version: String) in
        "\(mark)    \(LockScreenConfiguration.extensionIdentifier)(\(version))\t855441FD-9FFC-4FAA-A50F-5F5B50701AFD\t2026-10-05 06:06:07 +0000\t\(spaced.path)\n"
      }
      return try LockScreenExtensionRegistration.parseRecords(
        line(older, "1.2.4") + line(newer, "1.2.5") + " (2 plug-ins)\n").map(\.mark)
    }
    XCTAssertEqual(try versions("-", "-"), [.ignored])
    XCTAssertEqual(try versions("=", "-"), [.ignored])
    XCTAssertEqual(try versions("=", "="), [.superseded])
    XCTAssertEqual(try versions("-", " "), [.unknown])

    // Only an ignore on this app's copy stops activation; the normal blank state and every
    // other mark let it through.
    for (character, mark) in marks {
      let registry = Registry(paths: [ext], marks: [ext: character])
      do {
        try await registration(app, registry: registry).prepare()
        XCTAssertNotEqual(mark, .ignored, "an ignored renderer must stop activation")
      } catch let failure as LockScreenWallpaperFailure {
        XCTAssertEqual(mark, .ignored, "mark \(character) must not stop activation")
        XCTAssertEqual(failure.reason, .extensionTurnedOff)
        XCTAssertFalse(failure.message.isEmpty)
      }
      let state = await registry.state()
      XCTAssertTrue(state.commands.allSatisfy { $0.arguments.first == "-m" }, "reading never changes an election")
    }

    // The same through a reconciliation that registers this copy and removes another one,
    // and through a renderer that was never registered here.
    let converging = Registry(paths: [otherExt], marks: [otherExt: "-", ext: "-"])
    do {
      try await registration(app, registry: converging).prepare()
      XCTFail("An ignored renderer must stop activation after reconciling")
    } catch let failure as LockScreenWallpaperFailure {
      XCTAssertEqual(failure.reason, .extensionTurnedOff)
    }
    var state = await converging.state()
    XCTAssertEqual(state.paths, [ext], "Registration still converges before the election is judged")
    XCTAssertFalse(state.commands.contains { $0.arguments.first == "-e" })

    // Another copy being ignored is not this app's problem.
    let neighbour = Registry(paths: [ext, otherExt], marks: [otherExt: "-"])
    try await registration(app, registry: neighbour).prepare()
    state = await neighbour.state()
    XCTAssertEqual(state.paths, [ext])
  }

  func testAnIgnoredRendererEndsNoProcesses() async throws {
    let app = try makeApp("Current")
    let ext = app.appendingPathComponent(LockScreenExtensionRegistration.extensionPath)
    let table = FakeExtensionProcessTable([FakeExtensionProcessTable.process(1, bundle: "/gone/Other.appex")])
    let registry = Registry(paths: [ext], marks: [ext: "-"])
    do {
      try await registration(app, registry: registry, processes: table.processes).prepare()
      XCTFail("An ignored renderer must stop activation")
    } catch let failure as LockScreenWallpaperFailure {
      XCTAssertEqual(failure.reason, .extensionTurnedOff)
    }
    XCTAssertTrue(table.signals.isEmpty, "Nothing is ended for a renderer macOS will not run")
    XCTAssertEqual(table.lists, 0)
  }

  func testEnableExtensionRunsOneElectionCommandAndVerifiesIt() async throws {
    let app = try makeApp("Current")
    let ext = app.appendingPathComponent(LockScreenExtensionRegistration.extensionPath)
    let registry = Registry(paths: [ext], marks: [ext: "-"])
    let service = registration(app, registry: registry)
    try await service.enableExtension()
    var state = await registry.state()
    XCTAssertEqual(
      state.commands.filter { $0.arguments.first == "-e" }.map(\.arguments),
      [["-e", "use", "-i", LockScreenConfiguration.extensionIdentifier]])
    XCTAssertEqual(state.commands.last?.arguments.first, "-m", "The result is read back from the registry")
    try await service.prepare()

    // A renderer macOS keeps ignoring is reported, not claimed as repaired.
    let stubborn = Registry(paths: [ext], marks: [ext: "-"], electionSticks: true)
    do {
      try await registration(app, registry: stubborn).enableExtension()
      XCTFail("A renderer that stays ignored must fail")
    } catch let failure as LockScreenWallpaperFailure {
      XCTAssertEqual(failure.reason, .extensionTurnedOff)
    }
    state = await stubborn.state()
    XCTAssertEqual(state.commands.filter { $0.arguments.first == "-e" }.count, 1)

    // A refused command fails the same way instead of the generic registration error.
    let refused = Registry(paths: [ext], marks: [ext: "-"], failureFlag: "-e")
    do {
      try await registration(app, registry: refused).enableExtension()
      XCTFail("A refused election command must fail")
    } catch let failure as LockScreenWallpaperFailure {
      XCTAssertEqual(failure.reason, .extensionTurnedOff)
    }
  }

  func testEnableExtensionLeavesAnElectionAloneUnlessThisCopyIsIgnored() async throws {
    let app = try makeApp("Current")
    let other = try makeApp("Other")
    let ext = app.appendingPathComponent(LockScreenExtensionRegistration.extensionPath)
    let otherExt = other.appendingPathComponent(LockScreenExtensionRegistration.extensionPath)
    for registry in [
      Registry(paths: [ext]), Registry(paths: [ext], marks: [ext: "+"]),
      Registry(paths: [ext, otherExt], marks: [otherExt: "-"]), Registry(paths: []),
    ] {
      try await registration(app, registry: registry).enableExtension()
      let state = await registry.state()
      XCTAssertTrue(state.commands.allSatisfy { $0.arguments.first == "-m" }, "no election was asked to change")
    }
  }

  private final class Timeline: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var events: [String] { lock.withLock { recorded } }
    func add(_ event: String) { lock.withLock { recorded.append(event) } }
  }

  private actor Registry {
    struct Command { var tool: String; var arguments: [String] }
    private var paths: [URL]
    private var marks: [String: Character]
    private var commands: [Command] = []
    private let ignoreRemoval: Bool
    private let failureFlag: String?
    private let cancel: Bool
    private let removeWithParent: Bool
    private let electionSticks: Bool

    /// `marks` are the election marks pluginkit prints in column 0 (blank when absent);
    /// `electionSticks` makes `-e use` change nothing, like a refused election.
    init(paths: [URL], marks: [URL: Character] = [:], ignoreRemoval: Bool = false,
      failureFlag: String? = nil, cancel: Bool = false, removeWithParent: Bool = false,
      electionSticks: Bool = false) {
      self.paths = paths
      self.marks = Dictionary(uniqueKeysWithValues: marks.map { ($0.key.path, $0.value) })
      self.ignoreRemoval = ignoreRemoval
      self.failureFlag = failureFlag
      self.cancel = cancel
      self.removeWithParent = removeWithParent
      self.electionSticks = electionSticks
    }

    func state() -> (paths: [URL], commands: [Command]) { (paths, commands) }

    func run(_ tool: URL, _ arguments: [String]) throws -> String {
      commands.append(Command(tool: tool.lastPathComponent, arguments: arguments))
      if arguments.first == failureFlag {
        if cancel { throw CancellationError() }
        throw NSError(domain: "registration-command", code: 1)
      }
      switch (tool.lastPathComponent, arguments[0]) {
      case ("pluginkit", "-m"): return Self.output(paths, marks: marks)
      case ("pluginkit", "-a"):
        let url = URL(fileURLWithPath: arguments[1])
        if !paths.contains(url) { paths.append(url) }
      case ("pluginkit", "-r"):
        if !ignoreRemoval { paths.removeAll { $0.path == arguments[1] } }
      case ("pluginkit", "-e"):
        XCTAssertEqual(arguments, ["-e", "use", "-i", LockScreenConfiguration.extensionIdentifier])
        if !electionSticks { for path in paths { marks[path.path] = "+" } }
      case ("lsregister", "-u"):
        if removeWithParent { paths.removeAll { $0.path.hasPrefix(arguments[1] + "/") } }
      case ("lsregister", "-f"): break
      default: XCTFail("Unexpected mutation: \(tool.path) \(arguments)")
      }
      return ""
    }

    /// `marks` are keyed by path.
    nonisolated static func output(_ paths: [URL], marks: [String: Character] = [:]) -> String {
      if paths.isEmpty { return "  (no matches)\n" }
      return paths.map {
        "\(marks[$0.path] ?? " ")    \(LockScreenConfiguration.extensionIdentifier)(1.2.5)\t855441FD-9FFC-4FAA-A50F-5F5B50701AFD\t2026-10-05 06:06:07 +0000\t\($0.path)\n"
      }.joined() + " (\(paths.count) plug-in\(paths.count == 1 ? "" : "s"))\n"
    }
  }
}
