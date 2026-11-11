import Foundation

struct WallpaperPreviewFailure: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// An immutable copy of the inspector's current values, never a desktop assignment.
struct WallpaperPreviewRequest: Equatable, Sendable {
    enum Kind: String, Sendable { case scene, video, web }
    let wallpaperID: String
    let title: String
    let kind: Kind
    let projectURL: URL
    let entryFile: String
    let assetsURL: URL
    var propertiesJSON: String
    /// The properties a running preview cannot change in place: a picture or a file is read
    /// when the wallpaper loads. A preview holds them at the values it started with.
    var frozenPropertyIDs: Set<String> = []
    let fps: UInt32
    let scalingMode: Int32
    var scalingFactor: Double
    let volume: Float
    /// Wallpaper Engine's per-wallpaper options with the draft in them; nil for a web page.
    let engineOptions: WallpaperEngineOptions?
    /// The saved scene quality, for a scene preview.
    let sceneQuality: SceneQualitySettings

    init(_ input: BridgeWallpaperPreview) throws {
        switch input.kind {
        case .projectScene: kind = .scene
        case .video: kind = .video
        case .webpage: kind = .web
        case .unknown:
            throw WallpaperPreviewFailure(message: String(localized: "This wallpaper type cannot be previewed."))
        }
        wallpaperID = input.wallpaperId
        title = input.title
        projectURL = URL(fileURLWithPath: input.projectPath, isDirectory: true)
        entryFile = input.entryFile
        assetsURL = URL(fileURLWithPath: input.assetsPath, isDirectory: true)
        propertiesJSON = input.propertiesJson
        fps = min(30, max(1, input.fps))
        scalingMode = input.scalingMode.rendererValue
        scalingFactor = input.scalingFactor
        volume = input.volume
        engineOptions = input.engineOptions.map(WallpaperEngineOptions.init)
        sceneQuality = SceneQualitySettings(input.sceneQuality)
    }
}

/// Checks preview inputs without loading a renderer or reading outside the installed project.
actor WallpaperPreviewLoader {
    private let libraryURL: URL

    init(libraryURL: URL = ClientPaths.libraryURL) { self.libraryURL = libraryURL }

    func validate(_ request: WallpaperPreviewRequest) throws -> WallpaperPreviewRequest {
        try Task.checkCancellation()
        let id = request.wallpaperID
        let library = libraryURL.resolvingSymlinksInPath().standardizedFileURL
        let root = request.projectURL.resolvingSymlinksInPath().standardizedFileURL
        let expected = library.appendingPathComponent(id, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        guard !id.isEmpty, id != ".", id != "..", !id.contains("/"), !id.contains("\\"), !id.contains("\0"),
              root == expected, Self.contains(root, in: library),
              request.scalingFactor.isFinite, request.scalingFactor > 0, request.volume.isFinite,
              (0...1).contains(request.volume), request.propertiesJSON.utf8.count <= 8 * 1024 * 1024,
              let properties = request.propertiesJSON.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: properties)) is [String: Any]
        else { throw WallpaperPreviewFailure(message: String(localized: "The preview inputs are invalid. Refresh the library and try again.")) }
        let manifest = root.appendingPathComponent("project.json")
        guard Self.readableFile(manifest), Self.contains(manifest.resolvingSymlinksInPath(), in: root),
              let size = try manifest.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 8 * 1024 * 1024,
              let project = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any],
              (project["type"] as? String)?.lowercased() == request.kind.rawValue,
              (project["file"] as? String ?? "") == request.entryFile
        else { throw WallpaperPreviewFailure(message: String(localized: "The wallpaper files changed or are missing. Refresh the library before previewing.")) }
        let entry = root.appendingPathComponent(request.entryFile).resolvingSymlinksInPath()
        guard !request.entryFile.hasPrefix("/"), !request.entryFile.contains("\0"),
              !request.entryFile.isEmpty, Self.contains(entry, in: root),
              Self.readableFile(entry) || (request.kind == .scene && Self.readableFile(root.appendingPathComponent("scene.pkg")))
        else { throw WallpaperPreviewFailure(message: String(localized: "The preview entry file is missing or outside this wallpaper folder.")) }
        if request.kind == .scene, !ClientPaths.hasSceneAssets(at: request.assetsURL) {
            throw WallpaperPreviewFailure(message: String(localized: "Install Wallpaper Engine’s shared scene resources before previewing a scene wallpaper."))
        }
        try Task.checkCancellation()
        return request
    }

    private static func readableFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            && FileManager.default.isReadableFile(atPath: url.path)
    }

    private static func contains(_ url: URL, in root: URL) -> Bool {
        let base = root.pathComponents, path = url.standardizedFileURL.pathComponents
        return path.count > base.count && Array(path.prefix(base.count)) == base
    }
}

extension BridgeScalingMode {
    /// The renderer's own number for the mode, as `owe_property_scaling_mode` takes it and the
    /// lock-screen configuration carries it.
    var rendererValue: Int32 {
        switch self {
        case .none: 0
        case .stretch: 1
        case .match: 2
        case .fill: 3
        case .matchBlurred: 4
        }
    }
}
