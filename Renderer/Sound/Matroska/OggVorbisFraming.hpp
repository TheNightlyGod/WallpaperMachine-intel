// Matroska and WebM store Vorbis as raw packets (the three header packets in the
// track's CodecPrivate, Xiph-laced), and stb_vorbis reads Ogg pages. This puts the
// packets into an in-memory Ogg stream (RFC 3533) so the project's Ogg Vorbis decoder
// can read a Matroska audio track unchanged. It parses no Vorbis data: packet bytes
// pass through, only the framing around them is written.
#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace wallpaper::sound
{

using VorbisHeaders = std::array<std::vector<std::uint8_t>, 3>;

/// The identification, comment and setup packets from an `A_VORBIS` CodecPrivate:
/// a count byte (2), the sizes of the first two packets in Xiph lacing, then the
/// three packets. False with `*error` when the record does not have that shape.
bool SplitVorbisCodecPrivate(const std::vector<std::uint8_t>& codecPrivate, VorbisHeaders* headers,
                             std::string* error);

/// Builds Ogg pages one packet at a time.
///
/// The headers go in as the Ogg Vorbis mapping requires (the identification
/// packet alone on the first page, the comment and setup packets after it). Each
/// audio packet then gets pages of its own. Their granule position is the "unknown"
/// value, since a page's position is the sample count after its last packet and that
/// needs the packets' block sizes; only the last page carries one, `totalFrames`, so
/// a decoder knows exactly where the sound ends.
class OggVorbisWriter {
public:
    explicit OggVorbisWriter(std::uint32_t serial = 0x57444d56);

    /// Writes the three header pages. Call first, once.
    void writeHeaders(const VorbisHeaders& headers);
    /// Writes one audio packet. A packet added after `finish` is ignored.
    void writePacket(const std::uint8_t* data, std::size_t size);
    /// Ends the stream: the last packet's page is marked last and carries `totalFrames`.
    /// With no packet written, an empty last page does that.
    void finish(std::uint64_t totalFrames);

    const std::vector<std::uint8_t>& bytes() const { return m_bytes; }
    std::vector<std::uint8_t>        take() { return std::move(m_bytes); }

private:
    void writePages(const std::uint8_t* data, std::size_t size, bool beginOfStream, std::uint64_t granule,
                    bool endOfStream);
    void writePage(std::uint8_t flags, std::uint64_t granule, const std::uint8_t* lacing, std::size_t laceCount,
                   const std::uint8_t* body, std::size_t bodySize);

    std::uint32_t             m_serial;
    std::uint32_t             m_sequence { 0 };
    std::vector<std::uint8_t> m_bytes;
    // The last audio packet is held back until `finish`, which decides its page's
    // granule position and end-of-stream flag.
    std::vector<std::uint8_t> m_held;
    bool                      m_haveHeld { false };
    bool                      m_finished { false };
};

} // namespace wallpaper::sound
