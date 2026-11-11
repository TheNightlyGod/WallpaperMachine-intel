#include "WPPuppetIk.hpp"
#include "Scene/SceneForces.hpp"

#include <algorithm>
#include <bit>
#include <cmath>
#include <limits>

namespace wallpaper
{
namespace
{
using V3 = linalg::Vector3d;
using Q = linalg::Quaterniond;
using A = linalg::Affine3f;
using Sim = WPPuppet::BoneSimulation;
using Link = PuppetIkPlan::Link;

V3 Position(const A& m) { return V3(m(0, 3), m(1, 3), m(2, 3)); }
void Position(A& m, const V3& p) {
    if (! p.allFinite()) return;
    for (int i = 0; i < 3; ++i) m(i, 3) = static_cast<float>(p[i]);
}
V3 Unit(const V3& v, const V3& fallback = V3(1, 0, 0)) {
    const double n = v.norm();
    return n > 1e-12 && std::isfinite(n) ? V3(v / n) : fallback;
}
Q Rotation(const V3& from, const V3& to) {
    const V3 a = Unit(from), b = Unit(to);
    const double d = std::clamp(a.dot(b), -1.0, 1.0);
    if (d > 0.9999999) return Q::Identity();
    if (d < -0.9999999) {
        V3 axis = a.cross(V3(1, 0, 0));
        if (axis.squaredNorm() < 1.1920929e-7) axis = a.cross(V3(0, 1, 0));
        axis = Unit(axis);
        return Q(0, axis.x(), axis.y(), axis.z());
    }
    const double s = std::sqrt(2 * (1 + d));
    const V3 xyz = a.cross(b) / s;
    return Q(s * 0.5, xyz.x(), xyz.y(), xyz.z());
}
linalg::Matrix3d Linear(const A& m) {
    linalg::Matrix3d result;
    for (int c = 0; c < 3; ++c) for (int r = 0; r < 3; ++r) result(r, c) = m(r, c);
    return result;
}
void Linear(A& m, const linalg::Matrix3d& value) {
    if (! value.allFinite()) return;
    for (int c = 0; c < 3; ++c) for (int r = 0; r < 3; ++r) m(r, c) = static_cast<float>(value(r, c));
}
linalg::Matrix3d UnitColumns(const A& m) {
    auto result = Linear(m);
    for (int c = 0; c < 3; ++c) {
        const V3 v = Unit(V3(result(0, c), result(1, c), result(2, c)),
                          c == 0 ? V3(1, 0, 0) : c == 1 ? V3(0, 1, 0) : V3(0, 0, 1));
        for (int r = 0; r < 3; ++r) result(r, c) = v[r];
    }
    return result;
}
V3 Goal(const Link& link, const PuppetIkState& state, std::span<A> model) {
    return Position(link.goal >= 0 ? state.targets[static_cast<usize>(link.goal)] : model[link.end]);
}

// sub_1401E23D0 / sub_140215020: extract and rebuild Z·Y·X Euler rotations.
// The source matrices are intentionally not normalized before extraction: the
// target-link composer measures their column lengths separately for scale.
V3 LinkAngles(const A& m) {
    const double z = std::atan2(m(1, 0), m(0, 0));
    const double y = std::atan2(-m(2, 0), std::hypot(m(2, 1), m(2, 2)));
    const double s = std::sin(z), c = std::cos(z);
    return V3(std::atan2(s * m(0, 2) - c * m(1, 2), c * m(1, 1) - s * m(0, 1)), y, z);
}

linalg::Matrix3d LinkRotation(const V3& e) {
    const double     cx = std::cos(e.x()), sx = std::sin(e.x());
    const double     cy = std::cos(e.y()), sy = std::sin(e.y());
    const double     cz = std::cos(e.z()), sz = std::sin(e.z());
    linalg::Matrix3d m;
    m(0, 0) = cy * cz;
    m(1, 0) = cy * sz;
    m(2, 0) = -sy;
    m(0, 1) = sx * sy * cz - cx * sz;
    m(1, 1) = sx * sy * sz + cx * cz;
    m(2, 1) = sx * cy;
    m(0, 2) = cx * sy * cz + sx * sz;
    m(1, 2) = cx * sy * sz - sx * cz;
    m(2, 2) = cx * cy;
    return m;
}

void BlendLink(A& target, const A& source, float weight, bool position_only = false) {
    const V3    position = Position(target) * (1.0 - weight) + Position(source) * weight;
    if (position_only) {
        Position(target, position);
        return;
    }
    auto from = LinkAngles(target), to = LinkAngles(source);
    // 0x14027138e..0x140271460. Raw PE constants are pi at 0x140492834
    // and 2*pi at 0x140492864. This one-sided pi adjustment is not slerp.
    constexpr double pi = 3.1415927410125732, two_pi = 6.2831854820251465;
    for (int axis = 0; axis < 3; ++axis) {
        from[axis] = std::fmod(from[axis], two_pi);
        to[axis]   = std::fmod(to[axis], two_pi);
        if (to[axis] - from[axis] > pi) to[axis] -= pi;
    }
    auto rotation = LinkRotation(from * (1.0 - weight) + to * weight);
    for (int axis = 0; axis < 3; ++axis) {
        const double a = V3(target(0, axis), target(1, axis), target(2, axis)).norm();
        const double b = V3(source(0, axis), source(1, axis), source(2, axis)).norm();
        for (int row = 0; row < 3; ++row)
            rotation(row, axis) *= a * (1.0 - weight) + b * weight;
    }
    Linear(target, rotation);
    Position(target, position);
}

void ApplyTargetLinks(PuppetIkState& state, const PuppetIkPlan::Chain& chain, std::span<A> model) {
    usize next_grounding = 0;
    for (const auto& link : chain.target_links) {
        const auto* grounding = link.mode == PuppetIkPlan::TargetLink::Mode::Grounding
            ? &chain.grounding_links[next_grounding++] : nullptr;
        const float weight = state.link_weights[link.weight_slot];
        if (!std::isfinite(weight)) continue;
        auto& target = state.targets[link.target];
        const A* source_pose = &model[link.source_bone];
        A projected;
        if (link.mode == PuppetIkPlan::TargetLink::Mode::Axis || grounding) {
            const V3 axis((*source_pose)(0,0),(*source_pose)(1,0),(*source_pose)(2,0));
            const double length_squared = axis.squaredNorm();
            if (!std::isfinite(length_squared) || length_squared <= 0) continue;
            const V3 origin = Position(*source_pose);
            if (grounding) {
                // 0x14026F5B3: high-bit grounding takes precedence over flags 0/1/2.
                // The source's X axis is the plane normal, not the flag-2 line.
                const auto& path = chain.segments[grounding->segment].links[grounding->link];
                const V3 normal = axis / std::sqrt(length_squared);
                const double distance = (origin-Position(model[path.bones.front()])).norm();
                const double along = (Position(target)-origin).dot(normal);
                if (distance >= path.reach || along < 0) {
                    projected = target; // unreachable/behind: preserve target rotation and scale
                    Position(projected,origin);
                } else {
                    projected = *source_pose;
                    Position(projected,origin+normal*std::min(path.reach-distance,along));
                }
            } else {
                projected = target;
                Position(projected,origin+axis*(Position(target)-origin).dot(axis)/length_squared);
            }
            source_pose = &projected;
        }
        BlendLink(target,*source_pose,weight,link.mode == PuppetIkPlan::TargetLink::Mode::Position);
    }
}

void ReflectGroundedJoints(const PuppetIkState& state, const PuppetIkPlan::Chain& chain,
                           std::span<A> model) {
    for (const auto& grounding : chain.grounding_links) {
        const auto& rule = chain.target_links[grounding.target_link];
        const auto& path = chain.segments[grounding.segment].links[grounding.link];
        const auto& source = model[rule.source_bone];
        const V3 axis(source(0,0),source(1,0),source(2,0));
        const double length = axis.norm();
        if (!(length > 0) || !std::isfinite(length)) continue;
        const V3 normal = axis/length;
        const double distance = (Position(source)-Position(model[path.bones.front()])).norm();
        double remaining = distance;
        int attempts = 32;
        for (usize middle=1; middle+1<path.bones.size() && attempts>0; ++middle,--attempts) {
            remaining -= state.plan->lengths[path.bones[middle]];
            if (remaining < 0) break;
            const V3 before = Position(model[path.bones[middle-1]]);
            const V3 chord = Position(model[path.bones[middle+1]])-before;
            V3 perpendicular = chord.cross(normal.cross(chord));
            // Raw IEEE constants 0x140492620 and 0x1404925E0, not decompiler decimals.
            if (perpendicular.squaredNorm() < 0.009999999776482582) continue;
            perpendicular /= perpendicular.norm();
            auto& joint = model[path.bones[middle]];
            const double side = (Position(joint)-before).dot(perpendicular);
            if (side > 1.1920928955078125e-7) {
                Position(joint,Position(joint)-perpendicular*(2*side));
                remaining = distance;
                // 0x1402728CC sets 1; the loop increment then advances to 2.
                middle = 1;
            }
        }
    }
}

// sub_14026DF30: ikce is a planar bend limit. The two fields called ikrminl/maxl
// hold radians; they neither terminate the chain nor scale its segment lengths.
V3 LimitDirection(const WPPuppet& puppet, std::span<A> model, uint32_t bone, V3 direction) {
    const auto& b = puppet.bones[bone];
    const auto& sim = b.simulation;
    if ((sim.flags & Sim::kIkChainEnd) == 0 || b.anim_parent >= model.size()) return direction;
    const double xy = std::hypot(direction.x(), direction.y());
    if (! (xy > 1e-12)) return direction;
    const Q frame = Rotation(V3(1, 0, 0), Position(model[bone]) - Position(model[b.anim_parent]));
    V3 local = frame.conjugate().toRotationMatrix() * V3(direction.x() / xy, direction.y() / xy, 0);
    const double angle = std::atan2(local.y(), local.x());
    double turn = angle < sim.ik_rope_min_length ? sim.ik_rope_min_length - angle : 0;
    if (angle > sim.ik_rope_max_length) {
        const double other = sim.ik_rope_max_length - angle;
        if (turn == 0 || std::abs(other) < std::abs(turn)) turn = other;
    }
    if (turn != 0) {
        const double c = std::cos(turn), s = std::sin(turn);
        local = V3(c * local.x() - s * local.y(), s * local.x() + c * local.y(), local.z());
        const V3 changed = frame.toRotationMatrix() * local * xy;
        direction.x() = changed.x();
        direction.y() = changed.y();
    }
    return direction;
}

void StepRope(const WPPuppet& puppet, PuppetIkState& state, uint32_t root,
              const Link& link, std::span<A> model) {
    if (! state.world_valid) return;
    const auto& sim = puppet.bones[link.end].simulation;
    const bool free = (sim.flags & Sim::kIkFreeEnd) != 0;
    const V3 start = Position(model[root]);
    V3 goal = Goal(link, state, model);
    const V3 d = goal - start;
    if ((sim.flags & Sim::kIkStretch) == 0 && d.norm() > link.reach && link.reach > 0) {
        goal = start + Unit(d) * link.reach;
    }
    state.rope_current[root] = state.world * start;
    if (! free) {
        Position(model[link.end], goal);
        state.rope_current[link.end] = state.world * goal;
    }
    const usize limit = link.bones.size() - (free ? 0 : 1);
    const auto* forces = state.forces.get();
    const bool wind = forces && forces->wind_enabled && forces->wind_strength != 0;
    const V3 gravity = forces && (sim.flags & Sim::kGravity) != 0
        ? (forces->Gravity() * sim.mass).cast<double>() : V3::Zero();
    const bool accelerate = wind || gravity.squaredNorm() != 0;
    if (! state.rope_primed[root]) {
        for (usize i = 1; i < limit; ++i) {
            const auto bone = link.bones[i];
            state.rope_current[bone] = state.world * Position(model[bone]);
            state.rope_previous[bone] = state.rope_current[bone];
        }
        state.rope_primed[root] = true;
    }
    for (usize i = 1; i < limit; ++i) {
        const auto bone = link.bones[i];
        if (state.advance) {
            const V3 old = state.rope_current[bone];
            const V3 velocity = old - state.rope_previous[bone];
            V3 next = old + velocity;
            // 0x14026EB60 uses tf (already squared by the IK-only JSON parser),
            // not exp(-ikrd*dt). ikrd controls the end bone's orientation below.
            if (state.dt * state.dt > 1.1920929e-7 && sim.trans_friction > 0.01f &&
                velocity.squaredNorm() > 0.0001) next -= velocity * sim.trans_friction;
            // sub_14026EB60 samples wind at the predicted world point, before the
            // acceleration is added. Gravity alone is scaled by the end bone's mass.
            if (accelerate) {
                V3 acceleration = gravity;
                if (wind) acceleration += forces->WindAt(static_cast<float>(next.x()),
                                                          static_cast<float>(state.time)).cast<double>();
                next += acceleration * (state.dt * state.dt);
            }
            state.rope_previous[bone] = old;
            state.rope_current[bone] = next;
        }
        Position(model[bone], state.world_inverse * state.rope_current[bone]);
    }
}

// sub_14026E340: one sweep of world-space Verlet points constrained in model space.
void ConstrainRope(const WPPuppet& puppet, PuppetIkState& state, const Link& link,
                   std::span<A> model, bool forward) {
    if (! state.world_valid || link.bones.size() < 2) return;
    const auto& sim = puppet.bones[link.end].simulation;
    const bool free = (sim.flags & Sim::kIkFreeEnd) != 0;
    double scale = 1;
    const V3 end = state.world_inverse * state.rope_current[link.bones.back()];
    const V3 start = state.world_inverse * state.rope_current[link.bones.front()];
    const double distance = (end - start).norm();
    if ((sim.flags & Sim::kIkStretch) != 0 && link.reach > 0 && distance > link.reach) scale = distance / link.reach;
    const usize limit = link.bones.size() - (free ? 0 : 1);
    for (usize i = 1; i < limit; ++i) {
        const usize at = forward ? i : link.bones.size() - i;
        const auto child = link.bones[at], parent = link.bones[at - 1];
        V3 a = state.world_inverse * state.rope_current[parent];
        V3 b = state.world_inverse * state.rope_current[child];
        const V3 delta = b - a;
        const double length = delta.norm();
        const double error = state.plan->lengths[child] * scale - length;
        if (std::abs(error) <= 0.001) continue;
        const V3 change = (length > 0.01 ? V3(delta / length) : V3(0.707, 0.707, 0)) * error;
        if (i == 1 && forward) b += change;
        else if (i == 1) a -= change;
        else { a -= change * 0.5; b += change * 0.5; }
        state.rope_current[parent] = state.world * a;
        state.rope_current[child] = state.world * b;
        Position(model[parent], a);
        Position(model[child], b);
    }
}

void Backward(const WPPuppet& puppet, PuppetIkState& state, uint32_t root,
              const Link& link, std::span<A> model) {
    if ((link.flags & 4) != 0) { ConstrainRope(puppet, state, link, model, false); return; }
    const V3 start = Position(model[root]);
    V3 goal = Goal(link, state, model);
    const V3 axis = Unit(goal - start);
    double distance = (goal - start).norm();
    if (link.minimum_reach > distance) { distance = link.minimum_reach; goal = start + axis * distance; }
    V3 pole = V3::Zero();
    if (link.pole >= 0) {
        pole = Position(state.targets[static_cast<usize>(link.pole)]) - goal;
        pole -= axis * pole.dot(axis);
    }
    const V3 normal = Unit(axis.cross(pole));
    Position(model[link.end], goal);
    const bool bend = distance < link.reach || (link.flags & 2) != 0;
    double walked = 0;
    for (usize i = link.bones.size() - 1; i > 0; --i) {
        const auto child = link.bones[i], parent = link.bones[i - 1];
        const V3 at = Position(model[child]);
        V3 direction = bend ? V3(Position(model[parent]) - at) : V3(-axis);
        if (bend) {
            if (i > 1) direction = -LimitDirection(puppet, model, parent, -direction);
            if (i + 1 == link.bones.size() || link.reach * 0.5 > walked + state.plan->lengths[child]) {
                if (pole.squaredNorm() > 0.01) direction -= normal * direction.dot(normal);
                const double side = direction.dot(pole);
                if (side < 0) direction -= pole * (2 * side);
            }
        }
        Position(model[parent], at + Unit(direction, -axis) * state.plan->lengths[child]);
        walked += state.plan->lengths[child];
    }
}

void RecoverRotations(const WPPuppet& puppet, PuppetIkState& state,
                       const PuppetIkPlan::Chain& chain, std::span<A> model) {
    for (const auto& segment : chain.segments) {
        Q root_sum = Q::Identity();
        usize root_count = 0;
        for (const auto& link : segment.links) {
            const usize first = segment.links.size() == 1 ? 0 : 1;
            for (usize i = first; i + 1 < link.bones.size(); ++i) {
                const auto bone = link.bones[i], child = link.bones[i + 1];
                const V3& reference = link.reference_directions[i];
                const Q rotation = Rotation(reference, Position(model[child]) - Position(model[bone]));
                Linear(model[bone], rotation.toRotationMatrix() * Linear(state.plan->reference[bone]));
            }
            if (segment.links.size() > 1 && link.bones.size() > 1) {
                const auto child = link.bones[1];
                const Q rotation = Rotation(link.reference_directions.front(),
                                              Position(model[child]) - Position(model[segment.root]));
                root_sum = root_count == 0 ? rotation : root_sum.slerp(1.0 / static_cast<double>(root_count + 1), rotation);
                ++root_count;
            }
            if (link.goal >= 0) {
                const auto& sim = puppet.bones[link.end].simulation;
                if ((sim.flags & Sim::kIkFreeEnd) != 0) {
                    if (link.bones.size() > 2) Linear(model[link.end], Linear(model[link.bones[link.bones.size() - 2]]));
                } else {
                    const auto& target = state.targets[static_cast<usize>(link.goal)];
                    auto rotation = UnitColumns(target);
                    const V3 delta = Position(target) - Position(model[link.end]);
                    const double distance = delta.norm();
                    if ((sim.flags & Sim::kIkRope) != 0 && distance > 1) {
                        const double mix = std::min((distance - 1) / std::max(1.0f, sim.ik_rope_damping), 1.0);
                        rotation = Q(rotation).slerp(mix, Rotation(V3(1, 0, 0), delta)).toRotationMatrix();
                    }
                    Linear(model[link.end], rotation);
                }
            }
        }
        if (root_count > 0) Linear(model[segment.root], root_sum.toRotationMatrix() * Linear(state.plan->reference[segment.root]));
    }
}
} // namespace

std::shared_ptr<const PuppetIkPlan> PreparePuppetIk(const WPPuppet& puppet) {
    if (puppet.bones.empty() || (puppet.ik_chains.empty() && puppet.bone_links.empty())) return {};
    auto plan = std::make_shared<PuppetIkPlan>();
    const usize count = puppet.bones.size();
    const auto curve_slot = [&](uint32_t curve) {
        const auto found = std::find(plan->link_curve_indices.begin(),plan->link_curve_indices.end(),curve);
        const auto slot = static_cast<uint32_t>(found-plan->link_curve_indices.begin());
        if (found == plan->link_curve_indices.end()) plan->link_curve_indices.push_back(curve);
        return slot;
    };
    for (const auto& rule : puppet.bone_links) {
        if (rule.bone >= count || rule.link_b >= count || rule.link_a >= puppet.bone_links.size() ||
            (puppet.bones[rule.bone].sim_type & 2) != 0) continue;
        // 0x140200E20..0x1402011B9: ordinary bones always blend full TRS, ignoring IK flags.
        plan->bone_links.push_back({rule.bone,rule.link_b,curve_slot(rule.link_a)});
    }
    std::stable_sort(plan->bone_links.begin(),plan->bone_links.end(),
        [](const auto& a,const auto& b){return a.bone<b.bone;});
    if (puppet.ik_chains.empty()) return plan->bone_links.empty() ? nullptr : plan;
    plan->at_bone.assign(count, -1);
    plan->driven.assign(count, false);
    plan->lengths.resize(count);
    plan->reference.resize(count);
    std::vector<int32_t> goal(count, -1), pole(count, -1), first_goal(count, -1);
    for (usize i = 0; i < puppet.ik_targets.size(); ++i) {
        const auto& target = puppet.ik_targets[i];
        if (target.bone < count) {
            if (target.type == 0) {
                goal[target.bone] = static_cast<int32_t>(i);
                if (first_goal[target.bone] < 0) first_goal[target.bone] = static_cast<int32_t>(i);
            }
            if (target.type == 1) pole[target.bone] = static_cast<int32_t>(i);
        }
        const A& base = target.has_reference ? target.reference : target.matrix;
        auto rotation = UnitColumns(base);
        V3 scale;
        for (int c = 0; c < 3; ++c) scale[c] = V3(base(0, c), base(1, c), base(2, c)).norm();
        if (Linear(base).determinant() < 0) {
            scale.x() = -scale.x();
            for (int r = 0; r < 3; ++r) rotation(r, 0) = -rotation(r, 0);
        }
        plan->targets.push_back({ Position(base), scale, Q(rotation) });
    }
    for (usize i = 0; i < count; ++i) {
        const auto& bone = puppet.bones[i];
        const A& local = bone.has_local_reference ? bone.local_reference : bone.local_bind;
        plan->reference[i] = bone.anim_parent < i ? plan->reference[bone.anim_parent] * local : local;
        if (bone.anim_parent >= i && puppet.world_anchored_bones) plan->reference[i].translation() += bone.vertex_centroid_offset;
        const double stored = i < puppet.bone_table.size() ? puppet.bone_table[i] : 0;
        plan->lengths[i] = stored > 0 && std::isfinite(stored) ? stored : Position(local).norm();
    }
    for (const auto& source : puppet.ik_chains) {
        if (source.bone >= count) continue;
        PuppetIkPlan::Chain chain;
        chain.root = source.bone;
        for (const auto& piece : source.segments) {
            if (piece.bone >= count) continue;
            PuppetIkPlan::Segment segment;
            segment.root = piece.bone;
            for (const auto& entry : piece.links) {
                if (entry.a >= count || entry.bones.size() < 2 || entry.bones.front() != piece.bone ||
                    entry.bones.back() != entry.a ||
                    std::any_of(entry.bones.begin(), entry.bones.end(), [&](uint32_t b) { return b >= count; }) ||
                    ((entry.flags & 1) != 0 && goal[entry.a] < 0)) continue;
                Link link;
                link.end = entry.a;
                link.flags = entry.flags;
                link.goal = (entry.flags & 1) != 0 ? goal[entry.a] : -1;
                link.pole = pole[entry.a];
                link.bones = entry.bones;
                link.reference_directions.reserve(link.bones.size() - 1);
                for (usize i = 0; i + 1 < link.bones.size(); ++i) {
                    const auto bone = link.bones[i], child = link.bones[i + 1];
                    V3 direction = Position(plan->reference[child]) - Position(plan->reference[bone]);
                    // sub_140269400 reads this cached MDLS direction during recovery. Resolve
                    // it once here; no per-frame neighbour search or new pose buffer is needed.
                    if (bone < puppet.bone_neighbours.size()) {
                        const auto& neighbours = puppet.bone_neighbours[bone];
                        const auto found = std::find_if(neighbours.begin(), neighbours.end(),
                                                        [child](const auto& n) { return n.bone == child; });
                        if (found != neighbours.end()) {
                            const V3 stored(found->values[0], found->values[1], found->values[2]);
                            if (stored.allFinite() && stored.squaredNorm() > 1e-12) direction = stored;
                        }
                    }
                    link.reference_directions.push_back(direction);
                }
                link.reach = std::bit_cast<float>(entry.b);
                link.minimum_reach = std::bit_cast<float>(entry.c);
                if (! std::isfinite(link.reach) || link.reach <= 0) {
                    link.reach = 0;
                    for (usize i = 1; i < link.bones.size(); ++i) link.reach += plan->lengths[link.bones[i]];
                }
                if (! std::isfinite(link.minimum_reach)) link.minimum_reach = 0;
                plan->has_rope = plan->has_rope || (link.flags & 4) != 0;
                for (auto b : link.bones) if (std::find(chain.affected.begin(), chain.affected.end(), b) == chain.affected.end()) chain.affected.push_back(b);
                segment.links.push_back(std::move(link));
            }
            if (! segment.links.empty()) chain.segments.push_back(std::move(segment));
        }
        if (chain.segments.empty()) continue;
        // The loader places an IK-driven bone's rules on its first position
        // target. The composer visits only the targets explicitly named by
        // this chain, in their stored order, then their rules in file order.
        for (const auto target : source.targets) {
            if (target >= puppet.ik_targets.size()) continue;
            const auto owner = puppet.ik_targets[target].bone;
            if (owner >= count || (puppet.bones[owner].sim_type & 2) == 0 ||
                first_goal[owner] != static_cast<int32_t>(target))
                continue;
            for (const auto& rule : puppet.bone_links) {
                if (rule.bone != owner || rule.link_b >= count || rule.link_a >= puppet.bone_links.size()) continue;
                using Mode = PuppetIkPlan::TargetLink::Mode;
                const Mode mode = (rule.flags & 0x10000u) != 0 ? Mode::Grounding :
                    (rule.flags & 2) != 0 ? Mode::Axis : (rule.flags & 1) != 0 ? Mode::Position : Mode::Transform;
                if (mode == Mode::Axis || mode == Mode::Grounding) {
                    for (uint32_t segment=0;segment<chain.segments.size();++segment)
                        for (uint32_t link=0;link<chain.segments[segment].links.size();++link) {
                            if (chain.segments[segment].links[link].end != owner) continue;
                            const auto index = static_cast<uint32_t>(chain.target_links.size());
                            chain.target_links.push_back({target,rule.link_b,curve_slot(rule.link_a),mode});
                            if (mode == Mode::Grounding) chain.grounding_links.push_back({index,segment,link});
                        }
                } else {
                    chain.target_links.push_back({target,rule.link_b,curve_slot(rule.link_a),mode});
                }
            }
        }
        plan->at_bone[source.bone] = static_cast<int32_t>(plan->chains.size());
        plan->chains.push_back(std::move(chain));
    }
    if (plan->chains.empty()) {
        if (plan->bone_links.empty()) return {};
        // Empty or rejected authored chains must not leave solver capacity on
        // a plan whose only real consumers are ordinary bone rules.
        std::vector<int32_t>().swap(plan->at_bone);
        std::vector<bool>().swap(plan->driven);
        std::vector<double>().swap(plan->lengths);
        std::vector<A>().swap(plan->reference);
        std::vector<PuppetIkPlan::Target>().swap(plan->targets);
        return plan;
    }
    for (usize i = 0; i < count; ++i) plan->driven[i] = (puppet.bones[i].sim_type & 2) != 0 && plan->at_bone[i] < 0;
    return plan;
}

PuppetIkState::PuppetIkState(std::shared_ptr<const PuppetIkPlan> value) : plan(std::move(value)) {
    targets.assign(plan->targets.size(), A::Identity());
    link_weights.assign(plan->link_curve_indices.size(), 0);
    if (plan->has_rope) {
        rope_current.assign(plan->reference.size(), V3::Zero());
        rope_previous.assign(plan->reference.size(), V3::Zero());
        rope_primed.assign(plan->reference.size(), false);
    }
}

void BeginPuppetIkFrame(PuppetIkState& state, double time, const std::array<double, 16>& world) {
    state.advance = std::isfinite(time) && (! state.clock_started || state.time != time);
    state.dt = state.clock_started && state.advance ? std::clamp(time - state.time, 0.0, 0.25) : 0;
    if (state.advance) { state.time = time; state.clock_started = true; }
    if (! state.plan->has_rope) return;
    for (int c = 0; c < 4; ++c) for (int r = 0; r < 4; ++r) state.world(r, c) = world[static_cast<usize>(c * 4 + r)];
    const double determinant = state.world.linear().determinant();
    state.world_valid = std::isfinite(determinant) && std::abs(determinant) > 1e-12;
    if (state.world_valid) state.world_inverse = state.world.inverse();
}

void ApplyPuppetBoneLinks(PuppetIkState& state, uint32_t bone, usize& next_link, std::span<A> model) {
    while (next_link < state.plan->bone_links.size() && state.plan->bone_links[next_link].bone == bone) {
        const auto& link = state.plan->bone_links[next_link++];
        const float weight = state.link_weights[link.weight_slot];
        if (std::isfinite(weight)) BlendLink(model[bone],model[link.source_bone],weight);
    }
}

void SolvePuppetIk(const WPPuppet& puppet, PuppetIkState& state, usize index, std::span<A> model) {
    const auto& chain = state.plan->chains[index];
    ApplyTargetLinks(state, chain, model);
    const V3 anchor = Position(model[chain.root]);
    for (const auto& segment : chain.segments) for (const auto& link : segment.links) {
        if ((link.flags & 4) != 0) StepRope(puppet, state, segment.root, link, model);
    }
    for (int iteration = 0; iteration < 10; ++iteration) {
        for (auto segment = chain.segments.rbegin(); segment != chain.segments.rend(); ++segment) {
            V3 centre = V3::Zero();
            usize count = 0;
            for (auto link = segment->links.rbegin(); link != segment->links.rend(); ++link) {
                Backward(puppet, state, segment->root, *link, model);
                if ((link->flags & 4) == 0) { centre += Position(model[segment->root]); ++count; }
            }
            if (count > 0) Position(model[segment->root], centre / static_cast<double>(count));
        }
        // The native correction runs only after the first backward sweep and
        // is gated by the rule bit, independently of its animation weight.
        if (iteration == 0) ReflectGroundedJoints(state,chain,model);
        bool reached = true;
        for (const auto& segment : chain.segments) for (const auto& link : segment.links) {
            if ((link.flags & 4) != 0) { ConstrainRope(puppet, state, link, model, true); continue; }
            if (segment.root == chain.root && puppet.bones[chain.root].anim_parent != WPPuppet::NO_PARENT) Position(model[chain.root], anchor);
            for (usize i = 0; i + 1 < link.bones.size(); ++i) {
                const auto bone = link.bones[i], child = link.bones[i + 1];
                const V3 at = Position(model[bone]);
                V3 direction = Unit(Position(model[child]) - at);
                if (i > 0) direction = LimitDirection(puppet, model, bone, direction);
                Position(model[child], at + direction * state.plan->lengths[child]);
            }
            if (link.goal >= 0 && (Position(model[link.end]) - Goal(link, state, model)).squaredNorm() > 0.1) reached = false;
        }
        if (reached) break;
    }
    RecoverRotations(puppet, state, chain, model);
}
} // namespace wallpaper
