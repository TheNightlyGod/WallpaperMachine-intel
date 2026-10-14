import Foundation

/// When a spectrum the analyser did not recompute is still worth sending again.
///
/// Once the audio stops the analyser publishes one cleared spectrum and then no
/// further generations, so a page that smooths per callback would receive a
/// single zero and freeze part-way through its decay. Wallpaper Engine's
/// listener keeps calling on its fixed cadence, so a quiet stretch keeps
/// calling here too: on every poll while a decay can still be running, then
/// once a second, which keeps the page fed (and gives a page that subscribes
/// during the silence its first frame) at a cost of one small call per second.
///
/// Only an all-zero spectrum is ever repeated. The renderer maps everything at
/// or below -48 dB to exactly 0, so a spectrum with any signal in it came from a
/// real analysis and replaying it later would show sound that has stopped.
struct WebWallpaperSilenceCadence {
    /// How long after the last new spectrum every poll repeats the cleared one.
    var settle: Duration = .milliseconds(1500)
    /// The spacing of repeats once the settle window has passed.
    var keepAlive: Duration = .seconds(1)

    private var lastNewGeneration: ContinuousClock.Instant?
    private var lastRepeat: ContinuousClock.Instant?

    /// A spectrum with a generation not seen before was just delivered.
    mutating func recordNew(at now: ContinuousClock.Instant) {
        lastNewGeneration = now
    }

    /// Whether the unchanged `spectrum`, read at `now`, should be delivered
    /// again. Answering yes counts as a repeat for the keep-alive spacing.
    mutating func shouldRepeat(_ spectrum: BridgeAudioSpectrum, at now: ContinuousClock.Instant) -> Bool {
        guard let lastNewGeneration,
              !spectrum.bins.isEmpty, spectrum.bins.allSatisfy({ $0 == 0 }) else { return false }
        let settled = now - lastNewGeneration >= settle
        if settled, let lastRepeat, now - lastRepeat < keepAlive { return false }
        lastRepeat = now
        return true
    }

    mutating func reset() {
        lastNewGeneration = nil
        lastRepeat = nil
    }
}

/// Reads the renderer's audio analysis and hands each newly computed spectrum
/// to whoever is subscribed, repeating a cleared one through silence.
///
/// One pump serves every display. The analysis is process-global, so a timer
/// per page would repeat the same read once per screen, and the tap it feeds is
/// opened by demand rather than by the wallpaper merely existing: with nothing
/// subscribed there is no timer at all, not a timer that reads and discards.
@MainActor
final class WebWallpaperAudioPump {
    /// The Wallpaper Engine listener contract fires at roughly 20 Hz. 30 Hz is
    /// the ceiling here so a page that reacts per frame is not starved, while a
    /// 120 Hz display never drags the renderer into a per-refresh read.
    nonisolated static let defaultInterval = Duration.milliseconds(33)

    private let read: @MainActor () throws -> BridgeAudioSpectrum?
    private let wait: @Sendable (Duration) async throws -> Void
    private let interval: Duration
    private let now: @MainActor () -> ContinuousClock.Instant
    private var silence: WebWallpaperSilenceCadence
    private var subscribers: Set<ObjectIdentifier> = []
    private var task: Task<Void, Never>?
    /// Only a spectrum the analyser actually recomputed is worth waking a page
    /// for; between recomputations the buffer holds the same numbers. The one
    /// exception is a cleared spectrum, which `silence` decides about.
    private var lastGeneration: UInt64?
    private var readFailureLogged = false

    /// Called on the main actor with each new spectrum, and with a cleared one
    /// again while the sound stays off (see `WebWallpaperSilenceCadence`). A
    /// spectrum with signal is never delivered twice.
    var onSpectrum: (@MainActor (BridgeAudioSpectrum) -> Void)?

    /// Whether the shared timer exists at all.
    var isPolling: Bool { task != nil }
    var subscriberCount: Int { subscribers.count }

    init(
        read: @escaping @MainActor () throws -> BridgeAudioSpectrum?,
        interval: Duration = WebWallpaperAudioPump.defaultInterval,
        silence: WebWallpaperSilenceCadence = WebWallpaperSilenceCadence(),
        now: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
        wait: (@Sendable (Duration) async throws -> Void)? = nil
    ) {
        self.read = read
        self.interval = interval
        self.silence = silence
        self.now = now
        self.wait = wait ?? { try await Task.sleep(for: $0) }
    }

    func setSubscribed(_ subscribed: Bool, for key: ObjectIdentifier) {
        let changed = subscribed ? subscribers.insert(key).inserted : subscribers.remove(key) != nil
        guard changed else { return }
        if subscribers.isEmpty {
            stop()
        } else if task == nil {
            start()
        }
    }

    func removeAllSubscribers() {
        guard !subscribers.isEmpty else { return }
        subscribers.removeAll()
        stop()
    }

    private func start() {
        // A serial loop rather than a repeating timer: the next read is only
        // issued after the previous delivery, so a slow frame delays the next
        // sample instead of queueing a backlog of stale spectra behind it.
        task = Task { @MainActor [weak self, wait, interval] in
            while !Task.isCancelled {
                guard let self, !self.subscribers.isEmpty else { return }
                self.pollOnce()
                guard !Task.isCancelled else { return }
                do { try await wait(interval) } catch { return }
            }
        }
    }

    private func stop() {
        task?.cancel()
        task = nil
        // The next subscriber must be given the first spectrum it sees, even if
        // the analyser has not recomputed since the last one left.
        lastGeneration = nil
        silence.reset()
    }

    /// One read and, when it is worth it, one delivery. The loop calls this on
    /// every tick; it is internal so a test can drive it with its own clock.
    func pollOnce() {
        do {
            guard let spectrum = try read() else { return }
            readFailureLogged = false
            if spectrum.generation != lastGeneration {
                lastGeneration = spectrum.generation
                silence.recordNew(at: now())
                onSpectrum?(spectrum)
            } else if silence.shouldRepeat(spectrum, at: now()) {
                onSpectrum?(spectrum)
            }
        } catch {
            // A failing analyser fails every poll; one line is the whole story.
            guard !readFailureLogged else { return }
            readFailureLogged = true
            AppLog.warn("web wallpaper audio: spectrum unavailable: \(error.localizedDescription)")
        }
    }
}
