#pragma once

#include "TexelSample.hpp"
#include "Particle/Particle.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <functional>
#include <limits>
#include <memory>
#include <span>
#include <vector>

namespace wallpaper
{

struct ParticleImageVertex {
    linalg::Vector3f position { 0, 0, 0 };
    linalg::Vector2f uv { 0, 0 };
    std::array<uint32_t, 4> bones {};
    std::array<float, 4> weights {};
};
using ParticleImageTriangle = std::array<ParticleImageVertex, 3>;

/// The CPU picture and UV geometry of a linked layer. Static file images are held
/// once; a runtime image replaces this shared pointer without copying its pixels.
struct ParticleImageSurface {
    std::shared_ptr<Image> image;
    std::shared_ptr<Image> opacity;
    std::vector<ParticleImageTriangle> triangles;
    int last_width { 0 }, last_height { 0 };
    /// A producer can supply the already downsampled RGBA image on demand.
    /// Its original pixel extent is available without creating that image.
    bool downsampled { false };
    std::array<int, 2> pixel_extent {};
};

struct ParticleImageSample {
    linalg::Vector2f uv { 0, 0 };
    std::array<uint8_t, 3> colour {};
    uint32_t surface { 0 };
    uint32_t triangle { std::numeric_limits<uint32_t>::max() };
    uint32_t bone { std::numeric_limits<uint32_t>::max() };
    /// Packed pixel offsets for a plain image, barycentric coordinates for a UV piece.
    linalg::Vector2f coordinates { 0, 0 };
};

namespace particle_image_detail
{
inline int Address(int value, int size, TextureWrap wrap) {
    if (wrap == TextureWrap::REPEAT) return (value % size + size) % size;
    return std::clamp(value, 0, size - 1);
}

// One hardware-filtered sample before downsample_quarter.frag averages its taps.
inline std::array<double, 4> SampleLevel(const Image& image, double u, double v, std::size_t level) {
    std::array<double, 4> colour {};
    if (image.slots.empty() || image.slots[0].mipmaps.empty()) return colour;
    const auto& mip = image.slots[0].mipmaps[level];
    if (! mip.data || mip.width <= 0 || mip.height <= 0 || ! TexelSampleReads(image.header.format)) return colour;
    const double x = u * mip.width - 0.5, y = v * mip.height - 0.5;
    if (image.header.sample.minFilter == TextureFilter::NEAREST) {
        const auto p = TexelRgba(mip, image.header.format,
            Address(static_cast<int>(std::floor(x + 0.5)), mip.width, image.header.sample.wrapS),
            Address(static_cast<int>(std::floor(y + 0.5)), mip.height, image.header.sample.wrapT));
        return { static_cast<double>(p[0]), static_cast<double>(p[1]),
                 static_cast<double>(p[2]), static_cast<double>(p[3]) };
    }
    const int ix = static_cast<int>(std::floor(x)), iy = static_cast<int>(std::floor(y));
    const double tx = x - ix, ty = y - iy;
    for (int dy = 0; dy < 2; ++dy) {
        for (int dx = 0; dx < 2; ++dx) {
            const auto p = TexelRgba(mip, image.header.format,
                                     Address(ix + dx, mip.width, image.header.sample.wrapS),
                                     Address(iy + dy, mip.height, image.header.sample.wrapT));
            const double weight = (dx ? tx : 1.0 - tx) * (dy ? ty : 1.0 - ty);
            for (int c = 0; c < 4; ++c) colour[c] += p[c] * weight;
        }
    }
    return colour;
}

inline std::array<double, 4> Sample(const Image& image, double u, double v, double lod) {
    if (image.slots.empty() || image.slots[0].mipmaps.empty()) return {};
    const auto last = image.slots[0].mipmaps.size() - 1;
    lod = std::clamp(lod, 0.0, static_cast<double>(last));
    if (image.header.sample.mipFilter == TextureFilter::NEAREST)
        return SampleLevel(image, u, v, static_cast<std::size_t>(std::lround(lod)));
    const auto lower = static_cast<std::size_t>(std::floor(lod));
    auto colour = SampleLevel(image, u, v, lower);
    const double blend = lod - lower;
    if (blend > 0.0 && lower < last) {
        const auto upper = SampleLevel(image, u, v, lower + 1);
        for (int c = 0; c < 4; ++c) colour[c] += (upper[c] - colour[c]) * blend;
    }
    return colour;
}

inline std::array<int, 2> Extent(const ParticleImageSurface& surface) {
    if (surface.downsampled) return surface.pixel_extent;
    if (! surface.image || surface.image->slots.empty() || surface.image->slots[0].mipmaps.empty()) return {};
    const auto& image = *surface.image;
    if (image.header.isVideo) return {};
    const auto& mip = image.slots[0].mipmaps[0];
    if (! mip.data || mip.width <= 0 || mip.height <= 0 || ! TexelSampleReads(image.header.format)) return {};
    return { std::clamp(image.header.mapWidth, 1, mip.width),
             std::clamp(image.header.mapHeight, 1, mip.height) };
}

inline std::array<int, 2> QuarterExtent(int width, int height) {
    if (width <= 0 || height <= 0) return {};
    const double cap = std::min({ 1.0, 3840.0 / width, 2160.0 / height });
    return { std::max(1, static_cast<int>(width * cap) / 4),
             std::max(1, static_cast<int>(height * cap) / 4) };
}

inline bool Barycentric(const ParticleImageTriangle& triangle, const linalg::Vector2f& uv,
                         linalg::Vector2f& out) {
    const auto a = triangle[1].uv - triangle[0].uv;
    const auto b = triangle[2].uv - triangle[0].uv;
    const auto p = uv - triangle[0].uv;
    const float det = a.x() * b.y() - a.y() * b.x();
    if (std::abs(det) < 1e-12f) return false;
    out = { (p.x() * b.y() - p.y() * b.x()) / det,
             (a.x() * p.y() - a.y() * p.x()) / det };
    return out.x() >= -1e-5f && out.y() >= -1e-5f && out.sum() <= 1.00001f;
}

inline linalg::Vector2f PackedPoint(int x, int y, int map_width, int width, int height) {
    // The reference's 8-byte map entry packs x/y as signed integers; both use
    // the width-derived step (sub_1401D3AE0, read at 0x140238f8d/0x14023902b).
    const double step = static_cast<double>(width) / map_width;
    return { static_cast<float>(std::trunc(step * x - width * 0.5 + step * 0.5)),
             static_cast<float>(std::trunc(step * y - height * 0.5 + step * 0.5)) };
}
} // namespace particle_image_detail

/// Cached emission texels of an emitterimage link (sub_1401D3AE0). No work is
/// registered for a layer that no image emitter uses. The map is bounded by the
/// reference's 3840 x 2160 input cap and rebuilt only on resize or the timed flag.
struct ParticleLayerImageSource {
    std::vector<ParticleImageSurface> surfaces;
    std::vector<ParticleImageSample> samples;
    std::function<void(ParticleLayerImageSource&)> refresh;
    std::function<void(ParticleLayerImageSource&)> prepare_pixels;
    std::function<void(ParticleLayerImageSource&)> release_pixels;
    std::function<std::span<const linalg::Affine3f>()> palette;
    linalg::Matrix4d world { linalg::Matrix4d::Identity() };
    linalg::Matrix4d previous_world { linalg::Matrix4d::Identity() };
    linalg::Vector2d extent { 0, 0 };
    linalg::Vector2d centre { 0, 0 };
    bool available { false };
    bool primed { false };
    bool built { false };
    double prepared_time { std::numeric_limits<double>::quiet_NaN() };
    double built_time { 0 };

    void Prepare(double time, bool timed_rebuild) {
        if (time != prepared_time) {
            previous_world = world;
            prepared_time = time;
        }
        if (refresh) refresh(*this);
        if (! available) {
            samples.clear();
            built = false;
            primed = false;
            return;
        }
        if (! primed) { previous_world = world; primed = true; }
        bool resized = false;
        for (const auto& surface : surfaces) {
            const auto size = particle_image_detail::Extent(surface);
            resized = resized || size[0] != surface.last_width || size[1] != surface.last_height;
        }
        if (! built || resized || (timed_rebuild && time - built_time > 1.0)) {
            if (prepare_pixels) prepare_pixels(*this);
            Rebuild();
            if (release_pixels) release_pixels(*this);
            built = true;
            built_time = time;
        }
    }

    void Rebuild() {
        using namespace particle_image_detail;
        samples.clear();
        for (std::size_t part = 0; part < surfaces.size(); ++part) {
            auto& surface = surfaces[part];
            const auto size = Extent(surface);
            surface.last_width = size[0]; surface.last_height = size[1];
            if (size[0] <= 0 || size[1] <= 0) continue;
            if (!surface.image || surface.image->slots.empty() || surface.image->slots[0].mipmaps.empty()) continue;
            const auto& image = *surface.image;
            const auto& mip = image.slots[0].mipmaps[0];
            if (!mip.data || mip.width <= 0 || mip.height <= 0) continue;
            const auto quarter = surface.downsampled ? std::array<int, 2> { mip.width, mip.height }
                                                     : QuarterExtent(size[0], size[1]);
            const int width = quarter[0], height = quarter[1];
            if (width > 960 || height > 540) continue;
            const double lod = std::log2(std::max(static_cast<double>(size[0]) / width,
                                                   static_cast<double>(size[1]) / height));
            double opacity_lod = 0.0;
            if (surface.opacity && !surface.opacity->slots.empty() &&
                !surface.opacity->slots[0].mipmaps.empty()) {
                const auto& mask = surface.opacity->slots[0].mipmaps[0];
                if (mask.width > 0 && mask.height > 0)
                    opacity_lod = std::log2(std::max(static_cast<double>(size[0]) * mask.width / (static_cast<double>(mip.width) * width),
                                                      static_cast<double>(size[1]) * mask.height / (static_cast<double>(mip.height) * height)));
            }
            const std::size_t start = samples.size();
            samples.resize(start + static_cast<std::size_t>(width) * height);
            for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x) {
                auto& sample = samples[start + static_cast<std::size_t>(y) * width + x];
                sample = {};
                sample.surface = static_cast<uint32_t>(part);
                sample.uv = { (x + 0.5f) / width, (y + 0.5f) / height };
                sample.coordinates = PackedPoint(x, y, width, size[0], size[1]);
                const double u = sample.uv.x() * size[0] / mip.width;
                const double v = sample.uv.y() * size[1] / mip.height;
                std::array<double, 4> colour {};
                if (surface.downsampled) {
                    const auto pixel = TexelRgba(mip, image.header.format, x, y);
                    for (int c = 0; c < 4; ++c) colour[c] = pixel[c];
                } else {
                    for (int dy : { -1, 1 }) for (int dx : { -1, 1 }) {
                        const auto tap = Sample(image, u + dx * 2.0 / mip.width, v + dy * 2.0 / mip.height, lod);
                        for (int c = 0; c < 4; ++c) colour[c] += tap[c] * 0.25;
                    }
                    if (surface.opacity) colour[3] *= Sample(*surface.opacity, u, v, opacity_lod)[0] / 255.0;
                }
                // Temporarily use the high bit of surface as the rejected-alpha mark.
                if (std::lround(colour[3]) < 127) sample.surface |= 0x80000000u;
                for (int c = 0; c < 3; ++c)
                    sample.colour[c] = static_cast<uint8_t>(std::clamp(std::lround(colour[c]), 0L, 255L));
            }
            // Rasterise UV triangles onto the map once, not a triangle search for
            // every emitted particle. Last triangle wins where UV pieces overlap.
            for (std::size_t t = 0; t < surface.triangles.size(); ++t) {
                const auto& tri = surface.triangles[t];
                if (!tri[0].uv.allFinite() || !tri[1].uv.allFinite() || !tri[2].uv.allFinite()) continue;
                const auto low = tri[0].uv.cwiseMin(tri[1].uv).cwiseMin(tri[2].uv);
                const auto high = tri[0].uv.cwiseMax(tri[1].uv).cwiseMax(tri[2].uv);
                const int x0 = std::min(static_cast<int>(std::floor(std::clamp(low.x(), 0.0f, 1.0f) * width)), width - 1);
                const int x1 = std::min(static_cast<int>(std::ceil(std::clamp(high.x(), 0.0f, 1.0f) * width)), width - 1);
                const int y0 = std::min(static_cast<int>(std::floor(std::clamp(low.y(), 0.0f, 1.0f) * height)), height - 1);
                const int y1 = std::min(static_cast<int>(std::ceil(std::clamp(high.y(), 0.0f, 1.0f) * height)), height - 1);
                for (int y = y0; y <= y1; ++y) for (int x = x0; x <= x1; ++x) {
                    auto& sample = samples[start + static_cast<std::size_t>(y) * width + x];
                    linalg::Vector2f bary;
                    if (Barycentric(tri, sample.uv, bary)) {
                        sample.triangle = static_cast<uint32_t>(t);
                        const auto point = PackedPoint(x, y, width, size[0], size[1]);
                        const linalg::Vector2f placed_uv(point.x() / size[0] + 0.5f, point.y() / size[1] + 0.5f);
                        Barycentric(tri, placed_uv, sample.coordinates);
                        // The reference's emission map stores one bone index per
                        // texel (sub_1402378A0 at 0x140239057), not a copied pose.
                        std::array<std::pair<uint32_t, float>, 12> weights {};
                        std::size_t used = 0;
                        const std::array<float, 3> blend { 1.0f - bary.sum(), bary.x(), bary.y() };
                        for (int v = 0; v < 3; ++v) for (int lane = 0; lane < 4; ++lane) {
                            const float weight = blend[v] * tri[v].weights[lane];
                            if (weight <= 0) continue;
                            const auto bone = tri[v].bones[lane];
                            auto found = std::find_if(weights.begin(), weights.begin() + used,
                                [bone](const auto& value) { return value.first == bone; });
                            if (found == weights.begin() + used) weights[used++] = { bone, weight };
                            else found->second += weight;
                        }
                        sample.bone = used == 0 ? std::numeric_limits<uint32_t>::max()
                            : std::max_element(weights.begin(), weights.begin() + used,
                                [](const auto& a, const auto& b) { return a.second < b.second; })->first;
                    }
                }
            }
            samples.erase(std::remove_if(samples.begin() + static_cast<std::ptrdiff_t>(start), samples.end(),
                [&surface](const ParticleImageSample& sample) {
                    return (sample.surface & 0x80000000u) != 0 ||
                           (! surface.triangles.empty() && sample.triangle == std::numeric_limits<uint32_t>::max());
                }), samples.end());
        }
    }

    linalg::Vector3d LocalPosition(const ParticleImageSample& sample, const linalg::Vector3d& offset) const {
        const auto& surface = surfaces[sample.surface];
        if (sample.triangle == std::numeric_limits<uint32_t>::max())
            return linalg::Vector3d(centre.x() + sample.coordinates.x() * extent.x() / surface.last_width,
                                    centre.y() - sample.coordinates.y() * extent.y() / surface.last_height, 0.0) + offset;
        const auto bones = palette ? palette() : std::span<const linalg::Affine3f> {};
        const auto& triangle = surface.triangles[sample.triangle];
        const std::array<double, 3> bary { 1.0 - sample.coordinates.sum(), sample.coordinates.x(), sample.coordinates.y() };
        linalg::Vector3d position = offset;
        for (int corner = 0; corner < 3; ++corner) {
            const auto& vertex = triangle[corner];
            position += bary[corner] * vertex.position.cast<double>();
        }
        if (sample.bone < bones.size()) return (bones[sample.bone] * position.cast<float>()).cast<double>();
        return position;
    }
};
} // namespace wallpaper
