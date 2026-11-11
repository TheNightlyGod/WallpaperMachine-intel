#pragma once

#include <array>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace wallpaper::metal
{

/// One member of a uniform block, in bytes, exactly as the shader compiler laid
/// it out. Plain data, so
/// this library keeps no dependency on the shader bridge's types.
struct MetalUniformMember
{
    uint32_t offset { 0 };
    uint32_t size { 0 };
    uint32_t element_count { 1 };
    uint32_t array_count { 0 };
    uint32_t array_stride { 0 };
};

struct MetalUniformBlock
{
    std::string                                         name;
    uint32_t                                            size { 0 };
    uint32_t                                            binding { 0 };
    std::unordered_map<std::string, MetalUniformMember> members;
};

struct MetalVertexInput
{
    std::string name;
    uint32_t    location { 0 };
    /// Vertex format name as the shader compiler reports it, e.g.
    /// `r32g32b32_sfloat`. Kept as the compiler's own spelling so an
    /// unrecognised one is visibly unrecognised instead of silently becoming a
    /// plausible default.
    std::string format;
};

enum class MetalDescriptorKind : uint8_t
{
    UniformBuffer,
    SampledImage,
    CombinedImageSampler,
    Sampler,
};

struct MetalDescriptorBinding
{
    std::string         name;
    uint32_t            binding { 0 };
    MetalDescriptorKind kind { MetalDescriptorKind::UniformBuffer };
    /// What a sampled image is, as reflected (`"dimension"`; absent means a plain 2D texture).
    enum class Image : uint8_t { D2, D3, D2Ms, Depth2D, Other } image { Image::D2 };
    /// A comparison sampler (`"comparison":true`), bound with a compare function.
    bool comparison { false };
};

/// Where the vertex stage's clip-space position comes from, as the shader compiler proved it
/// (`"vertex_position"`): `vec4(input.xyz, 1.0)`, multiplied by the `mat4` uniform `matrix`
/// (matrix on the left) unless `matrix` is empty.
struct MetalVertexPosition
{
    std::string input;
    std::string matrix;
};

/// One factor of a fragment colour channel the shader compiler proved to be a product
/// (`"fragment_colour"`): component `component` of the float uniform member `member`, or, with
/// `member` empty, the constant `constant`.
struct MetalColourFactor
{
    std::string member;
    uint32_t    component { 0 };
    float       constant { 0.0f };
};

struct MetalShaderReflection
{
    std::vector<MetalUniformBlock>      blocks;
    std::vector<MetalVertexInput>       inputs;
    std::vector<MetalDescriptorBinding> descriptors;
    std::vector<uint32_t>               active_texture_slots;
    /// Absent when the compiler could not prove it, which is every form it does not recognise.
    std::optional<MetalVertexPosition>  vertex_position;
    /// The fragment stage writes colour 0 for every fragment it runs for: nothing discards and
    /// no sample mask is written (`"fragment_always_writes"`). False when not proven.
    bool                                fragment_always_writes { false };
    /// The uniform block members anything the program produces can depend on
    /// (`"read_uniforms"`): a member it declares, and may even name, only in values nothing it
    /// produces uses is not among them. Absent when the compiler could not say, which is read as
    /// "every declared member is read".
    std::optional<std::unordered_set<std::string>> read_uniforms;
    /// The channels of colour 0 (red, green, blue, alpha) proven to be the product of their
    /// factors (`"fragment_colour"`); a channel left empty is not proven. Every channel is
    /// empty when the document has no such fact.
    std::array<std::optional<std::vector<MetalColourFactor>>, 4> fragment_colour {};

    [[nodiscard]] const MetalUniformBlock* uniformBlock() const
    {
        return blocks.empty() ? nullptr : &blocks.front();
    }
    [[nodiscard]] const MetalUniformMember* member(std::string_view name) const;
    [[nodiscard]] bool                      hasMember(std::string_view name) const
    {
        return member(name) != nullptr;
    }
    /// Whether the program can read member `name`: it declares it, and the compiler did not
    /// prove that nothing the program produces depends on it.
    [[nodiscard]] bool readsMember(std::string_view name) const
    {
        return hasMember(name) &&
               (! read_uniforms.has_value() || read_uniforms->contains(std::string(name)));
    }
};

/// Parses the reflection document the shader compiler emits. The Metal target
/// produces a payload with the `descriptor_bindings` / `uniform_blocks` /
/// `vertex_inputs` schema, which this reads.
///
/// Returns false and fills `error` rather than throwing: a malformed or
/// unexpected reflection document must hold the scene with a reason,
/// never take a wallpaper down.
bool ParseMetalShaderReflection(std::string_view json, MetalShaderReflection& out,
                                std::string* error);

} // namespace wallpaper::metal
