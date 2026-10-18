import Foundation

/// A setter was handed a value its control never offers: a stale control or a forged request,
/// never a choice the user made. Stores that validate their input throw it instead of clamping,
/// so a caller cannot mistake a refusal for a saved value.
struct InvalidControlValue: LocalizedError {
  var errorDescription: String? {
    String(localized: "This control sent an invalid value. Refresh the interface and retry.")
  }
}
