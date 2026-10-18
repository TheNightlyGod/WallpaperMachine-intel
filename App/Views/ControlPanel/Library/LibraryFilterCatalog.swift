import SwiftUI

/// The boxes of the Filters sidebar, tag for tag as Wallpaper Engine's own Workshop sidebar has
/// them. Installed applies them to the library in the app; Discover sends the same tags to
/// Steam. Tags are Steam's English names and are never translated when matched or sent: only the
/// labels are.
///
/// Three families. A "Show only" box starts unticked, and ticking it *requires* the tag. A Tags
/// chip starts out filtering nothing: selecting it requires its tag and hiding it excludes the tag
/// (`FilterTagChip`). Every other box starts ticked, and unticking it *excludes* the tag, so a group with everything ticked
/// filters nothing.
enum LibraryFilterCatalog {
  /// One box.
  struct Entry: Identifiable {
    /// The tag as Steam and the manifests spell it.
    let tag: String
    /// The box's name in the panel's language; the numeric resolutions have none to translate.
    let label: Text
    /// Wallpaper Engine leaves this box unticked by default. Only Discover starts with any.
    let isOffByDefault: Bool

    var id: String { tag }
  }

  /// A run of boxes with an optional heading and All / None links, or of chips with Reset.
  struct Section: Identifiable {
    let key: String
    let title: Text?
    let hasQuickLinks: Bool
    /// The tags are chips, which select rather than untick: a long list of tags a wallpaper can
    /// carry several of.
    let isChips: Bool
    /// What Steam knows and a wallpaper's manifest does not carry (its Workshop category and
    /// resolution), so Installed leaves it out.
    let isDiscoverOnly: Bool
    let entries: [Entry]

    var id: String { key }
    var tags: [String] { entries.map(\.tag) }
  }

  /// A disclosure of the popover.
  struct Group: Identifiable {
    let key: String
    let title: LocalizedStringKey
    let isDiscoverOnly: Bool
    let sections: [Section]

    var id: String { key }
    var tags: [String] { sections.flatMap(\.tags) }
  }

  /// A "Show only" box: a tag a wallpaper must carry, with the symbol that marks it.
  struct RequiredTag: Identifiable {
    let tag: String
    let label: Text
    let symbol: String

    var id: String { tag }
  }

  // MARK: Builders (the labels stay literals so the catalog finds them)

  private static func entry(_ tag: String, _ label: LocalizedStringKey, off: Bool = false)
    -> Entry
  {
    Entry(tag: tag, label: Text(label), isOffByDefault: off)
  }

  private static func number(_ size: String, prefix: String = "") -> Entry {
    Entry(tag: "\(prefix)\(size)", label: Text(verbatim: size), isOffByDefault: false)
  }

  private static func required(_ tag: String, _ label: LocalizedStringKey, _ symbol: String)
    -> RequiredTag
  {
    RequiredTag(tag: tag, label: Text(label), symbol: symbol)
  }

  private static func section(
    _ key: String, title: LocalizedStringKey? = nil, quick: Bool = false, chips: Bool = false,
    discoverOnly: Bool = false, _ entries: [Entry]
  ) -> Section {
    Section(
      key: key, title: title.map { Text($0) }, hasQuickLinks: quick, isChips: chips,
      isDiscoverOnly: discoverOnly, entries: entries)
  }

  // MARK: Show only

  /// What Installed can require, in order: the two facts only a library has, then Discover's three.
  static let showOnly: [RequiredTag] = [
    required("Favorite", "Favorites", "heart"),
    required("Active", "Active on target display", "play"),
    required("Update", "Update available", "arrow.down.circle"),
    required("Approved", "Approved", "trophy"),
    required("Audio responsive", "Audio responsive", "waveform"),
    required("Customizable", "Customizable", "slider.horizontal.3"),
  ]

  /// The tags a wallpaper's own facts supply, besides the ones its manifest lists.
  static let favoriteTag = "Favorite"
  static let activeTag = "Active"
  static let updateTag = "Update"
  static let approvedTag = "Approved"
  static let unspecifiedTag = "Unspecified"

  // MARK: Exclusion groups

  static let groups: [Group] = [
    Group(
      key: "type", title: "Type", isDiscoverOnly: false,
      sections: [
        section("type", [entry("Scene", "Scene"), entry("Video", "Video"), entry("Web", "Web")]),
        section(
          "category", discoverOnly: true,
          [entry("Wallpaper", "Wallpaper"), entry("Preset", "Preset")]),
      ]),
    Group(
      key: "rating", title: "Age rating", isDiscoverOnly: false,
      sections: [
        section(
          "rating",
          [
            entry("Everyone", "Everyone (G)"),
            entry("Questionable", "Questionable (PG-13)", off: true),
            entry("Mature", "Mature (R-18)", off: true),
          ])
      ]),
    Group(
      key: "resolution", title: "Resolution", isDiscoverOnly: true,
      sections: [
        section(
          "widescreen", title: "Widescreen", quick: true,
          [entry("Standard Definition", "Standard definition")]
            + ["1280 x 720", "1366 x 768", "1920 x 1080", "2560 x 1440", "3840 x 2160"].map {
              number($0)
            }),
        section(
          "ultrawide", title: "Ultrawide", quick: true,
          [entry("Ultrawide Standard Definition", "Ultrawide (standard)")]
            + ["2560 x 1080", "3440 x 1440"].map { number($0, prefix: "Ultrawide ") }),
        section(
          "dual", title: "Dual monitor", quick: true,
          [entry("Dual Standard Definition", "Dual monitor (standard)")]
            + ["3840 x 1080", "5120 x 1440", "7680 x 2160"].map { number($0, prefix: "Dual ") }),
        section(
          "triple", title: "Triple monitor", quick: true,
          [entry("Triple Standard Definition", "Triple monitor (standard)")]
            + ["4096 x 768", "5760 x 1080", "7680 x 1440", "11520 x 2160"].map {
              number($0, prefix: "Triple ")
            }),
        section(
          "portrait", title: "Portrait monitor / phone", quick: true,
          [entry("Portrait Standard Definition", "Portrait monitor / phone (standard)")]
            + ["720 x 1280", "1080 x 1920", "1440 x 2560", "2160 x 3840"].map {
              number($0, prefix: "Portrait ")
            }),
        section(
          "other-resolution",
          [
            entry("Other resolution", "Other resolution"),
            entry("Dynamic resolution", "Dynamic resolution"),
          ]),
      ]),
    Group(
      key: "genre", title: "Tags", isDiscoverOnly: false,
      sections: [
        section(
          "genre", quick: true, chips: true,
          [
            entry("Abstract", "Abstract"), entry("Animal", "Animal"), entry("Anime", "Anime"),
            entry("Cartoon", "Cartoon"), entry("CGI", "CGI"), entry("Cyberpunk", "Cyberpunk"),
            entry("Fantasy", "Fantasy"), entry("Game", "Game"), entry("Girls", "Girls"),
            entry("Guys", "Guys"), entry("Landscape", "Landscape"), entry("Medieval", "Medieval"),
            entry("Memes", "Memes"), entry("MMD", "MMD (Miku Miku Dance)"),
            entry("Music", "Music"), entry("Nature", "Nature"), entry("Pixel art", "Pixel art"),
            entry("Relaxing", "Relaxing"), entry("Retro", "Retro"), entry("Sci-Fi", "Sci-Fi"),
            entry("Sports", "Sports"), entry("Technology", "Technology"),
            entry("Television", "Television"), entry("Vehicle", "Vehicle"),
            entry(unspecifiedTag, "Unspecified genre", off: true),
          ])
      ]),
  ]

  /// The groups Installed shows: what a wallpaper's own manifest can answer.
  static let installedGroups: [Group] = groups.filter { !$0.isDiscoverOnly }.map { group in
    Group(
      key: group.key, title: group.title, isDiscoverOnly: false,
      sections: group.sections.filter { !$0.isDiscoverOnly })
  }

  static let sections: [Section] = groups.flatMap(\.sections)

  /// The tags offered as chips, whose required ones the chips show rather than "Show only".
  static let chipTags: Set<String> = Set(sections.filter(\.isChips).flatMap(\.tags))

  /// Steam's own words for "no genre was tagged": every genre but Unspecified, lower-cased for
  /// matching. A wallpaper carrying none of them counts as Unspecified.
  static let genreTags: Set<String> = Set(
    groups.first { $0.key == "genre" }!.sections[0].entries.map(\.tag)
      .filter { $0 != unspecifiedTag }.map { $0.lowercased() })

  /// Tags Discover always excludes and never offers.
  static let hiddenExcludedTags = ["Application", "Asset"]

  /// The tags Discover starts excluded: the hidden ones and the boxes Wallpaper Engine leaves
  /// unticked. Must equal `WorkshopStore.defaultExcludedTags`, which a test holds it to.
  static let defaultExcludedTags: [String] =
    hiddenExcludedTags + sections.flatMap(\.entries).filter(\.isOffByDefault).map(\.tag)

  static func section(key: String) -> Section? { sections.first { $0.key == key } }
}
