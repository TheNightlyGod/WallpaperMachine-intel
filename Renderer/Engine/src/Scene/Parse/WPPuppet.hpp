#pragma once
#include <cstdint>
#include <vector>
#include <string>
#include <string_view>
#include <memory>
#include <span>
#include <array>
#include <optional>
#include "Utils/Linalg.hpp"

#include "Core/Literals.hpp"

namespace wallpaper
{

class WPPuppetLayer;

class WPPuppet {
public:
    enum class PlayMode
    {
        Loop,
        Mirror,
        Single
    };
    static constexpr uint32_t NO_PARENT = 0xFFFFFFFFu;

    struct Bone {
        static constexpr uint32_t NO_PARENT { WPPuppet::NO_PARENT };

        std::string     name;
        int32_t         sim_type { 0 };
        linalg::Affine3f local_bind { linalg::Affine3f::Identity() };
        // Character-sheet bind geometry and assembled animation reference pose differ.
        linalg::Affine3f local_reference { linalg::Affine3f::Identity() };
        bool has_local_reference { false };
        linalg::Vector3f reference_position { linalg::Vector3f::Zero() };
        linalg::Vector3f reference_scale { linalg::Vector3f::Ones() };
        linalg::Quaterniond reference_rotation { linalg::Quaterniond::Identity() };
        // Parent bone indices as the skeleton, the bind pose and the animations each name them.
        uint32_t    parent { NO_PARENT };
        uint32_t    bind_parent { NO_PARENT };
        uint32_t    anim_parent { NO_PARENT };
        uint32_t    file_parent { NO_PARENT };  // the index the file itself stored
        std::string simulation_json;            // physics settings, left as text
        bool        noParent() const { return parent == NO_PARENT; }
        bool        noBindParent() const { return bind_parent == NO_PARENT; }
        bool        noAnimParent() const { return anim_parent == NO_PARENT; }
        linalg::Affine3f offset_trans { linalg::Affine3f::Identity() };
        linalg::Affine3f world_bind { linalg::Affine3f::Identity() };
        linalg::Affine3f inv_bind { linalg::Affine3f::Identity() };
        linalg::Vector3f vertex_centroid_offset { 0.0f, 0.0f, 0.0f };
        linalg::Vector3f file_skin_pivot { 0.0f, 0.0f, 0.0f };
        linalg::Matrix4f file_skin_mat { linalg::Matrix4f::Identity() };
        bool            has_file_skin_pivot { false };
        linalg::Affine3f file_world_bind { linalg::Affine3f::Identity() };
        bool            has_file_world_bind { false };
    };
    struct Attachment {
        uint16_t        bone_index { 0 };
        std::string     name;
        linalg::Affine3f local_xform { linalg::Affine3f::Identity() };
    };
    struct BoneFrame {
        linalg::Vector3f position;
        linalg::Vector3f angle;
        linalg::Vector3f scale;
        linalg::Quaterniond quaternion;
    };
    struct Animation {
        i32         id;
        double      fps;
        i32         length;
        PlayMode    mode;
        std::string name;

        struct BoneTrack {
            uint32_t               bone_index { 0 };
            int32_t                unk { 0 };
            std::vector<BoneFrame> frames;
        };
        std::vector<BoneTrack> bone_tracks;

        struct AnimTrans {
            std::vector<float> extra_track;
            std::vector<float> main_track;
        };
        struct BoneFrameCurve {
            std::vector<float> values;
        };
        struct AnimV4Event {
            float              time { 0.0f };
            uint32_t           flags { 0 };
            std::vector<float> values;
        };
        struct AnimEvent {
            uint32_t    time_value { 0 };
            std::string event_json;
        };

        uint32_t                 unk_after_id { 0 };  // a word of unknown use after the id
        std::optional<AnimTrans> trans;               // present only when the clip stores it
        // Keyframe curves and events, as the animation block of the file lists them.
        std::vector<BoneFrameCurve> blend_curves;
        std::vector<AnimV4Event>    v4_events;
        std::array<float, 3>        aabb_min {};
        std::array<float, 3>        aabb_max {};
        bool                        has_aabb { false };
        std::vector<BoneFrameCurve> scalar_curves;
        std::vector<AnimEvent>      events;

        double max_time;
        double frame_time;
        struct InterpolationInfo {
            idx    frame_a;
            idx    frame_b;
            double t;
        };
        InterpolationInfo getInterpolationInfo(double* cur_time) const;
    };
public:
    std::vector<Bone>      bones;
    std::vector<Animation> anims;
    std::vector<Attachment> attachments;
    bool world_anchored_bones { false };

    void prepared();

private:
    friend class WPPuppetLayer;
    void evaluatePose(const WPPuppetLayer&, std::span<linalg::Affine3f>) const noexcept;
};

// One puppet's animation-layer stack. Copies share playback state: the image
// node, its effect passes and its attachments each keep a copy, and a script
// or user property controlling one of them must move all of them together.
class WPPuppetLayer {
    friend class WPPuppet;

public:
    WPPuppetLayer();
    WPPuppetLayer(std::shared_ptr<WPPuppet>);
    ~WPPuppetLayer();

    bool hasPuppet() const { return m_puppet != nullptr; }

    struct AnimationLayer {
        i32         id { 0 };
        double      rate { 1.0f };
        double      blend { 1.0f };
        bool        visible { true };
        double      cur_time { 0.0f };
        i32         layer_id { 0 };
        std::string name;
        bool        additive { false };
        bool        blendin { false };
        bool        blendout { false };
        double      blendtime { 0.0 };
        // Authored layers start playing, matching the editor. A single-shot
        // animation stops at its last frame until play() restarts it.
        bool        playing { true };
    };

    void prepared(std::span<AnimationLayer>);

    std::span<const linalg::Affine3f> genFrame(double time) noexcept;

    // SceneScript IAnimationLayer surface. Layers resolve by authored name
    // first, then by stack index; -1 means no such layer.
    i32  findLayer(std::string_view name) const noexcept;
    usize layerCount() const noexcept;
    /// The authored name of the layer at `index`; empty for an unnamed layer or
    /// an index with no layer.
    std::string layerName(i32 index) const;
    bool play(i32 index) noexcept;
    bool pause(i32 index) noexcept;
    bool stop(i32 index) noexcept;
    bool isPlaying(i32 index) const noexcept;
    bool setFrame(i32 index, double frame) noexcept;
    double frame(i32 index) const noexcept;
    double frameCount(i32 index) const noexcept;
    double fps(i32 index) const noexcept;
    bool setRate(i32 index, double rate) noexcept;
    double rate(i32 index) const noexcept;
    bool setBlend(i32 index, double blend) noexcept;
    double blend(i32 index) const noexcept;
    bool setVisible(i32 index, bool visible) noexcept;
    bool visible(i32 index) const noexcept;
    // The layers whose single-shot animation has played out since the last call,
    // oldest first. A script's `addEndedCallback` is answered from this. The
    // record is shared by every copy, so any one of them can take it.
    std::vector<i32> takeFinishedLayers() noexcept;

private:
    struct Layer {
        AnimationLayer                         anim_layer;
        double                                 blend;
        const WPPuppet::Animation*             anim { nullptr };
        WPPuppet::Animation::InterpolationInfo interp_info {};
    };
    struct State {
        double m_global_blend { 1.0 };
        double m_total_blend { 0.0 };
        double m_last_elapsed { -1.0 };
        // False until the first evaluation: that one only records the scene time.
        bool   m_clock_started { false };

        std::vector<Layer> m_layers;
        std::vector<i32>   m_finished_layers;
        std::vector<linalg::Affine3f> m_final_affines;
        bool m_pose_valid { false };
        uint64_t m_pose_time_bits { 0 };
    };

    void   rebuildBlend() noexcept;
    void   updateInterpolation(double time) noexcept;
    void   invalidatePose() noexcept;
    Layer* layerAt(i32 index) noexcept;
    const Layer* layerAt(i32 index) const noexcept;

    std::shared_ptr<State>    m_state;
    std::shared_ptr<WPPuppet> m_puppet;
};

} // namespace wallpaper
