// The still a surface shows when its scene cannot be drawn: found from the
// project, decoded, and put on a layer. Headless: a plain CALayer, no window.
#include "Surface/StillPreview.hpp"

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>

#include <gtest/gtest.h>

#include <filesystem>
#include <fstream>
#include <string>
#include <unistd.h>

namespace
{

namespace fs = std::filesystem;
using wallpaper::surface::FindPreviewImage;
using wallpaper::surface::StillPreview;

/// A solid red PNG of the given size, written with ImageIO.
void WritePng(const fs::path& path, size_t width, size_t height)
{
    fs::create_directories(path.parent_path());
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef    context = CGBitmapContextCreate(
        nullptr, width, height, 8, 0, space, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGContextSetRGBFillColor(context, 1, 0, 0, 1);
    CGContextFillRect(context, CGRectMake(0, 0, static_cast<CGFloat>(width), static_cast<CGFloat>(height)));
    CGImageRef image = CGBitmapContextCreateImage(context);
    NSURL*     url   = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path.c_str()]];
    CGImageDestinationRef destination =
        CGImageDestinationCreateWithURL((__bridge CFURLRef)url, CFSTR("public.png"), 1, nullptr);
    CGImageDestinationAddImage(destination, image, nullptr);
    ASSERT_TRUE(CGImageDestinationFinalize(destination));
    CFRelease(destination);
    CGImageRelease(image);
    CGContextRelease(context);
    CGColorSpaceRelease(space);
}

class StillPreviewTest : public ::testing::Test {
protected:
    void SetUp() override
    {
        root_ = fs::temp_directory_path() / ("wm-surface-still-" + std::to_string(::getpid()) + "-" +
                                             ::testing::UnitTest::GetInstance()->current_test_info()->name());
        fs::remove_all(root_);
        fs::create_directories(root_);
    }
    void TearDown() override { fs::remove_all(root_); }

    fs::path root_;
};

TEST_F(StillPreviewTest, TheProjectFilesPreviewKeyIsFoundBeforeAConventionalName)
{
    WritePng(root_ / "art/cover.png", 8, 4);
    WritePng(root_ / "preview.png", 2, 2);
    std::ofstream(root_ / "project.json") << R"({"title":"x","preview":"art/cover.png"})";
    EXPECT_EQ(fs::path(FindPreviewImage((root_ / "project.json").string())).filename(), "cover.png");
    // The folder works as well as the file, and so does a file beside project.json.
    EXPECT_EQ(fs::path(FindPreviewImage(root_.string())).filename(), "cover.png");
    EXPECT_EQ(fs::path(FindPreviewImage((root_ / "scene.pkg").string())).filename(), "cover.png");
}

TEST_F(StillPreviewTest, AProjectWithoutAPreviewKeyUsesTheConventionalFileAndOneWithNoneHasNoPreview)
{
    std::ofstream(root_ / "project.json") << R"({"title":"x"})";
    EXPECT_TRUE(FindPreviewImage((root_ / "project.json").string()).empty());
    WritePng(root_ / "preview.png", 2, 2);
    EXPECT_EQ(fs::path(FindPreviewImage((root_ / "project.json").string())).filename(), "preview.png");
    EXPECT_TRUE(FindPreviewImage("").empty());
}

TEST_F(StillPreviewTest, APreviewKeyThatEscapesTheProjectIsIgnored)
{
    WritePng(root_ / "outside/secret.png", 2, 2);
    fs::create_directories(root_ / "project");
    std::ofstream(root_ / "project/project.json") << R"({"preview":"../outside/secret.png"})";
    EXPECT_TRUE(FindPreviewImage((root_ / "project/project.json").string()).empty());
}

TEST_F(StillPreviewTest, ShowingPutsOneSublayerOnTheSurfaceAndHidingTakesItAway)
{
    WritePng(root_ / "preview.png", 16, 9);
    CALayer* surface = [CALayer layer];
    surface.frame    = CGRectMake(0, 0, 320, 180);

    StillPreview still;
    EXPECT_FALSE(still.shown());
    std::string error;
    ASSERT_TRUE(still.Show((__bridge void*)surface, (root_ / "preview.png").string(), error)) << error;
    EXPECT_TRUE(still.shown());
    EXPECT_EQ(surface.sublayers.count, 1u);
    EXPECT_TRUE(CGRectEqualToRect(surface.sublayers[0].frame, surface.bounds));
    EXPECT_EQ(still.pictureSize(), std::make_pair(16u, 9u));
    EXPECT_NE(surface.sublayers[0].contents, nil);

    // Showing again replaces the picture rather than stacking another.
    ASSERT_TRUE(still.Show((__bridge void*)surface, (root_ / "preview.png").string(), error)) << error;
    EXPECT_EQ(surface.sublayers.count, 1u);

    still.Hide();
    EXPECT_FALSE(still.shown());
    EXPECT_EQ(surface.sublayers.count, 0u);
    still.Hide();
}

TEST_F(StillPreviewTest, AReplacedLayerGetsThePictureAndTheOldOneLosesIt)
{
    WritePng(root_ / "preview.png", 4, 4);
    CALayer* first  = [CALayer layer];
    CALayer* second = [CALayer layer];
    first.frame     = CGRectMake(0, 0, 100, 100);
    second.frame    = CGRectMake(0, 0, 200, 100);
    StillPreview still;
    std::string  error;
    ASSERT_TRUE(still.Show((__bridge void*)first, (root_ / "preview.png").string(), error)) << error;
    ASSERT_TRUE(still.Show((__bridge void*)second, (root_ / "preview.png").string(), error)) << error;
    EXPECT_EQ(first.sublayers.count, 0u);
    EXPECT_EQ(second.sublayers.count, 1u);
}

TEST_F(StillPreviewTest, AFileThatIsNotAPictureShowsNothingAndSaysWhy)
{
    std::ofstream(root_ / "preview.png") << "this is not a png";
    CALayer* surface = [CALayer layer];
    surface.frame    = CGRectMake(0, 0, 10, 10);
    StillPreview still;
    std::string  error;
    EXPECT_FALSE(still.Show((__bridge void*)surface, (root_ / "preview.png").string(), error));
    EXPECT_FALSE(error.empty());
    EXPECT_FALSE(still.shown());
    EXPECT_EQ(surface.sublayers.count, 0u);
    EXPECT_FALSE(still.Show(nullptr, (root_ / "preview.png").string(), error));
}

TEST_F(StillPreviewTest, ADestroyedStillTakesItsSublayerWithIt)
{
    WritePng(root_ / "preview.png", 4, 4);
    CALayer* surface = [CALayer layer];
    surface.frame    = CGRectMake(0, 0, 10, 10);
    {
        StillPreview still;
        std::string  error;
        ASSERT_TRUE(still.Show((__bridge void*)surface, (root_ / "preview.png").string(), error)) << error;
    }
    EXPECT_EQ(surface.sublayers.count, 0u);
}

} // namespace
