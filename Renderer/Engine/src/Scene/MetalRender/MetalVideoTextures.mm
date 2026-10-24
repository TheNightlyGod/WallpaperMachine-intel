#include "MetalVideoTextures.hpp"

#include "MetalRender/MetalVideoSupport.hpp"

#import <CoreVideo/CoreVideo.h>

#include "Core/RendererCounters.hpp"
#include "Image.hpp"
#include "Interface/IImageParser.h"
#include "Platform/Apple/VideoFrameInterop.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Scene/Scene.h"
#include "Utils/Logging.h"
#include "Video/VideoColorConversion.hpp"
#include "Video/VideoConversionMetal.hpp"
#include "Video/VideoFramePacing.hpp"
// For `ResolveEffectiveVideoPlaybackState`: the global/per-layer combination is
// part of what playback means, and a second copy of it here would be a second
// definition that can drift from the playback code's.
#include "Video/VideoTextureSource.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <map>
#include <utility>

namespace wallpaper::metal
{
namespace
{

/// What author shaders sample, on both import paths. Keeping the zero-copy
/// BGRA frame and the converted NV12 frame in one format means a shader cannot
/// tell which decoder produced its texture.
constexpr MTLPixelFormat kVideoDestinationPixelFormat = MTLPixelFormatBGRA8Unorm;

/// Conversion destinations per source: the renderer's two in-flight frames plus
/// the one this frame writes. A destination a command buffer may still be
/// reading is therefore never the one chosen next.
constexpr std::size_t kDestinationSlots = 3;

/// Frames between opportunistic `CVMetalTextureCacheFlush` calls. Flushing
/// every frame would drop the cache's own reuse, which is the only reason the
/// per-frame import is cheap; never flushing keeps dead surfaces mapped.
constexpr std::uint64_t kTextureCacheFlushInterval = 64;

bool SetError(std::string* error, std::string message)
{
    if (error != nullptr) *error = std::move(message);
    return false;
}

std::string DescribePixelFormat(std::uint32_t code)
{
    // The four characters of a pixel-format code, most significant byte first.
    std::string text;
    for (int shift = 24; shift >= 0; shift -= 8) {
        const auto byte = static_cast<char>((code >> shift) & 0xFFu);
        if (byte == '\0') break;
        text.push_back(byte);
    }
    return text;
}

/// How a decoded frame reaches the shaders, decided by its pixel format.
enum class PixelKind {
    /// One BGRA image, imported as it is.
    Bgra,
    /// 8-bit biplanar 4:2:0 (NV12): two planes, converted or sampled directly.
    Nv12,
    /// 10-bit biplanar 4:2:0 (P010, `x420`): two 16-bit planes, always converted,
    /// because the conversion is also where HDR is tone mapped to SDR.
    TenBit,
};

/// BGRA, 8-bit NV12 and 10-bit biplanar 4:2:0. Every other chroma layout and
/// depth needs colour handling this path does not have, and guessing one would
/// show wrong colours rather than fall back.
bool SupportedPixelFormat(std::uint32_t pixel_format, PixelKind* kind)
{
    PixelKind found = PixelKind::Bgra;
    switch (pixel_format) {
    case kCVPixelFormatType_32BGRA:
        found = PixelKind::Bgra;
        break;
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
        found = PixelKind::Nv12;
        break;
    case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
    case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
        found = PixelKind::TenBit;
        break;
    default:
        return false;
    }
    if (kind != nullptr) *kind = found;
    return true;
}

} // namespace

/// Members of `MetalVideoTextures::State`, which is declared in a header, so
/// these need a linkage the anonymous namespace above cannot give them.
namespace video_detail
{

/// Everything one imported frame's texture depends on, released together.
///
/// Core Video documents the wrapper, not the vended `MTLTexture`, as the object
/// whose lifetime governs the texture's validity, and the pixel buffer outlives
/// the decoder slot it came from, so all three are held here rather than
/// assumed alive.
struct FrameBundle {
    video::VideoTextureFrame frame {};
    CVMetalTextureRef        wrappers[2] { nullptr, nullptr };
    /// What author shaders sample as one image: the vended BGRA texture, or
    /// the conversion destination the NV12 kernel wrote. Nil when every
    /// consumer reads the planes and nothing needed one image.
    id<MTLTexture>           sampled { nil };
    id<MTLTexture>           destination { nil };
    /// The decoder's own planes, vended from `wrappers`. Held here because a
    /// shader that samples them directly depends on the wrappers and the pixel
    /// buffer staying alive exactly as long as the vended texture does.
    id<MTLTexture>           luma { nil };
    id<MTLTexture>           chroma { nil };
    video::YuvColorParams    color {};
    /// 10-bit frames only: the constants of the HDR/SDR conversion. The planes
    /// above are then 16-bit and belong to the conversion alone, which is why
    /// `planes()` does not offer them.
    bool                     ten_bit { false };
    video::HdrConversionParams hdr {};
    /// Cleared when this bundle dies, which is after the command buffer that
    /// read `destination` completed. Until then the slot is not offered again.
    std::shared_ptr<std::atomic<bool>> slot_busy;

    FrameBundle() = default;
    FrameBundle(const FrameBundle&)            = delete;
    FrameBundle& operator=(const FrameBundle&) = delete;

    ~FrameBundle()
    {
        if (slot_busy) slot_busy->store(false, std::memory_order_release);
        for (auto& wrapper : wrappers) {
            if (wrapper != nullptr) {
                CFRelease(wrapper);
                wrapper = nullptr;
            }
        }
        video::ReleaseAppleVideoFrame(&frame);
    }
};

/// The frames one command buffer read. Held by a `shared_ptr` the completion
/// handler captures, so the handler owns what it must outlive without owning
/// the renderer.
struct PendingFrames {
    std::vector<std::shared_ptr<FrameBundle>> bundles;
};

struct DestinationSlot {
    id<MTLTexture>                     texture { nil };
    std::shared_ptr<std::atomic<bool>> busy;
};

struct VideoSourceEntry {
    std::shared_ptr<video::VideoTextureSource> source;
    /// Keeps the currently sampled frame alive between frames; replaced only
    /// when a newer generation is imported.
    std::shared_ptr<FrameBundle>               current;
    id<MTLTexture>                             texture { nil };
    std::uint64_t                              imported_generation { 0 };
    bool                                       has_import { false };
    /// Destination-slot shape, which is the conversion's, not the frame's.
    std::uint32_t                              width { 0 };
    std::uint32_t                              height { 0 };
    /// The decoded size of the frame `current` holds.
    std::uint32_t                              frame_width { 0 };
    std::uint32_t                              frame_height { 0 };
    /// How the frame `current` holds reached its consumers.
    VideoFramePath                             path { VideoFramePath::None };
    /// What the import that produced `current` was asked for. A demand that
    /// changes -- the setting toggled, a material's variant became usable --
    /// re-imports the same generation rather than waiting for the next one.
    VideoConsumerDemand                        satisfied {};
    /// Set when `current` is a 10-bit frame, whose one converted image serves
    /// every demand, so that a demand that changes is not a reason to import and
    /// convert it again.
    bool                                       demand_independent { false };
    std::array<DestinationSlot, kDestinationSlots> slots {};
    /// What the last `syncPlayback` actually asked for, which is what decides
    /// whether this source still changes on its own.
    bool                                       advancing { true };
    video::VideoFrameSelectionTracker          selection;
    std::uint64_t                              reported_decode_outputs { 0 };
    std::uint64_t                              reported_seeks { 0 };
};

} // namespace video_detail

using namespace video_detail;

struct MetalVideoTextures::State {
    id<MTLDevice>               device { nil };
    CVMetalTextureCacheRef      texture_cache { nullptr };
    id<MTLComputePipelineState> nv12_pipeline { nil };
    id<MTLComputePipelineState> bgra_pipeline { nil };
    /// Built the first time a source's frames are 10-bit, never for 8-bit video:
    /// the library it comes from is a second compile of the 10-bit kernel and
    /// what it shares with the NV12 one.
    id<MTLComputePipelineState> ten_bit_pipeline { nil };
    /// Why the conversion pipeline is missing, kept from `configure` so the
    /// first frame that needs it can say something better than "no pipeline".
    std::string                 pipeline_error;

    std::map<std::string, VideoSourceEntry> sources;
    /// What a graph being rebuilt set aside (`hold`) for the compile that follows
    /// to take back: each one's decoder, with what is reported of its work so far.
    std::map<std::string, VideoSourceEntry> held;
    std::map<std::string, VideoConsumerDemand> demand;
    RendererCounters*                       counters { nullptr };
    bool                                    paused { false };
    float                                   rate { 1.0f };
    std::uint64_t                           frames { 0 };
    std::uint64_t                           conversions_encoded { 0 };
    std::uint64_t                           imports { 0 };

    /// Entries go before the device objects they were made from, so nothing
    /// outlives the cache it came out of within this object.
    ~State()
    {
        sources.clear();
        held.clear();
        releaseDeviceObjects();
    }

    void releaseDeviceObjects()
    {
        if (texture_cache != nullptr) {
            CFRelease(texture_cache);
            texture_cache = nullptr;
        }
        nv12_pipeline = nil;
        bgra_pipeline = nil;
        ten_bit_pipeline = nil;
        device        = nil;
    }

    /// Pipeline and Core Video cache both belong to one device, so they are
    /// built together and thrown away together.
    void buildDeviceObjects()
    {
        CVMetalTextureCacheRef cache = nullptr;
        if (CVMetalTextureCacheCreate(kCFAllocatorDefault, nullptr, device, nullptr, &cache) ==
                kCVReturnSuccess &&
            cache != nullptr) {
            texture_cache = cache;
        } else {
            pipeline_error = "failed to create a Core Video texture cache for this Metal device";
            return;
        }

        NSError*  library_error = nil;
        NSString* source        = [NSString stringWithUTF8String:video::kVideoConversionMetalSource];
        id<MTLLibrary> library =
            [device newLibraryWithSource:source options:nil error:&library_error];
        if (library == nil) {
            pipeline_error = library_error != nil
                                 ? std::string([[library_error localizedDescription] UTF8String])
                                 : "failed to compile the NV12 video conversion library";
            return;
        }
        const auto pipeline = [&](NSString* name) -> id<MTLComputePipelineState> {
            id<MTLFunction> function = [library newFunctionWithName:name];
            if (function == nil) {
                pipeline_error = "failed to load a video conversion function";
                return nil;
            }
            NSError* error = nil;
            auto result = [device newComputePipelineStateWithFunction:function error:&error];
            if (result == nil) pipeline_error = error != nil
                ? std::string([[error localizedDescription] UTF8String]) : "failed to create a video conversion pipeline";
            return result;
        };
        nv12_pipeline = pipeline(@"nv12_to_bgra");
        bgra_pipeline = pipeline(@"bgra_transform");
    }

    /// The 10-bit conversion pipeline, compiled on first need. False with `error`
    /// set when Metal refuses the kernel, which fails the scene's compile like any other unsupported video.
    bool ensureTenBitPipeline(std::string* error)
    {
        if (ten_bit_pipeline != nil) return true;
        if (device == nil) return SetError(error, "no Metal device for 10-bit video textures");
        NSString* source = [NSString stringWithFormat:@"%s%s", video::kVideoConversionMetalSource,
                                                      video::kVideoTenBitConversionMetalSource];
        NSError* library_error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&library_error];
        id<MTLFunction> function = library != nil ? [library newFunctionWithName:@"p010_to_bgra"] : nil;
        if (function == nil) {
            return SetError(error, library_error != nil
                                       ? "failed to compile the 10-bit video conversion: " +
                                             std::string([[library_error localizedDescription] UTF8String])
                                       : std::string("failed to load the 10-bit video conversion function"));
        }
        NSError* pipeline_error_object = nil;
        ten_bit_pipeline = [device newComputePipelineStateWithFunction:function error:&pipeline_error_object];
        if (ten_bit_pipeline == nil) {
            return SetError(error, pipeline_error_object != nil
                                       ? "failed to create the 10-bit video conversion pipeline: " +
                                             std::string([[pipeline_error_object localizedDescription] UTF8String])
                                       : std::string("failed to create the 10-bit video conversion pipeline"));
        }
        return true;
    }

    /// What a key's source is asked to play right now: the layer's own clock and
    /// controls, under the renderer's pause and rate. The one answer for the
    /// frame being drawn and for a source being opened, which must not start from
    /// any clock but the one the next frame will hand it.
    video::VideoPlaybackState playbackFor(const Scene& scene, const std::string& key) const
    {
        video::VideoPlaybackState layer_state =
            scene.runtime != nullptr
                ? scene.runtime->ResolveVideoPlaybackState(key, scene.elapsingTime)
                : video::VideoPlaybackState {};
        if (scene.runtime == nullptr) layer_state.scene_elapsed_seconds = scene.elapsingTime;
        video::VideoPlaybackState global_state {};
        global_state.paused = paused;
        global_state.rate   = rate;
        return video::ResolveEffectiveVideoPlaybackState(global_state, layer_state);
    }

    void reportSourceWork(VideoSourceEntry& entry, std::uint64_t generation)
    {
        if (counters == nullptr) return;
        const auto stats = entry.source->sourceStats();
        if (stats.decoded_frames > entry.reported_decode_outputs) {
            counters->Add(OWE_RC_VIDEO_DECODE_OUTPUTS,
                          stats.decoded_frames - entry.reported_decode_outputs);
            entry.reported_decode_outputs = stats.decoded_frames;
        }
        if (stats.seek_requests > entry.reported_seeks) {
            counters->Add(OWE_RC_VIDEO_SEEKS, stats.seek_requests - entry.reported_seeks);
            entry.reported_seeks = stats.seek_requests;
        }
        const auto selection = entry.selection.Observe(generation);
        if (selection.selected) {
            counters->Add(OWE_RC_VIDEO_FRAMES_SELECTED);
            counters->Set(OWE_RC_VIDEO_SELECTED_GENERATION, generation);
        }
        if (selection.reused) counters->Add(OWE_RC_VIDEO_FRAMES_REUSED);
        if (selection.skipped > 0) counters->Add(OWE_RC_VIDEO_FRAMES_SKIPPED, selection.skipped);
    }

    void publishSourceIdentity()
    {
        if (counters == nullptr) return;
        std::uint64_t live_sources    = 0;
        std::uint64_t single_instance = 0;
        for (const auto& [key, entry] : sources) {
            (void)key;
            if (! entry.source) continue;
            ++live_sources;
            single_instance = entry.source->sourceStats().instance_id;
        }
        counters->Set(OWE_RC_VIDEO_SOURCE_COUNT, live_sources);
        counters->Set(OWE_RC_VIDEO_SOURCE_INSTANCE, live_sources == 1 ? single_instance : 0);
    }

    /// A destination no command buffer is still reading, allocating it the
    /// first time the slot is used. Nil means every slot is in flight or Metal
    /// refused one, which the caller treats as "no new frame this tick" rather
    /// than as a failure.
    id<MTLTexture> acquireDestination(VideoSourceEntry& entry,
                                      std::uint32_t     width,
                                      std::uint32_t     height,
                                      DestinationSlot** out_slot)
    {
        if (entry.width != width || entry.height != height) {
            // A shape nothing requests any more is not worth its bytes. Frames
            // still in flight hold their own reference to the old texture, so
            // dropping the slots here cannot pull one out from under them.
            entry.slots  = {};
            entry.width  = width;
            entry.height = height;
        }

        for (auto& slot : entry.slots) {
            if (slot.busy && slot.busy->load(std::memory_order_acquire)) continue;
            if (slot.texture == nil) {
                MTLTextureDescriptor* descriptor = [MTLTextureDescriptor
                    texture2DDescriptorWithPixelFormat:kVideoDestinationPixelFormat
                                                 width:width
                                                height:height
                                             mipmapped:NO];
                if (descriptor == nil) return nil;
                descriptor.usage           = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
                descriptor.storageMode     = MTLStorageModePrivate;
                descriptor.resourceOptions = MTLResourceStorageModePrivate;
                slot.texture               = [device newTextureWithDescriptor:descriptor];
                if (slot.texture == nil) return nil;
            }
            if (! slot.busy) slot.busy = std::make_shared<std::atomic<bool>>(false);
            slot.busy->store(true, std::memory_order_release);
            *out_slot = &slot;
            return slot.texture;
        }
        return nil;
    }
};

MetalVideoTextures::MetalVideoTextures(): m_state(std::make_shared<State>()) {}

MetalVideoTextures::~MetalVideoTextures() = default;

void MetalVideoTextures::configure(id<MTLDevice> device)
{
    auto& state = *m_state;
    if (state.device == device) return;
    state.sources.clear();
    state.held.clear();
    state.releaseDeviceObjects();
    state.pipeline_error.clear();
    state.device = device;
    if (device == nil) return;
    state.buildDeviceObjects();
}

bool MetalVideoTextures::prepare(Scene&                          scene,
                                 const std::vector<std::string>& texture_keys,
                                 std::string*                    error)
{
    auto& state = *m_state;
    if (texture_keys.empty()) {
        // A graph that binds no video says so: a rebuild that left the last one out
        // reports none open.
        state.publishSourceIdentity();
        return true;
    }
    if (state.device == nil) {
        return SetError(error, "no Metal device for the scene's video textures");
    }
    if (state.texture_cache == nullptr) {
        return SetError(error,
                        state.pipeline_error.empty()
                            ? std::string("no Core Video texture cache for the scene's video "
                                          "textures")
                            : state.pipeline_error);
    }

    for (const auto& key : texture_keys) {
        if (key.empty() || state.sources.count(key) != 0) continue;

        if (auto reason = MetalVideoTextureRejection(scene, key); ! reason.empty()) {
            return SetError(error, std::move(reason));
        }

        VideoSourceEntry entry;
        std::string      source_error;
        // A video the graph being rebuilt set aside is neither parsed nor opened
        // again: reading one that is packaged in the scene copies and hashes the
        // whole file, and a decoder opened again shows the head of its clip until
        // a seek to the clock has landed. It is given the clock as a draw gives it,
        // and carries on from the frame it had. One that failed while it waited is
        // opened again like any other.
        if (auto held = state.held.find(key); held != state.held.end()) {
            entry = std::move(held->second);
            state.held.erase(held);
            if (! entry.source->syncPlayback(state.playbackFor(scene, key), &source_error) ||
                ! entry.source->refreshFrame(&source_error) ||
                ! entry.source->currentFrame().valid()) {
                LOG_INFO("video texture \"%s\" did not survive the rebuild, opening it again: %s",
                         key.c_str(), source_error.c_str());
                entry        = VideoSourceEntry {};
                source_error = {};
            }
        }
        if (! entry.source) {
            if (scene.imageParser == nullptr) {
                return SetError(error, "the scene cannot resolve video texture \"" + key + "\"");
            }
            auto image = scene.imageParser->Parse(key);
            if (! image) {
                return SetError(error, "failed to parse video texture \"" + key + "\"");
            }
            // Not every key handed in is a video; the ones that are not belong to
            // the ordinary texture path and are simply not ours.
            if (! image->header.isVideo) continue;

            // A private source per call: every surface decodes its own clip.
            auto source = video::CreateVideoTextureSource(image, &source_error);
            if (! source) {
                return SetError(error,
                                "failed to open video texture \"" + key + "\": " + source_error);
            }
            if (! source->prime(&source_error)) {
                return SetError(error,
                                "failed to prime video texture \"" + key + "\": " + source_error);
            }
            // The first frame is what proves the media plays at all and what the
            // format rejection below is decided on. Importing it is the render
            // thread's job, because the import has to be encoded into a command
            // buffer this call does not have. A video opened under a scene that is
            // already some way into the clip is given that clock here, so that the
            // seek to it starts now and not on the first draw. The head of the clip
            // is on offer until it lands.
            if (! source->syncPlayback(state.playbackFor(scene, key), &source_error) ||
                ! source->refreshFrame(&source_error)) {
                return SetError(error,
                                "failed to read the first frame of video texture \"" + key +
                                    "\": " + source_error);
            }
            entry.source = std::move(source);
        }
        const auto frame = entry.source->currentFrame();
        if (! frame.valid()) {
            return SetError(error, "video texture \"" + key + "\" produced no first frame");
        }
        PixelKind kind = PixelKind::Bgra;
        if (! SupportedPixelFormat(frame.pixel_format, &kind)) {
            return SetError(error,
                            "video texture \"" + key + "\" decodes to the unsupported pixel " +
                                "format " + DescribePixelFormat(frame.pixel_format));
        }
        // The kernel is compiled here, at graph compile, for a 10-bit video, so
        // that the first frame does not stall on it.
        if (kind == PixelKind::TenBit && ! state.ensureTenBitPipeline(error)) return false;
        const bool is_nv12 = kind == PixelKind::Nv12;
        if (is_nv12 && state.nv12_pipeline == nil) {
            return SetError(error,
                            state.pipeline_error.empty()
                                ? std::string("no NV12 conversion pipeline for video textures")
                                : state.pipeline_error);
        }

        if (kind == PixelKind::Bgra && frame.needsDisplayTransform() && state.bgra_pipeline == nil) {
            return SetError(error,
                            state.pipeline_error.empty()
                                ? std::string("no BGRA display-transform pipeline for video textures")
                                : state.pipeline_error);
        }

        state.sources.emplace(key, std::move(entry));
    }

    state.publishSourceIdentity();
    return true;
}

#ifdef WESCENE_BUILD_TESTS
bool MetalVideoTextures::prepareForTests(const std::string&                         key,
                                         std::shared_ptr<video::VideoTextureSource> source,
                                         std::string*                               error)
{
    auto& state = *m_state;
    if (state.device == nil || state.texture_cache == nullptr) {
        return SetError(error, "MetalVideoTextures was not configured with a Metal device");
    }
    if (! source) return SetError(error, "a test video source must not be null");
    if (! source->prime(error) || ! source->refreshFrame(error)) return false;
    const auto frame = source->currentFrame();
    if (! frame.valid()) return SetError(error, "the test video source produced no first frame");
    PixelKind kind = PixelKind::Bgra;
    if (! SupportedPixelFormat(frame.pixel_format, &kind)) {
        return SetError(error,
                        "the test video source decodes to the unsupported pixel format " +
                            DescribePixelFormat(frame.pixel_format));
    }
    if (kind == PixelKind::TenBit && ! state.ensureTenBitPipeline(error)) return false;
    VideoSourceEntry entry;
    entry.source = std::move(source);
    state.sources.insert_or_assign(key, std::move(entry));
    return true;
}

std::uint64_t MetalVideoTextures::conversionsEncodedForTests() const
{
    return m_state->conversions_encoded;
}

std::uint64_t MetalVideoTextures::importsForTests() const { return m_state->imports; }

bool MetalVideoTextures::tenBitPipelineBuiltForTests() const
{
    return m_state->ten_bit_pipeline != nil;
}
#endif

void MetalVideoTextures::release()
{
    // Sources and slot textures go; anything a command buffer is still reading
    // is owned by that command buffer's pending block and outlives this call.
    m_state->sources.clear();
    m_state->demand.clear();
    if (m_state->texture_cache != nullptr) CVMetalTextureCacheFlush(m_state->texture_cache, 0);
}

void MetalVideoTextures::hold()
{
    auto& state = *m_state;
    for (auto& [key, entry] : state.sources) {
        if (! entry.source) continue;
        // The decoder and what has been reported of its work, so that taking it
        // back reports only what it does from here. The imported frame, the
        // destinations and the texture belong to the graph that is going.
        VideoSourceEntry kept;
        kept.source                  = std::move(entry.source);
        kept.selection               = entry.selection;
        kept.reported_decode_outputs = entry.reported_decode_outputs;
        kept.reported_seeks          = entry.reported_seeks;
        state.held.insert_or_assign(key, std::move(kept));
    }
    release();
}

void MetalVideoTextures::closeHeld() { m_state->held.clear(); }

bool MetalVideoTextures::owns(const std::string& key) const
{
    return m_state->sources.count(key) != 0;
}

bool MetalVideoTextures::empty() const { return m_state->sources.empty(); }

void MetalVideoTextures::setPaused(bool paused) { m_state->paused = paused; }

void MetalVideoTextures::setRate(float rate) { m_state->rate = rate; }

void MetalVideoTextures::setCounters(RendererCounters* counters)
{
    m_state->counters = counters;
}

void MetalVideoTextures::setDemand(std::map<std::string, VideoConsumerDemand> demand)
{
    m_state->demand = std::move(demand);
}

bool MetalVideoTextures::advancesOnItsOwn() const
{
    for (const auto& [key, entry] : m_state->sources) {
        (void)key;
        if (entry.source && entry.advancing) return true;
    }
    return false;
}

id<MTLTexture> MetalVideoTextures::texture(const std::string& key) const
{
    const auto iterator = m_state->sources.find(key);
    return iterator == m_state->sources.end() ? nil : iterator->second.texture;
}

VideoFramePlanes MetalVideoTextures::planes(const std::string& key) const
{
    const auto iterator = m_state->sources.find(key);
    if (iterator == m_state->sources.end() || ! iterator->second.current) return {};
    const auto& bundle = *iterator->second.current;
    if (bundle.luma == nil || bundle.chroma == nil) return {};
    // A 10-bit frame's planes are 16-bit and belong to its conversion: a shader
    // written for the 8-bit planes would read them as the wrong numbers.
    if (bundle.ten_bit) return {};
    return VideoFramePlanes {
        .luma   = bundle.luma,
        .chroma = bundle.chroma,
        .params = bundle.color,
        .width  = iterator->second.frame_width,
        .height = iterator->second.frame_height,
        .display_transform = bundle.frame.display_transform,
    };
}

VideoFramePath MetalVideoTextures::path(const std::string& key) const
{
    const auto iterator = m_state->sources.find(key);
    return iterator == m_state->sources.end() ? VideoFramePath::None : iterator->second.path;
}

VideoFramePath MetalVideoTextures::path() const
{
    VideoFramePath shared = VideoFramePath::None;
    for (const auto& [key, entry] : m_state->sources) {
        (void)key;
        if (entry.path == VideoFramePath::None) continue;
        if (shared == VideoFramePath::None) {
            shared = entry.path;
            continue;
        }
        // Two textures on different paths is a mixed scene, which is the
        // honest answer rather than whichever one came first.
        if (shared != entry.path) return VideoFramePath::Nv12Mixed;
    }
    return shared;
}

bool MetalVideoTextures::frameSize(const std::string& key, std::uint32_t* width,
                                   std::uint32_t* height) const
{
    const auto iterator = m_state->sources.find(key);
    if (iterator == m_state->sources.end() || ! iterator->second.has_import) return false;
    if (iterator->second.frame_width == 0 || iterator->second.frame_height == 0) return false;
    if (width != nullptr) *width = iterator->second.frame_width;
    if (height != nullptr) *height = iterator->second.frame_height;
    return true;
}

bool MetalVideoTextures::beginFrame(Scene& scene, id<MTLCommandBuffer> command, std::string* error)
{
    auto& state = *m_state;
    if (state.sources.empty()) return true;
    if (command == nil) return SetError(error, "video textures need a command buffer to import into");

    auto pending = std::make_shared<PendingFrames>();
    id<MTLComputeCommandEncoder> encoder = nil;
    const auto convert = [&](VideoSourceEntry& entry, const std::shared_ptr<FrameBundle>& bundle,
                              const video::VideoTextureFrame& frame, PixelKind kind) -> int {
        const bool nv12 = kind != PixelKind::Bgra;
        auto pipeline = kind == PixelKind::TenBit ? state.ten_bit_pipeline
                        : nv12                     ? state.nv12_pipeline
                                                   : state.bgra_pipeline;
        if (pipeline == nil) {
            SetError(error, state.pipeline_error.empty() ? "video conversion pipeline is unavailable" : state.pipeline_error);
            return -1;
        }
        DestinationSlot* slot = nullptr;
        auto destination = state.acquireDestination(entry, frame.displayWidth(), frame.displayHeight(), &slot);
        if (destination == nil) return 0;
        auto source = nv12 ? bundle->luma : bundle->sampled;
        bundle->destination = destination;
        bundle->sampled = destination;
        bundle->slot_busy = slot->busy;
        if (encoder == nil) {
            encoder = [command computeCommandEncoder];
            if (encoder == nil) {
                SetError(error, "failed to create a video conversion command encoder");
                return -1;
            }
            encoder.label = @"owe video texture conversion";
        }
        [encoder setComputePipelineState:pipeline];
        [encoder setTexture:source atIndex:0];
        [encoder setTexture:bundle->chroma atIndex:1];
        [encoder setTexture:destination atIndex:2];
        if (nv12) {
            const auto color = bundle->color;
            [encoder setBytes:&color length:sizeof(color) atIndex:0];
        }
        if (kind == PixelKind::TenBit) {
            const auto hdr = bundle->hdr;
            [encoder setBytes:&hdr length:sizeof(hdr) atIndex:2];
        }
        const auto transform = video::VideoTransformConstants(frame.display_transform);
        [encoder setBytes:&transform length:sizeof(transform) atIndex:1];
        const NSUInteger x = std::min<NSUInteger>(16u, pipeline.threadExecutionWidth);
        const NSUInteger y = std::min<NSUInteger>(16u, std::max<NSUInteger>(1u, pipeline.maxTotalThreadsPerThreadgroup / x));
        [encoder dispatchThreads:MTLSizeMake(frame.displayWidth(), frame.displayHeight(), 1u)
            threadsPerThreadgroup:MTLSizeMake(x, y, 1u)];
        ++state.conversions_encoded;
        if (state.counters != nullptr) state.counters->Set(OWE_RC_VIDEO_CONVERSIONS, state.conversions_encoded);
        return 1;
    };

    const bool ok = [&]() -> bool {
        for (auto& [key, entry] : state.sources) {
            if (! entry.source) continue;

            const auto effective = state.playbackFor(scene, key);
            entry.advancing = ! effective.paused && effective.rate > 0.0f;

            if (! entry.source->syncPlayback(effective, error)) return false;
            if (! entry.source->refreshFrame(error)) return false;

            const auto current = entry.source->currentFrame();
            if (! current.valid()) {
                // Nothing decoded yet. That is only a failure while there is
                // also nothing on screen to keep showing.
                if (entry.has_import) continue;
                return SetError(error, "video texture \"" + key + "\" has no frame to display");
            }
            state.reportSourceWork(entry, current.generation);

            // Asked before anything is imported: a frame every consumer samples
            // as planes must not be converted first. An unnamed key keeps the
            // default, which is the single-image behaviour this class had
            // before planes existed.
            const auto demanded = state.demand.find(key);
            const VideoConsumerDemand demand =
                demanded == state.demand.end() ? VideoConsumerDemand {} : demanded->second;

            // A generation already imported is already on screen, unless what
            // its consumers need has changed since -- the setting was toggled,
            // or a material's variant became usable. Passes that sample it
            // several times share this one import; nothing is converted twice.
            if (entry.has_import && entry.imported_generation == current.generation &&
                (entry.demand_independent ||
                 (entry.satisfied.planes == demand.planes && entry.satisfied.rgb == demand.rgb))) {
                // Retained into this command buffer even though nothing was
                // imported for it: the plane and image textures this frame
                // samples are vended from that bundle's Core Video wrappers,
                // and the wrappers have to outlive the commands that read them.
                if (entry.current) pending->bundles.push_back(entry.current);
                continue;
            }

            auto bundle = std::make_shared<FrameBundle>();
            // Retained under the producer's own lock where the source can do
            // it, so the frame cannot be released between the read and the
            // retain.
            if (! entry.source->retainCurrentFrame(&bundle->frame)) {
                video::RetainAppleVideoFrame(current, &bundle->frame);
            }
            if (! bundle->frame.valid()) {
                return SetError(error,
                                "failed to retain the current frame of video texture \"" + key +
                                    "\"");
            }
            const auto& frame = bundle->frame;
            PixelKind   kind = PixelKind::Bgra;
            if (! SupportedPixelFormat(frame.pixel_format, &kind)) {
                return SetError(error,
                                "video texture \"" + key + "\" changed to the unsupported pixel " +
                                    "format " + DescribePixelFormat(frame.pixel_format));
            }
            CVPixelBufferRef pixel_buffer = static_cast<CVPixelBufferRef>(frame.pixel_buffer);
            if (pixel_buffer == nullptr) {
                return SetError(error,
                                "video texture \"" + key + "\" produced a frame with no pixel "
                                                           "buffer");
            }

            // Decided per frame from the format the decoder really produced,
            // never from the first frame's: software decode hands back BGRA and
            // VideoToolbox hands back NV12 for the same file, and either can
            // take over mid-playback.
            VideoFramePath path = VideoFramePath::None;
            if (kind == PixelKind::Bgra) {
                const CVReturn result =
                    CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                              state.texture_cache,
                                                              pixel_buffer,
                                                              nullptr,
                                                              kVideoDestinationPixelFormat,
                                                              frame.width,
                                                              frame.height,
                                                              0,
                                                              &bundle->wrappers[0]);
                if (result != kCVReturnSuccess || bundle->wrappers[0] == nullptr) {
                    return SetError(error,
                                    "failed to import the BGRA frame of video texture \"" + key +
                                        "\"");
                }
                bundle->sampled = CVMetalTextureGetTexture(bundle->wrappers[0]);
                if (bundle->sampled == nil) {
                    return SetError(error,
                                    "Core Video returned no texture for video texture \"" + key +
                                        "\"");
                }
                path = VideoFramePath::Bgra;
                if (frame.needsDisplayTransform()) {
                    const int converted = convert(entry, bundle, frame, PixelKind::Bgra);
                    if (converted < 0) return false;
                    if (converted == 0) {
                        if (entry.current) pending->bundles.push_back(entry.current);
                        continue;
                    }
                }
            } else if (kind == PixelKind::TenBit) {
                // 10-bit samples sit in the top bits of 16-bit words, imported as
                // they are. Plane sampling stays 8-bit only, so the conversion is
                // not optional here whatever the consumers asked for: it is also
                // what tone maps an HDR picture, and the one image it writes is
                // all any consumer ever samples.
                if (! state.ensureTenBitPipeline(error)) return false;
                // The planes' own sizes, not half the luma's: a buffer whose width
                // is odd has a chroma plane one column wider than that.
                const std::size_t luma_width    = CVPixelBufferGetWidthOfPlane(pixel_buffer, 0);
                const std::size_t luma_height   = CVPixelBufferGetHeightOfPlane(pixel_buffer, 0);
                const std::size_t chroma_width  = CVPixelBufferGetWidthOfPlane(pixel_buffer, 1);
                const std::size_t chroma_height = CVPixelBufferGetHeightOfPlane(pixel_buffer, 1);
                const CVReturn luma_result =
                    CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                              state.texture_cache,
                                                              pixel_buffer,
                                                              nullptr,
                                                              MTLPixelFormatR16Unorm,
                                                              luma_width,
                                                              luma_height,
                                                              0,
                                                              &bundle->wrappers[0]);
                const CVReturn chroma_result =
                    CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                              state.texture_cache,
                                                              pixel_buffer,
                                                              nullptr,
                                                              MTLPixelFormatRG16Unorm,
                                                              chroma_width,
                                                              chroma_height,
                                                              1,
                                                              &bundle->wrappers[1]);
                if (luma_result != kCVReturnSuccess || bundle->wrappers[0] == nullptr ||
                    chroma_result != kCVReturnSuccess || bundle->wrappers[1] == nullptr) {
                    return SetError(error,
                                    "failed to import the 10-bit planes of video texture \"" + key +
                                        "\"");
                }
                bundle->luma   = CVMetalTextureGetTexture(bundle->wrappers[0]);
                bundle->chroma = CVMetalTextureGetTexture(bundle->wrappers[1]);
                if (bundle->luma == nil || bundle->chroma == nil) {
                    return SetError(error,
                                    "Core Video returned no plane textures for video texture \"" +
                                        key + "\"");
                }
                const auto description = video::AppleVideoFrameColorDescription(frame);
                video::ReportTenBitColor(description);
                bundle->ten_bit = true;
                bundle->color   = video::MakeYuvColorParams(description);
                bundle->hdr     = video::MakeHdrConversionParams(description);

                const int converted = convert(entry, bundle, frame, PixelKind::TenBit);
                if (converted < 0) return false;
                if (converted == 0) {
                    if (entry.current) pending->bundles.push_back(entry.current);
                    continue;
                }
                path = VideoFramePath::Yuv10Converted;
            } else {
                // Both planes, whichever path the consumers take: the direct
                // one samples them and the conversion reads them.
                const CVReturn luma_result =
                    CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                              state.texture_cache,
                                                              pixel_buffer,
                                                              nullptr,
                                                              MTLPixelFormatR8Unorm,
                                                              frame.width,
                                                              frame.height,
                                                              0,
                                                              &bundle->wrappers[0]);
                const CVReturn chroma_result =
                    CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                              state.texture_cache,
                                                              pixel_buffer,
                                                              nullptr,
                                                              MTLPixelFormatRG8Unorm,
                                                              frame.width / 2,
                                                              frame.height / 2,
                                                              1,
                                                              &bundle->wrappers[1]);
                if (luma_result != kCVReturnSuccess || bundle->wrappers[0] == nullptr ||
                    chroma_result != kCVReturnSuccess || bundle->wrappers[1] == nullptr) {
                    return SetError(error,
                                    "failed to import the NV12 planes of video texture \"" + key +
                                        "\"");
                }
                bundle->luma   = CVMetalTextureGetTexture(bundle->wrappers[0]);
                bundle->chroma = CVMetalTextureGetTexture(bundle->wrappers[1]);
                if (bundle->luma == nil || bundle->chroma == nil) {
                    return SetError(error,
                                    "Core Video returned no plane textures for video texture \"" +
                                        key + "\"");
                }
                bundle->color = video::AppleVideoFrameColorParams(frame);

                if (! demand.rgb) {
                    // Nothing asked for one image, so no destination is
                    // acquired, none is allocated and no conversion is encoded.
                    path = VideoFramePath::Nv12Direct;
                } else {
                    const int converted = convert(entry, bundle, frame, PixelKind::Nv12);
                    if (converted < 0) return false;
                    if (converted == 0) {
                        if (entry.current) pending->bundles.push_back(entry.current);
                        continue;
                    }
                    // One conversion serves every consumer that needs an image,
                    // however many passes that is.
                    path = demand.planes ? VideoFramePath::Nv12Mixed
                                         : VideoFramePath::Nv12Converted;
                }
            }

            ++state.imports;
            if (state.counters != nullptr) {
                state.counters->Set(OWE_RC_VIDEO_IMPORTS, state.imports);
            }
            entry.texture             = bundle->sampled;
            entry.imported_generation = frame.generation;
            entry.has_import          = true;
            entry.frame_width         = frame.displayWidth();
            entry.frame_height        = frame.displayHeight();
            entry.path                = path;
            entry.satisfied           = demand;
            entry.demand_independent  = kind == PixelKind::TenBit;
            // The previous bundle is dropped here, which frees its slot unless
            // a command buffer still holds it through `pending`.
            entry.current = bundle;
            pending->bundles.push_back(std::move(bundle));
        }
        return true;
    }();

    if (encoder != nil) [encoder endEncoding];
    if (! pending->bundles.empty()) {
        // The handler owns the frames, not the renderer: it may run after
        // `release()` or after this object is gone, on a thread Metal chose.
        [command addCompletedHandler:^(id<MTLCommandBuffer>) {
            pending->bundles.clear();
        }];
    }
    if (++state.frames % kTextureCacheFlushInterval == 0 && state.texture_cache != nullptr) {
        CVMetalTextureCacheFlush(state.texture_cache, 0);
    }
    return ok;
}

} // namespace wallpaper::metal
