#include "Runtime/DynamicValue.hpp"

#include "Project/ProjectProperties.hpp"
#include "Utils/Logging.h"

#include <sstream>

namespace wallpaper
{
namespace
{
Eigen::Vector3f ParseVec3String(const std::string& value)
{
    std::istringstream stream(value);
    float x = 0.0f;
    float y = 0.0f;
    float z = 0.0f;
    stream >> x >> y >> z;
    return Eigen::Vector3f(x, y, z);
}
} // namespace

DynamicValue::DynamicValue(const Eigen::Vector4i& value) { update(value); }
DynamicValue::DynamicValue(const Eigen::Vector3i& value) { update(value); }
DynamicValue::DynamicValue(const Eigen::Vector2i& value) { update(value); }
DynamicValue::DynamicValue(const Eigen::Vector4f& value) { update(value); }
DynamicValue::DynamicValue(const Eigen::Vector3f& value) { update(value); }
DynamicValue::DynamicValue(const Eigen::Vector2f& value) { update(value); }
DynamicValue::DynamicValue(float value) { update(value); }
DynamicValue::DynamicValue(int value) { update(value); }
DynamicValue::DynamicValue(bool value) { update(value); }
DynamicValue::DynamicValue(std::string value) { update(value); }

DynamicValue::~DynamicValue()
{
    if (m_alive_flag) *m_alive_flag = false;
    disconnect();
    m_listeners.clear();
}

const Eigen::Vector4i& DynamicValue::getIVec4() const { return m_ivec4; }
const Eigen::Vector3i& DynamicValue::getIVec3() const { return m_ivec3; }
const Eigen::Vector2i& DynamicValue::getIVec2() const { return m_ivec2; }
const Eigen::Vector4f& DynamicValue::getVec4() const { return m_vec4; }
const Eigen::Vector3f& DynamicValue::getVec3() const { return m_vec3; }
const Eigen::Vector2f& DynamicValue::getVec2() const { return m_vec2; }
const float& DynamicValue::getFloat() const { return m_float; }
const int& DynamicValue::getInt() const { return m_int; }
const bool& DynamicValue::getBool() const { return m_bool; }
const std::string& DynamicValue::getString() const { return m_string; }
DynamicValue::UnderlyingType DynamicValue::getType() const { return m_type; }

std::string DynamicValue::toString() const
{
    switch (m_type) {
    case UnderlyingType::Float: return std::to_string(m_float);
    case UnderlyingType::Int: return std::to_string(m_int);
    case UnderlyingType::Boolean: return std::to_string(m_bool);
    case UnderlyingType::Vec2:
        return std::to_string(m_vec2.x()) + ", " + std::to_string(m_vec2.y());
    case UnderlyingType::Vec3:
        return std::to_string(m_vec3.x()) + ", " + std::to_string(m_vec3.y()) + ", " +
               std::to_string(m_vec3.z());
    case UnderlyingType::Vec4:
        return std::to_string(m_vec4.x()) + ", " + std::to_string(m_vec4.y()) + ", " +
               std::to_string(m_vec4.z()) + ", " + std::to_string(m_vec4.w());
    case UnderlyingType::IVec2:
        return std::to_string(m_ivec2.x()) + ", " + std::to_string(m_ivec2.y());
    case UnderlyingType::IVec3:
        return std::to_string(m_ivec3.x()) + ", " + std::to_string(m_ivec3.y()) + ", " +
               std::to_string(m_ivec3.z());
    case UnderlyingType::IVec4:
        return std::to_string(m_ivec4.x()) + ", " + std::to_string(m_ivec4.y()) + ", " +
               std::to_string(m_ivec4.z()) + ", " + std::to_string(m_ivec4.w());
    case UnderlyingType::String: return m_string;
    case UnderlyingType::Null: return "null";
    }
    return "unknown";
}

void DynamicValue::update(float new_value)
{
    m_ivec4  = Eigen::Vector4i::Constant(static_cast<int>(new_value));
    m_ivec3  = Eigen::Vector3i::Constant(static_cast<int>(new_value));
    m_ivec2  = Eigen::Vector2i::Constant(static_cast<int>(new_value));
    m_vec4   = Eigen::Vector4f::Constant(new_value);
    m_vec3   = Eigen::Vector3f::Constant(new_value);
    m_vec2   = Eigen::Vector2f::Constant(new_value);
    m_float  = new_value;
    m_int    = static_cast<int>(new_value);
    m_bool   = static_cast<int>(new_value) != 0;
    m_string = "";
    m_type   = UnderlyingType::Float;
    propagate();
}

void DynamicValue::update(int new_value)
{
    m_ivec4  = Eigen::Vector4i::Constant(new_value);
    m_ivec3  = Eigen::Vector3i::Constant(new_value);
    m_ivec2  = Eigen::Vector2i::Constant(new_value);
    m_vec4   = Eigen::Vector4f::Constant(static_cast<float>(new_value));
    m_vec3   = Eigen::Vector3f::Constant(static_cast<float>(new_value));
    m_vec2   = Eigen::Vector2f::Constant(static_cast<float>(new_value));
    m_float  = static_cast<float>(new_value);
    m_int    = new_value;
    m_bool   = new_value != 0;
    m_string = "";
    m_type   = UnderlyingType::Int;
    propagate();
}

void DynamicValue::update(bool new_value)
{
    const auto numeric = new_value ? 1.0f : 0.0f;
    m_ivec4  = Eigen::Vector4i::Constant(new_value ? 1 : 0);
    m_ivec3  = Eigen::Vector3i::Constant(new_value ? 1 : 0);
    m_ivec2  = Eigen::Vector2i::Constant(new_value ? 1 : 0);
    m_vec4   = Eigen::Vector4f::Constant(numeric);
    m_vec3   = Eigen::Vector3f::Constant(numeric);
    m_vec2   = Eigen::Vector2f::Constant(numeric);
    m_float  = numeric;
    m_int    = new_value ? 1 : 0;
    m_bool   = new_value;
    m_string = "";
    m_type   = UnderlyingType::Boolean;
    propagate();
}

void DynamicValue::update(const Eigen::Vector2f& new_value)
{
    m_ivec4  = Eigen::Vector4i(static_cast<int>(new_value.x()), static_cast<int>(new_value.y()), 0, 0);
    m_ivec3  = Eigen::Vector3i(static_cast<int>(new_value.x()), static_cast<int>(new_value.y()), 0);
    m_ivec2  = Eigen::Vector2i(static_cast<int>(new_value.x()), static_cast<int>(new_value.y()));
    m_vec2   = new_value;
    m_vec3   = Eigen::Vector3f(new_value.x(), new_value.y(), 0.0f);
    m_vec4   = Eigen::Vector4f(new_value.x(), new_value.y(), 0.0f, 0.0f);
    m_float  = new_value.x();
    m_int    = static_cast<int>(new_value.x());
    m_bool   = new_value.x() != 0.0f;
    m_string = "";
    m_type   = UnderlyingType::Vec2;
    propagate();
}

void DynamicValue::update(const Eigen::Vector3f& new_value)
{
    m_ivec4  = Eigen::Vector4i(static_cast<int>(new_value.x()), static_cast<int>(new_value.y()), static_cast<int>(new_value.z()), 0);
    m_ivec3  = Eigen::Vector3i(static_cast<int>(new_value.x()), static_cast<int>(new_value.y()), static_cast<int>(new_value.z()));
    m_ivec2  = Eigen::Vector2i(static_cast<int>(new_value.x()), static_cast<int>(new_value.y()));
    m_vec2   = Eigen::Vector2f(new_value.x(), new_value.y());
    m_vec3   = new_value;
    m_vec4   = Eigen::Vector4f(new_value.x(), new_value.y(), new_value.z(), 0.0f);
    m_float  = new_value.x();
    m_int    = static_cast<int>(new_value.x());
    m_bool   = new_value.x() != 0.0f;
    m_string = "";
    m_type   = UnderlyingType::Vec3;
    propagate();
}

void DynamicValue::update(const Eigen::Vector4f& new_value)
{
    m_ivec4  = Eigen::Vector4i(static_cast<int>(new_value.x()), static_cast<int>(new_value.y()), static_cast<int>(new_value.z()), static_cast<int>(new_value.w()));
    m_ivec3  = Eigen::Vector3i(static_cast<int>(new_value.x()), static_cast<int>(new_value.y()), static_cast<int>(new_value.z()));
    m_ivec2  = Eigen::Vector2i(static_cast<int>(new_value.x()), static_cast<int>(new_value.y()));
    m_vec2   = Eigen::Vector2f(new_value.x(), new_value.y());
    m_vec3   = Eigen::Vector3f(new_value.x(), new_value.y(), new_value.z());
    m_vec4   = new_value;
    m_float  = new_value.x();
    m_int    = static_cast<int>(new_value.x());
    m_bool   = new_value.x() != 0.0f;
    m_string = "";
    m_type   = UnderlyingType::Vec4;
    propagate();
}

void DynamicValue::update(const Eigen::Vector2i& new_value)
{
    m_ivec4  = Eigen::Vector4i(new_value.x(), new_value.y(), 0, 0);
    m_ivec3  = Eigen::Vector3i(new_value.x(), new_value.y(), 0);
    m_ivec2  = new_value;
    m_vec2   = Eigen::Vector2f(new_value.cast<float>());
    m_vec3   = Eigen::Vector3f(static_cast<float>(new_value.x()), static_cast<float>(new_value.y()), 0.0f);
    m_vec4   = Eigen::Vector4f(static_cast<float>(new_value.x()), static_cast<float>(new_value.y()), 0.0f, 0.0f);
    m_float  = static_cast<float>(new_value.x());
    m_int    = new_value.x();
    m_bool   = new_value.x() != 0;
    m_string = "";
    m_type   = UnderlyingType::IVec2;
    propagate();
}

void DynamicValue::update(const Eigen::Vector3i& new_value)
{
    m_ivec4  = Eigen::Vector4i(new_value.x(), new_value.y(), new_value.z(), 0);
    m_ivec3  = new_value;
    m_ivec2  = Eigen::Vector2i(new_value.x(), new_value.y());
    m_vec2   = Eigen::Vector2f(static_cast<float>(new_value.x()), static_cast<float>(new_value.y()));
    m_vec3   = new_value.cast<float>();
    m_vec4   = Eigen::Vector4f(static_cast<float>(new_value.x()), static_cast<float>(new_value.y()), static_cast<float>(new_value.z()), 0.0f);
    m_float  = static_cast<float>(new_value.x());
    m_int    = new_value.x();
    m_bool   = new_value.x() != 0;
    m_string = "";
    m_type   = UnderlyingType::IVec3;
    propagate();
}

void DynamicValue::update(const Eigen::Vector4i& new_value)
{
    m_ivec4  = new_value;
    m_ivec3  = Eigen::Vector3i(new_value.x(), new_value.y(), new_value.z());
    m_ivec2  = Eigen::Vector2i(new_value.x(), new_value.y());
    m_vec2   = Eigen::Vector2f(static_cast<float>(new_value.x()), static_cast<float>(new_value.y()));
    m_vec3   = Eigen::Vector3f(static_cast<float>(new_value.x()), static_cast<float>(new_value.y()), static_cast<float>(new_value.z()));
    m_vec4   = new_value.cast<float>();
    m_float  = static_cast<float>(new_value.x());
    m_int    = new_value.x();
    m_bool   = new_value.x() != 0;
    m_string = "";
    m_type   = UnderlyingType::IVec4;
    propagate();
}

void DynamicValue::update(const std::string& new_value)
{
    // A setting bound to a choice with a condition is a flag: whether the choice
    // equals the condition. It is typed as one, so a script reads true or false
    // rather than the choice itself, which is truthy whatever it is.
    if (m_condition.has_value()) {
        DynamicValue::update(m_condition->condition == new_value);
        return;
    }
    m_ivec4  = Eigen::Vector4i::Zero();
    m_ivec3  = Eigen::Vector3i::Zero();
    m_ivec2  = Eigen::Vector2i::Zero();
    m_vec2   = Eigen::Vector2f::Zero();
    m_vec3   = Eigen::Vector3f::Zero();
    m_vec4   = Eigen::Vector4f::Zero();
    m_float  = 0.0f;
    m_int    = 0;
    // A flag bound to a choice without a condition reads the choice as a flag.
    m_bool   = StringIsTrue(new_value);
    m_string = new_value;
    m_type   = UnderlyingType::String;
    propagate();
}

void DynamicValue::update(const DynamicValue& other)
{
    if (m_condition.has_value() && other.getType() == UnderlyingType::String) {
        DynamicValue::update(m_condition->condition == other.getString());
        return;
    }
    m_ivec4  = other.getIVec4();
    m_ivec3  = other.getIVec3();
    m_ivec2  = other.getIVec2();
    m_vec2   = other.getVec2();
    m_vec3   = other.getVec3();
    m_vec4   = other.getVec4();
    m_float  = other.getFloat();
    m_int    = other.getInt();
    m_bool   = other.getBool();
    m_string = other.getString();
    m_type   = other.getType();
    propagate();
}

void DynamicValue::update()
{
    m_ivec4  = Eigen::Vector4i::Zero();
    m_ivec3  = Eigen::Vector3i::Zero();
    m_ivec2  = Eigen::Vector2i::Zero();
    m_vec2   = Eigen::Vector2f::Zero();
    m_vec3   = Eigen::Vector3f::Zero();
    m_vec4   = Eigen::Vector4f::Zero();
    m_float  = 0.0f;
    m_int    = 0;
    m_bool   = false;
    m_string = "";
    m_type   = UnderlyingType::Null;
    propagate();
}

std::function<void()> DynamicValue::listen(const std::function<void(const DynamicValue&)>& callback)
{
    const auto iterator = m_listeners.insert(m_listeners.end(), callback);
    auto       alive    = m_alive_flag;

    return [this, iterator, alive] {
        if (!alive || !*alive) return;
        m_listeners.erase(iterator);
    };
}

void DynamicValue::connect(DynamicValue* other)
{
    const auto listener = [this](const DynamicValue& source) {
        if (source.getType() == UnderlyingType::Null) {
            update();
        } else {
            update(source);
        }
    };

    const auto deregister = other->listen(listener);
    listener(*other);
    m_connections.push_back(deregister);
}

void DynamicValue::connectVec3(DynamicValue* other)
{
    const auto listener = [this](const DynamicValue& source) {
        if (source.getType() == UnderlyingType::Null) {
            update();
        } else if (source.getType() == UnderlyingType::String) {
            update(ParseVec3String(source.getString()));
        } else {
            update(source.getVec3());
        }
    };

    const auto deregister = other->listen(listener);
    listener(*other);
    m_connections.push_back(deregister);
}

void DynamicValue::disconnect()
{
    for (const auto& deregister : m_connections) {
        if (!deregister) continue;
        try {
            deregister();
        } catch (...) {
            LOG_ERROR("exception during dynamic value listener deregistration");
        }
    }
    m_connections.clear();
}

void DynamicValue::attachCondition(const ConditionInfo& condition)
{
    m_condition = condition;
}

void DynamicValue::propagate() const
{
    ++m_generation;
    for (const auto& callback : m_listeners) {
        callback(*this);
    }
}

} // namespace wallpaper
