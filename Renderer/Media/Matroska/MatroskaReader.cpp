#include "Media/Matroska/MatroskaReader.hpp"

#include "Media/ByteReader.hpp"
#include "Media/Checked.hpp"
#include "Media/CodecConfig.hpp"
#include "Media/Matroska/Ebml.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <utility>

namespace wallpaper::media
{
namespace
{

// Element IDs, written as in the Matroska specification (length marker kept).
constexpr std::uint32_t kEbmlHeader        = 0x1A45DFA3;
constexpr std::uint32_t kEbmlReadVersion   = 0x42F7;
constexpr std::uint32_t kEbmlMaxIdLength   = 0x42F2;
constexpr std::uint32_t kEbmlMaxSizeLength = 0x42F3;
constexpr std::uint32_t kDocType           = 0x4282;
constexpr std::uint32_t kDocTypeReadVersion = 0x4285;
constexpr std::uint32_t kSegment           = 0x18538067;
constexpr std::uint32_t kSeekHead          = 0x114D9B74;
constexpr std::uint32_t kInfo              = 0x1549A966;
constexpr std::uint32_t kTimecodeScale     = 0x2AD7B1;
constexpr std::uint32_t kDuration          = 0x4489;
constexpr std::uint32_t kTracks            = 0x1654AE6B;
constexpr std::uint32_t kTrackEntry        = 0xAE;
constexpr std::uint32_t kTrackNumber       = 0xD7;
constexpr std::uint32_t kTrackUid          = 0x73C5;
constexpr std::uint32_t kTrackType         = 0x83;
constexpr std::uint32_t kFlagEnabled       = 0xB9;
constexpr std::uint32_t kFlagLacing        = 0x9C;
constexpr std::uint32_t kDefaultDuration   = 0x23E383;
constexpr std::uint32_t kCodecId           = 0x86;
constexpr std::uint32_t kCodecPrivate      = 0x63A2;
constexpr std::uint32_t kCodecDelay        = 0x56AA;
constexpr std::uint32_t kSeekPreRoll       = 0x56BB;
constexpr std::uint32_t kVideo             = 0xE0;
constexpr std::uint32_t kPixelWidth        = 0xB0;
constexpr std::uint32_t kPixelHeight       = 0xBA;
constexpr std::uint32_t kDisplayWidth      = 0x54B0;
constexpr std::uint32_t kDisplayHeight     = 0x54BA;
constexpr std::uint32_t kDisplayUnit       = 0x54B2;
constexpr std::uint32_t kColour            = 0x55B0;
constexpr std::uint32_t kMatrixCoefficients = 0x55B1;
constexpr std::uint32_t kBitsPerChannel    = 0x55B2;
constexpr std::uint32_t kRange             = 0x55B9;
constexpr std::uint32_t kTransferCharacteristics = 0x55BA;
constexpr std::uint32_t kPrimaries         = 0x55BB;
constexpr std::uint32_t kProjection        = 0x7670;
constexpr std::uint32_t kProjectionType    = 0x7671;
constexpr std::uint32_t kProjectionPoseRoll = 0x7675;
constexpr std::uint32_t kAudio             = 0xE1;
constexpr std::uint32_t kSamplingFrequency = 0xB5;
constexpr std::uint32_t kChannels          = 0x9F;
constexpr std::uint32_t kBitDepth          = 0x6264;
constexpr std::uint32_t kContentEncodings  = 0x6D80;
constexpr std::uint32_t kContentEncoding   = 0x6240;
constexpr std::uint32_t kContentEncodingScope = 0x5032;
constexpr std::uint32_t kContentEncodingType = 0x5033;
constexpr std::uint32_t kContentCompression = 0x5034;
constexpr std::uint32_t kContentCompAlgo   = 0x4254;
constexpr std::uint32_t kContentCompSettings = 0x4255;
constexpr std::uint32_t kContentEncryption = 0x5035;
constexpr std::uint32_t kCluster           = 0x1F43B675;
constexpr std::uint32_t kClusterTimecode   = 0xE7;
constexpr std::uint32_t kSimpleBlock       = 0xA3;
constexpr std::uint32_t kBlockGroup        = 0xA0;
constexpr std::uint32_t kBlock             = 0xA1;
constexpr std::uint32_t kBlockDuration     = 0x9B;
constexpr std::uint32_t kReferenceBlock    = 0xFB;
constexpr std::uint32_t kDiscardPadding    = 0x75A2;
constexpr std::uint32_t kEncryptedBlock    = 0xAF;
constexpr std::uint32_t kCues              = 0x1C53BB6B;
constexpr std::uint32_t kTags              = 0x1254C367;
constexpr std::uint32_t kChapters          = 0x1043A770;
constexpr std::uint32_t kAttachments       = 0x1941A469;

/// IDs that can only appear directly inside the Segment (or above), so an
/// unknown-size Cluster ends where one starts.
bool EndsUnknownSizeCluster(std::uint32_t id)
{
    switch (id) {
    case kCluster: case kCues: case kTags: case kChapters: case kAttachments: case kSeekHead:
    case kInfo: case kTracks: case kSegment: case kEbmlHeader: return true;
    default: return false;
    }
}

struct Header {
    std::uint32_t id { 0 };
    std::uint64_t offset { 0 };
    std::uint64_t dataOffset { 0 };
    std::uint64_t size { 0 };
    bool          unknown { false };
};

struct TrackCodec {
    const char*   id;
    MatroskaCodec codec;
    bool          supported;
};

constexpr TrackCodec kCodecs[] = {
    { "V_VP9", MatroskaCodec::Vp9, true },
    { "V_AV1", MatroskaCodec::Av1, true },
    { "V_MPEG4/ISO/AVC", MatroskaCodec::H264, true },
    { "V_MPEGH/ISO/HEVC", MatroskaCodec::Hevc, true },
    { "V_VP8", MatroskaCodec::Vp8, false },
    { "A_OPUS", MatroskaCodec::Opus, true },
    { "A_VORBIS", MatroskaCodec::Vorbis, true },
    { "A_AAC", MatroskaCodec::Aac, true },
    { "A_MPEG/L3", MatroskaCodec::Mp3, true },
};

// Calls `visit(id, payload)` for each child of a master element held in memory.
// Children of unknown size are not valid inside the elements read this way.
template<typename Visit>
bool ForEachChild(ByteReader region, Error* error, std::uint64_t base, Visit&& visit)
{
    while (! region.atEnd()) {
        std::uint32_t id = 0;
        if (! ebml::ReadId(region, &id)) return Fail(error, ErrorKind::Corrupt, "an element id is invalid or cut short", base);
        std::uint64_t size    = 0;
        bool          unknown = false;
        if (! ebml::ReadVint(region, &size, &unknown)) return Fail(error, ErrorKind::Corrupt, "an element size is invalid or cut short", base);
        if (unknown) return Fail(error, ErrorKind::Corrupt, "an element of unknown size where only sized elements are allowed", base);
        if (size > region.remaining()) return Fail(error, ErrorKind::Corrupt, "an element extends past its parent", base);
        if (! visit(id, region.Sub(static_cast<std::size_t>(size)))) return false;
    }
    return true;
}

bool Uint(ByteReader payload, std::uint64_t* value) { return ebml::ReadUnsigned(payload, value); }

// Clockwise quarter turns for a Matroska ProjectionPoseRoll (degrees counter-clockwise).
std::optional<DisplayMatrix> MatrixForRoll(double roll)
{
    if (! std::isfinite(roll)) return std::nullopt;
    double turns = std::fmod(-roll, 360.0);
    if (turns < 0) turns += 360.0;
    for (int quarter = 0; quarter < 4; ++quarter) {
        if (std::fabs(turns - 90.0 * quarter) > 0.01 && std::fabs(turns - 90.0 * quarter - 360.0) > 0.01) continue;
        constexpr std::int32_t one = 65536;
        switch (quarter) {
        case 0: return kIdentityDisplayMatrix;
        case 1: return DisplayMatrix { 0, one, 0, -one, 0, 0, 0, 0, 1 << 30 };
        case 2: return DisplayMatrix { -one, 0, 0, 0, -one, 0, 0, 0, 1 << 30 };
        default: return DisplayMatrix { 0, -one, 0, one, 0, 0, 0, 0, 1 << 30 };
        }
    }
    return std::nullopt;
}

} // namespace

class MatroskaParser {
public:
    MatroskaParser(MatroskaReader* reader, Error* error)
        : m_reader(reader), m_error(error), m_source(*reader->m_source), m_options(reader->m_options),
          m_limits(m_options.limits), m_fileSize(m_source.size()),
          m_deadline(std::chrono::steady_clock::now() + m_options.limits.maxScanTime)
    {
    }

    bool run()
    {
        if (! parseEbmlHeader()) return false;
        if (! parseSegment()) return false;
        return finish();
    }

private:
    bool fail(ErrorKind kind, const std::string& message, std::uint64_t offset = 0)
    {
        return Fail(m_error, kind, message, offset);
    }
    void warn(const std::string& message) { m_reader->m_warnings.push_back(message); }

    bool spendMetadata(std::uint64_t bytes, std::uint64_t offset)
    {
        m_metadataBytes += bytes;
        if (m_metadataBytes > m_limits.maxMetadataBytes) {
            return fail(ErrorKind::LimitExceeded, "the file's headers are larger than " + std::to_string(m_limits.maxMetadataBytes) + " bytes", offset);
        }
        return true;
    }

    // Reads the element header at `offset`; the element's data must start before `limit`.
    // `*cutShort` is set when the header is incomplete because the file itself ends.
    bool readHeader(std::uint64_t offset, std::uint64_t limit, Header* header, bool* cutShort = nullptr)
    {
        if (cutShort != nullptr) *cutShort = false;
        std::uint8_t buffer[12];
        const std::uint64_t available = limit > offset ? limit - offset : 0;
        const std::size_t   want      = static_cast<std::size_t>(std::min<std::uint64_t>(sizeof(buffer), available));
        const std::size_t   got       = m_source.readAt(offset, buffer, want);
        if (m_source.ioFailed()) return fail(ErrorKind::Io, "reading an element header failed", offset);
        const bool atEnd = offset + got >= m_fileSize;
        auto incomplete = [&](const char* what) {
            if (atEnd && cutShort != nullptr) *cutShort = true;
            return fail(atEnd ? ErrorKind::Truncated : ErrorKind::Corrupt, what, offset);
        };
        if (got == 0) return incomplete("an element header is cut short");
        const int idLength = ebml::VintLength(buffer[0]);
        if (idLength == 0 || idLength > 4) return fail(ErrorKind::Corrupt, "an element id is invalid", offset);
        if (got < static_cast<std::size_t>(idLength) + 1) return incomplete("an element header is cut short");
        const int sizeLength = ebml::VintLength(buffer[idLength]);
        if (sizeLength == 0) return fail(ErrorKind::Corrupt, "an element size is invalid", offset);
        if (got < static_cast<std::size_t>(idLength + sizeLength)) return incomplete("an element header is cut short");
        ByteReader reader(buffer, got);
        std::uint32_t id = 0;
        std::uint64_t size = 0;
        bool          unknown = false;
        ebml::ReadId(reader, &id);
        ebml::ReadVint(reader, &size, &unknown);
        header->id         = id;
        header->offset     = offset;
        header->dataOffset = offset + reader.position();
        header->size       = unknown ? 0 : size;
        header->unknown    = unknown;
        return true;
    }

    bool readPayload(const Header& header, std::uint64_t limit, std::vector<std::uint8_t>* out)
    {
        if (header.unknown) return fail(ErrorKind::Corrupt, "an element of unknown size where a sized element is required", header.offset);
        if (header.dataOffset > limit || header.size > limit - header.dataOffset) {
            return fail(ErrorKind::Truncated, "an element extends past the end of its parent or of the file", header.offset);
        }
        if (! spendMetadata(header.size, header.offset)) return false;
        return ReadVector(m_source, header.dataOffset, header.size, m_limits.maxMetadataBytes, out, m_error);
    }

    // --- EBML header -----------------------------------------------------------------

    bool parseEbmlHeader()
    {
        if (m_fileSize < 4) return fail(ErrorKind::NotThisFormat, "too short to be a Matroska file");
        Header header;
        if (! readHeader(0, m_fileSize, &header) || header.id != kEbmlHeader) {
            if (m_error != nullptr) *m_error = Error {};
            return fail(ErrorKind::NotThisFormat, "the file does not start with an EBML header");
        }
        if (header.unknown || header.size > 65536) return fail(ErrorKind::Corrupt, "the EBML header has an invalid size", 0);
        std::vector<std::uint8_t> payload;
        if (! readPayload(header, m_fileSize, &payload)) return false;
        std::uint64_t readVersion = 1, maxId = 4, maxSize = 8, docReadVersion = 1;
        bool ok = ForEachChild(ByteReader(payload.data(), payload.size()), m_error, header.dataOffset,
                               [&](std::uint32_t id, ByteReader child) {
            std::uint64_t value = 0;
            switch (id) {
            case kDocType: m_reader->m_info.docType = ebml::ReadString(child); break;
            case kEbmlReadVersion: if (Uint(child, &value)) readVersion = value; break;
            case kEbmlMaxIdLength: if (Uint(child, &value)) maxId = value; break;
            case kEbmlMaxSizeLength: if (Uint(child, &value)) maxSize = value; break;
            case kDocTypeReadVersion: if (Uint(child, &value)) docReadVersion = value; break;
            default: break;
            }
            return true;
        });
        if (! ok) return false;
        const std::string& docType = m_reader->m_info.docType;
        if (docType != "webm" && docType != "matroska") {
            return fail(ErrorKind::NotThisFormat, "the EBML document type is '" + docType + "', not webm or matroska");
        }
        if (readVersion > 1 || docReadVersion > 4) return fail(ErrorKind::Unsupported, "the file needs a newer EBML or Matroska reader");
        if (maxId > 4 || maxSize > 8) return fail(ErrorKind::Unsupported, "the file uses element ids or sizes longer than this reader supports");
        m_position = header.dataOffset + header.size;
        return true;
    }

    // --- Segment ---------------------------------------------------------------------

    bool parseSegment()
    {
        // Top level: skip anything before the Segment (Void, CRC-32, other EBML bodies).
        Header segment;
        bool   found = false;
        while (m_position < m_fileSize) {
            Header header;
            if (! readHeader(m_position, m_fileSize, &header)) return false;
            if (header.id == kSegment) {
                segment = header;
                found   = true;
                break;
            }
            if (header.unknown) return fail(ErrorKind::Corrupt, "an element of unknown size outside the Segment", header.offset);
            if (header.dataOffset > m_fileSize || header.size > m_fileSize - header.dataOffset) {
                return fail(ErrorKind::Truncated, "the file ends before its Segment", header.offset);
            }
            m_position = header.dataOffset + header.size;
        }
        if (! found) return fail(ErrorKind::Corrupt, "the file has no Segment");
        std::uint64_t end = m_fileSize;
        if (! segment.unknown) {
            if (segment.dataOffset > m_fileSize || segment.size > m_fileSize - segment.dataOffset) {
                warn("the Segment extends past the end of the file");
            } else {
                end = segment.dataOffset + segment.size;
            }
        }
        m_segmentEnd = end;
        std::uint64_t offset = segment.dataOffset;
        while (offset < end && ! m_stop) {
            Header header;
            bool   cut = false;
            if (! readHeader(offset, end, &header, &cut)) {
                if (cut && haveTracks()) {
                    warn("the file ends inside an element header");
                    break;
                }
                return false;
            }
            switch (header.id) {
            case kInfo:
            case kTracks: {
                std::vector<std::uint8_t> payload;
                if (! readPayload(header, end, &payload)) return false;
                if (! (header.id == kInfo ? parseInfo(payload, header.dataOffset) : parseTracks(payload, header.dataOffset))) return false;
                offset = header.dataOffset + header.size;
                break;
            }
            case kCluster:
                if (! haveTracks()) return fail(ErrorKind::Corrupt, "a Cluster comes before the Tracks element", header.offset);
                if (! m_reader->m_options.buildIndex) {
                    m_stop = true;
                    break;
                }
                if (! parseCluster(header, end, &offset)) return false;
                break;
            default:
                if (header.unknown) return fail(ErrorKind::Corrupt, "an element of unknown size inside the Segment", header.offset);
                if (header.dataOffset > end || header.size > end - header.dataOffset) {
                    warn("the file ends inside an element");
                    m_stop = true;
                    break;
                }
                offset = header.dataOffset + header.size;
                break;
            }
        }
        if (! haveTracks()) return fail(ErrorKind::Corrupt, "the file has no Tracks element");
        return true;
    }

    bool haveTracks() const { return m_haveTracks; }

    bool parseInfo(const std::vector<std::uint8_t>& payload, std::uint64_t base)
    {
        double durationTicks = 0;
        bool   haveDuration  = false;
        const bool ok = ForEachChild(ByteReader(payload.data(), payload.size()), m_error, base,
                                     [&](std::uint32_t id, ByteReader child) {
            std::uint64_t value = 0;
            if (id == kTimecodeScale) {
                if (! Uint(child, &value) || value == 0) return Fail(m_error, ErrorKind::Corrupt, "TimecodeScale is invalid", base);
                m_reader->m_info.timecodeScale = value;
            } else if (id == kDuration) {
                if (! ebml::ReadFloat(child, &durationTicks)) return Fail(m_error, ErrorKind::Corrupt, "Duration is invalid", base);
                haveDuration = true;
            }
            return true;
        });
        if (! ok) return false;
        if (haveDuration && std::isfinite(durationTicks) && durationTicks > 0) {
            const double ns = durationTicks * static_cast<double>(m_reader->m_info.timecodeScale);
            if (ns < 9.2e18) m_reader->m_info.infoDurationNs = static_cast<std::int64_t>(ns);
        }
        return true;
    }

    // --- Tracks ----------------------------------------------------------------------

    bool parseTracks(const std::vector<std::uint8_t>& payload, std::uint64_t base)
    {
        if (m_haveTracks) return true;  // a second Tracks element is ignored
        std::vector<MatroskaTrack>& tracks = m_reader->m_tracks;
        const bool ok = ForEachChild(ByteReader(payload.data(), payload.size()), m_error, base,
                                     [&](std::uint32_t id, ByteReader entry) {
            if (id != kTrackEntry) return true;
            if (tracks.size() >= m_limits.maxTracks) return Fail(m_error, ErrorKind::LimitExceeded, "the file has more than " + std::to_string(m_limits.maxTracks) + " tracks", base);
            MatroskaTrack track;
            if (! parseTrackEntry(entry, &track, base)) return false;
            for (const MatroskaTrack& other : tracks) {
                if (other.number == track.number) {
                    warn("track number " + std::to_string(track.number) + " is used twice; the later one is ignored");
                    return true;
                }
            }
            tracks.push_back(std::move(track));
            return true;
        });
        if (! ok) return false;
        m_haveTracks = true;
        m_reader->m_packets.assign(tracks.size(), {});
        return chooseVideoTrack();
    }

    bool parseTrackEntry(ByteReader entry, MatroskaTrack* track, std::uint64_t base)
    {
        bool sawVideo = false;
        ByteReader videoPayload, audioPayload, encodings;
        const bool ok = ForEachChild(entry, m_error, base, [&](std::uint32_t id, ByteReader child) {
            std::uint64_t value = 0;
            switch (id) {
            case kTrackNumber:
                if (! Uint(child, &value) || value == 0 || value > 0xFFFFFFFFULL) return Fail(m_error, ErrorKind::Corrupt, "a TrackNumber is invalid", base);
                track->number = static_cast<std::uint32_t>(value);
                break;
            case kTrackUid: if (Uint(child, &value)) track->uid = value; break;
            case kTrackType:
                if (Uint(child, &value)) {
                    track->rawType = static_cast<std::uint8_t>(std::min<std::uint64_t>(value, 255));
                    track->type    = value == 1 ? MatroskaTrackType::Video : value == 2 ? MatroskaTrackType::Audio : MatroskaTrackType::Other;
                }
                break;
            case kFlagEnabled: if (Uint(child, &value)) track->enabled = value != 0; break;
            case kFlagLacing: if (Uint(child, &value)) track->lacing = value != 0; break;
            case kDefaultDuration:
                if (Uint(child, &value) && value <= static_cast<std::uint64_t>(INT64_MAX)) track->defaultDurationNs = static_cast<std::int64_t>(value);
                break;
            case kCodecId: track->codecId = ebml::ReadString(child); break;
            case kCodecPrivate:
                if (child.size() > m_limits.maxCodecPrivateBytes) return Fail(m_error, ErrorKind::LimitExceeded, "a CodecPrivate is larger than the limit", base);
                track->codecPrivate.assign(child.cursor(), child.cursor() + child.size());
                break;
            case kCodecDelay: if (Uint(child, &value) && value <= static_cast<std::uint64_t>(INT64_MAX)) track->codecDelayNs = static_cast<std::int64_t>(value); break;
            case kSeekPreRoll: if (Uint(child, &value) && value <= static_cast<std::uint64_t>(INT64_MAX)) track->seekPreRollNs = static_cast<std::int64_t>(value); break;
            case kVideo: videoPayload = child; sawVideo = true; break;
            case kAudio: audioPayload = child; break;
            case kContentEncodings: encodings = child; break;
            default: break;
            }
            return true;
        });
        if (! ok) return false;
        if (track->number == 0) return fail(ErrorKind::Corrupt, "a TrackEntry has no TrackNumber", base);
        if (sawVideo) {
            if (! parseVideo(videoPayload, track, base)) return false;
        }
        if (! audioPayload.atEnd()) {
            if (! parseAudio(audioPayload, track, base)) return false;
        }
        classify(track);
        if (! encodings.atEnd() && ! parseEncodings(encodings, track, base)) return false;
        return true;
    }

    void classify(MatroskaTrack* track)
    {
        for (const TrackCodec& codec : kCodecs) {
            if (track->codecId == codec.id) {
                track->codec     = codec.codec;
                track->supported = codec.supported;
                break;
            }
        }
        if (track->type == MatroskaTrackType::Other) {
            track->supported = false;
            track->unsupportedReason = "track type " + std::to_string(track->rawType) + " is not played";
            return;
        }
        const bool video = track->type == MatroskaTrackType::Video;
        const bool codecMatchesType = track->codec == MatroskaCodec::Unknown ||
            (video == (track->codec == MatroskaCodec::Vp9 || track->codec == MatroskaCodec::Av1 || track->codec == MatroskaCodec::H264 ||
                       track->codec == MatroskaCodec::Hevc || track->codec == MatroskaCodec::Vp8));
        if (! codecMatchesType) {
            track->supported         = false;
            track->unsupportedReason = std::string(video ? "video" : "audio") + " track with codec " + track->codecId + " is not supported";
        } else if (! track->supported) {
            track->unsupportedReason = std::string(video ? "video" : "audio") + " codec " + (track->codecId.empty() ? "(none)" : track->codecId) + " is not supported";
        }
    }

    bool parseVideo(ByteReader payload, MatroskaTrack* track, std::uint64_t base)
    {
        double      roll = 0;
        bool        haveRoll = false;
        std::uint64_t projectionType = 0;
        return ForEachChild(payload, m_error, base, [&](std::uint32_t id, ByteReader child) {
            std::uint64_t value = 0;
            switch (id) {
            case kPixelWidth: if (Uint(child, &value) && value <= 0xFFFFFFFFULL) track->pixelWidth = static_cast<std::uint32_t>(value); break;
            case kPixelHeight: if (Uint(child, &value) && value <= 0xFFFFFFFFULL) track->pixelHeight = static_cast<std::uint32_t>(value); break;
            case kDisplayWidth: if (Uint(child, &value) && value <= 0xFFFFFFFFULL) track->displayWidth = static_cast<std::uint32_t>(value); break;
            case kDisplayHeight: if (Uint(child, &value) && value <= 0xFFFFFFFFULL) track->displayHeight = static_cast<std::uint32_t>(value); break;
            case kDisplayUnit: if (Uint(child, &value)) track->displayUnit = value; break;
            case kColour: return parseColour(child, track, base);
            case kProjection:
                return ForEachChild(child, m_error, base, [&](std::uint32_t projectionId, ByteReader field) {
                    std::uint64_t number = 0;
                    if (projectionId == kProjectionType && Uint(field, &number)) projectionType = number;
                    if (projectionId == kProjectionPoseRoll && ebml::ReadFloat(field, &roll)) haveRoll = true;
                    if (haveRoll && projectionType == 0) {
                        if (const auto matrix = MatrixForRoll(roll)) track->displayMatrix = *matrix;
                    }
                    return true;
                });
            default: break;
            }
            return true;
        });
    }

    bool parseColour(ByteReader payload, MatroskaTrack* track, std::uint64_t base)
    {
        ColourDescription colour;
        colour.source = ColourDescription::Source::Matroska;
        const bool ok = ForEachChild(payload, m_error, base, [&](std::uint32_t id, ByteReader child) {
            std::uint64_t value = 0;
            if (! Uint(child, &value)) return true;
            switch (id) {
            case kMatrixCoefficients: colour.matrix = static_cast<std::uint16_t>(std::min<std::uint64_t>(value, 255)); break;
            case kBitsPerChannel: track->bitsPerChannel = static_cast<std::uint8_t>(std::min<std::uint64_t>(value, 255)); break;
            case kRange: colour.fullRange = value == 2; break;
            case kTransferCharacteristics: colour.transfer = static_cast<std::uint16_t>(std::min<std::uint64_t>(value, 255)); break;
            case kPrimaries: colour.primaries = static_cast<std::uint16_t>(std::min<std::uint64_t>(value, 255)); break;
            default: break;
            }
            return true;
        });
        if (ok) track->colour = colour;
        return ok;
    }

    bool parseAudio(ByteReader payload, MatroskaTrack* track, std::uint64_t base)
    {
        return ForEachChild(payload, m_error, base, [&](std::uint32_t id, ByteReader child) {
            std::uint64_t value = 0;
            double        number = 0;
            if (id == kSamplingFrequency && ebml::ReadFloat(child, &number)) track->samplingFrequency = number;
            if (id == kChannels && Uint(child, &value) && value <= 0xFFFFFFFFULL) track->channels = static_cast<std::uint32_t>(value);
            if (id == kBitDepth && Uint(child, &value) && value <= 0xFFFFFFFFULL) track->bitDepth = static_cast<std::uint32_t>(value);
            return true;
        });
    }

    bool parseEncodings(ByteReader payload, MatroskaTrack* track, std::uint64_t base)
    {
        int count = 0;
        const bool ok = ForEachChild(payload, m_error, base, [&](std::uint32_t id, ByteReader encoding) {
            if (id != kContentEncoding) return true;
            ++count;
            std::uint64_t scope = 1, type = 0, algo = 0;
            bool          encrypted = false, hasCompression = false;
            std::vector<std::uint8_t> settings;
            const bool inner = ForEachChild(encoding, m_error, base, [&](std::uint32_t childId, ByteReader field) {
                std::uint64_t value = 0;
                switch (childId) {
                case kContentEncodingScope: if (Uint(field, &value)) scope = value; break;
                case kContentEncodingType: if (Uint(field, &value)) type = value; break;
                case kContentEncryption: encrypted = true; break;
                case kContentCompression:
                    hasCompression = true;
                    return ForEachChild(field, m_error, base, [&](std::uint32_t compId, ByteReader compField) {
                        std::uint64_t number = 0;
                        if (compId == kContentCompAlgo && Uint(compField, &number)) algo = number;
                        if (compId == kContentCompSettings) {
                            if (compField.size() > 4096) return Fail(m_error, ErrorKind::LimitExceeded, "a header-stripping setting is too long", base);
                            settings.assign(compField.cursor(), compField.cursor() + compField.size());
                        }
                        return true;
                    });
                default: break;
                }
                return true;
            });
            if (! inner) return false;
            if (count > 1) return markUnsupported(track, "a track with more than one content encoding");
            if (encrypted || type == 1) return markUnsupported(track, "an encrypted track");
            if (scope != 1) return markUnsupported(track, "a content encoding that is not applied to frames alone");
            if (! hasCompression) return true;
            if (algo != 3) return markUnsupported(track, algo == 0 ? "a zlib-compressed track" : algo == 1 ? "a bzip2-compressed track" : algo == 2 ? "an lzo-compressed track" : "a track with an unknown compression");
            track->headerStrip = std::move(settings);
            return true;
        });
        return ok;
    }

    bool markUnsupported(MatroskaTrack* track, const std::string& what)
    {
        track->supported         = false;
        track->unsupportedReason = what + " is not supported";
        return true;
    }

    bool chooseVideoTrack()
    {
        const std::vector<MatroskaTrack>& tracks = m_reader->m_tracks;
        std::optional<std::size_t> chosen, disabled, firstVideo;
        for (std::size_t index = 0; index < tracks.size(); ++index) {
            if (tracks[index].type != MatroskaTrackType::Video) continue;
            if (! firstVideo) firstVideo = index;
            if (! tracks[index].supported) continue;
            if (tracks[index].enabled) {
                chosen = index;
                break;
            }
            if (! disabled) disabled = index;
        }
        if (! chosen) chosen = disabled;
        if (! chosen) {
            if (! firstVideo) return fail(ErrorKind::Unsupported, "the file has no video track");
            return fail(ErrorKind::Unsupported, tracks[*firstVideo].unsupportedReason);
        }
        m_reader->m_videoTrack = *chosen;
        return validateVideoTrack(tracks[*chosen]);
    }

    bool validateVideoTrack(const MatroskaTrack& track)
    {
        if (track.pixelWidth == 0 || track.pixelHeight == 0) return fail(ErrorKind::Corrupt, "the video track has no PixelWidth or PixelHeight");
        std::uint8_t depth = 0;
        ColourDescription ignored;
        switch (track.codec) {
        case MatroskaCodec::H264:
        case MatroskaCodec::Hevc: {
            const std::uint32_t type = track.codec == MatroskaCodec::H264 ? FourCC('a', 'v', 'c', 'C') : FourCC('h', 'v', 'c', 'C');
            if (track.codecPrivate.empty() || ! SummarizeCodecConfig(type, track.codecPrivate.data(), track.codecPrivate.size(), &depth, &ignored)) {
                return fail(ErrorKind::Corrupt, "the " + track.codecId + " track has no valid CodecPrivate record");
            }
            break;
        }
        case MatroskaCodec::Av1:
            if (! track.codecPrivate.empty() && ! SummarizeCodecConfig(FourCC('a', 'v', '1', 'C'), track.codecPrivate.data(), track.codecPrivate.size(), &depth, &ignored)) {
                return fail(ErrorKind::Corrupt, "the V_AV1 track's CodecPrivate is not an av1C record");
            }
            break;
        default: break;
        }
        return true;
    }

    // --- Clusters --------------------------------------------------------------------

    // A failure inside the media data. With a usable key frame already indexed,
    // corruption or a cut file ends the scan and keeps what was read; anything
    // else, and every limit or unsupported feature, fails the open.
    bool scanProblem(ErrorKind kind, const std::string& message, std::uint64_t offset)
    {
        if ((kind == ErrorKind::Corrupt || kind == ErrorKind::Truncated) && m_haveVideoKeyframe) {
            warn(message + " (at offset " + std::to_string(offset) + "); the rest of the file is ignored");
            m_stop = true;
            return true;
        }
        return fail(kind, message, offset);
    }

    bool timeBudgetOk(std::uint64_t offset)
    {
        if (std::chrono::steady_clock::now() >= m_deadline) {
            return fail(ErrorKind::LimitExceeded, "indexing the file took longer than the allowed " +
                        std::to_string(m_limits.maxScanTime.count()) + " ms", offset);
        }
        return true;
    }

    bool parseCluster(const Header& cluster, std::uint64_t segmentEnd, std::uint64_t* next)
    {
        if (! timeBudgetOk(cluster.offset)) return false;
        std::uint64_t end = segmentEnd;
        if (! cluster.unknown) {
            if (cluster.dataOffset > segmentEnd || cluster.size > segmentEnd - cluster.dataOffset) {
                warn("the file ends inside a Cluster");
            } else {
                end = cluster.dataOffset + cluster.size;
            }
        }
        std::uint64_t offset = cluster.dataOffset;
        std::int64_t  timecode = 0;
        // A problem inside the cluster ends it (when the scan may continue at all).
        auto problem = [&](ErrorKind kind, const std::string& message, std::uint64_t at) {
            const bool ok = scanProblem(kind, message, at);
            *next = end;
            offset = end;
            return ok;
        };
        while (offset < end && ! m_stop) {
            Header header;
            bool   cut = false;
            if (! readHeader(offset, end, &header, &cut)) {
                if (cut) {
                    if (! cluster.unknown || offset >= m_fileSize) warn("the file ends inside a Cluster");
                    offset = end;
                    break;
                }
                return problem(ErrorKind::Corrupt, "an element inside a Cluster is invalid", offset);
            }
            if (cluster.unknown && EndsUnknownSizeCluster(header.id)) break;
            const bool sized = ! header.unknown;
            if (! sized) return problem(ErrorKind::Corrupt, "an element of unknown size inside a Cluster", header.offset);
            const bool fits = header.dataOffset <= end && header.size <= end - header.dataOffset;
            if (! fits) {
                warn("the file ends inside an element of a Cluster");
                offset = end;
                break;
            }
            const std::uint64_t after = header.dataOffset + header.size;
            switch (header.id) {
            case kClusterTimecode: {
                std::uint8_t bytes[8] {};
                if (header.size > 8) return problem(ErrorKind::Corrupt, "a Cluster Timecode is longer than 8 bytes", header.offset);
                m_source.readAt(header.dataOffset, bytes, static_cast<std::size_t>(header.size));
                std::uint64_t value = 0;
                Uint(ByteReader(bytes, static_cast<std::size_t>(header.size)), &value);
                if (value > static_cast<std::uint64_t>(INT64_MAX)) return problem(ErrorKind::Corrupt, "a Cluster Timecode is out of range", header.offset);
                timecode = static_cast<std::int64_t>(value);
                break;
            }
            case kSimpleBlock:
                if (! handleBlock(header.dataOffset, header.size, true, nullptr, timecode, header.offset)) return false;
                break;
            case kBlockGroup:
                if (! handleBlockGroup(header, timecode)) return false;
                break;
            case kEncryptedBlock:
                return fail(ErrorKind::Unsupported, "encrypted blocks are not supported", header.offset);
            default: break;
            }
            offset = after;
        }
        *next = std::max(offset, cluster.dataOffset);
        if (cluster.unknown && offset >= end) *next = end;
        return true;
    }

    struct GroupInfo {
        bool          haveBlock { false };
        std::uint64_t blockOffset { 0 };
        std::uint64_t blockSize { 0 };
        std::uint64_t blockHeaderOffset { 0 };
        std::int64_t  durationTicks { -1 };
        bool          hasReference { false };
        std::int64_t  discardPaddingNs { 0 };
    };

    bool handleBlockGroup(const Header& group, std::int64_t timecode)
    {
        GroupInfo info;
        std::uint64_t offset = group.dataOffset;
        const std::uint64_t end = group.dataOffset + group.size;
        while (offset < end) {
            Header header;
            if (! readHeader(offset, end, &header)) {
                if (m_error != nullptr) *m_error = Error {};
                return scanProblem(ErrorKind::Corrupt, "an element inside a BlockGroup is invalid", offset);
            }
            if (header.unknown || header.dataOffset > end || header.size > end - header.dataOffset) {
                return scanProblem(ErrorKind::Corrupt, "an element inside a BlockGroup extends past it", header.offset);
            }
            switch (header.id) {
            case kBlock:
                if (! info.haveBlock) {
                    info.haveBlock         = true;
                    info.blockOffset       = header.dataOffset;
                    info.blockSize         = header.size;
                    info.blockHeaderOffset = header.offset;
                }
                break;
            case kBlockDuration:
            case kDiscardPadding:
            case kReferenceBlock: {
                std::uint8_t bytes[8] {};
                if (header.size > 8) return scanProblem(ErrorKind::Corrupt, "a BlockGroup number is longer than 8 bytes", header.offset);
                m_source.readAt(header.dataOffset, bytes, static_cast<std::size_t>(header.size));
                ByteReader number(bytes, static_cast<std::size_t>(header.size));
                if (header.id == kReferenceBlock) {
                    info.hasReference = true;
                } else if (header.id == kBlockDuration) {
                    std::uint64_t value = 0;
                    Uint(number, &value);
                    if (value <= static_cast<std::uint64_t>(INT64_MAX)) info.durationTicks = static_cast<std::int64_t>(value);
                } else {
                    std::int64_t value = 0;
                    ebml::ReadSigned(number, &value);
                    info.discardPaddingNs = value;
                }
                break;
            }
            default: break;
            }
            offset = header.dataOffset + header.size;
        }
        if (! info.haveBlock) return true;
        return handleBlock(info.blockOffset, info.blockSize, false, &info, timecode, info.blockHeaderOffset);
    }

    bool handleBlock(std::uint64_t dataOffset, std::uint64_t size, bool simple, const GroupInfo* group,
                     std::int64_t clusterTimecode, std::uint64_t elementOffset)
    {
        if (m_stop) return true;
        if (size < 4) return scanProblem(ErrorKind::Corrupt, "a block is too short to hold its header", elementOffset);
        std::uint8_t head[16];
        const std::size_t headBytes = static_cast<std::size_t>(std::min<std::uint64_t>(size, sizeof(head)));
        if (m_source.readAt(dataOffset, head, headBytes) != headBytes) {
            return m_source.ioFailed() ? fail(ErrorKind::Io, "reading a block header failed", dataOffset)
                                       : scanProblem(ErrorKind::Truncated, "the file ends inside a block header", elementOffset);
        }
        ByteReader reader(head, headBytes);
        std::uint64_t trackNumber = 0;
        int           trackLength = 0;
        if (! ebml::ReadVint(reader, &trackNumber, nullptr, &trackLength)) return scanProblem(ErrorKind::Corrupt, "a block's track number is invalid", elementOffset);
        const std::int16_t relative = reader.I16();
        const std::uint8_t flags    = reader.U8();
        if (! reader.ok()) return scanProblem(ErrorKind::Corrupt, "a block is too short to hold its header", elementOffset);
        const std::uint64_t headerLength = reader.position();

        const MatroskaTrack* track = nullptr;
        std::size_t          trackIndex = 0;
        for (std::size_t index = 0; index < m_reader->m_tracks.size(); ++index) {
            if (m_reader->m_tracks[index].number == trackNumber) {
                track = &m_reader->m_tracks[index];
                trackIndex = index;
                break;
            }
        }
        if (track == nullptr) {
            if (! m_warnedUnknownTrack) warn("a block names track " + std::to_string(trackNumber) + ", which the file does not define; such blocks are skipped");
            m_warnedUnknownTrack = true;
            return true;
        }
        if (track->type == MatroskaTrackType::Other || ! track->supported) return true;
        const bool video = track->type == MatroskaTrackType::Video;

        std::int64_t ticks = 0;
        if (! CheckedAdd<std::int64_t>(clusterTimecode, relative, &ticks)) return scanProblem(ErrorKind::Corrupt, "a block timestamp overflows", elementOffset);
        std::int64_t ptsNs = 0;
        if (m_reader->m_info.timecodeScale > static_cast<std::uint64_t>(INT64_MAX) ||
            ! CheckedMul<std::int64_t>(ticks, static_cast<std::int64_t>(m_reader->m_info.timecodeScale), &ptsNs)) {
            return scanProblem(ErrorKind::Corrupt, "a block timestamp overflows", elementOffset);
        }

        const std::uint64_t payloadOffset = dataOffset + headerLength;
        const std::uint64_t payloadSize   = size - headerLength;
        std::vector<std::uint64_t> frameSizes;
        std::uint64_t              firstFrameOffset = payloadOffset;
        const int lacing = (flags >> 1) & 3;
        if (lacing == 0) {
            frameSizes.push_back(payloadSize);
        } else {
            if (! parseLacing(lacing, payloadOffset, payloadSize, &frameSizes, &firstFrameOffset, elementOffset)) return false;
            if (m_stop) return true;
        }

        std::int64_t blockDurationNs = 0;
        if (group != nullptr && group->durationTicks >= 0) {
            if (! CheckedMul<std::int64_t>(group->durationTicks, static_cast<std::int64_t>(m_reader->m_info.timecodeScale), &blockDurationNs)) blockDurationNs = 0;
        }
        const std::int64_t count = static_cast<std::int64_t>(frameSizes.size());
        std::int64_t       frameDuration = blockDurationNs > 0 ? blockDurationNs / count : track->defaultDurationNs;
        const std::uint64_t maxFrame = video ? std::max<std::uint64_t>(65536, static_cast<std::uint64_t>(track->pixelWidth) * track->pixelHeight * 4) : m_limits.maxBlockBytes;
        std::uint64_t offset = firstFrameOffset;
        for (std::size_t index = 0; index < frameSizes.size(); ++index) {
            const std::uint64_t frameSize = frameSizes[index];
            if (frameSize > m_limits.maxBlockBytes || frameSize > maxFrame || frameSize > 0xFFFFFFFFULL) {
                return scanProblem(ErrorKind::Corrupt, "a frame of " + std::to_string(frameSize) + " bytes is larger than the track allows", elementOffset);
            }
            if (m_packetCount >= m_limits.maxPackets) {
                return fail(ErrorKind::LimitExceeded, "the file has more than " + std::to_string(m_limits.maxPackets) + " frames", elementOffset);
            }
            MatroskaPacket packet;
            packet.offset     = offset;
            packet.size       = static_cast<std::uint32_t>(frameSize);
            std::int64_t shift = 0;
            if (! CheckedMul<std::int64_t>(static_cast<std::int64_t>(index), frameDuration, &shift) || ! CheckedAdd<std::int64_t>(ptsNs, shift, &packet.ptsNs)) {
                return scanProblem(ErrorKind::Corrupt, "a laced frame timestamp overflows", elementOffset);
            }
            packet.durationNs = frameDuration;
            packet.keyframe   = video ? (index == 0 && (simple ? (flags & 0x80U) != 0 : ! group->hasReference)) : true;
            packet.invisible  = (flags & 0x08U) != 0;
            if (group != nullptr) {
                packet.discardPaddingNs = static_cast<std::int32_t>(std::clamp<std::int64_t>(group->discardPaddingNs, INT32_MIN, INT32_MAX));
            }
            m_reader->m_packets[trackIndex].push_back(packet);
            ++m_packetCount;
            if (video && trackIndex == m_reader->m_videoTrack && packet.keyframe) m_haveVideoKeyframe = true;
            offset += frameSize;
            if ((m_packetCount & 1023U) == 0 && ! timeBudgetOk(elementOffset)) return false;
        }
        return true;
    }

    // Reads the lace table at the start of a block's payload. `*firstFrame` is where
    // the first frame's bytes begin; `*sizes` receives every frame's size.
    bool parseLacing(int lacing, std::uint64_t payloadOffset, std::uint64_t payloadSize,
                     std::vector<std::uint64_t>* sizes, std::uint64_t* firstFrame, std::uint64_t elementOffset)
    {
        if (payloadSize < 1) return scanProblem(ErrorKind::Corrupt, "a laced block has no lace count", elementOffset);
        const std::size_t cap = static_cast<std::size_t>(std::min<std::uint64_t>(payloadSize, 65536));
        std::vector<std::uint8_t> table(cap);
        if (m_source.readAt(payloadOffset, table.data(), cap) != cap) {
            return scanProblem(ErrorKind::Truncated, "the file ends inside a lace table", elementOffset);
        }
        ByteReader reader(table.data(), table.size());
        const std::uint32_t frames = static_cast<std::uint32_t>(reader.U8()) + 1;
        if (frames > m_limits.maxLaceFrames) return fail(ErrorKind::LimitExceeded, "a block holds " + std::to_string(frames) + " laced frames", elementOffset);
        sizes->assign(frames, 0);
        std::uint64_t consumed = 0;  // total of the sizes of all frames but the last
        auto bad = [&](const char* what) { return scanProblem(ErrorKind::Corrupt, what, elementOffset); };
        if (lacing == 2) {  // fixed-size
            const std::uint64_t body = payloadSize - 1;
            if (body % frames != 0) return bad("fixed-size lacing does not divide the block evenly");
            std::fill(sizes->begin(), sizes->end(), body / frames);
            *firstFrame = payloadOffset + 1;
            return spendMetadata(reader.position(), elementOffset);
        }
        if (lacing == 1) {  // Xiph
            for (std::uint32_t index = 0; index + 1 < frames; ++index) {
                std::uint64_t size = 0;
                std::uint8_t  byte;
                do {
                    byte = reader.U8();
                    if (! reader.ok()) return bad("a Xiph lace table is cut short");
                    size += byte;
                } while (byte == 255);
                (*sizes)[index] = size;
                consumed += size;
            }
        } else {  // EBML
            std::uint64_t first = 0;
            if (! ebml::ReadVint(reader, &first)) return bad("an EBML lace table is invalid");
            (*sizes)[0] = first;
            consumed    = first;
            std::int64_t previous = static_cast<std::int64_t>(first);
            for (std::uint32_t index = 1; index + 1 < frames; ++index) {
                std::int64_t difference = 0;
                if (! ebml::ReadSignedVint(reader, &difference)) return bad("an EBML lace table is invalid");
                const std::int64_t size = previous + difference;
                if (size < 0) return bad("an EBML lace size is negative");
                (*sizes)[index] = static_cast<std::uint64_t>(size);
                consumed += static_cast<std::uint64_t>(size);
                previous = size;
            }
            if (frames == 1) consumed = 0;
        }
        const std::uint64_t tableBytes = reader.position();
        if (tableBytes > payloadSize || consumed > payloadSize - tableBytes) return bad("laced frame sizes exceed the block");
        (*sizes)[frames - 1] = payloadSize - tableBytes - consumed;
        *firstFrame = payloadOffset + tableBytes;
        // Only the table itself counts against the header budget, not the frame bytes after it.
        return spendMetadata(tableBytes, elementOffset);
    }

    // --- Wrap-up ---------------------------------------------------------------------

    bool finish()
    {
        MatroskaReader& reader = *m_reader;
        const MatroskaTrack& track = reader.m_tracks[reader.m_videoTrack];
        VideoStreamInfo& info = reader.m_videoInfo;
        switch (track.codec) {
        case MatroskaCodec::Vp9: info.codecFourcc = FourCC('v', 'p', '0', '9'); break;
        case MatroskaCodec::Av1: info.codecFourcc = FourCC('a', 'v', '0', '1'); break;
        case MatroskaCodec::H264: info.codecFourcc = FourCC('a', 'v', 'c', '1'); break;
        default: info.codecFourcc = FourCC('h', 'v', 'c', '1'); break;
        }
        if (track.codec == MatroskaCodec::H264) info.configFourcc = FourCC('a', 'v', 'c', 'C');
        if (track.codec == MatroskaCodec::Hevc) info.configFourcc = FourCC('h', 'v', 'c', 'C');
        if (track.codec == MatroskaCodec::Av1 && ! track.codecPrivate.empty()) info.configFourcc = FourCC('a', 'v', '1', 'C');
        if (info.configFourcc != 0) info.codecConfig = track.codecPrivate;
        info.codedWidth  = track.pixelWidth;
        info.codedHeight = track.pixelHeight;
        info.timescale   = 1000000000;
        info.trackId     = track.number;
        info.displayMatrix = track.displayMatrix;
        info.colour        = track.colour;
        if (track.displayUnit == 0 && track.displayWidth != 0 && track.displayHeight != 0) {
            info.displayWidth  = track.displayWidth;
            info.displayHeight = track.displayHeight;
        }
        if ((track.displayUnit == 0 || track.displayUnit == 3) && track.displayWidth != 0 && track.displayHeight != 0) {
            const std::int64_t num = static_cast<std::int64_t>(track.displayWidth) * track.pixelHeight;
            const std::int64_t den = static_cast<std::int64_t>(track.displayHeight) * track.pixelWidth;
            if (num != den) info.pixelAspect = MakeRational(num, den);
        }
        std::uint8_t depth = 0;
        ColourDescription fromConfig;
        if (info.configFourcc != 0) SummarizeCodecConfig(info.configFourcc, info.codecConfig.data(), info.codecConfig.size(), &depth, &fromConfig);
        info.bitDepth = depth;
        if (track.bitsPerChannel != 0) info.bitDepth = track.bitsPerChannel;

        if (! reader.m_options.buildIndex) {
            info.durationTicks = reader.m_info.infoDurationNs;
            return true;
        }
        const std::vector<MatroskaPacket>& packets = reader.m_packets[reader.m_videoTrack];
        if (packets.empty()) return fail(ErrorKind::Corrupt, "the video track has no frames");
        buildSamples(packets);
        if (reader.m_keyframes.empty()) return fail(ErrorKind::Corrupt, "the video track has no key frame");
        if (track.codec == MatroskaCodec::Vp9) readVp9KeyFrame();
        return true;
    }

    void buildSamples(const std::vector<MatroskaPacket>& packets)
    {
        MatroskaReader& reader = *m_reader;
        VideoStreamInfo& info = reader.m_videoInfo;
        const std::size_t count = packets.size();
        std::vector<std::int64_t> sorted(count);
        for (std::size_t index = 0; index < count; ++index) sorted[index] = packets[index].ptsNs;
        std::sort(sorted.begin(), sorted.end());
        // dts: the i-th smallest pts, moved earlier by the least amount that keeps it at or before its own pts.
        std::int64_t shift = 0;
        for (std::size_t index = 0; index < count; ++index) shift = std::max(shift, sorted[index] - packets[index].ptsNs);
        std::int64_t minDelta = std::numeric_limits<std::int64_t>::max();
        for (std::size_t index = 1; index < count; ++index) {
            const std::int64_t delta = sorted[index] - sorted[index - 1];
            if (delta > 0) minDelta = std::min(minDelta, delta);
        }
        const bool haveDelta = minDelta != std::numeric_limits<std::int64_t>::max();
        const MatroskaTrack& track = reader.m_tracks[reader.m_videoTrack];

        reader.m_videoSamples.assign(count, Sample {});
        std::int64_t end = 0;
        for (std::size_t index = 0; index < count; ++index) {
            Sample& sample = reader.m_videoSamples[index];
            sample.offset  = packets[index].offset;
            sample.size    = packets[index].size;
            sample.pts     = packets[index].ptsNs;
            sample.dts     = sorted[index] - shift;
            sample.sync    = packets[index].keyframe;
            std::int64_t duration = packets[index].durationNs;
            if (duration <= 0) duration = track.defaultDurationNs;
            if (duration <= 0 && haveDelta) duration = minDelta;
            sample.duration = duration;
            end = std::max(end, sample.pts + duration);
        }
        if (haveDelta) {
            info.minFramePeriod = MakeRational(minDelta, 1000000000);
            info.avgFramePeriod = MakeRational(sorted.back() - sorted.front(), static_cast<std::int64_t>(count - 1) * 1000000000);
        } else if (track.defaultDurationNs > 0) {
            info.minFramePeriod = info.avgFramePeriod = MakeRational(track.defaultDurationNs, 1000000000);
        } else if (packets[0].durationNs > 0) {
            info.minFramePeriod = info.avgFramePeriod = MakeRational(packets[0].durationNs, 1000000000);
        }
        info.contentEndTicks = end;
        info.durationTicks   = end > 0 ? end : reader.m_info.infoDurationNs;
        reader.m_keyframes.build(reader.m_videoSamples);
    }

    void readVp9KeyFrame()
    {
        MatroskaReader& reader = *m_reader;
        const MatroskaTrack& track = reader.m_tracks[reader.m_videoTrack];
        for (const Sample& sample : reader.m_videoSamples) {
            if (! sample.sync) continue;
            std::vector<std::uint8_t> bytes(track.headerStrip);
            const std::size_t want = std::min<std::size_t>(sample.size, 32);
            const std::size_t at   = bytes.size();
            bytes.resize(at + want);
            if (m_source.readAt(sample.offset, bytes.data() + at, want) != want) break;
            Vp9FrameHeader header;
            Error          parseError;
            if (ParseVp9UncompressedHeader(bytes.data(), bytes.size(), &header, &parseError) && header.keyFrame && header.hasColourConfig) {
                reader.m_vp9 = header;
                reader.m_videoInfo.bitDepth = header.bitDepth;
            } else {
                warn("the first VP9 key frame's header could not be read: " + Describe(parseError));
            }
            break;
        }
    }

    MatroskaReader*       m_reader;
    Error*                m_error;
    const ByteSource&     m_source;
    const MatroskaOptions& m_options;
    const MatroskaLimits& m_limits;
    std::uint64_t         m_fileSize;
    std::chrono::steady_clock::time_point m_deadline;
    std::uint64_t         m_metadataBytes { 0 };
    std::uint64_t         m_position { 0 };
    std::uint64_t         m_segmentEnd { 0 };
    std::uint64_t         m_packetCount { 0 };
    bool                  m_haveTracks { false };
    bool                  m_haveVideoKeyframe { false };
    bool                  m_stop { false };
    bool                  m_warnedUnknownTrack { false };
};

std::unique_ptr<MatroskaReader> MatroskaReader::Open(std::shared_ptr<ByteSource> source, Error* error,
                                                     const MatroskaOptions& options)
{
    if (source == nullptr) {
        Fail(error, ErrorKind::Io, "no byte source");
        return nullptr;
    }
    std::unique_ptr<MatroskaReader> reader(new MatroskaReader());
    reader->m_source  = std::move(source);
    reader->m_options = options;
    MatroskaParser parser(reader.get(), error);
    if (! parser.run()) return nullptr;
    return reader;
}

std::optional<std::size_t> MatroskaReader::findVideoKeyframeAtOrBefore(std::int64_t ptsNs) const
{
    return m_keyframes.findAtOrBefore(m_videoSamples, ptsNs);
}

namespace
{
bool ReadWithStrip(const ByteSource& source, const std::vector<std::uint8_t>& strip, std::uint64_t offset,
                   std::uint32_t size, std::uint32_t limit, std::vector<std::uint8_t>* out, Error* error)
{
    std::vector<std::uint8_t> body;
    if (! ReadVector(source, offset, size, limit, &body, error)) return false;
    if (strip.empty()) {
        *out = std::move(body);
        return true;
    }
    out->assign(strip.begin(), strip.end());
    out->insert(out->end(), body.begin(), body.end());
    return true;
}
} // namespace

bool MatroskaReader::readSample(std::size_t index, std::vector<std::uint8_t>* out, Error* error) const
{
    if (index >= m_videoSamples.size()) return Fail(error, ErrorKind::Corrupt, "no such sample");
    const Sample& sample = m_videoSamples[index];
    return ReadWithStrip(*m_source, m_tracks[m_videoTrack].headerStrip, sample.offset, sample.size, m_options.limits.maxReadBytes, out, error);
}

bool MatroskaReader::readPacket(std::size_t trackIndex, std::size_t packetIndex, std::vector<std::uint8_t>* out,
                                Error* error) const
{
    if (trackIndex >= m_packets.size() || packetIndex >= m_packets[trackIndex].size()) return Fail(error, ErrorKind::Corrupt, "no such packet");
    const MatroskaPacket& packet = m_packets[trackIndex][packetIndex];
    return ReadWithStrip(*m_source, m_tracks[trackIndex].headerStrip, packet.offset, packet.size, m_options.limits.maxReadBytes, out, error);
}

} // namespace wallpaper::media
