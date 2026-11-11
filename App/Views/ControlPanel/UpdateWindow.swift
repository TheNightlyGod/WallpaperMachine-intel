import AppKit
import SwiftUI

/// The window an available update opens: the app's icon, what changed in every version since the
/// running one, and **Skip This Version**, **Remind Me Later** or **Install Update**. It follows the
/// store, so a download started here shows its progress in place.
@MainActor
enum UpdateWindow {
  static let defaultContentSize = NSSize(width: 620, height: 540)
  static let minimumContentSize = NSSize(width: 500, height: 420)

  /// What the buttons do; `AppDelegate` owns the update flow and the window.
  struct Actions {
    let skip: () -> Void
    let later: () -> Void
    let install: () -> Void
    let setMode: (AppUpdateMode) -> Void
    var cancel: () -> Void = {}
  }

  /// - Parameter language: The notes translation the window opens with, the app's effective
  ///   language's by default; the switch above the notes changes it for this window only, never
  ///   the app's language.
  static func make(
    store: AppUpdateStore, actions: Actions, language: AppReleaseHistory.Language? = nil
  ) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: defaultContentSize),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.title = String(localized: "Software Update")
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isReleasedWhenClosed = false
    let notesLanguage = UpdateNotesLanguage(
      language ?? AppReleaseHistory.Language(appLanguage: AppLanguageStore.shared.effective))
    let hosting = NSHostingController(
      rootView: UpdateWindowView(store: store, actions: actions, notesLanguage: notesLanguage)
        .panelTheme(theme: AppThemeStore.shared, locale: PanelLocale.shared))
    hosting.sizingOptions = []
    window.contentViewController = hosting
    window.contentMinSize = minimumContentSize
    // Installing a controller can resize the window to its content view's fitting size.
    window.setContentSize(defaultContentSize)
    return window
  }

  /// A note's inline Markdown, links kept and nothing else interpreted: notes come from the
  /// project's own release, but are still read as text, never as a format or a layout.
  static func inlineNotes(_ markdown: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(
      interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
    return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
  }
}

/// The release-notes translation one update window shows.
@MainActor
@Observable
final class UpdateNotesLanguage {
  var selection: AppReleaseHistory.Language

  init(_ selection: AppReleaseHistory.Language) {
    self.selection = selection
  }
}

struct UpdateWindowView: View {
  let store: AppUpdateStore
  let actions: UpdateWindow.Actions
  let notesLanguage: UpdateNotesLanguage
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let state = store.state
    VStack(alignment: .leading, spacing: 16) {
      header(state)
      VStack(alignment: .leading, spacing: 8) {
        notesBar
        UpdateNotesBox(releases: store.notesReleases, language: notesLanguage.selection)
        if store.notesReleases.isEmpty {
          Text("No release notes are available for this version.").font(.caption)
        } else {
          Text("Release notes include up to 20 recent versions. Older changes are available on GitHub.")
            .font(.caption).foregroundStyle(theme.surface.muted.color)
        }
      }
      footer(state)
    }
    .padding(.horizontal, 24)
    // From the window's top edge: the title bar holds only the window buttons, then a gap.
    .padding(.top, 46)
    .padding(.bottom, 20)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(theme.surface.background.color)
    .ignoresSafeArea(.container, edges: .top)
    // Release notes link issues and commits on GitHub; nothing else opens from here.
    .environment(\.openURL, OpenURLAction { url in ExternalLink.open(url) ? .handled : .discarded })
  }

  /// **English / 简体中文 / 한국어** above the notes: the translation this window shows.
  private var notesBar: some View {
    @Bindable var notesLanguage = notesLanguage
    return HStack(spacing: 12) {
      Text("Release notes")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(theme.surface.muted.color)
      Spacer(minLength: 0)
      Picker("Release notes language", selection: $notesLanguage.selection) {
        ForEach(AppReleaseHistory.Language.allCases, id: \.self) { language in
          Text(verbatim: language.name).tag(language)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .controlSize(.small)
      .fixedSize()
    }
  }

  private func header(_ state: AppUpdateState) -> some View {
    HStack(alignment: .top, spacing: 16) {
      Image(nsImage: NSApp.applicationIconImage ?? NSImage())
        .resizable()
        .interpolation(.high)
        .frame(width: 64, height: 64)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 6) {
        Group {
          if case .ready = state {
            Text("A new version of WallpaperMachine is ready to install!")
          } else {
            Text("A new version of WallpaperMachine is available!")
          }
        }
        .font(.system(size: 15, weight: .bold))
        .foregroundStyle(theme.surface.text.color)
        .accessibilityAddTraits(.isHeader)
        detail(state)
          .font(.system(size: 13))
          .foregroundStyle(theme.surface.muted.color)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
  }

  @ViewBuilder
  private func detail(_ state: AppUpdateState) -> some View {
    let available = state.availableVersion ?? ""
    let current = state.currentVersion
    switch state {
    case .ready:
      Text("WallpaperMachine \(available) has been downloaded—you have \(current). WallpaperMachine quits and reopens to install it.")
    case .manual:
      Text("WallpaperMachine \(available) is now available—you have \(current). Download it from GitHub Releases.")
    case .error(_, _, let code, _):
      Text(verbatim: UpdatePresentation.errorText(code, rateLimitedUntil: store.rateLimitedUntil))
    default:
      Text("WallpaperMachine \(available) is now available—you have \(current). Would you like to download it now?")
    }
  }

  private func footer(_ state: AppUpdateState) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      switch state {
      case .downloading(_, _, let percent, let transferred, let total, _):
        progress(value: min(max(percent / 100, 0), 1)) {
          if total > 0 {
            Text(
              "\(TransferFormat.bytes(Double(transferred), locale: PanelLocale.shared.locale)) of \(TransferFormat.bytes(Double(total), locale: PanelLocale.shared.locale))"
            )
          } else {
            Text("Downloading \(Int(percent))%")
          }
        }
      case .preparing:
        progress(value: nil) { Text("Preparing update…") }
      default:
        Picker("Update mode", selection: Binding(get: { store.mode }, set: actions.setMode)) {
          ForEach(AppUpdateMode.allCases, id: \.self) { mode in
            Text(verbatim: mode.title).tag(mode)
          }
        }
        .pickerStyle(.menu)
        Text(verbatim: store.mode.explanation).font(.caption).foregroundStyle(theme.surface.muted.color)
      }
      HStack(spacing: 10) {
        Button("Skip This Version", action: actions.skip)
          .disabled(state.isBusy)
        Spacer(minLength: 12)
        if state.isBusy { Button("Cancel", action: actions.cancel) }
        Button("Remind Me Later", action: actions.later)
          .keyboardShortcut(.cancelAction)
        primary(state)
      }
      .controlSize(.large)
    }
  }

  @ViewBuilder
  private func primary(_ state: AppUpdateState) -> some View {
    Group {
      switch state {
      case .ready:
        Button(store.canInstallInPlace ? L("Install and Relaunch") : L("Show in Finder"), action: actions.install)
      case .manual: Button("Open GitHub Releases", action: actions.install)
      case .error: Button("Retry", action: actions.install)
      default: Button("Download Update", action: actions.install)
      }
    }
    .buttonStyle(.panelPrimary)
    .keyboardShortcut(.defaultAction)
    // Nothing to install while a check runs or after one failed.
    .disabled(state.isBusy || state.availableVersion == nil || store.isChecking || store.isRestoring || store.installIsScheduled)
  }

  private func progress(value: Double?, @ViewBuilder label: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      if let value {
        ProgressView(value: value).progressViewStyle(.linear)
      } else {
        ProgressView().progressViewStyle(.linear)
      }
      label()
        .font(.system(size: 11.5))
        .foregroundStyle(theme.surface.muted.color)
    }
  }
}

/// The scrolling box of release notes: each version's linked number and date, then its sections
/// and bullets, issue and commit references linked (`ReleaseNotesEntryView`, as About draws them).
struct UpdateNotesBox: View {
  let releases: [AppReleaseHistory.Entry]
  let language: AppReleaseHistory.Language
  @Environment(\.panelTheme) private var theme

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 24) {
        ForEach(releases, id: \.version.display) { release in
          ReleaseNotesEntryView(release: release, language: language, style: .full)
        }
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    // Another translation starts at the top again.
    .id(language)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(theme.surface.sunken.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(theme.surface.line.color))
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("Release notes"))
  }
}
