// What the scene parser builds for a text object: the layer's node, runtime state, card mesh and
// texture; the keys layers are known by; how a font reference resolves; visibility bindings; and
// which keys place the text. Headless: scenes are parsed for their runtime and graph only.

#include "text_fixture.hpp"

#include "Scene/Scene.h"
#include "SpecTexs.hpp"
#include "Text/SystemFontResolver.hpp"
#include "Text/TextGlyphMesh.hpp"
#include "Text/TextLayer.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace
{
using namespace we_test;
using namespace wallpaper;

constexpr std::string_view kFontBytes = "fake-font-bytes";

std::vector<uint8_t> BytesOf(std::string_view text) { return { text.begin(), text.end() }; }

} // namespace

class TextParseScene : public TextSceneTest {};

// ---- A. the layer as parsed --------------------------------------------------------------

TEST_F(TextParseScene, ARightBottomLayerKeepsItsNodeAndMovesOnlyItsCard)
{
    ASSERT_TRUE(Load(SceneDocument({ TextObject(1, "caption", { { "value", "hello" } },
                                                { { "font", { { "value", "Arial" } } },
                                                  { "padding", 4 },
                                                  { "origin", Json::array({ 100, 50, 0 }) },
                                                  { "horizontalalign", "right" },
                                                  { "verticalalign", "bottom" } }) })));
    auto& runtime = Runtime();
    ASSERT_TRUE(runtime.HasNodeNamed("caption"));
    EXPECT_EQ(runtime.NodeText("caption"), "hello");

    // A plain layer (no effect, blend or background) carries no margin: the authored padding of 4
    // would add 8 to each side, so the card is the text alone. Its size is read back from the
    // layout, which the next assertions use to place the card.
    const auto size = runtime.NodeSize("caption");
    EXPECT_GT(size.x(), 8.0f);
    EXPECT_GT(size.y(), 8.0f);
    const auto state = runtime.NodeTextState("caption");
    ASSERT_TRUE(state.has_value());
    EXPECT_EQ(state->padding.x(), 0.0f);
    EXPECT_EQ(state->padding.y(), 0.0f);
    const auto layout = runtime.NodeTextLayout("caption");
    ASSERT_TRUE(layout.has_value());
    EXPECT_NEAR(size.x(), layout->BlockSize().x(), 1e-3f);

    auto* node = Node("caption");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    EXPECT_TRUE(node->Translate().isApprox(linalg::Vector3f(100.0f, 50.0f, 0.0f)));

    const Box box = PositionBox(*node->Mesh());
    EXPECT_NEAR(box.max_x, 0.0f, 1e-3f);
    EXPECT_NEAR(box.min_x, -size.x(), 1e-3f);
    EXPECT_NEAR(box.max_y, layout->top + layout->descender, 1e-3f);
}

TEST_F(TextParseScene, ALayersGlyphsAreDrawnFromItsAtlasThroughTheFontShader)
{
    ASSERT_TRUE(Load(SceneDocument({ TextObject(1, "caption", "I I") })));
    auto* node = Node("caption");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    const auto* material = node->Mesh()->MaterialForSlot(kTextGlyphSubmesh);
    ASSERT_NE(material, nullptr);
    EXPECT_EQ(material->name, "text");
    ASSERT_EQ(material->textures.size(), 1u);
    const std::string key = material->textures.front();
    EXPECT_EQ(key, TextAtlasName("caption"));
    EXPECT_FALSE(IsSpecTex(key));
    EXPECT_TRUE(scene->textures.contains(key));
    EXPECT_EQ(material->blenmode, BlendMode::Translucent);

    // A plain layer's glyphs come from a mono coverage atlas (R8) with ink in it.
    const auto image = scene->imageParser->Parse(key);
    ASSERT_NE(image, nullptr);
    EXPECT_EQ(image->header.format, TextureFormat::R8);
    EXPECT_GT(InkTexels(*image), 0u) << "the atlas is blank";

    // One quad per inked glyph, the space has none: two quads with a clear gap between them.
    const auto& glyphs = node->Mesh()->Submeshes().at(kTextGlyphSubmesh);
    ASSERT_EQ(glyphs.GetIndexArray(0).DrawIndexCount(), 12u);
    const auto&  vertices = glyphs.GetVertexArray(0);
    const auto   stride   = vertices.OneSizeOf() / sizeof(float);
    const float* data     = vertices.Data();
    const float  first_right = std::max(data[2 * stride], data[3 * stride]);
    const float  second_left = std::min(data[4 * stride], data[5 * stride]);
    EXPECT_LT(first_right, second_left) << "no clear gap between the letters";

    const auto& shader = material->customShader.shader;
    ASSERT_NE(shader, nullptr);
    ASSERT_TRUE(shader->rust_reflection_json.has_value());
    const Json reflection = Json::parse(*shader->rust_reflection_json);
    bool       has_mvp    = false;
    for (const auto& block : reflection.at("uniform_blocks")) {
        for (const auto& member : block.at("members")) {
            has_mvp = has_mvp || member.at("name") == "g_ModelViewProjectionMatrix";
        }
    }
    EXPECT_TRUE(has_mvp);
    int texture_binding = -1;
    for (const auto& binding : reflection.at("descriptor_bindings")) {
        if (binding.at("name") == "g_Texture0") {
            EXPECT_EQ(binding.at("descriptor"), "sampled_image");
            texture_binding = binding.at("binding").get<int>();
        }
    }
    ASSERT_GE(texture_binding, 0) << "the shader has no g_Texture0";
    int uniform_buffers = 0;
    int samplers        = 0;
    for (const auto& binding : reflection.at("descriptor_bindings")) {
        const std::string kind = binding.at("descriptor");
        if (kind == "uniform_buffer") ++uniform_buffers;
        if (kind == "sampler") ++samplers;
        if (kind == "uniform_buffer" || kind == "sampler") {
            EXPECT_NE(binding.at("binding").get<int>(), texture_binding) << kind << " shares the texture's slot";
        }
    }
    EXPECT_GE(uniform_buffers, 1);
    EXPECT_GE(samplers, 1);
}

TEST_F(TextParseScene, BothObjectFormsOfTextAndFontReachTheRuntime)
{
    ASSERT_TRUE(Load(SceneDocument({
        TextObject(1, "plain", "plain text", { { "font", "Arial" } }),
        TextObject(2, "nested", { { "text", "nested text" } }, { { "font", { { "value", "Arial" } } } }),
    })));
    EXPECT_EQ(Runtime().NodeText("plain"), "plain text");
    EXPECT_EQ(Runtime().NodeText("nested"), "nested text");
}

TEST_F(TextParseScene, AHiddenLayerStillExistsWithItsText)
{
    ASSERT_TRUE(Load(SceneDocument({ TextObject(1, "hiddenCaption", "secret", { { "visible", false } }) })));
    EXPECT_TRUE(Runtime().HasNodeNamed("hiddenCaption"));
    EXPECT_EQ(Runtime().NodeText("hiddenCaption"), "secret");
    auto* node = Node("hiddenCaption");
    ASSERT_NE(node, nullptr);
    EXPECT_FALSE(node->Visible());
}

// ---- C. keys and hierarchy ---------------------------------------------------------------

TEST_F(TextParseScene, TwoLayersWithOneNameAreKeyedByIdAndGetOwnTextures)
{
    ASSERT_TRUE(Load(SceneDocument({ TextObject(1, "duplicate", "first"),
                                     TextObject(2, "duplicate", "second much wider") })));
    auto* first  = Node("__we_text_1");
    auto* second = Node("__we_text_2");
    ASSERT_NE(first, nullptr);
    ASSERT_NE(second, nullptr);
    ASSERT_NE(first->Mesh(), nullptr);
    ASSERT_NE(second->Mesh(), nullptr);
    ASSERT_EQ(first->Mesh()->MaterialForSlot(kTextGlyphSubmesh)->textures.size(), 1u);
    ASSERT_EQ(second->Mesh()->MaterialForSlot(kTextGlyphSubmesh)->textures.size(), 1u);
    EXPECT_NE(CardTexture(*first), CardTexture(*second));
    EXPECT_TRUE(Runtime().HasNodeNamed("__we_text_1"));
    EXPECT_TRUE(Runtime().HasNodeNamed("__we_text_2"));
    EXPECT_EQ(Runtime().NodeText("__we_text_1"), "first");
    EXPECT_EQ(Runtime().NodeText("__we_text_2"), "second much wider");
}

TEST_F(TextParseScene, AChildListedBeforeItsTextParentIsStillItsChild)
{
    ASSERT_TRUE(Load(SceneDocument({ TextObject(2, "childText", "child", { { "parent", 1 } }),
                                     TextObject(1, "parentText", "parent") })));
    auto* parent = Node("parentText");
    ASSERT_NE(parent, nullptr);
    ASSERT_NE(parent->Mesh(), nullptr);
    ASSERT_EQ(parent->GetChildren().size(), 1u);
    const auto& child = parent->GetChildren().front();
    EXPECT_EQ(child->Name(), "childText");
    EXPECT_EQ(child->Parent(), parent);
}

TEST_F(TextParseScene, AnUnnamedTextParentIsKnownOnlyByItsTextKey)
{
    Json parent = TextObject(1, "", "parent");
    parent.erase("name");
    ASSERT_TRUE(Load(SceneDocument({ TextObject(2, "childText", "child", { { "parent", 1 } }), parent })));
    EXPECT_FALSE(Runtime().HasNodeNamed("__we_layer_1"));
    EXPECT_TRUE(Runtime().HasNodeNamed("__we_text_1"));
    EXPECT_EQ(Runtime().NodeText("__we_text_1"), "parent");
}

// ---- B. fonts at parse time --------------------------------------------------------------

TEST_F(TextParseScene, FontReferencesResolveByWhereTheyPoint)
{
    world.PutAsset("fonts/asset.ttf", kFontBytes);
    world.PutAsset("fonts/prefixed.ttf", kFontBytes);
    world.PutProvided("absolute.otf", kFontBytes);
    ASSERT_TRUE(Load(SceneDocument({
        TextObject(1, "family", "a", { { "font", "Arial" } }),
        TextObject(2, "asset", "a", { { "font", "fonts/asset.ttf" } }),
        TextObject(3, "alias", "a", { { "font", "systemfont_consolas" } }),
        TextObject(4, "absolute", "a", { { "font", "/provided/absolute.otf" } }),
        TextObject(5, "prefixed", "a", { { "font", "assets/fonts/prefixed.ttf" } }),
    })));
    auto& runtime = Runtime();
    const auto family = runtime.NodeTextState("family");
    ASSERT_TRUE(family.has_value());
    EXPECT_EQ(family->font_key, "Arial");
    EXPECT_EQ(family->resolved_font_kind, "system");
    EXPECT_EQ(family->resolved_font_identity, "arial");

    const auto asset = runtime.NodeTextState("asset");
    ASSERT_TRUE(asset.has_value());
    EXPECT_EQ(asset->resolved_font_kind, "asset");
    EXPECT_EQ(asset->resolved_font_path, "/assets/fonts/asset.ttf");
    EXPECT_EQ(asset->resolved_font_data.bytes(), BytesOf(kFontBytes));

    const auto alias = runtime.NodeTextState("alias");
    ASSERT_TRUE(alias.has_value());
    EXPECT_EQ(alias->resolved_font_kind, "system");
    EXPECT_EQ(alias->resolved_font_identity, "consolas");

    const auto absolute = runtime.NodeTextState("absolute");
    ASSERT_TRUE(absolute.has_value());
    EXPECT_EQ(absolute->resolved_font_kind, "asset");
    EXPECT_EQ(absolute->resolved_font_path, "/provided/absolute.otf");
    EXPECT_EQ(absolute->resolved_font_data.bytes(), BytesOf(kFontBytes));

    const auto prefixed = runtime.NodeTextState("prefixed");
    ASSERT_TRUE(prefixed.has_value());
    EXPECT_EQ(prefixed->resolved_font_kind, "asset");
    EXPECT_EQ(prefixed->resolved_font_path, "/assets/fonts/prefixed.ttf");
}

TEST_F(TextParseScene, ASceneFontAliasReachesAnInstalledFontFile)
{
    ASSERT_TRUE(Load(SceneDocument({ TextObject(1, "caption", "a", { { "font", "systemfont_verdana" } }) })));
    const auto state = Runtime().NodeTextState("caption");
    ASSERT_TRUE(state.has_value());
    EXPECT_EQ(state->resolved_font_kind, "system");
    EXPECT_EQ(state->resolved_font_identity, "verdana");
#ifdef __APPLE__
    EXPECT_FALSE(state->resolved_font_path.empty());
#else
    EXPECT_TRUE(state->resolved_font_path.empty());
#endif
}

TEST_F(TextParseScene, ParsedVerdanaTextIsDrawnAntiAliasedIntoACardOfItsMeasuredSize)
{
    ASSERT_TRUE(Load(SceneDocument(
        { TextObject(1, "caption", "Hg", { { "font", "systemfont_verdana" }, { "pointsize", 40 } }) })));
    const auto state = Runtime().NodeTextState("caption");
    ASSERT_TRUE(state.has_value());
    EXPECT_EQ(state->resolved_font_kind, "system");
    EXPECT_EQ(state->resolved_font_identity, "verdana");
#ifdef __APPLE__
    EXPECT_FALSE(state->resolved_font_path.empty());
#endif

    const auto size = Runtime().NodeSize("caption");
    EXPECT_GT(size.x(), 130.0f);
    EXPECT_LT(size.x(), 280.0f);
    EXPECT_GT(size.y(), 120.0f);
    EXPECT_LT(size.y(), 220.0f);

    auto* node = Node("caption");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    EXPECT_EQ(node->Mesh()->GetVertexArray(0).VertexCount(), 4u);
    const Box box = PositionBox(*node->Mesh());
    EXPECT_NEAR(box.W(), size.x(), 1.0f);
    EXPECT_NEAR(box.H(), size.y(), 1.0f);

    const auto image = scene->imageParser->Parse(CardTexture(*node));
    ASSERT_NE(image, nullptr);
    ASSERT_EQ(image->slots.size(), 1u);
    ASSERT_EQ(image->slots.front().mipmaps.size(), 1u);
    ASSERT_NE(image->slots.front().mipmaps.front().data, nullptr);
    // The mono atlas holds one coverage byte a texel (R8).
    ASSERT_EQ(image->header.format, TextureFormat::R8);
    const auto& level = image->slots.front().mipmaps.front();
    bool        soft  = false;
    for (i32 at = 0; at < level.width * level.height; ++at) {
        const uint8_t coverage = level.data.get()[at];
        if (coverage > 0 && coverage < 255) {
            soft = true;
            break;
        }
    }
    EXPECT_TRUE(soft) << "no anti-aliased edge texel";
}

TEST(TextLayerStateCopies, ShareTheFontBytesInsteadOfCopyingThem)
{
    TextLayerState state;
    state.text               = "fps: 60";
    state.resolved_font_data = std::vector<uint8_t>(1024, 42);
    const TextLayerState copy = state;
    ASSERT_FALSE(state.resolved_font_data.empty());
    ASSERT_FALSE(copy.resolved_font_data.empty());
    EXPECT_EQ(copy.resolved_font_data.data(), state.resolved_font_data.data());
}

// ---- D. visibility bindings --------------------------------------------------------------

TEST_F(TextParseScene, AVisibilityScriptHidesTheLayerOnTheNextTick)
{
    ASSERT_TRUE(Load(SceneDocument({ TextObject(
        1, "caption", "shown",
        { { "visible", { { "value", true }, { "script", UpdateReturning("false") } } } }) })));
    Runtime().Tick(kFrame);
    auto* node = Node("caption");
    ASSERT_NE(node, nullptr);
    EXPECT_FALSE(node->Visible());
    EXPECT_EQ(Runtime().scriptErrorCount(), 0u);
}

TEST_F(TextParseScene, AUserPropertyVisibilityFollowsTheProjectOverride)
{
    ProjectProperties properties { { "show_text", RuntimeScalarValue::Bool(true) } };
    ASSERT_TRUE(Load(SceneDocument({ TextObject(
                         1, "caption", "shown",
                         { { "visible", { { "value", true }, { "user", "show_text" } } } }) }),
                     properties));
    auto* node = Node("caption");
    ASSERT_NE(node, nullptr);
    EXPECT_TRUE(node->Visible());
    Runtime().ApplyProjectPropertyOverride({ { "show_text", RuntimeScalarValue::Bool(false) } });
    Runtime().Tick(kFrame);
    EXPECT_FALSE(node->Visible());
}

// ---- E. only horizontalalign / verticalalign place the text ------------------------------

TEST_F(TextParseScene, AStrayAlignmentKeyDoesNotPlaceTextAcrossTheOrigin)
{
    const Json common = { { "pointsize", 10 }, { "origin", Json::array({ 100, 50, 0 }) }, { "alignment", "left" } };
    Json       aligned = common;
    aligned["horizontalalign"] = "right";
    ASSERT_TRUE(Load(SceneDocument({ TextObject(1, "stray", "aaaa", common),
                                     TextObject(2, "right", "aaaa", aligned) })));
    auto* stray = Node("stray");
    auto* right = Node("right");
    ASSERT_NE(stray, nullptr);
    ASSERT_NE(right, nullptr);
    ASSERT_NE(stray->Mesh(), nullptr);
    ASSERT_NE(right->Mesh(), nullptr);
    EXPECT_TRUE(stray->Translate().isApprox(linalg::Vector3f(100.0f, 50.0f, 0.0f)));
    EXPECT_TRUE(right->Translate().isApprox(linalg::Vector3f(100.0f, 50.0f, 0.0f)));

    const Box stray_box = PositionBox(*stray->Mesh());
    EXPECT_NEAR(stray_box.CX(), 0.0f, 1e-3f);
    const auto state = Runtime().NodeTextState("stray");
    ASSERT_TRUE(state.has_value());
    EXPECT_EQ(state->horizontal_align, "center");

    const Box right_box = PositionBox(*right->Mesh());
    EXPECT_NEAR(right_box.max_x, 0.0f, 1e-3f);
    EXPECT_LT(right_box.CX(), -1.0f);
}

TEST_F(TextParseScene, AStrayAlignmentKeyDoesNotPlaceTextAboveTheOrigin)
{
    const Json common = { { "pointsize", 10 }, { "origin", Json::array({ 100, 50, 0 }) }, { "alignment", "top" } };
    Json       aligned = common;
    aligned["verticalalign"] = "bottom";
    ASSERT_TRUE(Load(SceneDocument({ TextObject(1, "stray", "aaaa", common),
                                     TextObject(2, "bottom", "aaaa", aligned) })));
    auto* stray  = Node("stray");
    auto* bottom = Node("bottom");
    ASSERT_NE(stray, nullptr);
    ASSERT_NE(bottom, nullptr);
    ASSERT_NE(stray->Mesh(), nullptr);
    ASSERT_NE(bottom->Mesh(), nullptr);
    EXPECT_TRUE(stray->Translate().isApprox(linalg::Vector3f(100.0f, 50.0f, 0.0f)));
    EXPECT_TRUE(bottom->Translate().isApprox(linalg::Vector3f(100.0f, 50.0f, 0.0f)));

    const Box stray_box  = PositionBox(*stray->Mesh());
    const Box bottom_box = PositionBox(*bottom->Mesh());
    EXPECT_GT(bottom_box.CY(), stray_box.CY() + 1.0f);
    EXPECT_NEAR(stray_box.CX(), 0.0f, 1e-3f);
    EXPECT_NEAR(bottom_box.CX(), 0.0f, 1e-3f);
    const auto state = Runtime().NodeTextState("stray");
    ASSERT_TRUE(state.has_value());
    EXPECT_EQ(state->vertical_align, "center");
}

// ---- G. font materials, depth, perspective, fog, the wallpaper's emoji face (Appendix G) ------

namespace
{
/// The slot of a text node's mesh, by submesh index.
const SceneMaterial* SlotMaterial(SceneNode& node, std::size_t slot)
{
    return node.Mesh() == nullptr ? nullptr : node.Mesh()->MaterialForSlot(slot);
}

/// Whether the compiled program reads `uniform`: the combos a material is built with show in
/// which uniforms its program reads (the stand-in font shader declares `g_RenderVar0` only for a
/// distance field, `g_RenderVar1` for an outline or shadow, `g_RenderVar3` for a drop shadow).
bool Reads(const SceneMaterial& material, const std::string& uniform)
{
    const auto& shader = material.customShader.shader;
    if (shader == nullptr || ! shader->rust_reflection_json.has_value()) return false;
    return shader->rust_reflection_json->find("\"" + uniform + "\"") != std::string::npos;
}

Json PerspectiveDocument(std::vector<Json> objects)
{
    Json document = SceneDocument(std::move(objects));
    document["general"]["orthogonalprojection"] = nullptr;
    document["camera"] = { { "center", "0 0 0" }, { "eye", "0 0 10" }, { "up", "0 1 0" } };
    return document;
}
} // namespace

TEST_F(TextParseScene, DepthtestSelectsTheDepthFontMaterialsInAPerspectiveScene)
{
    // `depthtest` is a word, `enabled` unless the layer says `disabled`; the `_depth` font
    // materials are taken in a perspective scene only (decompiles/G-F10.md).
    ASSERT_TRUE(Load(PerspectiveDocument({ TextObject(1, "tested", "a", { { "origin", "0 0 -50" } }),
                                           TextObject(2, "untested", "a",
                                                      { { "origin", "0 0 -50" }, { "depthtest", "disabled" } }) })));
    for (const auto& [name, depth] : { std::pair { "tested", true }, std::pair { "untested", false } }) {
        SCOPED_TRACE(name);
        auto* node = Node(name);
        ASSERT_NE(node, nullptr);
        for (const std::size_t slot : { kTextGlyphSubmesh, kTextColorGlyphSubmesh }) {
            const auto* material = SlotMaterial(*node, slot);
            ASSERT_NE(material, nullptr);
            EXPECT_EQ(material->depth_test, depth);
            EXPECT_EQ(material->depth_write, depth);
        }
    }
}

TEST_F(TextParseScene, AnOrthoSceneNeverDepthTestsItsText)
{
    ASSERT_TRUE(Load(SceneDocument({ TextObject(1, "caption", "a", { { "depthtest", "enabled" } }) })));
    auto* node = Node("caption");
    ASSERT_NE(node, nullptr);
    const auto* material = SlotMaterial(*node, kTextGlyphSubmesh);
    ASSERT_NE(material, nullptr);
    EXPECT_FALSE(material->depth_test);
    EXPECT_FALSE(material->depth_write);
}

TEST_F(TextParseScene, APerspectiveTextLayerIsSeenThroughThePerspectiveCamera)
{
    ASSERT_TRUE(Load(SceneDocument({ TextObject(1, "flat", "a"),
                                     TextObject(2, "turned", "a", { { "perspective", true } }) })));
    ASSERT_NE(Node("flat"), nullptr);
    ASSERT_NE(Node("turned"), nullptr);
    EXPECT_EQ(Node("flat")->Camera(), "");
    EXPECT_EQ(Node("turned")->Camera(), "global_perspective");
}

TEST_F(TextParseScene, GlyphsDrawWithTheFontMaterialsAndTheirStyleCombos)
{
    // Mono glyphs: `basefont`; colour glyphs: `basefontrgba` (COLORFONT); a distance field when the
    // layer asks for `msdf` or any style (decompiles/G-F4.md), with the style's combos and the
    // render variables of `TextStyleRenderVars` (range 24, decompiles/G-F5.md).
    ASSERT_TRUE(Load(SceneDocument({ TextObject(1, "plain", "a"),
                                     TextObject(2, "styled", "a",
                                                { { "outline", true }, { "outlinethickness", 2 },
                                                  { "dropshadow", true }, { "dropshadowsize", 1 } }),
                                     TextObject(3, "outlined", "a", { { "outline", true } }) })));
    auto* plain  = Node("plain");
    auto* styled = Node("styled");
    ASSERT_NE(plain, nullptr);
    ASSERT_NE(styled, nullptr);
    const auto* mono   = SlotMaterial(*plain, kTextGlyphSubmesh);
    const auto* colour = SlotMaterial(*plain, kTextColorGlyphSubmesh);
    const auto* msdf   = SlotMaterial(*styled, kTextGlyphSubmesh);
    ASSERT_NE(mono, nullptr);
    ASSERT_NE(colour, nullptr);
    ASSERT_NE(msdf, nullptr);
    EXPECT_FALSE(Reads(*mono, "g_RenderVar0"));
    EXPECT_EQ(mono->textures.front(), TextAtlasName("plain"));
    EXPECT_EQ(colour->textures.front(), TextColorAtlasName("plain"));
    EXPECT_TRUE(Reads(*msdf, "g_RenderVar0"));
    EXPECT_TRUE(Reads(*msdf, "g_RenderVar3")) << "no drop shadow";
    ASSERT_NE(Node("outlined"), nullptr);
    const auto* outlined = SlotMaterial(*Node("outlined"), kTextGlyphSubmesh);
    ASSERT_NE(outlined, nullptr);
    EXPECT_TRUE(Reads(*outlined, "g_RenderVar1")) << "no outline";
    EXPECT_FALSE(Reads(*outlined, "g_RenderVar3")) << "a drop shadow nobody asked for";
    const auto rv0 = msdf->customShader.constValues.find("g_RenderVar0");
    ASSERT_NE(rv0, msdf->customShader.constValues.end());
    EXPECT_FLOAT_EQ(rv0->second[0], 24.0f);
    EXPECT_EQ(msdf->blenmode, BlendMode::Translucent);
}

TEST_F(TextParseScene, EveryTextLayerOfAFoggedSceneEndsInTheFogPass)
{
    // In a fogged scene a text layer is a composite whose chain ends in the fogging passthrough,
    // as an image layer's does (the WE probe probetext-fog); the glyph passes stay unfogged.
    world.PutAsset("materials/util/effectpassthrough_4.json",
                   R"({"passes":[{"shader":"fog_through","blending":"normal","cullmode":"nocull",)"
                   R"("depthtest":"disabled","depthwrite":"disabled","textures":[null]}]})");
    world.PutAsset("shaders/fog_through.vert",
                   "uniform mat4 g_ModelViewProjectionMatrix;\nattribute vec3 a_Position;\n"
                   "attribute vec2 a_TexCoord;\nvarying vec2 v_TexCoord;\nvoid main() {\n"
                   "  gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);\n"
                   "  v_TexCoord = a_TexCoord;\n}\n");
    world.PutAsset("shaders/fog_through.frag",
                   "// [COMBO] {\"material\":\"fog\",\"combo\":\"FOG\",\"default\":1}\n"
                   "uniform sampler2D g_Texture0;\n#if FOG_DIST\nuniform vec4 g_FogDistanceParams;\n#endif\n"
                   "varying vec2 v_TexCoord;\nvoid main() {\n"
                   "  gl_FragColor = texSample2D(g_Texture0, v_TexCoord);\n"
                   "#if FOG_COMPUTED && FOG_DIST\n  gl_FragColor.rgb *= g_FogDistanceParams.xyz;\n#endif\n}\n");
    Json document = SceneDocument({ TextObject(1, "caption", "a") });
    document["general"]["fogdistance"]      = true;
    document["general"]["fogdistancestart"] = 0;
    document["general"]["fogdistanceend"]   = 100;
    ASSERT_TRUE(Load(document));
    auto* node = Node("caption");
    ASSERT_NE(node, nullptr);
    const auto camera = scene->cameras.find(node->Camera());
    ASSERT_NE(camera, scene->cameras.end()) << "the layer is not drawn through a chain";
    ASSERT_TRUE(camera->second->HasImgEffect());
    auto& chain = *camera->second->GetImgEffect();
    ASSERT_GE(chain.EffectCount(), 1u);
    const auto& last = chain.GetEffect(chain.EffectCount() - 1);
    ASSERT_NE(last, nullptr);
    ASSERT_FALSE(last->nodes.empty());
    const auto* pass = last->nodes.back().sceneNode->Mesh()->Material();
    ASSERT_NE(pass, nullptr);
    EXPECT_TRUE(Reads(*pass, "g_FogDistanceParams")) << "the last pass is not the fogging passthrough";
    const auto* glyphs = SlotMaterial(*node, kTextGlyphSubmesh);
    ASSERT_NE(glyphs, nullptr);
    EXPECT_FALSE(Reads(*glyphs, "g_FogDistanceParams")) << "a glyph pass was fogged";
}

TEST_F(TextParseScene, TheAssetsTwemojiIsReadOnceAndSharedByEveryLayer)
{
    // The wallpaper assets' Twemoji is a face of Wallpaper Engine's glyph fallback list
    // (`sub_1401AD670`): read once per scene, shared by every layer without a copy.
    world.PutAsset("fonts/TwemojiMozilla.ttf", "twemoji-stand-in");
    ASSERT_TRUE(Load(SceneDocument({ TextObject(1, "first", "a"), TextObject(2, "second", "b") })));
    const auto first  = Runtime().NodeTextState("first");
    const auto second = Runtime().NodeTextState("second");
    ASSERT_TRUE(first.has_value());
    ASSERT_TRUE(second.has_value());
    ASSERT_EQ(first->asset_emoji_font.size(), std::string_view("twemoji-stand-in").size());
    EXPECT_EQ(first->asset_emoji_font.data(), second->asset_emoji_font.data());
}
