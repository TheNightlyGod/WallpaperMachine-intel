import SwiftUI

/// Page one: the welcome, the language and the appearance. Both choices apply the moment they are
/// made, so the guide itself repaints in the language and the light or dark the person picked.
struct WelcomeLanguagePage: View {
  @Environment(FirstRunModel.self) private var model
  @Environment(PanelController.self) private var controller
  @Environment(\.welcomeIsCompact) private var compact

  var body: some View {
    WelcomeColumn(spacing: compact ? 16 : 20) {
      WelcomeColumn(spacing: compact ? 8 : 10, centered: true) {
        WelcomeHero()
        WelcomePageHeader(
          title: Text("Welcome to WallpaperMachine"),
          lead: Text(
            "Use Steam Workshop wallpapers on your Mac desktop. Choose a language and appearance to start. You can change both later in Settings."
          ), alignment: .center)
      }
      languageGroup
      appearanceGroup
      if let error = model.error { WelcomeNotice(style: .error, message: error) }
    }
  }

  // MARK: Language

  /// System first, then every shipped language by its own name.
  private var languages: [AppLanguage] { controller.appLanguage.choices }
  private var languageTags: [String] { [AppLanguageStore.systemChoice] + languages.map(\.tag) }

  private var languageGroup: some View {
    WelcomeColumn(spacing: 10) {
      WelcomeGroupLabel(systemImage: "globe", title: Text("Language"))
      WelcomeChoiceGroup(
        label: L("Language"), count: languageTags.count,
        selectedIndex: languageTags.firstIndex(of: model.languageChoice),
        isEnabled: !model.pending.contains(.language),
        select: { choose(languageTags[$0]) }
      ) {
        WelcomeColumn(spacing: 10) {
          systemLanguageTile
          // Six names share one row: tighter spacing, and a long name shrinks a little rather
          // than breaking inside a word.
          WelcomeTileRow(spacing: 8) {
            ForEach(languages, id: \.tag) { language in
              WelcomeTile(
                isSelected: model.languageChoice == language.tag,
                isEnabled: !model.pending.contains(.language), action: { choose(language.tag) }
              ) {
                // A language is named in itself, whatever the interface speaks.
                Text(verbatim: language.name)
                  .font(.system(size: 13, weight: .semibold))
                  .lineLimit(1)
                  .minimumScaleFactor(0.75)
                  .frame(maxWidth: .infinity)
              }
            }
          }
        }
      }
      WelcomeNote(
        text: Text(
          "The interface and import picker switch at once. Quit and reopen the app to switch menus and other dialogs."
        ))
    }
  }

  private var systemLanguageTile: some View {
    WelcomeTile(
      isSelected: model.languageChoice == AppLanguageStore.systemChoice,
      isEnabled: !model.pending.contains(.language),
      action: { choose(AppLanguageStore.systemChoice) }
    ) {
      WelcomeColumn(spacing: 2) {
        Text("System (Auto)").font(.system(size: 13, weight: .semibold))
        Text("Follows the macOS language")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
      }
      .padding(.trailing, 26)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func choose(_ tag: String) { Task { await model.chooseLanguage(tag) } }

  // MARK: Appearance

  private let modes: [AppThemePreferences.Mode] = [.system, .light, .dark]

  private var appearanceGroup: some View {
    WelcomeColumn(spacing: 10) {
      WelcomeGroupLabel(systemImage: "circle.lefthalf.filled", title: Text("Appearance"))
      WelcomeChoiceGroup(
        label: L("Appearance"), count: modes.count,
        selectedIndex: modes.firstIndex(of: model.appearance),
        isEnabled: !model.pending.contains(.theme),
        select: { chooseAppearance(modes[$0]) }
      ) {
        WelcomeTileRow(spacing: 10) {
          ForEach(modes, id: \.rawValue) { mode in
            WelcomeTile(
              isSelected: model.appearance == mode, isEnabled: !model.pending.contains(.theme),
              action: { chooseAppearance(mode) }
            ) {
              WelcomeColumn(spacing: 9) {
                WelcomeMiniature(mode: mode)
                label(for: mode)
              }
            }
          }
        }
      }
    }
  }

  @ViewBuilder private func label(for mode: AppThemePreferences.Mode) -> some View {
    WelcomeColumn(spacing: 2) {
      switch mode {
      case .system:
        Label("System (Auto)", systemImage: "circle.lefthalf.filled")
        Text("Follows macOS light and dark")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
      case .light:
        Label("Light", systemImage: "sun.max")
      case .dark:
        Label("Dark", systemImage: "moon")
      }
    }
    .font(.system(size: 13, weight: .semibold))
    .labelStyle(WelcomeInlineLabelStyle())
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  private func chooseAppearance(_ mode: AppThemePreferences.Mode) {
    Task { await model.chooseAppearance(mode) }
  }
}

/// A glyph and a name on one line, the glyph in the accent.
private struct WelcomeInlineLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 6) {
      configuration.icon.font(.system(size: 12, weight: .semibold)).foregroundStyle(.tint)
      configuration.title
    }
  }
}

/// The app icon the Dock shows (the person's choice, or the season's), over the welcome.
struct WelcomeHero: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.welcomeIsCompact) private var compact
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hasAppeared = false

  var body: some View {
    Image(controller.dockIconName)
      .resizable()
      .interpolation(.high)
      .aspectRatio(contentMode: .fit)
      .frame(width: compact ? 48 : 60, height: compact ? 48 : 60)
      .shadow(color: .black.opacity(0.26), radius: 12, y: 6)
      .scaleEffect(hasAppeared || reduceMotion ? 1 : 0.88)
      .opacity(hasAppeared || reduceMotion ? 1 : 0)
      .accessibilityHidden(true)
      .onAppear {
        guard !reduceMotion else { return }
        withAnimation(.spring(duration: 0.55, bounce: 0.25)) { hasAppeared = true }
      }
  }
}

/// A miniature of the panel in the appearance it stands for: fixed colours, never the current
/// theme's, and the accent on its title line. The automatic one is both, split on a slant.
private struct WelcomeMiniature: View {
  let mode: AppThemePreferences.Mode
  @Environment(\.panelTheme) private var theme

  var body: some View {
    ZStack {
      picture(.light)
      if mode == .system {
        picture(.dark).mask(AppearanceSplit())
      }
      if mode == .dark { picture(.dark) }
    }
    .frame(height: 44)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(.black.opacity(0.16), lineWidth: 0.5)
    }
    .accessibilityHidden(true)
  }

  private func picture(_ appearance: PanelAppearance) -> some View {
    let colors = SurfacePalette.miniature(tone: .neutral, appearance: appearance)
    return GeometryReader { proxy in
      ZStack(alignment: .topLeading) {
        Rectangle().fill(colors.background.color)
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .fill(colors.bar.color)
          .frame(width: 18, height: proxy.size.height - 10)
          .offset(x: 5, y: 5)
        RoundedRectangle(cornerRadius: 3, style: .continuous)
          .fill(theme.accent.base.color)
          .frame(width: max(0, proxy.size.width - 40), height: 6)
          .offset(x: 30, y: 9)
        RoundedRectangle(cornerRadius: 3, style: .continuous)
          .fill(colors.line.color)
          .frame(width: max(0, (proxy.size.width - 30) * 0.62), height: 6)
          .offset(x: 30, y: 20)
      }
    }
  }
}

/// The right-hand part of the automatic miniature: everything past a slanted line.
private struct AppearanceSplit: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: rect.width * 0.6, y: 0))
    path.addLine(to: CGPoint(x: rect.width, y: 0))
    path.addLine(to: CGPoint(x: rect.width, y: rect.height))
    path.addLine(to: CGPoint(x: rect.width * 0.4, y: rect.height))
    path.closeSubpath()
    return path
  }
}
