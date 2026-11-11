#pragma once
#include <string>
#include <cstdint>

namespace wallpaper
{
enum class ImageType
{
    UNKNOWN = -1,
    BMP     = 0,
    ICO     = 1,
    JPEG    = 2,
    JNG     = 3,
    KOALA   = 4,
    LBM     = 5,
    MNG     = 6,
    PBM     = 7,
    PBMRAW  = 8,
    PCD     = 9,
    PCX     = 10,
    PGM     = 11,
    PGMRAW  = 12,
    PNG     = 13,
    PPM     = 14,
    PPMRAW  = 15,
    RAS     = 16,
    TARGA   = 17,
    TIFF    = 18,
    WBMP    = 19,
    PSD     = 20,
    CUT     = 21,
    XBM     = 22,
    XPM     = 23,
    DDS     = 24,
    GIF     = 25,
    HDR     = 26,
    FAXG3   = 27,
    SGI     = 28,
    EXR     = 29,
    J2K     = 30,
    JP2     = 31,
    PFM     = 32,
    PICT    = 33,
    RAW     = 34,
};

enum class TextureFormat
{
    BC1,
    BC2,
    BC3,
    RGBA8,
    RG8,
    R8,
    RGBA16F,
    RG16F,
    R16F,
    BC7,
    RGB10A2,
    RGBA16,
    RGBA16S,
    /// A depth render target the scene samples (the shadow atlas): 32-bit float depth.
    Depth32F
};
/// Decodes diagnostic readback samples without a platform half-float ABI.
float HalfFloatToFloat(uint16_t bits);

enum class BlendMode
{
    Disable,
    Translucent,
    Additive,
    Normal,
    AlphaToCoverage,
    /// Wallpaper Engine's translucent blend with device flag 0x100 (`sub_14009B100`):
    /// colour DEST_COLOR / INV_SRC_ALPHA, alpha ONE / ONE. Never authored; a puppet's
    /// nested clipping masks are multiplied together with it (`sub_14020D6A0`).
    Multiply
};

/// How a blended draw combines its alpha with the target's (Wallpaper Engine 2.8.0.42,
/// `sub_140099F60`). The colour factors always come from the material's `BlendMode`.
enum class AlphaBlendRule : uint8_t
{
    /// The material's own alpha factors: translucent is SRC_ALPHA / INV_SRC_ALPHA, so a
    /// translucent draw leaves `As*As + Ad*(1-As)`.
    Material,
    /// ONE / INV_SRC_ALPHA: `As + Ad*(1-As)`. A layer's own picture into its composite,
    /// which Wallpaper Engine draws like the first pass of an effect chain (`sub_1401EA500`).
    SourceOver,
    /// BlendOpAlpha MAX with ONE / ONE: the children of a layer whose `copybackground` is off
    /// (`sub_1401ECB20`, `sub_140207B50`). Only blended modes are affected.
    Max,
};

/// A material pass's `alphawriting` (`sub_1401577E0`: default 0, enabled 1, disabled 2; an
/// unknown or differently cased word is the default).
enum class AlphaWriting : uint8_t
{
    Default,
    Enabled,
    Disabled,
};

enum class CullMode
{
    None,
    Back,
    Front
};

enum class ShaderType
{
    VERTEX,
    GEOMETRY,
    FRAGMENT
};

enum class TextureType
{
    IMG_2D,
};

enum class MeshPrimitive
{
    POINT,
    TRIANGLE
};

enum class FillMode
{
    STRETCH,
    ASPECTFIT,
    ASPECTCROP
};

enum class TextureWrap
{
    CLAMP_TO_EDGE,
    REPEAT,
    // Outside [0,1] reads transparent black (D3D BORDER with colour 0,0,0,0).
    CLAMP_TO_BORDER
};

enum class TextureFilter
{
    LINEAR,
    NEAREST
};

struct TextureSample {
    TextureWrap   wrapS { TextureWrap::REPEAT };
    TextureWrap   wrapT { TextureWrap::REPEAT };
    TextureFilter magFilter { TextureFilter::NEAREST };
    TextureFilter minFilter { TextureFilter::NEAREST };
    // How a mip level is picked between the levels of a texture that has them.
    // Linear unless the texture's file asks for point sampling: the reference
    // sampler for that flag points the mip level as well as the texel, and a
    // sample that merely has both filters on NEAREST (the default, or a target
    // made for one reason or another) is not that request.
    TextureFilter mipFilter { TextureFilter::LINEAR };
    // 1 = no anisotropic filtering.
    uint8_t maxAnisotropy { 1 };
    // A comparison sampler (shadow maps): D3D func 5, GREATER.
    enum class Compare : uint8_t { None, Greater } compare { Compare::None };
};

enum class VertexType
{
    FLOAT1,
    FLOAT2,
    FLOAT3,
    FLOAT4,
    UINT1,
    UINT2,
    UINT3,
    UINT4
};

} // namespace wallpaper
