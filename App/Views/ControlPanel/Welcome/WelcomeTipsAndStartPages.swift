import SwiftUI

// MARK: - Tips

/// Page five: the three things to know, and the honest word about wallpapers that do not run yet.
struct WelcomeTipsPage: View {
  @Environment(\.panelTheme) private var theme
  @Environment(\.welcomeIsCompact) private var compact

  var body: some View {
    WelcomeColumn(spacing: compact ? 18 : 22) {
      WelcomePageHeader(title: Text("The basics"))
      DividedRows(separatorInset: 54) {
        tip("magnifyingglass", .blue, Text("Browse wallpapers in Steam Workshop. No account needed."))
        tip("arrow.down.circle", .green, Text("Download one, then double-click it to apply."))
        tip(
          "display", .orange,
          Text("Each display plays its own wallpaper. Pick the display in the top bar."))
      }
      .welcomeSurface()
      WelcomeStatusCard(
        systemImage: "chevron.left.forwardslash.chevron.right",
        title: Text("Not every wallpaper works yet"),
        detail: Text(
          "Videos usually play. Scenes are experimental, and Application wallpapers can’t run on macOS. If one doesn’t work, use “Report on GitHub” in its details. Pull requests are welcome too."
        )
      ) {
        HStack(spacing: 18) {
          WelcomeLinkButton(title: Text("Report an issue"), url: ExternalLink.repositoryIssues)
          WelcomeLinkButton(title: Text("Contribute on GitHub"), url: ExternalLink.repository)
        }
      }
    }
  }

  private func tip(_ symbol: String, _ color: Color, _ text: Text) -> some View {
    HStack(spacing: 12) {
      SymbolTile(systemImage: symbol, color: color, size: .medium)
      text
        .font(.system(size: 13))
        .foregroundStyle(theme.surface.text.color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Start

/// Page six: what the guide set, what it left unsaved, and the ways to begin. Nothing on the
/// desktop changes until a wallpaper is applied.
struct WelcomeStartPage: View {
  @Environment(FirstRunModel.self) private var model
  @Environment(\.panelTheme) private var theme
  @Environment(\.welcomeIsCompact) private var compact

  var body: some View {
    let recap = model.recap
    WelcomeColumn(spacing: compact ? 16 : 20) {
      WelcomePageHeader(
        title: Text("Setup complete"),
        lead: Text("Your desktop won’t change until you apply a wallpaper."))
      DividedRows(separatorInset: 14) {
        recapRow(Text("Language"), value: language(recap), action: nil)
        recapRow(Text("Appearance"), value: appearance(recap), action: nil)
        recapRow(
          Text("Steam"), value: Text(verbatim: recap.steam),
          action: recap.offersFinishingSignIn
            ? (Text("Finish sign-in"), { model.go(to: .steam) }) : nil)
        ForEach(recap.unsaved) { unsaved in
          recapRow(
            unsaved.step == .performance ? Text("Performance") : Text("Preferences"),
            value: unsaved.count == 1
              ? Text("\(unsaved.count) change not saved") : Text("\(unsaved.count) changes not saved"),
            action: (Text("Review"), { model.go(to: unsaved.step) }))
        }
      }
      .welcomeSurface()
      WelcomeColumn(spacing: 8) {
        WelcomeActionRow(
          symbol: "magnifyingglass", color: theme.accent.control.color,
          title: Text("Browse the Workshop"),
          note: Text("Find wallpapers from Steam in Browse → Steam Workshop."),
          trailingSymbol: "chevron.right", isSuggested: true
        ) { model.browse() }
        WelcomeActionRow(
          symbol: "plus", color: .gray, title: Text("Import wallpapers"),
          note: Text("Bring in wallpaper folders or files you already have."),
          trailingSymbol: "chevron.right"
        ) { model.importWallpapers() }
      }
      // Where the guide lives: Settings › General › Help.
      WelcomeNote(text: Text("You can open this guide again from Settings → General."))
    }
  }

  private func language(_ recap: WelcomeRecap) -> Text {
    // A language is named in itself; following macOS has a name of its own.
    recap.languageName.map { Text(verbatim: $0) } ?? Text("System (Auto)")
  }

  private func appearance(_ recap: WelcomeRecap) -> Text {
    switch recap.appearance {
    case .system: Text("System (Auto)")
    case .light: Text("Light")
    case .dark: Text("Dark")
    }
  }

  private func recapRow(_ label: Text, value: Text, action: (Text, () -> Void)?) -> some View {
    HStack(spacing: 12) {
      label
        .font(.system(size: 13))
        .foregroundStyle(theme.surface.muted.color)
        .frame(width: 96, alignment: .leading)
      value
        .font(.system(size: 13, weight: .medium))
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
      if let (title, run) = action {
        Button(action: run) { title }
          .buttonStyle(.welcomeCapsule(isActive: true))
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .accessibilityElement(children: .combine)
  }
}
