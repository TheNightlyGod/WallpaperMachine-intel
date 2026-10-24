import Foundation
import WallpaperMedia

/// Which player draws a plain video wallpaper on the lock screen and as the screen saver.
enum LockScreenVideoPath: Equatable {
  /// An AVFoundation layer with hardware decode.
  case avFoundation(URL)
  /// A WebM or Matroska file AVFoundation cannot open, opened with the app's own reader and played
  /// by `WebMPlayer` (`LockScreenWebMPlayer`).
  case webM(URL, WebMFile)
  /// Neither of the app's own players can take the clip. There is no other renderer for a video:
  /// the surface holds what it shows and reports `reason`, as the desktop does.
  case unplayable(reason: String)

  var isPlayable: Bool {
    switch self {
    case .avFoundation, .webM: return true
    case .unplayable: return false
    }
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    switch (lhs, rhs) {
    case let (.avFoundation(a), .avFoundation(b)): return a == b
    case let (.webM(a, fileA), .webM(b, fileB)): return a == b && fileA === fileB
    case let (.unplayable(a), .unplayable(b)): return a == b
    default: return false
    }
  }
}

/// The decision, kept apart from the player so it can be exercised without a lock screen.
///
/// It mirrors the app: the app publishes `plainVideo` for every plain video and `nativeVideoFile`
/// when it found the clip, and the players take it when `NativeVideoAdmission` accepts it, the same
/// rule the desktop applies. The clip plays at its own frame rate. A clip AVFoundation cannot open
/// is tried with the app's own WebM reader (a Matroska or WebM file it plays goes to `WebMPlayer`);
/// anything else is unplayable, and the surface holds it with the reason.
enum LockScreenVideoPlanner {
  /// The scene's media file in the exchange directory, as a path relative to it. Nil when the
  /// scene is not a plain video the app published a file for, or names a file that cannot lie inside its
  /// project folder.
  static func mediaPath(of scene: LockScreenScene) -> String? {
    guard scene.webEntryFile == nil, let file = scene.nativeVideoFile, !file.isEmpty,
      !file.hasPrefix("/")
    else { return nil }
    let parts = file.split(separator: "/", omittingEmptySubsequences: false)
    guard !parts.contains(".."), !parts.contains("."), !parts.contains("") else { return nil }
    let project = scene.projectPath.split(separator: "/", omittingEmptySubsequences: false)
    guard project.count >= 2 else { return nil }
    return (project.dropLast() + parts).joined(separator: "/")
  }

  /// `resolve` turns the relative path into a readable file and throws when it cannot (the
  /// extension's own sandboxed asset lookup); `admission` is the desktop's rule.
  static func decide(
    scene: LockScreenScene,
    resolve: (String) throws -> URL,
    admission: (URL) async -> NativeVideoRefusal? = { url in
      await NativeVideoAdmission.evaluate(url: url)
    },
    openWebM: (URL) -> WebMFile? = { url in
      if case .success(let file) = WebMOpening.open(url: url) { return file }
      return nil
    }
  ) async -> LockScreenVideoPath {
    guard scene.webEntryFile == nil, scene.plainVideo == true else {
      return .unplayable(reason: "this wallpaper is not a plain video")
    }
    guard scene.nativeVideoFile != nil else {
      return .unplayable(reason: "the project's video file could not be found")
    }
    guard let path = mediaPath(of: scene) else {
      return .unplayable(reason: "the clip's path is not inside its project")
    }
    let url: URL
    do { url = try resolve(path) } catch {
      return .unplayable(reason: "the clip is unavailable: \(error.localizedDescription)")
    }
    if let refusal = await admission(url) {
      // AVFoundation never opens Matroska or WebM; the app's reader may. Anything it does not play
      // keeps the refusal AVFoundation gave.
      if case .notPlayable = refusal, let file = openWebM(url) { return .webM(url, file) }
      return .unplayable(reason: refusal.reason)
    }
    return .avFoundation(url)
  }
}

/// A bound on work that may never finish, with the clock as a parameter so a test does not wait.
enum LockScreenDeadline {
  struct Expired: Error, LocalizedError, Equatable {
    let timeout: Duration
    var errorDescription: String? { "it did not finish within \(timeout)" }
  }

  /// How long a player has, from the decision to the first frame, before the surface holds the
  /// clip as unplayable. It is well inside the surface's 30 second first-frame deadline, so the
  /// failure is reported while the host is still waiting for a picture.
  static let nativeAttempt = Duration.seconds(10)

  /// `operation`'s result, or `Expired` once `sleep(timeout)` returns first. The loser is
  /// cancelled; an `operation` that ignores cancellation is abandoned, not waited for.
  @MainActor
  static func run<T>(
    within timeout: Duration,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    operation: @escaping @MainActor () async throws -> T
  ) async throws -> T {
    let race = Race()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
        let work = Task { @MainActor in
          let result: Result<T, Error>
          do { result = .success(try await operation()) } catch { result = .failure(error) }
          guard race.settle() else { return }
          race.timer?.cancel()
          continuation.resume(with: result)
        }
        race.work = work
        race.timer = Task { @MainActor in
          do { try await sleep(timeout) } catch { return }
          guard race.settle() else { return }
          work.cancel()
          continuation.resume(throwing: Expired(timeout: timeout))
        }
      }
    } onCancel: {
      // The operation is told, and ends by itself; the timer stays the bound if it does not.
      race.work?.cancel()
    }
  }

  /// Which of the operation and the timer finished first, shared with the cancellation handler.
  private final class Race: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false
    private var _work: Task<Void, Never>?
    private var _timer: Task<Void, Never>?
    var work: Task<Void, Never>? {
      get { lock.withLock { _work } }
      set { lock.withLock { _work = newValue } }
    }
    var timer: Task<Void, Never>? {
      get { lock.withLock { _timer } }
      set { lock.withLock { _timer = newValue } }
    }
    func settle() -> Bool {
      lock.withLock {
        guard !settled else { return false }
        settled = true
        return true
      }
    }
  }
}
