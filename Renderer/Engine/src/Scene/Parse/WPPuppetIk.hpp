#pragma once

#include "WPPuppet.hpp"

namespace wallpaper
{
// Prepared MDLS chains. The file's links, lengths and target maps determine the solve;
// the JSON ik_depth is editor input, not a replacement for that stored topology.
struct PuppetIkPlan {
    struct Target {
        linalg::Vector3d position;
        linalg::Vector3d scale;
        linalg::Quaterniond rotation;
    };
    struct Link {
        uint32_t end { 0 };
        uint32_t flags { 0 };
        int32_t goal { -1 }, pole { -1 };
        double reach { 0 }, minimum_reach { 0 };
        std::vector<uint32_t> bones;
        std::vector<linalg::Vector3d> reference_directions;
    };
    struct Segment {
        uint32_t root { 0 };
        std::vector<Link> links;
    };
    struct TargetLink {
        enum class Mode { Transform, Position, Axis, Grounding };
        uint32_t target { 0 }, source_bone { 0 }, weight_slot { 0 };
        Mode mode { Mode::Transform };
    };
    struct GroundingLink {
        uint32_t target_link {0}, segment {0}, link {0};
    };
    struct BoneLink {
        uint32_t bone {0}, source_bone {0}, weight_slot {0};
    };
    struct Chain {
        uint32_t root { 0 };
        std::vector<Segment> segments;
        std::vector<uint32_t> affected;
        std::vector<TargetLink> target_links;
        std::vector<GroundingLink> grounding_links;
    };
    std::vector<Chain> chains;
    std::vector<BoneLink> bone_links;
    std::vector<int32_t> at_bone;
    std::vector<bool> driven;
    std::vector<double> lengths;
    std::vector<linalg::Affine3f> reference;
    std::vector<Target> targets;
    // Only curves consumed by prepared target links; ordinary/no-link puppets
    // acquire neither a per-instance array nor a new sampling traversal.
    std::vector<uint32_t> link_curve_indices;
    bool has_rope { false };
};

// Per image-puppet instance, only for usable IK or ordinary blend-rule consumers.
// Ordinary-only plans allocate neither per-bone solver arrays nor rope state.
struct PuppetIkState {
    explicit PuppetIkState(std::shared_ptr<const PuppetIkPlan>);
    std::shared_ptr<const PuppetIkPlan> plan;
    std::shared_ptr<const SceneForceState> forces;
    std::vector<linalg::Affine3f> targets;
    std::vector<float>                     link_weights;
    std::vector<linalg::Vector3d> rope_current, rope_previous;
    std::vector<bool> rope_primed;
    linalg::Affine3d world { linalg::Affine3d::Identity() };
    linalg::Affine3d world_inverse { linalg::Affine3d::Identity() };
    double time { 0 }, dt { 0 };
    bool clock_started { false }, advance { false }, world_valid { true };
};

std::shared_ptr<const PuppetIkPlan> PreparePuppetIk(const WPPuppet&);
void BeginPuppetIkFrame(PuppetIkState&, double time, const std::array<double, 16>& world);
void ApplyPuppetBoneLinks(PuppetIkState&, uint32_t bone, usize& next_link,
                          std::span<linalg::Affine3f> model);
void SolvePuppetIk(const WPPuppet&, PuppetIkState&, usize chain, std::span<linalg::Affine3f> model);
} // namespace wallpaper
