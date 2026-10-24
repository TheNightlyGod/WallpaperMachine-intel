import AVFoundation
import CoreGraphics
import Foundation
import QuartzCore

/// What the lock-screen surface needs of whatever plays a plain video: the AVFoundation layer below or
/// the WebM player (`LockScreenWebMPlayer`). Both are built from the clip's video alone, muted, and
/// leave the sound out entirely.
@MainActor
protocol LockScreenVideoPlaying: AnyObject {
  var isPaused: Bool { get }
  /// Called once, with the reason, when a clip that was playing can no longer be: the surface then
  /// draws it with the scene engine. A failure that arrives with no handler is held until one is set.
  var onFailure: ((String) -> Void)? { get set }
  /// Puts the picture's layer into `root`, whose bounds are the display.
  func attach(to root: CALayer)
  /// Starts the clip and returns once a frame can be shown, with that frame composed at the display's
  /// size. Throws when the clip cannot be played.
  func prepare() async throws -> CGImage?
  func setPaused(_ paused: Bool)
  /// The picture on the display now, composed where the layer puts it.
  func frame() async -> CGImage?
  func stop()
}

/// Plays a plain video wallpaper on the lock screen and as the screen saver through an
/// `AVPlayerLayer` in the extension's own layer tree, so the system decodes it in hardware and
/// the process does no per-frame work.
///
/// What it leaves out on purpose, because the lock-screen process never plays sound:
/// the player is built from the clip's video track alone, so no audio is decoded, no audio
/// output is opened and no audio session is taken; it is muted as well, and it asks neither to
/// keep the display awake nor to take over system playback. It is a layer, not a window, so
/// where the picture goes follows `NativeVideoLayout`, the rule the desktop's native player and
/// the scene engine share, including the position the app publishes.
///
/// Compiled by both targets so the failure behaviour is tested: a clip AVFoundation cannot open
/// fails `prepare()`, and the surface then draws it with the scene engine.
@MainActor
final class LockScreenVideoPlayer: LockScreenVideoPlaying {
  enum Failure: Error, LocalizedError, Equatable {
    case unplayable(String)
    case stopped

    var errorDescription: String? {
      switch self {
      case .unplayable(let detail): detail
      case .stopped: "the player was stopped"
      }
    }
  }

  /// How long a resumed player has to show it is advancing before it is judged stalled.
  static let stallCheckDelay = Duration.seconds(4)

  private let url: URL
  private let mode: NativeVideoScalingMode
  private let factor: Double
  private let pan: NativeVideoLayout.Pan
  private let viewport: CGSize
  private let backingScale: CGFloat
  private let player = AVQueuePlayer()
  private let layer = AVPlayerLayer()
  private var looper: AVPlayerLooper?
  private var observations: [NSKeyValueObservation] = []
  private var presentationSize: CGSize?
  private var preparing: CheckedContinuation<Void, Error>?
  private var stallCheck: Task<Void, Never>?
  private var stopped = false
  private(set) var isPaused = false
  /// Called once, with the reason, when a clip that was playing can no longer be: the item
  /// failed, or a resumed player never advanced. The surface then draws it with the scene
  /// engine.
  ///
  /// A failure that arrives while no handler is set is held and handed over the moment one is,
  /// so the window between the first frame and the assignment cannot lose it.
  var onFailure: ((String) -> Void)? {
    didSet { deliverPendingFailure() }
  }
  private var pendingFailure: String?
  private var failureLatched = false

  init(
    url: URL, mode: NativeVideoScalingMode, factor: Double,
    pan: NativeVideoLayout.Pan = .centered, viewport: CGSize, backingScale: CGFloat
  ) {
    self.url = url
    self.mode = mode
    self.factor = factor
    self.pan = pan
    self.viewport = viewport
    self.backingScale = backingScale
    player.actionAtItemEnd = .advance
    player.isMuted = true
    player.volume = 0
    // Nothing here is playback the system should know about.
    player.preventsDisplaySleepDuringVideoPlayback = false
    player.allowsExternalPlayback = false
    layer.player = player
    layer.videoGravity = .resizeAspectFill
  }

  /// Puts the layer into `root`, whose bounds are the display. The overflow of Fill, Original
  /// size and a large scale factor is cropped there.
  func attach(to root: CALayer) {
    root.masksToBounds = true
    root.addSublayer(layer)
    applyPlacement()
  }

  /// Opens the clip and returns once a frame can be shown, with that frame composed at the
  /// display's size. Throws when AVFoundation cannot play the clip.
  func prepare() async throws -> CGImage? {
    let item = try await Self.videoOnlyItem(url: url)
    guard !stopped else { throw Failure.stopped }
    let looper = AVPlayerLooper(player: player, templateItem: item)
    self.looper = looper
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      preparing = continuation
      observations = [
        layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
          guard layer.isReadyForDisplay else { return }
          Task { @MainActor [weak self] in self?.finishPreparing(nil) }
        },
        looper.observe(\.status, options: [.initial, .new]) { [weak self] looper, _ in
          guard looper.status == .failed else { return }
          let detail = looper.error?.localizedDescription ?? "the player looper failed"
          Task { @MainActor [weak self] in self?.fail(detail) }
        },
        player.observe(\.currentItem, options: [.initial, .new]) { [weak self] player, _ in
          let item = player.currentItem
          Task { @MainActor [weak self] in self?.follow(item) }
        },
      ]
      // Playing until the first frame is ready is what makes the layer ready; the surface
      // pauses it again as soon as the policy says so.
      player.play()
    }
    return await frame()
  }

  private var itemObservation: NSKeyValueObservation?
  private var sizeObservation: NSKeyValueObservation?
  private weak var followed: AVPlayerItem?

  private func follow(_ item: AVPlayerItem?) {
    guard !stopped, let item, item !== followed else { return }
    followed = item
    itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
      guard item.status == .failed else { return }
      let detail = item.error?.localizedDescription ?? "the player item failed"
      Task { @MainActor [weak self] in self?.fail(detail) }
    }
    sizeObservation = item.observe(\.presentationSize, options: [.initial, .new]) {
      [weak self] item, _ in
      let size = item.presentationSize
      Task { @MainActor [weak self] in
        guard let self, !self.stopped, size.width > 0, size.height > 0,
          size != self.presentationSize
        else { return }
        self.presentationSize = size
        self.applyPlacement()
      }
    }
  }

  private func finishPreparing(_ error: Error?) {
    guard let continuation = preparing else { return }
    preparing = nil
    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
  }

  /// Before the first frame a failure fails `prepare()`; afterwards it is the surface's to hear.
  func fail(_ detail: String) {
    guard !stopped else { return }
    if preparing != nil {
      finishPreparing(Failure.unplayable(detail))
    } else if !failureLatched {
      failureLatched = true
      pendingFailure = detail
      stallCheck?.cancel()
      deliverPendingFailure()
    }
  }

  /// Hands the held failure to the handler, once: the handler is dropped as it is called.
  private func deliverPendingFailure() {
    guard !stopped, let detail = pendingFailure, let handler = onFailure else { return }
    pendingFailure = nil
    onFailure = nil
    handler(detail)
  }

  private func applyPlacement() {
    guard !stopped else { return }
    let placement = NativeVideoLayout.placement(
      mode: mode, factor: factor, videoSize: presentationSize, viewport: viewport,
      backingScale: backingScale, pan: pan)
    // A sliding picture would show the layout settling.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    switch placement {
    case .gravity(let gravity):
      layer.videoGravity = gravity
      layer.frame = CGRect(origin: .zero, size: viewport)
    case .frame(let rect):
      // The rectangle already has the picture's own aspect.
      layer.videoGravity = .resize
      // The layout measures from the top edge and the root layer grows upward.
      layer.frame = NativeVideoLayout.layerFrame(rect, viewportHeight: viewport.height)
    case .pending:
      break
    }
  }

  /// Plays or holds the clip. A held clip keeps its last frame on the layer and decodes nothing.
  func setPaused(_ paused: Bool) {
    guard !stopped, paused != isPaused else { return }
    isPaused = paused
    stallCheck?.cancel()
    stallCheck = nil
    if paused {
      player.pause()
    } else {
      player.play()
      scheduleStallCheck()
    }
  }

  /// A pipeline that stops delivering after the display or the Mac slept raises no error, so a
  /// resumed player is looked at once: one that has not moved is handed to the scene engine.
  private func scheduleStallCheck() {
    let before = player.currentItem?.currentTime()
    stallCheck = Task { [weak self] in
      do { try await Task.sleep(for: Self.stallCheckDelay) } catch { return }
      guard let self, !self.stopped, !self.isPaused, self.preparing == nil else { return }
      let now = self.player.currentItem?.currentTime()
      guard let before, let now, CMTimeCompare(before, now) == 0 else { return }
      self.fail("playback did not advance after it was resumed")
    }
  }

  /// The picture on the display now, composed where the layer puts it, read through an image
  /// generator for this one request: nothing is decoded between requests.
  func frame() async -> CGImage? {
    guard !stopped else { return nil }
    let pixels = CGSize(width: viewport.width * backingScale, height: viewport.height * backingScale)
    guard pixels.width > 0, pixels.height > 0 else { return nil }
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 4)
    generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 4)
    // Enough for the largest picture the layout can make from a display-sized frame without
    // reading an 8K clip at full size.
    generator.maximumSize = CGSize(
      width: min(pixels.width * 2, 16_384), height: min(pixels.height * 2, 16_384))
    let time = player.currentItem?.currentTime() ?? .zero
    guard let image = try? await generator.image(at: time.isValid ? time : .zero).image
    else { return nil }
    return NativeVideoLayout.composeFrame(
      image, pixelSize: pixels, backingScale: backingScale, mode: mode, factor: factor, pan: pan)
  }

  func stop() {
    guard !stopped else { return }
    stopped = true
    stallCheck?.cancel()
    stallCheck = nil
    pendingFailure = nil
    onFailure = nil
    observations.removeAll()
    itemObservation = nil
    sizeObservation = nil
    finishPreparing(Failure.stopped)
    looper?.disableLooping()
    looper = nil
    player.pause()
    player.removeAllItems()
    layer.player = nil
    layer.removeFromSuperlayer()
  }

  /// The clip's video track alone, with its display matrix: the same picture the file shows and
  /// nothing that makes sound. Throws for a file AVFoundation cannot play, or that has no video.
  static func videoOnlyItem(url: URL) async throws -> AVPlayerItem {
    let asset = AVURLAsset(url: url)
    do {
      guard try await asset.load(.isPlayable) else {
        throw Failure.unplayable("the asset reports itself unplayable")
      }
      guard let video = try await asset.loadTracks(withMediaType: .video).first else {
        throw Failure.unplayable("the asset has no video track")
      }
      let (range, transform) = try await video.load(.timeRange, .preferredTransform)
      let composition = AVMutableComposition()
      guard
        let track = composition.addMutableTrack(
          withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
      else { throw Failure.unplayable("no track could be made for the clip") }
      try track.insertTimeRange(range, of: video, at: .zero)
      track.preferredTransform = transform
      return AVPlayerItem(asset: composition)
    } catch let failure as Failure {
      throw failure
    } catch {
      throw Failure.unplayable(error.localizedDescription)
    }
  }
}
