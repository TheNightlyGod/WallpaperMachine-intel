import SwiftUI

/// Settings › Performance: what the app costs in energy, the quality of the picture, and the
/// renderers behind it. The less common choices wait inside Advanced.
struct PerformanceSettingsSection: View {
  private static let energy = SettingsItem.Group("energy", title: "Energy use")
  private static let quality = SettingsItem.Group("quality", title: "Quality")
  private static let video = SettingsItem.Group("video", title: "Video playback")
  private static let scene = SettingsItem.Group("scene", title: "Scene wallpapers")
  private static let experimental = SettingsItem.Group("experimental", title: "Experimental")

  // Energy use
  static let energyUse = SettingsItem(
    id: "performance.energy-readout", section: .performance, group: energy,
    title: "This app, last few seconds",
    note:
      "Right after you apply a wallpaper, these figures include loading it, which can take several watts for a few seconds.",
    keywords: [
      "Unavailable on this Mac", "Measuring…", "Video not counted",
      "GPU shared with other apps", "Low energy use", "Medium energy use", "High energy use",
    ])
  static let energyMethod = SettingsItem(
    id: "performance.energy-method", section: .performance, group: energy,
    title: "How it’s measured")

  // Quality
  static let preset = SettingsItem(
    id: "performance.quality-preset", section: .performance, group: quality, title: "Preset",
    note:
      "Low, Medium and High set the frame-rate limit and render scale together. Custom means the current values match none of those.",
    keywords: ["Low", "Medium", "High", "Custom"])
  static let frameRateLimit = SettingsItem(
    id: "performance.frame-rate-limit", section: .performance, group: quality,
    title: "Frame rate limit",
    note:
      "At the top of the slider there is no limit, and each display runs at its own frame rate: up to 60 fps unless you chose more for it. A lower value caps scenes and web wallpapers on every display, while a video plays at its own frame rate; saved per-display frame rates are not rewritten.",
    keywords: ["No limit"])
  static let renderScale = SettingsItem(
    id: "performance.render-scale", section: .performance, group: quality,
    title: "Internal render scale",
    note:
      "Renders at a lower resolution and scales the result to fill the same area. Size and position on screen don’t change.",
    keywords: ["Not applicable to the wallpapers currently running", "100% (native)"])
  /// What the engine uses now where it differs from the saved Frame rate limit and render scale,
  /// and which condition lowers them.
  static let renderScaleEffective = SettingsItem(
    id: "performance.render-scale-effective", section: .performance, group: quality,
    title: "Effective now")
  static let sceneResolution = SettingsItem(
    id: "performance.scene-resolution", section: .performance, group: quality,
    title: "2D scene resolution",
    note:
      "Display resolution draws a 2D scene at the size it covers on your display, as Wallpaper Engine does, which keeps it sharp on a high-resolution screen. Canvas size draws it at the size its author made it and stretches the result, which uses the least GPU and memory. Internal render scale applies on top. Perspective scenes and videos aren’t affected.",
    keywords: ["Display resolution", "Canvas size"])

  // Advanced
  static let advanced = SettingsItem(
    id: "performance.advanced", section: .performance, title: "Advanced",
    note: "Diagnostics & experimental options")

  static let videoDiagnostics = SettingsItem(
    id: "performance.video-diagnostics", section: .performance, group: video, inside: advanced,
    title: "Live diagnostics")
  static let videoInUse = SettingsItem(
    id: "performance.video-in-use", section: .performance, group: video,
    inside: videoDiagnostics, title: "In use now",
    keywords: ["No video wallpaper is running."])

  static let sceneOptimization = SettingsItem(
    id: "performance.scene-optimization", section: .performance, group: scene, inside: advanced,
    title: "Scene render optimisation",
    note:
      "Skips rendering work that wouldn’t change the picture, such as parts of a scene that stay the same. Resolution, frame rate and animation speed are unaffected. Turn it off to compare.",
    keywords: [
      "How much can be skipped depends on the scene. If everything in it moves, nothing is skipped."
    ])
  static let sceneOnDemand = SettingsItem(
    id: "performance.scene-on-demand", section: .performance, group: scene, inside: advanced,
    title: "Update only when the scene changes",
    note:
      "When a scene has nothing left to animate, it stops drawing until something changes. Scenes that are still moving keep running normally, and scripts, sound and input keep working."
  )
  static let sceneDiagnostics = SettingsItem(
    id: "performance.scene-diagnostics", section: .performance, group: scene, inside: advanced,
    title: "Live diagnostics")
  static let sceneDrawnBy = SettingsItem(
    id: "performance.scene-drawn-by", section: .performance, group: scene,
    inside: sceneDiagnostics, title: "Drawn by",
    keywords: ["No scene wallpaper is running."])
  static let sceneInForce = SettingsItem(
    id: "performance.scene-in-force", section: .performance, group: scene,
    inside: sceneDiagnostics, title: "In force now")
  static let sceneUpdating = SettingsItem(
    id: "performance.scene-updating", section: .performance, group: scene,
    inside: sceneDiagnostics, title: "Updating now", keywords: ["Retry"])
  static let sceneCompatibility = SettingsItem(
    id: "performance.scene-compatibility", section: .performance, group: scene, inside: advanced,
    title: "Renderer compatibility")

  static let videoPlaneSampling = SettingsItem(
    id: "performance.video-plane-sampling", section: .performance, group: experimental,
    inside: advanced, title: "Direct video plane sampling",
    note:
      "Experimental. In scenes drawn by Native Metal, lets a layer’s shader read video frames directly instead of converting them to a color image every frame. Only works with 8-bit NV12 video and shaders that support it; everything else converts as before. Live diagnostics under Scene wallpapers shows which path each scene uses."
  )

  static let items = [
    energyUse, energyMethod, preset, frameRateLimit, renderScale, renderScaleEffective,
    sceneResolution, advanced, videoDiagnostics, videoInUse, sceneOptimization, sceneOnDemand,
    sceneDiagnostics, sceneDrawnBy, sceneInForce, sceneUpdating, sceneCompatibility,
    videoPlaneSampling,
  ]

  /// The live rows this page leaves out while they have nothing to say, by the values its body
  /// draws them from: Effective now while the saved frame-rate limit and scale are the ones in
  /// force, and In force now while no scene has a backend.
  @MainActor
  static func unofferedItems(_ controller: PanelController) -> Set<String> {
    let performance = controller.performanceSettings
    var hidden: [SettingsItem] = []
    if performance.quality.effectiveNowText == nil { hidden.append(renderScaleEffective) }
    if performance.optimization.text == nil { hidden.append(sceneInForce) }
    return Set(hidden.map(\.id))
  }

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let performance = controller.performanceSettings
    SettingsPage(.performance) {
      SettingsUnavailableNotice()
      SettingsGroup(Self.energy, in: .performance) {
        SettingsRow(Self.energyUse, stacked: true) { PerformanceEnergyReadout() }
        SettingsDisclosure(Self.energyMethod) {
          SettingsProse {
            Text("macOS shares GPU energy between apps by GPU time.")
            Text(
              "Includes the control panel, the lock screen and the CPU side of video decoding. Screen compositing, the hardware video decoder, memory and the display itself are not included."
            )
            Text("Low: below 0.5 W. Medium: 0.5 W to below 2 W. High: 2 W or more.")
            Text("Change a quality setting below to compare energy use.")
          }
        }
      }
      SettingsGroup(Self.quality, in: .performance) {
        // The segments take their labels' width, never a fixed one: a fixed width squeezed
        // "Medium" and, with the inspector beside the page, asked the split view for more room
        // than the smallest window has.
        SettingsRow(Self.preset) { PerformanceQualityPresetControl(fillsWidth: false) }
        SettingsRow(Self.frameRateLimit) { PerformanceFrameRateControl() }
        SettingsRow(
          Self.renderScale,
          note: performance.canChangeRenderScale
            ? nil : L("Not applicable to the wallpapers currently running")
        ) {
          SettingsMenuControl(
            key: "renderScale", saved: performance.quality.preferredRenderScale,
            options: performance.renderScaleChoices.map {
              SettingsMenuOption(value: $0.scale, title: $0.title)
            }, isEnabled: performance.canChangeRenderScale
          ) { try await controller.setRenderScale(Double($0)) }
        }
        if let effective = performance.quality.effectiveNowText {
          SettingsRow(Self.renderScaleEffective) {
            SettingsStatusText(text: effective) {
              // A condition's Reduced quality is chosen under Playback & Power, not on this page.
              if performance.quality.cause != nil {
                Button(SettingsSection.playback.openTitle) {
                  controller.settings.select(.playback)
                }
                .controlSize(.small)
              }
            }
          }
        }
        SettingsRow(Self.sceneResolution) {
          SettingsMenuControl(
            key: "sceneResolution", saved: performance.sceneResolution,
            options: SceneResolutionMode.allCases.map {
              SettingsMenuOption(value: $0, title: $0.title)
            }
          ) { try await controller.setSceneResolution($0) }
        }
      }
      SettingsGroupDisclosure(Self.advanced) {
        videoGroup(performance)
        sceneGroup(performance)
        experimentalGroup(performance)
      }
    }
  }

  // MARK: Advanced

  private func videoGroup(_ performance: PerformanceSettings) -> some View {
    SettingsGroup(Self.video, in: .performance) {
      SettingsDisclosure(Self.videoDiagnostics) {
        SettingsRow(Self.videoInUse, stacked: true) {
          report(performance.videoBackends.map(\.line), empty: "No video wallpaper is running.")
        }
      }
    }
  }

  private func sceneGroup(_ performance: PerformanceSettings) -> some View {
    SettingsGroup(Self.scene, in: .performance) {
      SettingsRow(Self.sceneOptimization, note: optimisationNote(performance)) {
        SettingsSwitchControl(key: .sceneOptimization)
      }
      SettingsRow(Self.sceneOnDemand) { SettingsSwitchControl(key: .sceneOnDemand) }
      SettingsDisclosure(Self.sceneDiagnostics) {
        SettingsRow(Self.sceneDrawnBy, stacked: true) {
          report(
            performance.sceneRenderers.map(\.line),
            empty: "No scene wallpaper is running.")
        }
        if let text = performance.optimization.text {
          SettingsRow(Self.sceneInForce, stacked: true) { Text(verbatim: text).font(.system(size: 12.5)) }
        }
        SettingsRow(Self.sceneUpdating, stacked: true) { updating(performance.sceneUpdates) }
      }
      SettingsDisclosure(Self.sceneCompatibility) {
        SettingsProse {
          Text(
            "Native Metal is the only scene renderer. It draws a scene only if it supports everything in it: image layers, sprite-sheet animation, 2D puppets with their own skinning shader, 2D sprite, sprite-trail, rope and rope-trail particles, 3D models, perspective cameras, scene lights, standard effect chains and post-processing, effects that read the previous frame, layer links, and BGRA, 8-bit NV12 or 10-bit video textures (HDR video is tone mapped to SDR). This applies to the lock screen and screen saver too."
          )
          Text(
            "A scene it can't draw is not drawn at all: it keeps its last picture, or its preview when it has drawn nothing yet, and the reason appears under “Drawn by”."
          )
        }
      }
    }
  }

  private func experimentalGroup(_ performance: PerformanceSettings) -> some View {
    SettingsGroup(Self.experimental, in: .performance) {
      SettingsRow(Self.videoPlaneSampling) {
        SettingsSwitchControl(key: .sceneVideoPlaneSampling)
      }
    }
  }

  // MARK: Pieces

  /// The note of Scene render optimisation, which says more while a running scene is drawn, the only
  /// time it is true of anything.
  private func optimisationNote(_ performance: PerformanceSettings) -> String? {
    guard performance.nativeSceneRunning else { return nil }
    return L(
      "Skips rendering work that wouldn’t change the picture, such as parts of a scene that stay the same. Resolution, frame rate and animation speed are unaffected. Turn it off to compare."
    ) + " "
      + L(
        "How much can be skipped depends on the scene. If everything in it moves, nothing is skipped."
      )
  }

  /// One line for each running wallpaper, or the words for none.
  @ViewBuilder
  private func report(_ lines: [String], empty: LocalizedStringKey) -> some View {
    if lines.isEmpty {
      Text(empty).font(.system(size: 12.5)).foregroundStyle(theme.surface.muted.color)
    } else {
      VStack(alignment: .leading, spacing: 4) {
        ForEach(lines.indices, id: \.self) { index in
          Text(verbatim: lines[index]).font(.system(size: 12.5))
        }
      }
      .accessibilityElement(children: .contain)
    }
  }

  /// What each running scene's update loop is doing. A scene that stopped after a failure has Retry,
  /// which loads its wallpaper again on its display; it waits for the reload, so it is never pressed
  /// twice.
  @ViewBuilder
  private func updating(_ reports: [SceneUpdateReport]) -> some View {
    if reports.isEmpty {
      Text("No scene wallpaper is running.")
        .font(.system(size: 12.5)).foregroundStyle(theme.surface.muted.color)
    } else {
      VStack(alignment: .leading, spacing: 6) {
        ForEach(reports) { report in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: report.line).font(.system(size: 12.5))
              .frame(maxWidth: .infinity, alignment: .leading)
            if report.canRetry {
              let name = "sceneRetry:\(report.displayID)"
              SettingsActionButton(
                "Retry", isDisabled: controller.settings.isLocked(name, whileRunning: true)
              ) {
                controller.settings.perform(name) {
                  try await controller.retryScene(onPhysicalDisplay: report.displayID)
                }
              }
            }
          }
        }
      }
      .accessibilityElement(children: .contain)
    }
  }
}
