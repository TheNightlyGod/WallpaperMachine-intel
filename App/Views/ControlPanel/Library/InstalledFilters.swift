import SwiftUI

/// The Filters sidebar of the Installed page: the collections, one of which can be on show, the tags
/// a wallpaper must have (Show only), the boxes whose unticking hides every wallpaper that carries
/// the tag, and the Tags chips, which a click selects (`FilterTagChip`).
/// Nothing is sent anywhere: the grid narrows as the boxes change.
struct InstalledFilters: View {
  @Environment(PanelController.self) private var controller

  var body: some View {
    let model = controller.library
    FilterPanel(count: model.filterCount, onClear: { model.clearFilters() }) {
      CollectionsFilterGroup(isExpanded: expansion("collections"))
      FilterGroup(
        "Show only",
        count: model.filter.requiredTags.filter { !LibraryFilterCatalog.chipTags.contains($0) }.count,
        isExpanded: expansion("show-only")
      ) {
        ForEach(LibraryFilterCatalog.showOnly) { entry in
          RequiredTagToggle(entry: entry)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        let others = model.filter.requiredTags.filter { tag in
          !LibraryFilterCatalog.showOnly.contains { $0.tag == tag }
            && !LibraryFilterCatalog.chipTags.contains(tag)
        }
        if !others.isEmpty {
          Text("Other selected tags")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
          TagFlow(spacing: 6) {
            ForEach(others, id: \.self) { tag in
              Button { model.setRequired(tag, false) } label: {
                TagChip(text: tag, selection: .required)
              }
              .buttonStyle(.plain)
              .accessibilityLabel(Text(verbatim: tag))
              .accessibilityAddTraits(.isSelected)
            }
          }
        }
      }
      ForEach(LibraryFilterCatalog.installedGroups) { group in
        FilterGroup(
          group.title, count: model.filter.count(among: group.tags),
          isExpanded: expansion(group.key)
        ) {
          ForEach(group.sections) { section in
            ExclusionSection(section: section)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
    }
    .accessibilityIdentifier("installed-filters")
  }

  private func expansion(_ key: String) -> Binding<Bool> {
    let model = controller.library
    return Binding(
      get: { model.openFilterGroups.contains(key) },
      set: { isOpen in
        if isOpen { model.openFilterGroups.insert(key) } else { model.openFilterGroups.remove(key) }
      })
  }
}

/// A "Show only" box: ticking it requires the tag.
private struct RequiredTagToggle: View {
  let entry: LibraryFilterCatalog.RequiredTag

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let model = controller.library
    Toggle(
      isOn: Binding(
        get: { model.filter.requiredTags.contains(entry.tag) },
        set: { model.setRequired(entry.tag, $0) })
    ) {
      Label {
        entry.label
      } icon: {
        Image(systemName: entry.symbol)
          .foregroundStyle(
            entry.tag == LibraryFilterCatalog.approvedTag
              ? theme.surface.approved.color : Color.secondary)
          .frame(width: 16)
      }
    }
    .toggleStyle(.checkbox)
    .font(.system(size: 13))
  }
}

/// One section of a group: an optional heading with All and None, then a box to a line; or the Tags
/// chips under a Reset link.
private struct ExclusionSection: View {
  let section: LibraryFilterCatalog.Section

  @Environment(PanelController.self) private var controller

  var body: some View {
    let model = controller.library
    VStack(alignment: .leading, spacing: 6) {
      if section.title != nil || section.hasQuickLinks { heading(model) }
      if section.isChips {
        TagFlow(spacing: 6) {
          ForEach(section.entries) { entry in
            FilterTagChip(
              selection: model.chipSelection(entry.tag),
              onChange: { model.setChip(entry.tag, $0) }
            ) {
              entry.label
            }
          }
        }
      } else {
        ForEach(section.entries) { entry in
          Toggle(
            isOn: Binding(
              get: { model.isIncluded(entry.tag) }, set: { model.setIncluded(entry.tag, $0) })
          ) {
            entry.label
          }
          .toggleStyle(.checkbox)
          .font(.system(size: 13))
        }
      }
    }
    .padding(.bottom, 4)
  }

  private func heading(_ model: InstalledBrowserModel) -> some View {
    HStack(spacing: 10) {
      if let title = section.title {
        title.font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      if section.isChips {
        Button("Reset") { model.resetChips(in: section) }
          .disabled(model.chipsAreAtDefaults(in: section))
      } else if section.hasQuickLinks {
        let included = model.includedCount(in: section)
        Button("All") { model.setSection(section.key, included: true) }
          .disabled(included == section.entries.count)
        Button("None") { model.setSection(section.key, included: false) }
          .disabled(included == 0)
      }
    }
    .buttonStyle(.link)
    .font(.system(size: 12))
  }
}
