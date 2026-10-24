#include "support/schema_fixtures.hpp"

#include "Fs/MemBinaryStream.h"
#include "WPSceneParser.hpp"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <utility>
#include <variant>

namespace we_schema
{

using namespace wallpaper;

// ---- file system -------------------------------------------------------------------------

bool MemoryFs::Contains(std::string_view path) const
{
    return files_.find(std::string(path)) != files_.end();
}

std::shared_ptr<fs::IBinaryStream> MemoryFs::Open(std::string_view path)
{
    const auto found = files_.find(std::string(path));
    if (found == files_.end()) return nullptr;
    const std::string& text = found->second;
    return std::make_shared<fs::MemBinaryStream>(std::vector<std::uint8_t>(text.begin(), text.end()));
}

std::shared_ptr<fs::IBinaryStreamW> MemoryFs::OpenW(std::string_view) { return nullptr; }

void MountAssets(fs::VFS& vfs, FileMap files)
{
    vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files)));
}

void Add(FileMap& into, const FileMap& more)
{
    for (const auto& [path, bytes] : more) into[path] = bytes;
}

void PutJson(FileMap& files, const std::string& path, const Json& document)
{
    files[path] = document.dump();
}

// ---- bytes -------------------------------------------------------------------------------

ByteWriter& ByteWriter::Stamp(std::string_view prefix, int version)
{
    char digits[8];
    std::snprintf(digits, sizeof(digits), "%04d", version);
    bytes_.append(prefix);
    bytes_.append(digits, 4);
    bytes_.push_back('\0');
    return *this;
}

ByteWriter& ByteWriter::Str(std::string_view text)
{
    bytes_.append(text);
    bytes_.push_back('\0');
    return *this;
}

ByteWriter& ByteWriter::U8(std::uint8_t value)
{
    bytes_.push_back(static_cast<char>(value));
    return *this;
}

ByteWriter& ByteWriter::U16(std::uint16_t value)
{
    return Raw(std::string_view(reinterpret_cast<const char*>(&value), sizeof(value)));
}

ByteWriter& ByteWriter::U32(std::uint32_t value)
{
    return Raw(std::string_view(reinterpret_cast<const char*>(&value), sizeof(value)));
}

ByteWriter& ByteWriter::I32(std::int32_t value)
{
    return Raw(std::string_view(reinterpret_cast<const char*>(&value), sizeof(value)));
}

ByteWriter& ByteWriter::F32(float value)
{
    return Raw(std::string_view(reinterpret_cast<const char*>(&value), sizeof(value)));
}

ByteWriter& ByteWriter::Raw(std::string_view bytes)
{
    bytes_.append(bytes);
    return *this;
}

ByteWriter& ByteWriter::PatchU32(std::size_t at, std::uint32_t value)
{
    if (at + sizeof(value) <= bytes_.size()) std::memcpy(bytes_.data() + at, &value, sizeof(value));
    return *this;
}

// ---- binary model and texture files ------------------------------------------------------

namespace
{

constexpr std::uint32_t kSkinnedFlags  = 0x00800000u | 0x01000000u | 0x00000008u;
constexpr std::uint32_t kMeshOnlyFlags = 0x00000008u;

// The three corners every test mesh uses, as (x, y, u).
constexpr float kCorners[3][3] = { { 0.0f, 0.0f, 0.0f }, { 1.0f, 0.0f, 0.5f }, { 0.0f, 1.0f, 1.0f } };

// One mesh record of a version-21+ model.
void WriteMesh(ByteWriter& out, std::string_view material, std::uint32_t part_id, bool skinned)
{
    out.Str(material);
    out.U32(0);
    out.F32(-1.0f).F32(-1.0f).F32(0.0f);
    out.F32(1.0f).F32(1.0f).F32(0.0f);
    out.U32(skinned ? kSkinnedFlags : kMeshOnlyFlags);
    out.U32(skinned ? 3 * 52 : 3 * 20);
    for (const auto& corner : kCorners) {
        out.F32(corner[0]).F32(corner[1]).F32(0.0f);
        if (skinned) {
            out.U32(0).U32(0).U32(0).U32(0);
            out.F32(1.0f).F32(0.0f).F32(0.0f).F32(0.0f);
            out.F32(corner[2]).F32(0.5f);
        } else {
            out.F32(corner[2]).F32(0.5f);
        }
    }
    out.U32(6).U16(0).U16(1).U16(2);
    // The second texture-coordinate payload, then the parts table.
    out.U8(1).U8(1).U16(0).U8(0).U32(36);
    for (int i = 0; i < 3; ++i) out.F32(0.25f * static_cast<float>(i)).F32(0.5f).U32(0);
    out.U8(1).U32(16).U32(part_id).U32(0).U32(0).U32(3);
}

// A skeleton block holding `bones` (name, parent index or -1), every bind matrix the identity.
void WriteSkeleton(ByteWriter& out, const std::vector<std::pair<std::string, std::int32_t>>& bones)
{
    out.Stamp("MDLS", 1);
    out.U32(0);
    out.U16(static_cast<std::uint16_t>(bones.size())).U16(0);
    for (const auto& [name, parent] : bones) {
        out.Str(name);
        out.I32(0);
        out.U32(parent < 0 ? 0xFFFFFFFFu : static_cast<std::uint32_t>(parent));
        out.U32(64);
        for (int row = 0; row < 4; ++row) {
            for (int col = 0; col < 4; ++col) out.F32(row == col ? 1.0f : 0.0f);
        }
        out.Str("{}");
    }
}

// The closing animation stamp (no animations) and the trailing zero byte.
void WriteNoAnimations(ByteWriter& out) { out.Stamp("MDLA", 0).U8(0); }

} // namespace

std::string MdlTwoMeshes()
{
    ByteWriter out;
    out.Stamp("MDLV", 21).U32(kSkinnedFlags).U32(1).U32(2);
    WriteMesh(out, "mat/head.json", 10, true);
    WriteMesh(out, "mat/eyes.json", 20, true);
    WriteSkeleton(out, { { "root", -1 } });
    WriteNoAnimations(out);
    return out.Take();
}

std::string MdlMaskedHead()
{
    ByteWriter out;
    out.Stamp("MDLV", 23).U32(kSkinnedFlags).U32(1).U32(2);
    WriteMesh(out, "mat/head.json", 10, true);
    out.U32(1).U32(7).U32(0).Str("mat/head_mask.json").U32(0).U32(1).U32(0).U32(1).U32(0);
    WriteMesh(out, "mat/eyes.json", 20, true);
    out.U32(0);
    WriteSkeleton(out, { { "root", -1 } });
    WriteNoAnimations(out);
    return out.Take();
}

std::string MdlWithAttachment()
{
    ByteWriter out;
    out.Stamp("MDLV", 21).U32(kSkinnedFlags).U32(1).U32(1);
    WriteMesh(out, "mat/head.json", 10, true);
    WriteSkeleton(out, { { "root", -1 }, { "head", 0 } });
    out.Stamp("MDAT", 1);
    const std::size_t end_at = out.Size();
    out.U32(0);
    out.U16(1).U16(1);
    out.Str("hat_anchor");
    // Column-major: the translation is the first three values of the last column.
    for (int col = 0; col < 4; ++col) {
        for (int row = 0; row < 4; ++row) {
            float value = row == col ? 1.0f : 0.0f;
            if (col == 3 && row < 3) value = 4.0f + static_cast<float>(row);
            out.F32(value);
        }
    }
    out.PatchU32(end_at, static_cast<std::uint32_t>(out.Size()));
    WriteNoAnimations(out);
    return out.Take();
}

std::string MdlMeshOnly()
{
    ByteWriter out;
    out.Stamp("MDLV", 21).U32(kMeshOnlyFlags).U32(1).U32(2);
    WriteMesh(out, "mat/head.json", 10, false);
    WriteMesh(out, "mat/eyes.json", 20, false);
    return out.Take();
}

std::string TexVideoMarker()
{
    ByteWriter out;
    out.Stamp("TEXV", 5).Stamp("TEXI", 1);
    out.I32(0).U32(1u << 5);
    out.I32(1).I32(1).I32(1).I32(1).I32(0);
    out.Stamp("TEXB", 3);
    out.I32(1).I32(-1);
    out.I32(1).I32(1).I32(1).I32(0).I32(0).I32(0);
    return out.Take();
}

// ---- file sets ---------------------------------------------------------------------------

namespace
{

constexpr const char* kPlainVertex = R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
uniform mat4 g_ModelViewProjectionMatrix;
void main() {
    gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
    v_TexCoord = a_TexCoord;
}
)";

constexpr const char* kPlainFragment = R"(varying vec2 v_TexCoord;
uniform sampler2D g_Texture0;
void main() {
    gl_FragColor = texSample2D(g_Texture0, v_TexCoord);
}
)";

// The same pass the vertex shaders of a skinned puppet share: the bones are only compiled in
// when the SKINNING combo is on.
constexpr const char* kSkinnedVertex = R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
#if SKINNING
attribute uvec4 a_BlendIndices;
attribute vec4 a_BlendWeights;
uniform mat4x3 g_Bones[BONECOUNT];
#endif
varying vec2 v_TexCoord;
uniform mat4 g_ModelViewProjectionMatrix;
void main() {
    vec3 position = a_Position;
#if SKINNING
    mat4x3 skin = g_Bones[a_BlendIndices.x] * a_BlendWeights.x;
    position = mul(vec4(position, 1.0), skin);
#endif
    gl_Position = mul(vec4(position, 1.0), g_ModelViewProjectionMatrix);
    v_TexCoord = a_TexCoord;
}
)";

constexpr const char* kTintFragment = R"(varying vec2 v_TexCoord;
uniform sampler2D g_Texture0;
uniform float g_Tint; // {"material":"tint","default":0.0}
void main() {
    gl_FragColor = texSample2D(g_Texture0, v_TexCoord) * (1.0 + g_Tint);
}
)";

constexpr const char* kMaskFragment = R"(varying vec2 v_TexCoord;
uniform sampler2D g_Texture0;
uniform sampler2D g_Texture1;
void main() {
    gl_FragColor = texSample2D(g_Texture0, v_TexCoord) * texSample2D(g_Texture1, v_TexCoord);
}
)";

void AddShaderPair(FileMap& files, const std::string& name, const std::string& vertex, const std::string& fragment)
{
    files["/shaders/" + name + ".vert"] = vertex;
    files["/shaders/" + name + ".frag"] = fragment;
}

// A one-pass material file.
Json MaterialJson(const std::string& shader, const Json& textures, const std::string& blending = "translucent",
                  const std::string& cull = "nocull", const std::string& depth_test = "disabled",
                  const std::string& depth_write = "disabled")
{
    return { { "passes", Json::array({ { { "blending", blending },
                                         { "cullmode", cull },
                                         { "depthtest", depth_test },
                                         { "depthwrite", depth_write },
                                         { "shader", shader },
                                         { "textures", textures } } }) } };
}

} // namespace

FileMap GenericImageShaders()
{
    FileMap files;
    AddShaderPair(files, "genericimage", kPlainVertex, kPlainFragment);
    return files;
}

FileMap BasicAssets()
{
    FileMap files = GenericImageShaders();
    PutJson(files, "/image.json", { { "material", "mat.json" }, { "width", 64 }, { "height", 32 } });
    PutJson(files, "/mat.json", MaterialJson("genericimage", Json::array({ "a.tex" })));
    files["/materials/a.tex.tex"] = "";
    PutJson(files, "/particle.json",
            { { "emitter", Json::array({ { { "id", 1 }, { "name", "emit" } } }) },
              { "material", "mat.json" },
              { "maxcount", 4 },
              { "starttime", 0 },
              { "children", Json::array({ { { "name", "child_particle.json" },
                                            { "type", "eventspawn" },
                                            { "maxcount", 3 },
                                            { "origin", Json::array({ 1, 2, 3 }) },
                                            { "scale", Json::array({ 0.5, 0.5, 1 }) },
                                            { "angles", Json::array({ 0, 0, 45 }) } } }) } });
    PutJson(files, "/child_particle.json",
            { { "emitter", Json::array({ { { "id", 2 }, { "name", "child_emit" } } }) },
              { "material", "mat.json" },
              { "maxcount", 2 },
              { "starttime", 1 } });
    return files;
}

FileMap PuppetAssets(const PuppetOptions& options)
{
    FileMap files;
    PutJson(files, "/puppet_image.json", { { "material", "mat/base.json" }, { "width", 64 }, { "height", 32 }, { "puppet", "puppet.mdl" } });
    if (options.mesh_only) {
        files["/puppet.mdl"] = MdlMeshOnly();
    } else if (options.masked) {
        files["/puppet.mdl"] = MdlMaskedHead();
    } else {
        files["/puppet.mdl"] = MdlTwoMeshes();
    }
    PutJson(files, "/mat/base.json", MaterialJson("baseimage", Json::array({ "base.tex" })));
    PutJson(files, "/mat/head.json", MaterialJson("headimage", Json::array({ "head.tex" })));
    if (options.eyes_material) {
        PutJson(files, "/mat/eyes.json",
                MaterialJson("eyesimage", Json::array({ options.eyes_render_target ? "_rt_4FrameBuffer" : "eyes.tex" })));
    }
    AddShaderPair(files, "baseimage", kPlainVertex, kTintFragment);
    AddShaderPair(files, "headimage", kSkinnedVertex, kTintFragment);
    AddShaderPair(files, "eyesimage", kSkinnedVertex, kTintFragment);
    for (const char* texture : { "base", "head", "eyes" }) {
        files[std::string("/materials/") + texture + ".tex.tex"] = "";
    }
    if (options.masked) {
        PutJson(files, "/mat/head_mask.json", MaterialJson("headmaskimage", Json::array({ "head_mask.tex" })));
        AddShaderPair(files, "headmaskimage", kSkinnedVertex, kTintFragment);
        AddShaderPair(files, "clippingmaskimage4", kPlainVertex, kMaskFragment);
        files["/materials/head_mask.tex.tex"] = "";
    }
    return files;
}

namespace
{

constexpr const char* kLeafFragment = R"(varying vec2 v_TexCoord;
uniform sampler2D g_Texture0;
uniform vec3 g_EyePosition;
uniform vec3 g_ViewForward;
uniform vec3 g_ViewUp;
uniform vec3 g_ViewRight;
uniform vec4 g_LightsPosition[4];
void main() {
    vec4 colour = texSample2D(g_Texture0, v_TexCoord);
    colour.rgb += g_EyePosition * 0.0 + g_ViewForward * 0.0 + g_ViewUp * 0.0 + g_ViewRight * 0.0 + g_LightsPosition[0].xyz * 0.0;
    gl_FragColor = colour;
}
)";

} // namespace

std::string LeafMaterialText(const Json& state)
{
    Json pass = { { "shader", "genericimage" }, { "textures", Json::array({ "a.tex" }) } };
    for (const auto& [key, value] : state.items()) pass[key] = value;
    return Json { { "passes", Json::array({ pass }) } }.dump();
}

FileMap LeafModelAssets()
{
    FileMap files;
    files["/planet.mdl"] = MdlMeshOnly();
    files["/mat/head.json"] = LeafMaterialText({ { "blending", "normal" }, { "cullmode", "normal" }, { "depthtest", "enabled" }, { "depthwrite", "enabled" } });
    files["/mat/eyes.json"] = LeafMaterialText({ { "blending", "normal" }, { "cullmode", "nocull" }, { "depthtest", "enabled" }, { "depthwrite", "disabled" } });
    AddShaderPair(files, "genericimage", kPlainVertex, kLeafFragment);
    files["/materials/a.tex.tex"] = "";
    return files;
}

namespace
{

constexpr const char* kBloomExtractFragment = R"(varying vec2 v_TexCoord;
uniform sampler2D g_Texture0;
uniform vec4 g_Texture0Resolution;
uniform float g_BloomStrength; // {"material":"bloomstrength","default":0.0}
uniform float g_BloomThreshold; // {"material":"bloomthreshold","default":0.0}
uniform vec3 g_BloomTint; // {"material":"bloomtint","default":"1 1 1"}
void main() {
    vec4 colour = texSample2D(g_Texture0, v_TexCoord);
    gl_FragColor = vec4(colour.rgb * g_BloomTint * g_BloomStrength * g_BloomThreshold, colour.a) + g_Texture0Resolution * 0.0;
}
)";

constexpr const char* kBloomPlainFragment = R"(varying vec2 v_TexCoord;
uniform sampler2D g_Texture0;
uniform vec4 g_Texture0Resolution;
void main() {
    gl_FragColor = texSample2D(g_Texture0, v_TexCoord) + g_Texture0Resolution * 0.0;
}
)";

constexpr const char* kBloomCombineFragment = R"(varying vec2 v_TexCoord;
uniform sampler2D g_Texture0;
uniform sampler2D g_Texture1;
uniform vec4 g_Texture0Resolution;
void main() {
    gl_FragColor = texSample2D(g_Texture0, v_TexCoord) + texSample2D(g_Texture1, v_TexCoord) + g_Texture0Resolution * 0.0;
}
)";

constexpr const char* kHdrFragment = R"(varying vec2 v_TexCoord;
uniform sampler2D g_Texture0;
uniform sampler2D g_Texture1;
uniform vec4 g_Texture0Resolution;
uniform vec4 g_RenderVar0;
uniform float g_BloomStrength;
uniform vec4 g_BloomBlendParams;
uniform vec3 g_BloomTint;
uniform float g_BloomScatter;
void main() {
    vec4 colour = texSample2D(g_Texture0, v_TexCoord) + texSample2D(g_Texture1, v_TexCoord);
    colour.rgb *= g_BloomTint * g_BloomStrength * g_BloomScatter;
    gl_FragColor = colour + g_RenderVar0 * 0.0 + g_BloomBlendParams * 0.0 + g_Texture0Resolution * 0.0;
}
)";

void AddBloomMaterial(FileMap& files, const std::string& material, const std::string& shader, const Json& extra = Json::object())
{
    Json document = MaterialJson(shader, Json::array({ "a.tex" }));
    for (const auto& [key, value] : extra.items()) document["passes"][0][key] = value;
    PutJson(files, "/materials/util/" + material + ".json", document);
}

} // namespace

FileMap BloomAssets(BloomSet set)
{
    FileMap files;
    files["/materials/a.tex.tex"] = "";
    if (set == BloomSet::Hdr) {
        const std::pair<const char*, const char*> materials[] = {
            { "hdr_downsample_bloom", "hdr_extract" },       { "hdr_downsample", "hdr_down" },
            { "hdr_upsample", "hdr_up" },                    { "hdr_upsample_cubic", "hdr_cubic" },
            { "combine_hdr_upsample_linear", "hdr_combine" },
        };
        for (const auto& [material, shader] : materials) {
            AddBloomMaterial(files, material, shader);
            AddShaderPair(files, shader, kPlainVertex, kHdrFragment);
        }
        return files;
    }
    AddBloomMaterial(files, "downsample_quarter_bloom", "bloom_extract",
                     { { "constantshadervalues", { { "bloomstrength", 9 }, { "bloomthreshold", 9 }, { "bloomtint", "9 9 9" } } } });
    AddShaderPair(files, "bloom_extract", kPlainVertex, kBloomExtractFragment);
    AddBloomMaterial(files, "downsample_eighth_blur_v", "bloom_blur_v");
    AddShaderPair(files, "bloom_blur_v", kPlainVertex, kBloomPlainFragment);
    AddBloomMaterial(files, "blur_h_bloom", "bloom_blur_h");
    AddShaderPair(files, "bloom_blur_h", kPlainVertex, kBloomPlainFragment);
    if (set == BloomSet::Ldr) {
        AddBloomMaterial(files, "combine_ldr", "bloom_combine");
        AddShaderPair(files, "bloom_combine", kPlainVertex, kBloomCombineFragment);
    }
    return files;
}

// ---- scene documents ---------------------------------------------------------------------

namespace
{

Json GeneralBlock(const Json& projection, const Json& patch)
{
    Json general = { { "ambientcolor", Json::array({ 0.2, 0.2, 0.2 }) },
                     { "skylightcolor", Json::array({ 0.3, 0.3, 0.3 }) },
                     { "clearcolor", Json::array({ 0, 0, 0 }) },
                     { "cameraparallax", false },
                     { "cameraparallaxamount", 0 },
                     { "cameraparallaxdelay", 0 },
                     { "cameraparallaxmouseinfluence", 0 },
                     { "orthogonalprojection", projection } };
    for (const auto& [key, value] : patch.items()) general[key] = value;
    return general;
}

Json CameraBlock(const Json& eye)
{
    return { { "center", Json::array({ 0, 0, 0 }) }, { "eye", eye }, { "up", Json::array({ 0, 1, 0 }) } };
}

} // namespace

Json QuietScene(Json objects, const Json& general_patch)
{
    return { { "camera", CameraBlock(Json::array({ 0, 0, 1 })) },
             { "general", GeneralBlock({ { "width", 640 }, { "height", 360 } }, general_patch) },
             { "objects", std::move(objects) } };
}

Json PerspectiveScene(Json objects, const Json& general_patch)
{
    Json patch = { { "fov", 60 }, { "nearz", 0.1 }, { "farz", 5000 } };
    for (const auto& [key, value] : general_patch.items()) patch[key] = value;
    return { { "camera", CameraBlock(Json::array({ 0, 10, 20 })) },
             { "general", GeneralBlock(nullptr, patch) },
             { "objects", std::move(objects) } };
}

Json CanvasWithCameraObject(const Json& camera_patch)
{
    Json camera = { { "id", 9 },
                    { "name", "shot" },
                    { "camera", "default" },
                    { "origin", Json::array({ 0, 0, 500 }) },
                    { "angles", Json::array({ 0, 0, 0 }) },
                    { "fov", 50 } };
    for (const auto& [key, value] : camera_patch.items()) camera[key] = value;
    Json image = { { "id", 310 },
                   { "name", "canvas image" },
                   { "image", "image.json" },
                   { "alignment", "bottomleft" },
                   { "scale", Json::array({ 1, 1, 1 }) },
                   { "angles", Json::array({ 0, 0, 0 }) },
                   { "visible", true } };
    Json scene = QuietScene(Json::array({ camera, image }));
    scene["camera"] = { { "center", Json::array({ 0, 0, -1 }) }, { "eye", Json::array({ 0, 0, 0 }) }, { "up", Json::array({ 0, 1, 0 }) } };
    return scene;
}

namespace
{

Json Track(double from, double to)
{
    return Json::array({ { { "frame", 0 }, { "value", from } }, { { "frame", 30 }, { "value", to } } });
}

} // namespace

Json CameraPathClip(double start_x, bool visible, int fps, const std::string& mode)
{
    return { { "visible", visible },
             { "options", { { "fps", fps }, { "length", 30 }, { "mode", mode } } },
             { "eye", { { "c0", Track(start_x, start_x + 2) }, { "c1", Track(0, 0) }, { "c2", Track(10, 10) } } },
             { "center", { { "c0", Track(start_x, start_x + 2) }, { "c1", Track(0, 0) }, { "c2", Track(0, 0) } } },
             { "up", { { "c0", Track(0, 0) }, { "c1", Track(1, 1) }, { "c2", Track(0, 0) } } },
             { "fov", Track(40, 60) } };
}

std::string CameraPathsText(const std::vector<Json>& clips)
{
    return Json { { "paths", Json(clips) } }.dump();
}

// ---- parsing -----------------------------------------------------------------------------

ParseRig::ParseRig(FileMap assets)
    : vfs_(std::make_unique<fs::VFS>()),
      sound_(std::make_unique<audio::SoundManager>(audio::SoundManager::OutputBackend::Null))
{
    MountAssets(*vfs_, std::move(assets));
}

ParseRig::~ParseRig()
{
    scene_.reset();
    sound_.reset();
    vfs_.reset();
}

std::shared_ptr<Scene> ParseRig::Parse(const Json& scene_json, ParseOptions options)
{
    return Parse(scene_json.dump(), options);
}

std::shared_ptr<Scene> ParseRig::Parse(const std::string& scene_text, ParseOptions options)
{
    WPSceneParser     parser;
    SceneParseRequest request;
    request.scene_id    = "schema-test";
    request.pkg_version = options.pkg_version;
    if (options.live) request.project_properties = &properties_;
    scene_ = parser.Parse(request, scene_text, *vfs_, *sound_);
    return scene_;
}

// ---- reading a parsed scene --------------------------------------------------------------

SceneNode* FindChild(SceneNode& parent, std::string_view name)
{
    for (const auto& child : parent.GetChildren()) {
        if (child != nullptr && child->Name() == name) return child.get();
    }
    return nullptr;
}

SceneNode* FindRootChild(Scene& scene, std::string_view name)
{
    return scene.sceneGraph == nullptr ? nullptr : FindChild(*scene.sceneGraph, name);
}

std::array<float, 3> VertexPosition(const SceneVertexArray& vertices, std::size_t index)
{
    const float* at = vertices.Data() + index * vertices.OneSize();
    return { at[0], at[1], at[2] };
}

std::array<float, 2> VertexUv(const SceneVertexArray& vertices, std::size_t index)
{
    const float* at = vertices.Data() + index * vertices.OneSize();
    return { at[4], at[5] };
}

const ScenePostProcessPass* PassStep(const ScenePostProcess& chain, std::size_t index)
{
    return index < chain.steps.size() ? std::get_if<ScenePostProcessPass>(&chain.steps[index]) : nullptr;
}

const ScenePostProcessCopy* CopyStep(const ScenePostProcess& chain, std::size_t index)
{
    return index < chain.steps.size() ? std::get_if<ScenePostProcessCopy>(&chain.steps[index]) : nullptr;
}

bool NearArray(const std::array<float, 3>& actual, const std::array<float, 3>& expected, float tolerance)
{
    for (std::size_t i = 0; i < 3; ++i) {
        if (!(std::abs(actual[i] - expected[i]) <= tolerance)) return false;
    }
    return true;
}

} // namespace we_schema
