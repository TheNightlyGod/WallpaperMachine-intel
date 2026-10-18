#pragma once
#include <cstdint>
#include <vector>
#include <string>
#include <string_view>
#include <memory>
#include <span>
#include <array>
#include <optional>
#include <Eigen/Geometry>

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
        Eigen::Affine3f local_bind { Eigen::Affine3f::Identity() };
        // Character-sheet bind geometry and assembled animation reference pose differ.
        Eigen::Affine3f local_reference { Eigen::Affine3f::Identity() };
        bool has_local_reference { false };
        Eigen::Vector3f reference_position { Eigen::Vector3f::Zero() };
        Eigen::Vector3f reference_scale { Eigen::Vector3f::Ones() };
        Eigen::Quaterniond reference_rotation { Eigen::Quaterniond::Identity() };
        // Local dump/schema compatibility mirror. Runtime hierarchy follows
        // upstream's bind_parent/anim_parent/file_parent fields below.
        uint32_t        parent { NO_PARENT };
        uint32_t        bind_parent { NO_PARENT };
        uint32_t        anim_parent { NO_PARENT };
        uint32_t        file_parent { NO_PARENT };
        std::string     simulation_json;

        bool noParent() const { return parent == NO_PARENT; }
        bool noBindParent() const { return bind_parent == NO_PARENT; }
        bool noAnimParent() const { return anim_parent == NO_PARENT; }
        // prepared
        Eigen::Affine3f offset_trans { Eigen::Affine3f::Identity() };
        Eigen::Affine3f world_bind { Eigen::Affine3f::Identity() };
        Eigen::Affine3f inv_bind { Eigen::Affine3f::Identity() };
        Eigen::Vector3f vertex_centroid_offset { 0.0f, 0.0f, 0.0f };
        Eigen::Vector3f file_skin_pivot { 0.0f, 0.0f, 0.0f };
        Eigen::Matrix4f file_skin_mat { Eigen::Matrix4f::Identity() };
        bool            has_file_skin_pivot { false };
        Eigen::Affine3f file_world_bind { Eigen::Affine3f::Identity() };
        bool            has_file_world_bind { false };
        /*
        Eigen::Vector3f world_axis_x;
        Eigen::Vector3f world_axis_y;
        Eigen::Vector3f world_axis_z;
        */
    };
    struct Attachment {
        uint16_t        bone_index { 0 };
        std::string     name;
        Eigen::Affine3f local_xform { Eigen::Affine3f::Identity() };
    };
    struct BoneFrame {
        Eigen::Vector3f position;
        Eigen::Vector3f angle;
        Eigen::Vector3f scale;

        // prepared
        Eigen::Quaterniond quaternion;
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

        uint32_t unk_after_id { 0 };
        std::optional<AnimTrans>    trans;
        std::vector<BoneFrameCurve> blend_curves;
        std::vector<AnimV4Event>    v4_events;
        std::array<float, 3>        aabb_min {};
        std::array<float, 3>        aabb_max {};
        bool                        has_aabb { false };
        std::vector<BoneFrameCurve> scalar_curves;
        std::vector<AnimEvent>      events;

        // prepared
        double max_time;
        double frame_time;
        struct InterpolationInfo {
            idx    frame_a;
            idx    frame_b;
            double t;
        };
        InterpolationInfo getInterpolationInfo(double* cur_time) const;
    };
    struct BoneDir {
        uint32_t             bone_id { 0 };
        std::array<float, 3> dir {};
    };
    struct ChainBoneDir {
        uint16_t             chain_id { 0 };
        uint32_t             bone_id { 0 };
        std::array<float, 3> dir {};
    };
    struct BoneCond {
        uint16_t cnt { 0 };
        uint32_t id { 0 };
        uint32_t child { 0 };
        uint32_t val { 0 };
    };
    struct IkConfig {
        Eigen::Matrix4f                         chain_a_target { Eigen::Matrix4f::Identity() };
        uint8_t                                 ik_version { 0 };
        std::array<uint32_t, 2>                 ik_header {};
        Eigen::Matrix4f                         chain_b_target { Eigen::Matrix4f::Identity() };
        std::array<uint8_t, 7>                  ik_flags {};
        std::array<Eigen::Vector3f, 6>          pole_targets {};
        std::vector<BoneDir>                    rest_rotations;
        std::vector<ChainBoneDir>               ik_targets;
        std::optional<BoneDir>                  ik_target_root;
        BoneCond                                ik_constraint {};
        std::array<std::vector<uint32_t>, 2>    ik_bone_lists;
        uint32_t                                ik_chain_count { 0 };
        std::array<float, 2>                    ik_chain_length {};
        std::vector<uint32_t>                   ik_chain_bones;
    };

public:
    std::vector<Bone>      bones;
    std::vector<Animation> anims;
    std::vector<Attachment> attachments;
    std::optional<IkConfig> ik_config;
    bool world_anchored_bones { false };

    void prepared();

private:
    friend class WPPuppetLayer;
    void evaluatePose(const WPPuppetLayer&, std::span<Eigen::Affine3f>) const noexcept;
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

    bool hasPuppet() const { return (bool)m_puppet; };

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

    std::span<const Eigen::Affine3f> genFrame(double time) noexcept;

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

        operator bool() const noexcept { return anim != nullptr; };
    };
    struct State {
        double m_global_blend { 1.0 };
        double m_total_blend { 0.0 };
        double m_last_elapsed { -1.0 };

        std::vector<Layer> m_layers;
        std::vector<i32>   m_finished_layers;
        std::vector<Eigen::Affine3f> m_final_affines;
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
