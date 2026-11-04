import Foundation

/// The check for Workshop updates of installed wallpapers, for Settings and the All wallpapers chip's update
/// dot. Which wallpaper has one is `WorkshopStore.updates.available`.
struct WorkshopUpdatesState: Equatable {
  let isChecking: Bool
  /// How many installed wallpapers their authors have changed since they were installed.
  let count: Int
  let lastChecked: Date?
  let errorMessage: String?
  /// The app checks by itself, at most once a day.
  let checksAutomatically: Bool

  @MainActor
  init(_ updates: WorkshopUpdateStore) {
    isChecking = updates.isChecking
    count = updates.available.count
    lastChecked = updates.lastChecked
    errorMessage = updates.errorMessage
    checksAutomatically = updates.checksAutomatically
  }
}
