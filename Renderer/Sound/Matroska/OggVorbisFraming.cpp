#include "Sound/Matroska/OggVorbisFraming.hpp"

#include <algorithm>
#include <cstring>

namespace wallpaper::sound
{
namespace
{

constexpr std::uint8_t  kContinued   = 0x01;
constexpr std::uint8_t  kBeginStream = 0x02;
constexpr std::uint8_t  kEndStream   = 0x04;
constexpr std::uint64_t kNoGranule   = ~std::uint64_t { 0 };

/// The Ogg page checksum: CRC-32 with polynomial 0x04C11DB7, initial value 0, no
/// reflection and no final inversion (RFC 3533 section 6).
std::uint32_t OggCrc(const std::uint8_t* data, std::size_t size, std::uint32_t crc)
{
    static const auto table = [] {
        std::array<std::uint32_t, 256> built {};
        for (std::uint32_t index = 0; index < 256; ++index) {
            std::uint32_t value = index << 24;
            for (int bit = 0; bit < 8; ++bit) value = (value & 0x80000000U) != 0 ? (value << 1) ^ 0x04C11DB7U : value << 1;
            built[index] = value;
        }
        return built;
    }();
    for (std::size_t at = 0; at < size; ++at) crc = (crc << 8) ^ table[((crc >> 24) ^ data[at]) & 0xFFU];
    return crc;
}

void PutLe32(std::uint8_t* at, std::uint32_t value)
{
    for (int index = 0; index < 4; ++index) at[index] = static_cast<std::uint8_t>(value >> (8 * index));
}

void PutLe64(std::uint8_t* at, std::uint64_t value)
{
    for (int index = 0; index < 8; ++index) at[index] = static_cast<std::uint8_t>(value >> (8 * index));
}

} // namespace

bool SplitVorbisCodecPrivate(const std::vector<std::uint8_t>& codecPrivate, VorbisHeaders* headers, std::string* error)
{
    const auto fail = [&](const char* message) {
        if (error != nullptr) *error = message;
        return false;
    };
    if (headers == nullptr) return fail("no output");
    if (codecPrivate.size() < 3 || codecPrivate[0] != 2) return fail("the Vorbis track's CodecPrivate is not three laced headers");
    std::size_t at = 1;
    std::size_t sizes[2] = { 0, 0 };
    for (std::size_t& size : sizes) {
        for (;;) {
            if (at >= codecPrivate.size()) return fail("the Vorbis track's header sizes are cut off");
            const std::uint8_t byte = codecPrivate[at++];
            size += byte;
            if (size > codecPrivate.size()) return fail("the Vorbis track's header sizes exceed its CodecPrivate");
            if (byte != 255) break;
        }
    }
    const std::size_t remaining = codecPrivate.size() - at;
    if (sizes[0] + sizes[1] >= remaining) return fail("the Vorbis track's setup header is missing");
    const std::size_t third = remaining - sizes[0] - sizes[1];
    const auto        part  = [&](std::size_t from, std::size_t size) {
        return std::vector<std::uint8_t>(codecPrivate.begin() + static_cast<std::ptrdiff_t>(from),
                                         codecPrivate.begin() + static_cast<std::ptrdiff_t>(from + size));
    };
    (*headers)[0] = part(at, sizes[0]);
    (*headers)[1] = part(at + sizes[0], sizes[1]);
    (*headers)[2] = part(at + sizes[0] + sizes[1], third);
    // The identification packet is 0x01 "vorbis" and the Ogg mapping puts it alone on a
    // page of exactly one 30-byte segment; anything else is not a header this can frame.
    if ((*headers)[0].size() != 30 || (*headers)[0][0] != 1 || std::memcmp((*headers)[0].data() + 1, "vorbis", 6) != 0) {
        return fail("the Vorbis track's first header is not an identification header");
    }
    if ((*headers)[1].empty() || (*headers)[1][0] != 3 || (*headers)[2].empty() || (*headers)[2][0] != 5) {
        return fail("the Vorbis track's comment or setup header is missing");
    }
    return true;
}

OggVorbisWriter::OggVorbisWriter(std::uint32_t serial) : m_serial(serial) {}

void OggVorbisWriter::writePage(std::uint8_t flags, std::uint64_t granule, const std::uint8_t* lacing, std::size_t laceCount,
                                const std::uint8_t* body, std::size_t bodySize)
{
    const std::size_t start = m_bytes.size();
    m_bytes.resize(start + 27 + laceCount + bodySize);
    std::uint8_t* page = m_bytes.data() + start;
    std::memcpy(page, "OggS", 4);
    page[4] = 0;
    page[5] = flags;
    PutLe64(page + 6, granule);
    PutLe32(page + 14, m_serial);
    PutLe32(page + 18, m_sequence++);
    PutLe32(page + 22, 0);  // checksum, filled in below
    page[26] = static_cast<std::uint8_t>(laceCount);
    if (laceCount != 0) std::memcpy(page + 27, lacing, laceCount);
    if (bodySize != 0) std::memcpy(page + 27 + laceCount, body, bodySize);
    PutLe32(page + 22, OggCrc(page, 27 + laceCount + bodySize, 0));
}

void OggVorbisWriter::writePages(const std::uint8_t* data, std::size_t size, bool beginOfStream, std::uint64_t granule,
                                 bool endOfStream)
{
    // A packet is cut into segments of 255 bytes and a last one shorter (possibly empty);
    // a page holds at most 255 segments, so a long packet continues on the next page.
    std::vector<std::uint8_t> lacing(size / 255, 255);
    lacing.push_back(static_cast<std::uint8_t>(size % 255));
    std::size_t segmentAt = 0;
    std::size_t byteAt    = 0;
    bool        continued = false;
    while (segmentAt < lacing.size()) {
        const std::size_t count = std::min<std::size_t>(255, lacing.size() - segmentAt);
        std::size_t       body  = 0;
        for (std::size_t index = 0; index < count; ++index) body += lacing[segmentAt + index];
        const bool last = segmentAt + count == lacing.size();
        std::uint8_t flags = 0;
        if (continued) flags |= kContinued;
        if (beginOfStream && segmentAt == 0) flags |= kBeginStream;
        if (endOfStream && last) flags |= kEndStream;
        // A page on which the packet does not finish has no position.
        writePage(flags, last ? granule : kNoGranule, lacing.data() + segmentAt, count, data + byteAt, body);
        continued = lacing[segmentAt + count - 1] == 255;
        segmentAt += count;
        byteAt += body;
    }
}

void OggVorbisWriter::writeHeaders(const VorbisHeaders& headers)
{
    writePages(headers[0].data(), headers[0].size(), true, 0, false);
    // The comment and setup packets share their pages, as in every Ogg Vorbis file:
    // the comment packet starts the page and the setup packet follows it.
    std::vector<std::uint8_t> lacing;
    std::vector<std::uint8_t> joined;
    for (int index = 1; index < 3; ++index) {
        const auto& packet = headers[static_cast<std::size_t>(index)];
        lacing.insert(lacing.end(), packet.size() / 255, 255);
        lacing.push_back(static_cast<std::uint8_t>(packet.size() % 255));
        joined.insert(joined.end(), packet.begin(), packet.end());
    }
    std::size_t segmentAt = 0;
    std::size_t byteAt    = 0;
    bool        continued = false;
    while (segmentAt < lacing.size()) {
        const std::size_t count = std::min<std::size_t>(255, lacing.size() - segmentAt);
        std::size_t       body  = 0;
        for (std::size_t index = 0; index < count; ++index) body += lacing[segmentAt + index];
        const bool last = segmentAt + count == lacing.size();
        writePage(continued ? kContinued : 0, last ? 0 : kNoGranule, lacing.data() + segmentAt, count, joined.data() + byteAt, body);
        continued = lacing[segmentAt + count - 1] == 255;
        segmentAt += count;
        byteAt += body;
    }
}

void OggVorbisWriter::writePacket(const std::uint8_t* data, std::size_t size)
{
    if (m_finished) return;
    if (m_haveHeld) writePages(m_held.data(), m_held.size(), false, kNoGranule, false);
    m_held.assign(data, data + size);
    m_haveHeld = true;
}

void OggVorbisWriter::finish(std::uint64_t totalFrames)
{
    if (m_finished) return;
    m_finished = true;
    if (m_haveHeld) {
        writePages(m_held.data(), m_held.size(), false, totalFrames, true);
        m_held.clear();
        m_haveHeld = false;
    } else {
        writePage(kEndStream, totalFrames, nullptr, 0, nullptr, 0);
    }
}

} // namespace wallpaper::sound
