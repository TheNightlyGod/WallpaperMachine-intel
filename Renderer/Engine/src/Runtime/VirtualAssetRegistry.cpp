// Clean-room implementation from the WallpaperMachine spec e2-runtime-animation.md; written without access to the original source.
#include "Runtime/VirtualAssetRegistry.hpp"

namespace wallpaper
{
bool InstallVirtualAssets(fs::VFS& vfs)
{
    // The engine supplies no virtual files of its own: nothing reads any, so nothing is mounted.
    (void)vfs;
    return true;
}
} // namespace wallpaper
