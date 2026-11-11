#include "WPPuppetMorph.hpp"
#include "WPMdlParser.hpp"
#include "Runtime/RuntimeImageSource.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>

namespace wallpaper {
namespace {
bool SameShapeName(std::string_view a, std::string_view b) {
    const auto lower = [](unsigned char c) { return c >= 'A' && c <= 'Z' ? c + ('a' - 'A') : c; };
    return a.size() == b.size() && std::equal(a.begin(), a.end(), b.begin(),
        [&](unsigned char x, unsigned char y) { return lower(x) == lower(y); });
}
} // namespace

void PreparePuppetMorphMetadata(WPMdl& mdl) {
    if (!mdl.puppet || std::none_of(mdl.morph_sections.begin(), mdl.morph_sections.end(),
        [](const auto& mesh) { return !mesh.sections.empty(); })) return;
    auto& info = mdl.puppet->morph_meshes;
    info.resize(mdl.morph_sections.size());
    for (std::size_t i = 0; i < info.size(); ++i) {
        const auto& source = mdl.morph_sections[i];
        auto& destination = info[i];
        destination.scale = source.mesh_parameter;
        destination.vertices = source.vertex_count;
        destination.modifiers = i < mdl.meshes.size() && (mdl.meshes[i].flag_a & 0x2000u) != 0;
        destination.shapes.reserve(source.sections.size());
        for (const auto& shape : source.sections) {
            PuppetMorphShapeInfo entry;
            entry.name = shape.tag;
            if (shape.modifier) {
                entry.bone = shape.modifier->bone;
                entry.modifier_flags = shape.modifier->selector;
                entry.range = shape.modifier->parameters;
            }
            destination.shapes.push_back(std::move(entry));
        }
    }
}

std::shared_ptr<Image> BuildPuppetMorphImage(const WPMdl& mdl, std::size_t mesh_index,
                                           bool image_puppet, const std::string& name) {
    if (mesh_index >= mdl.meshes.size() || mesh_index >= mdl.morph_sections.size()) return {};
    const auto& mesh = mdl.meshes[mesh_index];
    const auto& morph = mdl.morph_sections[mesh_index];
    if (morph.sections.empty() || morph.vertex_count == 0) return {};
    if (image_puppet && (mesh_index != 0 || (mesh.flag & 0x10000u) == 0)) return {};
    const std::size_t vertices = image_puppet ? morph.vertex_count : mesh.positions.size();
    if (vertices == 0) return {};
    const bool normals = (mesh.flag_a & 0x400u) != 0;
    const bool tangents = (mesh.flag_a & 0x800u) != 0;
    const bool alpha = (mesh.flag_a & 0x1000u) != 0;
    for (const auto& shape : morph.sections) {
        if (shape.vertices.size() < vertices ||
            (normals && shape.data_400.size() < vertices) ||
            (tangents && shape.data_800.size() < vertices) ||
            (image_puppet && alpha && shape.data_1000.size() < vertices)) return {};
    }
    const uint64_t channels = image_puppet ? 4 : 3 * (1 + unsigned(normals) + unsigned(tangents));
    const uint64_t words = uint64_t(vertices) * morph.sections.size() * channels + (image_puppet ? 4 : 0);
    const uint64_t pixels = (words + 3) / 4;
    auto side = uint32_t(std::ceil(std::sqrt(double(pixels))));
    while (uint64_t(side) * side < pixels) ++side;
    if (side == 0 || side > 16384 || uint64_t(side) * side * 8 > std::numeric_limits<int32_t>::max()) return {};
    auto image = std::make_shared<Image>();
    image->key = name;
    auto& header = image->header;
    header.width = header.height = header.mapWidth = header.mapHeight = int32_t(side);
    header.count = 1;
    header.format = TextureFormat::RGBA16S;
    header.formatCode = 19;
    header.sample.wrapS = header.sample.wrapT = TextureWrap::CLAMP_TO_EDGE;
    header.sample.minFilter = header.sample.magFilter = TextureFilter::NEAREST;
    auto& slot = image->slots.emplace_back();
    slot.width = slot.height = int32_t(side);
    auto& level = slot.mipmaps.emplace_back();
    level.width = level.height = int32_t(side);
    level.size = std::size_t(side) * side * 8;
    level.data = ImageDataPtr(new uint8_t[level.size] {}, [](uint8_t* bytes) { delete[] bytes; });
    std::size_t cursor = 0;
    const auto put = [&](uint16_t value) {
        std::memcpy(level.data.get() + cursor, &value, sizeof(value));
        cursor += sizeof(value);
    };
    if (image_puppet) {
        // 0x1401FBAE0: vertex w == 0 does not morph. Texture texel zero is reserved;
        // only meshes carrying the alpha stream are copied by this image path.
        put(0); put(0); put(0); put(32767);
        if (alpha) for (const auto& shape : morph.sections) {
            for (std::size_t vertex = 0; vertex < vertices; ++vertex) {
                for (uint16_t word : shape.vertices[vertex]) put(word);
                put(shape.data_1000[vertex]);
            }
        }
    } else if (!tangents) {
        // 0x1401D7760: models pack three position words, then three normal words
        // when present, starting at texel zero. The shipped tangent branch writes
        // no data; retaining its zero texture avoids inventing a third layout.
        for (const auto& shape : morph.sections) {
            for (std::size_t vertex = 0; vertex < vertices; ++vertex) {
                for (uint16_t word : shape.vertices[vertex]) put(word);
                if (normals) for (uint16_t word : shape.data_400[vertex]) put(word);
            }
        }
    }
    return image;
}

void RegisterPuppetMorphImages(WPMdl& mdl, RuntimeImageSource& images,
                               const std::string& model_name, bool image_puppet) {
    mdl.image_morph_layout = image_puppet;
    if (!mdl.puppet || mdl.puppet->morph_meshes.empty() ||
        (!image_puppet && mdl.puppet->bones.empty())) return;
    const std::size_t count = image_puppet ? std::min<std::size_t>(1, mdl.meshes.size()) : mdl.meshes.size();
    mdl.morph_texture_names.resize(count);
    for (std::size_t mesh = 0; mesh < count; ++mesh) {
        if (mesh >= mdl.morph_sections.size() || mdl.morph_sections[mesh].sections.empty()) continue;
        const std::string name = std::string("__morph/") + (image_puppet ? "image/" : "model/") +
                                 model_name + "/" + std::to_string(mesh);
        auto image = images.StaticImage(name);
        if (!image) {
            image = BuildPuppetMorphImage(mdl, mesh, image_puppet, name);
            if (!image || !images.SetStaticImage(name, image)) continue;
        }
        mdl.morph_texture_names[mesh] = name;
        if (!image_puppet && mesh < mdl.puppet->morph_meshes.size()) {
            mdl.puppet->morph_meshes[mesh].vertices = static_cast<uint32_t>(mdl.meshes[mesh].positions.size());
            mdl.puppet->morph_meshes[mesh].modifiers = false;
        }
    }
}

i32 WPPuppetLayer::blendShapeIndex(std::string_view name) const noexcept {
    if (name.empty() || !m_puppet || m_puppet->morph_meshes.empty()) return -1;
    const auto& shapes = m_puppet->morph_meshes[0].shapes;
    for (std::size_t i = 0; i < shapes.size(); ++i)
        if (SameShapeName(shapes[i].name, name)) return static_cast<i32>(i);
    return -1;
}

std::optional<float> WPPuppetLayer::blendShapeWeight(usize shape) const noexcept {
    if (!m_state || !m_state->m_morph || m_state->m_morph->meshes.empty()) return std::nullopt;
    const auto& weights = m_state->m_morph->meshes[0].weights;
    return shape < weights.size() ? std::optional<float>(weights[shape]) : std::nullopt;
}

bool WPPuppetLayer::setBlendShapeWeight(usize shape, float weight) noexcept {
    if (!std::isfinite(weight) || !blendShapeWeight(shape)) return false;
    auto& mesh = m_state->m_morph->meshes[0];
    mesh.weights[shape] = weight;
    mesh.active[shape] = std::abs(weight) >= std::numeric_limits<float>::epsilon();
    mesh.dirty = true;
    for (auto& write : mesh.writes) if (write.first == shape) { write.second = weight; return true; }
    mesh.writes.emplace_back(static_cast<uint32_t>(shape), weight);
    return true;
}

const PuppetMorphUniforms* WPPuppetLayer::morphUniforms(usize index) noexcept {
    if (!m_state || !m_state->m_morph || !m_puppet || index >= m_state->m_morph->meshes.size()) return nullptr;
    auto& state = m_state->m_morph->meshes[index];
    if (state.weights.empty()) return nullptr;
    if (!state.dirty) return &state.uniforms;
    const auto& info = m_puppet->morph_meshes[index];
    auto& out = state.uniforms;
    std::array<std::pair<uint32_t, float>, 11> active {};
    std::size_t count = 0;
    // Both WE draw paths select the first eleven active indices, then stable-sort
    // those entries by signed weight. This is not a strongest-eleven selection.
    for (std::size_t i = 0; i < state.weights.size() && count < active.size(); ++i)
        if (state.active[i])
            active[count++] = {static_cast<uint32_t>(i), state.weights[i]};
    for (std::size_t i = 1; i < count; ++i) {
        const auto value = active[i];
        std::size_t at = i;
        while (at > 0 && value.second > active[at - 1].second) { active[at] = active[at - 1]; --at; }
        active[at] = value;
    }
    for (std::size_t i = 0; i < 12; ++i) { out.offsets[i] = 0; out.weights[i] = 0; }
    out.offsets[0] = float(count);
    out.weights[0] = info.scale;
    for (std::size_t i = 0; i < count; ++i) {
        out.offsets[i + 1] = float(uint64_t(active[i].first) * info.vertices);
        out.weights[i + 1] = active[i].second;
        if (out.transforms.size() == 0) continue;
        const auto& shape = info.shapes[active[i].first];
        auto transform = linalg::Matrix4f::Identity();
        if (shape.bone < m_state->m_model_bones.size()) {
            const auto& bone = m_state->m_model_bones[shape.bone];
            if (std::abs(bone.linear().determinant()) > 1e-12f) transform = bone.inverse().matrix();
        }
        for (std::size_t lane = 0; lane < 16; ++lane) out.transforms[i * 16 + lane] = transform.data()[lane];
        out.rules[i * 3] = (shape.modifier_flags & 2u) != 0 ? 1.0f : 0.0f;
        out.rules[i * 3 + 1] = shape.range[0];
        out.rules[i * 3 + 2] = shape.range[1];
    }
    state.dirty = false;
    return &out;
}
} // namespace wallpaper
