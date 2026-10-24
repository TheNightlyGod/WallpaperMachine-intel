#pragma once

#include <string>

namespace wallpaper::shader
{

// Names the compiler build that produced a shader, so a cached result from a
// different one is never reused. Declared apart from the bridge so a renderer
// that only keys a cache by it does not take on the bridge's reflection
// types.
std::string RustShaderCacheIdentity();

} // namespace wallpaper::shader
