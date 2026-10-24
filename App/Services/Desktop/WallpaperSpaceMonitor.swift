import AppKit
import Darwin

struct WallpaperDesktopSpace: Equatable, Sendable {
    var id: String
    var number: Int
    /// The window server's number for the desktop, which a window is put on; nil when the
    /// topology does not give one.
    var managedID: UInt64? = nil
}

struct WallpaperDisplaySpaces: Equatable, Sendable {
    var displayUUID: String
    var spaces: [WallpaperDesktopSpace]
    var current: String?
    /// The window server's number for the current desktop, which a window is moved to; nil on a
    /// full-screen app's Space or when the topology does not give one.
    var currentManagedID: UInt64? = nil
}

struct WallpaperSpaceVisit: Equatable, Sendable {
    var spaceID: String
    var token: String
    /// The display's Desktop 1, whose choice a desktop without one follows.
    var firstSpaceID: String? = nil
}

/// Read-only Space topology and persistent visit identities for automatic selection.
@MainActor
final class WallpaperSpaceMonitor {
    static let visitsKey = "WallpaperMachine.spaceVisits"
    static let didChangeNotification = Notification.Name("WallpaperMachine.desktopSpacesChanged")
    static let shared = WallpaperSpaceMonitor(defaults: ClientPreferences.defaults,
        provider: { SystemWallpaperSpaceSource.shared?.read() },
        workspaceCenter: NSWorkspace.shared.notificationCenter, displayCenter: .default)
    typealias Provider = @MainActor () -> [String: WallpaperDisplaySpaces]?
    private struct Visit: Codable { var space: String; var token: String }
    private let defaults: UserDefaults?
    private let provider: Provider
    private let workspaceCenter: NotificationCenter?
    private let displayCenter: NotificationCenter?
    private let displayConfiguration: @MainActor () -> DisplayConfiguration
    /// The displays the last screen change found.
    private var screenDisplays: DisplayConfiguration?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var retry: Task<Void, Never>?
    private var visits: [String: Visit]
    private(set) var displays: [String: WallpaperDisplaySpaces] = [:]
    private(set) var available = false

    init(defaults: UserDefaults? = nil, provider: @escaping Provider = { nil },
         workspaceCenter: NotificationCenter? = nil, displayCenter: NotificationCenter? = nil,
         displayConfiguration: @escaping @MainActor () -> DisplayConfiguration = DisplayConfiguration.current) {
        self.defaults = defaults; self.provider = provider
        self.workspaceCenter = workspaceCenter; self.displayCenter = displayCenter
        self.displayConfiguration = displayConfiguration
        let data = defaults?.data(forKey: Self.visitsKey)
        let loaded = data.flatMap { $0.count <= 128 * 1024 ? try? JSONDecoder().decode([String: Visit].self, from: $0) : nil } ?? [:]
        visits = loaded.count <= 64 ? loaded.filter { !$0.key.isEmpty && $0.key.count <= 128
            && !$0.value.space.isEmpty && $0.value.space.count <= 128 && UUID(uuidString: $0.value.token) != nil } : [:]
    }

    func start() {
        guard observers.isEmpty else { return }
        for (center, name) in [(workspaceCenter, NSWorkspace.activeSpaceDidChangeNotification),
                               (workspaceCenter, NSWorkspace.didWakeNotification),
                               (displayCenter, NSApplication.didChangeScreenParametersNotification)] {
            guard let center else { continue }
            let screens = name == NSApplication.didChangeScreenParametersNotification
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { screens ? self?.screensChanged() : self?.refresh() }
            }
            observers.append((center, observer))
        }
        screenDisplays = displayConfiguration()
        refresh()
    }

    func stop() {
        retry?.cancel(); retry = nil
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
    }

    func refresh() { retry?.cancel(); retry = nil; read(attempt: 0) }

    /// Each read is a round trip to the window server, and an XDR display posts a screen
    /// change for every frame of an EDR headroom ramp. Only a display that came, went or
    /// moved can change which Spaces belong to which display.
    private func screensChanged() {
        let current = displayConfiguration()
        guard current != screenDisplays else { return }
        screenDisplays = current
        refresh()
    }

    private func read(attempt: Int) {
        let next = provider()
        let wasAvailable = available
        let before = displays
        available = next != nil
        displays = next ?? [:]
        var changedVisits = false
        for display in displays.values {
            guard let space = display.current, visits[display.displayUUID]?.space != space else { continue }
            if visits.count >= 64, visits[display.displayUUID] == nil {
                let live = Set(displays.values.map(\.displayUUID))
                visits = visits.filter { live.contains($0.key) }
            }
            visits[display.displayUUID] = Visit(space: space, token: UUID().uuidString)
            changedVisits = true
        }
        if changedVisits, let data = try? JSONEncoder().encode(visits) { defaults?.set(data, forKey: Self.visitsKey) }
        if wasAvailable != available || before != displays || changedVisits {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
        guard next == nil, attempt < 3 else { return }
        retry = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100 * (attempt + 1))) } catch { return }
            self?.read(attempt: attempt + 1)
        }
    }

    func visit(for physicalDisplay: String) -> WallpaperSpaceVisit? {
        guard available, let display = displays[physicalDisplay], let current = display.current,
              let visit = visits[display.displayUUID], visit.space == current else { return nil }
        return .init(spaceID: current, token: visit.token, firstSpaceID: display.spaces.first?.id)
    }

    func physicalDisplay(_ id: String, title: String) -> String? {
        ResolvedDisplayTitles.liveDisplayID(id, title: title).map(String.init)
    }

    /// Decode UUIDs, never ordinal desktop numbers. A fullscreen current Space is a valid
    /// topology with no active desktop choice. Malformed or ambiguous groups fail closed.
    nonisolated static func decode(groups: [[String: Any]], displays: [String: String]) -> [String: WallpaperDisplaySpaces]? {
        guard !groups.isEmpty, groups.count <= 64, displays.count <= 64 else { return nil }
        var result: [String: WallpaperDisplaySpaces] = [:]
        func string(_ value: Any?) -> String? {
            guard let value = value as? String, !value.isEmpty, value.count <= 128,
                  !value.contains(where: { $0.isNewline || $0 == "\0" }) else { return nil }
            return value
        }
        func number(_ value: Any?) -> UInt64? {
            guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue >= 0, value.doubleValue.isFinite,
                  value.doubleValue < Double(UInt64.max), value.doubleValue.rounded() == value.doubleValue else { return nil }
            return value.uint64Value
        }
        for group in groups {
            guard let identifier = string(group["Display Identifier"]) else { return nil }
            let matching = displays.filter { identifier == "Main" || $0.value.caseInsensitiveCompare(identifier) == .orderedSame }
            if matching.isEmpty { continue }
            guard let raw = group["Spaces"] as? [[String: Any]], !raw.isEmpty, raw.count <= 128,
                  let current = group["Current Space"] as? [String: Any] else { return nil }
            var decoded: [(id: String?, number: UInt64?, type: UInt64)] = []
            for space in raw {
                guard let type = number(space["type"]) else { return nil }
                let id = string(space["uuid"])
                let identifier = number(space["ManagedSpaceID"] ?? space["id64"])
                guard (type != 0 || id != nil), id != nil || identifier != nil else { return nil }
                decoded.append((id, identifier, type))
            }
            let uuids = decoded.compactMap(\.id)
            guard Set(uuids).count == uuids.count else { return nil }
            let currentUUID = string(current["uuid"])
            let currentNumber = number(current["ManagedSpaceID"] ?? current["id64"])
            let active = decoded.filter { item in
                if let currentUUID, let id = item.id { return id == currentUUID }
                return currentNumber != nil && item.number == currentNumber
            }
            guard active.count == 1 else { return nil }
            let desktops = decoded.filter { $0.type == 0 }.enumerated().map {
                WallpaperDesktopSpace(id: $0.element.id!, number: $0.offset + 1, managedID: $0.element.number)
            }
            for (display, uuid) in matching {
                guard result[display] == nil else { return nil }
                let desktop = active[0].type == 0
                result[display] = .init(displayUUID: uuid, spaces: desktops, current: desktop ? active[0].id : nil,
                                        currentManagedID: desktop ? currentNumber ?? active[0].number : nil)
            }
        }
        return result.isEmpty ? nil : result
    }
}

/// Optional read-only CGS entry points, matching the existing desktop-poster integration.
@MainActor
private final class SystemWallpaperSpaceSource {
    static let shared = SystemWallpaperSpaceSource()
    private typealias Connection = @convention(c) () -> Int32
    private typealias CopySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private let connection: Connection
    private let copySpaces: CopySpaces

    init?() {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let connection = dlsym(handle, "_CGSDefaultConnection"),
              let spaces = dlsym(handle, "CGSCopyManagedDisplaySpaces") else { return nil }
        self.connection = unsafeBitCast(connection, to: Connection.self)
        copySpaces = unsafeBitCast(spaces, to: CopySpaces.self)
    }

    func read() -> [String: WallpaperDisplaySpaces]? {
        guard let groups = copySpaces(connection())?.takeRetainedValue() as? [[String: Any]] else { return nil }
        var displays: [String: String] = [:]
        for screen in NSScreen.screens {
            guard let id = SystemDesktopPictureWorkspace.id(screen), let number = UInt32(id),
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue() else { continue }
            displays[id] = CFUUIDCreateString(nil, uuid) as String
        }
        return WallpaperSpaceMonitor.decode(groups: groups, displays: displays)
    }
}
