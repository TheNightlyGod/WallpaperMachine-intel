// Clean-room implementation from the WallpaperMachine spec e1b-scene-model.md; written without access to the original source.
#pragma once
#include <vector>
#include <cstdint>
#include <string>
#include <unordered_map>
#include <algorithm>
#include <span>
#include <optional>
#include <memory>
#include <array>
#include <type_traits>

#include "Utils/Linalg.hpp"

#include "Core/MapSet.hpp"
#include "Core/ArrayHelper.hpp"

namespace wallpaper
{
using ShaderValueInter = std::array<float, 16>;

class ShaderValue {
public:
    using value_type = float;

public:
    ShaderValue()  = default;
    ~ShaderValue() = default;

    ShaderValue(const ShaderValue&)            = default;
    ShaderValue& operator=(const ShaderValue&) = default;

    ShaderValue(const value_type& value) noexcept: m_size(1) { m_value[0] = value; }
    template<typename Range>
        requires std::is_constructible_v<std::span<const value_type>, const Range&>
    ShaderValue(const Range& range) noexcept {
        const std::span<const value_type> view(range);
        Fill(view.data(), view.size());
    }
    ShaderValue(const value_type* ptr, std::size_t num) noexcept { Fill(ptr, num); }

    template<typename Derived>
    static ShaderValue fromMatrix(const linalg::DenseBase<Derived>& mat) {
        ShaderValue result;
        result.m_size    = static_cast<size_t>(mat.size());
        result.m_dynamic = result.m_size > result.m_value.size();
        // Match fromSpan's allocation-failure semantics for the final owning storage.
        // Matrices, blocks and maps hold their values already, in the original scalar
        // type, so narrowing to the shader's float is the only conversion.
        const auto pack = [&](const auto& evaluated) noexcept {
            if (result.m_dynamic) result.m_dvalue.resize(result.m_size);
            auto* destination = result.m_dynamic ? result.m_dvalue.data() : result.m_value.data();
            size_t index = 0;
            for (linalg::Index column = 0; column < evaluated.cols(); ++column) {
                for (linalg::Index row = 0; row < evaluated.rows(); ++row) {
                    destination[index++] = static_cast<value_type>(evaluated.coeff(row, column));
                }
            }
        };
        pack(mat.derived());
        return result;
    }
    const auto& operator[](std::size_t index) const { return data()[index]; }
    auto&       operator[](std::size_t index) { return Storage()[index]; }

    const value_type* data() const noexcept {
        return m_dynamic ? m_dvalue.data() : m_value.data();
    };
    size_t size() const noexcept { return m_size; };

    /// Shrinks or regrows the count within the storage the value already has.
    void setSize(size_t v) noexcept {
        const size_t capacity = m_dynamic ? m_dvalue.size() : m_value.size();
        m_size                = std::min(v, capacity);
    }

private:
    value_type* Storage() noexcept { return m_dynamic ? m_dvalue.data() : m_value.data(); }
    // Copies `num` floats, inline when they fit and on the heap otherwise.
    void Fill(const value_type* ptr, std::size_t num) noexcept {
        m_size    = num;
        m_dynamic = num > m_value.size();
        if (m_dynamic) {
            m_dvalue.assign(ptr, ptr + num);
        } else if (num != 0) {
            std::copy_n(ptr, num, m_value.begin());
        }
    }

    bool                    m_dynamic { false };
    ShaderValueInter        m_value {};
    std::vector<value_type> m_dvalue;
    size_t                  m_size { 0 };
};

using ShaderValues   = Map<std::string, ShaderValue>;
using ShaderValueMap = ShaderValues;

struct ShaderAttribute {
public:
    std::string name;
    uint32_t    location;
};

/// Metal Shading Language translation of a shader program, defined by the
/// native Metal backend. Deliberately incomplete here: `shared_ptr` erases the
/// deleter at construction, so this declaration gives the scene library the
/// field without giving it a dependency on the renderer that fills it.
struct SceneMetalProgram;

struct SceneShader {
public:
    uint32_t    id;
    std::string name;

    /*
    std::string vertexCode;
    std::string geometryCode;
    std::string fragmentCode;
    */

    std::vector<ShaderAttribute> attrs;
    ShaderValues                 default_uniforms;
    std::optional<std::string>   rust_reflection_json;
    /// Null means translation was never attempted, which is the state until the
    /// parse's pending translations are flushed. A non-null program
    /// that reports an error means it was attempted and failed. The two must
    /// stay distinguishable: only the second is a fault in the shader.
    std::shared_ptr<const SceneMetalProgram> metal_program;
};
} // namespace wallpaper
