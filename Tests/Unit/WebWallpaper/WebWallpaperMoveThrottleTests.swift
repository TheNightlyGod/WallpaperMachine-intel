import AppKit
import XCTest

@testable import WallpaperMachine

/// The pointer-move throttle is pure policy over explicit timestamps, so a
/// second of a 1000 Hz mouse is replayed here in microseconds and the verdicts
/// never depend on how busy the machine is.
final class WebWallpaperMoveThrottleTests: XCTestCase {
  private let interval = 1.0 / 60
  private let ms = 0.001

  func testFirstMoveAfterAQuietStretchIsDeliveredAtOnce() {
    var throttle = WebWallpaperMoveThrottle()
    XCTAssertEqual(throttle.offer(window: 1, at: 100, interval: interval), .deliverNow)
    XCTAssertEqual(
      throttle.offer(window: 1, at: 100 + interval + ms, interval: interval), .deliverNow,
      "a move after the interval has passed is not held")
    XCTAssertEqual(
      throttle.offer(window: 1, at: 200, interval: interval), .deliverNow,
      "a flick that starts from rest is never delayed")
  }

  func testMovesInsideTheIntervalAreHeldWithOneFlushTimerAndTheTrailingEdgeIsDelivered() throws {
    var throttle = WebWallpaperMoveThrottle()
    XCTAssertEqual(throttle.offer(window: 1, at: 0, interval: interval), .deliverNow)
    let first = throttle.offer(window: 1, at: 4 * ms, interval: interval)
    guard case .hold(let delay) = first, let delay else { return XCTFail("\(first)") }
    XCTAssertEqual(delay, interval - 4 * ms, accuracy: 1e-9, "the timer ends the interval that started at the last delivery")
    XCTAssertEqual(throttle.offer(window: 1, at: 8 * ms, interval: interval), .hold(scheduleFlushAfter: nil))
    XCTAssertEqual(throttle.offer(window: 1, at: 12 * ms, interval: interval), .hold(scheduleFlushAfter: nil))

    // The timer fires at the end of the interval and delivers the newest move;
    // the next interval starts from that delivery.
    throttle.delivered(window: 1, at: interval)
    let next = throttle.offer(window: 1, at: 20 * ms, interval: interval)
    guard case .hold(let nextDelay) = next, let nextDelay else { return XCTFail("\(next)") }
    XCTAssertEqual(nextDelay, interval - (20 * ms - interval), accuracy: 1e-9)
  }

  func testAMoveBehindALateTimerIsDeliveredAndSupersedesTheHeldOne() {
    var throttle = WebWallpaperMoveThrottle()
    XCTAssertEqual(throttle.offer(window: 1, at: 0, interval: interval), .deliverNow)
    XCTAssertEqual(throttle.offer(window: 1, at: 5 * ms, interval: interval), .hold(scheduleFlushAfter: interval - 5 * ms))
    // The main thread was busy and the timer has not run, but the interval is over.
    XCTAssertEqual(throttle.offer(window: 1, at: 30 * ms, interval: interval), .deliverNow)
    // Whatever is held after that is a new burst with its own timer.
    XCTAssertEqual(
      throttle.offer(window: 1, at: 31 * ms, interval: interval), .hold(scheduleFlushAfter: interval - ms))
  }

  func testAMoveStampedBeforeTheLastDeliveryIsHeldForAtMostOneInterval() {
    var throttle = WebWallpaperMoveThrottle()
    throttle.delivered(window: 1, at: 10)
    // An event stamped before the delivery it follows (the timer's clock reads
    // later than an event that was already queued) is simply held.
    XCTAssertEqual(throttle.offer(window: 1, at: 9.99, interval: interval), .hold(scheduleFlushAfter: interval))
  }

  func testWindowsAreThrottledIndependently() {
    var throttle = WebWallpaperMoveThrottle()
    XCTAssertEqual(throttle.offer(window: 1, at: 0, interval: interval), .deliverNow)
    XCTAssertEqual(throttle.offer(window: 2, at: 2 * ms, interval: interval), .deliverNow,
      "a second display's wallpaper has its own interval")
    XCTAssertEqual(throttle.offer(window: 1, at: 3 * ms, interval: interval), .hold(scheduleFlushAfter: interval - 3 * ms))
    XCTAssertEqual(throttle.offer(window: 2, at: 4 * ms, interval: interval), .hold(scheduleFlushAfter: interval - 2 * ms),
      "each window gets its own timer")
    throttle.delivered(window: 1, at: interval)
    XCTAssertEqual(throttle.offer(window: 2, at: 6 * ms, interval: interval), .hold(scheduleFlushAfter: nil),
      "window 1's flush does not touch window 2's burst")
  }

  func testResetAndCancelDropPendingState() {
    var throttle = WebWallpaperMoveThrottle()
    XCTAssertEqual(throttle.offer(window: 1, at: 0, interval: interval), .deliverNow)
    XCTAssertEqual(throttle.offer(window: 2, at: 0, interval: interval), .deliverNow)
    XCTAssertEqual(throttle.offer(window: 1, at: ms, interval: interval), .hold(scheduleFlushAfter: interval - ms))
    throttle.cancel(window: 1)
    XCTAssertEqual(throttle.offer(window: 1, at: 2 * ms, interval: interval), .deliverNow,
      "a cancelled window starts over with a leading edge")
    XCTAssertEqual(throttle.offer(window: 2, at: 2 * ms, interval: interval), .hold(scheduleFlushAfter: interval - 2 * ms),
      "other windows keep their state")
    throttle.reset()
    XCTAssertEqual(throttle.offer(window: 2, at: 3 * ms, interval: interval), .deliverNow)
  }

  func testAThousandHertzStreamIsReducedToTheConfiguredRate() {
    for rate in [60.0, 30.0, 10.0] {
      let interval = 1 / rate
      var throttle = WebWallpaperMoveThrottle()
      var deliveries: [TimeInterval] = []
      var flushAt: TimeInterval?
      // One second of events, one per millisecond, with the flush timer fired
      // exactly when it was asked to.
      for step in 0..<1000 {
        let now = Double(step) * ms
        if let due = flushAt, due <= now {
          throttle.delivered(window: 1, at: due)
          deliveries.append(due)
          flushAt = nil
        }
        switch throttle.offer(window: 1, at: now, interval: interval) {
        case .deliverNow: deliveries.append(now)
        case .hold(let delay): if let delay { flushAt = now + delay }
        }
      }
      XCTAssertEqual(Double(deliveries.count), rate, accuracy: 2, "\(rate) per second")
      let gaps = zip(deliveries, deliveries.dropFirst()).map { $1 - $0 }
      XCTAssertGreaterThanOrEqual(gaps.min() ?? interval, interval - 1e-9, "no two deliveries closer than the interval")
    }
  }
}

/// The coalescer keeps the newest held move per window and the timer that ends
/// its interval. Events are real `NSEvent`s (no window is involved) and the
/// clock and the timer are the test's own.
@MainActor
final class WebWallpaperMoveCoalescerTests: XCTestCase {
  private let interval = 1.0 / 60
  private var clock = 0.0
  private var delivered: [(window: Int, id: Int)] = []
  private var goneWindows: Set<Int> = []
  private var gate: WaitGate!
  private var coalescer: WebWallpaperMoveCoalescer!

  override func setUp() {
    clock = 0
    delivered = []
    goneWindows = []
    gate = WaitGate()
    coalescer = WebWallpaperMoveCoalescer(
      deliver: { [unowned self] window, event in
        guard !goneWindows.contains(window) else { return false }
        delivered.append((window, event.eventNumber))
        return true
      },
      now: { [unowned self] in clock },
      wait: { [gate = gate!] delay in try await gate.wait(delay) })
  }

  override func tearDown() {
    coalescer.reset()
    gate.releaseAll()
  }

  /// A move of the pointer, identified by `id`, observed at `time`.
  private func move(to id: Int, at time: Double, window: Int = 1) {
    clock = max(clock, time)
    let event = NSEvent.mouseEvent(
      with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: time,
      windowNumber: window, context: nil, eventNumber: id, clickCount: 0, pressure: 0)!
    coalescer.move(event, window: window, interval: interval)
  }

  /// The ids of the moves the page received, in order.
  private var xs: [Int] { delivered.map(\.id) }

  func testOnlyTheFirstAndTheNewestMoveOfABurstReachThePage() async throws {
    move(to: 1, at: 0)
    move(to: 2, at: 0.004)
    move(to: 3, at: 0.008)
    move(to: 4, at: 0.012)
    XCTAssertEqual(xs, [1], "the moves inside the interval are held")
    try await gate.parked(1)
    XCTAssertEqual(gate.delays.count, 1, "one timer serves the burst")
    XCTAssertEqual(gate.delays[0], interval - 0.004, accuracy: 1e-9)

    clock = interval
    gate.release()
    try await settle { self.xs.count == 2 }
    XCTAssertEqual(xs, [1, 4], "the pointer comes to rest at the newest position")
  }

  func testAGestureFlushesTheHeldMoveFirstAndTheTimerThenDoesNothing() async throws {
    move(to: 1, at: 0)
    move(to: 2, at: 0.004)
    move(to: 3, at: 0.008)
    try await gate.parked(1)
    XCTAssertTrue(coalescer.hasPending(window: 1))

    // A press arrives: the forwarder flushes before delivering it.
    clock = 0.010
    coalescer.flush(window: 1)
    XCTAssertEqual(xs, [1, 3])
    XCTAssertFalse(coalescer.hasPending(window: 1))
    coalescer.flush(window: 1)
    XCTAssertEqual(xs, [1, 3], "flushing with nothing held delivers nothing")

    // The timer that was already waiting wakes up and must not deliver again.
    gate.release()
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(xs, [1, 3])
  }

  func testAMovePastTheIntervalReplacesTheHeldOneAndCancelsItsTimer() async throws {
    move(to: 1, at: 0)
    move(to: 2, at: 0.005)
    try await gate.parked(1)
    move(to: 3, at: 0.030)
    XCTAssertEqual(xs, [1, 3], "the newer move goes through at once; the stale held one is dropped")
    XCTAssertFalse(coalescer.hasPending(window: 1))

    gate.release()
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(xs, [1, 3], "the superseded timer delivers nothing")
  }

  func testTheDeliveryStampsTheNextInterval() async throws {
    move(to: 1, at: 0)
    move(to: 2, at: 0.004)
    try await gate.parked(1)
    clock = interval + 0.001
    gate.release()
    try await settle { self.xs.count == 2 }

    // A move right after the flush belongs to the interval the flush started.
    move(to: 3, at: interval + 0.003)
    XCTAssertEqual(xs, [1, 2], "held, not delivered on top of the flush")
    XCTAssertTrue(coalescer.hasPending(window: 1))
    try await gate.parked(2)
    XCTAssertEqual(gate.delays[1], interval - 0.002, accuracy: 1e-9)
  }

  func testResetDropsHeldMovesAndTheirTimers() async throws {
    move(to: 1, at: 0)
    move(to: 2, at: 0.004)
    move(to: 5, at: 0.004, window: 2)
    move(to: 6, at: 0.006, window: 2)
    try await gate.parked(2)
    coalescer.reset()
    XCTAssertFalse(coalescer.hasPending(window: 1))
    XCTAssertFalse(coalescer.hasPending(window: 2))

    gate.releaseAll()
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(xs, [1, 5], "nothing held survives a monitor being removed")
    move(to: 7, at: 0.1)
    XCTAssertEqual(xs, [1, 5, 7], "and the next move after a reset is a leading edge")
  }

  func testWindowsAreCoalescedSeparately() {
    move(to: 1, at: 0, window: 1)
    move(to: 10, at: 0.001, window: 2)
    move(to: 2, at: 0.002, window: 1)
    move(to: 20, at: 0.003, window: 2)
    XCTAssertEqual(delivered.map(\.window), [1, 2])
    coalescer.flush(window: 2)
    XCTAssertEqual(delivered.map(\.window), [1, 2, 2])
    XCTAssertEqual(xs, [1, 10, 20])
    XCTAssertTrue(coalescer.hasPending(window: 1), "flushing one window leaves the other's move held")
    coalescer.flush(window: 1)
    XCTAssertEqual(xs, [1, 10, 20, 2])
  }

  func testAHeldMoveForAWindowThatWentAwayIsDroppedAndForgotten() async throws {
    move(to: 1, at: 0)
    move(to: 2, at: 0.004)
    try await gate.parked(1)
    goneWindows.insert(1)
    clock = interval
    gate.release()
    try await settle { !self.coalescer.hasPending(window: 1) }
    XCTAssertEqual(xs, [1], "the window is gone, so the held move has nowhere to go")

    // A new window reusing the number starts with a leading edge, not with the
    // interval of the one that went away.
    goneWindows.remove(1)
    move(to: 3, at: interval + 0.001)
    XCTAssertEqual(xs, [1, 3])
  }

  func testAThousandHertzStreamReachesThePageAtTheConfiguredRate() async throws {
    // The same stream as the pure test, but through the held-event store: the
    // timer is released whenever the stream's clock passes its delay.
    var due: Double?
    for step in 0..<1000 {
      let now = Double(step) * 0.001
      if let dueAt = due, dueAt <= now {
        clock = dueAt
        gate.release()
        try await settle { !self.coalescer.hasPending(window: 1) }
        due = nil
      }
      let timers = gate.delays.count
      move(to: step, at: now)
      if coalescer.hasPending(window: 1), due == nil {
        try await gate.parked(timers + 1)
        due = now + gate.delays[timers]
      }
    }
    XCTAssertEqual(Double(delivered.count), 60, accuracy: 2)
    XCTAssertEqual(xs, xs.sorted(), "positions are never delivered out of order")
    XCTAssertEqual(xs.first, 0)
  }

  // MARK: - helpers

  private func settle(timeout: TimeInterval = 5, until condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(2))
    }
    XCTFail("condition not met before timeout")
  }
}

/// A timer the test releases by hand. Each `wait` parks until released, so the
/// order and the delays of the coalescer's flushes are checked without sleeping.
private final class WaitGate: @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [CheckedContinuation<Void, Error>] = []
  private var requested: [TimeInterval] = []
  private var next = 0

  var delays: [TimeInterval] {
    lock.lock()
    defer { lock.unlock() }
    return requested
  }

  func wait(_ delay: TimeInterval) async throws {
    try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      requested.append(delay)
      continuations.append(continuation)
      lock.unlock()
    }
  }

  /// Waits until `count` waits have been requested in total.
  func parked(_ count: Int, timeout: TimeInterval = 5) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if delays.count >= count { return }
      try await Task.sleep(for: .milliseconds(2))
    }
    XCTFail("\(count) timers were not requested before the timeout")
  }

  /// Wakes the oldest wait that has not been woken yet.
  func release() {
    lock.lock()
    let continuation = next < continuations.count ? continuations[next] : nil
    if continuation != nil { next += 1 }
    lock.unlock()
    continuation?.resume()
  }

  func releaseAll() {
    lock.lock()
    let rest = Array(continuations.dropFirst(next))
    next = continuations.count
    lock.unlock()
    for continuation in rest { continuation.resume() }
  }
}
