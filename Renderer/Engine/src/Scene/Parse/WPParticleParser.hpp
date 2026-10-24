#pragma once
#include "Particle/ParticleEmitter.h"
#include "wpscene/WPParticleObject.h"
#include "Audio/AudioResponseService.h"

#include <memory>

namespace wallpaper
{
/// The colour a particle file produces on its own, which an instance's colour
/// override is measured against.
struct ParticleColorDefinition {
    /// Representative colour of the file (the last colour source found), in 0-1.
    linalg::Vector3f defaultColor { 1.0f, 1.0f, 1.0f };
    /// Whether any colour initializer or colour operator exists. A file without
    /// one takes the override colour as a plain tint.
    bool hasColor { false };
};

/// Everything the generators of one particle file read besides their own JSON.
struct ParticleParseContext {
    /// The scene object's override (speed, size, colour, ...); never null for
    /// operators, optional for the rest.
    std::shared_ptr<const wpscene::ParticleInstanceoverride> over;
    /// What spawn-time initializers read (control points, system time, event parent).
    std::shared_ptr<const ParticleSpawnContext> spawn;
    ParticleColorDefinition                     color;
    /// Whether the scene object's `instanceoverride.speed` reaches the records
    /// that scale with it. A particle file that sets the "ignore speed
    /// override" flag keeps it out of all of them.
    bool                                        speed_override { true };
    /// Whether the scene object's `instanceoverride.size` reaches the records
    /// that scale with it: the size draw and every `sizechange` ramp. A file that
    /// sets the "ignore size override" flag keeps it out of all of them.
    bool                                        size_override { true };
    /// Whether the scene has a pixel canvas (an orthogonal projection with a size).
    /// Wallpaper Engine fills a key a file leaves out with different numbers
    /// in a pixel scene and in a 3D scene.
    bool                                        ortho { true };
    /// Whether a re-tinted preset is multiplied by the override colour as well:
    /// true for scenes saved before version 5 (WPScene::kRetintOnlyVersion).
    bool                                        tint_after_retint { true };
    /// Audio source and the scene's "needs audio" mark for operators and
    /// initializers that carry `audioprocessing*` keys.
    std::function<audio::AudioSpectrumSnapshot()> spectrum;
    std::function<void()>                         requires_audio;
};

class WPParticleParser {
public:
    static ParticleInitOp genParticleInitOp(const nlohmann::json&);
    static ParticleInitOp genParticleInitOp(const nlohmann::json&, const ParticleParseContext&);
    static ParticleOperatorOp
    genParticleOperatorOp(const nlohmann::json&,
                          std::shared_ptr<const wpscene::ParticleInstanceoverride>);
    static ParticleOperatorOp genParticleOperatorOp(const nlohmann::json&,
                                                    const ParticleParseContext&);
    static ParticleEmittOp
    genParticleEmittOp(const wpscene::Emitter&, bool sort = false,
                       std::shared_ptr<const wpscene::ParticleInstanceoverride> override = nullptr,
                       std::function<audio::AudioSpectrumSnapshot()> audio_spectrum      = {},
                       std::shared_ptr<ParticleSpawnContext>         spawn               = nullptr);
    static ParticleInitOp
        genOverrideInitOp(std::shared_ptr<const wpscene::ParticleInstanceoverride>,
                          ParticleColorDefinition color = {}, bool speed_override = true,
                          bool size_override = true, bool tint_after_retint = true);

    /// Finds the colour a file's initializers and operators produce, for
    /// measuring an instance colour override against.
    static ParticleColorDefinition
    analyzeColorSources(const std::vector<nlohmann::json>& initializers,
                        const std::vector<nlohmann::json>& operators);
};
} // namespace wallpaper
