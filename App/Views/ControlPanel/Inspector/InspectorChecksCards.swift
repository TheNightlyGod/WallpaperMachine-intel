import SwiftUI

/// The Compatibility check card: what the app could establish about the wallpaper before it plays
/// on the target display, and which backend draws it now. Nothing here is the card's own verdict;
/// every line comes from the check, and an unknown stays unknown until the wallpaper runs.
struct CompatibilityCard: View {
  let state: CompatibilityState
  let row: LibraryRow

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let summary = InspectorWording.compatibilitySummary(state)
    let checkKey = InspectorAction.compatibilityCheck(state.wallpaperID, display: state.displayID)
    InspectorSection(
      "Compatibility check",
      accessory: {
        if let summary {
          HStack(spacing: 4) {
            if state.isChecking { ProgressRing(value: nil, lineWidth: 1.5).frame(width: 11, height: 11) }
            Text(verbatim: summary)
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(
                state.unavailableCount > 0 ? theme.surface.danger.color : theme.surface.muted.color)
          }
          .accessibilityElement(children: .combine)
          .announcing(summary)
        }
      }
    ) {
      ForEach(Array(state.checks.enumerated()), id: \.offset) { _, check in
        CheckRow(check: check)
      }
      if state.checks.isEmpty {
        InspectorCardRow {
          if state.isChecking {
            InspectorNote("Reading the wallpaper’s files…")
          } else {
            InspectorNote("Not checked yet on this display.")
          }
        }
      }
      InspectorCardRow {
        if let backend = InspectorWording.backendLine(state) {
          Text(verbatim: backend)
            .font(.system(size: 11.5))
            .foregroundStyle(theme.surface.text.color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        } else {
          InspectorNote("Which backend draws it is known once it plays on this display.")
        }
      }
      InspectorCardRow {
        TagFlow(spacing: 10) {
          Button {
            controller.launch(checkKey) {
              try await controller.checkCompatibility(state.wallpaperID, display: state.displayID)
            }
          } label: {
            if state.checks.isEmpty {
              Label("Check compatibility", systemImage: "arrow.clockwise")
            } else {
              Label("Check again", systemImage: "arrow.clockwise")
            }
          }
          .buttonStyle(.inspectorLink)
          .disabled(state.isChecking || !state.canCheck || controller.isBusy(checkKey))
          .help(
            state.canCheck
              ? L("Reads the wallpaper’s files again and re-runs the checks")
              : L("Choose an enabled, independent target display to check this wallpaper"))
          // Only the installed files are what a fresh copy from the Workshop repairs.
          if state.installedFilesAreUnavailable, controller.canReinstall(row.id) {
            Button {
              controller.launch(PanelActionCoordinator.key("workshopReinstall", id: row.id)) {
                try await controller.reinstallWorkshopItem(id: row.id)
              }
            } label: {
              Label("Reinstall from Workshop…", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.inspectorLink)
          }
        }
      }
    }
  }

  private struct CheckRow: View {
    let check: WallpaperCompatibilityCheck
    @Environment(\.panelTheme) private var theme

    var body: some View {
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: symbol)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(color)
          .frame(width: 16)
          .padding(.top, 1)
          .accessibilityLabel(InspectorWording.statusWord(check.status))
        VStack(alignment: .leading, spacing: 2) {
          Text(verbatim: check.title)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(theme.surface.text.color)
          if !check.detail.isEmpty {
            Text(verbatim: check.detail)
              .font(.system(size: 11.5))
              .foregroundStyle(theme.surface.muted.color)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .accessibilityElement(children: .combine)
    }

    private var symbol: String { InspectorGlyphs.compatibility(check.status) }

    private var color: Color {
      switch check.status {
      case .ok: theme.surface.approved.color
      case .warning: theme.surface.warning.color
      case .unavailable: theme.surface.danger.color
      case .unknown: theme.surface.muted.color
      }
    }
  }
}

/// The Black bars card of a video: an explicit check that samples a few frames for bars baked into
/// the picture, and what Fill with a scale factor would do about them on the target display.
struct LetterboxCard: View {
  let state: LetterboxState

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let checking = state.outcome == .checking
    let result = InspectorWording.letterboxResult(state)
    let checkKey = InspectorAction.letterboxCheck(state.wallpaperID, display: state.displayID)
    let stageKey = InspectorAction.letterboxStage(state.wallpaperID, display: state.displayID)
    let factor = InspectorWording.stageableFactor(state)
    let stageNote = InspectorWording.letterboxStageNote(state)
    InspectorSection("Black bars") {
      InspectorCardRow {
        InspectorNote(
          "Some videos have black bars baked into the picture. Looking samples a few frames of the file; nothing is changed."
        )
      }
      if checking {
        InspectorCardRow {
          HStack(spacing: 6) {
            ProgressRing(value: nil, lineWidth: 1.5).frame(width: 12, height: 12)
            Text("Looking for black bars…")
              .font(.system(size: 11.5))
              .foregroundStyle(theme.surface.muted.color)
          }
          .accessibilityElement(children: .combine)
        }
      } else if let result {
        ResultRow(result: result)
      }
      InspectorCardRow {
        TagFlow(spacing: 10) {
          if let factor {
            Button {
              controller.launch(stageKey) {
                try await controller.stageLetterboxFactor(state.wallpaperID, display: state.displayID)
              }
            } label: {
              Label(
                "Set scale factor to ×\(InspectorWording.factor(factor))",
                systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.inspectorLink)
            .disabled(!state.isEligible || controller.isBusy(stageKey))
          }
          Button {
            controller.launch(checkKey) {
              try await controller.checkLetterbox(state.wallpaperID, display: state.displayID)
            }
          } label: {
            if state.outcome == .idle || checking {
              Label("Look for black bars", systemImage: "arrow.clockwise")
            } else {
              Label("Look again", systemImage: "arrow.clockwise")
            }
          }
          .buttonStyle(.inspectorLink)
          .disabled(checking || !state.isEligible || controller.isBusy(checkKey))
          .help(
            state.isEligible
              ? "" : L("Choose an enabled, independent target display to check this wallpaper"))
        }
      }
      // What the staging button does, or did, follows the buttons (`letterbox.js`).
      switch stageNote {
      case .none: EmptyView()
      case .pending(let factor):
        InspectorCardRow {
          InspectorNote(
            verbatim: L(
              "Scale factor is set to ×\(InspectorWording.factor(factor)). Choose Apply changes to keep it, or Revert to undo."
            ))
        }
      case .explains:
        InspectorCardRow {
          InspectorNote("Fills in this display’s Scale factor. Nothing is saved until you choose Apply changes.")
        }
      }
    }
  }

  private struct ResultRow: View {
    let result: InspectorWording.LetterboxResult
    @Environment(\.panelTheme) private var theme

    var body: some View {
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: symbol)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(color)
          .frame(width: 16)
          .padding(.top, 1)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(verbatim: result.headline)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(theme.surface.text.color)
          if let detail = result.detail {
            Text(verbatim: detail)
              .font(.system(size: 11.5))
              .foregroundStyle(theme.surface.muted.color)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .accessibilityElement(children: .combine)
    }

    private var symbol: String { InspectorGlyphs.letterbox(result.glyph) }

    private var color: Color {
      switch result.glyph {
      case .ok: theme.surface.approved.color
      case .info: theme.accent.accent.color
      case .unclear: theme.surface.muted.color
      case .failed: theme.surface.warning.color
      }
    }
  }
}
