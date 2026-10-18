import SwiftUI

/// A page or a list with nothing to show yet, and what to do about it. Built on
/// `ContentUnavailableView`, so it centres itself and follows the system's type and spacing.
struct PanelEmptyState<Actions: View>: View {
  private let title: Text
  private let systemImage: String
  private let detail: Text?
  private let actions: Actions
  private var selectsText = false

  /// For fixed wording, which is looked up in the catalog.
  init(
    _ title: LocalizedStringKey, systemImage: String, description: LocalizedStringKey? = nil,
    @ViewBuilder actions: () -> Actions
  ) {
    self.title = Text(title)
    self.systemImage = systemImage
    detail = description.map { Text($0) }
    self.actions = actions()
  }

  /// For wording that is not a catalog key: a name from the library, a message from a service.
  init(
    verbatim title: String, systemImage: String, description: String? = nil,
    @ViewBuilder actions: () -> Actions
  ) {
    self.title = Text(verbatim: title)
    self.systemImage = systemImage
    detail = description.map { Text(verbatim: $0) }
    self.actions = actions()
  }

  /// Lets the title and the description be selected and copied, as an empty state outside
  /// Settings could be in the web panel (a search term, a reason to copy into a report). The
  /// actions stay buttons.
  func textSelectable() -> Self {
    var copy = self
    copy.selectsText = true
    return copy
  }

  var body: some View {
    // `ContentUnavailableView` asks for about 260 points of width whatever it is given, which in a
    // page beside an open inspector would make the window wider than it is. Reading the width the
    // page offers and giving it back as the view's own keeps the minimum at zero.
    GeometryReader { proxy in
      ContentUnavailableView {
        Label {
          title.modifier(EmptyStateSelection(isEnabled: selectsText))
        } icon: {
          Image(systemName: systemImage)
        }
      } description: {
        detail.modifier(EmptyStateSelection(isEnabled: selectsText))
      } actions: {
        actions
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
    }
  }
}

/// `textSelection` takes a type rather than a flag, so the choice is made here.
private struct EmptyStateSelection: ViewModifier {
  let isEnabled: Bool

  func body(content: Content) -> some View {
    if isEnabled {
      content.textSelection(.enabled)
    } else {
      content.textSelection(.disabled)
    }
  }
}

extension PanelEmptyState where Actions == EmptyView {
  init(_ title: LocalizedStringKey, systemImage: String, description: LocalizedStringKey? = nil) {
    self.init(title, systemImage: systemImage, description: description) { EmptyView() }
  }

  init(verbatim title: String, systemImage: String, description: String? = nil) {
    self.init(verbatim: title, systemImage: systemImage, description: description) { EmptyView() }
  }
}
