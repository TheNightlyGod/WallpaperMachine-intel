#pragma once
#include <memory>
#include <cstdint>
#include <functional>
#include <string>
#include "Utils/Logging.h"
#include "Core/NoCopyMove.hpp"

namespace wallpaper
{

namespace fs
{
class IBinaryStream;
}
namespace audio
{

class SoundStream : NoCopy, NoMove {
public:
    struct Desc {
        uint32_t channels;
        uint32_t sampleRate;
    };
    struct Options {
        bool loop { true };
    };

public:
    SoundStream()          = default;
    virtual ~SoundStream() = default;

    virtual uint64_t NextPcmData(void* pData, uint32_t frameCount) = 0;
    virtual void     PassDesc(const Desc&)                         = 0;
};
std::unique_ptr<SoundStream> CreateSoundStream(std::shared_ptr<fs::IBinaryStream>,
                                               const SoundStream::Desc&,
                                               SoundStream::Options options = {});

class SoundManager : NoCopy, NoMove {
public:
    // Null discards output on miniaudio's null backend (headless tests).
    enum class OutputBackend
    {
        System,
        Null,
    };

    explicit SoundManager(OutputBackend backend = OutputBackend::System);
    ~SoundManager();
    void MountStream(std::unique_ptr<SoundStream>&&);
    void MountStream(std::shared_ptr<SoundStream>);
    void UnMountAll();
    void Play();
    void Pause();
    // True while the output device is started (IO running).
    bool OutputStarted() const;
    // How many times the output device has started, so a start that was stopped again
    // before anyone looked still shows.
    uint64_t OutputStarts() const;

    float Volume() const;
    bool  Muted() const;
    void  SetMuted(bool);
    void  SetVolume(float);

private:
    class impl;
    std::unique_ptr<impl> pImpl;
};
} // namespace audio
} // namespace wallpaper
