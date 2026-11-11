import SwiftUI

/// One version of the release notes: its number, linked to what changed since the version before
/// on GitHub, the day it came out, then its sections and their lines. Settings › About and the
/// update window both draw versions with it.
struct ReleaseNotesEntryView: View {
  enum Style {
    /// Settings › About: each line in plain words, its issue and commit references left out,
    /// nothing selectable (Settings is not).
    case compact
    /// The update window: the issue and commit references kept as links, the lines selectable.
    case full
  }

  let release: AppReleaseHistory.Entry
  let language: AppReleaseHistory.Language
  var style = Style.compact

  @Environment(\.panelTheme) private var theme
  @Environment(\.locale) private var locale

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      header
      ForEach(Array(release.notes(language: language).sections.enumerated()), id: \.offset) { _, section in
        sectionView(section)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var bodySize: CGFloat { style == .full ? 13 : 12.5 }

  private var header: some View {
    let title = L("Version \(release.version.display)")
    return HStack(alignment: .firstTextBaseline, spacing: 8) {
      Group {
        if let url = release.url, ExternalLink.isAllowed(url) {
          Link(destination: url) { Text(verbatim: title) }
            .help(url.absoluteString)
        } else {
          Text(verbatim: title)
        }
      }
      .font(.system(size: style == .full ? 15 : 14, weight: .semibold))
      .foregroundStyle(theme.accent.accent.color)
      if let day = Self.day(release.date, locale: locale) {
        Text(verbatim: day)
          .font(.system(size: 12))
          .foregroundStyle(theme.surface.muted.color)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }

  private func sectionView(_ section: ReleaseNotes.Section) -> some View {
    // The window keeps each line's links; About reads the same lines without them.
    let lines =
      style == .full && section.markdown.count == section.items.count ? section.markdown : section.items
    return VStack(alignment: .leading, spacing: 5) {
      if !section.title.isEmpty {
        // Known headings (Features, Bug Fixes) are translated; any other reads as given.
        Text(verbatim: PanelLocale.shared.catalogString(section.title))
          .font(.system(size: bodySize - 0.5, weight: .semibold))
          .foregroundStyle(
            section.isHighlights ? theme.accent.accent.color : theme.surface.text.color)
          .padding(.top, 2)
      }
      ForEach(lines.indices, id: \.self) { index in
        if section.isList {
          HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(verbatim: "•").foregroundStyle(theme.surface.faint.color)
            line(lines[index])
          }
        } else {
          line(lines[index])
        }
      }
      .font(.system(size: bodySize))
      .lineSpacing(2)
      .foregroundStyle(theme.surface.text.color)
    }
  }

  @ViewBuilder
  private func line(_ text: String) -> some View {
    if style == .full {
      Text(UpdateWindow.inlineNotes(text)).textSelection(.enabled)
    } else {
      Text(verbatim: text)
    }
  }

  /// The changelog's `2026-11-09` in the panel's language ("Nov 9, 2026", "2026年11月9日"), or as
  /// written when it is not a day.
  static func day(_ text: String?, locale: Locale) -> String? {
    guard let text, !text.isEmpty else { return nil }
    let format: Date.FormatString = "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits)"
    let strategy = Date.ParseStrategy(
      format: format, locale: Locale(identifier: "en_US_POSIX"), timeZone: .gmt)
    guard let date = try? Date(text, strategy: strategy) else { return text }
    return date.formatted(
      Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, timeZone: .gmt))
  }
}
