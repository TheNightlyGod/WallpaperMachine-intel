import SwiftUI

/// The strip under the grid: what is on show on the left, and the pager on the right, each only
/// while it has something to say (`WorkshopFooterContent`).
///
/// A list is 30 tiles a page and at most 1,000 pages, which is Steam's own limit. Previous and Next
/// move one page; the number field takes any page, which is rounded and kept within the pages there
/// are; a page that fails to load says so here with Retry, and the tiles already on show stay.
struct WorkshopFooter: View {
  let density: WorkshopHeaderDensity
  let content: WorkshopFooterContent

  @Environment(PanelController.self) private var controller

  var body: some View {
    let browse = controller.workshopBrowse
    // Beside an open inspector in the smallest window the pager has no room for the summary.
    let layout = density == .compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
      : AnyLayout(HStackLayout(spacing: 12))
    layout {
      if content.showsSummary {
        WorkshopSummaryLine(browse: browse)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        Spacer(minLength: 0)
      }
      if content.showsPager {
        WorkshopPager(pager: browse.pager, showsLabel: density != .compact)
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, density == .compact ? 8 : 0)
    .frame(minHeight: 44)
  }
}

/// The summary: how many results, or what is happening, with a link to the same list on Steam. A
/// failed load that left tiles on show says why and offers Retry instead.
struct WorkshopSummaryLine: View {
  let browse: WorkshopBrowseState

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let model = controller.workshopBrowser
    if let message = browse.errorMessage, !browse.items.isEmpty {
      HStack(spacing: 8) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(theme.surface.danger.color)
          .accessibilityHidden(true)
        Text(verbatim: message)
          .foregroundStyle(theme.surface.danger.color)
          .lineLimit(2)
        Button("Retry") { model.retry() }
          .buttonStyle(.panelLink)
      }
      .font(.system(size: 12))
    } else {
      let summary = WorkshopSummary.make(browse: browse)
      HStack(spacing: 10) {
        line(summary)
          .font(.system(size: 12))
          .foregroundStyle(theme.surface.muted.color)
          .lineLimit(2)
          .accessibilityAddTraits(.updatesFrequently)
        if browse.hasLoaded, !browse.isLoading {
          Button {
            model.openOnSteam()
          } label: {
            Label("Open on Steam", systemImage: "arrow.up.right.square")
          }
          .buttonStyle(.panelLink)
          .font(.system(size: 12))
          .labelStyle(.titleAndIcon)
        }
      }
    }
  }

  @ViewBuilder
  private func line(_ summary: WorkshopSummary) -> some View {
    switch summary {
    case .searching:
      Text("Searching Steam Workshop…")
    case .subscriptions:
      EmptyView()
    case .lookup:
      Text("Showing the item from your link. Filters don’t apply to it.")
    case .degraded:
      Text("Steam changed its Workshop page, so this list may be incomplete.")
    case .results(let count):
      Text("\(count) results")
    case .idle:
      Text("Steam Workshop")
    }
  }
}

/// Previous, the page number with the number of pages, and Next.
struct WorkshopPager: View {
  let pager: ResultPager
  var showsLabel = true

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @FocusState private var fieldFocused: Bool

  var body: some View {
    @Bindable var model = controller.workshopBrowser
    let canJump = pager.canJump
    HStack(spacing: 6) {
      Button {
        model.showPage(pager.previousPage)
      } label: {
        Image(systemName: "chevron.left").frame(width: 16, height: 18)
      }
      .buttonStyle(.panelCapsule)
      .disabled(!pager.canGoBack)
      .help(L("Previous page"))
      .accessibilityLabel(Text("Previous page"))
      .accessibilityIdentifier("workshop-previous-page")

      if showsLabel {
        Text("Page")
          .font(.system(size: 12))
          .foregroundStyle(theme.surface.muted.color)
      }
      TextField(text: $model.pageText) { Text("Page number") }
        .labelsHidden()
        .textFieldStyle(.plain)
        .multilineTextAlignment(.center)
        .font(.system(size: 12).monospacedDigit())
        .frame(width: 44, height: 22)
        .background(theme.surface.hover.color, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay {
          if fieldFocused {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
              .strokeBorder(theme.accent.focus.color, lineWidth: 2)
          }
        }
        .focused($fieldFocused)
        .disabled(!canJump)
        .onSubmit { model.jump() }
        .onChange(of: model.pageText) {
          // Only digits make a page number, and no page has more than four.
          let digits = String(model.pageText.filter { ("0"..."9").contains($0) }.prefix(5))
          if digits != model.pageText { model.pageText = digits }
        }
        .help(L("Type a page number and press Return"))
        .accessibilityLabel(Text("Page number"))
        .accessibilityIdentifier("workshop-page-field")
      Text("of \(pager.pages)")
        .font(.system(size: 12).monospacedDigit())
        .foregroundStyle(theme.surface.muted.color)
      if canJump && model.pageText != String(pager.page) {
        Button("Go") { model.jump() }
          .buttonStyle(.panelLink)
          .font(.system(size: 12))
      }

      Button {
        model.showPage(pager.nextPage)
      } label: {
        Image(systemName: "chevron.right").frame(width: 16, height: 18)
      }
      .buttonStyle(.panelCapsule)
      .disabled(!pager.canGoForward)
      .help(L("Next page"))
      .accessibilityLabel(Text("Next page"))
      .accessibilityIdentifier("workshop-next-page")
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("Go to page"))
  }
}
