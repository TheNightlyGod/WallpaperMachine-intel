#include "MetalRender/MetalShaderReflection.hpp"

#include <nlohmann/json.hpp>

#include <bit>

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
            const auto dimension = descriptor.value("dimension", std::string("2d"));
            using Image          = MetalDescriptorBinding::Image;
            const Image image    = dimension == "3d"         ? Image::D3
                                   : dimension == "2d_ms"    ? Image::D2Ms
                                   : dimension == "depth_2d" ? Image::Depth2D
                                   : dimension == "2d"       ? Image::D2
                                                             : Image::Other;
            out.descriptors.push_back(MetalDescriptorBinding {
                .name       = descriptor.at("name").get<std::string>(),
                .binding    = descriptor.at("binding").get<uint32_t>(),
                .kind       = kind,
                .image      = image,
                .comparison = descriptor.value("comparison", false),
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

        // The coverage facts: absent or malformed means not proven, never an error.
        if (const auto position = document.find("vertex_position");
            position != document.end() && position->is_object()) {
            const auto input  = position->find("input");
            const auto matrix = position->find("matrix");
            if (input != position->end() && input->is_string() &&
                (matrix == position->end() || matrix->is_string())) {
                out.vertex_position = MetalVertexPosition {
                    .input  = input->get<std::string>(),
                    .matrix = matrix == position->end() ? std::string {} : matrix->get<std::string>(),
                };
            }
        }
        if (const auto writes = document.find("fragment_always_writes");
            writes != document.end() && writes->is_boolean()) {
            out.fragment_always_writes = writes->get<bool>();
        }
        // The same for the read members: a list of anything but names says nothing.
        if (const auto read = document.find("read_uniforms");
            read != document.end() && read->is_array()) {
            std::unordered_set<std::string> names;
            bool                            names_only = true;
            for (const auto& name : *read) {
                if (! name.is_string()) {
                    names_only = false;
                    break;
                }
                names.insert(name.get<std::string>());
            }
            if (names_only) out.read_uniforms = std::move(names);
        }
        // Likewise for the fragment colour: a channel whose factors are not all readable is
        // left unproven, never guessed.
        if (const auto colour = document.find("fragment_colour");
            colour != document.end() && colour->is_array() && colour->size() == 4) {
            for (std::size_t channel = 0; channel < 4; ++channel) {
                const auto& factors = (*colour)[channel];
                if (! factors.is_array() || factors.empty()) continue;
                std::vector<MetalColourFactor> parsed;
                bool                           readable = true;
                for (const auto& factor : factors) {
                    const auto uniform   = factor.is_object() ? factor.find("uniform") : factor.end();
                    const auto component = factor.is_object() ? factor.find("component") : factor.end();
                    const auto bits      = factor.is_object() ? factor.find("constant_bits") : factor.end();
                    if (uniform != factor.end() && uniform->is_string() && component != factor.end() &&
                        component->is_number_unsigned() && component->get<uint64_t>() < 4) {
                        parsed.push_back({ .member    = uniform->get<std::string>(),
                                           .component = component->get<uint32_t>() });
                    } else if (bits != factor.end() && bits->is_number_unsigned() &&
                               bits->get<uint64_t>() <= 0xffffffffull) {
                        parsed.push_back({ .constant = std::bit_cast<float>(bits->get<uint32_t>()) });
                    } else {
                        readable = false;
                        break;
                    }
                }
                if (readable) out.fragment_colour[channel] = std::move(parsed);
            }
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
