import Foundation

/// Normalized crop alignment: zero aligns the leading edge, one the trailing edge.
/// A custom value remains custom even at .5/.5/1; reset removes it and restores authored Fit.
struct StillImagePlacement: Codable, Equatable, Sendable {
    static let propertyKey = "wm_imagePlacement"
    static let zoomRange: ClosedRange<Double> = 1...3
    let x: Double
    let y: Double
    let zoom: Double

    init(x: Double, y: Double, zoom: Double) throws {
        guard x.isFinite, y.isFinite, zoom.isFinite,
              (0...1).contains(x), (0...1).contains(y), Self.zoomRange.contains(zoom)
        else { throw Failure.invalidPlacement }
        self.x = x
        self.y = y
        self.zoom = zoom
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(x: values.decode(Double.self, forKey: .x),
                      y: values.decode(Double.self, forKey: .y),
                      zoom: values.decode(Double.self, forKey: .zoom))
    }

    enum Failure: LocalizedError {
        case invalidPlacement, invalidIdentity, invalidProperties
        var errorDescription: String? {
            switch self {
            case .invalidPlacement: String(localized: "Image placement must use positions between 0 and 1 and zoom between 1 and 3.")
            case .invalidIdentity: String(localized: "Choose an installed image wallpaper and a valid display.")
            case .invalidProperties: String(localized: "The image wallpaper’s current properties could not be read.")
            }
        }
    }

    /// Mirrors the generated page's fit-aware pixel projection, including letterboxing.
    func projection(imageWidth: Double, imageHeight: Double, viewportWidth: Double,
                    viewportHeight: Double, fit: StillImageWallpaper.Fit) -> CGRect? {
        guard [imageWidth, imageHeight, viewportWidth, viewportHeight].allSatisfy({ $0.isFinite && $0 > 0 })
        else { return nil }
        let base: Double
        switch fit {
        case .fill, .fillTop: base = max(viewportWidth / imageWidth, viewportHeight / imageHeight)
        case .fit, .blur: base = min(viewportWidth / imageWidth, viewportHeight / imageHeight)
        case .center: base = 1
        }
        let width = imageWidth * base * zoom, height = imageHeight * base * zoom
        guard width.isFinite, height.isFinite else { return nil }
        return CGRect(x: (viewportWidth - width) * x, y: (viewportHeight - height) * y,
                      width: width, height: height)
    }

    static func merging(_ json: String, placement: StillImagePlacement?) throws -> String {
        guard let data = json.data(using: .utf8),
              var properties = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw Failure.invalidProperties }
        properties[propertyKey] = ["value": [
            "customized": placement != nil, "x": placement?.x ?? 0.5,
            "y": placement?.y ?? 0.5, "zoom": placement?.zoom ?? 1,
        ]]
        return String(decoding: try JSONSerialization.data(withJSONObject: properties, options: [.sortedKeys]), as: UTF8.self)
    }
}

@MainActor
final class StillImagePlacementStore {
    static let shared = StillImagePlacementStore()
    nonisolated static let storageKey = "WallpaperMachine.imagePlacements"
    static let didChangeNotification = Notification.Name("WallpaperMachine.imagePlacementsDidChange")
    private struct Envelope: Codable {
        var version = 1
        var placements: [String: [String: StillImagePlacement]] = [:]
    }
    private let defaults: UserDefaults
    let library: URL
    private var envelope: Envelope
    private struct CachedPage {
        let stamp: StillImagePageUpgrade.Stamp
        let result: StillImagePageUpgrade.Result?
    }
    private struct Flight {
        let token: UUID
        let preparesPage: Bool
        let task: Task<StillImagePageUpgrade.Result?, Error>
    }
    private var knownPages: [String: CachedPage] = [:]
    private var flights: [String: Flight] = [:]
    private var lifecycles: [String: UUID] = [:]
    private let beforeValidation: (@Sendable () throws -> Void)?

    init(defaults: UserDefaults = ClientPreferences.defaults, library: URL = ClientPaths.libraryURL,
         beforeValidation: (@Sendable () throws -> Void)? = nil) {
        self.defaults = defaults
        self.library = library
        self.beforeValidation = beforeValidation
        let saved = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(Envelope.self, from: $0) }
        envelope = saved?.version == 1 ? saved! : Envelope()
    }

    func placement(wallpaperID: String, displayID: String) -> StillImagePlacement? {
        envelope.placements[wallpaperID]?[displayID]
    }

    func set(_ placement: StillImagePlacement, wallpaperID: String, displayID: String) throws {
        try validateIdentity(wallpaperID: wallpaperID, displayID: displayID)
        guard self.placement(wallpaperID: wallpaperID, displayID: displayID) != placement else { return }
        var changed = envelope
        changed.placements[wallpaperID, default: [:]][displayID] = placement
        try persist(changed, wallpaperID: wallpaperID, displayID: displayID)
    }

    func reset(wallpaperID: String, displayID: String) throws {
        try validateIdentity(wallpaperID: wallpaperID, displayID: displayID)
        guard placement(wallpaperID: wallpaperID, displayID: displayID) != nil else { return }
        var changed = envelope
        changed.placements[wallpaperID]?[displayID] = nil
        if changed.placements[wallpaperID]?.isEmpty == true { changed.placements[wallpaperID] = nil }
        try persist(changed, wallpaperID: wallpaperID, displayID: displayID)
    }

    func forget(_ ids: Set<String>) throws {
        var changed = envelope
        for id in ids {
            changed.placements[id] = nil
            knownPages[id] = nil
            lifecycles[id] = nil
            // Removing the token fences completions even if cancellation arrives after IO.
            flights.removeValue(forKey: id)?.task.cancel()
        }
        guard changed.placements != envelope.placements else { return }
        try persist(changed)
    }

    /// Snapshot reads only a bounded metadata stamp. Inspection and preparation share one
    /// flight per wallpaper; unsupported results certify only the exact inspected version.
    func generatedImage(wallpaperID: String) -> StillImagePageUpgrade.Result? {
        guard Self.validGeneratedIdentity(wallpaperID) else { return nil }
        let stamp = StillImagePageUpgrade.stamp(project: library.appendingPathComponent(wallpaperID))
        if let cached = knownPages[wallpaperID], cached.stamp == stamp { return cached.result }
        if flights[wallpaperID] == nil {
            _ = startFlight(wallpaperID: wallpaperID, stamp: stamp, preparesPage: false)
        }
        return nil
    }

    /// Awaiting callers receive the same committed result, after cache publication. A legacy
    /// rewrite emits one pageUpgraded notification; placement changes never emit that flag.
    func prepare(wallpaperID: String) async throws -> StillImagePageUpgrade.Result? {
        guard Self.validGeneratedIdentity(wallpaperID) else { return nil }
        let lifecycle = lifecycleToken(wallpaperID: wallpaperID)
        while true {
            try Task.checkCancellation()
            if let flight = flights[wallpaperID] {
                let info = try await flight.task.value
                try Task.checkCancellation()
                guard lifecycles[wallpaperID] == lifecycle else { throw CancellationError() }
                if flight.preparesPage || info == nil { return info }
                // An inspector may have found a legacy page. Re-evaluate its version before
                // choosing a cached result or joining/starting the actual prepare flight.
                continue
            }
            let stamp = StillImagePageUpgrade.stamp(project: library.appendingPathComponent(wallpaperID))
            if let cached = knownPages[wallpaperID], cached.stamp == stamp {
                guard let info = cached.result else { return nil }
                if !info.upgraded { return info }
            }
            let flight = startFlight(wallpaperID: wallpaperID, stamp: stamp, preparesPage: true)
            let info = try await flight.task.value
            try Task.checkCancellation()
            guard lifecycles[wallpaperID] == lifecycle else { throw CancellationError() }
            return info
        }
    }

    private func startFlight(wallpaperID: String, stamp: StillImagePageUpgrade.Stamp,
                             preparesPage: Bool) -> Flight {
        let token = UUID()
        let lifecycle = lifecycleToken(wallpaperID: wallpaperID)
        let library = library
        let project = library.appendingPathComponent(wallpaperID)
        let beforeValidation = beforeValidation
        let task = Task<StillImagePageUpgrade.Result?, Error> { @MainActor [weak self] in
            try Task.checkCancellation()
            let work = Task.detached(priority: preparesPage ? .userInitiated : .utility) {
                try StillImagePageUpgrade.evaluate(wallpaperID: wallpaperID, project: project,
                    library: library, expectedStamp: stamp, upgrade: preparesPage,
                    beforeValidation: beforeValidation)
            }
            do {
                let evaluation = try await withTaskCancellationHandler {
                    try await work.value
                } onCancel: {
                    work.cancel()
                }
                try Task.checkCancellation()
                guard let self, self.flights[wallpaperID]?.token == token,
                      self.lifecycles[wallpaperID] == lifecycle else {
                    throw CancellationError()
                }
                self.flights[wallpaperID] = nil
                // A package replaced after IO is never certified by an old result, including nil.
                if let version = evaluation.stamp, StillImagePageUpgrade.stamp(project: project) == version {
                    let cached = evaluation.result.map { info in
                        StillImagePageUpgrade.Result(imageFile: info.imageFile, fit: info.fit,
                            imageAspectRatio: info.imageAspectRatio, imagePixelSize: info.imagePixelSize,
                            upgraded: preparesPage ? false : info.upgraded)
                    }
                    self.knownPages[wallpaperID] = CachedPage(stamp: version, result: cached)
                } else {
                    self.knownPages[wallpaperID] = nil
                }
                if evaluation.pageUpgraded {
                    NotificationCenter.default.post(name: Self.didChangeNotification, object: self,
                        userInfo: ["wallpaperID": wallpaperID, "pageUpgraded": true])
                } else {
                    NotificationCenter.default.post(name: Self.didChangeNotification, object: self,
                        userInfo: ["wallpaperID": wallpaperID, "metadataOnly": true])
                }
                guard let version = evaluation.stamp, self.knownPages[wallpaperID]?.stamp == version else { return nil }
                return evaluation.result
            } catch {
                if let self, self.flights[wallpaperID]?.token == token {
                    self.flights[wallpaperID] = nil
                }
                throw error
            }
        }
        let flight = Flight(token: token, preparesPage: preparesPage, task: task)
        flights[wallpaperID] = flight
        return flight
    }

    private func lifecycleToken(wallpaperID: String) -> UUID {
        if let token = lifecycles[wallpaperID] { return token }
        let token = UUID()
        lifecycles[wallpaperID] = token
        return token
    }

    private static func validGeneratedIdentity(_ wallpaperID: String) -> Bool {
        validIdentity(wallpaperID) && (wallpaperID.hasPrefix("image-") || wallpaperID.hasPrefix("pixiv-"))
    }

    /// Only call for a page proven generated by the app. Host passes its effective properties,
    /// after file/directory staging, without changing the persisted authored options.
    func effectivePropertiesJSON(_ json: String, wallpaperID: String, displayID: String) throws -> String {
        try StillImagePlacement.merging(json, placement: placement(wallpaperID: wallpaperID, displayID: displayID))
    }

    private func validateIdentity(wallpaperID: String, displayID: String) throws {
        guard Self.validIdentity(wallpaperID), Self.validIdentity(displayID) else {
            throw StillImagePlacement.Failure.invalidIdentity
        }
    }

    private static func validIdentity(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1024 && !value.contains("/") && !value.contains("\\")
            && value != "." && value != ".." && !value.unicodeScalars.contains { $0.value < 32 }
    }

    private func persist(_ changed: Envelope, wallpaperID: String? = nil, displayID: String? = nil) throws {
        let data = try JSONEncoder().encode(changed)
        defaults.set(data, forKey: Self.storageKey)
        envelope = changed
        var userInfo: [String: String] = [:]
        if let wallpaperID { userInfo["wallpaperID"] = wallpaperID }
        if let displayID { userInfo["displayID"] = displayID }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self, userInfo: userInfo)
    }
}
