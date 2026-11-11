// In-memory fixtures for the scene-schema behaviour tests (scene_schema_part*_test).
//
// Everything here is plain test data and a thin driver: a read-only file system over a map, a
// byte writer for the binary model/texture containers, the file sets the schema tests mount at
// /assets, scene-file skeletons, and a rig that parses a scene document headlessly. Nothing
// draws, nothing opens a device or a window, and nothing touches the disk or the user's
// preferences.
//
// Conventions shared by every part that uses this layer:
//   * A `FileMap` maps a path *relative to the mount* (so it starts with '/') to the file's
//     bytes. `MountAssets` mounts one at /assets, where the scene parser looks for assets.
//   * The `*Assets()` builders return a complete, self-consistent file set; a test that needs
//     a variation takes the map and replaces or adds entries before mounting it. `Add` merges
//     two sets (later entries win).
//   * The API is stable: a part that needs more writes it in its own test file, not here.
#pragma once

#include "Audio/SoundManager.h"
#include "Fs/Fs.h"
#include "Fs/VFS.h"
#include "Project/ProjectProperties.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneNode.h"
#include "Scene/SceneVertexArray.h"

#include <nlohmann/json.hpp>

#include <array>
#include <cstddef>
#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

namespace we_schema
{

using Json    = nlohmann::json;
using FileMap = std::map<std::string, std::string>;

// ---- file system -------------------------------------------------------------------------

/// A read-only `fs::Fs` over a map of path to bytes. `Contains` is "the key is present", `Open`
/// streams the bytes (null when absent) and `OpenW` always refuses.
class MemoryFs final : public wallpaper::fs::Fs {
public:
    explicit MemoryFs(FileMap files) : files_(std::move(files)) {}

    bool Contains(std::string_view path) const override;
    std::shared_ptr<wallpaper::fs::IBinaryStream>  Open(std::string_view path) override;
    std::shared_ptr<wallpaper::fs::IBinaryStreamW> OpenW(std::string_view path) override;

private:
    FileMap files_;
};

/// Mounts `files` at /assets of `vfs`.
void MountAssets(wallpaper::fs::VFS& vfs, FileMap files);

/// Copies every entry of `more` into `into`, replacing entries of the same path.
void Add(FileMap& into, const FileMap& more);

/// Stores `document` serialised as JSON text under `path`.
void PutJson(FileMap& files, const std::string& path, const Json& document);

// ---- bytes -------------------------------------------------------------------------------

/// Writes the little-endian binary containers (model files, textures).
class ByteWriter {
public:
    /// The 9-byte container stamp: `prefix` (4 chars), `version` as four zero-padded decimal
    /// digits, a NUL. `Stamp("MDLV", 21)` writes "MDLV0021\0".
    ByteWriter& Stamp(std::string_view prefix, int version);
    /// The bytes, then a NUL.
    ByteWriter& Str(std::string_view text);
    ByteWriter& U8(std::uint8_t value);
    ByteWriter& U16(std::uint16_t value);
    ByteWriter& U32(std::uint32_t value);
    ByteWriter& I32(std::int32_t value);
    ByteWriter& F32(float value);
    /// Raw bytes with no terminator.
    ByteWriter& Raw(std::string_view bytes);

    /// Where the next byte lands.
    [[nodiscard]] std::size_t Size() const { return bytes_.size(); }
    /// Overwrites four already-written bytes with `value` (to back-fill an end offset).
    ByteWriter& PatchU32(std::size_t at, std::uint32_t value);
    [[nodiscard]] const std::string& Bytes() const { return bytes_; }
    [[nodiscard]] std::string        Take() { return std::move(bytes_); }

private:
    std::string bytes_;
};

// ---- binary model and texture files ------------------------------------------------------

/// Skinned two-mesh puppet: head (`mat/head.json`, part 10) and eyes (`mat/eyes.json`, part 20),
/// one bone `root`.
std::string MdlTwoMeshes();
/// As `MdlTwoMeshes` at version 23, with the first mesh carrying a mask-material extension
/// (`mat/head_mask.json`).
std::string MdlMaskedHead();
/// As MdlMaskedHead, with a second mask on the head drawn from the piece the first clips.
std::string MdlNestedMaskedHead();
/// One mesh and two bones (`root`, `head` whose parent is `root`) plus one attachment named
/// `hat_anchor` whose matrix is the identity translated by (4, 5, 6).
std::string MdlWithAttachment();
/// Two meshes of plain position+UV vertices and no skeleton.
std::string MdlMeshOnly();
/// A `.tex` container whose header flags mark it as a video texture; it needs no decoder.
std::string TexVideoMarker();

// ---- file sets ---------------------------------------------------------------------------

/// The shader pair `genericimage` (vertex forwards position and UV, fragment samples
/// `g_Texture0`) at /shaders/genericimage.{vert,frag}.
FileMap GenericImageShaders();

/// Files for image and particle objects:
///   /image.json (64x32, material mat.json), /mat.json (one translucent, nocull, no-depth
///   pass of shader `genericimage`, texture `a.tex`), the `genericimage` shaders, an EMPTY
///   /materials/a.tex.tex, /particle.json (one emitter `emit` id 1, material mat.json,
///   maxcount 4, starttime 0, one child `child_particle.json`: type `eventspawn`, maxcount 3,
///   origin [1,2,3], scale [.5,.5,1], angles [0,0,45]) and /child_particle.json (one emitter
///   `child_emit` id 2, maxcount 2, starttime 1).
FileMap BasicAssets();

struct PuppetOptions {
    /// Keep `mat/eyes.json`; without it the eyes mesh has no material.
    bool eyes_material { true };
    /// Make the eyes material's texture the render target name `_rt_4FrameBuffer`.
    bool eyes_render_target { false };
    /// Use the masked model (`MdlMaskedHead`) plus the mask material and its shader pair.
    bool masked { false };
    /// With `masked`: use `MdlNestedMaskedHead`, whose second mask is nested in the first.
    bool nested_masks { false };
    /// Use the skeleton-less `MdlMeshOnly` model.
    bool mesh_only { false };
};
/// Files for an image layer `puppet_image.json` (64x32, material `mat/base.json`, puppet
/// `puppet.mdl`): the model per `options`, the three materials and their shaders, and the
/// empty textures. Every fragment multiplies `g_Texture0` by `g_Tint`
/// (`{"material":"tint","default":0.0}`).
FileMap PuppetAssets(const PuppetOptions& options = {});

/// Files for a model layer: `/planet.mdl` (`MdlMeshOnly`), materials `/mat/head.json` (blending
/// normal, cullmode normal, depth test and write enabled) and `/mat/eyes.json` (blending
/// normal, nocull, depth test enabled, write disabled), both on shader `genericimage`
/// (whose fragment also declares the eye/view/light uniforms) with texture `a.tex`, and an
/// empty /materials/a.tex.tex. The two slot materials differ only in cull and depth write.
FileMap LeafModelAssets();
/// The text of a material file with one pass: shader `genericimage`, texture `a.tex`, and
/// every key of `state` (blending/cullmode/depthtest/depthwrite words, ...) set over it.
std::string LeafMaterialText(const Json& state = Json::object());

/// Which bloom stand-ins to mount. The materials live under /materials/util/.
enum class BloomSet {
    Ldr,       ///< extract with constants bloomstrength/threshold/tint = 9 (to be overwritten), blurs, combine
    LdrBroken, ///< as Ldr without the combine material
    Hdr,       ///< five materials whose shaders are hdr_extract/down/up/cubic/combine
};
FileMap BloomAssets(BloomSet set);

// ---- scene documents ---------------------------------------------------------------------

/// The quiet canvas scene: camera at the origin looking down -z, a 640x360 orthogonal canvas,
/// no bloom, no parallax, black clear colour. `objects` fills the `objects` array; every key of
/// `general_patch` is set over the `general` block (a `null` value is kept as a JSON null).
Json QuietScene(Json objects = Json::array(), const Json& general_patch = Json::object());
/// The perspective ("3D") scene: camera eye [0,10,20] looking at the origin, `orthogonalprojection`
/// null, fov 60, nearz 0.1, farz 5000, parallax off, no bloom. `general_patch` as above.
Json PerspectiveScene(Json objects = Json::array(), const Json& general_patch = Json::object());
/// A canvas scene whose camera looks down the canvas from the origin, with a camera object
/// `shot` (id 9, origin [0,0,500], fov 50) and an image layer `canvas image` (id 310,
/// alignment bottomleft). `camera_patch` is set over the camera object's keys.
Json CanvasWithCameraObject(const Json& camera_patch = Json::object());

/// One camera-path clip moving the camera along +x by 2 units over one second (30 fps, 30
/// frames), starting at `start_x`, looking down -z with up +y and a field of view ramping 40
/// to 60. `visible` and `fps` can be spoiled to build the clips a player must skip.
Json CameraPathClip(double start_x, bool visible = true, int fps = 30, const std::string& mode = "single");
/// `{"paths": clips}` as file text.
std::string CameraPathsText(const std::vector<Json>& clips);

// ---- parsing -----------------------------------------------------------------------------

struct ParseOptions {
    /// Provide a project-property table, so the scene gets a `SceneRuntimeContext`
    /// (`scene->runtime`). Without it the id-only overload is used: no runtime, nothing dynamic.
    bool          live { false };
    /// Package version stamp passed in the request (0 = unknown).
    std::uint16_t pkg_version { 0 };
    /// Scene quality passed in the request. Fixtures parse at Ultra post-processing so an
    /// HDR scene keeps its HDR pipeline (the app's default level, Enabled, draws LDR bloom).
    wallpaper::SceneQuality quality { .post_processing = static_cast<int>(wallpaper::PostProcessing::Ultra) };
};

/// Mounts a file set and parses scene documents through it, headless. One rig holds one
/// virtual file system and a null-output sound manager; the parsed scene may be inspected and
/// ticked while the rig lives.
class ParseRig {
public:
    explicit ParseRig(FileMap assets);
    ~ParseRig();
    ParseRig(const ParseRig&)            = delete;
    ParseRig& operator=(const ParseRig&) = delete;

    /// Parses `scene_json`; null when the parser refuses the scene.
    std::shared_ptr<wallpaper::Scene> Parse(const Json& scene_json, ParseOptions options = {});
    std::shared_ptr<wallpaper::Scene> Parse(const std::string& scene_text, ParseOptions options = {});

    wallpaper::fs::VFS&             vfs() { return *vfs_; }
    wallpaper::audio::SoundManager& sound() { return *sound_; }
    /// The (empty) project-property table `live` parses use.
    wallpaper::ProjectProperties&   properties() { return properties_; }

private:
    std::unique_ptr<wallpaper::fs::VFS>             vfs_;
    std::unique_ptr<wallpaper::audio::SoundManager> sound_;
    wallpaper::ProjectProperties                    properties_;
    std::shared_ptr<wallpaper::Scene>               scene_;
};

// ---- reading a parsed scene --------------------------------------------------------------

/// The first direct child of `parent` named `name`, or null.
wallpaper::SceneNode* FindChild(wallpaper::SceneNode& parent, std::string_view name);
/// The first child of the scene graph's root named `name`, or null.
wallpaper::SceneNode* FindRootChild(wallpaper::Scene& scene, std::string_view name);

/// Position (floats 0..2) and texture coordinate (floats 4..5) of vertex `index`.
std::array<float, 3> VertexPosition(const wallpaper::SceneVertexArray& vertices, std::size_t index);
std::array<float, 2> VertexUv(const wallpaper::SceneVertexArray& vertices, std::size_t index);

/// The `index`-th step of a post-process chain as a pass / as a copy; null when it is the other
/// kind or past the end.
const wallpaper::ScenePostProcessPass* PassStep(const wallpaper::ScenePostProcess& chain, std::size_t index);
const wallpaper::ScenePostProcessCopy* CopyStep(const wallpaper::ScenePostProcess& chain, std::size_t index);

/// Whether every component of `actual` is within `tolerance` of `expected`.
bool NearArray(const std::array<float, 3>& actual, const std::array<float, 3>& expected, float tolerance);

} // namespace we_schema
