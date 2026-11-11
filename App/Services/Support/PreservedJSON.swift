import Foundation

/// Reads a saved JSON object or array one entry at a time, and writes it back with the entries
/// this build could not read still in it.
///
/// Several stores keep every display's (or every item's) settings in one JSON value. Decoded as a
/// whole, one entry this build does not understand (saved by a newer build that knows another
/// mode or action, or damaged) fails the read of all of them, and the next save then writes only
/// what the user just edited over the rest. Read through here, such an entry is set aside as it
/// was saved, the others load, and a save puts it back unchanged, so installing the newer build
/// again finds it.
///
/// A value that decodes whole is returned exactly as `JSONDecoder` reads it, and a save with
/// nothing set aside is exactly what `JSONEncoder` writes: only a value with an unreadable entry
/// takes the entry-by-entry path.
enum PreservedJSON {
    /// The entries of a JSON object that decode as `Value` and pass `accepts`, and the others as
    /// they were saved. Nil when `data` is not a JSON object at all.
    static func readObject<Value: Decodable>(
        _ data: Data, as type: Value.Type, accepts: (String, Value) -> Bool = { _, _ in true }
    ) -> (values: [String: Value], unread: [String: Data])? {
        if let whole = try? JSONDecoder().decode([String: Value].self, from: data),
           whole.allSatisfy({ accepts($0.key, $0.value) }) {
            return (whole, [:])
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var values: [String: Value] = [:]
        var unread: [String: Data] = [:]
        for (key, entry) in object {
            guard let raw = fragment(entry) else { continue }
            if let value = try? JSONDecoder().decode(Value.self, from: raw), accepts(key, value) {
                values[key] = value
            } else {
                unread[key] = raw
            }
        }
        return (values, unread)
    }

    /// The elements of a JSON array that decode as `Value`, in order, and the others as they were
    /// saved. Nil when `data` is not a JSON array at all.
    static func readArray<Value: Decodable>(_ data: Data, as type: Value.Type) -> (values: [Value], unread: [Data])? {
        if let whole = try? JSONDecoder().decode([Value].self, from: data) { return (whole, []) }
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return nil }
        var values: [Value] = []
        var unread: [Data] = []
        for entry in array {
            guard let raw = fragment(entry) else { continue }
            if let value = try? JSONDecoder().decode(Value.self, from: raw) {
                values.append(value)
            } else {
                unread.append(raw)
            }
        }
        return (values, unread)
    }

    /// `values` as a JSON object, with each `unread` entry whose key `values` does not hold put
    /// back as it was saved. A key the user has since given a value keeps that value.
    static func writeObject<Value: Encodable>(_ values: [String: Value], keeping unread: [String: Data]) throws -> Data {
        let encoded = try JSONEncoder().encode(values)
        let kept = unread.filter { values[$0.key] == nil }
        guard !kept.isEmpty else { return encoded }
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { return encoded }
        for (key, raw) in kept {
            object[key] = try JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed])
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// `values` as a JSON array, with the `unread` elements after them as they were saved.
    static func writeArray<Value: Encodable>(_ values: [Value], keeping unread: [Data]) throws -> Data {
        let encoded = try JSONEncoder().encode(values)
        guard !unread.isEmpty else { return encoded }
        guard var array = try JSONSerialization.jsonObject(with: encoded) as? [Any] else { return encoded }
        for raw in unread {
            array.append(try JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed]))
        }
        return try JSONSerialization.data(withJSONObject: array)
    }

    private static func fragment(_ value: Any) -> Data? {
        try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
    }
}
