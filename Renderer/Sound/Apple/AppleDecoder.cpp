#include "Sound/Apple/AppleDecoder.hpp"

#include <AudioToolbox/AudioToolbox.h>

#include <algorithm>
#include <cstring>
#include <string>
#include <utility>

namespace wallpaper::sound
{
namespace
{

std::string FourCc(OSStatus status)
{
    const auto value = static_cast<std::uint32_t>(status);
    char       text[5] = { static_cast<char>((value >> 24) & 0xff), static_cast<char>((value >> 16) & 0xff),
                           static_cast<char>((value >> 8) & 0xff), static_cast<char>(value & 0xff), 0 };
    const bool printable = std::all_of(text, text + 4, [](char c) { return c >= 32 && c < 127; });
    return printable ? std::string("'") + text + "'" : std::to_string(status);
}

std::string Describe(const char* what, OSStatus status)
{
    return std::string(what) + " (AudioToolbox error " + FourCc(status) + ")";
}

/// The callbacks AudioFile reads the sound through. The source is only read.
struct Reader {
    std::shared_ptr<media::ByteSource> source;
};

OSStatus ReadCallback(void* client, SInt64 position, UInt32 requested, void* buffer, UInt32* actual)
{
    const auto* reader = static_cast<const Reader*>(client);
    if (position < 0) {
        *actual = 0;
        return kAudioFileUnspecifiedError;
    }
    const std::size_t count = reader->source->readAt(static_cast<std::uint64_t>(position), buffer, requested);
    *actual                 = static_cast<UInt32>(count);
    if (reader->source->ioFailed()) return kAudioFileUnspecifiedError;
    // A short read is fine; only a read that starts at the end is the end of the file.
    return count == 0 && requested > 0 ? kAudioFileEndOfFileError : noErr;
}

SInt64 SizeCallback(void* client)
{
    return static_cast<SInt64>(static_cast<const Reader*>(client)->source->size());
}

class AppleDecoder final : public PcmDecoder {
public:
    AppleDecoder(std::unique_ptr<Reader> reader, AudioFileID file, ExtAudioFileRef extended, PcmFormat format)
        : m_reader(std::move(reader)), m_file(file), m_extended(extended), m_format(format)
    {
    }

    ~AppleDecoder() override
    {
        ExtAudioFileDispose(m_extended);
        AudioFileClose(m_file);
    }

    PcmFormat format() const override { return m_format; }

    std::size_t read(float* out, std::size_t frames) override
    {
        if (m_failed || frames == 0) return 0;
        AudioBufferList list {};
        list.mNumberBuffers              = 1;
        list.mBuffers[0].mNumberChannels = m_format.channels;
        list.mBuffers[0].mData           = out;
        list.mBuffers[0].mDataByteSize   = static_cast<UInt32>(frames * m_format.channels * sizeof(float));
        UInt32 count = static_cast<UInt32>(frames);
        const OSStatus status = ExtAudioFileRead(m_extended, &count, &list);
        if (status != noErr) {
            m_failed  = true;
            m_failure = Describe("failed to decode audio", status);
            // Frames decoded before the error are still good.
            return count;
        }
        return count;
    }

    bool rewind() override
    {
        if (m_failed) return false;
        const OSStatus status = ExtAudioFileSeek(m_extended, 0);
        if (status != noErr) {
            m_failed  = true;
            m_failure = Describe("failed to rewind audio", status);
            return false;
        }
        return true;
    }

    bool               failed() const override { return m_failed; }
    const std::string& failure() const override { return m_failure; }

private:
    std::unique_ptr<Reader> m_reader;
    AudioFileID             m_file;
    ExtAudioFileRef         m_extended;
    PcmFormat               m_format;
    bool                    m_failed { false };
    std::string             m_failure;
};

/// True when the source starts with an ISO base media `ftyp` box (MP4, MOV, M4A).
bool IsIsoBaseMedia(const media::ByteSource& source)
{
    std::uint8_t head[8] {};
    return source.readAt(0, head, sizeof head) == sizeof head && std::memcmp(head + 4, "ftyp", 4) == 0;
}

/// What AudioFile is told to expect. 0 lets it sniff the content first; the
/// rest are tried in turn when sniffing finds nothing, because some formats
/// (MP3 without a tag, for one) are only recognised when named.
constexpr AudioFileTypeID kHints[] = {
    0,
    kAudioFileMP3Type,
    kAudioFileWAVEType,
    kAudioFileFLACType,
    kAudioFileAIFFType,
    kAudioFileAIFCType,
    kAudioFileCAFType,
    kAudioFileM4AType,
    kAudioFileMPEG4Type,
    kAudioFileAAC_ADTSType,
};

} // namespace

std::unique_ptr<PcmDecoder> OpenAppleDecoder(std::shared_ptr<media::ByteSource> source,
                                             std::string*                       error,
                                             bool                               audioOptional)
{
    const auto fail = [&](std::string message) -> std::unique_ptr<PcmDecoder> {
        if (error != nullptr) *error = std::move(message);
        return nullptr;
    };
    if (source == nullptr) return fail("audio source must not be null");
    if (source->size() == 0) return fail("audio file is empty");

    auto reader    = std::make_unique<Reader>();
    reader->source = std::move(source);

    AudioFileID file   = nullptr;
    OSStatus    status = kAudioFileUnspecifiedError;
    // AudioFile answers a video-only MP4 or MOV with "invalid file", the same as a
    // damaged one. An ISO base media file (an `ftyp` box first) that it rejects is
    // taken to have no audio; that is what a silent video is, and it is told apart
    // from a file the system does not recognise at all.
    const bool isoBmff = IsIsoBaseMedia(*reader->source);
    bool recognisedWithoutAudio = false;
    for (const AudioFileTypeID hint : kHints) {
        status = AudioFileOpenWithCallbacks(reader.get(), ReadCallback, nullptr, SizeCallback, nullptr, hint, &file);
        if (status == noErr) break;
        file = nullptr;
        if (status == kAudioFileInvalidFileError && isoBmff) recognisedWithoutAudio = true;
        if (reader->source->ioFailed()) break;
    }
    if (file == nullptr) {
        if (recognisedWithoutAudio && audioOptional) {
            // Silent on purpose: not an error, and nothing to report.
            if (error != nullptr) error->clear();
            return nullptr;
        }
        return fail(Describe(recognisedWithoutAudio ? "the file has no audio the system can decode"
                                                    : "not audio the system can decode",
                             status));
    }

    ExtAudioFileRef extended = nullptr;
    status                   = ExtAudioFileWrapAudioFileID(file, false, &extended);
    if (status != noErr) {
        AudioFileClose(file);
        return fail(Describe("failed to open the audio file", status));
    }

    AudioStreamBasicDescription native {};
    UInt32                      size = sizeof(native);
    status = ExtAudioFileGetProperty(extended, kExtAudioFileProperty_FileDataFormat, &size, &native);
    if (status != noErr || native.mChannelsPerFrame == 0 || native.mSampleRate < 1.0) {
        ExtAudioFileDispose(extended);
        AudioFileClose(file);
        return fail(Describe("the audio file has no usable format", status));
    }

    // The client format is the file's own layout as 32-bit float: the decoder
    // changes the sample format and nothing else, so remixing and resampling
    // stay the pipeline's, the same for every decoder.
    AudioStreamBasicDescription client {};
    client.mSampleRate       = native.mSampleRate;
    client.mFormatID         = kAudioFormatLinearPCM;
    client.mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    client.mChannelsPerFrame = native.mChannelsPerFrame;
    client.mBitsPerChannel   = 32;
    client.mBytesPerFrame    = 4 * native.mChannelsPerFrame;
    client.mFramesPerPacket  = 1;
    client.mBytesPerPacket   = client.mBytesPerFrame;
    status = ExtAudioFileSetProperty(extended, kExtAudioFileProperty_ClientDataFormat, sizeof(client), &client);
    if (status != noErr) {
        ExtAudioFileDispose(extended);
        AudioFileClose(file);
        return fail(Describe("the system cannot decode this audio format", status));
    }

    const PcmFormat format { native.mChannelsPerFrame, static_cast<std::uint32_t>(native.mSampleRate + 0.5) };
    return std::make_unique<AppleDecoder>(std::move(reader), file, extended, format);
}

} // namespace wallpaper::sound
