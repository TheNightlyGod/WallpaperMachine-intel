import SwiftUI

/// Previous page, the page field with the number of pages, Go, and Next: the pager of Discover's
/// Steam list and of pixiv's listings. The field keeps only what can be a page number
/// (`ResultPager.sanitizedPageText`); Return and Go hand it to `jump`.
struct PageJumpControls: View {
  enum Style {
    /// Discover's footer: a borderless field on a fill, and Go as a link while the field names
    /// another page than the one on show.
    case inline
    /// pixiv's bar: a bordered field, and Go as a small button that drops with the "Page" label.
    case bordered
  }

  let pager: ResultPager
  @Binding var text: String
  var style = Style.inline
  /// Shows "Page" before the field. A bordered pager drops Go with it; Return still goes.
  var showsLabel = true
  /// Starts the identifiers of the controls: `<prefix>-previous-page`, `<prefix>-page-field` and
  /// `<prefix>-next-page`.
  let identifierPrefix: String
  let showPage: (Int) -> Void
  let jump: () -> Void

  @Environment(\.panelTheme) private var theme
  @FocusState private var fieldFocused: Bool

  var body: some View {
    HStack(spacing: 6) {
      Button {
        showPage(pager.previousPage)
      } label: {
        chevron("chevron.left")
      }
      .buttonStyle(.panelCapsule)
      .disabled(!pager.canGoBack)
      .help(L("Previous page"))
      .accessibilityLabel(Text("Previous page"))
      .accessibilityIdentifier("\(identifierPrefix)-previous-page")

      HStack(spacing: 6) {
        if showsLabel { Text("Page").foregroundStyle(theme.surface.muted.color) }
        field
          .disabled(!pager.canJump)
          .onSubmit(jump)
          .onChange(of: text) { _, typed in
            let digits = ResultPager.sanitizedPageText(typed)
            if digits != typed { text = digits }
          }
          .help(L("Type a page number and press Return"))
          .accessibilityLabel(Text("Page number"))
          .accessibilityIdentifier("\(identifierPrefix)-page-field")
        Text("of \(pager.pages)").foregroundStyle(theme.surface.muted.color)
        goButton
      }
      .font(.system(size: 12).monospacedDigit())
      .accessibilityElement(children: .contain)
      .accessibilityLabel(Text("Go to page"))

      Button {
        showPage(pager.nextPage)
      } label: {
        chevron("chevron.right")
      }
      .buttonStyle(.panelCapsule)
      .disabled(!pager.canGoForward)
      .help(L("Next page"))
      .accessibilityLabel(Text("Next page"))
      .accessibilityIdentifier("\(identifierPrefix)-next-page")
    }
  }

  @ViewBuilder
  private func chevron(_ symbol: String) -> some View {
    switch style {
    case .inline: Image(systemName: symbol).frame(width: 16, height: 18)
    case .bordered: Image(systemName: symbol)
    }
  }

  @ViewBuilder
  private var field: some View {
    switch style {
    case .inline:
      TextField(text: $text) { Text("Page number") }
        .labelsHidden()
        .textFieldStyle(.plain)
        .multilineTextAlignment(.center)
        .frame(width: 44, height: 22)
        .background(theme.surface.hover.color, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay {
          if fieldFocused {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
              .strokeBorder(theme.accent.focus.color, lineWidth: 2)
          }
        }
        .focused($fieldFocused)
    case .bordered:
      TextField("Page number", text: $text)
        .textFieldStyle(.roundedBorder)
        .multilineTextAlignment(.center)
        .frame(width: 52)
    }
  }

  @ViewBuilder
  private var goButton: some View {
    switch style {
    case .inline:
      if pager.canJump && text != String(pager.page) {
        Button("Go", action: jump)
          .buttonStyle(.panelLink)
          .font(.system(size: 12))
      }
    case .bordered:
      if showsLabel {
        Button("Go", action: jump).disabled(!pager.canJump)
          .controlSize(.small)
      }
    }
  }
}
