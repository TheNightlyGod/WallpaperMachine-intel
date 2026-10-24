#include "Audio/SoundStreamFactory.hpp"

#include "Audio/BinaryStreamByteSource.hpp"
#include "Audio/PcmSoundStream.hpp"
#include "Fs/IBinaryStream.h"
#include "Sound/Apple/AppleDecoder.hpp"
#include "Sound/Vorbis/VorbisDecoder.hpp"

#include <cstring>

namespace wallpaper::audio
{
namespace
{

bool SetError(std::string* error, std::string message)
{
    if (error != nullptr) *error = std::move(message);
    return false;
}

/// True when the stream starts with the Ogg page marker. Content decides, never
/// a file name: a scene's sound can be named anything.
bool IsOgg(fs::IBinaryStream& stream)
{
    char magic[4] {};
    if (!stream.Rewind()) return false;
    const bool ogg = stream.Read(magic, sizeof(magic)) == sizeof(magic) && std::memcmp(magic, "OggS", 4) == 0;
    stream.Rewind();
    return ogg;
}

} // namespace

std::unique_ptr<SoundStream> CreateSceneSoundStream(std::shared_ptr<fs::IBinaryStream> stream,
                                                    std::string*                       error,
                                                    SoundStream::Options               options)
{
    if (stream == nullptr) {
        SetError(error, "VFS audio stream must not be null");
        return nullptr;
    }
    // Ogg Vorbis has no system decoder: the vendored stb_vorbis reads it.
    const bool ogg    = IsOgg(*stream);
    auto       source = MakeBinaryStreamByteSource(std::move(stream));
    if (source == nullptr) {
        SetError(error, "VFS audio stream does not report its size");
        return nullptr;
    }
    auto decoder = ogg ? sound::OpenVorbisDecoder(source, error) : sound::OpenAppleDecoder(std::move(source), error);
    if (decoder == nullptr) return nullptr;
    return std::make_unique<PcmSoundStream>(std::move(decoder), options, "VFS audio stream");
}

} // namespace wallpaper::audio
