#include "Utils/Logging.h"
#include "WPPuppet.hpp"

#include <algorithm>
#include <bit>
#include <cmath>

using namespace wallpaper;
using namespace Eigen;

static Quaterniond ToQuaternion(Vector3f euler) {
    const std::array<Vector3d, 3> axis { Vector3d::UnitX(), Vector3d::UnitY(), Vector3d::UnitZ() };
    return AngleAxis<double>(euler.z(), axis[2]) * AngleAxis<double>(euler.y(), axis[1]) *
           AngleAxis<double>(euler.x(), axis[0]);
};

static bool HasValidBindParentIndex(const WPPuppet::Bone& bone, uint index)
{
    return bone.bind_parent == WPPuppet::Bone::NO_PARENT || bone.bind_parent < index;
}

void WPPuppet::prepared() {
    for (uint i = 0; i < bones.size(); i++) {
        auto& b = bones[i];
        if (! HasValidBindParentIndex(b, i)) {
            // Local safety adapter: upstream asserts this invariant. Some
            // malformed workshop assets previously crashed here; keep the
            // puppet usable by rooting only the invalid bind branch.
            LOG_ERROR("puppet invalid bind parent index %u for bone %u", b.bind_parent, i);
            b.bind_parent = WPPuppet::Bone::NO_PARENT;
            b.parent      = WPPuppet::Bone::NO_PARENT;
            b.world_bind  = b.local_bind;
        } else {
            if (b.noBindParent()) {
                b.world_bind = b.local_bind;
                if (world_anchored_bones) {
                    b.world_bind.pretranslate(b.vertex_centroid_offset);
                }
            } else {
                b.world_bind = bones[b.bind_parent].world_bind * b.local_bind;
            }
        }

        b.inv_bind = b.world_bind.inverse();
        const auto& reference = b.has_local_reference ? b.local_reference : b.local_bind;
        b.reference_position = reference.translation();
        b.reference_scale = reference.linear().colwise().norm();
        Eigen::Matrix3f rotation = reference.linear();
        for (int axis = 0; axis < 3; ++axis) {
            if (b.reference_scale[axis] != 0.0f) rotation.col(axis) /= b.reference_scale[axis];
        }
        if (rotation.determinant() < 0.0f) {
            b.reference_scale.x() = -b.reference_scale.x();
            rotation.col(0) = -rotation.col(0);
        }
        b.reference_rotation = Eigen::Quaterniond(rotation.cast<double>()).normalized();
    }
    for (auto& anim : anims) {
        anim.frame_time = 1.0f / anim.fps;
        anim.max_time   = anim.length / anim.fps;
        for (auto& track : anim.bone_tracks) {
            for (auto& f : track.frames) {
                f.quaternion = ToQuaternion(f.angle);
            }
        }
    }
}

void WPPuppet::evaluatePose(const WPPuppetLayer& puppet_layer,
                            std::span<Eigen::Affine3f> final_affines) const noexcept {
    const auto& state = *puppet_layer.m_state;
    double global_blend = state.m_global_blend;

    // TRS skinning is required: WE puppets animate scale (e.g. blink uses
    // frame.scale.y -> ~0). A pure-translation g_Bones would shift the whole
    // sprite as a unit; intra-sprite compression needs non-identity linear so
    // vertices within the sprite get differential treatment.
    for (uint i = 0; i < final_affines.size(); i++) {
        const auto& bone   = bones[i];
        auto&       affine = final_affines[i];

        // Local safety adapter: upstream asserts anim_parent ordering. Invalid
        // asset data can otherwise index outside final_affines and crash.
        const bool has_valid_anim_parent = ! bone.noAnimParent() && bone.anim_parent < i;
        if (!bone.noAnimParent() && !has_valid_anim_parent) {
            LOG_ERROR("puppet invalid anim parent index %u for bone %u", bone.anim_parent, i);
        }
        const Affine3f parent =
            has_valid_anim_parent ? final_affines[bone.anim_parent] : Affine3f::Identity();

        // Bind state. vco is a fixed render-time pivot offset for root sprite
        // bones and is added to trans after layer blending below.
        Vector3f    trans { bone.reference_position * global_blend };
        Vector3f    scale { bone.reference_scale * global_blend };
        Quaterniond quat { bone.reference_rotation };
        const Quaterniond ident { Quaterniond::Identity() };

        for (auto& layer : state.m_layers) {
            auto& alayer = layer.anim_layer;
            if (layer.anim == nullptr || ! alayer.visible) continue;
            if (i >= layer.anim->bone_tracks.size()) continue;
            // Local safety adapter: upstream assumes valid MDLA tracks. Keep
            // empty or truncated tracks from dereferencing frame[0]/frame_b.
            if (layer.anim->bone_tracks[i].frames.empty()) continue;
            auto& info = layer.interp_info;
            if (static_cast<usize>(info.frame_a) >= layer.anim->bone_tracks[i].frames.size() ||
                static_cast<usize>(info.frame_b) >= layer.anim->bone_tracks[i].frames.size()) {
                continue;
            }

            auto& frame_a    = layer.anim->bone_tracks[i].frames[(usize)info.frame_a];
            auto& frame_b    = layer.anim->bone_tracks[i].frames[(usize)info.frame_b];

            double t = info.t;
            double one_t   = 1.0f - info.t;

            // Keyframes are local poses, not offsets from the first sample.
            // The first sample may already collapse an eyelid or rotate a bone.
            const auto& base_rotation = bone.reference_rotation;
            const auto& base_position = bone.reference_position;
            const auto& base_scale = bone.reference_scale;
            auto frame_a_quat_delta = base_rotation.conjugate() * frame_a.quaternion;
            auto frame_b_quat_delta = base_rotation.conjugate() * frame_b.quaternion;
            auto pos_a_delta   = frame_a.position - base_position;
            auto pos_b_delta   = frame_b.position - base_position;
            auto scale_a_delta = frame_a.scale - base_scale;
            auto scale_b_delta = frame_b.scale - base_scale;

            // Absolute layers share a normalized pose budget; their deltas must
            // use the same weight as the reference pose or assembly offsets stack.
            quat *= frame_a_quat_delta.slerp(t, frame_b_quat_delta)
                        .slerp(1.0 - layer.blend, ident);
            if (alayer.additive) {
                trans += alayer.blend * (pos_a_delta * one_t + pos_b_delta * t);
                scale += alayer.blend * (scale_a_delta * one_t + scale_b_delta * t);
            } else {
                trans += (layer.blend * base_position) +
                         (layer.blend * (pos_a_delta * one_t + pos_b_delta * t));
                scale += (layer.blend * base_scale) +
                         (layer.blend * (scale_a_delta * one_t + scale_b_delta * t));
            }
        }
        if (bone.noBindParent() && world_anchored_bones) {
            trans += bone.vertex_centroid_offset;
        }
        affine = Affine3f::Identity();
        affine.pretranslate(trans);
        affine.rotate(quat.cast<float>());
        affine.scale(scale);
        affine = parent * affine;
    }

    for (uint i = 0; i < final_affines.size(); i++) {
        final_affines[i] *= bones[i].inv_bind.matrix();
    }
}

static constexpr void genInterpolationInfo(WPPuppet::Animation::InterpolationInfo& info,
                                           double& cur, u32 length, double frame_time,
                                           double max_time) {
    // Local safety adapter: upstream assumes positive animation timing. A
    // zero-length/zero-fps track should hold bind pose, not divide by zero.
    if (length == 0 || frame_time <= 0.0 || max_time <= 0.0) {
        info.frame_a = 0;
        info.frame_b = 0;
        info.t = 0.0;
        return;
    }
    cur          = std::fmod(cur, max_time);
    double _rate = cur / frame_time;

    // `length` is the number of intervals; tracks store length + 1 samples.
    // frame_b = frame_a + 1 is therefore in range for valid MDLA tracks.
    info.frame_a = ((uint)_rate) % length;
    info.frame_b = info.frame_a + 1;
    info.t       = _rate - (double)info.frame_a;
}

static constexpr void genSingleInterpolationInfo(WPPuppet::Animation::InterpolationInfo& info,
                                                 double& cur, u32 length, double frame_time,
                                                 double max_time) {
    // Local safety adapter: upstream assumes positive animation timing. A
    // zero-length/zero-fps track should hold bind pose, not divide by zero.
    if (length == 0 || frame_time <= 0.0 || max_time <= 0.0) {
        info.frame_a = 0;
        info.frame_b = 0;
        info.t = 0.0;
        return;
    }
    if (cur >= max_time) {
        cur = max_time;
        info.frame_a = length;
        info.frame_b = length;
        info.t = 0.0;
        return;
    }
    if (cur < 0.0) cur = 0.0;
    double _rate = cur / frame_time;

    info.frame_a = (uint)_rate;
    info.frame_b = info.frame_a + 1;
    info.t       = _rate - (double)info.frame_a;
}

WPPuppet::Animation::InterpolationInfo
WPPuppet::Animation::getInterpolationInfo(double* cur_time) const {
    InterpolationInfo _info;
    auto&             _cur_time = *cur_time;

    if (mode == PlayMode::Loop) {
        genInterpolationInfo(_info, _cur_time, (u32)length, frame_time, max_time);
    } else if (mode == PlayMode::Single) {
        genSingleInterpolationInfo(_info, _cur_time, (u32)length, frame_time, max_time);
    } else if (mode == PlayMode::Mirror) {
        const auto _get_frame = [this](auto f) -> idx {
            return f <= length ? f : (2 * length - f);
        };
        genInterpolationInfo(_info, _cur_time, (u32)length * 2, frame_time, max_time * 2.0f);
        _info.frame_a = _get_frame(_info.frame_a);
        _info.frame_b = _get_frame(_info.frame_b);
    }

    return _info;
}

void WPPuppetLayer::prepared(std::span<AnimationLayer> alayers) {
    if (! m_puppet || ! m_state) return;
    invalidatePose();
    auto& layers = m_state->m_layers;
    layers.resize(alayers.size());
    const auto& anims = m_puppet->anims;
    for (usize i = 0; i < alayers.size(); i++) {
        const auto& layer = alayers[i];
        auto it = std::find_if(anims.begin(), anims.end(), [&layer](auto& a) {
            return layer.id == a.id;
        });
        layers[i] = Layer {
            .anim_layer = layer,
            .blend      = 0.0,
            .anim       = it != anims.end() ? std::addressof(*it) : nullptr,
        };
    }
    rebuildBlend();
}

// Normalizes the authored blend weights across visible non-additive layers.
// Later layers take priority, so the stack is walked back to front.
void WPPuppetLayer::rebuildBlend() noexcept {
    auto&   state       = *m_state;
    double& blend       = state.m_global_blend;
    double& total_blend = state.m_total_blend;

    blend       = 1.0;
    total_blend = 0.0;
    for (const auto& layer : state.m_layers) {
        const auto& alayer = layer.anim_layer;
        if (! alayer.visible || alayer.additive || layer.anim == nullptr) continue;
        total_blend += alayer.blend;
    }

    for (auto it = state.m_layers.rbegin(); it != state.m_layers.rend(); ++it) {
        auto&       layer  = *it;
        const auto& alayer = layer.anim_layer;
        double      cur_blend { 0.0 };
        if (layer.anim != nullptr && alayer.visible) {
            if (alayer.additive) {
                cur_blend = alayer.blend;
            } else if (total_blend > 1.0) {
                cur_blend = alayer.blend / total_blend;
                blend     = 0.0;
            } else {
                cur_blend = blend * alayer.blend;
                blend *= 1.0 - alayer.blend;
                blend = blend < 0.0 ? 0.0 : blend;
            }
        }
        layer.blend = cur_blend;
    }
}

std::span<const Eigen::Affine3f> WPPuppetLayer::genFrame(double time) noexcept {
    if (! m_puppet || ! m_state) return {};
    auto& state = *m_state;
    const auto time_bits = std::bit_cast<uint64_t>(time);
    if (state.m_pose_valid && std::isfinite(time) && state.m_pose_time_bits == time_bits) {
        return state.m_final_affines;
    }

    state.m_pose_valid = false;
    updateInterpolation(time);
    m_puppet->evaluatePose(*this, state.m_final_affines);
    state.m_pose_time_bits = time_bits;
    state.m_pose_valid =
        std::isfinite(time) && std::isfinite(state.m_last_elapsed) &&
        std::isfinite(state.m_global_blend) && std::isfinite(state.m_total_blend) &&
        std::all_of(state.m_layers.begin(), state.m_layers.end(), [](const Layer& layer) {
            const auto& authored = layer.anim_layer;
            return std::isfinite(authored.rate) && std::isfinite(authored.blend) &&
                   std::isfinite(authored.cur_time) && std::isfinite(layer.blend) &&
                   std::isfinite(layer.interp_info.t);
        });
    return state.m_final_affines;
}

void WPPuppetLayer::invalidatePose() noexcept {
    if (m_state) m_state->m_pose_valid = false;
}

void WPPuppetLayer::updateInterpolation(double time) noexcept {
    auto&  state   = *m_state;
    double delta   = (state.m_last_elapsed < 0.0) ? 0.0 : (time - state.m_last_elapsed);
    bool   advance = (state.m_last_elapsed < 0.0) || (delta > 0.0);
    if (advance) state.m_last_elapsed = time;
    for (usize index = 0; index < state.m_layers.size(); ++index) {
        auto& layer = state.m_layers[index];
        if (! layer) continue;
        auto& alayer = layer.anim_layer;
        if (advance && alayer.playing) alayer.cur_time += delta * alayer.rate;
        layer.interp_info = layer.anim->getInterpolationInfo(&alayer.cur_time);
        // A finished single-shot layer holds its last frame and reports
        // stopped so play() restarts it instead of re-clamping forever. It
        // finishes once: the script that asked to hear about it hears it then.
        if (alayer.playing && layer.anim->mode == WPPuppet::PlayMode::Single &&
            alayer.cur_time >= layer.anim->max_time) {
            alayer.playing = false;
            // Bounded: a puppet nobody drains must not grow without limit.
            constexpr usize kMaxPendingFinished = 256;
            if (state.m_finished_layers.size() < kMaxPendingFinished) {
                state.m_finished_layers.push_back(static_cast<i32>(index));
            }
        }
    }
}

std::vector<i32> WPPuppetLayer::takeFinishedLayers() noexcept {
    if (! m_state) return {};
    std::vector<i32> finished;
    finished.swap(m_state->m_finished_layers);
    return finished;
}

WPPuppetLayer::Layer* WPPuppetLayer::layerAt(i32 index) noexcept {
    if (! m_state || index < 0 || static_cast<usize>(index) >= m_state->m_layers.size()) {
        return nullptr;
    }
    return &m_state->m_layers[static_cast<usize>(index)];
}

const WPPuppetLayer::Layer* WPPuppetLayer::layerAt(i32 index) const noexcept {
    if (! m_state || index < 0 || static_cast<usize>(index) >= m_state->m_layers.size()) {
        return nullptr;
    }
    return &m_state->m_layers[static_cast<usize>(index)];
}

i32 WPPuppetLayer::findLayer(std::string_view name) const noexcept {
    if (! m_state) return -1;
    const auto& layers = m_state->m_layers;
    for (usize i = 0; i < layers.size(); i++) {
        if (layers[i].anim_layer.name == name) return static_cast<i32>(i);
    }
    // SceneScript also accepts the stack index.
    i32 index = 0;
    for (const char ch : name) {
        if (ch < '0' || ch > '9') return -1;
        index = index * 10 + (ch - '0');
        if (index > 4096) return -1;
    }
    if (name.empty() || static_cast<usize>(index) >= layers.size()) return -1;
    return index;
}

usize WPPuppetLayer::layerCount() const noexcept {
    return m_state ? m_state->m_layers.size() : 0;
}

std::string WPPuppetLayer::layerName(i32 index) const {
    const auto* layer = layerAt(index);
    return layer != nullptr ? layer->anim_layer.name : std::string {};
}

bool WPPuppetLayer::play(i32 index) noexcept {
    auto* layer = layerAt(index);
    if (layer == nullptr) return false;
    invalidatePose();
    auto& alayer = layer->anim_layer;
    if (! alayer.playing && layer->anim != nullptr &&
        layer->anim->mode == WPPuppet::PlayMode::Single &&
        alayer.cur_time >= layer->anim->max_time) {
        alayer.cur_time = 0.0;
    }
    alayer.playing = true;
    return true;
}

bool WPPuppetLayer::pause(i32 index) noexcept {
    auto* layer = layerAt(index);
    if (layer == nullptr) return false;
    invalidatePose();
    layer->anim_layer.playing = false;
    return true;
}

bool WPPuppetLayer::stop(i32 index) noexcept {
    auto* layer = layerAt(index);
    if (layer == nullptr) return false;
    invalidatePose();
    layer->anim_layer.playing  = false;
    layer->anim_layer.cur_time = 0.0;
    if (layer->anim != nullptr) {
        layer->interp_info = layer->anim->getInterpolationInfo(&layer->anim_layer.cur_time);
    }
    return true;
}

bool WPPuppetLayer::isPlaying(i32 index) const noexcept {
    const auto* layer = layerAt(index);
    return layer != nullptr && layer->anim_layer.playing;
}

bool WPPuppetLayer::setFrame(i32 index, double frame) noexcept {
    auto* layer = layerAt(index);
    if (layer == nullptr || layer->anim == nullptr || ! std::isfinite(frame)) return false;
    invalidatePose();
    const double frames = static_cast<double>(layer->anim->length);
    if (frame < 0.0) frame = 0.0;
    if (frame > frames) frame = frames;
    layer->anim_layer.cur_time = frame * layer->anim->frame_time;
    layer->interp_info = layer->anim->getInterpolationInfo(&layer->anim_layer.cur_time);
    return true;
}

double WPPuppetLayer::frame(i32 index) const noexcept {
    const auto* layer = layerAt(index);
    if (layer == nullptr || layer->anim == nullptr || layer->anim->frame_time <= 0.0) return 0.0;
    return layer->anim_layer.cur_time / layer->anim->frame_time;
}

double WPPuppetLayer::frameCount(i32 index) const noexcept {
    const auto* layer = layerAt(index);
    if (layer == nullptr || layer->anim == nullptr) return 0.0;
    return static_cast<double>(layer->anim->length);
}

double WPPuppetLayer::fps(i32 index) const noexcept {
    const auto* layer = layerAt(index);
    if (layer == nullptr || layer->anim == nullptr) return 0.0;
    return layer->anim->fps;
}

bool WPPuppetLayer::setRate(i32 index, double rate) noexcept {
    auto* layer = layerAt(index);
    if (layer == nullptr || ! std::isfinite(rate)) return false;
    invalidatePose();
    layer->anim_layer.rate = rate;
    return true;
}

double WPPuppetLayer::rate(i32 index) const noexcept {
    const auto* layer = layerAt(index);
    return layer == nullptr ? 0.0 : layer->anim_layer.rate;
}

bool WPPuppetLayer::setBlend(i32 index, double blend) noexcept {
    auto* layer = layerAt(index);
    if (layer == nullptr || ! std::isfinite(blend)) return false;
    if (layer->anim_layer.blend == blend) return true;
    invalidatePose();
    layer->anim_layer.blend = blend;
    rebuildBlend();
    return true;
}

double WPPuppetLayer::blend(i32 index) const noexcept {
    const auto* layer = layerAt(index);
    return layer == nullptr ? 0.0 : layer->anim_layer.blend;
}

bool WPPuppetLayer::setVisible(i32 index, bool visible) noexcept {
    auto* layer = layerAt(index);
    if (layer == nullptr) return false;
    if (layer->anim_layer.visible == visible) return true;
    invalidatePose();
    layer->anim_layer.visible = visible;
    rebuildBlend();
    return true;
}

bool WPPuppetLayer::visible(i32 index) const noexcept {
    const auto* layer = layerAt(index);
    return layer != nullptr && layer->anim_layer.visible;
}

WPPuppetLayer::WPPuppetLayer(std::shared_ptr<WPPuppet> pup)
    : m_state(pup ? std::make_shared<State>() : nullptr), m_puppet(std::move(pup)) {
    if (m_state) m_state->m_final_affines.resize(m_puppet->bones.size());
}
WPPuppetLayer::WPPuppetLayer()  = default;
WPPuppetLayer::~WPPuppetLayer() = default;
