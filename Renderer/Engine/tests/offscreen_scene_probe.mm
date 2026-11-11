// Explicit diagnostic tool. Draws one imported scene with Native Metal into private GPU
// images: a CAMetalLayer no window owns, no AppKit window, audio device or desktop capture.
// Writes the scene's own render target after every frame (`frame-<n>.ppm`).
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

#include "Audio/SoundManager.h"
#include "Utils/Random.hpp"
#include "Audio/AudioResponseService.h"
#include "Particle/ParticleSystem.h"
#include "Fs/PhysicalFs.h"
#include "Fs/VFS.h"
#include "Project/ProjectProperties.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/RuntimeImageSource.hpp"
#include "Runtime/VirtualAssetRegistry.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneNode.h"
#include "WPSceneParser.hpp"
#include "SceneSourceResolver.hpp"
#include "scene_probe_controls.hpp"
#include "scene_graph_changes.hpp"
#include "MetalRender/MetalBackendRouter.hpp"
#include "MetalRender/MetalRender.hpp"
#include "RenderCommon/SceneRaster.hpp"
#include "RenderCommon/StaticSubgraphCache.hpp"
#include "RenderCommon/SceneToRenderGraph.hpp"
#include "Presentation/WallpaperScaling.hpp"
#include "RenderGraph/RenderGraph.hpp"
#include "Interface/IImageParser.h"
#include "SpecTexs.hpp"
#include <charconv>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <nlohmann/json.hpp>
#include <stdexcept>
#include <vector>
#include <thread>

using namespace wallpaper;
using namespace wallpaper::metal;

#if defined(__APPLE__)
#include <libproc.h>
#include <sys/resource.h>
#include <unistd.h>
#endif

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
        // WE_TEST_SCENE_STORAGE: the folder the scripts' localStorage persists in (display-1's
        // screen file), so a second run can read what the first one saved.
        const char* storage = std::getenv("WE_TEST_SCENE_STORAGE");
        auto scene = parser.Parse(SceneParseRequest {
            .scene_id = paths.scene_id, .project_path = project,
            .project_properties = &properties, .pkg_version = PackageVersion(paths.pkg_path),
            .storage_directory = storage != nullptr ? storage : "", .storage_screen_key = "display-1",
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
            linalg::Vector3f position = (target->ModelTrans() * linalg::Vector4d(0, 0, 0, 1)).head<3>().cast<float>();
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
                const auto source = render::ResolveSceneSourceExtent(*scene, Extent2D { px_w, px_h });
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
                    .origin = linalg::Vector2f(static_cast<float>(mapping.origin_x),
                                              static_cast<float>(mapping.origin_y)),
                    .size   = linalg::Vector2f(static_cast<float>(mapping.size_x),
                                            static_cast<float>(mapping.size_y)),
                    .content_origin =
                        linalg::Vector2f(static_cast<float>(mapping.content_origin_x),
                                        static_cast<float>(mapping.content_origin_y)),
                    .content_size = linalg::Vector2f(static_cast<float>(mapping.content_size_x),
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
        // WE_TEST_CURSOR_PATH: a scripted cursor, one entry a 1/60 s tick before the captured frames:
        // "x,y,down;x,y,down;..." in world units, `down` 1 while the left button is held (0 or left
        // out: up). A press and a release are dispatched where `down` changes, so a script can be
        // made to drag (cursorDown, cursorMove, cursorUp) the same way every run. The scene clock
        // moves with each tick (puppet poses and their simulation follow it). With
        // WE_TEST_CURSOR_TRACE=<layer name> each tick prints that puppet layer's bone world origins.
        if (const char* path = std::getenv("WE_TEST_CURSOR_PATH")) {
            const char* trace = std::getenv("WE_TEST_CURSOR_TRACE");
            scene->runtime->SetCursorEnter(true);
            bool       held  = false;
            int        ticks = 0;
            std::string_view rest(path);
            while (! rest.empty()) {
                const auto        end   = rest.find(';');
                const std::string entry(rest.substr(0, end));
                rest = end == std::string_view::npos ? std::string_view {} : rest.substr(end + 1);
                if (entry.empty()) continue;
                float x = 0.0f, y = 0.0f;
                int   down = 0;
                const int read = std::sscanf(entry.c_str(), "%f,%f,%d", &x, &y, &down);
                Check(read >= 2, "WE_TEST_CURSOR_PATH entries must be \"x,y[,down]\"");
                const bool now = down != 0;
                scene->runtime->SetCursorWorldPosition(linalg::Vector3f(x, y, 0.0f));
                scene->runtime->SetCursorButtons(now ? 1u : 0u, now && ! held ? 1u : 0u, ! now && held ? 1u : 0u);
                scene->runtime->DispatchCursorFrameEvents(ticks != 0);
                scene->runtime->Tick(1.0 / 60.0);
                scene->PassFrameTime(1.0 / 60.0);
                held = now;
                ++ticks;
                Check(ticks <= 36000, "WE_TEST_CURSOR_PATH holds at most 36000 entries");
                if (trace != nullptr) {
                    std::cout << "tick " << ticks << " t=" << scene->elapsingTime << " cursor=" << x << ',' << y
                              << (now ? " down" : " up");
                    for (int32_t b = 0; b < scene->runtime->PuppetBoneCount(trace); ++b) {
                        const auto m = scene->runtime->PuppetBoneTransform(
                            trace, b, SceneRuntimeContext::PuppetBoneSpace::World);
                        if (m.has_value()) std::cout << " b" << b << '=' << (*m)(0, 3) << ',' << (*m)(1, 3);
                    }
                    std::cout << std::endl;
                }
            }
            scene->runtime->SetCursorButtons(0, 0, 0);
            std::cout << "cursor path ticks=" << ticks << std::endl;
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
                const linalg::Vector3d world =
                    (node->ModelTrans() * linalg::Vector4d(0, 0, 0, 1)).head<3>();
                const linalg::Vector3d rendered =
                    (node->RenderTrans() * linalg::Vector4d(0, 0, 0, 1)).head<3>();
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
            const auto image = scene->imageParser->Parse(TextAtlasName(name));
            if (image && !image->slots.empty()) {
                const auto& mip = image->slots[0].mipmaps[0];
                std::vector<uint8_t> pixels(mip.data.get(), mip.data.get() + mip.size);
                for (std::size_t i = 0; i < pixels.size(); i += 4)
                    for (int c = 0; c < 3; ++c) pixels[i+c] = pixels[i+c] * pixels[i+3] / 255;
                // Layer names are untrusted package data, not output paths.
                Ppm(out / ("text-" + std::to_string(text_index++) + ".ppm"), pixels.data(), mip.width, mip.height);
            }
        }
        // The isolated run: no static-result reuse and no sharing of images between targets
        // that are never alive together, so every target keeps an image of its own. Read once
        // per process, so it is set before anything creates a renderer.
        const bool isolated = std::getenv("WE_TEST_NO_REUSE") != nullptr;
        if (isolated) ::setenv("WALLPAPER_MACHINE_METAL_TARGET_SHARING", "0", 1);
        const bool scene_optimization =
            ! isolated && std::getenv("WE_TEST_NO_SCENE_OPTIMIZATION") == nullptr;
        render::SetSceneOptimizationEnabled(scene_optimization);

        if (const char* size = std::getenv("WE_TEST_TEXTURE_SURFACE")) {
            unsigned width = 0, height = 0;
            Check(std::sscanf(size, "%ux%u", &width, &height) == 2 && width && height,
                  "WE_TEST_TEXTURE_SURFACE must be <width>x<height>");
            scene->imageParser->SetTextureSurfaceSize(scene->display_sized ? 0 : width,
                                                     scene->display_sized ? 0 : height);
        }
        uint32_t surface_width = 1920, surface_height = 1080;
        if (const char* size = std::getenv("WE_TEST_SURFACE")) {
            Check(std::sscanf(size, "%ux%u", &surface_width, &surface_height) == 2 &&
                      surface_width > 0 && surface_height > 0 && surface_width <= 8192 &&
                      surface_height <= 8192,
                  "WE_TEST_SURFACE must be <width>x<height>");
        }
        const auto selection = SelectSceneBackend(*scene);
        if (selection.failed()) {
            std::cerr << "Native Metal does not draw this scene: " << selection.failure_reason << '\n';
            return 1;
        }

        @autoreleasepool {
            CAMetalLayer* layer   = [CAMetalLayer layer];
            layer.device          = MTLCreateSystemDefaultDevice();
            Check(layer.device != nil, "no Metal device");
            layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
            layer.drawableSize    = CGSizeMake(surface_width, surface_height);
            layer.framebufferOnly = NO;

            MetalRender         render;
            MetalRenderInitInfo info {
                .metal_layer   = (__bridge void*)layer,
                .width         = static_cast<uint16_t>(surface_width),
                .height        = static_cast<uint16_t>(surface_height),
                .render_width  = static_cast<uint16_t>(surface_width),
                .render_height = static_cast<uint16_t>(surface_height),
            };
            Check(render.init(info), render.lastError().c_str());
            auto graph = sceneToRenderGraph(*scene);
            Check(graph != nullptr, "build the render graph");
            Check(render.compileRenderGraph(*scene, *graph), render.lastError().c_str());
            // As the host presents a wallpaper.
            render.SetWallpaperScalingMode(WallpaperScalingMode::FILL);
            render.SetWallpaperScalingFactor(1.0);
            render.SetWallpaperFraming(WallpaperFraming {});
            render.SetWallpaperHorizontalFlip(false);
            milestone("prepared");

            const bool capture_last = std::getenv("WE_TEST_CAPTURE_LAST") != nullptr;
            tests::SceneProbeControls controls;
            scene->runtime->SetScreenResolution(linalg::Vector2f(surface_width, surface_height));
            const auto read_target = [&](const std::string& key, uint32_t& width, uint32_t& height,
                                         std::vector<uint8_t>& rgba) {
                return render.ReadRenderTargetForTests(scene->ResolveRenderTargetName(key), rgba,
                                                       width, height);
            };
            for (int frame = 0; frame < frame_count; ++frame) {
                if (controls.hasInput()) {
                    controls.input(*scene, static_cast<uint32_t>(frame), render.CursorMapping(*scene));
                }
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
                }
                scene->targetFps =
                    static_cast<uint32_t>(std::lround(1.0 / (frame_step > 0.0 ? frame_step : 1.0 / 60.0)));
                scene->paritileSys->Emitt();
                scene->runtime->Tick(frame_step > 0.0 ? frame_step : 1.0 / 60.0);
                // Text layout runs on its own thread and its results are collected
                // by the pump, which the host calls every frame. Without this a
                // label whose layout landed after preparation is never rasterized.
                scene->runtime->PumpTextLayerCache();
                {
                    std::string change_error;
                    tests::ApplyRuntimeSceneChanges(render, *scene, graph, true, &change_error);
                    Check(change_error.empty(), change_error.c_str());
                }
                scene->shaderValueUpdater->FrameBegin();
                Check(render.drawFrame(*scene),
                      ("frame " + std::to_string(frame) + ": " + render.lastError()).c_str());
                if (! capture_last || frame == frame_count - 1 || controls.sample(frame)) {
                    uint32_t             width = 0, height = 0;
                    std::vector<uint8_t> rgba;
                    Check(read_target(std::string(SpecTex_Default), width, height, rgba),
                          "read the scene's output target");
                    Ppm(out / ("frame-" + std::to_string(frame) + ".ppm"), rgba.data(), width, height);
                    if (std::getenv("WE_TEST_DUMP_ALPHA") != nullptr) {
                        PpmAlpha(out / ("frame-" + std::to_string(frame) + "-alpha.ppm"),
                                 rgba.data(), width, height);
                    }
                }
                if (controls.sample(frame)) controls.state(*scene, frame, out);
                // A target held against its counterpart in another build, instead of the two
                // being described from different code. Names carry a per-run suffix, so `*`
                // is the only way to ask for one across processes.
                if (const char* wanted = std::getenv("WE_TEST_DUMP_TARGETS");
                    wanted != nullptr && *wanted != '\0' && frame == frame_count - 1) {
                    for (const auto& [name, target] : scene->renderTargets) {
                        (void)target;
                        if (std::string_view(wanted) != "*" &&
                            std::string_view(wanted).find(name) == std::string_view::npos) {
                            continue;
                        }
                        uint32_t             width = 0, height = 0;
                        std::vector<uint8_t> rgba;
                        if (! read_target(name, width, height, rgba) || width == 0 || height == 0)
                            continue;
                        std::string safe = name;
                        std::replace(safe.begin(), safe.end(), '/', '_');
                        Ppm(out / ("target-" + safe + ".ppm"), rgba.data(), width, height);
                    }
                }
                if (frame == 0) milestone("first-frame");
                if (frame_step > 0.0 || audio_hz_env)
                    scene->PassFrameTime(frame_step > 0.0 ? frame_step : 1.0 / 60.0);
                scene->shaderValueUpdater->FrameEnd();
            }
            // Reported so a comparison cannot pass vacuously: identical pixels prove nothing
            // if nothing was reused.
            std::cout << "Scene optimization: " << (scene_optimization ? "on" : "off")
                      << (isolated ? ", isolated targets" : "") << '\n';
#if defined(__APPLE__)
            rusage_info_v4 usage {};
            if (proc_pid_rusage(getpid(), RUSAGE_INFO_V4,
                                reinterpret_cast<rusage_info_t*>(&usage)) == 0) {
                std::cout << "Process memory: footprint=" << usage.ri_phys_footprint
                          << " peak=" << usage.ri_lifetime_max_phys_footprint << '\n';
            }
#endif
            render.destroy();
        }
        std::cout << "Offscreen scene output: " << out << '\n';
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n'; return 1;
    }
}
