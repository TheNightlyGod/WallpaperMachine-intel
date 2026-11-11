// Scenes with text layers, parsed in memory, and the small measuring helpers the text tests share.
//
// `TextWorld` is a scratch tree with two mounts (`/assets`, the wallpaper's own files, and
// `/provided`, a second root such as a user font folder) plus the engine's built-in assets. It
// parses a scene document the way the host does and hands back the scene with its runtime; nothing
// draws and no window or Metal device is involved.
#pragma once

#include "Project/ProjectProperties.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Scene/Scene.h"

#include <nlohmann/json.hpp>

#include <filesystem>
#include <initializer_list>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

namespace wallpaper::audio
{
class SoundManager;
}

namespace we_test
{

using Json = nlohmann::json;

class TextWorld {
public:
    TextWorld();
    ~TextWorld();
    TextWorld(const TextWorld&)            = delete;
    TextWorld& operator=(const TextWorld&) = delete;

    /// Writes a file the scene reads as `/assets/<path>`.
    void PutAsset(const std::string& path, std::string_view bytes);
    /// Writes a file the scene reads as `/provided/<path>`.
    void PutProvided(const std::string& path, std::string_view bytes);

    /// Parses `scene_json`; null when the parser refuses it.
    std::shared_ptr<wallpaper::Scene> Load(const Json& document, wallpaper::ProjectProperties properties = {});

private:
    std::filesystem::path                  root_;
    std::unique_ptr<wallpaper::audio::SoundManager> sound_;
};

// ---- scene documents -----------------------------------------------------------------------

/// A scene file: camera, quiet `general`, and `objects`. Canvas defaults to 640x360.
Json SceneDocument(std::vector<Json> objects, int width = 640, int height = 360);

/// A text object. `text` is whatever the file holds for the property (a string or an object);
/// `extra` keys replace the defaults (Arial, 20 pt, origin 0, centred, visible).
Json TextObject(int id, const std::string& name, const Json& text, const Json& extra = Json::object());

/// A group layer other layers can name as `parent`.
Json GroupObject(int id, const std::string& name);

// ---- looking at the parsed scene -----------------------------------------------------------

struct Box {
    float min_x { 0 }, max_x { 0 }, min_y { 0 }, max_y { 0 };
    [[nodiscard]] float W() const { return max_x - min_x; }
    [[nodiscard]] float H() const { return max_y - min_y; }
    [[nodiscard]] float CX() const { return (min_x + max_x) * 0.5f; }
    [[nodiscard]] float CY() const { return (min_y + max_y) * 0.5f; }
};

/// The local x/y extent of a mesh's vertices.
Box PositionBox(const wallpaper::SceneMesh& mesh);
/// The extent of its texture coordinates (u as x, v as y).
Box TexCoordBox(const wallpaper::SceneMesh& mesh);

/// A direct child of the scene graph root with this name, or null.
wallpaper::SceneNode* RootChild(wallpaper::Scene& scene, std::string_view name);
/// The first texture key of material slot 0 of the node's mesh ("" when there is none).
std::string CardTexture(wallpaper::SceneNode& node);

/// How many glyph quads the layer's mono/MSDF glyph submesh draws.
std::size_t GlyphQuads(wallpaper::SceneNode& node);

/// Pumps the text worker until none of `names` is dirty; false if that never happens.
bool PumpUntilClean(wallpaper::SceneRuntimeContext& runtime, std::initializer_list<std::string> names);
bool PumpUntilClean(wallpaper::SceneRuntimeContext& runtime, const std::vector<std::string>& names);

/// Counts texels of an atlas mip with coverage above zero (R8 coverage, or RGBA8 alpha).
std::size_t InkTexels(const wallpaper::Image& image);

} // namespace we_test
