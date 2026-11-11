import Foundation

extension InspectorOptions {
  /// One of Wallpaper Engine's per-wallpaper options, drawn as a property row (`PropertyRowView`
  /// with the `.engineOption` scope). Its words are the app's own.
  struct EngineOptionRow: Equatable, Identifiable {
    let option: BridgeEngineOptionId
    let row: PropertyRow

    var id: String { row.id }
  }

  /// The words of an image filter's file name, which is the only name a filter has: a leading
  /// `lutx<digits>_` is dropped, underscores become spaces and the first letter is capitalised.
  /// The name is never translated.
  static func imageFilterLabel(_ name: String) -> String {
    var words = Substring(name)
    let lower = name.lowercased()
    if lower.hasPrefix("lutx"), let underscore = name.firstIndex(of: "_") {
      let digits = name[name.index(name.startIndex, offsetBy: 4)..<underscore]
      if !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) {
        words = name[name.index(after: underscore)...]
      }
    }
    let spaced = words.replacingOccurrences(of: "_", with: " ")
    guard let first = spaced.first else { return name }
    return first.uppercased() + spaced.dropFirst()
  }

  /// The app's name for an option, in the panel's language.
  @MainActor
  static func engineOptionTitle(_ option: BridgeEngineOptionId, locale: PanelLocale) -> String {
    switch option {
    case .colorEnabled: locale.string("Color adjustments")
    case .brightness: locale.string("Brightness")
    case .contrast: locale.string("Contrast")
    case .saturation: locale.string("Saturation")
    case .hueShift: locale.string("Hue shift")
    case .imageFilter: locale.string("Image filter")
    case .filterStrength: locale.string("Filter strength")
    case .flipHorizontal: locale.string("Flip horizontally")
    case .mouseParallax: locale.string("Mouse parallax")
    case .playbackRate: locale.string("Playback rate")
    }
  }

  @MainActor
  static func engineRow(
    _ option: BridgeEngineOptionRow, filters: [String], inputs: Inputs
  ) -> EngineOptionRow {
    let locale = inputs.locale ?? .shared
    let name = engineOptionTitle(option.id, locale: locale)
    let pending = inputs.pendingEngineValues[option.id]
    let shown = pending ?? option.value
    let control: PropertyRow.Control
    switch option.id {
    case .colorEnabled, .flipHorizontal, .mouseParallax:
      if case .bool(let isOn) = shown { control = .toggle(isOn: isOn) } else { control = .toggle(isOn: false) }
    case .imageFilter:
      var choices = [PropertyRow.Choice(id: 0, label: locale.string("No filter"), value: .string(value: ""))]
      for (index, filter) in filters.enumerated() {
        choices.append(.init(id: index + 1, label: imageFilterLabel(filter), value: .string(value: filter)))
      }
      control = .choice(selection: choices.first { $0.value == shown }?.value, choices: choices)
    case .brightness, .contrast, .saturation, .hueShift, .filterStrength, .playbackRate:
      let minimum = option.slider?.min ?? 0
      let number: Double
      if case .number(let value) = shown { number = value } else { number = minimum }
      control = .slider(
        PropertyRow.Slider(
          value: number, minimum: minimum, maximum: option.slider?.max ?? 100,
          step: option.slider.map { $0.step > 0 ? $0.step : 1 } ?? 1,
          precision: Int(option.slider?.precision ?? 0)))
    }
    return EngineOptionRow(
      option: option.id,
      row: PropertyRow(
        id: "engine.\(option.id)", control: control, name: name,
        label: PropertyLabels.Presentation(text: name, markup: nil, images: [:]),
        isModified: option.modified || pending != nil, isDirty: option.modified,
        canRestoreDefault: true))
  }
}
