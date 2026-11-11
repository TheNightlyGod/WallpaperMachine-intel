// Runtime text mutation: a text change is recorded at once and measured and drawn later by the
// text worker; dirty flags, the cache revision and the cache identity; the card and its picture
// being replaced under the same texture key. Some tests use a runtime with no scene at all.
// Headless: no renderer, no window.

#include "text_fixture.hpp"

#include "Runtime/DynamicValue.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/RuntimeImageSource.hpp"
#include "SpecTexs.hpp"
#include "Text/TextGlyphMesh.hpp"

#include <chrono>
#include <sstream>
#include <thread>

namespace
{
using namespace we_test;
using namespace wallpaper;

TextLayerState Layer(const std::string& text, float point_size, const std::string& font = "Arial")
{
    TextLayerState state;
    state.text       = text;
    state.font_key   = font;
    state.point_size = point_size;
    return state;
}

/// A runtime without a scene, with nodes it owns.
class BareRuntime : public ::testing::Test {
protected:
    std::unique_ptr<SceneRuntimeContext>    runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    std::vector<std::shared_ptr<SceneNode>> nodes;

    void Add(const std::string& name, TextLayerState state)
    {
        nodes.push_back(std::make_shared<SceneNode>());
        runtime->RegisterNode(name, nodes.back().get());
        runtime->RegisterTextLayer(name, std::move(state));
    }

    TextLayerState State(const std::string& name)
    {
        const auto state = runtime->NodeTextState(name);
        EXPECT_TRUE(state.has_value());
        return state.value_or(TextLayerState {});
    }
};

} // namespace

class TextRuntimeBare : public BareRuntime {};
class TextRuntimeScene : public TextSceneTest {};

// ---- I. mutating text at run time --------------------------------------------------------

TEST_F(TextRuntimeBare, AChangeUpdatesTextSizeRevisionAndDirtyState)
{
    ASSERT_NE(runtime, nullptr);
    TextLayerState state = Layer("a", 10.0f);
    state.padding = state.authored_padding = linalg::Vector2f(2.0f, 2.0f);
    state.horizontal_align                  = "left";
    state.vertical_align                    = "top";
    Add("caption", state);

    const auto before_size  = runtime->NodeSize("caption");
    const auto before_state = State("caption");
    EXPECT_FALSE(before_state.texture_cache_key.empty());
    EXPECT_EQ(before_state.cache_revision, 1u);

    ASSERT_TRUE(runtime->SetNodeText("caption", "longer text"));
    EXPECT_EQ(runtime->NodeText("caption"), "longer text");
    EXPECT_TRUE(runtime->NodeTextDirty("caption"));

    ASSERT_TRUE(PumpUntilClean(*runtime, { "caption" }));
    const auto after_size = runtime->NodeSize("caption");
    EXPECT_GT(after_size.x(), before_size.x());
    EXPECT_EQ(after_size.y(), before_size.y());
    const auto after_state = State("caption");
    EXPECT_EQ(after_state.cache_revision, before_state.cache_revision + 1);
    EXPECT_FALSE(after_state.cache_dirty);
    EXPECT_FALSE(after_state.full_dirty);

    runtime->ClearNodeTextDirty("caption");
    const auto cleared = State("caption");
    EXPECT_EQ(cleared.text, "longer text");
    EXPECT_EQ(cleared.cache_revision, after_state.cache_revision);
    EXPECT_FALSE(cleared.cache_dirty);
    EXPECT_FALSE(cleared.full_dirty);
    EXPECT_FALSE(runtime->NodeTextDirty("caption"));
}

TEST_F(TextRuntimeBare, WritingTheTextAlreadyHeldCostsNothing)
{
    TextLayerState state = Layer("12:34", 33.0f, "systemfont_sansserif");
    state.padding = state.authored_padding = linalg::Vector2f(32.0f, 32.0f);
    Add("caption", state);
    auto  value = std::make_unique<DynamicValue>(std::string("12:34"));
    auto* bound = value.get();
    runtime->RegisterTextValue("caption", std::move(value));
    runtime->ClearNodeTextDirty("caption");
    ASSERT_FALSE(runtime->ConsumeSceneGraphMutationFlag());
    const auto before = State("caption");
    ASSERT_FALSE(before.cache_dirty);
    ASSERT_FALSE(before.full_dirty);

    // The bound value is assigned the very text the layer shows: its generation moves on, so the
    // tick looks at the layer, and finds nothing to do.
    bound->update(std::string("12:34"));
    ResetTextLayerMeasurementCountForTests();
    runtime->Tick(1.0 / 60.0);

    EXPECT_EQ(TextLayerMeasurementCountForTests(), 0u);
    const auto after = State("caption");
    EXPECT_EQ(after.cache_revision, before.cache_revision);
    EXPECT_FALSE(after.cache_dirty);
    EXPECT_FALSE(after.full_dirty);
    EXPECT_FALSE(runtime->NodeTextDirty("caption"));
    EXPECT_FALSE(runtime->ConsumeSceneGraphMutationFlag());
}

TEST_F(TextRuntimeBare, APumpedChangeClearsDirtyWithoutLosingTheText)
{
    Add("caption", Layer("before", 12.0f));
    ASSERT_TRUE(runtime->SetNodeText("caption", "after"));
    EXPECT_TRUE(runtime->NodeTextDirty("caption"));
    ASSERT_TRUE(PumpUntilClean(*runtime, { "caption" }));
    const auto state = State("caption");
    EXPECT_EQ(state.text, "after");
    EXPECT_FALSE(state.cache_dirty);
    EXPECT_FALSE(state.full_dirty);
    EXPECT_FALSE(runtime->NodeTextDirty("caption"));
}

TEST(TextRuntimeSceneless, ASceneThatCannotTakeATextureStillEndsClean)
{
    // A scene object with a runtime but no image source: nowhere to publish a picture to.
    Scene scene;
    scene.runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    ASSERT_NE(scene.runtime, nullptr);
    SceneRuntimeContext& rt = *scene.runtime;
    rt.AttachScene(&scene);
    const auto holder = std::make_shared<SceneNode>();
    rt.RegisterNode("caption", holder.get());
    rt.RegisterTextLayer("caption", Layer("before", 12.0f));

    const bool accepted = rt.SetNodeText("caption", "after");
    ASSERT_TRUE(accepted);
    ASSERT_TRUE(rt.NodeTextDirty("caption"));
    ASSERT_TRUE(PumpUntilClean(rt, { "caption" }));

    const auto settled = rt.NodeTextState("caption");
    ASSERT_TRUE(settled.has_value());
    EXPECT_FALSE(settled->cache_dirty || settled->full_dirty);
    EXPECT_FALSE(rt.NodeTextDirty("caption"));
    EXPECT_FALSE(rt.ConsumeSceneGraphMutationFlag()) << "no picture was published, so nothing needs a rebuild";
}

TEST_F(TextRuntimeScene, APumpedChangeRewritesTheGlyphsUnderTheSameAtlas)
{
    ASSERT_TRUE(Load(SceneDocument({ TextObject(1, "caption", "a") })));
    auto* node = Node("caption");
    ASSERT_NE(node, nullptr);
    const std::string key = CardTexture(*node);
    ASSERT_NE(scene->imageParser->Parse(key), nullptr);
    EXPECT_EQ(GlyphQuads(*node), 1u);
    (void)Runtime().ConsumeSceneGraphMutationFlag();

    ASSERT_TRUE(Runtime().SetNodeText("caption", "aaaaaa"));
    EXPECT_TRUE(Runtime().NodeTextDirty("caption"));
    ASSERT_TRUE(PumpUntilClean(Runtime(), { "caption" }));

    // The glyph mesh holds a quad per letter; the atlas keeps its name (its cells are shared,
    // decompiles/G-F16.md) and nothing is rebuilt.
    EXPECT_EQ(GlyphQuads(*node), 6u);
    ASSERT_NE(scene->imageParser->Parse(key), nullptr);
    EXPECT_FALSE(Runtime().NodeTextDirty("caption"));
    EXPECT_FALSE(Runtime().ConsumeSceneGraphMutationFlag()) << "the glyphs are rewritten in place";
    EXPECT_EQ(CardTexture(*node), key);
}

TEST_F(TextRuntimeScene, AHiddenLayerWaitsUntilItIsShown)
{
    ASSERT_TRUE(Load(SceneDocument({ TextObject(1, "caption", "before", { { "visible", false } }) })));
    auto* node = Node("caption");
    ASSERT_NE(node, nullptr);
    EXPECT_EQ(GlyphQuads(*node), 6u);

    ASSERT_TRUE(Runtime().SetNodeText("caption", "after"));
    EXPECT_TRUE(Runtime().NodeTextDirty("caption"));
    Runtime().PumpTextLayerCache();
    EXPECT_EQ(GlyphQuads(*node), 6u);
    EXPECT_TRUE(Runtime().NodeTextDirty("caption"));

    // Even when given time, nothing is prepared while the layer is hidden.
    for (int round = 0; round < 5; ++round) {
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
        Runtime().PumpTextLayerCache();
    }
    EXPECT_TRUE(Runtime().NodeTextDirty("caption"));
    EXPECT_EQ(GlyphQuads(*node), 6u);

    EXPECT_TRUE(Runtime().SetNodeVisible("caption", true));
    ASSERT_TRUE(PumpUntilClean(Runtime(), { "caption" }));
    EXPECT_EQ(GlyphQuads(*node), 5u);
    EXPECT_FALSE(Runtime().NodeTextDirty("caption"));
}

TEST_F(TextRuntimeScene, ATextParticleImageIsMadeOnlyOnDemandAndKeepsTheMaterialAlphaRule)
{
    for (bool msdf : { false, true }) {
        ASSERT_TRUE(Load(SceneDocument({ TextObject(1, "caption", "MMMM", {
            { "pointsize", 48 }, { "color", "1 0 0" }, { "alpha", 0.7 }, { "msdf", msdf } }) })));
        auto& runtime = Runtime();
        auto* images = dynamic_cast<RuntimeImageSource*>(scene->imageParser.get());
        ASSERT_NE(images, nullptr);
        const auto generation = images->NamesGeneration();
        runtime.ClearNodeTextDirty("caption");
        ResetTextLayerMeasurementCountForTests();
        const auto frame = runtime.TextEmissionFrame("caption");
        ASSERT_TRUE(frame.has_value());
        EXPECT_EQ(frame->size.x(), std::floor(frame->size.x()));
        const auto width = uint32_t(std::max(1.0f, frame->size.x() / 4));
        const auto height = uint32_t(std::max(1.0f, frame->size.y() / 4));
        const auto peak = [](const std::shared_ptr<Image>& image, std::size_t channel) {
            if (!image || image->slots.empty() || image->slots[0].mipmaps.empty()) return -1;
            const auto& level = image->slots[0].mipmaps[0];
            int value = 0;
            for (std::size_t at = channel; at < std::size_t(level.size); at += 4) value = std::max(value, int(level.data.get()[at]));
            return value;
        };
        auto dim = runtime.BuildTextEmissionImage("caption", width, height);
        ASSERT_NE(dim, nullptr);
        EXPECT_EQ(dim->header.width, int(width));
        EXPECT_EQ(dim->header.height, int(height));
        EXPECT_EQ(peak(dim, 3), 125) << "0.70 squared is below 127";
        runtime.SetNodeAlpha("caption", 0.75f);
        auto visible = runtime.BuildTextEmissionImage("caption", width, height);
        EXPECT_EQ(peak(visible, 3), 143) << "0.75 squared passes 127";
        EXPECT_EQ(peak(visible, 0), 191) << "RGB uses the source-alpha blend factor";
        EXPECT_EQ(peak(visible, 1), 0);
        runtime.SetNodeVisible("caption", false);
        auto hidden = runtime.BuildTextEmissionImage("caption", width, height);
        ASSERT_NE(hidden, nullptr);
        EXPECT_EQ(peak(hidden, 3), peak(visible, 3)) << "hidden donors still emit";
        EXPECT_EQ(images->NamesGeneration(), generation) << "no persistent bitmap is registered";
        EXPECT_EQ(TextLayerMeasurementCountForTests(), 0u) << "sampling never reshapes the text";
        EXPECT_FALSE(runtime.NodeTextDirty("caption"));
    }
}

TEST_F(TextRuntimeScene, AHiddenParticleDonorRefreshesItsTextFontAndPointSize)
{
    world.PutAsset("particle.json", R"({"maxcount":8,"material":"materials/particle.json",
        "emitter":[{"name":"layerimage","rate":0,"instantaneous":8,"flags":131072}],
        "initializer":[{"name":"lifetimerandom","min":100,"max":100}]})");
    world.PutAsset("materials/particle.json", R"({"passes":[{"shader":"particle_probe",
        "blending":"translucent","cullmode":"nocull","depthtest":"disabled","textures":[]}]})");
    world.PutAsset("shaders/particle_probe.vert",
        "attribute vec3 a_Position;\nvoid main() { gl_Position = vec4(a_Position, 1.0); }\n");
    world.PutAsset("shaders/particle_probe.frag", "void main() { gl_FragColor = vec4(1.0, 1.0, 1.0, 1.0); }\n");
    const Json emitter = {
        { "id", 3 }, { "name", "emitter" }, { "particle", "particle.json" },
        { "dependencies", Json::array({ { { "id", 1 }, { "index", 0 }, { "type", "emitterimage" } } }) }
    };
    ASSERT_TRUE(Load(SceneDocument({
        TextObject(1, "caption", "M", { { "visible", false }, { "pointsize", 32 } }),
        TextObject(2, "unused", "before", { { "visible", false } }), emitter })));
    auto& runtime = Runtime();
    auto* node = Node("caption");
    ASSERT_NE(node, nullptr);
    const auto original = runtime.TextEmissionFrame("caption");
    ASSERT_TRUE(original.has_value());
    const auto pixels = [&]() {
        const auto frame = runtime.TextEmissionFrame("caption");
        if (!frame) return std::vector<uint8_t>();
        const auto image = runtime.BuildTextEmissionImage("caption",
            uint32_t(std::max(1.0f, frame->size.x() / 4)), uint32_t(std::max(1.0f, frame->size.y() / 4)));
        if (!image) return std::vector<uint8_t>();
        const auto& mip = image->slots[0].mipmaps[0];
        return std::vector<uint8_t>(mip.data.get(), mip.data.get() + mip.size);
    };
    const auto original_pixels = pixels();
    ASSERT_FALSE(original_pixels.empty());
    ASSERT_TRUE(runtime.SetNodeText("unused", "waiting"));
    ASSERT_TRUE(runtime.SetNodeText("caption", "MMMM"));
    EXPECT_TRUE(runtime.TextLayoutInFlight()) << "a hidden emitter source still needs its new layout";
    ASSERT_TRUE(PumpUntilClean(runtime, { "caption" }));
    EXPECT_GT(runtime.TextEmissionFrame("caption")->size.x(), original->size.x());
    EXPECT_NE(pixels(), original_pixels);
    const auto text_size = runtime.TextEmissionFrame("caption")->size;

    ASSERT_TRUE(runtime.SetNodeTextStyle("caption", "pointsize", "64"));
    ASSERT_TRUE(PumpUntilClean(runtime, { "caption" }));
    EXPECT_GT(runtime.TextEmissionFrame("caption")->size.x(), text_size.x());
    EXPECT_GT(runtime.TextEmissionFrame("caption")->size.y(), text_size.y());
    const auto before_font = pixels();
    ASSERT_TRUE(runtime.SetNodeTextStyle("caption", "font", "systemfont_verdana"));
    ASSERT_TRUE(PumpUntilClean(runtime, { "caption" }));
    EXPECT_NE(pixels(), before_font);

    ASSERT_TRUE(runtime.SetNodeText("caption", " "));
    ASSERT_TRUE(PumpUntilClean(runtime, { "caption" }));
    const auto empty = pixels();
    ASSERT_FALSE(empty.empty());
    EXPECT_TRUE(std::all_of(empty.begin(), empty.end(), [](uint8_t value) { return value == 0; }));
    EXPECT_FALSE(node->EffectiveVisible());
    EXPECT_EQ(scene->FindRenderTarget(LayerCompositeTargetKey(node->ID())), nullptr)
        << "CPU preparation must not allocate a hidden GPU composite";
    EXPECT_TRUE(runtime.NodeTextDirty("unused")) << "unreferenced hidden text still waits";
    EXPECT_EQ(GlyphQuads(*Node("unused")), 6u);
    EXPECT_FALSE(runtime.TextLayoutInFlight()) << "an unused hidden layer must not keep the scene awake";
    runtime.UnregisterNode("caption");
    EXPECT_FALSE(runtime.TextEmissionFrame("caption").has_value());
    EXPECT_EQ(runtime.BuildTextEmissionImage("caption", 4, 4), nullptr);
}

TEST_F(TextRuntimeScene, ATextParticleImageRejectsMissingDonorsAndOversizedMaps)
{
    ASSERT_TRUE(Load(SceneDocument({ TextObject(1, "caption", "a") })));
    EXPECT_FALSE(Runtime().TextEmissionFrame("missing").has_value());
    EXPECT_EQ(Runtime().BuildTextEmissionImage("missing", 4, 4), nullptr);
    EXPECT_EQ(Runtime().BuildTextEmissionImage("caption", 0, 4), nullptr);
    EXPECT_EQ(Runtime().BuildTextEmissionImage("caption", 961, 4), nullptr);
    EXPECT_EQ(Runtime().BuildTextEmissionImage("caption", 4, 541), nullptr);
}

TEST_F(TextRuntimeScene, TextParticleImagesIncludeBackgroundsColourGlyphsAndStyledCoverage)
{
    const auto picture = [&](const std::string& text, Json extra) {
        extra["pointsize"] = 48;
        EXPECT_TRUE(Load(SceneDocument({ TextObject(1, "caption", text, extra) })));
        const auto frame = Runtime().TextEmissionFrame("caption");
        if (!frame) return std::shared_ptr<Image>();
        return Runtime().BuildTextEmissionImage("caption", uint32_t(std::max(1.0f, frame->size.x() / 4)),
                                                 uint32_t(std::max(1.0f, frame->size.y() / 4)));
    };
    auto background = picture("", { { "opaquebackground", true }, { "backgroundcolor", "0 1 0" }, { "alpha", 0.75 } });
    ASSERT_NE(background, nullptr);
    const auto& bg = background->slots[0].mipmaps[0];
    for (std::size_t at = 0; at < std::size_t(bg.size); at += 4) {
        EXPECT_EQ(bg.data.get()[at + 0], 0);
        EXPECT_EQ(bg.data.get()[at + 1], 191);
        EXPECT_EQ(bg.data.get()[at + 2], 0);
        EXPECT_EQ(bg.data.get()[at + 3], 143);
    }
    const auto count = [](const std::shared_ptr<Image>& image) {
        if (!image) return std::size_t(0);
        const auto& level = image->slots[0].mipmaps[0];
        std::size_t kept = 0;
        for (std::size_t at = 3; at < std::size_t(level.size); at += 4) kept += level.data.get()[at] >= 127;
        return kept;
    };
    auto plain = picture("I", { { "color", "1 0 0" }, { "msdf", true } });
    auto outlined = picture("I", { { "color", "1 0 0" }, { "outline", true },
                                     { "outlinecolor", "1 0 0" }, { "outlinethickness", 8 } });
    ASSERT_NE(plain, nullptr);
    ASSERT_NE(outlined, nullptr);
    EXPECT_GT(count(outlined), count(plain)) << "the outline is part of the emitter's source";
    const auto red_shadow_samples = [&](float opacity) {
        auto shadow = picture("Aa", { { "color", "1 1 1" }, { "dropshadow", true },
            { "dropshadowsize", 6 }, { "dropshadowoffset", "4 4" },
            { "dropshadowopacity", opacity }, { "dropshadowcolor", "1 0 0" } });
        if (!shadow) return std::size_t(0);
        const auto& level = shadow->slots[0].mipmaps[0];
        std::size_t red = 0;
        for (std::size_t at = 0; at < std::size_t(level.size); at += 4) {
            const auto* p = level.data.get() + at;
            red += p[3] >= 127 && p[0] > p[1] + 20 && p[0] > p[2] + 20;
        }
        return red;
    };
    EXPECT_GT(red_shadow_samples(1), 0u) << "the WE donor's particles include the shadow colour";
    EXPECT_EQ(red_shadow_samples(0), 0u) << "a transparent shadow contributes no emission colour";
    auto emoji = picture("😀", {});
    ASSERT_NE(emoji, nullptr);
    const auto& color = emoji->slots[0].mipmaps[0];
    std::size_t saturated = 0;
    for (std::size_t at = 0; at < std::size_t(color.size); at += 4) {
        const auto* p = color.data.get() + at;
        if (p[3] >= 127 && *std::max_element(p, p + 3) - *std::min_element(p, p + 3) > 20) ++saturated;
    }
    EXPECT_GT(saturated, 10u) << "the colour atlas must not become a monochrome mask";
}

TEST_F(TextRuntimeScene, EveryScriptTextMemberReachesTheNativeLayerWithItsType)
{
    const std::string script = R"JS(
export function update(value) { return value; }
export function cursorClick() {
    thisLayer.padding = new Vec2(8, 6);
    thisLayer.spacing = new Vec2(2, 3);
    thisLayer.maxwidth = 120;
    thisLayer.maxrows = 2;
    thisLayer.limitwidth = true;
    thisLayer.limitrows = true;
    thisLayer.limituseellipsis = true;
    thisLayer.blockalign = true;
    thisLayer.anchor = 'topleft';
    thisLayer.backgroundcolor = new Vec3(0.2, 0.4, 0.6);
    thisLayer.backgroundbrightness = 2;
    thisLayer.opaquebackground = true;
    thisLayer.msdf = true;
    thisLayer.outline = true;
    thisLayer.outlinethickness = 3;
    thisLayer.outlinecolor = new Vec3(0.25, 0.5, 0.75);
    thisLayer.blur = true;
    thisLayer.blursize = 2;
    thisLayer.dropshadow = true;
    thisLayer.dropshadowsize = 4;
    thisLayer.dropshadowopacity = 0.5;
    thisLayer.dropshadowoffset = new Vec2(3, -2);
    thisLayer.dropshadowcolor = new Vec3(1, 0, 0);
    thisLayer.depthtest = 'disabled';
    if (!(thisLayer.padding instanceof Vec2) || thisLayer.padding.y !== 6 ||
        !(thisLayer.outlinecolor instanceof Vec3) || thisLayer.outlinecolor.z !== 0.75 ||
        thisLayer.limitrows !== true || thisLayer.maxrows !== 2 || thisLayer.depthtest !== 'disabled' ||
        thisLayer.backgroundcolor.x !== Math.fround(0.2)) {
        throw new Error('text members have the wrong value types');
    }
}
)JS";
    ASSERT_TRUE(Load(SceneDocument({ TextObject(1, "caption", { { "value", "one two three" }, { "script", script } }) })));
    Runtime().Tick(kFrame);
    Runtime().DispatchCursorClick();
    EXPECT_EQ(Runtime().scriptErrorCount(), 0u);
    const std::pair<const char*, const char*> expected[] = {
        { "padding", "8 6" }, { "spacing", "2 3" }, { "maxwidth", "120" }, { "maxrows", "2" },
        { "limitwidth", "1" }, { "limitrows", "1" }, { "limituseellipsis", "1" }, { "blockalign", "1" },
        { "anchor", "topleft" }, { "backgroundcolor", "0.2 0.4 0.6" }, { "backgroundbrightness", "2" },
        { "opaquebackground", "1" }, { "msdf", "1" }, { "outline", "1" }, { "outlinethickness", "3" },
        { "outlinecolor", "0.25 0.5 0.75" }, { "blur", "1" }, { "blursize", "2" },
        { "dropshadow", "1" }, { "dropshadowsize", "4" }, { "dropshadowopacity", "0.5" },
        { "dropshadowoffset", "3 -2" }, { "dropshadowcolor", "1 0 0" }, { "depthtest", "disabled" }
    };
    for (const auto& [name, value] : expected) {
        SCOPED_TRACE(name);
        const auto actual = Runtime().NodeTextStyle("caption", name);
        ASSERT_TRUE(actual.has_value());
        if (std::string_view(value).find(' ') == std::string_view::npos) EXPECT_EQ(*actual, value);
        else {
            std::istringstream actual_values(*actual), expected_values(value);
            float wanted;
            while (expected_values >> wanted) {
                double got = 0;
                ASSERT_TRUE(bool(actual_values >> got));
                EXPECT_DOUBLE_EQ(got, double(wanted));
            }
        }
    }
    ASSERT_TRUE(PumpUntilClean(Runtime(), { "caption" }));
    const auto state = Runtime().NodeTextState("caption");
    ASSERT_TRUE(state.has_value());
    EXPECT_TRUE(state->padding.isApprox(linalg::Vector2f(8, 6)));
    EXPECT_TRUE(state->spacing.isApprox(linalg::Vector2f(2, 3)));
    EXPECT_TRUE(state->msdf);
    EXPECT_TRUE(state->style.outline && state->style.blur && state->style.drop_shadow);
}

TEST_F(TextRuntimeScene, TextUniformMembersDoNotRelayoutOrRebuild)
{
    ASSERT_TRUE(Load(SceneDocument({ TextObject(1, "caption", "Aa", { { "outline", true } }) })));
    Runtime().ClearNodeTextDirty("caption");
    (void)Runtime().ConsumeSceneGraphMutationFlag();
    ResetTextLayerMeasurementCountForTests();
    for (const auto& [name, value] : std::vector<std::pair<const char*, const char*>> {
            { "outlinethickness", "2" }, { "outlinecolor", "0.25 0.5 0.75" }, { "blursize", "5" },
            { "dropshadowsize", "7" }, { "dropshadowopacity", "0.6" }, { "dropshadowoffset", "2 -3" },
            { "dropshadowcolor", "1 0 0" }, { "backgroundcolor", "0 1 0" },
            { "backgroundbrightness", "3" }, { "anchor", "topright" } }) {
        SCOPED_TRACE(name);
        EXPECT_TRUE(Runtime().SetNodeTextStyle("caption", name, value));
    }
    Runtime().PumpTextLayerCache();
    EXPECT_EQ(TextLayerMeasurementCountForTests(), 0u);
    EXPECT_FALSE(Runtime().NodeTextDirty("caption"));
    EXPECT_FALSE(Runtime().ConsumeSceneGraphMutationFlag());
    const auto* material = Node("caption")->Mesh()->MaterialForSlot(kTextGlyphSubmesh);
    ASSERT_NE(material, nullptr);
    const auto& color = material->customShader.constValues.at("g_RenderVar1");
    EXPECT_FLOAT_EQ(color[0], 0.25f);
    EXPECT_FLOAT_EQ(color[1], 0.5f);
    EXPECT_FLOAT_EQ(color[2], 0.75f);
}

TEST_F(TextRuntimeScene, TextLayoutMembersGrowTheCardAndEqualWritesDoNoWork)
{
    ASSERT_TRUE(Load(SceneDocument({ TextObject(1, "caption", "Aa", { { "opaquebackground", true }, { "padding", 0 } }) })));
    const auto before = Runtime().NodeSize("caption");
    (void)Runtime().ConsumeSceneGraphMutationFlag();
    ASSERT_TRUE(Runtime().SetNodeTextStyle("caption", "padding", "8 6"));
    ASSERT_TRUE(PumpUntilClean(Runtime(), { "caption" }));
    EXPECT_NEAR(Runtime().NodeSize("caption").x(), before.x() + 16, 0.01f);
    EXPECT_NEAR(Runtime().NodeSize("caption").y(), before.y() + 12, 0.01f);
    EXPECT_FALSE(Runtime().ConsumeSceneGraphMutationFlag());
    ResetTextLayerMeasurementCountForTests();
    ASSERT_TRUE(Runtime().SetNodeTextStyle("caption", "padding", "8 6"));
    ASSERT_TRUE(Runtime().SetNodeTextStyle("caption", "spacing", "0 0"));
    Runtime().PumpTextLayerCache();
    EXPECT_FALSE(Runtime().NodeTextDirty("caption"));
    EXPECT_EQ(TextLayerMeasurementCountForTests(), 0u);
    EXPECT_FALSE(Runtime().ConsumeSceneGraphMutationFlag());
}

TEST_F(TextRuntimeScene, TextDistanceFieldSwitchPublishesItsAtlasBeforeChangingTheMaterial)
{
    ASSERT_TRUE(Load(SceneDocument({ TextObject(1, "caption", "MMMM", { { "pointsize", 32 } }) })));
    Runtime().ClearNodeTextDirty("caption");
    (void)Runtime().ConsumeSceneGraphMutationFlag();
    ASSERT_EQ(scene->imageParser->Parse(TextAtlasName("caption"))->header.format, TextureFormat::R8);
    ASSERT_TRUE(Runtime().SetNodeTextStyle("caption", "msdf", "1"));
    EXPECT_EQ(scene->imageParser->Parse(TextAtlasName("caption"))->header.format, TextureFormat::R8);
    EXPECT_FALSE(Runtime().ConsumeSceneGraphMutationFlag()) << "the old glyphs still need their coverage shader";
    ASSERT_TRUE(PumpUntilClean(Runtime(), { "caption" }));
    EXPECT_EQ(scene->imageParser->Parse(TextAtlasName("caption"))->header.format, TextureFormat::RGBA8);
    EXPECT_TRUE(Runtime().ConsumeSceneGraphMutationFlag());
    ASSERT_TRUE(Runtime().SetNodeAlpha("caption", 0.4f));
    EXPECT_FLOAT_EQ(Node("caption")->Mesh()->MaterialForSlot(kTextGlyphSubmesh)->customShader.constValues.at("g_Color4")[3], 0.4f);
    ASSERT_TRUE(Runtime().SetNodeTextStyle("caption", "msdf", "1"));
    EXPECT_FALSE(Runtime().NodeTextDirty("caption"));
    EXPECT_FALSE(Runtime().ConsumeSceneGraphMutationFlag());
}

TEST_F(TextRuntimeScene, ABackgroundEnabledByScriptKeepsFollowingTheExistingAlphaDriver)
{
    ASSERT_TRUE(Load(SceneDocument({ TextObject(1, "caption", "Aa", {
        { "alpha", { { "value", 0.25 }, { "script", "export function update(v) { return engine.runtime < 1 ? 0.25 : 0.75; }" } } } }) })));
    Runtime().Tick(kFrame);
    (void)Runtime().ConsumeSceneGraphMutationFlag();
    ASSERT_TRUE(Runtime().SetNodeTextStyle("caption", "backgroundcolor", "0 1 0"));
    ASSERT_TRUE(Runtime().SetNodeTextStyle("caption", "opaquebackground", "1"));
    ASSERT_TRUE(PumpUntilClean(Runtime(), { "caption" }));
    auto* background = Node("caption")->Mesh()->MaterialForSlot(kTextBackgroundSubmesh);
    ASSERT_NE(background, nullptr);
    EXPECT_FLOAT_EQ(background->customShader.constValues.at("g_Alpha")[0], 0.25f);
    EXPECT_FLOAT_EQ(background->customShader.constValues.at("g_Color")[1], 1.0f);
    EXPECT_TRUE(Runtime().ConsumeSceneGraphMutationFlag());
    Runtime().Tick(1.5);
    EXPECT_FLOAT_EQ(background->customShader.constValues.at("g_Alpha")[0], 0.75f);
    ASSERT_TRUE(Runtime().SetNodeTextStyle("caption", "opaquebackground", "0"));
    ASSERT_TRUE(PumpUntilClean(Runtime(), { "caption" }));
    EXPECT_EQ(Node("caption")->Mesh()->MaterialForSlot(kTextBackgroundSubmesh), nullptr);
    EXPECT_TRUE(Runtime().ConsumeSceneGraphMutationFlag());
}

TEST_F(TextRuntimeScene, ACancelledDistanceFieldSwitchKeepsItsCoverageAtlasAndNeedsNoRebuild)
{
    ASSERT_TRUE(Load(SceneDocument({ TextObject(1, "caption", "MMMM") })));
    (void)Runtime().ConsumeSceneGraphMutationFlag();
    ASSERT_TRUE(Runtime().SetNodeTextStyle("caption", "msdf", "1"));
    Runtime().PumpTextLayerCache();
    ASSERT_TRUE(Runtime().SetNodeTextStyle("caption", "msdf", "0"));
    ASSERT_TRUE(PumpUntilClean(Runtime(), { "caption" }));
    EXPECT_EQ(scene->imageParser->Parse(TextAtlasName("caption"))->header.format, TextureFormat::R8);
    EXPECT_FALSE(Runtime().ConsumeSceneGraphMutationFlag());
}

TEST_F(TextRuntimeScene, TextEnumsUseReferenceDefaultsAndMaxRowsKeepsItsSignedValue)
{
    ASSERT_TRUE(Load(SceneDocument({ TextObject(1, "caption", "Aa") })));
    const std::pair<const char*, const char*> cases[] = {
        { "horizontalalign", "left" }, { "verticalalign", "center" },
        { "anchor", "none" }, { "depthtest", "disabled" }
    };
    for (const auto& [key, expected] : cases) {
        EXPECT_TRUE(Runtime().SetNodeTextStyle("caption", key, "not-a-word"));
        EXPECT_EQ(Runtime().NodeTextStyle("caption", key), std::optional<std::string>(expected));
    }
    ASSERT_TRUE(Runtime().SetNodeTextStyle("caption", "maxrows", "-1"));
    EXPECT_EQ(Runtime().NodeTextStyle("caption", "maxrows"), std::optional<std::string>("-1"));
}

TEST_F(TextRuntimeScene, TextColourWritesReachTheGlyphsWithoutRecolouringTheBackground)
{
    ASSERT_TRUE(Load(SceneDocument({ TextObject(1, "caption", "Aa", {
        { "opaquebackground", true }, { "backgroundcolor", "0 1 0" } }) })));
    ASSERT_TRUE(Runtime().SetNodeColor("caption", linalg::Vector3f(0, 0, 1)));
    const auto* glyphs = Node("caption")->Mesh()->MaterialForSlot(kTextGlyphSubmesh);
    const auto* background = Node("caption")->Mesh()->MaterialForSlot(kTextBackgroundSubmesh);
    ASSERT_NE(glyphs, nullptr);
    ASSERT_NE(background, nullptr);
    EXPECT_FLOAT_EQ(glyphs->customShader.constValues.at("g_Color4")[2], 1.0f);
    EXPECT_FLOAT_EQ(background->customShader.constValues.at("g_Color")[1], 1.0f);
    EXPECT_FLOAT_EQ(background->customShader.constValues.at("g_Color")[2], 0.0f);
}

TEST_F(TextRuntimeBare, SettingTextNeverMeasuresOnTheCallingThread)
{
    TextLayerState state = Layer("fps: 59", 20.0f);
    state.padding = state.authored_padding = linalg::Vector2f(32.0f, 32.0f);
    Add("caption", state);
    runtime->ClearNodeTextDirty("caption");
    ASSERT_FALSE(runtime->NodeTextDirty("caption"));

    ResetTextLayerMeasurementCountForTests();
    ASSERT_TRUE(runtime->SetNodeText("caption", "fps: 60"));
    EXPECT_EQ(TextLayerMeasurementCountForTests(), 0u);
    EXPECT_TRUE(runtime->NodeTextDirty("caption"));
}

TEST_F(TextRuntimeScene, AVisibleLayersPreparationIsDeferredAndLandsLater)
{
    ASSERT_TRUE(Load(SceneDocument({ TextObject(1, "caption", "before",
                                                { { "pointsize", 28 }, { "padding", 32 } }) })));
    ASSERT_NE(Node("caption"), nullptr);
    const std::string key    = CardTexture(*Node("caption"));
    const auto        before = scene->imageParser->Parse(key);
    ASSERT_NE(before, nullptr);

    ResetTextLayerMeasurementCountForTests();
    ASSERT_TRUE(Runtime().SetNodeText("caption", "after after after"));
    EXPECT_EQ(TextLayerMeasurementCountForTests(), 0u);
    EXPECT_EQ(Runtime().NodeText("caption"), "after after after");
    EXPECT_TRUE(Runtime().NodeTextDirty("caption"));

    Runtime().PumpTextLayerCache();
    ASSERT_NE(scene->imageParser->Parse(key), nullptr);
    EXPECT_EQ(scene->imageParser->Parse(key)->key, before->key) << "the first pump only queues the job";
    EXPECT_TRUE(Runtime().NodeTextDirty("caption"));

    std::string latest = before->key;
    for (int round = 0; round < 200 && latest == before->key; ++round) {
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
        Runtime().PumpTextLayerCache();
        const auto image = scene->imageParser->Parse(key);
        ASSERT_NE(image, nullptr);
        latest = image->key;
    }
    EXPECT_NE(latest, before->key) << "the job never landed";
    EXPECT_FALSE(Runtime().NodeTextDirty("caption"));
}

TEST_F(TextRuntimeScene, AChangedTextResizesTheDrawnCardWithoutRebuilding)
{
    ASSERT_TRUE(Load(SceneDocument({ TextObject(1, "caption", "a", { { "pointsize", 10 } }) })));
    auto* node = Node("caption");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    EXPECT_TRUE(node->Mesh()->Dynamic());
    const auto  before_size  = Runtime().NodeSize("caption");
    const float before_width = PositionBox(*node->Mesh()).W();
    (void)Runtime().ConsumeSceneGraphMutationFlag();

    ASSERT_TRUE(Runtime().SetNodeText("caption", "aaaaaaaaaa"));
    ASSERT_TRUE(PumpUntilClean(Runtime(), { "caption" }));

    const auto after_size = Runtime().NodeSize("caption");
    EXPECT_GT(after_size.x(), before_size.x());
    const float after_width = PositionBox(*node->Mesh()).W();
    EXPECT_GT(after_width, before_width);
    EXPECT_NEAR(after_width, after_size.x(), 1.0f);
    EXPECT_FALSE(Runtime().ConsumeSceneGraphMutationFlag());
}

// ---- J. bare registration ----------------------------------------------------------------

TEST_F(TextRuntimeBare, ARegisteredLayerReportsTheRuntimeGlyphAtlasBackend)
{
    Add("caption", Layer("layout only", 12.0f));
    const auto state = runtime->NodeTextState("caption");
    ASSERT_TRUE(state.has_value());
    EXPECT_EQ(state->render_backend, "runtime-glyph-atlas");
}

TEST_F(TextRuntimeBare, LayersWithIdenticalTextFontAndSizeStillGetDistinctCacheKeys)
{
    Add("first", Layer("same", 12.0f));
    Add("second", Layer("same", 12.0f));
    const auto first  = State("first");
    const auto second = State("second");
    EXPECT_FALSE(first.texture_cache_key.empty());
    EXPECT_FALSE(second.texture_cache_key.empty());
    EXPECT_NE(first.texture_cache_key, second.texture_cache_key);
}

TEST_F(TextRuntimeBare, LayersWithDifferentTextGetDistinctCacheKeys)
{
    Add("first", Layer("one", 12.0f));
    Add("second", Layer("two", 12.0f));
    EXPECT_NE(State("first").texture_cache_key, State("second").texture_cache_key);
}
