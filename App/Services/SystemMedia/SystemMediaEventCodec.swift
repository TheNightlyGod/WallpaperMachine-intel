import Foundation

/// Turns a relay event into the SceneScript JSON object official Wallpaper Engine
/// media handlers receive. The JSON is handed to the engine verbatim so optional
/// fields are not dropped by a narrower Rust model.
enum SystemMediaEventCodec {
    /// SceneScript colour vectors are 0…1. CSS `rgb(r, g, b)` is what the web
    /// relay already stores.
    static func vec3(fromCSS css: String) -> [Double] {
        let digits = css.drop { $0 != "(" }.dropFirst().prefix { $0 != ")" }
        let parts = digits.split(separator: ",").compactMap {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        guard parts.count == 3 else { return [0, 0, 0] }
        return parts.map { min(max($0 / 255, 0), 1) }
    }

    /// SceneScript numbers playback as Wallpaper Engine's `MediaPlaybackEvent`
    /// does: stopped 0, playing 1, paused 2. Scripts compare `event.state` with
    /// those numbers as often as with the named constants.
    static func sceneScriptPlaybackState(_ state: SystemMediaPlaybackState) -> Int {
        switch state {
        case .stopped: 0
        case .playing: 1
        case .paused: 2
        }
    }

    static func json(for event: WebWallpaperMediaRelay.Event) -> String? {
        let object: [String: Any]
        switch event {
        case let .status(enabled):
            object = ["type": "mediaStatusChanged", "enabled": enabled]
        case let .properties(properties):
            object = [
                "type": "mediaPropertiesChanged",
                "title": properties.title,
                "artist": properties.artist,
                "subTitle": properties.subTitle,
                "albumTitle": properties.albumTitle,
                "albumArtist": properties.albumArtist,
                "genres": properties.genres,
                "contentType": properties.contentType,
            ]
        case let .thumbnail(thumbnail):
            object = [
                "type": "mediaThumbnailChanged",
                "hasThumbnail": !thumbnail.isEmpty,
                "primaryColor": vec3(fromCSS: thumbnail.primaryColor),
                "secondaryColor": vec3(fromCSS: thumbnail.secondaryColor),
                "tertiaryColor": vec3(fromCSS: thumbnail.tertiaryColor),
                "textColor": vec3(fromCSS: thumbnail.textColor),
                "highContrastColor": vec3(fromCSS: thumbnail.highContrastColor),
            ]
        case let .playback(state):
            object = ["type": "mediaPlaybackChanged", "state": sceneScriptPlaybackState(state)]
        case let .timeline(timeline):
            object = [
                "type": "mediaTimelineChanged",
                "position": timeline.position,
                "duration": timeline.duration,
            ]
        }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        return json
    }
}
