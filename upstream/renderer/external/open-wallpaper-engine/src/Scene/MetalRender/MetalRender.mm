#include "MetalRender/MetalRender.hpp"

#include "Runtime/RuntimeImageSource.hpp"

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include "MetalPosterCapture.hpp"
#include "MetalVideoTextures.hpp"

#include "MetalRender/MetalBlend.hpp"
#include "MetalRender/MetalCapability.hpp"
#include "MetalRender/MetalVideoSupport.hpp"
#include "MetalRender/MetalProjection.hpp"
#include "MetalRender/MetalShaderReflection.hpp"
#include "MetalRender/SceneMetalProgram.hpp"
#include "Shader/RustShaderBridge.hpp"
#include "MetalRender/ScenePassDescription.hpp"

#include "CopyPass.hpp"
#include "CustomShaderPass.hpp"
#include "PassCommon.hpp"
#include "PrePass.hpp"
#include "RenderGraph/RenderGraph.hpp"
#include "VulkanRender/CopyElision.hpp"
#include "VulkanRender/StaticSubgraphCache.hpp"
#include "VulkanRender/UnchangedPresent.hpp"

#include "Image.hpp"
#include "Interface/IImageParser.h"
#include "Interface/IShaderValueUpdater.h"
#include "Scene/Scene.h"
#include "SpecTexs.hpp"
#include "Utils/AutoDeletor.hpp"
#include "Utils/Logging.h"

#include <Eigen/Dense>

#include <algorithm>
#include <atomic>
#include <limits>
#include <charconv>
#include <chrono>
#include <deque>
#include <thread>
#include <unordered_set>
#include <cmath>
#include <cstring>
#include <functional>
#include <map>
#include <optional>
#include <span>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

// The mirrored enumerators the rest of this library is written against have to
// be the framework's own values, or every pipeline is built with plausible
// nonsense. Checked here, where both definitions are visible.
static_assert((uint32_t)wallpaper::metal::MetalBlendFactor::Zero == MTLBlendFactorZero, "");
static_assert((uint32_t)wallpaper::metal::MetalBlendFactor::One == MTLBlendFactorOne, "");
static_assert((uint32_t)wallpaper::metal::MetalBlendFactor::SourceColor == MTLBlendFactorSourceColor,
              "");
static_assert((uint32_t)wallpaper::metal::MetalBlendFactor::OneMinusSourceColor ==
                  MTLBlendFactorOneMinusSourceColor,
              "");
static_assert((uint32_t)wallpaper::metal::MetalBlendFactor::SourceAlpha == MTLBlendFactorSourceAlpha,
              "");
static_assert((uint32_t)wallpaper::metal::MetalBlendFactor::OneMinusSourceAlpha ==
                  MTLBlendFactorOneMinusSourceAlpha,
              "");
static_assert((uint32_t)wallpaper::metal::MetalBlendFactor::DestinationColor ==
                  MTLBlendFactorDestinationColor,
              "");
static_assert((uint32_t)wallpaper::metal::MetalBlendFactor::OneMinusDestinationColor ==
                  MTLBlendFactorOneMinusDestinationColor,
              "");
static_assert((uint32_t)wallpaper::metal::MetalBlendFactor::DestinationAlpha ==
                  MTLBlendFactorDestinationAlpha,
              "");
static_assert((uint32_t)wallpaper::metal::MetalBlendFactor::OneMinusDestinationAlpha ==
                  MTLBlendFactorOneMinusDestinationAlpha,
              "");
static_assert((uint32_t)wallpaper::metal::MetalBlendOperation::Add == MTLBlendOperationAdd, "");
static_assert((uint32_t)wallpaper::metal::MetalCullMode::None == MTLCullModeNone, "");
static_assert((uint32_t)wallpaper::metal::MetalCullMode::Front == MTLCullModeFront, "");
static_assert((uint32_t)wallpaper::metal::MetalCullMode::Back == MTLCullModeBack, "");
static_assert((uint32_t)wallpaper::metal::MetalLoadAction::DontCare == MTLLoadActionDontCare, "");
static_assert((uint32_t)wallpaper::metal::MetalLoadAction::Load == MTLLoadActionLoad, "");
static_assert((uint32_t)wallpaper::metal::MetalLoadAction::Clear == MTLLoadActionClear, "");
static_assert((uint32_t)wallpaper::metal::MetalPixelFormat::RGBA8Unorm == MTLPixelFormatRGBA8Unorm,
              "");
static_assert((uint32_t)wallpaper::metal::MetalPixelFormat::RGBA8Unorm_sRGB ==
                  MTLPixelFormatRGBA8Unorm_sRGB,
              "");
static_assert((uint32_t)wallpaper::metal::MetalPixelFormat::RGBA16Float ==
                  MTLPixelFormatRGBA16Float, "");
static_assert((uint32_t)wallpaper::metal::MetalPixelFormat::BGRA8Unorm == MTLPixelFormatBGRA8Unorm,
              "");
static_assert((uint32_t)wallpaper::metal::MetalPixelFormat::BGRA8Unorm_sRGB ==
                  MTLPixelFormatBGRA8Unorm_sRGB,
              "");
static_assert((uint32_t)wallpaper::metal::MetalPixelFormat::Depth32Float ==
                  MTLPixelFormatDepth32Float,
              "");
static_assert((uint32_t)wallpaper::metal::MetalDepthCompare::Never == MTLCompareFunctionNever, "");
static_assert((uint32_t)wallpaper::metal::MetalDepthCompare::LessEqual ==
                  MTLCompareFunctionLessEqual,
              "");

namespace wallpaper::metal
{
namespace
{

/// Frames the CPU may run ahead of the GPU. Two is enough to keep the queue
/// fed without letting the wallpaper build a backlog of work nobody will see.
constexpr NSUInteger kFramesInFlight = 2;

/// Vertex buffers are bound from the top of Metal's buffer argument table
/// downwards, because the translated shader's own resources are placed at their
/// SPIR-V binding indices, which start at zero. A collision is detected at
/// prepare time rather than assumed away.
constexpr NSUInteger kVertexBufferTopIndex = 30;

/// Render targets are read by later passes and by the presentation blit, so
/// their contents must outlive the pass that wrote them. Nothing here is ever
/// `memoryless`: a memoryless attachment's contents end with its render pass,
/// which is exactly the lifetime these do not have.
constexpr MTLTextureUsage kRenderTargetUsage =
    MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;

MTLPixelFormat SceneTargetFormat(TextureFormat format)
{
    switch (format) {
    case TextureFormat::RGBA8: return MTLPixelFormatRGBA8Unorm;
    case TextureFormat::RGBA16F: return MTLPixelFormatRGBA16Float;
    default: return MTLPixelFormatInvalid;
    }
}

/// Ceiling on the pixels this backend keeps alive only so they can be reused.
/// The same number the compatibility backend uses, so the two report one
/// budget and one `pinned_bytes` total rather than two that happen to be added
/// together.
constexpr uint64_t kStaticCacheBudgetBytes = 192ULL * 1024ULL * 1024ULL;

constexpr std::string_view kPresentShaderSource = R"(
#include <metal_stdlib>
using namespace metal;

struct OweVertex {
    float2 position;
    float2 texcoord;
};

struct OweVarying {
    float4 position [[position]];
    float2 texcoord;
};

vertex OweVarying owe_present_vertex(uint vertex_id [[vertex_id]],
                                     const device OweVertex* vertices [[buffer(0)]]) {
    OweVarying out;
    out.position = float4(vertices[vertex_id].position, 0.0, 1.0);
    out.texcoord = vertices[vertex_id].texcoord;
    return out;
}

fragment float4 owe_present_fragment(OweVarying in [[stage_in]],
                                     texture2d<float> source [[texture(0)]],
                                     sampler source_sampler [[sampler(0)]]) {
    return source.sample(source_sampler, in.texcoord);
}

// Texel for texel, never filtered: the destination is the source's size and
// format, so each fragment reads exactly the pixel it covers.
fragment float4 owe_copy_fragment(OweVarying in [[stage_in]],
                                  texture2d<float> source [[texture(0)]]) {
    return source.read(uint2(in.position.xy));
}
)";

struct PresentVertex
{
    float position[2];
    float texcoord[2];
};

/// A triangle strip covering the target, with the texture's top row at the top
/// of the image. Metal's normalized device coordinates put -1 at the bottom and
/// its textures put v = 0 at the top, so v = 1 belongs with y = -1. These are
/// the same four vertices the compatibility backend's final blit uses, which is
/// what makes the two backends present the same orientation.
constexpr PresentVertex kPresentVertices[4] = {
    { { -1.0f, -1.0f }, { 0.0f, 1.0f } },
    { { -1.0f, 1.0f }, { 0.0f, 0.0f } },
    { { 1.0f, -1.0f }, { 1.0f, 1.0f } },
    { { 1.0f, 1.0f }, { 1.0f, 0.0f } },
};

constexpr PresentVertex kPresentVerticesFlipped[4] = {
    { { -1.0f, -1.0f }, { 1.0f, 1.0f } },
    { { -1.0f, 1.0f }, { 1.0f, 0.0f } },
    { { 1.0f, -1.0f }, { 0.0f, 1.0f } },
    { { 1.0f, 1.0f }, { 0.0f, 0.0f } },
};

double NormalizeScaleFactor(double value)
{
    if (! std::isfinite(value) || value <= 0.0) return 1.0;
    return value;
}

/// The longest side of a 2D texture this device can create, from Apple's
/// published feature-set limits: 16384 from the third GPU family on and on every
/// Mac family, 8192 below that. The Metal API has no query for it, so this is
/// the table the documentation gives.
uint32_t MaxTextureDimension(id<MTLDevice> device)
{
    if (device != nil && ([device supportsFamily:MTLGPUFamilyApple3] ||
                          [device supportsFamily:MTLGPUFamilyMac2])) {
        return 16384;
    }
    return 8192;
}

MTLVertexFormat ToMetalVertexFormat(std::string_view name)
{
    if (name == "r32_sfloat") return MTLVertexFormatFloat;
    if (name == "r32g32_sfloat") return MTLVertexFormatFloat2;
    if (name == "r32g32b32_sfloat") return MTLVertexFormatFloat3;
    if (name == "r32g32b32a32_sfloat") return MTLVertexFormatFloat4;
    if (name == "r32_uint") return MTLVertexFormatUInt;
    if (name == "r32g32_uint") return MTLVertexFormatUInt2;
    if (name == "r32g32b32_uint") return MTLVertexFormatUInt3;
    if (name == "r32g32b32a32_uint") return MTLVertexFormatUInt4;
    if (name == "r32_sint") return MTLVertexFormatInt;
    if (name == "r32g32_sint") return MTLVertexFormatInt2;
    if (name == "r32g32b32_sint") return MTLVertexFormatInt3;
    if (name == "r32g32b32a32_sint") return MTLVertexFormatInt4;
    return MTLVertexFormatInvalid;
}

MTLSamplerAddressMode ToMetalAddressMode(TextureWrap wrap)
{
    switch (wrap) {
    case TextureWrap::CLAMP_TO_EDGE: return MTLSamplerAddressModeClampToEdge;
    case TextureWrap::REPEAT: return MTLSamplerAddressModeRepeat;
    }
    return MTLSamplerAddressModeClampToEdge;
}

MTLSamplerMinMagFilter ToMetalFilter(TextureFilter filter)
{
    switch (filter) {
    case TextureFilter::LINEAR: return MTLSamplerMinMagFilterLinear;
    case TextureFilter::NEAREST: return MTLSamplerMinMagFilterNearest;
    }
    return MTLSamplerMinMagFilterLinear;
}

/// Uncompressed formats only. Block-compressed source images are rejected
/// rather than decoded here: silently expanding them would change memory use
/// and filtering behaviour relative to the compatibility backend.
/// `block_bytes` is non-zero for a block-compressed format, where a row is
/// counted in 4x4 blocks rather than pixels and `bytes_per_pixel` means nothing.
bool ToMetalImageFormat(TextureFormat format, bool block_compression, MTLPixelFormat& out,
                        uint32_t& bytes_per_pixel, uint32_t& block_bytes)
{
    block_bytes = 0;
    switch (format) {
    case TextureFormat::RGBA8:
        out             = MTLPixelFormatRGBA8Unorm;
        bytes_per_pixel = 4;
        return true;
    case TextureFormat::RGBA16F:
        out             = MTLPixelFormatRGBA16Float;
        bytes_per_pixel = 8;
        return true;
    case TextureFormat::RG8:
        out             = MTLPixelFormatRG8Unorm;
        bytes_per_pixel = 2;
        return true;
    case TextureFormat::R8:
        out             = MTLPixelFormatR8Unorm;
        bytes_per_pixel = 1;
        return true;
    // The same three formats the compatibility backend hands to the same GPU
    // through MoltenVK, uploaded as the blocks the file already holds. A device
    // without them refuses the image, and with it the scene, rather than
    // decoding on the CPU into a texture four to eight times the size.
    case TextureFormat::BC1:
        out         = MTLPixelFormatBC1_RGBA;
        block_bytes = 8;
        return block_compression;
    case TextureFormat::BC2:
        out         = MTLPixelFormatBC2_RGBA;
        block_bytes = 16;
        return block_compression;
    case TextureFormat::BC3:
        out         = MTLPixelFormatBC3_RGBA;
        block_bytes = 16;
        return block_compression;
    case TextureFormat::RGB8: return false;
    }
    return false;
}

/// Writes every level of `slot` into `texture`, as the pixels or the 4x4 blocks
/// the image holds. A level with no data is skipped; false when a block-
/// compressed level is shorter than its own block grid, which the copy would
/// read past.
bool UploadImageLevels(id<MTLTexture> texture, const Image::Slot& slot, uint32_t bytes_per_pixel,
                       uint32_t block_bytes)
{
    for (std::size_t level = 0; level < slot.mipmaps.size(); ++level) {
        const auto& mipmap = slot.mipmaps[level];
        if (mipmap.data == nullptr || mipmap.width <= 0 || mipmap.height <= 0) continue;
        MTLRegion region = MTLRegionMake2D(0, 0, (NSUInteger)mipmap.width,
                                           (NSUInteger)mipmap.height);
        NSUInteger bytes_per_row = (NSUInteger)mipmap.width * bytes_per_pixel;
        if (block_bytes > 0) {
            const NSUInteger blocks_wide = ((NSUInteger)mipmap.width + 3) / 4;
            const NSUInteger blocks_high = ((NSUInteger)mipmap.height + 3) / 4;
            bytes_per_row                = blocks_wide * block_bytes;
            // A level shorter than its own block grid would be read past
            // its end by the copy below.
            if (mipmap.size < 0 || (NSUInteger)mipmap.size < bytes_per_row * blocks_high) {
                return false;
            }
        }
        [texture replaceRegion:region
                   mipmapLevel:level
                     withBytes:mipmap.data.get()
                   bytesPerRow:bytes_per_row];
    }
    return true;
}

/// Reads the material texture slot out of a generated chroma-plane resource
/// name. `std::nullopt` for anything else, including the material's own
/// `g_TextureN` names, which have their own reader.
std::optional<std::size_t> VideoChromaSlot(std::string_view name, std::string_view prefix)
{
    if (! name.starts_with(prefix)) return std::nullopt;
    name.remove_prefix(prefix.size());
    if (name.empty()) return std::nullopt;
    if (name.size() > 1 && name.front() == '0') return std::nullopt;
    std::size_t  slot   = 0;
    const auto   result = std::from_chars(name.data(), name.data() + name.size(), slot);
    if (result.ec != std::errc {} || result.ptr != name.data() + name.size()) return std::nullopt;
    return slot;
}

std::optional<std::size_t> VideoChromaTextureSlot(std::string_view name)
{
    return VideoChromaSlot(name, "_we_VideoChroma");
}

std::optional<std::size_t> VideoChromaSamplerSlot(std::string_view name)
{
    return VideoChromaSlot(name, "_we_Sampler__we_VideoChroma");
}

std::string VideoRangeUniformName(std::size_t slot)
{
    return "_we_VideoRange" + std::to_string(slot);
}

std::string VideoMatrixUniformName(std::size_t slot)
{
    return "_we_VideoMatrix" + std::to_string(slot);
}

/// Where one material texture slot's texture and sampler go in Metal's
/// per-stage argument tables. A negative index means that stage does not bind
/// it at all.
struct MetalRenderTextureSlotBinding
{
    int vertex_texture { -1 };
    int fragment_texture { -1 };
    int vertex_sampler { -1 };
    int fragment_sampler { -1 };

    [[nodiscard]] bool bound() const { return vertex_texture >= 0 || fragment_texture >= 0; }
};

/// One program's resource bindings, matched on the original GLSL names.
struct MetalResourcePlan
{
    int                                                  vertex_uniform_slot { -1 };
    int                                                  fragment_uniform_slot { -1 };
    std::vector<MetalRenderTextureSlotBinding>           texture_slots;
    MetalRenderTextureSlotBinding                        chroma {};
    bool                                                 has_chroma { false };
    /// Material texture slot the chroma plane belongs to.
    std::size_t                                          chroma_slot { 0 };
};

/// Builds the binding plan for one translated program. Returns an empty string
/// on success and the reason otherwise; both the ordinary program and the plane
/// variant go through this, so the two cannot disagree about how a resource
/// name becomes a slot.
std::string BuildMetalResourcePlan(const std::vector<SceneMetalStage>& stages,
                                   const MetalUniformBlock*            uniform_block,
                                   std::size_t                         texture_count,
                                   const std::vector<uint32_t>&        active_texture_slots,
                                   MetalResourcePlan&                  out)
{
    out.texture_slots.assign(texture_count, MetalRenderTextureSlotBinding {});
    // A slot the shader declares but never samples needs no texture behind it:
    // the GLSL preprocessor already dropped it from SPIR-V, Vulkan skips an
    // empty material name, and Metal leaves an unused argument unbound. Naga's
    // MSL writer may still name that argument. One the shader does sample, with
    // nothing in the material to bind, is a genuine failure and stays one.
    const auto sampled = [&active_texture_slots](std::size_t slot) {
        return std::find(active_texture_slots.begin(), active_texture_slots.end(),
                         static_cast<uint32_t>(slot)) != active_texture_slots.end();
    };
    for (const auto& stage : stages) {
        const bool vertex_stage = stage.kind == SceneMetalStageKind::Vertex;
        for (const auto& binding : stage.bindings) {
            if (binding.set != 0) {
                return "a shader binds a resource outside descriptor set 0";
            }
            // SPIR-V drops an unused uniform block; Naga's MSL writer may still
            // name `GlobalUniforms` as a buffer argument. Vulkan has nothing to
            // bind then. Match that: bind the block when reflection kept it,
            // otherwise leave the argument unbound.
            if (binding.name == "GlobalUniforms" ||
                (uniform_block != nullptr && binding.name == uniform_block->name)) {
                if (binding.slot_kind != SceneMetalSlotKind::Buffer) {
                    return "a shader binds its uniform block as something other than a buffer";
                }
                if (uniform_block != nullptr) {
                    (vertex_stage ? out.vertex_uniform_slot : out.fragment_uniform_slot) =
                        static_cast<int>(binding.slot);
                }
                continue;
            }
            if (const auto chroma = VideoChromaTextureSlot(binding.name); chroma.has_value()) {
                if (binding.slot_kind != SceneMetalSlotKind::Texture) {
                    return "a shader binds a video plane as something other than a texture";
                }
                if (out.has_chroma && out.chroma_slot != *chroma) {
                    return "a shader binds more than one video plane";
                }
                out.has_chroma  = true;
                out.chroma_slot = *chroma;
                (vertex_stage ? out.chroma.vertex_texture : out.chroma.fragment_texture) =
                    static_cast<int>(binding.slot);
                continue;
            }
            if (const auto chroma = VideoChromaSamplerSlot(binding.name); chroma.has_value()) {
                if (binding.slot_kind != SceneMetalSlotKind::Sampler) {
                    return "a shader binds a video plane sampler as something else";
                }
                if (out.has_chroma && out.chroma_slot != *chroma) {
                    return "a shader binds more than one video plane";
                }
                out.has_chroma  = true;
                out.chroma_slot = *chroma;
                (vertex_stage ? out.chroma.vertex_sampler : out.chroma.fragment_sampler) =
                    static_cast<int>(binding.slot);
                continue;
            }
            const auto texture_slot = vulkan::detail::CustomShaderTextureSlot(binding.name);
            if (texture_slot.has_value()) {
                if (! sampled(*texture_slot)) continue;
                if (*texture_slot >= out.texture_slots.size()) {
                    return "a shader samples texture slot " + std::to_string(*texture_slot) +
                           ", which the material does not have";
                }
                auto& slot = out.texture_slots[*texture_slot];
                if (binding.slot_kind == SceneMetalSlotKind::Texture) {
                    (vertex_stage ? slot.vertex_texture : slot.fragment_texture) =
                        static_cast<int>(binding.slot);
                } else if (binding.slot_kind == SceneMetalSlotKind::Sampler) {
                    (vertex_stage ? slot.vertex_sampler : slot.fragment_sampler) =
                        static_cast<int>(binding.slot);
                } else {
                    return "a shader binds a texture as a buffer";
                }
                continue;
            }
            const auto sampler_slot = vulkan::detail::CustomShaderSamplerSlot(binding.name);
            if (sampler_slot.has_value()) {
                if (! sampled(*sampler_slot)) continue;
                if (*sampler_slot >= out.texture_slots.size()) {
                    return "a shader samples texture slot " + std::to_string(*sampler_slot) +
                           ", which the material does not have";
                }
                auto& slot = out.texture_slots[*sampler_slot];
                (vertex_stage ? slot.vertex_sampler : slot.fragment_sampler) =
                    static_cast<int>(binding.slot);
                continue;
            }
            return "a shader binds a resource the native renderer does not recognise: " +
                   binding.name;
        }
    }
    return {};
}

/// Matrices the Metal backend has to carry through its clip-space fold.
/// `MetalClipSpaceFold` is the identity on every convention pair this renderer
/// has met, but the fold is applied rather than skipped so that a future change
/// to either convention is honoured instead of silently ignored.
/// Identity of a translated program, from what it actually contains.
///
/// Deliberately not the address of the object holding it. An address is unique
/// only while that object lives: two scenes loaded one after another can put
/// different programs at the same address, and a cache keyed on it would hand
/// the second scene the first one's pipeline. The content is also what makes
/// reuse real -- two surfaces showing the same wallpaper translate to the same
/// Metal source and can share one library and one pipeline.
uint64_t ProgramContentId(const std::vector<SceneMetalStage>& stages)
{
    uint64_t hash = 0xcbf29ce484222325ULL;
    const auto fold = [&hash](const void* data, std::size_t size) {
        const auto* bytes = static_cast<const uint8_t*>(data);
        for (std::size_t i = 0; i < size; ++i) {
            hash ^= bytes[i];
            hash *= 1099511628211ULL;
        }
    };
    for (const auto& stage : stages) {
        const auto kind = static_cast<uint8_t>(stage.kind);
        fold(&kind, sizeof(kind));
        fold(stage.entry_point.data(), stage.entry_point.size());
        fold(stage.language_version.data(), stage.language_version.size());
        fold(stage.source.data(), stage.source.size());
    }
    return hash;
}

/// Compiled Metal libraries and pipeline states, shared for as long as the
/// process runs.
///
/// Scoped by device, because a `MTLLibrary` and a `MTLRenderPipelineState`
/// belong to the device that created them and are not portable to another. Held
/// across scene loads and across surfaces on purpose: the expensive part of
/// preparing a wallpaper is the Metal compiler, and the second surface showing
/// the same wallpaper -- or the same wallpaper loaded again after a display
/// change -- must not pay for it twice.
///
/// Bounded: past the cap nothing new is remembered and the caller still gets a
/// correctly built object, so a long session cannot grow this without limit.
/// Nothing is evicted, because evicting one entry of a scene that is still
/// drawing would simply make it compile again on the next graph build.
class MetalProgramCache
{
public:
    static constexpr std::size_t kMaxLibraries = 256;
    static constexpr std::size_t kMaxPipelines = 512;

    static MetalProgramCache& shared()
    {
        static MetalProgramCache cache;
        return cache;
    }

#ifdef WESCENE_BUILD_TESTS
    /// Drops the open archives without changing where they live, so the next
    /// pipeline reads the published file exactly as a new launch would.
    void reopenArchives()
    {
        waitForArchiveWrites();
        const std::lock_guard lock { m_mutex };
        forgetArchivesLocked();
    }

    /// Lets every write already scheduled run, keeping the open archives.
    void finishArchiveWrites() { waitForArchiveWrites(); }
#endif

    [[nodiscard]] MetalPipelineArchiveStatus archiveStatus() const
    {
        const std::lock_guard lock { m_mutex };
        MetalPipelineArchiveStatus status;
        for (const auto& [archive_id, entry] : m_archives) {
            (void)archive_id;
            if (entry.loaded != nil) status.available = true;
        }
        status.collected = m_archive_collected.load(std::memory_order_relaxed);
        status.published = m_archive_published.load(std::memory_order_relaxed);
        return status;
    }

    /// How many times a Metal shader source has actually been handed to the
    /// compiler. Diagnostic: nothing schedules on it, and it is the only way a
    /// test can tell a cache hit from a second compile that produced an
    /// identical result.
    [[nodiscard]] uint64_t compileCount() const
    {
        return m_compiles.load(std::memory_order_relaxed);
    }

    id<MTLLibrary> libraryFor(id<MTLDevice> device, const SceneMetalStage& stage,
                              std::string* error)
    {
        if (device == nil) return nil;
        const uint64_t registry = device.registryID;
        {
            const std::lock_guard lock { m_mutex };
            auto& entry = m_devices[registry];
            if (auto found = entry.libraries.find(stage.source); found != entry.libraries.end()) {
                return found->second;
            }
        }

        // Outside the lock: this is the Metal shader compiler, and holding a
        // process-wide lock across it would make one surface's compile block
        // every other surface's.
        NSError*  compile_error = nil;
        NSString* source        = [[NSString alloc] initWithBytes:stage.source.data()
                                                    length:stage.source.size()
                                                  encoding:NSUTF8StringEncoding];
        MTLCompileOptions* options = [MTLCompileOptions new];
        m_compiles.fetch_add(1, std::memory_order_relaxed);
        id<MTLLibrary>     library = [device newLibraryWithSource:source
                                                     options:options
                                                       error:&compile_error];
        if (library == nil) {
            if (error != nullptr) {
                *error = std::string("a shader could not be compiled by Metal: ") +
                         (compile_error != nil ? compile_error.localizedDescription.UTF8String
                                               : "unknown error");
            }
            return nil;
        }

        const std::lock_guard lock { m_mutex };
        auto& entry = m_devices[registry];
        // Another thread may have compiled the same source meanwhile. Keeping
        // the one already published keeps the mapping single-valued.
        if (auto found = entry.libraries.find(stage.source); found != entry.libraries.end()) {
            return found->second;
        }
        if (entry.libraries.size() < kMaxLibraries) entry.libraries.emplace(stage.source, library);
        return library;
    }

    /// `archive_root` is the asking renderer's own regenerable cache directory,
    /// not a process-wide setting. Two displays showing different wallpapers
    /// have different ones, and each files its pipelines under its own scene;
    /// the library and pipeline caches above stay shared by device, because a
    /// compiled program is the same program whichever wallpaper wanted it.
    id<MTLRenderPipelineState> pipelineFor(id<MTLDevice> device, const MetalPipelineKey& key,
                                           const std::vector<SceneMetalStage>& stages,
                                           MTLVertexDescriptor* vertex_descriptor,
                                           std::string_view     archive_root,
                                           std::string* error)
    {
        if (device == nil) return nil;
        const uint64_t registry = device.registryID;
        {
            const std::lock_guard lock { m_mutex };
            auto& entry = m_devices[registry];
            if (auto found = entry.pipelines.find(key); found != entry.pipelines.end()) {
                return found->second;
            }
        }

        id<MTLFunction> vertex_function   = nil;
        id<MTLFunction> fragment_function = nil;
        for (const auto& stage : stages) {
            id<MTLLibrary> library = libraryFor(device, stage, error);
            if (library == nil) return nil;
            NSString*       name     = [NSString stringWithUTF8String:stage.entry_point.c_str()];
            id<MTLFunction> function = [library newFunctionWithName:name];
            if (function == nil) {
                if (error != nullptr) {
                    *error = "a translated shader has no entry point named " + stage.entry_point;
                }
                return nil;
            }
            if (stage.kind == SceneMetalStageKind::Vertex) {
                vertex_function = function;
            } else {
                fragment_function = function;
            }
        }
        if (vertex_function == nil || fragment_function == nil) {
            if (error != nullptr) *error = "a translated shader is missing a stage";
            return nil;
        }

        MTLRenderPipelineDescriptor* descriptor = [MTLRenderPipelineDescriptor new];
        descriptor.vertexFunction               = vertex_function;
        descriptor.fragmentFunction             = fragment_function;
        descriptor.vertexDescriptor             = vertex_descriptor;
        descriptor.rasterSampleCount            = key.sample_count;
        descriptor.alphaToCoverageEnabled       = key.blend.alpha_to_coverage;
        if (key.depth_format != MetalPixelFormat::Invalid) {
            descriptor.depthAttachmentPixelFormat =
                static_cast<MTLPixelFormat>(key.depth_format);
        }

        MTLRenderPipelineColorAttachmentDescriptor* attachment = descriptor.colorAttachments[0];
        attachment.pixelFormat = static_cast<MTLPixelFormat>(key.color_format);
        attachment.writeMask   = key.write_alpha ? MTLColorWriteMaskAll
                                                 : (MTLColorWriteMaskRed | MTLColorWriteMaskGreen |
                                                  MTLColorWriteMaskBlue);
        attachment.blendingEnabled = key.blend.blending_enabled;
        if (key.blend.blending_enabled) {
            attachment.rgbBlendOperation =
                static_cast<MTLBlendOperation>(key.blend.rgb_operation);
            attachment.alphaBlendOperation =
                static_cast<MTLBlendOperation>(key.blend.alpha_operation);
            attachment.sourceRGBBlendFactor =
                static_cast<MTLBlendFactor>(key.blend.source_rgb);
            attachment.destinationRGBBlendFactor =
                static_cast<MTLBlendFactor>(key.blend.destination_rgb);
            attachment.sourceAlphaBlendFactor =
                static_cast<MTLBlendFactor>(key.blend.source_alpha);
            attachment.destinationAlphaBlendFactor =
                static_cast<MTLBlendFactor>(key.blend.destination_alpha);
        }

        // The archive is offered to Metal, never depended on. Whatever it can
        // supply is reused; anything it cannot is compiled exactly as before,
        // and a wallpaper is never refused a pipeline because a cache missed.
        // That is also why the strict "fail on archive miss" option is not used
        // here: it would turn a cold cache into a wallpaper that does not load.
        if (id<MTLBinaryArchive> archive = loadedArchive(device, archive_root); archive != nil) {
            descriptor.binaryArchives = @[ archive ];
        }

        NSError*                   pipeline_error = nil;
        id<MTLRenderPipelineState> state =
            [device newRenderPipelineStateWithDescriptor:descriptor error:&pipeline_error];
        if (state == nil) {
            if (error != nullptr) {
                *error = std::string("a shader pipeline could not be created: ") +
                         (pipeline_error != nil ? pipeline_error.localizedDescription.UTF8String
                                                : "unknown error");
            }
            return nil;
        }

        collectIntoArchive(device, archive_root, key, descriptor);

        const std::lock_guard lock { m_mutex };
        auto& entry = m_devices[registry];
        if (auto found = entry.pipelines.find(key); found != entry.pipelines.end()) {
            return found->second;
        }
        if (entry.pipelines.size() < kMaxPipelines) entry.pipelines.emplace(key, state);
        return state;
    }

#ifdef WESCENE_BUILD_TESTS
    /// Asks the archive, strictly, for every pipeline this process has built.
    ///
    /// The strict option belongs to a check and not to a wallpaper: it is the
    /// only way to tell "the archive supplied this" from "Metal compiled it
    /// again quickly", and it is exactly the answer a test needs. Returns false
    /// when there is no archive, when nothing has been built, or when any
    /// descriptor is not in the archive.
    bool archiveServesEverySeenPipeline()
    {
        // Let the writes land and forget the open handles, so what answers
        // below is the published file and not this run's in-memory collector.
        reopenArchives();

        struct Seen
        {
            id<MTLDevice>                device;
            std::string                  root;
            MTLRenderPipelineDescriptor* descriptor;
        };
        std::vector<Seen> seen;
        {
            const std::lock_guard lock { m_mutex };
            for (auto& [archive_id, entry] : m_archives) {
                if (entry.device == nil) continue;
                for (const auto& descriptor : entry.descriptors) {
                    seen.push_back(Seen { entry.device, archive_id.second, descriptor });
                }
            }
        }
        if (seen.empty()) return false;

        for (const auto& [device, root, descriptor] : seen) {
            // Opened the way a later launch opens it, from the published file.
            id<MTLBinaryArchive> archive = loadedArchive(device, root);
            if (archive == nil) return false;
            MTLRenderPipelineDescriptor* probe = [descriptor copy];
            probe.binaryArchives               = @[ archive ];
            NSError* miss                      = nil;
            id<MTLRenderPipelineState> state =
                [device newRenderPipelineStateWithDescriptor:probe
                                                     options:MTLPipelineOptionFailOnBinaryArchiveMiss
                                                  reflection:nil
                                                       error:&miss];
            if (state == nil) return false;
        }
        return true;
    }
#endif

private:
    struct DeviceEntry
    {
        std::unordered_map<std::string, id<MTLLibrary>> libraries;
        std::unordered_map<MetalPipelineKey, id<MTLRenderPipelineState>, MetalPipelineKeyHash>
            pipelines;
    };

    /// One store, identified by the device it was built for and the directory
    /// it lives in. Keyed by both because a Mac showing two wallpapers has one
    /// device and two caches, and filing either one's pipelines under the
    /// other's directory would lose them on the next wallpaper change.
    using ArchiveId = std::pair<uint64_t, std::string>;
    struct ArchiveIdHash
    {
        std::size_t operator()(const ArchiveId& key) const
        {
            return std::hash<uint64_t> {}(key.first) ^ (std::hash<std::string> {}(key.second) << 1);
        }
    };
    struct ArchiveEntry
    {
        /// Read-only, handed to descriptors. Never mutated after it is created,
        /// so the render thread can attach it while the collector below is
        /// being written on the archive queue.
        id<MTLBinaryArchive>                   loaded { nil };
        /// The one object `addRenderPipelineFunctions` is called on, touched
        /// only from `m_archive_queue`.
        id<MTLBinaryArchive>                   collector { nil };
        NSURL*                                 url { nil };
        id<MTLDevice>                          device { nil };
        bool                                   attempted { false };
        std::unordered_set<MetalPipelineKey, MetalPipelineKeyHash> keys;
        std::vector<MTLRenderPipelineDescriptor*>                  descriptors;
    };

    /// Caller holds `m_mutex`. Keeps the number of stores one session holds
    /// open bounded: each carries two archive objects and the descriptors that
    /// went into them, and a user switching wallpapers all afternoon would
    /// otherwise accumulate one per wallpaper.
    ///
    /// The oldest is released, not deleted: its file stays on disk, and the
    /// next pipeline for that wallpaper opens it again. A write still waiting
    /// out its debounce when its store is released is lost, which costs that
    /// wallpaper one recompile on a later launch and nothing else.
    void rememberStoreLocked(const ArchiveId& archive_id)
    {
        m_archive_order.push_back(archive_id);
        while (m_archive_order.size() > kMaxArchiveStores) {
            const auto oldest = m_archive_order.front();
            m_archive_order.pop_front();
            if (oldest == archive_id) continue;
            m_archives.erase(oldest);
            m_archive_write_generations.erase(oldest);
        }
    }

    /// Caller holds `m_mutex`. The pipelines already built are objects and are
    /// untouched; only the stores they would be filed in are let go.
    void forgetArchivesLocked()
    {
        for (auto& [archive_id, entry] : m_archives) {
            (void)archive_id;
            entry.loaded    = nil;
            entry.collector = nil;
            entry.attempted = false;
            entry.keys.clear();
        }
    }

    MetalProgramCache()
    {
        m_archive_queue = dispatch_queue_create("owe.metal.pipeline-archive",
                                                dispatch_queue_attr_make_with_qos_class(
                                                    DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    }

    /// One file per device and per compiler identity.
    ///
    /// The device's own registry id is not part of it: that number is assigned
    /// at boot and would give a different file every restart, which is the one
    /// thing a cache that exists to survive restarts must not do. What is in it
    /// is what actually decides whether a stored pipeline is usable -- which
    /// GPU, and which shader toolchain produced the source. Metal rejects a
    /// file it cannot use anyway; this only stops two incompatible stores from
    /// fighting over one name.
    static std::string ArchiveFileName(id<MTLDevice> device)
    {
        std::string name = device.name != nil ? device.name.UTF8String : "device";
        for (auto& character : name) {
            if (! std::isalnum(static_cast<unsigned char>(character))) character = '-';
        }
        const auto identity = shader::RustShaderCacheIdentity();
        uint64_t   digest   = 1469598103934665603ull;
        for (const char character : identity) {
            digest ^= static_cast<unsigned char>(character);
            digest *= 1099511628211ull;
        }
        char suffix[17] {};
        std::snprintf(suffix, sizeof(suffix), "%016llx",
                      static_cast<unsigned long long>(digest));
        return "pipelines-" + name + "-" + suffix + ".metallib-archive";
    }

    /// The archive to attach to descriptors, opening or creating it once.
    id<MTLBinaryArchive> loadedArchive(id<MTLDevice> device, std::string_view archive_root)
    {
        if (device == nil || archive_root.empty()) return nil;
        const ArchiveId archive_id { device.registryID, std::string(archive_root) };
        {
            const std::lock_guard lock { m_mutex };
            auto& entry = m_archives[archive_id];
            if (entry.attempted) return entry.loaded;
        }

        const std::string root { archive_root };
        NSString* directory = [NSString stringWithUTF8String:root.c_str()];
        NSURL*    url       = [[NSURL fileURLWithPath:directory isDirectory:YES]
            URLByAppendingPathComponent:[NSString
                                            stringWithUTF8String:ArchiveFileName(device).c_str()]];
        [[NSFileManager defaultManager] createDirectoryAtURL:[url URLByDeletingLastPathComponent]
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:nil];

        // Two objects from the same file on purpose. The one handed to
        // descriptors is never written, so no write can race a pipeline
        // creation; the one written to is loaded from the same file, so
        // serialising it republishes everything previous runs stored instead of
        // replacing the file with only what this run happened to build.
        const auto open = [&url](id<MTLDevice> owner, bool required) -> id<MTLBinaryArchive> {
            MTLBinaryArchiveDescriptor* descriptor = [MTLBinaryArchiveDescriptor new];
            descriptor.url                         = url;
            NSError*             failure           = nil;
            id<MTLBinaryArchive> archive = [owner newBinaryArchiveWithDescriptor:descriptor
                                                                          error:&failure];
            if (archive != nil || ! required) return archive;
            // Missing, from another GPU, or damaged: all the same answer. Start
            // an empty one so this run can still contribute, and let the next
            // launch read what it writes.
            descriptor.url = nil;
            return [owner newBinaryArchiveWithDescriptor:descriptor error:&failure];
        };

        // `loaded` stays nil on a first run: there is no file, so there is
        // nothing to offer a descriptor, and attaching the collector instead
        // would put an object the archive queue mutates in the path of a thread
        // that is drawing.
        id<MTLBinaryArchive> loaded    = open(device, false);
        id<MTLBinaryArchive> collector = open(device, true);

        const std::lock_guard lock { m_mutex };
        auto& entry = m_archives[archive_id];
        // Another thread may have opened the same file meanwhile -- the render
        // thread and the variant queue both create pipelines. Keeping the pair
        // already published keeps one collector authoritative, so an addition
        // dispatched against it is not lost when this one is discarded.
        if (entry.attempted) return entry.loaded;
        entry.attempted = true;
        rememberStoreLocked(archive_id);
        entry.device    = device;
        entry.url       = url;
        entry.loaded    = loaded;
        entry.collector = collector;
        return entry.loaded;
    }

    /// Remembers a pipeline the archive did not already hold.
    ///
    /// The work happens on a serial queue of its own: adding to an archive
    /// compiles, and writing one touches the disk, neither of which belongs on
    /// a thread that is trying to draw. Each addition schedules one write,
    /// which coalesces with any other pending write -- a wallpaper with twenty
    /// pipelines publishes the file once, not twenty times.
    void collectIntoArchive(id<MTLDevice> device, std::string_view archive_root,
                            const MetalPipelineKey&      key,
                            MTLRenderPipelineDescriptor* descriptor)
    {
        if (device == nil || archive_root.empty()) return;
        const ArchiveId      archive_id { device.registryID, std::string(archive_root) };
        id<MTLBinaryArchive> collector = nil;
        {
            const std::lock_guard lock { m_mutex };
            auto& entry = m_archives[archive_id];
            if (entry.collector == nil) return;
            if (entry.keys.size() >= kMaxArchivedPipelines) return;
            if (! entry.keys.insert(key).second) return;
            collector = entry.collector;
        }

        // Copied, and without the archives it was created against: what is
        // stored is the pipeline, not a reference to the store it came from.
        MTLRenderPipelineDescriptor* stored = [descriptor copy];
        stored.binaryArchives                = nil;
        m_archive_collected.fetch_add(1, std::memory_order_relaxed);
        dispatch_async(m_archive_queue, ^{
            NSError* failure = nil;
            if (! [collector addRenderPipelineFunctionsWithDescriptor:stored error:&failure]) {
                // Remembered by omission: the key stays in `keys`, so this
                // descriptor is not offered again and the same failure is not
                // produced for every frame that rebuilds the graph.
                LOG_INFO("metal pipeline archive did not accept a pipeline: %s",
                         failure != nil ? failure.localizedDescription.UTF8String : "unknown");
                return;
            }
            {
                const std::lock_guard lock { m_mutex };
                auto& entry = m_archives[archive_id];
                // Bounded on its own account: `keys` is emptied when the store
                // is reopened, and this must not grow with every reopen.
                if (entry.descriptors.size() < kMaxArchivedPipelines) {
                    entry.descriptors.push_back(stored);
                }
            }
            scheduleArchiveWrite(archive_id);
        });
    }

    /// Publishes one store's collector, on the archive queue, at most once per
    /// burst of additions to that store.
    ///
    /// The generation is per store, not global: a Mac with two GPUs, or two
    /// wallpapers with their own caches, must not have one store's pending
    /// write cancelled by an addition to another.
    void scheduleArchiveWrite(const ArchiveId& requested)
    {
        // Copied into a local before the block is built. A block that names a
        // reference parameter captures the reference, not the referent, and
        // this one outlives the caller by two seconds.
        const ArchiveId archive_id = requested;
        uint64_t        generation = 0;
        {
            const std::lock_guard lock { m_mutex };
            generation = ++m_archive_write_generations[archive_id];
        }
        m_archive_writes_pending.fetch_add(1, std::memory_order_relaxed);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(2 * NSEC_PER_SEC)),
                       m_archive_queue,
                       ^{
                           bool current = false;
                           {
                               const std::lock_guard lock { m_mutex };
                               current = m_archive_write_generations[archive_id] == generation;
                           }
                           if (current) writeArchive(archive_id);
                           m_archive_writes_pending.fetch_sub(1, std::memory_order_relaxed);
                       });
    }

    /// Runs only on `m_archive_queue`.
    void writeArchive(const ArchiveId& archive_id)
    {
        id<MTLBinaryArchive> collector = nil;
        NSURL*               url       = nil;
        {
            const std::lock_guard lock { m_mutex };
            auto found = m_archives.find(archive_id);
            if (found == m_archives.end()) return;
            collector = found->second.collector;
            url       = found->second.url;
        }
        if (collector == nil || url == nil) return;

        // Serialised in this process's own temporary folder, never beside the
        // store. Metal writes a scratch file next to the destination and
        // corrupts the heap when that folder is deleted under it (a double free
        // in its error path), and the store lives in a regenerable cache that
        // clearing the cache or removing a wallpaper deletes whenever it likes.
        // Only plain file operations touch the store's folder, and those fail
        // cleanly when it has gone.
        NSFileManager* files   = [NSFileManager defaultManager];
        NSURL*         scratch = [NSURL
            fileURLWithPath:[NSTemporaryDirectory()
                                stringByAppendingPathComponent:
                                    [NSString stringWithFormat:@"owe-pipelines-%d-%llu.metallib-archive",
                                                               getpid(),
                                                               ++m_archive_scratch_serial]]];
        NSError* failure = nil;
        if (! [collector serializeToURL:scratch error:&failure]) {
            LOG_INFO("metal pipeline archive could not be written: %s",
                     failure != nil ? failure.localizedDescription.UTF8String : "unknown");
            [files removeItemAtURL:scratch error:nil];
            return;
        }

        // Then beside the real file and moved over it. Another process
        // writing the same store at the same moment replaces it whole rather
        // than interleaving with this one, and a reader never opens a file that
        // is half written.
        NSURL* staged = [NSURL
            fileURLWithPath:[[url path] stringByAppendingFormat:@".tmp%d", getpid()]];
        [files removeItemAtURL:staged error:nil];
        NSError* stage_error = nil;
        if (! [files moveItemAtURL:scratch toURL:staged error:&stage_error]) {
            LOG_INFO("metal pipeline archive could not be published: %s",
                     stage_error != nil ? stage_error.localizedDescription.UTF8String
                                        : "unknown");
            [files removeItemAtURL:scratch error:nil];
            return;
        }
        NSError* replace_error = nil;
        if (! [[NSFileManager defaultManager] replaceItemAtURL:url
                                                 withItemAtURL:staged
                                                backupItemName:nil
                                                       options:0
                                              resultingItemURL:nil
                                                         error:&replace_error]) {
            // `replaceItemAtURL:` needs the destination to exist; the first
            // publication of a new archive is an ordinary move.
            NSError* move_error = nil;
            if (! [[NSFileManager defaultManager] moveItemAtURL:staged toURL:url
                                                          error:&move_error]) {
                LOG_INFO("metal pipeline archive could not be published: %s",
                         move_error != nil ? move_error.localizedDescription.UTF8String
                                           : "unknown");
                [[NSFileManager defaultManager] removeItemAtURL:staged error:nil];
                return;
            }
        }
        m_archive_published.fetch_add(1, std::memory_order_relaxed);
    }

    /// Lets everything already queued finish. Only a test needs this; the
    /// renderer never waits for the archive.
    void waitForArchiveWrites()
    {
        // Drained first, not polled first. The additions are what schedule the
        // writes, so a pending count read before they have run is a count of
        // nothing and would let this return before any write existed.
        dispatch_sync(m_archive_queue, ^{
        });
        for (int attempt = 0; attempt < 600; ++attempt) {
            if (m_archive_writes_pending.load(std::memory_order_relaxed) == 0) break;
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
        dispatch_sync(m_archive_queue, ^{
        });
    }

    /// A ceiling on what one process contributes. A user who never stops
    /// switching wallpapers must not be able to grow this file without limit;
    /// the ones that do not fit are compiled, which is what happened before any
    /// of this existed.
    static constexpr std::size_t kMaxArchivedPipelines = 256;

    /// How many wallpapers' stores stay open at once. Two displays is the case
    /// this exists for; the rest is headroom for switching between them.
    static constexpr std::size_t kMaxArchiveStores = 8;

    mutable std::mutex                        m_mutex;
    std::unordered_map<uint64_t, DeviceEntry> m_devices;
    std::unordered_map<ArchiveId, ArchiveEntry, ArchiveIdHash> m_archives;
    std::unordered_map<ArchiveId, uint64_t, ArchiveIdHash>     m_archive_write_generations;
    std::deque<ArchiveId>                                      m_archive_order;
    std::atomic<uint64_t>                     m_compiles { 0 };
    dispatch_queue_t                          m_archive_queue { nullptr };
    std::atomic<uint64_t>                     m_archive_collected { 0 };
    std::atomic<uint64_t>                     m_archive_published { 0 };
    std::atomic<uint64_t>                     m_archive_writes_pending { 0 };
    /// Names each write's scratch file. Touched only on `m_archive_queue`.
    uint64_t                                  m_archive_scratch_serial { 0 };
};

bool FoldsOnLeft(std::string_view name)
{
    return name == G_VP || name == G_MVP || name == G_ETVP;
}

bool FoldsOnRight(std::string_view name)
{
    // The inverse of a folded matrix folds on the other side.
    return name == G_MVPI || name == G_ETVPI;
}

/// `WALLPAPER_MACHINE_FEEDBACK_COPIES=1` makes every feedback copy as a copy,
/// so a power comparison can measure the texture trade against it in one
/// binary. A measurement switch only: both ways draw the same bytes. Read
/// once, like the other A/B switches.
/// Whether targets that are never alive at once share an image. On by
/// default; `WALLPAPER_MACHINE_METAL_TARGET_SHARING=0` turns it off for an A/B
/// or to read every target's own pixels after a frame.
std::atomic<bool>& TargetSharingSwitch()
{
    static std::atomic<bool> enabled { [] {
        const char* value = std::getenv("WALLPAPER_MACHINE_METAL_TARGET_SHARING");
        return value == nullptr || std::string_view(value) != "0";
    }() };
    return enabled;
}

bool FeedbackCopiesForcedByEnvironment()
{
    static const bool forced = [] {
        const char* value = std::getenv("WALLPAPER_MACHINE_FEEDBACK_COPIES");
        return value != nullptr && value[0] != '\0' && std::string_view(value) != "0";
    }();
    return forced;
}

} // namespace

MetalPipelineArchiveStatus MetalPipelineArchiveStatusForDiagnostics()
{
    return MetalProgramCache::shared().archiveStatus();
}

bool MetalDeviceAvailable()
{
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        return device != nil;
    }
}

struct MetalRender::Impl
{
    // ---- device
    id<MTLDevice>         device { nil };
    id<MTLCommandQueue>   queue { nil };
    CAMetalLayer*         layer { nil };
    dispatch_semaphore_t  inflight { nullptr };
    NSUInteger            frame_slot { 0 };
    bool                  inited { false };
    std::string           last_error;
    /// Set while a frame's uniforms are written when a value cannot be placed
    /// the way its shader laid it out. The frame is then failed rather than
    /// drawn from a block whose neighbouring members may have been overwritten.
    std::string           uniform_error;
    /// This surface's regenerable compile cache, set with its scene. Empty
    /// until a host supplies one, and empty means no archive at all.
    std::string           pipeline_archive_root;

    // ---- presentation
    /// One full-target textured-quad pipeline per destination colour format.
    /// The drawable's format is built when presentation is, and a scaled copy's
    /// destination format at compile: a pipeline is never created inside a
    /// frame, because creating one blocks on the shader compiler.
    std::unordered_map<uint32_t, id<MTLRenderPipelineState>> present_pipelines;
    id<MTLLibrary>             present_library { nil };
    id<MTLBuffer>              present_vertices { nil };
    id<MTLBuffer>              present_vertices_flipped { nil };
    id<MTLSamplerState>        present_sampler { nil };
    /// Copies a scene target into another of its size and format texel for
    /// texel, as the first draw of a render pass. Built with the graph like
    /// every other pipeline, and kept, like them, across surface resets.
    std::unordered_map<uint32_t, id<MTLRenderPipelineState>> scene_copy_pipelines;
    MTLPixelFormat             drawable_format { MTLPixelFormatBGRA8Unorm };

    // ---- host services
    MetalPosterCapture poster;
    MetalVideoTextures video;
    /// Whether the graph currently compiled has produced a frame. A poster
    /// composed before that would publish an empty image as the wallpaper.
    bool               frame_drawn { false };
    /// The last composition that actually reached the layer, and scratch for
    /// the frame being decided. A frame whose passes were all reused and whose
    /// composition inputs match takes no drawable and presents nothing.
    vulkan::UnchangedPresentGate present_gate;
    vulkan::PresentationKey      present_key;

    // ---- host configuration
    uint32_t             output_width { 0 };
    uint32_t             output_height { 0 };
    double               display_scale_factor { 1.0 };
    WallpaperScalingMode scaling_mode { WallpaperScalingMode::NONE };
    double               scaling_factor { 1.0 };
    WallpaperFraming     framing {};
    bool                 horizontal_flip { false };
    bool                 video_paused { false };
    float                video_rate { 1.0f };
    RendererCounters*    counters { nullptr };
    /// The raster extent the last size resolve produced: the authored canvas
    /// through the internal render scale, which is what screen-space shader
    /// inputs have to describe.
    uint32_t             raster_width { 0 };
    uint32_t             raster_height { 0 };

    // ---- compiled graph
    using TextureSlotBinding = MetalRenderTextureSlotBinding;

    /// Where one uniform write of a program lands, resolved once.
    ///
    /// A program's writes arrive in the same order every frame -- its defaults,
    /// its constants, then the value updater's -- so the n-th write of a frame
    /// is looked up by position and its name only compared, instead of hashed
    /// into the reflection for every value of every pass of every frame. A
    /// write whose name differs from the one remembered at its position is
    /// resolved again, so a sequence that changes costs a lookup, never a
    /// wrong offset. The member is a copy, so nothing here outlives the
    /// reflection it came from.
    struct UniformWriteSlot
    {
        std::string        name;
        bool               present { false };
        bool               bones { false };
        /// 0: no clip-space fold, 1: folded on the left, 2: on the right.
        uint8_t            fold { 0 };
        MetalUniformMember member {};
    };

    /// One material's second program: the same author shader translated to
    /// sample a video slot's NV12 planes instead of one pre-converted image.
    ///
    /// Everything here is built with the graph, never inside a frame. `ready`
    /// false means this material keeps converting, which is exactly what it did
    /// before the variant existed and is never a reason to fail a draw.
    struct VideoPlaneDraw
    {
        bool                            ready { false };
        /// Material texture slot the variant samples as planes.
        std::size_t                     slot { 0 };
        id<MTLRenderPipelineState>      pipeline { nil };
        MetalShaderReflection           reflection;
        int                             vertex_uniform_slot { -1 };
        int                             fragment_uniform_slot { -1 };
        uint32_t                        uniform_size { 0 };
        std::vector<TextureSlotBinding> texture_slots;
        /// Where the chroma plane and its own sampler go.
        TextureSlotBinding              chroma;
        /// Linear-filtered, with the author's own wrap modes: the chroma plane
        /// is half resolution and the pre-converted path upsamples it linearly,
        /// so reproducing that filter is what keeps the two paths comparable.
        id<MTLSamplerState>             chroma_sampler { nil };
        std::string                     range_uniform;
        std::string                     matrix_uniform;
        std::string                     uv_transform_uniform;
        std::string                     uv_offset_uniform;
        /// One uniform buffer per in-flight frame, sized to this variant's own
        /// block.
        ///
        /// Its own storage rather than a slice of the shared ring, because the
        /// variant arrives after the ring was sized: the two programs have
        /// different blocks -- the variant carries the colour constants the
        /// ordinary one has no member for -- and re-cutting every pass's offset
        /// mid-session to make room would move storage the current frame is
        /// already writing into.
        std::vector<id<MTLBuffer>>      uniform_ring;
        /// This program's writes, by position.
        std::vector<UniformWriteSlot>   uniform_writes;
    };

    /// How far the optional variant of one pass has got.
    ///
    /// `Idle` is what every pass is in while the feature is off, and the state
    /// nothing has been spent in. `Refused` is remembered: a variant this pass
    /// cannot use is not reconsidered every frame.
    enum class VariantBuild : uint8_t
    {
        Idle = 0,
        Building = 1,
        Ready = 2,
        Refused = 3,
    };

    struct PreparedPass
    {
        MetalPassKind kind { MetalPassKind::Unsupported };
        std::size_t   description_index { 0 };

        // draw state
        id<MTLRenderPipelineState>         pipeline { nil };
        MetalShaderReflection              reflection;
        int                                vertex_uniform_slot { -1 };
        int                                fragment_uniform_slot { -1 };
        uint32_t                           uniform_size { 0 };
        uint32_t                           uniform_offset { 0 };
        /// The ordinary program's writes, by position.
        std::vector<UniformWriteSlot>      uniform_writes;
        std::vector<TextureSlotBinding>    texture_slots;
        /// The plane-sampling variant of this pass, when one was produced.
        VideoPlaneDraw                     video_planes;
        VariantBuild                       variant_build { VariantBuild::Idle };
        /// The translated program this pass draws with, held so the optional
        /// variant can be collected from it long after the graph was compiled.
        std::shared_ptr<const SceneMetalProgram> program;
        /// The vertex layout the ordinary pipeline was built against. The
        /// variant must be built against the identical one: it is the same
        /// author program drawing the same mesh.
        MTLVertexDescriptor*               vertex_descriptor { nil };
        uint64_t                           vertex_layout_id { 0 };
        std::vector<id<MTLSamplerState>>   samplers;
        std::vector<id<MTLBuffer>>         vertex_buffers;
        std::vector<NSUInteger>            vertex_buffer_slots;
        id<MTLBuffer>                      index_buffer { nil };
        uint32_t                           index_count { 0 };
        MTLIndexType                       index_type { MTLIndexTypeUInt16 };
        NSUInteger                         index_element_size { sizeof(uint16_t) };
        std::vector<SceneMesh::DrawRange>  draw_ranges;
        uint32_t                           vertex_count { 0 };
        /// A texture slot the shader samples names nothing: the render graph
        /// found no producer for it (a layer texture whose layer draws no
        /// composite). The compatibility backend then neither draws nor clears
        /// the step, every frame, and neither does this one.
        bool                               unproduced_input { false };

        // ---- geometry the runtime rewrites every frame (particles)
        /// True when the mesh behind this pass is dynamic. Everything below is
        /// meaningless otherwise, and `vertex_buffers` / `index_buffer` are
        /// then the single immutable upload made at prepare time.
        bool                               dynamic_mesh { false };
        /// `[vertex array][frame slot]`. One storage per array per in-flight
        /// frame, allocated once at the mesh's declared capacity: the particle
        /// system's maximum count is fixed when the scene is parsed, so this
        /// never has to grow, and writing into the slot the next frame owns is
        /// what keeps the CPU off a buffer the GPU is still reading.
        std::vector<std::vector<id<MTLBuffer>>> dynamic_vertex_rings;
        std::vector<id<MTLBuffer>>         dynamic_index_ring;
        /// The mesh revision each frame slot's storage was filled from, so an
        /// unchanged simulation re-uses what is already there.
        std::vector<uint64_t>              dynamic_uploaded_generation;
        /// The layout the pipeline was built against, re-checked on every
        /// upload. A mesh that changes shape after preparation fails the frame
        /// rather than being reinterpreted against the old pipeline.
        std::vector<std::size_t>           dynamic_vertex_strides;
        std::vector<std::size_t>           dynamic_vertex_capacities;
        std::size_t                        dynamic_index_capacity { 0 };
        std::vector<std::vector<SceneVertexArray::SceneVertexAttribute>> dynamic_vertex_attributes;
        /// One entry per material texture slot that names a sprite sheet, copied
        /// from the scene's texture table the way the compatibility backend's
        /// graph builder copies it. The shared value updater advances these and
        /// writes the frame's rotation and translation uniforms; the sheet
        /// itself is one uploaded image (or one per `imageId`), never a
        /// per-frame upload.
        sprite_map_t                       sprites;
        id<MTLDepthStencilState>           depth_stencil { nil };
        bool                               depth_test { false };
        bool                               depth_write { false };
    };

    std::vector<ScenePassDescription>                   descriptions;
    std::vector<PreparedPass>                           prepared;
    std::unordered_map<std::string, id<MTLTexture>>     targets;
    /// Target keys holding a texture of their own, as opposed to sharing one
    /// with the source a copy was folded onto. Tracked because re-applying the
    /// copy plan at runtime has to know which images to give back and which to
    /// allocate again.
    std::unordered_set<std::string>                     owned_targets;
    /// Targets the reuse table pinned, whose pixels must survive the frame;
    /// they never share an image.
    std::unordered_set<std::string>                     pinned_target_keys;
    /// Depth attachments, keyed by the colour target they belong to. Created
    /// only for targets a pass actually depth-tests, at that target's size
    /// (which already honours renderScale). Post-process passes that do not
    /// depth-test do not get one.
    std::unordered_map<std::string, id<MTLTexture>>     depth_targets;
    std::unordered_map<uint32_t, id<MTLDepthStencilState>> depth_stencil_states;
    /// Every slot of an imported image, in file order. A plain image has one;
    /// a sprite sheet spread over several images has one per sheet, and the
    /// frame's `imageId` chooses between them.
    std::unordered_map<std::string, std::vector<id<MTLTexture>>> images;

    // ---- images the runtime replaces while the scene plays
    /// One replaceable image's storage: the same picture in one texture per
    /// in-flight frame, plus what each of those currently holds.
    ///
    /// A ring rather than one texture, and a ring rather than a fresh
    /// allocation per change, for the same reason the dynamic vertex storage is
    /// one: new pixels are written into the slot the next frame owns, never
    /// into an image a queued command buffer is still reading, and a text layer
    /// that re-renders its clock every minute does not allocate a texture every
    /// minute. A size or format change does allocate, and the images it
    /// replaces stay alive as long as the command buffers referencing them do.
    struct RuntimeImageRing
    {
        std::vector<id<MTLTexture>> slots;
        /// The content version each slot holds; zero means "never filled".
        std::vector<uint64_t>       slot_versions;
        /// Whether each slot holds a track's cover rather than the empty texel
        /// a cover name starts as. Read only where a cover is bound over a
        /// render target (`ScenePassDescription::cover_keys`), and taken from
        /// the image uploaded into that slot, so the choice and the pixels
        /// always agree.
        std::vector<bool>           slot_covers;
        /// The newest version seen, which is what the reuse analysis folds in.
        uint64_t                    version { 0 };
        uint32_t                    width { 0 };
        uint32_t                    height { 0 };
        MTLPixelFormat              format { MTLPixelFormatRGBA8Unorm };
        uint32_t                    bytes_per_pixel { 4 };
        /// Non-zero for a block-compressed image: a cover slot stands in for
        /// its cover with the picture its author shipped, which is whatever
        /// the file held, mip chain included.
        uint32_t                    block_bytes { 0 };
        uint32_t                    levels { 1 };
        TextureSample               sample {};
    };
    std::unordered_map<std::string, RuntimeImageRing> runtime_image_rings;
    /// How many times pixels have actually been written into one of those
    /// rings. Read by tests only; nothing in the draw path consults it.
    uint64_t                                          runtime_image_uploads { 0 };
    /// The runtime-replaceable image keys this graph's materials bind, in the
    /// order they were first seen. Fixed for the life of the graph: what makes
    /// a key replaceable is the scene's own image source, not the frame.
    std::vector<std::string>                          runtime_image_keys;

    std::unordered_map<std::string, id<MTLSamplerState>> samplers;
    std::vector<id<MTLBuffer>> uniform_rings;
    uint32_t                   uniform_ring_size { 0 };
    bool                       graph_ready { false };
    uint32_t                   demand_reasons {
        static_cast<uint32_t>(vulkan::DynamicReason::UnknownInput)
    };

    // ---- direct NV12 plane sampling
    /// Where a finished optional pipeline build leaves its result.
    ///
    /// Owned by a shared pointer because the build runs on a queue of its own:
    /// the renderer, its graph and even this object may be gone by the time the
    /// Metal compiler comes back, and the result then lands in a box that
    /// nobody reads instead of in freed memory.
    struct VariantPipelineMailbox
    {
        struct Entry
        {
            std::size_t                description_index { 0 };
            uint64_t                   generation { 0 };
            id<MTLRenderPipelineState> pipeline { nil };
            std::string                error;
        };

        std::mutex         mutex;
        std::vector<Entry> ready;
    };
    std::shared_ptr<VariantPipelineMailbox> variant_mailbox {
        std::make_shared<VariantPipelineMailbox>()
    };
    /// Bumped whenever the graph is released, so a build started for a graph
    /// that no longer exists is recognised and dropped.
    uint64_t                   graph_generation { 0 };
    /// What the last frame reported, computed on the thread that owns the state
    /// it is derived from and read by whoever asks. The host asks from its own
    /// thread, and reading the pass table from there would be reading it while
    /// a frame boundary is rewriting it.
    std::atomic<VideoFramePath> reported_path { VideoFramePath::None };
    /// Serial, and created only when the first optional build is asked for: a
    /// run that never turns the feature on never creates it.
    dispatch_queue_t           variant_queue { nullptr };

    /// The setting the current demand plan was built for. A change is applied
    /// at a frame boundary, before anything is imported, because the demand is
    /// what decides whether a conversion is encoded at all.
    bool                       video_planes_applied { false };
    /// Per prepared pass, whether it draws with its plane variant this frame.
    /// Filled after the frame's import, because it depends on the format the
    /// decoder actually produced.
    std::vector<uint8_t>       video_plane_active;

    // ---- scene optimisation
    /// The same analysis the compatibility backend runs, over this backend's
    /// own pass list. Reusing the class rather than reimplementing it is what
    /// keeps "which target may be reused" one rule with one set of tests; only
    /// the resources it governs are Metal's.
    vulkan::StaticSubgraphCache           static_cache;
    std::vector<vulkan::StaticPassSample> static_samples;
    std::vector<uint8_t>                  static_skip;
    /// One entry per description, in the same order. `None` for anything that
    /// is not a copy.
    std::vector<vulkan::CopyElision>      copy_elision;
    /// Render-target keys that share another key's texture after elision.
    std::unordered_map<std::string, std::string> target_aliases;
    uint64_t                              static_pinned_bytes { 0 };
    uint64_t                              elided_copies { 0 };
    /// Set for the lifetime of a compiled graph: whether the analysis ran at
    /// all. A graph compiled while the setting was off must not start reusing
    /// pixels when the setting is turned on, because nothing sized or pinned
    /// its targets.
    bool                                  optimization_compiled { false };
    /// The setting value the current copy plan, target table and reuse table
    /// were built for. A change is applied on the next frame, at its boundary,
    /// rather than waiting for the scene's graph to be compiled again.
    bool                                  optimization_applied { false };

    // ---- encoder counts
    /// Render and blit encoders the pass loop opened: this frame's while it is
    /// being encoded, and the last finished loop's. The composition and the
    /// poster are not scene passes and are not counted. Read by tests only;
    /// nothing in the draw path consults them.
    struct EncodeCounts
    {
        uint32_t render_passes { 0 };
        uint32_t scene_output_passes { 0 };
        uint32_t blit_passes { 0 };
    };
    EncodeCounts frame_encodes;
    EncodeCounts last_frame_encodes;

    // ---- per-pass encode inputs
    /// Each description's colour target and, when it depth-tests, its depth
    /// attachment: resolved whenever the target table changes rather than
    /// looked up by name for every pass of every frame. nil where the table
    /// has none.
    std::vector<id<MTLTexture>> pass_targets;
    std::vector<id<MTLTexture>> pass_depths;
    /// Whether a pass samples the image it renders into. Such a pass starts a
    /// render pass of its own: an image cannot be sampled by the render pass
    /// it is attached to.
    std::vector<uint8_t>        pass_reads_own_target;
    id<MTLTexture>              scene_output_target { nil };
    std::string                 scene_output_key;

    // ---- feedback copies
    /// A copy that exists only so the next pass can read the image it is
    /// about to draw into: the graph copies the image `source_key` names into
    /// `copy_key`, and `reader` then draws into the source while sampling the
    /// copy. The copy's texture already holds the right pixels by the time the
    /// reader draws, if the two names trade textures instead: the copy's name
    /// takes the source's texture, which holds exactly what the copy would,
    /// and the reader draws into the other one after copying those pixels in
    /// as its render pass's first draw. That removes the copy and the load of
    /// the image back into tile memory, which at a scene's full size is most
    /// of what such a layer costs, and every name still reads what it did.
    ///
    /// Planned only where the trade is exact: both textures private to their
    /// one name, one size and format, one mip level, no depth attachment,
    /// neither image reused across frames, and the reader the next pass to
    /// touch the source, loading it rather than clearing to nothing or leaving
    /// it undefined. Nothing between the two writes the copy.
    struct FeedbackSwap
    {
        bool                     valid { false };
        std::size_t              reader { 0 };
        /// Whether the reader's render pass begins by copying the source in.
        /// A reader that clears needs none.
        bool                     prefix { false };
        std::string              source_key;
        std::string              copy_key;
        /// Passes that render into either name, whose cached target follows
        /// the trade.
        std::vector<std::size_t> source_passes;
        std::vector<std::size_t> copy_passes;
    };
    /// One entry per description; meaningful only for copies.
    std::vector<FeedbackSwap>   feedback_swaps;
    /// The trades made while encoding this frame, undone if it is abandoned:
    /// its command buffer never runs, so the textures still hold what they
    /// held when the frame began.
    std::vector<std::size_t>    frame_swaps;
    /// Opening copies still owed in this frame: the texture a reader will
    /// render into, and the image it opens with. More than one can be owed at
    /// once -- the plan lets unrelated passes, other trades among them, run
    /// between a copy and its reader -- so each reader takes its own by target.
    std::vector<std::pair<id<MTLTexture>, id<MTLTexture>>> opening_copies;

    /// Traded copies of one source that share a small set of images instead
    /// of each keeping one. A copy takes an image from the set when it runs
    /// -- the source's own when it trades, a free one when it is blitted --
    /// and gives one back once its last reader has been encoded, so the set
    /// only has to cover the copies alive at the same time, not every copy.
    struct PooledCopy
    {
        std::size_t index { 0 };
        std::string key;
        __strong id<MTLTexture>* slot { nullptr };
    };
    struct PooledTrade
    {
        std::string                 source_key;
        __strong id<MTLTexture>*    source_slot { nullptr };
        std::vector<std::size_t>    source_passes;
        std::vector<PooledCopy>     copies;
        std::vector<id<MTLTexture>> images;
        std::vector<id<MTLTexture>> free;
    };
    std::vector<PooledTrade> pooled_trades;
    /// Per description: the group and copy a pooled copy step belongs to.
    std::vector<std::pair<int, int>> pooled_copy_at;
    /// Per description: the pooled copies whose image is free again from this
    /// pass on, because the pass before it was their last reader.
    std::vector<std::vector<std::pair<int, int>>> pooled_release_at;
    /// What every pooled name held when the frame began, put back if the
    /// frame is abandoned.
    std::vector<std::pair<__strong id<MTLTexture>*, id<MTLTexture>>> pooled_snapshot;
    /// Pooled copies run this frame; a frame that ran one is not a repeat.
    uint32_t pooled_moves { 0 };

    bool fail(std::string message)
    {
        last_error = std::move(message);
        present_gate.Invalidate();
        LOG_ERROR("metal render: %s", last_error.c_str());
        return false;
    }

    void releaseGraph();
    void releasePresentation();

    bool buildPresentation();
    id<MTLRenderPipelineState> presentPipelineFor(MTLPixelFormat format);
    bool ensurePresentPipeline(MTLPixelFormat format);
    bool encodeComposition(id<MTLCommandBuffer> command, id<MTLTexture> destination,
                           const Scene& scene);
    bool encodeScaledCopy(id<MTLCommandBuffer> command, id<MTLTexture> source,
                          id<MTLTexture> destination);
    bool compile(Scene& scene, rg::RenderGraph& graph);
    void resolveTargetSizes(Scene& scene);
    bool prepareTargets(Scene& scene);
    /// One scene target's image, labelled with its key; nil if Metal refuses it.
    id<MTLTexture> newSceneTarget(const std::string& name, const SceneRenderTarget& target);
    bool prepareDepthTargets();
    id<MTLDepthStencilState> depthStencilFor(bool test, bool write);
    void planCopyElision(Scene& scene);
    /// Fills the per-pass encode inputs from the current target tables.
    void refreshPassTargets(Scene& scene);
    /// Whether pass `index` draws this frame: a prepared draw whose layer is
    /// visible, or that has to produce its image for a consumer while hidden.
    /// The uniform write, the geometry upload and the encoder all ask this one
    /// question, so they cannot disagree about a pass.
    bool passDraws(std::size_t index) const;
    /// Whether the step's clear applies this frame. A step the compatibility
    /// backend drops for an input nothing produces drops its clear with it.
    bool passClears(std::size_t index) const;
    /// Decides which copies are replaced by a trade of textures. Called after
    /// the reuse table is built, because a reused image must keep its texture.
    void planFeedbackSwaps();
    /// Lets targets whose lifetimes in the frame do not overlap share one
    /// image. Called after the reuse table is built, because a pinned target
    /// must keep its own.
    void shareTargetImages(Scene& scene);
    /// Turns the traded copies of a source into a pooled trade where every
    /// one of them qualifies. Called after the trades are planned.
    void planPooledTrades(Scene& scene);
    /// Gives every pooled copy an image of its own again, before a change of
    /// plan, so nothing is left sharing outside a pooled trade.
    void releasePooledTrades();
    /// The frame-start state of the pooled trades: free sets and snapshot.
    void beginPooledTrades();
    /// Puts every pooled name back to what it held when the frame began.
    void abandonPooledTrades(Scene& scene);
    bool ensureSceneCopyPipeline(MTLPixelFormat format);
    /// Whether the reader of copy `index` renders this frame. A reader that
    /// neither draws nor clears opens no render pass, so it could not copy
    /// the source in, and the copy is executed as a copy instead.
    bool feedbackReaderRenders(std::size_t index) const;
    /// Trades the textures of copy `index`'s two names, everywhere this backend
    /// looks them up. Its own inverse.
    void tradeFeedbackTextures(std::size_t index);
    void compileStaticCache(Scene& scene);
    void releaseSceneOptimization();
    /// Rebuilds the copy plan, the target table and the reuse table for the
    /// current setting, at a frame boundary. Clears for targets that regain an
    /// image of their own are encoded into `command`, so nothing waits.
    bool applySceneOptimizationSetting(Scene& scene, id<MTLCommandBuffer> command);
    vulkan::StaticPassSample frameSample(Scene& scene, std::size_t index) const;
    /// Fills `static_skip` for this frame. False means nothing may be skipped.
    bool planStaticSkips(Scene& scene);
    bool clearTargetsOnce();
    bool prepareDraw(Scene& scene, std::size_t index, PreparedPass& out);
    /// Collects finished optional builds and starts the ones now wanted.
    ///
    /// Runs at a frame boundary and never blocks: everything expensive happens
    /// on the variant queue, and a pass whose variant is not ready draws with
    /// the ordinary program exactly as it did before the variant existed.
    void pumpVideoPlaneVariants(Scene& scene, bool planes_enabled);
    /// Turns a compiled variant and its pipeline into a draw this pass can
    /// switch to. Never fails the pass: a variant that cannot be used is
    /// refused and the ordinary program keeps the material.
    bool installVideoPlaneDraw(Scene& scene, std::size_t index, PreparedPass& out,
                               const SceneMetalVideoPlaneVariant& variant,
                               id<MTLRenderPipelineState> pipeline);
    /// Publishes what each video texture's consumers can use, before the next
    /// frame is imported.
    void updateVideoDemand(bool planes_enabled);
    /// Decides, per pass, whether this frame is drawn with the plane variant.
    void selectVideoPlaneDraws(bool planes_enabled);
    /// The path this frame took, refined with whether an optional program is
    /// still on its way.
    ///
    /// "Preparing" is said only while something is genuinely in flight -- a
    /// translation queued or running, or a pipeline being built. A material for
    /// which the variant was refused, or which never had a candidate, reports
    /// the plain converting path, because nothing further is coming.
    [[nodiscard]] VideoFramePath framePathReport(bool planes_enabled) const
    {
        const auto path = video.path();
        if (path != VideoFramePath::Nv12Converted || ! planes_enabled) return path;
        for (const auto& pass : prepared) {
            if (pass.program == nullptr || ! pass.program->hasVideoPlaneCandidate()) continue;
            if (pass.variant_build == VariantBuild::Building) {
                return VideoFramePath::Nv12ConvertedPreparing;
            }
            if (pass.variant_build != VariantBuild::Idle) continue;
            const auto state = pass.program->videoPlaneState();
            if (state == SceneMetalVariantState::Pending ||
                state == SceneMetalVariantState::Ready) {
                return VideoFramePath::Nv12ConvertedPreparing;
            }
        }
        return path;
    }

    /// How many passes currently hold a usable variant. Used to notice that one
    /// was adopted, which changes what its video's consumers need.
    [[nodiscard]] std::size_t readyVariantCount() const
    {
        std::size_t count = 0;
        for (const auto& pass : prepared) {
            if (pass.video_planes.ready) ++count;
        }
        return count;
    }
    /// Copies this frame's simulated geometry into the slot the frame owns.
    /// False means the mesh no longer matches what the pipeline was built for,
    /// which fails the frame rather than drawing it against a stale layout.
    bool uploadDynamicMesh(PreparedPass& pass, const ScenePassDescription& desc,
                           std::string* error);
    /// `image_slot` selects one slot of a multi-image sprite sheet; negative
    /// means the first, which is what every non-sprite texture has.
    id<MTLTexture> resolveTexture(Scene& scene, const std::string& key,
                                  id<MTLSamplerState>* sampler_out, int image_slot = -1);
    /// The cover slot `slot` of `desc` shows over its render target this frame
    /// (`ScenePassDescription::cover_keys`), with its sampler; nil while no
    /// cover is published, when the slot samples the target it names.
    id<MTLTexture> publishedCover(const ScenePassDescription& desc, std::size_t slot,
                                  id<MTLSamplerState>* sampler_out);
    /// Names the replaceable images this graph binds. Called once per compiled
    /// graph, because the answer cannot change inside one.
    void collectRuntimeImageKeys(Scene& scene);
    /// Brings this frame's slot of every replaceable image up to date, before
    /// anything samples one. Uploads nothing when the content has not changed,
    /// which is the ordinary case for a text layer standing still.
    void refreshRuntimeImages(Scene& scene);
    id<MTLSamplerState> samplerFor(const TextureSample& sample);
    /// The same wrap modes with linear filtering, for the chroma plane.
    id<MTLSamplerState> chromaSamplerFor(const TextureSample& sample);
    id<MTLRenderPipelineState> pipelineFor(const MetalPipelineKey& key,
                                           const std::vector<SceneMetalStage>& stages,
                                           MTLVertexDescriptor* vertex_descriptor);
    void computeDemandReasons(Scene& scene, rg::RenderGraph& graph);
    void writeUniforms(Scene& scene, const ScenePassDescription& desc, PreparedPass& pass,
                       const MetalShaderReflection& reflection, bool planes_active,
                       uint8_t* destination);
    WallpaperScalingLayout scalingLayout(const Scene& scene, uint32_t width,
                                         uint32_t height) const;
};

void MetalRender::Impl::releaseSceneOptimization()
{
    if (static_pinned_bytes != 0) {
        vulkan::AdjustSceneOptimizationPinnedBytes(-static_cast<int64_t>(static_pinned_bytes));
        static_pinned_bytes = 0;
    }
    static_cache.Reset();
    static_samples.clear();
    static_skip.clear();
    copy_elision.clear();
    target_aliases.clear();
    elided_copies         = 0;
    optimization_compiled = false;
}

void MetalRender::Impl::releaseGraph()
{
    video.release();
    poster.invalidate();
    releaseSceneOptimization();
    frame_drawn = false;
    present_gate.Invalidate();
    descriptions.clear();
    prepared.clear();
    targets.clear();
    depth_targets.clear();
    pass_targets.clear();
    pass_depths.clear();
    pass_reads_own_target.clear();
    scene_output_target = nil;
    scene_output_key.clear();
    feedback_swaps.clear();
    frame_swaps.clear();
    opening_copies.clear();
    pooled_trades.clear();
    pooled_copy_at.clear();
    pooled_release_at.clear();
    pooled_snapshot.clear();
    images.clear();
    runtime_image_rings.clear();
    runtime_image_keys.clear();
    runtime_image_uploads = 0;
    samplers.clear();
    // A new graph, and nothing an optional build started for the old one may
    // arrive in it. The mailbox is replaced rather than emptied, so a build
    // still running writes into a box nobody reads and the pipeline it produces
    // is simply dropped -- the shared program cache keeps it, so a scene that
    // comes back does not pay for it again.
    ++graph_generation;
    variant_mailbox = std::make_shared<VariantPipelineMailbox>();
    reported_path.store(VideoFramePath::None);
    uniform_rings.clear();
    uniform_ring_size = 0;
    graph_ready       = false;
    demand_reasons    = static_cast<uint32_t>(vulkan::DynamicReason::UnknownInput);
}

void MetalRender::Impl::releasePresentation()
{
    // The pipelines survive: they depend on the device and a colour format, not
    // on the layer, and a scaled copy still needs its own one after a display
    // reconfiguration has released the surface.
    poster.invalidate();
    frame_drawn              = false;
    present_gate.Invalidate();
    present_library          = nil;
    present_vertices         = nil;
    present_vertices_flipped = nil;
    present_sampler          = nil;
    layer                    = nil;
}

bool MetalRender::Impl::buildPresentation()
{
    present_gate.Invalidate();
    NSError* error = nil;
    NSString* source =
        [[NSString alloc] initWithBytes:kPresentShaderSource.data()
                                 length:kPresentShaderSource.size()
                               encoding:NSUTF8StringEncoding];
    MTLCompileOptions* options = [MTLCompileOptions new];
    id<MTLLibrary> library = [device newLibraryWithSource:source options:options error:&error];
    if (library == nil) {
        return fail(std::string("presentation shader failed to compile: ") +
                    (error != nil ? error.localizedDescription.UTF8String : "unknown error"));
    }
    present_library = library;
    if (! ensurePresentPipeline(drawable_format)) return false;

    present_vertices = [device newBufferWithBytes:kPresentVertices
                                           length:sizeof(kPresentVertices)
                                          options:MTLResourceStorageModeShared];
    present_vertices_flipped = [device newBufferWithBytes:kPresentVerticesFlipped
                                                   length:sizeof(kPresentVerticesFlipped)
                                                  options:MTLResourceStorageModeShared];
    if (present_vertices == nil || present_vertices_flipped == nil) {
        return fail("presentation vertices could not be allocated");
    }

    MTLSamplerDescriptor* sampler_descriptor = [MTLSamplerDescriptor new];
    sampler_descriptor.minFilter    = MTLSamplerMinMagFilterLinear;
    sampler_descriptor.magFilter    = MTLSamplerMinMagFilterLinear;
    sampler_descriptor.sAddressMode = MTLSamplerAddressModeClampToEdge;
    sampler_descriptor.tAddressMode = MTLSamplerAddressModeClampToEdge;
    present_sampler = [device newSamplerStateWithDescriptor:sampler_descriptor];
    if (present_sampler == nil) return fail("presentation sampler could not be created");
    return true;
}

id<MTLRenderPipelineState> MetalRender::Impl::presentPipelineFor(MTLPixelFormat format)
{
    const auto found = present_pipelines.find(static_cast<uint32_t>(format));
    return found != present_pipelines.end() ? found->second : nil;
}

bool MetalRender::Impl::ensurePresentPipeline(MTLPixelFormat format)
{
    if (presentPipelineFor(format) != nil) return true;
    if (present_library == nil) return fail("the presentation shader is not available");

    MTLRenderPipelineDescriptor* descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction   = [present_library newFunctionWithName:@"owe_present_vertex"];
    descriptor.fragmentFunction = [present_library newFunctionWithName:@"owe_present_fragment"];
    descriptor.colorAttachments[0].pixelFormat = format;

    NSError* error = nil;
    id<MTLRenderPipelineState> pipeline =
        [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (pipeline == nil) {
        return fail(std::string("presentation pipeline failed to build: ") +
                    (error != nil ? error.localizedDescription.UTF8String : "unknown error"));
    }
    present_pipelines.emplace(static_cast<uint32_t>(format), pipeline);
    return true;
}

/// Copies `source` onto the whole of `destination` through a render pass.
///
/// A blit cannot do this: Metal's texture-to-texture blit requires matching
/// sizes and compatible formats, and the scene's own post-process chain copies
/// between buffers that differ in both -- a full-resolution buffer into a half
/// one, for instance. Skipping such a copy, which is what this used to do,
/// left the destination holding the previous frame while every later pass read
/// it as if it were fresh.
bool MetalRender::Impl::encodeScaledCopy(id<MTLCommandBuffer> command, id<MTLTexture> source,
                                         id<MTLTexture> destination)
{
    if (command == nil || source == nil || destination == nil) return false;
    id<MTLRenderPipelineState> pipeline = presentPipelineFor(destination.pixelFormat);
    if (pipeline == nil) return false;

    MTLRenderPassDescriptor* descriptor = [MTLRenderPassDescriptor renderPassDescriptor];
    descriptor.colorAttachments[0].texture     = destination;
    // The draw covers every texel, so there is nothing to preserve or clear.
    descriptor.colorAttachments[0].loadAction  = MTLLoadActionDontCare;
    descriptor.colorAttachments[0].storeAction = MTLStoreActionStore;

    id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:descriptor];
    if (encoder == nil) return false;
    [encoder setViewport:(MTLViewport) { 0.0, 0.0, (double)destination.width,
                                         (double)destination.height, 0.0, 1.0 }];
    [encoder setScissorRect:(MTLScissorRect) { 0, 0, destination.width, destination.height }];
    [encoder setCullMode:static_cast<MTLCullMode>(kSceneCullMode)];
    [encoder setRenderPipelineState:pipeline];
    // Never the flipped vertices: a copy inside the frame is not presentation,
    // and the user's horizontal flip applies once, at the end.
    [encoder setVertexBuffer:present_vertices offset:0 atIndex:0];
    [encoder setFragmentTexture:source atIndex:0];
    [encoder setFragmentSamplerState:present_sampler atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [encoder endEncoding];
    return true;
}

/// Draws the scene's output image into `destination` with the user's scaling
/// mode, zoom and horizontal flip.
///
/// One implementation for the drawable and for a poster capture. Two would drift
/// and the drift would show as a poster that is framed differently from the
/// wallpaper it claims to be a picture of. The layout is computed from the
/// destination's own size, which is the only thing that differs between them.
bool MetalRender::Impl::encodeComposition(id<MTLCommandBuffer> command,
                                          id<MTLTexture> destination, const Scene& scene)
{
    if (command == nil || destination == nil) return false;
    const auto output = targets.find(scene.ResolveRenderTargetName(SpecTex_Default));
    if (output == targets.end()) return false;
    id<MTLRenderPipelineState> pipeline = presentPipelineFor(destination.pixelFormat);
    if (pipeline == nil) return false;

    const auto layout =
        scalingLayout(scene, (uint32_t)destination.width, (uint32_t)destination.height);
    MTLRenderPassDescriptor* present = [MTLRenderPassDescriptor renderPassDescriptor];
    present.colorAttachments[0].texture     = destination;
    // Cleared, so the letterbox around a fitted image is black rather than
    // whatever the destination held.
    present.colorAttachments[0].loadAction  = MTLLoadActionClear;
    present.colorAttachments[0].storeAction = MTLStoreActionStore;
    present.colorAttachments[0].clearColor  = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);

    id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:present];
    if (encoder == nil) return false;
    const VulkanViewportBox viewport {
        .x      = (double)layout.viewport_px.x,
        .y      = (double)(layout.viewport_px.y + std::max(1, layout.viewport_px.height)),
        .width  = (double)std::max(1, layout.viewport_px.width),
        .height = -(double)std::max(1, layout.viewport_px.height),
    };
    const auto metal_viewport = ToMetalViewport(viewport);
    [encoder setViewport:(MTLViewport) { metal_viewport.origin_x, metal_viewport.origin_y,
                                         metal_viewport.width, metal_viewport.height, 0.0, 1.0 }];
    const NSUInteger scissor_width  = (NSUInteger)std::max(0, layout.scissor_px.width);
    const NSUInteger scissor_height = (NSUInteger)std::max(0, layout.scissor_px.height);
    [encoder setScissorRect:(MTLScissorRect) { (NSUInteger)std::max(0, layout.scissor_px.x),
                                               (NSUInteger)std::max(0, layout.scissor_px.y),
                                               std::min(scissor_width, destination.width),
                                               std::min(scissor_height, destination.height) }];
    [encoder setCullMode:static_cast<MTLCullMode>(kSceneCullMode)];
    [encoder setRenderPipelineState:pipeline];
    [encoder setVertexBuffer:(horizontal_flip ? present_vertices_flipped : present_vertices)
                      offset:0
                     atIndex:0];
    [encoder setFragmentTexture:output->second atIndex:0];
    [encoder setFragmentSamplerState:present_sampler atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [encoder endEncoding];
    return true;
}

id<MTLSamplerState> MetalRender::Impl::samplerFor(const TextureSample& sample)
{
    char key_bytes[6] = {
        static_cast<char>(sample.wrapS),
        static_cast<char>(sample.wrapT),
        static_cast<char>(sample.magFilter),
        static_cast<char>(sample.minFilter),
        static_cast<char>(sample.mipFilter),
        '\0',
    };
    const std::string key(key_bytes, 5);
    if (auto found = samplers.find(key); found != samplers.end()) return found->second;

    MTLSamplerDescriptor* descriptor = [MTLSamplerDescriptor new];
    descriptor.sAddressMode = ToMetalAddressMode(sample.wrapS);
    descriptor.tAddressMode = ToMetalAddressMode(sample.wrapT);
    descriptor.magFilter    = ToMetalFilter(sample.magFilter);
    descriptor.minFilter    = ToMetalFilter(sample.minFilter);
    // Only a texture whose file asks for point sampling picks its mip level by
    // point; see `TextureSample::mipFilter`.
    descriptor.mipFilter    = sample.mipFilter == TextureFilter::NEAREST
                                  ? MTLSamplerMipFilterNearest
                                  : MTLSamplerMipFilterLinear;
    id<MTLSamplerState> state = [device newSamplerStateWithDescriptor:descriptor];
    if (state == nil) return nil;
    samplers.emplace(key, state);
    return state;
}

id<MTLSamplerState> MetalRender::Impl::chromaSamplerFor(const TextureSample& sample)
{
    // The author's wrap modes with linear filtering. The pre-converted path
    // upsamples chroma linearly for every consumer, whatever filter the author
    // asked for on the colour image, so reproducing that here is what keeps a
    // one-to-one sample of either path landing on the same colour.
    TextureSample chroma = sample;
    chroma.magFilter     = TextureFilter::LINEAR;
    chroma.minFilter     = TextureFilter::LINEAR;
    return samplerFor(chroma);
}

void MetalRender::Impl::collectRuntimeImageKeys(Scene& scene)
{
    runtime_image_keys.clear();
    runtime_image_rings.clear();
    const auto* runtime_images =
        dynamic_cast<const RuntimeImageSource*>(scene.imageParser.get());
    if (runtime_images == nullptr) return;

    const auto collect = [&](const std::string& key) {
        if (key.empty() || IsSpecTex(key)) return;
        if (! runtime_images->IsRuntimeImage(key)) return;
        if (std::find(runtime_image_keys.begin(), runtime_image_keys.end(), key) ==
            runtime_image_keys.end()) {
            runtime_image_keys.push_back(key);
        }
    };
    for (const auto& desc : descriptions) {
        for (const auto& key : desc.texture_keys) collect(key);
        // A cover a slot shows over its render target is uploaded like any
        // other, though the slot itself names the target.
        for (const auto& key : desc.cover_keys) collect(key);
    }
}

void MetalRender::Impl::refreshRuntimeImages(Scene& scene)
{
    if (runtime_image_keys.empty()) return;
    auto* runtime_images = dynamic_cast<RuntimeImageSource*>(scene.imageParser.get());
    if (runtime_images == nullptr) return;

    const std::size_t slot = static_cast<std::size_t>(frame_slot) % kFramesInFlight;
    for (const auto& key : runtime_image_keys) {
        auto& ring = runtime_image_rings[key];
        // The version alone answers "is anything different?", so the common
        // case -- a text layer whose text, font and size have not moved -- costs
        // one integer comparison and touches no pixels at all.
        const uint64_t version = runtime_images->Version(key);
        ring.version           = version;
        if (version != 0 && slot < ring.slot_versions.size() &&
            ring.slot_versions[slot] == version) {
            continue;
        }

        // Only now is the image itself fetched. `Parse` on a name this source
        // does not own would fall through to the file parser and decode from
        // disk, which is why only keys it owns are ever asked.
        auto parsed = runtime_images->Parse(key);
        if (parsed == nullptr || parsed->slots.empty() || parsed->slots.front().mipmaps.empty()) {
            continue;
        }
        const auto& source = parsed->slots.front();
        const auto& mipmap = source.mipmaps.front();
        if (mipmap.data == nullptr || mipmap.width <= 0 || mipmap.height <= 0) continue;

        // Pixels the runtime rasterised are never blocks. The picture a cover
        // slot shows while no cover exists is the author's own file, which may
        // be block-compressed and carry a mip chain, so both are offered.
        MTLPixelFormat format {};
        uint32_t       bytes_per_pixel = 0;
        uint32_t       block_bytes     = 0;
        if (! ToMetalImageFormat(parsed->header.format, device.supportsBCTextureCompression,
                                 format, bytes_per_pixel, block_bytes)) {
            continue;
        }

        const auto width  = static_cast<uint32_t>(mipmap.width);
        const auto height = static_cast<uint32_t>(mipmap.height);
        const auto levels = static_cast<uint32_t>(source.mipmaps.size());
        if (ring.slots.size() != kFramesInFlight || ring.width != width ||
            ring.height != height || ring.format != format || ring.levels != levels) {
            // A new size or format needs new images. The ones being replaced
            // are released here and stay alive exactly as long as the command
            // buffers that reference them, which retain what they encode.
            std::vector<id<MTLTexture>> rebuilt;
            rebuilt.reserve(kFramesInFlight);
            for (NSUInteger f = 0; f < kFramesInFlight; ++f) {
                MTLTextureDescriptor* descriptor =
                    [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                                       width:(NSUInteger)width
                                                                      height:(NSUInteger)height
                                                                   mipmapped:levels > 1];
                if (levels > 1) descriptor.mipmapLevelCount = levels;
                descriptor.usage       = MTLTextureUsageShaderRead;
                descriptor.storageMode = MTLStorageModeShared;
                id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
                if (texture == nil) break;
                rebuilt.push_back(texture);
            }
            if (rebuilt.size() != kFramesInFlight) continue;
            ring.slots           = std::move(rebuilt);
            ring.slot_versions.assign(kFramesInFlight, 0);
            ring.slot_covers.assign(kFramesInFlight, false);
            ring.width           = width;
            ring.height          = height;
            ring.format          = format;
            ring.bytes_per_pixel = bytes_per_pixel;
            ring.block_bytes     = block_bytes;
            ring.levels          = levels;
        }

        // The sampler follows the image the name shows now, as the compatibility
        // backend's does: a cover slot shows its author's picture, sampled as the
        // file says, and then a track's cover, clamped and linear.
        ring.sample = parsed->header.sample;

        // Into the texture the next frame owns, never one a queued command
        // buffer is still reading. A level the image does not hold stays as it was.
        if (! UploadImageLevels(ring.slots[slot], source, bytes_per_pixel, block_bytes)) continue;
        ring.slot_versions[slot] = version;
        ring.slot_covers[slot]   = ! RuntimeImageSource::IsEmptyCover(*parsed);
        ++runtime_image_uploads;
    }
}

id<MTLTexture> MetalRender::Impl::publishedCover(const ScenePassDescription& desc,
                                                 std::size_t slot,
                                                 id<MTLSamplerState>* sampler_out)
{
    if (slot >= desc.cover_keys.size() || desc.cover_keys[slot].empty()) return nil;
    const auto ring = runtime_image_rings.find(desc.cover_keys[slot]);
    if (ring == runtime_image_rings.end() || ring->second.slots.empty()) return nil;
    const std::size_t frame = static_cast<std::size_t>(frame_slot) % kFramesInFlight;
    if (frame >= ring->second.slot_covers.size() || ! ring->second.slot_covers[frame]) return nil;
    if (sampler_out != nullptr) *sampler_out = samplerFor(ring->second.sample);
    return ring->second.slots[frame];
}

id<MTLTexture> MetalRender::Impl::resolveTexture(Scene& scene, const std::string& key,
                                                 id<MTLSamplerState>* sampler_out, int image_slot)
{
    if (key.empty()) return nil;
    const auto pick = [image_slot](const std::vector<id<MTLTexture>>& slots) -> id<MTLTexture> {
        if (slots.empty()) return nil;
        if (image_slot < 0 || static_cast<std::size_t>(image_slot) >= slots.size()) {
            return slots.front();
        }
        return slots[static_cast<std::size_t>(image_slot)];
    };

    // A video key never reaches the image parser: its placeholder still would
    // be uploaded once and then bound forever in place of the decoded frame.
    if (video.owns(key)) {
        if (sampler_out != nullptr) {
            const auto found = scene.textures.find(key);
            *sampler_out     = samplerFor(found != scene.textures.end() ? found->second.sample
                                                                       : TextureSample {});
        }
        return video.texture(key);
    }

    if (auto target = targets.find(key); target != targets.end()) {
        if (sampler_out != nullptr) {
            const auto* render_target = scene.FindRenderTarget(key);
            *sampler_out = samplerFor(render_target != nullptr ? render_target->sample
                                                               : TextureSample {});
        }
        return target->second;
    }

    // A replaceable image never reaches the importer below: it has no file to
    // read, and its pixels are whatever the runtime last produced.
    if (auto ring = runtime_image_rings.find(key);
        ring != runtime_image_rings.end() && ! ring->second.slots.empty()) {
        if (sampler_out != nullptr) *sampler_out = samplerFor(ring->second.sample);
        return ring->second.slots[static_cast<std::size_t>(frame_slot) % kFramesInFlight];
    }

    if (auto image = images.find(key); image != images.end()) {
        if (sampler_out != nullptr) {
            const auto found = scene.textures.find(key);
            *sampler_out     = samplerFor(found != scene.textures.end() ? found->second.sample
                                                                       : TextureSample {});
        }
        return pick(image->second);
    }

    if (IsSpecTex(key)) {
        // A spec texture with no allocation is a render target the graph never
        // produced. Treated as missing rather than substituted.
        return nil;
    }

    if (scene.imageParser == nullptr) return nil;
    auto parsed = scene.imageParser->Parse(key);
    if (parsed == nullptr || parsed->slots.empty() || parsed->slots.front().mipmaps.empty()) {
        return nil;
    }

    MTLPixelFormat format {};
    uint32_t       bytes_per_pixel = 0;
    uint32_t       block_bytes     = 0;
    if (! ToMetalImageFormat(parsed->header.format, device.supportsBCTextureCompression, format,
                             bytes_per_pixel, block_bytes)) {
        return nil;
    }

    // Every slot for a sprite sheet, the first one for anything else. A sheet
    // whose frames are spread over several images names the one it wants
    // through the frame's `imageId`, exactly as the compatibility backend's
    // texture slots do, and importing only one would play the whole animation
    // out of the first sheet. A texture that is not a sheet has no way to reach
    // a second slot, so uploading one would be memory nothing can sample.
    const auto  scene_texture = scene.textures.find(key);
    const bool  is_sprite =
        scene_texture != scene.textures.end() ? scene_texture->second.isSprite
                                              : parsed->header.isSprite;
    const std::size_t wanted = is_sprite ? parsed->slots.size() : 1;
    std::vector<id<MTLTexture>> slot_textures;
    slot_textures.reserve(wanted);
    for (const auto& slot : std::span(parsed->slots).first(wanted)) {
        if (slot.mipmaps.empty() || slot.width <= 0 || slot.height <= 0) break;
        MTLTextureDescriptor* descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                               width:(NSUInteger)slot.width
                                                              height:(NSUInteger)slot.height
                                                           mipmapped:slot.mipmaps.size() > 1];
        descriptor.mipmapLevelCount = slot.mipmaps.size();
        descriptor.usage            = MTLTextureUsageShaderRead;
        // Shared storage, so the pixels are written straight into the texture.
        // A staging buffer plus a blit would need the frame to wait on an
        // upload, which is exactly what the per-frame path must never do.
        descriptor.storageMode = MTLStorageModeShared;

        id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
        if (texture == nil) break;
        if (! UploadImageLevels(texture, slot, bytes_per_pixel, block_bytes)) break;
        slot_textures.push_back(texture);
    }
    if (slot_textures.empty()) return nil;

    const auto inserted = images.emplace(key, std::move(slot_textures)).first;
    if (sampler_out != nullptr) {
        const auto found = scene.textures.find(key);
        *sampler_out     = samplerFor(found != scene.textures.end() ? found->second.sample
                                                                   : parsed->header.sample);
    }
    return pick(inserted->second);
}

id<MTLRenderPipelineState> MetalRender::Impl::pipelineFor(
    const MetalPipelineKey& key, const std::vector<SceneMetalStage>& stages,
    MTLVertexDescriptor* vertex_descriptor)
{
    std::string error;
    id<MTLRenderPipelineState> state = MetalProgramCache::shared().pipelineFor(
        device, key, stages, vertex_descriptor, pipeline_archive_root, &error);
    if (state == nil && ! error.empty()) last_error = std::move(error);
    return state;
}

void MetalRender::SetPipelineArchivePath(std::string_view path)
{
    if (pImpl == nullptr) return;
    pImpl->pipeline_archive_root = std::string(path);
}

/// Sizes every render target the way the compatibility backend does.
///
/// The three sizings are different questions and must not be flattened into
/// one. A screen-bound target follows the raster extent; a target the author
/// sized directly -- an effect ping-pong buffer, a fixed-fraction scratch
/// buffer -- follows the internal render scale from its own authored size; a
/// bound target follows a fraction of the target it names. An author's
/// half-resolution blur buffer at 50% internal scale is therefore a quarter of
/// the canvas in each axis, which is what makes the two scales compose instead
/// of one overwriting the other.
void MetalRender::Impl::resolveTargetSizes(Scene& scene)
{
    const VkExtent2D fallback { std::max<uint32_t>(1, output_width),
                                std::max<uint32_t>(1, output_height) };
    const auto extents      = vulkan::ResolveScreenBoundRenderTargetSizes(
        scene, fallback,
        vulkan::SceneRasterSurface { .display_scale_factor = NormalizeScaleFactor(display_scale_factor),
                                     .max_dimension        = MaxTextureDimension(device) });
    const auto render_scale = vulkan::ResolveSceneRenderScale(scene);
    raster_width            = std::max(1u, extents.raster.width);
    raster_height           = std::max(1u, extents.raster.height);

    for (auto& [name, target] : scene.renderTargets) {
        if (name == SpecTex_Default) continue;
        if (target.bind.screen && target.bind.enable) continue;
        if (! target.bind.enable) {
            vulkan::ResolveRenderScaledSize(target, render_scale);
            continue;
        }
        const auto bound = scene.renderTargets.find(target.bind.name);
        if (target.bind.name.empty() || bound == scene.renderTargets.end()) continue;
        target.width  = static_cast<int32_t>(target.bind.scale * bound->second.width);
        target.height = static_cast<int32_t>(target.bind.scale * bound->second.height);
    }

    for (auto& [name, target] : scene.renderTargets) {
        (void)name;
        if (! target.has_mipmap) continue;
        const auto smaller = std::max(1, std::min(target.width, target.height));
        target.mipmap_level =
            std::max(3u, static_cast<uint32_t>(std::floor(std::log2(smaller)))) - 2u;
    }
}

static std::unordered_set<std::string> ReferencedRenderTargets(
    const Scene& scene, const std::vector<ScenePassDescription>& descriptions)
{
    std::unordered_set<std::string> required { scene.ResolveRenderTargetName(SpecTex_Default) };
    // Include hidden draws and elided copies: animation can reveal them, and
    // disabling optimization can restore a copy without recompiling the graph.
    for (const auto& pass : descriptions) {
        if (! pass.target_key.empty()) required.insert(pass.target_key);
        if (! pass.source_key.empty()) required.insert(pass.source_key);
        required.insert(pass.texture_keys.begin(), pass.texture_keys.end());
    }
    return required;
}

id<MTLTexture> MetalRender::Impl::newSceneTarget(const std::string&       name,
                                                 const SceneRenderTarget& target)
{
    const NSUInteger levels = std::max<uint32_t>(1, target.mipmap_level);
    MTLTextureDescriptor* descriptor = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:SceneTargetFormat(target.format)
                                     width:(NSUInteger)target.width
                                    height:(NSUInteger)target.height
                                 mipmapped:levels > 1];
    descriptor.mipmapLevelCount = levels;
    descriptor.usage            = kRenderTargetUsage;
    // Private, never memoryless. A later pass, the presentation draw and a
    // poster capture all read these after the pass that wrote them has
    // ended, so their contents have to survive the render pass.
    descriptor.storageMode = MTLStorageModePrivate;
    id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
    if (texture != nil) texture.label = [NSString stringWithUTF8String:name.c_str()];
    return texture;
}

bool MetalRender::Impl::prepareTargets(Scene& scene)
{
    targets.clear();
    owned_targets.clear();
    const auto required = ReferencedRenderTargets(scene, descriptions);
    for (const auto& [name, target] : scene.renderTargets) {
        if (! required.contains(name)) continue;
        if (target.width <= 0 || target.height <= 0) continue;
        // An aliased destination shares its source's texture, so it must not
        // get one of its own. Resolved after the loop, because the source may
        // be allocated later than the destination is visited.
        if (target_aliases.count(name) != 0) continue;
        id<MTLTexture> texture = newSceneTarget(name, target);
        if (texture == nil) {
            return fail("a render target could not be allocated");
        }
        targets.emplace(name, texture);
        owned_targets.insert(name);
    }
    // Alias chains are resolved by walking to a key that is not itself an
    // alias. The walk is bounded by the number of aliases, so a cycle the
    // planner could never produce still cannot hang the compile; a destination
    // whose source was never allocated simply keeps no entry, and every read of
    // it fails the way a missing target already does.
    for (const auto& [destination, source] : target_aliases) {
        std::string root = source;
        for (std::size_t step = 0; step <= target_aliases.size(); ++step) {
            const auto next = target_aliases.find(root);
            if (next == target_aliases.end()) break;
            root = next->second;
        }
        const auto found = targets.find(root);
        if (found == targets.end()) continue;
        targets.emplace(destination, found->second);
    }
    if (targets.find(scene.ResolveRenderTargetName(SpecTex_Default)) == targets.end()) {
        return fail("the scene has no output image");
    }
    return clearTargetsOnce();
}

bool MetalRender::Impl::prepareDepthTargets()
{
    depth_targets.clear();
    std::unordered_set<std::string> needed;
    for (const auto& desc : descriptions) {
        if (desc.kind != MetalPassKind::CustomShader || ! desc.depth_test) continue;
        if (desc.target_key.empty()) continue;
        needed.insert(desc.target_key);
    }
    for (const auto& key : needed) {
        const auto color = targets.find(key);
        if (color == targets.end() || color->second == nil) {
            return fail("a depth-tested pass targets an image that does not exist");
        }
        MTLTextureDescriptor* descriptor = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                         width:color->second.width
                                        height:color->second.height
                                     mipmapped:NO];
        descriptor.usage       = MTLTextureUsageRenderTarget;
        descriptor.storageMode = MTLStorageModePrivate;
        id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
        if (texture == nil) return fail("a depth attachment could not be allocated");
        texture.label = [NSString stringWithFormat:@"%s/depth", key.c_str()];
        depth_targets.emplace(key, texture);
    }
    return true;
}

void MetalRender::Impl::refreshPassTargets(Scene& scene)
{
    const auto lookup = [](const std::unordered_map<std::string, id<MTLTexture>>& table,
                           const std::string& key) -> id<MTLTexture> {
        if (key.empty()) return nil;
        const auto found = table.find(key);
        return found != table.end() ? found->second : nil;
    };
    pass_targets.assign(descriptions.size(), nil);
    pass_depths.assign(descriptions.size(), nil);
    pass_reads_own_target.assign(descriptions.size(), uint8_t { 0 });
    for (std::size_t i = 0; i < descriptions.size(); ++i) {
        const auto&    desc   = descriptions[i];
        id<MTLTexture> target = lookup(targets, desc.target_key);
        pass_targets[i]       = target;
        if (i < prepared.size() && prepared[i].depth_test) {
            pass_depths[i] = lookup(depth_targets, desc.target_key);
        }
        if (target == nil) continue;
        // Through the table, not by name: a key the copy plan folded onto
        // another shares that key's image.
        for (const auto& key : desc.texture_keys) {
            if (lookup(targets, key) != target) continue;
            pass_reads_own_target[i] = 1;
            break;
        }
    }
    scene_output_key    = scene.ResolveRenderTargetName(SpecTex_Default);
    scene_output_target = lookup(targets, scene_output_key);
}

bool MetalRender::Impl::passDraws(std::size_t index) const
{
    const auto& pass = prepared[index];
    if (pass.kind != MetalPassKind::CustomShader || pass.pipeline == nil) return false;
    if (pass.unproduced_input) return false;
    const auto& desc = descriptions[index];
    return desc.visibility_node == nullptr || desc.visibility_node->EffectiveVisible() ||
           (desc.visibility_node->MustProduce() && ! desc.target_key.empty() &&
            desc.target_key != wallpaper::SpecTex_Default);
}

bool MetalRender::Impl::ensureSceneCopyPipeline(MTLPixelFormat format)
{
    if (scene_copy_pipelines.contains(static_cast<uint32_t>(format))) return true;
    if (present_library == nil) return false;
    MTLRenderPipelineDescriptor* descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction   = [present_library newFunctionWithName:@"owe_present_vertex"];
    descriptor.fragmentFunction = [present_library newFunctionWithName:@"owe_copy_fragment"];
    descriptor.colorAttachments[0].pixelFormat = format;
    NSError* error = nil;
    id<MTLRenderPipelineState> pipeline =
        [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (pipeline == nil) {
        // Not a failed scene: the copies are simply made as copies.
        LOG_ERROR("metal render: the scene copy pipeline failed to build: %s",
                  error != nil ? error.localizedDescription.UTF8String : "unknown error");
        return false;
    }
    scene_copy_pipelines.emplace(static_cast<uint32_t>(format), pipeline);
    return true;
}

void MetalRender::Impl::shareTargetImages(Scene& scene)
{
    if (! TargetSharingSwitch().load()) return;

    // The span of passes each target is touched in, and whether it can give
    // its image up outside that span. A target qualifies only if nothing
    // before or after the span in a frame expects its pixels: its first touch
    // in a frame is a clear that really happens (a clear step, or a draw that
    // opens with a clear and is not dropped for an input nothing produces),
    // nothing copies into or out of it (which keeps copy elision and texture
    // trades to their own images), and it is not carried into the next frame,
    // pinned by the reuse table, mip-mapped, depth-attached or the output the
    // composition and the posters read.
    struct Span
    {
        std::size_t first { 0 };
        std::size_t last { 0 };
        bool        seen { false };
        bool        shareable { true };
    };
    std::unordered_map<std::string, Span> spans;
    const auto touch = [&spans](const std::string& key, std::size_t index, bool opens_clean) {
        if (key.empty()) return;
        auto& span = spans[key];
        if (! span.seen) {
            span.seen      = true;
            span.first     = index;
            span.shareable = opens_clean;
        }
        span.last = index;
    };
    for (std::size_t i = 0; i < descriptions.size(); ++i) {
        const auto& desc = descriptions[i];
        switch (desc.kind) {
        case MetalPassKind::Copy:
            for (const auto* key : { &desc.source_key, &desc.target_key }) {
                touch(*key, i, false);
                if (! key->empty()) spans[*key].shareable = false;
            }
            break;
        case MetalPassKind::Clear: touch(desc.target_key, i, true); break;
        case MetalPassKind::CustomShader: {
            // Reads come first: a draw samples before it writes.
            for (const auto& key : desc.texture_keys) touch(key, i, false);
            const bool clears = desc.load_action == MetalLoadAction::Clear &&
                                (i >= prepared.size() || ! prepared[i].unproduced_input);
            touch(desc.target_key, i, clears);
            break;
        }
        case MetalPassKind::Virtual:
        case MetalPassKind::Unsupported: break;
        }
    }

    const auto output = scene.ResolveRenderTargetName(SpecTex_Default);
    struct Candidate
    {
        std::string key;
        Span        span;
    };
    std::vector<Candidate> candidates;
    for (const auto& [key, span] : spans) {
        if (! span.shareable || key == output) continue;
        if (owned_targets.count(key) == 0 || target_aliases.count(key) != 0) continue;
        if (pinned_target_keys.count(key) != 0 || depth_targets.count(key) != 0) continue;
        const auto texture = targets.find(key);
        if (texture == targets.end() || texture->second == nil ||
            texture->second.mipmapLevelCount != 1) {
            continue;
        }
        const auto* target = scene.FindRenderTarget(key);
        if (target == nullptr || target->carriesPreviousFrame) continue;
        candidates.push_back({ key, span });
    }
    // Earliest first, so each target takes the first image of its shape that
    // is free by then: the interval colouring that uses fewest images.
    std::sort(candidates.begin(), candidates.end(), [](const Candidate& a, const Candidate& b) {
        return a.span.first != b.span.first ? a.span.first < b.span.first : a.key < b.key;
    });
    struct Image
    {
        id<MTLTexture> texture { nil };
        std::size_t    free_after { 0 };
    };
    std::vector<Image> images;
    for (const auto& candidate : candidates) {
        id<MTLTexture> own = targets.at(candidate.key);
        Image*         reuse = nullptr;
        for (auto& image : images) {
            if (image.free_after >= candidate.span.first) continue;
            if (image.texture.width != own.width || image.texture.height != own.height ||
                image.texture.pixelFormat != own.pixelFormat || image.texture.usage != own.usage) {
                continue;
            }
            reuse = &image;
            break;
        }
        if (reuse == nullptr) {
            images.push_back({ own, candidate.span.last });
            continue;
        }
        // The target's own image is released with this assignment; the one it
        // takes over was cleared at compile like every other and is cleared
        // again by this target's first draw each frame.
        targets[candidate.key] = reuse->texture;
        reuse->free_after      = candidate.span.last;
    }
}

void MetalRender::Impl::planPooledTrades(Scene& scene)
{
    pooled_trades.clear();
    pooled_copy_at.assign(descriptions.size(), { -1, -1 });
    pooled_release_at.assign(descriptions.size() + 1, {});
    if (! TargetSharingSwitch().load()) return;

    // Every traded copy, grouped by the source it copies.
    std::map<std::string, std::vector<std::size_t>> by_source;
    for (std::size_t i = 0; i < feedback_swaps.size(); ++i) {
        if (feedback_swaps[i].valid) by_source[feedback_swaps[i].source_key].push_back(i);
    }
    const auto reads = [](const ScenePassDescription& desc, const std::string& key) {
        if (desc.kind == MetalPassKind::Copy) return desc.source_key == key;
        return std::find(desc.texture_keys.begin(), desc.texture_keys.end(), key) !=
               desc.texture_keys.end();
    };

    for (auto& [source, copies] : by_source) {
        const auto source_found = targets.find(source);
        if (source_found == targets.end() || source_found->second == nil) continue;
        // Each copy has to be the only writer of its name, be read only by
        // later draws, and hold nothing a later frame reads. Otherwise the
        // source keeps its ordinary trades.
        std::vector<std::pair<std::size_t, std::size_t>> spans; // copy index, last reader
        bool qualifies = true;
        for (const auto i : copies) {
            const auto& key = feedback_swaps[i].copy_key;
            const auto* target = scene.FindRenderTarget(key);
            if (target == nullptr || target->carriesPreviousFrame ||
                feedback_swaps[i].copy_passes != std::vector<std::size_t> { i } ||
                pinned_target_keys.count(key) != 0) {
                qualifies = false;
                break;
            }
            std::size_t last = i;
            for (std::size_t j = 0; j < descriptions.size() && qualifies; ++j) {
                if (j == i || ! reads(descriptions[j], key)) continue;
                if (j < i || descriptions[j].kind != MetalPassKind::CustomShader) qualifies = false;
                last = std::max(last, j);
            }
            if (! qualifies) break;
            spans.emplace_back(i, last);
        }
        if (! qualifies) continue;

        // The most copies alive at once, simulated in pass order: a copy takes
        // an image when it runs and gives one back after its last reader.
        std::size_t live = 0, most = 0;
        for (std::size_t j = 0; j < descriptions.size(); ++j) {
            for (const auto& [copy, last] : spans) {
                if (last + 1 == j) --live;
            }
            for (const auto& [copy, last] : spans) {
                if (copy == j) most = std::max(most, ++live);
            }
        }

        PooledTrade group;
        group.source_key    = source;
        group.source_slot   = &source_found->second;
        group.source_passes = feedback_swaps[copies.front()].source_passes;
        group.images.push_back(source_found->second);
        const int index = static_cast<int>(pooled_trades.size());
        for (std::size_t k = 0; k < copies.size(); ++k) {
            const auto  i     = copies[k];
            const auto& key   = feedback_swaps[i].copy_key;
            auto        found = targets.find(key);
            // The first `most` copies' own images become the set; the rest are
            // released. Every copy name starts on one of the set's images,
            // which it holds no pixels of until it runs.
            if (group.images.size() < most + 1) group.images.push_back(found->second);
            found->second = group.images.back();
            owned_targets.erase(key);
            group.copies.push_back({ i, key, &found->second });
            pooled_copy_at[i] = { index, static_cast<int>(k) };
            pooled_release_at[spans[k].second + 1].emplace_back(index, static_cast<int>(k));
        }
        pooled_trades.push_back(std::move(group));
    }
}

void MetalRender::Impl::releasePooledTrades()
{
    for (auto& group : pooled_trades) {
        for (auto& copy : group.copies) {
            // Removed from the names this renderer owns when it was pooled, so
            // the reallocation that follows gives it a fresh, cleared image.
            targets.erase(copy.key);
        }
    }
    pooled_trades.clear();
}

void MetalRender::Impl::beginPooledTrades()
{
    pooled_snapshot.clear();
    pooled_moves = 0;
    for (auto& group : pooled_trades) {
        pooled_snapshot.emplace_back(group.source_slot, *group.source_slot);
        group.free.clear();
        for (id<MTLTexture> image : group.images) {
            if (image != *group.source_slot) group.free.push_back(image);
        }
        for (auto& copy : group.copies) pooled_snapshot.emplace_back(copy.slot, *copy.slot);
    }
}

void MetalRender::Impl::abandonPooledTrades(Scene& scene)
{
    for (auto& [slot, texture] : pooled_snapshot) *slot = texture;
    pooled_snapshot.clear();
    if (! pooled_trades.empty()) refreshPassTargets(scene);
}

void MetalRender::Impl::planFeedbackSwaps()
{
    feedback_swaps.assign(descriptions.size(), FeedbackSwap {});
    frame_swaps.clear();
    opening_copies.clear();
    // Part of the copy plan, and switched with it: with scene optimisation off,
    // every copy the graph asks for is made as a copy.
    if (! vulkan::SceneOptimizationEnabled() || FeedbackCopiesForcedByEnvironment()) {
        return;
    }

    // A texture another name shares -- through an elided copy -- would carry
    // that name along with the trade.
    std::unordered_map<const void*, uint32_t> names_per_texture;
    for (const auto& [key, texture] : targets) {
        (void)key;
        if (texture != nil) ++names_per_texture[(__bridge const void*)texture];
    }
    const auto exclusive = [&](const std::string& key) -> id<MTLTexture> {
        const auto found = targets.find(key);
        if (found == targets.end() || found->second == nil) return nil;
        return names_per_texture[(__bridge const void*)found->second] == 1 ? found->second : nil;
    };
    const auto reads = [](const ScenePassDescription& desc, const std::string& key) {
        if (desc.kind == MetalPassKind::Copy) return desc.source_key == key;
        return std::find(desc.texture_keys.begin(), desc.texture_keys.end(), key) !=
               desc.texture_keys.end();
    };
    const auto uses_depth = [this](const std::vector<std::size_t>& passes) {
        return std::any_of(passes.begin(), passes.end(), [this](std::size_t k) {
            return k < pass_depths.size() && pass_depths[k] != nil;
        });
    };

    for (std::size_t i = 0; i < descriptions.size(); ++i) {
        const auto& copy = descriptions[i];
        if (copy.kind != MetalPassKind::Copy || copy.source_key == copy.target_key) continue;
        if (i < copy_elision.size() && copy_elision[i] != vulkan::CopyElision::None) continue;
        id<MTLTexture> source      = exclusive(copy.source_key);
        id<MTLTexture> destination = exclusive(copy.target_key);
        if (source == nil || destination == nil) continue;
        if (source.width != destination.width || source.height != destination.height ||
            source.pixelFormat != destination.pixelFormat || source.mipmapLevelCount != 1 ||
            destination.mipmapLevelCount != 1) {
            continue;
        }
        if (! ensureSceneCopyPipeline(destination.pixelFormat)) continue;

        // The next pass to touch the source has to be the one that draws into
        // it without reading it, and nothing before it may write the copy.
        std::size_t reader = descriptions.size();
        for (std::size_t j = i + 1; j < descriptions.size(); ++j) {
            const auto& next = descriptions[j];
            if (next.target_key == copy.target_key) break;
            const bool writes = next.target_key == copy.source_key;
            const bool read   = reads(next, copy.source_key);
            if (! writes && ! read) continue;
            if (writes && ! read) reader = j;
            break;
        }
        if (reader == descriptions.size()) continue;
        const auto& draw = descriptions[reader];
        if (draw.kind != MetalPassKind::CustomShader ||
            draw.load_action == MetalLoadAction::DontCare) {
            continue;
        }
        // An image the reuse table keeps across frames keeps its texture too.
        if (static_cache.PassSampled(i) || static_cache.PassSampled(reader)) continue;
        if (reader < pass_reads_own_target.size() && pass_reads_own_target[reader] != 0) continue;

        FeedbackSwap swap;
        for (std::size_t k = 0; k < descriptions.size(); ++k) {
            if (descriptions[k].target_key == copy.source_key) swap.source_passes.push_back(k);
            if (descriptions[k].target_key == copy.target_key) swap.copy_passes.push_back(k);
        }
        // The copy that opens the reader's render pass is built for a colour
        // attachment alone.
        if (uses_depth(swap.source_passes) || uses_depth(swap.copy_passes)) continue;
        swap.valid        = true;
        swap.reader       = reader;
        swap.prefix       = draw.load_action == MetalLoadAction::Load;
        swap.source_key   = copy.source_key;
        swap.copy_key     = copy.target_key;
        feedback_swaps[i] = std::move(swap);
    }
}

bool MetalRender::Impl::feedbackReaderRenders(std::size_t index) const
{
    const auto reader = feedback_swaps[index].reader;
    if (reader < static_skip.size() && static_skip[reader] != 0) return false;
    return passDraws(reader) || passClears(reader);
}

bool MetalRender::Impl::passClears(std::size_t index) const
{
    if (descriptions[index].load_action != MetalLoadAction::Clear) return false;
    return index >= prepared.size() || ! prepared[index].unproduced_input;
}

void MetalRender::Impl::tradeFeedbackTextures(std::size_t index)
{
    const auto& swap   = feedback_swaps[index];
    const auto  source = targets.find(swap.source_key);
    const auto  copy   = targets.find(swap.copy_key);
    if (source == targets.end() || copy == targets.end()) return;
    std::swap(source->second, copy->second);
    for (const auto k : swap.source_passes) pass_targets[k] = source->second;
    for (const auto k : swap.copy_passes) pass_targets[k] = copy->second;
    if (swap.source_key == scene_output_key) scene_output_target = source->second;
    if (swap.copy_key == scene_output_key) scene_output_target = copy->second;
}

id<MTLDepthStencilState> MetalRender::Impl::depthStencilFor(bool test, bool write)
{
    if (! test) return nil;
    const uint32_t key = (test ? 1u : 0u) | (write ? 2u : 0u);
    if (auto found = depth_stencil_states.find(key); found != depth_stencil_states.end()) {
        return found->second;
    }
    MTLDepthStencilDescriptor* descriptor = [MTLDepthStencilDescriptor new];
    descriptor.depthCompareFunction       = MTLCompareFunctionLessEqual;
    descriptor.depthWriteEnabled          = write ? YES : NO;
    id<MTLDepthStencilState> state = [device newDepthStencilStateWithDescriptor:descriptor];
    if (state != nil) depth_stencil_states.emplace(key, state);
    return state;
}

/// Zeroes every freshly allocated target once, at compile time.
///
/// A private Metal texture's initial contents are undefined. A scene may read a
/// target the graph never writes -- an effect input the author left empty -- and
/// without this that read would sample whatever the driver last left in that
/// memory, which is neither black nor the same twice.
bool MetalRender::Impl::clearTargetsOnce()
{
    id<MTLCommandBuffer> command = [queue commandBuffer];
    if (command == nil) return fail("a Metal command buffer could not be created");
    std::unordered_set<const void*> cleared;
    for (const auto& [name, texture] : targets) {
        (void)name;
        // Two keys may now name one texture. Clearing it twice is harmless but
        // pointless, and skipping the duplicate keeps the count honest.
        if (! cleared.insert((__bridge const void*)texture).second) continue;
        MTLRenderPassDescriptor* descriptor = [MTLRenderPassDescriptor renderPassDescriptor];
        descriptor.colorAttachments[0].texture     = texture;
        descriptor.colorAttachments[0].loadAction  = MTLLoadActionClear;
        descriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
        descriptor.colorAttachments[0].clearColor  = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);
        id<MTLRenderCommandEncoder> encoder =
            [command renderCommandEncoderWithDescriptor:descriptor];
        if (encoder == nil) return fail("a render target could not be cleared");
        [encoder endEncoding];
    }
    [command commit];
    // Compile time, never the frame path: the first frame must not race the
    // clear of the targets it reads.
    [command waitUntilCompleted];
    return true;
}

bool MetalRender::Impl::prepareDraw(Scene& scene, std::size_t index, PreparedPass& out)
{
    const auto& desc = descriptions[index];
    auto*       mesh = desc.node->Mesh();
    if (mesh == nullptr) return fail("a draw step lost its mesh");
    if (desc.submesh_index >= mesh->Submeshes().size()) {
        return fail("a draw step names a submesh that does not exist");
    }
    const auto& submesh  = mesh->Submeshes()[desc.submesh_index];
    const auto* material = mesh->MaterialForSlot(desc.material_slot);
    if (material == nullptr || material->customShader.shader == nullptr) {
        return fail("a draw step lost its material");
    }
    // Held, not borrowed: the optional variant of this same program may be
    // collected from it many frames from now, and nothing else keeps it alive
    // for that long.
    out.program         = material->customShader.shader->metal_program;
    const auto* program = out.program.get();
    if (program == nullptr || ! program->ok()) {
        return fail("a shader could not be translated to Metal");
    }
    out.variant_build = VariantBuild::Idle;
    out.video_planes  = VideoPlaneDraw {};

    std::string reflection_error;
    if (! ParseMetalShaderReflection(program->reflection_json, out.reflection, &reflection_error)) {
        return fail(reflection_error);
    }

    // ---- resource slots, matched on the original GLSL names.
    out.samplers.assign(desc.texture_keys.size(), nil);
    const auto* uniform_block = out.reflection.uniformBlock();
    out.uniform_size          = uniform_block != nullptr ? uniform_block->size : 0;
    MetalResourcePlan plan;
    if (auto plan_error = BuildMetalResourcePlan(program->stages, uniform_block,
                                                 desc.texture_keys.size(),
                                                 out.reflection.active_texture_slots, plan);
        ! plan_error.empty()) {
        // Named, because "which shader" is the whole diagnosis for an author.
        return fail(plan_error + " (" + material->name + ")");
    }
    if (plan.has_chroma) {
        return fail("a shader binds a video plane the ordinary program has no use for");
    }
    out.texture_slots        = std::move(plan.texture_slots);
    out.vertex_uniform_slot  = plan.vertex_uniform_slot;
    out.fragment_uniform_slot = plan.fragment_uniform_slot;

    // ---- sprite sheets
    // The same rule `SceneToRenderGraph`'s `CheckAndSetSprite` applies: a
    // material slot naming a sheet gets its own copy of the animation, so two
    // layers sharing one sheet keep independent playback. Render targets and
    // special textures are never sheets.
    out.sprites.clear();
    for (std::size_t i = 0; i < desc.texture_keys.size(); ++i) {
        const auto& key = desc.texture_keys[i];
        if (key.empty() || IsSpecTex(key)) continue;
        const auto found = scene.textures.find(key);
        if (found == scene.textures.end() || ! found->second.isSprite) continue;
        if (found->second.spriteAnim.numFrames() == 0) continue;
        out.sprites[i] = found->second.spriteAnim;
    }

    // ---- textures
    const auto missing_image = [&](std::size_t slot) {
        std::string message = "an image a layer needs could not be loaded: slot " +
                              std::to_string(slot) + " (" + material->name + ")";
        if (! desc.texture_keys[slot].empty()) message += ": " + desc.texture_keys[slot];
        return fail(std::move(message));
    };
    out.unproduced_input = false;
    for (std::size_t i = 0; i < desc.texture_keys.size(); ++i) {
        if (! out.texture_slots[i].bound()) continue;
        // No name at all is not an image that failed to load here: nothing in
        // the scene was going to produce it, on either renderer. A name that
        // does not load is still a whole-scene fallback below.
        if (desc.texture_keys[i].empty()) {
            if (! out.unproduced_input) {
                LOG_INFO("metal render: %s samples slot %zu, which nothing in the scene produces; "
                         "the step is skipped as on the compatibility renderer",
                         material->name.c_str(), i);
            }
            out.unproduced_input = true;
            continue;
        }
        id<MTLSamplerState> sampler = nil;
        id<MTLTexture> texture = resolveTexture(scene, desc.texture_keys[i], &sampler);
        // A video texture has no frame yet at compile time, which is not a
        // missing image: the first `beginFrame` produces one.
        if (texture == nil && ! video.owns(desc.texture_keys[i])) {
            return missing_image(i);
        }
        out.samplers[i] = sampler;
        // A sheet spread over several images must have every one of them, or a
        // frame would silently fall back to the first sheet mid-animation.
        const auto sprite = out.sprites.find(i);
        if (sprite == out.sprites.end()) continue;
        const auto imported = images.find(desc.texture_keys[i]);
        std::size_t needed = 1;
        for (std::size_t frame = 0; frame < sprite->second.numFrames(); ++frame) {
            const auto image_id = sprite->second.FrameAt(frame).imageId;
            if (image_id >= 0) needed = std::max(needed, static_cast<std::size_t>(image_id) + 1);
        }
        if (imported == images.end() || imported->second.size() < needed) {
            return fail("a sprite sheet is missing one of its images: " + desc.texture_keys[i]);
        }
    }

    // ---- vertex layout
    MTLVertexDescriptor* vertex_descriptor = [MTLVertexDescriptor new];
    uint64_t             layout_id         = 0xcbf29ce484222325ULL;
    out.vertex_buffers.clear();
    out.vertex_buffer_slots.clear();
    out.vertex_count = 0;
    if (submesh.VertexCount() == 0) return fail("a draw step has no vertices");
    if (submesh.VertexCount() > kVertexBufferTopIndex) {
        return fail("a draw step needs more vertex buffers than Metal can bind");
    }

    out.dynamic_mesh = mesh->Dynamic();
    out.dynamic_vertex_rings.clear();
    out.dynamic_vertex_strides.clear();
    out.dynamic_vertex_capacities.clear();
    out.dynamic_vertex_attributes.clear();
    out.dynamic_index_ring.clear();
    out.dynamic_uploaded_generation.assign(out.dynamic_mesh ? kFramesInFlight : 0, 0);

    std::vector<Map<std::string, SceneVertexArray::SceneVertexAttributeOffset>> attribute_maps;
    attribute_maps.reserve(submesh.VertexCount());
    for (std::size_t i = 0; i < submesh.VertexCount(); ++i) {
        const auto&     vertex = submesh.GetVertexArray(i);
        const NSUInteger slot  = kVertexBufferTopIndex - i;
        attribute_maps.push_back(vertex.GetAttrOffsetMap());

        if (out.dynamic_mesh) {
            // Capacity, not the current size: a particle mesh is empty until
            // the first emission, and the storage has to be the one the
            // simulation's maximum needs from then on.
            const std::size_t capacity = vertex.CapacitySizeOf();
            if (capacity == 0) return fail("a draw step has an empty vertex buffer");
            std::vector<id<MTLBuffer>> ring;
            ring.reserve(kFramesInFlight);
            for (NSUInteger f = 0; f < kFramesInFlight; ++f) {
                id<MTLBuffer> buffer = [device newBufferWithLength:capacity
                                                           options:MTLResourceStorageModeShared];
                if (buffer == nil) return fail("a vertex buffer could not be allocated");
                ring.push_back(buffer);
            }
            out.dynamic_vertex_rings.push_back(std::move(ring));
            out.dynamic_vertex_strides.push_back(vertex.OneSizeOf());
            out.dynamic_vertex_capacities.push_back(capacity);
            out.dynamic_vertex_attributes.push_back(vertex.Attributes());
            out.vertex_buffer_slots.push_back(slot);
        } else {
            if (vertex.DataSizeOf() == 0) return fail("a draw step has an empty vertex buffer");
            id<MTLBuffer> buffer = [device newBufferWithBytes:vertex.Data()
                                                       length:vertex.DataSizeOf()
                                                      options:MTLResourceStorageModeShared];
            if (buffer == nil) return fail("a vertex buffer could not be allocated");
            out.vertex_buffers.push_back(buffer);
            out.vertex_buffer_slots.push_back(slot);
            out.vertex_count += static_cast<uint32_t>(vertex.DataSize() / vertex.OneSize());
        }

        vertex_descriptor.layouts[slot].stride       = vertex.OneSizeOf();
        vertex_descriptor.layouts[slot].stepFunction = MTLVertexStepFunctionPerVertex;
        vertex_descriptor.layouts[slot].stepRate     = 1;
        layout_id = layout_id * 1099511628211ULL + vertex.OneSizeOf();
    }

    for (const auto& input : out.reflection.inputs) {
        const auto format = ToMetalVertexFormat(input.format);
        if (format == MTLVertexFormatInvalid) {
            return fail("a shader uses a vertex format the native renderer does not recognise: " +
                        input.format);
        }
        // The buffer that actually carries this attribute, falling back to the
        // first one exactly as the compatibility backend does when a shader
        // declares an input the mesh does not provide.
        std::size_t source   = 0;
        std::size_t offset   = 0;
        bool        provided = false;
        for (std::size_t i = 0; i < attribute_maps.size(); ++i) {
            const auto found = attribute_maps[i].find(input.name);
            if (found == attribute_maps[i].end()) continue;
            source   = i;
            offset   = found->second.offset;
            provided = true;
            break;
        }
        // The fallback below is tolerable for an input a shader never really
        // uses. Bone indices are not that: read from whatever sits at offset
        // zero they index the bone array with a position's bit pattern.
        if (! provided && (input.name == WE_IN_BLENDINDICES || input.name == WE_IN_BLENDWEIGHTS)) {
            return fail("a puppet shader is bound to a mesh without bone weights");
        }
        vertex_descriptor.attributes[input.location].format      = format;
        vertex_descriptor.attributes[input.location].offset      = offset;
        vertex_descriptor.attributes[input.location].bufferIndex =
            out.vertex_buffer_slots[source];
        layout_id = layout_id * 1099511628211ULL + (input.location * 31 + offset);
    }

    // A resource slot that collides with a vertex buffer slot would silently
    // overwrite one with the other.
    for (const auto slot : out.vertex_buffer_slots) {
        if (out.vertex_uniform_slot >= 0 &&
            static_cast<NSUInteger>(out.vertex_uniform_slot) == slot) {
            return fail("a shader binds a uniform block where a vertex buffer has to go");
        }
    }

    // ---- indices
    if (submesh.IndexCount() > 0) {
        const auto& indices = submesh.GetIndexArray(0);
        out.index_type         = indices.Width() == SceneIndexWidth::UInt32 ? MTLIndexTypeUInt32
                                                                           : MTLIndexTypeUInt16;
        out.index_element_size = indices.ElementSize();
        // Packed 16-bit indices occupy a 32-bit array; 32-bit indices occupy
        // one slot each. DrawIndexCount() is the number of indices to draw.
        if (out.dynamic_mesh) {
            out.dynamic_index_capacity = indices.CapacitySizeof();
            if (out.dynamic_index_capacity == 0) {
                return fail("a draw step has an empty index buffer");
            }
            out.dynamic_index_ring.reserve(kFramesInFlight);
            for (NSUInteger f = 0; f < kFramesInFlight; ++f) {
                id<MTLBuffer> buffer =
                    [device newBufferWithLength:out.dynamic_index_capacity
                                        options:MTLResourceStorageModeShared];
                if (buffer == nil) return fail("an index buffer could not be allocated");
                out.dynamic_index_ring.push_back(buffer);
            }
            // Filled per frame from the simulation's own render count; zero
            // live particles is a frame that draws nothing, not a failure.
            out.index_count = 0;
        } else {
            const uint64_t count = indices.DrawIndexCount();
            const uint64_t bytes = indices.DrawIndexBytes();
            if (count > std::numeric_limits<uint32_t>::max()) {
                return fail("an index buffer is larger than a draw can address");
            }
            if (count > 0 && bytes == 0) {
                return fail("index byte capacity overflowed");
            }
            out.index_count = static_cast<uint32_t>(count);
            out.draw_ranges = submesh.DrawRanges();
            if (out.index_count > 0) {
                out.index_buffer = [device newBufferWithBytes:indices.Data()
                                                        length:static_cast<NSUInteger>(bytes)
                                                       options:MTLResourceStorageModeShared];
                if (out.index_buffer == nil) return fail("an index buffer could not be allocated");
            }
        }
    } else if (out.dynamic_mesh) {
        // A text layer's card carries no index stream: four corners drawn as a
        // triangle strip, exactly like the immutable card meshes below. The
        // count is re-read from the uploaded array every frame, because a
        // relayout rewrites the corners in place.
        out.vertex_count = static_cast<uint32_t>(submesh.GetVertexArray(0).VertexCount());
    }

    // ---- pipeline
    const auto  target = targets.find(desc.target_key);
    if (target == targets.end()) return fail("a draw step targets an image that does not exist");

    MetalPipelineKey key {
        .program_id       = ProgramContentId(program->stages),
        .vertex_layout_id = layout_id,
        .blend            = ToMetalBlendState(desc.blend),
        .color_format     = static_cast<MetalPixelFormat>(target->second.pixelFormat),
        .depth_format     = desc.depth_test ? MetalPixelFormat::Depth32Float
                                            : MetalPixelFormat::Invalid,
        .depth_compare    = desc.depth_test ? MetalDepthCompare::LessEqual
                                            : MetalDepthCompare::Never,
        .sample_count     = 1,
        .write_alpha      = desc.write_alpha,
        .depth_test       = desc.depth_test,
        .depth_write      = desc.depth_write,
    };
    out.pipeline = pipelineFor(key, program->stages, vertex_descriptor);
    if (out.pipeline == nil) return fail(last_error.empty() ? "a shader pipeline could not be "
                                                             "created"
                                                            : last_error);
    out.depth_test     = desc.depth_test;
    out.depth_write    = desc.depth_write;
    out.depth_stencil  = depthStencilFor(desc.depth_test, desc.depth_write);
    if (desc.depth_test && out.depth_stencil == nil) {
        return fail("a depth-stencil state could not be created");
    }
    if (desc.depth_test && depth_targets.find(desc.target_key) == depth_targets.end()) {
        return fail("a depth-tested pass has no depth attachment");
    }
    // Kept for the optional variant, which is built later against the identical
    // vertex layout. The descriptor is finished at this point and nothing
    // mutates it afterwards.
    out.vertex_descriptor = vertex_descriptor;
    out.vertex_layout_id  = layout_id;

    // ---- uniform initial state
    auto* updater = scene.shaderValueUpdater.get();
    if (updater != nullptr) {
        auto exists_op = [&out](std::string_view name) { return out.reflection.hasMember(name); };
        updater->InitUniforms(desc.node, desc.material_slot, exists_op);
    }
    return true;
}

bool MetalRender::Impl::installVideoPlaneDraw(Scene& scene, std::size_t index, PreparedPass& out,
                                              const SceneMetalVideoPlaneVariant& variant,
                                              id<MTLRenderPipelineState> pipeline)
{
    out.video_planes = VideoPlaneDraw {};
    if (pipeline == nil) return false;

    const auto& desc = descriptions[index];
    const auto  slot = static_cast<std::size_t>(variant.slot);
    // Everything below refuses rather than substitutes: a variant that does not
    // line up with this pass leaves the material converting, which is what it
    // did before the variant existed.
    const auto refuse = [&](const std::string& reason) {
        LOG_INFO("metal video plane variant unused for pass %zu: %s", index, reason.c_str());
        out.video_planes = VideoPlaneDraw {};
        return false;
    };

    if (slot >= desc.texture_keys.size() || desc.texture_keys[slot].empty()) {
        return refuse("the variant names a texture slot this pass does not bind");
    }
    if (! video.owns(desc.texture_keys[slot])) {
        return refuse("the slot the variant samples is not a video this backend plays");
    }

    VideoPlaneDraw draw;
    draw.slot = slot;
    std::string reflection_error;
    if (! ParseMetalShaderReflection(variant.reflection_json, draw.reflection,
                                     &reflection_error)) {
        return refuse(reflection_error);
    }
    const auto* uniform_block = draw.reflection.uniformBlock();
    draw.uniform_size         = uniform_block != nullptr ? uniform_block->size : 0;

    MetalResourcePlan plan;
    if (auto plan_error = BuildMetalResourcePlan(variant.stages, uniform_block,
                                                 desc.texture_keys.size(),
                                                 draw.reflection.active_texture_slots, plan);
        ! plan_error.empty()) {
        return refuse(plan_error);
    }
    if (! plan.has_chroma || plan.chroma_slot != slot) {
        return refuse("the variant declares no chroma plane for the slot it was built for");
    }
    if (! plan.texture_slots[slot].bound()) {
        return refuse("the variant does not bind the luma plane");
    }
    draw.texture_slots         = std::move(plan.texture_slots);
    draw.chroma                = plan.chroma;
    draw.vertex_uniform_slot   = plan.vertex_uniform_slot;
    draw.fragment_uniform_slot = plan.fragment_uniform_slot;

    // The colour constants are written per frame from the decoded frame's own
    // colorimetry, so a variant whose block does not carry them would sample
    // planes and convert them with zeroes.
    draw.range_uniform  = VideoRangeUniformName(slot);
    draw.matrix_uniform = VideoMatrixUniformName(slot);
    draw.uv_transform_uniform = "_we_VideoUvTransform" + std::to_string(slot);
    draw.uv_offset_uniform = "_we_VideoUvOffset" + std::to_string(slot);
    if (! draw.reflection.hasMember(draw.range_uniform) ||
        ! draw.reflection.hasMember(draw.matrix_uniform) ||
        ! draw.reflection.hasMember(draw.uv_transform_uniform) ||
        ! draw.reflection.hasMember(draw.uv_offset_uniform)) {
        return refuse("the variant carries incomplete colour or display constants for the plane it samples");
    }

    const auto texture = scene.textures.find(desc.texture_keys[slot]);
    draw.chroma_sampler =
        chromaSamplerFor(texture != scene.textures.end() ? texture->second.sample
                                                         : TextureSample {});
    if (draw.chroma_sampler == nil) {
        return refuse("a chroma sampler could not be created");
    }

    // Its own uniform storage, one buffer per in-flight frame, allocated now
    // because only now is the variant's block size known.
    if (draw.uniform_size > 0) {
        draw.uniform_ring.reserve(kFramesInFlight);
        for (NSUInteger f = 0; f < kFramesInFlight; ++f) {
            id<MTLBuffer> buffer = [device newBufferWithLength:draw.uniform_size
                                                       options:MTLResourceStorageModeShared];
            if (buffer == nil) return refuse("the variant's uniform storage could not be created");
            draw.uniform_ring.push_back(buffer);
        }
    }

    draw.pipeline    = pipeline;
    draw.ready       = true;
    out.video_planes = std::move(draw);
    return true;
}

void MetalRender::Impl::pumpVideoPlaneVariants(Scene& scene, bool planes_enabled)
{
    // ---- results that arrived since the last frame
    std::vector<VariantPipelineMailbox::Entry> arrived;
    if (variant_mailbox != nullptr) {
        const std::lock_guard lock { variant_mailbox->mutex };
        arrived.swap(variant_mailbox->ready);
    }
    for (auto& entry : arrived) {
        if (entry.generation != graph_generation) continue;
        if (entry.description_index >= prepared.size()) continue;
        auto& pass = prepared[entry.description_index];
        if (pass.variant_build != VariantBuild::Building) continue;
        const auto variant = pass.program != nullptr ? pass.program->videoPlanes() : nullptr;
        if (entry.pipeline == nil || variant == nullptr || ! variant->ok()) {
            if (! entry.error.empty()) {
                LOG_INFO("metal video plane variant pipeline not built: %s", entry.error.c_str());
            }
            pass.variant_build = VariantBuild::Refused;
            continue;
        }
        // Adopted at a frame boundary, before anything in this frame is
        // encoded, so the switch happens between frames and never inside one.
        pass.variant_build = installVideoPlaneDraw(scene, entry.description_index, pass, *variant,
                                                   entry.pipeline)
                                 ? VariantBuild::Ready
                                 : VariantBuild::Refused;
    }

    // ---- builds worth starting now
    //
    // Nothing at all while the feature is off: an optional pipeline that
    // nothing would select is pure cost, and creating it anyway is exactly the
    // "it is already compiled, so it is free" mistake.
    if (! planes_enabled) return;

    for (std::size_t i = 0; i < prepared.size() && i < descriptions.size(); ++i) {
        auto& pass = prepared[i];
        if (pass.kind != MetalPassKind::CustomShader) continue;
        if (pass.variant_build != VariantBuild::Idle) continue;
        if (pass.program == nullptr || ! pass.program->hasVideoPlaneCandidate()) continue;

        switch (pass.program->videoPlaneState()) {
        case SceneMetalVariantState::None:
        case SceneMetalVariantState::Pending:
            // The translation is not here yet. Asking again next frame costs a
            // comparison; the wallpaper is drawing meanwhile.
            continue;
        case SceneMetalVariantState::Failed:
            // Remembered, so the same hopeless variant is not reconsidered on
            // every frame for the life of this scene.
            pass.variant_build = VariantBuild::Refused;
            continue;
        case SceneMetalVariantState::Ready: break;
        }

        const auto variant = pass.program->videoPlanes();
        if (variant == nullptr || ! variant->ok()) {
            pass.variant_build = VariantBuild::Refused;
            continue;
        }
        const auto& desc = descriptions[i];
        const auto  slot = static_cast<std::size_t>(variant->slot);
        if (slot >= desc.texture_keys.size() || desc.texture_keys[slot].empty() ||
            ! video.owns(desc.texture_keys[slot])) {
            pass.variant_build = VariantBuild::Refused;
            continue;
        }
        const auto target = targets.find(desc.target_key);
        if (target == targets.end() || pass.vertex_descriptor == nil) {
            pass.variant_build = VariantBuild::Refused;
            continue;
        }

        const MetalPipelineKey key {
            .program_id       = ProgramContentId(variant->stages),
            .vertex_layout_id = pass.vertex_layout_id,
            .blend            = ToMetalBlendState(desc.blend),
            .color_format     = static_cast<MetalPixelFormat>(target->second.pixelFormat),
            .depth_format     = desc.depth_test ? MetalPixelFormat::Depth32Float
                                                : MetalPixelFormat::Invalid,
            .depth_compare    = desc.depth_test ? MetalDepthCompare::LessEqual
                                                : MetalDepthCompare::Never,
            .sample_count     = 1,
            .write_alpha      = desc.write_alpha,
            .depth_test       = desc.depth_test,
            .depth_write      = desc.depth_write,
        };

        if (variant_queue == nullptr) {
            dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(
                DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
            variant_queue = dispatch_queue_create("owe.metal.optional-variant", attributes);
        }
        if (variant_queue == nullptr) {
            pass.variant_build = VariantBuild::Refused;
            continue;
        }

        pass.variant_build = VariantBuild::Building;
        // Everything the build reads is copied here, on this thread: the queue
        // touches no scene, no graph and no renderer state, and posts one
        // finished pipeline into a box the next frame boundary reads.
        auto                 mailbox    = variant_mailbox;
        const auto           generation = graph_generation;
        const auto           index      = i;
        id<MTLDevice>        build_device      = device;
        MTLVertexDescriptor* build_descriptor  = pass.vertex_descriptor;
        auto                 stages            = variant->stages;
        const std::string    archive_root      = pipeline_archive_root;
        dispatch_async(variant_queue, ^{
            std::string                error;
            id<MTLRenderPipelineState> pipeline = MetalProgramCache::shared().pipelineFor(
                build_device, key, stages, build_descriptor, archive_root, &error);
            if (mailbox == nullptr) return;
            const std::lock_guard lock { mailbox->mutex };
            mailbox->ready.push_back(VariantPipelineMailbox::Entry {
                .description_index = index,
                .generation        = generation,
                .pipeline          = pipeline,
                .error             = std::move(error),
            });
        });
    }
}

void MetalRender::Impl::updateVideoDemand(bool planes_enabled)
{
    video_planes_applied = planes_enabled;
    if (video.empty()) {
        video.setDemand({});
        return;
    }
    // Accumulated over every consumer of every key: one conversion serves all
    // the consumers that need an image, and no conversion is encoded when none
    // of them does.
    std::map<std::string, VideoConsumerDemand> demand;
    for (std::size_t i = 0; i < descriptions.size() && i < prepared.size(); ++i) {
        const auto& desc = descriptions[i];
        if (desc.kind != MetalPassKind::CustomShader) continue;
        const auto& pass = prepared[i];
        for (std::size_t t = 0; t < desc.texture_keys.size(); ++t) {
            const auto& key = desc.texture_keys[t];
            if (key.empty() || ! video.owns(key)) continue;
            const bool direct =
                planes_enabled && pass.video_planes.ready && pass.video_planes.slot == t;
            auto [entry, inserted] = demand.try_emplace(key, VideoConsumerDemand { false, false });
            (void)inserted;
            if (direct) {
                entry->second.planes = true;
            } else {
                entry->second.rgb = true;
            }
        }
    }
    video.setDemand(std::move(demand));
}

void MetalRender::Impl::selectVideoPlaneDraws(bool planes_enabled)
{
    video_plane_active.assign(prepared.size(), uint8_t { 0 });
    if (! planes_enabled || video.empty()) return;
    for (std::size_t i = 0; i < prepared.size() && i < descriptions.size(); ++i) {
        const auto& pass = prepared[i];
        if (! pass.video_planes.ready) continue;
        const auto& desc = descriptions[i];
        if (pass.video_planes.slot >= desc.texture_keys.size()) continue;
        // The frame the decoder actually produced decides, every frame: the
        // same file is BGRA under software decode and NV12 under VideoToolbox,
        // and either can take over without the scene being reparsed.
        if (! video.planes(desc.texture_keys[pass.video_planes.slot]).valid()) continue;
        video_plane_active[i] = 1;
    }
}

bool MetalRender::Impl::uploadDynamicMesh(PreparedPass& pass, const ScenePassDescription& desc,
                                         std::string* error)
{
    const auto set_error = [error](std::string message) {
        if (error != nullptr) *error = std::move(message);
        return false;
    };
    if (desc.node == nullptr) return set_error("a draw step lost its node");
    auto* mesh = desc.node->Mesh();
    if (mesh == nullptr) return set_error("a draw step lost its mesh");
    if (desc.submesh_index >= mesh->Submeshes().size()) {
        return set_error("a draw step names a submesh that does not exist");
    }
    auto& submesh = mesh->Submeshes()[desc.submesh_index];
    // Indexed or not is a property of the shape prepared, so both have to still
    // agree: a mesh that grew or lost an index stream would otherwise be
    // reinterpreted against storage built for the other shape.
    if (submesh.VertexCount() != pass.dynamic_vertex_rings.size() ||
        (submesh.IndexCount() == 0) != pass.dynamic_index_ring.empty()) {
        return set_error("a dynamic mesh changed its binding shape after preparation");
    }

    const std::size_t slot = static_cast<std::size_t>(frame_slot) % kFramesInFlight;
    // The draw count comes from the simulation every frame. When the revision
    // already in this slot's storage is the current one, nothing is copied and
    // the count read here still describes exactly those bytes.
    const bool indexed = ! pass.dynamic_index_ring.empty();
    if (indexed) {
        const auto& indices = submesh.GetIndexArray(0);
        if (indices.Width() != (pass.index_type == MTLIndexTypeUInt32 ? SceneIndexWidth::UInt32
                                                                      : SceneIndexWidth::UInt16)) {
            return set_error("a dynamic mesh changed its index width after preparation");
        }
        const uint64_t count = indices.DrawIndexCount();
        const uint64_t bytes = indices.DrawIndexBytes();
        if (count > std::numeric_limits<uint32_t>::max() || (count > 0 && bytes == 0)) {
            return set_error("a dynamic mesh's index count is not addressable");
        }
        pass.index_count = static_cast<uint32_t>(count);
        pass.draw_ranges = submesh.DrawRanges();
    } else {
        pass.vertex_count = static_cast<uint32_t>(submesh.GetVertexArray(0).VertexCount());
    }

    const uint64_t generation = mesh->DirtyGeneration();
    if (slot < pass.dynamic_uploaded_generation.size() &&
        pass.dynamic_uploaded_generation[slot] == generation && generation != 0) {
        return true;
    }

    for (std::size_t i = 0; i < submesh.VertexCount(); ++i) {
        const auto& vertex = submesh.GetVertexArray(i);
        if (vertex.OneSizeOf() != pass.dynamic_vertex_strides[i] ||
            vertex.DataSizeOf() > pass.dynamic_vertex_capacities[i]) {
            return set_error("a dynamic mesh outgrew the storage prepared for it");
        }
        const auto& attributes = vertex.Attributes();
        if (! std::equal(attributes.begin(), attributes.end(),
                         pass.dynamic_vertex_attributes[i].begin(),
                         pass.dynamic_vertex_attributes[i].end(),
                         [](const auto& a, const auto& b) {
                             return a.name == b.name && a.type == b.type && a.padding == b.padding;
                         })) {
            return set_error("a dynamic mesh changed its vertex layout after preparation");
        }
        if (vertex.DataSizeOf() == 0) continue;
        std::memcpy(pass.dynamic_vertex_rings[i][slot].contents, vertex.Data(),
                    vertex.DataSizeOf());
    }

    if (indexed) {
        const auto&       live_indices = submesh.GetIndexArray(0);
        const std::size_t index_bytes  = live_indices.DrawIndexBytes();
        if (index_bytes > pass.dynamic_index_capacity) {
            return set_error("a dynamic mesh outgrew the index storage prepared for it");
        }
        if (pass.index_count > 0 && index_bytes == 0) {
            return set_error("a dynamic mesh's index byte capacity overflowed");
        }
        if (index_bytes > 0) {
            std::memcpy(pass.dynamic_index_ring[slot].contents, live_indices.Data(), index_bytes);
        }
    }
    if (slot < pass.dynamic_uploaded_generation.size()) {
        pass.dynamic_uploaded_generation[slot] = generation;
    }
    return true;
}

void MetalRender::Impl::writeUniforms(Scene& scene, const ScenePassDescription& desc,
                                      PreparedPass& pass,
                                      const MetalShaderReflection& reflection, bool planes_active,
                                      uint8_t* destination)
{
    const auto* block = reflection.uniformBlock();
    if (block == nullptr || destination == nullptr) return;

    auto&       writes = planes_active ? pass.video_planes.uniform_writes : pass.uniform_writes;
    std::size_t cursor = 0;
    const auto  write  = [&](std::string_view name, const ShaderValue& value) {
        if (cursor == writes.size()) writes.emplace_back();
        auto& slot = writes[cursor++];
        if (slot.name != name) {
            const auto* found = reflection.member(name);
            slot.name         = name;
            slot.present      = found != nullptr;
            slot.member       = found != nullptr ? *found : MetalUniformMember {};
            slot.bones        = name == G_BONES;
            slot.fold         = FoldsOnLeft(name) ? 1 : FoldsOnRight(name) ? 2 : 0;
        }
        if (! slot.present) return;
        const auto* member = &slot.member;

        // The fold is applied to every matrix that carries clip space, so a
        // change to either API's convention is honoured rather than ignored.
        std::array<float, 16> folded {};
        const float*          data  = value.data();
        std::size_t           count = value.size();
        if (count == 16 && slot.fold != 0) {
            Eigen::Matrix4f matrix = Eigen::Map<const Eigen::Matrix4f>(value.data());
            const Eigen::Matrix4f fold = MetalClipSpaceFold().cast<float>();
            matrix = slot.fold == 1 ? (fold * matrix).eval() : (matrix * fold).eval();
            std::memcpy(folded.data(), matrix.data(), sizeof(folded));
            data = folded.data();
        }

        const std::size_t bytes = count * sizeof(float);
        // A pose is one 4x4 matrix per bone, written element by element through
        // the reflected stride. A pose of a different length than the shader's
        // `g_Bones[N]`, or a stride it does not fit, has no correct placement:
        // the contiguous copy below would spill into whatever follows the
        // array, and drawing a truncated skeleton is not a fallback.
        if (slot.bones) {
            const std::size_t bone_bytes = 16 * sizeof(float);
            if (member->array_count == 0 || member->array_stride < bone_bytes ||
                bytes != member->array_count * bone_bytes) {
                if (uniform_error.empty()) {
                    uniform_error = "a puppet's bone count does not match its shader";
                }
                return;
            }
        }
        if (member->array_count > 0 && member->array_stride > 0 &&
            bytes % member->array_count == 0) {
            const std::size_t element_size = bytes / member->array_count;
            if (element_size > 0 && element_size <= member->array_stride) {
                for (std::size_t i = 0; i < member->array_count; ++i) {
                    const std::size_t at = member->offset + i * member->array_stride;
                    if (at + element_size > block->size) return;
                    std::memcpy(destination + at,
                                reinterpret_cast<const uint8_t*>(data) + i * element_size,
                                element_size);
                }
                return;
            }
        }
        const std::size_t copy = std::min<std::size_t>(bytes, block->size - member->offset);
        if (member->offset >= block->size) return;
        std::memcpy(destination + member->offset, data, copy);
    };

    auto* material = desc.node != nullptr && desc.node->Mesh() != nullptr
                         ? desc.node->Mesh()->MaterialForSlot(desc.material_slot)
                         : nullptr;
    if (material == nullptr) return;

    // Defaults first, then the author's constants, then this frame's values, so
    // a value that is both defaulted and animated ends up animated.
    if (material->customShader.shader != nullptr) {
        for (const auto& [name, value] : material->customShader.shader->default_uniforms) {
            write(name, value);
        }
    }
    for (const auto& [name, value] : material->customShader.constValues) write(name, value);

    // Before the value updater is consulted, because a scene without one still
    // must not sample planes through zeroed constants. Read from the frame the
    // decoder produced rather than from anything assumed: the same eight
    // numbers the pre-converted path's kernel is given, so the two cannot
    // disagree about range or matrix.
    if (planes_active && pass.video_planes.ready) {
        const auto planes = video.planes(desc.texture_keys[pass.video_planes.slot]);
        if (planes.valid()) {
            const std::array<float, 4> range {
                planes.params.y_offset,
                planes.params.y_scale,
                planes.params.chroma_offset,
                planes.params.chroma_scale,
            };
            const std::array<float, 4> matrix {
                planes.params.r_cr,
                planes.params.g_cb,
                planes.params.g_cr,
                planes.params.b_cb,
            };
            write(pass.video_planes.range_uniform,
                  ShaderValue(std::span<const float>(range.data(), range.size())));
            write(pass.video_planes.matrix_uniform,
                  ShaderValue(std::span<const float>(matrix.data(), matrix.size())));
            const auto& uv_transform = planes.display_transform.matrix;
            const auto& uv_offset = planes.display_transform.offset;
            write(pass.video_planes.uv_transform_uniform, ShaderValue(std::span<const float>(uv_transform)));
            write(pass.video_planes.uv_offset_uniform, ShaderValue(std::span<const float>(uv_offset)));
        }
    }

    auto* updater = scene.shaderValueUpdater.get();
    if (updater == nullptr) return;

    std::string original_camera;
    bool        restore_camera = false;
    if (! desc.camera_override.empty() && desc.node->Camera() != desc.camera_override) {
        original_camera = desc.node->Camera();
        desc.node->SetCamera(desc.camera_override);
        restore_camera = true;
    }
    updater->UpdateUniforms(desc.node, desc.material_slot, pass.sprites, std::cref(write));
    if (restore_camera) desc.node->SetCamera(original_camera);

    // Last, so it overrides the parser's constant. The shared value updater
    // reports render-target sizes; a video slot's real size is the decoded
    // frame's, and a shader that taps neighbours at the placeholder's step
    // would sample the wrong texels. Read from the frame rather than from a
    // texture, because on the direct path there is no single colour image to
    // ask.
    for (std::size_t i = 0;
         i < desc.texture_keys.size() && i < WE_GLTEX_RESOLUTION_NAMES.size(); ++i) {
        const auto& key = desc.texture_keys[i];
        if (key.empty() || ! video.owns(key)) continue;
        uint32_t width  = 0;
        uint32_t height = 0;
        if (! video.frameSize(key, &width, &height)) continue;
        const std::array<float, 4> resolution {
            static_cast<float>(width), static_cast<float>(height),
            static_cast<float>(width), static_cast<float>(height),
        };
        write(WE_GLTEX_RESOLUTION_NAMES[i],
              ShaderValue(std::span<const float>(resolution.data(), resolution.size())));
        if (width > 0 && height > 0) {
            const std::array<float, 4> texel {
                1.0f / static_cast<float>(width), 1.0f / static_cast<float>(height),
                static_cast<float>(width), static_cast<float>(height),
            };
            write(WE_GLTEX_TEXEL_NAMES[i],
                  ShaderValue(std::span<const float>(texel.data(), texel.size())));
        }
    }

}

void MetalRender::Impl::computeDemandReasons(Scene& scene, rg::RenderGraph& graph)
{
    (void)graph;
    // Derived from this backend's OWN pass descriptions, not from the render
    // graph's Vulkan pass objects. The Metal path never instantiates those, so
    // walking the graph found nothing, concluded nothing was dynamic, and
    // reported a provably-still scene — which would let on-demand updating stop
    // the clock on an animating wallpaper. An empty answer is the dangerous
    // answer here, so every path that cannot account for a pass adds
    // `UnknownInput` instead of contributing silence.
    uint32_t reasons              = 0;
    bool     saw_shader_pass      = false;
    bool     understood_every_pass = true;

    const auto* updater       = scene.shaderValueUpdater.get();
    const auto* runtime_images =
        dynamic_cast<const RuntimeImageSource*>(scene.imageParser.get());

    for (std::size_t index = 0; index < descriptions.size(); ++index) {
        const auto& desc = descriptions[index];
        switch (desc.kind) {
        case MetalPassKind::CustomShader: {
            saw_shader_pass = true;
            // Reflection captured at InitUniforms, never a search of shader
            // text. A material with no updater reports every kind, so an
            // untracked pass cannot look still by omission.
            const uint32_t varying =
                updater != nullptr
                    ? updater->FrameVaryingUniforms(desc.node, desc.material_slot,
                                                    desc.camera_override)
                    : frame_varying_uniform::kAll;
            if ((varying & (frame_varying_uniform::kTime | frame_varying_uniform::kDayTime)) != 0)
                reasons |= vulkan::DynamicReason::TimeUniform;
            if ((varying & frame_varying_uniform::kAudio) != 0)
                reasons |= vulkan::DynamicReason::AudioUniform;
            if ((varying & (frame_varying_uniform::kPointer | frame_varying_uniform::kParallax)) !=
                0)
                reasons |= vulkan::DynamicReason::PointerUniform;
            if ((varying & frame_varying_uniform::kBones) != 0)
                reasons |= vulkan::DynamicReason::BoneUniform;

            if (runtime_images != nullptr) {
                for (const auto& texture : desc.texture_keys) {
                    if (texture.empty()) continue;
                    if (runtime_images->IsRuntimeImage(texture)) {
                        reasons |= vulkan::DynamicReason::RuntimeImage;
                        break;
                    }
                }
            }
            if (std::any_of(desc.cover_keys.begin(), desc.cover_keys.end(),
                            [](const std::string& cover) { return ! cover.empty(); })) {
                reasons |= vulkan::DynamicReason::RuntimeImage;
            }
            // A sheet with more than one frame and a mesh the runtime rewrites
            // both change the picture without any uniform this reflection
            // names. Reported here so on-demand updating keeps the clock
            // running for them -- the reuse cache answers a different question
            // about the same two inputs and is not driven by this.
            if (index < prepared.size()) {
                for (const auto& [slot, sprite] : prepared[index].sprites) {
                    (void)slot;
                    if (sprite.numFrames() > 1) {
                        reasons |= vulkan::DynamicReason::AnimatedSprite;
                        break;
                    }
                }
            }
            if (desc.node != nullptr && desc.node->Mesh() != nullptr &&
                desc.node->Mesh()->Dynamic()) {
                reasons |= desc.node->Mesh()->UpdatesOnEvent()
                               ? vulkan::DynamicReason::EventMesh
                               : vulkan::DynamicReason::DynamicMesh;
            }
            break;
        }
        case MetalPassKind::Copy:
        case MetalPassKind::Clear:
        case MetalPassKind::Virtual: break;
        case MetalPassKind::Unsupported: understood_every_pass = false; break;
        }
    }

    // A target the frame reads before it writes it hands each frame's result
    // to the next: a trail keeps fading and an accumulation keeps converging
    // with nothing else changing, so the clock has to keep running for it.
    for (const auto& [name, target] : scene.renderTargets) {
        if (target.carriesPreviousFrame && targets.contains(name)) {
            reasons |= vulkan::DynamicReason::Feedback;
            break;
        }
    }

    // A compiled graph that yielded no shader pass is not a still scene; it is
    // a graph this analysis did not understand.
    if (! saw_shader_pass || ! understood_every_pass) {
        reasons |= vulkan::DynamicReason::UnknownInput;
    }
    demand_reasons = reasons;
}

/// Decides which copies this backend can reduce, using the compatibility
/// backend's rule rather than a second one.
///
/// The rule is not relaxed for Metal: a copy that resamples, that generates the
/// destination's mip chain, or whose destination anything else writes or reads
/// first, still runs. Round 8 turned unequal copies into real resampling passes,
/// and `copy_compatible` is exactly what keeps those out of the alias case --
/// a name is never what decides.
void MetalRender::Impl::planCopyElision(Scene& scene)
{
    copy_elision.assign(descriptions.size(), vulkan::CopyElision::None);
    target_aliases.clear();
    elided_copies = 0;
    if (! vulkan::SceneOptimizationEnabled()) return;

    const auto mip_levels = [&scene](const std::string& key) -> uint32_t {
        const auto* target = scene.FindRenderTarget(key);
        return target != nullptr ? std::max<uint32_t>(1, target->mipmap_level) : 1u;
    };

    std::vector<vulkan::ElisionPassDesc> elision;
    elision.reserve(descriptions.size() + 1);
    for (const auto& desc : descriptions) {
        vulkan::ElisionPassDesc entry;
        switch (desc.kind) {
        case MetalPassKind::Copy: {
            entry.kind   = vulkan::ElisionPassDesc::Kind::Copy;
            entry.writes = desc.target_key;
            entry.reads  = { desc.source_key };
            const auto* source = scene.FindRenderTarget(desc.source_key);
            const auto* target = scene.FindRenderTarget(desc.target_key);
            entry.copy_compatible = desc.source_width == desc.target_width &&
                                    desc.source_height == desc.target_height &&
                                    mip_levels(desc.source_key) == mip_levels(desc.target_key) &&
                                    source != nullptr && target != nullptr &&
                                    source->format == target->format;
            entry.copy_generates_mipmaps = desc.generate_mipmaps;
            break;
        }
        case MetalPassKind::Clear:
            entry.kind   = vulkan::ElisionPassDesc::Kind::Clear;
            entry.writes = desc.target_key;
            break;
        case MetalPassKind::CustomShader:
            entry.kind   = vulkan::ElisionPassDesc::Kind::Custom;
            entry.writes = desc.target_key;
            for (const auto& key : desc.texture_keys) {
                if (! key.empty()) entry.reads.push_back(key);
            }
            break;
        case MetalPassKind::Virtual:
        case MetalPassKind::Unsupported: entry.kind = vulkan::ElisionPassDesc::Kind::Custom; break;
        }
        elision.push_back(std::move(entry));
    }
    // The composition draw, and the poster that re-composes from the same
    // image, both read the scene's output. Without this entry a scene whose
    // last step is a copy into the output would look like a copy nobody wants.
    elision.push_back(vulkan::ElisionPassDesc {
        .kind  = vulkan::ElisionPassDesc::Kind::Present,
        .reads = { scene.ResolveRenderTargetName(SpecTex_Default) },
    });

    const auto plan = vulkan::PlanCopyElision(elision);
    for (std::size_t i = 0; i < descriptions.size() && i < plan.size(); ++i) {
        if (descriptions[i].kind != MetalPassKind::Copy) continue;
        if (plan[i] == vulkan::CopyElision::None) continue;
        copy_elision[i] = plan[i];
        ++elided_copies;
        if (plan[i] == vulkan::CopyElision::Alias) {
            target_aliases[descriptions[i].target_key] = descriptions[i].source_key;
        }
    }
    vulkan::RecordElidedCopies(elided_copies);
}

/// Builds the target table this backend reuses pixels from.
///
/// Called after the targets exist, because "may be reused" also depends on the
/// texture actually being one this renderer keeps: nothing here is pooled, and
/// an aliased destination shares its source's image, so pinning is the budget
/// decision alone.
/// Resolves an alias chain to the key that is not itself an alias.
///
/// The walk is bounded by the number of aliases, so a cycle the planner could
/// never produce still cannot hang a frame.
static std::string ResolveAliasRoot(const std::unordered_map<std::string, std::string>& aliases,
                                    const std::string&                                  key)
{
    std::string root = key;
    for (std::size_t step = 0; step <= aliases.size(); ++step) {
        const auto next = aliases.find(root);
        if (next == aliases.end()) break;
        root = next->second;
    }
    return root;
}

bool MetalRender::Impl::applySceneOptimizationSetting(Scene& scene, id<MTLCommandBuffer> command)
{
    const bool enabled = vulkan::SceneOptimizationEnabled();
    if (enabled == optimization_applied) return true;
    // Targets are reallocated and cleared in this frame's own command buffer,
    // so the frame after a change always composes and presents.
    present_gate.Invalidate();
    if (! graph_ready) {
        optimization_applied = enabled;
        return true;
    }

    // The whole plan, not just the flag: the copy plan decides which targets
    // exist at all, so turning the setting back on with only `enabled = true`
    // would leave elided copies unexecuted and aliased images unallocated.
    releasePooledTrades();
    releaseSceneOptimization();
    planCopyElision(scene);

    // Targets first. A destination the plan has just folded onto its source
    // gives up its own image; one the plan no longer folds gets a fresh image
    // and starts from a defined state rather than from whatever the driver
    // last left there.
    std::vector<id<MTLTexture>> cleared;
    const auto required = ReferencedRenderTargets(scene, descriptions);
    for (const auto& [name, target] : scene.renderTargets) {
        if (! required.contains(name)) continue;
        if (target.width <= 0 || target.height <= 0) continue;
        if (target_aliases.count(name) != 0) {
            const auto root  = ResolveAliasRoot(target_aliases, target_aliases.at(name));
            const auto found = targets.find(root);
            if (found == targets.end()) continue;
            targets[name] = found->second;
            owned_targets.erase(name);
            continue;
        }
        if (owned_targets.count(name) != 0 && targets.count(name) != 0) continue;

        id<MTLTexture> texture = newSceneTarget(name, target);
        if (texture == nil) return fail("a render target could not be reallocated");
        targets[name] = texture;
        owned_targets.insert(name);
        cleared.push_back(texture);
    }

    // Encoded into this frame's own command buffer, ahead of every pass in it.
    // Nothing waits on the GPU for a setting change.
    for (id<MTLTexture> texture : cleared) {
        MTLRenderPassDescriptor* descriptor = [MTLRenderPassDescriptor renderPassDescriptor];
        descriptor.colorAttachments[0].texture     = texture;
        descriptor.colorAttachments[0].loadAction  = MTLLoadActionClear;
        descriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
        descriptor.colorAttachments[0].clearColor  = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);
        id<MTLRenderCommandEncoder> encoder =
            [command renderCommandEncoderWithDescriptor:descriptor];
        if (encoder == nil) return fail("a reallocated render target could not be cleared");
        [encoder endEncoding];
    }

    // Last, because reuse is decided over the targets that now exist. A fresh
    // table has rendered nothing, so the first frame after the change redraws
    // everything instead of trusting pixels an earlier plan produced.
    if (! prepareDepthTargets()) return false;
    refreshPassTargets(scene);
    compileStaticCache(scene);
    planFeedbackSwaps();
    planPooledTrades(scene);
    refreshPassTargets(scene);
    optimization_applied = enabled;
    return true;
}

void MetalRender::Impl::compileStaticCache(Scene& scene)
{
    static_cache.Reset();
    static_samples.clear();
    static_skip.assign(descriptions.size(), uint8_t { 0 });
    // Given back rather than forgotten: this runs again whenever the setting
    // changes, and a total that is only ever zeroed here would count the same
    // pixels into the process-wide budget once per change.
    if (static_pinned_bytes != 0) {
        vulkan::AdjustSceneOptimizationPinnedBytes(-static_cast<int64_t>(static_pinned_bytes));
        static_pinned_bytes = 0;
    }
    optimization_compiled = false;
    if (! vulkan::SceneOptimizationEnabled()) return;

    const auto* updater = scene.shaderValueUpdater.get();
    const auto* runtime_images =
        dynamic_cast<const RuntimeImageSource*>(scene.imageParser.get());

    std::vector<vulkan::StaticPassDesc> descs;
    descs.reserve(descriptions.size());
    for (std::size_t i = 0; i < descriptions.size(); ++i) {
        const auto& desc = descriptions[i];
        vulkan::StaticPassDesc out;
        switch (desc.kind) {
        case MetalPassKind::Copy:
            // An elided copy executes nothing, so it is neither a writer of its
            // destination nor a reason for it to be redrawn.
            if (copy_elision[i] == vulkan::CopyElision::None) {
                out.target = desc.target_key;
                out.inputs = { vulkan::ResolveCopyAliasKey(target_aliases, desc.source_key) };
            }
            break;
        case MetalPassKind::Clear:
            // A clear is a writer like any other. Reusing a target while still
            // clearing it every frame is exactly how the pixels would be lost.
            out.target = desc.target_key;
            break;
        case MetalPassKind::CustomShader: {
            out.target = desc.target_key;
            for (const auto& key : desc.texture_keys) {
                if (key.empty()) continue;
                // Through the alias, never the name: a destination the copy
                // plan folded onto its source has no writer of its own, and a
                // read of the bare name would look like a read of something
                // nothing in this frame produces.
                out.inputs.push_back(vulkan::ResolveCopyAliasKey(target_aliases, key));
            }
            uint32_t reasons = 0;
            const uint32_t varying =
                updater != nullptr
                    ? updater->FrameVaryingUniforms(desc.node, desc.material_slot,
                                                    desc.camera_override)
                    : frame_varying_uniform::kAll;
            if ((varying & (frame_varying_uniform::kTime | frame_varying_uniform::kDayTime)) != 0)
                reasons |= vulkan::DynamicReason::TimeUniform;
            if ((varying & frame_varying_uniform::kAudio) != 0)
                reasons |= vulkan::DynamicReason::AudioUniform;
            if ((varying & (frame_varying_uniform::kPointer | frame_varying_uniform::kParallax)) !=
                0)
                reasons |= vulkan::DynamicReason::PointerUniform;
            if ((varying & frame_varying_uniform::kBones) != 0)
                reasons |= vulkan::DynamicReason::BoneUniform;
            for (const auto& key : desc.texture_keys) {
                if (key.empty()) continue;
                if (video.owns(key)) reasons |= vulkan::DynamicReason::VideoInput;
                if (runtime_images != nullptr && runtime_images->IsRuntimeImage(key))
                    reasons |= vulkan::DynamicReason::RuntimeImage;
            }
            // A cover bound over a render target changes the picture whenever
            // a track brings one, though the target alone may be still.
            if (std::any_of(desc.cover_keys.begin(), desc.cover_keys.end(),
                            [](const std::string& cover) { return ! cover.empty(); })) {
                reasons |= vulkan::DynamicReason::RuntimeImage;
            }
            // A mesh the runtime rewrites every frame -- a particle system --
            // is never reusable. Its geometry is uploaded per frame and the
            // upload happens only for a pass that executes, so a skipped one
            // would draw last frame's vertices out of a buffer nobody filled.
            if (desc.node != nullptr && desc.node->Mesh() != nullptr &&
                desc.node->Mesh()->Dynamic()) {
                // Either bit costs this target its cacheability, which is the
                // only thing the reuse cache asks. Telling them apart matters
                // one level up, where the scene decides whether to keep the
                // clock.
                reasons |= desc.node->Mesh()->UpdatesOnEvent()
                               ? vulkan::DynamicReason::EventMesh
                               : vulkan::DynamicReason::DynamicMesh;
            }
            // Sprite sheets are deliberately absent: the frame this pass draws
            // is folded into its per-frame sample below, taken after the sprite
            // clock has advanced, so a sheet that is between frame changes is
            // reused and a sheet that changed frame is redrawn. The clock keeps
            // running either way, which is what stops a sprite scene from being
            // declared still.
            out.dynamic_reasons = reasons;
            break;
        }
        case MetalPassKind::Virtual: break;
        case MetalPassKind::Unsupported:
            // Not reachable: an unsupported pass fails the graph rejection. If
            // it ever were, it must not be reusable.
            out.dynamic_reasons = static_cast<uint32_t>(vulkan::DynamicReason::UnknownInput);
            break;
        }
        descs.push_back(std::move(out));
    }

    static_cache.Compile(descs);
    static_samples.assign(descriptions.size(), vulkan::StaticPassSample {});

    pinned_target_keys.clear();
    std::unordered_map<const void*, uint32_t> keys_per_image;
    for (const auto& [key, texture] : targets) {
        (void)key;
        if (texture != nil) ++keys_per_image[(__bridge const void*)texture];
    }
    for (std::size_t i = 0; i < static_cache.TargetCount(); ++i) {
        if (! static_cache.TargetCacheable(i)) continue;
        const auto& key   = static_cache.TargetKey(i);
        const auto  found = targets.find(key);
        if (found == targets.end()) continue;
        // A shared image is redrawn by another target every frame, so the
        // pixels this one would keep are not there to keep.
        if (found->second == nil || keys_per_image[(__bridge const void*)found->second] > 1) {
            continue;
        }
        const auto* target = scene.FindRenderTarget(key);
        if (target == nullptr || target->width <= 0 || target->height <= 0) continue;
        uint64_t bytes = static_cast<uint64_t>(target->width) *
                         static_cast<uint64_t>(target->height) *
                         (target->format == TextureFormat::RGBA16F ? 8ULL : 4ULL);
        if (found->second.mipmapLevelCount > 1) bytes += bytes / 3ULL;
        if (bytes == 0) continue;
        // Over budget the target simply re-renders; the frame is never blocked
        // and nothing grows without a bound.
        if (static_pinned_bytes + bytes > kStaticCacheBudgetBytes) continue;
        static_cache.SetTargetPinned(i, true, bytes);
        static_pinned_bytes += bytes;
        pinned_target_keys.insert(key);
    }
    if (static_pinned_bytes != 0) {
        vulkan::AdjustSceneOptimizationPinnedBytes(static_cast<int64_t>(static_pinned_bytes));
    }
    optimization_compiled = true;
}

vulkan::StaticPassSample MetalRender::Impl::frameSample(Scene& scene, std::size_t index) const
{
    vulkan::StaticPassSample sample;
    const auto&              desc = descriptions[index];
    if (desc.kind != MetalPassKind::CustomShader) {
        if (desc.uses_scene_clear_color) {
            sample.hash = vulkan::StaticHashBytes(0xcbf29ce484222325ULL,
                desc.clear_color.data(), sizeof(float) * desc.clear_color.size());
        }
        return sample;
    }
    sample.visible = desc.visibility_node == nullptr ||
                    desc.visibility_node->EffectiveVisible() ||
                    (desc.visibility_node->MustProduce() && ! desc.target_key.empty() &&
                     desc.target_key != wallpaper::SpecTex_Default);

    uint64_t hash = 0xcbf29ce484222325ULL;
    if (desc.uses_scene_clear_color) {
        hash = vulkan::StaticHashBytes(hash, desc.clear_color.data(), sizeof(float) * desc.clear_color.size());
    }
    if (desc.node != nullptr) {
        // Idempotent, and the transform has to be current before it is
        // compared: a parent moved by a script updates lazily.
        desc.node->UpdateTrans();
        const auto model = desc.node->ModelTrans();
        hash = vulkan::StaticHashBytes(hash, model.data(), sizeof(double) * 16);
        // Where the node is drawn, when that is not where its world matrix puts it: a
        // layer a screen anchor shifts, or a final card drawn through an override that
        // carries the shift.
        if (desc.node->HasRenderTransformOverride() || ! desc.node->DrawOffset().isZero()) {
            const auto drawn = desc.node->RenderTrans();
            hash = vulkan::StaticHashBytes(hash, drawn.data(), sizeof(double) * 16);
        }
        if (auto* mesh = desc.node->Mesh(); mesh != nullptr) {
            hash = vulkan::StaticHashMix(hash, mesh->DirtyGeneration());
            if (const auto* material = mesh->MaterialForSlot(desc.material_slot);
                material != nullptr) {
                for (const auto& [name, value] : material->customShader.constValues) {
                    hash = vulkan::StaticHashBytes(hash, name.data(), name.size());
                    hash = vulkan::StaticHashBytes(hash, value.data(),
                                                   value.size() * sizeof(float));
                }
            }
        }
        // Lights move, fade and switch without touching this node or material.
        if (const auto* updater = scene.shaderValueUpdater.get(); updater != nullptr) {
            hash = vulkan::StaticHashMix(hash,
                                         updater->LightStateHash(desc.node, desc.material_slot));
        }
    }

    hash = vulkan::FoldPassCameras(hash, scene, desc.camera_override, desc.node);

    // What a replaceable image currently holds. Its geometry can be unchanged
    // while its pixels are not -- a clock redrawing the same number of glyphs,
    // a media thumbnail replaced by one of the same size -- and a target whose
    // only moving input is that image would otherwise be called unchanged and
    // keep showing the previous picture.
    if (! runtime_image_rings.empty()) {
        const auto fold = [&](const std::string& key) {
            if (key.empty()) return;
            const auto ring = runtime_image_rings.find(key);
            if (ring == runtime_image_rings.end()) return;
            hash = vulkan::StaticHashBytes(hash, key.data(), key.size());
            hash = vulkan::StaticHashMix(hash, ring->second.version);
        };
        for (const auto& key : desc.texture_keys) fold(key);
        for (const auto& key : desc.cover_keys) fold(key);
    }

    // The sprite frame as it will actually be sampled, not its index: two
    // frames of one sheet differ by their rectangle and axes, and that is
    // exactly what reaches the shader.
    for (const auto& [slot, sprite] : prepared[index].sprites) {
        hash = vulkan::StaticHashMix(hash, static_cast<uint64_t>(slot));
        if (sprite.numFrames() == 0) continue;
        const auto& frame = sprite.GetCurFrame();
        hash = vulkan::StaticHashMix(hash, static_cast<uint64_t>(frame.imageId));
        const std::array<float, 9> rect { frame.x,        frame.y,        frame.width,
                                          frame.height,   frame.rate,     frame.xAxis[0],
                                          frame.xAxis[1], frame.yAxis[0], frame.yAxis[1] };
        hash = vulkan::StaticHashBytes(hash, rect.data(), rect.size() * sizeof(float));
    }

    hash = vulkan::StaticHashMix(hash, desc.target_width);
    hash = vulkan::StaticHashMix(hash, desc.target_height);
    sample.hash = hash;
    return sample;
}

bool MetalRender::Impl::planStaticSkips(Scene& scene)
{
    if (static_skip.size() != descriptions.size()) {
        static_skip.assign(descriptions.size(), uint8_t { 0 });
    }
    std::fill(static_skip.begin(), static_skip.end(), uint8_t { 0 });
    if (! optimization_compiled || ! vulkan::SceneOptimizationEnabled() ||
        static_cache.TargetCount() == 0) {
        // Dropped, not merely unused. While reuse is off every target is
        // redrawn from whatever this frame's inputs are, and the table still
        // holds the signature that was current when it was switched off. If a
        // later frame's inputs happen to match that one -- a layer moved away
        // and back, a script writing a value it wrote before -- switching reuse
        // back on would call the target unchanged although the pixels behind it
        // came from a frame with different inputs.
        static_cache.InvalidateAll();
        return false;
    }
    // Reuse needs a target that is both cacheable and pinned, and nothing is
    // pinned when no target is cacheable or none fitted the budget at this
    // size. `Plan` can then only answer "execute every pass", and sampling and
    // hashing every pass to arrive there is work with no reachable result.
    if (static_pinned_bytes == 0) {
        static_cache.InvalidateAll();
        uint64_t executed = 0;
        for (const auto& desc : descriptions) {
            if (desc.kind != MetalPassKind::Virtual) ++executed;
        }
        vulkan::RecordSceneOptimizationFrame(executed, 0);
        return false;
    }
    if (static_samples.size() != descriptions.size()) {
        static_samples.assign(descriptions.size(), vulkan::StaticPassSample {});
    }
    // Only the writers of a cacheable target fold into a signature; the rest
    // execute whatever their sample would say.
    for (std::size_t i = 0; i < descriptions.size(); ++i) {
        static_samples[i] =
            static_cache.PassSampled(i) ? frameSample(scene, i) : vulkan::StaticPassSample {};
    }
    static_cache.Plan(static_samples, static_skip);

    uint64_t skipped  = 0;
    uint64_t executed = 0;
    for (std::size_t i = 0; i < descriptions.size(); ++i) {
        if (descriptions[i].kind == MetalPassKind::Virtual) continue;
        if (static_skip[i] != 0)
            ++skipped;
        else
            ++executed;
    }
    vulkan::RecordSceneOptimizationFrame(executed, skipped);
    return skipped != 0;
}

bool MetalRender::Impl::compile(Scene& scene, rg::RenderGraph& graph)
{
    releaseGraph();
    // The videos a rebuild set aside and this graph does not take back are the
    // ones it no longer uses: closed with the compile, however it ends.
    AUTO_DELETER(held_videos, [this]() { video.closeHeld(); });
    if (scene.imageParser != nullptr) {
        scene.imageParser->SetTextureSurfaceSize(scene.display_sized ? 0 : output_width,
                                                 scene.display_sized ? 0 : output_height);
    }

    if (auto reason = MetalGraphRejection(scene, graph); ! reason.empty()) {
        return fail(std::move(reason));
    }

    resolveTargetSizes(scene);

    // Lowered before the targets are allocated: a copy's destination may be a
    // name only the graph knows, and lowering is what declares it.
    std::string error;
    if (! BuildScenePassDescriptions(scene, graph, descriptions, &error)) {
        return fail(std::move(error));
    }

    // Before the targets are allocated: an aliased copy destination must not
    // get an image of its own, and which copies survive decides what the reuse
    // analysis below sees.
    planCopyElision(scene);

    if (! prepareTargets(scene)) return false;
    if (! prepareDepthTargets()) return false;

    for (std::size_t i = 0; i < descriptions.size(); ++i) {
        if (descriptions[i].kind != MetalPassKind::Copy) continue;
        const auto target = targets.find(descriptions[i].target_key);
        // An elided copy has no image of its own yet still needs its pipeline
        // built here: the setting can be switched back off while the scene
        // runs, and the copy would then execute in a frame that must not stop
        // to compile anything.
        if (target == targets.end()) {
            if (copy_elision[i] != vulkan::CopyElision::None) continue;
            return fail("a copy step targets an image that does not exist");
        }
        if (! ensurePresentPipeline(target->second.pixelFormat)) return false;
    }

    // ---- images the runtime replaces, uploaded once here and refreshed at
    // every frame boundary from then on.
    collectRuntimeImageKeys(scene);
    refreshRuntimeImages(scene);

    // ---- video textures the scene's materials bind
    std::vector<std::string> video_keys;
    for (const auto& desc : descriptions) {
        for (const auto& key : desc.texture_keys) {
            if (key.empty()) continue;
            const auto found = scene.textures.find(key);
            if (found == scene.textures.end() || ! found->second.isVideo) continue;
            if (std::find(video_keys.begin(), video_keys.end(), key) == video_keys.end()) {
                video_keys.push_back(key);
            }
        }
    }
    video.configure(device);
    std::string video_error;
    if (! video.prepare(scene, video_keys, &video_error)) {
        // A video the native path cannot play is a whole-scene fallback, not a
        // layer quietly drawn without it.
        return fail(std::move(video_error));
    }
    video.setCounters(counters);
    video.setPaused(video_paused);
    video.setRate(video_rate);

    prepared.resize(descriptions.size());
    uint32_t uniform_cursor = 0;
    for (std::size_t i = 0; i < descriptions.size(); ++i) {
        auto& pass            = prepared[i];
        pass.kind             = descriptions[i].kind;
        pass.description_index = i;
        if (pass.kind != MetalPassKind::CustomShader) continue;
        if (! prepareDraw(scene, i, pass)) return false;
        // The ordinary program's block, and only that. The optional variant
        // brings its own storage when it arrives, because it arrives after this
        // ring has been cut and the offsets in it are already in use.
        const uint32_t reserved = pass.uniform_size;
        if (reserved > 0) {
            // Metal requires a 256-byte aligned buffer offset for constant
            // buffers on macOS.
            uniform_cursor       = (uniform_cursor + 255u) & ~255u;
            pass.uniform_offset  = uniform_cursor;
            uniform_cursor      += reserved;
        }
    }
    // After the passes are prepared: which ones depth-test is decided there.
    refreshPassTargets(scene);

    uniform_ring_size = std::max<uint32_t>(uniform_cursor, 256u);
    uniform_rings.clear();
    for (NSUInteger i = 0; i < kFramesInFlight; ++i) {
        id<MTLBuffer> buffer = [device newBufferWithLength:uniform_ring_size
                                                   options:MTLResourceStorageModeShared];
        if (buffer == nil) return fail("uniform storage could not be allocated");
        uniform_rings.push_back(buffer);
    }

    if (scene.shaderValueUpdater != nullptr) {
        // The raster extent, not the authored canvas: a half-scale raster has
        // half-scale texels, and a neighbour-tap effect that is told otherwise
        // samples at the wrong step.
        scene.shaderValueUpdater->SetScreenSize(static_cast<int32_t>(raster_width),
                                                static_cast<int32_t>(raster_height));
        scene.shaderValueUpdater->SetTexelSize(1.0f / static_cast<float>(raster_width),
                                               1.0f / static_cast<float>(raster_height));
    }

    computeDemandReasons(scene, graph);
    // After the passes are prepared, because what a video's consumers can use
    // is a property of the variants those passes ended up with.
    updateVideoDemand(MetalVideoPlaneSamplingEnabled());
    // Last: it reads the prepared passes' sprite maps and the allocated
    // targets, so both have to exist before a target can be called reusable.
    compileStaticCache(scene);
    shareTargetImages(scene);
    refreshPassTargets(scene);
    planFeedbackSwaps();
    planPooledTrades(scene);
    refreshPassTargets(scene);
    optimization_applied = vulkan::SceneOptimizationEnabled();
    graph_ready = true;
    last_error.clear();
    return true;
}

WallpaperScalingLayout MetalRender::Impl::scalingLayout(const Scene& scene, uint32_t width,
                                                        uint32_t height) const
{
    const double scale_factor = NormalizeScaleFactor(display_scale_factor);
    const auto   source_extent =
        vulkan::ResolveSceneSourceExtent(scene, { std::max(1u, width), std::max(1u, height) });
    const uint32_t logical_width = std::max(
        1u, static_cast<uint32_t>(std::lround(static_cast<double>(width) / scale_factor)));
    const uint32_t logical_height = std::max(
        1u, static_cast<uint32_t>(std::lround(static_cast<double>(height) / scale_factor)));
    return ComputeWallpaperScalingLayout(scaling_mode, source_extent.width, source_extent.height,
                                         logical_width, logical_height, scale_factor,
                                         scaling_factor, framing.pan_x, framing.pan_y);
}

// ---------------------------------------------------------------------------

MetalRender::MetalRender(): pImpl(std::make_unique<Impl>()) {}
MetalRender::~MetalRender() { destroy(); }

bool MetalRender::init(const MetalRenderInitInfo& info)
{
    @autoreleasepool {
        if (info.metal_layer == nullptr) return pImpl->fail("no Metal layer was provided");
        CAMetalLayer* layer = (__bridge CAMetalLayer*)info.metal_layer;
        if (! [layer isKindOfClass:[CAMetalLayer class]]) {
            return pImpl->fail("the wallpaper window has no Metal layer");
        }

        id<MTLDevice> device = layer.device;
        if (device == nil) {
            device = MTLCreateSystemDefaultDevice();
            if (device == nil) return pImpl->fail("this machine has no Metal device");
            layer.device = device;
        }

        pImpl->device = device;
        pImpl->layer  = layer;
        pImpl->queue  = [device newCommandQueue];
        if (pImpl->queue == nil) return pImpl->fail("a Metal command queue could not be created");

        pImpl->drawable_format = layer.pixelFormat != MTLPixelFormatInvalid
                                     ? layer.pixelFormat
                                     : MTLPixelFormatBGRA8Unorm;
        layer.framebufferOnly  = YES;
        pImpl->output_width    = info.width;
        pImpl->output_height   = info.height;
        pImpl->display_scale_factor = NormalizeScaleFactor(info.display_scale_factor);
        if (pImpl->inflight == nullptr) {
            pImpl->inflight = dispatch_semaphore_create(kFramesInFlight);
        }
        if (! pImpl->buildPresentation()) return false;
        pImpl->poster.configure(device, info.wants_poster, info.poster_ready);
        pImpl->inited = true;
        pImpl->last_error.clear();
        return true;
    }
}

void MetalRender::destroy()
{
    if (pImpl == nullptr) return;
    @autoreleasepool {
        // The only synchronous wait in this class. Destruction has to observe
        // that no frame is still reading the textures about to be released, and
        // there is no later point at which to notice.
        if (pImpl->queue != nil && pImpl->inflight != nullptr && pImpl->inited) {
            id<MTLCommandBuffer> drain = [pImpl->queue commandBuffer];
            [drain commit];
            [drain waitUntilCompleted];
        }
        pImpl->releaseGraph();
        pImpl->video.closeHeld();
        pImpl->releasePresentation();
        pImpl->present_pipelines.clear();
        pImpl->queue  = nil;
        pImpl->device = nil;
        pImpl->inited = false;
    }
}

bool MetalRender::inited() const { return pImpl->inited; }

bool MetalRender::releaseSurface()
{
    @autoreleasepool {
        pImpl->releasePresentation();
        // The compiled graph survives a surface release, so the reuse table
        // would too. Its verdict is about pixels that were composed for the
        // surface just given up; the next surface may differ in size, scale or
        // format, and a stale "unchanged" would show the old one.
        pImpl->static_cache.InvalidateAll();
        pImpl->inited = false;
        return true;
    }
}

bool MetalRender::resetSurface(const MetalRenderInitInfo& info)
{
    // Keeps the compiled graph: only presentation-scoped state is rebuilt.
    const bool had_graph = pImpl->graph_ready;
    @autoreleasepool {
        if (info.metal_layer == nullptr) return pImpl->fail("no Metal layer was provided");
        CAMetalLayer* layer = (__bridge CAMetalLayer*)info.metal_layer;
        if (! [layer isKindOfClass:[CAMetalLayer class]]) {
            return pImpl->fail("the wallpaper window has no Metal layer");
        }
        if (layer.device == nil) layer.device = pImpl->device;
        pImpl->layer           = layer;
        pImpl->drawable_format = layer.pixelFormat != MTLPixelFormatInvalid
                                     ? layer.pixelFormat
                                     : MTLPixelFormatBGRA8Unorm;
        pImpl->output_width         = info.width;
        pImpl->output_height        = info.height;
        pImpl->display_scale_factor = NormalizeScaleFactor(info.display_scale_factor);
        if (! pImpl->buildPresentation()) return false;
        pImpl->poster.configure(pImpl->device, info.wants_poster, info.poster_ready);
        pImpl->static_cache.InvalidateAll();
        pImpl->inited     = true;
        pImpl->graph_ready = had_graph;
        return true;
    }
}

bool MetalRender::clearLastRenderGraph()
{
    @autoreleasepool {
        pImpl->releaseGraph();
        pImpl->video.closeHeld();
        return true;
    }
}

bool MetalRender::clearLastRenderGraphForRebuild()
{
    @autoreleasepool {
        pImpl->video.hold();
        pImpl->releaseGraph();
        return true;
    }
}

bool MetalRender::compileRenderGraph(Scene& scene, rg::RenderGraph& graph)
{
    if (! pImpl->inited) {
        // The compile a rebuild set its videos aside for is not going to happen, and
        // nothing else would close them.
        pImpl->video.closeHeld();
        return pImpl->fail("the native renderer is not initialised");
    }
    @autoreleasepool {
        return pImpl->compile(scene, graph);
    }
}

bool MetalRender::ApplyRenderScale(Scene& scene, rg::RenderGraph& graph, double scale,
                                   SceneResolution resolution)
{
    // The same guard the compatibility backend has, and for a sharper reason
    // here: `compile` starts by releasing the graph, which drops every uploaded
    // image and sets every video aside for the new graph to take back. The host
    // pushes this as a live property to every open scene whenever the value
    // *might* have moved — on scene creation, and on each power-source change
    // while the battery profile is on — precisely so a quality control the user
    // drags does not reparse the project. Acting on an unchanged value would turn
    // every plug and unplug into exactly that.
    if (! std::isfinite(scale) || scale <= 0.0) return true;
    const double clamped = std::min(1.0, std::max(vulkan::kMinRenderScale, scale));
    if (scene.render_scale == clamped && scene.resolution == resolution) return true;

    // A resolution that this scene has no canvas to apply to changes nothing
    // that is drawn, so it must not cost a perspective scene or a video its
    // compiled graph either.
    const bool resizes =
        scene.render_scale != clamped ||
        (scene.resolution != resolution && vulkan::SceneResolutionAffectsRaster(scene));
    scene.render_scale = clamped;
    scene.resolution   = resolution;
    if (! resizes) return true;
    @autoreleasepool {
        pImpl->video.hold();
        return pImpl->compile(scene, graph);
    }
}

void MetalRender::UpdateCameraFillMode(Scene& scene, FillMode fillmode)
{
    vulkan::ApplyCameraFillMode(scene, fillmode, pImpl->output_width, pImpl->output_height);
    // The camera moved: reuse signatures see it, but the gate must not let a
    // frame decided before that change stand in for one after it.
    pImpl->present_gate.Invalidate();
}

void MetalRender::SetWallpaperScalingMode(WallpaperScalingMode mode)
{
    pImpl->scaling_mode = mode;
    pImpl->present_gate.Invalidate();
}

void MetalRender::SetWallpaperScalingFactor(double factor)
{
    pImpl->scaling_factor = NormalizeScaleFactor(factor);
    pImpl->present_gate.Invalidate();
}

void MetalRender::SetWallpaperFraming(const WallpaperFraming& framing)
{
    // Like the scaling factor: the frame after a pan must present, not be
    // skipped as a repeat of one decided before it.
    pImpl->framing = NormalizeWallpaperFraming(framing);
    pImpl->present_gate.Invalidate();
}

void MetalRender::SetWallpaperHorizontalFlip(bool enabled)
{
    pImpl->horizontal_flip = enabled;
    pImpl->present_gate.Invalidate();
}

void MetalRender::InvalidatePresentedFrame() { pImpl->present_gate.Invalidate(); }

void MetalRender::SetVideoPlaybackPaused(bool paused)
{
    pImpl->video_paused = paused;
    pImpl->video.setPaused(paused);
}

void MetalRender::SetVideoPlaybackRate(float rate)
{
    pImpl->video_rate = rate;
    pImpl->video.setRate(rate);
}

VideoFramePath MetalRender::VideoPath() const { return pImpl->reported_path.load(); }

double MetalRender::ShortestVideoFramePeriod() const
{
    return pImpl->video.shortestFramePeriod();
}

uint32_t MetalRender::ShaderUpdateDemandReasons() const
{
    uint32_t reasons = pImpl->demand_reasons;
    // Asked now rather than latched at compile: pausing playback stops the
    // frames without rebuilding the graph, and a paused video must not keep
    // the clock running.
    if (pImpl->video.advancesOnItsOwn()) reasons |= vulkan::DynamicReason::VideoInput;
    return reasons;
}

void MetalRender::SetCounters(RendererCounters* counters)
{
    pImpl->counters = counters;
    pImpl->video.setCounters(counters);
}

WallpaperCursorMapping MetalRender::CursorMapping(const Scene& scene) const
{
    if (! pImpl->inited) return {};
    if (pImpl->output_width == 0 || pImpl->output_height == 0) return {};
    const auto camera = scene.cameras.find("global");
    if (camera == scene.cameras.end() || camera->second == nullptr) return {};
    const auto position = camera->second->GetPosition();
    return ComputeWallpaperCursorMapping(
        pImpl->scalingLayout(scene, pImpl->output_width, pImpl->output_height),
        position.x(), position.y(), camera->second->VisibleWidth(),
        camera->second->VisibleHeight());
}

const std::string& MetalRender::lastError() const { return pImpl->last_error; }

bool MetalRender::drawFrame(Scene& scene, bool* presented)
{
    if (presented != nullptr) *presented = false;
    if (! pImpl->inited || ! pImpl->graph_ready || pImpl->layer == nil) return false;

    @autoreleasepool {
        auto& impl = *pImpl;

        // Bounds how far the CPU may run ahead. Released by the completion
        // handler below, never by waiting on the command buffer. Taken before
        // the uniform writes, because they fill this frame's ring slot.
        dispatch_semaphore_wait(impl.inflight, DISPATCH_TIME_FOREVER);

        // The drawable is taken only after the passes are encoded, at the
        // point the composition needs it: a frame whose passes were all reused
        // and whose composition would be identical takes none at all.

        id<MTLCommandBuffer> command = [impl.queue commandBuffer];
        if (command == nil) {
            dispatch_semaphore_signal(impl.inflight);
            return impl.fail("a Metal command buffer could not be created");
        }

        // At the frame boundary, before anything else in this buffer: the copy
        // plan and the target table are what the setting really controls, and
        // both have to be in their new shape before any pass is encoded.
        if (! impl.applySceneOptimizationSetting(scene, command)) {
            dispatch_semaphore_signal(impl.inflight);
            return false;
        }

        // Before any pass samples one, and before the reuse plan reads their
        // versions: a text layer that re-rendered itself, or a media thumbnail
        // that arrived, has new pixels that this frame must see.
        impl.refreshRuntimeImages(scene);

        // Before anything is imported: what a video's consumers can use decides
        // whether a colour conversion is encoded for it at all, so a setting
        // that changed has to reach the import ahead of it rather than after.
        const bool planes_enabled = MetalVideoPlaneSamplingEnabled();
        // Ahead of the demand, because a variant adopted at this boundary
        // changes what its pass can consume. Nothing here compiles anything or
        // waits for a compile: it collects what finished and starts what is
        // now worth starting.
        const std::size_t variants_before = impl.readyVariantCount();
        impl.pumpVideoPlaneVariants(scene, planes_enabled);
        if (planes_enabled != impl.video_planes_applied ||
            impl.readyVariantCount() != variants_before) {
            impl.updateVideoDemand(planes_enabled);
        }

        // Before any pass: a decoded frame taken here is the one every pass in
        // this command buffer samples, and its conversion is encoded ahead of
        // them. A failure here is a failed frame, not a black one drawn as if
        // it had succeeded.
        std::string video_error;
        if (! impl.video.beginFrame(scene, command, &video_error)) {
            dispatch_semaphore_signal(impl.inflight);
            return impl.fail(std::move(video_error));
        }
        // After the import, because the frame's real pixel format is what
        // decides which of a material's two programs draws it.
        impl.selectVideoPlaneDraws(planes_enabled);

        id<MTLBuffer> uniforms = impl.uniform_rings[impl.frame_slot];
        auto*         uniform_base = static_cast<uint8_t*>(uniforms.contents);

        // `FrameBegin` is the host's, once per frame before it draws, as for
        // the compatibility backend: it steps the parallax cursor's smoothing
        // by the frame time and places puppet attachments. Calling it here as
        // well stepped the smoothing twice per frame, so the parallax on this
        // backend chased the cursor twice as fast.
        for (std::size_t i = 0; i < impl.prepared.size(); ++i) {
            auto&       pass = impl.prepared[i];
            const auto& desc = impl.descriptions[i];
            // A pass that draws nothing this frame needs no uniforms: nothing
            // reads them, the way the compatibility backend skips the update
            // of a hidden layer.
            if (! impl.passDraws(i)) continue;
            const bool planes_active =
                i < impl.video_plane_active.size() && impl.video_plane_active[i] != 0;
            const auto& reflection =
                planes_active ? pass.video_planes.reflection : pass.reflection;
            const uint32_t size =
                planes_active ? pass.video_planes.uniform_size : pass.uniform_size;
            if (size == 0) continue;
            uint8_t* destination = uniform_base + pass.uniform_offset;
            if (planes_active) {
                const std::size_t slot =
                    static_cast<std::size_t>(impl.frame_slot) % kFramesInFlight;
                if (slot >= pass.video_planes.uniform_ring.size()) continue;
                destination =
                    static_cast<uint8_t*>(pass.video_planes.uniform_ring[slot].contents);
            }
            impl.writeUniforms(scene, desc, pass, reflection, planes_active, destination);
        }
        if (scene.shaderValueUpdater != nullptr) scene.shaderValueUpdater->FrameEnd();
        if (! impl.uniform_error.empty()) {
            // Nothing has been encoded or recorded for this frame yet.
            dispatch_semaphore_signal(impl.inflight);
            return impl.fail(std::exchange(impl.uniform_error, {}));
        }

        // After the uniform pass, never before it: the sprite clock and the
        // node transforms advance in there, and a sample taken first would
        // describe the previous frame. Nothing above is conditional on the
        // plan, so a reused target still costs its scripts, its sprite step and
        // its uniform write -- only the drawing is removed.
        for (auto& desc : impl.descriptions) {
            if (desc.uses_scene_clear_color) {
                desc.clear_color = { scene.clearColor[0], scene.clearColor[1], scene.clearColor[2], 1.0f };
            }
        }
        impl.planStaticSkips(scene);
        // A frame that fails after the plan has already recorded this frame's
        // signatures must not leave those signatures behind: the next frame
        // would reuse a target the GPU never wrote.
        impl.frame_swaps.clear();
        impl.opening_copies.clear();
        impl.beginPooledTrades();
        const auto abandon_frame = [&impl, &scene](std::string message) {
            // Its command buffer never runs, so every texture still holds what
            // it held when the frame began, and every name has to point back at
            // it.
            for (auto swap = impl.frame_swaps.rbegin(); swap != impl.frame_swaps.rend(); ++swap) {
                impl.tradeFeedbackTextures(*swap);
            }
            impl.abandonPooledTrades(scene);
            impl.frame_swaps.clear();
            impl.opening_copies.clear();
            impl.static_cache.InvalidateAll();
            dispatch_semaphore_signal(impl.inflight);
            return impl.fail(std::move(message));
        };

        // This frame's simulated geometry, into the storage this frame owns.
        // The simulation itself belongs to the shared runtime and has already
        // run; nothing here emits, ages or kills a particle, and a pass whose
        // pixels are being reused needs no upload because a reused target's
        // writers never include a mesh the runtime rewrites.
        for (std::size_t i = 0; i < impl.prepared.size(); ++i) {
            auto& pass = impl.prepared[i];
            if (! pass.dynamic_mesh) continue;
            if (i < impl.static_skip.size() && impl.static_skip[i] != 0) continue;
            // Nothing reads this frame's slot of a pass that does not draw; the
            // next frame that draws it uploads whatever the mesh holds then.
            if (! impl.passDraws(i)) continue;
            std::string upload_error;
            if (! impl.uploadDynamicMesh(pass, impl.descriptions[i], &upload_error)) {
                return abandon_frame(std::move(upload_error));
            }
        }

        // Encodes the smaller levels of a mip-mapped target, once its last
        // writer before a reader has finished with level 0.
        const auto generate_mipmaps = [&command, &impl](id<MTLTexture> texture) {
            if (texture == nil || texture.mipmapLevelCount <= 1) return;
            id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
            [blit generateMipmapsForTexture:texture];
            [blit endEncoding];
            ++impl.frame_encodes.blit_passes;
        };

        // Consecutive passes that render into one image share one render pass,
        // the rule the compatibility backend batches by. Every render pass
        // stores its whole target and the next one loads it back, and at the
        // scene's size that memory traffic, not the draws, is what a frame of
        // many layers costs. A pass starts a new render pass when it renders
        // elsewhere, changes the depth attachment, samples its own target, or
        // clears a target something was already drawn into.
        struct OpenRenderPass
        {
            id<MTLRenderCommandEncoder> encoder { nil };
            id<MTLTexture>              target { nil };
            id<MTLTexture>              depth { nil };
            uint32_t                    width { 0 };
            uint32_t                    height { 0 };
            bool                        began_with_clear { false };
            std::array<float, 4>        clear_color {};
            bool                        drew { false };
            // The state the previous draw left set. A draw in a shared render
            // pass inherits it, so each draw sets what differs, nil included.
            id<MTLRenderPipelineState>  pipeline { nil };
            id<MTLDepthStencilState>    depth_stencil { nil };
            MetalCullMode               cull_mode { kSceneCullMode };
        };
        OpenRenderPass open;
        const auto close_pass = [&open]() {
            if (open.encoder != nil) [open.encoder endEncoding];
            open = OpenRenderPass {};
        };
        // Depth attachments already cleared this frame; a later render pass
        // that uses one again loads it.
        std::vector<id<MTLTexture>> depth_cleared;

        impl.frame_encodes = {};
        for (std::size_t i = 0; i < impl.prepared.size(); ++i) {
            auto&       pass = impl.prepared[i];
            const auto& desc = impl.descriptions[i];
            // A pooled copy whose last reader has been encoded gives its image
            // back. Any later use of it is a copy step, which ends the open
            // render pass first, and the GPU runs this command buffer in order.
            if (i < impl.pooled_release_at.size()) {
                for (const auto& [g, k] : impl.pooled_release_at[i]) {
                    auto& group = impl.pooled_trades[static_cast<std::size_t>(g)];
                    group.free.push_back(*group.copies[static_cast<std::size_t>(k)].slot);
                }
            }
            // A reused target is left exactly as the last frame wrote it. No
            // encoder is created for a skipped pass, because creating one would
            // apply its load action -- a clear would erase the pixels the plan
            // just decided to keep -- and its mip levels are already the ones
            // that belong to those pixels.
            if (i < impl.static_skip.size() && impl.static_skip[i] != 0) continue;
            id<MTLTexture> target = i < impl.pass_targets.size() ? impl.pass_targets[i] : nil;
            if (target == nil) continue;

            if (pass.kind == MetalPassKind::Copy) {
                // A copy the plan removed produces nothing: either its result
                // has no consumer, or the destination now shares the source's
                // texture and a byte-for-byte duplicate would change nothing.
                if (i < impl.copy_elision.size() &&
                    impl.copy_elision[i] != vulkan::CopyElision::None) {
                    continue;
                }
                const auto source = impl.targets.find(desc.source_key);
                if (source == impl.targets.end()) continue;
                close_pass();
                if (i < impl.pooled_copy_at.size() && impl.pooled_copy_at[i].first >= 0) {
                    auto& group =
                        impl.pooled_trades[static_cast<std::size_t>(impl.pooled_copy_at[i].first)];
                    auto& copy = group.copies[static_cast<std::size_t>(impl.pooled_copy_at[i].second)];
                    if (group.free.empty()) return abandon_frame("a pooled copy found no free image");
                    id<MTLTexture> next = group.free.back();
                    group.free.pop_back();
                    id<MTLTexture> image = *group.source_slot;
                    ++impl.pooled_moves;
                    if (impl.feedbackReaderRenders(i)) {
                        // Traded: the copy's name takes the image as it stands
                        // and the source carries on in a free one, which its
                        // reader fills first when it loads.
                        *copy.slot         = image;
                        *group.source_slot = next;
                        for (const auto k : group.source_passes) impl.pass_targets[k] = next;
                        if (group.source_key == impl.scene_output_key) {
                            impl.scene_output_target = next;
                        }
                        if (impl.feedback_swaps[i].prefix) impl.opening_copies.emplace_back(next, image);
                    } else {
                        // Nothing redraws the source before it is read again,
                        // so the copy is made into a free image.
                        *copy.slot          = next;
                        impl.pass_targets[i] = next;
                        id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
                        [blit copyFromTexture:image
                                  sourceSlice:0
                                  sourceLevel:0
                                    toTexture:next
                             destinationSlice:0
                             destinationLevel:0
                                   sliceCount:1
                                   levelCount:1];
                        [blit endEncoding];
                        ++impl.frame_encodes.blit_passes;
                    }
                    continue;
                }
                if (i < impl.feedback_swaps.size() && impl.feedback_swaps[i].valid &&
                    impl.feedbackReaderRenders(i)) {
                    // The copy's name takes the image as it stands; the source's
                    // name takes the texture the copy would have been made in,
                    // which the reader fills first.
                    id<MTLTexture> image = source->second;
                    impl.tradeFeedbackTextures(i);
                    impl.frame_swaps.push_back(i);
                    if (impl.feedback_swaps[i].prefix) impl.opening_copies.emplace_back(target, image);
                    continue;
                }
                const bool identical = source->second.width == target.width &&
                                       source->second.height == target.height &&
                                       source->second.pixelFormat == target.pixelFormat;
                if (identical) {
                    id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
                    [blit copyFromTexture:source->second
                              sourceSlice:0
                              sourceLevel:0
                                toTexture:target
                         destinationSlice:0
                         destinationLevel:0
                               sliceCount:1
                               levelCount:1];
                    [blit endEncoding];
                    ++impl.frame_encodes.blit_passes;
                } else if (impl.encodeScaledCopy(command, source->second, target)) {
                    ++impl.frame_encodes.render_passes;
                    if (target == impl.scene_output_target) {
                        ++impl.frame_encodes.scene_output_passes;
                    }
                } else {
                    // Skipping it would leave the destination holding the
                    // previous frame while the graph says it was refreshed.
                    return abandon_frame("an effect image could not be resampled");
                }
                if (desc.generate_mipmaps) generate_mipmaps(target);
                continue;
            }

            // A step whose layer is hidden draws nothing, but a clear it
            // carries still applies, so the next writer starts from the state
            // the graph decided. Without one it needs no render pass at all,
            // and the target keeps what the passes before it left there.
            const bool draws  = impl.passDraws(i);
            const bool clears = impl.passClears(i);
            if (! draws && ! clears) {
                if (desc.generate_mipmaps) {
                    close_pass();
                    generate_mipmaps(target);
                }
                continue;
            }

            id<MTLTexture> depth = i < impl.pass_depths.size() ? impl.pass_depths[i] : nil;
            const bool     joins =
                open.encoder != nil && open.target == target && open.depth == depth &&
                impl.pass_reads_own_target[i] == 0 &&
                (! clears ||
                 (! open.drew && open.began_with_clear && open.clear_color == desc.clear_color));
            if (! joins) {
                close_pass();
                // Every texel is written by the copy that opens it, so there is
                // nothing to load.
                id<MTLTexture> opening = nil;
                for (auto owed = impl.opening_copies.begin(); owed != impl.opening_copies.end();
                     ++owed) {
                    if (owed->first != target) continue;
                    opening = owed->second;
                    impl.opening_copies.erase(owed);
                    break;
                }
                const bool opens_with_copy = opening != nil;
                MTLRenderPassDescriptor* descriptor = [MTLRenderPassDescriptor renderPassDescriptor];
                descriptor.colorAttachments[0].texture    = target;
                descriptor.colorAttachments[0].loadAction =
                    opens_with_copy ? MTLLoadActionDontCare : static_cast<MTLLoadAction>(desc.load_action);
                // Always stored: a later pass, the presentation blit or a poster
                // capture reads this target after the pass ends.
                descriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
                descriptor.colorAttachments[0].clearColor  = MTLClearColorMake(
                    desc.clear_color[0], desc.clear_color[1], desc.clear_color[2],
                    desc.clear_color[3]);
                if (depth != nil) {
                    const bool first = std::find(depth_cleared.begin(), depth_cleared.end(),
                                                 depth) == depth_cleared.end();
                    if (first) depth_cleared.push_back(depth);
                    descriptor.depthAttachment.texture     = depth;
                    descriptor.depthAttachment.loadAction  =
                        first ? MTLLoadActionClear : MTLLoadActionLoad;
                    descriptor.depthAttachment.storeAction = MTLStoreActionStore;
                    descriptor.depthAttachment.clearDepth  = 1.0;
                }
                open.encoder = [command renderCommandEncoderWithDescriptor:descriptor];
                if (open.encoder == nil) return abandon_frame("a render pass could not be started");
                open.target           = target;
                open.depth            = depth;
                open.began_with_clear = clears;
                open.clear_color      = desc.clear_color;
                ++impl.frame_encodes.render_passes;
                if (target == impl.scene_output_target) ++impl.frame_encodes.scene_output_passes;
                // Culling follows the compatibility backend: none for a pass
                // without depth, the material's for one with it, against the
                // same front faces. Each draw sets the mode it needs below.
                [open.encoder setCullMode:static_cast<MTLCullMode>(kSceneCullMode)];
                [open.encoder setFrontFacingWinding:kSceneFrontFaceCounterClockwise
                                                        ? MTLWindingCounterClockwise
                                                        : MTLWindingClockwise];
                if (opens_with_copy) {
                    [open.encoder setViewport:(MTLViewport) { 0.0, 0.0, (double)target.width,
                                                              (double)target.height, 0.0, 1.0 }];
                    [open.encoder setScissorRect:(MTLScissorRect) { 0, 0, target.width, target.height }];
                    const auto copy_pipeline =
                        impl.scene_copy_pipelines.at(static_cast<uint32_t>(target.pixelFormat));
                    [open.encoder setRenderPipelineState:copy_pipeline];
                    [open.encoder setVertexBuffer:impl.present_vertices offset:0 atIndex:0];
                    [open.encoder setFragmentTexture:opening atIndex:0];
                    [open.encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                                     vertexStart:0
                                     vertexCount:4];
                    open.pipeline = copy_pipeline;
                    open.width    = static_cast<uint32_t>(target.width);
                    open.height   = static_cast<uint32_t>(target.height);
                }
            }

            if (draws) {
                id<MTLRenderCommandEncoder> encoder = open.encoder;
                if (open.width != desc.target_width || open.height != desc.target_height) {
                    [encoder setViewport:(MTLViewport) { 0.0, 0.0, (double)desc.target_width,
                                                         (double)desc.target_height, 0.0, 1.0 }];
                    [encoder setScissorRect:(MTLScissorRect) { 0, 0, desc.target_width,
                                                               desc.target_height }];
                    open.width  = desc.target_width;
                    open.height = desc.target_height;
                }
                // One of the material's two programs, chosen from the format the
                // decoder produced for this frame. Both were built with the graph.
                const bool planes_active =
                    i < impl.video_plane_active.size() && impl.video_plane_active[i] != 0;
                id<MTLRenderPipelineState> pipeline =
                    planes_active ? pass.video_planes.pipeline : pass.pipeline;
                if (pipeline != open.pipeline) {
                    [encoder setRenderPipelineState:pipeline];
                    open.pipeline = pipeline;
                }
                if (pass.depth_stencil != open.depth_stencil) {
                    [encoder setDepthStencilState:pass.depth_stencil];
                    open.depth_stencil = pass.depth_stencil;
                }
                if (desc.cull_mode != open.cull_mode) {
                    [encoder setCullMode:static_cast<MTLCullMode>(desc.cull_mode)];
                    open.cull_mode = desc.cull_mode;
                }

                const std::size_t geometry_slot =
                    static_cast<std::size_t>(impl.frame_slot) % kFramesInFlight;
                if (pass.dynamic_mesh) {
                    for (std::size_t v = 0; v < pass.dynamic_vertex_rings.size(); ++v) {
                        [encoder setVertexBuffer:pass.dynamic_vertex_rings[v][geometry_slot]
                                          offset:0
                                         atIndex:pass.vertex_buffer_slots[v]];
                    }
                } else {
                    for (std::size_t v = 0; v < pass.vertex_buffers.size(); ++v) {
                        [encoder setVertexBuffer:pass.vertex_buffers[v]
                                          offset:0
                                         atIndex:pass.vertex_buffer_slots[v]];
                    }
                }
                const auto& active_slots =
                    planes_active ? pass.video_planes.texture_slots : pass.texture_slots;
                const int uniform_vertex_slot = planes_active
                                                    ? pass.video_planes.vertex_uniform_slot
                                                    : pass.vertex_uniform_slot;
                const int uniform_fragment_slot = planes_active
                                                      ? pass.video_planes.fragment_uniform_slot
                                                      : pass.fragment_uniform_slot;
                const uint32_t uniform_size =
                    planes_active ? pass.video_planes.uniform_size : pass.uniform_size;
                id<MTLBuffer> uniform_buffer = uniforms;
                NSUInteger    uniform_offset = pass.uniform_offset;
                if (planes_active) {
                    uniform_buffer = pass.video_planes.uniform_ring.empty()
                                         ? nil
                                         : pass.video_planes.uniform_ring[geometry_slot];
                    uniform_offset = 0;
                }
                if (uniform_size > 0 && uniform_buffer != nil) {
                    if (uniform_vertex_slot >= 0) {
                        [encoder setVertexBuffer:uniform_buffer
                                          offset:uniform_offset
                                         atIndex:(NSUInteger)uniform_vertex_slot];
                    }
                    if (uniform_fragment_slot >= 0) {
                        [encoder setFragmentBuffer:uniform_buffer
                                            offset:uniform_offset
                                           atIndex:(NSUInteger)uniform_fragment_slot];
                    }
                }
                // nil is bound as well: a render pass shared with the previous
                // draw still holds that draw's images, and a slot this draw
                // leaves empty has to read as empty, exactly as it would in a
                // render pass of its own.
                const auto bind_texture = [&encoder](const Impl::TextureSlotBinding& slot,
                                                      id<MTLTexture>                 texture,
                                                      id<MTLSamplerState>            sampler) {
                    if (texture == nil) sampler = nil;
                    if (slot.vertex_texture >= 0) {
                        [encoder setVertexTexture:texture atIndex:(NSUInteger)slot.vertex_texture];
                    }
                    if (slot.fragment_texture >= 0) {
                        [encoder setFragmentTexture:texture
                                            atIndex:(NSUInteger)slot.fragment_texture];
                    }
                    if (slot.vertex_sampler >= 0) {
                        [encoder setVertexSamplerState:sampler
                                               atIndex:(NSUInteger)slot.vertex_sampler];
                    }
                    if (slot.fragment_sampler >= 0) {
                        [encoder setFragmentSamplerState:sampler
                                                 atIndex:(NSUInteger)slot.fragment_sampler];
                    }
                };
                for (std::size_t t = 0; t < active_slots.size(); ++t) {
                    const auto& slot = active_slots[t];
                    if (! slot.bound()) continue;
                    // The video slot on the direct path binds the decoder's own
                    // two planes, through the same binding plan reflection
                    // produced, in place of the one image the other program
                    // samples.
                    if (planes_active && t == pass.video_planes.slot) {
                        const auto planes = impl.video.planes(desc.texture_keys[t]);
                        const bool valid  = planes.valid();
                        bind_texture(slot, valid ? planes.luma : nil, pass.samplers[t]);
                        bind_texture(pass.video_planes.chroma, valid ? planes.chroma : nil,
                                     pass.video_planes.chroma_sampler);
                        continue;
                    }
                    // A sprite sheet's current frame decides which uploaded
                    // image is bound; its rectangle inside that image arrives
                    // through the rotation and translation uniforms written
                    // above.
                    int image_slot = -1;
                    if (const auto sprite = pass.sprites.find(t);
                        sprite != pass.sprites.end() && sprite->second.numFrames() > 0) {
                        image_slot = sprite->second.GetCurFrame().imageId;
                    }
                    // A cover published over the slot's render target is bound
                    // in its place, sampled as a cover is.
                    id<MTLSamplerState> cover_sampler = nil;
                    if (id<MTLTexture> cover = impl.publishedCover(desc, t, &cover_sampler);
                        cover != nil) {
                        bind_texture(slot, cover, cover_sampler);
                        continue;
                    }
                    bind_texture(slot,
                                 impl.resolveTexture(scene, desc.texture_keys[t], nullptr,
                                                     image_slot),
                                 pass.samplers[t]);
                }

                id<MTLBuffer> index_buffer = pass.index_buffer;
                if (pass.dynamic_mesh) {
                    index_buffer = pass.dynamic_index_ring.empty()
                                       ? nil
                                       : pass.dynamic_index_ring[geometry_slot];
                }
                if (index_buffer != nil && pass.index_count > 0) {
                    if (! pass.draw_ranges.empty()) {
                        for (const auto& range : pass.draw_ranges) {
                            uint64_t offset_bytes = 0;
                            if (! CheckedMulU64(range.indexOffset, pass.index_element_size,
                                                offset_bytes) ||
                                offset_bytes > std::numeric_limits<NSUInteger>::max()) {
                                continue;
                            }
                            [encoder
                                drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                           indexCount:range.indexCount
                                            indexType:pass.index_type
                                          indexBuffer:index_buffer
                                    indexBufferOffset:static_cast<NSUInteger>(offset_bytes)];
                        }
                    } else {
                        [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                            indexCount:pass.index_count
                                             indexType:pass.index_type
                                           indexBuffer:index_buffer
                                     indexBufferOffset:0];
                    }
                } else if (pass.vertex_count > 0) {
                    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                                vertexStart:0
                                vertexCount:pass.vertex_count];
                }
                open.drew = true;
            }
            if (desc.generate_mipmaps) {
                close_pass();
                generate_mipmaps(target);
            }
        }
        close_pass();
        impl.last_frame_encodes = impl.frame_encodes;

        // ---- presentation
        // What the composition reads besides the scene output's own pixels,
        // compared exactly with what the last presented composition read.
        const CGSize drawable_size = impl.layer.drawableSize;
        const auto   drawable_width  = static_cast<uint32_t>(std::max(1.0, drawable_size.width));
        const auto   drawable_height = static_cast<uint32_t>(std::max(1.0, drawable_size.height));
        const auto   composed_output =
            impl.targets.find(scene.ResolveRenderTargetName(SpecTex_Default));
        const auto layout = impl.scalingLayout(scene, drawable_width, drawable_height);
        impl.present_key.Clear();
        impl.present_key.AddPointer((__bridge const void*)impl.layer);
        impl.present_key.Add(drawable_width);
        impl.present_key.Add(drawable_height);
        impl.present_key.Add(static_cast<uint64_t>(impl.layer.pixelFormat));
        impl.present_key.AddPointer(composed_output != impl.targets.end()
                                        ? (__bridge const void*)composed_output->second
                                        : nullptr);
        impl.present_key.Add(static_cast<uint64_t>(static_cast<uint32_t>(layout.viewport_px.x)));
        impl.present_key.Add(static_cast<uint64_t>(static_cast<uint32_t>(layout.viewport_px.y)));
        impl.present_key.Add(static_cast<uint64_t>(static_cast<uint32_t>(layout.viewport_px.width)));
        impl.present_key.Add(static_cast<uint64_t>(static_cast<uint32_t>(layout.viewport_px.height)));
        impl.present_key.Add(static_cast<uint64_t>(static_cast<uint32_t>(layout.scissor_px.x)));
        impl.present_key.Add(static_cast<uint64_t>(static_cast<uint32_t>(layout.scissor_px.y)));
        impl.present_key.Add(static_cast<uint64_t>(static_cast<uint32_t>(layout.scissor_px.width)));
        impl.present_key.Add(static_cast<uint64_t>(static_cast<uint32_t>(layout.scissor_px.height)));
        impl.present_key.Add(impl.horizontal_flip ? 1u : 0u);

        // Every pass reused or drawing nothing, no feedback trade and no video
        // to import: the scene output holds exactly the pixels the last
        // composition read. With identical composition inputs, composing and
        // presenting again would put the same picture back.
        const bool nothing_encoded = impl.frame_encodes.render_passes == 0 &&
                                     impl.frame_encodes.blit_passes == 0 &&
                                     impl.frame_swaps.empty() && impl.pooled_moves == 0 &&
                                     impl.video.empty();
        if (vulkan::SceneOptimizationEnabled() && nothing_encoded &&
            impl.present_gate.Matches(impl.present_key, {})) {
            // The buffer holds nothing and is dropped uncommitted, so the slot
            // is released here and the uniform ring does not advance: the next
            // frame rewrites the slot this one filled, which no GPU work reads.
            // A pending poster is served by the poster request itself, which
            // composes the retained output without a frame.
            dispatch_semaphore_signal(impl.inflight);
            if (impl.counters != nullptr) impl.counters->Add(OWE_RC_PRESENTS_SKIPPED_UNCHANGED);
            return true;
        }

        id<CAMetalDrawable> drawable = [impl.layer nextDrawable];
        if (drawable == nil) {
            // The layer has no drawable to give right now. The passes already
            // encoded still run, so the targets and the reuse plan agree, but
            // nothing reaches the surface: `presented` stays false and the
            // next frame presents whatever it would have.
            impl.present_gate.Invalidate();
            dispatch_semaphore_t semaphore = impl.inflight;
            [command addCompletedHandler:^(id<MTLCommandBuffer>) {
              dispatch_semaphore_signal(semaphore);
            }];
            [command commit];
            impl.frame_slot  = (impl.frame_slot + 1) % kFramesInFlight;
            impl.frame_drawn = true;
            return true;
        }
        impl.encodeComposition(command, drawable.texture, scene);

        // The poster draws the same composition into a texture this process
        // owns. It costs nothing unless a request is pending, and it never
        // reads the drawable, holds one, or makes the layer readable. A capture
        // that fails is not a failed frame: the wallpaper is already drawn, and
        // the capture keeps its own diagnostic for the next service call.
        impl.poster.encodeIfRequested(
            command, (uint32_t)drawable.texture.width, (uint32_t)drawable.texture.height,
            drawable.texture.pixelFormat,
            [&impl, &scene](id<MTLCommandBuffer> poster_command, id<MTLTexture> destination) {
                return impl.encodeComposition(poster_command, destination, scene);
            });

        dispatch_semaphore_t semaphore = impl.inflight;
        [command addCompletedHandler:^(id<MTLCommandBuffer>) {
          dispatch_semaphore_signal(semaphore);
        }];
        [command presentDrawable:drawable];
        [command commit];

        impl.frame_slot = (impl.frame_slot + 1) % kFramesInFlight;
        impl.frame_drawn = true;
        // With scene optimisation off nothing is remembered, so turning it
        // back on starts from a real present.
        if (vulkan::SceneOptimizationEnabled()) {
            impl.present_gate.Record(impl.present_key, {});
        } else {
            impl.present_gate.Invalidate();
        }
        // Published here, on the thread that owns the pass table, so the host
        // reads a value rather than a table another thread is rewriting.
        impl.reported_path.store(impl.framePathReport(planes_enabled));
        if (impl.counters != nullptr) impl.counters->Add(OWE_RC_PRESENT_REQUESTS);
        // `scene.first_frame_ok` belongs to the frame handler: setting it here
        // would satisfy its own check before it ran and swallow the one edge
        // it reports to the host.
        if (presented != nullptr) *presented = true;
        return true;
    }
}

PosterServiceResult MetalRender::ServicePosterRequest(Scene& scene)
{
    if (pImpl == nullptr || ! pImpl->inited || ! pImpl->graph_ready) {
        return PosterServiceResult::NoFrameYet;
    }
    // Composing the output image before the compiled graph has ever been drawn
    // would publish an empty picture as the wallpaper.
    if (! pImpl->frame_drawn) return PosterServiceResult::NoFrameYet;

    @autoreleasepool {
        auto& impl = *pImpl;

        uint32_t       width  = std::max<uint32_t>(1, impl.output_width);
        uint32_t       height = std::max<uint32_t>(1, impl.output_height);
        MTLPixelFormat format = impl.drawable_format;
        if (impl.layer != nil) {
            const CGSize size = impl.layer.drawableSize;
            if (size.width >= 1.0 && size.height >= 1.0) {
                width  = (uint32_t)size.width;
                height = (uint32_t)size.height;
            }
            if (impl.layer.pixelFormat != MTLPixelFormatInvalid) format = impl.layer.pixelFormat;
        }

        id<MTLCommandBuffer> command = [impl.queue commandBuffer];
        if (command == nil) {
            impl.last_error = "a Metal command buffer could not be created";
            return PosterServiceResult::Failed;
        }

        // Deliberately outside the in-flight semaphore and the uniform ring:
        // this re-composes the retained output image rather than re-running the
        // scene, so it needs no uniform slot, and taking a frame slot would let
        // an idle wallpaper -- one that never completes another frame to signal
        // it -- wait forever.
        const auto outcome = impl.poster.encodeIfRequested(
            command, width, height, format,
            [&impl, &scene](id<MTLCommandBuffer> poster_command, id<MTLTexture> destination) {
                return impl.encodeComposition(poster_command, destination, scene);
            });

        switch (outcome) {
        case MetalPosterCapture::Outcome::Encoded:
            [command commit];
            return PosterServiceResult::Submitted;
        case MetalPosterCapture::Outcome::Busy: return PosterServiceResult::Busy;
        case MetalPosterCapture::Outcome::Failed:
            impl.last_error = impl.poster.lastError();
            return PosterServiceResult::Failed;
        case MetalPosterCapture::Outcome::NotRequested:
            return PosterServiceResult::NotRequested;
        }
        return PosterServiceResult::Failed;
    }
}


#ifdef WESCENE_BUILD_TESTS
bool MetalRender::ReadRenderTargetForTests(const std::string& key, std::vector<uint8_t>& rgba,
                                           uint32_t& width, uint32_t& height,
                                           std::vector<float>* radiance)
{
    @autoreleasepool {
        const auto found = pImpl->targets.find(key);
        if (found == pImpl->targets.end()) return false;
        id<MTLTexture> texture = found->second;
        width  = static_cast<uint32_t>(texture.width);
        height = static_cast<uint32_t>(texture.height);
        const bool half_float = texture.pixelFormat == MTLPixelFormatRGBA16Float;
        const NSUInteger bytes_per_row = texture.width * (half_float ? 8 : 4);
        id<MTLBuffer>    staging       = [pImpl->device newBufferWithLength:bytes_per_row * texture.height
                                                            options:MTLResourceStorageModeShared];
        if (staging == nil) return false;

        id<MTLCommandBuffer>      command = [pImpl->queue commandBuffer];
        id<MTLBlitCommandEncoder> blit    = [command blitCommandEncoder];
        [blit copyFromTexture:texture
                  sourceSlice:0
                  sourceLevel:0
                 sourceOrigin:MTLOriginMake(0, 0, 0)
                   sourceSize:MTLSizeMake(texture.width, texture.height, 1)
                     toBuffer:staging
            destinationOffset:0
       destinationBytesPerRow:bytes_per_row
     destinationBytesPerImage:bytes_per_row * texture.height];
        [blit endEncoding];
        [command commit];
        // Deliberately synchronous, and deliberately not on the frame path:
        // a readback has no later point at which to observe completion.
        [command waitUntilCompleted];

        const size_t samples = static_cast<size_t>(width) * height * 4;
        rgba.resize(samples);
        if (radiance != nullptr) radiance->resize(samples);
        const auto* source = static_cast<const uint8_t*>(staging.contents);
        for (size_t i = 0; i < samples; ++i) {
            const float value = half_float
                ? HalfFloatToFloat(reinterpret_cast<const uint16_t*>(source)[i])
                : static_cast<float>(source[i]) / 255.0f;
            if (radiance != nullptr) (*radiance)[i] = value;
            rgba[i] = half_float
                ? static_cast<uint8_t>(std::lround(std::clamp(value, 0.0f, 1.0f) * 255.0f))
                : source[i];
        }
        return true;
    }
}

uint64_t MetalRender::RuntimeImageUploadsForTests() const
{
    return pImpl == nullptr ? 0 : pImpl->runtime_image_uploads;
}

MetalRender::FrameEncodeCountsForTests MetalRender::LastFrameEncodeCountsForTests() const
{
    if (pImpl == nullptr) return {};
    const auto& last = pImpl->last_frame_encodes;
    return { last.render_passes, last.scene_output_passes, last.blit_passes };
}

void MetalRender::SetTargetSharingForTests(bool enabled) { TargetSharingSwitch().store(enabled); }

uint64_t MetalRender::RenderTargetBytesForTests() const
{
    if (pImpl == nullptr) return 0;
    std::unordered_set<const void*> counted;
    uint64_t                        bytes = 0;
    for (const auto* table : { &pImpl->targets, &pImpl->depth_targets }) {
        for (const auto& [key, texture] : *table) {
            (void)key;
            if (texture == nil || ! counted.insert((__bridge const void*)texture).second) continue;
            bytes += texture.allocatedSize;
        }
    }
    return bytes;
}

uint64_t MetalRender::ProgramCompilesForTests() { return MetalProgramCache::shared().compileCount(); }

bool MetalRender::PipelineArchiveServesEverySeenPipelineForTests()
{
    return MetalProgramCache::shared().archiveServesEverySeenPipeline();
}

void MetalRender::WaitForPipelineArchiveWritesForTests()
{
    MetalProgramCache::shared().finishArchiveWrites();
}
#endif

} // namespace wallpaper::metal
