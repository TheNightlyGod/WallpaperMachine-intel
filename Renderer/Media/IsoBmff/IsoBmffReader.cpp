#include "Media/IsoBmff/IsoBmffReader.hpp"

#include "Media/ByteReader.hpp"
#include "Media/Checked.hpp"
#include "Media/CodecConfig.hpp"

#include <algorithm>
#include <limits>
#include <set>
#include <utility>

namespace wallpaper::media
{
namespace
{

constexpr std::uint32_t kFtyp = FourCC('f', 't', 'y', 'p');
constexpr std::uint32_t kMoov = FourCC('m', 'o', 'o', 'v');
constexpr std::uint32_t kMoof = FourCC('m', 'o', 'o', 'f');
constexpr std::uint32_t kStyp = FourCC('s', 't', 'y', 'p');
constexpr std::uint32_t kMvex = FourCC('m', 'v', 'e', 'x');
constexpr std::uint32_t kMvhd = FourCC('m', 'v', 'h', 'd');
constexpr std::uint32_t kTrak = FourCC('t', 'r', 'a', 'k');
constexpr std::uint32_t kTkhd = FourCC('t', 'k', 'h', 'd');
constexpr std::uint32_t kEdts = FourCC('e', 'd', 't', 's');
constexpr std::uint32_t kElst = FourCC('e', 'l', 's', 't');
constexpr std::uint32_t kMdia = FourCC('m', 'd', 'i', 'a');
constexpr std::uint32_t kMdhd = FourCC('m', 'd', 'h', 'd');
constexpr std::uint32_t kHdlr = FourCC('h', 'd', 'l', 'r');
constexpr std::uint32_t kMinf = FourCC('m', 'i', 'n', 'f');
constexpr std::uint32_t kStbl = FourCC('s', 't', 'b', 'l');
constexpr std::uint32_t kStsd = FourCC('s', 't', 's', 'd');
constexpr std::uint32_t kStts = FourCC('s', 't', 't', 's');
constexpr std::uint32_t kCtts = FourCC('c', 't', 't', 's');
constexpr std::uint32_t kStss = FourCC('s', 't', 's', 's');
constexpr std::uint32_t kStsz = FourCC('s', 't', 's', 'z');
constexpr std::uint32_t kStz2 = FourCC('s', 't', 'z', '2');
constexpr std::uint32_t kStsc = FourCC('s', 't', 's', 'c');
constexpr std::uint32_t kStco = FourCC('s', 't', 'c', 'o');
constexpr std::uint32_t kCo64 = FourCC('c', 'o', '6', '4');
constexpr std::uint32_t kVide = FourCC('v', 'i', 'd', 'e');
constexpr std::uint32_t kColr = FourCC('c', 'o', 'l', 'r');
constexpr std::uint32_t kNclx = FourCC('n', 'c', 'l', 'x');
constexpr std::uint32_t kNclc = FourCC('n', 'c', 'l', 'c');
constexpr std::uint32_t kPasp = FourCC('p', 'a', 's', 'p');
constexpr std::uint32_t kAvcC = FourCC('a', 'v', 'c', 'C');
constexpr std::uint32_t kHvcC = FourCC('h', 'v', 'c', 'C');
constexpr std::uint32_t kAv1C = FourCC('a', 'v', '1', 'C');
constexpr std::uint32_t kVpcC = FourCC('v', 'p', 'c', 'C');
constexpr std::uint32_t kAvc1 = FourCC('a', 'v', 'c', '1');
constexpr std::uint32_t kAvc3 = FourCC('a', 'v', 'c', '3');
constexpr std::uint32_t kHvc1 = FourCC('h', 'v', 'c', '1');
constexpr std::uint32_t kHev1 = FourCC('h', 'e', 'v', '1');
constexpr std::uint32_t kAv01 = FourCC('a', 'v', '0', '1');
constexpr std::uint32_t kVp09 = FourCC('v', 'p', '0', '9');
constexpr std::uint32_t kEncv = FourCC('e', 'n', 'c', 'v');

// Times in an edit list are far inside this in any real file; refusing the rest
// keeps every later addition free of overflow.
constexpr std::int64_t kMaxEditTicks = std::int64_t { 1 } << 50;

bool IsFirstBoxType(std::uint32_t type)
{
    switch (type) {
    case kFtyp: case kMoov: case kMoof: case kStyp:
    case FourCC('m', 'd', 'a', 't'): case FourCC('f', 'r', 'e', 'e'): case FourCC('s', 'k', 'i', 'p'):
    case FourCC('w', 'i', 'd', 'e'): case FourCC('p', 'n', 'o', 't'): case FourCC('j', 'u', 'n', 'k'):
    case FourCC('u', 'u', 'i', 'd'): case FourCC('s', 'i', 'd', 'x'): return true;
    default: return false;
    }
}

struct Box {
    std::uint32_t type { 0 };
    /// Absolute offset of the box header in the input.
    std::uint64_t offset { 0 };
    ByteReader    payload;
};

// Reads the next box from `region` (a slice of memory that starts at absolute
// offset `base`). A size of 0 means "to the end of the region".
bool NextBox(ByteReader& region, std::uint64_t base, Box* box, Error* error)
{
    const std::uint64_t at = base + region.position();
    if (region.remaining() < 8) return Fail(error, ErrorKind::Corrupt, "a box header is cut short", at);
    const std::uint32_t size32 = region.U32();
    box->type                  = region.U32();
    box->offset                = at;
    std::uint64_t total        = size32;
    std::uint64_t header       = 8;
    if (size32 == 1) {
        if (region.remaining() < 8) return Fail(error, ErrorKind::Corrupt, "a 64-bit box size is cut short", at);
        total  = region.U64();
        header = 16;
    } else if (size32 == 0) {
        total = region.remaining() + header;
    }
    if (total < header) return Fail(error, ErrorKind::Corrupt, "a box is smaller than its own header", at);
    const std::uint64_t payload = total - header;
    if (payload > region.remaining()) {
        return Fail(error, ErrorKind::Corrupt, FourCCString(box->type) + " box extends past its parent", at);
    }
    box->payload = region.Sub(static_cast<std::size_t>(payload));
    return true;
}

bool ReadFullBoxHeader(ByteReader& reader, std::uint8_t* version, std::uint32_t* flags)
{
    const std::uint32_t word = reader.U32();
    if (! reader.ok()) return false;
    *version = static_cast<std::uint8_t>(word >> 24);
    *flags   = word & 0x00FFFFFFU;
    return true;
}

struct Edit {
    std::int64_t  segmentDuration { 0 };
    std::int64_t  mediaTime { 0 };
    std::int16_t  rateInteger { 1 };
    std::int16_t  rateFraction { 0 };
};

struct Slice {
    bool       present { false };
    ByteReader data;
};

struct TrackData {
    std::uint32_t trackId { 0 };
    std::uint32_t tkhdFlags { 0 };
    bool          hasTkhd { false };
    DisplayMatrix matrix { kIdentityDisplayMatrix };
    std::uint32_t width16 { 0 };
    std::uint32_t height16 { 0 };
    std::uint64_t tkhdDuration { 0 };
    bool          hasMdhd { false };
    std::uint32_t mediaTimescale { 0 };
    std::uint64_t mediaDuration { 0 };
    bool          mediaDurationKnown { false };
    std::uint32_t handler { 0 };
    bool          hasEdits { false };
    bool          stbl { false };
    std::vector<Edit> edits;
    Slice stsd, stts, ctts, stss, stsz, stz2, stsc, stco, co64;
};

} // namespace

// Holds the parse state so the helpers can share the error sink and limits.
class IsoBmffParser {
public:
    IsoBmffParser(IsoBmffReader* reader, Error* error) : m_reader(reader), m_error(error) {}

    bool run()
    {
        if (! scanTopLevel()) return false;
        return parseMoov() && selectAndBuild();
    }

private:
    bool fail(ErrorKind kind, const std::string& message, std::uint64_t offset = 0)
    {
        return Fail(m_error, kind, message, offset);
    }

    // --- Top level, read through the ByteSource ----------------------------------

    bool scanTopLevel()
    {
        const ByteSource&   source   = *m_reader->m_source;
        const std::uint64_t fileSize = source.size();
        if (fileSize < 8) return fail(ErrorKind::NotThisFormat, "too short to be an MP4 file");
        std::uint64_t position      = 0;
        std::uint32_t count         = 0;
        bool          cutInsideBox  = false;
        while (position < fileSize) {
            if (++count > m_reader->m_limits.maxTopLevelBoxes) {
                return fail(ErrorKind::LimitExceeded, "too many top-level boxes", position);
            }
            if (fileSize - position < 8) break;  // a few stray bytes after the last box
            std::uint8_t header[16] {};
            if (! ReadExact(source, position, header, 8)) return fail(ErrorKind::Io, "reading a box header failed", position);
            ByteReader    reader(header, 8);
            const std::uint32_t size32 = reader.U32();
            const std::uint32_t type   = reader.U32();
            std::uint64_t       total  = size32;
            std::uint64_t       headerSize = 8;
            if (count == 1 && ! IsFirstBoxType(type)) {
                return fail(ErrorKind::NotThisFormat, "the first box is '" + FourCCString(type) + "', not an MP4 box");
            }
            if (size32 == 1) {
                if (fileSize - position < 16 || ! ReadExact(source, position + 8, header + 8, 8)) {
                    return fail(ErrorKind::Truncated, "a 64-bit box size is cut short", position);
                }
                ByteReader large(header + 8, 8);
                total      = large.U64();
                headerSize = 16;
            } else if (size32 == 0) {
                total = fileSize - position;
            }
            if (total < headerSize) return fail(ErrorKind::Corrupt, "a box is smaller than its own header", position);
            const bool fits = total <= fileSize - position;

            if (type == kMoof || type == kStyp) {
                return fail(ErrorKind::Unsupported, "fragmented MP4 not supported", position);
            }
            if (type == kFtyp && total - headerSize >= 4 && fits && m_reader->m_majorBrand == 0) {
                std::uint8_t brand[4] {};
                if (ReadExact(source, position + headerSize, brand, 4)) {
                    ByteReader brandReader(brand, 4);
                    m_reader->m_majorBrand = brandReader.U32();
                }
            }
            if (type == kMoov && ! m_haveMoov) {
                if (! fits) return fail(ErrorKind::Truncated, "the moov box extends past the end of the file", position);
                const std::uint64_t payload = total - headerSize;
                if (payload > m_reader->m_limits.maxMoovBytes) {
                    return fail(ErrorKind::LimitExceeded, "the moov box is larger than " +
                                std::to_string(m_reader->m_limits.maxMoovBytes) + " bytes", position);
                }
                m_haveMoov    = true;
                m_moovPayload = position + headerSize;
                m_moovSize    = payload;
            }
            if (! fits) {
                cutInsideBox = true;
                break;
            }
            position += total;
        }
        if (! m_haveMoov) {
            return cutInsideBox ? fail(ErrorKind::Truncated, "the file ends before its moov box")
                                : fail(ErrorKind::Corrupt, "the file has no moov box");
        }
        return true;
    }

    // --- moov, parsed from memory -------------------------------------------------

    bool parseMoov()
    {
        const ByteSource& source = *m_reader->m_source;
        const std::size_t size   = static_cast<std::size_t>(m_moovSize);
        const std::uint8_t* data = source.view(m_moovPayload, size);
        if (data == nullptr) {
            if (! ReadVector(source, m_moovPayload, m_moovSize, m_reader->m_limits.maxMoovBytes, &m_moovBytes, m_error)) {
                return false;
            }
            data = m_moovBytes.data();
        }
        ByteReader region(data, size);
        while (! region.atEnd()) {
            Box box;
            if (! NextBox(region, m_moovPayload, &box, m_error)) return false;
            switch (box.type) {
            case kMvex: return fail(ErrorKind::Unsupported, "fragmented MP4 not supported", box.offset);
            case kMvhd:
                if (! parseMvhd(box)) return false;
                break;
            case kTrak:
                if (m_tracks.size() >= m_reader->m_limits.maxTracks) {
                    return fail(ErrorKind::LimitExceeded, "too many tracks", box.offset);
                }
                m_tracks.emplace_back();
                if (! parseTrak(box, &m_tracks.back())) return false;
                break;
            default: break;
            }
        }
        return true;
    }

    bool parseMvhd(Box& box)
    {
        std::uint8_t  version = 0;
        std::uint32_t flags   = 0;
        ByteReader&   reader  = box.payload;
        if (! ReadFullBoxHeader(reader, &version, &flags)) return fail(ErrorKind::Corrupt, "mvhd is cut short", box.offset);
        if (version == 1) {
            reader.Skip(16);
            m_movieTimescale = reader.U32();
        } else {
            reader.Skip(8);
            m_movieTimescale = reader.U32();
        }
        if (! reader.ok()) return fail(ErrorKind::Corrupt, "mvhd is cut short", box.offset);
        return true;
    }

    bool parseTrak(Box& trak, TrackData* track)
    {
        ByteReader& region = trak.payload;
        while (! region.atEnd()) {
            Box box;
            if (! NextBox(region, trak.offset, &box, m_error)) return false;
            if (box.type == kTkhd) {
                if (! parseTkhd(box, track)) return false;
            } else if (box.type == kEdts) {
                if (! parseEdts(box, track)) return false;
            } else if (box.type == kMdia) {
                if (! parseMdia(box, track)) return false;
            }
        }
        return true;
    }

    bool parseTkhd(Box& box, TrackData* track)
    {
        std::uint8_t  version = 0;
        ByteReader&   reader  = box.payload;
        if (! ReadFullBoxHeader(reader, &version, &track->tkhdFlags)) return fail(ErrorKind::Corrupt, "tkhd is cut short", box.offset);
        if (version == 1) {
            reader.Skip(16);
            track->trackId = reader.U32();
            reader.Skip(4);
            track->tkhdDuration = reader.U64();
        } else {
            reader.Skip(8);
            track->trackId = reader.U32();
            reader.Skip(4);
            track->tkhdDuration = reader.U32();
        }
        reader.Skip(8 + 2 + 2 + 2 + 2);  // reserved, layer, alternate group, volume, reserved
        for (auto& value : track->matrix) value = reader.I32();
        track->width16  = reader.U32();
        track->height16 = reader.U32();
        if (! reader.ok()) return fail(ErrorKind::Corrupt, "tkhd is cut short", box.offset);
        track->hasTkhd = true;
        return true;
    }

    bool parseEdts(Box& edts, TrackData* track)
    {
        ByteReader& region = edts.payload;
        while (! region.atEnd()) {
            Box box;
            if (! NextBox(region, edts.offset, &box, m_error)) return false;
            if (box.type != kElst || track->hasEdits) continue;
            std::uint8_t  version = 0;
            std::uint32_t flags   = 0;
            ByteReader&   reader  = box.payload;
            if (! ReadFullBoxHeader(reader, &version, &flags)) return fail(ErrorKind::Corrupt, "elst is cut short", box.offset);
            const std::uint32_t count = reader.U32();
            const std::size_t   width = version == 1 ? 20 : 12;
            if (! reader.ok() || count > reader.remaining() / width) {
                return fail(ErrorKind::Corrupt, "elst entry count exceeds the box", box.offset);
            }
            if (count > m_reader->m_limits.maxEdits) return fail(ErrorKind::LimitExceeded, "too many edit-list entries", box.offset);
            track->hasEdits = true;
            track->edits.reserve(count);
            for (std::uint32_t index = 0; index < count; ++index) {
                Edit edit;
                if (version == 1) {
                    const std::uint64_t duration = reader.U64();
                    edit.mediaTime               = reader.I64();
                    if (duration > static_cast<std::uint64_t>(INT64_MAX)) return fail(ErrorKind::Corrupt, "elst duration out of range", box.offset);
                    edit.segmentDuration = static_cast<std::int64_t>(duration);
                } else {
                    edit.segmentDuration = reader.U32();
                    edit.mediaTime       = reader.I32();
                }
                edit.rateInteger  = reader.I16();
                edit.rateFraction = reader.I16();
                track->edits.push_back(edit);
            }
            if (! reader.ok()) return fail(ErrorKind::Corrupt, "elst is cut short", box.offset);
        }
        return true;
    }

    bool parseMdia(Box& mdia, TrackData* track)
    {
        ByteReader& region = mdia.payload;
        while (! region.atEnd()) {
            Box box;
            if (! NextBox(region, mdia.offset, &box, m_error)) return false;
            if (box.type == kMdhd) {
                if (! parseMdhd(box, track)) return false;
            } else if (box.type == kHdlr) {
                std::uint8_t  version = 0;
                std::uint32_t flags   = 0;
                ByteReader&   reader  = box.payload;
                if (! ReadFullBoxHeader(reader, &version, &flags)) return fail(ErrorKind::Corrupt, "hdlr is cut short", box.offset);
                reader.Skip(4);
                track->handler = reader.U32();
                if (! reader.ok()) return fail(ErrorKind::Corrupt, "hdlr is cut short", box.offset);
            } else if (box.type == kMinf) {
                if (! parseContainerFor(box, kStbl, track)) return false;
            }
        }
        return true;
    }

    // minf holds stbl; stbl holds the sample tables.
    bool parseContainerFor(Box& minf, std::uint32_t wanted, TrackData* track)
    {
        ByteReader& region = minf.payload;
        while (! region.atEnd()) {
            Box box;
            if (! NextBox(region, minf.offset, &box, m_error)) return false;
            if (box.type == wanted && ! track->stbl) {
                track->stbl = true;
                if (! parseStbl(box, track)) return false;
            }
        }
        return true;
    }

    bool parseMdhd(Box& box, TrackData* track)
    {
        std::uint8_t  version = 0;
        std::uint32_t flags   = 0;
        ByteReader&   reader  = box.payload;
        if (! ReadFullBoxHeader(reader, &version, &flags)) return fail(ErrorKind::Corrupt, "mdhd is cut short", box.offset);
        if (version == 1) {
            reader.Skip(16);
            track->mediaTimescale = reader.U32();
            const std::uint64_t duration = reader.U64();
            track->mediaDuration      = duration;
            track->mediaDurationKnown = duration != std::numeric_limits<std::uint64_t>::max();
        } else {
            reader.Skip(8);
            track->mediaTimescale = reader.U32();
            const std::uint32_t duration = reader.U32();
            track->mediaDuration      = duration;
            track->mediaDurationKnown = duration != std::numeric_limits<std::uint32_t>::max();
        }
        if (! reader.ok()) return fail(ErrorKind::Corrupt, "mdhd is cut short", box.offset);
        track->hasMdhd = true;
        return true;
    }

    bool parseStbl(Box& stbl, TrackData* track)
    {
        ByteReader& region = stbl.payload;
        while (! region.atEnd()) {
            Box box;
            if (! NextBox(region, stbl.offset, &box, m_error)) return false;
            Slice* slice = nullptr;
            switch (box.type) {
            case kStsd: slice = &track->stsd; break;
            case kStts: slice = &track->stts; break;
            case kCtts: slice = &track->ctts; break;
            case kStss: slice = &track->stss; break;
            case kStsz: slice = &track->stsz; break;
            case kStz2: slice = &track->stz2; break;
            case kStsc: slice = &track->stsc; break;
            case kStco: slice = &track->stco; break;
            case kCo64: slice = &track->co64; break;
            default: break;
            }
            if (slice != nullptr && ! slice->present) {
                slice->present = true;
                slice->data    = box.payload;
            }
        }
        return true;
    }

    // --- Building the sample table ------------------------------------------------

    bool selectAndBuild()
    {
        // The first enabled video track; a disabled one only when nothing else is.
        const TrackData* chosen   = nullptr;
        const TrackData* disabled = nullptr;
        for (const TrackData& track : m_tracks) {
            if (track.handler != kVide) continue;
            if (! track.hasTkhd || (track.tkhdFlags & 1U) != 0) {
                chosen = &track;
                break;
            }
            if (disabled == nullptr) disabled = &track;
        }
        if (chosen == nullptr) chosen = disabled;
        if (chosen == nullptr) return fail(ErrorKind::Unsupported, "the file has no video track");
        return build(*chosen);
    }

    bool build(const TrackData& track)
    {
        if (! track.stsd.present || ! track.stts.present || ! track.stsc.present ||
            ! (track.stsz.present || track.stz2.present) || ! (track.stco.present || track.co64.present)) {
            return fail(ErrorKind::Corrupt, "the video track lacks a sample table box (stsd, stts, stsc, stsz and stco are required)");
        }
        if (! track.hasMdhd || track.mediaTimescale == 0) return fail(ErrorKind::Corrupt, "the video track has no media timescale");
        VideoStreamInfo& info = m_reader->m_info;
        info.timescale = track.mediaTimescale;
        info.trackId   = track.trackId;

        std::vector<Sample>& samples = m_reader->m_samples;
        std::uint32_t        declared = 0;
        if (! readSizes(track, &samples, &declared)) return false;
        std::uint32_t description = 1;
        if (! assignOffsets(track, &samples, &description)) return false;
        if (! parseStsd(track, description)) return false;
        if (! applyTimes(track, &samples)) return false;
        if (! applySync(track, &samples, declared)) return false;
        if (! applyEdits(track, &samples)) return false;
        if (! clipToFile(&samples)) return false;
        finish(track, samples);
        return true;
    }

    bool readSizes(const TrackData& track, std::vector<Sample>* samples, std::uint32_t* declared)
    {
        const std::uint32_t maxSamples = m_reader->m_limits.maxSamples;
        if (track.stsz.present) {
            ByteReader    reader = track.stsz.data;
            std::uint8_t  version = 0;
            std::uint32_t flags   = 0;
            if (! ReadFullBoxHeader(reader, &version, &flags)) return fail(ErrorKind::Corrupt, "stsz is cut short");
            const std::uint32_t constant = reader.U32();
            const std::uint32_t count    = reader.U32();
            if (! reader.ok()) return fail(ErrorKind::Corrupt, "stsz is cut short");
            if (count == 0) return fail(ErrorKind::Corrupt, "the video track has no samples");
            if (count > maxSamples) return fail(ErrorKind::LimitExceeded, "the video track has " + std::to_string(count) + " samples");
            if (constant == 0 && count > reader.remaining() / 4) return fail(ErrorKind::Corrupt, "stsz entry count exceeds the box");
            samples->assign(count, Sample {});
            for (Sample& sample : *samples) sample.size = constant != 0 ? constant : reader.U32();
            *declared = count;
            return true;
        }
        ByteReader    reader = track.stz2.data;
        std::uint8_t  version = 0;
        std::uint32_t flags   = 0;
        if (! ReadFullBoxHeader(reader, &version, &flags)) return fail(ErrorKind::Corrupt, "stz2 is cut short");
        reader.Skip(3);
        const std::uint8_t  fieldSize = reader.U8();
        const std::uint32_t count     = reader.U32();
        if (! reader.ok()) return fail(ErrorKind::Corrupt, "stz2 is cut short");
        if (fieldSize != 4 && fieldSize != 8 && fieldSize != 16) return fail(ErrorKind::Corrupt, "stz2 field size must be 4, 8 or 16");
        if (count == 0) return fail(ErrorKind::Corrupt, "the video track has no samples");
        if (count > maxSamples) return fail(ErrorKind::LimitExceeded, "the video track has " + std::to_string(count) + " samples");
        const std::uint64_t needed = (static_cast<std::uint64_t>(count) * fieldSize + 7) / 8;
        if (needed > reader.remaining()) return fail(ErrorKind::Corrupt, "stz2 entry count exceeds the box");
        samples->assign(count, Sample {});
        for (std::uint32_t index = 0; index < count; index += (fieldSize == 4 ? 2U : 1U)) {
            if (fieldSize == 4) {
                const std::uint8_t pair = reader.U8();
                (*samples)[index].size = pair >> 4;
                if (index + 1 < count) (*samples)[index + 1].size = pair & 0x0FU;
            } else if (fieldSize == 8) {
                (*samples)[index].size = reader.U8();
            } else {
                (*samples)[index].size = reader.U16();
            }
        }
        *declared = count;
        return true;
    }

    bool assignOffsets(const TrackData& track, std::vector<Sample>* samples, std::uint32_t* description)
    {
        struct Run {
            std::uint32_t firstChunk, samplesPerChunk, descriptionIndex;
        };
        ByteReader    stsc    = track.stsc.data;
        std::uint8_t  version = 0;
        std::uint32_t flags   = 0;
        if (! ReadFullBoxHeader(stsc, &version, &flags)) return fail(ErrorKind::Corrupt, "stsc is cut short");
        const std::uint32_t runCount = stsc.U32();
        if (! stsc.ok() || runCount == 0 || runCount > stsc.remaining() / 12) return fail(ErrorKind::Corrupt, "stsc entry count does not match the box");
        std::vector<Run> runs(runCount);
        std::set<std::uint32_t> descriptions;
        for (std::uint32_t index = 0; index < runCount; ++index) {
            runs[index].firstChunk       = stsc.U32();
            runs[index].samplesPerChunk  = stsc.U32();
            runs[index].descriptionIndex = stsc.U32();
            if (runs[index].descriptionIndex == 0) return fail(ErrorKind::Corrupt, "stsc names sample description 0");
            if (index == 0 ? runs[0].firstChunk != 1 : runs[index].firstChunk <= runs[index - 1].firstChunk) {
                return fail(ErrorKind::Corrupt, "stsc chunk numbers are not increasing from 1");
            }
        }

        const bool          wide = ! track.stco.present;
        ByteReader          chunks = wide ? track.co64.data : track.stco.data;
        if (! ReadFullBoxHeader(chunks, &version, &flags)) return fail(ErrorKind::Corrupt, "the chunk offset table is cut short");
        const std::uint32_t chunkCount = chunks.U32();
        const std::size_t   entryWidth = wide ? 8 : 4;
        if (! chunks.ok() || chunkCount > chunks.remaining() / entryWidth) return fail(ErrorKind::Corrupt, "the chunk offset count exceeds the box");

        std::size_t   assigned = 0;
        std::size_t   run      = 0;
        const std::size_t total = samples->size();
        for (std::uint32_t chunk = 1; chunk <= chunkCount && assigned < total; ++chunk) {
            while (run + 1 < runs.size() && runs[run + 1].firstChunk <= chunk) ++run;
            std::uint64_t position = wide ? chunks.U64() : chunks.U32();
            for (std::uint32_t inChunk = 0; inChunk < runs[run].samplesPerChunk && assigned < total; ++inChunk) {
                Sample& sample = (*samples)[assigned++];
                sample.offset  = position;
                if (! CheckedAdd<std::uint64_t>(position, sample.size, &position)) {
                    return fail(ErrorKind::Corrupt, "a sample offset overflows");
                }
            }
            // Only runs that hold samples take part in the description check.
            if (runs[run].samplesPerChunk > 0) descriptions.insert(runs[run].descriptionIndex);
        }
        if (assigned == 0) return fail(ErrorKind::Corrupt, "the chunk tables place no samples");
        if (assigned < total) {
            m_reader->m_warnings.push_back("the chunk tables place " + std::to_string(assigned) + " of " + std::to_string(total) + " samples");
            samples->resize(assigned);
        }
        if (descriptions.size() > 1) return fail(ErrorKind::Unsupported, "the video track changes its sample description");
        if (! descriptions.empty()) *description = *descriptions.begin();
        return true;
    }

    bool applyTimes(const TrackData& track, std::vector<Sample>* samples)
    {
        const std::size_t count = samples->size();
        std::uint8_t      version = 0;
        std::uint32_t     flags   = 0;
        {
            ByteReader reader = track.stts.data;
            if (! ReadFullBoxHeader(reader, &version, &flags)) return fail(ErrorKind::Corrupt, "stts is cut short");
            const std::uint32_t entries = reader.U32();
            if (! reader.ok() || entries > reader.remaining() / 8) return fail(ErrorKind::Corrupt, "stts entry count exceeds the box");
            std::int64_t dts   = 0;
            std::size_t  index = 0;
            for (std::uint32_t entry = 0; entry < entries && index < count; ++entry) {
                const std::uint32_t runLength = reader.U32();
                const std::uint32_t delta     = reader.U32();
                for (std::uint32_t step = 0; step < runLength && index < count; ++step, ++index) {
                    (*samples)[index].dts      = dts;
                    (*samples)[index].duration = delta;
                    dts += delta;
                }
            }
            if (index < count) return fail(ErrorKind::Corrupt, "stts covers " + std::to_string(index) + " of " + std::to_string(count) + " samples");
        }
        for (Sample& sample : *samples) sample.pts = sample.dts;
        if (track.ctts.present) {
            ByteReader reader = track.ctts.data;
            if (! ReadFullBoxHeader(reader, &version, &flags)) return fail(ErrorKind::Corrupt, "ctts is cut short");
            const std::uint32_t entries = reader.U32();
            if (! reader.ok() || entries > reader.remaining() / 8) return fail(ErrorKind::Corrupt, "ctts entry count exceeds the box");
            std::size_t index = 0;
            for (std::uint32_t entry = 0; entry < entries && index < count; ++entry) {
                const std::uint32_t runLength = reader.U32();
                // Signed in both versions: some version 0 writers store negative
                // offsets, and no real unsigned offset reaches 2^31 ticks.
                const std::int32_t offset = reader.I32();
                for (std::uint32_t step = 0; step < runLength && index < count; ++step, ++index) {
                    (*samples)[index].pts += offset;
                }
            }
            if (index < count) {
                m_reader->m_warnings.push_back("ctts covers " + std::to_string(index) + " of " + std::to_string(count) + " samples");
            }
        }
        return true;
    }

    bool applySync(const TrackData& track, std::vector<Sample>* samples, std::uint32_t declared)
    {
        if (! track.stss.present) {
            for (Sample& sample : *samples) sample.sync = true;
            return true;
        }
        ByteReader    reader  = track.stss.data;
        std::uint8_t  version = 0;
        std::uint32_t flags   = 0;
        if (! ReadFullBoxHeader(reader, &version, &flags)) return fail(ErrorKind::Corrupt, "stss is cut short");
        const std::uint32_t entries = reader.U32();
        if (! reader.ok() || entries > reader.remaining() / 4) return fail(ErrorKind::Corrupt, "stss entry count exceeds the box");
        if (entries == 0) return fail(ErrorKind::Corrupt, "the video track has no sync samples");
        std::uint32_t last = 0;
        for (std::uint32_t entry = 0; entry < entries; ++entry) {
            const std::uint32_t number = reader.U32();
            if (number == 0 || number <= last || number > declared) return fail(ErrorKind::Corrupt, "stss lists a sample number out of order or out of range");
            last = number;
            if (number <= samples->size()) (*samples)[number - 1].sync = true;
        }
        return true;
    }

    bool applyEdits(const TrackData& track, std::vector<Sample>* samples)
    {
        VideoStreamInfo& info = m_reader->m_info;
        std::int64_t     shift = 0;
        std::int64_t     editDuration = 0;
        if (track.hasEdits && ! track.edits.empty()) {
            if (m_movieTimescale == 0) return fail(ErrorKind::Corrupt, "the file has an edit list but no movie timescale");
            std::int64_t emptyTicks    = 0;
            std::int64_t mediaStart    = 0;
            int          segments      = 0;
            std::int64_t beforeTrailing = 0;
            bool         openEnded      = false;
            for (const Edit& edit : track.edits) {
                std::int64_t ticks = 0;
                if (! RescaleRound(edit.segmentDuration, info.timescale, m_movieTimescale, &ticks) || ticks > kMaxEditTicks) {
                    return fail(ErrorKind::Corrupt, "an edit-list duration is out of range");
                }
                if (edit.mediaTime == -1) {
                    if (segments == 0) {
                        emptyTicks += ticks;
                        editDuration += ticks;
                    }
                    // An empty edit after the media segment only pads the end.
                    continue;
                }
                if (edit.mediaTime < 0 || edit.mediaTime > kMaxEditTicks) return fail(ErrorKind::Corrupt, "an edit-list media time is out of range");
                if (++segments > 1) return fail(ErrorKind::Unsupported, "an edit list with more than one media segment is not supported");
                if (edit.rateInteger != 1 || edit.rateFraction != 0) return fail(ErrorKind::Unsupported, "an edit list with a media rate other than 1 is not supported");
                mediaStart = edit.mediaTime;
                // A zero-length media segment is how QuickTime says "to the end".
                if (ticks == 0) openEnded = true;
                editDuration += ticks;
                beforeTrailing = editDuration;
            }
            if (segments == 1) {
                shift        = emptyTicks - mediaStart;
                editDuration = openEnded ? 0 : beforeTrailing;
            } else {
                editDuration = 0;  // only empty edits: no usable timeline, keep the sample times as they are
                m_reader->m_warnings.push_back("the edit list holds no media segment and was ignored");
            }
        }
        if (shift != 0) {
            for (Sample& sample : *samples) {
                sample.dts += shift;
                sample.pts += shift;
            }
        }
        m_editDuration = editDuration;
        return true;
    }

    bool clipToFile(std::vector<Sample>* samples)
    {
        const std::uint64_t fileSize = m_reader->m_source->size();
        std::size_t         valid    = 0;
        for (const Sample& sample : *samples) {
            std::uint64_t end = 0;
            if (! CheckedAdd<std::uint64_t>(sample.offset, sample.size, &end) || end > fileSize) break;
            ++valid;
        }
        if (valid == 0) return fail(ErrorKind::Truncated, "the first sample lies beyond the end of the file");
        if (valid < samples->size()) {
            m_reader->m_warnings.push_back("the file ends inside the sample data: " + std::to_string(valid) + " of " +
                                           std::to_string(samples->size()) + " samples are present");
            samples->resize(valid);
        }
        return true;
    }

    void finish(const TrackData& track, const std::vector<Sample>& samples)
    {
        VideoStreamInfo& info = m_reader->m_info;
        info.displayMatrix    = track.matrix;
        // tkhd sizes are 16.16 fixed point.
        info.displayWidth  = (track.width16 + 0x8000U) >> 16;
        info.displayHeight = (track.height16 + 0x8000U) >> 16;

        std::int64_t end = std::numeric_limits<std::int64_t>::min();
        std::int64_t minDuration = std::numeric_limits<std::int64_t>::max();
        std::int64_t sumDuration = 0;
        for (const Sample& sample : samples) {
            end = std::max<std::int64_t>(end, sample.pts + sample.duration);
            if (sample.duration > 0) minDuration = std::min<std::int64_t>(minDuration, sample.duration);
            sumDuration += sample.duration;
        }
        info.contentEndTicks = end;
        if (minDuration != std::numeric_limits<std::int64_t>::max()) {
            info.minFramePeriod = MakeRational(minDuration, info.timescale);
            info.avgFramePeriod = MakeRational(sumDuration, static_cast<std::int64_t>(samples.size()) * info.timescale);
        }

        std::int64_t duration = 0;
        if (m_editDuration > 0) {
            duration = m_editDuration;
        } else if (track.mediaDurationKnown && track.mediaDuration > 0 &&
                   track.mediaDuration <= static_cast<std::uint64_t>(INT64_MAX)) {
            duration = static_cast<std::int64_t>(track.mediaDuration);
        } else if (track.tkhdDuration > 0 && m_movieTimescale != 0 &&
                   track.tkhdDuration <= static_cast<std::uint64_t>(INT64_MAX)) {
            RescaleRound(static_cast<std::int64_t>(track.tkhdDuration), info.timescale, m_movieTimescale, &duration);
        }
        info.durationTicks = duration > 0 ? duration : std::max<std::int64_t>(end, 0);

        m_reader->m_keyframes.build(samples);
    }

    // --- The sample description ---------------------------------------------------

    bool parseStsd(const TrackData& track, std::uint32_t wanted)
    {
        ByteReader    reader  = track.stsd.data;
        std::uint8_t  version = 0;
        std::uint32_t flags   = 0;
        if (! ReadFullBoxHeader(reader, &version, &flags)) return fail(ErrorKind::Corrupt, "stsd is cut short");
        const std::uint32_t entries = reader.U32();
        if (! reader.ok() || entries == 0 || entries > reader.remaining() / 8) return fail(ErrorKind::Corrupt, "stsd entry count does not match the box");
        if (wanted > entries) return fail(ErrorKind::Corrupt, "stsc names a sample description that stsd does not have");
        Box entry;
        for (std::uint32_t index = 1; index <= wanted; ++index) {
            if (! NextBox(reader, 0, &entry, m_error)) return false;
        }
        return parseVisualEntry(entry);
    }

    bool parseVisualEntry(Box& entry)
    {
        VideoStreamInfo& info = m_reader->m_info;
        info.codecFourcc      = entry.type;
        if (entry.type == kEncv) return fail(ErrorKind::Unsupported, "encrypted video is not supported");
        ByteReader& reader = entry.payload;
        reader.Skip(8);   // reserved(6), data_reference_index(2)
        reader.Skip(16);  // pre_defined, reserved, pre_defined[3]
        info.codedWidth  = reader.U16();
        info.codedHeight = reader.U16();
        reader.Skip(4 + 4 + 4 + 2 + 32 + 2 + 2);  // resolution, reserved, frame_count, compressorname, depth, pre_defined
        if (! reader.ok()) return fail(ErrorKind::Corrupt, "the video sample entry is cut short");
        if (info.codedWidth == 0 || info.codedHeight == 0) return fail(ErrorKind::Corrupt, "the video sample entry has no picture size");

        std::uint32_t configType = 0;
        while (reader.remaining() >= 8) {
            Box child;
            if (! NextBox(reader, entry.offset, &child, m_error)) return false;
            switch (child.type) {
            case kAvcC: case kHvcC: case kAv1C: case kVpcC:
                if (configType == 0) {
                    if (child.payload.size() > m_reader->m_limits.maxConfigBytes) return fail(ErrorKind::LimitExceeded, "a codec configuration record is too large");
                    configType = child.type;
                    info.codecConfig.assign(child.payload.cursor(), child.payload.cursor() + child.payload.size());
                }
                break;
            case kColr: parseColr(child); break;
            case kPasp: {
                const std::uint32_t horizontal = child.payload.U32();
                const std::uint32_t vertical   = child.payload.U32();
                if (child.payload.ok() && horizontal > 0 && vertical > 0) info.pixelAspect = MakeRational(horizontal, vertical);
                break;
            }
            default: break;
            }
        }
        // QuickTime ends some entries with a four-byte zero terminator; anything
        // else left over is not a box and is ignored the same way.
        info.configFourcc = configType;

        std::uint32_t expected = 0;
        switch (entry.type) {
        case kAvc1: case kAvc3: expected = kAvcC; break;
        case kHvc1: case kHev1: expected = kHvcC; break;
        case kAv01: expected = kAv1C; break;
        case kVp09: expected = kVpcC; break;
        default: break;
        }
        if (expected != 0 && configType != expected) {
            return fail(ErrorKind::Corrupt, "the " + FourCCString(entry.type) + " sample entry has no " + FourCCString(expected) + " record");
        }
        if (configType != 0) {
            ColourDescription fromConfig;
            std::uint8_t      depth = 0;
            if (! SummarizeCodecConfig(configType, info.codecConfig.data(), info.codecConfig.size(), &depth, &fromConfig)) {
                return fail(ErrorKind::Corrupt, "the " + FourCCString(configType) + " record is too short");
            }
            info.bitDepth = depth;
            if (! info.colour.present() && fromConfig.present()) info.colour = fromConfig;
        }
        return true;
    }

    void parseColr(Box& box)
    {
        VideoStreamInfo& info = m_reader->m_info;
        ByteReader&      reader = box.payload;
        const std::uint32_t type = reader.U32();
        if (type == kNclx) {
            ColourDescription colour;
            colour.source    = ColourDescription::Source::ContainerNclx;
            colour.primaries = reader.U16();
            colour.transfer  = reader.U16();
            colour.matrix    = reader.U16();
            colour.fullRange = (reader.U8() & 0x80U) != 0;
            if (reader.ok()) info.colour = colour;
        } else if (type == kNclc && info.colour.source != ColourDescription::Source::ContainerNclx) {
            ColourDescription colour;
            colour.source    = ColourDescription::Source::ContainerNclc;
            colour.primaries = reader.U16();
            colour.transfer  = reader.U16();
            colour.matrix    = reader.U16();
            if (reader.ok()) info.colour = colour;
        }
    }

    IsoBmffReader*              m_reader;
    Error*                      m_error;
    bool                        m_haveMoov { false };
    std::uint64_t               m_moovPayload { 0 };
    std::uint64_t               m_moovSize { 0 };
    std::vector<std::uint8_t>   m_moovBytes;
    std::uint32_t               m_movieTimescale { 0 };
    std::int64_t                m_editDuration { 0 };
    std::vector<TrackData>      m_tracks;
};

bool LooksLikeIsoBmff(const ByteSource& source)
{
    std::uint8_t header[8] {};
    if (! ReadExact(source, 0, header, sizeof(header))) return false;
    ByteReader          reader(header, sizeof(header));
    const std::uint32_t size = reader.U32();
    const std::uint32_t type = reader.U32();
    return (size == 0 || size == 1 || size >= 8) && IsFirstBoxType(type);
}

std::unique_ptr<IsoBmffReader> IsoBmffReader::Open(std::shared_ptr<ByteSource> source, Error* error,
                                                   const IsoBmffLimits& limits)
{
    if (source == nullptr) {
        Fail(error, ErrorKind::Io, "no byte source");
        return nullptr;
    }
    std::unique_ptr<IsoBmffReader> reader(new IsoBmffReader());
    reader->m_source = std::move(source);
    reader->m_limits = limits;
    IsoBmffParser parser(reader.get(), error);
    if (! parser.run()) return nullptr;
    return reader;
}

std::optional<std::size_t> IsoBmffReader::findKeyframeAtOrBefore(std::int64_t pts) const
{
    return m_keyframes.findAtOrBefore(m_samples, pts);
}

bool IsoBmffReader::readSample(std::size_t index, std::vector<std::uint8_t>* out, Error* error) const
{
    if (index >= m_samples.size()) return Fail(error, ErrorKind::Corrupt, "no such sample");
    const Sample& sample = m_samples[index];
    return ReadVector(*m_source, sample.offset, sample.size, m_limits.maxSampleBytes, out, error);
}

} // namespace wallpaper::media
