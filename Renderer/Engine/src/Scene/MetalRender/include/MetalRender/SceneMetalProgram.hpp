#pragma once

#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace wallpaper
{

/// Everything the optional plane-sampling variant of one program needs to be
/// compiled later, captured while the parser still holds it.
///
/// Opaque here on purpose. It is made of parser types -- the preprocessed
/// units, the combos, the texture info -- which the renderer has no business
/// knowing; it only ever passes the pointer back. Owning it by shared pointer
/// is what gives the background compile an input with a lifetime of its own:
/// the parser, its virtual file system and the project it read are all long
/// gone by the time a user turns the setting on.
struct SceneMetalVariantInputs;

/// Where one program's optional variant has got to.
///
/// `None` is the resting state and the one every program is in while the
/// feature is off: nothing has been asked for, so nothing has been spent.
/// `Pending` means a compile is in flight and the ordinary program is drawing
/// meanwhile -- never that the wallpaper is waiting for anything.
enum class SceneMetalVariantState : uint8_t
{
    None = 0,
    Pending = 1,
    Ready = 2,
    Failed = 3,
};

/// Metal argument-table namespace a shader resource is bound into.
///
/// Metal keeps buffers, textures and samplers in independent index spaces, so a
/// slot number only means something together with the space it belongs to.
enum class SceneMetalSlotKind : uint8_t
{
    Buffer = 0,
    Texture = 1,
    Sampler = 2,
};

enum class SceneMetalStageKind : uint8_t
{
    Vertex = 0,
    Fragment = 1,
};

/// One shader resource and the Metal argument-table slot it was translated to.
///
/// `name` is the original GLSL global name (`g_Texture0`), which is what the
/// reflection payload and the material's texture list use. It is deliberately
/// not the identifier that appears in the generated Metal source: the shader
/// backend appends a trailing underscore on collisions, so matching on source
/// text would silently miss exactly the shaders that collided.
struct SceneMetalBinding
{
    std::string        name;
    uint32_t           set { 0 };
    uint32_t           binding { 0 };
    SceneMetalSlotKind slot_kind { SceneMetalSlotKind::Buffer };
    uint32_t           slot { 0 };
};

struct SceneMetalStage
{
    SceneMetalStageKind            kind { SceneMetalStageKind::Vertex };
    std::string                    source;
    /// The generated entry-point function name. The shader backend renames
    /// entry points, so this is never assumed to be `main`.
    std::string                    entry_point;
    std::string                    language_version;
    std::vector<SceneMetalBinding> bindings;
};

/// Metal Shading Language translation of one material's shader program.
///
/// Attached to `SceneShader` by the parser, which is the only place that still
/// holds the final combos, the preprocessed units and the texture info the
/// settling compile ran with. A null `metal_program` on a shader therefore
/// means "translation was never attempted", which is a different answer from
/// "translation was attempted and failed" and has to stay distinguishable: the
/// first is what a scene looks like until its pending translations are
/// flushed, and reporting it as a translation failure would accuse the
/// author's shader of a fault it does not have.
/// The same author program, translated to sample one video slot as NV12 luma
/// and chroma planes instead of one pre-converted image.
///
/// This is a second program, not an edit of the first: it has its own stages,
/// its own reflection and its own resource layout, and the renderer selects
/// between the two per frame from the format the decoder actually produced. It
/// is produced only where the translation is exact; `error` records why it was
/// not, and a scene whose variant failed simply keeps converting, which is the
/// behaviour every Metal scene had before this existed.
struct SceneMetalVideoPlaneVariant
{
    std::vector<SceneMetalStage> stages;
    std::string                  reflection_json;
    /// Material texture slot this variant samples as planes.
    uint32_t                     slot { 0 };
    /// Non-empty when the variant was attempted and could not be produced.
    std::string                  error;

    [[nodiscard]] bool ok() const
    {
        return error.empty() && ! stages.empty() && ! reflection_json.empty();
    }
};

struct SceneMetalProgram
{
    std::vector<SceneMetalStage> stages;
    /// The reflection payload: uniform block
    /// layout, vertex inputs and active texture slots. Kept as the raw
    /// document so this type stays free of JSON dependencies.
    std::string reflection_json;
    /// Non-empty when translation was attempted and failed. The scene still
    /// loads and still draws; only the native backend is refused.
    std::string error;
    /// What the optional variant would be compiled from, or null when this
    /// material has no candidate video slot at all. Present does not mean
    /// requested: nothing is compiled until something asks.
    std::shared_ptr<const SceneMetalVariantInputs> video_plane_inputs;

    [[nodiscard]] bool ok() const
    {
        return error.empty() && ! stages.empty() && ! reflection_json.empty();
    }

    /// Whether a variant could ever exist for this program.
    [[nodiscard]] bool hasVideoPlaneCandidate() const
    {
        return video_plane_inputs != nullptr;
    }

    [[nodiscard]] SceneMetalVariantState videoPlaneState() const
    {
        const std::lock_guard lock { m_video_plane_mutex };
        return m_video_plane_state;
    }

    /// The compiled variant, or null while there is none. Safe to call from the
    /// render thread at any time: it takes a copy of the pointer, so a compile
    /// finishing mid-frame cannot pull the program out from under a draw.
    [[nodiscard]] std::shared_ptr<const SceneMetalVideoPlaneVariant> videoPlanes() const
    {
        const std::lock_guard lock { m_video_plane_mutex };
        return m_video_planes;
    }

    /// Claims the right to compile this program's variant, once.
    ///
    /// False means somebody already has it, or it is already decided. Two
    /// surfaces showing the same wallpaper therefore compile it once between
    /// them rather than once each.
    [[nodiscard]] bool claimVideoPlaneCompile() const
    {
        const std::lock_guard lock { m_video_plane_mutex };
        if (video_plane_inputs == nullptr) return false;
        if (m_video_plane_state != SceneMetalVariantState::None) return false;
        m_video_plane_state = SceneMetalVariantState::Pending;
        return true;
    }

    /// Gives a claim back without deciding anything.
    ///
    /// For work that was queued and then dropped before it ran: the program
    /// returns to its resting state, so asking again later is allowed. A
    /// compile that actually ran reports its result instead, failure included,
    /// which is what stops a hopeless variant from being retried every frame.
    void releaseVideoPlaneClaim() const
    {
        const std::lock_guard lock { m_video_plane_mutex };
        if (m_video_plane_state == SceneMetalVariantState::Pending) {
            m_video_plane_state = SceneMetalVariantState::None;
        }
    }

    /// Records the compile's result. A variant that failed is remembered as
    /// failed, so the same condition is never retried in a loop.
    void publishVideoPlanes(std::shared_ptr<const SceneMetalVideoPlaneVariant> variant) const
    {
        const std::lock_guard lock { m_video_plane_mutex };
        const bool usable    = variant != nullptr && variant->ok();
        m_video_planes       = std::move(variant);
        m_video_plane_state =
            usable ? SceneMetalVariantState::Ready : SceneMetalVariantState::Failed;
    }

private:
    mutable std::mutex                                        m_video_plane_mutex;
    mutable SceneMetalVariantState                            m_video_plane_state {
        SceneMetalVariantState::None
    };
    mutable std::shared_ptr<const SceneMetalVideoPlaneVariant> m_video_planes;
};

} // namespace wallpaper
