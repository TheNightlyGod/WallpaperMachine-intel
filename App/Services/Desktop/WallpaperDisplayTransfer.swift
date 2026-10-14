import Foundation

/// A bounded multi-display switch with validation before writes and verified recovery.
@MainActor
enum WallpaperDisplayTransfer {
    struct Display: Equatable {
        var id: String
        var title: String
        var eligible: Bool
        var wallpaperID: String?
    }
    struct Snapshot {
        var displays: [Display]
        var wallpapers: Set<String>
        var reliable = true
        /// Wallpapers the load journal holds back after repeated crashes. A held wallpaper keeps
        /// its display assignment, so its display reads as showing it while it has no scene.
        var held: Set<String> = []
    }
    enum Request {
        case layout([WallpaperDisplayAssignment])
        case copy(from: String, to: String)
        case swap(String, String)
        /// One wallpaper on every eligible display. The displays are read from the snapshot the
        /// request is planned in, not fixed when it is made, so `execute` plans again after
        /// preparing and refuses a display set that moved.
        case everywhere(wallpaperID: String)

        /// Whether the request is the user naming one wallpaper to open, which counts as choosing
        /// it again after a crash hold. Copy, swap and a layout move assignments that already
        /// exist, so they leave a hold alone.
        var releasesHold: Bool {
            if case .everywhere = self { true } else { false }
        }

        /// The displays the request gives a wallpaper to, which is what it is a choice for: a
        /// copy leaves its source as it was.
        func displayIDs(in snapshot: Snapshot) -> [String] {
            switch self {
            case .layout(let values): values.map(\.displayID)
            case .copy(_, let target): [target]
            case .swap(let first, let second): [first, second]
            case .everywhere: WallpaperDisplayTransfer.eligibleDisplays(in: snapshot).map(\.id)
            }
        }
    }
    typealias Apply = @MainActor (String, String) async throws -> Void
    typealias Clear = @MainActor (String, String) async throws -> Void

    static func capture(_ snapshot: Snapshot) throws -> [WallpaperDisplayAssignment] {
        guard snapshot.reliable else { throw WallpaperDisplayLayoutError.changed }
        let values = snapshot.displays.compactMap { display -> WallpaperDisplayAssignment? in
            guard display.eligible, let id = display.wallpaperID else { return nil }
            return .init(displayID: display.id, displayTitle: display.title, wallpaperID: id)
        }
        guard !values.isEmpty else { throw WallpaperDisplayLayoutError.noWallpapers }
        try validate(values, in: snapshot)
        return values
    }

    /// The displays a wallpaper can be given to, the main display first and the others in the
    /// order the snapshot lists them, so the screen being looked at changes first.
    nonisolated static func eligibleDisplays(in snapshot: Snapshot) -> [Display] {
        let eligible = snapshot.displays.filter(\.eligible)
        return eligible.filter { $0.id == "primary" } + eligible.filter { $0.id != "primary" }
    }

    static func plan(_ request: Request, in snapshot: Snapshot) throws -> [WallpaperDisplayAssignment] {
        let result: [WallpaperDisplayAssignment]
        switch request {
        case .layout(let values): result = values
        case .everywhere(let wallpaperID):
            guard snapshot.reliable else { throw WallpaperDisplayLayoutError.changed }
            let targets = eligibleDisplays(in: snapshot)
            guard !targets.isEmpty else { throw WallpaperDisplayLayoutError.noEligibleDisplays }
            result = targets.map { .init(displayID: $0.id, displayTitle: $0.title, wallpaperID: wallpaperID) }
        case .copy(let source, let target), .swap(let source, let target):
            guard source != target else { throw WallpaperDisplayLayoutError.sameDisplay }
            let first = try display(source, in: snapshot)
            let second = try display(target, in: snapshot)
            guard let id = first.wallpaperID else { throw WallpaperDisplayLayoutError.noWallpapers }
            var values = [WallpaperDisplayAssignment(displayID: target, displayTitle: second.title, wallpaperID: id)]
            if case .swap = request {
                guard let other = second.wallpaperID else { throw WallpaperDisplayLayoutError.noWallpapers }
                values.append(.init(displayID: source, displayTitle: first.title, wallpaperID: other))
            }
            result = values
        }
        try validate(result, in: snapshot)
        return result
    }

    static func validate(_ values: [WallpaperDisplayAssignment], in snapshot: Snapshot) throws {
        guard snapshot.reliable else { throw WallpaperDisplayLayoutError.changed }
        try WallpaperDisplayLayoutStore.validateAssignments(values)
        for value in values {
            _ = try display(value.displayID, title: value.displayTitle, in: snapshot)
            guard snapshot.wallpapers.contains(value.wallpaperID) else {
                throw WallpaperDisplayLayoutError.unavailableWallpaper(value.wallpaperID)
            }
        }
    }

    static func execute(_ request: Request, snapshot: @escaping @MainActor () -> Snapshot,
                        prepare: @MainActor (Set<String>) async throws -> Void,
                        apply: @escaping Apply, clear: @escaping Clear) async throws -> [WallpaperDisplayAssignment] {
        let before = snapshot()
        let assignments = try plan(request, in: before)
        let ids = Set(assignments.map(\.wallpaperID) + assignments.compactMap { value in
            before.displays.first(where: { $0.id == value.displayID })?.wallpaperID
        })
        try await prepare(ids)
        try Task.checkCancellation()
        let ready = snapshot()
        guard try plan(request, in: ready) == assignments,
              assignments.allSatisfy({ value in
                  ready.displays.first(where: { $0.id == value.displayID })?.wallpaperID
                    == before.displays.first(where: { $0.id == value.displayID })?.wallpaperID
              }) else { throw WallpaperDisplayLayoutError.changed }
        var attempted: [WallpaperDisplayAssignment] = []
        do {
            for value in assignments {
                try Task.checkCancellation()
                let current = snapshot()
                try validate(assignments, in: current)
                let existing = current.displays.first { $0.id == value.displayID }?.wallpaperID
                let original = before.displays.first { $0.id == value.displayID }?.wallpaperID
                guard existing == original else { throw WallpaperDisplayLayoutError.changed }
                attempted.append(value)
                // A held wallpaper's display reads as showing it, so it is applied again until the
                // hold is lifted: the first apply lifts it for every display, and the displays after
                // it find the wallpaper opened and are skipped like any other.
                let held = request.releasesHold && current.held.contains(value.wallpaperID)
                if existing != value.wallpaperID || held { try await apply(value.wallpaperID, value.displayID) }
            }
            let after = snapshot()
            try validate(assignments, in: after)
            guard assignments.allSatisfy({ value in
                after.displays.first { $0.id == value.displayID }?.wallpaperID == value.wallpaperID
            }) else { throw WallpaperDisplayLayoutError.changed }
            return assignments
        } catch {
            let reason = error.localizedDescription
            // Recovery must still run when the caller cancels midway through a swap.
            let failures = await Task { @MainActor in
                await recover(attempted, all: assignments, before: before, snapshot: snapshot, apply: apply, clear: clear)
            }.value
            if failures.isEmpty { throw WallpaperDisplayLayoutError.restored(reason) }
            throw WallpaperDisplayLayoutError.incomplete(failures.joined(separator: ", "), reason)
        }
    }

    private static func recover(_ attempted: [WallpaperDisplayAssignment], all: [WallpaperDisplayAssignment], before: Snapshot,
                                snapshot: @MainActor () -> Snapshot, apply: Apply, clear: Clear) async -> [String] {
        var failures: [String] = []
        for value in attempted.reversed() {
            let current = snapshot()
            let original = before.displays.first { $0.id == value.displayID }?.wallpaperID
            guard current.reliable, let screen = current.displays.first(where: { $0.id == value.displayID }), screen.eligible else {
                failures.append(value.displayTitle); continue
            }
            if screen.wallpaperID == original { continue }
            guard screen.wallpaperID == value.wallpaperID else { failures.append(value.displayTitle); continue }
            do {
                if let original { try await apply(original, value.displayID) }
                else { try await clear(value.wallpaperID, value.displayID) }
            } catch { AppLog.warn("display layout recovery failed: \(error.localizedDescription)") }
            let verified = snapshot()
            if !verified.reliable || verified.displays.first(where: { $0.id == value.displayID })?.wallpaperID != original {
                failures.append(value.displayTitle)
            }
        }
        let final = snapshot()
        for value in all where !failures.contains(value.displayTitle) {
            let original = before.displays.first { $0.id == value.displayID }?.wallpaperID
            guard final.reliable, let display = final.displays.first(where: { $0.id == value.displayID }),
                  display.eligible, display.wallpaperID == original else { failures.append(value.displayTitle); continue }
        }
        return failures
    }

    private static func display(_ id: String, title: String? = nil, in snapshot: Snapshot) throws -> Display {
        guard let value = snapshot.displays.first(where: { $0.id == id }), value.eligible else {
            throw WallpaperDisplayLayoutError.unavailableDisplay(title ?? snapshot.displays.first { $0.id == id }?.title ?? id)
        }
        return value
    }
}
