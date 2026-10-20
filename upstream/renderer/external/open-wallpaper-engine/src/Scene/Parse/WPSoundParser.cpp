#include "WPSoundParser.hpp"

#include "Audio/SampleMath.h"
#include "Fs/VFS.h"
#include "Runtime/DynamicValue.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/SceneSettingResolver.hpp"
#include "Utils/Logging.h"
#include "wpscene/WPSoundObject.h"

#include <nlohmann/json.hpp>

#include <algorithm>
#include <cmath>
#include <limits>
#include <optional>
#include <random>
#include <string>
#include <string_view>
#include <utility>

using namespace wallpaper;

PlaybackMode wallpaper::ParseSoundPlaybackMode(std::string_view value) {
    if (value == "single") return PlaybackMode::OneShot;
    if (value == "random") return PlaybackMode::Random;
    return PlaybackMode::Loop;
}

WPSoundStream::WPSoundStream(const std::vector<std::string>& paths, fs::VFS& vfs, Config config)
    : WPSoundStream(
          [&paths, &vfs] {
              std::vector<StreamFactory> factories;
              factories.reserve(paths.size());
              for (const auto& path : paths) {
                  factories.emplace_back([&vfs, path](const Desc& desc) {
                      return std::shared_ptr<audio::SoundStream>(
                          audio::CreateSoundStream(vfs.Open("/assets/" + path),
                                                   desc,
                                                   { .loop = false }));
                  });
              }
              return factories;
          }(),
          config) {}

WPSoundStream::WPSoundStream(std::vector<StreamFactory> factories, Config config)
    : m_config(config),
      m_stream_factories(std::move(factories)),
      m_volume(audio::ClampVolume(config.volume)),
      m_muted(config.muted),
      m_playing(! config.startsilent) {
    m_config.volume = m_volume.load(std::memory_order_relaxed);
    if (m_config.random_seed) m_random.seed(*m_config.random_seed);
}

WPSoundStream::~WPSoundStream() = default;

uint64_t WPSoundStream::NextPcmData(void* data, uint32_t frame_count) {
    if (data == nullptr || m_desc.channels == 0 || m_stream_factories.empty()) return 0;
    const auto sample_count = static_cast<std::size_t>(frame_count) * m_desc.channels;
    audio::ClearInterleavedF32(data, sample_count);
    if (m_rewind_requested.exchange(false, std::memory_order_relaxed)) {
        m_cur_active.reset();
        m_cur_index = 0;
        m_delay_frames = 0;
        m_finished.store(false, std::memory_order_relaxed);
    }
    if (! m_playing.load(std::memory_order_relaxed)) return frame_count;

    uint32_t written = 0;
    std::size_t empty_sources = 0;
    while (written < frame_count) {
        if (m_delay_frames != 0) {
            const auto silence = std::min<uint64_t>(m_delay_frames, frame_count - written);
            m_delay_frames -= silence;
            written += static_cast<uint32_t>(silence);
            continue;
        }
        if (! m_cur_active) Switch();
        if (! m_cur_active) break;
        const auto count = std::min<uint64_t>(frame_count - written,
            m_cur_active->NextPcmData(static_cast<float*>(data) + static_cast<size_t>(written) * m_desc.channels,
                                     frame_count - written));
        if (count != 0) {
            written += static_cast<uint32_t>(count);
            empty_sources = 0;
            continue;
        }
        if (m_config.mode == PlaybackMode::OneShot) {
            m_playing.store(false, std::memory_order_relaxed);
            m_finished.store(true, std::memory_order_relaxed);
            break;
        }
        m_cur_active.reset();
        if (m_config.mode == PlaybackMode::Random) m_delay_frames = DelayFrames();
        // Empty or unreadable inputs must not spin on the audio worker.
        if (++empty_sources > m_stream_factories.size()) break;
    }
    if (m_muted.load(std::memory_order_relaxed)) audio::ClearInterleavedF32(data, sample_count);
    else audio::ApplyVolumeF32(data, sample_count, m_volume.load(std::memory_order_relaxed));
    return frame_count;
}

uint64_t WPSoundStream::DelayFrames() {
    const double minimum = std::isfinite(m_config.mintime) ? std::max(0.0f, m_config.mintime) : 0.0;
    const double maximum = std::isfinite(m_config.maxtime) ? std::max(minimum, double(m_config.maxtime)) : minimum;
    const double seconds = std::uniform_real_distribution<double>(minimum, maximum)(m_random);
    return static_cast<uint64_t>(std::min(std::ceil(seconds * m_desc.sampleRate),
                                         double(std::numeric_limits<int64_t>::max())));
}

void WPSoundStream::PassDesc(const Desc& desc) {
    if (m_desc.sampleRate != 0 && m_desc.sampleRate != desc.sampleRate) {
        m_delay_frames = static_cast<uint64_t>(std::min(
            std::ceil(double(m_delay_frames) * desc.sampleRate / m_desc.sampleRate),
            double(std::numeric_limits<int64_t>::max())));
    }
    m_desc = desc;
    if (m_cur_active != nullptr) m_cur_active->PassDesc(desc);
}

void WPSoundStream::Play() {
    if (m_finished.exchange(false, std::memory_order_relaxed)) {
        m_rewind_requested.store(true, std::memory_order_relaxed);
    }
    m_playing.store(true, std::memory_order_relaxed);
}

void WPSoundStream::Pause() { m_playing.store(false, std::memory_order_relaxed); }

void WPSoundStream::Stop() {
    m_playing.store(false, std::memory_order_relaxed);
    m_finished.store(false, std::memory_order_relaxed);
    m_rewind_requested.store(true, std::memory_order_relaxed);
}

bool WPSoundStream::IsPlaying() const { return m_playing.load(std::memory_order_relaxed); }

void WPSoundStream::SetVolume(float volume) {
    m_volume.store(audio::ClampVolume(volume), std::memory_order_relaxed);
}

float WPSoundStream::Volume() const { return m_volume.load(std::memory_order_relaxed); }

void WPSoundStream::SetMuted(bool muted) { m_muted.store(muted, std::memory_order_relaxed); }

bool WPSoundStream::Muted() const { return m_muted.load(std::memory_order_relaxed); }

void WPSoundStream::Switch() {
    if (m_stream_factories.empty()) return;
    auto stream = m_stream_factories[LoopIndex()](m_desc);
    if (stream == nullptr) {
        m_cur_active.reset();
        return;
    }
    stream->PassDesc(m_desc);
    m_cur_active = std::move(stream);
}

std::size_t WPSoundStream::LoopIndex() {
    if (m_config.mode == PlaybackMode::Random) {
        std::uniform_int_distribution<std::size_t> distribution(0, m_stream_factories.size() - 1);
        return distribution(m_random);
    }

    const std::size_t index = m_cur_index;
    m_cur_index++;
    if (m_cur_index == m_stream_factories.size()) m_cur_index = 0;
    return index;
}

void WPSoundParser::Parse(const wpscene::WPSoundObject& obj, fs::VFS& vfs, audio::SoundManager& sm,
                          SceneRuntimeContext* runtime, std::string_view runtime_name) {
    // The user's own slider wins over the author's default when the author
    // bound one: that binding is the whole point of the slider.
    float volume = obj.volume;
    if (runtime != nullptr && ! obj.volume_user.empty()) {
        if (const auto* bound = runtime->FindPropertyValue(obj.volume_user);
            bound != nullptr && bound->getType() == DynamicValue::UnderlyingType::Float) {
            volume = bound->getFloat();
        }
    }

    WPSoundStream::Config config { .maxtime     = obj.maxtime,
                                   .mintime     = obj.mintime,
                                   .volume      = audio::ClampVolume(volume),
                                   .muted       = obj.muted,
                                   .startsilent = obj.startsilent,
                                   .mode        = ParseSoundPlaybackMode(obj.playbackmode) };

    auto stream = std::make_shared<WPSoundStream>(obj.sound, vfs, config);
    if (runtime != nullptr) {
        runtime->RegisterSoundLayer(runtime_name.empty() ? obj.name : std::string(runtime_name),
                                    stream);
        // The read above is the volume the layer starts with; this keeps it in
        // step with the slider afterwards.
        BindVolumeProperty(*runtime, stream, obj.volume_user, obj.volume);
    }
    sm.MountStream(stream);
}

void WPSoundParser::BindVolumeProperty(SceneRuntimeContext& runtime,
                                       std::weak_ptr<WPSoundStream> stream,
                                       std::string_view property, float authored_volume) {
    if (property.empty()) return;

    // The same binding every other slider-driven setting resolves, so the layer
    // sees the property exactly as a fresh load would: the authored volume while
    // the project declares no such property, the property's value once it does.
    const nlohmann::json setting { { "user", std::string(property) },
                                   { "value", authored_volume } };
    // The last value the property gave. Every property is refreshed whenever a
    // document is applied, so an unchanged one must not undo a volume a script
    // has set since.
    auto applied = std::make_shared<std::optional<float>>();
    runtime.RegisterDynamicValueListener(
        ResolveFloatSetting(runtime, setting),
        [stream = std::move(stream), applied](const DynamicValue& value) {
            if (value.getType() != DynamicValue::UnderlyingType::Float &&
                value.getType() != DynamicValue::UnderlyingType::Int) {
                return;
            }
            const float volume = value.getFloat();
            if (applied->has_value() && **applied == volume) return;
            *applied = volume;
            if (const auto live = stream.lock()) live->SetVolume(volume);
        });
}
