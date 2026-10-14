import Foundation

/// Every display's playlist, saved in UserDefaults, and when each display that rotates or
/// follows the day changes next. Mutations post `didChangeNotification` once; the scheduler
/// and the panel follow it.
@MainActor
final class PlaylistStore {
    static let shared = PlaylistStore()
    static let didChangeNotification = Notification.Name("WallpaperMachine.playlistsDidChange")
    private static let playlistsKey = "WallpaperMachine.playlists"
    private static let nextChangeKey = "WallpaperMachine.playlistNextChange"
    static let plansKey = "WallpaperMachine.playlistPlans"
    private static let holdsKey = "WallpaperMachine.playlistHolds"
    private static let roundsKey = "WallpaperMachine.playlistRounds"
    /// The most wallpapers one saved round keeps. A round holds each wallpaper of the playlist
    /// at most once, so only a very large library gets near it.
    private static let roundLimit = 2048

    private let defaults: UserDefaults
    private(set) var playlists: [String: DisplayPlaylist]
    private(set) var plans: [PlaylistPlan]
    /// When each display changes next. Kept across launches, so a relaunch neither restarts a
    /// long interval nor skips a change that fell due while the app was closed.
    private(set) var nextChange: [String: Date]
    /// Why a display's playlist is waiting instead of changing its wallpaper. The only reason is
    /// that the user removed the wallpaper: a display they emptied stays empty until a wallpaper
    /// is put on it again, or they resume the playlist. Kept across launches, so a relaunch does
    /// not fill a display that was cleared, and left out of backups like the other run state.
    enum Hold: String, Codable {
        case removedWallpaper
    }
    private(set) var holds: [String: Hold]
    /// What each display has shown this shuffle round, so every wallpaper comes round before one
    /// repeats. A display that still shuffles the same source and collection keeps its round
    /// across launches (`WallpaperMachine.playlistRounds`), so a relaunch neither repeats what it
    /// just showed nor starts over halfway through. Run state, left out of backups.
    private(set) var recent: [String: [String]] = [:]
    /// What Random Wallpaper has picked of each pool on each display this round, filed under
    /// `<display>|<pool>`, so every wallpaper of the pool comes round before one repeats. It is
    /// kept apart from `recent`: a display's own playlist round and its Random round never
    /// disturb each other. Saved with the shuffle rounds, and left out of backups the same way.
    private(set) var randomRounds: [String: [String]] = [:]
    private(set) var revisions: [String: UInt64] = [:]
    struct SkippedWallpaper: Equatable {
        let message: String
        let retryAfter: Date
    }
    /// Failures belong to this run only. An app update or relaunch starts with a fresh attempt.
    private(set) var skipped: [String: [String: SkippedWallpaper]] = [:]
    /// Changes a rotating display to its next wallpaper now, answering false when it does not
    /// rotate. The app delegate points it at the scheduler; the panel's Change now calls it.
    var skipHandler: (@MainActor (String) -> Bool)?
    /// Lifts a display's hold and fills it from its playlist now. The app delegate points it at
    /// the scheduler; the panel's Resume playlist calls it.
    var resumeHandler: (@MainActor (String) -> Void)?

    init(defaults: UserDefaults = ClientPreferences.defaults) {
        self.defaults = defaults
        playlists = (defaults.data(forKey: Self.playlistsKey))
            .flatMap { try? JSONDecoder().decode([String: DisplayPlaylist].self, from: $0) } ?? [:]
        plans = defaults.data(forKey: Self.plansKey)
            .flatMap { try? JSONDecoder().decode([PlaylistPlan].self, from: $0) } ?? []
        let stored = defaults.dictionary(forKey: Self.nextChangeKey) as? [String: Double] ?? [:]
        nextChange = stored.mapValues { Date(timeIntervalSince1970: $0) }
        let heldDisplays = defaults.dictionary(forKey: Self.holdsKey) as? [String: String] ?? [:]
        holds = heldDisplays.compactMapValues(Hold.init(rawValue:))
        let saved = Self.savedRounds(in: defaults)
        recent = Self.shuffleRounds(in: saved, for: playlists)
        randomRounds = Self.randomRounds(in: saved)
    }

    func playlist(for display: String) -> DisplayPlaylist {
        playlists[display] ?? DisplayPlaylist()
    }

    /// Changes one display's playlist. A new mode, trigger, interval or day and night times
    /// start a fresh wait, which the scheduler dates.
    func update(_ display: String, _ change: (inout DisplayPlaylist) -> Void) {
        let before = playlist(for: display)
        var after = before
        change(&after)
        guard after != before else { return }
        after.planID = nil
        revisions[display, default: 0] &+= 1
        playlists[display] = after
        // Turning the playlist off leaves nothing to wait for.
        if after.mode == .off { holds[display] = nil }
        if after.mode != before.mode || after.trigger != before.trigger || after.interval != before.interval
            || after.dayStart != before.dayStart || after.nightStart != before.nightStart
        {
            nextChange[display] = nil
        }
        // A round belongs to the wallpapers it was drawn from, and to a rotation that is running.
        if after.source != before.source || after.collectionID != before.collectionID
            || after.order != before.order || after.mode != before.mode
        {
            recent[display] = nil
        }
        persist()
    }

    /// Appends the wallpapers not already on the display's list, in the order given.
    func add(_ ids: [String], to display: String) {
        update(display) { playlist in
            for id in ids where !playlist.wallpaperIDs.contains(id) { playlist.wallpaperIDs.append(id) }
        }
    }

    func remove(_ id: String, from display: String) {
        update(display) { $0.wallpaperIDs.removeAll { $0 == id } }
    }

    /// Reordering never changes membership or the next deadline. Refuse a stale page instead
    /// of silently dropping wallpapers added since that page was rendered.
    func reorder(_ ids: [String], on display: String, expected: [String]? = nil) throws {
        let playlist = playlist(for: display)
        guard playlist.source == .list, ids.count == playlist.wallpaperIDs.count,
              expected == nil || expected == playlist.wallpaperIDs,
              Set(ids).count == ids.count, Set(ids) == Set(playlist.wallpaperIDs) else {
            throw OrderError.changed
        }
        update(display) { $0.wallpaperIDs = ids }
    }

    enum OrderError: LocalizedError {
        case changed
        var errorDescription: String? {
            String(localized: "The playlist changed. Refresh it and try reordering again.")
        }
    }

    /// Drops wallpapers that left the library from every list and every day or night choice.
    func forget(_ ids: [String]) {
        let gone = Set(ids)
        var changed = false
        for (display, playlist) in playlists {
            var kept = playlist
            kept.wallpaperIDs.removeAll(where: gone.contains)
            if let day = kept.dayWallpaperID, gone.contains(day) { kept.dayWallpaperID = nil }
            if let night = kept.nightWallpaperID, gone.contains(night) { kept.nightWallpaperID = nil }
            if kept != playlist {
                playlists[display] = kept
                revisions[display, default: 0] &+= 1
                changed = true
            }
        }
        for index in plans.indices {
            let before = plans[index].playlist
            plans[index].playlist.wallpaperIDs.removeAll(where: gone.contains)
            if let day = before.dayWallpaperID, gone.contains(day) { plans[index].playlist.dayWallpaperID = nil }
            if let night = before.nightWallpaperID, gone.contains(night) { plans[index].playlist.nightWallpaperID = nil }
            changed = changed || plans[index].playlist != before
        }
        var roundsChanged = false
        for display in recent.keys {
            let before = recent[display]
            recent[display]?.removeAll(where: gone.contains)
            roundsChanged = roundsChanged || recent[display] != before
        }
        for key in randomRounds.keys {
            let before = randomRounds[key]
            randomRounds[key]?.removeAll(where: gone.contains)
            if randomRounds[key]?.isEmpty == true { randomRounds[key] = nil }
            roundsChanged = roundsChanged || randomRounds[key] != before
        }
        for display in skipped.keys {
            skipped[display] = skipped[display]?.filter { !gone.contains($0.key) }
        }
        if changed {
            persist(plansChanged: true)
        } else if roundsChanged {
            persistRounds()
        }
    }

    func recordFailure(_ id: String, on display: String, message: String, retryAfter: Date) {
        skipped[display, default: [:]][id] = SkippedWallpaper(message: message, retryAfter: retryAfter)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    func clearFailures(on display: String) {
        guard skipped.removeValue(forKey: display) != nil else { return }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    func clearFailure(_ id: String, on display: String) {
        guard skipped[display]?.removeValue(forKey: id) != nil else { return }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// Dates the display's next change; nil clears it. Setting the date it already has is not a
    /// change, so the scheduler can re-date on every evaluation without a feedback loop.
    func schedule(_ display: String, at date: Date?) {
        guard nextChange[display] != date else { return }
        nextChange[display] = date
        persist()
    }

    /// Makes a display's playlist wait (`hold`) or lets it carry on (nil). Setting what it
    /// already has is not a change, so the scheduler can lift a hold on every evaluation.
    func setHold(_ hold: Hold?, on display: String) {
        guard holds[display] != hold else { return }
        holds[display] = hold
        // Nothing falls due while a display waits, and whatever deadline it had would be stale
        // when the wait ends: the scheduler dates a fresh interval then.
        if hold != nil { nextChange[display] = nil }
        persist()
    }

    /// Remembers a pick for shuffle; see `PlaylistPlanner.remember(_:in:candidates:)`. A shuffled
    /// display's round is saved at once, without a notification (nothing on screen depends on
    /// it); an in-order rotation has no round worth keeping and writes nothing.
    func recordPick(_ id: String, on display: String, candidates: [String]) {
        recent[display] = PlaylistPlanner.remember(id, in: recent[display] ?? [], candidates: candidates)
        if playlist(for: display).order == .shuffle { persistRounds() }
    }

    /// The wallpaper Random Wallpaper puts on `display` after `current`: any of `candidates`
    /// but the one on screen and the ones this pool has already supplied this round, so every
    /// wallpaper comes round before one repeats. Nil when there is no other wallpaper to pick.
    /// Nothing is remembered until `recordRandomPick` says the pick was shown.
    func randomPick<Random: RandomNumberGenerator>(
        on display: String, pool: AutomationCommand.RandomPool, from candidates: [String], after current: String?,
        using random: inout Random
    ) -> String? {
        PlaylistPlanner.next(
            after: current, in: candidates, order: .shuffle,
            recent: randomRounds[Self.randomKey(display, pool)] ?? [], using: &random)
    }

    func randomPick(
        on display: String, pool: AutomationCommand.RandomPool, from candidates: [String], after current: String?
    ) -> String? {
        var random = SystemRandomNumberGenerator()
        return randomPick(on: display, pool: pool, from: candidates, after: current, using: &random)
    }

    /// Remembers that Random Wallpaper showed `id` from `pool` on `display`; see
    /// `PlaylistPlanner.remember(_:in:candidates:)`. Saved at once, without a notification:
    /// nothing on screen depends on it.
    func recordRandomPick(_ id: String, on display: String, pool: AutomationCommand.RandomPool, candidates: [String]) {
        let key = Self.randomKey(display, pool)
        let round = PlaylistPlanner.remember(id, in: randomRounds[key] ?? [], candidates: candidates)
        randomRounds[key] = round.isEmpty ? nil : round
        persistRounds()
    }

    func plan(id: String) -> PlaylistPlan? {
        plans.first { $0.id == id }
    }

    @discardableResult
    func savePlan(from display: String, name: String) throws -> PlaylistPlan {
        var playlist = playlist(for: display)
        playlist.planID = nil
        let plan = PlaylistPlan(id: UUID().uuidString, name: try WallpaperCollectionStore.validatedName(name), playlist: playlist)
        let updated = plans + [plan]
        let data = try JSONEncoder().encode(updated)
        plans = updated
        defaults.set(data, forKey: Self.plansKey)
        persist()
        return plan
    }

    func renamePlan(_ id: String, name: String) throws {
        guard let index = plans.firstIndex(where: { $0.id == id }) else { throw LibraryOrganizationError.missingPlan }
        let name = try WallpaperCollectionStore.validatedName(name)
        guard plans[index].name != name else { return }
        var updated = plans
        updated[index].name = name
        let data = try JSONEncoder().encode(updated)
        plans = updated
        defaults.set(data, forKey: Self.plansKey)
        persist()
    }

    /// Deleting a plan never stops its active display copies; they become independent.
    func deletePlan(_ id: String) throws {
        guard plan(id: id) != nil else { throw LibraryOrganizationError.missingPlan }
        let updated = plans.filter { $0.id != id }
        let data = try JSONEncoder().encode(updated)
        plans = updated
        defaults.set(data, forKey: Self.plansKey)
        for display in playlists.keys where playlists[display]?.planID == id {
            playlists[display]?.planID = nil
        }
        persist()
    }

    /// Copies the plan, not display pause state. Rotation becomes due once; day/night is
    /// reconciled by its existing phase rules when presentation is running again.
    func applyPlan(_ id: String, to display: String) throws {
        guard let plan = plan(id: id) else { throw LibraryOrganizationError.missingPlan }
        var playlist = plan.playlist
        playlist.planID = id
        revisions[display, default: 0] &+= 1
        playlists[display] = playlist
        recent[display] = nil
        // Choosing a playlist is asking for it to run.
        holds[display] = nil
        nextChange[display] = playlist.hasTimer ? .distantPast : nil
        persist()
    }

    /// Returns from a temporary Focus override without detaching a saved plan or
    /// immediately advancing its rotation past the restored wallpaper.
    func restore(_ playlist: DisplayPlaylist, on display: String, now: Date = Date()) {
        revisions[display, default: 0] &+= 1
        playlists[display] = playlist
        recent[display] = nil
        holds[display] = nil
        nextChange[display] = playlist.hasTimer ? now.addingTimeInterval(TimeInterval(playlist.interval * 60)) : nil
        persist()
    }

    /// A removed collection leaves an empty explicit list, never an all-library rotation.
    func forgetCollection(_ id: String) {
        var changed = false
        func detach(_ playlist: inout DisplayPlaylist) {
            guard playlist.collectionID == id else { return }
            playlist.collectionID = nil
            if playlist.source == .collection {
                playlist.source = .list
                playlist.wallpaperIDs = []
            }
            changed = true
        }
        for display in playlists.keys where playlists[display]?.collectionID == id {
            var playlist = playlists[display]!
            detach(&playlist)
            revisions[display, default: 0] &+= 1
            playlists[display] = playlist
            recent[display] = nil
        }
        for index in plans.indices { detach(&plans[index].playlist) }
        if changed { persist(plansChanged: true) }
    }

    private func persist(plansChanged: Bool = false) {
        if let data = try? JSONEncoder().encode(playlists) {
            defaults.set(data, forKey: Self.playlistsKey)
        }
        if plansChanged, let data = try? JSONEncoder().encode(plans) {
            defaults.set(data, forKey: Self.plansKey)
        }
        defaults.set(nextChange.mapValues(\.timeIntervalSince1970), forKey: Self.nextChangeKey)
        defaults.set(holds.mapValues(\.rawValue), forKey: Self.holdsKey)
        // Every change that clears or prunes a round lands here, so a playlist edit, a plan, a
        // Focus restore or a deleted wallpaper never leaves a stale round behind.
        persistRounds()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// A round as it is saved. The signature names what the round was drawn from, so a round is
    /// only picked up again for the same source, collection and order (a shuffled playlist) or
    /// the same pool (Random): the playlist's `revisions` start at zero on every launch and
    /// cannot say that.
    private struct Round: Codable, Equatable {
        var signature: String
        var ids: [String]
    }

    /// The saved rounds, in a wrapper with default-tolerant decoding so a build that keeps more
    /// kinds of round can add a field without migrating the others, and an older build ignores
    /// the ones it does not know.
    private struct SavedRounds: Codable {
        var playlists: [String: Round] = [:]
        /// Random Wallpaper's, filed under `<display>|<pool>`.
        var random: [String: Round] = [:]

        init(playlists: [String: Round] = [:], random: [String: Round] = [:]) {
            self.playlists = playlists
            self.random = random
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            playlists = (try? container.decodeIfPresent([String: Round].self, forKey: .playlists)) ?? [:]
            random = (try? container.decodeIfPresent([String: Round].self, forKey: .random)) ?? [:]
        }
    }

    private static func signature(of playlist: DisplayPlaylist) -> String {
        "\(playlist.source.rawValue)|\(playlist.collectionID ?? "")|\(playlist.order.rawValue)"
    }

    private static func randomKey(_ display: String, _ pool: AutomationCommand.RandomPool) -> String {
        "\(display)|\(pool.rawValue)"
    }

    /// The pool a Random round is filed under: what follows the last bar of its key. A display
    /// id may hold bars of its own, a pool's name never does.
    private static func randomPool(ofKey key: String) -> AutomationCommand.RandomPool? {
        key.lastIndex(of: "|").flatMap { AutomationCommand.RandomPool(rawValue: String(key[key.index(after: $0)...])) }
    }

    private static func savedRounds(in defaults: UserDefaults) -> SavedRounds {
        defaults.data(forKey: roundsKey).flatMap { try? JSONDecoder().decode(SavedRounds.self, from: $0) } ?? SavedRounds()
    }

    /// The rounds worth picking up again: a display that rotates in shuffle order over the same
    /// source and collection it was saved under. Anything else (an edited, switched-off or gone
    /// display, or a playlist restored from a backup) starts a fresh round. Wallpapers that left
    /// the library need no pruning here: the planner ignores them and the next pick drops them.
    private static func shuffleRounds(in saved: SavedRounds, for playlists: [String: DisplayPlaylist]) -> [String: [String]] {
        var rounds: [String: [String]] = [:]
        for (display, round) in saved.playlists {
            guard let playlist = playlists[display], playlist.mode == .rotate, playlist.order == .shuffle,
                  round.signature == signature(of: playlist) else { continue }
            if !round.ids.isEmpty { rounds[display] = Array(round.ids.suffix(roundLimit)) }
        }
        return rounds
    }

    /// Random rounds need no playlist to hang on, only a pool the build still knows, so a round
    /// filed under a pool this build does not have (or under a different signature) is dropped.
    private static func randomRounds(in saved: SavedRounds) -> [String: [String]] {
        var rounds: [String: [String]] = [:]
        for (key, round) in saved.random {
            guard let pool = randomPool(ofKey: key), round.signature == pool.rawValue, !round.ids.isEmpty else { continue }
            rounds[key] = Array(round.ids.suffix(roundLimit))
        }
        return rounds
    }

    /// Writes the rounds of the displays that shuffle and Random Wallpaper's, and the whole key
    /// away when there are none. Posts nothing: a pick already posts through the date of the
    /// next change, and a Random pick changes nothing the panel shows.
    private func persistRounds() {
        var rounds: [String: Round] = [:]
        for (display, ids) in recent where !ids.isEmpty {
            let playlist = playlist(for: display)
            guard playlist.mode == .rotate, playlist.order == .shuffle else { continue }
            rounds[display] = Round(signature: Self.signature(of: playlist), ids: Array(ids.suffix(Self.roundLimit)))
        }
        var random: [String: Round] = [:]
        for (key, ids) in randomRounds where !ids.isEmpty {
            guard let pool = Self.randomPool(ofKey: key) else { continue }
            random[key] = Round(signature: pool.rawValue, ids: Array(ids.suffix(Self.roundLimit)))
        }
        if rounds.isEmpty, random.isEmpty {
            if defaults.object(forKey: Self.roundsKey) != nil { defaults.removeObject(forKey: Self.roundsKey) }
        } else if let data = try? JSONEncoder().encode(SavedRounds(playlists: rounds, random: random)) {
            defaults.set(data, forKey: Self.roundsKey)
        }
    }
}
