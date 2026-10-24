#include "Utils/Sha.hpp"

#include <CommonCrypto/CommonDigest.h>

#include <algorithm>
#include <cstdint>

// The digest names caches and keys them; it is not a security boundary. The
// SDK does not mark CC_SHA1 deprecated, so no warning needs silencing here.
namespace
{
// The most that is handed to the digest at a time.
constexpr std::size_t kPiece = 64 * 1024;

std::string Hex(const std::uint8_t (&digest)[CC_SHA1_DIGEST_LENGTH])
{
    static constexpr char kHex[] = "0123456789abcdef";
    std::string           hex(utils::SHA1_LEN, '0');
    for (std::size_t i = 0; i < CC_SHA1_DIGEST_LENGTH; ++i) {
        hex[2 * i]     = kHex[digest[i] >> 4];
        hex[2 * i + 1] = kHex[digest[i] & 0x0f];
    }
    return hex;
}

void Feed(CC_SHA1_CTX& context, std::span<const char> bytes)
{
    const char* data = bytes.data();
    for (std::size_t left = bytes.size(); left > 0;) {
        const std::size_t piece = std::min(left, kPiece);
        CC_SHA1_Update(&context, data, static_cast<CC_LONG>(piece));
        data += piece;
        left -= piece;
    }
}
} // namespace

struct utils::Sha1Stream::State {
    CC_SHA1_CTX context;
};

utils::Sha1Stream::Sha1Stream() : m_state(new State)
{
    CC_SHA1_Init(&m_state->context);
}

utils::Sha1Stream::~Sha1Stream() { delete m_state; }

void utils::Sha1Stream::Update(std::span<const char> bytes) { Feed(m_state->context, bytes); }

std::string utils::Sha1Stream::Finish()
{
    std::uint8_t digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1_Final(digest, &m_state->context);
    return Hex(digest);
}

std::string utils::genSha1(std::span<const char> in)
{
    CC_SHA1_CTX context;
    CC_SHA1_Init(&context);
    Feed(context, in);
    std::uint8_t digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1_Final(digest, &context);
    return Hex(digest);
}
