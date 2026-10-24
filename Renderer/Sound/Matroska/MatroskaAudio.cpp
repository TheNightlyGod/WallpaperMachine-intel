#include "Sound/Matroska/MatroskaAudio.hpp"

#include "Media/ByteSource.hpp"
#include "Sound/Matroska/OggVorbisFraming.hpp"
#include "Sound/Vorbis/VorbisDecoder.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <utility>
#include <vector>

#ifdef __APPLE__
#include <AudioToolbox/AudioToolbox.h>
#endif

namespace wallpaper::sound
{

std::uint32_t OpusPacketFrames(const std::uint8_t* packet, std::size_t size)
{
    if (packet == nullptr || size == 0) return 0;
    const unsigned config = packet[0] >> 3U;
    const unsigned code   = packet[0] & 3U;
    // Samples at 48 kHz in one frame: SILK 10, 20, 40 and 60 ms, hybrid 10 and 20 ms,
    // CELT 2.5, 5, 10 and 20 ms (RFC 6716, table 2).
    std::uint32_t frame = 0;
    if (config < 12) {
        static constexpr std::uint32_t kSilk[4] = { 480, 960, 1920, 2880 };
        frame                                   = kSilk[config % 4];
    } else if (config < 16) {
        frame = (config % 2) == 0 ? 480 : 960;
    } else {
        static constexpr std::uint32_t kCelt[4] = { 120, 240, 480, 960 };
        frame                                   = kCelt[config % 4];
    }
    std::uint32_t count = 1;
    if (code == 1 || code == 2) {
        count = 2;
    } else if (code == 3) {
        if (size < 2) return 0;
        count = packet[1] & 0x3FU;
        if (count == 0) return 0;
    }
    const std::uint32_t total = frame * count;
    // A packet holds at most 120 ms.
    return total > 5760 ? 0 : total;
}

namespace
{

std::unique_ptr<PcmDecoder> Fail(std::string* error, std::string message)
{
    if (error != nullptr) *error = std::move(message);
    return nullptr;
}

// --- Vorbis ----------------------------------------------------------------------

std::unique_ptr<PcmDecoder> OpenVorbis(const std::shared_ptr<media::MatroskaReader>& reader, std::size_t trackIndex,
                                       const MatroskaAudioLimits& limits, std::string* error)
{
    const media::MatroskaTrack& track   = reader->tracks()[trackIndex];
    const auto&                 packets = reader->packets(trackIndex);
    VorbisHeaders               headers;
    std::string                 why;
    if (!SplitVorbisCodecPrivate(track.codecPrivate, &headers, &why)) return Fail(error, why);
    if (packets.empty()) return Fail(error, "the Vorbis track has no packets");

    std::uint64_t bytes = 0;
    for (const auto& packet : packets) bytes += packet.size;
    if (bytes > limits.maxVorbisBytes) return Fail(error, "the Vorbis track is too large to decode in memory");

    // The identification header's sample rate (little endian, after the 7-byte tag,
    // the version and the channel count).
    const std::uint64_t rate = static_cast<std::uint64_t>(headers[0][12]) | static_cast<std::uint64_t>(headers[0][13]) << 8 |
                               static_cast<std::uint64_t>(headers[0][14]) << 16 | static_cast<std::uint64_t>(headers[0][15]) << 24;
    // Where the sound ends: the last packet's time plus its length, from the block's
    // duration or, failing that, the spacing of the last two packets.
    const auto& last = packets.back();
    std::int64_t lastLength = last.durationNs;
    if (lastLength <= 0 && packets.size() > 1) lastLength = last.ptsNs - packets[packets.size() - 2].ptsNs;
    const std::int64_t lengthNs = std::max<std::int64_t>(0, last.ptsNs + std::max<std::int64_t>(0, lastLength) - packets.front().ptsNs);
    const std::uint64_t totalFrames =
        static_cast<std::uint64_t>(static_cast<long double>(lengthNs) * static_cast<long double>(rate) / 1e9L);

    OggVorbisWriter           writer;
    std::vector<std::uint8_t> packet;
    writer.writeHeaders(headers);
    for (std::size_t index = 0; index < packets.size(); ++index) {
        media::Error readError;
        if (!reader->readPacket(trackIndex, index, &packet, &readError)) {
            return Fail(error, "the Vorbis track could not be read: " + media::Describe(readError));
        }
        writer.writePacket(packet.data(), packet.size());
    }
    writer.finish(totalFrames);
    return OpenVorbisDecoder(media::MakeMemoryByteSource(writer.take()), error);
}

// --- Opus, AAC and MP3 ---------------------------------------------------------

#ifdef __APPLE__

// 'nomo': what the supply function answers when the converter asks for input past the one packet.
constexpr OSStatus kNoMoreInput = static_cast<OSStatus>(0x6E6F6D6F);

/// One Matroska audio track decoded packet by packet with an AudioToolbox converter.
class PacketDecoder final : public PcmDecoder {
public:
    /// What the converter is made from, kept so a rewind can make a fresh one.
    struct Config {
        AudioStreamBasicDescription input {};
        AudioStreamBasicDescription output {};
        std::vector<std::uint8_t>   cookie;
        std::uint32_t               skipFrames { 0 };
        float                       gain { 1.0f };
        bool                        opus { false };
    };

    PacketDecoder(std::shared_ptr<media::MatroskaReader> reader, std::size_t trackIndex, Config config, PcmFormat format)
        : m_reader(std::move(reader)), m_trackIndex(trackIndex), m_config(std::move(config)), m_format(format),
          m_skip(m_config.skipFrames), m_opus(m_config.opus), m_gain(m_config.gain)
    {
        m_decoded.resize(static_cast<std::size_t>(kMaxFrames) * format.channels);
    }

    /// Makes the converter. False when the system refuses the formats.
    OSStatus makeConverter()
    {
        if (m_converter != nullptr) AudioConverterDispose(m_converter);
        m_converter = nullptr;
        const OSStatus status = AudioConverterNew(&m_config.input, &m_config.output, &m_converter);
        if (status != noErr) return status;
        if (!m_config.cookie.empty()) {
            AudioConverterSetProperty(m_converter, kAudioConverterDecompressionMagicCookie,
                                      static_cast<UInt32>(m_config.cookie.size()), m_config.cookie.data());
        }
        m_calibrated = false;
        return noErr;
    }

    ~PacketDecoder() override
    {
        if (m_converter != nullptr) AudioConverterDispose(m_converter);
    }

    PcmFormat format() const override { return m_format; }

    std::size_t read(float* out, std::size_t frames) override
    {
        std::size_t produced = 0;
        const std::size_t channels = m_format.channels;
        while (produced < frames) {
            if (m_position < m_available) {
                const std::size_t count = std::min(frames - produced, m_available - m_position);
                std::memcpy(out + produced * channels, m_decoded.data() + m_position * channels,
                            count * channels * sizeof(float));
                m_position += count;
                produced += count;
                continue;
            }
            if (m_failed || !decodeNext()) break;
        }
        return produced;
    }

    bool rewind() override
    {
        // A fresh converter, not a reset one: the system's Opus decoder trims its own delay
        // from the first packet it is given and a reset converter does not do it again.
        if (makeConverter() != noErr) {
            m_failed  = true;
            m_failure = "failed to restart the audio decoder";
            return false;
        }
        m_next      = 0;
        m_skip      = m_config.skipFrames;
        m_available = 0;
        m_position  = 0;
        return true;
    }

    bool               failed() const override { return m_failed; }
    const std::string& failure() const override { return m_failure; }

private:
    static constexpr UInt32 kMaxFrames = 8192;

    struct Input {
        const std::uint8_t*          data { nullptr };
        UInt32                       size { 0 };
        AudioStreamPacketDescription description {};
        bool                         given { false };
    };

    static OSStatus Supply(AudioConverterRef, UInt32* packets, AudioBufferList* data,
                           AudioStreamPacketDescription** descriptions, void* user)
    {
        auto* input = static_cast<Input*>(user);
        if (input->given) {
            *packets = 0;
            return kNoMoreInput;
        }
        input->given                     = true;
        *packets                         = 1;
        data->mNumberBuffers             = 1;
        data->mBuffers[0].mNumberChannels = 0;
        data->mBuffers[0].mData          = const_cast<std::uint8_t*>(input->data);
        data->mBuffers[0].mDataByteSize  = input->size;
        if (descriptions != nullptr) *descriptions = &input->description;
        return noErr;
    }

    /// Decodes packets until one gives frames to play, or the track ends.
    bool decodeNext()
    {
        const auto& packets = m_reader->packets(m_trackIndex);
        while (m_next < packets.size()) {
            const std::size_t index = m_next++;
            media::Error      readError;
            if (!m_reader->readPacket(m_trackIndex, index, &m_packet, &readError)) {
                m_failed  = true;
                m_failure = "failed to read audio: " + media::Describe(readError);
                return false;
            }
            if (m_packet.empty()) continue;
            Input input;
            input.data                              = m_packet.data();
            input.size                              = static_cast<UInt32>(m_packet.size());
            input.description.mStartOffset          = 0;
            input.description.mDataByteSize         = input.size;
            input.description.mVariableFramesInPacket = m_opus ? OpusPacketFrames(m_packet.data(), m_packet.size()) : 0;
            if (m_opus && input.description.mVariableFramesInPacket == 0) continue;  // not an Opus packet

            AudioBufferList list {};
            list.mNumberBuffers              = 1;
            list.mBuffers[0].mNumberChannels = m_format.channels;
            list.mBuffers[0].mData           = m_decoded.data();
            list.mBuffers[0].mDataByteSize   = kMaxFrames * m_format.channels * static_cast<UInt32>(sizeof(float));
            UInt32 frames                    = kMaxFrames;
            const OSStatus status = AudioConverterFillComplexBuffer(m_converter, &Supply, &input, &frames, &list, nullptr);
            if (status != noErr && status != kNoMoreInput) {
                // A packet the decoder rejects is skipped: one bad packet is a click, not the end.
                continue;
            }
            if (m_opus && !m_calibrated) {
                // The first packet of a fresh Opus converter comes back shorter than it is:
                // the system has already dropped part of the decoder's delay. What it dropped
                // counts toward the pre-skip the stream asks for.
                m_calibrated = true;
                const std::uint32_t expected = input.description.mVariableFramesInPacket;
                const std::uint32_t dropped  = expected > frames ? expected - frames : 0;
                m_skip                       = m_skip > dropped ? m_skip - dropped : 0;
            }
            std::size_t begin = 0;
            std::size_t end   = frames;
            if (m_skip > 0) {
                const std::size_t drop = std::min<std::size_t>(m_skip, end);
                begin += drop;
                m_skip -= static_cast<std::uint32_t>(drop);
            }
            const std::int32_t padding = packets[index].discardPaddingNs;
            if (padding > 0) {
                const auto drop = static_cast<std::size_t>(static_cast<double>(padding) * m_format.sampleRate / 1e9);
                end              = drop >= end - begin ? begin : end - drop;
            }
            if (end <= begin) continue;
            const std::size_t channels = m_format.channels;
            if (begin != 0) std::memmove(m_decoded.data(), m_decoded.data() + begin * channels, (end - begin) * channels * sizeof(float));
            m_available = end - begin;
            m_position  = 0;
            if (m_gain != 1.0f) {
                for (std::size_t at = 0; at < m_available * channels; ++at) m_decoded[at] *= m_gain;
            }
            return true;
        }
        return false;
    }

    std::shared_ptr<media::MatroskaReader> m_reader;
    std::size_t                            m_trackIndex;
    Config                                 m_config;
    AudioConverterRef                      m_converter { nullptr };
    PcmFormat                              m_format;
    std::uint32_t                          m_skip;
    bool                                   m_opus;
    float                                  m_gain;
    bool                                   m_calibrated { false };
    std::size_t                            m_next { 0 };
    std::vector<std::uint8_t>              m_packet;
    std::vector<float>                     m_decoded;
    std::size_t                            m_available { 0 };
    std::size_t                            m_position { 0 };
    bool                                   m_failed { false };
    std::string                            m_failure;
};

std::uint32_t LittleEndian16(const std::uint8_t* at) { return static_cast<std::uint32_t>(at[0]) | static_cast<std::uint32_t>(at[1]) << 8; }

/// An AudioSpecificConfig wrapped in the MPEG-4 elementary stream descriptor Core Audio
/// takes as an AAC decoder's magic cookie (ISO/IEC 14496-1: an ES_Descriptor holding a
/// DecoderConfigDescriptor, which holds the DecoderSpecificInfo, and an SLConfigDescriptor).
/// Lengths use the one-byte form, which holds for any config short of 100 bytes.
std::vector<std::uint8_t> AacMagicCookie(const std::vector<std::uint8_t>& audioSpecificConfig)
{
    const auto size = static_cast<std::uint8_t>(audioSpecificConfig.size());
    std::vector<std::uint8_t> specific { 0x05, size };
    specific.insert(specific.end(), audioSpecificConfig.begin(), audioSpecificConfig.end());
    // object type 0x40 (MPEG-4 audio), stream type 5 (audio, upstream 0, reserved 1), buffer size and bitrates unknown
    std::vector<std::uint8_t> config { 0x40, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    config.insert(config.end(), specific.begin(), specific.end());
    std::vector<std::uint8_t> decoderConfig { 0x04, static_cast<std::uint8_t>(config.size()) };
    decoderConfig.insert(decoderConfig.end(), config.begin(), config.end());
    // ES_ID 0, no flags; SLConfigDescriptor predefined 2 (MP4 file)
    std::vector<std::uint8_t> stream { 0, 0, 0 };
    stream.insert(stream.end(), decoderConfig.begin(), decoderConfig.end());
    stream.insert(stream.end(), { 0x06, 0x01, 0x02 });
    std::vector<std::uint8_t> cookie { 0x03, static_cast<std::uint8_t>(stream.size()) };
    cookie.insert(cookie.end(), stream.begin(), stream.end());
    return cookie;
}

std::unique_ptr<PcmDecoder> OpenPacketDecoder(const std::shared_ptr<media::MatroskaReader>& reader, std::size_t trackIndex,
                                              std::string* error)
{
    const media::MatroskaTrack& track = reader->tracks()[trackIndex];
    if (reader->packets(trackIndex).empty()) return Fail(error, "the audio track has no packets");

    PacketDecoder::Config config;
    AudioStreamBasicDescription& input = config.input;

    switch (track.codec) {
    case media::MatroskaCodec::Opus: {
        // OpusHead (RFC 7845 section 5.1): "OpusHead", version, channels, pre-skip,
        // input rate, output gain (Q7.8 dB), channel mapping family.
        const auto& head = track.codecPrivate;
        if (head.size() < 19 || std::memcmp(head.data(), "OpusHead", 8) != 0) return Fail(error, "the Opus track has no OpusHead record");
        const std::uint32_t channels = head[9];
        const std::uint32_t family   = head[18];
        if (family != 0 || channels < 1 || channels > 2) {
            return Fail(error, "Opus audio with " + std::to_string(channels) + " channels (mapping family " +
                                   std::to_string(family) + ") is not decoded");
        }
        config.skipFrames = LittleEndian16(head.data() + 10);
        const auto gainQ8 = static_cast<std::int16_t>(LittleEndian16(head.data() + 16));
        if (gainQ8 != 0) config.gain = static_cast<float>(std::pow(10.0, static_cast<double>(gainQ8) / (20.0 * 256.0)));
        input.mSampleRate       = 48000;
        input.mFormatID         = kAudioFormatOpus;
        input.mChannelsPerFrame = channels;
        config.opus             = true;
        break;
    }
    case media::MatroskaCodec::Aac: {
        if (track.codecPrivate.size() < 2 || track.codecPrivate.size() > 100) return Fail(error, "the AAC track has no usable AudioSpecificConfig");
        config.cookie           = AacMagicCookie(track.codecPrivate);
        input.mFormatID         = kAudioFormatMPEG4AAC;
        UInt32 size             = sizeof(input);
        if (AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, static_cast<UInt32>(config.cookie.size()),
                                   config.cookie.data(), &size, &input) != noErr) {
            return Fail(error, "the AAC track's AudioSpecificConfig was not understood");
        }
        if (input.mSampleRate <= 0) input.mSampleRate = track.samplingFrequency;
        if (input.mChannelsPerFrame == 0) input.mChannelsPerFrame = track.channels;
        if (input.mFramesPerPacket == 0) input.mFramesPerPacket = 1024;
        break;
    }
    case media::MatroskaCodec::Mp3:
        input.mFormatID         = kAudioFormatMPEGLayer3;
        input.mSampleRate       = track.samplingFrequency;
        input.mChannelsPerFrame = track.channels;
        input.mFramesPerPacket  = track.samplingFrequency >= 32000 ? 1152 : 576;
        break;
    default: return Fail(error, "audio codec " + track.codecId + " is not decoded");
    }
    if (input.mSampleRate < 8000 || input.mSampleRate > 192000 || input.mChannelsPerFrame < 1 || input.mChannelsPerFrame > 2) {
        return Fail(error, track.codecId + " audio with " + std::to_string(input.mChannelsPerFrame) + " channels at " +
                               std::to_string(static_cast<long>(input.mSampleRate)) + " Hz is not decoded");
    }

    AudioStreamBasicDescription& output = config.output;
    output.mSampleRate       = input.mSampleRate;
    output.mFormatID         = kAudioFormatLinearPCM;
    output.mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    output.mChannelsPerFrame = input.mChannelsPerFrame;
    output.mBitsPerChannel   = 32;
    output.mBytesPerFrame    = 4 * output.mChannelsPerFrame;
    output.mFramesPerPacket  = 1;
    output.mBytesPerPacket   = output.mBytesPerFrame;

    const PcmFormat format { input.mChannelsPerFrame, static_cast<std::uint32_t>(input.mSampleRate) };
    auto            decoder = std::make_unique<PacketDecoder>(reader, trackIndex, std::move(config), format);
    if (const OSStatus created = decoder->makeConverter(); created != noErr) {
        return Fail(error, track.codecId + " audio is not decoded by this Mac (error " + std::to_string(created) + ")");
    }
    return decoder;
}

#endif // __APPLE__

} // namespace

std::unique_ptr<PcmDecoder> OpenMatroskaAudio(std::shared_ptr<media::MatroskaReader> reader, std::size_t trackIndex,
                                              std::string* error, const MatroskaAudioLimits& limits)
{
    if (reader == nullptr || trackIndex >= reader->tracks().size() ||
        reader->tracks()[trackIndex].type != media::MatroskaTrackType::Audio) {
        return Fail(error, "no audio track");
    }
    const media::MatroskaTrack& track = reader->tracks()[trackIndex];
    if (!track.supported) return Fail(error, track.unsupportedReason.empty() ? "the audio track is not supported" : track.unsupportedReason);
    if (track.codec == media::MatroskaCodec::Vorbis) return OpenVorbis(reader, trackIndex, limits, error);
#ifdef __APPLE__
    return OpenPacketDecoder(reader, trackIndex, error);
#else
    return Fail(error, "audio codec " + track.codecId + " is not decoded on this platform");
#endif
}

} // namespace wallpaper::sound
