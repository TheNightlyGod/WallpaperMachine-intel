// Clean-room implementation from the WallpaperMachine spec e2-runtime-animation.md; written without access to the original source.
#include "Runtime/SceneSettingResolver.hpp"

#include "Runtime/DynamicValue.hpp"
#include "Runtime/NumberText.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/ScriptedDynamicValue.hpp"
#include "Scripting/ScriptModuleSyntax.hpp"

#include <nlohmann/json.hpp>

#include <algorithm>
#include <array>
#include <cmath>
#include <iterator>
#include <sstream>

namespace wallpaper
{
namespace
{

// ---------------------------------------------------------------------------
// Reading an authored value. Every reader first looks through one level of
// `{"value": ...}`.
// ---------------------------------------------------------------------------

const nlohmann::json& Unwrapped(const nlohmann::json& node) {
    if (node.is_object()) {
        const auto value = node.find("value");
        if (value != node.end()) return *value;
    }
    return node;
}

float NumberOf(const nlohmann::json& value) {
    if (value.is_number()) {
        const auto number = static_cast<float>(value.get<double>());
        return std::isfinite(number) ? number : 0.0f;
    }
    if (value.is_boolean()) return value.get<bool>() ? 1.0f : 0.0f;
    if (value.is_string()) return LeadingNumberOrZero(value.get_ref<const std::string&>());
    return 0.0f;
}

float read_number(const nlohmann::json& setting) { return NumberOf(Unwrapped(setting)); }

bool parse_bool(const nlohmann::json& setting) {
    const auto& value = Unwrapped(setting);
    if (value.is_boolean()) return value.get<bool>();
    if (value.is_number()) return value.get<double>() != 0.0;
    if (value.is_string()) {
        const auto& text = value.get_ref<const std::string&>();
        return text == "true" || text == "1";
    }
    return false;
}

std::string read_text(const nlohmann::json& setting) {
    const auto& value = Unwrapped(setting);
    if (value.is_string()) return value.get<std::string>();
    if (value.is_object()) {
        const auto text = value.find("text");
        if (text != value.end() && text->is_string()) return text->get<std::string>();
    }
    return {};
}

// One lane of a vector setting: an array element that is a number, the n-th number of a text,
// or, for lane 0, a lone number.
float read_lane(const nlohmann::json& setting, std::size_t lane) {
    const auto& value = Unwrapped(setting);
    if (value.is_array()) {
        return lane < value.size() && value[lane].is_number() ? NumberOf(value[lane]) : 0.0f;
    }
    if (value.is_string() && lane < 4) {
        float lanes[4];
        ReadNumberList(value.get_ref<const std::string&>(), lanes, lane + 1);
        return lanes[lane];
    }
    if (lane == 0 && (value.is_number() || value.is_boolean())) return NumberOf(value);
    return 0.0f;
}

// The lanes of a two- or four-component constant: a lone number fills every lane.
template<std::size_t N>
std::array<float, N> read_lanes(const nlohmann::json& setting) {
    std::array<float, N> lanes {};
    const auto&          value = Unwrapped(setting);
    for (std::size_t i = 0; i < N; ++i) lanes[i] = value.is_number() ? NumberOf(value) : read_lane(value, i);
    return lanes;
}

linalg::Vector3f parse_vec3(const nlohmann::json& setting) {
    const auto& value = Unwrapped(setting);
    if (value.is_array()) {
        if (value.size() < 3) return linalg::Vector3f::Zero();
        for (std::size_t i = 0; i < 3; ++i) {
            if (!value[i].is_number()) return linalg::Vector3f::Zero();
        }
        return linalg::Vector3f(NumberOf(value[0]), NumberOf(value[1]), NumberOf(value[2]));
    }
    if (value.is_number()) {
        const float lane = NumberOf(value);
        return linalg::Vector3f(lane, lane, lane);
    }
    if (value.is_string()) {
        float lanes[3];
        ReadNumberList(value.get_ref<const std::string&>(), lanes, 3);
        return linalg::Vector3f(lanes[0], lanes[1], lanes[2]);
    }
    return linalg::Vector3f::Zero();
}

// What a setting's `user` member asks for: the property to follow, in either authored form, and
// a condition that only the object form can carry (it needs a text name and a text condition).
struct UserLink
{
    std::string                  property;
    std::optional<ConditionInfo> condition;
};

UserLink ReadUserLink(const nlohmann::json& setting) {
    UserLink link;
    if (!setting.is_object()) return link;
    const auto user = setting.find("user");
    if (user == setting.end()) return link;
    if (user->is_string()) {
        link.property = user->get<std::string>();
        return link;
    }
    if (!user->is_object()) return link;
    const auto name = user->find("name");
    if (name == user->end() || !name->is_string()) return link;
    link.property = name->get<std::string>();
    const auto condition = user->find("condition");
    if (condition != user->end() && condition->is_string()) {
        link.condition = ConditionInfo { link.property, condition->get<std::string>() };
    }
    return link;
}

// How a value reads its property: as one whole value, or as the three lanes of a vector.
enum class FollowShape { Whole, Vec3 };

// Makes `value` follow the property its setting names, if any. The condition goes on before the
// first read. A property the table does not declare yet is followed once a document supplies it;
// until then the value keeps its own authored value, as Wallpaper Engine shows it: there is no
// choice to compare a condition with, and another setting's authored value is not this one's.
void FollowUserProperty(SceneRuntimeContext& context, const nlohmann::json& setting,
                        FollowShape shape, DynamicValue& value) {
    const UserLink link = ReadUserLink(setting);
    if (link.property.empty()) return;
    const bool    declared = context.FindPropertyValue(link.property) != nullptr;
    DynamicValue* target   = context.FollowProperty(link.property, value);
    if (target == nullptr) return;
    if (link.condition) value.attachCondition(*link.condition);
    if (shape == FollowShape::Vec3) {
        value.connectVec3(target, declared);
    } else {
        value.connect(target, declared);
    }
}

bool mentions_scene_event_registration(const std::string& script) {
    for (const char* call : { "engine.on(", "scene.on(", "thisScene.on(" }) {
        if (script.find(call) != std::string::npos) return true;
    }
    return false;
}

// Where a value script lives, which the script host needs to pick its `thisObject`.
struct ScriptSite
{
    std::string_view      layer_name;
    ScriptedValueSemantic semantic { ScriptedValueSemantic::Generic };
    int                   animation_layer { -1 };
    // The effect whose visibility the script decides, and the clock of the keyed setting it
    // sits on.
    std::string                              effect_reference;
    std::shared_ptr<ScalarAnimationPlayback> own_animation;
};

DynamicValueUniquePtr resolve_auto_setting(SceneRuntimeContext& context, const nlohmann::json& setting,
                                           std::string_view current_layer_name = {});

// The scripted value for a setting that carries a value script, seeded with `seed`; null when
// the setting has none. A script that only registers scene events is not a value script.
DynamicValueUniquePtr MakeScriptedValue(SceneRuntimeContext& context, const nlohmann::json& setting,
                                        const DynamicValue& seed, const ScriptSite& site) {
    const auto* source = [&]() -> const std::string* {
        if (!setting.is_object()) return nullptr;
        const auto script = setting.find("script");
        if (script == setting.end() || !script->is_string()) return nullptr;
        return &script->get_ref<const std::string&>();
    }();
    if (source == nullptr) return nullptr;
    if (!ExportsFunction(*source, "update") && mentions_scene_event_registration(*source)) {
        return nullptr;
    }

    std::map<std::string, DynamicValueUniquePtr> owned;
    if (const auto declared = setting.find("scriptproperties");
        declared != setting.end() && declared->is_object()) {
        for (const auto& [key, item] : declared->items()) {
            owned.emplace(key, resolve_auto_setting(context, item, site.layer_name));
        }
    }
    std::string animation_reference;
    if (site.own_animation != nullptr) animation_reference = context.RegisterSettingAnimation(site.own_animation);
    auto scripted = std::make_unique<ScriptedDynamicValue>(
        context, *source, std::string(site.layer_name), std::move(owned), seed, site.semantic,
        site.animation_layer, site.effect_reference, std::move(animation_reference));
    context.RegisterScriptedValue(scripted.get());
    return scripted;
}

// Finishes a resolver: lets a value script take over from the literal, then binds the property
// last so that a property change overwrites what a script produced.
DynamicValueUniquePtr Finish(SceneRuntimeContext& context, const nlohmann::json& setting,
                             DynamicValueUniquePtr literal, const ScriptSite& site,
                             FollowShape shape) {
    if (auto scripted = MakeScriptedValue(context, setting, *literal, site)) {
        literal = std::move(scripted);
    }
    FollowUserProperty(context, setting, shape, *literal);
    return literal;
}

// A script property is resolved by the kind its authored value has.
DynamicValueUniquePtr resolve_auto_setting(SceneRuntimeContext& context, const nlohmann::json& setting,
                                           std::string_view current_layer_name) {
    const auto& value = Unwrapped(setting);
    if (value.is_boolean()) return ResolveBoolSetting(context, setting, current_layer_name);
    DynamicValueUniquePtr resolved;
    if (value.is_number()) {
        resolved = std::make_unique<DynamicValue>(NumberOf(value));
    } else if (value.is_string()) {
        resolved = std::make_unique<DynamicValue>(value.get<std::string>());
    } else {
        resolved = std::make_unique<DynamicValue>();
    }
    FollowUserProperty(context, setting, FollowShape::Whole, *resolved);
    return resolved;
}

} // namespace

bool InitialBoolSetting(const nlohmann::json& setting)
{
    return parse_bool(setting);
}

std::string UserPropertyName(const nlohmann::json& setting)
{
    return ReadUserLink(setting).property;
}

namespace
{
// Cubic Bernstein form in power basis: p0 (1-u)^3 + 3 p1 u (1-u)^2 + 3 p2 u^2 (1-u) + p3 u^3.
struct Cubic
{
    double c0, c1, c2, c3;
    Cubic(double p0, double p1, double p2, double p3)
        : c0(p0), c1(3.0 * (p1 - p0)), c2(3.0 * (p2 - 2.0 * p1 + p0)),
          c3(p3 - 3.0 * p2 + 3.0 * p1 - p0) {}
    double At(double u) const { return ((c3 * u + c2) * u + c1) * u + c0; }
    double Slope(double u) const { return (3.0 * c3 * u + 2.0 * c2) * u + c1; }
};

// The curve parameter in 0..1 at which the time cubic (0, x1, x2, 1) reaches `time`. Time never
// decreases with the parameter, so the root stays inside a shrinking bracket; Newton steps
// converge fast and a step that leaves the bracket (or a flat spot) falls back to its midpoint.
double ParameterAtTime(const Cubic& clock, double time) {
    double lo = 0.0;
    double hi = 1.0;
    double u  = std::clamp(time, 0.0, 1.0);
    for (int round = 0; round < 64; ++round) {
        const double miss = clock.At(u) - time;
        if (miss == 0.0) return u;
        (miss < 0.0 ? lo : hi) = u;
        if (hi - lo < 1e-12) break;
        const double slope = clock.Slope(u);
        double       next  = slope > 1e-12 ? u - miss / slope : -1.0;
        if (!(next > lo && next < hi)) next = 0.5 * (lo + hi);
        if (std::abs(next - u) < 1e-13) return next;
        u = next;
    }
    return 0.5 * (lo + hi);
}

// The value between two keys at `along` (0..1 of their interval), `span` frames apart.
double ValueBetween(const ScalarAnimationKeyframe& from, const ScalarAnimationKeyframe& to,
                    double span, double along) {
    const double a = from.value;
    const double b = to.value;
    if (!from.front.enabled && !to.back.enabled) return a + (b - a) * along;
    const double x1 = from.front.enabled ? std::clamp(from.front.x / span, 0.0, 1.0) : 1.0 / 3.0;
    const double x2 = to.back.enabled ? std::clamp(1.0 + to.back.x / span, x1, 1.0) : 2.0 / 3.0;
    const double y1 = from.front.enabled ? a + from.front.y : a + (b - a) / 3.0;
    const double y2 = to.back.enabled ? b + to.back.y : b - (b - a) / 3.0;
    const double u  = ParameterAtTime(Cubic(0.0, x1, x2, 1.0), along);
    return Cubic(a, y1, y2, b).At(u);
}
} // namespace

float ScalarAnimation::Evaluate(double seconds) const {
    if (keyframes.empty() || std::isnan(fps) || fps <= 0.0) return initial_value;
    if (!std::isfinite(seconds) || seconds < 0.0) return initial_value;

    const double total   = FrameCount();
    const bool   mirror  = mode == ScalarAnimationMode::Mirror && total > 0.0;
    const bool   looping = (mode == ScalarAnimationMode::Loop && total > 0.0) || mirror;
    double       frame   = seconds * fps;
    if (mirror) {
        // Forward over the first length of each double length, back over the second.
        frame = std::fmod(frame, 2.0 * total);
        if (frame > total) frame = 2.0 * total - frame;
    } else if (looping) {
        frame = std::fmod(frame, total);
    }
    // A time so large that it overflows the frame position has no position in the loop.
    if (std::isnan(frame)) return initial_value;
    if (frame < keyframes.front().frame) return looping ? keyframes.front().value : initial_value;

    // `later` is the first key beyond the playhead (of keys sharing a frame, the last one wins).
    const auto later = std::partition_point(keyframes.begin(), keyframes.end(),
                                            [frame](const ScalarAnimationKeyframe& key) {
                                                return key.frame <= frame;
                                            });
    if (later == keyframes.end()) return keyframes.back().value;
    const ScalarAnimationKeyframe& to   = *later;
    const ScalarAnimationKeyframe& from = *std::prev(later);
    if (frame == from.frame) return from.value;
    const double span = to.frame - from.frame;
    if (!(span > 0.0)) return to.value;
    return static_cast<float>(ValueBetween(from, to, span, (frame - from.frame) / span));
}

double ScalarAnimation::FrameCount() const
{
    return length_frames > 0.0 ? length_frames : (keyframes.empty() ? 0.0 : keyframes.back().frame);
}

namespace
{
// Markers fire as the playhead travels across their frame: departure exclusive,
// arrival inclusive, in the order they are met. A loop runs on a circle, so the
// distance is measured along the direction of travel — that makes a wrap, an
// exact landing on the seam and a marker authored at the period the same point.
// Travelling at least a whole period reports each marker once, never once per
// lap, so one stalled frame cannot flood the queue. A mirror is a circle of twice
// the length, on which a marker sits twice, once on the way out and once on the
// way back (once only at either end), and `previous` is the position on it.
void CollectCrossedEvents(const ScalarAnimation& animation, double previous, double travelled,
                          double length, std::vector<ScalarAnimationEvent>& out)
{
    if (animation.events.empty() || travelled == 0.0 || !std::isfinite(travelled)) return;

    const bool circular = (animation.mode == ScalarAnimationMode::Loop
                           || animation.mode == ScalarAnimationMode::Mirror)
                          && length > 0.0;
    if (!circular) {
        const double arrival = std::clamp(previous + travelled, 0.0, std::max(0.0, length));
        if (travelled > 0.0) {
            for (const auto& event : animation.events) {
                if (!event.name.empty() && event.frame > previous && event.frame <= arrival) {
                    out.push_back(event);
                }
            }
        } else {
            for (auto event = animation.events.rbegin(); event != animation.events.rend(); ++event) {
                if (!event->name.empty() && event->frame >= arrival && event->frame < previous) {
                    out.push_back(*event);
                }
            }
        }
        return;
    }

    const bool   mirror = animation.mode == ScalarAnimationMode::Mirror;
    const double period = mirror ? 2.0 * length : length;
    const auto wrap = [period](double value) {
        const double wrapped = std::fmod(value, period);
        return wrapped < 0.0 ? wrapped + period : wrapped;
    };
    const double start    = wrap(previous);
    const double distance = std::abs(travelled);
    const bool   forward  = travelled > 0.0;
    std::vector<std::pair<double, const ScalarAnimationEvent*>> met;
    const auto meet = [&](double position, const ScalarAnimationEvent& event) {
        const double delta = wrap(forward ? position - start : start - position);
        if (distance >= period) {
            // A full lap returns to the departure frame, so that marker is last.
            met.emplace_back(delta == 0.0 ? period : delta, &event);
        } else if (delta > 0.0 && delta <= distance) {
            met.emplace_back(delta, &event);
        }
    };
    for (const auto& event : animation.events) {
        if (event.name.empty()) continue;
        // A mirror turns at its ends, so a marker past either is never reached.
        if (mirror && (event.frame < 0.0 || event.frame > length)) continue;
        meet(event.frame, event);
        const double back = period - event.frame;
        if (mirror && wrap(back) != wrap(event.frame)) meet(back, event);
    }
    std::sort(met.begin(), met.end(), [](const auto& left, const auto& right) {
        return left.first < right.first;
    });
    for (const auto& [delta, event] : met) out.push_back(*event);
}
} // namespace

void ScalarAnimationPlayback::Advance(double seconds)
{
    if (!playing || !std::isfinite(seconds) || seconds <= 0.0) return;
    // A clock of no (or a negative) frame rate moves nothing.
    if (!(animation.fps > 0.0)) return;
    const double length = animation.FrameCount();
    const double previous = frame;
    const double next = frame + seconds * animation.fps * rate;
    if (animation.mode == ScalarAnimationMode::Mirror && length > 0.0) {
        // The position on a circle of twice the length: out to the end, then back.
        const double period = 2.0 * length;
        const double phase  = reversing ? period - frame : frame;
        const double travel = seconds * animation.fps * rate;
        double       ahead  = std::fmod(phase + travel, period);
        if (ahead < 0.0) ahead += period;
        reversing = ahead > length;
        frame     = reversing ? period - ahead : ahead;
        CollectCrossedEvents(animation, phase, travel, length, pending_events);
        return;
    }
    if (animation.mode == ScalarAnimationMode::Loop && length > 0.0) {
        frame = std::fmod(next, length);
        if (frame < 0.0) frame += length;
    } else {
        frame = std::clamp(next, 0.0, std::max(0.0, length));
        if ((rate > 0.0 && next >= length) || (rate < 0.0 && next <= 0.0)) playing = false;
    }
    CollectCrossedEvents(animation, previous, next - previous, length, pending_events);
}

void ScalarAnimationPlayback::Play()
{
    if (!playing && animation.mode == ScalarAnimationMode::Single) {
        if (rate >= 0.0 && frame >= animation.FrameCount()) frame = 0.0;
        else if (rate < 0.0 && frame <= 0.0) frame = animation.FrameCount();
    }
    playing = true;
}

void ScalarAnimationPlayback::Stop()
{
    playing = false;
    frame = 0.0;
    reversing = false;
}

void ScalarAnimationPlayback::SetFrame(double value)
{
    if (std::isfinite(value)) frame = std::clamp(value, 0.0, std::max(0.0, animation.FrameCount()));
}

float ScalarAnimationPlayback::Value() const
{
    return animation.Evaluate(animation.fps > 0.0 ? frame / animation.fps : 0.0);
}

std::unique_ptr<DynamicValue> ResolveBoolSetting(
    SceneRuntimeContext& context,
    const nlohmann::json& setting,
    std::string_view current_layer_name,
    int animation_layer_index,
    std::string effect_reference) {
    ScriptSite site { current_layer_name, ScriptedValueSemantic::Generic, animation_layer_index };
    site.effect_reference = std::move(effect_reference);
    return Finish(context, setting, std::make_unique<DynamicValue>(parse_bool(setting)), site,
                  FollowShape::Whole);
}

std::unique_ptr<DynamicValue> ResolveFloatSetting(
    SceneRuntimeContext& context,
    const nlohmann::json& setting,
    std::string_view current_layer_name,
    int animation_layer_index) {
    const ScriptSite site { current_layer_name, ScriptedValueSemantic::Generic,
                            animation_layer_index };
    return Finish(context, setting, std::make_unique<DynamicValue>(read_number(setting)), site,
                  FollowShape::Whole);
}

std::unique_ptr<DynamicValue> ResolveVec3Setting(
    SceneRuntimeContext& context,
    const nlohmann::json& setting,
    std::string_view current_layer_name,
    Vec3SettingSemantic semantic,
    std::shared_ptr<ScalarAnimationPlayback> own_animation) {
    ScriptSite site;
    site.layer_name    = current_layer_name;
    site.own_animation = std::move(own_animation);
    if (semantic == Vec3SettingSemantic::AnglesDegrees) {
        site.semantic = ScriptedValueSemantic::AnglesDegrees;
    }
    return Finish(context, setting, std::make_unique<DynamicValue>(parse_vec3(setting)), site,
                  FollowShape::Vec3);
}

std::unique_ptr<DynamicValue> ResolveVectorSetting(
    SceneRuntimeContext& context,
    const nlohmann::json& setting,
    std::size_t components,
    std::string_view current_layer_name,
    std::shared_ptr<ScalarAnimationPlayback> own_animation) {
    if (components == 3) {
        return ResolveVec3Setting(context, setting, current_layer_name, Vec3SettingSemantic::Generic,
                                  std::move(own_animation));
    }
    auto literal = [&]() -> DynamicValueUniquePtr {
        if (components == 2) {
            const auto lanes = read_lanes<2>(setting);
            return std::make_unique<DynamicValue>(linalg::Vector2f(lanes[0], lanes[1]));
        }
        if (components == 4) {
            const auto lanes = read_lanes<4>(setting);
            return std::make_unique<DynamicValue>(
                linalg::Vector4f(lanes[0], lanes[1], lanes[2], lanes[3]));
        }
        return std::make_unique<DynamicValue>(read_number(setting));
    }();
    ScriptSite site { current_layer_name };
    site.own_animation = std::move(own_animation);
    return Finish(context, setting, std::move(literal), site, FollowShape::Whole);
}

std::unique_ptr<DynamicValue> ResolveStringSetting(
    SceneRuntimeContext& context,
    const nlohmann::json& setting,
    std::string_view current_layer_name) {
    return Finish(context, setting, std::make_unique<DynamicValue>(read_text(setting)),
                  ScriptSite { current_layer_name }, FollowShape::Whole);
}

namespace
{
// The three curves of a vec3 setting, before any clock is chosen for them.
struct Vec3Timeline
{
    std::array<ScalarAnimation, 3> components;
    std::array<float, 3>           offset {};
    // The first keyed component supplies the clock's play state.
    std::size_t first { 3 };
    double      last_frame { 0.0 };
    // The setting this one is keyed together with (`options.parent.key`).
    std::string parent;
};

std::optional<Vec3Timeline> ReadVec3Timeline(const nlohmann::json& setting)
{
    if (!setting.is_object()) return std::nullopt;
    const auto source = setting.find("animation");
    if (source == setting.end() || !source->is_object()) return std::nullopt;

    Vec3Timeline timeline;
    const auto base = parse_vec3(setting);
    const auto relative_value = source->find("relative");
    const bool relative = relative_value != source->end() && relative_value->is_boolean() &&
                          relative_value->get<bool>();
    for (std::size_t i = 0; i < timeline.components.size(); ++i) {
        timeline.offset[i] = relative ? base[i] : 0.0f;
        auto curve = ResolveScalarAnimation(setting, i);
        if (!curve) {
            timeline.components[i].initial_value = relative ? 0.0f : base[i];
            continue;
        }
        if (timeline.first == timeline.components.size()) timeline.first = i;
        if (relative) curve->initial_value = 0.0f;
        timeline.last_frame = std::max(timeline.last_frame, curve->keyframes.back().frame);
        timeline.components[i] = std::move(*curve);
    }
    if (timeline.first == timeline.components.size()) return std::nullopt;

    if (const auto options = source->find("options"); options != source->end() &&
                                                      options->is_object()) {
        if (const auto parent = options->find("parent"); parent != options->end() &&
                                                         parent->is_object()) {
            const auto key = parent->find("key");
            if (key != parent->end() && key->is_string()) timeline.parent = key->get<std::string>();
        }
    }
    return timeline;
}

// The clock a timeline plays on: its first keyed curve's play state, as long as
// the longest curve of everything driven by it unless the author gave a length.
ScalarAnimation Vec3TimelineClock(const Vec3Timeline& timeline, double last_frame)
{
    auto clock = timeline.components[timeline.first];
    if (!(clock.length_frames > 0.0)) clock.length_frames = last_frame;
    return clock;
}

std::shared_ptr<NodeVec3Animation> MakeVec3Animation(
    Vec3Timeline timeline, std::shared_ptr<ScalarAnimationPlayback> playback)
{
    auto animation = std::make_shared<NodeVec3Animation>();
    animation->playback   = std::move(playback);
    animation->components = std::move(timeline.components);
    animation->offset     = timeline.offset;
    // Only the clock wraps; short component curves must hold their last key
    // until that shared clock loops, just like vector material timelines.
    for (auto& curve : animation->components) curve.mode = ScalarAnimationMode::Single;
    return animation;
}
} // namespace

std::array<float, 3> NodeVec3Animation::Value() const
{
    const double frame = playback != nullptr ? playback->frame : 0.0;
    std::array<float, 3> value;
    for (std::size_t i = 0; i < components.size(); ++i) {
        const auto& curve = components[i];
        value[i] = offset[i] + curve.Evaluate(curve.fps > 0.0 ? frame / curve.fps : 0.0);
    }
    return value;
}

void RegisterNodeTransformSettings(SceneRuntimeContext& context, SceneNode* node,
                                   std::string_view layer_name, const nlohmann::json& origin,
                                   const nlohmann::json& scale, const nlohmann::json& angles,
                                   bool animate)
{
    if (node == nullptr) return;
    static constexpr std::array<const char*, 3> keys { "origin", "scale", "angles" };
    const std::array<const nlohmann::json*, 3> settings { &origin, &scale, &angles };
    const std::string name(layer_name);

    // Do not introduce a second writer for a script or user property.
    std::array<std::optional<Vec3Timeline>, 3> timelines;
    std::array<bool, 3>                        bound {};
    for (std::size_t i = 0; i < settings.size(); ++i) {
        const auto& setting = *settings[i];
        if (!setting.is_object()) continue;
        bound[i] = setting.contains("script") || setting.contains("user");
        if (!bound[i] && animate) timelines[i] = ReadVec3Timeline(setting);
    }

    // A setting keyed under another one plays on that one's clock, however long
    // the chain; a parent that has no timeline, or a cycle, leaves it its own.
    const auto root_of = [&](std::size_t property) {
        std::size_t root = property;
        for (std::size_t step = 0; step < keys.size(); ++step) {
            const auto parent = std::find_if(keys.begin(), keys.end(), [&](const char* key) {
                return timelines[root]->parent == key;
            });
            if (parent == keys.end()) return root;
            const auto index = static_cast<std::size_t>(parent - keys.begin());
            if (!timelines[index]) return root;
            root = index;
        }
        return property;
    };
    std::array<std::size_t, 3> roots {};
    std::array<double, 3>      group_last_frame {};
    for (std::size_t i = 0; i < timelines.size(); ++i) {
        if (!timelines[i]) continue;
        roots[i] = root_of(i);
        group_last_frame[roots[i]] = std::max(group_last_frame[roots[i]], timelines[i]->last_frame);
    }
    std::array<std::shared_ptr<ScalarAnimationPlayback>, 3> clocks;
    for (std::size_t i = 0; i < timelines.size(); ++i) {
        if (!timelines[i] || roots[i] != i) continue;
        clocks[i] = context.RegisterScalarAnimation(
            layer_name, Vec3TimelineClock(*timelines[i], group_last_frame[i]));
    }

    // A setting a script drives is not played from its timeline, but the script reaches the
    // timeline's clock as its own (`thisObject.getAnimation()`).
    std::array<std::shared_ptr<ScalarAnimationPlayback>, 3> own_clock;
    for (std::size_t i = 0; i < settings.size(); ++i) {
        const auto& setting = *settings[i];
        if (!bound[i] || !setting.is_object() || !setting.contains("script")) continue;
        if (const auto keyed = ReadVec3Timeline(setting)) {
            own_clock[i] = context.RegisterSettingClock(Vec3TimelineClock(*keyed, keyed->last_frame));
        }
    }

    const auto animation_of = [&](std::size_t property) {
        return timelines[property]
                   ? std::shared_ptr<const NodeVec3Animation>(
                         MakeVec3Animation(std::move(*timelines[property]), clocks[roots[property]]))
                   : nullptr;
    };
    if (bound[0] || timelines[0]) {
        context.RegisterNodeTranslate(
            name, node,
            ResolveVec3Setting(context, origin, layer_name, Vec3SettingSemantic::Generic, own_clock[0]),
            animation_of(0));
    }
    if (bound[1] || timelines[1]) {
        context.RegisterNodeScale(name, node,
                                  ResolveVec3Setting(context, scale, layer_name,
                                                     Vec3SettingSemantic::Generic, own_clock[1]),
                                  animation_of(1));
    }
    if (bound[2] || timelines[2]) {
        context.RegisterNodeRotation(name, node,
                                     ResolveVec3Setting(context, angles, layer_name,
                                                        Vec3SettingSemantic::AnglesDegrees,
                                                        own_clock[2]),
                                     animation_of(2));
    }
}

std::shared_ptr<const NodeVec3Animation>
ResolveVec3Animation(SceneRuntimeContext& context, std::string_view layer_name,
                     const nlohmann::json& setting)
{
    auto timeline = ReadVec3Timeline(setting);
    if (!timeline) return nullptr;
    auto clock = Vec3TimelineClock(*timeline, timeline->last_frame);
    return MakeVec3Animation(std::move(*timeline),
                             context.RegisterScalarAnimation(layer_name, std::move(clock)));
}

namespace
{
// `wraploop`: the curve is cut at the timeline's length and ends on a key at
// that frame holding the first key's value, so a loop returns to where it began
// instead of holding its last key until the length and then jumping back
// (Wallpaper Engine's FUN_1401a98b0, run on every curve of a timeline that sets
// the flag). Keys past the length go, but never down to fewer than two. The
// closing key's incoming handle mirrors the first key's outgoing one, so the
// seam is as smooth as the curve is at its start. A curve with fewer than two
// keys, or a timeline with no length, is left as authored.
void CloseCurveAtLoopLength(ScalarAnimation& curve)
{
    auto& keys = curve.keyframes;
    if (!(curve.length_frames > 0.0) || keys.size() < 2) return;
    while (keys.size() > 1 && curve.length_frames < keys.back().frame) keys.pop_back();
    if (keys.size() < 2) return;

    const ScalarAnimationKeyframe first = keys.front();
    if (keys.back().frame != curve.length_frames) {
        ScalarAnimationKeyframe closing;
        closing.frame = curve.length_frames;
        keys.push_back(closing);
    }
    auto& closing = keys.back();
    closing.value = first.value;
    closing.back  = ScalarAnimationHandle { -first.front.x, -first.front.y, first.front.enabled };
}
} // namespace

namespace
{
float LenientNumber(const nlohmann::json& node, const char* key) {
    const auto found = node.find(key);
    return found == node.end() ? 0.0f : NumberOf(*found);
}

double LenientDouble(const nlohmann::json& node, const char* key) {
    const auto found = node.find(key);
    if (found == node.end()) return 0.0;
    if (found->is_number()) {
        const double number = found->get<double>();
        return std::isfinite(number) ? number : 0.0;
    }
    return NumberOf(*found);
}

ScalarAnimationHandle ReadHandle(const nlohmann::json& key, const char* member) {
    ScalarAnimationHandle handle;
    const auto            found = key.find(member);
    if (found == key.end() || !found->is_object()) return handle;
    const auto enabled = found->find("enabled");
    handle.enabled     = enabled != found->end() && parse_bool(*enabled);
    handle.x           = LenientDouble(*found, "x");
    handle.y           = LenientDouble(*found, "y");
    return handle;
}
} // namespace

std::optional<ScalarAnimation> ResolveScalarAnimation(const nlohmann::json& setting,
                                                      std::size_t component) {
    if (component >= 4 || !setting.is_object()) return std::nullopt;
    const auto animation = setting.find("animation");
    if (animation == setting.end() || !animation->is_object()) return std::nullopt;
    const auto options = animation->find("options");
    if (options == animation->end() || !options->is_object()) return std::nullopt;
    const auto lane = animation->find("c" + std::to_string(component));
    if (lane == animation->end() || !lane->is_array() || lane->empty()) return std::nullopt;

    ScalarAnimation curve;
    for (const auto& entry : *lane) {
        if (!entry.is_object() || !entry.contains("frame") || !entry.contains("value")) continue;
        ScalarAnimationKeyframe key;
        key.frame = LenientDouble(entry, "frame");
        key.value = LenientNumber(entry, "value");
        key.front = ReadHandle(entry, "front");
        key.back  = ReadHandle(entry, "back");
        curve.keyframes.push_back(key);
    }
    if (curve.keyframes.empty()) return std::nullopt;
    std::stable_sort(curve.keyframes.begin(), curve.keyframes.end(),
                     [](const auto& left, const auto& right) { return left.frame < right.frame; });

    curve.initial_value = read_lane(setting, component);
    curve.fps           = LenientDouble(*options, "fps");
    curve.length_frames = LenientDouble(*options, "length");
    const auto mode = options->find("mode");
    if (mode != options->end() && mode->is_string()) {
        const auto& named = mode->get_ref<const std::string&>();
        if (named == "loop") curve.mode = ScalarAnimationMode::Loop;
        else if (named == "mirror") curve.mode = ScalarAnimationMode::Mirror;
    }
    const auto name = options->find("name");
    if (name != options->end() && name->is_string()) curve.name = name->get<std::string>();
    const auto paused = options->find("startpaused");
    curve.start_paused = paused != options->end() && parse_bool(*paused);

    const auto events = options->find("events");
    if (events != options->end() && events->is_array()) {
        for (const auto& entry : *events) {
            if (!entry.is_object()) continue;
            const auto event_name = entry.find("name");
            if (event_name == entry.end() || !event_name->is_string()) continue;
            curve.events.push_back(
                ScalarAnimationEvent { LenientDouble(entry, "frame"), event_name->get<std::string>() });
        }
        std::stable_sort(curve.events.begin(), curve.events.end(),
                         [](const auto& left, const auto& right) { return left.frame < right.frame; });
    }

    const auto wrap = options->find("wraploop");
    if (wrap != options->end() && parse_bool(*wrap)) CloseCurveAtLoopLength(curve);
    return curve;
}

} // namespace wallpaper
