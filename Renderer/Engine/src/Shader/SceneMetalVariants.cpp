#include "Shader/SceneMetalVariants.hpp"

#include "MetalRender/SceneMetalProgram.hpp"
#include "Scene/Scene.h"
#include "Shader/RustShaderBridge.hpp"
#include "Utils/Logging.h"
#include "Scene/Parse/WPShaderParser.hpp"

#include <atomic>
#include <condition_variable>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace wallpaper
{
namespace
{

/// One compile at a time, and never more than this many waiting.
///
/// One worker because a variant is optional work that must never compete with
/// the wallpaper for a core; a bounded queue because a user flipping a setting
/// while wallpapers load must not be able to grow an unbounded backlog. A
/// submission that does not fit is simply not made, and the program stays in
/// the state it was: the ordinary path keeps drawing and the next frame
/// boundary can ask again.
constexpr std::size_t kMaxQueued = 32;

SceneMetalSlotKind ToSceneMetalSlotKind(shader::RustShaderMetalSlotKind kind)
{
    switch (kind) {
    case shader::RustShaderMetalSlotKind::Texture: return SceneMetalSlotKind::Texture;
    case shader::RustShaderMetalSlotKind::Sampler: return SceneMetalSlotKind::Sampler;
    case shader::RustShaderMetalSlotKind::Buffer: break;
    }
    return SceneMetalSlotKind::Buffer;
}

struct VariantJob
{
    std::shared_ptr<const SceneMetalProgram> program;
    /// Where this process keeps regenerable compile results. Carried on the
    /// job rather than on the program's inputs because it describes this
    /// installation, not the program: the same shader compiled on another
    /// machine is the same shader.
    std::string                              cache_root;
    /// The submission epoch. A job queued before the last cancellation is not
    /// started; one already running cannot be taken back.
    uint64_t                                 epoch { 0 };
};

class VariantCompiler
{
public:
    static VariantCompiler& Instance()
    {
        static VariantCompiler compiler;
        return compiler;
    }

    void submit(std::shared_ptr<const SceneMetalProgram> program, std::string cache_root)
    {
        if (program == nullptr) return;
        // The program itself decides whether it is free to be compiled, which
        // is what keeps two surfaces showing the same wallpaper from compiling
        // one program twice.
        if (! program->claimVideoPlaneCompile()) return;

        {
            const std::lock_guard lock { m_mutex };
            if (m_queue.size() >= kMaxQueued) {
                // Give the claim back rather than dropping the request on the
                // floor: this program is then still in its resting state and a
                // later frame can ask again.
                program->releaseVideoPlaneClaim();
                return;
            }
            m_queue.push_back(VariantJob { .program    = std::move(program),
                                           .cache_root = std::move(cache_root),
                                           .epoch      = m_epoch });
            start();
        }
        m_wake.notify_one();
    }

    void cancel()
    {
        {
            const std::lock_guard lock { m_mutex };
            for (auto& job : m_queue) {
                // Never started, so the program is put back the way it was.
                if (job.program != nullptr) job.program->releaseVideoPlaneClaim();
            }
            m_queue.clear();
            ++m_epoch;
        }
        m_wake.notify_one();
    }

    void shutdown()
    {
        cancel();
        {
            const std::lock_guard lock { m_mutex };
            m_stop = true;
        }
        m_wake.notify_all();
        if (m_worker.joinable()) m_worker.join();
        // Stopped, not disabled. One wallpaper surface going away must not
        // leave the next one in this process unable to prepare anything; the
        // next submission starts a fresh worker.
        const std::lock_guard lock { m_mutex };
        m_stop = false;
    }

    [[nodiscard]] uint64_t completed() const
    {
        return m_completed.load(std::memory_order_relaxed);
    }

private:
    VariantCompiler() = default;
    ~VariantCompiler() { shutdown(); }

    /// Started on the first submission, not at process start: a run that never
    /// asks for a variant never creates a thread.
    void start()
    {
        if (m_worker.joinable() || m_stop) return;
        m_worker = std::thread([this] {
            loop();
        });
    }

    void loop()
    {
        while (true) {
            VariantJob job;
            {
                std::unique_lock lock { m_mutex };
                m_wake.wait(lock, [this] {
                    return m_stop || ! m_queue.empty();
                });
                if (m_stop) return;
                job = std::move(m_queue.front());
                m_queue.pop_front();
            }
            compile(job);
            m_completed.fetch_add(1, std::memory_order_relaxed);
        }
    }

    static void compile(const VariantJob& job)
    {
        const auto& program = job.program;
        if (program == nullptr || program->video_plane_inputs == nullptr) return;
        const auto& inputs = *program->video_plane_inputs;

        auto variant  = std::make_shared<SceneMetalVideoPlaneVariant>();
        variant->slot = inputs.nv12_plane_slot;

        std::vector<shader::RustShaderMetalStage> stages;
        std::string                               reflection_json;
        std::string                               error;
        if (! WPShaderParser::CompileMslVariant(
                inputs, job.cache_root, stages, &reflection_json, &error)) {
            variant->error = error.empty() ? "the plane variant could not be compiled" : error;
        } else {
            variant->reflection_json = std::move(reflection_json);
            for (const auto& stage : stages) {
                SceneMetalStage out;
                out.kind             = stage.kind == ShaderType::FRAGMENT
                                           ? SceneMetalStageKind::Fragment
                                           : SceneMetalStageKind::Vertex;
                out.source           = stage.source;
                out.entry_point      = stage.entry_point;
                out.language_version = stage.language_version;
                out.bindings.reserve(stage.bindings.size());
                for (const auto& binding : stage.bindings) {
                    out.bindings.push_back(SceneMetalBinding {
                        .name      = binding.name,
                        .set       = binding.set,
                        .binding   = binding.binding,
                        .slot_kind = ToSceneMetalSlotKind(binding.slot_kind),
                        .slot      = binding.slot,
                    });
                }
                variant->stages.push_back(std::move(out));
            }
            if (variant->stages.empty() || variant->reflection_json.empty()) {
                variant->error = "the plane variant produced no usable shader";
            }
        }

        if (! variant->error.empty()) {
            // Once, with the reason. The program remembers it as failed, so the
            // same condition is never logged again for this scene.
            LOG_INFO("metal video plane variant of '%s' not used: %s",
                     inputs.shader_name.c_str(),
                     variant->error.c_str());
        }
        program->publishVideoPlanes(std::move(variant));
    }

    mutable std::mutex      m_mutex;
    std::condition_variable m_wake;
    std::deque<VariantJob>  m_queue;
    std::thread             m_worker;
    uint64_t                m_epoch { 0 };
    bool                    m_stop { false };
    std::atomic<uint64_t>   m_completed { 0 };
};

} // namespace

void RequestSceneMetalVariants(Scene& scene, bool wanted, std::string_view cache_root)
{
    if (! wanted) return;
    for (const auto& program : scene.metal_variant_candidates) {
        if (program == nullptr) continue;
        if (program->videoPlaneState() != SceneMetalVariantState::None) continue;
        VariantCompiler::Instance().submit(program, std::string(cache_root));
    }
}

void CancelSceneMetalVariants() { VariantCompiler::Instance().cancel(); }

void ShutdownSceneMetalVariants() { VariantCompiler::Instance().shutdown(); }

uint64_t SceneMetalVariantCompileCount() { return VariantCompiler::Instance().completed(); }

} // namespace wallpaper
