// Effect chains on text layers: the chain follows the text card as it is laid out, grows,
// shrinks or is cut at the buffer limit, and an effect on a text layer sees frame time. Also the
// metadata a shader's default textures contribute to a material (an image layer, not text).
// Headless: scenes are parsed and their render graph is built, never executed.

#include "text_fixture.hpp"

#include "RenderCommon/SceneToRenderGraph.hpp"
#include "RenderGraph/RenderGraph.hpp"
#include "Scene/SceneShader.h"
#include "SpecTexs.hpp"
#include "WPShaderValueUpdater.hpp"
#include "support/scene_package.hpp"

#include <cmath>
#include <cstring>

namespace
{
using namespace we_test;
using namespace wallpaper;

constexpr const char* kEffectFile = "effects/gradient/effect.json";

const char kPassThroughFragment[] = R"(varying vec2 v_TexCoord;
uniform sampler2D g_Texture0;
void main() {
    gl_FragColor = texSample2D(g_Texture0, v_TexCoord);
}
)";

const char kTimedFragment[] = R"(varying vec2 v_TexCoord;
uniform sampler2D g_Texture0;
uniform float g_Time;
uniform vec3 u_Gradient; // {"material":"gradient","default":"1 1 1"}
void main() {
    vec4 texel = texSample2D(g_Texture0, v_TexCoord);
    gl_FragColor = vec4(u_Gradient * abs(cos(g_Time)), texel.a);
}
)";

/// Installs a one- or two-pass effect that copies the card through.
void PutPassThroughEffect(TextWorld& world, bool with_buffer, const char* fragment = kPassThroughFragment,
                          const Json& material_constants = Json::object())
{
    Json passes;
    if (with_buffer) {
        passes = Json::array({ { { "material", "materials/effects/gradient.json" },
                                 { "bind", Json::array({ { { "name", "previous" }, { "index", 0 } } }) },
                                 { "target", "_rt_BlurBuffer" } },
                               { { "material", "materials/effects/gradient.json" },
                                 { "bind", Json::array({ { { "name", "_rt_BlurBuffer" }, { "index", 0 } } }) } } });
    } else {
        passes = Json::array({ { { "material", "materials/effects/gradient.json" } } });
    }
    Json effect = { { "name", "gradient" }, { "version", 1 }, { "passes", passes } };
    if (with_buffer) effect["fbos"] = Json::array({ { { "name", "_rt_BlurBuffer" }, { "scale", 2 } } });
    world.PutAsset(kEffectFile, effect.dump());

    Json pass = { { "shader", "effects/gradient" }, { "textures", Json::array({ nullptr }) } };
    if (!material_constants.empty()) pass["constantshadervalues"] = material_constants;
    world.PutAsset("materials/effects/gradient.json", Json({ { "passes", Json::array({ pass }) } }).dump());
    world.PutAsset("shaders/effects/gradient.vert", StandardVertexShader());
    world.PutAsset("shaders/effects/gradient.frag", fragment);
}

Json EffectEntry(const Json& extra = Json::object())
{
    Json entry = { { "file", kEffectFile }, { "id", 2 }, { "visible", true } };
    for (const auto& [key, value] : extra.items()) entry[key] = value;
    return entry;
}

/// A caption with one gradient effect; `extra` keys replace the layer's defaults.
Json EffectCaption(const Json& text, const Json& extra = Json::object())
{
    Json merged = { { "effects", Json::array({ EffectEntry() }) } };
    for (const auto& [key, value] : extra.items()) merged[key] = value;
    return TextObject(1, "caption", text, merged);
}

/// Everything about a caption's chain the tests read, looked up fresh each time.
struct Chain {
    Scene&                 scene;
    SceneNode*             text { nullptr };
    SceneCamera*           camera { nullptr };
    SceneImageEffectLayer* layer { nullptr };

    explicit Chain(Scene& s, std::string_view name = "caption") : scene(s)
    {
        text = RootChild(scene, name);
        if (text == nullptr || text->Camera().empty()) return;
        const auto found = scene.cameras.find(text->Camera());
        if (found == scene.cameras.end() || found->second == nullptr || !found->second->HasImgEffect()) return;
        camera = found->second.get();
        layer  = camera->GetImgEffect().get();
    }

    [[nodiscard]] bool Ok() const { return text != nullptr && camera != nullptr && layer != nullptr; }
    SceneRenderTarget* PingPong() const { return scene.FindRenderTarget(layer->FirstTarget()); }
    SceneRenderTarget* Buffer() const
    {
        return scene.FindRenderTarget(layer->GetEffect(0)->nodes.front().output);
    }
    [[nodiscard]] Box TextBox() const { return PositionBox(*text->Mesh()); }
    [[nodiscard]] Box FinalBox() const { return PositionBox(layer->FinalMesh()); }
    [[nodiscard]] Box FinalUv() const { return TexCoordBox(layer->FinalMesh()); }
};

/// The buffer covers the final card: `buffer width * u extent` reaches the card's width, capped
/// at the target the chain renders to.
void ExpectBufferCoversFinalCard(const SceneRenderTarget& buffer, const SceneMesh& final_mesh, int target_w,
                                 int target_h)
{
    const Box uv = TexCoordBox(final_mesh);
    const Box fm = PositionBox(final_mesh);
    EXPECT_GE(buffer.width * (uv.max_x - uv.min_x) + 1e-3, std::min<double>(target_w, std::ceil(fm.W())));
    EXPECT_GE(buffer.height * (uv.max_y - uv.min_y) + 1e-3, std::min<double>(target_h, std::ceil(fm.H())));
}

void ExpectUnitTexCoords(const Box& uv)
{
    EXPECT_FLOAT_EQ(uv.min_x, 0.0f);
    EXPECT_FLOAT_EQ(uv.max_x, 1.0f);
    EXPECT_FLOAT_EQ(uv.min_y, 0.0f);
    EXPECT_FLOAT_EQ(uv.max_y, 1.0f);
}

void ExpectBoxMatches(const Box& box, const Box& reference, float tolerance)
{
    EXPECT_NEAR(box.W(), reference.W(), tolerance);
    EXPECT_NEAR(box.H(), reference.H(), tolerance);
}

std::string Longer() { return "a much longer caption for effects"; }

} // namespace

class TextEffectChain : public TextSceneTest {
protected:
    /// Drops flags the parse and graph build may have left, so a test sees only its own change.
    void DrainFlags()
    {
        (void)Runtime().ConsumeSceneGraphMutationFlag();
        (void)Runtime().ConsumeRenderTargetResizeFlag();
    }
};

// ---- F. the chain follows the card -------------------------------------------------------

TEST_F(TextEffectChain, AnEffectOnATextLayerReceivesFrameTime)
{
    PutPassThroughEffect(world, false, kTimedFragment, { { "gradient", "0.1 0.2 0.3" } });
    ASSERT_TRUE(Load(SceneDocument({ EffectCaption(
        "a", { { "size", "200 40" },
               { "effects", Json::array({ EffectEntry({ { "passes", Json::array({ { { "constantshadervalues",
                                                                                   { { "gradient", "0.25 0.5 0.75" } } } } }) } }) }) } }) })));
    Chain chain(*scene);
    ASSERT_TRUE(chain.Ok());
    ASSERT_NE(sceneToRenderGraph(*scene), nullptr);

    SceneNode* effect_node = chain.layer->GetEffect(0)->nodes.front().sceneNode.get();
    ASSERT_NE(effect_node, nullptr);
    auto* updater = dynamic_cast<WPShaderValueUpdater*>(scene->shaderValueUpdater.get());
    ASSERT_NE(updater, nullptr);
    updater->InitUniforms(effect_node, [](std::string_view name) { return name == "g_Time"; });
    scene->PassFrameTime(0.5);

    sprite_map_t sprites;
    bool         seen = false;
    float        time = -1.0f;
    updater->UpdateUniforms(effect_node, sprites, [&](std::string_view name, const ShaderValue& value) {
        if (name == "g_Time") {
            seen = true;
            time = value[0];
        }
    });
    EXPECT_TRUE(seen) << "g_Time was never reported for the effect of a text layer";
    EXPECT_EQ(time, 0.5f);
}

TEST_F(TextEffectChain, TheChainFollowsACardThatGrows)
{
    PutPassThroughEffect(world, true);
    ASSERT_TRUE(Load(SceneDocument({ EffectCaption("a", { { "padding", 0 } }) })));
    Chain chain(*scene);
    ASSERT_TRUE(chain.Ok());
    const int    w0 = chain.PingPong()->width;
    const double c0 = chain.camera->Width();
    ASSERT_NE(chain.Buffer(), nullptr);
    const int  b0           = chain.Buffer()->width;
    const Box  text_before  = chain.TextBox();
    const Box  final_before = chain.FinalBox();

    ASSERT_NE(sceneToRenderGraph(*scene), nullptr);
    SceneNode* resolved = chain.layer->ResolvedFinalRenderNode();
    ASSERT_NE(resolved, nullptr);
    ASSERT_NE(resolved->Mesh(), nullptr);
    EXPECT_TRUE(resolved->Mesh()->Dynamic());
    DrainFlags();

    ASSERT_TRUE(Runtime().SetNodeText("caption", Longer()));
    ASSERT_TRUE(PumpUntilClean(Runtime(), { "caption" }));

    const auto layout = Runtime().NodeTextLayout("caption");
    ASSERT_TRUE(layout.has_value());
    ASSERT_NE(chain.PingPong(), nullptr);
    EXPECT_GT(chain.PingPong()->width, w0);
    EXPECT_EQ(chain.PingPong()->width, static_cast<int>(layout->card.x()));
    EXPECT_EQ(chain.PingPong()->height, static_cast<int>(layout->card.y()));
    EXPECT_GT(chain.camera->Width(), c0);
    EXPECT_EQ(static_cast<int>(chain.camera->Width()), chain.PingPong()->width);
    EXPECT_EQ(static_cast<int>(chain.camera->Height()), chain.PingPong()->height);
    ASSERT_NE(chain.Buffer(), nullptr);
    ExpectBufferCoversFinalCard(*chain.Buffer(), chain.layer->FinalMesh(), chain.PingPong()->width,
                                chain.PingPong()->height);
    EXPECT_GT(chain.Buffer()->width, b0);

    EXPECT_GT(chain.TextBox().W(), text_before.W());
    EXPECT_GT(chain.FinalBox().W(), final_before.W());
    ExpectBoxMatches(chain.FinalBox(), chain.TextBox(), 1.0f);
    ExpectUnitTexCoords(chain.FinalUv());

    EXPECT_EQ(chain.layer->ResolvedFinalRenderNode(), resolved);
    EXPECT_TRUE(resolved->Mesh()->Dynamic());
    ExpectBoxMatches(PositionBox(*resolved->Mesh()), chain.TextBox(), 1.0f);
    ExpectUnitTexCoords(TexCoordBox(*resolved->Mesh()));

    EXPECT_FALSE(Runtime().ConsumeSceneGraphMutationFlag());
    EXPECT_TRUE(Runtime().ConsumeRenderTargetResizeFlag());
    EXPECT_FALSE(Runtime().ConsumeRenderTargetResizeFlag());
}

TEST_F(TextEffectChain, AFractionalCardIsCutOffNeverRounded)
{
    PutPassThroughEffect(world, false);
    ASSERT_TRUE(Load(SceneDocument({ EffectCaption("Wind", { { "spacing", "0.2 0" },
                                                             { "padding", 0 },
                                                             { "size", Json::array({ 93.6, 41.6 }) } }) })));
    Chain chain(*scene);
    ASSERT_TRUE(chain.Ok());
    const auto layout = Runtime().NodeTextLayout("caption");
    ASSERT_TRUE(layout.has_value());
    ASSERT_GE(layout->card.x() - std::floor(layout->card.x()), 0.5f)
        << "the case is only meaningful when the card's width has a fraction of half or more";

    EXPECT_EQ(static_cast<int>(chain.camera->Width()), static_cast<int>(layout->card.x()));
    EXPECT_EQ(static_cast<int>(chain.camera->Height()), static_cast<int>(layout->card.y()));
    const Box final_box = chain.FinalBox();
    EXPECT_NEAR(final_box.W(), std::floor(layout->card.x()), 1e-3f);
    EXPECT_NEAR(final_box.H(), std::floor(layout->card.y()), 1e-3f);
    ExpectUnitTexCoords(chain.FinalUv());
}

TEST_F(TextEffectChain, AScriptSetTextKeepsTheFinalCardWhole)
{
    PutPassThroughEffect(world, false);
    const std::string script =
        "engine.on('cursorDown', function() { thisLayer.text = '" + Longer() + "'; });";
    ASSERT_TRUE(Load(SceneDocument({ EffectCaption(
        { { "text", "a" }, { "script", script } }, { { "padding", 0 } }) })));
    Chain chain(*scene);
    ASSERT_TRUE(chain.Ok());
    DrainFlags();

    Runtime().DispatchCursorDown();
    ASSERT_TRUE(PumpUntilClean(Runtime(), { "caption" }));

    EXPECT_EQ(Runtime().NodeText("caption"), Longer());
    ExpectUnitTexCoords(chain.FinalUv());
    const auto layout = Runtime().NodeTextLayout("caption");
    ASSERT_TRUE(layout.has_value());
    EXPECT_EQ(chain.PingPong()->width, static_cast<int>(layout->card.x()));
    EXPECT_FALSE(Runtime().ConsumeSceneGraphMutationFlag());
    EXPECT_TRUE(Runtime().ConsumeRenderTargetResizeFlag());
    EXPECT_FALSE(Runtime().ConsumeRenderTargetResizeFlag());
    EXPECT_EQ(Runtime().scriptErrorCount(), 0u);
}

TEST_F(TextEffectChain, ARightBottomTextWithAnEffectFollowsTheMeasuredRenderFrame)
{
    PutPassThroughEffect(world, true);
    const std::string script = UpdateReturning("'a much longer caption for explicit effects'");
    ASSERT_TRUE(Load(SceneDocument({ EffectCaption(
        { { "value", "a" }, { "script", script } },
        { { "padding", 0 }, { "horizontalalign", "right" }, { "verticalalign", "bottom" } }) })));
    Chain chain(*scene);
    ASSERT_TRUE(chain.Ok());

    Runtime().Tick(kFrame);
    ASSERT_TRUE(PumpUntilClean(Runtime(), { "caption" }));
    const auto state  = Runtime().NodeTextState("caption");
    const auto layout = Runtime().NodeTextLayout("caption");
    ASSERT_TRUE(state.has_value());
    ASSERT_TRUE(layout.has_value());
    const auto card  = Runtime().NodeSize("caption");
    const auto frame = TextLayerRenderFrameForLayout(*state, *layout);

    EXPECT_EQ(Runtime().NodeText("caption"), "a much longer caption for explicit effects");
    EXPECT_TRUE(card.isApprox(layout->card));
    EXPECT_GT(card.x(), 400.0f);
    EXPECT_TRUE(chain.text->Translate().isApprox(linalg::Vector3f::Zero()));
    EXPECT_NEAR(frame.center.x(), -card.x() / 2.0f, 1e-3f);

    const Box text_box = chain.TextBox();
    EXPECT_NEAR(text_box.W(), frame.size.x(), 1.0f);
    EXPECT_NEAR(text_box.H(), frame.size.y(), 1.0f);
    EXPECT_NEAR(text_box.CX(), frame.center.x(), 1e-4f);
    EXPECT_NEAR(text_box.CY(), frame.center.y(), 1e-4f);

    ASSERT_NE(chain.PingPong(), nullptr);
    EXPECT_EQ(chain.PingPong()->width, static_cast<int32_t>(frame.size.x()));
    EXPECT_EQ(chain.PingPong()->height, static_cast<int32_t>(frame.size.y()));
    EXPECT_EQ(std::lround(chain.camera->Width()), chain.PingPong()->width);
    EXPECT_EQ(std::lround(chain.camera->Height()), chain.PingPong()->height);
    ASSERT_NE(chain.Buffer(), nullptr);
    ExpectBufferCoversFinalCard(*chain.Buffer(), chain.layer->FinalMesh(), chain.PingPong()->width,
                                chain.PingPong()->height);

    const Box final_box = chain.FinalBox();
    EXPECT_NEAR(final_box.W(), frame.size.x(), 1.0f);
    EXPECT_NEAR(final_box.H(), frame.size.y(), 1.0f);
    EXPECT_NEAR(final_box.CX(), frame.center.x(), 1e-4f);
    EXPECT_NEAR(final_box.CY(), frame.center.y(), 1e-4f);
    ExpectUnitTexCoords(chain.FinalUv());

    ASSERT_NE(sceneToRenderGraph(*scene), nullptr);
    SceneNode* resolved = chain.layer->ResolvedFinalRenderNode();
    ASSERT_NE(resolved, nullptr);
    ASSERT_NE(resolved->Mesh(), nullptr);
    const Box resolved_box = PositionBox(*resolved->Mesh());
    EXPECT_NEAR(resolved_box.W(), frame.size.x(), 1.0f);
    EXPECT_NEAR(resolved_box.H(), frame.size.y(), 1.0f);
    EXPECT_NEAR(resolved_box.CX(), frame.center.x(), 1e-4f);
    EXPECT_NEAR(resolved_box.CY(), frame.center.y(), 1e-4f);

    // A relayout resized the chain's targets once; nothing needed the graph rebuilt.
    EXPECT_FALSE(Runtime().ConsumeSceneGraphMutationFlag());
    EXPECT_TRUE(Runtime().ConsumeRenderTargetResizeFlag());
    ASSERT_TRUE(PumpUntilClean(Runtime(), { "caption" }));
    EXPECT_FALSE(Runtime().ConsumeSceneGraphMutationFlag());
    EXPECT_FALSE(Runtime().ConsumeRenderTargetResizeFlag());
}

TEST_F(TextEffectChain, AStaticAlignedTextWithAnEffectCoversItsRasterWithoutScaling)
{
    PutPassThroughEffect(world, true);
    ASSERT_TRUE(Load(SceneDocument({ EffectCaption("Saturday Saturday Saturday",
                                                   { { "padding", 0 },
                                                     { "horizontalalign", "right" },
                                                     { "verticalalign", "bottom" } }) })));
    Chain chain(*scene);
    ASSERT_TRUE(chain.Ok());
    const auto layout = Runtime().NodeTextLayout("caption");
    ASSERT_TRUE(layout.has_value());
    const auto card = Runtime().NodeSize("caption");
    EXPECT_TRUE(card.isApprox(layout->card));

    const Box text_box = chain.TextBox();
    EXPECT_NEAR(text_box.W(), card.x(), 1.0f);
    EXPECT_NEAR(text_box.H(), card.y(), 1.0f);
    EXPECT_NEAR(text_box.CX(), layout->centre.x(), 1e-4f);
    EXPECT_NEAR(text_box.CY(), layout->centre.y(), 1e-4f);
    EXPECT_NEAR(text_box.CX(), -card.x() / 2.0f, 1e-4f);

    ASSERT_NE(chain.PingPong(), nullptr);
    EXPECT_EQ(chain.PingPong()->width, static_cast<int32_t>(card.x()));
    EXPECT_EQ(chain.PingPong()->height, static_cast<int32_t>(card.y()));
    EXPECT_EQ(std::lround(chain.camera->Width()), chain.PingPong()->width);
    EXPECT_EQ(std::lround(chain.camera->Height()), chain.PingPong()->height);
    const auto position = chain.camera->GetPosition();
    EXPECT_NEAR(position.x(), text_box.CX(), 1e-4);
    EXPECT_NEAR(position.y(), text_box.CY(), 1e-4);
    ASSERT_NE(chain.Buffer(), nullptr);
    ExpectBufferCoversFinalCard(*chain.Buffer(), chain.layer->FinalMesh(), chain.PingPong()->width,
                                chain.PingPong()->height);

    const Box final_box = chain.FinalBox();
    EXPECT_NEAR(final_box.W(), card.x(), 1.0f);
    EXPECT_NEAR(final_box.H(), card.y(), 1.0f);
    EXPECT_NEAR(final_box.CX(), text_box.CX(), 1e-4f);
    EXPECT_NEAR(final_box.CY(), text_box.CY(), 1e-4f);

    ASSERT_NE(sceneToRenderGraph(*scene), nullptr);
    SceneNode* resolved = chain.layer->ResolvedFinalRenderNode();
    ASSERT_NE(resolved, nullptr);
    ASSERT_NE(resolved->Mesh(), nullptr);
    const Box resolved_box = PositionBox(*resolved->Mesh());
    EXPECT_NEAR(resolved_box.W(), card.x(), 1.0f);
    EXPECT_NEAR(resolved_box.H(), card.y(), 1.0f);
    EXPECT_NEAR(resolved_box.CX(), text_box.CX(), 1e-4f);
    EXPECT_NEAR(resolved_box.CY(), text_box.CY(), 1e-4f);
    EXPECT_TRUE(chain.text->Translate().isApprox(linalg::Vector3f::Zero()));
}

// ---- G. the buffer limit -----------------------------------------------------------------

TEST_F(TextEffectChain, ACardPastTheBufferLimitIsCutOffToIt)
{
    PutPassThroughEffect(world, true);
    ASSERT_TRUE(Load(SceneDocument({ EffectCaption(std::string(260, 'W'),
                                                   { { "pointsize", 40 }, { "padding", 0 } }) })));
    Chain chain(*scene);
    ASSERT_TRUE(chain.Ok());
    const auto layout = Runtime().NodeTextLayout("caption");
    ASSERT_TRUE(layout.has_value());
    ASSERT_GT(layout->card.x(), 4096.0f);

    EXPECT_LE(chain.camera->Width(), 4096.0);
    EXPECT_LE(chain.camera->Height(), 4096.0);
    ASSERT_NE(chain.PingPong(), nullptr);
    EXPECT_LE(chain.PingPong()->width, 4096);
    EXPECT_LE(chain.PingPong()->height, 4096);
    EXPECT_GT(chain.TextBox().W(), static_cast<float>(chain.PingPong()->width))
        << "the text card itself is not cut";
    ASSERT_NE(chain.Buffer(), nullptr);
    ExpectBufferCoversFinalCard(*chain.Buffer(), chain.layer->FinalMesh(), chain.PingPong()->width,
                                chain.PingPong()->height);

    const Box final_box = chain.FinalBox();
    EXPECT_NEAR(final_box.W(), static_cast<float>(chain.PingPong()->width), 1.0f);
    EXPECT_LE(final_box.H(), static_cast<float>(chain.PingPong()->height));
    const Box uv = chain.FinalUv();
    EXPECT_FLOAT_EQ(uv.min_x, 0.0f);
    EXPECT_FLOAT_EQ(uv.max_x, 1.0f);
    EXPECT_GE(uv.min_y, 0.0f);
    EXPECT_LE(uv.max_y, 1.0f);

    ASSERT_NE(sceneToRenderGraph(*scene), nullptr);
    SceneNode* resolved = chain.layer->ResolvedFinalRenderNode();
    ASSERT_NE(resolved, nullptr);
    ASSERT_NE(resolved->Mesh(), nullptr);
    EXPECT_NEAR(PositionBox(*resolved->Mesh()).W(), static_cast<float>(chain.PingPong()->width), 1.0f);
    const Box resolved_uv = TexCoordBox(*resolved->Mesh());
    EXPECT_FLOAT_EQ(resolved_uv.min_x, 0.0f);
    EXPECT_FLOAT_EQ(resolved_uv.max_x, 1.0f);
    EXPECT_GE(resolved_uv.min_y, 0.0f);
    EXPECT_LE(resolved_uv.max_y, 1.0f);
    EXPECT_FALSE(Runtime().ConsumeSceneGraphMutationFlag());
}

// ---- H. default textures of a shader -----------------------------------------------------

namespace
{
const char kDefaultedVertex[] = R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
    gl_Position = vec4(a_Position, 1.0);
    v_TexCoord = a_TexCoord;
}
)";

const char kDefaultedFragment[] = R"(varying vec2 v_TexCoord;
uniform sampler2D g_Texture0; // {"material":"albedo","default":"fallback-r8.tex"}
#ifndef TEX0FORMAT
// [COMBO] {"combo":"FIRST_PASS_ONLY","default":1}
#endif
#if FIRST_PASS_ONLY
uniform float g_StaleFirstPassMarker; // {"material":"stale","default":1.0}
#endif
#if TEX0FORMAT == 9
uniform sampler2D g_Texture1; // {"material":"second","default":"second-r8.tex"}
#endif
#if TEX1FORMAT == 9
uniform float g_CascadedDefaultObserved; // {"material":"cascaded","default":1.0}
#endif
void main() {
    vec4 colour = texSample2D(g_Texture0, v_TexCoord);
#if TEX1FORMAT == 9
    colour.r += 0.001 * texSample2D(g_Texture1, v_TexCoord).r + 0.001 * g_CascadedDefaultObserved;
#endif
    gl_FragColor = colour;
}
)";

/// A texture container with no pixel data: one level of 1x1, format 9 (single 8-bit channel).
std::string HeaderOnlyR8Texture()
{
    std::string out;
    const auto  text = [&](const char* tag) {
        out.append(tag, 8);
        out.push_back('\0');
    };
    const auto i32 = [&](int32_t value) {
        for (int shift = 0; shift < 32; shift += 8) out.push_back(static_cast<char>((value >> shift) & 0xff));
    };
    text("TEXV0005");
    text("TEXI0001");
    i32(9);
    i32(0);
    i32(1);
    i32(1);
    i32(1);
    i32(1);
    i32(0);
    text("TEXB0003");
    i32(1);
    i32(static_cast<int32_t>(ImageType::UNKNOWN));
    i32(0);
    return out;
}
} // namespace

TEST_F(TextEffectChain, DefaultTextureFormatsCascadeThroughAMaterial)
{
    world.PutAsset("image.json", Json({ { "width", 64 }, { "height", 32 }, { "material", "mat.json" } }).dump());
    world.PutAsset("mat.json", Json({ { "passes",
                                        Json::array({ { { "blending", "translucent" },
                                                        { "cullmode", "nocull" },
                                                        { "depthtest", "disabled" },
                                                        { "depthwrite", "disabled" },
                                                        { "shader", "defaulttexture" },
                                                        { "textures", Json::array({ "" }) } } }) } })
                                      .dump());
    world.PutAsset("shaders/defaulttexture.vert", kDefaultedVertex);
    world.PutAsset("shaders/defaulttexture.frag", kDefaultedFragment);
    world.PutAsset("materials/fallback-r8.tex.tex", HeaderOnlyR8Texture());
    world.PutAsset("materials/second-r8.tex.tex", HeaderOnlyR8Texture());

    ASSERT_TRUE(Load(SceneDocument(
        { { { "id", 1 }, { "name", "defaulted image" }, { "image", "image.json" }, { "visible", true } } })));
    auto* node = RootChild(*scene, "defaulted image");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    const auto* material = node->Mesh()->MaterialForSlot(0);
    ASSERT_NE(material, nullptr);
    const std::vector<std::string> expected_slots { "fallback-r8.tex", "second-r8.tex" };
    EXPECT_EQ(material->textures, expected_slots);
    for (const auto& key : expected_slots) EXPECT_TRUE(scene->textures.contains(key)) << key;

    ASSERT_NE(material->customShader.shader, nullptr);
    ASSERT_TRUE(material->customShader.shader->rust_reflection_json.has_value());
    const Json reflection = Json::parse(*material->customShader.shader->rust_reflection_json);
    bool       cascaded   = false;
    bool       stale      = false;
    for (const auto& block : reflection.at("uniform_blocks")) {
        for (const auto& member : block.at("members")) {
            cascaded = cascaded || member.at("name") == "g_CascadedDefaultObserved";
            stale    = stale || member.at("name") == "g_StaleFirstPassMarker";
        }
    }
    EXPECT_TRUE(cascaded) << "the combo of the second default texture was never evaluated";
    EXPECT_FALSE(stale) << "a member of a combo that no longer holds stayed in the layout";
}
