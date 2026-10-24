#include "Sound/Vorbis/VorbisDecoder.hpp"

#include <algorithm>
#include <cstring>
#include <limits>
#include <utility>

// stb_vorbis is a single C file: its declarations come from the file itself in
// header-only mode, with the same definitions it was built with.
#define STB_VORBIS_HEADER_ONLY
#include "stb_vorbis.c"
#undef STB_VORBIS_HEADER_ONLY

namespace wallpaper::sound
{
namespace
{

// A scene's sound is a few megabytes; a file past this is not one of them.
constexpr std::uint64_t kMaxFileBytes = 256ull * 1024 * 1024;
constexpr std::size_t   kMaxChannels  = 8;
// Past the highest rate any audio format uses. The file names its own rate, and a
// large one would only make the resampler's filter enormous.
constexpr std::uint32_t kMaxSampleRate = 768000;

std::uint32_t LittleEndian32(const std::uint8_t* at)
{
    return static_cast<std::uint32_t>(at[0]) | static_cast<std::uint32_t>(at[1]) << 8 |
           static_cast<std::uint32_t>(at[2]) << 16 | static_cast<std::uint32_t>(at[3]) << 24;
}

/// Checks the two headers stb_vorbis parses without trusting their lengths: the
/// identification header's page and the comment header (the vendor string, the
/// user comments and the framing bit). stb_vorbis allocates and copies by the
/// lengths that header states, so a file that claims two billion comments would
/// crash it. This walks the Ogg pages with the same structure stb_vorbis insists
/// on (the identification header alone on the first page, the comment header
/// starting the second) and accepts only a comment header whose every length
/// fits inside the header's bytes. Returns an empty string when it is sound.
std::string CheckHeaders(const std::uint8_t* data, std::size_t size)
{
    constexpr std::size_t kPageHeader = 27;
    std::size_t           at          = 0;
    std::vector<std::uint8_t> comment;
    bool                  commentDone = false;

    for (int page = 0; !commentDone; ++page) {
        if (size - at < kPageHeader || std::memcmp(data + at, "OggS", 4) != 0) {
            return page == 0 ? "not an Ogg stream" : "the file ends inside its headers";
        }
        const std::uint8_t flags    = data[at + 5];
        const std::size_t  segments = data[at + 26];
        if (data[at + 4] != 0) return "unknown Ogg stream structure version";
        if (size - at - kPageHeader < segments) return "the file ends inside its headers";
        const std::uint8_t* table = data + at + kPageHeader;
        std::size_t         body  = 0;
        for (std::size_t i = 0; i < segments; ++i) body += table[i];
        const std::size_t bodyAt = at + kPageHeader + segments;
        if (size - bodyAt < body) return "the file ends inside its headers";

        if (page == 0) {
            if (segments != 1 || table[0] != 30 || (flags & 0x01) != 0) return "invalid first Ogg page";
            if (body < 7 || data[bodyAt] != 1 || std::memcmp(data + bodyAt + 1, "vorbis", 6) != 0) {
                return "not a Vorbis stream";
            }
        } else {
            // The comment packet: begins the page, may continue on the pages after it.
            if ((page == 1) == ((flags & 0x01) != 0)) return "invalid Ogg page flags";
            std::size_t offset = bodyAt;
            for (std::size_t i = 0; i < segments && !commentDone; ++i) {
                comment.insert(comment.end(), data + offset, data + offset + table[i]);
                offset += table[i];
                commentDone = table[i] < 255;
            }
            // Whatever follows the comment packet's last segment is the setup header.
        }
        at = bodyAt + body;
    }

    // 0x03 "vorbis", vendor length and string, comment count, each comment's length
    // and text, then a framing byte with bit 0 set.
    const std::size_t total = comment.size();
    if (total < 7 || comment[0] != 3 || std::memcmp(comment.data() + 1, "vorbis", 6) != 0) {
        return "not a Vorbis stream";
    }
    std::size_t pos = 7;
    const auto  remaining = [&] { return total - pos; };
    if (remaining() < 4) return "invalid comment header";
    const std::uint32_t vendor = LittleEndian32(comment.data() + pos);
    pos += 4;
    if (vendor > remaining()) return "invalid comment header";
    pos += vendor;
    if (remaining() < 4) return "invalid comment header";
    const std::uint32_t count = LittleEndian32(comment.data() + pos);
    pos += 4;
    // Every comment is at least its own 4-byte length.
    if (count > remaining() / 4) return "invalid comment header";
    for (std::uint32_t i = 0; i < count; ++i) {
        if (remaining() < 4) return "invalid comment header";
        const std::uint32_t length = LittleEndian32(comment.data() + pos);
        pos += 4;
        if (length > remaining()) return "invalid comment header";
        pos += length;
    }
    if (remaining() < 1 || (comment[pos] & 1) == 0) return "invalid comment header";
    return {};
}

const char* ErrorName(int code)
{
    switch (code) {
    case VORBIS__no_error: return "no error";
    case VORBIS_need_more_data: return "the file ends inside its headers";
    case VORBIS_invalid_api_mixing: return "invalid use of the decoder";
    case VORBIS_outofmem: return "out of memory";
    case VORBIS_feature_not_supported: return "a Vorbis feature the decoder does not support";
    case VORBIS_too_many_channels: return "too many channels";
    case VORBIS_file_open_failure: return "cannot open the file";
    case VORBIS_seek_without_length: return "cannot seek";
    case VORBIS_unexpected_eof: return "unexpected end of file";
    case VORBIS_seek_invalid: return "invalid seek";
    case VORBIS_invalid_setup: return "invalid setup header";
    case VORBIS_invalid_stream: return "invalid stream";
    case VORBIS_missing_capture_pattern: return "not an Ogg stream";
    case VORBIS_invalid_stream_structure_version: return "unknown Vorbis stream structure version";
    case VORBIS_continued_packet_flag_invalid: return "invalid Ogg page flags";
    case VORBIS_incorrect_stream_serial_number: return "unexpected Ogg stream serial number";
    case VORBIS_invalid_first_page: return "invalid first Ogg page";
    case VORBIS_bad_packet_type: return "not a Vorbis stream";
    case VORBIS_cant_find_last_page: return "cannot find the last Ogg page";
    case VORBIS_seek_failed: return "seek failed";
    case VORBIS_ogg_skeleton_not_supported: return "Ogg skeleton streams are not supported";
    default: return "unknown error";
    }
}

class VorbisDecoder final : public PcmDecoder {
public:
    VorbisDecoder(std::vector<std::uint8_t> bytes, stb_vorbis* vorbis, PcmFormat format,
                  std::uint64_t total_frames)
        : m_bytes(std::move(bytes)), m_vorbis(vorbis), m_format(format), m_total(total_frames),
          m_order(VorbisToNativeOrder(format.channels))
    {
    }

    ~VorbisDecoder() override { stb_vorbis_close(m_vorbis); }

    PcmFormat format() const override { return m_format; }

    std::size_t read(float* out, std::size_t frames) override
    {
        if (m_failed || frames == 0 || m_position >= m_total) return 0;
        frames = static_cast<std::size_t>(std::min<std::uint64_t>(frames, m_total - m_position));
        const int channels = static_cast<int>(m_format.channels);
        const int count    = stb_vorbis_get_samples_float_interleaved(
            m_vorbis, channels, out, static_cast<int>(frames) * channels);
        if (count <= 0) {
            // The data ended before the granule position said it would (a file cut
            // short), or it is damaged. A cut is the end of the sound; anything
            // else is a failure the log should name.
            const int code = stb_vorbis_get_error(m_vorbis);
            if (code != VORBIS__no_error && code != VORBIS_unexpected_eof && code != VORBIS_need_more_data) {
                m_failed  = true;
                m_failure = std::string("failed to decode Ogg Vorbis audio: ") + ErrorName(code);
            }
            m_position = m_total;
            return 0;
        }
        const auto got = static_cast<std::size_t>(count);
        if (!m_order.empty()) Reorder(out, got);
        m_position += got;
        return got;
    }

    bool rewind() override
    {
        if (stb_vorbis_seek_start(m_vorbis) == 0) {
            m_failed  = true;
            m_failure = "failed to rewind Ogg Vorbis audio";
            return false;
        }
        m_position = 0;
        return true;
    }

    bool               failed() const override { return m_failed; }
    const std::string& failure() const override { return m_failure; }

private:
    void Reorder(float* samples, std::size_t frames)
    {
        const std::size_t channels = m_format.channels;
        float             frame[kMaxChannels];
        for (std::size_t at = 0; at < frames; ++at) {
            float* source = samples + at * channels;
            for (std::size_t channel = 0; channel < channels; ++channel) {
                frame[channel] = source[static_cast<std::size_t>(m_order[channel])];
            }
            std::memcpy(source, frame, channels * sizeof(float));
        }
    }

    std::vector<std::uint8_t> m_bytes; // stb_vorbis reads from these for as long as it is open
    stb_vorbis*               m_vorbis;
    PcmFormat                 m_format;
    std::uint64_t             m_total;
    std::uint64_t             m_position { 0 };
    std::vector<int>          m_order;
    bool                      m_failed { false };
    std::string               m_failure;
};

} // namespace

std::vector<int> VorbisToNativeOrder(std::uint32_t channels)
{
    switch (channels) {
    case 3: return { 0, 2, 1 };
    case 5: return { 0, 2, 1, 3, 4 };
    case 6: return { 0, 2, 1, 5, 3, 4 };
    case 7: return { 0, 2, 1, 6, 5, 3, 4 };
    case 8: return { 0, 2, 1, 7, 5, 6, 3, 4 };
    default: return {};
    }
}

std::unique_ptr<PcmDecoder> OpenVorbisDecoder(const std::shared_ptr<media::ByteSource>& source,
                                              std::string*                              error)
{
    const auto fail = [&](std::string message) -> std::unique_ptr<PcmDecoder> {
        if (error != nullptr) *error = std::move(message);
        return nullptr;
    };
    if (source == nullptr) return fail("audio source must not be null");

    std::vector<std::uint8_t> bytes;
    media::Error              read_error;
    if (!media::ReadVector(*source, 0, source->size(), kMaxFileBytes, &bytes, &read_error)) {
        return fail("failed to read the Ogg Vorbis file: " + media::Describe(read_error));
    }
    if (bytes.empty()) return fail("audio file is empty");

    // stb_vorbis trusts the lengths in the comment header, so check them first.
    if (const std::string problem = CheckHeaders(bytes.data(), bytes.size()); !problem.empty()) {
        return fail("not Ogg Vorbis audio: " + problem);
    }

    int         code   = VORBIS__no_error;
    stb_vorbis* vorbis = stb_vorbis_open_memory(bytes.data(), static_cast<int>(bytes.size()), &code, nullptr);
    if (vorbis == nullptr) return fail(std::string("not Ogg Vorbis audio: ") + ErrorName(code));

    const stb_vorbis_info info = stb_vorbis_get_info(vorbis);
    if (info.channels <= 0 || info.channels > static_cast<int>(kMaxChannels) || info.sample_rate == 0 ||
        info.sample_rate > kMaxSampleRate) {
        stb_vorbis_close(vorbis);
        return fail("the Ogg Vorbis file has an unsupported layout");
    }
    // The length the last Ogg page's granule position gives. stb_vorbis itself would
    // decode up to a block past it, which a loop would hear as silence at the seam.
    // A file cut off before any audio page has no length: it plays what decodes.
    const unsigned length = stb_vorbis_stream_length_in_samples(vorbis);
    // Failing to find a last page leaves its error behind; reading it clears it, so
    // it is not taken for a decoding failure later.
    (void) stb_vorbis_get_error(vorbis);
    const std::uint64_t total = length != 0 ? length : std::numeric_limits<std::uint64_t>::max();
    const PcmFormat format { static_cast<std::uint32_t>(info.channels), info.sample_rate };
    return std::make_unique<VorbisDecoder>(std::move(bytes), vorbis, format, total);
}

} // namespace wallpaper::sound
