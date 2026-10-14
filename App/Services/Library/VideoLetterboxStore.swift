import CoreGraphics
import Foundation
import Observation

/// Holds the black-bar check results the inspector shows, in memory only.
///
/// A check is an explicit click that decodes a few frames, so there is no queue and no saved
/// record: results are kept for the session, tagged with the library revision they were taken
/// at, and read as "not checked" once the library has been refreshed. One probe runs at a time;
/// starting another wallpaper's check, selecting a different wallpaper or stopping the panel
/// cancels the running one and writes nothing.
@MainActor @Observable
final class VideoLetterboxStore {
  enum Phase: Equatable {
    case idle
    case checking
    case done(VideoLetterboxProbe.Report)
    case failed(VideoLetterboxProbe.Failure)
  }

  /// Resolves the installed video file for a wallpaper, validating it against the library.
  typealias EntryResolver = @MainActor (_ wallpaperID: String, _ displayID: String) async throws -> URL

  private struct Record {
    let revision: UInt64
    let phase: Phase
  }

  static let entryLimit = 16

  /// The size of a display's viewport in points, or nil when it is not connected.
  @ObservationIgnored var viewportProvider: @MainActor (String) -> CGSize? = { _ in nil }
  @ObservationIgnored var onChange: (@MainActor () -> Void)?
  @ObservationIgnored private let probe: VideoLetterboxProbe
  @ObservationIgnored private let entry: EntryResolver
  @ObservationIgnored private var generation: UInt64 = 0
  @ObservationIgnored private var order: [String] = []
  private var records: [String: Record] = [:]
  private var running: (wallpaperID: String, revision: UInt64)?
  @ObservationIgnored private var runningTask: Task<Void, Never>?
  /// Bumped on every state change, so the panel can observe the store without reading its records.
  private(set) var changes: UInt64 = 0

  init(probe: VideoLetterboxProbe = VideoLetterboxProbe(), entry: @escaping EntryResolver) {
    self.probe = probe
    self.entry = entry
  }

  /// What the card shows for a wallpaper at a library revision. A result from an older revision
  /// reads as idle: the files it described may have been replaced.
  func phase(for wallpaperID: String, revision: UInt64) -> Phase {
    if let running, running.wallpaperID == wallpaperID, running.revision == revision { return .checking }
    guard let record = records[wallpaperID], record.revision == revision else { return .idle }
    return record.phase
  }

  /// A different selection cancels a check still running for another wallpaper.
  func select(_ wallpaperID: String?) {
    guard let running, running.wallpaperID != wallpaperID else { return }
    cancelRunning()
  }

  func check(wallpaperID: String, displayID: String, libraryRevision: UInt64) async {
    if let running, running.wallpaperID == wallpaperID, running.revision == libraryRevision { return }
    cancelRunning()
    let ticket = generation
    running = (wallpaperID, libraryRevision)
    let task = Task(priority: .utility) { [weak self] in
      guard let self else { return }
      await self.run(wallpaperID: wallpaperID, displayID: displayID, revision: libraryRevision, ticket: ticket)
    }
    runningTask = task
    touch()
    await task.value
  }

  /// Why a stored result cannot back an action.
  enum Confirmation: Error, Equatable {
    /// There is no finished result for the wallpaper at this library revision.
    case notChecked
    /// The file is no longer the one that was examined; the result has been dropped.
    case fileChanged
  }

  /// The finished result for a wallpaper, after proving the file on disk is still the one it
  /// describes. A replaced file drops the result, so the card reads as not checked again.
  func confirmedReport(wallpaperID: String, displayID: String, libraryRevision: UInt64) async throws -> VideoLetterboxProbe.Report {
    guard case .done(let report) = phase(for: wallpaperID, revision: libraryRevision) else { throw Confirmation.notChecked }
    let url = try await entry(wallpaperID, displayID)
    let stamp = await probe.currentStamp(of: url)
    // Both awaits can outlast a newer check, a library refresh or a selection change.
    guard case .done(let current) = phase(for: wallpaperID, revision: libraryRevision), current == report else {
      throw Confirmation.notChecked
    }
    guard stamp == report.stamp else {
      AppLog.warn("Black bar result for \(wallpaperID) dropped: the video file changed since it was checked")
      records.removeValue(forKey: wallpaperID)
      order.removeAll { $0 == wallpaperID }
      touch()
      throw Confirmation.fileChanged
    }
    return report
  }

  func cancelAll() { cancelRunning() }

  private func cancelRunning() {
    generation &+= 1
    runningTask?.cancel()
    runningTask = nil
    guard running != nil else { return }
    running = nil
    touch()
  }

  private func touch() {
    changes &+= 1
    onChange?()
  }

  private func run(wallpaperID: String, displayID: String, revision: UInt64, ticket: UInt64) async {
    let clock = ContinuousClock()
    let started = clock.now
    let outcome: Phase
    do {
      let url = try await entry(wallpaperID, displayID)
      outcome = .done(try await probe.check(url))
    } catch is CancellationError {
      // Cancelled by a newer request, which owns the state now, or by the resolver itself, which
      // leaves this check unfinished: only then is there a running marker to clear.
      if generation == ticket {
        running = nil
        runningTask = nil
        touch()
      }
      return
    } catch let failure as VideoLetterboxProbe.Failure {
      outcome = .failed(failure)
    } catch {
      outcome = .failed(.unreadable(error.localizedDescription))
    }
    // Cancelled while it finished: a newer request owns the state now.
    guard generation == ticket, !Task.isCancelled else { return }
    let elapsed = started.duration(to: clock.now)
    let milliseconds = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    switch outcome {
    case .done(let report):
      AppLog.info("Black bar check for \(wallpaperID): \(report.sampled) frames, \(Self.describe(report.verdict)), \(milliseconds) ms")
    case .failed(let failure):
      AppLog.warn("Black bar check for \(wallpaperID) failed after \(milliseconds) ms: \(failure)")
    case .idle, .checking:
      break
    }
    records[wallpaperID] = Record(revision: revision, phase: outcome)
    order.removeAll { $0 == wallpaperID }
    order.append(wallpaperID)
    while order.count > Self.entryLimit { records.removeValue(forKey: order.removeFirst()) }
    running = nil
    runningTask = nil
    touch()
  }

  private static func describe(_ verdict: LetterboxDetector.Verdict) -> String {
    switch verdict {
    case .none: return "no bars"
    case .bars(let value): return "bars: \(value.summary)"
    case .uneven(let value): return "uneven bars: \(value.summary)"
    case .indeterminate(let reason): return "indeterminate: \(reason)"
    }
  }
}
