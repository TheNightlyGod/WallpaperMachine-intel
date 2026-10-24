#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include "Audio/SoundManager.h"
#include "Interface/IShaderValueUpdater.h"
#include "Fs/Fs.h"
#include "Fs/MemBinaryStream.h"
#include "Fs/VFS.h"
#include "support/byte_fs.hpp"
#include "Image.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneCamera.h"
#include "Scene/SceneImageEffectLayer.h"
#include "Scene/SceneLayerReference.hpp"
#include "SpecTexs.hpp"
#include "WPSceneParser.hpp"
#include "RenderCommon/ScenePass.hpp"
#include "RenderCommon/SceneRaster.hpp"
#include "RenderGraph/RenderGraph.hpp"
#include "RenderCommon/SceneToRenderGraph.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <functional>
#include <limits>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace
{
using namespace wallpaper;

// The in-memory file space the tests mount; text goes in, the project's byte map serves it.
std::unique_ptr<fs::Fs> MakeTextFs(const std::map<std::string, std::string>& files) {
    test::MapFs::Files bytes;
    for (const auto& [path, text] : files) bytes[path].assign(text.begin(), text.end());
    return std::make_unique<test::MapFs>(std::move(bytes));
}

constexpr std::string_view kVert = R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)";
constexpr std::string_view kFrag = R"(uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)";

std::string SceneJson(std::string_view objects) {
    return std::string(R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":64,"height":32}
      },
      "objects": )") + std::string(objects) + "}";
}

void MountFiles(fs::VFS& vfs, std::map<std::string, std::string> extra = {}) {
    auto files = std::map<std::string, std::string> {
        { "/image.json", R"({"width":64,"height":32,"material":"mat.json"})" },
        { "/mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["solid"]}]})" },
        { "/linked.json", R"({"width":64,"height":32,"material":"linked_mat.json"})" },
        { "/shaders/genericimage.vert", std::string(kVert) },
        { "/shaders/genericimage.frag", std::string(kFrag) },
        { "/materials/solid.tex", "" },
    };
    for (auto& [path, content] : extra) files[path] = std::move(content);
    ASSERT_TRUE(vfs.Mount("/assets", MakeTextFs(files)));
}

/// With `properties`, parsed with a runtime as the wallpaper is, so a layer the
/// scene file hides is hidden for good rather than until a script says otherwise.
std::shared_ptr<Scene> ParseScene(fs::VFS& vfs, std::string_view objects,
                                  std::map<std::string, std::string> extra = {},
                                  const ProjectProperties* properties = nullptr) {
    MountFiles(vfs, std::move(extra));
    audio::SoundManager sound;
    WPSceneParser       parser;
    return parser.Parse(
        SceneParseRequest { .scene_id = "layer-texture", .project_properties = properties },
        SceneJson(objects), vfs, sound);
}

const rg::DrawPass* FindPassByNode(
    const rg::RenderGraph& graph, std::string_view name) {
    for (const auto id : graph.topologicalOrder()) {
        auto* pass = dynamic_cast<const rg::DrawPass*>(graph.getPass(id));
        if (pass != nullptr && pass->desc().node != nullptr &&
            pass->desc().node->Name() == name) {
            return pass;
        }
    }
    return nullptr;
}

size_t PassIndexByNode(const rg::RenderGraph& graph, std::string_view name) {
    size_t index = 0;
    for (const auto id : graph.topologicalOrder()) {
        auto* pass = dynamic_cast<const rg::DrawPass*>(graph.getPass(id));
        if (pass != nullptr && pass->desc().node != nullptr &&
            pass->desc().node->Name() == name) {
            return index;
        }
        ++index;
    }
    return static_cast<size_t>(-1);
}

const rg::CopyPass* FindLinkCopy(const rg::RenderGraph& graph, std::string_view dst) {
    for (const auto id : graph.topologicalOrder()) {
        auto* pass = dynamic_cast<const rg::CopyPass*>(graph.getPass(id));
        if (pass != nullptr && pass->desc().dst == dst) return pass;
    }
    return nullptr;
}

const rg::DrawPass* FindPassByOutput(const rg::RenderGraph& graph,
                                                 std::string_view output) {
    const rg::DrawPass* found = nullptr;
    for (const auto id : graph.topologicalOrder()) {
        auto* pass = dynamic_cast<const rg::DrawPass*>(graph.getPass(id));
        if (pass != nullptr && pass->desc().output == output) found = pass;
    }
    return found;
}

// A 64x32 canvas with camera parallax on, so a test can move the cursor and see
// whether the shift reaches an image it must not.
std::string ParallaxSceneJson(std::string_view objects) {
    return std::string(R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":true,
        "cameraparallaxamount":1, "cameraparallaxdelay":0.1,
        "cameraparallaxmouseinfluence":1,
        "orthogonalprojection":{"width":64,"height":32}
      },
      "objects": )") + std::string(objects) + "}";
}

std::map<std::string, std::string> CopyEffectFiles() {
    return {
        { "/effects/copy/effect.json",
          R"({"name":"copy","passes":[{"material":"materials/copy.json"}]})" },
        { "/materials/copy.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":[null]}]} )" },
    };
}

void AddScreenTarget(Scene& scene) {
    scene.renderTargets[std::string(SpecTex_Default)] = SceneRenderTarget {
        .width = 64, .height = 32, .allowReuse = true,
    };
}

/// Asks the value updater, as a backend does before drawing `pass`, for the
/// uniforms named in `wanted`, through the camera the pass draws with.
std::map<std::string, ShaderValue, std::less<>> PassUniforms(
    Scene& scene, const rg::DrawPass& pass, std::vector<std::string_view> wanted) {
    auto*          node = pass.desc().node;
    const uint32_t slot = pass.desc().material_slot;
    auto&          updater = *scene.shaderValueUpdater;
    updater.InitUniforms(node, slot, [&wanted](std::string_view name) {
        return std::find(wanted.begin(), wanted.end(), name) != wanted.end();
    });
    const std::string camera = node->Camera();
    if (! pass.desc().camera_override.empty()) node->SetCamera(pass.desc().camera_override);
    sprite_map_t                                    sprites;
    std::map<std::string, ShaderValue, std::less<>> values;
    updater.UpdateUniforms(node, slot, sprites, [&values](std::string_view name, const ShaderValue& v) {
        values[std::string(name)] = v;
    });
    node->SetCamera(camera);
    return values;
}

/// Where `pass` puts a corner of its card, in normalised device coordinates.
linalg::Vector2d CardCornerNdc(Scene& scene, const rg::DrawPass& pass,
                              linalg::Vector2d corner) {
    const auto uniforms = PassUniforms(scene, pass, { "g_ModelViewProjectionMatrix" });
    const auto found    = uniforms.find("g_ModelViewProjectionMatrix");
    if (found == uniforms.end() || found->second.size() != 16) {
        ADD_FAILURE() << "the pass was given no model-view-projection matrix";
        return linalg::Vector2d::Constant(std::nan(""));
    }
    const linalg::Matrix4f mvp  = linalg::Map<const linalg::Matrix4f>(found->second.data());
    const linalg::Vector4f clip = mvp * linalg::Vector4f(corner.x(), corner.y(), 0.0f, 1.0f);
    return { clip.x() / clip.w(), clip.y() / clip.w() };
}

void ExpectCardFillsItsTarget(Scene& scene, const rg::DrawPass& pass,
                              linalg::Vector2d lower_left_corner, linalg::Vector2d upper_right_corner) {
    const auto lower_left  = CardCornerNdc(scene, pass, lower_left_corner);
    const auto upper_right = CardCornerNdc(scene, pass, upper_right_corner);
    EXPECT_NEAR(lower_left.x(), -1.0, 1e-4);
    EXPECT_NEAR(lower_left.y(), -1.0, 1e-4);
    EXPECT_NEAR(upper_right.x(), 1.0, 1e-4);
    EXPECT_NEAR(upper_right.y(), 1.0, 1e-4);
}

void ExpectCardFillsItsTarget(Scene& scene, const rg::DrawPass& pass,
                              linalg::Vector2d half_extent) {
    ExpectCardFillsItsTarget(scene, pass, -half_extent, half_extent);
}

/// The lower-left and upper-right corners of a card mesh, in the space it is
/// authored in.
std::pair<linalg::Vector2d, linalg::Vector2d> CardCorners(const SceneMesh& mesh) {
    const auto& vertices = mesh.GetVertexArray(0);
    const auto  offsets  = vertices.GetAttrOffsetMap();
    const auto  position = offsets.find(std::string(WE_IN_POSITION));
    linalg::Vector2d lower = linalg::Vector2d::Constant(std::numeric_limits<double>::infinity());
    linalg::Vector2d upper = -lower;
    if (position == offsets.end()) return { lower, upper };
    for (std::size_t vertex = 0; vertex < vertices.VertexCount(); ++vertex) {
        const float* xy = vertices.Data() + vertex * vertices.OneSize() +
                          position->second.offset / sizeof(float);
        lower = lower.cwiseMin(linalg::Vector2d(xy[0], xy[1]));
        upper = upper.cwiseMax(linalg::Vector2d(xy[0], xy[1]));
    }
    return { lower, upper };
}

/// Lays a text layer out as the wallpaper's frame loop does, until the layout
/// lands. False when it never does.
bool PumpTextLayout(SceneRuntimeContext& runtime, std::string_view name) {
    for (int attempt = 0; attempt < 200; ++attempt) {
        runtime.PumpTextLayerCache();
        if (! runtime.NodeTextDirty(name)) return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    return false;
}

} // namespace

TEST(LayerTextureReference, CompositeIdIsTheAuthoredSyntax) {
    LayerCompositeSlot slot = LayerCompositeSlot::None;
    const auto         id   = ParseImageLayerCompositeId("_rt_imageLayerComposite_14942_a", &slot);
    ASSERT_TRUE(id.has_value());
    EXPECT_EQ(*id, 14942);
    EXPECT_EQ(slot, LayerCompositeSlot::A);
    EXPECT_EQ(ParseImageLayerCompositeId("_rt_imageLayerComposite_14942_b", &slot).value_or(0),
              14942);
    EXPECT_EQ(slot, LayerCompositeSlot::B);
    EXPECT_TRUE(ParseImageLayerCompositeId("_rt_imageLayerComposite_159").has_value());
}

TEST(LayerTextureReference, ForwardReferenceResolvesById) {
    const auto objects = nlohmann::json::parse(R"([
      {"id":160,"name":"consumer","image":"linked.json",
       "effects":[{"passes":[{"textures":["_rt_imageLayerComposite_159_a"]}]}]},
      {"id":159,"name":"source","image":"image.json"}
    ])");
    const auto index = BuildLayerObjectIndex(objects);
    auto       resolved =
        ResolveLayerTextureName("_rt_imageLayerComposite_159_a", index, nullptr);
    EXPECT_TRUE(resolved.is_layer);
    EXPECT_EQ(resolved.source_id, 159);
    EXPECT_TRUE(resolved.error.empty());
    EXPECT_EQ(resolved.resolved, GenLinkTex(159));
}

TEST(LayerTextureReference, DuplicateNameIsExplicit) {
    const auto objects = nlohmann::json::parse(R"([
      {"id":1,"name":"dup","image":"image.json"},
      {"id":2,"name":"dup","image":"image.json"}
    ])");
    const auto index    = BuildLayerObjectIndex(objects);
    auto       resolved = ResolveLayerTextureName("dup", index, nullptr);
    EXPECT_TRUE(resolved.is_layer);
    EXPECT_EQ(resolved.error, kLayerTextureDuplicateName);
    EXPECT_NE(resolved.resolved, GenLinkTex(1));
}

TEST(LayerTextureReference, MissingTargetIsExplicit) {
    const auto objects = nlohmann::json::parse(R"([{"id":1,"name":"only","image":"image.json"}])");
    const auto index   = BuildLayerObjectIndex(objects);
    auto       resolved =
        ResolveLayerTextureName("_rt_imageLayerComposite_99_a", index, nullptr);
    EXPECT_TRUE(resolved.is_layer);
    EXPECT_EQ(resolved.error, kLayerTextureMissingTarget);
}

TEST(LayerTextureReference, CycleIsExplicit) {
    const auto objects = nlohmann::json::parse(R"([
      {"id":1,"name":"a","image":"image.json",
       "effects":[{"passes":[{"textures":["_rt_imageLayerComposite_2_a"]}]}]},
      {"id":2,"name":"b","image":"image.json",
       "effects":[{"passes":[{"textures":["_rt_imageLayerComposite_1_a"]}]}]}
    ])");
    const auto index = BuildLayerObjectIndex(objects);
    const auto refs  = CollectLayerTextureRefs(objects, index, nullptr);
    EXPECT_EQ(ClassifyLayerTextureReferences(refs, index), kLayerTextureIllegalCycle);
}

TEST(LayerTextureReference, SelfBInItsOwnEffectsIsNotAReference) {
    const auto objects = nlohmann::json::parse(R"([
      {"id":7,"name":"self","image":"image.json",
       "effects":[{"passes":[{"textures":["_rt_imageLayerComposite_7_b"]}]}]}
    ])");
    const auto index = BuildLayerObjectIndex(objects);
    const auto refs  = CollectLayerTextureRefs(objects, index, nullptr);
    EXPECT_TRUE(refs.empty());
    EXPECT_TRUE(ClassifyLayerTextureReferences(refs, index).empty());
}

TEST(LayerTextureReference, ALayersOwnCompositeOutsideItsEffectsIsNotARefusal) {
    // Its own `_a` or `_b` outside its effects is the composite as the frame before left it,
    // which the render graph keeps for it; neither slot is a reason to refuse a scene,
    // and neither is a reference to another layer.
    for (const char* slot : { "a", "b" }) {
        SCOPED_TRACE(slot);
        const auto objects = nlohmann::json::parse(
            R"([{"id":7,"name":"self","image":"image.json","textures":["_rt_imageLayerComposite_7_)" +
            std::string(slot) + R"("]}])");
        const auto index = BuildLayerObjectIndex(objects);
        const auto refs  = CollectLayerTextureRefs(objects, index, nullptr);
        ASSERT_EQ(refs.size(), 1u);
        EXPECT_EQ(refs.front().consumer_id, 7);
        EXPECT_EQ(refs.front().source_id, 7);
        EXPECT_TRUE(ClassifyLayerTextureReferences(refs, index).empty());
    }
}

TEST(LayerTextureReference, FileNameIsNotALayerEvenWhenNamesMatch) {
    fs::VFS vfs;
    MountFiles(vfs);
    const auto objects = nlohmann::json::parse(R"([
      {"id":1,"name":"solid","image":"image.json"}
    ])");
    const auto index    = BuildLayerObjectIndex(objects);
    auto       resolved = ResolveLayerTextureName("solid", index, &vfs);
    EXPECT_FALSE(resolved.is_layer);
    EXPECT_EQ(resolved.resolved, "solid");
}

// Render targets are the names that start with `_rt_` (or `_alias_`); any other
// texture name is a file, whatever it starts with. Layers exported from an image
// editor are often named like `_0022_Eyes`, and their textures with them: read as
// a render target nobody registered, the slot was left unbound and the layer never
// drew.
TEST(LayerTextureReference, ATextureNamedWithALeadingUnderscoreIsItsFile) {
    const auto material = [](std::string_view texture) {
        return std::string(R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":[")") +
               std::string(texture) + R"("]}]})";
    };
    fs::VFS vfs;
    auto    parsed = ParseScene(vfs, R"([
        {"id":1,"name":"_eyes","image":"eyes.json"},
        {"id":2,"name":"lids","image":"lids.json"}
      ])",
      {{ "/eyes.json", R"({"width":64,"height":32,"material":"eyes_mat.json"})" },
       { "/eyes_mat.json", material("_eyes") },
       { "/materials/_eyes.tex", "" },
       { "/lids.json", R"({"width":64,"height":32,"material":"lids_mat.json"})" },
       { "/lids_mat.json", material("__drawn_by__lids") },
       { "/materials/__drawn_by__lids.tex", "" }});
    ASSERT_NE(parsed, nullptr);

    for (const auto& [layer, texture] : { std::pair { "_eyes", "_eyes" }, std::pair { "lids", "__drawn_by__lids" } }) {
        SCOPED_TRACE(layer);
        SceneNode* node = nullptr;
        for (auto& child : parsed->sceneGraph->GetChildren()) {
            if (child->Name() == layer) node = child.get();
        }
        ASSERT_NE(node, nullptr);
        ASSERT_NE(node->Mesh(), nullptr);
        const auto* drawn = node->Mesh()->MaterialForSlot(0);
        ASSERT_NE(drawn, nullptr);
        ASSERT_FALSE(drawn->textures.empty());
        EXPECT_EQ(drawn->textures[0], texture);
        EXPECT_FALSE(IsSpecTex(drawn->textures[0]));
        EXPECT_EQ(parsed->FindRenderTarget(texture), nullptr);
    }
}

// An effect's own buffers are render targets whatever the effect calls them: a
// bokeh blur declares `_coc` and `_full1`, a buffer may have no underscore at all,
// `plain` and `_rt_plain` are two buffers, and one named like an alias is still a
// target the engine made. Each pass that binds one reads what the pass before it
// drew there.
TEST(LayerTextureReference, AnEffectsOwnBuffersAreTargetsWhateverTheyAreCalled) {
    fs::VFS vfs;
    auto    parsed = ParseScene(vfs, R"([
        {"id":5,"name":"blurred","image":"image.json",
         "effects":[{"file":"effects/buffers/effect.json","id":6,"visible":true}]}
      ])",
      {{ "/effects/buffers/effect.json",
         R"({"name":"buffers","fbos":[{"name":"_half","scale":2},{"name":"plain","scale":1},{"name":"_rt_plain","scale":1},{"name":"_alias_cookie","scale":1}],"passes":[)"
         R"({"material":"materials/copy.json","target":"_half","bind":[{"name":"previous","index":0}]},)"
         R"({"material":"materials/copy.json","target":"plain","bind":[{"name":"_half","index":0}]},)"
         R"({"material":"materials/copy.json","target":"_rt_plain","bind":[{"name":"plain","index":0}]},)"
         R"({"material":"materials/copy.json","target":"_alias_cookie","bind":[{"name":"_rt_plain","index":0}]},)"
         R"({"material":"materials/copy.json","bind":[{"name":"_alias_cookie","index":0}]}]})" },
       { "/materials/copy.json",
         R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":[null]}]} )" }});
    ASSERT_NE(parsed, nullptr);

    // The buffers the first four passes draw into, in the effect's own order.
    SceneNode* layer = nullptr;
    for (auto& child : parsed->sceneGraph->GetChildren()) {
        if (child->Name() == "blurred") layer = child.get();
    }
    ASSERT_NE(layer, nullptr);
    const auto camera = parsed->cameras.find(layer->Camera());
    ASSERT_NE(camera, parsed->cameras.end());
    ASSERT_TRUE(camera->second->HasImgEffect());
    const auto& effect = *camera->second->GetImgEffect()->GetEffect(0);
    ASSERT_EQ(effect.nodes.size(), 5u);
    std::vector<std::string> buffers;
    for (const auto& node : effect.nodes) {
        if (buffers.size() < 4) buffers.push_back(node.output);
    }
    EXPECT_EQ(std::set<std::string>(buffers.begin(), buffers.end()).size(), 4u)
        << "two buffers of the effect were given one target";

    AddScreenTarget(*parsed);
    if (parsed->cameras.find("effect") == parsed->cameras.end()) {
        parsed->cameras["effect"] = std::make_shared<SceneCamera>(64, 32, 0.01f, 100.0f);
    }
    parsed->activeCamera = nullptr;
    const auto graph = sceneToRenderGraph(*parsed);
    ASSERT_NE(graph, nullptr);

    std::vector<std::pair<rg::NodeID, const rg::DrawPass*>> passes;
    for (const auto id : graph->topologicalOrder()) {
        if (auto* pass = dynamic_cast<const rg::DrawPass*>(graph->getPass(id))) passes.emplace_back(id, pass);
    }
    for (const auto& key : buffers) {
        SCOPED_TRACE(key);
        EXPECT_NE(parsed->FindRenderTarget(key), nullptr) << "the effect's buffer was never registered";
        EXPECT_TRUE(StartsWithText(key, WE_SPEC_PREFIX)) << key << " is not named as a target the engine made";
        const auto writer = std::find_if(passes.begin(), passes.end(),
                                         [&key](const auto& pass) { return pass.second->desc().output == key; });
        const auto reader = std::find_if(passes.begin(), passes.end(), [&key](const auto& pass) {
            const auto& textures = pass.second->desc().textures;
            return ! textures.empty() && textures[0] == key;
        });
        ASSERT_NE(writer, passes.end());
        ASSERT_NE(reader, passes.end());
        EXPECT_TRUE(graph->mustPrecede(writer->first, reader->first));
    }
}

TEST(LayerTextureReference, ParserKeepsInvisibleCompositeSource) {
    fs::VFS vfs;
    auto    parsed = ParseScene(vfs, R"([
        {"id":159,"name":"source","image":"image.json","visible":false},
        {"id":160,"name":"consumer","image":"linked.json","visible":true,
         "dependencies":[159]}
      ])",
      {{ "/linked_mat.json",
         R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["_rt_imageLayerComposite_159_a"]}]})" }});
    ASSERT_NE(parsed, nullptr);
    EXPECT_TRUE(parsed->layer_texture_error.empty());
    EXPECT_TRUE(parsed->layer_texture_sources.contains(159));
    SceneNode* source = nullptr;
    for (auto& child : parsed->sceneGraph->GetChildren()) {
        if (child->Name() == "source") source = child.get();
    }
    ASSERT_NE(source, nullptr);
    EXPECT_FALSE(source->Visible());
    EXPECT_TRUE(source->MustProduce());
}

// A model may tile a layer texture hundreds of times (UVs far outside 0..1).
// Clamping smeared the edge texels into solid bands across it.
TEST(LayerTextureReference, CompositeAddressingFollowsTheSourceLayersClampUvs) {
    const auto wrap_for = [](std::string_view clamp) {
        fs::VFS vfs;
        auto    parsed = ParseScene(vfs, std::string(R"([
            {"id":159,"name":"source","image":"image.json","visible":false)") +
                std::string(clamp) + R"(},
            {"id":160,"name":"consumer","image":"linked.json","dependencies":[159]}
          ])",
          {{ "/linked_mat.json",
             R"({"passes":[{"shader":"genericimage","textures":["_rt_imageLayerComposite_159_a"]}]})" }});
        EXPECT_NE(parsed, nullptr);
        const auto* target =
            parsed == nullptr ? nullptr : parsed->FindRenderTarget(LayerCompositeTargetKey(159));
        EXPECT_NE(target, nullptr);
        return target == nullptr ? std::pair { TextureWrap::REPEAT, TextureWrap::REPEAT }
                                 : std::pair { target->sample.wrapS, target->sample.wrapT };
    };
    const auto clamp  = std::pair { TextureWrap::CLAMP_TO_EDGE, TextureWrap::CLAMP_TO_EDGE };
    const auto repeat = std::pair { TextureWrap::REPEAT, TextureWrap::REPEAT };
    EXPECT_EQ(wrap_for(",\"clampuvs\":false"), repeat);
    EXPECT_EQ(wrap_for(",\"clampuvs\":true"), clamp);
    EXPECT_EQ(wrap_for(""), clamp);
}

// A texture whose header is all the parser reads: one pixel, `flags` as the
// header carries them (bit 0 asks for point sampling, bit 1 for clamping).
std::string TextureHeaderBytes(uint32_t flags) {
    std::string bytes;
    const auto  append = [&bytes](const void* data, std::size_t size) {
        bytes.append(static_cast<const char*>(data), size);
    };
    const auto stamp = [&](const char* text) { append(text, 9); };
    const auto i32   = [&](int32_t value) { append(&value, sizeof(value)); };
    stamp("TEXV0005");
    stamp("TEXI0001");
    i32(9); // R8
    append(&flags, sizeof(flags));
    for (int index = 0; index < 4; ++index) i32(1);
    i32(0);
    stamp("TEXB0003");
    i32(1);
    i32(static_cast<int32_t>(ImageType::UNKNOWN));
    i32(0);
    return bytes;
}

// The render targets of an image layer are sampled by the passes of its effect
// chain and by whoever reads its composite. Wallpaper Engine point-samples them
// when the layer asks (`nointerpolation`) or when its texture's header does, and
// wraps them instead of clamping when `clampuvs` is off.
TEST(LayerTextureReference, LayerTargetsFollowNointerpolationClampuvsAndTheTextureHeader) {
    const auto material = [](std::string_view texture) {
        return std::string(R"({"passes":[{"blending":"translucent","cullmode":"nocull",)") +
               R"("depthtest":"disabled","depthwrite":"disabled","shader":"genericimage",)" +
               R"("textures":[")" + std::string(texture) + R"("]}]})";
    };
    auto files = CopyEffectFiles();
    files["/img_linear.json"]   = R"({"width":64,"height":32,"material":"mat_linear.json"})";
    files["/mat_linear.json"]   = material("linear");
    files["/materials/linear.tex"] = TextureHeaderBytes(0);
    files["/img_point.json"]    = R"({"width":64,"height":32,"material":"mat_point.json"})";
    files["/mat_point.json"]    = material("point");
    files["/materials/point.tex"] = TextureHeaderBytes(1);
    files["/linked_mat.json"] =
        R"({"passes":[{"shader":"genericimage","textures":["_rt_imageLayerComposite_14_a"]}]})";

    fs::VFS vfs;
    auto    parsed = ParseScene(vfs, R"([
        {"id":10,"name":"plain","image":"img_linear.json",
         "effects":[{"file":"effects/copy/effect.json","id":90,"visible":true}]},
        {"id":11,"name":"nointerp","image":"img_linear.json","nointerpolation":true,
         "effects":[{"file":"effects/copy/effect.json","id":91,"visible":true}]},
        {"id":12,"name":"wrapped","image":"img_linear.json","clampuvs":false,
         "effects":[{"file":"effects/copy/effect.json","id":92,"visible":true}]},
        {"id":13,"name":"header","image":"img_point.json",
         "effects":[{"file":"effects/copy/effect.json","id":93,"visible":true}]},
        {"id":14,"name":"source","image":"img_point.json","visible":false},
        {"id":15,"name":"reader","image":"linked.json","dependencies":[14]}
      ])", files);
    ASSERT_NE(parsed, nullptr);

    const auto ping_pong = [&](std::string_view layer) {
        SceneNode* node = nullptr;
        for (auto& child : parsed->sceneGraph->GetChildren()) {
            if (child->Name() == layer) node = child.get();
        }
        EXPECT_NE(node, nullptr) << layer;
        if (node == nullptr) return TextureSample {};
        const auto* target =
            parsed->FindRenderTarget(std::string(WE_EFFECT_PPONG_PREFIX_A.data()) + node->Camera());
        EXPECT_NE(target, nullptr) << layer;
        const auto* other =
            parsed->FindRenderTarget(std::string(WE_EFFECT_PPONG_PREFIX_B.data()) + node->Camera());
        EXPECT_NE(other, nullptr) << layer;
        if (target == nullptr || other == nullptr) return TextureSample {};
        EXPECT_EQ(other->sample.wrapS, target->sample.wrapS) << layer;
        EXPECT_EQ(other->sample.magFilter, target->sample.magFilter) << layer;
        return target->sample;
    };
    const auto expect_sample = [](const TextureSample& sample, TextureWrap wrap,
                                  TextureFilter filter, std::string_view what) {
        EXPECT_EQ(sample.wrapS, wrap) << what;
        EXPECT_EQ(sample.wrapT, wrap) << what;
        EXPECT_EQ(sample.magFilter, filter) << what;
        EXPECT_EQ(sample.minFilter, filter) << what;
    };
    expect_sample(ping_pong("plain"), TextureWrap::CLAMP_TO_EDGE, TextureFilter::LINEAR, "plain");
    expect_sample(ping_pong("nointerp"), TextureWrap::CLAMP_TO_EDGE, TextureFilter::NEAREST,
                  "nointerpolation");
    expect_sample(ping_pong("wrapped"), TextureWrap::REPEAT, TextureFilter::LINEAR, "clampuvs off");
    expect_sample(ping_pong("header"), TextureWrap::CLAMP_TO_EDGE, TextureFilter::NEAREST,
                  "point-sampled texture header");

    // The composite another layer reads takes the layer's filter as well.
    const auto* composite = parsed->FindRenderTarget(LayerCompositeTargetKey(14));
    ASSERT_NE(composite, nullptr);
    expect_sample(composite->sample, TextureWrap::CLAMP_TO_EDGE, TextureFilter::NEAREST,
                  "composite of a point-sampled layer");
}

// A layer another layer reads is given its composite before its own material
// is loaded, so the filter the composite takes from the layer's texture header
// cannot come from what an earlier layer loaded: a point-sampled texture that no
// other layer has used yet must still give a point-sampled composite, in the
// same filter as the layer's own ping-pong pair, whichever layer is parsed first.
TEST(LayerTextureReference, ACompositeFollowsItsLayersTextureHeaderWhateverIsParsedFirst) {
    const auto material = [](std::string_view texture) {
        return std::string(R"({"passes":[{"blending":"translucent","cullmode":"nocull",)") +
               R"("depthtest":"disabled","depthwrite":"disabled","shader":"genericimage",)" +
               R"("textures":[")" + std::string(texture) + R"("]}]})";
    };
    const auto files = [&] {
        auto files = CopyEffectFiles();
        files["/img_point.json"]       = R"({"width":64,"height":32,"material":"mat_point.json"})";
        files["/mat_point.json"]       = material("only_user");
        files["/materials/only_user.tex"] = TextureHeaderBytes(1);
        files["/img_other.json"]       = R"({"width":64,"height":32,"material":"mat_other.json"})";
        files["/mat_other.json"]       = material("only_user");
        files["/img_plain.json"]       = R"({"width":64,"height":32,"material":"mat_plain.json"})";
        files["/mat_plain.json"]       = material("plain_user");
        files["/materials/plain_user.tex"] = TextureHeaderBytes(0);
        files["/linked_mat.json"] =
            R"({"passes":[{"shader":"genericimage","textures":["_rt_imageLayerComposite_1_a"]}]})";
        return files;
    };
    const auto filter_of_composite = [&](std::string_view objects, int32_t id) {
        fs::VFS vfs;
        auto    parsed = ParseScene(vfs, objects, files());
        EXPECT_NE(parsed, nullptr);
        const auto* target =
            parsed == nullptr ? nullptr : parsed->FindRenderTarget(LayerCompositeTargetKey(id));
        EXPECT_NE(target, nullptr);
        return target == nullptr ? TextureFilter::LINEAR : target->sample.magFilter;
    };

    // The only layer to use a point-sampled texture, read by a later layer.
    EXPECT_EQ(filter_of_composite(R"([
        {"id":1,"name":"source","image":"img_point.json","visible":false},
        {"id":2,"name":"reader","image":"linked.json","dependencies":[1]}
      ])", 1), TextureFilter::NEAREST);
    // And when it is the first of two to use it, or comes after the reader's
    // other inputs: the same.
    EXPECT_EQ(filter_of_composite(R"([
        {"id":1,"name":"source","image":"img_point.json","visible":false},
        {"id":3,"name":"later","image":"img_other.json"},
        {"id":2,"name":"reader","image":"linked.json","dependencies":[1]}
      ])", 1), TextureFilter::NEAREST);
    EXPECT_EQ(filter_of_composite(R"([
        {"id":3,"name":"earlier","image":"img_other.json"},
        {"id":1,"name":"source","image":"img_point.json","visible":false},
        {"id":2,"name":"reader","image":"linked.json","dependencies":[1]}
      ])", 1), TextureFilter::NEAREST);
    // A texture without the flag is not point-sampled however it is reached.
    EXPECT_EQ(filter_of_composite(R"([
        {"id":1,"name":"source","image":"img_plain.json","visible":false},
        {"id":2,"name":"reader","image":"linked.json","dependencies":[1]}
      ])", 1), TextureFilter::LINEAR);
    // A layer whose texture cannot be read keeps the linear default rather than
    // the point sampling of a header that was never read.
    EXPECT_EQ(filter_of_composite(R"([
        {"id":1,"name":"source","image":"image.json","visible":false},
        {"id":2,"name":"reader","image":"linked.json","dependencies":[1]}
      ])", 1), TextureFilter::LINEAR);

    // With an effect chain of its own, the composite and the ping-pong pair
    // registered after the material agree.
    fs::VFS vfs;
    auto    parsed = ParseScene(vfs, R"([
        {"id":1,"name":"source","image":"img_point.json",
         "effects":[{"file":"effects/copy/effect.json","id":90,"visible":true}]},
        {"id":2,"name":"reader","image":"linked.json","dependencies":[1]}
      ])", files());
    ASSERT_NE(parsed, nullptr);
    const auto* composite = parsed->FindRenderTarget(LayerCompositeTargetKey(1));
    ASSERT_NE(composite, nullptr);
    SceneNode* node = nullptr;
    for (auto& child : parsed->sceneGraph->GetChildren()) {
        if (child->Name() == "source") node = child.get();
    }
    ASSERT_NE(node, nullptr);
    const auto* ping_pong =
        parsed->FindRenderTarget(std::string(WE_EFFECT_PPONG_PREFIX_A.data()) + node->Camera());
    ASSERT_NE(ping_pong, nullptr);
    EXPECT_EQ(composite->sample.magFilter, TextureFilter::NEAREST);
    EXPECT_EQ(ping_pong->sample.magFilter, composite->sample.magFilter);
    EXPECT_EQ(ping_pong->sample.minFilter, composite->sample.minFilter);
}

// Only image, text and model layers are tested for the cursor. A light, a
// camera, a particle emitter and a plain group are registered as layers the
// cursor never reaches, and an image layer carries its own `solid` and
// `disablepropagation`.
TEST(LayerTextureReference, LightsCamerasParticlesAndGroupsAreNeverHitTestedForTheCursor) {
    const ProjectProperties properties {};
    fs::VFS                 vfs;
    auto files = std::map<std::string, std::string> {
        { "/particle.json",
          R"({"emitter":[{"name":"emit","id":1}],"material":"mat.json","maxcount":4,"starttime":0})" },
    };
    auto parsed = ParseScene(vfs, R"([
        {"id":1,"name":"image","image":"image.json","solid":false,"disablepropagation":true},
        {"id":2,"name":"group","origin":"0 0 0"},
        {"id":3,"name":"lamp","light":"point","origin":"8 8 100","color":"1 1 1","radius":50,
         "intensity":1},
        {"id":4,"name":"shot","camera":"default","origin":[8,4,500],"angles":[0,0,0],"fov":50},
        {"id":5,"name":"sparks","particle":"particle.json","origin":[8,4,0],
         "solid":true,"disablepropagation":true}
      ])", files, &properties);
    ASSERT_NE(parsed, nullptr);
    ASSERT_NE(parsed->runtime, nullptr);
    const auto target = [&](std::string_view name) {
        return parsed->runtime->NodeCursorTargetOf(name);
    };
    ASSERT_TRUE(target("image").has_value());
    EXPECT_TRUE(target("image")->hittable);
    EXPECT_FALSE(target("image")->solid);
    EXPECT_TRUE(target("image")->blocks);
    for (const char* name : { "group", "lamp", "shot", "sparks" }) {
        SCOPED_TRACE(name);
        ASSERT_TRUE(target(name).has_value()) << "the kind of layer was never registered";
        EXPECT_FALSE(target(name)->hittable);
    }
}

// The cursor is tested against image, text and model layers that are solid, and
// only those; a plain group is never a target.
TEST(LayerTextureReference, ImageLayersAndGroupsRegisterTheirCursorTargeting) {
    const ProjectProperties properties {};
    fs::VFS                 vfs;
    auto parsed = ParseScene(vfs, R"([
        {"id":1,"name":"plain","image":"image.json"},
        {"id":2,"name":"ghost","image":"image.json","solid":false},
        {"id":3,"name":"blocker","image":"image.json","disablepropagation":true},
        {"id":4,"name":"group","origin":"0 0 0"}
      ])", {}, &properties);
    ASSERT_NE(parsed, nullptr);
    ASSERT_NE(parsed->runtime, nullptr);
    const auto target = [&](std::string_view name) {
        return parsed->runtime->NodeCursorTargetOf(name);
    };
    ASSERT_TRUE(target("plain").has_value());
    EXPECT_TRUE(target("plain")->hittable);
    EXPECT_TRUE(target("plain")->solid);
    EXPECT_FALSE(target("plain")->blocks);
    EXPECT_FALSE(target("ghost")->solid);
    EXPECT_TRUE(target("blocker")->blocks);
    ASSERT_TRUE(target("group").has_value());
    EXPECT_FALSE(target("group")->hittable);
}

TEST(LayerTextureReference, ExternalMaterialsKeepHiddenTransitiveProducers) {
    const ProjectProperties properties {};
    fs::VFS                 vfs;
    auto parsed = ParseScene(vfs, R"([
        {"id":159,"name":"source","image":"image.json","visible":false},
        {"id":161,"name":"consumer","image":"outer.json"},
        {"id":160,"name":"middle","image":"linked.json","visible":false}
      ])",
      {{ "/outer.json", R"({"width":64,"height":32,"material":"outer_mat.json"})" },
       { "/outer_mat.json",
         R"({"passes":[{"shader":"genericimage","textures":["_rt_imageLayerComposite_160_a"]}]})" },
       { "/linked_mat.json",
         R"({"passes":[{"shader":"genericimage","textures":["_rt_imageLayerComposite_159_a"]}]})" }},
      &properties);
    ASSERT_NE(parsed, nullptr);
    const auto graph = sceneToRenderGraph(*parsed);
    ASSERT_NE(graph, nullptr);
    const auto* source = FindPassByNode(*graph, "source");
    const auto* middle = FindPassByNode(*graph, "middle");
    ASSERT_NE(source, nullptr);
    ASSERT_NE(middle, nullptr);
    EXPECT_FALSE(source->desc().node->Visible());
    EXPECT_FALSE(middle->desc().node->Visible());
    EXPECT_EQ(source->desc().output, LayerCompositeTargetKey(159));
    EXPECT_EQ(middle->desc().output, LayerCompositeTargetKey(160));
    EXPECT_LT(PassIndexByNode(*graph, "source"), PassIndexByNode(*graph, "middle"));
    EXPECT_LT(PassIndexByNode(*graph, "middle"), PassIndexByNode(*graph, "consumer"));
}

TEST(LayerTextureReference, ProducerRunsBeforeConsumer) {
    fs::VFS vfs;
    auto    parsed = ParseScene(vfs, R"([
        {"id":160,"name":"consumer","image":"linked.json","visible":true,
         "dependencies":[159]},
        {"id":159,"name":"source","image":"image.json","visible":false}
      ])",
      {{ "/linked_mat.json",
         R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["_rt_imageLayerComposite_159_a"]}]})" }});
    ASSERT_NE(parsed, nullptr);
    parsed->renderTargets[std::string(SpecTex_Default)] = SceneRenderTarget {
        .width = 64, .height = 32, .allowReuse = true,
    };
    parsed->cameras["effect"] = std::make_shared<SceneCamera>(64, 32, 0.01f, 100.0f);
    parsed->activeCamera      = nullptr;

    const auto graph = sceneToRenderGraph(*parsed);
    ASSERT_NE(graph, nullptr);
    const auto* consumer = FindPassByNode(*graph, "consumer");
    ASSERT_NE(consumer, nullptr);
    ASSERT_FALSE(consumer->desc().textures.empty());
    EXPECT_EQ(consumer->desc().textures[0], GenLinkTex(159));

    const auto source_index   = PassIndexByNode(*graph, "source");
    const auto consumer_index = PassIndexByNode(*graph, "consumer");
    EXPECT_NE(source_index, static_cast<size_t>(-1));
    EXPECT_LT(source_index, consumer_index);

    const auto* link = FindLinkCopy(*graph, GenLinkTex(159));
    ASSERT_NE(link, nullptr);
    EXPECT_NE(link->desc().src, SpecTex_Default);
    EXPECT_EQ(link->desc().src, LayerCompositeTargetKey(159));
}

TEST(LayerTextureReference, EffectChainSourceLinksFromCompositeNotDefault) {
    fs::VFS vfs;
    auto    parsed = ParseScene(vfs, R"([
        {"id":159,"name":"source","image":"image.json","visible":false,
         "effects":[{"file":"effects/copy/effect.json","visible":true}]},
        {"id":160,"name":"consumer","image":"linked.json","visible":true,
         "dependencies":[159]}
      ])",
      {{ "/linked_mat.json",
         R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["_rt_imageLayerComposite_159_a"]}]})" },
        { "/effects/copy/effect.json",
          R"({"name":"copy","passes":[{"material":"materials/copy.json"}]})" },
        { "/materials/copy.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":[null]}]} )" }});
    ASSERT_NE(parsed, nullptr);
    EXPECT_TRUE(parsed->layer_texture_error.empty());
    EXPECT_TRUE(parsed->layer_texture_sources.contains(159));
    parsed->renderTargets[std::string(SpecTex_Default)] = SceneRenderTarget {
        .width = 64, .height = 32, .allowReuse = true,
    };
    if (parsed->cameras.find("effect") == parsed->cameras.end()) {
        parsed->cameras["effect"] = std::make_shared<SceneCamera>(64, 32, 0.01f, 100.0f);
    }
    parsed->activeCamera = nullptr;

    const auto graph = sceneToRenderGraph(*parsed);
    ASSERT_NE(graph, nullptr);
    const auto* consumer = FindPassByNode(*graph, "consumer");
    ASSERT_NE(consumer, nullptr);
    ASSERT_FALSE(consumer->desc().textures.empty());
    EXPECT_EQ(consumer->desc().textures[0], GenLinkTex(159));

    const auto* link = FindLinkCopy(*graph, GenLinkTex(159));
    ASSERT_NE(link, nullptr) << "the consumer never received a copy of the source composite";
    EXPECT_NE(link->desc().src, SpecTex_Default);
    EXPECT_EQ(link->desc().src, LayerCompositeTargetKey(159));

    const auto* composite = FindPassByOutput(*graph, LayerCompositeTargetKey(159));
    ASSERT_NE(composite, nullptr);
    EXPECT_NE(composite->desc().output, SpecTex_Default);
}

TEST(LayerTextureReference, AnnotationDefaultBindsItsSlotWithoutClaimingTheAuthorBoundIt) {
    // A sampler annotation's `default` exists so an unbound slot still samples
    // something sane. Its `combo` answers a different question -- did the
    // material bind a texture here -- and answering yes from the default turns
    // the shader's optional feature on permanently. `rounded_mask` then reads
    // its corner radius out of a white default instead of `u_Radius` and masks
    // every layer it touches into a circle.
    constexpr std::string_view kMaskFrag = R"(uniform sampler2D g_Texture0;
uniform sampler2D g_Texture1; // {"combo":"MASKED","default":"solid"}
varying vec2 v_TexCoord;
void main() {
#if MASKED
  gl_FragColor = texture(g_Texture1, v_TexCoord);
#else
  gl_FragColor = texture(g_Texture0, v_TexCoord);
#endif
}
)";
    fs::VFS vfs;
    auto    parsed = ParseScene(vfs, R"([
        {"id":1,"name":"masked","image":"masked.json"}
      ])",
      {{ "/masked.json", R"({"width":64,"height":32,"material":"masked_mat.json"})" },
       { "/masked_mat.json",
         R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"masked","textures":["solid"]}]})" },
       { "/shaders/masked.vert", std::string(kVert) },
       { "/shaders/masked.frag", std::string(kMaskFrag) }});
    ASSERT_NE(parsed, nullptr);

    SceneNode* node = nullptr;
    for (auto& child : parsed->sceneGraph->GetChildren()) {
        if (child->Name() == "masked") node = child.get();
    }
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    auto* material = node->Mesh()->MaterialForSlot(0);
    ASSERT_NE(material, nullptr);

    // With the combo off the shader takes its `#else` branch, so the authored
    // slot 0 is the one sampled and survives. Reporting the default as an
    // author binding compiles the other branch instead, which stops sampling
    // slot 0 and clears it -- that is what this asserts against.
    ASSERT_FALSE(material->textures.empty());
    EXPECT_EQ(material->textures[0], "solid");
    // The default slot is never read under that branch, so nothing holds a
    // texture it does not sample.
    EXPECT_TRUE(material->textures.size() < 2u || material->textures[1].empty());
    // The `#if MASKED` branch must not have been compiled in, so the pass
    // samples slot 0 the way the author wrote it.
    EXPECT_EQ(std::count(material->defines.begin(), material->defines.end(), "MASKED"), 0);
}

// Another layer samples `_rt_imageLayerComposite_<id>` as the source layer's
// card in that layer's own texture space. Drawn through the scene's camera, the
// composite followed where the layer sat, how far a camera layer zoomed and
// where the cursor pushed it, so a planet assembled from hidden layers slid out
// from under its own mask.
TEST(LayerTextureReference, AReferencedLayerIsItsCardWhereverTheSceneShowsIt) {
    fs::VFS vfs;
    MountFiles(vfs,
               { { "/linked_mat.json",
                   R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["_rt_imageLayerComposite_159_a"]}]})" } });
    audio::SoundManager sound;
    WPSceneParser       parser;
    auto                parsed = parser.Parse("layer-composite-camera", ParallaxSceneJson(R"([
        {"id":9,"name":"shot","camera":"default","origin":[8,4,500],
         "angles":[0,0,0],"fov":50,"zoom":2},
        {"id":159,"name":"source","image":"image.json","origin":[20,10,0],
         "scale":[0.5,0.5,1],"parallaxDepth":"1 1","visible":false},
        {"id":160,"name":"consumer","image":"linked.json","visible":true,
         "dependencies":[159]}
      ])"),
                                     vfs,
                                     sound);
    ASSERT_NE(parsed, nullptr);
    AddScreenTarget(*parsed);
    // The cursor in a corner, long enough for the smoothing to arrive: a layer
    // at depth 1 on screen is pushed by parallax now.
    parsed->shaderValueUpdater->MouseInput(1.0, 0.0);
    parsed->frameTime = 1.0;
    parsed->shaderValueUpdater->FrameBegin();

    const auto graph = sceneToRenderGraph(*parsed);
    ASSERT_NE(graph, nullptr);
    const auto* composite = FindPassByOutput(*graph, LayerCompositeTargetKey(159));
    ASSERT_NE(composite, nullptr);
    ExpectCardFillsItsTarget(*parsed, *composite, { 32.0, 16.0 });
    // Nor does the cursor: the composite is not kept out of reuse for parallax.
    const auto varying = parsed->shaderValueUpdater->FrameVaryingUniforms(
        composite->desc().node, composite->desc().material_slot, composite->desc().camera_override);
    EXPECT_EQ(varying & (frame_varying_uniform::kPointer | frame_varying_uniform::kParallax), 0u);
}

// A layer's composite is copied into its link texture while the graph is
// built, so its size is known only then, and the value updater reports it every
// frame. A zero folded into the material at parse time in its place was divided
// by: in the consumer's card padding, which made every texture coordinate of
// the card NaN, and by `uv * size.z / size.x` wherever a shader maps
// coordinates through it.
TEST(LayerTextureReference, AReferencedCompositeIsSampledAtItsRealSize) {
    fs::VFS vfs;
    auto    parsed = ParseScene(vfs, R"([
        {"id":159,"name":"source","image":"image.json","visible":false},
        {"id":160,"name":"consumer","image":"linked.json","visible":true,
         "dependencies":[159]}
      ])",
      {{ "/linked_mat.json",
         R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["_rt_imageLayerComposite_159_a"]}]})" }});
    ASSERT_NE(parsed, nullptr);
    AddScreenTarget(*parsed);
    const auto graph = sceneToRenderGraph(*parsed);
    ASSERT_NE(graph, nullptr);
    const auto* consumer = FindPassByNode(*graph, "consumer");
    ASSERT_NE(consumer, nullptr);
    ASSERT_NE(consumer->desc().node->Mesh(), nullptr);
    const auto* material =
        consumer->desc().node->Mesh()->MaterialForSlot(consumer->desc().material_slot);
    ASSERT_NE(material, nullptr);

    // The consumer's card maps the whole linked image.
    const auto& vertices = consumer->desc().node->Mesh()->GetVertexArray(0);
    const auto  offsets  = vertices.GetAttrOffsetMap();
    const auto  texcoord = offsets.find(std::string(WE_IN_TEXCOORD));
    ASSERT_NE(texcoord, offsets.end());
    for (std::size_t vertex = 0; vertex < vertices.VertexCount(); ++vertex) {
        const float* uv = vertices.Data() + vertex * vertices.OneSize() +
                          texcoord->second.offset / sizeof(float);
        for (int axis = 0; axis < 2; ++axis) {
            EXPECT_TRUE(uv[axis] == 0.0f || uv[axis] == 1.0f)
                << "vertex " << vertex << " axis " << axis << " maps " << uv[axis];
        }
    }

    // A backend declares the link target from the composite as it prepares the
    // copy (CopyPass, ScenePassDescription); this harness prepares none, so it
    // declares it the same way.
    parsed->renderTargets[GenLinkTex(159)] =
        parsed->renderTargets.at(LayerCompositeTargetKey(159));
    const auto live = PassUniforms(*parsed, *consumer, { "g_Texture0Resolution" });
    // Metal writes the material's constants and then the value updater's live
    // values; the other order is checked too, so the shader reads the composite's
    // real size whichever lands last.
    for (const bool constants_last : { false, true }) {
        SCOPED_TRACE(constants_last ? "constants uploaded last"
                                    : "live values uploaded last, as Metal does");
        std::map<std::string, ShaderValue, std::less<>> uploaded;
        const auto upload = [&uploaded](const auto& values) {
            for (const auto& [name, value] : values) uploaded[std::string(name)] = value;
        };
        if (constants_last) {
            upload(live);
            upload(material->customShader.constValues);
        } else {
            upload(material->customShader.constValues);
            upload(live);
        }
        const auto size = uploaded.find("g_Texture0Resolution");
        ASSERT_NE(size, uploaded.end()) << "nothing gives the shader the linked composite's size";
        ASSERT_EQ(size->second.size(), 4u);
        EXPECT_FLOAT_EQ(size->second[0], 64.0f);
        EXPECT_FLOAT_EQ(size->second[1], 32.0f);
    }
}

// A compose layer draws its children into its own target through a camera
// that spans the layer's card, each child where it sits inside the layer. That
// is not a layer-local camera: placing the children at identity would pile them
// all onto the centre of the target.
TEST(LayerTextureReference, ComposeChildrenKeepTheirPlaceInsideTheLayer) {
    fs::VFS vfs;
    auto    parsed = ParseScene(vfs, R"([
        {"id":1,"name":"container","image":"models/util/composelayer.json",
         "size":[64,32],"origin":[32,16,0],"copybackground":false},
        {"id":2,"name":"child","parent":1,"image":"small.json","origin":[10,5,0]}
      ])",
      {{ "/models/util/composelayer.json",
         R"({"passthrough":true,"material":"materials/util/composelayer.json"})" },
       { "/materials/util/composelayer.json",
         R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["_rt_FullFrameBuffer"]}]})" },
       { "/materials/util/effectpassthrough.json",
         R"({"passes":[{"blending":"normal","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage"}]})" },
       { "/small.json", R"({"width":16,"height":8,"material":"mat.json"})" }});
    ASSERT_NE(parsed, nullptr);
    AddScreenTarget(*parsed);
    const auto graph = sceneToRenderGraph(*parsed);
    ASSERT_NE(graph, nullptr);
    const auto* child = FindPassByNode(*graph, "child");
    ASSERT_NE(child, nullptr);

    const auto corner = CardCornerNdc(*parsed, *child, { 8.0, 4.0 });
    EXPECT_NEAR(corner.x(), (10.0 + 8.0) / 32.0, 1e-4);
    EXPECT_NEAR(corner.y(), (5.0 + 4.0) / 16.0, 1e-4);
}

// Wallpaper Engine composes a layer from the flags and the shader of its model,
// not from the model's name, so the depth-testing variant of the composition
// layer composes its children the same way.
TEST(LayerTextureReference, TheDepthTestedComposeModelComposesLikeTheOthers) {
    fs::VFS vfs;
    auto    parsed = ParseScene(vfs, R"([
        {"id":1,"name":"container","image":"models/util/composelayer_depthtest.json",
         "size":[64,32],"origin":[32,16,0],"copybackground":false},
        {"id":2,"name":"child","parent":1,"image":"small.json","origin":[10,5,0]}
      ])",
      {{ "/models/util/composelayer_depthtest.json",
         R"({"passthrough":true,"material":"materials/util/composelayer.json"})" },
       { "/materials/util/composelayer.json",
         R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"enabled","depthwrite":"disabled","shader":"genericimage","textures":["_rt_FullFrameBuffer"]}]})" },
       { "/materials/util/effectpassthrough.json",
         R"({"passes":[{"blending":"normal","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage"}]})" },
       { "/small.json", R"({"width":16,"height":8,"material":"mat.json"})" }});
    ASSERT_NE(parsed, nullptr);
    AddScreenTarget(*parsed);
    const auto graph = sceneToRenderGraph(*parsed);
    ASSERT_NE(graph, nullptr);
    const auto* child = FindPassByNode(*graph, "child");
    ASSERT_NE(child, nullptr);

    const auto corner = CardCornerNdc(*parsed, *child, { 8.0, 4.0 });
    EXPECT_NEAR(corner.x(), (10.0 + 8.0) / 32.0, 1e-4);
    EXPECT_NEAR(corner.y(), (5.0 + 4.0) / 16.0, 1e-4);
}

// A project layer is sized by the scene's canvas, not by the size the scene file
// saved for it; the layer's position stays the scene file's.
TEST(LayerTextureReference, AProjectLayerTakesTheCanvasSizeAndKeepsItsOrigin) {
    const ProjectProperties properties {};
    fs::VFS                 vfs;
    auto parsed = ParseScene(vfs, R"([
        {"id":1,"name":"project","image":"models/util/projectlayer.json",
         "size":[10,10],"origin":[40,12,0]},
        {"id":2,"name":"plain","image":"models/util/solid.json","size":[10,10],"origin":[40,12,0]}
      ])",
      {{ "/models/util/projectlayer.json",
         R"({"passthrough":true,"autosize":true,"projectlayer":true,"material":"materials/util/composelayer.json"})" },
       { "/models/util/solid.json",
         R"({"autosize":true,"material":"materials/util/composelayer.json"})" },
       { "/materials/util/composelayer.json",
         R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["_rt_FullFrameBuffer"]}]})" }},
      &properties);
    ASSERT_NE(parsed, nullptr);
    ASSERT_NE(parsed->runtime, nullptr);
    // The scene's canvas is 64 by 32.
    EXPECT_TRUE(parsed->runtime->NodeSize("project").isApprox(linalg::Vector2f(64.0f, 32.0f)));
    EXPECT_TRUE(parsed->runtime->NodeTranslate("project").isApprox(linalg::Vector3f(40.0f, 12.0f, 0.0f)));
    // `autosize` alone sizes from the texture, which the scene file's size already is.
    EXPECT_TRUE(parsed->runtime->NodeSize("plain").isApprox(linalg::Vector2f(10.0f, 10.0f)));
}

// What a `shape` object needs of an effect: its shader only compiles with the
// DIRECTDRAW combo on, which the scene file never sets, and a uniform tells two
// effects apart.
std::map<std::string, std::string> ShapeEffectFiles() {
    const std::string vert = std::string(kVert);
    const std::string frag = R"(#if ! DIRECTDRAW
#error the shape did not force DIRECTDRAW on
#endif
uniform vec3 g_Tint; // {"material":"tint","default":"1 1 1"}
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = vec4(g_Tint * v_TexCoord.x, 1.0);
}
)";
    std::map<std::string, std::string> files {
        { "/materials/effects/shaft.json",
          R"({"passes":[{"shader":"effects/shaft","blending":"normal","cullmode":"nocull",)"
          R"("depthtest":"disabled","depthwrite":"disabled","textures":[null]}]})" },
        { "/shaders/effects/shaft.vert", vert },
        { "/shaders/effects/shaft.frag", frag },
    };
    for (const std::string name : { "first", "second" }) {
        files["/effects/" + name + "/effect.json"] =
            R"({"name":")" + name +
            R"(","passes":[{"material":"materials/effects/shaft.json"}]})";
    }
    return files;
}

// A `shape` object is a quad as tall as the canvas on both axes, drawn through its
// last effect straight onto the scene, additively, with the effect's DIRECTDRAW
// combo forced on. With `point0` to `point3` on the first effect's first pass the
// quad is the one those four corners make.
TEST(LayerTextureReference, AShapeDrawsItsLastEffectAdditivelyOntoTheScene) {
    const ProjectProperties properties {};
    fs::VFS                 vfs;
    auto parsed = ParseScene(vfs, R"([
        {"id":1,"name":"shaft","shape":"quad","origin":[32,16,0],"visible":true,
         "effects":[
           {"file":"effects/first/effect.json","id":10,"visible":true,
            "passes":[{"constantshadervalues":{"tint":"1 0 0","point0":"0.25 0.25",
              "point1":"0.75 0.25","point2":"0.9 0.75","point3":"0.1 0.75"}}]},
           {"file":"effects/second/effect.json","id":11,"visible":true,
            "passes":[{"constantshadervalues":{"tint":"0 1 0"}}]}]},
        {"id":2,"name":"whole","shape":"quad","origin":[32,16,0],"visible":true,
         "effects":[{"file":"effects/first/effect.json","id":12,"visible":true}]},
        {"id":3,"name":"hidden","shape":"quad","visible":false,
         "effects":[{"file":"effects/first/effect.json","id":13,"visible":true}]}
      ])", ShapeEffectFiles(), &properties);
    ASSERT_NE(parsed, nullptr);

    SceneNode* shaft = nullptr;
    SceneNode* whole = nullptr;
    SceneNode* hidden = nullptr;
    for (auto& child : parsed->sceneGraph->GetChildren()) {
        if (child->Name() == "shaft") shaft = child.get();
        if (child->Name() == "whole") whole = child.get();
        if (child->Name() == "hidden") hidden = child.get();
    }
    ASSERT_NE(shaft, nullptr);
    ASSERT_NE(whole, nullptr);
    ASSERT_NE(hidden, nullptr);
    // An object that is not shown is not drawn at all.
    EXPECT_EQ(hidden->Mesh(), nullptr);

    // The quad of the four corners, as `(p.x, 1 - p.y)` of a 32 unit square about
    // the layer, with the corner as its texture coordinates; it is the last
    // effect's material that draws it.
    ASSERT_NE(shaft->Mesh(), nullptr);
    const auto& vertices = shaft->Mesh()->GetVertexArray(0);
    ASSERT_EQ(vertices.VertexCount(), 4u);
    const auto offsets  = vertices.GetAttrOffsetMap();
    const auto position = offsets.at(std::string(WE_IN_POSITION)).offset / sizeof(float);
    const auto texcoord = offsets.at(std::string(WE_IN_TEXCOORD)).offset / sizeof(float);
    std::vector<std::array<float, 4>> got;
    for (std::size_t index = 0; index < vertices.VertexCount(); ++index) {
        const float* v = vertices.Data() + index * vertices.OneSize();
        got.push_back({ v[position], v[position + 1], v[texcoord], v[texcoord + 1] });
    }
    std::sort(got.begin(), got.end());
    std::vector<std::array<float, 4>> expected;
    for (const auto& corner : std::vector<std::array<float, 2>> {
             { 0.25f, 0.25f }, { 0.75f, 0.25f }, { 0.9f, 0.75f }, { 0.1f, 0.75f } }) {
        expected.push_back({ 32.0f * corner[0] - 16.0f, 32.0f * (1.0f - corner[1]) - 16.0f,
                             corner[0], corner[1] });
    }
    std::sort(expected.begin(), expected.end());
    ASSERT_EQ(got.size(), expected.size());
    for (std::size_t index = 0; index < got.size(); ++index) {
        for (std::size_t lane = 0; lane < 4; ++lane) {
            EXPECT_NEAR(got[index][lane], expected[index][lane], 1e-4f) << index << "/" << lane;
        }
    }
    const auto* material = shaft->Mesh()->Material();
    ASSERT_NE(material, nullptr);
    EXPECT_EQ(material->blenmode, BlendMode::Additive);
    ASSERT_TRUE(material->customShader.constValues.contains("g_Tint"));
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("g_Tint")[0], 0.0f)
        << "the first effect was drawn instead of the last";
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("g_Tint")[1], 1.0f);

    // Without the four corners it is the whole square, as tall as the canvas.
    ASSERT_NE(whole->Mesh(), nullptr);
    const auto [lower, upper] = CardCorners(*whole->Mesh());
    EXPECT_TRUE(lower.isApprox(linalg::Vector2d(-16.0, -16.0)));
    EXPECT_TRUE(upper.isApprox(linalg::Vector2d(16.0, 16.0)));

    // And it reaches the scene's own target as a pass of its own.
    AddScreenTarget(*parsed);
    const auto graph = sceneToRenderGraph(*parsed);
    ASSERT_NE(graph, nullptr);
    const auto* pass = FindPassByNode(*graph, "shaft");
    ASSERT_NE(pass, nullptr);
    EXPECT_EQ(pass->desc().output, std::string(SpecTex_Default));
}

// A compose layer that only copies the background behind it adds nothing on
// screen and used to be skipped outright. A mask drawn after other layers can
// still sample it to paint that background back -- a toggle's clouds clipped to
// its pill -- and then found no texture at all: the layer has to be drawn into
// its composite, and only there, since its card covers its whole target.
TEST(LayerTextureReference, ABareComposeLayerAnotherSamplesIsDrawnOnlyIntoItsComposite) {
    const auto compose_files = [] {
        return std::map<std::string, std::string> {
            { "/models/util/composelayer.json",
              R"({"passthrough":true,"material":"materials/util/composelayer.json"})" },
            { "/materials/util/composelayer.json",
              R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["_rt_FullFrameBuffer"]}]})" },
            { "/linked_mat.json",
              R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["_rt_imageLayerComposite_89_a"]}]})" },
        };
    };
    fs::VFS vfs;
    auto    parsed = ParseScene(vfs, R"([
        {"id":1,"name":"backdrop","image":"image.json"},
        {"id":89,"name":"behind","image":"models/util/composelayer.json",
         "size":[64,32],"origin":[32,16,0]},
        {"id":2,"name":"clouds","image":"image.json"},
        {"id":22,"name":"mask","image":"linked.json","dependencies":[89]}
      ])", compose_files());
    ASSERT_NE(parsed, nullptr);
    AddScreenTarget(*parsed);
    const auto graph = sceneToRenderGraph(*parsed);
    ASSERT_NE(graph, nullptr);

    std::vector<std::string> behind_outputs;
    for (const auto id : graph->topologicalOrder()) {
        auto* pass = dynamic_cast<const rg::DrawPass*>(graph->getPass(id));
        if (pass != nullptr && pass->desc().node != nullptr &&
            pass->desc().node->Name() == "behind") {
            behind_outputs.push_back(pass->desc().output);
        }
    }
    EXPECT_EQ(behind_outputs, std::vector<std::string> { LayerCompositeTargetKey(89) });

    const auto* mask = FindPassByNode(*graph, "mask");
    ASSERT_NE(mask, nullptr);
    ASSERT_FALSE(mask->desc().textures.empty());
    EXPECT_EQ(mask->desc().textures[0], GenLinkTex(89));
    const auto* link = FindLinkCopy(*graph, GenLinkTex(89));
    ASSERT_NE(link, nullptr) << "the mask was given nothing to sample";
    EXPECT_EQ(link->desc().src, LayerCompositeTargetKey(89));
    EXPECT_LT(PassIndexByNode(*graph, "behind"), PassIndexByNode(*graph, "clouds"));

    // Nobody samples it: it stays out of the graph, as before.
    fs::VFS unused_vfs;
    auto    unused = ParseScene(unused_vfs, R"([
        {"id":1,"name":"backdrop","image":"image.json"},
        {"id":89,"name":"behind","image":"models/util/composelayer.json",
         "size":[64,32],"origin":[32,16,0]}
      ])", compose_files());
    ASSERT_NE(unused, nullptr);
    AddScreenTarget(*unused);
    const auto unused_graph = sceneToRenderGraph(*unused);
    ASSERT_NE(unused_graph, nullptr);
    EXPECT_EQ(FindPassByNode(*unused_graph, "behind"), nullptr);
}

// A compose layer's effect may sample one of the layer's own children -- a
// solid card a script tints, kept as a palette -- while that child is also
// part of what the compose layer shows. Inside a compose layer the child was
// drawn only into the compose target, never into a composite of its own, so
// the effect found nothing to sample and was skipped.
TEST(LayerTextureReference, AComposeLayersEffectCanSampleItsOwnChild) {
    constexpr std::string_view kTintFrag = R"(uniform sampler2D g_Texture0;
uniform sampler2D g_Texture1;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord) * texture(g_Texture1, v_TexCoord);
}
)";
    // A child hidden for good is only its composite; one a script hides may
    // show again without a new graph, so it keeps its place in the picture.
    const std::array<std::pair<std::string_view, bool>, 3> visibilities { {
        { "true", true },
        { "false", false },
        { R"({"script":"export function update(value) { return value; }","value":false})", true },
    } };
    for (const auto& [visible, in_picture] : visibilities) {
        SCOPED_TRACE(visible);
        const ProjectProperties properties {};
        fs::VFS                 vfs;
        auto                    parsed = ParseScene(vfs, std::string(R"([
            {"id":1,"name":"container","image":"models/util/composelayer.json",
             "size":[64,32],"origin":[32,16,0],"dependencies":[2],
             "effects":[{"file":"effects/tint/effect.json","visible":true,
                         "passes":[{"textures":[null,"_rt_imageLayerComposite_2_a"]}]}]},
            {"id":2,"name":"palette","parent":1,"image":"small.json","origin":[10,5,0],
             "visible":)") + std::string(visible) + "}]",
          {{ "/models/util/composelayer.json",
             R"({"passthrough":true,"material":"materials/util/composelayer.json"})" },
           { "/materials/util/composelayer.json",
             R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["_rt_FullFrameBuffer"]}]})" },
           { "/small.json", R"({"width":16,"height":8,"material":"mat.json"})" },
           { "/effects/tint/effect.json",
             R"({"name":"tint","passes":[{"material":"materials/tint.json"}]})" },
           { "/materials/tint.json",
             R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"tint","textures":[null,null]}]})" },
           { "/shaders/tint.vert", std::string(kVert) },
           { "/shaders/tint.frag", std::string(kTintFrag) }},
          &properties);
        ASSERT_NE(parsed, nullptr);
        EXPECT_TRUE(parsed->layer_texture_error.empty()) << parsed->layer_texture_error;
        AddScreenTarget(*parsed);
        SceneNode* container = nullptr;
        for (auto& child : parsed->sceneGraph->GetChildren()) {
            if (child->Name() == "container") container = child.get();
        }
        ASSERT_NE(container, nullptr);
        const auto camera = parsed->cameras.find(container->Camera());
        ASSERT_NE(camera, parsed->cameras.end());
        ASSERT_TRUE(camera->second->HasImgEffect());
        const auto compose_target =
            parsed->ResolveRenderTargetName(camera->second->GetImgEffect()->FirstTarget());

        const auto graph = sceneToRenderGraph(*parsed);
        ASSERT_NE(graph, nullptr);
        const rg::DrawPass* tint = nullptr;
        for (const auto id : graph->topologicalOrder()) {
            auto* pass = dynamic_cast<const rg::DrawPass*>(graph->getPass(id));
            if (pass == nullptr) continue;
            const auto& textures = pass->desc().textures;
            if (std::find(textures.begin(), textures.end(), GenLinkTex(2)) != textures.end())
                tint = pass;
        }
        ASSERT_NE(tint, nullptr) << "the effect was given nothing to sample";
        const auto* link = FindLinkCopy(*graph, GenLinkTex(2));
        ASSERT_NE(link, nullptr);
        EXPECT_EQ(link->desc().src, LayerCompositeTargetKey(2));

        // The palette is its own card in its composite, and still part of the
        // compose layer's picture wherever it shows.
        std::vector<std::string> outputs;
        const rg::DrawPass* composite = nullptr;
        for (const auto id : graph->topologicalOrder()) {
            auto* pass = dynamic_cast<const rg::DrawPass*>(graph->getPass(id));
            if (pass == nullptr || pass->desc().node == nullptr ||
                pass->desc().node->Name() != "palette")
                continue;
            outputs.push_back(pass->desc().output);
            if (pass->desc().output == LayerCompositeTargetKey(2)) composite = pass;
        }
        auto expected = std::vector<std::string> { LayerCompositeTargetKey(2) };
        if (in_picture) expected.push_back(compose_target);
        EXPECT_EQ(outputs, expected);
        ASSERT_NE(composite, nullptr);
        ExpectCardFillsItsTarget(*parsed, *composite, { 8.0, 4.0 });
        EXPECT_TRUE(composite->desc().node->MustProduce());
    }
}

// A text layer is sampled like an image: a hidden title another layer scrolls
// across a card of its own, a clock whose effect outlines what it samples. Only
// an image layer was given a composite, though. A sampled text layer was drawn
// through the scene camera into a screen-sized fallback, so the consumer found
// the text wherever it sits on screen, and, hidden, it was never drawn at all.
// Its card is laid out again whenever the text changes, so its composite moves
// and resizes with it, one texel per unit as an image's is: a consumer may place
// the image by its size. Texels are the card's width and height with the fraction
// cut off, as Wallpaper Engine builds a text card's buffers, as the scene loads
// and again after every relayout. A spacing of 0.2 between glyphs gives both texts
// below a fractional card with a fraction of .6, where cutting and rounding differ.
TEST(LayerTextureReference, ASampledTextLayerIsItsCardInItsOwnComposite) {
    // With an effect the layer draws through the chain's buffers, and what is
    // sampled is the chain's final card. Declared as a dependency the
    // reference is known before the text is parsed; named only in a material
    // file it is found while the consumer is parsed.
    for (const bool fractional : { false, true }) {
        bool a_fraction_rounds_up = false;
        for (const bool with_effect : { false, true }) {
            for (const bool declared : { true, false }) {
                SCOPED_TRACE(std::string(fractional ? "fractional card, " : "whole card, ") +
                             (with_effect ? "with an effect" : "plain") +
                             (declared ? ", declared" : ", found in a material"));
                auto files = CopyEffectFiles();
                files["/linked_mat.json"] =
                    R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["_rt_imageLayerComposite_416_a"]}]})";
                // Left-aligned, the card hangs to the right of the layer's origin and is
                // not centred on it.
                const std::string objects =
                    std::string(R"([
                    {"id":680,"name":"marquee","image":"linked.json")") +
                    (declared ? R"(,"dependencies":[416])" : "") + R"(},
                    {"id":416,"name":"title","text":"Wind","font":"Arial","pointsize":20,
                     "padding":0,"horizontalalign":"left",
                     "origin":[50,20,0],"visible":false)" +
                    (fractional ? R"(,"spacing":"0.2 0")" : "") +
                    (with_effect ? R"(,"effects":[{"file":"effects/copy/effect.json","visible":true}])"
                                 : "") +
                    "}]";
                const ProjectProperties properties {};
                fs::VFS                 vfs;
                auto parsed = ParseScene(vfs, objects, files, &properties);
                ASSERT_NE(parsed, nullptr);
                ASSERT_NE(parsed->runtime, nullptr);
                EXPECT_TRUE(parsed->layer_texture_error.empty()) << parsed->layer_texture_error;
                AddScreenTarget(*parsed);
                auto& runtime = *parsed->runtime;

                // The pass that draws the title into its composite, and the card it
                // draws there.
                struct Composite {
                    const rg::DrawPass* pass { nullptr };
                    linalg::Vector2d                 lower, upper;
                };
                const auto find_composite = [&](const rg::RenderGraph& graph) {
                    Composite found;
                    found.pass = FindPassByOutput(graph, LayerCompositeTargetKey(416));
                    if (found.pass == nullptr || found.pass->desc().node->Mesh() == nullptr)
                        return found;
                    std::tie(found.lower, found.upper) =
                        CardCorners(*found.pass->desc().node->Mesh());
                    return found;
                };
                const auto expect_composite_is_the_card = [&](const Composite& composite) {
                    ASSERT_NE(composite.pass, nullptr) << "the title was never drawn into a composite";
                    auto* owner = composite.pass->desc().visibility_node != nullptr
                                            ? composite.pass->desc().visibility_node
                                            : composite.pass->desc().node;
                    EXPECT_EQ(owner->Name(), "title");
                    EXPECT_TRUE(owner->MustProduce()) << "hidden, the title would never be drawn";
                    // The card the title shows on screen, whichever mesh draws it. With an
                    // effect the composite is the card the chain ends in, cut to the
                    // buffers it is drawn into: short of the text's own by half the
                    // fraction they cut off on each side.
                    ASSERT_NE(owner->Mesh(), nullptr);
                    const auto [card_lower, card_upper] = CardCorners(*owner->Mesh());
                    const double slack = fractional && with_effect ? 0.5 : 1e-3;
                    EXPECT_NEAR(composite.lower.x(), card_lower.x(), slack);
                    EXPECT_NEAR(composite.lower.y(), card_lower.y(), slack);
                    EXPECT_NEAR(composite.upper.x(), card_upper.x(), slack);
                    EXPECT_NEAR(composite.upper.y(), card_upper.y(), slack);
                    ExpectCardFillsItsTarget(*parsed, *composite.pass, composite.lower, composite.upper);
                    const auto* target = parsed->FindRenderTarget(LayerCompositeTargetKey(416));
                    ASSERT_NE(target, nullptr);
                    // The card's size in texels: its width and height with the fraction
                    // cut off.
                    const auto card = runtime.NodeSize("title");
                    EXPECT_EQ(target->width, std::max(4, static_cast<int32_t>(card.x())))
                        << card.x();
                    EXPECT_EQ(target->height, std::max(4, static_cast<int32_t>(card.y())))
                        << card.y();
                    a_fraction_rounds_up =
                        a_fraction_rounds_up || card.x() - std::floor(card.x()) >= 0.5f;
                };

                auto graph = sceneToRenderGraph(*parsed);
                ASSERT_NE(graph, nullptr);
                const auto* marquee = FindPassByNode(*graph, "marquee");
                ASSERT_NE(marquee, nullptr);
                ASSERT_FALSE(marquee->desc().textures.empty());
                EXPECT_EQ(marquee->desc().textures[0], GenLinkTex(416));
                const auto* link = FindLinkCopy(*graph, GenLinkTex(416));
                ASSERT_NE(link, nullptr) << "the marquee was given nothing to sample";
                EXPECT_EQ(link->desc().src, LayerCompositeTargetKey(416));

                const auto before = find_composite(*graph);
                expect_composite_is_the_card(before);
                ASSERT_NE(before.pass, nullptr);
                ASSERT_GT(std::abs((before.lower.x() + before.upper.x()) * 0.5), 1.0)
                    << "the fixture's card must sit off the layer's origin";

                // A longer title widens the card while the layer stays hidden.
                ASSERT_TRUE(runtime.SetNodeText("title", "Wind over the river"));
                ASSERT_TRUE(PumpTextLayout(runtime, "title"))
                    << "a hidden text layer another samples was never laid out again";
                EXPECT_FALSE(runtime.ConsumeSceneGraphMutationFlag())
                    << "a wider card rebuilt a graph that only needs its target resized";
                EXPECT_TRUE(runtime.ConsumeRenderTargetResizeFlag())
                    << "the composite outgrew its target and nothing asked for it to be resized";
                graph = sceneToRenderGraph(*parsed);
                ASSERT_NE(graph, nullptr);
                const auto after = find_composite(*graph);
                expect_composite_is_the_card(after);
                ASSERT_NE(after.pass, nullptr);
                EXPECT_GT(after.upper.x() - after.lower.x(), before.upper.x() - before.lower.x());
            }
        }
        if (fractional) {
            EXPECT_TRUE(a_fraction_rounds_up)
                << "no card had a fraction of .5 or more, so rounding and cutting agree";
        }
    }
}

namespace
{

/// Layer 7, an image and a text layer, with two effects that name the layer's
/// own composite: the first, `first`, where it would take `previous`, the
/// second, `second`, next to it. Both must read the image the chain is working
/// on, and only another layer may make the layer produce its composite. Older
/// editors also list the layer in its own `dependencies`, once for each name
/// its effects bind; that does not make it a sampled layer either.
void ExpectOwnEffectsReadTheChainInput(std::string_view first, std::string_view second) {
    constexpr std::string_view kBlendFrag = R"(uniform sampler2D g_Texture0;
uniform sampler2D g_Texture1;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord) * texture(g_Texture1, v_TexCoord);
}
)";
    const std::array<std::pair<std::string_view, std::string_view>, 2> layers { {
        { "image", R"("image":"image.json")" },
        { "text", R"("text":"Wind","font":"Arial","pointsize":20,"origin":[32,16,0])" },
    } };
    // { sampled elsewhere, listed in its own dependencies }
    const std::array<std::pair<bool, bool>, 4> variants { {
        { false, false }, { false, true }, { true, false }, { true, true },
    } };
    for (const auto& [kind, layer] : layers) {
        for (const auto& [sampled_elsewhere, self_dependency] : variants) {
            SCOPED_TRACE(std::string(kind) + (sampled_elsewhere ? ", sampled elsewhere" : "") +
                         (self_dependency ? ", in its own dependencies" : ""));
            auto files = CopyEffectFiles();
            files["/effects/blend/effect.json"] =
                R"({"name":"blend","passes":[{"material":"materials/blend.json"}]})";
            files["/materials/blend.json"] =
                R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"blend","textures":[null,null]}]})";
            files["/shaders/blend.vert"] = std::string(kVert);
            files["/shaders/blend.frag"] = std::string(kBlendFrag);
            files["/linked_mat.json"] =
                R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["_rt_imageLayerComposite_7_a"]}]})";
            const std::string objects =
                std::string(R"([{"id":7,"name":"outlined",)") + std::string(layer) +
                (self_dependency ? R"(,"dependencies":[7,7])" : "") + R"(,
                "effects":[
                  {"file":"effects/copy/effect.json","visible":true,
                   "passes":[{"textures":[")" + std::string(first) + R"("]}]},
                  {"file":"effects/blend/effect.json","visible":true,
                   "passes":[{"textures":[null,")" + std::string(second) + R"("]}]}]})" +
                (sampled_elsewhere
                     ? R"(,{"id":8,"name":"mirror","image":"linked.json","dependencies":[7]})"
                     : "") +
                "]";
            const ProjectProperties properties {};
            fs::VFS                 vfs;
            auto parsed = ParseScene(vfs, objects, files, &properties);
            ASSERT_NE(parsed, nullptr);
            EXPECT_TRUE(parsed->layer_texture_error.empty()) << parsed->layer_texture_error;
            // Its own effects do not make a layer something another samples.
            EXPECT_EQ(parsed->layer_texture_sources.contains(7), sampled_elsewhere);
            AddScreenTarget(*parsed);
            SceneNode* outlined = nullptr;
            for (auto& child : parsed->sceneGraph->GetChildren()) {
                if (child->Name() == "outlined") outlined = child.get();
            }
            ASSERT_NE(outlined, nullptr);
            const auto camera = parsed->cameras.find(outlined->Camera());
            ASSERT_NE(camera, parsed->cameras.end());
            ASSERT_TRUE(camera->second->HasImgEffect());
            auto& chain = *camera->second->GetImgEffect();
            ASSERT_EQ(chain.EffectCount(), 2u);

            const auto graph = sceneToRenderGraph(*parsed);
            ASSERT_NE(graph, nullptr);
            const auto passes_of = [&](const SceneNode* node) {
                std::vector<const rg::DrawPass*> found;
                for (const auto id : graph->topologicalOrder()) {
                    auto* pass = dynamic_cast<const rg::DrawPass*>(graph->getPass(id));
                    if (pass != nullptr && pass->desc().node == node) found.push_back(pass);
                }
                return found;
            };
            const auto own = passes_of(outlined);
            const auto first  = passes_of(chain.GetEffect(0)->nodes.front().sceneNode.get());
            const auto second = passes_of(chain.GetEffect(1)->nodes.front().sceneNode.get());
            ASSERT_EQ(own.size(), 1u);
            ASSERT_EQ(first.size(), 1u);
            ASSERT_FALSE(second.empty());

            // The first effect reads the layer as drawn, before any effect...
            ASSERT_FALSE(first[0]->desc().textures.empty());
            EXPECT_EQ(first[0]->desc().textures[0], own[0]->desc().output);
            // ...and the second what the first made of it, in both slots.
            for (const auto* pass : second) {
                ASSERT_GE(pass->desc().textures.size(), 2u);
                EXPECT_EQ(pass->desc().textures[0], first[0]->desc().output);
                EXPECT_EQ(pass->desc().textures[1], pass->desc().textures[0]);
            }

            const auto* link = FindLinkCopy(*graph, GenLinkTex(7));
            if (! sampled_elsewhere) {
                EXPECT_EQ(link, nullptr);
                EXPECT_EQ(FindPassByOutput(*graph, LayerCompositeTargetKey(7)), nullptr)
                    << "the layer was drawn into a composite nobody samples";
                continue;
            }
            const auto* mirror = FindPassByNode(*graph, "mirror");
            ASSERT_NE(mirror, nullptr);
            ASSERT_FALSE(mirror->desc().textures.empty());
            EXPECT_EQ(mirror->desc().textures[0], GenLinkTex(7));
            ASSERT_NE(link, nullptr) << "the mirror was given nothing to sample";
            EXPECT_EQ(link->desc().src, LayerCompositeTargetKey(7));
            EXPECT_NE(FindPassByOutput(*graph, LayerCompositeTargetKey(7)), nullptr);
        }
    }
}

} // namespace

// A layer's own effect may bind the layer's `_a` composite where it would
// otherwise take `previous` -- an outline that names the text it outlines.
// Inside the layer's chain that is the chain's buffer A, the image the effect
// works on; the composite is what the chain ends in. Read as the composite, the
// effect sampled a link the frame had yet to fill, so the layer drew nothing
// and the native backend refused the scene as history feedback. Another layer
// binding the same name still samples the finished composite.
TEST(LayerTextureReference, ALayersOwnEffectReadsItsBufferANotItsComposite) {
    ExpectOwnEffectsReadTheChainInput("_rt_imageLayerComposite_7_a", "_rt_imageLayerComposite_7_a");
}

// `_b` is the chain's other ping-pong buffer. The layer is drawn into `_a` and
// every effect pass without a target of its own writes the other buffer; the
// editor names, in the slot `previous` fills, the buffer `previous` was in when
// the effect was set up, so `_a` and `_b` alternate along the chain (built-in
// blur, shine and godrays; a workshop wave named `_b` in its first slot, after
// one effect). Taken as last-frame history, the name made the native backend
// refuse the whole scene and the wave sampled an empty link; it is the image
// the effect works on. A name left over from before the effects were reordered
// is still that image.
TEST(LayerTextureReference, ALayersOwnEffectReadsItsBufferBAsTheImageItWorksOn) {
    {
        SCOPED_TRACE("_a then _b, as the editor alternates them");
        ExpectOwnEffectsReadTheChainInput("_rt_imageLayerComposite_7_a",
                                          "_rt_imageLayerComposite_7_b");
    }
    {
        SCOPED_TRACE("_b in both");
        ExpectOwnEffectsReadTheChainInput("_rt_imageLayerComposite_7_b",
                                          "_rt_imageLayerComposite_7_b");
    }
}

// A wallpaper whose settings offer a choice -- a theme, a language, a date
// format -- usually ships every option as a layer and hides all but the chosen
// one through its properties. Changing a property reloads the scene, so a layer
// they hide cannot appear before the next parse unless a script shows it. Its
// passes, and the effect targets they would allocate, stay out of the graph
// until then; a layer a script drives, or one another layer samples, stays in.
// A layer whose own effect names it, and which the editor lists in its own
// `dependencies` for that, is not sampled by another.
TEST(HiddenLayers, ALayerItsPropertiesHideStaysOutOfTheGraphUntilSomethingShowsIt) {
    const ProjectProperties properties {
        { "light", RuntimeScalarValue::Bool(true) },
        { "dark", RuntimeScalarValue::Bool(false) },
    };
    auto files = CopyEffectFiles();
    files["/linked_mat.json"] =
        R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["_rt_imageLayerComposite_6_a"]}]})";
    fs::VFS vfs;
    MountFiles(vfs, std::move(files));
    audio::SoundManager sound;
    WPSceneParser       parser;
    auto                parsed = parser.Parse(
        SceneParseRequest { .scene_id = "hidden-layers", .project_properties = &properties },
        SceneJson(R"([
        {"id":1,"name":"chosen","image":"image.json","visible":{"user":"light","value":false},
         "effects":[{"file":"effects/copy/effect.json","visible":true}]},
        {"id":2,"name":"unchosen","image":"image.json","visible":{"user":"dark","value":true},
         "effects":[{"file":"effects/copy/effect.json","visible":true}]},
        {"id":3,"name":"group","visible":{"user":"dark","value":true}},
        {"id":4,"name":"member","image":"image.json","parent":3,
         "effects":[{"file":"effects/copy/effect.json","visible":true}]},
        {"id":5,"name":"scripted","image":"image.json",
         "visible":{"script":"export function update(value) { return value; }",
                    "user":"dark","value":true}},
        {"id":6,"name":"source","image":"image.json","visible":{"user":"dark","value":true}},
        {"id":7,"name":"consumer","image":"linked.json","dependencies":[6]},
        {"id":8,"name":"self-lit","image":"image.json","visible":{"user":"dark","value":true},
         "dependencies":[8],
         "effects":[{"file":"effects/copy/effect.json","visible":true,
                     "passes":[{"textures":["_rt_imageLayerComposite_8_a"]}]}]},
        {"id":9,"name":"self-lit-off","image":"image.json","visible":false,
         "dependencies":[9],
         "effects":[{"file":"effects/copy/effect.json","visible":true,
                     "passes":[{"textures":["_rt_imageLayerComposite_9_b"]}]}]}
      ])"),
        vfs,
        sound);
    ASSERT_NE(parsed, nullptr);
    ASSERT_NE(parsed->runtime, nullptr);
    AddScreenTarget(*parsed);
    auto& runtime = *parsed->runtime;

    // Every pass a layer owns, its effect steps included, counted by the layer
    // whose visibility decides whether it draws.
    const auto passes_of = [](const rg::RenderGraph& graph, std::string_view name) {
        std::size_t count = 0;
        for (const auto id : graph.topologicalOrder()) {
            auto* pass = dynamic_cast<const rg::DrawPass*>(graph.getPass(id));
            if (pass == nullptr) continue;
            const auto* owner = pass->desc().visibility_node != nullptr
                                    ? pass->desc().visibility_node
                                    : pass->desc().node;
            if (owner != nullptr && owner->Name() == name) ++count;
        }
        return count;
    };

    auto graph = sceneToRenderGraph(*parsed);
    ASSERT_NE(graph, nullptr);
    EXPECT_GT(passes_of(*graph, "chosen"), 1u) << "the chosen layer lost its effect";
    EXPECT_EQ(passes_of(*graph, "unchosen"), 0u) << "a layer its properties hide was drawn";
    EXPECT_EQ(passes_of(*graph, "member"), 0u) << "a hidden group's member was drawn";
    EXPECT_EQ(passes_of(*graph, "scripted"), 1u)
        << "a layer whose script decides its visibility must stay in the graph";
    EXPECT_EQ(passes_of(*graph, "source"), 1u) << "a hidden layer another samples must still draw";
    EXPECT_EQ(passes_of(*graph, "self-lit"), 0u)
        << "a layer its properties hide was kept for its own effect";
    EXPECT_EQ(passes_of(*graph, "self-lit-off"), 0u)
        << "a hidden layer was kept for its own effect";

    // Showing a layer that is already in the graph changes nothing about it.
    EXPECT_FALSE(runtime.ConsumeSceneGraphMutationFlag());
    ASSERT_TRUE(runtime.SetNodeVisible("scripted", true));
    EXPECT_FALSE(runtime.ConsumeSceneGraphMutationFlag());

    // What `layer.visible = true` from a SceneScript reaches.
    ASSERT_TRUE(runtime.SetNodeVisible("unchosen", true));
    EXPECT_TRUE(runtime.ConsumeSceneGraphMutationFlag())
        << "a script showed a layer the graph left out, and nothing asked for a new graph";
    graph = sceneToRenderGraph(*parsed);
    EXPECT_EQ(passes_of(*graph, "unchosen"), passes_of(*graph, "chosen"));
    // From now on the script decides: hidden again, it keeps its passes, so a
    // script that blinks a layer asks for one new graph and not one per blink.
    ASSERT_TRUE(runtime.SetNodeVisible("unchosen", false));
    ASSERT_TRUE(runtime.SetNodeVisible("unchosen", true));
    EXPECT_FALSE(runtime.ConsumeSceneGraphMutationFlag());
    ASSERT_TRUE(runtime.SetNodeVisible("unchosen", false));
    graph = sceneToRenderGraph(*parsed);
    EXPECT_EQ(passes_of(*graph, "unchosen"), passes_of(*graph, "chosen"));

    // The group's member shows when the group does.
    ASSERT_TRUE(runtime.SetNodeVisible("group", true));
    EXPECT_TRUE(runtime.ConsumeSceneGraphMutationFlag());
    graph = sceneToRenderGraph(*parsed);
    EXPECT_EQ(passes_of(*graph, "member"), passes_of(*graph, "chosen"));
    ASSERT_TRUE(runtime.SetNodeVisible("group", false));

    // A property applied in place, rather than by a reload, shows the rest.
    fs::VFS             reload_vfs;
    MountFiles(reload_vfs, CopyEffectFiles());
    auto in_place = parser.Parse(
        SceneParseRequest { .scene_id = "hidden-layers", .project_properties = &properties },
        SceneJson(R"([
        {"id":2,"name":"unchosen","image":"image.json","visible":{"user":"dark","value":true},
         "effects":[{"file":"effects/copy/effect.json","visible":true}]}
      ])"),
        reload_vfs,
        sound);
    ASSERT_NE(in_place, nullptr);
    AddScreenTarget(*in_place);
    graph = sceneToRenderGraph(*in_place);
    EXPECT_EQ(passes_of(*graph, "unchosen"), 0u);
    in_place->runtime->ApplyProjectPropertyOverride({ { "dark", RuntimeScalarValue::Bool(true) } });
    in_place->runtime->Tick(1.0 / 60.0);
    EXPECT_TRUE(in_place->runtime->ConsumeSceneGraphMutationFlag())
        << "a property shown in place left its layer out of the graph";
    graph = sceneToRenderGraph(*in_place);
    EXPECT_GT(passes_of(*graph, "unchosen"), 1u);
}

// A property shown on the running scene, rather than by loading it again, takes
// the same path a script does: the tick that applies it sees a layer appear that
// the graph left out and asks for one new graph. Nothing else moves the graph. A
// layer the preview hides again keeps its passes until the next build, so a layer
// that blinks costs nothing, and the next build leaves it out once more.
TEST(HiddenLayers, APropertyPreviewRevealsALayerWithOneGraphRebuildAndAGraphBuiltLaterLeavesTheHiddenOneOutAgain) {
    const ProjectProperties properties {
        { "light", RuntimeScalarValue::Bool(true) },
        { "dark", RuntimeScalarValue::Bool(false) },
        { "glow", RuntimeScalarValue::Bool(false) },
    };
    fs::VFS vfs;
    MountFiles(vfs, CopyEffectFiles());
    audio::SoundManager sound { audio::SoundManager::OutputBackend::Null };
    WPSceneParser       parser;
    auto                parsed = parser.Parse(
        SceneParseRequest { .scene_id = "preview-reveals", .project_properties = &properties },
        SceneJson(R"([
        {"id":1,"name":"chosen","image":"image.json","visible":{"user":"light","value":false},
         "effects":[{"file":"effects/copy/effect.json","visible":true}]},
        {"id":2,"name":"unchosen","image":"image.json","visible":{"user":"dark","value":true},
         "effects":[{"file":"effects/copy/effect.json","visible":true}]},
        {"id":3,"name":"held","image":"image.json","visible":{"user":"glow","value":true},
         "effects":[{"file":"effects/copy/effect.json","visible":{"user":"glow","value":true}}]}
      ])"),
        vfs,
        sound);
    ASSERT_NE(parsed, nullptr);
    ASSERT_NE(parsed->runtime, nullptr);
    AddScreenTarget(*parsed);
    auto& runtime = *parsed->runtime;

    const auto passes_of = [](const rg::RenderGraph& graph, std::string_view name) {
        std::size_t count = 0;
        for (const auto id : graph.topologicalOrder()) {
            auto* pass = dynamic_cast<const rg::DrawPass*>(graph.getPass(id));
            if (pass == nullptr) continue;
            const auto* owner = pass->desc().visibility_node != nullptr
                                    ? pass->desc().visibility_node
                                    : pass->desc().node;
            if (owner != nullptr && owner->Name() == name) ++count;
        }
        return count;
    };
    // One tick, as a frame runs it, and whether it asked for a new graph.
    const auto tick = [&runtime] {
        runtime.Tick(1.0 / 60.0);
        return runtime.ConsumeSceneGraphMutationFlag();
    };

    auto graph = sceneToRenderGraph(*parsed);
    ASSERT_NE(graph, nullptr);
    const std::size_t chosen_passes = passes_of(*graph, "chosen");
    ASSERT_GT(chosen_passes, 1u) << "the chosen layer lost its effect";
    ASSERT_EQ(passes_of(*graph, "unchosen"), 0u);
    ASSERT_EQ(passes_of(*graph, "held"), 0u);
    EXPECT_FALSE(tick());

    // A property that only changes what is already shown asks for no graph.
    runtime.PreviewProjectPropertyOverride({ { "light", RuntimeScalarValue::Bool(true) } });
    EXPECT_FALSE(tick());

    // A property that only a load can apply reveals nothing: the layer and the
    // effect that follow the same switch stay as the scene built them.
    const auto held = runtime.PreviewProjectPropertyOverride({ { "glow", RuntimeScalarValue::Bool(true) } });
    EXPECT_EQ(held.deferred, std::vector<std::string> { "glow" });
    EXPECT_FALSE(tick());
    EXPECT_FALSE(runtime.NodeVisible("held"));

    // The preview shows the layer: one tick asks for one graph, and no tick after
    // it asks again, whether the graph has been built yet or not.
    runtime.PreviewProjectPropertyOverride({ { "dark", RuntimeScalarValue::Bool(true) } });
    EXPECT_TRUE(tick()) << "a preview showed a layer the graph left out and asked for no new graph";
    EXPECT_FALSE(tick());
    graph = sceneToRenderGraph(*parsed);
    EXPECT_EQ(passes_of(*graph, "unchosen"), chosen_passes);

    // Hidden again and shown again on the graph that has its passes: nothing is
    // rebuilt, and the passes are still there the whole time.
    runtime.PreviewProjectPropertyOverride({});
    EXPECT_FALSE(tick());
    EXPECT_FALSE(runtime.NodeVisible("unchosen"));
    EXPECT_EQ(passes_of(*graph, "unchosen"), chosen_passes);
    runtime.PreviewProjectPropertyOverride({ { "dark", RuntimeScalarValue::Bool(true) } });
    EXPECT_FALSE(tick()) << "a layer the graph still draws asked for a new graph";

    // A graph built while it is hidden leaves it out again: its passes and the
    // targets they would allocate are not kept for a layer only a property shows.
    runtime.PreviewProjectPropertyOverride({});
    EXPECT_FALSE(tick());
    graph = sceneToRenderGraph(*parsed);
    EXPECT_EQ(passes_of(*graph, "unchosen"), 0u);
    EXPECT_EQ(passes_of(*graph, "chosen"), chosen_passes);

    // And showing it then asks for a graph again, once.
    runtime.PreviewProjectPropertyOverride({ { "dark", RuntimeScalarValue::Bool(true) } });
    EXPECT_TRUE(tick());
    EXPECT_FALSE(tick());
    graph = sceneToRenderGraph(*parsed);
    EXPECT_EQ(passes_of(*graph, "unchosen"), chosen_passes);
}

// A fullscreen layer post-processes the screen, so its result has to land on
// all of it. Drawn through the scene camera, a camera layer's zoom shrank it to
// a window on the canvas with the unprocessed scene around it.
TEST(CameraFraming, AFullscreenLayerCoversTheScreenWhateverTheShot) {
    fs::VFS vfs;
    auto    extra = CopyEffectFiles();
    extra["/post.json"] = R"({"fullscreen":true,"passthrough":true,"material":"mat.json"})";
    auto parsed = ParseScene(vfs, R"([
        {"id":9,"name":"shot","camera":"default","origin":[8,4,500],
         "angles":[0,0,0],"fov":50,"zoom":2},
        {"id":1,"name":"backdrop","image":"image.json","origin":[32,16,0]},
        {"id":2,"name":"post","image":"post.json",
         "effects":[{"file":"effects/copy/effect.json","visible":true}]}
      ])",
                             std::move(extra));
    ASSERT_NE(parsed, nullptr);
    AddScreenTarget(*parsed);
    const auto graph = sceneToRenderGraph(*parsed);
    ASSERT_NE(graph, nullptr);

    // The scene itself is still shown twice as close about (40, 20).
    const auto* backdrop = FindPassByNode(*graph, "backdrop");
    ASSERT_NE(backdrop, nullptr);
    const auto corner = CardCornerNdc(*parsed, *backdrop, { 32.0, 16.0 });
    EXPECT_NEAR(corner.x(), 1.5, 1e-4);
    EXPECT_NEAR(corner.y(), 1.5, 1e-4);

    // The post layer's result, the last thing drawn to the screen, covers it.
    const auto* post = FindPassByOutput(*graph, SpecTex_Default);
    ASSERT_NE(post, nullptr);
    ASSERT_NE(post, backdrop);
    ExpectCardFillsItsTarget(*parsed, *post, { 32.0, 16.0 });
}

TEST(CameraFraming, OpaqueGeometryPrecedesTransparentCardsOnlyWhenRequested) {
    for (const bool enabled : { false, true }) {
        fs::VFS vfs;
        MountFiles(vfs, {
            { "/opaque.json", R"({"width":64,"height":32,"material":"opaque_mat.json"})" },
            { "/opaque_mat.json",
              R"({"passes":[{"shader":"genericimage","blending":"disabled","depthtest":"enabled","depthwrite":"enabled","textures":["solid"]}]})" },
        });
        auto json = nlohmann::json::parse(SceneJson(R"([
            {"id":1,"name":"glow","image":"image.json"},
            {"id":2,"name":"background","image":"opaque.json"}
          ])"));
        json["general"]["orthogonalprojection"] = nullptr;
        json["general"]["transparentsorting"] = enabled;
        audio::SoundManager sound;
        WPSceneParser parser;
        auto scene = parser.Parse("opaque-before-glow", json.dump(), vfs, sound);
        ASSERT_NE(scene, nullptr);
        const auto graph = sceneToRenderGraph(*scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_NE(FindPassByNode(*graph, "glow"), nullptr);
        ASSERT_NE(FindPassByNode(*graph, "background"), nullptr);
        EXPECT_EQ(PassIndexByNode(*graph, "background") < PassIndexByNode(*graph, "glow"),
                  enabled);
    }
}

TEST(CameraFraming, AFullscreenEffectCoversAPerspectiveScene) {
    fs::VFS vfs;
    auto extra = CopyEffectFiles();
    extra["/post.json"] = R"({"fullscreen":true,"passthrough":true,"material":"mat.json"})";
    MountFiles(vfs, std::move(extra));
    auto json = nlohmann::json::parse(SceneJson(R"([
        {"id":9,"name":"shot","camera":"default","origin":[2,1,6],"fov":50},
        {"id":2,"name":"post","image":"post.json",
         "effects":[{"file":"effects/copy/effect.json","visible":true}]}
      ])"));
    json["general"]["orthogonalprojection"] = nullptr;
    audio::SoundManager sound;
    WPSceneParser parser;
    auto parsed = parser.Parse("perspective-post", json.dump(), vfs, sound);
    ASSERT_NE(parsed, nullptr);
    ASSERT_TRUE(parsed->activeCamera->IsPerspective());
    const auto graph = sceneToRenderGraph(*parsed);
    ASSERT_NE(graph, nullptr);
    const auto* post = FindPassByOutput(*graph, SpecTex_Default);
    ASSERT_NE(post, nullptr);
    const linalg::Vector2d half_extent(parsed->scene_extent[0] / 2.0,
                                      parsed->scene_extent[1] / 2.0);
    ExpectCardFillsItsTarget(*parsed, *post, half_extent);
    parsed->activeCamera->SetFov(75);
    parsed->activeCamera->Update();
    ExpectCardFillsItsTarget(*parsed, *post, half_extent);
}

// Wallpaper Engine lays a fullscreen layer over the whole screen and takes only
// its visibility from the hierarchy. Placed by the world matrix, the result of
// a layer under a translated, scaled or turned group was drawn as a copy of
// the screen shifted by the group, with the screen's own corner showing in the
// opposite one.
TEST(CameraFraming, AFullscreenLayerCoversTheScreenWhereverItsParentSits) {
    struct Group {
        const char* name;
        const char* origin;
        const char* scale;
        const char* angles;
    };
    constexpr std::array<Group, 4> groups { {
        { "translated", "[20,10,0]", "[1,1,1]", "[0,0,0]" },
        { "scaled", "[20,10,0]", "[1.5,1.5,1]", "[0,0,0]" },
        { "turned", "[20,10,0]", "[1,1,1]", "[0,0,0.3]" },
        { "scaled and turned", "[-12,7,0]", "[0.6,1.5,1]", "[0,0,-0.7]" },
    } };
    for (const auto& group : groups) {
        SCOPED_TRACE(group.name);
        fs::VFS vfs;
        auto    extra = CopyEffectFiles();
        extra["/post.json"] = R"({"fullscreen":true,"passthrough":true,"material":"mat.json"})";
        // The post layer sits two groups down: the inner group carries the
        // transform under test, the outer one moves it again.
        const ProjectProperties properties;
        auto parsed = ParseScene(vfs,
                                 std::string(R"([
            {"id":1,"name":"backdrop","image":"image.json","origin":[32,16,0]},
            {"id":3,"name":"outer","origin":[5,-4,0]},
            {"id":4,"name":"inner","parent":3,"origin":)") +
                                     group.origin + R"(,"scale":)" + group.scale +
                                     R"(,"angles":)" + group.angles + R"(},
            {"id":2,"name":"post","parent":4,"image":"post.json",
             "effects":[{"file":"effects/copy/effect.json","visible":true}]}
          ])",
                                 std::move(extra), &properties);
        ASSERT_NE(parsed, nullptr);
        ASSERT_NE(parsed->runtime, nullptr);
        AddScreenTarget(*parsed);
        const auto graph = sceneToRenderGraph(*parsed);
        ASSERT_NE(graph, nullptr);
        const auto* post = FindPassByOutput(*graph, SpecTex_Default);
        ASSERT_NE(post, nullptr);
        ASSERT_NE(post, FindPassByNode(*graph, "backdrop"));

        // As the parser leaves it, and again after the runtime has ticked: every
        // tick it copies each layer's world matrix onto its effect's final card.
        ExpectCardFillsItsTarget(*parsed, *post, { 32.0, 16.0 });
        for (int tick = 0; tick < 3; ++tick) parsed->runtime->Tick(1.0 / 60.0);
        ExpectCardFillsItsTarget(*parsed, *post, { 32.0, 16.0 });
    }
}

// Camera parallax moves a whole tree by its outermost layer's distance from the
// middle of the view. A fullscreen layer is placed by the canvas alone, so the
// group it sits in carries it nowhere there either.
TEST(CameraFraming, ParallaxDoesNotCarryAFullscreenLayerWithItsParent) {
    fs::VFS vfs;
    auto    extra = CopyEffectFiles();
    extra["/post.json"] = R"({"fullscreen":true,"passthrough":true,"material":"mat.json"})";
    MountFiles(vfs, std::move(extra));
    audio::SoundManager sound;
    WPSceneParser       parser;
    auto                parsed = parser.Parse("fullscreen-parallax", ParallaxSceneJson(R"([
        {"id":3,"name":"group","origin":[20,10,0]},
        {"id":2,"name":"post","parent":3,"image":"post.json",
         "effects":[{"file":"effects/copy/effect.json","visible":true}]}
      ])"),
                                     vfs,
                                     sound);
    ASSERT_NE(parsed, nullptr);
    AddScreenTarget(*parsed);
    // The cursor at rest in the middle of the view, so the only thing that
    // could move the layer is where its group sits.
    parsed->shaderValueUpdater->MouseInput(0.5, 0.5);
    parsed->frameTime = 1.0;
    parsed->shaderValueUpdater->FrameBegin();

    const auto graph = sceneToRenderGraph(*parsed);
    ASSERT_NE(graph, nullptr);
    const auto* post = FindPassByOutput(*graph, SpecTex_Default);
    ASSERT_NE(post, nullptr);
    ExpectCardFillsItsTarget(*parsed, *post, { 32.0, 16.0 });
}

// A group decides whether the fullscreen layer under it shows, though no longer
// where: hiding the group hides the layer, and showing it again brings back a
// card that still covers the screen.
TEST(CameraFraming, AGroupStillDecidesWhetherAFullscreenLayerShows) {
    const ProjectProperties properties { { "open", RuntimeScalarValue::Bool(true) } };
    fs::VFS                 vfs;
    auto                    extra = CopyEffectFiles();
    extra["/post.json"] = R"({"fullscreen":true,"passthrough":true,"material":"mat.json"})";
    auto parsed = ParseScene(vfs, R"([
        {"id":1,"name":"backdrop","image":"image.json","origin":[32,16,0]},
        {"id":3,"name":"group","origin":[20,10,0],"visible":{"user":"open","value":true}},
        {"id":2,"name":"post","parent":3,"image":"post.json",
         "effects":[{"file":"effects/copy/effect.json","visible":true}]}
      ])",
                             std::move(extra), &properties);
    ASSERT_NE(parsed, nullptr);
    ASSERT_NE(parsed->runtime, nullptr);
    AddScreenTarget(*parsed);
    auto&      runtime = *parsed->runtime;
    const auto tick    = [&runtime](bool open) {
        runtime.PreviewProjectPropertyOverride({ { "open", RuntimeScalarValue::Bool(open) } });
        runtime.Tick(1.0 / 60.0);
    };
    const auto graph = sceneToRenderGraph(*parsed);
    ASSERT_NE(graph, nullptr);
    const auto* post = FindPassByOutput(*graph, SpecTex_Default);
    ASSERT_NE(post, nullptr);
    ASSERT_NE(post, FindPassByNode(*graph, "backdrop"));

    // The pass shows exactly when the layer does: its own switch and every
    // group above it.
    const auto* owner = post->desc().visibility_node != nullptr ? post->desc().visibility_node
                                                                : post->desc().node;
    ASSERT_NE(owner, nullptr);
    tick(true);
    EXPECT_TRUE(owner->EffectiveVisible());
    ExpectCardFillsItsTarget(*parsed, *post, { 32.0, 16.0 });
    tick(false);
    EXPECT_FALSE(runtime.NodeVisible("group"));
    EXPECT_TRUE(runtime.NodeVisible("post")) << "the layer's own switch was never touched";
    EXPECT_FALSE(owner->EffectiveVisible()) << "a hidden group left its fullscreen layer shown";
    tick(true);
    EXPECT_TRUE(owner->EffectiveVisible());
    ExpectCardFillsItsTarget(*parsed, *post, { 32.0, 16.0 });
}

// A fullscreen layer is drawn over the whole screen whatever its own transform,
// but the layers below it are placed from the transform the scene saved for it
// (none saved, none added) under the groups it sits in. Placed from the screen
// centre the layer is drawn at, a picture saved at the middle of the canvas was
// drawn a whole canvas away.
TEST(CameraFraming, TheChildrenOfAFullscreenLayerAreSavedAgainstItsSavedTransform) {
    struct Case {
        const char* name;
        const char* post_fields;
        const char* group;
        linalg::Vector3d expected;  // the child's world position
    };
    const std::array<Case, 4> cases { {
        { "no origin", "", "", { 7.0, 9.0, 0.0 } },
        { "an origin saved", R"("origin":[5,3,0],)", "", { 12.0, 12.0, 0.0 } },
        { "a scale saved", R"("origin":[5,3,0],"scale":[2,2,1],)", "", { 19.0, 21.0, 0.0 } },
        { "under a moved group", "", R"("parent":3,)", { 27.0, 19.0, 0.0 } },
    } };
    for (const auto& item : cases) {
        SCOPED_TRACE(item.name);
        fs::VFS vfs;
        auto    extra = CopyEffectFiles();
        extra["/post.json"] = R"({"fullscreen":true,"passthrough":true,"material":"mat.json"})";
        const ProjectProperties properties;
        auto parsed = ParseScene(vfs,
                                 std::string(R"([
            {"id":3,"name":"group","origin":[20,10,0]},
            {"id":2,"name":"post",)") + item.post_fields +
                                     item.group + R"("image":"post.json",
             "effects":[{"file":"effects/copy/effect.json","visible":true}]},
            {"id":4,"name":"picture","parent":2,"origin":[7,9,0]}
          ])",
                                 std::move(extra), &properties);
        ASSERT_NE(parsed, nullptr);
        ASSERT_NE(parsed->runtime, nullptr);
        for (int tick = 0; tick < 2; ++tick) parsed->runtime->Tick(1.0 / 60.0);
        const linalg::Matrix4d picture = parsed->runtime->NodeTransformMatrix("picture");
        EXPECT_NEAR(picture(0, 3), item.expected.x(), 1.0e-4);
        EXPECT_NEAR(picture(1, 3), item.expected.y(), 1.0e-4);
        // The layer itself still covers the screen, whatever was saved for it.
        AddScreenTarget(*parsed);
        const auto graph = sceneToRenderGraph(*parsed);
        ASSERT_NE(graph, nullptr);
        const auto* post = FindPassByOutput(*graph, SpecTex_Default);
        ASSERT_NE(post, nullptr);
        ExpectCardFillsItsTarget(*parsed, *post, { 32.0, 16.0 });
    }
}

// The camera perspective layers of a 2D scene draw through keeps the lens the
// scene authored and follows the canvas plane: whatever frames the canvas -- a
// fill mode, a camera layer's zoom and pan -- puts its eye (visible height / 2) /
// tan(fov / 2) from the plane and over the point the orthographic view looks at,
// so a layer on the plane lands where it does without the perspective.
TEST(CameraFraming, APerspectiveCameraKeepsItsLensAndFollowsEveryWayTheCanvasIsFramed) {
    fs::VFS vfs;
    auto    parsed = ParseScene(vfs, R"([
        {"id":1,"name":"backdrop","image":"image.json","origin":[32,16,0]}
      ])");
    ASSERT_NE(parsed, nullptr);
    const auto& canvas      = *parsed->cameras.at("global");
    const auto& perspective = *parsed->cameras.at("global_perspective");
    const double fov        = perspective.Fov();

    const auto expect_framed = [&](const std::string& what) {
        SCOPED_TRACE(what);
        EXPECT_DOUBLE_EQ(perspective.Fov(), fov) << "the lens is the scene's, not the framing's";
        EXPECT_DOUBLE_EQ(perspective.Aspect(), canvas.Aspect());
        const auto centre = canvas.GetPosition();
        const auto eye    = perspective.GetPosition();
        EXPECT_NEAR(eye.x(), centre.x(), 1e-4);
        EXPECT_NEAR(eye.y(), centre.y(), 1e-4);
        EXPECT_NEAR(eye.z(), (canvas.VisibleHeight() / 2.0) / std::tan(fov * M_PI / 360.0), 1e-3);
        for (const auto& [fx, fy] : {std::pair { -0.5, -0.5 }, std::pair { 0.5, 0.5 },
                                     std::pair { 0.3, -0.2 }}) {
            const linalg::Vector4d point(centre.x() + fx * canvas.VisibleWidth(),
                                        centre.y() + fy * canvas.VisibleHeight(), 0.0, 1.0);
            const linalg::Vector4d flat = canvas.GetViewProjectionMatrix() * point;
            const linalg::Vector4d deep = perspective.GetViewProjectionMatrix() * point;
            EXPECT_NEAR(deep.x() / deep.w(), flat.x() / flat.w(), 1e-5);
            EXPECT_NEAR(deep.y() / deep.w(), flat.y() / flat.w(), 1e-5);
        }
    };

    expect_framed("as parsed");
    struct Output {
        FillMode    mode;
        const char* name;
        uint32_t    width;
        uint32_t    height;
    };
    for (const auto& output : { Output { FillMode::STRETCH, "stretch", 300, 90 },
                                Output { FillMode::ASPECTFIT, "fit wide", 400, 100 },
                                Output { FillMode::ASPECTFIT, "fit tall", 100, 400 },
                                Output { FillMode::ASPECTCROP, "crop wide", 400, 100 },
                                Output { FillMode::ASPECTCROP, "crop tall", 100, 400 } }) {
        render::ApplyCameraFillMode(*parsed, output.mode, output.width, output.height);
        expect_framed(output.name);
    }
    parsed->FrameCanvas(2.0, linalg::Vector2f(8.0f, 4.0f));
    expect_framed("zoomed and panned");
    parsed->FrameCanvas(1.0, linalg::Vector2f(0.0f, 0.0f));
    expect_framed("back to the whole canvas");
}

// The static-result cache reuses a target's pixels while every pass writing it
// samples the same. A camera layer zooming or panning the scene moves no node
// and rebuilds no graph, so a sample blind to the camera served the first
// frame of an intro for as long as it played.
TEST(CameraFraming, MovingTheCameraChangesTheStaticSampleOfAPassItDraws) {
    fs::VFS vfs;
    auto    parsed = ParseScene(vfs, R"([
        {"id":1,"name":"backdrop","image":"image.json","origin":[32,16,0]}
      ])");
    ASSERT_NE(parsed, nullptr);
    AddScreenTarget(*parsed);
    const auto graph = sceneToRenderGraph(*parsed);
    ASSERT_NE(graph, nullptr);
    const auto* backdrop = FindPassByNode(*graph, "backdrop");
    ASSERT_NE(backdrop, nullptr);

    // The camera fold both the sample of a pass and the reuse cache are built on.
    const auto sample = [&] {
        return render::FoldPassCameras(0xcbf29ce484222325ULL, *parsed,
                                       backdrop->desc().camera_override, backdrop->desc().node);
    };
    const auto still = sample();
    EXPECT_EQ(sample(), still) << "an unchanged pass must be reusable";
    parsed->FrameCanvas(2.0, linalg::Vector2f(8.0f, 4.0f));
    EXPECT_NE(sample(), still) << "the view moved and the pass would still be reused";
}
