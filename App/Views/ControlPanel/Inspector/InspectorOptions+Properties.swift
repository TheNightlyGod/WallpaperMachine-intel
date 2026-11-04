import Foundation

extension InspectorOptions {
  /// One authored property: how to draw its control, what it is called, and whether it differs from
  /// what the wallpaper is using.
  struct PropertyRow: Equatable, Identifiable {
    enum Control: Equatable {
      case toggle(isOn: Bool)
      /// A slider. `step` is nil when the author gave none (any value); `precision` is how many
      /// decimals the author means the value to carry, which the web panel did not use.
      case slider(Slider)
      /// A pop-up of the author's choices. `selection` is the choice the current value matches, and
      /// nil when it matches none: show no selection, and never change the value on its own.
      case choice(selection: BridgePropertyValue?, choices: [Choice])
      case color(red: Double, green: Double, blue: Double)
      case text(String)
      /// A scene's image picker: the path of the picked image, empty for none. The picker stores
      /// the path, not a copy.
      case image(path: String)
      case file(PathState)
      case folder(PathState, Folder)
      /// A description record; `detail` is its value when that adds words to the label.
      case description(detail: String?)
      /// A heading that names the controls after it.
      case heading

      /// Whether this is a chosen file or folder, which keeps its own Clear.
      var isChosenPath: Bool {
        switch self {
        case .file, .folder: true
        default: false
        }
      }
    }

    struct Slider: Equatable {
      let value: Double
      let minimum: Double
      let maximum: Double
      let step: Double?
      let precision: Int
    }

    struct Choice: Equatable, Identifiable {
      /// The choice's place in the author's list: two choices may carry the same value.
      let id: Int
      let label: String
      let value: BridgePropertyValue
    }

    /// A chosen file or folder, reduced to what the row shows. Names and paths are
    /// attacker-influenced: show them with `Text(verbatim:)`.
    struct PathState: Equatable {
      /// The chosen item's own name; nil when nothing is chosen. The staged path the wallpaper
      /// reads is never shown.
      let name: String?
      /// The extensions the property accepts, sorted.
      let acceptedTypes: [String]
      /// Why choosing failed (a staging obstacle), shown beside this control and not in the banner.
      let error: String?
      /// The app keeps its own copy (true), or the wallpaper reads the file where it is (false).
      let isManaged: Bool
      /// A chosen item that is no longer there; reselect it.
      let isMissing: Bool
      /// The user's original pick, for recognising an external reference.
      let sourcePath: String?

      var isChosen: Bool { name != nil }
    }

    struct Folder: Equatable {
      enum Delivery: Equatable {
        /// The wallpaper receives the whole list of files.
        case wholeList
        /// The wallpaper picks files from the folder itself.
        case onDemand
      }
      let delivery: Delivery
      /// Files the import would take; nil when the folder could not be read, which is unknown and
      /// not zero.
      let fileCount: Int?
      let fileLimit: Int
      /// The folder holds more than `fileLimit` matching files; the first `fileLimit` are used.
      let isTruncated: Bool
    }

    let id: String
    let control: Control
    /// What names the control: the label's words, or "Unnamed option" for a label that is pure
    /// decoration. Never the editor's id.
    let name: String
    let label: PropertyLabels.Presentation
    /// The bridge reports the value as changed, or there is a draft or a value on its way.
    let isModified: Bool
    /// The bridge reports this property as changed (not counting the panel's own overlay).
    let isDirty: Bool
    /// The author gave a default, so Restore default is offered.
    let canRestoreDefault: Bool
  }
}
