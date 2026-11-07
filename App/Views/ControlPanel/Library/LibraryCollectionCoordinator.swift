import AppKit
import SwiftUI

@MainActor
final class LibraryCollectionCoordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
  let model: InstalledBrowserModel
  let scrollView = LibraryCollectionScrollView()
  let collection = LibraryCollectionView()
  let gridLayout = LibraryCollectionLayout()
  var rows: [LibraryRow] = []
  var environment = EnvironmentValues()
  var appearance = LibraryCollectionAppearance(EnvironmentValues())
  var otherDisplays = Set<String>()
  var preferredWidth = TileGridLayout.preferredTileWidth
  var pendingOffset: CGFloat?
  var lastScrollToTopCount: Int?
  var isLayingOut = false
  var isUserScrolling = false
  var hoveredID: String?
  var lastFocusedID: String?
  var hasPointerDown = false
  var eventMonitor: Any?
  private var observers: [NSObjectProtocol] = []
  private var stopped = false

  init(model: InstalledBrowserModel, restoring: CGFloat) {
    self.model = model
    pendingOffset = restoring
    super.init()
    scrollView.owner = self
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.contentView.postsBoundsChangedNotifications = true
    collection.owner = self
    collection.collectionViewLayout = gridLayout
    collection.dataSource = self
    collection.delegate = self
    collection.isSelectable = false
    collection.backgroundColors = [.clear]
    collection.wantsLayer = true
    collection.register(LibraryCollectionItem.self, forItemWithIdentifier: LibraryCollectionItem.identifier)
    scrollView.documentView = collection
    observe(NSView.boundsDidChangeNotification, object: scrollView.contentView) { $0.clipChanged() }
    observe(NSScrollView.willStartLiveScrollNotification, object: scrollView) { $0.setUserScrolling(true) }
    observe(NSScrollView.didEndLiveScrollNotification, object: scrollView) { $0.setUserScrolling(false) }
    model.scrollGrid = { [weak self] in self?.scroll(to: $0) }
  }

  private func observe(_ name: Notification.Name, object: AnyObject, action: @escaping (LibraryCollectionCoordinator) -> Void) {
    observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { if let self { action(self) } }
    })
  }

  func update(rows next: [LibraryRow], otherDisplays: Set<String>, environment: EnvironmentValues,
              preferredWidth: CGFloat, scrollToTopCount: Int) {
    let identitiesChanged = rows.map(\.id) != next.map(\.id)
    let nextAppearance = LibraryCollectionAppearance(environment)
    let contentChanged = rows != next || self.otherDisplays != otherDisplays || appearance != nextAppearance
    if let id = model.focusedID, !next.contains(where: { $0.id == id }) {
      model.focusChanged(id, isFocused: false, byKeyboard: false)
    }
    if let id = lastFocusedID, !next.contains(where: { $0.id == id }) { lastFocusedID = nil }
    rows = next
    self.otherDisplays = otherDisplays
    self.environment = environment
    appearance = nextAppearance
    self.preferredWidth = preferredWidth
    if let previous = lastScrollToTopCount, previous != scrollToTopCount { pendingOffset = 0 }
    lastScrollToTopCount = scrollToTopCount
    scrollView.setAccessibilityLabel(L("Wallpapers"))
    if identitiesChanged { collection.reloadData() }
    layoutViewport()
    if contentChanged {
      for case let item as LibraryCollectionItem in collection.visibleItems() {
        guard let path = collection.indexPath(for: item), rows.indices.contains(path.item) else { continue }
        configure(item, at: path.item)
      }
    }
    updateVisibility()
  }

  func layoutViewport() {
    guard !stopped, !isLayingOut else { return }
    let viewport = scrollView.contentView.bounds.size
    guard viewport.width > 0, viewport.height > 0 else { return }
    isLayingOut = true
    defer { isLayingOut = false }
    let changed = gridLayout.configure(viewport: viewport, preferredWidth: preferredWidth, count: rows.count)
    let size = gridLayout.collectionViewContentSize
    if collection.frame.size != size { collection.setFrameSize(size) }
    if changed { collection.layoutSubtreeIfNeeded() }
    model.geometry = gridLayout.geometry
    model.geometry.offsetY = scrollView.contentView.bounds.minY
    if let target = pendingOffset, viewport.height > 100 {
      pendingOffset = nil
      scroll(to: target)
    } else if model.geometry.offsetY > model.geometry.maxOffset {
      scroll(to: model.geometry.maxOffset)
    }
    updateVisibility()
  }

  func clipChanged() {
    guard !stopped else { return }
    if scrollView.contentView.bounds.size != gridLayout.geometry.viewport { layoutViewport() }
    model.geometry.offsetY = scrollView.contentView.bounds.minY
    if pendingOffset == nil { model.scrolled(to: model.geometry.offsetY) }
    updateVisibility()
  }

  func scroll(to offset: CGFloat) {
    guard gridLayout.geometry.viewport.height > 0 else { pendingOffset = offset; return }
    let y = min(max(0, offset), gridLayout.geometry.maxOffset)
    scrollView.contentView.scroll(to: CGPoint(x: 0, y: y))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    clipChanged()
  }

  func updateVisibility() {
    let rect = scrollView.contentView.bounds
    let visible = gridLayout.layoutAttributesForElements(in: rect).compactMap { attributes -> String? in
      let frame = attributes.frame
      let intersection = frame.intersection(rect)
      guard frame.width > 0, frame.height > 0,
        intersection.width * intersection.height >= frame.width * frame.height * 0.25,
        let path = attributes.indexPath, rows.indices.contains(path.item)
      else { return nil }
      return rows[path.item].id
    }
    let ids = Set(visible)
    model.tilesVisibilityChanged(ids)
    for case let item as LibraryCollectionItem in collection.visibleItems() {
      let onScreen = item.tile.row.map { ids.contains($0.id) } ?? false
      if item.tile.isOnScreen != onScreen { item.tile.isOnScreen = onScreen }
    }
  }

  func configure(_ item: LibraryCollectionItem, at index: Int) {
    let row = rows[index]
    item.configure(row: row, others: otherDisplays, controller: model.controller, environment: environment)
    let focused = model.focusedID == row.id && scrollView.window?.firstResponder === collection
    let hovering = hoveredID == row.id && !isUserScrolling
    let onScreen = model.tilesOnScreen.contains(row.id)
    if item.tile.isFocused != focused { item.tile.isFocused = focused }
    if item.tile.isHovering != hovering { item.tile.isHovering = hovering }
    if item.tile.isOnScreen != onScreen { item.tile.isOnScreen = onScreen }
  }

  func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }
  func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { rows.count }
  func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
    let item = collectionView.makeItem(withIdentifier: LibraryCollectionItem.identifier, for: indexPath)
    if let item = item as? LibraryCollectionItem { configure(item, at: indexPath.item) }
    return item
  }

  func collectionView(_ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
    if let item = item as? LibraryCollectionItem, rows.indices.contains(indexPath.item) {
      configure(item, at: indexPath.item)
    }
  }

  func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
    (item as? LibraryCollectionItem)?.tile.isOnScreen = false
  }

  func stop() {
    guard !stopped else { return }
    stopped = true
    clearHover()
    model.isPointerDown = false
    model.endSweep()
    model.tilesVisibilityChanged([])
    model.scrollGrid = nil
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    observers.removeAll()
    if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    eventMonitor = nil
    collection.dataSource = nil
    collection.delegate = nil
  }
}
