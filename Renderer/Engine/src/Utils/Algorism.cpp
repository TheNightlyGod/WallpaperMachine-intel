// Clean-room implementation from the WallpaperMachine spec e7-small-units.md; written without access to the original source.
#include "Utils/Algorism.h"
#include "Utils/Linalg.hpp"

using namespace wallpaper;
using namespace wallpaper::linalg;

namespace
{
// The published permutation of improved noise, repeated once so that an index up
// to 511 needs no wrapping.
constexpr unsigned char kPermutation[256] = {
    151, 160, 137, 91,  90,  15,  131, 13,  201, 95,  96,  53,  194, 233, 7,   225,
    140, 36,  103, 30,  69,  142, 8,   99,  37,  240, 21,  10,  23,  190, 6,   148,
    247, 120, 234, 75,  0,   26,  197, 62,  94,  252, 219, 203, 117, 35,  11,  32,
    57,  177, 33,  88,  237, 149, 56,  87,  174, 20,  125, 136, 171, 168, 68,  175,
    74,  165, 71,  134, 139, 48,  27,  166, 77,  146, 158, 231, 83,  111, 229, 122,
    60,  211, 133, 230, 220, 105, 92,  41,  55,  46,  245, 40,  244, 102, 143, 54,
    65,  25,  63,  161, 1,   216, 80,  73,  209, 76,  132, 187, 208, 89,  18,  169,
    200, 196, 135, 130, 116, 188, 159, 86,  164, 100, 109, 198, 173, 186, 3,   64,
    52,  217, 226, 250, 124, 123, 5,   202, 38,  147, 118, 126, 255, 82,  85,  212,
    207, 206, 59,  227, 47,  16,  58,  17,  182, 189, 28,  42,  223, 183, 170, 213,
    119, 248, 152, 2,   44,  154, 163, 70,  221, 153, 101, 155, 167, 43,  172, 9,
    129, 22,  39,  253, 19,  98,  108, 110, 79,  113, 224, 232, 178, 185, 112, 104,
    218, 246, 97,  228, 251, 34,  242, 193, 238, 210, 144, 12,  191, 179, 162, 241,
    81,  51,  145, 235, 249, 14,  239, 107, 49,  192, 214, 31,  181, 199, 106, 157,
    184, 84,  204, 176, 115, 121, 50,  45,  127, 4,   150, 254, 138, 236, 205, 93,
    222, 114, 67,  29,  24,  72,  243, 141, 128, 195, 78,  66,  215, 61,  156, 180,
};

inline int Hash(int index) { return kPermutation[index & 255]; }

double Fade(double t) { return t * t * t * (t * (t * 6.0 - 15.0) + 10.0); }

// The dot product of the offset with one of twelve edge directions, chosen by the
// low four bits of the corner's hash.
double Gradient(int hash, double x, double y, double z) {
    const int    h = hash & 15;
    const double u = h < 8 ? x : y;
    const double v = h < 4 ? y : (h == 12 || h == 14 ? x : z);
    return ((h & 1) == 0 ? u : -u) + ((h & 2) == 0 ? v : -v);
}

// The lattice cell of a coordinate on a period of 256; a coordinate too large for
// an integer simply lands on a cell, whichever one.
int Cell(double floored) {
    const double wrapped = std::fmod(floored, 256.0);
    return static_cast<int>(wrapped) & 255;
}
} // namespace

double algorism::CalculatePersperctiveDistance(double fov, double height) noexcept {
    constexpr double kPi = 3.14159265358979323846;
    return height / (2.0 * std::tan((fov / 2.0) * kPi / 180.0));
}

double algorism::PerlinNoise(double x, double y, double z) noexcept {
    if (! std::isfinite(x) || ! std::isfinite(y) || ! std::isfinite(z)) return 0.0;
    const double fx = std::floor(x), fy = std::floor(y), fz = std::floor(z);
    const int    X = Cell(fx), Y = Cell(fy), Z = Cell(fz);
    x -= fx;
    y -= fy;
    z -= fz;
    const double u = Fade(x), v = Fade(y), w = Fade(z);

    const int A = Hash(X) + Y, AA = Hash(A) + Z, AB = Hash(A + 1) + Z;
    const int B = Hash(X + 1) + Y, BA = Hash(B) + Z, BB = Hash(B + 1) + Z;

    return lerp(w,
                lerp(v,
                     lerp(u, Gradient(Hash(AA), x, y, z), Gradient(Hash(BA), x - 1, y, z)),
                     lerp(u, Gradient(Hash(AB), x, y - 1, z), Gradient(Hash(BB), x - 1, y - 1, z))),
                lerp(v,
                     lerp(u, Gradient(Hash(AA + 1), x, y, z - 1), Gradient(Hash(BA + 1), x - 1, y, z - 1)),
                     lerp(u,
                          Gradient(Hash(AB + 1), x, y - 1, z - 1),
                          Gradient(Hash(BB + 1), x - 1, y - 1, z - 1))));
}
