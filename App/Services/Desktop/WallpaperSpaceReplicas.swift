import AppKit

@MainActor
protocol WallpaperSpaceReplicaSurface: AnyObject {
    var number: Int { get }
    func setImage(_ image: CGImage, frame: CGRect)
    func present(below window: Int)
    func close()
}

/// Gives each desktop sharing a wallpaper its own still window during the Space animation.
/// A live window can belong to several Spaces but the compositor need not paint it into each
/// sliding group. These single-Space windows sit below it and share one captured image, without
/// another renderer/player/page. Frames refresh on preparation, parking and content changes only.
@MainActor
final class WallpaperSpaceReplicas {
    struct Key: Hashable {
        var display: UInt32
        var wallpaper: String
    }
    typealias Plan = [Key: Set<UInt64>]

    struct Source {
        var key: Key
        var window: Int
        var layer: CALayer
        var frame: CGRect
        var revision: UInt64
        var parked: Bool
        var visit: UInt64?

        fileprivate var stamp: Stamp {
            Stamp(window: window, layer: ObjectIdentifier(layer), frame: frame, revision: revision,
                  parked: parked, visit: parked ? nil : visit)
        }
    }

    fileprivate struct Stamp: Equatable {
        var window: Int
        var layer: ObjectIdentifier
        var frame: CGRect
        var revision: UInt64
        var parked: Bool
        var visit: UInt64?
    }

    @MainActor private final class Entry {
        var source: Source
        var spaces: Set<UInt64>
        var image: CGImage?
        var attempted: Stamp?
        var windows: [UInt64: any WallpaperSpaceReplicaSurface] = [:]
        // A refused move waits for a new topology/source, never retries in an idle loop.
        var refused: Set<UInt64> = []
        init(source: Source, spaces: Set<UInt64>) { self.source = source; self.spaces = spaces }
        func close() { for window in windows.values { window.close() }; windows.removeAll(); image = nil }
    }

    private let plan: @MainActor () -> Plan
    private let sources: @MainActor () -> [Source]
    private let mover: (any WallpaperSpaceWindowMoving)?
    private let capture: @MainActor (Source) async -> CGImage?
    private let makeWindow: @MainActor (CGRect) -> any WallpaperSpaceReplicaSurface
    private let maximumImageBytes: Int
    private let maximumWindows: Int
    private var entries: [Key: Entry] = [:]
    private var captureTask: Task<Void, Never>?
    private var captureToken: UUID?

    init(plan: @escaping @MainActor () -> Plan, sources: @escaping @MainActor () -> [Source],
         mover: (any WallpaperSpaceWindowMoving)?,
         capture: @escaping @MainActor (Source) async -> CGImage? = WallpaperSpaceReplicas.capture,
         makeWindow: @escaping @MainActor (CGRect) -> any WallpaperSpaceReplicaSurface = {
             WallpaperSpaceReplicaWindow(frame: $0)
         }, maximumImageBytes: Int = 64 * 1_024 * 1_024, maximumWindows: Int = 32) {
        self.plan = plan; self.sources = sources; self.mover = mover
        self.capture = capture; self.makeWindow = makeWindow
        self.maximumImageBytes = max(4, maximumImageBytes)
        self.maximumWindows = max(0, maximumWindows)
    }

    var retainedImageBytes: Int {
        entries.values.reduce(0) { $0 + ($1.image.map { $0.bytesPerRow * $0.height } ?? 0) }
    }

    func stop() {
        captureToken = nil
        captureTask?.cancel(); captureTask = nil
        for entry in entries.values { entry.close() }
        entries.removeAll()
    }

    /// Called with the pinning and parking updates, never from a timer or a frame callback.
    func update() {
        guard mover != nil else { stop(); return }
        let available = Dictionary(sources().map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var wanted: Plan = [:]
        var count = 0
        for (key, spaces) in plan().sorted(by: { Self.precedes($0.key, $1.key) })
            where spaces.count > 1 && available[key] != nil {
            guard count + spaces.count <= maximumWindows, wanted.count < maximumImageBytes / 4 else { continue }
            count += spaces.count
            wanted[key] = spaces
        }
        for key in Array(entries.keys) where wanted[key] == nil {
            entries.removeValue(forKey: key)?.close()
        }
        for (key, spaces) in wanted {
            guard let source = available[key] else { continue }
            if let entry = entries[key], entry.source.window == source.window,
               entry.source.layer === source.layer {
                if entry.spaces != spaces || entry.source.stamp != source.stamp { entry.refused.removeAll() }
                entry.source = source
                entry.spaces = spaces
                for space in Array(entry.windows.keys) where !spaces.contains(space) {
                    entry.windows.removeValue(forKey: space)?.close()
                }
            } else {
                entries.removeValue(forKey: key)?.close()
                entries[key] = Entry(source: source, spaces: spaces)
            }
        }
        if entries.isEmpty { stop(); return }
        let budget = maximumImageBytes / entries.count
        for entry in entries.values {
            if let image = entry.image, image.bytesPerRow * image.height > budget {
                entry.image = Self.fitted(image, bytes: budget)
            }
            present(entry)
        }
        captureNext()
    }

    private static func precedes(_ first: Key, _ second: Key) -> Bool {
        (first.display, first.wallpaper) < (second.display, second.wallpaper)
    }

    private func captureNext() {
        guard captureTask == nil,
              let key = entries.keys.sorted(by: Self.precedes).first(where: {
                  entries[$0].map { $0.attempted != $0.source.stamp } ?? false
              }), let entry = entries[key] else { return }
        let source = entry.source, stamp = source.stamp
        entry.attempted = stamp
        let token = UUID()
        captureToken = token
        captureTask = Task { [weak self, weak entry, capture] in
            let image = await capture(source)
            guard let self, self.captureToken == token else { return }
            if let entry, self.entries[key] === entry, entry.source.stamp == stamp, let image {
                entry.image = Self.fitted(image, bytes: self.maximumImageBytes / max(1, self.entries.count))
                self.present(entry)
            } else if image == nil, self.entries[key] === entry {
                AppLog.warn("space replicas: no frame for window \(source.window); keeping the previous still")
            }
            self.captureTask = nil
            self.captureToken = nil
            self.captureNext()
        }
    }

    private func present(_ entry: Entry) {
        guard let image = entry.image, let mover else { return }
        for space in entry.spaces.sorted() where !entry.refused.contains(space) {
            if let window = entry.windows[space] {
                window.setImage(image, frame: entry.source.frame)
                continue
            }
            let window = makeWindow(entry.source.frame)
            window.setImage(image, frame: entry.source.frame)
            mover.move(windows: [window.number], toSpace: space)
            guard mover.spaces(ofWindow: window.number) == [space] else {
                window.close()
                entry.refused.insert(space)
                AppLog.warn("space replicas: could not place a still on desktop \(space)")
                continue
            }
            entry.windows[space] = window
            window.present(below: entry.source.window)
        }
    }

    /// One image object is shared by all of a wallpaper's windows. Downsampling only when the
    /// total budget requires it bounds retained pixel memory without rejecting a whole display.
    private static func fitted(_ image: CGImage, bytes: Int) -> CGImage? {
        if image.bytesPerRow * image.height <= bytes { return image }
        let scale = min(1, sqrt(Double(bytes / 4) / Double(image.width * image.height)))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        guard width * height * 4 <= bytes,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func capture(_ source: Source) async -> CGImage? {
        let grab = DesktopPosterGrab(center: .default, contextPrefix: "space-replica", acceptsOtherRequests: false)
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return nil }
            return await grab.run(on: source.layer, timeout: .seconds(1), sleep: { try await Task.sleep(for: $0) })?.cgImage()
        } onCancel: {
            Task { @MainActor in grab.cancel() }
        }
    }
}
