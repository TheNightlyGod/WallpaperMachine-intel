// The failure every container reader reports: what went wrong, where in the
// input, and a sentence a log or a refusal reason can carry. Readers return a
// bool and fill an Error, so a caller never has to catch or guess.
#pragma once

#include <cstdint>
#include <string>

namespace wallpaper::media
{

enum class ErrorKind : std::uint8_t {
    None,
    /// The input is a different container than this reader reads.
    NotThisFormat,
    /// The input ends inside a structure that must be complete.
    Truncated,
    /// A field contradicts the format or the rest of the file.
    Corrupt,
    /// Valid, but outside what this reader plays (a codec, a feature).
    Unsupported,
    /// A size, count or time exceeds the reader's fixed limits.
    LimitExceeded,
    /// The byte source itself failed.
    Io,
};

struct Error {
    ErrorKind     kind { ErrorKind::None };
    std::string   message;
    /// Byte offset in the input the problem was found at; 0 when not meaningful.
    std::uint64_t offset { 0 };

    explicit operator bool() const { return kind != ErrorKind::None; }
};

const char* ErrorKindName(ErrorKind kind);

/// "truncated at offset 42: moov box exceeds the file", for logs and reasons.
std::string Describe(const Error& error);

/// Fills `*error` when it is not null, and returns false so a reader can write
/// `return Fail(error, ErrorKind::Corrupt, "...", offset);`.
bool Fail(Error* error, ErrorKind kind, std::string message, std::uint64_t offset = 0);

} // namespace wallpaper::media
