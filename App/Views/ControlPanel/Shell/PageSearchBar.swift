import AppKit
import SwiftUI

/// The search bar of the pages that have one (Installed, Steam Workshop and pixiv): a full-width
/// field at the top of the page, above its own row of tools, owned by the detail column rather
/// than by each page.
///
/// It used to be the window's toolbar search item, which AppKit puts in the toolbar's trailing
/// corner, above the inspector, where it was easy to miss. Here it is the first thing on the page,
/// where the grid it searches starts. It stays one field across the pages and only changes its
/// text, prompt and Return action. Settings searches in the same kind of field above its section
/// list (`SettingsSectionList`), at that column's width. The Workshop's field is there only while
/// the list on show is one Steam searches (an author's or a collection's wallpapers are not).
struct PageSearchBar: View {
  let selection: SidebarSelection

  @Environment(PanelController.self) private var controller

  var body: some View {
    if let field = field {
      // No minimum width of its own, like the pages under it: the inspector asks for its own, and
      // anything more makes the split view wider than the smallest window.
      PageSearchFieldView(field: field)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 2)
        .frame(minWidth: 0, maxWidth: .infinity)
    }
  }

  private var field: PageSearchFieldView.Field? {
    switch selection {
    case .wallpaper:
      let model = controller.library
      return .init(
        text: Binding(get: { model.filter.text }, set: { model.setText($0) }),
        prompt: L("Search wallpapers"), name: L("Search installed wallpapers"), submit: {})
    case .pixiv:
      let model = controller.pixivBrowser
      return .init(
        text: Binding(get: { model.draft.text }, set: { model.setText($0) }),
        prompt: L("Search pixiv tags"), name: L("Search pixiv by tag"),
        submit: { model.submit() })
    case .workshop:
      // Every edit goes through the model, which tells a pasted link (searched at once) from typing
      // (searched after a pause) and a bare item id (searched on Return). Only the store's source is
      // read here, so the field is not redrawn for every change of the list.
      let source = controller.workshop.source
      guard source.isSearchable else { return nil }
      let model = controller.workshopBrowser
      return .init(
        text: Binding(get: { model.text }, set: { model.edit(text: $0) }),
        prompt: WorkshopSearchTrigger.invitesLink(for: source)
          ? L("Search Workshop or paste a link") : L("Search Workshop"),
        name: L("Search Steam Workshop"), submit: { model.search() })
    case .settings:
      return nil
    }
  }
}

/// An `NSSearchField`, so the page's field is what Command-F finds (`PanelSearchFocus`) and reads
/// to VoiceOver as a search field. Typing reaches the model with every change; Return submits.
struct PageSearchFieldView: NSViewRepresentable {
  struct Field {
    var text: Binding<String>
    var prompt: String
    /// What VoiceOver calls the field, which says more than the short prompt drawn in it.
    var name: String
    var submit: () -> Void
  }

  let field: Field

  func makeCoordinator() -> Coordinator { Coordinator(field: field) }

  func makeNSView(context: Context) -> NSSearchField {
    let view = NSSearchField()
    view.controlSize = .large
    view.font = .systemFont(ofSize: NSFont.systemFontSize(for: .large))
    // The action comes on Return and on the clear button, not after every keystroke: typing is
    // followed through the delegate.
    view.sendsWholeSearchString = true
    view.delegate = context.coordinator
    view.target = context.coordinator
    view.action = #selector(Coordinator.searched(_:))
    view.setContentHuggingPriority(.defaultLow, for: .horizontal)
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    view.setAccessibilityIdentifier("page-search-field")
    return view
  }

  func updateNSView(_ view: NSSearchField, context: Context) {
    context.coordinator.field = field
    let text = field.text.wrappedValue
    if view.stringValue != text { view.stringValue = text }
    if view.placeholderString != field.prompt { view.placeholderString = field.prompt }
    if view.accessibilityLabel() != field.name { view.setAccessibilityLabel(field.name) }
    view.isEnabled = context.environment.isEnabled
  }

  /// As wide as it is offered and no wider than that asks: a minimum width of its own would make
  /// the split view wider than the smallest window with the inspector open, and AppKit then loops
  /// over the constraints and throws.
  func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSSearchField, context: Context)
    -> CGSize?
  {
    CGSize(width: proposal.width ?? 0, height: view.intrinsicContentSize.height)
  }

  final class Coordinator: NSObject, NSSearchFieldDelegate {
    var field: Field

    init(field: Field) { self.field = field }

    func controlTextDidChange(_ note: Notification) {
      guard let view = note.object as? NSSearchField else { return }
      changed(to: view.stringValue)
    }

    /// Return, or the clear button.
    @objc func searched(_ sender: NSSearchField) {
      changed(to: sender.stringValue)
    }

    func control(
      _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
    ) -> Bool {
      guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
      changed(to: control.stringValue)
      field.submit()
      return true
    }

    private func changed(to text: String) {
      if field.text.wrappedValue != text { field.text.wrappedValue = text }
    }
  }
}
