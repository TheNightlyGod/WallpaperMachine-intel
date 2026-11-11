// Clean-room port of the noise functions read off Wallpaper Engine 2.8.0.42's
// decompile; see include/Particle/ParticleNoise.h.
#include "ParticleNoise.h"

#include <algorithm>
#include <array>
#include <bit>
#include <cstdint>

namespace wallpaper::ParticleNoise
{
namespace
{

constexpr std::array<std::uint8_t, 256> kPermutation = {
    151, 160, 137, 91,  90,  15,  131, 13,  201, 95,  96,  53,  194, 233, 7,   225, 140, 36,  103,
    30,  69,  142, 8,   99,  37,  240, 21,  10,  23,  190, 6,   148, 247, 120, 234, 75,  0,   26,
    197, 62,  94,  252, 219, 203, 117, 35,  11,  32,  57,  177, 33,  88,  237, 149, 56,  87,  174,
    20,  125, 136, 171, 168, 68,  175, 74,  165, 71,  134, 139, 48,  27,  166, 77,  146, 158, 231,
    83,  111, 229, 122, 60,  211, 133, 230, 220, 105, 92,  41,  55,  46,  245, 40,  244, 102, 143,
    54,  65,  25,  63,  161, 1,   216, 80,  73,  209, 76,  132, 187, 208, 89,  18,  169, 200, 196,
    135, 130, 116, 188, 159, 86,  164, 100, 109, 198, 173, 186, 3,   64,  52,  217, 226, 250, 124,
    123, 5,   202, 38,  147, 118, 126, 255, 82,  85,  212, 207, 206, 59,  227, 47,  16,  58,  17,
    182, 189, 28,  42,  223, 183, 170, 213, 119, 248, 152, 2,   44,  154, 163, 70,  221, 153, 101,
    155, 167, 43,  172, 9,   129, 22,  39,  253, 19,  98,  108, 110, 79,  113, 224, 232, 178, 185,
    112, 104, 218, 246, 97,  228, 251, 34,  242, 193, 238, 210, 144, 12,  191, 179, 162, 241, 81,
    51,  145, 235, 249, 14,  239, 107, 49,  192, 214, 31,  181, 199, 106, 157, 184, 84,  204, 176,
    115, 121, 50,  45,  127, 4,   150, 254, 138, 236, 205, 93,  222, 114, 67,  29,  24,  72,  243,
    141, 128, 195, 78,  66,  215, 61,  156, 180
};

int Perm(int i) { return kPermutation[static_cast<std::size_t>(i & 255)]; }

/// The engine's floor: truncate, minus one when that rounded up.
int Floor(float v) {
    const int t = static_cast<int>(v);
    return static_cast<float>(t) <= v ? t : t - 1;
}

// dword_140483170 / 140483140 / 1404835A0: x, y and z of the 12 gradients.
constexpr float kGradX[12] = { 1, -1, 1, -1, 1, -1, 1, -1, 0, 0, 0, 0 };
constexpr float kGradY[12] = { 1, 1, -1, -1, 0, 0, 0, 0, 1, -1, 1, -1 };
constexpr float kGradZ[12] = { 0, 0, 0, 0, 1, 1, -1, -1, 1, 1, -1, -1 };

float Corner3(int gi, float x, float y, float z) {
    float t = 0.6f - x * x - y * y - z * z;
    if (t < 0.0f) return 0.0f;
    t *= t;
    return t * t * (kGradX[gi] * x + kGradY[gi] * y + kGradZ[gi] * z);
}

float Grad2(int hash, float x, float y) {
    // 0x14027B170: hash bits 2..5 swap the axes, bit 0 negates the first,
    // bit 1 negates twice the second.
    float u = x, v = y;
    if ((hash & 0x3C) != 0) {
        u = y;
        v = x;
    }
    if (hash & 1) u = -u;
    v = (hash & 2) ? v * -2.0f : v + v;
    return u + v;
}

float Grad1(int hash, float x) {
    float g = static_cast<float>(hash & 7) + 1.0f;
    if (hash & 8) g = -g;
    return g * x;
}

} // namespace

float Simplex3(float x, float y, float z) {
    constexpr float F3 = 1.0f / 3.0f, G3 = 1.0f / 6.0f;
    const float s = (x + y + z) * F3;
    const int   i = Floor(x + s), j = Floor(y + s), k = Floor(z + s);
    const float t = static_cast<float>(i + j + k) * G3;
    const float x0 = x - (static_cast<float>(i) - t);
    const float y0 = y - (static_cast<float>(j) - t);
    const float z0 = z - (static_cast<float>(k) - t);
    // The corner order exactly as 0x1400FC220 picks it, ties included: where the two
    // largest offsets are equal its masks pick no second corner, which Gustavson's
    // branches would, so the engine's sum can pass 1 on those planes.
    const bool i1 = y0 <= x0 && z0 <= x0;
    const bool j1 = x0 < y0 && z0 < y0;
    const bool k1 = x0 < z0 && y0 < z0;
    const bool i2 = (x0 < y0 && z0 <= x0) || (x0 < z0 && y0 <= x0) || i1;
    const bool j2 = (y0 < z0 && x0 < y0) || (z0 <= y0 && y0 <= x0) || j1;
    const bool k2 = (z0 <= y0 && x0 < z0) || (y0 < z0 && z0 <= x0) || k1;
    const float x1 = x0 - i1 + G3, y1 = y0 - j1 + G3, z1 = z0 - k1 + G3;
    const float x2 = x0 - i2 + 2.0f * G3, y2 = y0 - j2 + 2.0f * G3, z2 = z0 - k2 + 2.0f * G3;
    const float x3 = x0 - 1.0f + 0.5f, y3 = y0 - 1.0f + 0.5f, z3 = z0 - 1.0f + 0.5f;
    const int ii = i & 255, jj = j & 255, kk = k & 255;
    const int gi0 = Perm(ii + Perm(jj + Perm(kk))) % 12;
    const int gi1 = Perm(ii + i1 + Perm(jj + j1 + Perm(kk + k1))) % 12;
    const int gi2 = Perm(ii + i2 + Perm(jj + j2 + Perm(kk + k2))) % 12;
    const int gi3 = Perm(ii + 1 + Perm(jj + 1 + Perm(kk + 1))) % 12;
    return 32.0f * (Corner3(gi0, x0, y0, z0) + Corner3(gi1, x1, y1, z1) + Corner3(gi2, x2, y2, z2) +
                    Corner3(gi3, x3, y3, z3));
}

float Simplex2(float x, float y) {
    constexpr float F2 = 0.3660254f, G2 = 0.21132487f;
    const float s  = (x + y) * F2;
    const int   i  = Floor(x + s), j = Floor(y + s);
    const float t  = static_cast<float>(i + j) * G2;
    const float x0 = x - (static_cast<float>(i) - t);
    const float y0 = y - (static_cast<float>(j) - t);
    const int   i1 = x0 > y0 ? 1 : 0;
    const int   j1 = x0 > y0 ? 0 : 1;
    const float x1 = x0 - i1 + G2, y1 = y0 - j1 + G2;
    const float x2 = x0 - 1.0f + 2.0f * G2, y2 = y0 - 1.0f + 2.0f * G2;
    float       n  = 0.0f;
    float       t0 = 0.5f - x0 * x0 - y0 * y0;
    if (t0 >= 0.0f) {
        t0 *= t0;
        n += t0 * t0 * Grad2(Perm(Perm(j) + i), x0, y0);
    }
    float t1 = 0.5f - x1 * x1 - y1 * y1;
    if (t1 >= 0.0f) {
        t1 *= t1;
        n += t1 * t1 * Grad2(Perm(i + Perm(j + j1) + i1), x1, y1);
    }
    float t2 = 0.5f - x2 * x2 - y2 * y2;
    if (t2 >= 0.0f) {
        t2 *= t2;
        n += t2 * t2 * Grad2(Perm(Perm(j + 1) + i + 1), x2, y2);
    }
    return n * 45.23065f;
}

float Simplex1(float x) {
    const int   i  = Floor(x);
    const float x0 = x - static_cast<float>(i);
    const float x1 = x0 - 1.0f;
    float       t0 = 1.0f - x0 * x0;
    t0 *= t0;
    float t1 = 1.0f - x1 * x1;
    t1 *= t1;
    return (t0 * t0 * Grad1(Perm(i), x0) + t1 * t1 * Grad1(Perm(i + 1), x1)) * 0.395f;
}

float Fbm2(float x, float y, int octaves) {
    float sum = 0.0f, weights = 0.0f, amplitude = 1.0f, frequency = 1.0f;
    for (int o = 0; o < octaves; ++o) {
        sum += Simplex2(x * frequency, y * frequency) * amplitude;
        weights += amplitude;
        amplitude *= 0.5f;
        frequency += frequency;
    }
    return weights > 0.0f ? sum / weights : 0.0f;
}

namespace
{
// FastNoise-style hash of a lattice corner (0x1400FB820): the corner's primes
// XOR the seed, times 0x27D4EB2D, folded by an arithmetic shift of 15.
std::int32_t CornerHash(std::uint32_t xp, std::uint32_t yp, std::int32_t seed) {
    const std::uint32_t h = (xp ^ yp ^ static_cast<std::uint32_t>(seed)) * 0x27D4EB2Du;
    const std::int32_t  s = static_cast<std::int32_t>(h);
    return s ^ (s >> 15);
}

float WithSign(float v, std::uint32_t sign_bit) {
    return std::bit_cast<float>(std::bit_cast<std::uint32_t>(v) ^ sign_bit);
}

// Bit 0 flips x, bit 1 flips y, bit 2 swaps them; the gradient is x * (1 + sqrt 2) + y.
float CornerValue(std::int32_t h, float x, float y, float falloff) {
    const float gx = WithSign(x, static_cast<std::uint32_t>(h) << 31);
    const float gy = WithSign(y, static_cast<std::uint32_t>(h >> 1) << 31);
    const bool  swap = ((h >> 2) & 1) != 0;
    const float a = swap ? gy : gx, b = swap ? gx : gy;
    const float f2 = falloff * falloff;
    return (a * 2.4142136f + b) * (f2 * f2);
}
} // namespace

float OpenSimplex2(std::int32_t seed, float x, float y) {
    constexpr std::uint32_t kPrimeX = 501125321u, kPrimeY = 1136930381u;
    constexpr float         F2 = 0.36602539f, G2 = 0.21132487f;
    const float skew = (x + y) * F2;
    const float xs = x + skew, ys = y + skew;
    const float tx = static_cast<float>(static_cast<int>(xs)), ty = static_cast<float>(static_cast<int>(ys));
    const float fi = tx - (xs < tx ? 1.0f : 0.0f), fj = ty - (ys < ty ? 1.0f : 0.0f);
    const auto  hi = static_cast<std::uint32_t>(static_cast<std::int32_t>(fi)) * kPrimeX;
    const auto  hj = static_cast<std::uint32_t>(static_cast<std::int32_t>(fj)) * kPrimeY;
    const float t  = (fi + fj) * G2;
    const float x0 = x - (fi - t), y0 = y - (fj - t);
    const bool  lower = y0 < x0;
    const float x1 = (x0 - (lower ? 1.0f : 0.0f)) + G2, y1 = (y0 - (lower ? 0.0f : 1.0f)) + G2;
    const float x2 = x0 + -0.57735026f, y2 = y0 + -0.57735026f;
    const float a0 = std::max(-(x0 * x0) + (-(y0 * y0) + 0.5f), 0.0f);
    const float a1 = std::max(-(x1 * x1) + (-(y1 * y1) + 0.5f), 0.0f);
    const float a2 = std::max(-(x2 * x2) + (-(y2 * y2) + 0.5f), 0.0f);
    const float n0 = CornerValue(CornerHash(hj, hi, seed), x0, y0, a0);
    const float n1 = CornerValue(CornerHash(hj + (lower ? 0u : kPrimeY), hi + (lower ? kPrimeX : 0u), seed),
                                 x1, y1, a1);
    const float n2 = CornerValue(CornerHash(hj + kPrimeY, hi + kPrimeX, seed), x2, y2, a2);
    return (n0 + (n1 + n2)) * 38.283688f;
}

float OpenSimplex2Fbm(std::int32_t seed, float x, float y, int octaves) {
    // 0x1400FB740: the first amplitude is 1 / sum of 0.5^o; 0x1400FB570 then halves
    // it per octave (the weighted strength is 0), doubles the frequency and steps
    // the seed.
    float total = 1.0f, gain = 0.5f;
    for (int o = 1; o < octaves; ++o) {
        total += gain;
        gain *= 0.5f;
    }
    float amplitude = 1.0f / total, sum = 0.0f;
    for (int o = 0; o < std::max(octaves, 1); ++o) {
        sum += OpenSimplex2(seed, x, y) * amplitude;
        amplitude *= 0.5f;
        x *= 2.0f;
        y *= 2.0f;
        seed = static_cast<std::int32_t>(static_cast<std::uint32_t>(seed) + 1u);
    }
    return sum;
}

} // namespace wallpaper::ParticleNoise
