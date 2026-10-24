import Foundation

/// Decides which wallpapers each display that follows desktop Spaces keeps loaded and paused for
/// the desktops the person is not on, and tells the renderer and the web and video hosts.
///
/// A display keeps the wallpaper chosen for each of its desktops, Desktop 1's for one that follows
/// it, once that wallpaper has played there: leaving a desktop pauses its wallpaper in a window of
/// its own on that desktop (`WallpaperSpacePinning`), and coming back runs it on from where it
/// stopped, with no load and no still picture first. A paused wallpaper draws nothing, so the cost
/// is memory: one loaded wallpaper for each different wallpaper the display's desktops are set to.
/// A desktop set to a playlist keeps nothing.
///
/// Nothing is kept while the Mac reports memory pressure or while wallpapers are unloaded to free
/// memory, and nothing is kept for a display whose windows cannot be put on a desktop of their own.
/// A wallpaper let go loads fresh on the next visit, as it did before anything was kept.
@MainActor
final class WallpaperSpaceParking {
    /// The wallpapers each display may keep, by the CoreGraphics display id.
    typealias Plan = [UInt32: Set<String>]

    private let plan: @MainActor () -> Plan
    private let send: @MainActor (UInt32, [String]) async throws -> Void
    private let hosts: @MainActor (Plan) -> Void
    private let footprint: () -> UInt64?
    private let center: NotificationCenter
    private var observer: NSObjectProtocol?
    private var underPressure = false
    private var unloaded = false
    /// What the renderer was last told, by display.
    private var sent: Plan = [:]
    private var sending: Task<Void, Never>?
    private var hostPlan: Plan = [:]

    /// `plan` is what the displays' desktop choices ask for now; `send` hands one display's list
    /// to the renderer, `hosts` the whole plan to the web and video hosts.
    init(plan: @escaping @MainActor () -> Plan,
         send: @escaping @MainActor (UInt32, [String]) async throws -> Void,
         hosts: @escaping @MainActor (Plan) -> Void,
         footprint: (() -> UInt64?)? = nil,
         center: NotificationCenter = .default) {
        self.plan = plan
        self.send = send
        self.hosts = hosts
        self.footprint = footprint ?? { ProcessFootprint.current() }
        self.center = center
    }

    func start() {
        guard observer == nil else { return }
        observer = center.addObserver(forName: WallpaperSpaceMonitor.didChangeNotification, object: nil,
                                      queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }

    /// Lets go of everything kept.
    func stop() {
        if let observer { center.removeObserver(observer) }
        observer = nil
        update()
    }

    /// While the Mac reports memory pressure nothing is kept, and what was kept is let go.
    func setUnderPressure(_ pressure: Bool) {
        guard pressure != underPressure else { return }
        underPressure = pressure
        AppLog.info(pressure
            ? "space parking: memory pressure; letting go of the wallpapers kept for other desktops "
                + "(process footprint \(ProcessFootprint.describe(footprint())))"
            : "space parking: memory pressure over; desktops keep their wallpapers again from the next visit")
        update()
    }

    /// While wallpapers are unloaded to free memory nothing is kept either.
    func setUnloaded(_ unloaded: Bool) {
        guard unloaded != self.unloaded else { return }
        self.unloaded = unloaded
        update()
    }

    /// The wallpapers each display keeps now.
    var current: Plan { observer == nil || underPressure || unloaded ? [:] : plan().filter { !$0.value.isEmpty } }

    /// Brings the renderer and the hosts in line with the plan. Cheap: call it whenever the
    /// choices, the desktops or the displays may have changed.
    func update() {
        let wanted = current
        if wanted != hostPlan {
            hostPlan = wanted
            hosts(wanted)
        }
        sendChanges()
    }

    /// One display at a time and in order, so two quick changes cannot land the wrong way round;
    /// what changes meanwhile is sent once the one in flight is done.
    private func sendChanges() {
        guard sending == nil else { return }
        let wanted = current
        guard let display = Set(wanted.keys).union(sent.keys).sorted().first(where: { wanted[$0] != sent[$0] })
        else { return }
        let list = wanted[display] ?? []
        sending = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.send(display, list.sorted())
                self.sent[display] = list.isEmpty ? nil : list
                AppLog.info("space parking: display \(display) keeps \(list.count) wallpaper\(list.count == 1 ? "" : "s") "
                    + "for its other desktops (process footprint \(ProcessFootprint.describe(self.footprint())))")
            } catch {
                AppLog.warn("space parking: display \(display) could not be told what to keep: \(error.localizedDescription)")
                self.sending = nil
                return
            }
            self.sending = nil
            self.sendChanges()
        }
    }
}
