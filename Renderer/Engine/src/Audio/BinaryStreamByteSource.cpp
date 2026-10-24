#include "Audio/BinaryStreamByteSource.hpp"

#include "Fs/IBinaryStream.h"

#include <atomic>
#include <mutex>
#include <utility>

namespace wallpaper::audio
{
namespace
{

class BinaryStreamByteSource final : public media::ByteSource {
public:
    BinaryStreamByteSource(std::shared_ptr<fs::IBinaryStream> stream, std::uint64_t size)
        : m_stream(std::move(stream)), m_size(size)
    {
    }

    std::uint64_t size() const override { return m_size; }

    std::size_t readAt(std::uint64_t offset, void* destination, std::size_t length) const override
    {
        if (offset >= m_size || length == 0) return 0;
        length = static_cast<std::size_t>(std::min<std::uint64_t>(length, m_size - offset));
        std::lock_guard lock { m_mutex };
        if (!m_stream->SeekSet(static_cast<idx>(offset))) {
            m_failed.store(true, std::memory_order_relaxed);
            return 0;
        }
        return static_cast<std::size_t>(m_stream->Read(destination, length));
    }

    bool ioFailed() const override { return m_failed.load(std::memory_order_relaxed); }

private:
    std::shared_ptr<fs::IBinaryStream> m_stream;
    std::uint64_t                      m_size;
    mutable std::mutex                 m_mutex;
    mutable std::atomic<bool>          m_failed { false };
};

} // namespace

std::shared_ptr<media::ByteSource> MakeBinaryStreamByteSource(std::shared_ptr<fs::IBinaryStream> stream)
{
    if (stream == nullptr) return nullptr;
    const auto size = stream->Size();
    if (size < 0) return nullptr;
    return std::make_shared<BinaryStreamByteSource>(std::move(stream), static_cast<std::uint64_t>(size));
}

} // namespace wallpaper::audio
