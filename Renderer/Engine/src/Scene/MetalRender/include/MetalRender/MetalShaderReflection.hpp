#pragma once

#include <cstdint>
#include <string>
#include <string_view>
#include <unordered_map>
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
};

struct MetalShaderReflection
{
    std::vector<MetalUniformBlock>      blocks;
    std::vector<MetalVertexInput>       inputs;
    std::vector<MetalDescriptorBinding> descriptors;
    std::vector<uint32_t>               active_texture_slots;

    [[nodiscard]] const MetalUniformBlock* uniformBlock() const
    {
        return blocks.empty() ? nullptr : &blocks.front();
    }
    [[nodiscard]] const MetalUniformMember* member(std::string_view name) const;
    [[nodiscard]] bool                      hasMember(std::string_view name) const
    {
        return member(name) != nullptr;
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
