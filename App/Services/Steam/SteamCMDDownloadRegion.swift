import Darwin
import Foundation

/// The download region (Steam's "cell") SteamCMD starts from, written into the config it reads
/// before every run.
///
/// Steam picks a cell at each sign-in from the address it sees, but for an address in mainland
/// China it does not always pick a mainland one: a sign-in can come back with Singapore (35), and
/// SteamCMD then fetches every chunk across the border, where throughput falls to a few KB/s at
/// busy hours and the download stalls. Given a mainland cell instead, Steam answers with its own
/// nearest mainland cell and its mainland download servers, and lists its nearest connection
/// servers (Hong Kong, Tokyo) first. From an address outside mainland China Steam replaces a
/// mainland cell with its own choice, so a wrong guess changes nothing. The saved sign-in keeps
/// SteamCMD's config, so without this one unlucky first sign-in held every later download on the
/// far servers.
struct SteamCMDDownloadRegion: Equatable, Sendable {
    /// The cell to start from; nil leaves Steam's own choice untouched.
    let cell: Int?

    /// Shanghai. Steam narrows any mainland cell to the one it would give the address.
    static let mainlandChinaCell = 47
    /// The mainland cells in Steam's download-region list. A cell Steam chose that is missing
    /// here is replaced by `mainlandChinaCell`, which Steam narrows again, so a gap costs nothing.
    static let mainlandChinaCells: Set<Int> = [
        46, 47, 48, 148, 159, 160, 166, 167, 168, 169, 170, 171,
        197, 198, 199, 200, 201, 202, 203, 204, 205, 206, 211,
    ]
    /// The time zones macOS sets for a Mac in mainland China (and their older aliases). Hong Kong,
    /// Macau and Taiwan have zones of their own and reach Steam's servers directly.
    static let mainlandChinaTimeZones: Set<String> = [
        "Asia/Shanghai", "Asia/Urumqi", "Asia/Chongqing", "Asia/Chungking", "Asia/Harbin",
        "Asia/Kashgar", "PRC",
    ]

    /// Leaves the region to Steam.
    static let steamsChoice = SteamCMDDownloadRegion(cell: nil)

    static func forTimeZone(_ zone: TimeZone) -> SteamCMDDownloadRegion {
        mainlandChinaTimeZones.contains(zone.identifier) ? SteamCMDDownloadRegion(cell: mainlandChinaCell) : .steamsChoice
    }

    static var current: SteamCMDDownloadRegion { forTimeZone(.current) }

    /// Where SteamCMD keeps its config under the home it runs with.
    static func configFile(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/Steam/config/config.vdf")
    }

    /// Writes the cell into the config of the SteamCMD home `home`, keeping the rest of it (a
    /// restored sign-in lives there). Best effort: a config it cannot read or write is left as it
    /// is, and the run goes on with Steam's own choice.
    func seed(home: URL) {
        guard let cell else { return }
        let file = Self.configFile(home: home)
        let files = FileManager.default
        do {
            var info = stat()
            let existing: String?
            if lstat(file.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFREG else {
                    AppLog.warn("SteamCMD config is not a regular file; download region left to Steam")
                    return
                }
                existing = String(decoding: try Data(contentsOf: file), as: UTF8.self)
            } else {
                existing = nil
                try files.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                          attributes: [.posixPermissions: 0o700])
            }
            guard let seeded = Self.seeding(existing, cell: cell) else { return }
            try Data(seeded.utf8).write(to: file, options: .atomic)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            AppLog.warn("SteamCMD download region could not be set: \(error.localizedDescription)")
        }
    }

    /// `config` with its download region set to `cell`; nil when it already names a mainland cell
    /// or is not a config this can read. A missing or empty config becomes one holding the cell.
    static func seeding(_ config: String?, cell: Int) -> String? {
        let bytes = Array((config ?? "").utf8)
        guard let parsed = KeyValues(bytes) else { return nil }
        let value = Array("\"\(cell)\"".utf8)
        if !parsed.cellValues.isEmpty {
            if parsed.cellValues.allSatisfy({ Int($0.text).map(mainlandChinaCells.contains) == true }) { return nil }
            var edited = bytes
            for found in parsed.cellValues.reversed() { edited.replaceSubrange(found.range, with: value) }
            return String(decoding: edited, as: UTF8.self)
        }
        if let index = parsed.steamBlockBody {
            var edited = bytes
            edited.insert(contentsOf: Array("\n\t\t\t\t\"CellIDServerOverride\"\t\t".utf8) + value, at: index)
            return String(decoding: edited, as: UTF8.self)
        }
        guard parsed.isEmpty else { return nil }
        return """
        "InstallConfigStore"
        {
        \t"Software"
        \t{
        \t\t"Valve"
        \t\t{
        \t\t\t"Steam"
        \t\t\t{
        \t\t\t\t"CellIDServerOverride"\t\t"\(cell)"
        \t\t\t}
        \t\t}
        \t}
        }

        """
    }

    /// Just enough of Valve's KeyValues text to find `InstallConfigStore/Software/Valve/Steam` and
    /// its `CellIDServerOverride`. Keys compare without case, as Steam reads them.
    private struct KeyValues {
        struct Value {
            let range: Range<Int>
            let text: String
        }

        private static let steamPath = ["installconfigstore", "software", "valve", "steam"]
        private(set) var cellValues: [Value] = []
        /// Just after the `{` that opens the Steam block.
        private(set) var steamBlockBody: Int?
        private(set) var isEmpty = true

        /// Nil when the text is not well-formed KeyValues.
        init?(_ bytes: [UInt8]) {
            var path: [String] = []
            var key: String?
            var index = 0
            while index < bytes.count {
                let byte = bytes[index]
                switch byte {
                case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"):
                    index += 1
                case UInt8(ascii: "/") where index + 1 < bytes.count && bytes[index + 1] == UInt8(ascii: "/"):
                    while index < bytes.count, bytes[index] != UInt8(ascii: "\n") { index += 1 }
                case UInt8(ascii: "{"):
                    guard let opened = key else { return nil }
                    path.append(opened.lowercased())
                    key = nil
                    index += 1
                    if path == Self.steamPath, steamBlockBody == nil { steamBlockBody = index }
                case UInt8(ascii: "}"):
                    guard key == nil, !path.isEmpty else { return nil }
                    path.removeLast()
                    index += 1
                default:
                    isEmpty = false
                    let start = index
                    let text: String
                    if byte == UInt8(ascii: "\"") {
                        index += 1
                        var content: [UInt8] = []
                        while true {
                            guard index < bytes.count else { return nil }
                            let next = bytes[index]
                            if next == UInt8(ascii: "\"") { index += 1; break }
                            if next == UInt8(ascii: "\\"), index + 1 < bytes.count {
                                content.append(bytes[index + 1])
                                index += 2
                                continue
                            }
                            content.append(next)
                            index += 1
                        }
                        text = String(decoding: content, as: UTF8.self)
                    } else {
                        let delimiters: Set<UInt8> = Set(" \t\r\n{}\"".utf8)
                        while index < bytes.count, !delimiters.contains(bytes[index]) { index += 1 }
                        text = String(decoding: bytes[start..<index], as: UTF8.self)
                    }
                    if let pending = key {
                        if path == Self.steamPath, pending.lowercased() == "cellidserveroverride" {
                            cellValues.append(Value(range: start..<index, text: text))
                        }
                        key = nil
                    } else {
                        key = text
                    }
                }
            }
            guard path.isEmpty, key == nil else { return nil }
        }
    }
}
