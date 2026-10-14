import Foundation

/// Decides what a running preview is told when the property draft changes.
///
/// A preview cannot take every kind of property in place: a picture or a file is read
/// when the wallpaper loads, so the property keeps the value the preview started with and
/// the window offers a reload. Everything else follows the draft.
///
/// Both payloads the bridge writes are one object keyed by property id: a scene's holds the
/// plain value, a Web wallpaper's holds `{ value, type, … }`. Only the ids matter here, so
/// one rule serves both and an entry is kept or replaced whole.
enum LivePropertyPayload {
    struct Merged: Equatable {
        /// The properties to show, with sorted keys, so equal states are equal strings.
        let json: String
        /// A property the preview cannot change in place differs from the value it started with.
        let frozenChanged: Bool
    }

    /// `started` is the JSON the preview was created with and `latest` the newest one built
    /// from the draft. Each id in `frozen` keeps its started entry, or stays absent if it had
    /// none. Returns nil when either document is not a JSON object.
    static func merge(started: String, latest: String, frozen: Set<String>) -> Merged? {
        guard let loaded = object(started), var live = object(latest) else { return nil }
        var changed = false
        for id in frozen {
            let before = loaded[id], after = live[id]
            if encoded(before) != encoded(after) { changed = true }
            live[id] = before
        }
        guard let json = encode(live) else { return nil }
        return Merged(json: json, frozenChanged: changed)
    }

    /// The same document with sorted keys, or nil when it is not a JSON object.
    static func canonical(_ json: String) -> String? {
        object(json).flatMap(encode)
    }

    private static func object(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func encode(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// One entry as canonical text; a missing entry is its own value, distinct from `null`.
    private static func encoded(_ value: Any?) -> String? {
        guard let value else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
