// Lets the new sound decoders read a scene's sound through the engine's
// virtual file system: a ByteSource over an fs::IBinaryStream. Reads are
// positioned (seek, then read) and serialised, so the decoders' random access
// is safe on a stream that has one position.
#pragma once

#include "Media/ByteSource.hpp"

#include <memory>

namespace wallpaper::fs
{
class IBinaryStream;
}

namespace wallpaper::audio
{

/// Returns null when the stream is null or does not know its size.
std::shared_ptr<media::ByteSource> MakeBinaryStreamByteSource(std::shared_ptr<fs::IBinaryStream> stream);

} // namespace wallpaper::audio
