#pragma once
#include "Interface/IParticleRawGener.h"
#include <functional>

namespace wallpaper
{

class WPParticleRawGener : public IParticleRawGener {
public:
    WPParticleRawGener() {};
    virtual ~WPParticleRawGener() {};

    virtual void GenGLData(std::span<const std::unique_ptr<ParticleInstance>>, SceneMesh&,
                           ParticleRawGenSpecOp&, ParticleRenderScale render_scale,
                           ParticleOverflowFlags& overflow_flags);
};

} // namespace wallpaper
