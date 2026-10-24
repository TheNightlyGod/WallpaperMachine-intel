// Scene file schema, part 4: effect files. Effect and material files are read leniently (stray
// commas before a closing bracket are tolerated), the buffers an effect declares take their size
// and format from the layer and the scene, and the swap commands an effect lists are lowered to
// copies.
#include "support/schema_fixtures_part03.hpp"

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
    EXPECT_EQ(fitted->format, TextureFormat::RGBA16F);

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
    { "FloatFormatStaysFloatInAnLdrScene", { { "fit", 256 }, { "format", "rg1616f" } }, false, 640, 360, 256, 144, TextureFormat::RGBA16F },
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

} // namespace
