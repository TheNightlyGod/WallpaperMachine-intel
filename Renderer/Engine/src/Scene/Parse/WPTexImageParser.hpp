#pragma once
#include "Interface/IImageParser.h"
#include "Fs/VFS.h"

#include <string>

namespace wallpaper
{
/// True when `name` is an absolute path to a picture or video on this machine
/// that can be opened right now. A `scenetexture` property holds the path the
/// user picked, not a copy of the file, so the file can be moved, deleted, or
/// out of reach of a sandboxed process: each of those has to leave the slot on
/// the texture the wallpaper shipped rather than on a name that decodes to
/// nothing.
bool HostLooseAssetIsReadable(std::string_view name);


class WPTexImageParser : public IImageParser {
public:
    WPTexImageParser(fs::VFS* vfs): m_vfs(vfs) {}
    virtual ~WPTexImageParser() = default;

    std::shared_ptr<Image> Parse(const std::string&) override;
    ImageHeader            ParseHeader(const std::string&) override;

private:
    std::shared_ptr<Image> ParseLooseAsset(const std::string& name);
    ImageHeader            ParseLooseAssetHeader(const std::string& name);

    fs::VFS* m_vfs;
};
} // namespace wallpaper
