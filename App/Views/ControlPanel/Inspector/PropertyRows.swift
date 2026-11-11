import AppKit
import SwiftUI

/// The presets and the authored properties of the wallpaper, in the author's order. Both are left
/// out when no row has anything to draw (a wallpaper whose rows are all empty groups and decoration).
struct PropertiesCards: View {
  let options: InspectorOptions

  @Environment(PanelController.self) private var controller

  var body: some View {
    let rows = InspectorPolicy.visibleProperties(options)
    if !rows.isEmpty {
      if let presets = controller.presetsState, presets.wallpaperID == options.wallpaperID {
        PresetsCard(state: presets)
      }
      InspectorSection("Wallpaper properties") {
        InspectorCardRow {
          HStack {
            Spacer(minLength: 0)
            Button {
              controller.launch(InspectorAction.restoreAll(options.wallpaperID)) {
                try await controller.restoreAllProperties(options.wallpaperID)
              }
            } label: {
              Label("Restore all defaults", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.inspectorLink)
            .disabled(!options.canRestoreAll)
            .help(
              L(
                "Stages the default for every property except chosen files and folders. Revert undoes it."
              ))
          }
        }
        ForEach(rows) { row in
          PropertyRowView(options: options, row: row)
        }
      }
    }
  }
}

/// One authored property: its label (the author's markup, drawn safely), a Modified mark, Restore
/// default and the control. A switch, a colour and a choice sit beside the label; a slider, text,
/// picture, file and folder sit under it. Groups are headings and descriptions are text.
struct PropertyRowView: View {
  /// Whose value the row edits: an authored property, or one of Wallpaper Engine's per-wallpaper
  /// options, which the same row draws with the same Modified mark and Restore default. The scope
  /// only picks the actions and their key.
  enum Scope: Equatable {
    case authored
    case engineOption(BridgeEngineOptionId)
  }

  let options: InspectorOptions
  let row: InspectorOptions.PropertyRow
  let scope: Scope

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @State private var isHovering = false
  @FocusState private var restoreFocused: Bool
  @State private var drag = DriverBox<PumpedDrag<PropertyDragValue>>()
  @State private var colorDriver = DriverBox<ColorPickDriver>()
  @State private var liveColor: Color?
  @FocusState private var textFocused: Bool

  init(options: InspectorOptions, row: InspectorOptions.PropertyRow, scope: Scope = .authored) {
    self.options = options
    self.row = row
    self.scope = scope
  }

  private var id: String { options.wallpaperID }
  private var propertyKey: String {
    switch scope {
    case .authored: InspectorAction.property(id, row.id)
    case .engineOption(let option): InspectorAction.engineOption(id, option)
    }
  }

  var body: some View {
    switch row.control {
    case .heading:
      PropertyHeadingView(row: row)
    case .description(let detail):
      PropertyDescriptionView(row: row, detail: detail)
    default:
      content
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        // A drag cut off by the view going away (another wallpaper, a closed window) settles with
        // its newest value, so the wallpaper is put back at a saved one.
        .onDisappear {
          colorDriver.driver?.finish()
          drag.driver?.settle()
        }
    }
  }

  private var isDisabled: Bool {
    switch row.control {
    case .file, .folder, .image:
      controller.isInspectorControlDisabled(options, key: InspectorAction.propertyPath(id, row.id))
        && controller.isInspectorControlDisabled(options, key: propertyKey)
    default:
      controller.isInspectorControlDisabled(options, key: propertyKey)
    }
  }

  // MARK: Row chrome

  @ViewBuilder
  private var content: some View {
    switch row.control {
    case .toggle(let isOn):
      topLine(control: true) {
        Toggle(isOn: Binding(get: { isOn }, set: { commit(.bool(value: $0)) })) {
          Text(verbatim: row.name)
        }
          .labelsHidden()
          .toggleStyle(.switch)
          .controlSize(.small)
          .accessibilityLabel(Text(verbatim: row.name))
          .disabled(isDisabled)
      }
    case .slider(let slider):
      sliderRow(slider)
    case .choice(let selection, let choices):
      topLine(control: true) {
        Picker(
          "",
          selection: Binding<Int?>(
            get: { choices.first { $0.value == selection }?.id },
            set: { chosen in
              guard let chosen, let choice = choices.first(where: { $0.id == chosen }) else { return }
              commit(choice.value)
            })
        ) {
          ForEach(choices) { choice in
            Text(verbatim: choice.label).tag(Optional(choice.id))
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(minWidth: 110, maxWidth: 170)
        .accessibilityLabel(Text(verbatim: row.name))
        .disabled(isDisabled)
      }
    case .color(let red, let green, let blue):
      topLine(control: true) {
        ColorPicker(
          "",
          selection: Binding(
            get: { liveColor ?? Color(.sRGB, red: red, green: green, blue: blue) },
            set: { pick($0) }),
          supportsOpacity: false
        )
        .labelsHidden()
        .accessibilityLabel(Text(verbatim: row.name))
        .disabled(isDisabled)
        .onReceive(NotificationCenter.default.publisher(for: NSColorPanel.willCloseNotification)) {
          _ in colorDriver.driver?.finish()
        }
        .onChange(of: controller.isBusy(propertyKey)) { _, busy in
          if !busy, colorDriver.driver?.isPicking != true { liveColor = nil }
        }
      }
    case .text(let text):
      VStack(alignment: .leading, spacing: 6) {
        topLine {}
        TextField(
          "",
          text: Binding(
            get: { text },
            set: { controller.setPropertyText($0, property: row.id, in: id) })
        )
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .focused($textFocused)
        .onSubmit(commitText)
        .accessibilityLabel(Text(verbatim: row.name))
        .disabled(isDisabled)
        .onChange(of: textFocused) { _, focused in if !focused { commitText() } }
      }
    case .image(let path):
      VStack(alignment: .leading, spacing: 6) {
        topLine {}
        PathValueField(
          label: row.name, text: path.isEmpty ? L("No image selected") : path,
          isPlaceholder: path.isEmpty)
        HStack(spacing: 8) {
          Button {
            controller.launch(InspectorAction.propertyPath(id, row.id)) {
              try await controller.chooseTextureImage(id, property: row.id)
            }
          } label: {
            Label("Choose image", systemImage: "folder")
          }
          .buttonStyle(.inspectorSecondary)
          if !path.isEmpty {
            Button("Clear") { commit(.string(value: "")) }
              .buttonStyle(.inspectorSecondary)
          }
        }
        .disabled(isDisabled)
      }
    case .file(let state):
      AssetValueView(
        options: options, row: row, state: state, folder: nil, isDisabled: isDisabled,
        header: { topLine {} })
    case .folder(let state, let folder):
      AssetValueView(
        options: options, row: row, state: state, folder: folder, isDisabled: isDisabled,
        header: { topLine {} })
    case .heading, .description:
      EmptyView()
    }
  }

  /// The label, the Modified mark and Restore default, with the row's value or control beside them.
  ///
  /// A switch, a choice or a colour (`control`) moves under the label when the label would not fit
  /// beside it on one line, so a narrow column never breaks the author's words or squeezes the
  /// control (`PropertyTopLineLayout`). A slider's value and the rows with nothing beside the label
  /// keep one line, where the label wraps between words.
  @ViewBuilder
  private func topLine<Trailing: View>(
    control: Bool = false, @ViewBuilder trailing: () -> Trailing
  ) -> some View {
    if control {
      PropertyTopLineLayout(reserve: row.isModified ? 0 : ModifiedMark.width()) {
        PropertyNameView(row: row)
          .layoutValue(key: PropertyTopLineLayout.PartKey.self, value: .label)
        marks
          .layoutValue(key: PropertyTopLineLayout.PartKey.self, value: .marks)
        trailing()
          .layoutValue(key: PropertyTopLineLayout.PartKey.self, value: .control)
      }
    } else {
      HStack(alignment: .center, spacing: 8) {
        PropertyNameView(row: row)
          .frame(maxWidth: .infinity, alignment: .leading)
        marks
        trailing()
      }
    }
  }

  /// The Modified mark and Restore default.
  private var marks: some View {
    HStack(alignment: .center, spacing: 8) {
      if row.isModified { ModifiedMark() }
      if row.canRestoreDefault {
        Button {
          restoreDefault()
        } label: {
          Image(systemName: "arrow.counterclockwise")
        }
        .buttonStyle(InspectorIconButtonStyle(side: 22))
        .focused($restoreFocused)
        .opacity(isHovering || row.isModified || restoreFocused ? 1 : 0)
        .help(L("Restore default: \(row.name)"))
        .accessibilityLabel(L("Restore default: \(row.name)"))
        .disabled(isDisabled)
      }
    }
  }

  // MARK: Committing

  private func commit(_ value: BridgePropertyValue) {
    switch scope {
    case .authored:
      controller.launch(propertyKey, policy: .latestWins) {
        try await controller.commitProperty(id, property: row.id, value: value)
      }
    case .engineOption(let option):
      controller.launch(propertyKey, policy: .latestWins) {
        try await controller.commitEngineOption(id, option: option, value: value)
      }
    }
  }

  private func restoreDefault() {
    switch scope {
    case .authored:
      controller.launch(InspectorAction.restoreProperty(id, row.id)) {
        try await controller.restoreProperty(id, property: row.id)
      }
    case .engineOption(let option):
      controller.launch(InspectorAction.restoreEngineOption(id, option)) {
        try await controller.restoreEngineOption(id, option: option)
      }
    }
  }

  private func commitText() {
    guard let text = controller.propertyTextDraft(row.id, in: id) else { return }
    commit(.string(value: text))
  }

  // MARK: Slider

  private func sliderRow(_ slider: InspectorOptions.PropertyRow.Slider) -> some View {
    let lower = min(slider.minimum, slider.maximum)
    let upper = max(slider.minimum, slider.maximum)
    return DraggableSlider(
      value: slider.value, range: lower...upper, step: slider.step,
      format: {
        InspectorWording.sliderValue($0, step: slider.step, precision: slider.precision)
      },
      accessibilityLabel: row.name,
      onDrag: { sliderDrag().update(.number($0)) },
      onRelease: { sliderDrag().release(.number($0)) },
      onStep: { sliderDrag().step(.number($0)) }
    ) { output in
      topLine {
        Text(verbatim: output)
          .font(.system(size: 12).monospacedDigit())
          .foregroundStyle(theme.surface.muted.color)
          .accessibilityHidden(true)
      }
    }
    .disabled(isDisabled)
  }

  /// The driver of this slider's drags: a pump of its own for each drag, the property's key.
  private func sliderDrag() -> PumpedDrag<PropertyDragValue> {
    if let driver = drag.driver { return driver }
    let driver: PumpedDrag<PropertyDragValue>
    switch scope {
    case .authored:
      driver = .property(controller: controller, wallpaperID: id, property: row.id)
    case .engineOption(let option):
      driver = .engineOption(controller: controller, wallpaperID: id, option: option)
    }
    drag.driver = driver
    return driver
  }

  // MARK: Colour

  private func pick(_ color: Color) {
    guard let converted = NSColor(color).usingColorSpace(.sRGB) else { return }
    liveColor = color
    func unit(_ value: CGFloat) -> Double { min(1, max(0, Double(value))) }
    colorPickDriver().pick(
      red: unit(converted.redComponent), green: unit(converted.greenComponent),
      blue: unit(converted.blueComponent))
  }

  private func colorPickDriver() -> ColorPickDriver {
    if let driver = colorDriver.driver { return driver }
    let driver = ColorPickDriver(drag: sliderDrag())
    colorDriver.driver = driver
    return driver
  }
}

// MARK: - Label

/// The label of a control row: the author's markup drawn safely, or the app's own words. A label
/// with nothing to draw is named by the row's name, so a control is never anonymous.
private struct PropertyNameView: View {
  let row: InspectorOptions.PropertyRow

  @Environment(\.panelTheme) private var theme

  var body: some View {
    let document = InspectorPolicy.labelDocument(for: row)
    if row.label.markup != nil, !document.isEmpty {
      PropertyLabelView(document: document, baseSize: 13)
    } else {
      Text(verbatim: row.name)
        .font(.system(size: 13))
        .foregroundStyle(theme.surface.text.color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
  }
}

/// A group names the controls that follow it: a bold heading, with a rule above it.
private struct PropertyHeadingView: View {
  let row: InspectorOptions.PropertyRow

  var body: some View {
    PropertyLabelView(
      document: InspectorPolicy.labelDocument(for: row), baseSize: 12.5, baseWeight: .semibold
    )
    .padding(.horizontal, 12)
    .padding(.top, 12)
    .padding(.bottom, 6)
    .accessibilityAddTraits(.isHeader)
  }
}

/// A description: the label as text, and the record's value when that adds words.
private struct PropertyDescriptionView: View {
  let row: InspectorOptions.PropertyRow
  let detail: String?

  @Environment(\.panelTheme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      let document = InspectorPolicy.labelDocument(for: row)
      if !document.isEmpty {
        PropertyLabelView(document: document, baseSize: 12, color: theme.surface.muted.color)
      }
      if let detail {
        Text(verbatim: detail)
          .font(.system(size: 12))
          .foregroundStyle(theme.surface.muted.color)
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }
}

// MARK: - Files and folders

/// A read-only line showing a chosen path or name. It is attacker-influenced text and is selectable
/// so it can be copied out. VoiceOver names it by its property, with the text as its value, as the
/// page's read-only field was labelled by the property's label.
struct PathValueField: View {
  /// The property's name.
  let label: String
  let text: String
  var isPlaceholder = false

  @Environment(\.panelTheme) private var theme

  var body: some View {
    Text(verbatim: text)
      .font(.system(size: 12))
      .foregroundStyle(isPlaceholder ? theme.surface.faint.color : theme.surface.text.color)
      .lineLimit(1)
      .truncationMode(.middle)
      .padding(.horizontal, 8)
      .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
      .background(theme.surface.sunken.color, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .strokeBorder(theme.surface.line.color, lineWidth: 0.5)
      }
      .textSelection(.enabled)
      .accessibilityLabel(Text(verbatim: label))
      .accessibilityValue(Text(verbatim: text))
  }
}

/// A file or folder property: what is chosen, Choose… and Clear, what the choice means for the
/// wallpaper, and why it failed beside the control.
private struct AssetValueView<Header: View>: View {
  let options: InspectorOptions
  let row: InspectorOptions.PropertyRow
  let state: InspectorOptions.PropertyRow.PathState
  let folder: InspectorOptions.PropertyRow.Folder?
  let isDisabled: Bool
  @ViewBuilder let header: () -> Header

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  private var isFolder: Bool { folder != nil }

  var body: some View {
    let id = options.wallpaperID
    let key = InspectorAction.propertyPath(id, row.id)
    VStack(alignment: .leading, spacing: 6) {
      header()
      PathValueField(
        label: row.name,
        text: state.name ?? (isFolder ? L("No folder chosen") : L("No file chosen")),
        isPlaceholder: !state.isChosen)
      HStack(spacing: 8) {
        Button {
          controller.launch(key) { try await controller.chooseAssetPath(id, property: row.id) }
        } label: {
          if state.isMissing {
            Label("Reselect…", systemImage: "folder")
          } else {
            Label("Choose…", systemImage: "folder")
          }
        }
        .buttonStyle(.inspectorSecondary)
        .help(isFolder ? L("Choose a folder for \(row.name)") : L("Choose a file for \(row.name)"))
        Button("Clear") {
          controller.launch(key) { try await controller.clearAssetPath(id, property: row.id) }
        }
        .buttonStyle(.inspectorSecondary)
        .disabled(!state.isChosen)
        .help(L("Clear \(row.name)"))
      }
      .disabled(isDisabled)
      ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
        InspectorNote(verbatim: note)
      }
      if state.isChosen && state.isMissing {
        InspectorNotice(tone: .warning) {
          Text(verbatim: missingSentence).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .announcing(missingSentence)
      }
      if let error = state.error {
        InspectorNotice(tone: .error) {
          Text(verbatim: error).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .announcing(error)
      }
    }
  }

  private var missingSentence: String {
    if let path = state.sourcePath {
      return isFolder
        ? L("Missing — this folder is no longer at \(path). Reselect it.")
        : L("Missing — this file is no longer at \(path). Reselect it.")
    }
    return isFolder
      ? L("Missing — this folder can no longer be found. Reselect it.")
      : L("Missing — this file can no longer be found. Reselect it.")
  }

  /// The muted lines under the control, in the page's order: what it accepts, what a folder holds
  /// and how the wallpaper gets it, and where the chosen item lives.
  private var notes: [String] {
    AssetNotes.lines(state: state, folder: folder)
  }
}

/// The sentences under a file or folder property.
enum AssetNotes {
  @MainActor
  static func lines(
    state: InspectorOptions.PropertyRow.PathState, folder: InspectorOptions.PropertyRow.Folder?
  ) -> [String] {
    var notes: [String] = []
    let types = state.acceptedTypes.joined(separator: ", ")
    if !types.isEmpty {
      notes.append(
        folder != nil ? L("Uses \(types) files from the chosen folder.") : L("Accepts \(types)."))
    }
    // Both lines describe the folder, never an import outcome: a failed link or copy is skipped and
    // logged by the importer, so the staged count can be under the cap.
    if let folder, state.isChosen {
      if folder.isTruncated {
        let limit = folder.fileLimit
        notes.append(L("More than \(limit) files match; only the first \(limit) are used."))
      } else if let count = folder.fileCount {
        notes.append(
          count == 1
            ? L("\(count) matching file in this folder.") : L("\(count) matching files in this folder."))
      } else {
        notes.append(L("This folder could not be read. Choose it again, or pick another."))
      }
      notes.append(
        folder.delivery == .wholeList
          ? L("The wallpaper receives the whole list of files.")
          : L("The wallpaper picks files from the folder itself."))
    }
    // A missing item is the one state the person has to act on: it gets its own alert and no
    // where-it-lives note, which would read as a contradiction.
    if state.isChosen, !state.isMissing {
      if state.isManaged {
        notes.append(
          L("Copied into this app’s managed folder, so it survives cache cleans and wallpaper updates."))
      } else if let path = state.sourcePath {
        notes.append(L("Used in place from \(path). Moving or deleting it there breaks the wallpaper."))
      } else {
        notes.append(
          L("Used in place from where you chose it. Moving or deleting it there breaks the wallpaper."))
      }
    }
    return notes
  }
}
