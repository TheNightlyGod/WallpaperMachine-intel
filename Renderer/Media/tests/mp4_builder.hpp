// Test-only ISO-BMFF writer: assembles small, valid (or deliberately broken) MP4
// files in memory from a description, so the reader's tests state what they
// expect in the test itself instead of depending on binary fixtures. It writes
// the boxes the reader reads and a few it must skip, nothing more.
#pragma once

#include "Media/DisplayMatrix.hpp"

#include <array>
#include <cstdint>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace wallpaper::media::testing
{

using Bytes = std::vector<std::uint8_t>;

inline void Put8(Bytes& out, std::uint32_t value) { out.push_back(static_cast<std::uint8_t>(value)); }
inline void Put16(Bytes& out, std::uint32_t value) { Put8(out, value >> 8); Put8(out, value); }
inline void Put24(Bytes& out, std::uint32_t value) { Put8(out, value >> 16); Put16(out, value); }
inline void Put32(Bytes& out, std::uint32_t value) { Put16(out, value >> 16); Put16(out, value); }
inline void Put64(Bytes& out, std::uint64_t value)
{
    Put32(out, static_cast<std::uint32_t>(value >> 32));
    Put32(out, static_cast<std::uint32_t>(value));
}
inline void PutType(Bytes& out, const std::string& type)
{
    for (std::size_t index = 0; index < 4; ++index) out.push_back(static_cast<std::uint8_t>(type[index]));
}
inline void Append(Bytes& out, const Bytes& more) { out.insert(out.end(), more.begin(), more.end()); }

inline Bytes Box(const std::string& type, const Bytes& payload)
{
    Bytes out;
    Put32(out, static_cast<std::uint32_t>(payload.size() + 8));
    PutType(out, type);
    Append(out, payload);
    return out;
}

/// A box that uses the 64-bit size form.
inline Bytes LargeBox(const std::string& type, const Bytes& payload)
{
    Bytes out;
    Put32(out, 1);
    PutType(out, type);
    Put64(out, payload.size() + 16);
    Append(out, payload);
    return out;
}

inline Bytes FullBox(const std::string& type, std::uint32_t version, std::uint32_t flags, const Bytes& payload)
{
    Bytes body;
    Put32(body, (version << 24) | flags);
    Append(body, payload);
    return Box(type, body);
}

template<typename... Parts>
Bytes Cat(const Parts&... parts)
{
    Bytes out;
    (Append(out, parts), ...);
    return out;
}

// Configuration records (14496-15, the AV1 and VP9 bindings) with plausible fields.
inline Bytes AvcC(std::uint32_t profile, std::uint32_t bitDepth)
{
    Bytes out;
    Put8(out, 1);
    Put8(out, profile);
    Put8(out, 0);
    Put8(out, 31);
    Put8(out, 0xFF);
    Put8(out, 0xE1);
    Put16(out, 2);
    Put8(out, 0x67);
    Put8(out, 0x64);
    Put8(out, 1);
    Put16(out, 2);
    Put8(out, 0x68);
    Put8(out, 0xEE);
    if (profile == 100 || profile == 110 || profile == 122 || profile == 244) {
        Put8(out, 0xFC | 1);
        Put8(out, 0xF8 | (bitDepth - 8));
        Put8(out, 0xF8 | (bitDepth - 8));
        Put8(out, 0);
    }
    return out;
}

inline Bytes HvcC(std::uint32_t bitDepth)
{
    Bytes out(23, 0);
    out[0]  = 1;
    out[1]  = 0x01;
    out[12] = 93;
    out[16] = 0xFC | 1;
    out[17] = static_cast<std::uint8_t>(0xF8 | (bitDepth - 8));
    out[18] = static_cast<std::uint8_t>(0xF8 | (bitDepth - 8));
    out[21] = 0x03;
    return out;
}

inline Bytes Av1C(std::uint32_t bitDepth)
{
    Bytes out;
    Put8(out, 0x81);
    Put8(out, 0x00);
    Put8(out, (bitDepth > 8 ? 0x40U : 0U) | (bitDepth == 12 ? 0x20U : 0U) | 0x0CU);
    Put8(out, 0x00);
    return out;
}

inline Bytes VpcC(std::uint32_t bitDepth, bool fullRange, std::uint32_t primaries, std::uint32_t transfer,
                  std::uint32_t matrix)
{
    Bytes out;
    Put32(out, 1U << 24);
    Put8(out, 2);
    Put8(out, 41);
    Put8(out, (bitDepth << 4) | (1U << 1) | (fullRange ? 1U : 0U));
    Put8(out, primaries);
    Put8(out, transfer);
    Put8(out, matrix);
    Put16(out, 0);
    return out;
}

inline Bytes ColrNclx(std::uint32_t primaries, std::uint32_t transfer, std::uint32_t matrix, bool fullRange)
{
    Bytes out;
    PutType(out, "nclx");
    Put16(out, primaries);
    Put16(out, transfer);
    Put16(out, matrix);
    Put8(out, fullRange ? 0x80U : 0U);
    return Box("colr", out);
}

inline Bytes ColrNclc(std::uint32_t primaries, std::uint32_t transfer, std::uint32_t matrix)
{
    Bytes out;
    PutType(out, "nclc");
    Put16(out, primaries);
    Put16(out, transfer);
    Put16(out, matrix);
    return Box("colr", out);
}

inline Bytes Pasp(std::uint32_t horizontal, std::uint32_t vertical)
{
    Bytes out;
    Put32(out, horizontal);
    Put32(out, vertical);
    return Box("pasp", out);
}

struct SampleSpec {
    std::uint32_t size { 10 };
    std::uint32_t delta { 40 };
    std::int32_t  cts { 0 };
    bool          sync { true };
};

struct EditSpec {
    std::int64_t duration { 0 };   // movie timescale
    std::int64_t mediaTime { 0 };  // media timescale, -1 for an empty edit
    std::int16_t rateInteger { 1 };
    std::int16_t rateFraction { 0 };
};

struct Mp4Spec {
    std::string   entry { "avc1" };
    std::uint32_t width { 640 };
    std::uint32_t height { 360 };
    /// Payload of the configuration box; chosen per `entry` when empty.
    Bytes         config;
    /// Name of the configuration box; chosen per `entry` when empty ("" = none for unknown entries).
    std::string   configType;
    bool          omitConfig { false };
    /// Boxes appended inside the sample entry after the configuration record.
    std::vector<Bytes> entryChildren;
    Bytes         entryTrailer;

    std::uint32_t mediaTimescale { 1000 };
    std::uint32_t movieTimescale { 1000 };
    std::vector<SampleSpec> samples;
    /// Samples per chunk, repeated cyclically; empty means one chunk per sample.
    std::vector<std::uint32_t> chunking;

    bool          writeStss { true };
    bool          writeCtts { false };
    std::uint32_t cttsVersion { 0 };
    /// 0 writes stsz with per-sample sizes, 4/8/16 writes stz2, 1 writes stsz with one constant size.
    std::uint32_t sizeTable { 0 };
    bool          co64 { false };

    std::optional<std::vector<EditSpec>> edits;
    std::uint32_t elstVersion { 0 };

    DisplayMatrix matrix { kIdentityDisplayMatrix };
    std::uint32_t tkhdVersion { 0 };
    std::uint32_t tkhdWidth16 { 0 };   // 16.16; 0 writes width << 16
    std::uint32_t tkhdHeight16 { 0 };
    bool          trackEnabled { true };
    std::uint32_t trackId { 1 };

    /// Overrides what mdhd and mvhd say about the duration (otherwise the sum of the deltas).
    std::optional<std::uint64_t> mediaDuration;

    bool          moovFirst { true };
    bool          largeMdat { false };
    bool          mdatToEndOfFile { false };
    bool          freeBox { false };
    bool          mvex { false };
    bool          moofAfter { false };
    bool          audioTrackFirst { false };
    bool          noVideoTrack { false };
    bool          extraDisabledVideoFirst { false };
    std::string   ftypBrand { "isom" };
    bool          writeFtyp { true };
};

struct BuiltMp4 {
    Bytes                        bytes;
    std::vector<std::uint64_t>   offsets;
    std::vector<Bytes>           payloads;
    std::uint64_t                moovOffset { 0 };
    std::uint64_t                moovSize { 0 };
};

inline std::string DefaultConfigType(const std::string& entry)
{
    if (entry == "avc1" || entry == "avc3") return "avcC";
    if (entry == "hvc1" || entry == "hev1") return "hvcC";
    if (entry == "av01") return "av1C";
    if (entry == "vp09") return "vpcC";
    return "";
}

inline Bytes DefaultConfig(const std::string& type)
{
    if (type == "avcC") return AvcC(100, 8);
    if (type == "hvcC") return HvcC(8);
    if (type == "av1C") return Av1C(8);
    if (type == "vpcC") return VpcC(8, false, 1, 1, 1);
    return {};
}

inline Bytes VisualEntry(const Mp4Spec& spec)
{
    Bytes body;
    Bytes zeros(6, 0);
    Append(body, zeros);
    Put16(body, 1);
    Append(body, Bytes(16, 0));
    Put16(body, spec.width);
    Put16(body, spec.height);
    Put32(body, 0x00480000);
    Put32(body, 0x00480000);
    Put32(body, 0);
    Put16(body, 1);
    Append(body, Bytes(32, 0));
    Put16(body, 0x18);
    Put16(body, 0xFFFF);
    std::string type = spec.configType.empty() ? DefaultConfigType(spec.entry) : spec.configType;
    if (! type.empty() && ! spec.omitConfig) {
        Append(body, Box(type, spec.config.empty() ? DefaultConfig(type) : spec.config));
    }
    for (const Bytes& child : spec.entryChildren) Append(body, child);
    Append(body, spec.entryTrailer);
    return Box(spec.entry, body);
}

inline Bytes TrakFor(const Mp4Spec& spec, std::uint64_t mdatData, const std::vector<std::uint64_t>& offsets,
                     const std::string& handler, bool enabled, std::uint32_t trackId, bool withTables)
{
    std::uint64_t totalDelta = 0;
    for (const SampleSpec& sample : spec.samples) totalDelta += sample.delta;
    const std::uint64_t mediaDuration = spec.mediaDuration.value_or(totalDelta);

    Bytes tkhd;
    if (spec.tkhdVersion == 1) {
        Put64(tkhd, 0);
        Put64(tkhd, 0);
        Put32(tkhd, trackId);
        Put32(tkhd, 0);
        Put64(tkhd, mediaDuration);
    } else {
        Put32(tkhd, 0);
        Put32(tkhd, 0);
        Put32(tkhd, trackId);
        Put32(tkhd, 0);
        Put32(tkhd, static_cast<std::uint32_t>(mediaDuration));
    }
    Append(tkhd, Bytes(8, 0));
    Put16(tkhd, 0);
    Put16(tkhd, 0);
    Put16(tkhd, 0);
    Put16(tkhd, 0);
    for (std::int32_t value : spec.matrix) Put32(tkhd, static_cast<std::uint32_t>(value));
    Put32(tkhd, spec.tkhdWidth16 != 0 ? spec.tkhdWidth16 : spec.width << 16);
    Put32(tkhd, spec.tkhdHeight16 != 0 ? spec.tkhdHeight16 : spec.height << 16);
    Bytes tkhdBox = FullBox("tkhd", spec.tkhdVersion, enabled ? 3 : 0, tkhd);

    Bytes edts;
    if (spec.edits && withTables) {
        Bytes elst;
        Put32(elst, static_cast<std::uint32_t>(spec.edits->size()));
        for (const EditSpec& edit : *spec.edits) {
            if (spec.elstVersion == 1) {
                Put64(elst, static_cast<std::uint64_t>(edit.duration));
                Put64(elst, static_cast<std::uint64_t>(edit.mediaTime));
            } else {
                Put32(elst, static_cast<std::uint32_t>(edit.duration));
                Put32(elst, static_cast<std::uint32_t>(static_cast<std::int32_t>(edit.mediaTime)));
            }
            Put16(elst, static_cast<std::uint16_t>(edit.rateInteger));
            Put16(elst, static_cast<std::uint16_t>(edit.rateFraction));
        }
        edts = Box("edts", FullBox("elst", spec.elstVersion, 0, elst));
    }

    Bytes mdhd;
    Put32(mdhd, 0);
    Put32(mdhd, 0);
    Put32(mdhd, spec.mediaTimescale);
    Put32(mdhd, static_cast<std::uint32_t>(mediaDuration));
    Put16(mdhd, 0x55C4);
    Put16(mdhd, 0);
    Bytes hdlr;
    Put32(hdlr, 0);
    PutType(hdlr, handler);
    Append(hdlr, Bytes(12, 0));
    hdlr.push_back(0);

    Bytes stbl;
    if (withTables) {
        Bytes stsd;
        Put32(stsd, 1);
        Append(stsd, VisualEntry(spec));
        Append(stbl, FullBox("stsd", 0, 0, stsd));

        Bytes stts;
        std::vector<std::pair<std::uint32_t, std::uint32_t>> runs;
        for (const SampleSpec& sample : spec.samples) {
            if (! runs.empty() && runs.back().second == sample.delta) ++runs.back().first;
            else runs.emplace_back(1, sample.delta);
        }
        Put32(stts, static_cast<std::uint32_t>(runs.size()));
        for (const auto& run : runs) {
            Put32(stts, run.first);
            Put32(stts, run.second);
        }
        Append(stbl, FullBox("stts", 0, 0, stts));

        bool anyCts = spec.writeCtts;
        for (const SampleSpec& sample : spec.samples) anyCts = anyCts || sample.cts != 0;
        if (anyCts) {
            Bytes ctts;
            std::vector<std::pair<std::uint32_t, std::int32_t>> cts;
            for (const SampleSpec& sample : spec.samples) {
                if (! cts.empty() && cts.back().second == sample.cts) ++cts.back().first;
                else cts.emplace_back(1, sample.cts);
            }
            Put32(ctts, static_cast<std::uint32_t>(cts.size()));
            for (const auto& run : cts) {
                Put32(ctts, run.first);
                Put32(ctts, static_cast<std::uint32_t>(run.second));
            }
            Append(stbl, FullBox("ctts", spec.cttsVersion, 0, ctts));
        }

        if (spec.writeStss) {
            Bytes stss;
            std::vector<std::uint32_t> numbers;
            for (std::size_t index = 0; index < spec.samples.size(); ++index) {
                if (spec.samples[index].sync) numbers.push_back(static_cast<std::uint32_t>(index + 1));
            }
            Put32(stss, static_cast<std::uint32_t>(numbers.size()));
            for (std::uint32_t number : numbers) Put32(stss, number);
            Append(stbl, FullBox("stss", 0, 0, stss));
        }

        Bytes stsz;
        if (spec.sizeTable == 4 || spec.sizeTable == 8 || spec.sizeTable == 16) {
            Put24(stsz, 0);
            Put8(stsz, spec.sizeTable);
            Put32(stsz, static_cast<std::uint32_t>(spec.samples.size()));
            if (spec.sizeTable == 4) {
                for (std::size_t index = 0; index < spec.samples.size(); index += 2) {
                    const std::uint32_t high = spec.samples[index].size;
                    const std::uint32_t low  = index + 1 < spec.samples.size() ? spec.samples[index + 1].size : 0;
                    Put8(stsz, (high << 4) | low);
                }
            } else {
                for (const SampleSpec& sample : spec.samples) {
                    if (spec.sizeTable == 8) Put8(stsz, sample.size);
                    else Put16(stsz, sample.size);
                }
            }
            Append(stbl, FullBox("stz2", 0, 0, stsz));
        } else if (spec.sizeTable == 1) {
            Put32(stsz, spec.samples.empty() ? 0 : spec.samples[0].size);
            Put32(stsz, static_cast<std::uint32_t>(spec.samples.size()));
            Append(stbl, FullBox("stsz", 0, 0, stsz));
        } else {
            Put32(stsz, 0);
            Put32(stsz, static_cast<std::uint32_t>(spec.samples.size()));
            for (const SampleSpec& sample : spec.samples) Put32(stsz, sample.size);
            Append(stbl, FullBox("stsz", 0, 0, stsz));
        }

        // Group samples into chunks.
        std::vector<std::uint32_t> perChunk;
        std::size_t                assigned = 0;
        for (std::size_t index = 0; assigned < spec.samples.size(); ++index) {
            std::uint32_t count = spec.chunking.empty() ? 1 : spec.chunking[index % spec.chunking.size()];
            if (count > spec.samples.size() - assigned) count = static_cast<std::uint32_t>(spec.samples.size() - assigned);
            perChunk.push_back(count);
            assigned += count;
        }
        Bytes stsc;
        std::vector<std::array<std::uint32_t, 3>> entries;
        for (std::size_t chunk = 0; chunk < perChunk.size(); ++chunk) {
            if (entries.empty() || entries.back()[1] != perChunk[chunk]) {
                entries.push_back({ static_cast<std::uint32_t>(chunk + 1), perChunk[chunk], 1 });
            }
        }
        Put32(stsc, static_cast<std::uint32_t>(entries.size()));
        for (const auto& entry : entries) {
            Put32(stsc, entry[0]);
            Put32(stsc, entry[1]);
            Put32(stsc, entry[2]);
        }
        Append(stbl, FullBox("stsc", 0, 0, stsc));

        Bytes stco;
        Put32(stco, static_cast<std::uint32_t>(perChunk.size()));
        std::size_t first = 0;
        for (std::uint32_t count : perChunk) {
            const std::uint64_t at = mdatData + (offsets.empty() ? 0 : offsets[first]);
            if (spec.co64) Put64(stco, at);
            else Put32(stco, static_cast<std::uint32_t>(at));
            first += count;
        }
        Append(stbl, FullBox(spec.co64 ? "co64" : "stco", 0, 0, stco));
    }

    Bytes minf = Box("stbl", stbl);
    Bytes mdia = Cat(FullBox("mdhd", 0, 0, mdhd), FullBox("hdlr", 0, 0, hdlr), Box("minf", minf));
    return Box("trak", Cat(tkhdBox, edts, Box("mdia", mdia)));
}

inline Bytes MoovFor(const Mp4Spec& spec, std::uint64_t mdatData, const std::vector<std::uint64_t>& offsets)
{
    std::uint64_t totalDelta = 0;
    for (const SampleSpec& sample : spec.samples) totalDelta += sample.delta;
    Bytes mvhd;
    Put32(mvhd, 0);
    Put32(mvhd, 0);
    Put32(mvhd, spec.movieTimescale);
    Put32(mvhd, static_cast<std::uint32_t>(spec.mediaDuration.value_or(totalDelta)));
    Put32(mvhd, 0x00010000);
    Put16(mvhd, 0x0100);
    Append(mvhd, Bytes(10, 0));
    for (std::int32_t value : kIdentityDisplayMatrix) Put32(mvhd, static_cast<std::uint32_t>(value));
    Append(mvhd, Bytes(24, 0));
    Put32(mvhd, 2);

    Bytes moov = FullBox("mvhd", 0, 0, mvhd);
    if (spec.audioTrackFirst) Append(moov, TrakFor(spec, mdatData, offsets, "soun", true, 7, false));
    if (spec.extraDisabledVideoFirst) Append(moov, TrakFor(spec, mdatData, offsets, "vide", false, 9, true));
    if (! spec.noVideoTrack) Append(moov, TrakFor(spec, mdatData, offsets, "vide", spec.trackEnabled, spec.trackId, true));
    if (spec.mvex) Append(moov, Box("mvex", FullBox("mehd", 0, 0, Bytes(4, 0))));
    return Box("moov", moov);
}

inline BuiltMp4 BuildMp4(const Mp4Spec& spec)
{
    BuiltMp4 built;
    Bytes    mdatPayload;
    for (std::size_t index = 0; index < spec.samples.size(); ++index) {
        built.offsets.push_back(mdatPayload.size());
        Bytes payload(spec.samples[index].size, static_cast<std::uint8_t>(0x10 + index));
        Append(mdatPayload, payload);
        built.payloads.push_back(payload);
    }
    Bytes ftyp;
    if (spec.writeFtyp) {
        Bytes body;
        PutType(body, spec.ftypBrand);
        Put32(body, 0x200);
        PutType(body, "isom");
        PutType(body, "avc1");
        ftyp = Box("ftyp", body);
    }
    Bytes freeBox = spec.freeBox ? Box("free", Bytes(37, 0)) : Bytes();
    Bytes mdat;
    std::uint64_t mdatHeader = 8;
    if (spec.largeMdat) {
        mdat       = LargeBox("mdat", mdatPayload);
        mdatHeader = 16;
    } else {
        mdat = Box("mdat", mdatPayload);
        if (spec.mdatToEndOfFile) {
            mdat[0] = mdat[1] = mdat[2] = mdat[3] = 0;
        }
    }

    // The moov size does not depend on the offsets (fixed-width fields), so a
    // first pass with a dummy base measures it.
    const Bytes   probe    = MoovFor(spec, 0, built.offsets);
    const std::uint64_t moovSize = probe.size();
    const std::uint64_t mdatStart = ftyp.size() + freeBox.size() + (spec.moovFirst ? moovSize : 0);
    const Bytes   moov     = MoovFor(spec, mdatStart + mdatHeader, built.offsets);

    built.bytes = ftyp;
    Append(built.bytes, freeBox);
    if (spec.moovFirst) {
        built.moovOffset = built.bytes.size();
        Append(built.bytes, moov);
        Append(built.bytes, mdat);
    } else {
        Append(built.bytes, mdat);
        built.moovOffset = built.bytes.size();
        Append(built.bytes, moov);
    }
    built.moovSize = moov.size();
    for (std::uint64_t& offset : built.offsets) offset += mdatStart + mdatHeader;
    if (spec.moofAfter) Append(built.bytes, Box("moof", FullBox("mfhd", 0, 0, Bytes(4, 0))));
    return built;
}

/// `count` samples of `size` bytes, a sync sample every `gop`, `delta` ticks apart.
inline std::vector<SampleSpec> Samples(std::size_t count, std::uint32_t size = 100, std::uint32_t delta = 40,
                                       std::size_t gop = 4)
{
    std::vector<SampleSpec> samples(count);
    for (std::size_t index = 0; index < count; ++index) {
        samples[index].size  = size + static_cast<std::uint32_t>(index);
        samples[index].delta = delta;
        samples[index].sync  = gop != 0 && index % gop == 0;
    }
    return samples;
}

} // namespace wallpaper::media::testing
