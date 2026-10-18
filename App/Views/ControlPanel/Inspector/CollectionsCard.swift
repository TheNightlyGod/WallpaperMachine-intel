import SwiftUI

/// Which collections the wallpaper belongs to: one switch for each collection, and a way to make a
/// new one that already holds this wallpaper. Membership changes at once and says nothing.
struct CollectionsCard: View {
  let wallpaperID: String

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @State private var isNaming = false
  @State private var name = ""
  @FocusState private var nameFocused: Bool

  private func key(_ collection: CollectionRow) -> String {
    PanelActionCoordinator.key("collectionMember", id: collection.id, detail: wallpaperID)
  }

  var body: some View {
    let rows = controller.collectionRows
    let busy = rows.contains { controller.isBusy(key($0)) }
    let createKey = PanelActionCoordinator.key("collectionNew", id: wallpaperID)
    InspectorSection(
      "Collections",
      isOpen: InspectorPolicy.collectionsOpenByDefault(rows, wallpaperID: wallpaperID)
    ) {
      if rows.isEmpty {
        InspectorCardRow {
          InspectorNote(
            "No collections yet. Collections group wallpapers for browsing and for playlists.")
        }
      } else {
        ForEach(rows) { collection in
          InspectorRow(verbatim: collection.name) {
            Toggle(
              "",
              isOn: Binding(
                get: { collection.wallpaperIDs.contains(wallpaperID) },
                set: { member in
                  controller.launch(key(collection)) {
                    if member {
                      try await controller.addToCollection(
                        collection.id, wallpaperIDs: [wallpaperID])
                    } else {
                      try await controller.removeFromCollection(
                        collection.id, wallpaperIDs: [wallpaperID])
                    }
                  }
                })
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityLabel(Text(verbatim: collection.name))
          }
          .disabled(busy)
        }
      }
      InspectorCardRow {
        if isNaming {
          VStack(alignment: .leading, spacing: 8) {
            TextField("Collection name", text: $name, prompt: Text("Collection name"))
              .textFieldStyle(.roundedBorder)
              .controlSize(.small)
              .focused($nameFocused)
              .onSubmit(create)
              .onExitCommand(perform: cancel)
              .accessibilityLabel("Collection name")
            HStack(spacing: 8) {
              Button("Create") { create() }
                .buttonStyle(.panelPrimary(size: .compact))
                .disabled(trimmedName.isEmpty || controller.isBusy(createKey))
              Button("Cancel") { cancel() }
                .buttonStyle(.inspectorSecondary)
            }
          }
          .onAppear { nameFocused = true }
        } else {
          Button {
            name = ""
            isNaming = true
          } label: {
            Label("New collection…", systemImage: "plus")
          }
          .buttonStyle(.inspectorLink)
        }
      }
    }
  }

  private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

  private func cancel() {
    isNaming = false
    name = ""
  }

  /// Makes the collection with this wallpaper in it. A name the store refuses reaches the banner
  /// and leaves the field open.
  private func create() {
    let value = trimmedName
    guard !value.isEmpty else { return }
    let outcome = Outcome<Void>()
    let id = wallpaperID
    let task = controller.launch(PanelActionCoordinator.key("collectionNew", id: id)) {
      outcome.ran = true
      do { _ = try await controller.createCollection(name: value, wallpaperIDs: [id]) } catch {
        outcome.failed = true
        throw error
      }
    }
    Task { @MainActor in
      await task.value
      if outcome.ran, !outcome.failed { cancel() }
    }
  }
}
