// Shared by the sound stream tests: an in-memory IBinaryStream, a WAV writer
// for the formats scene sounds use, and a decode loop that reads a stream the
// way the output worker does (fixed-size chunks until it returns 0).
#pragma once

#include "Audio/SoundManager.h"
#include "Fs/IBinaryStream.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <functional>
#include <memory>
#include <numbers>
#include <vector>

namespace wallpaper::audio::testing
{

class MemoryBinaryStream final : public fs::IBinaryStream {
public:
    explicit MemoryBinaryStream(std::vector<uint8_t> data): m_data(std::move(data)) {}

    usize Read(void* buffer, usize sizeInByte) override
    {
        const auto bytes_to_read =
            std::min<usize>(sizeInByte, static_cast<usize>(m_data.size() - m_position));
        if (bytes_to_read > 0) {
            std::memcpy(buffer, m_data.data() + m_position, bytes_to_read);
            m_position += bytes_to_read;
        }
        return bytes_to_read;
    }

    char* Gets(char* buffer, usize sizeStr) override
    {
        if (buffer == nullptr || sizeStr == 0) return buffer;
        usize copied = 0;
        while (copied + 1 < sizeStr && m_position < m_data.size()) {
            const auto byte  = static_cast<char>(m_data[m_position++]);
            buffer[copied++] = byte;
            if (byte == '\n') break;
        }
        buffer[copied] = '\0';
        return copied == 0 ? nullptr : buffer;
    }

    idx  Tell() const override { return static_cast<idx>(m_position); }
    bool SeekSet(idx offset) override
    {
        if (offset < 0 || static_cast<std::size_t>(offset) > m_data.size()) return false;
        m_position = static_cast<std::size_t>(offset);
        return true;
    }
    bool  SeekCur(idx offset) override { return SeekSet(static_cast<idx>(m_position) + offset); }
    bool  SeekEnd(idx offset) override { return SeekSet(static_cast<idx>(m_data.size()) + offset); }
    isize Size() const override { return static_cast<isize>(m_data.size()); }

protected:
    usize Write_impl(const void*, usize) override { return 0; }

private:
    std::vector<uint8_t> m_data;
    std::size_t          m_position { 0 };
};

inline std::shared_ptr<fs::IBinaryStream> MemoryStream(std::vector<uint8_t> bytes)
{
    return std::make_shared<MemoryBinaryStream>(std::move(bytes));
}

template<std::size_t N>
std::vector<uint8_t> Bytes(const uint8_t (&array)[N])
{
    return std::vector<uint8_t>(array, array + N);
}

inline void PutU16(std::vector<uint8_t>& bytes, uint32_t value)
{
    bytes.push_back(static_cast<uint8_t>(value & 0xffu));
    bytes.push_back(static_cast<uint8_t>((value >> 8u) & 0xffu));
}

inline void PutU32(std::vector<uint8_t>& bytes, uint32_t value)
{
    PutU16(bytes, value & 0xffffu);
    PutU16(bytes, value >> 16u);
}

inline void PutTag(std::vector<uint8_t>& bytes, const char (&tag)[5])
{
    bytes.insert(bytes.end(), tag, tag + 4);
}

enum class WavFormat
{
    UInt8,
    Int16,
    Int24,
    Float32,
};

inline uint32_t BytesPerSample(WavFormat format)
{
    switch (format) {
    case WavFormat::UInt8: return 1;
    case WavFormat::Int16: return 2;
    case WavFormat::Int24: return 3;
    case WavFormat::Float32: return 4;
    }
    return 0;
}

/// The reference signal: channel `channel` is a sine of 440 Hz, 660 Hz, ...
/// at amplitude 0.5, so every channel is distinguishable and a swap shows.
inline float IdealSample(double frame, uint32_t channel, double sample_rate)
{
    const double frequency = 440.0 + 220.0 * channel;
    return static_cast<float>(0.5 * std::sin(2.0 * std::numbers::pi * frequency * frame / sample_rate));
}

/// The integer a file of `format` stores for `ideal`.
inline int32_t StoredInteger(WavFormat format, float ideal)
{
    switch (format) {
    case WavFormat::UInt8: return static_cast<int32_t>(std::lround(ideal * 127.0f)) + 128;
    case WavFormat::Int16: return static_cast<int32_t>(std::lround(ideal * 32767.0f));
    case WavFormat::Int24: return static_cast<int32_t>(std::lround(ideal * 8388607.0f));
    case WavFormat::Float32: return 0;
    }
    return 0;
}

/// What a decoder must return for the sample `IdealSample` wrote: the stored
/// integer over its full scale (an 8-bit file is offset by 128).
inline float StoredSample(WavFormat format, float ideal)
{
    const auto value = StoredInteger(format, ideal);
    switch (format) {
    case WavFormat::UInt8: return static_cast<float>(value - 128) / 128.0f;
    case WavFormat::Int16: return static_cast<float>(value) / 32768.0f;
    case WavFormat::Int24: return static_cast<float>(value) / 8388608.0f;
    case WavFormat::Float32: return ideal;
    }
    return 0.0f;
}

/// A WAV file of `frames` frames of the reference signal. `declared_frames`, when
/// not 0, is what the headers claim (a download cut short); `extra_chunk` puts a
/// LIST chunk before the audio, as taggers do.
inline std::vector<uint8_t> MakeWav(WavFormat format, uint32_t channels, uint32_t sample_rate,
                                    uint32_t frames, uint32_t declared_frames = 0,
                                    bool extra_chunk = false)
{
    const uint32_t bytes_per_sample = BytesPerSample(format);
    const uint32_t data_size        = frames * channels * bytes_per_sample;
    const uint32_t declared_size =
        (declared_frames ? declared_frames : frames) * channels * bytes_per_sample;
    const uint32_t list_size = extra_chunk ? 8u + 12u : 0u;
    std::vector<uint8_t> bytes;
    bytes.reserve(44u + list_size + data_size);
    PutTag(bytes, "RIFF");
    PutU32(bytes, 36u + list_size + declared_size);
    PutTag(bytes, "WAVE");
    PutTag(bytes, "fmt ");
    PutU32(bytes, 16);
    PutU16(bytes, format == WavFormat::Float32 ? 3u : 1u);
    PutU16(bytes, channels);
    PutU32(bytes, sample_rate);
    PutU32(bytes, sample_rate * channels * bytes_per_sample);
    PutU16(bytes, channels * bytes_per_sample);
    PutU16(bytes, bytes_per_sample * 8u);
    if (extra_chunk) {
        PutTag(bytes, "LIST");
        PutU32(bytes, 12);
        PutTag(bytes, "INFO");
        PutTag(bytes, "ISFT");
        PutU32(bytes, 0);
    }
    PutTag(bytes, "data");
    PutU32(bytes, declared_size);
    for (uint32_t frame = 0; frame < frames; ++frame) {
        for (uint32_t channel = 0; channel < channels; ++channel) {
            const float ideal = IdealSample(frame, channel, sample_rate);
            if (format == WavFormat::Float32) {
                uint32_t bits;
                std::memcpy(&bits, &ideal, sizeof bits);
                PutU32(bytes, bits);
                continue;
            }
            const auto value = static_cast<uint32_t>(StoredInteger(format, ideal));
            for (uint32_t byte = 0; byte < bytes_per_sample; ++byte) {
                bytes.push_back(static_cast<uint8_t>((value >> (8u * byte)) & 0xffu));
            }
        }
    }
    return bytes;
}

/// Reads `stream` the way the output worker does, in chunks of `chunk` frames
/// until a read returns 0 (or `max_frames` is reached, which a looping stream
/// does by design). Returns interleaved samples at `desc`.
inline std::vector<float> ReadAll(SoundStream& stream, const SoundStream::Desc& desc,
                                  uint32_t chunk = 97, uint64_t max_frames = 1'000'000)
{
    std::vector<float> all;
    std::vector<float> block(static_cast<std::size_t>(chunk) * desc.channels);
    while (all.size() / desc.channels < max_frames) {
        const auto frames = stream.NextPcmData(block.data(), chunk);
        if (frames == 0) break;
        all.insert(all.end(), block.begin(),
                   block.begin() + static_cast<std::ptrdiff_t>(frames * desc.channels));
    }
    return all;
}

inline std::vector<float> Decode(std::vector<uint8_t> bytes, const SoundStream::Desc& desc,
                                 SoundStream::Options options = { .loop = false },
                                 uint32_t chunk = 97)
{
    auto stream = CreateSoundStream(MemoryStream(std::move(bytes)), desc, options);
    if (stream == nullptr) return {};
    return ReadAll(*stream, desc, chunk);
}

} // namespace wallpaper::audio::testing
