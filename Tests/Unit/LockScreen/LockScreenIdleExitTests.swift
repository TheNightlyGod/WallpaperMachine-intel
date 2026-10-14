import XCTest

@testable import WallpaperMachine

@MainActor
final class LockScreenIdleExitTests: XCTestCase {
  private var busy = false
  private var exits = 0

  private func makeExit() -> LockScreenIdleExit {
    LockScreenIdleExit(
      grace: .milliseconds(50), isBusy: { [unowned self] in busy }, exit: { [unowned self] in exits += 1 })
  }

  private func settle() async throws { try await Task.sleep(for: .milliseconds(250)) }

  /// Holds the main queue past the grace period, so a due exit waits behind it.
  private func blockMainQueue(for seconds: TimeInterval, thenWaitFor signal: DispatchSemaphore) {
    Thread.sleep(forTimeInterval: seconds)
    signal.wait()
  }

  func testExitsOnlyAfterTheLastHostConnectionCloses() async throws {
    let idle = makeExit()
    idle.connectionOpened()
    idle.connectionOpened()
    idle.connectionClosed()
    try await settle()
    XCTAssertEqual(exits, 0)

    idle.connectionClosed()
    try await settle()
    XCTAssertEqual(exits, 1)
  }

  func testOpenConnectionsFollowAcceptsAndCloses() async throws {
    let idle = makeExit()
    XCTAssertEqual(idle.openConnections, 0)
    idle.connectionOpened()
    idle.connectionOpened()
    XCTAssertEqual(idle.openConnections, 2)
    idle.connectionClosed()
    XCTAssertEqual(idle.openConnections, 1)
    idle.connectionOpened()
    XCTAssertEqual(idle.openConnections, 2)

    // A close the count never saw (an invalidation after an interruption) cannot go negative.
    idle.connectionClosed()
    idle.connectionClosed()
    idle.connectionClosed()
    XCTAssertEqual(idle.openConnections, 0)
    try await settle()
  }

  func testANewConnectionDuringTheGracePeriodKeepsTheProcess() async throws {
    let idle = makeExit()
    idle.connectionOpened()
    idle.connectionClosed()
    idle.connectionOpened()
    try await settle()
    XCTAssertEqual(exits, 0)
  }

  /// The listener accepts connections off the main queue. One accepted after the exit
  /// fell due, while the main queue was busy, must still keep the process.
  func testAConnectionAcceptedWhileTheExitIsQueuedKeepsTheProcess() async throws {
    let idle = makeExit()
    idle.connectionOpened()
    idle.connectionClosed()
    // Let the first open's main-queue hop pass, so only the count can stop the exit.
    try await Task.sleep(for: .milliseconds(10))
    let accepted = DispatchSemaphore(value: 0)
    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) {
      idle.connectionOpened()
      accepted.signal()
    }
    blockMainQueue(for: 0.15, thenWaitFor: accepted)
    try await settle()
    XCTAssertEqual(exits, 0)
  }

  func testALiveSurfaceKeepsTheProcessUntilItIsRemoved() async throws {
    let idle = makeExit()
    busy = true
    idle.connectionOpened()
    idle.connectionClosed()
    try await settle()
    XCTAssertEqual(exits, 0)

    busy = false
    idle.surfacesChanged()
    try await settle()
    XCTAssertEqual(exits, 1)
  }

  func testASurfaceAcquiredDuringTheGracePeriodKeepsTheProcess() async throws {
    let idle = makeExit()
    idle.connectionOpened()
    idle.connectionClosed()
    busy = true
    try await settle()
    XCTAssertEqual(exits, 0)
  }
}
