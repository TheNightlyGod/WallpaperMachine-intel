import Foundation

/// Puts back the macOS wallpaper-store selections that poster writes replaced.
///
/// The per-Space picture API speaks only image paths. A desktop showing an
/// aerial, a dynamic or any other extension wallpaper (for example macOS 27's
/// default "Golden Gate" shown on all Spaces) reads as an empty selection, and
/// the public API answers with a still stand-in such as `DefaultDesktop.heic`.
/// Writing that back leaves an image choice in every Space, which macOS shows
/// as a different wallpaper. The store snapshot taken before the first poster
/// holds the real choice; only selections this app wrote are replaced, so a
/// choice made in System Settings while the app ran is kept.
enum DesktopWallpaperStoreRestoration {
    private static let imageProvider = "com.apple.wallpaper.choice.image"

    /// A picture written back through the per-Space API, and when.
    struct Write: Codable, Equatable {
        var url: URL
        var at: Date
    }

    /// How far a selection's `LastSet` may sit from a write for the write to
    /// be what set it: WallpaperAgent applies a write about 0.3 s later, and
    /// copies it into the display-wide and system-wide selections then too.
    static let writeTolerance: (before: TimeInterval, after: TimeInterval) = (2, 10)

    /// The store with every selection this app wrote put back as `original` had
    /// it, or nil when nothing needs to change. `written` are the image files
    /// the app wrote back through the per-Space API; a selection of the same
    /// file is the app's only when it was set at one of those writes, so the
    /// same picture chosen in System Settings stays. `posters` is the folder of
    /// its posters. A selection that was itself a poster in `original` is never
    /// put back.
    static func restored(current: Data, original: Data, written: [Write], posters: URL) throws -> Data? {
        guard var root = try PropertyListSerialization.propertyList(from: current, format: nil) as? [String: Any],
              let before = try PropertyListSerialization.propertyList(from: original, format: nil) as? [String: Any]
        else { throw CocoaError(.fileReadCorruptFile) }
        let writes = Dictionary(grouping: written, by: \.url.standardizedFileURL).mapValues { $0.map(\.at) }
        let posters = posters.standardizedFileURL.path
        func isOurs(_ selection: [String: Any]) -> Bool {
            guard let urls = imageURLs(selection), !urls.isEmpty else { return false }
            let set = selection["LastSet"] as? Date
            return urls.allSatisfy { url in
                if url.deletingLastPathComponent().path == posters { return true }
                // Without a time nothing shows the app set it, and the same file
                // may be the user's own choice, so it is left alone.
                guard let times = writes[url], let set else { return false }
                return times.contains {
                    set >= $0 - writeTolerance.before && set <= $0 + writeTolerance.after
                }
            }
        }
        func namesPoster(_ selection: [String: Any]) -> Bool {
            imageURLs(selection)?.contains { $0.deletingLastPathComponent().path == posters } == true
        }
        var changed = false
        for path in selectionPaths(root) {
            guard var node = node(root, path: path),
                  let desktop = node["Desktop"] as? [String: Any], isOurs(desktop) else { continue }
            let originalNode = self.node(before, path: path)
            let originalDesktop = originalNode.flatMap(desktopSelection)
            if let originalDesktop {
                guard !namesPoster(originalDesktop),
                      !(originalDesktop as NSDictionary).isEqual(to: desktop) else { continue }
                node["Desktop"] = originalDesktop
            } else {
                node.removeValue(forKey: "Desktop")
            }
            node["Type"] = type(node)
            // A node the app's write created goes, unless it holds a choice of its own.
            let keep = originalNode != nil || node["Idle"].map { !isInheritedIdle($0, path: path, root: root) } == true
            setNode(&root, path: path, value: keep && node["Type"] != nil ? node : nil)
            changed = true
        }
        guard changed else { return nil }
        // A Space the app's writes brought into the store goes once it is empty again.
        if var spaces = root["Spaces"] as? [String: Any] {
            let originalSpaces = before["Spaces"] as? [String: Any] ?? [:]
            for (id, value) in spaces where originalSpaces[id] == nil {
                guard let space = value as? [String: Any], space["Default"] == nil,
                      (space["Displays"] as? [String: Any])?.isEmpty != false else { continue }
                spaces.removeValue(forKey: id)
            }
            root["Spaces"] = spaces
        }
        return try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    }

    /// Every node that can hold a desktop selection, most specific last.
    private static func selectionPaths(_ root: [String: Any]) -> [[String]] {
        var paths: [[String]] = [["AllSpacesAndDisplays"], ["SystemDefault"]]
        let displays = (root["Displays"] as? [String: Any] ?? [:]).keys.sorted()
        paths += displays.map { ["Displays", $0] }
        let spaces = root["Spaces"] as? [String: Any] ?? [:]
        for id in spaces.keys.sorted() {
            paths.append(["Spaces", id, "Default"])
            let scoped = (spaces[id] as? [String: Any])?["Displays"] as? [String: Any] ?? [:]
            paths += scoped.keys.sorted().map { ["Spaces", id, "Displays", $0] }
        }
        return paths
    }

    /// What a node shows on the desktop: its own desktop choice or a linked one.
    private static func desktopSelection(_ node: [String: Any]) -> [String: Any]? {
        if let desktop = node["Desktop"] as? [String: Any] { return desktop }
        return node["Type"] as? String == "linked" ? node["Linked"] as? [String: Any] : nil
    }

    /// The image files a selection names, or nil when any choice is not an image.
    private static func imageURLs(_ selection: [String: Any]) -> [URL]? {
        guard let content = selection["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]] else { return nil }
        var urls: [URL] = []
        for choice in choices {
            guard choice["Provider"] as? String == imageProvider,
                  let data = choice["Configuration"] as? Data,
                  let config = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let value = config["url"] as? [String: Any], let relative = value["relative"] as? String,
                  let url = URL(string: relative), url.isFileURL else { return nil }
            urls.append(url.standardizedFileURL)
        }
        return urls
    }

    /// WallpaperAgent copies the screen-saver choice it inherits into a node it
    /// creates for a desktop write; that copy is no choice of the user's.
    private static func isInheritedIdle(_ idle: Any, path: [String], root: [String: Any]) -> Bool {
        guard let idle = idle as? [String: Any], let content = idle["Content"] as? [String: Any] else { return false }
        for fallback in [["SystemDefault"], ["AllSpacesAndDisplays"]] where fallback != path {
            guard let inherited = (node(root, path: fallback)?["Idle"] as? [String: Any])?["Content"] else { continue }
            if (inherited as? NSDictionary)?.isEqual(to: content) == true { return true }
        }
        let choices = content["Choices"] as? [[String: Any]] ?? []
        return !choices.isEmpty && choices.allSatisfy { $0["Provider"] as? String == "default" }
    }

    private static func type(_ node: [String: Any]) -> String? {
        if node["Type"] as? String == "linked", node["Linked"] != nil, node["Desktop"] == nil { return "linked" }
        switch (node["Desktop"] != nil, node["Idle"] != nil) {
        case (true, true): return "individual"
        case (true, false): return "desktop"
        case (false, true): return "idle"
        case (false, false): return nil
        }
    }

    private static func node(_ root: [String: Any], path: [String]) -> [String: Any]? {
        var node = root
        for key in path {
            guard let child = node[key] as? [String: Any] else { return nil }
            node = child
        }
        return node
    }

    private static func setNode(_ root: inout [String: Any], path: [String], value: [String: Any]?) {
        guard let key = path.first else { return }
        if path.count == 1 {
            root[key] = value
            return
        }
        var child = root[key] as? [String: Any] ?? [:]
        setNode(&child, path: Array(path.dropFirst()), value: value)
        root[key] = child
    }
}
