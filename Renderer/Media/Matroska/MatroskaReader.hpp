// A reader for Matroska and WebM files (the Matroska element specification and
// RFC 8794 EBML), written for one job: locate every compressed video and audio
// frame and describe the video track so a decoder front end can play it. It
// never decodes, and reads frame payloads only through readSample()/readPacket().
//
// Open() makes one sequential pass over the Segment, reading only element
// headers and block headers (payloads are skipped by size) and builds an index
// of every frame of every video and audio track: where it is, how big, when it
// is shown, whether it is a key frame. Cues are ignored on purpose: the index
// gives exact durations and frame periods, keyframe seeking without Cues, and
// works for files whose Cues are missing, wrong or after the media.
//
// Supported: EBML header and DocType checks; Segment and Cluster of unknown size;
// SimpleBlock and BlockGroup (Block, BlockDuration, ReferenceBlock,
// DiscardPadding); Xiph, EBML and fixed-size lacing; header-stripping content
// encoding. Refused as Unsupported: encrypted tracks, other content
// compression, and any codec this project does not play (VP8 and unknown ids).
// BlockAdditions (VP9 alpha) are ignored, so such a file plays opaque. Tracks
// must precede the first Cluster.
//
// Every size read from the file is checked against its parent element and the
// file, and every allocation is bounded by MatroskaLimits.
#pragma once

#include "Media/ByteSource.hpp"
#include "Media/Error.hpp"
#include "Media/KeyframeIndex.hpp"
#include "Media/Matroska/Vp9Header.hpp"
#include "Media/VideoTypes.hpp"

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace wallpaper::media
{

struct MatroskaLimits {
    /// Bytes of header data (EBML header, Info, Tracks, lace tables) read in total.
    std::uint64_t maxMetadataBytes { 16ULL << 20 };
    std::uint32_t maxTracks { 64 };
    std::uint32_t maxCodecPrivateBytes { 1U << 20 };
    /// Frames in one laced block.
    std::uint32_t maxLaceFrames { 256 };
    /// The largest frame, and the largest block header the reader will parse.
    std::uint64_t maxBlockBytes { 64ULL << 20 };
    /// Frames indexed across all tracks; a file with more is refused, not cut.
    std::uint64_t maxPackets { 4000000 };
    /// How long the indexing pass may run before the file is refused as too complex.
    std::chrono::milliseconds maxScanTime { 60000 };
    /// Largest frame readSample()/readPacket() will return.
    std::uint32_t maxReadBytes { 256U << 20 };
};

struct MatroskaOptions {
    MatroskaLimits limits;
    /// False reads the headers only (EBML header, Info, Tracks) and stops at the
    /// first Cluster, for probing a file's tracks without indexing it.
    bool           buildIndex { true };
};

enum class MatroskaTrackType : std::uint8_t { Other, Video, Audio };

enum class MatroskaCodec : std::uint8_t {
    Unknown,
    Vp9,
    Av1,
    H264,
    Hevc,
    Vp8,
    Opus,
    Vorbis,
    Aac,
    Mp3,
};

struct MatroskaTrack {
    std::uint32_t     number { 0 };
    std::uint64_t     uid { 0 };
    MatroskaTrackType type { MatroskaTrackType::Other };
    /// The raw Matroska track type (1 video, 2 audio, 17 subtitle ...).
    std::uint8_t      rawType { 0 };
    std::string       codecId;
    MatroskaCodec     codec { MatroskaCodec::Unknown };
    /// True when this project plays the codec and encoding; otherwise `unsupportedReason` says why.
    bool              supported { false };
    std::string       unsupportedReason;
    bool              enabled { true };
    bool              lacing { true };
    /// CodecPrivate verbatim: avcC / hvcC / av1C for video, OpusHead, the three Vorbis
    /// headers or an AudioSpecificConfig for audio; empty when absent.
    std::vector<std::uint8_t> codecPrivate;
    std::int64_t      defaultDurationNs { 0 };
    std::int64_t      codecDelayNs { 0 };
    std::int64_t      seekPreRollNs { 0 };
    /// Bytes a header-stripping content encoding removed from the front of every
    /// frame; readSample()/readPacket() put them back.
    std::vector<std::uint8_t> headerStrip;

    // Video
    std::uint32_t     pixelWidth { 0 };
    std::uint32_t     pixelHeight { 0 };
    std::uint32_t     displayWidth { 0 };
    std::uint32_t     displayHeight { 0 };
    /// DisplayUnit: 0 pixels, 1 centimetres, 2 inches, 3 display aspect ratio.
    std::uint64_t     displayUnit { 0 };
    /// Colour.BitsPerChannel; 0 when not stated.
    std::uint8_t      bitsPerChannel { 0 };
    ColourDescription colour;
    /// From a rectangular Projection's pose roll when it is a whole number of quarter turns.
    DisplayMatrix     displayMatrix { kIdentityDisplayMatrix };
    // Audio
    double            samplingFrequency { 0 };
    std::uint32_t     channels { 0 };
    std::uint32_t     bitDepth { 0 };
};

struct MatroskaInfo {
    std::string   docType;
    /// Nanoseconds per timestamp tick (Info.TimecodeScale, default 1,000,000).
    std::uint64_t timecodeScale { 1000000 };
    /// Info.Duration in nanoseconds; 0 when absent. Many files get it wrong, so the
    /// index, not this, decides how long the video plays.
    std::int64_t  infoDurationNs { 0 };
};

/// One frame of a video or audio track (a laced block yields several).
struct MatroskaPacket {
    std::uint64_t offset { 0 };
    std::int64_t  ptsNs { 0 };
    /// From BlockDuration, else the track's DefaultDuration; 0 when neither is known.
    std::int64_t  durationNs { 0 };
    std::uint32_t size { 0 };
    /// DiscardPadding in nanoseconds, clamped to 32 bits (Opus end trimming).
    std::int32_t  discardPaddingNs { 0 };
    bool          keyframe { false };
    /// The block's invisible flag: decode it but do not show it.
    bool          invisible { false };
};

class MatroskaReader {
public:
    static std::unique_ptr<MatroskaReader> Open(std::shared_ptr<ByteSource> source, Error* error,
                                                const MatroskaOptions& options = {});

    const MatroskaInfo&               info() const { return m_info; }
    /// Every track, in file order.
    const std::vector<MatroskaTrack>& tracks() const { return m_tracks; }
    /// Index into tracks() of the video track played: the first enabled one whose
    /// codec is supported. Open() fails when there is none.
    std::size_t                       videoTrackIndex() const { return m_videoTrack; }
    const MatroskaTrack&              videoTrack() const { return m_tracks[m_videoTrack]; }
    const VideoStreamInfo&            videoInfo() const { return m_videoInfo; }
    /// Video frames in decode (file) order with times in nanoseconds. `pts` is the
    /// presentation time; `dts` is derived (Matroska stores only presentation
    /// time): the sorted presentation times shifted by the smallest amount that
    /// keeps every dts at or before its pts, so streams without reordering have
    /// dts == pts. Empty after a headers-only open.
    const std::vector<Sample>&        videoSamples() const { return m_videoSamples; }
    /// The packets of any indexed track (video or audio), in file order.
    const std::vector<MatroskaPacket>& packets(std::size_t trackIndex) const { return m_packets[trackIndex]; }
    /// The profile, bit depth, colour space and size read from the first video key
    /// frame, for VP9 tracks (WebM has no `vpcC`); empty for other codecs.
    const std::optional<Vp9FrameHeader>& vp9KeyFrame() const { return m_vp9; }
    /// Oddities tolerated: a cut file, a block for an unknown track, a corrupt
    /// tail after the last usable key frame.
    const std::vector<std::string>&   warnings() const { return m_warnings; }

    /// The index in videoSamples() of the last key frame shown at or before `ptsNs`
    /// (the first key frame for an earlier time); nullopt when there are no samples.
    std::optional<std::size_t> findVideoKeyframeAtOrBefore(std::int64_t ptsNs) const;

    /// A video frame's bytes (with any stripped header restored).
    bool readSample(std::size_t index, std::vector<std::uint8_t>* out, Error* error) const;
    /// A packet of any indexed track (with any stripped header restored).
    bool readPacket(std::size_t trackIndex, std::size_t packetIndex, std::vector<std::uint8_t>* out,
                    Error* error) const;

    const std::shared_ptr<ByteSource>& source() const { return m_source; }

private:
    MatroskaReader() = default;

    std::shared_ptr<ByteSource>                 m_source;
    MatroskaOptions                             m_options;
    MatroskaInfo                                m_info;
    std::vector<MatroskaTrack>                  m_tracks;
    std::size_t                                 m_videoTrack { 0 };
    VideoStreamInfo                             m_videoInfo;
    std::vector<std::vector<MatroskaPacket>>    m_packets;
    std::vector<Sample>                         m_videoSamples;
    KeyframeIndex                               m_keyframes;
    std::optional<Vp9FrameHeader>               m_vp9;
    std::vector<std::string>                    m_warnings;

    friend class MatroskaParser;
};

} // namespace wallpaper::media
