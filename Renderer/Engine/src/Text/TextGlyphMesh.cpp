#include "Text/TextGlyphMesh.hpp"

#include "Runtime/RuntimeImageSource.hpp"
#include "Scene/SceneMesh.h"
#include "Scene/Parse/WPSceneParser.hpp"
#include "SpecTexs.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <vector>

namespace wallpaper
{
namespace
{
// Each attribute takes four floats of the vertex, padding included (as `MakeQuadMesh`).
constexpr std::size_t kFloatsPerVertex = 8;

std::size_t GlyphCapacity(std::size_t glyphs) {
    std::size_t capacity = 64;
    while (capacity < glyphs) capacity *= 2;
    return capacity;
}

SceneMesh::Submesh MakeGlyphSubmesh(std::size_t glyphs, uint32_t slot) {
    SceneMesh::Submesh submesh;
    submesh.AddVertexArray(SceneVertexArray({ { std::string(WE_IN_POSITION), VertexType::FLOAT3 },
                                              { std::string(WE_IN_TEXCOORD), VertexType::FLOAT2 } },
                                            glyphs * 4));
    submesh.AddIndexArray(SceneIndexArray(glyphs, SceneIndexWidth::UInt32));
    submesh.material_slot = slot;
    return submesh;
}

void FillGlyphs(SceneMesh::Submesh& submesh, std::span<const TextGlyphQuad> quads) {
    std::vector<float>    vertices(quads.size() * 4 * kFloatsPerVertex, 0.0f);
    std::vector<uint32_t> indices(quads.size() * 6);
    for (std::size_t q = 0; q < quads.size(); ++q) {
        const auto& quad = quads[q];
        // left-bottom, left-top, right-bottom, right-top (v runs down the atlas).
        const std::array<std::array<float, 4>, 4> corners { {
            { quad.left, quad.bottom, quad.u0, quad.v1 },
            { quad.left, quad.top, quad.u0, quad.v0 },
            { quad.right, quad.bottom, quad.u1, quad.v1 },
            { quad.right, quad.top, quad.u1, quad.v0 },
        } };
        for (std::size_t c = 0; c < 4; ++c) {
            float* vertex = vertices.data() + (q * 4 + c) * kFloatsPerVertex;
            vertex[0]     = corners[c][0];
            vertex[1]     = corners[c][1];
            vertex[4]     = corners[c][2];
            vertex[5]     = corners[c][3];
        }
        const auto base = static_cast<uint32_t>(q * 4);
        const std::array<uint32_t, 6> quad_indices { base, base + 1, base + 2, base + 2, base + 1, base + 3 };
        std::copy(quad_indices.begin(), quad_indices.end(), indices.begin() + static_cast<std::ptrdiff_t>(q * 6));
    }
    if (! vertices.empty()) submesh.GetVertexArray(0).SetVertexs(0, vertices);
    auto& index_array = submesh.GetIndexArray(0);
    if (! indices.empty()) index_array.Assign(0, indices);
    index_array.SetDrawIndexCount(indices.size());
}
} // namespace

std::shared_ptr<SceneMesh> MakeTextLayerMesh(const TextLayerRenderBounds& card, const TextGlyphBuild& build) {
    auto mesh = std::make_shared<SceneMesh>(MeshUpdate::OnEvent);
    auto& submeshes = mesh->Submeshes();
    {
        SceneMesh::Submesh quad;
        SceneVertexArray   vertices({ { std::string(WE_IN_POSITION), VertexType::FLOAT3 },
                                      { std::string(WE_IN_TEXCOORD), VertexType::FLOAT2 } },
                                    4);
        const std::array<float, 32> packed {
            card.left,  card.bottom, 0, 0, 0, 1, 0, 0, //
            card.left,  card.top,    0, 0, 0, 0, 0, 0, //
            card.right, card.bottom, 0, 0, 1, 1, 0, 0, //
            card.right, card.top,    0, 0, 1, 0, 0, 0,
        };
        vertices.SetVertexs(0, packed);
        const std::array<uint16_t, 6> indices { 0, 1, 2, 2, 1, 3 };
        SceneIndexArray index_array(1);
        index_array.AssignHalf(0, indices);
        quad.AddVertexArray(std::move(vertices));
        quad.AddIndexArray(std::move(index_array));
        quad.material_slot = static_cast<uint32_t>(kTextBackgroundSubmesh);
        submeshes.push_back(std::move(quad));
    }
    submeshes.push_back(MakeGlyphSubmesh(GlyphCapacity(build.glyphs.size()), kTextGlyphSubmesh));
    submeshes.push_back(MakeGlyphSubmesh(GlyphCapacity(build.color_glyphs.size()), kTextColorGlyphSubmesh));
    FillGlyphs(submeshes[kTextGlyphSubmesh], build.glyphs);
    FillGlyphs(submeshes[kTextColorGlyphSubmesh], build.color_glyphs);
    return mesh;
}

void WriteTextGlyphSubmesh(SceneMesh& mesh, std::size_t index, std::span<const TextGlyphQuad> quads) {
    auto& submeshes = mesh.Submeshes();
    if (index >= submeshes.size()) return;
    auto& submesh = submeshes[index];
    if (submesh.VertexCount() == 0 || submesh.GetVertexArray(0).CapacitySize() < quads.size() * 4 * kFloatsPerVertex) {
        submesh = MakeGlyphSubmesh(GlyphCapacity(quads.size()), static_cast<uint32_t>(index));
    }
    FillGlyphs(submesh, quads);
    mesh.SetDirty();
}

void PublishTextAtlases(RuntimeImageSource& images, std::string_view layer_key, const TextGlyphBuild& build) {
    const auto publish = [&images](const std::string& name, const TextAtlasPicture& picture) {
        if (picture.bytes == nullptr || picture.width == 0) {
            static const std::array<uint8_t, 4> clear { 0, 0, 0, 0 };
            if (! images.MatchesImage(name, 1, 1, TextureFormat::RGBA8, clear.data(), clear.size())) {
                images.SetImage(name, 1, 1, TextureFormat::RGBA8, clear.data(), clear.size());
            }
            return;
        }
        const auto format = picture.rgba ? TextureFormat::RGBA8 : TextureFormat::R8;
        if (images.MatchesImage(name, picture.width, picture.height, format, picture.bytes->data(),
                                picture.bytes->size())) {
            return;
        }
        images.SetImage(name, picture.width, picture.height, format, picture.bytes->data(), picture.bytes->size());
    };
    publish(TextAtlasName(layer_key), build.atlas);
    publish(TextColorAtlasName(layer_key), build.color_atlas);
}

void SetTextAtlasResolutions(SceneMaterial* glyphs, SceneMaterial* color_glyphs, const TextGlyphBuild& build) {
    const auto resolution = [](const TextAtlasPicture& picture) {
        const float w = picture.width == 0 ? 1.0f : static_cast<float>(picture.width);
        const float h = picture.height == 0 ? 1.0f : static_cast<float>(picture.height);
        return ShaderValue(std::array<float, 4> { w, h, w, h });
    };
    if (glyphs != nullptr) glyphs->customShader.constValues["g_Texture0Resolution"] = resolution(build.atlas);
    if (color_glyphs != nullptr) {
        auto& values = color_glyphs->customShader.constValues;
        if (build.distance_field) {
            values["g_Texture0Resolution"] = resolution(build.atlas);
            values["g_Texture1Resolution"] = resolution(build.color_atlas);
        } else {
            values["g_Texture0Resolution"] = resolution(build.color_atlas.bytes ? build.color_atlas : build.atlas);
        }
    }
}

namespace
{
using Pixel = std::array<float, 4>;

Pixel Uniform(const SceneMaterial* material, std::string_view name, Pixel fallback) {
    if (material == nullptr) return fallback;
    const auto found = material->customShader.constValues.find(std::string(name));
    if (found == material->customShader.constValues.end()) return fallback;
    for (std::size_t i = 0; i < std::min(found->second.size(), fallback.size()); ++i) {
        const float value = found->second[i];
        if (std::isfinite(value)) fallback[i] = value;
    }
    return fallback;
}

struct AtlasSampler {
    std::shared_ptr<Image> owner;
    const uint8_t* pixels { nullptr };
    int width { 0 }, height { 0 }, bpp { 0 };

    AtlasSampler() = default;
    explicit AtlasSampler(std::shared_ptr<Image> image): owner(std::move(image)) {
        if (owner == nullptr || owner->slots.empty() || owner->slots[0].mipmaps.empty()) return;
        const auto& level = owner->slots[0].mipmaps[0];
        bpp = owner->header.format == TextureFormat::R8 ? 1 : owner->header.format == TextureFormat::RGBA8 ? 4 : 0;
        if (bpp == 0 || level.width <= 0 || level.height <= 0 || level.data == nullptr ||
            level.size < int64_t(level.width) * level.height * bpp) return;
        width = level.width;
        height = level.height;
        pixels = level.data.get();
    }

    Pixel sample(float u, float v) const {
        if (pixels == nullptr || !std::isfinite(u) || !std::isfinite(v)) return {};
        const float x = std::clamp(u, 0.0f, 1.0f) * width - 0.5f;
        const float y = std::clamp(v, 0.0f, 1.0f) * height - 0.5f;
        const int x0 = static_cast<int>(std::floor(x)), y0 = static_cast<int>(std::floor(y));
        const float fx = x - x0, fy = y - y0;
        Pixel value {};
        for (int iy = 0; iy < 2; ++iy) for (int ix = 0; ix < 2; ++ix) {
            const auto* p = pixels + (std::size_t(std::clamp(y0 + iy, 0, height - 1)) * width +
                                      std::clamp(x0 + ix, 0, width - 1)) * bpp;
            const float weight = (ix ? fx : 1.0f - fx) * (iy ? fy : 1.0f - fy);
            if (bpp == 1) { value[0] += weight * p[0] / 255.0f; value[3] += weight; }
            else for (std::size_t c = 0; c < 4; ++c) value[c] += weight * p[c] / 255.0f;
        }
        return value;
    }
};

float Median(const Pixel& pixel) {
    return std::max(std::min(pixel[0], pixel[1]), std::min(std::max(pixel[0], pixel[1]), pixel[2]));
}

void Blend(Pixel& target, Pixel source) {
    const float alpha = std::clamp(source[3], 0.0f, 1.0f);
    for (std::size_t c = 0; c < 3; ++c) target[c] = source[c] * alpha + target[c] * (1.0f - alpha);
    // Same Material alpha rule as the glyph draw. WE text donors at .70 do not
    // pass the emitter's 127 threshold; .75 and .80 do (plain and MSDF probes).
    target[3] = TranslucentBlendAlpha(alpha, target[3]);
}

struct EmissionGlyph {
    TextGlyphQuad quad;
    const AtlasSampler* distance;
    const AtlasSampler* color;
    Pixel tint, rv0, rv1, rv2, rv3;
    bool df, colored, outline, blur, shadow;
    float pixel_range;

    Pixel shade(float x, float y) const {
        if (x < quad.left || x >= quad.right || y < quad.bottom || y >= quad.top) return {};
        const float u = quad.u0 + (x - quad.left) / (quad.right - quad.left) * (quad.u1 - quad.u0);
        const float v = quad.v0 + (quad.top - y) / (quad.top - quad.bottom) * (quad.v1 - quad.v0);
        Pixel result = tint;
        if (!df) {
            const auto texel = color->sample(u, v);
            if (colored) { result = texel; result[3] *= tint[3]; }
            else result[3] *= texel[0];
            return result;
        }
        const auto coverage = [this](float d, float threshold, float radius) {
            if (!blur && !shadow) return std::clamp(d + threshold, 0.0f, 1.0f);
            const float half = std::max(radius, 0.5f);
            const float t = std::clamp((d + threshold - 0.5f + half) / (2.0f * half), 0.0f, 1.0f);
            return t * t * (3.0f - 2.0f * t);
        };
        const float range = blur ? rv0[0] : pixel_range;
        const float d = (Median(distance->sample(u, v)) - 0.5f) * range;
        const float radius = blur ? rv0[2] : 0.0f;
        const float fill = coverage(d, 0.5f, radius);
        if (colored) result = color->sample(u, v);
        if (outline) {
            const float reach = blur ? rv0[1] : rv0[1] * pixel_range / std::max(rv0[0], 1.0f);
            for (std::size_t c = 0; c < 3; ++c) result[c] = rv1[c] + (result[c] - rv1[c]) * fill;
            result[3] = coverage(d, 0.5f + reach, radius) * tint[3];
        } else result[3] = fill * tint[3];
        if (shadow) {
            const auto texel = distance->sample(u - rv1[3] / distance->width, v - rv2[3] / distance->height);
            const float a = std::clamp(rv3[0] * coverage((Median(texel) - 0.5f) * rv0[0],
                                                        0.5f + (outline ? rv0[1] : 0.0f), rv0[3]), 0.0f, 1.0f) * tint[3];
            const float combined = result[3] + a * (1.0f - result[3]);
            for (std::size_t c = 0; c < 3; ++c) {
                result[c] = (result[c] * result[3] + rv2[c] * a * (1.0f - result[3])) / std::max(combined, 1e-6f);
            }
            result[3] = combined;
        }
        return result;
    }
};

struct QuarterAxis {
    std::array<float, 4> point;
    std::array<float, 4> weight;
};

QuarterAxis QuarterSamples(uint32_t at, uint32_t target, uint32_t source) {
    QuarterAxis result;
    // downsample_quarter samples +/-2 source texels, using the texture's linear sampler.
    for (int side = 0; side < 2; ++side) {
        const float p = (float(at) + 0.5f) * float(source) / float(target) + (side ? 2.0f : -2.0f) - 0.5f;
        const int base = static_cast<int>(std::floor(p));
        const float f = p - base;
        for (int lane = 0; lane < 2; ++lane) {
            result.point[side * 2 + lane] = float(std::clamp(base + lane, 0, int(source) - 1)) + 0.5f;
            result.weight[side * 2 + lane] = 0.5f * (lane ? f : 1.0f - f);
        }
    }
    return result;
}
} // namespace

std::shared_ptr<Image> RenderTextEmissionImage(
    const SceneMesh& mesh, RuntimeImageSource& images, const TextLayerRenderFrame& frame,
    bool distance_field, const TextStyleUniforms& style, uint32_t width, uint32_t height,
    const SceneMaterial* background) {
    if (!width || !height || width > 960 || height > 540 || !frame.size.allFinite() || !frame.center.allFinite() ||
        frame.size.x() < 1 || frame.size.y() < 1 || frame.size.x() > 4096 || frame.size.y() > 4096) return nullptr;
    const auto source_width = uint32_t(frame.size.x()), source_height = uint32_t(frame.size.y());
    std::array<std::array<AtlasSampler, 2>, 2> atlases;
    std::vector<EmissionGlyph> glyphs;
    for (std::size_t slot : { kTextGlyphSubmesh, kTextColorGlyphSubmesh }) {
        if (slot >= mesh.Submeshes().size()) continue;
        const auto* material = mesh.MaterialForSlot(uint32_t(slot));
        const auto& submesh = mesh.Submeshes()[slot];
        if (!material || material->textures.empty() || !submesh.VertexCount() || !submesh.IndexCount()) continue;
        const bool colored = slot == kTextColorGlyphSubmesh;
        auto& pair = atlases[slot - 1];
        pair[0] = AtlasSampler(images.Parse(material->textures[0]));
        pair[1] = colored && distance_field && material->textures.size() > 1
                      ? AtlasSampler(images.Parse(material->textures[1])) : pair[0];
        if (!pair[0].pixels || !pair[1].pixels) continue;
        const auto tint = Uniform(material, "g_Color4", { 1, 1, 1, 1 });
        const auto rv0 = Uniform(material, "g_RenderVar0", style.rv0);
        const auto& vertices = submesh.GetVertexArray(0);
        if (vertices.OneSize() != kFloatsPerVertex) continue;
        const auto count = std::min<std::size_t>(submesh.GetIndexArray(0).DrawIndexCount() / 6, vertices.VertexCount() / 4);
        for (std::size_t at = 0; at < count; ++at) {
            const auto* p = vertices.Data() + at * 4 * kFloatsPerVertex;
            TextGlyphQuad quad { p[0], p[1], p[16], p[9], p[4], p[13], p[20], p[5] };
            if (!(quad.right > quad.left) || !(quad.top > quad.bottom) || !(quad.u1 > quad.u0) || !(quad.v1 > quad.v0)) continue;
            if (quad.right <= frame.bounds.left || quad.left >= frame.bounds.right ||
                quad.top <= frame.bounds.bottom || quad.bottom >= frame.bounds.top) continue;
            const float range = std::max(1.0f, 0.5f * rv0[0] *
                ((quad.right - quad.left) / ((quad.u1 - quad.u0) * pair[0].width) +
                 (quad.top - quad.bottom) / ((quad.v1 - quad.v0) * pair[0].height)));
            glyphs.push_back({ quad, &pair[0], &pair[1], tint, rv0,
                Uniform(material, "g_RenderVar1", style.rv1), Uniform(material, "g_RenderVar2", style.rv2),
                Uniform(material, "g_RenderVar3", style.rv3), distance_field, colored,
                style.outline, style.blur, style.shadow, range });
        }
    }
    Pixel clear {};
    if (background != nullptr) {
        auto color = Uniform(background, "g_Color", { 0, 0, 0, 1 });
        color[3] = Uniform(background, "g_Alpha", { 1, 0, 0, 0 })[0];
        Blend(clear, color);
    }
    auto image = std::make_shared<Image>();
    image->key = "text-emission-quarter";
    image->header.width = image->header.mapWidth = int32_t(width);
    image->header.height = image->header.mapHeight = int32_t(height);
    image->header.format = TextureFormat::RGBA8;
    image->header.count = 1;
    auto& slot = image->slots.emplace_back();
    slot.width = int32_t(width); slot.height = int32_t(height);
    auto& level = slot.mipmaps.emplace_back();
    level.width = int32_t(width); level.height = int32_t(height); level.size = std::size_t(width) * height * 4;
    level.data = ImageDataPtr(new uint8_t[std::size_t(level.size)] {}, [](uint8_t* p) { delete[] p; });
    std::vector<QuarterAxis> columns;
    columns.reserve(width);
    for (uint32_t x = 0; x < width; ++x) columns.push_back(QuarterSamples(x, width, source_width));
    // Only one row of sample accumulators; never construct a full-size text bitmap.
    std::vector<Pixel> row(std::size_t(width) * 16);
    const float step = float(source_width) / float(width);
    for (uint32_t y = 0; y < height; ++y) {
        std::fill(row.begin(), row.end(), clear);
        const auto vertical = QuarterSamples(y, height, source_height);
        for (const auto& glyph : glyphs) {
            if (glyph.quad.top <= frame.bounds.top - vertical.point[3] ||
                glyph.quad.bottom > frame.bounds.top - vertical.point[0]) continue;
            const auto first = uint32_t(std::clamp(std::floor((glyph.quad.left - frame.bounds.left - 3) / step) - 1, 0.0f, float(width)));
            const auto last = uint32_t(std::clamp(std::ceil((glyph.quad.right - frame.bounds.left + 3) / step) + 1, 0.0f, float(width)));
            for (uint32_t x = first; x < last; ++x) for (std::size_t iy = 0; iy < 4; ++iy) for (std::size_t ix = 0; ix < 4; ++ix) {
                Blend(row[std::size_t(x) * 16 + iy * 4 + ix],
                      glyph.shade(frame.bounds.left + columns[x].point[ix], frame.bounds.top - vertical.point[iy]));
            }
        }
        for (uint32_t x = 0; x < width; ++x) {
            Pixel pixel {};
            for (std::size_t iy = 0; iy < 4; ++iy) for (std::size_t ix = 0; ix < 4; ++ix) {
                const float weight = columns[x].weight[ix] * vertical.weight[iy];
                const auto& sample = row[std::size_t(x) * 16 + iy * 4 + ix];
                for (std::size_t c = 0; c < 4; ++c) pixel[c] += sample[c] * weight;
            }
            for (std::size_t c = 0; c < 4; ++c) {
                level.data.get()[(std::size_t(y) * width + x) * 4 + c] = std::isfinite(pixel[c])
                    ? uint8_t(std::lround(std::clamp(pixel[c], 0.0f, 1.0f) * 255.0f)) : 0;
            }
        }
    }
    return image;
}

} // namespace wallpaper
