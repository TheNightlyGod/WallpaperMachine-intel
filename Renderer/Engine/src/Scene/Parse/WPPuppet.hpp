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
#include "WPPuppetMorph.hpp"

#include "Core/Literals.hpp"

namespace wallpaper
{

class WPPuppetLayer;
struct PuppetIkPlan;
struct PuppetIkState;
struct SceneForceState;

// One bone's simulation state, per puppet instance (Wallpaper Engine's 80-byte record at skeleton
// +952, B-D2): the angular velocity as a rotation per 1/60 s (w, x, y, z), the Euler offset the
// bone is turned by (x, y, z radians, Rz·Ry·Rx), the translation offset and its velocity, both in
// world units.
struct BonePhysicsState {
    std::array<double, 4> rotation_velocity { 1.0, 0.0, 0.0, 0.0 };
    std::array<double, 3> angles { 0.0, 0.0, 0.0 };
    std::array<double, 3> offset { 0.0, 0.0, 0.0 };
    std::array<double, 3> velocity { 0.0, 0.0, 0.0 };
};

class WPPuppet {
public:
    enum class PlayMode
    {
        Loop,
        Mirror,
        Single
    };
    static constexpr uint32_t NO_PARENT = 0xFFFFFFFFu;
    // Animation::flags bits (anim+80). kAnimClip: a clip record follows; without kAnimOwnFrames
    // the clip plays its source's frames from `start` on (0x14021c6be). The kRoot* bits are
    // the root-motion axes of sub_140225900: translation locked per axis, yaw extracted.
    static constexpr uint32_t kAnimClip        = 0x1u;
    static constexpr uint32_t kAnimOwnFrames   = 0x400u;
    static constexpr uint32_t kRootX           = 0x800u;
    static constexpr uint32_t kRootY           = 0x1000u;
    static constexpr uint32_t kRootZ           = 0x2000u;
    static constexpr uint32_t kRootYaw         = 0x8000u;
    static constexpr uint32_t kRootMotionMask  = 0x1F800u;

    // A bone's simulation settings, as we_ParseBoneSimulationJson 0x140265C30 reads them from the
    // JSON text after the bone's matrix into bone +104 (B-D2). Defaults are the bone constructor's
    // (sub_14026B860). Flag bits are Wallpaper Engine's.
    struct BoneSimulation {
        static constexpr uint32_t kSpring      = 0x1;       // se
        static constexpr uint32_t kRigid       = 0x2;       // re
        static constexpr uint32_t kGravity     = 0x4;       // ge
        static constexpr uint32_t kAngleLimit  = 0x8;       // la
        static constexpr uint32_t kTorqueLimit = 0x10;      // lt
        static constexpr uint32_t kIkGravity   = 0x20;      // ikg
        static constexpr uint32_t kIkRope      = 0x40;      // ikr
        static constexpr uint32_t kIkStretch   = 0x80;      // ikse
        static constexpr uint32_t kIkFreeEnd   = 0x100;     // ikfe
        static constexpr uint32_t kRotation    = 0x1000;    // r
        static constexpr uint32_t kTranslation = 0x2000;    // t
        static constexpr uint32_t kIk          = 0x4000;    // ik
        static constexpr uint32_t kIkChainEnd  = 0x8000;    // ikce
        // Set when rax / ray / raz (tax / tay / taz) is false: that axis is held.
        static constexpr uint32_t kHoldTurnX   = 0x100000;
        static constexpr uint32_t kHoldTurnY   = 0x200000;
        static constexpr uint32_t kHoldTurnZ   = 0x400000;
        static constexpr uint32_t kHoldMoveX   = 0x800000;
        static constexpr uint32_t kHoldMoveY   = 0x1000000;
        static constexpr uint32_t kHoldMoveZ   = 0x2000000;

        uint32_t         flags { 0 };
        float            rot_stiffness { 0.0f };    // rs, degrees a second per radian away
        float            trans_stiffness { 0.0f };  // ts
        float            rot_friction { 0.0f };     // rf
        float            trans_friction { 0.0f };   // tf (squared / 100^2 for an IK-only bone)
        float            rot_inertia { 1.0f };      // 1 - ri / 100
        float            trans_inertia { 1.0f };    // 1 - ti / 100
        linalg::Vector3f gravity { 0.0f, 0.0f, 0.0f }; // gd, world space
        float            mass { 1000.0f };          // m
        linalg::Vector3f tip { 0.0f, 0.0f, 0.0f };  // tp, bone space
        float            tip_length { 1.0f };       // |tp| / 100
        float            trans_max { 0.0f };        // tm
        linalg::Vector3f angle_min { 0.0f, 0.0f, 0.0f }; // lamin, radians
        linalg::Vector3f angle_max { 0.0f, 0.0f, 0.0f }; // lamax
        float            torque_max { 0.0f };       // ltmax, degrees a step
        int32_t          ik_depth { 2 };            // ikd, at least 1
        float            ik_rope_damping { 50.0f }; // ikrd: end-orientation distance, at least 1
        float            ik_rope_min_length { 0.0f }; // ikrminl: planar angle minimum, radians
        float            ik_rope_max_length { 0.0f }; // ikrmaxl: planar angle maximum, radians

        // The composer simulates a bone with rotation or translation and spring or rigid
        // (0x140201377); anything else adds no motion.
        bool simulates() const noexcept { return (flags & 0x3u) != 0 && (flags & 0x3000u) != 0; }
    };

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
        BoneSimulation simulation;              // the bone's physics and IK settings
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
            // Bit 0 set: the track is left out of the pose (anim+112 mask). The loader also
            // sets it for a bone an IK chain drives.
            int32_t                unk { 0 };
            std::vector<BoneFrame> frames;
        };
        std::vector<BoneTrack> bone_tracks;   // one per declared bone, in bone order
        std::vector<BoneTrack> target_tracks; // one per IK target (MDLA 2 on)
        struct LinkCurve {
            uint32_t           flags { 0 }; // bit 0 leaves this curve out of the layer blend
            std::vector<float> values;
        };
        std::vector<LinkCurve> link_curves; // one per link record (MDLA 2 on)

        struct BoneFrameCurve {
            std::vector<float> values;
        };
        struct MorphTrack {
            uint16_t           shape { 0 };
            std::vector<float> values;
        };
        struct MorphMeshTrack {
            uint32_t flags { 0 };
            // Preserved from anim+312's mesh record +4; the traced composers sample
            // the curves directly. It is not a timestamp or the MDMP geometry scale.
            float scale { 1.0f };
            std::vector<MorphTrack> curves;
        };
        struct AnimEvent {
            uint32_t    time_value { 0 };
            std::string event_json;
        };

        uint32_t                 unk_after_id { 0 };  // a word of unknown use after the id
        // The header word after the frame count (WE anim+80, loader 0x140261880 @0x140263a47).
        // Bit 0: the clip record below follows the animation. Bits 0x1F800: root motion
        // (0x14021C480 @0x14021cbf8), see the kRoot* bits.
        uint32_t                 flags { 0 };
        // One weight a frame for each texture channel, numbered by the file's record order
        // (the version-3 block of 0x140261880: a count, then per channel a word the loader
        // skips and frames + 1 floats).
        std::vector<std::vector<float>> texture_channels;
        // The record the loader reads after the version-6 curves when flags bit 0 is set
        // (0x140264fd0..0x14026513d, 192 bytes at anim+336).
        struct Clip {
            uint16_t source { 0 };          // +8: an earlier animation of the same block
            uint32_t start { 0 };           // +12: its first frame
            uint32_t end { 0 };             // +16: its last frame
            uint32_t origin_offset { 0 };   // +20: frames past start the first extraction measures from
            uint32_t bone { NO_PARENT };    // +24: the root bone, NO_PARENT for none
            // Filled by prepared() when the clip extracts root motion (0x1402651b1): the root
            // bone's model matrix at the start and end frames, and the start's inverse 3x3,
            // all column-major (+28, +128, +92).
            std::array<double, 16> start_matrix {};
            std::array<double, 16> end_matrix {};
            std::array<double, 9>  start_inverse {};
            bool                   prepared { false };
        };
        std::optional<Clip> clip;
        // Keyframe curves and events, as the animation block of the file lists them.
        std::vector<BoneFrameCurve> blend_curves;
        std::vector<MorphMeshTrack> morph_tracks;
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
    // The skeleton's inverse-kinematics description, as the MDLS block (version 2 on)
    // stores it after the bones (we_LoadMdlModel 0x140261880, 0x1402625da..0x140263963).
    struct IkTarget {
        std::string      name;
        uint32_t         bone { 0 };
        uint32_t         type { 0 }; // 0 position target, 1 orientation target
        linalg::Affine3f matrix { linalg::Affine3f::Identity() };
        linalg::Affine3f reference { linalg::Affine3f::Identity() };
        bool             has_reference { false };
    };
    struct BoneLink {
        uint32_t bone { 0 };       // owner; an IK-driven owner links its first position target
        uint32_t link_a { 0 };     // MDLA link-curve index, not necessarily this record's index
        uint32_t link_b { 0 };     // source bone whose model transform the rule reads
        uint32_t flags { 0 };      // MDLS 4 on
        uint32_t extra_u32 { 0 };  // flags & 2
        float    extra_f32 { 0 };  // flags & 2, at least FLT_EPSILON
    };
    // One record of a bone's group in the K table: another bone and three values.
    struct BoneNeighbour {
        uint32_t             bone { 0 };
        std::array<float, 3> values {};
    };
    struct IkChainLink {
        uint32_t              a { 0 };
        uint32_t              flags { 0 };
        uint32_t              b { 0 }; // float bits: total reach
        uint32_t              c { 0 }; // float bits: minimum goal distance
        std::vector<uint32_t> bones;
    };
    struct IkChainSegment {
        uint32_t                 bone { 0 };
        std::vector<IkChainLink> links;
    };
    struct IkChain {
        uint32_t                    bone { 0 };  // the chain's own bone
        std::vector<uint32_t>       targets;     // indices into ik_targets
        std::vector<IkChainSegment> segments;
    };
public:
    std::vector<Bone>      bones;
    /// The first post-box MDLS table; cursor picking visits its indices backwards.
    std::vector<uint32_t>  hit_box_order;
    std::vector<Animation> anims;
    std::vector<Attachment> attachments;
    std::vector<IkTarget>   ik_targets;
    std::vector<BoneLink>   bone_links;
    std::vector<float>      bone_table;          // K values, one per bone in the corpus
    std::vector<std::vector<BoneNeighbour>> bone_neighbours; // K groups
    std::vector<IkChain>    ik_chains;
    bool world_anchored_bones { false };
    // The model's first mesh has flag-word bit 4 (SKINNING_ALPHA): every layer then also
    // composes a per-bone alpha from its clip's per-bone curves (Animation::blend_curves).
    bool bone_alpha { false };
    // Some bone simulates (BoneSimulation::simulates): only then does a layer keep per-bone
    // physics state and step it. Set by prepared().
    bool has_simulation { false };
    // Null for a model without usable explicit IK chains; no per-frame IK work or state then.
    std::shared_ptr<const PuppetIkPlan> ik_plan;
    std::vector<PuppetMorphMeshInfo> morph_meshes;

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
    // WE's image-puppet composer solves IK; its 3D-model composer keeps FK. Animation,
    // script bone access and the existing spring/rigid simulation stay shared.
    enum class CompositionKind { ImagePuppet, Model };
    WPPuppetLayer();
    WPPuppetLayer(std::shared_ptr<WPPuppet>, CompositionKind = CompositionKind::ImagePuppet);
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
        // Fade the layer in over its first `blendtime` seconds (at most half the
        // clip). Wallpaper Engine clears this flag once a looping or mirrored clip
        // has faded in, so it fades in once; a single-shot clip keeps it
        // (we_AnimLayerEffectiveBlend 0x14026C8B0).
        bool        blendin { false };
        // Fade the layer out over the last `blendtime` seconds of the clip.
        bool        blendout { false };
        double      blendtime { 0.5 }; // 0x14026C680 writes 0.5 s
        // Authored layers start playing, matching the editor. A single-shot
        // animation stops at its last frame until play() restarts it.
        bool        playing { true };
    };

    void prepared(std::span<AnimationLayer>);

    std::span<const linalg::Affine3f> genFrame(double time) noexcept;
    /// The most recently evaluated skin palette, without evaluating or copying it.
    std::span<const linalg::Affine3f> lastFrame() const noexcept;
    // Per-bone alpha of the last evaluation (g_BonesAlpha), one value a bone; empty unless the
    // puppet is a SKINNING_ALPHA one.
    std::span<const float> boneAlpha() const noexcept;
    /// Each texture channel's weight at `time` (advancing the layers as `genFrame` does): the
    /// visible layers' animations, each sampled between its two frames and weighed by its share
    /// of the layers' blend. A layer alone counts in full whatever its blend, as in Wallpaper
    /// Engine. Channels no animation names stay 0.
    void textureChannelWeights(double time, std::span<float> out) noexcept;
    i32 blendShapeIndex(std::string_view name) const noexcept;
    std::optional<float> blendShapeWeight(usize shape) const noexcept;
    bool setBlendShapeWeight(usize shape, float weight) noexcept;
    const PuppetMorphUniforms* morphUniforms(usize mesh = 0) noexcept;

    // The bones of the last evaluation, as the SceneScript bone methods read and write them
    // (B-D8, image puppet methods registered by sub_140211070). Model bones are model-space
    // (WE +712), local bones parent-relative (+784); both hold genFrame's pose and any writes.
    usize boneCount() const noexcept;
    // The first bone named exactly `name` (0x140210790); -1 for none or the empty name.
    i32 boneIndex(std::string_view name) const noexcept;
    i32 attachmentIndex(std::string_view name) const noexcept;
    struct AttachmentBinding {
        uint32_t bone_index;
        linalg::Affine3f bind_transform;
    };
    std::optional<AttachmentBinding> attachmentBinding(i32 index) const;
    std::optional<linalg::Affine3f> attachmentTransform(i32 index) const;
    bool sharesPoseWith(const WPPuppetLayer& other) const { return m_state == other.m_state; }
    // The parent index the file stores (bone record +96, 0x140210860); -1 for a root or no bone.
    i32 boneParent(i32 bone) const noexcept;
    std::span<const linalg::Affine3f> modelBones() const noexcept;
    /// Picks the authored image-puppet boxes from the already-published pose.
    /// This never evaluates animation or simulation.
    std::optional<std::string> hitBoxName(const linalg::Matrix4d& layer_world,
                                         const linalg::Vector3d& ray_origin,
                                         const linalg::Vector3d& ray_direction) const;
    std::span<const linalg::Affine3f> localBones() const noexcept;
    // setBoneTransform 0x14020F350: that bone's model matrix and palette, and nothing else.
    // setLocalBoneTransform 0x14020F840 -> sub_14020DB40: the bone's local, then its model
    // matrix and palette and those of every bone below it. A write holds until the clock moves:
    // an evaluation at the same scene time applies it again, a new time drops it (the
    // composer rebuilds every bone each frame, scripts run after it). False for a bone the
    // puppet does not have.
    bool setModelBone(usize bone, const linalg::Affine3f& model) noexcept;
    bool setLocalBone(usize bone, const linalg::Affine3f& local) noexcept;

    // SceneScript IAnimationLayer surface. Public lookups resolve by authored name,
    // then by stack index. Object references use a serial ("#<serial>") exclusively,
    // so an authored name cannot redirect an existing object; -1 means no such layer.
    i32  findLayer(std::string_view name, bool by_serial = false) const noexcept;
    usize layerCount() const noexcept;
    // A number no other layer of this stack has had or will have, so a script object follows
    // its layer when a layer below it goes. Authored layers are numbered 0, 1, ... in stack
    // order; -1 for an index with no layer.
    i32 layerSerial(i32 index) const noexcept;
    /// The authored name of the layer at `index`; empty for an unnamed layer or
    /// an index with no layer.
    std::string layerName(i32 index) const;
    // The id of the first animation named `name` (createAnimationLayer 0x14020EA30 looks a
    // name up this way); nullopt when none has it.
    std::optional<i32> animationIdNamed(std::string_view name) const noexcept;
    // Where createLayer puts a layer (sub_1401FCC20): `autosort` goes below the trailing
    // additive layers; else `index` is clamped to the last place (a negative one too), so it
    // never appends; else the layer goes on top.
    struct LayerPlacement {
        bool                  autosort { false };
        std::optional<double> index;
    };
    // A script-made layer (sub_1401FCC20): `layer.id` names the animation; the clip keeps
    // `blendout` only when it plays once. `destroy_on_end` is playSingleAnimation's flag
    // 0x8000000: the layer ends with its first cycle whatever the clip's mode (the end, the
    // first wrap, the first bounce), its ended notice is posted and it goes once
    // removeEndedLayers() runs. The stack index of the new layer; -1 when no animation has
    // the id.
    i32 createLayer(AnimationLayer layer, LayerPlacement placement, bool destroy_on_end) noexcept;
    // destroyAnimationLayer 0x14020EF80: by index, or every layer with the name. Layers above
    // move down one place; a pending ended notice of a destroyed layer is dropped.
    bool destroyLayer(i32 index) noexcept;
    bool destroyLayersNamed(std::string_view name) noexcept;
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
    bool setAdditive(i32 index, bool additive) noexcept;
    bool additive(i32 index) const noexcept;
    bool setBlendIn(i32 index, bool blendin) noexcept;
    bool blendIn(i32 index) const noexcept;
    bool setBlendOut(i32 index, bool blendout) noexcept;
    bool blendOut(i32 index) const noexcept;
    // Finite and not negative; anything else is refused.
    bool setBlendTime(i32 index, double seconds) noexcept;
    double blendTime(i32 index) const noexcept;
    // The layers whose animation has played out since the last call, oldest first, by
    // serial: a single-shot clip at its end, a loop at each wrap, a mirror at each turn.
    // A destroy_on_end layer has `removed`: it goes at the next removeEndedLayers(). A script's
    // `addEndedCallback` is answered from this. The record is shared by every copy, so any
    // one of them can take it.
    struct FinishedLayer {
        i32  serial { 0 };
        bool removed { false };
    };
    std::vector<FinishedLayer> takeFinishedLayers() noexcept;
    // Erases the destroy_on_end layers that ended, after their listeners ran (the composer
    // 0x1401FDF90 calls the ended listeners, then deletes the layers marked 0x10000000).
    void removeEndedLayers() noexcept;
    // A model layer's `rootmotion` flag, shared by every copy (+784). While it is set, a layer
    // whose clip carries root-motion bits (Animation::kRoot*, with a clip record naming the root
    // bone) keeps the root bone where the clip starts and hands the motion to the layer itself
    // (0x14021C480 -> sub_140225900): each evaluation appends one step per such layer.
    void setRootMotion(bool on) noexcept;
    bool rootMotion() const noexcept;
    // One layer's motion for one evaluation: `translation` in the model's own axes, already
    // weighted; the owner adds (its world matrix's 3x3) * translation to its origin. `yaw`
    // radians about the layer's y axis, weighted.
    struct RootMotionStep {
        linalg::Vector3d translation { 0.0, 0.0, 0.0 };
        double           yaw { 0.0 };
    };
    // The steps since the last call, in the order the layers produced them.
    std::vector<RootMotionStep> takeRootMotion() noexcept;

    // Bone simulation (B-D2). The simulation runs in world space: the owner tells the layer its
    // world matrix (column-major) before each evaluation; without it the layer is the world.
    // Only a puppet with a simulating bone or a rope chain needs its layer's world matrix.
    bool simulates() const noexcept;
    bool usesSceneForces() const noexcept;
    void setSceneForces(std::shared_ptr<const SceneForceState>) noexcept;
    void setLayerWorld(const linalg::Matrix4d& world) noexcept;
    // applyBonePhysicsImpulse 0x140210990: `linear` (world units a second) is added to the bone's
    // velocity, `angular_degrees` (Rz·Ry·Rx) turns its angular velocity. resetBonePhysicsSimulation
    // 0x140210E10: the bone's state back to rest. Both act at the next step and answer false for a
    // bone that does not simulate.
    bool applyBoneImpulse(usize bone, const linalg::Vector3d& linear,
                          const linalg::Vector3d& angular_degrees) noexcept;
    bool resetBoneSimulation(usize bone) noexcept;

private:
    struct Layer {
        AnimationLayer                         anim_layer;
        // The weight the layer is composed with this frame: its blend, faded by
        // blendin/blendout.
        double                                 blend;
        const WPPuppet::Animation*             anim { nullptr };
        WPPuppet::Animation::InterpolationInfo interp_info {};
        // The weight before this evaluation's clock step: WE reads a later layer's weight
        // (we_AnimLayerEffectiveBlend) before that layer's own step in the same pass.
        double                                 pre_step_blend { 0.0 };
        // Root motion (layer+208 bit 31, +328, +332): primed after the first extraction, the
        // layer time and the root bone's model matrix that extraction measured.
        bool                                   rm_primed { false };
        double                                 rm_prev_time { 0.0 };
        std::array<double, 16>                 rm_prev {};
        i32                                    serial { 0 };
        // playSingleAnimation (+260 & 0x8000000): the layer goes after its first cycle;
        // `pending_destroy` once that cycle ended (0x10000000).
        bool                                   destroy_on_end { false };
        bool                                   pending_destroy { false };
        // The clip time before this evaluation's step, to see a wrap or a bounce.
        double                                 cycle_prev { 0.0 };
    };
    struct State {
        CompositionKind m_composition { CompositionKind::ImagePuppet };
        double m_last_elapsed { -1.0 };
        // False until the first evaluation: that one only records the scene time.
        bool   m_clock_started { false };

        std::vector<Layer> m_layers;
        // Pending ended notices, by layer serial.
        std::vector<i32>   m_finished_layers;
        i32                m_next_serial { 0 };
        std::vector<linalg::Affine3f> m_final_affines;
        std::vector<float>            m_bone_alpha;
        bool                          m_root_motion { false };
        std::vector<RootMotionStep>   m_root_motion_steps;
        bool m_pose_valid { false };
        uint64_t m_pose_time_bits { 0 };
        // The last evaluation's bones (the palette is m_final_affines).
        std::vector<linalg::Affine3f> m_model_bones;
        std::vector<linalg::Affine3f> m_local_bones;
        struct ScriptWrite {
            bool             local { false };
            usize            bone { 0 };
            linalg::Affine3f matrix { linalg::Affine3f::Identity() };
        };
        std::vector<ScriptWrite> m_script_writes;
        std::shared_ptr<PuppetIkState> m_ik;
        std::shared_ptr<PuppetMorphState> m_morph;
        // Bone simulation, sized only for a puppet with a simulating bone. m_prev_world is each
        // bone's final world matrix of the previous step (Wallpaper Engine's +840), taken when
        // the clock moves; m_physics_offset the local matrix the step put on the bone, applied
        // again when the pose is recomputed at the same time.
        std::vector<BonePhysicsState>       m_physics;
        std::vector<std::array<double, 16>> m_physics_offset;
        std::vector<std::array<double, 16>> m_prev_world;
        std::array<double, 16>              m_layer_world { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
        std::array<double, 16>              m_step_world { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
        double                              m_physics_time { 0.0 };
        double                              m_physics_dt { 0.0 };
        bool                                m_physics_primed { false }; // a pose was evaluated
        bool                                m_physics_step { false };   // this evaluation steps
        bool                                m_physics_applies { false }; // offsets exist
    };

    void   updateWeights() noexcept;
    void   updateInterpolation(double time) noexcept;
    void   invalidatePose() noexcept;
    Layer* layerAt(i32 index) noexcept;
    const Layer* layerAt(i32 index) const noexcept;
    void         applyBoneWrite(const State::ScriptWrite& write) noexcept;

    std::shared_ptr<State>    m_state;
    std::shared_ptr<WPPuppet> m_puppet;
};

} // namespace wallpaper
