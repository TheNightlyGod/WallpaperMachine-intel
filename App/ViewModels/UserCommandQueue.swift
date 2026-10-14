import Observation

/// Runs the user's commands one at a time, in the order they arrive.
///
/// A command given while another runs waits its turn instead of failing: being busy is a
/// state the panel shows, never an error. Commands that share a `slot` want only their
/// latest request carried out — switching wallpapers, selecting one to inspect — so a
/// newer one in the same slot drops any that are still waiting and joins the back of the
/// line. The one already running always finishes.
///
/// Not every command in a slot is the user's. A playlist, an automatic rule or an update
/// reload gives its `origin`, and such a command never replaces a choice of the user's in its
/// slot, whether that choice is waiting or already running: it gives way at once, and the
/// user's choice runs, or finishes, as the last word. Joining the line behind a running
/// choice would let the automatic change replace what the user just got.
@MainActor
@Observable
final class UserCommandQueue {
    struct Waiting: Equatable {
        let slot: String?
        /// What the waiting command acts on, for the panel to mark; nil when unknown.
        let subject: String?
    }

    /// What a command is, as far as the slots it acts on go.
    private struct Claim {
        let slot: String?
        let origin: ActivationOrigin
        /// The slots a command with no slot of its own is the user's choice for.
        let choosing: [String]

        func covers(_ other: String) -> Bool { slot == other || choosing.contains(other) }
        func isChoice(for other: String) -> Bool { origin.isUserChoice && covers(other) }
    }

    private struct Waiter {
        let claim: Claim
        let subject: String?
        let continuation: CheckedContinuation<Bool, Never>
        var slot: String? { claim.slot }
    }

    private(set) var isBusy = false
    private var waiters: [Waiter] = []
    /// The command that holds `isBusy`: set when a command is handed the queue, not when its
    /// task gets to run, so there is no moment a running choice goes unseen.
    private var running: Claim?
    private var slotRevisions: [String: UInt64] = [:]
    private var userSlotRevisions: [String: UInt64] = [:]

    /// Also advances for a waiting command that was replaced. Background retries use this
    /// to yield to a newer intent even after that intent has left the waiting list. A
    /// command that gave way to a waiting user choice does not advance it.
    func revision(for slot: String) -> UInt64 { slotRevisions[slot] ?? 0 }

    /// Advances only for the user's own commands in `slot`, and for choices noted with
    /// `noteUserChoice`. Work that outlives one command and must not act after the user has
    /// chosen something else compares this, so an automatic change in the same slot does not
    /// cancel it.
    func userRevision(for slot: String) -> UInt64 { userSlotRevisions[slot] ?? 0 }

    /// Counts a choice of the user's in each of `slots` without running a command there. A
    /// choice is made when it is asked for, but some are carried out later, or by a command
    /// that has no slot of its own, such as a layout covering several displays; work waiting
    /// on `userRevision` has to see them like any other choice.
    func noteUserChoice(in slots: [String]) {
        for slot in Set(slots) { userSlotRevisions[slot, default: 0] &+= 1 }
    }

    /// Commands waiting behind the running one, oldest first.
    var waiting: [Waiting] { waiters.map { Waiting(slot: $0.slot, subject: $0.subject) } }

    func hasWaiting(slot: String) -> Bool { waiters.contains { $0.slot == slot } }

    /// Runs `operation` once every earlier command has finished. Returns false without
    /// running it when a newer command in the same `slot` replaced it while it waited, or,
    /// for a command that is not the user's, when the user already has a choice waiting or
    /// running there.
    ///
    /// `choosing` names the slots a user command with no slot of its own acts on, such as a
    /// layout giving wallpapers to several displays. It is the user's choice in each of them
    /// from the moment it is asked for (as `noteUserChoice` counts it), and an automatic
    /// command for one of them gives way to it while it waits and while it runs.
    @discardableResult
    func run(
        slot: String? = nil, subject: String? = nil, origin: ActivationOrigin = .user,
        choosing: [String] = [],
        _ operation: @MainActor () async throws -> Void
    ) async rethrows -> Bool {
        let claim = Claim(slot: slot, origin: origin, choosing: choosing)
        if origin.isUserChoice { noteUserChoice(in: choosing) }
        if let slot {
            // Decided before the revision moves, so a command that gave way leaves no trace
            // for anything watching the slot.
            if !origin.isUserChoice, holdsUserChoice(in: slot) {
                AppLog.info("activation yielded to a user choice: \(slot), \(origin.rawValue)"
                    + (subject.map { ", \($0)" } ?? ""))
                return false
            }
            slotRevisions[slot, default: 0] &+= 1
            if origin.isUserChoice { userSlotRevisions[slot, default: 0] &+= 1 }
            supersede(slot: slot, by: origin)
        }
        if isBusy {
            let admitted = await withCheckedContinuation { continuation in
                waiters.append(Waiter(claim: claim, subject: subject, continuation: continuation))
            }
            // The finishing command handed `isBusy` over without clearing it.
            guard admitted else { return false }
        } else {
            isBusy = true
            running = claim
        }
        defer { advance() }
        try await operation()
        return true
    }

    /// Whether the user has a choice in `slot`, waiting for its turn or running.
    private func holdsUserChoice(in slot: String) -> Bool {
        if let running, running.isChoice(for: slot) { return true }
        return waiters.contains { $0.claim.isChoice(for: slot) }
    }

    /// The user's newer command drops every command still waiting in its slot; an automatic
    /// one drops only older automatic ones, never a command the user is waiting on.
    private func supersede(slot: String, by origin: ActivationOrigin) {
        let replaces: (Waiter) -> Bool = { $0.slot == slot && (origin.isUserChoice || !$0.claim.origin.isUserChoice) }
        let replaced = waiters.filter(replaces)
        guard !replaced.isEmpty else { return }
        waiters.removeAll(where: replaces)
        for waiter in replaced { waiter.continuation.resume(returning: false) }
    }

    private func advance() {
        guard !waiters.isEmpty else {
            isBusy = false
            running = nil
            return
        }
        let next = waiters.removeFirst()
        running = next.claim
        next.continuation.resume(returning: true)
    }
}
