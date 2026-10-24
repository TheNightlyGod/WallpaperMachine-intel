#include "support/scene_package.hpp"

#include <algorithm>
#include <bit>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <stdexcept>

#include <unistd.h>

namespace we_test
{
namespace
{

namespace disk = std::filesystem;

// A little-endian byte writer for the texture container.
struct Bytes {
    std::string data;
    void        u8(uint8_t v) { data.push_back(static_cast<char>(v)); }
    void        u32(uint32_t v)
    {
        for (unsigned n = 0; n != 4; ++n) u8(static_cast<uint8_t>(v >> (8 * n)));
    }
    /// A stamp is its text followed by a zero byte.
    void stamp(const char* text)
    {
        data += text;
        u8(0);
    }
};

// Flag bits of the container's header word.
constexpr uint32_t kFlagPoint = 1u << 0;
constexpr uint32_t kFlagClamp = 1u << 1;

std::string Vec3Text(const std::array<float, 3>& v)
{
    char text[96];
    std::snprintf(text, sizeof(text), "%.6f %.6f %.6f", static_cast<double>(v[0]),
                  static_cast<double>(v[1]), static_cast<double>(v[2]));
    return text;
}

std::string Vec2Text(const std::array<float, 2>& v)
{
    char text[64];
    std::snprintf(text, sizeof(text), "%.6f %.6f", static_cast<double>(v[0]),
                  static_cast<double>(v[1]));
    return text;
}

// A half-size copy, each texel the mean of the 2x2 block it replaces.
Image Halve(const Image& source)
{
    const uint32_t width  = std::max(1u, source.width / 2);
    const uint32_t height = std::max(1u, source.height / 2);
    Image          out    = Image::Solid(width, height, { 0, 0, 0, 0 });
    for (uint32_t y = 0; y < height; ++y) {
        for (uint32_t x = 0; x < width; ++x) {
            std::array<unsigned, 4> sum {};
            unsigned                count = 0;
            for (uint32_t dy = 0; dy < 2; ++dy) {
                for (uint32_t dx = 0; dx < 2; ++dx) {
                    const uint32_t sx = std::min(source.width - 1, x * 2 + dx);
                    const uint32_t sy = std::min(source.height - 1, y * 2 + dy);
                    const Rgba     px = source.At(sx, sy);
                    for (std::size_t c = 0; c < 4; ++c) sum[c] += px[c];
                    ++count;
                }
            }
            out.Set(x, y,
                    { static_cast<uint8_t>((sum[0] + count / 2) / count),
                      static_cast<uint8_t>((sum[1] + count / 2) / count),
                      static_cast<uint8_t>((sum[2] + count / 2) / count),
                      static_cast<uint8_t>((sum[3] + count / 2) / count) });
        }
    }
    return out;
}

const char kVertexShader[] = R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
uniform mat4 g_ModelViewProjectionMatrix;
void main() {
    gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
    v_TexCoord = a_TexCoord;
}
)";

// The layer's colour and alpha arrive as g_Color4; the picture is the first texture.
const char kImageFragment[] = R"(varying vec2 v_TexCoord;
uniform sampler2D g_Texture0;
uniform vec4 g_Color4;
void main() {
    gl_FragColor = texSample2D(g_Texture0, v_TexCoord) * g_Color4;
}
)";

const char kTintFragment[] = R"(varying vec2 v_TexCoord;
uniform sampler2D g_Texture0;
uniform vec3 g_Tint; // {"material":"tint","default":"1 1 1"}
void main() {
    vec4 texel = texSample2D(g_Texture0, v_TexCoord);
    gl_FragColor = vec4(texel.rgb * g_Tint, texel.a);
}
)";

} // namespace

// ---- textures ----------------------------------------------------------------------------

std::string MakeTexWithLevels(const std::vector<Image>& levels, TexOptions options)
{
    if (levels.empty() || levels.front().empty()) throw std::invalid_argument("a texture needs a picture");
    const Image& base = levels.front();
    Bytes        b;
    b.stamp("TEXV0005");
    b.stamp("TEXI0001");
    b.u32(0); // pixel format 0: RGBA8
    b.u32((options.point_sampling ? kFlagPoint : 0u) | (options.clamp ? kFlagClamp : 0u));
    b.u32(base.width);
    b.u32(base.height);
    b.u32(base.width); // the visible extent is the whole picture
    b.u32(base.height);
    b.u32(0xff000000u);
    b.stamp("TEXB0002");
    b.u32(1); // one picture
    b.u32(static_cast<uint32_t>(levels.size()));
    for (const Image& level : levels) {
        const auto bytes = static_cast<uint32_t>(level.rgba.size());
        b.u32(level.width);
        b.u32(level.height);
        b.u32(0); // not compressed
        b.u32(bytes);
        b.u32(bytes);
        b.data.append(reinterpret_cast<const char*>(level.rgba.data()), level.rgba.size());
    }
    return b.data;
}

std::string MakeTex(const Image& image, TexOptions options)
{
    std::vector<Image> levels { image };
    while (static_cast<int>(levels.size()) < options.mip_levels &&
           (levels.back().width > 1 || levels.back().height > 1)) {
        levels.push_back(Halve(levels.back()));
    }
    return MakeTexWithLevels(levels, options);
}

std::string MakeTex(Rgba colour) { return MakeTex(Image::Solid(1, 1, colour)); }

std::string MakePng(const Image& image) { return EncodePng(image); }

// ---- JSON builders -----------------------------------------------------------------------

Json PropertyBinding(const std::string& property, const Json& fallback)
{
    return { { "user", property }, { "value", fallback } };
}

Json ScriptedValue(const std::string& source, const Json& initial, const Json& properties)
{
    return { { "script", source }, { "scriptproperties", properties }, { "value", initial } };
}

Json ImageLayerJson(const ImageLayer& layer)
{
    Json object = {
        { "id", layer.id },
        { "name", layer.name },
        { "image", layer.model },
        { "origin", Vec3Text(layer.origin) },
        { "size", Vec2Text(layer.size) },
        { "color", layer.color },
        { "alpha", layer.alpha },
        { "visible", layer.visible },
    };
    if (layer.parent >= 0) object["parent"] = layer.parent;
    if (!layer.effects.empty()) object["effects"] = layer.effects;
    for (const auto& [key, value] : layer.extra.items()) object[key] = value;
    return object;
}

Json GroupJson(int id, const std::string& name, std::array<float, 3> origin, int parent)
{
    Json object = { { "id", id }, { "name", name }, { "origin", Vec3Text(origin) } };
    if (parent >= 0) object["parent"] = parent;
    return object;
}

Json EffectUse(const std::string& effect_file, const Json& constants, int id)
{
    Json use = { { "file", effect_file },
                 { "passes", Json::array({ { { "constantshadervalues", constants } } }) } };
    if (id != 0) use["id"] = id;
    return use;
}

Json CameraJson()
{
    return { { "center", "0 0 0" }, { "eye", "0 0 1" }, { "up", "0 1 0" } };
}

Json GeneralJson(const SceneGeneral& general)
{
    Json block = {
        { "orthogonalprojection", { { "width", general.canvas_width }, { "height", general.canvas_height } } },
        { "clearcolor", Vec3Text(general.clear_color) },
        { "bloom", false },
        { "hdr", false },
        { "camerashake", false },
        { "cameraparallax", general.parallax },
        { "cameraparallaxamount", general.parallax_amount },
        { "cameraparallaxdelay", general.parallax_delay },
        { "cameraparallaxmouseinfluence", general.parallax_mouse_influence },
    };
    for (const auto& [key, value] : general.extra.items()) block[key] = value;
    return block;
}

Json SceneJson(const SceneGeneral& general, const std::vector<Json>& objects)
{
    return { { "camera", CameraJson() }, { "general", GeneralJson(general) }, { "objects", objects } };
}

Json ColorProperty(const std::string& value)
{
    return { { "type", "color" }, { "text", "colour" }, { "value", value } };
}

Json SliderProperty(double value, double minimum, double maximum)
{
    return { { "type", "slider" }, { "text", "slider" }, { "value", value }, { "min", minimum }, { "max", maximum } };
}

Json BoolProperty(bool value) { return { { "type", "bool" }, { "text", "switch" }, { "value", value } }; }

std::string_view StandardVertexShader() { return kVertexShader; }

// ---- the project folder ------------------------------------------------------------------

ScenePackage::ScenePackage()
{
    std::string pattern = (disk::temp_directory_path() / "we-scene-package-XXXXXX").string();
    if (::mkdtemp(pattern.data()) == nullptr) throw std::runtime_error("cannot create a scratch folder");
    root_ = pattern;
}

ScenePackage::~ScenePackage()
{
    std::error_code ignored;
    if (!root_.empty()) disk::remove_all(root_, ignored);
}

void ScenePackage::Put(const std::string& relative_path, std::string_view bytes)
{
    const disk::path full = root_ / relative_path;
    disk::create_directories(full.parent_path());
    std::ofstream out(full, std::ios::binary | std::ios::trunc);
    out.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
    if (!out) throw std::runtime_error("cannot write " + full.string());
}

void ScenePackage::PutJson(const std::string& relative_path, const Json& document)
{
    Put(relative_path, document.dump());
}

bool ScenePackage::Contains(const std::string& relative_path) const
{
    return disk::exists(root_ / relative_path);
}

void ScenePackage::SetProject(const Json& properties)
{
    PutJson("project.json", { { "title", "synthetic scene" },
                              { "type", "scene" },
                              { "file", "scene.json" },
                              { "general", { { "properties", properties } } } });
}

void ScenePackage::SetScene(const Json& scene) { PutJson("scene.json", scene); }

void ScenePackage::AddShader(const std::string& name, std::string_view vertex, std::string_view fragment)
{
    Put("shaders/" + name + ".vert", vertex);
    Put("shaders/" + name + ".frag", fragment);
}

void ScenePackage::InstallStandardAssets()
{
    if (standard_assets_) return;
    standard_assets_ = true;
    AddShader("harness_image", kVertexShader, kImageFragment);
    AddShader("harness_tint", kVertexShader, kTintFragment);
    Put("materials/util/white.tex", MakeTex(Rgba { 255, 255, 255, 255 }));
}

std::string ScenePackage::AddTexture(const std::string& name, const Image& image, TexOptions options)
{
    Put("materials/" + name + ".tex", MakeTex(image, options));
    return name;
}

std::string ScenePackage::AddPngTexture(const std::string& name, const Image& image)
{
    Put("materials/" + name + ".png", EncodePng(image));
    return name;
}

std::string ScenePackage::AddImageModel(const std::string& name, const std::string& texture, ModelOptions options)
{
    InstallStandardAssets();
    const std::string material = "materials/" + name + ".json";
    const std::string model    = "models/" + name + ".json";
    PutJson(material, { { "passes", Json::array({ { { "shader", options.shader },
                                                     { "textures", Json::array({ texture }) },
                                                     { "blending", options.blending },
                                                     { "cullmode", "nocull" },
                                                     { "depthtest", "disabled" },
                                                     { "depthwrite", "disabled" } } }) } });
    PutJson(model, { { "material", material }, { "autosize", false } });
    return model;
}

std::string ScenePackage::AddTintEffect(const std::string& name)
{
    InstallStandardAssets();
    const std::string material = "materials/" + name + ".json";
    const std::string effect   = "effects/" + name + ".json";
    PutJson(material, { { "passes", Json::array({ { { "shader", "harness_tint" },
                                                     { "textures", Json::array({ nullptr }) },
                                                     { "blending", "disabled" },
                                                     { "cullmode", "nocull" },
                                                     { "depthtest", "disabled" },
                                                     { "depthwrite", "disabled" } } }) } });
    PutJson(effect, { { "name", name }, { "passes", Json::array({ { { "material", material } } }) } });
    return effect;
}

void ScenePackage::MakeSolidScene(Rgba colour)
{
    const std::string model = AddImageModel("solid");
    ImageLayer        layer;
    layer.model = model;
    layer.color = Vec3Text({ colour[0] / 255.0f, colour[1] / 255.0f, colour[2] / 255.0f });
    layer.alpha = colour[3] / 255.0;
    SetProject();
    SetScene(SceneJson({}, { ImageLayerJson(layer) }));
}

} // namespace we_test
