// Test-only Matroska/WebM writer: builds small files in memory from a
// description, so the reader's tests state what they expect in the test itself.
// It writes the elements the reader reads (and a few it must skip), with
// control over the things real files vary in: SimpleBlock or BlockGroup, lacing,
// unknown-size Segment and Clusters, Cues present, absent or first.
#pragma once

#include "mp4_builder.hpp"  // Bytes, Put*, Append and the codec config helpers

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <optional>
#include <string>
#include <vector>

namespace wallpaper::media::testing
{

inline Bytes IdBytes(std::uint32_t id)
{
    Bytes out;
    bool  started = false;
    for (int shift = 24; shift >= 0; shift -= 8) {
        const std::uint8_t byte = static_cast<std::uint8_t>(id >> shift);
        if (byte != 0 || started) out.push_back(byte);
        started = started || byte != 0;
    }
    return out;
}

/// An EBML size/vint of the shortest length that fits (or exactly `length` bytes).
inline Bytes Vint(std::uint64_t value, int length = 0)
{
    if (length == 0) {
        length = 1;
        while (length < 8 && value >= (std::uint64_t { 1 } << (7 * length)) - 1) ++length;
    }
    Bytes out(static_cast<std::size_t>(length));
    std::uint64_t marked = value | (std::uint64_t { 1 } << (7 * length));
    for (int index = length - 1; index >= 0; --index) {
        out[static_cast<std::size_t>(index)] = static_cast<std::uint8_t>(marked);
        marked >>= 8;
    }
    return out;
}

inline Bytes UnknownSize(int length = 1)
{
    Bytes out(static_cast<std::size_t>(length), 0xFF);
    out[0] = static_cast<std::uint8_t>(0xFFU >> (length - 1));
    return out;
}

inline Bytes SignedVint(std::int64_t value)
{
    for (int length = 1; length <= 8; ++length) {
        const std::int64_t bias = (std::int64_t { 1 } << (7 * length - 1)) - 1;
        const std::int64_t raw  = value + bias;
        if (raw >= 0 && raw < (std::int64_t { 1 } << (7 * length)) - 1) return Vint(static_cast<std::uint64_t>(raw), length);
    }
    return {};
}

inline Bytes Element(std::uint32_t id, const Bytes& payload, int sizeLength = 0)
{
    Bytes out = IdBytes(id);
    Append(out, Vint(payload.size(), sizeLength));
    Append(out, payload);
    return out;
}

inline Bytes UintElement(std::uint32_t id, std::uint64_t value)
{
    Bytes payload;
    int   length = 1;
    while (length < 8 && (value >> (8 * length)) != 0) ++length;
    for (int index = length - 1; index >= 0; --index) payload.push_back(static_cast<std::uint8_t>(value >> (8 * index)));
    return Element(id, payload);
}

inline Bytes IntElement(std::uint32_t id, std::int64_t value)
{
    Bytes payload;
    for (int index = 7; index >= 0; --index) payload.push_back(static_cast<std::uint8_t>(static_cast<std::uint64_t>(value) >> (8 * index)));
    return Element(id, payload);
}

inline Bytes FloatElement(std::uint32_t id, double value, bool wide = true)
{
    Bytes payload;
    if (wide) {
        std::uint64_t bits;
        std::memcpy(&bits, &value, sizeof(bits));
        Put64(payload, bits);
    } else {
        const float   single = static_cast<float>(value);
        std::uint32_t bits;
        std::memcpy(&bits, &single, sizeof(bits));
        Put32(payload, bits);
    }
    return Element(id, payload);
}

inline Bytes StringElement(std::uint32_t id, const std::string& text) { return Element(id, Bytes(text.begin(), text.end())); }

enum class Lacing { None, Xiph, Ebml, Fixed };

struct FrameRecord {
    std::uint32_t track { 0 };
    std::uint64_t offset { 0 };
    Bytes         data;
    std::int64_t  ticks { 0 };  // the block's absolute time in TimecodeScale ticks
    bool          key { false };
};

struct Part {
    Bytes                    bytes;
    std::vector<FrameRecord> frames;  // offsets relative to the start of `bytes`
};

inline Part Join(std::vector<Part> parts)
{
    Part out;
    for (Part& part : parts) {
        for (FrameRecord frame : part.frames) {
            frame.offset += out.bytes.size();
            out.frames.push_back(std::move(frame));
        }
        Append(out.bytes, part.bytes);
    }
    return out;
}

inline Part Plain(const Bytes& bytes) { return Part { bytes, {} }; }

/// An element around a Part; `unknownSize` writes the all-ones size.
inline Part Wrap(std::uint32_t id, const Part& inner, bool unknownSize = false)
{
    Part out;
    out.bytes = IdBytes(id);
    Append(out.bytes, unknownSize ? UnknownSize(1) : Vint(inner.bytes.size()));
    const std::size_t header = out.bytes.size();
    Append(out.bytes, inner.bytes);
    for (FrameRecord frame : inner.frames) {
        frame.offset += header;
        out.frames.push_back(std::move(frame));
    }
    return out;
}

struct BlockSpec {
    std::uint32_t      track { 1 };
    std::int64_t       time { 0 };  // absolute, in TimecodeScale ticks
    bool               key { true };
    bool               group { false };
    std::optional<std::int64_t> duration;  // ticks, BlockGroup only
    bool               reference { false };  // BlockGroup: add a ReferenceBlock
    std::vector<Bytes> frames;
    Lacing             lacing { Lacing::None };
    std::int64_t       discardPaddingNs { 0 };
    bool               invisible { false };
    /// BlockGroup: add a BlockAdditions element (the way VP9 alpha is carried).
    bool               additions { false };
    /// Bytes written after the block header in place of the lace table and frames (no frame is recorded).
    std::optional<Bytes> rawPayload;
};

struct ClusterSpec {
    std::int64_t           timecode { 0 };
    std::vector<BlockSpec> blocks;
    bool                   unknownSize { false };
    bool                   omitTimecode { false };
};

struct TrackSpec {
    std::uint32_t number { 1 };
    std::uint32_t type { 1 };
    std::string   codecId { "V_VP9" };
    Bytes         codecPrivate;
    bool          enabled { true };
    bool          lacing { true };
    std::int64_t  defaultDurationNs { 0 };
    // video
    std::uint32_t width { 64 };
    std::uint32_t height { 48 };
    std::uint32_t displayWidth { 0 };
    std::uint32_t displayHeight { 0 };
    std::optional<std::uint32_t> displayUnit;
    Bytes         colour;  // the payload of a Colour element, if any
    std::optional<double> poseRoll;
    // audio
    std::uint32_t channels { 2 };
    double        sampleRate { 48000 };
    std::uint32_t bitDepth { 0 };
    std::int64_t  codecDelayNs { 0 };
    std::int64_t  seekPreRollNs { 0 };
    // content encoding
    Bytes         headerStrip;
    bool          encrypted { false };
    std::optional<std::uint32_t> compressionAlgo;
};

struct MkvSpec {
    std::string              docType { "webm" };
    std::optional<std::uint32_t> docReadVersion;
    std::optional<std::uint32_t> maxIdLength;
    std::optional<std::uint32_t> maxSizeLength;
    std::optional<std::uint64_t> timecodeScale;
    std::optional<double>    infoDuration;  // ticks
    std::vector<TrackSpec>   tracks;
    std::vector<ClusterSpec> clusters;
    bool                     segmentUnknownSize { false };
    bool                     writeCues { false };
    bool                     cuesFirst { false };
    bool                     voidBefore { false };
    bool                     tagsAfter { false };
    bool                     tracksAfterClusters { false };
    bool                     writeSeekHead { false };
};

struct BuiltMkv {
    Bytes                    bytes;
    std::vector<FrameRecord> frames;
};

inline Bytes TrackEntry(const TrackSpec& track)
{
    Bytes body;
    Append(body, UintElement(0xD7, track.number));
    Append(body, UintElement(0x73C5, 1000 + track.number));
    Append(body, UintElement(0x83, track.type));
    if (! track.enabled) Append(body, UintElement(0xB9, 0));
    if (! track.lacing) Append(body, UintElement(0x9C, 0));
    if (track.defaultDurationNs > 0) Append(body, UintElement(0x23E383, static_cast<std::uint64_t>(track.defaultDurationNs)));
    Append(body, StringElement(0x86, track.codecId));
    if (! track.codecPrivate.empty()) Append(body, Element(0x63A2, track.codecPrivate));
    if (track.codecDelayNs != 0) Append(body, UintElement(0x56AA, static_cast<std::uint64_t>(track.codecDelayNs)));
    if (track.seekPreRollNs != 0) Append(body, UintElement(0x56BB, static_cast<std::uint64_t>(track.seekPreRollNs)));
    if (track.type == 1) {
        Bytes video;
        Append(video, UintElement(0xB0, track.width));
        Append(video, UintElement(0xBA, track.height));
        if (track.displayWidth != 0) Append(video, UintElement(0x54B0, track.displayWidth));
        if (track.displayHeight != 0) Append(video, UintElement(0x54BA, track.displayHeight));
        if (track.displayUnit) Append(video, UintElement(0x54B2, *track.displayUnit));
        if (! track.colour.empty()) Append(video, Element(0x55B0, track.colour));
        if (track.poseRoll) {
            Bytes projection;
            Append(projection, UintElement(0x7671, 0));
            Append(projection, FloatElement(0x7675, *track.poseRoll, false));
            Append(video, Element(0x7670, projection));
        }
        Append(body, Element(0xE0, video));
    } else if (track.type == 2) {
        Bytes audio;
        Append(audio, FloatElement(0xB5, track.sampleRate));
        Append(audio, UintElement(0x9F, track.channels));
        if (track.bitDepth != 0) Append(audio, UintElement(0x6264, track.bitDepth));
        Append(body, Element(0xE1, audio));
    }
    if (! track.headerStrip.empty() || track.encrypted || track.compressionAlgo) {
        Bytes encoding;
        if (track.encrypted) {
            Append(encoding, UintElement(0x5033, 1));
            Append(encoding, Element(0x5035, UintElement(0x47E1, 5)));
        } else {
            Bytes compression;
            Append(compression, UintElement(0x4254, track.compressionAlgo.value_or(3)));
            if (! track.headerStrip.empty()) Append(compression, Element(0x4255, track.headerStrip));
            Append(encoding, Element(0x5034, compression));
        }
        Append(body, Element(0x6D80, Element(0x6240, encoding)));
    }
    return Element(0xAE, body);
}

inline Part BlockPart(const BlockSpec& block, std::int64_t clusterTimecode)
{
    Bytes payload = Vint(block.track, 1);
    const std::int64_t relative = block.time - clusterTimecode;
    Put16(payload, static_cast<std::uint32_t>(static_cast<std::uint16_t>(relative)));
    std::uint8_t flags = 0;
    if (! block.group && block.key) flags |= 0x80;
    if (block.invisible) flags |= 0x08;
    if (block.lacing == Lacing::Xiph) flags |= 0x02;
    if (block.lacing == Lacing::Fixed) flags |= 0x04;
    if (block.lacing == Lacing::Ebml) flags |= 0x06;
    Put8(payload, flags);

    std::vector<std::pair<std::size_t, Bytes>> placed;
    if (block.rawPayload) {
        Append(payload, *block.rawPayload);
    } else if (block.lacing != Lacing::None) {
        Put8(payload, static_cast<std::uint32_t>(block.frames.size() - 1));
        if (block.lacing == Lacing::Xiph) {
            for (std::size_t index = 0; index + 1 < block.frames.size(); ++index) {
                std::size_t size = block.frames[index].size();
                while (size >= 255) {
                    Put8(payload, 255);
                    size -= 255;
                }
                Put8(payload, static_cast<std::uint32_t>(size));
            }
        } else if (block.lacing == Lacing::Ebml) {
            Append(payload, Vint(block.frames[0].size()));
            for (std::size_t index = 1; index + 1 < block.frames.size(); ++index) {
                Append(payload, SignedVint(static_cast<std::int64_t>(block.frames[index].size()) - static_cast<std::int64_t>(block.frames[index - 1].size())));
            }
        }
    }
    std::uint64_t at = payload.size();
    if (! block.rawPayload) {
        for (const Bytes& frame : block.frames) {
            placed.emplace_back(at, frame);
            Append(payload, frame);
            at += frame.size();
        }
    }
    Part blockElement;
    blockElement.bytes = Element(block.group ? 0xA1 : 0xA3, payload);
    const std::size_t header = blockElement.bytes.size() - payload.size();
    for (const auto& frame : placed) {
        blockElement.frames.push_back({ block.track, header + frame.first, frame.second, block.time, block.key });
    }
    if (! block.group) return blockElement;

    Bytes group;
    Append(group, blockElement.bytes);
    if (block.duration) Append(group, UintElement(0x9B, static_cast<std::uint64_t>(*block.duration)));
    if (block.reference) Append(group, IntElement(0xFB, -1));
    if (block.additions) Append(group, Element(0x75A1, Element(0xA6, Cat(UintElement(0xEE, 1), Element(0xA5, Bytes(17, 0x5A))))));
    if (block.discardPaddingNs != 0) Append(group, IntElement(0x75A2, block.discardPaddingNs));
    Part out;
    out.bytes = Element(0xA0, group);
    const std::size_t groupHeader = out.bytes.size() - group.size();
    for (FrameRecord frame : blockElement.frames) {
        frame.offset += groupHeader;
        out.frames.push_back(std::move(frame));
    }
    return out;
}

inline Part ClusterPart(const ClusterSpec& cluster)
{
    std::vector<Part> parts;
    if (! cluster.omitTimecode) parts.push_back(Plain(UintElement(0xE7, static_cast<std::uint64_t>(cluster.timecode))));
    for (const BlockSpec& block : cluster.blocks) parts.push_back(BlockPart(block, cluster.timecode));
    return Wrap(0x1F43B675, Join(std::move(parts)), cluster.unknownSize);
}

inline BuiltMkv BuildMkv(const MkvSpec& spec)
{
    Bytes ebml;
    Append(ebml, UintElement(0x4286, 1));
    Append(ebml, UintElement(0x42F7, 1));
    Append(ebml, UintElement(0x42F2, spec.maxIdLength.value_or(4)));
    Append(ebml, UintElement(0x42F3, spec.maxSizeLength.value_or(8)));
    Append(ebml, StringElement(0x4282, spec.docType));
    Append(ebml, UintElement(0x4287, 4));
    Append(ebml, UintElement(0x4285, spec.docReadVersion.value_or(2)));

    Bytes info;
    if (spec.timecodeScale) Append(info, UintElement(0x2AD7B1, *spec.timecodeScale));
    Append(info, StringElement(0x4D80, "mkv_builder"));
    if (spec.infoDuration) Append(info, FloatElement(0x4489, *spec.infoDuration, false));

    Bytes tracks;
    for (const TrackSpec& track : spec.tracks) Append(tracks, TrackEntry(track));

    std::vector<Part> segment;
    if (spec.writeSeekHead) segment.push_back(Plain(Element(0x114D9B74, Element(0x4DBB, Bytes(12, 0)))));
    if (spec.voidBefore) segment.push_back(Plain(Element(0xEC, Bytes(23, 0))));
    segment.push_back(Plain(Element(0x1549A966, info)));
    if (! spec.tracksAfterClusters) segment.push_back(Plain(Element(0x1654AE6B, tracks)));
    const Bytes cues = Element(0x1C53BB6B, Element(0xBB, Cat(UintElement(0xB3, 0), Element(0xB7, Cat(UintElement(0xF7, 1), UintElement(0xF1, 0))))));
    if (spec.writeCues && spec.cuesFirst) segment.push_back(Plain(cues));
    for (const ClusterSpec& cluster : spec.clusters) segment.push_back(ClusterPart(cluster));
    if (spec.tracksAfterClusters) segment.push_back(Plain(Element(0x1654AE6B, tracks)));
    if (spec.writeCues && ! spec.cuesFirst) segment.push_back(Plain(cues));
    if (spec.tagsAfter) segment.push_back(Plain(Element(0x1254C367, Element(0x7373, Bytes(8, 0)))));

    const Part wrapped = Wrap(0x18538067, Join(std::move(segment)), spec.segmentUnknownSize);
    BuiltMkv built;
    built.bytes = Element(0x1A45DFA3, ebml);
    const std::size_t base = built.bytes.size();
    Append(built.bytes, wrapped.bytes);
    for (FrameRecord frame : wrapped.frames) {
        frame.offset += base;
        built.frames.push_back(std::move(frame));
    }
    return built;
}

/// The offset of the first occurrence of `pattern` in `bytes`, or `bytes.size()`.
inline std::size_t FindBytes(const Bytes& bytes, const Bytes& pattern)
{
    const auto at = std::search(bytes.begin(), bytes.end(), pattern.begin(), pattern.end());
    return static_cast<std::size_t>(at - bytes.begin());
}

/// A deterministic frame body, `size` bytes, distinct per (`track`, `index`).
inline Bytes FrameBytes(std::uint32_t track, std::size_t index, std::size_t size)
{
    Bytes out(size);
    for (std::size_t at = 0; at < size; ++at) out[at] = static_cast<std::uint8_t>(track * 31 + index * 7 + at);
    return out;
}

} // namespace wallpaper::media::testing
