#include "Runtime/SceneSettingResolver.hpp"

#include "Runtime/DynamicValue.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/ScriptedDynamicValue.hpp"
#include "Scripting/ScriptModuleSyntax.hpp"

#include <nlohmann/json.hpp>

#include <algorithm>
#include <array>
#include <cmath>
#include <sstream>

namespace wallpaper
{
namespace
{

const nlohmann::json& unwrap_value(const nlohmann::json& value)
{
    if (value.is_object() && value.contains("value")) return value.at("value");
    return value;
}

Eigen::Vector3f parse_vec3(const nlohmann::json& value)
{
    const auto& source = unwrap_value(value);
    if (source.is_array() && source.size() >= 3) {
        return Eigen::Vector3f(
            source.at(0).get<float>(),
            source.at(1).get<float>(),
            source.at(2).get<float>());
    }
    if (source.is_number()) {
        const float scalar = source.get<float>();
        return Eigen::Vector3f(scalar, scalar, scalar);
    }
    if (source.is_string()) {
        std::istringstream stream(source.get<std::string>());
        float x = 0.0f;
        float y = 0.0f;
        float z = 0.0f;
        stream >> x >> y >> z;
        return Eigen::Vector3f(x, y, z);
    }
    return Eigen::Vector3f::Zero();
}

float parse_float(const nlohmann::json& value)
{
    const auto& source = unwrap_value(value);
    if (source.is_number()) return source.get<float>();
    if (source.is_boolean()) return source.get<bool>() ? 1.0f : 0.0f;
    if (source.is_string()) {
        try {
            return std::stof(source.get<std::string>());
        } catch (...) {
            return 0.0f;
        }
    }
    return 0.0f;
}

// Vector settings carry one initial value per component, either as an array or
// as a space-separated string. Scalars keep the plain single-value reading.
float parse_component(const nlohmann::json& value, std::size_t component)
{
    const auto& source = unwrap_value(value);
    if (source.is_array()) {
        return component < source.size() && source.at(component).is_number()
                   ? source.at(component).get<float>()
                   : 0.0f;
    }
    if (source.is_string()) {
        std::istringstream stream(source.get<std::string>());
        float              parsed = 0.0f;
        for (std::size_t index = 0; index <= component; ++index) {
            if (! (stream >> parsed)) return 0.0f;
        }
        return parsed;
    }
    return component == 0 ? parse_float(value) : 0.0f;
}

bool parse_bool(const nlohmann::json& value)
{
    const auto& source = unwrap_value(value);
    if (source.is_boolean()) return source.get<bool>();
    if (source.is_number()) return source.get<float>() != 0.0f;
    if (source.is_string()) return source.get<std::string>() == "true" || source.get<std::string>() == "1";
    return false;
}

std::string parse_string(const nlohmann::json& value)
{
    const auto& source = unwrap_value(value);
    if (source.is_string()) return source.get<std::string>();
    if (source.is_object() && source.contains("text") && source.at("text").is_string()) {
        return source.at("text").get<std::string>();
    }
    return source.dump();
}

std::optional<ConditionInfo> parse_condition(const nlohmann::json& setting, std::string* user_name)
{
    if (!setting.is_object() || !setting.contains("user")) return std::nullopt;

    const auto& user = setting.at("user");
    if (user.is_string()) {
        *user_name = user.get<std::string>();
        return std::nullopt;
    }
    if (user.is_object() && user.contains("name") && user.at("name").is_string()) {
        *user_name = user.at("name").get<std::string>();
        if (user.contains("condition") && user.at("condition").is_string()) {
            return ConditionInfo {
                .name = *user_name,
                .condition = user.at("condition").get<std::string>(),
            };
        }
    }
    return std::nullopt;
}

DynamicValueUniquePtr resolve_auto_setting(SceneRuntimeContext& context, const nlohmann::json& setting);
DynamicValueUniquePtr resolve_auto_setting(
    SceneRuntimeContext& context,
    const nlohmann::json& setting,
    std::string_view current_layer_name);

void bind_user_property(SceneRuntimeContext& context, const nlohmann::json& setting, DynamicValue& value)
{
    std::string user_name;
    const auto  condition = parse_condition(setting, &user_name);
    if (user_name.empty()) return;

    if (condition.has_value()) value.attachCondition(*condition);

    if (auto* property_value = context.FindPropertyValue(user_name); property_value != nullptr) {
        value.connect(property_value);
    }
}

void bind_vec3_user_property(
    SceneRuntimeContext& context,
    const nlohmann::json& setting,
    DynamicValue& value)
{
    std::string user_name;
    const auto  condition = parse_condition(setting, &user_name);
    if (user_name.empty()) return;

    if (condition.has_value()) value.attachCondition(*condition);

    auto* property_value = context.FindPropertyValue(user_name);
    if (property_value == nullptr) return;

    value.connectVec3(property_value);
}

DynamicValueUniquePtr wrap_script_if_needed(
    SceneRuntimeContext& context,
    const nlohmann::json& setting,
    std::string_view     current_layer_name,
    DynamicValueUniquePtr value,
    ScriptedValueSemantic semantic = ScriptedValueSemantic::Generic,
    PropertyScriptObject object = {})
{
    if (!setting.is_object() || !setting.contains("script") || !setting.at("script").is_string()) {
        return value;
    }

    const auto script_source = setting.at("script").get<std::string>();
    const bool scene_events = script_source.find("engine.on(") != std::string::npos ||
                              script_source.find("scene.on(") != std::string::npos ||
                              script_source.find("thisScene.on(") != std::string::npos;
    if (scene_events && ! ExportsFunction(script_source, "update")) {
        return value;
    }

    std::map<std::string, DynamicValueUniquePtr> script_properties;
    if (setting.contains("scriptproperties") && setting.at("scriptproperties").is_object()) {
        for (const auto& [name, property] : setting.at("scriptproperties").items()) {
            script_properties.emplace(name, resolve_auto_setting(context, property, current_layer_name));
        }
    }

    auto scripted_value = std::make_unique<ScriptedDynamicValue>(
        context,
        script_source,
        std::string(current_layer_name),
        std::move(script_properties),
        *value,
        semantic,
        object);
    context.RegisterScriptedValue(scripted_value.get());
    return scripted_value;
}

DynamicValueUniquePtr resolve_auto_setting(SceneRuntimeContext& context, const nlohmann::json& setting)
{
    return resolve_auto_setting(context, setting, {});
}

DynamicValueUniquePtr resolve_auto_setting(
    SceneRuntimeContext& context,
    const nlohmann::json& setting,
    std::string_view current_layer_name)
{
    const auto& source = unwrap_value(setting);
    if (source.is_boolean()) return ResolveBoolSetting(context, setting, current_layer_name);

    DynamicValueUniquePtr value;
    if (source.is_number()) {
        value = std::make_unique<DynamicValue>(parse_float(setting));
    } else if (source.is_string()) {
        value = std::make_unique<DynamicValue>(parse_string(setting));
    } else {
        value = std::make_unique<DynamicValue>();
    }
    bind_user_property(context, setting, *value);
    return value;
}

} // namespace

bool InitialBoolSetting(const nlohmann::json& setting)
{
    return parse_bool(setting);
}

std::string UserPropertyName(const nlohmann::json& setting)
{
    std::string user_name;
    parse_condition(setting, &user_name);
    return user_name;
}

float ScalarAnimation::Evaluate(double seconds) const
{
    if (!(fps > 0.0) || keyframes.empty() || !std::isfinite(seconds) || seconds < 0.0) {
        return initial_value;
    }

    double frame = seconds * fps;
    const double animation_length =
        length_frames > 0.0 ? length_frames : keyframes.back().frame;

    if (mode == ScalarAnimationMode::Loop && animation_length > 0.0) {
        frame = std::fmod(frame, animation_length);
        if (frame < 0.0) frame += animation_length;
    } else {
        if (frame < keyframes.front().frame) return initial_value;
        if (frame >= keyframes.back().frame) return keyframes.back().value;
    }

    const auto upper = std::upper_bound(
        keyframes.begin(),
        keyframes.end(),
        frame,
        [](double target, const ScalarAnimationKeyframe& keyframe) {
            return target < keyframe.frame;
        });

    if (upper == keyframes.begin()) return keyframes.front().value;
    if (upper == keyframes.end()) return keyframes.back().value;

    const auto& left  = *(upper - 1);
    const auto& right = *upper;
    if (frame == left.frame) return left.value;
    const double span = right.frame - left.frame;
    if (span <= 0.0) return right.value;

    const double factor = std::clamp((frame - left.frame) / span, 0.0, 1.0);
    if (left.front.enabled || right.back.enabled) {
        const double x1 = left.front.enabled ? std::clamp(left.front.x / span, 0.0, 1.0) : 1.0 / 3.0;
        const double x2 = right.back.enabled ? std::clamp(1.0 + right.back.x / span, x1, 1.0) : 2.0 / 3.0;
        const double y1 = left.front.enabled ? left.value + left.front.y
                                             : left.value + (right.value - left.value) / 3.0;
        const double y2 = right.back.enabled ? right.value + right.back.y
                                             : right.value - (right.value - left.value) / 3.0;
        const auto cubic = [](double a, double b, double c, double d, double t) {
            const double u = 1.0 - t;
            return u * u * u * a + 3.0 * u * u * t * b + 3.0 * u * t * t * c + t * t * t * d;
        };
        double low = 0.0;
        double high = 1.0;
        for (int iteration = 0; iteration < 24; ++iteration) {
            const double t = (low + high) * 0.5;
            if (cubic(0.0, x1, x2, 1.0, t) < factor) low = t;
            else high = t;
        }
        return static_cast<float>(cubic(left.value, y1, y2, right.value, (low + high) * 0.5));
    }
    return static_cast<float>(left.value + (right.value - left.value) * factor);
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
// lap, so one stalled frame cannot flood the queue.
void CollectCrossedEvents(const ScalarAnimation& animation, double previous, double travelled,
                          double length, std::vector<ScalarAnimationEvent>& out)
{
    if (animation.events.empty() || travelled == 0.0 || !std::isfinite(travelled)) return;

    if (animation.mode != ScalarAnimationMode::Loop || !(length > 0.0)) {
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

    const auto wrap = [length](double value) {
        const double wrapped = std::fmod(value, length);
        return wrapped < 0.0 ? wrapped + length : wrapped;
    };
    const double start    = wrap(previous);
    const double distance = std::abs(travelled);
    const bool   forward  = travelled > 0.0;
    std::vector<std::pair<double, const ScalarAnimationEvent*>> met;
    for (const auto& event : animation.events) {
        if (event.name.empty()) continue;
        const double delta = wrap(forward ? event.frame - start : start - event.frame);
        if (distance >= length) {
            // A full lap returns to the departure frame, so that marker is last.
            met.emplace_back(delta == 0.0 ? length : delta, &event);
        } else if (delta > 0.0 && delta <= distance) {
            met.emplace_back(delta, &event);
        }
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
    const double length = animation.FrameCount();
    const double previous = frame;
    const double next = frame + seconds * animation.fps * rate;
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
    PropertyScriptObject object)
{
    auto value = std::make_unique<DynamicValue>(parse_bool(setting));
    value      = wrap_script_if_needed(
        context,
        setting,
        current_layer_name,
        std::move(value),
        ScriptedValueSemantic::Generic,
        object);
    bind_user_property(context, setting, *value);
    return value;
}

std::unique_ptr<DynamicValue> ResolveFloatSetting(
    SceneRuntimeContext& context,
    const nlohmann::json& setting,
    std::string_view current_layer_name,
    PropertyScriptObject object)
{
    auto value = std::make_unique<DynamicValue>(parse_float(setting));
    value      = wrap_script_if_needed(
        context,
        setting,
        current_layer_name,
        std::move(value),
        ScriptedValueSemantic::Generic,
        object);
    bind_user_property(context, setting, *value);
    return value;
}

std::unique_ptr<DynamicValue> ResolveVec3Setting(
    SceneRuntimeContext& context,
    const nlohmann::json& setting,
    std::string_view current_layer_name,
    Vec3SettingSemantic semantic,
    PropertyScriptObject object)
{
    auto value = std::make_unique<DynamicValue>(parse_vec3(setting));
    const auto scripted_semantic =
        semantic == Vec3SettingSemantic::AnglesDegrees
        ? ScriptedValueSemantic::AnglesDegrees
        : ScriptedValueSemantic::Generic;
    value      = wrap_script_if_needed(
        context,
        setting,
        current_layer_name,
        std::move(value),
        scripted_semantic,
        object);
    bind_vec3_user_property(context, setting, *value);
    return value;
}

std::unique_ptr<DynamicValue> ResolveVectorSetting(
    SceneRuntimeContext& context,
    const nlohmann::json& setting,
    std::size_t components,
    std::string_view current_layer_name,
    PropertyScriptObject object)
{
    if (components == 3) {
        return ResolveVec3Setting(context, setting, current_layer_name,
                                  Vec3SettingSemantic::Generic, object);
    }
    if (components != 2 && components != 4) {
        return ResolveFloatSetting(context, setting, current_layer_name, object);
    }

    // A single authored number fills every component, matching parse_vec3.
    const auto& source = unwrap_value(setting);
    const auto  component = [&](std::size_t index) {
        return source.is_number() ? parse_float(setting) : parse_component(setting, index);
    };
    auto value = components == 2
                     ? std::make_unique<DynamicValue>(
                           Eigen::Vector2f(component(0), component(1)))
                     : std::make_unique<DynamicValue>(
                           Eigen::Vector4f(component(0), component(1), component(2), component(3)));
    value = wrap_script_if_needed(
        context,
        setting,
        current_layer_name,
        std::move(value),
        ScriptedValueSemantic::Generic,
        object);
    bind_user_property(context, setting, *value);
    return value;
}

std::unique_ptr<DynamicValue> ResolveStringSetting(
    SceneRuntimeContext& context,
    const nlohmann::json& setting,
    std::string_view current_layer_name,
    PropertyScriptObject object)
{
    auto value = std::make_unique<DynamicValue>(parse_string(setting));
    value      = wrap_script_if_needed(
        context,
        setting,
        current_layer_name,
        std::move(value),
        ScriptedValueSemantic::Generic,
        object);
    bind_user_property(context, setting, *value);
    return value;
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

    const auto animation_of = [&](std::size_t property) {
        return timelines[property]
                   ? std::shared_ptr<const NodeVec3Animation>(
                         MakeVec3Animation(std::move(*timelines[property]), clocks[roots[property]]))
                   : nullptr;
    };
    if (bound[0] || timelines[0]) {
        context.RegisterNodeTranslate(name, node, ResolveVec3Setting(context, origin, layer_name),
                                      animation_of(0));
    }
    if (bound[1] || timelines[1]) {
        context.RegisterNodeScale(name, node,
                                  ResolveVec3Setting(context, scale, layer_name,
                                                     Vec3SettingSemantic::Generic),
                                  animation_of(1));
    }
    if (bound[2] || timelines[2]) {
        context.RegisterNodeRotation(name, node,
                                     ResolveVec3Setting(context, angles, layer_name,
                                                        Vec3SettingSemantic::AnglesDegrees),
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

std::optional<ScalarAnimation> ResolveScalarAnimation(const nlohmann::json& setting,
                                                      std::size_t component)
{
    static constexpr std::array<const char*, 4> curve_keys { "c0", "c1", "c2", "c3" };
    if (component >= curve_keys.size()) return std::nullopt;
    if (!setting.is_object() || !setting.contains("animation")) return std::nullopt;

    const auto& animation = setting.at("animation");
    if (!animation.is_object()) return std::nullopt;

    const auto options_iterator = animation.find("options");
    const auto curve_iterator   = animation.find(curve_keys[component]);
    if (options_iterator == animation.end() || curve_iterator == animation.end()) {
        return std::nullopt;
    }
    if (!options_iterator->is_object() || !curve_iterator->is_array() || curve_iterator->empty()) {
        return std::nullopt;
    }

    ScalarAnimation result;
    result.initial_value = parse_component(setting, component);

    const auto& options = *options_iterator;
    if (options.contains("fps")) {
        result.fps = static_cast<double>(parse_float(options.at("fps")));
    }
    if (options.contains("length")) {
        result.length_frames = static_cast<double>(parse_float(options.at("length")));
    }
    if (options.contains("mode") && options.at("mode").is_string()) {
        result.mode = options.at("mode").get<std::string>() == "loop"
                          ? ScalarAnimationMode::Loop
                          : ScalarAnimationMode::Single;
    }
    if (options.contains("name") && options.at("name").is_string()) {
        result.name = options.at("name").get<std::string>();
    }
    if (options.contains("startpaused")) result.start_paused = parse_bool(options.at("startpaused"));
    if (const auto events = options.find("events");
        events != options.end() && events->is_array()) {
        for (const auto& entry : *events) {
            if (!entry.is_object() || !entry.contains("name") || !entry.at("name").is_string()) {
                continue;
            }
            ScalarAnimationEvent parsed;
            parsed.name = entry.at("name").get<std::string>();
            if (entry.contains("frame")) {
                parsed.frame = static_cast<double>(parse_float(entry.at("frame")));
            }
            result.events.push_back(std::move(parsed));
        }
        std::sort(result.events.begin(),
                  result.events.end(),
                  [](const ScalarAnimationEvent& left, const ScalarAnimationEvent& right) {
                      return left.frame < right.frame;
                  });
    }

    for (const auto& keyframe : *curve_iterator) {
        if (!keyframe.is_object() || !keyframe.contains("frame") || !keyframe.contains("value")) {
            continue;
        }

        ScalarAnimationKeyframe parsed;
        parsed.frame = static_cast<double>(parse_float(keyframe.at("frame")));
        parsed.value = parse_float(keyframe.at("value"));
        const auto parse_handle = [](const nlohmann::json& source, const char* key) {
            ScalarAnimationHandle handle;
            const auto iterator = source.find(key);
            if (iterator == source.end() || !iterator->is_object()) return handle;
            if (iterator->contains("enabled")) handle.enabled = parse_bool(iterator->at("enabled"));
            if (iterator->contains("x")) handle.x = parse_float(iterator->at("x"));
            if (iterator->contains("y")) handle.y = parse_float(iterator->at("y"));
            return handle;
        };
        parsed.back = parse_handle(keyframe, "back");
        parsed.front = parse_handle(keyframe, "front");
        result.keyframes.push_back(parsed);
    }

    if (result.keyframes.empty()) return std::nullopt;

    std::sort(
        result.keyframes.begin(),
        result.keyframes.end(),
        [](const ScalarAnimationKeyframe& left, const ScalarAnimationKeyframe& right) {
            return left.frame < right.frame;
        });
    if (options.contains("wraploop") && parse_bool(options.at("wraploop"))) {
        CloseCurveAtLoopLength(result);
    }
    return result;
}

} // namespace wallpaper
