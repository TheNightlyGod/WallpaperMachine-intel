import XCTest
@testable import WallpaperMachine

/// A command given while another runs must wait its turn, never fail for being early; only
/// the latest of several waiting switches is carried out; and a switch the app makes on its
/// own never replaces one the user is waiting on.
@MainActor
final class UserCommandQueueTests: XCTestCase {
    func testCommandsGivenWhileBusyRunInArrivalOrder() async throws {
        let queue = UserCommandQueue()
        let log = Log()
        let gate = Gate()
        let first = Task { try await queue.run { log.add("first"); await gate.wait(); log.add("first done") } }
        await until { queue.isBusy }
        let second = Task { try await queue.run { log.add("second") } }
        await until { queue.waiting.count == 1 }
        let third = Task { try await queue.run { log.add("third") } }
        await until { queue.waiting.count == 2 }
        XCTAssertEqual(log.entries, ["first"], "Nothing may start while a command runs")

        gate.open()
        let ran = try await [first.value, second.value, third.value]

        XCTAssertEqual(ran, [true, true, true])
        XCTAssertEqual(log.entries, ["first", "first done", "second", "third"])
        XCTAssertFalse(queue.isBusy)
    }

    func testNewerCommandInSameSlotReplacesOneStillWaiting() async throws {
        let queue = UserCommandQueue()
        let log = Log()
        let gate = Gate()
        let running = Task { try await queue.run(slot: "activate:1", subject: "a") { await gate.wait(); log.add("a") } }
        await until { queue.isBusy }
        let replaced = Task { try await queue.run(slot: "activate:1", subject: "b") { log.add("b") } }
        await until { queue.waiting.count == 1 }
        let other = Task { try await queue.run(slot: "activate:2", subject: "x") { log.add("x") } }
        await until { queue.waiting.count == 2 }
        let latest = Task { try await queue.run(slot: "activate:1", subject: "c") { log.add("c") } }
        await until { queue.waiting.map(\.subject) == ["x", "c"] }

        let replacedRan = try await replaced.value
        XCTAssertFalse(replacedRan, "A replaced switch reports that it did not run, without an error")
        gate.open()
        let ran = try await [running.value, other.value, latest.value]

        XCTAssertEqual(ran, [true, true, true])
        XCTAssertEqual(log.entries, ["a", "x", "c"],
                       "The running switch finishes; another display's switch keeps its place; the latest joins the back")
    }

    func testAutomaticCommandNeverReplacesAWaitingUserCommand() async throws {
        let queue = UserCommandQueue()
        let log = Log()
        let gate = Gate()
        let running = Task { try await queue.run(slot: "activate:1", subject: "a") { await gate.wait(); log.add("a") } }
        await until { queue.isBusy }
        let chosen = Task { try await queue.run(slot: "activate:1", subject: "chosen") { log.add("chosen") } }
        await until { queue.waiting.count == 1 }

        // The queue stays held open: a command that has to wait for the gate would hang here.
        for origin in [ActivationOrigin.playlist, .automation, .updateReload, .layout] {
            let ran = try await queue.run(slot: "activate:1", subject: "automatic", origin: origin) { log.add("automatic") }
            XCTAssertFalse(ran, "\(origin) must give way at once to a choice the user is waiting on")
        }
        XCTAssertEqual(queue.waiting.map(\.subject), ["chosen"], "The user's choice keeps its place")

        gate.open()
        let ran = try await [running.value, chosen.value]
        XCTAssertEqual(ran, [true, true])
        XCTAssertEqual(log.entries, ["a", "chosen"])
    }

    /// The user's Apply is already running, so the playlist that comes due meanwhile does not
    /// wait behind it: it would then replace the wallpaper the Apply just put on the display.
    func testAutomaticCommandNeverFollowsAUserCommandThatIsRunning() async throws {
        let queue = UserCommandQueue()
        let log = Log()
        let gate = Gate()
        let chosen = Task { try await queue.run(slot: "activate:1", subject: "chosen") { await gate.wait(); log.add("chosen") } }
        await until { queue.isBusy }
        let before = queue.revision(for: "activate:1")

        for origin in [ActivationOrigin.playlist, .automation, .updateReload, .layout] {
            let ran = try await queue.run(slot: "activate:1", subject: "automatic", origin: origin) { log.add("automatic") }
            XCTAssertFalse(ran, "\(origin) must give way at once to a choice that is running")
        }
        XCTAssertTrue(queue.waiting.isEmpty, "Nothing is left to run behind the choice")
        XCTAssertEqual(queue.revision(for: "activate:1"), before, "Giving way leaves no trace in the slot")

        gate.open()
        _ = try await chosen.value
        XCTAssertEqual(log.entries, ["chosen"])

        let later = try await queue.run(slot: "activate:1", subject: "later", origin: .playlist) { log.add("later") }
        XCTAssertTrue(later, "Once the choice is done the slot is free again")
        XCTAssertEqual(log.entries, ["chosen", "later"])
    }

    func testAutomaticCommandStillWaitsBehindACommandThatIsNotTheUsersChoiceInItsSlot() async throws {
        let queue = UserCommandQueue()
        let log = Log()
        let gate = Gate()
        // Another display's choice, a setting and an automatic change of this display's own.
        let running = Task { try await queue.run(slot: "activate:2") { await gate.wait(); log.add("other display") } }
        await until { queue.isBusy }
        let rotation = Task { try await queue.run(slot: "activate:1", subject: "rotation", origin: .playlist) { log.add("rotation") } }
        await until { queue.waiting.count == 1 }

        gate.open()
        let ran = try await [running.value, rotation.value]

        XCTAssertEqual(ran, [true, true])
        XCTAssertEqual(log.entries, ["other display", "rotation"])
    }

    /// A choice that waited behind another command is running from the moment it is handed the
    /// queue, before its task gets to run, so an automatic command cannot slip in between.
    func testAChoiceHandedTheQueueIsAlreadyRunningForAutomaticCommands() async throws {
        let queue = UserCommandQueue()
        let log = Log()
        let first = Gate()
        let second = Gate()
        let blocker = Task { try await queue.run { await first.wait() } }
        await until { queue.isBusy }
        let chosen = Task { try await queue.run(slot: "activate:1", subject: "chosen") { await second.wait(); log.add("chosen") } }
        await until { queue.waiting.count == 1 }

        first.open()
        _ = try await blocker.value
        // The choice left the waiting list when the blocker finished; it is running now.
        XCTAssertTrue(queue.waiting.isEmpty)
        let ran = try await queue.run(slot: "activate:1", origin: .playlist) { log.add("rotation") }
        XCTAssertFalse(ran)

        second.open()
        _ = try await chosen.value
        XCTAssertEqual(log.entries, ["chosen"])
    }

    /// A layout, copy, swap or apply to all displays has no slot of its own but is the user's
    /// choice for each display it names, from the moment it is asked for until it is done.
    func testAnAutomaticCommandGivesWayToAChoiceCoveringItsSlotWhileItWaitsAndWhileItRuns() async throws {
        let queue = UserCommandQueue()
        let log = Log()
        let blocking = Gate()
        let covering = Gate()
        let blocker = Task { try await queue.run { await blocking.wait() } }
        await until { queue.isBusy }
        let layout = Task {
            try await queue.run(choosing: ["activate:1", "activate:2"]) { await covering.wait(); log.add("layout") }
        }
        await until { queue.waiting.count == 1 }
        XCTAssertEqual(["activate:1", "activate:2", "activate:3"].map(queue.userRevision(for:)), [1, 1, 0],
                       "it is the user's choice in the slots it names from the moment it is asked for")

        for slot in ["activate:1", "activate:2"] {
            let waitingRan = try await queue.run(slot: slot, origin: .playlist) { log.add("rotation \(slot)") }
            XCTAssertFalse(waitingRan, "\(slot) gives way to a layout that waits")
        }
        let other = Task { try await queue.run(slot: "activate:3", subject: "other", origin: .playlist) { log.add("rotation 3") } }
        await until { queue.waiting.count == 2 }

        blocking.open()
        _ = try await blocker.value
        await until { queue.waiting.map(\.subject) == ["other"] }
        let runningRan = try await queue.run(slot: "activate:2", origin: .automation) { log.add("rule") }
        XCTAssertFalse(runningRan, "and to the layout that runs")

        covering.open()
        let ran = try await [layout.value, other.value]
        XCTAssertEqual(ran, [true, true])
        XCTAssertEqual(log.entries, ["layout", "rotation 3"], "a display the layout does not name is not held back")
        XCTAssertEqual(queue.userRevision(for: "activate:1"), 1, "the layout counts once, not once more when it runs")
    }

    func testAutomaticCommandForAnotherDisplayIsNotAffectedByAWaitingUserCommand() async throws {
        let queue = UserCommandQueue()
        let log = Log()
        let gate = Gate()
        let running = Task { try await queue.run(slot: "activate:1") { await gate.wait() } }
        await until { queue.isBusy }
        let chosen = Task { try await queue.run(slot: "activate:1", subject: "chosen") { log.add("chosen") } }
        await until { queue.waiting.count == 1 }
        let other = Task { try await queue.run(slot: "activate:2", subject: "rotation", origin: .playlist) { log.add("rotation") } }
        await until { queue.waiting.count == 2 }

        gate.open()
        let ran = try await [running.value, chosen.value, other.value]

        XCTAssertEqual(ran, [true, true, true])
        XCTAssertEqual(log.entries, ["chosen", "rotation"])
    }

    func testUserCommandReplacesAWaitingAutomaticCommand() async throws {
        let queue = UserCommandQueue()
        let log = Log()
        let gate = Gate()
        let running = Task { try await queue.run(subject: "a") { await gate.wait(); log.add("a") } }
        await until { queue.isBusy }
        let rotation = Task { try await queue.run(slot: "activate:1", subject: "rotation", origin: .playlist) { log.add("rotation") } }
        await until { queue.waiting.count == 1 }
        let chosen = Task { try await queue.run(slot: "activate:1", subject: "chosen") { log.add("chosen") } }
        await until { queue.waiting.map(\.subject) == ["chosen"] }

        let rotationRan = try await rotation.value
        XCTAssertFalse(rotationRan)
        gate.open()
        let ran = try await [running.value, chosen.value]

        XCTAssertEqual(ran, [true, true])
        XCTAssertEqual(log.entries, ["a", "chosen"])
    }

    func testAutomaticCommandReplacesAnOlderAutomaticOne() async throws {
        let queue = UserCommandQueue()
        let log = Log()
        let gate = Gate()
        let running = Task { try await queue.run { await gate.wait() } }
        await until { queue.isBusy }
        let older = Task { try await queue.run(slot: "activate:1", subject: "older", origin: .automation) { log.add("older") } }
        await until { queue.waiting.count == 1 }
        let newer = Task { try await queue.run(slot: "activate:1", subject: "newer", origin: .playlist) { log.add("newer") } }
        await until { queue.waiting.map(\.subject) == ["newer"] }

        let olderRan = try await older.value
        XCTAssertFalse(olderRan)
        gate.open()
        let ran = try await [running.value, newer.value]

        XCTAssertEqual(ran, [true, true])
        XCTAssertEqual(log.entries, ["newer"])
    }

    func testYieldedAutomaticCommandDoesNotAdvanceTheSlotRevision() async throws {
        let queue = UserCommandQueue()
        let gate = Gate()
        let running = Task { try await queue.run(slot: "activate:1") { await gate.wait() } }
        await until { queue.isBusy }
        let chosen = Task { try await queue.run(slot: "activate:1", subject: "chosen") {} }
        await until { queue.waiting.count == 1 }
        let before = queue.revision(for: "activate:1")

        let ran = try await queue.run(slot: "activate:1", origin: .playlist) {}

        XCTAssertFalse(ran)
        XCTAssertEqual(queue.revision(for: "activate:1"), before,
                       "Work watching the slot must not read a command that gave way as newer intent")
        gate.open()
        _ = try await [running.value, chosen.value]
    }

    func testUserRevisionCountsOnlyUserCommands() async throws {
        let queue = UserCommandQueue()
        XCTAssertEqual(queue.userRevision(for: "activate:1"), 0)

        try await queue.run(slot: "activate:1") {}
        XCTAssertEqual(queue.userRevision(for: "activate:1"), 1)

        try await queue.run(slot: "activate:1", origin: .playlist) {}
        try await queue.run(slot: "activate:1", origin: .updateReload) {}
        XCTAssertEqual(queue.userRevision(for: "activate:1"), 1, "Automatic changes are not the user choosing again")
        XCTAssertEqual(queue.revision(for: "activate:1"), 3, "The slot revision still counts every command that ran")

        try await queue.run(slot: "activate:2") {}
        XCTAssertEqual(queue.userRevision(for: "activate:1"), 1)
        XCTAssertEqual(queue.userRevision(for: "activate:2"), 1)
    }

    func testANotedChoiceCountsInEachNamedSlotOnceAndRunsNothing() async throws {
        let queue = UserCommandQueue()
        let gate = Gate()
        let running = Task { try await queue.run(slot: "activate:1") { await gate.wait() } }
        await until { queue.isBusy }
        let waiting = Task { try await queue.run(slot: "activate:1", subject: "waiting") {} }
        await until { queue.waiting.count == 1 }
        let before = queue.userRevision(for: "activate:1")
        let slotRevision = queue.revision(for: "activate:1")

        queue.noteUserChoice(in: ["activate:1", "activate:2", "activate:2"])

        XCTAssertEqual(queue.userRevision(for: "activate:1"), before + 1)
        XCTAssertEqual(queue.userRevision(for: "activate:2"), 1, "A slot named twice is one choice")
        XCTAssertEqual(queue.userRevision(for: "activate:3"), 0)
        XCTAssertEqual(queue.revision(for: "activate:1"), slotRevision, "No command ran, so the slot's own count stays")
        XCTAssertEqual(queue.waiting.map(\.subject), ["waiting"], "Noting a choice replaces nothing that waits")
        gate.open()
        _ = try await [running.value, waiting.value]
    }

    func testFailedCommandStillHandsOverToTheNext() async throws {
        let queue = UserCommandQueue()
        let log = Log()
        let gate = Gate()
        let failing = Task {
            try await queue.run {
                await gate.wait()
                throw WallpaperActionError(message: "boom")
            }
        }
        await until { queue.isBusy }
        let next = Task { try await queue.run { log.add("next") } }
        await until { queue.waiting.count == 1 }

        gate.open()
        do {
            _ = try await failing.value
            XCTFail("The failure belongs to the command that failed")
        } catch {}
        _ = try await next.value

        XCTAssertEqual(log.entries, ["next"])
        XCTAssertFalse(queue.isBusy)
    }
}

@MainActor
private final class Log {
    private(set) var entries: [String] = []
    func add(_ entry: String) { entries.append(entry) }
}

@MainActor
private final class Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume() }
    }
}

/// Lets other main-actor tasks run until `condition` holds; fails the test if it never does.
@MainActor
private func until(
    _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line
) async {
    for _ in 0..<1_000 {
        if condition() { return }
        await Task.yield()
    }
    XCTFail("Condition never became true", file: file, line: line)
}
