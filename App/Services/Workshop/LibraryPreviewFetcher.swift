import Foundation

/// Reads an installed wallpaper's own preview file for a `WorkshopThumbnailCache`, so the Installed
/// grid shows small cached stills instead of decoding every preview, animated ones included, at
/// full size. The cache is asked for `file:` addresses; only an image inside the library is read.
struct LibraryPreviewFetcher: WorkshopThumbnailFetching {
    /// The same ceiling the panel's raw preview route has always applied.
    static let maximumBytes = 32 * 1024 * 1024
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "avif", "bmp", "tiff"]

    let root: URL
    let byteLimit: Int

    init(root: URL = ClientPaths.libraryURL, byteLimit: Int = LibraryPreviewFetcher.maximumBytes) {
        self.root = root
        self.byteLimit = max(1, byteLimit)
    }

    func fetch(_ url: URL) async throws -> Data {
        guard url.isFileURL else { throw URLError(.unsupportedURL) }
        // A stamped address (see `identity`) carries its stamp in the query, never in the path.
        guard let file = Self.confined(URL(fileURLWithPath: url.path), in: root) else {
            throw URLError(.noPermissionsToReadFile)
        }
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else { throw URLError(.fileDoesNotExist) }
        guard (values.fileSize ?? 0) <= byteLimit else { throw URLError(.dataLengthExceedsMaximum) }
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { throw URLError(.cannotOpenFile) }
        guard data.count <= byteLimit else { throw URLError(.dataLengthExceedsMaximum) }
        return data
    }

    /// `file` with its symlinks resolved, when it lies inside `root` and names an image.
    static func confined(_ file: URL, in root: URL) -> URL? {
        let resolved = file.resolvingSymlinksInPath().standardizedFileURL
        let prefix = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard resolved.path.hasPrefix(prefix), imageExtensions.contains(resolved.pathExtension.lowercased()) else {
            return nil
        }
        return resolved
    }

    /// The address a preview is cached under: the file stamped with its modification time and size,
    /// so a preview that was replaced gets a new entry and the old one ages out of the cache.
    static func identity(of file: URL, in root: URL = ClientPaths.libraryURL) throws -> URL {
        guard let confined = confined(file, in: root) else { throw URLError(.noPermissionsToReadFile) }
        let print = try fingerprint(of: confined)
        var components = URLComponents()
        components.scheme = "file"
        components.path = confined.path
        components.queryItems = [
            URLQueryItem(name: "m", value: String(print.modified)),
            URLQueryItem(name: "s", value: String(print.size)),
        ]
        guard let stamped = components.url else { throw URLError(.badURL) }
        return stamped
    }

    /// One number that changes when the preview file is replaced: a digest of the same
    /// modification time and size `identity` stamps the cache entry with. The panel puts it in a
    /// cover's address, so the page asks for a cover again only when its preview changed. Nil when
    /// the file cannot be read. Reads the file system, so never on the main actor's snapshot path.
    static func coverStamp(of file: URL) -> UInt64? {
        guard let print = try? fingerprint(of: file.resolvingSymlinksInPath()) else { return nil }
        // FNV-1a over the eight bytes of each fact.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for word in [UInt64(bitPattern: print.modified), UInt64(clamping: print.size)] {
            for shift in stride(from: 0, to: 64, by: 8) {
                hash = (hash ^ ((word >> UInt64(shift)) & 0xff)) &* 0x0000_0100_0000_01b3
            }
        }
        return hash
    }

    /// The modification time in microseconds and the size in bytes.
    private static func fingerprint(of file: URL) throws -> (modified: Int64, size: Int) {
        let values = try file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modified = Int64(((values.contentModificationDate ?? .distantPast).timeIntervalSince1970 * 1_000_000).rounded())
        return (modified, values.fileSize ?? 0)
    }
}
