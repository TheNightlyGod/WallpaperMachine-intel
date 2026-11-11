#include "support/gpu_scene.hpp"
#include <atomic>

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include "Audio/SoundManager.h"
#include "Fs/PhysicalFs.h"
#include "Fs/VFS.h"
#include "Interface/IShaderValueUpdater.h"
#include "MetalRender/MetalBackendRouter.hpp"
#include "MetalRender/MetalRender.hpp"
#include "Particle/ParticleSystem.h"
#include "Project/ProjectProperties.hpp"
#include "RenderCommon/SceneToRenderGraph.hpp"
#include "RenderCommon/StaticSubgraphCache.hpp"
#include "RenderGraph/RenderGraph.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/VirtualAssetRegistry.hpp"
#include "Scene/Scene.h"
#include "SceneSourceResolver.hpp"
#include "Utils/Random.hpp"
#include "WPSceneParser.hpp"

#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <filesystem>
#include <map>
#include <mutex>
#include <optional>

#include <unistd.h>

namespace we_test
{

using namespace wallpaper;
namespace disk = std::filesystem;

bool MetalAvailable()
{
    const char* simulate = std::getenv("WE_TEST_SIMULATE_NO_METAL");
    if (simulate != nullptr && *simulate != '\0' && std::string(simulate) != "0") return false;
    return metal::MetalDeviceAvailable();
}

namespace
{

// The poster texture the renderer composes is delivered from a Metal-owned thread; this is
// the hand-over to the test thread.
struct PosterBox {
    std::mutex              mutex;
    std::condition_variable condition;
    bool                    wanted { false };
    bool                    delivered { false };
    Image                   image;
};

} // namespace

struct GpuScene::Impl {
    GpuSceneOptions options;
    std::string     project_file;
    std::string     error;

    disk::path scratch;
    disk::path cache_directory;
    disk::path shared_directory;
    bool       previous_optimization { true };
    bool       broken { false };

    std::unique_ptr<audio::SoundManager> sound;
    std::shared_ptr<Scene>               scene;
    std::unique_ptr<rg::RenderGraph>     graph;
    std::unique_ptr<metal::MetalRender>  render;
    CAMetalLayer*                        layer { nil };
    std::shared_ptr<PosterBox>           poster { std::make_shared<PosterBox>() };

    ProjectProperties            properties_in_effect;
    std::map<std::string, Json>  preview_values;

    float    pointer_x { 0.5f };
    float    pointer_y { 0.5f };
    bool     cursor_was_in_window { false };
    std::shared_ptr<std::atomic<bool>> display_changed {std::make_shared<std::atomic<bool>>(false)};
    uint64_t frames { 0 };
    int      compiles { 0 };
    bool     released { false };

    PassCounts              last_passes;
    std::vector<PassCounts> frame_passes;

    /// Records why the scene cannot run any more.
    bool Fail(std::string message)
    {
        error  = std::move(message);
        broken = true;
        return false;
    }

    bool Load();
    bool OpenRenderer();
    bool CompileGraph();
    bool StepOne();
    void ReleaseAll();
};

// Reads the project the way the host's control thread does and hands back a parsed scene.
bool GpuScene::Impl::Load()
{
    SceneSourceResolution resolved;
    std::string           problem;
    if (!ResolveSceneSourcePaths(project_file, &resolved, &problem)) {
        return Fail("the scene source cannot be resolved: " + problem);
    }
    if (resolved.kind != SceneSourceResolutionKind::Scene) return Fail("the project is not a scene");

    auto vfs = std::make_unique<fs::VFS>();
    {
        // The shared assets of the real host are not needed: a synthetic project carries
        // everything it draws with, so an empty folder stands in for them.
        auto shared = fs::CreatePhysicalFs(shared_directory.string());
        if (shared == nullptr || !vfs->Mount("/assets", std::move(shared))) {
            return Fail("the shared assets cannot be mounted");
        }
    }
    if (!MountSceneSource(*vfs, resolved.scene_source, &problem)) {
        return Fail("the project's files cannot be mounted: " + problem);
    }
    {
        auto cache = fs::CreatePhysicalFs(cache_directory.string(), true);
        if (cache == nullptr || !vfs->Mount("/cache", std::move(cache), "cache")) {
            return Fail("the scratch shader cache cannot be mounted");
        }
    }
    if (!InstallVirtualAssets(*vfs)) return Fail("the built-in assets cannot be installed");

    const std::string scene_text = fs::GetFileContent(*vfs, "/assets/" + resolved.scene_source.pkg_entry);
    if (scene_text.empty()) return Fail("the scene file is missing or empty");

    ProjectProperties authored;
    if (!ParseProjectProperties(project_file, &authored, &problem)) {
        return Fail("the project's properties cannot be read: " + problem);
    }
    ProjectProperties merged = authored;
    if (options.saved_properties.is_object() && !options.saved_properties.empty()) {
        ProjectProperties saved;
        if (!ParseFlatProjectPropertyOverrideJson(options.saved_properties.dump(), &saved, &problem)) {
            return Fail("the saved property values cannot be read: " + problem);
        }
        merged = MergeProjectProperties(authored, saved);
    }

    SceneParseRequest request;
    request.quality = options.quality;
    request.scene_id                    = resolved.scene_source.scene_id;
    request.project_path                = project_file;
    request.project_properties          = &merged;
    request.authored_project_properties = &authored;
    request.pkg_version                 = options.package_version;
    request.user_options                = options.user_options;

    Random::seed(options.seed);
    WPSceneParser parser;
    scene = parser.Parse(request, scene_text, *vfs, *sound);
    if (scene == nullptr) return Fail("the parse produced no scene");
    scene->project_path = project_file;
    if (scene->runtime != nullptr) {
        scene->runtime->SetAudioResponseEnabled(false);
        scene->runtime->SetMediaIntegrationEnabled(false);
        scene->runtime->SetScreenResolution(linalg::Vector2f(static_cast<float>(options.width),
                                                             static_cast<float>(options.height)));
    }
    scene->vfs = std::move(vfs);
    if (!scene->shader_fallbacks.empty()) {
        return Fail("a shader of the scene did not compile: " + scene->shader_fallbacks.front());
    }
    return true;
}

// Picks the backend as the host does, then creates the renderer on a layer that no window owns.
bool GpuScene::Impl::OpenRenderer()
{
    const auto selection = metal::SelectSceneBackend(*scene);
    if (selection.failed()) return Fail("the native backend refused the scene: " + selection.failure_reason);

    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device == nil) return Fail("this machine has no Metal device");
        layer                = [CAMetalLayer layer];
        layer.device         = device;
        layer.pixelFormat    = MTLPixelFormatBGRA8Unorm;
        layer.framebufferOnly = NO;
        layer.contentsScale  = options.backing_scale;
        layer.drawableSize   = CGSizeMake(options.width * options.backing_scale,
                                          options.height * options.backing_scale);
    }

    metal::MetalRenderInitInfo info;
    info.metal_layer          = (__bridge void*)layer;
    info.width                = static_cast<uint16_t>(options.width);
    info.height               = static_cast<uint16_t>(options.height);
    info.display_scale_factor = options.backing_scale;
    info.display_characteristics = options.display_characteristics;
    info.display_hdr_output_allowed = options.display_hdr_output_allowed;
    info.display_id = options.display_id;
    info.redraw_callback = [flag=display_changed] { flag->store(true); };
    auto box                  = poster;
    info.wants_poster         = [box] {
        std::lock_guard<std::mutex> guard(box->mutex);
        return std::exchange(box->wanted, false);
    };
    info.poster_ready = [box](std::span<const uint8_t> pixels, uint32_t width, uint32_t height, bool bgra) {
        Image image { width, height, std::vector<uint8_t>(pixels.begin(), pixels.end()) };
        if (bgra) {
            for (std::size_t at = 0; at + 3 < image.rgba.size(); at += 4) std::swap(image.rgba[at], image.rgba[at + 2]);
        }
        std::lock_guard<std::mutex> guard(box->mutex);
        box->image     = std::move(image);
        box->delivered = true;
        box->condition.notify_all();
    };

    render = std::make_unique<metal::MetalRender>();
    if (!render->init(info)) {
        const std::string reason = render->lastError();
        render.reset();
        return Fail("the renderer could not start: " + reason);
    }
    return true;
}

bool GpuScene::Impl::CompileGraph()
{
    // Targets are allocated once, at the size they will keep.
    scene->render_scale = options.render_scale;
    scene->resolution   = CurrentSceneResolution();
    auto next           = sceneToRenderGraph(*scene);
    if (next == nullptr) return Fail("the scene produced no render graph");
    if (!render->compileRenderGraph(*scene, *next)) {
        return Fail("the render graph did not compile: " + render->lastError());
    }
    graph = std::move(next);
    ++compiles;
    if (scene->runtime != nullptr) {
        (void)scene->runtime->ConsumeSceneGraphMutationFlag();
        (void)scene->runtime->ConsumeRenderTargetResizeFlag();
    }
    return true;
}

// One frame, in the order the host's frame handler runs it.
bool GpuScene::Impl::StepOne()
{
    if (display_changed->exchange(false) && render && scene) render->RefreshDisplayOutput(*scene);
    Scene&      current = *scene;
    auto* const updater = current.shaderValueUpdater.get();
    auto* const runtime = current.runtime.get();
    const double step   = options.time_step;

    current.pointerPosition = { pointer_x, pointer_y };
    if (updater != nullptr) {
        updater->MouseInput(pointer_x, pointer_y);
        updater->MouseButtonsInput(0);
        updater->FrameBegin();
    }
    if (runtime != nullptr) {
        const WallpaperCursorMapping mapping = render->CursorMapping(current);
        if (mapping.valid) {
            CursorViewport viewport;
            viewport.origin = linalg::Vector2f(static_cast<float>(mapping.origin_x), static_cast<float>(mapping.origin_y));
            viewport.size   = linalg::Vector2f(static_cast<float>(mapping.size_x), static_cast<float>(mapping.size_y));
            viewport.content_origin = linalg::Vector2f(static_cast<float>(mapping.content_origin_x),
                                                       static_cast<float>(mapping.content_origin_y));
            viewport.content_size   = linalg::Vector2f(static_cast<float>(mapping.content_size_x),
                                                       static_cast<float>(mapping.content_size_y));
            runtime->SetCursorViewport(viewport);
        }
        runtime->SetCursorInput(pointer_x, pointer_y);
        runtime->SetCursorEnter(true);
        runtime->SetCursorButtons(0, 0, 0);
        cursor_was_in_window = runtime->DispatchCursorFrameEvents(cursor_was_in_window);
    }
    if (step > 0.0) current.targetFps = static_cast<uint32_t>(std::lround(1.0 / step));
    if (current.paritileSys != nullptr) current.paritileSys->Emitt();
    if (runtime != nullptr) {
        runtime->Tick(step);
        runtime->PumpTextLayerCache();
        (void)runtime->TakeUserShortcutRequests();
    }

    bool ok = true;
    if (runtime != nullptr) {
        const bool mutated = runtime->ConsumeSceneGraphMutationFlag();
        const bool resized = runtime->ConsumeRenderTargetResizeFlag();
        if (mutated) {
            ok = render->clearLastRenderGraphForRebuild() && CompileGraph();
        } else if (resized && !render->ResizeRenderTargets(current)) {
            ok = render->clearLastRenderGraphForRebuild() && CompileGraph();
        }
    }
    if (!ok) {
        if (!broken) Fail("the graph could not be rebuilt: " + render->lastError());
        if (updater != nullptr) updater->FrameEnd();
        return false;
    }
    if (current.paritileSys != nullptr) current.paritileSys->RebuildVisibleMeshes();

    bool presented = false;
    if (!render->drawFrame(current, &presented)) {
        Fail("the frame did not draw: " + render->lastError());
        if (updater != nullptr) updater->FrameEnd();
        return false;
    }
    current.PassFrameTime(step);
    if (updater != nullptr) updater->FrameEnd();

    const auto counts = render->LastFrameEncodeCountsForTests();
    last_passes       = { counts.render_passes, counts.scene_output_passes, counts.blit_passes };
    frame_passes.push_back(last_passes);
    ++frames;
    return true;
}

void GpuScene::Impl::ReleaseAll()
{
    if (released) return;
    released = true;
    // The renderer waits for the GPU to finish reading the targets before they are released,
    // and goes first so nothing it draws from is gone.
    graph.reset();
    if (render != nullptr) {
        render->destroy();
        render.reset();
    }
    scene.reset();
    layer = nil;
    sound.reset();
}

// ---- GpuScene ----------------------------------------------------------------------------

GpuScene::GpuScene(const ScenePackage& package, GpuSceneOptions options) : impl_(std::make_unique<Impl>())
{
    Impl& impl         = *impl_;
    impl.options       = std::move(options);
    impl.project_file  = package.project_file();
    if (!MetalAvailable()) {
        impl.Fail("no Metal device in this process");
        impl.released = true;
        return;
    }

    impl.previous_optimization = render::SceneOptimizationEnabled();
    render::SetSceneOptimizationEnabled(impl.options.scene_optimization);

    // The scratch shader cache and the empty shared-assets folder sit beside the package,
    // never inside the project folder.
    std::string pattern = (disk::temp_directory_path() / "we-scene-run-XXXXXX").string();
    if (::mkdtemp(pattern.data()) == nullptr) {
        impl.Fail("cannot create the scratch folder");
        return;
    }
    impl.scratch          = pattern;
    impl.cache_directory  = impl.scratch / "cache";
    impl.shared_directory = impl.scratch / "shared";
    std::error_code made;
    disk::create_directories(impl.cache_directory, made);
    disk::create_directories(impl.shared_directory, made);

    impl.sound = std::make_unique<audio::SoundManager>(audio::SoundManager::OutputBackend::Null);
    if (!impl.Load() || !impl.OpenRenderer() || !impl.CompileGraph()) return;
}

GpuScene::~GpuScene()
{
    if (impl_ == nullptr) return;
    impl_->ReleaseAll();
    if (!impl_->scratch.empty()) {
        std::error_code ignored;
        disk::remove_all(impl_->scratch, ignored);
        render::SetSceneOptimizationEnabled(impl_->previous_optimization);
    }
}

bool GpuScene::ok() const
{
    return !impl_->broken && !impl_->released && impl_->graph != nullptr;
}
const std::string& GpuScene::error() const { return impl_->error; }

bool GpuScene::Step(int frames)
{
    if (!ok()) return false;
    for (int i = 0; i < frames; ++i) {
        @autoreleasepool {
            if (!impl_->StepOne()) return false;
        }
    }
    return true;
}

Image GpuScene::Run(int frames)
{
    if (!Step(frames)) return {};
    return Picture();
}

Image GpuScene::Picture()
{
    Impl& impl = *impl_;
    if (!ok()) return {};
    {
        std::lock_guard<std::mutex> guard(impl.poster->mutex);
        impl.poster->wanted    = true;
        impl.poster->delivered = false;
    }
    const auto outcome = impl.render->ServicePosterRequest(*impl.scene);
    if (outcome != metal::PosterServiceResult::Submitted) {
        impl.error = outcome == metal::PosterServiceResult::NoFrameYet
                         ? "no frame has been drawn yet"
                         : "the picture could not be composed: " + impl.render->lastError();
        return {};
    }
    std::unique_lock<std::mutex> lock(impl.poster->mutex);
    if (!impl.poster->condition.wait_for(lock, std::chrono::seconds(20), [&] { return impl.poster->delivered; })) {
        impl.error = "the composed picture did not arrive in 20 seconds";
        return {};
    }
    return std::move(impl.poster->image);
}

void GpuScene::SetPointer(double x, double y)
{
    impl_->pointer_x = static_cast<float>(std::clamp(x, 0.0, 1.0));
    impl_->pointer_y = static_cast<float>(std::clamp(y, 0.0, 1.0));
}

void GpuScene::Reseed() { Random::seed(impl_->options.seed); }

bool GpuScene::SetProperty(const std::string& name, const Json& value)
{
    Impl& impl = *impl_;
    if (!ok() || impl.scene->runtime == nullptr) return false;
    impl.preview_values[name] = value;
    Json document             = Json::object();
    for (const auto& [key, held] : impl.preview_values) document[key] = held;
    ProjectProperties table;
    std::string       problem;
    if (!ParseFlatProjectPropertyOverrideJson(document.dump(), &table, &problem)) {
        impl.error = "the property document is not valid: " + problem;
        return false;
    }
    (void)impl.scene->runtime->PreviewProjectPropertyOverride(table);
    return true;
}

void GpuScene::TickRuntime(double seconds)
{
    if (ok() && impl_->scene->runtime != nullptr) impl_->scene->runtime->Tick(seconds);
}

PassCounts GpuScene::LastFramePasses() const { return impl_->last_passes; }
const std::vector<PassCounts>& GpuScene::FramePasses() const { return impl_->frame_passes; }
PassCounts GpuScene::FirstFramePasses() const
{
    return impl_->frame_passes.empty() ? PassCounts {} : impl_->frame_passes.front();
}
uint64_t GpuScene::frames() const { return impl_->frames; }

std::vector<std::string> GpuScene::RenderTargetNames() const
{
    std::vector<std::string> names;
    if (impl_->scene == nullptr) return names;
    for (const auto& [name, target] : impl_->scene->renderTargets) {
        (void)target;
        names.push_back(name);
    }
    std::sort(names.begin(), names.end());
    return names;
}

std::vector<std::string> GpuScene::RenderTargetsOfLayer(int id) const
{
    // The buffers of a layer's effect chain carry its id: the ping-pong pair is named for the
    // layer's effect camera, and each buffer an effect declares ends in `_<id>_<index>`.
    const std::string camera = "__effect_layer_" + std::to_string(id);
    const std::string middle = "_" + std::to_string(id) + "_";
    std::vector<std::string> owned;
    for (const std::string& name : RenderTargetNames()) {
        const bool pair   = name.find(camera) != std::string::npos;
        const bool effect = name.find(middle) != std::string::npos && name.rfind("_rt_", 0) != 0;
        if (pair || effect) owned.push_back(name);
    }
    return owned;
}

bool GpuScene::ReadRenderTarget(const std::string& name, Image* out, std::vector<float>* radiance)
{
    if (!ok() || out == nullptr) return false;
    std::vector<uint8_t> rgba;
    uint32_t             width = 0, height = 0;
    if (!impl_->render->ReadRenderTargetForTests(name, rgba, width, height, radiance)) return false;
    *out = Image { width, height, std::move(rgba) };
    return true;
}

Image GpuScene::RenderTarget(const std::string& name)
{
    Image image;
    if (!ReadRenderTarget(name, &image)) return {};
    return image;
}

bool GpuScene::Rebuild()
{
    Impl& impl = *impl_;
    if (!ok()) return false;
    if (!impl.render->clearLastRenderGraphForRebuild()) {
        return impl.Fail("the old graph could not be released: " + impl.render->lastError());
    }
    impl.graph.reset();
    return impl.CompileGraph();
}

int GpuScene::RebuildCount() const { return std::max(0, impl_->compiles - 1); }

void GpuScene::Release() { impl_->ReleaseAll(); }
bool GpuScene::released() const { return impl_->released; }

Scene&                  GpuScene::scene() { return *impl_->scene; }
SceneRuntimeContext*    GpuScene::runtime() { return impl_->scene->runtime.get(); }
metal::MetalRender&     GpuScene::renderer() { return *impl_->render; }

} // namespace we_test
