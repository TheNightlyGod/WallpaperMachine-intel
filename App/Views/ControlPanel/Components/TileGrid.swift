import SwiftUI

/// The geometry of a tile grid, apart from the view so it can be tested.
enum TileGridLayout {
  /// The width a tile is drawn at when there is room for it.
  static let preferredTileWidth: CGFloat = 140
  static let minimumColumns = 3

  /// How many columns fit `width`: as many tiles of the preferred width and gap as fit, and never
  /// fewer than three, so a narrow window shrinks its tiles instead of dropping to a list.
  static func columnCount(forWidth width: CGFloat, spacing: CGFloat) -> Int {
    guard width.isFinite, width > 0 else { return minimumColumns }
    return max(
      minimumColumns, Int(((width + spacing) / (preferredTileWidth + spacing)).rounded(.down)))
  }

  /// The ways the arrow keys, Home and End move focus.
  enum Move {
    case left, right, up, down, first, last
  }

  /// The cell focus moves to, or nil when the move would leave the grid: focus is held at the ends
  /// instead of wrapping, and a key down from a column the last row does not reach stays put.
  static func destination(from index: Int, _ move: Move, columns: Int, count: Int) -> Int? {
    let target =
      switch move {
      case .left: index - 1
      case .right: index + 1
      case .up: index - columns
      case .down: index + columns
      case .first: 0
      case .last: count - 1
      }
    return (0..<count).contains(target) ? target : nil
  }
}

/// A lazily built grid of square-artwork cells that fills the width it is given.
///
/// Cells are built only as they scroll into view, so a library of ten thousand wallpapers costs
/// what the window shows. Every cell can take keyboard focus: the arrow keys move between cells (up
/// and down by a whole row), Home and End jump to the first and last, and Return or Space calls
/// `onActivate`. A cell draws its own focus ring from `\.isFocused`; `WallpaperTile` does.
///
/// While the person scrolls (a trackpad or wheel gesture, and the glide after it) the cells take
/// no pointer: content moving under a still pointer otherwise has every cell's hover, gestures
/// and cursor tested again at every frame, about a fifth of the main thread's time while
/// scrolling. Hover comes back where the pointer rests once the scroll stops. A scroll the grid
/// makes itself (a sweep's autoscroll, a focused cell brought into view) keeps them.
struct TileGrid<Item: Identifiable, Cell: View>: View where Item.ID: Hashable {
  let items: [Item]
  let spacing: CGFloat
  let insets: EdgeInsets
  let onActivate: (Item) -> Void
  let cell: (Item) -> Cell

  @State private var width: CGFloat = 0
  @State private var isUserScrolling = false
  @FocusState private var focused: Item.ID?

  init(
    _ items: [Item], spacing: CGFloat = 14,
    insets: EdgeInsets = EdgeInsets(top: 12, leading: 20, bottom: 20, trailing: 20),
    onActivate: @escaping (Item) -> Void = { _ in }, @ViewBuilder cell: @escaping (Item) -> Cell
  ) {
    self.items = items
    self.spacing = spacing
    self.insets = insets
    self.onActivate = onActivate
    self.cell = cell
  }

  private var columnCount: Int {
    TileGridLayout.columnCount(forWidth: width - insets.leading - insets.trailing, spacing: spacing)
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVGrid(
          columns: Array(
            repeating: GridItem(.flexible(minimum: 0), spacing: spacing), count: columnCount),
          alignment: .center, spacing: spacing
        ) {
          ForEach(items) { item in
            cell(item)
              .id(item.id)
              .focusable()
              .focused($focused, equals: item.id)
              .focusEffectDisabled()
          }
        }
        .padding(insets)
        .allowsHitTesting(!isUserScrolling)
      }
      .onScrollPhaseChange { _, phase in
        let scrolling = phase == .interacting || phase == .decelerating
        if scrolling != isUserScrolling { isUserScrolling = scrolling }
      }
      .onGeometryChange(for: CGFloat.self) {
        $0.size.width
      } action: {
        width = $0
      }
      .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .home, .end]) { press in
        move(press.key, proxy: proxy)
      }
      .onKeyPress(keys: [.return, .space]) { _ in
        guard let focused, let item = items.first(where: { $0.id == focused }) else {
          return .ignored
        }
        onActivate(item)
        return .handled
      }
    }
  }

  private func move(_ key: KeyEquivalent, proxy: ScrollViewProxy) -> KeyPress.Result {
    guard let current = focused, let index = items.firstIndex(where: { $0.id == current }) else {
      return .ignored
    }
    let move: TileGridLayout.Move =
      switch key {
      case .leftArrow: .left
      case .rightArrow: .right
      case .upArrow: .up
      case .downArrow: .down
      case .home: .first
      default: .last
      }
    if let target = TileGridLayout.destination(
      from: index, move, columns: columnCount, count: items.count)
    {
      focused = items[target].id
      proxy.scrollTo(items[target].id)
    }
    return .handled
  }
}
