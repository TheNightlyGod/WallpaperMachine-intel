import XCTest

@testable import WallpaperMachine

final class SurfacePaletteTests: XCTestCase {
  private let tones: [AppThemePreferences.Tone] = [.neutral, .warm, .cool]
  private let appearances: [PanelAppearance] = [.light, .dark]

  func testTextAndSemanticColoursStayReadableInEveryToneAndAppearance() {
    for tone in tones {
      for appearance in appearances {
        let palette = SurfacePalette(tone: tone, appearance: appearance)
        let context = "\(tone) \(appearance)"
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

  func testOverlaysAreWhiteOnDarkSurfacesAndBlackOnLightOnes() {
    for tone in tones {
      let dark = SurfacePalette(tone: tone, appearance: .dark)
      let light = SurfacePalette(tone: tone, appearance: .light)
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
