import Foundation

/// A `file` or `directory` property's chosen path, reduced to what the inspector shows.
///
/// `matches` and `truncated` describe a folder: how many files inside it the importer would
/// take, and whether it holds more than the import limit. Both are nil / false for a single
/// file, and `matches` stays nil for a folder that could not be read, which is an unknown
/// count and never an empty folder.
struct PanelPropertyAsset: Equatable {
  let path: String
  let name: String
  var matches: Int?
  var truncated = false
}
