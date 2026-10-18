import SwiftUI

/// A titled group of rows in the inspector, styled as an inset grouped form: Display, Audio,
/// Properties, Presets and the like.
struct InspectorCard<Content: View>: View {
  private let title: Text?
  private let content: Content

  @Environment(\.panelTheme) private var theme

  init(_ title: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
    self.title = title.map { Text($0) }
    self.content = content()
  }

  init(verbatim title: String, @ViewBuilder content: () -> Content) {
    self.title = Text(verbatim: title)
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let title {
        title
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(theme.surface.muted.color)
          .padding(.leading, 12)
          .accessibilityAddTraits(.isHeader)
      }
      PanelCard { content }
    }
  }
}

/// One row of an `InspectorCard`: a label on the leading side and its control or value trailing,
/// at least 36 points high.
struct InspectorRow<Label: View, Trailing: View>: View {
  private let label: Label
  private let trailing: Trailing

  init(@ViewBuilder trailing: () -> Trailing, @ViewBuilder label: () -> Label) {
    self.label = label()
    self.trailing = trailing()
  }

  var body: some View {
    HStack(spacing: 12) {
      label
        .font(.system(size: 13))
        .frame(maxWidth: .infinity, alignment: .leading)
      trailing
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 4)
    .frame(minHeight: 36)
  }
}

extension InspectorRow where Label == Text {
  /// A row named by fixed wording.
  init(_ title: LocalizedStringKey, @ViewBuilder trailing: () -> Trailing) {
    self.init(trailing: trailing) { Text(title) }
  }

  /// A row named by text that is not a catalog key.
  init(verbatim title: String, @ViewBuilder trailing: () -> Trailing) {
    self.init(trailing: trailing) { Text(verbatim: title) }
  }
}
