// Explicit diagnostic tool. Renders only imported scene assets to private GPU
// images: no surface, swapchain, AppKit window, audio device or desktop capture.
#include "Audio/SoundManager.h"
#include "Core/Random.hpp"
#include "Audio/AudioResponseService.h"
#include "Particle/ParticleSystem.h"
#include "Fs/PhysicalFs.h"
#include "Fs/VFS.h"
#include "Project/ProjectProperties.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/RuntimeImageSource.hpp"
#include "Runtime/VirtualAssetRegistry.hpp"
#include "Runtime/RuntimeImageSource.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneNode.h"
#include "WPSceneParser.hpp"
#include "SceneSourceResolver.hpp"
#include "scene_probe_controls.hpp"
#include <charconv>
#include <cstdio>
#include "SpecTexs.hpp"
#include "Vulkan/Device.hpp"
#include "Vulkan/TextureCache.hpp"
#include "Vulkan/Util.hpp"
#include "VulkanRender/CustomShaderPass.hpp"
#include "VulkanRender/PrePass.hpp"
#include "VulkanRender/CopyPass.hpp"
#include "VulkanRender/StaticSubgraphCache.hpp"
#include "VulkanRender/PassCommon.hpp"
#include "Presentation/WallpaperScaling.hpp"
#include "TexturePrefetch.hpp"
#include "VulkanRender/Resource.hpp"
#include "VulkanRender/SceneToRenderGraph.hpp"
#include "RenderGraph/RenderGraph.hpp"
#include "Interface/IImageParser.h"
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <nlohmann/json.hpp>
#include <stdexcept>
#include <nlohmann/json.hpp>
#include <vector>
#include <thread>

using namespace wallpaper;
using namespace wallpaper::vulkan;
namespace {
void Check(bool ok, const char* message) { if (!ok) throw std::runtime_error(message); }
uint16_t PackageVersion(const std::string& path) {
    std::ifstream file(path, std::ios::binary);
    uint32_t length = 0;
    file.read(reinterpret_cast<char*>(&length), sizeof(length));
    if (!file || length < 5 || length > 64) return SceneParseRequest::kUnknownPkgVersion;
    std::string stamp(length, '\0');
    file.read(stamp.data(), length);
    if (!file || !stamp.starts_with("PKGV")) return SceneParseRequest::kUnknownPkgVersion;
    uint16_t version = 0;
    const auto [end, ec] = std::from_chars(stamp.data() + 4, stamp.data() + stamp.size(), version);
    return ec == std::errc{} && end == stamp.data() + stamp.size()
        ? version : SceneParseRequest::kUnknownPkgVersion;
}
void Ppm(const std::filesystem::path& path, const uint8_t* rgba, int w, int h) {
    std::ofstream file(path, std::ios::binary);
    file << "P6\n" << w << ' ' << h << "\n255\n";
    for (int i = 0; i < w * h; ++i) file.write(reinterpret_cast<const char*>(rgba + i * 4), 3);
}
/// The alpha channel on its own, as grey.
///
/// Effects that weight by coverage -- the bokeh downsample divides by the sum
/// of the taps' alpha -- produce completely different colour from the same RGB
/// when alpha differs, so a colour-only dump cannot explain them.
void PpmAlpha(const std::filesystem::path& path, const uint8_t* rgba, int w, int h) {
    std::ofstream file(path, std::ios::binary);
    file << "P6\n" << w << ' ' << h << "\n255\n";
    for (int i = 0; i < w * h; ++i) {
        const char grey[3] { static_cast<char>(rgba[i * 4 + 3]), static_cast<char>(rgba[i * 4 + 3]),
                             static_cast<char>(rgba[i * 4 + 3]) };
        file.write(grey, 3);
    }
}
void CheckRecording(Device& device, RenderingResources& rr, VkResult result) {
    if (result == VK_SUCCESS) return;
    // No draw submission happened. A reset failure must retain pins/uploads
    // rather than unwinding owners while the command still references them.
    if (rr.command.Reset() != VK_SUCCESS) std::terminate();
    device.tex_cache().AbandonVideoFrameRecording();
    rr.vertex_buf->finishUpload(false);
    rr.dyn_buf->finishUpload(false);
    throw std::runtime_error(std::string("record passes: ") + vvk::ToString(result));
}
void Submit(Device& device, RenderingResources& rr) {
    const auto end_result = rr.command.End();
    VkResult submit_result = end_result;
    if (end_result == VK_SUCCESS) {
        VkSubmitInfo submit { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .commandBufferCount = 1, .pCommandBuffers = rr.command.address() };
        submit_result = device.graphics_queue().handle.Submit(submit, {});
    }
    if (submit_result != VK_SUCCESS) {
        if (submit_result == VK_ERROR_DEVICE_LOST) {
            device.tex_cache().DiscardAfterDeviceLoss();
            rr.vertex_buf->finishUpload(false);
            rr.dyn_buf->finishUpload(false);
        } else if (rr.command.Reset() == VK_SUCCESS) {
            rr.vertex_buf->finishUpload(false);
            rr.dyn_buf->finishUpload(false);
            device.tex_cache().AbandonVideoFrameRecording();
        }
        Check(false, "end or submit command failed");
    }
    device.tex_cache().MarkVideoFrameSubmitted();
    const auto idle_result = device.handle().WaitIdle();
    if (idle_result == VK_ERROR_DEVICE_LOST) {
        device.tex_cache().DiscardAfterDeviceLoss();
        rr.vertex_buf->finishUpload(false);
        rr.dyn_buf->finishUpload(false);
        Check(false, "device lost during probe");
    }
    if (idle_result != VK_SUCCESS) {
        LOG_ERROR("cannot destroy renderer resources before GPU completion");
        std::terminate();
    }
    rr.vertex_buf->finishUpload(true);
    rr.dyn_buf->finishUpload(true);
    device.tex_cache().CompleteVideoFrame();
}
void Begin(vvk::CommandBuffer& command) {
    Check(command.Begin(VkCommandBufferBeginInfo {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT }) == VK_SUCCESS, "begin command");
}

void ReadImage(Device& device, RenderingResources&, const ImageParameters& image,
               const std::filesystem::path& path) {
    std::vector<uint8_t> bytes;
    std::string error;
    Check(device.tex_cache().ReadbackImageSample(image, 0, 0,
        image.extent.width, image.extent.height, &bytes, &error), error.c_str());
    Ppm(path, bytes.data(), image.extent.width, image.extent.height);
    if (std::getenv("WE_TEST_DUMP_ALPHA") != nullptr) {
        auto alpha_path = path;
        alpha_path.replace_extension("");
        alpha_path += "-alpha.ppm";
        PpmAlpha(alpha_path, bytes.data(), image.extent.width,
                 image.extent.height);
    }
}

// Feeds the scene the now-playing state the app would deliver, so a media
// wallpaper can be rendered without a desktop, a system media source or the
// macOS Automation permission the real sources need.
//
// `WE_TEST_MEDIA_EVENTS` is a JSON array of SceneScript media event objects,
// dispatched in order. `WE_TEST_MEDIA_ARTWORK` is "<width>x<height>:<rrggbb>"
// and publishes one opaque cover, so what reached `$mediaThumbnail` is legible
// in the rendered frame.
void InjectSystemMedia(Scene& scene) {
    const char* events = std::getenv("WE_TEST_MEDIA_EVENTS");
    const char* artwork = std::getenv("WE_TEST_MEDIA_ARTWORK");
    if (!events && !artwork) return;
    Check(scene.runtime != nullptr, "scene has no runtime for media events");
    scene.runtime->SetMediaIntegrationEnabled(true);

    if (artwork) {
        unsigned width = 0, height = 0, rgb = 0;
        Check(std::sscanf(artwork, "%ux%u:%x", &width, &height, &rgb) == 3 &&
                  width >= 1 && width <= 4096 && height >= 1 && height <= 4096,
              "WE_TEST_MEDIA_ARTWORK must be \"<width>x<height>:<rrggbb>\"");
        auto* images = dynamic_cast<RuntimeImageSource*>(scene.imageParser.get());
        Check(images != nullptr, "scene image parser cannot hold runtime images");
        std::vector<uint8_t> rgba(std::size_t(width) * height * 4);
        for (std::size_t i = 0; i < rgba.size(); i += 4) {
            rgba[i + 0] = uint8_t((rgb >> 16) & 0xFF);
            rgba[i + 1] = uint8_t((rgb >> 8) & 0xFF);
            rgba[i + 2] = uint8_t(rgb & 0xFF);
            rgba[i + 3] = 0xFF;
        }
        PublishSystemMediaArtwork(*images, width, height, rgba.data(), rgba.size());
        std::cout << "media artwork " << width << 'x' << height << " rgb=" << std::hex << rgb
                  << std::dec << std::endl;
    }

    if (events) {
        const auto parsed = nlohmann::json::parse(events, nullptr, false);
        Check(!parsed.is_discarded() && parsed.is_array(),
              "WE_TEST_MEDIA_EVENTS must be a JSON array of media event objects");
        for (const auto& event : parsed) {
            Check(event.is_object(), "each WE_TEST_MEDIA_EVENTS entry must be an object");
            const auto json = event.dump();
            scene.runtime->DispatchMediaEventJson(json);
            std::cout << "media event " << json << std::endl;
        }
        scene.runtime->Tick(1.0 / 60.0);
    }
}
}
#if defined(__APPLE__)
#include <libproc.h>
#include <sys/resource.h>
#include <unistd.h>
#endif

int main() {
    try {
        const auto started = std::chrono::steady_clock::now();
        const auto milestone = [&](const char* name) {
            std::cout << "startup " << name << " ms="
                      << std::chrono::duration<double, std::milli>(
                             std::chrono::steady_clock::now() - started).count()
                      << std::endl;
        };
        const char* project = std::getenv("WE_TEST_PROJECT");
        const char* assets = std::getenv("WE_TEST_ASSETS");
        const char* output = std::getenv("WE_TEST_OUTPUT");
        Check(project && assets && output, "Set WE_TEST_PROJECT, WE_TEST_ASSETS, WE_TEST_OUTPUT");
        const std::filesystem::path out(output);
        std::filesystem::create_directories(out);
        int frame_count = 3;
        if (const char* value = std::getenv("WE_TEST_FRAMES")) {
            const std::string_view text(value);
            const auto parsed = std::from_chars(text.data(), text.data() + text.size(), frame_count);
            Check(parsed.ec == std::errc {} && parsed.ptr == text.data() + text.size() &&
                      frame_count >= 1 && frame_count <= 3600,
                  "WE_TEST_FRAMES must be 1..3600");
        }
        double frame_step = 0.0;
        if (const char* value = std::getenv("WE_TEST_FRAME_STEP")) {
            char* end = nullptr;
            frame_step = std::strtod(value, &end);
            Check(end != value && *end == '\0' && std::isfinite(frame_step) &&
                      frame_step > 0.0 && frame_step <= 1.0,
                  "WE_TEST_FRAME_STEP must be >0 and <=1 seconds");
        }
        const char* audio_hz_env = std::getenv("WE_TEST_AUDIO_HZ");
        double      audio_hz     = 0.0;
        if (audio_hz_env) {
            char* end = nullptr;
            audio_hz  = std::strtod(audio_hz_env, &end);
            Check(end != audio_hz_env && *end == '\0' && std::isfinite(audio_hz) &&
                      audio_hz >= 0.0 && audio_hz <= audio::kAudioResponseSampleRate / 2.0,
                  "WE_TEST_AUDIO_HZ must be 0..24000");
            audio::ResetAudioResponseServiceForTesting();
        }
        // A fixed seed makes a particle scene repeatable, so the same project
        // can be compared frame for frame with another backend's run.
        if (const char* seed = std::getenv("WE_TEST_RANDOM_SEED")) {
            Random::seed(static_cast<uint32_t>(std::strtoul(seed, nullptr, 10)));
        }
        SceneSourcePaths paths;
        std::string error;
        Check(ResolveSceneSourcePaths(project, &paths, &error), error.c_str());
        fs::VFS vfs;
        Check(vfs.Mount("/assets", fs::CreatePhysicalFs(assets), "assets"), "assets mount");
        Check(MountSceneSource(vfs, paths, &error), error.c_str());
        Check(vfs.Mount("/cache", fs::CreatePhysicalFs((out / "cache").string(), true), "cache"), "cache mount");
        InstallVirtualAssets(vfs);
        ProjectProperties properties;
        Check(ParseProjectProperties(project, &properties, &error), error.c_str());
        if (const char* json = std::getenv("WE_TEST_PROPERTIES")) {
            ProjectProperties overrides;
            Check(ParseFlatProjectPropertyOverrideJson(json, &overrides, &error), error.c_str());
            properties = MergeProjectProperties(properties, overrides);
        }
        auto source = vfs.Open("/assets/" + paths.pkg_entry);
        Check(source != nullptr, "scene source");
        const auto scene_source = source->ReadAllStr();
        if (const char* asset = std::getenv("WE_TEST_ASSET_PATH")) {
            auto file = vfs.Open(std::string("/assets/") + asset);
            Check(file != nullptr, "diagnostic asset");
            std::ofstream(out / "asset.txt") << file->ReadAllStr();
        }
        if (std::getenv("WE_TEST_DUMP_SOURCE"))
            std::ofstream(out / "scene.json") << scene_source;
        WPSceneParser parser;
        audio::SoundManager sound(audio::SoundManager::OutputBackend::Null);
        auto scene = parser.Parse(SceneParseRequest {
            .scene_id = paths.scene_id, .project_path = project,
            .project_properties = &properties, .pkg_version = PackageVersion(paths.pkg_path),
        }, scene_source, vfs, sound);
        Check(scene != nullptr, "parse scene");
        milestone("parsed");
        if (const char* media = std::getenv("WE_TEST_MEDIA_JSON")) {
            const auto events = nlohmann::json::parse(media);
            Check(events.is_array(), "WE_TEST_MEDIA_JSON must be an event array");
            scene->runtime->SetMediaIntegrationEnabled(true);
            for (const auto& event : events) scene->runtime->DispatchMediaEventJson(event.dump());
        }
        if (std::getenv("WE_TEST_MEDIA_ARTWORK")) {
            auto* images = dynamic_cast<RuntimeImageSource*>(scene->imageParser.get());
            Check(images != nullptr, "runtime artwork source");
            const uint8_t pixels[] = {255, 0, 0, 255, 0, 255, 0, 255,
                                      0, 0, 255, 255, 255, 255, 0, 255};
            images->SetRgbaImage("$mediaThumbnail", 2, 2, pixels, sizeof(pixels));
            scene->runtime->DispatchMediaEventJson(R"({"type":"mediaThumbnailChanged","hasThumbnail":true})");
        }
        if (audio_hz_env) {
            const char* enabled = std::getenv("WE_TEST_AUDIO_ENABLED");
            scene->runtime->SetAudioResponseEnabled(! enabled || std::string_view(enabled) != "0");
        }
        for (int i = 0; i < 20; ++i) {
            scene->runtime->Tick(1.0 / 60.0);
            scene->runtime->PumpTextLayerCache();
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
        }
        InjectSystemMedia(*scene);
        // Media events change layer text, and that layout runs on another
        // thread. Drain it the same way the initial warm-up does; five tight
        // pumps collect nothing a worker has not finished yet.
        for (int i = 0; i < 20; ++i) {
            scene->runtime->Tick(1.0 / 60.0);
            scene->runtime->PumpTextLayerCache();
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
        }
        if (const char* click = std::getenv("WE_TEST_CLICK_LAYER")) {
            int32_t layer_id = 0;
            const std::string_view text(click);
            const auto parsed = std::from_chars(text.data(), text.data() + text.size(), layer_id);
            Check(parsed.ec == std::errc{} && parsed.ptr == text.data() + text.size(), "invalid click layer ID");
            SceneNode* target = nullptr;
            const auto locate = [&](auto&& self, SceneNode* node) -> void {
                if (!node) return;
                if (node->ID() == layer_id) target = node;
                for (const auto& child : node->GetChildren()) self(self, child.get());
            };
            locate(locate, scene->sceneGraph.get());
            Check(target != nullptr, "click layer missing");
            target->UpdateTrans();
            Eigen::Vector3f position = (target->ModelTrans() * Eigen::Vector4d(0, 0, 0, 1)).head<3>().cast<float>();
            if (const char* offset = std::getenv("WE_TEST_CLICK_OFFSET")) {
                // World-space "dx dy" from the layer origin, e.g. to probe a
                // texel-covered corner instead of the centre.
                float dx = 0.0f;
                float dy = 0.0f;
                Check(std::sscanf(offset, "%f %f", &dx, &dy) == 2, "WE_TEST_CLICK_OFFSET must be \"dx dy\"");
                position.x() += dx;
                position.y() += dy;
            }
            int click_count = 1;
            if (const char* count = std::getenv("WE_TEST_CLICK_COUNT")) {
                const std::string_view value(count);
                const auto parsed_count = std::from_chars(value.data(), value.data() + value.size(), click_count);
                Check(parsed_count.ec == std::errc{} && parsed_count.ptr == value.data() + value.size() &&
                          click_count >= 1 && click_count <= 10, "click count must be 1..10");
            }
            // A desktop never hands the runtime a world position: it publishes
            // the presented viewport and a window-normalized cursor, and hit
            // testing derives the world point from those. WE_TEST_CLICK_VIEWPORT
            // reproduces that mapping — "<px_w>x<px_h>@<scale>:<fill|fit|stretch|none>" —
            // so a click can be exercised the way the running wallpaper maps it.
            if (const char* viewport = std::getenv("WE_TEST_CLICK_VIEWPORT")) {
                unsigned px_w = 0, px_h = 0;
                double   display_scale = 0.0;
                char     mode_text[16] = {};
                Check(std::sscanf(viewport, "%ux%u@%lf:%15s", &px_w, &px_h, &display_scale,
                                  mode_text) == 4 &&
                          px_w > 0 && px_h > 0 && display_scale > 0.0,
                      "WE_TEST_CLICK_VIEWPORT must be \"<px_w>x<px_h>@<scale>:<mode>\"");
                const std::string_view mode_name(mode_text);
                WallpaperScalingMode   mode = WallpaperScalingMode::FILL;
                if (mode_name == "fit") mode = WallpaperScalingMode::FIT;
                else if (mode_name == "stretch") mode = WallpaperScalingMode::STRETCH;
                else if (mode_name == "none") mode = WallpaperScalingMode::NONE;
                else Check(mode_name == "fill", "scaling mode must be fill, fit, stretch or none");

                // The camera is left exactly as the parser built it: nothing in
                // the app sends PROPERTY_FILLMODE, so a running wallpaper never
                // reaches UpdateCameraFillMode either, and cropping comes only
                // from the scaling layout below.
                const auto source = ResolveSceneSourceExtent(*scene, VkExtent2D { px_w, px_h });
                const auto layout = ComputeWallpaperScalingLayout(
                    mode, source.width, source.height,
                    static_cast<uint32_t>(std::lround(px_w / display_scale)),
                    static_cast<uint32_t>(std::lround(px_h / display_scale)), display_scale, 1.0);
                const auto camera = scene->cameras.find("global");
                Check(camera != scene->cameras.end() && camera->second != nullptr,
                      "scene has no global camera to map the cursor through");
                const auto camera_position = camera->second->GetPosition();
                const auto mapping        = ComputeWallpaperCursorMapping(
                    layout, camera_position.x(), camera_position.y(),
                    camera->second->VisibleWidth(), camera->second->VisibleHeight());
                Check(mapping.valid, "cursor mapping must be valid for this display");
                scene->runtime->SetCursorViewport(CursorViewport {
                    .origin = Eigen::Vector2f(static_cast<float>(mapping.origin_x),
                                              static_cast<float>(mapping.origin_y)),
                    .size   = Eigen::Vector2f(static_cast<float>(mapping.size_x),
                                            static_cast<float>(mapping.size_y)),
                    .content_origin =
                        Eigen::Vector2f(static_cast<float>(mapping.content_origin_x),
                                        static_cast<float>(mapping.content_origin_y)),
                    .content_size = Eigen::Vector2f(static_cast<float>(mapping.content_size_x),
                                                    static_cast<float>(mapping.content_size_y)),
                });
                const double normalized_x =
                    (static_cast<double>(position.x()) - mapping.origin_x) / mapping.size_x;
                const double normalized_y =
                    1.0 - (static_cast<double>(position.y()) - mapping.origin_y) / mapping.size_y;
                scene->runtime->SetCursorInput(static_cast<float>(normalized_x),
                                               static_cast<float>(normalized_y));
                std::cout << "cursor viewport origin=" << mapping.origin_x << ' '
                          << mapping.origin_y << " size=" << mapping.size_x << ' '
                          << mapping.size_y << " content_origin=" << mapping.content_origin_x
                          << ' ' << mapping.content_origin_y
                          << " content_size=" << mapping.content_size_x << ' '
                          << mapping.content_size_y << " normalized=" << normalized_x << ' '
                          << normalized_y << std::endl;
            } else {
                scene->runtime->SetCursorWorldPosition(position);
            }
            scene->runtime->SetCursorEnter(true);
            for (int i = 0; i < click_count; ++i) {
                scene->runtime->SetCursorButtons(0, 1, 1);
                scene->runtime->DispatchCursorFrameEvents(i != 0);
                scene->runtime->SetCursorButtons(0, 0, 0);
                scene->runtime->Tick(1.0 / 60.0);
            }
            std::cout << "click layer=" << layer_id << " count=" << click_count
                      << " position=" << position.transpose() << std::endl;
        }
        if (std::getenv("WE_TEST_DUMP_SOURCE")) {
            std::ofstream nodes(out / "nodes.txt");
            // World placement matters as much as the local transform: an effect
            // or compose layer is composited through a separate final node, and
            // a final node still carrying local coordinates draws the layer in
            // the wrong place without any of these local numbers changing.
            const auto dump = [&](auto&& self, SceneNode* node) -> void {
                if (!node) return;
                node->UpdateTrans();
                const Eigen::Vector3d world =
                    (node->ModelTrans() * Eigen::Vector4d(0, 0, 0, 1)).head<3>();
                const Eigen::Vector3d rendered =
                    (node->RenderTrans() * Eigen::Vector4d(0, 0, 0, 1)).head<3>();
                nodes << node->ID() << ' ' << node->Name() << " visible=" << node->Visible()
                      << " effective=" << node->EffectiveVisible()
                      << " translate=" << node->Translate().transpose()
                      << " scale=" << node->Scale().transpose()
                      << " world=" << world.transpose()
                      << " rendered=" << rendered.transpose()
                      << " override=" << (node->HasRenderTransformOverride() ? 1 : 0) << '\n';
                for (const auto& child : node->GetChildren()) self(self, child.get());
            };
            dump(dump, scene->sceneGraph.get());
        }
        std::vector<std::string> text_names;
        const auto collect_text = [&](auto&& self, SceneNode* node) -> void {
            if (!node) return;
            if (scene->runtime->NodeTextState(node->Name())) text_names.push_back(node->Name());
            for (const auto& child : node->GetChildren()) self(self, child.get());
        };
        collect_text(collect_text, scene->sceneGraph.get());
        std::size_t text_index = 0;
        for (const auto& name : text_names) {
            const auto state  = scene->runtime->NodeTextState(name);
            const auto layout = scene->runtime->NodeTextLayout(name);
            std::cout << name << " font=" << state->resolved_font_path << " kind=" << state->resolved_font_kind
                      << " text=" << state->text << " size=" << layout->card.transpose() << std::endl;
            const auto image = scene->imageParser->Parse(TextTextureName(name));
            if (image && !image->slots.empty()) {
                const auto& mip = image->slots[0].mipmaps[0];
                std::vector<uint8_t> pixels(mip.data.get(), mip.data.get() + mip.size);
                for (std::size_t i = 0; i < pixels.size(); i += 4)
                    for (int c = 0; c < 3; ++c) pixels[i+c] = pixels[i+c] * pixels[i+3] / 255;
                // Layer names are untrusted package data, not output paths.
                Ppm(out / ("text-" + std::to_string(text_index++) + ".ppm"), pixels.data(), mip.width, mip.height);
            }
        }
        auto graph = sceneToRenderGraph(*scene);
        Instance instance;
        std::vector<Extension> instance_extensions { { true, VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME } };
        Check(Instance::Create(instance, instance_extensions, {}), "create instance");
        // Match the production device extension set so scenes whose textures are
        // video streams import their frames here instead of rendering empty slots.
        std::vector<Extension> extensions { { true, VK_KHR_PUSH_DESCRIPTOR_EXTENSION_NAME } };
#if defined(__APPLE__)
        extensions.push_back({ true, "VK_EXT_metal_objects" });
#endif
        Check(instance.ChoosePhysicalDevice([&](auto gpu) { return Device::CheckGPU(gpu, extensions, {}); }), "choose GPU");
        Device device;
        // Opt in to the production texture residency policy while leaving the
        // existing full-source golden comparisons available as a baseline.
        if (const char* size = std::getenv("WE_TEST_TEXTURE_SURFACE")) {
            unsigned width = 0, height = 0;
            Check(std::sscanf(size, "%ux%u", &width, &height) == 2 && width && height,
                  "WE_TEST_TEXTURE_SURFACE must be <width>x<height>");
            scene->imageParser->SetTextureSurfaceSize(scene->display_sized ? 0 : width,
                                                     scene->display_sized ? 0 : height);
        }
        VkExtent2D surface_extent { 1920, 1080 };
        if (const char* size = std::getenv("WE_TEST_SURFACE")) {
            Check(std::sscanf(size, "%ux%u", &surface_extent.width, &surface_extent.height) == 2 &&
                      surface_extent.width > 0 && surface_extent.height > 0,
                  "WE_TEST_SURFACE must be <width>x<height>");
        }
        const auto extents = ResolveScreenBoundRenderTargetSizes(*scene, surface_extent);
        const auto extent = extents.raster;
        Check(extent.width <= 8192 && extent.height <= 8192, "probe raster extent exceeds 8192");
        for (auto& [name, rt] : scene->renderTargets) {
            if (rt.bind.enable && !rt.bind.screen) {
                const auto* parent = scene->FindRenderTarget(rt.bind.name);
                Check(parent != nullptr, "missing render target binding");
                rt.width = ResolveScreenBoundRenderTargetDimension(parent->width, rt.bind.scale);
                rt.height = ResolveScreenBoundRenderTargetDimension(parent->height, rt.bind.scale);
            }
            if (rt.has_mipmap) rt.mipmap_level = std::max(3u, static_cast<uint32_t>(std::floor(std::log2(std::min(rt.width, rt.height))))) - 2u;
        }
        scene->shaderValueUpdater->SetScreenSize(extent.width, extent.height);
        // Both production backends derive this from the extent actually being
        // rasterized. Leaving the default behind made every neighbour-tap
        // effect in this probe -- blurs above all -- sample at a 1920x1080
        // step whatever the scene's real size, so a blur rendered here could
        // not be compared with the same blur rendered by a real backend.
        scene->shaderValueUpdater->SetTexelSize(1.0f / static_cast<float>(std::max(1u, extent.width)),
                                                1.0f / static_cast<float>(std::max(1u, extent.height)));
        Check(Device::Create(instance, extensions, extent, device), "create device");
        if (const char* output = std::getenv("WE_TEST_OUTPUT")) {
            device.UsePipelineCacheFile(output);
        }
        StagingBuffer vertices(device, 8 * 1024 * 1024, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT | VK_BUFFER_USAGE_INDEX_BUFFER_BIT);
        StagingBuffer dynamic(device, 8 * 1024 * 1024, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT | VK_BUFFER_USAGE_INDEX_BUFFER_BIT | VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT);
        Check(vertices.allocate() && dynamic.allocate(), "allocate buffers");
        vvk::CommandBuffers commands;
        Check(device.cmd_pool().Allocate(1, VK_COMMAND_BUFFER_LEVEL_PRIMARY, commands) == VK_SUCCESS, "allocate commands");
        RenderingResources rr {};
        rr.command = vvk::CommandBuffer(commands[0], device.handle().Dispatch());
        rr.vertex_buf = &vertices; rr.dyn_buf = &dynamic;
        auto nodes = graph->topologicalOrder();
        auto releases = graph->getLastReadTexs(nodes);
        Check(ReserveCarriedOverTargets(*scene, device.tex_cache()), "reserve carried targets");
        std::vector<VulkanPass*> passes;
        PrePass pre(PrePass::Desc {});
        pre.prepare(*scene, device, rr);
        passes.push_back(&pre);
        std::ofstream trace(out / "passes.txt");
        // Decodes ahead of the passes the way VulkanRender::preparePasses
        // does, so the startup timing below is the production one.
        std::vector<VulkanPass*> graph_passes;
        graph_passes.reserve(nodes.size());
        for (const auto& node : nodes) {
            graph_passes.push_back(static_cast<VulkanPass*>(graph->getPass(node)));
        }
        auto prefetch = TexturePrefetch::ForPasses(*scene, device.tex_cache(), graph_passes);
        rr.texture_prefetch = prefetch.get();
        for (std::size_t i = 0; i < nodes.size(); ++i) {
            auto* pass = static_cast<VulkanPass*>(graph->getPass(nodes[i]));
            std::vector<std::string_view> release_keys;
            if (!std::getenv("WE_TEST_NO_REUSE")) {
                for (auto* tex : releases[i]) release_keys.push_back(tex->key());
            }
            pass->setReleaseTexs(release_keys);
            pass->prepare(*scene, device, rr);
            Check(pass->prepared(), "pass failed to prepare");
            passes.push_back(pass);
            if (auto* custom = dynamic_cast<CustomShaderPass*>(pass)) {
                const auto& d = custom->desc();
                trace << i << " id=" << d.node->ID() << " " << d.node->Name() << " material="
                      << d.node->Mesh()->Material()->name << " visible="
                      << (!d.visibility_node || d.visibility_node->EffectiveVisible()) << " output="
                      << d.output << " image=" << d.vk_output.handle << " clear=" << d.clear_on_first_use << '\n';
                for (std::size_t t = 0; t < d.textures.size(); ++t) {
                    trace << "  " << t << ": " << d.textures[t];
                    // What `g_TextureNResolution` would be given. The updater
                    // writes it only for a bound name it finds among the
                    // scene's render targets and skips silently otherwise, and
                    // a blur divides its step by that value.
                    if (!d.textures[t].empty()) {
                        const auto found = scene->renderTargets.find(d.textures[t]);
                        if (found == scene->renderTargets.end()) {
                            trace << " resolution=MISSING";
                        } else {
                            trace << " resolution=" << found->second.width << 'x'
                                  << found->second.height;
                        }
                    }
                    if (!d.vk_textures[t].slots.empty()) {
                        const auto& texture = d.vk_textures[t].getActive();
                        VkMemoryRequirements memory {};
                        if (texture.handle != VK_NULL_HANDLE) {
                            device.handle().Dispatch().vkGetImageMemoryRequirements(
                                *device.handle(), texture.handle, &memory);
                        }
                        trace << " image=" << texture.handle << " extent=" << texture.extent.width
                              << 'x' << texture.extent.height << " mips=" << texture.mipmap_level
                              << " bytes=" << memory.size;
                    }
                    if (d.sprites_map.contains(t)) {
                        const auto& f = d.sprites_map.at(t).GetCurFrame();
                        trace << " sprite=" << f.x << ',' << f.y << " axis=" << f.xAxis[0] << ',' << f.xAxis[1] << ',' << f.yAxis[0] << ',' << f.yAxis[1];
                    }
                    trace << '\n';
                }
            }
        }
        rr.texture_prefetch = nullptr;
        prefetch.reset();
        milestone("prepared");
        auto result = device.tex_cache().Query(std::string(SpecTex_Default), ToTexKey(*scene->FindRenderTarget(SpecTex_Default)), true);
        Check(result.has_value(), "result target");
        CustomPassExecutionScratch scratch;

        // Drives the static subgraph cache exactly as VulkanRender does, so the
        // golden comparison covers the reuse path rather than only the code it
        // shares with an unoptimised run. `WE_TEST_NO_SCENE_OPTIMIZATION`
        // forces the unoptimised path for a direct A/B.
        StaticSubgraphCache static_cache;
        std::vector<StaticPassSample> static_samples;
        std::vector<uint8_t> static_skip;
        const bool scene_optimization = std::getenv("WE_TEST_NO_SCENE_OPTIMIZATION") == nullptr;
        if (scene_optimization) {
            std::vector<StaticPassDesc> static_descs;
            static_descs.reserve(passes.size());
            for (auto* pass : passes) {
                StaticPassDesc desc;
                if (auto* custom = dynamic_cast<CustomShaderPass*>(pass)) {
                    desc = custom->staticPassDesc(*scene);
                    desc.target = scene->ResolveRenderTargetName(desc.target);
                    for (auto& input : desc.inputs) input = scene->ResolveRenderTargetName(input);
                } else if (auto* copy = dynamic_cast<CopyPass*>(pass)) {
                    desc.target = scene->ResolveRenderTargetName(copy->desc().dst);
                    desc.inputs = { scene->ResolveRenderTargetName(copy->desc().src) };
                } else if (auto* clear = dynamic_cast<PrePass*>(pass)) {
                    desc.target = scene->ResolveRenderTargetName(clear->desc().result);
                }
                static_descs.push_back(std::move(desc));
            }
            static_cache.Compile(static_descs);
            for (std::size_t i = 0; i < static_cache.TargetCount(); ++i) {
                if (! static_cache.TargetCacheable(i)) continue;
                const auto& key = static_cache.TargetKey(i);
                const auto bytes = device.tex_cache().RenderTargetBytes(key);
                if (bytes == 0 || ! device.tex_cache().PinRenderTarget(key)) continue;
                static_cache.SetTargetPinned(i, true, bytes);
            }
            static_samples.assign(passes.size(), StaticPassSample {});
            static_skip.assign(passes.size(), uint8_t { 0 });
        }

        const bool capture_last = std::getenv("WE_TEST_CAPTURE_LAST") != nullptr;
        tests::SceneProbeControls controls;
        scene->runtime->SetScreenResolution(
            Eigen::Vector2f(surface_extent.width, surface_extent.height));
        const auto cursor_layout = ComputeWallpaperScalingLayout(
            WallpaperScalingMode::FILL, extents.source.width, extents.source.height,
            surface_extent.width, surface_extent.height, 1.0, 1.0);
        for (int frame = 0; frame < frame_count; ++frame) {
            if (controls.hasInput()) {
                const auto& camera = *scene->cameras.at("global");
                const auto position = camera.GetPosition();
                controls.input(*scene, frame, ComputeWallpaperCursorMapping(
                    cursor_layout, position.x(), position.y(),
                    camera.VisibleWidth(), camera.VisibleHeight()));
            }
            scene->shaderValueUpdater->FrameBegin();
            if (audio_hz_env) {
                // Synthetic PCM only. Submit after GPU setup so the live-input
                // timeout cannot expire while shaders/pipelines are compiling.
                std::array<float, audio::kAudioResponseWindowFrames> pcm {};
                for (size_t i = 0; i < pcm.size(); ++i) {
                    pcm[i] = controls.audioSample(i, audio_hz);
                }
                const auto generation = audio::CurrentAudioSpectrumSnapshot().generation;
                Check(audio::SubmitMonoAudioFrames(
                          audio::kAudioResponseSampleRate, pcm.size(), pcm.data(), &error),
                      error.c_str());
                const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
                while (audio::CurrentAudioSpectrumSnapshot().generation <= generation &&
                       std::chrono::steady_clock::now() < deadline) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(1));
                }
                Check(audio::CurrentAudioSpectrumSnapshot().generation > generation,
                      "synthetic PCM was not analyzed");
                scene->paritileSys->Emitt();
            }
            scene->runtime->Tick(frame_step > 0.0 ? frame_step : 1.0 / 60.0);
            // Text layout runs on its own thread and its results are collected
            // by the pump, which production DRAW calls every frame. Without
            // this a label whose layout landed after preparation is never
            // rasterized, and the frame is missing text the scene does have.
            scene->runtime->PumpTextLayerCache();
            Check(device.tex_cache().BeginVideoFrameRecording(), "begin frame pins");
            std::vector<VulkanPass*> frame_passes = passes;
            if (scene_optimization) {
                for (std::size_t i = 0; i < passes.size(); ++i) {
                    auto* custom = dynamic_cast<CustomShaderPass*>(passes[i]);
                    static_samples[i] = custom != nullptr
                                            ? custom->frameSample(*scene)
                                            : StaticPassSample { .hash = 0, .visible = true };
                }
                static_cache.Plan(static_samples, static_skip);
                frame_passes.clear();
                for (std::size_t i = 0; i < passes.size(); ++i) {
                    auto* custom = dynamic_cast<CustomShaderPass*>(passes[i]);
                    if (custom != nullptr) custom->setFrameSkipped(static_skip[i] != 0);
                    if (static_skip[i] != 0 && custom == nullptr) continue;
                    frame_passes.push_back(passes[i]);
                }
            }
            Check(UpdatePreparedPasses(device, rr, frame_passes), "update current frame");
            Begin(rr.command);
            // As VulkanRender does right after beginning the frame.
            device.tex_cache().RecordVideoFirstUseTransitions(rr.command);
            Check(vertices.recordUpload(rr.command), "upload vertices");
            Check(dynamic.recordUpload(rr.command), "upload dynamic data");
            // Long samples would otherwise rewrite thousands of intermediate
            // images, so only the final frame is broken out pass by pass.
            const bool dump_passes =
                std::getenv("WE_TEST_DUMP_PASSES") && frame == frame_count - 1;
            if (!dump_passes)
                CheckRecording(device, rr,
                               ExecutePreparedPasses(device, rr, frame_passes, scratch, passes));
            else {
                int pass_index = 0;
                for (auto* pass : passes) {
                    CheckRecording(device, rr, pass->execute(device, rr));
                    if (auto* custom = dynamic_cast<CustomShaderPass*>(pass)) {
                        Submit(device, rr);
                        // Sequence-indexed so every pass survives; node ids repeat.
                        ReadImage(device, rr, custom->desc().vk_output,
                                  out / ("pass-" + std::to_string(pass_index) + "-node" +
                                         std::to_string(custom->desc().node->ID()) + ".ppm"));
                        const auto& d = custom->desc();
                        trace << "frame " << frame << " pass " << pass_index
                              << " id=" << d.node->ID() << " slot=" << d.material_slot
                              << " visible="
                              << (!d.visibility_node || d.visibility_node->EffectiveVisible());
                        if (auto* slot = d.node->Mesh()->MaterialForSlot(d.material_slot)) {
                            trace << " material=" << slot->name << " textures=";
                            for (const auto& texture : slot->textures) trace << '[' << texture << ']';
                            for (const auto& [name, value] : slot->customShader.constValues) {
                                trace << ' ' << name << "=[";
                                for (std::size_t c = 0; c < value.size(); ++c) {
                                    trace << (c != 0 ? "," : "") << value[c];
                                }
                                trace << ']';
                            }
                        }
                        trace << '\n';
                        Check(device.tex_cache().BeginVideoFrameRecording(), "begin next pass pins");
                        Begin(rr.command);
                    }
                    ++pass_index;
                }
            }
            Submit(device, rr);
            if (! capture_last || frame == frame_count - 1 || controls.sample(frame))
                ReadImage(device, rr, *result, out / ("frame-" + std::to_string(frame) + ".ppm"));
            if (controls.sample(frame)) controls.state(*scene, frame, out);
            // The same knob the Metal harness takes, so a target can be held
            // against its counterpart on the other backend instead of the two
            // being described from different code. Names carry a per-run
            // suffix, so `*` is the only way to ask for one across processes.
            if (const char* wanted = std::getenv("WE_TEST_DUMP_TARGETS");
                wanted != nullptr && *wanted != '\0' && frame == frame_count - 1) {
                for (const auto& [name, target] : scene->renderTargets) {
                    if (std::string_view(wanted) != "*" &&
                        std::string_view(wanted).find(name) == std::string_view::npos) {
                        continue;
                    }
                    auto dumped = device.tex_cache().Query(name, ToTexKey(target), true);
                    if (! dumped.has_value()) continue;
                    std::string safe = name;
                    std::replace(safe.begin(), safe.end(), '/', '_');
                    ReadImage(device, rr, *dumped, out / ("target-" + safe + ".ppm"));
                }
            }
            if (frame == 0) milestone("first-frame");
            if (frame_step > 0.0 || audio_hz_env)
                scene->PassFrameTime(frame_step > 0.0 ? frame_step : 1.0 / 60.0);
            scene->shaderValueUpdater->FrameEnd();
        }
        if (scene_optimization) {
            // Reported so a golden comparison cannot pass vacuously: identical
            // pixels prove nothing if no pass was ever reused.
            const auto& stats = static_cache.stats();
            std::cout << "Scene optimization: " << stats.skipped_passes << " passes reused, "
                      << stats.executed_passes << " executed, " << stats.cacheable_targets
                      << " cacheable targets, " << stats.pinned_targets << " pinned\n";
        }
        Check(device.handle().WaitIdle() == VK_SUCCESS, "final probe idle");

        device.SavePipelineCache();
        Check(rr.command.Reset() == VK_SUCCESS, "discard final probe command");
        Check(device.tex_cache().WaitForPendingUploads(), "retire texture uploads");
#if defined(__APPLE__)
        rusage_info_v4 usage {};
        if (proc_pid_rusage(getpid(), RUSAGE_INFO_V4,
                           reinterpret_cast<rusage_info_t*>(&usage)) == 0) {
            std::cout << "Process memory: footprint=" << usage.ri_phys_footprint
                      << " peak=" << usage.ri_lifetime_max_phys_footprint << '\n';
        }
#endif
        VmaStats memory {};
        vmaCalculateStats(device.vma_allocator(), &memory);
        std::cout << "VMA memory: blocks=" << memory.total.blockCount
                  << " reserved=" << (memory.total.usedBytes + memory.total.unusedBytes)
                  << " allocated=" << memory.total.usedBytes << '\n';
        for (auto* pass : passes) pass->destory(device, rr);
        passes.clear();
        scratch.passes.clear();
        scratch.candidates.clear();
        scratch.plan.entries.clear();
        Check(device.tex_cache().Clear(), "clear probe cache");
        std::cout << "Offscreen scene output: " << out << '\n';
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n'; return 1;
    }
}
