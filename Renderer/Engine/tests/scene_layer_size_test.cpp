// An image layer is as large as the size its scene saved. The width and height a model states (the
// editor writes a sprite sheet's frame size there) size only a layer that saved no size, as a layer a
// script creates does. Parse-level: the scene is parsed, never drawn, so no device is needed.

#include <gtest/gtest.h>

#include "support/scene_package.hpp"

#include "Audio/SoundManager.h"
#include "Fs/PhysicalFs.h"
#include "Fs/VFS.h"
#include "Project/ProjectProperties.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/VirtualAssetRegistry.hpp"
#include "Scene/Scene.h"
#include "SceneSourceResolver.hpp"
#include "WPSceneParser.hpp"

#include <algorithm>
#include <cstring>
#include <filesystem>
#include <limits>
#include <memory>
#include <optional>
#include <string>

#include <unistd.h>

namespace
{
using namespace we_test;
using wallpaper::ParseProjectProperties;
using wallpaper::ProjectProperties;
using wallpaper::ResolveSceneSourcePaths;
using wallpaper::MountSceneSource;
using wallpaper::InstallVirtualAssets;
using wallpaper::SceneSourceResolution;
using wallpaper::SceneParseRequest;
using wallpaper::WPSceneParser;
using wallpaper::Scene;
using wallpaper::SceneNode;
using wallpaper::SceneMesh;
using wallpaper::SceneVertexArray;
namespace audio = wallpaper::audio;
namespace fs    = wallpaper::fs;
namespace disk = std::filesystem;

// The box and texture span of the one card a scene draws.
struct Card {
    float width { 0.0f };
    float height { 0.0f };
    float u_min { 0.0f }, u_max { 0.0f }, v_min { 0.0f }, v_max { 0.0f };
};

// A parsed scene and the scratch folders it needs, released together.
class ParsedScene {
public:
    explicit ParsedScene(const ScenePackage& package)
    {
        std::string pattern = (disk::temp_directory_path() / "we-layer-size-XXXXXX").string();
        if (::mkdtemp(pattern.data()) == nullptr) return;
        scratch_ = pattern;
        disk::create_directories(scratch_ / "cache");
        disk::create_directories(scratch_ / "shared");

        SceneSourceResolution resolved;
        std::string           problem;
        if (!ResolveSceneSourcePaths(package.project_file(), &resolved, &problem)) { Fail(problem); return; }
        auto vfs = std::make_unique<fs::VFS>();
        auto shared = fs::CreatePhysicalFs((scratch_ / "shared").string());
        if (shared == nullptr || !vfs->Mount("/assets", std::move(shared))) { Fail("shared mount"); return; }
        if (!MountSceneSource(*vfs, resolved.scene_source, &problem)) { Fail(problem); return; }
        auto cache = fs::CreatePhysicalFs((scratch_ / "cache").string(), true);
        if (cache == nullptr || !vfs->Mount("/cache", std::move(cache), "cache")) { Fail("cache mount"); return; }
        if (!InstallVirtualAssets(*vfs)) { Fail("virtual assets"); return; }

        ProjectProperties properties;
        if (!ParseProjectProperties(package.project_file(), &properties, &problem)) { Fail(problem); return; }
        SceneParseRequest request;
        request.scene_id                    = resolved.scene_source.scene_id;
        request.project_path                = package.project_file();
        request.project_properties          = &properties;
        request.authored_project_properties = &properties;

        sound_ = std::make_unique<audio::SoundManager>(audio::SoundManager::OutputBackend::Null);
        const std::string text = fs::GetFileContent(*vfs, "/assets/" + resolved.scene_source.pkg_entry);
        WPSceneParser     parser;
        scene_ = parser.Parse(request, text, *vfs, *sound_);
        if (scene_ != nullptr) scene_->vfs = std::move(vfs);
        else error_ = "the parse produced no scene";
    }
    ~ParsedScene()
    {
        scene_.reset();
        sound_.reset();
        std::error_code ignored;
        if (!scratch_.empty()) disk::remove_all(scratch_, ignored);
    }

    [[nodiscard]] Scene*              scene() const { return scene_.get(); }
    [[nodiscard]] const std::string&  error() const { return error_; }

    // The card of the first node that draws a four-corner mesh, found by walking the tree.
    [[nodiscard]] std::optional<Card> FirstCard() const
    {
        if (scene_ == nullptr || scene_->sceneGraph == nullptr) return std::nullopt;
        std::optional<Card> found;
        Visit(*scene_->sceneGraph, found);
        return found;
    }

private:
    void Fail(const std::string& why) { error_ = why; }

    static void Visit(SceneNode& node, std::optional<Card>& found)
    {
        if (found.has_value()) return;
        if (SceneMesh* mesh = node.Mesh(); mesh != nullptr && !mesh->Submeshes().empty() &&
                                           mesh->Submeshes().front().VertexCount() > 0) {
            const SceneVertexArray& vertices = mesh->GetVertexArray(0);
            const auto              offsets  = vertices.GetAttrOffsetMap();
            const auto              position = offsets.find("a_Position");
            const auto              texcoord = offsets.find("a_TexCoord");
            if (vertices.VertexCount() == 4 && position != offsets.end() && texcoord != offsets.end()) {
                Card card;
                float lo_x = 1e30f, hi_x = -1e30f, lo_y = 1e30f, hi_y = -1e30f;
                card.u_min = card.v_min = 1e30f;
                card.u_max = card.v_max = -1e30f;
                for (std::size_t i = 0; i < 4; ++i) {
                    const float* base = vertices.Data() + i * vertices.OneSize();
                    const float* at   = base + position->second.offset / sizeof(float);
                    const float* uv   = base + texcoord->second.offset / sizeof(float);
                    lo_x = std::min(lo_x, at[0]);
                    hi_x = std::max(hi_x, at[0]);
                    lo_y = std::min(lo_y, at[1]);
                    hi_y = std::max(hi_y, at[1]);
                    card.u_min = std::min(card.u_min, uv[0]);
                    card.u_max = std::max(card.u_max, uv[0]);
                    card.v_min = std::min(card.v_min, uv[1]);
                    card.v_max = std::max(card.v_max, uv[1]);
                }
                card.width  = hi_x - lo_x;
                card.height = hi_y - lo_y;
                found       = card;
                return;
            }
        }
        for (const auto& child : node.GetChildren()) {
            if (child != nullptr) Visit(*child, found);
        }
    }

    std::unique_ptr<audio::SoundManager> sound_;
    std::shared_ptr<Scene>               scene_;
    disk::path                           scratch_;
    std::string                          error_;
};

// A texture container flagged as a sprite sheet of `columns` x `rows` equal frames, with the frame
// table that follows its pictures.
std::string MakeSpriteSheet(uint32_t columns, uint32_t rows, uint32_t cell)
{
    const Image sheet = Image::Solid(columns * cell, rows * cell, { 90, 160, 220, 255 });
    std::string bytes = MakeTex(sheet);
    // After the two 9-byte stamps come the format word and then the flag word.
    uint32_t flags = 0;
    std::memcpy(&flags, bytes.data() + 22, sizeof(flags));
    flags |= 1u << 2;
    std::memcpy(bytes.data() + 22, &flags, sizeof(flags));

    const auto put_u32 = [&](uint32_t value) { bytes.append(reinterpret_cast<const char*>(&value), 4); };
    const auto put_f32 = [&](float value) { bytes.append(reinterpret_cast<const char*>(&value), 4); };
    bytes.append("TEXS0003", 8);
    bytes.push_back('\0');
    put_u32(columns * rows);
    put_u32(cell);
    put_u32(cell);
    for (uint32_t frame = 0; frame < columns * rows; ++frame) {
        put_u32(0);   // picture 0
        put_f32(0.1f); // seconds on screen
        put_f32(static_cast<float>((frame % columns) * cell));
        put_f32(static_cast<float>((frame / columns) * cell));
        put_f32(static_cast<float>(cell)); // x axis
        put_f32(0.0f);
        put_f32(0.0f);                      // y axis
        put_f32(static_cast<float>(cell));
    }
    return bytes;
}

struct Case {
    std::optional<std::array<float, 2>> saved_size;
    std::optional<std::array<float, 2>> model_size;
    bool                                sprite_sheet { false };
};

// Parses a one-layer scene built to the case and returns the card it makes.
std::optional<Card> CardOf(const Case& which, std::array<float, 3> origin = { 128.0f, 72.0f, 0.0f })
{
    ScenePackage package;
    std::string  model;
    if (which.sprite_sheet) {
        package.Put("materials/sheet.tex", MakeSpriteSheet(2, 2, 64));
        model = package.AddImageModel("sized", "sheet");
    } else {
        model = package.AddImageModel("sized", package.AddTexture("sized", Image::Solid(64, 64, { 90, 160, 220, 255 })));
    }
    Json model_json = { { "material", "materials/sized.json" }, { "autosize", false } };
    if (which.model_size) {
        model_json["width"]  = (*which.model_size)[0];
        model_json["height"] = (*which.model_size)[1];
    }
    package.PutJson(model, model_json);

    ImageLayer layer;
    layer.model  = model;
    layer.origin = origin;
    Json object  = ImageLayerJson(layer);
    object.erase("size");
    if (which.saved_size) {
        char text[64];
        std::snprintf(text, sizeof(text), "%.6f %.6f", static_cast<double>((*which.saved_size)[0]),
                      static_cast<double>((*which.saved_size)[1]));
        object["size"] = text;
    }
    package.SetProject();
    package.SetScene(SceneJson({}, { object }));

    ParsedScene parsed(package);
    EXPECT_NE(parsed.scene(), nullptr) << parsed.error();
    if (parsed.scene() == nullptr) return std::nullopt;
    EXPECT_TRUE(parsed.scene()->shader_fallbacks.empty())
        << (parsed.scene()->shader_fallbacks.empty() ? std::string {} : parsed.scene()->shader_fallbacks.front());
    if (which.sprite_sheet) {
        const auto sheet = parsed.scene()->textures.find("sheet");
        EXPECT_TRUE(sheet != parsed.scene()->textures.end() && sheet->second.isSprite &&
                    sheet->second.spriteAnim.numFrames() == 4)
            << "the picture of this case is meant to be an animated sheet of four frames";
    }
    return parsed.FirstCard();
}

void ExpectCard(const std::optional<Card>& card, float width, float height)
{
    ASSERT_TRUE(card.has_value()) << "the scene drew no card";
    EXPECT_FLOAT_EQ(card->width, width);
    EXPECT_FLOAT_EQ(card->height, height);
    // The picture is sampled over the whole card.
    EXPECT_FLOAT_EQ(card->u_min, 0.0f);
    EXPECT_FLOAT_EQ(card->u_max, 1.0f);
    EXPECT_FLOAT_EQ(card->v_min, 0.0f);
    EXPECT_FLOAT_EQ(card->v_max, 1.0f);
}

} // namespace

TEST(LayerSize, TheSizeTheSceneSavedWinsOverTheSizeTheModelStates)
{
    ExpectCard(CardOf({ .saved_size = std::array<float, 2> { 400.0f, 300.0f },
                        .model_size = std::array<float, 2> { 64.0f, 64.0f } }),
               400.0f, 300.0f);
}

TEST(LayerSize, ALayerThatSavedNoSizeTakesTheSizeTheModelStates)
{
    ExpectCard(CardOf({ .model_size = std::array<float, 2> { 64.0f, 64.0f } }), 64.0f, 64.0f);
}

TEST(LayerSize, ALayerWithNeitherSizeIsTwiceItsOriginAsBefore)
{
    // The size a layer falls back on when nothing states one: twice its origin on each axis.
    ExpectCard(CardOf({}, { 90.0f, 50.0f, 0.0f }), 180.0f, 100.0f);
}

TEST(LayerSize, TheSameHoldsForAnAnimatedSpriteSheet)
{
    ExpectCard(CardOf({ .saved_size = std::array<float, 2> { 400.0f, 300.0f },
                        .model_size = std::array<float, 2> { 64.0f, 64.0f },
                        .sprite_sheet = true }),
               400.0f, 300.0f);
    ExpectCard(CardOf({ .model_size = std::array<float, 2> { 64.0f, 64.0f }, .sprite_sheet = true }), 64.0f, 64.0f);
    ExpectCard(CardOf({ .sprite_sheet = true }, { 90.0f, 50.0f, 0.0f }), 180.0f, 100.0f);
}
