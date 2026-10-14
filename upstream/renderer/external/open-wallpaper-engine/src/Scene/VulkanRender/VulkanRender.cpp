#include "VulkanRender.hpp"

#include "Utils/Logging.h"
#include "Utils/AutoDeletor.hpp"
#include "RenderGraph/RenderGraph.hpp"
#include "Scene/Scene.h"
#include "Interface/IShaderValueUpdater.h"

#include "Utils/Algorism.h"

#include <glslang/Public/ShaderLang.h>

#include "Vulkan/Device.hpp"
#include "Vulkan/TextureCache.hpp"
#include "Vulkan/Swapchain.hpp"
#include "Vulkan/Util.hpp"
#include "Vulkan/VulkanExSwapchain.hpp"

#include "VulkanPass.hpp"
#include "CustomShaderPass.hpp"
#include "CopyPass.hpp"
#include "VulkanRender/StaticSubgraphCache.hpp"
#include "VulkanRender/UnchangedPresent.hpp"
#include "VulkanRender/CopyElision.hpp"
#include "PrePass.hpp"
#include "FinPass.hpp"
#include "Resource.hpp"
#include "TexturePrefetch.hpp"
#include "Interface/IImageParser.h"
#include "SpecTexs.hpp"
#include "PassCommon.hpp"

#include "Core/ArrayHelper.hpp"

#include <algorithm>
#include <atomic>
#include <cassert>
#include <cmath>
#include <cstdint>
#include <exception>
#include <unistd.h>
#include <vector>

#if ENABLE_RENDERDOC_API
#    include "RenderDoc.h"
#endif

using namespace wallpaper::vulkan;

constexpr uint64_t vk_wait_time { 10u * 1000u * 1000000u };
constexpr uint32_t vk_command_num { 2 };

constexpr std::array base_inst_exts {
    Extension { false, VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME },
};
std::vector<Extension> BaseDeviceExtensions() {
    std::vector<Extension> extensions {
        Extension { false, VK_EXT_MEMORY_BUDGET_EXTENSION_NAME },
        Extension { true, VK_KHR_PUSH_DESCRIPTOR_EXTENSION_NAME },
    };
#if defined(__APPLE__)
    extensions.push_back({ true, "VK_EXT_metal_objects" });
#endif
#if defined(__linux__)
    extensions.push_back({ true, VK_KHR_EXTERNAL_MEMORY_EXTENSION_NAME });
    extensions.push_back({ true, VK_KHR_EXTERNAL_SEMAPHORE_EXTENSION_NAME });
    extensions.push_back({ true, VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME });
    extensions.push_back({ true, VK_KHR_EXTERNAL_SEMAPHORE_FD_EXTENSION_NAME });
#endif
    return extensions;
}

namespace
{
const char* WallpaperScalingModeName(wallpaper::WallpaperScalingMode mode) {
    switch (mode) {
    case wallpaper::WallpaperScalingMode::NONE: return "none";
    case wallpaper::WallpaperScalingMode::STRETCH: return "stretch";
    case wallpaper::WallpaperScalingMode::FIT: return "fit";
    case wallpaper::WallpaperScalingMode::FILL: return "fill";
    }

    return "unknown";
}

double NormalizeScaleFactor(double scale_factor) {
    if (! std::isfinite(scale_factor) || scale_factor <= 0.0) return 1.0;
    return scale_factor;
}

/// The largest poster the renderer composes on request, in bytes.
constexpr std::size_t kPosterByteLimit = 128u * 1024u * 1024u;

/// The image a requested poster is composed into, so the drawable itself is
/// only ever rendered to. It lives for one frame.
struct PosterTarget {
    VmaImageParameters image;
    vvk::Framebuffer   framebuffer;
};

/// Allocates an image of the drawable's size and format for `pass` to compose
/// into. Refused when what was actually allocated exceeds the poster limit.
bool CreatePosterTarget(const Device& device, VkFormat format, VkExtent3D extent,
                        VkRenderPass pass, PosterTarget& out) {
    out = {};
    if (pass == VK_NULL_HANDLE || extent.width == 0 || extent.height == 0) return false;
    PosterTarget target;
    target.image.extent = extent;
    const VkImageCreateInfo image_info {
        .sType         = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType     = VK_IMAGE_TYPE_2D,
        .format        = format,
        .extent        = extent,
        .mipLevels     = 1,
        .arrayLayers   = 1,
        .samples       = VK_SAMPLE_COUNT_1_BIT,
        .tiling        = VK_IMAGE_TILING_OPTIMAL,
        .usage         = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
        .sharingMode   = VK_SHARING_MODE_EXCLUSIVE,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
    };
    const VmaAllocationCreateInfo allocation { .usage = VMA_MEMORY_USAGE_GPU_ONLY };
    if (vvk::CreateImage(device.vma_allocator(), image_info, allocation, target.image.handle) !=
        VK_SUCCESS)
        return false;
    VmaAllocationInfo allocated {};
    vmaGetAllocationInfo(device.vma_allocator(), target.image.handle.Allocation(), &allocated);
    if (allocated.size > kPosterByteLimit) return false;
    const VkImageViewCreateInfo view_info {
        .sType            = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image            = *target.image.handle,
        .viewType         = VK_IMAGE_VIEW_TYPE_2D,
        .format           = format,
        .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 },
    };
    if (device.handle().CreateImageView(view_info, target.image.view) != VK_SUCCESS) return false;
    const VkImageView view = *target.image.view;
    const VkFramebufferCreateInfo framebuffer_info {
        .sType           = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
        .renderPass      = pass,
        .attachmentCount = 1,
        .pAttachments    = &view,
        .width           = extent.width,
        .height          = extent.height,
        .layers          = 1,
    };
    if (device.handle().CreateFramebuffer(framebuffer_info, target.framebuffer) != VK_SUCCESS)
        return false;
    out = std::move(target);
    return true;
}

} // namespace

struct VulkanRender::Impl {
    Impl()  = default;
    ~Impl() = default;

    bool init(RenderInitInfo);
    bool initDevice(const RenderInitInfo& info);
    bool initPresentation(const RenderInitInfo& info);
    bool releasePresentation();
    void destroy();

    bool drawFrame(Scene&, bool* presented);
    VkResult quiesceFrame(bool wait_for_presentation = false);
    VkResult resetRecordings();
    bool failFrame(VkResult result);

    bool CreateRenderingResource(RenderingResources&);
    void DestroyRenderingResource(RenderingResources&);

    bool clearLastRenderGraph();
    bool compileRenderGraph(Scene&, rg::RenderGraph&);
    /// Resizes the scene's render targets to a new internal render scale and
    /// re-prepares the existing passes in place. Deliberately narrower than
    /// `compileRenderGraph`: the render graph, the parsed scene, uploaded
    /// images and live video decoders all survive, so changing quality does not
    /// restart the wallpaper.
    bool applyRenderScale(Scene&, rg::RenderGraph&, double scale);
    bool preparePasses(Scene&);
    /// Decides copy elimination and which targets may retain their pixels.
    /// Runs once per compiled graph, never per frame.
    bool applySceneOptimization(Scene&, rg::RenderGraph&);
    /// Aggregates every pass's reflection-derived dynamic inputs, plus
    /// `Feedback` when the graph carries a target into the next frame. Runs
    /// whether or not pixel reuse is enabled, because on-demand updating asks
    /// the same question for a different purpose.
    void computeShaderDynamicReasons(Scene&);
    /// Gives every pinned target back to the reuse pool.
    void releaseStaticCache();
    /// Waits for submitted work before prepared pass state is destroyed.
    /// A no-op while no graph is loaded, which is the compile path.
    bool quiesceForPassRebuild();
    /// Per frame: samples the varying inputs and marks reusable passes.
    void planStaticSkips(Scene&);
    /// Whether this frame, as prepared, would put back exactly the picture the
    /// last present left on the surface. Fills `m_present_key` and
    /// `m_present_videos` for the record a presented frame leaves.
    bool frameRepeatsLastPresent(const Scene&);
    /// True when nothing but the final composition would record work: every
    /// other pass was reused by the static plan or draws nothing this frame.
    bool frameRecordsOnlyComposition() const;
    void UpdateCameraFillMode(Scene&, wallpaper::FillMode);
    void SetWallpaperScalingMode(wallpaper::WallpaperScalingMode);
    void SetWallpaperScalingFactor(double);
    void SetWallpaperFraming(const wallpaper::WallpaperFraming&);
    void SetWallpaperHorizontalFlip(bool);

    bool initRes();
    VkResult executePreparedPasses(RenderingResources&);
    bool drawFrameSwapchain();
    bool drawFrameOffscreen();
    void setRenderTargetSize(Scene&, rg::RenderGraph&);
    void updateScalingLayout(const Scene&, uint32_t output_width, uint32_t output_height);
    WallpaperScalingLayout computeScalingLayout(const Scene&, uint32_t output_width,
                                                uint32_t output_height) const;
    WallpaperCursorMapping CursorMapping(const Scene&) const;

    Instance                m_instance;
    std::unique_ptr<Device> m_device;

    std::unique_ptr<PrePass> m_prepass { nullptr };
    std::unique_ptr<FinPass> m_finpass { nullptr };
    CustomShaderPass* m_direct_present_pass { nullptr };

    std::unique_ptr<FinPass> m_testpass { nullptr };
    ReDrawCB                 m_redraw_cb;
    std::function<bool()> m_wants_poster;
    std::function<void(std::span<const uint8_t>, uint32_t, uint32_t, bool)> m_poster_ready;
    std::function<bool()> m_poster_pending;
    std::function<void(uint64_t, double)> m_video_frame_presented;
    /// PTS of each entry in `m_present_videos`, in the same order.
    std::vector<double>              m_present_pts;

    std::unique_ptr<StagingBuffer> m_vertex_buf { nullptr };
    std::unique_ptr<StagingBuffer> m_dyn_buf { nullptr };

    vvk::CommandBuffers m_cmds;
    vvk::CommandBuffer  m_upload_cmd;
    vvk::CommandBuffer  m_render_cmd;

    bool m_with_surface { false };
    bool m_inited { false };
    bool m_pass_loaded { false };
    bool m_frame_faulted { false };
    bool m_device_lost { false };
    bool m_draw_submitted { false };
    bool m_static_upload_submitted { false };
    bool m_draw_recording { false };
    bool m_static_upload_recording { false };
    bool m_destroying { false };
    VmaBufferParameters m_frame_poster;
    PosterTarget        m_frame_poster_target;

    std::unique_ptr<VulkanExSwapchain>    m_ex_swapchain;
    RenderingResources                    m_rendering_resources;
    WallpaperScalingLayout                m_scaling_layout {};
    WallpaperScalingMode                  m_scaling_mode { WallpaperScalingMode::FIT };
    double                                m_scaling_factor { 1.0 };
    wallpaper::WallpaperFraming           m_framing {};
    bool                                  m_horizontal_flip { false };
    double                                m_display_scale_factor { 1.0 };
    VkExtent2D                            m_requested_render_extent {};

    // Exported dma_fence sync_file fd for the most recently completed
    // offscreen frame. Written by drawFrameOffscreen(), consumed by
    // takeLastFrameSyncFd() (called from the host's redraw callback).
    // -1 means no frame has been exported yet. Ownership: the taker.
    std::atomic<int> m_last_sync_fd { -1 };

    std::vector<VulkanPass*> m_passes;
    CustomPassExecutionScratch m_pass_scratch;
    StaticSubgraphCache m_static_cache;
    std::vector<StaticPassSample> m_static_samples;
    std::vector<uint8_t> m_static_skip;
    /// Union of every pass's reflection-derived dynamic inputs for the compiled
    /// graph, plus its history loops. `UnknownInput` until a graph has been
    /// analysed, so a renderer that has not compiled anything never reports a
    /// scene as still.
    uint32_t m_shader_dynamic_reasons { static_cast<uint32_t>(DynamicReason::UnknownInput) };
    /// The pass list this frame actually records, with skipped clears and
    /// copies removed. Rebuilt in place so no allocation happens per frame.
    std::vector<VulkanPass*> m_frame_passes;
    /// Upper bound on what pinned render targets may occupy. Beyond it, a
    /// target keeps taking part in the reuse pool and simply re-renders, which
    /// costs GPU work rather than memory.
    uint64_t m_static_cache_budget_bytes { 192ULL * 1024ULL * 1024ULL };
    uint64_t m_static_pinned_bytes { 0 };
    /// The setting value the current copy plan and reuse table were built for.
    /// A change is applied at a frame boundary rather than at the next graph
    /// compile.
    bool     m_scene_optimization_applied { false };
    /// Owned by the scene that created this renderer; may be null in tests and
    /// standalone tools. Only read on the render thread.
    RendererCounters* m_counters { nullptr };
    /// The last frame that actually reached the surface, and scratch for the
    /// frame being decided. Reused, so a repeated frame allocates nothing.
    UnchangedPresentGate             m_present_gate;
    PresentationKey                  m_present_key;
    std::vector<PresentedVideoFrame> m_present_videos;
};

VulkanRender::VulkanRender(): pImpl(std::make_unique<Impl>()) {}
VulkanRender::~VulkanRender() { destroy(); }

bool VulkanRender::inited() const { return pImpl->m_inited; }

int VulkanRender::takeLastFrameSyncFd() {
    return pImpl->m_last_sync_fd.exchange(-1, std::memory_order_acq_rel);
}

bool VulkanRender::init(RenderInitInfo info) { return pImpl->init(info); }
void VulkanRender::destroy() { pImpl->destroy(); }
bool VulkanRender::releaseSurface() { return pImpl->releasePresentation(); }
bool VulkanRender::resetSurface(const RenderInitInfo& info) {
    if (! pImpl->releasePresentation()) return false;
    return pImpl->initPresentation(info);
}
bool VulkanRender::drawFrame(Scene& scene, bool* presented) {
    bool reached_surface = false;
    const bool drawn     = pImpl->drawFrame(scene, &reached_surface);
    if (presented != nullptr) *presented = drawn && reached_surface;
    return drawn;
}
void VulkanRender::InvalidatePresentedFrame() { pImpl->m_present_gate.Invalidate(); }
bool VulkanRender::clearLastRenderGraph() { return pImpl->clearLastRenderGraph(); }
bool VulkanRender::compileRenderGraph(Scene& scene, rg::RenderGraph& rg) {
    return pImpl->compileRenderGraph(scene, rg);
}
bool VulkanRender::ApplySceneOptimization(Scene& scene, rg::RenderGraph& rg) {
    return pImpl->applySceneOptimization(scene, rg);
}
bool VulkanRender::ApplyRenderScale(Scene& scene, rg::RenderGraph& rg, double scale) {
    return pImpl->applyRenderScale(scene, rg, scale);
}
void VulkanRender::UpdateCameraFillMode(Scene& scene, wallpaper::FillMode fill) {
    pImpl->UpdateCameraFillMode(scene, fill);
};
void VulkanRender::SetWallpaperScalingMode(wallpaper::WallpaperScalingMode mode) {
    pImpl->SetWallpaperScalingMode(mode);
}
void VulkanRender::SetWallpaperScalingFactor(double factor) {
    pImpl->SetWallpaperScalingFactor(factor);
}
void VulkanRender::SetWallpaperFraming(const wallpaper::WallpaperFraming& framing) {
    pImpl->SetWallpaperFraming(framing);
}
void VulkanRender::SetWallpaperHorizontalFlip(bool enabled) {
    pImpl->SetWallpaperHorizontalFlip(enabled);
}
void VulkanRender::SetPipelineCachePath(std::string path) {
    if (pImpl->m_device != nullptr) pImpl->m_device->UsePipelineCacheFile(std::move(path));
}
wallpaper::WallpaperCursorMapping VulkanRender::CursorMapping(const Scene& scene) const {
    return pImpl->CursorMapping(scene);
}
void VulkanRender::SetVideoPlaybackPaused(bool paused) {
    if (pImpl->m_device != nullptr) {
        pImpl->m_device->tex_cache().SetVideoPlaybackPaused(paused);
    }
}
void VulkanRender::SetVideoPlaybackRate(float rate) {
    if (pImpl->m_device != nullptr) {
        pImpl->m_device->tex_cache().SetVideoPlaybackRate(rate);
    }
}
double VulkanRender::ShortestVideoFramePeriod() const {
    if (pImpl->m_device == nullptr) return 0.0;
    return pImpl->m_device->tex_cache().ShortestVideoFramePeriod();
}
uint32_t VulkanRender::ShaderUpdateDemandReasons() const {
    return pImpl->m_shader_dynamic_reasons;
}
void VulkanRender::SetCounters(RendererCounters* counters) {
    pImpl->m_counters = counters;
    if (pImpl->m_device != nullptr) {
        pImpl->m_device->tex_cache().SetCounters(counters);
    }
}

wallpaper::ExSwapchain* VulkanRender::exSwapchain() const { return pImpl->m_ex_swapchain.get(); };

bool VulkanRender::Impl::init(RenderInitInfo info) {
    if (m_inited) return ! m_frame_faulted && ! m_device_lost;
    if (m_device || m_instance.inst()) destroy();
    if (! initDevice(info)) return false;
    if (! initPresentation(info)) return false;
    m_inited = true;
    return true;
}

bool VulkanRender::Impl::initDevice(const RenderInitInfo& info) {
    m_redraw_cb = info.redraw_callback;

    std::vector<Extension> inst_exts { base_inst_exts.begin(), base_inst_exts.end() };

    if (! info.offscreen) {
        std::transform(info.surface_info.instanceExts.begin(),
                       info.surface_info.instanceExts.end(),
                       std::back_inserter(inst_exts),
                       [](const auto& s) {
                           return Extension { true, s.c_str() };
                       });
    }

    std::vector<InstanceLayer> inst_layers;
    if (info.enable_valid_layer) {
        inst_layers.push_back({ true, VALIDATION_LAYER_NAME });
        LOG_INFO("vulkan valid layer \"%s\" enabled", VALIDATION_LAYER_NAME.data());
    }

    if (! Instance::Create(m_instance, inst_exts, inst_layers)) {
        LOG_ERROR("init vulkan failed");
        return false;
    }
    return true;
}

bool VulkanRender::Impl::initPresentation(const RenderInitInfo& info) {
    if (m_device_lost) return false;
    m_wants_poster   = info.wants_poster;
    m_poster_ready   = info.poster_ready;
    m_poster_pending = info.poster_pending;
    m_video_frame_presented = info.video_frame_presented;
    // A new surface has shown nothing of this renderer's yet.
    m_present_gate.Invalidate();
    // Presentation-scoped bookkeeping: these fields are re-read on every
    // surface reconfigure, so they must live here (not in initDevice) to
    // reflect the new display's geometry / scale on each reset.
    m_display_scale_factor    = NormalizeScaleFactor(info.display_scale_factor);
    m_requested_render_extent = { info.render_width, info.render_height };
    VkExtent2D extent { info.width, info.height };
    if (extent.width * extent.height < 500 * 500) {
        LOG_ERROR("too small swapchain image size: %dx%d", extent.width, extent.height);
    } else {
        LOG_INFO("set swapchain image size: %dx%d", extent.width, extent.height);
    }
    LOG_INFO("wallpaper render init: output_px=%ux%u requested_render_px=%ux%u display_scale=%.3f",
             extent.width,
             extent.height,
             m_requested_render_extent.width,
             m_requested_render_extent.height,
             m_display_scale_factor);

    std::vector<Extension> device_exts = BaseDeviceExtensions();

    if (! info.offscreen) {
        device_exts.push_back({ true, VK_KHR_SWAPCHAIN_EXTENSION_NAME });
    } else {
#if defined(__linux__)
        device_exts.push_back({ true, VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME });
        device_exts.push_back({ true, VK_EXT_IMAGE_DRM_FORMAT_MODIFIER_EXTENSION_NAME });
        device_exts.push_back({ true, VK_EXT_QUEUE_FAMILY_FOREIGN_EXTENSION_NAME });
#else
        LOG_ERROR("offscreen external-memory rendering is only supported on Linux");
        return false;
#endif
    }

    if (! info.offscreen) {
        VkSurfaceKHR surface;
        VVK_CHECK_ACT(
            {
                LOG_ERROR("create vulkan surface failed");
                return false;
            },
            info.surface_info.createSurfaceOp(*m_instance.inst(), &surface));
        m_instance.setSurface(VkSurfaceKHR(surface));
        m_with_surface = true;
    }

    if (! m_device) {
        {
            auto surface   = *m_instance.surface();
            auto check_gpu = [&device_exts, surface](const vvk::PhysicalDevice& gpu) {
                return Device::CheckGPU(gpu, device_exts, surface);
            };
            if (! m_instance.ChoosePhysicalDevice(check_gpu, info.uuid)) return false;
        }

        {
            m_device = std::make_unique<Device>();
            if (! Device::Create(m_instance, device_exts, extent, *m_device)) {
                LOG_ERROR("init vulkan device failed");
                return false;
            }
            // The texture cache owns the video sources, so it needs the same
            // counters the frame clock writes to.
            m_device->tex_cache().SetCounters(m_counters);
        }
    } else {
        // Device already exists — just recreate the swapchain.
        m_device->set_out_extent(extent);
        if (m_with_surface) {
            if (! m_device->recreateSwapchain(*m_instance.surface(), extent)) {
                LOG_ERROR("recreate swapchain failed");
                return false;
            }
        }
    }

    if (info.offscreen) {
        m_ex_swapchain = CreateExSwapchain(*m_device,
                                           extent.width,
                                           extent.height,
                                           (info.offscreen_tiling == TexTiling::OPTIMAL
                                                ? VK_IMAGE_TILING_OPTIMAL
                                                : VK_IMAGE_TILING_LINEAR));
        m_with_surface = false;
    }

    if (! initRes()) return false;
    m_frame_faulted = false;
    return true;
}

VkResult VulkanRender::Impl::resetRecordings() {
    if (m_draw_recording && ! m_draw_submitted) {
        const auto result = m_render_cmd ? m_render_cmd.Reset() : VK_SUCCESS;
        if (result != VK_SUCCESS) return result;
        m_device->tex_cache().AbandonVideoFrameRecording();
        if (m_dyn_buf) m_dyn_buf->finishUpload(false);
        m_draw_recording = false;
        m_frame_poster = {};
        m_frame_poster_target = {};
    }
    if (m_static_upload_recording && ! m_static_upload_submitted) {
        const auto result = m_upload_cmd ? m_upload_cmd.Reset() : VK_SUCCESS;
        if (result != VK_SUCCESS) return result;
        if (m_vertex_buf) m_vertex_buf->finishUpload(false);
        m_static_upload_recording = false;
    }
    return VK_SUCCESS;
}

VkResult VulkanRender::Impl::quiesceFrame(bool wait_for_presentation) {
    if (! m_device || ! m_device->handle()) return VK_SUCCESS;
    const auto discard_commands = [&]() {
        m_rendering_resources.command = {};
        m_render_cmd = {};
        m_upload_cmd = {};
        m_cmds = {};
    };
    const auto discard_lost_device = [&]() {
        m_frame_faulted = true;
        m_device_lost = true;
        if (m_destroying) discard_commands();
        m_device->tex_cache().DiscardAfterDeviceLoss();
        if (m_vertex_buf) m_vertex_buf->finishUpload(false);
        if (m_dyn_buf) m_dyn_buf->finishUpload(false);
        m_draw_submitted = false;
        m_static_upload_submitted = false;
        m_draw_recording = false;
        m_static_upload_recording = false;
        m_frame_poster = {};
        m_frame_poster_target = {};
        return VK_ERROR_DEVICE_LOST;
    };
    if (m_device_lost) return discard_lost_device();
    if (wait_for_presentation || m_draw_submitted || m_static_upload_submitted || m_frame_faulted) {
        const auto result = m_device->handle().WaitIdle();
        if (result == VK_ERROR_DEVICE_LOST) return discard_lost_device();
        if (result != VK_SUCCESS) {
            LOG_ERROR("renderer quiescence failed: %s", vvk::ToString(result));
            m_frame_faulted = true;
            m_device->tex_cache().InvalidateVideoDestinationPool();
            return result;
        }
    }
    if (m_destroying) {
        discard_commands();
    } else {
        const auto result = resetRecordings();
        if (result == VK_ERROR_DEVICE_LOST) return discard_lost_device();
        if (result != VK_SUCCESS) {
            LOG_ERROR("discard renderer recording failed: %s", vvk::ToString(result));
            m_frame_faulted = true;
            m_device->tex_cache().InvalidateVideoDestinationPool();
            return result;
        }
    }
    if (m_draw_submitted) {
        m_device->tex_cache().CompleteVideoFrame();
        if (m_dyn_buf) m_dyn_buf->finishUpload(true);
    } else if (m_draw_recording) {
        m_device->tex_cache().AbandonVideoFrameRecording();
        if (m_dyn_buf) m_dyn_buf->finishUpload(false);
    }
    if (m_static_upload_submitted) {
        if (m_vertex_buf) m_vertex_buf->finishUpload(true);
    } else if (m_static_upload_recording) {
        if (m_vertex_buf) m_vertex_buf->finishUpload(false);
    }
    m_draw_submitted = false;
    m_static_upload_submitted = false;
    m_draw_recording = false;
    m_static_upload_recording = false;
    m_frame_poster = {};
    m_frame_poster_target = {};
    return VK_SUCCESS;
}

bool VulkanRender::Impl::failFrame(VkResult result) {
    LOG_ERROR("renderer frame stopped: %s", vvk::ToString(result));
    m_frame_faulted = true;
    m_present_gate.Invalidate();
    m_device->tex_cache().InvalidateVideoDestinationPool();
    if (result == VK_ERROR_DEVICE_LOST) m_device_lost = true;
    if (m_device_lost || m_draw_submitted || m_static_upload_submitted) {
        const auto idle_result = quiesceFrame();
        if (idle_result != VK_SUCCESS && idle_result != VK_ERROR_DEVICE_LOST)
            LOG_ERROR("renderer retains unfinished frame resources");
    } else {
        const auto reset_result = resetRecordings();
        if (reset_result == VK_ERROR_DEVICE_LOST) {
            m_device_lost = true;
            const auto lost_result = quiesceFrame();
            if (lost_result != VK_ERROR_DEVICE_LOST)
                LOG_ERROR("renderer device-loss cleanup failed");
        } else if (reset_result != VK_SUCCESS) {
            LOG_ERROR("renderer retains failed command recording: %s", vvk::ToString(reset_result));
        }
    }
    return false;
}

bool VulkanRender::Impl::releasePresentation() {
    if (quiesceFrame(true) != VK_SUCCESS) return false;
    m_direct_present_pass = nullptr;
    m_present_gate.Invalidate();
    if (m_device && m_device->handle()) {
        std::string error;
        if (! m_device->tex_cache().WaitForPendingUploads(&error)) {
            LOG_ERROR("cannot release presentation uploads: %s", error.c_str());
            return failFrame(VK_ERROR_UNKNOWN);
        }
        for (auto* command : { &m_render_cmd, &m_upload_cmd }) {
            if (*command) {
                const auto result = command->Reset();
                if (result != VK_SUCCESS) return failFrame(result);
            }
        }
        releaseStaticCache();
        for (auto* pass : m_passes) {
            if (pass != nullptr) pass->destory(*m_device, m_rendering_resources);
        }
        m_passes.clear();
        m_pass_scratch.passes.clear();
        m_pass_scratch.candidates.clear();
        m_pass_scratch.plan.entries.clear();
        if (! m_device->tex_cache().Clear(&error)) {
            LOG_ERROR("cannot clear presentation cache: %s", error.c_str());
            return failFrame(VK_ERROR_UNKNOWN);
        }
    }
    m_pass_loaded = false;
    DestroyRenderingResource(m_rendering_resources);
    m_finpass.reset();
    m_prepass.reset();
    m_ex_swapchain.reset();
    if (m_device) m_device->releaseSwapchain();
    m_instance.releaseSurface();
    m_with_surface = false;
    return true;
}

bool VulkanRender::Impl::initRes() {
    // Presentation-scoped: always recreated.
    m_prepass = std::make_unique<PrePass>(PrePass::Desc {});
    m_finpass = std::make_unique<FinPass>(FinPass::Desc {});
    if (m_with_surface) {
        m_finpass->setPresentFormat(m_device->swapchain().format());
        m_finpass->setPresentQueueIndex(m_device->present_queue().family_index);
        m_finpass->setPresentLayout(VK_IMAGE_LAYOUT_PRESENT_SRC_KHR);
    } else {
        m_finpass->setPresentFormat(m_ex_swapchain->format());
        m_finpass->setPresentLayout(VK_IMAGE_LAYOUT_GENERAL);
        m_finpass->setPresentQueueIndex(VK_QUEUE_FAMILY_EXTERNAL);
    }

    // Device-scoped: only allocated on first call.
    if (!m_vertex_buf) {
        m_vertex_buf = std::make_unique<StagingBuffer>(*m_device,
                                                       2 * 1024 * 1024,
                                                       VK_BUFFER_USAGE_VERTEX_BUFFER_BIT |
                                                           VK_BUFFER_USAGE_INDEX_BUFFER_BIT);
        m_dyn_buf    = std::make_unique<StagingBuffer>(*m_device,
                                                    2 * 1024 * 1024,
                                                    VK_BUFFER_USAGE_VERTEX_BUFFER_BIT |
                                                        VK_BUFFER_USAGE_INDEX_BUFFER_BIT |
                                                        VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT);
        if (! m_vertex_buf->allocate()) return false;
        if (! m_dyn_buf->allocate()) return false;
    }
    if (m_cmds.data() == nullptr) {
        const auto result = m_device->cmd_pool().Allocate(
            vk_command_num, VK_COMMAND_BUFFER_LEVEL_PRIMARY, m_cmds);
        if (result != VK_SUCCESS) return failFrame(result);
        m_upload_cmd = vvk::CommandBuffer(m_cmds[0], m_device->handle().Dispatch());
        m_render_cmd = vvk::CommandBuffer(m_cmds[1], m_device->handle().Dispatch());
    }
    if (! CreateRenderingResource(m_rendering_resources)) return false;

#if ENABLE_RENDERDOC_API
    load_renderdoc_api();
#endif
    return true;
}

void VulkanRender::Impl::destroy() {
    m_destroying = true;
    m_direct_present_pass = nullptr;
    m_present_gate.Invalidate();
    const auto result = quiesceFrame(true);
    if (result != VK_SUCCESS && result != VK_ERROR_DEVICE_LOST) {
        LOG_ERROR("cannot destroy renderer resources before GPU completion");
        std::terminate();
    }
    if (m_device && m_device->handle()) {
        if (! m_device_lost) {
            std::string error;
            if (! m_device->tex_cache().WaitForPendingUploads(&error)) {
                LOG_ERROR("texture upload retirement failed during renderer destruction: %s",
                          error.c_str());
                // The cache destructor checks its remaining slots against device idle.
            }
        }
        releaseStaticCache();
        for (auto* pass : m_passes) {
            if (pass != nullptr) pass->destory(*m_device, m_rendering_resources);
        }
    }
    m_passes.clear();
    m_pass_scratch.passes.clear();
    m_pass_scratch.candidates.clear();
    m_pass_scratch.plan.entries.clear();
    m_prepass.reset();
    m_finpass.reset();
    m_testpass.reset();
    m_ex_swapchain.reset();
    DestroyRenderingResource(m_rendering_resources);
    m_render_cmd = {};
    m_upload_cmd = {};
    m_cmds = {};
    m_frame_poster = {};
    m_frame_poster_target = {};
    m_vertex_buf.reset();
    m_dyn_buf.reset();
    m_device.reset();
    m_instance.Destroy();
    const int fd = m_last_sync_fd.exchange(-1, std::memory_order_acq_rel);
    if (fd >= 0) ::close(fd);
    m_pass_loaded = false;
    m_inited = false;
    m_with_surface = false;
    m_frame_faulted = false;
    m_device_lost = false;
    m_destroying = false;
}

bool VulkanRender::Impl::CreateRenderingResource(RenderingResources& rr) {
    rr.command = m_render_cmd;
    rr.vertex_buf = m_vertex_buf.get();
    rr.dyn_buf = m_dyn_buf.get();
    const auto fence_result = m_device->handle().CreateFence(
        VkFenceCreateInfo { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO },
        rr.fence_frame);
    if (fence_result != VK_SUCCESS) return failFrame(fence_result);
    VkSemaphoreCreateInfo semaphore { .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
    if (m_with_surface) {
        auto result = m_device->handle().CreateSemaphore(semaphore, rr.sem_swap_finish);
        if (result != VK_SUCCESS) return failFrame(result);
        result = m_device->handle().CreateSemaphore(semaphore, rr.sem_swap_wait_image);
        if (result != VK_SUCCESS) return failFrame(result);
    }
    // Only offscreen Linux rendering exports SYNC_FD.
    VkExportSemaphoreCreateInfo export_info {
        .sType = VK_STRUCTURE_TYPE_EXPORT_SEMAPHORE_CREATE_INFO,
        .handleTypes = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT_KHR,
    };
    if (! m_with_surface) semaphore.pNext = &export_info;
    const auto export_result = m_device->handle().CreateSemaphore(semaphore, rr.sem_export);
    if (export_result != VK_SUCCESS) return failFrame(export_result);
    return true;
}

void VulkanRender::Impl::DestroyRenderingResource(RenderingResources& rr) {
    rr.command = {};
    rr.fence_frame.reset();
    rr.sem_swap_wait_image.reset();
    rr.sem_swap_finish.reset();
    rr.sem_export.reset();
    rr.vertex_buf = nullptr;
    rr.dyn_buf = nullptr;
}

// VulkanExSwapchain* VulkanRender::exSwapchain() const { return m_ex_swapchain.get(); }

bool VulkanRender::Impl::drawFrame(Scene& scene, bool* presented) {
    *presented = false;
    if (! m_inited || ! m_pass_loaded || m_frame_faulted || m_device_lost) return false;
    if (quiesceFrame() != VK_SUCCESS) return false;

    m_device->tex_cache().CollectCompletedUploads();

    const auto output_extent = m_device->out_extent();
    updateScalingLayout(
        scene, std::max(1u, output_extent.width), std::max(1u, output_extent.height));
    m_rendering_resources.wallpaper_viewport = MakeWallpaperViewport(m_scaling_layout);
    m_rendering_resources.wallpaper_scissor  = MakeWallpaperScissor(m_scaling_layout);
    m_rendering_resources.wallpaper_horizontal_flip = m_horizontal_flip;

    std::string error;
    if (! m_device->tex_cache().BeginVideoFrameRecording(&error)) {
        LOG_ERROR("cannot begin video frame recording: %s", error.c_str());
        return failFrame(VK_ERROR_UNKNOWN);
    }
    m_draw_recording = true;
    // Decided before the update so a reusable pass also skips re-uploading
    // uniforms nothing will read this frame.
    planStaticSkips(scene);
    if (! UpdatePreparedPasses(*m_device, m_rendering_resources, m_passes))
        return failFrame(VK_ERROR_UNKNOWN);

    // After the update, so the video clock, frame promotion, sprite steps and
    // uniform writes all ran exactly as they would for a drawn frame; before
    // the acquire, so a repeat never takes a drawable it would not present.
    if (! m_instance.offscreen() && frameRepeatsLastPresent(scene)) {
        // Nothing was recorded, so the frame's video pins are released without
        // a submission and the surface keeps the picture it already shows.
        m_device->tex_cache().AbandonVideoFrameRecording();
        m_draw_recording = false;
        if (m_counters != nullptr) m_counters->Add(OWE_RC_PRESENTS_SKIPPED_UNCHANGED);
        return true;
    }

#if ENABLE_RENDERDOC_API
    if (rdoc_api)
        rdoc_api->StartFrameCapture(
            RENDERDOC_DEVICEPOINTER_FROM_VKINSTANCE((VkInstance)m_instance.inst()), NULL);
#endif

    const bool rendered = m_instance.offscreen() ? drawFrameOffscreen() : drawFrameSwapchain();
    *presented = rendered;
    if (rendered && m_redraw_cb) m_redraw_cb();

#if ENABLE_RENDERDOC_API
    if (rdoc_api)
        rdoc_api->EndFrameCapture(
            RENDERDOC_DEVICEPOINTER_FROM_VKINSTANCE((VkInstance)m_instance.inst()), NULL);
#endif
    return rendered;
}

VkResult VulkanRender::Impl::executePreparedPasses(RenderingResources& rr) {
    // `m_frame_passes` drops clears and copies whose target is reusing last
    // frame's pixels. Custom passes stay so batching still sees the same
    // neighbours; they report themselves invisible instead.
    const auto passes = m_frame_passes.empty()
                            ? std::span<VulkanPass* const> { m_passes }
                            : std::span<VulkanPass* const> { m_frame_passes };
    return ExecutePreparedPasses(*m_device, rr, passes, m_pass_scratch, m_passes);
}

bool VulkanRender::Impl::drawFrameSwapchain() {

    RenderingResources& rr = m_rendering_resources;
    uint32_t image_index   = 0;
    const auto acquire_result = m_device->handle().AcquireNextImageKHR(
        *m_device->swapchain().handle(), vk_wait_time, *rr.sem_swap_wait_image, {}, &image_index);
    if (acquire_result != VK_SUCCESS && acquire_result != VK_SUBOPTIMAL_KHR)
        return failFrame(acquire_result);
    const auto& image = m_device->swapchain().images()[image_index];

    m_finpass->setPresent(image);

    // Read back only on a host request, after the final scaling/cropping pass.
    // Never inspect another window or the desktop compositor's contents.
    auto& poster = m_frame_poster;
    const auto format = m_device->swapchain().format();
    const bool bgra = format == VK_FORMAT_B8G8R8A8_UNORM || format == VK_FORMAT_B8G8R8A8_SRGB;
    const bool rgba = format == VK_FORMAT_R8G8B8A8_UNORM || format == VK_FORMAT_R8G8B8A8_SRGB;
    const size_t poster_size = size_t(image.extent.width) * image.extent.height * 4;
    const bool present_directly =
        m_direct_present_pass != nullptr &&
        m_direct_present_pass->canPresentDirectly(
            rr, { image.extent.width, image.extent.height }, format);
    const bool export_poster = m_poster_ready && m_wants_poster && (bgra || rgba) &&
        m_device->graphics_queue().family_index == m_device->present_queue().family_index &&
        poster_size <= kPosterByteLimit && m_wants_poster();
    // The poster is composed a second time, into an image of its own, by the
    // very pass that composes the drawable: the drawable is never read.
    const VkRenderPass poster_pass = ! export_poster ? VK_NULL_HANDLE
                                     : present_directly
                                         ? m_direct_present_pass->presentationCopySourcePass()
                                         : m_finpass->copySourcePass();
    if (export_poster &&
        (! CreatePosterTarget(*m_device, format, image.extent, poster_pass, m_frame_poster_target) ||
         ! CreateReadbackBuffer(m_device->vma_allocator(), poster_size, poster)))
        return failFrame(VK_ERROR_OUT_OF_DEVICE_MEMORY);

    const auto begin_result = rr.command.Begin(VkCommandBufferBeginInfo {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = nullptr,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    });
    if (begin_result != VK_SUCCESS) return failFrame(begin_result);
    // Imported video images never sampled before get their layout transition
    // here, inside the frame, instead of in a submission of their own.
    m_device->tex_cache().RecordVideoFirstUseTransitions(rr.command);
    if (! m_dyn_buf->recordUpload(rr.command)) return failFrame(VK_ERROR_UNKNOWN);
    VkResult execute_result = VK_SUCCESS;
    if (present_directly) {
        execute_result = m_direct_present_pass->executePresentation(*m_device, rr, image, format);
        if (execute_result == VK_SUCCESS) {
            // The pass drew into the drawable, not into the scene's output
            // target, so that target does not hold the pixels the reuse plan
            // just recorded for it. A later frame that reuses it through the
            // final blit would otherwise compose an image nobody drew.
            m_static_cache.InvalidateAll();
            VkImageMemoryBarrier barrier {
                .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                .srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
                .dstAccessMask = 0,
                .oldLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                .newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
                .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                .image = image.handle,
                .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 },
            };
            rr.command.PipelineBarrier(VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                                       VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, barrier);
        }
    } else {
        execute_result = executePreparedPasses(rr);
    }
    if (execute_result != VK_SUCCESS) return failFrame(execute_result);
    if (export_poster) {
        auto& target = m_frame_poster_target;
        const VkExtent2D extent { image.extent.width, image.extent.height };
        const auto composed =
            present_directly
                ? m_direct_present_pass->recordPresentation(*m_device, rr, poster_pass,
                                                            *target.framebuffer, extent)
                : m_finpass->recordComposition(rr, poster_pass, *target.framebuffer, extent);
        if (composed != VK_SUCCESS) return failFrame(composed);
        // The render pass left the image laid out to be copied from; the copy
        // still has to wait for its writes.
        VkImageMemoryBarrier written {
            .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT,
            .oldLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            .newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .image = *target.image.handle,
            .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 },
        };
        rr.command.PipelineBarrier(VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                                   VK_PIPELINE_STAGE_TRANSFER_BIT, 0, written);
        VkBufferImageCopy region {
            .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 },
            .imageExtent = image.extent,
        };
        rr.command.CopyImageToBuffer(*target.image.handle, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                                     *poster.handle, spanone { region });
        VkBufferMemoryBarrier host_barrier {
            .sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
            .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
            .dstAccessMask = VK_ACCESS_HOST_READ_BIT,
            .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .buffer = *poster.handle,
            .offset = 0,
            .size = VK_WHOLE_SIZE,
        };
        rr.command.PipelineBarrier(VK_PIPELINE_STAGE_TRANSFER_BIT,
                                   VK_PIPELINE_STAGE_HOST_BIT, 0, host_barrier);
    }
    const auto end_result = rr.command.End();
    if (end_result != VK_SUCCESS) return failFrame(end_result);

    VkPipelineStageFlags wait_dst_stage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    VkSubmitInfo         sub_info {
                .sType                = VK_STRUCTURE_TYPE_SUBMIT_INFO,
                .pNext                = nullptr,
                .waitSemaphoreCount   = 1,
                .pWaitSemaphores      = rr.sem_swap_wait_image.address(),
                .pWaitDstStageMask    = &wait_dst_stage,
                .commandBufferCount   = 1,
                .pCommandBuffers      = rr.command.address(),
                .signalSemaphoreCount = 1,
                .pSignalSemaphores    = rr.sem_swap_finish.address(),
    };

    const auto submit_result = m_device->graphics_queue().handle.Submit(sub_info, *rr.fence_frame);
    if (submit_result != VK_SUCCESS) return failFrame(submit_result);
    m_draw_submitted = true;
    if (m_counters != nullptr) m_counters->Add(OWE_RC_RENDER_SUBMISSIONS);
    m_device->tex_cache().MarkVideoFrameSubmitted();
    VkPresentInfoKHR present_info {
        .sType              = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
        .pNext              = nullptr,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores    = rr.sem_swap_finish.address(),
        .swapchainCount     = 1,
        .pSwapchains        = m_device->swapchain().handle().address(),
        .pImageIndices      = &image_index,
    };
    // Even an out-of-date surface must finish the submitted copy before its
    // temporary readback buffer is destroyed.
    if (m_counters != nullptr) m_counters->Add(OWE_RC_PRESENT_REQUESTS);
    const auto present_result = m_device->present_queue().handle.Present(present_info);
    const auto wait_result = rr.fence_frame.Wait(vk_wait_time);
    if (wait_result != VK_SUCCESS) return failFrame(wait_result);
    // Fence signalled: the GPU finished the frame. Whether the compositor ever
    // put it on a display is not observable through this backend, so no counter
    // claims it.
    if (m_counters != nullptr) m_counters->Add(OWE_RC_GPU_COMPLETIONS);
    m_device->tex_cache().CompleteVideoFrame();
    m_dyn_buf->finishUpload(true);
    m_draw_submitted = false;
    m_draw_recording = false;
    if (present_result != VK_SUCCESS && present_result != VK_SUBOPTIMAL_KHR)
        return failFrame(present_result);
    if (m_video_frame_presented) {
        for (std::size_t i = 0; i < m_present_videos.size(); ++i) {
            if (m_present_videos[i].frame == nullptr) continue;
            m_video_frame_presented(m_present_videos[i].generation, m_present_pts[i]);
        }
    }
    const auto reset_result = rr.fence_frame.Reset();
    if (reset_result != VK_SUCCESS) return failFrame(reset_result);
    // The surface now shows what this frame drew. Only a clean acquire and
    // present leaves a record a later frame may repeat: a suboptimal surface
    // keeps presenting until it is rebuilt, and with scene optimisation off
    // nothing is remembered, so turning it back on starts from a real present.
    if (SceneOptimizationEnabled() && acquire_result == VK_SUCCESS && present_result == VK_SUCCESS)
        m_present_gate.Record(m_present_key, m_present_videos);
    else
        m_present_gate.Invalidate();
    if (export_poster) {
        void* bytes = nullptr;
        const auto map_result = poster.handle.MapMemory(&bytes);
        if (map_result != VK_SUCCESS) return failFrame(map_result);
        const auto invalidate_result = vmaInvalidateAllocation(
            m_device->vma_allocator(), poster.handle.Allocation(), 0, VK_WHOLE_SIZE);
        if (invalidate_result == VK_SUCCESS) {
            m_poster_ready({ static_cast<const uint8_t*>(bytes), poster_size },
                           image.extent.width, image.extent.height, bgra);
        }
        poster.handle.UnMapMemory();
        if (invalidate_result != VK_SUCCESS) return failFrame(invalidate_result);
    }
    m_frame_poster = {};
    m_frame_poster_target = {};
    return true;
}
bool VulkanRender::Impl::drawFrameOffscreen() {
    RenderingResources& rr    = m_rendering_resources;
    ImageParameters     image = m_ex_swapchain->GetInprogressImage();

    m_finpass->setPresent(image);

    const auto begin_result = rr.command.Begin(VkCommandBufferBeginInfo {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = nullptr,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    });
    if (begin_result != VK_SUCCESS) return failFrame(begin_result);
    m_device->tex_cache().RecordVideoFirstUseTransitions(rr.command);
    if (! m_dyn_buf->recordUpload(rr.command)) return failFrame(VK_ERROR_UNKNOWN);
    const auto execute_result = executePreparedPasses(rr);
    if (execute_result != VK_SUCCESS) return failFrame(execute_result);

    const auto end_result = rr.command.End();
    if (end_result != VK_SUCCESS) return failFrame(end_result);

    VkSubmitInfo sub_info {
        .sType                = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .pNext                = nullptr,
        .commandBufferCount   = 1,
        .pCommandBuffers      = rr.command.address(),
        .signalSemaphoreCount = 1,
        .pSignalSemaphores    = rr.sem_export.address(),
    };
    const auto submit_result = m_device->graphics_queue().handle.Submit(sub_info, *rr.fence_frame);
    if (submit_result != VK_SUCCESS) return failFrame(submit_result);
    m_draw_submitted = true;
    if (m_counters != nullptr) m_counters->Add(OWE_RC_RENDER_SUBMISSIONS);
    m_device->tex_cache().MarkVideoFrameSubmitted();
    const auto wait_result = rr.fence_frame.Wait(vk_wait_time);
    if (wait_result != VK_SUCCESS) return failFrame(wait_result);
    // Offscreen frames are handed to the host, never presented by this
    // process, so there is no present request to count here.
    if (m_counters != nullptr) m_counters->Add(OWE_RC_GPU_COMPLETIONS);
    m_device->tex_cache().CompleteVideoFrame();
    m_dyn_buf->finishUpload(true);
    m_draw_submitted = false;
    m_draw_recording = false;
    const auto reset_result = rr.fence_frame.Reset();
    if (reset_result != VK_SUCCESS) return failFrame(reset_result);

    // Export the signaled semaphore as a dma_fence sync_file fd. The
    // export resets the semaphore's payload, so the next submit can
    // signal it again. Stored in an atomic slot that the host reads in
    // send_frame_ready_locked via takeLastFrameSyncFd().
    {
        int                     fd = -1;
        VkSemaphoreGetFdInfoKHR gi {
            .sType      = VK_STRUCTURE_TYPE_SEMAPHORE_GET_FD_INFO_KHR,
            .pNext      = nullptr,
            .semaphore  = *rr.sem_export,
            .handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT_KHR,
        };
        const auto export_result = m_device->handle().GetSemaphoreFdKHR(gi, &fd);
        if (export_result != VK_SUCCESS) return failFrame(export_result);
        if (fd < 0) return failFrame(VK_ERROR_INVALID_EXTERNAL_HANDLE);
        int old = m_last_sync_fd.exchange(fd, std::memory_order_acq_rel);
        if (old >= 0) ::close(old);
    }

    m_ex_swapchain->renderFrame();
    return true;
}

void VulkanRender::Impl::setRenderTargetSize(Scene& scene, rg::RenderGraph& rg) {
    auto&      ext     = m_device->out_extent();
    const auto extents = ResolveScreenBoundRenderTargetSizes(scene, ext);
    const auto render_scale = ResolveSceneRenderScale(scene);
    for (auto& item : scene.renderTargets) {
        auto& rt = item.second;
        if (item.first == wallpaper::SpecTex_Default) continue;
        if (rt.bind.screen && rt.bind.enable) continue;
        if (! rt.bind.enable) {
            // Targets the author sized directly: effect ping-pong buffers and
            // the engine's fixed-fraction scratch buffers. They are internal
            // raster, so they follow the render scale from their authored size.
            ResolveRenderScaledSize(rt, render_scale);
            continue;
        }
        auto bind_rt = scene.renderTargets.find(rt.bind.name);
        if (rt.bind.name.empty() || bind_rt == scene.renderTargets.end()) {
            LOG_ERROR("unknonw render target bind: %s", rt.bind.name.c_str());
            continue;
        }
        // Relative to another target, which has already been scaled.
        rt.width  = (i32)(rt.bind.scale * bind_rt->second.width);
        rt.height = (i32)(rt.bind.scale * bind_rt->second.height);
    }
    for (auto& item : scene.renderTargets) {
        auto& rt = item.second;
        if (! item.first.empty() && (rt.width * rt.height <= 4)) {
            LOG_ERROR("wrong size for render target: %s", item.first.c_str());
        } else if (rt.has_mipmap) {
            rt.mipmap_level =
                std::max(3u,
                         static_cast<uint>(std::floor(std::log2(std::min(rt.width, rt.height))))) -
                2u;
        }
    }
    // Screen-space shader inputs describe the buffer actually being rasterized,
    // so a half-scale raster must report half-scale texels; otherwise every
    // neighbour-tap effect samples at the wrong step. Presentation layout and
    // cursor mapping deliberately use the authored extent instead.
    scene.shaderValueUpdater->SetScreenSize(static_cast<i32>(extents.raster.width),
                                            static_cast<i32>(extents.raster.height));
    scene.shaderValueUpdater->SetTexelSize(
        1.0f / static_cast<float>(std::max(1u, extents.raster.width)),
        1.0f / static_cast<float>(std::max(1u, extents.raster.height)));
}

wallpaper::WallpaperScalingLayout
VulkanRender::Impl::computeScalingLayout(const Scene& scene, uint32_t output_width,
                                         uint32_t output_height) const {
    const double scale_factor  = NormalizeScaleFactor(m_display_scale_factor);
    const auto   source_extent = ResolveSceneSourceExtent(
        scene, { std::max(1u, output_width), std::max(1u, output_height) });
    const uint32_t logical_width = std::max(
        1u, static_cast<uint32_t>(std::lround(static_cast<double>(output_width) / scale_factor)));
    const uint32_t logical_height = std::max(
        1u, static_cast<uint32_t>(std::lround(static_cast<double>(output_height) / scale_factor)));

    return ComputeWallpaperScalingLayout(m_scaling_mode,
                                         source_extent.width,
                                         source_extent.height,
                                         logical_width,
                                         logical_height,
                                         scale_factor,
                                         m_scaling_factor,
                                         m_framing.pan_x,
                                         m_framing.pan_y);
}

void VulkanRender::Impl::updateScalingLayout(const Scene& scene, uint32_t output_width,
                                             uint32_t output_height) {
    m_scaling_layout = computeScalingLayout(scene, output_width, output_height);
}

wallpaper::WallpaperCursorMapping VulkanRender::Impl::CursorMapping(const Scene& scene) const {
    if (! m_inited || m_device == nullptr) return {};
    const auto extent = m_device->out_extent();
    if (extent.width == 0 || extent.height == 0) return {};

    const auto camera = scene.cameras.find("global");
    if (camera == scene.cameras.end() || camera->second == nullptr) return {};

    const auto position = camera->second->GetPosition();
    return ComputeWallpaperCursorMapping(computeScalingLayout(scene, extent.width, extent.height),
                                         position.x(),
                                         position.y(),
                                         camera->second->VisibleWidth(),
                                         camera->second->VisibleHeight());
}

void VulkanRender::Impl::UpdateCameraFillMode(wallpaper::Scene&   scene,
                                              wallpaper::FillMode fillmode) {
    ApplyCameraFillMode(
        scene, fillmode, m_device->out_extent().width, m_device->out_extent().height);
    // The camera moved; what the scene draws changes without any video frame
    // or layout value this renderer compares.
    m_present_gate.Invalidate();
}

void VulkanRender::Impl::SetWallpaperScalingMode(wallpaper::WallpaperScalingMode mode) {
    m_scaling_mode = mode;
    m_present_gate.Invalidate();
    LOG_INFO("wallpaper scaling mode: %s", WallpaperScalingModeName(m_scaling_mode));
}

void VulkanRender::Impl::SetWallpaperScalingFactor(double factor) {
    m_scaling_factor = NormalizeScaleFactor(factor);
    m_present_gate.Invalidate();
    LOG_INFO("wallpaper scaling factor: %.3f", m_scaling_factor);
}

void VulkanRender::Impl::SetWallpaperFraming(const wallpaper::WallpaperFraming& framing) {
    // No log line: a drag on a position control sets this many times a second,
    // which would flood the log.
    m_framing = NormalizeWallpaperFraming(framing);
    m_present_gate.Invalidate();
}

void VulkanRender::Impl::SetWallpaperHorizontalFlip(bool enabled) {
    m_horizontal_flip = enabled;
    m_present_gate.Invalidate();
    LOG_INFO("wallpaper horizontal flip: %s", m_horizontal_flip ? "enabled" : "disabled");
}

bool VulkanRender::Impl::clearLastRenderGraph() {
    if (quiesceFrame() != VK_SUCCESS) return false;
    m_direct_present_pass = nullptr;
    m_present_gate.Invalidate();
    if (! m_device || ! m_device->handle()) return m_passes.empty();
    std::string error;
    if (! m_device->tex_cache().WaitForPendingUploads(&error)) {
        LOG_ERROR("cannot clear render graph uploads: %s", error.c_str());
        return failFrame(VK_ERROR_UNKNOWN);
    }
    for (auto* command : { &m_render_cmd, &m_upload_cmd }) {
        if (*command) {
            const auto result = command->Reset();
            if (result != VK_SUCCESS) return failFrame(result);
        }
    }
    releaseStaticCache();
    for (auto* pass : m_passes) {
        if (pass != nullptr) pass->destory(*m_device, m_rendering_resources);
    }
    m_passes.clear();
    m_pass_scratch.passes.clear();
    m_pass_scratch.candidates.clear();
    m_pass_scratch.plan.entries.clear();
    m_pass_loaded = false;
    if (! m_device->tex_cache().Clear(&error)) {
        LOG_ERROR("cannot clear render graph cache: %s", error.c_str());
        return failFrame(VK_ERROR_UNKNOWN);
    }
    if (! m_vertex_buf || ! m_dyn_buf) return false;
    m_vertex_buf->destroy();
    m_dyn_buf->destroy();
    const bool vertex_allocated = m_vertex_buf->allocate();
    const bool dynamic_allocated = m_dyn_buf->allocate();
    return vertex_allocated && dynamic_allocated;
}

bool VulkanRender::Impl::compileRenderGraph(Scene& scene, rg::RenderGraph& rg) {
    if (! m_inited || m_device_lost || m_frame_faulted) return false;
    if (! m_passes.empty() && ! clearLastRenderGraph()) return false;
    m_direct_present_pass = nullptr;
    if (quiesceFrame() != VK_SUCCESS) return false;
    std::string error;
    if (! m_device->tex_cache().WaitForPendingUploads(&error)) {
        LOG_ERROR("cannot compile render graph with pending uploads: %s", error.c_str());
        return failFrame(VK_ERROR_UNKNOWN);
    }
    m_pass_scratch.passes.clear();
    m_pass_scratch.candidates.clear();
    m_pass_scratch.plan.entries.clear();
    m_pass_loaded = false;

    auto nodes             = rg.topologicalOrder();
    auto node_release_texs = rg.getLastReadTexs(nodes);

    m_passes.clear();
    m_passes.resize(nodes.size());

    std::transform(nodes.begin(),
                   nodes.end(),
                   node_release_texs.begin(),
                   m_passes.begin(),
                   [&rg](auto& id, auto& texs) {
                       auto* pass = rg.getPass(id);
                       assert(pass != nullptr);
                       VulkanPass* vpass = static_cast<VulkanPass*>(pass);
                       // LOG_INFO("----release tex");
                       std::vector<std::string_view> release_keys;
                       release_keys.reserve(texs.size());
                       for (auto* tex : texs) release_keys.push_back(tex->key());
                       vpass->setReleaseTexs(release_keys);
                       return vpass;
                   });

    for (auto* pass : m_passes) {
        if (auto* custom = dynamic_cast<CustomShaderPass*>(pass)) {
            custom->desc().presentation_format = VK_FORMAT_UNDEFINED;
            custom->desc().presents_through_final_viewport = false;
        }
    }
    if (m_with_surface && ! m_instance.offscreen() &&
        m_device->graphics_queue().family_index == m_device->present_queue().family_index) {
        const auto format = m_device->swapchain().format();
        if (format == VK_FORMAT_R8G8B8A8_UNORM || format == VK_FORMAT_B8G8R8A8_UNORM) {
            m_direct_present_pass = FindDirectPresentationPass(scene, m_passes);
            if (m_direct_present_pass != nullptr) {
                m_direct_present_pass->desc().presentation_format = format;
                // The plain-video scene is built as the final composition's
                // own quad copying one texture (CreateVideoProjectScene), so
                // presenting it may resample the source instead of the copy.
                m_direct_present_pass->desc().presents_through_final_viewport =
                    scene.single_video_source;
            }
        }
    }

    m_passes.insert(m_passes.begin(), m_prepass.get());
    m_passes.push_back(m_finpass.get());

    setRenderTargetSize(scene, rg);

    if (! preparePasses(scene)) return false;
    if (! applySceneOptimization(scene, rg)) return false;
    m_pass_loaded = true;
    return true;
};

bool VulkanRender::Impl::quiesceForPassRebuild() {
    // Destroying prepared pass state and dropping render targets is exactly
    // what `applyRenderScale` does, and it is only safe once no submitted
    // frame can still be reading them. During a compile nothing has been
    // submitted for this graph, so the wait is skipped there; at a frame
    // boundary it is not optional, and it is a one-time cost paid when the
    // user changes a setting rather than per frame.
    if (! m_pass_loaded) return true;
    if (quiesceFrame() != VK_SUCCESS) return false;
    std::string error;
    if (! m_device->tex_cache().WaitForPendingUploads(&error)) {
        LOG_ERROR("cannot rebuild passes with pending uploads: %s", error.c_str());
        return failFrame(VK_ERROR_UNKNOWN);
    }
    for (auto* command : { &m_render_cmd, &m_upload_cmd }) {
        if (*command) {
            const auto result = command->Reset();
            if (result != VK_SUCCESS) return failFrame(result);
        }
    }
    return true;
}

bool VulkanRender::Impl::applySceneOptimization(Scene& scene, rg::RenderGraph& rg) {
    m_present_gate.Invalidate();
    releaseStaticCache();
    m_static_cache.Reset();
    m_static_samples.clear();
    m_static_skip.assign(m_passes.size(), uint8_t { 0 });
    // Unconditional: on-demand updating needs to know what the shaders depend
    // on whether or not pixel reuse is switched on. The two features answer
    // different questions from the same reflection, and tying this to the
    // reuse switch would make turning reuse off silently make every scene look
    // dynamic.
    computeShaderDynamicReasons(scene);
    m_scene_optimization_applied = SceneOptimizationEnabled();
    if (! m_scene_optimization_applied) {
        // Copies the last plan removed have to come back, or switching the
        // setting off would leave their destinations holding whatever the
        // elision decided they could share. Only a plan that really removed
        // something needs the passes rebuilt.
        bool restored = false;
        for (auto* pass : m_passes) {
            auto* copy = dynamic_cast<CopyPass*>(pass);
            if (copy == nullptr || copy->desc().elision == CopyElision::None) continue;
            copy->desc().elision = CopyElision::None;
            restored             = true;
        }
        if (restored) {
            if (! quiesceForPassRebuild()) return false;
            for (auto* pass : m_passes) {
                if (pass != nullptr) pass->destory(*m_device, m_rendering_resources);
            }
            std::string error;
            if (! m_device->tex_cache().ClearRenderTargets(&error)) {
                LOG_ERROR("cannot drop render targets for copy elision: %s", error.c_str());
                return failFrame(VK_ERROR_UNKNOWN);
            }
            setRenderTargetSize(scene, rg);
            if (! preparePasses(scene)) return false;
        }
        RecordElidedCopies(0);
        return true;
    }

    // Copy elimination first: it changes which targets exist and who reads
    // them, so the reuse analysis must see the list the renderer will run.
    std::vector<ElisionPassDesc> elision;
    elision.reserve(m_passes.size());
    for (auto* pass : m_passes) {
        ElisionPassDesc desc;
        if (auto* copy = dynamic_cast<CopyPass*>(pass)) {
            desc = copy->elisionDesc(scene);
        } else if (auto* custom = dynamic_cast<CustomShaderPass*>(pass)) {
            desc.kind   = ElisionPassDesc::Kind::Custom;
            desc.writes = scene.ResolveRenderTargetName(custom->desc().output);
            for (const auto& texture : custom->desc().textures) {
                if (texture.empty()) continue;
                desc.reads.push_back(scene.ResolveRenderTargetName(texture));
            }
        } else if (auto* pre = dynamic_cast<PrePass*>(pass)) {
            desc.kind   = ElisionPassDesc::Kind::Clear;
            desc.writes = scene.ResolveRenderTargetName(pre->desc().result);
        } else {
            // The final blit consumes the scene's output. Recording its read
            // keeps that target from looking like a result nobody wants.
            desc.kind  = ElisionPassDesc::Kind::Present;
            desc.reads = { scene.ResolveRenderTargetName(SpecTex_Default) };
        }
        elision.push_back(std::move(desc));
    }

    const auto plan = PlanCopyElision(elision);
    uint64_t   elided = 0;
    bool       changed = false;
    std::unordered_map<std::string, std::string> aliases;
    for (std::size_t i = 0; i < m_passes.size(); ++i) {
        auto* copy = dynamic_cast<CopyPass*>(m_passes[i]);
        if (copy == nullptr || plan[i] == CopyElision::None) continue;
        copy->desc().elision = plan[i];
        changed              = true;
        ++elided;
        if (plan[i] == CopyElision::Alias) {
            aliases[scene.ResolveRenderTargetName(copy->desc().dst)] =
                scene.ResolveRenderTargetName(copy->desc().src);
        }
    }
    if (changed) {
        // The copies decided above change what each pass queries, so their
        // prepared state has to be rebuilt against the new plan.
        if (! quiesceForPassRebuild()) return false;
        for (auto* pass : m_passes) {
            if (pass != nullptr) pass->destory(*m_device, m_rendering_resources);
        }
        std::string error;
        if (! m_device->tex_cache().ClearRenderTargets(&error)) {
            LOG_ERROR("cannot drop render targets for copy elision: %s", error.c_str());
            return failFrame(VK_ERROR_UNKNOWN);
        }
        setRenderTargetSize(scene, rg);
        if (! preparePasses(scene)) return false;
    }
    RecordElidedCopies(elided);

    std::vector<StaticPassDesc> descs;
    descs.reserve(m_passes.size());
    for (std::size_t i = 0; i < m_passes.size(); ++i) {
        StaticPassDesc desc;
        if (auto* custom = dynamic_cast<CustomShaderPass*>(m_passes[i])) {
            desc = custom->staticPassDesc(scene);
            desc.target = scene.ResolveRenderTargetName(desc.target);
            // Through the alias, never the bare name. An aliased destination
            // has no writer of its own after elision, so a read of it that is
            // not resolved looks like a read of something no pass produces --
            // and a reader whose real source is redrawn every frame would then
            // be called reusable.
            for (auto& input : desc.inputs) {
                input = ResolveCopyAliasKey(aliases, scene.ResolveRenderTargetName(input));
            }
        } else if (auto* copy = dynamic_cast<CopyPass*>(m_passes[i])) {
            // An elided copy produces nothing at execution time, so it neither
            // writes a target nor forces one to re-render.
            if (copy->desc().elision == CopyElision::None) {
                desc.target = scene.ResolveRenderTargetName(copy->desc().dst);
                desc.inputs = { ResolveCopyAliasKey(
                    aliases, scene.ResolveRenderTargetName(copy->desc().src)) };
            }
        } else if (auto* pre = dynamic_cast<PrePass*>(m_passes[i])) {
            // A clear is a writer like any other: reusing a target while still
            // clearing it every frame is exactly how the pixels would be lost.
            desc.target = scene.ResolveRenderTargetName(pre->desc().result);
        }
        descs.push_back(std::move(desc));
    }
    m_static_cache.Compile(descs);
    m_static_samples.assign(m_passes.size(), StaticPassSample {});

    for (std::size_t i = 0; i < m_static_cache.TargetCount(); ++i) {
        if (! m_static_cache.TargetCacheable(i)) continue;
        const auto& key   = m_static_cache.TargetKey(i);
        const auto  bytes = m_device->tex_cache().RenderTargetBytes(key);
        if (bytes == 0) continue;
        if (m_static_pinned_bytes + bytes > m_static_cache_budget_bytes) continue;
        if (! m_device->tex_cache().PinRenderTarget(key)) continue;
        m_static_cache.SetTargetPinned(i, true, bytes);
        m_static_pinned_bytes += bytes;
    }
    AdjustSceneOptimizationPinnedBytes(static_cast<int64_t>(m_static_pinned_bytes));
    return true;
}

void VulkanRender::Impl::computeShaderDynamicReasons(Scene& scene) {
    // Starts at "unknown" and is replaced wholesale, so a pass shape this
    // function does not recognise leaves the scene looking dynamic rather than
    // still. Only `CustomShaderPass` carries shader reflection; clears and
    // copies contribute nothing of their own beyond the targets they touch.
    //
    // A target the frame reads before it writes it hands each frame's result
    // to the next: a trail keeps fading and an accumulation keeps converging
    // with nothing else changing, so the clock has to keep running for it.
    // The flag stays on the scene's target once a graph has set it, so only a
    // target a pass of this graph reads or writes counts, not one an earlier
    // graph of the same scene carried.
    const auto carries_previous_frame = [&scene](const std::string& key) {
        if (key.empty()) return false;
        const auto* target = scene.FindRenderTarget(key);
        return target != nullptr && target->carriesPreviousFrame;
    };
    uint32_t reasons = 0;
    bool     understood_every_pass = true;
    bool     reads_previous_frame  = false;
    for (auto* pass : m_passes) {
        if (pass == nullptr) continue;
        if (auto* custom = dynamic_cast<CustomShaderPass*>(pass)) {
            const auto desc = custom->staticPassDesc(scene);
            reasons |= desc.dynamic_reasons;
            reads_previous_frame = reads_previous_frame || carries_previous_frame(desc.target) ||
                                   std::any_of(desc.inputs.begin(), desc.inputs.end(),
                                               carries_previous_frame);
            continue;
        }
        if (auto* copy = dynamic_cast<CopyPass*>(pass)) {
            reads_previous_frame = reads_previous_frame ||
                                   carries_previous_frame(copy->desc().src) ||
                                   carries_previous_frame(copy->desc().dst);
            continue;
        }
        if (dynamic_cast<PrePass*>(pass) != nullptr || dynamic_cast<FinPass*>(pass) != nullptr) {
            continue;
        }
        understood_every_pass = false;
    }
    if (reads_previous_frame) reasons |= DynamicReason::Feedback;
    if (! understood_every_pass) reasons |= DynamicReason::UnknownInput;
    m_shader_dynamic_reasons = reasons;
}

void VulkanRender::Impl::releaseStaticCache() {
    if (m_static_pinned_bytes != 0) {
        AdjustSceneOptimizationPinnedBytes(-static_cast<int64_t>(m_static_pinned_bytes));
        m_static_pinned_bytes = 0;
    }
    for (auto* pass : m_passes) {
        if (auto* custom = dynamic_cast<CustomShaderPass*>(pass)) custom->setFrameSkipped(false);
    }
}

void VulkanRender::Impl::planStaticSkips(Scene& scene) {
    (void)scene;
    if (m_static_skip.size() != m_passes.size()) m_static_skip.assign(m_passes.size(), uint8_t { 0 });
    if (! SceneOptimizationEnabled() || m_static_cache.TargetCount() == 0) {
        // Dropped, not merely unused. While reuse is off every target is
        // redrawn from whatever this frame's inputs are, and the table still
        // holds the signature that was current when it was switched off. If a
        // later frame's inputs happen to match that one, switching reuse back
        // on would call the target unchanged although the pixels behind it came
        // from a frame with different inputs.
        m_static_cache.InvalidateAll();
        for (auto* pass : m_passes) {
            if (auto* custom = dynamic_cast<CustomShaderPass*>(pass)) custom->setFrameSkipped(false);
        }
        return;
    }
    // Reuse needs a target that is both cacheable and holding a pinned
    // allocation: the pool may hand an unpinned image to another key, so
    // `Plan` refuses to skip one. With nothing pinned — an uncacheable graph,
    // or one whose targets did not fit the memory budget at this output size —
    // the only answer Plan can give is "execute every pass", and sampling every
    // pass and hashing every signature to arrive there is work with no reachable
    // result. The budget still stands; this only stops paying to re-discover
    // that it was exhausted, every frame.
    if (m_static_pinned_bytes == 0) {
        m_static_cache.InvalidateAll();
        std::fill(m_static_skip.begin(), m_static_skip.end(), uint8_t { 0 });
        for (auto* pass : m_passes) {
            if (auto* custom = dynamic_cast<CustomShaderPass*>(pass)) custom->setFrameSkipped(false);
        }
        // Empty means "no pass was dropped", which is what executePreparedPasses
        // reads as the full list; filling it with every pass would say the same
        // thing and allocate to do it.
        m_frame_passes.clear();
        RecordSceneOptimizationFrame(static_cast<uint64_t>(m_passes.size()), 0);
        return;
    }
    if (m_static_samples.size() != m_passes.size())
        m_static_samples.assign(m_passes.size(), StaticPassSample {});

    for (std::size_t i = 0; i < m_passes.size(); ++i) {
        auto* custom = dynamic_cast<CustomShaderPass*>(m_passes[i]);
        // Only the writers of a cacheable target fold into a signature; the
        // rest execute whatever their sample would say. A clear or a copy
        // contributes no varying state of its own either: it is skipped exactly
        // when the target it writes is.
        if (! m_static_cache.PassSampled(i)) {
            m_static_samples[i] = StaticPassSample { .hash = 0, .visible = true };
            continue;
        }
        if (custom != nullptr) {
            m_static_samples[i] = custom->frameSample(scene);
        } else if (const auto* clear = dynamic_cast<PrePass*>(m_passes[i]);
                   clear != nullptr && ! clear->desc().transparent) {
            m_static_samples[i] = StaticPassSample {
                .hash = StaticHashBytes(0xcbf29ce484222325ULL, scene.clearColor.data(), sizeof(float) * 3),
                .visible = true,
            };
        } else {
            m_static_samples[i] = StaticPassSample {};
        }
    }

    // Into the member the frame already owns. A fresh vector here was a heap
    // allocation and free on every frame of every scene, to carry one byte per
    // pass that is overwritten wholesale by `Plan` anyway.
    m_static_cache.Plan(m_static_samples, m_static_skip);
    uint64_t skipped  = 0;
    uint64_t executed = 0;
    m_frame_passes.clear();
    m_frame_passes.reserve(m_passes.size());
    for (std::size_t i = 0; i < m_passes.size(); ++i) {
        const bool skipped_here = m_static_skip[i] != 0;
        auto* custom = dynamic_cast<CustomShaderPass*>(m_passes[i]);
        if (custom != nullptr) custom->setFrameSkipped(skipped_here);
        if (skipped_here) {
            ++skipped;
            // A custom pass stays in the list so batching still sees the same
            // neighbours; it reports itself invisible instead. A clear or copy
            // has no such representation, so it leaves the list entirely.
            if (custom != nullptr) m_frame_passes.push_back(m_passes[i]);
            continue;
        }
        ++executed;
        m_frame_passes.push_back(m_passes[i]);
    }
    RecordSceneOptimizationFrame(executed, skipped);
}

bool VulkanRender::Impl::frameRecordsOnlyComposition() const {
    for (std::size_t i = 0; i < m_passes.size(); ++i) {
        const auto* pass = m_passes[i];
        if (pass == nullptr || pass == m_finpass.get()) continue;
        if (i < m_static_skip.size() && m_static_skip[i] != 0) continue;
        if (const auto* custom = dynamic_cast<const CustomShaderPass*>(pass)) {
            const auto candidate = custom->batchCandidate();
            // Hidden and carrying no clear: records nothing.
            if (! candidate.visible && ! candidate.clear_only) continue;
            // Hidden with a clear nothing can observe: the executor drops it.
            if (! candidate.visible && candidate.clear_only) {
                CustomShaderPass* clearing[] { const_cast<CustomShaderPass*>(custom) };
                if (! HiddenClearIsObservable(m_passes, clearing)) continue;
            }
            return false;
        }
        // An eliminated copy produces nothing at execution time.
        if (const auto* copy = dynamic_cast<const CopyPass*>(pass);
            copy != nullptr && copy->desc().elision != CopyElision::None) {
            continue;
        }
        return false;
    }
    return true;
}

bool VulkanRender::Impl::frameRepeatsLastPresent(const Scene& scene) {
    // Everything the final composition reads besides the scene's own pixels.
    const auto& rr = m_rendering_resources;
    m_present_key.Clear();
    const auto extent = m_device->out_extent();
    m_present_key.Add(extent.width);
    m_present_key.Add(extent.height);
    m_present_key.AddPointer(m_with_surface ? *m_device->swapchain().handle() : nullptr);
    m_present_key.Add(static_cast<uint64_t>(m_with_surface ? m_device->swapchain().format()
                                                           : VK_FORMAT_UNDEFINED));
    m_present_key.AddFloat(rr.wallpaper_viewport.x);
    m_present_key.AddFloat(rr.wallpaper_viewport.y);
    m_present_key.AddFloat(rr.wallpaper_viewport.width);
    m_present_key.AddFloat(rr.wallpaper_viewport.height);
    m_present_key.Add(static_cast<uint64_t>(static_cast<uint32_t>(rr.wallpaper_scissor.offset.x)));
    m_present_key.Add(static_cast<uint64_t>(static_cast<uint32_t>(rr.wallpaper_scissor.offset.y)));
    m_present_key.Add(rr.wallpaper_scissor.extent.width);
    m_present_key.Add(rr.wallpaper_scissor.extent.height);
    m_present_key.Add(rr.wallpaper_horizontal_flip ? 1u : 0u);
    m_present_key.AddFloat(scene.clearColor[0]);
    m_present_key.AddFloat(scene.clearColor[1]);
    m_present_key.AddFloat(scene.clearColor[2]);
    m_present_key.Add(scene.clearEnabled ? 1u : 0u);
    m_present_key.AddDouble(scene.render_scale);
    m_present_key.AddPointer(m_direct_present_pass);

    m_present_videos.clear();
    m_present_pts.clear();
    m_device->tex_cache().ForEachCurrentVideoFrame(
        [this](const void* texture, const void* frame, uint64_t generation, double pts) {
            m_present_videos.push_back(PresentedVideoFrame { texture, frame, generation });
            m_present_pts.push_back(pts);
        });

    // Render-result reuse at the scale of the surface, so it answers to the
    // same setting as the per-target reuse it extends.
    if (! SceneOptimizationEnabled() || ! m_present_gate.Valid()) return false;
    // A frame with new host data to upload has something new to draw.
    if (m_dyn_buf == nullptr || m_dyn_buf->hasPendingWrites()) return false;
    // The Vulkan path can export a poster only from inside a presented frame,
    // so a pending request is answered by drawing. Asked without taking it;
    // with no way to ask, a request is always assumed possible.
    if (m_wants_poster && (! m_poster_pending || m_poster_pending())) return false;
    // Two proofs that the scene's own pixels are the ones already shown: the
    // engine's plain-video scene is one video texture behind a copy, so its
    // picture is its video frame; any other scene must have had every pass
    // reused, leaving nothing to record but the final composition.
    if (! scene.single_video_source && ! frameRecordsOnlyComposition()) return false;
    return m_present_gate.Matches(m_present_key, m_present_videos);
}

bool VulkanRender::Impl::preparePasses(Scene& scene) {
    // Re-prepared passes draw into rebuilt targets; nothing presented before
    // this point describes what they will produce.
    m_present_gate.Invalidate();
    if (scene.imageParser != nullptr) {
        const auto extent = m_device->out_extent();
        // A perspective view may magnify a small UV region of a model or skybox.
        // Its display size does not bound the source texture's required detail.
        scene.imageParser->SetTextureSurfaceSize(scene.display_sized ? 0 : extent.width,
                                                 scene.display_sized ? 0 : extent.height);
    }
    if (! ReserveCarriedOverTargets(scene, m_device->tex_cache())) {
        LOG_ERROR("cannot allocate the render targets carried into the next frame");
        return false;
    }
    glslang::InitializeProcess();
    {
        // Decodes ahead of the passes on other threads; joined when this
        // block ends, before anything reads what the passes prepared.
        const auto prefetch = TexturePrefetch::ForPasses(scene, m_device->tex_cache(), m_passes);
        m_rendering_resources.texture_prefetch = prefetch.get();
        AUTO_DELETER(texture_prefetch, [this]() { m_rendering_resources.texture_prefetch = nullptr; });
        for (auto* p : m_passes) {
            if (! p->prepared()) {
                p->prepare(scene, *m_device, m_rendering_resources);
            }
        }
    }
    glslang::FinalizeProcess();
    if (std::any_of(m_passes.begin(), m_passes.end(),
                    [](const auto* pass) { return pass == nullptr || ! pass->prepared(); }))
        return false;

    m_static_upload_recording = true;
    const auto begin_result = m_upload_cmd.Begin(VkCommandBufferBeginInfo {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = nullptr,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    });
    if (begin_result != VK_SUCCESS) return failFrame(begin_result);
    if (! m_vertex_buf->recordUpload(m_upload_cmd)) return failFrame(VK_ERROR_UNKNOWN);
    const auto end_result = m_upload_cmd.End();
    if (end_result != VK_SUCCESS) return failFrame(end_result);
    {
        VkSubmitInfo sub_info {
            .sType              = VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext              = nullptr,
            .commandBufferCount = 1,
            .pCommandBuffers    = m_upload_cmd.address(),
        };
        const auto submit_result = m_device->graphics_queue().handle.Submit(sub_info, {});
        if (submit_result != VK_SUCCESS) return failFrame(submit_result);
        m_static_upload_submitted = true;
        const auto idle_result = quiesceFrame();
        if (idle_result != VK_SUCCESS) return false;
    }
    // The pipelines this prepare just built. A later launch of the same
    // wallpaper reads them back instead of compiling again.
    if (m_device != nullptr) m_device->SavePipelineCache();
    return true;
}

bool VulkanRender::Impl::applyRenderScale(Scene& scene, rg::RenderGraph& rg, double scale) {
    if (! std::isfinite(scale) || scale <= 0.0) return true;
    const double clamped = std::min(1.0, std::max(kMinRenderScale, scale));
    if (scene.render_scale == clamped) return true;

    // A plain-video scene keeps its media-sized target whatever the user
    // selects, so record the preference but do no work: the higher layer
    // reports the control as not applicable for those wallpapers.
    if (scene.single_video_source) {
        scene.render_scale = clamped;
        return true;
    }
    scene.render_scale = clamped;

    // Nothing is prepared yet, so the next compile reads the new scale anyway.
    if (! m_inited || m_device_lost || m_frame_faulted || ! m_pass_loaded) return true;

    if (quiesceFrame() != VK_SUCCESS) return false;
    std::string error;
    if (! m_device->tex_cache().WaitForPendingUploads(&error)) {
        LOG_ERROR("cannot change render scale with pending uploads: %s", error.c_str());
        return failFrame(VK_ERROR_UNKNOWN);
    }
    for (auto* command : { &m_render_cmd, &m_upload_cmd }) {
        if (*command) {
            const auto result = command->Reset();
            if (result != VK_SUCCESS) return failFrame(result);
        }
    }
    // The pass objects are owned by the render graph and by this Impl, so
    // destroying their prepared state leaves them reusable. That is what lets
    // the graph, the scene and the decoders survive a quality change.
    for (auto* pass : m_passes) {
        if (pass != nullptr) pass->destory(*m_device, m_rendering_resources);
    }
    if (! m_device->tex_cache().ClearRenderTargets(&error)) {
        LOG_ERROR("cannot drop render targets for render scale: %s", error.c_str());
        return failFrame(VK_ERROR_UNKNOWN);
    }

    setRenderTargetSize(scene, rg);
    if (! preparePasses(scene)) {
        LOG_ERROR("failed to re-prepare passes at render scale %.3f", clamped);
        return false;
    }
    LOG_INFO("render scale applied: %.3f", clamped);
    return true;
}
