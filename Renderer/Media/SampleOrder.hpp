// How far a stream's decode order is from its display order, measured on the
// sample table a reader produced, so a decoder that outputs in decode order can
// put its frames in display order with a buffer of exactly the right size.
#pragma once

#include "Media/VideoTypes.hpp"

#include <cstddef>
#include <vector>

namespace wallpaper::media
{

/// The most samples decoded before one that are shown after it: the lateness of
/// the latest-decoded picture of any sample, 0 for a stream whose decode order is
/// its display order. Holding `ReorderDepth + 1` decoded frames and releasing the
/// earliest-shown whenever that many are held (and everything at the end) emits
/// them in display order, however the file was encoded. Samples with equal
/// presentation times do not count against each other.
std::size_t ReorderDepth(const std::vector<Sample>& samples);

} // namespace wallpaper::media
