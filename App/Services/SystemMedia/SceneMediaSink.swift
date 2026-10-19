import Foundation

/// Feeds live now-playing events into every desktop scene with integration enabled.
///
/// Scenes do not register listeners. Demand is the set of applied scenes with
/// media integration on, which the bridge reports by handle. The engine drops
/// events when a scene's live flag is off, so this fans out to
/// every enabled wallpaper without asking for handles of its own.
@MainActor
final class SceneMediaSink {
    private let session: DesktopMediaSession
    private let submit: (String) async throws -> Void
    private let applyArtwork: (UInt32, UInt32, Data) async throws -> Void
    private let fetchHandles: () async -> Set<UInt64>
    private let nextShortcut: (() async throws -> BridgeUserShortcut)?
    /// Waits for wallpaper button presses. A long wait, not a poll: it returns
    /// only when a press arrives, so an untouched wallpaper costs nothing.
    private var shortcuts: Task<Void, Never>?
    /// Held, not derived from a temporary. `ObjectIdentifier` is an address,
    /// and an address freed the moment it was taken can be handed to the next
    /// allocation — which would let two listeners share one key in the shared
    /// relay and silently overwrite or remove each other.
    private let listenerToken = ListenerKey()
    private var listenerKey: ObjectIdentifier { ObjectIdentifier(listenerToken) }
    /// Whether this sink currently has anything to feed.
    ///
    /// The relay hands every event to every listener, because a listener key
    /// is not a consumer key — the web host keeps one listener for all its
    /// pages. So the decision not to do the work belongs here, where the
    /// effective demand is known.
    private var consuming = false
    /// Bumped whenever `consuming` changes, and captured by each delivery.
    ///
    /// A delivery awaits the engine twice, so a pause can land in the middle
    /// of one. A boolean cannot retire that delivery: by the time it resumes
    /// the scene may have been resumed too, and `consuming` would be true
    /// again — letting a cover from before the pause overwrite the one
    /// published after it. The epoch only ever moves forward, so a delivery
    /// that started in an earlier one is dropped whatever the flag says.
    private var deliveryEpoch: UInt64 = 0
    /// The tail of the delivery queue, so covers and their metadata reach the
    /// engine in publication order rather than in whatever order the engine
    /// happened to answer.
    private var deliveryChain: Task<Void, Never>?
    /// Scenes that have already been shown the current state. A scene is born
    /// with none of it, so a handle absent from this set is what makes a
    /// replay necessary — not the moment the first consumer appears.
    private var fedHandles: Set<UInt64> = []
    /// Reconciles can overlap: a pause and a resume each start one, and the
    /// bridge call is awaited. Applying a stale answer would re-open the
    /// provider after a pause, so only the newest reconcile may act.
    private var generation: UInt64 = 0

    private final class ListenerKey {}

    init(
        session: DesktopMediaSession,
        submit: @escaping (String) async throws -> Void,
        applyArtwork: @escaping (UInt32, UInt32, Data) async throws -> Void,
        fetchHandles: @escaping () async -> Set<UInt64>,
        nextShortcut: (() async throws -> BridgeUserShortcut)? = nil
    ) {
        self.session = session
        self.submit = submit
        self.applyArtwork = applyArtwork
        self.fetchHandles = fetchHandles
        self.nextShortcut = nextShortcut
        session.relay.addListener(listenerKey) { [weak self] event in
            self?.deliver(event)
        }
        startShortcuts()
    }

    /// Carries out what each press was bound to, on the one session that is
    /// actually reporting. The loop ends rather than spins if the bridge stops
    /// reporting.
    private func startShortcuts() {
        // A sink with no source of presses simply has none to carry out.
        guard shortcuts == nil, nextShortcut != nil else { return }
        shortcuts = Task { [weak self] in
            // One bad answer is not a reason to stop taking presses for the
            // rest of the session. Giving up on the first one is how every
            // button in a wallpaper goes quiet before its user has touched
            // anything, with the cause recorded once and then never again.
            var failures = 0
            while !Task.isCancelled {
                guard let next = self?.nextShortcut else { return }
                let event: BridgeUserShortcut
                do {
                    event = try await next()
                    failures = 0
                } catch {
                    failures += 1
                    AppLog.warn("Waiting for wallpaper shortcuts failed (\(failures)): \(error)")
                    if failures >= 5 {
                        AppLog.warn("Stopped waiting for wallpaper shortcuts.")
                        return
                    }
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                guard let self, !Task.isCancelled else { return }
                await self.perform(event)
            }
        }
    }

    /// Carries out one press, or nothing.
    ///
    /// The value is the user's own choice for that property; a wallpaper whose
    /// user left a button unbound gets silence, which is what an unbound
    /// button already did.
    private func perform(_ event: BridgeUserShortcut) async {
        guard let command = SystemMediaCommand(rawValue: event.value) else {
            AppLog.info("Wallpaper shortcut \(event.property) is bound to nothing this host can do: \"\(event.value)\".")
            return
        }
        if await session.send(command) {
            AppLog.info("Carried out \(command.rawValue) for wallpaper shortcut \(event.property).")
            return
        }
        AppLog.warn("No media player took a wallpaper's transport command.")
    }

    func reconcile() {
        generation &+= 1
        let generation = self.generation
        Task { @MainActor [weak self] in
            guard let self else { return }
            let handles = await self.fetchHandles()
            guard generation == self.generation else { return }
            self.setConsuming(!handles.isEmpty)
            // Switching wallpapers, adding a display, rebuilding a scene or
            // resuming after a pause produces a handle that has seen nothing.
            // Replaying reaches every opted-in scene, not only the new one,
            // because the engine has no per-handle submit here; re-sending an
            // unchanged state is idempotent, and the alternative is a new
            // display staying blank until the track changes.
            if !handles.subtracting(self.fedHandles).isEmpty {
                for event in self.session.relay.currentEvents(userEnabled: true) {
                    self.deliver(event)
                }
            }
            self.fedHandles = handles
        }
    }

    func shutdown() {
        shortcuts?.cancel()
        shortcuts = nil
        // Retires any reconcile still in flight, and any delivery already past
        // its first await, along with the listener. `setConsuming` tells the
        // relay; saying it twice would only rely on its remove-guard.
        generation &+= 1
        setConsuming(false)
        session.relay.removeListener(listenerKey)
        fedHandles = []
    }

    /// Moves the epoch only when the answer actually changed, so an unrelated
    /// reconcile does not retire deliveries that are still wanted.
    private func setConsuming(_ value: Bool) {
        if consuming != value {
            consuming = value
            deliveryEpoch &+= 1
        }
        session.relay.setConsuming(value, for: listenerKey)
    }

    private func deliver(_ event: WebWallpaperMediaRelay.Event) {
        // Nothing visible is opted in, so there is nothing to copy, encode or
        // send.
        guard consuming else { return }
        let epoch = deliveryEpoch
        var cover: (width: UInt32, height: UInt32, rgba: Data)?
        if case let .thumbnail(thumbnail) = event {
            if thumbnail.isEmpty {
                cover = (0, 0, Data())
            } else if let width = UInt32(exactly: thumbnail.width), width > 0,
                let height = UInt32(exactly: thumbnail.height), height > 0,
                UInt64(thumbnail.rgba.count) / 4 == UInt64(width) * UInt64(height),
                thumbnail.rgba.count.isMultiple(of: 4)
            {
                cover = (width, height, Data(thumbnail.rgba))
            }
        }
        // Chained, not parallel. A slow cover must not be overtaken by the one
        // that replaced it and then land on top of it: the engine applies
        // whatever arrives last, so the order covers reach it is the order
        // they were published in.
        let previous = deliveryChain
        deliveryChain = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, self.deliveryEpoch == epoch else { return }
            if let cover {
                do {
                    try await self.applyArtwork(cover.width, cover.height, cover.rgba)
                } catch {
                    AppLog.warn("scene media artwork could not be applied: \(error.localizedDescription)")
                }
                // The cover await is where a pause and a resume can both land.
                // The call already inside the engine cannot be taken back, but
                // this event's own metadata must not follow a newer one.
                guard self.deliveryEpoch == epoch else { return }
            }
            guard let json = SystemMediaEventCodec.json(for: event) else { return }
            do {
                try await self.submit(json)
            } catch {
                AppLog.warn("scene media event could not be submitted: \(error.localizedDescription)")
            }
        }
    }
}
