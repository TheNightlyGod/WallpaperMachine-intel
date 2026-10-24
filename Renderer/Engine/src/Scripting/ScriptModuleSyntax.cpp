#include "Scripting/ScriptModuleSyntax.hpp"

namespace wallpaper
{
namespace
{

constexpr std::string_view kExport = "export";

/// The byte length of the ECMAScript WhiteSpace or LineTerminator code point that
/// starts at `position` in UTF-8 `text`, zero when there is none: TAB, VT, FF,
/// SP, NBSP, ZWNBSP (U+FEFF), the other Zs code points, LF, CR, LS and PS.
/// U+FEFF is not Unicode White_Space, so a generic whitespace test misses it.
std::size_t JsWhitespaceLength(std::string_view text, std::size_t position) {
    if (position >= text.size()) return 0;
    const auto byte = [&](std::size_t offset) -> unsigned {
        return position + offset < text.size() ? static_cast<unsigned char>(text[position + offset])
                                               : 0u;
    };
    const unsigned lead = byte(0);
    if (lead == ' ' || lead == '\t' || lead == '\n' || lead == '\r' || lead == '\v' ||
        lead == '\f') {
        return 1;
    }
    if (lead == 0xC2 && byte(1) == 0xA0) return 2; // U+00A0
    if (lead == 0xE1 && byte(1) == 0x9A && byte(2) == 0x80) return 3; // U+1680
    if (lead == 0xE2 && byte(1) == 0x80 &&
        ((byte(2) >= 0x80 && byte(2) <= 0x8A) || byte(2) == 0xA8 || byte(2) == 0xA9 ||
         byte(2) == 0xAF)) {
        return 3; // U+2000..U+200A, U+2028, U+2029, U+202F
    }
    if (lead == 0xE2 && byte(1) == 0x81 && byte(2) == 0x9F) return 3; // U+205F
    if (lead == 0xE3 && byte(1) == 0x80 && byte(2) == 0x80) return 3; // U+3000
    if (lead == 0xEF && byte(1) == 0xBB && byte(2) == 0xBF) return 3; // U+FEFF
    return 0;
}

/// Whether a whitespace or line-terminator code point ends just before `position`.
bool JsWhitespaceEndsAt(std::string_view text, std::size_t position) {
    for (std::size_t length = 1; length <= 3 && length <= position; ++length) {
        if (JsWhitespaceLength(text, position - length) == length) return true;
    }
    return false;
}

std::size_t SkipJsWhitespace(std::string_view text, std::size_t position) {
    while (const std::size_t length = JsWhitespaceLength(text, position)) position += length;
    return position;
}

bool ContinuesIdentifier(std::string_view text, std::size_t position) {
    if (position >= text.size() || JsWhitespaceLength(text, position) != 0) return false;
    const auto byte = static_cast<unsigned char>(text[position]);
    // Any other non-ASCII code point may be part of an identifier.
    return byte >= 0x80 || (byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'z') ||
           (byte >= 'A' && byte <= 'Z') || byte == '_' || byte == '$';
}

} // namespace

bool ExportKeywordAt(std::string_view text, std::size_t position) {
    if (text.substr(position, kExport.size()) != kExport) return false;
    // Not the tail of an identifier or a member: `reexport`, `module.export`.
    if (position != 0 && ! JsWhitespaceEndsAt(text, position)) {
        const char before = text[position - 1];
        if (before != ';' && before != '{' && before != '}') return false;
    }
    return JsWhitespaceLength(text, position + kExport.size()) != 0;
}

bool ExportsFunction(std::string_view source, std::string_view name) {
    constexpr std::string_view function = "function";
    for (std::size_t at = source.find(kExport); at != std::string_view::npos;
         at = source.find(kExport, at + 1)) {
        if (! ExportKeywordAt(source, at)) continue;
        const std::size_t keyword = SkipJsWhitespace(source, at + kExport.size());
        if (source.substr(keyword, function.size()) != function) continue;
        const std::size_t identifier = SkipJsWhitespace(source, keyword + function.size());
        if (identifier == keyword + function.size()) continue; // `functionupdate`
        if (source.substr(identifier, name.size()) != name) continue;
        if (ContinuesIdentifier(source, identifier + name.size())) continue; // `updateAll`
        return true;
    }
    return false;
}

} // namespace wallpaper
