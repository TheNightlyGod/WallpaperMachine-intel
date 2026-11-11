#pragma once

#include <cstdint>

// The noise functions of Wallpaper Engine 2.8.0.42's particle system, from the
// decompile (artifacts/we-parity/decompiles/F-D1.md, F-D2.md, F-D3.md, F-D4.md,
// F-D11.md). The simplex ones share Ken Perlin's 256-entry permutation; all are
// computed in single precision, as the engine computes them.

namespace wallpaper::ParticleNoise
{

/// 3D simplex noise (Gustavson, 12 cube-edge gradients, t = 0.6 - |d|^2,
/// contribution t^4 * dot), times 32: 0x1400FC220. The `turbulence` field.
float Simplex3(float x, float y, float z);

/// 2D simplex noise with the engine's gradient pick and scale 45.23065:
/// 0x14027B170. The octaves of `positionoffsetrandom`.
float Simplex2(float x, float y);

/// 1D simplex noise (gradient 1 + (h & 7), negated when h & 8), times 0.395:
/// 0x14027B090. The heading of `turbulentvelocityrandom`.
float Simplex1(float x);

/// `octaves` layers of Simplex2, frequency doubling and amplitude halving,
/// divided by the amplitude sum (0x14023B340, positionoffsetrandom case).
float Fbm2(float x, float y, int octaves);

/// The engine's global noise object's 2D noise (0x1400FB820): FastNoise-style
/// OpenSimplex2 with hashed corners (primes 501125321 / 1136930381, hash times
/// 0x27D4EB2D), gradient x * 2.4142136 + y, scale 38.283688. The `simplexnoise`
/// transform of `remapvalue`.
float OpenSimplex2(std::int32_t seed, float x, float y);

/// That object's fbm (0x1400FB570 with the amplitude normaliser 0x1400FB740):
/// `octaves` layers of OpenSimplex2, frequency doubling, amplitude halving from
/// 1 / sum(0.5^o), seed one higher per layer. The `fbmnoise` transform.
float OpenSimplex2Fbm(std::int32_t seed, float x, float y, int octaves);

} // namespace wallpaper::ParticleNoise
