#include "Media/Error.hpp"

#include <utility>

namespace wallpaper::media
{

const char* ErrorKindName(ErrorKind kind)
{
    switch (kind) {
    case ErrorKind::None: return "no error";
    case ErrorKind::NotThisFormat: return "not this format";
    case ErrorKind::Truncated: return "truncated";
    case ErrorKind::Corrupt: return "corrupt";
    case ErrorKind::Unsupported: return "unsupported";
    case ErrorKind::LimitExceeded: return "limit exceeded";
    case ErrorKind::Io: return "read failed";
    }
    return "unknown error";
}

std::string Describe(const Error& error)
{
    std::string text = ErrorKindName(error.kind);
    if (error.kind == ErrorKind::None) return text;
    if (error.offset != 0) text += " at offset " + std::to_string(error.offset);
    if (! error.message.empty()) text += ": " + error.message;
    return text;
}

bool Fail(Error* error, ErrorKind kind, std::string message, std::uint64_t offset)
{
    if (error != nullptr) {
        error->kind    = kind;
        error->message = std::move(message);
        error->offset  = offset;
    }
    return false;
}

} // namespace wallpaper::media
