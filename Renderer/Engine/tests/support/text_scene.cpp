#include "support/text_scene.hpp"
#include "support/font_assets.hpp"

#include "Audio/SoundManager.h"
#include "Fs/PhysicalFs.h"
#include "Fs/VFS.h"
#include "Image.hpp"
#include "Interface/IImageParser.h"
#include "Runtime/VirtualAssetRegistry.hpp"
#include "SpecTexs.hpp"
#include "Text/TextGlyphMesh.hpp"
#include "Utils/Random.hpp"
#include "WPSceneParser.hpp"

#include <algorithm>
#include <chrono>
#include <fstream>
#include <limits>
#include <stdexcept>
#include <thread>

#include <unistd.h>

namespace we_test
{

using namespace wallpaper;
namespace disk = std::filesystem;

TextWorld::TextWorld()
{
    std::string pattern = (disk::temp_directory_path() / "we-text-world-XXXXXX").string();
    if (::mkdtemp(pattern.data()) == nullptr) throw std::runtime_error("cannot create a scratch folder");
    root_ = pattern;
    for (const char* folder : { "assets", "provided", "cache" }) disk::create_directories(root_ / folder);
    // The font materials and shaders text layers draw with (stand-ins; a test may overwrite them).
    wallpaper::test::WriteFontAssets(root_ / "assets");
    sound_ = std::make_unique<audio::SoundManager>(audio::SoundManager::OutputBackend::Null);
}

TextWorld::~TextWorld()
{
    sound_.reset();
    std::error_code ignored;
    if (!root_.empty()) disk::remove_all(root_, ignored);
}

namespace
{
void WriteFile(const disk::path& target, std::string_view bytes)
{
    disk::create_directories(target.parent_path());
    std::ofstream out(target, std::ios::binary | std::ios::trunc);
    out.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
}
} // namespace

void TextWorld::PutAsset(const std::string& path, std::string_view bytes) { WriteFile(root_ / "assets" / path, bytes); }

void TextWorld::PutProvided(const std::string& path, std::string_view bytes)
{
    WriteFile(root_ / "provided" / path, bytes);
}

std::shared_ptr<Scene> TextWorld::Load(const Json& document, ProjectProperties properties)
{
    auto vfs = std::make_unique<fs::VFS>();
    if (!vfs->Mount("/assets", fs::CreatePhysicalFs((root_ / "assets").string()))) return nullptr;
    if (!vfs->Mount("/provided", fs::CreatePhysicalFs((root_ / "provided").string()))) return nullptr;
    if (!vfs->Mount("/cache", fs::CreatePhysicalFs((root_ / "cache").string(), true), "cache")) return nullptr;
    if (!InstallVirtualAssets(*vfs)) return nullptr;

    SceneParseRequest request;
    request.scene_id           = "text-world";
    request.project_properties = &properties;

    Random::seed(1);
    WPSceneParser parser;
    auto          scene = parser.Parse(request, document.dump(), *vfs, *sound_);
    if (scene == nullptr) return nullptr;
    if (scene->runtime != nullptr) {
        scene->runtime->SetAudioResponseEnabled(false);
        scene->runtime->SetMediaIntegrationEnabled(false);
    }
    scene->vfs = std::move(vfs);
    return scene;
}

// ---- scene documents -----------------------------------------------------------------------

Json SceneDocument(std::vector<Json> objects, int width, int height)
{
    return {
        { "camera", { { "center", "0 0 0" }, { "eye", "0 0 1" }, { "up", "0 1 0" } } },
        { "general",
          { { "ambientcolor", "0 0 0" },
            { "skylightcolor", "0 0 0" },
            { "clearcolor", "0 0 0" },
            { "bloom", false },
            { "hdr", false },
            { "cameraparallax", false },
            { "cameraparallaxamount", 0 },
            { "cameraparallaxdelay", 0 },
            { "cameraparallaxmouseinfluence", 0 },
            { "orthogonalprojection", { { "width", width }, { "height", height } } } } },
        { "objects", std::move(objects) },
    };
}

Json TextObject(int id, const std::string& name, const Json& text, const Json& extra)
{
    Json object = {
        { "id", id },
        { "name", name },
        { "text", text },
        { "font", "Arial" },
        { "pointsize", 20 },
        { "origin", "0 0 0" },
        { "visible", true },
    };
    for (const auto& [key, value] : extra.items()) object[key] = value;
    return object;
}

Json GroupObject(int id, const std::string& name)
{
    return { { "id", id }, { "name", name }, { "origin", "0 0 0" } };
}

// ---- measuring -----------------------------------------------------------------------------

namespace
{
Box VertexBox(const SceneMesh& mesh, std::size_t byte_offset)
{
    const auto&       vertices = mesh.GetVertexArray(0);
    const std::size_t stride   = vertices.OneSize();
    const float*      data     = vertices.Data();
    Box               box { std::numeric_limits<float>::max(), std::numeric_limits<float>::lowest(),
                            std::numeric_limits<float>::max(), std::numeric_limits<float>::lowest() };
    for (std::size_t at = 0; at < vertices.VertexCount(); ++at) {
        const float* vertex = data + at * stride + byte_offset / sizeof(float);
        box.min_x           = std::min(box.min_x, vertex[0]);
        box.max_x           = std::max(box.max_x, vertex[0]);
        box.min_y           = std::min(box.min_y, vertex[1]);
        box.max_y           = std::max(box.max_y, vertex[1]);
    }
    return box;
}
} // namespace

Box PositionBox(const SceneMesh& mesh) { return VertexBox(mesh, 0); }

Box TexCoordBox(const SceneMesh& mesh)
{
    const auto offsets = mesh.GetVertexArray(0).GetAttrOffsetMap();
    const auto found   = offsets.find(std::string(WE_IN_TEXCOORD));
    if (found == offsets.end()) throw std::runtime_error("the mesh has no texture coordinates");
    return VertexBox(mesh, found->second.offset);
}

SceneNode* RootChild(Scene& scene, std::string_view name)
{
    for (const auto& child : scene.sceneGraph->GetChildren()) {
        if (child != nullptr && child->Name() == name) return child.get();
    }
    return nullptr;
}

std::string CardTexture(SceneNode& node)
{
    if (node.Mesh() == nullptr) return {};
    // The glyphs' material reads the layer's atlas (slot 1 of the text mesh).
    const auto* material = node.Mesh()->MaterialForSlot(wallpaper::kTextGlyphSubmesh);
    if (material == nullptr || material->textures.empty()) return {};
    return material->textures.front();
}

std::size_t GlyphQuads(SceneNode& node)
{
    if (node.Mesh() == nullptr || node.Mesh()->Submeshes().size() <= kTextGlyphSubmesh) return 0;
    const auto& glyphs = node.Mesh()->Submeshes()[kTextGlyphSubmesh];
    if (glyphs.IndexCount() == 0) return 0;
    return glyphs.GetIndexArray(0).DrawIndexCount() / 6;
}

bool PumpUntilClean(SceneRuntimeContext& runtime, const std::vector<std::string>& names)
{
    for (int round = 0; round < 200; ++round) {
        runtime.PumpTextLayerCache();
        const bool clean = std::none_of(names.begin(), names.end(), [&](const std::string& name) {
            return runtime.NodeTextDirty(name);
        });
        if (clean) return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    return false;
}

bool PumpUntilClean(SceneRuntimeContext& runtime, std::initializer_list<std::string> names)
{
    return PumpUntilClean(runtime, std::vector<std::string>(names));
}

std::size_t InkTexels(const Image& image)
{
    if (image.slots.empty() || image.slots.front().mipmaps.empty()) return 0;
    const auto& level = image.slots.front().mipmaps.front();
    if (level.data == nullptr) return 0;
    // A mono atlas is one coverage byte a texel (R8), the others RGBA8 with coverage in alpha.
    const bool  r8     = image.header.format == TextureFormat::R8;
    const i32   stride = r8 ? 1 : 4;
    const i32   lane   = r8 ? 0 : 3;
    std::size_t count  = 0;
    for (i32 at = 0; at < level.width * level.height; ++at) {
        if (level.data.get()[at * stride + lane] > 0) ++count;
    }
    return count;
}

} // namespace we_test
