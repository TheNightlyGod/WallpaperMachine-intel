// How a material document turns into texture slots and shader constants, and how the runtime
// image source keeps the pictures it is given. Everything is in-memory JSON and byte arrays.

#include "Interface/IImageParser.h"
#include "Runtime/RuntimeImageSource.hpp"
#include "WPSceneParser.hpp"
#include "wpscene/WPMaterial.h"

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include <array>
#include <cstring>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace wallpaper
{
namespace
{

using nlohmann::json;
using wpscene::WPMaterial;
using wpscene::WPMaterialPass;

constexpr const char* kCover = "$mediaThumbnail";

// A one-pass material document around the given pass members.
json MaterialWith(json pass)
{
    pass["shader"] = "generic";
    return { { "passes", json::array({ std::move(pass) }) } };
}

WPMaterial ParseMaterial(const json& document)
{
    WPMaterial material;
    EXPECT_TRUE(material.FromJson(document));
    return material;
}

WPMaterialPass ParsePass(const json& document)
{
    WPMaterialPass pass;
    EXPECT_TRUE(pass.FromJson(document));
    return pass;
}

json SystemSlot(const char* name) { return { { "type", "system" }, { "name", name } }; }

std::vector<std::string> Applied(const WPMaterial& material)
{
    std::vector<std::string> slots = material.textures;
    ApplySystemUserTextures(slots, material.usertextures);
    return slots;
}

// ---- user texture slots ---------------------------------------------------------------------

TEST(UserTextureSlots, ARegularMaterialsSlotZeroNamesTheCover)
{
    const auto material = ParseMaterial(MaterialWith(
        { { "textures", { "materials/authored" } }, { "usertextures", json::array({ SystemSlot(kCover) }) } }));
    ASSERT_EQ(material.textures.size(), 1u);
    ASSERT_EQ(material.usertextures.size(), 1u);

    auto slots = Applied(material);
    ASSERT_EQ(slots.size(), 1u);
    EXPECT_EQ(slots[0], kCover) << "the authored path is replaced";

    // An empty texture list grows to hold the slot.
    const auto bare = ParseMaterial(
        MaterialWith({ { "textures", json::array() }, { "usertextures", json::array({ SystemSlot(kCover) }) } }));
    slots = Applied(bare);
    ASSERT_EQ(slots.size(), 1u);
    EXPECT_EQ(slots[0], kCover);

    // A name with no type is a property-style name: without a property table nothing changes.
    const auto untyped = ParseMaterial(MaterialWith(
        { { "textures", { "materials/authored" } }, { "usertextures", json::array({ { { "name", kCover } } }) } }));
    EXPECT_EQ(Applied(untyped), (std::vector<std::string> { "materials/authored" }));

    // A system slot the renderer does not supply stays as authored.
    const auto foreign = ParseMaterial(MaterialWith(
        { { "textures", { "materials/authored" } }, { "usertextures", json::array({ SystemSlot("$other") }) } }));
    EXPECT_EQ(Applied(foreign), (std::vector<std::string> { "materials/authored" }));

    // Only the indexed slot is rewritten.
    const auto second = ParseMaterial(MaterialWith(
        { { "textures", { "first", "second" } }, { "usertextures", json::array({ nullptr, SystemSlot(kCover) }) } }));
    EXPECT_EQ(Applied(second), (std::vector<std::string> { "first", kCover }));
}

TEST(UserTextureSlots, AnEffectPassSuppliesTheCoverForSlotOneAfterTheMerge)
{
    auto material = ParseMaterial(MaterialWith({ { "textures", { "base", "placeholder" } } }));
    const auto pass = ParsePass({ { "textures", { "base", "effect placeholder" } },
                                  { "usertextures", json::array({ nullptr, SystemSlot(kCover) }) } });
    material.MergePass(pass);
    ASSERT_EQ(material.textures.size(), 2u);
    ASSERT_EQ(material.usertextures.size(), 2u);

    const auto slots = Applied(material);
    ASSERT_EQ(slots.size(), 2u);
    EXPECT_EQ(slots[0], "base");
    EXPECT_EQ(slots[1], kCover);

    // Vacant entries never erase what a lower layer put in a slot.
    material.MergePass(ParsePass({ { "textures", { "", "" } }, { "usertextures", json::array({ nullptr, nullptr }) } }));
    ASSERT_EQ(material.usertextures.size(), 2u);
    EXPECT_EQ(material.usertextures[1].type, "system");
    EXPECT_EQ(material.usertextures[1].name, kCover);
    EXPECT_EQ(material.textures[0], "base");
    EXPECT_EQ(material.textures[1], "effect placeholder");

    // A pass that binds a slot beyond the material's own textures extends the list.
    auto longer = ParseMaterial(MaterialWith({ { "textures", { "a", "b" } } }));
    longer.MergePass(ParsePass({ { "usertextures", json::array({ nullptr, nullptr, SystemSlot(kCover) }) } }));
    auto grown = Applied(longer);
    ASSERT_EQ(grown.size(), 3u);
    EXPECT_EQ(grown[2], kCover);
    EXPECT_EQ(grown[0], "a");

    // Two layers binding different slots both survive.
    auto both = ParseMaterial(MaterialWith(
        { { "textures", { "a", "b" } }, { "usertextures", json::array({ nullptr, SystemSlot(kCover) }) } }));
    both.MergePass(ParsePass({ { "usertextures", json::array({ SystemSlot("$mediaPreviousThumbnail") }) } }));
    ASSERT_EQ(both.usertextures.size(), 2u);
    EXPECT_EQ(Applied(both), (std::vector<std::string> { "$mediaPreviousThumbnail", kCover }));
}

// ---- constant shader values -----------------------------------------------------------------

json WithConstants(json constants)
{
    return MaterialWith({ { "textures", { "any" } }, { "constantshadervalues", std::move(constants) } });
}

TEST(ConstantShaderValues, KeepTheirUserBindingAndFallbackValue)
{
    const auto material = ParseMaterial(WithConstants(
        { { "color", { { "user", "tintprop" }, { "value", "0.00000 0.00000 0.00000" } } },
          { "Alpha", { { "user", "alphaprop" }, { "value", 1.0 } } } }));

    ASSERT_TRUE(material.constantshadervalues.contains("color"));
    ASSERT_TRUE(material.constantshadervalues.contains("Alpha"));
    EXPECT_FALSE(material.constantshadervalues.contains("alpha")) << "keys are case sensitive";

    const auto& color = material.constantshadervalues.at("color");
    EXPECT_EQ(color.user, "tintprop");
    ASSERT_EQ(color.value.size(), 3u);
    for (float lane : color.value) EXPECT_FLOAT_EQ(lane, 0.0f);

    const auto& alpha = material.constantshadervalues.at("Alpha");
    EXPECT_EQ(alpha.user, "alphaprop");
    ASSERT_EQ(alpha.value.size(), 1u);
    EXPECT_FLOAT_EQ(alpha.value[0], 1.0f);
}

TEST(ConstantShaderValues, ReadTheirLanesLeniently)
{
    const auto material = ParseMaterial(WithConstants(
        { { "array", { { "value", { 0.25, 0.5, "x" } } } },
          { "words", { { "value", "1 two 3" } } },
          { "flag", { { "user", { { "name", "modeprop" }, { "condition", "night" } } }, { "value", 0 } } },
          { "junk", true },
          { "plain", { { "value", 0.5 } } } }));

    const auto& array = material.constantshadervalues.at("array");
    ASSERT_EQ(array.value.size(), 3u);
    EXPECT_FLOAT_EQ(array.value[0], 0.25f);
    EXPECT_FLOAT_EQ(array.value[1], 0.5f);
    EXPECT_FLOAT_EQ(array.value[2], 0.0f);
    EXPECT_TRUE(array.user.empty());

    const auto& words = material.constantshadervalues.at("words");
    ASSERT_EQ(words.value.size(), 3u);
    EXPECT_FLOAT_EQ(words.value[0], 1.0f);
    EXPECT_FLOAT_EQ(words.value[1], 0.0f) << "an unreadable piece reads as 0";
    EXPECT_FLOAT_EQ(words.value[2], 3.0f);

    const auto& flag = material.constantshadervalues.at("flag");
    EXPECT_EQ(flag.user, "modeprop");
    ASSERT_TRUE(flag.user_condition.has_value());
    EXPECT_EQ(*flag.user_condition, "night");

    // An entry that cannot be read is empty and does not fail the material.
    ASSERT_TRUE(material.constantshadervalues.contains("junk"));
    EXPECT_TRUE(material.constantshadervalues.at("junk").value.empty());
    const auto& plain = material.constantshadervalues.at("plain");
    ASSERT_EQ(plain.value.size(), 1u);
    EXPECT_FLOAT_EQ(plain.value[0], 0.5f);
}

TEST(ConstantShaderValues, KeepTheirScriptAndScriptProperties)
{
    const std::string script =
        "export var scriptProperties = createScriptProperties().addSlider({ name: 'speed', value: 1 }).finish(); "
        "export function update(value) { return value; }";
    const json animation = { { "options", { { "name", "pulse" } } }, { "c0", json::array() } };

    const auto material = ParseMaterial(WithConstants(
        { { "color", { { "script", script },
                       { "scriptproperties", { { "speed", { { "user", "speed_user" }, { "value", 0.5 } } } } },
                       { "value", "1 1 1" } } },
          { "badprops", { { "script", script }, { "scriptproperties", json::array({ 1, 2 }) } } },
          { "moving", { { "animation", animation }, { "value", 1 } } },
          { "quiet", { { "value", 1 } } } }));

    const auto& color = material.constantshadervalues.at("color");
    EXPECT_EQ(color.script, script);
    ASSERT_TRUE(color.scriptproperties.is_object());
    ASSERT_TRUE(color.scriptproperties.contains("speed"));
    EXPECT_EQ(color.scriptproperties["speed"]["user"], "speed_user");
    EXPECT_DOUBLE_EQ(color.scriptproperties["speed"]["value"].get<double>(), 0.5);
    ASSERT_EQ(color.value.size(), 3u);
    for (float lane : color.value) EXPECT_FLOAT_EQ(lane, 1.0f);

    // Script properties that are not an object are not kept; the material still parses.
    EXPECT_FALSE(material.constantshadervalues.at("badprops").scriptproperties.is_object());
    EXPECT_EQ(material.constantshadervalues.at("moving").animation, animation);
    EXPECT_TRUE(material.constantshadervalues.at("quiet").script.empty());
}

// ---- the runtime image source ---------------------------------------------------------------

// A fallback that knows nothing.
class NoPictures final : public IImageParser {
public:
    std::shared_ptr<Image> Parse(const std::string&) override { return nullptr; }
    ImageHeader            ParseHeader(const std::string&) override { return {}; }
};

// A fallback that counts what it is asked and answers every parse with one picture.
class CountingPictures final : public IImageParser {
public:
    std::shared_ptr<Image> Parse(const std::string& name) override
    {
        ++parses;
        auto image = std::make_shared<Image>();
        image->key = "fallback:" + name;
        returned = image;
        return image;
    }
    ImageHeader ParseHeader(const std::string&) override
    {
        ++headers;
        return {};
    }

    int                    parses { 0 };
    int                    headers { 0 };
    std::shared_ptr<Image> returned;
};

TEST(RuntimeImageStore, PublishesTheExactRgbaPayloadAsAFreshImage)
{
    RuntimeImageSource source(std::make_unique<NoPictures>());
    std::array<uint8_t, 8> bytes { 0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80 };
    const auto before = source.Version(kCover);
    source.SetRgbaImage(kCover, 2, 1, bytes.data(), bytes.size());

    // Extents as {width, height, mapWidth, mapHeight, frames} and the pixel format.
    const ImageHeader header = source.ParseHeader(kCover);
    EXPECT_EQ((std::vector<int> { header.width, header.height, header.mapWidth, header.mapHeight, header.count }),
              (std::vector<int> { 2, 1, 2, 1, 1 }));
    EXPECT_EQ(header.format, TextureFormat::RGBA8);

    const auto image = source.Parse(kCover);
    ASSERT_NE(image, nullptr);
    EXPECT_EQ(std::make_pair(image->header.width, image->header.height), std::make_pair(2, 1));
    // One slot holding one mip level, both as large as the picture.
    ASSERT_EQ(image->slots.size(), 1u);
    ASSERT_EQ(image->slots[0].mipmaps.size(), 1u);
    const auto& level = image->slots[0].mipmaps[0];
    EXPECT_EQ(std::make_pair(image->slots[0].width, image->slots[0].height), std::make_pair(2, 1));
    EXPECT_EQ(std::make_pair(level.width, level.height), std::make_pair(2, 1));
    EXPECT_EQ(level.size, static_cast<isize>(bytes.size()));
    ASSERT_NE(level.data, nullptr);
    EXPECT_EQ(std::vector<uint8_t>(level.data.get(), level.data.get() + level.size),
              std::vector<uint8_t>(bytes.begin(), bytes.end()));
    EXPECT_GT(source.Version(kCover), before);

    // The store holds a private copy.
    bytes.fill(0xEE);
    EXPECT_EQ(level.data.get()[0], 0x10);
    EXPECT_EQ(level.data.get()[7], 0x80);
}

TEST(RuntimeImageStore, EveryPublicationIsANewImageAndOldOnesStayIntact)
{
    RuntimeImageSource source(std::make_unique<NoPictures>());
    std::array<uint8_t, 4> first { 1, 2, 3, 4 }, second { 9, 8, 7, 6 };
    source.SetRgbaImage(kCover, 1, 1, first.data(), first.size());
    const auto earlier = source.Parse(kCover);
    const auto earlierVersion = source.Version(kCover);

    source.SetRgbaImage(kCover, 1, 1, second.data(), second.size());
    const auto later = source.Parse(kCover);
    ASSERT_NE(earlier, nullptr);
    ASSERT_NE(later, nullptr);
    EXPECT_NE(earlier.get(), later.get());
    EXPECT_NE(earlier->key, later->key);
    EXPECT_GT(source.Version(kCover), earlierVersion);
    EXPECT_EQ(earlier->slots[0].mipmaps[0].data.get()[0], 1);
    EXPECT_EQ(later->slots[0].mipmaps[0].data.get()[0], 9);

    // An ordinary name of another size.
    std::vector<uint8_t> big(24, 0x5A);
    EXPECT_FALSE(source.IsRuntimeImage("__we_text_layer"));
    const auto beforeName = source.Version("__we_text_layer");
    source.SetRgbaImage("__we_text_layer", 3, 2, big.data(), big.size());
    const auto named = source.Parse("__we_text_layer");
    ASSERT_NE(named, nullptr);
    ASSERT_EQ(named->slots.size(), 1u);
    EXPECT_EQ(named->slots[0].width, 3);
    EXPECT_EQ(named->slots[0].height, 2);
    EXPECT_EQ(named->slots[0].mipmaps[0].size, 24);
    EXPECT_TRUE(source.IsRuntimeImage("__we_text_layer"));
    EXPECT_GT(source.Version("__we_text_layer"), beforeName);
    EXPECT_NE(named->key, later->key);
}

TEST(RuntimeImageStore, RefusesPayloadsThatDoNotDescribeAPicture)
{
    RuntimeImageSource source(std::make_unique<NoPictures>());
    std::array<uint8_t, 4> pixel { 1, 2, 3, 4 };
    source.SetRgbaImage(kCover, 1, 1, pixel.data(), pixel.size());
    const auto kept = source.Parse(kCover);
    const auto keptVersion = source.Version(kCover);

    std::array<uint8_t, 8> eight {};
    // Wrong length, empty extents, no data and no name.
    source.SetRgbaImage("fresh", 2, 1, eight.data(), 7);
    source.SetRgbaImage("fresh", 0, 1, eight.data(), 0);
    source.SetRgbaImage("fresh", 1, 0, eight.data(), 0);
    source.SetRgbaImage("fresh", 1, 1, nullptr, 4);
    source.SetRgbaImage("", 1, 1, pixel.data(), pixel.size());
    EXPECT_FALSE(source.IsRuntimeImage("fresh"));
    EXPECT_FALSE(source.IsRuntimeImage(""));

    source.SetRgbaImage(kCover, 2, 1, eight.data(), 7);
    source.SetRgbaImage(kCover, 0, 1, eight.data(), 0);
    source.SetRgbaImage(kCover, 1, 1, nullptr, 4);
    EXPECT_EQ(source.Parse(kCover).get(), kept.get());
    EXPECT_EQ(source.Version(kCover), keptVersion);
}

TEST(RuntimeImageStore, KnowsItsOwnImagesWithoutAskingTheFallback)
{
    auto  counting = std::make_unique<CountingPictures>();
    auto* fallback = counting.get();
    RuntimeImageSource source(std::move(counting));

    EXPECT_TRUE(source.IsRuntimeImage("$mediaThumbnail"));
    EXPECT_TRUE(source.IsRuntimeImage("$mediaPreviousThumbnail"));
    EXPECT_FALSE(source.IsRuntimeImage("materials/static.tex"));
    EXPECT_EQ(fallback->parses, 0);
    EXPECT_EQ(fallback->headers, 0);

    const std::array<uint8_t, 4> red { 0xFF, 0x00, 0x00, 0xFF };
    source.SetRgbaImage("__we_text_texture_layer", 1, 1, red.data(), red.size());
    EXPECT_TRUE(source.IsRuntimeImage("__we_text_texture_layer"));
    EXPECT_EQ(fallback->parses, 0);
    EXPECT_EQ(fallback->headers, 0);

    // Reading a published image never reaches the fallback either.
    EXPECT_NE(source.Parse("__we_text_texture_layer"), nullptr);
    (void)source.ParseHeader("__we_text_texture_layer");
    EXPECT_EQ(fallback->parses, 0);
    EXPECT_EQ(fallback->headers, 0);

    // An ordinary packaged path is the fallback's business, exactly once.
    const auto packaged = source.Parse("materials/static.tex");
    EXPECT_EQ(fallback->parses, 1);
    EXPECT_EQ(packaged, fallback->returned);

    // A published ordinary name can be forgotten again; the cover names cannot.
    EXPECT_TRUE(source.RemoveImage("__we_text_texture_layer"));
    EXPECT_FALSE(source.IsRuntimeImage("__we_text_texture_layer"));
    EXPECT_FALSE(source.RemoveImage("$mediaThumbnail"));
    EXPECT_TRUE(source.IsRuntimeImage("$mediaThumbnail"));
}

} // namespace
} // namespace wallpaper
