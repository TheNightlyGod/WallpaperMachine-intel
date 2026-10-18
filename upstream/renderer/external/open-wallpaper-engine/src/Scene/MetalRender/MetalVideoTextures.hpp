#pragma once

// Objective-C++ only: this header names Metal types and is included from `.mm`
// translation units. The part of the video decision that plain C++ needs is in
// `MetalRender/MetalVideoSupport.hpp`.

#import <Metal/Metal.h>

#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include "MetalRender/MetalVideoSupport.hpp"
#include "Video/VideoColorConversion.hpp"
#include "Video/VideoDisplayTransform.hpp"

namespace wallpaper
{
class Scene;
class RendererCounters;

namespace video
{
class VideoTextureSource;
}

namespace metal
{

/// What one video texture's consumers need from each frame.
///
/// This is asked before anything is imported, which is the whole point: a frame
/// whose consumers all sample planes must not be converted first and then have
/// the conversion thrown away.
struct VideoConsumerDemand
{
    /// At least one consumer samples the decoder's planes directly.
    bool planes { false };
    /// At least one consumer needs one colour image.
    bool rgb { true };
};

/// The decoder's two planes and the constants that turn them into colour.
struct VideoFramePlanes
{
    id<MTLTexture>          luma { nil };
    id<MTLTexture>          chroma { nil };
    video::YuvColorParams   params {};
    std::uint32_t           width { 0 };
    std::uint32_t           height { 0 };
    video::VideoDisplayTransform display_transform;

    [[nodiscard]] bool valid() const { return luma != nil && chroma != nil; }
};

/// The scene's video textures, as ordinary sampled `MTLTexture`s.
///
/// This is not the plain-video backend and does not replace it: it exists so a
/// scene whose author samples a video the way it samples any other texture can
/// stay on the native Metal renderer. Each texture keeps its own decoder and
/// its own playback semantics, exactly as the compatibility backend's texture
/// cache gives it.
///
/// One frame is imported per generation, no matter how many passes sample it,
/// and every object that frame's texture depends on — the pixel buffer, the
/// Core Video wrappers, the conversion destination — stays retained until the
/// command buffer that read it completes.
class MetalVideoTextures {
public:
    MetalVideoTextures();
    ~MetalVideoTextures();
    MetalVideoTextures(const MetalVideoTextures&)            = delete;
    MetalVideoTextures& operator=(const MetalVideoTextures&) = delete;

    void configure(id<MTLDevice> device);

    /// Graph compile time. One source per key; keys that are not video
    /// textures are ignored. A key whose source `hold` set aside is not opened
    /// again, nor is its media read again: the source is given the scene's clock
    /// as it is and carries on. False with an error means the whole scene falls
    /// back to the compatibility backend.
    bool prepare(Scene& scene, const std::vector<std::string>& texture_keys, std::string* error);

    /// Drops the open sources and the textures. Frames a command buffer may still
    /// be reading are kept alive by that command buffer's completion handler, not
    /// by this object, so calling this mid-flight is safe. Sources set aside by
    /// `hold` are not touched: `closeHeld` ends them.
    void release();

    /// The first half of a graph rebuilt under a playing scene: sets the open
    /// sources aside, with the textures and the demand released as `release`
    /// does, so that the next `prepare` takes back the ones its keys name. A
    /// source is the decoder's open file, its thread and the frames it has
    /// decoded ahead, which is what a video costs to open and why its clip
    /// would otherwise start again at the head. Only for a graph that the same
    /// scene is about to compile again: a key names the same media there.
    void hold();

    /// Closes the sources `hold` set aside and `prepare` did not take back, which
    /// are the videos the new graph no longer uses. The compile that follows a
    /// `hold` ends with it, however it ends, and the renderer calls it itself
    /// when it refuses the compile before it begins.
    void closeHeld();

    [[nodiscard]] bool owns(const std::string& key) const;
    [[nodiscard]] bool empty() const;

    void setPaused(bool paused);
    void setRate(float rate);
    void setCounters(RendererCounters* counters);

    /// Declares what each key's consumers can use, before the next frame is
    /// imported. Keys not named keep the default, which is "needs one colour
    /// image" -- the behaviour every consumer had before planes existed.
    void setDemand(std::map<std::string, VideoConsumerDemand> demand);

    /// Shortest frame period among the sources, in seconds, or 0 when any of
    /// them cannot say — pacing on the others would skip its changes.
    [[nodiscard]] double shortestFramePeriod() const;

    /// True when at least one source is unpaused with a positive rate: the
    /// scene must not idle, because its content changes without an event.
    [[nodiscard]] bool advancesOnItsOwn() const;

    /// Render thread, once per frame, before any pass is encoded into
    /// `command`. Conversions are encoded into `command`, so ordering against
    /// the passes that sample them comes from the command buffer itself.
    bool beginFrame(Scene& scene, id<MTLCommandBuffer> command, std::string* error);

    /// Last valid frame for `key`, at the decoded frame's own size. Nil when no
    /// frame was ever produced for it, and also when every consumer samples the
    /// planes directly -- there is then no single colour image, by design.
    [[nodiscard]] id<MTLTexture> texture(const std::string& key) const;

    /// The planes of `key`'s current frame, valid only while the current frame
    /// really is NV12 and the planes were published for it.
    [[nodiscard]] VideoFramePlanes planes(const std::string& key) const;

    /// How `key`'s current frame reached its consumers.
    [[nodiscard]] VideoFramePath path(const std::string& key) const;

    /// The path this scene's video textures share, or the mixed value when
    /// they differ. `None` when nothing has been imported.
    [[nodiscard]] VideoFramePath path() const;

    /// The decoded size of `key`'s current frame. False when there is none, in
    /// which case `width` and `height` are untouched.
    [[nodiscard]] bool frameSize(const std::string& key, std::uint32_t* width,
                                 std::uint32_t* height) const;

#ifdef WESCENE_BUILD_TESTS
    /// Registers a source directly, so the import, the conversion and the
    /// lifetime rules can be exercised without any media on disk.
    bool prepareForTests(const std::string&                         key,
                         std::shared_ptr<video::VideoTextureSource> source,
                         std::string*                               error);
    [[nodiscard]] std::uint64_t conversionsEncodedForTests() const;
    [[nodiscard]] std::uint64_t importsForTests() const;
#endif

private:
    struct State;
    /// Shared with every frame this object has in flight. A completion handler
    /// holds its own reference and never touches `this`, which is what makes a
    /// handler that runs after `release()` — or after destruction, on whatever
    /// thread Metal picks — well defined.
    std::shared_ptr<State> m_state;
};

} // namespace metal
} // namespace wallpaper
