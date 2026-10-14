import CoreMedia
import XCTest

@testable import WallpaperMachine

/// When a health check runs, how long it samples, what it reports and how it
/// repairs, against a scripted target and a hand-fired clock. No player, no
/// media, no real waiting.
@MainActor
final class NativeVideoHealthSupervisorTests: XCTestCase {
    /// A short window keeps the drive loops small: settle, then five samples
    /// four steps apart, and ten after a rebuild.
    private let policy = NativeVideoHealthSupervisor.Policy(
        minimumPause: .seconds(5), settle: .milliseconds(500), window: .milliseconds(500),
        step: .milliseconds(100), rebuildWindow: .seconds(1))

    private let sleeper = ManualSleeper()
    private let item = NSObject()

    /// What the scripted pipeline looks like.
    private enum Pipeline {
        /// Pictures arrive and the clock moves.
        case healthy
        /// The clock moves and no picture comes: a dead decoder.
        case clockOnly
        /// The player says it is waiting for data.
        case waiting
        /// There is nothing to sample.
        case empty
    }

    @MainActor
    private final class FakeTarget: NativeVideoHealthTarget {
        var isEligibleForCheck = true
        var pipeline: Pipeline
        private let render: (Pipeline, Int) -> NativeVideoLivenessEvaluator.Sample?
        private(set) var sampled = 0
        private(set) var finished = 0
        private(set) var events: [NativeVideoHealthEvent] = []
        /// Everything the supervisor did to this target, in order, with the
        /// reports among it: the order is what a ladder is.
        private(set) var calls: [String] = []

        /// Whether the surface can still afford a rebuild, and whether one
        /// starts when asked for.
        var rebuildAllowed = true
        var rebuildStarts = true
        /// What a repair does to the pipeline, if it does anything.
        var afterKick: Pipeline?
        var afterRebuild: Pipeline?
        private(set) var kicks = 0
        private(set) var rebuilds: [String] = []
        private(set) var giveUps: [(trigger: String, detail: String)] = []
        private(set) var healthyProofs = 0

        init(
            _ pipeline: Pipeline,
            render: @escaping (Pipeline, Int) -> NativeVideoLivenessEvaluator.Sample?
        ) {
            self.pipeline = pipeline
            self.render = render
        }

        func liveSample() -> NativeVideoLivenessEvaluator.Sample? {
            defer { sampled += 1 }
            return render(pipeline, sampled)
        }
        func finishSampling() { finished += 1 }
        func reportHealth(_ event: NativeVideoHealthEvent) {
            events.append(event)
            calls.append("report \(event.stage) \(event.verdict.kind) -> \(event.next.kind)")
        }
        func canRebuildPlayback() -> Bool { rebuildAllowed }
        func kickPlayback() {
            kicks += 1
            calls.append("kick")
            if let afterKick { pipeline = afterKick }
        }
        func rebuildPlayback(reason: String) -> Bool {
            calls.append("rebuild")
            guard rebuildStarts else { return false }
            rebuilds.append(reason)
            if let afterRebuild { pipeline = afterRebuild }
            return true
        }
        func playbackProvedHealthy() {
            healthyProofs += 1
            calls.append("healthy")
        }
        func giveUpOnPlayback(trigger: String, detail: String) {
            giveUps.append((trigger: trigger, detail: detail))
            calls.append("giveUp")
        }
    }

    private func sample(
        _ index: Int, advancing: Bool, frame: Bool, waiting: Bool = false
    ) -> NativeVideoLivenessEvaluator.Sample {
        NativeVideoLivenessEvaluator.Sample(
            time: CMTime(seconds: 10 + (advancing ? Double(index) * 0.1 : 0), preferredTimescale: 600),
            item: ObjectIdentifier(item), producedFrame: frame, waiting: waiting)
    }

    private func makeTarget(_ pipeline: Pipeline) -> FakeTarget {
        FakeTarget(pipeline) { [unowned self] pipeline, index in
            switch pipeline {
            case .healthy: return sample(index, advancing: true, frame: true)
            case .clockOnly: return sample(index, advancing: true, frame: false)
            case .waiting: return sample(index, advancing: false, frame: false, waiting: true)
            case .empty: return nil
            }
        }
    }

    private func healthy() -> FakeTarget { makeTarget(.healthy) }

    /// The clock runs and no frame ever comes: a dead decoder.
    private func clockOnly() -> FakeTarget { makeTarget(.clockOnly) }

    private func makeSupervisor(_ target: FakeTarget) -> NativeVideoHealthSupervisor {
        let supervisor = NativeVideoHealthSupervisor(policy: policy, sleep: sleeper.closure)
        supervisor.target = target
        return supervisor
    }

    /// Lets the next timer the supervisor is waiting on run out.
    private func fireNext() async {
        await sleeper.waitUntilPending()
        sleeper.fireNext()
    }

    /// Runs out every timer the check asks for until it has nothing left to wait
    /// for, however many looks and repairs that takes.
    private func runToTheEnd(_ supervisor: NativeVideoHealthSupervisor) async {
        var finished = false
        let watcher = Task { @MainActor in
            await supervisor.waitUntilIdleForTest()
            finished = true
        }
        var turns = 0
        while !finished, turns < 100_000 {
            turns += 1
            if !sleeper.fireNext() { await Task.yield() }
        }
        await watcher.value
        XCTAssertTrue(finished, "the check never ended")
    }

    /// Runs the first look to its verdict: the settle, then every step but the
    /// last, after which the supervisor acts on the verdict without waiting.
    private func finishFirstLook(samples: Int? = nil) async {
        await fireNext()  // the settle
        for _ in 0..<((samples ?? policy.sampleLimit) - 1) { await fireNext() }
    }

    // MARK: Looking

    func testAHealthyPipelineIsReportedAndSamplingStopsAtTheProof() async {
        let target = healthy()
        let supervisor = makeSupervisor(target)

        supervisor.schedule(trigger: "resumed after 2 h")
        await fireNext()  // the settle
        await fireNext()  // the step after the first sample
        await supervisor.waitUntilIdleForTest()

        XCTAssertEqual(
            target.events, [NativeVideoHealthEvent(trigger: "resumed after 2 h", verdict: .advancing)])
        XCTAssertEqual(target.sampled, 2, "one sample anchors the clock, the next proves it")
        XCTAssertEqual(sleeper.pendingCount, 0, "no further timer once it is proven")
        XCTAssertEqual(target.finished, 1, "what sampling attached is released")
        XCTAssertEqual(target.kicks, 0, "a healthy pipeline is left alone")
        XCTAssertTrue(target.rebuilds.isEmpty)
        XCTAssertEqual(target.healthyProofs, 1, "and the target is told pictures flow")
    }

    func testADeadPipelineIsReportedStalledOnlyWhenTheWholeWindowHasBeenSampled() async {
        let target = clockOnly()
        let supervisor = makeSupervisor(target)

        supervisor.schedule(trigger: "resumed after 2 h")
        await fireNext()  // the settle
        for _ in 0..<(policy.sampleLimit - 1) {
            await fireNext()
            XCTAssertTrue(target.events.isEmpty, "a stall is concluded at the end of the window")
        }
        await sleeper.waitUntilPending()  // the settle after the kick

        XCTAssertEqual(target.sampled, policy.sampleLimit, "the window bounds the work")
        XCTAssertEqual(target.events.count, 1)
        XCTAssertEqual(target.events.first?.trigger, "resumed after 2 h")
        XCTAssertEqual(target.events.first?.stage, .initial)
        guard case .stalled = target.events.first?.verdict else {
            return XCTFail("\(String(describing: target.events.first))")
        }
        supervisor.cancel()
    }

    func testTheDefaultWindowTakesAtMostTwentySamples() async {
        // The documented bound: two seconds in steps of a tenth.
        let target = clockOnly()
        let supervisor = NativeVideoHealthSupervisor(sleep: sleeper.closure)
        supervisor.target = target

        supervisor.schedule(trigger: "wake")
        await fireNext()
        for _ in 0..<19 { await fireNext() }
        await sleeper.waitUntilPending()  // the settle after the kick

        XCTAssertEqual(target.sampled, 20)
        XCTAssertEqual(target.events.count, 1)
        supervisor.cancel()
    }

    func testAPipelineThatWasWaitingForDataIsReportedWaitingNotStalled() async {
        let target = makeTarget(.waiting)
        let supervisor = makeSupervisor(target)

        supervisor.schedule(trigger: "resumed after 9 min")
        await finishFirstLook()
        await sleeper.waitUntilPending()  // looking again

        guard case .waiting = target.events.first?.verdict else {
            return XCTFail("a slow source is not a dead pipeline: \(target.events)")
        }
        XCTAssertEqual(target.events.first?.next, .recheck, "and is not nudged")
        XCTAssertEqual(target.kicks, 0)
        supervisor.cancel()
    }

    func testAWindowWithNothingToSampleIsReportedWaiting() async {
        let target = makeTarget(.empty)
        let supervisor = makeSupervisor(target)

        supervisor.schedule(trigger: "resumed after 9 min")
        await finishFirstLook()
        await sleeper.waitUntilPending()

        guard case .waiting = target.events.first?.verdict else {
            return XCTFail("\(target.events)")
        }
        supervisor.cancel()
    }

    func testASurfaceThatCannotBeJudgedIsNotProbed() async {
        let target = healthy()
        target.isEligibleForCheck = false
        let supervisor = makeSupervisor(target)

        supervisor.schedule(trigger: "resumed after 2 h")
        await supervisor.waitUntilIdleForTest()

        XCTAssertTrue(sleeper.requested.isEmpty, "not even the settle is waited for")
        XCTAssertEqual(target.sampled, 0)
        XCTAssertTrue(target.events.isEmpty)
        XCTAssertEqual(target.finished, 0)
    }

    func testASurfaceThatStopsBeingEligibleDuringTheSettleIsNeverSampled() async {
        let target = healthy()
        let supervisor = makeSupervisor(target)

        supervisor.schedule(trigger: "resumed after 2 h")
        await sleeper.waitUntilPending()
        target.isEligibleForCheck = false  // the user paused during the settle
        sleeper.fireNext()
        await supervisor.waitUntilIdleForTest()

        XCTAssertEqual(target.sampled, 0)
        XCTAssertTrue(target.events.isEmpty)
        XCTAssertEqual(target.finished, 1)
        XCTAssertEqual(target.kicks, 0)
    }

    func testAPauseMidRunStopsSamplingAndReportsNothing() async {
        let target = clockOnly()
        let supervisor = makeSupervisor(target)

        supervisor.schedule(trigger: "resumed after 2 h")
        await fireNext()  // settle
        await fireNext()  // first step
        await sleeper.waitUntilPending()  // the second sample is taken, waiting on the next step
        XCTAssertEqual(target.sampled, 2)
        target.isEligibleForCheck = false
        sleeper.fireNext()
        await supervisor.waitUntilIdleForTest()

        XCTAssertEqual(target.sampled, 2, "no sample after it stopped being meaningful")
        XCTAssertTrue(target.events.isEmpty, "a half-finished check says nothing")
        XCTAssertEqual(target.finished, 1)
        XCTAssertEqual(sleeper.pendingCount, 0)
        XCTAssertEqual(target.kicks, 0, "and repairs nothing")
    }

    func testCancellingAbandonsTheRunAndReleasesWhatItAttached() async {
        let target = clockOnly()
        let supervisor = makeSupervisor(target)

        supervisor.schedule(trigger: "resumed after 2 h")
        await fireNext()  // settle
        await sleeper.waitUntilPending()  // sampling, waiting on the first step
        supervisor.cancel()
        XCTAssertEqual(target.finished, 1, "released at once, not when the run notices")
        await supervisor.waitUntilIdleForTest()

        XCTAssertEqual(sleeper.cancelledCount, 1, "the step timer is cancelled")
        XCTAssertTrue(target.events.isEmpty)
        XCTAssertEqual(target.sampled, 1)
    }

    func testCancellingWithNothingRunningDoesNothing() {
        let target = healthy()
        let supervisor = makeSupervisor(target)

        supervisor.cancel()

        XCTAssertEqual(target.finished, 0)
    }

    func testTwoTriggersAreOneCheckForTheLatest() async {
        let target = healthy()
        let supervisor = makeSupervisor(target)

        supervisor.schedule(trigger: "resumed after 2 h")
        await sleeper.waitUntilPending()
        supervisor.schedule(trigger: "woke from sleep")
        await fireNext()  // the second run's settle
        await fireNext()
        await supervisor.waitUntilIdleForTest()

        XCTAssertEqual(
            target.events, [NativeVideoHealthEvent(trigger: "woke from sleep", verdict: .advancing)],
            "the earlier trigger is absorbed, not reported on its own")
        XCTAssertEqual(sleeper.cancelledCount, 1, "its settle was cancelled")
    }

    func testATriggerDuringSamplingStartsTheCheckOverFromItsOwnSettle() async {
        let target = healthy()
        let supervisor = makeSupervisor(target)

        supervisor.schedule(trigger: "resumed after 2 h")
        await fireNext()  // settle
        await sleeper.waitUntilPending()  // one sample taken, waiting on the step
        XCTAssertEqual(target.sampled, 1)
        supervisor.schedule(trigger: "woke from sleep")
        XCTAssertEqual(target.finished, 1, "the first check's output is released")
        await sleeper.waitUntilPending()
        XCTAssertEqual(
            sleeper.requested.last, policy.settle, "and the new check settles before it looks")
        XCTAssertEqual(target.sampled, 1, "nothing is sampled before the settle ends")
        await fireNext()
        await fireNext()
        await supervisor.waitUntilIdleForTest()

        XCTAssertEqual(target.events.map(\.trigger), ["woke from sleep"])
    }

    func testAnotherCheckCanFollowOnceOneHasFinished() async {
        let target = healthy()
        let supervisor = makeSupervisor(target)

        supervisor.schedule(trigger: "first")
        await fireNext()
        await fireNext()
        await supervisor.waitUntilIdleForTest()
        supervisor.schedule(trigger: "second")
        await fireNext()
        await fireNext()
        await supervisor.waitUntilIdleForTest()

        XCTAssertEqual(target.events.map(\.trigger), ["first", "second"])
    }

    // MARK: Repairing

    func testAStalledPipelineIsKickedThenRebuiltThenGivenUp() async {
        let target = clockOnly()
        let supervisor = makeSupervisor(target)

        supervisor.schedule(trigger: "the displays woke")
        await runToTheEnd(supervisor)

        XCTAssertEqual(target.calls, [
            "report initial stalled -> kick", "kick",
            "report afterKick stalled -> rebuild", "rebuild",
            "report afterRebuild stalled -> giveUp", "giveUp",
        ])
        XCTAssertEqual(target.kicks, 1, "exactly one kick")
        XCTAssertEqual(target.rebuilds.count, 1, "exactly one rebuild")
        XCTAssertEqual(target.giveUps.count, 1, "and one report")
        XCTAssertEqual(target.giveUps.first?.trigger, "the displays woke")
        let detail = target.giveUps.first?.detail ?? ""
        if case let .stalled(seen)? = target.events.last?.verdict {
            XCTAssertTrue(detail.contains(seen), "the report carries what the last look saw")
        } else {
            XCTFail("the last look should have found a stall: \(String(describing: target.events.last))")
        }
        XCTAssertTrue(target.rebuilds.first?.contains("the displays woke") == true, "and why it ran")
        XCTAssertEqual(target.healthyProofs, 0)
        XCTAssertEqual(target.finished, 1, "the run releases its output once, at the end")
        XCTAssertEqual(sleeper.pendingCount, 0)
    }

    func testEachLookAfterARepairSettlesFirstAndTheOneAfterARebuildGetsTheLongerWindow() async {
        let target = clockOnly()
        let supervisor = makeSupervisor(target)

        supervisor.schedule(trigger: "the Mac woke")
        await runToTheEnd(supervisor)

        let limits = policy.sampleLimit
        let rebuildSamples = policy.samples(in: policy.rebuildWindow)
        XCTAssertEqual(rebuildSamples, 10)
        XCTAssertEqual(
            target.sampled, limits + limits + rebuildSamples,
            "the first look, the look after the kick and the longer look after the rebuild")
        XCTAssertEqual(
            sleeper.requested.filter { $0 == policy.settle }.count, 3,
            "the trigger and each repair let the pipeline settle before it is looked at")
    }

    func testAKickThatBringsThePicturesBackEndsTheCheck() async {
        let target = clockOnly()
        target.afterKick = .healthy
        let supervisor = makeSupervisor(target)

        supervisor.schedule(trigger: "resumed after 2 h")
        await runToTheEnd(supervisor)

        XCTAssertEqual(target.calls, [
            "report initial stalled -> kick", "kick",
            "report afterKick advancing -> done", "healthy",
        ])
        XCTAssertTrue(target.rebuilds.isEmpty, "the cheap repair was enough")
        XCTAssertTrue(target.giveUps.isEmpty)
        XCTAssertEqual(target.healthyProofs, 1)
    }

    func testARebuildThatBringsThePicturesBackEndsTheCheck() async {
        let target = clockOnly()
        target.afterRebuild = .healthy
        let supervisor = makeSupervisor(target)

        supervisor.schedule(trigger: "resumed after 2 h")
        await runToTheEnd(supervisor)

        XCTAssertEqual(target.calls, [
            "report initial stalled -> kick", "kick",
            "report afterKick stalled -> rebuild", "rebuild",
            "report afterRebuild advancing -> done", "healthy",
        ])
        XCTAssertTrue(target.giveUps.isEmpty)
    }

    func testARebuildTheBudgetRefusesIsReportedInsteadOfTried() async {
        let target = clockOnly()
        target.rebuildAllowed = false
        let supervisor = makeSupervisor(target)

        supervisor.schedule(trigger: "resumed after 2 h")
        await runToTheEnd(supervisor)

        XCTAssertEqual(target.calls, [
            "report initial stalled -> kick", "kick",
            "report afterKick stalled -> giveUp", "giveUp",
        ])
        XCTAssertEqual(target.rebuilds.count, 0)
        XCTAssertEqual(target.giveUps.count, 1)
    }

    func testARebuildThatCannotStartIsReportedAtOnce() async {
        let target = clockOnly()
        target.rebuildStarts = false
        let supervisor = makeSupervisor(target)

        supervisor.schedule(trigger: "resumed after 2 h")
        await runToTheEnd(supervisor)

        XCTAssertEqual(target.giveUps.count, 1, "no look at a pipeline nobody rebuilt")
        XCTAssertEqual(target.events.count, 2)
        XCTAssertEqual(sleeper.pendingCount, 0)
    }

    func testAPauseMidLadderStopsEveryRepair() async {
        let target = clockOnly()
        let supervisor = makeSupervisor(target)

        supervisor.schedule(trigger: "resumed after 2 h")
        await finishFirstLook()
        await sleeper.waitUntilPending()  // the settle after the kick
        XCTAssertEqual(target.kicks, 1)
        target.isEligibleForCheck = false  // the user paused
        sleeper.fireNext()
        await supervisor.waitUntilIdleForTest()

        XCTAssertEqual(target.kicks, 1)
        XCTAssertTrue(target.rebuilds.isEmpty, "a clip nobody is watching is not rebuilt")
        XCTAssertTrue(target.giveUps.isEmpty, "nor given up on")
        XCTAssertEqual(target.events.count, 1, "and the half-finished check says no more")
        XCTAssertEqual(sleeper.pendingCount, 0)
    }

    func testCancellingMidLadderStopsEveryRepair() async {
        let target = clockOnly()
        let supervisor = makeSupervisor(target)

        supervisor.schedule(trigger: "resumed after 2 h")
        await finishFirstLook()
        await sleeper.waitUntilPending()
        supervisor.cancel()
        await supervisor.waitUntilIdleForTest()

        XCTAssertEqual(target.calls, ["report initial stalled -> kick", "kick"])
        XCTAssertEqual(sleeper.pendingCount, 0)
        XCTAssertEqual(target.finished, 1)
    }

    func testATriggerWhileRepairingIsAbsorbedNotKickedAgain() async {
        let target = clockOnly()
        let supervisor = makeSupervisor(target)

        supervisor.schedule(trigger: "resumed after 2 h")
        await finishFirstLook()
        await sleeper.waitUntilPending()  // the kick is done; the look after it settles
        let timers = sleeper.requested.count
        supervisor.schedule(trigger: "the displays woke")
        supervisor.schedule(trigger: "the session became active")

        XCTAssertEqual(sleeper.cancelledCount, 0, "the check in flight is left alone")
        XCTAssertEqual(sleeper.requested.count, timers, "and nothing starts over")
        await runToTheEnd(supervisor)

        XCTAssertEqual(target.kicks, 1, "one kick however many triggers arrived")
        XCTAssertEqual(target.rebuilds.count, 1)
        XCTAssertEqual(target.giveUps.count, 1)
        XCTAssertEqual(Set(target.events.map(\.trigger)), ["resumed after 2 h"])
    }

    func testATriggerThatArrivesAfterTheLadderEndedStartsANewOne() async {
        let target = clockOnly()
        target.afterKick = .healthy
        let supervisor = makeSupervisor(target)
        supervisor.schedule(trigger: "first")
        await runToTheEnd(supervisor)
        XCTAssertEqual(target.kicks, 1)

        target.pipeline = .clockOnly  // it died again after the wake
        supervisor.schedule(trigger: "second")
        await runToTheEnd(supervisor)

        XCTAssertEqual(target.kicks, 2, "each trigger gets its own ladder")
        XCTAssertEqual(target.events.filter { $0.stage == .initial }.map(\.trigger), ["first", "second"])
    }

    func testAPipelineThatKeepsWaitingIsLookedAtAgainWithoutASettleThenTreatedAsStuck() async {
        let target = makeTarget(.waiting)
        let supervisor = makeSupervisor(target)

        supervisor.schedule(trigger: "resumed after 9 min")
        await runToTheEnd(supervisor)

        XCTAssertEqual(
            target.events.map { $0.next.kind }, ["recheck", "recheck", "kick", "rebuild", "giveUp"])
        XCTAssertEqual(
            sleeper.requested.filter { $0 == policy.settle }.count, 3,
            "the rechecks follow the window that just ended; only the trigger and the repairs settle")
        XCTAssertEqual(target.kicks, 1)
        XCTAssertEqual(target.rebuilds.count, 1)
        XCTAssertEqual(target.giveUps.count, 1)
    }

    func testAPipelineThatWasOnlySlowToWakeIsNeverTouched() async {
        let target = makeTarget(.waiting)
        let supervisor = makeSupervisor(target)

        supervisor.schedule(trigger: "the Mac woke")
        await finishFirstLook()
        await sleeper.waitUntilPending()  // looking again
        target.pipeline = .healthy  // the disk spun up
        await fireNext()  // the next sample is the picture that proves it
        await supervisor.waitUntilIdleForTest()

        XCTAssertEqual(target.calls, [
            "report initial waiting -> recheck",
            "report initial advancing -> done", "healthy",
        ])
        XCTAssertEqual(target.kicks, 0)
        XCTAssertTrue(target.rebuilds.isEmpty)
    }
}

private extension NativeVideoLiveness {
    var kind: String {
        switch self {
        case .advancing: return "advancing"
        case .stalled: return "stalled"
        case .waiting: return "waiting"
        }
    }
}

private extension NativeVideoHealthLadder.Action {
    var kind: String {
        switch self {
        case .done: return "done"
        case .recheck: return "recheck"
        case .kick: return "kick"
        case .rebuild: return "rebuild"
        case .giveUp: return "giveUp"
        }
    }
}
