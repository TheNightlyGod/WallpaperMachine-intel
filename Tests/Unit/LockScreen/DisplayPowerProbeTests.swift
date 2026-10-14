import XCTest

@testable import WallpaperMachine

final class DisplayPowerProbeTests: XCTestCase {
  /// Display power the test can change between questions, as sleep and wake do.
  private final class Displays: @unchecked Sendable {
    private let lock = NSLock()
    private var asleep: Set<UInt32>
    let online: [UInt32]

    init(asleep: Set<UInt32>, online: [UInt32]) {
      self.asleep = asleep
      self.online = online
    }

    func set(_ id: UInt32, asleep value: Bool) {
      lock.lock()
      defer { lock.unlock() }
      if value { asleep.insert(id) } else { asleep.remove(id) }
    }

    var probe: DisplayPowerProbe {
      DisplayPowerProbe(
        isAsleep: { [self] id in
          lock.lock()
          defer { lock.unlock() }
          return asleep.contains(id)
        },
        onlineDisplays: { [self] in online })
    }
  }

  func testAKnownDisplayAnswersForItselfAndNoneNeedsEveryOnlineDisplayAsleep() {
    let displays = Displays(asleep: [1], online: [1, 2])
    let probe = displays.probe
    XCTAssertTrue(probe.displaysAsleep(for: 1))
    XCTAssertFalse(probe.displaysAsleep(for: 2))
    XCTAssertFalse(
      probe.displaysAsleep(for: nil), "One display still awake: a preview can be looked at there.")

    displays.set(2, asleep: true)
    XCTAssertTrue(probe.displaysAsleep(for: nil))
    XCTAssertTrue(probe.displaysAsleep(for: 2))
  }

  func testNoOnlineDisplaysIsNotTreatedAsAllAsleep() {
    let probe = Displays(asleep: [], online: []).probe
    XCTAssertFalse(probe.displaysAsleep(for: nil))
  }

  /// The reason the power state is a question: a wake whose notification never arrived
  /// must not leave the surface believing the display still sleeps.
  func testThePowerStateIsReadAtEachQuestionNotRemembered() {
    let displays = Displays(asleep: [7], online: [7])
    let probe = displays.probe
    XCTAssertTrue(probe.displaysAsleep(for: 7))
    XCTAssertTrue(probe.displaysAsleep(for: nil))

    displays.set(7, asleep: false)
    XCTAssertFalse(probe.displaysAsleep(for: 7))
    XCTAssertFalse(probe.displaysAsleep(for: nil))

    displays.set(7, asleep: true)
    XCTAssertTrue(probe.displaysAsleep(for: 7))
  }
}
