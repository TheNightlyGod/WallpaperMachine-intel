/// End-to-end proof for the native Metal scene backend.
///
/// Parses an author project the ordinary way, with the native renderer
/// selected, then:
///   1. feeds the translated Metal Shading Language to `newLibraryWithSource:`
///      -- the first time anything has done so -- and reports the compiler's
///      own diagnostic verbatim if it refuses,
///   2. builds the real render graph and draws it with
///      `MTLRenderCommandEncoder`, and
///   3. reads the scene's own output image back and checks the author's shader
///      actually wrote it.
///
/// Creates only private GPU textures and an offscreen layer. No window, no
/// desktop, no audio device, no screen capture.

#include "Runtime/RuntimeImageSource.hpp"
#include "MetalRender/MetalBackendRouter.hpp"
#include "MetalRender/MetalCapability.hpp"
#include "MetalRender/MetalRender.hpp"
#include "MetalRender/MetalShaderReflection.hpp"
#include "MetalRender/MetalVideoSupport.hpp"
#include "MetalRender/SceneMetalProgram.hpp"

#include "Audio/AudioResponseService.h"
#include "Audio/SoundManager.h"
#include "Core/Random.hpp"
#include "Fs/PhysicalFs.h"
#include "Fs/VFS.h"
#include "Particle/ParticleSystem.h"
#include "Project/ProjectProperties.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/VirtualAssetRegistry.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneBackendSelection.hpp"
#include "Scene/SceneUpdateDemand.hpp"
#include "Scene/SceneNode.h"
#include "Scene/SceneMesh.h"
#include "Scene/SceneTexture.h"
#include "SpriteAnimation.hpp"
#include "video_orientation_cases.hpp"
#include "Scene/SceneRendererHandle.hpp"
#include "SpecTexs.hpp"
#include "WPShaderValueUpdater.hpp"
#include "RenderGraph/RenderGraph.hpp"
#include "VulkanRender/CopyPass.hpp"
#include "VulkanRender/CustomShaderPass.hpp"
#include "VulkanRender/SceneToRenderGraph.hpp"
#include "VulkanRender/StaticSubgraphCache.hpp"
#include "Shader/SceneMetalVariants.hpp"
#include "Scene/Parse/WPShaderParser.hpp"
#include "Shader/RustShaderBridge.hpp"
#include "WPSceneParser.hpp"
#include "SceneSourceResolver.hpp"
#include "synthetic_video.hpp"
#include "scene_probe_controls.hpp"

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <vulkan/vulkan.h>
#include <vulkan/vulkan_metal.h>

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include <array>
#include <atomic>
#include <charconv>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <map>
#include <memory>
#include <mutex>
#include <span>
#include <string>
#include <thread>
#include <utility>
#include <vector>
#include <time.h>

using namespace wallpaper;
using namespace wallpaper::metal;

namespace
{

/// A minimal original scene: one flat-coloured card drawn through the author's
/// own vertex and fragment shaders. Small on purpose -- the point is that the
/// shader is real and travels the whole pipeline, not that the scene is rich.
/// `blue` picks the constant the fragment shader writes, which is only ever
/// varied to make a fixture's translated program textually unique -- the one
/// test that has to observe a cold compile needs a source no earlier test in
/// the same process has already compiled.
std::filesystem::path WriteFixture(const std::filesystem::path& root,
                                   std::string_view blue = "0.25")
{
    const std::string vertex =
        "uniform mat4 g_ModelViewProjectionMatrix;\n"
        "attribute vec3 a_Position;\n"
        "attribute vec2 a_TexCoord;\n"
        "varying vec2 v_TexCoord;\n"
        "void main() {\n"
        "  gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);\n"
        "  v_TexCoord = a_TexCoord;\n"
        "}\n";
    const std::string fragment =
        "varying vec2 v_TexCoord;\n"
        "void main() {\n"
        "  gl_FragColor = vec4(v_TexCoord.x, v_TexCoord.y, " + std::string(blue) + ", 1.0);\n"
        "}\n";

    const std::map<std::string, std::string> files {
        { "project.json",
          R"({"title":"Metal draw smoke","type":"scene","file":"layout.json","general":{"properties":{}}})" },
        { "models/tile.json", R"({"width":256,"height":192,"material":"materials/tile.json"})" },
        { "materials/tile.json",
          R"({"passes":[{"shader":"metal_probe","blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled"}]})" },
        { "shaders/metal_probe.vert", vertex },
        { "shaders/metal_probe.frag", fragment },
        { "layout.json",
          R"({"camera":{"center":[0,0,0],"eye":[0,0,1],"up":[0,1,0]},)"
          R"("general":{"ambientcolor":[0,0,0],"skylightcolor":[0,0,0],"clearcolor":[0.0,0.0,0.0],)"
          R"("cameraparallax":false,"orthogonalprojection":{"width":384,"height":256}},)"
          R"("objects":[{"id":1,"name":"tile","image":"models/tile.json","origin":[192,128,0],)"
          R"("scale":[1,1,1],"angles":[0,0,0],"visible":true}]})" },
    };

    for (const auto& [name, contents] : files) {
        const auto path = root / name;
        std::filesystem::create_directories(path.parent_path());
        std::ofstream(path) << contents;
    }
    return root / "project.json";
}

/// Three of the fixture's cards over one another, left to right, all drawn
/// straight into the scene's own image. The middle card's `visible` is
/// `middle_visibility_json` verbatim: a literal, or a binding to the project's
/// `showmiddle` property, whose saved value is `show_middle`.
std::filesystem::path WriteLayeredFixture(const std::filesystem::path& root,
                                          std::string_view middle_visibility_json, bool show_middle)
{
    const auto project = WriteFixture(root);
    const auto card = [](int id, std::string_view name, int x, std::string_view visible) {
        return R"({"id":)" + std::to_string(id) + R"(,"name":")" + std::string(name) +
               R"(","image":"models/tile.json","origin":[)" + std::to_string(x) +
               R"(,128,0],"scale":[1,1,1],"angles":[0,0,0],"visible":)" + std::string(visible) +
               "}";
    };
    std::ofstream(project)
        << R"({"title":"Metal layered smoke","type":"scene","file":"layout.json","general":)"
        << R"({"properties":{"showmiddle":{"type":"bool","value":)"
        << (show_middle ? "true" : "false") << "}}}}";
    std::ofstream(root / "layout.json")
        << R"({"camera":{"center":[0,0,0],"eye":[0,0,1],"up":[0,1,0]},)"
        << R"("general":{"ambientcolor":[0,0,0],"skylightcolor":[0,0,0],"clearcolor":[0.0,0.0,0.0],)"
        << R"("cameraparallax":false,"orthogonalprojection":{"width":384,"height":256}},)"
        << R"("objects":[)" << card(1, "left", 96, "true") << ","
        << card(2, "middle", 192, middle_visibility_json) << "," << card(3, "right", 288, "true")
        << "]}";
    return project;
}

/// The fixture's card, then two smaller lenses over it that each read the scene
/// as it stands beneath them. A lens samples `_rt_FullFrameBuffer`, which is the
/// image it draws into, so the graph copies that image first; the second lens
/// sees the first one's output. A lens shows what it read with red and blue
/// inverted, so over the card, whose blue is 0.25, its blue is 0.75.
std::filesystem::path WriteFeedbackFixture(const std::filesystem::path& root)
{
    const auto project = WriteFixture(root);
    const std::map<std::string, std::string> files {
        { "models/lens.json", R"({"width":128,"height":96,"material":"materials/lens.json"})" },
        { "materials/lens.json",
          R"({"passes":[{"shader":"feedback_lens","blending":"translucent","cullmode":"nocull",)"
          R"("depthtest":"disabled","depthwrite":"disabled","textures":["_rt_FullFrameBuffer"]}]})" },
        { "shaders/feedback_lens.vert",
          "uniform mat4 g_ModelViewProjectionMatrix;\n"
          "attribute vec3 a_Position;\n"
          "attribute vec2 a_TexCoord;\n"
          "varying vec2 v_TexCoord;\n"
          "void main() {\n"
          "  gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);\n"
          "  v_TexCoord = a_TexCoord;\n"
          "}\n" },
        { "shaders/feedback_lens.frag",
          "uniform sampler2D g_Texture0;\n"
          "varying vec2 v_TexCoord;\n"
          "void main() {\n"
          "  vec4 behind = texture(g_Texture0, v_TexCoord);\n"
          "  gl_FragColor = vec4(1.0 - behind.r, behind.g, 1.0 - behind.b, 1.0);\n"
          "}\n" },
        { "layout.json",
          R"({"camera":{"center":[0,0,0],"eye":[0,0,1],"up":[0,1,0]},)"
          R"("general":{"ambientcolor":[0,0,0],"skylightcolor":[0,0,0],"clearcolor":[0.0,0.0,0.0],)"
          R"("cameraparallax":false,"orthogonalprojection":{"width":384,"height":256}},)"
          R"("objects":[{"id":1,"name":"tile","image":"models/tile.json","origin":[192,128,0],)"
          R"("scale":[1,1,1],"angles":[0,0,0],"visible":true},)"
          R"({"id":2,"name":"lens","image":"models/lens.json","origin":[160,112,0],)"
          R"("scale":[1,1,1],"angles":[0,0,0],"visible":true},)"
          R"({"id":3,"name":"second lens","image":"models/lens.json","origin":[224,144,0],)"
          R"("scale":[1,1,1],"angles":[0,0,0],"visible":true}]})" },
    };
    for (const auto& [name, contents] : files) {
        const auto path = root / name;
        std::filesystem::create_directories(path.parent_path());
        std::ofstream(path) << contents;
    }
    return project;
}

/// A small card of the probe tile and, apart from it, an echo card that
/// shows the scene's previous frame through `_rt_MipMappedFrameBuffer`. The
/// graph fills that buffer from the frame's output after the echo has read
/// it, so what the echo samples is always the frame before.
std::filesystem::path WriteHistoryFixture(const std::filesystem::path& root)
{
    const auto project = WriteFixture(root);
    const std::map<std::string, std::string> files {
        { "models/small.json", R"({"width":96,"height":64,"material":"materials/tile.json"})" },
        { "models/echo.json", R"({"width":192,"height":128,"material":"materials/echo.json"})" },
        { "materials/echo.json",
          R"({"passes":[{"shader":"history_echo","blending":"translucent","cullmode":"nocull",)"
          R"("depthtest":"disabled","depthwrite":"disabled","textures":["_rt_MipMappedFrameBuffer"]}]})" },
        { "shaders/history_echo.vert",
          "uniform mat4 g_ModelViewProjectionMatrix;\n"
          "attribute vec3 a_Position;\n"
          "attribute vec2 a_TexCoord;\n"
          "varying vec2 v_TexCoord;\n"
          "void main() {\n"
          "  gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);\n"
          "  v_TexCoord = a_TexCoord;\n"
          "}\n" },
        { "shaders/history_echo.frag",
          "uniform sampler2D g_Texture0;\n"
          "varying vec2 v_TexCoord;\n"
          "void main() {\n"
          "  gl_FragColor = vec4(texture(g_Texture0, v_TexCoord).rgb, 1.0);\n"
          "}\n" },
        { "layout.json",
          R"({"camera":{"center":[0,0,0],"eye":[0,0,1],"up":[0,1,0]},)"
          R"("general":{"ambientcolor":[0,0,0],"skylightcolor":[0,0,0],"clearcolor":[0.0,0.0,0.0],)"
          R"("cameraparallax":false,"orthogonalprojection":{"width":384,"height":256}},)"
          R"("objects":[{"id":1,"name":"tile","image":"models/small.json","origin":[64,208,0],)"
          R"("scale":[1,1,1],"angles":[0,0,0],"visible":true},)"
          R"({"id":2,"name":"echo","image":"models/echo.json","origin":[272,80,0],)"
          R"("scale":[1,1,1],"angles":[0,0,0],"visible":true}]})" },
    };
    for (const auto& [name, contents] : files) {
        const auto path = root / name;
        std::filesystem::create_directories(path.parent_path());
        std::ofstream(path) << contents;
    }
    return project;
}

struct LoadedScene
{
    fs::VFS                vfs;
    audio::SoundManager    sound { audio::SoundManager::OutputBackend::Null };
    ProjectProperties      properties;
    std::shared_ptr<Scene> scene;
};

bool LoadScene(const std::filesystem::path& project, const std::filesystem::path& cache,
               LoadedScene& out, std::string& error)
{
    const auto directory = project.parent_path();
    if (! out.vfs.Mount("/assets", fs::CreatePhysicalFs(directory.string()), "assets")) {
        error = "assets mount failed";
        return false;
    }
    if (! out.vfs.Mount("/cache", fs::CreatePhysicalFs(cache.string(), true), "cache")) {
        error = "cache mount failed";
        return false;
    }
    InstallVirtualAssets(out.vfs);
    if (! ParseProjectProperties(project.string(), &out.properties, &error)) return false;

    auto source = out.vfs.Open("/assets/layout.json");
    if (source == nullptr) {
        error = "scene source missing";
        return false;
    }
    WPSceneParser parser;
    out.scene = parser.Parse(SceneParseRequest {
                                 .scene_id           = "metal-draw-smoke",
                                 .project_path       = project.string(),
                                 .project_properties = &out.properties,
                             },
                             source->ReadAllStr(), out.vfs, out.sound);
    if (out.scene == nullptr) {
        error = "scene parse failed";
        return false;
    }
    return true;
}

SceneNode* FirstDrawableNode(SceneNode* node)
{
    if (node == nullptr) return nullptr;
    if (auto* mesh = node->Mesh(); mesh != nullptr && mesh->MaterialForSlot(0) != nullptr) {
        return node;
    }
    for (const auto& child : node->GetChildren()) {
        if (auto* found = FirstDrawableNode(child.get()); found != nullptr) return found;
    }
    return nullptr;
}

/// The last frame's final composition from one renderer.
struct RendererPicture
{
    std::vector<uint8_t> rgb;
    uint32_t             width { 0 };
    uint32_t             height { 0 };
    /// Why there is no picture: the renderer did not start, prepare or draw.
    std::string          error;
};

/// Draws `scene` with one renderer through `SceneRendererHandle` on a layer no
/// window owns, as the host drives it -- the scaling it pushes to every
/// renderer it creates, its per-frame `FrameBegin`, a graph rebuilt on every
/// mutation -- and returns the last frame through the poster path both
/// renderers share. Two calls on two parses of one scene, seeded and clocked
/// alike, differ only by what the renderers did.
RendererPicture DrawWithRenderer(Scene& scene, bool native, uint32_t width, uint32_t height,
                                 int frames, double step)
{
    RendererPicture picture;
    @autoreleasepool {
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = MTLCreateSystemDefaultDevice();
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.contentsScale   = 1.0;
        layer.frame           = CGRectMake(0, 0, width, height);
        layer.drawableSize    = CGSizeMake(width, height);
        layer.framebufferOnly = NO;
        void* handle          = (__bridge void*)layer;

        std::atomic<bool> wanted { false };
        RenderInitInfo    info;
        info.metal_layer   = handle;
        info.width         = static_cast<uint16_t>(width);
        info.height        = static_cast<uint16_t>(height);
        info.render_width  = static_cast<uint16_t>(width);
        info.render_height = static_cast<uint16_t>(height);
        info.surface_info.instanceExts = { VK_KHR_SURFACE_EXTENSION_NAME,
                                           VK_EXT_METAL_SURFACE_EXTENSION_NAME };
        info.surface_info.createSurfaceOp = [handle](VkInstance instance, VkSurfaceKHR* surface) {
            auto* create = reinterpret_cast<PFN_vkCreateMetalSurfaceEXT>(
                vkGetInstanceProcAddr(instance, "vkCreateMetalSurfaceEXT"));
            if (create == nullptr) return VK_ERROR_EXTENSION_NOT_PRESENT;
            const VkMetalSurfaceCreateInfoEXT create_info {
                .sType  = VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT,
                .pNext  = nullptr,
                .flags  = 0,
                .pLayer = (__bridge CAMetalLayer*)handle,
            };
            return create(instance, &create_info, nullptr, surface);
        };
        info.wants_poster   = [&wanted] { return wanted.exchange(false); };
        info.poster_pending = [&wanted] { return wanted.load(); };
        info.poster_ready   = [&picture](std::span<const uint8_t> bytes, uint32_t w, uint32_t h,
                                       bool bgra) {
            picture.width  = w;
            picture.height = h;
            picture.rgb.resize(std::size_t(w) * h * 3);
            for (std::size_t i = 0; i < std::size_t(w) * h && i * 4 + 3 < bytes.size(); ++i) {
                picture.rgb[i * 3 + 0] = bytes[i * 4 + (bgra ? 2 : 0)];
                picture.rgb[i * 3 + 1] = bytes[i * 4 + 1];
                picture.rgb[i * 3 + 2] = bytes[i * 4 + (bgra ? 0 : 2)];
            }
        };

        SceneRendererHandle render;
        std::string         error;
        if (native ? ! render.createMetal(info, error) : ! render.createVulkan(info)) {
            picture.error = "could not start: " + error;
            return picture;
        }
        auto graph = sceneToRenderGraph(scene);
        if (graph == nullptr || ! render.compileRenderGraph(scene, *graph)) {
            picture.error = "could not prepare: " + render.lastError();
            render.destroy();
            return picture;
        }
        render.SetWallpaperScalingMode(WallpaperScalingMode::FILL);
        render.SetWallpaperScalingFactor(1.0);
        render.SetWallpaperFraming(WallpaperFraming {});
        render.SetWallpaperHorizontalFlip(false);
        render.UpdateCameraFillMode(scene, FillMode::ASPECTCROP);
        if (scene.runtime != nullptr) {
            scene.runtime->SetScreenResolution(Eigen::Vector2f(width, height));
        }
        for (int frame = 0; frame < frames && picture.error.empty(); ++frame) {
            scene.paritileSys->Emitt();
            if (scene.runtime != nullptr) {
                scene.runtime->Tick(step);
                scene.runtime->PumpTextLayerCache();
                if (scene.runtime->ConsumeSceneGraphMutationFlag()) {
                    // Cleared before the old graph is released: the renderer
                    // still refers to its passes until then.
                    if (! render.clearLastRenderGraph()) {
                        picture.error = "could not rebuild: " + render.lastError();
                        break;
                    }
                    graph = sceneToRenderGraph(scene);
                    if (graph == nullptr || ! render.compileRenderGraph(scene, *graph)) {
                        picture.error = "could not rebuild: " + render.lastError();
                        break;
                    }
                }
            }
            if (frame == frames - 1) wanted = true;
            if (scene.shaderValueUpdater != nullptr) scene.shaderValueUpdater->FrameBegin();
            if (! render.drawFrame(scene)) {
                picture.error = "frame " + std::to_string(frame) + ": " + render.lastError();
            }
            scene.PassFrameTime(step);
        }
        if (picture.rgb.empty() && picture.error.empty() && native) {
            (void)render.ServicePosterRequest(scene);
        }
        render.destroy();
        if (picture.rgb.empty() && picture.error.empty()) picture.error = "delivered no picture";
    }
    return picture;
}

rg::TexNode::Desc TexDesc(const std::string& key)
{
    return rg::TexNode::Desc {
        .name = key,
        .key  = key,
        .type = IsSpecTex(key) ? rg::TexNode::TexType::Temp : rg::TexNode::TexType::Imported,
    };
}

void AddDraw(rg::RenderGraph& graph, SceneNode* node, const std::string& output,
             const std::vector<std::string>& inputs, bool clear = true)
{
    const auto* pass = graph.addPass<vulkan::CustomShaderPass>(
        "draw", rg::PassNode::Type::CustomShader,
        [node, &output, &inputs](rg::RenderGraphBuilder&          builder,
                                 vulkan::CustomShaderPass::Desc& desc) {
            desc.node             = node;
            desc.visibility_node  = node;
            desc.output           = output;
            for (const auto& input : inputs) {
                auto* tex = builder.createTexNode(TexDesc(input));
                if (IsSpecTex(input)) builder.markVirtualWrite(tex);
                builder.read(tex);
                desc.textures.push_back(std::string(tex->key()));
            }
            builder.write(builder.createTexNode(TexDesc(output), true));
        });
    // These actions are finalized after construction, as in sceneToRenderGraph.
    auto& desc = static_cast<vulkan::CustomShaderPass*>(graph.getPass(pass->ID()))->desc();
    desc.write_alpha = output != SpecTex_Default;
    desc.clear_on_first_use = clear;
    desc.preserve_target_contents = ! clear;
}

void AddCopy(rg::RenderGraph& graph, const std::string& source, const std::string& destination)
{
    graph.addPass<vulkan::CopyPass>(
        "copy", rg::PassNode::Type::Copy,
        [&source, &destination](rg::RenderGraphBuilder& builder, vulkan::CopyPass::Desc& desc) {
            auto* in  = builder.createTexNode(TexDesc(source));
            auto* out = builder.createTexNode(TexDesc(destination), true);
            builder.read(in);
            builder.write(out);
            desc.src = std::string(in->key());
            desc.dst = std::string(out->key());
        });
}

/// Asks for this scene's optional programs and waits, bounded, for the
/// background translation to settle.
///
/// The wallpaper's own loop asks for exactly this at a frame boundary and never
/// waits; a test that wants to compare the two paths has to know the second one
/// exists before it starts drawing, which is what this waits for.
bool SettleVariantTranslation(Scene& scene, std::string* reason,
                              std::string_view cache_root = {})
{
    RequestSceneMetalVariants(scene, true, cache_root);
    for (const auto& program : scene.metal_variant_candidates) {
        if (program == nullptr) continue;
        for (int attempt = 0; attempt < 500; ++attempt) {
            if (program->videoPlaneState() != SceneMetalVariantState::Pending) break;
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
        const auto state = program->videoPlaneState();
        if (state == SceneMetalVariantState::Ready) continue;
        if (reason != nullptr) {
            const auto variant = program->videoPlanes();
            *reason = state == SceneMetalVariantState::Failed && variant != nullptr
                          ? variant->error
                          : "the optional translation did not finish";
        }
        return false;
    }
    return true;
}

/// Draws, without advancing the scene clock, until the frame path settles on
/// the one asked for.
///
/// Bounded and not immediate on purpose: the optional pipeline is built off the
/// frame thread, so the frame that adopts it is the first one after the build
/// came back rather than the first one after the setting changed. That is the
/// behaviour, not a tolerance.
bool DrawUntilVideoPath(MetalRender& render, Scene& scene, SceneVideoPath wanted,
                        int frames = 64)
{
    for (int frame = 0; frame < frames; ++frame) {
        if (! render.drawFrame(scene)) return false;
        if (render.VideoPath() == wanted) return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    return false;
}

SceneMaterial* FirstMaterial(SceneNode* node)
{
    if (node == nullptr) return nullptr;
    if (auto* mesh = node->Mesh(); mesh != nullptr && mesh->MaterialForSlot(0) != nullptr) {
        return mesh->MaterialForSlot(0);
    }
    for (const auto& child : node->GetChildren()) {
        if (auto* found = FirstMaterial(child.get()); found != nullptr) return found;
    }
    return nullptr;
}

class MetalSceneDraw : public ::testing::Test {
protected:
    void SetUp() override
    {
        if (! MetalDeviceAvailable()) {
            GTEST_SKIP() << "no Metal device on this machine; the native draw was not exercised";
        }
        root_ = std::filesystem::temp_directory_path() /
                ("owe-metal-smoke-" + std::to_string(::getpid()));
        std::filesystem::remove_all(root_);
        std::filesystem::create_directories(root_);
        SetSceneRendererPreference(SceneRendererPreference::NativeMetalPreferred);
        ForgetMetalPrepareFailures();
    }

    void TearDown() override
    {
        SetSceneRendererPreference(SceneRendererPreference::Compatibility);
        ForgetMetalPrepareFailures();
        std::error_code ignored;
        std::filesystem::remove_all(root_, ignored);
    }

    std::filesystem::path root_;
};

// Entirely original shaders behind the ordinary authored material/effect
// interfaces. The HDR combo changes emitted radiance, an effect halves it, and
// two layer-as-texture consumers carry that result into the scene and bloom.
std::filesystem::path WriteParsedRadianceFixture(const std::filesystem::path& root, bool hdr)
{
    const auto project = WriteFixture(root);
    const std::string vertex =
        "uniform mat4 g_ModelViewProjectionMatrix;\n"
        "attribute vec3 a_Position;\nattribute vec2 a_TexCoord;\n"
        "varying vec2 v_TexCoord;\n"
        "void main(){ gl_Position=g_ModelViewProjectionMatrix*vec4(a_Position,1.0);"
        "v_TexCoord=a_TexCoord; }\n";
    const std::string sample =
        "uniform sampler2D g_Texture0;\nvarying vec2 v_TexCoord;\n"
        "void main(){ gl_FragColor=texture(g_Texture0,v_TexCoord); }\n";
    const std::string combine =
        "uniform sampler2D g_Texture0;\nuniform sampler2D g_Texture1;\n"
        "varying vec2 v_TexCoord;\nvoid main(){"
        "gl_FragColor=vec4(texture(g_Texture0,v_TexCoord).rgb+"
        "texture(g_Texture1,v_TexCoord).rgb,1.0); }\n";
    const std::string extract =
        "uniform sampler2D g_Texture0;\n"
        "uniform float g_BloomStrength; // {\"material\":\"bloomstrength\",\"default\":1.0}\n"
        "uniform vec4 g_BloomBlendParams;\n"
        "uniform vec3 g_BloomTint; // {\"material\":\"bloomtint\",\"default\":\"1 1 1\"}\n"
        "varying vec2 v_TexCoord;\n"
        "vec3 bright(vec2 uv){ return max(texture(g_Texture0,uv).rgb-"
        "vec3(g_BloomBlendParams.x),vec3(0.0)); }\n"
        "void main(){ gl_FragColor=vec4((bright(v_TexCoord)+"
        "bright(v_TexCoord+vec2(-0.125,0.0))+"
        "bright(v_TexCoord+vec2(0.125,0.0)))*"
        "(g_BloomStrength/3.0)*g_BloomTint,1.0); }\n";
    const std::map<std::string, std::string> fragments {
        { "parsed_emitter",
          "uniform sampler2D g_Texture2; // {\"combo\":\"MASKS\",\"components\":[{\"combo\":\"M0\"},{\"combo\":\"M1\"},{\"combo\":\"M2\"},{\"combo\":\"EMISSIVE_MAP\"}]}\n"
          "varying vec2 v_TexCoord;\nvoid main(){\n#if HDR && EMISSIVE_MAP\n"
          "float radiance=4.0*texture(g_Texture2,v_TexCoord).a;\n#else\nfloat radiance=0.5;\n#endif\n"
          "gl_FragColor=vec4(v_TexCoord.x<0.5?radiance:0.0,0.0,0.0,1.0); }\n" },
        { "parsed_effect", "uniform sampler2D g_Texture0;\nvarying vec2 v_TexCoord;\n"
          "void main(){ gl_FragColor=vec4(texture(g_Texture0,v_TexCoord).rgb*0.5,1.0); }\n" },
        { "parsed_sample", sample },
        { "parsed_extract", extract },
        { "parsed_upsample",
          "uniform sampler2D g_Texture0;\nuniform float g_BloomScatter;\n"
          "varying vec2 v_TexCoord;\nvoid main(){"
          "gl_FragColor=vec4(texture(g_Texture0,v_TexCoord).rgb*g_BloomScatter,1.0); }\n" },
        { "parsed_combine", combine },
        { "parsed_ldr_extract",
          "uniform sampler2D g_Texture0;\n"
          "uniform float g_BloomStrength; // {\"material\":\"bloomstrength\",\"default\":1.0}\n"
          "uniform float g_BloomThreshold; // {\"material\":\"bloomthreshold\",\"default\":0.0}\n"
          "varying vec2 v_TexCoord;\nvoid main(){"
          "gl_FragColor=vec4(max(texture(g_Texture0,v_TexCoord).rgb-"
          "vec3(g_BloomThreshold),vec3(0.0))*g_BloomStrength,1.0); }\n" },
    };
    for (const auto& [name, fragment] : fragments) {
        std::ofstream(root / ("shaders/" + name + ".vert")) << vertex;
        std::ofstream(root / ("shaders/" + name + ".frag")) << fragment;
    }
    const auto material = [&](std::string_view path, std::string_view shader,
                              const nlohmann::json& textures, bool additive = false) {
        nlohmann::json pass {
            { "shader", shader }, { "textures", textures },
            { "blending", additive ? "additive" : "normal" }, { "cullmode", "nocull" },
            { "depthtest", "disabled" }, { "depthwrite", "disabled" },
        };
        const auto destination = root / path;
        std::filesystem::create_directories(destination.parent_path());
        std::ofstream(destination) << nlohmann::json {
            { "passes", nlohmann::json::array({ pass }) },
        };
    };
    {
        std::ofstream texture(root / "materials/emissive.tex", std::ios::binary);
        const auto u32 = [&](uint32_t value) {
            const char bytes[] { char(value), char(value >> 8), char(value >> 16), char(value >> 24) };
            texture.write(bytes, sizeof(bytes));
        };
        texture.write("TEXV0005", 9);
        texture.write("TEXI0001", 9);
        u32(0); u32(1u << 23);
        for (int i = 0; i < 4; ++i) u32(1);
        u32(0);
        texture.write("TEXB0002", 9);
        u32(1); u32(1); u32(1); u32(1); u32(0); u32(0); u32(4);
        const char rgba[] {0, 0, 0, char(255)};
        texture.write(rgba, sizeof(rgba));
    }
    material("materials/emitter.json", "parsed_emitter", {nullptr, nullptr, "emissive"});
    material("materials/effect.json", "parsed_effect", { nullptr });
    material("materials/relay.json", "parsed_sample", { "_rt_imageLayerComposite_1_a" });
    material("materials/consumer.json", "parsed_sample", { "_rt_imageLayerComposite_2_a" });
    for (const auto* name : { "emitter", "relay", "consumer" }) {
        std::ofstream(root / ("models/" + std::string(name) + ".json"))
            << nlohmann::json { { "width", 384 }, { "height", 256 },
                { "material", "materials/" + std::string(name) + ".json" } };
    }
    std::filesystem::create_directories(root / "effects");
    std::ofstream(root / "effects/half.json")
        << R"({"name":"halve radiance","passes":[{"material":"materials/effect.json","bind":[{"name":"previous","index":0}]}]})";
    material("materials/util/hdr_downsample_bloom.json", "parsed_extract", { "_rt_default" });
    material("materials/util/hdr_downsample.json", "parsed_sample", { "_rt_default" });
    material("materials/util/hdr_upsample.json", "parsed_upsample", { "_rt_default" }, true);
    material("materials/util/combine_hdr_upsample_linear.json", "parsed_combine",
             { "_rt_default", "_rt_default" });
    material("materials/util/downsample_quarter_bloom.json", "parsed_ldr_extract", { "_rt_default" });
    material("materials/util/downsample_eighth_blur_v.json", "parsed_sample", { "_rt_bloom_mip1" });
    material("materials/util/blur_h_bloom.json", "parsed_sample", { "_rt_bloom_mip2" });
    material("materials/util/combine_ldr.json", "parsed_combine", { "_rt_default", "_rt_bloom_mip1" });

    std::ifstream source(root / "layout.json");
    auto layout = nlohmann::json::parse(source);
    auto& general = layout["general"];
    general["hdr"] = hdr;
    general["bloom"] = true;
    general["bloomstrength"] = 1.0;
    general["bloomthreshold"] = 0.25;
    general["bloomtint"] = { 1.0, 1.0, 1.0 };
    general["bloomhdrstrength"] = 1.0;
    general["bloomhdrthreshold"] = 0.25;
    general["bloomhdrfeather"] = 0.0;
    general["bloomhdriterations"] = 2;
    general["bloomhdrscatter"] = 0.25;
    layout["objects"] = nlohmann::json::array();
    for (const auto& [id, name] : std::array<std::pair<int, const char*>, 3> {
             std::pair { 1, "emitter" }, { 2, "relay" }, { 3, "consumer" } }) {
        nlohmann::json object {
            { "id", id }, { "name", name }, { "image", "models/" + std::string(name) + ".json" },
            { "origin", { 192, 128, 0 } }, { "scale", { 1, 1, 1 } },
            { "angles", { 0, 0, 0 } }, { "visible", id == 3 },
        };
        if (id > 1) object["dependencies"] = { id - 1 };
        if (id == 1)
            object["effects"] = nlohmann::json::array({
                { { "file", "effects/half.json" }, { "visible", true } },
            });
        layout["objects"].push_back(std::move(object));
    }
    std::ofstream(root / "layout.json") << layout;
    return project;
}

} // namespace

TEST_F(MetalSceneDraw, ParsedHdrRadianceSurvivesEffectsLayerLinksAndBloom)
{
    // The last case exercises graph-created composite metadata as well as the
    // parser-created targets. No hand-built passes or target format overrides.
    for (const auto& [hdr, synthesize_composite] :
         std::array<std::pair<bool, bool>, 3> {
             std::pair { false, false }, { true, false }, { true, true } }) {
        SCOPED_TRACE(hdr ? (synthesize_composite ? "HDR graph composite" : "HDR") : "SDR");
        const auto directory = root_ /
            (hdr ? (synthesize_composite ? "hdr-synthesized" : "hdr") : "sdr");
        const auto project = WriteParsedRadianceFixture(directory, hdr);
        LoadedScene loaded;
        std::string error;
        ASSERT_TRUE(LoadScene(project, directory / "cache", loaded, error)) << error;
        auto& scene = *loaded.scene;
        ASSERT_TRUE(scene.layer_texture_error.empty()) << scene.layer_texture_error;
        const auto find_emitter = [](auto&& self, SceneNode* node) -> SceneNode* {
            if (node->Name() == "emitter" && node->HasMaterial()) return node;
            for (const auto& child : node->GetChildren()) {
                if (auto* found = self(self, child.get())) return found;
            }
            return nullptr;
        };
        auto* emitter = find_emitter(find_emitter, scene.sceneGraph.get());
        ASSERT_NE(emitter, nullptr);
        const auto camera = scene.cameras.find(emitter->Camera());
        ASSERT_NE(camera, scene.cameras.end());
        ASSERT_TRUE(camera->second->HasImgEffect());
        const auto effect_input = scene.ResolveRenderTargetName(
            camera->second->GetImgEffect()->FirstTarget());
        if (synthesize_composite) scene.renderTargets.erase(LayerCompositeTargetKey(2));
        const auto graph = sceneToRenderGraph(scene);
        ASSERT_NE(graph, nullptr);

        @autoreleasepool {
            CAMetalLayer* layer = [CAMetalLayer layer];
            layer.device = MTLCreateSystemDefaultDevice();
            layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
            layer.drawableSize = CGSizeMake(384, 256);
            MetalRender render;
            ASSERT_TRUE(render.init(MetalRenderInitInfo {
                .metal_layer = (__bridge void*)layer, .width = 384, .height = 256,
                .render_width = 384, .render_height = 256, .display_scale_factor = 1.0,
            }));
            ASSERT_TRUE(render.compileRenderGraph(scene, *graph)) << render.lastError();
            ASSERT_TRUE(render.drawFrame(scene)) << render.lastError();
            const auto expect_radiance = [&](const std::string& key, float expected) {
                std::vector<uint8_t> bytes;
                std::vector<float> radiance;
                uint32_t width = 0, height = 0;
                ASSERT_TRUE(render.ReadRenderTargetForTests(key, bytes, width, height, &radiance))
                    << key;
                ASSERT_EQ(width, 384u) << key;
                ASSERT_EQ(height, 256u) << key;
                EXPECT_NEAR(radiance[(128u * width + 96u) * 4], expected, 0.005f) << key;
                const auto* target = scene.FindRenderTarget(key);
                ASSERT_NE(target, nullptr);
                EXPECT_EQ(target->format, hdr ? TextureFormat::RGBA16F : TextureFormat::RGBA8)
                    << key;
            };
            expect_radiance(effect_input, hdr ? 4.0f : 0.5f);
            expect_radiance(GenLinkTex(1), hdr ? 2.0f : 0.25f);
            expect_radiance(LayerCompositeTargetKey(2), hdr ? 2.0f : 0.25f);
            expect_radiance(GenLinkTex(2), hdr ? 2.0f : 0.25f);

            std::vector<uint8_t> bytes;
            std::vector<float> radiance;
            uint32_t width = 0, height = 0;
            for (const auto& key : { std::string(SpecTex_Default), std::string("_rt_bloom_combine"),
                    std::string(hdr ? "_rt_hdr_bloom_0" : "_rt_bloom_mip1") }) {
                const auto* target = scene.FindRenderTarget(key);
                ASSERT_NE(target, nullptr) << key;
                EXPECT_EQ(target->format, hdr ? TextureFormat::RGBA16F : TextureFormat::RGBA8)
                    << key;
            }
            ASSERT_TRUE(render.ReadRenderTargetForTests(
                hdr ? "_rt_hdr_bloom_0" : "_rt_bloom_mip1", bytes, width, height, &radiance));
            const size_t bloom_left = ((height / 2) * width + width / 4) * 4;
            if (hdr) EXPECT_GT(radiance[bloom_left], 1.0f);
            else EXPECT_NEAR(radiance[bloom_left], 0.0f, 0.005f);
            ASSERT_TRUE(render.ReadRenderTargetForTests(
                scene.ResolveRenderTargetName(SpecTex_Default), bytes, width, height, &radiance));
            ASSERT_EQ(width, 384u);
            ASSERT_EQ(height, 256u);
            const size_t left = (128u * width + 96u) * 4;
            const size_t halo = (128u * width + 216u) * 4;
            const size_t dark = (128u * width + 336u) * 4;
            if (hdr) {
                EXPECT_GT(radiance[left], 2.0f);
                EXPECT_GT(radiance[halo], 0.1f);
                EXPECT_GT(bytes[halo], 25u);
            } else {
                EXPECT_NEAR(radiance[left], 0.25f, 0.005f);
                EXPECT_NEAR(bytes[left], 64, 1);
                EXPECT_EQ(bytes[halo], 0u);
            }
            EXPECT_NEAR(radiance[dark], 0.0f, 0.005f);
            render.destroy();
        }
    }
}

TEST_F(MetalSceneDraw, HdrSpreadPreservesEnergyAndStrengthScalesTheHalo)
{
    const auto directory = root_ / "bounded-bloom";
    const auto project = WriteParsedRadianceFixture(directory, true);
    std::ofstream(project) <<
        R"({"title":"Bounded bloom","type":"scene","file":"layout.json","general":{"properties":)"
        R"({"strength":{"type":"slider","value":1},"spread":{"type":"slider","value":0}}}})";
    // A coarse kernel with known reach distinguishes spreading from gain.
    std::ofstream(directory / "shaders/parsed_upsample.frag") <<
        "uniform sampler2D g_Texture0;\nuniform float g_BloomScatter;\n"
        "varying vec2 v_TexCoord;\nvoid main(){\n"
        "gl_FragColor=vec4(texture(g_Texture0,v_TexCoord-vec2(0.125,0)).rgb"
        "*g_BloomScatter,1); }\n";
    {
        std::ifstream input(directory / "layout.json");
        auto layout = nlohmann::json::parse(input);
        layout["general"]["bloomhdrstrength"] = {{"user", "strength"}, {"value", 1.0}};
        layout["general"]["bloomhdrscatter"] = {{"user", "spread"}, {"value", 0.0}};
        std::ofstream(directory / "layout.json") << layout;
    }
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, directory / "cache", loaded, error)) << error;
    auto& scene = *loaded.scene;
    const auto graph = sceneToRenderGraph(scene);
    ASSERT_NE(graph, nullptr);
    @autoreleasepool {
        CAMetalLayer* layer = [CAMetalLayer layer];
        layer.device = MTLCreateSystemDefaultDevice();
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize = CGSizeMake(384, 256);
        MetalRender render;
        ASSERT_TRUE(render.init(MetalRenderInitInfo {
            .metal_layer = (__bridge void*)layer, .width = 384, .height = 256,
            .render_width = 384, .render_height = 256, .display_scale_factor = 1.0,
        }));
        ASSERT_TRUE(render.compileRenderGraph(scene, *graph)) << render.lastError();
        const auto sample = [&](float strength, float spread, std::array<float, 2>& result) {
            scene.runtime->ApplyProjectPropertyOverride({
                {"strength", RuntimeScalarValue::Float(strength)},
                {"spread", RuntimeScalarValue::Float(spread)},
            });
            scene.runtime->Tick(1.0 / 60.0);
            ASSERT_TRUE(render.drawFrame(scene)) << render.lastError();
            std::vector<uint8_t> bytes;
            std::vector<float> radiance;
            uint32_t width = 0, height = 0;
            ASSERT_TRUE(render.ReadRenderTargetForTests(
                "_rt_hdr_bloom_0", bytes, width, height, &radiance));
            ASSERT_GT(width, 0u);
            result = {
                radiance[((height / 2) * width + width / 4) * 4],
                radiance[((height / 2) * width + width * 11 / 16) * 4],
            };
        };
        std::array<float, 2> narrow {}, wide {}, stronger {}, extreme {}, off {};
        sample(1.0f, 0.0f, narrow);
        sample(1.0f, 4.0f, wide);
        EXPECT_NEAR(narrow[0], 1.75f, 0.005f); // Constant field above the .25 threshold.
        EXPECT_NEAR(wide[0], narrow[0], 0.005f);
        EXPECT_NEAR(narrow[1], 0.0f, 0.005f);
        EXPECT_GT(wide[1], narrow[1] + 0.02f); // Spread moves energy beyond the source.
        sample(2.0f, 4.0f, stronger);
        for (int i = 0; i < 2; ++i) EXPECT_NEAR(stronger[i], 2 * wide[i], 0.01f);
        sample(1.0f, 1.0e6f, extreme);
        EXPECT_NEAR(extreme[0], narrow[0], 0.005f);
        EXPECT_LT(extreme[1], extreme[0]);
        sample(0.0f, 4.0f, off);
        for (float value : off) EXPECT_FLOAT_EQ(value, 0.0f);
        render.destroy();
    }
}

TEST_F(MetalSceneDraw, ParsedHdrMissingLayerSourceRetainsBackendRejection)
{
    const auto directory = root_ / "missing-hdr-source";
    const auto project = WriteParsedRadianceFixture(directory, true);
    std::ifstream source(directory / "layout.json");
    auto layout = nlohmann::json::parse(source);
    layout["objects"].erase(layout["objects"].begin());
    std::ofstream(directory / "layout.json") << layout;
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, directory / "cache", loaded, error)) << error;
    ASSERT_FALSE(loaded.scene->layer_texture_error.empty());
    EXPECT_EQ(SelectSceneBackend(*loaded.scene).backend, SceneBackend::LegacyVulkan);
}

namespace
{

/// A compose layer covering the canvas over one child: a 64x32 card of one
/// colour in its middle. The compose layer's effect samples that child as a
/// layer texture and shows it with red and blue swapped wherever the child
/// itself is not part of the compose layer's picture.
std::filesystem::path WriteComposePaletteFixture(const std::filesystem::path& root)
{
    const auto project = WriteFixture(root);
    const std::string vertex =
        "uniform mat4 g_ModelViewProjectionMatrix;\n"
        "attribute vec3 a_Position;\nattribute vec2 a_TexCoord;\n"
        "varying vec2 v_TexCoord;\n"
        "void main(){ gl_Position=g_ModelViewProjectionMatrix*vec4(a_Position,1.0);"
        "v_TexCoord=a_TexCoord; }\n";
    const std::map<std::string, std::string> files {
        { "models/util/composelayer.json",
          R"({"passthrough":true,"material":"materials/util/composelayer.json"})" },
        { "materials/util/composelayer.json",
          R"({"passes":[{"shader":"palette_sample","blending":"translucent","cullmode":"nocull",)"
          R"("depthtest":"disabled","depthwrite":"disabled","textures":["_rt_FullFrameBuffer"]}]})" },
        { "models/palette.json", R"({"width":64,"height":32,"material":"materials/palette.json"})" },
        { "materials/palette.json",
          R"({"passes":[{"shader":"palette_fill","blending":"translucent","cullmode":"nocull",)"
          R"("depthtest":"disabled","depthwrite":"disabled"}]})" },
        { "effects/swap/effect.json",
          R"({"name":"swap","passes":[{"material":"materials/swap.json"}]})" },
        { "materials/swap.json",
          R"({"passes":[{"shader":"palette_swap","blending":"translucent","cullmode":"nocull",)"
          R"("depthtest":"disabled","depthwrite":"disabled","textures":[null,null]}]})" },
        { "shaders/palette_sample.vert", vertex },
        { "shaders/palette_sample.frag",
          "uniform sampler2D g_Texture0;\nvarying vec2 v_TexCoord;\n"
          "void main(){ gl_FragColor=texture(g_Texture0,v_TexCoord); }\n" },
        { "shaders/palette_fill.vert", vertex },
        { "shaders/palette_fill.frag",
          "varying vec2 v_TexCoord;\n"
          "void main(){ gl_FragColor=vec4(0.25,0.5,0.75,1.0); }\n" },
        { "shaders/palette_swap.vert", vertex },
        { "shaders/palette_swap.frag",
          "uniform sampler2D g_Texture0;\nuniform sampler2D g_Texture1;\n"
          "varying vec2 v_TexCoord;\nvoid main(){\n"
          "vec4 picture=texture(g_Texture0,v_TexCoord);\n"
          "vec3 palette=texture(g_Texture1,v_TexCoord).bgr;\n"
          "gl_FragColor=vec4(mix(palette,picture.rgb,picture.a),1.0); }\n" },
        { "layout.json",
          R"({"camera":{"center":[0,0,0],"eye":[0,0,1],"up":[0,1,0]},)"
          R"("general":{"ambientcolor":[0,0,0],"skylightcolor":[0,0,0],"clearcolor":[0.0,0.0,0.0],)"
          R"("cameraparallax":false,"orthogonalprojection":{"width":384,"height":256}},)"
          R"("objects":[{"id":1,"name":"container","image":"models/util/composelayer.json",)"
          R"("size":[384,256],"origin":[192,128,0],"copybackground":false,"dependencies":[2],)"
          R"("effects":[{"file":"effects/swap/effect.json","visible":true,)"
          R"("passes":[{"textures":[null,"_rt_imageLayerComposite_2_a"]}]}]},)"
          R"({"id":2,"name":"palette","parent":1,"image":"models/palette.json",)"
          R"("origin":[0,0,0],"visible":true}]})" },
    };
    for (const auto& [name, contents] : files) {
        const auto path = root / name;
        std::filesystem::create_directories(path.parent_path());
        std::ofstream(path) << contents;
    }
    return project;
}

} // namespace

// A compose layer's effect sampling the layer's own child found no composite
// of it: the child was drawn only into the compose layer's target, so the
// effect's input stayed empty and the native backend could not draw it.
TEST_F(MetalSceneDraw, AComposeLayersEffectSamplesItsOwnChild)
{
    const auto  directory = root_ / "compose-palette";
    const auto  project   = WriteComposePaletteFixture(directory);
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, directory / "cache", loaded, error)) << error;
    auto& scene = *loaded.scene;
    ASSERT_TRUE(scene.layer_texture_error.empty()) << scene.layer_texture_error;
    const auto selection = SelectSceneBackend(scene);
    ASSERT_EQ(selection.backend, SceneBackend::NativeMetal) << selection.fallback_reason;
    const auto graph = sceneToRenderGraph(scene);
    ASSERT_NE(graph, nullptr);

    @autoreleasepool {
        CAMetalLayer* layer = [CAMetalLayer layer];
        layer.device        = MTLCreateSystemDefaultDevice();
        layer.pixelFormat   = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize  = CGSizeMake(384, 256);
        MetalRender render;
        ASSERT_TRUE(render.init(MetalRenderInitInfo {
            .metal_layer = (__bridge void*)layer, .width = 384, .height = 256,
            .render_width = 384, .render_height = 256, .display_scale_factor = 1.0,
        }));
        ASSERT_TRUE(render.compileRenderGraph(scene, *graph)) << render.lastError();
        ASSERT_TRUE(render.drawFrame(scene)) << render.lastError();
        std::vector<uint8_t> bytes;
        std::vector<float>   radiance;
        uint32_t             width = 0, height = 0;
        ASSERT_TRUE(render.ReadRenderTargetForTests(
            scene.ResolveRenderTargetName(SpecTex_Default), bytes, width, height, &radiance));
        ASSERT_EQ(width, 384u);
        ASSERT_EQ(height, 256u);
        const auto expect_color = [&](uint32_t x, uint32_t y, std::array<float, 3> expected) {
            const size_t pixel = (y * width + x) * 4;
            for (size_t channel = 0; channel < 3; ++channel) {
                EXPECT_NEAR(radiance[pixel + channel], expected[channel], 0.01f)
                    << "pixel " << x << "," << y << " channel " << channel;
            }
        };
        // The child where it sits in the compose layer's picture...
        expect_color(192, 128, { 0.25f, 0.5f, 0.75f });
        // ...and, everywhere else, the effect's view of the child's own card.
        expect_color(32, 32, { 0.75f, 0.5f, 0.25f });
        expect_color(352, 224, { 0.75f, 0.5f, 0.25f });
        render.destroy();
    }
}

TEST_F(MetalSceneDraw, TranslatedAuthorShaderCompilesAndDrawsTheScene)
{
    const auto project = WriteFixture(root_ / "project");
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "cache", loaded, error)) << error;

    // ---- 1. the parser produced a translation at all
    auto* material = FirstMaterial(loaded.scene->sceneGraph.get());
    ASSERT_NE(material, nullptr);
    ASSERT_NE(material->customShader.shader, nullptr);
    const auto* program = material->customShader.shader->metal_program.get();
    ASSERT_NE(program, nullptr) << "the parser hook did not run with the native preference on";
    ASSERT_TRUE(program->error.empty()) << "metal translation failed: " << program->error;
    ASSERT_FALSE(program->stages.empty());

    // ---- 2. the Metal compiler accepts it
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        ASSERT_NE(device, nil);
        for (const auto& stage : program->stages) {
            EXPECT_EQ(stage.entry_point, "main_")
                << "the backend reads the entry point from the stage, so this is a contract check";
            NSError*  compile_error = nil;
            NSString* source = [NSString stringWithUTF8String:stage.source.c_str()];
            id<MTLLibrary> library = [device newLibraryWithSource:source
                                                          options:[MTLCompileOptions new]
                                                            error:&compile_error];
            ASSERT_NE(library, nil)
                << "Metal refused the translated shader: "
                << (compile_error != nil ? compile_error.localizedDescription.UTF8String
                                         : "unknown error")
                << "\n----- generated MSL -----\n"
                << stage.source;
            NSString* entry = [NSString stringWithUTF8String:stage.entry_point.c_str()];
            EXPECT_NE([library newFunctionWithName:entry], nil)
                << "no function named " << stage.entry_point;
        }
    }

    // ---- 3. the gate accepts the scene
    const auto selection = SelectSceneBackend(*loaded.scene);
    ASSERT_EQ(selection.backend, SceneBackend::NativeMetal) << selection.fallback_reason;

    // ---- 4. a real frame, drawn by render command encoders
    @autoreleasepool {
        id<MTLDevice>  device = MTLCreateSystemDefaultDevice();
        CAMetalLayer*  layer  = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(384, 256);
        layer.framebufferOnly = NO;

        MetalRender  render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 384,
            .height               = 256,
            .render_width         = 384,
            .render_height        = 256,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();

        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        const uint32_t before_compile = render.ShaderUpdateDemandReasons();
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
        render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);

        // Zero means "provably still", which is what lets on-demand updating
        // stop this scene's clock. It must therefore be DERIVED, never the
        // value left over when the analysis found nothing to look at.
        //
        // This fixture's shader binds no frame-varying uniform, so zero is the
        // right answer for it -- which is exactly why asserting only that is
        // worthless. The assertion that carries weight is the one above it: a
        // renderer whose graph has not been analysed must report
        // `UnknownInput`, because a caller must never be able to mistake "not
        // asked yet" for "nothing changes".
        EXPECT_TRUE(before_compile & wallpaper::vulkan::DynamicReason::UnknownInput)
            << "an unanalysed renderer reported " << before_compile
            << ", which a caller would read as a still scene";
        const uint32_t reasons = render.ShaderUpdateDemandReasons();
        EXPECT_EQ(reasons, 0u) << "reported reasons: " << reasons;

        for (int frame = 0; frame < 3; ++frame) {
            ASSERT_TRUE(render.drawFrame(*loaded.scene)) << render.lastError();
            loaded.scene->PassFrameTime(1.0 / 60.0);
        }

        std::vector<uint8_t> pixels;
        uint32_t             width = 0;
        uint32_t             height = 0;
        ASSERT_TRUE(render.ReadRenderTargetForTests(
            loaded.scene->ResolveRenderTargetName(SpecTex_Default), pixels, width, height));
        ASSERT_EQ(width, 384u);
        ASSERT_EQ(height, 256u);
        ASSERT_EQ(pixels.size(), width * height * 4u);

        // The author's fragment shader writes vec4(u, v, 0.25, 1). The scene
        // clears to black, so any pixel with a blue channel near 0.25 and a
        // non-zero red or green can only have come from that shader running.
        std::size_t shader_pixels = 0;
        for (std::size_t i = 0; i < pixels.size(); i += 4) {
            const auto r = pixels[i];
            const auto g = pixels[i + 1];
            const auto b = pixels[i + 2];
            if (b >= 55 && b <= 73 && (r > 8 || g > 8)) ++shader_pixels;
        }
        EXPECT_GT(shader_pixels, 1000u)
            << "the target holds no pixels the author's fragment shader could have produced";

        render.destroy();
    }
}

TEST_F(MetalSceneDraw, MatrixInversesOfEverySizeAreTranslatedAndDrawnExactly)
{
    // Naga's MSL writer has no `inverse`, so a stage that inverts a matrix --
    // the stock perspective-warping effects undo `squareToQuad` in the vertex
    // stage -- failed to translate and was dropped by this backend. Each size
    // undoes its own matrix here and the residual is drawn a hundredfold: the
    // card stays white only if every inverse is right, and one wrong cofactor
    // sign drives its channel to black.
    const auto directory = root_ / "inverse";
    const auto project = WriteFixture(directory);
    std::ofstream(directory / "shaders/metal_probe.vert") << R"(
uniform mat4 g_ModelViewProjectionMatrix;
attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying float v_Residual3;
void main() {
    mat3 warp = mat3(1.5, 0.25, 0.125, -0.5, 1.25, 0.375, 0.75, -0.25, 1.0);
    vec3 a = vec3(0.3, -0.6, 0.9);
    v_Residual3 = distance(inverse(warp) * (warp * a), a);
    gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);
}
)";
    std::ofstream(directory / "shaders/metal_probe.frag") << R"(
varying float v_Residual3;
void main() {
    mat2 shear = mat2(1.25, -0.5, 0.75, 1.5);
    mat4 frame = mat4(2.0, 0.25, -0.5, 0.125, 0.5, 1.5, 0.25, -0.25,
                      -0.375, 0.5, 1.25, 0.5, 0.25, -0.75, 0.5, 1.0);
    vec2 a = vec2(0.4, -0.7);
    vec4 b = vec4(-0.2, 0.5, 0.8, -0.9);
    float residual2 = distance(inverse(shear) * (shear * a), a);
    float residual4 = distance(inverse(frame) * (frame * b), b);
    gl_FragColor = vec4(vec3(1.0) - 100.0 * vec3(residual2, v_Residual3, residual4), 1.0);
}
)";
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "inverse-cache", loaded, error)) << error;
    auto* material = FirstMaterial(loaded.scene->sceneGraph.get());
    ASSERT_NE(material, nullptr);
    ASSERT_NE(material->customShader.shader, nullptr);
    const auto* program = material->customShader.shader->metal_program.get();
    ASSERT_NE(program, nullptr);
    ASSERT_TRUE(program->error.empty()) << "metal translation failed: " << program->error;
    const auto selection = SelectSceneBackend(*loaded.scene);
    ASSERT_EQ(selection.backend, SceneBackend::NativeMetal) << selection.fallback_reason;

    @autoreleasepool {
        CAMetalLayer* layer = [CAMetalLayer layer];
        layer.device        = MTLCreateSystemDefaultDevice();
        layer.pixelFormat   = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize  = CGSizeMake(384, 256);
        MetalRender render;
        ASSERT_TRUE(render.init(MetalRenderInitInfo {
            .metal_layer = (__bridge void*)layer, .width = 384, .height = 256,
            .render_width = 384, .render_height = 256, .display_scale_factor = 1.0,
        }));
        const auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
        ASSERT_TRUE(render.drawFrame(*loaded.scene)) << render.lastError();
        std::vector<uint8_t> pixels;
        uint32_t width = 0, height = 0;
        ASSERT_TRUE(render.ReadRenderTargetForTests(
            loaded.scene->ResolveRenderTargetName(SpecTex_Default), pixels, width, height));
        ASSERT_GT(width, 0u);
        ASSERT_GT(height, 0u);
        const auto offset = ((height / 2) * width + width / 2) * 4;
        EXPECT_GE(pixels[offset + 0], 250u) << "mat2 inverse is wrong";
        EXPECT_GE(pixels[offset + 1], 250u) << "mat3 inverse is wrong";
        EXPECT_GE(pixels[offset + 2], 250u) << "mat4 inverse is wrong";
        render.destroy();
    }
}

TEST_F(MetalSceneDraw, SingleSampleAlphaCoveragePreservesTransparentAndPartialPixels)
{
    const auto project = WriteFixture(root_ / "coverage");
    std::ofstream(project.parent_path() / "materials/tile.json")
        << R"({"passes":[{"shader":"metal_probe","blending":"alphatocoverage","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled"}]})";
    std::ofstream(project.parent_path() / "shaders/metal_probe.frag")
        << "varying vec2 v_TexCoord;\nvoid main() {"
        << "gl_FragColor=vec4(1,0,0,floor(v_TexCoord.x*3.0)*0.5); }\n";
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "cache", loaded, error)) << error;
    @autoreleasepool {
        CAMetalLayer* layer = [CAMetalLayer layer];
        layer.device = MTLCreateSystemDefaultDevice();
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize = CGSizeMake(384, 256);
        MetalRender render;
        ASSERT_TRUE(render.init({
            .metal_layer = (__bridge void*)layer, .width = 384, .height = 256,
            .render_width = 384, .render_height = 256, .display_scale_factor = 1.0,
        })) << render.lastError();
        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
        render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);
        for (int frame = 0; frame < 3; ++frame) {
            ASSERT_TRUE(render.drawFrame(*loaded.scene)) << render.lastError();
            std::vector<uint8_t> pixels;
            uint32_t width = 0, height = 0;
            ASSERT_TRUE(render.ReadRenderTargetForTests(
                loaded.scene->ResolveRenderTargetName(SpecTex_Default), pixels, width, height));
            ASSERT_EQ(width, 384u);
            ASSERT_EQ(height, 256u);
            for (const auto& [x, red] : { std::pair {100, 0}, {192, 128}, {284, 255} }) {
                const auto offset = (128 * width + x) * 4;
                EXPECT_NEAR(pixels[offset], red, 1);
                EXPECT_EQ(pixels[offset + 1], 0);
                EXPECT_EQ(pixels[offset + 2], 0);
            }
        }
        render.destroy();
    }
}

TEST_F(MetalSceneDraw, UnreferencedTargetsStayUnallocatedAcrossOptimizationChanges)
{
    const auto project = WriteFixture(root_ / "project");
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "cache", loaded, error)) << error;
    loaded.scene->renderTargets["_rt_unused"] = SceneRenderTarget { .width = 128, .height = 128 };
    const bool optimization_was = wallpaper::vulkan::SceneOptimizationEnabled();
    struct Restore {
        bool value;
        ~Restore() { wallpaper::vulkan::SetSceneOptimizationEnabled(value); }
    } restore { optimization_was };
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer = [CAMetalLayer layer];
        layer.device = device;
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize = CGSizeMake(384, 256);
        MetalRender render;
        MetalRenderInitInfo info {
            .metal_layer = (__bridge void*)layer, .width = 384, .height = 256,
            .render_width = 384, .render_height = 256, .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info));
        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
        std::vector<uint8_t> reference;
        for (bool enabled : {true, false, true}) {
            wallpaper::vulkan::SetSceneOptimizationEnabled(enabled);
            ASSERT_TRUE(render.drawFrame(*loaded.scene)) << render.lastError();
            std::vector<uint8_t> pixels;
            uint32_t width = 0, height = 0;
            EXPECT_FALSE(render.ReadRenderTargetForTests("_rt_unused", pixels, width, height));
            ASSERT_TRUE(render.ReadRenderTargetForTests(
                loaded.scene->ResolveRenderTargetName(SpecTex_Default), pixels, width, height));
            if (reference.empty()) reference = pixels;
            else EXPECT_EQ(pixels, reference);
        }
        render.destroy();
    }
}

TEST_F(MetalSceneDraw, ACopySkippedByTheOptimisationGetsItsImageWhenItIsTurnedOff)
{
    // Nothing samples the copy's destination, so the plan drops the copy as
    // dead and the copy step is the only thing that names that image. Turning
    // the optimisation off makes the copy again, without recompiling, and it
    // must find an image to write into.
    const std::string output = std::string(SpecTex_Default);
    const std::string copy   = "_rt_dead_copy";
    const auto        project = WriteFixture(root_ / "project");
    LoadedScene       loaded;
    std::string       error;
    ASSERT_TRUE(LoadScene(project, root_ / "cache", loaded, error)) << error;
    SceneNode* tile = FirstDrawableNode(loaded.scene->sceneGraph.get());
    ASSERT_NE(tile, nullptr);
    struct Restore {
        bool value;
        ~Restore() { wallpaper::vulkan::SetSceneOptimizationEnabled(value); }
    } restore { wallpaper::vulkan::SceneOptimizationEnabled() };
    wallpaper::vulkan::SetSceneOptimizationEnabled(true);
    @autoreleasepool {
        CAMetalLayer* layer = [CAMetalLayer layer];
        layer.device = MTLCreateSystemDefaultDevice();
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize = CGSizeMake(384, 256);
        MetalRender render;
        MetalRenderInitInfo info {
            .metal_layer = (__bridge void*)layer, .width = 384, .height = 256,
            .render_width = 384, .render_height = 256, .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info));
        rg::RenderGraph graph;
        AddDraw(graph, tile, output, {});
        AddCopy(graph, output, copy);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, graph)) << render.lastError();
        for (bool enabled : { true, false, true }) {
            SCOPED_TRACE(enabled ? "optimised" : "every copy made");
            wallpaper::vulkan::SetSceneOptimizationEnabled(enabled);
            ASSERT_TRUE(render.drawFrame(*loaded.scene)) << render.lastError();
            // The saving is only real if the dead copy is not made while the
            // optimisation is on; with it off, the copy is the frame's one blit.
            EXPECT_EQ(render.LastFrameEncodeCountsForTests().blit_passes, enabled ? 0u : 1u);
            if (enabled) continue;
            std::vector<uint8_t> drawn, copied;
            uint32_t width = 0, height = 0;
            ASSERT_TRUE(render.ReadRenderTargetForTests(
                loaded.scene->ResolveRenderTargetName(output), drawn, width, height));
            ASSERT_TRUE(render.ReadRenderTargetForTests(copy, copied, width, height))
                << "the restored copy has no image to write into";
            EXPECT_EQ(copied, drawn);
        }
        render.destroy();
    }
}

TEST_F(MetalSceneDraw, LightingViewDirectionFollowsTheAuthoredSceneThroughEffects)
{
    // Original shaders reproduce the view-dependent lighting shape, without
    // private assets or the compatibility lighting helper. A 2D eye on the
    // layer's plane must not turn front-facing artwork into ambient-only RGB.
    for (bool ortho : { true, false }) {
        for (bool effect : { false, true }) {
            SCOPED_TRACE(std::string(ortho ? "2D" : "perspective") +
                         (effect ? " effect" : " direct"));
            const auto directory = root_ / (std::string(ortho ? "ortho" : "perspective") +
                                             (effect ? "-effect" : "-direct"));
            const auto project = WriteFixture(directory);
            const std::string vertex = R"(
attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
varying vec3 v_ViewDir;
void main() {
    gl_Position = vec4(a_TexCoord * 2.0 - 1.0, 0.0, 1.0);
    v_TexCoord = a_TexCoord;
    v_ViewDir = vec3(1.0, 0.0, 0.0);
}
)";
            const std::string lighting = R"(
#if SCENE_ORTHO
    vec3 view = vec3(0.0, 0.0, 1.0);
#else
    vec3 view = normalize(v_ViewDir);
#endif
    // The unlit half must retain its authored colour under either projection.
    if (v_TexCoord.x > 0.5)
        color.rgb *= 0.2 + 0.8 * max(dot(vec3(0.0, 0.0, 1.0), view), 0.0);
    gl_FragColor = color;
}
)";
            const std::string declarations =
                "varying vec2 v_TexCoord;\nvarying vec3 v_ViewDir;\n";
            std::ofstream(directory / "shaders/metal_probe.vert") << vertex;
            std::ofstream(directory / "shaders/metal_probe.frag") << declarations <<
                "void main() {\nvec4 color = vec4(0.25, 0.5, 0.75, 1.0);\n" <<
                (effect ? "gl_FragColor = color;\n}\n" : lighting);
            auto material = nlohmann::json::parse(
                std::ifstream(directory / "materials/tile.json"));
            // The scene owns this switch even if a stale material disagrees.
            material["passes"][0]["combos"]["SCENE_ORTHO"] = ortho ? 0 : 1;
            std::ofstream(directory / "materials/tile.json") << material;
            auto layout = nlohmann::json::parse(std::ifstream(directory / "layout.json"));
            if (! ortho) layout["general"]["orthogonalprojection"] = nullptr;
            if (effect) {
                std::filesystem::create_directories(directory / "effects");
                std::ofstream(directory / "effects/view.json") <<
                    R"({"name":"view lighting","passes":[{"material":"materials/view.json"}]})";
                material["passes"][0]["shader"] = "view";
                material["passes"][0]["textures"] = nlohmann::json::array({ nullptr });
                std::ofstream(directory / "materials/view.json") << material;
                std::ofstream(directory / "shaders/view.vert") << vertex;
                std::ofstream(directory / "shaders/view.frag") <<
                    "uniform sampler2D g_Texture0;\n" << declarations <<
                    "void main() {\nvec4 color = texture(g_Texture0, v_TexCoord);\n" << lighting;
                layout["objects"][0]["effects"] = nlohmann::json::array({
                    { { "file", "effects/view.json" }, { "visible", true } }
                });
            }
            std::ofstream(directory / "layout.json") << layout;
            LoadedScene loaded;
            std::string error;
            ASSERT_TRUE(LoadScene(project, directory / "cache", loaded, error)) << error;
            auto& scene = *loaded.scene;
            const auto graph = sceneToRenderGraph(scene);
            ASSERT_NE(graph, nullptr);
            @autoreleasepool {
                CAMetalLayer* layer = [CAMetalLayer layer];
                layer.device = MTLCreateSystemDefaultDevice();
                layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
                layer.drawableSize = CGSizeMake(384, 256);
                MetalRender render;
                ASSERT_TRUE(render.init(MetalRenderInitInfo {
                    .metal_layer = (__bridge void*)layer, .width = 384, .height = 256,
                    .render_width = 384, .render_height = 256, .display_scale_factor = 1.0,
                }));
                ASSERT_TRUE(render.compileRenderGraph(scene, *graph)) << render.lastError();
                ASSERT_TRUE(render.drawFrame(scene)) << render.lastError();
                std::vector<uint8_t> pixels;
                uint32_t width = 0, height = 0;
                ASSERT_TRUE(render.ReadRenderTargetForTests(
                    scene.ResolveRenderTargetName(SpecTex_Default), pixels, width, height));
                ASSERT_GT(width, 0u);
                ASSERT_GT(height, 0u);
                for (bool lit : { false, true }) {
                    const auto offset = ((height / 2) * width + width * (lit ? 3 : 1) / 4) * 4;
                    for (size_t channel = 0; channel < 3; ++channel) {
                        const float albedo = 0.25f * (channel + 1);
                        const float gain = lit && ! ortho ? 0.2f : 1.0f;
                        EXPECT_NEAR(pixels[offset + channel], 255.0f * albedo * gain, 1.0f);
                    }
                    EXPECT_EQ(pixels[offset + 3], 255u);
                }
                render.destroy();
            }
        }
    }
}

TEST_F(MetalSceneDraw, ParentedCardsStayJoinedWhileParallaxMovesAndReverses)
{
    for (bool effect : {false, true}) {
        SCOPED_TRACE(effect ? "effect chain" : "direct cards");
        const auto directory = root_ / (effect ? "parallax-effect" : "parallax-direct");
        const auto project = WriteFixture(directory);
        std::ofstream(directory / "models/tile.json") <<
            R"({"width":64,"height":64,"material":"materials/tile.json"})";
        std::ofstream(directory / "shaders/metal_probe.frag") <<
            "void main() { gl_FragColor = vec4(1.0, 0.0, 0.0, 1.0); }\n";
        auto layout = nlohmann::json::parse(std::ifstream(directory / "layout.json"));
        layout["general"]["clearcolor"] = {0, 0, 0};
        layout["general"]["cameraparallax"] = true;
        layout["general"]["cameraparallaxamount"] = 1;
        layout["general"]["cameraparallaxmouseinfluence"] = 1;
        layout["general"]["cameraparallaxdelay"] = 0;
        auto card = layout["objects"][0];
        card["id"] = 1;
        card["name"] = "left card";
        card["parent"] = 3;
        card["origin"] = {-32, 0, 0};
        if (effect) {
            std::filesystem::create_directories(directory / "effects");
            std::ofstream(directory / "effects/copy.json") <<
                R"({"name":"copy","passes":[{"material":"materials/copy.json"}]})";
            std::ofstream(directory / "materials/copy.json") <<
                R"({"passes":[{"shader":"copy","textures":[null],"blending":"normal","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled"}]})";
            std::filesystem::copy_file(directory / "shaders/metal_probe.vert",
                                       directory / "shaders/copy.vert");
            std::ofstream(directory / "shaders/copy.frag") <<
                "uniform sampler2D g_Texture0;\nvarying vec2 v_TexCoord;\n"
                "void main() { gl_FragColor = texture(g_Texture0, v_TexCoord); }\n";
            card["effects"] = nlohmann::json::array({{{"file", "effects/copy.json"}}});
        }
        auto right = card;
        right["id"] = 2;
        right["name"] = "right card";
        right["origin"] = {32, 0, 0};
        right["parallaxDepth"] = {9, -9}; // stale child values must not win
        layout["objects"] = nlohmann::json::array({card, right,
            {{"id", 3}, {"name", "inner"}, {"parent", 4}, {"parallaxDepth", {0, 0}}},
            {{"id", 4}, {"name", "root"}, {"origin", {192, 128, 0}},
             {"parallaxDepth", {0.5, 0.25}}}});
        std::ofstream(directory / "layout.json") << layout;
        LoadedScene loaded;
        std::string error;
        ASSERT_TRUE(LoadScene(project, directory / "cache", loaded, error)) << error;
        auto& scene = *loaded.scene;
        const auto graph = sceneToRenderGraph(scene);
        ASSERT_NE(graph, nullptr);
        @autoreleasepool {
            CAMetalLayer* layer = [CAMetalLayer layer];
            layer.device = MTLCreateSystemDefaultDevice();
            layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
            layer.drawableSize = CGSizeMake(384, 256);
            MetalRender render;
            ASSERT_TRUE(render.init(MetalRenderInitInfo {
                .metal_layer = (__bridge void*)layer, .width = 384, .height = 256,
                .render_width = 384, .render_height = 256, .display_scale_factor = 1.0,
            }));
            ASSERT_TRUE(render.compileRenderGraph(scene, *graph)) << render.lastError();
            // Include repeated frames: caching must not freeze inherited motion,
            // and local effect targets must not receive parallax a second time.
            for (float cursor : {0.5f, 1.0f, 1.0f, 0.0f, 0.0f, 0.5f}) {
                scene.shaderValueUpdater->MouseInput(cursor, 1.0f - cursor);
                // The host's per-frame step, which carries the cursor into
                // the smoothed position the parallax reads.
                scene.shaderValueUpdater->FrameBegin();
                ASSERT_TRUE(render.drawFrame(scene)) << render.lastError();
                std::vector<uint8_t> pixels;
                uint32_t width = 0, height = 0;
                ASSERT_TRUE(render.ReadRenderTargetForTests(
                    scene.ResolveRenderTargetName(SpecTex_Default), pixels, width, height));
                ASSERT_EQ(width, 384u);
                ASSERT_EQ(height, 256u);
                const float cx = 192 + (0.5f - cursor) * 192;
                const float cy = 128 - (0.5f - cursor) * 64; // readback is top-down
                for (unsigned y = 8; y < height; y += 16) {
                    for (unsigned x = 8; x < width; x += 16) {
                        const bool covered = std::abs(x - cx) < 64 && std::abs(y - cy) < 32;
                        const auto offset = (y * width + x) * 4;
                        ASSERT_EQ(pixels[offset], covered ? 255 : 0)
                            << "cursor=" << cursor << " pixel=" << x << "," << y;
                        ASSERT_EQ(pixels[offset + 1], 0);
                        ASSERT_EQ(pixels[offset + 2], 0);
                    }
                }
            }
            render.destroy();
        }
    }
}

TEST_F(MetalSceneDraw, AnAnimatedCurtainRevealsTheWholeCanvasAndStaysOpen)
{
    for (bool effect : { false, true }) {
        SCOPED_TRACE(effect ? "effect chain" : "direct layer");
        const auto directory = root_ / (effect ? "effect-curtain" : "direct-curtain");
        const auto project = WriteFixture(directory);
        std::ofstream(directory / "models/tile.json") <<
            R"({"width":192,"height":256,"material":"materials/tile.json"})";
        std::ofstream(directory / "shaders/metal_probe.frag") <<
            "void main() {\n gl_FragColor = vec4(0.0, 0.0, 0.0, 1.0);\n}\n";
        auto layout = nlohmann::json::parse(std::ifstream(directory / "layout.json"));
        layout["general"]["clearcolor"] = { 0.2, 0.4, 0.6 };
        auto& card = layout["objects"][0];
        card["alignment"] = "left";
        card["origin"] = nlohmann::json::parse(R"({
            "value":[192,128,0],"animation":{
                "relative":true,"options":{"fps":60,"length":30,"mode":"single"},
                "c0":[{"frame":0,"value":0},{"frame":30,"value":192}]
            }
        })");
        if (effect) {
            std::filesystem::create_directories(directory / "effects");
            std::ofstream(directory / "effects/copy.json") <<
                R"({"name":"copy","passes":[{"material":"materials/copy.json"}]})";
            std::ofstream(directory / "materials/copy.json") <<
                R"({"passes":[{"shader":"copy","textures":[null],"blending":"normal","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled"}]})";
            std::filesystem::copy_file(directory / "shaders/metal_probe.vert",
                                       directory / "shaders/copy.vert");
            std::ofstream(directory / "shaders/copy.frag") <<
                "uniform sampler2D g_Texture0;\nvarying vec2 v_TexCoord;\n"
                "void main() {\n gl_FragColor = texture(g_Texture0, v_TexCoord);\n}\n";
            card["effects"] = nlohmann::json::array({ { { "file", "effects/copy.json" } } });
        }
        std::ofstream(directory / "layout.json") << layout;
        LoadedScene loaded;
        std::string error;
        ASSERT_TRUE(LoadScene(project, directory / "cache", loaded, error)) << error;
        auto& scene = *loaded.scene;
        const auto graph = sceneToRenderGraph(scene);
        ASSERT_NE(graph, nullptr);
        @autoreleasepool {
            CAMetalLayer* layer = [CAMetalLayer layer];
            layer.device = MTLCreateSystemDefaultDevice();
            layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
            layer.drawableSize = CGSizeMake(384, 256);
            MetalRender render;
            ASSERT_TRUE(render.init(MetalRenderInitInfo {
                .metal_layer = (__bridge void*)layer, .width = 384, .height = 256,
                .render_width = 384, .render_height = 256, .display_scale_factor = 1.0,
            }));
            ASSERT_TRUE(render.compileRenderGraph(scene, *graph)) << render.lastError();
            double elapsed = 0.0;
            for (double delta : { 0.0, 0.25, 0.25, 5.0 }) {
                scene.runtime->Tick(delta);
                elapsed += delta;
                ASSERT_TRUE(render.drawFrame(scene)) << render.lastError();
                std::vector<uint8_t> pixels;
                uint32_t width = 0, height = 0;
                ASSERT_TRUE(render.ReadRenderTargetForTests(
                    scene.ResolveRenderTargetName(SpecTex_Default), pixels, width, height));
                ASSERT_EQ(width, 384u);
                ASSERT_EQ(height, 256u);
                for (unsigned x : { 48u, 224u, 336u }) {
                    const bool covered = x >= 192.0 + 384.0 * std::min(elapsed, 0.5);
                    const auto offset = ((height / 2) * width + x) * 4;
                    for (unsigned channel = 0; channel < 3; ++channel) {
                        EXPECT_NEAR(pixels[offset + channel],
                                    covered ? 0u : 51u * (channel + 1), 1u);
                    }
                }
            }
            render.destroy();
        }
    }
}

TEST_F(MetalSceneDraw, PuppetEffectsApplyLightingOnceAfterAssembly)
{
    // Original one-bone card and shaders exercise the real model parser and
    // effect-chain builder, not a hand-constructed approximation of the graph.
    for (bool puppet : { false, true }) {
        for (bool effect : { false, true }) {
            for (bool lit : { false, true }) {
                const std::string label = std::to_string(puppet) + std::to_string(effect) +
                                          std::to_string(lit);
                SCOPED_TRACE(label);
                const auto directory = root_ / ("puppet-lighting-" + label);
                const auto project = WriteFixture(directory);
                if (puppet) {
                    std::ofstream model(directory / "models/card.mdl", std::ios::binary);
                    const auto put = [&model](auto value) {
                        model.write(reinterpret_cast<const char*>(&value), sizeof(value));
                    };
                    const auto str = [&model](const char* value) {
                        model.write(value, std::strlen(value) + 1);
                    };
                    const uint32_t flags = 0x00800000u | 0x01000000u | 0x00000008u;
                    str("MDLV0021");
                    put(flags); put(uint32_t(1)); put(uint32_t(1));
                    str("materials/tile.json"); put(uint32_t(0));
                    for (float v : { -128.f, -96.f, 0.f, 128.f, 96.f, 0.f }) put(v);
                    put(flags); put(uint32_t(4 * 52));
                    for (const auto& vertex : std::array<std::array<float, 4>, 4> {{
                             { -128, -96, 0, 1 }, { 128, -96, 1, 1 },
                             { 128, 96, 1, 0 }, { -128, 96, 0, 0 } }}) {
                        put(vertex[0]); put(vertex[1]); put(0.f);
                        for (int i = 0; i < 4; ++i) put(uint32_t(0));
                        for (float weight : { 1.f, 0.f, 0.f, 0.f }) put(weight);
                        put(vertex[2]); put(vertex[3]);
                    }
                    put(uint32_t(12));
                    for (uint16_t index : { 0, 1, 2, 0, 2, 3 }) put(index);
                    put(uint8_t(1)); put(uint8_t(1)); put(uint16_t(0)); put(uint8_t(0));
                    put(uint32_t(4 * 12));
                    for (int i = 0; i < 4; ++i) {
                        put(0.f); put(0.f); put(uint32_t(0));
                    }
                    put(uint8_t(1)); put(uint32_t(16));
                    for (uint32_t value : { 1u, 0u, 0u, 6u }) put(value);
                    str("MDLS0001"); put(uint32_t(0)); put(uint16_t(1)); put(uint16_t(0));
                    str("root"); put(int32_t(0)); put(uint32_t(0xFFFFFFFFu)); put(uint32_t(64));
                    for (int col = 0; col < 4; ++col)
                        for (int row = 0; row < 4; ++row) put(row == col ? 1.f : 0.f);
                    str("{}"); str("MDLA0000"); put(uint8_t(0));
                    std::ofstream(directory / "models/tile.json") <<
                        R"({"width":256,"height":192,"material":"materials/tile.json","puppet":"models/card.mdl"})";
                }
                // A white texture keeps the material identical on its input and
                // final pass: repeated lighting alone must account for any loss.
                std::filesystem::create_directories(directory / "materials");
                {
                    std::ofstream texture(directory / "materials/white.tex", std::ios::binary);
                    const auto put = [&texture](uint32_t value) {
                        texture.write(reinterpret_cast<const char*>(&value), sizeof(value));
                    };
                    texture.write("TEXV0005", 9); texture.write("TEXI0001", 9);
                    for (uint32_t value : { 0u, 0u, 1u, 1u, 1u, 1u, 0u }) put(value);
                    texture.write("TEXB0001", 9);
                    for (uint32_t value : { 1u, 1u, 1u, 1u, 4u, 0xFFFFFFFFu }) put(value);
                }
                const std::string vertex = R"(
uniform mat4 g_ModelViewProjectionMatrix;
attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
#if SKINNING
uniform mat4x3 g_Bones[BONECOUNT];
attribute uvec4 a_BlendIndices;
#endif
void main() {
    vec3 position = a_Position;
#if SKINNING
    position = g_Bones[a_BlendIndices.x] * vec4(position, 1.0);
#endif
    gl_Position = g_ModelViewProjectionMatrix * vec4(position, 1.0);
    v_TexCoord = a_TexCoord;
}
)";
                const std::string fragment = R"(
uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
    vec4 color = texture(g_Texture0, v_TexCoord);
#if LIGHTING
    color.rgb *= vec3(0.4, 0.6, 0.8);
#endif
    gl_FragColor = color;
}
)";
                std::ofstream(directory / "shaders/metal_probe.vert") << vertex;
                std::ofstream(directory / "shaders/metal_probe.frag") << fragment;
                auto material = nlohmann::json::parse(
                    std::ifstream(directory / "materials/tile.json"));
                material["passes"][0]["textures"] = { "white" };
                material["passes"][0]["combos"]["LIGHTING"] = lit ? 1 : 0;
                std::ofstream(directory / "materials/tile.json") << material;
                if (effect) {
                    std::filesystem::create_directories(directory / "effects");
                    std::ofstream(directory / "effects/identity.json") <<
                        R"({"name":"identity","passes":[{"material":"materials/identity.json"}]})";
                    material["passes"][0]["combos"]["LIGHTING"] = 0;
                    material["passes"][0]["textures"] = nlohmann::json::array({ nullptr });
                    std::ofstream(directory / "materials/identity.json") << material;
                    auto layout = nlohmann::json::parse(std::ifstream(directory / "layout.json"));
                    layout["objects"][0]["effects"] = nlohmann::json::array({
                        { { "file", "effects/identity.json" }, { "visible", true } }
                    });
                    std::ofstream(directory / "layout.json") << layout;
                }
                LoadedScene loaded;
                std::string error;
                ASSERT_TRUE(LoadScene(project, directory / "cache", loaded, error)) << error;
                const auto graph = sceneToRenderGraph(*loaded.scene);
                ASSERT_NE(graph, nullptr);
                @autoreleasepool {
                    CAMetalLayer* layer = [CAMetalLayer layer];
                    layer.device = MTLCreateSystemDefaultDevice();
                    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
                    layer.drawableSize = CGSizeMake(384, 256);
                    MetalRender render;
                    ASSERT_TRUE(render.init(MetalRenderInitInfo {
                        .metal_layer = (__bridge void*)layer, .width = 384, .height = 256,
                        .render_width = 384, .render_height = 256, .display_scale_factor = 1.0,
                    }));
                    ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
                    for (int frame = 0; frame < 3; ++frame) {
                        ASSERT_TRUE(render.drawFrame(*loaded.scene)) << render.lastError();
                        std::vector<uint8_t> pixels;
                        uint32_t width = 0, height = 0;
                        ASSERT_TRUE(render.ReadRenderTargetForTests(
                            loaded.scene->ResolveRenderTargetName(SpecTex_Default), pixels, width, height));
                        ASSERT_EQ(width, 384u);
                        ASSERT_EQ(height, 256u);
                        for (uint32_t x : { 128u, 192u, 256u }) {
                            SCOPED_TRACE(x);
                            const auto offset = (128 * width + x) * 4;
                            for (size_t channel = 0; channel < 3; ++channel)
                                EXPECT_NEAR(pixels[offset + channel],
                                            255.f * (lit ? 0.4f + 0.2f * channel : 1.f), 1.f);
                            EXPECT_EQ(pixels[offset + 3], 255u);
                        }
                    }
                    render.destroy();
                }
            }
        }
    }
}

TEST_F(MetalSceneDraw, APerspectiveCameraDrawsThroughTheAuthoredShader)
{
    // A scene that last round was refused only for a perspective camera: the
    // same author card, drawn through `global_perspective` rather than the
    // ortho global camera. The shader writes clip from g_MVP, so a rotated
    // card must foreshorten -- left and right edges different heights -- which
    // is what rules out "orthographic plus a constant scale".
    const auto project = WriteFixture(root_ / "perspective-project", "0.30");
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "cache-perspective", loaded, error)) << error;

    auto* node = FirstDrawableNode(loaded.scene->sceneGraph.get());
    ASSERT_NE(node, nullptr);
    ASSERT_NE(loaded.scene->cameras["global_perspective"], nullptr);
    node->SetCamera("global_perspective");
    node->SetRotation(Eigen::Vector3f { 0.0f, 0.55f, 0.0f });

    const auto selection = SelectSceneBackend(*loaded.scene);
    ASSERT_EQ(selection.backend, SceneBackend::NativeMetal) << selection.fallback_reason;

    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer  = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(384, 256);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 384,
            .height               = 256,
            .render_width         = 384,
            .render_height        = 256,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();

        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
        render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);

        ASSERT_TRUE(render.drawFrame(*loaded.scene)) << render.lastError();

        std::vector<uint8_t> pixels;
        uint32_t             width = 0;
        uint32_t             height = 0;
        ASSERT_TRUE(render.ReadRenderTargetForTests(
            loaded.scene->ResolveRenderTargetName(SpecTex_Default), pixels, width, height));
        ASSERT_EQ(width, 384u);
        ASSERT_EQ(height, 256u);

        auto column_height = [&](uint32_t x) {
            int min_y = -1;
            int max_y = -1;
            for (uint32_t y = 0; y < height; ++y) {
                const std::size_t i = (static_cast<std::size_t>(y) * width + x) * 4;
                const auto        b = pixels[i + 2];
                if (b >= 65 && b <= 90) {
                    if (min_y < 0) min_y = static_cast<int>(y);
                    max_y = static_cast<int>(y);
                }
            }
            return min_y < 0 ? 0 : max_y - min_y + 1;
        };

        uint32_t left = 0;
        uint32_t right = width - 1;
        while (left < width && column_height(left) == 0) ++left;
        while (right > 0 && column_height(right) == 0) --right;
        ASSERT_LT(left, right) << "the perspective card produced no shader pixels";
        const int left_h  = column_height(left + (right - left) / 8);
        const int right_h = column_height(right - (right - left) / 8);
        EXPECT_NE(left_h, 0);
        EXPECT_NE(right_h, 0);
        EXPECT_GT(std::abs(left_h - right_h), 4)
            << "a rotated card under a perspective camera must foreshorten; left height "
            << left_h << " right height " << right_h;

        render.destroy();
    }
}

/// Two overlapping cards, drawn in order: a half-transparent red card nearer
/// the camera, whose `blending`, `depthtest` and `depthwrite` are the given
/// authored strings, then an opaque blue card further away that depth-tests
/// and writes no depth. The blue card spans x 152..312 and the red one
/// 72..232, so half the blue card lies behind the red one.
std::filesystem::path WriteDepthWriteFixture(const std::filesystem::path& root,
                                             std::string_view blending,
                                             std::string_view depthtest,
                                             std::string_view depthwrite)
{
    const std::string vertex =
        "uniform mat4 g_ModelViewProjectionMatrix;\n"
        "attribute vec3 a_Position;\n"
        "attribute vec2 a_TexCoord;\n"
        "varying vec2 v_TexCoord;\n"
        "void main() {\n"
        "  gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);\n"
        "  v_TexCoord = a_TexCoord;\n"
        "}\n";
    const auto fragment = [](std::string_view colour) {
        return "varying vec2 v_TexCoord;\n"
               "void main() {\n"
               "  gl_FragColor = vec4(" + std::string(colour) + ");\n"
               "}\n";
    };
    const auto pass = [](std::string_view shader, std::string_view blend, std::string_view test,
                         std::string_view write) {
        return R"({"passes":[{"shader":")" + std::string(shader) + R"(","blending":")" +
               std::string(blend) + R"(","cullmode":"nocull","depthtest":")" +
               std::string(test) + R"(","depthwrite":")" + std::string(write) + R"("}]})";
    };
    const auto card = [](int id, std::string_view name, int x, int z) {
        return R"({"id":)" + std::to_string(id) + R"(,"name":")" + std::string(name) +
               R"(","image":"models/)" + std::string(name) + R"(.json","origin":[)" +
               std::to_string(x) + ",128," + std::to_string(z) +
               R"(],"scale":[1,1,1],"angles":[0,0,0],"visible":true})";
    };

    const std::map<std::string, std::string> files {
        { "project.json",
          R"({"title":"Metal depth write","type":"scene","file":"layout.json","general":{"properties":{}}})" },
        { "models/near.json", R"({"width":160,"height":128,"material":"materials/near.json"})" },
        { "models/far.json", R"({"width":160,"height":128,"material":"materials/far.json"})" },
        { "materials/near.json", pass("depth_write_near", blending, depthtest, depthwrite) },
        { "materials/far.json", pass("depth_write_far", "normal", "enabled", "disabled") },
        { "shaders/depth_write_near.vert", vertex },
        { "shaders/depth_write_near.frag", fragment("1.0, 0.0, 0.0, 0.5") },
        { "shaders/depth_write_far.vert", vertex },
        { "shaders/depth_write_far.frag", fragment("0.0, 0.0, 1.0, 1.0") },
        { "layout.json",
          R"({"camera":{"center":[0,0,0],"eye":[0,0,1],"up":[0,1,0]},)"
          R"("general":{"ambientcolor":[0,0,0],"skylightcolor":[0,0,0],"clearcolor":[0.0,0.0,0.0],)"
          R"("cameraparallax":false,"orthogonalprojection":{"width":384,"height":256}},)"
          R"("objects":[)" + card(1, "near", 152, 100) + "," + card(2, "far", 232, -100) + "]}" },
    };
    for (const auto& [name, contents] : files) {
        const auto path = root / name;
        std::filesystem::create_directories(path.parent_path());
        std::ofstream(path) << contents;
    }
    return root / "project.json";
}

TEST_F(MetalSceneDraw, ADepthWritingDrawHidesLaterDrawsAsOnCompatibility)
{
    // Wallpaper Engine applies a material's `depthwrite` whatever its blending
    // -- its own depth-tested font materials are translucent and write depth --
    // so a translucent or additive layer that asks to write depth hides what
    // is drawn behind it afterwards, its transparent texels included. As in
    // Direct3D, OpenGL and Vulkan, a draw that does not depth-test writes no
    // depth, and only a target with a depth attachment has any. Each case is
    // drawn by both renderers and must come out the same; the cases also have
    // to differ from each other, or the comparison proves nothing.
    struct Case
    {
        const char* name;
        const char* blending;
        const char* depthtest;
        const char* depthwrite;
        bool        depth;
        bool        hides;
    };
    const Case cases[] = {
        { "translucent", "translucent", "enabled", "enabled", true, true },
        { "additive", "additive", "enabled", "enabled", true, true },
        { "opaque", "normal", "enabled", "enabled", true, true },
        { "translucent-no-write", "translucent", "enabled", "disabled", true, false },
        { "translucent-no-test", "translucent", "disabled", "enabled", true, false },
        { "translucent-no-depth", "translucent", "enabled", "enabled", false, false },
        { "opaque-no-depth", "normal", "enabled", "enabled", false, false },
    };
    // The far card is 160 x 128 pixels, half of it behind the near card.
    constexpr std::size_t kFarCard   = 160 * 128;
    constexpr std::size_t kUnhidden  = kFarCard * 9 / 10;
    constexpr std::size_t kHalfShown = kFarCard / 2;
    for (const auto& c : cases) {
        SCOPED_TRACE(c.name);
        std::map<bool, RendererPicture> pictures;
        for (const bool native : { false, true }) {
            const std::string name = std::string(c.name) + (native ? "-native" : "-compat");
            const auto        project = WriteDepthWriteFixture(root_ / ("depth-write-" + name),
                                                               c.blending, c.depthtest,
                                                               c.depthwrite);
            LoadedScene loaded;
            std::string error;
            ASSERT_TRUE(LoadScene(project, root_ / ("depth-write-cache-" + name), loaded, error))
                << error;
            loaded.scene->FindRenderTarget(std::string(SpecTex_Default))->withDepth = c.depth;
            if (native) {
                ASSERT_EQ(SelectSceneBackend(*loaded.scene).backend, SceneBackend::NativeMetal);
            }
            pictures[native] = DrawWithRenderer(*loaded.scene, native, 384, 256, 1, 1.0 / 60.0);
            ASSERT_TRUE(pictures[native].error.empty()) << pictures[native].error;
        }
        for (const bool native : { false, true }) {
            const auto& rgb  = pictures[native].rgb;
            std::size_t blue = 0;
            for (std::size_t i = 0; i + 2 < rgb.size(); i += 3) {
                if (rgb[i] < 32 && rgb[i + 1] < 32 && rgb[i + 2] > 224) ++blue;
            }
            const char* renderer = native ? "native" : "compatibility";
            if (c.hides) {
                EXPECT_GT(blue, kHalfShown * 9 / 10) << renderer << " hid more than the overlap";
                EXPECT_LT(blue, kHalfShown * 11 / 10)
                    << renderer << " drew the far card over a nearer depth-writing one";
            } else {
                EXPECT_GT(blue, kUnhidden) << renderer << " hid the far card behind a draw "
                                           << "that writes no depth";
            }
        }
        EXPECT_EQ(pictures[true].rgb, pictures[false].rgb)
            << "the native renderer wrote other depth than the compatibility renderer";
    }
}

TEST_F(MetalSceneDraw, ADepthTestedDrawCullsTheSameFacesAsCompatibility)
{
    // The compatibility backend honours a material's `cullmode` for every
    // pass into a depth-attached target -- models, skyboxes, a planet's ring --
    // with counter-clockwise front faces, and culls nothing elsewhere. Drawing
    // both faces of a ring here put its unlit back over its lit front. Each
    // case is drawn by both renderers and must come out the same; the cases
    // also have to differ from each other, or the comparison proves nothing.
    struct Case
    {
        const char* name;
        float       yaw;
        CullMode    cull;
        bool        depth;
    };
    constexpr float kTowards = 0.3f;
    constexpr float kAway    = 3.14159265f - 0.3f;
    const Case cases[] = {
        { "towards-back", kTowards, CullMode::Back, true },
        { "away-back", kAway, CullMode::Back, true },
        { "towards-front", kTowards, CullMode::Front, true },
        { "away-none", kAway, CullMode::None, true },
        { "away-back-no-depth", kAway, CullMode::Back, false },
    };
    std::map<std::string, std::size_t> card_pixels;
    for (const auto& c : cases) {
        SCOPED_TRACE(c.name);
        std::map<bool, RendererPicture> pictures;
        for (const bool native : { false, true }) {
            const std::string name = std::string(c.name) + (native ? "-native" : "-compat");
            const auto  project = WriteFixture(root_ / ("cull-" + name), "0.30");
            LoadedScene loaded;
            std::string error;
            ASSERT_TRUE(LoadScene(project, root_ / ("cull-cache-" + name), loaded, error)) << error;
            auto* node = FirstDrawableNode(loaded.scene->sceneGraph.get());
            ASSERT_NE(node, nullptr);
            node->SetCamera("global_perspective");
            node->SetRotation(Eigen::Vector3f { 0.0f, c.yaw, 0.0f });
            auto* material        = node->Mesh()->Material();
            material->depth_test  = true;
            material->depth_write = true;
            material->cull_mode   = c.cull;
            loaded.scene->FindRenderTarget(std::string(SpecTex_Default))->withDepth = c.depth;
            if (native) {
                ASSERT_EQ(SelectSceneBackend(*loaded.scene).backend, SceneBackend::NativeMetal);
            }
            pictures[native] = DrawWithRenderer(*loaded.scene, native, 384, 256, 1, 1.0 / 60.0);
            ASSERT_TRUE(pictures[native].error.empty()) << pictures[native].error;
        }
        EXPECT_EQ(pictures[true].rgb, pictures[false].rgb)
            << "the native renderer culled other faces than the compatibility renderer";
        // The card's constant blue, 0.30.
        std::size_t card = 0;
        for (std::size_t i = 0; i + 2 < pictures[true].rgb.size(); i += 3) {
            if (pictures[true].rgb[i + 2] >= 65 && pictures[true].rgb[i + 2] <= 90) ++card;
        }
        card_pixels[c.name] = card;
    }
    // One side of the card is culled and the other kept, by either cull mode,
    // and nothing is culled without culling or without depth.
    EXPECT_NE(card_pixels["towards-back"] == 0, card_pixels["away-back"] == 0);
    EXPECT_NE(card_pixels["towards-back"] == 0, card_pixels["towards-front"] == 0);
    EXPECT_GT(card_pixels["away-none"], 1000u);
    EXPECT_GT(card_pixels["away-back-no-depth"], 1000u);
}

TEST_F(MetalSceneDraw, AnIntermediateTargetIsDrawnCopiedAndResampledInOneFrame)
{
    // The shape an effect chain lowers to: the author's layer drawn into an
    // intermediate at the author's own smaller size, that intermediate copied
    // into a link texture, and the link texture resampled onto the scene's
    // output. Every step reads what an earlier step in the SAME frame produced.
    const auto  project = WriteFixture(root_ / "project");
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "cache", loaded, error)) << error;

    auto* node = FirstDrawableNode(loaded.scene->sceneGraph.get());
    ASSERT_NE(node, nullptr);

    // An author-sized effect buffer: half the canvas in each axis. Its size must
    // survive as its own, not be flattened to the output's.
    loaded.scene->renderTargets["_rt_effect_pingpong_a_0"] = SceneRenderTarget {
        .width  = 192,
        .height = 128,
    };

    @autoreleasepool {
        id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(640, 360);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 640,
            .height               = 360,
            .render_width         = 640,
            .render_height        = 360,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();

        rg::RenderGraph graph;
        AddDraw(graph, node, "_rt_effect_pingpong_a_0", {});
        AddCopy(graph, "_rt_effect_pingpong_a_0", "_rt_link_1");
        AddCopy(graph, "_rt_link_1", std::string(SpecTex_Default));

        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, graph)) << render.lastError();
        render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);
        ASSERT_TRUE(render.drawFrame(*loaded.scene)) << render.lastError();

        const auto shader_pixels = [](const std::vector<uint8_t>& pixels) {
            std::size_t count = 0;
            for (std::size_t i = 0; i < pixels.size(); i += 4) {
                const auto r = pixels[i];
                const auto g = pixels[i + 1];
                const auto b = pixels[i + 2];
                if (b >= 55 && b <= 73 && (r > 8 || g > 8)) ++count;
            }
            return count;
        };

        std::vector<uint8_t> intermediate;
        uint32_t             width  = 0;
        uint32_t             height = 0;
        ASSERT_TRUE(
            render.ReadRenderTargetForTests("_rt_effect_pingpong_a_0", intermediate, width, height));
        // The author's own size, not the output's: flattening the two would
        // make this 384x256 and change every texel step the effect samples at.
        EXPECT_EQ(width, 192u);
        EXPECT_EQ(height, 128u);
        EXPECT_GT(shader_pixels(intermediate), 200u)
            << "the intermediate holds nothing the author's shader could have written";

        std::vector<uint8_t> linked;
        ASSERT_TRUE(render.ReadRenderTargetForTests("_rt_link_1", linked, width, height));
        EXPECT_EQ(width, 192u);
        EXPECT_EQ(height, 128u);
        EXPECT_EQ(linked, intermediate) << "the equal-sized copy is not a faithful copy";

        std::vector<uint8_t> output;
        ASSERT_TRUE(render.ReadRenderTargetForTests(
            loaded.scene->ResolveRenderTargetName(SpecTex_Default), output, width, height));
        EXPECT_EQ(width, 384u);
        EXPECT_EQ(height, 256u);
        // The resample used to be skipped silently, which left this target
        // holding whatever it was cleared to.
        EXPECT_GT(shader_pixels(output), 800u)
            << "the scaled copy did not carry the intermediate onto the output";

        render.destroy();
    }
}

TEST_F(MetalSceneDraw, ADrawnFrameIsReportedAsPresentedAndLeavesTheFirstFrameFlagAlone)
{
    // `Scene::first_frame_ok` is the scene handler's, and the handler tells the
    // host a first frame exists on the edge where it sets it. A backend that
    // set the flag itself would satisfy that check before the handler ran, the
    // host would never hear about the frame, and a wallpaper drawing perfectly
    // well would be torn down when the startup deadline expired.
    const auto project = WriteFixture(root_ / "project");
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "cache", loaded, error)) << error;
    ASSERT_EQ(SelectSceneBackend(*loaded.scene).backend, SceneBackend::NativeMetal);

    @autoreleasepool {
        id<MTLDevice>  device = MTLCreateSystemDefaultDevice();
        CAMetalLayer*  layer  = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(256, 128);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 256,
            .height               = 128,
            .render_width         = 256,
            .render_height        = 128,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();
        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();

        bool presented = false;
        ASSERT_TRUE(render.drawFrame(*loaded.scene, &presented)) << render.lastError();
        EXPECT_TRUE(presented) << "a frame was drawn but not reported as reaching the layer";
        EXPECT_FALSE(loaded.scene->first_frame_ok)
            << "the backend claimed the handler's first-frame flag, so the host would never be "
               "told this wallpaper started";

        render.destroy();
    }
}

TEST_F(MetalSceneDraw, RememberedPrepareFailureStopsTheBackendFlipFlopping)
{
    const auto project = WriteFixture(root_ / "project");
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "cache", loaded, error)) << error;

    ASSERT_EQ(SelectSceneBackend(*loaded.scene).backend, SceneBackend::NativeMetal);

    RecordMetalPrepareFailure(*loaded.scene, "a shader pipeline could not be created");
    for (int attempt = 0; attempt < 3; ++attempt) {
        const auto selection = SelectSceneBackend(*loaded.scene);
        EXPECT_EQ(selection.backend, SceneBackend::LegacyVulkan);
        EXPECT_EQ(selection.fallback_reason, "a shader pipeline could not be created");
    }

    // Turning the preference off and on again is the one thing the user can do
    // that makes the question worth asking a second time.
    SetSceneRendererPreference(SceneRendererPreference::Compatibility);
    const auto off = SelectSceneBackend(*loaded.scene);
    EXPECT_EQ(off.backend, SceneBackend::LegacyVulkan);
    EXPECT_TRUE(off.fallback_reason.empty()) << "choosing compatibility is not a fallback";

    SetSceneRendererPreference(SceneRendererPreference::NativeMetalPreferred);
    EXPECT_EQ(SelectSceneBackend(*loaded.scene).backend, SceneBackend::NativeMetal);
}

TEST_F(MetalSceneDraw, OverbrightRadianceReachesBloomWithoutChangingLdrColor)
{
    const auto directory = root_ / "radiance";
    const auto project = WriteFixture(directory);
    const std::string vertex =
        "uniform mat4 g_ModelViewProjectionMatrix;\n"
        "attribute vec3 a_Position;\nattribute vec2 a_TexCoord;\n"
        "varying vec2 v_TexCoord;\n"
        "void main(){ gl_Position=g_ModelViewProjectionMatrix*vec4(a_Position,1);"
        "v_TexCoord=a_TexCoord; }\n";
    // Original synthetic shaders: an emitter, thresholded neighboring bloom,
    // and an SDR additive composition. A threshold above one makes clipping
    // before bloom observable rather than merely a different intermediate.
    const std::map<std::string, std::string> fragments {
        { "emitter", "varying vec2 v_TexCoord;\nvoid main(){"
          "gl_FragColor=vec4(v_TexCoord.x<0.5?vec3(4,0.25,0.5):vec3(0),1);}\n" },
        { "bloom", "varying vec2 v_TexCoord;\nuniform sampler2D g_Texture0;\n"
          "void main(){ float r=texture(g_Texture0,v_TexCoord+vec2(-0.125,0)).r;"
          "r+=texture(g_Texture0,v_TexCoord).r;"
          "r+=texture(g_Texture0,v_TexCoord+vec2(0.125,0)).r;"
          "gl_FragColor=vec4(max(r/3.0-1.25,0.0)*0.25,0,0,1);}\n" },
        { "compose", "varying vec2 v_TexCoord;\nuniform sampler2D g_Texture0;\n"
          "uniform sampler2D g_Texture1;\nvoid main(){"
          "gl_FragColor=vec4(clamp(texture(g_Texture0,v_TexCoord).rgb+"
          "texture(g_Texture1,v_TexCoord).rgb,0.0,1.0),1);}\n" },
    };
    nlohmann::json objects = nlohmann::json::array();
    int id = 0;
    for (const auto& [name, fragment] : fragments) {
        std::ofstream(directory / ("shaders/" + name + ".vert")) << vertex;
        std::ofstream(directory / ("shaders/" + name + ".frag")) << fragment;
        nlohmann::json pass {
            { "shader", name }, { "blending", "normal" },
            { "depthtest", "disabled" }, { "depthwrite", "disabled" },
        };
        if (name != "emitter") pass["textures"] = { "_rt_radiance" };
        if (name == "compose") pass["textures"].push_back("_rt_bloom_probe");
        std::ofstream(directory / ("materials/" + name + ".json"))
            << nlohmann::json { { "passes", nlohmann::json::array({ pass }) } };
        std::ofstream(directory / ("models/" + name + ".json"))
            << R"({"width":384,"height":256,"material":"materials/)" << name << R"(.json"})";
        objects.push_back({ { "id", ++id }, { "name", name },
            { "image", "models/" + name + ".json" }, { "origin", { 192, 128, 0 } },
            { "scale", { 1, 1, 1 } }, { "angles", { 0, 0, 0 } }, { "visible", true } });
    }
    std::ifstream layout_source(directory / "layout.json");
    auto layout = nlohmann::json::parse(layout_source);
    layout["objects"] = std::move(objects);
    std::ofstream(directory / "layout.json") << layout;
    const auto find_node = [](auto&& self, SceneNode* node, std::string_view name) -> SceneNode* {
        if (node->Name() == name && node->HasMaterial()) return node;
        for (const auto& child : node->GetChildren()) {
            if (auto* found = self(self, child.get(), name)) return found;
        }
        return nullptr;
    };
    for (bool hdr : { false, true }) {
        SCOPED_TRACE(hdr ? "HDR" : "LDR");
        LoadedScene loaded;
        std::string error;
        ASSERT_TRUE(LoadScene(project, root_ / (hdr ? "cache-hdr" : "cache-ldr"), loaded, error))
            << error;
        auto& scene = *loaded.scene;
        const auto format = hdr ? TextureFormat::RGBA16F : TextureFormat::RGBA8;
        for (const auto& key : { "_rt_radiance", "_rt_bloom_probe" }) {
            scene.renderTargets[key] = SceneRenderTarget {
                .width = 384, .height = 256, .format = format,
            };
        }
        auto* emitter = find_node(find_node, scene.sceneGraph.get(), "emitter");
        auto* bloom = find_node(find_node, scene.sceneGraph.get(), "bloom");
        auto* compose = find_node(find_node, scene.sceneGraph.get(), "compose");
        ASSERT_NE(emitter, nullptr);
        ASSERT_NE(bloom, nullptr);
        ASSERT_NE(compose, nullptr);
        @autoreleasepool {
            CAMetalLayer* layer = [CAMetalLayer layer];
            layer.device = MTLCreateSystemDefaultDevice();
            layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
            layer.drawableSize = CGSizeMake(384, 256);
            MetalRender render;
            ASSERT_TRUE(render.init(MetalRenderInitInfo {
                .metal_layer = (__bridge void*)layer, .width = 384, .height = 256,
                .render_width = 384, .render_height = 256, .display_scale_factor = 1.0,
            }));
            rg::RenderGraph graph;
            AddDraw(graph, emitter, "_rt_radiance", {});
            AddDraw(graph, bloom, "_rt_bloom_probe", { "_rt_radiance" });
            AddDraw(graph, compose, std::string(SpecTex_Default),
                    { "_rt_radiance", "_rt_bloom_probe" });
            ASSERT_TRUE(render.compileRenderGraph(scene, graph)) << render.lastError();
            ASSERT_TRUE(render.drawFrame(scene)) << render.lastError();
            std::vector<uint8_t> bytes;
            std::vector<float> radiance;
            uint32_t width = 0, height = 0;
            ASSERT_TRUE(render.ReadRenderTargetForTests("_rt_radiance", bytes, width, height,
                                                        &radiance));
            const size_t left = (128u * width + 96u) * 4;
            EXPECT_NEAR(radiance[left], hdr ? 4.0f : 1.0f, 0.001f);
            ASSERT_TRUE(render.ReadRenderTargetForTests("_rt_bloom_probe", bytes, width, height,
                                                        &radiance));
            EXPECT_NEAR(radiance[left], hdr ? 0.6875f : 0.0f, 0.001f);
            ASSERT_TRUE(render.ReadRenderTargetForTests(
                scene.ResolveRenderTargetName(SpecTex_Default), bytes, width, height));
            EXPECT_EQ(bytes[left], 255);
            EXPECT_NEAR(bytes[left + 1], 64, 1);
            EXPECT_NEAR(bytes[left + 2], 128, 1);
            // Outside the emitter, one neighboring overbright tap contributes
            // a visible red halo only when radiance survived the first target.
            const size_t halo = (128u * width + 192u + 4u) * 4;
            EXPECT_NEAR(bytes[halo], hdr ? 5 : 0, 1);
            const size_t dark = (128u * width + 300u) * 4;
            EXPECT_EQ(bytes[dark], 0);
            render.destroy();
        }
    }
}


// ---------------------------------------------------------------------------
// Scene optimisation on the native backend

namespace
{

/// A drawn frame plus the reuse counters that frame moved.
struct FrameCounters
{
    uint64_t executed { 0 };
    uint64_t skipped { 0 };
};

FrameCounters DrawOneFrame(MetalRender& render, Scene& scene)
{
    const auto before = wallpaper::vulkan::CurrentSceneOptimizationTotals();
    const bool ok     = render.drawFrame(scene);
    EXPECT_TRUE(ok) << render.lastError();
    const auto after = wallpaper::vulkan::CurrentSceneOptimizationTotals();
    return FrameCounters { after.executed_passes - before.executed_passes,
                           after.skipped_passes - before.skipped_passes };
}

std::vector<uint8_t> ReadOutput(MetalRender& render, Scene& scene)
{
    std::vector<uint8_t> pixels;
    uint32_t             width = 0;
    uint32_t             height = 0;
    EXPECT_TRUE(render.ReadRenderTargetForTests(scene.ResolveRenderTargetName(SpecTex_Default),
                                                pixels, width, height));
    return pixels;
}

} // namespace

TEST_F(MetalSceneDraw, AnUnchangedTargetIsReusedAndProducesTheSamePixels)
{
    // This fixture binds no frame-varying uniform, which is exactly the scene
    // whose second frame has nothing new to draw. What must be true is both
    // halves at once: work was removed, AND the picture is byte-identical to
    // the one the work produced.
    const auto  project = WriteFixture(root_ / "project");
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "cache", loaded, error)) << error;
    ASSERT_EQ(SelectSceneBackend(*loaded.scene).backend, SceneBackend::NativeMetal);

    @autoreleasepool {
        id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(640, 360);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 640,
            .height               = 360,
            .render_width         = 640,
            .render_height        = 360,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();

        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
        render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);

        const auto first = DrawOneFrame(render, *loaded.scene);
        EXPECT_EQ(first.skipped, 0u) << "nothing can be reused before anything has been drawn";
        EXPECT_GT(first.executed, 0u);
        const auto drawn = ReadOutput(render, *loaded.scene);
        ASSERT_FALSE(drawn.empty());

        const auto second = DrawOneFrame(render, *loaded.scene);
        EXPECT_GT(second.skipped, 0u)
            << "an unchanged scene re-executed every pass; nothing was reused";
        EXPECT_EQ(ReadOutput(render, *loaded.scene), drawn)
            << "the reused target does not hold the pixels the drawn frame produced";

        // Moving the layer changes the model transform, which is part of the
        // sample. The target has to be redrawn, and the picture has to change.
        auto* node = FirstDrawableNode(loaded.scene->sceneGraph.get());
        ASSERT_NE(node, nullptr);
        node->SetTranslate(Eigen::Vector3f { 96.0f, 64.0f, 0.0f });
        const auto moved = DrawOneFrame(render, *loaded.scene);
        EXPECT_EQ(moved.skipped, 0u)
            << "a moved layer reused its target; the transform is not in the sample";
        EXPECT_NE(ReadOutput(render, *loaded.scene), drawn)
            << "the target was re-executed but the picture did not change";

        render.destroy();
    }
}

TEST_F(MetalSceneDraw, TurningTheOptimisationOffDrawsEveryPassAgain)
{
    const auto  project = WriteFixture(root_ / "project");
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "cache", loaded, error)) << error;

    @autoreleasepool {
        id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(640, 360);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 640,
            .height               = 360,
            .render_width         = 640,
            .render_height        = 360,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();

        wallpaper::vulkan::SetSceneOptimizationEnabled(false);
        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
        render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);

        DrawOneFrame(render, *loaded.scene);
        const auto second = DrawOneFrame(render, *loaded.scene);
        EXPECT_EQ(second.skipped, 0u) << "pixels were reused with the setting switched off";
        wallpaper::vulkan::SetSceneOptimizationEnabled(true);

        render.destroy();
    }
}

TEST_F(MetalSceneDraw, AFrameThatWouldRepeatThePictureTakesNoDrawableAndPresentsNothing)
{
    // A static scene: from the second frame every pass is reused, so the
    // composition would put back exactly the picture already on the layer. That
    // frame must succeed without a drawable, a commit or a present -- and
    // anything that changes what the composition reads has to bring the
    // present back, exactly once.
    const auto  project = WriteFixture(root_ / "project");
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "cache", loaded, error)) << error;
    ASSERT_EQ(SelectSceneBackend(*loaded.scene).backend, SceneBackend::NativeMetal);

    RendererCounters::SetEnabled(true);
    RendererCounters counters;
    @autoreleasepool {
        id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(640, 360);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 640,
            .height               = 360,
            .render_width         = 640,
            .render_height        = 360,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();
        render.SetCounters(&counters);
        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
        render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);

        const auto draw = [&]() {
            bool presented = false;
            EXPECT_TRUE(render.drawFrame(*loaded.scene, &presented)) << render.lastError();
            return presented;
        };
        const auto skipped = [&]() { return counters.Get(OWE_RC_PRESENTS_SKIPPED_UNCHANGED); };
        const auto requests = [&]() { return counters.Get(OWE_RC_PRESENT_REQUESTS); };

        EXPECT_TRUE(draw()) << "the first frame has nothing on the layer to repeat";
        const auto drawn = ReadOutput(render, *loaded.scene);
        for (int frame = 0; frame < 5; ++frame) {
            EXPECT_FALSE(draw()) << "frame " << frame << " repeated the picture and presented it";
        }
        EXPECT_EQ(skipped(), 5u);
        EXPECT_EQ(requests(), 1u) << "a skipped frame was counted as a present request";
        EXPECT_EQ(ReadOutput(render, *loaded.scene), drawn)
            << "skipping the present changed what the scene output holds";

        // Each of these changes what the composition reads without touching a
        // pass, so the next frame presents once and the one after repeats.
        const std::array<std::function<void()>, 5> changes {
            [&] { render.SetWallpaperHorizontalFlip(true); },
            [&] { render.SetWallpaperScalingMode(WallpaperScalingMode::FILL); },
            [&] { render.SetWallpaperScalingFactor(1.5); },
            [&] { render.SetWallpaperFraming({ 0.0, 1.0 }); },
            [&] { render.InvalidatePresentedFrame(); },
        };
        for (std::size_t i = 0; i < changes.size(); ++i) {
            changes[i]();
            EXPECT_TRUE(draw()) << "change " << i << " did not bring the present back";
            EXPECT_FALSE(draw()) << "change " << i << " presented more than once";
        }
        EXPECT_EQ(requests(), 1u + changes.size());

        // A changed layer is new content: it draws and presents.
        auto* node = FirstDrawableNode(loaded.scene->sceneGraph.get());
        ASSERT_NE(node, nullptr);
        node->SetTranslate(Eigen::Vector3f { 96.0f, 64.0f, 0.0f });
        EXPECT_TRUE(draw()) << "a moved layer was not presented";
        EXPECT_FALSE(draw());

        // With the optimisation off every frame presents, and switching it back
        // on starts from a real present rather than from a stale record.
        wallpaper::vulkan::SetSceneOptimizationEnabled(false);
        for (int frame = 0; frame < 3; ++frame) {
            EXPECT_TRUE(draw()) << "a frame was skipped with the setting switched off";
        }
        wallpaper::vulkan::SetSceneOptimizationEnabled(true);
        EXPECT_TRUE(draw()) << "the first frame after turning reuse back on must present";
        EXPECT_FALSE(draw());

        render.destroy();
    }
    RendererCounters::SetEnabled(false);
}

TEST_F(MetalSceneDraw, APannedWallpaperIsComposedAtTheChosenPositionInTheDrawableAndThePoster)
{
    // A 3:2 scene fitted into a square layer leaves bars above and below. The
    // composition that fills the drawable is the one a poster is made from, so
    // where the picture sits is read off the poster: the first and last rows
    // that are not the bars' black must be the ones the layout function says,
    // for the top, the middle and the bottom, in the frame that presents the
    // change and again for a poster served without drawing a frame.
    const auto project = WriteFixture(root_ / "project");
    {
        // The scene's own background must not be black, or it could not be told
        // from the bars around it.
        const auto layout_path = root_ / "project" / "layout.json";
        std::ifstream in(layout_path);
        std::string   text((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        in.close();
        const std::string black = "\"clearcolor\":[0.0,0.0,0.0]";
        const auto        at    = text.find(black);
        ASSERT_NE(at, std::string::npos);
        text.replace(at, black.size(), "\"clearcolor\":[0.2,0.4,0.6]");
        std::ofstream(layout_path) << text;
    }
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "cache", loaded, error)) << error;
    ASSERT_EQ(SelectSceneBackend(*loaded.scene).backend, SceneBackend::NativeMetal);

    struct Poster {
        std::mutex              mutex;
        std::condition_variable changed;
        bool                    requested { false };
        int                     delivered { 0 };
        bool                    bgra { false };
        uint32_t                width { 0 };
        uint32_t                height { 0 };
        std::vector<uint8_t>    pixels;
    };
    auto poster = std::make_shared<Poster>();

    constexpr uint32_t kSide = 480;
    @autoreleasepool {
        id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(kSide, kSide);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = kSide,
            .height               = kSide,
            .render_width         = kSide,
            .render_height        = kSide,
            .display_scale_factor = 1.0,
        };
        info.wants_poster = [poster] {
            std::scoped_lock lock(poster->mutex);
            const bool wanted = poster->requested;
            poster->requested = false;
            return wanted;
        };
        info.poster_ready = [poster](std::span<const uint8_t> pixels, uint32_t width,
                                     uint32_t height, bool bgra) {
            std::scoped_lock lock(poster->mutex);
            poster->pixels.assign(pixels.begin(), pixels.end());
            poster->width  = width;
            poster->height = height;
            poster->bgra   = bgra;
            ++poster->delivered;
            poster->changed.notify_all();
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();
        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
        render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);
        render.SetWallpaperScalingMode(WallpaperScalingMode::FIT);

        const auto ask_for_poster = [&] {
            std::scoped_lock lock(poster->mutex);
            poster->requested = true;
        };
        const auto wait_for_poster = [&](int expected) {
            std::unique_lock lock(poster->mutex);
            return poster->changed.wait_for(lock, std::chrono::seconds(10),
                                            [&] { return poster->delivered >= expected; });
        };
        // The rows and columns that differ from the bars' black.
        struct Footprint {
            int32_t first_x { 0 }, last_x { -1 }, first_y { 0 }, last_y { -1 };
        };
        const auto footprint_of = [&](const std::vector<uint8_t>& pixels) {
            Footprint f { static_cast<int32_t>(kSide), -1, static_cast<int32_t>(kSide), -1 };
            for (int32_t y = 0; y < static_cast<int32_t>(kSide); ++y) {
                for (int32_t x = 0; x < static_cast<int32_t>(kSide); ++x) {
                    const auto at = (static_cast<size_t>(y) * kSide + x) * 4;
                    if (pixels[at] == 0 && pixels[at + 1] == 0 && pixels[at + 2] == 0) continue;
                    f.first_x = std::min(f.first_x, x);
                    f.last_x  = std::max(f.last_x, x);
                    f.first_y = std::min(f.first_y, y);
                    f.last_y  = std::max(f.last_y, y);
                }
            }
            return f;
        };

        bool presented = false;
        ASSERT_TRUE(render.drawFrame(*loaded.scene, &presented)) << render.lastError();
        ASSERT_TRUE(presented);

        int  deliveries = 0;
        int  previous_first_y = -1;
        for (const double pan_y : { 0.0, 0.5, 1.0 }) {
            SCOPED_TRACE(pan_y);
            const auto layout = ComputeWallpaperScalingLayout(
                WallpaperScalingMode::FIT, 384, 256, kSide, kSide, 1.0, 1.0, 0.5, pan_y);
            ASSERT_EQ(layout.viewport_px.width, static_cast<int32_t>(kSide));
            ASSERT_EQ(layout.viewport_px.height, 320);

            // The frame that follows the change presents, and the poster
            // composed beside the drawable is the same picture.
            render.SetWallpaperFraming({ 0.5, pan_y });
            ask_for_poster();
            presented = false;
            ASSERT_TRUE(render.drawFrame(*loaded.scene, &presented)) << render.lastError();
            EXPECT_TRUE(presented) << "a changed position did not present";
            ASSERT_TRUE(wait_for_poster(++deliveries));
            std::vector<uint8_t> in_frame;
            {
                std::scoped_lock lock(poster->mutex);
                ASSERT_EQ(poster->width, kSide);
                ASSERT_EQ(poster->height, kSide);
                ASSERT_EQ(poster->pixels.size(), static_cast<size_t>(kSide) * kSide * 4);
                in_frame = poster->pixels;
            }
            const auto drawn = footprint_of(in_frame);
            EXPECT_EQ(drawn.first_y, layout.viewport_px.y);
            EXPECT_EQ(drawn.last_y, layout.viewport_px.y + layout.viewport_px.height - 1);
            EXPECT_EQ(drawn.first_x, 0);
            EXPECT_EQ(drawn.last_x, static_cast<int32_t>(kSide) - 1);
            EXPECT_GT(drawn.first_y, previous_first_y) << "the picture did not move down";
            previous_first_y = drawn.first_y;

            // An idle wallpaper's poster is composed from the retained output,
            // with no frame drawn, and has to agree with the drawable's.
            ask_for_poster();
            EXPECT_EQ(render.ServicePosterRequest(*loaded.scene), PosterServiceResult::Submitted);
            ASSERT_TRUE(wait_for_poster(++deliveries));
            {
                std::scoped_lock lock(poster->mutex);
                EXPECT_EQ(poster->pixels, in_frame);
            }

            // The next frame repeats the picture and presents nothing.
            presented = true;
            ASSERT_TRUE(render.drawFrame(*loaded.scene, &presented)) << render.lastError();
            EXPECT_FALSE(presented);
        }
        EXPECT_EQ(previous_first_y, 160) << "the bottom pan leaves all the slack above the picture";

        render.destroy();
    }
}

TEST_F(MetalSceneDraw, GeometryRebuiltEveryFrameIsUploadedAndDrawnFromItsOwnSlot)
{
    // The particle shape, without a particle system: a mesh marked dynamic,
    // empty when the graph is compiled, filled afterwards. What is proved is
    // the upload path -- an empty frame is not a failure, a filled one reaches
    // the screen, and the storage rotates per in-flight frame without the CPU
    // overwriting what the GPU is reading.
    const auto  project = WriteFixture(root_ / "project");
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "cache", loaded, error)) << error;

    auto* node = FirstDrawableNode(loaded.scene->sceneGraph.get());
    ASSERT_NE(node, nullptr);
    auto* source_mesh = node->Mesh();
    ASSERT_NE(source_mesh, nullptr);
    auto material = source_mesh->MaterialSlotPtr(0);
    ASSERT_NE(material, nullptr);

    // Same attribute names the author's shader declares, so the translated
    // pipeline binds this stream exactly as it binds the static one.
    auto dynamic_mesh = std::make_shared<SceneMesh>(MeshUpdate::PerFrame);
    std::vector<SceneVertexArray::SceneVertexAttribute> attributes {
        { std::string(WE_IN_POSITION), VertexType::FLOAT3 },
        { std::string(WE_IN_TEXCOORD), VertexType::FLOAT2 },
    };
    constexpr std::size_t kQuads = 4;
    dynamic_mesh->AddVertexArray(SceneVertexArray(attributes, kQuads * 4));
    dynamic_mesh->AddIndexArray(SceneIndexArray(kQuads));
    dynamic_mesh->GetVertexArray(0).SetOption(WE_PRENDER_SPRITE, true);
    dynamic_mesh->MaterialSlots().push_back(material);
    node->AddMesh(dynamic_mesh);

    ASSERT_EQ(SelectSceneBackend(*loaded.scene).backend, SceneBackend::NativeMetal)
        << SelectSceneBackend(*loaded.scene).fallback_reason;

    @autoreleasepool {
        id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(640, 360);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 640,
            .height               = 360,
            .render_width         = 640,
            .render_height        = 360,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();

        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
        render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);

        // A mesh the runtime has not filled yet must keep the scene ticking
        // rather than be declared still, and must not be reusable.
        EXPECT_TRUE(render.ShaderUpdateDemandReasons() &
                    wallpaper::vulkan::DynamicReason::DynamicMesh)
            << "a mesh rebuilt per frame was not reported as advancing on its own";

        // Three empty frames: nothing to draw is not a failed frame.
        for (int frame = 0; frame < 3; ++frame) {
            ASSERT_TRUE(render.drawFrame(*loaded.scene)) << render.lastError();
            loaded.scene->PassFrameTime(1.0 / 60.0);
        }
        const auto empty = ReadOutput(render, *loaded.scene);
        ASSERT_FALSE(empty.empty());

        // Now fill one quad, the way the particle generator does, and let more
        // than `kFramesInFlight` frames go by so every slot is written and read.
        auto& vertices = dynamic_mesh->GetVertexArray(0);
        auto& indices  = dynamic_mesh->GetIndexArray(0);
        const std::array<float, 20> quad {
            20.0f,  20.0f,  0.0f, 0.0f, 0.0f,
            360.0f, 20.0f,  0.0f, 1.0f, 0.0f,
            360.0f, 230.0f, 0.0f, 1.0f, 1.0f,
            20.0f,  230.0f, 0.0f, 0.0f, 1.0f,
        };
        vertices.SetVertexs(0, quad);
        const std::array<uint16_t, 6> quad_indices { 0, 1, 3, 1, 2, 3 };
        indices.AssignHalf(0, quad_indices);
        indices.SetRenderDataCount(3);
        dynamic_mesh->SetDirty();

        for (int frame = 0; frame < 5; ++frame) {
            ASSERT_TRUE(render.drawFrame(*loaded.scene)) << render.lastError();
            loaded.scene->PassFrameTime(1.0 / 60.0);
        }
        const auto filled = ReadOutput(render, *loaded.scene);
        EXPECT_NE(filled, empty)
            << "geometry uploaded after the graph was compiled never reached the target";

        render.destroy();
    }
}

TEST_F(MetalSceneDraw, ASpriteSheetAdvancesOnItsOwnClockAndRedrawsOnlyWhenTheFrameChanges)
{
    // Sprite animation reaches the shader as the frame's rotation and
    // translation uniforms, so what has to be proved is the chain around them:
    // the sheet is picked up at prepare, advanced by the shared value updater
    // every frame, folded into the reuse sample as the rectangle that will
    // actually be sampled, and reported as something that keeps the clock
    // running. The fixture's shader binds no texture slot, so nothing here
    // claims a sheet was sampled on the GPU -- only that the machinery around
    // it behaves.
    const auto  project = WriteFixture(root_ / "project");
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "cache", loaded, error)) << error;

    auto* node = FirstDrawableNode(loaded.scene->sceneGraph.get());
    ASSERT_NE(node, nullptr);
    auto* material = node->Mesh()->MaterialForSlot(0);
    ASSERT_NE(material, nullptr);

    // Two frames of one sheet, a tenth of a second apart.
    SceneTexture sheet { .url = "materials/sheet.tex", .isSprite = true };
    sheet.spriteAnim.AppendFrame(
        SpriteFrame { .imageId = 0, .frametime = 0.1f, .width = 0.5f, .height = 1.0f });
    sheet.spriteAnim.AppendFrame(SpriteFrame {
        .imageId = 0, .frametime = 0.1f, .x = 0.5f, .width = 0.5f, .height = 1.0f });
    loaded.scene->textures["materials/sheet.tex"] = std::move(sheet);
    material->textures = { "materials/sheet.tex" };

    ASSERT_EQ(SelectSceneBackend(*loaded.scene).backend, SceneBackend::NativeMetal)
        << SelectSceneBackend(*loaded.scene).fallback_reason;

    @autoreleasepool {
        id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(640, 360);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 640,
            .height               = 360,
            .render_width         = 640,
            .render_height        = 360,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();

        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
        render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);

        // A sheet with more than one frame is not a still scene: whatever the
        // reuse cache decides, the clock has to keep running or the animation
        // never reaches its next frame.
        EXPECT_TRUE(render.ShaderUpdateDemandReasons() &
                    wallpaper::vulkan::DynamicReason::AnimatedSprite)
            << "an animated sheet was not reported as advancing on its own";

        DrawOneFrame(render, *loaded.scene);
        // A sheet starts with no time left on its current frame, so the first
        // tick that carries any elapsed time steps it. That step has to redraw.
        loaded.scene->PassFrameTime(1.0 / 60.0);
        const auto first_step = DrawOneFrame(render, *loaded.scene);
        EXPECT_EQ(first_step.skipped, 0u)
            << "the sheet stepped to its second frame and the target was reused anyway";

        // A sixtieth of a second does not consume the tenth of a second this
        // frame is held for, so the rectangle the shader samples is unchanged
        // and the target may be reused.
        const auto between = DrawOneFrame(render, *loaded.scene);
        EXPECT_GT(between.skipped, 0u) << "a sheet between frame changes forced a redraw";

        // Enough time to step the sheet again: the rectangle changes, so the
        // target must be redrawn rather than reused. The clock kept running
        // through the reused frames above, which is what makes this reachable.
        loaded.scene->PassFrameTime(0.5);
        const auto stepped = DrawOneFrame(render, *loaded.scene);
        EXPECT_EQ(stepped.skipped, 0u)
            << "the sheet advanced a frame and the target was reused anyway";

        render.destroy();
    }
}

TEST_F(MetalSceneDraw, TurningTheOptimisationBackOnDoesNotReuseAFrameDrawnWhileItWasOff)
{
    // The defect this covers: with reuse off, nothing records a signature, so
    // the table keeps the one that was current when it was switched off -- while
    // every frame in between redraws from whatever inputs it has. If the inputs
    // later return to that recorded value, re-enabling would call the target
    // unchanged although its pixels came from a frame with different inputs.
    const auto  project = WriteFixture(root_ / "project");
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "cache", loaded, error)) << error;

    auto* node = FirstDrawableNode(loaded.scene->sceneGraph.get());
    ASSERT_NE(node, nullptr);
    const Eigen::Vector3f home = node->Translate();

    @autoreleasepool {
        id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(640, 360);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 640,
            .height               = 360,
            .render_width         = 640,
            .render_height        = 360,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();

        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
        render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);

        DrawOneFrame(render, *loaded.scene);
        const auto at_home = ReadOutput(render, *loaded.scene);
        ASSERT_FALSE(at_home.empty());
        ASSERT_GT(DrawOneFrame(render, *loaded.scene).skipped, 0u)
            << "the recorded signature this test depends on was never taken";

        // Off: the layer moves and is drawn there. Nothing records that.
        wallpaper::vulkan::SetSceneOptimizationEnabled(false);
        node->SetTranslate(Eigen::Vector3f { home.x() + 96.0f, home.y(), home.z() });
        const auto moved = DrawOneFrame(render, *loaded.scene);
        EXPECT_EQ(moved.skipped, 0u) << "pixels were reused with the setting switched off";
        const auto away = ReadOutput(render, *loaded.scene);
        ASSERT_NE(away, at_home);

        // Back to where the recorded signature was taken, without drawing: the
        // target still holds the moved picture.
        node->SetTranslate(home);
        wallpaper::vulkan::SetSceneOptimizationEnabled(true);

        const auto resumed = DrawOneFrame(render, *loaded.scene);
        EXPECT_EQ(resumed.skipped, 0u)
            << "re-enabling reused a target whose pixels came from a frame drawn while it was off";
        EXPECT_EQ(ReadOutput(render, *loaded.scene), at_home)
            << "the first frame after re-enabling did not restore the picture its inputs describe";

        // And it records again from there.
        EXPECT_GT(DrawOneFrame(render, *loaded.scene).skipped, 0u)
            << "reuse never resumed after the setting was switched back on";

        render.destroy();
    }
}

TEST_F(MetalSceneDraw, AGraphCompiledWithTheOptimisationOffStartsReusingWhenItIsTurnedOn)
{
    // The asymmetry this removes: the reuse table, the copy plan and the target
    // table are all built while the graph is compiled, so a graph compiled with
    // the setting off used to carry no plan at all and turning the setting back
    // on did nothing until the wallpaper, the render scale or the app changed.
    // Nothing here recompiles the graph; the change is applied at a frame
    // boundary over the graph that is already running.
    wallpaper::vulkan::SetSceneOptimizationEnabled(false);
    const auto  project = WriteFixture(root_ / "project");
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "cache", loaded, error)) << error;

    @autoreleasepool {
        id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(640, 360);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 640,
            .height               = 360,
            .render_width         = 640,
            .render_height        = 360,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();

        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        // Compiled with the setting off: no reuse table exists at this point.
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
        render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);

        DrawOneFrame(render, *loaded.scene);
        EXPECT_EQ(DrawOneFrame(render, *loaded.scene).skipped, 0u)
            << "pixels were reused although the graph was compiled with the setting off";
        const auto drawn = ReadOutput(render, *loaded.scene);
        ASSERT_FALSE(drawn.empty());

        wallpaper::vulkan::SetSceneOptimizationEnabled(true);
        // The first frame after the change redraws: a table that has recorded
        // nothing cannot call anything unchanged, which is what stops stale
        // pixels being adopted.
        EXPECT_EQ(DrawOneFrame(render, *loaded.scene).skipped, 0u)
            << "the first frame after re-enabling reused pixels no plan had recorded";
        EXPECT_EQ(ReadOutput(render, *loaded.scene), drawn)
            << "re-applying the setting changed the picture";
        // And from there it reuses, without the graph having been compiled
        // again.
        EXPECT_GT(DrawOneFrame(render, *loaded.scene).skipped, 0u)
            << "re-enabling never produced a reuse plan for the running graph";

        render.destroy();
    }
}

// ---------------------------------------------------------------------------
// A real video layer, through the whole path.
//
// This is what makes the direct plane path more than a compiler feature: an
// ordinary author project whose material samples `g_Texture0`, a real decoded
// video behind that slot, the second program compiled by the parser from the
// same inputs as the first, the planes bound through the binding plan
// reflection produced, and the picture read back off the GPU. Nothing here is a
// test-only shader: the fragment source below is what the author wrote and it
// is what draws.

namespace
{

/// The media the fixtures name. 640x360, because the comparison below has to be
/// able to ask for a one-to-one mapping between video texels and output pixels.
constexpr uint32_t kVideoWidth  = 640;
constexpr uint32_t kVideoHeight = 360;

/// The same fixture shape as the cases above, with one video texture on slot 0
/// and a material that samples it the way an ordinary image layer does.
///
/// `canvas` sizes both the orthographic projection and the layer, so a fixture
/// at the media's own size maps one video texel onto one output pixel and a
/// smaller one exercises the scaled case.
std::filesystem::path WriteVideoFixture(const std::filesystem::path& root, uint32_t canvas_width,
                                        uint32_t canvas_height,
                                        std::optional<std::array<int32_t, 9>> display_matrix = std::nullopt)
{
    const std::string vertex =
        "uniform mat4 g_ModelViewProjectionMatrix;\n"
        "attribute vec3 a_Position;\n"
        "attribute vec2 a_TexCoord;\n"
        "varying vec2 v_TexCoord;\n"
        "void main() {\n"
        "  gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);\n"
        "  v_TexCoord = a_TexCoord;\n"
        "}\n";
    // A plain sample of the layer's own texture, which is what the large
    // majority of image-layer shaders do.
    const std::string fragment =
        "uniform sampler2D g_Texture0;\n"
        "varying vec2 v_TexCoord;\n"
        "void main() {\n"
        "  gl_FragColor = texture2D(g_Texture0, v_TexCoord);\n"
        "}\n";

    const std::string width  = std::to_string(canvas_width);
    const std::string height = std::to_string(canvas_height);
    const std::string origin_x = std::to_string(canvas_width / 2);
    const std::string origin_y = std::to_string(canvas_height / 2);

    const std::map<std::string, std::string> files {
        { "project.json",
          R"({"title":"Metal video draw","type":"scene","file":"layout.json","general":{"properties":{}}})" },
        { "models/tile.json",
          R"({"width":)" + width + R"(,"height":)" + height +
              R"(,"material":"materials/tile.json"})" },
        { "materials/tile.json",
          R"({"passes":[{"shader":"metal_video","blending":"normal","cullmode":"nocull",)"
          R"("depthtest":"disabled","depthwrite":"disabled","textures":["clip"]}]})" },
        { "shaders/metal_video.vert", vertex },
        { "shaders/metal_video.frag", fragment },
        { "layout.json",
          R"({"camera":{"center":[0,0,0],"eye":[0,0,1],"up":[0,1,0]},)"
          R"("general":{"ambientcolor":[0,0,0],"skylightcolor":[0,0,0],"clearcolor":[0.0,0.0,0.0],)"
          R"("cameraparallax":false,"orthogonalprojection":{"width":)" +
              width + R"(,"height":)" + height + R"(}},)"
          R"("objects":[{"id":1,"name":"tile","image":"models/tile.json","origin":[)" +
              origin_x + "," + origin_y + R"(,0],)"
          R"("scale":[1,1,1],"angles":[0,0,0],"visible":true}]})" },
    };

    for (const auto& [name, contents] : files) {
        const auto path = root / name;
        std::filesystem::create_directories(path.parent_path());
        std::ofstream(path) << contents;
    }
    // The media the material's texture slot names, encoded here rather than
    // shipped. `clip.mp4` is what the loose-asset resolver finds for "clip".
    std::filesystem::create_directories(root / "materials");
    if (! video::testing_media::WriteSyntheticVideo(root / "materials" / "clip.mp4", 1,
                                                    "metal-video-draw", display_matrix)) {
        return {};
    }
    return root / "project.json";
}

/// One offscreen native renderer over a compiled graph, at `width`x`height`.
struct VideoScene {
    LoadedScene     loaded;
    CAMetalLayer*   layer { nil };
    MetalRender     render;
    std::unique_ptr<rg::RenderGraph> graph;

    bool Draw() { return render.drawFrame(*loaded.scene); }

    std::vector<uint8_t> Read()
    {
        std::vector<uint8_t> pixels;
        uint32_t             width  = 0;
        uint32_t             height = 0;
        if (! render.ReadRenderTargetForTests(
                loaded.scene->ResolveRenderTargetName(SpecTex_Default), pixels, width, height)) {
            ADD_FAILURE() << "the scene output could not be read back";
        }
        return pixels;
    }
};

} // namespace

/// Restores the process-wide switch however a test leaves.
namespace
{
struct ScopedPlaneSampling {
    explicit ScopedPlaneSampling(bool enabled) { SetMetalVideoPlaneSamplingEnabled(enabled); }
    ~ScopedPlaneSampling() { SetMetalVideoPlaneSamplingEnabled(false); }
};
} // namespace

TEST_F(MetalSceneDraw, AVideoLayerSamplesTheDecoderPlanesThroughItsOwnShader)
{
    const auto project = WriteVideoFixture(root_ / "video-project", kVideoWidth, kVideoHeight);
    if (project.empty()) {
        GTEST_SKIP() << "no hardware H.264 encoder here, so no decodable media to parse";
    }
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "video-cache", loaded, error)) << error;

    auto* material = FirstMaterial(loaded.scene->sceneGraph.get());
    ASSERT_NE(material, nullptr);
    ASSERT_NE(material->customShader.shader, nullptr);
    const auto* program = material->customShader.shader->metal_program.get();
    ASSERT_NE(program, nullptr);
    ASSERT_TRUE(program->error.empty()) << program->error;

    // ---- 1. the parser captured what a second program would need, and
    // compiled nothing: loading a wallpaper must not pay for an optional
    // program before it has drawn a frame.
    ASSERT_TRUE(program->hasVideoPlaneCandidate())
        << "no plane variant was even possible for a single-video material";
    ASSERT_EQ(program->videoPlaneState(), SceneMetalVariantState::None)
        << "the optional program was compiled during the parse";

    // ---- 2. asked for, it is produced in the background from that snapshot
    std::string variant_error;
    ASSERT_TRUE(SettleVariantTranslation(*loaded.scene, &variant_error)) << variant_error;
    const auto variant = program->videoPlanes();
    ASSERT_NE(variant, nullptr);
    ASSERT_TRUE(variant->ok()) << "plane variant refused: " << variant->error;
    EXPECT_EQ(variant->slot, 0u);
    ASSERT_FALSE(variant->stages.empty());
    // A translation of the author's program, not a substitute for it.
    EXPECT_NE(variant->stages.front().source, program->stages.front().source);

    const auto selection = SelectSceneBackend(*loaded.scene);
    ASSERT_EQ(selection.backend, SceneBackend::NativeMetal) << selection.fallback_reason;

    // ---- 3. a real frame, drawn through the variant
    ScopedPlaneSampling sampling(true);

    @autoreleasepool {
        id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(kVideoWidth, kVideoHeight);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = kVideoWidth,
            .height               = kVideoHeight,
            .render_width         = kVideoWidth,
            .render_height        = kVideoHeight,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();

        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
        render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);

        for (int frame = 0; frame < 3; ++frame) {
            ASSERT_TRUE(render.drawFrame(*loaded.scene)) << render.lastError();
            loaded.scene->PassFrameTime(1.0 / 60.0);
        }
        // The optional pipeline is built off the frame thread, so the adoption
        // happens at the first boundary after it comes back rather than at the
        // first frame. A few more frames is what that looks like from here.
        DrawUntilVideoPath(render, *loaded.scene, SceneVideoPath::Nv12Direct);

        // ---- 4. the path the frame really took
        const auto path = render.VideoPath();
        if (path != SceneVideoPath::Nv12Direct) {
            // Software decode hands back BGRA, and the direct path is then not
            // applicable rather than broken. Reported rather than asserted
            // away, because a machine without VideoToolbox is a real one.
            GTEST_SKIP() << "the decoder produced " << SceneVideoPathName(path)
                         << " rather than NV12, so the direct path was not exercised";
        }

        std::vector<uint8_t> pixels;
        uint32_t             width  = 0;
        uint32_t             height = 0;
        ASSERT_TRUE(render.ReadRenderTargetForTests(
            loaded.scene->ResolveRenderTargetName(SpecTex_Default), pixels, width, height));
        ASSERT_EQ(pixels.size(), width * height * 4u);

        // The scene clears to black, so a frame carrying colour is a frame the
        // plane sample produced.
        std::size_t coloured = 0;
        for (std::size_t i = 0; i < pixels.size(); i += 4) {
            if (pixels[i] > 8 || pixels[i + 1] > 8 || pixels[i + 2] > 8) ++coloured;
        }
        EXPECT_GT(coloured, 1000u)
            << "the output holds nothing the plane sample could have produced";

        render.destroy();
    }
}

TEST_F(MetalSceneDraw, AVideoLayerKeepsConvertingWhileTheSettingIsOff)
{
    const auto project = WriteVideoFixture(root_ / "video-off-project", kVideoWidth, kVideoHeight);
    if (project.empty()) {
        GTEST_SKIP() << "no hardware H.264 encoder here, so no decodable media to parse";
    }
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "video-off-cache", loaded, error)) << error;

    // Default state, asserted rather than assumed: the material could have a
    // variant and, with the switch off, none is asked for at all.
    ScopedPlaneSampling sampling(false);
    auto* off_material = FirstMaterial(loaded.scene->sceneGraph.get());
    ASSERT_NE(off_material, nullptr);
    ASSERT_NE(off_material->customShader.shader, nullptr);
    const auto off_program = off_material->customShader.shader->metal_program;
    ASSERT_NE(off_program, nullptr);
    ASSERT_TRUE(off_program->hasVideoPlaneCandidate());

    @autoreleasepool {
        id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(kVideoWidth, kVideoHeight);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = kVideoWidth,
            .height               = kVideoHeight,
            .render_width         = kVideoWidth,
            .render_height        = kVideoHeight,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();
        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
        render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);
        for (int frame = 0; frame < 3; ++frame) {
            ASSERT_TRUE(render.drawFrame(*loaded.scene)) << render.lastError();
            loaded.scene->PassFrameTime(1.0 / 60.0);
        }

        const auto path = render.VideoPath();
        EXPECT_NE(path, SceneVideoPath::Nv12Direct)
            << "the switch is off and a material still sampled planes";
        EXPECT_NE(path, SceneVideoPath::Nv12Mixed);
        // Nothing was translated and nothing was built. This is the whole point
        // of the switch being off: it is not "compiled and unused", it is "not
        // compiled".
        EXPECT_EQ(off_program->videoPlaneState(), SceneMetalVariantState::None)
            << "an optional program was prepared although the switch was off";

        // And switching it on reaches a scene that is already running, without
        // the graph being compiled again. The wallpaper's own loop asks at a
        // frame boundary; this drives the renderer directly, so it asks here.
        SetMetalVideoPlaneSamplingEnabled(true);
        std::string variant_error;
        if (path == SceneVideoPath::Nv12Converted) {
            ASSERT_TRUE(SettleVariantTranslation(*loaded.scene, &variant_error)) << variant_error;
            EXPECT_TRUE(DrawUntilVideoPath(render, *loaded.scene, SceneVideoPath::Nv12Direct))
                << "a running scene never picked the setting up";
        }

        render.destroy();
    }
}

namespace
{

/// Draws one decoded frame twice -- once pre-converted, once sampled directly --
/// and returns the per-channel differences.
///
/// The frame is held by pausing playback, and the hold is proved rather than
/// assumed: two draws on the same path must reproduce each other before the
/// two paths are compared at all.
struct PathComparison {
    bool                 ran { false };
    bool                 unavailable { false };
    std::string          reason;
    std::vector<uint8_t> converted;
    std::vector<uint8_t> direct;
};

PathComparison CompareVideoPaths(const std::filesystem::path& project,
                                 const std::filesystem::path& cache, uint32_t canvas_width,
                                 uint32_t canvas_height)
{
    PathComparison result;
    LoadedScene    loaded;
    std::string    error;
    if (! LoadScene(project, cache, loaded, error)) {
        result.reason = error;
        return result;
    }

    @autoreleasepool {
        id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(canvas_width, canvas_height);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = static_cast<uint16_t>(canvas_width),
            .height               = static_cast<uint16_t>(canvas_height),
            .render_width         = static_cast<uint16_t>(canvas_width),
            .render_height        = static_cast<uint16_t>(canvas_height),
            .display_scale_factor = 1.0,
        };
        if (! render.init(info)) {
            result.reason = render.lastError();
            return result;
        }
        auto graph = sceneToRenderGraph(*loaded.scene);
        if (graph == nullptr || ! render.compileRenderGraph(*loaded.scene, *graph)) {
            result.reason = render.lastError();
            return result;
        }
        render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);

        const auto output = loaded.scene->ResolveRenderTargetName(SpecTex_Default);
        const auto read   = [&]() {
            std::vector<uint8_t> pixels;
            uint32_t             width  = 0;
            uint32_t             height = 0;
            render.ReadRenderTargetForTests(output, pixels, width, height);
            return pixels;
        };

        SetMetalVideoPlaneSamplingEnabled(false);
        for (int frame = 0; frame < 2; ++frame) {
            if (! render.drawFrame(*loaded.scene)) {
                result.reason = render.lastError();
                return result;
            }
            loaded.scene->PassFrameTime(1.0 / 60.0);
        }
        render.SetVideoPlaybackPaused(true);
        // Pausing stops the clock, but frames the decoder had already produced
        // still become current one at a time. The hold is therefore waited for
        // and then proved, rather than assumed after a fixed number of frames:
        // two consecutive draws reproducing each other exactly is the only
        // evidence that what follows compares one frame.
        std::vector<uint8_t> previous;
        bool                 held = false;
        for (int settle = 0; settle < 16 && ! held; ++settle) {
            if (! render.drawFrame(*loaded.scene)) {
                result.reason = render.lastError();
                return result;
            }
            auto current = read();
            held         = ! previous.empty() && current == previous;
            previous     = std::move(current);
        }
        if (! held) {
            result.reason = "the decoded frame never stopped advancing while paused";
            return result;
        }
        if (render.VideoPath() != SceneVideoPath::Nv12Converted) {
            result.unavailable = true;
            result.reason = std::string("the decoder produced ") +
                                 SceneVideoPathName(render.VideoPath()) +
                                 ", so there is no conversion to compare against";
            return result;
        }
        result.converted = std::move(previous);

        SetMetalVideoPlaneSamplingEnabled(true);
        std::string variant_error;
        if (! SettleVariantTranslation(*loaded.scene, &variant_error)) {
            result.reason = variant_error;
            return result;
        }
        // Without advancing the clock: the frame is held, and what is being
        // waited for is the optional pipeline, not a new picture.
        if (! DrawUntilVideoPath(render, *loaded.scene, SceneVideoPath::Nv12Direct)) {
            result.reason = "the running scene did not take the direct path";
            return result;
        }
        result.direct = read();
        result.ran    = result.converted.size() == result.direct.size() &&
                     ! result.converted.empty();
        if (! result.ran) result.reason = "video path readbacks are empty or have different sizes";
        render.destroy();
    }
    return result;
}

} // namespace

TEST_F(MetalSceneDraw, MissingProjectIsAComparisonFailureInsteadOfAPlatformSkip)
{
    const auto result = CompareVideoPaths(root_ / "missing" / "project.json", root_ / "cache", 16, 16);
    EXPECT_FALSE(result.ran);
    EXPECT_FALSE(result.unavailable);
    EXPECT_FALSE(result.reason.empty());
}

TEST_F(MetalSceneDraw, OneToOneSamplingProducesTheSamePictureOnBothPaths)
{
    // The equivalence claim, measured rather than asserted in prose: one decoded
    // frame, held still, drawn by the pre-converting program and then by the
    // plane-sampling one, at a size where one video texel maps to one output
    // pixel.
    //
    // One code value is the intermediate's own 8-bit quantisation, which the
    // direct path does not perform. Anything larger would be a real difference
    // in the picture.
    const auto project =
        WriteVideoFixture(root_ / "video-1to1-project", kVideoWidth, kVideoHeight);
    if (project.empty()) {
        GTEST_SKIP() << "no hardware H.264 encoder here, so no decodable media to parse";
    }
    ScopedPlaneSampling sampling(false);
    const auto comparison =
        CompareVideoPaths(project, root_ / "video-1to1-cache", kVideoWidth, kVideoHeight);
    if (comparison.unavailable) GTEST_SKIP() << comparison.reason;
    ASSERT_TRUE(comparison.ran) << comparison.reason;

    int worst = 0;
    for (std::size_t i = 0; i < comparison.converted.size(); ++i) {
        worst = std::max(worst, std::abs(static_cast<int>(comparison.converted[i]) -
                                          static_cast<int>(comparison.direct[i])));
    }
    EXPECT_LE(worst, 1) << "the two paths disagree by " << worst
                        << " code values at a one-to-one mapping";
}

TEST_F(MetalSceneDraw, DisplayMatricesProduceMatchingConvertedAndDirectVideoPictures)
{
    for (const auto& orientation : video::testing_media::kOrientations) {
        SCOPED_TRACE(orientation.name);
        const uint32_t width = orientation.swaps_axes ? kVideoHeight : kVideoWidth;
        const uint32_t height = orientation.swaps_axes ? kVideoWidth : kVideoHeight;
        const auto directory = root_ / orientation.name;
        const auto project = WriteVideoFixture(directory, width, height, orientation.matrix());
        if (project.empty()) GTEST_SKIP() << "no H.264 encoder is available";
        ScopedPlaneSampling sampling(false);
        const auto comparison = CompareVideoPaths(project, directory / "cache", width, height);
        if (comparison.unavailable) GTEST_SKIP() << comparison.reason;
        ASSERT_TRUE(comparison.ran) << comparison.reason;
        int worst = 0;
        for (size_t index = 0; index < comparison.converted.size(); ++index) {
            worst = std::max(worst, std::abs(int(comparison.converted[index]) - int(comparison.direct[index])));
        }
        EXPECT_LE(worst, 2);
    }
    const std::array<int32_t, 9> shear {65536, 0, 0, 32768, 65536, 0, 0, 0, 1 << 30};
    const auto transform = video::ResolveVideoDisplayTransform(shear, kVideoWidth, kVideoHeight);
    ASSERT_TRUE(transform.has_value());
    const auto project = WriteVideoFixture(root_ / "shear", transform->width, transform->height, shear);
    if (project.empty()) GTEST_SKIP() << "no H.264 encoder is available";
    ScopedPlaneSampling sampling(false);
    const auto comparison = CompareVideoPaths(project, root_ / "shear-cache", transform->width, transform->height);
    if (comparison.unavailable) GTEST_SKIP() << comparison.reason;
    ASSERT_TRUE(comparison.ran) << comparison.reason;
    int worst = 0;
    for (size_t index = 0; index < comparison.converted.size(); ++index) {
        worst = std::max(worst, std::abs(int(comparison.converted[index]) - int(comparison.direct[index])));
    }
    EXPECT_LE(worst, 2);
}

TEST_F(MetalSceneDraw, ScaledSamplingStaysInsideTheClampExcursionTheStreamImplies)
{
    // Where the layer is resampled, the two paths stop being identical, and the
    // reason is structural rather than numerical. The pre-converting path
    // clamps each texel to the stream's declared range and quantises it before
    // the author's sampler filters; the direct path filters first and clamps
    // the result. The transform between those two clamps is affine, so the two
    // orders agree exactly wherever the clamp does nothing -- which is every
    // sample a conforming stream carries.
    //
    // Where a stream does carry codes outside the range it declares, the two
    // orders disagree by at most the excursion the clamp removes. For 8-bit
    // limited range that is (255 - 235) / 219 * 255 = 23.3 code values at the
    // top and 16 / 219 * 255 = 18.6 at the bottom, so 24 bounds it. The
    // synthetic probe below is deliberately the worst case: full-range noise
    // carried in a stream that declares limited range, so roughly one texel in
    // seven clamps. Real content does not look like this, which is why the
    // one-to-one case above is the equivalence claim and this one is a bound.
    constexpr int kClampExcursionBound = 24;

    const auto project = WriteVideoFixture(root_ / "video-scaled-project", 384, 256);
    if (project.empty()) {
        GTEST_SKIP() << "no hardware H.264 encoder here, so no decodable media to parse";
    }
    ScopedPlaneSampling sampling(false);
    const auto comparison = CompareVideoPaths(project, root_ / "video-scaled-cache", 384, 256);
    if (comparison.unavailable) GTEST_SKIP() << comparison.reason;
    ASSERT_TRUE(comparison.ran) << comparison.reason;

    int       worst = 0;
    long long total = 0;
    for (std::size_t i = 0; i < comparison.converted.size(); ++i) {
        const int delta = std::abs(static_cast<int>(comparison.converted[i]) -
                                    static_cast<int>(comparison.direct[i]));
        worst = std::max(worst, delta);
        total += delta;
    }
    const double mean = static_cast<double>(total) /
                        static_cast<double>(comparison.converted.size());

    EXPECT_LE(worst, kClampExcursionBound)
        << "the two paths disagree by " << worst
        << " code values, which is more than the stream's own clamp can account for";
    // A colour, binding or coordinate fault would not stay near zero on
    // average, whatever it did to the worst pixel.
    EXPECT_LT(mean, 3.0) << "the two paths differ by " << mean
                         << " code values on average, which is a picture difference rather than "
                            "a clamp-order effect at the edges";
    RecordProperty("worst_delta", worst);
}

namespace
{

/// A project whose only layer is a text object, in the shape the editor's "add
/// text" writes: no model, no material, no author shader. Everything the layer
/// draws with -- the card, its texture and the program that samples it -- is
/// produced by the parser and the text system.
///
/// `text_json`, when given, replaces the quoted caption with the author's own
/// JSON for that field: `{"user":...}` for a layer the user's property drives,
/// `{"script":...}` for one that re-evaluates itself every tick.
std::filesystem::path WriteTextFixture(const std::filesystem::path& root, std::string_view text,
                                       bool with_effect = false,
                                       std::string_view text_json = {},
                                       std::string_view style_json = {})
{
    const std::string effects =
        with_effect ? R"(,"effects":[{"file":"effects/probe.json","visible":true}])" : "";
    const std::map<std::string, std::string> files {
        { "project.json",
          R"({"title":"Metal text smoke","type":"scene","file":"layout.json","general":{"properties":{"intensity":{"type":"slider","value":0.5}}}})" },
        // An effect chain over the text layer: the layer draws into a buffer,
        // the effect samples it, and the chain's final card -- a second mesh the
        // relayout rewrites -- draws the result.
        { "effects/probe.json",
          R"({"name":"probe copy","passes":[{"material":"materials/copy.json"}]})" },
        { "materials/copy.json",
          R"({"passes":[{"shader":"probe_copy","blending":"translucent","cullmode":"nocull",)"
          R"("depthtest":"disabled","depthwrite":"disabled","textures":[null]}]})" },
        { "shaders/probe_copy.vert",
          "uniform mat4 g_ModelViewProjectionMatrix;\n"
          "attribute vec3 a_Position;\n"
          "attribute vec2 a_TexCoord;\n"
          "varying vec2 v_TexCoord;\n"
          "void main() {\n"
          "  gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);\n"
          "  v_TexCoord = a_TexCoord;\n"
          "}\n" },
        { "shaders/probe_copy.frag",
          "uniform sampler2D g_Texture0;\n"
          "varying vec2 v_TexCoord;\n"
          "void main() {\n"
          "  gl_FragColor = texture(g_Texture0, v_TexCoord);\n"
          "}\n" },
        { "layout.json",
          R"({"camera":{"center":[0,0,0],"eye":[0,0,1],"up":[0,1,0]},)"
          R"("general":{"ambientcolor":[0,0,0],"skylightcolor":[0,0,0],"clearcolor":[0.0,0.0,0.0],)"
          R"("cameraparallax":false,"orthogonalprojection":{"width":384,"height":256}},)"
          R"("objects":[{"id":1,"name":"caption","text":)" +
              (text_json.empty() ? "\"" + std::string(text) + "\"" : std::string(text_json)) +
              R"(,"font":"Arial","pointsize":48,"origin":[192,128,0],)"
              R"("scale":[1,1,1],"angles":[0,0,0],"visible":true)" + effects +
              std::string(style_json) + R"(}]})" },
    };

    for (const auto& [name, contents] : files) {
        const auto path = root / name;
        std::filesystem::create_directories(path.parent_path());
        std::ofstream(path) << contents;
    }
    return root / "project.json";
}

/// How many pixels carry colour, which is the only thing that distinguishes
/// "the glyphs were drawn" from "the pass ran".
///
/// Colour, not alpha: a cleared opaque black target has alpha everywhere and
/// would satisfy a test that counted it.
std::size_t LitPixels(const std::vector<uint8_t>& rgba)
{
    std::size_t lit = 0;
    for (std::size_t i = 0; i + 3 < rgba.size(); i += 4) {
        if (rgba[i] != 0 || rgba[i + 1] != 0 || rgba[i + 2] != 0) ++lit;
    }
    return lit;
}

/// Exactly what `SceneWallpaper::evaluateSceneUpdateDemand` ORs to decide
/// whether a scene may stop its clock, assembled from the same two halves so
/// this can be asked without a frame clock, a looper or a surface.
uint32_t SceneDemand(MetalRender& render, Scene& scene)
{
    uint32_t reasons = SceneDemandReasonsFromShaderInputs(render.ShaderUpdateDemandReasons());
    if (scene.runtime != nullptr) reasons |= scene.runtime->DescribeTimeAdvancingWork();
    return reasons;
}

/// One production frame: the runtime tick and the text pump the wallpaper's own
/// loop runs, then the draw.
void AdvanceSceneFrame(MetalRender& render, Scene& scene)
{
    if (scene.runtime != nullptr) {
        scene.runtime->Tick(1.0 / 60.0);
        scene.runtime->PumpTextLayerCache();
    }
    // The host's per-frame step, as `SceneWallpaper`'s draw does it.
    if (scene.shaderValueUpdater != nullptr) scene.shaderValueUpdater->FrameBegin();
    EXPECT_TRUE(render.drawFrame(scene)) << render.lastError();
    scene.PassFrameTime(1.0 / 60.0);
}

} // namespace

TEST_F(MetalSceneDraw, TextStylingChangesPixelsWithoutRerasterizingGlyphs)
{
    for (const bool with_effect : { false, true }) {
        SCOPED_TRACE(with_effect);
        const auto project = WriteTextFixture(
            root_ / (with_effect ? "styled-effect" : "styled-text"), "FADE", with_effect, {},
            R"(,"alpha":{"value":1,"script":"export function update() { return engine.runtime < 0.5 ? 1 : engine.runtime < 1 ? 0.5 : 0; }"},)"
            R"("color":{"value":"1 0 0","script":"export function update() { return engine.runtime < 0.5 ? new Vec3(1,0,0) : new Vec3(0,0,1); }"},)"
            R"("brightness":{"value":0.5,"user":"intensity"})");
        LoadedScene loaded;
        std::string error;
        ASSERT_TRUE(LoadScene(project, root_ / "style-cache", loaded, error)) << error;
        @autoreleasepool {
            id<MTLDevice> device = MTLCreateSystemDefaultDevice();
            CAMetalLayer* layer = [CAMetalLayer layer];
            layer.device = device;
            layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
            layer.drawableSize = CGSizeMake(384, 256);
            MetalRender render;
            MetalRenderInitInfo info {
                .metal_layer = (__bridge void*)layer,
                .width = 384, .height = 256, .render_width = 384, .render_height = 256,
                .display_scale_factor = 1.0,
            };
            ASSERT_TRUE(render.init(info)) << render.lastError();
            auto graph = sceneToRenderGraph(*loaded.scene);
            ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
            render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);
            for (int frame = 0; frame < 8; ++frame) AdvanceSceneFrame(render, *loaded.scene);
            const auto peak = [](const std::vector<uint8_t>& pixels, std::size_t channel) {
                uint8_t value = 0;
                for (std::size_t i = channel; i < pixels.size(); i += 4)
                    value = std::max(value, pixels[i]);
                return value;
            };
            const auto red = ReadOutput(render, *loaded.scene);
            EXPECT_NEAR(peak(red, 0), 128, 2);
            EXPECT_EQ(peak(red, 2), 0);
            const auto uploads = render.RuntimeImageUploadsForTests();
            ResetTextLayerMeasurementCountForTests();
            loaded.scene->runtime->ApplyProjectPropertyOverride({
                { "intensity", RuntimeScalarValue::Float(1.0f) },
            });
            loaded.scene->runtime->Tick(0.5);
            ASSERT_TRUE(render.drawFrame(*loaded.scene)) << render.lastError();
            const auto blue = ReadOutput(render, *loaded.scene);
            EXPECT_EQ(peak(blue, 0), 0);
            EXPECT_NEAR(peak(blue, 2), 128, 2);
            loaded.scene->runtime->Tick(0.5);
            ASSERT_TRUE(render.drawFrame(*loaded.scene)) << render.lastError();
            EXPECT_EQ(LitPixels(ReadOutput(render, *loaded.scene)), 0u);
            EXPECT_EQ(render.RuntimeImageUploadsForTests(), uploads);
            EXPECT_EQ(TextLayerMeasurementCountForTests(), 0u);
            EXPECT_EQ(loaded.scene->runtime->scriptErrorCount(), 0u);
            render.destroy();
        }
    }
}

TEST_F(MetalSceneDraw, ATextLayerIsParsedTranslatedAndDrawnByTheNativeBackend)
{
    // The whole chain for a text layer, through the ordinary parser and the
    // production graph lowering: the card the runtime rewrites is accepted, the
    // text program is translated to Metal, the rasterised glyphs are imported as
    // an ordinary image and the layer reaches the scene's own output.
    const auto  project = WriteTextFixture(root_ / "text-project", "HELLO");
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "cache", loaded, error)) << error;
    ASSERT_NE(loaded.scene->runtime, nullptr);

    const auto selection = SelectSceneBackend(*loaded.scene);
    ASSERT_EQ(selection.backend, SceneBackend::NativeMetal) << selection.fallback_reason;

    @autoreleasepool {
        id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(384, 256);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 384,
            .height               = 256,
            .render_width         = 384,
            .render_height        = 256,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();

        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
        render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);

        for (int frame = 0; frame < 3; ++frame) AdvanceSceneFrame(render, *loaded.scene);

        const auto drawn = ReadOutput(render, *loaded.scene);
        ASSERT_FALSE(drawn.empty());
        EXPECT_GT(LitPixels(drawn), 0u)
            << "the text layer produced no pixels in the scene's own target";

        // A layer whose picture the runtime replaces must keep the clock
        // running, or a text that changes would never be redrawn.
        EXPECT_TRUE(render.ShaderUpdateDemandReasons() &
                    wallpaper::vulkan::DynamicReason::RuntimeImage)
            << "a runtime-replaced image was not reported as a reason to keep drawing";

        render.destroy();
    }
}

namespace
{

/// A hidden text layer another layer samples: the marquee's card covers the
/// canvas and shows the title's composite across all of it. The title sits in
/// a corner of the canvas, so a composite that held it where it sits on screen
/// would show it there, small, instead of across the marquee.
std::filesystem::path WriteSampledTextFixture(const std::filesystem::path& root, bool with_effect)
{
    const auto project = WriteTextFixture(root, "HELLO", with_effect);
    const std::string effects =
        with_effect ? R"(,"effects":[{"file":"effects/probe.json","visible":true}])" : "";
    const std::map<std::string, std::string> files {
        { "models/marquee.json", R"({"width":384,"height":256,"material":"materials/marquee.json"})" },
        { "materials/marquee.json",
          R"({"passes":[{"shader":"probe_copy","blending":"translucent","cullmode":"nocull",)"
          R"("depthtest":"disabled","depthwrite":"disabled",)"
          R"("textures":["_rt_imageLayerComposite_1_a"]}]})" },
        { "layout.json",
          R"({"camera":{"center":[0,0,0],"eye":[0,0,1],"up":[0,1,0]},)"
          R"("general":{"ambientcolor":[0,0,0],"skylightcolor":[0,0,0],"clearcolor":[0.0,0.0,0.0],)"
          R"("cameraparallax":false,"orthogonalprojection":{"width":384,"height":256}},)"
          R"("objects":[{"id":1,"name":"title","text":"HELLO","font":"Arial","pointsize":24,)"
          R"("padding":0,"origin":[60,220,0],"visible":false)" + effects + R"(},)"
          R"({"id":2,"name":"marquee","image":"models/marquee.json","origin":[192,128,0],)"
          R"("dependencies":[1]}]})" },
    };
    for (const auto& [name, contents] : files) {
        const auto path = root / name;
        std::filesystem::create_directories(path.parent_path());
        std::ofstream(path) << contents;
    }
    return project;
}

} // namespace

// A hidden text layer another layer samples was never drawn into a composite
// on the native backend (nothing marked it as one that must produce), and,
// visible, it would have been drawn where it sits on screen rather than as its
// own card: the marquee showed nothing.
TEST_F(MetalSceneDraw, AHiddenTextLayerAnotherSamplesIsItsCardInItsComposite)
{
    for (const bool with_effect : { false, true }) {
        SCOPED_TRACE(with_effect ? "with an effect" : "plain");
        const auto  directory = root_ / (with_effect ? "sampled-text-effect" : "sampled-text");
        const auto  project   = WriteSampledTextFixture(directory, with_effect);
        LoadedScene loaded;
        std::string error;
        ASSERT_TRUE(LoadScene(project, directory / "cache", loaded, error)) << error;
        auto& scene = *loaded.scene;
        ASSERT_TRUE(scene.layer_texture_error.empty()) << scene.layer_texture_error;
        const auto selection = SelectSceneBackend(scene);
        ASSERT_EQ(selection.backend, SceneBackend::NativeMetal) << selection.fallback_reason;

        @autoreleasepool {
            CAMetalLayer* layer = [CAMetalLayer layer];
            layer.device        = MTLCreateSystemDefaultDevice();
            layer.pixelFormat   = MTLPixelFormatBGRA8Unorm;
            layer.drawableSize  = CGSizeMake(384, 256);
            MetalRender render;
            ASSERT_TRUE(render.init(MetalRenderInitInfo {
                .metal_layer = (__bridge void*)layer, .width = 384, .height = 256,
                .render_width = 384, .render_height = 256, .display_scale_factor = 1.0,
            }));
            auto graph = sceneToRenderGraph(scene);
            ASSERT_NE(graph, nullptr);
            ASSERT_TRUE(render.compileRenderGraph(scene, *graph)) << render.lastError();
            render.UpdateCameraFillMode(scene, FillMode::ASPECTFIT);
            for (int frame = 0; frame < 3; ++frame) AdvanceSceneFrame(render, scene);

            const auto pixels = ReadOutput(render, scene);
            ASSERT_EQ(pixels.size(), 384u * 256u * 4u);
            uint32_t left = 384, right = 0, bottom = 0, top = 256;
            for (uint32_t y = 0; y < 256; ++y) {
                for (uint32_t x = 0; x < 384; ++x) {
                    const auto* pixel = &pixels[(y * 384 + x) * 4];
                    if (pixel[0] == 0 && pixel[1] == 0 && pixel[2] == 0) continue;
                    left   = std::min(left, x);
                    right  = std::max(right, x);
                    top    = std::min(top, y);
                    bottom = std::max(bottom, y);
                }
            }
            ASSERT_GT(LitPixels(pixels), 0u) << "the marquee found nothing in the title's composite";
            // The title's card fills its composite, so its glyphs stretch from
            // one side of the marquee to the other, and sit across its middle.
            EXPECT_LT(left, 384u / 8u);
            EXPECT_GT(right, 384u * 7u / 8u);
            EXPECT_LT(top, 256u / 2u);
            EXPECT_GT(bottom, 256u / 2u);
            render.destroy();
        }
    }
}

namespace
{

/// One card of one colour in the middle of the canvas, with `effects`: each
/// `effects/own/effect.json` shows what it reads with red and blue swapped.
std::filesystem::path WriteOwnBufferFixture(const std::filesystem::path& root,
                                            const std::string&           effects)
{
    const auto project = WriteFixture(root);
    const std::string vertex =
        "uniform mat4 g_ModelViewProjectionMatrix;\n"
        "attribute vec3 a_Position;\nattribute vec2 a_TexCoord;\n"
        "varying vec2 v_TexCoord;\n"
        "void main(){ gl_Position=g_ModelViewProjectionMatrix*vec4(a_Position,1.0);"
        "v_TexCoord=a_TexCoord; }\n";
    const std::map<std::string, std::string> files {
        { "models/card.json", R"({"width":128,"height":64,"material":"materials/card.json"})" },
        { "materials/card.json",
          R"({"passes":[{"shader":"own_fill","blending":"translucent","cullmode":"nocull",)"
          R"("depthtest":"disabled","depthwrite":"disabled"}]})" },
        { "effects/own/effect.json",
          R"({"name":"own","passes":[{"material":"materials/own.json"}]})" },
        { "materials/own.json",
          R"({"passes":[{"shader":"own_swap","blending":"translucent","cullmode":"nocull",)"
          R"("depthtest":"disabled","depthwrite":"disabled","textures":[null]}]})" },
        { "shaders/own_fill.vert", vertex },
        { "shaders/own_fill.frag",
          "varying vec2 v_TexCoord;\n"
          "void main(){ gl_FragColor=vec4(0.25,0.5,0.75,1.0); }\n" },
        { "shaders/own_swap.vert", vertex },
        { "shaders/own_swap.frag",
          "uniform sampler2D g_Texture0;\nvarying vec2 v_TexCoord;\n"
          "void main(){ vec4 own=texture(g_Texture0,v_TexCoord);"
          "gl_FragColor=vec4(own.bgr,own.a); }\n" },
        { "layout.json",
          R"({"camera":{"center":[0,0,0],"eye":[0,0,1],"up":[0,1,0]},)"
          R"("general":{"ambientcolor":[0,0,0],"skylightcolor":[0,0,0],"clearcolor":[0.0,0.0,0.0],)"
          R"("cameraparallax":false,"orthogonalprojection":{"width":384,"height":256}},)"
          R"("objects":[{"id":1,"name":"card","image":"models/card.json","origin":[192,128,0],)"
          R"("effects":)" + effects + "}]}" },
    };
    for (const auto& [name, contents] : files) {
        const auto path = root / name;
        std::filesystem::create_directories(path.parent_path());
        std::ofstream(path) << contents;
    }
    return project;
}

} // namespace

// An effect binding its own layer's `_a` composite read a link the frame had
// yet to fill: the layer drew nothing, and the native backend refused the whole
// scene as history feedback. Inside the layer's chain the name is the image the
// effect works on.
TEST_F(MetalSceneDraw, ALayersOwnEffectReadsItsBufferANotItsComposite)
{
    {
        SCOPED_TRACE("image");
        const auto  directory = root_ / "own-buffer-a";
        // The card's own `_a` composite where the effect would take `previous`.
        const auto  project   = WriteOwnBufferFixture(
            directory, R"([{"file":"effects/own/effect.json","visible":true,)"
                       R"("passes":[{"textures":["_rt_imageLayerComposite_1_a"]}]}])");
        LoadedScene loaded;
        std::string error;
        ASSERT_TRUE(LoadScene(project, directory / "cache", loaded, error)) << error;
        auto& scene = *loaded.scene;
        ASSERT_TRUE(scene.layer_texture_error.empty()) << scene.layer_texture_error;
        const auto selection = SelectSceneBackend(scene);
        ASSERT_EQ(selection.backend, SceneBackend::NativeMetal) << selection.fallback_reason;
        const auto graph = sceneToRenderGraph(scene);
        ASSERT_NE(graph, nullptr);

        @autoreleasepool {
            CAMetalLayer* layer = [CAMetalLayer layer];
            layer.device        = MTLCreateSystemDefaultDevice();
            layer.pixelFormat   = MTLPixelFormatBGRA8Unorm;
            layer.drawableSize  = CGSizeMake(384, 256);
            MetalRender render;
            ASSERT_TRUE(render.init(MetalRenderInitInfo {
                .metal_layer = (__bridge void*)layer, .width = 384, .height = 256,
                .render_width = 384, .render_height = 256, .display_scale_factor = 1.0,
            }));
            ASSERT_TRUE(render.compileRenderGraph(scene, *graph)) << render.lastError();
            ASSERT_TRUE(render.drawFrame(scene)) << render.lastError();
            std::vector<uint8_t> bytes;
            std::vector<float>   radiance;
            uint32_t             width = 0, height = 0;
            ASSERT_TRUE(render.ReadRenderTargetForTests(
                scene.ResolveRenderTargetName(SpecTex_Default), bytes, width, height, &radiance));
            ASSERT_EQ(width, 384u);
            ASSERT_EQ(height, 256u);
            const auto expect_color = [&](uint32_t x, uint32_t y, std::array<float, 3> expected) {
                const size_t pixel = (y * width + x) * 4;
                for (size_t channel = 0; channel < 3; ++channel) {
                    EXPECT_NEAR(radiance[pixel + channel], expected[channel], 0.01f)
                        << "pixel " << x << "," << y << " channel " << channel;
                }
            };
            // The card as its effect saw it, and nothing around it.
            expect_color(192, 128, { 0.75f, 0.5f, 0.25f });
            expect_color(140, 100, { 0.75f, 0.5f, 0.25f });
            expect_color(32, 32, { 0.0f, 0.0f, 0.0f });
            render.destroy();
        }
    }
    {
        SCOPED_TRACE("text");
        const auto  directory = root_ / "own-buffer-a-text";
        const auto  project   = WriteTextFixture(
            directory, "HELLO", false, {},
            R"(,"effects":[{"file":"effects/probe.json","visible":true,)"
            R"("passes":[{"textures":["_rt_imageLayerComposite_1_a"]}]}])");
        LoadedScene loaded;
        std::string error;
        ASSERT_TRUE(LoadScene(project, directory / "cache", loaded, error)) << error;
        auto& scene = *loaded.scene;
        ASSERT_TRUE(scene.layer_texture_error.empty()) << scene.layer_texture_error;
        const auto selection = SelectSceneBackend(scene);
        ASSERT_EQ(selection.backend, SceneBackend::NativeMetal) << selection.fallback_reason;

        @autoreleasepool {
            CAMetalLayer* layer = [CAMetalLayer layer];
            layer.device        = MTLCreateSystemDefaultDevice();
            layer.pixelFormat   = MTLPixelFormatBGRA8Unorm;
            layer.drawableSize  = CGSizeMake(384, 256);
            MetalRender render;
            ASSERT_TRUE(render.init(MetalRenderInitInfo {
                .metal_layer = (__bridge void*)layer, .width = 384, .height = 256,
                .render_width = 384, .render_height = 256, .display_scale_factor = 1.0,
            }));
            auto graph = sceneToRenderGraph(scene);
            ASSERT_NE(graph, nullptr);
            ASSERT_TRUE(render.compileRenderGraph(scene, *graph)) << render.lastError();
            render.UpdateCameraFillMode(scene, FillMode::ASPECTFIT);
            for (int frame = 0; frame < 3; ++frame) AdvanceSceneFrame(render, scene);
            EXPECT_GT(LitPixels(ReadOutput(render, scene)), 0u)
                << "the text layer's effect showed nothing of the text";
            render.destroy();
        }
    }
}

// The editor names `previous`'s ping-pong buffer in the slot `previous` fills,
// `_a` and `_b` alternating along the chain, so a second effect names `_b`.
// Taken as last-frame history, the name made the native backend refuse the
// whole scene; it is the image the effect works on, the first effect's output.
TEST_F(MetalSceneDraw, ALayersOwnEffectReadsItsBufferBAsTheImageItWorksOn)
{
    const std::string effects =
        R"([{"file":"effects/own/effect.json","visible":true,)"
        R"("passes":[{"textures":["_rt_imageLayerComposite_1_a"]}]},)"
        R"({"file":"effects/own/effect.json","visible":true,)"
        R"("passes":[{"textures":["_rt_imageLayerComposite_1_b"]}]}])";
    {
        SCOPED_TRACE("image");
        const auto  directory = root_ / "own-buffer-b";
        const auto  project   = WriteOwnBufferFixture(directory, effects);
        LoadedScene loaded;
        std::string error;
        ASSERT_TRUE(LoadScene(project, directory / "cache", loaded, error)) << error;
        auto& scene = *loaded.scene;
        ASSERT_TRUE(scene.layer_texture_error.empty()) << scene.layer_texture_error;
        const auto selection = SelectSceneBackend(scene);
        ASSERT_EQ(selection.backend, SceneBackend::NativeMetal) << selection.fallback_reason;
        const auto graph = sceneToRenderGraph(scene);
        ASSERT_NE(graph, nullptr);

        @autoreleasepool {
            CAMetalLayer* layer = [CAMetalLayer layer];
            layer.device        = MTLCreateSystemDefaultDevice();
            layer.pixelFormat   = MTLPixelFormatBGRA8Unorm;
            layer.drawableSize  = CGSizeMake(384, 256);
            MetalRender render;
            ASSERT_TRUE(render.init(MetalRenderInitInfo {
                .metal_layer = (__bridge void*)layer, .width = 384, .height = 256,
                .render_width = 384, .render_height = 256, .display_scale_factor = 1.0,
            }));
            ASSERT_TRUE(render.compileRenderGraph(scene, *graph)) << render.lastError();
            ASSERT_TRUE(render.drawFrame(scene)) << render.lastError();
            std::vector<uint8_t> bytes;
            std::vector<float>   radiance;
            uint32_t             width = 0, height = 0;
            ASSERT_TRUE(render.ReadRenderTargetForTests(
                scene.ResolveRenderTargetName(SpecTex_Default), bytes, width, height, &radiance));
            ASSERT_EQ(width, 384u);
            ASSERT_EQ(height, 256u);
            const auto expect_color = [&](uint32_t x, uint32_t y, std::array<float, 3> expected) {
                const size_t pixel = (y * width + x) * 4;
                for (size_t channel = 0; channel < 3; ++channel) {
                    EXPECT_NEAR(radiance[pixel + channel], expected[channel], 0.01f)
                        << "pixel " << x << "," << y << " channel " << channel;
                }
            };
            // Swapped twice: the second effect swapped back what the first made.
            // Reading the card before any effect would leave it swapped, and an
            // empty texture black.
            expect_color(192, 128, { 0.25f, 0.5f, 0.75f });
            expect_color(140, 100, { 0.25f, 0.5f, 0.75f });
            expect_color(32, 32, { 0.0f, 0.0f, 0.0f });
            render.destroy();
        }
    }
    {
        SCOPED_TRACE("text");
        const auto  directory = root_ / "own-buffer-b-text";
        const auto  project   = WriteTextFixture(
            directory, "HELLO", false, {},
            R"(,"effects":[{"file":"effects/probe.json","visible":true,)"
            R"("passes":[{"textures":["_rt_imageLayerComposite_1_a"]}]},)"
            R"({"file":"effects/probe.json","visible":true,)"
            R"("passes":[{"textures":["_rt_imageLayerComposite_1_b"]}]}])");
        LoadedScene loaded;
        std::string error;
        ASSERT_TRUE(LoadScene(project, directory / "cache", loaded, error)) << error;
        auto& scene = *loaded.scene;
        ASSERT_TRUE(scene.layer_texture_error.empty()) << scene.layer_texture_error;
        const auto selection = SelectSceneBackend(scene);
        ASSERT_EQ(selection.backend, SceneBackend::NativeMetal) << selection.fallback_reason;

        @autoreleasepool {
            CAMetalLayer* layer = [CAMetalLayer layer];
            layer.device        = MTLCreateSystemDefaultDevice();
            layer.pixelFormat   = MTLPixelFormatBGRA8Unorm;
            layer.drawableSize  = CGSizeMake(384, 256);
            MetalRender render;
            ASSERT_TRUE(render.init(MetalRenderInitInfo {
                .metal_layer = (__bridge void*)layer, .width = 384, .height = 256,
                .render_width = 384, .render_height = 256, .display_scale_factor = 1.0,
            }));
            auto graph = sceneToRenderGraph(scene);
            ASSERT_NE(graph, nullptr);
            ASSERT_TRUE(render.compileRenderGraph(scene, *graph)) << render.lastError();
            render.UpdateCameraFillMode(scene, FillMode::ASPECTFIT);
            for (int frame = 0; frame < 3; ++frame) AdvanceSceneFrame(render, scene);
            EXPECT_GT(LitPixels(ReadOutput(render, scene)), 0u)
                << "the text layer's second effect showed nothing of the text";
            render.destroy();
        }
    }
}

TEST_F(MetalSceneDraw, TextThatHasNotChangedIsNeitherLaidOutNorUploadedAgain)
{
    // The round's optimisation, stated as what must NOT happen: the scripts and
    // the runtime keep running every frame, and the same string must still cost
    // no measurement, no rasterisation and no texture upload. Then a real change
    // must cost exactly those, once.
    const auto  project = WriteTextFixture(root_ / "text-repeat-project", "12:30");
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "cache", loaded, error)) << error;
    ASSERT_NE(loaded.scene->runtime, nullptr);
    ASSERT_EQ(SelectSceneBackend(*loaded.scene).backend, SceneBackend::NativeMetal);

    @autoreleasepool {
        id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(384, 256);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 384,
            .height               = 256,
            .render_width         = 384,
            .render_height        = 256,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();

        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
        render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);

        // Settle: the first layout is prepared on the text worker, so the
        // uploads it produces belong to start-up rather than to steady state.
        for (int frame = 0; frame < 8; ++frame) AdvanceSceneFrame(render, *loaded.scene);
        const auto settled         = ReadOutput(render, *loaded.scene);
        const auto settled_uploads = render.RuntimeImageUploadsForTests();
        ResetTextLayerMeasurementCountForTests();

        for (int frame = 0; frame < 12; ++frame) AdvanceSceneFrame(render, *loaded.scene);
        EXPECT_EQ(render.RuntimeImageUploadsForTests(), settled_uploads)
            << "an unchanged text was uploaded to the GPU again";
        EXPECT_EQ(TextLayerMeasurementCountForTests(), 0u)
            << "an unchanged text was measured and laid out again";
        EXPECT_EQ(ReadOutput(render, *loaded.scene), settled);

        // The same layer, a different string: the work that was skipped above
        // has to happen now, and the picture has to change with it.
        ASSERT_TRUE(loaded.scene->runtime->SetNodeText("caption", "12:31"));
        std::vector<uint8_t> changed;
        for (int frame = 0; frame < 16; ++frame) {
            AdvanceSceneFrame(render, *loaded.scene);
            changed = ReadOutput(render, *loaded.scene);
            if (changed != settled) break;
        }
        EXPECT_NE(changed, settled) << "a new string never reached the drawn picture";
        const auto changed_uploads = render.RuntimeImageUploadsForTests();
        EXPECT_GT(changed_uploads, settled_uploads);
        // One write per in-flight slot at most: new pixels go into the storage
        // the frame owns, never into an image a queued command buffer reads.
        EXPECT_LE(changed_uploads - settled_uploads, 2u)
            << "one text change caused more uploads than there are frames in flight";

        // And back to quiet: once every in-flight slot holds the new picture,
        // the new string is the unchanged one and costs nothing again.
        for (int frame = 0; frame < 4; ++frame) AdvanceSceneFrame(render, *loaded.scene);
        const auto quiet_uploads = render.RuntimeImageUploadsForTests();
        for (int frame = 0; frame < 12; ++frame) AdvanceSceneFrame(render, *loaded.scene);
        EXPECT_EQ(render.RuntimeImageUploadsForTests(), quiet_uploads)
            << "a text that had already settled kept uploading";

        render.destroy();
    }
}

TEST_F(MetalSceneDraw, TheSameProgramIsCompiledOnceAndReusedByTheNextSurface)
{
    // Two renderers, the same wallpaper, one device. The second one must find
    // the translated program already compiled: a second surface showing what is
    // already on screen is the ordinary case -- the lock screen beside the
    // desktop, a preview beside the wallpaper -- and paying the Metal compiler
    // again for the identical source is pure duplicated work.
    // A constant no other fixture uses, so the first load below is a genuine
    // cold compile rather than a hit left by an earlier test in this process.
    const auto project = WriteFixture(root_ / "reuse-project", "0.3125");

    const auto draw_once = [&](const std::filesystem::path& cache) {
        LoadedScene loaded;
        std::string error;
        EXPECT_TRUE(LoadScene(project, cache, loaded, error)) << error;
        if (loaded.scene == nullptr) return;

        @autoreleasepool {
            id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
            CAMetalLayer* layer   = [CAMetalLayer layer];
            layer.device          = device;
            layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
            layer.drawableSize    = CGSizeMake(384, 256);
            layer.framebufferOnly = NO;

            MetalRender         render;
            MetalRenderInitInfo info {
                .metal_layer          = (__bridge void*)layer,
                .width                = 384,
                .height               = 256,
                .render_width         = 384,
                .render_height        = 256,
                .display_scale_factor = 1.0,
            };
            ASSERT_TRUE(render.init(info)) << render.lastError();
            auto graph = sceneToRenderGraph(*loaded.scene);
            ASSERT_NE(graph, nullptr);
            ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
            render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);
            ASSERT_TRUE(render.drawFrame(*loaded.scene)) << render.lastError();
            render.destroy();
        }
    };

    const auto before_first = MetalRender::ProgramCompilesForTests();
    draw_once(root_ / "reuse-cache-a");
    const auto after_first = MetalRender::ProgramCompilesForTests();
    // The first one has to compile something, or the comparison below would be
    // satisfied by a counter nothing increments.
    ASSERT_GT(after_first, before_first)
        << "nothing was handed to the Metal compiler, so nothing could be reused";

    draw_once(root_ / "reuse-cache-b");
    EXPECT_EQ(MetalRender::ProgramCompilesForTests(), after_first)
        << "the same translated program was compiled by Metal a second time";
}

TEST_F(MetalSceneDraw, ATextLayerWithAnEffectChainKeepsBothOfItsCards)
{
    // A text layer with effects has more than one mesh the relayout rewrites:
    // its own card, the chain's final card, and the node the chain resolves its
    // last pass onto. All three are the same four-corner shape, and the gate has
    // to accept all three or the scene falls back as a whole.
    const auto  project = WriteTextFixture(root_ / "text-effect-project", "EFFECT", true);
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "text-effect-cache", loaded, error)) << error;
    ASSERT_NE(loaded.scene->runtime, nullptr);

    const auto selection = SelectSceneBackend(*loaded.scene);
    ASSERT_EQ(selection.backend, SceneBackend::NativeMetal) << selection.fallback_reason;

    @autoreleasepool {
        id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(384, 256);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 384,
            .height               = 256,
            .render_width         = 384,
            .render_height        = 256,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();

        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
        render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);

        for (int frame = 0; frame < 4; ++frame) AdvanceSceneFrame(render, *loaded.scene);
        const auto drawn = ReadOutput(render, *loaded.scene);
        ASSERT_FALSE(drawn.empty());
        EXPECT_GT(LitPixels(drawn), 0u)
            << "the text layer's effect chain produced no pixels in the scene's own target";
        // And the chain's cards follow a relayout rather than keeping the size
        // the first frame was built at. Different glyphs, not more of the same
        // word: the chain draws into a buffer the layer's card is clipped to,
        // and a longer repetition can leave exactly the same pixels inside it.
        ASSERT_TRUE(loaded.scene->runtime->SetNodeText("caption", "WOVEN"));
        std::vector<uint8_t> changed;
        for (int frame = 0; frame < 16; ++frame) {
            AdvanceSceneFrame(render, *loaded.scene);
            changed = ReadOutput(render, *loaded.scene);
            if (changed != drawn) break;
        }
        EXPECT_NE(changed, drawn) << "a relayout never reached the effect chain's output";

        render.destroy();
    }
}

namespace
{

/// Draws until the scene reports it has nothing left to do, or gives up.
///
/// Bounded on purpose: "eventually quiet" is the claim, and a test that spun
/// forever would turn a scene that never settles into a hang rather than a
/// failure.
bool SettleSceneDemand(MetalRender& render, Scene& scene, int max_frames = 120)
{
    for (int frame = 0; frame < max_frames; ++frame) {
        AdvanceSceneFrame(render, scene);
        if (SceneDemand(render, scene) == 0) return true;
    }
    return false;
}

} // namespace

TEST_F(MetalSceneDraw, AStaticTextSceneRunsOutOfWorkToDo)
{
    // The round's point, stated as the scene's own answer: a text layer whose
    // caption is fixed has nothing that advances on its own, so the wallpaper
    // may stop its clock entirely rather than merely stop uploading.
    const auto  project = WriteTextFixture(root_ / "static-text-idle", "HELLO");
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "static-text-idle-cache", loaded, error)) << error;
    ASSERT_NE(loaded.scene->runtime, nullptr);

    @autoreleasepool {
        id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(384, 256);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 384,
            .height               = 256,
            .render_width         = 384,
            .render_height        = 256,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();
        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();

        ASSERT_TRUE(SettleSceneDemand(render, *loaded.scene))
            << "a fixed caption never stopped asking for frames";
        EXPECT_GT(LitPixels(ReadOutput(render, *loaded.scene)), 0u)
            << "the scene went quiet without ever drawing the text";

        // Both facts that used to stop it are still reported, because both are
        // still true and the pixel-reuse cache depends on them. What changed is
        // that neither is read as a reason for the whole scene to keep drawing.
        const auto shader = render.ShaderUpdateDemandReasons();
        EXPECT_TRUE(shader & wallpaper::vulkan::DynamicReason::EventMesh)
            << "the text card stopped being reported as geometry the runtime rewrites";
        EXPECT_TRUE(shader & wallpaper::vulkan::DynamicReason::RuntimeImage)
            << "the text texture stopped being reported as an image the runtime replaces";

        render.destroy();
    }
}

TEST_F(MetalSceneDraw, AChangedCaptionWakesTheSceneAndThenLetsItGoQuietAgain)
{
    // The other half of idling, and the one that makes it safe: a scene that
    // has gone quiet must not stay quiet through a change. The demand has to
    // come back while the new layout is in flight, the new picture has to
    // reach the output, and only then may the scene be still again.
    const auto  project = WriteTextFixture(root_ / "text-wake", "HELLO");
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "text-wake-cache", loaded, error)) << error;
    ASSERT_NE(loaded.scene->runtime, nullptr);

    @autoreleasepool {
        id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(384, 256);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 384,
            .height               = 256,
            .render_width         = 384,
            .render_height        = 256,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();
        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();

        ASSERT_TRUE(SettleSceneDemand(render, *loaded.scene));
        const auto quiet = ReadOutput(render, *loaded.scene);
        ASSERT_FALSE(quiet.empty());

        ASSERT_TRUE(loaded.scene->runtime->SetNodeText("caption", "WOVEN"));
        EXPECT_NE(SceneDemand(render, *loaded.scene), 0u)
            << "a caption that changed left the scene claiming it had nothing to do";

        ASSERT_TRUE(SettleSceneDemand(render, *loaded.scene))
            << "the scene never finished applying the new caption";
        EXPECT_NE(ReadOutput(render, *loaded.scene), quiet)
            << "the scene went quiet again without the new caption reaching the output";

        // Setting the same string back is not a change, so it must not produce
        // a scene that thinks it has work.
        ASSERT_TRUE(loaded.scene->runtime->SetNodeText("caption", "WOVEN"));
        EXPECT_EQ(SceneDemand(render, *loaded.scene), 0u)
            << "writing the caption it already had woke the scene up";

        render.destroy();
    }
}

TEST_F(MetalSceneDraw, TextProducedByAScriptIsNeverCalledStill)
{
    // The limit of the change above, and the one it must not cross. A caption
    // whose value is computed every tick keeps the clock, whatever the script
    // happens to return: nothing here reads the script's body, counts repeated
    // results or infers when it will next differ.
    const auto project = WriteTextFixture(
        root_ / "scripted-text",
        "HELLO",
        false,
        R"({"value":"HELLO","script":"export function update(value) { return '12:34'; }"})");
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "scripted-text-cache", loaded, error)) << error;
    ASSERT_NE(loaded.scene->runtime, nullptr);

    @autoreleasepool {
        id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(384, 256);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 384,
            .height               = 256,
            .render_width         = 384,
            .render_height        = 256,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();
        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();

        for (int frame = 0; frame < 30; ++frame) {
            AdvanceSceneFrame(render, *loaded.scene);
            ASSERT_TRUE(SceneDemand(render, *loaded.scene) &
                        wallpaper::SceneDemandReason::Script)
                << "a scripted caption was allowed to look like a still scene on frame " << frame;
        }

        render.destroy();
    }
}

TEST_F(MetalSceneDraw, TextBoundToAUserPropertyIsEventDrivenRatherThanContinuous)
{
    // A caption the user's own property supplies changes when they change it,
    // which is an event and not a timeline. The binding exists for the whole
    // life of the scene; that on its own must not keep the clock running.
    const auto project = WriteTextFixture(root_ / "property-text",
                                          "HELLO",
                                          false,
                                          R"({"value":"HELLO","user":"caption"})");
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "property-text-cache", loaded, error)) << error;
    ASSERT_NE(loaded.scene->runtime, nullptr);

    @autoreleasepool {
        id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(384, 256);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 384,
            .height               = 256,
            .render_width         = 384,
            .render_height        = 256,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();
        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();

        ASSERT_TRUE(SettleSceneDemand(render, *loaded.scene))
            << "a caption bound to a user property never stopped asking for frames";

        render.destroy();
    }
}

TEST_F(MetalSceneDraw, AStaticTextLayerUnderAnEffectChainAlsoRunsOutOfWork)
{
    // The effect chain adds two more cards the relayout rewrites and two more
    // passes. None of them is driven by anything, so the scene is still still.
    const auto  project = WriteTextFixture(root_ / "effect-text-idle", "HELLO", true);
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "effect-text-idle-cache", loaded, error)) << error;
    ASSERT_NE(loaded.scene->runtime, nullptr);

    @autoreleasepool {
        id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(384, 256);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 384,
            .height               = 256,
            .render_width         = 384,
            .render_height        = 256,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();
        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();

        ASSERT_TRUE(SettleSceneDemand(render, *loaded.scene))
            << "a text layer under an effect chain never stopped asking for frames";
        EXPECT_GT(LitPixels(ReadOutput(render, *loaded.scene)), 0u)
            << "the chain went quiet without drawing anything";

        render.destroy();
    }
}

TEST_F(MetalSceneDraw, AnOptionalProgramTranslatedOnceIsRestoredFromDiskOnTheNextLaunch)
{
    // What "persisted" has to mean, and the only way to show it without a
    // second process: the translation runs once, and a compile that starts from
    // an empty in-memory cache -- which is what a new launch is -- produces the
    // same Metal source, the same reflection and the same binding plan without
    // the compiler running at all.
    const auto project = WriteVideoFixture(root_ / "variant-cache-project", kVideoWidth,
                                           kVideoHeight);
    if (project.empty()) {
        GTEST_SKIP() << "no hardware H.264 encoder here, so no decodable media to parse";
    }
    const auto  cache_root = root_ / "variant-cache";
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, cache_root, loaded, error)) << error;

    auto* material = FirstMaterial(loaded.scene->sceneGraph.get());
    ASSERT_NE(material, nullptr);
    ASSERT_NE(material->customShader.shader, nullptr);
    const auto* program = material->customShader.shader->metal_program.get();
    ASSERT_NE(program, nullptr);
    ASSERT_TRUE(program->hasVideoPlaneCandidate())
        << "no plane variant was possible, so there is nothing to persist";
    const auto& inputs = *program->video_plane_inputs;

    const auto compile = [&inputs, &cache_root](
                             std::vector<shader::RustShaderMetalStage>& stages,
                             std::string& reflection) {
        std::string failure;
        const bool  ok = WPShaderParser::CompileMslVariant(
            inputs, cache_root.string(), stages, &reflection, &failure);
        EXPECT_TRUE(ok) << failure;
        return ok;
    };

    // ---- first launch: nothing on disk for this program yet
    WPShaderParser::ClearProgramCache();
    WPShaderParser::ResetStartupMetrics();
    std::vector<shader::RustShaderMetalStage> first;
    std::string                               first_reflection;
    ASSERT_TRUE(compile(first, first_reflection));
    const auto cold = WPShaderParser::GetStartupMetrics();
    ASSERT_EQ(cold.cache_hits, 0u) << "the first translation was already a hit";
    ASSERT_EQ(cold.cache_misses, 1u);
    ASSERT_FALSE(first.empty());
    ASSERT_FALSE(first_reflection.empty());

    // ---- next launch: the process remembers nothing, the disk does
    WPShaderParser::ClearProgramCache();
    WPShaderParser::ResetStartupMetrics();
    std::vector<shader::RustShaderMetalStage> second;
    std::string                               second_reflection;
    ASSERT_TRUE(compile(second, second_reflection));
    const auto warm = WPShaderParser::GetStartupMetrics();
    EXPECT_EQ(warm.cache_misses, 0u)
        << "the optional program was translated again from source on a later launch";
    EXPECT_EQ(warm.cache_hits, 1u);

    // Restoring the Metal source alone would not be enough: without the
    // reflection and the per-stage binding plan the renderer cannot bind
    // anything to it, and would have to compile it again to find out.
    EXPECT_EQ(second_reflection, first_reflection);
    ASSERT_EQ(second.size(), first.size());
    for (std::size_t i = 0; i < first.size(); ++i) {
        EXPECT_EQ(second[i].source, first[i].source);
        EXPECT_EQ(second[i].entry_point, first[i].entry_point);
        EXPECT_EQ(second[i].language_version, first[i].language_version);
        ASSERT_EQ(second[i].bindings.size(), first[i].bindings.size())
            << "stage " << i << " came back with a different binding plan";
        for (std::size_t b = 0; b < first[i].bindings.size(); ++b) {
            EXPECT_EQ(second[i].bindings[b].name, first[i].bindings[b].name);
            EXPECT_EQ(second[i].bindings[b].slot, first[i].bindings[b].slot);
            EXPECT_EQ(second[i].bindings[b].slot_kind, first[i].bindings[b].slot_kind);
        }
    }

    // ---- a cache that is there but unreadable is not a failure
    //
    // Truncating every stored program is the worst case a partial write or a
    // half-deleted folder can produce. The wallpaper must still get its
    // variant; the cache is an optimisation and never a dependency.
    std::size_t corrupted = 0;
    for (const auto& entry :
         std::filesystem::directory_iterator(cache_root / "metal-draw-smoke" / "programs01")) {
        if (! entry.is_regular_file()) continue;
        std::ofstream(entry.path(), std::ios::trunc) << "{\"request\": ";
        ++corrupted;
    }
    ASSERT_GT(corrupted, 0u) << "nothing was written to disk, so nothing was persisted";

    WPShaderParser::ClearProgramCache();
    WPShaderParser::ResetStartupMetrics();
    std::vector<shader::RustShaderMetalStage> recovered;
    std::string                               recovered_reflection;
    ASSERT_TRUE(compile(recovered, recovered_reflection))
        << "a corrupted cache entry stopped the variant being produced";
    EXPECT_EQ(WPShaderParser::GetStartupMetrics().cache_misses, 1u)
        << "a corrupted entry was read as a hit";
    ASSERT_EQ(recovered.size(), first.size());
    EXPECT_EQ(recovered.front().source, first.front().source);
    EXPECT_EQ(recovered_reflection, first_reflection);
}

TEST_F(MetalSceneDraw, BackgroundChangesInvalidateCachedPixelsWithoutRecompilingTheGraph)
{
    struct RestoreOptimization {
        bool previous { vulkan::SceneOptimizationEnabled() };
        ~RestoreOptimization() { vulkan::SetSceneOptimizationEnabled(previous); }
    } restore;
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(WriteFixture(root_ / "background"), root_ / "cache", loaded, error)) << error;
    @autoreleasepool {
        CAMetalLayer* layer = [CAMetalLayer layer];
        layer.device = MTLCreateSystemDefaultDevice();
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize = CGSizeMake(384, 256);
        MetalRender render;
        ASSERT_TRUE(render.init(MetalRenderInitInfo {
            .metal_layer = (__bridge void*)layer, .width = 384, .height = 256,
            .render_width = 384, .render_height = 256,
        })) << render.lastError();
        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
        for (const bool optimization : {false, true}) {
            vulkan::SetSceneOptimizationEnabled(optimization);
            for (const auto color : {std::array<float, 3> {1, 0, 0}, std::array<float, 3> {0, 1, 0}}) {
                loaded.scene->clearColor = color;
                for (int frame = 0; frame < 2; ++frame) {
                    ASSERT_TRUE(render.drawFrame(*loaded.scene)) << render.lastError();
                    std::vector<uint8_t> pixels;
                    uint32_t width = 0, height = 0;
                    ASSERT_TRUE(render.ReadRenderTargetForTests(std::string(SpecTex_Default), pixels, width, height));
                    ASSERT_GE(pixels.size(), 4u);
                    EXPECT_EQ(pixels[0], static_cast<uint8_t>(color[0] * 255));
                    EXPECT_EQ(pixels[1], static_cast<uint8_t>(color[1] * 255));
                    EXPECT_EQ(pixels[2], 0u);
                    EXPECT_EQ(pixels[3], 255u);
                }
            }
        }
        render.destroy();
    }
}

TEST_F(MetalSceneDraw, PipelinesThisProcessBuildsAreArchivedAndServeTheProductionPath)
{
    // What the archive has to be able to say, and the only claim worth making
    // about it: the file this process writes is handed to the real pipeline
    // creation path -- the same `newRenderPipelineStateWithDescriptor:` a
    // wallpaper goes through -- and Metal can satisfy those descriptors from it
    // without compiling. The strict option is used only here, to tell an actual
    // hit apart from a fast recompile; the renderer never asks that way,
    // because a cold cache must never stop a wallpaper loading.
    const auto archive_root = root_ / "pipeline-archive";
    std::filesystem::create_directories(archive_root);

    const auto  project = WriteFixture(root_ / "archive-project", "0.375");
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "archive-cache", loaded, error)) << error;

    @autoreleasepool {
        id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(384, 256);
        layer.framebufferOnly = NO;

        SceneRendererHandle render;
        RenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 384,
            .height               = 256,
            .render_width         = 384,
            .render_height        = 256,
            .display_scale_factor = 1.0,
        };
        render.SetPipelineArchivePath(archive_root.string());
        ASSERT_TRUE(render.createMetal(info, error)) << error;
        // Per surface, as the scene's own command sets it: another display
        // showing a different wallpaper keeps its own store.
        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
        loaded.scene->PassFrameTime(1.0 / 60.0);
        ASSERT_TRUE(render.drawFrame(*loaded.scene)) << render.lastError();

        // A first run has no file to read from, so nothing is attached to its
        // descriptors and everything is compiled -- which is the honest state
        // and not a failure. What it does is collect.
        EXPECT_GT(MetalPipelineArchiveStatusForDiagnostics().collected, 0u)
            << "the pipelines this scene needed were never offered to the archive";

        // Published, reopened from disk and asked strictly: this is the next
        // launch's question, answered without one.
        EXPECT_TRUE(MetalRender::PipelineArchiveServesEverySeenPipelineForTests())
            << "the archive could not supply a pipeline it had been given";

        const auto status = MetalPipelineArchiveStatusForDiagnostics();
        EXPECT_TRUE(status.available) << "the published archive could not be reopened";
        EXPECT_GT(status.published, 0u) << "the archive was never written out";

        render.destroy();
    }

    // Written to disk, under the regenerable cache and nowhere else.
    std::size_t files = 0;
    for (const auto& entry : std::filesystem::directory_iterator(archive_root)) {
        if (entry.is_regular_file() && entry.file_size() > 0) ++files;
    }
    EXPECT_GT(files, 0u) << "the archive was never published, so a later launch inherits nothing";

    // An unwritable or absent store is not a failure: pipelines are created
    // exactly as they were before any of this existed. This renderer is simply
    // never given a path.
    LoadedScene without;
    ASSERT_TRUE(LoadScene(WriteFixture(root_ / "no-archive-project", "0.4375"),
                          root_ / "no-archive-cache", without, error))
        << error;
    @autoreleasepool {
        id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(384, 256);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 384,
            .height               = 256,
            .render_width         = 384,
            .render_height        = 256,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();
        auto graph = sceneToRenderGraph(*without.scene);
        ASSERT_NE(graph, nullptr);
        EXPECT_TRUE(render.compileRenderGraph(*without.scene, *graph)) << render.lastError();
        AdvanceSceneFrame(render, *without.scene);
        EXPECT_GT(LitPixels(ReadOutput(render, *without.scene)), 0u)
            << "a wallpaper stopped drawing when there was no pipeline archive";
        render.destroy();
    }
}

TEST_F(MetalSceneDraw, AStoreFolderDeletedWhileItsArchiveIsWrittenCostsOnlyThatWrite)
{
    // The pipeline store sits in a regenerable cache folder that clearing the
    // cache or removing a wallpaper deletes whenever it likes, and its write
    // runs two seconds after the last pipeline. Metal's archive serialiser
    // writes a scratch file beside its destination and corrupts the heap when
    // that folder disappears under it, so a write that raced a deletion took
    // the whole process down. Here eight wallpapers each keep their own store,
    // so eight writes run, and every store folder is deleted and made again
    // without pause for as long as they take: a write may be lost, the process
    // must not be, and no scratch file may be left behind.
    std::vector<std::filesystem::path> archive_roots;
    const auto collected_before = MetalPipelineArchiveStatusForDiagnostics().collected;

    // Colours no other test draws, so every pipeline is new to the archive.
    for (const char* blue : { "0.53125", "0.59375", "0.65625", "0.71875", "0.78125", "0.84375",
                              "0.90625", "0.96875" }) {
        SCOPED_TRACE(blue);
        const auto archive_root = archive_roots.emplace_back(root_ / (std::string("archive-") + blue));
        std::filesystem::create_directories(archive_root);
        const auto  project = WriteFixture(root_ / (std::string("vanishing-") + blue), blue);
        LoadedScene loaded;
        std::string error;
        ASSERT_TRUE(LoadScene(project, root_ / (std::string("vanishing-cache-") + blue), loaded,
                              error))
            << error;
        @autoreleasepool {
            CAMetalLayer* layer   = [CAMetalLayer layer];
            layer.device          = MTLCreateSystemDefaultDevice();
            layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
            layer.drawableSize    = CGSizeMake(384, 256);
            layer.framebufferOnly = NO;

            SceneRendererHandle render;
            RenderInitInfo info {
                .metal_layer          = (__bridge void*)layer,
                .width                = 384,
                .height               = 256,
                .render_width         = 384,
                .render_height        = 256,
                .display_scale_factor = 1.0,
            };
            render.SetPipelineArchivePath(archive_root.string());
            ASSERT_TRUE(render.createMetal(info, error)) << error;
            auto graph = sceneToRenderGraph(*loaded.scene);
            ASSERT_NE(graph, nullptr);
            ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
            loaded.scene->PassFrameTime(1.0 / 60.0);
            ASSERT_TRUE(render.drawFrame(*loaded.scene)) << render.lastError();
            render.destroy();
        }
    }
    ASSERT_GT(MetalPipelineArchiveStatusForDiagnostics().collected, collected_before)
        << "nothing new was offered to the archive, so no write was scheduled";

    std::atomic<bool> churn { true };
    std::thread       deleter([&] {
        while (churn.load()) {
            for (const auto& archive_root : archive_roots) {
                std::error_code ignored;
                std::filesystem::remove_all(archive_root, ignored);
                std::filesystem::create_directories(archive_root, ignored);
            }
        }
    });
    MetalRender::WaitForPipelineArchiveWritesForTests();
    churn = false;
    deleter.join();

    std::size_t scratch = 0;
    const auto  prefix  = "owe-pipelines-" + std::to_string(::getpid()) + "-";
    for (const auto& entry : std::filesystem::directory_iterator(NSTemporaryDirectory().UTF8String)) {
        if (entry.path().filename().string().rfind(prefix, 0) == 0) ++scratch;
    }
    EXPECT_EQ(scratch, 0u) << "a write left its scratch file in the temporary folder";
}

TEST_F(MetalSceneDraw, ACaptionChangedWhileHiddenIsNotWorkInFlight)
{
    // The trap in reporting "text is still being laid out" as a reason to keep
    // drawing: the pump skips hidden layers, so a caption changed while its
    // layer is hidden is pending and is not being worked on. Counting it would
    // leave the wallpaper drawing forever for work nobody is doing. Showing the
    // layer again is an event, and the layout happens then.
    const auto  project = WriteTextFixture(root_ / "hidden-text", "HELLO");
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "hidden-text-cache", loaded, error)) << error;
    ASSERT_NE(loaded.scene->runtime, nullptr);

    @autoreleasepool {
        id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(384, 256);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 384,
            .height               = 256,
            .render_width         = 384,
            .render_height        = 256,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();
        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();

        ASSERT_TRUE(SettleSceneDemand(render, *loaded.scene));

        ASSERT_TRUE(loaded.scene->runtime->SetNodeVisible("caption", false));
        ASSERT_TRUE(loaded.scene->runtime->SetNodeText("caption", "WOVEN"));
        ASSERT_TRUE(SettleSceneDemand(render, *loaded.scene, 60))
            << "a caption changed behind a hidden layer kept the scene drawing for work the "
               "text pump never starts";

        // And the work is not lost: showing the layer again produces it.
        ASSERT_TRUE(loaded.scene->runtime->SetNodeVisible("caption", true));
        ASSERT_TRUE(SettleSceneDemand(render, *loaded.scene))
            << "the deferred layout never finished after the layer came back";
        EXPECT_GT(LitPixels(ReadOutput(render, *loaded.scene)), 0u)
            << "the layer came back empty";

        render.destroy();
    }
}

// ---------------------------------------------------------------------------
// Skinning, rope and trail layouts on a real device

namespace
{

/// Same project as `WriteFixture`, with a named vertex shader of the caller's
/// choosing. The fragment is the probe that writes `(u, v, 0.25, 1)`.
std::filesystem::path WriteShaderFixture(const std::filesystem::path& root,
                                         std::string_view             shader_name,
                                         std::string_view             vertex_source)
{
    const std::string fragment =
        "varying vec2 v_TexCoord;\n"
        "void main() {\n"
        "  gl_FragColor = vec4(v_TexCoord.x, v_TexCoord.y, 0.25, 1.0);\n"
        "}\n";
    const std::string shader(shader_name);
    const std::map<std::string, std::string> files {
        { "project.json",
          R"({"title":"Metal draw smoke","type":"scene","file":"layout.json","general":{"properties":{}}})" },
        { "models/tile.json", R"({"width":256,"height":192,"material":"materials/tile.json"})" },
        { "materials/tile.json",
          "{\"passes\":[{\"shader\":\"" + shader +
              "\",\"blending\":\"translucent\",\"cullmode\":\"nocull\",\"depthtest\":\"disabled\","
              "\"depthwrite\":\"disabled\"}]}" },
        { "shaders/" + shader + ".vert", std::string(vertex_source) },
        { "shaders/" + shader + ".frag", fragment },
        { "layout.json",
          R"({"camera":{"center":[0,0,0],"eye":[0,0,1],"up":[0,1,0]},)"
          R"("general":{"ambientcolor":[0,0,0],"skylightcolor":[0,0,0],"clearcolor":[0.0,0.0,0.0],)"
          R"("cameraparallax":false,"orthogonalprojection":{"width":384,"height":256}},)"
          R"("objects":[{"id":1,"name":"tile","image":"models/tile.json","origin":[192,128,0],)"
          R"("scale":[1,1,1],"angles":[0,0,0],"visible":true}]})" },
    };

    for (const auto& [name, contents] : files) {
        const auto path = root / name;
        std::filesystem::create_directories(path.parent_path());
        std::ofstream(path) << contents;
    }
    return root / "project.json";
}

bool PixelRectEqual(const std::vector<uint8_t>& a, const std::vector<uint8_t>& b, uint32_t width,
                    uint32_t x0, uint32_t y0, uint32_t x1, uint32_t y1)
{
    if (a.size() != b.size() || width == 0 || a.size() % (width * 4u) != 0) return false;
    const uint32_t height = static_cast<uint32_t>(a.size() / (width * 4u));
    if (x1 > width || y1 > height || x0 >= x1 || y0 >= y1) return false;
    for (uint32_t y = y0; y < y1; ++y) {
        for (uint32_t x = x0; x < x1; ++x) {
            const std::size_t i = (static_cast<std::size_t>(y) * width + x) * 4u;
            if (a[i] != b[i] || a[i + 1] != b[i + 1] || a[i + 2] != b[i + 2] ||
                a[i + 3] != b[i + 3]) {
                return false;
            }
        }
    }
    return true;
}

} // namespace

namespace
{

/// A two-bone puppet whose second bone slides 80 units along +X over a 0.3 s
/// loop while the first stays put, with one visible animation layer playing it.
WPPuppetLayer MakeSlidingPuppetLayer()
{
    auto puppet = std::make_shared<WPPuppet>();
    puppet->bones.emplace_back().name = "root";
    puppet->bones.emplace_back().name = "shift";
    auto& anim                        = puppet->anims.emplace_back();
    anim.id                           = 1;
    anim.fps                          = 30.0;
    anim.length                       = 9;
    anim.mode                         = WPPuppet::PlayMode::Loop;
    anim.name                         = "slide";
    auto still_frame                  = []() {
        WPPuppet::BoneFrame frame;
        frame.position = Eigen::Vector3f::Zero();
        frame.angle    = Eigen::Vector3f::Zero();
        frame.scale    = Eigen::Vector3f::Ones();
        return frame;
    };
    // Sized first: a reference taken from `emplace_back` would dangle as soon as
    // the second track made the vector grow.
    anim.bone_tracks.resize(2);
    auto& track0        = anim.bone_tracks[0];
    track0.bone_index   = 0;
    auto& track1        = anim.bone_tracks[1];
    track1.bone_index   = 1;
    constexpr int kKeys = 10;
    for (int i = 0; i < kKeys; ++i) {
        track0.frames.push_back(still_frame());
        auto frame          = still_frame();
        frame.position.x()  = 80.0f * (static_cast<float>(i) / static_cast<float>(kKeys - 1));
        track1.frames.push_back(frame);
    }
    puppet->prepared();

    WPPuppetLayer                  layer(puppet);
    WPPuppetLayer::AnimationLayer  anim_layer;
    anim_layer.id      = 1;
    anim_layer.rate    = 1.0;
    anim_layer.blend   = 1.0;
    anim_layer.visible = true;
    layer.prepared(std::span<WPPuppetLayer::AnimationLayer>(&anim_layer, 1));

    return layer;
}

/// Two separate quads in the node's local space, the first bound wholly to
/// bone 0 and the second wholly to bone 1, in the vertex layout the model
/// parser gives a puppet mesh. The second quad's texture coordinate is (1, 1)
/// and the first's (0, 0), so the probe fragment shader colours them apart.
std::shared_ptr<SceneMesh> MakeTwoQuadSkinnedMesh(std::shared_ptr<SceneMaterial> material)
{
    auto mesh = std::make_shared<SceneMesh>();
    std::vector<SceneVertexArray::SceneVertexAttribute> attributes {
        { std::string(WE_IN_POSITION), VertexType::FLOAT3 },
        { std::string(WE_IN_BLENDINDICES), VertexType::UINT4 },
        { std::string(WE_IN_BLENDWEIGHTS), VertexType::FLOAT4 },
        { std::string(WE_IN_TEXCOORD), VertexType::FLOAT2 },
    };
    SceneVertexArray vertices(attributes, 8);
    auto pack = [](float x, float y, uint32_t bone, float u, float v) {
        std::array<float, 16> out {};
        out[0] = x;
        out[1] = y;
        // UINT4 lives in the float slots as the raw 32-bit indices, not as floats.
        const uint32_t indices[4] = { bone, 0, 0, 0 };
        std::memcpy(out.data() + 4, indices, sizeof(indices));
        out[8]  = 1.0f;
        out[12] = u;
        out[13] = v;
        return out;
    };
    const std::array<std::array<float, 16>, 8> packed {
        pack(-140.0f, -30.0f, 0, 0.0f, 0.0f), pack(-60.0f, -30.0f, 0, 0.0f, 0.0f),
        pack(-60.0f, 30.0f, 0, 0.0f, 0.0f),   pack(-140.0f, 30.0f, 0, 0.0f, 0.0f),
        pack(20.0f, -30.0f, 1, 1.0f, 1.0f),   pack(100.0f, -30.0f, 1, 1.0f, 1.0f),
        pack(100.0f, 30.0f, 1, 1.0f, 1.0f),   pack(20.0f, 30.0f, 1, 1.0f, 1.0f),
    };
    for (std::size_t i = 0; i < packed.size(); ++i) vertices.SetVertexs(i, packed[i]);
    mesh->AddVertexArray(std::move(vertices));
    const std::array<uint16_t, 12> triangles { 0, 1, 3, 1, 2, 3, 4, 5, 7, 5, 6, 7 };
    SceneIndexArray                index_array(4);
    index_array.AssignHalf(0, triangles);
    mesh->AddIndexArray(std::move(index_array));
    mesh->MaterialSlots().push_back(material);
    return mesh;
}

} // namespace

TEST_F(MetalSceneDraw, APuppetIsSkinnedByItsOwnShaderFromThePoseTheRuntimeProduces)
{
    const std::string vertex =
        "uniform mat4 g_ModelViewProjectionMatrix;\n"
        "uniform mat4x3 g_Bones[2];\n"
        "attribute vec3 a_Position;\n"
        "attribute uvec4 a_BlendIndices;\n"
        "attribute vec4 a_BlendWeights;\n"
        "attribute vec2 a_TexCoord;\n"
        "varying vec2 v_TexCoord;\n"
        "void main() {\n"
        "  vec3 localPos = mul(vec4(a_Position, 1.0), g_Bones[a_BlendIndices.x] * a_BlendWeights.x + "
        "g_Bones[a_BlendIndices.y] * a_BlendWeights.y + g_Bones[a_BlendIndices.z] * a_BlendWeights.z + "
        "g_Bones[a_BlendIndices.w] * a_BlendWeights.w);\n"
        "  gl_Position = mul(vec4(localPos, 1.0), g_ModelViewProjectionMatrix);\n"
        "  v_TexCoord = a_TexCoord;\n"
        "}\n";
    const auto  project = WriteShaderFixture(root_ / "skin-project", "metal_skin_probe", vertex);
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "skin-cache", loaded, error)) << error;

    auto* node = FirstDrawableNode(loaded.scene->sceneGraph.get());
    ASSERT_NE(node, nullptr);
    auto* source_mesh = node->Mesh();
    ASSERT_NE(source_mesh, nullptr);
    auto material = source_mesh->MaterialSlotPtr(0);
    ASSERT_NE(material, nullptr);
    ASSERT_NE(material->customShader.shader, nullptr);
    const auto* program = material->customShader.shader->metal_program.get();
    ASSERT_NE(program, nullptr);
    ASSERT_TRUE(program->error.empty()) << program->error;

    auto layer = MakeSlidingPuppetLayer();
    node->AddMesh(MakeTwoQuadSkinnedMesh(material));

    ASSERT_NE(loaded.scene->shaderValueUpdater.get(), nullptr);
    WPShaderValueData data;
    data.puppet_layer = layer;
    static_cast<WPShaderValueUpdater*>(loaded.scene->shaderValueUpdater.get())
        ->SetNodeData(node, data);

    const auto selection = SelectSceneBackend(*loaded.scene);
    ASSERT_EQ(selection.backend, SceneBackend::NativeMetal) << selection.fallback_reason;

    MetalShaderReflection reflection;
    std::string           reflection_error;
    ASSERT_TRUE(ParseMetalShaderReflection(program->reflection_json, reflection, &reflection_error))
        << reflection_error;
    const auto* bones = reflection.member("g_Bones");
    ASSERT_NE(bones, nullptr) << "translated program has no g_Bones member";
    EXPECT_EQ(bones->array_count, 2u);
    EXPECT_EQ(bones->array_stride, 64u);

    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device == nil) {
            GTEST_SKIP() << "no Metal device on this machine; the native draw was not exercised";
        }
        CAMetalLayer* layer_view  = [CAMetalLayer layer];
        layer_view.device          = device;
        layer_view.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer_view.drawableSize    = CGSizeMake(640, 360);
        layer_view.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer_view,
            .width                = 640,
            .height               = 360,
            .render_width         = 640,
            .render_height        = 360,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();

        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
        render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);

        EXPECT_TRUE(render.ShaderUpdateDemandReasons() &
                    wallpaper::vulkan::DynamicReason::BoneUniform)
            << "a skinned puppet was not reported as advancing on its own";

        const auto first = DrawOneFrame(render, *loaded.scene);
        EXPECT_EQ(first.skipped, 0u);
        const auto first_pixels = ReadOutput(render, *loaded.scene);
        ASSERT_FALSE(first_pixels.empty());
        ASSERT_EQ(first_pixels.size() % 4u, 0u);
        const uint32_t canvas_w =
            first_pixels.size() == 640u * 360u * 4u ? 640u : 384u;
        const uint32_t canvas_h =
            static_cast<uint32_t>(first_pixels.size() / (canvas_w * 4u));
        // Bone 0 sits in the left-centre of the 384x256 canvas; mapped into the
        // output so a Y-flip still covers the same vertically centred band.
        const uint32_t x0 = canvas_w * 18u / 100u;
        const uint32_t x1 = canvas_w * 28u / 100u;
        const uint32_t y0 = canvas_h * 42u / 100u;
        const uint32_t y1 = canvas_h * 58u / 100u;

        std::vector<std::vector<uint8_t>> frames { first_pixels };
        loaded.scene->PassFrameTime(0.2);
        for (int frame = 0; frame < 3; ++frame) {
            const auto counters = DrawOneFrame(render, *loaded.scene);
            EXPECT_EQ(counters.skipped, 0u)
                << "a moving bone reused its target on frame " << frame;
            auto pixels = ReadOutput(render, *loaded.scene);
            EXPECT_NE(pixels, first_pixels)
                << "the skinned pose advanced and the picture did not change";
            frames.push_back(std::move(pixels));
            loaded.scene->PassFrameTime(1.0 / 60.0);
        }

        // Not merely "different": the bone-1 quad must have TRANSLATED. Its
        // fragment colour is (1, 1, 0.25), so its columns can be told from the
        // bone-0 quad's and the background in either byte order. The pose at
        // 0.2 s of a 0.3 s slide over 80 units is two thirds of the quad's own
        // 80-unit width, whatever scale the output was composed at -- and a
        // transposed or re-ordered bone matrix shears or scales the quad
        // instead of moving it, which changes that width.
        const auto bright_columns = [canvas_w](const std::vector<uint8_t>& rgba) {
            std::pair<int, int> columns { -1, -1 };
            for (std::size_t pixel = 0; pixel * 4 + 3 < rgba.size(); ++pixel) {
                const uint8_t* p = rgba.data() + pixel * 4;
                if (p[1] < 200 || std::max(p[0], p[2]) < 200 || std::min(p[0], p[2]) > 120) continue;
                const int x = static_cast<int>(pixel % canvas_w);
                if (columns.first < 0 || x < columns.first) columns.first = x;
                if (x > columns.second) columns.second = x;
            }
            return columns;
        };
        const auto at_rest = bright_columns(frames[0]);
        const auto slid    = bright_columns(frames[1]);
        ASSERT_GE(at_rest.first, 0) << "the bone-1 quad was not found in the first frame";
        ASSERT_GE(slid.first, 0) << "the bone-1 quad was not found after the pose advanced";
        const double rest_width = at_rest.second - at_rest.first + 1;
        const double slid_width = slid.second - slid.first + 1;
        EXPECT_NEAR(slid_width, rest_width, 2.0)
            << "the skinned quad changed shape instead of moving";
        EXPECT_NEAR((slid.first - at_rest.first) / rest_width, 2.0 / 3.0, 0.05)
            << "the skinned quad did not move by the distance its bone did";

        layer.pause(0);
        loaded.scene->PassFrameTime(0.2);
        DrawOneFrame(render, *loaded.scene);
        const auto paused_a = ReadOutput(render, *loaded.scene);
        loaded.scene->PassFrameTime(0.2);
        DrawOneFrame(render, *loaded.scene);
        const auto paused_b = ReadOutput(render, *loaded.scene);
        EXPECT_EQ(paused_a, paused_b)
            << "a paused puppet still changed while time passed";
        frames.push_back(paused_a);

        layer.play(0);
        loaded.scene->PassFrameTime(0.2);
        const auto played = DrawOneFrame(render, *loaded.scene);
        EXPECT_EQ(played.skipped, 0u);
        const auto played_pixels = ReadOutput(render, *loaded.scene);
        EXPECT_NE(played_pixels, paused_a)
            << "play() did not move the skinned picture again";
        frames.push_back(played_pixels);

        for (std::size_t i = 1; i < frames.size(); ++i) {
            EXPECT_TRUE(PixelRectEqual(frames[i], frames[0], canvas_w, x0, y0, x1, y1))
                << "the bone-0 quad moved on frame " << i;
        }

        render.destroy();
    }
}

TEST_F(MetalSceneDraw, ARopeLayoutMeshReachesTheTarget)
{
    const std::string vertex =
        "uniform mat4 g_ModelViewProjectionMatrix;\n"
        "attribute vec4 a_PositionVec4;\n"
        "attribute vec4 a_TexCoordVec4;\n"
        "attribute vec4 a_TexCoordVec4C1;\n"
        "attribute vec3 a_TexCoordVec3C2;\n"
        "attribute vec2 a_TexCoordC3;\n"
        "attribute vec4 a_Color;\n"
        "varying vec2 v_TexCoord;\n"
        "void main() {\n"
        "  vec3 position = mix(a_PositionVec4.xyz, a_TexCoordVec4.xyz, a_TexCoordC3.y) + "
        "vec3(0.0, (a_TexCoordC3.x * 2.0 - 1.0) * a_PositionVec4.w, 0.0);\n"
        "  gl_Position = g_ModelViewProjectionMatrix * vec4(position, 1.0);\n"
        "  v_TexCoord = a_TexCoordC3;\n"
        "}\n";
    const auto  project = WriteShaderFixture(root_ / "rope-project", "metal_rope_probe", vertex);
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "rope-cache", loaded, error)) << error;

    auto* node = FirstDrawableNode(loaded.scene->sceneGraph.get());
    ASSERT_NE(node, nullptr);
    auto* source_mesh = node->Mesh();
    ASSERT_NE(source_mesh, nullptr);
    auto material = source_mesh->MaterialSlotPtr(0);
    ASSERT_NE(material, nullptr);

    auto dynamic_mesh = std::make_shared<SceneMesh>(MeshUpdate::PerFrame);
    std::vector<SceneVertexArray::SceneVertexAttribute> attributes {
        { WE_IN_POSITIONVEC4.data(), VertexType::FLOAT4 },
        { WE_IN_TEXCOORDVEC4.data(), VertexType::FLOAT4 },
        { WE_IN_TEXCOORDVEC4C1.data(), VertexType::FLOAT4 },
        { WE_IN_TEXCOORDVEC3C2.data(), VertexType::FLOAT4 },
        { WE_IN_TEXCOORDC3.data(), VertexType::FLOAT4 },
        { WE_IN_COLOR.data(), VertexType::FLOAT4 },
    };
    constexpr std::size_t kQuads = 4;
    dynamic_mesh->AddVertexArray(SceneVertexArray(attributes, kQuads * 4));
    dynamic_mesh->AddIndexArray(SceneIndexArray(kQuads));
    dynamic_mesh->GetVertexArray(0).SetOption(WE_PRENDER_ROPE, true);
    dynamic_mesh->MaterialSlots().push_back(material);
    node->AddMesh(dynamic_mesh);

    ASSERT_EQ(SelectSceneBackend(*loaded.scene).backend, SceneBackend::NativeMetal)
        << SelectSceneBackend(*loaded.scene).fallback_reason;

    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device == nil) {
            GTEST_SKIP() << "no Metal device on this machine; the native draw was not exercised";
        }
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(640, 360);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 640,
            .height               = 360,
            .render_width         = 640,
            .render_height        = 360,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();

        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
        render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);

        for (int frame = 0; frame < 3; ++frame) {
            ASSERT_TRUE(render.drawFrame(*loaded.scene)) << render.lastError();
            loaded.scene->PassFrameTime(1.0 / 60.0);
        }
        const auto empty = ReadOutput(render, *loaded.scene);
        ASSERT_FALSE(empty.empty());

        auto& vertices = dynamic_mesh->GetVertexArray(0);
        auto& indices  = dynamic_mesh->GetIndexArray(0);
        const std::array<float, 2> uv[4] { { 0.0f, 1.0f }, { 1.0f, 1.0f }, { 1.0f, 0.0f }, { 0.0f, 0.0f } };
        std::array<float, 24 * 4>  segment {};
        for (int i = 0; i < 4; ++i) {
            float* v = segment.data() + i * 24;
            v[0]  = -150.0f;
            v[1]  = 0.0f;
            v[2]  = 0.0f;
            v[3]  = 20.0f;
            v[4]  = 150.0f;
            v[5]  = 0.0f;
            v[6]  = 0.0f;
            v[7]  = 1.0f;
            v[8]  = -150.0f;
            v[9]  = 0.0f;
            v[10] = 0.0f;
            v[11] = 0.0f;
            v[12] = 150.0f;
            v[13] = 0.0f;
            v[14] = 0.0f;
            v[15] = 0.0f;
            v[16] = uv[i][0];
            v[17] = uv[i][1];
            v[18] = 0.0f;
            v[19] = 0.0f;
            v[20] = 1.0f;
            v[21] = 1.0f;
            v[22] = 1.0f;
            v[23] = 1.0f;
        }
        vertices.SetVertexs(0, segment);
        const std::array<uint16_t, 6> quad_indices { 0, 1, 3, 1, 2, 3 };
        indices.AssignHalf(0, quad_indices);
        indices.SetRenderDataCount(3);
        dynamic_mesh->SetDirty();

        for (int frame = 0; frame < 5; ++frame) {
            ASSERT_TRUE(render.drawFrame(*loaded.scene)) << render.lastError();
            loaded.scene->PassFrameTime(1.0 / 60.0);
        }
        const auto filled = ReadOutput(render, *loaded.scene);
        EXPECT_NE(filled, empty)
            << "a rope layout uploaded after the graph was compiled never reached the target";

        render.destroy();
    }
}

TEST_F(MetalSceneDraw, ASpriteTrailMeshReachesTheTarget)
{
    const std::string vertex =
        "uniform mat4 g_ModelViewProjectionMatrix;\n"
        "attribute vec3 a_Position;\n"
        "attribute vec4 a_TexCoordVec4;\n"
        "attribute vec4 a_Color;\n"
        "attribute vec4 a_TexCoordVec4C1;\n"
        "attribute vec2 a_TexCoordC2;\n"
        "varying vec2 v_TexCoord;\n"
        "void main() {\n"
        "  vec3 position = a_Position + vec3((a_TexCoordVec4.x - 0.5) * 2.0 * a_TexCoordVec4.w, "
        "(a_TexCoordVec4.y - 0.5) * 2.0 * a_TexCoordVec4.w, 0.0) + "
        "a_TexCoordVec4C1.xyz * a_TexCoordVec4.y;\n"
        "  gl_Position = g_ModelViewProjectionMatrix * vec4(position, 1.0);\n"
        "  v_TexCoord = a_TexCoordVec4.xy;\n"
        "}\n";
    const auto  project = WriteShaderFixture(root_ / "trail-project", "metal_trail_probe", vertex);
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "trail-cache", loaded, error)) << error;

    auto* node = FirstDrawableNode(loaded.scene->sceneGraph.get());
    ASSERT_NE(node, nullptr);
    auto* source_mesh = node->Mesh();
    ASSERT_NE(source_mesh, nullptr);
    auto material = source_mesh->MaterialSlotPtr(0);
    ASSERT_NE(material, nullptr);

    auto dynamic_mesh = std::make_shared<SceneMesh>(MeshUpdate::PerFrame);
    std::vector<SceneVertexArray::SceneVertexAttribute> attributes {
        { WE_IN_POSITION.data(), VertexType::FLOAT3 },
        { WE_IN_TEXCOORDVEC4.data(), VertexType::FLOAT4 },
        { WE_IN_COLOR.data(), VertexType::FLOAT4 },
        { WE_IN_TEXCOORDVEC4C1.data(), VertexType::FLOAT4 },
        { WE_IN_TEXCOORDC2.data(), VertexType::FLOAT2 },
    };
    constexpr std::size_t kQuads = 4;
    dynamic_mesh->AddVertexArray(SceneVertexArray(attributes, kQuads * 4));
    dynamic_mesh->AddIndexArray(SceneIndexArray(kQuads));
    dynamic_mesh->GetVertexArray(0).SetOption(WE_PRENDER_SPRITE, true);
    dynamic_mesh->GetVertexArray(0).SetOption(WE_PRENDER_TRAIL, true);
    dynamic_mesh->GetVertexArray(0).SetOption(WE_CB_THICK_FORMAT, true);
    dynamic_mesh->MaterialSlots().push_back(material);
    node->AddMesh(dynamic_mesh);

    ASSERT_EQ(SelectSceneBackend(*loaded.scene).backend, SceneBackend::NativeMetal)
        << SelectSceneBackend(*loaded.scene).fallback_reason;

    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device == nil) {
            GTEST_SKIP() << "no Metal device on this machine; the native draw was not exercised";
        }
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(640, 360);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 640,
            .height               = 360,
            .render_width         = 640,
            .render_height        = 360,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();

        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
        render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);

        for (int frame = 0; frame < 3; ++frame) {
            ASSERT_TRUE(render.drawFrame(*loaded.scene)) << render.lastError();
            loaded.scene->PassFrameTime(1.0 / 60.0);
        }
        const auto empty = ReadOutput(render, *loaded.scene);
        ASSERT_FALSE(empty.empty());

        auto& vertices = dynamic_mesh->GetVertexArray(0);
        auto& indices  = dynamic_mesh->GetIndexArray(0);
        const std::array<float, 2> uv[4] { { 0.0f, 1.0f }, { 1.0f, 1.0f }, { 1.0f, 0.0f }, { 0.0f, 0.0f } };
        std::array<float, 20 * 4>  particle {};
        for (int i = 0; i < 4; ++i) {
            float* v = particle.data() + i * 20;
            v[0]  = 0.0f;
            v[1]  = 0.0f;
            v[2]  = 0.0f;
            v[4]  = uv[i][0];
            v[5]  = uv[i][1];
            v[6]  = 0.0f;
            v[7]  = 40.0f;
            v[8]  = 1.0f;
            v[9]  = 1.0f;
            v[10] = 1.0f;
            v[11] = 1.0f;
            v[12] = 80.0f;
            v[13] = 0.0f;
            v[14] = 0.0f;
            v[15] = 1.0f;
        }
        vertices.SetVertexs(0, particle);
        const std::array<uint16_t, 6> quad_indices { 0, 1, 3, 1, 2, 3 };
        indices.AssignHalf(0, quad_indices);
        indices.SetRenderDataCount(3);
        dynamic_mesh->SetDirty();

        for (int frame = 0; frame < 5; ++frame) {
            ASSERT_TRUE(render.drawFrame(*loaded.scene)) << render.lastError();
            loaded.scene->PassFrameTime(1.0 / 60.0);
        }
        const auto filled = ReadOutput(render, *loaded.scene);
        EXPECT_NE(filled, empty)
            << "a sprite-trail layout uploaded after the graph was compiled never reached the target";

        render.destroy();
    }
}

namespace
{

/// Wallpaper Engine's own shipped assets, where the editor's particle renderer
/// previews live. Resolved from the environment, never from a fixed home
/// directory; absent on a clean checkout, in which case the test below skips.
std::filesystem::path LocalSceneAssetsRoot()
{
    if (const char* assets = std::getenv("WE_TEST_ASSETS"); assets != nullptr && *assets != '\0') {
        return assets;
    }
    const char* home = std::getenv("HOME");
    if (home == nullptr || *home == '\0') return {};
    return std::filesystem::path(home) / "Library/Application Support/WallpaperMachine/SceneAssets";
}

std::size_t DifferingBytes(const std::vector<uint8_t>& a, const std::vector<uint8_t>& b)
{
    if (a.size() != b.size()) return std::max(a.size(), b.size());
    std::size_t differing = 0;
    for (std::size_t i = 0; i < a.size(); ++i) differing += a[i] != b[i] ? 1u : 0u;
    return differing;
}

} // namespace

TEST_F(MetalSceneDraw, TheShippedRopeAndTrailPreviewScenesAreParsedTranslatedAndDrawnNatively)
{
    // The production path end to end, on content this repository does not own:
    // the real project file, the real particle definition, the author's own
    // `genericparticle` / `genericropeparticle` shaders through the structured
    // translation, the shared simulation, and this backend's dynamic upload.
    // What it proves is that each renderer is accepted and that simulated
    // geometry reaches the target. It does not judge how the result looks.
    const auto assets = LocalSceneAssetsRoot();
    const auto previews = assets / "scenes/particleelementpreviews";
    if (assets.empty() || ! std::filesystem::is_directory(previews)) {
        GTEST_SKIP() << "Wallpaper Engine's shipped assets are not installed here; the rope, rope "
                        "trail and sprite trail renderers were not exercised on real content";
    }

    for (const std::string name : { "spritetrail", "rope", "ropetrail" }) {
        SCOPED_TRACE(name);
        const auto directory = previews / name;
        const auto project   = directory / "project.json";
        if (! std::filesystem::is_regular_file(project)) {
            ADD_FAILURE() << "the shipped assets have no preview scene for this renderer";
            continue;
        }

        // The same variable the offscreen probe honours, so one seed makes the
        // two backends simulate the same particles and their frames comparable.
        if (const char* seed = std::getenv("WE_TEST_RANDOM_SEED")) {
            Random::seed(static_cast<uint32_t>(std::strtoul(seed, nullptr, 10)));
        }
        LoadedScene loaded;
        ASSERT_TRUE(loaded.vfs.Mount("/assets", fs::CreatePhysicalFs(assets.string()), "assets"));
        ASSERT_TRUE(loaded.vfs.Mount("/assets", fs::CreatePhysicalFs(directory.string()), "scene"));
        ASSERT_TRUE(loaded.vfs.Mount(
            "/cache", fs::CreatePhysicalFs((root_ / ("cache-" + name)).string(), true), "cache"));
        InstallVirtualAssets(loaded.vfs);
        std::string error;
        ASSERT_TRUE(ParseProjectProperties(project.string(), &loaded.properties, &error)) << error;
        auto source = loaded.vfs.Open("/assets/scene.json");
        ASSERT_NE(source, nullptr);
        WPSceneParser parser;
        loaded.scene = parser.Parse(SceneParseRequest {
                                        .scene_id           = "metal-preview-" + name,
                                        .project_path       = project.string(),
                                        .project_properties = &loaded.properties,
                                    },
                                    source->ReadAllStr(), loaded.vfs, loaded.sound);
        ASSERT_NE(loaded.scene, nullptr);
        ASSERT_NE(loaded.scene->paritileSys, nullptr);
        ASSERT_TRUE(loaded.scene->paritileSys->HasEmitters())
            << "the preview scene's particle object did not load";

        const auto selection = SelectSceneBackend(*loaded.scene);
        ASSERT_EQ(selection.backend, SceneBackend::NativeMetal) << selection.fallback_reason;

        @autoreleasepool {
            id<MTLDevice> device       = MTLCreateSystemDefaultDevice();
            CAMetalLayer* layer        = [CAMetalLayer layer];
            layer.device               = device;
            layer.pixelFormat          = MTLPixelFormatBGRA8Unorm;
            layer.drawableSize         = CGSizeMake(512, 512);
            layer.framebufferOnly      = NO;

            MetalRender         render;
            MetalRenderInitInfo info {
                .metal_layer          = (__bridge void*)layer,
                .width                = 512,
                .height               = 512,
                .render_width         = 512,
                .render_height        = 512,
                .display_scale_factor = 1.0,
            };
            ASSERT_TRUE(render.init(info)) << render.lastError();
            auto graph = sceneToRenderGraph(*loaded.scene);
            ASSERT_NE(graph, nullptr);
            ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
            render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);

            // Before the first tick nothing has been emitted.
            ASSERT_TRUE(render.drawFrame(*loaded.scene)) << render.lastError();
            const auto empty = ReadOutput(render, *loaded.scene);
            ASSERT_FALSE(empty.empty());

            // The wallpaper's own frame order: simulate, tick, draw, pass time.
            for (int frame = 0; frame < 90; ++frame) {
                loaded.scene->paritileSys->Emitt();
                if (loaded.scene->runtime != nullptr) loaded.scene->runtime->Tick(1.0 / 60.0);
                ASSERT_TRUE(render.drawFrame(*loaded.scene)) << "frame " << frame << ": "
                                                             << render.lastError();
                loaded.scene->PassFrameTime(1.0 / 60.0);
            }
            const auto simulated = ReadOutput(render, *loaded.scene);
            EXPECT_GT(DifferingBytes(simulated, empty), 64u)
                << "a second and a half of simulation drew nothing through the native backend";

            // Opt-in, for looking at the result by hand: the same variable the
            // offscreen probe writes its frames under. Nothing is written
            // otherwise, and nothing here reads a display.
            if (const char* output = std::getenv("WE_TEST_OUTPUT");
                output != nullptr && *output != '\0' && simulated.size() % 4 == 0) {
                const std::size_t pixels = simulated.size() / 4;
                const std::size_t side   = static_cast<std::size_t>(std::sqrt(double(pixels)));
                if (side * side == pixels) {
                    std::filesystem::create_directories(output);
                    std::ofstream image(std::filesystem::path(output) / ("metal-" + name + ".ppm"),
                                        std::ios::binary);
                    image << "P6\n" << side << " " << side << "\n255\n";
                    for (std::size_t i = 0; i < pixels; ++i) {
                        image.write(reinterpret_cast<const char*>(simulated.data() + i * 4), 3);
                    }
                }
            }

            render.destroy();
        }
    }
}

TEST_F(MetalSceneDraw, TheShippedImageShaderSkinsAPuppetThroughTheNativeBackend)
{
    // The probe shader above proves the matrix convention; this proves the
    // author's own `genericimage2`, compiled with the two combos the model
    // parser gives a puppet, survives the structured translation with a bone
    // array the runtime can fill and bone-weight inputs the mesh can feed.
    const auto assets = LocalSceneAssetsRoot();
    if (assets.empty() || ! std::filesystem::is_regular_file(assets / "shaders/genericimage2.vert")) {
        GTEST_SKIP() << "Wallpaper Engine's shipped shaders are not installed here; the real "
                        "skinning shader was not translated";
    }

    const auto directory = root_ / "real-skin-project";
    const std::map<std::string, std::string> files {
        { "project.json",
          R"({"title":"Metal puppet probe","type":"scene","file":"scene.json","general":{"properties":{}}})" },
        { "models/tile.json", R"({"width":256,"height":192,"material":"materials/skin.json"})" },
        { "materials/skin.json",
          R"({"passes":[{"shader":"genericimage2","blending":"translucent","cullmode":"nocull",)"
          R"("depthtest":"disabled","depthwrite":"disabled","textures":["util/white"],)"
          R"("combos":{"SKINNING":1,"BONECOUNT":2}}]})" },
        { "scene.json",
          R"({"camera":{"center":[0,0,0],"eye":[0,0,1],"up":[0,1,0]},)"
          R"("general":{"ambientcolor":[0,0,0],"skylightcolor":[0,0,0],"clearcolor":[0.0,0.0,0.0],)"
          R"("cameraparallax":false,"orthogonalprojection":{"width":384,"height":256}},)"
          R"("objects":[{"id":1,"name":"tile","image":"models/tile.json","origin":[192,128,0],)"
          R"("scale":[1,1,1],"angles":[0,0,0],"visible":true}]})" },
    };
    for (const auto& [name, contents] : files) {
        const auto path = directory / name;
        std::filesystem::create_directories(path.parent_path());
        std::ofstream(path) << contents;
    }

    LoadedScene loaded;
    ASSERT_TRUE(loaded.vfs.Mount("/assets", fs::CreatePhysicalFs(assets.string()), "assets"));
    ASSERT_TRUE(loaded.vfs.Mount("/assets", fs::CreatePhysicalFs(directory.string()), "scene"));
    ASSERT_TRUE(loaded.vfs.Mount(
        "/cache", fs::CreatePhysicalFs((root_ / "real-skin-cache").string(), true), "cache"));
    InstallVirtualAssets(loaded.vfs);
    std::string error;
    const auto  project = directory / "project.json";
    ASSERT_TRUE(ParseProjectProperties(project.string(), &loaded.properties, &error)) << error;
    auto source = loaded.vfs.Open("/assets/scene.json");
    ASSERT_NE(source, nullptr);
    WPSceneParser parser;
    loaded.scene = parser.Parse(SceneParseRequest {
                                    .scene_id           = "metal-real-skin",
                                    .project_path       = project.string(),
                                    .project_properties = &loaded.properties,
                                },
                                source->ReadAllStr(), loaded.vfs, loaded.sound);
    ASSERT_NE(loaded.scene, nullptr);

    auto* node = FirstDrawableNode(loaded.scene->sceneGraph.get());
    ASSERT_NE(node, nullptr);
    auto material = node->Mesh()->MaterialSlotPtr(0);
    ASSERT_NE(material, nullptr);
    ASSERT_NE(material->customShader.shader, nullptr);
    const auto* program = material->customShader.shader->metal_program.get();
    ASSERT_NE(program, nullptr);
    ASSERT_TRUE(program->ok()) << program->error;

    MetalShaderReflection reflection;
    std::string           reflection_error;
    ASSERT_TRUE(ParseMetalShaderReflection(program->reflection_json, reflection, &reflection_error))
        << reflection_error;
    const auto* bones = reflection.member("g_Bones");
    ASSERT_NE(bones, nullptr) << "the skinning combo did not reach the translated program";
    EXPECT_EQ(bones->array_count, 2u);
    EXPECT_EQ(bones->array_stride, 64u);

    auto layer = MakeSlidingPuppetLayer();
    node->AddMesh(MakeTwoQuadSkinnedMesh(material));
    WPShaderValueData data;
    data.puppet_layer = layer;
    static_cast<WPShaderValueUpdater*>(loaded.scene->shaderValueUpdater.get())
        ->SetNodeData(node, data);

    const auto selection = SelectSceneBackend(*loaded.scene);
    ASSERT_EQ(selection.backend, SceneBackend::NativeMetal) << selection.fallback_reason;

    @autoreleasepool {
        id<MTLDevice> device       = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer_view   = [CAMetalLayer layer];
        layer_view.device          = device;
        layer_view.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer_view.drawableSize    = CGSizeMake(640, 360);
        layer_view.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer_view,
            .width                = 640,
            .height               = 360,
            .render_width         = 640,
            .render_height        = 360,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();
        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
        render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);

        ASSERT_TRUE(render.drawFrame(*loaded.scene)) << render.lastError();
        const auto at_rest = ReadOutput(render, *loaded.scene);
        loaded.scene->PassFrameTime(0.2);
        ASSERT_TRUE(render.drawFrame(*loaded.scene)) << render.lastError();
        const auto slid = ReadOutput(render, *loaded.scene);
        EXPECT_NE(slid, at_rest) << "the author's skinning shader drew the same picture for two poses";

        render.destroy();
    }
}

TEST_F(MetalSceneDraw, ARopeTrailPastTheOldSixteenBitIndexLimitStaysARopeTrail)
{
    // 5 000 particles x 10 segments x authored subdivision 3 is 150 000 quads,
    // past the old packed 16-bit cap of 16 384. It must remain a rope trail
    // with 32-bit indices, not a sprite trail and not a reduced subdivision.
    const auto assets  = LocalSceneAssetsRoot();
    const auto preview = assets / "scenes/particleelementpreviews/ropetrail";
    if (assets.empty() || ! std::filesystem::is_regular_file(preview / "project.json")) {
        GTEST_SKIP() << "Wallpaper Engine's shipped assets are not installed here; the rope trail "
                        "index-width path was not exercised";
    }

    const auto directory = root_ / "big-ropetrail";
    std::filesystem::create_directories(directory);
    std::filesystem::copy(preview, directory, std::filesystem::copy_options::recursive);
    const auto particle_path = directory / "particles/new_particle_system.json";
    nlohmann::json particle;
    {
        std::ifstream input(particle_path);
        ASSERT_TRUE(input.good());
        particle = nlohmann::json::parse(input);
    }
    particle["maxcount"] = 5000;
    std::ofstream(particle_path) << particle.dump();

    LoadedScene loaded;
    ASSERT_TRUE(loaded.vfs.Mount("/assets", fs::CreatePhysicalFs(assets.string()), "assets"));
    ASSERT_TRUE(loaded.vfs.Mount("/assets", fs::CreatePhysicalFs(directory.string()), "scene"));
    ASSERT_TRUE(loaded.vfs.Mount(
        "/cache", fs::CreatePhysicalFs((root_ / "big-ropetrail-cache").string(), true), "cache"));
    InstallVirtualAssets(loaded.vfs);
    std::string error;
    const auto  project = directory / "project.json";
    ASSERT_TRUE(ParseProjectProperties(project.string(), &loaded.properties, &error)) << error;
    auto source = loaded.vfs.Open("/assets/scene.json");
    ASSERT_NE(source, nullptr);
    WPSceneParser parser;
    loaded.scene = parser.Parse(SceneParseRequest {
                                    .scene_id           = "metal-big-ropetrail",
                                    .project_path       = project.string(),
                                    .project_properties = &loaded.properties,
                                },
                                source->ReadAllStr(), loaded.vfs, loaded.sound);
    ASSERT_NE(loaded.scene, nullptr);
    ASSERT_TRUE(loaded.scene->paritileSys->HasEmitters())
        << "the rope trail past the old 16-bit cap was dropped";

    auto* node = FirstDrawableNode(loaded.scene->sceneGraph.get());
    ASSERT_NE(node, nullptr);
    ASSERT_GT(node->Mesh()->VertexCount(), 0u);
    const auto& vertices = node->Mesh()->GetVertexArray(0);
    EXPECT_TRUE(vertices.GetOption(WE_PRENDER_ROPE));
    EXPECT_TRUE(vertices.GetOption(WE_PRENDER_TRAIL));
    EXPECT_TRUE(vertices.GetOption(WE_PRENDER_ROPETRAIL));
    EXPECT_FALSE(vertices.GetOption(WE_PRENDER_SPRITE));
    ASSERT_GT(node->Mesh()->IndexCount(), 0u);
    const auto& indices = node->Mesh()->GetIndexArray(0);
    EXPECT_EQ(indices.Width(), SceneIndexWidth::UInt32);
    EXPECT_GT(indices.QuadCapacity(), kMaxPackedUInt16Quads);

    const auto selection = SelectSceneBackend(*loaded.scene);
    EXPECT_EQ(selection.backend, SceneBackend::NativeMetal) << selection.fallback_reason;
}

namespace
{

uint16_t PackageVersionOf(const std::string& path)
{
    std::ifstream file(path, std::ios::binary);
    uint32_t      length = 0;
    file.read(reinterpret_cast<char*>(&length), sizeof(length));
    if (! file || length < 5 || length > 64) return SceneParseRequest::kUnknownPkgVersion;
    std::string stamp(length, '\0');
    file.read(stamp.data(), length);
    if (! file || ! stamp.starts_with("PKGV")) return SceneParseRequest::kUnknownPkgVersion;
    uint16_t version       = 0;
    const auto [end, code] = std::from_chars(stamp.data() + 4, stamp.data() + stamp.size(), version);
    return code == std::errc {} && end == stamp.data() + stamp.size()
               ? version
               : SceneParseRequest::kUnknownPkgVersion;
}

} // namespace

namespace {
/// Feeds the scene the now-playing state the app would deliver, with the same
/// two variables `offscreen_scene_probe` takes and the same meaning.
///
/// A wallpaper whose background is drawn from the current cover renders as flat
/// grey without one, so the two backends cannot be compared on the thing that
/// actually differs unless both can be given the same cover.
void InjectSystemMediaForMetal(Scene& scene) {
    const char* events  = std::getenv("WE_TEST_MEDIA_EVENTS");
    const char* artwork = std::getenv("WE_TEST_MEDIA_ARTWORK");
    if (events == nullptr && artwork == nullptr) return;
    if (scene.runtime == nullptr) return;
    scene.runtime->SetMediaIntegrationEnabled(true);

    if (artwork != nullptr) {
        unsigned width = 0, height = 0, rgb = 0;
        if (std::sscanf(artwork, "%ux%u:%x", &width, &height, &rgb) == 3 && width >= 1 &&
            width <= 4096 && height >= 1 && height <= 4096) {
            auto* images = dynamic_cast<RuntimeImageSource*>(scene.imageParser.get());
            // Said out loud rather than skipped quietly: a run that could not
            // publish the cover renders the same flat grey as a backend that
            // dropped it, and reading that as a backend defect is a mistake
            // this harness has already caused once.
            std::cout << "[ MEDIA    ] cover published: "
                      << (images != nullptr ? "yes" : "NO -- no runtime image source")
                      << std::endl;
            if (images != nullptr) {
                std::vector<uint8_t> rgba(std::size_t(width) * height * 4);
                for (std::size_t i = 0; i < rgba.size(); i += 4) {
                    rgba[i + 0] = uint8_t((rgb >> 16) & 0xFF);
                    rgba[i + 1] = uint8_t((rgb >> 8) & 0xFF);
                    rgba[i + 2] = uint8_t(rgb & 0xFF);
                    rgba[i + 3] = 0xFF;
                }
                PublishSystemMediaArtwork(*images, width, height, rgba.data(), rgba.size());
            }
        }
    }

    if (events != nullptr) {
        const auto parsed = nlohmann::json::parse(events, nullptr, false);
        if (!parsed.is_discarded() && parsed.is_array()) {
            for (const auto& event : parsed) {
                if (event.is_object()) scene.runtime->DispatchMediaEventJson(event.dump());
            }
            scene.runtime->Tick(1.0 / 60.0);
        }
    }
}

/// CPU time this thread has used, in milliseconds. Thread time rather than
/// wall time: `drawFrame` waits on the in-flight semaphore while the GPU
/// catches up, and that wait is not work the frame costs the CPU.
double ThreadCpuMilliseconds()
{
    timespec now {};
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &now);
    return double(now.tv_sec) * 1000.0 + double(now.tv_nsec) / 1.0e6;
}
} // namespace

TEST_F(MetalSceneDraw, LocalProjectsNamedByTheEnvironmentRunThroughTheNativeBackend)
{
    // For content this repository cannot carry -- a real puppet most of all.
    // `WE_TEST_METAL_PROJECTS` is a colon-separated list of `project.json`
    // paths; each is parsed exactly as the wallpaper loads it and its backend
    // decision is printed. A scene that falls back is reported with its reason
    // and is not a failure here: what must hold is that an ACCEPTED scene
    // prepares and draws every frame, because an accepted scene has no other
    // renderer behind it. `WE_TEST_PROPERTIES` and `WE_TEST_AUDIO_HZ` mean what
    // they mean for `offscreen_scene_probe`: a wallpaper whose layer is gated
    // on a saved property, or whose shader reads the spectrum, draws nothing
    // worth comparing without them, and this backend had no way to supply
    // either.
    const char* listed = std::getenv("WE_TEST_METAL_PROJECTS");
    const auto  assets = LocalSceneAssetsRoot();
    if (listed == nullptr || *listed == '\0' || assets.empty() ||
        ! std::filesystem::is_directory(assets)) {
        GTEST_SKIP() << "WE_TEST_METAL_PROJECTS names no local project; no real wallpaper was "
                        "drawn natively";
    }
    // Its own knob, not the probe's `WE_TEST_FRAMES`: that one counts samples a
    // `WE_TEST_FRAME_STEP` apart, and the matched-time recipe sets it for the
    // Vulkan run alone. Sharing it would silently move this frame's scene time.
    // Two frames at least, because frame 0 is excluded from the averages.
    int frame_count = 120;
    if (const char* value = std::getenv("WE_TEST_METAL_FRAMES")) {
        const std::string_view text(value);
        const auto parsed = std::from_chars(text.data(), text.data() + text.size(), frame_count);
        ASSERT_TRUE(parsed.ec == std::errc {} && parsed.ptr == text.data() + text.size() &&
                    frame_count >= 2 && frame_count <= 3600)
            << "WE_TEST_METAL_FRAMES must be 2..3600, not \"" << value << "\"";
    }
    double frame_step = 1.0 / 60.0;
    if (const char* value = std::getenv("WE_TEST_METAL_FRAME_STEP")) {
        char* end = nullptr;
        frame_step = std::strtod(value, &end);
        ASSERT_TRUE(end != value && *end == '\0' && std::isfinite(frame_step) &&
                    frame_step > 0.0 && frame_step <= 1.0);
    }

    std::vector<std::string> projects;
    for (std::string_view rest = listed; ! rest.empty();) {
        const auto colon = rest.find(':');
        if (colon != 0) projects.emplace_back(rest.substr(0, colon));
        if (colon == std::string_view::npos) break;
        rest.remove_prefix(colon + 1);
    }

    // Reusing a completed result is a correctness claim about the passes it
    // skips. Turning it off is how a scene that looks wrong under it can be
    // compared with the same scene drawn every frame. Process-global, so it is
    // set once around the whole loop and put back: an unfiltered run must not
    // carry this choice into any later test.
    const bool optimization_was = wallpaper::vulkan::SceneOptimizationEnabled();
    if (const char* opt = std::getenv("WE_TEST_SCENE_OPTIMIZATION")) {
        wallpaper::vulkan::SetSceneOptimizationEnabled(std::string_view(opt) != "0");
    }

    std::size_t index = 0;
    for (const auto& project : projects) {
        SCOPED_TRACE(project);
        if (const char* seed = std::getenv("WE_TEST_RANDOM_SEED")) {
            Random::seed(static_cast<uint32_t>(std::strtoul(seed, nullptr, 10)));
        }
        const std::string label = "local-" + std::to_string(index++);

        SceneSourcePaths paths;
        std::string      error;
        ASSERT_TRUE(ResolveSceneSourcePaths(project, &paths, &error)) << error;

        LoadedScene loaded;
        ASSERT_TRUE(loaded.vfs.Mount("/assets", fs::CreatePhysicalFs(assets.string()), "assets"));
        ASSERT_TRUE(MountSceneSource(loaded.vfs, paths, &error)) << error;
        ASSERT_TRUE(loaded.vfs.Mount(
            "/cache", fs::CreatePhysicalFs((root_ / ("cache-" + label)).string(), true), "cache"));
        InstallVirtualAssets(loaded.vfs);
        ASSERT_TRUE(ParseProjectProperties(project, &loaded.properties, &error)) << error;
        if (const char* json = std::getenv("WE_TEST_PROPERTIES")) {
            ProjectProperties overrides;
            ASSERT_TRUE(ParseFlatProjectPropertyOverrideJson(json, &overrides, &error)) << error;
            loaded.properties = MergeProjectProperties(loaded.properties, overrides);
        }
        auto source = loaded.vfs.Open("/assets/" + paths.pkg_entry);
        ASSERT_NE(source, nullptr);
        WPSceneParser parser;
        loaded.scene = parser.Parse(SceneParseRequest {
                                        .scene_id           = paths.scene_id,
                                        .project_path       = project,
                                        .project_properties = &loaded.properties,
                                        .pkg_version        = PackageVersionOf(paths.pkg_path),
                                    },
                                    source->ReadAllStr(), loaded.vfs, loaded.sound);
        ASSERT_NE(loaded.scene, nullptr);

        InjectSystemMediaForMetal(*loaded.scene);
        const auto selection = SelectSceneBackend(*loaded.scene);
        if (selection.backend != SceneBackend::NativeMetal) {
            std::cout << "[ LOCAL    ] " << paths.scene_id << ": Compatibility -- "
                      << selection.fallback_reason << std::endl;
            continue;
        }
        // Runtime ticks before the graph is built, as `offscreen_scene_probe`
        // takes 40 of them. Comparing a scripted or timed scene with that
        // probe needs both runtime clocks on the same second, so this matches
        // it on request; the scene clock is not advanced by it, there or here.
        if (const char* value = std::getenv("WE_TEST_METAL_WARMUP_TICKS");
            value != nullptr && loaded.scene->runtime != nullptr) {
            const int ticks = std::atoi(value);
            ASSERT_TRUE(ticks >= 0 && ticks <= 3600) << "WE_TEST_METAL_WARMUP_TICKS " << value;
            for (int tick = 0; tick < ticks; ++tick) {
                loaded.scene->runtime->Tick(1.0 / 60.0);
                loaded.scene->runtime->PumpTextLayerCache();
                std::this_thread::sleep_for(std::chrono::milliseconds(5));
            }
            (void)loaded.scene->runtime->ConsumeSceneGraphMutationFlag();
        }

        // A real surface is the size of the display it is on, and screen-space
        // shader inputs -- texel size above all -- follow it. Comparing this
        // backend's output with another's is only meaningful when both
        // rasterize the same extent, so the size is overridable.
        uint32_t surface_width  = 960;
        uint32_t surface_height = 540;
        if (const char* size = std::getenv("WE_TEST_METAL_SURFACE")) {
            unsigned w = 0, h = 0;
            if (std::sscanf(size, "%ux%u", &w, &h) == 2 && w > 0 && h > 0) {
                surface_width  = w;
                surface_height = h;
            }
        }
        @autoreleasepool {
            id<MTLDevice> device       = MTLCreateSystemDefaultDevice();
            CAMetalLayer* layer        = [CAMetalLayer layer];
            layer.device               = device;
            layer.pixelFormat          = MTLPixelFormatBGRA8Unorm;
            layer.drawableSize         = CGSizeMake(surface_width, surface_height);
            layer.framebufferOnly      = NO;

            MetalRender         render;
            MetalRenderInitInfo info {
                .metal_layer          = (__bridge void*)layer,
                .width                = static_cast<uint16_t>(surface_width),
                .height               = static_cast<uint16_t>(surface_height),
                .render_width         = static_cast<uint16_t>(surface_width),
                .render_height        = static_cast<uint16_t>(surface_height),
                .display_scale_factor = 1.0,
            };
            ASSERT_TRUE(render.init(info)) << render.lastError();
            auto graph = sceneToRenderGraph(*loaded.scene);
            ASSERT_NE(graph, nullptr);
            if (! render.compileRenderGraph(*loaded.scene, *graph)) {
                // The production router treats this as a fallback too, with
                // this text as the reason.
                std::cout << "[ LOCAL    ] " << paths.scene_id
                          << ": Compatibility after prepare -- " << render.lastError() << std::endl;
                render.destroy();
                continue;
            }
            render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTCROP);
            tests::SceneProbeControls controls;
            loaded.scene->runtime->SetScreenResolution(
                Eigen::Vector2f(surface_width, surface_height));
            const auto capture = [&](const std::string& filename) {
                const char* output = std::getenv("WE_TEST_OUTPUT");
                if (output == nullptr || *output == '\0') return;
                uint32_t width = 0, height = 0;
                std::vector<uint8_t> rgba;
                ASSERT_TRUE(render.ReadRenderTargetForTests(
                    loaded.scene->ResolveRenderTargetName(SpecTex_Default), rgba, width, height));
                std::filesystem::create_directories(output);
                std::ofstream image(std::filesystem::path(output) / filename, std::ios::binary);
                image << "P6\n" << width << " " << height << "\n255\n";
                for (std::size_t i = 0; i < std::size_t(width) * height; ++i)
                    image.write(reinterpret_cast<const char*>(rgba.data() + i * 4), 3);
            };

            const char* audio_hz = std::getenv("WE_TEST_AUDIO_HZ");
            if (audio_hz != nullptr && loaded.scene->runtime != nullptr) {
                loaded.scene->runtime->SetAudioResponseEnabled(true);
            }
            std::vector<uint8_t> first;
            // Frame 0 compiles and uploads; the steady state starts after it.
            MetalRender::FrameEncodeCountsForTests encodes;
            double                                  draw_cpu_ms = 0.0;
            int                                     measured    = 0;
            for (int frame = 0; frame < frame_count; ++frame) {
                if (audio_hz != nullptr) {
                    // Synthetic PCM only, analysed by the same service the
                    // desktop tap feeds.
                    std::array<float, audio::kAudioResponseWindowFrames> pcm {};
                    const double hz = std::strtod(audio_hz, nullptr);
                    for (std::size_t i = 0; i < pcm.size(); ++i) {
                        pcm[i] = controls.audioSample(i, hz);
                    }
                    const auto generation = audio::CurrentAudioSpectrumSnapshot().generation;
                    std::string audio_error;
                    ASSERT_TRUE(audio::SubmitMonoAudioFrames(audio::kAudioResponseSampleRate,
                                                             uint32_t(pcm.size()),
                                                             pcm.data(),
                                                             &audio_error))
                        << audio_error;
                    const auto deadline =
                        std::chrono::steady_clock::now() + std::chrono::seconds(2);
                    while (audio::CurrentAudioSpectrumSnapshot().generation <= generation &&
                           std::chrono::steady_clock::now() < deadline) {
                        std::this_thread::sleep_for(std::chrono::milliseconds(1));
                    }
                }
                if (controls.hasInput())
                    controls.input(*loaded.scene, frame, render.CursorMapping(*loaded.scene));
                loaded.scene->paritileSys->Emitt();
                if (loaded.scene->runtime != nullptr) {
                    loaded.scene->runtime->Tick(frame_step);
                    loaded.scene->runtime->PumpTextLayerCache();
                    if (loaded.scene->runtime->ConsumeSceneGraphMutationFlag()) {
                        ASSERT_TRUE(render.clearLastRenderGraph()) << render.lastError();
                        graph = sceneToRenderGraph(*loaded.scene);
                        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph))
                            << render.lastError();
                    }
                }
                if (loaded.scene->shaderValueUpdater != nullptr) {
                    loaded.scene->shaderValueUpdater->FrameBegin();
                }
                const double cpu_before = ThreadCpuMilliseconds();
                ASSERT_TRUE(render.drawFrame(*loaded.scene))
                    << "frame " << frame << ": " << render.lastError();
                const double cpu_after = ThreadCpuMilliseconds();
                if (frame > 0) {
                    const auto counts = render.LastFrameEncodeCountsForTests();
                    encodes.render_passes += counts.render_passes;
                    encodes.scene_output_passes += counts.scene_output_passes;
                    encodes.blit_passes += counts.blit_passes;
                    draw_cpu_ms += cpu_after - cpu_before;
                    ++measured;
                }
                if (frame == 0) first = ReadOutput(render, *loaded.scene);
                if (controls.sample(frame)) {
                    capture("frame-" + std::to_string(frame) + ".ppm");
                    if (const char* output = std::getenv("WE_TEST_OUTPUT"))
                        controls.state(*loaded.scene, frame, output);
                }
                loaded.scene->PassFrameTime(frame_step);
            }
            const auto last = ReadOutput(render, *loaded.scene);
            std::cout << "[ LOCAL    ] " << paths.scene_id << ": Native Metal, " << frame_count << " frames drawn, "
                      << DifferingBytes(first, last) << " bytes differ between the first and the last"
                      << std::endl;
            char encode_line[256];
            std::snprintf(encode_line, sizeof(encode_line),
                          "%.1f render passes/frame (%.1f on the scene output), %.1f blits/frame, "
                          "%.2f ms CPU per drawFrame",
                          double(encodes.render_passes) / measured,
                          double(encodes.scene_output_passes) / measured,
                          double(encodes.blit_passes) / measured, draw_cpu_ms / measured);
            std::cout << "[ LOCAL    ] " << paths.scene_id << ": " << encode_line << std::endl;
            // The target figure is this scene's own; the device figure is
            // process-wide and includes the layer's drawables, so it varies
            // between runs of the same scene.
            std::cout << "[ LOCAL    ] " << paths.scene_id
                      << ": render target bytes=" << render.RenderTargetBytesForTests()
                      << " device allocated bytes=" << device.currentAllocatedSize << std::endl;

            capture("metal-" + label + ".ppm");

            // Named intermediates, not just the final image. When this backend
            // and another disagree about a scene, the question is which pass
            // first diverges, and that is answered by holding the same target
            // from both against each other rather than by reading code.
            if (const char* wanted = std::getenv("WE_TEST_METAL_DUMP_TARGETS");
                wanted != nullptr && *wanted != '\0') {
                const char* output = std::getenv("WE_TEST_OUTPUT");
                // Target names carry a per-run suffix derived from the object
                // that owns them, so naming one across two processes is not
                // possible. `*` asks for every target the scene declares, which
                // is the same set on either backend.
                std::vector<std::string> keys;
                if (std::string_view(wanted) == "*") {
                    for (const auto& [name, target] : loaded.scene->renderTargets) {
                        (void)target;
                        keys.push_back(name);
                    }
                    std::sort(keys.begin(), keys.end());
                } else {
                    for (std::string_view rest = wanted; ! rest.empty();) {
                        const auto colon = rest.find(':');
                        if (colon != 0) keys.emplace_back(rest.substr(0, colon));
                        if (colon == std::string_view::npos) break;
                        rest.remove_prefix(colon + 1);
                    }
                }
                for (const auto& key : keys) {
                    uint32_t             width = 0, height = 0;
                    std::vector<uint8_t> rgba;
                    if (! render.ReadRenderTargetForTests(loaded.scene->ResolveRenderTargetName(key),
                                                          rgba, width, height) ||
                        width == 0 || height == 0) {
                        std::cout << "[ LOCAL    ] " << paths.scene_id << ": no target named " << key
                                  << std::endl;
                        continue;
                    }
                    double sum = 0.0;
                    for (std::size_t i = 0; i < std::size_t(width) * height; ++i) {
                        sum += (rgba[i * 4] + rgba[i * 4 + 1] + rgba[i * 4 + 2]) / 3.0;
                    }
                    std::cout << "[ LOCAL    ] " << paths.scene_id << ": " << key << " " << width << "x"
                              << height << " mean luma "
                              << sum / (double(width) * double(height)) << std::endl;
                    if (output == nullptr || *output == '\0') continue;
                    std::filesystem::create_directories(output);
                    std::string safe = key;
                    std::replace(safe.begin(), safe.end(), '/', '_');
                    std::ofstream image(std::filesystem::path(output) / ("metal-" + label + "-" + safe + ".ppm"),
                                        std::ios::binary);
                    image << "P6\n" << width << " " << height << "\n255\n";
                    for (std::size_t i = 0; i < std::size_t(width) * height; ++i) {
                        image.write(reinterpret_cast<const char*>(rgba.data() + i * 4), 3);
                    }
                    // Alpha on its own. Effects that weight by coverage -- the
                    // bokeh downsample divides by the sum of its taps' alpha --
                    // make completely different colour from the same RGB when
                    // alpha differs, so a colour-only dump cannot explain them.
                    if (std::getenv("WE_TEST_DUMP_ALPHA") != nullptr) {
                        std::ofstream alpha(std::filesystem::path(output) /
                                                ("metal-" + label + "-" + safe + "-alpha.ppm"),
                                            std::ios::binary);
                        alpha << "P6\n" << width << " " << height << "\n255\n";
                        for (std::size_t i = 0; i < std::size_t(width) * height; ++i) {
                            const char grey[3] { static_cast<char>(rgba[i * 4 + 3]),
                                                 static_cast<char>(rgba[i * 4 + 3]),
                                                 static_cast<char>(rgba[i * 4 + 3]) };
                            alpha.write(grey, 3);
                        }
                    }
                }
            }
            render.destroy();
        }
    }
    wallpaper::vulkan::SetSceneOptimizationEnabled(optimization_was);
}

TEST_F(MetalSceneDraw, LocalProjectsDrawTheSamePictureOnBothRenderers)
{
    // The two renderers in one harness: each project is parsed twice exactly
    // as a wallpaper loads it, seeded and clocked identically, and drawn
    // through `SceneRendererHandle` on a layer no window owns -- once by the
    // compatibility backend, once by the native one. The final composition of
    // the last frame comes back through the poster path both backends share,
    // so the two pictures differ only by what the renderers did. Prints the
    // mean absolute difference per channel and the share of pixels off by more
    // than 48, and writes both pictures under `WE_TEST_OUTPUT`. A diagnostic,
    // not a verdict: nothing is asserted about the size of a difference.
    // `WE_TEST_COMPARE_PROJECTS` is a colon-separated list of `project.json`
    // paths; `WE_TEST_METAL_FRAMES`, `WE_TEST_METAL_FRAME_STEP`,
    // `WE_TEST_METAL_WARMUP_TICKS`, `WE_TEST_RANDOM_SEED` and
    // `WE_TEST_PROPERTIES` mean what they mean for the local-project run, and
    // `WE_TEST_COMPARE_SURFACE` is the layer's `<width>x<height>` (960x540).
    const char* listed = std::getenv("WE_TEST_COMPARE_PROJECTS");
    const auto  assets = LocalSceneAssetsRoot();
    if (listed == nullptr || *listed == '\0' || assets.empty() ||
        ! std::filesystem::is_directory(assets)) {
        GTEST_SKIP() << "WE_TEST_COMPARE_PROJECTS names no local project";
    }
    int    frame_count = 120;
    double frame_step  = 1.0 / 60.0;
    int    warmup      = 0;
    if (const char* value = std::getenv("WE_TEST_METAL_FRAMES")) frame_count = std::atoi(value);
    if (const char* value = std::getenv("WE_TEST_METAL_FRAME_STEP")) frame_step = std::strtod(value, nullptr);
    if (const char* value = std::getenv("WE_TEST_METAL_WARMUP_TICKS")) warmup = std::atoi(value);
    ASSERT_TRUE(frame_count >= 1 && frame_count <= 3600 && frame_step > 0.0 && frame_step <= 1.0 &&
                warmup >= 0 && warmup <= 3600);
    uint32_t width = 960, height = 540;
    if (const char* size = std::getenv("WE_TEST_COMPARE_SURFACE")) {
        unsigned w = 0, h = 0;
        if (std::sscanf(size, "%ux%u", &w, &h) == 2 && w > 0 && h > 0 && w <= 8192 && h <= 8192) {
            width  = w;
            height = h;
        }
    }
    const char* output = std::getenv("WE_TEST_OUTPUT");

    std::vector<std::string> projects;
    for (std::string_view rest = listed; ! rest.empty();) {
        const auto colon = rest.find(':');
        if (colon != 0) projects.emplace_back(rest.substr(0, colon));
        if (colon == std::string_view::npos) break;
        rest.remove_prefix(colon + 1);
    }

    std::size_t index = 0;
    for (const auto& project : projects) {
        SCOPED_TRACE(project);
        const std::string label = "compare-" + std::to_string(index++);
        std::map<bool, RendererPicture> pictures;
        std::string             scene_id;
        for (const bool native : { false, true }) {
            SetSceneRendererPreference(native ? SceneRendererPreference::NativeMetalPreferred
                                              : SceneRendererPreference::Compatibility);
            if (const char* seed = std::getenv("WE_TEST_RANDOM_SEED")) {
                Random::seed(static_cast<uint32_t>(std::strtoul(seed, nullptr, 10)));
            }
            SceneSourcePaths paths;
            std::string      error;
            ASSERT_TRUE(ResolveSceneSourcePaths(project, &paths, &error)) << error;
            scene_id = paths.scene_id;
            LoadedScene loaded;
            ASSERT_TRUE(loaded.vfs.Mount("/assets", fs::CreatePhysicalFs(assets.string()), "assets"));
            ASSERT_TRUE(MountSceneSource(loaded.vfs, paths, &error)) << error;
            ASSERT_TRUE(loaded.vfs.Mount(
                "/cache",
                fs::CreatePhysicalFs((root_ / (label + (native ? "-native" : "-compat"))).string(), true),
                "cache"));
            InstallVirtualAssets(loaded.vfs);
            ASSERT_TRUE(ParseProjectProperties(project, &loaded.properties, &error)) << error;
            if (const char* json = std::getenv("WE_TEST_PROPERTIES")) {
                ProjectProperties overrides;
                ASSERT_TRUE(ParseFlatProjectPropertyOverrideJson(json, &overrides, &error)) << error;
                loaded.properties = MergeProjectProperties(loaded.properties, overrides);
            }
            auto source = loaded.vfs.Open("/assets/" + paths.pkg_entry);
            ASSERT_NE(source, nullptr);
            WPSceneParser parser;
            loaded.scene = parser.Parse(SceneParseRequest {
                                            .scene_id           = paths.scene_id,
                                            .project_path       = project,
                                            .project_properties = &loaded.properties,
                                            .pkg_version        = PackageVersionOf(paths.pkg_path),
                                        },
                                        source->ReadAllStr(), loaded.vfs, loaded.sound);
            ASSERT_NE(loaded.scene, nullptr);
            InjectSystemMediaForMetal(*loaded.scene);
            if (native) {
                const auto selection = SelectSceneBackend(*loaded.scene);
                if (selection.backend != SceneBackend::NativeMetal) {
                    std::cout << "[ COMPARE  ] " << scene_id << ": native refused -- "
                              << selection.fallback_reason << std::endl;
                    break;
                }
            }
            auto& scene = *loaded.scene;
            if (scene.runtime != nullptr) {
                for (int tick = 0; tick < warmup; ++tick) {
                    scene.runtime->Tick(1.0 / 60.0);
                    scene.runtime->PumpTextLayerCache();
                    std::this_thread::sleep_for(std::chrono::milliseconds(5));
                }
                (void)scene.runtime->ConsumeSceneGraphMutationFlag();
            }

            auto picture = DrawWithRenderer(scene, native, width, height, frame_count, frame_step);
            if (! picture.error.empty()) {
                std::cout << "[ COMPARE  ] " << scene_id << ": "
                          << (native ? "native" : "compatibility") << " -- " << picture.error
                          << std::endl;
                break;
            }
            pictures[native] = std::move(picture);
        }
        if (pictures.size() != 2) continue;
        const auto& a = pictures[false];
        const auto& b = pictures[true];
        ASSERT_EQ(a.width, b.width);
        ASSERT_EQ(a.height, b.height);
        double      total = 0.0;
        std::size_t off   = 0;
        for (std::size_t i = 0; i < a.rgb.size(); i += 3) {
            int worst = 0;
            for (std::size_t c = 0; c < 3; ++c) {
                const int d = std::abs(int(a.rgb[i + c]) - int(b.rgb[i + c]));
                total += d;
                worst = std::max(worst, d);
            }
            if (worst > 48) ++off;
        }
        std::printf("[ COMPARE  ] %s: mean abs difference %.3f, %.4f of pixels off by more than 48\n",
                    scene_id.c_str(), total / double(a.rgb.size()),
                    double(off) / double(a.rgb.size() / 3));
        if (output != nullptr && *output != '\0') {
            std::filesystem::create_directories(output);
            for (const auto& [native, picture] : pictures) {
                std::ofstream image(std::filesystem::path(output) /
                                        (scene_id + (native ? "-native.ppm" : "-compat.ppm")),
                                    std::ios::binary);
                image << "P6\n" << picture.width << " " << picture.height << "\n255\n";
                image.write(reinterpret_cast<const char*>(picture.rgb.data()),
                            std::streamsize(picture.rgb.size()));
            }
        }
    }
    SetSceneRendererPreference(SceneRendererPreference::Compatibility);
}

TEST_F(MetalSceneDraw, LayersSharingATargetShareOneRenderPassAndHiddenLayersCostNone)
{
    // Every card here draws straight into the scene's own image, so the whole
    // frame is one render pass: the clear and the draws after it share it, and
    // a hidden card starts none of its own. What the split must not change is
    // the picture: a hidden card draws exactly what a card that is not there
    // draws, and showing it changes the output.
    struct Variant
    {
        std::string name;
        std::string visible;
        bool        show;
    };
    const Variant variants[] = {
        { "hidden", R"({"user":"showmiddle","value":false})", false },
        { "dropped", "false", false },
        { "shown", R"({"user":"showmiddle","value":false})", true },
    };
    // Every frame is drawn in full, so the counts describe the split rather
    // than what reuse removed. Process-global, so it is put back however the
    // test ends.
    struct RestoreOptimization
    {
        bool was { wallpaper::vulkan::SceneOptimizationEnabled() };
        ~RestoreOptimization() { wallpaper::vulkan::SetSceneOptimizationEnabled(was); }
    } restore;
    wallpaper::vulkan::SetSceneOptimizationEnabled(false);

    std::map<std::string, std::vector<uint8_t>> pixels;
    for (const auto& variant : variants) {
        SCOPED_TRACE(variant.name);
        const auto  project = WriteLayeredFixture(root_ / variant.name, variant.visible, variant.show);
        LoadedScene loaded;
        std::string error;
        ASSERT_TRUE(LoadScene(project, root_ / (variant.name + "-cache"), loaded, error)) << error;
        ASSERT_EQ(SelectSceneBackend(*loaded.scene).backend, SceneBackend::NativeMetal);

        @autoreleasepool {
            id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
            CAMetalLayer* layer   = [CAMetalLayer layer];
            layer.device          = device;
            layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
            layer.drawableSize    = CGSizeMake(384, 256);
            layer.framebufferOnly = NO;

            MetalRender         render;
            MetalRenderInitInfo info {
                .metal_layer          = (__bridge void*)layer,
                .width                = 384,
                .height               = 256,
                .render_width         = 384,
                .render_height        = 256,
                .display_scale_factor = 1.0,
            };
            ASSERT_TRUE(render.init(info)) << render.lastError();
            auto graph = sceneToRenderGraph(*loaded.scene);
            ASSERT_NE(graph, nullptr);
            ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
            render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);

            for (int frame = 0; frame < 2; ++frame) AdvanceSceneFrame(render, *loaded.scene);
            const auto counts = render.LastFrameEncodeCountsForTests();
            EXPECT_EQ(counts.render_passes, 1u)
                << "the clear and the cards on one image did not share a render pass";
            EXPECT_EQ(counts.scene_output_passes, 1u);
            pixels[variant.name] = ReadOutput(render, *loaded.scene);
            render.destroy();
        }
    }

    ASSERT_FALSE(pixels["hidden"].empty());
    EXPECT_EQ(pixels["hidden"], pixels["dropped"])
        << "a hidden card changed the picture a scene without it draws";
    EXPECT_NE(pixels["shown"], pixels["hidden"]) << "showing the middle card changed nothing";
}

TEST_F(MetalSceneDraw, ALayerItsPropertiesHideHoldsNoImagesUntilAScriptShowsIt)
{
    // A layer the wallpaper's properties hide cannot appear before the next
    // parse unless a script shows it, so it holds none of the images its
    // effect chain draws through: it costs what a layer that is not there
    // costs. A script that shows it gets a graph that draws it, and the
    // picture is the one the property would have given.
    struct Variant
    {
        std::string name;
        std::string visible;
        bool        show;
    };
    const Variant variants[] = {
        { "hidden", R"({"user":"showmiddle","value":false})", false },
        { "dropped", "false", false },
        { "shown", R"({"user":"showmiddle","value":false})", true },
    };
    std::map<std::string, std::vector<uint8_t>> pixels;
    std::map<std::string, uint64_t>             bytes;
    for (const auto& variant : variants) {
        SCOPED_TRACE(variant.name);
        const auto directory = root_ / ("property-hidden-" + variant.name);
        const auto project   = WriteLayeredFixture(directory, variant.visible, variant.show);
        // The middle card draws through an effect, whose ping-pong images are
        // what a hidden layer would otherwise keep.
        std::filesystem::create_directories(directory / "effects");
        std::ofstream(directory / "effects/identity.json")
            << R"({"name":"identity","passes":[{"material":"materials/identity.json"}]})";
        std::ofstream(directory / "materials/identity.json")
            << R"({"passes":[{"shader":"identity_effect","blending":"translucent","cullmode":"nocull",)"
               R"("depthtest":"disabled","depthwrite":"disabled","textures":[null]}]})";
        std::ofstream(directory / "shaders/identity_effect.vert")
            << "uniform mat4 g_ModelViewProjectionMatrix;\n"
               "attribute vec3 a_Position;\n"
               "attribute vec2 a_TexCoord;\n"
               "varying vec2 v_TexCoord;\n"
               "void main() {\n"
               "  gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);\n"
               "  v_TexCoord = a_TexCoord;\n"
               "}\n";
        std::ofstream(directory / "shaders/identity_effect.frag")
            << "uniform sampler2D g_Texture0;\n"
               "varying vec2 v_TexCoord;\n"
               "void main() { gl_FragColor = texture(g_Texture0, v_TexCoord); }\n";
        auto layout = nlohmann::json::parse(std::ifstream(directory / "layout.json"));
        layout["objects"][1]["effects"] = nlohmann::json::array({
            { { "file", "effects/identity.json" }, { "visible", true } },
        });
        std::ofstream(directory / "layout.json") << layout;

        LoadedScene loaded;
        std::string error;
        ASSERT_TRUE(LoadScene(project, directory / "cache", loaded, error)) << error;
        auto& scene = *loaded.scene;
        ASSERT_EQ(SelectSceneBackend(scene).backend, SceneBackend::NativeMetal);

        @autoreleasepool {
            CAMetalLayer* layer   = [CAMetalLayer layer];
            layer.device          = MTLCreateSystemDefaultDevice();
            layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
            layer.drawableSize    = CGSizeMake(384, 256);
            layer.framebufferOnly = NO;
            MetalRender render;
            ASSERT_TRUE(render.init(MetalRenderInitInfo {
                .metal_layer = (__bridge void*)layer, .width = 384, .height = 256,
                .render_width = 384, .render_height = 256, .display_scale_factor = 1.0,
            })) << render.lastError();
            auto graph = sceneToRenderGraph(scene);
            ASSERT_NE(graph, nullptr);
            ASSERT_TRUE(render.compileRenderGraph(scene, *graph)) << render.lastError();
            render.UpdateCameraFillMode(scene, FillMode::ASPECTFIT);
            for (int frame = 0; frame < 2; ++frame) AdvanceSceneFrame(render, scene);
            ASSERT_FALSE(scene.runtime->ConsumeSceneGraphMutationFlag());
            bytes[variant.name]  = render.RenderTargetBytesForTests();
            pixels[variant.name] = ReadOutput(render, scene);

            if (variant.name == "hidden") {
                // What `thisScene.getLayer('middle').visible = true` reaches.
                ASSERT_TRUE(scene.runtime->SetNodeVisible("middle", true));
                EXPECT_TRUE(scene.runtime->ConsumeSceneGraphMutationFlag())
                    << "a script showed a layer the graph left out and no new graph was asked for";
                ASSERT_TRUE(render.clearLastRenderGraph()) << render.lastError();
                graph = sceneToRenderGraph(scene);
                ASSERT_TRUE(render.compileRenderGraph(scene, *graph)) << render.lastError();
                for (int frame = 0; frame < 2; ++frame) AdvanceSceneFrame(render, scene);
                bytes["revealed"]  = render.RenderTargetBytesForTests();
                pixels["revealed"] = ReadOutput(render, scene);
            }
            render.destroy();
        }
    }

    ASSERT_FALSE(pixels["hidden"].empty());
    EXPECT_EQ(bytes["hidden"], bytes["dropped"])
        << "a layer its properties hide still holds the images its effects draw through";
    EXPECT_GT(bytes["shown"], bytes["hidden"]) << "the shown layer's effect chain holds no images";
    EXPECT_EQ(pixels["hidden"], pixels["dropped"]);
    EXPECT_NE(pixels["shown"], pixels["hidden"]) << "showing the middle card changed nothing";
    EXPECT_EQ(pixels["revealed"], pixels["shown"])
        << "a layer a script showed is not drawn the way its property shows it";
    EXPECT_EQ(bytes["revealed"], bytes["shown"]);
}

namespace
{

/// The layered fixture with a slider driving the left card's alpha, which the
/// cards' shader reads, and an effect chain on the middle card, which is hidden
/// by the `showmiddle` switch unless `show_middle` says otherwise. Written with
/// the values a user would have saved, so a fresh load of it is the picture a
/// property preview has to arrive at.
std::filesystem::path WritePropertyPreviewFixture(const std::filesystem::path& directory,
                                                  bool show_middle, float opacity)
{
    const auto project =
        WriteLayeredFixture(directory, R"({"user":"showmiddle","value":false})", show_middle);
    std::ofstream(project)
        << R"({"title":"Metal preview smoke","type":"scene","file":"layout.json","general":)"
        << R"({"properties":{"showmiddle":{"type":"bool","value":)"
        << (show_middle ? "true" : "false")
        << R"(},"opacity":{"type":"slider","value":)" << opacity << "}}}}";
    std::filesystem::create_directories(directory / "effects");
    std::ofstream(directory / "effects/identity.json")
        << R"({"name":"identity","passes":[{"material":"materials/identity.json"}]})";
    std::ofstream(directory / "materials/identity.json")
        << R"({"passes":[{"shader":"identity_effect","blending":"translucent","cullmode":"nocull",)"
           R"("depthtest":"disabled","depthwrite":"disabled","textures":[null]}]})";
    std::ofstream(directory / "shaders/identity_effect.vert")
        << "uniform mat4 g_ModelViewProjectionMatrix;\n"
           "attribute vec3 a_Position;\n"
           "attribute vec2 a_TexCoord;\n"
           "varying vec2 v_TexCoord;\n"
           "void main() {\n"
           "  gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);\n"
           "  v_TexCoord = a_TexCoord;\n"
           "}\n";
    std::ofstream(directory / "shaders/identity_effect.frag")
        << "uniform sampler2D g_Texture0;\n"
           "varying vec2 v_TexCoord;\n"
           "void main() { gl_FragColor = texture(g_Texture0, v_TexCoord); }\n";
    // Every card carries the alpha the slider writes; a card nothing binds keeps
    // the full alpha the shader declares as its default.
    std::ofstream(directory / "shaders/metal_probe.frag")
        << "uniform float g_UserAlpha; // {\"material\":\"alpha\",\"default\":1.0}\n"
           "varying vec2 v_TexCoord;\n"
           "void main() {\n"
           "  gl_FragColor = vec4(v_TexCoord.x, v_TexCoord.y, 0.25, g_UserAlpha);\n"
           "}\n";
    auto layout = nlohmann::json::parse(std::ifstream(directory / "layout.json"));
    layout["objects"][0]["alpha"] = { { "user", "opacity" }, { "value", 1.0 } };
    layout["objects"][1]["effects"] = nlohmann::json::array({
        { { "file", "effects/identity.json" }, { "visible", true } },
    });
    std::ofstream(directory / "layout.json") << layout;
    return project;
}

/// One frame the way the wallpaper's own draw runs it: the tick applies the
/// bindings, a tick that showed a layer the graph left out asks for a new graph
/// before anything is drawn, and then the frame is. Returns whether it rebuilt.
bool AdvanceLikeTheWallpaper(MetalRender& render, Scene& scene,
                             std::unique_ptr<rg::RenderGraph>& graph)
{
    scene.runtime->Tick(1.0 / 60.0);
    scene.runtime->PumpTextLayerCache();
    bool rebuilt = false;
    if (scene.runtime->ConsumeSceneGraphMutationFlag()) {
        EXPECT_TRUE(render.clearLastRenderGraph()) << render.lastError();
        graph = sceneToRenderGraph(scene);
        EXPECT_NE(graph, nullptr);
        EXPECT_TRUE(render.compileRenderGraph(scene, *graph)) << render.lastError();
        rebuilt = true;
    }
    EXPECT_TRUE(render.drawFrame(scene)) << render.lastError();
    scene.PassFrameTime(1.0 / 60.0);
    return rebuilt;
}

} // namespace

TEST_F(MetalSceneDraw, APropertyPreviewChangesThePixelsAndAnEmptyDocumentRestoresThemByteForByte)
{
    // A property edit shown on the running scene, without loading it again: a
    // slider moves what is drawn, a switch shows a layer the graph left out (one
    // new graph, then it draws like any other), and the picture is the one a
    // fresh load with the same values gives. The empty document is the project's
    // own values again, and the first frame comes back exactly.
    const ProjectProperties preview_document {
        { "showmiddle", RuntimeScalarValue::Bool(true) },
        { "opacity", RuntimeScalarValue::Float(0.5f) },
    };

    std::vector<uint8_t> reference;
    {
        SCOPED_TRACE("a fresh load with the previewed values");
        const auto  project = WritePropertyPreviewFixture(root_ / "reference", true, 0.5f);
        LoadedScene loaded;
        std::string error;
        ASSERT_TRUE(LoadScene(project, root_ / "reference-cache", loaded, error)) << error;
        auto& scene = *loaded.scene;
        ASSERT_EQ(SelectSceneBackend(scene).backend, SceneBackend::NativeMetal);
        @autoreleasepool {
            CAMetalLayer* layer   = [CAMetalLayer layer];
            layer.device          = MTLCreateSystemDefaultDevice();
            layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
            layer.drawableSize    = CGSizeMake(384, 256);
            layer.framebufferOnly = NO;
            MetalRender render;
            ASSERT_TRUE(render.init(MetalRenderInitInfo {
                .metal_layer = (__bridge void*)layer, .width = 384, .height = 256,
                .render_width = 384, .render_height = 256, .display_scale_factor = 1.0,
            })) << render.lastError();
            auto graph = sceneToRenderGraph(scene);
            ASSERT_NE(graph, nullptr);
            ASSERT_TRUE(render.compileRenderGraph(scene, *graph)) << render.lastError();
            render.UpdateCameraFillMode(scene, FillMode::ASPECTFIT);
            for (int frame = 0; frame < 2; ++frame) AdvanceSceneFrame(render, scene);
            reference = ReadOutput(render, scene);
            render.destroy();
        }
    }
    ASSERT_FALSE(reference.empty());

    const auto  project = WritePropertyPreviewFixture(root_ / "preview", false, 1.0f);
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "preview-cache", loaded, error)) << error;
    auto& scene = *loaded.scene;
    ASSERT_NE(scene.runtime, nullptr);
    ASSERT_EQ(SelectSceneBackend(scene).backend, SceneBackend::NativeMetal);

    @autoreleasepool {
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = MTLCreateSystemDefaultDevice();
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(384, 256);
        layer.framebufferOnly = NO;
        MetalRender render;
        ASSERT_TRUE(render.init(MetalRenderInitInfo {
            .metal_layer = (__bridge void*)layer, .width = 384, .height = 256,
            .render_width = 384, .render_height = 256, .display_scale_factor = 1.0,
        })) << render.lastError();
        auto graph = sceneToRenderGraph(scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(scene, *graph)) << render.lastError();
        render.UpdateCameraFillMode(scene, FillMode::ASPECTFIT);
        const auto frames = [&](int count) {
            int rebuilds = 0;
            for (int frame = 0; frame < count; ++frame) {
                rebuilds += AdvanceLikeTheWallpaper(render, scene, graph) ? 1 : 0;
            }
            return rebuilds;
        };

        EXPECT_EQ(frames(2), 0);
        const auto first = ReadOutput(render, scene);
        ASSERT_FALSE(first.empty());
        EXPECT_NE(first, reference) << "the previewed values draw the same picture as the saved ones";

        // The slider alone moves what is drawn, in place.
        scene.runtime->PreviewProjectPropertyOverride({ { "opacity", RuntimeScalarValue::Float(0.5f) } });
        EXPECT_EQ(frames(2), 0) << "a slider asked for a new graph";
        const auto faded = ReadOutput(render, scene);
        EXPECT_NE(faded, first) << "the slider changed nothing that is drawn";
        EXPECT_NE(faded, reference);

        // The switch shows a layer the graph left out: one new graph, however many
        // frames follow, and then the picture a fresh load of those values draws.
        scene.runtime->PreviewProjectPropertyOverride(preview_document);
        EXPECT_EQ(frames(1), 1) << "showing a layer the graph left out did not rebuild the graph";
        EXPECT_EQ(frames(2), 0);
        const auto previewed = ReadOutput(render, scene);
        EXPECT_EQ(previewed, reference)
            << "a previewed property draws something a fresh load with it does not";

        // The empty document is the project's own values: the layer is hidden by
        // its property again and the first frame is back, bit for bit, without
        // another graph.
        scene.runtime->PreviewProjectPropertyOverride({});
        EXPECT_EQ(frames(3), 0);
        const auto restored = ReadOutput(render, scene);
        EXPECT_EQ(restored, first) << "the empty document did not restore the first frame";

        // And a second round trip lands on the same pictures: nothing drifts.
        scene.runtime->PreviewProjectPropertyOverride(preview_document);
        EXPECT_EQ(frames(3), 0) << "the graph already draws the layer";
        EXPECT_EQ(ReadOutput(render, scene), reference);
        scene.runtime->PreviewProjectPropertyOverride({});
        EXPECT_EQ(frames(2), 0);
        EXPECT_EQ(ReadOutput(render, scene), first);
        render.destroy();
    }
}

TEST_F(MetalSceneDraw, AFeedbackCopyTradesTexturesAndDrawsTheSamePicture)
{
    // Each lens reads the scene's own image, so the graph copies that image
    // before each one. With scene optimisation off every copy is made; with it
    // on the image and its copy trade textures instead. The two must draw the
    // same bytes on every frame -- including after the trades have carried
    // over from one frame to the next, when the image lives in a different
    // texture each frame.
    struct RestoreOptimization
    {
        bool was { wallpaper::vulkan::SceneOptimizationEnabled() };
        ~RestoreOptimization() { wallpaper::vulkan::SetSceneOptimizationEnabled(was); }
    } restore;

    std::map<bool, std::vector<std::vector<uint8_t>>>         frames;
    std::map<bool, MetalRender::FrameEncodeCountsForTests> counts;
    for (const bool optimise : { false, true }) {
        SCOPED_TRACE(optimise ? "optimisation on" : "optimisation off");
        wallpaper::vulkan::SetSceneOptimizationEnabled(optimise);
        const std::string name    = optimise ? "feedback-on" : "feedback-off";
        const auto        project = WriteFeedbackFixture(root_ / name);
        LoadedScene       loaded;
        std::string       error;
        ASSERT_TRUE(LoadScene(project, root_ / (name + "-cache"), loaded, error)) << error;
        ASSERT_EQ(SelectSceneBackend(*loaded.scene).backend, SceneBackend::NativeMetal);

        @autoreleasepool {
            id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
            CAMetalLayer* layer   = [CAMetalLayer layer];
            layer.device          = device;
            layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
            layer.drawableSize    = CGSizeMake(384, 256);
            layer.framebufferOnly = NO;

            MetalRender         render;
            MetalRenderInitInfo info {
                .metal_layer          = (__bridge void*)layer,
                .width                = 384,
                .height               = 256,
                .render_width         = 384,
                .render_height        = 256,
                .display_scale_factor = 1.0,
            };
            ASSERT_TRUE(render.init(info)) << render.lastError();
            auto graph = sceneToRenderGraph(*loaded.scene);
            ASSERT_NE(graph, nullptr);
            ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
            render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);

            for (int frame = 0; frame < 3; ++frame) {
                AdvanceSceneFrame(render, *loaded.scene);
                frames[optimise].push_back(ReadOutput(render, *loaded.scene));
            }
            counts[optimise] = render.LastFrameEncodeCountsForTests();
            render.destroy();
        }
    }

    EXPECT_EQ(counts[false].blit_passes, 2u) << "the fixture no longer copies the scene per lens";
    EXPECT_EQ(counts[true].blit_passes, 0u) << "the scene was still copied before a lens read it";
    EXPECT_EQ(counts[true].render_passes, counts[false].render_passes);
    ASSERT_EQ(frames[true].size(), frames[false].size());
    for (std::size_t frame = 0; frame < frames[true].size(); ++frame) {
        EXPECT_EQ(frames[true][frame], frames[false][frame]) << "frame " << frame;
    }

    // And a lens really read the card beneath it: its inverted blue is
    // 0.75, which neither the card nor a lens over the black background draws.
    std::size_t lensed = 0;
    const auto& drawn  = frames[true].back();
    for (std::size_t i = 0; i + 3 < drawn.size(); i += 4) {
        if (drawn[i + 2] >= 185 && drawn[i + 2] <= 197) ++lensed;
    }
    EXPECT_GT(lensed, 500u) << "no lens shows the card it was drawn over";
}

TEST_F(MetalSceneDraw, ASceneLightReachesTheAuthorsLightingUniforms)
{
    // Lighting in a scene is its author's shader reading the light arrays. The
    // card writes the first light's premultiplied colour (colour x intensity x
    // radius squared) and its x position, so the drawn pixel is those values.
    const auto project = WriteFixture(root_ / "lit");
    std::ofstream(root_ / "lit/shaders/metal_probe.frag")
        << "uniform vec4 g_LightsColorPremultiplied[3];\n"
           "uniform vec4 g_LightsPosition[4];\n"
           "varying vec2 v_TexCoord;\n"
           "void main() {\n"
           "  gl_FragColor = vec4(g_LightsColorPremultiplied[0].rg, g_LightsPosition[0].x / 400.0, 1.0);\n"
           "}\n";
    std::ofstream(root_ / "lit/layout.json")
        << R"({"camera":{"center":[0,0,0],"eye":[0,0,1],"up":[0,1,0]},)"
           R"("general":{"ambientcolor":[0,0,0],"skylightcolor":[0,0,0],"clearcolor":[0.0,0.0,0.0],)"
           R"("cameraparallax":false,"orthogonalprojection":{"width":384,"height":256}},)"
           R"("objects":[{"id":1,"name":"tile","image":"models/tile.json","origin":[192,128,0],)"
           R"("scale":[1,1,1],"angles":[0,0,0],"visible":true},)"
           R"({"id":2,"name":"lamp","light":"point","color":"1 0.5 0","intensity":0.5,"radius":1,)"
           R"("origin":"100 64 300","angles":"0 0 0","scale":"1 1 1","visible":true}]})";
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "lit-cache", loaded, error)) << error;
    ASSERT_EQ(loaded.scene->lights.size(), 1u);
    const auto selection = SelectSceneBackend(*loaded.scene);
    ASSERT_EQ(selection.backend, SceneBackend::NativeMetal) << selection.fallback_reason;

    @autoreleasepool {
        id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(384, 256);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 384,
            .height               = 256,
            .render_width         = 384,
            .render_height        = 256,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();
        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
        render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);
        AdvanceSceneFrame(render, *loaded.scene);
        const auto rgba = ReadOutput(render, *loaded.scene);
        render.destroy();

        // The canvas centre is inside the card.
        ASSERT_EQ(rgba.size(), 384u * 256u * 4u);
        const std::size_t centre = (128u * 384u + 192u) * 4u;
        EXPECT_NEAR(rgba[centre + 0], 128, 2) << "the light's red did not reach the shader";
        EXPECT_NEAR(rgba[centre + 1], 64, 2) << "the light's green did not reach the shader";
        EXPECT_NEAR(rgba[centre + 2], 64, 2) << "the light's position did not reach the shader";
    }
}

TEST_F(MetalSceneDraw, AStepSamplingAnImageNothingProducesIsSkippedLikeOnCompatibility)
{
    // The overlay samples the composite of an object that is a layer by id
    // but never draws one -- a light here, a hidden text layer in the wild.
    // The graph finds no producer and leaves the slot without a name. The
    // compatibility backend then neither draws nor clears that step, every
    // frame; refusing the whole scene for it would send a wallpaper to a
    // renderer that draws exactly the same picture.
    const auto project = WriteFixture(root_ / "unproduced");
    std::ofstream(root_ / "unproduced/models/overlay.json")
        << R"({"width":128,"height":96,"material":"materials/overlay.json"})";
    std::ofstream(root_ / "unproduced/materials/overlay.json")
        << R"({"passes":[{"shader":"overlay_sample","blending":"translucent","cullmode":"nocull",)"
           R"("depthtest":"disabled","depthwrite":"disabled","textures":["_rt_imageLayerComposite_3_a"]}]})";
    std::ofstream(root_ / "unproduced/shaders/overlay_sample.vert")
        << "uniform mat4 g_ModelViewProjectionMatrix;\n"
           "attribute vec3 a_Position;\n"
           "attribute vec2 a_TexCoord;\n"
           "varying vec2 v_TexCoord;\n"
           "void main() {\n"
           "  gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);\n"
           "  v_TexCoord = a_TexCoord;\n"
           "}\n";
    std::ofstream(root_ / "unproduced/shaders/overlay_sample.frag")
        << "uniform sampler2D g_Texture0;\n"
           "varying vec2 v_TexCoord;\n"
           "void main() {\n"
           "  gl_FragColor = vec4(1.0, 1.0, 1.0, 1.0) - texture(g_Texture0, v_TexCoord) * 0.0;\n"
           "}\n";
    std::ofstream(root_ / "unproduced/layout.json")
        << R"({"camera":{"center":[0,0,0],"eye":[0,0,1],"up":[0,1,0]},)"
           R"("general":{"ambientcolor":[0,0,0],"skylightcolor":[0,0,0],"clearcolor":[0.0,0.0,0.0],)"
           R"("cameraparallax":false,"orthogonalprojection":{"width":384,"height":256}},)"
           R"("objects":[{"id":1,"name":"tile","image":"models/tile.json","origin":[192,128,0],)"
           R"("scale":[1,1,1],"angles":[0,0,0],"visible":true},)"
           R"({"id":2,"name":"overlay","image":"models/overlay.json","origin":[192,128,0],)"
           R"("scale":[1,1,1],"angles":[0,0,0],"visible":true},)"
           R"({"id":3,"name":"lamp","light":"point","color":"1 1 1","intensity":1,"radius":1,)"
           R"("origin":"0 0 300","angles":"0 0 0","scale":"1 1 1","visible":true}]})";
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "unproduced-cache", loaded, error)) << error;
    const auto selection = SelectSceneBackend(*loaded.scene);
    ASSERT_EQ(selection.backend, SceneBackend::NativeMetal) << selection.fallback_reason;

    @autoreleasepool {
        id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(384, 256);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 384,
            .height               = 256,
            .render_width         = 384,
            .render_height        = 256,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();
        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
        render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);
        for (int frame = 0; frame < 2; ++frame) AdvanceSceneFrame(render, *loaded.scene);
        const auto rgba = ReadOutput(render, *loaded.scene);
        render.destroy();

        // The overlay covers the canvas centre; the tile beneath it shows,
        // with its constant 0.25 blue, and no overlay white anywhere.
        ASSERT_EQ(rgba.size(), 384u * 256u * 4u);
        const std::size_t centre = (128u * 384u + 192u) * 4u;
        EXPECT_NEAR(rgba[centre + 2], 64, 2) << "the tile under the skipped step is missing";
        std::size_t white = 0;
        for (std::size_t i = 0; i + 3 < rgba.size(); i += 4) {
            if (rgba[i] == 255 && rgba[i + 1] == 255 && rgba[i + 2] == 255) ++white;
        }
        EXPECT_EQ(white, 0u) << "the step with no input was drawn";
    }
}

TEST_F(MetalSceneDraw, ThePointerSmoothingStepsOnceForEachFrameTheHostDraws)
{
    // `FrameBegin` steps the parallax cursor's smoothing by one frame time; the
    // host calls it once per frame before drawing, on either backend. The card
    // shows the smoothed pointer's x as red. With a 1 s delay the first 1/60 s
    // frame moves it a sixtieth of the way from the centre to the cursor at
    // the right edge; a backend that stepped it again inside its own frame
    // would draw it nearer the cursor than the compatibility backend does.
    const auto project = WriteFixture(root_ / "pointer");
    std::ofstream(root_ / "pointer/shaders/metal_probe.frag")
        << "uniform vec2 g_PointerPosition;\n"
           "varying vec2 v_TexCoord;\n"
           "void main() {\n"
           "  gl_FragColor = vec4(g_PointerPosition.x, 0.0, 0.25, 1.0);\n"
           "}\n";
    std::ofstream(root_ / "pointer/layout.json")
        << R"({"camera":{"center":[0,0,0],"eye":[0,0,1],"up":[0,1,0]},)"
           R"("general":{"ambientcolor":[0,0,0],"skylightcolor":[0,0,0],"clearcolor":[0.0,0.0,0.0],)"
           R"("cameraparallax":true,"cameraparallaxdelay":1.0,"cameraparallaxamount":0.0,)"
           R"("cameraparallaxmouseinfluence":0.0,"orthogonalprojection":{"width":384,"height":256}},)"
           R"("objects":[{"id":1,"name":"tile","image":"models/tile.json","origin":[192,128,0],)"
           R"("scale":[1,1,1],"angles":[0,0,0],"visible":true}]})";
    LoadedScene loaded;
    std::string error;
    ASSERT_TRUE(LoadScene(project, root_ / "pointer-cache", loaded, error)) << error;
    ASSERT_EQ(SelectSceneBackend(*loaded.scene).backend, SceneBackend::NativeMetal);

    @autoreleasepool {
        id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
        CAMetalLayer* layer   = [CAMetalLayer layer];
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize    = CGSizeMake(384, 256);
        layer.framebufferOnly = NO;

        MetalRender         render;
        MetalRenderInitInfo info {
            .metal_layer          = (__bridge void*)layer,
            .width                = 384,
            .height               = 256,
            .render_width         = 384,
            .render_height        = 256,
            .display_scale_factor = 1.0,
        };
        ASSERT_TRUE(render.init(info)) << render.lastError();
        auto graph = sceneToRenderGraph(*loaded.scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
        render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);

        // One host frame of 1/60 s with the cursor at the right edge.
        loaded.scene->PassFrameTime(1.0 / 60.0);
        loaded.scene->shaderValueUpdater->MouseInput(1.0, 0.5);
        loaded.scene->shaderValueUpdater->FrameBegin();
        ASSERT_TRUE(render.drawFrame(*loaded.scene)) << render.lastError();
        const auto rgba = ReadOutput(render, *loaded.scene);
        render.destroy();

        ASSERT_EQ(rgba.size(), 384u * 256u * 4u);
        const std::size_t centre = (128u * 384u + 192u) * 4u;
        // 0.5 + 0.5 / 60 = 0.5083, 129.6 of 255; stepped twice it is 0.5247.
        EXPECT_NEAR(rgba[centre + 0], 130, 1)
            << "the pointer smoothing did not step exactly once for the frame";
    }
}

TEST_F(MetalSceneDraw, ALayerReadingThePreviousFrameSeesExactlyThePreviousFrame)
{
    // History: the echo samples a buffer the graph fills only after the echo
    // has drawn, so frame N shows frame N-1. That buffer is the target's own
    // image for as long as the graph lives. The first frame must see the
    // cleared buffer, not this frame's tile, and every later frame must see
    // the frame before -- with scene optimisation off and on, which plans the
    // copies and the reuse table differently around the same loop.
    struct RestoreOptimization
    {
        bool was { wallpaper::vulkan::SceneOptimizationEnabled() };
        ~RestoreOptimization() { wallpaper::vulkan::SetSceneOptimizationEnabled(was); }
    } restore;

    // The tile's constant blue, 0.25, which nothing else in the fixture draws.
    const auto tile_pixels = [](const std::vector<uint8_t>& rgba) {
        std::size_t count = 0;
        for (std::size_t i = 0; i + 3 < rgba.size(); i += 4) {
            if (rgba[i + 2] >= 56 && rgba[i + 2] <= 72) ++count;
        }
        return count;
    };

    std::map<bool, std::vector<std::vector<uint8_t>>> frames;
    for (const bool optimise : { false, true }) {
        SCOPED_TRACE(optimise ? "optimisation on" : "optimisation off");
        wallpaper::vulkan::SetSceneOptimizationEnabled(optimise);
        const std::string name    = optimise ? "history-on" : "history-off";
        const auto        project = WriteHistoryFixture(root_ / name);
        LoadedScene       loaded;
        std::string       error;
        ASSERT_TRUE(LoadScene(project, root_ / (name + "-cache"), loaded, error)) << error;
        const auto selection = SelectSceneBackend(*loaded.scene);
        ASSERT_EQ(selection.backend, SceneBackend::NativeMetal) << selection.fallback_reason;

        @autoreleasepool {
            id<MTLDevice> device  = MTLCreateSystemDefaultDevice();
            CAMetalLayer* layer   = [CAMetalLayer layer];
            layer.device          = device;
            layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
            layer.drawableSize    = CGSizeMake(384, 256);
            layer.framebufferOnly = NO;

            MetalRender         render;
            MetalRenderInitInfo info {
                .metal_layer          = (__bridge void*)layer,
                .width                = 384,
                .height               = 256,
                .render_width         = 384,
                .render_height        = 256,
                .display_scale_factor = 1.0,
            };
            ASSERT_TRUE(render.init(info)) << render.lastError();
            auto graph = sceneToRenderGraph(*loaded.scene);
            ASSERT_NE(graph, nullptr);
            ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
            render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);

            // Nothing in the fixture moves, so only the loop can keep it
            // changing; the clock must not be allowed to stop on it.
            EXPECT_TRUE(render.ShaderUpdateDemandReasons() &
                        wallpaper::vulkan::DynamicReason::Feedback);

            for (int frame = 0; frame < 4; ++frame) {
                AdvanceSceneFrame(render, *loaded.scene);
                frames[optimise].push_back(ReadOutput(render, *loaded.scene));
            }
            render.destroy();
        }

        const auto& drawn = frames[optimise];
        ASSERT_EQ(drawn.size(), 4u);
        // Frame 0 reads the cleared buffer. Had the echo read this frame's
        // own picture it would already hold the tile, and frame 1 would add
        // nothing to it.
        const auto alone = tile_pixels(drawn[0]);
        EXPECT_GT(alone, 3000u) << "the tile itself was not drawn";
        // Frame 1 shows frame 0 at half size: the tile once more, a quarter of
        // its area.
        EXPECT_GT(tile_pixels(drawn[1]), alone + alone / 8)
            << "the echo did not show the previous frame's tile";
        // Frame 2 shows frame 1, which already held an echo of its own; once
        // the echo's echo is below a pixel the picture stops changing.
        EXPECT_GE(tile_pixels(drawn[2]), tile_pixels(drawn[1]));
        EXPECT_NE(drawn[1], drawn[2]) << "frame 2 did not read frame 1";
    }

    for (std::size_t frame = 0; frame < frames[true].size(); ++frame) {
        EXPECT_EQ(frames[true][frame], frames[false][frame]) << "frame " << frame;
    }
}

TEST_F(MetalSceneDraw, TargetsThatAreNeverAliveTogetherShareImagesAndDrawTheSamePicture)
{
    // Two cases share images: traded copies of the scene (each lens reads a
    // copy of the picture so far, alive only until the lens has drawn) and
    // effect buffers of layers drawn one after the other. With sharing on,
    // fewer bytes of targets must hold exactly the same frames as with every
    // target in an image of its own, and the copies must still be traded
    // rather than blitted. Scene optimisation is on for the lenses and off for
    // the effects, whose static results it would otherwise pin.
    struct RestoreSwitches
    {
        bool optimise { wallpaper::vulkan::SceneOptimizationEnabled() };
        ~RestoreSwitches()
        {
            wallpaper::vulkan::SetSceneOptimizationEnabled(optimise);
            MetalRender::SetTargetSharingForTests(true);
        }
    } restore;

    const auto effect_fixture = [this](const std::filesystem::path& root) {
        const auto project = WriteFixture(root);
        std::filesystem::create_directories(root / "effects");
        std::ofstream(root / "effects/halve.json")
            << R"({"name":"halve green","passes":[{"material":"materials/halve.json"}]})";
        std::ofstream(root / "materials/halve.json")
            << R"({"passes":[{"shader":"halve_green","blending":"translucent","cullmode":"nocull",)"
               R"("depthtest":"disabled","depthwrite":"disabled","textures":[null]}]})";
        std::ofstream(root / "shaders/halve_green.vert")
            << "uniform mat4 g_ModelViewProjectionMatrix;\n"
               "attribute vec3 a_Position;\n"
               "attribute vec2 a_TexCoord;\n"
               "varying vec2 v_TexCoord;\n"
               "void main() {\n"
               "  gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);\n"
               "  v_TexCoord = a_TexCoord;\n"
               "}\n";
        std::ofstream(root / "shaders/halve_green.frag")
            << "uniform sampler2D g_Texture0;\n"
               "varying vec2 v_TexCoord;\n"
               "void main() {\n"
               "  gl_FragColor = texture(g_Texture0, v_TexCoord) * vec4(1.0, 0.5, 1.0, 1.0);\n"
               "}\n";
        const std::string effects =
            R"("effects":[{"file":"effects/halve.json","visible":true},{"file":"effects/halve.json","visible":true}])";
        std::ofstream(root / "layout.json")
            << R"({"camera":{"center":[0,0,0],"eye":[0,0,1],"up":[0,1,0]},)"
               R"("general":{"ambientcolor":[0,0,0],"skylightcolor":[0,0,0],"clearcolor":[0.0,0.0,0.0],)"
               R"("cameraparallax":false,"orthogonalprojection":{"width":384,"height":256}},)"
               R"("objects":[{"id":1,"name":"left","image":"models/tile.json","origin":[120,128,0],)"
               R"("scale":[0.5,0.5,1],"angles":[0,0,0],"visible":true,)" + effects + "},"
               R"({"id":2,"name":"right","image":"models/tile.json","origin":[264,128,0],)"
               R"("scale":[0.5,0.5,1],"angles":[0,0,0],"visible":true,)" + effects + "}]}";
        return project;
    };

    for (const bool lenses : { true, false }) {
        SCOPED_TRACE(lenses ? "traded copies" : "effect buffers");
        wallpaper::vulkan::SetSceneOptimizationEnabled(lenses);
        std::map<bool, std::vector<std::vector<uint8_t>>>    frames;
        std::map<bool, uint64_t>                              bytes;
        std::map<bool, MetalRender::FrameEncodeCountsForTests> counts;
        for (const bool share : { false, true }) {
            MetalRender::SetTargetSharingForTests(share);
            const std::string name =
                std::string(lenses ? "share-lens-" : "share-effect-") + (share ? "on" : "off");
            const auto  project = lenses ? WriteFeedbackFixture(root_ / name)
                                         : effect_fixture(root_ / name);
            LoadedScene loaded;
            std::string error;
            ASSERT_TRUE(LoadScene(project, root_ / (name + "-cache"), loaded, error)) << error;
            ASSERT_EQ(SelectSceneBackend(*loaded.scene).backend, SceneBackend::NativeMetal);
            @autoreleasepool {
                CAMetalLayer* layer   = [CAMetalLayer layer];
                layer.device          = MTLCreateSystemDefaultDevice();
                layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
                layer.drawableSize    = CGSizeMake(384, 256);
                layer.framebufferOnly = NO;
                MetalRender         render;
                MetalRenderInitInfo info {
                    .metal_layer          = (__bridge void*)layer,
                    .width                = 384,
                    .height               = 256,
                    .render_width         = 384,
                    .render_height        = 256,
                    .display_scale_factor = 1.0,
                };
                ASSERT_TRUE(render.init(info)) << render.lastError();
                auto graph = sceneToRenderGraph(*loaded.scene);
                ASSERT_NE(graph, nullptr);
                ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, *graph)) << render.lastError();
                render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);
                for (int frame = 0; frame < 3; ++frame) {
                    AdvanceSceneFrame(render, *loaded.scene);
                    frames[share].push_back(ReadOutput(render, *loaded.scene));
                }
                bytes[share]  = render.RenderTargetBytesForTests();
                counts[share] = render.LastFrameEncodeCountsForTests();
                render.destroy();
            }
        }
        EXPECT_LT(bytes[true], bytes[false]) << "no target gave its image up";
        EXPECT_EQ(counts[true].blit_passes, counts[false].blit_passes)
            << "sharing turned a traded copy into a blit";
        ASSERT_EQ(frames[true].size(), frames[false].size());
        for (std::size_t frame = 0; frame < frames[true].size(); ++frame) {
            EXPECT_EQ(frames[true][frame], frames[false][frame]) << "frame " << frame;
        }
    }
}

TEST_F(MetalSceneDraw, InterleavedFeedbackCopiesPreserveEachReadersImage)
{
    struct RestoreOptimization
    {
        bool was { wallpaper::vulkan::SceneOptimizationEnabled() };
        ~RestoreOptimization() { wallpaper::vulkan::SetSceneOptimizationEnabled(was); }
    } restore;

    const std::string a = std::string(SpecTex_Default);
    const std::string ac = "_rt_interleaved_a_copy";
    const std::string b = "_rt_effect_pingpong_interleaved_b";
    const std::string bc = "_rt_interleaved_b_copy";
    std::array<std::vector<std::vector<uint8_t>>, 2> reference;
    for (const bool optimise : { false, true }) {
        SCOPED_TRACE(optimise ? "texture trades" : "copy blits");
        wallpaper::vulkan::SetSceneOptimizationEnabled(optimise);
        const std::string name = optimise ? "interleaved-on" : "interleaved-off";
        const auto project = WriteFeedbackFixture(root_ / name);
        LoadedScene loaded;
        std::string error;
        ASSERT_TRUE(LoadScene(project, root_ / (name + "-cache"), loaded, error)) << error;

        SceneNode* tile = nullptr;
        SceneNode* lens = nullptr;
        SceneNode* broad_lens = nullptr;
        for (const auto& child : loaded.scene->sceneGraph->GetChildren()) {
            if (child->Name() == "tile") tile = FirstDrawableNode(child.get());
            if (child->Name() == "lens") lens = FirstDrawableNode(child.get());
            if (child->Name() == "second lens") broad_lens = FirstDrawableNode(child.get());
        }
        ASSERT_NE(tile, nullptr);
        ASSERT_NE(lens, nullptr);
        ASSERT_NE(broad_lens, nullptr);
        broad_lens->SetScale(Eigen::Vector3f { 2.0f, 2.0f, 1.0f });
        loaded.scene->renderTargets[b] = SceneRenderTarget { .width = 384, .height = 256 };

        @autoreleasepool {
            CAMetalLayer* layer   = [CAMetalLayer layer];
            layer.device          = MTLCreateSystemDefaultDevice();
            layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
            layer.drawableSize    = CGSizeMake(384, 256);
            layer.framebufferOnly = NO;
            MetalRender render;
            MetalRenderInitInfo info {
                .metal_layer          = (__bridge void*)layer,
                .width                = 384,
                .height               = 256,
                .render_width         = 384,
                .render_height        = 256,
                .display_scale_factor = 1.0,
            };
            ASSERT_TRUE(render.init(info)) << render.lastError();

            // Ac feeds B's first draw; B feeds A's last draw through a spare
            // dependency slot. This forces the interleaving independent of the
            // graph's ordering of unrelated nodes:
            // A -> copy A/Ac -> B -> copy B/Bc -> draw B -> draw A.
            // Both final draws leave coloured pixels outside their small quad
            // untouched, so losing either opening copy changes the image.
            rg::RenderGraph graph;
            AddDraw(graph, tile, a, {});
            AddCopy(graph, a, ac);
            AddDraw(graph, broad_lens, b, { ac });
            AddCopy(graph, b, bc);
            AddDraw(graph, lens, b, { bc }, false);
            AddDraw(graph, lens, a, { ac, b }, false);
            ASSERT_TRUE(render.compileRenderGraph(*loaded.scene, graph)) << render.lastError();
            render.UpdateCameraFillMode(*loaded.scene, FillMode::ASPECTFIT);

            // More than the in-flight slot count: texture trades must remain
            // correct when their allocations rotate through subsequent frames.
            for (int frame = 0; frame < 4; ++frame) {
                AdvanceSceneFrame(render, *loaded.scene);
                const auto counts = render.LastFrameEncodeCountsForTests();
                EXPECT_EQ(counts.blit_passes, optimise ? 0u : 2u);
                std::size_t target_index = 0;
                for (const auto& key : { a, b }) {
                    SCOPED_TRACE(key + " frame " + std::to_string(frame));
                    uint32_t width = 0, height = 0;
                    std::vector<uint8_t> pixels;
                    ASSERT_TRUE(render.ReadRenderTargetForTests(key, pixels, width, height));
                    ASSERT_EQ(width, 384u);
                    ASSERT_EQ(height, 256u);
                    if (optimise) {
                        EXPECT_EQ(pixels, reference[target_index][frame]);
                    } else {
                        reference[target_index].push_back(std::move(pixels));
                    }
                    ++target_index;
                }
            }
            render.destroy();
        }
    }
}
