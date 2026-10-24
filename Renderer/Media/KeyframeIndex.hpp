// Seeking in a flat sample table: which sync sample to start decoding from to
// show a given presentation time. Shared by every reader that produces Samples.
#pragma once

#include "Media/VideoTypes.hpp"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <vector>

namespace wallpaper::media
{

class KeyframeIndex {
public:
    /// Collects the sync samples of `samples` (decode order). Call once the table is final.
    void build(const std::vector<Sample>& samples)
    {
        m_indices.clear();
        m_increasing = true;
        for (std::size_t index = 0; index < samples.size(); ++index) {
            if (samples[index].sync) m_indices.push_back(static_cast<std::uint32_t>(index));
        }
        for (std::size_t index = 1; index < m_indices.size(); ++index) {
            if (samples[m_indices[index]].pts < samples[m_indices[index - 1]].pts) {
                m_increasing = false;
                break;
            }
        }
    }

    bool empty() const { return m_indices.empty(); }
    std::size_t count() const { return m_indices.size(); }

    /// The index of the last sync sample whose presentation time is at or before
    /// `pts`. A time before every sync sample gives the first one; nullopt only
    /// when there is no sync sample at all. Binary search over the sync samples
    /// when they are in presentation order (they are in every real file), a scan
    /// otherwise.
    std::optional<std::size_t> findAtOrBefore(const std::vector<Sample>& samples, std::int64_t pts) const
    {
        if (m_indices.empty()) return std::nullopt;
        if (m_increasing) {
            const auto after = std::upper_bound(m_indices.begin(), m_indices.end(), pts,
                                                [&samples](std::int64_t value, std::uint32_t index) {
                                                    return value < samples[index].pts;
                                                });
            return after == m_indices.begin() ? m_indices.front() : *(after - 1);
        }
        std::optional<std::size_t> best;
        for (std::uint32_t index : m_indices) {
            if (samples[index].pts <= pts && (! best || samples[index].pts >= samples[*best].pts)) best = index;
        }
        return best ? best : std::optional<std::size_t> { m_indices.front() };
    }

private:
    std::vector<std::uint32_t> m_indices;
    bool                       m_increasing { true };
};

} // namespace wallpaper::media
