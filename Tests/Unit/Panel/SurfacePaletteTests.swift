import XCTest

@testable import WallpaperMachine

final class SurfacePaletteTests: XCTestCase {
  private let tones: [AppThemePreferences.Tone] = [.neutral, .warm, .cool]
  private let appearances: [PanelAppearance] = [.light, .dark]

  /// Every palette the panel can wear in `appearance`: each tone's and the Halloween look's.
  private func palettes(_ appearance: PanelAppearance) -> [(String, SurfacePalette)] {
    tones.map { ("\($0) \(appearance)", SurfacePalette(tone: $0, appearance: appearance)) }
      + [("halloween \(appearance)", SurfacePalette(season: .halloween, appearance: appearance))]
  }

  func testTextAndSemanticColoursStayReadableInEveryToneSeasonAndAppearance() {
    for appearance in appearances {
      for (context, palette) in palettes(appearance) {
        for ground in [
          palette.background, palette.surface, palette.card, palette.raised, palette.well,
          palette.sunken,
        ] {
          XCTAssertGreaterThanOrEqual(palette.text.contrast(with: ground), 7, context)
          // Approval and heart marks are graphics beside text, not text.
          for mark in [palette.approved, palette.heart] {
            XCTAssertGreaterThanOrEqual(mark.contrast(with: ground), 3, context)
          }
        }
        for ground in [palette.background, palette.surface, palette.card] {
          for secondary in [palette.muted, palette.danger, palette.warning] {
            XCTAssertGreaterThanOrEqual(secondary.contrast(with: ground), 4.5, context)
          }
        }
        XCTAssertGreaterThanOrEqual(palette.tagInk.contrast(with: palette.badge), 4.5, context)
      }
    }
  }

  func testTonesTintTheSurfacesAndNeutralKeepsTheDefaultLook() {
    for appearance in appearances {
      let neutral = SurfacePalette(tone: .neutral, appearance: appearance)
      let warm = SurfacePalette(tone: .warm, appearance: appearance)
      let cool = SurfacePalette(tone: .cool, appearance: appearance)
      XCTAssertNotEqual(neutral.background, warm.background, "\(appearance)")
      XCTAssertNotEqual(neutral.surface, cool.surface, "\(appearance)")
      XCTAssertGreaterThanOrEqual(red(warm.surface), blue(warm.surface), "\(appearance)")
      XCTAssertGreaterThanOrEqual(blue(cool.surface), red(cool.surface), "\(appearance)")
      XCTAssertGreaterThanOrEqual(red(warm.muted) - blue(warm.muted), 0, "\(appearance)")
    }
    XCTAssertEqual(SurfacePalette(tone: .neutral, appearance: .light).background.hex, "#ffffff")
    XCTAssertEqual(SurfacePalette(tone: .neutral, appearance: .dark).background.hex, "#1d1d1f")
    XCTAssertEqual(SurfacePalette(tone: .warm, appearance: .dark).text.hex, "#f5f1ea")
    XCTAssertEqual(SurfacePalette(tone: .cool, appearance: .light).well.hex, "#eef1f6")
  }

  func testTheHalloweenLookHasItsOwnSurfacesInBothAppearances() {
    for appearance in appearances {
      let halloween = SurfacePalette(season: .halloween, appearance: appearance)
      for tone in tones {
        let everyday = SurfacePalette(tone: tone, appearance: appearance)
        XCTAssertNotEqual(halloween.background, everyday.background, "\(tone) \(appearance)")
        XCTAssertNotEqual(halloween.text, everyday.text, "\(tone) \(appearance)")
      }
    }
    // Moonlit ink in the dark: violet, never the neutral grey; parchment in the light: warm.
    let night = SurfacePalette(season: .halloween, appearance: .dark)
    XCTAssertGreaterThan(blue(night.surface), red(night.surface))
    let parchment = SurfacePalette(season: .halloween, appearance: .light)
    XCTAssertGreaterThan(red(parchment.surface), blue(parchment.surface))
  }

  func testOverlaysAreWhiteOnDarkSurfacesAndBlackOnLightOnes() {
    for (dark, light) in zip(palettes(.dark).map(\.1), palettes(.light).map(\.1)) {
      for overlay in [dark.line, dark.divider, dark.hover, dark.pressed, dark.selected] {
        XCTAssertEqual(overlay.rgb, 0xffffff)
        XCTAssertLessThan(overlay.alpha, 0.2)
      }
      for overlay in [light.line, light.divider, light.hover, light.pressed, light.selected] {
        XCTAssertEqual(overlay.rgb, 0)
        XCTAssertLessThan(overlay.alpha, 0.2)
      }
      XCTAssertLessThan(dark.hover.alpha, dark.pressed.alpha)
      XCTAssertLessThan(light.hover.alpha, light.pressed.alpha)
      XCTAssertLessThan(light.divider.alpha, light.line.alpha)
    }
  }

  func testMiniatureTintsOnlyTheBackgroundAndKeepsTheLightAndDarkPictures() {
    for appearance in appearances {
      let neutral = SurfacePalette.miniature(tone: .neutral, appearance: appearance)
      for tone in [AppThemePreferences.Tone.warm, .cool] {
        let tinted = SurfacePalette.miniature(tone: tone, appearance: appearance)
        XCTAssertNotEqual(tinted.background, neutral.background, "\(tone) \(appearance)")
        XCTAssertEqual(tinted.bar, neutral.bar)
        XCTAssertEqual(tinted.line, neutral.line)
      }
    }
    let light = SurfacePalette.miniature(tone: .neutral, appearance: .light)
    XCTAssertEqual([light.background.hex, light.bar.hex, light.line.hex], ["#f5f5f7", "#e2e2e7", "#c9c9d0"])
    let dark = SurfacePalette.miniature(tone: .neutral, appearance: .dark)
    XCTAssertEqual([dark.background.hex, dark.bar.hex, dark.line.hex], ["#2c2c2e", "#1c1c1e", "#48484c"])
    // 55% neutral and 45% amber, channel by channel, as the web panel mixed it.
    XCTAssertEqual(
      SurfacePalette.miniature(tone: .warm, appearance: .light).background.hex, "#f5efe7")
  }

  private func red(_ color: PanelColor) -> Int { Int((color.rgb >> 16) & 255) }
  private func blue(_ color: PanelColor) -> Int { Int(color.rgb & 255) }
}
