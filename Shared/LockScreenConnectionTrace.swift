import os

/// How many requests one connection from the wallpaper service carried.
///
/// A connection that closes without having carried any is the pattern worth
/// knowing about when the service misbehaves, and the close line in
/// `extension.log` reports this count next to the pid. It is only counted, never
/// acted on. Requests arrive on the listener's queue, so the count is locked.
final class LockScreenConnectionTrace: Sendable {
  private let count = OSAllocatedUnfairLock(initialState: 0)

  /// Call once for every request the connection delivers, whatever the answer.
  func noteServed() {
    count.withLock { $0 += 1 }
  }

  var served: Int { count.withLock { $0 } }
}
