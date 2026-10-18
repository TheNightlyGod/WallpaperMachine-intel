#include "WPTexImageParser.hpp"
#include "ImageOrientation.hpp"

#include "Type.hpp"
#include "Utils/Sha.hpp"
#include "Video/VideoMetadata.hpp"
#include "Video/VideoTextureSource.hpp"
#include "WPCommon.hpp"
#include <cstdint>
#include <lz4.h>

#include "SpriteAnimation.hpp"
#include "Utils/Algorism.h"
#include "Fs/VFS.h"
#include "Utils/BitFlags.hpp"

#if (defined(__aarch64__) || defined(__arm64__)) && !defined(STBI_NO_SIMD)
#define STBI_NEON
#endif
#define STB_IMAGE_IMPLEMENTATION
#include <stb_image.h>

#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <optional>
#include <span>
#include <string_view>

using namespace wallpaper;

enum class WPTexFlagEnum : uint32_t
{
    // true for no bilinear
    noInterpolation = 0,
    // true for no repeat
    clampUVs = 1,
    sprite   = 2,
    video    = 5,

    compo1 = 20,
    compo2 = 21,
    compo3 = 22,
    compo4 = 23
};
using WPTexFlags = BitFlags<WPTexFlagEnum>;

namespace
{
struct EmbeddedImageType
{
    ImageType type { ImageType::UNKNOWN };
    bool      isVideo { false };
};

struct LooseAssetCandidate
{
    std::string path;
    bool        isVideo { false };
    ImageType   imageType { ImageType::UNKNOWN };
    /// Where `path` has to be read from. A mounted path is absolute too —
    /// `/assets/materials/foo.png` — so the origin travels with the candidate
    /// rather than being guessed back out of the string.
    bool        isHost { false };
};

char* Lz4Decompress(const char* src, int size, int decompressed_size) {
    char* dst       = new char[(usize)decompressed_size];
    int   load_size = LZ4_decompress_safe(src, dst, size, decompressed_size);
    if (load_size < decompressed_size) {
        LOG_ERROR("lz4 decompress failed");
        delete[] dst;
        return nullptr;
    }
    return dst;
}

EmbeddedImageType DetectEmbeddedImageType(const unsigned char* data, usize size)
{
    if (size >= 8 && std::memcmp(data, "\x89PNG\r\n\x1a\n", 8) == 0) {
        return { ImageType::PNG, false };
    }
    if (size >= 3 && data[0] == 0xff && data[1] == 0xd8 && data[2] == 0xff) {
        return { ImageType::JPEG, false };
    }
    if (size >= 6 &&
        (std::memcmp(data, "GIF87a", 6) == 0 || std::memcmp(data, "GIF89a", 6) == 0)) {
        return { ImageType::GIF, false };
    }
    if (size >= 2 && data[0] == 'B' && data[1] == 'M') return { ImageType::BMP, false };
    if (size >= 4 &&
        ((data[0] == 'I' && data[1] == 'I' && data[2] == 0x2a && data[3] == 0x00) ||
         (data[0] == 'M' && data[1] == 'M' && data[2] == 0x00 && data[3] == 0x2a))) {
        return { ImageType::TIFF, false };
    }
    if (size >= 12 && std::memcmp(data + 4, "ftyp", 4) == 0) {
        return { ImageType::UNKNOWN, true };
    }
    if (size >= 4 && data[0] == 0x1a && data[1] == 0x45 &&
        data[2] == 0xdf && data[3] == 0xa3) {
        return { ImageType::UNKNOWN, true };
    }
    return {};
}

std::optional<std::vector<char>> ReadTexMipPayloadPrefix(
    fs::IBinaryStream& file,
    i32               src_size,
    usize             max_bytes)
{
    if (src_size <= 0) return std::nullopt;
    const idx payload_start = file.Tell();
    const idx remaining = file.Size() - payload_start;
    if (remaining < src_size) return std::nullopt;

    std::vector<char> payload(std::min<usize>(static_cast<usize>(src_size), max_bytes));
    if (!payload.empty()) {
        file.Read(payload.data(), payload.size());
    }
    file.SeekSet(payload_start + src_size);
    return payload;
}

std::optional<std::vector<char>> ReadTexMipPayload(
    fs::IBinaryStream& file,
    i32               src_size,
    usize             max_bytes)
{
    if (src_size <= 0 || static_cast<usize>(src_size) > max_bytes) return std::nullopt;
    const idx payload_start = file.Tell();
    const idx remaining = file.Size() - payload_start;
    if (remaining < src_size) return std::nullopt;

    std::vector<char> payload(static_cast<usize>(src_size));
    file.Read(payload.data(), payload.size());
    return payload;
}

TextureFormat ToTexFormate(int type) {
    /*
        type
        RGBA8888 = 0,
        DXT5 = 4,
        DXT3 = 6,
        DXT1 = 7,
        RG88 = 8,
        R8 = 9,
    */
    switch (type) {
    case 0: return TextureFormat::RGBA8;
    case 4: return TextureFormat::BC3;
    case 6: return TextureFormat::BC2;
    case 7: return TextureFormat::BC1;
    case 8: return TextureFormat::RG8;
    case 9: return TextureFormat::R8;
    default:
        LOG_ERROR("ERROR::ToTexFormate Unkown image type: %d", type);
        return TextureFormat::RGBA8;
    }
}
void LoadHeader(fs::IBinaryStream& file, ImageHeader& header) {
    header.extraHeader["texv"].val = ReadTexVesion(file);
    header.extraHeader["texi"].val = ReadTexVesion(file);

    header.format = ToTexFormate(file.ReadInt32());
    WPTexFlags flags(file.ReadUint32());
    {
        header.isSprite     = flags[WPTexFlagEnum::sprite];
        header.isVideo      = flags[WPTexFlagEnum::video];
        header.sample.wrapS = header.sample.wrapT =
            flags[WPTexFlagEnum::clampUVs] ? TextureWrap::CLAMP_TO_EDGE : TextureWrap::REPEAT;
        header.sample.minFilter = header.sample.magFilter =
            flags[WPTexFlagEnum::noInterpolation] ? TextureFilter::NEAREST : TextureFilter::LINEAR;
        // The reference builds the sampler of a file texture from these flags: with
        // `noInterpolation` it is point sampling for min, mag and the mip level.
        header.sample.mipFilter = header.sample.magFilter;
        header.extraHeader["compo1"].val = flags[WPTexFlagEnum::compo1];
        header.extraHeader["compo2"].val = flags[WPTexFlagEnum::compo2];
        header.extraHeader["compo3"].val = flags[WPTexFlagEnum::compo3];
        header.extraHeader["compo4"].val = flags[WPTexFlagEnum::compo4];
    }

    /*
        picture:
        width, height --> pow of 2 (tex size)
        mapw, maph    --> pic size
        mips
        mipw,miph     --> pow of 2

        sprites:
        width, height --> piece of sprite sheet
        mapw, maph    --> same
        1 mip
        mipw,mimp     --> tex size
    */

    header.width  = file.ReadInt32();
    header.height = file.ReadInt32();
    // in sprite this mean one pic
    header.mapWidth  = file.ReadInt32();
    header.mapHeight = file.ReadInt32();

    file.ReadInt32(); // unknown

    header.extraHeader["texb"].val = ReadTexVesion(file);

    header.count = file.ReadInt32();

    if (header.extraHeader["texb"].val >= 3) {
        header.type = static_cast<ImageType>(file.ReadInt32());
    }
    if (header.extraHeader["texb"].val >= 4) {
        header.extraHeader["texb_reserved"].val = file.ReadInt32();
    }
}

void SetHeaderPow2(ImageHeader& header, i32 mip_0_w, i32 mip_0_h) {
    header.mipmap_pow2   = algorism::IsPowOfTwo((u32)mip_0_w) || algorism::IsPowOfTwo((u32)mip_0_h);
    header.mipmap_larger = mip_0_w * mip_0_h > header.mapWidth * header.mapHeight;
}

std::string Lowercase(std::string value)
{
    std::transform(
        value.begin(),
        value.end(),
        value.begin(),
        [](const unsigned char ch) {
            return static_cast<char>(std::tolower(ch));
        });
    return value;
}

ImageType GuessImageTypeFromExtension(std::string_view extension)
{
    const std::string ext = Lowercase(std::string(extension));
    if (ext == ".png") return ImageType::PNG;
    if (ext == ".jpg" || ext == ".jpeg" || ext == ".jpe") return ImageType::JPEG;
    if (ext == ".bmp") return ImageType::BMP;
    if (ext == ".gif") return ImageType::GIF;
    if (ext == ".tga" || ext == ".targa") return ImageType::TARGA;
    if (ext == ".webp") return ImageType::UNKNOWN;
    return ImageType::UNKNOWN;
}

bool IsLooseImageExtension(std::string_view extension)
{
    const std::string ext = Lowercase(std::string(extension));
    return ext == ".png" || ext == ".jpg" || ext == ".jpeg" || ext == ".jpe" ||
           ext == ".bmp" || ext == ".gif" || ext == ".tga" || ext == ".targa" ||
           ext == ".webp";
}

bool IsLooseVideoExtension(std::string_view extension)
{
    const std::string ext = Lowercase(std::string(extension));
    return ext == ".mp4" || ext == ".m4v" || ext == ".mov" || ext == ".webm" ||
           ext == ".avi" || ext == ".mkv";
}

// A `scenetexture` property can name a picture the user picked from their own
// disk, which is an absolute path and reaches no VFS mount. It is resolved
// directly, and only as the loose picture or video it claims to be: no search,
// no extension guessing, no directory listing. Opening it is part of the
// question -- a file the user has since moved, or one a sandboxed process may
// not read, has to leave the slot on the wallpaper's own texture.
bool IsHostAssetPath(std::string_view name)
{
    const std::filesystem::path path { name };
    if (! path.is_absolute()) return false;
    const std::string extension = path.extension().string();
    if (! IsLooseImageExtension(extension) && ! IsLooseVideoExtension(extension)) return false;
    std::error_code ec;
    if (! std::filesystem::is_regular_file(path, ec)) return false;
    return static_cast<bool>(std::ifstream { path, std::ios::binary });
}

std::optional<LooseAssetCandidate> ResolveLooseAsset(fs::VFS& vfs, std::string_view name)
{
    if (IsHostAssetPath(name)) {
        const std::string extension = std::filesystem::path(name).extension().string();
        const bool        is_video  = IsLooseVideoExtension(extension);
        return LooseAssetCandidate {
            .path = std::string(name),
            .isVideo = is_video,
            .imageType = is_video ? ImageType::UNKNOWN : GuessImageTypeFromExtension(extension),
            .isHost = true,
        };
    }

    const std::array prefixes {
        std::string("/assets/materials/") + std::string(name),
        std::string("/assets/") + std::string(name),
    };

    for (const auto& prefix : prefixes) {
        const std::filesystem::path prefix_path(prefix);
        if (vfs.Contains(prefix)) {
            const std::string extension = prefix_path.extension().string();
            if (IsLooseImageExtension(extension)) {
                return LooseAssetCandidate {
                    .path = prefix,
                    .isVideo = false,
                    .imageType = GuessImageTypeFromExtension(extension),
                };
            }
            if (IsLooseVideoExtension(extension)) {
                return LooseAssetCandidate {
                    .path = prefix,
                    .isVideo = true,
                    .imageType = ImageType::UNKNOWN,
                };
            }
        }

        if (prefix_path.has_extension()) continue;

        for (const auto& extension : {
                 ".png",
                 ".jpg",
                 ".jpeg",
                 ".jpe",
                 ".bmp",
                 ".gif",
                 ".tga",
                 ".targa",
                 ".webp",
                 ".mp4",
                 ".m4v",
                 ".mov",
                 ".webm",
                 ".avi",
                 ".mkv",
             }) {
            const std::string candidate = prefix + extension;
            if (!vfs.Contains(candidate)) continue;
            if (IsLooseImageExtension(extension)) {
                return LooseAssetCandidate {
                    .path = candidate,
                    .isVideo = false,
                    .imageType = GuessImageTypeFromExtension(extension),
                };
            }
            return LooseAssetCandidate {
                .path = candidate,
                .isVideo = true,
                .imageType = ImageType::UNKNOWN,
            };
        }
    }

    return std::nullopt;
}

std::optional<std::vector<char>> LoadLooseAssetPayload(fs::VFS& vfs,
                                                       const LooseAssetCandidate& candidate)
{
    if (candidate.isHost) {
        std::ifstream file { std::filesystem::path(candidate.path), std::ios::binary };
        if (! file) return std::nullopt;
        return std::vector<char>(std::istreambuf_iterator<char>(file),
                                 std::istreambuf_iterator<char>());
    }

    auto stream = vfs.Open(candidate.path);
    if (!stream) return std::nullopt;

    const std::string payload = stream->ReadAllStr();
    return std::vector<char>(payload.begin(), payload.end());
}

std::filesystem::path WriteVideoPayloadToTemp(
    std::string_view         debug_label,
    std::string_view         extension,
    std::span<const char>    payload)
{
    if (payload.empty()) return {};

    std::error_code ec;
    const auto temp_dir = std::filesystem::temp_directory_path(ec) / "wallpaper-engine-video";
    if (ec) return {};
    std::filesystem::create_directories(temp_dir, ec);
    if (ec) return {};

    const std::string ext = extension.empty() ? ".mp4" : std::string(extension);
    const auto temp_path =
        temp_dir / (utils::genSha1(payload) + ext);
    if (std::filesystem::exists(temp_path, ec) &&
        !ec &&
        std::filesystem::file_size(temp_path, ec) == static_cast<uintmax_t>(payload.size())) {
        return temp_path;
    }

    std::ofstream output(temp_path, std::ios::binary | std::ios::trunc);
    if (!output.good()) return {};
    output.write(payload.data(), static_cast<std::streamsize>(payload.size()));
    output.close();
    if (!output.good()) return {};

    LOG_INFO("prepared FFmpeg video payload cache for \"%s\": %s",
             std::string(debug_label).c_str(),
             temp_path.string().c_str());
    return temp_path;
}

std::optional<video::VideoMetadata> ProbeVideoMetadataFromPayload(
    std::string_view      debug_label,
    std::string_view      extension,
    std::span<const char> payload)
{
    const auto temp_path = WriteVideoPayloadToTemp(debug_label, extension, payload);
    if (temp_path.empty()) return std::nullopt;

    video::VideoMetadata metadata;
    std::string          error;
    if (!video::ProbeVideoFileMetadata(temp_path.string(), &metadata, &error)) {
        LOG_ERROR("failed to probe video metadata for \"%s\": %s",
                  std::string(debug_label).c_str(),
                  error.c_str());
        return std::nullopt;
    }
    return metadata;
}

std::optional<std::vector<char>> LoadHeaderVideoPayload(
    fs::IBinaryStream& file,
    i32               src_size,
    bool              lz4_compressed,
    int32_t           decompressed_size)
{
    constexpr usize kMaxHeaderVideoProbeBytes = 64 * 1024 * 1024;
    auto payload = ReadTexMipPayload(file, src_size, kMaxHeaderVideoProbeBytes);
    if (!payload.has_value()) return std::nullopt;
    if (!lz4_compressed) return payload;
    if (decompressed_size <= 0 ||
        static_cast<usize>(decompressed_size) > kMaxHeaderVideoProbeBytes) {
        return std::nullopt;
    }
    char* decompressed = Lz4Decompress(payload->data(), src_size, decompressed_size);
    if (decompressed == nullptr) return std::nullopt;
    std::vector<char> out(
        decompressed,
        decompressed + static_cast<usize>(decompressed_size));
    delete[] decompressed;
    return out;
}

ImageHeader BuildLooseAssetHeader(
    int32_t width,
    int32_t height,
    bool    is_video,
    ImageType image_type,
    double duration_seconds = 0.0)
{
    ImageHeader header;
    header.width = width;
    header.height = height;
    header.mapWidth = width;
    header.mapHeight = height;
    header.count = 1;
    header.isVideo = is_video;
    header.videoAudioEnabled = false;
    header.durationSeconds = duration_seconds;
    header.type = image_type;
    header.format = TextureFormat::RGBA8;
    header.sample.wrapS = TextureWrap::CLAMP_TO_EDGE;
    header.sample.wrapT = TextureWrap::CLAMP_TO_EDGE;
    header.sample.minFilter = TextureFilter::LINEAR;
    header.sample.magFilter = TextureFilter::LINEAR;
    header.extraHeader["compo1"].val = 1;
    header.extraHeader["compo2"].val = 1;
    header.extraHeader["compo3"].val = 1;
    header.extraHeader["compo4"].val = 1;
    SetHeaderPow2(header, width, height);
    return header;
}

// The longest side of the level after the one whose payload of `payload_size`
// bytes starts at the stream's position. Its header follows that payload (width
// and height come first in every container version), so it is read ahead
// without moving the stream; 0 when the file ends before it.
uint64_t NextLevelLongestSide(fs::IBinaryStream& file, i32 payload_size) {
    const auto at = file.Tell();
    if (! file.SeekSet(at + payload_size)) return 0;
    const i32 width  = file.ReadInt32();
    const i32 height = file.ReadInt32();
    file.SeekSet(at);
    return uint64_t(std::max<i32>(std::max(width, height), 0));
}

} // namespace

bool wallpaper::HostLooseAssetIsReadable(std::string_view name) { return IsHostAssetPath(name); }

std::shared_ptr<Image> WPTexImageParser::Parse(const std::string& name) {
    // A picture of the user's own is not in the package, and probing the mount
    // for it logs a missing-file error for every slot on every load.
    if (IsHostAssetPath(name)) return ParseLooseAsset(name);
    std::string            path    = "/assets/materials/" + name + ".tex";
    std::shared_ptr<Image> img_ptr = std::make_shared<Image>();
    auto&                  img     = *img_ptr;
    img.key                        = name;
    // std::ifstream file = fs::GetFileFstream(vfs, path);
    auto pfile = m_vfs->Open(path);
    if (! pfile) return ParseLooseAsset(name);
    auto& file     = *pfile;
    auto  startpos = file.Tell();
    LoadHeader(file, img.header);

    // image
    i32 _image_count = img.header.count;
    if (_image_count < 0) return nullptr;
    usize image_count = (usize)_image_count;

    img.slots.resize(image_count);
    for (usize i_image = 0; i_image < image_count; i_image++) {
        auto& img_slot = img.slots[i_image];
        auto& mipmaps  = img_slot.mipmaps;

        usize mipmap_count = (usize)std::max<i32>(file.ReadInt32(), 0);
        mipmaps.resize(mipmap_count);
        usize first_mip = 0;
        // Use the authored mip chain, without decoding or uploading discarded
        // levels. Atlases, videos and unknown containers keep their full layout.
        const bool limit_mips = m_texture_surface_longest_side != 0 && image_count == 1 &&
            !img.header.isSprite && !img.header.isVideo &&
            (img.header.extraHeader["texb"].val < 3 || img.header.type != ImageType::UNKNOWN);
        // load image
        for (usize i_mipmap = 0; i_mipmap < mipmap_count; i_mipmap++) {
            auto& mipmap  = mipmaps.at(i_mipmap);
            mipmap.width  = file.ReadInt32();
            mipmap.height = file.ReadInt32();
            if (i_mipmap == 0) {
                img_slot.width  = mipmap.width;
                img_slot.height = mipmap.height;
                SetHeaderPow2(img.header, mipmap.width, mipmap.height);
            }

            bool    LZ4_compressed    = false;
            int32_t decompressed_size = 0;
            // check compress
            if (img.header.extraHeader["texb"].val > 1) {
                LZ4_compressed    = file.ReadInt32() == 1;
                decompressed_size = file.ReadInt32();
            }

            i32 src_size = file.ReadInt32();
            if (src_size <= 0 || mipmap.width <= 0 || mipmap.height <= 0 || decompressed_size < 0)
                return nullptr;
            if (src_size > file.Size() - file.Tell()) return nullptr;
            // Drop a leading level only while the next still covers the surface,
            // so what is kept is never magnified to fill it.
            if (limit_mips && i_mipmap == first_mip && i_mipmap + 1 < mipmap_count &&
                NextLevelLongestSide(file, src_size) >= m_texture_surface_longest_side) {
                file.SeekSet(file.Tell() + src_size);
                ++first_mip;
                continue;
            }

            char* result;
            result = new char[(usize)src_size];
            file.Read(result, (usize)src_size);

            // is LZ4 compress
            if (LZ4_compressed) {
                char* decompressed_char = Lz4Decompress(result, src_size, decompressed_size);
                src_size                = decompressed_size;
                if (decompressed_char != nullptr) {
                    delete[] result;
                    result = decompressed_char;
                } else {
                    LOG_ERROR("lz4 decompress failed");
                    delete[] result;
                    return nullptr;
                }
            }
            EmbeddedImageType embedded { img.header.type, img.header.isVideo };
            if (img.header.extraHeader["texb"].val >= 3 &&
                img.header.type == ImageType::UNKNOWN) {
                embedded = DetectEmbeddedImageType(
                    reinterpret_cast<const unsigned char*>(result),
                    static_cast<usize>(src_size));
                img.header.type = embedded.type;
                if (embedded.isVideo) img.header.isVideo = true;
            }

            // is image container
            if (img.header.extraHeader["texb"].val >= 3 && !img.header.isVideo &&
                embedded.type != ImageType::UNKNOWN) {
                int32_t w, h, n;
                auto*   data =
                    stbi_load_from_memory((const unsigned char*)result, src_size, &w, &h, &n, 4);
                if (data == nullptr || w <= 0 || h <= 0) {
                    LOG_ERROR("stbi decode failed");
                    delete[] result;
                    return nullptr;
                }
                OrientRGBA(data, w, h, JpegOrientation(std::span(
                    reinterpret_cast<const uint8_t*>(result), static_cast<size_t>(src_size))));
                mipmap.data = ImageDataPtr((uint8_t*)data, [](uint8_t* data) {
                    stbi_image_free((unsigned char*)data);
                });
                mipmap.width  = w;
                mipmap.height = h;
                if (i_mipmap == 0) {
                    img_slot.width  = w;
                    img_slot.height = h;
                    SetHeaderPow2(img.header, w, h);
                }
                img.header.format = TextureFormat::RGBA8;
                src_size    = w * h * 4;
            } else {
                mipmap.data = ImageDataPtr(new uint8_t[(usize)src_size], [](uint8_t* data) {
                    delete[] data;
                });
                std::copy(result, result + src_size, mipmap.data.get());
                if (img.header.isVideo && i_image == 0 && i_mipmap == 0) {
                    const auto metadata = ProbeVideoMetadataFromPayload(
                        name,
                        ".mp4",
                        std::span(result, static_cast<std::size_t>(src_size)));
                    if (metadata.has_value()) {
                        img.header.durationSeconds = metadata->duration_seconds;
                    }
                }
            }
            mipmap.size = src_size * (i32)sizeof(uint8_t);
            delete[] result;
        }
        if (first_mip != 0) {
            mipmaps.erase(mipmaps.begin(), mipmaps.begin() + first_mip);
            img_slot.width = mipmaps.front().width;
            img_slot.height = mipmaps.front().height;
        }
    }
    return img_ptr;
}

ImageHeader WPTexImageParser::ParseHeader(const std::string& name) {
    if (IsHostAssetPath(name)) return ParseLooseAssetHeader(name);
    ImageHeader header;
    std::string path  = "/assets/materials/" + name + ".tex";
    auto        pfile = m_vfs->Open(path);
    if (! pfile) return ParseLooseAssetHeader(name);
    auto& file = *pfile;

    LoadHeader(file, header);
    if (header.count < 0) return header;

    usize image_count = (usize)header.count;

    // load sprite info
    if (header.isSprite) {
        // bypass image data, store width and height
        std::vector<std::vector<float>> imageDatas(image_count);
        for (usize i_image = 0; i_image < image_count; i_image++) {
            int mipmap_count = file.ReadInt32();
            for (int32_t i_mipmap = 0; i_mipmap < mipmap_count; i_mipmap++) {
                int32_t width  = file.ReadInt32();
                int32_t height = file.ReadInt32();
                if (i_mipmap == 0) {
                    imageDatas.at(i_image) = { (float)width, (float)height };
                    header.mipmap_pow2     = algorism::IsPowOfTwo((u32)(width * height));
                }
                if (header.extraHeader["texb"].val > 1) {
                    int32_t LZ4_compressed    = file.ReadInt32();
                    int32_t decompressed_size = file.ReadInt32();
                    (void)LZ4_compressed;
                    (void)decompressed_size;
                }
                long src_size = file.ReadInt32();
                file.SeekCur(src_size);
            }
        }
        // sprite pos
        int32_t texs       = ReadTexVesion(file);
        int32_t framecount = file.ReadInt32();
        if (texs > 3) {
            LOG_ERROR("Unkown texs version");
        }
        if (texs == 3) {
            i32 width  = file.ReadInt32();
            i32 height = file.ReadInt32();
            (void)width;
            (void)height;
        }

        for (int32_t i = 0; i < framecount; i++) {
            SpriteFrame sf;
            sf.imageId = file.ReadInt32();
            const auto bad_image_id =
                sf.imageId < 0 ||
                static_cast<usize>(sf.imageId) >= imageDatas.size() ||
                imageDatas[static_cast<usize>(sf.imageId)].size() < 2;
            if (bad_image_id) {
                LOG_ERROR("invalid sprite image id: %d", sf.imageId);
                file.ReadFloat();
                for (int j = 0; j < 6; ++j) {
                    if (texs == 1) file.ReadInt32();
                    else file.ReadFloat();
                }
                continue;
            }
            float spriteWidth  = imageDatas[static_cast<usize>(sf.imageId)][0];
            float spriteHeight = imageDatas[static_cast<usize>(sf.imageId)][1];

            sf.frametime = file.ReadFloat();
            if (texs == 1) {
                sf.x        = (float)file.ReadInt32() / spriteWidth;
                sf.y        = (float)file.ReadInt32() / spriteHeight;
                sf.xAxis[0] = (float)file.ReadInt32();
                sf.xAxis[1] = (float)file.ReadInt32();
                sf.yAxis[0] = (float)file.ReadInt32();
                sf.yAxis[1] = (float)file.ReadInt32();
            } else {
                sf.x        = file.ReadFloat() / spriteWidth;
                sf.y        = file.ReadFloat() / spriteHeight;
                sf.xAxis[0] = file.ReadFloat();
                sf.xAxis[1] = file.ReadFloat();
                sf.yAxis[0] = file.ReadFloat();
                sf.yAxis[1] = file.ReadFloat();
            }
            sf.width  = (float)std::sqrt(std::pow(sf.xAxis[0], 2) + std::pow(sf.xAxis[1], 2));
            sf.height = (float)std::sqrt(std::pow(sf.yAxis[0], 2) + std::pow(sf.yAxis[1], 2));
            sf.xAxis[0] /= spriteWidth;
            sf.xAxis[1] /= spriteWidth;
            sf.yAxis[0] /= spriteHeight;
            sf.yAxis[1] /= spriteHeight;
            sf.rate = sf.height / sf.width;
            header.spriteAnim.AppendFrame(sf);
        }
    } else {
        i32 mipmap_count = file.ReadInt32();
        if (mipmap_count <= 0) return header;
        i32 width  = file.ReadInt32();
        i32 height = file.ReadInt32();
        SetHeaderPow2(header, width, height);
        if (header.extraHeader["texb"].val >= 3 && header.type == ImageType::UNKNOWN &&
            !header.isVideo) {
            bool    lz4_compressed = false;
            int32_t decompressed_size = 0;
            if (header.extraHeader["texb"].val > 1) {
                lz4_compressed = file.ReadInt32() == 1;
                decompressed_size = file.ReadInt32();
            }
            i32 src_size = file.ReadInt32();
            std::optional<std::vector<char>> sniff_payload;
            if (!lz4_compressed) {
                sniff_payload = ReadTexMipPayloadPrefix(file, src_size, 64);
            } else {
                file.SeekCur(src_size);
            }
            if (sniff_payload.has_value()) {
                const auto embedded = DetectEmbeddedImageType(
                    reinterpret_cast<const unsigned char*>(sniff_payload->data()),
                    sniff_payload->size());
                if (embedded.type != ImageType::UNKNOWN) header.type = embedded.type;
                if (embedded.isVideo) header.isVideo = true;
                if (embedded.isVideo) {
                    const idx payload_start = file.Tell() - src_size;
                    file.SeekSet(payload_start);
                    auto video_payload = LoadHeaderVideoPayload(
                        file,
                        src_size,
                        lz4_compressed,
                        decompressed_size);
                    if (video_payload.has_value()) {
                        const auto metadata = ProbeVideoMetadataFromPayload(
                            name,
                            ".mp4",
                            std::span(video_payload->data(), video_payload->size()));
                        if (metadata.has_value()) {
                            header.durationSeconds = metadata->duration_seconds;
                        }
                    }
                }
            }
            return header;
        }
        if (header.isVideo && mipmap_count > 0) {
            bool    lz4_compressed = false;
            int32_t decompressed_size = 0;
            if (header.extraHeader["texb"].val > 1) {
                lz4_compressed = file.ReadInt32() == 1;
                decompressed_size = file.ReadInt32();
            }
            i32 src_size = file.ReadInt32();
            if (src_size > 0) {
                std::vector<char> payload(static_cast<std::size_t>(src_size));
                file.Read(payload.data(), static_cast<usize>(src_size));
                std::span<const char> video_bytes(payload.data(), payload.size());
                std::unique_ptr<char[]> decompressed_storage;
                if (lz4_compressed && decompressed_size > 0) {
                    char* decompressed = Lz4Decompress(payload.data(), src_size, decompressed_size);
                    if (decompressed != nullptr) {
                        decompressed_storage.reset(decompressed);
                        video_bytes = std::span<const char>(decompressed_storage.get(),
                                                            static_cast<std::size_t>(decompressed_size));
                    }
                }
                const auto metadata = ProbeVideoMetadataFromPayload(name, ".mp4", video_bytes);
                if (metadata.has_value()) {
                    header.durationSeconds = metadata->duration_seconds;
                }
            }
        }
    }
    return header;
}

std::shared_ptr<Image> WPTexImageParser::ParseLooseAsset(const std::string& name)
{
    const auto candidate = ResolveLooseAsset(*m_vfs, name);
    if (!candidate.has_value()) return nullptr;

    const auto payload = LoadLooseAssetPayload(*m_vfs, *candidate);
    if (!payload.has_value() || payload->empty()) return nullptr;

    auto image = std::make_shared<Image>();
    image->key = name;

    if (candidate->isVideo) {
        const auto metadata = ProbeVideoMetadataFromPayload(
            name,
            std::filesystem::path(candidate->path).extension().string(),
            std::span(payload->data(), payload->size()));
        if (!metadata.has_value()) return nullptr;

        image->header = BuildLooseAssetHeader(
            static_cast<int32_t>(metadata->width),
            static_cast<int32_t>(metadata->height),
            true,
            ImageType::UNKNOWN,
            metadata->duration_seconds);

        Image::Slot slot;
        slot.width = static_cast<int32_t>(metadata->width);
        slot.height = static_cast<int32_t>(metadata->height);

        ImageData mip;
        mip.width = slot.width;
        mip.height = slot.height;
        mip.size = static_cast<isize>(payload->size());
        mip.data = ImageDataPtr(new uint8_t[payload->size()], [](uint8_t* data) {
            delete[] data;
        });
        std::copy(payload->begin(), payload->end(), reinterpret_cast<char*>(mip.data.get()));
        slot.mipmaps.push_back(std::move(mip));
        image->slots.push_back(std::move(slot));
        return image;
    }

    int width = 0;
    int height = 0;
    int channels = 0;
    unsigned char* decoded = stbi_load_from_memory(
        reinterpret_cast<const unsigned char*>(payload->data()),
        static_cast<int>(payload->size()),
        &width,
        &height,
        &channels,
        4);
    if (decoded == nullptr || width <= 0 || height <= 0) {
        if (decoded != nullptr) stbi_image_free(decoded);
        return nullptr;
    }

    OrientRGBA(decoded, width, height, JpegOrientation(std::span(
        reinterpret_cast<const uint8_t*>(payload->data()), payload->size())));
    image->header = BuildLooseAssetHeader(
        width,
        height,
        false,
        candidate->imageType);

    Image::Slot slot;
    slot.width = width;
    slot.height = height;

    ImageData mip;
    mip.width = width;
    mip.height = height;
    mip.size = static_cast<isize>(width * height * 4);
    mip.data = ImageDataPtr(reinterpret_cast<uint8_t*>(decoded), [](uint8_t* data) {
        stbi_image_free(data);
    });
    slot.mipmaps.push_back(std::move(mip));
    image->slots.push_back(std::move(slot));
    return image;
}

ImageHeader WPTexImageParser::ParseLooseAssetHeader(const std::string& name)
{
    const auto candidate = ResolveLooseAsset(*m_vfs, name);
    if (!candidate.has_value()) return {};

    const auto payload = LoadLooseAssetPayload(*m_vfs, *candidate);
    if (!payload.has_value() || payload->empty()) return {};

    if (candidate->isVideo) {
        const auto metadata = ProbeVideoMetadataFromPayload(
            name,
            std::filesystem::path(candidate->path).extension().string(),
            std::span(payload->data(), payload->size()));
        if (!metadata.has_value()) return {};
        return BuildLooseAssetHeader(
            static_cast<int32_t>(metadata->width),
            static_cast<int32_t>(metadata->height),
            true,
            ImageType::UNKNOWN,
            metadata->duration_seconds);
    }

    int width = 0;
    int height = 0;
    int channels = 0;
    if (stbi_info_from_memory(
            reinterpret_cast<const unsigned char*>(payload->data()),
            static_cast<int>(payload->size()),
            &width,
            &height,
            &channels) == 0 ||
        width <= 0 ||
        height <= 0) {
        return {};
    }

    if (JpegOrientation(std::span(reinterpret_cast<const uint8_t*>(payload->data()),
                                  payload->size())) >= 5) std::swap(width, height);
    return BuildLooseAssetHeader(width, height, false, candidate->imageType);
}
