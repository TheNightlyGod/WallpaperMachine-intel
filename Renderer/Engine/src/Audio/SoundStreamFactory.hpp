// How the engine turns a scene's encoded sound into a SoundStream. Callers name
// no decoder: which one serves a file is decided here, and a decoder can be
// replaced without touching them.
#pragma once

#include "Audio/SoundManager.h"

#include <memory>
#include <string>

namespace wallpaper::fs
{
class IBinaryStream;
}

namespace wallpaper::audio
{

/// A scene's sound: the whole file, read from the scene's package. Returns null
/// and fills `error` when the file is not audio the engine can decode, so the
/// layer stays silent. The stream still needs `PassDesc` before it is read.
std::unique_ptr<SoundStream> CreateSceneSoundStream(std::shared_ptr<fs::IBinaryStream> stream,
                                                    std::string*                       error,
                                                    SoundStream::Options               options = {});

} // namespace wallpaper::audio
