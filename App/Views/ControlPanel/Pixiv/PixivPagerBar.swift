import SwiftUI

/// The bar under the grid: what the listing is, and previous, a page field with Go, and next.
/// When a later page failed to load, its error and Retry lead the bar. It is a `PixivBar`: its
/// height follows the width it is given, never the other way round.
///
/// The summary is what the bar is for (how many works the filters hide is said nowhere else), so
/// the pager gives it room as the bar narrows: first the field drops its "Page" label and Go
/// (Return still goes), then the summary moves above the pager. It wraps to a second line rather
/// than being cut, and its tooltip carries the whole line if it still does not fit.
struct PixivPagerBar: View {
  let browse: PixivBrowseState

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @State private var width: CGFloat = 0

  /// Below this the summary sits above the pager.
  static let compactWidth: CGFloat = 520
  /// Below this the page field drops its "Page" label and Go.
  static let shortControlsWidth: CGFloat = 680

  /// How the bar lays out at a width.
  enum Layout: Equatable {
    /// The summary beside the full pager.
    case full
    /// The summary beside a pager without "Page" and Go.
    case short
    /// The summary above a pager without "Page" and Go.
    case stacked
  }

  static func layout(forWidth width: CGFloat) -> Layout {
    if width >= shortControlsWidth { return .full }
    if width >= compactWidth { return .short }
    return .stacked
  }

  /// Whether the page shows the bar: while works are on show, and while the filters hide every
  /// work of a page but there are other pages to go to. In the other empty states (loading, an
  /// error, nothing found, a single page all hidden) the page's centre says everything, and a
  /// bar of disabled controls under it would only be noise.
  static func isShown(for browse: PixivBrowseState) -> Bool {
    switch PixivEmptyState.make(browse) {
    case nil: true
    case .filtersHideAll: browse.pager.pages > 1
    case .loading, .error, .nothing: false
    }
  }

  private var showsError: Bool { browse.errorMessage != nil && !browse.works.isEmpty }
  private var layout: Layout { Self.layout(forWidth: width) }

  /// The bar's height: one row, two when it is narrow, and a line more for a failed page. A row
  /// has room for a summary of two lines.
  static func height(isCompact: Bool, showsError: Bool) -> CGFloat {
    (isCompact ? 76 : 46) + (showsError ? 40 : 0)
  }

  var body: some View {
    VStack(spacing: 0) {
      Divider()
      PixivBar(height: Self.height(isCompact: layout == .stacked, showsError: showsError)) {
        VStack(alignment: .leading, spacing: 8) {
          if showsError, let message = browse.errorMessage {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Text(verbatim: message)
                .font(.caption)
                .foregroundStyle(theme.surface.danger.color)
                .lineLimit(2)
                .help(message)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
              Button("Retry") {
                controller.launch("pixivRetry") { try await controller.pixivRetry() }
              }
              .controlSize(.small)
            }
          }
          if layout == .stacked {
            summary.frame(maxWidth: .infinity, alignment: .leading)
            PixivPageControls(pager: browse.pager, isCompact: true)
              .frame(maxWidth: .infinity, alignment: .center)
          } else {
            HStack(spacing: 12) {
              summary.frame(maxWidth: .infinity, alignment: .leading)
              PixivPageControls(pager: browse.pager, isCompact: layout == .short)
            }
          }
        }
        .padding(.horizontal, 20)
        .frame(maxHeight: .infinity, alignment: .center)
      }
      .onGeometryChange(for: CGFloat.self) {
        $0.size.width
      } action: {
        width = $0
      }
    }
    .background(theme.surface.background.color)
  }

  private var summary: some View {
    let text = PixivListSummary.make(browse).text
    return Text(verbatim: text)
      .font(.system(size: 12))
      .foregroundStyle(theme.surface.muted.color)
      .lineLimit(2)
      .truncationMode(.tail)
      .help(text)
      .accessibilityIdentifier("pixiv-summary")
  }
}

/// Previous page, the number field and Next. Compact, the field drops its "Page" label and Go.
struct PixivPageControls: View {
  let pager: ResultPager
  let isCompact: Bool

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @State private var typed = ""

  var body: some View {
    let model = controller.pixivBrowser
    HStack(spacing: 6) {
      Button {
        model.showPage(pager.previousPage)
      } label: {
        Image(systemName: "chevron.left")
      }
      .buttonStyle(.panelCapsule)
      .disabled(!pager.canGoBack)
      .help(L("Previous page"))
      .accessibilityLabel(L("Previous page"))
      .accessibilityIdentifier("pixiv-previous-page")

      HStack(spacing: 6) {
        if !isCompact { Text("Page").foregroundStyle(theme.surface.muted.color) }
        TextField("Page number", text: $typed)
          .textFieldStyle(.roundedBorder)
          .multilineTextAlignment(.center)
          .frame(width: 52)
          .disabled(!pager.canJump)
          .onSubmit(go)
          .onChange(of: typed) { _, text in
            let digits = text.filter(\.isNumber)
            if digits != text { typed = digits }
          }
          .help(L("Type a page number and press Return"))
          .accessibilityLabel(L("Page number"))
          .accessibilityIdentifier("pixiv-page-field")
        Text("of \(pager.pages)").foregroundStyle(theme.surface.muted.color)
        if !isCompact {
          Button("Go", action: go).disabled(!pager.canJump)
            .controlSize(.small)
        }
      }
      .font(.system(size: 12).monospacedDigit())
      .accessibilityElement(children: .contain)
      .accessibilityLabel(L("Go to page"))

      Button {
        model.showPage(pager.nextPage)
      } label: {
        Image(systemName: "chevron.right")
      }
      .buttonStyle(.panelCapsule)
      .disabled(!pager.canGoForward)
      .help(L("Next page"))
      .accessibilityLabel(L("Next page"))
      .accessibilityIdentifier("pixiv-next-page")
    }
    .onChange(of: pager.page, initial: true) { _, page in typed = String(page) }
  }

  private func go() {
    typed = String(controller.pixivBrowser.jump(typed: typed))
  }
}
