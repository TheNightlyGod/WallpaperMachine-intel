import Foundation

/// A Workshop item named by what the user pasted: its web page, a `steam://` link or its bare id.
/// Links are read as URLs, never by a pattern over free text, so a sentence that merely holds
/// digits or a link is still a search.
enum WorkshopLink {
    /// A bare number names an item from this many digits on, so a short number such as a year
    /// is still searched for.
    static let minimumBareDigits = 6

    /// The item `text` names: a bare id or a link to the item. Nil for anything else.
    static func itemID(in text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.utf8.count >= minimumBareDigits, text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) {
            return canonical(text)
        }
        return itemID(inLink: text)
    }

    /// The item a link names; a bare id is not a link. Accepted are the Workshop page on
    /// steamcommunity.com (`/sharedfiles/filedetails` or `/workshop/filedetails`, with an `id`)
    /// and `steam://url/CommunityFilePage/<id>`.
    static func itemID(inLink text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 2048, !text.contains(where: \.isWhitespace),
              let link = URLComponents(string: text), link.user == nil, link.password == nil, link.port == nil,
              let scheme = link.scheme?.lowercased(), let host = link.host?.lowercased() else { return nil }
        // Empty segments are dropped, so a trailing slash does not matter.
        let path = link.path.split(separator: "/").map { $0.lowercased() }
        switch scheme {
        case "https", "http":
            guard host == "steamcommunity.com" || host == "www.steamcommunity.com",
                  path == ["sharedfiles", "filedetails"] || path == ["workshop", "filedetails"] else { return nil }
            return (link.queryItems ?? []).first { $0.name == "id" }?.value.flatMap(canonical)
        case "steam":
            guard host == "url", path.count == 2, path[0] == "communityfilepage" else { return nil }
            return canonical(path[1])
        default:
            return nil
        }
    }

    /// A Workshop id as Steam writes it: digits only, above zero, without leading zeros.
    private static func canonical(_ digits: String) -> String? {
        WallpaperImportService.workshopID(digits).flatMap { UInt64($0) }.map(String.init)
    }
}
