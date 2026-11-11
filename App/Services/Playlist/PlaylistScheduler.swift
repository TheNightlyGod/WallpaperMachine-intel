import Foundation

/// Changes wallpapers on the displays whose playlist rotates or follows the day.
///
/// One timer waits for the earliest change. A change only happens while wallpapers are
/// playing: one that falls due while the user has paused, the screen is locked or the displays
/// sleep waits, and happens once, when `evaluate()` next finds playback running. A display that
/// is only out of sight (covered, behind a full-screen app, not the one in use) changes behind
/// the windows instead, so the new wallpaper is already there when the desktop shows again; it
/// changes once while it stays out of sight, and showing again starts a whole interval rather
/// than changing it in front of the user. The app delegate calls `evaluate()` when playback or
/// presentation changes, so nothing is polled. Every switch runs through the display's command slot, the same one the
/// panel and the menu bar use, so the latest request for a display wins.
///
/// A rotation set to change each time the Mac is unlocked has no timer. `noteUnlock()` opens a
/// short window, and every such display changes once in it, as soon as it can play.
///
/// A rotation that waits for videos to finish (`DisplayPlaylist.waitsForClipEnd`) does not cut
/// a clip: a timed change that falls due while one plays on the display waits until the clip
/// reaches its end and starts over, which the video host reports, so nothing is polled either.
/// It waits for as long as the display keeps playing that clip, and never longer than
/// `clipEndLimit(minutes:)`; the store notes the wait (`PlaylistStore.clipWaits`) for the panel.
@MainActor
final class PlaylistScheduler {
    /// Runs one switch on `display` through its command slot. `choose` names the wallpaper when
    /// the switch's turn comes, or nil to skip it. Answers the wallpaper applied, or nil when
    /// nothing was: a newer request replaced this one, or there was nothing to choose.
    typealias Activate = @MainActor (_ display: String, _ choose: @MainActor () -> String?) async throws -> String?
    /// Watches the video `wallpaper` playing on `display` for the end of the pass it is in, and
    /// calls `ended` once, later, when the clip starts over or stops playing there first (it
    /// failed, or the display moved on). Answers nil, and never calls `ended`, when the display
    /// does not play that wallpaper as a video with an end to wait for; otherwise a closure that
    /// ends the watch without calling it.
    typealias WatchClipEnd = @MainActor (
        _ display: String, _ wallpaper: String, _ ended: @escaping @MainActor () -> Void
    ) -> (@MainActor () -> Void)?

    private let store: PlaylistStore
    private let collections: WallpaperCollectionStore
    private let displays: @MainActor () -> [String]
    private let library: @MainActor () -> [String]
    private let favorites: @MainActor () -> Set<String>
    private let current: @MainActor (String) -> String?
    private let isRunning: @MainActor (String) -> Bool
    private let isUnseen: @MainActor (String) -> Bool
    private let watchClipEnd: WatchClipEnd
    private let activate: Activate
    private let commandRevision: @MainActor (String) -> UInt64
    private let now: @MainActor () -> Date
    private let calendar: Calendar
    private let center: NotificationCenter
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    private var observers: [NSObjectProtocol] = []
    private var timer: Task<Void, Never>?
    private var armedFor: Date?
    private var inFlight = Set<String>()
    /// Displays someone asked to move along while the timer's own change was waiting its turn:
    /// that change then runs as asked for, even if the display paused meanwhile.
    private var requestedWhileInFlight = Set<String>()
    /// The day or night period each display was last brought into line with, and the playlist
    /// it was brought into line under: a wallpaper the user applies by hand stays until the next
    /// period, and choosing a different day or night wallpaper applies at once. The store keeps
    /// the period across launches (`settle`), so a relaunch inside it is not a new period either.
    private var settledPeriods: [String: (period: Date, revision: UInt64)] = [:]
    /// The displays whose saved period this scheduler has looked up: once each, at the first
    /// evaluation that asks, when the displays and their playlists are known.
    private var restoredSettledPeriods = Set<String>()
    /// The rotating displays that changed while out of sight, with the playlist revision they
    /// changed under. Such a display does not change again until it shows, and showing again
    /// counts a whole interval from then. A playlist edited meanwhile applies at once.
    private var changedUnseen: [String: UInt64] = [:]
    /// The unlock the rotations that wait for one are answering: a number that tells it from the
    /// last, and when its window closes. A display that cannot play yet (covered, re-enumerating
    /// after wake, presentation still settling) is retried by the evaluations the app delegate
    /// runs on every presentation change until then, and is never changed minutes later.
    private var unlock: (id: UInt64, expires: Date)?
    private var unlockCount: UInt64 = 0
    /// The unlock each display has been dealt with for, so it changes once per unlock.
    private var handledUnlock: [String: UInt64] = [:]
    private var lastUnlock: Date?
    /// A timed change that fell due while a video played on the display, waiting for the clip to
    /// reach its end. It belongs to one deadline, one playlist revision and the wallpaper that was
    /// playing, and lasts only while the display plays: an evaluation that does not find it still
    /// waiting ends it, so pausing, covering, a new deadline or an edit each drop it.
    private struct ClipWait {
        let serial: UInt64
        let due: Date
        let revision: UInt64
        let wallpaper: String
        /// When the change is made anyway.
        let until: Date
        var cancel: (@MainActor () -> Void)?
        /// The clip reached its end, or stopped playing: the change can be made.
        var ended = false
    }
    private var clipWaits: [String: ClipWait] = [:]
    private var clipWaitSerial: UInt64 = 0
    private var random = SystemRandomNumberGenerator()
    /// Two unlocks closer than this are one: the session reports the lock clearing, and the
    /// unlock notification of a screen saver or a lock screen can follow it.
    static let unlockDebounce: TimeInterval = 2
    /// How long after an unlock a display that could not play at once may still change for it.
    static let unlockGrace: TimeInterval = 30
    static let failureCooldown: TimeInterval = 15 * 60
    /// A broken library must not monopolize the command queue in one automatic change.
    static let maximumAttempts = 5
    /// The shortest and the longest a due change waits for a video to finish.
    static let clipEndLimits: ClosedRange<TimeInterval> = (10 * 60)...(60 * 60)

    /// How long a due change of a rotation every `minutes` waits for the video on screen to
    /// finish: the interval, within `clipEndLimits`. A clip longer than that, or one that stopped
    /// advancing without failing, is cut then rather than holding the rotation.
    static func clipEndLimit(minutes: Int) -> TimeInterval {
        min(max(seconds(minutes), clipEndLimits.lowerBound), clipEndLimits.upperBound)
    }

    init(
        store: PlaylistStore,
        collections: WallpaperCollectionStore,
        displays: @escaping @MainActor () -> [String],
        library: @escaping @MainActor () -> [String],
        favorites: @escaping @MainActor () -> Set<String>,
        current: @escaping @MainActor (String) -> String?,
        isRunning: @escaping @MainActor (String) -> Bool,
        // Wallpapers play on the display but it is paused only because nobody can see it there.
        isUnseen: @escaping @MainActor (String) -> Bool = { _ in false },
        watchClipEnd: @escaping WatchClipEnd = { _, _, _ in nil },
        activate: @escaping Activate,
        commandRevision: @escaping @MainActor (String) -> UInt64 = { _ in 0 },
        now: (@MainActor () -> Date)? = nil,
        calendar: Calendar = .autoupdatingCurrent,
        center: NotificationCenter = .default,
        // The continuous clock keeps counting while the Mac sleeps, so a change that fell due
        // during sleep happens on wake rather than an interval of awake time later.
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(max(0, seconds)))
        }
    ) {
        self.store = store
        self.collections = collections
        self.displays = displays
        self.library = library
        self.favorites = favorites
        self.current = current
        self.isRunning = isRunning
        self.isUnseen = isUnseen
        self.watchClipEnd = watchClipEnd
        self.activate = activate
        self.commandRevision = commandRevision
        self.now = now ?? { Date() }
        self.calendar = calendar
        self.center = center
        self.sleep = sleep
    }

    func start() {
        guard observers.isEmpty else {
            evaluate()
            return
        }
        // A clock or time-zone change moves every day and night boundary; the store changes when
        // the user edits a playlist or a change is dated.
        let names: [(Notification.Name, AnyObject?)] = [
            (PlaylistStore.didChangeNotification, store),
            (WallpaperCollectionStore.didChangeNotification, collections),
            (.NSSystemClockDidChange, nil),
            (.NSSystemTimeZoneDidChange, nil),
        ]
        for (name, object) in names {
            observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate() }
            })
        }
        evaluate()
    }

    func stop() {
        for token in observers { center.removeObserver(token) }
        observers.removeAll()
        timer?.cancel()
        timer = nil
        armedFor = nil
        unlock = nil
        handledUnlock.removeAll()
        lastUnlock = nil
        changedUnseen.removeAll()
        for display in Array(clipWaits.keys) { endClipWait(display) }
    }

    /// The Mac was unlocked. Every display whose rotation waits for that changes to its next
    /// wallpaper once, as soon as wallpapers are playing there, for as long as `unlockGrace`.
    /// A second report within `unlockDebounce` is the same unlock. Without such a display
    /// nothing is kept, so choosing the setting later never acts on an unlock that is over.
    func noteUnlock() {
        guard !observers.isEmpty,
              store.playlists.values.contains(where: { $0.mode == .rotate && $0.trigger == .unlock })
        else { return }
        let date = now()
        if let lastUnlock, date.timeIntervalSince(lastUnlock) < Self.unlockDebounce { return }
        lastUnlock = date
        unlockCount &+= 1
        unlock = (unlockCount, date.addingTimeInterval(Self.unlockGrace))
        AppLog.info("playlist: the Mac was unlocked, so rotations that wait for it change within \(Int(Self.unlockGrace)) s")
        evaluate()
    }

    /// A restored/manual choice in a day/night plan stays until its next boundary.
    func holdCurrentPeriod(_ display: String) {
        let playlist = store.playlist(for: display)
        guard playlist.mode == .dayNight else { return }
        let phase = PlaylistPlanner.phase(at: now(), dayStart: playlist.dayStart, nightStart: playlist.nightStart, calendar: calendar)
        settle(display, (phase.until, store.revisions[display] ?? 0))
    }

    /// Notes the period `display` is settled up to, here and in the store, which keeps it for the
    /// next launch (`PlaylistStore.setSettledPeriod`).
    private func settle(_ display: String, _ value: (period: Date, revision: UInt64)?) {
        settledPeriods[display] = value
        store.setSettledPeriod(value?.period, on: display)
    }

    /// The period `display` is settled up to. What an earlier launch, or an earlier scheduler over
    /// the same store, settled under the day and night settings the display still has counts as
    /// settled under its playlist as it is now.
    private func settledPeriod(_ display: String) -> (period: Date, revision: UInt64)? {
        if restoredSettledPeriods.insert(display).inserted, settledPeriods[display] == nil,
           let period = store.settledPeriod(on: display) {
            settledPeriods[display] = (period, store.revisions[display] ?? 0)
        }
        return settledPeriods[display]
    }

    /// The longest a rotating display leaves a wallpaper the user just applied alone, whatever
    /// the deadline it was heading for.
    static let manualGrace: TimeInterval = 5 * 60

    /// The user applied a wallpaper to `display` by hand. A rotation that was about to replace
    /// it moments later waits `min(interval, manualGrace)` from now instead: a deadline that
    /// falls due sooner is pushed back to that point, and a later one is never shortened, so a
    /// long interval keeps its rhythm. A paused display whose deadline already passed is pushed
    /// back too, so it does not swap the moment playback resumes. Day and night already keeps a
    /// hand-picked wallpaper until its next boundary, and an Off display has nothing to hold.
    func noteManualChoice(_ display: String) {
        // The clip a due change waited for is not on screen any more, and the change itself is
        // held back below.
        endClipWait(display)
        let playlist = store.playlist(for: display)
        if playlist.mode == .rotate, playlist.trigger == .unlock {
            answerUnlock(display)
            return
        }
        guard playlist.hasTimer, let due = store.nextChange[display] else { return }
        let date = now()
        let held = date.addingTimeInterval(min(Self.seconds(playlist.interval), Self.manualGrace))
        guard due < held else { return }
        // Dating the change posts the store's notification, which re-arms the single timer.
        store.schedule(display, at: held)
        AppLog.info("playlist: a manual choice on display \(display) holds the rotation for \(Int(held.timeIntervalSince(date))) s")
    }

    /// Counts the unlock that is still waiting, if any, as dealt with for `display`: someone chose
    /// what it shows, or it has nothing to show, and the unlock must not change that afterwards.
    private func answerUnlock(_ display: String) {
        if let unlock { handledUnlock[display] = unlock.id }
    }

    /// Makes every change that is due, dates the next ones and arms the timer for the earliest.
    func evaluate() {
        guard !observers.isEmpty else { return }
        let date = now()
        if let current = unlock, current.expires <= date {
            unlock = nil
            handledUnlock.removeAll()
        }
        var earliest: Date?
        // The displays whose due change still waits for their video after this pass.
        var waitingForClip = Set<String>()
        for display in displays() {
            let playlist = store.playlist(for: display)
            let running = isRunning(display)
            if store.holds[display] != nil {
                // A wallpaper on the display again, from anyone, ends the wait: the user, a
                // rule, a Space or a Focus put it there, and each is a choice. The playlist then
                // counts a whole interval from now (or, for day and night, leaves what is on
                // screen until its next boundary), never a deadline it kept while the display
                // was empty.
                guard playlist.mode == .off || current(display) != nil else {
                    // Nothing is due while the display waits, so no deadline or timer exists, and
                    // an unlock does not fill it, nor change what is put there before it ends.
                    store.schedule(display, at: nil)
                    settle(display, nil)
                    answerUnlock(display)
                    continue
                }
                // Settle the period before lifting: lifting posts the store's notification.
                if playlist.mode == .dayNight {
                    let until = PlaylistPlanner.phase(
                        at: date, dayStart: playlist.dayStart, nightStart: playlist.nightStart, calendar: calendar).until
                    settle(display, (until, store.revisions[display] ?? 0))
                }
                store.setHold(nil, on: display)
                AppLog.info("playlist: display \(display) has a wallpaper again, so its playlist carries on")
            }
            switch playlist.mode {
            case .off:
                store.schedule(display, at: nil)
                settle(display, nil)
            case .rotate where playlist.trigger == .unlock:
                settle(display, nil)
                // No timer: a rotation that waits for the unlock has nothing dated.
                store.schedule(display, at: nil)
                if let unlock, handledUnlock[display] != unlock.id, running, !inFlight.contains(display) {
                    handledUnlock[display] = unlock.id
                    rotate(display, playlist: playlist, answering: unlock.id)
                }
            case .rotate:
                settle(display, nil)
                let revision = store.revisions[display] ?? 0
                // Showing again ends the stretch out of sight a change was made in.
                let changedOutOfSight = (running ? changedUnseen.removeValue(forKey: display) : changedUnseen[display]) == revision
                let interval = Self.seconds(playlist.interval)
                guard let due = store.nextChange[display] else {
                    let next = date.addingTimeInterval(interval)
                    store.schedule(display, at: next)
                    earliest = min(earliest ?? next, next)
                    continue
                }
                if running, changedOutOfSight {
                    // What the user sees now is new to them: it gets a whole interval.
                    let next = date.addingTimeInterval(interval)
                    store.schedule(display, at: next)
                    earliest = min(earliest ?? next, next)
                } else if due > date {
                    earliest = min(earliest ?? due, due)
                } else if inFlight.contains(display) {
                    // The change under way dates the next one.
                } else if running {
                    if let until = clipWait(on: display, playlist: playlist, due: due, revision: revision, at: date) {
                        waitingForClip.insert(display)
                        earliest = min(earliest ?? until, until)
                    } else {
                        rotate(display, playlist: playlist)
                    }
                } else if !changedOutOfSight, isUnseen(display) {
                    AppLog.info("playlist: display \(display) is out of sight, so it changes behind the windows")
                    rotate(display, playlist: playlist)
                }
            case .dayNight:
                let (phase, until) = PlaylistPlanner.phase(
                    at: date, dayStart: playlist.dayStart, nightStart: playlist.nightStart, calendar: calendar)
                store.schedule(display, at: until)
                earliest = min(earliest ?? until, until)
                let settled = settledPeriod(display)
                guard settled?.period != until || settled?.revision != (store.revisions[display] ?? 0) else { continue }
                guard running || isUnseen(display), !inFlight.contains(display) else { continue }
                follow(display, phase: phase, period: until, playlist: playlist)
            }
        }
        // A wait this pass did not keep is over: the display stopped playing, is out of sight,
        // got a new deadline or another playlist, or its change is being made.
        for display in Array(clipWaits.keys) where !waitingForClip.contains(display) { endClipWait(display) }
        arm(earliest)
    }

    /// Until when the change due on `display` waits for the video on screen to finish, or nil
    /// when it is made now: the playlist does not wait for videos, what plays there is not a video
    /// with an end to wait for, the clip has reached it, or it has been waited for as long as
    /// `clipEndLimit(minutes:)` allows. Called only while the display plays.
    private func clipWait(
        on display: String, playlist: DisplayPlaylist, due: Date, revision: UInt64, at date: Date
    ) -> Date? {
        guard playlist.waitsForClipEnd, let shown = current(display) else { return nil }
        if let wait = clipWaits[display], wait.due == due, wait.revision == revision, wait.wallpaper == shown {
            if wait.ended { return nil }
            guard date < wait.until else {
                AppLog.info("playlist: the video on display \(display) did not finish within "
                    + "\(Int(Self.clipEndLimit(minutes: playlist.interval) / 60)) min, so it changes now")
                return nil
            }
            return wait.until
        }
        endClipWait(display)
        clipWaitSerial &+= 1
        let serial = clipWaitSerial
        guard let cancel = watchClipEnd(display, shown, { [weak self] in self?.clipEnded(on: display, serial: serial) })
        else { return nil }
        let until = date.addingTimeInterval(Self.clipEndLimit(minutes: playlist.interval))
        clipWaits[display] = ClipWait(
            serial: serial, due: due, revision: revision, wallpaper: shown, until: until, cancel: cancel)
        // The panel says the change waits for the video instead of naming a deadline that passed.
        store.setClipWait(until, on: display)
        AppLog.info("playlist: display \(display) waits for its video to finish before it changes")
        return until
    }

    /// The clip a due change waits for reached its end, or stopped playing on the display. The
    /// change is made at once if the display still plays, through the usual evaluation; a second
    /// report of the same end changes nothing.
    private func clipEnded(on display: String, serial: UInt64) {
        guard var wait = clipWaits[display], wait.serial == serial, !wait.ended else { return }
        wait.ended = true
        wait.cancel = nil
        clipWaits[display] = wait
        AppLog.info("playlist: the video on display \(display) reached its end or stopped playing, so it changes now")
        evaluate()
    }

    private func endClipWait(_ display: String) {
        guard let wait = clipWaits.removeValue(forKey: display) else { return }
        wait.cancel?()
        store.setClipWait(nil, on: display)
    }

    /// Whether `skip(_:)` has a playlist wallpaper to change `display` to.
    func canSkip(_ display: String) -> Bool {
        let playlist = store.playlist(for: display)
        guard playlist.mode == .rotate else { return false }
        let candidates = availableCandidates(for: playlist, on: display)
        return candidates.contains { $0 != current(display) }
    }

    /// Changes `display` to its playlist's next wallpaper now, whatever the timer says, and
    /// starts a fresh interval. Someone asked for it, so it happens while the display is paused
    /// or covered too, and a change already under way counts as the answer. Returns false when
    /// the display does not rotate, so the caller can fall back to the library order, or when
    /// its playlist has no other wallpaper to change to. It also ends the wait of a display the
    /// user emptied.
    @discardableResult
    func skip(_ display: String) -> Bool {
        let playlist = store.playlist(for: display)
        guard playlist.mode == .rotate, displays().contains(display) else { return false }
        // Asking for a change answers an unlock that is still waiting to give one.
        answerUnlock(display)
        if inFlight.contains(display) {
            store.setHold(nil, on: display)
            requestedWhileInFlight.insert(display)
            return true
        }
        guard canSkip(display) else { return false }
        // Asking for a change is asking a display the user emptied to be filled.
        store.setHold(nil, on: display)
        rotate(display, playlist: playlist, requested: true)
        return true
    }

    /// The user wants a playlist that waited because they removed the wallpaper to run again.
    /// A rotation fills the display now and starts a fresh interval; day and night puts the
    /// wallpaper for the current half of the day back as soon as the display can play. Does
    /// nothing for a display that is not waiting.
    func resume(_ display: String) {
        guard store.holds[display] != nil else { return }
        settle(display, nil)
        store.setHold(nil, on: display)
        AppLog.info("playlist: display \(display) resumed after its wallpaper was removed")
        if store.playlist(for: display).mode == .rotate, skip(display) { return }
        evaluate()
    }

    /// A change the timer brings waits while the display cannot play, and is made while it is
    /// only out of sight; a `requested` one does not wait. `answering` names the unlock this
    /// change is for, when it is for one: that one waits until the display shows.
    private func rotate(_ display: String, playlist: DisplayPlaylist, requested: Bool = false, answering unlockID: UInt64? = nil) {
        let revision = store.revisions[display] ?? 0
        // This is the change a wait for the video was holding back, or one asked for instead.
        endClipWait(display)
        inFlight.insert(display)
        Task {
            var attempted = false
            defer {
                inFlight.remove(display)
                // A change asked for while this one waited rode on it. If this one was dropped
                // unmade (the playlist changed meanwhile), the asked-for change is made on its own.
                let unanswered = requestedWhileInFlight.remove(display) != nil && !attempted
                let remade = unanswered && skip(display)
                // A change for an unlock that never got its turn because the display stopped
                // playing meanwhile is made when it plays again, if the unlock is still recent.
                // One that is not playing gives no evaluation a reason to start it again at once.
                if let unlockID, !attempted, handledUnlock[display] == unlockID, !isRunning(display) {
                    handledUnlock[display] = nil
                }
                if remade {
                    // That change schedules the next interval once it is made.
                } else if playlist.hasTimer, (attempted || isRunning(display) || isUnseen(display)),
                          (store.revisions[display] ?? 0) == revision,
                          store.holds[display] == nil {
                    // An eligible display with no alternative still needs another deadline.
                    // Otherwise its next attempt would depend on an unrelated notification.
                    store.schedule(display, at: now().addingTimeInterval(Self.seconds(playlist.interval)))
                } else {
                    evaluate()
                }
            }
            var tried = Set<String>()
            for _ in 0..<Self.maximumAttempts {
                var selected: String?
                var selectedOutOfSight = false
                var command: UInt64?
                var candidates: [String] = []
                do {
                    let applied = try await activate(display) { [self] in
                        guard !observers.isEmpty, (store.revisions[display] ?? 0) == revision,
                            displays().contains(display),
                            requested || requestedWhileInFlight.contains(display) || isRunning(display)
                                || (unlockID == nil && isUnseen(display)),
                            // The user may have emptied the display while this change waited.
                            store.holds[display] == nil
                        else { return nil }
                        // Resolve membership when the command runs, not when its timer fired.
                        let latest = store.playlist(for: display)
                        candidates = self.availableCandidates(for: latest, on: display).filter { !tried.contains($0) }
                        selected = PlaylistPlanner.next(
                            after: current(display), in: candidates, order: latest.order,
                            recent: store.recent[display] ?? [], using: &random)
                        selectedOutOfSight = !isRunning(display) && isUnseen(display)
                        command = commandRevision(display)
                        attempted = attempted || selected != nil
                        return selected
                    }
                    if let applied, (store.revisions[display] ?? 0) == revision {
                        // Only a completed switch counts as the change made out of sight.
                        // A global pause during activation makes isUnseen false without
                        // showing the desktop, so keep the state from selection as well.
                        if !isRunning(display), selectedOutOfSight || isUnseen(display) {
                            changedUnseen[display] = revision
                        }
                        store.clearFailure(applied, on: display)
                        // The round counts the wallpapers it can pick from: one that keeps failing
                        // is left out while it cools down, or the round would never end and every
                        // later pick would be a plain random one.
                        store.recordPick(
                            applied, on: display,
                            candidates: self.availableCandidates(for: store.playlist(for: display), on: display))
                        AppLog.info("playlist changed display \(display) to \(applied)")
                    }
                    // A nil result means superseded or ineligible, never an instruction to retry.
                    break
                } catch is CancellationError {
                    break
                } catch {
                    guard let selected else { break }
                    attempted = true
                    tried.insert(selected)
                    store.recordFailure(selected, on: display, message: error.localizedDescription,
                                        retryAfter: now().addingTimeInterval(Self.failureCooldown))
                    AppLog.warn("playlist skipped \(selected) on display \(display): \(error.localizedDescription)")
                    guard !observers.isEmpty, (store.revisions[display] ?? 0) == revision,
                          displays().contains(display), command == commandRevision(display),
                          current(display) != selected else { break }
                }
            }
        }
    }
    private func follow(_ display: String, phase: PlaylistPlanner.Phase, period: Date, playlist: DisplayPlaylist) {
        let revision = store.revisions[display] ?? 0
        let target = phase == .day ? playlist.dayWallpaperID : playlist.nightWallpaperID
        guard let target, library().contains(target), current(display) != target else {
            settle(display, (period, revision))
            return
        }
        inFlight.insert(display)
        Task {
            var attempted = false
            defer {
                inFlight.remove(display)
                // A day or night switch never answers a rotation someone asked for meanwhile.
                if requestedWhileInFlight.remove(display) != nil { skip(display) }
                if (attempted || isRunning(display) || isUnseen(display)), (store.revisions[display] ?? 0) == revision {
                    settle(display, (period, revision))
                }
                evaluate()
            }
            do {
                let applied = try await activate(display) { [self] in
                    guard (store.revisions[display] ?? 0) == revision,
                        displays().contains(display), isRunning(display) || isUnseen(display), library().contains(target),
                        store.holds[display] == nil,
                        PlaylistPlanner.phase(at: now(), dayStart: playlist.dayStart,
                            nightStart: playlist.nightStart, calendar: calendar).until == period
                    else { return nil }
                    attempted = true
                    return current(display) == target ? nil : target
                }
                if applied != nil {
                    AppLog.info("playlist switched display \(display) to its \(phase.rawValue) wallpaper")
                }
            } catch {
                attempted = true
                AppLog.warn("playlist could not switch display \(display) to its \(phase.rawValue) wallpaper: \(error.localizedDescription)")
            }
        }
    }

    private func candidates(for playlist: DisplayPlaylist) -> [String] {
        let ids = playlist.collectionID.flatMap { collections.collection(id: $0)?.wallpaperIDs } ?? []
        return PlaylistPlanner.candidates(
            for: playlist, library: library(), favorites: favorites(), collectionIDs: ids)
    }

    private func availableCandidates(for playlist: DisplayPlaylist, on display: String) -> [String] {
        let date = now()
        return candidates(for: playlist).filter {
            guard let failure = store.skipped[display]?[$0] else { return true }
            return failure.retryAfter <= date
        }
    }

    private func arm(_ date: Date?) {
        guard date != armedFor else { return }
        timer?.cancel()
        timer = nil
        armedFor = date
        guard let date else { return }
        let delay = date.timeIntervalSince(now())
        let sleep = sleep
        timer = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.armedFor = nil
            self.evaluate()
        }
    }

    static func seconds(_ minutes: Int) -> TimeInterval {
        TimeInterval(max(1, minutes) * 60)
    }
}
