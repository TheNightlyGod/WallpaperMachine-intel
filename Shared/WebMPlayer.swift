import AVFoundation
import CoreMedia
import Foundation
import QuartzCore
import WallpaperMedia
import os

/// What a look at a WebM player's pipeline found, and what was done about it. The desktop surface
/// turns it into the health events the host logs and counts.
struct WebMHealthReport: Equatable {
  enum Verdict: Equatable {
    /// Frames were shown (or dropped on their deadline) and the clock moved.
    case advancing
    /// Something that should be moving was not; the text says what was seen.
    case stalled(String)
  }
  enum Repair: Equatable {
    case none
    /// The pipeline was flushed and fed again from where the clock is.
    case restarted
    /// Nothing left to try.
    case gaveUp
  }

  var trigger: String
  var verdict: Verdict
  var repair: Repair
  /// Whether this is the look that follows a repair, not the first look.
  var afterRepair = false
}

/// Plays a WebM or Matroska file with `AVSampleBufferDisplayLayer`: the project's own reader gives
/// compressed samples, the system decodes and shows them, and an `AVSampleBufferRenderSynchronizer`
/// keeps the picture and the sound on one clock. Decoding stays with the system's decoders (hardware,
/// including VP9 through VideoToolbox's supplemental decoder), so the process does no per-frame work
/// beyond handing the next compressed sample over.
///
/// - **Feeding** happens on a serial queue, from `requestMediaDataWhenReady`: a renderer that has room
///   asks for more and a sample goes in. Nothing runs while the renderer is full, and nothing runs
///   while the clock is stopped for long, because a stopped clock fills the renderers and stops the
///   requests.
/// - **Looping** is gapless by timestamps, not by seeking the player: at the end of the file the
///   reader goes back to the first key frame and its timestamps are raised by one duration, so the
///   clock runs on and no flush happens. The sound does the same and is cut where the picture ends.
/// - **Sound** is decoded to PCM by the reader (Opus, Vorbis, AAC, MP3) and played by an
///   `AVSampleBufferAudioRenderer` on the same synchronizer; without `withAudio` no audio is decoded,
///   no renderer is made and no audio session is touched, which is what the lock screen needs.
/// - **Placement** follows `NativeVideoLayout`, the rule the AVFoundation player and the scene engine
///   share, including the position, and the file's own orientation.
///
/// Compiled by the app and by the lock-screen extension.
@MainActor
final class WebMPlayer {
  /// Frames-per-second below which a clip is not judged by how often it feeds the renderer.
  static let healthWindowSeconds = 2.0
  static let healthWindow = Duration.seconds(healthWindowSeconds)
  /// The renderer's notifications, by name: Swift's own spellings of them are deprecated in the newest
  /// SDK in favour of an API that needs macOS 27.
  private static let didFailToDecode = Notification.Name("AVSampleBufferVideoRendererDidFailToDecodeNotification")
  private static let didFailToDecodeErrorKey = "AVSampleBufferVideoRendererDidFailToDecodeNotificationErrorKey"
  private static let requiresFlushDidChange = Notification.Name(
    "AVSampleBufferVideoRendererRequiresFlushToResumeDecodingDidChangeNotification")
  static let healthSettle = Duration.milliseconds(500)
  /// How long a stopped player must have been paused before resuming it is worth a health check.
  static let minimumPauseForCheck = Duration.seconds(5)

  let file: WebMFile
  /// The layer the picture is drawn on. Put it somewhere with `attach(to:)`.
  let layer = AVSampleBufferDisplayLayer()

  private let synchronizer = AVSampleBufferRenderSynchronizer()
  private let audioRenderer: AVSampleBufferAudioRenderer?
  private let feeder: WebMFeeder
  private let queue: DispatchQueue
  private let now: @MainActor () -> ContinuousClock.Instant
  private let sleep: @Sendable (Duration) async throws -> Void
  private var recovery: NativeVideoRecoveryBudget

  private var started = false
  private var stopped = false
  private var paused: Bool
  private var pausedSince: ContinuousClock.Instant?
  private var failureLatched = false
  private var hasShownFrame = false
  private var audioActive: Bool
  private var observers: [NSObjectProtocol] = []
  private var statusObservation: NSKeyValueObservation?
  private var healthTask: Task<Void, Never>?
  private var decodeFailures = 0
  private var firstDecodeFailure: String?
  // Repositioning the readers happens on the feed queue and never blocks the main actor: a read
  // from a volume that has stopped answering would freeze the app. `feedEpoch` retires the
  // repositionings that are in flight when the player stops or fails.
  private var feedEpoch = 0
  private var repositioning = 0
  private var restartAfterReposition = false

  // Placement.
  private var mode: NativeVideoScalingMode = .fill
  private var factor = 1.0
  private var pan = NativeVideoLayout.Pan.centered
  private var viewport = CGRect.zero
  private var backingScale: CGFloat = 1

  /// Why the file's sound is not played, when the file has some and it cannot be: the codec is not
  /// decodable, the reader refused the track. nil when it plays, or when none was asked for.
  private(set) var audioUnavailableReason: String?

  /// Called once with the reason when the clip can no longer be played: the system's decoder refused
  /// it, or the pipeline stopped delivering and repairs did not bring it back. The second argument
  /// says whether the failure is a verdict on the file (a decoder that never opened it) and not on
  /// the moment (a pipeline the system took away while the Mac slept). A failure that arrives with
  /// no handler is held and delivered when one is set.
  var onFailure: ((String, Bool) -> Void)? {
    didSet { deliverPendingFailure() }
  }
  private var pendingFailure: (detail: String, settled: Bool)?
  /// The sound failed and the clip goes on without it.
  var onAudioDropped: ((String) -> Void)?
  /// The first picture is on the layer.
  var onReadyForDisplay: (() -> Void)? {
    didSet { if isReadyForDisplay { onReadyForDisplay?() } }
  }
  var onHealthReport: ((WebMHealthReport) -> Void)?

  /// The clock the picture and the sound follow. Runs on past the file's end at every loop.
  var currentTime: CMTime { synchronizer.currentTime() }
  var videoSamplesFed: UInt64 { feeder.videoSamplesEnqueued }
  var isReadyForDisplay: Bool { !stopped && layer.isReadyForDisplay }
  var isPlaying: Bool { started && !stopped && !failureLatched && !paused }

  init(
    file: WebMFile, withAudio: Bool, paused: Bool,
    recovery: NativeVideoRecoveryBudget.Policy = .init(),
    feedQueue: DispatchQueue = DispatchQueue(label: "app.wallpapermachine.webm-feed", qos: .userInitiated),
    now: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.file = file
    self.paused = paused
    self.recovery = NativeVideoRecoveryBudget(policy: recovery)
    self.queue = feedQueue
    self.now = now
    self.sleep = sleep

    var audioReader: WebMAudioReader?
    if withAudio {
      if file.hasPlayableAudio {
        do { audioReader = try file.makeAudioReader() } catch {
          audioUnavailableReason = error.localizedDescription
        }
      } else if let reason = file.audioUnavailableReason {
        audioUnavailableReason = reason
      }
    }
    audioRenderer = audioReader == nil ? nil : AVSampleBufferAudioRenderer()
    audioActive = audioReader != nil
    feeder = WebMFeeder(file: file, audio: audioReader)

    layer.videoGravity = .resizeAspectFill
    layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    synchronizer.addRenderer(layer.sampleBufferRenderer)
    if let audioRenderer { synchronizer.addRenderer(audioRenderer) }
    synchronizer.setRate(0, time: file.firstPresentationTime)
    feeder.onFailure = { [weak self] detail in
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.fail(detail, settled: false) } }
    }
    feeder.onAudioFailure = { [weak self] detail in
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.dropAudio(detail) } }
    }
    observe()
  }

  // MARK: - Layer and placement

  /// Puts the layer into `root`, whose bounds are the display. The overflow of Fill, Original size and
  /// a large scale factor is cropped there.
  func attach(to root: CALayer) {
    root.masksToBounds = true
    root.addSublayer(layer)
    applyPlacement()
  }

  func relayout(bounds: CGRect, backingScale: CGFloat) {
    viewport = bounds
    self.backingScale = backingScale
    applyPlacement()
  }

  func setScaling(_ mode: NativeVideoScalingMode, factor: Double, pan: NativeVideoLayout.Pan) {
    self.mode = mode
    self.factor = factor
    self.pan = pan
    applyPlacement()
  }

  private func applyPlacement() {
    guard !stopped else { return }
    let size = file.presentationSize
    let upright = file.preferredTransform.isIdentity
    var placement = NativeVideoLayout.placement(
      mode: mode, factor: factor, videoSize: size, viewport: viewport.size,
      backingScale: backingScale, pan: pan)
    if !upright, case .gravity = placement {
      // Gravity centres the stored picture before the turn, so a turned clip is placed by its frame.
      let rect = NativeVideoLayout.pictureRect(
        mode: mode, factor: factor, videoSize: size, viewport: viewport.size,
        backingScale: backingScale, pan: pan)
      let scale = CGFloat(NativeVideoLayout.normalizedFactor(Double(backingScale)))
      placement = .frame(
        CGRect(
          x: CGFloat(rect.x) / scale, y: CGFloat(rect.y) / scale, width: CGFloat(rect.width) / scale,
          height: CGFloat(rect.height) / scale))
    }
    // A sliding picture would show the layout settling.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    switch placement {
    case .gravity(let gravity):
      layer.setAffineTransform(.identity)
      layer.videoGravity = gravity
      layer.frame = viewport
    case .frame(let rect):
      // The rectangle already has the picture's own aspect, so nothing but a plain stretch may
      // apply another aspect rule to it.
      layer.videoGravity = .resize
      // The layout measures from the top edge and the container's layer grows upward.
      let target = NativeVideoLayout.layerFrame(rect, viewportHeight: viewport.height)
        .offsetBy(dx: viewport.minX, dy: viewport.minY)
      if upright {
        layer.setAffineTransform(.identity)
        layer.frame = target
      } else {
        // The layer keeps the stored shape and is turned about its centre onto the target.
        let stored = file.transformSwapsAxes ? CGSize(width: target.height, height: target.width) : target.size
        layer.setAffineTransform(.identity)
        layer.bounds = CGRect(origin: .zero, size: stored)
        layer.position = CGPoint(x: target.midX, y: target.midY)
        layer.setAffineTransform(file.layerTransform)
      }
    case .pending:
      break
    }
  }

  // MARK: - Sound

  func setVolume(_ volume: Float, muted: Bool) {
    guard let audioRenderer, audioActive else { return }
    audioRenderer.volume = max(0, min(1, volume))
    audioRenderer.isMuted = muted
  }

  private func dropAudio(_ detail: String) {
    guard !stopped, audioActive, let audioRenderer else { return }
    audioActive = false
    audioRenderer.stopRequestingMediaData()
    synchronizer.removeRenderer(audioRenderer, at: .zero, completionHandler: nil)
    audioUnavailableReason = detail
    onAudioDropped?(detail)
  }

  // MARK: - Running

  /// Begins feeding and, unless paused, the clock. Call once.
  func start() {
    guard !started, !stopped else { return }
    started = true
    startFeeding()
    synchronizer.setRate(paused ? 0 : 1, time: file.firstPresentationTime)
    if paused { pausedSince = now() }
  }

  /// Plays or holds the clip. A held clip keeps its last picture on the layer and decodes nothing:
  /// its renderers fill and stop asking for samples.
  func setPaused(_ value: Bool) {
    guard !stopped, value != paused else { return }
    paused = value
    guard started else { return }
    if value {
      pausedSince = now()
      synchronizer.rate = 0
      healthTask?.cancel()
      healthTask = nil
    } else {
      synchronizer.rate = 1
      if let since = pausedSince, now() - since >= Self.minimumPauseForCheck {
        verifyPlayback(reason: "resumed after \(Int((now() - since) / .seconds(1))) s")
      }
      pausedSince = nil
    }
  }

  func stop() {
    guard !stopped else { return }
    stopped = true
    healthTask?.cancel()
    healthTask = nil
    pendingFailure = nil
    onFailure = nil
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers.removeAll()
    statusObservation = nil
    abandonFeeding()
    synchronizer.rate = 0
    layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    audioRenderer?.flush()
    layer.removeFromSuperlayer()
    // The readers go once the queue has finished what it is doing; a read that hangs holds that
    // queue, not the caller.
    let feeder = self.feeder
    queue.async { feeder.release() }
  }

  private func startFeeding() {
    let feeder = self.feeder
    let video = layer.sampleBufferRenderer
    video.requestMediaDataWhenReady(on: queue) { [video] in
      if !feeder.feedVideo(into: video) { video.stopRequestingMediaData() }
    }
    if let audioRenderer, audioActive { startFeedingAudio(into: audioRenderer) }
  }

  private func startFeedingAudio(into audioRenderer: AVSampleBufferAudioRenderer) {
    let feeder = self.feeder
    audioRenderer.requestMediaDataWhenReady(on: queue) { [audioRenderer] in
      if !feeder.feedAudio(into: audioRenderer) { audioRenderer.stopRequestingMediaData() }
    }
  }

  /// Stops asking the renderers for samples. A feed callback that is already running finishes on
  /// the queue; nothing here waits for it.
  private func stopFeeding() {
    layer.sampleBufferRenderer.stopRequestingMediaData()
    audioRenderer?.stopRequestingMediaData()
  }

  /// Stops feeding for good and retires every repositioning still in flight.
  private func abandonFeeding() {
    stopFeeding()
    feedEpoch += 1
    repositioning = 0
    restartAfterReposition = false
  }

  /// Moves the readers on the feed queue, behind any feed callback already running there, and
  /// resumes feeding on the main actor once the last repositioning in flight is done.
  private func reposition(video: Bool, at time: CMTime) {
    repositioning += 1
    let feeder = self.feeder
    let epoch = feedEpoch
    queue.async { [weak self] in
      if video { feeder.reposition(at: time) } else { feeder.repositionAudio(at: time) }
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.repositioned(epoch) } }
    }
  }

  private func repositioned(_ epoch: Int) {
    guard !stopped, !failureLatched, epoch == feedEpoch else { return }
    repositioning -= 1
    guard repositioning == 0 else { return }
    if restartAfterReposition {
      restartAfterReposition = false
      // Everything a feed callback put in before the readers moved is flushed away here, behind
      // the queue's barrier, and the renderers are fed again from the new position.
      layer.sampleBufferRenderer.flush(removingDisplayedImage: false, completionHandler: nil)
      audioRenderer?.flush()
      decodeFailures = 0
      startFeeding()
    } else if let audioRenderer, audioActive {
      startFeedingAudio(into: audioRenderer)
    }
  }

  // MARK: - Failure and repair

  private func fail(_ detail: String, settled: Bool) {
    guard !stopped, !failureLatched else { return }
    failureLatched = true
    healthTask?.cancel()
    healthTask = nil
    pendingFailure = (detail, settled)
    abandonFeeding()
    synchronizer.rate = 0
    deliverPendingFailure()
  }

  private func deliverPendingFailure() {
    guard !stopped, let pending = pendingFailure, let handler = onFailure else { return }
    pendingFailure = nil
    handler(pending.detail, pending.settled)
  }

  /// Rebuilds the feed from where the clock is: renderers flushed, readers moved to the key frame
  /// before that time and the sound to the time itself. The clock is not touched, so frames before
  /// the time are decoded and dropped as late and the picture resumes where it was. False when the
  /// allowance for repairs is spent.
  @discardableResult
  func restartPlayback(reason: String) -> Bool {
    guard !stopped, !failureLatched, started, recovery.permit(at: now()) else { return false }
    rebuild()
    return true
  }

  private func rebuild() {
    let time = synchronizer.currentTime()
    stopFeeding()
    restartAfterReposition = true
    reposition(video: true, at: time.isNumeric ? time : file.firstPresentationTime)
  }

  private func observe() {
    let center = NotificationCenter.default
    let renderer = layer.sampleBufferRenderer
    observers.append(
      center.addObserver(
        forName: .AVSampleBufferDisplayLayerReadyForDisplayDidChange, object: layer, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.readyForDisplayChanged() }
      })
    observers.append(
      center.addObserver(
        forName: Self.didFailToDecode, object: renderer, queue: .main
      ) { [weak self] note in
        let error = note.userInfo?[Self.didFailToDecodeErrorKey] as? NSError
        MainActor.assumeIsolated { self?.decodeFailed(error) }
      })
    observers.append(
      center.addObserver(
        forName: Self.requiresFlushDidChange, object: renderer, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.requiresFlushChanged() }
      })
    if let audioRenderer {
      observers.append(
        center.addObserver(
          forName: .AVSampleBufferAudioRendererWasFlushedAutomatically, object: audioRenderer,
          queue: .main
        ) { [weak self] note in
          let time = (note.userInfo?[AVSampleBufferAudioRendererFlushTimeKey] as? NSValue)?.timeValue
          MainActor.assumeIsolated { self?.audioFlushed(at: time) }
        })
    }
    statusObservation = renderer.observe(\.status, options: [.new]) { [weak self] renderer, _ in
      guard renderer.status == .failed else { return }
      let detail = renderer.error?.localizedDescription ?? "the video renderer failed"
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.rendererFailed(detail) } }
    }
  }

  private func readyForDisplayChanged() {
    guard !stopped, layer.isReadyForDisplay else { return }
    hasShownFrame = true
    recovery.healthy(at: now())
    onReadyForDisplay?()
  }

  private func decodeFailed(_ error: NSError?) {
    guard !stopped else { return }
    decodeFailures += 1
    if firstDecodeFailure == nil { firstDecodeFailure = error?.localizedDescription ?? "a frame could not be decoded" }
    // A decoder that fails every frame from the first one never opened the track: that is the
    // file's verdict. A frame lost in the middle of a playing clip is a glitch.
    if !hasShownFrame, decodeFailures >= 3 {
      fail("the system could not decode the video: \(firstDecodeFailure ?? "unknown error")", settled: true)
    }
  }

  private func requiresFlushChanged() {
    guard !stopped, !failureLatched, layer.sampleBufferRenderer.requiresFlushToResumeDecoding else { return }
    // The system took the decoder back (a sleep, a session change); decoding resumes after a flush.
    if !restartPlayback(reason: "the renderer asked to be flushed") {
      fail("the video decoder was taken away and could not be restored", settled: false)
    }
  }

  private func rendererFailed(_ detail: String) {
    guard !stopped, !failureLatched else { return }
    if hasShownFrame, restartPlayback(reason: detail) { return }
    fail(detail, settled: !hasShownFrame)
  }

  /// The system flushed the sound by itself (the output device changed): feed it again from where it
  /// was flushed.
  private func audioFlushed(at time: CMTime?) {
    guard !stopped, !failureLatched, audioActive, let audioRenderer else { return }
    let at = time ?? synchronizer.currentTime()
    audioRenderer.stopRequestingMediaData()
    reposition(video: false, at: at.isNumeric ? at : file.firstPresentationTime)
  }

  // MARK: - Health

  /// Looks, after a short settle, at whether pictures still come out, and repairs the pipeline if they
  /// do not: for a reason the player cannot see itself (the Mac or its displays woke, the session came
  /// back, a long pause ended). A pipeline that is paused, was never shown or belongs to a single
  /// still picture is not judged.
  func verifyPlayback(reason: String) {
    guard started, !stopped, !failureLatched, !paused, hasShownFrame, file.frameCount > 1 else { return }
    healthTask?.cancel()
    let sleep = self.sleep
    healthTask = Task { @MainActor [weak self] in
      do { try await sleep(Self.healthSettle) } catch { return }
      guard let self else { return }
      await self.judge(trigger: reason, afterRepair: false)
    }
  }

  /// One look: the clock and the renderer's frame count, `healthWindow` apart.
  private func judge(trigger: String, afterRepair: Bool) async {
    guard !stopped, !failureLatched, !paused else { return }
    let before = await sample()
    do { try await sleep(afterRepair ? Self.healthWindow * 2 : Self.healthWindow) } catch { return }
    guard !stopped, !failureLatched, !paused, !Task.isCancelled else { return }
    let after = await sample()
    guard let before, let after else {
      // The system gave no frame counts: the clock alone cannot show a decoder alive.
      onHealthReport?(WebMHealthReport(trigger: trigger, verdict: .advancing, repair: .none, afterRepair: afterRepair))
      return
    }
    let clock = (after.time - before.time).seconds
    let frames = after.frames - before.frames
    if clock >= 0.5 * Self.healthWindowSeconds, frames > 0 {
      recovery.healthy(at: now())
      onHealthReport?(WebMHealthReport(trigger: trigger, verdict: .advancing, repair: .none, afterRepair: afterRepair))
      return
    }
    let detail = "the clock moved \(String(format: "%.1f", clock)) s and \(frames) frames were shown or dropped"
    if !afterRepair, restartPlayback(reason: detail) {
      onHealthReport?(WebMHealthReport(trigger: trigger, verdict: .stalled(detail), repair: .restarted, afterRepair: afterRepair))
      await judge(trigger: trigger, afterRepair: true)
      return
    }
    onHealthReport?(WebMHealthReport(trigger: trigger, verdict: .stalled(detail), repair: .gaveUp, afterRepair: afterRepair))
    fail("playback did not advance (\(detail))", settled: false)
  }

  private struct Sample {
    var time: CMTime
    var frames: Int
  }

  private func sample() async -> Sample? {
    let metrics = await layer.sampleBufferRenderer.videoPerformanceMetrics
    guard let metrics else { return nil }
    return Sample(time: synchronizer.currentTime(), frames: metrics.totalNumberOfFrames)
  }

  /// Where the pipeline stands, in one line for the log.
  var stateSummary: String {
    let renderer = layer.sampleBufferRenderer
    let status: String
    switch renderer.status {
    case .unknown: status = "unknown"
    case .rendering: status = "rendering"
    case .failed: status = "failed (\(renderer.error?.localizedDescription ?? "no error"))"
    @unknown default: status = "?"
    }
    let time = synchronizer.currentTime()
    return
      "renderer \(status), ready for display \(layer.isReadyForDisplay), clock "
      + "\(String(format: "%.2f", time.isNumeric ? time.seconds : -1)) s at rate \(synchronizer.rate), "
      + "\(feeder.videoSamplesEnqueued) samples fed, \(decodeFailures) decode failures"
  }

  // MARK: - Poster

  /// The picture on the display now, upright at the clip's shown size, decoded from the key frame at
  /// or before the clock. Decoded once for this request; nothing runs between requests.
  func posterImage() async -> CGImage? {
    guard !stopped else { return nil }
    let time = started ? synchronizer.currentTime() : file.firstPresentationTime
    let first = file.firstPresentationTime
    let length = file.duration
    // The clock runs on past the file's end at every loop; the picture is the one at the same point
    // of the pass.
    var inPass = time
    if time.isNumeric, length.isNumeric, length.seconds > 0, time >= first {
      let passes = floor((time - first).seconds / length.seconds)
      inPass = CMTimeSubtract(time, CMTimeMultiplyByFloat64(length, multiplier: passes))
    }
    let file = self.file
    return await Task.detached(priority: .utility) {
      file.copyPosterImage(at: inPass)
    }.value
  }
}

// MARK: - Feeding

/// Where the feeder puts samples: a renderer, or a recording stand-in in a test.
protocol WebMSampleSink: AnyObject {
  /// The sink can take another sample now.
  var hasRoom: Bool { get }
  func accept(_ buffer: CMSampleBuffer)
}

extension AVSampleBufferVideoRenderer: WebMSampleSink {
  var hasRoom: Bool { isReadyForMoreMediaData }
  func accept(_ buffer: CMSampleBuffer) { enqueue(buffer) }
}

extension AVSampleBufferAudioRenderer: WebMSampleSink {
  var hasRoom: Bool { isReadyForMoreMediaData }
  func accept(_ buffer: CMSampleBuffer) { enqueue(buffer) }
}

/// Hands the readers' samples to the renderers, and wraps them at the end of the file. Every method
/// runs on the player's feed queue, never two at once; the main actor never waits for it.
final class WebMFeeder: @unchecked Sendable {
  private let file: WebMFile
  private var video: WebMVideoReader?
  private var audio: WebMAudioReader?
  private let first: CMTime
  private let length: CMTime
  private let loops: Bool
  private var videoPass = 0
  private var audioPass = 0
  private var videoDone = false
  private var audioDone = false
  /// Audio buffers decoded to reach a time after a reposition, ahead of the reader's next.
  private var heldAudio: CMSampleBuffer?
  private let counters = OSAllocatedUnfairLock(initialState: UInt64(0))

  var onFailure: (@Sendable (String) -> Void)?
  var onAudioFailure: (@Sendable (String) -> Void)?

  init(file: WebMFile, audio: WebMAudioReader?) {
    self.file = file
    self.video = file.makeVideoReader()
    self.audio = audio
    first = file.firstPresentationTime
    length = file.duration
    // One frame is a still picture: it is shown and held, not looped.
    loops = file.frameCount > 1 && length.isNumeric && length.seconds > 0
    audio?.rewind(withTimeOffset: .zero, limit: loops ? length : .invalid)
  }

  var videoSamplesEnqueued: UInt64 { counters.withLock { $0 } }

  func release() {
    video = nil
    audio = nil
    heldAudio = nil
  }

  private func passOffset(_ pass: Int) -> CMTime {
    CMTimeMultiplyByFloat64(length, multiplier: Double(pass))
  }

  /// Feeds while the renderer has room. False once the video has ended for good.
  func feedVideo(into sink: WebMSampleSink) -> Bool {
    while sink.hasRoom {
      guard let sample = nextVideo() else { return !videoDone }
      sink.accept(sample)
      counters.withLock { $0 += 1 }
    }
    return true
  }

  private func nextVideo() -> CMSampleBuffer? {
    guard let video, !videoDone else { return nil }
    if let sample = video.copyNextSampleBuffer() { return sample }
    if let error = video.error {
      videoDone = true
      onFailure?("the video could not be read: \(error.localizedDescription)")
      return nil
    }
    guard loops else {
      videoDone = true
      return nil
    }
    videoPass += 1
    video.timeOffset = passOffset(videoPass)
    _ = video.seek(to: .negativeInfinity)
    if let sample = video.copyNextSampleBuffer() { return sample }
    videoDone = true
    onFailure?("the video could not be read again from its start")
    return nil
  }

  func feedAudio(into sink: WebMSampleSink) -> Bool {
    while sink.hasRoom {
      guard let buffer = nextAudio() else { return !audioDone }
      sink.accept(buffer)
    }
    return true
  }

  private func nextAudio() -> CMSampleBuffer? {
    guard let audio, !audioDone else { return nil }
    if let held = heldAudio {
      heldAudio = nil
      return held
    }
    if let buffer = audio.copyNextSampleBuffer() { return buffer }
    if let error = audio.error {
      audioDone = true
      onAudioFailure?(error.localizedDescription)
      return nil
    }
    guard loops else {
      audioDone = true
      return nil
    }
    audioPass += 1
    audio.rewind(withTimeOffset: passOffset(audioPass), limit: length)
    if let buffer = audio.copyNextSampleBuffer() { return buffer }
    if let error = audio.error { onAudioFailure?(error.localizedDescription) }
    audioDone = true
    return nil
  }

  /// Moves both readers to `time`: the video to the key frame at or before it within its pass, the
  /// sound to the buffer that covers it.
  func reposition(at time: CMTime) {
    let pass = passIndex(of: time)
    if let video {
      videoPass = pass
      video.timeOffset = passOffset(pass)
      _ = video.seek(to: CMTimeSubtract(time, passOffset(pass)))
      videoDone = false
    }
    repositionAudio(at: time)
  }

  func repositionAudio(at time: CMTime) {
    guard let audio else { return }
    let pass = passIndex(of: time)
    audioPass = pass
    audioDone = false
    heldAudio = nil
    audio.rewind(withTimeOffset: passOffset(pass), limit: loops ? length : .invalid)
    // Decode and drop what the clock has passed: the sound is rewound to its start and read forward.
    while let buffer = audio.copyNextSampleBuffer() {
      let end = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(buffer), CMSampleBufferGetDuration(buffer))
      if end > time {
        heldAudio = buffer
        break
      }
    }
  }

  private func passIndex(of time: CMTime) -> Int {
    guard loops, time.isNumeric, time >= first else { return 0 }
    return max(0, Int(floor((time - first).seconds / length.seconds)))
  }
}
