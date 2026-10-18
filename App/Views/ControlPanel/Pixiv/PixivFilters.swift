import SwiftUI

/// The Filters sidebar of the pixiv page: the pixiv account, then orientation, minimum size, age
/// rating and AI-generated works. Every change is committed at once, with the whole draft.
struct PixivFilters: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let model = controller.pixivBrowser
    let query = model.query
    FilterPanel(count: model.filterCount, onClear: { model.clearFilters() }) {
      FilterGroup("pixiv account", isExpanded: expansion(.account)) { PixivAccountGroup() }
      FilterGroup(
        "Orientation", count: model.count(in: .orientation), isExpanded: expansion(.orientation)
      ) {
        Picker(
          "Orientation",
          selection: Binding(
            get: { query.orientation }, set: { model.choose(orientation: $0) })
        ) {
          ForEach(PixivOrientation.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()
        .fixedSize()
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("pixiv-orientation")
      }
      FilterGroup(
        "Minimum size", count: model.count(in: .minimumSize), isExpanded: expansion(.minimumSize)
      ) {
        Picker(
          "Minimum size",
          selection: Binding(
            get: { query.minimumSize }, set: { model.choose(minimumSize: $0) })
        ) {
          ForEach(PixivMinimumSize.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()
        .fixedSize()
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("pixiv-size")
      }
      FilterGroup(
        "Age rating", count: model.count(in: .ageRating), isExpanded: expansion(.ageRating)
      ) {
        let account = controller.pixivAccount
        VStack(alignment: .leading, spacing: 6) {
          ForEach(PixivQuery.offeredRatings, id: \.self) { rating in
            Toggle(
              isOn: Binding(
                get: { query.ratings.contains(rating) }, set: { model.set(rating, isOn: $0) })
            ) {
              Text(verbatim: rating.title)
            }
            .toggleStyle(.checkbox)
            // Mature waits for a sign-in; the box stays visible so the way to R-18 works is plain.
            .disabled(rating == .mature && !account.allowsMature)
            .accessibilityIdentifier("pixiv-rating-\(rating.rawValue)")
          }
          note(account.r18Note)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      FilterGroup("AI-generated", count: model.count(in: .ai), isExpanded: expansion(.ai)) {
        VStack(alignment: .leading, spacing: 6) {
          Toggle(
            "Hide AI-generated works",
            isOn: Binding(
              get: { query.hidesAIGenerated }, set: { model.set(hidesAIGenerated: $0) })
          )
          .toggleStyle(.checkbox)
          .accessibilityIdentifier("pixiv-hide-ai")
          Text("Applies to search; pixiv keeps AI-generated works out of its rankings.")
            .font(.caption)
            .foregroundStyle(theme.surface.muted.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .accessibilityIdentifier("pixiv-filters")
  }

  @ViewBuilder
  private func note(_ note: PixivAccountState.R18Note) -> some View {
    Group {
      switch note {
      case .signInToShow:
        Text("Sign in to pixiv to show R-18 works. R-18G works are never shown.")
      case .accountHidesThem:
        Text(
          "This pixiv account hides R-18 works. Turn them on in pixiv’s settings under Viewing restrictions."
        )
      case .neverShowsR18G:
        Text("R-18G works are never shown.")
      }
    }
    .font(.caption)
    .foregroundStyle(theme.surface.muted.color)
  }

  private func expansion(_ group: PixivFilterGroup) -> Binding<Bool> {
    let model = controller.pixivBrowser
    return Binding(
      get: { model.isExpanded(group) }, set: { model.setExpanded(group, $0) })
  }
}

/// The sidebar's first group: who is signed in, and the way to sign in or out. Signing in happens
/// on pixiv's own page in a window of its own; the app keeps only the session, in the keychain.
private struct PixivAccountGroup: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let account = controller.pixivAccount
    VStack(alignment: .leading, spacing: 8) {
      if account.isSignedIn {
        // A long account name is cut short; the tooltip carries the whole line. The name comes
        // from pixiv, so it is put into the sentence as text, never read as a localization key.
        let who = Self.signedInLine(account)
        HStack(spacing: 6) {
          Image(systemName: "person.crop.circle.fill")
            .foregroundStyle(theme.surface.muted.color)
            .accessibilityHidden(true)
          Text(verbatim: who)
        }
        .font(.system(size: 13))
        .lineLimit(1)
        .truncationMode(.tail)
        .help(who)
        .accessibilityIdentifier("pixiv-account-name")
        Button("Log out") {
          controller.launch("pixivSignOut") { try await controller.pixivSignOut() }
        }
        .buttonStyle(.link)
        .accessibilityIdentifier("pixiv-sign-out")
      } else {
        Text(
          account.isSigningIn
            ? "Finish signing in in the pixiv window."
            : "Signing in shows works pixiv keeps for members, and R-18 works if your account allows them. You sign in on pixiv’s own page; WallpaperMachine keeps only the session, in your keychain."
        )
        .font(.caption)
        .foregroundStyle(theme.surface.muted.color)
        PixivSignInButton(isSigningIn: account.isSigningIn)
          .controlSize(.small)
      }
      if let message = account.message, !message.isEmpty {
        Text(verbatim: message)
          .font(.caption)
          .foregroundStyle(theme.surface.danger.color)
          .textSelection(.enabled)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// "Signed in as {name}", or "Signed in to pixiv" while pixiv has not confirmed who it is.
  @MainActor
  static func signedInLine(_ account: PixivAccountState) -> String {
    guard let name = account.name, !name.isEmpty else { return L("Signed in to pixiv") }
    return L("Signed in as \(name)")
  }
}

/// "Sign in to pixiv…", or "Show sign-in window" while the window is open: the same action in the
/// Filters sidebar and beside the page's header. `isShort` gives the words a narrow header has room for
/// ("Sign in", "Sign-in window"), with the full ones in the tooltip and for VoiceOver.
///
/// The glyphs say what the button does: an account to sign in to, and a window to bring forward.
/// (The system's arrow out of a rectangle means Log Out, the opposite.)
struct PixivSignInButton: View {
  let isSigningIn: Bool
  var isShort = false
  @Environment(PanelController.self) private var controller

  var body: some View {
    Button {
      controller.launch("pixivSignIn") { try await controller.pixivSignIn() }
    } label: {
      switch (isSigningIn, isShort) {
      case (true, false): Label("Show sign-in window", systemImage: "macwindow")
      case (true, true): Label("Sign-in window", systemImage: "macwindow")
      case (false, false): Label("Sign in to pixiv…", systemImage: "person.crop.circle")
      case (false, true): Label("Sign in", systemImage: "person.crop.circle")
      }
    }
    .help(isShort ? Self.title(isSigningIn: isSigningIn) : "")
    .accessibilityLabel(Self.title(isSigningIn: isSigningIn))
    .accessibilityIdentifier("pixiv-sign-in")
  }

  /// The whole title of the button.
  @MainActor
  static func title(isSigningIn: Bool) -> String {
    isSigningIn ? L("Show sign-in window") : L("Sign in to pixiv…")
  }
}
