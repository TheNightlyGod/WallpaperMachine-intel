// The .tex container, loose pictures, packages and scene sources behind the texture parser.
#include <sys/stat.h>

#include <algorithm>
#include <cmath>
#include <filesystem>
#include <limits>

#include <gtest/gtest.h>

#include "Runtime/RuntimeImageSource.hpp"
#include "SceneSourceResolver.hpp"
#include "WPPkgFs.hpp"
#include "tex_fixtures.hpp"

using namespace wallpaper;
using namespace textest;

namespace
{

Blob redPng(uint8_t red) { return png1x1(red, 2, 3, 255); }

ImageHeader headerOf(Rig& rig, const std::string& name = "sample") { return rig->ParseHeader(name); }

// The container as a texture named "sample".
Rig texRig(const Container& c) { return rigForTex(build(c)); }

// TEXB2 chain of raw RGBA levels whose marks are the longest sides given.
Container rawChain(std::vector<int> sides, uint32_t flags = 0) {
    Container c;
    c.texb  = 2;
    c.flags = flags;
    c.width = c.mapWidth = c.height = c.mapHeight = sides.front();
    PictureSpec pic;
    for (int s : sides) pic.levels.push_back(rawLevel(s, s, static_cast<uint8_t>(s)));
    c.pictures.push_back(pic);
    return c;
}

// A sprite container: one picture with a single raw 1x1 level, then `tail`.
Container spriteContainer(std::optional<SpriteTail> tail) {
    Container c(2, { rawLevel(1, 1, 0xFF) });
    c.flags = kSprite;
    c.tail  = std::move(tail);
    return c;
}

SpriteTail tailOf(int version, std::vector<SpriteRow> rows) {
    SpriteTail t;
    t.version = version;
    t.rows    = std::move(rows);
    return t;
}

} // namespace

// ---------------------------------------------------------------------------------------------
// Container header
// ---------------------------------------------------------------------------------------------

TEST(TexContainer, HeaderLayoutForEveryContainerVersion) {
    for (int texb = 1; texb <= 4; ++texb) {
        SCOPED_TRACE("TEXB000" + std::to_string(texb));
        const Blob png = png1x1(10, 20, 30, 255);
        Container c(texb, { levelOf(1, 1, png) });
        c.type  = 13;
        auto rig = texRig(c);
        const auto h = headerOf(rig);
        EXPECT_EQ(h.extraHeader.at("texb").val, texb);
        EXPECT_EQ(h.extraHeader.at("texv").val, 5);
        EXPECT_EQ(h.extraHeader.at("texi").val, 1);
        EXPECT_EQ(h.count, 1);
        EXPECT_EQ(h.width, 8);
        EXPECT_EQ(h.height, 8);
        EXPECT_EQ(h.type, texb >= 3 ? ImageType::PNG : ImageType::UNKNOWN);
        EXPECT_EQ(h.extraHeader.count("texb_reserved"), texb == 4 ? 1u : 0u);
        EXPECT_FALSE(h.mipmap_pow2);

        const auto image = rig->Parse("sample");
        ASSERT_NE(image, nullptr);
        ASSERT_EQ(image->slots.size(), 1u);
        ASSERT_EQ(image->slots[0].mipmaps.size(), 1u);
        EXPECT_EQ(image->slots[0].width, 1);
        if (texb >= 3) {
            EXPECT_EQ(image->slots[0].mipmaps[0].size, 4);
            EXPECT_EQ(image->header.type, ImageType::PNG);
        } else {
            EXPECT_EQ(image->slots[0].mipmaps[0].size, static_cast<isize>(png.size()));
        }
    }
}

TEST(TexContainer, ReservedWordIsNeitherAFlagNorABodyOffset) {
    for (int word : { 12345, 0, 32, -1, 1 }) {
        SCOPED_TRACE("reserved " + std::to_string(word));
        Container c(4, { levelOf(1, 1, redPng(77)) });
        c.type     = 13;
        c.reserved = word;
        auto rig   = texRig(c);
        const auto h = headerOf(rig);
        EXPECT_FALSE(h.isVideo);
        EXPECT_EQ(h.type, ImageType::PNG);
        EXPECT_EQ(h.extraHeader.at("texb_reserved").val, word);
        EXPECT_FALSE(h.mipmap_pow2);
        const auto image = rig->Parse("sample");
        ASSERT_NE(image, nullptr);
        ASSERT_EQ(image->slots.size(), 1u);
        ASSERT_EQ(image->slots[0].mipmaps.size(), 1u);
        EXPECT_EQ(image->slots[0].width, 1);
        EXPECT_EQ(image->slots[0].height, 1);
        EXPECT_EQ(image->slots[0].mipmaps[0].data.get()[0], 77);
    }
}

TEST(TexContainer, EmptyLevelTablesGiveAHeaderButNoImage) {
    for (int texb : { 3, 1, 2, 4 }) {
        SCOPED_TRACE("TEXB000" + std::to_string(texb));
        Container c;
        c.texb = texb;
        c.pictures.push_back({ {}, std::nullopt });
        auto rig = texRig(c);
        const auto h = headerOf(rig);
        EXPECT_EQ(h.count, 1);
        EXPECT_FALSE(h.mipmap_pow2);
        EXPECT_FALSE(h.mipmap_larger);
        EXPECT_FALSE(h.isVideo);
        EXPECT_EQ(rig->Parse("sample"), nullptr);
    }
    // Level counts that cannot be true, with a real payload behind them.
    for (int declared : { -1, 1000000000 }) {
        SCOPED_TRACE("declared levels " + std::to_string(declared));
        Container c(3, { rawLevel(1, 1, 5) });
        c.pictures[0].declaredLevels = declared;
        auto rig = texRig(c);
        const auto h = headerOf(rig);
        EXPECT_EQ(h.count, 1);
        EXPECT_FALSE(h.mipmap_pow2);
        EXPECT_FALSE(h.mipmap_larger);
        EXPECT_EQ(rig->Parse("sample"), nullptr);
    }
    {
        Container c;
        c.texb = 3;
        auto rig = texRig(c);
        EXPECT_EQ(headerOf(rig).count, 0);
        EXPECT_EQ(rig->Parse("sample"), nullptr);
    }

    // The first level against the map: (width, height) -> (power of two, larger than the map).
    struct Row {
        int  w, h;
        bool pow2, larger;
    };
    // (2, 4) is larger by area with an equal width; (4, 1) is wider with an equal area.
    const Row rows[] = { { 1, 1, false, false }, { 4, 2, true, true },  { 2, 2, true, false },
                         { 3, 4, false, true },  { 4, 3, false, true }, { 2, 4, true, true },
                         { 4, 1, false, false } };
    for (const auto& r : rows) {
        SCOPED_TRACE(std::to_string(r.w) + "x" + std::to_string(r.h));
        Container c(2, { rawLevel(r.w, r.h, 1) });
        c.mapWidth = c.mapHeight = 2;
        auto rig = texRig(c);
        const auto h = headerOf(rig);
        EXPECT_EQ(h.mipmap_pow2, r.pow2);
        EXPECT_EQ(h.mipmap_larger, r.larger);
    }
}

// ---------------------------------------------------------------------------------------------
// Recognising what a level's bytes are
// ---------------------------------------------------------------------------------------------

TEST(TexContainer, UndeclaredTypeDecodesRealPicturesAndKeepsRawPixels) {
    struct Row {
        const char* what;
        Blob        payload;
        ImageType   type;
        uint8_t     pixel[4];
    };
    const Row rows[] = {
        { "png", png1x1(10, 20, 30, 255), ImageType::PNG, { 10, 20, 30, 255 } },
        { "gif", gif1x1({ 10, 20, 30 }, { 200, 100, 50 }, 1), ImageType::GIF, { 200, 100, 50, 255 } },
        { "bmp", bmp1x1(90, 60, 30), ImageType::BMP, { 90, 60, 30, 255 } },
    };
    for (const auto& r : rows) {
        SCOPED_TRACE(r.what);
        ASSERT_GT(r.payload.size(), 4u);
        Container c(3, { levelOf(1, 1, r.payload) });
        auto rig = texRig(c);
        const auto image = rig->Parse("sample");
        ASSERT_NE(image, nullptr);
        EXPECT_EQ(image->header.type, r.type);
        EXPECT_EQ(image->header.format, TextureFormat::RGBA8);
        ASSERT_EQ(image->slots.size(), 1u);
        ASSERT_EQ(image->slots[0].mipmaps.size(), 1u);
        EXPECT_EQ(image->slots[0].mipmaps[0].size, 4);
        for (int i = 0; i < 4; ++i) EXPECT_EQ(image->slots[0].mipmaps[0].data.get()[i], r.pixel[i]) << i;
        EXPECT_EQ(headerOf(rig).type, r.type);
    }
    {
        // Exactly the raw size: the bytes are pixels even though they start like a JPEG.
        Container c(3, { levelOf(1, 1, jpegMarker()) });
        auto rig = texRig(c);
        const auto image = rig->Parse("sample");
        ASSERT_NE(image, nullptr);
        EXPECT_EQ(image->header.type, ImageType::UNKNOWN);
        ASSERT_EQ(image->slots[0].mipmaps.size(), 1u);
        EXPECT_EQ(image->slots[0].mipmaps[0].size, 4);
        EXPECT_EQ(image->slots[0].mipmaps[0].data.get()[1], 0xD8);
    }
    {
        // Shorter than the raw size and not a picture.
        Container c(3, { levelOf(1, 1, { 1, 2, 3 }) });
        auto rig = texRig(c);
        EXPECT_EQ(rig->Parse("sample"), nullptr);
    }
}

TEST(TexContainer, HeaderOnlyRecognitionOfPictureMarkers) {
    struct Row {
        const char* what;
        int         texb;
        int         declared;
        Blob        payload;
        ImageType   want;
    };
    const Row rows[] = {
        { "jpeg marker", 3, -1, jpegMarker(), ImageType::JPEG },
        { "bmp", 3, -1, bmp1x1(1, 2, 3), ImageType::BMP },
        { "tiff marker", 3, -1, tiffMarker(), ImageType::TIFF },
        { "png", 3, -1, png1x1(1, 2, 3, 4), ImageType::PNG },
        { "gif", 3, -1, gif1x1({ 1, 2, 3 }, { 4, 5, 6 }, 0), ImageType::GIF },
        { "tiff in TEXB4", 4, -1, tiffMarker(), ImageType::TIFF },
        { "tiff in TEXB2", 2, -1, tiffMarker(), ImageType::UNKNOWN },
        { "declared wins", 3, 2, tiffMarker(), ImageType::JPEG },
    };
    for (const auto& r : rows) {
        SCOPED_TRACE(r.what);
        Container c(r.texb, { levelOf(1, 1, r.payload) });
        c.type = r.declared;
        auto rig = texRig(c);
        const auto h = headerOf(rig);
        EXPECT_EQ(h.type, r.want);
        EXPECT_FALSE(h.isVideo);
    }
}

TEST(TexContainer, VideoMarkersInAnUndeclaredTypeContainer) {
    for (const auto& marker : { mp4Marker(), webmMarker() }) {
        SCOPED_TRACE(marker.size() == 16 ? "mp4" : "webm");
        Container c(3, { levelOf(1, 1, marker) });
        auto rig = texRig(c);
        const auto h = headerOf(rig);
        EXPECT_TRUE(h.isVideo);
        EXPECT_EQ(h.type, ImageType::UNKNOWN);
        EXPECT_EQ(h.durationSeconds, 0.0);
        const auto image = rig->Parse("sample");
        ASSERT_NE(image, nullptr);
        EXPECT_TRUE(image->header.isVideo);
        ASSERT_EQ(image->slots.size(), 1u);
        ASSERT_EQ(image->slots[0].mipmaps.size(), 1u);
        EXPECT_EQ(image->slots[0].mipmaps[0].size, static_cast<isize>(marker.size()));
    }
    {
        Blob cut = mp4Marker();
        cut.resize(11);
        Container c(3, { levelOf(1, 1, cut) });
        auto rig = texRig(c);
        EXPECT_FALSE(headerOf(rig).isVideo);
    }
    {
        Container c(3, { levelOf(1, 1, mp4Marker()) });
        c.type = 13;
        auto rig = texRig(c);
        EXPECT_FALSE(headerOf(rig).isVideo);
    }
    {
        Container c(2, { levelOf(1, 1, { 1, 2, 3 }) });
        c.flags = kVideo;
        auto rig = texRig(c);
        EXPECT_TRUE(headerOf(rig).isVideo);
    }
}

TEST(TexContainer, SniffingNeverTrustsAPayloadLargerThanTheFile) {
    LevelSpec l;
    l.width  = l.height = 1;
    l.stored = 4096;
    Container c(3, { l });
    auto rig = guardRigFor(build(c));
    ImageHeader h;
    ASSERT_NO_THROW(h = rig.parser->ParseHeader("sample"));
    EXPECT_EQ(h.type, ImageType::UNKNOWN);
    EXPECT_FALSE(h.isVideo);
    EXPECT_LE(*rig.biggestRead, 64u);
    EXPECT_EQ(rig.parser->Parse("sample"), nullptr);
}

TEST(TexContainer, CompressedPayloadIsNotExpandedJustToSniffIt) {
    Blob raw(4096, 0);
    const Blob marker = mp4Marker();
    std::copy(marker.begin(), marker.end(), raw.begin());
    Container c(3, { lz4Level(1, 1, raw) });
    auto rig = guardRigFor(build(c));
    ImageHeader h;
    ASSERT_NO_THROW(h = rig.parser->ParseHeader("sample"));
    EXPECT_EQ(h.type, ImageType::UNKNOWN);
    EXPECT_FALSE(h.isVideo);
    EXPECT_LE(*rig.biggestRead, 64u);
    // The full load does expand it and recognises the clip.
    const auto image = rig.parser->Parse("sample");
    ASSERT_NE(image, nullptr);
    EXPECT_TRUE(image->header.isVideo);
}

TEST(TexContainer, VideoFlagWithCompressedPayloadTakesTheMetadataPath) {
    Blob raw(4096);
    for (size_t i = 0; i < raw.size(); ++i) raw[i] = static_cast<uint8_t>((i * 37 + i / 3) & 0xFF);
    const Blob marker = mp4Marker();
    std::copy(marker.begin(), marker.end(), raw.begin());
    Container c(3, { lz4Level(1, 1, raw) });
    c.flags = kVideo;
    auto rig = guardRigFor(build(c));
    ImageHeader h;
    ASSERT_NO_THROW(h = rig.parser->ParseHeader("sample"));
    EXPECT_TRUE(h.isVideo);
    // This path is the one allowed to read the whole compressed level.
    EXPECT_GT(*rig.biggestRead, 64u);
    EXPECT_EQ(h.durationSeconds, 0.0);

    // An uncompressed payload with the flag is a video too.
    Container plain(3, { levelOf(1, 1, Blob(300, 7)) });
    plain.flags = kVideo;
    auto plainRig = texRig(plain);
    EXPECT_TRUE(headerOf(plainRig).isVideo);
}

// ---------------------------------------------------------------------------------------------
// Sprite sheets
// ---------------------------------------------------------------------------------------------

TEST(TexSprite, FrameRowsNamingImpossiblePicturesAreSkipped) {
    // -1 and 2 are out of range; 1 is one past the only picture.
    const std::vector<SpriteRow> rows { { -1 }, { 2 }, { 1 }, { 0 } };
    {
        auto rig = texRig(spriteContainer(tailOf(2, rows)));
        const auto h = headerOf(rig);
        EXPECT_TRUE(h.isSprite);
        ASSERT_EQ(h.spriteAnim.numFrames(), 1u);
        EXPECT_EQ(h.spriteAnim.GetCurFrame().imageId, 0);
        const auto image = rig->Parse("sample");
        ASSERT_NE(image, nullptr);
        EXPECT_EQ(image->header.spriteAnim.numFrames(), 1u);
    }

    // Frame arithmetic for every table version.
    for (int version : { 1, 2, 3, 4 }) {
        SCOPED_TRACE("TEXS000" + std::to_string(version));
        Container c;
        c.texb  = 2;
        c.flags = kSprite;
        c.pictures.push_back({ { rawLevel(8, 4, 1) }, std::nullopt });
        c.pictures.push_back({ { rawLevel(2, 2, 2) }, std::nullopt });
        c.tail = tailOf(version, { { 0, 0.5f, { 2, 1, 4, 0, 0, 2 } },
                                   { 1, 0.25f, { 1, 0, 1, 0, 0, 2 } },
                                   { 1, 0.0f, { 0, 0, 0, 0, 0, 0 } } });
        auto rig = texRig(c);
        const auto h = headerOf(rig);
        ASSERT_EQ(h.spriteAnim.numFrames(), 3u);
        struct Want {
            int   image;
            float time, x, y, xa0, xa1, ya0, ya1, w, h, rate;
        };
        const Want want[] = {
            { 0, 0.5f, 0.25f, 0.25f, 0.5f, 0, 0, 0.5f, 4, 2, 0.5f },
            { 1, 0.25f, 0.5f, 0, 0.5f, 0, 0, 1, 1, 2, 2 },
            { 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 },
        };
        for (size_t i = 0; i < 3; ++i) {
            SCOPED_TRACE("frame " + std::to_string(i));
            const auto& f = h.spriteAnim.FrameAt(i);
            EXPECT_EQ(f.imageId, want[i].image);
            EXPECT_FLOAT_EQ(f.frametime, want[i].time);
            EXPECT_FLOAT_EQ(f.x, want[i].x);
            EXPECT_FLOAT_EQ(f.y, want[i].y);
            EXPECT_FLOAT_EQ(f.xAxis[0], want[i].xa0);
            EXPECT_FLOAT_EQ(f.xAxis[1], want[i].xa1);
            EXPECT_FLOAT_EQ(f.yAxis[0], want[i].ya0);
            EXPECT_FLOAT_EQ(f.yAxis[1], want[i].ya1);
            EXPECT_FLOAT_EQ(f.width, want[i].w);
            EXPECT_FLOAT_EQ(f.height, want[i].h);
            EXPECT_FLOAT_EQ(f.rate, want[i].rate);
        }
        const auto image = rig->Parse("sample");
        ASSERT_NE(image, nullptr);
        EXPECT_EQ(image->slots.size(), 2u);
        ASSERT_EQ(image->header.spriteAnim.numFrames(), 3u);
        EXPECT_FLOAT_EQ(image->header.spriteAnim.FrameAt(0).width, 4);
        EXPECT_FLOAT_EQ(image->header.spriteAnim.FrameAt(1).rate, 2);
    }
}

TEST(TexSprite, SpriteWithAnEmptyLevelTableYieldsNoFrames) {
    Container c;
    c.texb  = 2;
    c.flags = kSprite;
    c.pictures.push_back({ {}, std::nullopt });
    c.tail = tailOf(2, { { -1 }, { 2 }, { 0 } });
    auto rig = texRig(c);
    const auto h = headerOf(rig);
    EXPECT_TRUE(h.isSprite);
    EXPECT_EQ(h.spriteAnim.numFrames(), 0u);
    EXPECT_EQ(rig->Parse("sample"), nullptr);

    {
        auto empty = texRig(spriteContainer(tailOf(2, {})));
        EXPECT_EQ(headerOf(empty).spriteAnim.numFrames(), 0u);
    }
    {
        auto absent = texRig(spriteContainer(std::nullopt));
        const auto ah = headerOf(absent);
        EXPECT_TRUE(ah.isSprite);
        EXPECT_EQ(ah.spriteAnim.numFrames(), 0u);
    }
    {
        // Five rows are announced but only one follows.
        SpriteTail t = tailOf(2, { { 0 } });
        t.declaredRows = 5;
        auto lying = texRig(spriteContainer(t));
        EXPECT_EQ(headerOf(lying).spriteAnim.numFrames(), 1u);
    }
}

// ---------------------------------------------------------------------------------------------
// Surface budget
// ---------------------------------------------------------------------------------------------

namespace
{
void expectKept(const std::shared_ptr<Image>& image, int firstSide, size_t levels) {
    ASSERT_NE(image, nullptr);
    ASSERT_EQ(image->slots.size(), 1u);
    ASSERT_EQ(image->slots[0].mipmaps.size(), levels);
    EXPECT_EQ(image->slots[0].width, firstSide);
    EXPECT_EQ(image->slots[0].height, firstSide);
    EXPECT_EQ(image->slots[0].mipmaps[0].size, static_cast<isize>(firstSide) * firstSide * 4);
    EXPECT_EQ(image->slots[0].mipmaps[0].data.get()[0], firstSide);
}
} // namespace

TEST(TexBudget, SurfacePicksAuthoredLevelsAndKeepsLayoutMetadata) {
    auto rig = texRig(rawChain({ 8, 4, 2 }));
    RuntimeImageSource source(std::make_unique<WPTexImageParser>(rig.vfs.get()));
    struct Row {
        uint32_t surface;
        int      kept;
    };
    for (const Row r : { Row { 0, 8 }, Row { 3, 4 }, Row { 5, 8 }, Row { 1, 2 }, Row { 0, 8 } }) {
        SCOPED_TRACE("surface " + std::to_string(r.surface));
        source.SetTextureSurfaceSize(r.surface, r.surface);
        const auto image = source.Parse("sample");
        ASSERT_NE(image, nullptr);
        ASSERT_EQ(image->slots.size(), 1u);
        ASSERT_FALSE(image->slots[0].mipmaps.empty());
        EXPECT_EQ(image->slots[0].width, r.kept);
        EXPECT_EQ(image->slots[0].height, r.kept);
        EXPECT_EQ(image->slots[0].mipmaps[0].size, static_cast<isize>(r.kept) * r.kept * 4);
        EXPECT_EQ(image->slots[0].mipmaps[0].data.get()[0], r.kept);
        EXPECT_EQ(image->header.width, 8);
        EXPECT_EQ(image->header.mapWidth, 8);
        EXPECT_EQ(source.ParseHeader("sample").width, 8);
    }

    // A longer chain, through the source and straight on the parser.
    auto longRig = texRig(rawChain({ 16, 8, 4, 2 }));
    RuntimeImageSource longSource(std::make_unique<WPTexImageParser>(longRig.vfs.get()));
    struct Longer {
        uint32_t surface;
        int      kept;
        size_t   levels;
    };
    const Longer longer[] = { { 0, 16, 4 }, { 5, 8, 3 },  { 9, 16, 4 }, { 16, 16, 4 },
                              { 17, 16, 4 }, { 1, 2, 1 }, { 3, 4, 2 },  { 4, 4, 2 } };
    for (const auto& r : longer) {
        SCOPED_TRACE("long chain, surface " + std::to_string(r.surface));
        longSource.SetTextureSurfaceSize(r.surface, r.surface);
        expectKept(longSource.Parse("sample"), r.kept, r.levels);
        longRig->SetTextureSurfaceSize(r.surface, r.surface);
        expectKept(longRig->Parse("sample"), r.kept, r.levels);
    }
    auto three = texRig(rawChain({ 16, 8, 4 }));
    three->SetTextureSurfaceSize(7, 3);
    expectKept(three->Parse("sample"), 8, 2);
    three->SetTextureSurfaceSize(3, 0);
    expectKept(three->Parse("sample"), 16, 3);
    three->SetTextureSurfaceSize(0, 5);
    expectKept(three->Parse("sample"), 16, 3);
}

TEST(TexBudget, DroppedEncodedLevelsAreSkippedButALyingSizeStillFails) {
    const Blob junk(256, 0x08);
    const auto build2 = [&](std::optional<int> stored) {
        Container c;
        c.texb = 3;
        c.type = 13;
        LevelSpec a = levelOf(8, 8, junk);
        LevelSpec b = levelOf(1, 1, png1x1(200, 100, 50, 255));
        a.stored = stored;
        b.stored = stored;
        c.pictures.push_back({ { a, b }, std::nullopt });
        return c;
    };
    {
        auto rig = texRig(build2(std::nullopt));
        EXPECT_EQ(rig->Parse("sample"), nullptr); // level A really cannot be decoded
        rig->SetTextureSurfaceSize(1, 1);
        const auto image = rig->Parse("sample");
        ASSERT_NE(image, nullptr);
        ASSERT_EQ(image->slots.size(), 1u);
        ASSERT_EQ(image->slots[0].mipmaps.size(), 1u);
        EXPECT_EQ(image->slots[0].width, 1);
        const uint8_t want[4] = { 200, 100, 50, 255 };
        for (int i = 0; i < 4; ++i) EXPECT_EQ(image->slots[0].mipmaps[0].data.get()[i], want[i]);
    }
    {
        auto rig = texRig(build2(65536));
        rig->SetTextureSurfaceSize(1, 1);
        EXPECT_EQ(rig->Parse("sample"), nullptr);
    }
    {
        // A level to be dropped is still a level: a header without a size is not believed.
        Container c = build2(std::nullopt);
        c.pictures[0].levels[0].width = 0;
        auto rig = texRig(c);
        rig->SetTextureSurfaceSize(1, 1);
        EXPECT_EQ(rig->Parse("sample"), nullptr);
    }
}

TEST(TexBudget, SpriteAndVideoTexturesKeepTheirWholeChain) {
    for (uint32_t flag : { kSprite, kVideo }) {
        SCOPED_TRACE(flag == kSprite ? "sprite" : "video");
        auto rig = texRig(rawChain({ 8, 4, 2 }, flag));
        rig->SetTextureSurfaceSize(1, 1);
        const auto image = rig->Parse("sample");
        ASSERT_NE(image, nullptr);
        ASSERT_FALSE(image->slots.empty());
        EXPECT_EQ(image->slots.front().width, 8);
        EXPECT_EQ(image->slots.front().mipmaps.size(), 3u);
    }
    {
        // Raw payloads in TEXB3 with no declared type.
        Container c = rawChain({ 8, 4, 2 });
        c.texb = 3;
        auto rig = texRig(c);
        rig->SetTextureSurfaceSize(1, 1);
        const auto image = rig->Parse("sample");
        ASSERT_NE(image, nullptr);
        EXPECT_EQ(image->slots.front().width, 8);
        EXPECT_EQ(image->slots.front().mipmaps.size(), 3u);
    }
    {
        // Several pictures without the sprite flag: only the first is loaded.
        Container c = rawChain({ 8, 4, 2 });
        c.pictures.push_back(c.pictures[0]);
        auto rig = texRig(c);
        rig->SetTextureSurfaceSize(1, 1);
        const auto image = rig->Parse("sample");
        ASSERT_NE(image, nullptr);
        EXPECT_EQ(image->slots.size(), 1u);
        EXPECT_EQ(image->slots.front().mipmaps.size(), 3u);
        EXPECT_EQ(image->slots.front().width, 8);
    }
}

TEST(TexBudget, ALevelTheNextOneCannotCoverIsKept) {
    Container c;
    c.texb  = 2;
    c.width = c.mapWidth = 4100;
    c.height = c.mapHeight = 64;
    c.pictures.push_back({ { rawLevel(4100, 64, 1), rawLevel(2050, 32, 2) }, std::nullopt });
    auto rig = texRig(c);
    struct Row {
        uint32_t w, h;
        size_t   mips;
        int      width;
        uint8_t  mark;
    };
    const Row rows[] = { { 3456, 2024, 2, 4100, 1 }, { 2050, 100, 1, 2050, 2 }, { 2051, 100, 2, 4100, 1 } };
    for (const auto& r : rows) {
        SCOPED_TRACE("surface " + std::to_string(r.w) + "x" + std::to_string(r.h));
        rig->SetTextureSurfaceSize(r.w, r.h);
        const auto image = rig->Parse("sample");
        ASSERT_NE(image, nullptr);
        EXPECT_EQ(image->slots.front().mipmaps.size(), r.mips);
        EXPECT_EQ(image->slots.front().width, r.width);
        EXPECT_EQ(image->slots.front().mipmaps.front().data.get()[0], r.mark);
    }
}

TEST(TexBudget, KeptChainIsTheSmallestThatStillCoversTheSurface) {
    struct Screen {
        uint32_t w, h;
    };
    int combinations = 0;
    for (const Screen s : { Screen { 1920, 1080 }, Screen { 2560, 1440 }, Screen { 3456, 2234 } }) {
        const int S = static_cast<int>(std::max(s.w, s.h));
        for (bool portrait : { false, true }) {
            const uint32_t sw = portrait ? s.h : s.w;
            const uint32_t sh = portrait ? s.w : s.h;
            const int      step = std::max(1, S / 16);
            for (int L = S / 2; L <= 2 * S + 2; L += step) {
                ++combinations;
                const std::string tag = "L=" + std::to_string(L) + (portrait ? " portrait" : " landscape") +
                                        " surface " + std::to_string(sw) + "x" + std::to_string(sh);
                SCOPED_TRACE(tag);
                Container c;
                c.texb = 2;
                PictureSpec pic;
                std::vector<int> longest;
                int shortSide = 2;
                for (int side = L, k = 0;; side /= 2, ++k) {
                    longest.push_back(side);
                    const int w = portrait ? shortSide : side;
                    const int h = portrait ? side : shortSide;
                    pic.levels.push_back(rawLevel(w, h, static_cast<uint8_t>(k + 1)));
                    shortSide = std::max(1, shortSide / 2);
                    if (side == 1) break;
                }
                c.width = c.mapWidth = pic.levels[0].width;
                c.height = c.mapHeight = pic.levels[0].height;
                c.pictures.push_back(pic);
                auto rig = texRig(c);
                rig->SetTextureSurfaceSize(sw, sh);
                const auto image = rig->Parse("sample");
                ASSERT_NE(image, nullptr) << tag;
                ASSERT_FALSE(image->slots.empty()) << tag;
                const auto& mips = image->slots[0].mipmaps;
                ASSERT_FALSE(mips.empty()) << tag;
                const size_t authored = longest.size();
                const size_t dropped  = authored - mips.size();
                const int    first    = std::max(mips[0].width, mips[0].height);
                EXPECT_GE(first, std::min(L, S)) << tag;
                EXPECT_EQ(mips[0].data.get()[0], static_cast<uint8_t>(dropped + 1)) << tag;
                EXPECT_EQ(first, longest[dropped]) << tag;
                if (dropped + 1 < authored) EXPECT_LT(longest[dropped + 1], S) << tag;
            }
        }
    }
    EXPECT_GE(combinations, 150);

    // Boundary rows against a 1920x1080 surface: texture longest side -> first kept side.
    struct Edge {
        int tex, kept;
    };
    for (const Edge e : { Edge { 3840, 1920 }, Edge { 3839, 3839 }, Edge { 3841, 1920 },
                          Edge { 1920, 1920 }, Edge { 1919, 1919 }, Edge { 960, 960 } }) {
        SCOPED_TRACE("texture " + std::to_string(e.tex));
        Container c;
        c.texb = 2;
        PictureSpec pic;
        for (int side = e.tex;; side /= 2) {
            pic.levels.push_back(rawLevel(side, 1, 1));
            if (side == 1) break;
        }
        c.width = c.mapWidth = e.tex;
        c.height = c.mapHeight = 1;
        c.pictures.push_back(pic);
        auto rig = texRig(c);
        rig->SetTextureSurfaceSize(1920, 1080);
        const auto image = rig->Parse("sample");
        ASSERT_NE(image, nullptr);
        EXPECT_EQ(image->slots[0].mipmaps[0].width, e.kept);
    }
}

TEST(TexBudget, EncodedChainsAreMeasuredByTheirHeaders) {
    const auto build2 = [] {
        Container c;
        c.texb = 3;
        c.type = 13;
        c.width = c.mapWidth = c.height = c.mapHeight = 4100;
        c.pictures.push_back({ { levelOf(4100, 4100, redPng(1)), levelOf(2050, 2050, redPng(9)) },
                               std::nullopt });
        return c;
    };
    auto rig = texRig(build2());
    struct Row {
        uint32_t surface;
        size_t   mips;
        uint8_t  first;
    };
    for (const Row r : { Row { 3456, 2, 1 }, Row { 2000, 1, 9 }, Row { 2050, 1, 9 },
                         Row { 2051, 2, 1 }, Row { 4100, 2, 1 } }) {
        SCOPED_TRACE("surface " + std::to_string(r.surface));
        rig->SetTextureSurfaceSize(r.surface, r.surface);
        const auto image = rig->Parse("sample");
        ASSERT_NE(image, nullptr);
        EXPECT_EQ(image->slots[0].mipmaps.size(), r.mips);
        EXPECT_EQ(image->slots[0].mipmaps[0].data.get()[0], r.first);
    }
}

// ---------------------------------------------------------------------------------------------
// Loose pictures and host paths
// ---------------------------------------------------------------------------------------------

namespace
{
// A rig whose packaged files are only enough to have a mount at all.
Rig anyMount() {
    Container c(1, { levelOf(1, 1, png1x1(1, 2, 3, 4)) });
    c.type = 13;
    return texRig(c);
}
} // namespace

TEST(TexLoose, AbsolutePathToTheUsersOwnPictureLoads) {
    ScratchDir dir("tex-host");
    const std::string chosen = dir.write("chosen.png", png1x1(11, 22, 33, 44));
    auto rig = anyMount();
    const auto h = rig->ParseHeader(chosen);
    EXPECT_EQ(h.width, 1);
    EXPECT_EQ(h.height, 1);
    EXPECT_FALSE(h.isVideo);
    EXPECT_EQ(h.type, ImageType::PNG);
    EXPECT_EQ(h.count, 1);
    EXPECT_EQ(h.format, TextureFormat::RGBA8);
    EXPECT_EQ(h.sample.wrapS, TextureWrap::CLAMP_TO_EDGE);
    const auto image = rig->Parse(chosen);
    ASSERT_NE(image, nullptr);
    ASSERT_EQ(image->slots.size(), 1u);
    EXPECT_EQ(image->slots[0].width, 1);
    const uint8_t want[4] = { 11, 22, 33, 44 };
    ASSERT_FALSE(image->slots[0].mipmaps.empty());
    for (int i = 0; i < 4; ++i) EXPECT_EQ(image->slots[0].mipmaps[0].data.get()[i], want[i]);

    const std::string upper = dir.write("UPPER.PNG", png1x1(5, 6, 7, 8));
    EXPECT_NE(rig->Parse(upper), nullptr);

    const std::string wrongExt = dir.write("photo.jpg", png1x1(5, 6, 7, 8));
    const auto jh = rig->ParseHeader(wrongExt);
    EXPECT_EQ(jh.type, ImageType::JPEG);
    EXPECT_EQ(jh.width, 1);

    EXPECT_EQ(rig->Parse(dir.write("broken.png", std::string("not a picture"))), nullptr);
    std::filesystem::create_directories(dir.path() / "dir.png");
    EXPECT_EQ(rig->Parse(dir.str("dir.png")), nullptr);
    EXPECT_EQ(rig->Parse(dir.write("note.txt", png1x1(5, 6, 7, 8))), nullptr);
}

TEST(TexLoose, AbsolutePathToNothingStaysUnresolved) {
    ScratchDir dir("tex-absent");
    auto rig = texRig(Container(1, { levelOf(1, 1, png1x1(1, 2, 3, 4)) }));
    EXPECT_EQ(rig->Parse(dir.str("absent.png")), nullptr);
    EXPECT_NE(rig->Parse("sample"), nullptr);
    EXPECT_EQ(rig->ParseHeader(dir.str("absent.png")).width, 0);
}

TEST(TexLoose, PackagedLoosePicturesComeFromTheMountNotTheHostDisk) {
    struct Row {
        const char* inside;
        const char* name;
        ImageType   type;
    };
    const Row rows[] = {
        { "/materials/backdrop.png", "backdrop.png", ImageType::PNG },
        { "/pictures/backdrop.png", "pictures/backdrop.png", ImageType::PNG },
        { "/materials/guessed.png", "guessed", ImageType::PNG },
        { "/guess.jpg", "guess", ImageType::JPEG },
        { "/materials/UP.PNG", "UP.PNG", ImageType::PNG },
    };
    for (const auto& r : rows) {
        SCOPED_TRACE(r.name);
        auto rig = rigFor({ { r.inside, png1x1(9, 8, 7, 6) } });
        const auto h = rig->ParseHeader(r.name);
        EXPECT_EQ(h.width, 1);
        EXPECT_EQ(h.height, 1);
        EXPECT_EQ(h.type, r.type);
        const auto image = rig->Parse(r.name);
        ASSERT_NE(image, nullptr);
        ASSERT_EQ(image->slots.size(), 1u);
        EXPECT_EQ(image->slots[0].width, 1);
        EXPECT_EQ(image->slots[0].height, 1);
    }
    {
        // A packaged texture wins over a loose picture of the same name.
        Container c(1, { levelOf(1, 1, png1x1(1, 2, 3, 4)) });
        c.type = 13;
        auto rig = rigFor({ { "/materials/sample.tex", build(c) }, { "/materials/sample.png", png1x1(9, 9, 9, 9) } });
        EXPECT_EQ(rig->ParseHeader("sample").extraHeader.count("texb"), 1u);
        EXPECT_NE(rig->Parse("sample"), nullptr);
    }
    {
        // A damaged texture is not rescued by a loose picture.
        auto rig = rigFor({ { "/materials/sample.tex", { 1, 2, 3 } }, { "/materials/sample.png", png1x1(9, 9, 9, 9) } });
        EXPECT_EQ(rig->Parse("sample"), nullptr);
    }
}

TEST(TexLoose, PackagedBmpDecodesToItsPixels) {
    auto rig = rigFor({ { "/materials/backdrop.bmp", bmp1x1(90, 60, 30) } });
    const auto image = rig->Parse("backdrop.bmp");
    ASSERT_NE(image, nullptr);
    ASSERT_EQ(image->slots.size(), 1u);
    ASSERT_EQ(image->slots[0].mipmaps.size(), 1u);
    EXPECT_EQ(image->slots[0].mipmaps[0].size, 4);
    ASSERT_NE(image->slots[0].mipmaps[0].data.get(), nullptr);
    const uint8_t want[4] = { 90, 60, 30, 255 };
    for (int i = 0; i < 4; ++i) EXPECT_EQ(image->slots[0].mipmaps[0].data.get()[i], want[i]) << i;
    EXPECT_EQ(rig->ParseHeader("backdrop.bmp").type, ImageType::BMP);
}

TEST(TexLoose, HostLooseAssetReadability) {
    ScratchDir dir("tex-readable");
    const std::string chosen = dir.write("chosen.png", png1x1(1, 2, 3, 4));
    EXPECT_TRUE(HostLooseAssetIsReadable(chosen));
    EXPECT_FALSE(HostLooseAssetIsReadable(dir.str("gone.png")));
    EXPECT_FALSE(HostLooseAssetIsReadable(dir.str()));
    EXPECT_FALSE(HostLooseAssetIsReadable("materials/packaged"));
    EXPECT_FALSE(HostLooseAssetIsReadable(""));

    EXPECT_TRUE(HostLooseAssetIsReadable(dir.write("UP.PNG", png1x1(1, 2, 3, 4))));
    EXPECT_TRUE(HostLooseAssetIsReadable(dir.write("clip.mp4", Blob { 1, 2, 3 })));
    EXPECT_FALSE(HostLooseAssetIsReadable(dir.write("note.txt", std::string("hello"))));
    std::filesystem::create_directories(dir.path() / "dir.png");
    EXPECT_FALSE(HostLooseAssetIsReadable(dir.str("dir.png")));
    EXPECT_FALSE(HostLooseAssetIsReadable("a.png"));
    {
        // A relative name is never a host path, even when it happens to exist from here.
        dir.write("near.png", png1x1(1, 2, 3, 4));
        const auto before = std::filesystem::current_path();
        std::filesystem::current_path(dir.path());
        const bool readable = HostLooseAssetIsReadable("near.png");
        std::filesystem::current_path(before);
        EXPECT_FALSE(readable);
    }

    if (::geteuid() == 0) {
        GTEST_LOG_(INFO) << "running as root: the unreadable-file row is skipped";
    } else {
        const std::string locked = dir.write("locked.mp4", Blob { 1, 2, 3 });
        ASSERT_EQ(::chmod(locked.c_str(), 0), 0);
        EXPECT_FALSE(HostLooseAssetIsReadable(locked));
        ::chmod(locked.c_str(), 0600);
    }
}

// ---------------------------------------------------------------------------------------------
// Packages and scene sources
// ---------------------------------------------------------------------------------------------

namespace
{
std::unique_ptr<fs::WPPkgFs> openPkg(const ScratchDir& dir, const std::vector<PkgEntry>& entries,
                                     size_t truncateBy = 0) {
    Blob bytes = pkgBytes(entries);
    bytes.resize(bytes.size() - truncateBy);
    return fs::WPPkgFs::CreatePkgFs(dir.write("test.pkg", bytes));
}
std::string readAll(fs::Fs& f, std::string_view path) {
    auto stream = f.Open(path);
    return stream ? stream->ReadAllStr() : std::string("<missing>");
}
} // namespace

TEST(TexPackage, LookupIgnoresAsciiCase) {
    ScratchDir dir("tex-pkg");
    auto pkg = openPkg(dir, { { "Materials/Foo.TEX", "payload" } });
    ASSERT_NE(pkg, nullptr);
    EXPECT_TRUE(pkg->Contains("/materials/foo.tex"));
    EXPECT_TRUE(pkg->Contains("/MATERIALS/FOO.TEX"));
    EXPECT_EQ(readAll(*pkg, "/materials/foo.tex"), "payload");
    EXPECT_FALSE(pkg->Contains("materials/foo.tex"));
    EXPECT_FALSE(pkg->Contains("/materials/foo"));
    EXPECT_EQ(pkg->Open("/missing"), nullptr);
    EXPECT_EQ(pkg->OpenW("/materials/foo.tex"), nullptr);

    auto empty = openPkg(dir, { { "empty.bin", "" }, { "after.bin", "x" } });
    ASSERT_NE(empty, nullptr);
    EXPECT_EQ(readAll(*empty, "/empty.bin"), "");

    // The last entry runs off the end of the file.
    auto cut = openPkg(dir, { { "first.bin", "one" }, { "second.bin", "twelve bytes" } }, 1);
    ASSERT_NE(cut, nullptr);
    EXPECT_EQ(readAll(*cut, "/first.bin"), "one");
    EXPECT_FALSE(cut->Contains("/second.bin"));

    EXPECT_EQ(fs::WPPkgFs::CreatePkgFs(dir.write("tiny.pkg", Blob(10, 1))), nullptr);
    EXPECT_EQ(fs::WPPkgFs::CreatePkgFs(dir.str("nonexistent.pkg")), nullptr);
}

TEST(TexPackage, ExactPathBeatsACaseFoldCollision) {
    ScratchDir dir("tex-pkg-fold");
    auto pkg = openPkg(dir, { { "Materials/Foo.TEX", "upper" }, { "materials/foo.tex", "lower" } });
    ASSERT_NE(pkg, nullptr);
    EXPECT_EQ(readAll(*pkg, "/Materials/Foo.TEX"), "upper");
    EXPECT_EQ(readAll(*pkg, "/materials/foo.tex"), "lower");
    EXPECT_TRUE(pkg->Contains("/MATERIALS/FOO.TEX"));

    auto dup = openPkg(dir, { { "Materials/Foo.TEX", "upper" },
                              { "materials/foo.tex", "lower" },
                              { "materials/foo.tex", "dup" } });
    ASSERT_NE(dup, nullptr);
    EXPECT_EQ(readAll(*dup, "/materials/foo.tex"), "lower");
    EXPECT_EQ(readAll(*dup, "/MATERIALS/FOO.TEX"), "upper");
}

TEST(TexPackage, PresetFilesMountBesideThePackageAndThePackageWins) {
    ScratchDir dir("tex-scene");
    dir.write("scene.pkg", pkgBytes({ { "scene.json", "packaged" } }));
    dir.write("scene.json", std::string("loose"));
    dir.write("files/picked.png", png1x1(3, 4, 5, 6));

    SceneSourcePaths paths;
    std::string      err;
    ASSERT_TRUE(ResolveSceneSourcePaths(dir.str("scene.json"), &paths, &err)) << err;
    EXPECT_EQ(paths.pkg_path, dir.str("scene.pkg"));
    EXPECT_EQ(paths.pkg_entry, "scene.json");
    EXPECT_EQ(paths.pkg_dir, dir.str());
    EXPECT_EQ(paths.scene_id, dir.path().filename().string());

    {
        fs::VFS vfs;
        ASSERT_TRUE(MountSceneSource(vfs, paths, &err)) << err;
        EXPECT_EQ(fs::GetFileContent(vfs, "/assets/scene.json"), "packaged");
        WPTexImageParser parser(&vfs);
        const auto image = parser.Parse("files/picked.png");
        ASSERT_NE(image, nullptr);
        ASSERT_EQ(image->slots.size(), 1u);
        EXPECT_EQ(image->slots[0].width, 1);
        EXPECT_EQ(image->slots[0].mipmaps[0].data.get()[0], 3);
        EXPECT_EQ(parser.ParseHeader("files/picked.png").width, 1);
    }

    std::filesystem::remove(dir.path() / "scene.pkg");
    {
        fs::VFS vfs;
        ASSERT_TRUE(MountSceneSource(vfs, paths, &err)) << err;
        EXPECT_EQ(fs::GetFileContent(vfs, "/assets/scene.json"), "loose");
        WPTexImageParser parser(&vfs);
        EXPECT_NE(parser.Parse("files/picked.png"), nullptr);
    }

    // A package that is not one: fall back to the folder.
    dir.write("scene.pkg", Blob { 1, 2, 3 });
    {
        fs::VFS vfs;
        ASSERT_TRUE(MountSceneSource(vfs, paths, &err)) << err;
        EXPECT_EQ(fs::GetFileContent(vfs, "/assets/scene.json"), "loose");
    }

    SceneSourcePaths missing = paths;
    missing.pkg_dir          = dir.str("no-such-folder");
    {
        fs::VFS vfs;
        std::string failure;
        EXPECT_FALSE(MountSceneSource(vfs, missing, &failure));
        EXPECT_EQ(failure, "can't load pkg directory: " + missing.pkg_dir);
    }
}
