#pragma once

#include "Audio/AudioResponseService.h"
#include "Interface/IShaderValueUpdater.h"
#include "Presentation/WallpaperScaling.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneCamera.h"

#include <cmath>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <nlohmann/json.hpp>
#include <optional>
#include <stdexcept>
#include <unordered_set>
#include <vector>

namespace wallpaper::tests {

// Synthetic scene input only: never reads or moves the desktop pointer.
class SceneProbeControls {
public:
    SceneProbeControls() {
        if (const char* input = std::getenv("WE_TEST_INPUT_JSON")) {
            auto events = nlohmann::json::parse(input);
            if (!events.is_array()) throw std::runtime_error("WE_TEST_INPUT_JSON must be an array");
            uint32_t previous = 0;
            for (const auto& event : events) {
                Step step;
                step.frame = event.at("frame").get<uint32_t>();
                if (step.frame < previous) throw std::runtime_error("input frames must be ordered");
                previous = step.frame;
                if (event.contains("layer")) step.layer = event.at("layer").get<int32_t>();
                if (event.contains("x")) step.x = event.at("x").get<float>();
                if (event.contains("y")) step.y = event.at("y").get<float>();
                if (event.contains("inside")) step.inside = event.at("inside").get<bool>();
                if (event.contains("buttons")) step.buttons = event.at("buttons").get<uint32_t>();
                steps_.push_back(step);
            }
        }
        if (const char* samples = std::getenv("WE_TEST_SAMPLE_FRAMES")) {
            for (const auto& frame : nlohmann::json::parse(samples))
                samples_.insert(frame.get<uint32_t>());
        }
        if (const char* amplitude = std::getenv("WE_TEST_AUDIO_AMPLITUDE")) {
            char* end = nullptr;
            amplitude_ = std::strtof(amplitude, &end);
            if (end == amplitude || *end != '\0' || !std::isfinite(amplitude_) ||
                amplitude_ < 0.0f || amplitude_ > 1.0f)
                throw std::runtime_error("WE_TEST_AUDIO_AMPLITUDE must be 0..1");
        }
        if (const char* path = std::getenv("WE_TEST_AUDIO_FILE")) {
            std::ifstream file(path, std::ios::binary);
            const std::vector<char> bytes((std::istreambuf_iterator<char>(file)), {});
            if (bytes.size() < sizeof(float) || bytes.size() % sizeof(float) != 0)
                throw std::runtime_error("WE_TEST_AUDIO_FILE must be raw float32 mono PCM");
            audio_file_.resize(bytes.size() / sizeof(float));
            std::memcpy(audio_file_.data(), bytes.data(), bytes.size());
        }
    }

    bool sample(uint32_t frame) const { return samples_.contains(frame); }
    bool hasInput() const { return !steps_.empty(); }
    // A file plays on from where the previous frame stopped, looping.
    float audioSample(std::size_t index, double hz) {
        if (!audio_file_.empty()) {
            const float sample = audio_file_[audio_file_position_];
            audio_file_position_ = (audio_file_position_ + 1u) % audio_file_.size();
            return sample;
        }
        if (noise_) {
            noise_state_ = noise_state_ * 1664525u + 1013904223u;
            return amplitude_ * static_cast<float>(2.0 * noise_state_ / 4294967295.0 - 1.0);
        }
        return amplitude_ * std::sin(2.0 * 3.141592653589793 * hz * index /
                                     audio::kAudioResponseSampleRate);
    }

    void input(Scene& scene, uint32_t frame, const WallpaperCursorMapping& mapping) {
        if (steps_.empty() || scene.runtime == nullptr || !mapping.valid) return;
        while (next_ < steps_.size() && steps_[next_].frame <= frame) {
            const auto& step = steps_[next_++];
            if (step.x || step.y) followed_ = nullptr;
            if (step.x) x_ = *step.x;
            if (step.y) y_ = *step.y;
            if (step.inside) inside_ = *step.inside;
            if (step.buttons) buttons_ = *step.buttons;
            if (step.layer) {
                followed_ = find(scene.sceneGraph.get(), *step.layer);
                if (!followed_) throw std::runtime_error("probe input layer not found");
            }
        }
        if (followed_) {
            followed_->UpdateTrans();
            const linalg::Vector4d world = followed_->ModelTrans() * linalg::Vector4d(0, 0, 0, 1);
            const linalg::Vector4d clip = scene.activeCamera->GetViewProjectionMatrix() * world;
            if (clip.w() > 0.0 && std::isfinite(clip.w())) {
                const double cx = mapping.content_origin_x + (clip.x() / clip.w() + 1.0) * 0.5 * mapping.content_size_x;
                const double cy = mapping.content_origin_y + (clip.y() / clip.w() + 1.0) * 0.5 * mapping.content_size_y;
                x_ = static_cast<float>((cx - mapping.origin_x) / mapping.size_x);
                y_ = static_cast<float>(1.0 - (cy - mapping.origin_y) / mapping.size_y);
            }
        }
        scene.pointerPosition = {x_, y_};
        if (scene.shaderValueUpdater) {
            scene.shaderValueUpdater->MouseInput(x_, y_);
            scene.shaderValueUpdater->MouseButtonsInput(buttons_);
        }
        auto& runtime = *scene.runtime;
        runtime.SetCursorViewport(CursorViewport {
            .origin = linalg::Vector2f(mapping.origin_x, mapping.origin_y),
            .size = linalg::Vector2f(mapping.size_x, mapping.size_y),
            .content_origin = linalg::Vector2f(mapping.content_origin_x, mapping.content_origin_y),
            .content_size = linalg::Vector2f(mapping.content_size_x, mapping.content_size_y),
        });
        runtime.SetCursorInput(x_, y_);
        runtime.SetCursorEnter(inside_);
        runtime.SetCursorButtons(buttons_, buttons_ & ~previous_buttons_, previous_buttons_ & ~buttons_);
        was_inside_ = runtime.DispatchCursorFrameEvents(was_inside_);
        previous_buttons_ = buttons_;
    }

    void state(const Scene& scene, uint32_t frame, const std::filesystem::path& output) const {
        nlohmann::json report = {
            {"frame", frame}, {"scene_time", scene.elapsingTime},
            {"cursor", {x_, y_}}, {"inside", inside_}, {"buttons", buttons_},
            {"script_errors", scene.runtime ? scene.runtime->scriptErrorCount() : 0},
            {"nodes", nlohmann::json::array()},
        };
        const auto visit = [&](auto&& self, SceneNode* node) -> void {
            if (!node) return;
            node->UpdateTrans();
            const auto world = node->ModelTrans();
            nlohmann::json item = {
                {"id", node->ID()}, {"name", node->Name()}, {"visible", node->EffectiveVisible()},
                {"position", {world(0, 3), world(1, 3), world(2, 3)}},
                {"scale", {node->Scale().x(), node->Scale().y(), node->Scale().z()}},
            };
            if (scene.runtime) {
                if (auto text = scene.runtime->NodeTextState(node->Name())) item["text"] = text->text;
            }
            if (const auto* mesh = node->Mesh()) {
                item["materials"] = nlohmann::json::array();
                for (const auto& material : mesh->MaterialSlots()) {
                    if (!material) continue;
                    nlohmann::json constants = nlohmann::json::object();
                    for (const auto& [name, value] : material->customShader.constValues) {
                        auto values = nlohmann::json::array();
                        for (std::size_t i = 0; i < value.size(); ++i) values.push_back(value[i]);
                        constants[name] = std::move(values);
                    }
                    item["materials"].push_back({{"shader", material->name}, {"constants", std::move(constants)}});
                }
            }
            report["nodes"].push_back(std::move(item));
            for (const auto& child : node->GetChildren()) self(self, child.get());
        };
        visit(visit, scene.sceneGraph.get());
        std::filesystem::create_directories(output);
        std::ofstream(output / ("state-" + std::to_string(frame) + ".json")) << report.dump(2);
    }

private:
    struct Step {
        uint32_t frame {0};
        std::optional<int32_t> layer;
        std::optional<float> x, y;
        std::optional<bool> inside;
        std::optional<uint32_t> buttons;
    };
    static SceneNode* find(SceneNode* node, int32_t id) {
        if (!node) return nullptr;
        if (node->ID() == id) return node;
        for (const auto& child : node->GetChildren())
            if (auto* found = find(child.get(), id)) return found;
        return nullptr;
    }
    std::vector<Step> steps_;
    std::unordered_set<uint32_t> samples_;
    std::size_t next_ {0};
    SceneNode* followed_ {nullptr};
    float x_ {0.5f}, y_ {0.5f};
    bool inside_ {false}, was_inside_ {false};
    uint32_t buttons_ {0}, previous_buttons_ {0};
    float amplitude_ {0.025f};
    bool noise_ {std::getenv("WE_TEST_AUDIO_NOISE") != nullptr};
    uint32_t noise_state_ {17};
    std::vector<float> audio_file_;
    std::size_t audio_file_position_ {0};
};

} // namespace wallpaper::tests
