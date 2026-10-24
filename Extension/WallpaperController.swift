import AppKit

@MainActor
final class WallpaperController {
  static let shared = WallpaperController()
  private let surfaces = LockScreenSurfaceRegistry<WallpaperSurface>()
  private(set) var configuration: LockScreenConfiguration?
  private var observers: [NSObjectProtocol] = []
  /// Asked each time a surface decides whether to present, so a missed sleep or
  /// wake notification cannot leave it paused or rendering.
  let displayPower = DisplayPowerProbe.system
  /// Every signal that display power or the lock state may have changed only
  /// starts this: the answer comes from the system, now and over the next 2 s.
  private lazy var reevaluation = LockScreenReevaluationBurst(perform: { [weak self] in
    self?.surfaces.values.forEach { $0.applyPolicy() }
  })
  private var started = false
  /// Static so the extension's listener can count a connection off the main queue.
  nonisolated static let idleExit = LockScreenIdleExit(
    grace: .seconds(30),
    isBusy: { !WallpaperController.shared.surfaces.values.isEmpty },
    exit: {
      WallpaperRuntime.log("Exiting: no wallpaper host or surface remains.")
      Darwin.exit(0)
    })

  func start() {
    guard !started else { return }
    started = true
    WallpaperRuntime.removeLegacyExchange()
    reload()
    let workspace = NSWorkspace.shared.notificationCenter
    for (name, cause) in [
      (NSWorkspace.screensDidSleepNotification, "display sleep"),
      (NSWorkspace.screensDidWakeNotification, "display wake"),
      (NSWorkspace.willSleepNotification, "system sleep"),
      (NSWorkspace.didWakeNotification, "system wake"),
    ] {
      observers.append(
        workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.presentationEnvironmentChanged(cause: cause) }
        })
    }
    for (name, cause) in [
      ("com.apple.screenIsLocked", "screen locked"),
      ("com.apple.screenIsUnlocked", "screen unlocked"),
    ] {
      observers.append(
        DistributedNotificationCenter.default().addObserver(
          forName: .init(name), object: nil, queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated { self?.presentationEnvironmentChanged(cause: cause) }
        })
    }
    CFNotificationCenterAddObserver(
      CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
      { _, observer, _, _, _ in
        guard let observer else { return }
        let controller = Unmanaged<WallpaperController>.fromOpaque(observer).takeUnretainedValue()
        DispatchQueue.main.async { controller.reload() }
      }, LockScreenConfiguration.changedNotification as CFString, nil, .deliverImmediately)
  }

  func reload() {
    do {
      let next = try WallpaperRuntime.configuration()
      guard next != configuration else { return }
      configuration = next
      for surface in Array(surfaces.values) {
        guard let scene = selectScene(displayID: surface.displayID) else {
          surface.clear()
          continue
        }
        if surface.hasContent, surface.scene.sharesRenderer(with: scene) {
          surface.update(scene: scene)
          acknowledge(surface: surface)
        } else {
          // The hosted CAContext remains the same; only its child renderer changes.
          surface.replace(scene: scene, size: surface.size, scale: surface.scale) { [weak self, weak surface] error in
            guard let self, let surface else { return }
            self.acknowledge(surface: surface, error: error)
            if let error {
              WallpaperRuntime.log("Replacement failed: \(error.localizedDescription)")
            }
          }
        }
      }
      WallpaperRuntime.log("Configuration loaded scenes=\(next.scenes.count)")
    } catch {
      // A removed/corrupt manifest must never keep rendering a previously private scene.
      configuration = nil
      surfaces.values.forEach { $0.clear() }
      WallpaperRuntime.log("Configuration unavailable: \(error.localizedDescription)")
    }
  }

  func acknowledge(surface: WallpaperSurface, error: Error? = nil) {
    guard !surface.preview, let configuration,
      configuration.scenes.contains(surface.scene),
      surfaces.values.contains(where: { $0 === surface })
    else { return }
    let scene = surface.scene
    surface.whenReady { [weak self, weak surface] readyError in
      guard let self, let surface, self.configuration == configuration,
        surface.scene == scene, self.surfaces.values.contains(where: { $0 === surface }),
        !(readyError is CancellationError) || error != nil
      else { return }
      Self.record(
        LockScreenReadiness(
          revision: configuration.revision, displayID: scene.displayID,
          error: (error ?? readyError)?.localizedDescription, held: surface.heldNotice))
    }
  }

  /// A failure before any surface existed. Reported rather than left for the
  /// app to time out on, which it could only blame on macOS.
  private func acknowledge(scene: LockScreenScene, error: Error) {
    guard let configuration, configuration.scenes.contains(scene) else { return }
    Self.record(
      LockScreenReadiness(
        revision: configuration.revision, displayID: scene.displayID,
        error: error.localizedDescription))
  }

  private static func record(_ readiness: LockScreenReadiness) {
    var readiness = readiness
    readiness.processID = getpid()
    do {
      let data = try JSONEncoder().encode(readiness)
      try data.write(
        to: WallpaperRuntime.exchange.appendingPathComponent("ready-\(readiness.displayID).json"),
        options: .atomic)
    } catch {
      WallpaperRuntime.log("Readiness acknowledgement failed: \(error.localizedDescription)")
    }
  }

  private func selectScene(displayID: UInt32?) -> LockScreenScene? {
    guard let displayID else { return configuration?.scenes.first }
    return configuration?.scenes.first(where: { $0.displayID == displayID })
  }

  func acquire(id value: Any?, request: Any?, reply: @escaping (Any?, Error?) -> Void) {
    let started = ContinuousClock.now
    var acquiring: LockScreenScene?
    WallpaperRuntime.logRequestShape("acquire", request)
    do {
      guard let id = WallpaperRuntime.identifier(value), let request,
        let destination = WallpaperRuntime.field("destination", in: request),
        let size = WallpaperRuntime.field("size", in: destination) as? CGSize,
        let scale = WallpaperRuntime.field("scaleFactor", in: destination) as? CGFloat
      else {
        throw WallpaperRuntime.failure("Unsupported native wallpaper creation request.")
      }
      let displayID = WallpaperRuntime.field("directDisplayID", in: destination) as? UInt32
      let preview = WallpaperRuntime.field("isPreview", in: request) as? Bool ?? false
      reload()
      guard let scene = selectScene(displayID: displayID) else {
        throw WallpaperRuntime.failure(
          "No applied wallpaper is available for this display. Enable Animate Lock Screen or Use wallpaper as screen saver in WallpaperMachine."
        )
      }
      if !preview { acquiring = scene }
      let acquisition = try surfaces.acquire(
        id: id, matches: { $0.displayID == displayID && $0.preview == preview }
      ) { generation in
        try WallpaperSurface(
          scene: scene, displayID: displayID, size: size, scale: scale, preview: preview,
          generation: generation)
      }
      let surface = acquisition.surface
      let generation = acquisition.generation
      if let mode = WallpaperRuntime.field("presentationMode", in: request) {
        surface.presentation = WallpaperRuntime.enumCase(mode)
      }
      if let activity = WallpaperRuntime.field("activityState", in: request) {
        surface.activity = WallpaperRuntime.enumCase(activity)
      }
      let ready: (Error?) -> Void = { [weak self, weak surface] error in
        guard let self, let surface,
          self.surfaces.isCurrent(id: id, surface: surface, generation: generation)
        else {
          reply(nil, CancellationError())
          return
        }
        do {
          if let error { throw error }
          let contextReply = try WallpaperRuntime.contextReply(surface.context.contextId)
          self.acknowledge(surface: surface)
          let elapsed = ContinuousClock.now - started
          reply(contextReply, nil)
          self.logFirstFrame(id: id, scene: scene, preview: preview, elapsed: elapsed)
        } catch {
          if !(error is CancellationError) {
            WallpaperRuntime.log(
              "Acquire failed display=\(scene.displayID) after "
                + "\(LockScreenFirstFrameTiming.seconds(ContinuousClock.now - started)) s: "
                + error.localizedDescription)
            self.acknowledge(surface: surface, error: error)
          }
          self.surfaces.retireAfterFailure(id, surface: surface, error: error)
          reply(nil, error)
        }
      }
      if acquisition.isNew {
        surface.start(completion: ready)
      } else if surface.hasContent, surface.scene == scene, surface.size == size, surface.scale == scale {
        surface.applyPolicy()
        surface.whenReady(ready)
      } else {
        // Keep the hosted context while replacing its child renderer.
        surface.replace(scene: scene, size: size, scale: scale, completion: ready)
      }
    } catch {
      reply(nil, error)
      WallpaperRuntime.log("Acquire failed: \(error.localizedDescription)")
      if let acquiring { acknowledge(scene: acquiring, error: error) }
    }
  }

  /// The time from the request arriving to the reply carrying the surface. A first frame that
  /// takes most of WallpaperAgent's patience is called out on a line of its own.
  private func logFirstFrame(id: UUID, scene: LockScreenScene, preview: Bool, elapsed: Duration) {
    let seconds = LockScreenFirstFrameTiming.seconds(elapsed)
    let verdict = LockScreenFirstFrameTiming.classify(elapsed)
    WallpaperRuntime.log(
      "Acquired id=\(id) display=\(scene.displayID) preview=\(preview) "
        + "firstFrameAfter=\(seconds)s" + (verdict == .normal ? "" : " (\(verdict.rawValue))"))
    if verdict == .nearLimit {
      let patience = LockScreenFirstFrameTiming.seconds(LockScreenFirstFrameTiming.agentPatience)
      WallpaperRuntime.log(
        "First frame took \(seconds) s; WallpaperAgent gives up at about \(patience) s")
    }
  }

  /// A notice the wallpaper service forwards to its extensions. Waking is the only one that
  /// needs work: surfaces re-check whether they should be presenting. The others, such as
  /// `SignificantTimeChangeNotification`, are logged once so a new kind is noticed.
  func hostNotification(named name: String) {
    if name == "com.apple.wallpaper.hostDidWake" {
      presentationEnvironmentChanged(cause: "wallpaper service wake")
    } else if WallpaperRuntime.firstTime("host-notification-\(name)") {
      WallpaperRuntime.log("Host notification \(name) needs no action")
    }
  }

  /// Display power or the lock state may have changed. Nothing here trusts the signal to say
  /// which: each surface reads both from the system when it decides, now and again shortly
  /// after, because a display, a decoder or the session dictionary can trail the notification
  /// and some notifications never arrive.
  private func presentationEnvironmentChanged(cause: String) {
    WallpaperRuntime.log("Re-checking presentation (\(cause)) surfaces=\(surfaces.values.count)")
    reevaluation.trigger()
  }

  func update(id value: Any?, request: Any?) throws {
    WallpaperRuntime.logRequestShape("update", request)
    guard let id = WallpaperRuntime.identifier(value), let surface = surfaces[id], let request
    else { throw WallpaperRuntime.failure("Unknown wallpaper surface.") }
    if let mode = WallpaperRuntime.field("presentationMode", in: request) {
      surface.presentation = WallpaperRuntime.enumCase(mode)
    }
    if let activity = WallpaperRuntime.field("activityState", in: request) {
      surface.activity = WallpaperRuntime.enumCase(activity)
    }
    surface.applyPolicy()
    WallpaperRuntime.log(
      "Updated id=\(id) mode=\(surface.presentation) activity=\(surface.activity)")
  }

  func invalidate(id value: Any?) {
    guard let id = WallpaperRuntime.identifier(value) else { return }
    remove(id)
  }

  func snapshot(id value: Any?, reply: @escaping (Any?, Error?) -> Void) {
    guard let id = WallpaperRuntime.identifier(value), let surface = surfaces[id] else {
      reply(nil, WallpaperRuntime.failure("Unknown wallpaper surface."))
      return
    }
    surface.snapshot(reply: reply)
  }

  /// Surfaces alive, for the line logged when a connection closes.
  var surfaceCount: Int { surfaces.values.count }

  private func remove(_ id: UUID) {
    surfaces.remove(id)
    Self.idleExit.surfacesChanged()
  }
}
