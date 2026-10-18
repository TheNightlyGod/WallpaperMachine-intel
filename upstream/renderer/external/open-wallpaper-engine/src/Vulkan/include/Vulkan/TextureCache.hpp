#pragma once

#include "Video/VideoFramePacing.hpp"
#include "Video/VideoTextureSource.hpp"
#include "Parameters.hpp"
#include "Type.hpp"
#include "Core/NoCopyMove.hpp"
#include "Core/MapSet.hpp"
#include "Core/RendererCounters.hpp"

#include <cstddef>
#include <cstdint>
#include <algorithm>
#include <memory>
#include <vector>

namespace wallpaper
{

struct Image;
namespace video { class AppleVideoMetalTexturePool; }

namespace vulkan
{

VkFormat             ToVkType(TextureFormat);
VkSamplerAddressMode ToVkType(TextureWrap);
VkFilter             ToVkType(TextureFilter);
VkSamplerCreateInfo  GenRenderTargetSamplerInfo();

enum class TexUsage
{
    COLOR,
    DEPTH,
    MSAA_COLOR,
};

using TexHash = std::size_t;

struct VideoTextureSubmissionStats {
    std::uint64_t update_calls { 0 };
    std::uint64_t cache_hits { 0 };
    std::uint64_t new_imports { 0 };
    std::uint64_t evictions { 0 };
    /// Vulkan images created to alias an imported Metal texture. A pooled
    /// conversion destination gets one for its lifetime, so on the NV12 path
    /// this is bounded by `converted_destinations_created`, not by
    /// `new_imports`.
    std::uint64_t imported_images_created { 0 };
    /// New imports that reused the Vulkan image of their pooled destination.
    std::uint64_t imported_images_reused { 0 };
    /// UNDEFINED to SHADER_READ_ONLY transitions recorded into a frame's own
    /// command buffer for images that were never used before. There is no
    /// submission for them outside the frame.
    std::uint64_t first_use_transitions_recorded { 0 };
    std::uint64_t conversion_calls { 0 };
    std::uint64_t converted_destinations_created { 0 };
    std::uint64_t converted_destinations_reused { 0 };
    /// Imports that asked the pool to book a conversion destination and were
    /// not given one. Each is a frame this cache did not import and, above
    /// all, did not allocate for: the previously imported frame stayed on
    /// screen instead.
    ///
    /// `ReserveFresh` has no refusal path today — the in-flight slot cap is
    /// reported, never enforced, because refusing withholds the import whose
    /// delivery is what makes a consumer release the destination the next
    /// request needs — so this stays zero in practice. It is the guard's
    /// counter: anything other than zero means a reservation came back
    /// unbooked and the import correctly declined to allocate behind it.
    std::uint64_t conversion_reservations_refused { 0 };
    /// Destinations idle in the reuse pool. The Available state alone: a
    /// destination an import is using is deliberately not counted here.
    std::uint64_t pool_cached_texture_count { 0 };
    std::uint64_t pool_cached_bytes { 0 };
    /// Largest the pooled set has been since this pool was created, which is
    /// what a reuse ceiling has to be judged against.
    std::uint64_t pool_peak_cached_bytes { 0 };
    /// Handed to an import that has not yet reported the GPU may use it.
    std::uint64_t pool_checked_out_bytes { 0 };
    /// Referenced by a live imported frame.
    std::uint64_t pool_awaiting_gpu_bytes { 0 };
    /// Every conversion destination the pool is keeping alive: cached plus
    /// checked out plus awaiting GPU. This is an allocation ledger over those
    /// `MTLTexture`s and nothing else — decode pixel buffers, Core Video plane
    /// wrappers, Vulkan images and the swapchain are all outside it.
    std::uint64_t pool_live_bytes { 0 };
    std::uint64_t pool_peak_live_bytes { 0 };
    /// Granted reservations that are not allocations yet: an intent, so it is
    /// not part of `pool_live_bytes`.
    std::uint64_t pool_reserved_estimate_bytes { 0 };
    /// Reservations granted although the ceiling had no room, because refusing
    /// a destination the conversion needs would drop the frame.
    std::uint64_t pool_over_ceiling_grants { 0 };
    std::uint64_t pool_live_slot_count { 0 };
    std::uint64_t pool_hits { 0 };
    std::uint64_t pool_misses { 0 };
    std::uint64_t pool_recycles { 0 };
    std::uint64_t pool_evictions { 0 };
    /// Destinations the pool declined to take back into its cache. Admission
    /// only: a reservation is never refused for capacity.
    std::uint64_t pool_refusals { 0 };
    /// Reservations granted while more destinations were already in flight
    /// than the structural expectation accounts for — unretired conversion
    /// submissions, plus each live video texture's imported-frame cap, plus
    /// the destination every consumer holding an `ImageSlotsRef` retains.
    /// Reported rather than refused, so this is the figure that says a scene
    /// is holding more frames than the caps predict, without that ever
    /// stopping playback.
    std::uint64_t pool_in_flight_cap_breaches { 0 };
};

enum class TextureUploadSynchronization
{
    Blocking,
    Deferred,
};

inline video::VideoPlaybackState
ResolveEffectiveVideoPlaybackState(const video::VideoPlaybackState& global_state,
                                   const video::VideoPlaybackState& layer_state) {
    video::VideoPlaybackState effective_state = layer_state;
    effective_state.paused = global_state.paused || layer_state.paused;
    effective_state.rate =
        std::max(0.0f, global_state.rate) * std::max(0.0f, layer_state.rate);
    effective_state.scene_elapsed_seconds = layer_state.scene_elapsed_seconds;
    return effective_state;
}

struct TextureKey {
    i32           width;
    i32           height;
    TexUsage      usage;
    TextureFormat format;
    TextureSample sample;
    uint          mipmap_level { 1 };
    VkSampleCountFlagBits sample_count { VK_SAMPLE_COUNT_1_BIT };

    static TexHash HashValue(const TextureKey&);
};

// CPU-side planning only. Descriptor-visible color textures stay single-sampled;
// MSAA_COLOR is the private render-pass color sidecar resolved into COLOR.
VkSampleCountFlagBits PlannedTextureSampleCountForGpuAllocation(TextureKey key);

class TextureCache : NoCopy, NoMove {
public:
    TextureCache(const Device&);
    ~TextureCache();

    enum class VideoFrameState { Idle, Recording, Submitted };
    bool Clear(std::string* error = nullptr);
    /// `Clear` for a graph that is about to be prepared again for the scene that
    /// is drawing it. The live video textures are not closed: each is set aside
    /// as its decoder, with what is counted of it, for `FindVideoTex` to give back
    /// to the pass that binds the same key, and `CloseHeldVideos` closes the ones
    /// no pass took back. The frames imported from them go, as in `Clear`.
    bool ClearForRebuild(std::string* error = nullptr);
    /// Closes the videos `ClearForRebuild` set aside and `FindVideoTex` did not
    /// give back: the ones the graph prepared since no longer uses. The renderer
    /// calls it as the compile ends, however it ends, and when the clear that
    /// set them aside fails.
    void CloseHeldVideos();
    /// Evicts render-target textures only, keeping uploaded images and live
    /// video decoders. Used when the internal render scale changes, which
    /// resizes render targets but nothing else.
    bool ClearRenderTargets(std::string* error = nullptr);
    bool BeginVideoFrameRecording(std::string* error = nullptr);
    /// Records, into the frame's own command buffer, the first-use layout
    /// transition of every imported video image that has not had one yet.
    /// The renderer calls it right after beginning that command buffer, before
    /// anything samples. A transition counts as done once the frame is
    /// submitted; an abandoned recording puts it back for the next frame.
    void RecordVideoFirstUseTransitions(vvk::CommandBuffer& command);
    void PinVideoFrame(const ImageSlotsRef&);
    void MarkVideoFrameSubmitted();
    void CompleteVideoFrame();
    void AbandonVideoFrameRecording();
    void InvalidateVideoDestinationPool();
    bool WaitForPendingUploads(std::string* error = nullptr);
    void DiscardAfterDeviceLoss() noexcept;

    std::optional<ExImageParameters> CreateExTex(uint32_t witdh, uint32_t height, VkFormat,
                                                 VkImageTiling);
    ImageSlotsRef CreateTex(Image&);
    /// `CreateTex` for an image that may be a video, whose first frame is asked
    /// for at `video_state`'s clock and not at the head of the clip: a graph built
    /// again opens its videos again while the clip is playing.
    ImageSlotsRef CreateTex(Image&, const video::VideoPlaybackState& video_state);
    /// The slots `CreateTex` already holds for this image key, if any. For a
    /// cached key `CreateTex` returns them without reading the pixels it was
    /// handed, so a caller that asks first can skip decoding the image again.
    /// Static images only: videos live in their own map and are never found.
    std::optional<ImageSlotsRef> FindTex(std::string_view key) const;
    /// The slots of a video that is open for this key already: one this graph has
    /// open, or one `ClearForRebuild` set aside, which is taken back and asked for
    /// its frame at `video_state`'s clock like any video a pass binds. A caller
    /// that asks first neither reads the video again, which for one packaged in
    /// the scene copies and hashes the whole file, nor opens a decoder at the head
    /// of its clip. Empty when there is none, or when the one set aside failed
    /// while it waited; `CreateTex` then opens the video as it would any.
    std::optional<ImageSlotsRef> FindVideoTex(std::string_view key,
                                              const video::VideoPlaybackState& video_state);
    ImageSlotsRef ReplaceTex(Image&, std::string_view previous_key);
    void          CollectCompletedUploads();
    void          SetVideoPlaybackPaused(bool paused);
    void          SetVideoPlaybackRate(float rate);
    [[nodiscard]] VideoTextureSubmissionStats VideoSubmissionStats() const;
    /// Shortest frame period among the live video sources, in seconds, or 0
    /// when none of them can report one. The shortest is the safe answer: it
    /// is the rate at which something can still change.
    [[nodiscard]] double ShortestVideoFramePeriod() const;
    /// Calls `visit(texture, frame, generation)` for every video texture with
    /// the imported frame it currently shows, in a stable order. Identity only:
    /// nothing is imported, promoted or pinned, so a caller can ask whether a
    /// frame would show the same video pictures as the last one presented.
    template<typename Visit>
    void ForEachCurrentVideoFrame(Visit&& visit) const {
        for (const auto& [key, video_tex] : m_video_tex_map) {
            if (video_tex == nullptr) continue;
            const auto* frame = video_tex->current_frame;
            visit(static_cast<const void*>(video_tex.get()), static_cast<const void*>(frame),
                  frame != nullptr ? frame->generation : uint64_t { 0 },
                  frame != nullptr ? frame->pts_seconds : 0.0);
        }
    }
    /// Counters owned by the scene, shared with the frame clock and the
    /// renderer. Sources created after this call receive it too.
    void                                      SetCounters(RendererCounters* counters);
    void                                      ResetVideoSubmissionStats();
    double                           GetVideoDuration(std::string_view key) const;
    bool UpdateVideoFrame(std::string_view key, const video::VideoPlaybackState& playback_state,
                          ImageSlotsRef* out, std::string* error = nullptr);
    bool ReadbackImageSample(const ImageParameters& image, uint32_t x, uint32_t y, uint32_t width,
                             uint32_t height, std::vector<std::uint8_t>* out,
                             std::string* error = nullptr);

    std::optional<ImageParameters> Query(std::string_view key, TextureKey content_hash,
                                         bool persist = false);

    /// Gives `key` an image no other key has been handed, and never hands it
    /// back to the pool. For a target that carries its pixels into the next
    /// frame: an image it shared with another key would be drawn over by that
    /// key every frame. Called before any pass is prepared, as preparing a pass
    /// releases the images of the targets it is the last to use; a key that
    /// already has an image keeps it.
    std::optional<ImageParameters> Reserve(std::string_view key, TextureKey content_hash);

    void MarkShareReady(std::string_view key);

    /// Takes a render target out of the reuse pool so its pixels survive into
    /// the next frame. Fails when the key no longer owns an allocation,
    /// because another key may already have been handed the same image, and
    /// when the key took its image from a key that released it, because that
    /// key's passes still draw into it.
    bool PinRenderTarget(std::string_view key);

    /// Points `key` at the allocation `source` already owns, so an eliminated
    /// copy leaves both names reading the same pixels. Both keys are pinned:
    /// releasing one would let the pool re-issue an image the other still
    /// reads. Fails when `source` owns no allocation.
    bool AliasRenderTarget(std::string_view key, std::string_view source);

    /// Allocated size of a render target, or zero when the key owns none.
    uint64_t RenderTargetBytes(std::string_view key) const;

    void RecGenerateMipmaps(vvk::CommandBuffer& cmd, const ImageParameters& image) const;

private:
    friend struct TextureCacheVideoInteropTestAccess;
    ImageSlotsRef CreateVideoTex(Image&, std::shared_ptr<video::VideoTextureSource>,
                                 const video::VideoPlaybackState& video_state = {});
    struct ImportedVideoFrame;
    struct VideoImportImage;
    ImageSlotsRef                     CreateTex(Image&, TextureUploadSynchronization,
                                                const video::VideoPlaybackState& video_state = {});
    bool                              clearCache(bool hold_videos, std::string* error);
    struct VideoTex;
    ImageSlotsRef                     currentVideoSlots(const VideoTex& video_tex) const;
    std::optional<VmaImageParameters> CreateTex(TextureKey);
    VkSampler                         GetOrCreateSampler(TextureKey, std::string* error);
    /// Exports, once, the Metal device and the MTLCommandQueue MoltenVK runs
    /// the graphics queue on; the latter is what NV12 conversions are
    /// committed to so the frames that sample them are ordered after them.
    void*                             GetMetalDeviceHandle(std::string* error);
    void                              allocateCmd();
    struct TextureUploadSubmissionSlot {
        vvk::CommandBuffers              commands;
        vvk::CommandBuffer               command;
        vvk::Fence                       fence;
        bool                             pending { false };
        uint64_t                         submitted_serial { 0 };
        std::vector<VmaBufferParameters> staging_buffers;
    };
    /// The Vulkan image and view aliasing one imported Metal texture. For a
    /// pooled conversion destination it is made once and kept as the pool's
    /// companion of that destination, so it retires exactly when the pool
    /// lets the destination go. Samplers are per video texture and are not
    /// part of it.
    struct VideoImportImage {
        enum class Layout { Undefined, TransitionRecorded, ShaderReadOnly };
        ExImageParameters image;
        Layout            layout { Layout::Undefined };
    };
    TextureUploadSubmissionSlot* acquireTextureUploadSubmissionSlot(std::string* error);
    bool                         waitForTextureUploadSlot(TextureUploadSubmissionSlot& slot,
                                                          std::string* error);
    bool                         ensureTextureUploadSlot(TextureUploadSubmissionSlot&, std::string* error);
    bool                         waitForPendingTextureUploads(std::string* error);
    void                         collectCompletedTextureUploads();
    void                         retireRuntimeTexture(std::string_view key);
    std::shared_ptr<VideoImportImage> importedImageFor(void* metal_texture, uint32_t width,
                                                      uint32_t height, bool pooled,
                                                      std::string* error);
    vvk::CommandBuffers               m_tex_cmds;
    vvk::CommandBuffer                m_tex_cmd;
    /// Imported images whose first-use transition no frame has recorded yet.
    /// Weak: an image every frame has dropped needs no transition.
    std::vector<std::weak_ptr<VideoImportImage>>   m_video_first_use_pending;
    /// Transitions recorded into the frame being recorded, awaiting its
    /// submission (done) or its abandonment (pending again).
    std::vector<std::shared_ptr<VideoImportImage>> m_video_first_use_recorded;

    const Device&                m_device;
    /// Shared, because a cache entry is not the only holder: a pass bound to
    /// an image keeps its own reference, so replacing or clearing a key
    /// retires the name while the image itself lives until nothing samples it.
    Map<std::string, std::shared_ptr<ImageSlots>> m_tex_map;
    struct ImportedVideoFrame {
        /// Owns the imported frame: the Core Video texture wrapper, the pixel
        /// buffer and the Metal texture retire together when the last holder of
        /// this lease drops it.
        std::shared_ptr<void> frame_lease;
        /// Declared after the lease so it is released first, as the image it
        /// aliases the lease's texture with must not outlive that texture's
        /// last owner here.
        std::shared_ptr<VideoImportImage> vulkan_image;
        /// `vulkan_image`'s handles with this video texture's sampler.
        ImageParameters       image;
        uint64_t              generation { 0 };
        double                pts_seconds { 0.0 };
        uint64_t              last_used { 0 };
        mutable uint64_t      last_pinned_recording { 0 };
        void*                 surface_identity { nullptr };
        uint32_t              pixel_format { 0 };
    };
    struct VideoTex {
        TextureSample                                    sample;
        std::shared_ptr<video::VideoTextureSource>       source;
        ImportedVideoFrame*                              current_frame { nullptr };
        std::vector<std::shared_ptr<ImportedVideoFrame>> imported_frames;
        uint64_t                                         frame_use_serial { 0 };
        /// Turns the displayed generation sequence into selected / reused /
        /// skipped, which is how a pacing change is falsified.
        video::VideoFrameSelectionTracker                selection;
        /// Decoder totals already reported, so the counters accumulate the
        /// delta rather than the running total of every source.
        uint64_t                                         reported_decode_outputs { 0 };
        uint64_t                                         reported_seeks { 0 };
        /// Set by an update that ran while nothing was counting, which does
        /// not advance the totals above or `selection`. The next counted
        /// update only takes them as its starting point, so work done while
        /// counting was off is never reported as work done now.
        bool                                             counters_stale { false };
        /// Consumers of this video texture, observed rather than assumed.
        ///
        /// Every consumer calls `UpdateVideoFrame` for its own slot once per
        /// recording cycle, so counting those calls between
        /// `BeginVideoFrameRecording` and the next one counts the consumers
        /// that asked. It matters because each consumer retains one imported
        /// frame in its own `ImageSlotsRef` — one per slot, never a list —
        /// and those retentions are the term the per-video-texture caps do
        /// not cover.
        ///
        /// `consumers_in_cycle` is the tally for `consumer_cycle_serial`;
        /// `observed_consumers` is the high-water mark across closed cycles.
        /// It is a high-water mark and not the latest tally because a hidden
        /// consumer stops calling in while still holding the frame it last
        /// received: the cycle it goes quiet in must not drop it from the
        /// figure. The published value is the larger of the two, so a
        /// consumer set still growing inside the current cycle is covered
        /// immediately rather than a cycle late.
        uint64_t                                         consumer_cycle_serial { 0 };
        uint32_t                                         consumers_in_cycle { 0 };
        uint32_t                                         observed_consumers { 0 };
    };
    static constexpr std::size_t kMaxImportedVideoFramesPerVideoTex { 4 };
    /// Conversion submissions whose frame may be dropped before the GPU ran
    /// them. Not a gate: the pool parks such a destination until its command
    /// buffer completes. It is the unretired-submission term of the in-flight
    /// expectation.
    static constexpr std::size_t kMaxPendingVideoImportSubmissions { 2 };
    static constexpr std::size_t kMaxPendingTextureUploads { 8 };
    bool                CanReuseVideoFrameImport(const video::VideoTextureFrame& frame) const;
    std::shared_ptr<ImportedVideoFrame> FindImportedVideoFrame(
        VideoTex& video_tex, const video::VideoTextureFrame& frame, void* surface_identity) const;
    bool                EnsureVideoFrameCacheRoom(VideoTex& video_tex, std::string* error);
    /// Destinations this cache can legitimately hold in flight right now:
    /// `kMaxPendingVideoImportSubmissions` plus, for every live video texture,
    /// `kMaxImportedVideoFramesPerVideoTex` plus that texture's observed
    /// consumer count. Published to the conversion pool so a breach of it
    /// means a genuine leak rather than an ordinary busy scene.
    std::uint32_t       videoInFlightSlotExpectation() const;
    /// Counts this call as one consumer of `video_tex` for the current
    /// recording cycle. Only tallies during a recording, because outside one
    /// there is no cycle to attribute a consumer to.
    void                observeVideoConsumer(VideoTex& video_tex);
    /// Publishes how many decoder instances this cache consumes and, when
    /// there is exactly one, its identity, so source work can be attributed
    /// to a running decoder rather than to a file path.
    void                publishVideoSourceIdentity();
    Map<std::string, std::unique_ptr<VideoTex>> m_video_tex_map;
    /// What `ClearForRebuild` set aside: each video texture without the frames
    /// imported from it, which belonged to the graph that went.
    Map<std::string, std::unique_ptr<VideoTex>> m_held_video_tex_map;
    video::VideoPlaybackState                   m_video_playback_state {};
    /// Null outside a scene, e.g. in tests and standalone tools.
    RendererCounters*                           m_counters { nullptr };
    VideoTextureSubmissionStats                 m_video_submission_stats {};
    std::shared_ptr<video::AppleVideoMetalTexturePool> m_video_destination_pool;
    /// Latched on the first reservation the budget declined to book and
    /// cleared by the next grant, so such an episode is logged once instead of
    /// once per frame at the display's rate. Distinct from the in-flight slot
    /// cap, which is reported by the pool and never declines anything.
    bool m_video_reservation_refusal_reported { false };
    VideoFrameState m_video_frame_state { VideoFrameState::Idle };
    uint64_t m_video_recording_serial { 0 };
    std::vector<std::shared_ptr<const void>> m_video_frame_pins;
    bool m_video_recycling_disabled { false };
    bool m_device_lost { false };
    std::vector<TextureUploadSubmissionSlot>    m_texture_upload_slots;
    uint64_t                                    m_texture_upload_submit_serial { 0 };
    std::vector<std::shared_ptr<ImageSlots>>    m_retired_runtime_textures;
    void*                                       m_metal_device { nullptr };
    /// Borrowed id<MTLCommandQueue> MoltenVK owns for the graphics queue.
    void*                                       m_metal_command_queue { nullptr };
    bool                                        m_metal_device_queried { false };

    struct CachedSampler {
        TexHash      hash { 0 };
        vvk::Sampler sampler;
    };
    std::vector<CachedSampler> m_sampler_cache;

    struct QueryTex {
        idx                index { 0 };
        bool               share_ready { false };
        bool               persist { false };
        TexHash            content_hash;
        TextureFormat      format { TextureFormat::RGBA8 };
        VmaImageParameters image;
        Set<std::string>   query_keys;
    };
    std::vector<std::unique_ptr<QueryTex>> m_query_texs;
    Map<std::string, QueryTex*>            m_query_map;

    std::optional<ImageParameters> AllocateQuery(std::string_view key, TextureKey content_hash,
                                                 bool persist);
};

} // namespace vulkan
} // namespace wallpaper
