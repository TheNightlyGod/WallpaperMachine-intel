#include "CustomShaderPass.hpp"
#include "PrePass.hpp"
#include "CopyPass.hpp"
#include "FinPass.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneShader.h"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/RuntimeImageSource.hpp"
#include "Shader/RustShaderBridge.hpp"

#include "SpecTexs.hpp"
#include "Vulkan/Shader.hpp"
#include "Utils/Logging.h"
#include "Utils/AutoDeletor.hpp"
#include "Resource.hpp"
#include "PassCommon.hpp"
#include "TexturePrefetch.hpp"
#include "Interface/IImageParser.h"

#include "Core/ArrayHelper.hpp"

#include <cassert>
#include <algorithm>
#include <array>
#include <cstring>
#include <functional>
#include <limits>
#include <string>

using namespace wallpaper::vulkan;

namespace
{
using wallpaper::usize;

bool IsPreClearRedundant(const PrePass& pre, std::span<VulkanPass* const> following_passes) {
    const auto& image = pre.desc().vk_result;
    if (image.handle == VK_NULL_HANDLE || image.view == VK_NULL_HANDLE ||
        image.extent.width == 0 || image.extent.height == 0 ||
        image.extent.depth != 1 || image.mipmap_level != 1)
        return false;
    for (auto* pass : following_passes) {
        if (pass == nullptr || ! pass->prepared()) continue;
        const auto* custom = dynamic_cast<CustomShaderPass*>(pass);
        if (custom == nullptr) return false;
        const auto candidate = custom->batchCandidate();
        if (! candidate.visible && ! candidate.clear_only) continue;
        const auto& desc = custom->desc();
        if (candidate.visible) {
            for (size_t i = 0; i < desc.vk_textures.size(); ++i) {
                if (i < desc.vk_texture_bindings.size() &&
                    desc.vk_texture_bindings[i].image_binding >= 0 &&
                    ! desc.vk_textures[i].slots.empty() &&
                    desc.vk_textures[i].getActive().handle == image.handle)
                    return false;
            }
        }
        const auto& output = candidate.render;
        if (output.image != image.handle) continue;
        return output.sample_count == VK_SAMPLE_COUNT_1_BIT &&
               output.msaa_image == VK_NULL_HANDLE && output.msaa_view == VK_NULL_HANDLE &&
               output.view == image.view && output.extent.width == image.extent.width &&
               output.extent.height == image.extent.height && output.extent.depth == image.extent.depth &&
               desc.vk_output.mipmap_level == 1 &&
               (candidate.clear_only || output.load_op == VK_ATTACHMENT_LOAD_OP_CLEAR) &&
               std::memcmp(pre.desc().clear_value.color.float32, output.clear_value.color.float32,
                           sizeof(output.clear_value.color.float32)) == 0;
    }
    return false;
}

} // namespace

namespace wallpaper::vulkan
{

CustomShaderPass* FindDirectPresentationPass(Scene& scene, std::span<VulkanPass* const> graph_passes) {
    if (graph_passes.size() != 1) return nullptr;
    auto* pass = dynamic_cast<CustomShaderPass*>(graph_passes.front());
    if (pass == nullptr) return nullptr;
    const auto& desc = pass->desc();
    const auto output = scene.ResolveRenderTargetName(desc.output);
    const auto* target = scene.FindRenderTarget(output);
    if (output != SpecTex_Default || target == nullptr || target->withDepth || target->has_mipmap ||
        target->mipmap_level != 1 || target->sample_count != 1 ||
        desc.sample_count != VK_SAMPLE_COUNT_1_BIT ||
        ! desc.clear_on_first_use || desc.preserve_target_contents)
        return nullptr;
    for (const auto& texture : desc.textures) {
        if (texture.empty()) continue;
        const auto input = scene.ResolveRenderTargetName(texture);
        if (input.empty() || input == output ||
            (IsSpecTex(input) && ! scene.HasRenderTarget(input)))
            return nullptr;
    }
    return pass;
}

bool ReflectCustomShader(const SceneShader& shader, std::vector<Uni_ShaderSpv>& spvs,
                         ShaderReflected& ref) {
    ref = {};
    spvs.clear();
    if (! shader.rust_reflection_json.has_value()) {
        LOG_ERROR("shader '%s' has no Rust reflection metadata", shader.name.c_str());
        return false;
    }
    try {
        const auto metadata = nlohmann::json::parse(*shader.rust_reflection_json);
        for (const char* key : {"descriptor_bindings", "uniform_blocks", "vertex_inputs"}) {
            if (! metadata.is_object() || ! metadata.contains(key) || ! metadata.at(key).is_array()) {
                throw std::runtime_error("incomplete Rust reflection metadata");
            }
        }
        wallpaper::shader::RustShaderOutput output;
        wallpaper::shader::ApplyRustShaderReflectionJson(*shader.rust_reflection_json, output);
        ref = std::move(output.reflection);
        spvs.reserve(shader.codes.size());
        for (size_t index = 0; index < shader.codes.size(); ++index) {
            auto spv = std::make_unique<ShaderSpv>();
            spv->stage = index == 0 ? ShaderType::VERTEX : ShaderType::FRAGMENT;
            spv->spirv = shader.codes[index];
            spvs.emplace_back(std::move(spv));
        }
        return true;
    } catch (const std::exception& error) {
        ref = {};
        spvs.clear();
        LOG_ERROR("invalid Rust shader reflection for '%s': %s", shader.name.c_str(), error.what());
        return false;
    }
}

} // namespace wallpaper::vulkan

CustomShaderPass::CustomShaderPass(const Desc& desc) {
    m_desc.node            = desc.node;
    m_desc.visibility_node = desc.visibility_node;
    m_desc.textures        = desc.textures;
    m_desc.texture_covers  = desc.texture_covers;
    m_desc.output          = desc.output;
    m_desc.camera_override = desc.camera_override;
    m_desc.submesh_index   = desc.submesh_index;
    m_desc.material_slot   = desc.material_slot;
    m_desc.blend_override  = desc.blend_override;
    m_desc.sample_count    = desc.sample_count;
    m_desc.presentation_format = desc.presentation_format;
    m_desc.presents_through_final_viewport = desc.presents_through_final_viewport;
    m_desc.sprites_map     = desc.sprites_map;
    m_desc.video_textures  = desc.video_textures;
};

CustomShaderPass::~CustomShaderPass() {}

std::optional<vvk::RenderPass> CreateRenderPass(const vvk::Device& device, VkFormat format,
                                                VkAttachmentLoadOp loadOp,
                                                VkImageLayout      finalLayout,
                                                VkSampleCountFlagBits sample_count,
                                                bool with_depth = false) {
    const auto plan = PlanCustomPassAttachments(sample_count, with_depth);

    VkAttachmentDescription color {
        .format         = format,
        .samples        = plan.color_samples,
        .loadOp         = loadOp, // VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp        = VK_ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp  = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout  = VK_IMAGE_LAYOUT_UNDEFINED,
        .finalLayout =
            plan.needs_resolve_attachment ? VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
                                          : finalLayout, // ShaderReadOnlyOptimal
    };

    if (loadOp == VK_ATTACHMENT_LOAD_OP_LOAD) {
        color.initialLayout = plan.needs_resolve_attachment
                                  ? VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
                                  : VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    }

    VkAttachmentDescription resolve {
        .format         = format,
        .samples        = plan.resolve_samples,
        .loadOp         = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .storeOp        = VK_ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp  = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout  = VK_IMAGE_LAYOUT_UNDEFINED,
        .finalLayout    = finalLayout,
    };

    VkAttachmentDescription depth {
        .format         = VK_FORMAT_D32_SFLOAT,
        .samples        = plan.color_samples,
        .loadOp         = loadOp == VK_ATTACHMENT_LOAD_OP_LOAD ? VK_ATTACHMENT_LOAD_OP_LOAD
                                                              : VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp        = VK_ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp  = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout  = loadOp == VK_ATTACHMENT_LOAD_OP_LOAD
                              ? VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL
                              : VK_IMAGE_LAYOUT_UNDEFINED,
        .finalLayout    = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    };

    std::array<VkAttachmentDescription, 3> attachments {};
    uint32_t                               attachment_count = 0;
    attachments[attachment_count++] = color;
    if (plan.needs_resolve_attachment) attachments[attachment_count++] = resolve;
    VkAttachmentReference depth_ref {};
    if (plan.has_depth) {
        depth_ref.attachment = attachment_count;
        depth_ref.layout     = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
        attachments[attachment_count++] = depth;
    }

    VkAttachmentReference attachment_ref {
        .attachment = 0,
        .layout     = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    };
    VkAttachmentReference resolve_ref {
        .attachment = 1,
        .layout     = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    };

    VkSubpassDescription subpass {
        .pipelineBindPoint       = VK_PIPELINE_BIND_POINT_GRAPHICS,
        .colorAttachmentCount    = 1,
        .pColorAttachments       = &attachment_ref,
        .pResolveAttachments     = plan.needs_resolve_attachment ? &resolve_ref : nullptr,
        .pDepthStencilAttachment = plan.has_depth ? &depth_ref : nullptr,
    };

    VkPipelineStageFlags src_stages =
        VK_PIPELINE_STAGE_VERTEX_SHADER_BIT | VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT |
        VK_PIPELINE_STAGE_TRANSFER_BIT | VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    VkPipelineStageFlags dst_stages = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    VkAccessFlags        src_access = VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_TRANSFER_READ_BIT |
                               VK_ACCESS_TRANSFER_WRITE_BIT | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    VkAccessFlags dst_access =
        VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    if (plan.has_depth) {
        src_stages |= VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT |
                      VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT;
        dst_stages |= VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT |
                      VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT;
        src_access |= VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
        dst_access |= VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT |
                      VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
    }

    VkSubpassDependency dependency {
        .srcSubpass    = VK_SUBPASS_EXTERNAL,
        .dstSubpass    = 0,
        .srcStageMask  = src_stages,
        .dstStageMask  = dst_stages,
        .srcAccessMask = src_access,
        .dstAccessMask = dst_access,
    };

    VkRenderPassCreateInfo creatinfo {
        .sType           = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .attachmentCount = attachment_count,
        .pAttachments    = attachments.data(),
        .subpassCount    = 1,
        .pSubpasses      = &subpass,
        .dependencyCount = 1,
        .pDependencies   = &dependency,
    };
    vvk::RenderPass pass;
    if (auto res = device.CreateRenderPass(creatinfo, pass); res == VK_SUCCESS) {
        return pass;
    } else {
        VVK_CHECK(res);
        return std::nullopt;
    }
}

static bool WriteUniform(StagingBuffer* buf, const StagingBufferRef& bufref,
                         const ShaderReflected::BlockedUniform& member,
                         const wallpaper::ShaderValue& value) {
    using namespace wallpaper;
    std::span<uint8_t> bytes { (uint8_t*)value.data(),
                               value.size() * sizeof(ShaderValue::value_type) };
    if (member.array_count > 0 && member.array_stride > 0 &&
        bytes.size() % member.array_count == 0) {
        const size_t element_size = bytes.size() / member.array_count;
        if (element_size > 0 && element_size <= member.array_stride) {
            for (size_t index = 0; index < member.array_count; ++index) {
                if (! buf->writeToBuf(bufref, bytes.subspan(index * element_size, element_size),
                                      member.offset + index * member.array_stride)) return false;
            }
            return true;
        }
    }
    // Reflection size is the std140 slot. A wider host value (a mat4 written
    // into a mat3) used to continue into the next member and replace the first
    // column of g_ViewProjectionMatrix, which collapsed every perspective
    // vertex onto one screen column.
    if (member.size > 0 && bytes.size() > member.size) {
        bytes = bytes.first(member.size);
    }
    return buf->writeToBuf(bufref, bytes, member.offset);
}

static bool UpdateUniform(StagingBuffer* buf, const StagingBufferRef& bufref,
                          const ShaderReflected::Block& block, std::string_view name,
                          const wallpaper::ShaderValue& value) {
    const auto uniform = block.member_map.find(name);
    if (uniform == block.member_map.end()) return true;
    return WriteUniform(buf, bufref, uniform->second, value);
}

namespace
{
/// Per-pass memo of reflected members, so a frame's uniform writes cost no
/// string-keyed map walks.
///
/// Both tables point into the pass's own reflected block, which is immutable
/// until the next `prepare()` builds a new `update_op` and a new memo. Values
/// are still written every frame through the staging buffer's `memcmp` gate,
/// so nothing cached here can hold a value back.
struct UniformMemo {
    /// Names the shader value updater writes. Keys are compared by content,
    /// never by pointer, and a miss falls back to the reflected map, so an
    /// updater that writes a name for the first time is still resolved.
    struct Named {
        std::string                             name;
        const ShaderReflected::BlockedUniform* member;
    };
    std::vector<Named> named;
    usize              cursor { 0 };

    /// The material's constants that the block has, in map order.
    /// `constValues` is a `std::map` that only gains keys after parsing
    /// (`operator[]`, `emplace`, or assignment through `find`), so its nodes
    /// and their values stay where they are; a new key changes its size and
    /// rebuilds this table on the next frame.
    struct Constant {
        const ShaderReflected::BlockedUniform* member;
        const wallpaper::ShaderValue*          value;
    };
    const wallpaper::SceneMaterial* constants_material { nullptr };
    usize                           constants_count { 0 };
    bool                            constants_valid { false };
    std::vector<Constant>           constants;

    /// Whether each texture slot names a runtime image, as of
    /// `runtime_names_generation`, and for the name it held then.
    struct RuntimeSlot {
        std::string name;
        bool        is_runtime { false };
        bool        valid { false };
    };
    std::vector<RuntimeSlot> runtime_slots;
    uint64_t                 runtime_names_generation { 0 };
    bool                     runtime_names_valid { false };

    const ShaderReflected::BlockedUniform* Resolve(const ShaderReflected::Block& block,
                                                   std::string_view              name) {
        // The updater writes the same names in the same order each frame, so
        // the entry after the last hit is almost always the one.
        const usize count = named.size();
        for (usize step = 0; step < count; ++step) {
            usize index = cursor + step;
            if (index >= count) index -= count;
            if (named[index].name == name) {
                cursor = index + 1;
                return named[index].member;
            }
        }
        const auto                             found  = block.member_map.find(name);
        const ShaderReflected::BlockedUniform* member =
            found == block.member_map.end() ? nullptr : &found->second;
        named.push_back(Named { std::string(name), member });
        cursor = named.size();
        return member;
    }

    const std::vector<Constant>& Constants(const ShaderReflected::Block&  block,
                                           const wallpaper::SceneMaterial& material) {
        const auto& values = material.customShader.constValues;
        if (! constants_valid || constants_material != &material ||
            constants_count != values.size()) {
            constants.clear();
            for (const auto& [name, value] : values) {
                const auto found = block.member_map.find(name);
                if (found == block.member_map.end()) continue;
                constants.push_back(Constant { &found->second, &value });
            }
            constants_material = &material;
            constants_count    = values.size();
            constants_valid    = true;
        }
        return constants;
    }
};

/// What a video texture's consumer asks of its source at this moment: the
/// layer's own clock and controls, or the scene's clock for a texture no layer
/// controls. The one answer for the frame being drawn and for a source being
/// opened, which must start from the clock its first frame will be given.
wallpaper::video::VideoPlaybackState VideoPlaybackOf(const wallpaper::Scene& scene,
                                                     const std::string&      key) {
    wallpaper::video::VideoPlaybackState state =
        scene.runtime != nullptr ? scene.runtime->ResolveVideoPlaybackState(key, scene.elapsingTime)
                                 : wallpaper::video::VideoPlaybackState {};
    if (scene.runtime == nullptr) state.scene_elapsed_seconds = scene.elapsingTime;
    return state;
}
} // namespace

void CustomShaderPass::prepare(Scene& scene, const Device& device, RenderingResources& rr) {
    m_scene = &scene;
    setPrepared(false);
    m_desc.vk_textures.resize(m_desc.textures.size());
    m_desc.vk_texture_image_keys.resize(m_desc.textures.size());
    m_desc.video_textures.resize(m_desc.textures.size(), false);
    auto* runtime_images = dynamic_cast<wallpaper::RuntimeImageSource*>(scene.imageParser.get());
    for (usize i = 0; i < m_desc.textures.size(); i++) {
        auto& tex_name = m_desc.textures[i];
        if (tex_name.empty()) continue;

        ImageSlotsRef img_slots;
        if (IsSpecTex(tex_name)) {
            tex_name = scene.ResolveRenderTargetName(tex_name);
            if (! scene.HasRenderTarget(tex_name)) continue;
            auto& rt  = *scene.FindRenderTarget(tex_name);
            auto  opt = device.tex_cache().Query(tex_name, ToTexKey(rt), ! rt.allowReuse);
            if (! opt.has_value()) continue;
            img_slots.slots = { opt.value() };
        } else {
            // A package or loose image is cached under its own name, and
            // CreateTex answers a cached key without reading the pixels it is
            // handed, so parsing first decoded a texture again for every pass
            // that binds it only to drop the copy. Runtime images carry a
            // versioned key, so they always resolve through the parser.
            std::optional<ImageSlotsRef> cached;
            if (runtime_images == nullptr || ! runtime_images->IsRuntimeImage(tex_name)) {
                cached = device.tex_cache().FindTex(tex_name);
            }
            // A video the scene draws is open already when another pass bound it
            // first, or when this graph is built again under it: the cache set the
            // decoder aside. Neither is read again, which for a video packaged in
            // the scene would copy and hash the whole file, nor opened over, which
            // would show the head of the clip until a seek to the clock had landed.
            std::optional<ImageSlotsRef> open_video;
            if (! cached.has_value()) {
                const auto declared = scene.textures.find(tex_name);
                if (declared != scene.textures.end() && declared->second.isVideo) {
                    open_video = device.tex_cache().FindVideoTex(tex_name,
                                                                 VideoPlaybackOf(scene, tex_name));
                }
            }
            if (cached.has_value()) {
                m_desc.video_textures[i]        = false;
                m_desc.vk_texture_image_keys[i] = tex_name;
                img_slots                       = std::move(*cached);
            } else if (open_video.has_value()) {
                m_desc.video_textures[i]        = true;
                m_desc.vk_texture_image_keys[i] = tex_name;
                img_slots                       = std::move(*open_video);
            } else {
                std::shared_ptr<wallpaper::Image> image;
                if (auto prefetched = rr.texture_prefetch != nullptr
                                          ? rr.texture_prefetch->Take(tex_name)
                                          : std::nullopt) {
                    image = std::move(*prefetched);
                } else {
                    image = scene.imageParser->Parse(tex_name);
                }
                if (image) {
                    m_desc.video_textures[i] = image->header.isVideo;
                    m_desc.vk_texture_image_keys[i] = image->key;
                    img_slots                = device.tex_cache().CreateTex(
                        *image, VideoPlaybackOf(scene, tex_name));
                } else {
                    LOG_ERROR("parse tex \"%s\" failed", tex_name.c_str());
                }
            }
        }
        m_desc.vk_textures[i] = img_slots;
    }
    // A slot that shows a cover over its render target starts on the target;
    // the frame's update binds the cover whenever one is published.
    m_desc.vk_cover_targets.assign(m_desc.textures.size(), ImageSlotsRef {});
    m_desc.vk_cover_images.assign(m_desc.textures.size(), ImageSlotsRef {});
    for (usize i = 0; i < m_desc.texture_covers.size() && i < m_desc.textures.size(); i++) {
        if (! m_desc.texture_covers[i].empty()) m_desc.vk_cover_targets[i] = m_desc.vk_textures[i];
    }
    {
        auto& tex_name = m_desc.output;
        if (! IsSpecTex(tex_name)) {
            LOG_ERROR("custom shader output is not a spec texture: %s", tex_name.c_str());
            return;
        }
        tex_name = scene.ResolveRenderTargetName(tex_name);
        if (! scene.HasRenderTarget(tex_name)) {
            LOG_ERROR("custom shader output render target is not registered: %s", tex_name.c_str());
            return;
        }
        auto& rt = *scene.FindRenderTarget(tex_name);
        m_desc.sample_count = ResolveCustomPassRenderTargetSampleCount(
            SampleCountValue(m_desc.sample_count), device.limits().framebufferColorSampleCounts);
        if (auto opt = device.tex_cache().Query(tex_name, ToTexKey(rt), ! rt.allowReuse);
            opt.has_value()) {
            m_desc.vk_output = opt.value();
        } else
            return;

        if (m_desc.sample_count != VK_SAMPLE_COUNT_1_BIT) {
            const auto  msaa_key  = ToTexKeyMsaa(rt, m_desc.sample_count);
            const auto  sample_id = SampleCountValue(m_desc.sample_count);
            std::string twin_name =
                tex_name + "::msaa" + std::to_string(static_cast<unsigned>(sample_id));
            if (auto opt = device.tex_cache().Query(twin_name, msaa_key, true);
                opt.has_value()) {
                m_desc.vk_output_msaa = opt.value();
            } else {
                LOG_ERROR("failed to allocate MSAA attachment for render target: %s",
                          tex_name.c_str());
                return;
            }
        }
        m_desc.with_depth = rt.withDepth;
        if (rt.withDepth) {
            const auto  depth_key = ToTexKeyDepth(rt, m_desc.sample_count);
            std::string depth_name = tex_name + "::depth";
            if (m_desc.sample_count != VK_SAMPLE_COUNT_1_BIT) {
                depth_name += std::to_string(
                    static_cast<unsigned>(SampleCountValue(m_desc.sample_count)));
            }
            if (auto opt = device.tex_cache().Query(depth_name, depth_key, ! rt.allowReuse);
                opt.has_value()) {
                m_desc.vk_output_depth = opt.value();
            } else {
                LOG_ERROR("failed to allocate depth attachment for render target: %s",
                          tex_name.c_str());
                return;
            }
        }
    }

    SceneMesh& mesh = *(m_desc.node->Mesh());
    if (m_desc.submesh_index >= mesh.Submeshes().size()) return;
    auto& submesh = mesh.Submeshes()[m_desc.submesh_index];
    auto* material = mesh.MaterialForSlot(m_desc.material_slot);
    if (material == nullptr) return;

    std::vector<Uni_ShaderSpv> spvs;
    DescriptorSetInfo          descriptor_info;
    ShaderReflected            ref;
    {
        if (material->customShader.shader == nullptr) return;
        SceneShader& shader = *(material->customShader.shader);

        if (! ReflectCustomShader(shader, spvs, ref)) return;

        /*
        LOG_INFO("----shader------");
        LOG_INFO("%s", shader.name.c_str());
        LOG_INFO("--inputs:");
        for (auto& i : ref.input_location_map) {
            LOG_INFO("%d %s", i.second, i.first.c_str());
        }
        LOG_INFO("--bindings:");
        */

        if (! detail::PlanCustomShaderDescriptors(ref,
                                                  m_desc.vk_textures.size(),
                                                  m_desc.vk_texture_bindings,
                                                  descriptor_info.bindings)) {
            LOG_ERROR("custom shader reflection contains descriptors that cannot be written by "
                      "CustomShaderPass");
            return;
        }
    }

    m_desc.draw_count = 0;
    std::vector<VkVertexInputBindingDescription>   bind_descriptions;
    std::vector<VkVertexInputAttributeDescription> attr_descriptions;
    {
        m_desc.dyn_vertex   = mesh.Dynamic();
        m_desc.event_vertex = mesh.UpdatesOnEvent();
        m_desc.vertex_bufs.resize(submesh.VertexCount());

        for (uint i = 0; i < submesh.VertexCount(); i++) {
            const auto& vertex    = submesh.GetVertexArray(i);
            auto        attrs_map = vertex.GetAttrOffsetMap();

            VkVertexInputBindingDescription bind_desc {
                .binding   = i,
                .stride    = (uint32_t)vertex.OneSizeOf(),
                .inputRate = VK_VERTEX_INPUT_RATE_VERTEX,
            };
            bind_descriptions.push_back(bind_desc);

            for (auto& item : ref.input_location_map) {
                auto& name   = item.first;
                auto& input  = item.second;
                usize offset = exists(attrs_map, name) ? attrs_map[name].offset : 0;

                VkVertexInputAttributeDescription attr_desc {
                    .location = input.location,
                    .binding  = i,
                    .format   = input.format,
                    .offset   = (u32)offset,
                };
                attr_descriptions.push_back(attr_desc);
            }
            {
                auto& buf = m_desc.vertex_bufs[i];
                if (! m_desc.dyn_vertex) {
                    if (! rr.vertex_buf->allocateSubRef(vertex.CapacitySizeOf(), buf)) return;
                    if (! rr.vertex_buf->writeToBuf(buf, { (uint8_t*)vertex.Data(), buf.size }))
                        return;
                } else {
                    if (! rr.dyn_buf->allocateSubRef(vertex.CapacitySizeOf(), buf)) return;
                }
            }
            m_desc.draw_count += (u32)(vertex.DataSize() / vertex.OneSize());
        }

        if (submesh.IndexCount() > 0) {
            auto&          indice = submesh.GetIndexArray(0);
            const uint64_t count  = indice.DrawIndexCount();
            const uint64_t bytes  = indice.DrawIndexBytes();
            if (count > std::numeric_limits<u32>::max() || (count > 0 && bytes == 0)) {
                LOG_ERROR("index buffer is larger than a draw can address");
                return;
            }
            m_desc.draw_count  = (u32)count;
            m_desc.index_type  = indice.Width() == SceneIndexWidth::UInt32 ? VK_INDEX_TYPE_UINT32
                                                                          : VK_INDEX_TYPE_UINT16;
            m_desc.draw_ranges = submesh.DrawRanges();
            auto& buf         = m_desc.index_buf;
            if (! m_desc.dyn_vertex) {
                if (! rr.vertex_buf->allocateSubRef(indice.CapacitySizeof(), buf)) return;
                if (! rr.vertex_buf->writeToBuf(buf, { (uint8_t*)indice.Data(), buf.size })) return;
            } else {
                if (! rr.dyn_buf->allocateSubRef(indice.CapacitySizeof(), buf)) return;
            }
        }
    }
    {
        VkPipelineColorBlendAttachmentState color_blend;
        VkAttachmentLoadOp                  loadOp { VK_ATTACHMENT_LOAD_OP_DONT_CARE };
        {
            VkColorComponentFlags colorMask =
                VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT | VK_COLOR_COMPONENT_B_BIT;
            if (m_desc.write_alpha) colorMask |= VK_COLOR_COMPONENT_A_BIT;
            color_blend.colorWriteMask = colorMask;

            auto blendmode = m_desc.blend_override.value_or(material->blenmode);
            SetBlend(blendmode, color_blend, m_desc.sample_count);
            m_desc.blending          = color_blend.blendEnable;
            m_desc.alpha_to_coverage = blendmode == BlendMode::AlphaToCoverage &&
                                       m_desc.sample_count != VK_SAMPLE_COUNT_1_BIT;

            loadOp =
                ResolveAttachmentLoadOp(m_desc.preserve_target_contents, m_desc.clear_on_first_use);
        }
        auto opt = CreateRenderPass(device.handle(),
                                    ToVkType(scene.FindRenderTarget(m_desc.output)->format),
                                    loadOp,
                                    VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                                    m_desc.sample_count,
                                    m_desc.with_depth);
        if (! opt.has_value()) return;
        auto& pass = opt.value();

        descriptor_info.push_descriptor = true;
        GraphicsPipeline pipeline;
        pipeline.toDefault();
        if (m_desc.alpha_to_coverage) {
            pipeline.multisample.alphaToCoverageEnable = VK_TRUE;
        }
        if (m_desc.with_depth) {
            const auto depth = ResolveSceneDepthState(*material, m_desc.with_depth);
            pipeline.depth.depthTestEnable  = depth.test ? VK_TRUE : VK_FALSE;
            pipeline.depth.depthWriteEnable = depth.write ? VK_TRUE : VK_FALSE;
            pipeline.depth.depthCompareOp   = VK_COMPARE_OP_LESS_OR_EQUAL;
            switch (material->cull_mode) {
            case CullMode::Front: pipeline.raster.cullMode = VK_CULL_MODE_FRONT_BIT; break;
            case CullMode::Back: pipeline.raster.cullMode = VK_CULL_MODE_BACK_BIT; break;
            case CullMode::None:
            default: pipeline.raster.cullMode = VK_CULL_MODE_NONE; break;
            }
            // MoltenVK keeps counter-clockwise as the visible front face after
            // recordDraw's negative viewport. Clockwise culls the Saturn
            // skybox and its rings together.
            pipeline.raster.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE;
        }
        pipeline.addDescriptorSetInfo(spanone { descriptor_info })
            .setColorBlendStates(spanone { color_blend })
            .setTopology(m_desc.index_buf ? VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST
                                          : VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP)
            .addInputBindingDescription(bind_descriptions)
            .addInputAttributeDescription(attr_descriptions)
            .setSampleCount(m_desc.sample_count);
        for (auto& spv : spvs) pipeline.addStage(std::move(spv));

        if (! pipeline.create(device, pass, m_desc.pipeline)) return;
        if (m_desc.presentation_format != VK_FORMAT_UNDEFINED) {
            auto presentation_pass = CreateRenderPass(
                device.handle(), m_desc.presentation_format, VK_ATTACHMENT_LOAD_OP_CLEAR,
                VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, VK_SAMPLE_COUNT_1_BIT);
            if (! presentation_pass.has_value()) return;
            pipeline.setSampleCount(VK_SAMPLE_COUNT_1_BIT);
            // Presentation may be single-sample even when the offscreen pass is not.
            SetBlend(m_desc.blend_override.value_or(material->blenmode), color_blend,
                     VK_SAMPLE_COUNT_1_BIT);
            pipeline.setColorBlendStates(spanone { color_blend });
            pipeline.multisample.alphaToCoverageEnable = VK_FALSE;
            if (! pipeline.create(device, *presentation_pass, m_presentation_pipeline)) return;
            auto copy_source_pass = CreateRenderPass(
                device.handle(), m_desc.presentation_format, VK_ATTACHMENT_LOAD_OP_CLEAR,
                VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_SAMPLE_COUNT_1_BIT);
            if (! copy_source_pass.has_value()) return;
            m_presentation_copy_source_pass = std::move(*copy_source_pass);
        }
    }

    {
        auto render_info = renderInfo();
        auto views       = CustomPassFramebufferAttachmentViews(render_info);
        VkFramebufferCreateInfo info {
            .sType           = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
            .pNext           = nullptr,
            .renderPass      = *m_desc.pipeline.pass,
            .attachmentCount = views.size(),
            .pAttachments    = views.data(),
            .width           = m_desc.vk_output.extent.width,
            .height          = m_desc.vk_output.extent.height,
            .layers          = 1,
        };
        VVK_CHECK_VOID_RE(device.handle().CreateFramebuffer(info, m_desc.fb));
    }

    m_desc.uniform_block.reset();
    const ShaderReflected::Block* uniform_block = nullptr;
    if (detail::ReflectedUniformBlockBinding(ref) != nullptr) {
        m_desc.uniform_block = ref.blocks.front();
        uniform_block        = &m_desc.uniform_block.value();
        if (! rr.dyn_buf->allocateSubRef(uniform_block->size,
                                         m_desc.ubo_buf,
                                         device.limits().minUniformBufferOffsetAlignment)) {
            return;
        }
    } else if (! ref.blocks.empty()) {
        LOG_ERROR("shader uniform block has no matching uniform-buffer descriptor binding");
    }

    std::function<bool()> update_dyn_buf_op;
    if (m_desc.dyn_vertex) {
        auto& mesh        = *m_desc.node->Mesh();
        auto submesh_index = m_desc.submesh_index;
        auto* dyn_buf     = rr.dyn_buf;
        auto& vertex_bufs = m_desc.vertex_bufs;
        auto& draw_count  = m_desc.draw_count;
        auto& index_buf   = m_desc.index_buf;
        auto& index_type  = m_desc.index_type;
        auto& draw_ranges = m_desc.draw_ranges;
        auto& uploaded_generation = m_desc.uploaded_mesh_dirty_generation;
        const auto index_count = submesh.IndexCount();
        std::vector<usize> strides;
        std::vector<std::vector<SceneVertexArray::SceneVertexAttribute>> attributes;
        strides.reserve(submesh.VertexCount());
        attributes.reserve(submesh.VertexCount());
        for (usize i = 0; i < submesh.VertexCount(); ++i) {
            strides.push_back(submesh.GetVertexArray(i).OneSizeOf());
            attributes.push_back(submesh.GetVertexArray(i).Attributes());
        }
        update_dyn_buf_op = [&mesh,
                             submesh_index,
                             &vertex_bufs,
                             &draw_count,
                             &index_buf,
                             &index_type,
                             &draw_ranges,
                             &uploaded_generation,
                             dyn_buf,
                             index_count,
                             strides = std::move(strides),
                             attributes = std::move(attributes)]() {
            const uint64_t dirty_generation = mesh.DirtyGeneration();
            if (uploaded_generation == dirty_generation) return true;
            if (submesh_index >= mesh.Submeshes().size()) return false;
            auto& current = mesh.Submeshes()[submesh_index];
            if (current.VertexCount() != vertex_bufs.size() ||
                current.IndexCount() != index_count) {
                LOG_ERROR("dynamic mesh binding topology changed after preparation");
                return false;
            }
            for (usize i = 0; i < current.VertexCount(); ++i) {
                const auto& vertex = current.GetVertexArray(i);
                const auto& attrs = vertex.Attributes();
                if (vertex.DataSizeOf() > vertex_bufs[i].size ||
                    vertex.OneSizeOf() != strides[i] ||
                    ! std::equal(attrs.begin(), attrs.end(), attributes[i].begin(),
                                  attributes[i].end(), [](const auto& a, const auto& b) {
                                      return a.name == b.name && a.type == b.type &&
                                             a.padding == b.padding;
                                  })) {
                    LOG_ERROR("dynamic mesh exceeds prepared storage or changes vertex layout");
                    return false;
                }
            }
            if (index_count > 0 && current.GetIndexArray(0).DataSizeOf() > index_buf.size) {
                LOG_ERROR("dynamic mesh exceeds prepared index storage");
                return false;
            }
            for (usize i = 0; i < current.VertexCount(); ++i) {
                const auto& vertex = current.GetVertexArray(i);
                if (! dyn_buf->writeToBuf(vertex_bufs[i],
                                          { (uint8_t*)vertex.Data(), vertex.DataSizeOf() }))
                    return false;
            }
            if (index_count > 0) {
                const auto& indice = current.GetIndexArray(0);
                if (! dyn_buf->writeToBuf(index_buf,
                                          { (uint8_t*)indice.Data(), indice.DataSizeOf() }))
                    return false;
                const uint64_t live = indice.DrawIndexCount();
                const uint64_t bytes = indice.DrawIndexBytes();
                if (live > std::numeric_limits<u32>::max() || (live > 0 && bytes == 0)) {
                    LOG_ERROR("dynamic mesh index count is not addressable");
                    return false;
                }
                const auto expected = index_type == VK_INDEX_TYPE_UINT32 ? SceneIndexWidth::UInt32
                                                                         : SceneIndexWidth::UInt16;
                if (indice.Width() != expected) {
                    LOG_ERROR("dynamic mesh changed its index width after preparation");
                    return false;
                }
                draw_count = (u32)live;
                draw_ranges = current.DrawRanges();
            }
            uploaded_generation = dirty_generation;
            return true;
        };
    }

    auto* buf    = rr.dyn_buf;
    auto* bufref = &m_desc.ubo_buf;

    auto* node            = m_desc.node;
    auto* scene_ptr       = &scene;
    auto* device_ptr      = &device;
    auto* shader_updater  = scene.shaderValueUpdater.get();
    auto& sprites         = m_desc.sprites_map;
    auto& textures        = m_desc.textures;
    auto& video_textures  = m_desc.video_textures;
    auto& video_update_failure_reported = m_desc.video_update_failure_reported;
    auto& vk_textures     = m_desc.vk_textures;
    auto& vk_texture_image_keys = m_desc.vk_texture_image_keys;
    auto& texture_covers  = m_desc.texture_covers;
    auto& vk_cover_targets = m_desc.vk_cover_targets;
    auto& vk_cover_images = m_desc.vk_cover_images;
    auto  camera_override = m_desc.camera_override;
    auto  material_slot   = m_desc.material_slot;

    auto memo = std::make_shared<UniformMemo>();
    m_desc.update_op = [shader_updater,
                        uniform_block,
                        buf,
                        bufref,
                        node,
                        scene_ptr,
                        device_ptr,
                        &textures,
                        &video_textures,
                        runtime_images,
                        &sprites,
                        &video_update_failure_reported,
                        &vk_textures,
                        &vk_texture_image_keys,
                        &texture_covers,
                        &vk_cover_targets,
                        &vk_cover_images,
                        camera_override,
                        material_slot,
                        memo,
                        update_dyn_buf_op]() {
        bool writes_ok = true;
        memo->cursor   = 0;
        auto update_unf_op = [uniform_block, buf, bufref, &memo, &writes_ok](
                                 std::string_view name, const wallpaper::ShaderValue& value) {
            if (uniform_block == nullptr || buf == nullptr || bufref == nullptr || ! (*bufref))
                return;
            const auto* member = memo->Resolve(*uniform_block, name);
            if (member == nullptr) return;
            writes_ok = WriteUniform(buf, *bufref, *member, value) && writes_ok;
        };
        if (uniform_block != nullptr && node != nullptr && node->Mesh() != nullptr) {
            const auto* material = node->Mesh()->MaterialForSlot(material_slot);
            if (material == nullptr) return writes_ok;
            for (const auto& constant : memo->Constants(*uniform_block, *material)) {
                writes_ok = WriteUniform(buf, *bufref, *constant.member, *constant.value) && writes_ok;
            }
        }
        std::string original_camera;
        bool        restore_camera = false;
        if (! camera_override.empty() && node != nullptr && node->Camera() != camera_override) {
            original_camera = node->Camera();
            node->SetCamera(camera_override);
            restore_camera = true;
        }
        {
            AUTO_DELETER(camera_override, [&]() {
                if (restore_camera) node->SetCamera(original_camera);
            });
            shader_updater->UpdateUniforms(node, material_slot, sprites, std::cref(update_unf_op));
        }
        {
            for (auto& [i, sp] : sprites) {
                if (i >= vk_textures.size()) continue;
                vk_textures.at(i).active = sp.GetCurFrame().imageId;
            }
        }
        for (usize i = 0; i < video_textures.size(); ++i) {
            if (! video_textures[i]) continue;
            if (i >= textures.size() || i >= vk_textures.size()) continue;

            std::string                          error;
            const auto playback_state = VideoPlaybackOf(*scene_ptr, textures[i]);
            if (! device_ptr->tex_cache().UpdateVideoFrame(
                    textures[i], playback_state, &vk_textures[i], &error)) {
                // A software-decode import that cannot land fails every tick.
                // The first failure of a run is the whole story; the next
                // success re-arms it.
                if (i >= video_update_failure_reported.size()) {
                    video_update_failure_reported.resize(i + 1);
                }
                if (! video_update_failure_reported[i]) {
                    video_update_failure_reported[i] = true;
                    LOG_ERROR("failed to update video texture \"%s\": %s",
                              textures[i].c_str(),
                              error.c_str());
                }
            } else {
                if (i < video_update_failure_reported.size()) {
                    video_update_failure_reported[i] = false;
                }
                if (scene_ptr->runtime != nullptr) {
                    scene_ptr->runtime->SetVideoTextureDuration(
                        textures[i], device_ptr->tex_cache().GetVideoDuration(textures[i]));
                }
            }
        }
        if (runtime_images != nullptr) {
            // Names only ever join the runtime source, so a slot's answer can
            // change only when that set grows or the slot is given a new name.
            const uint64_t names_generation = runtime_images->NamesGeneration();
            if (memo->runtime_slots.size() != textures.size()) {
                memo->runtime_slots.assign(textures.size(), UniformMemo::RuntimeSlot {});
            }
            const bool names_changed = ! memo->runtime_names_valid ||
                                       memo->runtime_names_generation != names_generation;
            for (usize i = 0; i < textures.size(); ++i) {
                auto& slot = memo->runtime_slots[i];
                if (names_changed || ! slot.valid || slot.name != textures[i]) {
                    slot.name       = textures[i];
                    slot.is_runtime = runtime_images->IsRuntimeImage(textures[i]);
                    slot.valid      = true;
                }
            }
            memo->runtime_names_generation = names_generation;
            memo->runtime_names_valid      = true;
        }
        for (usize i = 0; i < textures.size(); ++i) {
            if (i >= video_textures.size() || i >= vk_textures.size()) continue;
            if (video_textures[i] || textures[i].empty() || IsSpecTex(textures[i])) continue;
            if (runtime_images == nullptr || ! memo->runtime_slots[i].is_runtime) {
                continue;
            }

            auto image = runtime_images->Parse(textures[i]);
            if (image == nullptr || image->header.isVideo) continue;
            if (i < vk_texture_image_keys.size() && vk_texture_image_keys[i] == image->key) {
                continue;
            }

            const auto previous_key = i < vk_texture_image_keys.size()
                                          ? std::string_view(vk_texture_image_keys[i])
                                          : std::string_view();
            vk_textures[i] = device_ptr->tex_cache().ReplaceTex(*image, previous_key);
            if (i >= vk_texture_image_keys.size()) vk_texture_image_keys.resize(i + 1);
            vk_texture_image_keys[i] = image->key;
        }
        // A slot whose authored texture is a render target -- another layer's
        // composite, a default cover -- shows the cover over it while one is
        // published, and the target again once the cover is cleared or before
        // a track has one. The cover last uploaded stays with the slot, so the
        // next one retires it whichever of the two is bound in between.
        for (usize i = 0; i < texture_covers.size(); ++i) {
            const auto& cover = texture_covers[i];
            if (cover.empty() || i >= vk_textures.size() || i >= vk_cover_targets.size() ||
                i >= vk_cover_images.size() || i >= vk_texture_image_keys.size()) {
                continue;
            }
            vk_textures[i] = vk_cover_targets[i];
            if (runtime_images == nullptr) continue;
            auto image = runtime_images->Parse(cover);
            if (image == nullptr || image->header.isVideo ||
                wallpaper::RuntimeImageSource::IsEmptyCover(*image)) {
                continue;
            }
            if (vk_texture_image_keys[i] != image->key || vk_cover_images[i].slots.empty()) {
                auto uploaded = device_ptr->tex_cache().ReplaceTex(*image, vk_texture_image_keys[i]);
                if (uploaded.slots.empty()) continue;
                vk_cover_images[i]       = std::move(uploaded);
                vk_texture_image_keys[i] = image->key;
            }
            vk_textures[i] = vk_cover_images[i];
        }
        if (update_dyn_buf_op) writes_ok = update_dyn_buf_op() && writes_ok;
        return writes_ok;
    };

    auto exists_unf_op = [uniform_block](std::string_view name) {
        return uniform_block != nullptr && exists(uniform_block->member_map, name);
    };
    shader_updater->InitUniforms(node, material_slot, exists_unf_op);

    if (uniform_block != nullptr) {
        if (! buf->fillBuf(*bufref, 0, bufref->size, 0)) return;
        {
            auto&      default_values = material->customShader.shader->default_uniforms;
            auto&      const_values   = material->customShader.constValues;
            std::array values_array   = { &default_values, &const_values };
            for (auto& values : values_array) {
                for (auto& v : *values) {
                    if (exists(uniform_block->member_map, v.first)) {
                        if (! UpdateUniform(buf, *bufref, *uniform_block, v.first, v.second)) return;
                    }
                }
            }
        }
    }
    if (! m_desc.update_op()) return;

    {
        m_desc.clear_value =
            ResolveAttachmentClearValue(m_desc.output == SpecTex_Default, scene.clearColor);
    }
    for (auto& tex : releaseTexs()) {
        device.tex_cache().MarkShareReady(tex);
    }
    setPrepared();
}

CustomPassRenderInfo CustomShaderPass::renderInfo() const {
    return CustomPassRenderInfo {
        .image        = m_desc.vk_output.handle,
        .view         = m_desc.vk_output.view,
        .msaa_image   = m_desc.vk_output_msaa.handle,
        .msaa_view    = m_desc.vk_output_msaa.view,
        .depth_image  = m_desc.vk_output_depth.handle,
        .depth_view   = m_desc.vk_output_depth.view,
        .with_depth   = m_desc.with_depth,
        .extent       = m_desc.vk_output.extent,
        .final_layout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        .load_op =
            ResolveAttachmentLoadOp(m_desc.preserve_target_contents, m_desc.clear_on_first_use),
        .sample_count = m_desc.sample_count,
        .render_pass = *m_desc.pipeline.pass,
        .framebuffer = *m_desc.fb,
        .clear_value = m_desc.clear_value,
    };
}

bool CustomShaderPass::updateFrame(const Device&, RenderingResources&) {
    if (m_scene != nullptr) {
        m_desc.clear_value = ResolveAttachmentClearValue(m_desc.output == SpecTex_Default,
                                                         m_scene->clearColor);
    }
    m_frame_visible = m_desc.visibility_node == nullptr ||
                      m_desc.visibility_node->EffectiveVisible() ||
                      (m_desc.visibility_node->MustProduce() && ! m_desc.output.empty() &&
                       m_desc.output != SpecTex_Default);
    m_frame_clear_only = ! m_frame_visible && m_desc.clear_on_first_use;
    if (! m_frame_visible) return true;
    // A skipped pass keeps the pixels it wrote last frame, so re-uploading its
    // uniforms would only produce a buffer nothing reads. Its dynamic inputs
    // were already proven unchanged, and the scene runtime still ticks, so no
    // script or animation side effect is lost by not running the update.
    if (m_frame_skipped) return true;
    if (m_desc.update_op && ! m_desc.update_op()) {
        m_frame_visible = false;
        return false;
    }
    if (! textureDescriptorsReady()) {
        m_frame_visible = false;
        m_frame_clear_only = false;
    }
    return true;
}

CustomPassBatchCandidate CustomShaderPass::batchCandidate() const {
    return CustomPassBatchCandidate {
        .batchable = true,
        // A skipped pass must also stop claiming a clear. Clearing its target
        // and drawing nothing is what would erase the pixels being reused.
        .visible = m_frame_visible && ! m_frame_skipped,
        .clear_only = m_frame_clear_only && ! m_frame_skipped,
        .render = renderInfo(),
    };
}

StaticPassDesc CustomShaderPass::staticPassDesc(const Scene& scene) const {
    StaticPassDesc desc;
    desc.target = m_desc.output;
    desc.inputs = m_desc.textures;

    uint32_t reasons = 0;
    const auto* updater = scene.shaderValueUpdater.get();
    const uint32_t varying =
        updater != nullptr
            ? updater->FrameVaryingUniforms(m_desc.node, m_desc.material_slot,
                                            m_desc.camera_override)
            : frame_varying_uniform::kAll;
    if ((varying & (frame_varying_uniform::kTime | frame_varying_uniform::kDayTime)) != 0)
        reasons |= DynamicReason::TimeUniform;
    if ((varying & frame_varying_uniform::kAudio) != 0) reasons |= DynamicReason::AudioUniform;
    if ((varying & (frame_varying_uniform::kPointer | frame_varying_uniform::kParallax)) != 0)
        reasons |= DynamicReason::PointerUniform;
    if ((varying & frame_varying_uniform::kBones) != 0) reasons |= DynamicReason::BoneUniform;

    if (std::any_of(m_desc.video_textures.begin(), m_desc.video_textures.end(),
                    [](bool video) { return video; }))
        reasons |= DynamicReason::VideoInput;
    if (m_desc.dyn_vertex)
        reasons |=
            m_desc.event_vertex ? DynamicReason::EventMesh : DynamicReason::DynamicMesh;
    for (const auto& [index, sprite] : m_desc.sprites_map) {
        (void)index;
        if (sprite.FrameCount() > 1) {
            reasons |= DynamicReason::AnimatedSprite;
            break;
        }
    }
    // An image the runtime may swap in place changes without any graph edit,
    // and the swap leaves no trace in the values this cache samples.
    const auto* runtime_images =
        dynamic_cast<const wallpaper::RuntimeImageSource*>(scene.imageParser.get());
    if (runtime_images != nullptr) {
        for (const auto& texture : m_desc.textures) {
            if (texture.empty()) continue;
            if (runtime_images->IsRuntimeImage(texture)) {
                reasons |= DynamicReason::RuntimeImage;
                break;
            }
        }
    }
    // So may a cover bound over a render target: the target alone can be a
    // still picture, and the pass would keep it after a track brought a cover.
    if (std::any_of(m_desc.texture_covers.begin(), m_desc.texture_covers.end(),
                    [](const std::string& cover) { return ! cover.empty(); })) {
        reasons |= DynamicReason::RuntimeImage;
    }
    desc.dynamic_reasons = reasons;
    return desc;
}

StaticPassSample CustomShaderPass::frameSample(const Scene& scene) const {
    StaticPassSample sample;
    sample.visible = m_desc.visibility_node == nullptr ||
                    m_desc.visibility_node->EffectiveVisible() ||
                    (m_desc.visibility_node->MustProduce() && ! m_desc.output.empty() &&
                     m_desc.output != SpecTex_Default);

    uint64_t hash = 0xcbf29ce484222325ULL;
    if (m_desc.output == SpecTex_Default) {
        hash = StaticHashBytes(hash, scene.clearColor.data(), sizeof(float) * 3);
    }
    auto* node = m_desc.node;
    if (node != nullptr) {
        // Idempotent, and the transform has to be current before it can be
        // compared: a parent moved by a script updates lazily.
        node->UpdateTrans();
        const auto model = node->ModelTrans();
        hash = StaticHashBytes(hash, model.data(), sizeof(double) * 16);
        if (node->Mesh() != nullptr) {
            hash = StaticHashMix(hash, node->Mesh()->DirtyGeneration());
            const auto* material = node->Mesh()->MaterialForSlot(m_desc.material_slot);
            if (material != nullptr) {
                for (const auto& [name, value] : material->customShader.constValues) {
                    hash = StaticHashBytes(hash, name.data(), name.size());
                    hash = StaticHashBytes(hash, value.data(), value.size() * sizeof(float));
                }
            }
        }
        // Lights move, fade and switch without touching this node or material.
        if (const auto* updater = scene.shaderValueUpdater.get(); updater != nullptr) {
            hash = StaticHashMix(hash, updater->LightStateHash(node, m_desc.material_slot));
        }
    }
    hash = FoldPassCameras(hash, scene, m_desc.camera_override, node);
    for (const auto& [index, sprite] : m_desc.sprites_map) {
        hash = StaticHashMix(hash, index);
        hash = StaticHashMix(hash, static_cast<uint64_t>(sprite.GetCurFrame().imageId));
    }
    hash = StaticHashMix(hash, m_desc.vk_output.extent.width);
    hash = StaticHashMix(hash, m_desc.vk_output.extent.height);
    sample.hash = hash;
    return sample;
}

bool CustomShaderPass::textureDescriptorsReady() const {
    for (usize i = 0; i < m_desc.vk_texture_bindings.size(); ++i) {
        const auto& binding = m_desc.vk_texture_bindings[i];
        if (binding.image_binding < 0) continue;
        if (i >= m_desc.vk_textures.size() || m_desc.vk_textures[i].slots.empty()) {
            const auto texture_name =
                i < m_desc.textures.size() ? m_desc.textures[i].c_str() : "<missing texture slot>";
            LOG_ERROR("custom shader texture descriptor slot %zu (%s) has no image for binding %d",
                      i,
                      texture_name,
                      binding.image_binding);
            return false;
        }
        if (binding.sampler_binding >= 0 &&
            m_desc.vk_textures[i].getActive().sampler == VK_NULL_HANDLE) {
            const auto texture_name =
                i < m_desc.textures.size() ? m_desc.textures[i].c_str() : "<missing texture slot>";
            LOG_ERROR(
                "custom shader texture descriptor slot %zu (%s) has no sampler for binding %d",
                i,
                texture_name,
                binding.sampler_binding);
            return false;
        }
    }
    return true;
}

void CustomShaderPass::recordTextureBarriers(const Device& device, RenderingResources& rr) const {
    for (usize i = 0; i < m_desc.vk_textures.size(); i++) {
        auto& slot = m_desc.vk_textures[i];
        if (i >= m_desc.vk_texture_bindings.size()) continue;
        const auto& binding = m_desc.vk_texture_bindings[i];
        if (binding.image_binding < 0 || slot.slots.empty()) continue;
        device.tex_cache().PinVideoFrame(slot);
        RecordShaderReadBarrier(rr.command, slot.getActive());
    }
}

void CustomShaderPass::recordDescriptors(RenderingResources& rr, VkPipelineLayout layout,
                                         VkSampler sampler_override) const {
    std::array<VkDescriptorImageInfo, 2 * WE_GLTEX_NAMES.size()> images;
    std::array<VkWriteDescriptorSet, 2 * WE_GLTEX_NAMES.size() + 1> writes;
    VkDescriptorBufferInfo buffer;
    size_t image_count = 0;
    size_t write_count = 0;
    for (usize i = 0; i < m_desc.vk_textures.size(); ++i) {
        const auto& slot = m_desc.vk_textures[i];
        if (i >= m_desc.vk_texture_bindings.size()) continue;
        const auto& binding = m_desc.vk_texture_bindings[i];
        if (binding.image_binding < 0 || slot.slots.empty()) continue;
        const auto& image = slot.getActive();
        const VkSampler sampler = sampler_override != VK_NULL_HANDLE ? sampler_override : image.sampler;
        const bool combined =
            binding.image_descriptor_type == VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        if (! combined && binding.image_descriptor_type != VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE) {
            LOG_ERROR("unsupported texture descriptor type %d for binding %d",
                      (int)binding.image_descriptor_type, binding.image_binding);
            continue;
        }
        images[image_count] = {
            combined ? sampler : VK_NULL_HANDLE, image.view, image.layout
        };
        writes[write_count++] = {
            .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = nullptr,
            .dstSet = {},
            .dstBinding = (uint32_t)binding.image_binding,
            .descriptorCount = 1,
            .descriptorType = binding.image_descriptor_type,
            .pImageInfo = &images[image_count++],
        };
        if (! combined && binding.sampler_binding >= 0 && sampler != VK_NULL_HANDLE) {
            images[image_count] = { sampler, {}, VK_IMAGE_LAYOUT_UNDEFINED };
            writes[write_count++] = {
                .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .pNext = nullptr,
                .dstSet = {},
                .dstBinding = (uint32_t)binding.sampler_binding,
                .descriptorCount = 1,
                .descriptorType = VK_DESCRIPTOR_TYPE_SAMPLER,
                .pImageInfo = &images[image_count++],
            };
        }
    }
    if (m_desc.ubo_buf && m_desc.uniform_block.has_value()) {
        buffer = { rr.dyn_buf->gpuBuf(), m_desc.ubo_buf.offset, m_desc.ubo_buf.size };
        writes[write_count++] = {
            .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = nullptr,
            .dstSet = {},
            .dstBinding = m_desc.uniform_block->binding,
            .descriptorCount = 1,
            .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .pBufferInfo = &buffer,
        };
    }
    if (write_count != 0) {
        rr.command.PushDescriptorSetKHR(
            VK_PIPELINE_BIND_POINT_GRAPHICS, layout, 0,
            std::span<const VkWriteDescriptorSet>(writes.data(), write_count));
    }
}

void CustomShaderPass::recordDraw(const Device& device, RenderingResources& rr) {
    recordDrawWithPipeline(device, rr, m_desc.pipeline, m_desc.vk_output.extent);
}

void CustomShaderPass::recordDrawWithPipeline(
    const Device& device, RenderingResources& rr, const PipelineParameters& pipeline,
    VkExtent3D outext) {
    const VkViewport viewport {
        .x        = 0,
        .y        = (float)outext.height,
        .width    = (float)outext.width,
        .height   = -(float)outext.height,
        .minDepth = 0.0f,
        .maxDepth = 1.0f,
    };
    const VkRect2D scissor { { 0, 0 }, { outext.width, outext.height } };
    recordDrawWithPipeline(device, rr, pipeline, viewport, scissor, VK_NULL_HANDLE);
}

void CustomShaderPass::recordDrawWithPipeline(
    const Device& device, RenderingResources& rr, const PipelineParameters& pipeline,
    VkViewport viewport, VkRect2D scissor, VkSampler sampler_override) {
    auto& cmd = rr.command;
    cmd.BindPipeline(VK_PIPELINE_BIND_POINT_GRAPHICS, *pipeline.handle);
    for (usize i = 0; i < m_desc.vk_textures.size(); ++i) {
        if (i < m_desc.vk_texture_bindings.size() &&
            m_desc.vk_texture_bindings[i].image_binding >= 0 &&
            ! m_desc.vk_textures[i].slots.empty()) {
            device.tex_cache().PinVideoFrame(m_desc.vk_textures[i]);
        }
    }
    recordDescriptors(rr, *pipeline.layout, sampler_override);
    cmd.SetViewport(0, viewport);
    cmd.SetScissor(0, scissor);

    auto gpu_buf = m_desc.dyn_vertex ? rr.dyn_buf->gpuBuf() : rr.vertex_buf->gpuBuf();

    for (usize i = 0; i < m_desc.vertex_bufs.size(); i++) {
        auto& buf = m_desc.vertex_bufs[i];
        cmd.BindVertexBuffers((u32)i, 1, &gpu_buf, &buf.offset);
    }
    if (m_desc.index_buf) {
        cmd.BindIndexBuffer(gpu_buf, m_desc.index_buf.offset, m_desc.index_type);
        if (!m_desc.draw_ranges.empty()) {
            for (const auto& range : m_desc.draw_ranges) {
                cmd.DrawIndexed(range.indexCount, 1, range.indexOffset, 0, 0);
            }
        } else {
            cmd.DrawIndexed(m_desc.draw_count, 1, 0, 0, 0);
        }
    } else {
        cmd.Draw(m_desc.draw_count, 1, 0, 0);
    }
}

void CustomShaderPass::recordClear(const Device&, RenderingResources& rr) {
    auto&                   cmd = rr.command;
    VkImageSubresourceRange base_srang {
        .aspectMask     = VK_IMAGE_ASPECT_COLOR_BIT,
        .baseMipLevel   = 0,
        .levelCount     = VK_REMAINING_MIP_LEVELS,
        .baseArrayLayer = 0,
        .layerCount     = VK_REMAINING_ARRAY_LAYERS,
    };
    const auto clear_image = [&](VkImage image, VkImageLayout old_layout,
                                 VkImageLayout final_layout, VkPipelineStageFlags src_stage,
                                 VkAccessFlags src_access, VkPipelineStageFlags dst_stage,
                                 VkAccessFlags dst_access) {
        if (image == VK_NULL_HANDLE) return;
        VkImageMemoryBarrier in_bar {
            .sType            = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext            = nullptr,
            .srcAccessMask    = src_access,
            .dstAccessMask    = VK_ACCESS_TRANSFER_WRITE_BIT,
            .oldLayout        = old_layout,
            .newLayout        = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .image            = image,
            .subresourceRange = base_srang,
        };
        cmd.PipelineBarrier(src_stage,
                            VK_PIPELINE_STAGE_TRANSFER_BIT,
                            0,
                            in_bar);
        cmd.ClearColorImage(image,
                            VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                            &m_desc.clear_value.color,
                            base_srang);
        VkImageMemoryBarrier out_bar {
            .sType            = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext            = nullptr,
            .srcAccessMask    = VK_ACCESS_TRANSFER_WRITE_BIT,
            .dstAccessMask    = dst_access,
            .oldLayout        = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .newLayout        = final_layout,
            .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .image            = image,
            .subresourceRange = base_srang,
        };
        cmd.PipelineBarrier(VK_PIPELINE_STAGE_TRANSFER_BIT,
                            dst_stage,
                            0,
                            out_bar);
    };
    clear_image(m_desc.vk_output.handle,
                VK_IMAGE_LAYOUT_UNDEFINED,
                VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                VK_PIPELINE_STAGE_VERTEX_SHADER_BIT | VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT |
                    VK_PIPELINE_STAGE_TRANSFER_BIT | VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_TRANSFER_READ_BIT |
                    VK_ACCESS_TRANSFER_WRITE_BIT | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
                VK_PIPELINE_STAGE_VERTEX_SHADER_BIT | VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                VK_ACCESS_SHADER_READ_BIT);
    clear_image(m_desc.vk_output_msaa.handle,
                VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                VK_PIPELINE_STAGE_VERTEX_SHADER_BIT | VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT |
                    VK_PIPELINE_STAGE_TRANSFER_BIT | VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_TRANSFER_READ_BIT |
                    VK_ACCESS_TRANSFER_WRITE_BIT | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
                VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT);
}

VkResult CustomShaderPass::execute(const Device& device, RenderingResources& rr) {
    const auto candidate = batchCandidate();
    if (! candidate.visible) {
        if (candidate.clear_only) {
            recordClear(device, rr);
        }
        return VK_SUCCESS;
    }
    recordTextureBarriers(device, rr);

    const auto            info = renderInfo();
    std::array<VkClearValue, 3> clear_values {};
    FillCustomPassClearValues(info, clear_values);
    VkRenderPassBeginInfo pass_begin_info {
        .sType       = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        .pNext       = nullptr,
        .renderPass  = info.render_pass,
        .framebuffer = info.framebuffer,
        .renderArea =
            VkRect2D {
                .offset = { 0, 0 },
                .extent = { info.extent.width, info.extent.height },
            },
        .clearValueCount = CustomPassBeginRenderPassClearValueCount(info),
        .pClearValues    = clear_values.data(),
    };
    rr.command.BeginRenderPass(pass_begin_info, VK_SUBPASS_CONTENTS_INLINE);
    recordDraw(device, rr);
    rr.command.EndRenderPass();
    return VK_SUCCESS;
}

bool CustomShaderPass::canPresentDirectly(const RenderingResources& rr, VkExtent2D target_extent,
                                         VkFormat target_format) const {
    if (! prepared() || ! m_presentation_pipeline.handle || ! m_presentation_pipeline.pass ||
        ! m_presentation_pipeline.layout || target_format != m_desc.presentation_format ||
        rr.wallpaper_horizontal_flip || target_extent.width == 0 || target_extent.height == 0)
        return false;
    const auto candidate = batchCandidate();
    const auto& output = m_desc.vk_output;
    const bool through_final = m_desc.presents_through_final_viewport;
    if (! candidate.visible || candidate.clear_only || m_desc.alpha_to_coverage ||
        candidate.render.sample_count != VK_SAMPLE_COUNT_1_BIT ||
        candidate.render.msaa_image != VK_NULL_HANDLE || candidate.render.msaa_view != VK_NULL_HANDLE ||
        output.handle == VK_NULL_HANDLE || output.view == VK_NULL_HANDLE ||
        output.extent.depth != 1 || output.mipmap_level != 1)
        return false;
    if (through_final) {
        // The final composition samples the output with the output's own
        // sampler; the source is sampled with that same one instead.
        if (output.sampler == VK_NULL_HANDLE) return false;
    } else {
        if (output.extent.width != target_extent.width ||
            output.extent.height != target_extent.height)
            return false;
        const auto viewport = ResolvePresentationViewport(rr, target_extent);
        const auto scissor = ResolvePresentationScissor(rr, target_extent);
        if (viewport.x != 0.0f || viewport.y != static_cast<float>(target_extent.height) ||
            viewport.width != static_cast<float>(target_extent.width) ||
            viewport.height != -static_cast<float>(target_extent.height) ||
            viewport.minDepth != 0.0f || viewport.maxDepth != 1.0f ||
            scissor.offset.x != 0 || scissor.offset.y != 0 ||
            scissor.extent.width != target_extent.width || scissor.extent.height != target_extent.height)
            return false;
    }
    size_t bound = 0;
    for (size_t i = 0; i < m_desc.vk_texture_bindings.size(); ++i) {
        if (m_desc.vk_texture_bindings[i].image_binding < 0) continue;
        if (i >= m_desc.vk_textures.size() || m_desc.vk_textures[i].slots.empty()) return false;
        const auto& image = m_desc.vk_textures[i].getActive();
        if (image.handle == VK_NULL_HANDLE || image.view == VK_NULL_HANDLE ||
            image.handle == output.handle)
            return false;
        ++bound;
        // Only then is the output a texel-for-texel copy of the source, which
        // is what makes sampling the source the same as sampling the output. A
        // source decoded smaller than the output was resampled into it.
        if (through_final &&
            (image.extent.width != output.extent.width || image.extent.height != output.extent.height ||
             image.extent.depth != 1 || image.mipmap_level != 1))
            return false;
    }
    return ! through_final || bound == 1;
}

VkResult CustomShaderPass::executePresentation(const Device& device, RenderingResources& rr,
                                               const ImageParameters& target, VkFormat target_format) {
    const VkExtent2D extent { target.extent.width, target.extent.height };
    if (target.extent.depth != 1 || target.mipmap_level != 1 ||
        ! canPresentDirectly(rr, extent, target_format))
        return VK_ERROR_INITIALIZATION_FAILED;
    for (size_t i = 0; i < m_desc.vk_textures.size(); ++i) {
        if (i < m_desc.vk_texture_bindings.size() && m_desc.vk_texture_bindings[i].image_binding >= 0 &&
            ! m_desc.vk_textures[i].slots.empty() &&
            m_desc.vk_textures[i].getActive().handle == target.handle)
            return VK_ERROR_INITIALIZATION_FAILED;
    }
    VkFramebuffer framebuffer = VK_NULL_HANDLE;
    const auto result = GetOrCreateColorFramebuffer(
        device, *m_presentation_pipeline.pass, target, m_presentation_framebuffers, framebuffer);
    if (result != VK_SUCCESS) return result;
    return recordPresentation(device, rr, *m_presentation_pipeline.pass, framebuffer, extent);
}

VkResult CustomShaderPass::recordPresentation(const Device& device, RenderingResources& rr,
                                              VkRenderPass render_pass, VkFramebuffer framebuffer,
                                              VkExtent2D extent) {
    if (render_pass == VK_NULL_HANDLE || framebuffer == VK_NULL_HANDLE ||
        ! canPresentDirectly(rr, extent, m_desc.presentation_format))
        return VK_ERROR_INITIALIZATION_FAILED;
    recordTextureBarriers(device, rr);
    VkRenderPassBeginInfo begin {
        .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        .renderPass = render_pass,
        .framebuffer = framebuffer,
        .renderArea = { { 0, 0 }, extent },
        .clearValueCount = 1,
        .pClearValues = &m_desc.clear_value,
    };
    rr.command.BeginRenderPass(begin, VK_SUBPASS_CONTENTS_INLINE);
    if (m_desc.presents_through_final_viewport) {
        // The final composition's own viewport, scissor and sampler, so each
        // target pixel receives the texel it would have read from the copy.
        recordDrawWithPipeline(device, rr, m_presentation_pipeline,
                               ResolvePresentationViewport(rr, extent),
                               ResolvePresentationScissor(rr, extent), m_desc.vk_output.sampler);
    } else {
        recordDrawWithPipeline(device, rr, m_presentation_pipeline,
                               VkExtent3D { extent.width, extent.height, 1 });
    }
    rr.command.EndRenderPass();
    return VK_SUCCESS;
}

void CustomShaderPass::destory(const Device&, RenderingResources& rr) {
    m_scene = nullptr;
    setPrepared(false);
    m_frame_visible = false;
    m_frame_clear_only = false;
    m_presentation_framebuffers.clear();
    m_presentation_copy_source_pass = {};
    ResetPipelineParameters(m_presentation_pipeline);
    m_desc.update_op = {};
    {
        auto& buf = m_desc.dyn_vertex ? rr.dyn_buf : rr.vertex_buf;
        for (auto& bufref : m_desc.vertex_bufs) {
            buf->unallocateSubRef(bufref);
        }
        buf->unallocateSubRef(m_desc.index_buf);
    }
    m_desc.vertex_bufs.clear();
    m_desc.index_buf = {};
    rr.dyn_buf->unallocateSubRef(m_desc.ubo_buf);
    m_desc.ubo_buf = {};
    m_desc.fb.reset();
    m_desc.vk_textures.clear();
    m_desc.vk_cover_targets.clear();
    m_desc.vk_cover_images.clear();
    m_desc.vk_texture_bindings.clear();
    m_desc.vk_texture_image_keys.clear();
    m_desc.vk_output = {};
    m_desc.vk_output_msaa = {};
    m_desc.vk_output_depth = {};
    m_desc.with_depth = false;
    m_desc.video_textures.clear();
    m_desc.draw_count = 0;
    m_desc.draw_ranges.clear();
    m_desc.uniform_block.reset();
    m_desc.blending = false;
    m_desc.alpha_to_coverage = false;
    m_desc.uploaded_mesh_dirty_generation = std::numeric_limits<uint64_t>::max();
    ResetPipelineParameters(m_desc.pipeline);
}

void CustomShaderPass::setDescTex(u32 index, std::string_view tex_key) {
    assert(index < m_desc.textures.size());
    if (index >= m_desc.textures.size()) return;
    m_desc.textures[index] = tex_key;
}

bool wallpaper::vulkan::UpdatePreparedPasses(const Device& device, RenderingResources& rr,
                                             std::span<VulkanPass* const> passes) {
    for (auto* pass : passes) {
        if (pass != nullptr && pass->prepared() && ! pass->updateFrame(device, rr)) return false;
    }
    return true;
}

bool wallpaper::vulkan::HiddenClearIsObservable(std::span<VulkanPass* const>        graph,
                                                std::span<CustomShaderPass* const> clearing) {
    if (clearing.empty() || clearing.front() == nullptr) return true;
    const auto& first = *clearing.front();
    // The scene output is always read after the frame -- by the final
    // composition, by direct presentation or by whoever captures it.
    if (first.desc().output == SpecTex_Default) return true;
    const auto render = first.batchCandidate().render;
    const VkImage image = render.image;
    const VkImage msaa  = render.msaa_image;
    if (image == VK_NULL_HANDLE) return true;
    const auto is_image = [&](VkImage candidate) {
        return candidate != VK_NULL_HANDLE && (candidate == image || candidate == msaa);
    };
    const auto clearing_pass = [&](const VulkanPass* pass) {
        return std::find(clearing.begin(), clearing.end(), pass) != clearing.end();
    };
    const auto position = std::find(graph.begin(), graph.end(), clearing.front());
    // Not in the list it is supposed to belong to: nothing can be proven.
    if (position == graph.end()) return true;
    const auto clear_index = static_cast<std::size_t>(position - graph.begin());

    for (std::size_t k = 0; k < graph.size(); ++k) {
        const auto* pass = graph[k];
        if (pass == nullptr || clearing_pass(pass)) continue;
        if (dynamic_cast<const PrePass*>(pass) != nullptr) continue; // another clear, not a read
        if (const auto* fin = dynamic_cast<const FinPass*>(pass)) {
            if (is_image(fin->sourceImage().handle)) return true;
            continue;
        }
        if (const auto* copy = dynamic_cast<const CopyPass*>(pass)) {
            if (is_image(copy->desc().vk_src.handle) || is_image(copy->desc().vk_dst.handle))
                return true;
            continue;
        }
        const auto* custom = dynamic_cast<const CustomShaderPass*>(pass);
        if (custom == nullptr) return true; // a pass shape this cannot reason about
        if (! custom->prepared()) continue;
        const auto candidate = custom->batchCandidate();
        // A pass before the clear reads what the previous frame's clear left,
        // whether or not it draws this frame -- it may draw the next one. A
        // pass after it matters only when it draws now: one that starts
        // drawing later is covered by the frame in which it does.
        if (k > clear_index && ! candidate.visible) continue;
        const auto& desc = custom->desc();
        for (std::size_t t = 0; t < desc.vk_textures.size(); ++t) {
            if (t < desc.vk_texture_bindings.size() && desc.vk_texture_bindings[t].image_binding < 0)
                continue;
            // Every slot, not only the active one: the active slot of a
            // sprite sheet or a ping-pong pair moves between frames.
            for (const auto& slot : desc.vk_textures[t].slots)
                if (is_image(slot.handle)) return true;
        }
        if (is_image(candidate.render.image) || is_image(candidate.render.msaa_image)) {
            // Rendering over it from a clear of its own reads nothing.
            const bool clears = candidate.clear_only ||
                                candidate.render.load_op == VK_ATTACHMENT_LOAD_OP_CLEAR;
            if (! clears) return true;
        }
    }
    return false;
}

VkResult wallpaper::vulkan::ExecutePreparedPasses(const Device& device, RenderingResources& rr,
                                              std::span<VulkanPass* const> passes,
                                              CustomPassExecutionScratch& scratch,
                                              std::span<VulkanPass* const> graph) {
    if (graph.empty()) graph = passes;
    size_t i = 0;
    while (i < passes.size()) {
        auto* pass = passes[i];
        if (pass == nullptr || ! pass->prepared()) {
            ++i;
            continue;
        }
        if (const auto* pre = dynamic_cast<PrePass*>(pass);
            pre != nullptr && IsPreClearRedundant(*pre, passes.subspan(i + 1))) {
            ++i;
            continue;
        }
        if (dynamic_cast<CustomShaderPass*>(pass) == nullptr) {
            const auto result = pass->execute(device, rr);
            if (result != VK_SUCCESS) return result;
            ++i;
            continue;
        }
        scratch.passes.clear();
        scratch.candidates.clear();
        for (; i < passes.size(); ++i) {
            auto* current = passes[i];
            if (current == nullptr || ! current->prepared()) break;
            auto* custom = dynamic_cast<CustomShaderPass*>(current);
            if (custom == nullptr) break;
            scratch.passes.push_back(custom);
            scratch.candidates.push_back(custom->batchCandidate());
        }
        PlanCustomPassBatches(scratch.candidates, scratch.plan);
        for (const auto& entry : scratch.plan.entries) {
            if (entry.kind == CustomPassBatchKind::ClearImage) {
                // A hidden layer's first-use clear that nothing will read --
                // not later in this frame, not through the previous frame's
                // contents -- writes pixels no one sees.
                const auto clearing = std::span<CustomShaderPass* const>(scratch.passes)
                                          .subspan(entry.first, entry.last - entry.first);
                if (HiddenClearIsObservable(graph, clearing))
                    scratch.passes[entry.first]->recordClear(device, rr);
                continue;
            }
            for (size_t local = entry.first; local < entry.last; ++local) {
                if (scratch.candidates[local].visible)
                    scratch.passes[local]->recordTextureBarriers(device, rr);
            }
            std::array<VkClearValue, 3> clear_values {};
            FillCustomPassClearValues(entry.render, clear_values);
            VkRenderPassBeginInfo begin {
                .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
                .pNext = nullptr,
                .renderPass = entry.render.render_pass,
                .framebuffer = entry.render.framebuffer,
                .renderArea = { { 0, 0 }, { entry.render.extent.width, entry.render.extent.height } },
                .clearValueCount = CustomPassBeginRenderPassClearValueCount(entry.render),
                .pClearValues = clear_values.data(),
            };
            rr.command.BeginRenderPass(begin, VK_SUBPASS_CONTENTS_INLINE);
            for (size_t local = entry.first; local < entry.last; ++local) {
                if (scratch.candidates[local].visible)
                    scratch.passes[local]->recordDraw(device, rr);
            }
            rr.command.EndRenderPass();
        }
    }
    return VK_SUCCESS;
}
