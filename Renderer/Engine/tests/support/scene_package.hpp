// Synthetic wallpaper projects for tests: a folder the scene loader opens exactly like a loose
// project, the engine's own texture container, and small JSON builders for the scene file.
//
// Nothing here draws or links the renderer. `GpuScene` (gpu_scene.hpp) loads a `ScenePackage`.
// Every file is written under the system temp directory and removed with the package.
#pragma once

#include "support/pixels.hpp"

#include <nlohmann/json.hpp>

#include <array>
#include <cstdint>
#include <filesystem>
#include <string>
#include <string_view>
#include <vector>

namespace we_test
{

using Json = nlohmann::json;

// ---- texture containers ------------------------------------------------------------------

struct TexOptions {
    /// Nearest-neighbour sampling instead of linear. On by default so a small texture shows
    /// its exact texels.
    bool point_sampling { true };
    /// Clamp to the edge instead of repeating.
    bool clamp { true };
    /// How many levels the container holds; levels below the first are box-filtered halves.
    int mip_levels { 1 };
};

/// The engine's `.tex` container (TEXV/TEXI/TEXB, uncompressed RGBA8) holding `image`.
std::string MakeTex(const Image& image, TexOptions options = {});
/// A container whose levels are exactly `levels` (largest first), for tests that need a
/// different picture in each level.
std::string MakeTexWithLevels(const std::vector<Image>& levels, TexOptions options = {});
/// A single flat-coloured texel texture.
std::string MakeTex(Rgba colour);
/// The same picture as a PNG file, which the loader also accepts beside `.tex` files.
std::string MakePng(const Image& image);

// ---- the scene file ----------------------------------------------------------------------

/// The block of `scene.json` that sets the canvas and the camera behaviour. Every default is
/// the quiet one: no bloom, no parallax, no shake, black clear colour.
struct SceneGeneral {
    int                  canvas_width { 256 };
    int                  canvas_height { 144 };
    std::array<float, 3> clear_color { 0.0f, 0.0f, 0.0f };
    bool                 parallax { false };
    float                parallax_amount { 0.5f };
    float                parallax_delay { 0.0f };
    float                parallax_mouse_influence { 0.5f };
    /// Keys merged over the block last, to set anything not named above.
    Json                 extra { Json::object() };
};

/// A user property bound to a setting: the value the setting has until a property of that name
/// says otherwise.
Json PropertyBinding(const std::string& property, const Json& fallback);
/// A setting driven by a script. `source` is the script text; `initial` is the value the
/// setting holds before the script first runs.
Json ScriptedValue(const std::string& source, const Json& initial, const Json& properties = Json::object());

/// One image layer of `scene.json`. Defaults put a canvas-sized layer in the middle of a
/// 256x144 canvas; set `origin` and `size` for another canvas.
struct ImageLayer {
    int                  id { 1 };
    std::string          name { "layer" };
    /// The model file, as `ScenePackage::AddImageModel` returned it.
    std::string          model;
    std::array<float, 3> origin { 128.0f, 72.0f, 0.0f };
    std::array<float, 2> size { 256.0f, 144.0f };
    /// A "r g b" string, or a `PropertyBinding` / `ScriptedValue`.
    Json                 color { "1 1 1" };
    Json                 alpha { 1.0 };
    Json                 visible { true };
    int                  parent { -1 };
    /// Entries of the layer's `effects` array (see `EffectUse`).
    std::vector<Json>    effects;
    /// Keys merged over the object last (`scale`, `angles`, `parallaxDepth`, ...).
    Json                 extra { Json::object() };
};
Json ImageLayerJson(const ImageLayer& layer);

/// A layer that only carries a transform; other layers name it as `parent`.
Json GroupJson(int id, const std::string& name, std::array<float, 3> origin, int parent = -1);

/// One use of an effect file by a layer: its constants by material key (`"tint": "0 1 0"`).
Json EffectUse(const std::string& effect_file, const Json& constants = Json::object(), int id = 0);

/// The camera block every synthetic scene uses: a straight look at the canvas.
Json CameraJson();
Json GeneralJson(const SceneGeneral& general);
/// The whole `scene.json` document.
Json SceneJson(const SceneGeneral& general, const std::vector<Json>& objects);

/// The project's property declarations: `{ "color": ColorProperty("1 0 0"), ... }`.
Json ColorProperty(const std::string& value);
Json SliderProperty(double value, double minimum = 0.0, double maximum = 1.0);
Json BoolProperty(bool value);

// ---- the project folder ------------------------------------------------------------------

struct ModelOptions {
    /// Blending of the image pass: "translucent", "normal", "additive", "disabled", ...
    std::string blending { "translucent" };
    /// Shader of the pass; the standard image shader unless a test installs its own.
    std::string shader { "harness_image" };
};

/// A scratch directory holding one wallpaper project, removed when the package is destroyed.
/// The folder is a loose project: `project.json`, `scene.json` and the asset tree beside them.
class ScenePackage {
public:
    ScenePackage();
    ~ScenePackage();
    ScenePackage(const ScenePackage&)            = delete;
    ScenePackage& operator=(const ScenePackage&) = delete;

    [[nodiscard]] const std::filesystem::path& root() const { return root_; }
    /// The path the scene loader takes as the wallpaper's source.
    [[nodiscard]] std::string project_file() const { return (root_ / "project.json").string(); }

    /// Writes (or replaces) a file under the project folder; parent folders are created.
    void Put(const std::string& relative_path, std::string_view bytes);
    void PutJson(const std::string& relative_path, const Json& document);
    [[nodiscard]] bool Contains(const std::string& relative_path) const;

    /// Writes `project.json` for a scene project with these property declarations.
    void SetProject(const Json& properties = Json::object());
    /// Writes `scene.json`.
    void SetScene(const Json& scene);

    /// The shaders and the white texture the model helpers below rely on. Called by every
    /// helper that needs them, so a test rarely calls it itself.
    void InstallStandardAssets();
    /// Writes `materials/<name>.tex` and returns `name`, the string a model names it by.
    std::string AddTexture(const std::string& name, const Image& image, TexOptions options = {});
    /// Writes a loose PNG as `materials/<name>.png` and returns `name`.
    std::string AddPngTexture(const std::string& name, const Image& image);
    /// A model (and material) drawing `texture` ("util/white" for a flat colour) through the
    /// standard image shader. Returns the path to put in `ImageLayer::model`.
    std::string AddImageModel(const std::string& name, const std::string& texture = "util/white",
                              ModelOptions options = {});
    /// An effect file that multiplies what it receives by a "tint" constant. Returns the path
    /// to pass to `EffectUse`.
    std::string AddTintEffect(const std::string& name);
    /// Installs a shader pair under `shaders/<name>.vert|.frag`.
    void AddShader(const std::string& name, std::string_view vertex, std::string_view fragment);

    /// Convenience for the commonest scene: one solid colour layer filling a default canvas.
    /// Writes project.json and scene.json.
    void MakeSolidScene(Rgba colour);

private:
    std::filesystem::path root_;
    bool                  standard_assets_ { false };
};

/// The standard vertex shader of the synthetic assets, for tests that install their own
/// fragment shader with `AddShader`.
std::string_view StandardVertexShader();

} // namespace we_test
