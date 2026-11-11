// Clean-room implementation from the WallpaperMachine spec e2-runtime-animation.md; written without access to the original source.
#include "Runtime/DynamicValue.hpp"

#include "Project/ProjectProperties.hpp"
#include "Runtime/NumberText.hpp"
#include "Utils/Logging.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <sstream>

namespace wallpaper
{

namespace
{
// A number cut toward zero into an int, safe for every float (a value that does not fit, or is
// not a number, reads as the nearest end, or 0).
int TruncateToInt(float value) {
    if (!(value == value)) return 0;
    if (value >= 2147483648.0f) return std::numeric_limits<int>::max();
    if (value <= -2147483648.0f) return std::numeric_limits<int>::min();
    return static_cast<int>(value);
}

std::string NumberText(float value) { return std::to_string(value); }
} // namespace

// Subscribers of one value. Removal inside a notification only empties the slot; the slots are
// compacted once the outermost notification has finished, so nobody is skipped or repeated.
struct DynamicValue::Hub
{
    // Shared, so a notification holds the callback it is running by a reference count instead
    // of copying the function (and whatever it captured) for every assignment.
    using Callback = std::shared_ptr<const std::function<void(const DynamicValue&)>>;
    struct Slot
    {
        uint64_t id { 0 };
        Callback callback;
    };
    std::vector<Slot> slots;
    uint64_t          next_id { 1 };
    int               notifying { 0 };
    bool              needs_compaction { false };

    void remove(uint64_t id) {
        for (auto& slot : slots) {
            if (slot.id != id || !slot.callback) continue;
            slot.callback = nullptr;
            if (notifying > 0) {
                needs_compaction = true;
            } else {
                std::erase_if(slots, [](const Slot& entry) { return !entry.callback; });
            }
            return;
        }
    }
};

DynamicValue::DynamicValue(const linalg::Vector4i& value) { update(value); }
DynamicValue::DynamicValue(const linalg::Vector3i& value) { update(value); }
DynamicValue::DynamicValue(const linalg::Vector2i& value) { update(value); }
DynamicValue::DynamicValue(const linalg::Vector4f& value) { update(value); }
DynamicValue::DynamicValue(const linalg::Vector3f& value) { update(value); }
DynamicValue::DynamicValue(const linalg::Vector2f& value) { update(value); }
DynamicValue::DynamicValue(float value) { update(value); }
DynamicValue::DynamicValue(int value) { update(value); }
DynamicValue::DynamicValue(bool value) { update(value); }
DynamicValue::DynamicValue(std::string value) { update(value); }

DynamicValue::DynamicValue(const DynamicValue& other) :
    m_generation(0), m_condition(other.m_condition) {
    takeContent(other);
    ++m_generation;
}

DynamicValue& DynamicValue::operator=(const DynamicValue& other) {
    if (this == &other) return *this;
    m_condition = other.m_condition;
    update(other);
    return *this;
}

DynamicValue::~DynamicValue() {
    disconnect();
    // Drop the subscribers first: a deregistration closure made for this value is then a no-op.
    m_hub.reset();
}

const linalg::Vector4i& DynamicValue::getIVec4() const { return m_ivec4; }
const linalg::Vector3i& DynamicValue::getIVec3() const { return m_ivec3; }
const linalg::Vector2i& DynamicValue::getIVec2() const { return m_ivec2; }
const linalg::Vector4f& DynamicValue::getVec4() const { return m_vec4; }
const linalg::Vector3f& DynamicValue::getVec3() const { return m_vec3; }
const linalg::Vector2f& DynamicValue::getVec2() const { return m_vec2; }
const float& DynamicValue::getFloat() const { return m_float; }
const int& DynamicValue::getInt() const { return m_int; }
const bool& DynamicValue::getBool() const { return m_bool; }
const std::string& DynamicValue::getString() const { return m_string; }
DynamicValue::UnderlyingType DynamicValue::getType() const { return m_type; }

std::string DynamicValue::toString() const {
    const auto join = [](const auto& vector, int lanes, auto&& format) {
        std::string text;
        for (int i = 0; i < lanes; ++i) {
            if (i > 0) text += ", ";
            text += format(vector[i]);
        }
        return text;
    };
    switch (m_type) {
    case Null: return "null";
    case Boolean: return m_bool ? "1" : "0";
    case Int: return std::to_string(m_int);
    case Float: return NumberText(m_float);
    case String: return m_string;
    case Vec2: return join(m_vec2, 2, NumberText);
    case Vec3: return join(m_vec3, 3, NumberText);
    case Vec4: return join(m_vec4, 4, NumberText);
    case IVec2: return join(m_ivec2, 2, [](int v) { return std::to_string(v); });
    case IVec3: return join(m_ivec3, 3, [](int v) { return std::to_string(v); });
    case IVec4: return join(m_ivec4, 4, [](int v) { return std::to_string(v); });
    }
    return {};
}

// Every reading back to "nothing"; each assignment then sets what its kind defines.
void DynamicValue::clearReadings() {
    m_type   = Null;
    m_float  = 0.0f;
    m_int    = 0;
    m_bool   = false;
    m_string.clear();
    m_ivec4 = linalg::Vector4i::Zero();
    m_ivec3 = linalg::Vector3i::Zero();
    m_ivec2 = linalg::Vector2i::Zero();
    m_vec4  = linalg::Vector4f::Zero();
    m_vec3  = linalg::Vector3f::Zero();
    m_vec2  = linalg::Vector2f::Zero();
}

void DynamicValue::finishAssignment() {
    ++m_generation;
    propagate();
}

void DynamicValue::update(float new_value) {
    clearReadings();
    m_type  = Float;
    m_float = new_value;
    m_int   = TruncateToInt(new_value);
    m_bool  = m_int != 0;
    const int truncated = m_int;
    m_vec2  = linalg::Vector2f(new_value, new_value);
    m_vec3  = linalg::Vector3f(new_value, new_value, new_value);
    m_vec4  = linalg::Vector4f(new_value, new_value, new_value, new_value);
    m_ivec2 = linalg::Vector2i(truncated, truncated);
    m_ivec3 = linalg::Vector3i(truncated, truncated, truncated);
    m_ivec4 = linalg::Vector4i(truncated, truncated, truncated, truncated);
    finishAssignment();
}

void DynamicValue::update(int new_value) {
    clearReadings();
    m_type  = Int;
    m_int   = new_value;
    m_float = static_cast<float>(new_value);
    m_bool  = new_value != 0;
    const float lane = m_float;
    m_vec2  = linalg::Vector2f(lane, lane);
    m_vec3  = linalg::Vector3f(lane, lane, lane);
    m_vec4  = linalg::Vector4f(lane, lane, lane, lane);
    m_ivec2 = linalg::Vector2i(new_value, new_value);
    m_ivec3 = linalg::Vector3i(new_value, new_value, new_value);
    m_ivec4 = linalg::Vector4i(new_value, new_value, new_value, new_value);
    finishAssignment();
}

void DynamicValue::update(bool new_value) {
    clearReadings();
    m_type  = Boolean;
    m_bool  = new_value;
    m_int   = new_value ? 1 : 0;
    m_float = new_value ? 1.0f : 0.0f;
    const float lane = m_float;
    m_vec2  = linalg::Vector2f(lane, lane);
    m_vec3  = linalg::Vector3f(lane, lane, lane);
    m_vec4  = linalg::Vector4f(lane, lane, lane, lane);
    m_ivec2 = linalg::Vector2i(m_int, m_int);
    m_ivec3 = linalg::Vector3i(m_int, m_int, m_int);
    m_ivec4 = linalg::Vector4i(m_int, m_int, m_int, m_int);
    finishAssignment();
}

void DynamicValue::update(const linalg::Vector2f& new_value) {
    clearReadings();
    m_type  = Vec2;
    m_vec2  = new_value;
    m_vec3  = linalg::Vector3f(new_value.x(), new_value.y(), 0.0f);
    m_vec4  = linalg::Vector4f(new_value.x(), new_value.y(), 0.0f, 0.0f);
    m_float = new_value.x();
    m_int   = TruncateToInt(new_value.x());
    m_bool  = new_value.x() != 0.0f;
    m_ivec2 = linalg::Vector2i(TruncateToInt(new_value.x()), TruncateToInt(new_value.y()));
    m_ivec3 = linalg::Vector3i(m_ivec2.x(), m_ivec2.y(), 0);
    m_ivec4 = linalg::Vector4i(m_ivec2.x(), m_ivec2.y(), 0, 0);
    finishAssignment();
}

void DynamicValue::update(const linalg::Vector3f& new_value) {
    clearReadings();
    m_type  = Vec3;
    m_vec3  = new_value;
    m_vec2  = linalg::Vector2f(new_value.x(), new_value.y());
    m_vec4  = linalg::Vector4f(new_value.x(), new_value.y(), new_value.z(), 0.0f);
    m_float = new_value.x();
    m_int   = TruncateToInt(new_value.x());
    m_bool  = new_value.x() != 0.0f;
    m_ivec3 = linalg::Vector3i(TruncateToInt(new_value.x()), TruncateToInt(new_value.y()),
                               TruncateToInt(new_value.z()));
    m_ivec2 = linalg::Vector2i(m_ivec3.x(), m_ivec3.y());
    m_ivec4 = linalg::Vector4i(m_ivec3.x(), m_ivec3.y(), m_ivec3.z(), 0);
    finishAssignment();
}

void DynamicValue::update(const linalg::Vector4f& new_value) {
    clearReadings();
    m_type  = Vec4;
    m_vec4  = new_value;
    m_vec3  = linalg::Vector3f(new_value.x(), new_value.y(), new_value.z());
    m_vec2  = linalg::Vector2f(new_value.x(), new_value.y());
    m_float = new_value.x();
    m_int   = TruncateToInt(new_value.x());
    m_bool  = new_value.x() != 0.0f;
    m_ivec4 = linalg::Vector4i(TruncateToInt(new_value.x()), TruncateToInt(new_value.y()),
                               TruncateToInt(new_value.z()), TruncateToInt(new_value.w()));
    m_ivec3 = linalg::Vector3i(m_ivec4.x(), m_ivec4.y(), m_ivec4.z());
    m_ivec2 = linalg::Vector2i(m_ivec4.x(), m_ivec4.y());
    finishAssignment();
}

void DynamicValue::update(const linalg::Vector2i& new_value) {
    clearReadings();
    m_type  = IVec2;
    m_ivec2 = new_value;
    m_ivec3 = linalg::Vector3i(new_value.x(), new_value.y(), 0);
    m_ivec4 = linalg::Vector4i(new_value.x(), new_value.y(), 0, 0);
    m_int   = new_value.x();
    m_float = static_cast<float>(new_value.x());
    m_bool  = new_value.x() != 0;
    m_vec2  = linalg::Vector2f(static_cast<float>(new_value.x()), static_cast<float>(new_value.y()));
    m_vec3  = linalg::Vector3f(m_vec2.x(), m_vec2.y(), 0.0f);
    m_vec4  = linalg::Vector4f(m_vec2.x(), m_vec2.y(), 0.0f, 0.0f);
    finishAssignment();
}

void DynamicValue::update(const linalg::Vector3i& new_value) {
    clearReadings();
    m_type  = IVec3;
    m_ivec3 = new_value;
    m_ivec2 = linalg::Vector2i(new_value.x(), new_value.y());
    m_ivec4 = linalg::Vector4i(new_value.x(), new_value.y(), new_value.z(), 0);
    m_int   = new_value.x();
    m_float = static_cast<float>(new_value.x());
    m_bool  = new_value.x() != 0;
    m_vec3  = linalg::Vector3f(static_cast<float>(new_value.x()), static_cast<float>(new_value.y()),
                               static_cast<float>(new_value.z()));
    m_vec2  = linalg::Vector2f(m_vec3.x(), m_vec3.y());
    m_vec4  = linalg::Vector4f(m_vec3.x(), m_vec3.y(), m_vec3.z(), 0.0f);
    finishAssignment();
}

void DynamicValue::update(const linalg::Vector4i& new_value) {
    clearReadings();
    m_type  = IVec4;
    m_ivec4 = new_value;
    m_ivec3 = linalg::Vector3i(new_value.x(), new_value.y(), new_value.z());
    m_ivec2 = linalg::Vector2i(new_value.x(), new_value.y());
    m_int   = new_value.x();
    m_float = static_cast<float>(new_value.x());
    m_bool  = new_value.x() != 0;
    m_vec4  = linalg::Vector4f(static_cast<float>(new_value.x()), static_cast<float>(new_value.y()),
                               static_cast<float>(new_value.z()), static_cast<float>(new_value.w()));
    m_vec3  = linalg::Vector3f(m_vec4.x(), m_vec4.y(), m_vec4.z());
    m_vec2  = linalg::Vector2f(m_vec4.x(), m_vec4.y());
    finishAssignment();
}

// The flag of a text: the choice's own text when a condition is attached, else `true` in any
// case or `1`.
void DynamicValue::assignText(const std::string& text) {
    m_type   = String;
    m_string = text;
    m_bool   = m_condition.has_value() ? text == m_condition->condition : StringIsTrue(text);
}

void DynamicValue::update(const std::string& new_value) {
    clearReadings();
    assignText(new_value);
    finishAssignment();
}

// Every reading of `other`, kind included. A text source read through a condition of this
// value is a flag by comparison with that condition instead of by its own reading.
void DynamicValue::takeContent(const DynamicValue& other) {
    m_type   = other.m_type;
    m_float  = other.m_float;
    m_int    = other.m_int;
    m_bool   = other.m_bool;
    m_string = other.m_string;
    m_ivec4  = other.m_ivec4;
    m_ivec3  = other.m_ivec3;
    m_ivec2  = other.m_ivec2;
    m_vec4   = other.m_vec4;
    m_vec3   = other.m_vec3;
    m_vec2   = other.m_vec2;
    if (m_type == String && m_condition.has_value()) m_bool = m_string == m_condition->condition;
}

void DynamicValue::update(const DynamicValue& other) {
    if (this == &other) {
        finishAssignment();
        return;
    }
    takeContent(other);
    finishAssignment();
}

void DynamicValue::update() {
    clearReadings();
    finishAssignment();
}

std::function<void()> DynamicValue::listen(const std::function<void(const DynamicValue&)>& callback) {
    if (!callback) return [] {};
    if (m_hub == nullptr) m_hub = std::make_shared<Hub>();
    const uint64_t id = m_hub->next_id++;
    m_hub->slots.push_back(
        Hub::Slot { id, std::make_shared<const std::function<void(const DynamicValue&)>>(callback) });
    return [hub = std::weak_ptr<Hub>(m_hub), id] {
        if (auto live = hub.lock()) live->remove(id);
    };
}

void DynamicValue::propagate() const {
    if (m_hub == nullptr || m_hub->slots.empty()) return;
    // Keep the hub alive even if a callback destroys this value, and leave the notification
    // in order even if one throws.
    const auto hub   = m_hub;
    const auto count = hub->slots.size();
    struct Notification
    {
        Hub& hub;
        explicit Notification(Hub& target) : hub(target) { ++hub.notifying; }
        ~Notification() {
            if (--hub.notifying == 0 && hub.needs_compaction) {
                std::erase_if(hub.slots, [](const Hub::Slot& slot) { return !slot.callback; });
                hub.needs_compaction = false;
            }
        }
    } notification(*hub);
    for (std::size_t i = 0; i < count && i < hub->slots.size(); ++i) {
        // Held while it runs: the callback may remove itself, which empties its slot.
        const auto callback = hub->slots[i].callback;
        if (callback) (*callback)(*this);
    }
}

bool DynamicValue::conditionHolds(const DynamicValue& choice) const {
    return ChoiceMatches(choice, m_condition->condition);
}

// A text choice is compared as text; a number is compared as a number when the condition is one
// (`2` and `2.0` are the same choice), else by the text it reads as.
bool DynamicValue::ChoiceMatches(const DynamicValue& choice, const std::string& wanted) {
    switch (choice.m_type) {
    case String: return choice.m_string == wanted;
    case Float:
    case Int:
    case Boolean: {
        std::size_t position = 0;
        float       number   = 0.0f;
        if (ReadLeadingNumber(wanted, position, number)) {
            while (position < wanted.size() && (wanted[position] == ' ' || wanted[position] == '\t')) ++position;
            if (position == wanted.size()) return choice.m_float == number;
        }
        return choice.toString() == wanted;
    }
    default: return choice.toString() == wanted;
    }
}

void DynamicValue::track(DynamicValue* other, bool as_vec3, bool read_now) {
    if (other == nullptr || other == this) return;
    const auto take = [this, as_vec3](const DynamicValue& source) {
        if (source.m_type == Null) {
            update();
        } else if (!as_vec3 && m_condition.has_value()) {
            // A choice read through a condition is a flag: true only while the choice is the
            // one the condition names.
            update(conditionHolds(source));
        } else if (!as_vec3) {
            update(source);
        } else if (source.m_type == String) {
            float lanes[3];
            ReadNumberList(source.m_string, lanes, 3);
            update(linalg::Vector3f(lanes[0], lanes[1], lanes[2]));
        } else {
            update(source.m_vec3);
        }
    };
    if (read_now) take(*other);
    m_trackings.push_back(other->listen(take));
}

void DynamicValue::connect(DynamicValue* other, bool read_now) { track(other, false, read_now); }

void DynamicValue::connectVec3(DynamicValue* other, bool read_now) { track(other, true, read_now); }

void DynamicValue::disconnect() {
    auto trackings = std::move(m_trackings);
    m_trackings.clear();
    for (auto& end : trackings) {
        try {
            end();
        } catch (const std::exception& error) {
            LOG_ERROR("DynamicValue: ending a tracking failed: %s", error.what());
        } catch (...) {
            LOG_ERROR("DynamicValue: ending a tracking failed");
        }
    }
}

void DynamicValue::attachCondition(const ConditionInfo& condition) { m_condition = condition; }

} // namespace wallpaper
