// A reader for the first video track of an MP4 / QuickTime file (ISO/IEC
// 14496-12 boxes, with the codec configuration records of 14496-15 and the AV1
// and VP9 bindings). It parses the `moov` sample tables into a flat sample table
// and stream description; it never decodes and never reads sample payloads
// except through readSample().
//
// Scope for this version: a progressive file with one `moov` (the `mdat` may
// come before or after it), `stsd` entries avc1/avc3/hvc1/hev1/av01/vp09 with
// their configuration records, any other video entry reported by type only, and
// an edit list of at most one leading empty edit and one normal segment.
// Fragmented files (`moof`/`mvex`), several media segments in an edit list and a
// non-unit edit rate are refused with an `Unsupported` error that says why.
//
// Every size read from the file is checked against the file, the enclosing box
// and the limits below before anything is allocated or indexed.
#pragma once

#include "Media/ByteSource.hpp"
#include "Media/Error.hpp"
#include "Media/KeyframeIndex.hpp"
#include "Media/VideoTypes.hpp"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace wallpaper::media
{

struct IsoBmffLimits {
    /// The largest `moov` box this reader will hold in memory.
    std::uint64_t maxMoovBytes { 128ULL << 20 };
    /// The most samples in the track; a file with more is refused, not truncated.
    std::uint32_t maxSamples { 4000000 };
    /// Top-level boxes scanned before giving up.
    std::uint32_t maxTopLevelBoxes { 100000 };
    /// `trak` boxes examined.
    std::uint32_t maxTracks { 256 };
    /// Edit-list entries read.
    std::uint32_t maxEdits { 4096 };
    /// Largest codec configuration record accepted.
    std::uint32_t maxConfigBytes { 1U << 20 };
    /// Largest single sample readSample() will return.
    std::uint32_t maxSampleBytes { 256U << 20 };
};

/// True when the first box of `source` looks like the start of an ISO-BMFF file
/// (a plausible size and a box type such readers expect first). A cheap sniff:
/// open() makes the real decision.
bool LooksLikeIsoBmff(const ByteSource& source);

class IsoBmffReader {
public:
    /// Parses `source` and returns the reader, or null with `error` filled.
    static std::unique_ptr<IsoBmffReader> Open(std::shared_ptr<ByteSource> source, Error* error,
                                               const IsoBmffLimits& limits = {});

    const VideoStreamInfo&     info() const { return m_info; }
    /// Decode order; never empty after a successful open.
    const std::vector<Sample>& samples() const { return m_samples; }
    /// The `ftyp` major brand ('isom', 'qt  ' ...), or 0 when the file has none.
    std::uint32_t              majorBrand() const { return m_majorBrand; }
    /// Oddities the reader tolerated (a table shorter than another, a file cut
    /// inside the sample data). Empty for a clean file.
    const std::vector<std::string>& warnings() const { return m_warnings; }

    /// The index of the last sync sample whose presentation time is at or before
    /// `pts` (ticks), the place to start decoding to show that time. A time
    /// before every sync sample gives the first one. Binary search over the sync
    /// samples; nullopt only when there is no sync sample at all.
    std::optional<std::size_t> findKeyframeAtOrBefore(std::int64_t pts) const;

    /// Reads sample `index`'s compressed bytes into `*out`.
    bool readSample(std::size_t index, std::vector<std::uint8_t>* out, Error* error) const;

    const std::shared_ptr<ByteSource>& source() const { return m_source; }

private:
    IsoBmffReader() = default;

    std::shared_ptr<ByteSource> m_source;
    IsoBmffLimits               m_limits;
    VideoStreamInfo             m_info;
    std::vector<Sample>         m_samples;
    KeyframeIndex               m_keyframes;
    std::uint32_t               m_majorBrand { 0 };
    std::vector<std::string>    m_warnings;

    friend class IsoBmffParser;
};

} // namespace wallpaper::media
