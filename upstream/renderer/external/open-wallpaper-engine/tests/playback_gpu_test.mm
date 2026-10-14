// Surface-free regression coverage. All images and input frames are synthetic.
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
#import <QuartzCore/CAMetalLayer.h>
#import <QuartzCore/CATransaction.h>

#include <gtest/gtest.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <functional>
#include <memory>
#include <set>
#include <stdexcept>
#include <unordered_map>
#include <unistd.h>
#include <sys/wait.h>
#include <utility>

#include "Image.hpp"
#include "Core/RendererCounters.hpp"
#include "Presentation/WallpaperScaling.hpp"
#include "Runtime/RuntimeImageSource.hpp"
#include "Scene/SceneWallpaper.hpp"
#include "Scene/WPShaderValueUpdater.hpp"
#include "Platform/Apple/FfmpegVideoInterop.hpp"
#include "Platform/Apple/SceneWallpaperBindings.h"
#include "Shader/RustShaderBridge.hpp"
#include "Video/VideoColorConversion.hpp"
#include "Video/VideoConversionBudget.hpp"
#include "video_orientation_cases.hpp"
#include "Vulkan/Device.hpp"
#include <vulkan/vulkan_metal.h>
#include "Vulkan/Util.hpp"
#include "VulkanRender/CustomShaderPass.hpp"
#include "VulkanRender/CopyPass.hpp"
#include "VulkanRender/FinPass.hpp"
#include "VulkanRender/PrePass.hpp"
#include "VulkanRender/PassCommon.hpp"
#include "VulkanRender/Resource.hpp"

namespace wallpaper::vulkan {
struct TextureCacheVideoInteropTestAccess {
    static ImageSlotsRef Create(TextureCache& cache, Image& image,
                                std::shared_ptr<video::VideoTextureSource> source) {
        return cache.CreateVideoTex(image, std::move(source));
    }
    static size_t CachedImports(const TextureCache& cache, const std::string& key) {
        const auto it = cache.m_video_tex_map.find(key);
        return it == cache.m_video_tex_map.end() ? 0 : it->second->imported_frames.size();
    }
};
}

namespace {
using namespace wallpaper;
using namespace wallpaper::vulkan;
using Bytes = std::vector<uint8_t>;
using Color = std::array<uint8_t, 4>;

void Require(bool condition, const std::string& message) {
    if (!condition) throw std::runtime_error(message);
}
void VkRequire(VkResult result, const char* operation) {
    Require(result == VK_SUCCESS, std::string(operation) + ": " + vvk::ToString(result));
}

// Each wrapper replaces only the fixture device's dispatch table. The registry is
// thread-local because every API call in these tests stays on the render thread.
// No loader entry point, shared GPU, or production failpoint is changed.
struct DispatchScope {
    static thread_local DispatchScope* current;
    vvk::DeviceDispatch& dispatch;
    vvk::DeviceDispatch saved;
    VkDevice device;
    bool fail_import = false;
    bool fail_image_view = false;
    bool fail_submit = false;
    bool timeout_wait = false;
    bool fail_reset = false;
    bool fail_framebuffer = false;
    bool fail_descriptor_layout = false;
    bool fail_pipeline_layout = false;
    bool fail_shader_module = false;
    int fail_shader_module_after = -1;
    VkResult idle_result = VK_SUCCESS;
    uint64_t waits = 0;
    uint64_t submits = 0;
    uint64_t pushes = 0;
    uint64_t clears = 0;
    uint64_t render_passes = 0;
    uint64_t draws = 0;
    uint64_t metal_image_imports = 0;
    VkBuffer watched_destination = VK_NULL_HANDLE;
    std::vector<VkBufferCopy> copies;

    explicit DispatchScope(Device& dev)
        : dispatch(const_cast<vvk::DeviceDispatch&>(dev.handle().Dispatch())),
          saved(dispatch), device(*dev.handle()) {
        Require(current == nullptr, "nested dispatch scope");
        current = this;
        dispatch.vkCreateImage = CreateImage;
        dispatch.vkCreateImageView = CreateImageView;
        dispatch.vkQueueSubmit = Submit;
        dispatch.vkWaitForFences = Wait;
        dispatch.vkResetFences = Reset;
        dispatch.vkDeviceWaitIdle = Idle;
        dispatch.vkCmdCopyBuffer = Copy;
        dispatch.vkCmdPushDescriptorSetKHR = Push;
        dispatch.vkCreateFramebuffer = CreateFramebuffer;
        dispatch.vkCreateDescriptorSetLayout = CreateDescriptorLayout;
        dispatch.vkCreatePipelineLayout = CreatePipelineLayout;
        dispatch.vkCreateShaderModule = CreateShaderModule;
        dispatch.vkCmdClearColorImage = Clear;
        dispatch.vkCmdBeginRenderPass = BeginRenderPass;
        dispatch.vkCmdDraw = Draw;
        dispatch.vkCmdDrawIndexed = DrawIndexed;
    }
    ~DispatchScope() { dispatch = saved; current = nullptr; }
    static VKAPI_ATTR VkResult VKAPI_CALL CreateImage(VkDevice d, const VkImageCreateInfo* info,
                                                       const VkAllocationCallbacks* alloc, VkImage* out) {
        auto& s = *current;
        for (auto* p = static_cast<const VkBaseInStructure*>(info->pNext); p; p = p->pNext) {
            if (d != s.device || p->sType != VK_STRUCTURE_TYPE_IMPORT_METAL_TEXTURE_INFO_EXT) continue;
            if (s.fail_import) {
                s.fail_import = false;
                return VK_ERROR_OUT_OF_DEVICE_MEMORY;
            }
            ++s.metal_image_imports;
        }
        return s.saved.vkCreateImage(d, info, alloc, out);
    }
    static VKAPI_ATTR VkResult VKAPI_CALL CreateImageView(VkDevice d, const VkImageViewCreateInfo* info,
                                                         const VkAllocationCallbacks* alloc, VkImageView* out) {
        auto& s = *current;
        if (d == s.device && std::exchange(s.fail_image_view, false)) return VK_ERROR_OUT_OF_DEVICE_MEMORY;
        return s.saved.vkCreateImageView(d, info, alloc, out);
    }
    static VKAPI_ATTR VkResult VKAPI_CALL Submit(VkQueue q, uint32_t n, const VkSubmitInfo* infos, VkFence f) {
        auto& s = *current;
        ++s.submits;
        if (std::exchange(s.fail_submit, false)) return VK_ERROR_OUT_OF_HOST_MEMORY;
        return s.saved.vkQueueSubmit(q, n, infos, f);
    }
    static VKAPI_ATTR VkResult VKAPI_CALL Wait(VkDevice d, uint32_t n, const VkFence* fs,
                                               VkBool32 all, uint64_t timeout) {
        auto& s = *current;
        ++s.waits;
        if (d == s.device && std::exchange(s.timeout_wait, false)) return VK_TIMEOUT;
        return s.saved.vkWaitForFences(d, n, fs, all, timeout);
    }
    static VKAPI_ATTR VkResult VKAPI_CALL Reset(VkDevice d, uint32_t n, const VkFence* fs) {
        auto& s = *current;
        if (d == s.device && std::exchange(s.fail_reset, false)) return VK_ERROR_OUT_OF_HOST_MEMORY;
        return s.saved.vkResetFences(d, n, fs);
    }
    static VKAPI_ATTR VkResult VKAPI_CALL Idle(VkDevice d) {
        auto& s = *current;
        return d == s.device && s.idle_result != VK_SUCCESS ? s.idle_result : s.saved.vkDeviceWaitIdle(d);
    }
    static VKAPI_ATTR void VKAPI_CALL Copy(VkCommandBuffer c, VkBuffer src, VkBuffer dst,
                                           uint32_t n, const VkBufferCopy* ranges) {
        auto& s = *current;
        if (dst == s.watched_destination) s.copies.insert(s.copies.end(), ranges, ranges + n);
        s.saved.vkCmdCopyBuffer(c, src, dst, n, ranges);
    }
    static VKAPI_ATTR void VKAPI_CALL Push(VkCommandBuffer c, VkPipelineBindPoint p, VkPipelineLayout l,
                                           uint32_t set, uint32_t n, const VkWriteDescriptorSet* writes) {
        auto& s = *current;
        ++s.pushes;
        s.saved.vkCmdPushDescriptorSetKHR(c, p, l, set, n, writes);
    }
    static VKAPI_ATTR VkResult VKAPI_CALL CreateFramebuffer(VkDevice d, const VkFramebufferCreateInfo* info,
                                                           const VkAllocationCallbacks* alloc, VkFramebuffer* out) {
        auto& s = *current;
        if (d == s.device && std::exchange(s.fail_framebuffer, false)) return VK_ERROR_OUT_OF_DEVICE_MEMORY;
        return s.saved.vkCreateFramebuffer(d, info, alloc, out);
    }
    static VKAPI_ATTR VkResult VKAPI_CALL CreateDescriptorLayout(VkDevice d, const VkDescriptorSetLayoutCreateInfo* info,
                                                                const VkAllocationCallbacks* alloc, VkDescriptorSetLayout* out) {
        auto& s = *current;
        if (d == s.device && std::exchange(s.fail_descriptor_layout, false)) return VK_ERROR_OUT_OF_HOST_MEMORY;
        return s.saved.vkCreateDescriptorSetLayout(d, info, alloc, out);
    }
    static VKAPI_ATTR VkResult VKAPI_CALL CreatePipelineLayout(VkDevice d, const VkPipelineLayoutCreateInfo* info,
                                                              const VkAllocationCallbacks* alloc, VkPipelineLayout* out) {
        auto& s = *current;
        if (d == s.device && std::exchange(s.fail_pipeline_layout, false)) return VK_ERROR_OUT_OF_HOST_MEMORY;
        return s.saved.vkCreatePipelineLayout(d, info, alloc, out);
    }
    static VKAPI_ATTR VkResult VKAPI_CALL CreateShaderModule(VkDevice d, const VkShaderModuleCreateInfo* info,
                                                            const VkAllocationCallbacks* alloc, VkShaderModule* out) {
        auto& s = *current;
        if (d == s.device && std::exchange(s.fail_shader_module, false)) return VK_ERROR_OUT_OF_HOST_MEMORY;
        if (d == s.device && s.fail_shader_module_after >= 0 && s.fail_shader_module_after-- == 0)
            return VK_ERROR_OUT_OF_HOST_MEMORY;
        return s.saved.vkCreateShaderModule(d, info, alloc, out);
    }
    static VKAPI_ATTR void VKAPI_CALL Clear(VkCommandBuffer c, VkImage image, VkImageLayout layout,
                                           const VkClearColorValue* color, uint32_t n, const VkImageSubresourceRange* ranges) {
        auto& s = *current; ++s.clears;
        s.saved.vkCmdClearColorImage(c, image, layout, color, n, ranges);
    }
    static VKAPI_ATTR void VKAPI_CALL BeginRenderPass(VkCommandBuffer c, const VkRenderPassBeginInfo* info,
                                                     VkSubpassContents contents) {
        auto& s = *current; ++s.render_passes;
        s.saved.vkCmdBeginRenderPass(c, info, contents);
    }
    static VKAPI_ATTR void VKAPI_CALL Draw(VkCommandBuffer c, uint32_t vertices, uint32_t instances,
                                          uint32_t first, uint32_t first_instance) {
        auto& s = *current; ++s.draws;
        s.saved.vkCmdDraw(c, vertices, instances, first, first_instance);
    }
    static VKAPI_ATTR void VKAPI_CALL DrawIndexed(VkCommandBuffer c, uint32_t indices, uint32_t instances,
                                                 uint32_t first, int32_t offset, uint32_t first_instance) {
        auto& s = *current; ++s.draws;
        s.saved.vkCmdDrawIndexed(c, indices, instances, first, offset, first_instance);
    }
};
thread_local DispatchScope* DispatchScope::current = nullptr;

class SyntheticVideo final : public video::VideoTextureSource {
public:
    CVPixelBufferRef buffer = nullptr;
    video::VideoTextureFrame frame {};
    bool fail_refresh = false;
    video::VideoPlaybackState playback {};
    SyntheticVideo(uint32_t w = 32, uint32_t h = 32) { Resize(w, h); }
    ~SyntheticVideo() override { if (buffer) CVPixelBufferRelease(buffer); }
    void Resize(uint32_t w, uint32_t h, OSType format = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
        CVPixelBufferRef replacement = nullptr;
        NSDictionary* attributes = @{ (__bridge NSString*)kCVPixelBufferIOSurfacePropertiesKey: @{},
                                      (__bridge NSString*)kCVPixelBufferMetalCompatibilityKey: @YES };
        Require(CVPixelBufferCreate(kCFAllocatorDefault, w, h, format,
                                    (__bridge CFDictionaryRef)attributes, &replacement) == kCVReturnSuccess,
                "IOSurface-backed Metal-compatible CVPixelBuffer prerequisite");
        if (buffer) CVPixelBufferRelease(buffer);
        buffer = replacement;
        frame.width = w; frame.height = h;
        frame.pixel_buffer = buffer;
        frame.io_surface = CVPixelBufferGetIOSurface(buffer);
        frame.pixel_format = format;
        frame.plane_count = static_cast<uint32_t>(CVPixelBufferGetPlaneCount(buffer));
        Set(0);
    }
    void Set(uint64_t generation, uint8_t y = 128, uint8_t u = 128, uint8_t v = 128,
             CFStringRef matrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2) {
        // A decoder hands out a biplanar frame from a pool that never writes
        // into a buffer someone still retains; the GPU conversion reads it
        // after the import returns. Model that rather than rewriting a frame
        // an import is still converting.
        if (CVPixelBufferGetPlaneCount(buffer) == 2 && CFGetRetainCount(buffer) > 1) {
            Resize(frame.width, frame.height, frame.pixel_format);
        }
        frame.generation = generation;
        frame.pts_seconds = static_cast<double>(generation) / 60.0;
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, matrix, kCVAttachmentMode_ShouldPropagate);
        Require(CVPixelBufferLockBaseAddress(buffer, 0) == kCVReturnSuccess, "lock synthetic frame");
        if (CVPixelBufferGetPlaneCount(buffer) == 2) {
            auto* luma = static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(buffer, 0));
            auto* chroma = static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(buffer, 1));
            for (size_t row = 0; row < frame.height; ++row)
                memset(luma + row * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0), y, frame.width);
            for (size_t row = 0; row < frame.height / 2; ++row)
                for (size_t x = 0; x < frame.width; x += 2) {
                    auto* p = chroma + row * CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) + x;
                    p[0] = u; p[1] = v;
                }
        } else {
            auto* raw = static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(buffer));
            for (size_t row = 0; row < frame.height; ++row)
                for (size_t x = 0; x < frame.width; ++x) {
                    auto* p = raw + row * CVPixelBufferGetBytesPerRow(buffer) + x * 4;
                    p[0] = v; p[1] = u; p[2] = y; p[3] = 255;
                }
        }
        Require(CVPixelBufferUnlockBaseAddress(buffer, 0) == kCVReturnSuccess, "unlock synthetic frame");
    }
    bool prime(std::string*) override { return true; }
    bool syncPlayback(const video::VideoPlaybackState& state, std::string*) override { playback = state; return true; }
    bool refreshFrame(std::string* error) override {
        if (!std::exchange(fail_refresh, false)) return true;
        if (error) *error = "synthetic one-shot decoder refresh error";
        return false;
    }
    video::VideoTextureFrame currentFrame() const override { return frame; }
    double durationSeconds() const override { return 1000.0; }
    double playbackSeconds() const override { return frame.pts_seconds; }
    uint64_t loopCount() const override { return 0; }
    double frameDurationSeconds() const override { return frame_duration_seconds; }
    double frame_duration_seconds = 1.0 / 60.0;
    video::VideoSourceStats stats {};
    video::VideoSourceStats sourceStats() const override { return stats; }
};

struct TestUpdater final : IShaderValueUpdater {
    std::array<float, 4> color { 1, 0, 0, 1 };
    unsigned calls = 0;
    std::function<void(SceneNode*)> geometry;
    void FrameBegin() override {}
    void FrameEnd() override {}
    void InitUniforms(SceneNode*, const ExistsUniformOp&) override {}
    void UpdateUniforms(SceneNode* node, sprite_map_t&, const UpdateUniformOp& update) override {
        ++calls;
        update("g_TestColor", ShaderValue(color));
        if (geometry) geometry(node);
    }
    void MouseInput(double, double) override {}
    void SetTexelSize(float, float) override {}
    void SetScreenSize(i32, i32) override {}
};

// Rust emits split texture/sampler descriptors. Convert that real compiler
// output to its equivalent combined-descriptor variant to exercise the legacy
// write path on the GPU, without another compiler or a fake pass.
void CombineSampler(ShaderCode& code, uint32_t image_binding, uint32_t sampler_binding) {
    struct Instruction {
        std::vector<uint32_t> words;
        uint32_t op() const { return words[0] & 0xffff; }
    };
    std::vector<Instruction> instructions;
    for (size_t offset = 5; offset < code.size();) {
        const size_t count = code[offset] >> 16;
        Require(count != 0 && offset + count <= code.size(), "valid Rust SPIR-V instruction");
        instructions.push_back({std::vector<uint32_t>(code.begin() + offset, code.begin() + offset + count)});
        offset += count;
    }
    uint32_t image = 0, sampler = 0, pointer = 0, image_type = 0, sampled_type = 0;
    for (const auto& ins : instructions) {
        const auto& w = ins.words;
        if (ins.op() == 71 && w.size() == 4 && w[2] == 33) {
            if (w[3] == image_binding) image = w[1];
            if (w[3] == sampler_binding) sampler = w[1];
        }
    }
    if (!image && !sampler) return;
    Require(image && sampler, "complete split descriptor pair");
    for (const auto& ins : instructions)
        if (ins.op() == 59 && ins.words[2] == image) pointer = ins.words[1];
    for (const auto& ins : instructions)
        if (ins.op() == 32 && ins.words[1] == pointer) image_type = ins.words[3];
    for (const auto& ins : instructions)
        if (ins.op() == 27 && ins.words[2] == image_type) sampled_type = ins.words[1];
    Require(pointer && image_type && sampled_type, "split image types");
    std::unordered_map<uint32_t, bool> loaded_images, loaded_samplers;
    for (const auto& ins : instructions) {
        if (ins.op() != 61) continue;
        if (ins.words[3] == image) loaded_images.emplace(ins.words[2], true);
        if (ins.words[3] == sampler) loaded_samplers.emplace(ins.words[2], true);
    }
    ShaderCode output(code.begin(), code.begin() + 5);
    unsigned rewritten_samples = 0;
    for (auto ins : instructions) {
        auto& w = ins.words;
        const auto op = ins.op();
        if ((op == 5 || op == 71) && (w[1] == sampler || loaded_samplers.contains(w[1]))) continue;
        if (op == 59 && w[2] == sampler) continue;
        if (op == 61 && w[3] == sampler) continue;
        if (op == 27 && w[1] == sampled_type) continue;
        if (op == 32 && w[1] == pointer) w[3] = sampled_type;
        if (op == 61 && w[3] == image) w[1] = sampled_type;
        if (op == 86 && loaded_images.contains(w[3]) && loaded_samplers.contains(w[4])) {
            w = {(4u << 16) | 83u, sampled_type, w[2], w[3]}; // OpCopyObject
            ++rewritten_samples;
        }
        if (op == 15) {
            size_t interface_start = 3;
            while (interface_start < w.size()) {
                const auto word = w[interface_start++];
                if ((word & 0xff) == 0 || (word & 0xff00) == 0 ||
                    (word & 0xff0000) == 0 || (word & 0xff000000) == 0) break;
            }
            w.erase(std::remove(w.begin() + interface_start, w.end(), sampler), w.end());
            w[0] = (static_cast<uint32_t>(w.size()) << 16) | op;
        }
        output.insert(output.end(), w.begin(), w.end());
        if (op == 25 && w[1] == image_type) {
            const std::array<uint32_t,3> sampled {(3u << 16) | 27u, sampled_type, image_type};
            output.insert(output.end(), sampled.begin(), sampled.end());
        }
    }
    Require(rewritten_samples != 0, "combined shader must really sample its descriptor");
    code = std::move(output);
}

class PlaybackGPU : public ::testing::Test {
protected:
    Instance instance;
    Device device;
    std::unique_ptr<StagingBuffer> vertices;
    std::unique_ptr<StagingBuffer> dynamic;
    vvk::CommandBuffers commands;
    RenderingResources rr {};
    Scene scene;
    TestUpdater* updater = nullptr;
    std::vector<std::unique_ptr<CustomShaderPass>> owned_passes;
    std::vector<std::shared_ptr<SceneNode>> nodes;
    std::vector<std::unique_ptr<VulkanPass>> auxiliary_passes;
    std::vector<std::shared_ptr<SceneShader>> shaders;
    std::vector<VmaImageParameters> private_targets;
    std::vector<vvk::ImageView> alias_views;
    CustomPassExecutionScratch scratch;
    bool recording = false;
    bool submitted = false;
    bool initialized = false;
    uint64_t serial = 0;

    void SetUp() override {
        try {
            std::vector<Extension> ix {{true, VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME}};
            Require(Instance::Create(instance, ix, {}), "Vulkan instance/MoltenVK prerequisite");
            std::vector<Extension> dx {{true, VK_EXT_METAL_OBJECTS_EXTENSION_NAME},
                                       {true, VK_KHR_PUSH_DESCRIPTOR_EXTENSION_NAME}};
            Require(instance.ChoosePhysicalDevice([&](auto gpu) { return Device::CheckGPU(gpu, dx, {}); }),
                    "Metal import and push-descriptor capable surface-free GPU prerequisite");
            Require(Device::Create(instance, dx, {32, 32}, device), "surface-free Vulkan device prerequisite");
            initialized = true;
            vertices = std::make_unique<StagingBuffer>(device, 256, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT | VK_BUFFER_USAGE_INDEX_BUFFER_BIT);
            dynamic = std::make_unique<StagingBuffer>(device, 256, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT | VK_BUFFER_USAGE_INDEX_BUFFER_BIT | VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
            Require(vertices->allocate() && dynamic->allocate(), "fixture staging allocation");
            VkRequire(device.cmd_pool().Allocate(1, VK_COMMAND_BUFFER_LEVEL_PRIMARY, commands), "allocate command");
            rr.command = vvk::CommandBuffer(commands[0], device.handle().Dispatch());
            rr.vertex_buf = vertices.get(); rr.dyn_buf = dynamic.get();
            NewFence();
            auto value_updater = std::make_unique<TestUpdater>();
            updater = value_updater.get();
            scene.shaderValueUpdater = std::move(value_updater);
            scene.activeCamera = nullptr;
        } catch (const std::exception& e) { FAIL() << e.what(); }
    }
    void TearDown() override {
        if (!initialized) return;
        const auto idle = device.handle().WaitIdle();
        if (idle != VK_SUCCESS) std::terminate();
        if (submitted) device.tex_cache().CompleteVideoFrame();
        else if (recording) {
            if (rr.command.Reset() != VK_SUCCESS) std::terminate();
            device.tex_cache().AbandonVideoFrameRecording();
        }
        if (vertices) vertices->finishUpload(submitted);
        if (dynamic) dynamic->finishUpload(submitted);
        submitted = recording = false;
        scratch.passes.clear(); scratch.candidates.clear(); scratch.plan.entries.clear();
        for (auto& pass : auxiliary_passes) pass->destory(device, rr);
        auxiliary_passes.clear();
        for (auto& pass : owned_passes) pass->destory(device, rr);
        owned_passes.clear();
        alias_views.clear();
        private_targets.clear();
        rr.command = {};
        commands = {};
        rr.fence_frame.reset();
        if (vertices) vertices->destroy();
        if (dynamic) dynamic->destroy();
        Require(device.tex_cache().Clear(), "fixture cache completion");
    }
    void NewFence() {
        rr.fence_frame.reset();
        VkRequire(device.handle().CreateFence(VkFenceCreateInfo {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO}, rr.fence_frame), "create fence");
    }
    ImageSlotsRef Register(const std::string& key, const std::shared_ptr<SyntheticVideo>& source,
                           TextureCache* cache = nullptr) {
        Image image;
        image.key = key; image.header.isVideo = true;
        image.header.width = source->frame.width; image.header.height = source->frame.height;
        auto result = TextureCacheVideoInteropTestAccess::Create(cache ? *cache : device.tex_cache(), image, source);
        Require(!result.slots.empty() && result.video_frame_owner, "register real video source: " + key);
        return result;
    }
    bool Update(const std::string& key, ImageSlotsRef& ref, double pts = 0) {
        std::string error;
        return device.tex_cache().UpdateVideoFrame(key, video::VideoPlaybackState {.scene_elapsed_seconds = pts}, &ref, &error);
    }
    Bytes Read(const ImageParameters& image) {
        Bytes bytes;
        std::string error;
        Require(device.tex_cache().ReadbackImageSample(image, 0, 0, image.extent.width, image.extent.height, &bytes, &error), error);
        return bytes;
    }
    Bytes Reference(const SyntheticVideo& source, bool rgba = true) {
        std::string error;
        void* lease = video::CreateAppleVideoFrameLease(source.frame, nullptr, nullptr, &error);
        Require(lease != nullptr, error);
        id<MTLTexture> texture = (__bridge id<MTLTexture>)video::AppleVideoFrameLeaseTexture(lease);
        Bytes bytes(source.frame.width * source.frame.height * 4);
        [texture getBytes:bytes.data() bytesPerRow:source.frame.width * 4
                 fromRegion:MTLRegionMake2D(0, 0, source.frame.width, source.frame.height) mipmapLevel:0];
        video::ReleaseAppleVideoFrameLease(lease);
        if (rgba) for (size_t i = 0; i < bytes.size(); i += 4) std::swap(bytes[i], bytes[i + 2]);
        return bytes;
    }
    static void ExpectSolid(const Bytes& bytes, Color color) {
        ASSERT_FALSE(bytes.empty());
        ASSERT_EQ(bytes.size() % 4, 0u);
        for (size_t i = 0; i < bytes.size(); ++i) {
            if (bytes[i] != color[i % 4]) {
                ADD_FAILURE() << "pixel " << i / 4 << " channel " << i % 4 << ": "
                              << unsigned(bytes[i]) << " expected " << unsigned(color[i % 4]);
                return;
            }
        }
    }
    void Begin() {
        Require(!recording && !submitted, "only one fixture draw in flight");
        std::string error;
        Require(device.tex_cache().BeginVideoFrameRecording(&error), error);
        recording = true;
        VkRequire(rr.command.Reset(), "reset command");
        VkRequire(rr.command.Begin(VkCommandBufferBeginInfo {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
                                                           .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT}), "begin command");
        device.tex_cache().RecordVideoFirstUseTransitions(rr.command);
    }
    void Upload() {
        Require(vertices->recordUpload(rr.command) && dynamic->recordUpload(rr.command), "record upload");
    }
    VkResult SubmitOnly() {
        VkRequire(rr.command.End(), "end command");
        VkSubmitInfo info {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = rr.command.address()};
        const auto result = device.graphics_queue().handle.Submit(info, *rr.fence_frame);
        if (result == VK_SUCCESS) {
            device.tex_cache().MarkVideoFrameSubmitted();
            submitted = true; recording = false;
        }
        return result;
    }
    void Complete() {
        VkRequire(rr.fence_frame.Wait(), "wait draw fence");
        device.tex_cache().CompleteVideoFrame();
        vertices->finishUpload(true); dynamic->finishUpload(true);
        submitted = false;
        const auto reset = rr.fence_frame.Reset();
        if (reset != VK_SUCCESS) NewFence();
    }
    void Submit() { VkRequire(SubmitOnly(), "submit draw"); Complete(); }
    void Abandon() {
        Require(!submitted, "cannot abandon submitted work");
        if (rr.command.Reset() != VK_SUCCESS) std::terminate();
        device.tex_cache().AbandonVideoFrameRecording();
        vertices->finishUpload(false); dynamic->finishUpload(false);
        recording = false;
    }
    VkResult CheckRecording(VkResult result) {
        if (result != VK_SUCCESS) Abandon();
        return result;
    }
    void Execute(VulkanPass& pass) {
        VkRequire(CheckRecording(pass.execute(device, rr)), "execute pass");
    }
    std::shared_ptr<SceneShader> Compile(bool texture, bool uniform, bool combined = false,
                                         std::string expression = {}, bool vertex_sample = false) {
        shader::RustShaderRequest request;
        request.shader_name = "playback_gpu/" + std::to_string(serial++);
        request.scene_id = "synthetic"; request.cache_enabled = false;
        request.stages = {{ShaderType::VERTEX,
            std::string("attribute vec2 a_Position;\nvarying vec2 v_Uv;\n") +
            (vertex_sample ? "uniform sampler2D g_Texture0;\nvarying vec4 v_Color;\n" : "") +
            "void main() { v_Uv = a_Position * 0.5 + vec2(0.5); gl_Position=vec4(a_Position,0.0,1.0);" +
            (vertex_sample ? "v_Color = textureLod(g_Texture0,vec2(0.5),0.0);" : "") + "}\n"},
            {ShaderType::FRAGMENT, std::string("varying vec2 v_Uv;\n") +
                (texture ? "uniform sampler2D g_Texture0;\n" : "") +
                (vertex_sample ? "varying vec4 v_Color;\n" : "") +
                (uniform ? "uniform vec4 g_TestColor;\n" : "") +
                "void main() { gl_FragColor=" + (!expression.empty() ? expression :
                    (texture ? "texture2D(g_Texture0,v_Uv)" : "vec4(0.0,1.0,0.0,1.0)")) +
                (uniform ? (texture ? " * g_TestColor" : " * 0.0 + g_TestColor") : "") + "; }\n"}};
        if (texture) request.textures.push_back(shader::RustShaderTextureInfo {.slot = 0, .present = true, .enabled = true});
        shader::RustShaderOutput output;
        Require(shader::CompileRustShaderProgram(request, output), "Rust shader prerequisite: " + shader::LastRustShaderError());
        auto result = std::make_shared<SceneShader>();
        result->name = request.shader_name;
        result->codes = std::move(output.codes);
        result->rust_reflection_json = std::move(output.reflection_json);
        if (combined) {
            const auto image_binding = output.reflection.binding_map.at("g_Texture0").binding;
            const auto sampler_binding = output.reflection.binding_map.at("_we_Sampler_g_Texture0").binding;
            for (auto& code : result->codes) CombineSampler(code, image_binding, sampler_binding);
            // The Rust compiler intentionally omits OpName debug strings. Keep
            // its authored names/UBO layout and update metadata with the same
            // descriptor transformation applied to the executable SPIR-V.
            auto reflection = nlohmann::json::parse(*result->rust_reflection_json);
            auto& bindings = reflection.at("descriptor_bindings");
            bindings.erase(std::remove_if(bindings.begin(), bindings.end(), [&](const auto& binding) {
                return binding.at("binding") == sampler_binding;
            }), bindings.end());
            for (auto& binding : bindings) {
                if (binding.at("binding") == image_binding)
                    binding["descriptor"] = "combined_image_sampler";
            }
            result->rust_reflection_json = reflection.dump();
        }
        shaders.push_back(result);
        return result;
    }
    std::string Target(uint32_t w = 32, uint32_t h = 32) {
        const std::string name = "_rt_gpu_" + std::to_string(serial++);
        scene.renderTargets[name] = SceneRenderTarget {.width = static_cast<i32>(w), .height = static_cast<i32>(h)};
        return name;
    }
    CustomShaderPass& Pass(bool texture = true, bool uniform = false,
                           std::string output = {}, bool dyn = false,
                           VkSampleCountFlagBits samples = VK_SAMPLE_COUNT_1_BIT,
                           std::shared_ptr<SceneShader> shader = {},
                           const std::function<void(CustomShaderPass::Desc&)>& configure = {},
                           bool require_prepared = true) {
        if (output.empty()) output = Target();
        auto mesh = std::make_shared<SceneMesh>(dyn ? MeshUpdate::PerFrame : MeshUpdate::Fixed);
        SceneVertexArray array({{"a_Position", VertexType::FLOAT2, false}}, dyn ? 4 : 3);
        if (dyn) {
            const std::array<float, 8> points {-1,-1, 1,-1, -1,1, 1,1};
            Require(array.SetVertex("a_Position", points), "set dynamic quad vertices");
        } else {
            const std::array<float, 6> points {-1,-1, 3,-1, -1,3};
            Require(array.SetVertex("a_Position", points), "set fullscreen triangle vertices");
        }
        mesh->AddVertexArray(std::move(array));
        SceneMaterial material;
        material.customShader.shader = shader ? std::move(shader) : Compile(texture, uniform);
        mesh->AddMaterial(std::move(material));
        auto node = std::make_shared<SceneNode>(); node->AddMesh(mesh); nodes.push_back(node);
        CustomShaderPass::Desc desc;
        desc.node = node.get(); desc.visibility_node = node.get(); desc.output = output;
        desc.sample_count = samples;
        if (texture) desc.textures = {""};
        auto pass = std::make_unique<CustomShaderPass>(desc);
        pass->desc().clear_on_first_use = true;
        if (configure) configure(pass->desc());
        pass->prepare(scene, device, rr);
        const bool prepared = pass->prepared();
        owned_passes.push_back(std::move(pass));
        Require(!require_prepared || prepared, "prepare real CustomShaderPass");
        return *owned_passes.back();
    }
    void Bind(CustomShaderPass& pass, const ImageSlotsRef& ref) { pass.desc().vk_textures.at(0) = ref; }
    ImageParameters ImageFor(const std::string& name) {
        auto image = device.tex_cache().Query(name, ToTexKey(scene.renderTargets.at(name)), true);
        Require(image.has_value(), "allocate private image");
        return *image;
    }
    FinPass& Final(const ImageParameters& target, VkFormat format = VK_FORMAT_R8G8B8A8_UNORM) {
        auto pass = std::make_unique<FinPass>(FinPass::Desc {});
        pass->setPresentFormat(format);
        pass->setPresentLayout(VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
        pass->setPresentQueueIndex(device.graphics_queue().family_index);
        pass->setPresent(target);
        pass->prepare(scene, device, rr);
        auto& result = *pass;
        auxiliary_passes.push_back(std::move(pass));
        return result;
    }
    PrePass& ClearPass(const std::string& name) {
        auto pass = std::make_unique<PrePass>(PrePass::Desc {.result = name});
        pass->prepare(scene, device, rr);
        Require(pass->prepared(), "prepare private clear");
        auto& result = *pass;
        auxiliary_passes.push_back(std::move(pass));
        return result;
    }
    static Bytes StripePixels(uint32_t width, uint32_t height) {
        Bytes expected(width * height * 4);
        for (uint32_t y = 0; y < height; ++y) for (uint32_t x = 0; x < width; ++x) {
            const Color color = x < width / 2 ? Color {255,0,0,255} : Color {0,0,255,255};
            std::copy(color.begin(), color.end(), expected.begin() + (y * width + x) * 4);
        }
        return expected;
    }
    /// `graph` is the whole pass list when `passes` is only the part executed
    /// this frame (static reuse leaves passes out); empty means the same list.
    void Frame(std::span<VulkanPass* const> passes, bool batched = true,
               std::span<VulkanPass* const> graph = {}) {
        // CPU writes precede command recording and the staging transaction.
        Require(device.tex_cache().BeginVideoFrameRecording(), "begin CPU frame scope");
        recording = true;
        Require(UpdatePreparedPasses(device, rr, passes), "update prepared passes");
        VkRequire(rr.command.Reset(), "reset frame command");
        VkRequire(rr.command.Begin(VkCommandBufferBeginInfo {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
                                                           .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT}), "begin frame command");
        device.tex_cache().RecordVideoFirstUseTransitions(rr.command);
        Upload();
        if (batched) VkRequire(CheckRecording(ExecutePreparedPasses(device, rr, passes, scratch, graph)), "execute frame");
        else for (auto* pass : passes) if (pass && pass->prepared()) Execute(*pass);
        Submit();
    }
    void Draw(CustomShaderPass& pass, bool batched = true) {
        VulkanPass* ptr = &pass; Frame(std::span<VulkanPass* const>(&ptr, 1), batched);
    }
    ImageParameters PrivateTarget(uint32_t width, uint32_t height, VkFormat format) {
        VmaImageParameters owner;
        owner.extent = {width,height,1};
        const VkImageCreateInfo image {.sType=VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .imageType=VK_IMAGE_TYPE_2D,.format=format,.extent=owner.extent,.mipLevels=1,.arrayLayers=1,
            .samples=VK_SAMPLE_COUNT_1_BIT,.tiling=VK_IMAGE_TILING_OPTIMAL,
            .usage=VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT|VK_IMAGE_USAGE_SAMPLED_BIT|
                   VK_IMAGE_USAGE_TRANSFER_SRC_BIT|VK_IMAGE_USAGE_TRANSFER_DST_BIT,
            .sharingMode=VK_SHARING_MODE_EXCLUSIVE,.initialLayout=VK_IMAGE_LAYOUT_UNDEFINED};
        const VmaAllocationCreateInfo allocation {.usage=VMA_MEMORY_USAGE_GPU_ONLY};
        VkRequire(vvk::CreateImage(device.vma_allocator(),image,allocation,owner.handle),"create private presentation image");
        const VkImageViewCreateInfo view {.sType=VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .image=*owner.handle,.viewType=VK_IMAGE_VIEW_TYPE_2D,.format=format,
            .subresourceRange={VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1}};
        VkRequire(device.handle().CreateImageView(view,owner.view),"create private presentation view");
        const ImageParameters result(owner);
        private_targets.push_back(std::move(owner));
        Poison(result,{1,0,1,1},true);
        return result;
    }
    void Poison(const ImageParameters& image, std::array<float,4> color, bool first = false) {
        Begin();
        VkImageMemoryBarrier barrier {.sType=VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .srcAccessMask=first ? VkAccessFlags(0) : VkAccessFlags(VK_ACCESS_SHADER_READ_BIT|VK_ACCESS_TRANSFER_READ_BIT|
                VK_ACCESS_TRANSFER_WRITE_BIT|VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT),
            .dstAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT,
            .oldLayout=first ? VK_IMAGE_LAYOUT_UNDEFINED : VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .newLayout=VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .srcQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED,.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED,
            .image=image.handle,.subresourceRange={VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1}};
        rr.command.PipelineBarrier(first ? VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT : VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
                                   VK_PIPELINE_STAGE_TRANSFER_BIT,0,barrier);
        VkClearColorValue value {}; std::copy(color.begin(),color.end(),value.float32);
        rr.command.ClearColorImage(image.handle,VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,&value,barrier.subresourceRange);
        barrier.srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT; barrier.dstAccessMask=VK_ACCESS_SHADER_READ_BIT;
        barrier.oldLayout=VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL; barrier.newLayout=VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        rr.command.PipelineBarrier(VK_PIPELINE_STAGE_TRANSFER_BIT,
                                   VK_PIPELINE_STAGE_VERTEX_SHADER_BIT|VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,0,barrier);
        Submit();
    }
    void FinishPrivatePresentation(const ImageParameters& target) {
        const VkImageMemoryBarrier barrier {.sType=VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .srcAccessMask=VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,.dstAccessMask=VK_ACCESS_SHADER_READ_BIT,
            .oldLayout=VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,.newLayout=VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .srcQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED,.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED,
            .image=target.handle,.subresourceRange={VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1}};
        rr.command.PipelineBarrier(VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                                   VK_PIPELINE_STAGE_VERTEX_SHADER_BIT|VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,0,barrier);
    }
    bool PresentFrame(CustomShaderPass& pass, FinPass& final, PrePass& pre,
                      const ImageParameters& target, VkFormat format, bool allow_direct = true) {
        final.setPresent(target);
        const std::array<VulkanPass*,3> sequence {&pre,&pass,&final};
        Begin(); Require(UpdatePreparedPasses(device,rr,sequence),"presentation update");
        device.tex_cache().RecordVideoFirstUseTransitions(rr.command); Upload();
        const bool direct=allow_direct && pass.canPresentDirectly(rr,{target.extent.width,target.extent.height},format);
        if (direct) {
            VkRequire(CheckRecording(pass.executePresentation(device,rr,target,format)),"record private direct");
            FinishPrivatePresentation(target);
        } else {
            VkRequire(CheckRecording(ExecutePreparedPasses(device,rr,sequence,scratch)),"record private normal");
        }
        Submit();
        return direct;
    }
    /// The poster of what `PresentFrame` just put on a target of `extent`,
    /// composed again by the same pass into an image of its own, the way the
    /// renderer composes one: the drawable itself is never read.
    Bytes ComposePoster(CustomShaderPass& pass, FinPass& final, PrePass& pre,
                        VkExtent2D extent, VkFormat format, bool direct) {
        const auto poster = PrivateTarget(extent.width, extent.height, format);
        const VkRenderPass render_pass =
            direct ? pass.presentationCopySourcePass() : final.copySourcePass();
        Require(render_pass != VK_NULL_HANDLE, "copy-source render pass");
        const VkImageView view = poster.view;
        const VkFramebufferCreateInfo info {.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
            .renderPass = render_pass, .attachmentCount = 1, .pAttachments = &view,
            .width = extent.width, .height = extent.height, .layers = 1};
        vvk::Framebuffer framebuffer;
        VkRequire(device.handle().CreateFramebuffer(info, framebuffer), "create poster framebuffer");
        const std::array<VulkanPass*,3> sequence {&pre,&pass,&final};
        Begin(); Require(UpdatePreparedPasses(device,rr,sequence),"poster update");
        device.tex_cache().RecordVideoFirstUseTransitions(rr.command); Upload();
        VkRequire(CheckRecording(direct
                      ? pass.recordPresentation(device, rr, render_pass, *framebuffer, extent)
                      : final.recordComposition(rr, render_pass, *framebuffer, extent)),
                  "record poster");
        VkImageMemoryBarrier barrier {.sType=VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .srcAccessMask=VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,.dstAccessMask=VK_ACCESS_SHADER_READ_BIT,
            .oldLayout=VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,.newLayout=VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .srcQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED,.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED,
            .image=poster.handle,.subresourceRange={VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1}};
        rr.command.PipelineBarrier(VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                                   VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,0,barrier);
        Submit();
        return Read(poster);
    }
    static Bytes NormalizeColorBytes(Bytes raw, VkFormat format) {
        if (format == VK_FORMAT_B8G8R8A8_UNORM)
            for(size_t i=0;i<raw.size();i+=4) std::swap(raw[i],raw[i+2]);
        return raw;
    }
    void CompareClearPaths(std::span<VulkanPass* const> sequence,
                           std::span<const ImageParameters> outputs, uint64_t removed) {
        std::vector<Bytes> reference;
        uint64_t before=0,after=0;
        { DispatchScope scope(device); Frame(sequence,false); before=scope.clears; }
        for(const auto& image:outputs) reference.push_back(Read(image));
        { DispatchScope scope(device); Frame(sequence,true); after=scope.clears; }
        ASSERT_GE(before,removed); EXPECT_EQ(after,before-removed);
        for(size_t i=0;i<outputs.size();++i) EXPECT_EQ(Read(outputs[i]),reference[i]);
    }
    Bytes BufferRead(StagingBuffer& staging, VkDeviceSize size) {
        VmaBufferParameters readback;
        Require(CreateReadbackBuffer(device.vma_allocator(), size, readback), "allocate buffer readback");
        Begin();
        VkBufferMemoryBarrier before {.sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
            .srcAccessMask = VK_ACCESS_MEMORY_WRITE_BIT, .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT,
            .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .buffer = staging.gpuBuf(), .offset = 0, .size = size};
        rr.command.PipelineBarrier(VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, before);
        VkBufferCopy copy {.size = size};
        rr.command.CopyBuffer(staging.gpuBuf(), *readback.handle, spanone {copy});
        VkBufferMemoryBarrier after {.sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
            .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT, .dstAccessMask = VK_ACCESS_HOST_READ_BIT,
            .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .buffer = *readback.handle, .offset = 0, .size = size};
        rr.command.PipelineBarrier(VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, after);
        Submit();
        void* mapped = nullptr;
        VkRequire(readback.handle.MapMemory(&mapped), "map buffer readback");
        VkRequire(vmaInvalidateAllocation(device.vma_allocator(), readback.handle.Allocation(), 0, VK_WHOLE_SIZE), "invalidate readback");
        Bytes bytes(static_cast<uint8_t*>(mapped), static_cast<uint8_t*>(mapped) + size);
        readback.handle.UnMapMemory();
        return bytes;
    }
    void UploadBuffer(StagingBuffer& staging) {
        Begin(); Require(staging.recordUpload(rr.command), "record test staging upload");
        VkRequire(SubmitOnly(), "submit test staging");
        VkRequire(rr.fence_frame.Wait(), "wait test staging");
        staging.finishUpload(true); Complete();
    }
};

TEST_F(PlaybackGPU, OverbrightTargetsFeedBloomAndPreserveSdrColor) {
    for (bool hdr : {false, true}) {
        SCOPED_TRACE(hdr ? "HDR" : "LDR");
        const auto source_name = Target();
        const auto bloom_name = Target();
        const auto copy_name = Target();
        for (const auto& name : {source_name, bloom_name, copy_name})
            scene.renderTargets.at(name).format =
                hdr ? TextureFormat::RGBA16F : TextureFormat::RGBA8;
        auto emitter_shader = Compile(false, false, false, "vec4(4.0,0.25,0.5,1.0)");
        auto bloom_shader = Compile(true, false, false,
            "vec4(max(texture2D(g_Texture0,v_Uv).r-2.0,0.0)*0.25,"
            "texture2D(g_Texture0,v_Uv).g,texture2D(g_Texture0,v_Uv).b,1.0)");
        auto& emitter = Pass(false, false, source_name, false, VK_SAMPLE_COUNT_1_BIT,
                             emitter_shader);
        auto& bloom = Pass(true, false, bloom_name, false, VK_SAMPLE_COUNT_1_BIT, bloom_shader);
        ImageSlotsRef emission; emission.slots = {emitter.desc().vk_output}; Bind(bloom, emission);
        auto copy = std::make_unique<CopyPass>(CopyPass::Desc {.src = bloom_name, .dst = copy_name});
        copy->prepare(scene, device, rr);
        ASSERT_TRUE(copy->prepared());
        auto& output = Pass(true, false);
        ImageSlotsRef blurred; blurred.slots = {copy->desc().vk_dst}; Bind(output, blurred);
        std::array<VulkanPass*,4> sequence {&emitter, &bloom, copy.get(), &output};
        for (bool batched : {false, true}) {
            Frame(sequence, batched);
            // Threshold two is unreachable after UNORM clipping. HDR must
            // contribute half-intensity bloom, with no accidental gamma step.
            ExpectSolid(Read(output.desc().vk_output),
                        {static_cast<uint8_t>(hdr ? 128 : 0), 64, 128, 255});
        }
        auxiliary_passes.push_back(std::move(copy));
    }
}

TEST_F(PlaybackGPU, ReleasingLargeFrameBufferDoesNotRetainAnOversizedEmptyBlock) {
    constexpr size_t frame_bytes = 40u * 1024 * 1024;
    {
        VmaBufferParameters frame;
        ASSERT_TRUE(CreateReadbackBuffer(device.vma_allocator(), frame_bytes, frame));
        void* mapped = nullptr;
        ASSERT_EQ(frame.handle.MapMemory(&mapped), VK_SUCCESS);
        auto* bytes = static_cast<uint8_t*>(mapped);
        bytes[0] = 17;
        bytes[frame_bytes - 1] = 91;
        EXPECT_EQ(bytes[0], 17);
        EXPECT_EQ(bytes[frame_bytes - 1], 91);
        frame.handle.UnMapMemory();
        VmaStats memory {};
        vmaCalculateStats(device.vma_allocator(), &memory);
        EXPECT_GE(memory.total.usedBytes, frame_bytes);
    }
    VmaStats memory {};
    vmaCalculateStats(device.vma_allocator(), &memory);
    // A transient large frame must not leave a desktop-sized idle allocation behind.
    EXPECT_LE(memory.total.unusedBytes, 32u * 1024 * 1024);
}

TEST_F(PlaybackGPU, SameGenerationSkipsConversion) {
    auto source = std::make_shared<SyntheticVideo>(); source->Set(1, 40, 90, 170);
    auto ref = Register("same", source);
    auto& pass = Pass(); Bind(pass, ref); Draw(pass);
    const auto expected = Reference(*source);
    EXPECT_EQ(Read(pass.desc().vk_output), expected);
    const auto stats = device.tex_cache().VideoSubmissionStats();
    for (int i = 0; i < 3; ++i) { ASSERT_TRUE(Update("same", ref)); Bind(pass, ref); Draw(pass); }
    EXPECT_EQ(device.tex_cache().VideoSubmissionStats().conversion_calls, stats.conversion_calls);
    EXPECT_EQ(device.tex_cache().VideoSubmissionStats().new_imports, stats.new_imports);
    auto old = ref;
    source->Set(2, 180, 170, 80);
    ASSERT_TRUE(Update("same", ref)); Bind(pass, ref); Draw(pass);
    EXPECT_EQ(Read(pass.desc().vk_output), Reference(*source));
    Bind(pass, old); Draw(pass);
    EXPECT_EQ(Read(pass.desc().vk_output), expected);
}

// Counting can be switched on and off while a decoder runs. Neither the work
// done before counting started nor the work done while it was off may be
// reported by the first counted frame; later frames report only their own.
TEST_F(PlaybackGPU, TurningCountersOnDoesNotReportWorkAlreadyDone) {
    auto source = std::make_shared<SyntheticVideo>();
    source->stats.decoded_frames = 40;
    source->stats.seek_requests = 3;
    source->Set(9, 40, 90, 170);
    auto ref = Register("baseline", source);

    RendererCounters counters;
    struct CountingOff {
        TextureCache& cache;
        ~CountingOff() { cache.SetCounters(nullptr); RendererCounters::SetEnabled(false); }
    } counting_off {device.tex_cache()};
    device.tex_cache().SetCounters(&counters);
    RendererCounters::SetEnabled(true);
    ASSERT_TRUE(Update("baseline", ref));
    EXPECT_EQ(counters.Get(OWE_RC_VIDEO_DECODE_OUTPUTS), 0u);
    EXPECT_EQ(counters.Get(OWE_RC_VIDEO_SEEKS), 0u);
    EXPECT_EQ(counters.Get(OWE_RC_VIDEO_FRAMES_SELECTED), 0u);
    EXPECT_EQ(counters.Get(OWE_RC_VIDEO_FRAMES_SKIPPED), 0u);

    source->stats.decoded_frames = 42;
    source->stats.seek_requests = 4;
    source->Set(11, 180, 170, 80);
    ASSERT_TRUE(Update("baseline", ref));
    EXPECT_EQ(counters.Get(OWE_RC_VIDEO_DECODE_OUTPUTS), 2u);
    EXPECT_EQ(counters.Get(OWE_RC_VIDEO_SEEKS), 1u);
    EXPECT_EQ(counters.Get(OWE_RC_VIDEO_FRAMES_SELECTED), 1u);
    EXPECT_EQ(counters.Get(OWE_RC_VIDEO_FRAMES_SKIPPED), 1u);

    // Off for a while: the decoder keeps producing and frames keep changing.
    RendererCounters::SetEnabled(false);
    source->stats.decoded_frames = 60;
    source->stats.seek_requests = 7;
    source->Set(30, 60, 100, 150);
    ASSERT_TRUE(Update("baseline", ref));
    source->Set(35, 70, 110, 140);
    ASSERT_TRUE(Update("baseline", ref));

    RendererCounters::SetEnabled(true);
    source->stats.decoded_frames = 61;
    source->Set(36, 80, 120, 130);
    ASSERT_TRUE(Update("baseline", ref));
    EXPECT_EQ(counters.Get(OWE_RC_VIDEO_DECODE_OUTPUTS), 2u) << "work done while off was reported";
    EXPECT_EQ(counters.Get(OWE_RC_VIDEO_SEEKS), 1u);
    EXPECT_EQ(counters.Get(OWE_RC_VIDEO_FRAMES_SELECTED), 1u);
    EXPECT_EQ(counters.Get(OWE_RC_VIDEO_FRAMES_SKIPPED), 1u)
        << "frames shown while counting was off were reported as skipped";

    source->stats.decoded_frames = 63;
    source->Set(38, 90, 130, 120);
    ASSERT_TRUE(Update("baseline", ref));
    EXPECT_EQ(counters.Get(OWE_RC_VIDEO_DECODE_OUTPUTS), 4u);
    EXPECT_EQ(counters.Get(OWE_RC_VIDEO_FRAMES_SELECTED), 2u);
    EXPECT_EQ(counters.Get(OWE_RC_VIDEO_FRAMES_SKIPPED), 2u);
}

TEST_F(PlaybackGPU, SteadyGenerationsReuseRetiredDestinations) {
    auto& pass = Pass();
    const std::array<CFStringRef, 3> matrices {kCVImageBufferYCbCrMatrix_ITU_R_601_4,
        kCVImageBufferYCbCrMatrix_ITU_R_709_2, kCVImageBufferYCbCrMatrix_ITU_R_2020};
    for (OSType range : {kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange}) {
        for (auto matrix : matrices) {
            auto source = std::make_shared<SyntheticVideo>(); source->Resize(32, 32, range);
            const auto key = "steady-" + std::to_string(serial++);
            auto ref = Register(key, source);
            uint64_t created = 0;
            uint64_t reused = 0;
            for (uint64_t i = 1; i <= 40; ++i) {
                source->Set(i, static_cast<uint8_t>(30 + (i * 19) % 180),
                            static_cast<uint8_t>(70 + (i * 13) % 110), static_cast<uint8_t>(60 + (i * 7) % 130), matrix);
                ASSERT_TRUE(Update(key, ref, i / 60.0));
                EXPECT_DOUBLE_EQ(source->playback.scene_elapsed_seconds, i / 60.0);
                EXPECT_DOUBLE_EQ(source->currentFrame().pts_seconds, i / 60.0);
                Bind(pass, ref); Draw(pass);
                EXPECT_EQ(Read(pass.desc().vk_output), Reference(*source)) << "generation " << i;
                auto stats = device.tex_cache().VideoSubmissionStats();
                if (i == 12) { created = stats.converted_destinations_created; reused = stats.converted_destinations_reused; }
                if (i > 12) {
                    EXPECT_EQ(stats.converted_destinations_created, created);
                    EXPECT_EQ(stats.converted_destinations_reused, reused + i - 12);
                }
                EXPECT_LE(TextureCacheVideoInteropTestAccess::CachedImports(device.tex_cache(), key), 4u);
                EXPECT_LE(stats.pool_cached_texture_count,
                          video::VideoConversionBudget::kCoexistingSlots);
                // The pool is bounded by VideoConversionBudget's ceiling, not
                // by the retired flat 64 MiB one. That figure had to go
                // because a single 6K or larger destination exceeds it, so a
                // large wallpaper could never keep one and reallocated per
                // frame; a 32x32 clip stays far below either number.
                EXPECT_LE(stats.pool_cached_bytes,
                          video::VideoConversionBudget::kDefaultCeilingBytes);
            }
        }
    }
}

TEST_F(PlaybackGPU, WarmLargeVideoStopsReallocatingItsConversionDestination) {
    // A 6144x3456 BGRA8 conversion destination is about 81 MiB, over the
    // retired flat 64 MiB pool ceiling. Under that ceiling every generation of
    // a large wallpaper allocated a destination and destroyed it again, which
    // is the churn this budget exists to remove.
    auto source = std::make_shared<SyntheticVideo>();
    source->Resize(6144, 3456);
    const std::string key = "large";
    auto ref = Register(key, source);
    constexpr uint64_t kWarm = 8;
    uint64_t created = 0;
    uint64_t reused = 0;
    std::array<uint8_t, 3> last {};
    // Per-generation trace of the ledger, so the allocate/reuse/return/destroy
    // sequence that produces the reported peak can be read instead of
    // guessed. `created` and `reused` below are cumulative totals; the
    // concurrent figure is `in_flight`, which is the destinations neither idle
    // in the pool nor yet given back.
    std::string  trace;
    uint64_t     previous_created = 0;
    uint64_t     previous_reused = 0;
    uint64_t     previous_recycles = 0;
    uint64_t     previous_refusals = 0;
    uint64_t     previous_evictions = 0;
    uint64_t     peak_in_flight = 0;
    for (uint64_t i = 1; i <= 16; ++i) {
        last = { static_cast<uint8_t>(30 + (i * 19) % 180),
                 static_cast<uint8_t>(70 + (i * 13) % 110),
                 static_cast<uint8_t>(60 + (i * 7) % 130) };
        source->Set(i, last[0], last[1], last[2]);
        ASSERT_TRUE(Update(key, ref, i / 60.0)) << "generation " << i;
        const auto stats = device.tex_cache().VideoSubmissionStats();
        // Cached bytes are the idle subset of the live bytes, never more.
        EXPECT_GE(stats.pool_live_bytes, stats.pool_cached_bytes) << "generation " << i;
        EXPECT_EQ(stats.pool_live_bytes,
                  stats.pool_cached_bytes + stats.pool_checked_out_bytes +
                      stats.pool_awaiting_gpu_bytes)
            << "generation " << i;
        const uint64_t in_flight = stats.pool_live_slot_count - stats.pool_cached_texture_count;
        peak_in_flight = std::max(peak_in_flight, in_flight);
        // Every live destination in this case has the one shape, so the live
        // total divided by the live count is that shape's measured cost.
        const uint64_t slot_bytes =
            stats.pool_live_slot_count == 0 ? 0 : stats.pool_live_bytes / stats.pool_live_slot_count;
        trace += "generation=" + std::to_string(i) + " action=" +
            (stats.converted_destinations_created > previous_created
                 ? "allocate"
                 : (stats.converted_destinations_reused > previous_reused ? "reuse" : "cache-hit")) +
            " slot_bytes=" + std::to_string(slot_bytes) + " live_bytes=" +
            std::to_string(stats.pool_live_bytes) + " cached_bytes=" +
            std::to_string(stats.pool_cached_bytes) + " in_flight=" + std::to_string(in_flight) +
            " returned=" + std::to_string(stats.pool_recycles - previous_recycles) +
            // A destination the pool refused is released outside the ledger,
            // which is a destroy as surely as an eviction is.
            " refused=" + std::to_string(stats.pool_refusals - previous_refusals) +
            " destroyed=" + std::to_string(stats.pool_evictions - previous_evictions) +
            " peak_live_bytes=" + std::to_string(stats.pool_peak_live_bytes) +
            " peak_cached_bytes=" + std::to_string(stats.pool_peak_cached_bytes) + "\n";
        previous_created = stats.converted_destinations_created;
        previous_reused = stats.converted_destinations_reused;
        previous_recycles = stats.pool_recycles;
        previous_refusals = stats.pool_refusals;
        previous_evictions = stats.pool_evictions;
        if (i == kWarm) {
            created = stats.converted_destinations_created;
            reused = stats.converted_destinations_reused;
        }
        if (i > kWarm) {
            EXPECT_EQ(stats.converted_destinations_created, created) << "generation " << i;
            EXPECT_EQ(stats.converted_destinations_reused, reused + i - kWarm)
                << "generation " << i;
        }
    }
    RecordProperty("conversion_ledger_trace", trace);
    const auto stats = device.tex_cache().VideoSubmissionStats();
    EXPECT_GT(stats.converted_destinations_reused, 0u);
    EXPECT_EQ(stats.pool_refusals, 0u);
    EXPECT_LE(stats.pool_cached_texture_count, video::VideoConversionBudget::kCoexistingSlots);
    EXPECT_LE(stats.pool_peak_cached_bytes, video::VideoConversionBudget::kDefaultCeilingBytes);
    // The pool really did hold a destination the retired ceiling refused.
    EXPECT_GT(stats.pool_peak_cached_bytes, 64u * 1024u * 1024u);
    // The cached figure alone was never the cost of this workload. More than
    // one destination was in flight at once, and each of those is the same
    // size as the single cached one the old figure reported.
    EXPECT_GT(peak_in_flight, 1u);
    EXPECT_GT(stats.pool_peak_live_bytes, stats.pool_peak_cached_bytes);
    EXPECT_GE(stats.pool_peak_live_bytes, peak_in_flight * 64u * 1024u * 1024u);
    // Reservations are intents; none may be left outstanding once every
    // import this loop started has finished.
    EXPECT_EQ(stats.pool_reserved_estimate_bytes, 0u);

    // A destination that came back from the pool still has to carry the frame
    // the conversion wrote into it. Sampling one corner is enough: a stale or
    // foreign texture would not hold this generation's colour at all.
    Bytes corner;
    std::string error;
    ASSERT_TRUE(device.tex_cache().ReadbackImageSample(ref.getActive(), 0, 0, 2, 2, &corner, &error))
        << error;
    ASSERT_EQ(corner.size(), 16u);
    const video::Rgb8 expected = video::ConvertYuvCodeToRgb8(
        video::MakeYuvColorParams({ .matrix = video::YuvMatrix::Bt709,
                                    .range = video::YuvRange::Full,
                                    .bit_depth = 8 }),
        last[0], last[1], last[2]);
    for (size_t pixel = 0; pixel < 4; ++pixel) {
        // Two code values of slack for half-precision output and rounding.
        EXPECT_NEAR(int(corner[pixel * 4 + 2]), int(expected.red), 2) << "pixel " << pixel;
        EXPECT_NEAR(int(corner[pixel * 4 + 1]), int(expected.green), 2) << "pixel " << pixel;
        EXPECT_NEAR(int(corner[pixel * 4 + 0]), int(expected.blue), 2) << "pixel " << pixel;
        EXPECT_EQ(int(corner[pixel * 4 + 3]), 255) << "pixel " << pixel;
    }
}

TEST_F(PlaybackGPU, RetainedFramesKeepTheirConversionDestinationsOutOfThePool) {
    auto source = std::make_shared<SyntheticVideo>();
    const std::string key = "in-flight";
    auto ref = Register(key, source);
    std::vector<ImageSlotsRef> held { ref };
    std::vector<Bytes>         expected { Reference(*source, false) };
    // Seven destinations in flight at once, none of them returned. This is
    // above the in-flight slot cap on purpose: the cap is a reported
    // structural expectation, never a refusal, so every one of these imports
    // has to succeed.
    for (uint64_t i = 1; i <= 6; ++i) {
        source->Set(i, static_cast<uint8_t>(40 + i * 25), static_cast<uint8_t>(90 + i * 9),
                    static_cast<uint8_t>(190 - i * 21));
        ASSERT_TRUE(Update(key, ref, i / 60.0));
        held.push_back(ref);
        expected.push_back(Reference(*source, false));
        // Every imported frame is still referenced, so no destination has
        // reached the end of its use. Pooling one here would let the next
        // conversion overwrite a texture a live consumer still samples.
        const auto stats = device.tex_cache().VideoSubmissionStats();
        EXPECT_EQ(stats.pool_cached_texture_count, 0u) << "generation " << i;
        EXPECT_EQ(stats.pool_cached_bytes, 0u) << "generation " << i;
        EXPECT_EQ(stats.converted_destinations_reused, 0u) << "generation " << i;
    }
    const auto before = device.tex_cache().VideoSubmissionStats();
    EXPECT_GE(before.converted_destinations_created, held.size());
    // Distinct pixels per retained frame: separate destinations, not one
    // texture quietly handed round behind their backs.
    for (size_t i = 0; i < held.size(); ++i) {
        EXPECT_EQ(Read(held[i].getActive()), expected[i]) << "retained frame " << i;
    }

    held.clear();
    ref = {};
    const auto released = device.tex_cache().VideoSubmissionStats();
    EXPECT_GT(released.pool_cached_texture_count, 0u);
    EXPECT_GT(released.pool_cached_bytes, 0u);
    source->Set(7, 200, 90, 60);
    ASSERT_TRUE(Update(key, ref));
    EXPECT_GT(device.tex_cache().VideoSubmissionStats().converted_destinations_reused,
              before.converted_destinations_reused);
    EXPECT_EQ(Read(ref.getActive()), Reference(*source, false));
}

TEST_F(PlaybackGPU, FreshConversionDestinationIsCountedBeforeItIsEverRecycled) {
    // The accounting hole this closes. A destination the import allocated for
    // itself used to reach the budget only when the frame that owned it died
    // and offered it back; until then the process held 81 MiB per frame that
    // nothing was counting, and the reported figure was the idle pool alone.
    auto source = std::make_shared<SyntheticVideo>();
    source->Resize(6144, 3456);
    const std::string key = "fresh";
    auto ref = Register(key, source);
    source->Set(1, 120, 100, 140);
    ASSERT_TRUE(Update(key, ref));

    const auto stats = device.tex_cache().VideoSubmissionStats();
    ASSERT_GT(stats.converted_destinations_created, 0u);
    ASSERT_EQ(stats.converted_destinations_reused, 0u);
    // Nothing has come back yet, so the reuse pool is still empty...
    EXPECT_EQ(stats.pool_recycles, 0u);
    EXPECT_EQ(stats.pool_cached_texture_count, 0u);
    EXPECT_EQ(stats.pool_cached_bytes, 0u);
    EXPECT_EQ(stats.pool_peak_cached_bytes, 0u);
    // ...and every destination is nevertheless on the books, held by the live
    // imported frames that reference them.
    EXPECT_EQ(stats.pool_checked_out_bytes, 0u);
    EXPECT_EQ(stats.pool_live_bytes, stats.pool_awaiting_gpu_bytes);
    EXPECT_EQ(stats.pool_live_slot_count, stats.converted_destinations_created);
    EXPECT_GE(stats.pool_live_bytes,
              stats.converted_destinations_created * 6144ull * 3456ull * 4ull);
    EXPECT_EQ(stats.pool_peak_live_bytes, stats.pool_live_bytes);
    // An estimate is released the moment the allocation it stood for exists.
    EXPECT_EQ(stats.pool_reserved_estimate_bytes, 0u);
}

TEST_F(PlaybackGPU, TwoVideoTexturesShareOnePoolWithinTheirCombinedSlotExpectation) {
    // One texture cache owns one conversion pool, so the in-flight slot
    // expectation is a per-pool quantity — but the count it is built from,
    // `kMaxImportedVideoFramesPerVideoTex`, is per video texture. Sizing the
    // pool's threshold with the per-video-texture figure makes every second
    // wallpaper look like a breach the moment both are busy: a permanent false
    // report of a condition that is supposed to mean a scene is holding more
    // frames than the caps predict. Two ordinary wallpapers are not that.
    //
    // Both sources are the same shape here, so a single reuse pool can serve
    // both and the sizing is the only thing under test.
    auto first = std::make_shared<SyntheticVideo>();
    auto second = std::make_shared<SyntheticVideo>();
    auto first_ref = Register("pair-first", first);
    auto second_ref = Register("pair-second", second);

    // Long enough for both sources to fill their imported-frame sets and start
    // recycling; the steady-state assertions only look past it.
    constexpr uint64_t kWarm = 12;
    uint64_t first_reuses = 0, first_creates = 0;
    uint64_t second_reuses = 0, second_creates = 0;
    uint64_t peak_in_flight = 0;
    auto previous = device.tex_cache().VideoSubmissionStats();
    for (uint64_t i = 1; i <= 24; ++i) {
        first->Set(i, static_cast<uint8_t>(30 + (i * 19) % 180),
                   static_cast<uint8_t>(70 + (i * 13) % 110),
                   static_cast<uint8_t>(60 + (i * 7) % 130));
        ASSERT_TRUE(Update("pair-first", first_ref, i / 60.0)) << "first source, generation " << i;
        auto now = device.tex_cache().VideoSubmissionStats();
        if (i > kWarm) {
            first_reuses += now.converted_destinations_reused - previous.converted_destinations_reused;
            first_creates += now.converted_destinations_created - previous.converted_destinations_created;
        }
        previous = now;

        // Deliberately different code values, so a destination handed to both
        // sources at once would show up as the wrong picture below.
        second->Set(i, static_cast<uint8_t>(200 - (i * 17) % 150),
                    static_cast<uint8_t>(140 - (i * 11) % 90),
                    static_cast<uint8_t>(180 - (i * 23) % 120));
        ASSERT_TRUE(Update("pair-second", second_ref, i / 60.0))
            << "second source, generation " << i;
        now = device.tex_cache().VideoSubmissionStats();
        if (i > kWarm) {
            second_reuses += now.converted_destinations_reused - previous.converted_destinations_reused;
            second_creates += now.converted_destinations_created - previous.converted_destinations_created;
        }
        previous = now;

        // Neither source may be turned away, and neither may be reported as
        // holding more than the pool's threshold accounts for: two ordinary
        // wallpapers are exactly what that threshold is supposed to admit.
        EXPECT_EQ(now.conversion_reservations_refused, 0u) << "generation " << i;
        EXPECT_EQ(now.pool_refusals, 0u) << "generation " << i;
        EXPECT_EQ(now.pool_in_flight_cap_breaches, 0u) << "generation " << i;
        peak_in_flight = std::max(peak_in_flight,
                                  now.pool_live_slot_count - now.pool_cached_texture_count);

        EXPECT_EQ(Read(first_ref.getActive()), Reference(*first, false))
            << "first source, generation " << i;
        EXPECT_EQ(Read(second_ref.getActive()), Reference(*second, false))
            << "second source, generation " << i;
    }

    // Both wallpapers reuse, and neither is still allocating once warm. A
    // threshold sized for one video texture would not change this — nothing
    // refuses any more — but the breach assertion above would fire every
    // generation, which is the regression this case pins.
    EXPECT_GT(first_reuses, 0u);
    EXPECT_GT(second_reuses, 0u);
    EXPECT_EQ(first_creates, 0u) << "a warm pool must stop allocating for the first source";
    EXPECT_EQ(second_creates, 0u) << "a warm pool must stop allocating for the second source";

    // The case really did exceed what one video texture alone may hold, which
    // is the only reason the sizing matters here.
    EXPECT_GT(peak_in_flight, video::VideoConversionBudget::kCoexistingSlots)
        << "two busy sources must exceed a single source's in-flight allowance, "
           "or this test is not covering the sizing at all";
    const auto stats = device.tex_cache().VideoSubmissionStats();
    EXPECT_EQ(stats.pool_in_flight_cap_breaches, 0u);
    EXPECT_EQ(stats.pool_reserved_estimate_bytes, 0u);
    EXPECT_EQ(stats.pool_live_bytes, stats.pool_cached_bytes + stats.pool_checked_out_bytes +
                                         stats.pool_awaiting_gpu_bytes);
}

TEST_F(PlaybackGPU, InFlightSlotCapIsReportedAndNeverRefusesAnImport) {
    // The in-flight slot cap is a structural expectation this pool reports,
    // never a gate. Refusing a conversion destination cannot be recovered from
    // on the real path: the destination that would satisfy the next request is
    // released by a consumer re-binding, and a consumer re-binds by receiving
    // the very import a refusal would withhold. Refusal removes the only way
    // back, so past the cap the import must still go through, the breach must
    // be reported, and every destination must stay accounted for.
    auto source = std::make_shared<SyntheticVideo>();
    const std::string key = "past-cap";
    auto ref = Register(key, source);
    std::vector<ImageSlotsRef> held { ref };
    std::vector<Bytes>         expected { Reference(*source, false) };

    // Well past `kMaxPendingVideoImportSubmissions +
    // kMaxImportedVideoFramesPerVideoTex`, holding every frame so nothing is
    // ever returned. This is the shape a denying cap would have stalled on.
    constexpr uint64_t kCap = uint64_t(video::kPendingVideoImportSubmissions +
                                       video::kImportedVideoFramesPerSource);
    for (uint64_t i = 1; i <= kCap + 6; ++i) {
        source->Set(i, static_cast<uint8_t>(40 + i * 15), static_cast<uint8_t>(90 + i * 9),
                    static_cast<uint8_t>(200 - i * 13));
        const auto before = device.tex_cache().VideoSubmissionStats();
        ASSERT_TRUE(Update(key, ref, i / 60.0))
            << "the in-flight cap must never refuse an import, generation " << i;
        held.push_back(ref);
        expected.push_back(Reference(*source, false));

        const auto after = device.tex_cache().VideoSubmissionStats();
        EXPECT_EQ(after.conversion_reservations_refused, 0u) << "generation " << i;
        // Every destination that exists is on the books. Nothing has come back,
        // so nothing was reused and nothing cached: the ledger's live count has
        // to be exactly what this cache allocated, which is what an allocation
        // slipping past an unread reservation would break.
        EXPECT_EQ(after.converted_destinations_reused, 0u) << "generation " << i;
        EXPECT_EQ(after.pool_cached_texture_count, 0u) << "generation " << i;
        EXPECT_EQ(after.pool_live_slot_count, after.converted_destinations_created)
            << "generation " << i;
        EXPECT_EQ(after.pool_live_slot_count, before.pool_live_slot_count + 1)
            << "generation " << i;
        EXPECT_EQ(after.pool_live_bytes, after.pool_awaiting_gpu_bytes) << "generation " << i;
        EXPECT_EQ(after.pool_checked_out_bytes, 0u) << "generation " << i;
        EXPECT_EQ(after.pool_reserved_estimate_bytes, 0u) << "generation " << i;
        // Granting past the cap is not the same as not noticing. Every
        // reservation made while the count was already at the cap is counted.
        EXPECT_EQ(after.pool_in_flight_cap_breaches,
                  before.pool_live_slot_count >= kCap ? before.pool_in_flight_cap_breaches + 1
                                                      : before.pool_in_flight_cap_breaches)
            << "generation " << i;
    }

    const auto past = device.tex_cache().VideoSubmissionStats();
    // The case really did run past the cap, or it is not covering this rule.
    EXPECT_GT(past.pool_live_slot_count, kCap);
    EXPECT_GT(past.pool_in_flight_cap_breaches, 0u);
    // A breach is not a refusal, and must not be counted as one.
    EXPECT_EQ(past.pool_refusals, 0u);
    // Every retained frame still carries its own picture: running past the cap
    // must not quietly hand one destination to two live frames.
    for (size_t i = 0; i < held.size(); ++i) {
        EXPECT_EQ(Read(held[i].getActive()), expected[i]) << "retained frame " << i;
    }

    // And once a consumer does let go, reuse resumes out of the pool rather
    // than by allocating afresh.
    held.clear();
    const auto released = device.tex_cache().VideoSubmissionStats();
    ASSERT_GT(released.pool_cached_texture_count, 0u);
    source->Set(kCap + 7, 200, 90, 60);
    ASSERT_TRUE(Update(key, ref));
    const auto recovered = device.tex_cache().VideoSubmissionStats();
    EXPECT_GT(recovered.converted_destinations_reused, past.converted_destinations_reused);
    EXPECT_EQ(recovered.converted_destinations_created, past.converted_destinations_created);
    EXPECT_EQ(recovered.conversion_reservations_refused, 0u);
    EXPECT_EQ(recovered.pool_reserved_estimate_bytes, 0u);
    EXPECT_EQ(Read(ref.getActive()), Reference(*source, false));
}

TEST_F(PlaybackGPU, HiddenConsumersKeepImportingAndTheOverageStopsGrowing) {
    // The shape that decided this design, driven entirely through the real pass
    // path: several consumers of one video texture where some stop re-binding
    // and keep the generation they last saw in their own `desc().vk_textures`.
    // Those retained references are handed out by `UpdateVideoFrame` itself, so
    // they are the import path's own retention, and they push the in-flight
    // count past what one video texture's caps account for.
    //
    // Under a cap that refused, this froze. The refused update left every
    // consumer holding its old reference, so no destination was ever returned,
    // so every later reservation was refused too: measured refusals of
    // 1, 8, 14, 19, 23 over five generations with allocations frozen and reuse
    // stuck at zero, the texture never leaving one generation again. Playback
    // has to keep moving instead.
    auto source = std::make_shared<SyntheticVideo>();
    const std::string key = "hidden";
    auto ref = Register(key, source);
    std::array<CustomShaderPass*, 7> passes;
    auto shader = Compile(true, false);
    for (auto& p : passes) p = &Pass(true, false, {}, false, VK_SAMPLE_COUNT_1_BIT, shader);
    for (auto* pass : passes) {
        pass->desc().textures[0] = key;
        pass->desc().video_textures[0] = true;
    }

    // Every consumer updating at one scene time shares a single import, which
    // is what an ordinary frame does and what has to stay cheap.
    Begin();
    for (auto* pass : passes) ASSERT_TRUE(pass->updateFrame(device, rr));
    Upload();
    for (auto* pass : passes) Execute(*pass);
    const auto shared = device.tex_cache().VideoSubmissionStats();
    EXPECT_EQ(shared.converted_destinations_created, 1u)
        << "consumers at one scene time must share one imported frame";
    EXPECT_GE(shared.cache_hits, passes.size() - 1);
    Submit();

    // Now let only a rotating subset re-bind, so the rest retain older
    // generations across frames.
    //
    // This is also where the overage's upper bound is pinned. It is enforced
    // by construction rather than by a counter: a consumer holds exactly one
    // reference per video-texture slot — `vk_textures[i]` is one assignment,
    // not a list — so the live set cannot exceed the cache's own retention
    // plus one destination per consumer slot, and neither term grows with
    // time. The observable consequence, asserted below, is that allocation
    // stops outright while reuse keeps going.
    constexpr uint64_t kSettle = 20;
    constexpr uint64_t kGenerations = 60;
    uint64_t peak_in_flight = 0;
    uint64_t last_generation = 0;
    VideoTextureSubmissionStats settled {};
    for (uint64_t g = 1; g <= kGenerations; ++g) {
        source->Set(g, static_cast<uint8_t>(30 + g * 17), static_cast<uint8_t>(80 + g * 9),
                    static_cast<uint8_t>(170 - g * 11));
        Begin();
        for (size_t i = g % passes.size(); i < passes.size(); ++i) {
            ASSERT_TRUE(passes[i]->updateFrame(device, rr))
                << "generation " << g << " pass " << i;
        }
        Upload();
        for (auto* pass : passes) Execute(*pass);
        const auto stats = device.tex_cache().VideoSubmissionStats();
        peak_in_flight = std::max<uint64_t>(
            peak_in_flight, stats.pool_live_slot_count - stats.pool_cached_texture_count);
        // Not one refusal, and the ledger stays self-consistent throughout.
        EXPECT_EQ(stats.conversion_reservations_refused, 0u) << "generation " << g;
        EXPECT_EQ(stats.pool_live_bytes, stats.pool_cached_bytes + stats.pool_checked_out_bytes +
                                             stats.pool_awaiting_gpu_bytes)
            << "generation " << g;
        EXPECT_EQ(stats.pool_reserved_estimate_bytes, 0u) << "generation " << g;
        if (g == kSettle) settled = stats;
        if (g > kSettle) {
            // The bound, as an observable: past the settling point this
            // workload allocates nothing further and the live set does not
            // grow, however long it runs. A genuinely unbounded overage would
            // show up right here as either figure creeping up.
            EXPECT_EQ(stats.converted_destinations_created,
                      settled.converted_destinations_created)
                << "conversion destinations kept being allocated at generation " << g;
            EXPECT_EQ(stats.pool_live_slot_count, settled.pool_live_slot_count)
                << "the live destination set kept growing at generation " << g;
            // ...while playback keeps advancing out of the pool.
            EXPECT_GT(stats.converted_destinations_reused, settled.converted_destinations_reused)
                << "generation " << g;
            // And the threshold now covers this shape, so nothing is reported
            // at all: a breach means a destination that stopped being
            // returned, not an ordinary scene with several layers on one
            // video. That is the only thing worth a log line.
            EXPECT_EQ(stats.pool_in_flight_cap_breaches, 0u)
                << "an ordinary retained-consumer scene must not be reported as a breach, "
                   "generation " << g;
        }
        Submit();
        last_generation = g;
    }

    const auto stats = device.tex_cache().VideoSubmissionStats();
    // The case exceeded what one video texture's own caps account for, which is
    // the only reason it is interesting.
    EXPECT_GT(peak_in_flight, uint64_t(video::kPendingVideoImportSubmissions +
                                       video::kImportedVideoFramesPerSource))
        << "the retained-consumer shape did not exceed the cap, so this proves nothing";
    // Nothing here is a leak, so nothing here is reported. A breach now means
    // a destination that stopped being returned, which is the only thing worth
    // a log line; an ordinary scene with several layers on one video is not
    // that, and used to be reported as if it were.
    EXPECT_EQ(stats.pool_in_flight_cap_breaches, 0u);
    // The overage is bounded, and this is the number: the live set never grew
    // past the cache's own retention plus one destination per consumer slot.
    EXPECT_LE(stats.pool_live_slot_count,
              uint64_t(video::kPendingVideoImportSubmissions +
                       video::kImportedVideoFramesPerSource) + passes.size());
    // Playback did not freeze: destinations came back and were reused, rather
    // than the texture being stuck on whatever generation filled the cap.
    EXPECT_GT(stats.converted_destinations_reused, 0u)
        << "a stalled video texture never reuses, because nothing is ever returned";
    EXPECT_GT(stats.pool_recycles, 0u);

    // And the surface really is showing the newest frame, not a frozen one.
    ASSERT_TRUE(Update(key, ref, last_generation / 60.0));
    EXPECT_EQ(Read(ref.getActive()), Reference(*source, false));
}

TEST_F(PlaybackGPU, ClearedCacheAndDestroyedPoolLeaveNoConversionBytesBehind) {
    auto&          domain = video::SharedVideoConversionMemoryDomain();
    const uint64_t domain_live_before = domain.live_bytes();
    const size_t   domain_budgets_before = domain.budget_count();

    auto cache = std::make_unique<TextureCache>(device);
    auto source = std::make_shared<SyntheticVideo>();
    source->Resize(1920, 1080);
    const std::string key = "drained";
    auto              ref = Register(key, source, cache.get());
    for (uint64_t i = 1; i <= 5; ++i) {
        source->Set(i, uint8_t(40 + i * 21), uint8_t(90 + i * 11), uint8_t(180 - i * 17));
        std::string error;
        ASSERT_TRUE(cache->UpdateVideoFrame(
            key, video::VideoPlaybackState { .scene_elapsed_seconds = i / 60.0 }, &ref, &error))
            << error;
    }
    const auto busy = cache->VideoSubmissionStats();
    EXPECT_GT(busy.pool_live_bytes, 0u);
    // A pool that has opted into the domain is one the domain can see.
    EXPECT_EQ(domain.budget_count(), domain_budgets_before + 1);
    EXPECT_GE(domain.live_bytes(), domain_live_before + busy.pool_live_bytes);

    ref = {};
    ASSERT_TRUE(cache->WaitForPendingUploads());
    // Clear drops the pool, which drains what it cached and takes itself out
    // of the domain. The destinations its live imports still held go with
    // their frames, so the domain has to come back to exactly where it was.
    ASSERT_TRUE(cache->Clear());
    const auto cleared = cache->VideoSubmissionStats();
    EXPECT_EQ(cleared.pool_cached_texture_count, 0u);
    EXPECT_EQ(cleared.pool_cached_bytes, 0u);
    EXPECT_EQ(cleared.pool_peak_cached_bytes, 0u);
    EXPECT_EQ(cleared.pool_checked_out_bytes, 0u);
    EXPECT_EQ(cleared.pool_awaiting_gpu_bytes, 0u);
    EXPECT_EQ(cleared.pool_live_bytes, 0u);
    EXPECT_EQ(cleared.pool_peak_live_bytes, 0u);
    EXPECT_EQ(cleared.pool_reserved_estimate_bytes, 0u);
    EXPECT_EQ(cleared.pool_live_slot_count, 0u);
    EXPECT_EQ(domain.budget_count(), domain_budgets_before);
    EXPECT_EQ(domain.live_bytes(), domain_live_before);

    cache.reset();
    EXPECT_EQ(domain.budget_count(), domain_budgets_before);
    EXPECT_EQ(domain.live_bytes(), domain_live_before);

    // A pool driven by hand, so the three states and the drain are observed on
    // a live object rather than on one the cache has already thrown away.
    id<MTLDevice> metal = MTLCreateSystemDefaultDevice();
    ASSERT_NE(metal, nil);
    {
        video::AppleVideoMetalTexturePool pool((__bridge void*)metal);
        source->Set(6, 60, 150, 110);
        const auto reservation = pool.ReserveFresh(source->frame.width, source->frame.height);
        EXPECT_TRUE(reservation.granted);
        EXPECT_GT(pool.Stats().reserved_estimate_bytes, 0u);
        EXPECT_EQ(pool.Stats().live_bytes, 0u) << "an intent is not an allocation";

        std::string error;
        void*       created = nullptr;
        void*       lease = video::CreateAppleVideoFrameLease(
            source->frame, (__bridge void*)metal, nullptr, &error, nullptr, &created);
        ASSERT_NE(lease, nullptr) << error;
        ASSERT_NE(created, nullptr);
        pool.CommitFresh(reservation, created);
        const auto committed = pool.Stats();
        EXPECT_EQ(committed.reserved_estimate_bytes, 0u);
        EXPECT_EQ(committed.checked_out_bytes, committed.live_bytes);
        EXPECT_GT(committed.live_bytes, 0u);
        EXPECT_EQ(committed.cached_bytes, 0u);

        pool.MarkGpuPending(created);
        const auto pending = pool.Stats();
        EXPECT_EQ(pending.checked_out_bytes, 0u);
        EXPECT_EQ(pending.awaiting_gpu_bytes, committed.live_bytes);
        EXPECT_EQ(pending.live_bytes, committed.live_bytes);

        void* recyclable = video::TakeAppleVideoFrameLeaseDestination(lease);
        ASSERT_EQ(recyclable, created);
        pool.Recycle(recyclable);
        video::ReleaseAppleVideoFrameLease(lease);
        const auto returned = pool.Stats();
        EXPECT_EQ(returned.awaiting_gpu_bytes, 0u);
        EXPECT_EQ(returned.cached_bytes, committed.live_bytes);
        EXPECT_EQ(returned.live_bytes, committed.live_bytes);

        pool.Clear();
        const auto drained = pool.Stats();
        EXPECT_EQ(drained.cached_bytes, 0u);
        EXPECT_EQ(drained.cached_texture_count, 0u);
        EXPECT_EQ(drained.checked_out_bytes, 0u);
        EXPECT_EQ(drained.awaiting_gpu_bytes, 0u);
        EXPECT_EQ(drained.live_bytes, 0u);
        EXPECT_EQ(drained.reserved_estimate_bytes, 0u);
        EXPECT_EQ(drained.live_slot_count, 0u);
    }
    // The destroyed pool took itself out of the shared domain.
    EXPECT_EQ(domain.budget_count(), domain_budgets_before);
    EXPECT_EQ(domain.live_bytes(), domain_live_before);
}

TEST_F(PlaybackGPU, VideoImportsUseTheDisplayedDimensionsAndOrientation) {
    for (const auto format : {kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange}) {
        for (const auto& orientation : video::testing_media::kOrientations) {
            SCOPED_TRACE(orientation.name);
            auto source = std::make_shared<SyntheticVideo>(16, 8);
            source->Resize(16, 8, format);
            source->Set(1);
            ASSERT_TRUE(video::testing_media::FillVideoQuadrants(source->buffer));
            const auto transform = video::ResolveVideoDisplayTransform(orientation.matrix(), 16, 8);
            ASSERT_TRUE(transform.has_value());
            source->frame.display_transform = *transform;
            const auto key = std::to_string(format) + orientation.name;
            const auto imported = Register(key, source);
            const auto& image = imported.getActive();
            const auto pixels = Read(image);
            EXPECT_EQ(image.extent.width, orientation.swaps_axes ? 8u : 16u);
            EXPECT_EQ(image.extent.height, orientation.swaps_axes ? 16u : 8u);
            for (size_t corner = 0; corner < 4; ++corner) {
                const size_t x = corner % 2 ? image.extent.width - 2 : 1;
                const size_t y = corner / 2 ? image.extent.height - 2 : 1;
                const size_t offset = (y * image.extent.width + x) * 4;
                const auto expected = video::testing_media::kQuadrantLuma[orientation.source_quadrants[corner]];
                for (size_t channel = 0; channel < 3; ++channel) EXPECT_NEAR(pixels.at(offset + channel), expected, 2);
                EXPECT_EQ(pixels.at(offset + 3), 255);
            }
        }
    }
}

TEST_F(PlaybackGPU, MetalConversionMatchesTheCpuColorReference) {
    // The other video tests compare the GPU result against an import of the
    // same frame, which cannot catch a wrong range or matrix. This one compares
    // the Metal kernel against the shared CPU conversion for known code values,
    // so the two paths have to agree about studio swing and colorimetry.
    const std::array<std::pair<CFStringRef, video::YuvMatrix>, 3> matrices {{
        { kCVImageBufferYCbCrMatrix_ITU_R_601_4, video::YuvMatrix::Bt601 },
        { kCVImageBufferYCbCrMatrix_ITU_R_709_2, video::YuvMatrix::Bt709 },
        { kCVImageBufferYCbCrMatrix_ITU_R_2020,
          video::YuvMatrix::Bt2020NonConstantLuminance },
    }};
    const std::array<std::array<uint8_t, 3>, 6> samples {{
        { 126, 128, 160 },  // the plan's worked example: chroma off the midpoint
        { 180, 128, 128 },  // neutral, isolates luma range handling
        {  51, 109, 212 },  // 75% red bar
        { 145, 147,  44 },  // 75% cyan bar
        {  16, 128, 128 },  // studio black
        { 235, 128, 128 },  // studio white
    }};
    for (OSType format : { kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                           kCVPixelFormatType_420YpCbCr8BiPlanarFullRange }) {
        const video::YuvRange range = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ? video::YuvRange::Full
            : video::YuvRange::Limited;
        for (const auto& [attachment, matrix] : matrices) {
            auto source = std::make_shared<SyntheticVideo>();
            source->Resize(32, 32, format);
            const auto params = video::MakeYuvColorParams(
                { .matrix = matrix, .range = range, .bit_depth = 8 });
            for (const auto& sample : samples) {
                source->Set(++serial, sample[0], sample[1], sample[2], attachment);
                const Bytes converted = Reference(*source, /*rgba=*/false);
                ASSERT_GE(converted.size(), 4u);
                const video::Rgb8 expected =
                    video::ConvertYuvCodeToRgb8(params, sample[0], sample[1], sample[2]);
                SCOPED_TRACE(testing::Message()
                             << "range=" << video::YuvRangeName(range)
                             << " matrix=" << video::YuvMatrixName(matrix)
                             << " Y=" << int(sample[0]) << " Cb=" << int(sample[1])
                             << " Cr=" << int(sample[2]));
                // Two code values of slack for half-precision output and
                // rounding; a wrong range or matrix is off by far more.
                EXPECT_NEAR(int(converted[2]), int(expected.red), 2);
                EXPECT_NEAR(int(converted[1]), int(expected.green), 2);
                EXPECT_NEAR(int(converted[0]), int(expected.blue), 2);
                EXPECT_EQ(int(converted[3]), 255);
            }
        }
    }
}

TEST_F(PlaybackGPU, NewVideoFramesNeitherWaitOnTheCpuNorSubmitOutsideTheFrame) {
    // The Compatibility path, one draw per new NV12 generation. A new frame
    // must reach the GPU inside the frame's own submission: no second submit
    // for its layout, no CPU wait for its conversion, and the Vulkan images
    // that alias the pooled conversion destinations are made once per
    // destination rather than once per frame. Each generation must still
    // carry its own pixels, checked against the CPU colour reference rather
    // than against another GPU conversion.
    auto source = std::make_shared<SyntheticVideo>();
    source->Set(1, 90, 110, 150);
    const std::string key = "in-frame";
    auto ref = Register(key, source);
    auto& pass = Pass(); Bind(pass, ref); Draw(pass);
    const auto params = video::MakeYuvColorParams(
        { .matrix = video::YuvMatrix::Bt709, .range = video::YuvRange::Full, .bit_depth = 8 });
    const auto before = device.tex_cache().VideoSubmissionStats();
    constexpr uint64_t kFrames = 24;
    uint64_t frame_submits = 0;
    uint64_t frame_waits = 0;
    uint64_t image_imports = 0;
    const uint64_t cpu_waits_before = video::AppleVideoConversionCpuWaits();
    for (uint64_t g = 2; g < 2 + kFrames; ++g) {
        const auto y = static_cast<uint8_t>(30 + (g * 23) % 190);
        const auto u = static_cast<uint8_t>(60 + (g * 17) % 130);
        const auto v = static_cast<uint8_t>(50 + (g * 29) % 150);
        source->Set(g, y, u, v);
        {
            DispatchScope scope(device);
            ASSERT_TRUE(Update(key, ref, g / 60.0)) << "generation " << g;
            Bind(pass, ref); Draw(pass);
            frame_submits += scope.submits;
            frame_waits += scope.waits;
            image_imports += scope.metal_image_imports;
        }
        // BGRA, as the conversion wrote it.
        const Bytes pixels = Read(ref.getActive());
        const video::Rgb8 expected = video::ConvertYuvCodeToRgb8(params, y, u, v);
        ASSERT_EQ(pixels.size(), size_t(source->frame.width) * source->frame.height * 4);
        for (size_t i = 0; i < pixels.size(); i += 4) {
            const bool near = std::abs(int(pixels[i + 2]) - int(expected.red)) <= 2 &&
                              std::abs(int(pixels[i + 1]) - int(expected.green)) <= 2 &&
                              std::abs(int(pixels[i]) - int(expected.blue)) <= 2 &&
                              pixels[i + 3] == 255;
            if (!near) {
                ADD_FAILURE() << "generation " << g << " pixel " << i / 4 << ": BGRA "
                              << int(pixels[i]) << ',' << int(pixels[i + 1]) << ','
                              << int(pixels[i + 2]) << ',' << int(pixels[i + 3]) << " expected RGB "
                              << int(expected.red) << ',' << int(expected.green) << ','
                              << int(expected.blue);
                break;
            }
        }
        EXPECT_EQ(Read(pass.desc().vk_output), NormalizeColorBytes(pixels, VK_FORMAT_B8G8R8A8_UNORM))
            << "generation " << g;
    }
    const auto after = device.tex_cache().VideoSubmissionStats();
    const uint64_t cpu_waits = video::AppleVideoConversionCpuWaits() - cpu_waits_before;
    RecordProperty("frame_submits", std::to_string(frame_submits));
    RecordProperty("frame_fence_waits", std::to_string(frame_waits));
    RecordProperty("metal_image_imports", std::to_string(image_imports));
    RecordProperty("conversion_cpu_waits", std::to_string(cpu_waits));
    EXPECT_EQ(after.new_imports - before.new_imports, kFrames);
    EXPECT_EQ(after.conversion_calls - before.conversion_calls, kFrames);
    EXPECT_EQ(cpu_waits, 0u) << "a conversion on the frame path must never be waited for on the CPU";
    EXPECT_EQ(frame_submits, kFrames) << "each new frame must be exactly one submission: its own";
    EXPECT_EQ(frame_waits, kFrames) << "the only fence waited on is each frame's own";
    EXPECT_LE(image_imports, after.converted_destinations_created)
        << "one Vulkan image per pooled destination, not one per frame";
    EXPECT_LT(image_imports, kFrames);
    EXPECT_EQ(after.imported_images_created - before.imported_images_created, image_imports);
    EXPECT_EQ(after.imported_images_created + after.imported_images_reused -
                  before.imported_images_created - before.imported_images_reused,
              kFrames);
}

TEST_F(PlaybackGPU, ADroppedFrameDestinationIsNotReusedBeforeItsConversionRuns) {
    // A conversion is committed without a CPU wait, so a frame can be dropped
    // before the GPU has run it — evicted unseen, or failed after the lease
    // existed. Its destination must not be lent to another import until that
    // command buffer has completed. A queue held on an event makes "not yet"
    // deterministic instead of a race against a fast GPU.
    id<MTLDevice> metal = MTLCreateSystemDefaultDevice();
    ASSERT_NE(metal, nil);
    id<MTLCommandQueue> queue = [metal newCommandQueue];
    id<MTLSharedEvent>  gate = [metal newSharedEvent];
    id<MTLCommandBuffer> blocker = [queue commandBuffer];
    [blocker encodeWaitForEvent:gate value:1];
    [blocker commit];
    struct Release {
        id<MTLSharedEvent> gate;
        ~Release() { gate.signaledValue = 1; }
    } release { gate };

    auto source = std::make_shared<SyntheticVideo>();
    source->Set(1, 60, 150, 110);
    const auto expected = Reference(*source, false);
    const uint32_t width = source->frame.width;
    const uint32_t height = source->frame.height;
    video::AppleVideoMetalTexturePool pool((__bridge void*)metal);
    const auto reservation = pool.ReserveFresh(width, height);
    ASSERT_TRUE(reservation.granted);
    const uint64_t waits_before = video::AppleVideoConversionCpuWaits();
    std::string error;
    void*       created = nullptr;
    void*       lease = video::CreateAppleVideoFrameLease(source->frame, (__bridge void*)metal,
                                                          nullptr, &error, nullptr, &created,
                                                          (__bridge void*)queue);
    ASSERT_NE(lease, nullptr) << error;
    ASSERT_NE(created, nullptr);
    EXPECT_EQ(video::AppleVideoConversionCpuWaits(), waits_before)
        << "given a queue, the import must return without waiting for the GPU";
    id<MTLCommandBuffer> conversion =
        (__bridge id<MTLCommandBuffer>)video::AppleVideoFrameLeaseConversion(lease);
    ASSERT_NE(conversion, nil);
    ASSERT_LT(conversion.status, MTLCommandBufferStatusCompleted);
    pool.CommitFresh(reservation, created);
    pool.MarkGpuPending(created);

    // The frame goes before its conversion has run.
    pool.Recycle(video::TakeAppleVideoFrameLeaseDestination(lease), (__bridge void*)conversion);
    video::ReleaseAppleVideoFrameLease(lease);
    const auto parked = pool.Stats();
    EXPECT_EQ(parked.cached_texture_count, 0u);
    EXPECT_EQ(parked.awaiting_gpu_bytes, parked.live_bytes);
    EXPECT_GT(parked.live_bytes, 0u);
    EXPECT_EQ(pool.Take(width, height), nullptr)
        << "a destination the GPU has not written yet must not be lent out";

    gate.signaledValue = 1;
    [conversion waitUntilCompleted];
    void* reused = pool.Take(width, height);
    ASSERT_EQ(reused, created) << "once converted, the same destination is reused";
    Bytes pixels(size_t(width) * height * 4);
    [(__bridge id<MTLTexture>)reused getBytes:pixels.data() bytesPerRow:width * 4
                                   fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
    EXPECT_EQ(pixels, expected) << "the parked destination holds its own conversion";
    pool.EndLoan(reused);
}

TEST_F(PlaybackGPU, RecordedConsumersSurviveCacheEviction) {
    auto source = std::make_shared<SyntheticVideo>();
    auto ref = Register("six", source);
    std::array<CustomShaderPass*, 6> passes;
    auto shader = Compile(true, false);
    for (auto& p : passes) p = &Pass(true, false, {}, false, VK_SAMPLE_COUNT_1_BIT, shader);
    std::array<Bytes, 6> expected;
    Begin();
    for (auto* pass : passes) {
        Bind(*pass, ref);
        ASSERT_TRUE(pass->updateFrame(device, rr));
    }
    Upload();
    for (size_t i = 0; i < passes.size(); ++i) {
        source->Set(i + 1, 35 + i * 30, 80 + i * 15, 175 - i * 17);
        expected[i] = Reference(*source);
        ASSERT_TRUE(Update("six", ref));
        Bind(*passes[i], ref);
        Execute(*passes[i]);
        passes[i]->desc().vk_textures[0] = {};
        ref = {};
    }
    Submit();
    for (size_t i = 0; i < passes.size(); ++i) EXPECT_EQ(Read(passes[i]->desc().vk_output), expected[i]);
}

TEST_F(PlaybackGPU, RetainedConsumerSurvivesOtherPassAndUpdateFailure) {
    auto a = std::make_shared<SyntheticVideo>(); a->Set(1, 50, 90, 170);
    auto b = std::make_shared<SyntheticVideo>(); b->Set(1, 170, 140, 60);
    auto ar = Register("a", a); auto br = Register("b", b);
    const auto old_pixels = Reference(*a);
    auto& retained = Pass(); auto& moving = Pass(); auto& other = Pass();
    Bind(retained, ar); Bind(moving, ar); Bind(other, br);
    Draw(retained);
    retained.desc().visibility_node->SetVisible(false);
    for (uint64_t i = 2; i < 12; ++i) {
        a->Set(i, 20 + i * 13, 110, 160); b->Set(i, 200 - i * 11, 160, 90);
        ASSERT_TRUE(Update("a", ar)); ASSERT_TRUE(Update("b", br));
        Bind(moving, ar); Bind(other, br);
        std::array<VulkanPass*, 3> passes {&moving, &retained, &other}; Frame(passes);
        EXPECT_EQ(Read(moving.desc().vk_output), Reference(*a));
        EXPECT_EQ(Read(other.desc().vk_output), Reference(*b));
    }
    retained.desc().textures[0] = "a";
    retained.desc().video_textures[0] = true;
    a->fail_refresh = true;
    retained.desc().visibility_node->SetVisible(true); Draw(retained);
    EXPECT_EQ(Read(retained.desc().vk_output), old_pixels);
    EXPECT_FALSE(a->fail_refresh);
}

TEST_F(PlaybackGPU, ConversionAndImportFailurePreserveCurrentFrame) {
    auto source = std::make_shared<SyntheticVideo>(); source->Set(1, 70, 160, 100);
    auto ref = Register("failure", source); auto& pass = Pass();
    const auto old = Reference(*source); auto owner = ref.video_frame_owner;
    source->Resize(32, 32, kCVPixelFormatType_32BGRA);
    source->Set(2, 230, 10, 40);
    source->frame.pixel_format = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    source->frame.plane_count = 2;
    ASSERT_FALSE(Update("failure", ref)); EXPECT_EQ(ref.video_frame_owner, owner);
    Bind(pass, ref); Draw(pass); EXPECT_EQ(Read(pass.desc().vk_output), old);
    source->Resize(32, 32); source->Set(3, 180, 80, 180);
    {
        DispatchScope scope(device); scope.fail_import = true;
        ASSERT_FALSE(Update("failure", ref)); EXPECT_FALSE(scope.fail_import);
    }
    EXPECT_EQ(ref.video_frame_owner, owner); Bind(pass, ref); Draw(pass);
    EXPECT_EQ(Read(pass.desc().vk_output), old);
    ASSERT_TRUE(Update("failure", ref)); Bind(pass, ref); Draw(pass);
    EXPECT_EQ(Read(pass.desc().vk_output), Reference(*source));
}

TEST_F(PlaybackGPU, ResizeAndDirectBgraKeepSeparateLifetimes) {
    auto source = std::make_shared<SyntheticVideo>(); source->Set(1, 80, 80, 170);
    auto ref = Register("resize", source); auto retained = ref;
    const auto old = Reference(*source); auto& pass = Pass();
    for (const auto extent : {std::array<uint32_t,2>{64,32}, {32,32}}) {
        source->Resize(extent[0], extent[1]); source->Set(++serial, 120, 160, 80);
        ASSERT_TRUE(Update("resize", ref));
        EXPECT_EQ(ref.getActive().extent.width, extent[0]); EXPECT_EQ(ref.getActive().extent.height, extent[1]);
        EXPECT_EQ(Read(ref.getActive()), Reference(*source, false));
    }
    const auto before = device.tex_cache().VideoSubmissionStats().conversion_calls;
    source->Resize(32, 32, kCVPixelFormatType_32BGRA); source->Set(++serial, 20, 180, 40);
    ASSERT_TRUE(Update("resize", ref)); Bind(pass, ref); Draw(pass);
    ExpectSolid(Read(pass.desc().vk_output), {20,180,40,255});
    const auto bgra_owner = ref.video_frame_owner;
    source->Set(++serial, 90, 30, 210); ASSERT_TRUE(Update("resize", ref));
    EXPECT_EQ(ref.video_frame_owner, bgra_owner);
    EXPECT_EQ(device.tex_cache().VideoSubmissionStats().conversion_calls, before);
    Bind(pass, ref); Draw(pass); ExpectSolid(Read(pass.desc().vk_output), {90,30,210,255});
    source->Resize(32, 32); source->Set(++serial, 180, 100, 130);
    ASSERT_TRUE(Update("resize", ref)); Bind(pass, ref); Draw(pass);
    EXPECT_EQ(Read(pass.desc().vk_output), Reference(*source));
    Bind(pass, retained); Draw(pass); EXPECT_EQ(Read(pass.desc().vk_output), old);
    const auto stats = device.tex_cache().VideoSubmissionStats();
    EXPECT_LE(stats.pool_cached_texture_count, video::VideoConversionBudget::kCoexistingSlots);
    EXPECT_LE(stats.pool_cached_bytes, video::VideoConversionBudget::kDefaultCeilingBytes);
    // Resolution churn must not leave the pool holding shapes nothing asks
    // for: only the size the last import requested may still be cached.
    EXPECT_LE(stats.pool_cached_bytes, 32u * 32u * 4u * video::VideoConversionBudget::kCoexistingSlots);
    id<MTLDevice> metal = MTLCreateSystemDefaultDevice(); ASSERT_NE(metal, nil);
    video::AppleVideoMetalTexturePool pool((__bridge void*)metal);
    const auto destination = [&](uint32_t width, uint32_t height) {
        auto* descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                              width:width height:height mipmapped:NO];
        descriptor.storageMode = MTLStorageModeShared;
        descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        id<MTLTexture> texture = [metal newTextureWithDescriptor:descriptor];
        Require(texture != nil, "allocate conversion destination for pool test");
        return texture;
    };
    // 4096x4097 is over the retired flat 64 MiB ceiling. Refusing it is what
    // made a large wallpaper reallocate a destination every generation, so it
    // now has to be pooled and lent back for its own shape only.
    id<MTLTexture> large = destination(4096, 4097);
    ASSERT_GT(large.allocatedSize, 64u * 1024u * 1024u);
    pool.Recycle((__bridge_retained void*)large);
    EXPECT_EQ(pool.Stats().cached_texture_count, 1u);
    EXPECT_EQ(pool.Stats().cached_bytes, large.allocatedSize);
    EXPECT_EQ(pool.Take(4096, 4096), nullptr);
    void* lent = pool.Take(4096, 4097);
    EXPECT_EQ(lent, (__bridge void*)large);
    EXPECT_EQ(pool.Stats().cached_texture_count, 0u);
    pool.Recycle(lent);
    EXPECT_EQ(pool.Stats().cached_texture_count, 1u);
    pool.RetainOnly(1920, 1080);
    EXPECT_EQ(pool.Stats().cached_texture_count, 0u);
    EXPECT_EQ(pool.Stats().cached_bytes, 0u);
    EXPECT_EQ(pool.Stats().peak_cached_bytes, large.allocatedSize);
}

TEST_F(PlaybackGPU, RecordingDiscardAndSubmissionRecoveryKeepOwners) {
    auto source = std::make_shared<SyntheticVideo>(); source->Set(1, 80, 170, 100);
    auto ref = Register("recovery", source); auto& pass = Pass(); Bind(pass, ref);
    auto expected = Reference(*source);
    Begin(); ASSERT_TRUE(pass.updateFrame(device, rr)); Upload(); Execute(pass); Abandon();
    Draw(pass); EXPECT_EQ(Read(pass.desc().vk_output), expected);
    Begin(); ASSERT_TRUE(pass.updateFrame(device, rr)); Upload(); Execute(pass);
    std::weak_ptr<const void> weak = ref.video_frame_owner;
    pass.desc().vk_textures[0] = {};
    ref = {};
    for (uint64_t generation = 2; generation <= 8; ++generation) {
        source->Set(generation, 40 + generation * 20, 100, 170);
        ASSERT_TRUE(Update("recovery", ref));
    }
    ASSERT_TRUE(device.tex_cache().WaitForPendingUploads());
    ASSERT_EQ(SubmitOnly(), VK_SUCCESS);
    {
        DispatchScope scope(device); scope.timeout_wait = true;
        EXPECT_EQ(rr.fence_frame.Wait(), VK_TIMEOUT);
        EXPECT_FALSE(device.tex_cache().BeginVideoFrameRecording());
        EXPECT_FALSE(device.tex_cache().Clear()); EXPECT_FALSE(weak.expired());
    }
    Complete(); EXPECT_EQ(Read(pass.desc().vk_output), expected);
    EXPECT_TRUE(weak.expired());
    Bind(pass, ref);
    expected = Reference(*source);
    Begin(); ASSERT_TRUE(pass.updateFrame(device, rr)); Upload(); Execute(pass);
    {
        DispatchScope scope(device); scope.fail_submit = true;
        EXPECT_EQ(SubmitOnly(), VK_ERROR_OUT_OF_HOST_MEMORY);
        EXPECT_EQ(scope.waits, 0u);
        Abandon(); EXPECT_EQ(scope.waits, 0u);
    }
    Draw(pass); EXPECT_EQ(Read(pass.desc().vk_output), expected);
    Begin(); ASSERT_TRUE(pass.updateFrame(device, rr)); Upload(); Execute(pass);
    ASSERT_EQ(SubmitOnly(), VK_SUCCESS);
    {
        DispatchScope scope(device); scope.fail_reset = true;
        Complete(); EXPECT_FALSE(scope.fail_reset);
    }
    Draw(pass); EXPECT_EQ(Read(pass.desc().vk_output), expected);
    // An import submits nothing of its own. A never-used image's first-use
    // transition goes into the frame; a frame that recorded it and was then
    // discarded never ran it, so the next frame must record it again, and a
    // submitted one is not repeated. A fresh size forces a fresh destination,
    // hence a fresh image that has never been transitioned.
    auto fresh = std::make_shared<SyntheticVideo>(16, 16); fresh->Set(1, 170, 90, 180);
    ImageSlotsRef fresh_ref;
    {
        DispatchScope scope(device);
        fresh_ref = Register("recovery-fresh", fresh);
        EXPECT_EQ(scope.submits, 0u) << "an import must not submit work of its own";
        EXPECT_EQ(scope.waits, 0u) << "an import must not wait on a fence";
    }
    const auto converted = Reference(*fresh);
    const Color fresh_color {converted[0], converted[1], converted[2], converted[3]};
    const auto transitions = [&] {
        return device.tex_cache().VideoSubmissionStats().first_use_transitions_recorded;
    };
    const auto before_frames = transitions();
    Bind(pass, fresh_ref);
    Begin(); ASSERT_TRUE(pass.updateFrame(device, rr)); Upload(); Execute(pass);
    const auto discarded = transitions() - before_frames;
    ASSERT_GT(discarded, 0u) << "the fresh image's transition belongs in the first frame";
    {
        DispatchScope scope(device); scope.fail_submit = true;
        EXPECT_EQ(SubmitOnly(), VK_ERROR_OUT_OF_HOST_MEMORY);
        Abandon();
    }
    Draw(pass); ExpectSolid(Read(pass.desc().vk_output), fresh_color);
    EXPECT_EQ(transitions() - before_frames, 2 * discarded)
        << "a discarded frame's first-use transitions must be recorded again";
    Draw(pass); ExpectSolid(Read(pass.desc().vk_output), fresh_color);
    EXPECT_EQ(transitions() - before_frames, 2 * discarded)
        << "a submitted first-use transition must not be recorded twice";
}

TEST_F(PlaybackGPU, ClearInvalidatesOldPoolWithoutInvalidatingOwners) {
    auto source = std::make_shared<SyntheticVideo>(); source->Set(1, 90, 80, 180);
    auto old = Register("clear", source);
    const auto pixels = Reference(*source, false);
    Begin(); device.tex_cache().PinVideoFrame(old);
    EXPECT_FALSE(device.tex_cache().Clear()); Abandon();
    Begin(); device.tex_cache().PinVideoFrame(old); ASSERT_EQ(SubmitOnly(), VK_SUCCESS);
    EXPECT_FALSE(device.tex_cache().Clear()); Complete();
    ASSERT_TRUE(device.tex_cache().Clear());
    EXPECT_EQ(Read(old.getActive()), pixels);
    source->Set(2, 150, 160, 80); auto fresh = Register("fresh", source);
    const auto count = device.tex_cache().VideoSubmissionStats().pool_cached_texture_count;
    old = {};
    EXPECT_EQ(device.tex_cache().VideoSubmissionStats().pool_cached_texture_count, count);
    fresh = {};
    ASSERT_TRUE(device.tex_cache().Clear());
    ::testing::FLAGS_gtest_death_test_style = "threadsafe";
    EXPECT_EXIT({
        alarm(5);
        auto terminal = std::make_unique<TextureCache>(device);
        auto input = std::make_shared<SyntheticVideo>();
        auto held = Register("terminal-loss", input, terminal.get());
        Require(terminal->WaitForPendingUploads(), "complete actual import before simulated loss");
        VkRequire(device.handle().WaitIdle(), "real idle before simulated loss");
        {
            DispatchScope scope(device); scope.idle_result = VK_ERROR_DEVICE_LOST;
            Require(device.handle().WaitIdle() == VK_ERROR_DEVICE_LOST, "controlled loss");
            terminal->DiscardAfterDeviceLoss();
            Require(!terminal->BeginVideoFrameRecording(), "lost cache must stay terminal");
            held = {}; terminal.reset();
        }
        _exit(0);
    }, ::testing::ExitedWithCode(0), "");
    EXPECT_EXIT({
        alarm(5);
        std::set_terminate([] { _exit(73); });
        auto terminal = std::make_unique<TextureCache>(device);
        auto input = std::make_shared<SyntheticVideo>();
        auto held = Register("terminal-unknown", input, terminal.get());
        // A submitted frame never completed: the frames it pinned are still
        // logically on the GPU, and the queue then fails to prove otherwise.
        Require(terminal->BeginVideoFrameRecording(), "begin the unfinished frame");
        terminal->PinVideoFrame(held);
        terminal->MarkVideoFrameSubmitted();
        held = {};
        DispatchScope scope(device); scope.idle_result = VK_ERROR_UNKNOWN;
        terminal.reset();
        _exit(74);
    }, ::testing::ExitedWithCode(73), "");
}

TEST_F(PlaybackGPU, PartialUploadsPreserveUntouchedBytes) {
    StagingBuffer staging(device, 256, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
    ASSERT_TRUE(staging.allocate()); StagingBufferRef ref; ASSERT_TRUE(staging.allocateSubRef(256, ref));
    UploadBuffer(staging); Bytes expected(256, 0); EXPECT_EQ(BufferRead(staging, 256), expected);
    const auto write = [&](size_t offset, Bytes bytes) {
        Require(staging.writeToBuf(ref, bytes, offset), "partial staging write");
        std::copy(bytes.begin(), bytes.end(), expected.begin() + offset);
    };
    write(5, {0x11,0x22,0x33}); write(69, {0xa1,0xa2,0xa3,0xa4,0xa5,0xa6,0xa7});
    write(8, {0x44,0x55}); write(6, {0x66,0x77});
    ASSERT_TRUE(staging.writeToBuf(ref, {}, 0)); ASSERT_TRUE(staging.writeToBuf(ref, {}, 256));
    {
        DispatchScope scope(device); scope.watched_destination = staging.gpuBuf();
        UploadBuffer(staging);
        ASSERT_EQ(scope.copies.size(), 2u);
        EXPECT_EQ(scope.copies[0].srcOffset, 4u); EXPECT_EQ(scope.copies[0].dstOffset, 4u); EXPECT_EQ(scope.copies[0].size, 8u);
        EXPECT_EQ(scope.copies[1].srcOffset, 68u); EXPECT_EQ(scope.copies[1].dstOffset, 68u); EXPECT_EQ(scope.copies[1].size, 8u);
    }
    EXPECT_EQ(BufferRead(staging, 256), expected);
    write(5, {0x11,0x66,0x77});
    {
        DispatchScope scope(device); scope.watched_destination = staging.gpuBuf(); UploadBuffer(staging);
        EXPECT_TRUE(scope.copies.empty());
    }
    EXPECT_EQ(BufferRead(staging, 256), expected);
}

TEST_F(PlaybackGPU, DiscardedUploadRetriesAndPendingStorageCannotMutate) {
    StagingBuffer staging(device, 256, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
    ASSERT_TRUE(staging.allocate()); StagingBufferRef ref; ASSERT_TRUE(staging.allocateSubRef(256, ref));
    UploadBuffer(staging);
    Bytes value {11,22,33,44}; ASSERT_TRUE(staging.writeToBuf(ref, value, 5));
    Begin(); ASSERT_TRUE(staging.recordUpload(rr.command));
    VkRequire(rr.command.End(), "end discarded upload");
    VkRequire(rr.command.Reset(), "reset discarded upload"); staging.finishUpload(false); Abandon();
    Begin(); ASSERT_TRUE(staging.recordUpload(rr.command));
    Bytes replacement {99,88,77,66};
    EXPECT_FALSE(staging.writeToBuf(ref, replacement, 5));
    EXPECT_FALSE(staging.fillBuf(ref, 0, 256, 0xff));
    StagingBufferRef additional;
    EXPECT_FALSE(staging.allocateSubRef(512, additional));
    EXPECT_FALSE(staging.allocate()); EXPECT_FALSE(staging.recordUpload(rr.command));
    staging.unallocateSubRef(ref);
    VkRequire(SubmitOnly(), "submit retry"); VkRequire(rr.fence_frame.Wait(), "wait retry");
    staging.finishUpload(true); Complete();
    Bytes expected(256, 0); std::copy(value.begin(), value.end(), expected.begin() + 5);
    EXPECT_EQ(BufferRead(staging, 256), expected);
    ASSERT_TRUE(staging.writeToBuf(ref, replacement, 5));
    ASSERT_TRUE(staging.allocateSubRef(512, additional)); UploadBuffer(staging);
    std::copy(replacement.begin(), replacement.end(), expected.begin() + 5);
    EXPECT_EQ(BufferRead(staging, 256), expected);
}

TEST_F(PlaybackGPU, GrowthReuploadsPreservedAndInitializedData) {
    StagingBuffer staging(device, 256, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
    for (bool before_first_upload : {false, true}) {
        ASSERT_TRUE(staging.allocate()); StagingBufferRef first, second;
        ASSERT_TRUE(staging.allocateSubRef(256, first)); Bytes pattern(256);
        for (size_t i = 0; i < pattern.size(); ++i) pattern[i] = static_cast<uint8_t>(i * 37 + 11);
        ASSERT_TRUE(staging.writeToBuf(first, pattern));
        if (!before_first_upload) UploadBuffer(staging);
        ASSERT_TRUE(staging.allocateSubRef(512, second));
        Bytes front {7,8,9,10}, back {21,22,23,24};
        ASSERT_TRUE(staging.writeToBuf(second, front)); ASSERT_TRUE(staging.writeToBuf(second, back, 508));
        UploadBuffer(staging);
        Bytes expected(second.offset + second.size, 0);
        std::copy(pattern.begin(), pattern.end(), expected.begin() + first.offset);
        std::copy(front.begin(), front.end(), expected.begin() + second.offset);
        std::copy(back.begin(), back.end(), expected.begin() + second.offset + 508);
        EXPECT_EQ(BufferRead(staging, expected.size()), expected);
        staging.destroy();
    }
    StagingBuffer odd(device, 260, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
    ASSERT_TRUE(odd.allocate()); StagingBufferRef first, aligned;
    ASSERT_TRUE(odd.allocateSubRef(260, first));
    const auto alignment = std::max<VkDeviceSize>(16, device.limits().minUniformBufferOffsetAlignment);
    ASSERT_TRUE(odd.allocateSubRef(64, aligned, alignment)); EXPECT_EQ(aligned.offset % alignment, 0u);
    ASSERT_TRUE(odd.fillBuf(aligned, 0, 64, 0x79)); UploadBuffer(odd);
    auto actual = BufferRead(odd, aligned.offset + aligned.size);
    Bytes expected(actual.size(), 0); std::fill(expected.begin() + aligned.offset, expected.end(), 0x79);
    EXPECT_EQ(actual, expected);
    auto& pass = Pass(false, true, {}, true); updater->color = {0,1,0,1}; Draw(pass);
    StagingBufferRef huge; ASSERT_TRUE(dynamic->allocateSubRef(8192, huge));
    updater->color = {0,0,1,1}; Draw(pass); ExpectSolid(Read(pass.desc().vk_output), {0,0,255,255});
}

TEST_F(PlaybackGPU, FrameUpdatesAreVisibleBeforeUpload) {
    for (bool batched : {true, false}) {
        updater->color = {1,0,0,1}; updater->geometry = {};
        auto& pass = Pass(false, true, {}, true);
        const auto set_half = [](SceneNode* node, bool right) {
            const float left = right ? 0.0f : -1.0f, right_x = right ? 1.0f : 0.0f;
            const std::array<float,8> positions {left,-1,right_x,-1,left,1,right_x,1};
            Require(node->Mesh()->GetVertexArray(0).SetVertexs(0, positions), "update dynamic geometry");
            node->Mesh()->SetDirty();
        };
        set_half(pass.desc().node, false);
        Draw(pass, batched);
        // A truly unchanged frame between initialization and this frame matters:
        // an upload-before-update implementation cannot hide behind initial dirt.
        Draw(pass, batched);
        updater->calls = 0;
        updater->color = {0,1,0,1}; updater->geometry = [&](SceneNode* n) { set_half(n, true); };
        Draw(pass, batched); EXPECT_EQ(updater->calls, 1u);
        auto bytes = Read(pass.desc().vk_output);
        for (uint32_t y = 0; y < 32; ++y) for (uint32_t x = 0; x < 32; ++x) {
            const auto i = (y * 32 + x) * 4;
            EXPECT_EQ(bytes[i], 0u); EXPECT_EQ(bytes[i+1], x >= 16 ? 255u : 0u); EXPECT_EQ(bytes[i+2], 0u);
        }
        updater->color = {0,0,1,1}; updater->geometry = [&](SceneNode* n) { set_half(n, false); };
        Draw(pass, batched); EXPECT_EQ(updater->calls, 2u);
        bytes = Read(pass.desc().vk_output);
        for (uint32_t y = 0; y < 32; ++y) for (uint32_t x = 0; x < 32; ++x) {
            const auto i = (y * 32 + x) * 4;
            EXPECT_EQ(bytes[i], 0u); EXPECT_EQ(bytes[i+1], 0u); EXPECT_EQ(bytes[i+2], x < 16 ? 255u : 0u);
        }
        pass.desc().visibility_node->SetVisible(false); Draw(pass, batched);
        EXPECT_EQ(updater->calls, 2u);
        // Stepped one pass at a time, a hidden pass records its first-use clear
        // itself. Batched, nothing reads this output, so the clear is left out;
        // what a reader sees is HiddenClearsAreRecordedOnlyWhereSomethingReadsThem.
        if (! batched) ExpectSolid(Read(pass.desc().vk_output), {0,0,0,0});
        updater->geometry = {};
    }
}

TEST_F(PlaybackGPU, GraphOrderingAndDescriptorWritesPreservePixels) {
    for (auto samples : {VK_SAMPLE_COUNT_1_BIT, VK_SAMPLE_COUNT_4_BIT}) {
        if (!(device.limits().framebufferColorSampleCounts & samples)) {
            RecordProperty("msaa4_variant", "not supported; single-sample cases still required"); continue;
        }
        const auto a_name = Target(), b_name = Target(), c_name = Target(), d_name = Target();
        auto& a = Pass(false, false, a_name, false, samples);
        auto& b = Pass(true, false, b_name, false, samples);
        ImageSlotsRef ar; ar.slots = {a.desc().vk_output}; Bind(b, ar);
        CopyPass copy(CopyPass::Desc {.src = b_name, .dst = c_name}); copy.prepare(scene, device, rr);
        ASSERT_TRUE(copy.prepared());
        auto& consumer = Pass(true, true, d_name, false, samples);
        updater->color = {1,1,1,1};
        ImageSlotsRef cr; cr.slots = {copy.desc().vk_dst}; Bind(consumer, cr);
        auto& adjacent = Pass(true, false, d_name, false, samples);
        adjacent.desc().preserve_target_contents = true; adjacent.desc().clear_on_first_use = false;
        Bind(adjacent, cr);
        auto& hidden = Pass(false, false, {}, false, samples); hidden.desc().visibility_node->SetVisible(false);
        std::array<VulkanPass*, 6> sequence {&a, &b, &copy, &consumer, &adjacent, &hidden};
        {
            DispatchScope scope(device); Frame(sequence);
            EXPECT_EQ(scope.pushes, 3u);
            EXPECT_EQ(scope.clears, 0u) << "nothing reads the hidden pass's output, so its clear "
                                           "must not be recorded";
        }
        ExpectSolid(Read(a.desc().vk_output), {0,255,0,255});
        ExpectSolid(Read(b.desc().vk_output), {0,255,0,255});
        ExpectSolid(Read(copy.desc().vk_dst), {0,255,0,255});
        ExpectSolid(Read(consumer.desc().vk_output), {0,255,0,255});
        EXPECT_EQ(b.desc().vk_texture_bindings[0].image_descriptor_type, VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE);
        EXPECT_GE(b.desc().vk_texture_bindings[0].sampler_binding, 0);
        for (bool uniform : {false, true}) {
            auto combined_shader = Compile(true, uniform, true);
            auto& combined = Pass(true, uniform, {}, false, samples, combined_shader);
            Bind(combined, cr);
            {
                DispatchScope scope(device); Draw(combined);
                EXPECT_EQ(scope.pushes, 1u);
            }
            EXPECT_EQ(combined.desc().vk_texture_bindings[0].image_descriptor_type,
                      VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER);
            EXPECT_EQ(combined.desc().vk_texture_bindings[0].sampler_binding, -1);
            ExpectSolid(Read(combined.desc().vk_output), {0,255,0,255});
        }
    }
}
// A target that carries its pixels into the next frame owns its image. It is
// not handed one that a target earlier in the frame released -- that target
// redraws it every frame -- and its own is never handed to a target after it.
TEST_F(PlaybackGPU, CarriedTargetsShareTheirImageWithNoOtherTarget) {
    auto&      cache = device.tex_cache();
    const auto key   = ToTexKey(SceneRenderTarget {.width = 24, .height = 40, .allowReuse = true});
    const auto earlier = cache.Query("_rt_carry_earlier", key);
    ASSERT_TRUE(earlier.has_value());
    cache.MarkShareReady("_rt_carry_earlier");

    scene.renderTargets["_rt_carry_history"] =
        SceneRenderTarget {.width = 24, .height = 40, .carriesPreviousFrame = true};
    ASSERT_TRUE(ReserveCarriedOverTargets(scene, cache));
    const auto history = cache.Query("_rt_carry_history", key, true);
    ASSERT_TRUE(history.has_value());
    EXPECT_NE(history->handle, earlier->handle);

    cache.MarkShareReady("_rt_carry_history");
    const auto later = cache.Query("_rt_carry_later", key);
    ASSERT_TRUE(later.has_value());
    EXPECT_NE(later->handle, history->handle);
    EXPECT_EQ(later->handle, earlier->handle) << "released images still go to the next target";
}

// The batched executor leaves a hidden layer's first-use clear out only when
// nothing can see the target. Every kind of reader keeps it, and a reader
// then samples the clear, not the pixels the layer drew before it was hidden.
TEST_F(PlaybackGPU, HiddenClearsAreRecordedOnlyWhereSomethingReadsThem) {
    const auto drawn_then_hidden = [&](std::string output = {},
                                       VkSampleCountFlagBits samples = VK_SAMPLE_COUNT_1_BIT)
        -> CustomShaderPass& {
        auto& pass = Pass(false, false, output, false, samples);
        Draw(pass);
        ExpectSolid(Read(pass.desc().vk_output), {0,255,0,255});
        pass.desc().visibility_node->SetVisible(false);
        return pass;
    };
    const auto reader_of = [&](CustomShaderPass& source) -> CustomShaderPass& {
        auto& reader = Pass(true, false);
        ImageSlotsRef ref; ref.slots = {source.desc().vk_output}; Bind(reader, ref);
        return reader;
    };
    const auto clears = [&](std::span<VulkanPass* const> passes,
                            std::span<VulkanPass* const> graph = {}) {
        DispatchScope scope(device); Frame(passes, true, graph);
        return scope.clears;
    };
    for (auto samples : {VK_SAMPLE_COUNT_1_BIT, VK_SAMPLE_COUNT_4_BIT}) {
        if (!(device.limits().framebufferColorSampleCounts & samples)) {
            RecordProperty("msaa4_variant", "not supported; single-sample cases still required"); continue;
        }
        SCOPED_TRACE(samples == VK_SAMPLE_COUNT_1_BIT ? "single-sample source" : "4x MSAA source");
        auto& hidden = drawn_then_hidden({}, samples);
        auto& reader = reader_of(hidden);
        std::array<VulkanPass*, 2> sequence {&hidden, &reader};
        EXPECT_EQ(clears(sequence), samples == VK_SAMPLE_COUNT_1_BIT ? 1u : 2u)
            << "a visible reader later in the frame keeps the clear (resolve and MSAA image)";
        ExpectSolid(Read(reader.desc().vk_output), {0,0,0,0});
    }
    {
        SCOPED_TRACE("a reader earlier in the frame samples what the previous frame's clear left");
        auto& hidden = drawn_then_hidden();
        auto& reader = reader_of(hidden);
        reader.desc().visibility_node->SetVisible(false);
        std::array<VulkanPass*, 2> sequence {&reader, &hidden};
        EXPECT_EQ(clears(sequence), 1u)
            << "kept while the earlier reader is hidden too; nothing reads the reader's own output";
        reader.desc().visibility_node->SetVisible(true);
        EXPECT_EQ(clears(sequence), 1u);
        ExpectSolid(Read(reader.desc().vk_output), {0,0,0,0});
    }
    {
        SCOPED_TRACE("a later reader that is hidden sees nothing now and gets the clear when it draws");
        auto& hidden = drawn_then_hidden();
        auto& reader = reader_of(hidden);
        reader.desc().visibility_node->SetVisible(false);
        std::array<VulkanPass*, 2> sequence {&hidden, &reader};
        EXPECT_EQ(clears(sequence), 0u);
        reader.desc().visibility_node->SetVisible(true);
        EXPECT_EQ(clears(sequence), 1u);
        ExpectSolid(Read(reader.desc().vk_output), {0,0,0,0});
    }
    {
        SCOPED_TRACE("a copy that reads the target, even one left out of this frame's execution");
        auto& hidden = drawn_then_hidden();
        const auto source = hidden.desc().output;
        CopyPass copy(CopyPass::Desc {.src = source, .dst = Target()});
        copy.prepare(scene, device, rr);
        ASSERT_TRUE(copy.prepared());
        std::array<VulkanPass*, 1> executed {&hidden};
        std::array<VulkanPass*, 2> graph {&hidden, &copy};
        EXPECT_EQ(clears(executed, graph), 1u);
        ExpectSolid(Read(hidden.desc().vk_output), {0,0,0,0});
        EXPECT_EQ(clears(graph), 1u);
        ExpectSolid(Read(copy.desc().vk_dst), {0,0,0,0});
    }
    {
        SCOPED_TRACE("a later pass that draws over the target without clearing it loads it");
        auto& hidden = drawn_then_hidden();
        // Something else in between, so the clear is an isolated one and not
        // the opening of the loading draw's own render pass.
        auto& between = Pass(false, false);
        auto& over = Pass(false, false, hidden.desc().output, false, VK_SAMPLE_COUNT_1_BIT, {},
                          [](CustomShaderPass::Desc& desc) {
                              desc.preserve_target_contents = true; desc.clear_on_first_use = false;
                          });
        std::array<VulkanPass*, 3> sequence {&hidden, &between, &over};
        EXPECT_EQ(clears(sequence), 1u);
        over.desc().visibility_node->SetVisible(false);
        EXPECT_EQ(clears(sequence), 0u) << "the loading draw is hidden too: nothing reads either";
    }
    {
        SCOPED_TRACE("the scene output is always read after the frame");
        scene.renderTargets[std::string(SpecTex_Default)] = SceneRenderTarget {.width = 32, .height = 32};
        scene.clearColor = {0,0,1};
        auto& hidden = drawn_then_hidden(std::string(SpecTex_Default));
        std::array<VulkanPass*, 1> sequence {&hidden};
        EXPECT_EQ(clears(sequence), 1u);
        ExpectSolid(Read(hidden.desc().vk_output), {0,0,255,255});
    }
}

TEST_F(PlaybackGPU, AttachmentToFinalPreservesNonuniformPixelsAcrossReuse) {
    const std::string output(SpecTex_Default);
    scene.renderTargets[output] = SceneRenderTarget {.width = 33, .height = 19};
    auto shader = Compile(false, false, false,
        "gl_FragCoord.x < 16.0 ? vec4(1.0,0.0,0.0,1.0) : vec4(0.0,0.0,1.0,1.0)");
    auto& producer = Pass(false, false, output, false, VK_SAMPLE_COUNT_1_BIT, shader);
    const auto present = ImageFor(Target(33, 19));
    auto& final = Final(present);
    ASSERT_TRUE(final.prepared());
    std::array<VulkanPass*, 2> sequence {&producer, &final};
    const auto expected = StripePixels(33, 19);
    for (bool batched : {true, false}) for (int repeat = 0; repeat < 3; ++repeat) {
        Frame(sequence, batched);
        EXPECT_EQ(Read(producer.desc().vk_output), expected);
        EXPECT_EQ(Read(present), expected);
    }
}

TEST_F(PlaybackGPU, CopyGeneratesEveryMipBeforeSamplingAndReuse) {
    const auto source = Target(32, 32), destination = Target(32, 32);
    scene.renderTargets[destination].has_mipmap = true;
    scene.renderTargets[destination].mipmap_level = 6;
    auto& producer = Pass(false, true, source);
    CopyPass copy(CopyPass::Desc {.src = source, .dst = destination});
    copy.prepare(scene, device, rr);
    ASSERT_TRUE(copy.prepared());
    std::vector<CustomShaderPass*> consumers;
    std::vector<VulkanPass*> sequence {&producer, &copy};
    for (unsigned mip = 0; mip < 6; ++mip) {
        auto shader = Compile(true, false, false,
            "textureLod(g_Texture0,v_Uv," + std::to_string(mip) + ".0)");
        auto& consumer = Pass(true, false, {}, false, VK_SAMPLE_COUNT_1_BIT, shader);
        ImageSlotsRef ref; ref.slots = {copy.desc().vk_dst}; Bind(consumer, ref);
        consumers.push_back(&consumer); sequence.push_back(&consumer);
    }
    for (bool batched : {true, false}) for (const auto color : {Color {255,0,0,255}, Color {0,0,255,255}}) {
        updater->color = {color[0] / 255.0f, color[1] / 255.0f, color[2] / 255.0f, 1};
        Frame(sequence, batched);
        ExpectSolid(Read(copy.desc().vk_dst), color);
        for (auto* consumer : consumers) ExpectSolid(Read(consumer->desc().vk_output), color);
    }
}

TEST_F(PlaybackGPU, PriorVertexAndFragmentReadersSurviveEveryOverwriteKind) {
    const auto target = Target();
    auto& writer = Pass(false, true, target);
    auto& fragment_reader = Pass();
    auto vertex_shader = Compile(true, false, false, "v_Color", true);
    auto& vertex_reader = Pass(true, false, {}, false, VK_SAMPLE_COUNT_1_BIT, vertex_shader);
    auto& hidden_clear = Pass(false, false, target);
    hidden_clear.desc().visibility_node->SetVisible(false);
    scene.clearColor = {0,0,1};
    auto& pre = ClearPass(target);
    ImageSlotsRef ref; ref.slots = {writer.desc().vk_output};
    Bind(fragment_reader, ref); Bind(vertex_reader, ref);
    for (bool batched : {true, false}) for (VulkanPass* overwrite :
         std::array<VulkanPass*,3> {&pre, &hidden_clear, &writer}) {
        updater->color = {1,0,0,1}; Draw(writer, batched);
        updater->color = {0,0,1,1};
        std::array<VulkanPass*,3> sequence {&vertex_reader, &fragment_reader, overwrite};
        Frame(sequence, batched);
        ExpectSolid(Read(vertex_reader.desc().vk_output), {255,0,0,255});
        ExpectSolid(Read(fragment_reader.desc().vk_output), {255,0,0,255});
        ExpectSolid(Read(writer.desc().vk_output),
                    overwrite == &hidden_clear ? Color {0,0,0,0} : Color {0,0,255,255});
    }
}

TEST_F(PlaybackGPU, FramebufferFailureStopsRecordingWithoutSubmittingOrWaiting) {
    const std::string output(SpecTex_Default);
    scene.renderTargets[output] = SceneRenderTarget {.width = 32, .height = 32};
    auto source = std::make_shared<SyntheticVideo>(); source->Set(1, 80, 170, 100);
    auto ref = Register("failed-final", source); auto retained = ref;
    auto& producer = Pass(true, false, output); Bind(producer, ref);
    const auto expected = Reference(*source);
    const auto target = ImageFor(Target());
    auto& final = Final(target); ASSERT_TRUE(final.prepared());
    auto& trailing = Pass(false, false);
    std::array<VulkanPass*,3> sequence {&producer, &final, &trailing};
    ASSERT_TRUE(device.tex_cache().WaitForPendingUploads());
    Begin(); ASSERT_TRUE(UpdatePreparedPasses(device, rr, sequence)); Upload();
    {
        DispatchScope scope(device); scope.fail_framebuffer = true;
        EXPECT_EQ(CheckRecording(ExecutePreparedPasses(device, rr, sequence, scratch)), VK_ERROR_OUT_OF_DEVICE_MEMORY);
        EXPECT_EQ(scope.submits, 0u); EXPECT_EQ(scope.waits, 0u);
        EXPECT_EQ(scope.draws, 1u);
    }
    EXPECT_FALSE(recording); EXPECT_FALSE(submitted);
    for (uint64_t generation = 2; generation < 9; ++generation) {
        source->Set(generation, 40 + generation * 20, 100, 170);
        ASSERT_TRUE(Update("failed-final", ref));
    }
    Bind(producer, retained);
    Frame(sequence);
    EXPECT_EQ(Read(target), expected);
    ExpectSolid(Read(trailing.desc().vk_output), {0,255,0,255});
}

TEST_F(PlaybackGPU, InvalidCopyStopsBeforeLaterPassAndCanRecover) {
    const auto source = Target(), destination = Target();
    auto& producer = Pass(false, false, source); Draw(producer);
    CopyPass copy(CopyPass::Desc {.src = source, .dst = destination});
    copy.prepare(scene, device, rr); ASSERT_TRUE(copy.prepared());
    auto& trailing = Pass(false, true);
    updater->color = {1,0,0,1}; Draw(trailing);
    const auto good = copy.desc().vk_src;
    copy.desc().vk_src = {};
    std::array<VulkanPass*,2> sequence {&copy, &trailing};
    Begin(); ASSERT_TRUE(UpdatePreparedPasses(device, rr, sequence)); Upload();
    {
        DispatchScope scope(device);
        EXPECT_EQ(CheckRecording(ExecutePreparedPasses(device, rr, sequence, scratch)), VK_ERROR_INITIALIZATION_FAILED);
        EXPECT_EQ(scope.submits, 0u); EXPECT_EQ(scope.waits, 0u); EXPECT_EQ(scope.draws, 0u);
    }
    ExpectSolid(Read(trailing.desc().vk_output), {255,0,0,255});
    copy.desc().vk_src = good;
    updater->color = {0,0,1,1}; Frame(sequence);
    ExpectSolid(Read(copy.desc().vk_dst), {0,255,0,255});
    ExpectSolid(Read(trailing.desc().vk_output), {0,0,255,255});
    CopyPass missing(CopyPass::Desc {.src = "_rt_missing", .dst = destination});
    missing.prepare(scene, device, rr); EXPECT_FALSE(missing.prepared());
}

TEST_F(PlaybackGPU, FinalPreparationDoesNotPublishPartialPipelines) {
    const std::string output(SpecTex_Default);
    scene.renderTargets[output] = SceneRenderTarget {.width = 32, .height = 32};
    ImageFor(output);
    const auto target = ImageFor(Target());
    for (int failure = 0; failure < 3; ++failure) {
        DispatchScope scope(device);
        scope.fail_descriptor_layout = failure == 0;
        scope.fail_pipeline_layout = failure == 1;
        scope.fail_shader_module = failure == 2;
        auto& final = Final(target);
        EXPECT_FALSE(final.prepared());
        EXPECT_EQ(scope.submits, 0u); EXPECT_EQ(scope.draws, 0u);
    }
}
TEST_F(PlaybackGPU, CopyPreservesNonuniformPatternBeforeSampling) {
    const auto source = Target(33, 19), destination = Target(33, 19);
    auto shader = Compile(false, false, false,
        "gl_FragCoord.x < 16.0 ? vec4(1.0,0.0,0.0,1.0) : vec4(0.0,0.0,1.0,1.0)");
    auto& producer = Pass(false, false, source, false, VK_SAMPLE_COUNT_1_BIT, shader);
    CopyPass copy(CopyPass::Desc {.src = source, .dst = destination});
    copy.prepare(scene, device, rr); ASSERT_TRUE(copy.prepared());
    auto& consumer = Pass(true, false, Target(33,19));
    ImageSlotsRef ref; ref.slots = {copy.desc().vk_dst}; Bind(consumer, ref);
    std::array<VulkanPass*,3> sequence {&producer,&copy,&consumer};
    const auto expected = StripePixels(33,19);
    for (bool batched : {true,false}) for(int repeat=0;repeat<3;++repeat) {
        Frame(sequence,batched);
        EXPECT_EQ(Read(copy.desc().vk_dst),expected);
        EXPECT_EQ(Read(consumer.desc().vk_output),expected);
    }
}

TEST(SceneSurface, DeferredBackendRetainsTheLayerUntilTheSceneIsDeleted) {
    owe_scene_wallpaper* raw = nullptr;
    ASSERT_EQ(owe_scene_wallpaper_new(&raw), 0);
    std::unique_ptr<owe_scene_wallpaper, decltype(&owe_scene_wallpaper_delete)>
        scene(raw, owe_scene_wallpaper_delete);
    ASSERT_EQ(owe_scene_wallpaper_init(scene.get()), 0);
    __weak CAMetalLayer* weak_layer = nil;
    @autoreleasepool {
        CAMetalLayer* layer = [CAMetalLayer layer];
        weak_layer = layer;
        // No scene or window: initialization queues the layer without creating
        // a GPU backend, as it does while startup is still loading a wallpaper.
        ASSERT_EQ(owe_scene_wallpaper_init_metal_vulkan(
            scene.get(), (__bridge void*)layer, 32, 32, 0, 0, 1.0), 0);
    }
    // Drain Core Animation's implicit transaction so only the scene owns it.
    [CATransaction flush];
    @autoreleasepool {
        EXPECT_TRUE(weak_layer != nil);
        ASSERT_EQ(owe_scene_wallpaper_shutdown(scene.get()), 0);
        scene.reset();
    }
    EXPECT_TRUE(weak_layer == nil);
}

TEST_F(PlaybackGPU, CopyPreparesAgainAfterRenderTargetsAreDroppedAndResized) {
    // What a render-scale change does: destroy every pass, drop the render
    // targets, resize them, then prepare only the passes reporting unprepared.
    const auto source = Target(), destination = Target();
    auto& producer = Pass(false, false, source);
    CopyPass copy(CopyPass::Desc {.src = source, .dst = destination});
    copy.prepare(scene, device, rr); ASSERT_TRUE(copy.prepared());
    std::array<VulkanPass*,2> sequence {&producer, &copy};
    Frame(sequence);
    ExpectSolid(Read(copy.desc().vk_dst), {0,255,0,255});

    for (auto* pass : sequence) pass->destory(device, rr);
    ASSERT_FALSE(copy.prepared());
    ASSERT_TRUE(device.tex_cache().ClearRenderTargets());
    for (const auto& name : {source, destination})
        scene.renderTargets[name] = SceneRenderTarget {.width = 24, .height = 24};
    for (auto* pass : sequence) if (!pass->prepared()) pass->prepare(scene, device, rr);
    ASSERT_TRUE(producer.prepared()); ASSERT_TRUE(copy.prepared());
    EXPECT_EQ(copy.desc().vk_src.extent.width, 24u);
    EXPECT_EQ(copy.desc().vk_dst.extent.width, 24u);
    Frame(sequence);
    ExpectSolid(Read(copy.desc().vk_dst), {0,255,0,255});
}

// Static reuse skips a pinned target's writers, so it may only pin an image no
// other target's passes still draw into. A pooled image handed on by a key that
// released it is drawn into by that key's prepared passes every frame: pinning
// the new holder kept the other target's pixels where its own skipped draw
// belonged, and a layer read another layer's picture from the second frame on.
TEST_F(PlaybackGPU, LastUseReleasesEveryInputAgainAfterRepreparation) {
    auto& cache = device.tex_cache();
    const auto first = Target(), second = Target(), output = Target(16, 16);
    const auto next_first = Target(), next_second = Target();
    PrePass consumer(PrePass::Desc { .result = output });
    const std::array<std::string_view, 2> released { first, second };
    consumer.setReleaseTexs(released);
    for (int preparation = 0; preparation < 2; ++preparation) {
        const auto query = [&](const std::string& key) {
            const auto value = cache.Query(key, ToTexKey(scene.renderTargets.at(key)));
            Require(value.has_value(), "allocate pooled target");
            return value->handle;
        };
        const std::set<VkImage> original { query(first), query(second) };
        ASSERT_EQ(original.size(), 2u);
        consumer.prepare(scene, device, rr);
        ASSERT_TRUE(consumer.prepared());
        EXPECT_EQ((std::set<VkImage> {query(next_first), query(next_second)}), original);
        consumer.destory(device, rr);
        ASSERT_TRUE(cache.ClearRenderTargets());
    }
}

TEST_F(PlaybackGPU, LiveClearColorReachesTheNextFrameWithoutRepreparation) {
    scene.clearColor = {1.0f, 0.0f, 0.0f};
    const auto target = Target(4, 4);
    auto& clear = ClearPass(target);
    const std::array<VulkanPass*, 1> sequence {&clear};
    Frame(sequence, false);
    ExpectSolid(Read(ImageFor(target)), {255, 0, 0, 255});
    scene.clearColor = {0.0f, 1.0f, 0.0f};
    Frame(sequence, false);
    ExpectSolid(Read(ImageFor(target)), {0, 255, 0, 255});
}

TEST_F(PlaybackGPU, LiveBackgroundReachesHiddenDrawAndFinalMargins) {
    const std::string output(SpecTex_Default);
    scene.renderTargets[output] = SceneRenderTarget { .width = 8, .height = 8 };
    scene.clearColor = {1.0f, 0.0f, 0.0f};
    auto& hidden = Pass(false, false, output);
    hidden.desc().visibility_node->SetVisible(false);
    const auto target = ImageFor(Target(16, 16));
    auto& final = Final(target);
    ASSERT_TRUE(final.prepared());
    rr.wallpaper_viewport = {4, 12, 8, -8, 0, 1};
    rr.wallpaper_scissor = {{4, 4}, {8, 8}};
    const std::array<VulkanPass*, 2> sequence {&hidden, &final};
    Frame(sequence);
    ExpectSolid(Read(target), {255, 0, 0, 255});
    scene.clearColor = {0.0f, 1.0f, 0.0f};
    Frame(sequence);
    ExpectSolid(Read(hidden.desc().vk_output), {0, 255, 0, 255});
    ExpectSolid(Read(target), {0, 255, 0, 255});
}

TEST_F(PlaybackGPU, TransparentClearRemainsTransparentWhenTheBackgroundChanges) {
    const auto target = Target(4, 4);
    PrePass clear(PrePass::Desc { .result = target, .transparent = true });
    clear.prepare(scene, device, rr);
    ASSERT_TRUE(clear.prepared());
    const std::array<VulkanPass*, 1> sequence {&clear};
    for (const auto color : {std::array<float, 3> {1, 0, 0}, std::array<float, 3> {0, 1, 0}}) {
        scene.clearColor = color;
        Frame(sequence, false);
        ExpectSolid(Read(ImageFor(target)), {0, 0, 0, 0});
    }
    clear.destory(device, rr);
}

TEST_F(PlaybackGPU, APooledImageAnotherTargetStillDrawsIntoIsNeverPinned) {
    auto&      cache = device.tex_cache();
    const auto first = Target(), second = Target(), own = Target(), alias = Target();
    const auto query = [&](const std::string& name) {
        auto image = cache.Query(name, ToTexKey(scene.renderTargets.at(name)));
        Require(image.has_value(), "allocate pooled target");
        return image->handle;
    };
    const auto shared = query(first);
    cache.MarkShareReady(first);
    ASSERT_EQ(query(second), shared) << "the pool hands the released image on";
    EXPECT_FALSE(cache.PinRenderTarget(first)) << "released, so no longer its own";
    EXPECT_FALSE(cache.PinRenderTarget(second)) << "the first target's passes still draw into it";

    EXPECT_NE(query(own), shared);
    ASSERT_TRUE(cache.AliasRenderTarget(alias, own));
    EXPECT_TRUE(cache.PinRenderTarget(own)) << "an elided copy's alias writes nothing";
}

TEST_F(PlaybackGPU, QueryFailureLeavesCopyAndFinalUnprepared) {
    const auto source = Target(), destination = Target();
    CopyPass copy(CopyPass::Desc {.src=source,.dst=destination});
    {
        DispatchScope scope(device); scope.fail_image_view = true;
        copy.prepare(scene,device,rr);
        EXPECT_FALSE(copy.prepared());
    }
    const std::string output(SpecTex_Default);
    scene.renderTargets[output] = SceneRenderTarget {.width=32,.height=32};
    const auto target = ImageFor(Target());
    {
        DispatchScope scope(device); scope.fail_image_view = true;
        auto& final=Final(target);
        EXPECT_FALSE(final.prepared());
    }
}

TEST_F(PlaybackGPU, FinalPreparationRejectsPendingVertexStorage) {
    const std::string output(SpecTex_Default);
    scene.renderTargets[output] = SceneRenderTarget {.width=32,.height=32};
    ImageFor(output);
    const auto target = ImageFor(Target());
    Begin(); Upload();
    auto& final=Final(target);
    EXPECT_FALSE(final.prepared());
    Abandon();
    auto& recovered=Final(target);
    ASSERT_TRUE(recovered.prepared());
    auto& writer=Pass(false,false,output);
    std::array<VulkanPass*,2> sequence {&writer,&recovered};
    Frame(sequence);
    ExpectSolid(Read(target),{0,255,0,255});
}
TEST_F(PlaybackGPU, RedundantClearTracksVisibilityReadinessAndPhysicalReaders) {
    const std::string output(SpecTex_Default);
    scene.renderTargets[output]=SceneRenderTarget {.width=32,.height=32};
    scene.clearColor={0,0,1};
    auto& pre=ClearPass(output);
    auto& writer=Pass(false,false,output);
    auto& reader=Pass();
    reader.desc().clear_on_first_use=false;
    ImageSlotsRef source; source.slots={writer.desc().vk_output}; Bind(reader,source);
    std::array<VulkanPass*,2> simple {&pre,&writer};
    const std::array<ImageParameters,1> target {writer.desc().vk_output};
    CompareClearPaths(simple,target,1);
    ExpectSolid(Read(target[0]),{0,255,0,255});
    writer.desc().visibility_node->SetVisible(false);
    CompareClearPaths(simple,target,1);
    ExpectSolid(Read(target[0]),{0,0,255,255});
    writer.desc().visibility_node->SetVisible(true);
    const std::array<VulkanPass*,3> with_reader {&pre,&reader,&writer};
    const std::array<ImageParameters,2> both {reader.desc().vk_output,writer.desc().vk_output};
    CompareClearPaths(with_reader,both,0);
    ExpectSolid(Read(both[0]),{0,0,255,255});
    reader.desc().visibility_node->SetVisible(false);
    CompareClearPaths(with_reader,target,1);
    reader.desc().visibility_node->SetVisible(true);
    reader.desc().vk_textures[0]={};
    CompareClearPaths(with_reader,target,1);
    Bind(reader,source);
    CompareClearPaths(with_reader,both,0);
    // Same descriptor slot, now a different physical image: no read of pre's target.
    auto& unrelated=Pass(false,false); Draw(unrelated);
    source.slots={unrelated.desc().vk_output}; Bind(reader,source);
    CompareClearPaths(with_reader,both,1);
    ExpectSolid(Read(both[0]),{0,255,0,255});
    auto unprepared=std::make_unique<CustomShaderPass>(CustomShaderPass::Desc {});
    const std::array<VulkanPass*,4> gaps {&pre,nullptr,unprepared.get(),&writer};
    CompareClearPaths(gaps,target,1);
}

TEST_F(PlaybackGPU, ClearLookaheadStopsAtPassBoundariesAndUnequalClearColors) {
    const std::string output(SpecTex_Default);
    scene.renderTargets[output]=SceneRenderTarget {.width=32,.height=32};
    scene.clearColor={0,0,1};
    auto& pre=ClearPass(output);
    auto& writer=Pass(false,false,output);
    const std::array<ImageParameters,1> target {writer.desc().vk_output};
    auto& other=Pass(false,false); Draw(other);
    auto& another_pre=ClearPass(other.desc().output);
    CopyPass copy(CopyPass::Desc {.src=other.desc().output,.dst=Target()});
    copy.prepare(scene,device,rr); ASSERT_TRUE(copy.prepared());
    const auto present=ImageFor(Target());
    auto& final=Final(present); ASSERT_TRUE(final.prepared());
    for(VulkanPass* boundary:std::array<VulkanPass*,3>{&copy,&another_pre,&final}) {
        const std::array<VulkanPass*,3> sequence {&pre,boundary,&writer};
        CompareClearPaths(sequence,target,0);
    }
    // Clear values are prepared frame state, refreshed from each pass's scene.
    // Separate scene sources exercise unequal values through that real update
    // contract instead of patching state that the next update replaces.
    Scene clear_scene;
    clear_scene.renderTargets[output]=scene.renderTargets.at(output);
    clear_scene.clearColor={0,0,1};
    PrePass independent_pre(PrePass::Desc {.result=output});
    independent_pre.prepare(clear_scene,device,rr);
    ASSERT_TRUE(independent_pre.prepared());
    auto& color_writer=Pass(false,false,output,true);
    const std::array<float,8> left_half {-1,-1,0,-1,-1,1,0,1};
    ASSERT_TRUE(color_writer.desc().node->Mesh()->GetVertexArray(0).SetVertexs(0,left_half));
    color_writer.desc().node->Mesh()->SetDirty();
    const std::array<VulkanPass*,2> simple {&independent_pre,&color_writer};
    for (const float red : {1.0f,-0.0f,0.0f}) {
        SCOPED_TRACE(red);
        scene.clearColor[0]=red;
        const uint64_t removed=red == 0.0f && !std::signbit(red) ? 1 : 0;
        CompareClearPaths(simple,target,removed); // Equality includes the sign bit of zero.
        const auto pixels=Read(target[0]);
        const Color clear {red == 1.0f ? uint8_t(255) : uint8_t(0),0,255,255};
        for (uint32_t y=0;y<32;++y) for (uint32_t x=0;x<32;++x) {
            const auto i=(y*32+x)*4;
            EXPECT_EQ((Color {pixels[i],pixels[i+1],pixels[i+2],pixels[i+3]}),
                      (x<16 ? Color {0,255,0,255} : clear)) << x << ',' << y;
        }
    }
    auto& load_writer=Pass(false,false,output,false,VK_SAMPLE_COUNT_1_BIT,{},
        [](auto& desc){desc.preserve_target_contents=true;desc.clear_on_first_use=false;});
    const std::array<VulkanPass*,2> load {&pre,&load_writer};
    CompareClearPaths(load,target,0);
}

// A composite cleared to transparent, then drawn into: opening the first draw
// with the same transparent clear leaves exactly the bytes the clear followed
// by a loading draw left, and the separate transfer clear is then dropped.
TEST_F(PlaybackGPU, FirstDrawAfterATransparentClearOpensWithItByteForByte) {
    const auto name = Target();
    auto& stale = Pass(false, false, name);
    auto pre_owner = std::make_unique<PrePass>(PrePass::Desc {.result = name, .transparent = true});
    pre_owner->prepare(scene, device, rr);
    ASSERT_TRUE(pre_owner->prepared());
    auto& pre = *pre_owner; auxiliary_passes.push_back(std::move(pre_owner));
    const auto shader = Compile(false, false, false, "vec4(1.0,0.0,0.0,1.0)");
    const auto left_half = [](CustomShaderPass& pass) {
        const std::array<float,8> positions {-1,-1,0,-1,-1,1,0,1};
        Require(pass.desc().node->Mesh()->GetVertexArray(0).SetVertexs(0, positions), "left-half quad");
        pass.desc().node->Mesh()->SetDirty();
    };
    auto& loading = Pass(false, false, name, true, VK_SAMPLE_COUNT_1_BIT, shader,
        [](auto& desc) { desc.preserve_target_contents = true; desc.clear_on_first_use = false; });
    auto& opening = Pass(false, false, name, true, VK_SAMPLE_COUNT_1_BIT, shader,
        [](auto& desc) { desc.preserve_target_contents = false; desc.clear_on_first_use = true; });
    left_half(loading); left_half(opening);
    const auto result = loading.desc().vk_output;

    // Whatever the target held before must not show through either way.
    Draw(stale); ExpectSolid(Read(result), {0,255,0,255});
    std::array<VulkanPass*, 2> before {&pre, &loading};
    {
        DispatchScope scope(device); Frame(before);
        EXPECT_EQ(scope.clears, 1u) << "a loading draw keeps the separate clear";
    }
    const auto expected = Read(result);
    for (uint32_t y = 0; y < 32; ++y) for (uint32_t x = 0; x < 32; ++x) {
        const auto i = (y * 32 + x) * 4;
        const Color pixel {expected[i], expected[i+1], expected[i+2], expected[i+3]};
        EXPECT_EQ(pixel, (x < 16 ? Color {255,0,0,255} : Color {0,0,0,0})) << x << ',' << y;
    }

    Draw(stale); ExpectSolid(Read(result), {0,255,0,255});
    std::array<VulkanPass*, 2> after {&pre, &opening};
    {
        DispatchScope scope(device); Frame(after);
        EXPECT_EQ(scope.clears, 0u) << "the draw's own clear makes the separate one redundant";
    }
    EXPECT_EQ(Read(result), expected);
}

TEST_F(PlaybackGPU, ClearLookaheadRejectsViewMipMsaaAndAliasBoundaries) {
    const std::string output(SpecTex_Default);
    scene.renderTargets[output]=SceneRenderTarget {.width=32,.height=32};
    auto& pre=ClearPass(output);
    auto& writer=Pass(false,false,output);
    const auto original=writer.desc().vk_output;
    const std::array<ImageParameters,1> target {original};
    const std::array<VulkanPass*,2> sequence {&pre,&writer};
    vvk::ImageView alias;
    const VkImageViewCreateInfo info {.sType=VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image=original.handle,.viewType=VK_IMAGE_VIEW_TYPE_2D,.format=VK_FORMAT_R8G8B8A8_UNORM,
        .subresourceRange={VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1}};
    VkRequire(device.handle().CreateImageView(info,alias),"alias view");
    writer.desc().vk_output.view=*alias;
    CompareClearPaths(sequence,target,0);
    writer.desc().vk_output=original;
    alias_views.push_back(std::move(alias));
    writer.desc().vk_output.extent.depth=2;
    CompareClearPaths(sequence,target,0);
    writer.desc().vk_output=original;
    if(device.limits().framebufferColorSampleCounts & VK_SAMPLE_COUNT_4_BIT) {
        auto& msaa=Pass(false,false,output,false,VK_SAMPLE_COUNT_4_BIT);
        const std::array<VulkanPass*,2> msaa_sequence {&pre,&msaa};
        CompareClearPaths(msaa_sequence,target,0);
    }
    const auto mip_name=Target();
    scene.renderTargets[mip_name].has_mipmap=true;
    scene.renderTargets[mip_name].mipmap_level=3;
    scene.clearColor={0,0,0};
    auto& mip_pre=ClearPass(mip_name);
    auto& mip_writer=Pass(false,false,mip_name);
    // Match values so that the mip boundary, not color inequality, prevents removal.
    mip_writer.desc().clear_value=mip_pre.desc().clear_value;
    const std::array<VulkanPass*,2> mips {&mip_pre,&mip_writer};
    const std::array<ImageParameters,1> mip_target {mip_writer.desc().vk_output};
    CompareClearPaths(mips,mip_target,0);
    auto& alias_writer=Pass(true,false,output);
    ImageSlotsRef self; self.slots={original}; Bind(alias_writer,self);
    const std::array<VulkanPass*,2> feedback {&pre,&alias_writer};
    Begin(); ASSERT_TRUE(UpdatePreparedPasses(device,rr,feedback)); Upload();
    {
        DispatchScope scope(device);
        VkRequire(CheckRecording(ExecutePreparedPasses(device,rr,feedback,scratch)),"record feedback boundary");
        EXPECT_EQ(scope.clears,1u);
    }
    // Input/output feedback is deliberately never submitted: only prove the
    // optimizer retains its prior clear, without executing undefined feedback.
    Abandon();
}

TEST_F(PlaybackGPU, DirectSelectorRequiresOneResolvedFirstClearWriter) {
    const std::string output(SpecTex_Default);
    scene.renderTargets[output]=SceneRenderTarget {.width=32,.height=32};
    auto& writer=Pass(false,false,output);
    std::array<VulkanPass*,1> graph {&writer};
    EXPECT_EQ(FindDirectPresentationPass(scene,graph),&writer);
    auto& rt=scene.renderTargets[output];
    rt.withDepth=true; EXPECT_EQ(FindDirectPresentationPass(scene,graph),nullptr); rt.withDepth=false;
    rt.has_mipmap=true; EXPECT_EQ(FindDirectPresentationPass(scene,graph),nullptr); rt.has_mipmap=false;
    rt.mipmap_level=2; EXPECT_EQ(FindDirectPresentationPass(scene,graph),nullptr); rt.mipmap_level=1;
    rt.sample_count=4; EXPECT_EQ(FindDirectPresentationPass(scene,graph),nullptr); rt.sample_count=1;
    writer.desc().clear_on_first_use=false; EXPECT_EQ(FindDirectPresentationPass(scene,graph),nullptr);
    writer.desc().clear_on_first_use=true;
    writer.desc().preserve_target_contents=true; EXPECT_EQ(FindDirectPresentationPass(scene,graph),nullptr);
    writer.desc().preserve_target_contents=false;
    writer.desc().textures={"_rt_unknown_direct_input"};
    EXPECT_EQ(FindDirectPresentationPass(scene,graph),nullptr);
    scene.renderTargetAliases["_rt_direct_alias"]=output;
    writer.desc().textures={"_rt_direct_alias"};
    EXPECT_EQ(FindDirectPresentationPass(scene,graph),nullptr);
    writer.desc().textures={"synthetic/external.png",""};
    EXPECT_EQ(FindDirectPresentationPass(scene,graph),&writer);
    writer.desc().output="_rt_direct_alias";
    EXPECT_EQ(FindDirectPresentationPass(scene,graph),&writer);
    writer.desc().output=Target();
    EXPECT_EQ(FindDirectPresentationPass(scene,graph),nullptr);
    writer.desc().output=output;
    auto& second=Pass(false,false,output);
    const std::array<VulkanPass*,2> multiple {&writer,&second};
    EXPECT_EQ(FindDirectPresentationPass(scene,multiple),nullptr);
    CopyPass copy(CopyPass::Desc {.src=output,.dst=Target()});
    const std::array<VulkanPass*,1> copy_graph {&copy};
    EXPECT_EQ(FindDirectPresentationPass(scene,copy_graph),nullptr);
}

TEST_F(PlaybackGPU, DirectPrivateTargetsMatchNormalAcrossFormatsSizesAndPoisonRotation) {
    const std::string output(SpecTex_Default);
    for(auto format:{VK_FORMAT_R8G8B8A8_UNORM,VK_FORMAT_B8G8R8A8_UNORM})
    for(const auto size:{VkExtent2D{33,19},VkExtent2D{47,25}}) {
        // A new graph retires its named targets before preparing a new size/format.
        VkRequire(device.handle().WaitIdle(), "retire prior private graph");
        VkRequire(rr.command.Reset(), "reset prior private graph command");
        scratch.passes.clear(); scratch.candidates.clear(); scratch.plan.entries.clear();
        for (auto& pass : auxiliary_passes) pass->destory(device, rr);
        auxiliary_passes.clear();
        for (auto& pass : owned_passes) pass->destory(device, rr);
        owned_passes.clear();
        alias_views.clear();
        private_targets.clear();
        nodes.clear();
        Require(device.tex_cache().Clear(), "retire named render targets before resize");
        scene.renderTargets[output]=SceneRenderTarget {.width=static_cast<int>(size.width),.height=static_cast<int>(size.height)};
        scene.clearColor={0,0,0};
        auto shader=Compile(false,false,false,
            "vec4(gl_FragCoord.x < "+std::to_string(size.width/2)+".0 ? 1.0 : 0.0,"
            "gl_FragCoord.y < "+std::to_string(size.height/2)+".0 ? 1.0 : 0.0,0.0,0.5)");
        auto& writer=Pass(false,false,output,false,VK_SAMPLE_COUNT_1_BIT,shader,
            [format](auto& desc){desc.presentation_format=format;});
        auto& pre=ClearPass(output);
        std::array<ImageParameters,3> targets;
        for(auto& target:targets) target=PrivateTarget(size.width,size.height,format);
        auto& final=Final(targets[0],format); ASSERT_TRUE(final.prepared());
        for(unsigned turn=0;turn<9;++turn) {
            const auto& target=targets[turn%targets.size()];
            const std::array<float,4> poison {float(turn%2),float((turn+1)%2),1,1};
            Poison(target,poison);
            EXPECT_FALSE(PresentFrame(writer,final,pre,target,format,false));
            const auto reference=Read(target);
            const auto rgba=NormalizeColorBytes(reference,format);
            ASSERT_EQ(rgba.size(),size.width*size.height*4u);
            for(uint32_t y=0;y<size.height;++y) for(uint32_t x=0;x<size.width;++x) {
                const auto at=(y*size.width+x)*4;
                ASSERT_EQ(rgba[at],x<size.width/2 ? 255 : 0);
                ASSERT_EQ(rgba[at+1],y<size.height/2 ? 255 : 0);
                ASSERT_EQ(rgba[at+2],0);
                ASSERT_NEAR(rgba[at+3],128,1);
            }
            Poison(target,{0,1,1,1});
            EXPECT_TRUE(PresentFrame(writer,final,pre,target,format));
            EXPECT_EQ(Read(target),reference);
        }
    }
}

TEST_F(PlaybackGPU, DirectFallbackTransitionsPreserveFullFramesAndClearBackground) {
    const std::string output(SpecTex_Default);
    scene.renderTargets[output]=SceneRenderTarget {.width=33,.height=19};
    scene.clearColor={0,0,1};
    auto& source=Pass(false,false,Target(33,19));
    Draw(source);
    auto& writer=Pass(true,false,output,true,VK_SAMPLE_COUNT_1_BIT,{},
        [](auto& desc){desc.presentation_format=VK_FORMAT_R8G8B8A8_UNORM;});
    writer.desc().textures[0]="synthetic/external.png";
    ImageSlotsRef ref; ref.slots={source.desc().vk_output}; Bind(writer,ref);
    const std::array<float,8> half {-1,-1,0,-1,-1,1,0,1};
    ASSERT_TRUE(writer.desc().node->Mesh()->GetVertexArray(0).SetVertexs(0,half));
    writer.desc().node->Mesh()->SetDirty();
    auto& pre=ClearPass(output);
    const auto target=PrivateTarget(33,19,VK_FORMAT_R8G8B8A8_UNORM);
    auto& final=Final(target); ASSERT_TRUE(final.prepared());
    const auto compare=[&](bool expected_direct) {
        EXPECT_FALSE(PresentFrame(writer,final,pre,target,VK_FORMAT_R8G8B8A8_UNORM,false));
        const auto reference=Read(target);
        Poison(target,{1,0,1,1});
        EXPECT_EQ(PresentFrame(writer,final,pre,target,VK_FORMAT_R8G8B8A8_UNORM),expected_direct);
        EXPECT_EQ(Read(target),reference);
    };
    compare(true);
    auto pixels=Read(target);
    EXPECT_EQ((Color{pixels[0],pixels[1],pixels[2],pixels[3]}),(Color{0,255,0,255}));
    const auto right=(33*19-1)*4;
    EXPECT_EQ((Color{pixels[right],pixels[right+1],pixels[right+2],pixels[right+3]}),(Color{0,0,255,255}));
    writer.desc().visibility_node->SetVisible(false); compare(false);
    ExpectSolid(Read(target),{0,0,255,255});
    writer.desc().visibility_node->SetVisible(true); compare(true);
    writer.desc().vk_textures[0]={}; compare(false);
    ExpectSolid(Read(target),{0,0,255,255});
    Bind(writer,ref); compare(true);
    rr.wallpaper_horizontal_flip=true; compare(false);
    rr.wallpaper_horizontal_flip=false; compare(true);
    rr.wallpaper_viewport={0,19,32,-19,0,1}; compare(false);
    rr.wallpaper_viewport={}; compare(true);
    rr.wallpaper_scissor={{1,0},{32,19}}; compare(false);
    rr.wallpaper_scissor={}; compare(true);
    writer.desc().alpha_to_coverage=true; compare(false);
    writer.desc().alpha_to_coverage=false; compare(true);
    const auto larger=PrivateTarget(35,21,VK_FORMAT_R8G8B8A8_UNORM);
    EXPECT_FALSE(PresentFrame(writer,final,pre,larger,VK_FORMAT_R8G8B8A8_UNORM));
    compare(true);
}

// The plain-video scene's one layer, as production builds it, presented
// straight from its source through the final composition's viewport and
// scissor. It must leave exactly the bytes the copy followed by the final
// composition leaves, in every scaling mode, up and down, and on the frames
// where it cannot it must fall back to that path. Either way, a poster
// composed on request must be exactly the bytes the target received.
TEST_F(PlaybackGPU, PlainVideoPresentsThroughTheFinalViewportByteForByte) {
    std::string error;
    auto node = SceneWallpaperInputTestAccess::CreateVideoProjectNode("synthetic/video.mp4", &error);
    ASSERT_NE(node, nullptr) << error;
    nodes.push_back(node);
    const std::string output(SpecTex_Default);
    // Even, so a 2x reduction puts every sample exactly on a texel edge.
    constexpr uint32_t kWidth = 38, kHeight = 22;
    scene.renderTargets[output] = SceneRenderTarget {.width = kWidth, .height = kHeight};
    scene.clearColor = {0.25f, 0.5f, 0.75f};
    // Distinct neighbouring texels, so any difference in which texels reach a
    // target pixel, or how they are weighted, shows up.
    const auto frame_shader = Compile(false, false, false,
        "vec4(fract(gl_FragCoord.x*0.137+gl_FragCoord.y*0.011), fract(gl_FragCoord.y*0.291),"
        " fract((gl_FragCoord.x+gl_FragCoord.y)*0.071), 1.0)");
    auto& decoded = Pass(false, false, Target(kWidth, kHeight), false, VK_SAMPLE_COUNT_1_BIT, frame_shader);
    auto& smaller = Pass(false, false, Target(kWidth - 2, kHeight), false, VK_SAMPLE_COUNT_1_BIT, frame_shader);
    Draw(decoded); Draw(smaller);
    auto& pre = ClearPass(output);
    // The same texels in the BGRA layout imported video frames arrive in.
    const auto decoded_bgra = PrivateTarget(kWidth, kHeight, VK_FORMAT_B8G8R8A8_UNORM);
    {
        auto& writer = Pass(false, false, Target(kWidth, kHeight), false, VK_SAMPLE_COUNT_1_BIT,
                            frame_shader,
                            [](auto& d) { d.presentation_format = VK_FORMAT_B8G8R8A8_UNORM; });
        auto& copy = Final(decoded_bgra, VK_FORMAT_B8G8R8A8_UNORM); ASSERT_TRUE(copy.prepared());
        ASSERT_TRUE(PresentFrame(writer, copy, pre, decoded_bgra, VK_FORMAT_B8G8R8A8_UNORM));
        ASSERT_EQ(NormalizeColorBytes(Read(decoded_bgra), VK_FORMAT_B8G8R8A8_UNORM),
                  Read(decoded.desc().vk_output));
    }
    // Decoded frames are sampled linearly; the nearest variant proves the
    // source is resampled the way the copy is, not the way the source says.
    const auto make_sampler = [&](VkFilter filter) {
        const VkSamplerCreateInfo info {.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            .magFilter = filter, .minFilter = filter,
            .mipmapMode = VK_SAMPLER_MIPMAP_MODE_LINEAR,
            .addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .maxAnisotropy = 1.0f, .compareOp = VK_COMPARE_OP_NEVER, .maxLod = 1.0f,
            .borderColor = VK_BORDER_COLOR_INT_OPAQUE_BLACK};
        vvk::Sampler sampler;
        VkRequire(device.handle().CreateSampler(info, sampler), "create frame sampler");
        return sampler;
    };
    const vvk::Sampler linear = make_sampler(VK_FILTER_LINEAR);
    const vvk::Sampler nearest = make_sampler(VK_FILTER_NEAREST);
    const auto as_frame = [](ImageParameters image, VkSampler sampler) {
        image.sampler = sampler;
        ImageSlotsRef ref; ref.slots = {image}; return ref;
    };

    constexpr VkFormat format = VK_FORMAT_R8G8B8A8_UNORM;
    CustomShaderPass::Desc desc;
    desc.node = node.get(); desc.visibility_node = node.get(); desc.output = output;
    desc.textures = {""};
    desc.presentation_format = format;
    desc.presents_through_final_viewport = true;
    auto owned = std::make_unique<CustomShaderPass>(desc);
    // What the graph gives the scene output's first writer.
    owned->desc().clear_on_first_use = true;
    owned->desc().write_alpha = false;
    owned->prepare(scene, device, rr);
    ASSERT_TRUE(owned->prepared());
    auto& video = *owned; owned_passes.push_back(std::move(owned));

    struct Case {
        const char* name; WallpaperScalingMode mode; uint32_t w, h; double display_scale, user_scale;
        double pan_x = 0.5, pan_y = 0.5;
    };
    const std::array cases {
        Case {"fit, letterboxed, enlarged", WallpaperScalingMode::FIT, 64, 64, 1.0, 1.0},
        Case {"fill, cropped, enlarged", WallpaperScalingMode::FILL, 64, 64, 1.0, 1.0},
        Case {"stretch, exactly halved", WallpaperScalingMode::STRETCH, 19, 11, 1.0, 1.0},
        Case {"stretch, uneven reduction", WallpaperScalingMode::STRETCH, 27, 17, 1.0, 1.0},
        Case {"stretch, one and a half", WallpaperScalingMode::STRETCH, 57, 33, 1.0, 1.0},
        Case {"fit on a 2x display", WallpaperScalingMode::FIT, 30, 40, 2.0, 1.0},
        Case {"fill with the user's scale", WallpaperScalingMode::FILL, 50, 30, 1.0, 0.7},
        Case {"unscaled with the user's scale", WallpaperScalingMode::NONE, 50, 30, 1.0, 1.3},
        Case {"same size", WallpaperScalingMode::STRETCH, kWidth, kHeight, 1.0, 1.0},
        // Positioned: the same layout function places the picture anywhere in its
        // slack, and the direct present, the copy and the poster must agree there.
        Case {"fill, panned to the leading edges", WallpaperScalingMode::FILL, 64, 64, 1.0, 1.0, 0.0, 0.0},
        Case {"fill, panned to the trailing edges", WallpaperScalingMode::FILL, 64, 64, 1.0, 1.0, 1.0, 1.0},
        Case {"fit, panned to the trailing edge", WallpaperScalingMode::FIT, 64, 64, 1.0, 1.0, 1.0, 1.0},
        Case {"fit on a 2x display, panned to the top", WallpaperScalingMode::FIT, 30, 40, 2.0, 1.0, 0.5, 0.0},
        Case {"unscaled with the user's scale, panned", WallpaperScalingMode::NONE, 70, 50, 1.0, 1.3, 0.25, 0.75},
    };
    struct Source { const char* name; ImageParameters image; VkSampler sampler; };
    const std::array sources {
        Source {"RGBA, linear", decoded.desc().vk_output, *linear},
        Source {"BGRA, linear", decoded_bgra, *linear},
        Source {"RGBA, nearest", decoded.desc().vk_output, *nearest},
        Source {"BGRA, nearest", decoded_bgra, *nearest},
    };
    for (const auto& source : sources) for (const auto& c : cases) {
        SCOPED_TRACE(std::string(source.name) + "; " + c.name);
        Bind(video, as_frame(source.image, source.sampler));
        const auto layout = ComputeWallpaperScalingLayout(c.mode, kWidth, kHeight, c.w, c.h,
                                                          c.display_scale, c.user_scale,
                                                          c.pan_x, c.pan_y);
        rr.wallpaper_viewport = MakeWallpaperViewport(layout);
        rr.wallpaper_scissor = MakeWallpaperScissor(layout);
        const auto target = PrivateTarget(static_cast<uint32_t>(layout.scissor_px.width),
                                          static_cast<uint32_t>(layout.scissor_px.height), format);
        auto& final = Final(target, format); ASSERT_TRUE(final.prepared());
        const VkExtent2D extent {target.extent.width, target.extent.height};
        const auto compare = [&](bool expected_direct) {
            EXPECT_FALSE(PresentFrame(video, final, pre, target, format, false));
            const auto reference = Read(target);
            Poison(target, {1,0,1,1});
            const bool direct = PresentFrame(video, final, pre, target, format);
            EXPECT_EQ(direct, expected_direct);
            EXPECT_EQ(Read(target), reference);
            // A requested poster is exactly what the drawable received.
            EXPECT_EQ(ComposePoster(video, final, pre, extent, format, direct), reference);
            return reference;
        };
        const auto reference = compare(true);
        // The picture sits where the layout says. Bars are the clear colour, so
        // the first and last rows and columns that differ from it are the
        // picture's footprint in the window: a pan that is silently dropped
        // moves it, and fails here.
        {
            const std::array<uint8_t, 4> clear {64, 128, 191, 255};
            const auto width = static_cast<int32_t>(target.extent.width);
            const auto height = static_cast<int32_t>(target.extent.height);
            int32_t first_x = width, last_x = -1, first_y = height, last_y = -1;
            for (int32_t y = 0; y < height; ++y) for (int32_t x = 0; x < width; ++x) {
                const auto at = (static_cast<size_t>(y) * width + x) * 4;
                if (std::equal(clear.begin(), clear.end(), reference.begin() + at)) continue;
                first_x = std::min(first_x, x); last_x = std::max(last_x, x);
                first_y = std::min(first_y, y); last_y = std::max(last_y, y);
            }
            const auto& v = layout.viewport_px;
            EXPECT_EQ(first_x, std::max(0, v.x));
            EXPECT_EQ(last_x, std::min(width, v.x + v.width) - 1);
            EXPECT_EQ(first_y, std::max(0, v.y));
            EXPECT_EQ(last_y, std::min(height, v.y + v.height) - 1);
        }
        // A pan that has room to move changes the pixels; one that does not
        // (Stretch, or an axis the picture fills exactly) leaves them alone.
        if (c.pan_x != 0.5 || c.pan_y != 0.5) {
            const auto centred = ComputeWallpaperScalingLayout(c.mode, kWidth, kHeight, c.w, c.h,
                                                               c.display_scale, c.user_scale);
            rr.wallpaper_viewport = MakeWallpaperViewport(centred);
            EXPECT_FALSE(PresentFrame(video, final, pre, target, format, false));
            EXPECT_NE(Read(target), reference);
            rr.wallpaper_viewport = MakeWallpaperViewport(layout);
        }
        // Not a degenerate picture: the source's texels reached the target.
        std::set<Color> colors;
        for (size_t i = 0; i + 3 < reference.size(); i += 4)
            colors.insert({reference[i], reference[i+1], reference[i+2], reference[i+3]});
        EXPECT_GT(colors.size(), 8u);
        // Mirrored, the final composition samples differently: the copy path.
        rr.wallpaper_horizontal_flip = true; compare(false);
        rr.wallpaper_horizontal_flip = false;
        // A frame decoded smaller than the scene is resampled into the copy.
        Bind(video, as_frame(smaller.desc().vk_output, source.sampler)); compare(false);
        Bind(video, as_frame(source.image, source.sampler));
        // Any other pass keeps the old rule: only an identical target.
        video.desc().presents_through_final_viewport = false;
        compare(c.w == kWidth && c.h == kHeight && c.display_scale == 1.0 && c.user_scale == 1.0);
        video.desc().presents_through_final_viewport = true;
    }
    rr.wallpaper_viewport = {}; rr.wallpaper_scissor = {};
}

TEST_F(PlaybackGPU, DirectRecordingFailuresDoNotSubmitAndRecoverWithFreshTargets) {
    const std::string output(SpecTex_Default);
    scene.renderTargets[output]=SceneRenderTarget {.width=32,.height=32};
    auto& writer=Pass(false,false,output,false,VK_SAMPLE_COUNT_1_BIT,{},
        [](auto& desc){desc.presentation_format=VK_FORMAT_R8G8B8A8_UNORM;});
    auto& pre=ClearPass(output);
    const auto target=PrivateTarget(32,32,VK_FORMAT_R8G8B8A8_UNORM);
    auto& final=Final(target); ASSERT_TRUE(final.prepared());
    Begin(); ASSERT_TRUE(writer.updateFrame(device,rr)); Upload();
    {
        DispatchScope scope(device); scope.fail_framebuffer=true;
        EXPECT_EQ(CheckRecording(writer.executePresentation(device,rr,target,VK_FORMAT_R8G8B8A8_UNORM)),VK_ERROR_OUT_OF_DEVICE_MEMORY);
        EXPECT_EQ(scope.submits,0u); EXPECT_EQ(scope.waits,0u); EXPECT_EQ(scope.draws,0u);
    }
    ExpectSolid(Read(target),{255,0,255,255});
    EXPECT_TRUE(PresentFrame(writer,final,pre,target,VK_FORMAT_R8G8B8A8_UNORM));
    ExpectSolid(Read(target),{0,255,0,255});
    Begin(); ASSERT_TRUE(writer.updateFrame(device,rr)); Upload();
    {
        DispatchScope scope(device);
        EXPECT_EQ(CheckRecording(writer.executePresentation(device,rr,target,VK_FORMAT_B8G8R8A8_UNORM)),VK_ERROR_INITIALIZATION_FAILED);
        EXPECT_EQ(scope.submits,0u); EXPECT_EQ(scope.waits,0u);
    }
    EXPECT_TRUE(PresentFrame(writer,final,pre,target,VK_FORMAT_R8G8B8A8_UNORM));
    auto& texture_writer=Pass(true,false,output,false,VK_SAMPLE_COUNT_1_BIT,{},
        [](auto& desc){desc.presentation_format=VK_FORMAT_R8G8B8A8_UNORM;});
    ImageSlotsRef alias; alias.slots={target};
    // The target requires a sampler to reach the explicit physical-alias guard.
    alias.slots[0].sampler=writer.desc().vk_output.sampler;
    Bind(texture_writer,alias);
    Begin(); ASSERT_TRUE(texture_writer.updateFrame(device,rr)); Upload();
    {
        DispatchScope scope(device);
        EXPECT_EQ(CheckRecording(texture_writer.executePresentation(device,rr,target,VK_FORMAT_R8G8B8A8_UNORM)),VK_ERROR_INITIALIZATION_FAILED);
        EXPECT_EQ(scope.submits,0u); EXPECT_EQ(scope.waits,0u);
    }
    ExpectSolid(Read(target),{0,255,0,255});
}
TEST_F(PlaybackGPU, RequestedPresentationPipelineFailureCannotPublishNormalOnlyPass) {
    const std::string output(SpecTex_Default);
    scene.renderTargets[output]=SceneRenderTarget {.width=32,.height=32};
    ImageFor(output);
    const auto shader=Compile(false,false);
    {
        DispatchScope scope(device);
        scope.fail_shader_module_after=2; // Normal vertex+fragment succeed; presentation fails.
        auto& failed=Pass(false,false,output,false,VK_SAMPLE_COUNT_1_BIT,shader,
            [](auto& desc){desc.presentation_format=VK_FORMAT_R8G8B8A8_UNORM;},false);
        EXPECT_FALSE(failed.prepared());
        EXPECT_FALSE(failed.canPresentDirectly(rr,{32,32},VK_FORMAT_R8G8B8A8_UNORM));
        EXPECT_EQ(scope.submits,0u);
    }
    {
        DispatchScope scope(device); scope.fail_framebuffer=true;
        auto& failed=Pass(false,false,output,false,VK_SAMPLE_COUNT_1_BIT,shader,
            [](auto& desc){desc.presentation_format=VK_FORMAT_R8G8B8A8_UNORM;},false);
        EXPECT_FALSE(failed.prepared());
        EXPECT_EQ(scope.submits,0u);
    }
    auto& recovered=Pass(false,false,output,false,VK_SAMPLE_COUNT_1_BIT,shader,
        [](auto& desc){desc.presentation_format=VK_FORMAT_R8G8B8A8_UNORM;});
    auto& pre=ClearPass(output);
    const auto target=PrivateTarget(32,32,VK_FORMAT_R8G8B8A8_UNORM);
    auto& final=Final(target);
    EXPECT_TRUE(PresentFrame(recovered,final,pre,target,VK_FORMAT_R8G8B8A8_UNORM));
    ExpectSolid(Read(target),{0,255,0,255});
}
TEST_F(PlaybackGPU, DirectTranslucentEdgesBlendAgainstTheSameClearColor) {
    const std::string output(SpecTex_Default);
    scene.renderTargets[output]=SceneRenderTarget {.width=33,.height=19};
    scene.clearColor={0,0,1};
    auto shader=Compile(false,false,false,"vec4(1.0,0.0,0.0,gl_FragCoord.x < 16.0 ? 0.5 : 0.0)");
    for(auto format:{VK_FORMAT_R8G8B8A8_UNORM,VK_FORMAT_B8G8R8A8_UNORM}) {
        auto& writer=Pass(false,false,output,false,VK_SAMPLE_COUNT_1_BIT,shader,[format](auto& desc){
            desc.presentation_format=format;
            desc.node->Mesh()->Material()->blenmode=BlendMode::Translucent;
        });
        auto& pre=ClearPass(output);
        const auto target=PrivateTarget(33,19,format);
        auto& final=Final(target,format);
        EXPECT_FALSE(PresentFrame(writer,final,pre,target,format,false));
        const auto reference=Read(target);
        Poison(target,{0,1,0,1});
        EXPECT_TRUE(PresentFrame(writer,final,pre,target,format));
        EXPECT_EQ(Read(target),reference);
        const auto rgba=NormalizeColorBytes(reference,format);
        for(uint32_t y=0;y<19;++y) for(uint32_t x=0;x<33;++x) {
            const auto offset=(y*33+x)*4;
            ASSERT_NEAR(rgba[offset],x<16 ? 128 : 0,1);
            ASSERT_EQ(rgba[offset+1],0);
            ASSERT_NEAR(rgba[offset+2],x<16 ? 128 : 255,1);
            ASSERT_EQ(rgba[offset+3],255);
        }
    }
}

/// A cover change makes two runtime names hold one image, and replacing either
/// of them must not free what the other is sampling.
///
/// `$mediaPreviousThumbnail` becomes exactly what `$mediaThumbnail` was, so
/// both names resolve to one `Image::key` and one cached texture. The bindings
/// are refreshed independently, in whatever order the author's texture slots
/// happen to be in, and whichever of them moves second retires the key the
/// first has just bound to. The binding that lost the race never refreshes
/// again either, because its own key did not change — so it samples freed
/// memory for the rest of the scene's life. This ran only once the cover stopped
/// rebuilding the graph, which used to clear the whole cache and re-prepare
/// every binding.
TEST_F(PlaybackGPU, AnAliasedCoverOutlivesTheNameItSharesBeingReplaced) {
    if (! initialized) GTEST_SKIP() << "no surface-free Vulkan device";

    const std::array<std::vector<uint8_t>, 3> covers {
        std::vector<uint8_t> { 0x11, 0x22, 0x33, 0xFF },
        std::vector<uint8_t> { 0x44, 0x55, 0x66, 0xFF },
        std::vector<uint8_t> { 0x77, 0x88, 0x99, 0xFF },
    };

    // Both orders the texture slots can be refreshed in.
    for (const bool previous_first : { true, false }) {
        RuntimeImageSource images(nullptr);
        auto&              cache = device.tex_cache();

        struct Binding {
            std::string   name;
            std::string   key;
            ImageSlotsRef ref;
        };
        Binding current { "$mediaThumbnail", {}, {} };
        Binding previous { "$mediaPreviousThumbnail", {}, {} };

        // What `CustomShaderPass::prepare` does: parse once, upload once.
        for (Binding* binding : { &current, &previous }) {
            auto image     = images.Parse(binding->name);
            ASSERT_NE(image, nullptr);
            binding->key = image->key;
            binding->ref = cache.CreateTex(*image);
            ASSERT_FALSE(binding->ref.slots.empty());
        }

        // What the per-frame `update_op` does, for one binding.
        const auto refresh = [&](Binding& binding) {
            auto image = images.Parse(binding.name);
            ASSERT_NE(image, nullptr);
            if (image->key == binding.key) return;
            binding.ref = cache.ReplaceTex(*image, binding.key);
            binding.key = image->key;
            ASSERT_FALSE(binding.ref.slots.empty());
        };

        // Cached images carry TRANSFER_DST|SAMPLED, never TRANSFER_SRC, so
        // they cannot legally be copied straight out. Sampling each one
        // through an ordinary pass into a render target is both legal and
        // closer to what the scene does with them, and the target is
        // readback-capable.
        auto& current_pass  = Pass();
        auto& previous_pass = Pass();
        const auto sampled  = [&](CustomShaderPass& pass, const ImageSlotsRef& ref) {
            Bind(pass, ref);
            Draw(pass);
            return Read(pass.desc().vk_output);
        };

        // The cover each slot should show. Before any track both slots hold
        // the 1x1 transparent starter the runtime image source publishes.
        const std::vector<uint8_t> starter { 0x00, 0x00, 0x00, 0x00 };
        for (std::size_t index = 0; index < covers.size(); ++index) {
            const auto& cover    = covers[index];
            const auto& outgoing = index == 0 ? starter : covers[index - 1];
            ASSERT_NE(current.ref.image_owner, nullptr)
                << "a bound image must be owned, not borrowed from the cache";
            ASSERT_TRUE(PublishSystemMediaArtwork(images, 1, 1, cover.data(), cover.size()));

            if (previous_first) {
                refresh(previous);
                refresh(current);
            } else {
                refresh(current);
                refresh(previous);
            }
            // Drain first, so nothing survives merely because an upload is
            // still in flight, then release everything the cache holds on its
            // own behalf. Only bindings keep anything alive past this point.
            std::string error;
            ASSERT_TRUE(cache.WaitForPendingUploads(&error)) << error;
            cache.CollectCompletedUploads();

            ASSERT_NE(current.ref.image_owner, nullptr);
            ASSERT_NE(previous.ref.image_owner, nullptr);

            // Drawn, then read back off the target. This is where a binding
            // that lost its image shows up: whichever slot refreshed second
            // retires the key the first just bound to, and before bindings
            // shared ownership that retire destroyed the image the first was
            // still sampling.
            //
            // Whether the outgoing image object itself survives is
            // deliberately not asserted: in one refresh order nothing
            // references it any more and it is correctly released, with the
            // previous slot taking an equivalent upload. What must hold in
            // both orders is what the two slots actually draw.
            const auto shown = sampled(current_pass, current.ref);
            const auto faded = sampled(previous_pass, previous.ref);
            ASSERT_GE(shown.size(), 4u);
            ASSERT_GE(faded.size(), 4u);
            EXPECT_EQ(std::vector<uint8_t>(shown.begin(), shown.begin() + 4), cover)
                << "the current slot does not draw the cover that was published (previous_first="
                << previous_first << ", cover " << index << ")";
            EXPECT_EQ(std::vector<uint8_t>(faded.begin(), faded.begin() + 4), outgoing)
                << "the previous slot does not draw the cover it replaced (previous_first="
                << previous_first << ", cover " << index << ")";
            EXPECT_NE(current.ref.getActive().handle, previous.ref.getActive().handle)
                << "a cross-fade needs two images, not one";
        }

        // The image outlives every cache reference and dies with its last
        // holder, which is what makes the sampling above safe rather than
        // lucky. The passes are holders too, so they let go first.
        Bind(current_pass, ImageSlotsRef {});
        Bind(previous_pass, ImageSlotsRef {});
        std::weak_ptr<const void> watch = previous.ref.image_owner;
        ASSERT_FALSE(watch.expired()) << "a bound image must be owned, not borrowed";
        auto copy = previous.ref;
        previous.ref = {};
        EXPECT_FALSE(watch.expired()) << "an image was freed while a binding still held it";
        copy         = {};
        current.ref  = {};
        cache.Clear();
        EXPECT_TRUE(watch.expired()) << "the image outlived its last holder";
    }
}
} // namespace

TEST_F(PlaybackGPU, LiveTexelSizeOverridesParseDefaultsWhileMaterialValuesStayLive) {
    auto values = std::make_unique<WPShaderValueUpdater>(&scene);
    auto* live = values.get();
    scene.shaderValueUpdater = std::move(values);
    scene.cameras["global"] = std::make_shared<SceneCamera>(32, 32, -1.0f, 1.0f);
    scene.cameras["global"]->AttatchNode(std::make_shared<SceneNode>());
    scene.activeCamera = scene.cameras.at("global").get();
    shader::RustShaderRequest request;
    request.shader_name = "live-raster-uniforms";
    request.scene_id = "synthetic";
    request.cache_enabled = false;
    request.stages = {
        { ShaderType::VERTEX,
          "attribute vec2 a_Position;\n"
          "void main() { gl_Position = vec4(a_Position, 0.0, 1.0); }\n" },
        { ShaderType::FRAGMENT,
          "uniform vec2 g_TexelSize;\nuniform float u_Tint;\n"
          "void main() { gl_FragColor = vec4(g_TexelSize, u_Tint, 1.0); }\n" },
    };
    shader::RustShaderOutput compiled;
    ASSERT_TRUE(shader::CompileRustShaderProgram(request, compiled));
    auto program = std::make_shared<SceneShader>();
    program->name = request.shader_name;
    program->codes = std::move(compiled.codes);
    program->rust_reflection_json = std::move(compiled.reflection_json);
    auto& pass = Pass(false, false, {}, false, VK_SAMPLE_COUNT_1_BIT, program,
                      [](CustomShaderPass::Desc& desc) {
                          desc.node->Mesh()->Material()->customShader.constValues["g_TexelSize"] =
                              std::array<float, 2> { 1.0f / 1920.0f, 1.0f / 1080.0f };
                      });
    live->SetTexelSize(0.25f, 0.5f);
    Draw(pass);
    ExpectSolid(Read(pass.desc().vk_output), { 64, 128, 0, 255 });
    auto& constants = nodes.back()->Mesh()->Material()->customShader.constValues;
    constants["u_Tint"] = 0.5f;
    live->SetTexelSize(0.5f, 0.25f);
    Draw(pass);
    ExpectSolid(Read(pass.desc().vk_output), { 128, 64, 128, 255 });
    constants["u_Tint"] = 1.0f;
    Draw(pass);
    ExpectSolid(Read(pass.desc().vk_output), { 128, 64, 255, 255 });
}

TEST_F(PlaybackGPU, AConditionalMaskKeepsPulsesOutOfTheMaskedRegion) {
    auto owned_images = std::make_unique<RuntimeImageSource>(nullptr);
    auto* images = owned_images.get();
    scene.imageParser = std::move(owned_images);
    Bytes mask(32 * 32 * 4, 255);
    for (size_t y = 0; y < 32; ++y)
        for (size_t x = 0; x < 16; ++x)
            mask[(y * 32 + x) * 4] = 0;
    images->SetRgbaImage("$conditionalMask", 32, 32, mask.data(), mask.size());

    shader::RustShaderRequest request;
    request.shader_name = "conditional-mask-pulse";
    request.scene_id = "synthetic";
    request.cache_enabled = false;
    request.textures.push_back(shader::RustShaderTextureInfo {
        .slot = 0, .present = true, .enabled = true });
    request.stages = {
        { ShaderType::VERTEX,
          "attribute vec2 a_Position;\nvarying vec2 v_Uv;\n"
          "void main() { v_Uv = a_Position * 0.5 + vec2(0.5);"
          "gl_Position = vec4(a_Position, 0.0, 1.0); }\n" },
        { ShaderType::FRAGMENT,
          "varying vec2 v_Uv;\nuniform vec4 g_TestColor;\n"
          "#if USE_MASK\n"
          "uniform sampler2D g_Texture0; // {\"combo\":\"USE_MASK\"}\n"
          "#endif\n"
          "void main() {\n"
          "  float mask = 1.0;\n"
          "#if USE_MASK\n"
          "  mask = texture2D(g_Texture0, v_Uv).r;\n"
          "#endif\n"
          "  gl_FragColor = mix(vec4(0.0, 0.0, 0.25, 1.0), g_TestColor, mask);\n"
          "}\n" },
    };
    shader::RustShaderOutput compiled;
    ASSERT_TRUE(shader::CompileRustShaderProgram(request, compiled));
    auto program = std::make_shared<SceneShader>();
    program->name = request.shader_name;
    program->codes = std::move(compiled.codes);
    program->rust_reflection_json = std::move(compiled.reflection_json);
    auto& pass = Pass(true, true, {}, false, VK_SAMPLE_COUNT_1_BIT, program,
                     [](CustomShaderPass::Desc& desc) { desc.textures = {"$conditionalMask"}; });
    for (int frame = 0; frame < 6; ++frame) {
        SCOPED_TRACE(frame);
        const bool bright = frame % 2 == 0;
        updater->color = bright ? std::array<float, 4> {1, 1, 1, 1}
                                : std::array<float, 4> {0, 0, 0, 1};
        Draw(pass);
        const auto pixels = Read(pass.desc().vk_output);
        ASSERT_EQ(pixels.size(), 32u * 32u * 4u);
        for (size_t y = 0; y < 32; ++y) {
            const size_t masked = (y * 32 + 4) * 4;
            const size_t lit = (y * 32 + 28) * 4;
            EXPECT_EQ(pixels[masked], 0);
            EXPECT_EQ(pixels[masked + 1], 0);
            EXPECT_EQ(pixels[masked + 2], 64);
            EXPECT_EQ(pixels[masked + 3], 255);
            for (size_t channel = 0; channel < 3; ++channel)
                EXPECT_EQ(pixels[lit + channel], bright ? 255 : 0);
            EXPECT_EQ(pixels[lit + 3], 255);
        }
    }
}

// A texture slot whose name joins the runtime image source after prepare is
// resolved through that source from the next frame on.
TEST_F(PlaybackGPU, RuntimeImagePublishedAfterPrepareReachesTheNextFrame) {
    auto owned_images = std::make_unique<RuntimeImageSource>(nullptr);
    auto* images = owned_images.get();
    scene.imageParser = std::move(owned_images);
    const std::array<uint8_t,4> red {255,0,0,255}, blue {0,0,255,255};
    images->SetRgbaImage("$r14Early", 1, 1, red.data(), red.size());
    auto& pass = Pass(true, false, {}, false, VK_SAMPLE_COUNT_1_BIT, {},
                      [](CustomShaderPass::Desc& desc) { desc.textures = {"$r14Early"}; });
    Draw(pass); ExpectSolid(Read(pass.desc().vk_output), {255,0,0,255});

    // A new name first, so the slot's own name is not what changed.
    const auto generation = images->NamesGeneration();
    images->SetRgbaImage("$r14Other", 1, 1, red.data(), red.size());
    EXPECT_NE(images->NamesGeneration(), generation);
    images->SetRgbaImage("$r14Early", 1, 1, blue.data(), blue.size());
    Draw(pass); ExpectSolid(Read(pass.desc().vk_output), {0,0,255,255});

    // Rebinding the slot to a name that became runtime after prepare.
    const std::array<uint8_t,4> green {0,255,0,255};
    images->SetRgbaImage("$r14Late", 1, 1, green.data(), green.size());
    pass.desc().textures[0] = "$r14Late";
    Draw(pass); ExpectSolid(Read(pass.desc().vk_output), {0,255,0,255});
}

// A slot whose name is not published yet at prepare starts sampling it the
// frame after it is published.
TEST_F(PlaybackGPU, RuntimeImageNamePublishedAfterPrepareReachesTheNextFrame) {
    auto owned_images = std::make_unique<RuntimeImageSource>(nullptr);
    auto* images = owned_images.get();
    scene.imageParser = std::move(owned_images);
    auto& pass = Pass(true, false, {}, false, VK_SAMPLE_COUNT_1_BIT, {},
                      [](CustomShaderPass::Desc& desc) { desc.textures = {"$r14Pending"}; }, false);
    ASSERT_TRUE(pass.prepared());
    Draw(pass);
    const std::array<uint8_t,4> blue {0,0,255,255};
    images->SetRgbaImage("$r14Pending", 1, 1, blue.data(), blue.size());
    Draw(pass); ExpectSolid(Read(pass.desc().vk_output), {0,0,255,255});
}
