import Darwin
import Foundation

/// Copies user imports non-destructively and adopts validated private Steam downloads.
actor WallpaperImportService {
    enum DuplicatePolicy: String, CaseIterable, Identifiable, Sendable {
        case skip = "Skip existing"
        case keepBoth = "Keep both copies"
        /// A project whose id is installed and whose content differs takes the installed one's place;
        /// identical content is skipped, as with Keep both copies.
        case replaceChanged = "Replace if changed"
        var id: String { rawValue }
    }

    struct Report: Sendable {
        var importedIDs: [String] = []
        var skipped: [String] = []
        /// The part of `skipped` that Keep both copies left alone because the library already held
        /// exactly the same content: nothing was copied.
        var identical: [String] = []
        /// The part of `importedIDs` that took the place of an installed project. Wallpaper options,
        /// user files and collections are keyed by id, so they stay with the new files.
        var replacedIDs: [String] = []
        var failures: [String] = []
        var cancelled = false
        /// Folders whose name is not a Workshop id but whose manifest names the item they are
        /// a copy of: folder name to item id. They are filed under that id.
        var recognizedWorkshopIDs: [String: String] = [:]
    }

    struct ImportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "webm", "mkv", "avi"]
    static let webExtensions: Set<String> = ["html", "htm"]
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "avif",
    ]
    /// Pictures a web view shows as they are. Any other format is shown from a JPEG copy, so a
    /// wallpaper never depends on which formats this macOS release's WebKit happens to decode.
    static let webImageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp"]
    /// A picture is read into memory whole to measure and scale it.
    static let maximumImageBytes = 512 * 1024 * 1024
    /// Library ids of imported pictures start with this, so the panel can tell a still image
    /// it packaged from a web wallpaper someone wrote.
    static let imageIDPrefix = "image-"
    nonisolated static let stagingPrefix = ".WallpaperMachine-import-"
    nonisolated static let stagingOwnerName = ".owner"
    nonisolated private static let stagingOwnerMarker = Data("WallpaperMachine local import v1\n".utf8)

    private let downscale: @Sendable (Data, Int) throws -> Data

    /// `downscale` re-encodes an image as a JPEG no larger than the given pixel size; the app
    /// uses the thumbnail cache's ImageIO encoder, which also proves the bytes decode.
    init(
        downscale: @escaping @Sendable (Data, Int) throws -> Data = {
            try WorkshopThumbnailCache.encodeThumbnail($0, maxPixelSize: $1)
        }
    ) {
        self.downscale = downscale
    }

    func importItems(
        _ sources: [URL], into library: URL, duplicates: DuplicatePolicy,
        progress: @Sendable (String) async -> Void
    ) async throws -> Report {
        let fm = FileManager.default
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        let managed = library.resolvingSymlinksInPath().standardizedFileURL
        // Beside the library, so publishing a finished project is a rename on one volume, and
        // outside it, so the library scan never lists a half-built import.
        let staging = Self.stagingRoot(forLibrary: library)
            .appendingPathComponent(Self.stagingPrefix + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        ClientPaths.excludeFromBackup(staging)
        let claim: Int32
        do {
            claim = try Self.claimStaging(staging)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        defer {
            close(claim)
            try? fm.removeItem(at: staging)
        }

        var report = Report()
        var seen = Set<String>()
        for source in sources {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            do {
                try Task.checkCancellation()
                for candidate in try discover(source) {
                    try Task.checkCancellation()
                    guard seen.insert(candidate.resolvingSymlinksInPath().standardizedFileURL.path).inserted else { continue }
                    let name = candidate.lastPathComponent
                    await progress(String(localized: "Importing \(name)…"))
                    do {
                        try await importCandidate(candidate, into: managed, staging: staging,
                                                  duplicates: duplicates, report: &report)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        report.failures.append("\(name): \(error.localizedDescription)")
                    }
                }
            } catch is CancellationError {
                report.cancelled = true
                break
            } catch {
                report.failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return report
    }

    /// What a candidate is, by what the chooser handed over.
    private enum CandidateKind {
        case project
        case video
        case web
        case image(String)
    }

    /// Imports one candidate into `library`, recording the outcome in `report`. Throws what stops
    /// this candidate; the caller turns that into a failure line and carries on.
    private func importCandidate(
        _ candidate: URL, into library: URL, staging: URL, duplicates: DuplicatePolicy, report: inout Report
    ) async throws {
        let fm = FileManager.default
        let name = candidate.lastPathComponent
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard !isWithin(resolved, library), !isWithin(library, resolved) else {
            throw ImportError(message: String(localized: "Choose a source outside WallpaperMachine’s managed library."))
        }

        let isDirectory = try downloadMetadata(at: candidate).st_mode & S_IFMT == S_IFDIR
        let ext = candidate.pathExtension.lowercased()
        let kind: CandidateKind
        var id = name
        if isDirectory {
            kind = .project
            if Self.workshopID(name) == nil, let inferred = inferredWorkshopID(of: candidate) {
                id = inferred
                report.recognizedWorkshopIDs[name] = inferred
                AppLog.info("import: \(name) is a copy of Workshop item \(inferred); filing it under that id")
            }
        } else if Self.imageExtensions.contains(ext) {
            kind = .image(ext)
            id = Self.imageIDPrefix + name
        } else if Self.videoExtensions.contains(ext) {
            kind = .video
            id = "local-" + name
        } else if Self.webExtensions.contains(ext) {
            kind = .web
            id = "local-" + name
        } else {
            throw ImportError(message: String(localized: "Choose a video, image, HTML file, or Wallpaper Engine project folder."))
        }
        guard !id.contains("/"), isSafeRelativePath(id) else {
            throw ImportError(message: String(localized: "The folder name cannot be used as a library identifier."))
        }

        var destination = library.appendingPathComponent(id, isDirectory: true)
        var replacing = false
        if (try? downloadMetadata(at: destination)) != nil {
            var imageExtension: String?
            if case .image(let kept) = kind { imageExtension = kept }
            switch try resolveDuplicate(duplicates, candidate: candidate, isDirectory: isDirectory,
                                        imageExtension: imageExtension, installed: destination) {
            case .skip(let identical):
                report.skipped.append(name)
                if identical { report.identical.append(name) }
                return
            case .keepBoth:
                id += "-" + UUID().uuidString
                destination = library.appendingPathComponent(id, isDirectory: true)
            case .replace:
                replacing = true
            }
        }

        let built = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        switch kind {
        case .project:
            if let preset = presetManifest(at: candidate) {
                try buildPreset(preset, from: candidate, into: built, library: library,
                                workshopID: Self.workshopID(id))
            } else {
                try validateProject(at: candidate)
                try copySafely(candidate, to: built)
            }
        case .image(let kept):
            try packageImage(candidate, extension: kept, into: built)
        case .video, .web:
            try fm.createDirectory(at: built, withIntermediateDirectories: false)
            try copySafely(candidate, to: built.appendingPathComponent(name))
            var isVideo = false
            if case .video = kind { isVideo = true }
            let manifest: [String: Any] = [
                "title": candidate.deletingPathExtension().lastPathComponent,
                "type": isVideo ? "video" : "web",
                "file": name,
                "general": ["properties": [String: Any]()],
            ]
            let data = try JSONSerialization.data(withJSONObject: manifest,
                                                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: built.appendingPathComponent("project.json"), options: .atomic)
        }

        try validateProject(at: built)
        try Task.checkCancellation()
        if replacing {
            try requireInstalledProject(destination)
            let code = Self.exchange(built, with: destination)
            guard code == 0 else { throw Self.replaceFailure(id, String(cString: strerror(code)) + ".") }
            report.replacedIDs.append(id)
            AppLog.info("import: replaced \(id) with the imported copy")
        } else {
            try fm.moveItem(at: built, to: destination)
        }
        report.importedIDs.append(id)
    }

    /// Builds a self-contained wallpaper from a preset folder and the base it names, found beside
    /// the preset or already installed. The base is copied, never changed.
    private func buildPreset(_ preset: Preset, from source: URL, into built: URL, library: URL, workshopID: String?) throws {
        let beside = source.deletingLastPathComponent().appendingPathComponent(preset.dependency, isDirectory: true)
        let installed = library.appendingPathComponent(preset.dependency, isDirectory: true)
        let base = try presetBase(of: preset, among: [beside, installed])
        try requireRegularTree(base)
        try FileManager.default.copyItem(at: base, to: built)
        try overlay(source, onto: built) { try copySafely($0, to: $1) }
        try writePresetManifest(preset, into: built, workshopID: workshopID)
    }

    /// What an import does with a candidate whose library id is already taken.
    private enum DuplicateOutcome {
        /// The installed item stays. `identical` when the candidate holds exactly the same content.
        case skip(identical: Bool)
        /// The candidate is copied under a new id beside the installed item.
        case keepBoth
        /// The candidate differs from the installed item and takes its place.
        case replace
    }

    /// Decides the fate of a candidate meeting an installed item. An installed item that is not a
    /// valid wallpaper is an error, never a reason to skip.
    private func resolveDuplicate(
        _ policy: DuplicatePolicy, candidate: URL, isDirectory: Bool, imageExtension: String?, installed: URL
    ) throws -> DuplicateOutcome {
        switch policy {
        case .skip:
            try validateProject(at: installed)
            return .skip(identical: false)
        case .keepBoth:
            // A second copy of what the library already holds only costs disk space and import time.
            guard try sameContent(candidate: candidate, installed: installed, isDirectory: isDirectory,
                                  imageExtension: imageExtension) else { return .keepBoth }
            try validateProject(at: installed)
            return .skip(identical: true)
        case .replaceChanged:
            // What the library already holds is never copied over itself.
            if try sameContent(candidate: candidate, installed: installed, isDirectory: isDirectory,
                               imageExtension: imageExtension) {
                try validateProject(at: installed)
                return .skip(identical: true)
            }
            // Refused before any byte is copied: replacing a folder that is not a wallpaper
            // would discard files that are not ours to discard.
            try requireInstalledProject(installed)
            return .replace
        }
    }

    /// Replacing needs an installed wallpaper to replace: a real folder, not a link, holding a
    /// regular `project.json`. It need not be playable, so a damaged install can be repaired.
    private func requireInstalledProject(_ installed: URL) throws {
        guard holdsProjectManifest(installed) else {
            throw Self.replaceFailure(installed.lastPathComponent, String(localized: "Its folder in the library has no project.json, so it is not an installed wallpaper."))
        }
    }

    /// Whether `folder` is a real folder, not a link, holding a regular `project.json`: the least
    /// that makes it a wallpaper's folder rather than somebody's. It need not be playable.
    private func holdsProjectManifest(_ folder: URL) -> Bool {
        guard let metadata = try? downloadMetadata(at: folder), metadata.st_mode & S_IFMT == S_IFDIR,
              let manifest = try? downloadMetadata(at: folder.appendingPathComponent("project.json")),
              manifest.st_mode & S_IFMT == S_IFREG else { return false }
        return true
    }

    nonisolated private static func replaceFailure(_ id: String, _ reason: String) -> ImportError {
        ImportError(message: String(localized: "Could not replace \(id) with the imported copy: \(reason) The installed version is unchanged."))
    }

    /// Swaps two folders in one step (`RENAME_SWAP`): `new` takes the place of `installed` and the
    /// old tree ends up at `new`'s path. 0 on success, else the `errno` that stopped it.
    nonisolated private static func exchange(_ new: URL, with installed: URL) -> Int32 {
        let result = new.path.withCString { newPath in
            installed.path.withCString { installedPath in
                renamex_np(newPath, installedPath, UInt32(RENAME_SWAP))
            }
        }
        return result == 0 ? 0 : errno
    }

    nonisolated static func stagingRoot(forLibrary library: URL) -> URL {
        library.resolvingSymlinksInPath().standardizedFileURL.deletingLastPathComponent()
    }

    /// Held across every await and copy. A second instance's startup sweep must not
    /// infer ownership from an idle-looking directory while an import is running.
    nonisolated static func claimStaging(_ staging: URL) throws -> Int32 {
        let owner = staging.appendingPathComponent(stagingOwnerName)
        let descriptor = open(owner.path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            close(descriptor)
            throw error
        }
        let written = stagingOwnerMarker.withUnsafeBytes { bytes in
            Darwin.write(descriptor, bytes.baseAddress, bytes.count)
        }
        guard written == stagingOwnerMarker.count else {
            close(descriptor)
            throw CocoaError(.fileWriteUnknown)
        }
        return descriptor
    }

    /// Claimed directories are removable only after their lock is released. Older
    /// versions wrote no claim, so those need a fully inspectable, day-old tree.
    nonisolated static func removeAbandonedStaging(in root: URL, legacyQuietFor quiet: TimeInterval = 86_400) {
        let files = FileManager.default
        guard let candidates = try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        let deadline = Date().addingTimeInterval(-max(0, quiet)).timeIntervalSince1970
        for staging in candidates where staging.lastPathComponent.hasPrefix(stagingPrefix) {
            let suffix = String(staging.lastPathComponent.dropFirst(stagingPrefix.count))
            var metadata = stat()
            guard UUID(uuidString: suffix) != nil, lstat(staging.path, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFDIR else { continue }
            let descriptor = open(staging.appendingPathComponent(stagingOwnerName).path, O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            if descriptor >= 0 {
                defer { close(descriptor) }
                var ownerInfo = stat()
                guard fstat(descriptor, &ownerInfo) == 0, ownerInfo.st_mode & S_IFMT == S_IFREG,
                      ownerInfo.st_size == stagingOwnerMarker.count else { continue }
                guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { continue }
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
                guard let marker = try? handle.read(upToCount: stagingOwnerMarker.count + 1),
                      marker == stagingOwnerMarker else { continue }
                try? files.removeItem(at: staging)
            } else if errno == ENOENT, legacyStagingIsQuiet(staging, before: deadline) {
                try? files.removeItem(at: staging)
            }
        }
    }

    nonisolated private static func legacyStagingIsQuiet(_ root: URL, before deadline: TimeInterval) -> Bool {
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0, Double(rootInfo.st_mtimespec.tv_sec) < deadline else { return false }
        var readable = true
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
            errorHandler: { _, _ in readable = false; return false }) else { return false }
        var visited = 0
        for case let file as URL in entries {
            visited += 1
            var info = stat()
            guard visited <= 200_000, lstat(file.path, &info) == 0,
                  Double(info.st_mtimespec.tv_sec) < deadline else { return false }
        }
        return readable
    }

    /// Packages one picture as a `StillImageWallpaper` in `staged`. The original keeps its bytes
    /// under a fixed name, so no file name from disk reaches the page's markup, and the title
    /// is the file's name.
    private func packageImage(_ source: URL, extension ext: String, into staged: URL) throws {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= Self.maximumImageBytes else {
            throw ImportError(message: String(localized: "Images must be regular files between 1 byte and 512 MB."))
        }
        let image = try Data(contentsOf: source, options: .mappedIfSafe)
        let unreadable = ImportError(message: String(localized: "This image could not be read. Choose a picture that opens in Preview."))
        guard let pixels = StillImageWallpaper.pixelSize(of: image) else { throw unreadable }
        let longest = max(pixels.width, pixels.height)
        let preview: Data
        var display: Data?
        do {
            preview = try downscale(image, StillImageWallpaper.previewPixels)
            if !Self.webImageExtensions.contains(ext) || longest > StillImageWallpaper.displayPixels {
                display = try downscale(image, min(longest, StillImageWallpaper.displayPixels))
            }
        } catch {
            throw unreadable
        }
        try Task.checkCancellation()
        let fm = FileManager.default
        try fm.createDirectory(at: staged, withIntermediateDirectories: false)
        let imageFile = "image.\(ext)"
        try image.write(to: staged.appendingPathComponent(imageFile))
        try preview.write(to: staged.appendingPathComponent(StillImageWallpaper.previewFile))
        if let display { try display.write(to: staged.appendingPathComponent(StillImageWallpaper.displayFile)) }
        let fit = StillImageWallpaper.Fit.preferred(width: pixels.width, height: pixels.height)
        try Data(StillImageWallpaper.page(showing: display == nil ? imageFile : StillImageWallpaper.displayFile, fit: fit).utf8)
            .write(to: staged.appendingPathComponent(StillImageWallpaper.entryFile))
        let manifest: [String: Any] = [
            "title": source.deletingPathExtension().lastPathComponent,
            "type": "web",
            "file": StillImageWallpaper.entryFile,
            "preview": StillImageWallpaper.previewFile,
            "general": ["properties": StillImageWallpaper.properties(fit: fit)],
            "image": ["file": imageFile, "width": pixels.width, "height": pixels.height],
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: staged.appendingPathComponent("project.json"), options: .atomic)
    }

    /// Consumes a complete item from disposable Steam staging without copying payload bytes.
    /// A valid existing item is left untouched unless `replacing`, when the new tree takes its
    /// place, and then so is a damaged one that still holds its `project.json`; the caller remains
    /// responsible for staging cleanup.
    ///
    /// A Workshop preset is assembled first: its base's content, the preset's own files on top,
    /// and the base's manifest carrying the preset's title and property values. The base comes
    /// from the same staging (see `presetBaseToDownload`) or, failing that, from the library.
    func importDownloadedItem(_ itemID: String, from staging: URL, into library: URL, replacing: Bool = false) throws {
        try Task.checkCancellation()
        guard Self.workshopID(itemID) != nil else {
            throw ImportError(message: String(localized: "Choose a valid numeric Workshop item identifier."))
        }
        let fm = FileManager.default
        let stagingRoot = staging.standardizedFileURL
        let canonicalStaging = stagingRoot.resolvingSymlinksInPath().standardizedFileURL
        var managedRoot = library.resolvingSymlinksInPath().standardizedFileURL
        guard !isWithin(canonicalStaging, managedRoot), !isWithin(managedRoot, canonicalStaging) else {
            throw ImportError(message: String(localized: "Download staging must be outside the managed library."))
        }

        var source = try downloadedItemFolder(itemID, in: stagingRoot)
        if let preset = presetManifest(at: source) {
            source = try assembleDownloadedPreset(itemID, preset: preset, at: source, staging: stagingRoot, library: library)
        }
        try validateDownloadedProject(at: source)
        try Task.checkCancellation()
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        managedRoot = library.resolvingSymlinksInPath().standardizedFileURL
        guard !isWithin(canonicalStaging, managedRoot), !isWithin(managedRoot, canonicalStaging) else {
            throw ImportError(message: String(localized: "Download staging must be outside the managed library."))
        }
        let destination = managedRoot.appendingPathComponent(itemID, isDirectory: true)
        try Task.checkCancellation()
        if replacing, let installed = try? downloadMetadata(at: destination), installed.st_mode & S_IFMT == S_IFDIR {
            // Only an installed wallpaper is replaced: the old tree ends up in staging, which the
            // caller clears, so a folder that is not one is left where it is. A damaged one, such as
            // a copy missing its entry file, still is: replacing is how it gets repaired.
            guard holdsProjectManifest(destination) else {
                throw ImportError(message: String(localized: "The library’s folder for Workshop item \(itemID) holds no project.json, so it is not an installed wallpaper and the new copy was not put in its place. Move the folder out of the library and download the item again."))
            }
            // An update swaps the new tree in and the old one out in one step, so the library never
            // lacks the wallpaper and a failure leaves the old version where it was.
            let code = Self.exchange(source, with: destination)
            guard code == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
                    NSFilePathErrorKey: destination.path,
                    NSLocalizedDescriptionKey: String(localized: "Could not replace Workshop item \(itemID) with its update: \(String(cString: strerror(code))). The installed version is unchanged.")
                ])
            }
            return
        }
        // Unlike moveItem, this cannot fall back to a cross-volume copy. RENAME_EXCL
        // atomically refuses even a destination created after our validation.
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else {
            let code = errno
            if code == EEXIST {
                try validateDownloadedProject(at: destination)
                try Task.checkCancellation()
                return
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
                NSFilePathErrorKey: destination.path,
                NSLocalizedDescriptionKey: String(localized: "Could not publish Workshop item \(itemID): \(String(cString: strerror(code))). Download staging and the library must be on the same volume.")
            ])
        }
    }

    /// The Workshop item a downloaded preset is built on, when neither the download's own staging
    /// nor the library already holds it; nil for an ordinary wallpaper. The downloader fetches it
    /// into the same staging before `importDownloadedItem` assembles the preset.
    func presetBaseToDownload(_ itemID: String, in staging: URL, library: URL) throws -> String? {
        try Task.checkCancellation()
        guard Self.workshopID(itemID) != nil else {
            throw ImportError(message: String(localized: "Choose a valid numeric Workshop item identifier."))
        }
        let stagingRoot = staging.standardizedFileURL
        guard let preset = presetManifest(at: try downloadedItemFolder(itemID, in: stagingRoot)) else { return nil }
        guard preset.dependency != itemID else {
            throw ImportError(message: String(localized: "This preset names itself as the wallpaper it is based on, so it cannot be used."))
        }
        let staged = Self.downloadedContent(in: stagingRoot).appendingPathComponent(preset.dependency, isDirectory: true)
        if (try? downloadMetadata(at: staged)) != nil { return nil }
        let installed = library.resolvingSymlinksInPath().standardizedFileURL
            .appendingPathComponent(preset.dependency, isDirectory: true)
        if (try? requireDownloadDirectory(installed)) != nil, (try? validateProject(at: installed)) != nil { return nil }
        return preset.dependency
    }

    /// A Workshop preset: no wallpaper `type`, only the Workshop item it is `dependency` on and,
    /// under `preset`, values for that item's properties.
    private struct Preset {
        let manifest: [String: Any]
        let dependency: String
    }

    nonisolated static func workshopID(_ value: Any?) -> String? {
        let text: String
        if let string = value as? String {
            text = string
        } else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.int64Value > 0 {
            text = number.stringValue
        } else {
            return nil
        }
        guard !text.isEmpty, text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let id = UInt64(text), id > 0 else { return nil }
        return text
    }

    private static func downloadedContent(in staging: URL) -> URL {
        staging.appendingPathComponent("steamapps/workshop/content/431960", isDirectory: true)
    }

    /// Checks each fixed ancestor before descending: resolving the final path alone would
    /// silently accept a Steam content directory redirected through a symbolic link.
    private func downloadedItemFolder(_ itemID: String, in staging: URL) throws -> URL {
        var source = staging
        try requireDownloadDirectory(source)
        for component in ["steamapps", "workshop", "content", "431960", itemID] {
            try Task.checkCancellation()
            source.appendPathComponent(component, isDirectory: true)
            try requireDownloadDirectory(source)
        }
        return source
    }

    /// The preset described by `root/project.json`, or nil when it is anything else; ordinary
    /// validation then reports what is wrong with it.
    private func presetManifest(at root: URL) -> Preset? {
        guard let manifest = readManifest(at: root),
              ((manifest["type"] as? String) ?? "").isEmpty,
              let dependency = Self.workshopID(manifest["dependency"]) else { return nil }
        return Preset(manifest: manifest, dependency: dependency)
    }

    /// The JSON object in `root/project.json`, or nil unless that is a regular file (not a link)
    /// of at most 16 MB without a byte-order mark. Import validation still insists on UTF-8.
    private func readManifest(at root: URL) -> [String: Any]? {
        let url = root.appendingPathComponent("project.json")
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) <= 16 * 1024 * 1024,
              let data = try? Data(contentsOf: url), !data.starts(with: [0xEF, 0xBB, 0xBF]) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The Workshop item a project folder belongs to although its name is not the id: the
    /// manifest's `workshopid`, else the item its `workshopurl` points at. Only a whole positive
    /// number counts. The folder name is not consulted (a title like "2077" is not an id), and a
    /// manifest naming nothing usable leaves the folder name as the library id.
    private func inferredWorkshopID(of folder: URL) -> String? {
        guard let manifest = readManifest(at: folder) else { return nil }
        // A fraction, an exponent (`1e3`) or a number too large for 64 bits is a measurement, not an identifier.
        let isMeasurement = (manifest["workshopid"] as? NSNumber).map { ["f", "d"].contains(String(cString: $0.objCType)) } ?? false
        if !isMeasurement, let id = Self.workshopID(manifest["workshopid"]) { return id }
        guard let link = manifest["workshopurl"] as? String else { return nil }
        return Self.workshopItemID(inLink: link)
    }

    /// The item a Workshop link names: `steam://url/CommunityFilePage/<id>`, a Steam Community
    /// `filedetails` page (`?id=<id>`), or a `steam://openurl/` wrapper around one.
    nonisolated static func workshopItemID(inLink link: String) -> String? {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        let wrapper = "steam://openurl/"
        if text.lowercased().hasPrefix(wrapper) { return workshopItemID(inLink: String(text.dropFirst(wrapper.count))) }
        guard let components = URLComponents(string: text), let host = components.host?.lowercased() else { return nil }
        switch components.scheme?.lowercased() {
        case "steam":
            let parts = components.path.split(separator: "/", omittingEmptySubsequences: true)
            guard host == "url", parts.count == 2, parts[0].lowercased() == "communityfilepage" else { return nil }
            return workshopID(String(parts[1]))
        case "http", "https":
            guard host == "steamcommunity.com" || host == "www.steamcommunity.com",
                  components.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "sharedfiles/filedetails",
                  let ids = components.queryItems?.filter({ $0.name == "id" }), ids.count == 1 else { return nil }
            return workshopID(ids[0].value)
        default:
            return nil
        }
    }

    /// The first candidate folder holding an installable wallpaper to build the preset on.
    private func presetBase(of preset: Preset, among candidates: [URL]) throws -> URL {
        for base in candidates {
            try Task.checkCancellation()
            guard let metadata = try? downloadMetadata(at: base), metadata.st_mode & S_IFMT == S_IFDIR else { continue }
            if presetManifest(at: base) != nil {
                throw ImportError(message: String(localized: "This preset is based on another preset (Workshop item \(preset.dependency)). Presets of presets are not supported."))
            }
            try validateProject(at: base)
            return base
        }
        throw ImportError(message: String(localized: "This preset is based on Workshop item \(preset.dependency), which is not in your library. Download or import that wallpaper first, then try again."))
    }

    /// Builds the downloaded preset in staging. A base downloaded alongside it is moved, one from
    /// the library is cloned, and the preset's own files are moved over it.
    private func assembleDownloadedPreset(_ itemID: String, preset: Preset, at source: URL, staging: URL, library: URL) throws -> URL {
        guard preset.dependency != itemID else {
            throw ImportError(message: String(localized: "This preset names itself as the wallpaper it is based on, so it cannot be used."))
        }
        try requireRegularTree(source)
        let staged = Self.downloadedContent(in: staging).appendingPathComponent(preset.dependency, isDirectory: true)
        let installed = library.resolvingSymlinksInPath().standardizedFileURL
            .appendingPathComponent(preset.dependency, isDirectory: true)
        let base = try presetBase(of: preset, among: [staged, installed])
        try requireRegularTree(base)
        let fm = FileManager.default
        let built = staging.appendingPathComponent("preset-\(UUID().uuidString)", isDirectory: true)
        if base == staged {
            try fm.moveItem(at: base, to: built)
        } else {
            // On APFS this clones the files rather than duplicating their bytes.
            try fm.copyItem(at: base, to: built)
        }
        try requireRegularTree(built)
        try overlay(source, onto: built) { try fm.moveItem(at: $0, to: $1) }
        try writePresetManifest(preset, into: built, workshopID: itemID)
        return built
    }

    /// Places every file of the preset over the base, replacing what is there; the preset's own
    /// manifest is merged separately.
    private func overlay(_ preset: URL, onto base: URL, root: Bool = true, transfer: (URL, URL) throws -> Void) throws {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        for child in try fm.contentsOfDirectory(at: preset, includingPropertiesForKeys: keys) {
            try Task.checkCancellation()
            if root && child.lastPathComponent == "project.json" { continue }
            let target = base.appendingPathComponent(child.lastPathComponent)
            let values = try child.resourceValues(forKeys: Set(keys))
            let existing = try? downloadMetadata(at: target)
            if values.isDirectory == true, values.isSymbolicLink != true, let existing, existing.st_mode & S_IFMT == S_IFDIR {
                try overlay(child, onto: target, root: false, transfer: transfer)
                continue
            }
            if existing != nil { try fm.removeItem(at: target) }
            try transfer(child, target)
        }
    }

    /// Rewrites the base's manifest in `built` as the preset's: its title, description, tags,
    /// rating and preview, its Workshop id, and its values for the base's properties.
    private func writePresetManifest(_ preset: Preset, into built: URL, workshopID: String?) throws {
        let url = built.appendingPathComponent("project.json")
        guard var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw ImportError(message: String(localized: "project.json must describe a scene, video, or web wallpaper."))
        }
        for key in ["title", "description", "tags", "contentrating"] {
            if let value = preset.manifest[key], !(value is NSNull) { manifest[key] = value }
        }
        if let preview = preset.manifest["preview"] as? String, isSafeRelativePath(preview),
           (try? built.appendingPathComponent(preview).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            manifest["preview"] = preview
        }
        // The base's Workshop identity must not follow it into the preset.
        manifest.removeValue(forKey: "workshopurl")
        manifest["workshopid"] = workshopID ?? Self.workshopID(preset.manifest["workshopid"])
        manifest["dependency"] = preset.dependency
        if let values = preset.manifest["preset"] as? [String: Any],
           var general = manifest["general"] as? [String: Any],
           var properties = general["properties"] as? [String: Any] {
            // Only properties the base declares take a value; nulls are the preset's group headings.
            for (name, value) in values where !(value is NSNull) {
                guard var property = properties[name] as? [String: Any] else { continue }
                property["value"] = value
                properties[name] = property
            }
            general["properties"] = properties
            manifest["general"] = general
        }
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    private func downloadMetadata(at url: URL) throws -> stat {
        var metadata = stat()
        // URL directory representations can include a trailing slash, which makes
        // lstat follow a final symlink. URL.path removes that directory marker.
        let result = url.path.withCString { lstat($0, &metadata) }
        guard result == 0 else {
            let code = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
        }
        return metadata
    }

    private func requireDownloadDirectory(_ url: URL) throws {
        let metadata = try downloadMetadata(at: url)
        guard metadata.st_mode & S_IFMT == S_IFDIR else {
            throw ImportError(message: String(localized: "Download directories must be real folders, not symbolic links or special files: \(url.lastPathComponent)."))
        }
    }

    private func validateDownloadedProject(at root: URL) throws {
        try requireRegularTree(root)
        try Task.checkCancellation()
        try validateProject(at: root, requireNonemptyContent: true)
    }

    private func requireRegularTree(_ root: URL) throws {
        try requireDownloadDirectory(root)
        var pending = [root]
        while let next = pending.popLast() {
            try Task.checkCancellation()
            let metadata = try downloadMetadata(at: next)
            switch metadata.st_mode & S_IFMT {
            case S_IFDIR:
                pending.append(contentsOf: try FileManager.default.contentsOfDirectory(at: next, includingPropertiesForKeys: nil))
            case S_IFREG:
                break
            default:
                throw ImportError(message: String(localized: "Downloaded projects may contain only regular files and folders, not symbolic links or special files: \(next.lastPathComponent)."))
            }
        }
    }

    /// Folders, relative to a chosen one, whose children can be projects: Workshop downloads in a
    /// Steam library, and the `projects` folders of a Wallpaper Engine install, which a user may
    /// pick as the library, as `steamapps`, `common`, the install itself, or a copy of it from
    /// another computer.
    private static let projectRoots: [String] = {
        let workshop = ["", "steamapps/workshop/content/431960", "workshop/content/431960", "content/431960", "431960"]
        let installs = ["steamapps/common/wallpaper_engine", "common/wallpaper_engine", "wallpaper_engine", "Wallpaper Engine", ""]
        let projectFolders = ["projects/myprojects", "projects/defaultprojects"]
        let installed = installs.flatMap { install in
            projectFolders.map { folder in install.isEmpty ? folder : install + "/" + folder }
        }
        // The projects folder itself, or one of its two halves.
        return workshop + installed + ["myprojects", "defaultprojects"]
    }()

    private func discover(_ source: URL) throws -> [URL] {
        let metadata = try downloadMetadata(at: source)
        guard metadata.st_mode & S_IFMT != S_IFLNK else {
            throw ImportError(message: String(localized: "Symbolic links are not imported. Choose the original folder or file instead."))
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR else { return [projectFolder(ofFile: source) ?? source] }
        if holdsProjectManifest(source) { return [source] }

        let fm = FileManager.default
        let chosen = source.resolvingSymlinksInPath().standardizedFileURL
        var found: [URL] = []
        var known = Set<String>()
        for relative in Self.projectRoots {
            try Task.checkCancellation()
            let root = (relative.isEmpty ? source : source.appendingPathComponent(relative, isDirectory: true))
                .resolvingSymlinksInPath().standardizedFileURL
            guard isWithin(root, chosen),
                  let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                             options: [.skipsHiddenFiles]) else { continue }
            for child in children where holdsProjectManifest(child) && known.insert(child.path).inserted {
                found.append(child)
            }
        }
        guard !found.isEmpty else {
            throw ImportError(message: String(localized: "No project.json found. Choose a wallpaper project, a folder containing projects, a Steam library or a Wallpaper Engine folder."))
        }
        return found.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// The project a chosen file belongs to: its own folder, when the file is the manifest, the
    /// scene description or a package, and the folder holds a project manifest. Links are never
    /// followed, neither the file nor the folder, so this is as strict as choosing the folder.
    private func projectFolder(ofFile file: URL) -> URL? {
        let name = file.lastPathComponent.lowercased()
        guard name == "project.json" || name == "scene.json" || file.pathExtension.lowercased() == "pkg",
              let metadata = try? downloadMetadata(at: file), metadata.st_mode & S_IFMT == S_IFREG else { return nil }
        let folder = URL(fileURLWithPath: file.deletingLastPathComponent().path, isDirectory: true)
        return holdsProjectManifest(folder) ? folder : nil
    }

    private func validateProject(at root: URL, requireNonemptyContent: Bool = false) throws {
        let describe = String(localized: "project.json must describe a scene, video, or web wallpaper.")
        let manifestURL = root.appendingPathComponent("project.json")
        guard let info = try? downloadMetadata(at: manifestURL), info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= 16 * 1024 * 1024, let data = try? Data(contentsOf: manifestURL) else {
            throw ImportError(message: String(localized: "project.json must be a regular JSON file smaller than 16 MB."))
        }
        guard !data.starts(with: [0xEF, 0xBB, 0xBF]), String(data: data, encoding: .utf8) != nil else {
            throw ImportError(message: String(localized: "project.json must use UTF-8 encoding without a byte-order mark. Convert the manifest and import it again."))
        }
        guard let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = (manifest["type"] as? String)?.lowercased(),
              ["scene", "video", "web"].contains(type) else { throw ImportError(message: describe) }

        var entry = ""
        if let declared = manifest["file"] {
            guard let text = declared as? String else { throw ImportError(message: describe) }
            entry = text
        }
        if entry.isEmpty {
            guard type == "scene" else { throw ImportError(message: describe) }
            entry = "scene.json"
        }
        guard isSafeRelativePath(entry) else {
            throw ImportError(message: String(localized: "The wallpaper entry file is outside its project folder."))
        }

        func isRegularContent(_ relative: String) -> Bool {
            guard let metadata = try? downloadMetadata(at: root.appendingPathComponent(relative)),
                  metadata.st_mode & S_IFMT == S_IFREG else { return false }
            return !requireNonemptyContent || metadata.st_size > 0
        }
        var present = isRegularContent(entry)
        if !present, type == "scene" {
            present = isRegularContent((entry as NSString).deletingPathExtension + ".pkg")
        }
        guard present else {
            throw ImportError(message: String(localized: "Missing project content: \(entry). Copy the complete wallpaper folder, not just project.json."))
        }
        if let preview = manifest["preview"] as? String, !isSafeRelativePath(preview) {
            throw ImportError(message: String(localized: "The preview path must remain inside the wallpaper folder."))
        }
        if let dependencies = manifest["dependencies"] as? [Any],
           dependencies.contains(where: { ($0 as? String).map { !isSafeRelativePath($0) } ?? false }) {
            throw ImportError(message: String(localized: "Project dependency paths may not escape their folder."))
        }
    }

    private func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"),
              !path.utf8.contains(0) else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false)
            .contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    private func isWithin(_ child: URL, _ parent: URL) -> Bool {
        child.path == parent.path || child.path.hasPrefix(parent.path.hasSuffix("/") ? parent.path : parent.path + "/")
    }

    private func copySafely(_ source: URL, to destination: URL) throws {
        try Task.checkCancellation()
        let metadata = try downloadMetadata(at: source)
        switch metadata.st_mode & S_IFMT {
        case S_IFLNK:
            throw ImportError(message: String(localized: "Symbolic links are not imported: \(source.lastPathComponent). Copy the original content into the project folder first."))
        case S_IFDIR:
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            for child in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                try copySafely(child, to: destination.appendingPathComponent(child.lastPathComponent))
            }
        case S_IFREG:
            try copyFile(source, to: destination)
        default:
            throw ImportError(message: String(localized: "Unsupported special file: \(source.lastPathComponent). Only regular files and folders can be imported."))
        }
    }

    /// Streams one regular file in 1 MiB chunks, checking for cancellation between them, and
    /// flushes it to disk before returning.
    private func copyFile(_ source: URL, to destination: URL) throws {
        let input = open(source.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard input >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(input) }
        let output = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o644)
        guard output >= 0 else {
            throw ImportError(message: String(localized: "Could not create \(destination.lastPathComponent). Check available disk space and folder permissions."))
        }
        defer { close(output) }
        let chunk = Self.comparisonChunk
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(input, buffer, chunk)
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if count == 0 { break }
            var written = 0
            while written < count {
                let step = Darwin.write(output, buffer + written, count - written)
                if step < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                written += step
            }
        }
        guard fsync(output) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    // MARK: Identical content

    /// Entries of one tree a comparison lists before it gives up and calls the trees different.
    private static let comparisonEntryLimit = 200_000
    private static let comparisonChunk = 1024 * 1024

    private struct TreeEntry: Equatable {
        let isDirectory: Bool
        let size: Int64
    }

    /// Whether the library item at `installed` is exactly what importing `candidate` would copy
    /// into it, byte for byte. A folder must hold the same folders and files, of the same sizes,
    /// with the same content. `.DS_Store` files are ignored on both sides: Finder adds them, and
    /// no wallpaper reads them. So is the top-level `.mwe-user-assets` folder, the bridge the app
    /// itself writes into an installed web wallpaper when the user picks a file or folder for one
    /// of its properties: derived and regenerable, never part of what a project ships. A single
    /// file is compared with the copy of it the item keeps (the file itself, or `image.<ext>` for
    /// a picture).
    ///
    /// Anything doubtful counts as different: a link or special file, a tree too large to list, a
    /// file that cannot be opened or that changes while it is read. The worst outcome is then the
    /// old behaviour, a second copy; a project is never skipped on a guess. Reading stops at the
    /// first difference. Throws only `CancellationError`, between chunks.
    private func sameContent(candidate: URL, installed: URL, isDirectory: Bool, imageExtension: String?) throws -> Bool {
        guard let installedInfo = try? downloadMetadata(at: installed), installedInfo.st_mode & S_IFMT == S_IFDIR else { return false }
        let left = UnsafeMutableRawPointer.allocate(byteCount: Self.comparisonChunk, alignment: 16)
        let right = UnsafeMutableRawPointer.allocate(byteCount: Self.comparisonChunk, alignment: 16)
        defer { left.deallocate(); right.deallocate() }
        guard isDirectory else {
            let kept = imageExtension.map { "image.\($0)" } ?? candidate.lastPathComponent
            return try Self.sameBytes(candidate.path, installed.appendingPathComponent(kept).path, left, right)
        }
        // The cheap check first: the same names and sizes, before a single byte is read.
        guard let wanted = try Self.treeListing(candidate), let held = try Self.treeListing(installed),
              wanted == held else { return false }
        let files = wanted.filter { !$0.value.isDirectory }.keys.sorted()
        // The manifest is the file most likely to differ and the quickest to read.
        for relative in files.filter({ $0 == "project.json" }) + files.filter({ $0 != "project.json" }) {
            guard try Self.sameBytes(candidate.path + "/" + relative, installed.path + "/" + relative, left, right) else { return false }
        }
        return true
    }

    /// Every file and folder below `root` by relative path, or nil when the tree holds anything
    /// but regular files and folders (`.DS_Store` files and the app's own top-level user-asset
    /// bridge aside), more than `comparisonEntryLimit` entries, or something that cannot be read.
    private static func treeListing(_ root: URL) throws -> [String: TreeEntry]? {
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        var listing: [String: TreeEntry] = [:]
        var pending = [""]
        while let relative = pending.popLast() {
            let folder = relative.isEmpty ? root.path : root.path + "/" + relative
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return nil }
            for name in names {
                try Task.checkCancellation()
                var entry = stat()
                guard lstat(folder + "/" + name, &entry) == 0 else { return nil }
                let path = relative.isEmpty ? name : relative + "/" + name
                switch entry.st_mode & S_IFMT {
                case S_IFDIR:
                    if relative.isEmpty && name == UserAssetStore.stagingDirectoryName { continue }
                    listing[path] = TreeEntry(isDirectory: true, size: 0)
                    pending.append(path)
                case S_IFREG:
                    if name == ".DS_Store" { continue }
                    listing[path] = TreeEntry(isDirectory: false, size: Int64(entry.st_size))
                default:
                    return nil
                }
                if listing.count > comparisonEntryLimit { return nil }
            }
        }
        return listing
    }

    /// Whether two regular files, neither a link, hold the same bytes. The buffers are
    /// `comparisonChunk` bytes each.
    private static func sameBytes(_ first: String, _ second: String,
                                  _ firstBuffer: UnsafeMutableRawPointer, _ secondBuffer: UnsafeMutableRawPointer) throws -> Bool {
        let left = open(first, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard left >= 0 else { return false }
        defer { close(left) }
        let right = open(second, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard right >= 0 else { return false }
        defer { close(right) }
        var leftInfo = stat()
        var rightInfo = stat()
        guard fstat(left, &leftInfo) == 0, fstat(right, &rightInfo) == 0,
              leftInfo.st_mode & S_IFMT == S_IFREG, rightInfo.st_mode & S_IFMT == S_IFREG,
              leftInfo.st_size == rightInfo.st_size else { return false }
        var remaining = Int64(leftInfo.st_size)
        while true {
            try Task.checkCancellation()
            let count = fill(firstBuffer, from: left)
            guard count >= 0, count == fill(secondBuffer, from: right),
                  memcmp(firstBuffer, secondBuffer, count) == 0 else { return false }
            // The size read must be the size the file had when it was opened.
            if count == 0 { return remaining == 0 }
            remaining -= Int64(count)
        }
    }

    /// Reads up to a chunk, more than once if the file system returns less. -1 on a read error.
    private static func fill(_ buffer: UnsafeMutableRawPointer, from descriptor: Int32) -> Int {
        var filled = 0
        while filled < comparisonChunk {
            let count = Darwin.read(descriptor, buffer + filled, comparisonChunk - filled)
            if count < 0 {
                if errno == EINTR { continue }
                return -1
            }
            if count == 0 { break }
            filled += count
        }
        return filled
    }
}
