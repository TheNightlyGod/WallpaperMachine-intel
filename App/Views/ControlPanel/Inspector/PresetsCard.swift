import SwiftUI

/// The presets of the wallpaper: named snapshots of its authored properties that can be applied
/// again, renamed, deleted, exported as a portable file and imported back. The controller owns the
/// presets and every file it reads or writes; this card keeps which preset is picked, a name being
/// typed and a Delete waiting for its second click.
struct PresetsCard: View {
  let state: PresetsState

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @State private var bar: PresetsBarState
  @FocusState private var nameFocused: Bool
  @FocusState private var focused: PresetsBarState.Focus?

  /// `bar` is the state the card starts with: a new wallpaper starts with none of it.
  init(state: PresetsState, bar: PresetsBarState = PresetsBarState()) {
    self.state = state
    _bar = State(initialValue: bar)
  }

  private var id: String { state.wallpaperID }

  /// Any preset action is on its way: the whole bar waits. Saving, applying, exporting and
  /// importing are keyed by the wallpaper, renaming and deleting by the preset.
  private var isPending: Bool {
    ["Save", "Apply", "Export", "Import"].contains {
      controller.isBusy(InspectorAction.preset($0, id: id))
    }
      || state.items.contains {
        controller.isBusy(InspectorAction.preset("Rename", id: $0.id))
          || controller.isBusy(InspectorAction.preset("Delete", id: $0.id))
      }
  }

  var body: some View {
    let pending = isPending
    let chosen = bar.chosen(in: state.items)
    InspectorSection("Presets") {
      InspectorCardRow {
        HStack(spacing: 8) {
          Picker(
            "Presets",
            selection: Binding(get: { bar.picked }, set: { bar.pick($0) })
          ) {
            if state.items.isEmpty {
              Text("No presets saved yet").tag("")
            } else {
              Text("Choose a preset…").tag("")
            }
            ForEach(state.items) { item in Text(verbatim: item.name).tag(item.id) }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .frame(maxWidth: .infinity, alignment: .leading)
          .disabled(!bar.canPick(state, isPending: pending))
          .accessibilityLabel("Presets")
          Button("Apply") { apply(chosen) }
            .buttonStyle(.panelPrimary(size: .compact))
            .disabled(!bar.canApply(state, isPending: pending))
            .help(applyHelp(chosen))
        }
      }
      if bar.showsTools(in: state.items) {
        InspectorCardRow {
          TagFlow(spacing: 14) {
            Button("Save current…") {
              bar.beginSave()
              nameFocused = true
            }
            .disabled(!bar.canSave(state, isPending: pending))
            .help(
              state.isDirty
                ? L("Apply or revert your changes first")
                : L("Saves the values the wallpaper is using now as a new preset"))
            Button("Import…") {
              run("Import", id: id) { try await controller.importPreset(into: id) }
            }
            .disabled(pending)
            .help(L("Adds a preset from a file exported by WallpaperMachine"))
            if let chosen {
              Button("Rename…") {
                bar.beginRename(of: chosen)
                nameFocused = true
              }
              .disabled(pending)
              Button("Export…") {
                run("Export", id: id) { try await controller.exportPreset(id, preset: chosen.id) }
              }
              .disabled(pending)
              .help(L("Saves “\(chosen.name)” as a file you can share or keep"))
              Button("Delete…") { bar.beginDelete(of: chosen) }
                .buttonStyle(.inspectorDestructiveLink)
                .disabled(pending)
                .focused($focused, equals: .deleteLink)
                .onAppear { takeFocus(.deleteLink) }
            }
          }
          .buttonStyle(.inspectorLink)
        }
      }
      if let editor = bar.editor {
        nameForm(editor, isPending: pending)
      }
      if let chosen, bar.isConfirmingDelete(in: state.items) {
        InspectorCardRow {
          VStack(alignment: .leading, spacing: 8) {
            InspectorNote(
              verbatim: L("Delete preset “\(chosen.name)”? The wallpaper keeps its current values."))
            HStack(spacing: 8) {
              Button("Delete") { delete(chosen) }
                .buttonStyle(.inspectorSecondary(isDestructive: true))
                .disabled(pending)
                .focused($focused, equals: .confirmDelete)
              Button("Cancel") { bar.cancelDelete() }
                .buttonStyle(.inspectorSecondary)
            }
          }
          .onAppear { takeFocus(.confirmDelete) }
        }
      }
      if bar.showsDirtyNote(state) {
        InspectorCardRow {
          InspectorNote("Apply or revert your changes before saving or applying a preset.")
        }
      }
      if let status = state.status {
        InspectorCardRow {
          Text(verbatim: status)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(theme.surface.text.color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .announcing(status)
        }
      }
      if let error = state.error {
        InspectorCardRow {
          InspectorNotice(tone: .error) { Text(verbatim: error).textSelection(.enabled) }
            .announcing(error)
        }
      }
    }
    .onChange(of: state.items) { _, items in bar.sync(items: items) }
  }

  // MARK: The name form

  private func nameForm(_ editor: PresetsBarState.Editor, isPending: Bool) -> some View {
    InspectorCardRow {
      VStack(alignment: .leading, spacing: 8) {
        TextField(
          "Preset name",
          text: Binding(
            get: { bar.editor?.name ?? "" }, set: { bar.setName($0) }),
          prompt: Text("Preset name")
        )
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .focused($nameFocused)
        .onSubmit { submit(editor) }
        .onExitCommand { bar.closeEditor() }
        .accessibilityLabel("Preset name")
        HStack(spacing: 8) {
          Button {
            submit(editor)
          } label: {
            if case .save = editor.mode {
              Text("Save preset")
            } else {
              Text("Save")
            }
          }
          .buttonStyle(.panelPrimary(size: .compact))
          .disabled(isPending || editor.trimmedName == nil)
          Button("Cancel") { bar.closeEditor() }
            .buttonStyle(.inspectorSecondary)
        }
      }
      .onAppear { nameFocused = true }
    }
  }

  // MARK: Focus

  /// Hands focus to `focus` once it is drawn, when the bar asked for it there.
  private func takeFocus(_ focus: PresetsBarState.Focus) {
    guard bar.focusRequest == focus else { return }
    focused = focus
    bar.focusTaken(focus)
  }

  // MARK: Actions

  private func applyHelp(_ chosen: PresetsState.Item?) -> String {
    if state.isDirty { return L("Apply or revert your changes first") }
    if let chosen { return L("Apply preset “\(chosen.name)”") }
    return L("Choose a preset to apply")
  }

  /// A preset action that has nothing to report back to the bar.
  private func run(_ action: String, id keyID: String, _ operation: @escaping @MainActor () async throws -> Void) {
    controller.launch(InspectorAction.preset(action, id: keyID), operation: operation)
  }

  private func apply(_ chosen: PresetsState.Item?) {
    guard let chosen else { return }
    run("Apply", id: id) { try await controller.applyPreset(id, preset: chosen.id) }
  }

  /// The name form's Return or Save: the preset is created (and then picked) or renamed, and the
  /// form closes once that went through; a refusal leaves it open for another try.
  private func submit(_ editor: PresetsBarState.Editor) {
    guard let name = editor.trimmedName else { return }
    let outcome = Outcome<String?>()
    switch editor.mode {
    case .save:
      let task = controller.launch(InspectorAction.preset("Save", id: id)) {
        outcome.ran = true
        do { outcome.value = try await controller.savePreset(id, name: name) } catch {
          outcome.failed = true
          throw error
        }
      }
      Task { @MainActor in
        await task.value
        if outcome.ran, !outcome.failed { bar.didSave(created: outcome.value ?? nil) }
      }
    case .rename(let presetID):
      let task = controller.launch(InspectorAction.preset("Rename", id: presetID)) {
        outcome.ran = true
        do { try await controller.renamePreset(presetID, to: name) } catch {
          outcome.failed = true
          throw error
        }
      }
      Task { @MainActor in
        await task.value
        if outcome.ran, !outcome.failed { bar.closeEditor() }
      }
    }
  }

  private func delete(_ chosen: PresetsState.Item) {
    let outcome = Outcome<Void>()
    bar.disarm()
    let task = controller.launch(InspectorAction.preset("Delete", id: chosen.id)) {
      outcome.ran = true
      do { try await controller.deletePreset(chosen.id) } catch {
        outcome.failed = true
        throw error
      }
    }
    Task { @MainActor in
      await task.value
      if outcome.ran, !outcome.failed { bar.didDelete(chosen.id) }
    }
  }
}

/// What a launched operation did: `launch` reports a failure to the banner and its task never
/// throws, so a view that has to know keeps the outcome itself.
@MainActor
final class Outcome<Value> {
  var ran = false
  var failed = false
  var value: Value?
}
