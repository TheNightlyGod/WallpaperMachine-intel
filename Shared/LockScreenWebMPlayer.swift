import CoreGraphics
import Foundation
import QuartzCore
import WallpaperMedia

/// Plays a WebM or Matroska video wallpaper on the lock screen and as the screen saver, with the same
/// `WebMPlayer` the desktop uses, in the extension's own layer tree.
///
/// What it leaves out on purpose, because the lock-screen process never plays sound: the player is made
/// without audio, so no sound is decoded, no audio renderer is made and no audio session is touched. It
/// is a layer, not a window, so where the picture goes follows `NativeVideoLayout`, including the
/// position the app publishes; and a clip it cannot play (the system's decoder refuses it, or the
/// pipeline stops after a resume and repairs do not help) is reported through `onFailure`, which the
/// surface answers by drawing the scene with the scene engine, the same as for the AVFoundation layer.
@MainActor
final class LockScreenWebMPlayer: LockScreenVideoPlaying {
  private let player: WebMPlayer
  private let mode: NativeVideoScalingMode
  private let factor: Double
  private let pan: NativeVideoLayout.Pan
  private let viewport: CGSize
  private let backingScale: CGFloat
  private let borderColor: CGColor?
  private var preparing: CheckedContinuation<Void, Error>?
  private var stopped = false
  private(set) var isPaused = false

  var onFailure: ((String) -> Void)? {
    didSet { deliverPendingFailure() }
  }
  private var pendingFailure: String?
  private var failureLatched = false

  init(
    file: WebMFile, mode: NativeVideoScalingMode, factor: Double,
    pan: NativeVideoLayout.Pan = .centered, viewport: CGSize, backingScale: CGFloat,
    options: WallpaperEngineOptions = .identity, lut: VideoLut? = nil, borderColor: CGColor? = nil
  ) {
    self.mode = mode
    self.factor = factor
    self.pan = pan
    self.viewport = viewport
    self.backingScale = backingScale
    self.borderColor = borderColor
    player = WebMPlayer(file: file, withAudio: false, paused: false)
    player.setScaling(mode, factor: factor, pan: pan)
    player.relayout(bounds: CGRect(origin: .zero, size: viewport), backingScale: backingScale)
    player.setEngineOptions(options, lut: lut, borderColor: borderColor)
  }

  func attach(to root: CALayer) {
    player.attach(to: root)
  }

  func prepare() async throws -> CGImage? {
    // A surface stopped before the preparation began would otherwise wait for a picture that never comes.
    guard !stopped else { throw LockScreenVideoPlayer.Failure.stopped }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      preparing = continuation
      player.onFailure = { [weak self] detail, _ in self?.fail(detail) }
      player.onReadyForDisplay = { [weak self] in self?.finishPreparing(nil) }
      // Playing until the first frame is ready is what makes the layer ready; the surface pauses it
      // again as soon as the policy says so.
      player.start()
    }
    return await frame()
  }

  private func finishPreparing(_ error: Error?) {
    guard let continuation = preparing else { return }
    preparing = nil
    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
  }

  /// Before the first frame a failure fails `prepare()`; afterwards it is the surface's to hear.
  private func fail(_ detail: String) {
    guard !stopped else { return }
    if preparing != nil {
      finishPreparing(LockScreenVideoPlayer.Failure.unplayable(detail))
    } else if !failureLatched {
      failureLatched = true
      pendingFailure = detail
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

  func setPaused(_ paused: Bool) {
    guard !stopped, paused != isPaused else { return }
    isPaused = paused
    player.setPaused(paused)
    // A pipeline that stops delivering after the display or the Mac slept raises no error, so a
    // resumed player is looked at: one that did not move is handed to the scene engine.
    if !paused { player.verifyPlayback(reason: "the lock screen resumed the clip") }
  }

  func frame() async -> CGImage? {
    guard !stopped else { return nil }
    let pixels = CGSize(width: viewport.width * backingScale, height: viewport.height * backingScale)
    guard pixels.width > 0, pixels.height > 0, let image = await player.posterImage() else { return nil }
    return NativeVideoLayout.composeFrame(
      image, pixelSize: pixels, backingScale: backingScale, mode: mode, factor: factor, pan: pan,
      borderColor: borderColor)
  }

  func stop() {
    guard !stopped else { return }
    stopped = true
    pendingFailure = nil
    onFailure = nil
    finishPreparing(LockScreenVideoPlayer.Failure.stopped)
    player.stop()
  }
}
