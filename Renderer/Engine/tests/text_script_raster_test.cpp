// Scripts on text layers, the position and scale a text layer is driven to, the FreeType raster of
// a layer, and a synthetic clock-like scene (a script-built time text with two children) built the
// way a typical clock wallpaper is, without any wallpaper's files.
// Headless: scenes are parsed for their runtime and graph only.

#include "text_fixture.hpp"

#include "RenderCommon/ScenePass.hpp"
#include "RenderCommon/SceneToRenderGraph.hpp"
#include "RenderGraph/RenderGraph.hpp"
#include "SpecTexs.hpp"
#include "Text/SystemFontResolver.hpp"

#include <algorithm>
#include <cmath>

namespace
{
using namespace we_test;
using namespace wallpaper;

const std::string kNulText(1, '\0');

// ---- raster helpers ----------------------------------------------------------------------

struct InkBox {
    bool found { false };
    int  min_x { 0 }, max_x { 0 }, min_y { 0 }, max_y { 0 };
    [[nodiscard]] int Width() const { return max_x - min_x + 1; }
    [[nodiscard]] int Height() const { return max_y - min_y + 1; }
};

InkBox InkOf(const std::vector<uint8_t>& rgba, int width, int height)
{
    InkBox box;
    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            if (rgba[(static_cast<std::size_t>(y) * width + x) * 4 + 3] == 0) continue;
            if (!box.found) {
                box = { true, x, x, y, y };
                continue;
            }
            box.min_x = std::min(box.min_x, x);
            box.max_x = std::max(box.max_x, x);
            box.min_y = std::min(box.min_y, y);
            box.max_y = std::max(box.max_y, y);
        }
    }
    return box;
}

TextLayerState HelveticaState(const std::string& text, float point_size, float padding)
{
    TextLayerState state;
    state.text                   = text;
    state.font_key               = "systemfont_Helvetica";
    state.resolved_font_kind     = "system";
    state.resolved_font_identity = "Helvetica";
    state.resolved_font_path     = ResolveInstalledFamily("Helvetica").path;
    state.point_size             = point_size;
    state.padding                = linalg::Vector2f(padding, padding);
    state.authored_padding       = state.padding;
    return state;
}

/// Rasterises into a buffer sized by the layer's own estimate (rounded up).
std::vector<uint8_t> RasterAtEstimate(const TextLayerState& state, int* width = nullptr, int* height = nullptr)
{
    const auto size = TextLayerRasterSize(state);
    const int  w    = static_cast<int>(std::ceil(size.x()));
    const int  h    = static_cast<int>(std::ceil(size.y()));
    std::vector<uint8_t> rgba(static_cast<std::size_t>(w) * h * 4, 0);
    RasterizeTextLayer(state, w, h, rgba);
    if (width != nullptr) *width = w;
    if (height != nullptr) *height = h;
    return rgba;
}

} // namespace

class TextScripts : public TextSceneTest {};

// ---- K. scripts on text layers -----------------------------------------------------------

TEST_F(TextScripts, TextScriptsWaitForTheTickBeforeReadingSharedState)
{
    ASSERT_TRUE(Load(SceneDocument({
        [] {
            Json producer = GroupObject(1, "producer");
            producer["visible"] = { { "value", true },
                                    { "script", "export function update(value) {"
                                                " shared.number = (shared.number || 6) + 1; return true; }" } };
            return producer;
        }(),
        TextObject(2, "caption",
                   { { "value", "waiting" },
                     { "script", UpdateReturning("shared.number.toFixed(1)") } }),
    })));
    EXPECT_EQ(Runtime().scriptErrorCount(), 0u) << "the text script ran while loading, before the producer";
    Runtime().Tick(kFrame);
    EXPECT_EQ(Runtime().NodeText("caption"), "7.0");
    Runtime().Tick(kFrame);
    EXPECT_EQ(Runtime().NodeText("caption"), "8.0");
    EXPECT_EQ(Runtime().scriptErrorCount(), 0u);
}

TEST_F(TextScripts, ARuntimeTextWriteSurvivesATickWhenTheObjectFormHasNoScript)
{
    ASSERT_TRUE(Load(SceneDocument({ TextObject(1, "caption", { { "text", "before" } }) })));
    EXPECT_EQ(Runtime().NodeText("caption"), "before");
    ASSERT_TRUE(Runtime().SetNodeText("caption", "after"));
    Runtime().Tick(kFrame);
    EXPECT_EQ(Runtime().NodeText("caption"), "after");
    EXPECT_EQ(Runtime().scriptErrorCount(), 0u);
}

TEST_F(TextScripts, AnEventOnlyScriptDoesNotOverwriteARuntimeWrite)
{
    ASSERT_TRUE(Load(SceneDocument({ TextObject(
        1, "caption",
        { { "value", "before" }, { "script", "engine.on('custom', function() { });" } }) })));
    EXPECT_EQ(Runtime().NodeText("caption"), "before");
    ASSERT_TRUE(Runtime().SetNodeText("caption", "after"));
    Runtime().Tick(kFrame);
    EXPECT_EQ(Runtime().NodeText("caption"), "after");
    EXPECT_EQ(Runtime().scriptErrorCount(), 0u);
}

TEST_F(TextScripts, AnEventOnlyScriptIsASceneScriptThatWritesThroughItsLayer)
{
    ASSERT_TRUE(Load(SceneDocument({ TextObject(
        1, "caption",
        { { "value", "before" },
          { "script", "engine.on('cursorDown', function() { thisLayer.text = 'clicked'; });" } }) })));
    EXPECT_EQ(Runtime().NodeText("caption"), "before");
    EXPECT_EQ(Runtime().sceneScriptCount(), 1u);
    Runtime().DispatchCursorDown(0);
    EXPECT_EQ(Runtime().NodeText("caption"), "clicked");
    EXPECT_EQ(Runtime().scriptErrorCount(), 0u);
}

// ---- L. dynamic position and scale -------------------------------------------------------

TEST_F(TextScripts, UserPropertyOriginAndScaleFollowOverrides)
{
    ProjectProperties properties { { "text_origin", RuntimeScalarValue::String("30 40 0") },
                                   { "text_scale", RuntimeScalarValue::Float(2.5f) } };
    ASSERT_TRUE(Load(SceneDocument({ TextObject(
                         1, "caption", "clock",
                         { { "origin", { { "value", "10 20 0" }, { "user", "text_origin" } } },
                           { "scale", { { "value", "1 1 1" }, { "user", "text_scale" } } } }) }),
                     properties));
    auto* node = Node("caption");
    ASSERT_NE(node, nullptr);
    EXPECT_EQ(node->Translate().x(), 30.0f);
    EXPECT_EQ(node->Translate().y(), 40.0f);
    EXPECT_EQ(node->Scale().x(), 2.5f);
    EXPECT_EQ(node->Scale().y(), 2.5f);

    Runtime().ApplyProjectPropertyOverride({ { "text_origin", RuntimeScalarValue::String("50 60 0") },
                                             { "text_scale", RuntimeScalarValue::Float(3.0f) } });
    Runtime().Tick(kFrame);
    EXPECT_EQ(node->Translate().x(), 50.0f);
    EXPECT_EQ(node->Translate().y(), 60.0f);
    EXPECT_EQ(node->Scale().x(), 3.0f);
    EXPECT_EQ(node->Scale().y(), 3.0f);
}

namespace
{
/// An origin script that places the layer at a fraction of the canvas, the fractions being
/// script properties.
Json CanvasFractionOrigin()
{
    const std::string source =
        "export var scriptProperties = createScriptProperties()\n"
        "  .addSlider({ name: 'x', label: 'x', value: 0.5, min: 0, max: 1 })\n"
        "  .addSlider({ name: 'y', label: 'y', value: 0.5, min: 0, max: 1 })\n"
        "  .finish();\n"
        "export function update(value) {\n"
        "  value.x = scriptProperties.x * engine.canvasSize.x;\n"
        "  value.y = scriptProperties.y * engine.canvasSize.y;\n"
        "  return value;\n"
        "}\n";
    return { { "value", "0 0 0" },
             { "script", source },
             { "scriptproperties",
               { { "x", { { "user", "x" }, { "value", 0.5 } } }, { "y", { { "user", "y" }, { "value", 0.5 } } } } } };
}
} // namespace

TEST_F(TextScripts, AScriptReadsTheCanvasSizeToPlaceATextLayer)
{
    ProjectProperties properties { { "x", RuntimeScalarValue::Float(0.8f) },
                                   { "y", RuntimeScalarValue::Float(0.25f) } };
    ASSERT_TRUE(Load(SceneDocument({ TextObject(1, "caption", "clock", { { "origin", CanvasFractionOrigin() } }) },
                                   1000, 500),
                     properties));
    Runtime().Tick(kFrame);
    auto* node = Node("caption");
    ASSERT_NE(node, nullptr);
    EXPECT_EQ(node->Translate().x(), 800.0f);
    EXPECT_EQ(node->Translate().y(), 125.0f);
    EXPECT_EQ(Runtime().scriptErrorCount(), 0u);
}

// ---- M. FreeType raster ------------------------------------------------------------------

class TextRaster : public ::testing::Test {};

#ifdef __APPLE__
#define REQUIRE_HELVETICA(state) ASSERT_FALSE((state).resolved_font_path.empty())
#else
#define REQUIRE_HELVETICA(state) (void)(state)
#endif

TEST_F(TextRaster, GlyphsAreSetAtTheFontsPixelSizeAndAntiAliased)
{
    const TextLayerState state = HelveticaState("Hg", 40.0f, 4.0f);
    REQUIRE_HELVETICA(state);
#ifdef __APPLE__
    const int            w = 420, h = 220;
    std::vector<uint8_t> rgba(static_cast<std::size_t>(w) * h * 4, 0);
    RasterizeTextLayer(state, w, h, rgba);
    const InkBox ink = InkOf(rgba, w, h);
    ASSERT_TRUE(ink.found);
    EXPECT_GT(ink.Height(), 110) << "40 pt at 300 dpi is about 167 pixels per em";
    bool soft = false;
    for (std::size_t at = 3; at < rgba.size() && !soft; at += 4) soft = rgba[at] > 0 && rgba[at] < 255;
    EXPECT_TRUE(soft) << "no anti-aliased texel";
#endif
}

TEST_F(TextRaster, TheEstimatedSizeContainsTallAndDescendingGlyphs)
{
    const TextLayerState state = HelveticaState("Hg", 40.0f, 4.0f);
    REQUIRE_HELVETICA(state);
#ifdef __APPLE__
    const auto size = TextLayerRasterSize(state);
    EXPECT_GT(size.x(), 130.0f);
    EXPECT_LT(size.x(), 280.0f);
    EXPECT_GT(size.y(), 120.0f);
    EXPECT_LT(size.y(), 220.0f);
    int w = 0, h = 0;
    const auto rgba = RasterAtEstimate(state, &w, &h);
    EXPECT_TRUE(InkOf(rgba, w, h).found);
#endif
}

TEST_F(TextRaster, CentredTextIsCentredInItsCard)
{
    TextLayerState state = HelveticaState("Saturday", 20.0f, 32.0f);
    state.horizontal_align = "center";
    state.vertical_align   = "center";
    REQUIRE_HELVETICA(state);
#ifdef __APPLE__
    const auto size = TextLayerRasterSize(state);
    EXPECT_TRUE(size.isApprox(MeasureTextLayerSize(state)));
    int w = 0, h = 0;
    const auto rgba = RasterAtEstimate(state, &w, &h);
    const InkBox ink = InkOf(rgba, w, h);
    ASSERT_TRUE(ink.found);
    EXPECT_NEAR((ink.min_x + ink.max_x) / 2.0, w / 2.0, 4.0);
    EXPECT_GE(ink.min_x, 32);
    EXPECT_LE(ink.max_x, w - 32);
#endif
}

TEST_F(TextRaster, AGlyphThePrimaryFaceLacksIsDrawnFromAFallbackFace)
{
#ifdef __APPLE__
    const TextLayerState han = HelveticaState("\xE4\xB8\xAD", 40.0f, 4.0f);
    REQUIRE_HELVETICA(han);
    const auto size = TextLayerRasterSize(han);
    EXPECT_GT(size.x(), 40.0f);
    EXPECT_GT(size.y(), 40.0f);
    int w = 0, h = 0;
    const auto drawn = RasterAtEstimate(han, &w, &h);
    const InkBox ink = InkOf(drawn, w, h);
    ASSERT_TRUE(ink.found);
    EXPECT_GT(ink.Width(), 20);
    EXPECT_GT(ink.Height(), 20);

    const TextLayerState unassigned = HelveticaState("\xF4\x8F\xBF\xBF", 40.0f, 4.0f);
    const auto           other      = RasterAtEstimate(unassigned);
    EXPECT_NE(drawn, other) << "an unmapped code point drew the same picture as a real character";
#endif
}

// ---- N. a clock-like scene ---------------------------------------------------------------

namespace
{
const char kClockScript[] =
    "var props = createScriptProperties()\n"
    "  .addText({ name: 'delimiter', value: ':' })\n"
    "  .addCheckbox({ name: 'showCD', value: false })\n"
    "  .addCheckbox({ name: 'showTime', value: false })\n"
    "  .addCheckbox({ name: 'use12hFormat', value: false })\n"
    "  .finish();\n"
    "function two(n) { return (n < 10 ? '0' : '') + n; }\n"
    "export function update(value) {\n"
    "  if (props.showTime || props.showCD) return '\\0';\n"
    "  var now = new Date();\n"
    "  var hours = now.getHours();\n"
    "  if (props.use12hFormat) hours = hours % 12 === 0 ? 12 : hours % 12;\n"
    "  return two(hours) + props.delimiter + two(now.getMinutes());\n"
    "}\n";

Json ClockScene()
{
    Json clock = TextObject(
        31, "Clock", { { "value", "06:15" },
                       { "script", kClockScript },
                       { "scriptproperties",
                         { { "delimiter", ":" },
                           { "showCD", false },
                           { "showTime", false },
                           { "use12hFormat", { { "user", "show12h" }, { "value", false } } } } } },
        { { "font", "systemfont_sansserif" },
          { "pointsize", 33 },
          { "padding", 32 },
          { "size", "342 156" },
          { "origin", CanvasFractionOrigin() },
          { "scale", { { "user", "newproperty2" }, { "value", "2.5 2.5 2.5" } } },
          { "visible", { { "user", "clock" }, { "value", true } } },
          { "color", { { "user", "newproperty1" }, { "value", "1.0 0.81176 0.87059" } } },
          { "horizontalalign", "center" },
          { "verticalalign", "center" },
          { "anchor", "none" } });
    Json date = TextObject(32, "Date", "DATE",
                           { { "font", "systemfont_sansserif" },
                             { "pointsize", 20 },
                             { "padding", 36 },
                             { "size", "987 125" },
                             { "origin", "283.14212 -113.36209 0" },
                             { "scale", "0.28 0.28 0" },
                             { "parent", 31 },
                             { "visible", { { "user", "time" }, { "value", true } } },
                             { "horizontalalign", "right" },
                             { "verticalalign", "center" },
                             { "anchor", "none" } });
    Json day = TextObject(33, "Dy", "PM",
                          { { "font", "systemfont_sansserif" },
                            { "pointsize", 32 },
                            { "padding", 32 },
                            { "size", "190 200" },
                            { "origin", "230.29727 -31.03779 0" },
                            { "scale", "0.61854 0.56577 0.43846" },
                            { "parent", 31 },
                            { "horizontalalign", "center" },
                            { "verticalalign", "center" },
                            { "anchor", "none" } });
    Json document             = SceneDocument({ clock, date, day }, 3840, 2160);
    document["camera"]        = { { "center", "0 0 -1" }, { "eye", "0 0 0" }, { "up", "0 1 0" } };
    document["general"]["clearenabled"] = true;
    return document;
}

ProjectProperties ClockProperties()
{
    return { { "clock", RuntimeScalarValue::Bool(true) },
             { "time", RuntimeScalarValue::Bool(true) },
             { "x", RuntimeScalarValue::Float(0.8f) },
             { "y", RuntimeScalarValue::Float(0.25f) },
             { "newproperty1", RuntimeScalarValue::String("1 0.8117647 0.8705882") },
             { "newproperty2", RuntimeScalarValue::Float(2.5f) } };
}
} // namespace

class TextClockScene : public TextSceneTest {};

TEST_F(TextClockScene, TheParentClockKeepsAVisibleRuntimeTexture)
{
    ASSERT_TRUE(Load(ClockScene(), ClockProperties()));
    auto* clock = Node("Clock");
    ASSERT_NE(clock, nullptr);
    ASSERT_NE(clock->Mesh(), nullptr);
    ASSERT_EQ(clock->GetChildren().size(), 2u);
    EXPECT_EQ(clock->GetChildren().front()->Name(), "Date");
    EXPECT_EQ(clock->GetChildren().back()->Name(), "Dy");

    Runtime().Tick(kFrame);
    ASSERT_TRUE(PumpUntilClean(Runtime(), { "Clock", "Date", "Dy" }));

    EXPECT_TRUE(Runtime().NodeVisible("Clock"));
    EXPECT_TRUE(clock->EffectiveVisible());
    EXPECT_NE(Runtime().NodeText("Clock"), kNulText);
    EXPECT_EQ(Runtime().scriptErrorCount(), 0u);
    const auto translate = Runtime().NodeTranslate("Clock");
    EXPECT_NEAR(translate.x(), 0.8 * 3840, 1e-3);
    EXPECT_NEAR(translate.y(), 0.25 * 2160, 1e-3);
    const auto scale = Runtime().NodeScale("Clock");
    EXPECT_NEAR(scale.x(), 2.5, 1e-3);
    EXPECT_NEAR(scale.y(), 2.5, 1e-3);

    const auto state = Runtime().NodeTextState("Clock");
    ASSERT_TRUE(state.has_value());
    EXPECT_EQ(state->resolved_font_kind, "system");
#ifdef __APPLE__
    EXPECT_FALSE(state->resolved_font_path.empty());
#endif

    const auto* material = clock->Mesh()->MaterialForSlot(0);
    ASSERT_NE(material, nullptr);
    ASSERT_EQ(material->textures.size(), 1u);
    const auto image = scene->imageParser->Parse(material->textures.front());
    ASSERT_NE(image, nullptr);
    const auto size = MeasureTextLayerSize(*state);
    EXPECT_EQ(image->header.width, static_cast<int>(std::ceil(size.x())));
    EXPECT_EQ(image->header.height, static_cast<int>(std::ceil(size.y())));
    EXPECT_GT(image->header.width, 100);
    EXPECT_GT(InkTexels(*image), 200u);

    Runtime().ClearNodeTextDirty("Clock");
    ResetTextLayerMeasurementCountForTests();
    Runtime().Tick(kFrame);
    EXPECT_EQ(TextLayerMeasurementCountForTests(), 0u) << "an idle tick measured text";
}

TEST_F(TextClockScene, TheRenderGraphDrawsTheClockWithItsRuntimeTexture)
{
    ASSERT_TRUE(Load(ClockScene(), ClockProperties()));
    Runtime().Tick(kFrame);
    Runtime().PumpTextLayerCache();
    auto* clock = Node("Clock");
    ASSERT_NE(clock, nullptr);
    ASSERT_NE(clock->Mesh(), nullptr);

    EXPECT_TRUE(Runtime().NodeVisible("Clock"));
    EXPECT_TRUE(clock->EffectiveVisible());
    EXPECT_NE(Runtime().NodeText("Clock"), kNulText);
    EXPECT_EQ(Runtime().scriptErrorCount(), 0u);
    const auto* material = clock->Mesh()->MaterialForSlot(0);
    ASSERT_NE(material, nullptr);
    ASSERT_EQ(material->textures.size(), 1u);
    EXPECT_EQ(material->textures.front(), TextTextureName("Clock"));
    EXPECT_EQ(TextTextureName("Clock"), "runtime/text/Clock");
    const auto image = scene->imageParser->Parse(material->textures.front());
    ASSERT_NE(image, nullptr);
    EXPECT_GT(InkTexels(*image), 200u);

    const auto graph = sceneToRenderGraph(*scene);
    ASSERT_NE(graph, nullptr);
    const rg::DrawPass* draw = nullptr;
    for (const auto id : graph->topologicalOrder()) {
        const auto* pass = dynamic_cast<const rg::DrawPass*>(graph->getPass(id));
        if (pass != nullptr && pass->desc().node == clock) draw = pass;
    }
    ASSERT_NE(draw, nullptr) << "the clock is not drawn by any pass";
    ASSERT_EQ(draw->desc().textures.size(), 1u);
    EXPECT_EQ(draw->desc().textures.front(), TextTextureName("Clock"));
    EXPECT_EQ(draw->desc().visibility_node, clock);
    EXPECT_EQ(draw->desc().output, SpecTex_Default);

    Runtime().ClearNodeTextDirty("Clock");
    ResetTextLayerMeasurementCountForTests();
    Runtime().Tick(kFrame);
    EXPECT_EQ(TextLayerMeasurementCountForTests(), 0u);
}

// ---- O. headless run of a script-driven text scene ---------------------------------------

TEST_F(TextClockScene, ASynthesisedClockSceneRunsHeadlessWithoutScriptErrors)
{
    ASSERT_TRUE(Load(ClockScene(), ClockProperties()));
    for (int frame = 0; frame < 3; ++frame) Runtime().Tick(kFrame);
    EXPECT_NE(sceneToRenderGraph(*scene), nullptr);
    EXPECT_EQ(Runtime().scriptErrorCount(), 0u);

    const std::string clock = Runtime().NodeText("Clock");
    ASSERT_EQ(clock.size(), 5u) << "the time text is not HH:MM";
    EXPECT_EQ(clock[2], ':');
    for (const int digit : { 0, 1, 3, 4 }) EXPECT_TRUE(std::isdigit(static_cast<unsigned char>(clock[digit])));
    EXPECT_EQ(Runtime().NodeText("Date"), "DATE");
    EXPECT_EQ(Runtime().NodeText("Dy"), "PM");
}
