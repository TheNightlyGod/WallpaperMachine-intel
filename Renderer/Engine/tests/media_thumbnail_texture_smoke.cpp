#include "Interface/IImageParser.h"
#include "Runtime/RuntimeImageSource.hpp"
#include "Runtime/DynamicValue.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/SceneSettingResolver.hpp"
#include "Scene/include/Scene/Scene.h"
#include "Scene/include/Scene/SceneMaterial.h"
#include "Scene/include/Scene/SceneMesh.h"
#include "Scene/SceneNode.h"
#include "Utils/Logging.h"
#include "WPShaderParser.hpp"
#include "WPSceneParser.hpp"
#include "wpscene/WPMaterial.h"

#include <gtest/gtest.h>

#include <cstdint>
#include <cstring>
#include <fstream>
#include <map>
#include <filesystem>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

#include <unistd.h>

namespace wallpaper
{
namespace
{

class NullImageParser final : public IImageParser {
public:
    std::shared_ptr<Image> Parse(const std::string&) override { return nullptr; }
    ImageHeader            ParseHeader(const std::string&) override { return {}; }
};

TEST(MediaThumbnailTexture, KeepsPreviousCoverAndClearsBothWhenDisabled) {
    RuntimeImageSource images(std::make_unique<NullImageParser>());
    const uint8_t first[] = {255, 0, 0, 255};
    const uint8_t second[] = {0, 255, 0, 255};
    const uint8_t empty[] = {0, 0, 0, 0};
    images.SetRgbaImage("$mediaThumbnail", 1, 1, first, sizeof(first));
    auto old_cover = images.Parse("$mediaThumbnail");
    images.SetRgbaImage("$mediaThumbnail", 1, 1, second, sizeof(second));
    EXPECT_EQ(images.Parse("$mediaPreviousThumbnail"), old_cover);
    EXPECT_NE(images.Parse("$mediaThumbnail"), old_cover);
    images.SetRgbaImage("$mediaThumbnail", 1, 1, empty, sizeof(empty));
    EXPECT_EQ(images.Parse("$mediaPreviousThumbnail"), images.Parse("$mediaThumbnail"));
    std::vector<std::string> textures;
    ApplySystemUserTextures(textures, {{.name = "$mediaPreviousThumbnail", .type = "system"}});
    ASSERT_EQ(textures.size(), 1u);
    EXPECT_EQ(textures[0], "$mediaPreviousThumbnail");
}

TEST(MediaThumbnailTextureSmoke, PreviousThumbnailSlotResolvesForCrossFades) {
    const nlohmann::json material_json = {
        { "passes",
          { {
              { "shader", "default" },
              { "textures", { "materials/base.tex", "masks/blend.tex" } },
              { "usertextures",
                { nullptr, { { "type", "system" }, { "name", "$mediaPreviousThumbnail" } } } },
          } } },
    };

    wpscene::WPMaterial material;
    ASSERT_TRUE(material.FromJson(material_json));

    auto textures = material.textures;
    ApplySystemUserTextures(textures, material.usertextures);

    ASSERT_EQ(textures.size(), 2u);
    EXPECT_EQ(textures[0], "materials/base.tex");
    EXPECT_EQ(textures[1], "$mediaPreviousThumbnail");
}

TEST(MediaThumbnailTextureSmoke, UnknownSystemTextureKeepsAuthoredTexture) {
    const nlohmann::json material_json = {
        { "passes",
          { {
              { "shader", "default" },
              { "textures", { "materials/base.tex" } },
              { "usertextures", { { { "type", "system" }, { "name", "$somethingElse" } } } },
          } } },
    };

    wpscene::WPMaterial material;
    ASSERT_TRUE(material.FromJson(material_json));

    auto textures = material.textures;
    ApplySystemUserTextures(textures, material.usertextures);

    ASSERT_EQ(textures.size(), 1u);
    EXPECT_EQ(textures[0], "materials/base.tex");
}

// A `scenetexture` property appears in `usertextures` as a bare string naming
// the property. Wallpapers built around "choose your own picture" slots are
// only as good as this substitution.
wpscene::WPMaterial TexturePropertyMaterial() {
    const nlohmann::json material_json = {
        { "passes",
          { {
              { "shader", "default" },
              { "textures", { "materials/base.tex" } },
              { "usertextures", { nullptr, "_1" } },
          } } },
    };
    wpscene::WPMaterial material;
    EXPECT_TRUE(material.FromJson(material_json));
    return material;
}

TEST(MediaThumbnailTextureSmoke, TexturePropertyTakesTheSlotItNames) {
    const auto material = TexturePropertyMaterial();
    ProjectProperties properties;
    properties["_1"] = RuntimeScalarValue::String("materials/chosen.tex");

    auto textures = material.textures;
    ApplySystemUserTextures(textures, material.usertextures, &properties);

    ASSERT_EQ(textures.size(), 2u);
    EXPECT_EQ(textures[0], "materials/base.tex");
    // The loader addresses packaged textures by bare name, so the authored form
    // the editor writes into the property is reduced to one.
    EXPECT_EQ(textures[1], "chosen");
}

TEST(MediaThumbnailTextureSmoke, TexturePropertyCarriesTheUsersOwnFileThrough) {
    // Per process: concurrent runs share the temporary directory.
    const auto directory = std::filesystem::temp_directory_path() /
                           ("wpe-user-texture-slot-" + std::to_string(::getpid()));
    std::filesystem::remove_all(directory);
    std::filesystem::create_directories(directory);
    const auto picture = directory / "photo.png";
    std::ofstream { picture, std::ios::binary } << "a readable file is what decides the slot";

    const auto material = TexturePropertyMaterial();
    ProjectProperties properties;
    properties["_1"] = RuntimeScalarValue::String(picture.string());

    auto textures = material.textures;
    ApplySystemUserTextures(textures, material.usertextures, &properties);

    ASSERT_EQ(textures.size(), 2u);
    EXPECT_EQ(textures[1], picture.string());

    std::filesystem::remove_all(directory);
}

// The property holds the path, not a copy. A file the user has since moved, or
// one a sandboxed process may not open, has to leave the slot on the artwork
// the wallpaper shipped: a name that decodes to nothing is a hole on screen.
TEST(MediaThumbnailTextureSmoke, AnUnreadableUserFileKeepsTheAuthoredTexture) {
    const auto material = TexturePropertyMaterial();
    ProjectProperties properties;
    properties["_1"] = RuntimeScalarValue::String(
        (std::filesystem::temp_directory_path() / "wpe-user-texture-gone.png").string());

    auto textures = material.textures;
    ApplySystemUserTextures(textures, material.usertextures, &properties);

    ASSERT_EQ(textures.size(), 1u);
    EXPECT_EQ(textures[0], "materials/base.tex");
}

TEST(MediaThumbnailTextureSmoke, UnsetTexturePropertyKeepsTheAuthoredTexture) {
    const auto material = TexturePropertyMaterial();
    ProjectProperties properties;
    properties["_1"] = RuntimeScalarValue::String("");

    auto textures = material.textures;
    ApplySystemUserTextures(textures, material.usertextures, &properties);

    ASSERT_EQ(textures.size(), 1u);
    EXPECT_EQ(textures[0], "materials/base.tex");
}

TEST(MediaThumbnailTextureSmoke, TexturePropertyWithoutATableKeepsTheAuthoredTexture) {
    const auto material = TexturePropertyMaterial();

    auto textures = material.textures;
    ApplySystemUserTextures(textures, material.usertextures);

    ASSERT_EQ(textures.size(), 1u);
    EXPECT_EQ(textures[0], "materials/base.tex");
}

TEST(MediaThumbnailTextureSmoke, PreviousThumbnailKeepsTheCoverItReplaced) {
    RuntimeImageSource source(std::make_unique<NullImageParser>());

    // Before any track: both slots parse, so a bound layer is never missing an
    // image, and the previous cover is transparent rather than a stale one.
    ASSERT_NE(source.Parse("$mediaPreviousThumbnail"), nullptr);

    const std::vector<uint8_t> first { 0x11, 0x22, 0x33, 0xFF };
    const std::vector<uint8_t> second { 0x44, 0x55, 0x66, 0xFF };

    source.SetRgbaImage("$mediaThumbnail", 1, 1, first.data(), first.size());
    ASSERT_TRUE(source.AliasRuntimeImage("$mediaThumbnail", "$mediaPreviousThumbnail"));
    source.SetRgbaImage("$mediaThumbnail", 1, 1, second.data(), second.size());

    const auto current  = source.Parse("$mediaThumbnail");
    const auto previous = source.Parse("$mediaPreviousThumbnail");
    ASSERT_NE(current, nullptr);
    ASSERT_NE(previous, nullptr);
    EXPECT_EQ(std::memcmp(current->slots[0].mipmaps[0].data.get(), second.data(), second.size()), 0);
    EXPECT_EQ(std::memcmp(previous->slots[0].mipmaps[0].data.get(), first.data(), first.size()), 0);
    // Distinct cache identities, so the two covers cannot collapse into one
    // GPU texture while both are on screen during a cross-fade.
    EXPECT_NE(current->key, previous->key);
    EXPECT_EQ(source.Version("$mediaPreviousThumbnail"), source.Version("$mediaThumbnail") - 1);
}

/// Re-sending the cover that is already showing must change nothing.
///
/// Replays are routine: every new scene handle is handed the current state
/// again. Treating that as a new cover retires the texture the GPU is
/// sampling, uploads another, and moves the current cover into the previous
/// slot — so a wallpaper would cross-fade a cover into itself, and would do it
/// every time a display was added or a wallpaper switched.
TEST(MediaThumbnailTextureSmoke, RepublishingTheSameCoverChangesNothing) {
    RuntimeImageSource source(std::make_unique<NullImageParser>());

    const std::vector<uint8_t> first { 0x11, 0x22, 0x33, 0xFF };
    const std::vector<uint8_t> second { 0x44, 0x55, 0x66, 0xFF };

    ASSERT_TRUE(PublishSystemMediaArtwork(source, 1, 1, first.data(), first.size()));
    ASSERT_TRUE(PublishSystemMediaArtwork(source, 1, 1, second.data(), second.size()));
    const auto current  = source.Parse("$mediaThumbnail");
    const auto previous = source.Parse("$mediaPreviousThumbnail");
    const auto version  = source.Version("$mediaThumbnail");

    EXPECT_FALSE(PublishSystemMediaArtwork(source, 1, 1, second.data(), second.size()))
        << "the cover already on screen was published again";
    EXPECT_EQ(source.Parse("$mediaThumbnail"), current) << "an identical cover replaced the image";
    EXPECT_EQ(source.Version("$mediaThumbnail"), version)
        << "an identical cover moved the version a renderer watches for changes";
    EXPECT_EQ(source.Parse("$mediaPreviousThumbnail"), previous)
        << "an identical cover overwrote the cover a cross-fade fades from";

    // A real change still lands, and still keeps the cover it replaced.
    EXPECT_TRUE(PublishSystemMediaArtwork(source, 1, 1, first.data(), first.size()));
    EXPECT_EQ(source.Parse("$mediaPreviousThumbnail"), current);
    EXPECT_GT(source.Version("$mediaThumbnail"), version);
}

TEST(MediaThumbnailTextureSmoke, EmptyArtworkClearsBothSlotsAndAReplayDoesNoWork) {
    RuntimeImageSource source(std::make_unique<NullImageParser>());
    const std::array<uint8_t, 4> first {255, 0, 0, 255}, second {0, 255, 0, 255}, empty {};
    ASSERT_TRUE(PublishSystemMediaArtwork(source, 1, 1, first.data(), first.size()));
    ASSERT_TRUE(PublishSystemMediaArtwork(source, 1, 1, second.data(), second.size()));
    ASSERT_TRUE(PublishSystemMediaArtwork(source, 0, 0, nullptr, 0));
    EXPECT_TRUE(source.MatchesRgba("$mediaThumbnail", 1, 1, empty.data(), empty.size()));
    EXPECT_TRUE(source.MatchesRgba("$mediaPreviousThumbnail", 1, 1, empty.data(), empty.size()));
    const auto cleared = source.Parse("$mediaThumbnail");
    const auto version = source.Version("$mediaThumbnail");
    EXPECT_FALSE(PublishSystemMediaArtwork(source, 0, 0, nullptr, 0));
    EXPECT_EQ(source.Version("$mediaThumbnail"), version);
    EXPECT_EQ(source.Parse("$mediaPreviousThumbnail"), cleared);
    EXPECT_FALSE(PublishSystemMediaArtwork(source, 0, 1, nullptr, 0));
    EXPECT_FALSE(PublishSystemMediaArtwork(source, 2, 2, first.data(), first.size()));
    EXPECT_EQ(source.Version("$mediaThumbnail"), version);
    ASSERT_TRUE(PublishSystemMediaArtwork(source, 1, 1, first.data(), first.size()));
    EXPECT_EQ(source.Parse("$mediaPreviousThumbnail"), cleared);
}

// What a cover layer ships in the slot a cover is bound to: pictures by name,
// each of them one 4x4 block of its own byte, decoded on demand and counted.
class AuthoredPictures final : public IImageParser {
public:
    int parse_calls { 0 };
    int header_calls { 0 };

    void Add(const std::string& name, uint8_t fill, bool video = false, bool sprite = false,
             TextureFormat format = TextureFormat::BC3) {
        m_pictures[name] = Picture { fill, video, sprite, true, format };
    }
    /// A file whose header reads but whose pixels do not decode.
    void AddUndecodable(const std::string& name) {
        m_pictures[name] = Picture { 0, false, false, false, TextureFormat::BC3 };
    }

    std::shared_ptr<Image> Parse(const std::string& name) override {
        ++parse_calls;
        const auto picture = m_pictures.find(name);
        if (picture == m_pictures.end() || ! picture->second.decodes) return nullptr;
        auto image    = std::make_shared<Image>();
        image->key    = name;
        image->header = HeaderOf(picture->second);
        Image::Slot slot;
        slot.width  = 4;
        slot.height = 4;
        ImageData mip;
        mip.width  = 4;
        mip.height = 4;
        mip.size   = 16;
        mip.data   = ImageDataPtr(new uint8_t[16], [](uint8_t* data) { delete[] data; });
        std::memset(mip.data.get(), picture->second.fill, 16);
        slot.mipmaps.push_back(std::move(mip));
        image->slots.push_back(std::move(slot));
        return image;
    }

    ImageHeader ParseHeader(const std::string& name) override {
        ++header_calls;
        const auto picture = m_pictures.find(name);
        return picture == m_pictures.end() ? ImageHeader {} : HeaderOf(picture->second);
    }

private:
    struct Picture {
        uint8_t fill { 0 };
        bool    video { false };
        bool    sprite { false };
        bool    decodes { true };
        TextureFormat format { TextureFormat::BC3 };
    };

    static ImageHeader HeaderOf(const Picture& picture) {
        ImageHeader header;
        header.width     = header.mapWidth  = 4;
        header.height    = header.mapHeight = 4;
        header.count     = 1;
        header.format    = picture.format;
        header.isVideo   = picture.video;
        header.isSprite  = picture.sprite;
        return header;
    }

    std::map<std::string, Picture> m_pictures;
};

uint8_t FirstByte(const std::shared_ptr<Image>& image) {
    return image != nullptr && ! image->slots.empty() && ! image->slots[0].mipmaps.empty() &&
                   image->slots[0].mipmaps[0].data != nullptr
               ? image->slots[0].mipmaps[0].data.get()[0]
               : uint8_t { 0xEE };
}

TEST(CoverSlot, ShowsTheAuthoredPictureUntilACoverIsPublishedAndAfterItIsCleared) {
    auto* parser = new AuthoredPictures();
    parser->Add("art", 0x5A);
    RuntimeImageSource source { std::unique_ptr<IImageParser>(parser) };

    const auto slot = source.BindCoverSlot("$mediaThumbnail", "art");
    ASSERT_NE(slot, "$mediaThumbnail");
    EXPECT_TRUE(source.IsRuntimeImage(slot)) << "a renderer would never refresh the slot";
    // The header a material reads while it loads is the authored picture's.
    EXPECT_EQ(source.ParseHeader(slot).format, TextureFormat::BC3);
    EXPECT_EQ(source.ParseHeader(slot).width, 4);

    const auto idle = source.Parse(slot);
    ASSERT_NE(idle, nullptr);
    EXPECT_EQ(FirstByte(idle), 0x5A) << "no track is playing, so the author's art shows";
    const auto idle_version = source.Version(slot);
    EXPECT_NE(idle_version, 0u);

    const std::vector<uint8_t> cover { 0x11, 0x22, 0x33, 0xFF };
    ASSERT_TRUE(PublishSystemMediaArtwork(source, 1, 1, cover.data(), cover.size()));
    const auto showing = source.Parse(slot);
    EXPECT_EQ(showing, source.Parse("$mediaThumbnail")) << "the slot must show the track's cover";
    EXPECT_EQ(FirstByte(showing), 0x11);
    EXPECT_GT(source.Version(slot), idle_version) << "a renderer would not notice the cover";
    // Its header is still the authored picture's: a material's size and format
    // constants were fixed from it before any track played.
    EXPECT_EQ(source.ParseHeader(slot).format, TextureFormat::BC3);

    const auto showing_version = source.Version(slot);
    ASSERT_TRUE(PublishSystemMediaArtwork(source, 0, 0, nullptr, 0));
    const auto cleared_version = source.Version(slot);
    EXPECT_GT(cleared_version, showing_version) << "a renderer would not notice the clear";
    EXPECT_EQ(source.Parse(slot), idle) << "the explicit clear brings the author's art back";
    EXPECT_EQ(parser->parse_calls, 1) << "the art was decoded again instead of kept";

    // A replay of the clear changes nothing, and so does reading the slot.
    EXPECT_FALSE(PublishSystemMediaArtwork(source, 0, 0, nullptr, 0));
    for (int i = 0; i < 50; ++i) (void)source.Parse(slot);
    EXPECT_EQ(source.Version(slot), cleared_version);
    EXPECT_EQ(parser->parse_calls, 1);
}

TEST(CoverSlot, ThePreviousCoverSlotStaysOnItsAuthoredPictureUntilThereIsAPreviousCover) {
    auto* parser = new AuthoredPictures();
    parser->Add("black", 0x10);
    RuntimeImageSource source { std::unique_ptr<IImageParser>(parser) };
    const auto         slot = source.BindCoverSlot("$mediaPreviousThumbnail", "black");
    ASSERT_NE(slot, "$mediaPreviousThumbnail");
    EXPECT_EQ(FirstByte(source.Parse(slot)), 0x10);

    const std::vector<uint8_t> first { 0x21, 0x22, 0x23, 0xFF };
    const std::vector<uint8_t> second { 0x31, 0x32, 0x33, 0xFF };
    // The first track has nothing before it: what it replaced was the empty cover.
    ASSERT_TRUE(PublishSystemMediaArtwork(source, 1, 1, first.data(), first.size()));
    EXPECT_EQ(FirstByte(source.Parse(slot)), 0x10);
    const auto before = source.Version(slot);
    // The second one fades from the first.
    ASSERT_TRUE(PublishSystemMediaArtwork(source, 1, 1, second.data(), second.size()));
    EXPECT_EQ(FirstByte(source.Parse(slot)), 0x21);
    EXPECT_GT(source.Version(slot), before);
}

TEST(CoverSlot, KeepsTheCoverNameWhenThereIsNothingToStandInForIt) {
    auto* parser = new AuthoredPictures();
    parser->Add("art", 1);
    parser->Add("clip", 2, true);
    parser->Add("sheet", 3, false, true);
    parser->Add("mask", 4, false, false, TextureFormat::R8);
    parser->Add("normal", 5, false, false, TextureFormat::RG8);
    parser->Add("plain", 6, false, false, TextureFormat::RGBA8);
    RuntimeImageSource source { std::unique_ptr<IImageParser>(parser) };

    EXPECT_EQ(source.BindCoverSlot("$mediaThumbnail", ""), "$mediaThumbnail");
    EXPECT_EQ(source.BindCoverSlot("$mediaThumbnail", "missing"), "$mediaThumbnail");
    EXPECT_EQ(source.BindCoverSlot("$mediaThumbnail", "clip"), "$mediaThumbnail")
        << "a video is not a picture a cover can stand in for";
    EXPECT_EQ(source.BindCoverSlot("$mediaThumbnail", "sheet"), "$mediaThumbnail");
    // A material is compiled to read a one- or two-channel picture through those
    // channels, which is not how it reads a track's RGBA cover.
    EXPECT_EQ(source.BindCoverSlot("$mediaThumbnail", "mask"), "$mediaThumbnail");
    EXPECT_EQ(source.BindCoverSlot("$mediaThumbnail", "normal"), "$mediaThumbnail");
    EXPECT_NE(source.BindCoverSlot("$mediaThumbnail", "plain"), "$mediaThumbnail")
        << "art stored as plain RGBA is a picture like any other";
    EXPECT_EQ(source.BindCoverSlot("materials/other.tex", "art"), "materials/other.tex")
        << "only the two cover names are slots";
    EXPECT_EQ(parser->parse_calls, 0);

    RuntimeImageSource bare { nullptr };
    EXPECT_EQ(bare.BindCoverSlot("$mediaThumbnail", "art"), "$mediaThumbnail");
}

TEST(CoverSlot, OneSlotPerCoverAndAuthoredPicture) {
    auto* parser = new AuthoredPictures();
    parser->Add("one", 1);
    parser->Add("two", 2);
    RuntimeImageSource source { std::unique_ptr<IImageParser>(parser) };
    const auto         generation = source.NamesGeneration();

    const auto first = source.BindCoverSlot("$mediaThumbnail", "one");
    EXPECT_NE(source.NamesGeneration(), generation) << "a renderer keeps its per-slot answers";
    const auto joined = source.NamesGeneration();
    EXPECT_EQ(source.BindCoverSlot("$mediaThumbnail", "one"), first);
    EXPECT_EQ(source.NamesGeneration(), joined);
    EXPECT_NE(source.BindCoverSlot("$mediaThumbnail", "two"), first);
    EXPECT_NE(source.BindCoverSlot("$mediaPreviousThumbnail", "one"), first);
    // Never removed with the layers a script makes and destroys.
    EXPECT_FALSE(source.RemoveImage(first));
    EXPECT_TRUE(source.IsRuntimeImage(first));
}

TEST(CoverSlot, DecodesTheAuthoredPictureOnlyWhenARendererAsksAndOnlyOnce) {
    auto* parser = new AuthoredPictures();
    parser->Add("art", 7);
    RuntimeImageSource source { std::unique_ptr<IImageParser>(parser) };
    const auto         slot = source.BindCoverSlot("$mediaThumbnail", "art");
    (void)source.IsRuntimeImage(slot);
    (void)source.Version(slot);
    (void)source.ParseHeader(slot);
    EXPECT_EQ(parser->parse_calls, 0) << "decoded while the scene loaded, before any texture budget";
    const auto first = source.Parse(slot);
    for (int i = 0; i < 100; ++i) EXPECT_EQ(source.Parse(slot), first);
    EXPECT_EQ(parser->parse_calls, 1);
}

TEST(CoverSlot, AnAuthoredPictureThatCannotBeDecodedLeavesTheCoverAsItWas) {
    auto* parser = new AuthoredPictures();
    parser->AddUndecodable("broken");
    RuntimeImageSource source { std::unique_ptr<IImageParser>(parser) };
    const auto         slot = source.BindCoverSlot("$mediaThumbnail", "broken");
    ASSERT_NE(slot, "$mediaThumbnail");
    // The slot still answers, with the cover's own transparent texel.
    EXPECT_EQ(source.Parse(slot), source.Parse("$mediaThumbnail"));
    EXPECT_EQ(parser->parse_calls, 1) << "a file that cannot be read was read again every frame";
    const std::vector<uint8_t> cover { 0x41, 0x42, 0x43, 0xFF };
    ASSERT_TRUE(PublishSystemMediaArtwork(source, 1, 1, cover.data(), cover.size()));
    EXPECT_EQ(source.Parse(slot), source.Parse("$mediaThumbnail"));
}

TEST(CoverSlot, ASystemSlotKeepsItsAuthoredTextureWhenCoversAreGiven) {
    auto* parser = new AuthoredPictures();
    parser->Add("art", 0x33);
    RuntimeImageSource source { std::unique_ptr<IImageParser>(parser) };

    const std::vector<wpscene::WPUserTexture> usertextures {
        { .name = "$mediaThumbnail", .type = "system" },
        { .name = "$mediaPreviousThumbnail", .type = "system" },
    };
    std::vector<std::string> textures { "art", "_rt_imageLayerComposite_3_a" };
    ApplySystemUserTextures(textures, usertextures, nullptr, &source);
    ASSERT_EQ(textures.size(), 2u);
    EXPECT_NE(textures[0], "$mediaThumbnail");
    EXPECT_EQ(FirstByte(source.Parse(textures[0])), 0x33);
    EXPECT_EQ(textures[1], "$mediaPreviousThumbnail")
        << "another layer's composite is not a picture the source can hold";

    // No authored texture in the slot: the cover alone.
    std::vector<std::string> empty { "" };
    ApplySystemUserTextures(empty, { usertextures[0] }, nullptr, &source);
    EXPECT_EQ(empty[0], "$mediaThumbnail");
    std::vector<std::string> none;
    ApplySystemUserTextures(none, { usertextures[0] }, nullptr, &source);
    ASSERT_EQ(none.size(), 1u);
    EXPECT_EQ(none[0], "$mediaThumbnail");

    // Without a source to bind through it names the cover, as it always has.
    std::vector<std::string> unbound { "art" };
    ApplySystemUserTextures(unbound, { usertextures[0] });
    EXPECT_EQ(unbound[0], "$mediaThumbnail");
}

} // namespace
} // namespace wallpaper
