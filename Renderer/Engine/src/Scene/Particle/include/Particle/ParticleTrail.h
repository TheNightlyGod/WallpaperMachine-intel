#pragma once

#include <cstdint>
#include <vector>

#include "Utils/Linalg.hpp"

namespace wallpaper
{

/// One recorded point of a particle's path, in the space the particle mesh is
/// drawn in: the owning instance's offset is already added, so a trail that
/// follows a moving parent keeps the path it really travelled.
///
/// Position only. A trail is drawn with the particle's current colour, alpha
/// and size along its whole length, so nothing else is worth remembering.
struct ParticleTrailSample {
    linalg::Vector3f position { 0.0f, 0.0f, 0.0f };
};

/// What a rope trail renderer asks the simulation to remember.
///
/// `samples` is how many recorded points one particle keeps and `period` is the
/// simulated time between two of them, so a full history spans
/// `samples * period` seconds of the particle's own path. Zero samples means the
/// subsystem keeps no history at all, which is every renderer but a rope trail.
struct ParticleTrailConfig {
    uint32_t samples { 0 };
    double   period { 0.0 };

    bool enabled() const noexcept { return samples > 0 && period > 0.0; }
};

/// The path one particle has travelled, newest point first.
///
/// Owned by the simulation and keyed by the particle's slot, never by a render
/// target: this is geometry history, not a previous frame's pixels. A slot's
/// history is reset when a new particle is spawned into it, so two particles
/// that reuse one slot are never joined into a single line.
class ParticleTrailHistory {
public:
    /// Forgets every point and sets how many may be held from now on.
    void Reset(uint32_t capacity) {
        m_samples.assign(capacity, ParticleTrailSample {});
        m_head  = 0;
        m_count = 0;
    }

    /// Records the newest point, dropping the oldest once the history is full.
    void Push(const ParticleTrailSample& sample) noexcept {
        if (m_samples.empty()) return;
        const auto capacity = static_cast<uint32_t>(m_samples.size());
        m_head              = (m_head + capacity - 1) % capacity;
        m_samples[m_head]   = sample;
        if (m_count < capacity) ++m_count;
    }

    /// Carries every recorded point through `transform`, a change of the space
    /// the points are expressed in.
    void Transform(const linalg::Matrix4d& transform) noexcept {
        for (auto& sample : m_samples) {
            const linalg::Vector4d moved =
                transform * linalg::Vector4d(sample.position.x(), sample.position.y(),
                                            sample.position.z(), 1.0);
            sample.position = moved.head<3>().cast<float>();
        }
    }

    uint32_t Count() const noexcept { return m_count; }
    uint32_t Capacity() const noexcept { return static_cast<uint32_t>(m_samples.size()); }

    /// `age` 0 is the newest point; `age` must be below `Count()`.
    const ParticleTrailSample& At(uint32_t age) const noexcept {
        return m_samples[(m_head + age) % static_cast<uint32_t>(m_samples.size())];
    }

private:
    std::vector<ParticleTrailSample> m_samples;
    uint32_t                         m_head { 0 };
    uint32_t                         m_count { 0 };
};

} // namespace wallpaper
