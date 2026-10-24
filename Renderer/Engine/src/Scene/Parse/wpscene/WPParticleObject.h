#pragma once
#include "WPJson.hpp"
#include "WPMaterial.h"
#include <nlohmann/json.hpp>
#include <vector>
#include <array>
#include <map>
#include "Utils/BitFlags.hpp"
#include "Core/Literals.hpp"

namespace wallpaper
{
namespace fs
{
class VFS;
}
namespace wpscene
{

class ParticleControlpoint {
public:
    enum class FlagEnum
    {
        link_mouse = 0,
        worldspace = 1,
    };
    using EFlags = BitFlags<FlagEnum>;

    bool                 FromJson(const nlohmann::json&);
    EFlags               flags { 0 };
    i32                  id { -1 };
    std::array<float, 3> offset { 0, 0, 0 };
};

class ParticleRender {
public:
    bool        FromJson(const nlohmann::json&);
    std::string name;
    float       length { 0.05f };
    float       maxlength { 10.0f };
    /// Points added between two connected particles (rope) or two recorded
    /// trail points (rope trail); each pair is then drawn as one more piece
    /// than this. A whole number in 0..32: Wallpaper Engine truncates the
    /// value it reads and clamps it.
    float       subdivision { 4.0f };
    float       minlength { 0.0f };
    /// Rope trail only: how many recorded segments a trail holds, 2..32.
    float       segments { 4.0f };
    float       uvscale { 1.0f };
    bool        uvscrolling { false };
    bool        uvsmoothing { false };
    nlohmann::json uvscale_setting;
    nlohmann::json uvscrolling_setting;
    nlohmann::json uvsmoothing_setting;
};

class Initializer {
public:
    bool                 FromJson(const nlohmann::json&);
    std::array<float, 3> max { 0, 0, 0 };
    std::array<float, 3> min { 0, 0, 0 };
    std::string          name;
};

class Emitter {
public:
    enum class FlagEnum : uint32_t
    {
        one_per_frame = 1,
        // Emit in windows separated by pauses (flags & 4).
        periodic = 2,
    };
    using EFlags = BitFlags<FlagEnum>;

public:
    bool                   FromJson(const nlohmann::json&);
    std::array<float, 3>   directions { 1.0f, 1.0f, 0.0f };
    std::array<float, 3>   distancemax { 256.0f, 256.0f, 256.0f };
    std::array<float, 3>   distancemin { 0.0f, 0.0f, 0.0f };
    std::array<float, 3>   origin { 0, 0, 0 };
    std::array<int32_t, 3> sign { 0, 0, 0 };
    u32                    instantaneous { 0 };
    float                  speedmin { 0 };
    float                  speedmax { 0 };
    u32                    audioprocessingmode { 0 };
    // What the audio-processing keys read when a particle file leaves them out.
    std::array<float, 2> audioprocessingbounds { 0.8f, 1.0f };
    float                audioprocessingexponent { 2.0f };
    i32                  audioprocessingfrequencystart { 0 };
    i32                  audioprocessingfrequencyend { 1 };
    i32                  controlpoint { 0 };
    i32                  id;
    EFlags               flags;
    // Timing keys; zero is Wallpaper Engine's default for each.
    float                delay { 0.0f };
    float                duration { 0.0f };
    float                minperiodicduration { 0.0f };
    float                maxperiodicduration { 0.0f };
    float                minperiodicdelay { 0.0f };
    float                maxperiodicdelay { 0.0f };
    u32                  maxtoemitperperiod { 0 };
    // sphererandom only: 0 is the whole sphere, 1 a single direction.
    float                cone { 0.0f };
    std::string          name;
    float                rate { 5.0f };
};

class ParticleChild;
class Particle {
public:
    enum class FlagEnum
    {
        wordspace             = 0,
        spritenoframeblending = 1,
        perspective           = 2,
        // The file keeps the scene object's `instanceoverride.speed` away from
        // its emitters, movement, turbulence, vortex, control point attraction
        // and position oscillation (the editor's "ignore speed override").
        ignorespeedoverride   = 4,
        // The file keeps the scene object's `instanceoverride.size` away from its
        // `sizerandom` draws and its `sizechange` ramps (the editor's "ignore size
        // override").
        ignoresizeoverride    = 7,
    };
    using EFlags = BitFlags<FlagEnum>;

public:
    bool FromJson(const nlohmann::json&, fs::VFS&);

    /// Whether the scene object's speed override reaches this file's
    /// speed-driven records.
    bool AppliesSpeedOverride() const { return ! flags[FlagEnum::ignorespeedoverride]; }

    /// Whether the scene object's size override reaches this file's size
    /// records: the size draw and every size ramp.
    bool AppliesSizeOverride() const { return ! flags[FlagEnum::ignoresizeoverride]; }

    std::vector<Emitter>              emitters;
    std::vector<nlohmann::json>       initializers;
    std::vector<nlohmann::json>       operators;
    /// The `renderer` list. A file that leaves the key out (or holds anything
    /// but an array there) gets one default sprite renderer, as Wallpaper
    /// Engine appends one; an array the file wrote empty stays empty, and such
    /// a system simulates (its particles still spawn children) but draws nothing.
    std::vector<ParticleRender>       renderers;
    std::vector<ParticleControlpoint> controlpoints;

    WPMaterial material;

    std::vector<ParticleChild> children;

    std::string animationmode;
    /// Whether a sprite sheet cross-fades a frame into the next. A `randomframe`
    /// particle shows one frame picked at random, so it never does, as Wallpaper
    /// Engine treats it as if the file had set the no-blending flag.
    bool BlendsSpriteFrames() const {
        return ! flags[FlagEnum::spritenoframeblending] && animationmode != "randomframe";
    }
    float       sequencemultiplier { 1.0f };
    uint32_t    maxcount { 1 };
    /// Seconds the system is simulated for before its first frame.
    float       starttime { 0.0f };
    EFlags      flags { 0 };
};
class ParticleChild {
public:
    bool FromJson(const nlohmann::json&, fs::VFS&);

    std::string type { "static" };
    std::string name;
    i32         maxcount { 20 };

    i32   controlpointstartindex { 0 };
    float probability { 1.0f };

    std::array<float, 3> angles { 0, 0, 0 };
    std::array<float, 3> origin { 0, 0, 0 };
    std::array<float, 3> scale { 1.0f, 1.0f, 1.0f };

    Particle obj;
};

class ParticleInstanceoverride {
public:
    bool FromJosn(const nlohmann::json&);
    bool enabled { false };
    bool overColor { false };
    bool overColorn { false };
    int32_t id { 0 };

    float                alpha { 1.0f };
    float                count { 1.0f };
    float                lifetime { 1.0f };
    float                rate { 1.0f };
    float                speed { 1.0f };
    float                size { 1.0f };
    std::array<float, 3> color { 1.0f, 1.0f, 1.0f };
    std::array<float, 3> colorn { 1.0f, 1.0f, 1.0f };
    /// Multiplies the colour tint, in a scene that renders HDR (`hdr` below).
    float                brightness { 1.0f };
    /// Set by the scene parser from the scene's own HDR switch. Brightness has
    /// no effect without it.
    bool                 hdr { false };
    /// `controlpoint0`..`controlpoint7`: where the scene puts the control point
    /// instead of the preset's own offset. Unset keys leave the preset alone.
    std::array<bool, 8>                  controlpointSet {};
    std::array<std::array<float, 3>, 8>  controlpoint {};
    /// `controlpointangle0`..`7`: Euler angles in radians (x, y, z).
    std::array<bool, 8>                  controlpointangleSet {};
    std::array<std::array<float, 3>, 8>  controlpointangle {};
    std::map<std::string, std::string> bindings;
};

class WPParticleObject {
public:
    bool                     FromJson(const nlohmann::json&, fs::VFS&);
    int32_t                  id;
    int32_t                  parent_id { -1 };
    std::string              name;
    std::array<float, 3>     origin { 0.0f, 0.0f, 0.0f };
    std::array<float, 3>     scale { 1.0f, 1.0f, 1.0f };
    std::array<float, 3>     angles { 0.0f, 0.0f, 0.0f };
    // Wallpaper Engine's default for an object that leaves the key out.
    std::array<float, 2>     parallaxDepth { 1.0f, 1.0f };
    bool                     visible { true };
    // True when a script or property drives the value; the setting below is then bound.
    bool dynamic_origin { false };
    bool dynamic_visible { false };

    // The settings as authored, whole.
    nlohmann::json origin_setting;
    nlohmann::json scale_setting;
    nlohmann::json angles_setting;
    nlohmann::json visible_setting;

    std::string              particle;           // path of the particle file
    Particle                 particleObj;        // that file, parsed
    ParticleInstanceoverride instanceoverride;
    std::vector<int32_t>     dependencies;
    nlohmann::json           field_bindings;
};

// JSON round trips (from_json throws on a missing key; the parsers never call it).
NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(
    Initializer,
    name,
    max,
    min);
NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(
    Emitter,
    name,
    distancemax,
    distancemin,
    rate,
    directions);
NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(
    Particle,
    initializers,
    operators,
    emitters);
NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(
    WPParticleObject,
    name,
    origin,
    angles,
    scale,
    visible,
    particle,
    particleObj);
} // namespace wpscene
} // namespace wallpaper
