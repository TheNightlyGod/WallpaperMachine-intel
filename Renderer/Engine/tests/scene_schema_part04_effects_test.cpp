// Scene file schema, part 4: effect files. Effect and material files are read leniently (stray
// commas before a closing bracket are tolerated), the buffers an effect declares take their size
// and format from the layer and the scene, and the swap commands an effect lists are lowered to
// copies.
#include "support/schema_fixtures_part03.hpp"
#include "wpscene/WPImageObject.h"

#include <gtest/gtest.h>

#include <string>
#include <vector>

namespace
{

using namespace we_schema;
using namespace we_schema::p3;
using namespace wallpaper;

// The camera a node draws through, or null.
SceneCamera* CameraOf(Scene& scene, SceneNode& node)
{
    const auto found = scene.cameras.find(node.Camera());
    return found == scene.cameras.end() ? nullptr : found->second.get();
}

// ---- lenient effect and material files -------------------------------------------------------

constexpr const char* kStrictEffect = R"({"name":"keep,] and ,} intact","fbos":[{"name":"_rt_pad,]","format":"rgba8888"}],"passes":[{"material":"effect_mat.json","bind":[{"name":"previous","index":0}]}]})";
constexpr const char* kStrictMaterial =
    R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":[null]}]})";

// The same documents with stray commas in front of closers, whitespace between them, and commas
// inside strings that must be left alone.
constexpr const char* kLenientEffect = "{\n"
                                       "  \"name\": \"keep,] and ,} intact\",\n"
                                       "  \"fbos\": [ { \"name\": \"_rt_pad,]\", \"format\": \"rgba8888\", }, ],\n"
                                       "  \"passes\": [\n"
                                       "    {\n"
                                       "      \"material\": \"effect_mat.json\",\n"
                                       "      \"bind\": [ { \"name\": \"previous\", \"index\": 0 }, ],\n"
                                       "    },\n"
                                       "  ],\n"
                                       "}\n";
constexpr const char* kLenientMaterial = "{ \"passes\": [ { \"blending\": \"translucent\", \"cullmode\": \"nocull\",\n"
                                         "  \"depthtest\": \"disabled\", \"depthwrite\": \"disabled\",\n"
                                         "  \"shader\": \"genericimage\", \"textures\": [null,], }, ], }";
// No whitespace at all between the comma and the closer.
constexpr const char* kCompactLenientEffect =
    R"({"name":"keep,] and ,} intact","fbos":[{"name":"_rt_pad,]","format":"rgba8888",},],"passes":[{"material":"effect_mat.json","bind":[{"name":"previous","index":0},],},],})";
// A comma that is not in front of a closer is still an error.
constexpr const char* kBrokenEffect =
    R"({"name":"copy","junk":[1,,2],"passes":[{"material":"effect_mat.json","bind":[{"name":"previous","index":0}]}]})";

struct LenientRow {
    const char* name;
    const char* effect;
    const char* material;
    bool        loads;
};

class LenientAssetFiles : public ::testing::TestWithParam<LenientRow> {};

// R-4.01 / B-4.01
TEST_P(LenientAssetFiles, StrayCommasInEffectAndMaterialFilesAreTolerated)
{
    const LenientRow row = GetParam();
    FileMap          files = BasicAssets();
    files["/effects/copy/effect.json"] = row.effect;
    files["/effect_mat.json"]          = row.material;
    ParseRig rig(files);
    auto     scene = rig.Parse(CanvasOf(Json::array({ ImageObject(1, "layer", { { "effects", CopyEffectEntry(3) } }) })));
    ASSERT_NE(scene, nullptr);
    SceneNode* node = FindRootChild(*scene, "layer");
    ASSERT_NE(node, nullptr);
    SceneCamera* camera = CameraOf(*scene, *node);
    if (!row.loads) {
        // The layer is kept, the effect is not.
        EXPECT_TRUE(camera == nullptr || !camera->HasImgEffect());
        return;
    }
    ASSERT_NE(camera, nullptr);
    ASSERT_TRUE(camera->HasImgEffect());
    ASSERT_EQ(camera->GetImgEffect()->EffectCount(), 1u);
    EXPECT_EQ(camera->GetImgEffect()->GetEffect(0)->nodes.size(), 1u);
    // The characters ",]" inside a name are part of the name, not a stray comma.
    bool kept = false;
    for (const auto& [name, target] : scene->renderTargets) kept = kept || name.rfind("_rt_pad,]_", 0) == 0;
    EXPECT_TRUE(kept);
}

const LenientRow kLenientRows[] = {
    { "StrayCommasWithWhitespace", kLenientEffect, kLenientMaterial, true },
    { "StrayCommasWithoutWhitespace", kCompactLenientEffect, kLenientMaterial, true },
    { "StrictDocuments", kStrictEffect, kStrictMaterial, true },
    { "LenientEffectStrictMaterial", kLenientEffect, kStrictMaterial, true },
    { "StrictEffectLenientMaterial", kStrictEffect, kLenientMaterial, true },
    { "CommaNotBeforeACloser", kBrokenEffect, kStrictMaterial, false },
};

std::string LenientName(const ::testing::TestParamInfo<LenientRow>& info) { return info.param.name; }

INSTANTIATE_TEST_SUITE_P(Documents, LenientAssetFiles, ::testing::ValuesIn(kLenientRows), LenientName);

// ---- effect buffers --------------------------------------------------------------------------

Json Fbo(const std::string& name, const Json& keys)
{
    Json fbo = { { "name", name } };
    for (const auto& [key, value] : keys.items()) fbo[key] = value;
    return fbo;
}

Json BufferPass(const std::string& target, const std::string& bind)
{
    Json pass = { { "material", "effect_mat.json" } };
    if (!target.empty()) pass["target"] = target;
    pass["bind"] = Json::array({ { { "name", bind }, { "index", 0 } } });
    return pass;
}

Json Command(const std::string& command, const std::string& source, const std::string& target)
{
    return { { "command", command }, { "source", source }, { "target", target } };
}

FileMap EffectBufferAssets(const Json& effect, int image_width = 640, int image_height = 360)
{
    FileMap files = BasicAssets();
    Add(files, BloomAssets(BloomSet::Hdr));
    PutJson(files, "/big.json", { { "material", "mat.json" }, { "width", image_width }, { "height", image_height } });
    PutJson(files, "/effect_mat.json",
            { { "passes", Json::array({ { { "blending", "normal" }, { "cullmode", "nocull" }, { "depthtest", "disabled" }, { "depthwrite", "disabled" },
                                          { "shader", "genericimage" }, { "textures", Json::array({ nullptr }) } } }) } });
    PutJson(files, "/effects/buffers/effect.json", effect);
    return files;
}

Json BufferScene(bool hdr)
{
    Json layer = ImageObject(2, "layer", { { "image", "big.json" }, { "origin", Json::array({ 320, 180, 0 }) },
                                           { "effects", Json::array({ { { "file", "effects/buffers/effect.json" }, { "id", 3 }, { "visible", true } } }) } });
    return CanvasOf(Json::array({ layer }), { { "hdr", hdr }, { "bloom", hdr } });
}

// The render target registered for the buffer `name` of the layer (names end in the layer id and
// the effect index; swap temporaries end in `_swap`).
const SceneRenderTarget* BufferNamed(const Scene& scene, const std::string& name)
{
    const std::string prefix = name + "_";
    const SceneRenderTarget* found = nullptr;
    for (const auto& [target_name, target] : scene.renderTargets) {
        if (target_name.rfind(prefix, 0) != 0) continue;
        if (target_name.size() >= 5 && target_name.compare(target_name.size() - 5, 5, "_swap") == 0) continue;
        EXPECT_EQ(found, nullptr) << "more than one buffer starts with " << prefix;
        found = &target;
    }
    return found;
}

Json FullEffect()
{
    return { { "name", "buffers" },
             { "fbos", Json::array({ Fbo("_rt_V1", { { "fit", 256 }, { "format", "rg1616f" } }), Fbo("_rt_V2", { { "fit", 256 }, { "format", "rg1616f" } }),
                                     Fbo("_rt_D1", { { "scale", 2 }, { "format", "rgba8888" } }), Fbo("_rt_D2", { { "scale", 2 }, { "format", "rgba8888" } }),
                                     Fbo("_rt_R1", { { "width", 100 }, { "height", 50 }, { "format", "rgba_backbuffer" } }),
                                     Fbo("_rt_R2", { { "width", 100 }, { "height", 50 }, { "format", "rgba_backbuffer" } }) }) },
             { "passes", Json::array({ BufferPass("_rt_V2", "_rt_V1"), BufferPass("_rt_D2", "_rt_D1"), BufferPass("", "_rt_R2"), BufferPass("_rt_R2", "_rt_R1"),
                                       Command("swap", "_rt_V1", "_rt_V2"), Command("swap", "_rt_D1", "_rt_D2"), Command("swap", "_rt_R1", "_rt_R2") }) } };
}

// R-4.02 / B-4.02
TEST(EffectBuffers, SizeAndFormatFollowTheBufferTheLayerAndTheScene)
{
    ParseRig rig(EffectBufferAssets(FullEffect()));
    auto     scene = rig.Parse(BufferScene(true));
    ASSERT_NE(scene, nullptr);
    EXPECT_TRUE(scene->hdr);

    const auto* fitted = BufferNamed(*scene, "_rt_V1");
    ASSERT_NE(fitted, nullptr);
    EXPECT_EQ(fitted->width, 256);
    EXPECT_EQ(fitted->height, 144);
    EXPECT_EQ(fitted->format, TextureFormat::RG16F);

    const auto* halved = BufferNamed(*scene, "_rt_D1");
    ASSERT_NE(halved, nullptr);
    EXPECT_EQ(halved->width, 320);
    EXPECT_EQ(halved->height, 180);
    EXPECT_EQ(halved->format, TextureFormat::RGBA8);

    const auto* own = BufferNamed(*scene, "_rt_R1");
    ASSERT_NE(own, nullptr);
    EXPECT_EQ(own->width, 100);
    EXPECT_EQ(own->height, 50);
    EXPECT_EQ(own->format, TextureFormat::RGBA16F);
}

struct BufferRow {
    const char* name;
    Json        keys;
    bool        hdr;
    int         image_width;
    int         image_height;
    int         width;
    int         height;
    TextureFormat format;
};

class SingleBuffer : public ::testing::TestWithParam<BufferRow> {};

TEST_P(SingleBuffer, TakesItsExtentAndFormatFromItsKeys)
{
    const BufferRow row = GetParam();
    Json effect = { { "name", "one" },
                    { "fbos", Json::array({ Fbo("_rt_P1", row.keys), Fbo("_rt_P2", row.keys) }) },
                    { "passes", Json::array({ BufferPass("_rt_P2", "_rt_P1") }) } };
    ParseRig rig(EffectBufferAssets(effect, row.image_width, row.image_height));
    auto     scene = rig.Parse(BufferScene(row.hdr));
    ASSERT_NE(scene, nullptr);
    const auto* buffer = BufferNamed(*scene, "_rt_P1");
    ASSERT_NE(buffer, nullptr);
    EXPECT_EQ(buffer->width, row.width);
    EXPECT_EQ(buffer->height, row.height);
    EXPECT_EQ(buffer->format, row.format);
}

// The scene is 640x360 unless a row says otherwise (the layer is the image's size).
const BufferRow kBufferRows[] = {
    { "BackbufferFormatIsLdrInAnLdrScene", { { "width", 100 }, { "height", 50 }, { "format", "rgba_backbuffer" } }, false, 640, 360, 100, 50, TextureFormat::RGBA8 },
    { "FloatFormatStaysFloatInAnLdrScene", { { "fit", 256 }, { "format", "rg1616f" } }, false, 640, 360, 256, 144, TextureFormat::RG16F },
    { "FitLargerThanTheLayerKeepsTheLayersSize", { { "fit", 4096 }, { "format", "rgba8888" } }, true, 640, 360, 640, 360, TextureFormat::RGBA8 },
    { "OwnWidthAboveTheLimitIsIgnored", { { "width", 8192 }, { "height", 50 }, { "format", "rgba8888" } }, true, 640, 360, 640, 50, TextureFormat::RGBA8 },
    { "ScaleZeroReadsAsOne", { { "scale", 0 }, { "format", "rgba8888" } }, true, 640, 360, 640, 360, TextureFormat::RGBA8 },
    { "FitKeepsTheAspectOfATallLayer", { { "fit", 256 }, { "format", "rgba8888" } }, true, 360, 640, 144, 256, TextureFormat::RGBA8 },
};

std::string BufferRowName(const ::testing::TestParamInfo<BufferRow>& info) { return info.param.name; }

INSTANTIATE_TEST_SUITE_P(Buffers, SingleBuffer, ::testing::ValuesIn(kBufferRows), BufferRowName);

// R-4.02 / B-4.03
TEST(EffectBuffers, SwapCommandsLowerToCopiesAndOnlyGoThroughATemporaryWhenTheSecondBufferIsReadFirst)
{
    ParseRig rig(EffectBufferAssets(FullEffect()));
    auto     scene = rig.Parse(BufferScene(true));
    ASSERT_NE(scene, nullptr);
    SceneNode* node = FindRootChild(*scene, "layer");
    ASSERT_NE(node, nullptr);
    SceneCamera* camera = CameraOf(*scene, *node);
    ASSERT_NE(camera, nullptr);
    ASSERT_TRUE(camera->HasImgEffect());
    const auto& commands = camera->GetImgEffect()->GetEffect(0)->commands;
    ASSERT_EQ(commands.size(), 5u);

    const auto starts = [](const std::string& text, const char* prefix) { return text.rfind(prefix, 0) == 0; };
    const auto ends   = [](const std::string& text, const char* suffix) {
        const std::string tail = suffix;
        return text.size() >= tail.size() && text.compare(text.size() - tail.size(), tail.size(), tail) == 0;
    };
    EXPECT_TRUE(starts(commands[0].dst, "_rt_V1_"));
    EXPECT_TRUE(starts(commands[0].src, "_rt_V2_"));
    EXPECT_TRUE(starts(commands[1].dst, "_rt_D1_"));
    EXPECT_TRUE(starts(commands[1].src, "_rt_D2_"));
    EXPECT_TRUE(ends(commands[2].dst, "_swap"));
    EXPECT_TRUE(starts(commands[2].src, "_rt_R1_"));
    EXPECT_TRUE(starts(commands[3].dst, "_rt_R1_"));
    EXPECT_TRUE(starts(commands[3].src, "_rt_R2_"));
    EXPECT_TRUE(starts(commands[4].dst, "_rt_R2_"));
    EXPECT_TRUE(ends(commands[4].src, "_swap"));
    for (const auto& command : commands) EXPECT_EQ(command.afterpos, 4);
    // The temporary the third swap goes through is a target of the scene.
    EXPECT_NE(scene->FindRenderTarget(commands[2].dst), nullptr);
}

TEST(EffectBuffers, ACopyCommandIsOneCopyFromItsSourceToItsTarget)
{
    Json effect = { { "name", "copy only" },
                    { "fbos", Json::array({ Fbo("_rt_P1", { { "format", "rgba8888" } }), Fbo("_rt_P2", { { "format", "rgba8888" } }) }) },
                    { "passes", Json::array({ BufferPass("_rt_P2", "_rt_P1"), Command("copy", "_rt_P2", "_rt_P1") }) } };
    ParseRig rig(EffectBufferAssets(effect));
    auto     scene = rig.Parse(BufferScene(true));
    ASSERT_NE(scene, nullptr);
    SceneNode* node = FindRootChild(*scene, "layer");
    ASSERT_NE(node, nullptr);
    SceneCamera* camera = CameraOf(*scene, *node);
    ASSERT_NE(camera, nullptr);
    ASSERT_TRUE(camera->HasImgEffect());
    const auto& commands = camera->GetImgEffect()->GetEffect(0)->commands;
    ASSERT_EQ(commands.size(), 1u);
    EXPECT_EQ(commands[0].dst.rfind("_rt_P1_", 0), 0u);
    EXPECT_EQ(commands[0].src.rfind("_rt_P2_", 0), 0u);
    EXPECT_EQ(commands[0].afterpos, 1);
}

TEST(EffectBuffers, ACommandThatCannotBeLoweredIsDroppedAndTheEffectStillLoads)
{
    Json effect = { { "name", "bad commands" },
                    { "fbos", Json::array({ Fbo("_rt_P1", { { "format", "rgba8888" } }), Fbo("_rt_P2", { { "format", "rgba8888" } }) }) },
                    { "passes", Json::array({ BufferPass("_rt_P2", "_rt_P1"), Command("swap", "_rt_P1", "_rt_missing"), Command("explode", "_rt_P1", "_rt_P2") }) } };
    ParseRig rig(EffectBufferAssets(effect));
    auto     scene = rig.Parse(BufferScene(true));
    ASSERT_NE(scene, nullptr);
    SceneNode* node = FindRootChild(*scene, "layer");
    ASSERT_NE(node, nullptr);
    SceneCamera* camera = CameraOf(*scene, *node);
    ASSERT_NE(camera, nullptr);
    ASSERT_TRUE(camera->HasImgEffect());
    EXPECT_TRUE(camera->GetImgEffect()->GetEffect(0)->commands.empty());
}

// ---- effect file keys (Appendix D item 13; WE 2.8.0.42 sub_1401E7170, sub_1401E63B0) -------

// The textures the effect's `pass`-th pass is drawn with.
std::vector<std::string> PassTextures(Scene& scene, std::size_t pass)
{
    SceneNode* node = FindRootChild(scene, "layer");
    if (node == nullptr) return {};
    SceneCamera* camera = CameraOf(scene, *node);
    if (camera == nullptr || ! camera->HasImgEffect()) return {};
    const auto& nodes = camera->GetImgEffect()->GetEffect(0)->nodes;
    if (pass >= nodes.size()) return {};
    auto it = nodes.begin();
    std::advance(it, static_cast<std::ptrdiff_t>(pass));
    return it->sceneNode->Mesh()->MaterialForSlot(0)->textures;
}

Json FluidLikeEffect()
{
    // The shape of `effects/fluidsimulation`: a buffer, a pass and two binds gated on combos.
    return { { "name", "fluid" },
             { "fbos", Json::array({ Fbo("_rt_V1", { { "fit", 256 }, { "format", "rg1616f" }, { "clear", "0 0 0 0" }, { "unique", true } }),
                                     Fbo("_rt_Normal", { { "format", "rgba8888" }, { "conditions", Json::array({ { { "LIGHTING", 1 } } }) } }),
                                     Fbo("_rt_Rep", { { "format", "rgba8888" }, { "uvs", "repeat" }, { "clear", "0.25 0.5 0.75 1" } }) }) },
             { "passes",
               Json::array({ BufferPass("_rt_V1", "_rt_V1"),
                             { { "material", "effect_mat.json" }, { "target", "_rt_Normal" },
                               { "bind", Json::array({ { { "name", "_rt_V1" }, { "index", 0 } } }) },
                               { "conditions", Json::array({ { { "LIGHTING", 1 } } }) } },
                             // The probe shader samples slot 0 only (unsampled slots are dropped),
                             // so each gated bind writes slot 0 and the last that holds wins.
                             { { "material", "effect_mat.json" },
                               { "bind", Json::array({ { { "name", "_rt_V1" }, { "index", 0 } },
                                                       { { "name", "_rt_Normal" }, { "index", 0 }, { "conditions", Json::array({ { { "LIGHTING", 1 } } }) } },
                                                       { { "name", "_rt_Rep" }, { "index", 0 }, { "conditions", Json::array({ { { "RENDERING", 3 } } }) } } }) } } }) } };
}

Json FluidScene(const Json& combos)
{
    Json instance = { { "file", "effects/buffers/effect.json" }, { "id", 3 }, { "visible", true } };
    if (! combos.is_null()) instance["combos"] = combos;
    Json layer = ImageObject(2, "layer", { { "image", "big.json" }, { "origin", Json::array({ 320, 180, 0 }) },
                                           { "effects", Json::array({ instance }) } });
    return CanvasOf(Json::array({ layer }), { { "hdr", false }, { "bloom", false } });
}

TEST(EffectFbo, RepeatClearUniqueAndConditionsAreRead)
{
    ParseRig rig(EffectBufferAssets(FluidLikeEffect()));
    // The conditions read the instance's own `combos`; LIGHTING is missing, so it reads 0.
    auto scene = rig.Parse(FluidScene({ { "RENDERING", 3 } }));
    ASSERT_NE(scene, nullptr);

    // `unique`: the instance's own buffer (layer 2, effect 0); `clear "0 0 0 0"` is a clear.
    const auto* velocity = scene->FindRenderTarget("_rt_V1_2_0");
    ASSERT_NE(velocity, nullptr);
    EXPECT_EQ(velocity->format, TextureFormat::RG16F);
    EXPECT_EQ(velocity->initial_clear, (std::array<float, 4> { 0, 0, 0, 0 }));
    // The buffer whose conditions fail is not made.
    EXPECT_EQ(BufferNamed(*scene, "_rt_Normal"), nullptr);
    // Not unique: one target for every effect declaring it at this size and scale.
    const auto* repeat = scene->FindRenderTarget("_rt_Rep_640_360_1_shared");
    ASSERT_NE(repeat, nullptr);
    EXPECT_EQ(repeat->sample.wrapS, TextureWrap::REPEAT);
    EXPECT_EQ(repeat->sample.wrapT, TextureWrap::REPEAT);
    EXPECT_EQ(repeat->initial_clear, (std::array<float, 4> { 0.25f, 0.5f, 0.75f, 1.0f }));

    // The pass whose conditions fail is left out, so the combine pass is the second.
    const auto combine = PassTextures(*scene, 1);
    ASSERT_GE(combine.size(), 1u);
    EXPECT_EQ(combine[0], "_rt_Rep_640_360_1_shared");
    EXPECT_TRUE(PassTextures(*scene, 2).empty());

    // With LIGHTING 1 the buffer, the pass and its bind come back; RENDERING 0 drops the last.
    ParseRig lit_rig(EffectBufferAssets(FluidLikeEffect()));
    auto     lit = lit_rig.Parse(FluidScene({ { "LIGHTING", 1 } }));
    ASSERT_NE(lit, nullptr);
    ASSERT_NE(BufferNamed(*lit, "_rt_Normal"), nullptr);
    const auto lit_combine = PassTextures(*lit, 2);
    ASSERT_GE(lit_combine.size(), 1u);
    EXPECT_EQ(lit_combine[0], "_rt_Normal_640_360_1_shared");
}

TEST(EffectFbo, ConditionsAreEveryElementOfTheArrayAndCompareWithTheirOperator)
{
    using wallpaper::wpscene::EffectConditionsHold;
    const Json combos = { { "A", 3 }, { "B", 2.9 } };
    EXPECT_TRUE(EffectConditionsHold(Json::array({ { { "A", 3 } } }), &combos));
    // Every element must hold (the array is not a choice of alternatives).
    EXPECT_FALSE(EffectConditionsHold(Json::array({ { { "A", 3 } }, { { "C", 1 } } }), &combos));
    // A missing combo reads 0; a double truncates.
    EXPECT_TRUE(EffectConditionsHold(Json::array({ { { "C", 0 }, { "B", 2 } } }), &combos));
    for (const auto& [op, holds] : std::vector<std::pair<std::string, bool>> {
             { "ge", true }, { "gt", false }, { "le", true }, { "lt", false }, { "eq", true }, { "", true } }) {
        EXPECT_EQ(EffectConditionsHold(Json::array({ { { "A", { { "value", 3 }, { "op", op } } } } }), &combos), holds) << op;
    }
    // A key whose value is not a number or an object is ignored; not an array always holds.
    EXPECT_TRUE(EffectConditionsHold(Json::array({ { { "A", "9" } } }), &combos));
    EXPECT_TRUE(EffectConditionsHold(Json::object({ { "A", 9 } }), &combos));
    EXPECT_FALSE(EffectConditionsHold(Json::array({ { { "A", 3 } } }), nullptr));
}

TEST(EffectFbo, AnEntryWithoutANameAndAFormatIsNoBufferAndClearNeedsFourNumbers)
{
    wallpaper::wpscene::WPEffectFbo fbo;
    EXPECT_FALSE(fbo.FromJson({ { "name", "_rt_A" } }));
    EXPECT_FALSE(fbo.FromJson({ { "format", "rgba8888" } }));
    const auto read = [](const Json& clear) {
        wallpaper::wpscene::WPEffectFbo f;
        EXPECT_TRUE(f.FromJson({ { "name", "_rt_A" }, { "format", "rgba8888" }, { "clear", clear } }));
        return f;
    };
    EXPECT_TRUE(read("").clear);
    const auto four = read("1 0.5 0 1");
    EXPECT_TRUE(four.clear);
    EXPECT_EQ(four.clear_color, (std::array<float, 4> { 1, 0.5f, 0, 1 }));
    // Two numbers set the colour a function clears to, without the clear at creation.
    const auto two = read("1 1");
    EXPECT_FALSE(two.clear);
    EXPECT_EQ(two.clear_color, (std::array<float, 4> { 1, 1, 0, 0 }));
    EXPECT_FALSE(read(true).clear);
}

TEST(EffectFboFormat, UnknownIsRgba8EvenInHdr)
{
    const struct { const char* format; bool hdr; TextureFormat expected; } rows[] = {
        { "r32f", true, TextureFormat::RGBA8 },           { "nonsense", true, TextureFormat::RGBA8 },
        { "r8", true, TextureFormat::R8 },                { "rg88", false, TextureFormat::RG8 },
        { "r16f", false, TextureFormat::R16F },           { "rgba_backbuffer", true, TextureFormat::RGBA16F },
        { "rgb_backbuffer", false, TextureFormat::RGBA8 }, { "rgba16161616f", false, TextureFormat::RGBA16F },
    };
    for (const auto& row : rows) {
        Json effect = { { "name", "one" },
                        { "fbos", Json::array({ Fbo("_rt_P1", { { "format", row.format } }) }) },
                        { "passes", Json::array({ BufferPass("_rt_P1", "previous") }) } };
        ParseRig rig(EffectBufferAssets(effect));
        auto     scene = rig.Parse(BufferScene(row.hdr));
        ASSERT_NE(scene, nullptr) << row.format;
        const auto* buffer = BufferNamed(*scene, "_rt_P1");
        ASSERT_NE(buffer, nullptr) << row.format;
        EXPECT_EQ(buffer->format, row.expected) << row.format << (row.hdr ? " hdr" : " ldr");
    }
}

TEST(EffectFbo, ANonUniqueBufferIsOneTargetForEveryLayerThatDeclaresItAtTheSameSize)
{
    Json effect = { { "name", "shared" },
                    { "fbos", Json::array({ Fbo("_rt_Shared", { { "format", "rgba8888" } }),
                                            Fbo("_rt_Own", { { "format", "rgba8888" }, { "unique", true } }) }) },
                    { "passes", Json::array({ BufferPass("_rt_Shared", "_rt_Own"), BufferPass("", "_rt_Shared") }) } };
    ParseRig rig(EffectBufferAssets(effect));
    const auto layer = [](int id, const char* name, int x) {
        return ImageObject(id, name, { { "image", "big.json" }, { "origin", Json::array({ x, 180, 0 }) },
                                       { "effects", Json::array({ { { "file", "effects/buffers/effect.json" }, { "id", id + 10 }, { "visible", true } } }) } });
    };
    auto scene = rig.Parse(CanvasOf(Json::array({ layer(2, "a", 160), layer(4, "b", 480) }), { { "hdr", false }, { "bloom", false } }));
    ASSERT_NE(scene, nullptr);
    std::vector<std::string> outputs, inputs;
    for (const char* name : { "a", "b" }) {
        auto* node = FindRootChild(*scene, name);
        ASSERT_NE(node, nullptr);
        auto* camera = CameraOf(*scene, *node);
        ASSERT_NE(camera, nullptr);
        ASSERT_TRUE(camera->HasImgEffect());
        const auto effect = camera->GetImgEffect()->GetEffect(0);
        ASSERT_NE(effect, nullptr);
        ASSERT_EQ(effect->nodes.size(), 2u);
        const auto& pass = effect->nodes.front();
        outputs.push_back(pass.output);
        const auto& textures = pass.sceneNode->Mesh()->MaterialForSlot(0)->textures;
        ASSERT_FALSE(textures.empty());
        inputs.push_back(textures[0]);
        EXPECT_NE(scene->FindRenderTarget(outputs.back()), nullptr);
        EXPECT_NE(scene->FindRenderTarget(inputs.back()), nullptr);
    }
    EXPECT_EQ(outputs[0], outputs[1]) << "non-unique outputs share one texture";
    EXPECT_NE(inputs[0], inputs[1]) << "unique inputs remain separate textures";
}

TEST(EffectFbo, TheLastExplicitClearOfASharedBufferWins)
{
    Json effect = { { "name", "shared clear" },
                    { "fbos", Json::array({ Fbo("_rt_SharedClear", { { "format", "rgba8888" }, { "clear", "1 0 0 1" } }) }) },
                    { "passes", Json::array({ BufferPass("", "_rt_SharedClear") }) } };
    FileMap files = EffectBufferAssets(effect);
    effect["fbos"][0]["clear"] = "0 1 0 1";
    PutJson(files, "/effects/green.json", effect);
    effect["fbos"][0].erase("clear");
    PutJson(files, "/effects/uncleared.json", effect);
    Json config = BufferScene(false);
    for (const auto& path : { "effects/green.json", "effects/uncleared.json" }) {
        Json layer = config["objects"][0];
        layer["id"] = 10 + config["objects"].size();
        layer["name"] = path;
        layer["effects"][0]["file"] = path;
        config["objects"].push_back(std::move(layer));
    }
    ParseRig rig(files);
    auto scene = rig.Parse(config);
    ASSERT_NE(scene, nullptr);
    const auto* buffer = BufferNamed(*scene, "_rt_SharedClear");
    ASSERT_NE(buffer, nullptr);
    EXPECT_EQ(buffer->initial_clear, (std::array<float, 4> { 0, 1, 0, 1 }));
}

TEST(EffectFunctions, RunEffectFunctionQueuesClearsOfTheEffectsFirstBuffers)
{
    // sub_1401EE3A0 clears the effect's buffers 0..N-1 (N = the buffers the function lists),
    // each to its own `clear` colour; only `"action": "clear"` with a known buffer is kept.
    Json effect = { { "name", "functions" },
                    { "fbos", Json::array({ Fbo("_rt_A", { { "format", "rgba8888" }, { "unique", true }, { "clear", "0.1 0.2 0.3 0.4" } }),
                                            Fbo("_rt_B", { { "format", "rgba8888" }, { "unique", true } }),
                                            Fbo("_rt_C", { { "format", "rgba8888" }, { "unique", true }, { "clear", "1 1 1 1" } }) }) },
                    { "functions", { { "clearC", { { "action", "clear" }, { "fbos", Json::array({ "_rt_C" }) } } },
                                     { "clearBC", { { "action", "clear" }, { "fbos", Json::array({ "_rt_B", "_rt_C" }) } } },
                                     { "swapA", { { "action", "swap" }, { "fbos", Json::array({ "_rt_A" }) } } },
                                     { "clearNothing", { { "action", "clear" }, { "fbos", Json::array({ "_rt_missing" }) } } } } },
                    { "passes", Json::array({ BufferPass("_rt_A", "_rt_B"), BufferPass("_rt_B", "_rt_C"), BufferPass("", "_rt_A") }) } };
    ParseRig rig(EffectBufferAssets(effect));
    auto     scene = rig.Parse(BufferScene(false), ParseOptions { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto&      runtime   = *scene->runtime;
    const auto reference = runtime.LayerEffectReference("layer", 0);
    ASSERT_FALSE(reference.empty());

    EXPECT_TRUE(runtime.RunEffectFunction(reference, "clearC"));
    ASSERT_EQ(scene->pending_effect_clears.size(), 1u);
    EXPECT_EQ(scene->pending_effect_clears[0].target, "_rt_A_2_0");
    EXPECT_EQ(scene->pending_effect_clears[0].color, (std::array<float, 4> { 0.1f, 0.2f, 0.3f, 0.4f }));
    scene->pending_effect_clears.clear();

    EXPECT_TRUE(runtime.RunEffectFunction(reference, "clearBC"));
    ASSERT_EQ(scene->pending_effect_clears.size(), 2u);
    EXPECT_EQ(scene->pending_effect_clears[1].target, "_rt_B_2_0");
    EXPECT_EQ(scene->pending_effect_clears[1].color, (std::array<float, 4> { 0, 0, 0, 0 }));
    scene->pending_effect_clears.clear();

    EXPECT_FALSE(runtime.RunEffectFunction(reference, "swapA"));
    EXPECT_FALSE(runtime.RunEffectFunction(reference, "clearNothing"));
    EXPECT_FALSE(runtime.RunEffectFunction("effect:nope", "clearC"));
    EXPECT_TRUE(scene->pending_effect_clears.empty());
}

} // namespace
