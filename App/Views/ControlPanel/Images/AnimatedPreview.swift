import AppKit
import ImageIO
import QuartzCore
import SwiftUI

/// The frames of an animated GIF, APNG or WebP, decoded one at a time.
///
/// Only the current frame is held, decoded at the size it is drawn, so an animation costs the
/// memory of one frame however long it is. Nothing is ever read back from the screen.
struct AnimatedFrames: @unchecked Sendable {
  private let source: CGImageSource
  let count: Int
  /// How long each frame stays, in seconds; the delays a browser would use: none below 20 ms.
  let delays: [TimeInterval]

  /// Nil unless `data` is an image with more than one frame.
  init?(data: Data) {
    guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      CGImageSourceGetCount(source) > 1
    else { return nil }
    self.source = source
    count = CGImageSourceGetCount(source)
    var delays: [TimeInterval] = []
    delays.reserveCapacity(count)
    for index in 0..<count {
      guard !Task.isCancelled else { return nil }
      delays.append(Self.delay(of: source, at: index))
    }
    self.delays = delays
  }

  /// Source metadata can be expensive too: a GIF's delays require reading every frame.
  nonisolated static func load(_ data: Data) async -> AnimatedFrames? {
    guard !Task.isCancelled else { return nil }
    let work = Task.detached(priority: .utility) { AnimatedFrames(data: data) }
    return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
  }

  /// Frame `index`, downsampled and prepared for the destination display off the main thread.
  /// ImageIO can return indexed pixels even for a thumbnail. Handing those straight to a layer
  /// makes Core Animation expand and color-convert them during the main-thread commit.
  func image(at index: Int, maxPixelSize: Int, colorSpace: CGColorSpace? = nil) -> CGImage? {
    guard (0..<count).contains(index) else { return nil }
    guard let image = CGImageSourceCreateThumbnailAtIndex(
      source, index,
      [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: max(16, maxPixelSize),
        kCGImageSourceShouldCache: false,
      ] as CFDictionary)
    else { return nil }
    // Keep higher-precision previews in their original format rather than quantizing them.
    guard image.bitsPerComponent <= 8 else { return image }
    let destination = colorSpace
      ?? (image.colorSpace?.model == .rgb ? image.colorSpace : CGColorSpace(name: CGColorSpace.sRGB))
    guard let destination,
      let context = CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
        space: destination,
        bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
    else { return image }
    context.setBlendMode(.copy)
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return context.makeImage()
  }

  /// A frame's delay, from whichever dictionary its format uses. Delays under 20 ms (including
  /// the 0 and 10 ms authors write to mean "as fast as possible") become 100 ms, as in browsers.
  nonisolated static func delay(of source: CGImageSource, at index: Int) -> TimeInterval {
    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
    else { return 0.1 }
    let candidates: [(CFString, CFString, CFString)] = [
      (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
      (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
      (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
    ]
    for (dictionary, unclamped, clamped) in candidates {
      guard let values = properties[dictionary] as? [CFString: Any] else { continue }
      let seconds =
        (values[unclamped] as? NSNumber)?.doubleValue ?? (values[clamped] as? NSNumber)?.doubleValue
      if let seconds { return seconds >= 0.02 ? seconds : 0.1 }
    }
    return 0.1
  }
}

/// Plays an animated image in place, only while `isPlaying`.
///
/// The still image that fills the same tile stays under it: when `isPlaying` is false, the
/// animation is torn down (timer stopped, frame released) and the view draws nothing. It also
/// stops when the window is not visible and shows only its first frame under Reduce Motion, so an
/// animation never runs where nobody can see it or where the user asked for none. Frames are
/// decoded off the main thread, one ahead of the one on show, so a page of animations never takes
/// the time a scroll needs. `data` is what `PanelImagePipeline.animation(for:)` returned, already
/// held to its budget.
struct AnimatedPreview: NSViewRepresentable {
  let data: Data?
  let isPlaying: Bool
  var contentMode: ContentMode = .fill

  func makeNSView(context: Context) -> AnimatedPreviewView { AnimatedPreviewView() }

  func updateNSView(_ view: AnimatedPreviewView, context: Context) {
    view.contentMode = contentMode
    view.set(data: data)
    view.setPlaying(isPlaying)
  }

  static func dismantleNSView(_ view: AnimatedPreviewView, coordinator: ()) {
    view.setPlaying(false)
    view.set(data: nil)
  }
}

@MainActor
final class AnimatedPreviewView: NSView {
  var contentMode: ContentMode = .fill {
    didSet { if contentMode != oldValue { needsLayout = true } }
  }
  private var frames: AnimatedFrames?
  private let prepareFrames: @Sendable (Data) async -> AnimatedFrames?
  private var sourceLoad: Task<Void, Never>?
  private var loadedData: Data?
  private var index = 0
  private var timer: Timer?
  /// The frame after `index`, decoded and waiting for its turn.
  private var upcoming: CGImage?
  private var hasUpcoming = false
  /// The current frame's time is up and the next one is still being decoded: it goes on show as
  /// soon as it arrives.
  private var isOverdue = false
  /// The decode under way. Cancelled when what it decodes is no longer wanted, and checked again
  /// on its return, so a late frame is never drawn.
  private var decode: Task<Void, Never>?
  private var isPlaying = false
  private var occlusionObserver: NSObjectProtocol?
  private let content = CALayer()

  override convenience init(frame: NSRect) {
    self.init(frame: frame, prepareFrames: { await AnimatedFrames.load($0) })
  }

  init(frame: NSRect, prepareFrames: @escaping @Sendable (Data) async -> AnimatedFrames?) {
    self.prepareFrames = prepareFrames
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = true
    content.contentsGravity = .resizeAspectFill
    layer?.addSublayer(content)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  deinit {
    sourceLoad?.cancel()
    timer?.invalidate()
    if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
  }

  override var isFlipped: Bool { true }

  func set(data: Data?) {
    guard data != loadedData else { return }
    loadedData = data
    sourceLoad?.cancel()
    sourceLoad = nil
    stop()
    frames = nil
    index = 0
    content.contents = nil
    guard let data else { return }
    let prepare = prepareFrames
    sourceLoad = Task { [weak self] in
      let frames = await prepare(data)
      guard !Task.isCancelled, let self else { return }
      self.sourceLoad = nil
      self.frames = frames
      if self.isPlaying { self.start() }
    }
  }

  func setPlaying(_ playing: Bool) {
    guard playing != isPlaying else { return }
    isPlaying = playing
    if playing { start() } else { stop() }
  }

  /// The frame currently drawn, for tests.
  var currentFrameIndex: Int { index }
  var isAnimating: Bool { timer != nil }
  var preparedFrameCount: Int { frames?.count ?? 0 }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    content.frame = bounds
    content.contentsGravity = contentMode == .fill ? .resizeAspectFill : .resizeAspect
    CATransaction.commit()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    occlusionObserver = nil
    guard let window else {
      stop()
      return
    }
    occlusionObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.visibilityChanged() }
    }
    if isPlaying { start() }
  }

  private var canAnimate: Bool {
    isPlaying && frames != nil && window?.occlusionState.contains(.visible) == true
  }

  private func visibilityChanged() {
    if canAnimate, timer == nil { start() } else if !canAnimate { stopTimer() }
  }

  /// Shows the current frame once it is decoded, then plays on from it unless Reduce Motion is on.
  private func start() {
    guard frames != nil, canAnimate else { return }
    stopTimer()
    let shown = index
    decodeFrame(shown) { [weak self] image in
      guard let self, let frames = self.frames else { return }
      self.content.contents = image
      guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
      self.prepareUpcoming()
      self.schedule(after: frames.delays[shown])
    }
  }

  private func stop() {
    stopTimer()
    index = 0
    content.contents = nil
  }

  /// Stops the clock and drops the frame being decoded or waiting; the frame on show stays.
  private func stopTimer() {
    timer?.invalidate()
    timer = nil
    decode?.cancel()
    decode = nil
    upcoming = nil
    hasUpcoming = false
    isOverdue = false
  }

  private func schedule(after delay: TimeInterval) {
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.advance() }
    }
  }

  /// The current frame's time is up: the next one goes on show if it is ready, or as soon as it is.
  private func advance() {
    timer = nil
    guard let frames, canAnimate else { return stopTimer() }
    guard hasUpcoming else {
      isOverdue = true
      return
    }
    index = (index + 1) % frames.count
    content.contents = upcoming
    upcoming = nil
    hasUpcoming = false
    isOverdue = false
    prepareUpcoming()
    schedule(after: frames.delays[index])
  }

  /// Starts decoding the frame after the one on show.
  private func prepareUpcoming() {
    guard let frames else { return }
    decodeFrame((index + 1) % frames.count) { [weak self] image in
      guard let self else { return }
      self.upcoming = image
      self.hasUpcoming = true
      if self.isOverdue { self.advance() }
    }
  }

  /// Decodes frame `index` at the size it is drawn, off the main thread, and hands it to `done`
  /// unless it was cancelled meanwhile. One decode at a time: a new one replaces the last.
  private func decodeFrame(_ index: Int, then done: @escaping @MainActor (CGImage?) -> Void) {
    guard let frames else { return }
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    let pixels = Int((max(bounds.width, bounds.height, 64) * scale).rounded(.up))
    let colorSpace = (window?.colorSpace ?? window?.screen?.colorSpace)?.cgColorSpace
    decode?.cancel()
    decode = Task { [weak self] in
      let image = await Task.detached(priority: .utility) {
        frames.image(at: index, maxPixelSize: pixels, colorSpace: colorSpace)
      }.value
      guard !Task.isCancelled, let self else { return }
      self.decode = nil
      done(image)
    }
  }
}
