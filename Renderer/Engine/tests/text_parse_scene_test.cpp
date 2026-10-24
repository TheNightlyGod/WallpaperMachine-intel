// What the scene parser builds for a text object: the layer's node, runtime state, card mesh and
// texture; the keys layers are known by; how a font reference resolves; visibility bindings; and
// which keys place the text. Headless: scenes are parsed for their runtime and graph only.

#include "text_fixture.hpp"

#include "Scene/Scene.h"
#include "SpecTexs.hpp"
#include "Text/SystemFontResolver.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace
{
using namespace we_test;
using namespace wallpaper;

constexpr std::string_view kFontBytes = "fake-font-bytes";

std::vector<uint8_t> BytesOf(std::string_view text) { return { text.begin(), text.end() }; }

/// Reads texel alpha of the first mip of slot 0.
struct Raster {
    int            width { 0 };
    int            height { 0 };
    const uint8_t* texels { nullptr };
    [[nodiscard]] uint8_t Alpha(int x, int y) const { return texels[(y * width + x) * 4 + 3]; }
};

Raster RasterOf(const Image& image)
{
    const auto& level = image.slots.front().mipmaps.front();
    return { level.width, level.height, level.data.get() };
}

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

TEST_F(TextParseScene, ALayersCardDrawsRuntimeInkThroughTheTextShader)
{
    ASSERT_TRUE(Load(SceneDocument({ TextObject(1, "caption", "I I") })));
    auto* node = Node("caption");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    const auto* material = node->Mesh()->MaterialForSlot(0);
    ASSERT_NE(material, nullptr);
    EXPECT_EQ(material->name, "text");
    ASSERT_EQ(material->textures.size(), 1u);
    const std::string key = material->textures.front();
    EXPECT_FALSE(key.empty());
    EXPECT_FALSE(IsSpecTex(key));
    EXPECT_TRUE(scene->textures.contains(key));
    EXPECT_EQ(material->blenmode, BlendMode::Translucent);

    const auto image = scene->imageParser->Parse(key);
    ASSERT_NE(image, nullptr);
    ASSERT_EQ(image->slots.size(), 1u);
    ASSERT_EQ(image->slots.front().mipmaps.size(), 1u);
    ASSERT_NE(image->slots.front().mipmaps.front().data, nullptr);
    const Raster raster = RasterOf(*image);
    ASSERT_GT(raster.width, 1);
    ASSERT_GT(raster.height, 1);

    bool ink = false;
    for (int y = 1; y <= raster.height - 2 && !ink; ++y) {
        for (int x = 1; x <= raster.width - 2; ++x) ink = ink || raster.Alpha(x, y) > 0;
    }
    EXPECT_TRUE(ink) << "the card's picture is blank";

    // The gap between the two letters runs clear through the picture.
    bool clear_column = false;
    for (int x = raster.width / 4; x < raster.width * 3 / 4 && !clear_column; ++x) {
        bool column_clear = true;
        for (int y = 1; y <= raster.height - 2; ++y) column_clear = column_clear && raster.Alpha(x, y) == 0;
        clear_column = column_clear;
    }
    EXPECT_TRUE(clear_column) << "no clear column between the letters";

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
    ASSERT_EQ(first->Mesh()->MaterialForSlot(0)->textures.size(), 1u);
    ASSERT_EQ(second->Mesh()->MaterialForSlot(0)->textures.size(), 1u);
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
    const Raster raster = RasterOf(*image);
    bool         soft   = false;
    for (int y = 0; y < raster.height && !soft; ++y) {
        for (int x = 0; x < raster.width; ++x) {
            const uint8_t alpha = raster.Alpha(x, y);
            if (alpha > 0 && alpha < 255) {
                soft = true;
                break;
            }
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
