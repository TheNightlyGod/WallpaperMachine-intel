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
    RGB8,
    RGBA8,
    RG8,
    R8,
    RGBA16F
};
/// Decodes diagnostic readback samples without a platform half-float ABI.
float HalfFloatToFloat(uint16_t bits);

enum class BlendMode
{
    Disable,
    Translucent,
    Additive,
    Normal,
    AlphaToCoverage
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
    REPEAT
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
