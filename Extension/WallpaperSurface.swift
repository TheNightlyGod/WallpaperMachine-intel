import AppKit
import CoreVideo
import IOSurface
import Metal

/// One WallpaperID is one compositor surface: never share a CAContext across Spaces.
@MainActor
final class WallpaperSurface: LockScreenSurfaceLifecycle {
  let context: CAContext
  let root: CALayer
  private(set) var scene: LockScreenScene
  let displayID: UInt32?
  private(set) var size: CGSize
  private(set) var scale: CGFloat
  let preview: Bool
  var presentation = "active"
  var activity = "active"
  private var layer: CAMetalLayer?
  private var renderer: OpaquePointer?
  private var web: ScreenSaverWebSurface?
  /// The player of a plain video wallpaper (an AVFoundation layer, or the WebM player for the files
  /// AVFoundation cannot open), in place of `renderer`.
  private var video: LockScreenVideoPlaying?
  private var nativeStart: Task<Void, Never>?
  private var contentError: Error?
  /// Set once, when the engine reports it cannot draw the scene (Native Metal is the only renderer), or when
  /// the extension's players cannot play a video. The surface then keeps what it shows
  /// and says why; it is not a `contentError`, because the surface is alive and showing a picture, and
  /// the same wallpaper can reuse it.
  private var heldFailure: LockScreenHeldFailure?
  /// The localized note about `heldFailure` the readiness file carries to the app.
  private(set) var heldNotice: String?
  private var frameObserver: NSObjectProtocol?
  private var firstFrameReply: ((Error?) -> Void)?
  private var readyWaiters: [(Error?) -> Void] = []
  private var deadline: Task<Void, Never>?
  private var snapshotWaiters: [(Any?, Error?) -> Void] = []
  private var snapshotDeadline: Task<Void, Never>?
  private var latestSnapshot: IOSurface?
  private var stopped = false
  var isReusable: Bool { !stopped && contentError == nil }
  var hasContent: Bool {
    renderer != nil || video != nil || heldFailure != nil || (web != nil && contentError == nil)
  }
  private var rendererPaused = false
  /// When this surface started presenting, set once its first frame arrived.
  /// Kept apart from readiness so rendering one frame for a snapshot or a
  /// readiness reply cannot become a permanent right to keep rendering.
  private var presentingSince: ContinuousClock.Instant?
  private var previewExpiry: Task<Void, Never>?
  /// An explicit opt-in for a preview that has to keep animating. No host
  /// request sets it today; it exists so the bounded behaviour has a documented
  /// escape hatch rather than being unconditional.
  var continuousPreviewRequested = false
  private let counters: RuntimeCounters
  private var surfaceKey: RuntimeSurfaceKey {
    RuntimeSurfaceKey(
      kind: preview ? .preview : .lockScreen, displayID: scene.displayID, generation: generation)
  }
  private let generation: UInt64

  init(
    scene: LockScreenScene, displayID: UInt32?, size: CGSize, scale: CGFloat, preview: Bool,
    generation: UInt64 = 0, counters: RuntimeCounters? = nil
  ) throws {
    try Self.validate(size: size, scale: scale)
    self.scene = scene
    self.displayID = displayID
    self.size = size
    self.scale = scale
    self.preview = preview
    self.generation = generation
    self.counters = counters ?? .shared
    context = try WallpaperRuntime.context(displayID: displayID)
    root = CALayer()
    root.frame = CGRect(origin: .zero, size: size)
    root.contentsScale = scale
    context.layer = root
    CATransaction.flush()
  }

  private static func validate(size: CGSize, scale: CGFloat) throws {
    guard size.width.isFinite, size.height.isFinite, scale.isFinite,
      size.width > 0, size.height > 0, scale > 0,
      size.width * scale <= 16_384, size.height * scale <= 16_384,
      size.width * size.height * scale * scale <= 32 * 1024 * 1024
    else { throw WallpaperRuntime.failure("Invalid wallpaper surface dimensions.") }
  }

  func start(completion: @escaping (Error?) -> Void) {
    guard !stopped, renderer == nil, web == nil, video == nil else {
      completion(WallpaperRuntime.failure("Wallpaper surface is not available."))
      return
    }
    do {
      let project = try WallpaperRuntime.asset(scene.projectPath)
      let assets = try WallpaperRuntime.asset(scene.assetsPath)
      contentError = nil
      if let entry = scene.webEntryFile {
        try startWeb(project: project, entry: entry, completion: completion)
        return
      }
      guard scene.fps > 0, (0...4).contains(scene.scalingMode), scene.scalingFactor.isFinite,
        scene.scalingFactor > 0, scene.framing?.isValid ?? true
      else {
        throw WallpaperRuntime.failure("Invalid lock-screen playback configuration.")
      }
      if scene.plainVideo == true {
        startVideo(completion: completion)
        return
      }
      try startEngine(project: project, assets: assets, completion: completion)
    } catch {
      stop()
      completion(error)
    }
  }

  /// The scene engine's start: its Metal layer, the renderer and its configuration.
  private func startEngine(
    project: URL, assets: URL, completion: @escaping (Error?) -> Void
  ) throws {
    let cache = WallpaperRuntime.documents.appendingPathComponent("ShaderCache")
      .appendingPathComponent(project.deletingLastPathComponent().lastPathComponent)
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    let metal = CAMetalLayer()
    metal.device = MTLCreateSystemDefaultDevice()
    metal.frame = root.bounds
    metal.contentsScale = scale
    metal.drawableSize = CGSize(width: size.width * scale, height: size.height * scale)
    metal.pixelFormat = .bgra8Unorm
    metal.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
    metal.framebufferOnly = false
    // An absent/purged drawable must reveal the committed frame underneath.
    metal.isOpaque = false
    guard metal.device != nil else {
      throw WallpaperRuntime.failure("Metal rendering is unavailable.")
    }
    root.addSublayer(metal)
    layer = metal
    CATransaction.flush()
    frameObserver = NotificationCenter.default.addObserver(
      forName: .init("WallpaperMachine.desktopPosterReady"), object: metal, queue: .main
    ) { [weak self] notification in
      MainActor.assumeIsolated { self?.receive(notification) }
    }
    try check(owe_scene_wallpaper_new(&renderer))
    try check(owe_scene_wallpaper_init(renderer))
    try check(
      owe_scene_wallpaper_init_metal(
        renderer, Unmanaged.passUnretained(metal).toOpaque(), UInt32(metal.drawableSize.width),
        UInt32(metal.drawableSize.height), 0, 0, Double(scale)))
    // The lock-screen process never plays sound, reads input, or receives media data.
    try check(
      owe_scene_wallpaper_set_property_bool(
        renderer, owe_property_audio_response_enabled(), false))
    try check(
      owe_scene_wallpaper_apply_config(
        renderer, project.path, assets.path, cache.path, scene.fps, false, 1, true, false,
        scene.propertiesJSON))
    try check(
      owe_scene_wallpaper_set_property_bool(
        renderer, owe_property_media_integration_enabled(), false))
    try check(
      owe_scene_wallpaper_set_property_int32(
        renderer, owe_property_scaling_mode(), scene.scalingMode))
    try check(
      owe_scene_wallpaper_set_property_float(
        renderer, owe_property_scaling_factor(), Float(scene.scalingFactor)))
    let framing = scene.effectiveFraming
    try check(owe_scene_wallpaper_set_framing(renderer, framing.panX, framing.panY))
    WallpaperRuntime.log(
      "Framing display=\(scene.displayID) panX=\(framing.panX) panY=\(framing.panY)")
    try installEngineSignals(renderer)
    firstFrameReply = completion
    requestFrame()
    armDeadline()
  }

  /// What the engine tells this surface without being asked, read when it does. A held scene never
  /// produces the poster the first frame waits for, so the engine's own first-frame edge, which it
  /// raises for a held failure too, is what ends that wait. A frame that fails after the scene drew has
  /// no poster to wait for and nothing to replace: the surface already shows the last frame.
  private enum EngineSignal { case firstFrame, renderFailed }

  private final class EngineSignalBox {
    let fire: () -> Void
    init(_ fire: @escaping () -> Void) { self.fire = fire }
  }

  private func installEngineSignals(_ renderer: OpaquePointer?) throws {
    func callback(_ signal: EngineSignal) -> UnsafeMutableRawPointer {
      Unmanaged.passRetained(
        EngineSignalBox { [weak self] in
          Task { @MainActor in self?.engineSignalled(signal) }
        }
      ).toOpaque()
    }
    let drop: @convention(c) (UnsafeMutableRawPointer?) -> Void = { pointer in
      if let pointer { Unmanaged<EngineSignalBox>.fromOpaque(pointer).release() }
    }
    let fire: @convention(c) (UnsafeMutableRawPointer?) -> Void = { pointer in
      guard let pointer else { return }
      Unmanaged<EngineSignalBox>.fromOpaque(pointer).takeUnretainedValue().fire()
    }
    let first = callback(.firstFrame)
    let firstResult = owe_scene_wallpaper_set_first_frame_callback(renderer, fire, first, drop)
    // A refusal does not take ownership of the box.
    if firstResult != 0 { drop(first) }
    try check(firstResult)
    let failed = callback(.renderFailed)
    let failedResult = owe_scene_wallpaper_set_render_failure_callback(renderer, fire, failed, drop)
    if failedResult != 0 { drop(failed) }
    try check(failedResult)
  }

  private func engineSignalled(_ signal: EngineSignal) {
    guard !stopped, renderer != nil, let held = engineHeldFailure() else { return }
    settleHeld(held, afterSignal: signal)
  }

  /// The engine's reason for holding this scene, when it is held.
  private func engineHeldFailure() -> LockScreenHeldFailure? {
    guard let renderer else { return nil }
    let scene = UnsafeMutableRawPointer(renderer)
    var reason = ""
    let needed = owe_scene_wallpaper_backend_failure_reason(scene, nil, 0)
    if needed > 0 {
      var buffer = [CChar](repeating: 0, count: needed + 1)
      _ = owe_scene_wallpaper_backend_failure_reason(scene, &buffer, buffer.count)
      reason = String(cString: buffer)
    }
    return LockScreenHeldFailure(rawStage: owe_scene_wallpaper_backend_failure(scene), reason: reason)
  }

  /// Native Metal could not draw the scene, or no player could play the video. Said once, in the log and in
  /// the readiness the app reads; the surface keeps its last frame, or shows the engine's preview picture.
  private func settleHeld(_ held: LockScreenHeldFailure, afterSignal signal: EngineSignal) {
    guard heldFailure == nil else { return }
    heldFailure = held
    heldNotice = Self.heldMessage(held)
    WallpaperRuntime.log(
      "Held display=\(scene.displayID) \(held.logDetail); not drawn, holding the last frame or the preview picture")
    switch signal {
    case .firstFrame:
      // The picture the wait was for is the one on the surface, so the wait is over. The preview, when
      // the project has one, is a sublayer the engine put on this surface's layer.
      guard let reply = firstFrameReply else { break }
      firstFrameReply = nil
      deadline?.cancel()
      deadline = nil
      presentingSince = ContinuousClock.now
      applyPolicy()
      reply(nil)
      let waiters = readyWaiters
      readyWaiters.removeAll()
      waiters.forEach { $0(nil) }
      finishSnapshots(error: latestSnapshot == nil ? WallpaperRuntime.failure("Wallpaper frame is not ready.") : nil)
    case .renderFailed:
      // After the scene drew: nothing to replace. The note reaches the app with the next readiness.
      WallpaperController.shared.acknowledge(surface: self)
    }
  }

  /// The words the app shows for a held scene, in the extension's language.
  static func heldMessage(_ held: LockScreenHeldFailure) -> String {
    let stage: String
    switch held.stage {
    case .unsupported: stage = String(localized: "it uses something Native Metal can't draw")
    case .prepare: stage = String(localized: "Native Metal couldn't start")
    case .compile: stage = String(localized: "its shaders didn't compile for Metal")
    case .frame: stage = String(localized: "a frame failed in Native Metal")
    case .surface: stage = String(localized: "Native Metal couldn't take the new display")
    case .video:
      return String(
        localized: "This video can't be played: \(held.reason). The lock screen keeps its last frame.")
    }
    let detail = held.reason.isEmpty ? stage : stage + " " + String(localized: "(reason: \(held.reason))")
    return String(
      localized:
        "Native Metal can't draw this wallpaper: \(detail). The lock screen shows its last frame, or its preview picture when it has drawn nothing yet."
    )
  }

  private func armDeadline() {
    deadline?.cancel()
    deadline = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(30)) } catch { return }
      guard let self, let reply = self.firstFrameReply else { return }
      self.firstFrameReply = nil
      self.stop()
      reply(
        WallpaperRuntime.failure(
          "The lock-screen renderer did not produce a frame within 30 seconds."))
    }
  }

  /// What the attempt to play the clip came to: a player showing its first frame, or the reason no
  /// player of the app's own could take it.
  private enum VideoAttempt {
    case unplayable(reason: String)
    case ready(LockScreenVideoPlaying, CGImage)
  }

  /// A plain video: decided against the same admission rule the desktop uses and played by the
  /// extension's own players, an AVFoundation layer or the WebM player. There is no other renderer for
  /// a video, so a clip they cannot take, before the first frame or after it, is held and reported.
  /// The attempt, from the decision to the first frame, has its own deadline, so a player that neither
  /// shows a frame nor fails is reported while the host is still waiting.
  private func startVideo(completion: @escaping (Error?) -> Void) {
    firstFrameReply = completion
    armDeadline()
    let scene = scene
    nativeStart = Task { @MainActor [weak self] in
      guard let self else { return }
      let attempt: VideoAttempt
      do {
        attempt = try await LockScreenDeadline.run(within: LockScreenDeadline.nativeAttempt) {
          [weak self] in
          guard let self else { throw CancellationError() }
          return try await self.attemptVideo(scene: scene)
        }
      } catch {
        guard !Task.isCancelled, !self.stopped, self.firstFrameReply != nil else { return }
        self.video?.stop()
        self.video = nil
        self.holdVideo(error.localizedDescription)
        return
      }
      guard !Task.isCancelled, !self.stopped, self.firstFrameReply != nil else {
        if case .ready(let player, _) = attempt, self.video !== player { player.stop() }
        return
      }
      switch attempt {
      case .unplayable(let reason):
        self.holdVideo(reason)
      case .ready(let player, let first):
        guard self.video === player else { return }
        do {
          let snapshot = try Self.snapshot(first)
          try LockScreenFrameBacking.install(snapshot, on: self.root)
          self.latestSnapshot = snapshot
        } catch {
          player.stop()
          self.video = nil
          self.holdVideo(error.localizedDescription)
          return
        }
        self.contentFrameReady()
        self.finishSnapshots(error: nil)
        // Last, so a failure the player already held is heard once the surface is ready for it.
        player.onFailure = { [weak self] detail in
          MainActor.assumeIsolated { self?.videoDidFail(detail) }
        }
      }
    }
  }

  private func attemptVideo(scene: LockScreenScene) async throws -> VideoAttempt {
    let path = await LockScreenVideoPlanner.decide(
      scene: scene, resolve: { try WallpaperRuntime.asset($0) })
    try Task.checkCancellation()
    let framing = scene.effectiveFraming
    let mode = NativeVideoScalingMode(rendererValue: scene.scalingMode) ?? .fill
    let pan = NativeVideoLayout.Pan(x: framing.panX, y: framing.panY)
    let player: LockScreenVideoPlaying
    switch path {
    case .avFoundation(let url):
      player = LockScreenVideoPlayer(
        url: url, mode: mode, factor: scene.scalingFactor, pan: pan, viewport: size,
        backingScale: self.scale)
    case .webM(_, let file):
      player = LockScreenWebMPlayer(
        file: file, mode: mode, factor: scene.scalingFactor, pan: pan, viewport: size,
        backingScale: self.scale)
    case .unplayable(let reason):
      return .unplayable(reason: reason)
    }
    video = player
    player.attach(to: root)
    do {
      guard let first = try await player.prepare() else {
        throw LockScreenVideoPlayer.Failure.unplayable("no frame could be read from the clip")
      }
      try Task.checkCancellation()
      return .ready(player, first)
    } catch {
      // Stopped here, not by the caller, which may have moved on to another player.
      player.stop()
      if video === player { video = nil }
      if error is CancellationError || (error as? LockScreenVideoPlayer.Failure) == .stopped {
        throw error
      }
      return .unplayable(reason: error.localizedDescription)
    }
  }

  /// The clip cannot be played and nothing else draws a video: the surface keeps the frame it shows
  /// (nothing, when it never had one) and says why, in the log and in the readiness the app reads. The
  /// host is told a picture exists even then, because it would otherwise wait out its whole deadline.
  private func holdVideo(_ reason: String) {
    nativeStart = nil
    guard !stopped else { return }
    settleHeld(
      LockScreenHeldFailure(video: reason),
      afterSignal: firstFrameReply != nil ? .firstFrame : .renderFailed)
  }

  /// The player stopped being able to play a clip it was playing. The frame it left on the surface
  /// stays, and the failure is reported.
  private func videoDidFail(_ detail: String) {
    guard !stopped, video != nil else { return }
    video?.stop()
    video = nil
    holdVideo(detail)
  }

  private func check(_ result: Int32) throws {
    guard result != 0 else { return }
    let message =
      owe_last_error().map { String(cString: $0) } ?? String(localized: "Unknown native rendering error.")
    throw WallpaperRuntime.failure(detail: message)
  }

  private func requestFrame() {
    if let layer {
      NotificationCenter.default.post(
        name: .init("WallpaperMachine.requestDesktopPoster"), object: layer)
    }
  }

  private func receive(_ notification: Notification) {
    guard !stopped, let data = notification.userInfo?["pixels"] as? Data,
      let width = notification.userInfo?["width"] as? Int,
      let height = notification.userInfo?["height"] as? Int,
      let bgra = notification.userInfo?["bgra"] as? Bool
    else { return }
    do {
      let snapshot = try Self.snapshot(data, width: width, height: height, bgra: bgra)
      try LockScreenFrameBacking.install(snapshot, on: root)
      latestSnapshot = snapshot
      contentFrameReady()
      finishSnapshots(error: nil)
    } catch {
      if let reply = firstFrameReply {
        firstFrameReply = nil
        stop()
        reply(error)
      }
      finishSnapshots(error: error)
    }
  }
  private func contentFrameReady() {
    guard let reply = firstFrameReply else { return }
    firstFrameReply = nil
    deadline?.cancel()
    deadline = nil
    presentingSince = ContinuousClock.now
    logBackend()
    counters.record(.readinessFrameRendered, for: surfaceKey)
    applyPolicy()
    reply(nil)
    let waiters = readyWaiters
    readyWaiters.removeAll()
    waiters.forEach { $0(nil) }
  }

  /// Which backend drew the first frame. The backend is only known once the scene is parsed, which the
  /// first frame proves.
  private func logBackend() {
    if video != nil {
      WallpaperRuntime.log(
        "Backend display=\(scene.displayID) drew=\(video is LockScreenWebMPlayer ? "WebM video" : "AVFoundation video")")
      return
    }
    guard let renderer else { return }
    let backend =
      owe_scene_wallpaper_backend(UnsafeMutableRawPointer(renderer))
        == Int32(OWE_SCENE_BACKEND_NATIVE_METAL.rawValue) ? "native Metal" : "unknown"
    WallpaperRuntime.log("Backend display=\(scene.displayID) drew=\(backend)")
  }

  private func startWeb(project: URL, entry: String, completion: @escaping (Error?) -> Void) throws {
    let page = try ScreenSaverWebSurface(
      projectURL: project.deletingLastPathComponent(), entryFile: entry,
      readAccessURL: project.deletingLastPathComponent(),
      size: size, scale: scale, propertiesJSON: scene.propertiesJSON ?? "{}", fps: scene.fps,
      paused: !WallpaperPresentationAuthority.suspensionReasons(for: authorityRequest).isEmpty)
    web = page
    firstFrameReply = completion
    page.onFrame = { [weak self] image in
      guard let self, !self.stopped else { throw CancellationError() }
      guard let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        throw ScreenSaverWebSurface.Failure.noFrame
      }
      let frame = try Self.snapshot(pixels)
      try LockScreenFrameBacking.install(frame, on: self.root)
      self.latestSnapshot = frame
    }
    page.onFailure = { [weak self] error in
      guard let self, !self.stopped else { return }
      self.contentError = error
      let waiters = self.readyWaiters
      self.readyWaiters.removeAll()
      waiters.forEach { $0(error) }
      self.finishSnapshots(error: error)
      WallpaperController.shared.acknowledge(surface: self, error: error)
    }
    try page.attach(to: root)
    page.start { [weak self] error in
      guard let self, !self.stopped else { return }
      if let error {
        self.contentError = error
        let reply = self.firstFrameReply
        self.firstFrameReply = nil
        reply?(error)
      } else {
        self.contentFrameReady()
      }
    }
  }


  private static func snapshot(_ data: Data, width: Int, height: Int, bgra: Bool) throws
    -> IOSurface
  {
    guard width > 0, height > 0, width <= 16_384, height <= 16_384,
      width * height <= 32 * 1024 * 1024, data.count == width * height * 4,
      let provider = CGDataProvider(data: data as CFData)
    else { throw CocoaError(.fileReadCorruptFile) }
    let bitmap =
      bgra
      ? CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
      : CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
    guard
      let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: bitmap),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else { throw CocoaError(.fileReadCorruptFile) }
    return try snapshot(image)
  }

  private static func snapshot(_ image: CGImage) throws -> IOSurface {
    let width = image.width
    let height = image.height
    guard width > 0, height > 0, width <= 16_384, height <= 16_384,
      width * height <= 32 * 1024 * 1024,
      let surface = IOSurface(properties: [
        .width: width, .height: height, .bytesPerElement: 4,
        .pixelFormat: kCVPixelFormatType_32BGRA,
      ])
    else { throw CocoaError(.fileReadCorruptFile) }
    surface.lock(options: [], seed: nil)
    defer { surface.unlock(options: [], seed: nil) }
    guard
      let target = CGContext(
        data: surface.baseAddress, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: surface.bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue)
    else { throw CocoaError(.fileReadCorruptFile) }
    target.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return surface
  }

  func update(scene: LockScreenScene) {
    self.scene = scene
    if let renderer {
      do { try check(owe_scene_wallpaper_set_target_fps(renderer, scene.fps)) } catch {
        WallpaperRuntime.log(error.localizedDescription)
      }
    }
    if let web {
      do {
        try web.update(propertiesJSON: scene.propertiesJSON ?? "{}", fps: scene.fps,
          paused: !WallpaperPresentationAuthority.suspensionReasons(for: authorityRequest).isEmpty)
      } catch {
        contentError = error
        web.stop()
        WallpaperController.shared.acknowledge(surface: self, error: error)
      }
    }
    applyPolicy()
  }

  /// Presentation eligibility for this surface, decided by the rules both
  /// processes share. A preview is bounded in time: producing the readiness
  /// frame must not buy it the right to animate for as long as a settings
  /// window happens to stay open.
  private var authorityRequest: WallpaperPresentationAuthority.Request {
    // Native desktop holds a frame once it has settled; the ordinary desktop renderer remains live.
    let locked =
      (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool
      ?? false
    return WallpaperPresentationAuthority.Request(
      role: preview ? .preview : .lockScreen,
      userPaused: scene.paused,
      displaysAsleep: WallpaperController.shared.displayPower.displaysAsleep(for: displayID),
      sessionLocked: locked,
      presentationMode: presentation,
      hostActivity: activity == "suspended" ? .suspended : .active,
      presentedFor: presentingSince.map { ContinuousClock.now - $0 },
      continuousPreviewRequested: continuousPreviewRequested,
      lockScreenEnabled: scene.webEntryFile == nil
        && (WallpaperController.shared.configuration?.lockScreenEnabled ?? false),
      screenSaverEnabled: WallpaperController.shared.configuration?.screenSaverEnabled ?? false)
  }

  func applyPolicy() {
    guard firstFrameReply == nil, !stopped, renderer != nil || web != nil || video != nil else {
      return
    }
    let request = authorityRequest
    // Keep the last drawable and scene state through unlock/sleep. Replacing
    // them with a poster forces a cold load after the display is already lit.
    let reasons = WallpaperPresentationAuthority.suspensionReasons(for: request)
    let shouldPause = !reasons.isEmpty
    schedulePreviewExpiry(for: request)
    guard shouldPause != rendererPaused else { return }
    do {
      if let web {
        web.setPaused(shouldPause)
      } else if let video {
        video.setPaused(shouldPause)
      } else if let renderer {
        try check(owe_scene_wallpaper_set_paused(renderer, shouldPause))
      }
      rendererPaused = shouldPause
      // The held frame becomes what snapshots and the backing show, in place of
      // the readiness frame (often an intro's black opening).
      if shouldPause, renderer != nil { requestFrame() }
      if shouldPause, video != nil { refreshVideoFrame() }
      counters.record(shouldPause ? .presentationSuspended : .presentationAuthorized, for: surfaceKey)
      WallpaperRuntime.log(
        "Playback display=\(scene.displayID) mode=\(presentation) activity=\(activity) locked=\(request.sessionLocked) paused=\(shouldPause) reasons=\(reasons.rawValue)"
      )
    } catch { WallpaperRuntime.log(error.localizedDescription) }
  }

  /// Re-evaluates a preview when its budget runs out, or a desktop when it has
  /// settled, so it stops on its own rather than waiting for a host update that
  /// may never come.
  private func schedulePreviewExpiry(for request: WallpaperPresentationAuthority.Request) {
    previewExpiry?.cancel()
    previewExpiry = nil
    guard let remaining = WallpaperPresentationAuthority.nextReevaluation(for: request) else {
      return
    }
    previewExpiry = Task { [weak self] in
      do { try await Task.sleep(for: remaining) } catch { return }
      guard let self, !Task.isCancelled else { return }
      self.previewExpiry = nil
      self.applyPolicy()
    }
  }

  /// The held frame of a paused clip becomes what snapshots and the backing show, in place of
  /// the frame it opened with.
  private func refreshVideoFrame() {
    guard let video else { return }
    Task { @MainActor [weak self, weak video] in
      guard let self, let video, self.video === video, self.rendererPaused,
        let frame = await video.frame(), self.video === video, self.rendererPaused,
        let snapshot = try? Self.snapshot(frame)
      else { return }
      try? LockScreenFrameBacking.install(snapshot, on: self.root)
      self.latestSnapshot = snapshot
    }
  }

  func snapshot(reply: @escaping (Any?, Error?) -> Void) {
    if let web, !web.isPaused, !rendererPaused, !stopped {
      web.snapshot { [weak self] result in
        guard let self else { reply(nil, CancellationError()); return }
        do {
          let image = try result.get()
          guard let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ScreenSaverWebSurface.Failure.noFrame
          }
          let frame = try Self.snapshot(pixels)
          self.latestSnapshot = frame
          reply(try WallpaperRuntime.snapshotReply(frame), nil)
        } catch { reply(nil, error) }
      }
      return
    }
    if let video, !rendererPaused, !stopped {
      Task { @MainActor [weak self] in
        guard let self else { reply(nil, CancellationError()); return }
        do {
          if let frame = await video.frame(), !self.stopped {
            let snapshot = try Self.snapshot(frame)
            self.latestSnapshot = snapshot
          }
          guard let latest = self.latestSnapshot else {
            throw WallpaperRuntime.failure("Wallpaper frame is not ready.")
          }
          reply(try WallpaperRuntime.snapshotReply(latest), nil)
        } catch { reply(nil, error) }
      }
      return
    }
    if rendererPaused || stopped {
      do {
        guard let latestSnapshot else {
          throw WallpaperRuntime.failure("Wallpaper frame is not ready.")
        }
        reply(try WallpaperRuntime.snapshotReply(latestSnapshot), nil)
      } catch { reply(nil, error) }
      return
    }
    snapshotWaiters.append(reply)
    requestFrame()
    guard snapshotDeadline == nil else { return }
    snapshotDeadline = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(3)) } catch { return }
      // A frame already known to have been presented is safe if rendering paused meanwhile.
      self?.finishSnapshots(
        error: self?.latestSnapshot == nil
          ? WallpaperRuntime.failure("Wallpaper snapshot timed out.") : nil)
    }
  }

  private func finishSnapshots(error: Error?) {
    snapshotDeadline?.cancel()
    snapshotDeadline = nil
    let waiters = snapshotWaiters
    snapshotWaiters.removeAll()
    for reply in waiters {
      do {
        if let error { throw error }
        guard let latestSnapshot else {
          throw WallpaperRuntime.failure("Wallpaper snapshot is unavailable.")
        }
        reply(try WallpaperRuntime.snapshotReply(latestSnapshot), nil)
      } catch { reply(nil, error) }
    }
  }

  func whenReady(_ reply: @escaping (Error?) -> Void) {
    if stopped {
      reply(CancellationError())
    } else if let contentError {
      reply(contentError)
    } else if latestSnapshot != nil, firstFrameReply == nil {
      reply(nil)
    } else if heldFailure != nil, firstFrameReply == nil {
      // Held, with a picture on the surface but no snapshot of it: that is as ready as it will get.
      reply(nil)
    } else {
      readyWaiters.append(reply)
    }
  }

  func replace(
    scene: LockScreenScene, size: CGSize, scale: CGFloat,
    completion: @escaping (Error?) -> Void
  ) {
    guard !stopped else {
      completion(CancellationError())
      return
    }
    do { try Self.validate(size: size, scale: scale) } catch {
      completion(error)
      return
    }
    releaseRenderer(keepingFrame: true)
    self.scene = scene
    self.size = size
    self.scale = scale
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    root.frame = CGRect(origin: .zero, size: size)
    root.contentsScale = scale
    CATransaction.commit()
    rendererPaused = false
    start(completion: completion)
  }

  private func releaseRenderer(keepingFrame: Bool = false) {
    deadline?.cancel()
    deadline = nil
    previewExpiry?.cancel()
    previewExpiry = nil
    presentingSince = nil
    if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
    frameObserver = nil
    web?.stop()
    web = nil
    nativeStart?.cancel()
    nativeStart = nil
    video?.stop()
    video = nil
    contentError = nil
    heldFailure = nil
    heldNotice = nil
    if let renderer {
      _ = owe_scene_wallpaper_begin_surface_reconfigure(renderer)
      _ = owe_scene_wallpaper_shutdown(renderer)
      _ = owe_scene_wallpaper_delete(renderer)
    }
    renderer = nil
    layer?.removeFromSuperlayer()
    layer = nil
    if let reply = firstFrameReply {
      firstFrameReply = nil
      reply(CancellationError())
    }
    rendererPaused = true
    let waiters = readyWaiters
    readyWaiters.removeAll()
    waiters.forEach { $0(CancellationError()) }
    finishSnapshots(error: CancellationError())
    latestSnapshot = nil
    if !keepingFrame { root.contents = nil }
  }

  func clear() {
    releaseRenderer()
    CATransaction.flush()
  }

  func stop() {
    guard !stopped else { return }
    stopped = true
    releaseRenderer()
    context.invalidate()
  }
}
