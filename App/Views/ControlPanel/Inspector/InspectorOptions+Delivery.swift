import Foundation

extension InspectorOptions {
  /// What the panel can say about audio and media reaching a wallpaper. Three claims stay apart for
  /// both: what the user switched on, whether anything is delivered, and whether the panel can tell
  /// at all. "Cannot tell" and "available" are both naturally an absent value, so each has a case
  /// of its own.
  struct DeliveryReport: Equatable {
    enum Audio: Equatable {
      /// No host is running for web wallpapers: nothing was observed.
      case unknown
      /// A host is running but has nothing for this wallpaper.
      case inactive
      /// The wallpaper never asked for audio.
      case idle
      case connecting
      /// Subscribed; the first audio frame has not arrived.
      case subscribed
      /// A confirmed audio frame reached the wallpaper.
      case delivering
      case failed
    }

    enum Media: Equatable {
      case unknown
      case available
      /// The system cannot say what is playing; `reason` is its own words, if it gave any.
      case unavailable(reason: String?)
    }

    /// How far the Volume control reaches into a web page, and whether Mute silences all of it.
    struct WebOutput: Equatable {
      enum Volume: Equatable {
        /// Volume sets the audio and video the page plays through media elements.
        case mediaElements
        case unavailable
        case unknown
      }
      enum Mute: Equatable {
        /// Mute silences the whole page, Web Audio included.
        case available
        case unavailable
        case unknown
      }
      let volume: Volume
      let mute: Mute
    }

    let audio: Audio
    let media: Media
    /// Present for web wallpapers only.
    let webOutput: WebOutput?

    /// What the report says with no running host.
    static let unobserved = DeliveryReport(audio: .unknown, media: .unknown, webOutput: nil)

    /// Only a running host can say whether anything is delivered. A scene wallpaper's media comes
    /// from the system's own availability instead of the host's.
    static func make(
      kind: BridgeWallpaperKind, wallpaperID: String, host: WebWallpaperHost.DeliveryStatus?,
      sceneMedia: SystemMediaAvailability?
    ) -> DeliveryReport {
      var audio = Audio.unknown
      var media = Media.unknown
      if let host {
        if let state = host.audioStates[wallpaperID] {
          switch state {
          case .idle: audio = .idle
          case .failed: audio = .failed
          case .connecting: audio = .connecting
          case .subscribed: audio = .subscribed
          case .delivering: audio = .delivering
          }
        } else {
          audio = .inactive
        }
        media = host.mediaUnavailableReason.map { .unavailable(reason: $0) } ?? .available
      }
      if kind == .projectScene, let sceneMedia {
        switch sceneMedia {
        case .available: media = .available
        case .unavailable(let reason): media = .unavailable(reason: reason)
        }
      }
      var webOutput: WebOutput?
      if kind == .webpage {
        let controls = host?.audioOutputControls[wallpaperID]
        webOutput = WebOutput(
          volume: controls.map { $0.mediaVolume ? .mediaElements : .unavailable } ?? .unknown,
          mute: controls.map { $0.pageMute ? .available : .unavailable } ?? .unknown)
      }
      return DeliveryReport(audio: audio, media: media, webOutput: webOutput)
    }
  }
}
