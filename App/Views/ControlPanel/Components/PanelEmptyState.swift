import SwiftUI

/// A page or a list with nothing to show yet, and what to do about it. Built on
/// `ContentUnavailableView`, so it centres itself and follows the system's type and spacing.
struct PanelEmptyState<Actions: View>: View {
  private let title: Text
  private let systemImage: String
  private let detail: Text?
  private let actions: Actions
  private var selectsText = false
  private var art: SeasonalArt?

  @Environment(\.panelTheme) private var theme

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

  /// Lets a seasonal look draw its picture of `art` in place of the symbol while it is on. Only for
  /// a state that means "nothing here"; an error keeps its symbol whatever the season.
  func seasonalArt(_ art: SeasonalArt) -> Self {
    var copy = self
    copy.art = art
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
          if let art, let season = theme.season {
            SeasonalArtwork(name: art.imageName(in: season))
          } else {
            Image(systemName: systemImage)
          }
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

/// What an empty state is about, for a season to draw a picture of.
enum SeasonalArt {
  /// Nothing in the library yet.
  case emptyLibrary
  /// A search or filters that match nothing.
  case noResults

  /// The asset catalog image set of the silhouette in `season`.
  func imageName(in season: Season) -> String {
    switch (season, self) {
    case (.halloween, .emptyLibrary): "HalloweenFrame"
    case (.halloween, .noResults): "HalloweenCat"
    }
  }
}

/// A papercut cameo: the season's silhouette on a strip of ground in front of the full moon, cut out
/// in a ring of the horizon's ink. The moon carries it on either appearance.
private struct SeasonalArtwork: View {
  let name: String

  var body: some View {
    let ink = SeasonHorizon.ink.color
    ZStack(alignment: .bottom) {
      SeasonHorizon.moon.color
      ink.frame(height: 22)
      Image(name)
        .resizable()
        .interpolation(.high)
        .scaledToFit()
        .frame(height: 96)
        .padding(.bottom, 16)
    }
    .frame(width: 132, height: 132)
    .clipShape(Circle())
    .padding(4)
    .overlay { Circle().strokeBorder(ink, lineWidth: 2) }
    .background {
      Circle()
        .fill(
          RadialGradient(
            colors: [SeasonHorizon.moon.color.opacity(0.3), SeasonHorizon.moon.color.opacity(0)],
            center: .center, startRadius: 66, endRadius: 100))
        .frame(width: 200, height: 200)
    }
    .accessibilityHidden(true)
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
