#pragma once

#include "Utils/Linalg.hpp"

#include <cstdint>
#include <functional>
#include <list>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace wallpaper
{

struct ConditionInfo
{
    std::string name;
    std::string condition;
};

class DynamicValue
{
public:
    enum UnderlyingType
    {
        Null = 0,
        IVec4 = 1,
        IVec3 = 2,
        IVec2 = 3,
        Vec4 = 4,
        Vec3 = 5,
        Vec2 = 6,
        Float = 7,
        Int = 8,
        Boolean = 9,
        String = 10,
    };

    DynamicValue() = default;
    explicit DynamicValue(const linalg::Vector4i& value);
    explicit DynamicValue(const linalg::Vector3i& value);
    explicit DynamicValue(const linalg::Vector2i& value);
    explicit DynamicValue(const linalg::Vector4f& value);
    explicit DynamicValue(const linalg::Vector3f& value);
    explicit DynamicValue(const linalg::Vector2f& value);
    explicit DynamicValue(float value);
    explicit DynamicValue(int value);
    explicit DynamicValue(bool value);
    explicit DynamicValue(std::string value);
    // A copy holds the same readings and condition; it does not inherit the subscribers or the
    // sources of the value it was made from.
    DynamicValue(const DynamicValue& other);
    DynamicValue& operator=(const DynamicValue& other);
    virtual ~DynamicValue();

    [[nodiscard]] const linalg::Vector4i& getIVec4() const;
    [[nodiscard]] const linalg::Vector3i& getIVec3() const;
    [[nodiscard]] const linalg::Vector2i& getIVec2() const;
    [[nodiscard]] const linalg::Vector4f& getVec4() const;
    [[nodiscard]] const linalg::Vector3f& getVec3() const;
    [[nodiscard]] const linalg::Vector2f& getVec2() const;
    [[nodiscard]] const float&       getFloat() const;
    [[nodiscard]] const int&         getInt() const;
    [[nodiscard]] const bool&        getBool() const;
    [[nodiscard]] const std::string& getString() const;
    [[nodiscard]] UnderlyingType     getType() const;
    [[nodiscard]] virtual std::string toString() const;
    /// Whether `choice` is the choice `wanted` names: text compared as text, a number as a
    /// number when `wanted` reads as one (`2` and `2.0` are the same choice).
    [[nodiscard]] static bool ChoiceMatches(const DynamicValue& choice, const std::string& wanted);
    /// Advances every time a different value is stored; consumers compare it to detect change.
    uint64_t Generation() const noexcept { return m_generation; }

    virtual void update(float new_value);
    virtual void update(int new_value);
    virtual void update(bool new_value);
    virtual void update(const linalg::Vector2f& new_value);
    virtual void update(const linalg::Vector3f& new_value);
    virtual void update(const linalg::Vector4f& new_value);
    virtual void update(const linalg::Vector2i& new_value);
    virtual void update(const linalg::Vector3i& new_value);
    virtual void update(const linalg::Vector4i& new_value);
    virtual void update(const std::string& new_value);
    virtual void update(const DynamicValue& other);
    virtual void update();

    std::function<void()> listen(const std::function<void(const DynamicValue&)>& callback);
    /// Follows `other`. With `read_now` false the value keeps what it holds until `other`
    /// next changes (a property the project has not declared has nothing to read yet).
    void                  connect(DynamicValue* other, bool read_now = true);
    void                  connectVec3(DynamicValue* other, bool read_now = true);
    void                  disconnect();
    void                  attachCondition(const ConditionInfo& condition);
    /// Whether the value follows a choice through a condition (`attachCondition`): what it
    /// holds is then the flag "the choice equals the condition", of kind Boolean.
    [[nodiscard]] bool    hasCondition() const noexcept { return m_condition.has_value(); }

private:
    struct Hub;
    void propagate() const;
    void takeContent(const DynamicValue& other);
    void clearReadings();
    void assignText(const std::string& text);
    [[nodiscard]] bool conditionHolds(const DynamicValue& choice) const;
    void finishAssignment();
    void track(DynamicValue* other, bool as_vec3, bool read_now);

    mutable uint64_t m_generation { 0 };
    UnderlyingType   m_type { Null };
    float            m_float { 0.0f };
    int              m_int { 0 };
    bool             m_bool { false };
    std::string      m_string;
    std::optional<ConditionInfo> m_condition;
    // Subscribers live in a shared hub so a deregistration closure that outlives the value
    // finds the hub gone instead of a dangling value.
    std::shared_ptr<Hub> m_hub;
    std::vector<std::function<void()>> m_trackings;
    linalg::Vector4i m_ivec4 = linalg::Vector4i::Zero();
    linalg::Vector3i m_ivec3 = linalg::Vector3i::Zero();
    linalg::Vector2i m_ivec2 = linalg::Vector2i::Zero();
    linalg::Vector4f m_vec4  = linalg::Vector4f::Zero();
    linalg::Vector3f m_vec3  = linalg::Vector3f::Zero();
    linalg::Vector2f m_vec2  = linalg::Vector2f::Zero();
};

using DynamicValueUniquePtr = std::unique_ptr<DynamicValue>;

} // namespace wallpaper
