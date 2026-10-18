
#include "Shader.hpp"
#include "Swapchain.hpp"
#include "TextureCache.hpp"
#include "Device.hpp"
#include "Util.hpp"

#include "Image.hpp"
#include "Platform/Apple/FfmpegVideoInterop.hpp"
#include "Video/SharedVideoSession.hpp"
#include "Core/MapSet.hpp"
#include "Core/ArrayHelper.hpp"
#include "Utils/AutoDeletor.hpp"
#include "Utils/Hash.h"
#include "include/Vulkan/Parameters.hpp"
#include "vvk/vulkan_wrapper.hpp"

#include <vulkan/vulkan_metal.h>

#include <cmath>
#include <cstdio>
#include <memory>
#include <optional>
#include <exception>
#include <limits>

using namespace wallpaper;
using namespace wallpaper::vulkan;

namespace wallpaper
{
namespace vulkan
{
VkFormat ToVkType(TextureFormat tf) {
    switch (tf) {
    case TextureFormat::BC1: return VK_FORMAT_BC1_RGBA_UNORM_BLOCK;
    case TextureFormat::BC2: return VK_FORMAT_BC2_UNORM_BLOCK;
    case TextureFormat::BC3: return VK_FORMAT_BC3_UNORM_BLOCK;
    case TextureFormat::R8: return VK_FORMAT_R8_UNORM;
    case TextureFormat::RG8: return VK_FORMAT_R8G8_UNORM;
    case TextureFormat::RGB8: return VK_FORMAT_R8G8B8_UNORM;
    case TextureFormat::RGBA8: return VK_FORMAT_R8G8B8A8_UNORM;
    case TextureFormat::RGBA16F: return VK_FORMAT_R16G16B16A16_SFLOAT;
    default: assert(false); return VK_FORMAT_R8G8B8A8_UNORM;
    }
}

VkSamplerAddressMode ToVkType(wallpaper::TextureWrap sam) {
    using namespace wallpaper;
    switch (sam) {
    case TextureWrap::CLAMP_TO_EDGE: return VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    case TextureWrap::REPEAT:
    default: return VK_SAMPLER_ADDRESS_MODE_REPEAT;
    }
}
VkFilter ToVkType(wallpaper::TextureFilter sam) {
    using namespace wallpaper;
    switch (sam) {
    case TextureFilter::LINEAR: return VK_FILTER_LINEAR;
    case TextureFilter::NEAREST:
    default: return VK_FILTER_NEAREST;
    }
}

// Only a texture whose file asks for point sampling picks its mip level by
// point; see `TextureSample::mipFilter`.
VkSamplerMipmapMode ToVkMipmapMode(const wallpaper::TextureSample& sam) {
    using namespace wallpaper;
    return sam.mipFilter == TextureFilter::NEAREST ? VK_SAMPLER_MIPMAP_MODE_NEAREST
                                                   : VK_SAMPLER_MIPMAP_MODE_LINEAR;
}

VkSamplerCreateInfo GenRenderTargetSamplerInfo() {
    return VkSamplerCreateInfo {
        .sType                   = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        .pNext                   = nullptr,
        .magFilter               = VK_FILTER_NEAREST,
        .minFilter               = VK_FILTER_NEAREST,
        .mipmapMode              = VK_SAMPLER_MIPMAP_MODE_LINEAR,
        .addressModeU            = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeV            = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeW            = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .anisotropyEnable        = false,
        .maxAnisotropy           = 1.0f,
        .compareEnable           = false,
        .compareOp               = VK_COMPARE_OP_NEVER,
        .minLod                  = 0.0f,
        .maxLod                  = 1.0f,
        .borderColor             = VK_BORDER_COLOR_INT_OPAQUE_BLACK,
        .unnormalizedCoordinates = false,
    };
}
} // namespace vulkan
} // namespace wallpaper

namespace
{
bool SetError(std::string* error, std::string message) {
    if (error != nullptr) *error = std::move(message);
    return false;
}

/// Exports the Metal device behind `device` and the MTLCommandQueue MoltenVK
/// runs its graphics queue on. MoltenVK hands out the very queue every
/// submission to that VkQueue is committed to (`MVKQueue::getMTLCommandQueue`),
/// so Metal work committed there before a `vkQueueSubmit` executes ahead of
/// the frame that submission records. Both handles are borrowed and live as
/// long as the device.
void* ExportMetalHandles(const Device& device, void** command_queue, std::string* error) {
    auto export_metal_objects = reinterpret_cast<PFN_vkExportMetalObjectsEXT>(
        device.handle().Dispatch().vkGetDeviceProcAddr(*device.handle(),
                                                       "vkExportMetalObjectsEXT"));
    if (export_metal_objects == nullptr) {
        SetError(error, "vkExportMetalObjectsEXT is not available on this Vulkan device");
        return nullptr;
    }

    VkExportMetalCommandQueueInfoEXT queue_info {
        .sType = VK_STRUCTURE_TYPE_EXPORT_METAL_COMMAND_QUEUE_INFO_EXT,
        .pNext = nullptr,
        .queue = *device.graphics_queue().handle,
    };
    VkExportMetalDeviceInfoEXT device_info {
        .sType = VK_STRUCTURE_TYPE_EXPORT_METAL_DEVICE_INFO_EXT,
        .pNext = &queue_info,
    };
    VkExportMetalObjectsInfoEXT export_info {
        .sType = VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECTS_INFO_EXT,
        .pNext = &device_info,
    };
    export_metal_objects(*device.handle(), &export_info);
    if (device_info.mtlDevice == nullptr) {
        SetError(error, "vkExportMetalObjectsEXT returned a null Metal device");
        return nullptr;
    }
    if (queue_info.mtlCommandQueue == nullptr) {
        SetError(error, "vkExportMetalObjectsEXT returned a null Metal command queue");
        return nullptr;
    }

    *command_queue = queue_info.mtlCommandQueue;
    return device_info.mtlDevice;
}

VkSamplerCreateInfo GenSamplerInfo(TextureKey key) {
    auto& sam = key.sample;

    VkSamplerCreateInfo sampler_info { .sType            = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
                                       .pNext            = nullptr,
                                       .magFilter        = ToVkType(sam.magFilter),
                                       .minFilter        = (ToVkType(sam.minFilter)),
                                       .mipmapMode       = ToVkMipmapMode(sam),
                                       .addressModeU     = (ToVkType(sam.wrapS)),
                                       .addressModeV     = (ToVkType(sam.wrapT)),
                                       .addressModeW     = (ToVkType(sam.wrapT)),
                                       .anisotropyEnable = (false),
                                       .maxAnisotropy    = (1.0f),
                                       .compareEnable    = (false),
                                       .compareOp        = VK_COMPARE_OP_NEVER,
                                       .minLod           = (0.0f),
                                       .maxLod           = (1.0f),
                                       .borderColor      = VK_BORDER_COLOR_INT_OPAQUE_BLACK,
                                       .unnormalizedCoordinates = (false) };
    return sampler_info;
}

/// Moves a new image out of UNDEFINED into `layout`. With `zero`, a colour
/// image is cleared to transparent black on the way: a new image holds
/// whatever its memory last held, which is neither black nor the same on
/// every GPU, and a target read before anything writes it would start from
/// that.
VkResult TransImgLayout(const vvk::Queue& queue, vvk::CommandBuffer& cmd,
                        const ImageParameters& image, VkImageLayout layout,
                        VkFence fence = VK_NULL_HANDLE, bool zero = false) {
    VkResult result;
    do {
        result = cmd.Begin(VkCommandBufferBeginInfo {
            .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = nullptr,
            .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        });
        if (result != VK_SUCCESS) break;

        VkImageSubresourceRange subresourceRange {
            .aspectMask     = layout == VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL
                                  ? VK_IMAGE_ASPECT_DEPTH_BIT
                                  : VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel   = 0,
            .levelCount     = VK_REMAINING_MIP_LEVELS,
            .baseArrayLayer = 0,
            .layerCount     = VK_REMAINING_ARRAY_LAYERS,
        };
        if (zero) {
            VkImageMemoryBarrier clear_bar {
                .sType            = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                .pNext            = nullptr,
                .srcAccessMask    = 0,
                .dstAccessMask    = VK_ACCESS_TRANSFER_WRITE_BIT,
                .oldLayout        = VK_IMAGE_LAYOUT_UNDEFINED,
                .newLayout        = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                .image            = image.handle,
                .subresourceRange = subresourceRange,
            };
            cmd.PipelineBarrier(VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                                VK_PIPELINE_STAGE_TRANSFER_BIT,
                                0,
                                clear_bar);
            const VkClearColorValue transparent {};
            cmd.ClearColorImage(
                image.handle, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &transparent, subresourceRange);
        }
        {
            VkImageMemoryBarrier out_bar {
                .sType            = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                .pNext            = nullptr,
                .srcAccessMask    = zero ? VkAccessFlags(VK_ACCESS_TRANSFER_WRITE_BIT) : 0,
                .dstAccessMask    = VK_ACCESS_MEMORY_READ_BIT,
                .oldLayout        = zero ? VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
                                         : VK_IMAGE_LAYOUT_UNDEFINED,
                .newLayout        = layout,
                .image            = image.handle,
                .subresourceRange = subresourceRange,
            };
            cmd.PipelineBarrier(zero ? VK_PIPELINE_STAGE_TRANSFER_BIT
                                     : VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                                VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                                VK_DEPENDENCY_BY_REGION_BIT,
                                out_bar);
        }
        result = cmd.End();
        if (result != VK_SUCCESS) break;

        VkSubmitInfo sub_info {
            .sType              = VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext              = nullptr,
            .commandBufferCount = 1,
            .pCommandBuffers    = cmd.address(),
        };
        result = queue.Submit(sub_info, fence);
    } while (false);
    return result;
}

std::optional<vvk::DeviceMemory> AllocateMemory(const vvk::Device& device, vvk::PhysicalDevice gpu,
                                                VkMemoryRequirements  reqs,
                                                VkMemoryPropertyFlags property,
                                                void*                 pNext = NULL) {
    VkPhysicalDeviceMemoryProperties pros = gpu.GetMemoryProperties().memoryProperties;
    for (uint32_t i = 0; i < pros.memoryTypeCount; ++i) {
        if ((reqs.memoryTypeBits & (1 << i)) && (pros.memoryTypes[i].propertyFlags & property)) {
            VkMemoryAllocateInfo memory_allocate_info { .sType =
                                                            VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                                                        .pNext           = pNext,
                                                        .allocationSize  = reqs.size,
                                                        .memoryTypeIndex = i };
            vvk::DeviceMemory    mem;
            VkResult             res = device.AllocateMemory(memory_allocate_info, mem);
            if (res == VK_SUCCESS) {
                return mem;
            } else {
                VVK_CHECK(res);
                return std::nullopt;
            }
        }
    }
    LOG_ERROR("vulkan allocate memory failed, no memory match requires");
    return std::nullopt;
}

/// A Vulkan image and view aliasing `metal_texture`, in UNDEFINED layout. The
/// caller records its first-use transition into a frame and supplies the
/// sampler, which belongs to the video texture rather than to the image.
std::optional<ExImageParameters>
CreateImportedMetalTextureImage(const Device& device, void* metal_texture, uint32_t width,
                                uint32_t height, std::string* error) {
    if (metal_texture == nullptr) {
        SetError(error, "cannot import a null Metal texture");
        return std::nullopt;
    }

    ExImageParameters image;

    VkImportMetalTextureInfoEXT import_texture_info {
        .sType      = VK_STRUCTURE_TYPE_IMPORT_METAL_TEXTURE_INFO_EXT,
        .pNext      = nullptr,
        .plane      = VK_IMAGE_ASPECT_COLOR_BIT,
        .mtlTexture = reinterpret_cast<MTLTexture_id>(metal_texture),
    };
    VkImageCreateInfo image_info {
        .sType                 = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .pNext                 = &import_texture_info,
        .imageType             = VK_IMAGE_TYPE_2D,
        .format                = VK_FORMAT_B8G8R8A8_UNORM,
        .extent                = VkExtent3D { .width = width, .height = height, .depth = 1 },
        .mipLevels             = 1,
        .arrayLayers           = 1,
        .samples               = VK_SAMPLE_COUNT_1_BIT,
        .tiling                = VK_IMAGE_TILING_OPTIMAL,
        .usage                 = VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
        .sharingMode           = VK_SHARING_MODE_EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .initialLayout         = VK_IMAGE_LAYOUT_UNDEFINED,
    };
    image.extent = image_info.extent;
    image.layout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

    if (const VkResult result = device.handle().CreateImage(image_info, image.handle);
        result != VK_SUCCESS) {
        LOG_ERROR("imported video image creation failed: %d", result);
        SetError(error, "failed to create Vulkan image for imported video frame");
        return std::nullopt;
    }

    {
        VkImageViewCreateInfo view_info {
            .sType    = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext    = nullptr,
            .image    = *image.handle,
            .viewType = VK_IMAGE_VIEW_TYPE_2D,
            .format   = VK_FORMAT_B8G8R8A8_UNORM,
            .subresourceRange =
                VkImageSubresourceRange {
                    .aspectMask     = VK_IMAGE_ASPECT_COLOR_BIT,
                    .baseMipLevel   = 0,
                    .levelCount     = 1,
                    .baseArrayLayer = 0,
                    .layerCount     = 1,
                },
        };
        if (const VkResult result = device.handle().CreateImageView(view_info, image.view);
            result != VK_SUCCESS) {
            LOG_ERROR("imported video image view creation failed: %d", result);
            SetError(error, "failed to create Vulkan image view for imported video frame");
            return std::nullopt;
        }
    }
    return image;
}

// DRM fourcc codes we emit. We currently only render R8G8B8A8_UNORM and
// B8G8R8A8_UNORM into the ExSwapchain, so those are the only mappings.
// Vulkan component order X-Y-Z-W maps to the *first-byte-in-memory* ordering
// used by DRM fourccs ('AB24' = little-endian 'AB24' bytes = A, B, 2, 4 →
// DRM_FORMAT_ABGR8888).
static uint32_t VkFormatToDrmFourcc(VkFormat fmt) {
    switch (fmt) {
    case VK_FORMAT_R8G8B8A8_UNORM: return 0x34324241u; // DRM_FORMAT_ABGR8888
    case VK_FORMAT_B8G8R8A8_UNORM: return 0x34324152u; // DRM_FORMAT_ARGB8888
    default: return 0u;
    }
}

std::optional<ExImageParameters> CreateExImage(uint32_t width, uint32_t height, VkFormat format,
                                               VkImageTiling       tiling,
                                               VkSamplerCreateInfo sampler_info,
                                               VkImageUsageFlags usage, const vvk::Device& device,
                                               const vvk::PhysicalDevice& gpu) {
    ExImageParameters image;
    do {
        // Iteration 1a: switch the external handle type from OPAQUE_FD to
        // real Linux DMA-BUF so the FD is importable outside this Vulkan
        // instance. The OPTIMAL code path would additionally use
        // VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT and pick a modifier from
        // a queried list; we keep LINEAR-only for now so that consumers
        // can mmap the buffer directly (the iteration 4 milestone).
        if (tiling != VK_IMAGE_TILING_LINEAR) {
            LOG_INFO("[ex-image] OPTIMAL tiling requested; downgrading to LINEAR "
                     "because the DRM-format-modifier path is not yet wired up");
            tiling = VK_IMAGE_TILING_LINEAR;
        }

        VkExternalMemoryImageCreateInfo ex_info {
            .sType       = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO,
            .pNext       = NULL,
            .handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
        };
        VkExportMemoryAllocateInfo ex_mem_info {
            .sType       = VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO,
            .pNext       = NULL,
            .handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
        };
        VkImageCreateInfo info {
            .sType                 = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext                 = &ex_info,
            .imageType             = VK_IMAGE_TYPE_2D,
            .format                = format,
            .extent                = VkExtent3D { .width = width, .height = height, .depth = 1 },
            .mipLevels             = 1,
            .arrayLayers           = 1,
            .samples               = VK_SAMPLE_COUNT_1_BIT,
            .tiling                = tiling,
            .usage                 = usage,
            .sharingMode           = VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .initialLayout         = VK_IMAGE_LAYOUT_UNDEFINED,
        };
        image.extent = info.extent;
        image.layout = VK_IMAGE_LAYOUT_GENERAL;

        VVK_CHECK_ACT(break, device.CreateImage(info, image.handle));

        image.mem_reqs = device.GetImageMemoryRequirements(*image.handle);

        if (auto opt = AllocateMemory(
                device, gpu, image.mem_reqs, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, &ex_mem_info);
            opt.has_value()) {
            image.mem = std::move(opt.value());
        } else
            break;

        VVK_CHECK_ACT(break, image.handle.BindMemory(*image.mem, 0));
        {
            VkImageViewCreateInfo createinfo {
                .sType    = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                .pNext    = nullptr,
                .image    = *image.handle,
                .viewType = VK_IMAGE_VIEW_TYPE_2D,
                .format   = format,
                .subresourceRange =
                    VkImageSubresourceRange {
                        .aspectMask     = VK_IMAGE_ASPECT_COLOR_BIT,
                        .baseMipLevel   = 0,
                        .levelCount     = 1,
                        .baseArrayLayer = 0,
                        .layerCount     = 1,
                    },
            };
            VVK_CHECK_ACT(break, device.CreateImageView(createinfo, image.view));
        }
        VVK_CHECK_ACT(break, device.CreateSampler(sampler_info, image.sampler));
        VVK_CHECK_ACT(break, image.mem.GetMemoryFdKHR(&image.fd));

        // Populate the DRM metadata so VulkanExSwapchain → ExHandle (and
        // eventually the waywallen-host process) can forward it to external
        // consumers without re-querying Vulkan.
        VkImageSubresource subres {
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .mipLevel   = 0,
            .arrayLayer = 0,
        };
        VkSubresourceLayout layout = device.GetImageSubresourceLayout(*image.handle, subres);
        image.plane0_offset        = layout.offset;
        image.plane0_stride        = static_cast<uint32_t>(layout.rowPitch);
        image.drm_modifier         = 0; // DRM_FORMAT_MOD_LINEAR
        image.drm_fourcc           = VkFormatToDrmFourcc(format);

        return image;

    } while (false);
    return std::nullopt;
}

inline std::optional<VmaImageParameters>
CreateImage(const Device& device, VkExtent3D extent, u32 miplevel, VkFormat format,
            VkSamplerCreateInfo sampler_info, VkImageUsageFlags usage,
            VmaMemoryUsage         mem_usage = VMA_MEMORY_USAGE_GPU_ONLY,
            VkSampleCountFlagBits  samples = VK_SAMPLE_COUNT_1_BIT) {
    VmaImageParameters image;
    do {
        const bool is_depth = (usage & VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT) != 0 &&
                              (usage & VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT) == 0;
        if (samples != VK_SAMPLE_COUNT_1_BIT && ! is_depth) {
            miplevel = 1;
            constexpr VkImageUsageFlags removed_msaa_usage =
                VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
            usage &= ~removed_msaa_usage;
            usage |= VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
        }

        VkImageCreateInfo info {
            .sType                 = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext                 = nullptr,
            .imageType             = VK_IMAGE_TYPE_2D,
            .format                = format,
            .extent                = extent,
            .mipLevels             = miplevel,
            .arrayLayers           = 1,
            .samples               = samples,
            .tiling                = VK_IMAGE_TILING_OPTIMAL,
            .usage                 = usage,
            .sharingMode           = VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .initialLayout         = VK_IMAGE_LAYOUT_UNDEFINED,
        };
        image.extent = info.extent;
        VmaAllocationCreateInfo vma_info {};
        vma_info.usage = mem_usage;
        VVK_CHECK_ACT(break,
                      vvk::CreateImage(device.vma_allocator(), info, vma_info, image.handle));

        image.mipmap_level = miplevel;
        {
            VkImageViewCreateInfo createinfo {
                .sType    = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                .pNext    = nullptr,
                .image    = *image.handle,
                .viewType = VK_IMAGE_VIEW_TYPE_2D,
                .format   = format,
                .subresourceRange =
                    VkImageSubresourceRange {
                        .aspectMask     = is_depth ? VK_IMAGE_ASPECT_DEPTH_BIT
                                                   : VK_IMAGE_ASPECT_COLOR_BIT,
                        .baseMipLevel   = 0,
                        .levelCount     = miplevel,
                        .baseArrayLayer = 0,
                        .layerCount     = 1,
                    },
            };
            VVK_CHECK_ACT(break, device.handle().CreateImageView(createinfo, image.view));
        }
        VVK_CHECK_ACT(break, device.handle().CreateSampler(sampler_info, image.sampler));
        return image;
    } while (false);
    /*
    if (result != vk::Result::eSuccess) {
        device.DestroyImageParameters(image);
    }
    */
    return std::nullopt;
}

inline VkResult CopyImageData(std::span<const BufferParameters> in_bufs,
                              std::span<const VkExtent3D> in_exts, const vvk::Queue& queue,
                              vvk::CommandBuffer& cmd, const ImageParameters& image,
                              VkFence fence = VK_NULL_HANDLE) {
    VkResult result;
    do {
        result = cmd.Begin(VkCommandBufferBeginInfo {
            .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = nullptr,
            .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        });
        if (result != VK_SUCCESS) break;

        VkImageSubresourceRange subresourceRange {
            .aspectMask     = VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel   = 0,
            .levelCount     = (uint32_t)in_bufs.size(),
            .baseArrayLayer = 0,
            .layerCount     = 1,
        };
        {
            VkImageMemoryBarrier in_bar {
                .sType            = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                .pNext            = nullptr,
                .srcAccessMask    = VK_ACCESS_MEMORY_WRITE_BIT,
                .dstAccessMask    = VK_ACCESS_TRANSFER_WRITE_BIT,
                .oldLayout        = VK_IMAGE_LAYOUT_UNDEFINED,
                .newLayout        = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                .image            = image.handle,
                .subresourceRange = subresourceRange,
            };
            cmd.PipelineBarrier(VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                                VK_PIPELINE_STAGE_TRANSFER_BIT,
                                VK_DEPENDENCY_BY_REGION_BIT,
                                in_bar);
        }
        VkBufferImageCopy copy {
            .imageSubresource =
                VkImageSubresourceLayers {
                    .aspectMask     = VK_IMAGE_ASPECT_COLOR_BIT,
                    .baseArrayLayer = 0,
                    .layerCount     = 1,
                },
        };
        for (usize i = 0; i < in_bufs.size(); i++) {
            copy.imageSubresource.mipLevel = (u32)i;
            copy.imageExtent               = in_exts[i];
            cmd.CopyBufferToImage(
                in_bufs[i].handle, image.handle, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, copy);
        }
        {
            VkImageMemoryBarrier out_bar {
                .sType            = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                .pNext            = nullptr,
                .srcAccessMask    = VK_ACCESS_TRANSFER_WRITE_BIT,
                .dstAccessMask    = VK_ACCESS_SHADER_READ_BIT,
                .oldLayout        = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                .newLayout        = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                .image            = image.handle,
                .subresourceRange = subresourceRange,
            };
            cmd.PipelineBarrier(VK_PIPELINE_STAGE_TRANSFER_BIT,
                                VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                                VK_DEPENDENCY_BY_REGION_BIT,
                                out_bar);
        }
        result = cmd.End();
        if (result != VK_SUCCESS) break;

        VkSubmitInfo sub_info {
            .sType              = VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext              = nullptr,
            .commandBufferCount = 1,
            .pCommandBuffers    = cmd.address(),
        };
        result = queue.Submit(sub_info, fence);
    } while (false);
    return result;
}
} // namespace

VkSampleCountFlagBits vulkan::PlannedTextureSampleCountForGpuAllocation(TextureKey key) {
    if (key.usage != TexUsage::MSAA_COLOR && key.usage != TexUsage::DEPTH)
        return VK_SAMPLE_COUNT_1_BIT;
    return key.sample_count;
}

bool TextureCache::ReadbackImageSample(const ImageParameters& image, uint32_t x, uint32_t y,
                                       uint32_t width, uint32_t height,
                                       std::vector<std::uint8_t>* out, std::string* error) {
    if (out == nullptr) {
        return SetError(error, "readback output buffer must not be null");
    }
    if (width == 0 || height == 0) {
        return SetError(error, "readback sample dimensions must be non-zero");
    }
    if (image.handle == VK_NULL_HANDLE) {
        return SetError(error, "readback source image handle must not be null");
    }
    if (x >= image.extent.width || y >= image.extent.height) {
        return SetError(error, "readback sample origin is outside the image extent");
    }

    const bool half_float = std::any_of(m_query_texs.begin(), m_query_texs.end(),
        [&](const auto& target) {
            return *target->image.handle == image.handle &&
                   target->format == TextureFormat::RGBA16F;
        });
    const uint32_t sample_width  = std::min(width, image.extent.width - x);
    const uint32_t sample_height = std::min(height, image.extent.height - y);
    const size_t   byte_count =
        static_cast<size_t>(sample_width) * static_cast<size_t>(sample_height) *
        (half_float ? 8u : 4u);
    if (byte_count == 0) {
        return SetError(error, "readback sample region resolved to zero bytes");
    }

    VmaBufferParameters readback_buffer;
    if (! CreateReadbackBuffer(m_device.vma_allocator(), byte_count, readback_buffer)) {
        return SetError(error, "failed to allocate a Vulkan readback buffer");
    }

    if (! m_tex_cmd) allocateCmd();

    const VkImageLayout           original_layout = image.layout;
    const VkImageSubresourceRange subresource_range {
        .aspectMask     = VK_IMAGE_ASPECT_COLOR_BIT,
        .baseMipLevel   = 0,
        .levelCount     = 1,
        .baseArrayLayer = 0,
        .layerCount     = 1,
    };
    const VkImageMemoryBarrier to_transfer_src {
        .sType               = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .pNext               = nullptr,
        .srcAccessMask       = VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT,
        .dstAccessMask       = VK_ACCESS_TRANSFER_READ_BIT,
        .oldLayout           = original_layout,
        .newLayout           = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image               = image.handle,
        .subresourceRange    = subresource_range,
    };
    const VkImageMemoryBarrier restore_layout {
        .sType               = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .pNext               = nullptr,
        .srcAccessMask       = VK_ACCESS_TRANSFER_READ_BIT,
        .dstAccessMask       = VK_ACCESS_MEMORY_READ_BIT,
        .oldLayout           = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        .newLayout           = original_layout,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image               = image.handle,
        .subresourceRange    = subresource_range,
    };
    const VkBufferImageCopy copy_region {
        .bufferOffset      = 0,
        .bufferRowLength   = 0,
        .bufferImageHeight = 0,
        .imageSubresource =
            VkImageSubresourceLayers {
                .aspectMask     = VK_IMAGE_ASPECT_COLOR_BIT,
                .mipLevel       = 0,
                .baseArrayLayer = 0,
                .layerCount     = 1,
            },
        .imageOffset = VkOffset3D { static_cast<int32_t>(x), static_cast<int32_t>(y), 0 },
        .imageExtent = VkExtent3D { sample_width, sample_height, 1 },
    };
    std::array                  copy_regions { copy_region };
    const VkBufferMemoryBarrier host_barrier {
        .sType               = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
        .pNext               = nullptr,
        .srcAccessMask       = VK_ACCESS_TRANSFER_WRITE_BIT,
        .dstAccessMask       = VK_ACCESS_HOST_READ_BIT,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .buffer              = *readback_buffer.handle,
        .offset              = 0,
        .size                = byte_count,
    };

    VkResult result = m_tex_cmd.Begin(VkCommandBufferBeginInfo {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = nullptr,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    });
    if (result != VK_SUCCESS) {
        VVK_CHECK(result);
        return SetError(error, "failed to begin command buffer for video readback");
    }

    m_tex_cmd.PipelineBarrier(
        VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, to_transfer_src);
    m_tex_cmd.CopyImageToBuffer(
        image.handle, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, *readback_buffer.handle, copy_regions);
    m_tex_cmd.PipelineBarrier(
        VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, host_barrier);
    m_tex_cmd.PipelineBarrier(
        VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, restore_layout);

    result = m_tex_cmd.End();
    if (result != VK_SUCCESS) {
        VVK_CHECK(result);
        return SetError(error, "failed to end command buffer for video readback");
    }

    const VkSubmitInfo submit_info {
        .sType              = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .pNext              = nullptr,
        .commandBufferCount = 1,
        .pCommandBuffers    = m_tex_cmd.address(),
    };
    std::array submit_infos { submit_info };
    result = m_device.graphics_queue().handle.Submit(submit_infos);
    if (result != VK_SUCCESS) {
        VVK_CHECK(result);
        return SetError(error, "failed to submit Vulkan readback command buffer");
    }

    result = m_device.handle().WaitIdle();
    if (result != VK_SUCCESS) {
        VVK_CHECK(result);
        return SetError(error, "failed to idle Vulkan device after video readback");
    }

    void* mapped_bytes = nullptr;
    result             = readback_buffer.handle.MapMemory(&mapped_bytes);
    if (result != VK_SUCCESS || mapped_bytes == nullptr) {
        if (result != VK_SUCCESS) VVK_CHECK(result);
        return SetError(error, "failed to map Vulkan readback buffer");
    }
    result = vmaInvalidateAllocation(m_device.vma_allocator(), readback_buffer.handle.Allocation(),
                                     0, VK_WHOLE_SIZE);
    if (result != VK_SUCCESS) {
        readback_buffer.handle.UnMapMemory();
        return SetError(error, "failed to invalidate Vulkan readback buffer");
    }

    if (half_float) {
        out->resize(byte_count / 2);
        const auto* source = static_cast<const uint16_t*>(mapped_bytes);
        for (size_t i = 0; i < out->size(); ++i) {
            (*out)[i] = static_cast<uint8_t>(std::lround(
                std::clamp(HalfFloatToFloat(source[i]), 0.0f, 1.0f) * 255.0f));
        }
    } else {
        out->resize(byte_count);
        memcpy(out->data(), mapped_bytes, byte_count);
    }
    readback_buffer.handle.UnMapMemory();
    return true;
}

std::size_t TextureKey::HashValue(const TextureKey& k) {
    std::size_t seed { 0 };
    utils::hash_combine(seed, k.width);
    utils::hash_combine(seed, k.height);
    utils::hash_combine(seed, (int)k.usage);
    utils::hash_combine(seed, (int)k.format);
    utils::hash_combine(seed, (int)k.mipmap_level);
    utils::hash_combine(seed, (int)k.sample_count);

    utils::hash_combine(seed, (int)k.sample.wrapS);
    utils::hash_combine(seed, (int)k.sample.wrapT);
    utils::hash_combine(seed, (int)k.sample.magFilter);
    utils::hash_combine(seed, (int)k.sample.minFilter);
    utils::hash_combine(seed, (int)k.sample.mipFilter);
    return seed;
}

std::optional<ExImageParameters> TextureCache::CreateExTex(uint32_t width, uint32_t height,
                                                           VkFormat format, VkImageTiling tiling) {
    VkSamplerCreateInfo sampler_info = GenRenderTargetSamplerInfo();

    auto opt = CreateExImage(width,
                             height,
                             format,
                             tiling,
                             sampler_info,
                             VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
                                 VK_IMAGE_USAGE_TRANSFER_DST_BIT,
                             m_device.device(),
                             m_device.gpu());
    if (opt.has_value()) {
        const auto& eximg = opt.value();

        if (! m_tex_cmd) allocateCmd();
        TransImgLayout(m_device.graphics_queue().handle, m_tex_cmd, eximg, VK_IMAGE_LAYOUT_GENERAL);
        VVK_CHECK(m_device.handle().WaitIdle());
    }
    return opt;
}

ImageSlotsRef TextureCache::CreateTex(Image& image) {
    return CreateTex(image, TextureUploadSynchronization::Blocking);
}

ImageSlotsRef TextureCache::CreateTex(Image& image, const video::VideoPlaybackState& video_state) {
    return CreateTex(image, TextureUploadSynchronization::Blocking, video_state);
}

ImageSlotsRef TextureCache::CreateTex(Image& image, TextureUploadSynchronization synchronization,
                                      const video::VideoPlaybackState& video_state) {
    if (m_device_lost) {
        LOG_ERROR("cannot create texture after device loss");
        return {};
    }
    if (image.header.isVideo) {
        // Open already, or set aside by the rebuild that this is the compile of.
        // A pass that asked `FindVideoTex` first never gets here for one: this is
        // for an image that was read before the cache was asked, or under a name
        // other than the one it is bound by.
        if (auto open = FindVideoTex(image.key, video_state)) return std::move(*open);

        std::string error;
        // Goes through the registry rather than straight to the factory: when
        // shared decode is on and another surface already has this media open,
        // this returns a consumer handle onto that running decoder instead of
        // starting a second one. With sharing off it is a private source, as
        // before.
        auto source = video::AcquireVideoTextureSource(image, &error);
        if (! source) {
            LOG_ERROR("failed to create FFmpeg video texture source for \"%s\": %s",
                      image.key.c_str(),
                      error.c_str());
            return {};
        }
        return CreateVideoTex(image, std::move(source), video_state);
    }

    if (auto cached = m_tex_map.find(image.key); cached != m_tex_map.end()) {
        return ImageSlotsRef(cached->second);
    }

    ImageSlots img_slots;
    bool       submitted_upload = false;
    auto       fail_texture_upload       = [&]() -> ImageSlotsRef {
        if (submitted_upload) {
            m_retired_runtime_textures.emplace_back(
                std::make_shared<ImageSlots>(std::move(img_slots)));
            std::string error;
            if (! waitForPendingTextureUploads(&error) && ! error.empty()) {
                LOG_ERROR(
                    "failed waiting for pending texture upload after texture load failure: %s",
                    error.c_str());
            }
        }
        return {};
    };


    img_slots.slots.resize(image.slots.size());

    auto& sam = image.header.sample;

    for (usize i = 0; i < image.slots.size(); i++) {
        auto& image_paras   = img_slots.slots[i];
        auto& image_slot    = image.slots[i];
        auto  mipmap_levels = image_slot.mipmaps.size();

        // check data
        if (! image_slot) return fail_texture_upload();
        VkSamplerCreateInfo sampler_info {
            .sType                   = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            .pNext                   = nullptr,
            .magFilter               = ToVkType(sam.magFilter),
            .minFilter               = (ToVkType(sam.minFilter)),
            .mipmapMode              = ToVkMipmapMode(sam),
            .addressModeU            = (ToVkType(sam.wrapS)),
            .addressModeV            = (ToVkType(sam.wrapT)),
            .addressModeW            = (ToVkType(sam.wrapT)),
            .anisotropyEnable        = (false),
            .maxAnisotropy           = (1.0f),
            .compareEnable           = (false),
            .compareOp               = VK_COMPARE_OP_NEVER,
            .minLod                  = (0.0f),
            .maxLod                  = (float)mipmap_levels,
            .borderColor             = VK_BORDER_COLOR_INT_OPAQUE_BLACK,
            .unnormalizedCoordinates = (false),
        };
        VkFormat   format = ToVkType(image.header.format);
        VkExtent3D ext { (u32)image_slot.width, (u32)image_slot.height, 1 };

        if (auto opt = CreateImage(m_device,
                                   ext,
                                   (u32)mipmap_levels,
                                   format,
                                   sampler_info,
                                   VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT);
            opt.has_value()) {
            image_paras = std::move(opt.value());
        } else
            return fail_texture_upload();

        std::vector<VmaBufferParameters> stage_bufs;
        std::vector<VkExtent3D>          extents;

        for (usize j = 0; j < image_slot.mipmaps.size(); j++) {
            auto&               image_data = image_slot.mipmaps[j];
            VmaBufferParameters buf;
            if (image_data.size <= 0) return fail_texture_upload();
            const auto image_data_size = static_cast<std::size_t>(image_data.size);
            if (! CreateStagingBuffer(m_device.vma_allocator(), image_data_size, buf)) {
                return fail_texture_upload();
            }
            {
                void* v_data;
                VVK_CHECK(buf.handle.MapMemory(&v_data));
                memcpy(v_data, image_data.data.get(), image_data_size);
                buf.handle.UnMapMemory();
            }
            stage_bufs.emplace_back(std::move(buf));
            extents.push_back(VkExtent3D { (u32)image_data.width, (u32)image_data.height, 1 });
        }

        std::string error;
        auto* upload_slot = acquireTextureUploadSubmissionSlot(&error);
        if (upload_slot == nullptr) {
            LOG_ERROR("failed to acquire texture upload slot for \"%s\": %s",
                      image.key.c_str(), error.c_str());
            return fail_texture_upload();
        }
        const VkResult result =
            CopyImageData(transform<VmaBufferParameters>(stage_bufs,
                                                         [](BufferParameters e) { return e; }),
                          extents, m_device.graphics_queue().handle, upload_slot->command,
                          image_paras, *upload_slot->fence);
        if (result != VK_SUCCESS) {
            if (upload_slot->command.Reset() != VK_SUCCESS) {
                upload_slot->command = {};
                upload_slot->commands = {};
            }
            upload_slot->fence = {};
            LOG_ERROR("texture upload submission failed: %d", result);
            return fail_texture_upload();
        }
        upload_slot->staging_buffers = std::move(stage_bufs);
        upload_slot->pending = true;
        upload_slot->submitted_serial = ++m_texture_upload_submit_serial;
        submitted_upload = true;
        if (synchronization == TextureUploadSynchronization::Blocking &&
            !waitForTextureUploadSlot(*upload_slot, &error)) {
            LOG_ERROR("failed waiting for texture upload for \"%s\": %s",
                      image.key.c_str(), error.c_str());
            return fail_texture_upload();
        }
    }
    auto stored        = std::make_shared<ImageSlots>(std::move(img_slots));
    m_tex_map[image.key] = stored;
    return ImageSlotsRef(stored);
}

std::optional<ImageSlotsRef> TextureCache::FindTex(std::string_view key) const {
    const auto cached = m_tex_map.find(key);
    if (cached == m_tex_map.end()) return std::nullopt;
    return ImageSlotsRef(cached->second);
}

ImageSlotsRef TextureCache::currentVideoSlots(const VideoTex& video_tex) const {
    ImageSlotsRef ref;
    if (auto* current = video_tex.current_frame; current != nullptr) {
        ref.slots = { ImageParameters(current->image) };
        for (const auto& owner : video_tex.imported_frames) {
            if (owner.get() == current) {
                ref.video_frame_owner = owner;
                break;
            }
        }
        ref.active = 0;
    }
    return ref;
}

std::optional<ImageSlotsRef> TextureCache::FindVideoTex(
    std::string_view key, const video::VideoPlaybackState& video_state) {
    if (m_device_lost) return std::nullopt;
    if (const auto open = m_video_tex_map.find(key); open != m_video_tex_map.end()) {
        return currentVideoSlots(*open->second);
    }
    const auto held = m_held_video_tex_map.find(key);
    if (held == m_held_video_tex_map.end()) return std::nullopt;

    // The decoder carries on from the frame it had, given the scene's clock as it is
    // now; it is not opened again, so it has no seek to the clock to make when the
    // rebuild took less than the second a frame is let to lag.
    const std::string name(key);
    m_video_tex_map[name] = std::move(held->second);
    m_held_video_tex_map.erase(held);
    ImageSlotsRef ref;
    std::string   error;
    if (! UpdateVideoFrame(name, video_state, &ref, &error)) {
        LOG_ERROR("video texture \"%s\" did not survive the rebuild, opening it again: %s",
                  name.c_str(), error.c_str());
        m_video_tex_map.erase(name);
        return std::nullopt;
    }
    return ref;
}

ImageSlotsRef TextureCache::CreateVideoTex(
    Image& image, std::shared_ptr<video::VideoTextureSource> source,
    const video::VideoPlaybackState& video_state) {
    if (m_device_lost || !source || exists(m_video_tex_map, image.key)) {
        LOG_ERROR("cannot register video texture \"%s\"", image.key.c_str());
        return {};
    }
    std::string error;
    if (!source->prime(&error)) {
        LOG_ERROR("failed to prime FFmpeg video texture source for \"%s\": %s",
                  image.key.c_str(), error.c_str());
        return {};
    }
    auto video_tex = std::make_unique<VideoTex>();
    video_tex->sample = image.header.sample;
    video_tex->source = std::move(source);
    m_video_tex_map[image.key] = std::move(video_tex);
    ImageSlotsRef ref;
    // The first update gives the source the scene's clock, which is not the head
    // of the clip when the graph is built again under a playing video: the seek to
    // it starts now, and the head of the clip is on offer until it lands.
    if (!UpdateVideoFrame(image.key, video_state, &ref, &error)) {
        LOG_ERROR("failed to import initial video frame for \"%s\": %s",
                  image.key.c_str(), error.c_str());
        m_video_tex_map.erase(image.key);
        return {};
    }
    return ref;
}

ImageSlotsRef TextureCache::ReplaceTex(Image& image, std::string_view previous_key) {
    auto replacement = CreateTex(image, TextureUploadSynchronization::Deferred);
    if (! replacement.slots.empty() && ! previous_key.empty() && previous_key != image.key) {
        retireRuntimeTexture(previous_key);
    }
    return replacement;
}

void TextureCache::allocateCmd() {
    const auto& pool = m_device.cmd_pool();
    VVK_CHECK(pool.Allocate(1, VK_COMMAND_BUFFER_LEVEL_PRIMARY, m_tex_cmds));
    m_tex_cmd = vvk::CommandBuffer(m_tex_cmds[0], m_device.handle().Dispatch());
}

TextureCache::TextureUploadSubmissionSlot*
TextureCache::acquireTextureUploadSubmissionSlot(std::string* error) {
    collectCompletedTextureUploads();
    for (auto& slot : m_texture_upload_slots) {
        if (!slot.pending) return ensureTextureUploadSlot(slot, error) ? &slot : nullptr;
    }

    if (m_texture_upload_slots.size() >= kMaxPendingTextureUploads) {
        auto oldest = std::min_element(
            m_texture_upload_slots.begin(),
            m_texture_upload_slots.end(),
            [](const TextureUploadSubmissionSlot& lhs, const TextureUploadSubmissionSlot& rhs) {
                return lhs.submitted_serial < rhs.submitted_serial;
            });
        if (oldest == m_texture_upload_slots.end()) {
            SetError(error, "texture upload submission slot accounting is invalid");
            return nullptr;
        }
        if (! waitForTextureUploadSlot(*oldest, error)) return nullptr;
        return ensureTextureUploadSlot(*oldest, error) ? &*oldest : nullptr;
    }

    TextureUploadSubmissionSlot slot;
    if (!ensureTextureUploadSlot(slot, error)) return nullptr;

    m_texture_upload_slots.emplace_back(std::move(slot));
    return &m_texture_upload_slots.back();
}

bool TextureCache::ensureTextureUploadSlot(TextureUploadSubmissionSlot& slot, std::string* error) {
    if (slot.pending) return SetError(error, "cannot reuse pending texture upload slot");
    if (!slot.command) {
        if (m_device.cmd_pool().Allocate(1, VK_COMMAND_BUFFER_LEVEL_PRIMARY, slot.commands) != VK_SUCCESS) {
            return SetError(error, "failed to allocate texture upload command buffer");
        }
        slot.command = vvk::CommandBuffer(slot.commands[0], m_device.handle().Dispatch());
    }
    if (slot.fence) return true;
    const VkFenceCreateInfo info {
        .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
        .pNext = nullptr,
        .flags = 0,
    };
    if (m_device.handle().CreateFence(info, slot.fence) != VK_SUCCESS) {
        return SetError(error, "failed to create Vulkan fence for texture upload");
    }
    return true;
}

bool TextureCache::waitForTextureUploadSlot(TextureUploadSubmissionSlot& slot, std::string* error) {
    if (! slot.pending) return true;

    if (const VkResult result = slot.fence.Wait(); result != VK_SUCCESS) {
        LOG_ERROR("texture upload wait failed: %d", result);
        return SetError(error, "failed waiting for pending texture upload");
    }
    slot.staging_buffers.clear();
    slot.pending = false;
    slot.submitted_serial = 0;
    if (const VkResult result = slot.fence.Reset(); result != VK_SUCCESS) {
        slot.fence = {};
        LOG_ERROR("texture upload fence reset failed: %d", result);
        return SetError(error, "failed resetting texture upload fence");
    }

    return true;
}

bool TextureCache::waitForPendingTextureUploads(std::string* error) {
    for (auto& slot : m_texture_upload_slots) {
        if (! waitForTextureUploadSlot(slot, error)) return false;
    }
    m_retired_runtime_textures.clear();
    return true;
}

void TextureCache::collectCompletedTextureUploads() {
    bool any_pending = false;
    for (auto& slot : m_texture_upload_slots) {
        if (! slot.pending) continue;
        if (slot.fence.GetStatus() != VK_SUCCESS) {
            any_pending = true;
            continue;
        }
        std::string error;
        if (! waitForTextureUploadSlot(slot, &error)) {
            if (! error.empty()) {
                LOG_ERROR("failed collecting completed texture upload: %s", error.c_str());
            }
            any_pending = true;
            continue;
        }
    }
    if (! any_pending) m_retired_runtime_textures.clear();
}

void TextureCache::retireRuntimeTexture(std::string_view key) {
    auto iter = m_tex_map.find(key);
    if (iter == m_tex_map.end()) return;
    // Retires the name, not necessarily the memory. Two runtime names can
    // alias one image — a cover change makes `$mediaPreviousThumbnail` hold
    // exactly what `$mediaThumbnail` held — so a pass still bound to it keeps
    // its own reference and the image goes when the last holder does, not
    // when this key is dropped.
    m_retired_runtime_textures.emplace_back(std::move(iter->second));
    m_tex_map.erase(iter);
}

void TextureCache::CollectCompletedUploads() { collectCompletedTextureUploads(); }

std::shared_ptr<TextureCache::VideoImportImage>
TextureCache::importedImageFor(void* metal_texture, uint32_t width, uint32_t height, bool pooled,
                               std::string* error) {
    // A pooled destination keeps the image made for it the first time, for as
    // long as the pool keeps the destination: same texture, same extent, same
    // device, so the alias is the same one. The pool drops it with the
    // destination, which is what stops a recycled address meeting a stale one.
    pooled = pooled && m_video_destination_pool;
    if (pooled) {
        if (auto companion = m_video_destination_pool->DestinationCompanion(metal_texture)) {
            ++m_video_submission_stats.imported_images_reused;
            return std::static_pointer_cast<VideoImportImage>(std::move(companion));
        }
    }
    auto image = CreateImportedMetalTextureImage(m_device, metal_texture, width, height, error);
    if (! image) return nullptr;
    auto imported = std::make_shared<VideoImportImage>();
    imported->image = std::move(*image);
    ++m_video_submission_stats.imported_images_created;
    m_video_first_use_pending.push_back(imported);
    if (pooled) m_video_destination_pool->SetDestinationCompanion(metal_texture, imported);
    return imported;
}

void TextureCache::RecordVideoFirstUseTransitions(vvk::CommandBuffer& command) {
    if (m_device_lost || m_video_frame_state != VideoFrameState::Recording) {
        LOG_ERROR("cannot record video first-use transitions outside frame recording");
        return;
    }
    for (const auto& pending : m_video_first_use_pending) {
        auto imported = pending.lock();
        if (! imported || imported->layout != VideoImportImage::Layout::Undefined) continue;
        const VkImageMemoryBarrier barrier {
            .sType               = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext               = nullptr,
            .srcAccessMask       = 0,
            .dstAccessMask       = VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_TRANSFER_READ_BIT,
            .oldLayout           = VK_IMAGE_LAYOUT_UNDEFINED,
            .newLayout           = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .image               = *imported->image.handle,
            .subresourceRange    = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 },
        };
        command.PipelineBarrier(VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                                VK_PIPELINE_STAGE_VERTEX_SHADER_BIT |
                                    VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT |
                                    VK_PIPELINE_STAGE_TRANSFER_BIT,
                                0,
                                barrier);
        imported->layout = VideoImportImage::Layout::TransitionRecorded;
        ++m_video_submission_stats.first_use_transitions_recorded;
        // The command buffer now names the image, so the frame keeps it alive
        // until the frame's fence has signalled.
        m_video_frame_pins.push_back(imported);
        m_video_first_use_recorded.push_back(std::move(imported));
    }
    m_video_first_use_pending.clear();
}

VkSampler TextureCache::GetOrCreateSampler(TextureKey tex_key, std::string* error) {
    const TexHash hash = TextureKey::HashValue(tex_key);
    for (auto& entry : m_sampler_cache) {
        if (entry.hash == hash && entry.sampler) return *entry.sampler;
    }

    CachedSampler entry {};
    entry.hash = hash;
    if (const VkResult result =
            m_device.handle().CreateSampler(GenSamplerInfo(tex_key), entry.sampler);
        result != VK_SUCCESS) {
        LOG_ERROR("cached video sampler creation failed: %d", result);
        SetError(error, "failed to create cached Vulkan sampler");
        return VK_NULL_HANDLE;
    }
    const VkSampler sampler = *entry.sampler;
    m_sampler_cache.push_back(std::move(entry));
    return sampler;
}

void* TextureCache::GetMetalDeviceHandle(std::string* error) {
    if (m_metal_device != nullptr) return m_metal_device;
    if (m_metal_device_queried) {
        SetError(error, "cached Metal device handle is not available");
        return nullptr;
    }
    m_metal_device         = ExportMetalHandles(m_device, &m_metal_command_queue, error);
    m_metal_device_queried = true;
    return m_metal_device;
}

std::optional<VmaImageParameters> TextureCache::CreateTex(TextureKey tex_key) {
    VmaImageParameters image_paras;
    do {
        const VkSampleCountFlagBits planned_samples =
            PlannedTextureSampleCountForGpuAllocation(tex_key);
        const bool          is_depth = tex_key.usage == TexUsage::DEPTH;
        VkSamplerCreateInfo sam_info = GenSamplerInfo(tex_key);
        VkFormat            format   = is_depth ? VK_FORMAT_D32_SFLOAT : ToVkType(tex_key.format);
        VkExtent3D          ext { (u32)tex_key.width, (u32)tex_key.height, 1 };
        const VkImageUsageFlags usage =
            is_depth ? VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT
                     : (VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT |
                        VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT);

        if (auto opt = CreateImage(m_device,
                                   ext,
                                   tex_key.mipmap_level,
                                   format,
                                   sam_info,
                                   usage,
                                   VMA_MEMORY_USAGE_GPU_ONLY,
                                   planned_samples);
            opt.has_value()) {
            image_paras = std::move(opt.value());
        } else
            break;

        const VkImageLayout final_layout =
            is_depth ? VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL
                     : (planned_samples == VK_SAMPLE_COUNT_1_BIT
                            ? VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
                            : VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL);

        // A target starts empty, as on the Metal backend: an effect's history
        // buffer that the frame reads before it draws, or an input nothing
        // draws, must read as nothing on its first frame. Only single-sample
        // colour images are sampled; depth and multisampled colour are not.
        // Once, here, where the allocation already waits for the GPU: no
        // frame pays for it.
        const bool zero = ! is_depth && planned_samples == VK_SAMPLE_COUNT_1_BIT;
        if (! m_tex_cmd) allocateCmd();
        TransImgLayout(m_device.graphics_queue().handle,
                       m_tex_cmd,
                       image_paras,
                       final_layout,
                       VK_NULL_HANDLE,
                       zero);
        image_paras.layout = final_layout;

        VVK_CHECK_ACT(break, m_device.handle().WaitIdle());
        return image_paras;
    } while (false);
    return std::nullopt;
}

TextureCache::TextureCache(const Device& device): m_device(device) {}

TextureCache::~TextureCache() {
    if (m_device_lost) return;
    std::string error;
    if (Clear(&error)) return;
    // Final destruction cannot leave retained GPU owners behind. The renderer destroys
    // its command owners before this boundary; standalone users must do the same.
    const VkResult result = m_device.handle().WaitIdle();
    if (result == VK_ERROR_DEVICE_LOST) {
        DiscardAfterDeviceLoss();
        return;
    }
    if (result != VK_SUCCESS) {
        LOG_ERROR("cannot destroy renderer resources before GPU completion");
        std::terminate();
    }
    InvalidateVideoDestinationPool();
    m_video_first_use_recorded.clear();
    m_video_first_use_pending.clear();
    for (auto& slot : m_texture_upload_slots) {
        slot.command = {};
        slot.commands = {};
        slot.pending = false;
        slot.staging_buffers.clear();
    }
    m_video_frame_pins.clear();
    m_video_frame_state = VideoFrameState::Idle;
}

void TextureCache::SetVideoPlaybackPaused(bool paused) { m_video_playback_state.paused = paused; }

void TextureCache::SetVideoPlaybackRate(float rate) { m_video_playback_state.rate = rate; }

void TextureCache::SetCounters(RendererCounters* counters) { m_counters = counters; }

void TextureCache::publishVideoSourceIdentity() {
    if (m_counters == nullptr) return;
    // A single decoder is identifiable, so its source work can be attributed
    // and de-duplicated. Zero or several is not: reporting one of their ids
    // would attribute the whole cache's decode work to one of them, so the
    // identity reads as unknown instead.
    uint64_t live_sources = 0;
    uint64_t single_instance = 0;
    for (const auto& [key, video_tex] : m_video_tex_map) {
        if (video_tex == nullptr || video_tex->source == nullptr) continue;
        ++live_sources;
        single_instance = video_tex->source->sourceStats().instance_id;
    }
    m_counters->Set(OWE_RC_VIDEO_SOURCE_COUNT, live_sources);
    m_counters->Set(OWE_RC_VIDEO_SOURCE_INSTANCE, live_sources == 1 ? single_instance : 0);
}

double TextureCache::ShortestVideoFramePeriod() const {
    double shortest = 0.0;
    for (const auto& [key, video_tex] : m_video_tex_map) {
        if (video_tex == nullptr || video_tex->source == nullptr) continue;
        const double period = video_tex->source->frameDurationSeconds();
        if (! (period > 0.0)) {
            // A source that cannot report its rate makes the whole answer
            // unknown: pacing on the others could skip its changes.
            return 0.0;
        }
        if (shortest == 0.0 || period < shortest) shortest = period;
    }
    return shortest;
}

VideoTextureSubmissionStats TextureCache::VideoSubmissionStats() const {
    auto stats                    = m_video_submission_stats;
    if (m_video_destination_pool) {
        const auto pool = m_video_destination_pool->Stats();
        stats.pool_cached_texture_count = pool.cached_texture_count;
        stats.pool_cached_bytes = pool.cached_bytes;
        stats.pool_peak_cached_bytes = pool.peak_cached_bytes;
        stats.pool_checked_out_bytes = pool.checked_out_bytes;
        stats.pool_awaiting_gpu_bytes = pool.awaiting_gpu_bytes;
        stats.pool_live_bytes = pool.live_bytes;
        stats.pool_peak_live_bytes = pool.peak_live_bytes;
        stats.pool_reserved_estimate_bytes = pool.reserved_estimate_bytes;
        stats.pool_over_ceiling_grants = pool.over_ceiling_grants;
        stats.pool_live_slot_count = pool.live_slot_count;
        stats.pool_hits = pool.hits;
        stats.pool_misses = pool.misses;
        stats.pool_recycles = pool.recycles;
        stats.pool_evictions = pool.evictions;
        stats.pool_refusals = pool.refusals;
        stats.pool_in_flight_cap_breaches = pool.in_flight_cap_breaches;
    }
    return stats;
}

void TextureCache::ResetVideoSubmissionStats() { m_video_submission_stats = {}; }

double TextureCache::GetVideoDuration(std::string_view key) const {
    const auto iterator = m_video_tex_map.find(std::string(key));
    if (iterator == m_video_tex_map.end() || iterator->second == nullptr ||
        ! iterator->second->source) {
        return 0.0;
    }
    return iterator->second->source->durationSeconds();
}

bool TextureCache::CanReuseVideoFrameImport(const video::VideoTextureFrame& frame) const {
    const bool is_nv12 = frame.pixel_format == 0x34323076u || frame.pixel_format == 0x34323066u;
    return !is_nv12 && !frame.needsDisplayTransform() && frame.io_surface != nullptr && frame.plane_count <= 1;
}

std::shared_ptr<TextureCache::ImportedVideoFrame>
TextureCache::FindImportedVideoFrame(VideoTex& video_tex, const video::VideoTextureFrame& frame,
                                     void* surface_identity) const {
    const bool can_reuse_surface_import = CanReuseVideoFrameImport(frame);
    for (auto& imported_frame : video_tex.imported_frames) {
        if (imported_frame == nullptr) continue;
        if (imported_frame->surface_identity != surface_identity) continue;
        if (imported_frame->pixel_format != frame.pixel_format) continue;
        if (imported_frame->image.extent.width != frame.displayWidth() ||
            imported_frame->image.extent.height != frame.displayHeight()) {
            continue;
        }
        if (! can_reuse_surface_import && imported_frame->generation != frame.generation) {
            continue;
        }
        return imported_frame;
    }
    return nullptr;
}

bool TextureCache::EnsureVideoFrameCacheRoom(VideoTex& video_tex, std::string*) {
    while (video_tex.imported_frames.size() >= kMaxImportedVideoFramesPerVideoTex) {
        auto victim = video_tex.imported_frames.end();
        for (auto iter = video_tex.imported_frames.begin(); iter != video_tex.imported_frames.end();
             ++iter) {
            if (iter->get() == video_tex.current_frame) continue;
            if (victim == video_tex.imported_frames.end() ||
                (*iter)->last_used < (*victim)->last_used) {
                victim = iter;
            }
        }
        if (victim == video_tex.imported_frames.end()) return true;
        ++m_video_submission_stats.evictions;
        video_tex.imported_frames.erase(victim);
    }
    return true;
}

void TextureCache::observeVideoConsumer(VideoTex& video_tex) {
    // Only a recording cycle delimits a consumer set. Outside one there is
    // nothing to attribute a call to, so the last observed figure stands.
    if (m_video_frame_state != VideoFrameState::Recording) return;
    if (video_tex.consumer_cycle_serial != m_video_recording_serial) {
        // A cycle closed. Fold its tally into a high-water mark rather than
        // replacing it, because the count that matters is how many consumers
        // are HOLDING a destination, not how many asked this cycle. A hidden
        // layer does not call in at all and still retains the frame it last
        // received, so the cycle in which it went quiet would otherwise drop
        // it from the figure — which is exactly the consumer the expectation
        // needs to cover. Over-counting a consumer that has left for good only
        // loosens a reporting threshold; under-counting one that is merely
        // quiet reports every ordinary scene as a leak.
        video_tex.observed_consumers =
            std::max(video_tex.observed_consumers, video_tex.consumers_in_cycle);
        video_tex.consumer_cycle_serial = m_video_recording_serial;
        video_tex.consumers_in_cycle = 0;
    }
    if (video_tex.consumers_in_cycle != std::numeric_limits<uint32_t>::max()) {
        ++video_tex.consumers_in_cycle;
    }
}

std::uint32_t TextureCache::videoInFlightSlotExpectation() const {
    // Every consumer of a video texture retains one imported frame in its own
    // ImageSlotsRef — one per slot, never a list — so the destinations this
    // cache can legitimately hold in flight are its unretired import
    // submissions plus, per video texture, its imported-frame cap and its
    // consumers. Anything beyond this is a destination that stopped being
    // returned, which is what the pool's breach counter is for.
    std::uint64_t slots = kMaxPendingVideoImportSubmissions;
    for (const auto& [key, video_tex] : m_video_tex_map) {
        if (video_tex == nullptr) continue;
        // The larger of the closed cycle and the one in progress, so a
        // consumer set that is still filling is covered in the cycle it grows
        // in rather than a cycle later.
        const std::uint64_t consumers =
            std::max(video_tex->observed_consumers, video_tex->consumers_in_cycle);
        slots += kMaxImportedVideoFramesPerVideoTex + consumers;
    }
    // A cache with no video texture registered yet still imports its first
    // frame, so never publish less than one video texture's worth.
    const std::uint64_t floor = kMaxPendingVideoImportSubmissions +
                                kMaxImportedVideoFramesPerVideoTex;
    return static_cast<std::uint32_t>(
        std::min<std::uint64_t>(std::max(slots, floor), std::numeric_limits<std::uint32_t>::max()));
}

bool TextureCache::BeginVideoFrameRecording(std::string* error) {
    if (m_device_lost || m_video_frame_state != VideoFrameState::Idle ||
        m_video_recording_serial == std::numeric_limits<uint64_t>::max()) {
        LOG_ERROR("cannot begin video frame recording before prior frame retirement");
        return SetError(error, "cannot begin video frame recording before prior frame retirement");
    }
    ++m_video_recording_serial;
    m_video_frame_state = VideoFrameState::Recording;
    return true;
}

void TextureCache::PinVideoFrame(const ImageSlotsRef& ref) {
    if (!ref.video_frame_owner) return;
    if (m_device_lost || m_video_frame_state != VideoFrameState::Recording) {
        LOG_ERROR("cannot pin video frame outside frame recording");
        return;
    }
    const auto* frame = static_cast<const ImportedVideoFrame*>(ref.video_frame_owner.get());
    if (frame->last_pinned_recording == m_video_recording_serial) return;
    m_video_frame_pins.push_back(ref.video_frame_owner);
    frame->last_pinned_recording = m_video_recording_serial;
}

void TextureCache::MarkVideoFrameSubmitted() {
    if (m_device_lost || m_video_frame_state != VideoFrameState::Recording) {
        LOG_ERROR("cannot submit video frame outside frame recording");
        return;
    }
    // Submitted means ordered ahead of every later use on this queue, so the
    // transitions this frame recorded are done as far as later frames go.
    for (const auto& imported : m_video_first_use_recorded) {
        imported->layout = VideoImportImage::Layout::ShaderReadOnly;
    }
    m_video_first_use_recorded.clear();
    m_video_frame_state = VideoFrameState::Submitted;
}

void TextureCache::CompleteVideoFrame() {
    if (m_video_frame_state != VideoFrameState::Submitted) {
        LOG_ERROR("cannot complete video frame without a submitted draw");
        return;
    }
    m_video_frame_pins.clear();
    m_video_frame_state = VideoFrameState::Idle;
}

void TextureCache::AbandonVideoFrameRecording() {
    if (m_video_frame_state != VideoFrameState::Recording) {
        LOG_ERROR("cannot abandon video frame outside unsubmitted recording");
        return;
    }
    // The discarded command buffer took its transitions with it; the next
    // frame records them again.
    for (auto& imported : m_video_first_use_recorded) {
        imported->layout = VideoImportImage::Layout::Undefined;
        m_video_first_use_pending.push_back(imported);
    }
    m_video_first_use_recorded.clear();
    m_video_frame_pins.clear();
    m_video_frame_state = VideoFrameState::Idle;
}

void TextureCache::InvalidateVideoDestinationPool() {
    m_video_recycling_disabled = true;
    m_video_destination_pool.reset();
}

bool TextureCache::WaitForPendingUploads(std::string* error) {
    if (m_device_lost) return SetError(error, "cannot wait for uploads after device loss");
    return waitForPendingTextureUploads(error);
}

void TextureCache::DiscardAfterDeviceLoss() noexcept {
    m_device_lost = true;
    InvalidateVideoDestinationPool();
    // No work can be submitted again on this device. Discard commands before their
    // referenced owners, and never recycle their converted Metal destinations.
    m_tex_cmd = {};
    m_tex_cmds = {};
    m_video_first_use_recorded.clear();
    m_video_first_use_pending.clear();
    for (auto& slot : m_texture_upload_slots) {
        slot.command = {};
        slot.commands = {};
        slot.pending = false;
        slot.staging_buffers.clear();
    }
    m_texture_upload_slots.clear();
    m_video_frame_pins.clear();
    m_video_frame_state = VideoFrameState::Idle;
    m_video_tex_map.clear();
    m_held_video_tex_map.clear();
    m_tex_map.clear();
    m_retired_runtime_textures.clear();
    m_query_map.clear();
    m_query_texs.clear();
    m_sampler_cache.clear();
}

bool TextureCache::Clear(std::string* error) { return clearCache(false, error); }

bool TextureCache::ClearForRebuild(std::string* error) { return clearCache(true, error); }

void TextureCache::CloseHeldVideos() {
    m_held_video_tex_map.clear();
    // The last word on which videos the new graph has open, for a rebuild that left
    // the last of them out as much as for one that kept it.
    publishVideoSourceIdentity();
}

bool TextureCache::clearCache(bool hold_videos, std::string* error) {
    if (m_device_lost) return SetError(error, "cannot clear texture cache after device loss");
    if (m_video_frame_state != VideoFrameState::Idle) {
        LOG_ERROR("cannot clear texture cache before video frame retirement");
        return SetError(error, "cannot clear texture cache before video frame retirement");
    }
    if (!WaitForPendingUploads(error)) return false;
    // Weak deleters attached to old owners cannot reach a newly created pool.
    m_video_destination_pool.reset();
    m_tex_map.clear();
    if (hold_videos) {
        // The decoder, and what is counted of it. The frames imported from it are
        // images of the device this graph drew with and go with the graph.
        for (auto& [key, video_tex] : m_video_tex_map) {
            if (video_tex == nullptr || video_tex->source == nullptr) continue;
            video_tex->current_frame = nullptr;
            video_tex->imported_frames.clear();
            m_held_video_tex_map.insert_or_assign(key, std::move(video_tex));
        }
    } else {
        m_held_video_tex_map.clear();
    }
    m_video_tex_map.clear();
    m_query_texs.clear();
    m_query_map.clear();
    m_video_recycling_disabled = false;
    return true;
}

/// Drops only the render-target textures, keeping uploaded images and live
/// video sources.
///
/// This is what makes an internal render-scale change cheap: render targets are
/// the only textures whose size depends on the scale, so evicting them alone
/// avoids re-uploading every wallpaper image and, more importantly, avoids
/// destroying the decoders in `m_video_tex_map` — which would reopen the file
/// and restart playback for what the user experiences as a quality slider.
bool TextureCache::ClearRenderTargets(std::string* error) {
    if (m_device_lost) {
        return SetError(error, "cannot clear render targets after device loss");
    }
    if (m_video_frame_state != VideoFrameState::Idle) {
        return SetError(error, "cannot clear render targets before video frame retirement");
    }
    if (! WaitForPendingUploads(error)) return false;
    m_query_map.clear();
    m_query_texs.clear();
    return true;
}

bool TextureCache::UpdateVideoFrame(std::string_view                 key,
                                    const video::VideoPlaybackState& playback_state,
                                    ImageSlotsRef* out, std::string* error) {
    ++m_video_submission_stats.update_calls;
    if (m_device_lost) return SetError(error, "cannot update video frame after device loss");
    if (! exists(m_video_tex_map, key)) {
        return SetError(error, std::string("video texture not registered: ") + std::string(key));
    }

    auto& video_tex = *m_video_tex_map.at(std::string(key));
    if (! video_tex.source) {
        return SetError(error, std::string("video texture source missing: ") + std::string(key));
    }

    // One call per consumer per recording cycle, so this is where the consumer
    // set is observed. It happens before any early return below: a consumer
    // that asked for a frame retains whatever it already holds whether or not
    // this update succeeds, so it counts either way.
    observeVideoConsumer(video_tex);

    const video::VideoPlaybackState effective_state =
        ResolveEffectiveVideoPlaybackState(m_video_playback_state, playback_state);

    if (! video_tex.source->syncPlayback(effective_state, error)) {
        return false;
    }
    if (! video_tex.source->refreshFrame(error)) {
        return false;
    }

    const auto frame = video_tex.source->currentFrame();
    if (! frame.valid()) {
        return SetError(error,
                        std::string("video frame is not ready for texture: ") + std::string(key));
    }

    if (m_counters != nullptr && RendererCounters::Enabled()) {
        // Source work: what the decoder instance produced, independently of
        // whether this consumer used it. Reported with the instance's own
        // identity so a roll-up can de-duplicate one decoder across consumers
        // without ever merging two decoders that read the same file.
        const auto stats = video_tex.source->sourceStats();
        if (video_tex.counters_stale) {
            // Updates ran while nothing was counting. This one only records
            // where the decoder and this consumer are now; reporting the gap
            // would attribute everything since then to this frame.
            video_tex.reported_decode_outputs = stats.decoded_frames;
            video_tex.reported_seeks          = stats.seek_requests;
            video_tex.selection.Reset();
            (void)video_tex.selection.Observe(frame.generation);
            video_tex.counters_stale = false;
            publishVideoSourceIdentity();
        } else {
            if (stats.decoded_frames > video_tex.reported_decode_outputs) {
                m_counters->Add(OWE_RC_VIDEO_DECODE_OUTPUTS,
                                stats.decoded_frames - video_tex.reported_decode_outputs);
                video_tex.reported_decode_outputs = stats.decoded_frames;
            }
            if (stats.seek_requests > video_tex.reported_seeks) {
                m_counters->Add(OWE_RC_VIDEO_SEEKS,
                                stats.seek_requests - video_tex.reported_seeks);
                video_tex.reported_seeks = stats.seek_requests;
            }
            publishVideoSourceIdentity();
            // Consumer work: which of those frames this update actually put on
            // screen, and how many it stepped over.
            const auto selection = video_tex.selection.Observe(frame.generation);
            if (selection.selected) {
                m_counters->Add(OWE_RC_VIDEO_FRAMES_SELECTED);
                m_counters->Set(OWE_RC_VIDEO_SELECTED_GENERATION, frame.generation);
            }
            if (selection.reused) m_counters->Add(OWE_RC_VIDEO_FRAMES_REUSED);
            if (selection.skipped > 0) {
                m_counters->Add(OWE_RC_VIDEO_FRAMES_SKIPPED, selection.skipped);
            }
        }
    } else {
        // Counters off: the decoder's mutex and the identity walk are not
        // taken at all, the same way the conversion-pool gauges below are not
        // read. What this update skipped is re-based on the next counted one.
        video_tex.counters_stale = true;
    }

    void* surface_identity = frame.io_surface != nullptr ? frame.io_surface : frame.pixel_buffer;
    auto imported_frame = FindImportedVideoFrame(video_tex, frame, surface_identity);
    if (imported_frame) {
        ++m_video_submission_stats.cache_hits;
        imported_frame->generation = frame.generation;
        imported_frame->pts_seconds = frame.pts_seconds;
        imported_frame->last_used = ++video_tex.frame_use_serial;
        video_tex.current_frame = imported_frame.get();
    } else {
        if (!EnsureVideoFrameCacheRoom(video_tex, error)) return false;
        void* metal_device = GetMetalDeviceHandle(error);
        if (metal_device == nullptr) return false;
        const bool converted = frame.pixel_format == 0x34323076u || frame.pixel_format == 0x34323066u || frame.needsDisplayTransform();
        if (converted && !m_video_recycling_disabled && !m_video_destination_pool) {
            m_video_destination_pool = std::make_shared<video::AppleVideoMetalTexturePool>(metal_device);
        }
        auto candidate = std::make_shared<ImportedVideoFrame>();
        if (converted && m_video_destination_pool) {
            // The in-flight slot expectation is a per-pool quantity built
            // from per-video-texture terms and from consumer retention, and
            // only this object can see either. It has to say so before it
            // asks, or an ordinary second wallpaper — or an ordinary scene
            // with several layers on one video — is reported as breaching a
            // threshold that never accounted for it.
            static_assert(video::kImportedVideoFramesPerSource ==
                              kMaxImportedVideoFramesPerVideoTex,
                          "FfmpegVideoInterop mirrors TextureCache's per-video-texture imported "
                          "frame cap; the two must stay equal");
            static_assert(video::kPendingVideoImportSubmissions ==
                              kMaxPendingVideoImportSubmissions,
                          "FfmpegVideoInterop mirrors TextureCache's pending import submission "
                          "cap; the two must stay equal");
            m_video_destination_pool->SetInFlightSlotExpectation(videoInFlightSlotExpectation());
            // A shape nothing requests any more is not worth its bytes. The
            // decoded frame's size is the only size that matters here; the
            // surface this ends up on never enters the key.
            m_video_destination_pool->RetainOnly(frame.displayWidth(), frame.displayHeight());
        }
        // Nothing may fail between borrowing or reserving a destination and
        // handing it to the import without unwinding the ledger: an abandoned
        // loan is a leaked slot, and an abandoned reservation is bytes the
        // budget believes are about to exist and never will.
        void* borrowed = converted && m_video_destination_pool
            ? m_video_destination_pool->Take(frame.displayWidth(), frame.displayHeight())
            : nullptr;
        // No reuse available: the import is about to allocate, so say so
        // before it does rather than discovering the bytes on the way back.
        video::AppleVideoConversionReservation reservation {};
        if (converted && m_video_destination_pool && borrowed == nullptr) {
            reservation = m_video_destination_pool->ReserveFresh(frame.displayWidth(), frame.displayHeight());
            if (! reservation.granted) {
                // The budget did not book this allocation, so there is no
                // allocation to make. Allocating anyway would hand back a
                // texture the ledger never learns about, which is exactly the
                // uncounted memory the reservation exists to prevent; this
                // frame's import fails instead and the previously imported
                // frame stays on screen.
                //
                // `ReserveFresh` has no refusal path — the in-flight slot
                // count is reported, never enforced, because withholding the
                // import is what stops destinations coming back at all — so
                // reaching here means a condition that genuinely cannot
                // allocate. Nothing was borrowed, nothing allocated, and an
                // unbooked reservation holds no estimate, so there is nothing
                // to unwind: `candidate` owns no lease and simply dies here.
                ++m_video_submission_stats.conversion_reservations_refused;
                if (! m_video_reservation_refusal_reported) {
                    m_video_reservation_refusal_reported = true;
                    LOG_INFO("video conversion destination not booked for \"%s\" (%ux%u); "
                             "importing this frame would allocate one nothing could account "
                             "for, so the previous frame stays on screen",
                             std::string(key).c_str(),
                             frame.displayWidth(),
                             frame.displayHeight());
                }
                return SetError(error,
                                std::string("video conversion destination was not booked: ") +
                                    std::string(key));
            }
            m_video_reservation_refusal_reported = false;
        }
        // A conversion this cache is actually going to perform. Counted after
        // the reservation, because a frame that never got a destination
        // converts nothing.
        if (converted) ++m_video_submission_stats.conversion_calls;
        // The lease keeps the Core Video wrapper and pixel buffer alive for as
        // long as this imported frame can be sampled; the texture below is
        // borrowed from it. The conversion goes onto the graphics queue's own
        // Metal queue and is not waited for: the frame that samples it is
        // submitted to the same queue afterwards, and Metal orders the two
        // through the tracked destination.
        bool  destination_allocation_failed = false;
        void* created = nullptr;
        void* lease = video::CreateAppleVideoFrameLease(frame, metal_device, borrowed, error,
                                                        &destination_allocation_failed, &created,
                                                        m_metal_command_queue);
        if (borrowed != nullptr) {
            if (lease != nullptr) {
                // The lease took an independent retain. The loan stays open
                // until the lease deleter reports GPU completion.
                video::ReleaseAppleVideoMetalTexture(borrowed);
            } else {
                m_video_destination_pool->EndLoan(borrowed);
            }
        }
        if (lease == nullptr) {
            if (m_video_destination_pool) {
                m_video_destination_pool->CancelFresh(reservation);
                if (destination_allocation_failed) {
                    m_video_destination_pool->ReportAllocationFailure(frame.displayWidth(), frame.displayHeight());
                }
            }
            return false;
        }
        if (m_video_destination_pool) {
            // Measured cost in, estimate out. A commit with no destination is
            // the cancel: the conversion reused something after all.
            m_video_destination_pool->CommitFresh(reservation, created);
        }
        void* metal_texture = video::AppleVideoFrameLeaseTexture(lease);
        if (converted) {
            if (borrowed != nullptr) ++m_video_submission_stats.converted_destinations_reused;
            else ++m_video_submission_stats.converted_destinations_created;
        }
        const std::weak_ptr<video::AppleVideoMetalTexturePool> pool =
            converted ? m_video_destination_pool : nullptr;
        candidate->frame_lease = std::shared_ptr<void>(lease, [pool](void* handle) {
            // Give a poolable conversion destination back before the lease
            // releases everything else it owns, each exactly once. The pool
            // holds it back until the conversion has completed on the GPU.
            if (auto owner = pool.lock()) {
                if (void* recyclable = video::TakeAppleVideoFrameLeaseDestination(handle)) {
                    owner->Recycle(recyclable, video::AppleVideoFrameLeaseConversion(handle));
                }
            }
            video::ReleaseAppleVideoFrameLease(handle);
        });
        // The lease exists and its deleter will recycle the destination, so
        // from here on the destination is one a live imported frame owns. Every
        // remaining failure in this block drops `candidate`, which runs that
        // deleter and takes the bytes off the live books.
        if (m_video_destination_pool) {
            m_video_destination_pool->MarkGpuPending(borrowed != nullptr ? borrowed : created);
        }
        TextureKey sampler_key {
            .width = static_cast<i32>(frame.displayWidth()),
            .height = static_cast<i32>(frame.displayHeight()),
            .usage = TexUsage::COLOR,
            .format = TextureFormat::RGBA8,
            .sample = video_tex.sample,
            .mipmap_level = 1,
        };
        const VkSampler sampler = GetOrCreateSampler(sampler_key, error);
        if (sampler == VK_NULL_HANDLE) return false;
        auto vulkan_image =
            importedImageFor(metal_texture, frame.displayWidth(), frame.displayHeight(), converted, error);
        if (!vulkan_image) return false;
        candidate->image = ImageParameters(vulkan_image->image);
        candidate->image.sampler = sampler;
        candidate->vulkan_image = std::move(vulkan_image);
        candidate->generation = frame.generation;
        candidate->pts_seconds = frame.pts_seconds;
        candidate->surface_identity = surface_identity;
        candidate->pixel_format = frame.pixel_format;
        // The image's first-use transition, if it still needs one, is recorded
        // into the next frame's command buffer by RecordVideoFirstUseTransitions:
        // nothing is submitted here.
        candidate->last_used = ++video_tex.frame_use_serial;
        video_tex.current_frame = candidate.get();
        video_tex.imported_frames.emplace_back(candidate);
        imported_frame = std::move(candidate);
        ++m_video_submission_stats.new_imports;
    }
    if (out != nullptr) {
        ImageSlotsRef result;
        result.slots = { ImageParameters(imported_frame->image) };
        result.video_frame_owner = std::move(imported_frame);
        *out = std::move(result);
    }

    if (m_counters != nullptr) {
        // Already accumulated by this cache; mirrored so one snapshot answers
        // "did GPU-side video work stop" without a second call.
        m_counters->Set(OWE_RC_VIDEO_CONVERSIONS, m_video_submission_stats.conversion_calls);
        m_counters->Set(OWE_RC_VIDEO_IMPORTS, m_video_submission_stats.new_imports);
        // Gauges, not totals: what the conversion destinations cost right now
        // and the most they have ever cost. Read off the pool on the import
        // path that just changed them, so no sampler and no thread exist for
        // this. Zero when this cache converts nothing, and not read at all
        // when nobody is counting.
        if (m_video_destination_pool && RendererCounters::Enabled()) {
            const auto pool = m_video_destination_pool->Stats();
            m_counters->Set(OWE_RC_VIDEO_CONVERSION_LIVE_BYTES, pool.live_bytes);
            m_counters->Set(OWE_RC_VIDEO_CONVERSION_PEAK_LIVE_BYTES, pool.peak_live_bytes);
        }
    }

    return true;
}

std::optional<ImageParameters> TextureCache::Query(std::string_view key, TextureKey content_hash,
                                                   bool persist) {
    if (exists(m_query_map, key)) {
        auto& query = *(m_query_map.find(key)->second);

        query.share_ready = false;
        query.persist     = persist;

        return query.image;
    };

    TexHash tex_hash = TextureKey::HashValue(content_hash);
    for (auto& query : m_query_texs) {
        if (! (query->share_ready)) continue;
        if (query->content_hash != tex_hash) continue;

        query->share_ready = false;
        query->persist     = persist;
        query->query_keys.insert(std::string(key));

        m_query_map[std::string(key)] = &(*query);

        return query->image;
    }

    return AllocateQuery(key, content_hash, persist);
}

std::optional<ImageParameters> TextureCache::Reserve(std::string_view key,
                                                     TextureKey       content_hash) {
    if (const auto it = m_query_map.find(std::string(key)); it != m_query_map.end()) {
        it->second->share_ready = false;
        it->second->persist     = true;
        return it->second->image;
    }
    return AllocateQuery(key, content_hash, true);
}

std::optional<ImageParameters> TextureCache::AllocateQuery(std::string_view key,
                                                           TextureKey content_hash, bool persist) {
    m_query_texs.emplace_back(std::make_unique<QueryTex>());
    auto& query                   = *m_query_texs.back();
    m_query_map[std::string(key)] = &query;

    query.index        = (idx)m_query_texs.size() - 1;
    query.content_hash = TextureKey::HashValue(content_hash);
    query.format       = content_hash.format;
    query.query_keys.insert(std::string(key));
    query.persist = persist;
    if (auto opt = CreateTex(content_hash); opt.has_value()) {
        query.image = std::move(opt.value());
        return query.image;
    }
    return std::nullopt;
}

void TextureCache::MarkShareReady(std::string_view key) {
    if (exists(m_query_map, key)) {
        auto& query = m_query_map.find(key)->second;
        if (query->persist) return;
        query->share_ready = true;
        m_query_map.erase(key.data());
    }
}

bool TextureCache::PinRenderTarget(std::string_view key) {
    auto it = m_query_map.find(std::string(key));
    // A key absent from the map was already released back to the pool, so its
    // image may belong to another target by now. Reporting failure keeps the
    // caller from reusing pixels it no longer owns.
    if (it == m_query_map.end() || it->second == nullptr) return false;
    auto* query = it->second;
    // The same holds the other way round: a key that took this image from the
    // pool after an earlier key released it shares it with that key's passes,
    // which were prepared against the image and keep drawing into it every
    // frame. Pinned, its own skipped writers would leave it holding the other
    // target's pixels. Keys still mapped here are aliases of an elided copy,
    // which write nothing.
    for (const auto& other : query->query_keys) {
        if (other == key) continue;
        auto mapped = m_query_map.find(other);
        if (mapped == m_query_map.end() || mapped->second != query) return false;
    }
    query->persist     = true;
    query->share_ready = false;
    return true;
}

bool TextureCache::AliasRenderTarget(std::string_view key, std::string_view source) {
    auto source_it = m_query_map.find(std::string(source));
    if (source_it == m_query_map.end() || source_it->second == nullptr) return false;
    auto* query = source_it->second;

    auto existing = m_query_map.find(std::string(key));
    if (existing != m_query_map.end() && existing->second == query) {
        query->persist = true;
        return true;
    }
    // The key may already own an allocation of its own. Returning it to the
    // pool is safe: nothing writes an aliased destination, so no reader of the
    // old image survives this call.
    if (existing != m_query_map.end() && existing->second != nullptr) {
        existing->second->persist     = false;
        existing->second->share_ready = true;
        m_query_map.erase(existing);
    }
    query->persist     = true;
    query->share_ready = false;
    query->query_keys.insert(std::string(key));
    m_query_map[std::string(key)] = query;
    return true;
}

uint64_t TextureCache::RenderTargetBytes(std::string_view key) const {
    auto it = m_query_map.find(std::string(key));
    if (it == m_query_map.end() || it->second == nullptr) return 0;
    const auto& image = it->second->image;
    // Derived from format, extent and mip chain, not physical residency.
    const uint64_t width  = image.extent.width;
    const uint64_t height = image.extent.height;
    uint64_t bytes = width * height *
        (it->second->format == TextureFormat::RGBA16F ? 8ULL : 4ULL);
    uint64_t       level  = bytes;
    for (uint32_t mip = 1; mip < image.mipmap_level; ++mip) {
        level /= 4ULL;
        if (level == 0) break;
        bytes += level;
    }
    return bytes;
}

void TextureCache::RecGenerateMipmaps(vvk::CommandBuffer& cmd, const ImageParameters& image) const {
    if (image.mipmap_level <= 1) return;

    constexpr VkPipelineStageFlags prior_stages =
        VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | VK_PIPELINE_STAGE_TRANSFER_BIT |
        VK_PIPELINE_STAGE_VERTEX_SHADER_BIT | VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
    constexpr VkAccessFlags prior_access =
        VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | VK_ACCESS_TRANSFER_READ_BIT |
        VK_ACCESS_TRANSFER_WRITE_BIT | VK_ACCESS_SHADER_READ_BIT;
    constexpr VkPipelineStageFlags shader_stages =
        VK_PIPELINE_STAGE_VERTEX_SHADER_BIT | VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;

    VkImageMemoryBarrier barrier {
        .sType               = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .pNext               = nullptr,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image               = image.handle,
        .subresourceRange =
            VkImageSubresourceRange {
                .aspectMask     = VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel   = 0,
                .levelCount     = 1,
                .baseArrayLayer = 0,
                .layerCount     = 1,
            },
    };

    i32 mipWidth  = (i32)image.extent.width;
    i32 mipHeight = (i32)image.extent.height;

    for (uint i = 1; i < image.mipmap_level; i++) {
        barrier.subresourceRange.baseMipLevel = i - 1;
        barrier.oldLayout                     = i == 1 ? VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
                                                       : VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;

        barrier.newLayout     = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        barrier.srcAccessMask = i == 1 ? prior_access : VK_ACCESS_TRANSFER_WRITE_BIT;
        barrier.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;

        cmd.PipelineBarrier(i == 1 ? prior_stages : VK_PIPELINE_STAGE_TRANSFER_BIT,
                            VK_PIPELINE_STAGE_TRANSFER_BIT,
                            0,
                            barrier);

        barrier.subresourceRange.baseMipLevel = i;
        barrier.oldLayout                     = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        barrier.newLayout                     = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        barrier.srcAccessMask                 = prior_access;
        barrier.dstAccessMask                 = VK_ACCESS_TRANSFER_WRITE_BIT;

        cmd.PipelineBarrier(prior_stages,
                            VK_PIPELINE_STAGE_TRANSFER_BIT,
                            0,
                            barrier);

        VkImageBlit blit {
            .srcSubresource =
                VkImageSubresourceLayers {
                    .aspectMask     = VK_IMAGE_ASPECT_COLOR_BIT,
                    .mipLevel       = i - 1,
                    .baseArrayLayer = 0,
                    .layerCount     = 1,
                },
            .srcOffsets = { VkOffset3D { 0, 0, 0 }, VkOffset3D { mipWidth, mipHeight, 1 } },
            .dstOffsets = { VkOffset3D { 0, 0, 0 },
                            VkOffset3D { mipWidth > 1 ? mipWidth / 2 : 1,
                                         mipHeight > 1 ? mipHeight / 2 : 1,
                                         1 } },
        };
        blit.dstSubresource =
            VkImageSubresourceLayers {
                .aspectMask     = blit.srcSubresource.aspectMask,
                .mipLevel       = blit.srcSubresource.mipLevel + 1,
                .baseArrayLayer = 0,
                .layerCount     = 1,
            },

        cmd.BlitImage(image.handle,
                      VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                      image.handle,
                      VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                      blit,
                      VK_FILTER_LINEAR);

        barrier.subresourceRange.baseMipLevel = i - 1;
        barrier.oldLayout                     = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        barrier.newLayout                     = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        barrier.srcAccessMask                 = VK_ACCESS_TRANSFER_READ_BIT;
        barrier.dstAccessMask                 = VK_ACCESS_SHADER_READ_BIT;

        cmd.PipelineBarrier(VK_PIPELINE_STAGE_TRANSFER_BIT,
                            shader_stages,
                            0,
                            barrier);

        if (mipWidth > 1) mipWidth /= 2;
        if (mipHeight > 1) mipHeight /= 2;
    }

    barrier.subresourceRange.baseMipLevel = image.mipmap_level - 1;
    barrier.oldLayout                     = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    barrier.newLayout                     = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    barrier.srcAccessMask                 = VK_ACCESS_TRANSFER_WRITE_BIT;
    barrier.dstAccessMask                 = VK_ACCESS_SHADER_READ_BIT;

    cmd.PipelineBarrier(VK_PIPELINE_STAGE_TRANSFER_BIT,
                        shader_stages,
                        0,
                        barrier);
}
