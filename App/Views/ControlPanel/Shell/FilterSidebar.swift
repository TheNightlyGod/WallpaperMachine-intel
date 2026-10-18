import SwiftUI

/// The Filters sidebar: a floating column at the leading edge of the page, holding the filters of
/// the page on show. `PanelDetail` slides it out from the window's leading edge and back; the page
/// beside it narrows to make room.
struct FilterSidebar: View {
  /// The column's width: room for the groups' rows and a few tag chips to a line.
  static let width: CGFloat = 260
  /// The gap it floats in.
  static let inset: CGFloat = 8

  let selection: SidebarSelection

  var body: some View {
    filters
      .frame(
        minWidth: 0, idealWidth: Self.width, maxWidth: Self.width, maxHeight: .infinity,
        alignment: .top)
      .modifier(FloatingSidebarBackground())
      .padding([.leading, .bottom], Self.inset)
      .padding(.top, Self.inset / 2)
      // The page has no minimum width of its own, and the column asks for none either: it takes
      // its width first and the page the rest, so the detail never asks the split view for more
      // than the window has (AppKit would loop on "needing another Update Constraints pass").
      .layoutPriority(1)
      .accessibilityElement(children: .contain)
      .accessibilityLabel(Text("Filters"))
      .accessibilityIdentifier("filters-sidebar")
  }

  @ViewBuilder
  private var filters: some View {
    switch selection {
    case .wallpaper: InstalledFilters()
    case .workshop: WorkshopFilters()
    case .pixiv: PixivFilters()
    case .settings: EmptyView()
    }
  }
}

/// A system sidebar's look: a floating glass panel from macOS 26, a material panel before.
private struct FloatingSidebarBackground: ViewModifier {
  private static let cornerRadius: CGFloat = 16

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
    if #available(macOS 26.0, *) {
      content.clipShape(shape).glassEffect(.regular, in: shape)
    } else {
      content.clipShape(shape).background(.regularMaterial, in: shape)
    }
  }
}
