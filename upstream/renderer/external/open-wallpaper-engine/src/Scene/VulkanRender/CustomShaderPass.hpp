#pragma once
#include "VulkanPass.hpp"
#include "PassCommon.hpp"
#include <string>
#include <vector>

#include "Vulkan/Device.hpp"
#include "Scene/Scene.h"
#include "Vulkan/StagingBuffer.hpp"
#include "Vulkan/GraphicsPipeline.hpp"
#include "Vulkan/Shader.hpp"
#include "VulkanRender/PassBatch.hpp"
#include "VulkanRender/StaticSubgraphCache.hpp"
#include "SpecTexs.hpp"
#include "SpriteAnimation.hpp"
#include "Interface/IShaderValueUpdater.h"

#include <cstdint>
#include <limits>
#include <optional>
#include <charconv>
#include <string_view>

namespace wallpaper
{

namespace vulkan
{

class CustomShaderPass : public VulkanPass {
public:
    struct Desc {
        struct TextureBinding {
            i32              image_binding { -1 };
            VkDescriptorType image_descriptor_type { VK_DESCRIPTOR_TYPE_MAX_ENUM };
            i32              sampler_binding { -1 };
        };

        // in
        SceneNode*               node { nullptr };
        SceneNode*               visibility_node { nullptr };
        std::vector<std::string> textures;
        /// `SceneMaterial::texture_covers`: per slot, the cover bound in place
        /// of that slot's render target while one is published; empty for a
        /// slot that always samples what `textures` names.
        std::vector<std::string> texture_covers;
        std::string              output;
        std::string              camera_override;
        std::size_t              submesh_index { 0 };
        uint32_t                 material_slot { 0 };
        bool                     clear_on_first_use { false };
        bool                     preserve_target_contents { false };
        bool                     write_alpha { true };
        /// How this draw blends instead of its material's blending. The last
        /// pass of an effect chain is also the draw that puts the layer onto
        /// the scene with the layer's blending; drawn into the layer's own
        /// composite it writes its result as every other pass of the chain
        /// does (`BlendMode::Normal`, a replace).
        std::optional<BlendMode> blend_override;
        bool                     alpha_to_coverage { false };
        VkSampleCountFlagBits    sample_count { VK_SAMPLE_COUNT_1_BIT };
        VkFormat                 presentation_format { VK_FORMAT_UNDEFINED };
        /// Set only for a pass that is, by how its scene is built, the final
        /// composition's own full-target quad copying one texture into the
        /// scene output: the plain-video scene. Presenting it may then draw
        /// straight into the target through the final composition's viewport
        /// and scissor, sampling that texture with the scene output's sampler
        /// -- exactly what the final composition does with the copy -- instead
        /// of only when output, target and viewport coincide.
        bool                     presents_through_final_viewport { false };
        sprite_map_t             sprites_map;

        // -----prepared
        // vulkan texs
        std::vector<ImageSlotsRef> vk_textures;
        std::vector<std::string>   vk_texture_image_keys;
        /// For a slot with a cover (`texture_covers`): its render target, which
        /// `vk_textures` holds again whenever no cover is published, and the
        /// cover last uploaded for it, kept while the target is bound so the
        /// next cover retires it.
        std::vector<ImageSlotsRef> vk_cover_targets;
        std::vector<ImageSlotsRef> vk_cover_images;
        std::vector<TextureBinding> vk_texture_bindings;
        std::vector<bool>          video_textures;
        /// One log per import-failure transition, not one per tick. Cleared
        /// when that slot's update succeeds again.
        std::vector<bool>          video_update_failure_reported;
        ImageParameters            vk_output;
        ImageParameters            vk_output_msaa;
        ImageParameters            vk_output_depth;
        bool                       with_depth { false };

        // bufs
        bool                          dyn_vertex { false };
        /// Set only for a `dyn_vertex` mesh the runtime rewrites on an event
        /// rather than every frame. Changes nothing about how the vertices are
        /// uploaded; read only when reporting why the scene must keep drawing.
        bool                          event_vertex { false };
        std::vector<StagingBufferRef> vertex_bufs;
        StagingBufferRef              index_buf;
        StagingBufferRef              ubo_buf;

        // pipeline
        VkClearValue       clear_value;
        bool               blending { false };
        vvk::Framebuffer   fb;
        PipelineParameters pipeline;
        u32                draw_count { 0 };
        VkIndexType        index_type { VK_INDEX_TYPE_UINT16 };
        std::vector<SceneMesh::DrawRange> draw_ranges;

        // uniforms
        std::optional<ShaderReflected::Block> uniform_block;
        std::function<bool()>                 update_op;
        uint64_t uploaded_mesh_dirty_generation { std::numeric_limits<uint64_t>::max() };
    };

    CustomShaderPass(const Desc&);
    virtual ~CustomShaderPass();

    void        setDescTex(u32 index, std::string_view tex_key);
    Desc&       desc() { return m_desc; }
    const Desc& desc() const { return m_desc; }

    void prepare(Scene&, const Device&, RenderingResources&) override;
    bool updateFrame(const Device&, RenderingResources&) override;
    VkResult execute(const Device&, RenderingResources&) override;
    void destory(const Device&, RenderingResources&) override;

    CustomPassBatchCandidate batchCandidate() const;
    CustomPassRenderInfo     renderInfo() const;
    void                     recordDraw(const Device&, RenderingResources&);
    void                     recordClear(const Device&, RenderingResources&);
    void recordTextureBarriers(const Device&, RenderingResources&) const;

    /// Compile-time shape of this pass for the static subgraph cache: the
    /// target it writes, the targets it reads and why it may be dynamic.
    StaticPassDesc staticPassDesc(const Scene&) const;
    /// Everything that can change this pass's output without changing the
    /// graph, folded into one value.
    StaticPassSample frameSample(const Scene&) const;
    /// Suppresses this frame's draw and its uniform update. The previous
    /// frame's pixels stay in the target, so the caller must have proved the
    /// target still owns them.
    void setFrameSkipped(bool skipped) { m_frame_skipped = skipped; }
    bool frameSkipped() const { return m_frame_skipped; }

    bool textureDescriptorsReady() const;
    bool canPresentDirectly(const RenderingResources&, VkExtent2D target_extent,
                            VkFormat target_format) const;
    VkResult executePresentation(const Device&, RenderingResources&, const ImageParameters& target,
                                 VkFormat target_format);
    /// A render pass compatible with the presentation pipeline that leaves
    /// its target ready to be copied from, for composing a poster.
    [[nodiscard]] VkRenderPass presentationCopySourcePass() const {
        return *m_presentation_copy_source_pass;
    }
    /// What `executePresentation` records, through `render_pass` into an
    /// `extent`-sized `framebuffer` of the presentation format.
    VkResult recordPresentation(const Device&, RenderingResources&, VkRenderPass render_pass,
                                VkFramebuffer framebuffer, VkExtent2D extent);

private:
    /// `sampler_override`, when set, replaces every bound texture's sampler.
    void recordDescriptors(RenderingResources&, VkPipelineLayout,
                           VkSampler sampler_override = VK_NULL_HANDLE) const;
    void recordDrawWithPipeline(const Device&, RenderingResources&, const PipelineParameters&,
                                VkExtent3D);
    void recordDrawWithPipeline(const Device&, RenderingResources&, const PipelineParameters&,
                                VkViewport, VkRect2D scissor,
                                VkSampler sampler_override);

    Desc m_desc {};
    const Scene* m_scene { nullptr };
    PipelineParameters m_presentation_pipeline;
    vvk::RenderPass m_presentation_copy_source_pass;
    std::vector<CachedColorFramebuffer> m_presentation_framebuffers;
    bool m_frame_visible { false };
    bool m_frame_clear_only { false };
    bool m_frame_skipped { false };
};

namespace detail
{

inline CustomShaderPass::Desc::TextureBinding ReflectedTextureBinding(
    const ShaderReflected& reflection,
    std::string_view       texture_name) {
    CustomShaderPass::Desc::TextureBinding texture_binding;
    const auto image_iter = reflection.binding_map.find(std::string(texture_name));
    if (image_iter != reflection.binding_map.end()) {
        texture_binding.image_binding = (i32)image_iter->second.binding;
        texture_binding.image_descriptor_type = image_iter->second.descriptorType;
    }

    const std::string sampler_name = std::string("_we_Sampler_") + std::string(texture_name);
    const auto        sampler_iter = reflection.binding_map.find(sampler_name);
    if (sampler_iter != reflection.binding_map.end()) {
        texture_binding.sampler_binding = (i32)sampler_iter->second.binding;
    }
    return texture_binding;
}

inline std::optional<usize> CustomShaderTextureSlot(std::string_view name) {
    constexpr std::string_view prefix { "g_Texture" };
    if (! wallpaper::sstart_with(name, prefix)) return std::nullopt;
    name.remove_prefix(prefix.size());
    if (name.empty()) return std::nullopt;
    usize slot = 0;
    const auto result = std::from_chars(name.data(), name.data() + name.size(), slot);
    if (result.ec != std::errc {} || result.ptr != name.data() + name.size()) {
        return std::nullopt;
    }
    if (slot >= WE_GLTEX_NAMES.size() || (name.size() > 1u && name.front() == '0')) {
        return std::nullopt;
    }
    return slot;
}

inline std::optional<usize> CustomShaderSamplerSlot(std::string_view name) {
    constexpr std::string_view prefix { "_we_Sampler_" };
    if (! wallpaper::sstart_with(name, prefix)) return std::nullopt;
    return CustomShaderTextureSlot(name.substr(prefix.size()));
}

inline const VkDescriptorSetLayoutBinding*
ReflectedUniformBlockBinding(const ShaderReflected& reflection) {
    if (reflection.blocks.empty()) return nullptr;

    const auto& block = reflection.blocks.front();
    const auto iter = reflection.binding_map.find(block.name);
    if (iter == reflection.binding_map.end()) return nullptr;
    if (iter->second.binding != block.binding) return nullptr;
    if (iter->second.descriptorType != VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER) return nullptr;
    if (iter->second.descriptorCount != 1) return nullptr;
    return &iter->second;
}

inline bool PlanCustomShaderDescriptors(
    const ShaderReflected&                                                 reflection,
    usize                                                                  texture_count,
    std::vector<CustomShaderPass::Desc::TextureBinding>&                   texture_bindings,
    std::vector<VkDescriptorSetLayoutBinding>&                             layout_bindings) {
    texture_bindings.clear();
    layout_bindings.clear();
    if (texture_count > WE_GLTEX_NAMES.size()) return false;

    const auto* uniform_binding = ReflectedUniformBlockBinding(reflection);
    if (! reflection.blocks.empty() && uniform_binding == nullptr) return false;
    if (uniform_binding != nullptr) layout_bindings.push_back(*uniform_binding);

    texture_bindings.resize(texture_count);

    for (const auto& [name, binding] : reflection.binding_map) {
        if (binding.descriptorCount != 1) return false;

        if (uniform_binding != nullptr && name == reflection.blocks.front().name) continue;

        if (const auto slot = CustomShaderTextureSlot(name); slot.has_value()) {
            if (*slot >= texture_count) return false;
            if (binding.descriptorType != VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE &&
                binding.descriptorType != VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER) {
                return false;
            }
            continue;
        }

        if (const auto slot = CustomShaderSamplerSlot(name); slot.has_value()) {
            if (*slot >= texture_count) return false;
            if (binding.descriptorType != VK_DESCRIPTOR_TYPE_SAMPLER) return false;
            const auto image_iter = reflection.binding_map.find(WE_GLTEX_NAMES[*slot]);
            if (image_iter == reflection.binding_map.end() ||
                image_iter->second.descriptorType != VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE) {
                return false;
            }
            continue;
        }

        return false;
    }

    for (usize i = 0; i < texture_count; i++) {
        const auto texture_binding = detail::ReflectedTextureBinding(reflection, WE_GLTEX_NAMES[i]);
        texture_bindings[i] = texture_binding;
        if (texture_binding.image_binding < 0) continue;

        const auto image_iter = reflection.binding_map.find(WE_GLTEX_NAMES[i]);
        if (image_iter == reflection.binding_map.end()) return false;
        const auto& image_binding = image_iter->second;
        if (image_binding.descriptorCount != 1) return false;
        if (image_binding.descriptorType != VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE &&
            image_binding.descriptorType != VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER) {
            return false;
        }
        if (image_binding.descriptorType == VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE &&
            texture_binding.sampler_binding < 0) {
            return false;
        }
        if (image_binding.descriptorType == VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER &&
            texture_binding.sampler_binding >= 0) {
            return false;
        }
        layout_bindings.push_back(image_binding);

        if (texture_binding.sampler_binding >= 0) {
            const std::string sampler_name =
                std::string("_we_Sampler_") + std::string(WE_GLTEX_NAMES[i]);
            const auto sampler_iter = reflection.binding_map.find(sampler_name);
            if (sampler_iter == reflection.binding_map.end()) return false;
            const auto& sampler_binding = sampler_iter->second;
            if (sampler_binding.descriptorType != VK_DESCRIPTOR_TYPE_SAMPLER) return false;
            if (sampler_binding.descriptorCount != 1) return false;
            layout_bindings.push_back(sampler_binding);
        }
    }

    return true;
}

} // namespace detail

} // namespace vulkan
} // namespace wallpaper
