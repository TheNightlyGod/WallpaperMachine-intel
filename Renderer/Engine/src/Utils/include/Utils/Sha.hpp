#pragma once
#include <cstdint>
#include <span>
#include <string>

namespace utils
{
constexpr size_t SHA1_LEN = 40;

std::string genSha1(std::span<const char>);

/// SHA-1 of input that arrives in pieces, for content too large to hold: a file read in
/// bounded blocks is hashed as it is read, and the digest is the one `genSha1` gives for the
/// same bytes however they were cut. The input is hashed where it lies, in pieces of at most
/// 64 KiB, and never copied.
class Sha1Stream {
public:
    Sha1Stream();
    ~Sha1Stream();
    Sha1Stream(const Sha1Stream&)            = delete;
    Sha1Stream& operator=(const Sha1Stream&) = delete;

    void Update(std::span<const char> bytes);
    /// The digest as 40 lower-case hex digits. The stream is spent afterwards.
    std::string Finish();

private:
    struct State;
    State* m_state;
};
} // namespace utils
