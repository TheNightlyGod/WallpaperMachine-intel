#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <limits>
#include <map>
#include <memory>
#include <optional>
#include <span>
#include <stdexcept>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>
#include <cstring>

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>
#include <Eigen/Dense>

#include "Fs/Fs.h"
#include "Fs/MemBinaryStream.h"
#include "Fs/VFS.h"
#include "Audio/SoundManager.h"
#include "Project/ProjectProperties.hpp"
#include "Particle/ParticleSystem.h"
#include "Runtime/DynamicValue.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/SceneSettingResolver.hpp"
#include "Runtime/RuntimeImageSource.hpp"
#include "Runtime/ScriptedDynamicValue.hpp"

#include <cmath>
#include "Scene/SceneCamera.h"
#include "Scene/SceneUpdateDemand.hpp"
#include "Scene/SceneNode.h"
#include "SpecTexs.hpp"
#include "Type.hpp"
#include "WPShaderValueUpdater.hpp"
#include "Scene/Parse/LayerParallax.hpp"
#include "Interface/IShaderValueUpdater.h"
#include "WPSceneParser.hpp"
#include "wpscene/WPImageObject.h"
#include "wpscene/WPMiscObject.hpp"
#include "wpscene/WPParticleObject.h"
#include "Scene/Parse/WPSoundParser.hpp"
#include "wpscene/WPSoundObject.h"
#include "wpscene/WPScene.h"
#include "Utils/Logging.h"
#include "Scripting/ScriptEngine.hpp"

namespace
{
using namespace wallpaper;

class MemoryFs final : public fs::Fs {
public:
    explicit MemoryFs(std::map<std::string, std::string> files): m_files(std::move(files)) {}

    bool Contains(std::string_view path) const override {
        return m_files.contains(std::string(path));
    }

    std::shared_ptr<fs::IBinaryStream> Open(std::string_view path) override {
        const auto it = m_files.find(std::string(path));
        if (it == m_files.end()) return nullptr;
        const auto& s = it->second;
        return std::make_shared<fs::MemBinaryStream>(std::vector<uint8_t>(s.begin(), s.end()));
    }

    std::shared_ptr<fs::IBinaryStreamW> OpenW(std::string_view) override { return nullptr; }

private:
    std::map<std::string, std::string> m_files;
};

class Bytes {
public:
    void Stamp(std::string_view prefix, int version) {
        char stamp[9] {};
        std::snprintf(stamp, sizeof(stamp), "%.4s%.4d", prefix.data(), version);
        Raw(std::span<const uint8_t>(reinterpret_cast<const uint8_t*>(stamp), sizeof(stamp)));
    }
    void Str(std::string_view value) {
        Raw(std::span<const uint8_t>(reinterpret_cast<const uint8_t*>(value.data()), value.size()));
        U8(0);
    }
    void U8(uint8_t value) { RawValue(value); }
    void U16(uint16_t value) { RawValue(value); }
    void U32(uint32_t value) { RawValue(value); }
    void I32(int32_t value) { RawValue(value); }
    void F32(float value) { RawValue(value); }
    std::size_t Size() const { return m_bytes.size(); }
    void PatchU32(std::size_t offset, uint32_t value) {
        ASSERT_LE(offset + sizeof(value), m_bytes.size());
        std::memcpy(m_bytes.data() + offset, &value, sizeof(value));
    }

    std::string TakeString() {
        return std::string(reinterpret_cast<const char*>(m_bytes.data()), m_bytes.size());
    }

private:
    template<typename T>
    void RawValue(const T& value) {
        Raw(std::span<const uint8_t>(reinterpret_cast<const uint8_t*>(&value), sizeof(value)));
    }
    void Raw(std::span<const uint8_t> bytes) {
        m_bytes.insert(m_bytes.end(), bytes.begin(), bytes.end());
    }

    std::vector<uint8_t> m_bytes;
};

constexpr uint32_t kSceneTestSkinUvFlag = 0x00800000u | 0x01000000u | 0x00000008u;
constexpr uint32_t kSceneTestVideoFlag = 1u << 5;

void WriteMeshOnlyPuppetVertex(Bytes& b, float x, float y, float u) {
    b.F32(x);
    b.F32(y);
    b.F32(0.0f);
    b.F32(u);
    b.F32(0.5f);
}

void WritePuppetVertex(Bytes& b, float x, float y, float u, uint32_t bone = 0) {
    b.F32(x);
    b.F32(y);
    b.F32(0.0f);
    b.U32(bone);
    b.U32(0);
    b.U32(0);
    b.U32(0);
    b.F32(1.0f);
    b.F32(0.0f);
    b.F32(0.0f);
    b.F32(0.0f);
    b.F32(u);
    b.F32(0.5f);
}

void WriteMeshOnlyPuppetMesh(Bytes& b, std::string_view material, uint32_t part_id) {
    b.Str(material);
    b.U32(0);
    b.F32(-1.0f);
    b.F32(-1.0f);
    b.F32(0.0f);
    b.F32(1.0f);
    b.F32(1.0f);
    b.F32(0.0f);
    b.U32(0x00000008u);
    b.U32(3u * 20u);
    WriteMeshOnlyPuppetVertex(b, 0.0f, 0.0f, 0.0f);
    WriteMeshOnlyPuppetVertex(b, 1.0f, 0.0f, 0.5f);
    WriteMeshOnlyPuppetVertex(b, 0.0f, 1.0f, 1.0f);
    b.U32(6);
    b.U16(0);
    b.U16(1);
    b.U16(2);
    b.U8(1);
    b.U8(1);
    b.U16(0);
    b.U8(0);
    b.U32(36);
    for (uint32_t i = 0; i < 3; ++i) {
        b.F32(0.25f * static_cast<float>(i));
        b.F32(0.5f);
        b.U32(0);
    }
    b.U8(1);
    b.U32(16);
    b.U32(part_id);
    b.U32(0);
    b.U32(0);
    b.U32(3);
}

void WritePuppetMesh(Bytes& b, std::string_view material, uint32_t part_id) {
    b.Str(material);
    b.U32(0);
    b.F32(-1.0f);
    b.F32(-1.0f);
    b.F32(0.0f);
    b.F32(1.0f);
    b.F32(1.0f);
    b.F32(0.0f);
    b.U32(kSceneTestSkinUvFlag);
    b.U32(3u * 52u);
    WritePuppetVertex(b, 0.0f, 0.0f, 0.0f);
    WritePuppetVertex(b, 1.0f, 0.0f, 0.5f);
    WritePuppetVertex(b, 0.0f, 1.0f, 1.0f);
    b.U32(6);
    b.U16(0);
    b.U16(1);
    b.U16(2);
    b.U8(1);
    b.U8(1);
    b.U16(0);
    b.U8(0);
    b.U32(36);
    for (uint32_t i = 0; i < 3; ++i) {
        b.F32(0.25f * static_cast<float>(i));
        b.F32(0.5f);
        b.U32(0);
    }
    b.U8(1);
    b.U32(16);
    b.U32(part_id);
    b.U32(0);
    b.U32(0);
    b.U32(3);
}

void WriteIdentity3x4(Bytes& b) {
    for (int col = 0; col < 4; ++col) {
        for (int row = 0; row < 4; ++row) {
            b.F32(row == col ? 1.0f : 0.0f);
        }
    }
}

void WriteTranslate3x4(Bytes& b, float x, float y, float z) {
    for (int col = 0; col < 4; ++col) {
        for (int row = 0; row < 4; ++row) {
            float value = row == col ? 1.0f : 0.0f;
            if (col == 3 && row == 0) value = x;
            if (col == 3 && row == 1) value = y;
            if (col == 3 && row == 2) value = z;
            b.F32(value);
        }
    }
}

std::string BuildTwoMeshPuppetMdlFixture() {
    Bytes b;
    b.Stamp("MDL", 21);
    b.U32(kSceneTestSkinUvFlag);
    b.U32(1);
    b.U32(2);
    WritePuppetMesh(b, "mat/head.json", 10);
    WritePuppetMesh(b, "mat/eyes.json", 20);

    b.Stamp("MDLS", 1);
    b.U32(0);
    b.U16(1);
    b.U16(0);
    b.Str("root");
    b.I32(0);
    b.U32(0xFFFFFFFFu);
    b.U32(64);
    WriteIdentity3x4(b);
    b.Str("{}");

    b.Stamp("MDLA", 0);
    b.U8(0);
    return b.TakeString();
}

std::string BuildMaskedTwoMeshPuppetMdlFixture() {
    Bytes b;
    b.Stamp("MDL", 23);
    b.U32(kSceneTestSkinUvFlag);
    b.U32(1);
    b.U32(2);
    WritePuppetMesh(b, "mat/head.json", 10);
    b.U32(1);
    b.U32(7);
    b.U32(0);
    b.Str("mat/head_mask.json");
    b.U32(0);
    b.U32(1);
    b.U32(0);
    b.U32(1);
    b.U32(0);
    WritePuppetMesh(b, "mat/eyes.json", 20);
    b.U32(0);

    b.Stamp("MDLS", 1);
    b.U32(0);
    b.U16(1);
    b.U16(0);
    b.Str("root");
    b.I32(0);
    b.U32(0xFFFFFFFFu);
    b.U32(64);
    WriteIdentity3x4(b);
    b.Str("{}");

    b.Stamp("MDLA", 0);
    b.U8(0);
    return b.TakeString();
}

std::string BuildAttachmentPuppetMdlFixture() {
    Bytes b;
    b.Stamp("MDL", 21);
    b.U32(kSceneTestSkinUvFlag);
    b.U32(1);
    b.U32(1);
    WritePuppetMesh(b, "mat/head.json", 10);

    b.Stamp("MDLS", 1);
    b.U32(0);
    b.U16(2);
    b.U16(0);
    b.Str("root");
    b.I32(0);
    b.U32(0xFFFFFFFFu);
    b.U32(64);
    WriteIdentity3x4(b);
    b.Str("{}");
    b.Str("head");
    b.I32(0);
    b.U32(0);
    b.U32(64);
    WriteIdentity3x4(b);
    b.Str("{}");

    b.Stamp("MDAT", 1);
    const auto mdat_end_offset_pos = b.Size();
    b.U32(0);
    b.U16(1);
    b.U16(1);
    b.Str("hat_anchor");
    WriteTranslate3x4(b, 4.0f, 5.0f, 6.0f);
    b.PatchU32(mdat_end_offset_pos, static_cast<uint32_t>(b.Size()));

    b.Stamp("MDLA", 0);
    b.U8(0);
    return b.TakeString();
}

std::string BuildMeshOnlyPuppetMdlFixture() {
    Bytes b;
    b.Stamp("MDL", 21);
    b.U32(0x00000008u);
    b.U32(1);
    b.U32(2);
    WriteMeshOnlyPuppetMesh(b, "mat/head.json", 10);
    WriteMeshOnlyPuppetMesh(b, "mat/eyes.json", 20);
    return b.TakeString();
}

std::string BuildVideoTexFixture() {
    Bytes b;
    b.Stamp("TEXV", 5);
    b.Stamp("TEXI", 1);
    b.I32(0);
    b.U32(kSceneTestVideoFlag);
    b.I32(1);
    b.I32(1);
    b.I32(1);
    b.I32(1);
    b.I32(0);
    b.Stamp("TEXB", 3);
    b.I32(1);
    b.I32(static_cast<int32_t>(ImageType::UNKNOWN));
    b.I32(1);
    b.I32(1);
    b.I32(1);
    b.I32(0);
    b.I32(0);
    b.I32(0);
    return b.TakeString();
}

void MountSceneFiles(fs::VFS& vfs) {
    auto files = std::map<std::string, std::string> {
        { "/image.json", R"({"width":64,"height":32,"material":"mat.json"})" },
        { "/mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["a.tex"]}]})" },
        { "/shaders/genericimage.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/genericimage.frag",
          R"(uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)" },
        { "/materials/a.tex.tex", "" },
        { "/particle.json",
          R"({"emitter":[{"name":"emit","id":1}],"material":"mat.json","maxcount":4,"starttime":0,
              "children":[{"name":"child_particle.json","type":"eventspawn","maxcount":3,
                "origin":[1,2,3],"scale":[0.5,0.5,1],"angles":[0,0,45]}]})" },
        { "/child_particle.json",
          R"({"emitter":[{"name":"child_emit","id":2}],"material":"mat.json","maxcount":2,"starttime":1})" },
    };
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
}

std::string PuppetMaterialJson(std::string_view shader,
                               std::string_view texture) {
    return std::string(R"({"passes":[{"blending":"translucent","cullmode":"nocull",)"
                       R"("depthtest":"disabled","depthwrite":"disabled","shader":")") +
           std::string(shader) + R"(","textures":[")" + std::string(texture) + R"("]}]})";
}

std::string PuppetMaterialJson(std::string_view                        shader,
                               std::initializer_list<std::string_view> textures) {
    std::string texture_json;
    for (const auto texture : textures) {
        if (! texture_json.empty()) texture_json += ",";
        texture_json += "\"" + std::string(texture) + "\"";
    }
    return std::string(R"({"passes":[{"blending":"translucent","cullmode":"nocull",)"
                       R"("depthtest":"disabled","depthwrite":"disabled","shader":")") +
           std::string(shader) + R"(","textures":[)" + texture_json + R"(]}]})";
}

void AddPuppetImageSceneFiles(std::map<std::string, std::string>& files,
                              bool                               include_eyes_material = true,
                              bool                               mesh_only_puppet = false) {
    files["/puppet_image.json"] =
        R"({"width":64,"height":32,"material":"mat/base.json","puppet":"puppet.mdl"})";
    files["/puppet.mdl"] = mesh_only_puppet ? BuildMeshOnlyPuppetMdlFixture()
                                          : BuildTwoMeshPuppetMdlFixture();
    files["/mat/base.json"] = PuppetMaterialJson("baseimage", "base.tex");
    files["/mat/head.json"] = PuppetMaterialJson("headimage", "head.tex");
    if (include_eyes_material) {
        files["/mat/eyes.json"] = PuppetMaterialJson("eyesimage", "eyes.tex");
    }
    files["/shaders/baseimage.vert"] = R"(
attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)";
    files["/shaders/baseimage.frag"] = R"(
uniform sampler2D g_Texture0;
uniform float g_Tint; // {"material":"tint","default":0.0}
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord) * g_Tint;
}
)";
    files["/shaders/headimage.vert"] = R"(
attribute vec3 a_Position;
attribute vec2 a_TexCoord;
#if SKINNING
attribute uvec4 a_BlendIndices;
attribute vec4 a_BlendWeights;
uniform mat4x3 g_Bones[BONECOUNT];
#endif
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)";
    files["/shaders/headimage.frag"] = R"(
uniform sampler2D g_Texture0;
uniform float g_Tint; // {"material":"tint","default":0.0}
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord) * g_Tint;
}
)";
    files["/shaders/eyesimage.vert"] = files["/shaders/headimage.vert"];
    files["/shaders/eyesimage.frag"] = R"(
uniform sampler2D g_Texture0;
uniform float g_Tint; // {"material":"tint","default":0.0}
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord) * g_Tint;
}
)";
    files["/materials/base.tex.tex"] = "";
    files["/materials/head.tex.tex"] = "";
    files["/materials/eyes.tex.tex"] = "";
}

void AddPuppetSlotRenderTargetSceneFiles(std::map<std::string, std::string>& files) {
    AddPuppetImageSceneFiles(files);
    files["/mat/eyes.json"] = PuppetMaterialJson("eyesimage", "_rt_4FrameBuffer");
}

void AddMaskedTwoMeshPuppetSceneFiles(std::map<std::string, std::string>& files) {
    AddPuppetImageSceneFiles(files);
    files["/puppet.mdl"] = BuildMaskedTwoMeshPuppetMdlFixture();
    files["/mat/head_mask.json"] = PuppetMaterialJson("headmaskimage", "head_mask.tex");
    files["/materials/head_mask.tex.tex"] = "";
    files["/materials/mat/head_mask.json.tex"] = "";
    files["/shaders/clippingmaskimage4.vert"] = files["/shaders/headimage.vert"];
    files["/shaders/clippingmaskimage4.frag"] = R"(
uniform sampler2D g_Texture0;
uniform sampler2D g_Texture1;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord) * texture(g_Texture1, v_TexCoord);
}
)";
}

void AddMultiVideoImageSceneFiles(std::map<std::string, std::string>& files) {
    files["/image.json"] =
        R"({"width":64,"height":32,"material":"mat/multi_video.json"})";
    files["/mat/multi_video.json"] =
        PuppetMaterialJson("multivideo", { "diffuse.tex", "mask.tex" });
    files["/shaders/multivideo.vert"] = R"(
attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)";
    files["/shaders/multivideo.frag"] = R"(
uniform sampler2D g_Texture0;
uniform sampler2D g_Texture1;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord) + texture(g_Texture1, v_TexCoord);
}
)";
    const auto video_tex = BuildVideoTexFixture();
    files["/materials/diffuse.tex.tex"] = video_tex;
    files["/materials/mask.tex.tex"] = video_tex;
}

std::string BasicImageSceneJson() {
    return R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "bloom":false, "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":310,"name":"video image","image":"image.json",
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true}
      ]
    })";
}

std::string DynamicImageSceneJson() {
    return R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":310,"name":"valid scripted image","image":"valid.json",
         "origin":{"value":[4,0,0],"script":"export function update(value) { return value; }"},
         "angles":[0,0,0],"visible":true},
        {"id":311,"name":"failed dynamic image","image":"image.json",
         "origin":{"value":[0,0,0],"script":"export function update(value) { return value; }"},
         "scale":{"value":[1,1,1],"user":"scaleProperty"},
         "angles":[0,0,0],"visible":true}
      ]
    })";
}

std::string DynamicParticleSceneJson() {
    return R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":310,"name":"valid scripted particle","particle":"valid_particle.json",
         "origin":{"value":[4,0,0],"script":"export function update(value) { return value; }"},
         "angles":[0,0,0],"visible":true},
        {"id":312,"name":"failed dynamic particle","particle":"particle.json",
         "origin":{"value":[0,0,0],"script":"export function update(value) { return value; }"},
         "scale":{"value":[1,1,1],"user":"scaleProperty"},
         "angles":[0,0,0],
         "visible":{"value":true,"script":"thisScene.on('cursorClick', function() { thisScene.getLayer('failed dynamic particle').visible = false; });"}}
      ]
    })";
}

std::string BasicPuppetSceneJson(bool dynamic_alpha = false) {
    return std::string(R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":300,"name":"puppet image","image":"puppet_image.json",
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true, "alpha":)") +
           (dynamic_alpha
                ? R"({"value":0.6,"animation":{"c0":[{"frame":0,"value":0.6},{"frame":1,"value":0.3}],"options":{"fps":30}}})"
                : "0.6") +
           R"(}
      ]
    })";
}

std::string PuppetParallaxSceneJson() {
    return R"({
      "camera": {"center":[10,0,0], "eye":[10,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":true,
        "cameraparallaxamount":2, "cameraparallaxdelay":0.25,
        "cameraparallaxmouseinfluence":1,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":300,"name":"puppet image","image":"puppet_image.json",
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true,
         "alpha":0.6, "parallaxDepth":[0.5,0.25]}
      ]
    })";
}

std::shared_ptr<SceneNode> FindRootChildByName(const Scene& scene, std::string_view name) {
    if (scene.sceneGraph == nullptr) return nullptr;
    const auto& root_children = scene.sceneGraph->GetChildren();
    auto        it            = std::find_if(
        root_children.begin(), root_children.end(), [name](const auto& node) {
            return node != nullptr && node->Name() == name;
        });
    if (it == root_children.end()) return nullptr;
    return *it;
}

SceneNode* FindFirstChildByName(SceneNode& node, std::string_view name) {
    auto child = std::find_if(node.GetChildren().begin(), node.GetChildren().end(),
                              [name](const auto& candidate) {
                                  return candidate != nullptr && candidate->Name() == name;
                              });
    return child == node.GetChildren().end() ? nullptr : child->get();
}

std::array<float, 3> VertexPosition(const SceneVertexArray& vertices, std::size_t index) {
    EXPECT_LT(index, vertices.VertexCount());
    const float* data = vertices.Data() + index * vertices.OneSize();
    return { data[0], data[1], data[2] };
}

std::array<float, 2> VertexUv(const SceneVertexArray& vertices, std::size_t index) {
    EXPECT_LT(index, vertices.VertexCount());
    const float* data = vertices.Data() + index * vertices.OneSize();
    return { data[4], data[5] };
}

void ExpectVec3Near(std::array<float, 3> actual, std::array<float, 3> expected, float tolerance) {
    EXPECT_NEAR(actual[0], expected[0], tolerance);
    EXPECT_NEAR(actual[1], expected[1], tolerance);
    EXPECT_NEAR(actual[2], expected[2], tolerance);
}

void ExpectVec2Near(std::array<float, 2> actual, std::array<float, 2> expected, float tolerance) {
    EXPECT_NEAR(actual[0], expected[0], tolerance);
    EXPECT_NEAR(actual[1], expected[1], tolerance);
}

void MountBloomSceneFiles(fs::VFS& vfs) {
    auto files = std::map<std::string, std::string> {
        { "/materials/util/downsample_quarter_bloom.json",
          R"({"passes":[{"blending":"normal","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"bloom_downsample_quarter","textures":["_rt_default"],"constantshadervalues":{"bloomstrength":[9.0],"bloomthreshold":[9.0],"bloomtint":[9.0,9.0,9.0]}}]})" },
        { "/materials/util/downsample_eighth_blur_v.json",
          R"({"passes":[{"blending":"normal","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"bloom_blur_v","textures":["_rt_bloom_mip1"]}]})" },
        { "/materials/util/blur_h_bloom.json",
          R"({"passes":[{"blending":"normal","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"bloom_blur_h","textures":["_rt_bloom_mip2"]}]})" },
        { "/materials/util/combine_ldr.json",
          R"({"passes":[{"blending":"normal","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"bloom_combine_ldr","textures":["_rt_default","_rt_bloom_mip1"]}]})" },
        { "/shaders/bloom_downsample_quarter.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/bloom_downsample_quarter.frag",
          R"(uniform sampler2D g_Texture0;
uniform float g_BloomStrength; // {"material":"bloomstrength","default":0.0}
uniform float g_BloomThreshold; // {"material":"bloomthreshold","default":0.0}
uniform vec3 g_BloomTint; // {"material":"bloomtint","default":"1 1 1"}
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord) * g_BloomStrength;
}
)" },
        { "/shaders/bloom_blur_v.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/bloom_blur_v.frag",
          R"(uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)" },
        { "/shaders/bloom_blur_h.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/bloom_blur_h.frag",
          R"(uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)" },
        { "/shaders/bloom_combine_ldr.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/bloom_combine_ldr.frag",
          R"(uniform sampler2D g_Texture0;
uniform sampler2D g_Texture1;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord) + texture(g_Texture1, v_TexCoord);
}
)" },
    };
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
}

void MountBrokenBloomSceneFiles(fs::VFS& vfs) {
    auto files = std::map<std::string, std::string> {
        { "/materials/util/downsample_quarter_bloom.json",
          R"({"passes":[{"blending":"normal","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"bloom_downsample_quarter","textures":["_rt_default"]}]})" },
        { "/materials/util/downsample_eighth_blur_v.json",
          R"({"passes":[{"blending":"normal","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"bloom_blur_v","textures":["_rt_bloom_mip1"]}]})" },
        { "/materials/util/blur_h_bloom.json",
          R"({"passes":[{"blending":"normal","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"bloom_blur_h","textures":["_rt_bloom_mip2"]}]})" },
        { "/shaders/bloom_downsample_quarter.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/bloom_downsample_quarter.frag",
          R"(uniform sampler2D g_Texture0;
uniform float g_BloomStrength; // {"material":"bloomstrength","default":0.0}
uniform float g_BloomThreshold; // {"material":"bloomthreshold","default":0.0}
uniform vec3 g_BloomTint; // {"material":"bloomtint","default":"1 1 1"}
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord) * g_BloomStrength;
}
)" },
        { "/shaders/bloom_blur_v.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/bloom_blur_v.frag",
          R"(uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)" },
        { "/shaders/bloom_blur_h.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/bloom_blur_h.frag",
          R"(uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)" },
    };
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
}

// Stand-ins for Wallpaper Engine's HDR bloom materials, each with a shader of
// its own name so a test can tell the passes apart.
void AddHdrBloomFixtureFiles(std::map<std::string, std::string>& files) {
    const std::string vert = "attribute vec3 a_Position;\nattribute vec2 a_TexCoord;\n"
                             "varying vec2 v_TexCoord;\nvoid main() {\n"
                             "  gl_Position = vec4(a_Position, 1.0);\n  v_TexCoord = a_TexCoord;\n}\n";
    const std::string frag =
        "uniform sampler2D g_Texture0;\nuniform vec4 g_RenderVar0;\n"
        "uniform float g_BloomStrength;\nuniform vec4 g_BloomBlendParams;\nuniform vec3 g_BloomTint;\n"
        "uniform float g_BloomScatter;\nvarying vec2 v_TexCoord;\n"
        "void main() {\n  gl_FragColor = texture(g_Texture0, v_TexCoord + g_RenderVar0.xy) *\n"
        "      g_BloomStrength * g_BloomScatter * g_BloomBlendParams.x * g_BloomTint.x;\n}\n";
    for (const auto& [material, shader] : std::array<std::pair<const char*, const char*>, 5> {
             std::pair { "hdr_downsample_bloom", "hdr_extract" }, { "hdr_downsample", "hdr_down" },
             { "hdr_upsample", "hdr_up" }, { "hdr_upsample_cubic", "hdr_cubic" },
             { "combine_hdr_upsample_linear", "hdr_combine" } }) {
        files[std::string("/materials/util/") + material + ".json"] =
            std::string(R"({"passes":[{"blending":"normal","cullmode":"nocull","depthtest":"disabled",)"
                        R"("depthwrite":"disabled","shader":")") + shader + R"("}]})";
        files[std::string("/shaders/") + shader + ".vert"] = vert;
        files[std::string("/shaders/") + shader + ".frag"] = frag;
    }
}

std::string BloomSceneJson(bool hdr) {
    return std::string(R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0, "bloom":true,
        "bloomstrength":1.5, "bloomthreshold":0.25,
        "bloomtint":[0.2,0.4,0.6], "hdr":)") +
           (hdr ? "true" : "false") + R"(,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": []
    })";
}

const ScenePostProcessPass* PostProcessPassAt(const ScenePostProcess& post, std::size_t index) {
    if (index >= post.steps.size()) return nullptr;
    return std::get_if<ScenePostProcessPass>(&post.steps[index]);
}

const ScenePostProcessCopy* PostProcessCopyAt(const ScenePostProcess& post, std::size_t index) {
    if (index >= post.steps.size()) return nullptr;
    return std::get_if<ScenePostProcessCopy>(&post.steps[index]);
}

void ExpectTextureResolution(const ScenePostProcessPass& pass, int width, int height) {
    ASSERT_NE(pass.node, nullptr);
    ASSERT_NE(pass.node->Mesh(), nullptr);
    ASSERT_NE(pass.node->Mesh()->Material(), nullptr);
    const auto& constants = pass.node->Mesh()->Material()->customShader.constValues;
    ASSERT_TRUE(constants.contains(WE_GLTEX_RESOLUTION_NAMES[0]));
    const auto& resolution = constants.at(WE_GLTEX_RESOLUTION_NAMES[0]);
    EXPECT_FLOAT_EQ(resolution[0], static_cast<float>(width));
    EXPECT_FLOAT_EQ(resolution[1], static_cast<float>(height));
    EXPECT_FLOAT_EQ(resolution[2], static_cast<float>(width));
    EXPECT_FLOAT_EQ(resolution[3], static_cast<float>(height));
}

} // namespace

TEST(SceneSchema, AbsorbsGeneralKeysAndLightConfig) {
    wpscene::WPScene scene;
    const auto       json = nlohmann::json::parse(R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.1,0.2,0.3], "skylightcolor":[0.4,0.5,0.6],
        "clearcolor":[0.7,0.8,0.9], "cameraparallax":true,
        "cameraparallaxamount":1.5, "cameraparallaxdelay":0.25,
        "cameraparallaxmouseinfluence":0.75, "zoom":2.0,
        "fov":63.0, "nearz":0.5, "farz":9000.0,
        "bloom":true, "bloomstrength":1.25, "bloomthreshold":0.8,
        "hdr":true, "norecompile":true, "bloomtint":[0.2,0.3,0.4],
        "perspectiveoverridefov":70.0, "windenabled":true,
        "winddirection":[1,0,0], "windstrength":3.0,
        "gravitydirection":[0,-1,0], "gravitystrength":9.8,
        "transparentsorting":true, "fogdistance":true,
        "fogdistancestart":10.0, "fogdistanceend":100.0,
        "fogdistancecolor":[0.6,0.7,0.8],
        "fogheight":true, "fogheightstart":2.0, "fogheightend":8.0,
        "fogheightcolor":[0.9,0.8,0.7],
        "lightconfig":{"directional":1,"point":2,"spotshadow":3},
        "orthogonalprojection":{"width":1280,"height":720}
      },
      "objects": []
    })");

    ASSERT_TRUE(scene.FromJson(json));
    EXPECT_TRUE(scene.general.hdr);
    EXPECT_TRUE(scene.general.norecompile);
    EXPECT_FLOAT_EQ(scene.general.bloomtint[2], 0.4f);
    EXPECT_TRUE(scene.general.windenabled);
    EXPECT_FLOAT_EQ(scene.general.windstrength, 3.0f);
    EXPECT_TRUE(scene.general.transparentsorting);
    EXPECT_TRUE(scene.general.fogdistance);
    EXPECT_TRUE(scene.general.fogheight);
    EXPECT_EQ(scene.general.lightconfig.at("point"), 2);
}


TEST(SceneSchema, ImageAbsorbsDependenciesInstanceAnimationLayersAndBindings) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    wpscene::WPImageObject image;
    const auto             json = nlohmann::json::parse(R"({
      "image":"image.json", "id":7, "name":"image layer",
      "dependencies":[1,2], "origin":[1,2,3], "attachment":"hat_anchor",
      "alpha":{"value":0.5,"animation":{"c0":[{"frame":0,"value":0.5}],"options":{"fps":30}}},
      "visible":{"value":true,"script":"export function update() { return true; }",
        "scriptproperties":{"speed":{"value":1.0}}},
      "instance":{"id":42,"combos":{"BLENDMODE":1},"textures":["override.tex"],
        "usertextures":[{"name":"$mediaThumbnail","type":"system"}]},
      "animationlayers":[{"animation":11,"blend":0.75,"rate":1.25,"visible":true,
        "id":3,"name":"blink","additive":true,"blendin":true,"blendout":true,"blendtime":0.4}]
    })");

    ASSERT_TRUE(image.FromJson(json, vfs));
    EXPECT_EQ(image.dependencies, (std::vector<int32_t> { 1, 2 }));
    EXPECT_EQ(image.attachment, "hat_anchor");
    // The instance block is what a solid instance layer overrides its shared
    // model material with, so it has to land on the material the layer renders
    // with — including the system cover slot the scene binds by name.
    ASSERT_FALSE(image.material.textures.empty());
    EXPECT_EQ(image.material.textures[0], "override.tex");
    EXPECT_EQ(image.material.combos.at("BLENDMODE"), 1);
    ASSERT_EQ(image.material.usertextures.size(), 1u);
    EXPECT_EQ(image.material.usertextures[0].name, "$mediaThumbnail");
    EXPECT_EQ(image.material.usertextures[0].type, "system");
    auto bound = image.material.textures;
    ApplySystemUserTextures(bound, image.material.usertextures);
    EXPECT_EQ(bound[0], "$mediaThumbnail");
    ASSERT_EQ(image.puppet_layers.size(), 1u);
    EXPECT_EQ(image.puppet_layers[0].layer_id, 3);
    EXPECT_EQ(image.puppet_layers[0].name, "blink");
    EXPECT_TRUE(image.puppet_layers[0].additive);
    EXPECT_TRUE(image.field_bindings.contains("alpha"));
    EXPECT_TRUE(image.field_bindings.contains("visible"));
}

// The layer colour of a solid instance layer paints the placeholder its shared
// model material ships. Whether it survives depends on whether that placeholder
// is actually replaced: the layer itself can tell for a runtime image, but not
// for a project property, whose value only the parse reads
// (PlaceholderPicture.* in project_property_preview_test).
TEST(SceneSchema, InstanceColourSurvivesUnlessARuntimeImageTakesTheSlot) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    const auto layer = [&vfs](const char* usertexture) {
        wpscene::WPImageObject image;
        const auto             json = nlohmann::json::parse(
            std::string(R"({"image":"image.json","id":7,"color":"0.11765 0.11765 0.11765",
              "instance":{"id":42,"textures":["util/white"],"usertextures":[)") +
            usertexture + "]}}");
        EXPECT_TRUE(image.FromJson(json, vfs));
        return image.color;
    };

    EXPECT_EQ(layer(R"({"name":"$mediaThumbnail","type":"system"})"),
              (std::array<float, 3> { 1.0f, 1.0f, 1.0f }));
    // A `scenetexture` project property may still be unset, which keeps
    // `util/white` in the slot: the layer keeps its tint until the parse knows.
    EXPECT_EQ(layer(R"("backgroundimage")"),
              (std::array<float, 3> { 0.11765f, 0.11765f, 0.11765f }));

    // A colour bound to a user property follows the same rule.
    const auto bound = [&vfs](const char* usertexture) {
        wpscene::WPImageObject image;
        const auto             json = nlohmann::json::parse(
            std::string(R"({"image":"image.json","id":7,
              "color":{"user":"tint","value":"0.11765 0.11765 0.11765"},
              "instance":{"id":42,"textures":["util/white"],"usertextures":[)") +
            usertexture + "]}}");
        EXPECT_TRUE(image.FromJson(json, vfs));
        return image.field_bindings.contains("color");
    };
    EXPECT_FALSE(bound(R"({"name":"$mediaThumbnail","type":"system"})"));
    EXPECT_TRUE(bound(R"("backgroundimage")"));
}

// A layer can be attached to its parent after something has already asked for
// its transform — composition layers build their camera and effect chain during
// parsing, and the scene graph is wired afterwards. The world transform has to
// follow the new parent, or the layer and everything under it draws at its own
// local coordinates.
TEST(SceneSchema, AttachingAParentRefreshesAWorldTransformThatWasAlreadyComputed) {
    auto parent = std::make_shared<SceneNode>();
    parent->SetTranslate({ 2560.0f, 1080.0f, 0.0f });
    auto child = std::make_shared<SceneNode>();
    child->SetTranslate({ 0.0f, 5.0f, 0.0f });

    child->UpdateTrans();
    ASSERT_EQ((child->ModelTrans() * Eigen::Vector4d(0, 0, 0, 1)).head<3>(),
              Eigen::Vector3d(0.0, 5.0, 0.0));

    parent->AppendChild(child);
    child->UpdateTrans();

    EXPECT_EQ((child->ModelTrans() * Eigen::Vector4d(0, 0, 0, 1)).head<3>(),
              Eigen::Vector3d(2560.0, 1085.0, 0.0));

    // The same has to hold deeper than one level: attaching a grandparent to an
    // already-evaluated subtree re-dirties it through MarkTransDirty's
    // recursion, so every descendant picks the new ancestry up.
    auto grandchild = std::make_shared<SceneNode>();
    grandchild->SetTranslate({ 7.0f, 0.0f, 0.0f });
    child->AppendChild(grandchild);
    grandchild->UpdateTrans();
    EXPECT_EQ((grandchild->ModelTrans() * Eigen::Vector4d(0, 0, 0, 1)).head<3>(),
              Eigen::Vector3d(2567.0, 1085.0, 0.0));

    auto root = std::make_shared<SceneNode>();
    root->SetTranslate({ 100.0f, 200.0f, 0.0f });
    root->AppendChild(parent);
    grandchild->UpdateTrans();
    EXPECT_EQ((grandchild->ModelTrans() * Eigen::Vector4d(0, 0, 0, 1)).head<3>(),
              Eigen::Vector3d(2667.0, 1285.0, 0.0));
}

TEST(SceneSchema, MaterialConstantShaderValueUserBindingsSurvivePassParsingAndMerge) {
    const auto material_json = nlohmann::json::parse(R"({
      "passes": [{
        "blending": "translucent",
        "cullmode": "nocull",
        "depthtest": "disabled",
        "depthwrite": "disabled",
        "shader": "genericimage",
        "textures": ["a.tex"],
        "constantshadervalues": {
          "Opacity": { "user": "opacity_user", "value": [0.25] },
          "Tint": { "user": "tint_user", "value": [0.1, 0.2, 0.3] }
        }
      }]
    })");
    wpscene::WPMaterial material;
    ASSERT_TRUE(material.FromJson(material_json));

    ASSERT_TRUE(material.constantshadervalues.contains("Opacity"));
    EXPECT_EQ(material.constantshadervalues.at("Opacity").user, "opacity_user");
    ASSERT_EQ(material.constantshadervalues.at("Opacity").value.size(), 1u);
    EXPECT_FLOAT_EQ(material.constantshadervalues.at("Opacity").value[0], 0.25f);

    wpscene::WPMaterialPass pass;
    ASSERT_TRUE(pass.FromJson(nlohmann::json::parse(R"({
      "constantshadervalues": {
        "Opacity": { "user": "override_opacity", "value": [0.75] }
      }
    })")));

    material.MergePass(pass);

    ASSERT_TRUE(material.constantshadervalues.contains("Opacity"));
    EXPECT_EQ(material.constantshadervalues.at("Opacity").user, "override_opacity");
    ASSERT_EQ(material.constantshadervalues.at("Opacity").value.size(), 1u);
    EXPECT_FLOAT_EQ(material.constantshadervalues.at("Opacity").value[0], 0.75f);
}

TEST(SceneSchema, ParticleAbsorbsInstanceOverrideExtrasAndNestedChildren) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    wpscene::WPParticleObject particle;
    const auto                json = nlohmann::json::parse(R"({
      "particle":"particle.json", "id":9, "name":"particles",
      "dependencies":[7],
      "instanceoverride":{"id":5,"alpha":0.5,"count":2.0,"color":[0.1,0.2,0.3]},
      "origin":{"value":[0,0,0],"scriptproperties":{"x":{"value":1}}},
      "visible":true
    })");

    ASSERT_TRUE(particle.FromJson(json, vfs));
    EXPECT_EQ(particle.dependencies, (std::vector<int32_t> { 7 }));
    EXPECT_TRUE(particle.instanceoverride.enabled);
    EXPECT_EQ(particle.instanceoverride.id, 5);
    EXPECT_TRUE(particle.instanceoverride.overColor);
    EXPECT_TRUE(particle.field_bindings.contains("origin"));
    ASSERT_EQ(particle.particleObj.children.size(), 1u);
    const auto& child = particle.particleObj.children[0];
    EXPECT_EQ(child.name, "child_particle.json");
    EXPECT_EQ(child.type, "eventspawn");
    EXPECT_EQ(child.maxcount, 3);
    EXPECT_FLOAT_EQ(child.origin[1], 2.0f);
    EXPECT_EQ(child.obj.emitters[0].name, "child_emit");
}

TEST(SceneSchema, AbsorbsTextModelAndCameraObjectKinds) {
    fs::VFS vfs;
    MountSceneFiles(vfs);

    wpscene::WPTextObject text;
    ASSERT_TRUE(text.FromJson(nlohmann::json::parse(R"({
      "id":1,"text":{"value":"hello"},"font":"Arial","pointsize":24,
      "padding":4,"horizontalalign":"center","verticalalign":"middle",
      "anchor":"center","maxrows":2,"maxwidth":300,"limitrows":true,
      "limitwidth":true,"limituseellipsis":true,"dependencies":[9],
      "alpha":{"script":"export function update() { return 1; }"}
    })"),
                              vfs));
    EXPECT_EQ(text.text.at("value"), "hello");
    EXPECT_TRUE(text.limituseellipsis);
    EXPECT_TRUE(text.field_bindings.contains("alpha"));

    wpscene::WPModelObject model;
    ASSERT_TRUE(model.FromJson(nlohmann::json::parse(R"({
      "id":2,"model":"model.mdl","attachment":"head","perspective":true,
      "dependencies":[1]
    })"),
                               vfs));
    EXPECT_EQ(model.model, "model.mdl");
    EXPECT_TRUE(model.perspective);

    wpscene::WPCameraObject camera;
    ASSERT_TRUE(camera.FromJson(nlohmann::json::parse(R"({
      "id":3,"camera":"main","path":"camera.json","fov":80,"zoom":1.5,
      "solid":true,"disablepropagation":true
    })"),
                                vfs));
    EXPECT_EQ(camera.camera, "main");
    EXPECT_FLOAT_EQ(camera.zoom, 1.5f);
    EXPECT_TRUE(camera.disablepropagation);
}

TEST(SceneSchema, ParserCreatesTextChildWithoutBreakingLayerParents) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    const std::string   scene = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":100,"name":"group","visible":true},
        {"id":101,"parent":100,"text":"hello","font":"Arial","visible":true}
      ]
    })";

    auto parsed = parser.Parse("schema-only", scene, vfs, sound_manager);
    ASSERT_NE(parsed, nullptr);
    ASSERT_TRUE(parsed->sceneGraph != nullptr);
    EXPECT_TRUE(parsed->HasRenderTarget("_alias_lightCookie"));
    const auto& root_children = parsed->sceneGraph->GetChildren();
    auto group = std::find_if(root_children.begin(), root_children.end(), [](const auto& node) {
        return node != nullptr && node->Name() == "group";
    });
    ASSERT_NE(group, root_children.end());
    EXPECT_EQ((*group)->Parent(), parsed->sceneGraph.get());
    ASSERT_EQ((*group)->GetChildren().size(), 1u);
    EXPECT_EQ((*group)->GetChildren().front()->Name(), "__we_text_101");
    EXPECT_NE((*group)->GetChildren().front()->Mesh(), nullptr);
}

void AddLeafModelSceneFiles(std::map<std::string, std::string>& files) {
    files["/planet.mdl"] = BuildMeshOnlyPuppetMdlFixture();
    files["/mat/head.json"] =
        R"({"passes":[{"blending":"normal","cullmode":"normal","depthtest":"enabled","depthwrite":"enabled","shader":"genericimage","textures":["a.tex"]}]})";
    files["/mat/eyes.json"] =
        R"({"passes":[{"blending":"normal","cullmode":"nocull","depthtest":"enabled","depthwrite":"disabled","shader":"genericimage","textures":["a.tex"]}]})";
    files["/shaders/genericimage.vert"] = R"(
attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)";
    files["/shaders/genericimage.frag"] = R"(
uniform sampler2D g_Texture0;
uniform vec3 g_EyePosition;
uniform vec3 g_ViewForward;
uniform vec3 g_ViewUp;
uniform vec3 g_ViewRight;
uniform vec4 g_LightsPosition[4];
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)";
    files["/materials/a.tex.tex"] = "";
}

std::string PerspectiveSceneJson(std::string_view objects) {
    return std::string(R"({
      "camera": {"center":[0,0,0], "eye":[0,10,20], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":null, "fov":60, "nearz":0.1, "farz":5000
      },
      "objects": )") +
           std::string(objects) + "}";
}

TEST(SceneSchema, ParserInstantiatesLeafModel) {
    auto files = std::map<std::string, std::string> {};
    AddLeafModelSceneFiles(files);
    fs::VFS vfs;
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    auto parsed = parser.Parse("leaf-model",
                               R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":7,"name":"planet","model":"planet.mdl","perspective":true,
         "origin":[3,4,5],"scale":[1,1,1],"angles":[0.1,0.2,0.3],"visible":true}
      ]
    })",
                               vfs,
                               sound_manager);
    ASSERT_NE(parsed, nullptr);
    auto node = FindRootChildByName(*parsed, "planet");
    ASSERT_NE(node, nullptr);
    EXPECT_EQ(node->ID(), 7);
    ExpectVec3Near({ node->Translate().x(), node->Translate().y(), node->Translate().z() },
                   { 3.0f, 4.0f, 5.0f },
                   1e-5f);
    ExpectVec3Near({ node->Rotation().x(), node->Rotation().y(), node->Rotation().z() },
                   { 0.1f, 0.2f, 0.3f },
                   1e-5f);
    EXPECT_EQ(node->Camera(), "global_perspective");
    ASSERT_NE(node->Mesh(), nullptr);
    EXPECT_FALSE(node->Mesh()->Submeshes().empty());
    ASSERT_FALSE(node->Mesh()->MaterialSlots().empty());
    ASSERT_NE(node->Mesh()->Material(), nullptr);
    EXPECT_TRUE(node->Mesh()->Material()->depth_test);
    EXPECT_TRUE(node->Mesh()->Material()->depth_write);
    EXPECT_EQ(node->Mesh()->Material()->cull_mode, CullMode::Back);
    const auto* default_rt = parsed->FindRenderTarget(SpecTex_Default);
    ASSERT_NE(default_rt, nullptr);
    EXPECT_TRUE(default_rt->withDepth);
}

TEST(SceneSchema, ParserRegistersWhatTheCursorMakesOfAModelLayer) {
    // A model is one of the three kinds the cursor is tested against, solid
    // unless the scene says otherwise, and a model can stop the walk too.
    auto files = std::map<std::string, std::string> {};
    AddLeafModelSceneFiles(files);
    fs::VFS vfs;
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager { audio::SoundManager::OutputBackend::Null };
    WPSceneParser       parser;
    ProjectProperties   properties;
    auto parsed = parser.Parse(
        SceneParseRequest { .scene_id = "model-cursor-target", .project_properties = &properties },
        R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":1,"name":"plain","model":"planet.mdl","visible":true},
        {"id":2,"name":"ghost","model":"planet.mdl","solid":false,"visible":true},
        {"id":3,"name":"blocker","model":"planet.mdl","disablepropagation":true,"visible":true}
      ]
    })",
        vfs, sound_manager);
    ASSERT_NE(parsed, nullptr);
    ASSERT_NE(parsed->runtime, nullptr);
    const auto plain = parsed->runtime->NodeCursorTargetOf("plain");
    ASSERT_TRUE(plain.has_value());
    EXPECT_TRUE(plain->hittable);
    EXPECT_TRUE(plain->solid);
    EXPECT_FALSE(plain->blocks);
    const auto ghost = parsed->runtime->NodeCursorTargetOf("ghost");
    ASSERT_TRUE(ghost.has_value());
    EXPECT_FALSE(ghost->solid);
    const auto blocker = parsed->runtime->NodeCursorTargetOf("blocker");
    ASSERT_TRUE(blocker.has_value());
    EXPECT_TRUE(blocker->blocks);
}

TEST(SceneSchema, OrthogonalprojectionNullActivatesPerspective) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    auto parsed = parser.Parse("perspective-camera",
                               PerspectiveSceneJson("[]"),
                               vfs,
                               sound_manager);
    ASSERT_NE(parsed, nullptr);
    ASSERT_NE(parsed->activeCamera, nullptr);
    ASSERT_TRUE(parsed->cameras.contains("global_perspective"));
    EXPECT_EQ(parsed->activeCamera, parsed->cameras.at("global_perspective").get());
    EXPECT_TRUE(parsed->activeCamera->IsPerspective());
    EXPECT_DOUBLE_EQ(parsed->activeCamera->Fov(), 60.0);
    EXPECT_TRUE(parsed->activeCamera->FovLocked());
    const auto eye = parsed->activeCamera->GetPosition();
    EXPECT_NEAR(eye.x(), 0.0, 1e-4);
    EXPECT_NEAR(eye.y(), 10.0, 1e-4);
    EXPECT_NEAR(eye.z(), 20.0, 1e-4);
    const auto forward = parsed->activeCamera->GetDirection().normalized();
    EXPECT_GT(forward.dot(Eigen::Vector3d(0.0, -10.0, -20.0).normalized()), 0.99);
    const auto* default_rt = parsed->FindRenderTarget(SpecTex_Default);
    ASSERT_NE(default_rt, nullptr);
    EXPECT_TRUE(default_rt->withDepth);
}

TEST(SceneSchema, ModelMaterialDefaultsAreOpaqueDepthTestedAndExplicitStateWins) {
    std::map<std::string, std::string> files;
    AddLeafModelSceneFiles(files);
    files["/mat/head.json"] = R"({"passes":[{"shader":"genericimage","textures":["a.tex"]}]})";
    files["/mat/eyes.json"] = R"({"passes":[{"shader":"genericimage","textures":["a.tex"],
      "blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled"}]})";
    fs::VFS vfs;
    ASSERT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager;
    WPSceneParser parser;
    auto scene = parser.Parse("model-depth", PerspectiveSceneJson(R"([
      {"id":1,"name":"model","model":"planet.mdl"}
    ])"), vfs, sound_manager);
    ASSERT_NE(scene, nullptr);
    auto node = FindRootChildByName(*scene, "model");
    ASSERT_NE(node, nullptr);
    ASSERT_EQ(node->Mesh()->MaterialSlots().size(), 2u);
    const auto& opaque = *node->Mesh()->MaterialSlotPtr(0);
    EXPECT_TRUE(opaque.depth_test);
    EXPECT_TRUE(opaque.depth_write);
    EXPECT_EQ(opaque.cull_mode, CullMode::Back);
    EXPECT_EQ(opaque.blenmode, BlendMode::Normal);
    const auto& explicit_state = *node->Mesh()->MaterialSlotPtr(1);
    EXPECT_FALSE(explicit_state.depth_test);
    EXPECT_FALSE(explicit_state.depth_write);
    EXPECT_EQ(explicit_state.cull_mode, CullMode::None);
    EXPECT_EQ(explicit_state.blenmode, BlendMode::Translucent);
}

TEST(SceneSchema, PassStateValuesOutsideWallpaperEnginesListsReadAsTheirFirstEntry) {
    // Wallpaper Engine knows only "disabled"/"enabled" for depthtest and
    // depthwrite and "normal"/"nocull" for cullmode; any other word takes the
    // list's first entry. A depth "compare" is never chosen per material.
    std::map<std::string, std::string> files;
    AddLeafModelSceneFiles(files);
    files["/mat/head.json"] = R"({"passes":[{"shader":"genericimage","textures":["a.tex"],
      "blending":"normal","cullmode":"inverted","depthtest":"greater","depthwrite":"always"}]})";
    files["/mat/eyes.json"] = R"({"passes":[{"shader":"genericimage","textures":["a.tex"],
      "blending":"normal","cullmode":"nocull","depthtest":"less","depthwrite":"enabled"}]})";
    fs::VFS vfs;
    ASSERT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager;
    WPSceneParser parser;
    auto scene = parser.Parse("model-pass-state", PerspectiveSceneJson(R"([
      {"id":1,"name":"model","model":"planet.mdl"}
    ])"), vfs, sound_manager);
    ASSERT_NE(scene, nullptr);
    auto node = FindRootChildByName(*scene, "model");
    ASSERT_NE(node, nullptr);
    ASSERT_EQ(node->Mesh()->MaterialSlots().size(), 2u);
    const auto& unknown = *node->Mesh()->MaterialSlotPtr(0);
    EXPECT_FALSE(unknown.depth_test);
    EXPECT_FALSE(unknown.depth_write);
    EXPECT_EQ(unknown.cull_mode, CullMode::Back);
    const auto& less = *node->Mesh()->MaterialSlotPtr(1);
    EXPECT_FALSE(less.depth_test);
    EXPECT_TRUE(less.depth_write);
    EXPECT_EQ(less.cull_mode, CullMode::None);
    // Drawn as it reads: no depth test means no depth write either.
    EXPECT_FALSE(ResolveSceneDepthState(less, true).write);
}

TEST(SceneSchema, ModelBonesReachEveryMaterialIncludingTheBindPose) {
    std::map<std::string, std::string> files;
    AddPuppetImageSceneFiles(files);
    fs::VFS vfs;
    ASSERT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager;
    WPSceneParser parser;
    ProjectProperties properties;
    auto scene = parser.Parse(SceneParseRequest { .scene_id = "skinned-model", .project_properties = &properties }, PerspectiveSceneJson(R"([
      {"id":1,"name":"model","model":"puppet.mdl",
       "animationlayers":[{"animation":99,"id":7,"name":"motion","blend":1,"rate":2}]}
    ])"), vfs, sound_manager);
    ASSERT_NE(scene, nullptr);
    auto node = FindRootChildByName(*scene, "model");
    ASSERT_NE(node, nullptr);
    auto* layer = scene->runtime->FindPuppetLayer("model");
    ASSERT_NE(layer, nullptr);
    ASSERT_EQ(layer->findLayer("motion"), 0);
    EXPECT_DOUBLE_EQ(layer->rate(0), 2.0);
    // No matching animation clip: even a bind pose must upload identity bones,
    // not leave a skinning shader's uniform array at zero and collapse the mesh.
    sprite_map_t sprites;
    for (uint32_t slot = 0; slot < node->Mesh()->MaterialSlots().size(); ++slot) {
        scene->shaderValueUpdater->InitUniforms(node.get(), slot,
            [](std::string_view name) { return name == "g_Bones"; });
        int writes = 0;
        scene->shaderValueUpdater->UpdateUniforms(node.get(), slot, sprites,
            [&](std::string_view name, const ShaderValue& value) {
                if (name != "g_Bones") return;
                ASSERT_EQ(value.size(), 16u);
                for (int i = 0; i < 16; ++i) EXPECT_FLOAT_EQ(value[i], i % 5 == 0 ? 1 : 0);
                ++writes;
            });
        EXPECT_EQ(writes, 1);
    }
}

TEST(SceneSchema, PerspectiveCameraSelectionFollowsVisibilityWithoutHiddenOverrides) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser parser;
    ProjectProperties properties;
    auto scene = parser.Parse(SceneParseRequest { .scene_id = "camera-selection", .project_properties = &properties }, PerspectiveSceneJson(R"([
      {"id":1,"name":"first","camera":"default","origin":[0,0,12],"fov":45},
      {"id":2,"name":"second","camera":"default","origin":[6,0,8],"fov":75,
       "visible":{"user":"alternate","value":false}}
    ])"), vfs, sound_manager);
    ASSERT_NE(scene, nullptr);
    const auto check = [&](Eigen::Vector3d eye, double fov) {
        EXPECT_TRUE(scene->activeCamera->GetPosition().isApprox(eye, 1e-5));
        EXPECT_DOUBLE_EQ(scene->activeCamera->Fov(), fov);
    };
    check({0,0,12}, 45);
    scene->runtime->Tick(0.1);
    check({0,0,12}, 45);
    ASSERT_TRUE(scene->runtime->SetNodeVisible("second", true));
    scene->runtime->Tick(0.1);
    check({6,0,8}, 75);
    ASSERT_TRUE(scene->runtime->SetNodeVisible("second", false));
    scene->runtime->Tick(0.1);
    check({0,0,12}, 45);
    ASSERT_TRUE(scene->runtime->SetNodeVisible("first", false));
    scene->runtime->Tick(0.1);
    check({0,10,20}, 60); // editor pose when no shot is visible
    EXPECT_EQ(scene->runtime->DescribeTimeAdvancingWork() & SceneDemandReason::Animation, 0u);
}

// A shot without a field of view of its own takes the scene's `fov`.
// `perspectiveoverridefov` is the field of view of a 2D scene's perspective
// layers (Wallpaper Engine reads `fov` when the scene is not orthographic), so
// a perspective scene that carries the key, from a package of any version,
// ignores it.
TEST(SceneSchema, PerspectiveShotsInheritSceneFovUnlessExplicitlyOverridden) {
    for (bool runtime_enabled : {false, true}) {
        for (const auto* camera_name : {"named shot camera", "default"}) {
            for (float ignored_override : {0.0f, 75.0f}) {
                for (const auto& object_fov : std::vector<nlohmann::json> {nullptr, 0, -1, 80}) {
                    SCOPED_TRACE(object_fov.dump() + " " + camera_name + " override " +
                                 std::to_string(ignored_override) +
                                 (runtime_enabled ? " runtime" : " static"));
                    auto source = nlohmann::json::parse(PerspectiveSceneJson(R"([
                      {"id":1,"name":"earlier","camera":"default","origin":[0,0,12],"fov":45},
                      {"id":2,"name":"target","camera":"default","origin":[6,0,8]}
                    ])"));
                    source["general"]["perspectiveoverridefov"] = ignored_override;
                    source["objects"][1]["camera"] = camera_name;
                    if (!object_fov.is_null()) source["objects"][1]["fov"] = object_fov;
                    const double scene_fov = 60.0;
                    const double expected = !object_fov.is_null() && object_fov.get<double>() > 0
                                                ? object_fov.get<double>() : scene_fov;
                    fs::VFS vfs;
                    MountSceneFiles(vfs);
                    audio::SoundManager sound(audio::SoundManager::OutputBackend::Null);
                    ProjectProperties properties;
                    auto scene = WPSceneParser().Parse(SceneParseRequest {
                        .scene_id = "scene-fov-inheritance",
                        .project_properties = runtime_enabled ? &properties : nullptr,
                    }, source.dump(), vfs, sound);
                    ASSERT_NE(scene, nullptr);
                    const bool named = std::string_view(camera_name) != "default";
                    auto* camera = scene->cameras.at(named ? camera_name : "global_perspective").get();
                    ASSERT_EQ(scene->activeCamera, camera);
                    EXPECT_DOUBLE_EQ(camera->Fov(), expected);
                    EXPECT_TRUE(camera->GetPosition().isApprox(Eigen::Vector3d(6,0,8), 1e-5));
                    if (!runtime_enabled) {
                        EXPECT_EQ(scene->runtime, nullptr);
                        continue;
                    }
                    ASSERT_NE(scene->runtime, nullptr);
                    scene->runtime->Tick(0.1);
                    EXPECT_DOUBLE_EQ(camera->Fov(), expected);
                    ASSERT_TRUE(scene->runtime->SetNodeVisible("target", false));
                    scene->runtime->Tick(0.1);
                    EXPECT_EQ(scene->activeCamera, scene->cameras.at("global_perspective").get());
                    EXPECT_DOUBLE_EQ(scene->activeCamera->Fov(), 45);
                    if (named) EXPECT_DOUBLE_EQ(camera->Fov(), expected);
                    ASSERT_TRUE(scene->runtime->SetNodeVisible("earlier", false));
                    scene->runtime->Tick(0.1);
                    EXPECT_DOUBLE_EQ(scene->activeCamera->Fov(), scene_fov);
                    EXPECT_TRUE(scene->activeCamera->GetPosition().isApprox(Eigen::Vector3d(0,10,20), 1e-5));
                    if (named) EXPECT_DOUBLE_EQ(camera->Fov(), expected);
                }
            }
        }
    }
}

nlohmann::json CameraPathFixture(double x) {
    const auto curve = [](double a, double b) {
        return nlohmann::json::array({{{"frame",0},{"value",a}},{{"frame",30},{"value",b}}});
    };
    return {{"visible",true}, {"options",{{"fps",30},{"length",30},{"mode","single"}}},
            {"eye",{{"c0",curve(x,x+2)},{"c1",curve(0,0)},{"c2",curve(10,10)}}},
            {"center",{{"c0",curve(x,x+2)},{"c1",curve(0,0)},{"c2",curve(0,0)}}},
            {"up",{{"c0",curve(0,0)},{"c1",curve(1,1)},{"c2",curve(0,0)}}},
            {"fov",curve(40,60)}};
}

TEST(SceneSchema, PerspectiveCameraPathsSampleAndQueueAuthoredCurves) {
    auto a = CameraPathFixture(0);
    auto b = CameraPathFixture(20);
    auto hidden = CameraPathFixture(100);
    hidden["visible"] = false;
    auto invalid = CameraPathFixture(200);
    invalid["options"]["fps"] = 0;
    std::map<std::string, std::string> files;
    files["/paths.json"] = nlohmann::json({{"paths",{a,hidden,invalid,b}}}).dump();
    fs::VFS vfs;
    ASSERT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager;
    WPSceneParser parser;
    ProjectProperties properties;
    auto scene = parser.Parse(SceneParseRequest { .scene_id = "camera-path", .project_properties = &properties }, PerspectiveSceneJson(R"([
      {"id":1,"name":"moving","camera":"default","path":"paths.json"},
      {"id":2,"name":"hidden preset","camera":"default","origin":[99,99,99],
       "visible":{"user":"alternate","value":false}}
    ])"), vfs, sound_manager);
    ASSERT_NE(scene, nullptr);
    EXPECT_TRUE(scene->activeCamera->GetPosition().isApprox(Eigen::Vector3d(0,0,10), 1e-5));
    scene->runtime->Tick(0.5);
    EXPECT_TRUE(scene->activeCamera->GetPosition().isApprox(Eigen::Vector3d(1,0,10), 1e-5));
    EXPECT_TRUE(scene->activeCamera->GetDirection().isApprox(-Eigen::Vector3d::UnitZ(), 1e-5));
    EXPECT_NEAR(scene->activeCamera->Fov(), 50, 1e-5);
    EXPECT_NE(scene->runtime->DescribeTimeAdvancingWork() & SceneDemandReason::Animation, 0u);
    scene->runtime->Tick(0.75); // overshoot is carried, not discarded at a cut
    EXPECT_NEAR(scene->activeCamera->GetPosition().x(), 20.5, 1e-5);
    scene->runtime->Tick(1.0);
    EXPECT_NEAR(scene->activeCamera->GetPosition().x(), 0.5, 1e-5);
    ASSERT_TRUE(scene->runtime->SetNodeVisible("moving", false));
    scene->runtime->Tick(0.5);
    EXPECT_EQ(scene->runtime->DescribeTimeAdvancingWork() & SceneDemandReason::Animation, 0u);
    EXPECT_TRUE(scene->activeCamera->GetPosition().isApprox(Eigen::Vector3d(0,10,20), 1e-5));
}

TEST(SceneSchema, CameraPathsPreserveSteepAndRolledLookAtOrientation) {
    for (const auto& up : { Eigen::Vector3d(0, 1, 0), Eigen::Vector3d(0.2, 1, 0.3) }) {
        for (const auto& eye : { Eigen::Vector3d(0.001, 10, 0.002),
                                Eigen::Vector3d(10, 0.001, 0.002) }) {
            auto path = CameraPathFixture(0);
            for (int axis = 0; axis < 3; ++axis) {
                const auto key = "c" + std::to_string(axis);
                path["eye"][key] = {{{"frame",0},{"value",eye[axis]}},
                                    {{"frame",30},{"value",axis == 2 ? -eye[axis] : eye[axis]}}};
                path["center"][key] = {{{"frame",0},{"value",0}}};
                path["up"][key] = {{{"frame",0},{"value",up[axis]}}};
            }
            CameraPathPlayback playback(ParseCameraPaths({{"paths",{path}}}), "sequence");
            auto node = std::make_shared<SceneNode>();
            SceneCamera camera(1, 0.1, 100, 50);
            camera.AttatchNode(node);
            for (int frame = 0; frame < 5; ++frame) {
                playback.Apply(*node, camera);
                const Eigen::Vector3d sampled(eye.x(), eye.y(), eye.z() * (1 - frame * 0.4));
                const Eigen::Vector3d forward = -sampled.normalized();
                const Eigen::Vector3d right = forward.cross(up).normalized();
                EXPECT_TRUE(camera.GetDirection().isApprox(forward, 1e-5));
                EXPECT_TRUE(camera.GetUp().isApprox(right.cross(forward), 1e-5));
                EXPECT_TRUE(camera.GetViewMatrix().allFinite());
                playback.Advance(0.2);
            }
        }
    }
}

TEST(SceneSchema, CameraPathsAndLayerTimelinesShareScaledAndZeroDeltas) {
    const auto path = CameraPathFixture(0);
    std::map<std::string, std::string> files;
    files["/paths.json"] = nlohmann::json({{"paths",{path}}}).dump();
    fs::VFS vfs;
    ASSERT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound(audio::SoundManager::OutputBackend::Null);
    WPSceneParser parser;
    ProjectProperties properties;
    auto scene = parser.Parse(SceneParseRequest {
        .scene_id = "shared-camera-clock", .project_properties = &properties,
    }, PerspectiveSceneJson(R"([
      {"id":1,"name":"moving","camera":"default","path":"paths.json"},
      {"id":2,"name":"layer","origin":{"value":[0,0,0],"animation":{
        "options":{"fps":30,"length":30,"mode":"loop"},
        "c0":[{"frame":0,"value":0},{"frame":30,"value":2}]}}}
    ])"), vfs, sound);
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    double elapsed = 0;
    // SceneWallpaper supplies IdeaTime * scene speed to this single Tick.
    // Zero scene speed supplies zero; a paused scene does not tick at all.
    // Resumed/scaled ticks must keep both clocks aligned.
    for (double delta : { 0.1 * 2, 0.0, 0.4 * 0.5, 0.0, 0.8, 0.1 }) {
        elapsed += delta;
        scene->runtime->Tick(delta);
        EXPECT_NEAR(scene->activeCamera->GetPosition().x(), std::fmod(elapsed, 1.0) * 2, 1e-5);
        EXPECT_NEAR(scene->runtime->NodeTranslate("layer").x(), scene->activeCamera->GetPosition().x(), 1e-5);
    }
}

TEST(SceneSchema, PerspectiveFallbackCapturesTheCameraAtFirstRegistrationOnly) {
    Scene scene;
    SceneCamera initial(1, 0.1, 100, 50), editor(1, 0.1, 100, 60), shot_camera(1, 0.1, 100, 70);
    scene.activeCamera = &initial;
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    runtime->AttachScene(&scene);
    scene.activeCamera = &editor; // parser chooses the editor camera before registering shots
    auto shot = std::make_shared<SceneNode>();
    shot->SetVisible(false);
    runtime->RegisterPerspectiveCameraShot(shot, &shot_camera, 45, {});
    EXPECT_EQ(scene.activeCamera, &editor);
    shot->SetVisible(true);
    runtime->Tick(0);
    EXPECT_EQ(scene.activeCamera, &shot_camera);
    auto hidden = std::make_shared<SceneNode>();
    hidden->SetVisible(false);
    runtime->RegisterPerspectiveCameraShot(hidden, &shot_camera, 80, {});
    shot->SetVisible(false);
    runtime->Tick(0);
    EXPECT_EQ(scene.activeCamera, &editor); // registration must not capture a selected shot
}

TEST(SceneSchema, RandomCameraPathsStayWithinAuthoredShotsAndBoundCatchup) {
    const auto paths = ParseCameraPaths({{"paths", {CameraPathFixture(0), CameraPathFixture(20)}}});
    CameraPathPlayback playback(paths, "random");
    SceneNode node;
    SceneCamera camera(1.0f, 0.1f, 1000.0f, 50.0f);
    playback.Apply(node, camera);
    const float first = node.Translate().x();
    EXPECT_TRUE(first == 0 || first == 20);
    playback.Advance(1.0);
    playback.Apply(node, camera);
    EXPECT_FLOAT_EQ(node.Translate().x(), first == 0 ? 20 : 0);
    playback.Advance(1e9);
    playback.Apply(node, camera);
    EXPECT_TRUE(node.Translate().allFinite());
    EXPECT_TRUE(node.Translate().x() >= 0 && node.Translate().x() <= 22);
}

TEST(SceneSchema, DefaultCameraObjectBecomesActivePerspective) {
    auto files = std::map<std::string, std::string> {};
    AddLeafModelSceneFiles(files);
    fs::VFS vfs;
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    auto parsed = parser.Parse(
        "default-camera",
        PerspectiveSceneJson(R"([
        {"id":9,"name":"playcam","camera":"default","origin":[0,0,0.454],
         "angles":[0,0,0],"fov":50,"visible":true},
        {"id":7,"name":"planet","model":"planet.mdl",
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true}
      ])"),
        vfs,
        sound_manager);
    ASSERT_NE(parsed, nullptr);
    ASSERT_NE(parsed->activeCamera, nullptr);
    ASSERT_TRUE(parsed->activeCamera->IsPerspective());
    const auto eye = parsed->activeCamera->GetPosition();
    EXPECT_NEAR(eye.x(), 0.0, 1e-4);
    EXPECT_NEAR(eye.y(), 0.0, 1e-4);
    EXPECT_NEAR(eye.z(), 0.454, 1e-4);
    auto planet = FindRootChildByName(*parsed, "planet");
    ASSERT_NE(planet, nullptr);
    EXPECT_EQ(planet->Camera(), "global_perspective");
}

// A 2D wallpaper's layers are authored against `orthogonalprojection`, so the
// canvas has to stay what gets projected even when the scene also carries a
// camera layer. Letting the layer take over reframes the scene through a
// perspective camera sitting at the authored shot pose -- a few hundred units
// off the canvas plane at fov 50 -- which leaves a magnified sliver of one
// corner where the wallpaper should be.
TEST(SceneSchema, CameraObjectKeepsAnOrthographicSceneOnItsCanvas) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    auto parsed = parser.Parse("ortho-camera-layer",
                               R"({
      "camera": {"center":[0,0,-1], "eye":[0,0,0], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":9,"name":"shot","camera":"default","origin":[0,0,500],
         "angles":[0,0,0],"fov":50},
        {"id":310,"name":"canvas image","image":"image.json",
         "alignment":"bottomleft","scale":[1,1,1],"angles":[0,0,0],"visible":true}
      ]
    })",
                               vfs,
                               sound_manager);
    ASSERT_NE(parsed, nullptr);
    ASSERT_NE(parsed->activeCamera, nullptr);
    EXPECT_FALSE(parsed->activeCamera->IsPerspective());

    const Eigen::Matrix4d projection = parsed->activeCamera->GetViewProjectionMatrix();
    const auto            to_ndc     = [&projection](double x, double y) {
        const Eigen::Vector4d clip = projection * Eigen::Vector4d(x, y, 0.0, 1.0);
        return Eigen::Vector2d(clip.x() / clip.w(), clip.y() / clip.w());
    };
    const auto centre = to_ndc(320.0, 180.0);
    EXPECT_NEAR(centre.x(), 0.0, 1e-6);
    EXPECT_NEAR(centre.y(), 0.0, 1e-6);
    const auto lower_left = to_ndc(0.0, 0.0);
    EXPECT_NEAR(lower_left.x(), -1.0, 1e-6);
    EXPECT_NEAR(lower_left.y(), -1.0, 1e-6);
    const auto upper_right = to_ndc(640.0, 360.0);
    EXPECT_NEAR(upper_right.x(), 1.0, 1e-6);
    EXPECT_NEAR(upper_right.y(), 1.0, 1e-6);

    // The shot is still a layer the scene can read and move, it just does not
    // own the projection.
    EXPECT_NE(FindRootChildByName(*parsed, "shot"), nullptr);
}

// The shot still frames the canvas it does not own: a wallpaper's "camera size"
// slider is the camera object's `zoom`, and a 2D scene has nowhere else to
// spend it now that the fov branch is perspective-only.
std::shared_ptr<Scene> ParseOrthoCameraZoomScene(fs::VFS& vfs, audio::SoundManager& sound_manager,
                                                 const std::string& zoom) {
    WPSceneParser parser;
    return parser.Parse("ortho-camera-zoom",
                        R"({
      "camera": {"center":[0,0,-1], "eye":[0,0,0], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":9,"name":"shot","camera":"default","origin":[0,0,500],
         "angles":[0,0,0],"fov":50,"zoom":)" + zoom + R"(},
        {"id":310,"name":"canvas image","image":"image.json",
         "alignment":"bottomleft","scale":[1,1,1],"angles":[0,0,0],"visible":true}
      ]
    })",
                        vfs,
                        sound_manager);
}

TEST(SceneSchema, CameraObjectZoomTightensTheOrthographicFrustum) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    audio::SoundManager sound_manager;
    auto parsed = ParseOrthoCameraZoomScene(vfs, sound_manager, "2.0");
    ASSERT_NE(parsed, nullptr);
    ASSERT_NE(parsed->activeCamera, nullptr);
    EXPECT_FALSE(parsed->activeCamera->IsPerspective());

    const Eigen::Matrix4d projection = parsed->activeCamera->GetViewProjectionMatrix();
    const auto            to_ndc     = [&projection](double x, double y) {
        const Eigen::Vector4d clip = projection * Eigen::Vector4d(x, y, 0.0, 1.0);
        return Eigen::Vector2d(clip.x() / clip.w(), clip.y() / clip.w());
    };
    // Same centre, half the canvas in view: the corner that used to sit on the
    // edge of the frame is now twice as far out.
    const auto centre = to_ndc(320.0, 180.0);
    EXPECT_NEAR(centre.x(), 0.0, 1e-6);
    EXPECT_NEAR(centre.y(), 0.0, 1e-6);
    const auto upper_right = to_ndc(640.0, 360.0);
    EXPECT_NEAR(upper_right.x(), 2.0, 1e-6);
    EXPECT_NEAR(upper_right.y(), 2.0, 1e-6);

    // Zoom is projection, not canvas: the authored extent the render targets
    // are sized from is untouched.
    EXPECT_NEAR(parsed->activeCamera->Width(), 640.0, 1e-6);
    EXPECT_NEAR(parsed->activeCamera->Height(), 360.0, 1e-6);
}

TEST(SceneSchema, CameraObjectZoomThatIsNotPositiveFramesTheWholeCanvas) {
    for (const auto& zoom : { std::string("0"), std::string("-1.5") }) {
        SCOPED_TRACE(zoom);
        fs::VFS vfs;
        MountSceneFiles(vfs);
        audio::SoundManager sound_manager;
        auto parsed = ParseOrthoCameraZoomScene(vfs, sound_manager, zoom);
        ASSERT_NE(parsed, nullptr);
        ASSERT_NE(parsed->activeCamera, nullptr);

        const Eigen::Matrix4d projection = parsed->activeCamera->GetViewProjectionMatrix();
        const Eigen::Vector4d clip = projection * Eigen::Vector4d(640.0, 360.0, 0.0, 1.0);
        EXPECT_NEAR(clip.x() / clip.w(), 1.0, 1e-6);
        EXPECT_NEAR(clip.y() / clip.w(), 1.0, 1e-6);
    }
}

// Parsed with project properties, as the app always does, so the scene has the
// runtime that plays camera layers.
std::shared_ptr<Scene> ParseOrthoShotScene(fs::VFS& vfs, audio::SoundManager& sound_manager,
                                           std::string_view shots,
                                           ProjectProperties properties = {}) {
    return WPSceneParser().Parse(SceneParseRequest {
                                     .scene_id           = "ortho-camera-shots",
                                     .project_properties = &properties,
                                 },
                                 std::string(R"({
      "camera": {"center":[0,0,-1], "eye":[0,0,0], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [)") + std::string(shots) + R"(,
        {"id":310,"name":"canvas image","image":"image.json",
         "alignment":"bottomleft","scale":[1,1,1],"angles":[0,0,0],"visible":true}
      ]
    })",
                                 vfs,
                                 sound_manager);
}

/// Where the canvas-plane point `canvas` lands in normalised device coordinates
/// when seen through `camera`.
Eigen::Vector2d CanvasToNdc(const SceneCamera& camera, Eigen::Vector2d canvas) {
    const Eigen::Matrix4d projection = camera.GetViewProjectionMatrix();
    const Eigen::Vector4d clip = projection * Eigen::Vector4d(canvas.x(), canvas.y(), 0.0, 1.0);
    return { clip.x() / clip.w(), clip.y() / clip.w() };
}

Eigen::Vector2d CanvasToNdc(const Scene& scene, Eigen::Vector2d canvas) {
    return CanvasToNdc(*scene.activeCamera, canvas);
}

/// The 640x360 canvas is shown `zoom` times closer about the scene point
/// `centre`, by the orthographic camera 2D layers draw through and by the
/// perspective one perspective layers draw through alike.
void ExpectViewFrames(const Scene& scene, Eigen::Vector2d centre, double zoom) {
    ASSERT_NE(scene.activeCamera, nullptr);
    EXPECT_FALSE(scene.activeCamera->IsPerspective());
    const auto perspective = scene.cameras.find("global_perspective");
    ASSERT_NE(perspective, scene.cameras.end());
    for (const SceneCamera* camera : { scene.activeCamera, perspective->second.get() }) {
        SCOPED_TRACE(camera->IsPerspective() ? "perspective camera" : "orthographic camera");
        const auto middle = CanvasToNdc(*camera, centre);
        EXPECT_NEAR(middle.x(), 0.0, 1e-4);
        EXPECT_NEAR(middle.y(), 0.0, 1e-4);
        const auto corner = CanvasToNdc(*camera, centre + Eigen::Vector2d(320.0, 180.0) / zoom);
        EXPECT_NEAR(corner.x(), 1.0, 1e-4);
        EXPECT_NEAR(corner.y(), 1.0, 1e-4);
    }
}

// A camera layer's timeline is how a 2D intro moves the view. The editor keys
// the shot's zoom and, linked to it, an origin that is an offset from the
// canvas centre; one playhead drives both, and a relative origin curve offsets
// the authored origin. Held at the whole canvas, the intro of a wallpaper that
// opens close on a planet and pulls back to its rest shot never played.
TEST(SceneSchema, CameraObjectTimelineGlidesFromItsFirstShotToWhereItRests) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    audio::SoundManager sound_manager;
    auto parsed = ParseOrthoShotScene(vfs, sound_manager, R"(
        {"id":9,"name":"shot","camera":"default","angles":[0,0,0],"fov":50,
         "origin":{"value":"-40 20 500","animation":{"relative":true,
           "options":{"fps":12,"length":24,"mode":"single","parent":{"key":"zoom"}},
           "c0":[{"frame":0,"value":100},{"frame":12,"value":40}],
           "c1":[{"frame":0,"value":50},{"frame":12,"value":-20}],
           "c2":[{"frame":0,"value":0},{"frame":12,"value":0}]}},
         "zoom":{"value":1,"animation":{
           "options":{"fps":12,"length":24,"mode":"single","children":[{"key":"origin"}]},
           "c0":[{"frame":0,"value":2},{"frame":12,"value":1}]}}})");
    ASSERT_NE(parsed, nullptr);
    ASSERT_NE(parsed->runtime, nullptr);

    // The first key: twice as close, centred 60 right of and 70 above the
    // canvas centre (the authored origin plus the curve's first offset).
    ExpectViewFrames(*parsed, { 380.0, 250.0 }, 2.0);

    parsed->runtime->Tick(0.5);
    const double moving = CanvasToNdc(*parsed, { 320.0, 180.0 }).x();
    EXPECT_GT(moving, -0.375 + 1e-3) << "half way through, the shot has not moved";
    EXPECT_LT(moving, -1e-3) << "half way through, the shot has already arrived";
    EXPECT_TRUE(parsed->runtime->DescribeTimeAdvancingWork() & SceneDemandReason::Animation)
        << "a playing intro needs frames";

    // Past the last key it rests where the authored origin and the curve's
    // last offset cancel: the whole canvas. A single-play intro that has ended
    // moves nothing, and a scene whose only motion it was may sleep.
    parsed->runtime->Tick(2.0);
    ExpectViewFrames(*parsed, { 320.0, 180.0 }, 1.0);
    EXPECT_FALSE(parsed->runtime->DescribeTimeAdvancingWork() & SceneDemandReason::Animation)
        << "the intro ended and still keeps the scene awake";
}

// A script writes this shot's origin. Until a tick has run it the layer holds
// whatever the editor last saved, which need not be where the shot is, so the
// view stays centred on the canvas until the script's value arrives: anything
// that reads the camera before the first tick -- the first frame's cursor
// mapping -- must not see the stale one.
TEST(SceneSchema, AScriptedShotOriginFramesTheViewOnceATickHasAppliedIt) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    audio::SoundManager sound_manager;
    auto parsed = ParseOrthoShotScene(vfs, sound_manager, R"(
        {"id":9,"name":"lens","camera":"default","angles":[0,0,0],"fov":50,"zoom":2,
         "origin":{"value":"300 100 500",
                   "script":"export function update(value) { value.x = 20; value.y = -10; return value; }"}})");
    ASSERT_NE(parsed, nullptr);
    ASSERT_NE(parsed->runtime, nullptr);

    ExpectViewFrames(*parsed, { 320.0, 180.0 }, 2.0);
    parsed->runtime->Tick(1.0 / 60.0);
    ExpectViewFrames(*parsed, { 340.0, 170.0 }, 2.0);
}

// Wallpapers offer several shots and pick one with a user property that shows
// it. The last visible camera layer in authored order frames the view,
// decided again every tick; with none visible the whole canvas is shown.
TEST(SceneSchema, TheLastVisibleCameraObjectFramesTheCanvas) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    audio::SoundManager sound_manager;
    auto parsed = ParseOrthoShotScene(vfs, sound_manager, R"(
        {"id":9,"name":"wide shot","camera":"default","origin":[0,0,500],
         "angles":[0,0,0],"fov":50,"zoom":2,
         "visible":{"user":"wide","value":true}},
        {"id":10,"name":"close shot","camera":"default","origin":[100,-40,500],
         "angles":[0,0,0],"fov":50,"zoom":4,
         "visible":{"user":"closeup","value":false}})",
                                      {
                                          { "wide", RuntimeScalarValue::Bool(true) },
                                          { "closeup", RuntimeScalarValue::Bool(false) },
                                      });
    ASSERT_NE(parsed, nullptr);
    ASSERT_NE(parsed->runtime, nullptr);

    ExpectViewFrames(*parsed, { 320.0, 180.0 }, 2.0);

    parsed->runtime->ApplyProjectPropertyOverride({ { "closeup", RuntimeScalarValue::Bool(true) } });
    parsed->runtime->Tick(1.0 / 60.0);
    ExpectViewFrames(*parsed, { 420.0, 140.0 }, 4.0);

    parsed->runtime->ApplyProjectPropertyOverride({
        { "wide", RuntimeScalarValue::Bool(false) },
        { "closeup", RuntimeScalarValue::Bool(false) },
    });
    parsed->runtime->Tick(1.0 / 60.0);
    ExpectViewFrames(*parsed, { 320.0, 180.0 }, 1.0);
}

TEST(SceneSchema, ParserKeepsSceneLightsAndUpdatesViewUniforms) {
    auto files = std::map<std::string, std::string> {};
    AddLeafModelSceneFiles(files);
    fs::VFS vfs;
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    auto parsed = parser.Parse(
        "model-light",
        PerspectiveSceneJson(R"([
        {"id":7,"name":"planet","model":"planet.mdl","perspective":true,
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true},
        {"id":8,"name":"sun","light":"point","origin":[11,22,33],
         "scale":[1,1,1],"angles":[0,0,0],"color":[1,0.5,0.25],
         "radius":1000,"intensity":0.75,"visible":true}
      ])"),
        vfs,
        sound_manager);
    ASSERT_NE(parsed, nullptr);
    ASSERT_EQ(parsed->lights.size(), 1u);
    ASSERT_NE(parsed->lights[0], nullptr);
    ASSERT_NE(parsed->lights[0]->node(), nullptr);
    ExpectVec3Near({ parsed->lights[0]->node()->Translate().x(),
                     parsed->lights[0]->node()->Translate().y(),
                     parsed->lights[0]->node()->Translate().z() },
                   { 11.0f, 22.0f, 33.0f },
                   1e-5f);

    auto node = FindRootChildByName(*parsed, "planet");
    ASSERT_NE(node, nullptr);
    auto* updater = dynamic_cast<WPShaderValueUpdater*>(parsed->shaderValueUpdater.get());
    ASSERT_NE(updater, nullptr);
    updater->InitUniforms(node.get(), 0, [](std::string_view name) {
        return name == "g_EyePosition" || name == "g_ViewForward" || name == "g_ViewUp" ||
               name == "g_ViewRight" || name == "g_LightsPosition";
    });
    std::unordered_map<std::string, std::array<float, 4>> captured;
    sprite_map_t                                          sprites;
    updater->UpdateUniforms(node.get(), sprites, [&](std::string_view name, const ShaderValue& value) {
        if (name == "g_EyePosition" || name == "g_ViewForward" || name == "g_ViewUp" ||
            name == "g_ViewRight") {
            captured[std::string(name)] = { value[0], value[1], value[2], 0.0f };
        }
        if (name == "g_LightsPosition") {
            captured[std::string(name)] = { value[0], value[1], value[2], value[3] };
        }
    });
    ASSERT_TRUE(captured.contains("g_EyePosition"));
    EXPECT_NEAR(captured["g_EyePosition"][0], 0.0f, 1e-3f);
    EXPECT_NEAR(captured["g_EyePosition"][1], 10.0f, 1e-3f);
    EXPECT_NEAR(captured["g_EyePosition"][2], 20.0f, 1e-3f);
    ASSERT_TRUE(captured.contains("g_LightsPosition"));
    EXPECT_NEAR(captured["g_LightsPosition"][0], 11.0f, 1e-3f);
    EXPECT_NEAR(captured["g_LightsPosition"][1], 22.0f, 1e-3f);
    EXPECT_NEAR(captured["g_LightsPosition"][2], 33.0f, 1e-3f);
}

std::string LitPerspectiveSceneJson(std::string_view objects, std::string_view lightconfig) {
    return std::string(R"({
      "camera": {"center":[0,0,0], "eye":[0,10,20], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":null, "fov":60, "nearz":0.1, "farz":5000,
        "lightconfig": )") +
           std::string(lightconfig) + R"(},
      "objects": )" + std::string(objects) + "}";
}

using CapturedUniforms = std::unordered_map<std::string, std::vector<float>>;

CapturedUniforms CaptureLightUniforms(Scene& scene, SceneNode& node) {
    static constexpr std::array kNames {
        "g_LPoint_Color", "g_LPoint_Origin", "g_LSpot_Color", "g_LSpot_Origin",
        "g_LSpot_Direction", "g_LSpot_Exponent", "g_LTube_Color", "g_LTube_OriginA",
        "g_LTube_OriginB", "g_LDirectional_Color", "g_LDirectional_Direction",
        "g_LightsPosition", "g_LightsColorPremultiplied", "g_NormalModelMatrix",
    };
    auto* updater = dynamic_cast<WPShaderValueUpdater*>(scene.shaderValueUpdater.get());
    EXPECT_NE(updater, nullptr);
    CapturedUniforms captured;
    if (updater == nullptr) return captured;
    updater->InitUniforms(&node, 0, [](std::string_view name) {
        return std::find(kNames.begin(), kNames.end(), name) != kNames.end();
    });
    sprite_map_t sprites;
    updater->UpdateUniforms(&node, sprites, [&](std::string_view name, const ShaderValue& value) {
        captured[std::string(name)] = std::vector<float>(value.data(), value.data() + value.size());
    });
    return captured;
}

void ExpectSlot(const CapturedUniforms& captured, const std::string& name, std::size_t slot,
                std::array<float, 4> expected) {
    SCOPED_TRACE(name + "[" + std::to_string(slot) + "]");
    const auto found = captured.find(name);
    ASSERT_NE(found, captured.end());
    ASSERT_GE(found->second.size(), slot * 4 + 4);
    for (std::size_t lane = 0; lane < 4; ++lane) {
        EXPECT_NEAR(found->second[slot * 4 + lane], expected[lane], 1e-4f) << "lane " << lane;
    }
}

Eigen::Vector3d WorldAxisX(SceneNode& node) {
    node.UpdateTrans();
    return node.ModelTrans().block<3, 1>(0, 0);
}

TEST(SceneSchema, LightsOfEachKindFillWallpaperEnginesLightingArrays) {
    std::map<std::string, std::string> files;
    AddLeafModelSceneFiles(files);
    fs::VFS vfs;
    ASSERT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    auto scene = parser.Parse("lights", LitPerspectiveSceneJson(R"([
      {"id":1,"name":"planet","model":"planet.mdl"},
      {"id":10,"name":"bulb","light":"lpoint","origin":"1 2 3","color":"1 0.5 0.25",
       "intensity":2,"radius":50,"exponent":3},
      {"id":11,"name":"off","light":"lpoint","origin":"9 9 9","color":"1 1 1",
       "intensity":5,"radius":50,"visible":false},
      {"id":12,"name":"torch","light":"lspot","origin":"0 0 0","angles":"0 0 1.5707963",
       "color":"0 1 0","intensity":4,"radius":80,"exponent":1.5,"innercone":20,"outercone":30},
      {"id":13,"name":"bar","light":"ltube","origin":"10 0 0","scale":"2 2 2",
       "controlpoint":"5 0 0","color":"1 0 0","intensity":1,"radius":30},
      {"id":20,"name":"rig","origin":"100 0 0","angles":"0 0 0.5"},
      {"id":14,"name":"sun","light":"ldirectional","parent":20,"origin":"1 0 0",
       "color":"1 1 1","intensity":0.5,"radius":200},
      {"id":15,"name":"lamp","light":"point","origin":"7 8 9","color":"1 1 1",
       "intensity":1,"radius":2}
    ])", R"({"point":2,"spot":1,"tube":1,"directional":1})"), vfs, sound_manager);
    ASSERT_NE(scene, nullptr);
    EXPECT_EQ(scene->light_config.point, 2u);
    EXPECT_EQ(scene->light_config.directional, 1u);
    // A light hidden for good is not parsed at all, like any other object.
    ASSERT_EQ(scene->lights.size(), 5u);

    auto planet = FindRootChildByName(*scene, "planet");
    ASSERT_NE(planet, nullptr);
    const auto captured = CaptureLightUniforms(*scene, *planet);

    // A point light: colour times intensity with its radius, origin with its
    // exponent. The unused slot stays zero.
    ExpectSlot(captured, "g_LPoint_Color", 0, { 2.0f, 1.0f, 0.5f, 50.0f });
    ExpectSlot(captured, "g_LPoint_Origin", 0, { 1.0f, 2.0f, 3.0f, 3.0f });
    ExpectSlot(captured, "g_LPoint_Color", 1, { 0.0f, 0.0f, 0.0f, 0.0f });

    // A spot shines along its own x axis, rotated with it; the cone cosines
    // ride in the w lanes.
    const auto* torch = scene->lights[1]->node();
    ASSERT_NE(torch, nullptr);
    const auto  spot_axis = WorldAxisX(*const_cast<SceneNode*>(torch));
    EXPECT_GT(std::abs(spot_axis.y()), 0.99);
    ExpectSlot(captured, "g_LSpot_Color", 0, { 0.0f, 4.0f, 0.0f, 80.0f });
    ExpectSlot(captured, "g_LSpot_Origin", 0, { 0.0f, 0.0f, 0.0f, std::cos(20.0f * 3.14159265f / 180.0f) });
    ExpectSlot(captured, "g_LSpot_Direction", 0,
               { float(spot_axis.x()), float(spot_axis.y()), float(spot_axis.z()),
                 std::cos(30.0f * 3.14159265f / 180.0f) });
    ExpectSlot(captured, "g_LSpot_Exponent", 0, { 1.5f, 0.0f, 0.0f, 0.0f });

    // A tube runs from its origin to its control point carried by its own
    // transform (scaled by two here), with the default exponent.
    ExpectSlot(captured, "g_LTube_OriginA", 0, { 10.0f, 0.0f, 0.0f, 2.0f });
    ExpectSlot(captured, "g_LTube_OriginB", 0, { 20.0f, 0.0f, 0.0f, 0.0f });

    // A directional light follows its parent; its direction points back
    // towards it, against its world x axis.
    auto* sun = scene->lights[3]->node();
    ASSERT_NE(sun, nullptr);
    const auto sun_axis = WorldAxisX(*sun);
    EXPECT_GT(std::abs(sun_axis.y()), 0.4);
    ExpectSlot(captured, "g_LDirectional_Color", 0, { 0.5f, 0.5f, 0.5f, 1.0f });
    ExpectSlot(captured, "g_LDirectional_Direction", 0,
               { float(-sun_axis.x()), float(-sun_axis.y()), float(-sun_axis.z()), 0.0f });

    // Only the older `point` light feeds the four packed legacy lights.
    ExpectSlot(captured, "g_LightsPosition", 0, { 7.0f, 8.0f, 9.0f, 0.0f });
    ExpectSlot(captured, "g_LightsPosition", 1, { 0.0f, 0.0f, 0.0f, 0.0f });
}

TEST(SceneSchema, LightsFollowTheirUserPropertyScriptAndIntensityTimeline) {
    std::map<std::string, std::string> files;
    AddLeafModelSceneFiles(files);
    fs::VFS vfs;
    ASSERT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties {
        { "daynight", RuntimeScalarValue::Bool(true) },
    };
    auto scene = parser.Parse(
        SceneParseRequest { .scene_id = "light-bindings", .project_properties = &properties },
        LitPerspectiveSceneJson(R"([
          {"id":1,"name":"planet","model":"planet.mdl"},
          {"id":10,"name":"day","light":"lpoint","origin":"0 0 0","color":"1 1 1","radius":10,
           "intensity":{"value":1,"animation":{"c0":[{"frame":0,"value":1},{"frame":10,"value":3}],
             "options":{"fps":10,"length":10,"mode":"single"}}},
           "visible":{"user":"daynight","value":true}},
          {"id":11,"name":"moving","light":"lpoint","color":"1 1 1","radius":10,"intensity":1,
           "origin":{"value":"0 0 0","script":"export function update() { return new Vec3(4, 5, 6); }"}}
        ])", R"({"point":2})"),
        vfs,
        sound_manager);
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto planet = FindRootChildByName(*scene, "planet");
    ASSERT_NE(planet, nullptr);

    scene->runtime->Tick(0.5);
    auto captured = CaptureLightUniforms(*scene, *planet);
    // Halfway along its intensity timeline, and the script has moved the other.
    ExpectSlot(captured, "g_LPoint_Color", 0, { 2.0f, 2.0f, 2.0f, 10.0f });
    ExpectSlot(captured, "g_LPoint_Origin", 1, { 4.0f, 5.0f, 6.0f, 2.0f });
    const auto lit_hash = scene->shaderValueUpdater->LightStateHash(planet.get(), 0);
    EXPECT_NE(lit_hash, 0u);

    // Switching the property off takes the light out; the moved one now
    // fills the first slot, and a lit pass sees a different light state.
    scene->runtime->ApplyProjectPropertyOverride({ { "daynight", RuntimeScalarValue::Bool(false) } });
    scene->runtime->Tick(0.01);
    captured = CaptureLightUniforms(*scene, *planet);
    ExpectSlot(captured, "g_LPoint_Origin", 0, { 4.0f, 5.0f, 6.0f, 2.0f });
    ExpectSlot(captured, "g_LPoint_Color", 1, { 0.0f, 0.0f, 0.0f, 0.0f });
    EXPECT_NE(scene->shaderValueUpdater->LightStateHash(planet.get(), 0), lit_hash);
}

TEST(SceneSchema, FogIsCompiledIntoPassesWhoseFogComboIsOnWithWallpaperEnginesParameters) {
    std::map<std::string, std::string> files;
    AddLeafModelSceneFiles(files);
    files["/shaders/foggy.vert"] = R"(
attribute vec3 a_Position;
void main() { gl_Position = vec4(a_Position, 1.0); }
)";
    files["/shaders/foggy.frag"] = R"(// [COMBO] {"material":"fog","combo":"FOG","default":1}
#if FOG_DIST
uniform vec4 g_FogDistanceParams;
#endif
void main() {
  vec4 color = vec4(1.0);
#if FOG_COMPUTED && FOG_DIST
  color.rgb *= g_FogDistanceParams.xyz;
#endif
  gl_FragColor = color;
}
)";
    files["/mat/head.json"] = R"({"passes":[{"shader":"foggy","textures":["a.tex"]}]})";
    files["/mat/eyes.json"] = R"({"passes":[{"shader":"foggy","textures":["a.tex"],"combos":{"FOG":0}}]})";
    fs::VFS vfs;
    ASSERT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    std::string json = PerspectiveSceneJson(R"([{"id":1,"name":"planet","model":"planet.mdl"}])");
    const auto general = json.find("\"general\": {") + std::string("\"general\": {").size();
    json.insert(general, R"("fogdistance":true,"fogdistancestart":2,"fogdistanceend":10,)"
                         R"("fogdistancecolor":[0.5,0.5,0.5],)");
    auto scene = parser.Parse("fog", json, vfs, sound_manager);
    ASSERT_NE(scene, nullptr);
    EXPECT_TRUE(scene->fog_distance);
    EXPECT_FALSE(scene->fog_height);
    auto node = FindRootChildByName(*scene, "planet");
    ASSERT_NE(node, nullptr);
    ASSERT_EQ(node->Mesh()->MaterialSlots().size(), 2u);

    const auto& fogged = *node->Mesh()->MaterialSlotPtr(0);
    ASSERT_NE(fogged.customShader.shader, nullptr);
    ASSERT_TRUE(fogged.customShader.shader->rust_reflection_json.has_value());
    EXPECT_NE(fogged.customShader.shader->rust_reflection_json->find("g_FogDistanceParams"),
              std::string::npos)
        << "a pass whose FOG combo is on was not compiled with distance fog";
    // (start, end - start, start density, end density - start density), with
    // Wallpaper Engine's default densities 0 and 1.
    const auto& params = fogged.customShader.constValues.at("g_FogDistanceParams");
    ASSERT_EQ(params.size(), 4u);
    EXPECT_FLOAT_EQ(params[0], 2.0f);
    EXPECT_FLOAT_EQ(params[1], 8.0f);
    EXPECT_FLOAT_EQ(params[2], 0.0f);
    EXPECT_FLOAT_EQ(params[3], 1.0f);

    const auto& clear = *node->Mesh()->MaterialSlotPtr(1);
    ASSERT_NE(clear.customShader.shader, nullptr);
    ASSERT_TRUE(clear.customShader.shader->rust_reflection_json.has_value());
    EXPECT_EQ(clear.customShader.shader->rust_reflection_json->find("g_FogDistanceParams"),
              std::string::npos)
        << "a pass that turns FOG off was compiled with fog";
}

TEST(SceneSchema, ATextureSlotsTexelIsTheStepOfTheTextureItSamples) {
    std::map<std::string, std::string> files;
    AddLeafModelSceneFiles(files);
    files["/mat/head.json"] =
        R"({"passes":[{"shader":"genericimage","textures":["_rt_4FrameBuffer"]}]})";
    fs::VFS vfs;
    ASSERT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    auto scene = parser.Parse("texel", PerspectiveSceneJson(R"([
      {"id":1,"name":"planet","model":"planet.mdl"}
    ])"), vfs, sound_manager);
    ASSERT_NE(scene, nullptr);
    auto node = FindRootChildByName(*scene, "planet");
    ASSERT_NE(node, nullptr);
    const auto* target = scene->FindRenderTarget("_rt_4FrameBuffer");
    ASSERT_NE(target, nullptr);
    ASSERT_GT(target->width, 0);
    const auto& values = node->Mesh()->MaterialSlotPtr(0)->customShader.constValues;
    ASSERT_TRUE(values.contains("g_Texture0Texel"));
    const auto& texel = values.at("g_Texture0Texel");
    ASSERT_EQ(texel.size(), 4u);
    EXPECT_FLOAT_EQ(texel[0], 1.0f / float(target->width));
    EXPECT_FLOAT_EQ(texel[1], 1.0f / float(target->height));
    EXPECT_FLOAT_EQ(texel[2], float(target->width));
    EXPECT_FLOAT_EQ(texel[3], float(target->height));
}

TEST(SceneSchema, TheSceneCameraShakesAsWallpaperEngineWhileItsPropertyIsOn) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties {
        { "shake", RuntimeScalarValue::Bool(true) },
    };
    std::string json = BasicImageSceneJson();
    const auto general = json.find("\"general\": {") + std::string("\"general\": {").size();
    json.insert(general, R"("camerashake":{"user":"shake","value":true},"camerashakeamplitude":1.0,)"
                         R"("camerashakespeed":2.0,"camerashakeroughness":1.0,)");
    auto scene = parser.Parse(
        SceneParseRequest { .scene_id = "camera-shake", .project_properties = &properties }, json,
        vfs, sound_manager);
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    ASSERT_NE(scene->activeCamera, nullptr);
    const Eigen::Matrix4d still = scene->activeCamera->GetViewProjectionMatrix();

    scene->runtime->Tick(0.25);
    // t = speed^2 * time = 1; amplitude / 10 times a tenth of the canvas height;
    // a 2D scene shakes in its plane only.
    const double amplitude = 1.0 * 0.1 * 360.0 * 0.1;
    const Eigen::Vector3d expected(std::cos(1.0) * amplitude, std::sin(1.333) * amplitude, 0.0);
    EXPECT_TRUE(scene->activeCamera->ShakeOffset().isApprox(expected, 1e-6));
    EXPECT_FALSE(scene->activeCamera->GetViewProjectionMatrix().isApprox(still, 1e-9))
        << "the shake did not move the view";
    EXPECT_NE(scene->runtime->DescribeTimeAdvancingWork() & SceneDemandReason::Animation, 0u);

    scene->runtime->ApplyProjectPropertyOverride({ { "shake", RuntimeScalarValue::Bool(false) } });
    scene->runtime->Tick(0.25);
    EXPECT_TRUE(scene->activeCamera->ShakeOffset().isZero());
    EXPECT_TRUE(scene->activeCamera->GetViewProjectionMatrix().isApprox(still, 1e-9));
    EXPECT_EQ(scene->runtime->DescribeTimeAdvancingWork() & SceneDemandReason::Animation, 0u);
}

TEST(SceneSchema, TheNormalMatrixIsTheDrawsRotationWithoutItsScale) {
    std::map<std::string, std::string> files;
    AddLeafModelSceneFiles(files);
    fs::VFS vfs;
    ASSERT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    auto scene = parser.Parse("normal-matrix", PerspectiveSceneJson(R"([
      {"id":1,"name":"planet","model":"planet.mdl","scale":"3 3 3","angles":"0 0 1.5707963"}
    ])"), vfs, sound_manager);
    ASSERT_NE(scene, nullptr);
    auto planet = FindRootChildByName(*scene, "planet");
    ASSERT_NE(planet, nullptr);
    const auto captured = CaptureLightUniforms(*scene, *planet);
    const auto axis     = WorldAxisX(*planet).normalized();
    // Three std140 columns, each a unit axis of the layer.
    ExpectSlot(captured, "g_NormalModelMatrix", 0,
               { float(axis.x()), float(axis.y()), float(axis.z()), 0.0f });
    const auto& matrix = captured.at("g_NormalModelMatrix");
    ASSERT_EQ(matrix.size(), 12u);
    for (int column = 0; column < 3; ++column) {
        const Eigen::Vector3f v(matrix[column * 4], matrix[column * 4 + 1], matrix[column * 4 + 2]);
        EXPECT_NEAR(v.norm(), 1.0f, 1e-4f);
    }
}

TEST(SceneSchema, ParserKeepsInvisibleImageDependencySources) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    const std::string   scene = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":159,"name":"dependency source","image":"image.json",
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":false},
        {"id":160,"name":"consumer","image":"image.json","dependencies":[159],
         "origin":[8,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true}
      ]
    })";

    auto parsed = parser.Parse("invisible-dependency-source", scene, vfs, sound_manager);

    ASSERT_NE(parsed, nullptr);
    auto source = FindRootChildByName(*parsed, "dependency source");
    ASSERT_NE(source, nullptr);
    EXPECT_FALSE(source->Visible());
    EXPECT_EQ(source->ID(), 159);
    ASSERT_NE(source->Mesh(), nullptr);
    auto consumer = FindRootChildByName(*parsed, "consumer");
    ASSERT_NE(consumer, nullptr);
    EXPECT_TRUE(consumer->Visible());
}

TEST(SceneSchema, ParserKeepsTransitiveInvisibleImageDependencySources) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    const std::string   scene = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":159,"name":"transitive source","image":"image.json",
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":false},
        {"id":200,"name":"hidden relay","image":"image.json","dependencies":[159],
         "origin":[4,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":false},
        {"id":201,"name":"visible consumer","image":"image.json","dependencies":[200],
         "origin":[8,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true}
      ]
    })";

    auto parsed = parser.Parse("transitive-invisible-dependency-source", scene, vfs, sound_manager);

    ASSERT_NE(parsed, nullptr);
    auto source = FindRootChildByName(*parsed, "transitive source");
    ASSERT_NE(source, nullptr);
    EXPECT_FALSE(source->Visible());
    EXPECT_EQ(source->ID(), 159);
    ASSERT_NE(source->Mesh(), nullptr);
    auto relay = FindRootChildByName(*parsed, "hidden relay");
    ASSERT_NE(relay, nullptr);
    EXPECT_FALSE(relay->Visible());
    auto consumer = FindRootChildByName(*parsed, "visible consumer");
    ASSERT_NE(consumer, nullptr);
    EXPECT_TRUE(consumer->Visible());
}

TEST(SceneSchema, ParserKeepsTransitiveInvisibleImageDependenciesFromDynamicVisibleImageRoots) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    const std::string   scene = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":180,"name":"dynamic transitive source","image":"image.json",
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":false},
        {"id":181,"name":"dynamic hidden relay","image":"image.json","dependencies":[180],
         "origin":[4,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":false},
        {"id":182,"name":"dynamic image consumer","image":"image.json","dependencies":[181],
         "origin":[8,0,0],"scale":[1,1,1],"angles":[0,0,0],
         "visible":{"value":false,"script":"export function update(value) { return value; }"}}
      ]
    })";

    auto parsed =
        parser.Parse("dynamic-visible-image-root-dependency-source", scene, vfs, sound_manager);

    ASSERT_NE(parsed, nullptr);
    auto source = FindRootChildByName(*parsed, "dynamic transitive source");
    ASSERT_NE(source, nullptr);
    EXPECT_FALSE(source->Visible());
    auto relay = FindRootChildByName(*parsed, "dynamic hidden relay");
    ASSERT_NE(relay, nullptr);
    EXPECT_FALSE(relay->Visible());
    auto consumer = FindRootChildByName(*parsed, "dynamic image consumer");
    ASSERT_NE(consumer, nullptr);
}

TEST(SceneSchema, ParserDoesNotRetainInvisibleNonImageDependencySources) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    const std::string   scene = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":170,"name":"hidden particle source","particle":"particle.json",
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":false},
        {"id":171,"name":"image consumer","image":"image.json","dependencies":[170],
         "origin":[8,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true}
      ]
    })";

    auto parsed = parser.Parse("invisible-non-image-dependency-source", scene, vfs, sound_manager);

    ASSERT_NE(parsed, nullptr);
    EXPECT_EQ(FindRootChildByName(*parsed, "hidden particle source"), nullptr);
    auto consumer = FindRootChildByName(*parsed, "image consumer");
    ASSERT_NE(consumer, nullptr);
    EXPECT_TRUE(consumer->Visible());
}

TEST(SceneSchema, SchemaOnlyObjectPreservesRenderableChildParentTransform) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    const std::string   scene = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":200,"name":"text parent","text":"hello","origin":[25,0,0],"visible":true},
        {"id":201,"parent":200,"name":"image child","image":"image.json",
         "origin":[5,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true}
      ]
    })";

    auto parsed = parser.Parse("schema-only-parent", scene, vfs, sound_manager);
    ASSERT_NE(parsed, nullptr);
    ASSERT_TRUE(parsed->sceneGraph != nullptr);
    const auto& root_children = parsed->sceneGraph->GetChildren();
    auto parent = std::find_if(root_children.begin(), root_children.end(), [](const auto& node) {
        return node != nullptr && node->Name() == "text parent";
    });
    ASSERT_NE(parent, root_children.end());
    ASSERT_EQ((*parent)->GetChildren().size(), 1u);
    const auto& child = (*parent)->GetChildren().front();
    ASSERT_NE(child, nullptr);
    EXPECT_EQ(child->Name(), "image child");
    EXPECT_EQ(child->Parent(), parent->get());

    child->UpdateTrans();
    EXPECT_NEAR(child->ModelTrans()(0, 3), 30.0, 1.0e-5);
}

TEST(SceneSchema, CameraUsesParentModelTransform) {
    auto parent = std::make_shared<SceneNode>();
    parent->SetTranslate({ 10.0f, 20.0f, 30.0f });
    parent->SetRotation({ 0.0f, 0.0f, static_cast<float>(EIGEN_PI / 2.0) });

    auto child = std::make_shared<SceneNode>();
    child->SetTranslate({ 2.0f, 3.0f, 4.0f });
    parent->AppendChild(child);

    SceneCamera camera(640, 360, 0.01f, 100.0f);
    camera.AttatchNode(child);
    camera.Update();

    const auto position = camera.GetPosition();
    EXPECT_NEAR(position.x(), 7.0, 1.0e-5);
    EXPECT_NEAR(position.y(), 22.0, 1.0e-5);
    EXPECT_NEAR(position.z(), 34.0, 1.0e-5);

    const auto direction = camera.GetDirection();
    EXPECT_NEAR(direction.x(), 0.0, 1.0e-5);
    EXPECT_NEAR(direction.y(), 0.0, 1.0e-5);
    EXPECT_NEAR(direction.z(), -1.0, 1.0e-5);

    child->UpdateTrans();
    const auto expected_view = child->ModelTrans().inverse().eval();
    const auto actual_view   = camera.GetViewMatrix();
    EXPECT_TRUE(actual_view.isApprox(expected_view, 1.0e-5));
}

TEST(SceneSchema, CameraViewGetterUpdatesAfterParentTransformChange) {
    auto parent = std::make_shared<SceneNode>();
    auto child  = std::make_shared<SceneNode>();
    parent->AppendChild(child);

    SceneCamera camera(640, 360, 0.01f, 100.0f);
    camera.AttatchNode(child);
    const auto initial_view = camera.GetViewMatrix();
    EXPECT_NEAR(initial_view(0, 3), 0.0, 1.0e-5);

    parent->SetTranslate({ 12.0f, 0.0f, 0.0f });
    const auto updated_view = camera.GetViewMatrix();
    EXPECT_NEAR(updated_view(0, 3), -12.0, 1.0e-5);
}

TEST(SceneSchema, CameraViewMatrixUsesScaledModelTransformInverse) {
    auto node = std::make_shared<SceneNode>();
    node->SetTranslate({ 4.0f, 6.0f, 8.0f });
    node->SetScale({ 2.0f, 3.0f, 4.0f });

    SceneCamera camera(640, 360, 0.01f, 100.0f);
    camera.AttatchNode(node);

    node->UpdateTrans();
    const auto expected_view = node->ModelTrans().inverse().eval();
    const auto actual_view   = camera.GetViewMatrix();
    EXPECT_TRUE(actual_view.isApprox(expected_view, 1.0e-5));
}

TEST(SceneSchema, ParserPreservesDeclarationOrderWhenContainersAttachLate) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    const std::string   scene = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":200,"name":"early container","origin":[10,0,0],"visible":true},
        {"id":201,"name":"middle sibling","image":"image.json",
         "origin":[20,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true},
        {"id":202,"parent":200,"name":"late child","image":"image.json",
         "origin":[5,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true}
      ]
    })";

    auto parsed = parser.Parse("declaration-order-containers", scene, vfs, sound_manager);
    ASSERT_NE(parsed, nullptr);
    ASSERT_NE(parsed->sceneGraph, nullptr);

    const auto& root_children = parsed->sceneGraph->GetChildren();
    std::vector<std::shared_ptr<SceneNode>> named_root_children;
    for (const auto& child : root_children) {
        if (child != nullptr && ! child->Name().empty()) {
            named_root_children.push_back(child);
        }
    }
    ASSERT_GE(named_root_children.size(), 2u);
    const auto& first = named_root_children[0];
    const auto& second = named_root_children[1];
    ASSERT_NE(first, nullptr);
    ASSERT_NE(second, nullptr);
    EXPECT_EQ(first->Name(), "early container");
    EXPECT_EQ(second->Name(), "middle sibling");

    ASSERT_EQ(first->GetChildren().size(), 1u);
    const auto& late_child = first->GetChildren().front();
    ASSERT_NE(late_child, nullptr);
    EXPECT_EQ(late_child->Name(), "late child");
    EXPECT_EQ(late_child->Parent(), first.get());
    late_child->UpdateTrans();
    EXPECT_NEAR(late_child->ModelTrans()(0, 3), 15.0, 1.0e-5);
}

TEST(SceneSchema, ParserKeepsForwardReferencedParentInDeclarationOrder) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    const std::string   scene = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":302,"parent":300,"name":"early child","image":"image.json",
         "origin":[5,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true},
        {"id":301,"name":"middle root","image":"image.json",
         "origin":[20,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true},
        {"id":300,"name":"late parent","origin":[10,0,0],"visible":true}
      ]
    })";

    auto parsed = parser.Parse("forward-parent-declaration-order", scene, vfs, sound_manager);
    ASSERT_NE(parsed, nullptr);
    ASSERT_NE(parsed->sceneGraph, nullptr);

    const auto& root_children = parsed->sceneGraph->GetChildren();
    std::vector<std::shared_ptr<SceneNode>> named_root_children;
    for (const auto& child : root_children) {
        if (child != nullptr && ! child->Name().empty()) {
            named_root_children.push_back(child);
        }
    }

    ASSERT_GE(named_root_children.size(), 2u);
    ASSERT_NE(named_root_children[0], nullptr);
    ASSERT_NE(named_root_children[1], nullptr);
    EXPECT_EQ(named_root_children[0]->Name(), "middle root");
    EXPECT_EQ(named_root_children[1]->Name(), "late parent");

    ASSERT_EQ(named_root_children[1]->GetChildren().size(), 1u);
    const auto& early_child = named_root_children[1]->GetChildren().front();
    ASSERT_NE(early_child, nullptr);
    EXPECT_EQ(early_child->Name(), "early child");
    EXPECT_EQ(early_child->Parent(), named_root_children[1].get());
    early_child->UpdateTrans();
    EXPECT_NEAR(early_child->ModelTrans()(0, 3), 15.0, 1.0e-5);
}

TEST(SceneSchema, ImageEffectFinalTransformIncludesDeferredParentAttachment) {
    fs::VFS vfs;
    auto files = std::map<std::string, std::string> {
        { "/image.json", R"({"width":64,"height":32,"material":"mat.json"})" },
        { "/mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["a.tex"]}]})" },
        { "/effects/copy/effect.json",
          R"({"name":"copy","passes":[{"material":"effect_mat.json","bind":[{"name":"previous","index":0}]}]})" },
        { "/effect_mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":[null]}]})" },
        { "/shaders/genericimage.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/genericimage.frag",
          R"(uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)" },
        { "/materials/a.tex.tex", "" },
    };
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    const std::string   scene = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":300,"name":"effect parent","origin":[40,0,0],"visible":true},
        {"id":301,"parent":300,"name":"nested effect","image":"image.json",
         "origin":[6,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true,
         "effects":[{"file":"effects/copy/effect.json","id":302,"visible":true}]}
      ]
    })";

    auto parsed = parser.Parse("nested-effect-final-transform", scene, vfs, sound_manager);
    ASSERT_NE(parsed, nullptr);
    auto parent = FindRootChildByName(*parsed, "effect parent");
    ASSERT_NE(parent, nullptr);
    auto* child = FindFirstChildByName(*parent, "nested effect");
    ASSERT_NE(child, nullptr);
    ASSERT_FALSE(child->Camera().empty());

    auto camera = parsed->cameras.find(child->Camera());
    ASSERT_NE(camera, parsed->cameras.end());
    ASSERT_NE(camera->second, nullptr);
    ASSERT_TRUE(camera->second->HasImgEffect());

    auto& final_node = camera->second->GetImgEffect()->FinalNode();
    final_node.UpdateTrans();
    EXPECT_NEAR(final_node.RenderTrans()(0, 3), 46.0, 1.0e-5);
}

// A node's draw offset is a translation in world space added to where the node is drawn
// and to nothing else: what hangs from the node, a camera on it and a hit test of its
// world matrix keep the matrix the node has, and a node drawn through an override draws
// where the override says.
TEST(SceneSchema, ANodesDrawOffsetMovesItsDrawAndNothingParentedToIt) {
    SceneNode parent(Eigen::Vector3f(10, 20, 0), Eigen::Vector3f(2, 3, 1), Eigen::Vector3f(0, 0, 0.5f),
                     "parent");
    auto child = std::make_shared<SceneNode>(Eigen::Vector3f(5, 7, 0), Eigen::Vector3f::Ones(),
                                              Eigen::Vector3f::Zero(), "child");
    parent.AppendChild(child);
    parent.UpdateTrans();
    child->UpdateTrans();
    const Eigen::Matrix4d model       = parent.ModelTrans();
    const Eigen::Matrix4d child_model = child->ModelTrans();
    EXPECT_TRUE(parent.RenderTrans().isApprox(model, 0.0));
    EXPECT_TRUE(parent.DrawOffset().isZero());

    parent.SetDrawOffset(Eigen::Vector3f(-70, 4, 0));
    parent.UpdateTrans();
    child->UpdateTrans();
    EXPECT_TRUE(parent.ModelTrans().isApprox(model, 0.0));
    EXPECT_TRUE(child->ModelTrans().isApprox(child_model, 0.0));
    // Drawn 70 left and 4 up in the scene, whatever the node's scale and turn: the offset
    // is not scaled or turned with the node.
    Eigen::Matrix4d moved = model;
    moved(0, 3) -= 70.0;
    moved(1, 3) += 4.0;
    EXPECT_TRUE(parent.RenderTrans().isApprox(moved, 1.0e-12));
    EXPECT_TRUE(Eigen::Matrix3d(parent.RenderTrans().block<3, 3>(0, 0))
                    .isApprox(Eigen::Matrix3d(model.block<3, 3>(0, 0)), 0.0));

    // A node drawn through an override draws where it says; the offset is not added to it.
    parent.SetRenderTransformOverride(Eigen::Matrix4d::Identity());
    EXPECT_TRUE(parent.RenderTrans().isApprox(Eigen::Matrix4d::Identity(), 0.0));
    parent.ClearRenderTransformOverride();
    EXPECT_TRUE(parent.RenderTrans().isApprox(moved, 1.0e-12));
    parent.SetDrawOffset(Eigen::Vector3f::Zero());
    EXPECT_TRUE(parent.RenderTrans().isApprox(model, 0.0));
}

namespace {

// A 64x32 image layer, a copy effect to draw one through, and the 640x360
// canvas the layer transform tests below place their layers on.
std::shared_ptr<Scene> ParseLayerPlacementScene(fs::VFS& vfs, audio::SoundManager& sound_manager,
                                                const std::string& objects) {
    auto files = std::map<std::string, std::string> {
        { "/image.json", R"({"width":64,"height":32,"material":"mat.json"})" },
        { "/mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["a.tex"]}]})" },
        { "/effects/copy/effect.json",
          R"({"name":"copy","passes":[{"material":"effect_mat.json","bind":[{"name":"previous","index":0}]}]})" },
        { "/effect_mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":[null]}]})" },
        { "/shaders/genericimage.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/genericimage.frag",
          R"(uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)" },
        { "/materials/a.tex.tex", "" },
    };
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    // Parsed with project properties, as the app always does, so the scene has
    // the runtime its scripts run on.
    ProjectProperties properties;
    return WPSceneParser().Parse(SceneParseRequest {
                                     .scene_id           = "layer-placement",
                                     .project_properties = &properties,
                                 },
                                 R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [)" + objects + "]}",
                                 vfs, sound_manager);
}

// A plain layer whose origin is whatever `body` returns when it runs, so the
// layer's origin reports what a script saw.
std::string ScriptedReaderLayer(int id, const std::string& name, const std::string& body) {
    return nlohmann::json {
        { "id", id }, { "name", name },
        { "origin", { { "value", "0 0 0" },
                      { "script", "export function update() { " + body + " }" } } }
    }.dump();
}

// `layer.getTransformMatrix()` x and y (m[12], m[13]) of a layer by name.
std::string StandsAt(const std::string& layer) {
    return "const m = thisScene.getLayer('" + layer + "').getTransformMatrix().m; "
           "return new Vec3(m[12], m[13], 0);";
}

} // namespace

// The matrix a script reads has to be the world transform of the layer the
// parser built: what its parents put it at, and not the identity a layer drawn
// through effects renders from (that one is in the node's render transform, not
// in the placement). A group at (100, 200) scaled by two puts a child at local
// (10, 20) at (120, 240), with or without an effect on it.
TEST(SceneSchema, LayerTransformMatrixOfParsedLayersIsWhereTheirParentsPutThem) {
    fs::VFS             vfs;
    audio::SoundManager sound_manager;
    const std::string   objects =
        R"({"id":1,"name":"group","origin":[100,200,0],"scale":[2,2,1],"visible":true},
            {"id":2,"parent":1,"name":"plain","image":"image.json",
             "origin":[10,20,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true},
            {"id":3,"parent":1,"name":"drawn","image":"image.json",
             "origin":[30,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true,
             "effects":[{"file":"effects/copy/effect.json","id":4,"visible":true}]},)" +
        ScriptedReaderLayer(10, "reads plain", StandsAt("plain")) + "," +
        ScriptedReaderLayer(11, "reads drawn", StandsAt("drawn")) + "," +
        ScriptedReaderLayer(12, "reads group", StandsAt("group"));
    auto scene = ParseLayerPlacementScene(vfs, sound_manager, objects);
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto& runtime = *scene->runtime;

    // The layer that is drawn through an effect really does render from an
    // identity of its own, or this would not tell the two matrices apart.
    auto group = FindRootChildByName(*scene, "group");
    ASSERT_NE(group, nullptr);
    auto* drawn = FindFirstChildByName(*group, "drawn");
    ASSERT_NE(drawn, nullptr);
    ASSERT_TRUE(drawn->HasRenderTransformOverride());

    runtime.Tick(0.01);
    EXPECT_TRUE(runtime.NodeTranslate("reads plain").isApprox(Eigen::Vector3f(120, 240, 0)))
        << runtime.NodeTranslate("reads plain").transpose();
    EXPECT_TRUE(runtime.NodeTranslate("reads drawn").isApprox(Eigen::Vector3f(160, 200, 0)))
        << runtime.NodeTranslate("reads drawn").transpose();
    EXPECT_TRUE(runtime.NodeTranslate("reads group").isApprox(Eigen::Vector3f(100, 200, 0)))
        << runtime.NodeTranslate("reads group").transpose();
    for (const auto& error : runtime.scriptErrors()) ADD_FAILURE() << error;
}

// A layer anchored to an edge is placed by its anchor (`origin`), while its
// matrix is the centre of the quad the anchor puts it at: half the drawn width
// to the right of a left anchor, the way Wallpaper Engine's layer matrix is the
// quad's centre. The matrix keeps up with a script that moves the anchor.
TEST(SceneSchema, LayerTransformMatrixOfAnAnchoredLayerIsTheCentreOfItsQuad) {
    fs::VFS             vfs;
    audio::SoundManager sound_manager;
    const std::string   objects =
        R"({"id":1,"name":"anchored","image":"image.json","alignment":"left",
            "origin":[100,70,0],"scale":[2,1,1],"angles":[0,0,0],"visible":true},
           {"id":2,"name":"moved","image":"image.json","alignment":"left",
            "origin":[100,70,0],"scale":[2,1,1],"angles":[0,0,0],"visible":true},)" +
        ScriptedReaderLayer(10, "reads matrix", StandsAt("anchored")) + "," +
        ScriptedReaderLayer(11, "reads origin",
                            "const o = thisScene.getLayer('anchored').origin; "
                            "return new Vec3(o.x, o.y, 0);") + "," +
        ScriptedReaderLayer(12, "moves anchor",
                            "thisScene.getLayer('moved').origin = new Vec3(300, 70, 0); " +
                                StandsAt("moved"));
    auto scene = ParseLayerPlacementScene(vfs, sound_manager, objects);
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto& runtime = *scene->runtime;

    // The left edge is at the anchor; the layer is drawn twice its width.
    const float half_width = runtime.NodeSize("anchored").x() * 2.0f / 2.0f;
    ASSERT_GT(half_width, 0.0f);

    runtime.Tick(0.01);
    EXPECT_TRUE(runtime.NodeTranslate("reads origin").isApprox(Eigen::Vector3f(100, 70, 0)))
        << runtime.NodeTranslate("reads origin").transpose();
    EXPECT_TRUE(runtime.NodeTranslate("reads matrix")
                    .isApprox(Eigen::Vector3f(100 + half_width, 70, 0)))
        << runtime.NodeTranslate("reads matrix").transpose();
    EXPECT_TRUE(runtime.NodeTranslate("moves anchor")
                    .isApprox(Eigen::Vector3f(300 + half_width, 70, 0)))
        << runtime.NodeTranslate("moves anchor").transpose();
    for (const auto& error : runtime.scriptErrors()) ADD_FAILURE() << error;
}

// An image with an effect that draws it through, both reading the layer colour
// from `g_Color4`: what a layer colour has to reach.
void MountTintableImageFiles(fs::VFS& vfs, bool hdr_bloom = false) {
    auto files = std::map<std::string, std::string> {
        { "/image.json", R"({"width":64,"height":32,"material":"mat.json"})" },
        { "/mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["a.tex"]}]})" },
        { "/effects/copy/effect.json",
          R"({"name":"copy","passes":[{"material":"effect_mat.json","bind":[{"name":"previous","index":0}]}]})" },
        { "/effect_mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":[null]}]})" },
        // Wallpaper Engine's Opacity effect: its `alpha` is the `g_UserAlpha` of its
        // own shader, the effect's, and not the layer's.
        { "/effects/opacity/effect.json",
          R"({"name":"opacity","passes":[{"material":"opacity_mat.json","bind":[{"name":"previous","index":0}]}]})" },
        { "/opacity_mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"opacity","textures":[null]}]})" },
        { "/shaders/opacity.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/opacity.frag",
          R"(uniform sampler2D g_Texture0;
uniform float g_UserAlpha; // {"material":"alpha","default":1.0}
varying vec2 v_TexCoord;
void main() {
  vec4 color = texture(g_Texture0, v_TexCoord);
  gl_FragColor = vec4(color.rgb, color.a * g_UserAlpha);
}
)" },
        { "/shaders/genericimage.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/genericimage.frag",
          R"(uniform sampler2D g_Texture0;
uniform vec4 g_Color4;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord) * g_Color4;
}
)" },
        { "/materials/a.tex.tex", "" },
    };
    if (hdr_bloom) AddHdrBloomFixtureFiles(files);
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
}

// The materials a layer draws with: its own and each effect pass's.
std::vector<SceneMaterial*> LayerMaterials(const Scene& scene, std::string_view name) {
    std::vector<SceneMaterial*> materials;
    auto node = FindRootChildByName(scene, name);
    if (node == nullptr || node->Mesh() == nullptr) return materials;
    materials.push_back(node->Mesh()->Material());
    if (const auto camera = scene.cameras.find(node->Camera());
        camera != scene.cameras.end() && camera->second->HasImgEffect()) {
        auto& layer = *camera->second->GetImgEffect();
        for (std::size_t index = 0; index < layer.EffectCount(); ++index) {
            for (auto& effect_node : layer.GetEffect(index)->nodes) {
                materials.push_back(effect_node.sceneNode->Mesh()->Material());
            }
        }
    }
    return materials;
}

// A layer colour bound to a user property is the property's value: a preset
// or a saved choice replaces the scene file's default. It has to reach the
// layer's own material and every effect pass, keep the layer's alpha, and
// follow the property when it changes. A scripted colour is the script's value
// from its first tick on (`ScriptedImageColour*` below), whatever the scene
// file's `value` says.
TEST(SceneSchema, UserBoundImageColourTintsEveryLayerMaterialAndFollowsTheProperty) {
    fs::VFS vfs;
    MountTintableImageFiles(vfs);
    audio::SoundManager sound_manager(audio::SoundManager::OutputBackend::Null);
    ProjectProperties   properties { { "tint", RuntimeScalarValue::String("0 0 1") } };
    const std::string   scene = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":1,"name":"plain","image":"image.json","alpha":0.5,
         "color":{"user":"tint","value":"0.9 0.15 0.27"},
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true},
        {"id":2,"name":"with effect","image":"image.json","alpha":0.5,
         "color":{"user":"tint","value":"0.9 0.15 0.27"},
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true,
         "effects":[{"file":"effects/copy/effect.json","id":3,"visible":true}]},
        {"id":4,"name":"scripted","image":"image.json","alpha":0.5,
         "color":{"script":"export function update(value) { return new Vec3(0, 1, 0); }",
                  "value":"0.9 0.15 0.27"},
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true}
      ]
    })";

    auto parsed = WPSceneParser().Parse(SceneParseRequest {
                                            .scene_id           = "user-bound-image-colour",
                                            .project_properties = &properties,
                                        },
                                        scene,
                                        vfs,
                                        sound_manager);
    ASSERT_NE(parsed, nullptr);
    ASSERT_NE(parsed->runtime, nullptr);

    const auto expect_colour = [&](std::string_view name, std::array<float, 3> rgb,
                                   std::size_t expected_materials) {
        SCOPED_TRACE(std::string(name));
        const auto materials = LayerMaterials(*parsed, name);
        ASSERT_EQ(materials.size(), expected_materials);
        for (const auto* material : materials) {
            const auto& values = material->customShader.constValues;
            ASSERT_TRUE(values.contains("g_Color4"));
            ASSERT_TRUE(values.contains("g_Color"));
            for (std::size_t index = 0; index < 3; ++index) {
                EXPECT_FLOAT_EQ(values.at("g_Color4")[index], rgb[index]);
                EXPECT_FLOAT_EQ(values.at("g_Color")[index], rgb[index]);
            }
            EXPECT_FLOAT_EQ(values.at("g_Color4")[3], 0.5f);
        }
    };

    expect_colour("plain", { 0.0f, 0.0f, 1.0f }, 1u);
    expect_colour("with effect", { 0.0f, 0.0f, 1.0f }, 2u);
    // Until its script has run, the scripted layer holds the scene file's value.
    expect_colour("scripted", { 0.9f, 0.15f, 0.27f }, 1u);

    parsed->runtime->ApplyProjectPropertyOverride(
        { { "tint", RuntimeScalarValue::String("0.25 0.5 0.75") } });
    parsed->runtime->Tick(1.0 / 60.0);
    expect_colour("plain", { 0.25f, 0.5f, 0.75f }, 1u);
    expect_colour("with effect", { 0.25f, 0.5f, 0.75f }, 2u);
    // The script's value, not the scene file's, once it has run.
    expect_colour("scripted", { 0.0f, 1.0f, 0.0f }, 1u);
    EXPECT_EQ(parsed->runtime->scriptErrorCount(), 0u);
}

// Wallpaper Engine runs a colour script on an image layer like one on a text
// layer: its `update()` is the layer's colour every frame, over the scene file's
// `value`, on the layer's own material and on every effect pass. The media
// widgets' colour script returns black until a cover's colour arrives. A script
// that returns nothing leaves the colour as it is, and one that writes
// `thisLayer.color` and returns nothing sets it.
TEST(SceneSchema, ScriptedImageColourIsTheScriptsValueOnEveryLayerMaterial) {
    fs::VFS vfs;
    auto files = std::map<std::string, std::string> {
        { "/image.json", R"({"width":64,"height":32,"material":"mat.json"})" },
        { "/mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["a.tex"]}]})" },
        { "/effects/copy/effect.json",
          R"({"name":"copy","passes":[{"material":"effect_mat.json","bind":[{"name":"previous","index":0}]}]})" },
        { "/effect_mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":[null]}]})" },
        { "/shaders/genericimage.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/genericimage.frag",
          R"(uniform sampler2D g_Texture0;
uniform vec4 g_Color4;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord) * g_Color4;
}
)" },
        { "/materials/a.tex.tex", "" },
    };
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager(audio::SoundManager::OutputBackend::Null);
    const std::string   scene = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":1,"name":"returns","image":"image.json","alpha":0.5,
         "color":{"script":"export function update() { return new Vec3(1, 0, 0); }",
                  "value":"0 1 0"},
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true,
         "effects":[{"file":"effects/copy/effect.json","id":2,"visible":true}]},
        {"id":3,"name":"returns nothing","image":"image.json","alpha":0.5,
         "color":{"script":"export function update(value) { }","value":"0.9 0.15 0.27"},
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true},
        {"id":4,"name":"writes","image":"image.json","alpha":0.5,
         "color":{"script":"export function update() { thisLayer.color = new Vec3(0, 0, 1); }",
                  "value":"1 0 0"},
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true,
         "effects":[{"file":"effects/copy/effect.json","id":5,"visible":true}]},
        {"id":6,"name":"cover","image":"image.json","alpha":0.5,
         "color":{"script":"let newColor = new Vec3(0, 0, 0);\nexport function update() { return newColor; }\nexport function mediaThumbnailChanged(event) { newColor = event.primaryColor; }",
                  "value":"0.33 0.64 0.74"},
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true},
        {"id":7,"name":"handler","image":"image.json","alpha":0.5,
         "color":{"script":"scene.on('mediaThumbnailChanged', function(event) { thisLayer.color = event.primaryColor; });",
                  "value":"0 1 0"},
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true,
         "effects":[{"file":"effects/copy/effect.json","id":8,"visible":true}]},
        {"id":9,"name":"reads its write","image":"image.json","alpha":0.5,
         "color":{"script":"let ticks = 0;\nexport function update(value) { ticks += 1; if (ticks == 1) { thisLayer.color = new Vec3(0, 0, 1); return; } return new Vec3(0.5, value.y, value.z); }",
                  "value":"1 0 0"},
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true}
      ]
    })";

    ProjectProperties properties;
    auto              parsed = WPSceneParser().Parse(SceneParseRequest {
                                                         .scene_id           = "scripted-image-colour",
                                                         .project_properties = &properties,
                                                     },
                                                     scene,
                                                     vfs,
                                                     sound_manager);
    ASSERT_NE(parsed, nullptr);
    ASSERT_NE(parsed->runtime, nullptr);

    const auto materials_of = [&parsed](std::string_view name) {
        std::vector<SceneMaterial*> materials;
        auto node = FindRootChildByName(*parsed, name);
        if (node == nullptr || node->Mesh() == nullptr) return materials;
        materials.push_back(node->Mesh()->Material());
        if (const auto camera = parsed->cameras.find(node->Camera());
            camera != parsed->cameras.end() && camera->second->HasImgEffect()) {
            auto& layer = *camera->second->GetImgEffect();
            for (std::size_t index = 0; index < layer.EffectCount(); ++index) {
                for (auto& effect_node : layer.GetEffect(index)->nodes) {
                    materials.push_back(effect_node.sceneNode->Mesh()->Material());
                }
            }
        }
        return materials;
    };
    const auto expect_colour = [&](std::string_view name, std::array<float, 3> rgb,
                                   std::size_t expected_materials) {
        SCOPED_TRACE(std::string(name));
        const auto materials = materials_of(name);
        ASSERT_EQ(materials.size(), expected_materials);
        for (const auto* material : materials) {
            const auto& values = material->customShader.constValues;
            ASSERT_TRUE(values.contains("g_Color4"));
            ASSERT_TRUE(values.contains("g_Color"));
            for (std::size_t index = 0; index < 3; ++index) {
                EXPECT_FLOAT_EQ(values.at("g_Color4")[index], rgb[index]);
                EXPECT_FLOAT_EQ(values.at("g_Color")[index], rgb[index]);
            }
            EXPECT_FLOAT_EQ(values.at("g_Color4")[3], 0.5f);
        }
    };

    // As the scene loads, before any script has run: the scene file's values.
    expect_colour("returns", { 0.0f, 1.0f, 0.0f }, 2u);
    expect_colour("returns nothing", { 0.9f, 0.15f, 0.27f }, 1u);
    expect_colour("writes", { 1.0f, 0.0f, 0.0f }, 2u);
    expect_colour("cover", { 0.33f, 0.64f, 0.74f }, 1u);
    expect_colour("handler", { 0.0f, 1.0f, 0.0f }, 2u);
    expect_colour("reads its write", { 1.0f, 0.0f, 0.0f }, 1u);

    // Scripts that decide a colour are scripts: the scene keeps its clock, which
    // is the cost of following them (an image colour script made none before).
    EXPECT_NE(parsed->runtime->DescribeTimeAdvancingWork() & SceneDemandReason::Script, 0u);

    // What the script wrote on the first tick is the value its second call is given
    // (it would be the scene file's (1, 0, 0), and the result (0.5, 0, 0), if not).
    parsed->runtime->Tick(1.0 / 60.0);
    expect_colour("reads its write", { 0.0f, 0.0f, 1.0f }, 1u);
    parsed->runtime->Tick(1.0 / 60.0);
    expect_colour("reads its write", { 0.5f, 0.0f, 1.0f }, 1u);

    // Every tick, not just the first: a colour that wore off would show here.
    for (int tick = 0; tick < 3; ++tick) {
        parsed->runtime->Tick(1.0 / 60.0);
        SCOPED_TRACE(tick);
        expect_colour("returns", { 1.0f, 0.0f, 0.0f }, 2u);
        // `update()` returned nothing, so the colour stays what it was.
        expect_colour("returns nothing", { 0.9f, 0.15f, 0.27f }, 1u);
        // It wrote the colour itself; the tick must not put the scene file's back.
        expect_colour("writes", { 0.0f, 0.0f, 1.0f }, 2u);
        // The media widgets' template: black until a cover's colour arrives.
        expect_colour("cover", { 0.0f, 0.0f, 0.0f }, 1u);
        // Written only by a handler, which has not been called yet.
        expect_colour("handler", { 0.0f, 1.0f, 0.0f }, 2u);
    }

    parsed->runtime->SetMediaIntegrationEnabled(true);
    parsed->runtime->DispatchMediaEventJson(
        R"({"type":"mediaThumbnailChanged","hasThumbnail":true,"primaryColor":[0.25,0.5,0.75],"secondaryColor":[0,0,0],"tertiaryColor":[0,0,0],"textColor":[1,1,1],"highContrastColor":[0,0,0]})");
    parsed->runtime->Tick(1.0 / 60.0);
    expect_colour("cover", { 0.25f, 0.5f, 0.75f }, 1u);
    // A colour script made of event handlers writes the colour from its handler,
    // and the write reaches the effect pass too.
    expect_colour("handler", { 0.25f, 0.5f, 0.75f }, 2u);
    parsed->runtime->Tick(1.0 / 60.0);
    expect_colour("cover", { 0.25f, 0.5f, 0.75f }, 1u);
    expect_colour("handler", { 0.25f, 0.5f, 0.75f }, 2u);
    EXPECT_EQ(parsed->runtime->scriptErrorCount(), 0u);
}

// A script writes a layer's opacity as `thisLayer.alpha`. The write has to reach
// every material that takes the layer's alpha -- its own and the `g_Color4` of
// each effect pass, as an authored alpha, a user property and a timeline do --
// and not the one built last, and an alpha a property or a script owns is left
// to its owner.
TEST(SceneSchema, AScriptsAlphaWriteReachesEveryMaterialOfTheLayer) {
    fs::VFS vfs;
    MountTintableImageFiles(vfs);
    audio::SoundManager sound_manager(audio::SoundManager::OutputBackend::Null);
    const std::string   scene = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":1,"name":"plain","image":"image.json","alpha":0.5,
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true},
        {"id":2,"name":"with effect","image":"image.json","alpha":0.5,
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true,
         "effects":[{"file":"effects/copy/effect.json","id":3,"visible":true}]},
        {"id":4,"name":"two effects","image":"image.json","alpha":0.5,
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true,
         "effects":[{"file":"effects/copy/effect.json","id":5,"visible":true},
                    {"file":"effects/copy/effect.json","id":6,"visible":{"value":false,
                     "script":"export function update() { return false; }"}}]},
        {"id":7,"name":"written by itself","image":"image.json","alpha":0.5,
         "visible":{"value":true,"script":"export function update(value) { thisLayer.alpha = 0.25; return value; }"},
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],
         "effects":[{"file":"effects/copy/effect.json","id":8,"visible":true}]},
        {"id":9,"name":"owned by a script","image":"image.json",
         "alpha":{"value":0.5,"script":"export function update(value) { return value; }"},
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true,
         "effects":[{"file":"effects/copy/effect.json","id":10,"visible":true}]}
      ]
    })";

    ProjectProperties properties;
    auto              parsed = WPSceneParser().Parse(SceneParseRequest {
                                                         .scene_id           = "script-alpha-write",
                                                         .project_properties = &properties,
                                                     },
                                                     scene,
                                                     vfs,
                                                     sound_manager);
    ASSERT_NE(parsed, nullptr);
    ASSERT_NE(parsed->runtime, nullptr);

    const auto expect_alpha = [&](std::string_view name, float alpha, std::size_t expected_materials) {
        SCOPED_TRACE(std::string(name));
        const auto materials = LayerMaterials(*parsed, name);
        ASSERT_EQ(materials.size(), expected_materials);
        for (const auto* material : materials) {
            const auto& values = material->customShader.constValues;
            ASSERT_TRUE(values.contains("g_Color4"));
            EXPECT_FLOAT_EQ(values.at("g_Color4")[3], alpha);
        }
    };

    expect_alpha("plain", 0.5f, 1u);
    expect_alpha("with effect", 0.5f, 2u);
    // Only the effects that are built have a pass; a script-switched one is built.
    expect_alpha("two effects", 0.5f, 3u);

    for (const auto& [name, count] : { std::pair<const char*, std::size_t> { "plain", 1u },
                                       { "with effect", 2u },
                                       { "two effects", 3u } }) {
        SCOPED_TRACE(name);
        ASSERT_TRUE(parsed->runtime->SetNodeAlpha(name, 0.25f));
        expect_alpha(name, 0.25f, count);
        EXPECT_FLOAT_EQ(*parsed->runtime->NodeAlpha(name), 0.25f);
        ASSERT_TRUE(parsed->runtime->SetNodeAlpha(name, 0.0f));
        expect_alpha(name, 0.0f, count);
        EXPECT_FLOAT_EQ(*parsed->runtime->NodeAlpha(name), 0.0f);
    }

    // The layer's own script writes it, and the effect pass follows.
    expect_alpha("written by itself", 0.5f, 2u);
    parsed->runtime->Tick(1.0 / 60.0);
    expect_alpha("written by itself", 0.25f, 2u);
    EXPECT_FLOAT_EQ(*parsed->runtime->NodeAlpha("written by itself"), 0.25f);

    // An alpha a script owns is that script's: no second writer.
    EXPECT_FALSE(parsed->runtime->SetNodeAlpha("owned by a script", 0.1f));
    expect_alpha("owned by a script", 0.5f, 2u);
    EXPECT_EQ(parsed->runtime->scriptErrorCount(), 0u);
}

// An effect with an alpha of its own, Wallpaper Engine's Opacity, keeps it. Its
// `g_UserAlpha` is the effect's `alpha`, set in the effect, while the layer's is
// the layer's own pass's; a layer's alpha, whether a script writes it, a user
// property is bound to it or its own script owns it, is applied once, by the
// layer, and the effect's multiplies it. The `g_Color4` and `g_Alpha` the layer
// hands every pass follow, as an authored alpha leaves them.
TEST(SceneSchema, AnEffectsOwnAlphaIsLeftAloneWhenTheLayersAlphaIsDriven) {
    fs::VFS vfs;
    MountTintableImageFiles(vfs);
    audio::SoundManager sound_manager(audio::SoundManager::OutputBackend::Null);
    const std::string   opacity = [](int id) {
        return R"("effects":[{"file":"effects/opacity/effect.json","id":)" + std::to_string(id) +
               R"(,"visible":true,"passes":[{"id":)" + std::to_string(id + 1) +
               R"(,"constantshadervalues":{"alpha":0.8}}]}])";
    }(10);
    const std::string   second_opacity = [](int id) {
        return R"({"file":"effects/opacity/effect.json","id":)" + std::to_string(id) +
               R"(,"visible":true,"passes":[{"id":)" + std::to_string(id + 1) +
               R"(,"constantshadervalues":{"alpha":0.8}}]})";
    }(20);
    const std::string   scene = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":1,"name":"authored","image":"image.json","alpha":0.5,
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true,)" + opacity + R"(},
        {"id":2,"name":"written","image":"image.json","alpha":0.5,
         "visible":{"value":true,"script":"export function update(value) { thisLayer.alpha = 0.25; return value; }"},
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],)" + opacity + R"(},
        {"id":3,"name":"bound","image":"image.json","alpha":{"user":"fade","value":1},
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true,)" + opacity + R"(},
        {"id":4,"name":"owned by a script","image":"image.json",
         "alpha":{"value":0.5,"script":"export function update(value) { return 0.3; }"},
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true,)" + opacity + R"(},
        {"id":5,"name":"two effects","image":"image.json","alpha":0.5,
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true,
         "effects":[{"file":"effects/opacity/effect.json","id":30,"visible":true,
                     "passes":[{"id":31,"constantshadervalues":{"alpha":0.8}}]},)" + second_opacity + R"(]}
      ]
    })";

    ProjectProperties properties { { "fade", RuntimeScalarValue::Float(0.4f) } };
    auto              parsed = WPSceneParser().Parse(SceneParseRequest {
                                                         .scene_id           = "effect-own-alpha",
                                                         .project_properties = &properties,
                                                     },
                                                     scene,
                                                     vfs,
                                                     sound_manager);
    ASSERT_NE(parsed, nullptr);
    ASSERT_NE(parsed->runtime, nullptr);

    // The layer's alpha is what its own pass, the first material, applies; every
    // later one is an effect pass, which keeps the alpha it was authored with.
    const auto expect_alpha = [&](std::string_view name, float alpha, std::size_t effect_passes) {
        SCOPED_TRACE(std::string(name));
        const auto materials = LayerMaterials(*parsed, name);
        ASSERT_EQ(materials.size(), effect_passes + 1u);
        for (std::size_t index = 0; index < materials.size(); ++index) {
            SCOPED_TRACE(index);
            const auto& values = materials[index]->customShader.constValues;
            ASSERT_TRUE(values.contains("g_UserAlpha"));
            ASSERT_TRUE(values.contains("g_Color4"));
            ASSERT_TRUE(values.contains("g_Alpha"));
            EXPECT_FLOAT_EQ(values.at("g_UserAlpha")[0], index == 0 ? alpha : 0.8f);
            EXPECT_FLOAT_EQ(values.at("g_Color4")[3], alpha);
            EXPECT_FLOAT_EQ(values.at("g_Alpha")[0], alpha);
        }
    };

    expect_alpha("authored", 0.5f, 1u);
    EXPECT_TRUE(parsed->runtime->SetNodeAlpha("authored", 0.1f));
    expect_alpha("authored", 0.1f, 1u);

    parsed->runtime->Tick(1.0 / 60.0);
    expect_alpha("written", 0.25f, 1u);
    expect_alpha("bound", 0.4f, 1u);
    expect_alpha("owned by a script", 0.3f, 1u);

    parsed->runtime->ApplyProjectPropertyOverride({ { "fade", RuntimeScalarValue::Float(0.7f) } });
    parsed->runtime->Tick(1.0 / 60.0);
    expect_alpha("bound", 0.7f, 1u);

    expect_alpha("two effects", 0.5f, 2u);
    EXPECT_TRUE(parsed->runtime->SetNodeAlpha("two effects", 0.2f));
    expect_alpha("two effects", 0.2f, 2u);
    EXPECT_EQ(parsed->runtime->scriptErrorCount(), 0u);
}

// Every pass of a layer is seeded with the layer's authored alpha, and only an
// `alpha` the effect sets itself replaces it, so an effect that sets none (an
// Opacity effect left at its defaults) starts from the layer's authored alpha. That
// start is the effect's own like an alpha it authored: a write, a property or a
// script that drives the layer's alpha afterwards leaves it where it was, and moves
// the `g_Color4` and `g_Alpha` of the effect's pass with the layer's.
TEST(SceneSchema, AnEffectThatSetsNoAlphaStartsFromTheLayersAuthoredAlphaAndKeepsIt) {
    fs::VFS vfs;
    MountTintableImageFiles(vfs);
    audio::SoundManager sound_manager(audio::SoundManager::OutputBackend::Null);
    const std::string   scene = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":1,"name":"authored","image":"image.json","alpha":0.5,
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true,
         "effects":[{"file":"effects/opacity/effect.json","id":10,"visible":true}]},
        {"id":2,"name":"written","image":"image.json","alpha":0.5,
         "visible":{"value":true,"script":"export function update(value) { thisLayer.alpha = 0.25; return value; }"},
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],
         "effects":[{"file":"effects/opacity/effect.json","id":20,"visible":true}]}
      ]
    })";

    ProjectProperties properties;
    auto              parsed = WPSceneParser().Parse(SceneParseRequest {
                                                         .scene_id           = "effect-no-alpha",
                                                         .project_properties = &properties,
                                                     },
                                                     scene,
                                                     vfs,
                                                     sound_manager);
    ASSERT_NE(parsed, nullptr);
    ASSERT_NE(parsed->runtime, nullptr);

    const auto expect_alpha = [&](std::string_view name, float layer_alpha, float effect_alpha) {
        SCOPED_TRACE(std::string(name));
        const auto materials = LayerMaterials(*parsed, name);
        ASSERT_EQ(materials.size(), 2u);
        for (std::size_t index = 0; index < materials.size(); ++index) {
            SCOPED_TRACE(index);
            const auto& values = materials[index]->customShader.constValues;
            ASSERT_TRUE(values.contains("g_UserAlpha"));
            EXPECT_FLOAT_EQ(values.at("g_UserAlpha")[0], index == 0 ? layer_alpha : effect_alpha);
            EXPECT_FLOAT_EQ(values.at("g_Color4")[3], layer_alpha);
        }
    };

    expect_alpha("authored", 0.5f, 0.5f);
    EXPECT_TRUE(parsed->runtime->SetNodeAlpha("authored", 0.1f));
    expect_alpha("authored", 0.1f, 0.5f);

    expect_alpha("written", 0.5f, 0.5f);
    parsed->runtime->Tick(1.0 / 60.0);
    expect_alpha("written", 0.25f, 0.5f);
    EXPECT_EQ(parsed->runtime->scriptErrorCount(), 0u);
}

// A puppet that has effects is drawn by its effect chain and then by a skinned
// pass of the layer's own material, appended to the chain: that pass is the layer
// on screen, so its `g_UserAlpha` is the layer's, while the effect before it keeps
// its own. The layer's own material, the sheet the chain starts from, carries it
// too, so this layer's alpha is applied by two passes whoever sets it (a known
// limitation, docs/testing/renderer.md): a script's write puts every material where
// an authored alpha of the same value puts it, and that is what is pinned here.
TEST(SceneSchema, APuppetsSkinnedPassUnderEffectsTakesTheLayersAlpha) {
    std::map<std::string, std::string> files;
    AddPuppetImageSceneFiles(files);
    files["/effects/opacity/effect.json"] =
        R"({"name":"opacity","passes":[{"material":"opacity_mat.json","bind":[{"name":"previous","index":0}]}]})";
    files["/opacity_mat.json"] =
        R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"opacity","textures":[null]}]})";
    files["/shaders/opacity.vert"] = files["/shaders/baseimage.vert"];
    files["/shaders/opacity.frag"] = R"(
uniform sampler2D g_Texture0;
uniform float g_UserAlpha; // {"material":"alpha","default":1.0}
varying vec2 v_TexCoord;
void main() {
  vec4 color = texture(g_Texture0, v_TexCoord);
  gl_FragColor = vec4(color.rgb, color.a * g_UserAlpha);
}
)";
    fs::VFS vfs;
    ASSERT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager;
    auto                json = nlohmann::json::parse(BasicPuppetSceneJson());
    json["objects"][0]["effects"] = nlohmann::json::parse(
        R"([{"file":"effects/opacity/effect.json","id":10,"visible":true,)"
        R"("passes":[{"id":11,"constantshadervalues":{"alpha":0.8}}]}])");
    ProjectProperties properties;
    auto              parsed = WPSceneParser().Parse(SceneParseRequest {
                                                         .scene_id           = "puppet-effects-alpha",
                                                         .project_properties = &properties,
                                                     },
                                                     json.dump(),
                                                     vfs,
                                                     sound_manager);
    ASSERT_NE(parsed, nullptr);
    ASSERT_NE(parsed->runtime, nullptr);

    // Its own material, the effect's pass, then the skinned pass.
    ASSERT_EQ(LayerMaterials(*parsed, "puppet image").size(), 3u);
    ASSERT_TRUE(parsed->runtime->SetNodeAlpha("puppet image", 0.25f));
    const auto materials = LayerMaterials(*parsed, "puppet image");
    ASSERT_EQ(materials.size(), 3u);
    for (std::size_t index = 0; index < materials.size(); ++index) {
        SCOPED_TRACE(index);
        const auto& values = materials[index]->customShader.constValues;
        ASSERT_TRUE(values.contains("g_UserAlpha"));
        EXPECT_FLOAT_EQ(values.at("g_UserAlpha")[0], index == 1 ? 0.8f : 0.25f);
        EXPECT_FLOAT_EQ(values.at("g_Color4")[3], 0.25f);
        EXPECT_EQ(materials[index]->own_user_alpha, index == 1);
    }

    // The same layer authored at 0.25: its materials hold what the write left.
    json["objects"][0]["alpha"] = 0.25;
    auto authored = WPSceneParser().Parse(SceneParseRequest {
                                              .scene_id           = "puppet-effects-alpha-authored",
                                              .project_properties = &properties,
                                          },
                                          json.dump(),
                                          vfs,
                                          sound_manager);
    ASSERT_NE(authored, nullptr);
    const auto authored_materials = LayerMaterials(*authored, "puppet image");
    ASSERT_EQ(authored_materials.size(), materials.size());
    for (std::size_t index = 0; index < materials.size(); ++index) {
        SCOPED_TRACE(index);
        const auto& written_values  = materials[index]->customShader.constValues;
        const auto& authored_values = authored_materials[index]->customShader.constValues;
        for (const char* name : { "g_UserAlpha", "g_Alpha", "g_Color4" }) {
            SCOPED_TRACE(name);
            ASSERT_EQ(written_values.contains(name), authored_values.contains(name));
            if (! written_values.contains(name)) continue;
            const auto& written_value  = written_values.at(name);
            const auto& authored_value = authored_values.at(name);
            if (std::string_view(name) == "g_Color4") {
                EXPECT_FLOAT_EQ(written_value[3], authored_value[3]);
            } else {
                // The effect's own alpha is its authored 0.8 in both.
                EXPECT_FLOAT_EQ(written_value[0], authored_value[0]);
            }
        }
        EXPECT_EQ(materials[index]->own_user_alpha, authored_materials[index]->own_user_alpha);
    }
}

// Wallpaper Engine multiplies a layer's colour by its brightness into the
// `g_Color4` of the layer's draw where it renders HDR -- the scene asks for HDR
// and has bloom on -- and draws every other scene as if the brightness were 1.
// The layer's own material and each effect pass take the product like they take
// the colour, a colour a script returns or writes included, and the brightness is
// not also handed to the shader as `g_Brightness`, which a shader that declares it
// takes from its own material.
// A brightness a user property or a script drives follows it, beside a colour
// that does the same.
TEST(SceneSchema, AnImageLayersBrightnessTintsItsMaterialsOnlyInAnHdrSceneAndFollowsItsBindings) {
    struct Layer {
        const char*          name;
        std::size_t          materials;
        std::array<float, 3> before;  // g_Color4.rgb as loaded, HDR scene
        std::array<float, 3> after;   // after the property document below, HDR scene
    };
    // glow loads at 0.75 and is then set to 0.25; tint loads at "0 0 1" and
    // is then set to "0.5 1 1".
    const std::array<Layer, 8> layers { {
        { "plain", 1u, { 0.25f, 0.5f, 0.5f }, { 0.25f, 0.5f, 0.5f } },
        { "with effect", 2u, { 0.25f, 0.5f, 0.5f }, { 0.25f, 0.5f, 0.5f } },
        { "bound", 1u, { 0.75f, 0.75f, 0.75f }, { 0.25f, 0.25f, 0.25f } },
        { "bound with effect", 2u, { 0.75f, 0.75f, 0.75f }, { 0.25f, 0.25f, 0.25f } },
        { "bound with colour", 1u, { 0.0f, 0.0f, 0.75f }, { 0.125f, 0.25f, 0.25f } },
        { "scripted", 1u, { 0.5f, 0.5f, 0.5f }, { 0.5f, 0.5f, 0.5f } },
        // A colour script's return value and its `thisLayer.color` write both
        // reach the layer's materials through the product, not around it.
        { "scripted colour", 2u, { 0.0f, 0.5f, 0.0f }, { 0.0f, 0.5f, 0.0f } },
        { "scripted colour write", 1u, { 0.0f, 0.0f, 0.5f }, { 0.0f, 0.0f, 0.5f } },
    } };
    const std::array<const char*, 2> shaders { "genericimage", "genericimage2" };

    for (const auto& [hdr, bloom] : std::array<std::pair<bool, bool>, 3> {
             std::pair { true, true }, { true, false }, { false, false } }) {
        // A scene renders HDR only with bloom on as well.
        const bool renders_hdr = hdr && bloom;
        for (const char* shader : shaders) {
            SCOPED_TRACE(std::string(hdr ? "hdr" : "sdr") + (bloom ? " bloom " : " no bloom ") + shader);
            fs::VFS vfs;
            auto files = std::map<std::string, std::string> {
                { "/image.json", R"({"width":64,"height":32,"material":"mat.json"})" },
                { "/mat.json",
                  std::string(R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":")") +
                      shader + R"(","textures":["a.tex"]}]})" },
                { "/effects/copy/effect.json",
                  R"({"name":"copy","passes":[{"material":"effect_mat.json","bind":[{"name":"previous","index":0}]}]})" },
                { "/effect_mat.json",
                  R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":[null]}]})" },
                { "/shaders/genericimage.vert",
                  R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
                { "/shaders/genericimage.frag",
                  R"(uniform sampler2D g_Texture0;
uniform vec4 g_Color4;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord) * g_Color4;
}
)" },
                { "/shaders/genericimage2.vert",
                  R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
                { "/shaders/genericimage2.frag",
                  R"(uniform sampler2D g_Texture0;
uniform vec4 g_Color4;
uniform float g_Brightness; // {"material":"Brightness","default":1,"range":[0,2]}
varying vec2 v_TexCoord;
void main() {
  vec4 color = texture(g_Texture0, v_TexCoord);
  color.rgb *= g_Brightness;
  gl_FragColor = color * g_Color4;
}
)" },
                { "/materials/a.tex.tex", "" },
            };
            if (renders_hdr) AddHdrBloomFixtureFiles(files);
            EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
            audio::SoundManager sound_manager(audio::SoundManager::OutputBackend::Null);
            ProjectProperties   properties { { "glow", RuntimeScalarValue::Float(0.75f) },
                                             { "tint", RuntimeScalarValue::String("0 0 1") } };
            const std::string   scene = std::string(R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0, "hdr":)") + (hdr ? "true" : "false") +
                                        R"(, "bloom":)" + (bloom ? "true" : "false") + R"(,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":1,"name":"plain","image":"image.json","color":"0.5 1 1","brightness":0.5,
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true},
        {"id":2,"name":"with effect","image":"image.json","color":"0.5 1 1","brightness":0.5,
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true,
         "effects":[{"file":"effects/copy/effect.json","id":3,"visible":true}]},
        {"id":4,"name":"bound","image":"image.json",
         "brightness":{"user":"glow","value":0.5},
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true},
        {"id":5,"name":"bound with effect","image":"image.json",
         "brightness":{"user":"glow","value":0.5},
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true,
         "effects":[{"file":"effects/copy/effect.json","id":6,"visible":true}]},
        {"id":7,"name":"bound with colour","image":"image.json",
         "color":{"user":"tint","value":"1 1 1"},
         "brightness":{"user":"glow","value":0.5},
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true},
        {"id":8,"name":"scripted","image":"image.json",
         "brightness":{"script":"export function update(value) { return 0.5; }","value":1},
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true},
        {"id":9,"name":"scripted colour","image":"image.json","brightness":0.5,
         "color":{"script":"export function update() { return new Vec3(0, 1, 0); }","value":"1 0 0"},
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true,
         "effects":[{"file":"effects/copy/effect.json","id":10,"visible":true}]},
        {"id":11,"name":"scripted colour write","image":"image.json","brightness":0.5,
         "color":{"script":"export function update() { thisLayer.color = new Vec3(0, 0, 1); }","value":"1 0 0"},
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true}
      ]
    })";

            auto parsed = WPSceneParser().Parse(SceneParseRequest {
                                                    .scene_id           = "image-brightness",
                                                    .project_properties = &properties,
                                                },
                                                scene,
                                                vfs,
                                                sound_manager);
            ASSERT_NE(parsed, nullptr);
            ASSERT_NE(parsed->runtime, nullptr);
            EXPECT_EQ(parsed->hdr, renders_hdr);

            const auto materials_of = [&parsed](std::string_view name) {
                std::vector<SceneMaterial*> materials;
                auto node = FindRootChildByName(*parsed, name);
                if (node == nullptr || node->Mesh() == nullptr) return materials;
                materials.push_back(node->Mesh()->Material());
                if (const auto camera = parsed->cameras.find(node->Camera());
                    camera != parsed->cameras.end() && camera->second->HasImgEffect()) {
                    auto& layer = *camera->second->GetImgEffect();
                    for (std::size_t index = 0; index < layer.EffectCount(); ++index) {
                        for (auto& effect_node : layer.GetEffect(index)->nodes) {
                            materials.push_back(effect_node.sceneNode->Mesh()->Material());
                        }
                    }
                }
                return materials;
            };
            // The colour a layer has without its brightness, as loaded and as set.
            const auto plain_colour = [](const Layer& layer, bool after) {
                const std::string name = layer.name;
                if (name == "plain" || name == "with effect") return std::array { 0.5f, 1.0f, 1.0f };
                if (name == "bound with colour") {
                    return after ? std::array { 0.5f, 1.0f, 1.0f } : std::array { 0.0f, 0.0f, 1.0f };
                }
                if (name == "scripted colour") return std::array { 0.0f, 1.0f, 0.0f };
                if (name == "scripted colour write") return std::array { 0.0f, 0.0f, 1.0f };
                return std::array { 1.0f, 1.0f, 1.0f };
            };
            const auto expect_tint = [&](const Layer& layer, bool after) {
                SCOPED_TRACE(std::string(layer.name) + (after ? " after" : " before"));
                const auto materials = materials_of(layer.name);
                ASSERT_EQ(materials.size(), layer.materials);
                const auto expected = renders_hdr ? (after ? layer.after : layer.before)
                                                  : plain_colour(layer, after);
                for (std::size_t slot = 0; slot < materials.size(); ++slot) {
                    SCOPED_TRACE(slot);
                    const auto& values = materials[slot]->customShader.constValues;
                    ASSERT_TRUE(values.contains("g_Color4"));
                    for (std::size_t index = 0; index < 3; ++index) {
                        EXPECT_FLOAT_EQ(values.at("g_Color4")[index], expected[index]);
                    }
                    EXPECT_FLOAT_EQ(values.at("g_Color4")[3], 1.0f);
                    // The older shaders keep the brightness of their own material.
                    if (slot == 0 && values.contains("g_Brightness")) {
                        EXPECT_FLOAT_EQ(values.at("g_Brightness")[0], 1.0f);
                    }
                }
            };

            // A script has run once before anything is drawn.
            parsed->runtime->Tick(1.0 / 60.0);
            for (const auto& layer : layers) expect_tint(layer, false);

            parsed->runtime->ApplyProjectPropertyOverride(
                { { "glow", RuntimeScalarValue::Float(0.25f) },
                  { "tint", RuntimeScalarValue::String("0.5 1 1") } });
            parsed->runtime->Tick(1.0 / 60.0);
            for (const auto& layer : layers) expect_tint(layer, true);
            EXPECT_EQ(parsed->runtime->scriptErrorCount(), 0u);
        }
    }
}

// Wallpaper Engine reads a comma before a closing `]` or `}`, and its own
// fluid simulation effect is written that way. An effect file or material
// with one has to load like any other instead of dropping the effect.
TEST(SceneSchema, EffectFilesWithTrailingCommasLoadTheirPasses) {
    fs::VFS vfs;
    auto files = std::map<std::string, std::string> {
        { "/image.json", R"({"width":64,"height":32,"material":"mat.json"})" },
        { "/mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["a.tex"]}]})" },
        { "/effects/copy/effect.json",
          R"({"name":"copy ,] and ,} stay",
              "passes":[{"material":"effect_mat.json","bind":[{"name":"previous","index":0},],},
              ],
            })" },
        { "/effect_mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":[null,],},]})" },
        { "/shaders/genericimage.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/genericimage.frag",
          R"(uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)" },
        { "/materials/a.tex.tex", "" },
    };
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager(audio::SoundManager::OutputBackend::Null);
    const std::string   scene = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":2,"name":"with effect","image":"image.json",
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true,
         "effects":[{"file":"effects/copy/effect.json","id":3,"visible":true}]}
      ]
    })";

    auto parsed = WPSceneParser().Parse(SceneParseRequest { .scene_id = "trailing-commas" },
                                        scene, vfs, sound_manager);
    ASSERT_NE(parsed, nullptr);
    auto node = FindRootChildByName(*parsed, "with effect");
    ASSERT_NE(node, nullptr);
    const auto camera = parsed->cameras.find(node->Camera());
    ASSERT_NE(camera, parsed->cameras.end());
    ASSERT_TRUE(camera->second->HasImgEffect()) << "the effect was dropped";
    auto& layer = *camera->second->GetImgEffect();
    ASSERT_EQ(layer.EffectCount(), 1u);
    EXPECT_EQ(layer.GetEffect(0)->nodes.size(), 1u);
}

// A script that decides an effect's visibility has that effect as `thisObject`
// (Wallpaper Engine's `IEffect`): writing `thisObject.visible` switches the
// effect. It was the layer, so a cover effect that shows itself once a track
// has a thumbnail showed its whole layer instead, over a property that hid it.
TEST(SceneSchema, AnEffectsVisibilityScriptSwitchesTheEffectAndNotItsLayer) {
    fs::VFS vfs;
    auto files = std::map<std::string, std::string> {
        { "/image.json", R"({"width":64,"height":32,"material":"mat.json"})" },
        { "/mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["a.tex"]}]})" },
        { "/effects/copy/effect.json",
          R"({"name":"copy","passes":[{"material":"effect_mat.json"}]})" },
        { "/effect_mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":[null]}]})" },
        { "/shaders/genericimage.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/genericimage.frag",
          R"(uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)" },
        { "/materials/a.tex.tex", "" },
    };
    ASSERT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager(audio::SoundManager::OutputBackend::Null);
    const nlohmann::json script {
        { "value", true },
        { "script",
          "export function init() {\n"
          "  if (thisObject.visible !== true) throw new Error('the effect did not start shown');\n"
          "  thisObject.visible = false;\n"
          "}\n"
          "export function mediaThumbnailChanged(event) { thisObject.visible = event.hasThumbnail; }\n" },
    };
    auto scene = nlohmann::json::parse(R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":2,"name":"cover","image":"image.json",
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true,
         "effects":[{"file":"effects/copy/effect.json","id":3}]}
      ]
    })");
    scene["objects"][0]["effects"][0]["visible"] = script;
    ProjectProperties properties;
    auto parsed = WPSceneParser().Parse(
        SceneParseRequest { .scene_id = "effect-visibility-object", .project_properties = &properties },
        scene.dump(), vfs, sound_manager);
    ASSERT_NE(parsed, nullptr);
    ASSERT_NE(parsed->runtime, nullptr);
    auto node = FindRootChildByName(*parsed, "cover");
    ASSERT_NE(node, nullptr);
    const auto camera = parsed->cameras.find(node->Camera());
    ASSERT_NE(camera, parsed->cameras.end());
    ASSERT_TRUE(camera->second->HasImgEffect());
    const auto effect = camera->second->GetImgEffect()->GetEffect(0);

    parsed->runtime->Tick(1.0 / 60.0);
    EXPECT_FALSE(effect->visible) << "the script's write did not reach its effect";
    EXPECT_TRUE(node->Visible()) << "the script's write hid the layer";
    parsed->runtime->SetMediaIntegrationEnabled(true);
    parsed->runtime->DispatchMediaEventJson(R"({"type":"mediaThumbnailChanged","hasThumbnail":true})");
    parsed->runtime->Tick(1.0 / 60.0);
    EXPECT_TRUE(effect->visible);
    EXPECT_TRUE(node->Visible());
    EXPECT_EQ(parsed->runtime->scriptErrorCount(), 0u);
}

TEST(SceneSchema, EffectBuffersTakeWallpaperEnginesSizesFormatsAndSwaps) {
    fs::VFS vfs;
    auto files = std::map<std::string, std::string> {
        { "/image.json", R"({"width":640,"height":360,"material":"mat.json"})" },
        { "/mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["a.tex"]}]})" },
        { "/effects/sim/effect.json",
          R"({"name":"sim","fbos":[
              {"name":"_rt_V1","fit":256,"format":"rg1616f"},
              {"name":"_rt_V2","fit":256,"format":"rg1616f"},
              {"name":"_rt_D1","scale":2,"format":"rgba8888"},
              {"name":"_rt_D2","scale":2,"format":"rgba8888"},
              {"name":"_rt_R1","width":100,"height":50,"format":"rgba_backbuffer"},
              {"name":"_rt_R2","width":100,"height":50,"format":"rgba_backbuffer"}],
            "passes":[
              {"material":"effect_mat.json","target":"_rt_V2","bind":[{"name":"_rt_V1","index":0}]},
              {"material":"effect_mat.json","target":"_rt_D2","bind":[{"name":"_rt_D1","index":0}]},
              {"material":"effect_mat.json","bind":[{"name":"_rt_R2","index":0}]},
              {"material":"effect_mat.json","target":"_rt_R2","bind":[{"name":"_rt_R1","index":0}]},
              {"command":"swap","source":"_rt_V1","target":"_rt_V2"},
              {"command":"swap","source":"_rt_D1","target":"_rt_D2"},
              {"command":"swap","source":"_rt_R1","target":"_rt_R2"}]})" },
        { "/effect_mat.json",
          R"({"passes":[{"blending":"normal","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":[null]}]})" },
        { "/shaders/genericimage.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/genericimage.frag",
          R"(uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)" },
        { "/materials/a.tex.tex", "" },
    };
    // An HDR scene renders in HDR only with its bloom on, so it needs bloom.
    AddHdrBloomFixtureFiles(files);
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager(audio::SoundManager::OutputBackend::Null);
    const std::string   scene = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0, "hdr":true, "bloom":true,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":2,"name":"simulated","image":"image.json",
         "origin":[320,180,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true,
         "effects":[{"file":"effects/sim/effect.json","id":3,"visible":true}]}
      ]
    })";
    auto parsed = WPSceneParser().Parse(SceneParseRequest { .scene_id = "effect-buffers" },
                                        scene, vfs, sound_manager);
    ASSERT_NE(parsed, nullptr);
    const auto target = [&parsed](std::string_view prefix) -> const SceneRenderTarget* {
        for (const auto& [name, rt] : parsed->renderTargets) {
            if (name.starts_with(prefix) && ! name.ends_with("_swap")) return &rt;
        }
        return nullptr;
    };
    // `fit` shrinks the longer side to 256 with the aspect kept; a float format
    // stays float; an explicit 8-bit format stays 8-bit in an HDR scene; an own
    // size wins; the back buffer's format follows the scene.
    const auto* velocity = target("_rt_V1_");
    ASSERT_NE(velocity, nullptr);
    EXPECT_EQ(velocity->width, 256);
    EXPECT_EQ(velocity->height, 144);
    EXPECT_EQ(velocity->format, TextureFormat::RGBA16F);
    const auto* dye = target("_rt_D1_");
    ASSERT_NE(dye, nullptr);
    EXPECT_EQ(dye->format, TextureFormat::RGBA8);
    const auto* sized = target("_rt_R1_");
    ASSERT_NE(sized, nullptr);
    EXPECT_EQ(sized->width, 100);
    EXPECT_EQ(sized->height, 50);
    EXPECT_EQ(sized->format, TextureFormat::RGBA16F);

    auto node = FindRootChildByName(*parsed, "simulated");
    ASSERT_NE(node, nullptr);
    const auto camera = parsed->cameras.find(node->Camera());
    ASSERT_NE(camera, parsed->cameras.end());
    ASSERT_TRUE(camera->second->HasImgEffect());
    const auto& commands = camera->second->GetImgEffect()->GetEffect(0)->commands;
    // V2 and D2 are drawn before they are read again: one copy each. R2 is read
    // first, so its old content goes through a temporary: three copies.
    ASSERT_EQ(commands.size(), 5u);
    EXPECT_TRUE(commands[0].dst.starts_with("_rt_V1_") && commands[0].src.starts_with("_rt_V2_"));
    EXPECT_TRUE(commands[1].dst.starts_with("_rt_D1_") && commands[1].src.starts_with("_rt_D2_"));
    EXPECT_TRUE(commands[2].dst.ends_with("_swap") && commands[2].src.starts_with("_rt_R1_"));
    EXPECT_TRUE(commands[3].dst.starts_with("_rt_R1_") && commands[3].src.starts_with("_rt_R2_"));
    EXPECT_TRUE(commands[4].dst.starts_with("_rt_R2_") && commands[4].src.ends_with("_swap"));
    for (const auto& command : commands) EXPECT_EQ(command.afterpos, 4);
}

TEST(SceneSchema, PassthroughImageEffectBaseMeshUsesLayerLocalCardGeometry) {
    fs::VFS vfs;
    auto files = std::map<std::string, std::string> {
        { "/models/util/composelayer.json",
          R"({"width":64,"height":32,"passthrough":true,"material":"materials/base_passthrough.json"})" },
        { "/materials/base_passthrough.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"passthrough","textures":["a.tex"]}]})" },
        { "/effects/copy/effect.json",
          R"({"name":"copy","passes":[{"material":"materials/effect_copy.json","bind":[{"name":"previous","index":0}]}]})" },
        { "/materials/effect_copy.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"effectcopy","textures":[null]}]})" },
        { "/shaders/passthrough.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/passthrough.frag",
          R"(uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)" },
        { "/shaders/effectcopy.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/effectcopy.frag",
          R"(uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)" },
        { "/materials/a.tex.tex", "" },
    };
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    const std::string   scene = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":401,"name":"green audio bars","image":"models/util/composelayer.json",
         "origin":[180,90,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true,
         "config":{"passthrough":true},
         "effects":[{"file":"effects/copy/effect.json","id":402,"visible":true}]}
      ]
    })";

    auto parsed = parser.Parse("passthrough-effect-local-card", scene, vfs, sound_manager);
    ASSERT_NE(parsed, nullptr);
    auto node = FindRootChildByName(*parsed, "green audio bars");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    ASSERT_EQ(node->Mesh()->Submeshes().size(), 1u);
    ASSERT_EQ(node->Mesh()->Submeshes()[0].VertexCount(), 1u);
    const auto& vertices = node->Mesh()->Submeshes()[0].GetVertexArray(0);
    ASSERT_EQ(vertices.VertexCount(), 4u);

    EXPECT_EQ(VertexPosition(vertices, 0), (std::array<float, 3> { -32.0f, -16.0f, 0.0f }));
    EXPECT_EQ(VertexPosition(vertices, 1), (std::array<float, 3> { -32.0f, 16.0f, 0.0f }));
    EXPECT_EQ(VertexPosition(vertices, 2), (std::array<float, 3> { 32.0f, -16.0f, 0.0f }));
    EXPECT_EQ(VertexPosition(vertices, 3), (std::array<float, 3> { 32.0f, 16.0f, 0.0f }));
}

TEST(SceneSchema, PassthroughNonComposeImageEffectKeepsProjectionBakedBaseMesh) {
    fs::VFS vfs;
    auto files = std::map<std::string, std::string> {
        { "/image.json",
          R"({"width":64,"height":32,"passthrough":true,"material":"materials/base_passthrough.json"})" },
        { "/materials/base_passthrough.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"passthrough","textures":["a.tex"]}]})" },
        { "/effects/copy/effect.json",
          R"({"name":"copy","passes":[{"material":"materials/effect_copy.json","bind":[{"name":"previous","index":0}]}]})" },
        { "/materials/effect_copy.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"effectcopy","textures":[null]}]})" },
        { "/shaders/passthrough.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/passthrough.frag",
          R"(uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)" },
        { "/shaders/effectcopy.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/effectcopy.frag",
          R"(uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)" },
        { "/materials/a.tex.tex", "" },
    };
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    const std::string   scene = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":501,"name":"regular passthrough effect","image":"image.json",
         "origin":[180,90,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true,
         "config":{"passthrough":true},
         "effects":[{"file":"effects/copy/effect.json","id":502,"visible":true}]}
      ]
    })";

    auto parsed = parser.Parse("passthrough-non-compose-effect", scene, vfs, sound_manager);
    ASSERT_NE(parsed, nullptr);
    auto node = FindRootChildByName(*parsed, "regular passthrough effect");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    ASSERT_EQ(node->Mesh()->Submeshes().size(), 1u);
    ASSERT_EQ(node->Mesh()->Submeshes()[0].VertexCount(), 1u);
    const auto& vertices = node->Mesh()->Submeshes()[0].GetVertexArray(0);
    ASSERT_EQ(vertices.VertexCount(), 4u);

    EXPECT_NE(VertexPosition(vertices, 0), (std::array<float, 3> { -32.0f, -16.0f, 0.0f }));
    EXPECT_NE(VertexUv(vertices, 0), (std::array<float, 2> { 0.0f, 1.0f }));
    ExpectVec3Near(
        VertexPosition(vertices, 0), { -0.5375f, -0.5888889f, 0.0f }, 1.0e-6f);
    ExpectVec3Near(
        VertexPosition(vertices, 1), { -0.5375f, -0.41111112f, 0.0f }, 1.0e-6f);
    ExpectVec3Near(
        VertexPosition(vertices, 2), { -0.3375f, -0.5888889f, 0.0f }, 1.0e-6f);
    ExpectVec3Near(
        VertexPosition(vertices, 3), { -0.3375f, -0.41111112f, 0.0f }, 1.0e-6f);
    ExpectVec2Near(VertexUv(vertices, 0), { 0.23125f, 0.79444444f }, 1.0e-6f);
    ExpectVec2Near(VertexUv(vertices, 1), { 0.23125f, 0.70555556f }, 1.0e-6f);
    ExpectVec2Near(VertexUv(vertices, 2), { 0.33125f, 0.79444444f }, 1.0e-6f);
    ExpectVec2Near(VertexUv(vertices, 3), { 0.33125f, 0.70555556f }, 1.0e-6f);
}

TEST(SceneSchema, ImageChildAttachmentAnchorsToParentPuppetMdat) {
    fs::VFS vfs;
    auto files = std::map<std::string, std::string> {
        { "/puppet_image.json",
          R"({"width":64,"height":32,"material":"mat/base.json","puppet":"puppet.mdl"})" },
        { "/puppet.mdl", BuildAttachmentPuppetMdlFixture() },
        { "/mat/base.json", PuppetMaterialJson("baseimage", "base.tex") },
        { "/mat/head.json", PuppetMaterialJson("headimage", "head.tex") },
        { "/child_image.json", R"({"width":16,"height":8,"material":"mat/child.json"})" },
        { "/mat/child.json", PuppetMaterialJson("childimage", "child.tex") },
        { "/shaders/baseimage.vert", R"(
attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/baseimage.frag", R"(
uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)" },
        { "/shaders/headimage.vert", R"(
attribute vec3 a_Position;
attribute vec2 a_TexCoord;
#if SKINNING
attribute uvec4 a_BlendIndices;
attribute vec4 a_BlendWeights;
uniform mat4x3 g_Bones[BONECOUNT];
#endif
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/headimage.frag", R"(
uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)" },
        { "/shaders/childimage.vert", R"(
attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/childimage.frag", R"(
uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)" },
        { "/materials/base.tex.tex", "" },
        { "/materials/head.tex.tex", "" },
        { "/materials/child.tex.tex", "" },
    };
    ASSERT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));

    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    const std::string   scene = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":300,"name":"puppet parent","image":"puppet_image.json",
         "origin":[10,20,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true},
        {"id":301,"name":"hat child","parent":300,"attachment":"hat_anchor",
         "image":"child_image.json","origin":[1,2,3],"scale":[1,1,1],
         "angles":[0,0,0],"visible":true}
      ]
    })";

    auto parsed = parser.Parse("attachment-child", scene, vfs, sound_manager);
    ASSERT_NE(parsed, nullptr);
    auto parent = FindRootChildByName(*parsed, "puppet parent");
    ASSERT_NE(parent, nullptr);
    auto* child = FindFirstChildByName(*parent, "hat child");
    ASSERT_NE(child, nullptr);
    EXPECT_EQ(child->Parent(), parent.get());

    child->UpdateTrans();
    EXPECT_NEAR(child->ModelTrans()(0, 3), 15.0, 1.0e-5);
    EXPECT_NEAR(child->ModelTrans()(1, 3), 27.0, 1.0e-5);
    EXPECT_NEAR(child->ModelTrans()(2, 3), 9.0, 1.0e-5);
    auto reordered = nlohmann::json::parse(scene);
    std::reverse(reordered["objects"].begin(), reordered["objects"].end());
    auto reversed = parser.Parse("attachment-child-reversed", reordered.dump(), vfs, sound_manager);
    ASSERT_NE(reversed, nullptr);
    auto reversed_parent = FindRootChildByName(*reversed, "puppet parent");
    ASSERT_NE(reversed_parent, nullptr);
    auto* reversed_child = FindFirstChildByName(*reversed_parent, "hat child");
    ASSERT_NE(reversed_child, nullptr);
    reversed_child->UpdateTrans();
    EXPECT_TRUE(reversed_child->ModelTrans().isApprox(child->ModelTrans(), 1e-6));
}

TEST(SceneSchema, PuppetAttachmentFollowsAnimatedAffineAndPreservesLocalEdits) {
    Scene scene;
    WPShaderValueUpdater updater(&scene);
    updater.SetCameraParallax({ false, 0.0f, 1.0f, 0.0f });
    auto puppet = std::make_shared<WPPuppet>();
    auto& root = puppet->bones.emplace_back();
    root.local_bind.translate(Eigen::Vector3f(100, 200, 0));
    auto& animation = puppet->anims.emplace_back();
    animation.id = 1;
    animation.fps = 1;
    animation.length = 1;
    animation.mode = WPPuppet::PlayMode::Single;
    auto& track = animation.bone_tracks.emplace_back();
    track.frames.push_back({ Eigen::Vector3f(10, 20, 0), Eigen::Vector3f::Zero(),
                             Eigen::Vector3f::Ones() });
    track.frames.push_back({ Eigen::Vector3f(30, 40, 0), Eigen::Vector3f(0, 0, 1.57079632679f),
                             Eigen::Vector3f(2, 3, 1) });
    puppet->prepared();
    WPPuppetLayer layer(puppet);
    WPPuppetLayer::AnimationLayer settings;
    settings.id = 1;
    layer.prepared(std::span(&settings, 1));
    auto parent = std::make_shared<SceneNode>();
    parent->SetTranslate(Eigen::Vector3f(5, 7, 0));
    parent->SetScale(Eigen::Vector3f(2, 2, 1));
    auto child = std::make_shared<SceneNode>();
    child->SetTranslate(Eigen::Vector3f(1, 2, 0));
    parent->AppendChild(child);
    auto attachment = puppet->bones[0].world_bind;
    attachment.translate(Eigen::Vector3f(4, 5, 0));
    updater.RegisterPuppetAttachments(layer, { { child.get(), 0, attachment } });
    child->UpdateTrans();
    EXPECT_NEAR(child->ModelTrans()(0, 3), 35, 1e-4);
    EXPECT_NEAR(child->ModelTrans()(1, 3), 61, 1e-4);
    scene.PassFrameTime(1.0);
    updater.FrameBegin();
    child->UpdateTrans();
    EXPECT_NEAR(child->ModelTrans()(0, 3), 23, 1e-4);
    EXPECT_NEAR(child->ModelTrans()(1, 3), 107, 1e-4);
    EXPECT_NEAR(child->ModelTrans()(0, 1), -6, 1e-4);
    EXPECT_NEAR(child->ModelTrans()(1, 0), 4, 1e-4);
    const Eigen::Matrix4d sampled = child->ModelTrans();
    updater.FrameBegin();
    child->UpdateTrans();
    EXPECT_TRUE(child->ModelTrans().isApprox(sampled, 1e-6));
    child->SetTranslate(Eigen::Vector3f(3, 2, 0));
    updater.FrameBegin();
    child->UpdateTrans();
    EXPECT_NEAR(child->ModelTrans()(0, 3), 23, 1e-4);
    EXPECT_NEAR(child->ModelTrans()(1, 3), 115, 1e-4);
    SceneCamera camera(640, 360, 0.01f, 100.0f);
    scene.activeCamera = &camera;
    auto mesh = std::make_shared<SceneMesh>();
    mesh->AddMaterial(SceneMaterial {});
    parent->AddMesh(mesh);
    WPShaderValueData shader_data;
    shader_data.puppet_layer = layer;
    updater.SetNodeData(parent.get(), shader_data);
    updater.InitUniforms(parent.get(), [](std::string_view name) { return name == "g_Bones"; });
    sprite_map_t sprites;
    Eigen::Matrix4f uniform = Eigen::Matrix4f::Zero();
    int bone_updates = 0;
    const auto capture_bones = [&](std::string_view name, const ShaderValue& value) {
        if (name != "g_Bones") return;
        ASSERT_EQ(value.size(), 16u);
        for (int i = 0; i < 16; ++i) uniform.data()[i] = value[i];
        ++bone_updates;
    };
    updater.UpdateUniforms(parent.get(), sprites, capture_bones);
    ASSERT_EQ(bone_updates, 1);
    ASSERT_TRUE(layer.setFrame(0, 0.5));
    updater.FrameBegin();
    updater.UpdateUniforms(parent.get(), sprites, capture_bones);
    ASSERT_EQ(bone_updates, 2);
    Eigen::Affine3f expected = Eigen::Affine3f::Identity();
    expected.translate(Eigen::Vector3f(20, 30, 0));
    expected.rotate(Eigen::AngleAxisf(0.785398163395f, Eigen::Vector3f::UnitZ()));
    expected.scale(Eigen::Vector3f(1.5f, 2.0f, 1.0f));
    expected = expected * puppet->bones[0].inv_bind;
    EXPECT_TRUE(uniform.isApprox(expected.matrix(), 1e-5));
    Eigen::Affine3d local = Eigen::Affine3d::Identity();
    local.translate(Eigen::Vector3d(3, 2, 0));
    child->UpdateTrans();
    EXPECT_TRUE(child->ModelTrans().isApprox(
        parent->ModelTrans() * (expected * attachment).matrix().cast<double>() * local.matrix(), 1e-5));
    child->SetTranslate(Eigen::Vector3f(4, 6, 0));
    updater.FrameBegin();
    updater.UpdateUniforms(parent.get(), sprites, capture_bones);
    ASSERT_EQ(bone_updates, 3);
    EXPECT_TRUE(uniform.isApprox(expected.matrix(), 1e-5));
    local = Eigen::Affine3d::Identity();
    local.translate(Eigen::Vector3d(4, 6, 0));
    child->UpdateTrans();
    EXPECT_TRUE(child->ModelTrans().isApprox(
        parent->ModelTrans() * (expected * attachment).matrix().cast<double>() * local.matrix(), 1e-5));
    scene.activeCamera = nullptr;
}

TEST(SceneSchema, ParserUsesStableRuntimeNamesForDuplicateGenericLayerNames) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "duplicate-layer-names",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0,0,0], "skylightcolor":[0,0,0],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":400,"height":300}
      },
      "objects": [
        {
          "id": 10,
          "name": "tap target",
          "origin": [100,150,0],
          "visible": {
            "value": true,
            "script": "export function update(value) { return value; }"
          }
        },
        {
          "id": 11,
          "name": "tap target",
          "origin": [300,150,0],
          "visible": {
            "value": true,
            "script": "export function update(value) { return value; }"
          }
        }
      ]
    })",
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    EXPECT_FALSE(scene->runtime->HasNodeNamed("tap target"));
    EXPECT_TRUE(scene->runtime->HasNodeNamed("__we_layer_10"));
    EXPECT_TRUE(scene->runtime->HasNodeNamed("__we_layer_11"));
}

TEST(SceneSchema, ParserUsesStableRuntimeNamesForDuplicateImageLayerNames) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "duplicate-image-layer-names",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0,0,0], "skylightcolor":[0,0,0],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":400,"height":300}
      },
      "objects": [
        {
          "id": 20,
          "name": "tap target",
          "image": "image.json",
          "origin": [100,150,0],
          "size": [64,32],
          "visible": true
        },
        {
          "id": 21,
          "name": "tap target",
          "image": "image.json",
          "origin": [300,150,0],
          "size": [64,32],
          "visible": true
        }
      ]
    })",
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    EXPECT_FALSE(scene->runtime->HasNodeNamed("tap target"));
    EXPECT_TRUE(scene->runtime->HasNodeNamed("__we_layer_20"));
    EXPECT_TRUE(scene->runtime->HasNodeNamed("__we_layer_21"));
    EXPECT_EQ(scene->runtime->NodeSize("__we_layer_20"), Eigen::Vector2f(64.0f, 32.0f));
    EXPECT_EQ(scene->runtime->NodeSize("__we_layer_21"), Eigen::Vector2f(64.0f, 32.0f));
}

// A model can state a size of its own (the editor writes one for a sprite sheet:
// a frame's size), and the scene saves the size the layer was given in the
// editor. A layer resized there is drawn at the scene's size, as Wallpaper Engine
// draws it; the model's size is only for a layer that saved none.
TEST(SceneSchema, ALayerIsDrawnAtTheSizeItsSceneSavedRatherThanItsModels) {
    fs::VFS vfs;
    MountSceneFiles(vfs); // image.json states 64 x 32
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    auto scene = parser.Parse(SceneParseRequest {
        .scene_id = "resized-model-layer", .project_properties = &properties,
    }, R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0,0,0], "skylightcolor":[0,0,0],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "orthogonalprojection":{"width":400,"height":300}
      },
      "objects": [
        {"id":30,"name":"resized","image":"image.json","origin":[100,150,0],
         "size":"96.00000 72.00000","visible":true},
        {"id":31,"name":"unsized","image":"image.json","origin":[300,150,0],"visible":true}
      ]
    })", vfs, sound_manager);
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);

    const auto drawn = [&](std::string_view name) {
        Eigen::Vector2f extent { 0.0f, 0.0f };
        const auto      node = FindRootChildByName(*scene, name);
        if (node == nullptr || node->Mesh() == nullptr) {
            ADD_FAILURE() << name << " has no card";
            return extent;
        }
        const auto& vertices = node->Mesh()->GetVertexArray(0);
        for (std::size_t index = 0; index < vertices.VertexCount(); ++index) {
            const auto position = VertexPosition(vertices, index);
            extent = extent.cwiseMax(Eigen::Vector2f(std::abs(position[0]), std::abs(position[1])));
        }
        return Eigen::Vector2f(extent * 2.0f);
    };
    EXPECT_EQ(scene->runtime->NodeSize("resized"), Eigen::Vector2f(96.0f, 72.0f));
    EXPECT_EQ(drawn("resized"), Eigen::Vector2f(96.0f, 72.0f));
    EXPECT_EQ(scene->runtime->NodeSize("unsized"), Eigen::Vector2f(64.0f, 32.0f));
    EXPECT_EQ(drawn("unsized"), Eigen::Vector2f(64.0f, 32.0f));
}

TEST(SceneSchema, DuplicateNamesResolveInAuthoredOrderWithoutSharingThisLayerBindings) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    audio::SoundManager sound(audio::SoundManager::OutputBackend::Null);
    WPSceneParser parser;
    const std::string source = R"JSON({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {"ambientcolor":[0,0,0], "skylightcolor":[0,0,0],
                  "clearcolor":[0,0,0], "cameraparallax":false,
                  "orthogonalprojection":{"width":400,"height":300}},
      "objects": [
        {"id":30, "name":"driver", "origin": {"value":[0,0,0],
          "script":"const image = thisScene.getLayer('image first'); const group = thisScene.getLayer('group first'); export function update(value) { image.scale = new Vec3(0.125); group.scale = new Vec3(0.25); return value; }"}},
        {"id":10, "name":"image first", "image":"image.json", "size":[64,32]},
        {"id":11, "name":"image first", "visible": {"value":true,
          "script":"export function update(value) { thisLayer.scale = new Vec3(9); return value; }"}},
        {"id":20, "name":"group first"},
        {"id":21, "name":"group first", "image":"image.json", "size":[64,32],
          "visible": {"value":true,
          "script":"export function update(value) { thisLayer.scale = new Vec3(7); return value; }"}}
      ]
    })JSON";
    ProjectProperties properties;
    auto scene = parser.Parse(SceneParseRequest {
        .scene_id = "duplicate-name-lookup", .project_properties = &properties,
    }, source, vfs, sound);
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    for (int frame = 0; frame < 3; ++frame) {
        scene->runtime->Tick(1.0 / 60.0);
        EXPECT_EQ(scene->runtime->NodeScale("__we_layer_10"), Eigen::Vector3f::Constant(0.125f));
        EXPECT_EQ(scene->runtime->NodeScale("__we_layer_11"), Eigen::Vector3f::Constant(9.0f));
        EXPECT_EQ(scene->runtime->NodeScale("__we_layer_20"), Eigen::Vector3f::Constant(0.25f));
        EXPECT_EQ(scene->runtime->NodeScale("__we_layer_21"), Eigen::Vector3f::Constant(7.0f));
    }
    EXPECT_EQ(scene->runtime->scriptErrorCount(), 0u);
    auto without_scripts = parser.Parse("duplicate-name-no-runtime", source, vfs, sound);
    ASSERT_NE(without_scripts, nullptr);
    EXPECT_EQ(without_scripts->runtime, nullptr);
}

TEST(SceneSchema, DuplicateLayerAliasesIgnoreMalformedEntriesAndKeepValidLookup) {
    for (const auto& entry : std::vector<nlohmann::json> {
             nullptr, 7, nlohmann::json::array(),
             {{"id", 30}, {"name", 7}}, {{"id", 30}, {"name", nullptr}},
             {{"id", "invalid"}, {"name", "shared"}}, {{"id", nullptr}, {"name", "shared"}},
             {{"name", "shared"}}, {{"id", 31}},
         }) {
        SCOPED_TRACE(entry.dump());
        auto source = nlohmann::json::parse(R"({
          "camera":{"center":[0,0,0],"eye":[0,0,1],"up":[0,1,0]},
          "general":{"ambientcolor":[0,0,0],"skylightcolor":[0,0,0],
            "clearcolor":[0,0,0],"cameraparallax":false,
            "orthogonalprojection":{"width":400,"height":300}},
          "objects":[
            {"id":10,"name":"shared"}, {"id":11,"name":"shared"},
            {"id":20,"name":"driver","origin":{"value":[0,0,0],
              "script":"const target = thisScene.getLayer('shared'); export function update(value) { target.scale = new Vec3(0.125); return value; }"}}
          ]
        })");
        source["objects"].insert(source["objects"].begin(), entry);
        fs::VFS vfs;
        MountSceneFiles(vfs);
        audio::SoundManager sound(audio::SoundManager::OutputBackend::Null);
        ProjectProperties properties;
        WPSceneParser parser;
        std::shared_ptr<Scene> scene;
        ASSERT_NO_THROW(scene = parser.Parse(SceneParseRequest {
            .scene_id = "malformed-alias-entry", .project_properties = &properties,
        }, source.dump(), vfs, sound));
        ASSERT_NE(scene, nullptr);
        ASSERT_NE(scene->runtime, nullptr);
        EXPECT_EQ(scene->runtime->ResolveLayerName("shared"), "__we_layer_10");
        scene->runtime->Tick(1.0 / 60.0);
        EXPECT_EQ(scene->runtime->NodeScale("__we_layer_10"), Eigen::Vector3f::Constant(0.125f));
        EXPECT_EQ(scene->runtime->NodeScale("__we_layer_11"), Eigen::Vector3f::Ones());
        EXPECT_EQ(scene->runtime->scriptErrorCount(), 0u);
    }
}

TEST(SceneSchema, CallbackOnlyDuplicateButtonsToggleNamedGroupsThroughParser) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    audio::SoundManager sound;
    WPSceneParser parser;
    const nlohmann::json setting = {
        {"value", true}, {"script", R"JS(
export var scriptProperties = createScriptProperties()
    .addText({name: 'target', value: 'missing'}).finish();
let visible;
export function init(value) { visible = true; return value; }
export function cursorClick() {
    visible = !visible;
    thisScene.getLayer(scriptProperties.target).visible = visible;
}
)JS"}, {"scriptproperties", {{"target", "mode"}}}};
    const nlohmann::json source = {
        {"camera", {{"center", {0, 0, 0}}, {"eye", {0, 0, 1}}, {"up", {0, 1, 0}}}},
        {"general", {{"ambientcolor", {0, 0, 0}}, {"skylightcolor", {0, 0, 0}},
                     {"clearcolor", {0, 0, 0}}, {"cameraparallax", false},
                     {"orthogonalprojection", {{"width", 400}, {"height", 300}}}}},
        {"objects", nlohmann::json::array({
            {{"id", 1}, {"name", "mode"}, {"visible", true}},
            {{"id", 2}, {"name", "content"}, {"image", "image.json"}, {"parent", 1}},
            {{"id", 3}, {"name", "button"}, {"image", "image.json"},
             {"origin", {200, 150, 0}}, {"size", {80, 80}}, {"visible", setting}},
            {{"id", 4}, {"name", "button"}, {"image", "image.json"}, {"parent", 3},
             {"scale", {0.9, 0.9, 1}}, {"size", {80, 80}}, {"visible", setting}}
        })}
    };
    ProjectProperties properties;
    auto scene = parser.Parse(SceneParseRequest {
        .scene_id = "callback-buttons", .project_properties = &properties,
    }, source.dump(), vfs, sound);
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto& runtime = *scene->runtime;
    runtime.Tick(0.01);
    runtime.SetCursorInput(0.5f, 0.5f);
    runtime.SetCursorEnter(true);
    for (bool visible : {false, true, false}) {
        runtime.SetCursorButtons(0, 1, 1);
        runtime.DispatchCursorFrameEvents(true);
        runtime.SetCursorButtons(0, 0, 0);
        runtime.Tick(0.01);
        EXPECT_EQ(runtime.NodeVisible("mode"), visible);
    }
    EXPECT_EQ(runtime.scriptErrorCount(), 0u);
}

TEST(SceneSchema, HiddenByDefaultVisibilityScriptDrivesVisibilityAndOrigin) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    audio::SoundManager sound;
    WPSceneParser        parser;
    // Authored "value" is the initial state handed to the script, not a licence
    // to run it: a layer hidden at authoring time must still follow update().
    const auto visibility = [](const char* property) {
        return nlohmann::json {
            { "value", false },
            { "script", std::string(R"JS(
let on = false;
export function applyUserProperties(changed) { if (changed.hasOwnProperty(')JS") +
                            property + R"JS(')) on = changed.)JS" + property + R"JS(; }
export function update() { return on; }
)JS" },
        };
    };
    const nlohmann::json source = {
        { "camera", { { "center", { 0, 0, 0 } }, { "eye", { 0, 0, 1 } }, { "up", { 0, 1, 0 } } } },
        { "general",
          { { "ambientcolor", { 0, 0, 0 } },
            { "skylightcolor", { 0, 0, 0 } },
            { "clearcolor", { 0, 0, 0 } },
            { "cameraparallax", false },
            { "orthogonalprojection", { { "width", 400 }, { "height", 300 } } } } },
        { "objects",
          nlohmann::json::array(
              { { { "id", 11 },
                  { "name", "shown by script" },
                  { "image", "image.json" },
                  { "size", { 80, 60 } },
                  { "origin",
                    { { "value", { 0, 0, 0 } },
                      { "script", "export function update() { return new Vec3(30, 0, 0); }" } } },
                  { "visible", visibility("show_first") } },
                { { "id", 12 },
                  { "name", "hidden by script" },
                  { "image", "image.json" },
                  { "size", { 80, 60 } },
                  { "visible", visibility("show_second") } } }) }
    };
    ProjectProperties properties {
        { "show_first", RuntimeScalarValue::Bool(true) },
        { "show_second", RuntimeScalarValue::Bool(false) },
    };
    auto scene = parser.Parse(SceneParseRequest {
                                  .scene_id           = "hidden-default-visibility-script",
                                  .project_properties = &properties,
                              },
                              source.dump(),
                              vfs,
                              sound);
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto& runtime = *scene->runtime;
    runtime.Tick(0.01);

    auto shown = FindRootChildByName(*scene, "shown by script");
    ASSERT_NE(shown, nullptr);
    EXPECT_TRUE(shown->Visible());
    EXPECT_FLOAT_EQ(shown->Translate().x(), 30.0f);
    auto hidden = FindRootChildByName(*scene, "hidden by script");
    ASSERT_NE(hidden, nullptr);
    EXPECT_FALSE(hidden->Visible());
    EXPECT_EQ(runtime.scriptErrorCount(), 0u);
}

TEST(SceneSchema, OriginTimelineMovesAlignedLayersAndStopsRequestingFrames) {
    for (bool relative : { false, true }) {
        for (const auto* anchor : { "left", "right" }) {
            SCOPED_TRACE(std::string(anchor) + (relative ? " relative" : " absolute"));
            fs::VFS vfs;
            MountSceneFiles(vfs);
            audio::SoundManager sound;
            nlohmann::json object = {
                { "id", 21 }, { "name", "moving card" }, { "image", "image.json" },
                { "alignment", anchor }, { "scale", { 2, 1, 1 } },
                { "origin", {
                    { "value", { 100, 70, 3 } },
                    { "animation", {
                        { "relative", relative },
                        { "options", { { "fps", 20 }, { "length", 20 },
                                         { "mode", "single" }, { "name", "slide" } } },
                        { "c0", nlohmann::json::array({
                            { { "frame", 0 }, { "value", 0 } },
                            { { "frame", 20 }, { "value", 80 } } }) }
                    } }
                } }
            };
            auto scene = ParseOrthoShotScene(vfs, sound, object.dump());
            ASSERT_NE(scene, nullptr);
            auto& runtime = *scene->runtime;
            auto node = FindRootChildByName(*scene, "moving card");
            ASSERT_NE(node, nullptr);
            const float base = relative ? 100.0f : 0.0f;
            const float offset = runtime.NodeSize("moving card").x() *
                                 (std::string_view(anchor) == "left" ? 1.0f : -1.0f);
            const auto expect_origin = [&](float x) {
                EXPECT_FLOAT_EQ(runtime.NodeTranslate("moving card").x(), x);
                EXPECT_FLOAT_EQ(node->Translate().x(), x + offset);
                EXPECT_FLOAT_EQ(node->Translate().y(), 70.0f);
                EXPECT_FLOAT_EQ(node->Translate().z(), 3.0f);
            };
            expect_origin(base);
            EXPECT_NE(runtime.DescribeTimeAdvancingWork() & SceneDemandReason::Animation, 0u);
            runtime.Tick(0.5);
            expect_origin(base + 40.0f);
            runtime.Tick(0.5);
            expect_origin(base + 80.0f);
            EXPECT_EQ(runtime.DescribeTimeAdvancingWork() & SceneDemandReason::Animation, 0u);
            runtime.Tick(10.0);
            expect_origin(base + 80.0f); // no accumulated relative displacement
            auto* clock = runtime.FindScalarAnimation("moving card", "slide");
            ASSERT_NE(clock, nullptr);
            clock->Play();
            runtime.Tick(0.25);
            expect_origin(base + 20.0f);
            clock->playing = false;
            runtime.Tick(10.0);
            expect_origin(base + 20.0f);
            clock->SetFrame(15.0);
            runtime.Tick(0.0);
            expect_origin(base + 60.0f);
        }
    }
}

TEST(SceneSchema, OriginTimelineComponentsUseOneLoopAndPreserveUnkeyedAxes) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    audio::SoundManager sound;
    auto scene = ParseOrthoShotScene(vfs, sound, R"({
        "id":21,"name":"looping card","image":"image.json",
        "origin":{"value":[10,20,30],"animation":{
            "relative":true,
            "options":{"fps":10,"mode":"loop","name":"orbit","startpaused":true},
            "c0":[{"frame":2,"value":4},{"frame":5,"value":10}],
            "c1":[{"frame":0,"value":0},{"frame":20,"value":40}]
        }}
    })");
    ASSERT_NE(scene, nullptr);
    auto& runtime = *scene->runtime;
    const auto expect_origin = [&](float x, float y) {
        EXPECT_EQ(runtime.NodeTranslate("looping card"), Eigen::Vector3f(x, y, 30));
    };
    runtime.Tick(5.0);
    expect_origin(10, 20); // before the first x key: zero relative offset
    auto* clock = runtime.FindScalarAnimation("looping card", "orbit");
    ASSERT_NE(clock, nullptr);
    clock->Play();
    runtime.Tick(0.5);
    expect_origin(20, 30);
    runtime.Tick(0.5);
    expect_origin(20, 40); // the short x curve holds, it does not loop on its own
    runtime.Tick(1.0);
    expect_origin(10, 20); // the longest component defines the inferred clock length
    EXPECT_EQ(runtime.scriptErrorCount(), 0u);
}

TEST(SceneSchema, OriginTimelineMovesGroupsAndTextParentsOnOneClock) {
    for (bool text : { false, true }) {
        fs::VFS vfs;
        MountSceneFiles(vfs);
        audio::SoundManager sound;
        auto parent = nlohmann::json::parse(R"({
            "id":21,"name":"moving parent",
            "origin":{"value":[10,20,0],"animation":{
                "relative":true,
                "options":{"fps":10,"length":10,"mode":"single"},
                "c0":[{"frame":0,"value":0},{"frame":10,"value":40}]
            }}
        })");
        if (text) {
            parent["text"] = "caption";
            parent["font"] = "Arial";
            parent["pointsize"] = 24;
        }
        auto scene = ParseOrthoShotScene(vfs, sound, parent.dump() + R"(,
            {"id":22,"name":"child card","image":"image.json","parent":21,
             "origin":[5,6,0]}
        )");
        ASSERT_NE(scene, nullptr);
        auto& runtime = *scene->runtime;
        runtime.Tick(0.5);
        EXPECT_FLOAT_EQ(runtime.NodeTranslate("moving parent").x(), 30.0f);
        auto node = FindRootChildByName(*scene, "moving parent");
        ASSERT_NE(node, nullptr);
        ASSERT_EQ(node->GetChildren().size(), 1u);
        node->GetChildren().front()->UpdateTrans();
        EXPECT_NEAR(node->GetChildren().front()->ModelTrans()(0, 3),
                    node->Translate().x() + 5.0f, 1e-4);
        runtime.Tick(0.5);
        EXPECT_FLOAT_EQ(runtime.NodeTranslate("moving parent").x(), 50.0f);
        EXPECT_EQ(runtime.DescribeTimeAdvancingWork() & SceneDemandReason::Animation, 0u);
        EXPECT_EQ(runtime.scriptErrorCount(), 0u);
    }
}

TEST(SceneSchema, OriginTimelineDoesNotOverrideAScriptOrUserProperty) {
    for (bool scripted : { false, true }) {
        fs::VFS vfs;
        MountSceneFiles(vfs);
        audio::SoundManager sound;
        nlohmann::json object = nlohmann::json::parse(R"({
            "id":21,"name":"bound card","image":"image.json",
            "origin":{"value":[1,2,3],"animation":{
                "options":{"fps":10,"length":10,"mode":"single","name":"unused"},
                "c0":[{"frame":0,"value":999}]
            }}
        })");
        if (scripted) object["origin"]["script"] =
            "export function update() { return new Vec3(7, 8, 9); }";
        else object["origin"]["user"] = "position";
        auto scene = ParseOrthoShotScene(vfs, sound, object.dump(), {
            { "position", RuntimeScalarValue::String("7 8 9") }
        });
        ASSERT_NE(scene, nullptr);
        auto& runtime = *scene->runtime;
        runtime.Tick(1.0);
        EXPECT_EQ(runtime.NodeTranslate("bound card"), Eigen::Vector3f(7, 8, 9));
        EXPECT_EQ(runtime.FindScalarAnimation("bound card", "unused"), nullptr);
        EXPECT_EQ(runtime.scriptErrorCount(), 0u);
    }
}

// A layer's scale and angles are keyed on a timeline like its origin: the
// editor writes `{value, animation:{c0..c2, options, relative}}` for each. The
// pose they describe at frame 0 is the layer's pose from the first frame, a
// single play ends where its last key leaves it, a timeline named in the scene
// can be played again by a script, and a relative curve is an offset from the
// authored value.
TEST(SceneSchema, ScaleAndAnglesTimelinesPlayLikeOriginTimelines) {
    struct Property {
        const char*          key;
        std::array<float, 3> base;
    };
    for (const auto& [key, base] : { Property { "scale", { 2, 3, 4 } },
                                     Property { "angles", { 10, 20, 30 } } }) {
        for (bool relative : { false, true }) {
            SCOPED_TRACE(std::string(key) + (relative ? " relative" : " absolute"));
            fs::VFS vfs;
            MountSceneFiles(vfs);
            audio::SoundManager sound;
            nlohmann::json object = {
                { "id", 21 }, { "name", "keyed card" }, { "image", "image.json" },
                { key, {
                    { "value", base },
                    { "animation", {
                        { "relative", relative },
                        { "options", { { "fps", 20 }, { "length", 20 },
                                         { "mode", "single" }, { "name", "pose" } } },
                        { "c0", nlohmann::json::array({
                            { { "frame", 0 }, { "value", 0 } },
                            { { "frame", 20 }, { "value", 1 } } }) }
                    } }
                } }
            };
            auto scene = ParseOrthoShotScene(vfs, sound, object.dump());
            ASSERT_NE(scene, nullptr);
            auto& runtime = *scene->runtime;
            auto node = FindRootChildByName(*scene, "keyed card");
            ASSERT_NE(node, nullptr);
            const auto pose = [&] {
                return std::string_view(key) == "scale" ? node->Scale() : node->Rotation();
            };
            // The curve describes x; y and z, which it does not key, keep the
            // authored value.
            const float start = relative ? base[0] : 0.0f;
            const auto  expect_pose = [&](float x) {
                EXPECT_FLOAT_EQ(pose().x(), x);
                EXPECT_FLOAT_EQ(pose().y(), base[1]);
                EXPECT_FLOAT_EQ(pose().z(), base[2]);
            };
            expect_pose(start);
            EXPECT_NE(runtime.DescribeTimeAdvancingWork() & SceneDemandReason::Animation, 0u);
            runtime.Tick(0.5);
            expect_pose(start + 0.5f);
            runtime.Tick(0.5);
            expect_pose(start + 1.0f);
            EXPECT_EQ(runtime.DescribeTimeAdvancingWork() & SceneDemandReason::Animation, 0u);
            runtime.Tick(10.0);
            expect_pose(start + 1.0f); // no accumulated relative displacement
            auto* clock = runtime.FindScalarAnimation("keyed card", "pose");
            ASSERT_NE(clock, nullptr);
            clock->Play();
            runtime.Tick(0.25);
            expect_pose(start + 0.25f);
            EXPECT_EQ(runtime.scriptErrorCount(), 0u);
        }
    }
}

// A timeline that starts paused is held at its first pose, not at the authored
// value, until something plays it: an intro keyed to start off the layer's
// resting place shows there from the first frame. A script finds it by name.
TEST(SceneSchema, ScaleAndAnglesTimelinesStartingPausedHoldTheirFirstPoseUntilPlayed) {
    for (const auto* key : { "scale", "angles" }) {
        SCOPED_TRACE(key);
        fs::VFS vfs;
        MountSceneFiles(vfs);
        audio::SoundManager sound;
        nlohmann::json object = {
            { "id", 21 }, { "name", "intro card" }, { "image", "image.json" },
            { key, {
                { "value", { 1, 1, 1 } },
                { "animation", {
                    { "relative", true },
                    { "options", { { "fps", 10 }, { "length", 10 }, { "mode", "single" },
                                     { "name", "intro" }, { "startpaused", true } } },
                    { "c1", nlohmann::json::array({
                        { { "frame", 0 }, { "value", -0.5 } },
                        { { "frame", 10 }, { "value", 0.5 } } }) }
                } }
            } }
        };
        auto scene = ParseOrthoShotScene(vfs, sound, object.dump());
        ASSERT_NE(scene, nullptr);
        auto& runtime = *scene->runtime;
        auto node = FindRootChildByName(*scene, "intro card");
        ASSERT_NE(node, nullptr);
        const auto pose_y = [&] {
            return std::string_view(key) == "scale" ? node->Scale().y() : node->Rotation().y();
        };
        EXPECT_FLOAT_EQ(pose_y(), 0.5f);
        EXPECT_EQ(runtime.DescribeTimeAdvancingWork() & SceneDemandReason::Animation, 0u)
            << "a paused timeline needs no frames";
        runtime.Tick(5.0);
        EXPECT_FLOAT_EQ(pose_y(), 0.5f);
        auto* clock = runtime.FindAnimationByName("intro");
        ASSERT_NE(clock, nullptr);
        clock->Play();
        runtime.Tick(0.5);
        EXPECT_FLOAT_EQ(pose_y(), 1.0f);
        runtime.Tick(0.5);
        EXPECT_FLOAT_EQ(pose_y(), 1.5f);
    }
}

// A loop wraps the shared clock, and short component curves hold their last key
// until it does, as origin components do.
TEST(SceneSchema, ScaleTimelineLoopsOnOneClockAndKeepsUnkeyedAxes) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    audio::SoundManager sound;
    auto scene = ParseOrthoShotScene(vfs, sound, R"({
        "id":21,"name":"pulsing card","image":"image.json",
        "scale":{"value":[1,2,3],"animation":{
            "relative":true,
            "options":{"fps":10,"mode":"loop","name":"pulse"},
            "c0":[{"frame":0,"value":0},{"frame":5,"value":1}],
            "c1":[{"frame":0,"value":0},{"frame":10,"value":4}]
        }}
    })");
    ASSERT_NE(scene, nullptr);
    auto& runtime = *scene->runtime;
    const auto expect_scale = [&](float x, float y) {
        const auto scale = runtime.NodeScale("pulsing card");
        EXPECT_NEAR(scale.x(), x, 1e-5);
        EXPECT_NEAR(scale.y(), y, 1e-5);
        EXPECT_FLOAT_EQ(scale.z(), 3.0f);
    };
    expect_scale(1, 2);
    runtime.Tick(0.5);
    expect_scale(2, 4);
    runtime.Tick(0.3);
    expect_scale(2, 5.2f); // the short x curve holds its last key
    runtime.Tick(0.4);
    expect_scale(1.4f, 2.8f); // the longest curve sets the clock's length: 12 frames is 2
    EXPECT_NE(runtime.DescribeTimeAdvancingWork() & SceneDemandReason::Animation, 0u);
    EXPECT_EQ(runtime.scriptErrorCount(), 0u);
}

// The editor links the properties it keys on one timeline: the first is the
// parent, the others name it in `options.parent` and carry none of the play
// state of their own. They are one animation, so a script that holds or plays
// the parent holds or plays them all.
TEST(SceneSchema, LinkedOriginScaleAndAnglesTimelinesShareTheirParentsClock) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    audio::SoundManager sound;
    auto scene = ParseOrthoShotScene(vfs, sound, R"({
        "id":21,"name":"linked card","image":"image.json",
        "origin":{"value":[10,20,0],"animation":{
            "relative":true,
            "options":{"fps":10,"length":10,"mode":"single","name":"rise","startpaused":true,
                       "children":[{"key":"angles"}]},
            "c0":[{"frame":0,"value":0},{"frame":10,"value":40}]
        }},
        "angles":{"value":[0,0,0],"animation":{
            "relative":true,
            "options":{"fps":10,"length":10,"mode":"single","parent":{"key":"origin"},
                       "children":[{"key":"scale"}]},
            "c2":[{"frame":0,"value":0},{"frame":10,"value":90}]
        }},
        "scale":{"value":[1,1,1],"animation":{
            "relative":true,
            "options":{"fps":10,"length":10,"mode":"single","parent":{"key":"angles"}},
            "c0":[{"frame":0,"value":0},{"frame":10,"value":1}]
        }}
    })");
    ASSERT_NE(scene, nullptr);
    auto& runtime = *scene->runtime;
    const auto expect_pose = [&](float x, float turn, float width) {
        EXPECT_FLOAT_EQ(runtime.NodeTranslate("linked card").x(), x);
        EXPECT_FLOAT_EQ(runtime.NodeRotation("linked card").z(), turn);
        EXPECT_FLOAT_EQ(runtime.NodeScale("linked card").x(), width);
    };
    expect_pose(10, 0, 1);
    runtime.Tick(5.0);
    expect_pose(10, 0, 1); // the parent is paused, so are the properties linked to it
    EXPECT_EQ(runtime.DescribeTimeAdvancingWork() & SceneDemandReason::Animation, 0u);
    auto* clock = runtime.FindScalarAnimation("linked card", "rise");
    ASSERT_NE(clock, nullptr);
    clock->Play();
    runtime.Tick(0.5);
    expect_pose(30, 45, 1.5f);
    runtime.Tick(0.5);
    expect_pose(50, 90, 2);
    EXPECT_EQ(runtime.DescribeTimeAdvancingWork() & SceneDemandReason::Animation, 0u);
    EXPECT_EQ(runtime.scriptErrorCount(), 0u);
}

// A scale or angles a script or a wallpaper property writes has one writer: its
// authored timeline does not become a second one, and registers no clock.
TEST(SceneSchema, ScaleAndAnglesTimelinesDoNotOverrideAScriptOrUserProperty) {
    for (const auto* key : { "scale", "angles" }) {
        for (bool scripted : { false, true }) {
            // A script returns an angle in its own units, which is not what this checks.
            if (scripted && std::string_view(key) == "angles") continue;
            SCOPED_TRACE(std::string(key) + (scripted ? " scripted" : " user property"));
            fs::VFS vfs;
            MountSceneFiles(vfs);
            audio::SoundManager sound;
            nlohmann::json object = nlohmann::json::parse(R"({
                "id":21,"name":"bound card","image":"image.json"
            })");
            object[key] = nlohmann::json::parse(R"({"value":[1,2,3],"animation":{
                "options":{"fps":10,"length":10,"mode":"single","name":"unused"},
                "c0":[{"frame":0,"value":999}]
            }})");
            if (scripted) object[key]["script"] =
                "export function update() { return new Vec3(7, 8, 9); }";
            else object[key]["user"] = "pose";
            auto scene = ParseOrthoShotScene(vfs, sound, object.dump(), {
                { "pose", RuntimeScalarValue::String("7 8 9") }
            });
            ASSERT_NE(scene, nullptr);
            auto& runtime = *scene->runtime;
            runtime.Tick(1.0);
            const auto pose = std::string_view(key) == "scale" ? runtime.NodeScale("bound card")
                                                              : runtime.NodeRotation("bound card");
            EXPECT_EQ(pose, Eigen::Vector3f(7, 8, 9));
            EXPECT_EQ(runtime.FindScalarAnimation("bound card", "unused"), nullptr);
            EXPECT_EQ(runtime.scriptErrorCount(), 0u);
        }
    }
}

// Every kind of object that sits in the scene takes its scale and angles
// from the one registration helper: text, a particle system, a light and a
// model, not only the image layer and the group the tests above use. A timeline
// the editor keyed on one plays there like it does on a card.
TEST(SceneSchema, ScaleAndAnglesTimelinesPlayOnTextParticleLightAndModelObjects) {
    const auto keyed = [](const char* key, std::array<float, 3> base) {
        return nlohmann::json {
            { "value", base },
            { "animation", {
                { "relative", true },
                { "options", { { "fps", 10 }, { "length", 10 }, { "mode", "single" } } },
                { "c0", nlohmann::json::array({
                    { { "frame", 0 }, { "value", 0 } }, { { "frame", 10 }, { "value", 1 } } }) }
            } }
        };
    };
    nlohmann::json animated_pose = {
        { "scale", keyed("scale", { 1, 2, 3 }) }, { "angles", keyed("angles", { 0.25f, 0.5f, 0.75f }) } };
    const auto expect_pose = [](const SceneNode& node, float shift, const char* label) {
        SCOPED_TRACE(label);
        EXPECT_NEAR(node.Scale().x(), 1.0f + shift, 1e-5);
        EXPECT_NEAR(node.Scale().y(), 2.0f, 1e-5);
        EXPECT_NEAR(node.Scale().z(), 3.0f, 1e-5);
        EXPECT_NEAR(node.Rotation().x(), 0.25f + shift, 1e-5);
        EXPECT_NEAR(node.Rotation().y(), 0.5f, 1e-5);
    };
    const auto object = [&](nlohmann::json base) {
        for (auto& [key, value] : animated_pose.items()) base[key] = value;
        return base.dump();
    };

    {
        fs::VFS vfs;
        MountSceneFiles(vfs);
        audio::SoundManager sound;
        auto scene = ParseOrthoShotScene(
            vfs, sound,
            object({ { "id", 21 }, { "name", "label" }, { "text", "hello" }, { "font", "Arial" },
                     { "visible", true } }) + "," +
            object({ { "id", 22 }, { "name", "sparks" }, { "particle", "particle.json" },
                     { "visible", true } }) + "," +
            object({ { "id", 23 }, { "name", "bulb" }, { "light", "point" }, { "radius", 100 },
                     { "intensity", 1 }, { "color", { 1, 1, 1 } }, { "visible", true } }));
        ASSERT_NE(scene, nullptr);
        auto& runtime = *scene->runtime;
        const auto text = FindRootChildByName(*scene, "label");
        ASSERT_NE(text, nullptr);
        const auto particles = FindRootChildByName(*scene, "sparks");
        ASSERT_NE(particles, nullptr);
        ASSERT_EQ(scene->lights.size(), 1u);
        ASSERT_NE(scene->lights[0]->node(), nullptr);
        const SceneNode* light = scene->lights[0]->node();
        expect_pose(*text, 0.0f, "text start");
        expect_pose(*particles, 0.0f, "particles start");
        expect_pose(*light, 0.0f, "light start");
        runtime.Tick(0.5);
        expect_pose(*text, 0.5f, "text mid");
        expect_pose(*particles, 0.5f, "particles mid");
        expect_pose(*light, 0.5f, "light mid");
        runtime.Tick(0.5);
        expect_pose(*text, 1.0f, "text end");
        expect_pose(*particles, 1.0f, "particles end");
        expect_pose(*light, 1.0f, "light end");
    }

    // A text or model object with children is first met as a group the
    // children hang from, then built as itself: its timeline plays once, on the
    // node the children stay under.
    {
        fs::VFS vfs;
        MountSceneFiles(vfs);
        audio::SoundManager sound;
        auto scene = ParseOrthoShotScene(
            vfs, sound,
            R"({"id":31,"name":"caption","text":"hello","font":"Arial","visible":true,
                "scale":{"value":[1,1,1],"animation":{"relative":true,
                  "options":{"fps":10,"length":10,"mode":"single"},
                  "c0":[{"frame":0,"value":0},{"frame":10,"value":1}]}}},
               {"id":32,"name":"underline","image":"image.json","parent":31,"origin":[5,6,0]})");
        ASSERT_NE(scene, nullptr);
        const auto caption = FindRootChildByName(*scene, "caption");
        ASSERT_NE(caption, nullptr);
        ASSERT_FALSE(caption->GetChildren().empty());
        auto* underline = caption->GetChildren().front().get();
        scene->runtime->Tick(0.5);
        EXPECT_NEAR(caption->Scale().x(), 1.5f, 1e-5);
        underline->UpdateTrans();
        EXPECT_NEAR(underline->ModelTrans()(0, 3) - caption->Translate().x(), 5.0f * 1.5f, 1e-4);
    }

    {
        auto files = std::map<std::string, std::string> {};
        AddLeafModelSceneFiles(files);
        fs::VFS vfs;
        EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
        audio::SoundManager sound;
        ProjectProperties   properties;
        auto scene = WPSceneParser().Parse(
            SceneParseRequest { .scene_id = "model-timeline", .project_properties = &properties },
            PerspectiveSceneJson("[" + object({ { "id", 7 }, { "name", "planet" },
                                                { "model", "planet.mdl" },
                                                { "perspective", true }, { "visible", true } }) +
                                 "]"),
            vfs, sound);
        ASSERT_NE(scene, nullptr);
        const auto model = FindRootChildByName(*scene, "planet");
        ASSERT_NE(model, nullptr);
        expect_pose(*model, 0.0f, "model start");
        scene->runtime->Tick(1.0);
        expect_pose(*model, 1.0f, "model end");
    }
}

// A looping timeline with `wraploop` (the editor's default for a loop) comes back
// to its first key by the end of the timeline's length: after its last key the
// value runs back, where without the flag it would hold the last key to the end
// and then jump. The same on origin and alpha, which share the curve reader.
TEST(SceneSchema, WrapLoopTimelinesReturnToTheirFirstKeyOnEveryAnimatedSetting) {
    for (const bool wrap : { false, true }) {
        SCOPED_TRACE(wrap ? "wraploop" : "plain loop");
        fs::VFS vfs;
        MountSceneFiles(vfs);
        audio::SoundManager sound;
        const auto timeline = [&](const char* base) {
            return std::string(R"({"value":)") + base + R"(,"animation":{"relative":false,
                "options":{"fps":10,"length":10,"mode":"loop","wraploop":)" +
                   (wrap ? "true" : "false") + R"(},
                "c0":[{"frame":0,"value":0},{"frame":5,"value":1}]}})";
        };
        auto scene = ParseOrthoShotScene(
            vfs, sound,
            R"({"id":21,"name":"sway","image":"image.json","scale":)" + timeline("[0,1,1]") +
                R"(,"origin":)" + timeline("[0,0,0]") + R"(})");
        ASSERT_NE(scene, nullptr);
        auto node = FindRootChildByName(*scene, "sway");
        ASSERT_NE(node, nullptr);
        auto& runtime = *scene->runtime;
        runtime.Tick(0.5);
        EXPECT_FLOAT_EQ(node->Scale().x(), 1.0f);
        runtime.Tick(0.25);
        // Frame 7.5 of 10: half way back, or still on the last key.
        EXPECT_FLOAT_EQ(node->Scale().x(), wrap ? 0.5f : 1.0f);
        EXPECT_FLOAT_EQ(node->Translate().x(), wrap ? 0.5f : 1.0f);
        runtime.Tick(0.25);
        EXPECT_FLOAT_EQ(node->Scale().x(), 0.0f);
    }
}

// The edge a layer is anchored to sits on its scaled size, so a scale that
// moves keeps the anchored edge where it is.
TEST(SceneSchema, ScaleTimelineKeepsAnAnchoredLayersEdgeOnItsScaledSize) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    audio::SoundManager sound;
    auto scene = ParseOrthoShotScene(vfs, sound, R"({
        "id":21,"name":"anchored card","image":"image.json","alignment":"left",
        "origin":[10,0,0],
        "scale":{"value":[1,1,1],"animation":{
            "options":{"fps":10,"length":10,"mode":"single"},
            "c0":[{"frame":0,"value":1},{"frame":10,"value":3}],
            "c1":[{"frame":0,"value":1},{"frame":10,"value":3}]
        }}
    })");
    ASSERT_NE(scene, nullptr);
    auto& runtime = *scene->runtime;
    auto node = FindRootChildByName(*scene, "anchored card");
    ASSERT_NE(node, nullptr);
    const float width = runtime.NodeSize("anchored card").x();
    EXPECT_FLOAT_EQ(node->Scale().x(), 1.0f);
    EXPECT_FLOAT_EQ(node->Translate().x(), 10.0f + width * 1.0f * 0.5f);
    runtime.Tick(1.0);
    EXPECT_FLOAT_EQ(node->Scale().x(), 3.0f);
    EXPECT_FLOAT_EQ(node->Translate().x(), 10.0f + width * 3.0f * 0.5f);
}

// A group's scale scales what it holds, and so does a drawn layer's that has
// children.
TEST(SceneSchema, ScaleTimelineScalesAParentsChildren) {
    for (bool group : { true, false }) {
        SCOPED_TRACE(group ? "group" : "image layer");
        fs::VFS vfs;
        MountSceneFiles(vfs);
        audio::SoundManager sound;
        auto parent = nlohmann::json::parse(R"({
            "id":21,"name":"growing parent",
            "scale":{"value":[1,1,1],"animation":{
                "relative":true,
                "options":{"fps":10,"length":10,"mode":"single"},
                "c0":[{"frame":0,"value":0},{"frame":10,"value":1}],
                "c1":[{"frame":0,"value":0},{"frame":10,"value":1}]
            }}
        })");
        if (!group) parent["image"] = "image.json";
        auto scene = ParseOrthoShotScene(vfs, sound, parent.dump() + R"(,
            {"id":22,"name":"child card","image":"image.json","parent":21,"origin":[5,6,0]}
        )");
        ASSERT_NE(scene, nullptr);
        auto& runtime = *scene->runtime;
        auto node = FindRootChildByName(*scene, "growing parent");
        ASSERT_NE(node, nullptr);
        ASSERT_EQ(node->GetChildren().size(), 1u);
        runtime.Tick(0.5);
        EXPECT_FLOAT_EQ(node->Scale().x(), 1.5f);
        node->GetChildren().front()->UpdateTrans();
        EXPECT_NEAR(node->GetChildren().front()->ModelTrans()(0, 3), 5.0f * 1.5f, 1e-4);
        runtime.Tick(0.5);
        EXPECT_FLOAT_EQ(node->Scale().x(), 2.0f);
        EXPECT_EQ(runtime.DescribeTimeAdvancingWork() & SceneDemandReason::Animation, 0u);
    }
}

// A layer colour keyed on a timeline tints the layer's own material and every
// effect pass as the playhead moves, and keeps the layer's alpha. Like any
// timeline it can start paused at its first colour and be played by name.
TEST(SceneSchema, ImageColourTimelineTintsEveryLayerMaterialAsItPlays) {
    fs::VFS vfs;
    MountTintableImageFiles(vfs);
    audio::SoundManager sound_manager(audio::SoundManager::OutputBackend::Null);
    ProjectProperties   properties;
    const auto keys = [](double first, double last) {
        return nlohmann::json::array({ { { "frame", 0 }, { "value", first } },
                                       { { "frame", 10 }, { "value", last } } });
    };
    const auto colour = [&](bool paused) {
        return nlohmann::json {
            { "value", "1 1 1" },
            { "animation", {
                { "options", { { "fps", 10 }, { "length", 10 }, { "mode", "single" },
                                 { "name", "tint" }, { "startpaused", paused } } },
                { "c0", keys(0.2, 1.0) }, { "c1", keys(0.4, 0.0) }, { "c2", keys(0.6, 0.6) }
            } }
        };
    };
    nlohmann::json scene_json = {
        { "camera", { { "center", { 0, 0, 0 } }, { "eye", { 0, 0, 1 } }, { "up", { 0, 1, 0 } } } },
        { "general", { { "ambientcolor", { 0.2, 0.2, 0.2 } }, { "skylightcolor", { 0.3, 0.3, 0.3 } },
                       { "clearcolor", { 0, 0, 0 } }, { "cameraparallax", false },
                       { "cameraparallaxamount", 0 }, { "cameraparallaxdelay", 0 },
                       { "cameraparallaxmouseinfluence", 0 },
                       { "orthogonalprojection", { { "width", 640 }, { "height", 360 } } } } },
        { "objects", nlohmann::json::array({
            { { "id", 1 }, { "name", "plain" }, { "image", "image.json" }, { "alpha", 0.5 },
              { "color", colour(false) }, { "visible", true } },
            { { "id", 2 }, { "name", "with effect" }, { "image", "image.json" }, { "alpha", 0.5 },
              { "color", colour(false) }, { "visible", true },
              { "effects", nlohmann::json::array({
                  { { "file", "effects/copy/effect.json" }, { "id", 3 }, { "visible", true } } }) } },
            { { "id", 4 }, { "name", "held" }, { "image", "image.json" }, { "alpha", 0.5 },
              { "color", colour(true) }, { "visible", true } } }) }
    };
    auto parsed = WPSceneParser().Parse(SceneParseRequest {
                                            .scene_id           = "image-colour-timeline",
                                            .project_properties = &properties,
                                        },
                                        scene_json.dump(),
                                        vfs,
                                        sound_manager);
    ASSERT_NE(parsed, nullptr);
    ASSERT_NE(parsed->runtime, nullptr);
    auto& runtime = *parsed->runtime;

    const auto expect_colour = [&](std::string_view name, std::array<float, 3> rgb,
                                   std::size_t expected_materials) {
        SCOPED_TRACE(std::string(name));
        const auto materials = LayerMaterials(*parsed, name);
        ASSERT_EQ(materials.size(), expected_materials);
        for (const auto* material : materials) {
            const auto& values = material->customShader.constValues;
            ASSERT_TRUE(values.contains("g_Color4"));
            ASSERT_TRUE(values.contains("g_Color"));
            for (std::size_t index = 0; index < 3; ++index) {
                EXPECT_FLOAT_EQ(values.at("g_Color4")[index], rgb[index]);
                EXPECT_FLOAT_EQ(values.at("g_Color")[index], rgb[index]);
            }
            EXPECT_FLOAT_EQ(values.at("g_Color4")[3], 0.5f);
        }
    };

    // The first colour is the layer's colour from the first frame.
    expect_colour("plain", { 0.2f, 0.4f, 0.6f }, 1u);
    expect_colour("with effect", { 0.2f, 0.4f, 0.6f }, 2u);
    expect_colour("held", { 0.2f, 0.4f, 0.6f }, 1u);
    EXPECT_NE(runtime.DescribeTimeAdvancingWork() & SceneDemandReason::Animation, 0u);

    runtime.Tick(0.5);
    expect_colour("plain", { 0.6f, 0.2f, 0.6f }, 1u);
    expect_colour("with effect", { 0.6f, 0.2f, 0.6f }, 2u);
    expect_colour("held", { 0.2f, 0.4f, 0.6f }, 1u);
    runtime.Tick(0.5);
    expect_colour("plain", { 1.0f, 0.0f, 0.6f }, 1u);
    expect_colour("with effect", { 1.0f, 0.0f, 0.6f }, 2u);
    expect_colour("held", { 0.2f, 0.4f, 0.6f }, 1u);

    auto* clock = runtime.FindScalarAnimation("held", "tint");
    ASSERT_NE(clock, nullptr);
    clock->Play();
    runtime.Tick(0.5);
    expect_colour("held", { 0.6f, 0.2f, 0.6f }, 1u);
    runtime.Tick(0.5);
    expect_colour("held", { 1.0f, 0.0f, 0.6f }, 1u);
    EXPECT_EQ(runtime.DescribeTimeAdvancingWork() & SceneDemandReason::Animation, 0u);
    EXPECT_EQ(runtime.scriptErrorCount(), 0u);
}

// The three sources of an image layer's colour agree on one rule: a script or
// a user property is the colour's only writer, a timeline plays where there is
// neither, and wherever the scene renders HDR the layer's brightness multiplies
// whichever colour applies into `g_Color4` of every material (the `g_Color` a
// shader reads for the plain colour stays the colour).
TEST(SceneSchema, ImageColourSourcesKeepTheirPrecedenceAndTheHdrBrightnessMultipliesEach) {
    fs::VFS vfs;
    MountTintableImageFiles(vfs, true);
    audio::SoundManager sound_manager(audio::SoundManager::OutputBackend::Null);
    ProjectProperties   properties { { "tint", RuntimeScalarValue::String("0 0 1") } };
    const auto timeline = [](const char* name) {
        return nlohmann::json {
            { "options", { { "fps", 10 }, { "length", 10 }, { "mode", "single" }, { "name", name } } },
            { "c0", nlohmann::json::array({ { { "frame", 0 }, { "value", 0.2 } },
                                            { { "frame", 10 }, { "value", 1.0 } } }) },
            { "c1", nlohmann::json::array({ { { "frame", 0 }, { "value", 0.4 } },
                                            { { "frame", 10 }, { "value", 0.0 } } }) },
            { "c2", nlohmann::json::array({ { { "frame", 0 }, { "value", 0.6 } },
                                            { { "frame", 10 }, { "value", 0.6 } } }) }
        };
    };
    const auto layer = [&](int id, const char* name, nlohmann::json colour, bool effect) {
        nlohmann::json object = {
            { "id", id }, { "name", name }, { "image", "image.json" }, { "alpha", 0.5 },
            { "brightness", 0.5 }, { "color", std::move(colour) }, { "visible", true } };
        if (effect) object["effects"] = nlohmann::json::array(
            { { { "file", "effects/copy/effect.json" }, { "id", id + 100 }, { "visible", true } } });
        return object;
    };
    const auto keyed = [&](const char* name) {
        return nlohmann::json { { "value", "1 1 1" }, { "animation", timeline(name) } };
    };
    auto scripted = keyed("script clock");
    scripted["script"] = "export function update(value) { return new Vec3(0, 1, 0); }";
    auto bound = keyed("property clock");
    bound["user"] = "tint";
    nlohmann::json scene_json = {
        { "camera", { { "center", { 0, 0, 0 } }, { "eye", { 0, 0, 1 } }, { "up", { 0, 1, 0 } } } },
        { "general", { { "ambientcolor", { 0.2, 0.2, 0.2 } }, { "skylightcolor", { 0.3, 0.3, 0.3 } },
                       { "clearcolor", { 0, 0, 0 } }, { "cameraparallax", false },
                       { "cameraparallaxamount", 0 }, { "cameraparallaxdelay", 0 },
                       { "cameraparallaxmouseinfluence", 0 }, { "hdr", true }, { "bloom", true },
                       { "orthogonalprojection", { { "width", 640 }, { "height", 360 } } } } },
        { "objects", nlohmann::json::array({
            layer(1, "keyed", keyed("keyed clock"), true),
            layer(2, "scripted", scripted, true),
            layer(3, "bound", bound, true) }) }
    };
    auto parsed = WPSceneParser().Parse(SceneParseRequest {
                                            .scene_id           = "image-colour-sources",
                                            .project_properties = &properties,
                                        },
                                        scene_json.dump(),
                                        vfs,
                                        sound_manager);
    ASSERT_NE(parsed, nullptr);
    ASSERT_NE(parsed->runtime, nullptr);
    ASSERT_TRUE(parsed->hdr);
    auto& runtime = *parsed->runtime;

    const auto expect_colour = [&](std::string_view name, std::array<float, 3> rgb) {
        SCOPED_TRACE(std::string(name));
        const auto materials = LayerMaterials(*parsed, name);
        ASSERT_EQ(materials.size(), 2u);
        for (const auto* material : materials) {
            const auto& values = material->customShader.constValues;
            for (std::size_t index = 0; index < 3; ++index) {
                EXPECT_FLOAT_EQ(values.at("g_Color4")[index], rgb[index] * 0.5f);
                EXPECT_FLOAT_EQ(values.at("g_Color")[index], rgb[index]);
            }
            EXPECT_FLOAT_EQ(values.at("g_Color4")[3], 0.5f);
        }
    };

    expect_colour("keyed", { 0.2f, 0.4f, 0.6f });
    expect_colour("bound", { 0.0f, 0.0f, 1.0f });
    runtime.Tick(0.5);
    // The timeline plays on the layer that has no binding, brightness applied
    // to each frame's colour; a script or a property has no clock beside it.
    expect_colour("keyed", { 0.6f, 0.2f, 0.6f });
    expect_colour("scripted", { 0.0f, 1.0f, 0.0f });
    expect_colour("bound", { 0.0f, 0.0f, 1.0f });
    EXPECT_NE(runtime.FindScalarAnimation("keyed", "keyed clock"), nullptr);
    EXPECT_EQ(runtime.FindScalarAnimation("scripted", "script clock"), nullptr);
    EXPECT_EQ(runtime.FindScalarAnimation("bound", "property clock"), nullptr);

    runtime.ApplyProjectPropertyOverride({ { "tint", RuntimeScalarValue::String("0.25 0.5 0.75") } });
    runtime.Tick(0.5);
    expect_colour("keyed", { 1.0f, 0.0f, 0.6f });
    expect_colour("bound", { 0.25f, 0.5f, 0.75f });
    EXPECT_EQ(runtime.scriptErrorCount(), 0u);
}

TEST(SceneSchema, ImageAlignmentAnchorSurvivesScriptedOriginAndScale) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    audio::SoundManager sound;
    WPSceneParser        parser;
    const nlohmann::json source = {
        { "camera", { { "center", { 0, 0, 0 } }, { "eye", { 0, 0, 1 } }, { "up", { 0, 1, 0 } } } },
        { "general",
          { { "ambientcolor", { 0, 0, 0 } },
            { "skylightcolor", { 0, 0, 0 } },
            { "clearcolor", { 0, 0, 0 } },
            { "cameraparallax", false },
            { "orthogonalprojection", { { "width", 400 }, { "height", 300 } } } } },
        { "objects",
          nlohmann::json::array(
              { { { "id", 21 },
                  { "name", "scripted origin" },
                  { "image", "image.json" },
                  { "alignment", "bottom" },
                  { "size", { 200, 100 } },
                  { "visible", true },
                  { "origin",
                    { { "value", { 50, 0, 0 } },
                      { "script", "export function update(value) { return value; }" } } } },
                { { "id", 22 },
                  { "name", "scaled anchor" },
                  { "image", "image.json" },
                  { "alignment", "left" },
                  { "size", { 100, 100 } },
                  { "scale", { 2, 2, 1 } },
                  { "visible", true },
                  { "origin", { 10, 0, 0 } } },
                { { "id", 23 },
                  { "name", "scripted scale anchor" },
                  { "image", "image.json" },
                  { "alignment", "left" },
                  { "size", { 100, 100 } },
                  { "visible", true },
                  { "origin", { 10, 0, 0 } },
                  { "scale",
                    { { "value", { 2, 2, 1 } },
                      { "script",
                        "export function update() { return new Vec3(0.5, 0.5, 1); }" } } } } }) }
    };
    ProjectProperties properties;
    auto              scene = parser.Parse(SceneParseRequest {
                                  .scene_id           = "image-alignment-anchor",
                                  .project_properties = &properties,
                              },
                              source.dump(),
                              vfs,
                              sound);
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto& runtime = *scene->runtime;

    // The layer size comes from the mounted image, so express the anchor offset
    // in terms of the registered size instead of fixture constants.
    const auto scripted_size = runtime.NodeSize("scripted origin");
    const auto scaled_size   = runtime.NodeSize("scaled anchor");

    // A scripted origin replaces the translate every tick, so the anchor offset
    // has to be re-derived instead of being baked in once at parse time.
    auto scripted = FindRootChildByName(*scene, "scripted origin");
    ASSERT_NE(scripted, nullptr);
    EXPECT_FLOAT_EQ(scripted->Translate().y(), scripted_size.y() * 0.5f);
    runtime.Tick(0.01);
    EXPECT_FLOAT_EQ(scripted->Translate().x(), 50.0f);
    EXPECT_FLOAT_EQ(scripted->Translate().y(), scripted_size.y() * 0.5f);

    // The anchor sits on the scaled edge, so scale participates in the offset.
    auto scaled = FindRootChildByName(*scene, "scaled anchor");
    ASSERT_NE(scaled, nullptr);
    EXPECT_FLOAT_EQ(scaled->Translate().x(), 10.0f + scaled_size.x() * 2.0f * 0.5f);

    // Every Register* helper re-registers the node; the anchor origin must stay
    // the authored origin so a scripted scale replaces the offset, never stacks
    // a second one on top of it.
    const auto scripted_scale_size = runtime.NodeSize("scripted scale anchor");
    auto       scripted_scale      = FindRootChildByName(*scene, "scripted scale anchor");
    ASSERT_NE(scripted_scale, nullptr);
    EXPECT_FLOAT_EQ(scripted_scale->Scale().x(), 0.5f);
    EXPECT_FLOAT_EQ(scripted_scale->Translate().x(),
                    10.0f + scripted_scale_size.x() * 0.5f * 0.5f);
    runtime.Tick(0.01);
    EXPECT_FLOAT_EQ(scripted_scale->Translate().x(),
                    10.0f + scripted_scale_size.x() * 0.5f * 0.5f);
    EXPECT_EQ(runtime.scriptErrorCount(), 0u);
}

TEST(SceneSchema, DuplicateParsedImageClickScriptsGateRealAssetSoundLayers) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    // The parse mounts these sound layers, and a mount opens the output device
    // on the system backend even though nothing plays.
    audio::SoundManager sound_manager(audio::SoundManager::OutputBackend::Null);
    WPSceneParser       parser;
    ProjectProperties   properties {
          { "click_count", RuntimeScalarValue::String("2") },
    };
    SceneParseRequest request {
        .scene_id           = "duplicate-click-script-sounds",
        .project_properties = &properties,
    };

    const auto click_script = R"JS(
'use strict';
export var scriptProperties = createScriptProperties()
  .addText({ name: 'count1', label: 'Count1', value: '1' })
  .addText({ name: 'voice1', label: 'Voice1', value: 'Voice1' })
  .addText({ name: 'count2', label: 'Count2', value: '2' })
  .addText({ name: 'voice2', label: 'Voice2', value: 'Voice2' })
  .addText({ name: 'waitingtime', label: 'Waitingtime', value: '1.0' })
  .finish();
var count = 0;
var waitingtime = 0;
export function cursorClick() {
  waitingtime = 0;
  count++;
  if (count == scriptProperties.count1)
    thisScene.getLayer(scriptProperties.voice1).play();
  if (count == scriptProperties.count2)
    thisScene.getLayer(scriptProperties.voice2).play();
}
export function update(value) {
  if (count != 0) waitingtime += engine.frametime;
  if (waitingtime > scriptProperties.waitingtime) {
    waitingtime = 0;
    count = 0;
  }
}
)JS";
    const auto script_setting = [&](std::string_view sound_name) {
        return nlohmann::json {
            { "value", true },
            { "script", click_script },
            { "scriptproperties",
              nlohmann::json {
                  { "count1",
                    nlohmann::json {
                        { "user", "click_count" },
                        { "value",
                          nlohmann::json {
                              { "user", "unused_default" },
                              { "value", "2" },
                          } },
                    } },
                  { "count2", "200" },
                  { "voice1", std::string(sound_name) },
                  { "voice2", "Voice2" },
                  { "waitingtime", "1.0" },
              } },
        };
    };

    nlohmann::json scene_json = {
        { "camera", { { "center", { 0, 0, 0 } }, { "eye", { 0, 0, 1 } }, { "up", { 0, 1, 0 } } } },
        { "general",
          {
              { "ambientcolor", { 0, 0, 0 } },
              { "skylightcolor", { 0, 0, 0 } },
              { "clearcolor", { 0, 0, 0 } },
              { "cameraparallax", false },
              { "cameraparallaxamount", 0 },
              { "cameraparallaxdelay", 0 },
              { "cameraparallaxmouseinfluence", 0 },
              { "orthogonalprojection", { { "width", 400 }, { "height", 300 } } },
          } },
        { "objects",
          nlohmann::json::array(
              { {
                    { "id", 43 },
                    { "name", "tap target" },
                    { "image", "image.json" },
                    { "origin", { 100, 150, 0 } },
                    { "size", { 80, 80 } },
                    { "visible", script_setting("headAudio") },
                },
                {
                    { "id", 59 },
                    { "name", "tap target" },
                    { "image", "image.json" },
                    { "origin", { 200, 150, 0 } },
                    { "size", { 80, 80 } },
                    { "visible", script_setting("bodyAudio") },
                },
                {
                    { "id", 62 },
                    { "name", "tap target" },
                    { "image", "image.json" },
                    { "origin", { 300, 150, 0 } },
                    { "size", { 80, 80 } },
                    { "visible", script_setting("legAudio") },
                },
                {
                    { "id", 74 },
                    { "name", "bodyAudio" },
                    { "sound", nlohmann::json::array({ "sounds/body.wav" }) },
                    { "playbackmode", "single" },
                    { "startsilent", true },
                },
                {
                    { "id", 75 },
                    { "name", "headAudio" },
                    { "sound", nlohmann::json::array({ "sounds/head.wav" }) },
                    { "playbackmode", "single" },
                    { "startsilent", true },
                },
                {
                    { "id", 77 },
                    { "name", "legAudio" },
                    { "sound", nlohmann::json::array({ "sounds/leg.wav" }) },
                    { "playbackmode", "single" },
                    { "startsilent", true },
                },
                {
                    { "id", 69 },
                    { "name", "backgroundAudio" },
                    { "sound", nlohmann::json::array({ "sounds/background.wav" }) },
                    { "playbackmode", "loop" },
                    { "startsilent", false },
                } }) },
    };

    auto scene = parser.Parse(request, scene_json.dump(), vfs, sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    EXPECT_TRUE(scene->runtime->SoundLayerPlaying("backgroundAudio"));
    EXPECT_FALSE(scene->runtime->SoundLayerPlaying("headAudio"));
    EXPECT_FALSE(scene->runtime->SoundLayerPlaying("bodyAudio"));
    EXPECT_FALSE(scene->runtime->SoundLayerPlaying("legAudio"));

    scene->runtime->SetCursorInput(0.5f, 0.5f);
    scene->runtime->SetCursorEnter(true);
    bool cursor_was_in_window = scene->runtime->DispatchCursorFrameEvents(false);
    scene->runtime->Tick(1.0 / 60.0);

    EXPECT_TRUE(cursor_was_in_window);
    EXPECT_FALSE(scene->runtime->SoundLayerPlaying("headAudio"));
    EXPECT_FALSE(scene->runtime->SoundLayerPlaying("bodyAudio"));
    EXPECT_FALSE(scene->runtime->SoundLayerPlaying("legAudio"));

    scene->runtime->SetCursorButtons(0u, 1u, 0u);
    cursor_was_in_window = scene->runtime->DispatchCursorFrameEvents(cursor_was_in_window);
    scene->runtime->Tick(1.0 / 60.0);

    EXPECT_TRUE(cursor_was_in_window);
    EXPECT_FALSE(scene->runtime->SoundLayerPlaying("headAudio"));
    EXPECT_FALSE(scene->runtime->SoundLayerPlaying("bodyAudio"));
    EXPECT_FALSE(scene->runtime->SoundLayerPlaying("legAudio"));

    scene->runtime->SetCursorButtons(0u, 0u, 0u);
    cursor_was_in_window = scene->runtime->DispatchCursorFrameEvents(cursor_was_in_window);
    scene->runtime->Tick(1.0 / 60.0);
    scene->runtime->SetCursorButtons(0u, 1u, 0u);
    cursor_was_in_window = scene->runtime->DispatchCursorFrameEvents(cursor_was_in_window);
    scene->runtime->Tick(1.0 / 60.0);

    EXPECT_TRUE(cursor_was_in_window);
    EXPECT_FALSE(scene->runtime->SoundLayerPlaying("headAudio"));
    EXPECT_TRUE(scene->runtime->SoundLayerPlaying("bodyAudio"));
    EXPECT_FALSE(scene->runtime->SoundLayerPlaying("legAudio"));
    EXPECT_EQ(scene->runtime->scriptErrorCount(), 0u);
}

TEST(SceneSchema, ParserBuildsLdrBloomPostProcessWhenBloomEnabledWithoutHdr) {
    fs::VFS vfs;
    MountBloomSceneFiles(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;

    auto parsed = parser.Parse("ldr-bloom", BloomSceneJson(false), vfs, sound_manager);
    ASSERT_NE(parsed, nullptr);

    ASSERT_EQ(parsed->post_processes.size(), 1u);
    ASSERT_NE(parsed->post_processes[0], nullptr);
    const auto& bloom = *parsed->post_processes[0];
    EXPECT_EQ(bloom.name, "__bloom");
    ASSERT_EQ(bloom.steps.size(), 5u);

    const auto* pass0 = PostProcessPassAt(bloom, 0);
    const auto* pass1 = PostProcessPassAt(bloom, 1);
    const auto* pass2 = PostProcessPassAt(bloom, 2);
    const auto* pass3 = PostProcessPassAt(bloom, 3);
    const auto* copy  = PostProcessCopyAt(bloom, 4);
    ASSERT_NE(pass0, nullptr);
    ASSERT_NE(pass1, nullptr);
    ASSERT_NE(pass2, nullptr);
    ASSERT_NE(pass3, nullptr);
    ASSERT_NE(copy, nullptr);
    EXPECT_EQ(pass0->output, "_rt_bloom_mip1");
    EXPECT_EQ(pass1->output, "_rt_bloom_mip2");
    EXPECT_EQ(pass2->output, "_rt_bloom_blur");
    EXPECT_EQ(pass3->output, "_rt_bloom_combine");
    EXPECT_EQ(copy->src, "_rt_bloom_combine");
    EXPECT_EQ(copy->dst, SpecTex_Default);

    ASSERT_NE(pass0->node, nullptr);
    ASSERT_NE(pass1->node, nullptr);
    ASSERT_NE(pass2->node, nullptr);
    ASSERT_NE(pass3->node, nullptr);
    ASSERT_NE(pass0->node->Mesh(), nullptr);
    ASSERT_NE(pass0->node->Mesh()->Material(), nullptr);
    const auto& constants = pass0->node->Mesh()->Material()->customShader.constValues;
    ASSERT_TRUE(constants.contains("g_BloomStrength"));
    ASSERT_TRUE(constants.contains("g_BloomThreshold"));
    ASSERT_TRUE(constants.contains("g_BloomTint"));
    EXPECT_FLOAT_EQ(constants.at("g_BloomStrength")[0], 1.5f);
    EXPECT_FLOAT_EQ(constants.at("g_BloomThreshold")[0], 0.25f);
    EXPECT_FLOAT_EQ(constants.at("g_BloomTint")[0], 0.2f);
    EXPECT_FLOAT_EQ(constants.at("g_BloomTint")[1], 0.4f);
    EXPECT_FLOAT_EQ(constants.at("g_BloomTint")[2], 0.6f);

    ExpectTextureResolution(*pass1, 160, 90);
    ExpectTextureResolution(*pass2, 80, 45);
    ExpectTextureResolution(*pass3, 640, 360);

    const auto* default_rt = parsed->FindRenderTarget(SpecTex_Default);
    const auto* mip1_rt    = parsed->FindRenderTarget("_rt_bloom_mip1");
    const auto* mip2_rt    = parsed->FindRenderTarget("_rt_bloom_mip2");
    const auto* combine_rt = parsed->FindRenderTarget("_rt_bloom_combine");
    ASSERT_NE(default_rt, nullptr);
    ASSERT_NE(mip1_rt, nullptr);
    ASSERT_NE(mip2_rt, nullptr);
    ASSERT_NE(combine_rt, nullptr);
    EXPECT_EQ(default_rt->format, TextureFormat::RGBA8);
    EXPECT_EQ(mip1_rt->format, TextureFormat::RGBA8);
    EXPECT_EQ(mip2_rt->format, TextureFormat::RGBA8);
    EXPECT_EQ(combine_rt->format, TextureFormat::RGBA8);
    EXPECT_TRUE(default_rt->bind.enable);
    EXPECT_TRUE(default_rt->bind.screen);
    EXPECT_EQ(default_rt->width, 640);
    EXPECT_EQ(default_rt->height, 360);
    EXPECT_TRUE(mip1_rt->bind.enable);
    EXPECT_TRUE(mip1_rt->bind.screen);
    EXPECT_DOUBLE_EQ(mip1_rt->bind.scale, 0.25);
    EXPECT_EQ(mip1_rt->width, 160);
    EXPECT_EQ(mip1_rt->height, 90);
    EXPECT_TRUE(mip2_rt->bind.enable);
    EXPECT_TRUE(mip2_rt->bind.screen);
    EXPECT_DOUBLE_EQ(mip2_rt->bind.scale, 0.125);
    EXPECT_EQ(mip2_rt->width, 80);
    EXPECT_EQ(mip2_rt->height, 45);
    // The horizontal blur writes an eighth-size image of its own, as Wallpaper
    // Engine's does, and the combine reads it.
    const auto* blur_rt = parsed->FindRenderTarget("_rt_bloom_blur");
    ASSERT_NE(blur_rt, nullptr);
    EXPECT_DOUBLE_EQ(blur_rt->bind.scale, 0.125);
    EXPECT_EQ(blur_rt->width, 80);
    ASSERT_GE(pass3->node->Mesh()->Material()->textures.size(), 2u);
    EXPECT_EQ(pass3->node->Mesh()->Material()->textures[1], "_rt_bloom_blur");
    EXPECT_TRUE(combine_rt->bind.enable);
    EXPECT_TRUE(combine_rt->bind.screen);
    EXPECT_DOUBLE_EQ(combine_rt->bind.scale, 1.0);
    EXPECT_EQ(combine_rt->width, 640);
    EXPECT_EQ(combine_rt->height, 360);
}

// Wallpaper Engine binds the scene's own settings to user properties like any
// other: the property's value is the setting's. Bloom on or off and which
// layers follow the cursor shape the scene, so they are read when it loads and
// a change reloads it; strength, threshold, tint, parallax delay and zoom
// follow the property while the scene runs.
TEST(SceneSchema, SceneSettingsBoundToUserPropertiesFollowThem) {
    fs::VFS vfs;
    MountBloomSceneFiles(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    const std::string json = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "clearcolor":[0,0,0],
        "bloom":{"user":"glow","value":false},
        "bloomstrength":{"user":"glowstrength","value":1.0}, "bloomthreshold":0.25,
        "bloomtint":{"user":"glowtint","value":"1 1 1"},
        "cameraparallax":{"user":"parallax","value":false},
        "cameraparallaxamount":{"user":"depth","value":0.2},
        "cameraparallaxdelay":{"user":"lag","value":0.5},
        "zoom":{"user":"lens","value":1.0},
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": []
    })";
    const ProjectProperties properties {
        { "glow", RuntimeScalarValue::Bool(true) },
        { "glowstrength", RuntimeScalarValue::Float(3.0f) },
        { "glowtint", RuntimeScalarValue::String("0.5 0.25 1") },
        { "parallax", RuntimeScalarValue::Bool(true) },
        { "depth", RuntimeScalarValue::Float(0.8f) },
        { "lag", RuntimeScalarValue::Float(1.5f) },
        { "lens", RuntimeScalarValue::Float(2.0f) },
    };
    auto scene = parser.Parse(
        SceneParseRequest { .scene_id = "bound-general", .project_properties = &properties }, json,
        vfs, sound_manager);
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto& runtime = *scene->runtime;

    // Read when the scene loads.
    ASSERT_EQ(scene->post_processes.size(), 1u) << "the saved bloom choice was ignored";
    const auto& parallax =
        static_cast<WPShaderValueUpdater&>(*scene->shaderValueUpdater).CameraParallax();
    EXPECT_TRUE(parallax.enable);
    EXPECT_FLOAT_EQ(parallax.amount, 0.8f);
    const auto load_only = runtime.LoadOnlyProperties();
    for (const char* name : { "glow", "parallax", "depth" }) {
        EXPECT_NE(std::find(load_only.begin(), load_only.end(), name), load_only.end()) << name;
    }

    // Followed while the scene runs.
    const auto* extract = PostProcessPassAt(*scene->post_processes[0], 0);
    ASSERT_NE(extract, nullptr);
    const auto& constants = extract->node->Mesh()->Material()->customShader.constValues;
    EXPECT_FLOAT_EQ(constants.at("g_BloomStrength")[0], 3.0f);
    EXPECT_FLOAT_EQ(constants.at("g_BloomTint")[1], 0.25f);
    EXPECT_FLOAT_EQ(parallax.delay, 1.5f);
    EXPECT_DOUBLE_EQ(scene->cameras.at("global")->Width(), 320.0);
    runtime.ApplyProjectPropertyOverride({
        { "glowstrength", RuntimeScalarValue::Float(0.5f) },
        { "glowtint", RuntimeScalarValue::String("1 0 0") },
        { "lag", RuntimeScalarValue::Float(0.25f) },
        { "lens", RuntimeScalarValue::Float(4.0f) },
    });
    EXPECT_FLOAT_EQ(constants.at("g_BloomStrength")[0], 0.5f);
    EXPECT_FLOAT_EQ(constants.at("g_BloomTint")[1], 0.0f);
    EXPECT_FLOAT_EQ(static_cast<WPShaderValueUpdater&>(*scene->shaderValueUpdater)
                        .CameraParallax().delay, 0.25f);
    EXPECT_DOUBLE_EQ(scene->cameras.at("global")->Width(), 160.0);
}

// A scene that switches parallax or HDR bloom on and leaves their settings out
// gets Wallpaper Engine's defaults.
TEST(SceneSchema, SceneSettingsLeftOutTakeWallpaperEnginesDefaults) {
    wpscene::WPScene sc;
    sc.FromJson(nlohmann::json::parse(R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {"cameraparallax":true, "orthogonalprojection":{"width":640,"height":360}}
    })"));
    EXPECT_TRUE(sc.general.cameraparallax);
    EXPECT_FLOAT_EQ(sc.general.cameraparallaxamount, 0.5f);
    EXPECT_FLOAT_EQ(sc.general.cameraparallaxdelay, 0.1f);
    EXPECT_FLOAT_EQ(sc.general.cameraparallaxmouseinfluence, 0.5f);
    // The ambient and sky light are black.
    for (int i = 0; i < 3; ++i) {
        EXPECT_FLOAT_EQ(sc.general.ambientcolor[i], 0.0f);
        EXPECT_FLOAT_EQ(sc.general.skylightcolor[i], 0.0f);
    }
    // And the HDR bloom keys, likewise.
    EXPECT_FLOAT_EQ(sc.general.bloomhdrstrength, 2.0f);
    EXPECT_FLOAT_EQ(sc.general.bloomhdrthreshold, 1.0f);
    EXPECT_FLOAT_EQ(sc.general.bloomhdrfeather, 0.1f);
    EXPECT_FLOAT_EQ(sc.general.bloomhdrscatter, 1.619f);
    EXPECT_EQ(sc.general.bloomhdriterations, 8);
}

// Wallpaper Engine's HDR bloom: as many half-size levels as the frame allows,
// at most eight and at most the scene's iterations; extraction and
// downsampling read a texel either side, upsampling half of one, the two
// coarsest levels bicubically; the scatter weighs each upsampled level as it
// is, and the extraction strength is divided by one more than the scatter
// raised to the levels past the second.
TEST(SceneSchema, HdrBloomBuildsWallpaperEnginesLevelsAndWeights) {
    std::map<std::string, std::string> files;
    AddHdrBloomFixtureFiles(files);
    fs::VFS vfs;
    ASSERT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager { audio::SoundManager::OutputBackend::Null };
    WPSceneParser       parser;
    const auto scene_json = [](int iterations) {
        return std::string(R"({
          "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
          "general": {"clearcolor":[0,0,0], "bloom":true, "hdr":true,
            "bloomhdrstrength":3.0, "bloomhdrscatter":2.0, "bloomhdrthreshold":1.0,
            "bloomhdrfeather":0.1, "bloomhdriterations":)") + std::to_string(iterations) + R"(,
            "orthogonalprojection":{"width":640,"height":360}},
          "objects": []
        })";
    };

    // Twelve asked for; a 360-pixel side allows eight.
    auto deep = parser.Parse("hdr-bloom-deep", scene_json(12), vfs, sound_manager);
    ASSERT_NE(deep, nullptr);
    ASSERT_EQ(deep->post_processes.size(), 1u);
    EXPECT_NE(deep->FindRenderTarget("_rt_hdr_bloom_7"), nullptr);
    EXPECT_EQ(deep->FindRenderTarget("_rt_hdr_bloom_8"), nullptr);
    const auto& steps = deep->post_processes[0]->steps;
    ASSERT_EQ(steps.size(), 1u + 7u + 7u + 1u + 1u);
    const auto pass = [&steps](std::size_t index) {
        const auto* step = std::get_if<ScenePostProcessPass>(&steps.at(index));
        EXPECT_NE(step, nullptr);
        return step;
    };
    const auto material = [&pass](std::size_t index) {
        return pass(index)->node->Mesh()->Material();
    };
    EXPECT_FLOAT_EQ(material(0)->customShader.constValues.at("g_BloomStrength")[0],
                    3.0f / (std::pow(2.0f, 6.0f) + 1.0f));
    EXPECT_FLOAT_EQ(pass(0)->source_texel_radius, 1.0f);
    for (std::size_t i = 1; i <= 7; ++i) EXPECT_FLOAT_EQ(pass(i)->source_texel_radius, 1.0f);
    for (std::size_t i = 8; i <= 14; ++i) {
        SCOPED_TRACE(i);
        EXPECT_FLOAT_EQ(pass(i)->source_texel_radius, 0.5f);
        EXPECT_FLOAT_EQ(material(i)->customShader.constValues.at("g_BloomScatter")[0], 2.0f);
        // The first two upsamples read the two coarsest levels.
        EXPECT_EQ(material(i)->name, i <= 9 ? "hdr_cubic" : "hdr_up");
    }
    EXPECT_FLOAT_EQ(pass(15)->source_texel_radius, 0.0f);

    // Three levels: both upsamples are of the two coarsest.
    auto shallow = parser.Parse("hdr-bloom-shallow", scene_json(3), vfs, sound_manager);
    ASSERT_NE(shallow, nullptr);
    const auto& shallow_steps = shallow->post_processes.at(0)->steps;
    ASSERT_EQ(shallow_steps.size(), 1u + 2u + 2u + 1u + 1u);
    for (std::size_t i : { 3u, 4u }) {
        EXPECT_EQ(std::get<ScenePostProcessPass>(shallow_steps[i]).node->Mesh()->Material()->name,
                  "hdr_cubic");
    }
}

// Wallpaper Engine's HDR pipeline needs the scene's bloom as well as its
// `hdr`: an HDR scene with bloom off is drawn with ordinary 8-bit targets.
TEST(SceneSchema, AnHdrSceneWithoutBloomRendersAsAnOrdinaryOne) {
    std::map<std::string, std::string> files;
    AddHdrBloomFixtureFiles(files);
    fs::VFS vfs;
    ASSERT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager { audio::SoundManager::OutputBackend::Null };
    WPSceneParser       parser;
    for (const bool bloom : { false, true }) {
        SCOPED_TRACE(bloom);
        auto scene = parser.Parse(
            bloom ? "hdr-with-bloom" : "hdr-without-bloom",
            std::string(R"({"camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
              "general": {"clearcolor":[0,0,0], "hdr":true, "bloom":)") +
                (bloom ? "true" : "false") +
                R"(, "orthogonalprojection":{"width":640,"height":360}}, "objects": []})",
            vfs, sound_manager);
        ASSERT_NE(scene, nullptr);
        EXPECT_EQ(scene->hdr, bloom);
        EXPECT_EQ(scene->FindRenderTarget(SpecTex_Default)->format,
                  bloom ? TextureFormat::RGBA16F : TextureFormat::RGBA8);
    }
}

TEST(SceneSchema, HdrBloomRejectsMissingHdrMaterialsRatherThanFallingBackToLdr) {
    fs::VFS vfs;
    MountBloomSceneFiles(vfs);
    audio::SoundManager sound_manager { audio::SoundManager::OutputBackend::Null };
    WPSceneParser parser;

    // A complete LDR pipeline cannot stand in for a missing HDR dependency:
    // doing so clips the scene before extracting its overbright contribution.
    EXPECT_THROW(parser.Parse("missing-hdr-bloom", BloomSceneJson(true), vfs, sound_manager),
                 std::runtime_error);
}

TEST(SceneSchema, ParserDoesNotCommitPartialBloomStateWhenMaterialLoadFails) {
    fs::VFS vfs;
    MountBrokenBloomSceneFiles(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;

    auto parsed = parser.Parse("broken-ldr-bloom", BloomSceneJson(false), vfs, sound_manager);
    ASSERT_NE(parsed, nullptr);
    EXPECT_TRUE(parsed->post_processes.empty());
    EXPECT_EQ(parsed->FindRenderTarget("_rt_bloom_mip1"), nullptr);
    EXPECT_EQ(parsed->FindRenderTarget("_rt_bloom_mip2"), nullptr);
    EXPECT_EQ(parsed->FindRenderTarget("_rt_bloom_blur"), nullptr);
    EXPECT_EQ(parsed->FindRenderTarget("_rt_bloom_combine"), nullptr);
}

TEST(SceneSchema, ParserLoadsPuppetMeshMaterialSlotsFromPerMeshMaterialFiles) {
    auto files = std::map<std::string, std::string> {};
    AddPuppetImageSceneFiles(files);
    fs::VFS vfs;
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager;
    WPSceneParser       parser;

    auto parsed = parser.Parse("puppet-slots", BasicPuppetSceneJson(), vfs, sound_manager);

    ASSERT_NE(parsed, nullptr);
    auto node = FindRootChildByName(*parsed, "puppet image");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    const auto& mesh = *node->Mesh();
    ASSERT_EQ(mesh.Submeshes().size(), 2u);
    EXPECT_EQ(mesh.Submeshes()[0].material_slot, 0u);
    EXPECT_EQ(mesh.Submeshes()[1].material_slot, 1u);
    ASSERT_EQ(mesh.MaterialSlots().size(), 2u);
    ASSERT_NE(mesh.MaterialForSlot(0), nullptr);
    ASSERT_NE(mesh.MaterialForSlot(1), nullptr);
    EXPECT_EQ(mesh.MaterialForSlot(0)->name, "headimage");
    EXPECT_EQ(mesh.MaterialForSlot(1)->name, "eyesimage");
    ASSERT_EQ(mesh.MaterialForSlot(0)->textures.size(), 1u);
    ASSERT_EQ(mesh.MaterialForSlot(1)->textures.size(), 1u);
    EXPECT_EQ(mesh.MaterialForSlot(0)->textures[0], "head.tex");
    EXPECT_EQ(mesh.MaterialForSlot(1)->textures[0], "eyes.tex");
}

TEST(SceneSchema, ParserKeepsMeshOnlyPuppetMaterialSlotsWithoutMdlsBlock) {
    auto files = std::map<std::string, std::string> {};
    AddPuppetImageSceneFiles(files, true, true);
    fs::VFS vfs;
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager;
    WPSceneParser       parser;

    auto parsed = parser.Parse("mesh-only-puppet-slots", BasicPuppetSceneJson(), vfs, sound_manager);

    ASSERT_NE(parsed, nullptr);
    auto node = FindRootChildByName(*parsed, "puppet image");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    const auto& mesh = *node->Mesh();
    ASSERT_EQ(mesh.Submeshes().size(), 2u);
    EXPECT_EQ(mesh.Submeshes()[0].material_slot, 0u);
    EXPECT_EQ(mesh.Submeshes()[1].material_slot, 1u);
    ASSERT_EQ(mesh.MaterialSlots().size(), 2u);
    ASSERT_NE(mesh.MaterialForSlot(0), nullptr);
    ASSERT_NE(mesh.MaterialForSlot(1), nullptr);
    EXPECT_EQ(mesh.MaterialForSlot(0)->name, "headimage");
    EXPECT_EQ(mesh.MaterialForSlot(1)->name, "eyesimage");
    ASSERT_EQ(mesh.MaterialForSlot(0)->textures.size(), 1u);
    ASSERT_EQ(mesh.MaterialForSlot(1)->textures.size(), 1u);
    EXPECT_EQ(mesh.MaterialForSlot(0)->textures[0], "head.tex");
    EXPECT_EQ(mesh.MaterialForSlot(1)->textures[0], "eyes.tex");
}

TEST(SceneSchema, ParserAlignsMaskedMultiMeshPuppetMaterialSlotsWithSubmeshes) {
    auto files = std::map<std::string, std::string> {};
    AddMaskedTwoMeshPuppetSceneFiles(files);
    fs::VFS vfs;
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager;
    WPSceneParser       parser;

    auto parsed = parser.Parse("masked-puppet-slots", BasicPuppetSceneJson(), vfs, sound_manager);

    ASSERT_NE(parsed, nullptr);
    auto node = FindRootChildByName(*parsed, "puppet image");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    const auto& mesh = *node->Mesh();
    ASSERT_EQ(mesh.Submeshes().size(), 4u);
    ASSERT_EQ(mesh.MaterialSlots().size(), 4u);

    EXPECT_EQ(mesh.Submeshes()[0].material_slot, 0u);
    EXPECT_EQ(mesh.Submeshes()[1].material_slot, 1u);
    EXPECT_EQ(mesh.Submeshes()[1].output_override, "_rt_puppet_mask");
    EXPECT_EQ(mesh.Submeshes()[2].material_slot, 2u);
    EXPECT_EQ(mesh.Submeshes()[3].material_slot, 3u);

    ASSERT_NE(mesh.MaterialForSlot(0), nullptr);
    ASSERT_NE(mesh.MaterialForSlot(1), nullptr);
    ASSERT_NE(mesh.MaterialForSlot(2), nullptr);
    ASSERT_NE(mesh.MaterialForSlot(3), nullptr);
    EXPECT_EQ(mesh.MaterialForSlot(0)->name, "headimage");
    EXPECT_EQ(mesh.MaterialForSlot(1)->name, "clippingmaskimage4");
    EXPECT_EQ(mesh.MaterialForSlot(2)->name, "headimage");
    EXPECT_EQ(mesh.MaterialForSlot(3)->name, "eyesimage");
    ASSERT_FALSE(mesh.MaterialForSlot(2)->textures.empty());
    ASSERT_FALSE(mesh.MaterialForSlot(3)->textures.empty());
    EXPECT_EQ(mesh.MaterialForSlot(2)->textures[0], "head.tex");
    EXPECT_EQ(mesh.MaterialForSlot(3)->textures[0], "eyes.tex");
}

TEST(SceneSchema, ParserBuildsMeshOnlyPuppetSubmeshesWithMeshVertexLayout) {
    auto files = std::map<std::string, std::string> {};
    AddPuppetImageSceneFiles(files, true, true);
    fs::VFS vfs;
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager;
    WPSceneParser       parser;

    auto parsed = parser.Parse("mesh-only-puppet-layout", BasicPuppetSceneJson(), vfs, sound_manager);

    ASSERT_NE(parsed, nullptr);
    auto node = FindRootChildByName(*parsed, "puppet image");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    const auto& mesh = *node->Mesh();
    ASSERT_EQ(mesh.Submeshes().size(), 2u);
    ASSERT_EQ(mesh.Submeshes()[0].VertexCount(), 1u);
    const auto& attrs = mesh.Submeshes()[0].GetVertexArray(0).Attributes();
    ASSERT_EQ(attrs.size(), 2u);
    EXPECT_EQ(attrs[0].name, std::string(WE_IN_POSITION));
    EXPECT_EQ(attrs[0].type, VertexType::FLOAT3);
    EXPECT_EQ(attrs[1].name, std::string(WE_IN_TEXCOORD));
    EXPECT_EQ(attrs[1].type, VertexType::FLOAT2);
}

TEST(SceneSchema, ParserAppliesPuppetMaterialInfoBeforeLoadingSlotMaterials) {
    auto files = std::map<std::string, std::string> {};
    AddPuppetImageSceneFiles(files);
    fs::VFS vfs;
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager;
    WPSceneParser       parser;

    auto parsed = parser.Parse("puppet-slot-combos", BasicPuppetSceneJson(true), vfs, sound_manager);

    ASSERT_NE(parsed, nullptr);
    auto node = FindRootChildByName(*parsed, "puppet image");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    ASSERT_EQ(node->Mesh()->MaterialSlots().size(), 2u);
    for (uint32_t slot = 0; slot < 2; ++slot) {
        const auto* material = node->Mesh()->MaterialForSlot(slot);
        ASSERT_NE(material, nullptr);
        ASSERT_NE(material->customShader.shader, nullptr);
        EXPECT_GT(material->customShader.shader->codes[0].size(), 0u);
    }
    EXPECT_FLOAT_EQ(node->Mesh()->MaterialForSlot(0)->customShader.constValues.at("g_Alpha")[0],
                    0.6f);
    EXPECT_FLOAT_EQ(node->Mesh()->MaterialForSlot(1)->customShader.constValues.at("g_Alpha")[0],
                    0.6f);
}

TEST(SceneSchema, ParserRegistersPuppetSlotShaderValueDataByMaterialSlot) {
    auto files = std::map<std::string, std::string> {};
    AddPuppetSlotRenderTargetSceneFiles(files);
    fs::VFS vfs;
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager;
    WPSceneParser       parser;

    auto parsed = parser.Parse("puppet-slot-render-targets", BasicPuppetSceneJson(), vfs, sound_manager);

    ASSERT_NE(parsed, nullptr);
    auto node = FindRootChildByName(*parsed, "puppet image");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(parsed->shaderValueUpdater, nullptr);
    auto* updater = dynamic_cast<WPShaderValueUpdater*>(parsed->shaderValueUpdater.get());
    ASSERT_NE(updater, nullptr);
    updater->InitUniforms(node.get(), 1, [](std::string_view name) {
        return name == "g_Texture0Resolution";
    });

    sprite_map_t sprites;
    std::unordered_map<std::string, ShaderValue> updates;
    updater->UpdateUniforms(node.get(), 1, sprites, [&](std::string_view name, const ShaderValue& value) {
        updates.emplace(std::string(name), value);
    });

    ASSERT_TRUE(updates.contains("g_Texture0Resolution"));
    EXPECT_FLOAT_EQ(updates.at("g_Texture0Resolution")[0], 160.0f);
    EXPECT_FLOAT_EQ(updates.at("g_Texture0Resolution")[1], 90.0f);
}

TEST(SceneSchema, ParallaxInheritanceResolvesRootsWithoutDependingOnDeclarationOrder) {
    auto objects = nlohmann::json::parse(R"([
        {"id":3,"parent":2,"parallaxDepth":[9,9]},
        {"id":2,"parent":1,"parallaxDepth":[0,0]},
        {"id":1,"parallaxDepth":[0.75,-0.25]},
        {"id":4,"parent":5,"parallaxDepth":[1,1]},
        {"id":5},
        {"id":6,"parent":99,"parallaxDepth":[0.2,0.4]},
        {"id":7,"parent":8,"parallaxDepth":[2,3]},
        {"id":8,"parent":7,"parallaxDepth":[4,5]},
        {"id":9,"parallaxDepth":[6,7]},
        {"id":9,"parallaxDepth":[8,9]},
        {"id":10,"parent":9,"parallaxDepth":[10,11]}
    ])");
    const auto original = objects;
    for (bool reversed : {false, true}) {
        objects = original;
        if (reversed) std::reverse(objects.begin(), objects.end());
        ResolveLayerParallax(objects);
        if (reversed) std::reverse(objects.begin(), objects.end());
        EXPECT_EQ(objects[0]["parallaxDepth"], original[2]["parallaxDepth"]);
        EXPECT_EQ(objects[1]["parallaxDepth"], original[2]["parallaxDepth"]);
        // A root without a depth has Wallpaper Engine's default, (1, 1).
        EXPECT_EQ(objects[3]["parallaxDepth"], nlohmann::json::array({1, 1}));
        for (std::size_t i : {2u, 4u, 5u, 6u, 7u, 8u, 9u, 10u})
            EXPECT_EQ(objects[i], original[i]);
    }
}

TEST(SceneSchema, ParallaxInheritanceRejectsOutOfRangeIdsWithoutAliasingValidLayers) {
    const auto minimum = std::numeric_limits<int32_t>::min();
    const auto maximum = std::numeric_limits<int32_t>::max();
    const std::vector<std::pair<nlohmann::json, int32_t>> invalid_ids {
        {int64_t(maximum) + 1, minimum}, {int64_t(minimum) - 1, maximum},
        {uint64_t(maximum) + 1, minimum}, {std::numeric_limits<uint64_t>::max(), -1},
        {(int64_t(1) << 32) + 1, 1},
    };
    for (const auto& [invalid, valid] : invalid_ids) {
        SCOPED_TRACE(invalid.dump());
        for (bool include_invalid_id : {false, true}) {
            auto original = nlohmann::json::array({
                {{"id", valid}, {"parallaxDepth", {0.75, -0.25}}},
                {{"id", 2}, {"parent", valid}, {"parallaxDepth", {2, 3}}},
                {{"id", 3}, {"parent", invalid}, {"parallaxDepth", {4, 5}}},
            });
            if (include_invalid_id) original.push_back({{"id", invalid}, {"parallaxDepth", {9, 9}}});
            for (bool reversed : {false, true}) {
                auto objects = original;
                if (reversed) std::reverse(objects.begin(), objects.end());
                ResolveLayerParallax(objects);
                if (reversed) std::reverse(objects.begin(), objects.end());
                EXPECT_EQ(objects[1]["parallaxDepth"], original[0]["parallaxDepth"]);
                EXPECT_EQ(objects[2], original[2]);
                EXPECT_EQ(objects[0], original[0]);
                if (include_invalid_id) EXPECT_EQ(objects[3], original[3]);
            }
        }
    }
}

TEST(SceneSchema, ParallaxInheritanceAcceptsSignedBoundariesAndUnsignedInRangeIds) {
    for (const auto& id : std::vector<nlohmann::json> {
             std::numeric_limits<int32_t>::min(), std::numeric_limits<int32_t>::max(),
             uint64_t(std::numeric_limits<int32_t>::max()),
         }) {
        auto objects = nlohmann::json::array({
            {{"id", 1}, {"parent", id}, {"parallaxDepth", {9, 9}}},
            {{"id", id}, {"parallaxDepth", {0.75, -0.25}}},
        });
        ResolveLayerParallax(objects);
        EXPECT_EQ(objects[0]["parallaxDepth"], objects[1]["parallaxDepth"]);
    }
}

TEST(SceneSchema, ParentedPuppetSlotsFollowTheRootDepthAndKeepTheirLocalTransforms) {
    for (bool reversed : {false, true}) {
        auto files = std::map<std::string, std::string> {};
        AddPuppetImageSceneFiles(files);
        fs::VFS vfs;
        ASSERT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
        audio::SoundManager sound(audio::SoundManager::OutputBackend::Null);
        auto source = nlohmann::json::parse(PuppetParallaxSceneJson());
        auto& objects = source["objects"];
        objects[0]["parent"] = 20;
        objects[0]["origin"] = {13, 17, 0};
        objects.push_back({{"id", 20}, {"name", "inner group"}, {"parent", 10},
                           {"parallaxDepth", {9, 9}}, {"origin", {30, 40, 0}}});
        objects.push_back({{"id", 10}, {"name", "root group"},
                           {"parallaxDepth", {0.75, -0.25}}, {"origin", {100, 80, 0}}});
        if (reversed) std::reverse(objects.begin(), objects.end());
        auto parsed = WPSceneParser().Parse("parent-parallax", source.dump(), vfs, sound);
        ASSERT_NE(parsed, nullptr);
        auto root = FindRootChildByName(*parsed, "root group");
        ASSERT_NE(root, nullptr);
        auto* inner = FindFirstChildByName(*root, "inner group");
        ASSERT_NE(inner, nullptr);
        auto* node = FindFirstChildByName(*inner, "puppet image");
        ASSERT_NE(node, nullptr);
        ASSERT_NE(node->Mesh(), nullptr);
        ASSERT_EQ(node->Mesh()->MaterialSlots().size(), 2u);
        auto& updater = *parsed->shaderValueUpdater;
        for (uint32_t slot = 0; slot < 2; ++slot)
            updater.InitUniforms(node, slot, [](std::string_view name) {
                return name == "g_ModelMatrix";
            });
        for (float x : {0.5f, 1.0f, 0.0f, 0.5f}) {
            updater.MouseInput(x, 1.0f - x);
            parsed->frameTime = 0.25;
            updater.FrameBegin();
            node->UpdateTrans();
            EXPECT_NEAR(node->ModelTrans()(0, 3), 143.0, 1e-5);
            EXPECT_NEAR(node->ModelTrans()(1, 3), 137.0, 1e-5);
            for (uint32_t slot = 0; slot < 2; ++slot) {
                ShaderValue model;
                sprite_map_t sprites;
                updater.UpdateUniforms(node, slot, sprites,
                    [&](std::string_view name, const ShaderValue& value) {
                        if (name == "g_ModelMatrix") model = value;
                    });
                ASSERT_EQ(model.size(), 16u);
                // The cursor's offset plus the root group's distance from the
                // view centre (320, 180), both times the root's depth.
                EXPECT_NEAR(model[12], 143.0f + ((0.5f - x) * 640 + (100 - 320)) * 2 * 0.75f, 1e-3);
                EXPECT_NEAR(model[13], 137.0f + ((0.5f - x) * 360 + (80 - 180)) * 2 * -0.25f, 1e-3);
            }
        }
    }
}

TEST(SceneSchema, ParserCopiesImageParallaxDepthToPuppetMaterialSlots) {
    auto files = std::map<std::string, std::string> {};
    AddPuppetImageSceneFiles(files);
    fs::VFS vfs;
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager;
    WPSceneParser       parser;

    auto parsed = parser.Parse("puppet-slot-parallax", PuppetParallaxSceneJson(), vfs, sound_manager);

    ASSERT_NE(parsed, nullptr);
    auto node = FindRootChildByName(*parsed, "puppet image");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    ASSERT_EQ(node->Mesh()->MaterialSlots().size(), 2u);
    ASSERT_NE(parsed->shaderValueUpdater, nullptr);
    auto* updater = dynamic_cast<WPShaderValueUpdater*>(parsed->shaderValueUpdater.get());
    ASSERT_NE(updater, nullptr);
    updater->InitUniforms(node.get(), 1, [](std::string_view name) {
        return name == "g_ModelMatrix";
    });
    // Parallax follows the cursor, so it is moved off the centre and given the
    // whole delay to arrive; only a slot that has the layer's depth moves.
    updater->MouseInput(1.0, 0.0);
    parsed->frameTime = 0.25;
    updater->FrameBegin();

    sprite_map_t sprites;
    std::unordered_map<std::string, ShaderValue> updates;
    updater->UpdateUniforms(node.get(), 1, sprites, [&](std::string_view name, const ShaderValue& value) {
        updates.emplace(std::string(name), value);
    });

    ASSERT_TRUE(updates.contains("g_ModelMatrix"));
    const auto placed = node->ModelTrans();
    EXPECT_NE(updates.at("g_ModelMatrix")[12], static_cast<float>(placed(0, 3)));
    EXPECT_NE(updates.at("g_ModelMatrix")[13], static_cast<float>(placed(1, 3)));
}

TEST(SceneSchema, ParserFallsBackWhenPuppetMeshSlotMaterialFailsToLoad) {
    auto files = std::map<std::string, std::string> {};
    AddPuppetImageSceneFiles(files, false);
    fs::VFS vfs;
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager;
    WPSceneParser       parser;

    auto parsed = parser.Parse("puppet-slot-fallback", BasicPuppetSceneJson(), vfs, sound_manager);

    ASSERT_NE(parsed, nullptr);
    auto node = FindRootChildByName(*parsed, "puppet image");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    EXPECT_EQ(node->Mesh()->Submeshes().size(), 2u);
    ASSERT_EQ(node->Mesh()->MaterialSlots().size(), 1u);
    ASSERT_NE(node->Mesh()->Material(), nullptr);
    EXPECT_EQ(node->Mesh()->Material()->name, "baseimage");
    ASSERT_EQ(node->Mesh()->Submeshes().size(), 2u);
    EXPECT_EQ(node->Mesh()->Submeshes()[0].material_slot, 0u);
    EXPECT_EQ(node->Mesh()->Submeshes()[1].material_slot, 0u);
}

std::shared_ptr<Scene> ParseCameraZoomScene(const nlohmann::json& zoom) {
    auto source = nlohmann::json::parse(BasicImageSceneJson());
    source["objects"] = nlohmann::json::array();
    source["general"]["orthogonalprojection"] = {{"width", 960}, {"height", 540}};
    source["general"]["zoom"] = zoom;
    fs::VFS vfs;
    audio::SoundManager sound;
    ProjectProperties properties;
    return WPSceneParser().Parse(SceneParseRequest {
        .scene_id = "camera-zoom", .project_properties = &properties,
    }, source.dump(), vfs, sound);
}

TEST(SceneSchema, CameraZoomTimelineRevealsFullCanvasWithoutResizingRenderTargets) {
    auto parsed = ParseCameraZoomScene(nlohmann::json::parse(R"({
        "value":3,"animation":{
            "options":{"fps":30,"length":450,"mode":"single","name":"intro"},
            "c0":[{"frame":0,"value":3},{"frame":300,"value":3},
                  {"frame":450,"value":1}]
        }
    })"));
    ASSERT_NE(parsed, nullptr);
    ASSERT_NE(parsed->runtime, nullptr);
    auto camera = parsed->cameras.at("global");
    auto perspective = parsed->cameras.at("global_perspective");
    auto linked = std::make_shared<SceneCamera>(*camera);
    parsed->cameras["linked"] = linked;
    parsed->linkedCameras["global"].push_back("linked");
    EXPECT_DOUBLE_EQ(camera->Width(), 320);
    EXPECT_DOUBLE_EQ(camera->Height(), 180);
    const auto initial_fov = perspective->Fov();
    const auto initial_distance = perspective->GetPosition().z();
    const auto target = parsed->renderTargets.at(std::string(SpecTex_Default));
    parsed->runtime->Tick(10.0);
    EXPECT_DOUBLE_EQ(camera->Width(), 320);
    parsed->runtime->Tick(2.5);
    EXPECT_DOUBLE_EQ(camera->Width(), 480);
    EXPECT_DOUBLE_EQ(camera->Height(), 270);
    parsed->runtime->Tick(2.5);
    EXPECT_DOUBLE_EQ(camera->Width(), 960);
    EXPECT_DOUBLE_EQ(camera->Height(), 540);
    EXPECT_DOUBLE_EQ(linked->Width(), camera->Width());
    EXPECT_DOUBLE_EQ(linked->Height(), camera->Height());
    // The zoom reframes the canvas, not the lens: the field of view stays the
    // scene's and the eye backs off as more of the canvas shows.
    EXPECT_DOUBLE_EQ(perspective->Fov(), initial_fov);
    EXPECT_GT(perspective->GetPosition().z(), initial_distance);
    EXPECT_NEAR(perspective->GetPosition().z(),
                270.0 / std::tan(initial_fov * M_PI / 360.0), 1e-3);
    EXPECT_DOUBLE_EQ(perspective->Aspect(), camera->Aspect());
    for (const auto* view : {camera.get(), perspective.get(), linked.get()}) {
        for (const auto& corner : {Eigen::Vector4d(0, 0, 0, 1),
                                   Eigen::Vector4d(960, 540, 0, 1)}) {
            const Eigen::Vector4d clip = view->GetViewProjectionMatrix() * corner;
            EXPECT_NEAR(std::abs(clip.x() / clip.w()), 1.0, 1e-6);
            EXPECT_NEAR(std::abs(clip.y() / clip.w()), 1.0, 1e-6);
        }
    }
    parsed->runtime->Tick(20.0);
    EXPECT_DOUBLE_EQ(camera->Width(), 960);
    EXPECT_EQ(parsed->ortho[0], 960);
    EXPECT_EQ(parsed->ortho[1], 540);
    EXPECT_EQ(parsed->renderTargets.at(std::string(SpecTex_Default)).width, target.width);
    EXPECT_EQ(parsed->renderTargets.at(std::string(SpecTex_Default)).height, target.height);
}

// A 2D scene's perspective layers -- particles and models with the
// `perspective` flag -- are drawn through a camera that Wallpaper Engine seats
// (canvas height / 2) / tan(fov / 2) in front of the canvas, with the scene's
// `perspectiveoverridefov` (95 when it leaves the key out; `fov` belongs to
// scenes with a perspective projection). The canvas plane maps exactly as the
// orthographic view does; what lies off it is magnified by D / (D - z), and
// nothing is clipped before it reaches the eye.
std::shared_ptr<Scene> ParseCanvasPerspectiveScene(int width, int height,
                                                   std::optional<double> override_fov) {
    auto source = nlohmann::json::parse(BasicImageSceneJson());
    source["objects"] = nlohmann::json::array();
    source["general"]["orthogonalprojection"] = {{"width", width}, {"height", height}};
    source["general"]["fov"] = 60;
    if (override_fov.has_value()) source["general"]["perspectiveoverridefov"] = *override_fov;
    fs::VFS vfs;
    audio::SoundManager sound;
    ProjectProperties properties;
    return WPSceneParser().Parse(SceneParseRequest {
        .scene_id = "canvas-perspective", .project_properties = &properties,
    }, source.dump(), vfs, sound);
}

Eigen::Vector4d ClipOf(const SceneCamera& camera, double x, double y, double z) {
    return camera.GetViewProjectionMatrix() * Eigen::Vector4d(x, y, z, 1.0);
}

TEST(SceneSchema, A2DScenesPerspectiveCameraSitsWhereItsFieldOfViewPutsTheEye) {
    struct Case {
        int                  width;
        int                  height;
        std::optional<double> override_fov;
        double               fov;
    };
    const Case cases[] = {
        { 1920, 1080, 50.0, 50.0 },
        { 3840, 2160, 25.0, 25.0 },
        { 1366, 768, 95.0, 95.0 },
        // No key: 95, whatever `fov` says.
        { 1366, 768, std::nullopt, 95.0 },
        { 7680, 2160, 170.0, 170.0 },
    };
    for (const auto& c : cases) {
        SCOPED_TRACE(std::to_string(c.width) + "x" + std::to_string(c.height) + " fov " +
                     std::to_string(c.fov));
        auto parsed = ParseCanvasPerspectiveScene(c.width, c.height, c.override_fov);
        ASSERT_NE(parsed, nullptr);
        const auto& canvas      = *parsed->cameras.at("global");
        const auto& perspective = *parsed->cameras.at("global_perspective");
        const double distance   = (c.height / 2.0) / std::tan(c.fov * M_PI / 360.0);

        EXPECT_DOUBLE_EQ(perspective.Fov(), c.fov);
        const auto eye = perspective.GetPosition();
        EXPECT_NEAR(eye.x(), c.width / 2.0, 1e-3);
        EXPECT_NEAR(eye.y(), c.height / 2.0, 1e-3);
        EXPECT_NEAR(eye.z(), distance, distance * 1e-6);
        EXPECT_DOUBLE_EQ(perspective.NearClip(), 5.0);
        EXPECT_NEAR(perspective.FarClip(), std::max(distance + 1000.0, 15000.0), 1e-2);

        // The canvas plane is mapped as the orthographic camera maps it.
        for (const auto& point : {std::pair {0.0, 0.0}, std::pair {double(c.width), double(c.height)},
                                  std::pair {c.width * 0.3, c.height * 0.8}}) {
            const auto flat = ClipOf(canvas, point.first, point.second, 0.0);
            const auto deep = ClipOf(perspective, point.first, point.second, 0.0);
            EXPECT_NEAR(deep.x() / deep.w(), flat.x() / flat.w(), 1e-5);
            EXPECT_NEAR(deep.y() / deep.w(), flat.y() / flat.w(), 1e-5);
        }

        // What lies in front of the plane is larger by D / (D - z) and stays
        // in view up to the near plane, 5 units from the eye, past a thousand
        // units out or not.
        const double offset = c.width / 200.0;
        const auto   centre_x = c.width / 2.0;
        const auto   flat = ClipOf(perspective, centre_x + offset, c.height / 2.0, 0.0);
        for (const double z : {distance * 0.1, distance * 0.5, distance * 0.9, distance - 6.0}) {
            SCOPED_TRACE("z " + std::to_string(z));
            const auto at = ClipOf(perspective, centre_x + offset, c.height / 2.0, z);
            ASSERT_GT(at.w(), 0.0);
            // The eye is stored as a float, which near a far eye is a fraction of a
            // unit: the ratio is taken against where it really is.
            const double seen = eye.z() / (eye.z() - z);
            EXPECT_NEAR((at.x() / at.w()) / (flat.x() / flat.w()), seen, seen * 1e-5);
            const auto middle = ClipOf(perspective, centre_x, c.height / 2.0, z);
            const double depth = middle.z() / middle.w();
            EXPECT_GE(depth, 0.0);
            EXPECT_LE(depth, 1.0);
        }
    }
}

TEST(SceneSchema, TheFieldOfViewOfA2DScenesPerspectiveCameraIsReadFromAnyPackageVersion) {
    const auto json = nlohmann::json::parse(R"({"perspectiveoverridefov":70.0,"windenabled":true})");
    // `windenabled` is a package-version-21 key and stays gated; the field of view
    // is read from whatever file carries it.
    wpscene::WPSceneGeneral v9;
    ASSERT_TRUE(v9.FromJson(json, 9));
    EXPECT_FLOAT_EQ(v9.perspectiveoverridefov, 70.0f);
    EXPECT_FALSE(v9.windenabled);
}

// What a shader reads as `g_EyePosition` in a 2D scene is not where the perspective
// camera sits. Wallpaper Engine keeps that eye at the centre of the view, 2000
// units in front of the canvas (the scene-wide eye of FUN_1401891a0), whatever
// distance the field of view puts the projection's eye at; the particle trail
// shaders orient their ribbons by it.
TEST(SceneSchema, A2DScenesPerspectiveModelReadsTheEyeTwoThousandUnitsOutWhateverTheLens) {
    auto files = std::map<std::string, std::string> {};
    AddLeafModelSceneFiles(files);
    fs::VFS vfs;
    ASSERT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager;
    auto parsed = WPSceneParser().Parse("canvas-eye", R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0, "perspectiveoverridefov":40,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":7,"name":"planet","model":"planet.mdl","perspective":true,
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true}
      ]
    })", vfs, sound_manager);
    ASSERT_NE(parsed, nullptr);
    auto node = FindRootChildByName(*parsed, "planet");
    ASSERT_NE(node, nullptr);
    ASSERT_EQ(node->Camera(), "global_perspective");
    auto* updater = parsed->shaderValueUpdater.get();
    ASSERT_NE(updater, nullptr);
    updater->InitUniforms(node.get(), 0, [](std::string_view name) { return name == "g_EyePosition"; });
    const auto read_eye = [&] {
        std::array<float, 3> eye { 0.0f, 0.0f, 0.0f };
        sprite_map_t         sprites;
        updater->UpdateUniforms(node.get(), sprites,
                                [&](std::string_view name, const ShaderValue& value) {
                                    if (name == "g_EyePosition") eye = { value[0], value[1], value[2] };
                                });
        return eye;
    };

    // The projection's eye is (360 / 2) / tan(20 degrees) = 494.6 units out.
    const auto& perspective = *parsed->cameras.at("global_perspective");
    ASSERT_NEAR(perspective.GetPosition().z(), 180.0 / std::tan(20.0 * M_PI / 180.0), 1e-2);
    auto eye = read_eye();
    EXPECT_NEAR(eye[0], 320.0f, 1e-3f);
    EXPECT_NEAR(eye[1], 180.0f, 1e-3f);
    EXPECT_NEAR(eye[2], 2000.0f, 1e-3f);

    // A reframed canvas moves the view's centre and the projection's eye; the
    // shader's eye follows the centre and keeps its distance.
    parsed->FrameCanvas(3.0, Eigen::Vector2f(40.0f, -20.0f));
    ASSERT_GT(std::abs(perspective.GetPosition().z() - 494.6), 100.0);
    eye = read_eye();
    EXPECT_NEAR(eye[0], 360.0f, 1e-3f);
    EXPECT_NEAR(eye[1], 160.0f, 1e-3f);
    EXPECT_NEAR(eye[2], 2000.0f, 1e-3f);
}

TEST(SceneSchema, CameraZoomTimelineHonorsPausedFirstKeyAndLooping) {
    auto parsed = ParseCameraZoomScene(nlohmann::json::parse(R"({
        "value":7,"animation":{
            "options":{"fps":30,"length":60,"mode":"loop","startpaused":true,"name":"zoom"},
            "c0":[{"frame":0,"value":2},{"frame":30,"value":1},{"frame":60,"value":2}]
        }
    })"));
    ASSERT_NE(parsed, nullptr);
    auto camera = parsed->cameras.at("global");
    EXPECT_DOUBLE_EQ(camera->Width(), 480);
    parsed->runtime->Tick(5.0);
    EXPECT_DOUBLE_EQ(camera->Width(), 480);
    auto* animation = parsed->runtime->FindScalarAnimation("", "zoom");
    ASSERT_NE(animation, nullptr);
    animation->Play();
    parsed->runtime->Tick(1.0);
    EXPECT_DOUBLE_EQ(camera->Width(), 960);
    parsed->runtime->Tick(1.0);
    EXPECT_DOUBLE_EQ(camera->Width(), 480);
    animation->Stop();
    parsed->runtime->Tick(1.0);
    EXPECT_DOUBLE_EQ(camera->Width(), 480);
}

TEST(SceneSchema, StaticAndInvalidCameraZoomRemainStable) {
    for (const auto& zoom : {nlohmann::json(2), nlohmann::json(0), nlohmann::json(-1),
                            nlohmann::json::parse(R"({"value":2,"animation":{}})")}) {
        auto parsed = ParseCameraZoomScene(zoom);
        ASSERT_NE(parsed, nullptr);
        const double width = zoom.is_number() && zoom.get<float>() <= 0 ? 960 : 480;
        EXPECT_DOUBLE_EQ(parsed->cameras.at("global")->Width(), width);
        parsed->runtime->Tick(20.0);
        EXPECT_DOUBLE_EQ(parsed->cameras.at("global")->Width(), width);
    }
}

TEST(SceneSchema, ParserPreservesPausedMaterialTimelineAndAppliesItsFirstKey) {
    auto files = std::map<std::string, std::string> {};
    AddMultiVideoImageSceneFiles(files);
    auto material = nlohmann::json::parse(files.at("/mat/multi_video.json"));
    material["passes"][0]["constantshadervalues"]["Opacity"] = nlohmann::json::parse(R"({
        "value":1.5,"animation":{
            "options":{"fps":30,"length":9,"mode":"single","startpaused":true,"name":"transition"},
            "c0":[{"frame":0,"value":0},{"frame":5,"value":1.5},{"frame":9,"value":0}]
        }
    })");
    files["/mat/multi_video.json"] = material.dump();
    files["/shaders/multivideo.frag"] = R"(
uniform float u_Opacity; // {"material":"Opacity","default":1}
void main() { gl_FragColor = vec4(u_Opacity); }
)";
    fs::VFS vfs;
    ASSERT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager;
    WPSceneParser parser;
    ProjectProperties properties;
    SceneParseRequest request {
        .scene_id = "paused-material-timeline",
        .project_properties = &properties,
    };
    auto parsed = parser.Parse(request, BasicImageSceneJson(), vfs, sound_manager);
    ASSERT_NE(parsed, nullptr);
    ASSERT_NE(parsed->runtime, nullptr);
    auto node = FindRootChildByName(*parsed, "video image");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    ASSERT_NE(node->Mesh()->Material(), nullptr);
    const auto& values = node->Mesh()->Material()->customShader.constValues;
    ASSERT_TRUE(values.contains("u_Opacity"));
    EXPECT_FLOAT_EQ(values.at("u_Opacity")[0], 0.0f);
    parsed->runtime->Tick(2.0);
    EXPECT_FLOAT_EQ(values.at("u_Opacity")[0], 0.0f);
    auto* animation = parsed->runtime->FindScalarAnimation("video image", "transition");
    ASSERT_NE(animation, nullptr);
    animation->Play();
    parsed->runtime->Tick(5.0 / 30.0);
    EXPECT_FLOAT_EQ(values.at("u_Opacity")[0], 1.5f);
    parsed->runtime->Tick(4.0 / 30.0);
    EXPECT_FLOAT_EQ(values.at("u_Opacity")[0], 0.0f);
}


// A vector shader constant carries one curve per component, and an author can
// slave several constants to one timeline. Both go through the real material
// pass here, so the assertions read the values a shader would be handed.
nlohmann::json VectorConstant(std::vector<float> value, const char* animation = nullptr) {
    nlohmann::json constant { { "value", std::move(value) } };
    if (animation != nullptr) constant["animation"] = nlohmann::json::parse(animation);
    return constant;
}

std::shared_ptr<Scene> ParseVectorTimelineScene(
    const std::vector<std::pair<std::string, nlohmann::json>>& layers,
    const nlohmann::json& origin = nlohmann::json::array({ 0, 0, 0 })) {
    std::map<std::string, std::string> files;
    files["/shaders/foldpage.vert"] = R"(
attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)";
    files["/shaders/foldpage.frag"] = R"(
uniform vec2 u_Point1; // {"material":"point1","default":"0 0"}
uniform vec2 u_Point2; // {"material":"point2","default":"0 0"}
varying vec2 v_TexCoord;
void main() { gl_FragColor = vec4(u_Point1 * v_TexCoord, u_Point2); }
)";
    auto source       = nlohmann::json::parse(BasicImageSceneJson());
    source["objects"] = nlohmann::json::array();
    int32_t id        = 400;
    for (const auto& [name, constants] : layers) {
        files["/" + name + ".json"] = nlohmann::json {
            { "width", 64 }, { "height", 32 }, { "material", "mat/" + name + ".json" }
        }.dump();
        files["/mat/" + name + ".json"] = nlohmann::json {
            { "passes", nlohmann::json::array({ nlohmann::json {
                  { "shader", "foldpage" },
                  { "blending", "translucent" },
                  { "cullmode", "nocull" },
                  { "depthtest", "disabled" },
                  { "depthwrite", "disabled" },
                  { "constantshadervalues", constants },
              } }) }
        }.dump();
        source["objects"].push_back(nlohmann::json {
            { "id", id++ }, { "name", name }, { "image", name + ".json" },
            { "origin", origin }, { "scale", { 1, 1, 1 } },
            { "angles", { 0, 0, 0 } }, { "visible", true } });
    }
    fs::VFS vfs;
    if (! vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files)))) return nullptr;
    audio::SoundManager sound_manager;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id = "vector-material-timeline",
          .project_properties = &properties,
    };
    return WPSceneParser().Parse(request, source.dump(), vfs, sound_manager);
}

const ShaderValues* LayerConstants(const Scene& scene, std::string_view name) {
    auto node = FindRootChildByName(scene, name);
    if (node == nullptr || node->Mesh() == nullptr || node->Mesh()->Material() == nullptr) {
        return nullptr;
    }
    return &node->Mesh()->Material()->customShader.constValues;
}

// The child's static value and its first key differ, so a component that never
// reads the curve is visible instead of being hidden behind a matching default.
const char* const kFoldChildAnimation = R"({
    "options":{"fps":30,"length":3,"mode":"single","parent":{"key":"point2"}},
    "c0":[{"frame":0,"value":0.875},{"frame":3,"value":0.375}],
    "c1":[{"frame":0,"value":0.875},{"frame":3,"value":0.875}]
})";
const char* const kFoldRootAnimation = R"({
    "options":{"fps":30,"length":3,"mode":"single","startpaused":true,"name":"fold",
               "children":[{"key":"point1"}]},
    "c0":[{"frame":0,"value":0.75},{"frame":3,"value":0.25}],
    "c1":[{"frame":0,"value":0.375},{"frame":3,"value":0.375}]
})";

nlohmann::json PausedFoldConstants() {
    return nlohmann::json {
        { "point1", VectorConstant({ 0.375f, 0.875f }, kFoldChildAnimation) },
        { "point2", VectorConstant({ 0.75f, 0.375f }, kFoldRootAnimation) },
    };
}

TEST(SceneSchema, PausedVectorTimelineAppliesItsFirstKeyToEveryRelatedConstant) {
    auto parsed = ParseVectorTimelineScene({ { "fold page", PausedFoldConstants() } });
    ASSERT_NE(parsed, nullptr);
    ASSERT_NE(parsed->runtime, nullptr);
    const auto* values = LayerConstants(*parsed, "fold page");
    ASSERT_NE(values, nullptr);
    ASSERT_TRUE(values->contains("u_Point1"));
    ASSERT_EQ(values->at("u_Point1").size(), 2u);
    EXPECT_FLOAT_EQ(values->at("u_Point1")[0], 0.875f);
    EXPECT_FLOAT_EQ(values->at("u_Point1")[1], 0.875f);
    EXPECT_FLOAT_EQ(values->at("u_Point2")[0], 0.75f);
    EXPECT_FLOAT_EQ(values->at("u_Point2")[1], 0.375f);
    // The parent holds the clock, so no component may drift to its last key or
    // fall back to the static value the author only meant as a default.
    parsed->runtime->Tick(5.0);
    EXPECT_FLOAT_EQ(values->at("u_Point1")[0], 0.875f);
    EXPECT_FLOAT_EQ(values->at("u_Point1")[1], 0.875f);
    EXPECT_FLOAT_EQ(values->at("u_Point2")[0], 0.75f);
}

TEST(SceneSchema, ScriptedVectorTimelineMovesParentAndChildOnTheSameFrame) {
    auto parsed = ParseVectorTimelineScene({ { "fold page", PausedFoldConstants() } });
    ASSERT_NE(parsed, nullptr);
    ASSERT_NE(parsed->runtime, nullptr);
    const auto* values = LayerConstants(*parsed, "fold page");
    ASSERT_NE(values, nullptr);
    auto& runtime = *parsed->runtime;
    const auto command = [&](std::string source) {
        auto program = runtime.scriptEngine().CreatePropertyScriptProgram(
            &runtime, "export function update(value) { " + source + "; return value; }",
            "fold page", {}, DynamicValue(0.0f), runtime.hostContext());
        ASSERT_NE(program, nullptr);
        program->Evaluate(runtime.hostContext(), DynamicValue(0.0f));
    };

    command("thisLayer.getAnimation('fold').play()");
    runtime.Tick(1.5 / 30.0);
    EXPECT_FLOAT_EQ(values->at("u_Point1")[0], 0.625f);
    EXPECT_FLOAT_EQ(values->at("u_Point2")[0], 0.5f);
    command("thisLayer.getAnimation('fold').pause()");
    runtime.Tick(1.0);
    EXPECT_FLOAT_EQ(values->at("u_Point1")[0], 0.625f);
    EXPECT_FLOAT_EQ(values->at("u_Point2")[0], 0.5f);
    command("thisLayer.getAnimation('fold').play(); thisLayer.getAnimation('fold').rate = 2");
    runtime.Tick(1.0 / 30.0);
    EXPECT_FLOAT_EQ(values->at("u_Point1")[0], 0.375f);
    EXPECT_FLOAT_EQ(values->at("u_Point2")[0], 0.25f);
    // A finished single timeline restarts from its first key for the whole group.
    command("thisLayer.getAnimation('fold').play()");
    runtime.Tick(0.0);
    EXPECT_FLOAT_EQ(values->at("u_Point1")[0], 0.875f);
    EXPECT_FLOAT_EQ(values->at("u_Point2")[0], 0.75f);
    command("thisLayer.getAnimation('fold').setFrame(3); thisLayer.getAnimation('fold').stop()");
    runtime.Tick(0.0);
    EXPECT_FLOAT_EQ(values->at("u_Point1")[0], 0.875f);
    EXPECT_EQ(runtime.scriptErrorCount(), 0u);
}

// `thisObject.getAnimation()` with no name, in the script of a keyed setting,
// is the timeline bound to that setting. It was the first unnamed timeline of
// the layer, which for a layer whose origin also moves is the origin's: a
// cross-fade that restarts its constant's timeline on a new cover restarted
// the layer's slide instead, and the fade never ran.
TEST(SceneSchema, AKeyedConstantsScriptPlaysTheConstantsOwnTimeline) {
    auto constant = VectorConstant({ 0.75f, 0.375f }, R"({
        "options":{"fps":30,"length":3,"mode":"single","startpaused":true},
        "c0":[{"frame":0,"value":0.75},{"frame":3,"value":0.25}],
        "c1":[{"frame":0,"value":0.375},{"frame":3,"value":0.375}]
    })");
    constant["script"] =
        "export function init(value) { var a = thisObject.getAnimation(); a.stop(); a.play(); "
        "return value; }";
    const auto origin = nlohmann::json::parse(R"({
        "value":"0 0 0",
        "animation":{"relative":true,
                     "options":{"fps":30,"length":60,"mode":"loop","wraploop":true},
                     "c0":[{"frame":0,"value":0},{"frame":60,"value":10}],
                     "c1":[{"frame":0,"value":0},{"frame":60,"value":0}],
                     "c2":[{"frame":0,"value":0},{"frame":60,"value":0}]}
    })");
    auto parsed = ParseVectorTimelineScene(
        { { "fading cover", nlohmann::json { { "point2", constant } } } }, origin);
    ASSERT_NE(parsed, nullptr);
    ASSERT_NE(parsed->runtime, nullptr);
    const auto* values = LayerConstants(*parsed, "fading cover");
    ASSERT_NE(values, nullptr);
    ASSERT_TRUE(values->contains("u_Point2"));
    EXPECT_FLOAT_EQ(values->at("u_Point2")[0], 0.75f);
    parsed->runtime->Tick(1.0 / 60.0);
    parsed->runtime->Tick(1.0);
    EXPECT_FLOAT_EQ(values->at("u_Point2")[0], 0.25f) << "the constant's own timeline never played";
    EXPECT_EQ(parsed->runtime->scriptErrorCount(), 0u);
}

nlohmann::json SharedClockConstants(const char* root_mode) {
    const std::string root = std::string(R"({
        "options":{"fps":30,"length":60,"mode":")") + root_mode + R"(","name":"fold"},
        "c0":[{"frame":0,"value":0},{"frame":60,"value":1}]
    })";
    return nlohmann::json {
        // A short looping child must follow the parent's clock instead of
        // restarting on its own length every 15 frames.
        { "point1", VectorConstant({ 9.0f, 9.0f }, R"({
            "options":{"fps":30,"length":15,"mode":"loop","parent":{"key":"point2"}},
            "c0":[{"frame":0,"value":0},{"frame":15,"value":1}],
            "c1":[{"frame":0,"value":0},{"frame":15,"value":2}]
        })") },
        { "point2", VectorConstant({ 0.0f, 0.625f }, root.c_str()) },
    };
}

TEST(SceneSchema, SharedVectorTimelineWrapsOnlyOnTheParentClock) {
    for (const char* mode : { "single", "loop" }) {
        auto parsed = ParseVectorTimelineScene({ { "fold page", SharedClockConstants(mode) } });
        ASSERT_NE(parsed, nullptr);
        ASSERT_NE(parsed->runtime, nullptr);
        const auto* values = LayerConstants(*parsed, "fold page");
        ASSERT_NE(values, nullptr);
        EXPECT_FLOAT_EQ(values->at("u_Point1")[0], 0.0f);
        // The parent animates one component; the other keeps its own value.
        EXPECT_FLOAT_EQ(values->at("u_Point2")[1], 0.625f);
        parsed->runtime->Tick(1.0);
        EXPECT_FLOAT_EQ(values->at("u_Point1")[0], 1.0f);
        EXPECT_FLOAT_EQ(values->at("u_Point1")[1], 2.0f);
        EXPECT_FLOAT_EQ(values->at("u_Point2")[0], 0.5f);
        EXPECT_FLOAT_EQ(values->at("u_Point2")[1], 0.625f);
        parsed->runtime->Tick(0.5);
        EXPECT_FLOAT_EQ(values->at("u_Point1")[0], 1.0f);
        EXPECT_FLOAT_EQ(values->at("u_Point1")[1], 2.0f);
        auto* clock = parsed->runtime->FindScalarAnimation("fold page", "fold");
        ASSERT_NE(clock, nullptr);
        clock->SetFrame(10.0);
        parsed->runtime->Tick(0.0);
        EXPECT_NEAR(values->at("u_Point1")[0], 2.0f / 3.0f, 1e-6);
        EXPECT_NEAR(values->at("u_Point1")[1], 4.0f / 3.0f, 1e-6);
        clock->SetFrame(45.0);
        parsed->runtime->Tick(0.5);
        const bool looping = std::string_view(mode) == "loop";
        EXPECT_FLOAT_EQ(values->at("u_Point1")[0], looping ? 0.0f : 1.0f);
        EXPECT_FLOAT_EQ(values->at("u_Point1")[1], looping ? 0.0f : 2.0f);
        if (! looping) {
            clock->Play();
            parsed->runtime->Tick(0.0);
            EXPECT_FLOAT_EQ(values->at("u_Point1")[0], 0.0f);
            EXPECT_FLOAT_EQ(values->at("u_Point1")[1], 0.0f);
        }
    }
}

TEST(SceneSchema, UnrelatedAndBrokenVectorTimelinesKeepTheirOwnConstants) {
    auto parsed = ParseVectorTimelineScene({
        { "fold page", PausedFoldConstants() },
        // The same constant name in another pass is a different parameter.
        { "free page", nlohmann::json {
              { "point1", VectorConstant({ 0.375f, 0.875f }, R"({
                  "options":{"fps":30,"length":3,"mode":"single"},
                  "c0":[{"frame":0,"value":0.875},{"frame":3,"value":0.125}],
                  "c1":[{"frame":0,"value":0.875},{"frame":3,"value":0.875}]
              })") },
          } },
        { "cyclic page", nlohmann::json {
              { "point1", VectorConstant({ 9.0f, 0.25f }, R"({
                  "options":{"fps":30,"length":3,"mode":"single","parent":{"key":"point2"}},
                  "c0":[{"frame":0,"value":0.5},{"frame":3,"value":0.125}]
              })") },
              { "point2", VectorConstant({ 9.0f, 9.0f }, R"({
                  "options":{"fps":30,"length":3,"mode":"single","parent":{"key":"point1"}},
                  "c0":[{"frame":0,"value":0.25},{"frame":3,"value":0.75}],
                  "c1":[{"frame":0,"value":0.5},{"frame":3,"value":0.75}]
              })") },
          } },
        { "orphan page", nlohmann::json {
              { "point1", VectorConstant({ 9.0f, 9.0f }, R"({
                  "options":{"fps":30,"length":3,"mode":"single","parent":{"key":"point9"}},
                  "c0":[{"frame":0,"value":0.25},{"frame":3,"value":0.75}],
                  "c1":[{"frame":0,"value":0.5},{"frame":3,"value":0.75}]
              })") },
          } },
    });
    ASSERT_NE(parsed, nullptr);
    ASSERT_NE(parsed->runtime, nullptr);
    const auto* fold   = LayerConstants(*parsed, "fold page");
    const auto* free   = LayerConstants(*parsed, "free page");
    const auto* cyclic = LayerConstants(*parsed, "cyclic page");
    const auto* orphan = LayerConstants(*parsed, "orphan page");
    ASSERT_NE(fold, nullptr);
    ASSERT_NE(free, nullptr);
    ASSERT_NE(cyclic, nullptr);
    ASSERT_NE(orphan, nullptr);

    parsed->runtime->Tick(5.0);
    // Its own unpaused timeline ran to the end instead of joining the paused group.
    EXPECT_FLOAT_EQ(free->at("u_Point1")[0], 0.125f);
    EXPECT_FLOAT_EQ(fold->at("u_Point1")[0], 0.875f);
    // Broken relations freeze on their first key and keep unanimated components.
    EXPECT_FLOAT_EQ(cyclic->at("u_Point1")[0], 0.5f);
    EXPECT_FLOAT_EQ(cyclic->at("u_Point1")[1], 0.25f);
    EXPECT_FLOAT_EQ(cyclic->at("u_Point2")[0], 0.25f);
    EXPECT_FLOAT_EQ(cyclic->at("u_Point2")[1], 0.5f);
    EXPECT_FLOAT_EQ(orphan->at("u_Point1")[0], 0.25f);
    EXPECT_FLOAT_EQ(orphan->at("u_Point1")[1], 0.5f);
}

std::vector<std::string>* captured_parse_errors = nullptr;

void CaptureParseErrors(int level, const char*, int, const char* message) {
    if (level == LOGLEVEL_ERROR && captured_parse_errors != nullptr) {
        captured_parse_errors->push_back(message == nullptr ? "" : message);
    }
}

std::vector<std::string> ParseVectorTimelineErrors(
    const std::vector<std::pair<std::string, nlohmann::json>>& layers) {
    std::vector<std::string> logs;
    captured_parse_errors = &logs;
    SetWallpaperLogCallback(CaptureParseErrors);
    auto parsed = ParseVectorTimelineScene(layers);
    SetWallpaperLogCallback(nullptr);
    captured_parse_errors = nullptr;
    EXPECT_NE(parsed, nullptr);
    return logs;
}

nlohmann::json OrphanConstant(const char* parent_key, float first_key) {
    const std::string animation = std::string(R"({
        "options":{"fps":30,"length":3,"mode":"single","parent":{"key":")") + parent_key + R"("}},
        "c0":[{"frame":0,"value":)" + std::to_string(first_key) + R"(},{"frame":3,"value":0.75}]
    })";
    return VectorConstant({ 9.0f, 9.0f }, animation.c_str());
}

TEST(SceneSchema, OneBrokenVectorTimelineGroupIsReportedOnce) {
    // Two constants naming the same unusable parent are one broken group.
    const auto shared_parent = ParseVectorTimelineErrors({
        { "orphan page", nlohmann::json {
              { "point1", OrphanConstant("point9", 0.25f) },
              { "point2", OrphanConstant("point9", 0.5f) },
          } },
    });
    EXPECT_EQ(shared_parent.size(), 1u);
    // Two unusable parents are two groups, so neither is silently swallowed.
    const auto separate_parents = ParseVectorTimelineErrors({
        { "orphan page", nlohmann::json {
              { "point1", OrphanConstant("point8", 0.25f) },
              { "point2", OrphanConstant("point9", 0.5f) },
          } },
    });
    EXPECT_EQ(separate_parents.size(), 2u);
}

TEST(SceneSchema, ScriptedMaterialConstantsKeepTheComponentsTheShaderDeclares) {
    // A script that swaps the components only produces the authored numbers when
    // it is handed a vector. Reaching it as a string yields NaN on `.x`/`.y`.
    nlohmann::json swapped { { "value", nlohmann::json::array({ 0.125f, 0.25f }) } };
    swapped["script"] = R"JS(
export function update(value) { return new Vec2(value.y, value.x); }
)JS";
    nlohmann::json doubled { { "value", nlohmann::json::array({ 0.5f, 0.75f }) } };
    doubled["script"] = R"JS(
export function update(value) { return value; }
)JS";
    auto parsed = ParseVectorTimelineScene({
        { "scripted page", nlohmann::json { { "point1", swapped }, { "point2", doubled } } },
    });
    ASSERT_NE(parsed, nullptr);
    ASSERT_NE(parsed->runtime, nullptr);
    const auto* values = LayerConstants(*parsed, "scripted page");
    ASSERT_NE(values, nullptr);
    ASSERT_TRUE(values->contains("u_Point1"));

    parsed->runtime->Tick(1.0 / 60.0);
    ASSERT_EQ(values->at("u_Point1").size(), 2u);
    EXPECT_FLOAT_EQ(values->at("u_Point1")[0], 0.25f);
    EXPECT_FLOAT_EQ(values->at("u_Point1")[1], 0.125f);
    parsed->runtime->Tick(1.0 / 60.0);
    EXPECT_FLOAT_EQ(values->at("u_Point1")[0], 0.125f);
    EXPECT_FLOAT_EQ(values->at("u_Point1")[1], 0.25f);
    // A script that returns its input unchanged still uploads both components.
    ASSERT_EQ(values->at("u_Point2").size(), 2u);
    EXPECT_FLOAT_EQ(values->at("u_Point2")[0], 0.5f);
    EXPECT_FLOAT_EQ(values->at("u_Point2")[1], 0.75f);
    EXPECT_EQ(parsed->runtime->scriptErrorCount(), 0u);
}

TEST(SceneSchema, ParserRegistersEveryVideoTextureInImageMaterialForLayerControls) {
    auto files = std::map<std::string, std::string> {};
    AddMultiVideoImageSceneFiles(files);
    fs::VFS vfs;
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id = "multi-video-image",
          .project_properties = &properties,
    };

    auto parsed = parser.Parse(request, BasicImageSceneJson(), vfs, sound_manager);

    ASSERT_NE(parsed, nullptr);
    ASSERT_NE(parsed->runtime, nullptr);
    EXPECT_TRUE(parsed->runtime->PauseNodeVideoTexture("video image"));
    EXPECT_TRUE(parsed->runtime->SetNodeVideoTextureCurrentTime("video image", 7.5));
    EXPECT_TRUE(parsed->runtime->SetNodeVideoTextureRate("video image", 0.25f));

    const auto diffuse = parsed->runtime->ResolveVideoPlaybackState("diffuse.tex", 99.0);
    EXPECT_TRUE(diffuse.paused);
    EXPECT_FLOAT_EQ(diffuse.rate, 0.25f);
    EXPECT_DOUBLE_EQ(diffuse.scene_elapsed_seconds, 7.5);

    const auto mask = parsed->runtime->ResolveVideoPlaybackState("mask.tex", 99.0);
    EXPECT_TRUE(mask.paused);
    EXPECT_FLOAT_EQ(mask.rate, 0.25f);
    EXPECT_DOUBLE_EQ(mask.scene_elapsed_seconds, 7.5);
}

TEST(SceneSchema, ParserUnregistersRuntimeNodeWhenImageMaterialFailsToLoad) {
    auto files = std::map<std::string, std::string> {
        { "/valid.json", R"({"width":64,"height":32,"material":"valid_mat.json"})" },
        { "/image.json", R"({"width":64,"height":32,"material":"mat.json"})" },
        { "/valid_mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"validimage","textures":["a.tex"]}]})" },
        { "/shaders/validimage.vert",
          R"(attribute vec3 a_Position;
void main() {
  gl_Position = vec4(a_Position, 1.0);
}
)" },
        { "/shaders/validimage.frag",
          R"(void main() {
  gl_FragColor = vec4(1.0);
}
)" },
        { "/mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"brokenimage","textures":["a.tex"]}]})" },
        { "/shaders/brokenimage.vert",
          R"(attribute vec3 a_Position;
void main() {
  gl_Position = vec4(a_Position, 1.0);
}
)" },
        { "/shaders/brokenimage.frag",
          R"(this is not valid GLSL
)" },
        { "/materials/a.tex.tex", "" },
    };
    fs::VFS vfs;
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "failed-dynamic-image",
          .project_properties = &properties,
    };

    auto parsed = parser.Parse(request, DynamicImageSceneJson(), vfs, sound_manager);

    ASSERT_NE(parsed, nullptr);
    ASSERT_NE(parsed->runtime, nullptr);
    EXPECT_EQ(parsed->runtime->sceneScriptCount(), 1u);
    EXPECT_TRUE(parsed->runtime->HasNodeNamed("valid scripted image"));
    EXPECT_FALSE(parsed->runtime->HasNodeNamed("failed dynamic image"));
    parsed->runtime->Tick(1.0 / 60.0);
}

TEST(SceneSchema, ParserRemovesQueuedSceneScriptWhenImageMaterialFailsToLoad) {
    auto files = std::map<std::string, std::string> {
        { "/image.json", R"({"width":64,"height":32,"material":"mat.json"})" },
        { "/mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"brokenimage","textures":["a.tex"]}]})" },
        { "/shaders/brokenimage.vert",
          R"(attribute vec3 a_Position;
void main() {
  gl_Position = vec4(a_Position, 1.0);
}
)" },
        { "/shaders/brokenimage.frag",
          R"(this is not valid GLSL
)" },
        { "/materials/a.tex.tex", "" },
    };
    fs::VFS vfs;
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "failed-scene-script-image",
          .project_properties = &properties,
    };
    const auto scene_json = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":313,"name":"failed scene-script image","image":"image.json",
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],
         "visible":{"value":true,"script":"thisScene.on('cursorClick', function() { thisScene.getLayer('failed scene-script image').visible = false; });"}}
      ]
    })";

    auto parsed = parser.Parse(request, scene_json, vfs, sound_manager);

    ASSERT_NE(parsed, nullptr);
    ASSERT_NE(parsed->runtime, nullptr);
    EXPECT_FALSE(parsed->runtime->HasNodeNamed("failed scene-script image"));
    EXPECT_EQ(parsed->runtime->sceneScriptCount(), 0u);
}

TEST(SceneSchema, RuntimeScopedUnregisterPreservesExistingSameNameNode) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto previous_node = std::make_shared<SceneNode>(
        Eigen::Vector3f(25.0f, 0.0f, 0.0f),
        Eigen::Vector3f::Ones(),
        Eigen::Vector3f::Zero(),
        "runtime target");
    auto failed_node = std::make_shared<SceneNode>(
        Eigen::Vector3f(50.0f, 0.0f, 0.0f),
        Eigen::Vector3f::Ones(),
        Eigen::Vector3f::Zero(),
        "runtime target");

    runtime->RegisterNode("runtime target", previous_node.get());
    const auto previous = runtime->CaptureNodeRegistration("runtime target");
    runtime->RegisterNode("runtime target", failed_node.get());
    ASSERT_FLOAT_EQ(runtime->NodeTranslate("runtime target").x(), 50.0f);
    runtime->RollbackNodeRegistration("runtime target", failed_node.get(), previous);

    EXPECT_TRUE(runtime->HasNodeNamed("runtime target"));
    EXPECT_FLOAT_EQ(runtime->NodeTranslate("runtime target").x(), 25.0f);

    runtime->RegisterNode("runtime target", failed_node.get());
    runtime->RollbackNodeRegistration("runtime target", failed_node.get(), nullptr);
    EXPECT_FALSE(runtime->HasNodeNamed("runtime target"));
}

TEST(SceneSchema, ParserUnregistersRuntimeNodeWhenParticleMaterialFailsToLoad) {
    auto files = std::map<std::string, std::string> {
        { "/valid_particle.json",
          R"({"emitter":[{"name":"emit","id":1}],"material":"valid_mat.json","maxcount":4,"starttime":0})" },
        { "/particle.json",
          R"({"emitter":[{"name":"emit","id":1}],"material":"mat.json","maxcount":4,"starttime":0})" },
        { "/valid_mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"validparticle","textures":["a.tex"]}]})" },
        { "/shaders/validparticle.vert",
          R"(attribute vec3 a_Position;
void main() {
  gl_Position = vec4(a_Position, 1.0);
}
)" },
        { "/shaders/validparticle.frag",
          R"(void main() {
  gl_FragColor = vec4(1.0);
}
)" },
        { "/mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"brokenparticle","textures":["a.tex"]}]})" },
        { "/shaders/brokenparticle.vert",
          R"(attribute vec3 a_Position;
void main() {
  gl_Position = vec4(a_Position, 1.0);
}
)" },
        { "/shaders/brokenparticle.frag",
          R"(this is not valid GLSL
)" },
        { "/materials/a.tex.tex", "" },
    };
    fs::VFS vfs;
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "failed-dynamic-particle",
          .project_properties = &properties,
    };

    auto parsed = parser.Parse(request, DynamicParticleSceneJson(), vfs, sound_manager);

    ASSERT_NE(parsed, nullptr);
    ASSERT_NE(parsed->runtime, nullptr);
    EXPECT_EQ(parsed->runtime->sceneScriptCount(), 1u);
    EXPECT_TRUE(parsed->runtime->HasNodeNamed("valid scripted particle"));
    EXPECT_FALSE(parsed->runtime->HasNodeNamed("failed dynamic particle"));
    parsed->runtime->Tick(1.0 / 60.0);
}

TEST(SceneSchema, RuntimeProjectPropertyResolutionStillWorks) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .project_properties = {
            { "speed", RuntimeScalarValue::Float(2.5f) },
        },
    });
    ASSERT_NE(runtime, nullptr);

    auto* value = runtime->FindPropertyValue("speed");
    ASSERT_NE(value, nullptr);
    EXPECT_FLOAT_EQ(value->getFloat(), 2.5f);
}

TEST(SceneSchema, SchemecolorUserPropertyUpdatesSceneClearColor) {
    fs::VFS vfs;
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::map<std::string, std::string> {})));
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties {
          { "background_color", RuntimeScalarValue::String("0.25 0.5 0.75") },
    };
    SceneParseRequest request {
        .scene_id           = "schemecolor-clearcolor",
        .project_properties = &properties,
    };
    const auto scene_json = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":{"user":"background_color","value":"0.1 0.2 0.3"},
        "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": []
    })";

    auto parsed = parser.Parse(request, scene_json, vfs, sound_manager);

    ASSERT_NE(parsed, nullptr);
    ASSERT_NE(parsed->runtime, nullptr);
    EXPECT_FLOAT_EQ(parsed->clearColor[0], 0.25f);
    EXPECT_FLOAT_EQ(parsed->clearColor[1], 0.5f);
    EXPECT_FLOAT_EQ(parsed->clearColor[2], 0.75f);

    parsed->runtime->ApplyProjectPropertyOverride({
        { "background_color", RuntimeScalarValue::String("0.5 0.25 0.125") },
    });

    EXPECT_FLOAT_EQ(parsed->clearColor[0], 0.5f);
    EXPECT_FLOAT_EQ(parsed->clearColor[1], 0.25f);
    EXPECT_FLOAT_EQ(parsed->clearColor[2], 0.125f);
}

#include <array>
#include <chrono>
#include <condition_variable>
#include <filesystem>
#include <mutex>
#include <thread>
#include "Core/RendererCounters.hpp"
#include "SceneWallpaper.hpp"
#include "Scene/Scene.h"
#if defined(__APPLE__)
#include "Platform/Apple/SceneWallpaperBindings.h"
#endif

namespace {
struct NativePointerObservation {
    std::mutex mutex;
    std::condition_variable changed;
    std::vector<bool> values;
    int drops { 0 };
    int first_frames { 0 };
    bool block { false };
    bool released { false };

    void Observe(bool accepts) {
        std::unique_lock lock(mutex);
        values.push_back(accepts);
        changed.notify_all();
        if (block) changed.wait(lock, [&] { return released; });
    }
    void Release() {
        std::lock_guard lock(mutex);
        released = true;
        changed.notify_all();
    }
    bool Wait(std::size_t count, int drop_count = 0) {
        std::unique_lock lock(mutex);
        return changed.wait_for(lock, std::chrono::seconds(5), [&] {
            return values.size() >= count && drops >= drop_count;
        });
    }
    std::vector<bool> Values() {
        std::lock_guard lock(mutex);
        return values;
    }
    int Drops() {
        std::lock_guard lock(mutex);
        return drops;
    }
};

std::shared_ptr<wallpaper::Scene> MakePointerCommitScene(bool accepts) {
    auto scene = std::make_shared<wallpaper::Scene>();
    scene->activeCamera = nullptr;
    scene->sceneGraph.reset();
    scene->accepts_pointer_input = accepts;
    return scene;
}
}

TEST(SceneSchema, PointerCapabilityFollowsActualCommitsWithoutFirstFrame) {
    NativePointerObservation observation;
    NativePointerObservation replacement;
    wallpaper::SceneWallpaper wallpaper;
    ASSERT_TRUE(wallpaper.init());
    wallpaper.setPropertyObject(wallpaper::PROPERTY_FIRST_FRAME_CALLBACK,
        std::make_shared<wallpaper::FirstFrameCallback>([&] {
            std::lock_guard lock(observation.mutex);
            ++observation.first_frames;
        }));
    wallpaper.setPropertyObject(wallpaper::PROPERTY_POINTER_INPUT_CALLBACK,
        std::make_shared<wallpaper::PointerInputCallback>([&](bool accepts) {
            observation.Observe(accepts);
        }));
    ASSERT_TRUE(observation.Wait(1));
    EXPECT_EQ(observation.Values(), (std::vector<bool> { true }));

    auto video = MakePointerCommitScene(false);
    wallpaper::SceneWallpaperInputTestAccess::PostScene(wallpaper, video);
    ASSERT_TRUE(observation.Wait(2));
    EXPECT_EQ(observation.Values(), (std::vector<bool> { true, false }));

    // Configuration is not a scene commit; replacement is a main-looper barrier.
    wallpaper.setPropertyBool(wallpaper::PROPERTY_FORCE_SHADER_REFRESH, true);
    wallpaper.setPropertyObject(wallpaper::PROPERTY_POINTER_INPUT_CALLBACK,
        std::make_shared<wallpaper::PointerInputCallback>([&](bool accepts) {
            replacement.Observe(accepts);
        }));
    ASSERT_TRUE(replacement.Wait(1));
    EXPECT_EQ(observation.Values(), (std::vector<bool> { true, false }));
    EXPECT_EQ(replacement.Values(), (std::vector<bool> { false }));

    auto scene = std::make_shared<wallpaper::Scene>();
    scene->activeCamera = nullptr;
    scene->sceneGraph.reset();
    scene->textures["video-texture"].isVideo = true;
    ASSERT_TRUE(scene->accepts_pointer_input);
    wallpaper::SceneWallpaperInputTestAccess::PostScene(wallpaper, scene);
    ASSERT_TRUE(replacement.Wait(2));
    wallpaper::SceneWallpaperInputTestAccess::PostScene(wallpaper, scene);
    ASSERT_TRUE(replacement.Wait(3));
    wallpaper::SceneWallpaperInputTestAccess::PostScene(wallpaper, video);
    ASSERT_TRUE(replacement.Wait(4));
    wallpaper::SceneWallpaperInputTestAccess::PostScene(wallpaper, nullptr);
    ASSERT_TRUE(replacement.Wait(5));
    wallpaper.shutdown();
    EXPECT_EQ(replacement.Values(), (std::vector<bool> { false, true, true, false, true }));
    EXPECT_FALSE(video->first_frame_ok);
    EXPECT_FALSE(scene->first_frame_ok);
    std::lock_guard lock(observation.mutex);
    EXPECT_EQ(observation.first_frames, 0);
}

namespace {
/// Parses `objects` over the shared scene files plus audio-reading variants of
/// the image material and particle. Keeps the VFS and sound manager alive for
/// as long as the scene is used.
struct AudioProbeScene {
    fs::VFS                           vfs;
    audio::SoundManager               sound_manager;
    ProjectProperties                 properties;
    std::shared_ptr<wallpaper::Scene> scene;

    explicit AudioProbeScene(std::string_view objects) {
        MountSceneFiles(vfs);
        auto files = std::map<std::string, std::string> {
            { "/audio_image.json", R"({"width":64,"height":32,"material":"audio_mat.json"})" },
            { "/audio_mat.json",
              R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled",)"
              R"("depthwrite":"disabled","shader":"genericimage","textures":["a.tex"],)"
              R"("combos":{"AUDIOPROCESSING":1}}]})" },
            { "/audio_particle.json",
              R"({"emitter":[{"name":"boxrandom","id":1,"audioprocessingmode":1}],)"
              R"("material":"mat.json","maxcount":4,"starttime":0})" },
        };
        EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
        // With project properties, as `loadScene` parses: that is what gives
        // the scene a runtime, which is where the requirement lives.
        scene = WPSceneParser().Parse(SceneParseRequest {
                                          .scene_id           = "audio-probe",
                                          .project_properties = &properties,
                                      },
                                      std::string(R"({
          "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
          "general": {
            "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
            "clearcolor":[0,0,0], "cameraparallax":false,
            "cameraparallaxamount":0, "cameraparallaxdelay":0,
            "cameraparallaxmouseinfluence":0,
            "orthogonalprojection":{"width":640,"height":360}
          },
          "objects": )") + std::string(objects) + "}",
                                      vfs,
                                      sound_manager);
    }

    bool RequiresAudio() const {
        return scene != nullptr && scene->runtime != nullptr &&
               scene->runtime->SceneRequiresAudioResponse();
    }
};

constexpr std::string_view kPlainImageObjects =
    R"([{"id":1,"name":"plain","image":"image.json","visible":true}])";
}

TEST(SceneSchema, AnEmitterOriginScalesWithItsLayerUnlessTheFileIsWorldspace) {
    // A particle system lives in its layer's space: Wallpaper Engine draws it
    // through the layer's model matrix, which scales the emitter origin along
    // with every position and size the system makes. A worldspace file is drawn
    // through no such matrix: the origin is added unscaled, in world units, so
    // the drawn place is the layer's position plus the authored 50, not 100.
    for (const auto& [flags, world_y] : { std::pair<int, float> { 0, 280.0f }, { 1, 230.0f } }) {
        SCOPED_TRACE(flags);
        fs::VFS vfs;
        MountSceneFiles(vfs);
        auto files = std::map<std::string, std::string> {
            { "/still_particle.json",
              R"({"emitter":[{"name":"boxrandom","id":1,"origin":"0 50 0",)"
              R"("distancemin":"0 0 0","distancemax":"0 0 0","speedmin":0,"speedmax":0,)"
              R"("rate":100,"instantaneous":1}],)"
              R"("initializer":[{"name":"lifetimerandom","min":10,"max":10}],)"
              R"("material":"mat.json","maxcount":1,"starttime":0,"flags":)" +
                  std::to_string(flags) + "}" },
        };
        ASSERT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
        audio::SoundManager sound_manager;
        auto scene = WPSceneParser().Parse(
            SceneParseRequest { .scene_id = "emitter-origin" },
            R"({"camera":{"center":[0,0,0],"eye":[0,0,1],"up":[0,1,0]},
                "general":{"clearcolor":[0,0,0],"cameraparallax":false,"bloom":false,
                           "orthogonalprojection":{"width":640,"height":360}},
                "objects":[{"id":1,"name":"snow","particle":"still_particle.json",
                            "origin":[320,180,0],"scale":[2,2,1],"visible":true}]})",
            vfs, sound_manager);
        ASSERT_NE(scene, nullptr);
        ASSERT_FALSE(scene->paritileSys->subsystems.empty());
        scene->frameTime = 1.0 / 60.0;
        scene->paritileSys->Emitt();
        const auto& subsystem = *scene->paritileSys->subsystems.front();
        ASSERT_FALSE(subsystem.Instances().empty());
        const auto particles = subsystem.Instances().front()->Particles();
        ASSERT_FALSE(particles.empty());
        const auto layer = FindRootChildByName(*scene, "snow");
        ASSERT_NE(layer, nullptr);
        layer->UpdateTrans();
        const auto& at = particles.front().position;
        const Eigen::Vector3d drawn =
            (layer->RenderTrans() * Eigen::Vector4d(at.x(), at.y(), at.z(), 1.0)).head<3>();
        EXPECT_NEAR(drawn.x(), 320.0, 1.0e-3);
        EXPECT_NEAR(drawn.y(), world_y, 1.0e-3);
    }
}

TEST(SceneSchema, AWorldspaceLayerStretchesItsSpawnsButNotTheSpeedOfItsParticles) {
    // A stretched layer (24 times wider than tall) carries a particle file whose
    // emitter sends each particle out from its spawn point at 60 units a second.
    // A layer-space file draws the particles and their motion through the
    // layer's matrix, so the speed is stretched along with everything else (about
    // 17 times faster on screen for a particle that leaves at 45 degrees), while a
    // worldspace file is in scene units: the spawn offset is stretched, the
    // particle heads along it, and goes at the speed the file wrote.
    constexpr double kAlong = 0.70710678118654752;
    struct Case {
        int    flags;
        double first_x;
        double step_length;
    };
    // After the first step the particle has gone a sixtieth of its speed.
    // Layer space: 5 units out along the diagonal, 0.7071 further on each axis,
    // all drawn 24 wide. Worldspace: 120 out along x (24 * 5), and the unit step
    // along the heading (120, 5), which is 0.99913 on x.
    const double heading_x = 120.0 / std::hypot(120.0, 5.0);
    for (const auto& [flags, first_x, step_length] :
         { Case { 0, 24.0 * (5.0 + kAlong), kAlong * std::hypot(24.0, 1.0) },
           Case { 1, 120.0 + heading_x, 1.0 } }) {
        SCOPED_TRACE(flags);
        fs::VFS vfs;
        MountSceneFiles(vfs);
        auto files = std::map<std::string, std::string> {
            { "/stretched_particle.json",
              R"({"emitter":[{"name":"boxrandom","id":1,"origin":"0 0 0","directions":"1 1 0",)"
              R"("distancemin":"5 5 0","distancemax":"5 5 0","speedmin":60,"speedmax":60,)"
              R"("rate":100,"instantaneous":1}],)"
              R"("initializer":[{"name":"lifetimerandom","min":10,"max":10}],)"
              R"("operator":[{"name":"movement","id":2}],)"
              R"("material":"mat.json","maxcount":1,"starttime":0,"flags":)" +
                  std::to_string(flags) + "}" },
        };
        ASSERT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
        audio::SoundManager sound_manager;
        auto scene = WPSceneParser().Parse(
            SceneParseRequest { .scene_id = "stretched" },
            R"({"camera":{"center":[0,0,0],"eye":[0,0,1],"up":[0,1,0]},
                "general":{"clearcolor":[0,0,0],"cameraparallax":false,"bloom":false,
                           "orthogonalprojection":{"width":640,"height":360}},
                "objects":[{"id":1,"name":"haze","particle":"stretched_particle.json",
                            "origin":[320,180,0],"scale":[24,1,1],"visible":true}]})",
            vfs, sound_manager);
        ASSERT_NE(scene, nullptr);
        ASSERT_FALSE(scene->paritileSys->subsystems.empty());
        const auto layer = FindRootChildByName(*scene, "haze");
        ASSERT_NE(layer, nullptr);
        scene->frameTime = 1.0 / 60.0;
        const auto drawn_position = [&] {
            scene->paritileSys->Emitt();
            const auto& subsystem = *scene->paritileSys->subsystems.front();
            const auto  particles = subsystem.Instances().front()->Particles();
            EXPECT_FALSE(particles.empty());
            layer->UpdateTrans();
            const auto& at = particles.front().position;
            return Eigen::Vector3d((layer->RenderTrans() * Eigen::Vector4d(at.x(), at.y(), at.z(), 1.0))
                                       .head<3>());
        };
        const auto first  = drawn_position();
        const auto second = drawn_position();
        EXPECT_NEAR(std::abs(first.x() - 320.0), first_x, 1.0e-3);
        EXPECT_NEAR((second - first).norm(), step_length, 1.0e-3);
    }
}

TEST(SceneSchema, AChildSystemOriginScalesWithItsLayerUnlessItsParentIsWorldspace) {
    // A child system's matrix, with the origin as its translation, is composed
    // with its parent system's, and a layer-space parent is drawn through the
    // layer's model matrix: the offset scales along with the rest. The
    // particles of a worldspace parent are already in world units, so the child
    // hangs at the authored offset unscaled, held here at half its value under
    // a layer scaled by two. An event child follows its parent's flag alone,
    // whatever its own file says. A static child whose own file is worldspace is
    // not settled by any reference scene and keeps the authored offset in world
    // units, as it did before the origin was scaled.
    struct Case {
        const char* type;
        int         parent_flags;
        int         child_flags;
        float       world_y;
    };
    for (const auto& [type, parent_flags, child_flags, world_y] : {
             Case { "static", 0, 0, 280.0f },
             Case { "static", 0, 1, 230.0f },
             Case { "static", 1, 0, 230.0f },
             Case { "static", 1, 1, 230.0f },
             Case { "eventfollow", 0, 0, 280.0f },
             Case { "eventfollow", 0, 1, 280.0f },
             Case { "eventfollow", 1, 0, 230.0f },
             Case { "eventfollow", 1, 1, 230.0f },
         }) {
        SCOPED_TRACE(std::string(type) + " " + std::to_string(parent_flags) + "/" +
                     std::to_string(child_flags));
        const auto still = [](int flags, std::string_view children) {
            return std::string(R"({"emitter":[{"name":"boxrandom","id":1,"origin":"0 0 0",)"
                               R"("distancemin":"0 0 0","distancemax":"0 0 0","speedmin":0,)"
                               R"("speedmax":0,"rate":100,"instantaneous":1}],)"
                               R"("initializer":[{"name":"lifetimerandom","min":10,"max":10}],)"
                               R"("material":"mat.json","maxcount":1,"starttime":0,"flags":)") +
                   std::to_string(flags) + std::string(children) + "}";
        };
        fs::VFS vfs;
        MountSceneFiles(vfs);
        auto files = std::map<std::string, std::string> {
            { "/parent_particle.json",
              still(parent_flags,
                    std::string(R"(,"children":[{"name":"child_particle.json","type":")") + type +
                        R"(","maxcount":1,"origin":"0 50 0"}])") },
            { "/child_particle.json", still(child_flags, "") },
        };
        ASSERT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
        audio::SoundManager sound_manager;
        auto scene = WPSceneParser().Parse(
            SceneParseRequest { .scene_id = "child-origin" },
            R"({"camera":{"center":[0,0,0],"eye":[0,0,1],"up":[0,1,0]},
                "general":{"clearcolor":[0,0,0],"cameraparallax":false,"bloom":false,
                           "orthogonalprojection":{"width":640,"height":360}},
                "objects":[{"id":1,"name":"snow","particle":"parent_particle.json",
                            "origin":[320,180,0],"scale":[2,2,1],"visible":true}]})",
            vfs, sound_manager);
        ASSERT_NE(scene, nullptr);
        const auto layer = FindRootChildByName(*scene, "snow");
        ASSERT_NE(layer, nullptr);
        ASSERT_EQ(layer->GetChildren().size(), 1u);
        const auto& child_node = layer->GetChildren().front();
        child_node->UpdateTrans();
        const Eigen::Vector3d placed =
            (child_node->ModelTrans() * Eigen::Vector4d(0, 0, 0, 1)).head<3>();
        EXPECT_NEAR(placed.x(), 320.0, 1.0e-3);
        EXPECT_NEAR(placed.y(), world_y, 1.0e-3);
    }
}

TEST(SceneSchema, AudioRequirementComesOnlyFromContentThatReadsAudio) {
    AudioProbeScene plain(kPlainImageObjects);
    ASSERT_NE(plain.scene, nullptr);
    ASSERT_NE(plain.scene->runtime, nullptr);
    EXPECT_FALSE(plain.RequiresAudio()) << "an image with an ordinary material reads no audio";
    plain.scene->runtime->Tick(0.5);
    EXPECT_FALSE(plain.RequiresAudio()) << "running the scene must not invent a requirement";

    AudioProbeScene material(
        R"([{"id":1,"name":"bars","image":"audio_image.json","visible":true}])");
    ASSERT_NE(material.scene, nullptr);
    EXPECT_TRUE(material.RequiresAudio()) << "an AUDIOPROCESSING material reads the spectrum";

    AudioProbeScene particle(
        R"([{"id":1,"name":"beat","particle":"audio_particle.json","visible":true}])");
    ASSERT_NE(particle.scene, nullptr);
    EXPECT_TRUE(particle.RequiresAudio()) << "an audio-processing emitter reads the spectrum";

    // A script only reads audio once it asks for buffers, which may be long
    // after the scene was parsed.
    AudioProbeScene script(
        R"([{"id":1,"name":"scripted","image":"image.json","visible":true,
             "origin":{"value":[0,0,0],"script":"export function update(value) { engine.registerAudioBuffers(engine.AUDIO_RESOLUTION_16); return value; }"}}])");
    ASSERT_NE(script.scene, nullptr);
    ASSERT_NE(script.scene->runtime, nullptr);
    EXPECT_FALSE(script.RequiresAudio());
    script.scene->runtime->Tick(0.5);
    EXPECT_TRUE(script.RequiresAudio()) << "registerAudioBuffers reads the spectrum";
}

TEST(SceneSchema, AudioRequirementIsReportedOncePerSceneAndResetByReplacement) {
    NativePointerObservation audio;
    NativePointerObservation commits;
    wallpaper::SceneWallpaper wallpaper;
    ASSERT_TRUE(wallpaper.init());
    const auto observe_commits = [&] {
        wallpaper.setPropertyObject(wallpaper::PROPERTY_POINTER_INPUT_CALLBACK,
            std::make_shared<wallpaper::PointerInputCallback>([&](bool accepts) {
                commits.Observe(accepts);
            }));
    };
    // Every commit reports pointer capability right after the audio
    // requirement, and re-registering replays on the same main looper, so the
    // pointer count doubles as an ordering barrier for audio reports.
    std::size_t barriers = 0;
    const auto barrier = [&] {
        observe_commits();
        ASSERT_TRUE(commits.Wait(++barriers));
    };
    const auto commit = [&](std::shared_ptr<wallpaper::Scene> scene) {
        wallpaper::SceneWallpaperInputTestAccess::PostScene(wallpaper, std::move(scene));
        ASSERT_TRUE(commits.Wait(++barriers));
    };
    wallpaper.setPropertyObject(wallpaper::PROPERTY_AUDIO_REQUIREMENT_CALLBACK,
        std::make_shared<wallpaper::AudioRequirementCallback>([&](bool requires_audio) {
            audio.Observe(requires_audio);
        }));
    ASSERT_TRUE(audio.Wait(1));
    barrier();
    EXPECT_EQ(audio.Values(), (std::vector<bool> { false })) << "installing replays the state";

    AudioProbeScene plain(kPlainImageObjects);
    ASSERT_NE(plain.scene, nullptr);
    commit(plain.scene);
    EXPECT_EQ(audio.Values(), (std::vector<bool> { false }))
        << "a scene that reads no audio never opens the tap";

    AudioProbeScene bars(R"([{"id":1,"name":"bars","image":"audio_image.json","visible":true}])");
    ASSERT_TRUE(bars.RequiresAudio());
    commit(bars.scene);
    EXPECT_EQ(audio.Values(), (std::vector<bool> { false, true }));
    bars.scene->runtime->MarkSceneRequiresAudioResponse();
    barrier();
    EXPECT_EQ(audio.Values(), (std::vector<bool> { false, true }))
        << "a scene that marks again is still one report";

    // Replacing with a scene that reads nothing lowers it, and the old scene's
    // late marks cannot raise it for the new one.
    AudioProbeScene next(kPlainImageObjects);
    commit(next.scene);
    EXPECT_EQ(audio.Values(), (std::vector<bool> { false, true, false }));
    bars.scene->runtime->MarkSceneRequiresAudioResponse();
    barrier();
    EXPECT_EQ(audio.Values(), (std::vector<bool> { false, true, false }));

    // A late mark by the scene now showing -- what a script's
    // registerAudioBuffers does -- raises it exactly once.
    next.scene->runtime->MarkSceneRequiresAudioResponse();
    next.scene->runtime->MarkSceneRequiresAudioResponse();
    barrier();
    EXPECT_EQ(audio.Values(), (std::vector<bool> { false, true, false, true }));

    commit(nullptr);
    wallpaper.shutdown();
    EXPECT_EQ(audio.Values(), (std::vector<bool> { false, true, false, true, false }));
}

#if defined(__APPLE__)
namespace {
struct NativePointerUserData {
    NativePointerObservation* observation;
};
void NativePointerCallback(void* data, bool accepts) {
    static_cast<NativePointerUserData*>(data)->observation->Observe(accepts);
}
void NativeFirstFrameCallback(void* data) {
    auto& observation = *static_cast<NativePointerUserData*>(data)->observation;
    std::lock_guard lock(observation.mutex);
    ++observation.first_frames;
    observation.changed.notify_all();
}
void NativePointerDrop(void* data) {
    std::unique_ptr<NativePointerUserData> owner(static_cast<NativePointerUserData*>(data));
    auto& observation = *owner->observation;
    std::lock_guard lock(observation.mutex);
    ++observation.drops;
    observation.changed.notify_all();
}
struct NativePointerSceneDeleter {
    void operator()(owe_scene_wallpaper* scene) const { owe_scene_wallpaper_delete(scene); }
};
using NativePointerSceneOwner = std::unique_ptr<owe_scene_wallpaper, NativePointerSceneDeleter>;
struct NativePointerReleaseOnExit {
    NativePointerObservation& observation;
    ~NativePointerReleaseOnExit() { observation.Release(); }
};
int RegisterNativePointer(owe_scene_wallpaper* scene, NativePointerObservation& observation) {
    auto data = std::make_unique<NativePointerUserData>();
    data->observation = &observation;
    const int status = owe_scene_wallpaper_set_pointer_input_callback(
        scene, NativePointerCallback, data.get(), NativePointerDrop);
    if (status == 0) data.release();
    return status;
}
int RegisterNativeFirstFrame(owe_scene_wallpaper* scene, NativePointerObservation& observation) {
    auto data = std::make_unique<NativePointerUserData>();
    data->observation = &observation;
    const int status = owe_scene_wallpaper_set_first_frame_callback(
        scene, NativeFirstFrameCallback, data.get(), NativePointerDrop);
    if (status == 0) data.release();
    return status;
}
}

TEST(SceneSchema, PointerCallbackReplacementAndClearRetainInflightUserData) {
    NativePointerObservation first;
    NativePointerObservation second;
    first.block = true;
    owe_scene_wallpaper* raw = nullptr;
    ASSERT_EQ(owe_scene_wallpaper_new(&raw), 0);
    NativePointerSceneOwner scene(raw);
    NativePointerReleaseOnExit release { first };
    ASSERT_EQ(owe_scene_wallpaper_init(scene.get()), 0);
    ASSERT_EQ(RegisterNativePointer(scene.get(), first), 0);
    ASSERT_TRUE(first.Wait(1));
    ASSERT_EQ(RegisterNativePointer(scene.get(), second), 0);
    ASSERT_EQ(owe_scene_wallpaper_set_pointer_input_callback(
        scene.get(), nullptr, nullptr, nullptr), 0);
    EXPECT_EQ(first.Drops(), 0);
    EXPECT_EQ(second.Drops(), 0);
    EXPECT_TRUE(second.Values().empty());
    first.Release();
    ASSERT_TRUE(first.Wait(1, 1));
    ASSERT_TRUE(second.Wait(1, 1));
    ASSERT_EQ(owe_scene_wallpaper_shutdown(scene.get()), 0);
    scene.reset();
    EXPECT_EQ(first.Values(), (std::vector<bool> { true }));
    EXPECT_EQ(second.Values(), (std::vector<bool> { true }));
    EXPECT_EQ(first.Drops(), 1);
    EXPECT_EQ(second.Drops(), 1);
}

TEST(SceneSchema, PointerCallbackShutdownStopsDeliveryAndReleasesOwnershipOnDelete) {
    NativePointerObservation observation;
    NativePointerObservation rejected;
    owe_scene_wallpaper* raw = nullptr;
    ASSERT_EQ(owe_scene_wallpaper_new(&raw), 0);
    NativePointerSceneOwner scene(raw);
    ASSERT_EQ(owe_scene_wallpaper_init(scene.get()), 0);
    ASSERT_EQ(RegisterNativePointer(scene.get(), observation), 0);
    ASSERT_TRUE(observation.Wait(1));
    ASSERT_EQ(owe_scene_wallpaper_shutdown(scene.get()), 0);
    EXPECT_NE(RegisterNativePointer(scene.get(), rejected), 0);
    EXPECT_EQ(rejected.Drops(), 0);
    EXPECT_TRUE(rejected.Values().empty());
    scene.reset();
    EXPECT_EQ(observation.Values(), (std::vector<bool> { true }));
    EXPECT_EQ(observation.Drops(), 1);
    EXPECT_EQ(rejected.Drops(), 0);
}

TEST(SceneSchema, NativeCallbackRegistrationFailureDoesNotConsumeUserData) {
    NativePointerObservation pointer;
    NativePointerObservation first_frame;
    EXPECT_NE(RegisterNativePointer(nullptr, pointer), 0);
    EXPECT_NE(RegisterNativeFirstFrame(nullptr, first_frame), 0);
    owe_scene_wallpaper* raw = nullptr;
    ASSERT_EQ(owe_scene_wallpaper_new(&raw), 0);
    NativePointerSceneOwner scene(raw);
    EXPECT_NE(RegisterNativePointer(scene.get(), pointer), 0);
    EXPECT_NE(RegisterNativeFirstFrame(scene.get(), first_frame), 0);
    scene.reset();
    EXPECT_EQ(pointer.Drops(), 0);
    EXPECT_EQ(first_frame.Drops(), 0);
    EXPECT_TRUE(pointer.Values().empty());
    EXPECT_EQ(first_frame.first_frames, 0);
}

TEST(SceneSchema, FirstFrameCallbackReplacementClearAndShutdownDropExactlyOnce) {
    NativePointerObservation first;
    NativePointerObservation second;
    NativePointerObservation barrier;
    owe_scene_wallpaper* raw = nullptr;
    ASSERT_EQ(owe_scene_wallpaper_new(&raw), 0);
    NativePointerSceneOwner scene(raw);
    ASSERT_EQ(owe_scene_wallpaper_init(scene.get()), 0);
    ASSERT_EQ(RegisterNativeFirstFrame(scene.get(), first), 0);
    ASSERT_EQ(RegisterNativeFirstFrame(scene.get(), second), 0);
    ASSERT_EQ(owe_scene_wallpaper_set_first_frame_callback(
        scene.get(), nullptr, nullptr, nullptr), 0);
    ASSERT_EQ(RegisterNativePointer(scene.get(), barrier), 0);
    ASSERT_TRUE(barrier.Wait(1));
    ASSERT_TRUE(first.Wait(0, 1));
    ASSERT_TRUE(second.Wait(0, 1));
    ASSERT_EQ(owe_scene_wallpaper_shutdown(scene.get()), 0);
    scene.reset();
    EXPECT_EQ(first.Drops(), 1);
    EXPECT_EQ(second.Drops(), 1);
    EXPECT_EQ(barrier.Drops(), 1);
    EXPECT_EQ(first.first_frames, 0);
    EXPECT_EQ(second.first_frames, 0);
}

TEST(SceneSchema, MouseButtonBaselineReconcilesLevelsWithoutInventingOrClearingEdges) {
    using Access = wallpaper::SceneWallpaperInputTestAccess;
    owe_scene_wallpaper* raw = nullptr;
    ASSERT_EQ(owe_scene_wallpaper_new(&raw), 0);
    NativePointerSceneOwner scene(raw);
    auto& native = Access::FromNative(*scene);
    const auto expect_buttons = [&](uint32_t down, uint32_t pressed, uint32_t released) {
        const auto snapshot = Access::ConsumeMouseButtons(native);
        EXPECT_EQ(snapshot.down, down);
        EXPECT_EQ(snapshot.pressed, pressed);
        EXPECT_EQ(snapshot.released, released);
    };

    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 31, true), 0);
    EXPECT_NE(owe_scene_wallpaper_set_mouse_button_baseline(nullptr, 0), 0);
    EXPECT_NE(owe_scene_wallpaper_set_mouse_button_baseline(scene.get(), 0), 0);
    expect_buttons(0x80000000u, 0x80000000u, 0);
    ASSERT_EQ(owe_scene_wallpaper_init(scene.get()), 0);
    ASSERT_EQ(owe_scene_wallpaper_set_mouse_button_baseline(scene.get(), 0), 0);
    expect_buttons(0, 0, 0);

    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 0, true), 0);
    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 0, false), 0);
    ASSERT_EQ(owe_scene_wallpaper_set_mouse_button_baseline(scene.get(), 1), 0);
    expect_buttons(1, 1, 1);
    expect_buttons(1, 0, 0);
    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 0, false), 0);
    expect_buttons(0, 0, 1);

    ASSERT_EQ(owe_scene_wallpaper_set_mouse_button_baseline(scene.get(), 1), 0);
    expect_buttons(1, 0, 0);
    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 0, false), 0);
    expect_buttons(0, 0, 1);

    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 2, true), 0);
    ASSERT_EQ(owe_scene_wallpaper_shutdown(scene.get()), 0);
    EXPECT_NE(owe_scene_wallpaper_set_mouse_button_baseline(scene.get(), 0), 0);
    expect_buttons(4, 4, 0);
}

TEST(SceneSchema, MouseButtonCommitBaselineKeepsVideoGatingFromStickingNativeLatch) {
    using Access = wallpaper::SceneWallpaperInputTestAccess;
    NativePointerObservation observation;
    owe_scene_wallpaper* raw = nullptr;
    ASSERT_EQ(owe_scene_wallpaper_new(&raw), 0);
    NativePointerSceneOwner scene(raw);
    auto& native = Access::FromNative(*scene);
    ASSERT_EQ(owe_scene_wallpaper_init(scene.get()), 0);
    ASSERT_EQ(RegisterNativePointer(scene.get(), observation), 0);
    ASSERT_TRUE(observation.Wait(1));
    const auto expect_buttons = [&](uint32_t down, uint32_t pressed, uint32_t released) {
        const auto snapshot = Access::ConsumeMouseButtons(native);
        EXPECT_EQ(snapshot.down, down);
        EXPECT_EQ(snapshot.pressed, pressed);
        EXPECT_EQ(snapshot.released, released);
    };
    auto interactive = MakePointerCommitScene(true);
    auto video = MakePointerCommitScene(false);

    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 0, true), 0);
    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 0, false), 0);
    Access::PostScene(native, interactive);
    ASSERT_TRUE(observation.Wait(2));
    expect_buttons(0, 1, 1);
    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 0, true), 0);
    Access::PostScene(native, MakePointerCommitScene(true));
    ASSERT_TRUE(observation.Wait(3));
    expect_buttons(1, 1, 0);

    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 1, true), 0);
    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 1, false), 0);
    Access::PostScene(native, video);
    ASSERT_TRUE(observation.Wait(4));
    expect_buttons(1, 0, 0);
    // The release observed during video was intentionally not sent to native.
    Access::PostScene(native, interactive);
    ASSERT_TRUE(observation.Wait(5));
    expect_buttons(1, 0, 0);
    ASSERT_EQ(owe_scene_wallpaper_set_mouse_button_baseline(scene.get(), 0), 0);
    expect_buttons(0, 0, 0);
    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 0, true), 0);
    expect_buttons(1, 1, 0);

    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 0, false), 0);
    Access::PostScene(native, video);
    ASSERT_TRUE(observation.Wait(6));
    expect_buttons(0, 0, 0);
    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 1, true), 0);
    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 1, false), 0);
    Access::PostScene(native, MakePointerCommitScene(true));
    ASSERT_TRUE(observation.Wait(7));
    expect_buttons(0, 0, 0);
    // Post-commit edges survive the held-level seed from the new sample.
    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 2, true), 0);
    ASSERT_EQ(owe_scene_wallpaper_set_mouse_button_baseline(scene.get(), 5), 0);
    expect_buttons(5, 4, 0);
    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 0, false), 0);
    expect_buttons(4, 0, 1);
    ASSERT_EQ(owe_scene_wallpaper_shutdown(scene.get()), 0);
    EXPECT_FALSE(interactive->first_frame_ok);
    EXPECT_FALSE(video->first_frame_ok);
}
#endif

TEST(SceneSchema, FailedPuppetMaterialRollsBackDynamicControlsAndSubscriptions) {
    std::map<std::string, std::string> files;
    AddPuppetImageSceneFiles(files);
    files["/shaders/baseimage.frag"] = "this is not valid GLSL";
    fs::VFS vfs;
    ASSERT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    auto json = nlohmann::json::parse(BasicPuppetSceneJson());
    json["objects"][0]["animationlayers"] = nlohmann::json::array({
        {{"animation", 7}, {"name", "gesture"},
         {"visible", {{"value", true}, {"user", "visible"}}},
         {"rate", {{"value", 1.0}, {"user", "rate"}}},
         {"blend", {{"value", 1.0}, {"user", "blend"}}}},
    });
    ProjectProperties properties {
        {"visible", RuntimeScalarValue::Bool(true)},
        {"rate", RuntimeScalarValue::Float(1.0f)},
        {"blend", RuntimeScalarValue::Float(1.0f)},
    };
    SceneParseRequest request { .scene_id = "failed-puppet-controls", .project_properties = &properties };
    audio::SoundManager sound;
    WPSceneParser parser;
    auto scene = parser.Parse(request, json.dump(), vfs, sound);
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    EXPECT_FALSE(scene->runtime->HasNodeNamed("puppet image"));
    EXPECT_EQ(scene->runtime->FindPuppetLayer("puppet image"), nullptr);
    scene->runtime->ApplyProjectPropertyOverride({
        {"visible", RuntimeScalarValue::Bool(false)},
        {"rate", RuntimeScalarValue::Float(2.0f)},
        {"blend", RuntimeScalarValue::Float(0.25f)},
    });
    scene->runtime->Tick(0.01);
    EXPECT_EQ(scene->runtime->FindPuppetLayer("puppet image"), nullptr);
    EXPECT_EQ(scene->runtime->PuppetAnimationControl("puppet image", "gesture", "exists", 0, false), 0.0);
}

TEST(SceneSchema, ParserCoverageUsesAuthoredRegionOfPaddedRgbaTexture) {
    Bytes bytes;
    bytes.Stamp("TEXV", 5);
    bytes.Stamp("TEXI", 1);
    bytes.I32(0);
    bytes.U32(0);
    // A 4x2 allocation contains a top-left 2x1 authored image.
    bytes.I32(4);
    bytes.I32(2);
    bytes.I32(2);
    bytes.I32(1);
    bytes.I32(0);
    bytes.Stamp("TEXB", 3);
    bytes.I32(1);
    bytes.I32(static_cast<int32_t>(ImageType::UNKNOWN));
    bytes.I32(1);
    bytes.I32(4);
    bytes.I32(2);
    bytes.I32(0);
    bytes.I32(0);
    bytes.I32(32);
    // Only the authored second texel meets the hit threshold; padding is transparent.
    for (int texel = 0; texel < 8; ++texel) {
        bytes.U8(255); bytes.U8(255); bytes.U8(255);
        bytes.U8(texel == 0 ? 15 : texel == 1 ? 16 : 0);
    }
    std::map<std::string, std::string> files;
    AddPuppetImageSceneFiles(files);
    files["/puppet_image.json"] = R"({"width":40,"height":20,"material":"mat/base.json"})";
    files["/materials/base.tex.tex"] = bytes.TakeString();
    auto json = nlohmann::json::parse(BasicPuppetSceneJson());
    auto& object = json["objects"][0];
    object["origin"] = {100, 100, 0};
    object["visible"] = {
        {"value", true},
        {"script", "export function cursorClick() { thisLayer.visible = false; }"},
    };
    fs::VFS vfs;
    ASSERT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound;
    WPSceneParser parser;
    // Runtime bootstrap is explicit, even when this scene has no user properties.
    ProjectProperties properties;
    auto scene = parser.Parse(SceneParseRequest {
        .scene_id = "padded-alpha-region", .project_properties = &properties,
    }, json.dump(), vfs, sound);
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto& runtime = *scene->runtime;
    runtime.Tick(0.0);
    EXPECT_EQ(runtime.NodeSize("puppet image"), Eigen::Vector2f(40.0f, 20.0f));
    EXPECT_TRUE(runtime.NodeVisible("puppet image"));
    runtime.SetCursorEnter(true);
    runtime.SetCursorButtons(0, 1, 1);
    runtime.SetCursorWorldPosition(Eigen::Vector3f(90, 100, 0));
    runtime.DispatchCursorFrameEvents(false);
    EXPECT_TRUE(runtime.NodeVisible("puppet image"));
    runtime.SetCursorWorldPosition(Eigen::Vector3f(110, 100, 0));
    runtime.DispatchCursorFrameEvents(true);
    EXPECT_FALSE(runtime.NodeVisible("puppet image"));
    EXPECT_EQ(runtime.scriptErrorCount(), 0u);
}

namespace {
/// A scene whose only content is a script that reveals a node when something
/// is playing, which is the shape this wallpaper's cover group has.
std::shared_ptr<wallpaper::Scene> MakeMediaProbeScene(std::shared_ptr<wallpaper::SceneNode>& probe) {
    auto scene = std::make_shared<wallpaper::Scene>();
    scene->activeCamera = nullptr;
    scene->sceneGraph.reset();
    scene->runtime = wallpaper::CreateSceneRuntimeContext(wallpaper::SceneRuntimeBootstrap {});
    if (scene->runtime == nullptr) return scene;
    probe = std::make_shared<wallpaper::SceneNode>();
    probe->SetVisible(false);
    scene->runtime->RegisterNode("probe", probe.get());
    scene->runtime->RegisterSceneScript(
        R"JS(
scene.on('mediaPlaybackChanged', function(event) {
  if (event.state === MediaPlaybackEvent.PLAYBACK_PLAYING) {
    scene.getObject('probe').visible = true;
  }
});
)JS",
        "");
    return scene;
}

/// Returns once both loopers have handled everything posted before the call:
/// a render-looper round trip, a main-looper round trip (installing a pointer
/// callback replays the current capability from the main looper), and a
/// render-looper round trip again for whatever the main looper forwarded.
///
/// Shutting down stops the loopers without draining them, so a test that
/// posts a scene and shuts down straight away otherwise measures whether the
/// render thread happened to get there first.
void WaitForPostedWork(wallpaper::SceneWallpaper& wallpaper) {
    ASSERT_TRUE(wallpaper.beginSurfaceReconfigure());
    struct Replay {
        std::mutex              mutex;
        std::condition_variable changed;
        bool                    seen { false };
    };
    auto replay = std::make_shared<Replay>();
    wallpaper.setPropertyObject(wallpaper::PROPERTY_POINTER_INPUT_CALLBACK,
                                std::make_shared<wallpaper::PointerInputCallback>([replay](bool) {
                                    std::scoped_lock lock(replay->mutex);
                                    replay->seen = true;
                                    replay->changed.notify_all();
                                }));
    {
        std::unique_lock lock(replay->mutex);
        ASSERT_TRUE(replay->changed.wait_for(lock, std::chrono::seconds(5),
                                             [&] { return replay->seen; }));
    }
    ASSERT_TRUE(wallpaper.beginSurfaceReconfigure());
}
} // namespace

TEST(SceneSchema, MediaStateSurvivesTheSceneItArrivedBefore) {
    // The host submits what is playing whenever it learns it, and a wallpaper
    // being rebuilt -- a property change reloads the scene on the same object,
    // a wallpaper switch builds a new one -- has no runtime to receive it for
    // as long as the parse takes. Dropping it there left a scene whose cover
    // group is revealed by `mediaPlaybackChanged` blank until the user pressed
    // pause and play again.
    wallpaper::SceneWallpaper wallpaper;
    ASSERT_TRUE(wallpaper.init());
    wallpaper.setPropertyBool(wallpaper::PROPERTY_MEDIA_INTEGRATION_ENABLED, true);
    wallpaper.setPropertyString(wallpaper::PROPERTY_MEDIA_EVENT_JSON,
                                R"({"type":"mediaPlaybackChanged","state":1})");

    std::shared_ptr<wallpaper::SceneNode> probe;
    auto scene = MakeMediaProbeScene(probe);
    ASSERT_NE(scene->runtime, nullptr);
    ASSERT_NE(probe, nullptr);
    ASSERT_FALSE(scene->runtime->NodeVisible("probe"));

    wallpaper::SceneWallpaperInputTestAccess::PostScene(wallpaper, scene);
    WaitForPostedWork(wallpaper);
    wallpaper.shutdown();

    EXPECT_TRUE(scene->runtime->NodeVisible("probe"))
        << "a scene attached after the event never learned what was playing";
    EXPECT_EQ(scene->runtime->scriptErrorCount(), 0u);
}

#if defined(__APPLE__)
TEST(SceneSchema, MediaArtworkClearCrossesTheNativeBoundaryAndReplacesPendingPixels) {
    struct NativeOwner {
        owe_scene_wallpaper* value {nullptr};
        ~NativeOwner() { if (value != nullptr) owe_scene_wallpaper_delete(value); }
    } native;
    ASSERT_EQ(owe_scene_wallpaper_new(&native.value), 0);
    auto& wallpaper = wallpaper::SceneWallpaperInputTestAccess::FromNative(*native.value);
    ASSERT_TRUE(wallpaper.init());
    wallpaper.setPropertyBool(wallpaper::PROPERTY_MEDIA_INTEGRATION_ENABLED, true);
    const std::array<uint8_t, 4> cover {20, 80, 140, 255}, empty {};
    ASSERT_EQ(owe_scene_wallpaper_apply_system_media_artwork(native.value, 1, 1, cover.data(), cover.size()), 0);
    ASSERT_EQ(owe_scene_wallpaper_apply_system_media_artwork(native.value, 0, 0, nullptr, 0), 0);
    std::shared_ptr<wallpaper::SceneNode> probe;
    auto scene = MakeMediaProbeScene(probe);
    scene->imageParser = std::make_unique<wallpaper::RuntimeImageSource>(nullptr);
    auto* images = static_cast<wallpaper::RuntimeImageSource*>(scene->imageParser.get());
    wallpaper::SceneWallpaperInputTestAccess::PostScene(wallpaper, scene);
    WaitForPostedWork(wallpaper);
    EXPECT_TRUE(images->MatchesRgba("$mediaThumbnail", 1, 1, empty.data(), empty.size()));
    ASSERT_EQ(owe_scene_wallpaper_apply_system_media_artwork(native.value, 1, 1, cover.data(), cover.size()), 0);
    WaitForPostedWork(wallpaper);
    EXPECT_TRUE(images->MatchesRgba("$mediaThumbnail", 1, 1, cover.data(), cover.size()));
    const auto covered_version = images->Version("$mediaThumbnail");
    EXPECT_NE(owe_scene_wallpaper_apply_system_media_artwork(native.value, 0, 1, nullptr, 0), 0);
    EXPECT_NE(owe_scene_wallpaper_apply_system_media_artwork(native.value, 2, 2, cover.data(), cover.size()), 0);
    EXPECT_EQ(images->Version("$mediaThumbnail"), covered_version);
    ASSERT_EQ(owe_scene_wallpaper_apply_system_media_artwork(native.value, 0, 0, nullptr, 0), 0);
    WaitForPostedWork(wallpaper);
    EXPECT_TRUE(images->MatchesRgba("$mediaThumbnail", 1, 1, empty.data(), empty.size()));
    EXPECT_TRUE(images->MatchesRgba("$mediaPreviousThumbnail", 1, 1, empty.data(), empty.size()));
    const auto cleared_version = images->Version("$mediaThumbnail");
    ASSERT_EQ(owe_scene_wallpaper_apply_system_media_artwork(native.value, 0, 0, nullptr, 0), 0);
    WaitForPostedWork(wallpaper);
    EXPECT_EQ(images->Version("$mediaThumbnail"), cleared_version);
    ASSERT_EQ(owe_scene_wallpaper_apply_system_media_artwork(native.value, 1, 1, cover.data(), cover.size()), 0);
    WaitForPostedWork(wallpaper);
    EXPECT_TRUE(images->MatchesRgba("$mediaThumbnail", 1, 1, cover.data(), cover.size()));
    wallpaper.shutdown();
}
#endif

TEST(SceneSchema, WithdrawingConsentDropsWhatWasRetained) {
    // Turning the setting back on must not resurrect what was playing when it
    // was last on. Retaining without clearing would replay a stale event here,
    // which is the only way this sequence can reveal the probe -- while the
    // setting is off both the replay and the runtime refuse to dispatch, so a
    // test that never re-enables pins nothing.
    wallpaper::SceneWallpaper wallpaper;
    ASSERT_TRUE(wallpaper.init());
    wallpaper.setPropertyBool(wallpaper::PROPERTY_MEDIA_INTEGRATION_ENABLED, true);
    wallpaper.setPropertyString(wallpaper::PROPERTY_MEDIA_EVENT_JSON,
                                R"({"type":"mediaPlaybackChanged","state":1})");
    wallpaper.setPropertyBool(wallpaper::PROPERTY_MEDIA_INTEGRATION_ENABLED, false);
    wallpaper.setPropertyBool(wallpaper::PROPERTY_MEDIA_INTEGRATION_ENABLED, true);

    std::shared_ptr<wallpaper::SceneNode> probe;
    auto scene = MakeMediaProbeScene(probe);
    ASSERT_NE(scene->runtime, nullptr);

    wallpaper::SceneWallpaperInputTestAccess::PostScene(wallpaper, scene);
    WaitForPostedWork(wallpaper);
    wallpaper.shutdown();

    EXPECT_FALSE(scene->runtime->NodeVisible("probe"))
        << "consent was withdrawn and what was playing then was replayed anyway";
}

TEST(SceneSchema, NoFrameClockRunsWithoutAScene) {
    // A surface still parsing, or one whose load failed, has nothing to draw.
    // Its frame clock used to start with the renderer and tick at 30 fps for as
    // long as the surface lived, posting draws that found no scene.
    wallpaper::RendererCounters::SetEnabled(true);
    wallpaper::SceneWallpaper wallpaper;
    ASSERT_TRUE(wallpaper.init());
    const auto wakeups = [&] {
        std::array<uint64_t, OWE_RC_COUNT> values {};
        wallpaper.counters(values.data(), values.size());
        return values[OWE_RC_TIMER_WAKEUPS];
    };
    std::this_thread::sleep_for(std::chrono::milliseconds(300));
    EXPECT_EQ(wakeups(), 0u) << "the frame clock ticked before any scene existed";

    // Asked to play a source that yields no scene, the clock still has nothing
    // to drive, so only the missing scene can be what keeps it stopped.
    wallpaper::SceneWallpaperConfig config;
    config.source = (std::filesystem::temp_directory_path() / "owe-no-such-project" /
                     "project.json")
                        .string();
    config.fps    = 60;
    config.paused = false;
    wallpaper.applyConfig(config);
    WaitForPostedWork(wallpaper);
    std::this_thread::sleep_for(std::chrono::milliseconds(300));
    EXPECT_EQ(wakeups(), 0u) << "the frame clock ran for a load that produced no scene";
    wallpaper.shutdown();
    wallpaper::RendererCounters::SetEnabled(false);
}

TEST(SceneSchema, ASoundFollowsTheSliderValueTheUserActuallyHas) {
    // scene.json carries the author's number beside the binding. Reading only
    // that number gives a sound whose volume is whatever the wallpaper shipped
    // with, so the user's own slider changes nothing. The binding names the
    // property; the property is where the user's value lives.
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .project_properties = {
            { "buttonsvolume", RuntimeScalarValue::Float(0.9f) },
        },
    });
    ASSERT_NE(runtime, nullptr);

    wpscene::WPSoundObject object;
    fs::VFS               vfs;
    const auto            json = nlohmann::json::parse(R"({
      "name": "button_press",
      "sound": ["sounds/button_press.ogg"],
      "playbackmode": "single",
      "volume": {"user": "buttonsvolume", "value": 0.3}
    })");
    ASSERT_TRUE(object.FromJson(json, vfs));
    EXPECT_FLOAT_EQ(object.volume, 0.3f) << "the author's number is still read";
    EXPECT_EQ(object.volume_user, "buttonsvolume");

    // Parse mounts the layer, which would open a system output device.
    audio::SoundManager sound_manager(audio::SoundManager::OutputBackend::Null);
    WPSoundParser::Parse(object, vfs, sound_manager, runtime.get());

    ASSERT_TRUE(runtime->HasSoundLayer("button_press"));
    EXPECT_FLOAT_EQ(runtime->SoundLayerVolume("button_press"), 0.9f)
        << "the sound kept the number scene.json shipped with instead of the user's slider";
}

TEST(SceneSchema, ASoundWithNoBindingKeepsTheAuthorsVolume) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    ASSERT_NE(runtime, nullptr);

    wpscene::WPSoundObject object;
    fs::VFS               vfs;
    const auto            json = nlohmann::json::parse(R"({
      "name": "click", "sound": ["a.ogg"], "volume": 0.75
    })");
    ASSERT_TRUE(object.FromJson(json, vfs));
    EXPECT_TRUE(object.volume_user.empty());

    audio::SoundManager sound_manager(audio::SoundManager::OutputBackend::Null);
    WPSoundParser::Parse(object, vfs, sound_manager, runtime.get());
    EXPECT_FLOAT_EQ(runtime->SoundLayerVolume("click"), 0.75f);
}

TEST(SceneSchema, AButtonSoundStartsSilentAndPlaysWhenAsked) {
    // These sounds ship `startsilent`, so they are registered not playing and
    // stay that way until a click asks for them. A click that reached the
    // runtime but left the stream silent is the shape of the reported symptom,
    // so both halves are pinned: quiet at rest, playing after the ask.
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    ASSERT_NE(runtime, nullptr);

    wpscene::WPSoundObject object;
    fs::VFS               vfs;
    const auto            json = nlohmann::json::parse(R"({
      "name": "button_press",
      "sound": ["sounds/button_press.ogg"],
      "playbackmode": "single",
      "startsilent": true,
      "volume": {"user": "buttonsvolume", "value": 0.3}
    })");
    ASSERT_TRUE(object.FromJson(json, vfs));
    EXPECT_TRUE(object.startsilent);

    audio::SoundManager sound_manager(audio::SoundManager::OutputBackend::Null);
    WPSoundParser::Parse(object, vfs, sound_manager, runtime.get());

    ASSERT_TRUE(runtime->HasSoundLayer("button_press"))
        << "the click handler asks for this by name and would find nothing";
    EXPECT_FALSE(runtime->SoundLayerPlaying("button_press"))
        << "a sound that starts silent was already running";

    EXPECT_TRUE(runtime->PlaySoundLayer("button_press"));
    EXPECT_TRUE(runtime->SoundLayerPlaying("button_press"))
        << "the click reached the runtime and the sound stayed silent";
}

TEST(SceneSchema, TheProgressFillFollowsAPublishedTimeline) {
    // The bar this wallpaper draws is not draggable and never was: nothing on
    // it reads the cursor. It is a fill whose origin a script moves, driven
    // only by what the host publishes, so a bar that never moves means the
    // events never arrived rather than that a drag was lost.
    //
    // The author's arithmetic is self-consistent -- `updatePosition` stores
    // milliseconds and the placement divides them back out -- so the fill is
    // pinned at a position the formula makes exact:
    //   -637 + (30 / 300) * 620 = -575
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    ASSERT_NE(runtime, nullptr);

    // `thisLayer.origin = ...` is a layer write, not this value's result: it
    // lands on the runtime's node translate, which is what the scene draws.
    SceneNode node;
    runtime->RegisterNodeTranslate("Solid", &node,
                                   std::make_unique<DynamicValue>(
                                       Eigen::Vector3f(0.0F, 700.0F, 0.0F)));

    ScriptedDynamicValue fill(*runtime, R"JS('use strict';

var lastTitle = null;
var lastPosition = -1;
var displayPosition = -1;
var lastUpdateTime = Date.now();
var isPlaying = false;
var pauseStartTime = null;
var dur = ""; // Variabile per la durata della canzone

export function mediaTimelineChanged(event) {
    var position = event.position;
    updatePosition(position);
    dur = event.duration; // Aggiorna la durata quando la timeline cambia
    console.log("Durata della canzone:", dur);
}

/*
Reset timer to 0 when song title changes
*/
export function mediaPropertiesChanged(event) {
    if (lastTitle !== event.title) {
        lastTitle = event.title;
        lastPosition = -1;
        displayPosition = 0;
        lastUpdateTime = Date.now();
    }
}

export function mediaPlaybackChanged(event) {
    if (event.state === MediaPlaybackEvent.PLAYBACK_PAUSED || event.state === MediaPlaybackEvent.PLAYBACK_STOPPED) {
        isPlaying = false;
        pauseStartTime = Date.now();
    } else {
        isPlaying = true;
        if (pauseStartTime !== null) {
            lastUpdateTime += Date.now() - pauseStartTime;
            pauseStartTime = null;
        }
    }
}

export function update(event) {
    if (!isPlaying || dur === "") {
        return;
    }

    var currentTime = Date.now();
    var elapsedSeconds = currentTime - lastUpdateTime;
    if (elapsedSeconds >= 1000) {
        displayPosition += elapsedSeconds;
        var lengthOfYourBar = 620; // Imposta la lunghezza totale della barra
        var startingXCoordinateOfYourBar = -637; // Coordinata X di partenza della barra
        var YCoordinateOfYourBar = 0; // Coordinata Y della barra

        // Calcola la posizione della barra in base alla durata
        thisLayer.origin = new Vec3(startingXCoordinateOfYourBar + (Math.round(displayPosition / 1000) / dur) * lengthOfYourBar, YCoordinateOfYourBar, 0);
        lastUpdateTime = currentTime;
    }
}

function updatePosition(position) {
    if (position !== lastPosition) {
        lastPosition = position;
        displayPosition = position * 1000;
        var lengthOfYourBar = 620; // Imposta la lunghezza totale della barra
        var startingXCoordinateOfYourBar = -637; // Coordinata X di partenza della barra
        var YCoordinateOfYourBar = 0; // Coordinata Y della barra

        // Calcola la posizione della barra in base alla durata
        thisLayer.origin = new Vec3(startingXCoordinateOfYourBar + (Math.round(displayPosition / 1000) / dur) * lengthOfYourBar, YCoordinateOfYourBar, 0);
        lastUpdateTime = Date.now();
    }
}

export function getDuration() {
    return dur; // Restituisce la durata della canzone
}
)JS", "Solid", {},
                              DynamicValue(Eigen::Vector3f(0.0F, 700.0F, 0.0F)));

    // The author places the fill before recording the duration it divides by,
    // so the very first event divides by an unset `dur` and puts the layer at
    // infinity. That is this wallpaper's own ordering, reproduced here rather
    // than papered over, because it is why the bar can start out misplaced.
    fill.DispatchMediaEventJson(
        R"({"type":"mediaTimelineChanged","position":30.0,"duration":300.0})");
    EXPECT_FALSE(std::isfinite(runtime->NodeTranslate("Solid").x()))
        << "the author's first-event ordering was silently corrected";

    // From the next event on the mapping is exact, which is what the bar
    // advancing at all depends on: -637 + (150 / 300) * 620 = -327.
    fill.DispatchMediaEventJson(
        R"({"type":"mediaTimelineChanged","position":150.0,"duration":300.0})");
    EXPECT_NEAR(runtime->NodeTranslate("Solid").x(), -327.0F, 0.5F)
        << "a published timeline did not move the fill";

    // Repeating a position carries no new information and must not jitter.
    fill.DispatchMediaEventJson(
        R"({"type":"mediaTimelineChanged","position":150.0,"duration":300.0})");
    EXPECT_NEAR(runtime->NodeTranslate("Solid").x(), -327.0F, 0.5F);

    // And it keeps tracking rather than latching on whatever arrived first.
    fill.DispatchMediaEventJson(
        R"({"type":"mediaTimelineChanged","position":300.0,"duration":300.0})");
    EXPECT_NEAR(runtime->NodeTranslate("Solid").x(), -17.0F, 0.5F);
}


TEST(SceneSchema, APressedTransportButtonComesBackWhenItIsReleased) {
    // The reported symptom is a transport button stuck flattened after one
    // press. This wallpaper's own scale script shrinks a held button to the
    // `hoScale` its scene ships -- a tenth of its size -- and only restores it
    // from `cursorUp`. Drive that script directly: the press must shrink it and
    // the release must bring it back, because a release that never arrives
    // leaves the button in exactly the state that was reported.
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    ASSERT_NE(runtime, nullptr);

    std::map<std::string, DynamicValueUniquePtr> script_properties;
    script_properties["hoScale"] = std::make_unique<DynamicValue>(0.1F);
    script_properties["speed"]   = std::make_unique<DynamicValue>(25.0F);
    script_properties["whY"]     = std::make_unique<DynamicValue>(0.0F);

    ScriptedDynamicValue scale(*runtime, R"JS('use strict';

import * as WEMath from 'WEMath';

export var scriptProperties = createScriptProperties()
.addSlider({
		name: 'whY',
		label: 'Scale',
		value: 0.0,
		min: -0.25,
		max: 0.25,
		integer: false
	})
	.addSlider({
		name: 'hoScale',
		label: 'Hover over scale multiplier',
		value: 0.9,
		min: 0.1,
		max: 2,
		integer: false
	})
	.addSlider({
		name: 'speed',
		label: 'Scale change speed',
		value: 100,
		min: 1,
		max: 100,
		integer: false
	})
	.finish();

let initScale, newScale, hover = false, propertyCheck = true, speed;

export function update(value) {
	if (hover) 
	{
		value = new Vec3((WEMath.mix(value.x, newScale.x, speed) + scriptProperties.whY), (WEMath.mix(value.y, newScale.y, speed) + scriptProperties.whY), (WEMath.mix(value.z, newScale.z, speed) + scriptProperties.whY));
	}
	else
	{
		value = new Vec3((WEMath.mix(value.x, initScale.x, speed) + scriptProperties.whY), (WEMath.mix(value.y, initScale.y, speed) + scriptProperties.whY), (WEMath.mix(value.z, initScale.z, speed) + scriptProperties.whY));
	}
	return value;
}

export function init(value) {
	initScale = value;
	return value;
}

export function cursorDown(event) {
	hover = true;
}

export function cursorUp(event) {
	hover = false;
}

export function applyUserProperties(changedUserProperties) {
	if (scriptProperties.hoScale != undefined && propertyCheck)
	{
		newScale = new Vec3(initScale.multiply(scriptProperties.hoScale));
		speed = scriptProperties.speed/100;
		propertyCheck = false;
	}
	
}
)JS", "avanti",
                               std::move(script_properties),
                               DynamicValue(Eigen::Vector3f(1.0F, 1.0F, 1.0F)));
    const ScriptHostContext host {};

    scale.reevaluate();
    EXPECT_NEAR(scale.getVec3().y(), 1.0F, 0.01F) << "the button was not its own size at rest";

    scale.DispatchCursorDown(host);
    for (int frame = 0; frame < 40; ++frame) scale.reevaluate();
    const float pressed = scale.getVec3().y();
    EXPECT_LT(pressed, 0.5F) << "the press did not shrink the button, so nothing is being tested";
    EXPECT_GT(pressed, 0.0F);

    scale.DispatchCursorUp(host);
    for (int frame = 0; frame < 40; ++frame) scale.reevaluate();
    EXPECT_NEAR(scale.getVec3().y(), 1.0F, 0.01F)
        << "the button stayed shrunk after release, which is the reported stuck button";
}

TEST(SceneSchema, AButtonThatShrinksWhileHeldStillGetsItsRelease) {
    // These transport buttons scale to a tenth of their size while held and
    // restore themselves from `cursorUp`. Deciding who hears a release by
    // hit-testing at release time loses it for exactly those buttons: the
    // press makes them too small to still be under the cursor, so the release
    // goes nowhere and they stay shrunk for good. The release belongs to
    // whoever took the press.
    fs::VFS vfs;
    MountSceneFiles(vfs);
    audio::SoundManager sound;
    WPSceneParser       parser;
    const std::string   scale_script = R"JS('use strict';
let held = false;
export function update(value) { return held ? new Vec3(0.1, 0.1, 1.0) : new Vec3(1.0, 1.0, 1.0); }
export function cursorDown(event) { held = true; }
export function cursorUp(event) { held = false; }
)JS";
    const nlohmann::json source = {
        {"camera", {{"center", {0, 0, 0}}, {"eye", {0, 0, 1}}, {"up", {0, 1, 0}}}},
        {"general", {{"ambientcolor", {0, 0, 0}}, {"skylightcolor", {0, 0, 0}},
                     {"clearcolor", {0, 0, 0}}, {"cameraparallax", false},
                     {"orthogonalprojection", {{"width", 400}, {"height", 300}}}}},
        {"objects", nlohmann::json::array({
            {{"id", 1}, {"name", "avanti"}, {"image", "image.json"},
             {"origin", {200, 150, 0}}, {"size", {80, 80}},
             {"scale", {{"script", scale_script}, {"value", "1.00000 1.00000 1.00000"}}}}
        })}
    };
    ProjectProperties properties;
    auto scene = parser.Parse(SceneParseRequest {
        .scene_id = "held-button", .project_properties = &properties,
    }, source.dump(), vfs, sound);
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto& runtime = *scene->runtime;
    runtime.Tick(0.01);

    // Inside the button at full size (160..240), outside it at a tenth
    // (196..204), which is the whole point.
    runtime.SetCursorInput(230.0F / 400.0F, 150.0F / 300.0F);
    runtime.SetCursorEnter(true);
    runtime.Tick(0.01);
    ASSERT_NEAR(runtime.NodeScale("avanti").x(), 1.0F, 0.01F);

    runtime.SetCursorButtons(1u, 1u, 0u);
    runtime.DispatchCursorFrameEvents(true);
    runtime.SetCursorButtons(1u, 0u, 0u);
    runtime.Tick(0.01);
    ASSERT_NEAR(runtime.NodeScale("avanti").x(), 0.1F, 0.01F)
        << "the press did not shrink the button, so the trap is not being sprung";

    runtime.SetCursorButtons(0u, 0u, 1u);
    runtime.DispatchCursorFrameEvents(true);
    runtime.SetCursorButtons(0u, 0u, 0u);
    runtime.Tick(0.01);
    EXPECT_NEAR(runtime.NodeScale("avanti").x(), 1.0F, 0.01F)
        << "the button shrank out from under the cursor and never heard its own release";
    EXPECT_EQ(runtime.scriptErrorCount(), 0u);
}

// A script imported from the Workshop declares the item it came from and names
// that item's model as `models/bar.json`, while the editor stored it under the
// item's workshop folder. The scene's own copy of the layer is hidden and never
// parsed, so the layer is made from the bare model: it has to find that folder,
// be as large as the model's picture rather than zero, and show.
TEST(SceneSchema, ALayerCreatedFromAWorkshopModelIsSizedByItsPictureAndShows) {
    Bytes tex;
    tex.Stamp("TEXV", 5);
    tex.Stamp("TEXI", 1);
    tex.I32(0);  // RGBA8888
    tex.U32(0);  // flags
    tex.I32(16); // texture
    tex.I32(8);
    tex.I32(12); // picture
    tex.I32(6);
    tex.I32(0);
    tex.Stamp("TEXB", 3);
    tex.I32(1);
    tex.I32(static_cast<int32_t>(ImageType::UNKNOWN));
    tex.I32(1);  // mipmaps
    tex.I32(16);
    tex.I32(8);
    tex.I32(0);  // not LZ4
    tex.I32(16 * 8 * 4);
    tex.I32(16 * 8 * 4);
    for (int texel = 0; texel < 16 * 8; ++texel) tex.U32(0xffffffffu);

    fs::VFS vfs;
    MountSceneFiles(vfs);
    ASSERT_TRUE(vfs.Mount(
        "/assets",
        std::make_unique<MemoryFs>(std::map<std::string, std::string> {
            { "/models/workshop/123/bar.json",
              R"({"autosize":true,"material":"materials/workshop/123/bar.json"})" },
            { "/materials/workshop/123/bar.json",
              R"({"passes":[{"blending":"translucent","shader":"genericimage",)"
              R"("textures":["workshop/123/bar"]}]})" },
            { "/materials/workshop/123/bar.tex", tex.TakeString() },
        })));
    const nlohmann::json source {
        { "camera", { { "center", { 0, 0, -1 } }, { "eye", { 0, 0, 0 } }, { "up", { 0, 1, 0 } } } },
        { "general",
          { { "ambientcolor", { 0, 0, 0 } },
            { "skylightcolor", { 0, 0, 0 } },
            { "clearcolor", { 0, 0, 0 } },
            { "cameraparallax", false },
            { "orthogonalprojection", { { "width", 640 }, { "height", 360 } } } } },
        { "objects",
          nlohmann::json::array({
              { { "id", 1 }, { "name", "source" }, { "image", "models/workshop/123/bar.json" },
                { "origin", { 320, 180, 0 } }, { "size", { 12, 6 } }, { "visible", false } },
              { { "id", 2 }, { "name", "owner" }, { "image", "image.json" },
                { "origin", { 320, 180, 0 } },
                { "visible",
                  { { "value", true },
                    { "script",
                      "export let __workshopId = '123';\n"
                      "export function init() { thisScene.createLayer('models/bar.json'); }\n"
                      "export function update(value) { return value; }\n" } } } },
          }) },
    };

    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    auto scene = parser.Parse(SceneParseRequest {
        .scene_id = "workshop-created-layer", .project_properties = &properties,
    }, source.dump(), vfs, sound_manager);
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    scene->runtime->Tick(1.0 / 60.0);
    scene->runtime->Tick(1.0 / 60.0);

    std::shared_ptr<SceneNode> created;
    for (const auto& child : scene->sceneGraph->GetChildren()) {
        if (child->Name().starts_with("__generated_layer_")) created = child;
    }
    ASSERT_NE(created, nullptr);
    EXPECT_NE(created->Mesh(), nullptr);
    EXPECT_TRUE(created->Visible());
    EXPECT_TRUE(scene->runtime->NodeSize(created->Name()).isApprox(Eigen::Vector2f(12, 6)));
    EXPECT_EQ(scene->runtime->scriptErrorCount(), 0u);
}

// ---------------------------------------------------------------------------
// SceneScript API parity: what needs the parser's own state.
// ---------------------------------------------------------------------------

namespace {

nlohmann::json ScriptParityScene(nlohmann::json objects) {
    return {
        { "camera", { { "center", { 0, 0, -1 } }, { "eye", { 0, 0, 0 } }, { "up", { 0, 1, 0 } } } },
        { "general",
          { { "ambientcolor", { 0, 0, 0 } },
            { "skylightcolor", { 0, 0, 0 } },
            { "clearcolor", { 0, 0, 0 } },
            { "cameraparallax", false },
            { "orthogonalprojection", { { "width", 640 }, { "height", 360 } } } } },
        { "objects", std::move(objects) },
    };
}

std::shared_ptr<Scene> ParseScriptParityScene(fs::VFS& vfs, const nlohmann::json& source) {
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    return parser.Parse(SceneParseRequest {
        .scene_id = "script-parity", .project_properties = &properties,
    }, source.dump(), vfs, sound_manager);
}

void WaitForTextLayoutToSettle(SceneRuntimeContext& runtime, const std::string& layer) {
    for (int attempt = 0; attempt < 400 && runtime.NodeTextDirty(layer); ++attempt) {
        runtime.PumpTextLayerCache();
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
}

} // namespace

// Layers are counted in the order the scene file declares them, found by their
// scene.json id, and their object is readable: all from the parse, not from the
// order scripts happened to register things in.
TEST(SceneSchema, ScriptsEnumerateLayersInSceneFileOrderAndReadTheirScenesObjects) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    const auto scene = ParseScriptParityScene(vfs, ScriptParityScene(nlohmann::json::array({
        { { "id", 31 }, { "name", "first" }, { "image", "image.json" }, { "origin", { 10, 20, 0 } } },
        { { "id", 7 }, { "name", "label" }, { "text", "hello" }, { "font", "Arial" }, { "pointsize", 24 } },
        { { "id", 12 }, { "name", "last" }, { "image", "image.json" },
          { "visible",
            { { "value", true },
              { "script",
                "export function init(value) {\n"
                "  const names = thisScene.enumerateLayers().map(l => l.name);\n"
                "  if (names.join(',') !== 'first,label,last') throw new Error('order: ' + names.join(','));\n"
                "  if (thisScene.getLayerCount() !== 3) throw new Error('count');\n"
                "  if (thisScene.getLayerByID(31) !== thisScene.getLayer('first')) throw new Error('id 31');\n"
                "  if (thisScene.getLayerByID(7) !== thisScene.getLayer(1)) throw new Error('id 7');\n"
                "  const config = thisScene.getInitialLayerConfig(thisScene.getLayer('label'));\n"
                "  if (config.text !== 'hello' || config.font !== 'Arial' || config.id !== 7) throw new Error('config');\n"
                "  const own = thisScene.getInitialLayerConfig(thisLayer);\n"
                "  if (own.image !== 'image.json' || own.name !== 'last') throw new Error('own config');\n"
                "  return value;\n"
                "}\n"
                "export function update(value) { return value; }\n" } } } },
    })));
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    scene->runtime->Tick(1.0 / 60.0);
    for (const auto& error : scene->runtime->scriptErrors()) ADD_FAILURE() << error;
    EXPECT_EQ(scene->runtime->LayerCount(), 3u);
    EXPECT_EQ(scene->runtime->LayerNameAt(0), "first");
    EXPECT_EQ(scene->runtime->LayerNameAt(1), "label");
    EXPECT_EQ(scene->runtime->LayerNameForId(12), "last");
    EXPECT_TRUE(scene->runtime->InitialLayerConfigRequested());
}

// A scene whose scripts never read the object list does not keep a copy of it.
TEST(SceneSchema, ASceneWithoutLayerConfigReadersKeepsNoCopyOfItsObjects) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    const auto scene = ParseScriptParityScene(vfs, ScriptParityScene(nlohmann::json::array({
        { { "id", 1 }, { "name", "plain" }, { "image", "image.json" },
          { "visible", { { "value", true }, { "script", "export function update(value) { return value; }" } } } },
    })));
    ASSERT_NE(scene, nullptr);
    scene->runtime->Tick(1.0 / 60.0);
    EXPECT_FALSE(scene->runtime->InitialLayerConfigRequested());
    EXPECT_EQ(scene->runtime->InitialLayerConfigJson("plain"), "");
}

// createLayer({ text }) builds the layer as the scene file's own text layers are
// built, so the new layer is a real one: it has a card, a material that takes
// the color and alpha, a measured size, and a place in the scene.
TEST(SceneSchema, CreateLayerBuildsATextLayerThroughTheParsersOwnTextPath) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    const auto scene = ParseScriptParityScene(vfs, ScriptParityScene(nlohmann::json::array({
        { { "id", 1 }, { "name", "label" }, { "text", "hello" }, { "font", "Arial" }, { "pointsize", 24 } },
        { { "id", 2 }, { "name", "owner" }, { "image", "image.json" },
          { "visible",
            { { "value", true },
              { "script",
                "export function init(value) {\n"
                "  const shadow = thisScene.createLayer({\n"
                "    text: thisScene.getInitialLayerConfig(thisScene.getLayer('label')).text,\n"
                "    font: thisScene.getLayer('label').font,\n"
                "    pointsize: thisScene.getLayer('label').pointsize,\n"
                "    color: '0.2 0.4 0.6', alpha: 0.5, name: 'shadow', horizontalalign: 'left'\n"
                "  });\n"
                "  shadow.origin = new Vec3(40, 50, 0);\n"
                // A text object has no `alignment`: a layer made with one is centred.
                "  thisScene.createLayer({ text: 'ghost', font: 'Arial', name: 'ghost',\n"
                "    alignment: 'right', verticalalign: 'Top' });\n"
                "  return value;\n"
                "}\n"
                "export function update(value) { return value; }\n" } } } },
    })));
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto& runtime = *scene->runtime;
    runtime.Tick(1.0 / 60.0);
    for (const auto& error : runtime.scriptErrors()) ADD_FAILURE() << error;

    const std::string name = runtime.ResolveLayerName("shadow");
    ASSERT_TRUE(runtime.HasNodeNamed(name)) << "the new layer is reachable by the name it was given";
    EXPECT_TRUE(name.starts_with("__we_text_")) << name;
    EXPECT_EQ(runtime.NodeText(name), "hello");
    const auto state = runtime.NodeTextState(name);
    ASSERT_TRUE(state.has_value());
    EXPECT_FLOAT_EQ(state->point_size, 24.0f);
    EXPECT_EQ(state->font_key, "Arial");
    EXPECT_EQ(state->horizontal_align, "left");
    const auto ghost = runtime.NodeTextState(runtime.ResolveLayerName("ghost"));
    ASSERT_TRUE(ghost.has_value());
    EXPECT_EQ(ghost->horizontal_align, "center") << "`alignment` names nothing a text layer has";
    EXPECT_EQ(ghost->vertical_align, "center") << "`Top` is not a word of the registry";
    EXPECT_GT(runtime.NodeSize(name).x(), 0.0f) << "laid out like the scene's own text";
    EXPECT_NEAR(runtime.NodeSize(name).x(), runtime.NodeSize("label").x(), 1e-3f);

    SceneNode* node = nullptr;
    for (const auto& child : scene->sceneGraph->GetChildren()) {
        if (child->Name() == name) node = child.get();
    }
    ASSERT_NE(node, nullptr) << "the layer joined the scene graph";
    ASSERT_NE(node->Mesh(), nullptr);
    ASSERT_NE(node->Mesh()->Material(), nullptr);
    const auto& constants = node->Mesh()->Material()->customShader.constValues;
    ASSERT_TRUE(constants.contains("g_Color"));
    EXPECT_FLOAT_EQ(constants.at("g_Color")[0], 0.2f);
    EXPECT_FLOAT_EQ(constants.at("g_Color")[1], 0.4f);
    EXPECT_FLOAT_EQ(constants.at("g_Color")[2], 0.6f);
    EXPECT_FLOAT_EQ(constants.at("g_Alpha")[0], 0.5f);
    EXPECT_TRUE(runtime.ConsumeSceneGraphMutationFlag());
    EXPECT_EQ(runtime.LayerCount(), 4u);
    EXPECT_EQ(runtime.LayerNameAt(2), name) << "created layers follow the scene's own";
}

// createLayer({ text, size }) goes through the parser's text path, which ignores the
// authored `size`: the card is the text plus its padding, as Wallpaper Engine sets it
// from the layout every time the text is laid out.
TEST(SceneSchema, ATextLayerAScriptMakesIgnoresAnAuthoredSize) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    const auto scene = ParseScriptParityScene(vfs, ScriptParityScene(nlohmann::json::array({
        { { "id", 1 }, { "name", "label" }, { "text", "hello" }, { "font", "Arial" }, { "pointsize", 24 } },
        { { "id", 2 }, { "name", "owner" }, { "image", "image.json" },
          { "visible",
            { { "value", true },
              { "script",
                "export function init(value) {\n"
                "  thisScene.createLayer({ text: 'hello', font: 'Arial', pointsize: 24,\n"
                "    name: 'boxed', size: '640 400' });\n"
                "  return value;\n"
                "}\n"
                "export function update(value) { return value; }\n" } } } },
    })));
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto& runtime = *scene->runtime;
    runtime.Tick(1.0 / 60.0);
    for (const auto& error : runtime.scriptErrors()) ADD_FAILURE() << error;

    const std::string name = runtime.ResolveLayerName("boxed");
    ASSERT_TRUE(runtime.HasNodeNamed(name));
    const auto card = runtime.NodeSize(name);
    EXPECT_GT(card.x(), 0.0f);
    EXPECT_LT(card.x(), 640.0f);
    EXPECT_LT(card.y(), 400.0f);
    EXPECT_TRUE(card.isApprox(runtime.NodeSize("label")));
}

// createLayer({ text, horizontalalign, verticalalign }) goes through the same path, so the
// layer it makes is placed as a scene's own: where the script puts its origin, with the
// card hung from it by the edges it is aligned to.
TEST(SceneSchema, ATextLayerAScriptMakesHangsFromItsOriginLikeASceneOne) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    const auto scene = ParseScriptParityScene(vfs, ScriptParityScene(nlohmann::json::array({
        { { "id", 1 }, { "name", "owner" }, { "image", "image.json" },
          { "visible",
            { { "value", true },
              { "script",
                "export function init(value) {\n"
                "  const label = thisScene.createLayer({ text: 'hello', font: 'Arial', pointsize: 24,\n"
                "    name: 'label', horizontalalign: 'right', verticalalign: 'bottom',\n"
                "    size: '640 400' });\n"
                "  label.origin = new Vec3(300, 100, 0);\n"
                "  return value;\n"
                "}\n"
                "export function update(value) { return value; }\n" } } } },
    })));
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto& runtime = *scene->runtime;
    runtime.Tick(1.0 / 60.0);
    for (const auto& error : runtime.scriptErrors()) ADD_FAILURE() << error;

    const std::string name = runtime.ResolveLayerName("label");
    ASSERT_TRUE(runtime.HasNodeNamed(name));
    SceneNode* node = nullptr;
    for (const auto& child : scene->sceneGraph->GetChildren()) {
        if (child->Name() == name) node = child.get();
    }
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    EXPECT_TRUE(node->Translate().isApprox(Eigen::Vector3f(300.0f, 100.0f, 0.0f)));
    EXPECT_TRUE(runtime.NodeTranslate(name).isApprox(Eigen::Vector3f(300.0f, 100.0f, 0.0f)));
    const auto layout = runtime.NodeTextLayout(name);
    ASSERT_TRUE(layout.has_value());
    const auto& vertices = node->Mesh()->GetVertexArray(0);
    float       max_x = -1.0e9f;
    float       max_y = -1.0e9f;
    for (std::size_t index = 0; index < vertices.VertexCount(); ++index) {
        max_x = std::max(max_x, vertices.Data()[index * vertices.OneSize()]);
        max_y = std::max(max_y, vertices.Data()[index * vertices.OneSize() + 1u]);
    }
    EXPECT_NEAR(max_x, 0.0f, 1.0e-3f) << "right aligned: the card ends on the origin";
    EXPECT_NEAR(max_y, layout->top + layout->descender, 1.0e-3f)
        << "bottom aligned: the descender line of the row is on the origin";
    EXPECT_LT(runtime.NodeSize(name).x(), 640.0f);
}

// A text layer's style is changed by script through the parser's own font
// resolution: a named system font resolves like the scene file's, a larger size
// and a new alignment lay the text out again and move the card about the layer's origin.
TEST(SceneSchema, ScriptsRestyleASceneTextLayerAndItIsLaidOutAgain) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    const auto scene = ParseScriptParityScene(vfs, ScriptParityScene(nlohmann::json::array({
        { { "id", 1 }, { "name", "clock" }, { "text", "12:30" }, { "font", "Arial" }, { "pointsize", 20 },
          { "origin", { 320, 180, 0 } }, { "horizontalalign", "left" }, { "verticalalign", "top" } },
        { { "id", 2 }, { "name", "owner" }, { "image", "image.json" },
          { "visible",
            { { "value", true },
              { "script",
                "export function init(value) { return value; }\n"
                "export function update(value) { return value; }\n"
                "export function cursorClick() {\n"
                "  const clock = thisScene.getLayer('clock');\n"
                "  clock.pointsize = clock.pointsize * 2;\n"
                "  clock.font = 'systemfont_arial';\n"
                "  clock.horizontalalign = 'right';\n"
                "}\n" } } } },
    })));
    ASSERT_NE(scene, nullptr);
    auto& runtime = *scene->runtime;
    runtime.Tick(1.0 / 60.0);
    WaitForTextLayoutToSettle(runtime, "clock");
    const auto before        = runtime.NodeSize("clock");
    EXPECT_EQ(runtime.NodeTextState("clock")->horizontal_align, "left");

    // The script's cursorClick runs when the pointer is over the owner's card.
    runtime.DispatchCursorClick();
    for (const auto& error : runtime.scriptErrors()) ADD_FAILURE() << error;

    const auto state = runtime.NodeTextState("clock");
    ASSERT_TRUE(state.has_value());
    EXPECT_FLOAT_EQ(state->point_size, 40.0f);
    EXPECT_EQ(state->font_key, "systemfont_arial");
    EXPECT_EQ(state->resolved_font_kind, "system") << "resolved by the parser's own rule";
    EXPECT_EQ(state->horizontal_align, "right");
    // The authored vertical alignment survives a horizontal change.
    EXPECT_EQ(state->vertical_align, "top");

    WaitForTextLayoutToSettle(runtime, "clock");
    ASSERT_FALSE(runtime.NodeTextDirty("clock"));
    const auto after = runtime.NodeSize("clock");
    EXPECT_GT(after.x(), before.x());
    EXPECT_GT(after.y(), before.y());
}

// A layer whose name is shared or empty is registered under a generated key, but
// scripts see the name the scene file gave it.
TEST(SceneSchema, ScriptsSeeTheAuthoredNameOfLayersTheParserRegisteredUnderGeneratedKeys) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    const auto scene = ParseScriptParityScene(vfs, ScriptParityScene(nlohmann::json::array({
        { { "id", 1 }, { "name", "twin" }, { "image", "image.json" } },
        { { "id", 2 }, { "name", "twin" }, { "image", "image.json" } },
        { { "id", 3 }, { "image", "image.json" } },
        { { "id", 4 }, { "name", "solo" }, { "image", "image.json" },
          { "visible",
            { { "value", true },
              { "script",
                "export function init(value) {\n"
                "  const names = thisScene.enumerateLayers().map(l => l.name);\n"
                "  if (names.join(',') !== 'twin,twin,,solo') throw new Error('names: ' + names.join(','));\n"
                "  if (thisScene.getLayerByID(2).name !== 'twin') throw new Error('id 2');\n"
                "  if (thisScene.getLayerByID(2) === thisScene.getLayer('twin')) throw new Error('the twins are one');\n"
                "  if (thisScene.getLayer('twin') !== thisScene.getLayer(0)) throw new Error('first twin');\n"
                "  if (thisScene.getLayer(2).name !== '') throw new Error('nameless');\n"
                "  if (thisScene.getLayerIndex(thisScene.getLayerByID(2)) !== 1) throw new Error('index');\n"
                "  if (thisLayer.name !== 'solo') throw new Error('this');\n"
                "  return value;\n"
                "}\n"
                "export function update(value) { return value; }\n" } } } },
    })));
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    scene->runtime->Tick(1.0 / 60.0);
    for (const auto& error : scene->runtime->scriptErrors()) ADD_FAILURE() << error;
    EXPECT_EQ(scene->runtime->LayerCount(), 4u);
    EXPECT_EQ(scene->runtime->LayerAuthoredName(scene->runtime->LayerNameAt(1)), "twin");
    EXPECT_EQ(scene->runtime->LayerAuthoredName(scene->runtime->LayerNameAt(2)), "");
}

// The same holds for a layer that has a script of its own. That script compiles
// while the parser builds the layer, and the layer object it is handed then
// (`thisLayer`) is the one every other script's `enumerateLayers()` returns, so
// the name has to be on record before. A script that gathers its widget's
// layers by name in `init` missed such a layer and left it where it was.
TEST(SceneSchema, LayersWithScriptsOfTheirOwnCarryTheirAuthoredNameUnderGeneratedKeys) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    const auto own_name_script = [](std::string_view expected) {
        return nlohmann::json {
            { "value", true },
            { "script",
              "const seen = thisLayer.name;\n"
              "export function update(value) {\n"
              "  if (seen !== '" + std::string(expected) + "') throw new Error('own name: ' + seen);\n"
              "  return value;\n"
              "}\n" },
        };
    };
    const auto scene = ParseScriptParityScene(vfs, ScriptParityScene(nlohmann::json::array({
        { { "id", 1 }, { "name", "twin" }, { "image", "image.json" }, { "visible", own_name_script("twin") } },
        { { "id", 2 }, { "name", "twin" }, { "image", "image.json" }, { "visible", own_name_script("twin") } },
        { { "id", 3 }, { "image", "image.json" }, { "visible", own_name_script("") } },
        { { "id", 4 }, { "name", "caption" }, { "text", "a" }, { "font", "Arial" }, { "pointsize", 24 } },
        { { "id", 5 }, { "name", "caption" }, { "text", "b" }, { "font", "Arial" }, { "pointsize", 24 },
          { "visible", own_name_script("caption") } },
        { { "id", 6 }, { "name", "mover" }, { "image", "image.json" },
          { "origin",
            { { "value", { 0, 0, 0 } },
              { "script",
                "export function init(value) {\n"
                "  thisScene.enumerateLayers().forEach(layer => {\n"
                "    if (layer.name === 'twin' || layer.name === 'caption') layer.origin = new Vec3(100, 50, 0);\n"
                "  });\n"
                "  return value;\n"
                "}\n"
                "export function update(value) { return value; }\n" } } } },
    })));
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto& runtime = *scene->runtime;
    runtime.Tick(1.0 / 60.0);
    for (const auto& error : runtime.scriptErrors()) ADD_FAILURE() << error;
    for (std::size_t index : { 0u, 1u, 3u, 4u }) {
        const auto key = runtime.LayerNameAt(index);
        const auto origin = runtime.NodeTranslate(key);
        EXPECT_TRUE(origin.x() == 100.0f && origin.y() == 50.0f)
            << runtime.LayerAuthoredName(key) << " at " << index
            << " was not gathered by its name: " << origin.transpose();
    }
}

// Every script runs `init` before any of them is told the user properties. A
// widget's options layer comes first in the scene and calls, from its first
// `applyUserProperties`, a function a later layer's `init` hands out. Started
// one script at a time, the call threw, and everything the options set after
// it (the switch that keeps the widget shown) was never set.
TEST(SceneSchema, EveryScriptRunsInitBeforeAnyIsToldTheUserProperties) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    const auto scene = ParseScriptParityScene(vfs, ScriptParityScene(nlohmann::json::array({
        { { "id", 1 }, { "name", "options" }, { "image", "image.json" },
          { "visible",
            { { "value", true },
              { "script",
                "export function applyUserProperties(changed) {\n"
                "  shared.startPlayer();\n"
                "  shared.enabled = true;\n"
                "}\n"
                "export function update(value) { return value; }\n" } } } },
        { { "id", 2 }, { "name", "player" }, { "image", "image.json" },
          { "visible",
            { { "value", true },
              { "script",
                "export function init(value) {\n"
                "  shared.startPlayer = () => { thisLayer.scale = new Vec3(3, 3, 1); };\n"
                "  return value;\n"
                "}\n"
                "export function update(value) { return shared.enabled === true; }\n" } } } },
    })));
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto& runtime = *scene->runtime;
    runtime.Tick(1.0 / 60.0);
    EXPECT_EQ(runtime.scriptErrorCount(), 0u);
    EXPECT_FLOAT_EQ(runtime.NodeScale("player").x(), 3.0f)
        << "the options' first applyUserProperties ran before the player's init";
    runtime.Tick(1.0 / 60.0);
    EXPECT_TRUE(runtime.NodeVisible("player")) << "the options stopped before the switch";
}

// What `init` returns is the property's value from then on, as what `update`
// returns is (Wallpaper Engine's own script template says so of both). A
// drag handle hides itself from `init`, and a typing text starts empty there
// and adds a letter on every `update`; one that returns nothing keeps the
// scene file's value, as does one that returns a value of another kind than
// the property's. Dropped, the handle stayed on screen and the typing text
// appended its letters to the placeholder.
TEST(SceneSchema, WhatInitReturnsIsThePropertysValue) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    const auto scene = ParseScriptParityScene(vfs, ScriptParityScene(nlohmann::json::array({
        { { "id", 1 }, { "name", "handle" }, { "image", "image.json" },
          { "visible",
            { { "value", true },
              { "script",
                "export function init(value) { return false; }\n"
                "export function update(value) { return value; }\n" } } } },
        { { "id", 2 }, { "name", "typing" }, { "font", "Arial" }, { "pointsize", 24 },
          { "text",
            { { "value", "placeholder" },
              { "script",
                "export function init(value) { return ''; }\n"
                "export function update(value) { return value + 'a'; }\n" } } } },
        { { "id", 3 }, { "name", "kept" }, { "image", "image.json" }, { "scale", { 2, 2, 1 } },
          { "visible",
            { { "value", true },
              { "script",
                "export function init(value) { thisLayer.alpha = 0.5; }\n"
                "export function update(value) { return value; }\n" } } } },
        { { "id", 4 }, { "name", "steady" }, { "image", "image.json" },
          { "origin",
            { { "value", { 10, 20, 0 } },
              { "script",
                "export function init(value) { return true; }\n"
                "export function update(value) { return value; }\n" } } } },
    })));
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto& runtime = *scene->runtime;
    runtime.Tick(1.0 / 60.0);
    runtime.Tick(1.0 / 60.0);
    EXPECT_EQ(runtime.scriptErrorCount(), 0u);
    EXPECT_FALSE(runtime.NodeVisible("handle"));
    EXPECT_EQ(runtime.NodeText("typing"), "aa");
    EXPECT_TRUE(runtime.NodeVisible("kept")) << "an init that returns nothing hid its layer";
    const auto steady = runtime.NodeTranslate("steady");
    EXPECT_TRUE(steady.x() == 10.0f && steady.y() == 20.0f)
        << "a flag returned for a position moved the layer to " << steady.transpose();
}

// A sound object is a layer to scripts: counted in the scene file's order,
// found by its id, called by its own name, and played through the object
// `enumerateLayers()` hands out. A music widget finds its tracks this way, by
// the `.mp3` in their names; with no sound listed it found none and threw when
// it was asked to play on startup. Two sounds that share a name stay two.
TEST(SceneSchema, ScriptsListSoundLayersInTheScenesOrderAndPlayThem) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    const auto source = ScriptParityScene(nlohmann::json::array({
        { { "id", 1 }, { "name", "cover" }, { "image", "image.json" } },
        { { "id", 2 }, { "name", "song.mp3 t:10" }, { "sound", { "sounds/a.mp3" } },
          { "startsilent", true }, { "playbackmode", "loop" } },
        { { "id", 3 }, { "name", "jingle.mp3" }, { "sound", { "sounds/b.mp3" } },
          { "startsilent", true } },
        { { "id", 4 }, { "name", "jingle.mp3" }, { "sound", { "sounds/c.mp3" } },
          { "startsilent", true } },
        { { "id", 5 }, { "name", "player" }, { "image", "image.json" },
          { "visible",
            { { "value", true },
              { "script",
                "export function init(value) {\n"
                "  const layers = thisScene.enumerateLayers();\n"
                "  const names = layers.map(l => l.name).join(',');\n"
                "  if (names !== 'cover,song.mp3 t:10,jingle.mp3,jingle.mp3,player') throw new Error('names: ' + names);\n"
                "  const songs = layers.filter(l => l.name.includes('.mp3'));\n"
                "  if (thisScene.getLayerByID(2) !== songs[0]) throw new Error('id 2');\n"
                "  if (thisScene.getLayer('jingle.mp3') !== songs[1]) throw new Error('first jingle');\n"
                "  if (songs[0].isPlaying()) throw new Error('a silent start played');\n"
                "  songs[0].play();\n"
                "  songs[2].play();\n"
                "  return value;\n"
                "}\n"
                "export function update(value) { return value; }\n" } } } },
    }));
    // The parse mounts the sounds, which opens a system output device unless
    // the manager has none.
    audio::SoundManager sound_manager(audio::SoundManager::OutputBackend::Null);
    WPSceneParser       parser;
    ProjectProperties   properties;
    const auto          scene = parser.Parse(SceneParseRequest {
        .scene_id = "sound-layers", .project_properties = &properties,
    }, source.dump(), vfs, sound_manager);
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto& runtime = *scene->runtime;
    runtime.Tick(1.0 / 60.0);
    EXPECT_EQ(runtime.scriptErrorCount(), 0u);
    EXPECT_EQ(runtime.LayerCount(), 5u);
    EXPECT_TRUE(runtime.SoundLayerPlaying(runtime.LayerNameAt(1)));
    EXPECT_FALSE(runtime.SoundLayerPlaying(runtime.LayerNameAt(2)))
        << "playing one of two sounds that share a name played the other";
    EXPECT_TRUE(runtime.SoundLayerPlaying(runtime.LayerNameAt(3)));
}

// A scene script runs `init` as it is registered. By then the layers' order and
// ids, the scene file's objects, and the hooks that restyle and create text
// layers are in place, as they are for every call after it.
TEST(SceneSchema, ASceneScriptsInitSeesTheLayerOrderIdsObjectsAndTextHooks) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    const auto scene = ParseScriptParityScene(vfs, ScriptParityScene(nlohmann::json::array({
        { { "id", 31 }, { "name", "first" }, { "image", "image.json" } },
        { { "id", 7 }, { "name", "label" }, { "text", "hello" }, { "font", "Arial" }, { "pointsize", 24 } },
        { { "id", 12 }, { "name", "last" }, { "image", "image.json" },
          { "visible",
            { { "value", true },
              { "script",
                "engine.on('resizeScreen', function() {});\n"
                "export function init(value) {\n"
                "  const names = thisScene.enumerateLayers().map(l => l.name);\n"
                "  if (names.join(',') !== 'first,label,last') throw new Error('order: ' + names.join(','));\n"
                "  if (thisScene.getLayerByID(31) !== thisScene.getLayer('first')) throw new Error('id 31');\n"
                "  if (thisScene.getLayerByID(7) !== thisScene.getLayer(1)) throw new Error('id 7');\n"
                "  const config = thisScene.getInitialLayerConfig(thisScene.getLayer('label'));\n"
                "  if (config === null || config.text !== 'hello' || config.id !== 7) throw new Error('config');\n"
                "  thisScene.getLayer('label').font = 'systemfont_arial';\n"
                "  const made = thisScene.createLayer({ text: 'from init', name: 'made', pointsize: 18 });\n"
                "  if (thisScene.getLayer('made') !== made || thisScene.getLayerCount() !== 4) throw new Error('made');\n"
                "  return value;\n"
                "}\n" } } } },
    })));
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto& runtime = *scene->runtime;
    for (const auto& error : runtime.scriptErrors()) ADD_FAILURE() << error;
    EXPECT_TRUE(runtime.InitialLayerConfigRequested());
    EXPECT_EQ(runtime.sceneScriptCount(), 1u) << "the script ran as a scene script";
    EXPECT_EQ(runtime.LayerCount(), 4u);
    EXPECT_EQ(runtime.NodeTextState("label")->font_key, "systemfont_arial");
    const auto made = runtime.ResolveLayerName("made");
    ASSERT_TRUE(runtime.HasNodeNamed(made));
    EXPECT_EQ(runtime.NodeText(made), "from init");
}

namespace {

// A file system that says whether it was asked while it still existed.
struct FsProbe {
    std::atomic<int>  asked_alive { 0 };
    std::atomic<int>  asked_after_death { 0 };
    std::atomic<bool> dead { false };
};

class ProbeFs final : public fs::Fs {
public:
    explicit ProbeFs(std::shared_ptr<FsProbe> probe): m_probe(std::move(probe)) {}
    ~ProbeFs() override { m_probe->dead = true; }

    bool Contains(std::string_view) const override {
        (m_probe->dead ? m_probe->asked_after_death : m_probe->asked_alive)++;
        return false;
    }
    std::shared_ptr<fs::IBinaryStream>  Open(std::string_view) override { return nullptr; }
    std::shared_ptr<fs::IBinaryStreamW> OpenW(std::string_view) override { return nullptr; }

private:
    std::shared_ptr<FsProbe> m_probe;
};

} // namespace

// A script's destroy() runs while the scene's files, layers and registries still
// exist: it can restyle a text layer, which asks the files for the font, and the
// request is answered by a file system that is still there.
TEST(SceneSchema, ScriptsEndWhileTheScenesFilesAndLayersStillExist) {
    auto probe = std::make_shared<FsProbe>();
    auto vfs   = std::make_unique<fs::VFS>();
    MountSceneFiles(*vfs);
    ASSERT_TRUE(vfs->Mount("/assets", std::make_unique<ProbeFs>(probe)));
    auto scene = ParseScriptParityScene(*vfs, ScriptParityScene(nlohmann::json::array({
        { { "id", 1 }, { "name", "label" }, { "text", "hello" }, { "font", "Arial" }, { "pointsize", 24 } },
        { { "id", 2 }, { "name", "owner" }, { "image", "image.json" },
          { "visible",
            { { "value", true },
              { "script",
                "export function init(value) { return value; }\n"
                "export function update(value) { return value; }\n"
                "export function destroy() {\n"
                "  thisScene.getLayer('label').font = 'fonts/probe.ttf';\n"
                "  thisLayer.visible = true;\n"
                "}\n" } } } },
    })));
    ASSERT_NE(scene, nullptr);
    scene->vfs = std::move(vfs);  // as the player hands the scene its files
    scene->runtime->Tick(1.0 / 60.0);
    for (const auto& error : scene->runtime->scriptErrors()) ADD_FAILURE() << error;
    const int asked_before = probe->asked_alive;

    scene.reset();
    EXPECT_GT(probe->asked_alive, asked_before) << "destroy() reached the files";
    EXPECT_EQ(probe->asked_after_death, 0) << "and they were still there";
    EXPECT_TRUE(probe->dead);
}

// Text layers a script makes and destroys over and over do not accumulate their
// rasters: each one's texture goes once the graph that drew it is gone.
TEST(SceneSchema, TextLayersAScriptMadeAndDestroyedLeaveNoTextureBehind) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    const auto scene = ParseScriptParityScene(vfs, ScriptParityScene(nlohmann::json::array({
        { { "id", 2 }, { "name", "owner" }, { "image", "image.json" } },
    })));
    ASSERT_NE(scene, nullptr);
    auto& runtime = *scene->runtime;
    auto* images  = dynamic_cast<RuntimeImageSource*>(scene->imageParser.get());
    ASSERT_NE(images, nullptr);
    const auto text_textures = [&] {
        std::size_t count = 0;
        for (const auto& [name, texture] : scene->textures) {
            if (name.starts_with("runtime/text/")) ++count;
        }
        return count;
    };
    runtime.Tick(1.0 / 60.0);
    const std::size_t baseline = text_textures();

    for (int round = 0; round < 4; ++round) {
        SCOPED_TRACE(round);
        const auto name = runtime.CreateTextLayer(R"({"text":"x","pointsize":20,"visible":true})", "owner");
        ASSERT_FALSE(name.empty());
        const auto texture = TextTextureName(name);
        EXPECT_TRUE(scene->textures.contains(texture));
        EXPECT_TRUE(images->IsRuntimeImage(texture));
        EXPECT_EQ(text_textures(), baseline + 1);

        runtime.ConsumeSceneGraphMutationFlag();
        EXPECT_TRUE(runtime.DestroyLayer(name));
        EXPECT_TRUE(scene->textures.contains(texture)) << "the graph compiled before still samples it";
        runtime.ConsumeSceneGraphMutationFlag();  // a graph without the layer was built
        runtime.Tick(1.0 / 60.0);
        EXPECT_FALSE(scene->textures.contains(texture));
        EXPECT_FALSE(images->IsRuntimeImage(texture));
        EXPECT_EQ(text_textures(), baseline);
    }
    EXPECT_TRUE(images->IsRuntimeImage("$mediaThumbnail")) << "the covers are never removed";
}
