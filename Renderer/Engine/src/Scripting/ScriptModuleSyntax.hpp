#pragma once

#include <cstddef>
#include <string_view>

namespace wallpaper
{

/// Whether `text` holds the `export` keyword at `position`: where a statement
/// can start -- the beginning, or after whitespace, a line terminator, `;`, `{`
/// or `}` -- and followed by a separator the language accepts there. Whitespace
/// is ECMAScript's, not ASCII's: authors paste scripts from rich-text editors,
/// which put U+00A0 where a space was typed. The module rewrite and both
/// `update` detections decide by this one definition.
bool ExportKeywordAt(std::string_view text, std::size_t position);

/// Whether `source` declares `export function <name>`, with any whitespace the
/// language allows between the tokens.
bool ExportsFunction(std::string_view source, std::string_view name);

} // namespace wallpaper
