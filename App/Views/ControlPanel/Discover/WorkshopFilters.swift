import SwiftUI

/// The Workshop's Filters sidebar: the boxes Wallpaper Engine's own sidebar offers, in the groups it
/// groups them in.
///
/// Each change searches at once. "Show only" boxes require a tag; the Tags chips start plain and a
/// click selects one (`FilterTagChip`); every other box is ticked unless it hides what carries its
/// tag, so a fresh sidebar filters nothing. A group's
/// title carries how many of its boxes differ from their defaults, the header carries the total,
/// and Clear puts the defaults back.
struct WorkshopFilters: View {
  @Environment(PanelController.self) private var controller

  var body: some View {
    let model = controller.workshopBrowser
    FilterPanel(count: model.filterCount, onClear: { model.clearFilters() }) {
      showOnly(model)
      ForEach(WorkshopFilterCatalog.groups) { group in
        FilterGroup(
          group.title, count: model.filters.count(in: group),
          isExpanded: Binding(
            get: { !model.isFolded(group.id) }, set: { model.setFolded(group.id, !$0) })
        ) {
          // A disclosure centres a block that is narrower than it: the block takes the width.
          VStack(alignment: .leading, spacing: 8) {
            ForEach(group.sections) { section in
              SectionView(section: section, model: model)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .accessibilityIdentifier("workshop-filters")
  }

  /// "Show only": the boxes that require a tag, and any other tag that is required.
  private func showOnly(_ model: WorkshopBrowserModel) -> some View {
    FilterGroup(
      "Show only", count: model.filters.requiredCount,
      isExpanded: Binding(
        get: { !model.isFolded("show-only") }, set: { model.setFolded("show-only", !$0) })
    ) {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(WorkshopFilterCatalog.showOnly) { entry in
          Toggle(
            isOn: Binding(
              get: { model.filters.isRequired(entry.tag) },
              set: { model.setRequired(entry.tag, $0) })
          ) {
            Label {
              Text(entry.name)
            } icon: {
              Image(systemName: entry.systemImage)
                .foregroundStyle(entry.tag == "Approved" ? Color.green : Color.secondary)
            }
          }
          .toggleStyle(.checkbox)
        }
        let others = model.filters.otherRequiredTags
        if !others.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            Text("Other selected tags")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(.secondary)
              .padding(.top, 4)
            ForEach(others, id: \.self) { tag in
              Toggle(
                isOn: Binding(
                  get: { model.filters.isRequired(tag) }, set: { model.setRequired(tag, $0) })
              ) {
                // A tag restored from somewhere else is Steam's own word, not a catalog key.
                Text(verbatim: tag)
              }
              .toggleStyle(.checkbox)
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  /// One section of a group: an optional heading with **All** and **None**, then its boxes.
  private struct SectionView: View {
    let section: WorkshopFilterCatalog.Section
    let model: WorkshopBrowserModel

    @Environment(\.panelTheme) private var theme

    var body: some View {
      VStack(alignment: .leading, spacing: 6) {
        if section.title != nil || section.hasQuickLinks { heading }
        switch section.style {
        case .checkboxes:
          ForEach(section.entries) { entry in
            Toggle(
              isOn: Binding(
                get: { model.filters.isIncluded(entry.tag) },
                set: { model.setIncluded(entry.tag, $0) })
            ) {
              entry.name.text
            }
            .toggleStyle(.checkbox)
          }
        case .chips:
          TagFlow(spacing: 6) {
            ForEach(section.entries) { entry in
              FilterTagChip(
                selection: model.filters.chipSelection(entry.tag),
                onChange: { model.setChip(entry.tag, $0) }
              ) {
                entry.name.text
              }
            }
          }
        }
      }
      .padding(.vertical, 2)
    }

    private var heading: some View {
      HStack {
        if let title = section.title {
          Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.surface.muted.color)
        }
        Spacer(minLength: 8)
        if section.style == .chips {
          Button("Reset") { model.resetChips(in: section) }
            .disabled(model.filters.chipsAreAtDefaults(in: section))
            .buttonStyle(.panelLink)
            .font(.system(size: 11.5))
        } else if section.hasQuickLinks {
          HStack(spacing: 10) {
            Button("All") { model.includeAll(in: section) }
              .disabled(model.filters.includesAll(in: section))
            Button("None") { model.excludeAll(in: section) }
              .disabled(model.filters.includesNone(in: section))
          }
          .buttonStyle(.panelLink)
          .font(.system(size: 11.5))
        }
      }
    }
  }
}
