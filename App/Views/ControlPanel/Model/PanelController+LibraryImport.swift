import AppKit
import Foundation
import UniformTypeIdentifiers

/// Answers the import picker for a test: the files it chose, or nil for Cancel.
typealias ImportFileChooser = @MainActor (NSWindow, [UTType]) async throws -> [URL]?

/// Importing wallpapers from files and folders into the library.
extension PanelController {
  /// What the import picker offers: folders and a project's own files, which stand for its folder
  /// (`project.json`, `scene.json`, `scene.pkg`), and every video, web and image type.
  static var importContentTypes: [UTType] {
    [.folder, .json]
      + WallpaperImportService.videoExtensions.union(WallpaperImportService.webExtensions)
      .union(WallpaperImportService.imageExtensions).union(["pkg"]).sorted()
      .compactMap { UTType(filenameExtension: $0) }
  }

  /// `import`: asks for files and folders in a sheet (in the panel's language, through the picker's
  /// helper process when macOS's differs) and starts the import with `duplicates` deciding what an
  /// installed wallpaper of the same name becomes. A cancelled pick starts nothing, and so does a
  /// panel with no window. The import runs in the app's own store, so closing the panel never
  /// cancels it.
  ///
  /// Queued, as it always was: the sheet holds the command queue while it is open.
  func beginImport(duplicates: WallpaperImportService.DuplicatePolicy = .skip) async throws {
    try await run(.queued) {
      guard !imports.isBusy, !importPicker.isPresenting else {
        throw WallpaperActionError(message: L("An import is already running."))
      }
      guard let window = dialogs.presentingWindow else { return }
      let types = Self.importContentTypes
      let urls: [URL]?
      if let chooseImportFiles {
        urls = try await chooseImportFiles(window, types)
      } else {
        urls = try await importPicker.choose(
          for: window, language: appLanguage.effective.tag, allowedContentTypes: types)
      }
      guard let urls, !isStopped else { return }
      try imports.start(urls, duplicates: duplicates)
    }
  }

  /// `importCancel`: stops the running import, which then reports what it had done.
  func cancelImport() { imports.cancel() }
}
