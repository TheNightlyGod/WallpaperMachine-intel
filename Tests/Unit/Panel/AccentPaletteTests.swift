import XCTest

@testable import WallpaperMachine

final class AccentPaletteTests: XCTestCase {
  /// accent, appearance, then `accent primary primaryHover primaryActive primaryLine onPrimary
  /// focus control`, as `WebUI/theme.js` computed them when the panel was rewritten: the nine
  /// accent swatches, extremes such as pure white and black, and awkward greys, in both appearances.
  private static let golden = [
    "#80bbff light #0063d6 #006ff0 #0062d4 #0055b8 #006ff0 #ffffff #097bff #3c96ff",
    "#80bbff dark #80bbff #006ff0 #0062d4 #0055b8 #3090ff #ffffff #80bbff #3c96ff",
    "#0a84ff light #0066ce #0072e6 #0064ca #0056ae #0072e6 #ffffff #007dfb #0a84ff",
    "#0a84ff dark #63b1ff #0072e6 #0064ca #0056ae #2491ff #ffffff #2391ff #0a84ff",
    "#5e5ce6 light #5653e5 #5e5ce6 #4644e2 #2e2bdf #5e5ce6 #ffffff #5e5ce6 #5e5ce6",
    "#5e5ce6 dark #a6a4f1 #5e5ce6 #4644e2 #2e2bdf #8685ec #ffffff #8685ec #5e5ce6",
    "#bf5af2 light #a112ea #b032ef #a618ed #9611d8 #b032ef #ffffff #b94af1 #bf5af2",
    "#bf5af2 dark #d591f6 #b032ef #a618ed #9611d8 #c466f3 #ffffff #c466f3 #bf5af2",
    "#ff375f light #d2002a #ea002f #ce0029 #b20024 #ea002f #ffffff #ff0637 #ff375f",
    "#ff375f dark #ff879f #ea002f #ce0029 #b20024 #ff4d70 #ffffff #ff4d70 #ff375f",
    "#ff9f0a light #955b00 #ff9f0a #ed9000 #d17f00 #b77000 #14161a #b77000 #d58100",
    "#ff9f0a dark #ff9f0a #ff9f0a #ed9000 #d17f00 #ff9f0a #14161a #ff9f0a #d58100",
    "#ffd60a light #7b6700 #ffd60a #edc500 #d1ae00 #987e00 #14161a #987e00 #b09200",
    "#ffd60a dark #ffd60a #ffd60a #edc500 #d1ae00 #ffd60a #14161a #ffd60a #b09200",
    "#30d158 light #1b7832 #30d158 #2abb4e #25a444 #21933d #14161a #21933d #26ab47",
    "#30d158 dark #30d158 #30d158 #2abb4e #25a444 #30d158 #14161a #30d158 #26ab47",
    "#8e8e93 light #68686d #8e8e93 #808085 #7f7f84 #7f7f85 #14161a #7f7f85 #8e8e93",
    "#8e8e93 dark #acacaf #8e8e93 #808085 #7f7f84 #909094 #14161a #909094 #8e8e93",
    "#ffffff light #686868 #ffffff #f1f1f1 #e3e3e3 #808080 #14161a #808080 #949494",
    "#ffffff dark #ffffff #ffffff #f1f1f1 #e3e3e3 #ffffff #14161a #ffffff #949494",
    "#000000 light #000000 #000000 #0e0e0e #1c1c1c #000000 #ffffff #000000 #000000",
    "#000000 dark #acacac #000000 #0e0e0e #1c1c1c #909090 #ffffff #909090 #000000",
    "#b43271 light #b43271 #b43271 #c83a7f #ca4385 #b43271 #ffffff #b43271 #b43271",
    "#b43271 dark #e195ba #b43271 #c83a7f #ca4385 #d66da0 #ffffff #d66da0 #b43271",
    "#808080 light #686868 #818181 #8f8f8f #9d9d9d #808080 #14161a #808080 #808080",
    "#808080 dark #acacac #818181 #8f8f8f #9d9d9d #909090 #14161a #909090 #808080",
    "#ff0000 light #d30000 #eb0000 #cf0000 #b30000 #eb0000 #ffffff #ff0000 #ff0000",
    "#ff0000 dark #ff8a8a #eb0000 #cf0000 #b30000 #ff5151 #ffffff #ff5151 #ff0000",
    "#00ff00 light #007a00 #00ff00 #00e300 #00c700 #009500 #14161a #009500 #00ad00",
    "#00ff00 dark #00ff00 #00ff00 #00e300 #00c700 #00ff00 #14161a #00ff00 #00ad00",
    "#0000ff light #0000ff #0000ff #1c1cff #3838ff #0000ff #ffffff #0000ff #0000ff",
    "#0000ff dark #a3a3ff #0000ff #1c1cff #3838ff #8282ff #ffffff #8282ff #0000ff",
    "#ffff00 light #6c6c00 #ffff00 #e3e300 #c7c700 #848400 #14161a #848400 #9a9a00",
    "#ffff00 dark #ffff00 #ffff00 #e3e300 #c7c700 #ffff00 #14161a #ffff00 #9a9a00",
    "#00ffff light #007474 #00ffff #00e3e3 #00c7c7 #008f8f #14161a #008f8f #00a5a5",
    "#00ffff dark #00ffff #00ffff #00e3e3 #00c7c7 #00ffff #14161a #00ffff #00a5a5",
    "#ff00ff light #b900b9 #cf00cf #b300b3 #970097 #cf00cf #ffffff #e200e2 #ff00ff",
    "#ff00ff dark #ff75ff #cf00cf #b300b3 #970097 #fc00fc #ffffff #ff00ff #ff00ff",
    "#123456 light #123456 #123456 #17426d #1c5084 #123456 #ffffff #123456 #123456",
    "#123456 dark #7db0e4 #123456 #17426d #1c5084 #4d94da #ffffff #4d94da #123456",
    "#fedcba light #a35202 #b65d03 #9a4f03 #7f4102 #b65d03 #ffffff #c86503 #e87503",
    "#fedcba dark #fedcba #b65d03 #9a4f03 #7f4102 #df7204 #ffffff #fedcba #e87503",
    "#7f7f7f light #686868 #818181 #8f8f8f #9d9d9d #808080 #14161a #7f7f7f #7f7f7f",
    "#7f7f7f dark #acacac #818181 #8f8f8f #9d9d9d #909090 #14161a #909090 #7f7f7f",
    "#101010 light #101010 #101010 #1e1e1e #2c2c2c #101010 #ffffff #101010 #101010",
    "#101010 dark #acacac #101010 #1e1e1e #2c2c2c #909090 #ffffff #909090 #101010",
    "#f0f0f0 light #686868 #f0f0f0 #e2e2e2 #d4d4d4 #808080 #14161a #808080 #949494",
    "#f0f0f0 dark #f0f0f0 #f0f0f0 #e2e2e2 #d4d4d4 #f0f0f0 #14161a #f0f0f0 #949494",
    "#e3e8f0 light #4f6994 #5976a5 #4f6993 #455c81 #5976a5 #ffffff #6681ad #8096bb",
    "#e3e8f0 dark #e3e8f0 #5976a5 #4f6993 #455c81 #7991b7 #ffffff #e3e8f0 #8096bb",
    "#3b414b light #3b414b #3b414b #474f5b #545c6a #3b414b #ffffff #3b414b #3b414b",
    "#3b414b dark #a5adb8 #3b414b #474f5b #545c6a #8791a1 #ffffff #8791a1 #3b414b",
  ]

  private func palette(_ accent: String, _ appearance: PanelAppearance) -> AccentPalette {
    AccentPalette(accent: accent, appearance: appearance)
  }

  func testEveryTokenMatchesTheOriginalAlgorithmToTheDigit() {
    XCTAssertEqual(Self.golden.count, 52)
    for row in Self.golden {
      let cells = row.split(separator: " ").map(String.init)
      let appearance: PanelAppearance = cells[1] == "dark" ? .dark : .light
      let result = palette(cells[0], appearance)
      let tokens = [
        result.accent, result.primary, result.primaryHover, result.primaryActive,
        result.primaryLine, result.onPrimary, result.focus, result.control,
      ].map(\.hex)
      XCTAssertEqual(tokens, Array(cells[2...]), "\(cells[0]) \(cells[1])")
      XCTAssertEqual(result.base.hex, cells[0])
    }
  }

  func testDefaultAccentIsUsedForAnythingThatIsNotASixDigitColor() {
    let expected = palette(AccentPalette.defaultAccent, .dark)
    for value in ["", "not-a-color", "#fff", "#12345g", "80bbff", "#80bbff00", "red"] {
      XCTAssertEqual(palette(value, .dark), expected, value)
    }
    XCTAssertEqual(palette(" #FFD60A\n", .light), palette("#ffd60a", .light), "Trimmed and lowercased")
    XCTAssertEqual(AccentPalette(appearance: .light), palette("#80bbff", .light))
  }

  func testEveryAccentGivesReadableFillsLinksAndRings() {
    let white = PanelColor(rgb: 0xffffff)
    let darkSurface = PanelColor(rgb: 0x3b414b)
    let lightSurface = PanelColor(rgb: 0xe3e8f0)
    let steps: [UInt32] = [0, 51, 102, 153, 204, 255]
    var checked = 0
    for r in steps {
      for g in steps {
        for b in steps {
          let accent = PanelColor(rgb: r << 16 | g << 8 | b).hex
          for (appearance, surface) in [(PanelAppearance.dark, darkSurface), (.light, lightSurface)] {
            let result = palette(accent, appearance)
            let context = "\(accent) \(appearance)"
            XCTAssertGreaterThanOrEqual(result.primary.contrast(with: result.onPrimary), 4.5, context)
            XCTAssertGreaterThanOrEqual(result.primaryHover.contrast(with: result.onPrimary), 4.5, context)
            XCTAssertGreaterThanOrEqual(result.primaryActive.contrast(with: result.onPrimary), 4.5, context)
            XCTAssertGreaterThanOrEqual(result.accent.contrast(with: surface), 4.5, context)
            XCTAssertGreaterThanOrEqual(result.primaryLine.contrast(with: surface), 3.2, context)
            XCTAssertGreaterThanOrEqual(result.focus.contrast(with: surface), 3.2, context)
            XCTAssertGreaterThanOrEqual(result.control.contrast(with: white), 3, context)
            checked += 1
          }
        }
      }
    }
    XCTAssertEqual(checked, 432)
  }

  func testLightAccentsGetAnInkLabelAndDarkOnesAWhiteLabel() {
    XCTAssertEqual(palette("#ffd60a", .light).onPrimary.hex, "#14161a")
    XCTAssertEqual(palette("#ffffff", .dark).onPrimary.hex, "#14161a")
    XCTAssertEqual(palette("#0a84ff", .light).onPrimary.hex, "#ffffff")
    XCTAssertEqual(palette("#000000", .dark).onPrimary.hex, "#ffffff")
  }

  func testPaletteDependsOnTheAppearanceOnlyWhereTheSurfaceDoes() {
    let light = palette("#bf5af2", .light)
    let dark = palette("#bf5af2", .dark)
    XCTAssertEqual(light.primary, dark.primary, "A fill does not change with the surface")
    XCTAssertEqual(light.onPrimary, dark.onPrimary)
    XCTAssertEqual(light.control, dark.control)
    XCTAssertNotEqual(light.accent, dark.accent, "Text accents are fitted to each surface")
  }

  func testPanelColorHexRoundTripsAndRefusesMalformedValues() {
    XCTAssertEqual(PanelColor(hex: "#0A84FF")?.hex, "#0a84ff")
    XCTAssertEqual(PanelColor(rgb: 0x0000ff).hex, "#0000ff")
    XCTAssertEqual(PanelColor(rgb: 0).hex, "#000000")
    for value in ["", "#fff", "0a84ff", "#0a84fg", "#0a84ff1"] {
      XCTAssertNil(PanelColor(hex: value), value)
    }
  }
}
