#pragma once

namespace wallpaper
{

/// Shadow and volumetric quality. The numbers are Wallpaper Engine's
/// (wallpaper64.exe sub_14010DF40 / sub_14010DAD0: "disabled" 0, "low" 1,
/// any other word 2, "high" 3, "ultra" 4).
enum class QualityLevel : int { Off = 0, Low = 1, Medium = 2, High = 3, Ultra = 4 };

/// Post-processing level: WE's UI words disabled / enabled / ultra / displayhdr.
/// sub_14010DF40: "disabled" = no bloom, "ultra" = HDR bloom, "displayhdr" = HDR
/// bloom on an HDR display, any other word = LDR bloom ("enabled").
enum class PostProcessing : int { Disabled = 0, Enabled = 2, Ultra = 4, DisplayHdr = 5 };

/// The scene quality settings (plan decision I1). A change reloads the scene.
/// Defaults are Wallpaper Engine's first-run "medium" preset (ui-scripts.js
/// getQualityPreset; the welcome dialog sets qualityPreset = "medium").
struct SceneQuality {
    int  msaa { 0 }; // 0, 2, 4 or 8 samples
    int  shadows { static_cast<int>(QualityLevel::Medium) };
    int  volumetrics { static_cast<int>(QualityLevel::Medium) };
    bool reflection { true };
    int  post_processing { static_cast<int>(PostProcessing::Enabled) };

    bool operator==(const SceneQuality&) const = default;
};

} // namespace wallpaper
