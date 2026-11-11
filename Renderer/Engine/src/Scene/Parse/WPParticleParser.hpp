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

/// One collision capsule of a linked model: the segment from `a` to `b` and a
/// radius around it, in scene coordinates.
struct ParticleCapsule {
    linalg::Vector3d a { 0.0, 0.0, 0.0 };
    linalg::Vector3d b { 0.0, 0.0, 0.0 };
    double           radius { 0.0 };
};

/// What a `collisionmodel` operator collides with: the capsules of the layer
/// the scene object links to it. The scene parser installs `fill` once the
/// link resolves; until then (or without a link) the operator does nothing.
struct ParticleCollisionModelSource {
    std::function<void(std::vector<ParticleCapsule>&)> fill;
    std::vector<ParticleCapsule>                        capsules; // reused every step
};

struct ParticleLayerImageSource;
struct ParticleLayerImageLink {
    std::shared_ptr<ParticleLayerImageSource> source;
};

/// The layers one particle file's records link to, in the order Wallpaper Engine
/// pushes them while it loads the file (emitters, then operators): a record's
/// position here is the `index` a scene object's `dependencies[]` entry names it by,
/// together with its `type` ("emitterimage", "collisionmodel"; sub_14022AF30).
struct ParticleLayerLinks {
    enum class Kind { EmitterImage, CollisionModel };
    struct Slot {
        Kind                                          kind;
        std::shared_ptr<ParticleCollisionModelSource> model;
        std::shared_ptr<ParticleLayerImageLink> image;
    };
    std::vector<Slot> slots;
};

/// Everything the generators of one particle file read besides their own JSON.
struct ParticleParseContext {
    /// The scene object's override (speed, size, colour, ...); never null for
    /// operators, optional for the rest.
    std::shared_ptr<const wpscene::ParticleInstanceoverride> over;
    /// What spawn-time initializers read (control points, system time, event parent).
    std::shared_ptr<const ParticleSpawnContext> spawn;
    /// Only remap destinations use this mutable view; readers keep their const span.
    std::span<ParticleControlpoint> writable_controlpoints;
    ParticleColorDefinition                     color;
    /// Whether the scene object's `instanceoverride.speed` reaches the records
    /// that scale with it. A particle file that sets the "ignore speed
    /// override" flag keeps it out of all of them.
    bool                                        speed_override { true };
    /// Whether the scene object's `instanceoverride.size` reaches the records
    /// that scale with it: the size draw and every `sizechange` ramp. A file that
    /// sets the "ignore size override" flag keeps it out of all of them.
    bool                                        size_override { true };
    /// File flags 8 / 32 / 64 clear these: the override colour (and its
    /// brightness), count and lifetime then reach none of the file's records.
    bool                                        colour_override { true };
    bool                                        count_override { true };
    bool                                        lifetime_override { true };
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
    /// The file's layer links; records that link to a layer append themselves.
    /// Null when nothing resolves links (the record then stays inert).
    std::shared_ptr<ParticleLayerLinks>           links;
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
                       std::shared_ptr<ParticleSpawnContext>         spawn               = nullptr,
                       std::shared_ptr<ParticleLayerLinks> links = nullptr);
    static ParticleInitOp
        genOverrideInitOp(std::shared_ptr<const wpscene::ParticleInstanceoverride>,
                          ParticleColorDefinition color = {}, bool speed_override = true,
                          bool size_override = true, bool tint_after_retint = true,
                          bool colour_override = true);

    /// Finds the colour a file's initializers and operators produce, for
    /// measuring an instance colour override against.
    static ParticleColorDefinition
    analyzeColorSources(const std::vector<nlohmann::json>& initializers,
                        const std::vector<nlohmann::json>& operators);
};
} // namespace wallpaper
