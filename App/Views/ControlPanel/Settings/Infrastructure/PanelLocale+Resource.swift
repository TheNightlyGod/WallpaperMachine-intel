import Foundation

extension PanelLocale {
  /// A phrase declared as a `LocalizedStringResource`, in the panel's language rather than the
  /// language the app launched in. Settings declare their rows' words as resources, so they can be
  /// searched and shown in whatever language the panel is in.
  ///
  /// A resource is a key plus the values to fill into it; its own bundle and locale are the ones
  /// the app launched with, so only the key and the values are used.
  func string(resolving resource: LocalizedStringResource) -> String {
    String(localized: resource.defaultValue, table: resource.table, bundle: bundle, locale: locale)
  }
}
