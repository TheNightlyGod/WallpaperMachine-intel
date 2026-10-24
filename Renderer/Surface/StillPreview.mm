#include "Surface/StillPreview.hpp"

#include "Surface/PreviewPath.hpp"

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>

#include <filesystem>
#include <optional>

namespace wallpaper::surface
{
namespace
{

namespace fs = std::filesystem;

/// A surface never shows more than this many pixels of a preview: the picture is
/// scaled to the screen anyway, and a decode cap keeps a hostile file from
/// costing memory.
constexpr int kMaxPictureEdge = 4096;

/// The `preview` key of the project file, or empty.
std::string DeclaredPreview(const fs::path& project_json)
{
    @autoreleasepool {
        NSData* data = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:project_json.c_str()]
                                              options:NSDataReadingMappedIfSafe
                                                error:nil];
        if (data == nil || data.length == 0 || data.length > 8u * 1024u * 1024u) return {};
        id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![parsed isKindOfClass:[NSDictionary class]]) return {};
        id name = ((NSDictionary*)parsed)[@"preview"];
        if (![name isKindOfClass:[NSString class]]) return {};
        return std::string([(NSString*)name UTF8String]);
    }
}

} // namespace

std::string FindPreviewImage(const std::string& project_path)
{
    if (project_path.empty()) return {};
    std::error_code error;
    fs::path        path(project_path);
    fs::path        directory;
    std::string     declared;
    if (fs::is_directory(path, error)) {
        directory = path;
        declared  = DeclaredPreview(directory / "project.json");
    } else {
        directory = path.parent_path();
        // A project file names its own preview; a scene source file or package
        // has the project.json beside it.
        declared = DeclaredPreview(path.filename() == "project.json" ? path : directory / "project.json");
    }
    if (directory.empty()) return {};
    const auto picked = PickPreviewFile(directory, declared);
    return picked ? picked->string() : std::string {};
}

struct StillPreview::Impl {
    CALayer*  sublayer { nil };
    CGImageRef image { nullptr };
    unsigned  width { 0 };
    unsigned  height { 0 };

    ~Impl() { Reset(); }

    void Reset()
    {
        if (sublayer != nil) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            [sublayer removeFromSuperlayer];
            [CATransaction commit];
            sublayer = nil;
        }
        if (image != nullptr) {
            CGImageRelease(image);
            image = nullptr;
        }
        width = height = 0;
    }
};

StillPreview::StillPreview() : m_impl(std::make_unique<Impl>()) {}
StillPreview::~StillPreview() = default;

bool StillPreview::shown() const { return m_impl->sublayer != nil; }

std::pair<unsigned, unsigned> StillPreview::pictureSize() const
{
    return { m_impl->width, m_impl->height };
}

bool StillPreview::Show(void* layer_pointer, const std::string& image_path, std::string& error)
{
    @autoreleasepool {
        CALayer* parent = (__bridge CALayer*)layer_pointer;
        if (parent == nil) {
            error = "there is no surface to show the preview on";
            return false;
        }
        NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:image_path.c_str()]];
        CGImageSourceRef source = url != nil ? CGImageSourceCreateWithURL((__bridge CFURLRef)url, nullptr) : nullptr;
        if (source == nullptr || CGImageSourceGetCount(source) == 0) {
            if (source != nullptr) CFRelease(source);
            error = "the preview picture cannot be read: " + image_path;
            return false;
        }
        // Frame 0 of an animation is its poster.
        NSDictionary* options = @{
            (__bridge NSString*)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
            (__bridge NSString*)kCGImageSourceCreateThumbnailWithTransform : @YES,
            (__bridge NSString*)kCGImageSourceThumbnailMaxPixelSize : @(kMaxPictureEdge),
        };
        CGImageRef decoded =
            CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
        CFRelease(source);
        if (decoded == nullptr) {
            error = "the preview picture cannot be decoded: " + image_path;
            return false;
        }

        // Replacing, not stacking: a display change gives the scene a new layer
        // and asks for the picture again.
        m_impl->Reset();
        m_impl->image  = decoded;
        m_impl->width  = static_cast<unsigned>(CGImageGetWidth(decoded));
        m_impl->height = static_cast<unsigned>(CGImageGetHeight(decoded));

        CALayer* picture            = [CALayer layer];
        picture.contents            = (__bridge id)decoded;
        picture.contentsGravity     = kCAGravityResizeAspectFill;
        picture.masksToBounds       = YES;
        picture.contentsScale       = parent.contentsScale;
        picture.frame               = parent.bounds;
        picture.name                = @"MWEFailurePreview";
        picture.actions             = @{ @"contents" : [NSNull null], @"bounds" : [NSNull null], @"position" : [NSNull null] };
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [parent addSublayer:picture];
        [CATransaction commit];
        m_impl->sublayer = picture;
        return true;
    }
}

void StillPreview::Hide() { m_impl->Reset(); }

} // namespace wallpaper::surface
