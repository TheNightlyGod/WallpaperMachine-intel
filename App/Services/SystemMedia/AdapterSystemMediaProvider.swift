import Foundation

@MainActor
protocol SystemMediaStreaming: AnyObject {
    func start(receive: @escaping (Data) -> Void, ended: @escaping () -> Void) throws
    func stop()
    /// Asks the now-playing application to carry out one `MRCommand`.
    ///
    /// Separate from the stream it shares a process image with: reading what is
    /// playing runs for as long as a wallpaper wants it, and changing it is one
    /// short-lived invocation.
    func send(command: Int) async -> Bool
    /// One complete read when a playing timeline has outlived its last metadata.
    func snapshot() async -> Data?
}

/// Runs the bundled, pinned adapter only while a wallpaper consumes media data.
@MainActor
final class BundledSystemMediaStream: SystemMediaStreaming {
    private var process: Process?
    private var output: Pipe?
    private let bundle: Bundle
    private let snapshotReader: MediaSnapshotReader

    init(bundle: Bundle = .main, snapshotReader: MediaSnapshotReader = MediaSnapshotReader()) {
        self.bundle = bundle
        self.snapshotReader = snapshotReader
    }

    func start(receive: @escaping (Data) -> Void, ended: @escaping () -> Void) throws {
        stop()
        guard let script = bundle.url(forResource: "mediaremote-adapter", withExtension: "pl"),
              let frameworks = bundle.privateFrameworksURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        task.arguments = [script.path, frameworks.appendingPathComponent("MediaRemoteAdapter.framework").path,
                          "stream", "--no-diff", "--debounce=100"]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self, weak task] handle in
            let data = handle.availableData
            Task { @MainActor in
                guard let self, let task, self.process === task, !data.isEmpty else { return }
                receive(data)
            }
        }
        task.terminationHandler = { [weak self, weak task] _ in
            Task { @MainActor in
                guard let self, let task, self.process === task else { return }
                self.stop()
                ended()
            }
        }
        process = task
        output = pipe
        do { try task.run() } catch { stop(); throw error }
    }

    /// One short-lived process, never on the main actor: a player that is slow
    /// to answer must not stall the UI, and this must not disturb the stream a
    /// wallpaper is already reading.
    func send(command: Int) async -> Bool {
        guard let script = bundle.url(forResource: "mediaremote-adapter", withExtension: "pl"),
              let frameworks = bundle.privateFrameworksURL else { return false }
        let framework = frameworks.appendingPathComponent("MediaRemoteAdapter.framework").path
        let path = script.path
        return await Task.detached(priority: .userInitiated) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            task.arguments = [path, framework, "send", String(command)]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            do {
                try task.run()
            } catch {
                AppLog.warn("The media adapter could not run a transport command.")
                return false
            }
            task.waitUntilExit()
            return task.terminationStatus == 0
        }.value
    }

    func snapshot() async -> Data? {
        guard let script = bundle.url(forResource: "mediaremote-adapter", withExtension: "pl"),
              let frameworks = bundle.privateFrameworksURL else {
            AppLog.warn("The media snapshot reader is unavailable in this bundle.")
            return nil
        }
        do {
            return try await snapshotReader.read(executable: URL(fileURLWithPath: "/usr/bin/perl"),
                arguments: [script.path, frameworks.appendingPathComponent("MediaRemoteAdapter.framework").path, "get"])
        } catch is CancellationError {
            return nil
        } catch {
            AppLog.warn("The system media snapshot could not be read: \(error)")
            return nil
        }
    }

    func stop() {
        output?.fileHandleForReading.readabilityHandler = nil
        output = nil
        let previous = process
        process = nil
        previous?.terminationHandler = nil
        if previous?.isRunning == true { previous?.terminate() }
    }
}

@MainActor
final class AdapterSystemMediaProvider: SystemMediaProvider {
    private(set) var availability: SystemMediaAvailability = .unavailable(reason: String(localized: "Media integration has not been started."))
    var onPropertiesChanged: ((SystemMediaProperties) -> Void)?
    var onThumbnailChanged: ((SystemMediaThumbnail) -> Void)?
    var onPlaybackChanged: ((SystemMediaPlaybackState) -> Void)?
    var onTimelineChanged: ((SystemMediaTimeline?) -> Void)?

    private let stream: any SystemMediaStreaming
    private let artwork: MediaArtwork
    private let scheduler: any MediaTimerScheduling
    private let now: () -> Date
    private var consumers = 0
    private var buffer = Data()
    private var properties = SystemMediaProperties()
    private var thumbnail: SystemMediaThumbnail?
    private var resolvedArtwork: (encoded: String, thumbnail: SystemMediaThumbnail)?
    private var playback = SystemMediaPlaybackState.stopped
    private var timeline: SystemMediaTimeline?
    private var timestamp = Date()
    private var rate = 0.0
    private var ticker: (any MediaTimerToken)?
    private var generation = 0
    private var metadataRevision: UInt64 = 0
    private var recovery: Task<Void, Never>?
    private var recoveryID: UUID?
    private var recoveryAttempts = 0
    private var nextRecoveryAt: Date?
    private var itemIdentity: ItemIdentity?

    private struct ItemIdentity: Equatable {
        var process: Int?
        var parentApplication: String?
        var content: String?
        var title: String?
        var artist: String?
        var album: String?

        init(_ payload: [String: Any]) {
            process = payload["processIdentifier"] as? Int
            parentApplication = payload["parentApplicationBundleIdentifier"] as? String
            content = payload["contentItemIdentifier"] as? String
            title = payload["title"] as? String
            artist = payload["artist"] as? String
            album = payload["album"] as? String
        }
    }

    init(stream: (any SystemMediaStreaming)? = nil, artwork: MediaArtwork? = nil,
         scheduler: (any MediaTimerScheduling)? = nil, now: @escaping () -> Date = Date.init) {
        self.stream = stream ?? BundledSystemMediaStream()
        self.artwork = artwork ?? MediaArtwork()
        self.scheduler = scheduler ?? FoundationMediaTimerScheduler()
        self.now = now
    }

    func addConsumer() {
        consumers += 1
        guard consumers == 1 else { return }
        generation += 1
        let current = generation
        do {
            try stream.start(receive: { [weak self] data in
                guard let self, self.generation == current, self.consumers > 0 else { return }
                self.receive(data)
            }, ended: { [weak self] in
                guard let self, self.generation == current else { return }
                self.fail()
            })
        } catch { fail() }
    }

    func removeConsumer() {
        guard consumers > 0 else { return }
        consumers -= 1
        guard consumers == 0 else { return }
        generation += 1
        cancelRecovery()
        itemIdentity = nil
        stream.stop()
        ticker?.cancel()
        ticker = nil
        buffer.removeAll()
        properties = SystemMediaProperties()
        thumbnail = nil
        resolvedArtwork = nil
        playback = .stopped
        timeline = nil
        availability = .unavailable(reason: String(localized: "Media integration has not been started."))
    }

    func replayCurrentState() {
        onPropertiesChanged?(properties)
        if let thumbnail { onThumbnailChanged?(thumbnail) }
        onPlaybackChanged?(playback)
        emitTimeline()
    }

    /// Hands the command to whichever application is currently now-playing.
    ///
    /// The same bundled, pinned adapter that reports the state, asked once to
    /// change it.
    func send(_ command: SystemMediaCommand) async -> Bool {
        await stream.send(command: Self.adapterCommand(for: command))
    }

    /// `MRCommand` identifiers, from the adapter's own header.
    private static func adapterCommand(for command: SystemMediaCommand) -> Int {
        switch command {
        case .togglePlayPause: 2
        case .nextTrack: 4
        case .previousTrack: 5
        }
    }

    private func fail() {
        generation += 1
        cancelRecovery()
        stream.stop()
        ticker?.cancel()
        ticker = nil
        resolvedArtwork = nil
        apply([:])
        availability = .unavailable(reason: String(localized: "The system media service is unavailable."))
        AppLog.warn("System media adapter stopped or could not start.")
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        guard buffer.count <= 8 * 1024 * 1024 else { buffer.removeAll(); fail(); return }
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer[..<end]
            buffer.removeSubrange(...end)
            guard let envelope = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  envelope["type"] as? String == "data",
                  envelope["diff"] as? Bool != true,
                  let payload = envelope["payload"] as? [String: Any] else { continue }
            availability = .available
            metadataRevision &+= 1
            let previousIdentity = itemIdentity
            let previousTimestamp = timestamp
            cancelRecovery(resetBudget: false)
            apply(payload)
            if itemIdentity != previousIdentity || timelineMovedBeforeEnd(since: previousTimestamp) {
                resetRecoveryBudget()
            }
        }
    }

    private func apply(_ payload: [String: Any]) {
        itemIdentity = payload.isEmpty ? nil : ItemIdentity(payload)
        var next = SystemMediaProperties()
        next.title = payload["title"] as? String ?? ""
        next.artist = payload["artist"] as? String ?? ""
        next.albumTitle = payload["album"] as? String ?? ""
        let changed = next != properties
        if changed { properties = next; onPropertiesChanged?(next) }
        var cover: SystemMediaThumbnail?
        if let encoded = payload["artworkData"] as? String {
            if let cached = resolvedArtwork, cached.encoded == encoded {
                cover = cached.thumbnail
            } else if let data = Data(base64Encoded: encoded), let parsed = artwork.thumbnail(for: data) {
                resolvedArtwork = (encoded, parsed)
                cover = parsed
            }
        }
        if let cover, cover != thumbnail {
            thumbnail = cover
            onThumbnailChanged?(cover)
        } else if cover == nil && thumbnail != .empty
                    && (changed || payload.isEmpty || payload["artworkData"] != nil) {
            // An explicit empty image clears the previous track in both web and scene consumers.
            resolvedArtwork = nil
            thumbnail = .empty
            onThumbnailChanged?(.empty)
        }
        let nextPlayback: SystemMediaPlaybackState = payload.isEmpty ? .stopped :
            (payload["playing"] as? Bool == true ? .playing : .paused)
        if playback != nextPlayback { playback = nextPlayback; onPlaybackChanged?(playback) }
        if let duration = payload["duration"] as? Double, duration.isFinite, duration > 0,
           let elapsed = payload["elapsedTime"] as? Double, elapsed.isFinite {
            timeline = SystemMediaTimeline(position: max(0, elapsed), duration: duration)
        } else { timeline = nil }
        let reportedTimestamp = payload["timestamp"] as? Double
        timestamp = reportedTimestamp.flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
            ?? (payload["timestamp"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? now()
        let reportedRate = payload["playbackRate"] as? Double ?? 1
        rate = playback == .playing && reportedRate.isFinite ? max(0, reportedRate) : 0
        ticker?.cancel()
        ticker = nil
        emitTimeline(allowRecovery: false)
        if playback == .playing, timeline != nil {
            ticker = scheduler.schedule(every: 1) { [weak self] in self?.emitTimeline() }
        }
    }

    private func emitTimeline(allowRecovery: Bool = true) {
        guard playback == .playing, var value = timeline else { onTimelineChanged?(nil); return }
        let currentTime = now()
        let elapsed = value.position + max(0, currentTime.timeIntervalSince(timestamp)) * rate
        value.position = min(value.duration, max(0, elapsed))
        onTimelineChanged?(value)
        // Use the existing timeline tick, with a grace period for ordinary transition events.
        // Silence mid-song is expected; only an overdue finite track warrants a fresh read.
        if allowRecovery, rate > 0, elapsed >= value.duration + 2 { recoverIfNeeded(at: currentTime) }
    }

    private func cancelRecovery(resetBudget: Bool = true) {
        recovery?.cancel()
        recovery = nil
        recoveryID = nil
        if resetBudget { resetRecoveryBudget() }
    }

    private func resetRecoveryBudget() {
        recoveryAttempts = 0
        nextRecoveryAt = nil
    }

    private func timelineMovedBeforeEnd(since previousTimestamp: Date) -> Bool {
        guard timestamp > previousTimestamp, let timeline else { return false }
        return timeline.position + max(0, now().timeIntervalSince(timestamp)) * rate < timeline.duration
    }

    private func recoverIfNeeded(at date: Date) {
        guard consumers > 0, recovery == nil, recoveryAttempts < 2,
              nextRecoveryAt.map({ date >= $0 }) ?? true else { return }
        let id = UUID()
        let subscription = generation
        let revision = metadataRevision
        let identity = itemIdentity
        let previousTimestamp = timestamp
        recoveryID = id
        recoveryAttempts += 1
        nextRecoveryAt = date.addingTimeInterval(5)
        recovery = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.recoveryID == id { self.recovery = nil; self.recoveryID = nil }
            }
            guard let data = await self.stream.snapshot(), !Task.isCancelled,
                  self.consumers > 0, self.generation == subscription, self.metadataRevision == revision,
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            // A later stream message always wins. A repeated or unavailable snapshot costs at
            // most one retry; a genuinely new item gets its own future boundary check.
            if payload.isEmpty || ItemIdentity(payload) != identity {
                self.resetRecoveryBudget()
            }
            self.apply(payload)
            if self.timelineMovedBeforeEnd(since: previousTimestamp) {
                // Repeat-one can restart the same content ID without a stream event.
                self.resetRecoveryBudget()
            }
        }
    }
}
