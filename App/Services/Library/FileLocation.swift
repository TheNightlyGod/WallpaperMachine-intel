import Foundation

/// Path identity that `URL` equality does not give: it also compares directory hints and trailing slashes.
enum FileLocation {
    nonisolated static func isSame(_ first: URL, _ second: URL) -> Bool {
        first.resolvingSymlinksInPath().standardizedFileURL.path
            == second.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
