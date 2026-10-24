#include "Media/SampleOrder.hpp"

#include <algorithm>
#include <cstdint>

namespace wallpaper::media
{

std::size_t ReorderDepth(const std::vector<Sample>& samples)
{
    const std::size_t count = samples.size();
    if (count < 2) return 0;

    // Rank each presentation time among the distinct ones, then count, for each
    // sample in decode order, the earlier samples with a larger rank (a Fenwick
    // tree over ranks keeps that O(n log n) for a four-million-sample table).
    std::vector<std::int64_t> times(count);
    for (std::size_t index = 0; index < count; ++index) times[index] = samples[index].pts;
    std::sort(times.begin(), times.end());
    times.erase(std::unique(times.begin(), times.end()), times.end());

    std::vector<std::uint32_t> tree(times.size() + 1, 0);
    std::size_t depth = 0;
    for (std::size_t index = 0; index < count; ++index) {
        const std::size_t rank = static_cast<std::size_t>(
            std::lower_bound(times.begin(), times.end(), samples[index].pts) - times.begin()) + 1;
        // Samples seen so far whose rank is at most `rank`.
        std::size_t notLater = 0;
        for (std::size_t at = rank; at > 0; at -= at & (~at + 1)) notLater += tree[at];
        depth = std::max(depth, index - notLater);
        for (std::size_t at = rank; at < tree.size(); at += at & (~at + 1)) ++tree[at];
    }
    return depth;
}

} // namespace wallpaper::media
