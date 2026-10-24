#include "MetalRender/MetalShaderReflection.hpp"

#include <nlohmann/json.hpp>

namespace wallpaper::metal
{
namespace
{

bool ToDescriptorKind(std::string_view name, MetalDescriptorKind& out)
{
    if (name == "uniform_buffer") {
        out = MetalDescriptorKind::UniformBuffer;
        return true;
    }
    if (name == "sampled_image") {
        out = MetalDescriptorKind::SampledImage;
        return true;
    }
    if (name == "combined_image_sampler") {
        out = MetalDescriptorKind::CombinedImageSampler;
        return true;
    }
    if (name == "sampler") {
        out = MetalDescriptorKind::Sampler;
        return true;
    }
    return false;
}

} // namespace

const MetalUniformMember* MetalShaderReflection::member(std::string_view name) const
{
    const auto* block = uniformBlock();
    if (block == nullptr) return nullptr;
    const auto found = block->members.find(std::string(name));
    if (found == block->members.end()) return nullptr;
    return &found->second;
}

bool ParseMetalShaderReflection(std::string_view json, MetalShaderReflection& out,
                                std::string* error)
{
    out = MetalShaderReflection {};
    if (json.empty()) {
        if (error != nullptr) *error = "the shader reported no reflection data";
        return false;
    }

    nlohmann::json document;
    try {
        document = nlohmann::json::parse(json);
    } catch (const std::exception& e) {
        if (error != nullptr) *error = std::string("unreadable shader reflection: ") + e.what();
        return false;
    }

    try {
        for (const auto& descriptor :
             document.value("descriptor_bindings", nlohmann::json::array())) {
            if (descriptor.value("set", 0u) != 0u) {
                if (error != nullptr) {
                    *error = "the shader binds a resource outside descriptor set 0";
                }
                return false;
            }
            if (descriptor.value("count", 1u) != 1u) {
                if (error != nullptr) *error = "the shader binds a descriptor array";
                return false;
            }
            MetalDescriptorKind kind {};
            const auto descriptor_name = descriptor.at("descriptor").get<std::string>();
            if (! ToDescriptorKind(descriptor_name, kind)) {
                if (error != nullptr) {
                    *error = "the shader binds an unsupported resource kind: " + descriptor_name;
                }
                return false;
            }
            out.descriptors.push_back(MetalDescriptorBinding {
                .name    = descriptor.at("name").get<std::string>(),
                .binding = descriptor.at("binding").get<uint32_t>(),
                .kind    = kind,
            });
        }

        for (const auto& block_json : document.value("uniform_blocks", nlohmann::json::array())) {
            MetalUniformBlock block {
                .name    = block_json.at("name").get<std::string>(),
                .size    = block_json.at("size").get<uint32_t>(),
                .binding = block_json.value("binding", 0u),
                .members = {},
            };
            for (const auto& member : block_json.value("members", nlohmann::json::array())) {
                block.members[member.at("name").get<std::string>()] = MetalUniformMember {
                    .offset        = member.at("offset").get<uint32_t>(),
                    .size          = member.at("size").get<uint32_t>(),
                    .element_count = member.value("element_count", 1u),
                    .array_count   = member.value("array_count", 0u),
                    .array_stride  = member.value("array_stride", 0u),
                };
            }
            out.blocks.push_back(std::move(block));
        }

        for (const auto& input : document.value("vertex_inputs", nlohmann::json::array())) {
            out.inputs.push_back(MetalVertexInput {
                .name     = input.at("name").get<std::string>(),
                .location = input.at("location").get<uint32_t>(),
                .format   = input.at("format").get<std::string>(),
            });
        }

        for (const auto& slot : document.value("active_texture_slots", nlohmann::json::array())) {
            out.active_texture_slots.push_back(slot.get<uint32_t>());
        }
    } catch (const std::exception& e) {
        if (error != nullptr) {
            *error = std::string("unexpected shader reflection contents: ") + e.what();
        }
        return false;
    }

    return true;
}

} // namespace wallpaper::metal
