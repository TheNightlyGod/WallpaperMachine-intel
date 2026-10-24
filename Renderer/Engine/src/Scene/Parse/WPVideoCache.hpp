#pragma once

#include <string>
#include <string_view>

namespace wallpaper
{
namespace fs
{
class IBinaryStream;
}

/// Makes a clip that lives inside a package playable from a path, without ever holding it in
/// memory: its bytes are streamed in 1 MiB pieces into a file of the temp directory named by
/// the clip's content (SHA-1, hashed first, as the stream is read), and that path is returned.
///
/// The file is copied only when no entry of that name is there already. It is written under a
/// staging name and published in one step, so another opener never finds a half-written file
/// at the content's name, and an entry that is already there (a whole one) is never replaced.
///
/// `extension` is the clip's own, with its dot, and ends the entry's name so that the file
/// identifies as the kind of media it is. Empty when the stream cannot be read whole or the
/// entry cannot be written.
std::string CacheVideoByContent(fs::IBinaryStream& clip, std::string_view extension);

} // namespace wallpaper
