// Clean-room implementation from the WallpaperMachine spec p6-textures-packages.md; written without access to the original source.
#include "WPTexImageParser.hpp"
#include "ImageOrientation.hpp"

#include "Type.hpp"
#include "Video/VideoContainerProbe.hpp"
#include "Video/VideoTextureSource.hpp"
#include "WPCommon.hpp"
#include "WPTextureFormats.hpp"
#include <nlohmann/json.hpp>
#include <unordered_map>
#include <cstdint>
#include <lz4.h>

#include "SpriteAnimation.hpp"
#include "Utils/Algorism.h"
#include "Fs/VFS.h"
#include "Utils/BitFlags.hpp"
#include "Fs/CBinaryStream.h"
#include "Media/ByteSource.hpp"
#include "WPVideoCache.hpp"

#if (defined(__aarch64__) || defined(__arm64__)) && !defined(STBI_NO_SIMD)
#define STBI_NEON
#endif
// Only the formats a wallpaper's pictures come in are decoded: whatever else stb_image reads
// (PSD, PIC, PNM, HDR) is code a crafted file could reach and no texture needs.
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#define STBI_ONLY_BMP
#define STBI_ONLY_GIF
#define STBI_ONLY_TGA
// No GPU texture is wider or taller than this, so a picture that is is refused before its
// pixels are allocated.
#define STBI_MAX_DIMENSIONS 16384
#define STB_IMAGE_IMPLEMENTATION
#include <stb_image.h>

#include <algorithm>
#include <array>
#include <climits>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <mutex>
#include <optional>
#include <span>
#include <string_view>
#include <utility>
#include <vector>

using namespace wallpaper;

namespace
{
constexpr std::array<std::string_view, 9> kImageExtensions { "png", "jpg", "jpeg", "jpe", "bmp",
                                                            "gif", "tga", "targa", "webp" };
constexpr std::array<std::string_view, 6> kVideoExtensions { "mp4", "m4v", "mov", "webm", "avi", "mkv" };

// `extension` carries its leading dot; the comparison ignores ASCII case.
bool ExtensionIn(std::string_view extension, std::span<const std::string_view> list)
{
    if (extension.size() < 2 || extension.front() != '.') return false;
    extension.remove_prefix(1);
    return std::any_of(list.begin(), list.end(), [&](std::string_view known) {
        return known.size() == extension.size() &&
               std::equal(known.begin(), known.end(), extension.begin(), [](char a, char b) {
                   return a == (b >= 'A' && b <= 'Z' ? static_cast<char>(b - 'A' + 'a') : b);
               });
    });
}

bool IsLooseImageExtension(std::string_view extension)
{
    return ExtensionIn(extension, kImageExtensions);
}

bool IsLooseVideoExtension(std::string_view extension)
{
    return ExtensionIn(extension, kVideoExtensions);
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

// ---- the .tex container ------------------------------------------------------

constexpr u32 kFlagPoint  = 1u << 0;
constexpr u32 kFlagClamp  = 1u << 1;
constexpr u32 kFlagSprite = 1u << 2;
constexpr u32 kFlagVideo  = 1u << 5;
// A volume: TEXI and every level header carry a slice count (`sub_14015C760`,
// `sub_14015C8D0`, WE 2.8.0.42). The shipped colour-grading LUTs are 32x32x32 volumes.
constexpr u32 kFlagVolume = 1u << 6;
constexpr int kFirstComponentBit = 20;
// The reference refuses a level beyond these (`Invalid texture resolution`, `sub_14015C8D0`).
constexpr i32 kMaxSide  = 0x2000;
constexpr i32 kMaxDepth = 0x80;

// Largest level a compressed block may expand to, unless the format needs more.
constexpr i64 kExpandCeiling = i64 { 1 } << 30;
// A block-compressed level can never expand by more than this factor.
constexpr i64 kLz4MaxRatio = 255;
// What the description reads of a payload to recognise it.
constexpr i64 kSniffBytes = 64;
// How much of a loose JPEG is searched for its orientation.
constexpr i64 kOrientationWindow = i64 { 1 } << 20;

// A variant patch flag: blend the patch over the level by its alpha instead of copying it.
constexpr u32 kPatchBlend = 1u << 0;
// A variant patch flag: the patch's bytes replace the whole level.
constexpr u32 kPatchReplace = 1u << 1;

// One record of a TEXB0004 variant table: when its condition holds, every level patch whose
// id is `key` is applied with the flags `value`.
struct VariantRecord {
    i32         id { 0 };
    i32         key { 0 };
    u32         value { 0 };
    std::string json;
};

struct Container {
    int texv { 0 };
    int texi { 0 };
    int texb { 0 };

    i32 formatCode { 0 };
    u32 flags { 0 };
    i32 textureWidth { 0 };
    i32 textureHeight { 0 };
    i32 imageWidth { 0 };
    i32 imageHeight { 0 };
    i32 depth { 1 };

    i32  pictures { 0 };
    i32  imageType { -1 }; // FreeImage id, -1 when none is declared

    std::vector<VariantRecord>                   variants;
    std::unordered_map<i32, u32>                 patchFlags; // chosen patch id -> flags
    std::unordered_map<std::string, std::string> choices;

    const WeTextureFormat* row { nullptr };
    TextureFormat          format { TextureFormat::RGBA8 };

    bool sprite() const { return (flags & kFlagSprite) != 0; }
    bool video() const { return (flags & kFlagVideo) != 0; }
    bool volume() const { return (flags & kFlagVolume) != 0; }
    bool declaresPicture() const { return texb >= 3 && imageType != -1; }
};

i64 BytesLeft(const fs::IBinaryStream& file) { return file.Size() - file.Tell(); }

// A nine-byte stamp: `TEX`, the expected fourth letter, four digits and (when
// asked) a NUL. The version, or -1 when the bytes are anything else.
int ReadStamp(fs::IBinaryStream& file, char letter, bool needNul)
{
    std::array<char, 9> stamp {};
    if (file.Read(stamp.data(), stamp.size()) != stamp.size()) return -1;
    if (std::memcmp(stamp.data(), "TEX", 3) != 0 || stamp[3] != letter) return -1;
    if (needNul && stamp[8] != '\0') return -1;
    int version = 0;
    for (std::size_t i = 4; i < 8; ++i) {
        if (stamp[i] < '0' || stamp[i] > '9') return -1;
        version = version * 10 + (stamp[i] - '0');
    }
    return version;
}

// Bytes up to a NUL, which is consumed. False when the file ends first.
bool ReadCString(fs::IBinaryStream& file, std::string& out)
{
    out.clear();
    while (BytesLeft(file) > 0) {
        char c = 0;
        if (file.Read(&c, 1) != 1) return false;
        if (c == '\0') return true;
        out.push_back(c);
    }
    return false;
}

// Evaluates the variant records as `sub_14015C8D0` does. The JSON is
// `{"condition": "<name>"}` (asks whether the name is set) or
// `{"condition": {"name": ..., "condition": ...}}`. The first holding record of an id
// chooses its key's patch flags.
void ChooseVariants(Container& c, const IImageParser::VariantCondition& holds)
{
    std::unordered_map<i32, bool> seen;
    for (const auto& record : c.variants) {
        const auto json = nlohmann::json::parse(record.json, nullptr, false);
        if (json.is_discarded() || ! json.is_object()) continue;
        const auto cond = json.find("condition");
        if (cond == json.end()) continue;
        bool held = false;
        if (cond->is_string()) {
            const std::string name = cond->get<std::string>();
            held                   = holds && holds(name, {});
            c.choices[name]        = held ? "1" : "0";
        } else if (cond->is_object()) {
            const auto name  = cond->find("name");
            const auto value = cond->find("condition");
            if (name == cond->end() || value == cond->end() || ! name->is_string() || ! value->is_string())
                continue;
            const std::string key = name->get<std::string>();
            const std::string want = value->get<std::string>();
            held = holds && holds(key, want);
            if (held) c.choices[key] = want;
            else c.choices.try_emplace(key, "$__default");
        } else {
            continue;
        }
        if (held && seen.emplace(record.id, true).second) c.patchFlags[record.key] = record.value;
    }
}

// Reads the fixed part of the container. False (with the reason logged) for a
// file that is not a texture this reader understands.
bool ReadContainer(fs::IBinaryStream& file, Container& c, const IImageParser::VariantCondition& holds)
{
    c.texv = ReadStamp(file, 'V', false);
    c.texi = ReadStamp(file, 'I', false);
    if (c.texv < 0 || c.texi < 0) {
        LOG_ERROR("texture: the stamps are not TEXV and TEXI");
        return false;
    }
    // format, flags and four sizes (`sub_14015C760`); then a slice count for a volume and a
    // colour from TEXI0001 on; then the TEXB stamp.
    if (BytesLeft(file) < 4 * 6) {
        LOG_ERROR("texture: the header is cut short");
        return false;
    }
    c.formatCode    = file.ReadInt32();
    c.flags         = file.ReadUint32();
    c.textureWidth  = file.ReadInt32();
    c.textureHeight = file.ReadInt32();
    c.imageWidth    = file.ReadInt32();
    c.imageHeight   = file.ReadInt32();
    if (BytesLeft(file) < (c.volume() ? 4 : 0) + (c.texi >= 1 ? 4 : 0) + 9) {
        LOG_ERROR("texture: the header is cut short");
        return false;
    }
    if (c.volume()) c.depth = file.ReadInt32();
    if (c.texi >= 1) file.ReadInt32(); // a packed colour that nothing needs
    if (c.depth < 1 || c.depth > kMaxDepth) {
        LOG_ERROR("texture: the slice count %d is not usable", c.depth);
        return false;
    }
    c.texb = ReadStamp(file, 'B', true);
    if (c.texb < 1) {
        LOG_ERROR("texture: no TEXB stamp where one belongs");
        return false;
    }
    if (c.texb > 4) LOG_INFO("texture: TEXB%04d is newer than any known, read as TEXB0004", c.texb);
    const i64 more = 4 + (c.texb >= 3 ? 4 : 0) + (c.texb >= 4 ? 4 : 0);
    if (BytesLeft(file) < more) {
        LOG_ERROR("texture: the header is cut short");
        return false;
    }
    c.pictures = file.ReadInt32();
    if (c.texb >= 3) c.imageType = file.ReadInt32();
    if (c.texb >= 4) {
        const u32 count = file.ReadUint32();
        // Three numbers and at least a NUL each.
        if (count > static_cast<u64>(BytesLeft(file)) / 13) {
            LOG_ERROR("texture: the variant count is not usable");
            return false;
        }
        c.variants.resize(count);
        for (auto& record : c.variants) {
            record.id    = file.ReadInt32();
            record.key   = file.ReadInt32();
            record.value = file.ReadUint32();
            if (! ReadCString(file, record.json)) {
                LOG_ERROR("texture: a variant record does not end");
                return false;
            }
        }
        ChooseVariants(c, holds);
    }
    c.row = WeFormatOfCode(c.formatCode);
    if (c.row == nullptr) {
        LOG_ERROR("texture: unknown pixel format code %d", c.formatCode);
        return false;
    }
    c.format = c.row->upload;
    return true;
}

ImageType DeclaredType(const Container& c)
{
    if (! c.declaresPicture() || c.imageType < 0 || c.imageType > 34) return ImageType::UNKNOWN;
    return static_cast<ImageType>(c.imageType);
}

// What the container header alone says: sizes, sampler, flags, stamps.
ImageHeader HeaderOf(const Container& c)
{
    ImageHeader h;
    h.width     = c.textureWidth;
    h.height    = c.textureHeight;
    h.mapWidth  = c.imageWidth;
    h.mapHeight = c.imageHeight;
    h.depth     = c.depth;
    h.count     = c.pictures;
    h.format    = c.format;
    // A declared picture is decoded to RGBA8 before the shader sees it.
    h.formatCode = c.declaresPicture() || c.video() ? 0 : c.formatCode;
    h.type      = DeclaredType(c);
    h.isSprite  = c.sprite();
    h.isVideo   = c.video();
    h.variantChoices = c.choices;

    const TextureFilter filter = (c.flags & kFlagPoint) != 0 ? TextureFilter::NEAREST : TextureFilter::LINEAR;
    h.sample.minFilter         = filter;
    h.sample.magFilter         = filter;
    h.sample.mipFilter         = filter;
    const TextureWrap wrap     = (c.flags & kFlagClamp) != 0 ? TextureWrap::CLAMP_TO_EDGE : TextureWrap::REPEAT;
    h.sample.wrapS             = wrap;
    h.sample.wrapT             = wrap;
    // A texture loaded from a file filters anisotropically, 8x, unless it point-samples
    // (Wallpaper Engine's sampler builder `sub_140099980`: filter 0x55 with MaxAnisotropy 8 for
    // textures `sub_1400EC220` loads; engine-made ones, render targets and clips, filter linearly).
    h.sample.maxAnisotropy = ((c.flags & kFlagPoint) != 0 || c.video()) ? 1 : 8;

    h.extraHeader["texv"].val = c.texv;
    h.extraHeader["texi"].val = c.texi;
    h.extraHeader["texb"].val = c.texb;
    for (int i = 0; i < 4; ++i) {
        h.extraHeader["compo" + std::to_string(i + 1)].val =
            (c.flags >> (kFirstComponentBit + i)) & 1u ? 1 : 0;
    }
    return h;
}

// The first level of the first picture, as it was authored, decides whether the
// texture is padded; the product is taken in 64 bits.
void NoteFirstLevel(ImageHeader& h, i32 width, i32 height)
{
    h.mipmap_larger = h.mapWidth > 0 && h.mapHeight > 0 && width > 0 && height > 0 &&
                      i64 { width } * height > i64 { h.mapWidth } * h.mapHeight;
    h.mipmap_pow2 = width > 0 && height > 0 && algorism::IsPowOfTwo(static_cast<u32>(width)) &&
                    algorism::IsPowOfTwo(static_cast<u32>(height));
}

// ---- levels ---------------------------------------------------------------

// A rectangle of a variant, kept when its id was chosen.
struct LevelPatch {
    u32   flags { 0 };
    i32   format { 0 };
    i32   x { 0 }, y { 0 }, width { 0 }, height { 0 };
    std::vector<uint8_t> bytes;
};

struct LevelHead {
    i32  width { 0 };
    i32  height { 0 };
    i32  depth { 1 };
    bool compressed { false };
    i32  expanded { 0 };
    i32  stored { 0 };
};

// The fields of one level header; false when the file ends inside them.
bool ReadLevelHead(fs::IBinaryStream& file, const Container& c, LevelHead& head)
{
    if (BytesLeft(file) < (c.texb >= 2 ? 20 : 12) + (c.volume() ? 4 : 0)) return false;
    head.width  = file.ReadInt32();
    head.height = file.ReadInt32();
    if (c.volume()) head.depth = file.ReadInt32();
    if (c.texb >= 2) {
        head.compressed = file.ReadInt32() == 1;
        head.expanded   = file.ReadInt32();
    }
    head.stored = file.ReadInt32();
    return true;
}

// A level whose header can be believed: the payload lies inside the file.
bool LevelUsable(const fs::IBinaryStream& file, int texb, const LevelHead& head)
{
    return head.width > 0 && head.height > 0 && head.width <= kMaxSide && head.height <= kMaxSide &&
           head.depth >= 1 && head.depth <= kMaxDepth && head.stored > 0 && head.stored <= BytesLeft(file) &&
           (texb < 2 || head.expanded >= 0);
}

// The variant patches that follow a level's payload when the container has variant records
// (`sub_14015C8D0`): groups of entries `skip, id, x, y, w, h, format, size, bytes`. Only
// chosen ids are kept. False when the file ends inside them.
bool ReadLevelPatches(fs::IBinaryStream& file, const Container& c, std::vector<LevelPatch>* kept)
{
    if (c.variants.empty()) return true;
    if (BytesLeft(file) < 4) return false;
    const u32 groups = file.ReadUint32();
    for (u32 g = 0; g < groups; ++g) {
        if (BytesLeft(file) < 4) return false;
        const u32 entries = file.ReadUint32();
        for (u32 e = 0; e < entries; ++e) {
            if (BytesLeft(file) < 4 * 8) return false;
            file.ReadInt32(); // unread by the reference
            const i32 id = file.ReadInt32();
            LevelPatch patch;
            patch.x      = file.ReadInt32();
            patch.y      = file.ReadInt32();
            patch.width  = file.ReadInt32();
            patch.height = file.ReadInt32();
            patch.format = file.ReadInt32();
            const u32 size = file.ReadUint32();
            if (size > static_cast<u64>(BytesLeft(file))) return false;
            const auto chosen = c.patchFlags.find(id);
            if (kept == nullptr || chosen == c.patchFlags.end()) {
                if (! file.SeekCur(size)) return false;
                continue;
            }
            patch.flags = chosen->second;
            patch.bytes.resize(size);
            if (size > 0 && file.Read(patch.bytes.data(), size) != size) return false;
            kept->push_back(std::move(patch));
        }
    }
    return true;
}

// How many bytes of a raw or block-compressed level the file stores for this size.
u64 RawBytes(const Container& c, i32 width, i32 height, i32 depth)
{
    return WeStoredBytes(*c.row, width, height, depth);
}

// The longer side of the level header that follows a payload of `payload` bytes
// from the current position, read ahead without moving the stream. 0 when the file
// ends first or the sizes are not positive.
u64 NextLevelLongest(fs::IBinaryStream& file, i32 payload)
{
    const idx at = file.Tell();
    if (! file.SeekSet(at + payload)) return 0;
    u64 longest = 0;
    if (BytesLeft(file) >= 8) {
        const i32 width  = file.ReadInt32();
        const i32 height = file.ReadInt32();
        if (width > 0 && height > 0) longest = static_cast<u64>(std::max(width, height));
    }
    file.SeekSet(at);
    return longest;
}

using Bytes = std::unique_ptr<uint8_t[]>;

Bytes MakeBytes(u64 size) { return Bytes(new (std::nothrow) uint8_t[size]); }

ImageDataPtr OwnArray(Bytes bytes)
{
    return ImageDataPtr(bytes.release(), [](uint8_t* p) { delete[] p; });
}

// The bytes of one level, expanded when the level is compressed. The compressed
// bytes are dropped as soon as they have been expanded.
Bytes ReadLevelBytes(fs::IBinaryStream& file, const LevelHead& head, const Container& c, i64& size)
{
    if (! head.compressed) {
        Bytes bytes = MakeBytes(static_cast<u64>(head.stored));
        if (! bytes || file.Read(bytes.get(), static_cast<usize>(head.stored)) !=
                           static_cast<usize>(head.stored))
            return nullptr;
        size = head.stored;
        return bytes;
    }
    const u64 ceiling =
        std::max<u64>(static_cast<u64>(kExpandCeiling), RawBytes(c, head.width, head.height, head.depth));
    if (head.expanded <= 0 || static_cast<u64>(head.expanded) > ceiling ||
        i64 { head.expanded } > i64 { head.stored } * kLz4MaxRatio + kLz4MaxRatio) {
        LOG_ERROR("texture: a compressed level claims an impossible size");
        return nullptr;
    }
    Bytes packed = MakeBytes(static_cast<u64>(head.stored));
    if (! packed || file.Read(packed.get(), static_cast<usize>(head.stored)) != static_cast<usize>(head.stored))
        return nullptr;
    Bytes bytes = MakeBytes(static_cast<u64>(head.expanded));
    if (! bytes) return nullptr;
    const int got = LZ4_decompress_safe(reinterpret_cast<const char*>(packed.get()),
                                        reinterpret_cast<char*>(bytes.get()),
                                        head.stored,
                                        head.expanded);
    if (got != head.expanded) {
        LOG_ERROR("texture: a compressed level does not expand to its stated size");
        return nullptr;
    }
    size = head.expanded;
    return bytes;
}

// ---- recognising payloads ---------------------------------------------------

enum class Magic { None, Png, Jpeg, Gif, Bmp, Tiff, Mp4, Matroska };

Magic SniffMagic(const uint8_t* p, std::size_t n)
{
    const auto starts = [&](std::initializer_list<int> bytes) {
        if (n < bytes.size()) return false;
        std::size_t i = 0;
        for (const int b : bytes) {
            if (p[i++] != b) return false;
        }
        return true;
    };
    if (starts({ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a })) return Magic::Png;
    if (starts({ 0xff, 0xd8, 0xff })) return Magic::Jpeg;
    if (starts({ 'G', 'I', 'F', '8', '7', 'a' }) || starts({ 'G', 'I', 'F', '8', '9', 'a' })) return Magic::Gif;
    if (starts({ 'B', 'M' })) return Magic::Bmp;
    if (starts({ 'I', 'I', '*', 0 }) || starts({ 'M', 'M', 0, '*' })) return Magic::Tiff;
    if (n >= 12 && std::memcmp(p + 4, "ftyp", 4) == 0) return Magic::Mp4;
    if (starts({ 0x1a, 0x45, 0xdf, 0xa3 })) return Magic::Matroska;
    return Magic::None;
}

ImageType PictureTypeOf(Magic magic)
{
    switch (magic) {
    case Magic::Png: return ImageType::PNG;
    case Magic::Jpeg: return ImageType::JPEG;
    case Magic::Gif: return ImageType::GIF;
    case Magic::Bmp: return ImageType::BMP;
    case Magic::Tiff: return ImageType::TIFF;
    default: return ImageType::UNKNOWN;
    }
}

bool IsVideoMagic(Magic magic) { return magic == Magic::Mp4 || magic == Magic::Matroska; }

// ---- pictures -----------------------------------------------------------------

// Decodes a picture to 8-bit RGBA, rows top first, and turns a JPEG upright.
// The input is released as soon as it has been decoded.
bool DecodePicture(Bytes bytes, i64 size, ImageData& out)
{
    if (! bytes || size <= 0 || size > INT_MAX) return false;
    int      width = 0, height = 0, channels = 0;
    uint8_t* pixels = stbi_load_from_memory(bytes.get(), static_cast<int>(size), &width, &height, &channels, 4);
    if (pixels == nullptr) return false;
    const int orientation = JpegOrientation(std::span<const uint8_t>(bytes.get(), static_cast<usize>(size)));
    bytes.reset();
    ImageDataPtr owner(pixels, [](uint8_t* p) { stbi_image_free(p); });
    if (orientation > 1) OrientRGBA(pixels, width, height, orientation);
    out.width  = width;
    out.height = height;
    out.size   = static_cast<isize>(width) * height * 4;
    out.data   = std::move(owner);
    return true;
}

enum class Kind { Raw, Picture, Video };

struct DecodedLevel {
    ImageData data;
    Kind      kind { Kind::Raw };
    ImageType sniffed { ImageType::UNKNOWN };
};

// The pixels of a patch, encoded as its level is: LZ4 when the level is, a picture when the
// container declares one, raw otherwise (`sub_14015C8D0`). Empty when it does not decode.
std::vector<uint8_t> PatchPixels(const Container& c, const LevelHead& head, const LevelPatch& patch)
{
    const u64 area = u64(patch.width) * u64(patch.height);
    if (head.compressed) {
        std::vector<uint8_t> out(area * 4);
        const int got = LZ4_decompress_safe(reinterpret_cast<const char*>(patch.bytes.data()),
                                            reinterpret_cast<char*>(out.data()),
                                            static_cast<int>(patch.bytes.size()), static_cast<int>(out.size()));
        if (got < 0) return {};
        return out;
    }
    if (c.declaresPicture()) {
        Bytes copy = MakeBytes(patch.bytes.size());
        if (! copy || patch.bytes.empty()) return {};
        std::memcpy(copy.get(), patch.bytes.data(), patch.bytes.size());
        ImageData decoded;
        if (! DecodePicture(std::move(copy), static_cast<i64>(patch.bytes.size()), decoded)) return {};
        const auto* p = decoded.data.get();
        return std::vector<uint8_t>(p, p + decoded.size);
    }
    return patch.bytes;
}

// Lays one patch over a level as `sub_14015C480` does: format 0 with the blend flag mixes
// colour by the patch's alpha and keeps the larger alpha; otherwise rows are copied for the
// formats the reference copies (0, 4, 6, 7, 8, 9) and the rest is left alone.
void BlitPatch(i32 format, const LevelPatch& patch, const uint8_t* src, u64 src_size, uint8_t* level,
               u64 level_size, i32 level_width)
{
    const u64 pw = u64(patch.width), ph = u64(patch.height), px = u64(patch.x), py = u64(patch.y);
    const u64 lw = u64(level_width);
    const auto copy = [&](u64 dst, u64 from, u64 n) {
        if (dst + n <= level_size && from + n <= src_size) std::memcpy(level + dst, src + from, n);
    };
    if ((patch.flags & kPatchBlend) != 0) {
        if (format != 0) return;
        for (u64 y = 0; y < ph; ++y) {
            for (u64 x = 0; x < pw; ++x) {
                const u64 s = 4 * (x + y * pw), d = 4 * (x + px + lw * (y + py));
                if (s + 4 > src_size || d + 4 > level_size) continue;
                const u32 a = src[s + 3];
                for (int ch = 0; ch < 3; ++ch) {
                    const int delta = int(src[s + ch]) - int(level[d + ch]);
                    level[d + ch]   = static_cast<uint8_t>(level[d + ch] + ((int(a) * delta) >> 8));
                }
                level[d + 3] = std::max<uint8_t>(level[d + 3], static_cast<uint8_t>(a));
            }
        }
        return;
    }
    switch (format) {
    case 0:
        for (u64 y = 0; y < ph; ++y) copy(4 * (px + lw * (y + py)), 4 * y * pw, 4 * pw);
        break;
    case 4:
    case 6:
        for (u64 y = 0; y < ph; y += 4) copy(lw * (y + py) + 4 * px, y * pw, 4 * pw);
        break;
    case 7:
        for (u64 y = 0; y < ph; y += 4) copy((lw * (y + py) + 4 * px) >> 1, (y * pw) >> 1, 2 * pw);
        break;
    case 8:
        for (u64 y = 0; y < ph; ++y) copy(2 * (px + lw * (y + py)), 2 * y * pw, 2 * pw);
        break;
    case 9:
        for (u64 y = 0; y < ph; ++y) copy(px + lw * (y + py), y * pw, pw);
        break;
    default: break;
    }
}

// Applies a level's chosen patches in file order. Patches before the one ahead of the last
// whole-level replacement are dropped (the reference's own trim), and a replacement ends the walk.
void ApplyPatches(const Container& c, const LevelHead& head, std::vector<LevelPatch> patches, i32 format,
                  ImageData& level)
{
    if (patches.empty() || ! level.data) return;
    for (std::size_t i = patches.size(); i-- > 0;) {
        if ((patches[i].flags & kPatchReplace) == 0) continue;
        if (i != 0) patches.erase(patches.begin(), patches.begin() + static_cast<std::ptrdiff_t>(i - 1));
        break;
    }
    for (const auto& patch : patches) {
        if ((patch.flags & kPatchReplace) != 0) {
            if (patch.bytes.size() < static_cast<u64>(level.size)) return;
            Bytes bytes = MakeBytes(patch.bytes.size());
            if (! bytes) return;
            std::memcpy(bytes.get(), patch.bytes.data(), patch.bytes.size());
            level.size = static_cast<isize>(patch.bytes.size());
            level.data = OwnArray(std::move(bytes));
            return;
        }
        if (patch.width <= 0 || patch.height <= 0 || patch.x < 0 || patch.y < 0 ||
            patch.x > level.width || patch.width > level.width - patch.x || patch.y > level.height ||
            patch.height > level.height - patch.y)
            continue;
        const auto pixels = PatchPixels(c, head, patch);
        if (pixels.empty()) continue;
        BlitPatch(format, patch, pixels.data(), pixels.size(), level.data.get(), static_cast<u64>(level.size),
                  level.width);
    }
}

// Decides what a level's bytes are (raw pixels, an embedded picture or a clip) and
// produces the level's data. False when the level cannot be used.
bool BuildLevel(const Container& c, const LevelHead& head, Bytes bytes, i64 size, std::vector<LevelPatch> patches,
                DecodedLevel& out)
{
    const u64 needed = RawBytes(c, head.width, head.height, head.depth);
    if (c.video()) {
        out.kind = Kind::Video;
    } else if (c.declaresPicture()) {
        out.kind = Kind::Picture;
    } else if (c.texb >= 3 && static_cast<u64>(size) != needed) {
        // No declared type: bytes that are exactly the pixels of the level are pixels.
        const Magic magic = SniffMagic(bytes.get(), static_cast<usize>(size));
        if (IsVideoMagic(magic)) {
            out.kind = Kind::Video;
        } else if (magic != Magic::None) {
            out.kind    = Kind::Picture;
            out.sniffed = PictureTypeOf(magic);
        }
    }

    switch (out.kind) {
    case Kind::Picture:
        if (! DecodePicture(std::move(bytes), size, out.data)) {
            LOG_ERROR("texture: an embedded picture does not decode");
            return false;
        }
        if (head.depth > 1) {
            // A volume's picture is decoded as width x (height x depth): the slices stacked top
            // to bottom (`sub_14015C8D0` asks the decoder for w, h*d), which is [z][y][x].
            if (out.data.width != head.width || out.data.height != head.height * head.depth) {
                LOG_ERROR("texture: a volume picture is not its slices stacked");
                return false;
            }
            out.data.height = head.height;
            out.data.depth  = head.depth;
        }
        ApplyPatches(c, head, std::move(patches), 0, out.data);
        return true;
    case Kind::Video:
        out.data.width  = head.width;
        out.data.height = head.height;
        out.data.size   = static_cast<isize>(size);
        out.data.data   = OwnArray(std::move(bytes));
        return true;
    case Kind::Raw:
        if (static_cast<u64>(size) < needed) {
            LOG_ERROR("texture: a level is shorter than its size needs");
            return false;
        }
        out.data.width  = head.width;
        out.data.height = head.height;
        out.data.depth  = head.depth;
        out.data.size   = static_cast<isize>(size);
        out.data.data   = OwnArray(std::move(bytes));
        ApplyPatches(c, head, std::move(patches), c.formatCode, out.data);
        return true;
    }
    return false;
}

// ---- the sprite frame table -------------------------------------------------

using PictureDims = std::vector<std::pair<i32, i32>>; // first authored level; 0 x 0 = none

// Reads the frame table that follows the pictures and appends the valid frames.
void ReadFrameTable(fs::IBinaryStream& file, const PictureDims& pictures, SpriteAnimation& frames)
{
    const int version = ReadStamp(file, 'S', false);
    if (version <= 0 || BytesLeft(file) < 4) return;
    const i32 count = file.ReadInt32();
    if (version == 3) {
        if (BytesLeft(file) < 8) return;
        file.ReadInt32(); // the cell size, which the frames repeat
        file.ReadInt32();
    }
    if (version > 3) LOG_INFO("texture: TEXS%04d is newer than any known, read as TEXS0003", version);
    if (count <= 0) return;
    constexpr i64 kRowBytes = 32; // index, time and six numbers
    const i64     rows      = std::min<i64>(count, BytesLeft(file) / kRowBytes);
    for (i64 r = 0; r < rows; ++r) {
        const i32   index = file.ReadInt32();
        const float time  = file.ReadFloat();
        std::array<float, 6> v {};
        for (float& value : v) value = version == 1 ? static_cast<float>(file.ReadInt32()) : file.ReadFloat();
        if (index < 0 || static_cast<std::size_t>(index) >= pictures.size()) continue;
        const auto [pw, ph] = pictures[static_cast<std::size_t>(index)];
        if (pw <= 0 || ph <= 0) continue;
        const float w = static_cast<float>(pw);
        const float h = static_cast<float>(ph);

        SpriteFrame frame;
        frame.imageId   = index;
        frame.frametime = time;
        frame.x         = v[0] / w;
        frame.y         = v[1] / h;
        frame.xAxis     = { v[2] / w, v[3] / h };
        frame.yAxis     = { v[4] / w, v[5] / h };
        frame.width     = std::hypot(v[2], v[3]);
        frame.height    = std::hypot(v[4], v[5]);
        frame.rate      = frame.width > 0.0f ? frame.height / frame.width : 1.0f;
        frames.AppendFrame(frame);
    }
}

// ---- reading video through a stream ---------------------------------------

// A window of a stream as the container readers' byte source. Reads are
// serialised, since the stream has one position.
// The most that is asked of a stream in one read when a window of it is probed.
constexpr std::size_t kStreamReadPiece = std::size_t { 1 } << 20;

class StreamByteSource final : public media::ByteSource {
public:
    StreamByteSource(std::shared_ptr<fs::IBinaryStream> stream, u64 start, u64 size)
        : m_stream(std::move(stream)), m_start(start), m_size(size) {}

    std::uint64_t size() const override { return m_size; }
    std::size_t   readAt(std::uint64_t offset, void* destination, std::size_t length) const override {
        if (offset >= m_size || length == 0) return 0;
        length = static_cast<std::size_t>(std::min<u64>(length, m_size - offset));
        std::lock_guard lock(m_mutex);
        if (! m_stream->SeekSet(static_cast<idx>(m_start + offset))) {
            m_failed = true;
            return 0;
        }
        // However much a reader asks for at once, the stream is read in bounded pieces.
        auto*       out  = static_cast<uint8_t*>(destination);
        std::size_t done = 0;
        while (done < length) {
            const std::size_t piece = std::min(length - done, kStreamReadPiece);
            const std::size_t got   = m_stream->Read(out + done, piece);
            done += got;
            if (got < piece) break;
        }
        return done;
    }
    bool ioFailed() const override { return m_failed; }

private:
    std::shared_ptr<fs::IBinaryStream> m_stream;
    u64                                m_start;
    u64                                m_size;
    mutable std::mutex                 m_mutex;
    mutable bool                       m_failed { false };
};

std::optional<video::VideoMetadata> ProbeStreamWindow(std::shared_ptr<fs::IBinaryStream> stream, u64 start, u64 size)
{
    if (size == 0) return std::nullopt;
    auto source = std::make_shared<StreamByteSource>(std::move(stream), start, size);
    return video::ProbeVideoMetadataFromSource(source);
}

std::optional<video::VideoMetadata> ProbeBytes(const uint8_t* data, i64 size)
{
    return video::ProbeVideoMetadataFromMemory(
        std::span<const char>(reinterpret_cast<const char*>(data), static_cast<usize>(size)));
}

// ---- describing a container ---------------------------------------------------

ImageHeader DescribeContainer(std::shared_ptr<fs::IBinaryStream> stream, const IImageParser::VariantCondition& holds)
{
    fs::IBinaryStream& file = *stream;
    Container          c;
    if (! ReadContainer(file, c, holds)) return {};
    ImageHeader h = HeaderOf(c);

    if (c.sprite()) {
        // Every level table is walked (payloads are skipped) so the frame table is found.
        if (c.pictures < 1 || c.pictures > BytesLeft(file) / 4) return h;
        PictureDims pictures(static_cast<std::size_t>(c.pictures));
        for (auto& dims : pictures) {
            if (BytesLeft(file) < 4) return h;
            const i32 levels = file.ReadInt32();
            if (levels < 0 || levels > BytesLeft(file) / 12) return h;
            for (i32 i = 0; i < levels; ++i) {
                LevelHead head;
                if (! ReadLevelHead(file, c, head) || ! LevelUsable(file, c.texb, head) ||
                    ! file.SeekCur(head.stored) || ! ReadLevelPatches(file, c, nullptr))
                    return h;
                if (i == 0) dims = { head.width, head.height };
            }
        }
        if (pictures.front().first > 0) NoteFirstLevel(h, pictures.front().first, pictures.front().second);
        ReadFrameTable(file, pictures, h.spriteAnim);
        return h;
    }

    if (c.pictures < 1 || BytesLeft(file) < 4) return h;
    const i32 levels = file.ReadInt32();
    if (levels < 1 || levels > BytesLeft(file) / 12) return h;
    LevelHead head;
    if (! ReadLevelHead(file, c, head)) return h;
    NoteFirstLevel(h, head.width, head.height);

    const bool usable = head.stored > 0 && head.stored <= BytesLeft(file);
    if (! usable) return h;
    const idx payload = file.Tell();

    if (c.video()) {
        // A clip is measured where it lies; a compressed one has to be expanded first.
        if (! head.compressed) {
            if (const auto meta = ProbeStreamWindow(stream, static_cast<u64>(payload), static_cast<u64>(head.stored)))
                h.durationSeconds = meta->duration_seconds;
        } else {
            i64   size  = 0;
            Bytes bytes = ReadLevelBytes(file, head, c, size);
            if (bytes) {
                if (const auto meta = ProbeBytes(bytes.get(), size)) h.durationSeconds = meta->duration_seconds;
            }
        }
        return h;
    }

    if (c.texb >= 3 && c.imageType == -1 && ! head.compressed) {
        std::array<uint8_t, kSniffBytes> prefix {};
        const usize want = static_cast<usize>(std::min<i64>(head.stored, kSniffBytes));
        if (file.Read(prefix.data(), want) == want) {
            const Magic magic = SniffMagic(prefix.data(), want);
            if (IsVideoMagic(magic)) {
                h.isVideo    = true;
                h.formatCode = 0;
                if (const auto meta = ProbeStreamWindow(stream, static_cast<u64>(payload), static_cast<u64>(head.stored)))
                    h.durationSeconds = meta->duration_seconds;
            } else if (magic != Magic::None) {
                h.type       = PictureTypeOf(magic);
                h.formatCode = 0;
            }
        }
    }
    return h;
}

// ---- loose pictures and videos ----------------------------------------------

struct LooseFile {
    bool        host { false }; // read from the disk rather than the file space
    std::string path;
    bool        video { false };
};

// The extension of the last path component, with its dot; empty when there is none.
std::string ExtensionOfName(std::string_view name)
{
    const std::size_t slash = name.rfind('/');
    const std::string_view part = slash == std::string_view::npos ? name : name.substr(slash + 1);
    if (part.empty() || part.find_first_not_of('.') == std::string_view::npos) return {};
    const std::size_t dot = part.rfind('.');
    if (dot == std::string_view::npos || dot == 0) return {};
    return std::string(part.substr(dot));
}

bool HasLooseExtension(std::string_view extension)
{
    return IsLooseImageExtension(extension) || IsLooseVideoExtension(extension);
}

std::optional<LooseFile> ResolveInFileSpace(fs::VFS* vfs, const std::string& name)
{
    if (vfs == nullptr || name.empty()) return std::nullopt;
    static constexpr std::array<std::string_view, 15> kGuess { "png", "jpg", "jpeg", "jpe", "bmp",
                                                              "gif", "tga", "targa", "webp", "mp4",
                                                              "m4v", "mov",  "webm",  "avi",  "mkv" };
    const std::string extension = ExtensionOfName(name);
    for (const std::string_view prefix : { "/assets/materials/", "/assets/" }) {
        const std::string path = std::string(prefix) + name;
        if (HasLooseExtension(extension) && vfs->Contains(path)) {
            return LooseFile { false, path, IsLooseVideoExtension(extension) };
        }
        if (! extension.empty()) continue;
        for (const std::string_view guess : kGuess) {
            const std::string candidate = path + "." + std::string(guess);
            if (vfs->Contains(candidate)) {
                return LooseFile { false, candidate, IsLooseVideoExtension("." + std::string(guess)) };
            }
        }
    }
    return std::nullopt;
}

std::shared_ptr<fs::IBinaryStream> OpenLoose(fs::VFS* vfs, const LooseFile& file)
{
    if (file.host) return fs::CreateCBinaryStream(file.path);
    return vfs != nullptr ? vfs->Open(file.path) : nullptr;
}

ImageType TypeOfExtension(std::string_view extension)
{
    std::string lower(extension);
    for (char& c : lower) c = c >= 'A' && c <= 'Z' ? static_cast<char>(c - 'A' + 'a') : c;
    if (lower == ".png") return ImageType::PNG;
    if (lower == ".jpg" || lower == ".jpeg" || lower == ".jpe") return ImageType::JPEG;
    if (lower == ".bmp") return ImageType::BMP;
    if (lower == ".gif") return ImageType::GIF;
    if (lower == ".tga" || lower == ".targa") return ImageType::TARGA;
    return ImageType::UNKNOWN;
}

ImageHeader LooseHeader(i32 width, i32 height, ImageType type)
{
    ImageHeader h;
    h.width     = width;
    h.height    = height;
    h.mapWidth  = width;
    h.mapHeight = height;
    h.count     = 1;
    h.format    = TextureFormat::RGBA8;
    h.type      = type;
    h.sample.wrapS     = TextureWrap::CLAMP_TO_EDGE;
    h.sample.wrapT     = TextureWrap::CLAMP_TO_EDGE;
    h.sample.minFilter = TextureFilter::LINEAR;
    h.sample.magFilter = TextureFilter::LINEAR;
    h.sample.mipFilter = TextureFilter::LINEAR;
    h.sample.maxAnisotropy = 8; // a picture file, as a .tex without the point flag
    for (int i = 1; i <= 4; ++i) h.extraHeader["compo" + std::to_string(i)].val = 1;
    return h;
}

// Callbacks that let stb read the size of a picture from a stream.
int StbRead(void* user, char* data, int size)
{
    return static_cast<int>(static_cast<fs::IBinaryStream*>(user)->Read(data, static_cast<usize>(size)));
}
void StbSkip(void* user, int n)
{
    auto* stream = static_cast<fs::IBinaryStream*>(user);
    if (! stream->SeekCur(n)) stream->SeekEnd(0);
}
int StbEof(void* user)
{
    const auto* stream = static_cast<fs::IBinaryStream*>(user);
    return stream->Tell() >= stream->Size() ? 1 : 0;
}

// The size a loose picture will have once decoded, from its header alone.
bool LoosePictureSize(fs::IBinaryStream& stream, i32& width, i32& height)
{
    if (stream.Size() <= 0) return false;
    int orientation = 1;
    if (stream.Size() >= 2) {
        // Only a JPEG can be turned, and its orientation sits in the first segments.
        std::array<uint8_t, 2> start {};
        if (stream.SeekSet(0) && stream.Read(start.data(), 2) == 2 && start[0] == 0xff && start[1] == 0xd8) {
            const usize want = static_cast<usize>(std::min<i64>(stream.Size(), kOrientationWindow));
            std::vector<uint8_t> prefix(want);
            if (stream.SeekSet(0)) {
                prefix.resize(stream.Read(prefix.data(), want));
                orientation = JpegOrientation(prefix);
            }
        }
    }
    if (! stream.SeekSet(0)) return false;
    const stbi_io_callbacks callbacks { StbRead, StbSkip, StbEof };
    int                     w = 0, h = 0, channels = 0;
    if (! stbi_info_from_callbacks(&callbacks, &stream, &w, &h, &channels) || w <= 0 || h <= 0) return false;
    width  = orientation >= 5 ? h : w;
    height = orientation >= 5 ? w : h;
    return true;
}

} // namespace

bool wallpaper::HostLooseAssetIsReadable(std::string_view name) { return IsHostAssetPath(name); }

namespace
{
// The picture or clip a name stands for, from the host disk when the name is a
// host path and from the file space otherwise.
std::optional<LooseFile> ResolveLooseFile(fs::VFS* vfs, const std::string& name)
{
    if (IsHostAssetPath(name)) return LooseFile { true, name, IsLooseVideoExtension(ExtensionOfName(name)) };
    return ResolveInFileSpace(vfs, name);
}

// A texture container found in the file space.
std::shared_ptr<Image> LoadContainer(std::shared_ptr<fs::IBinaryStream> stream, const std::string& name,
                                     uint64_t surfaceLongestSide, const IImageParser::VariantCondition& holds)
{
    fs::IBinaryStream& file = *stream;
    Container          c;
    if (! ReadContainer(file, c, holds)) return nullptr;
    const auto fail = [&](const char* why) -> std::shared_ptr<Image> {
        LOG_ERROR("texture \"%s\": %s", name.c_str(), why);
        return nullptr;
    };
    if (c.pictures < 1 || c.pictures > BytesLeft(file) / 4) return fail("the picture count is not usable");

    // Only a single-picture, plain texture whose levels are raw pixels or declared
    // pictures may lose levels to the display.
    const bool eligible = c.pictures == 1 && ! c.sprite() && ! c.video() && ! c.volume() &&
                          (c.texb < 3 || c.declaresPicture());
    const std::size_t loaded = c.sprite() ? static_cast<std::size_t>(c.pictures) : 1;

    auto image = std::make_shared<Image>();
    image->key = name;
    ImageHeader header = HeaderOf(c);
    PictureDims dims(static_cast<std::size_t>(c.pictures));
    // Every level is uploaded as the first one kept is: decoded pictures as RGBA, raw levels in
    // the container's format, a clip as itself. A level of another kind would be read as the
    // first one's pixels, past the end of its own bytes.
    std::optional<Kind> kind;

    for (std::size_t p = 0; p < loaded; ++p) {
        if (BytesLeft(file) < 4) return fail("the file ends inside the level tables");
        const i32 levels = file.ReadInt32();
        if (levels < 0 || levels > BytesLeft(file) / 12) return fail("the level count is not usable");
        if (p == 0 && levels == 0) return fail("the first picture has no levels");

        Image::Slot slot;
        bool        cut = false;
        for (i32 i = 0; i < levels; ++i) {
            LevelHead head;
            if (! ReadLevelHead(file, c, head) || ! LevelUsable(file, c.texb, head))
                return fail("a level header is not usable");
            if (i == 0) {
                dims[p] = { head.width, head.height };
                if (p == 0) NoteFirstLevel(header, head.width, head.height);
            }
            // Behind a level of another kind the chain has ended: what follows is skipped.
            if (cut) {
                if (! file.SeekCur(head.stored)) return fail("a level lies outside the file");
                continue;
            }
            // The level behind this one can cover the surface by itself: this one is
            // not needed. Its payload is skipped, never decoded.
            if (eligible && surfaceLongestSide > 0 && i + 1 < levels &&
                NextLevelLongest(file, head.stored) >= surfaceLongestSide) {
                if (! file.SeekCur(head.stored) || ! ReadLevelPatches(file, c, nullptr))
                    return fail("a level lies outside the file");
                continue;
            }

            i64   size  = 0;
            Bytes bytes = ReadLevelBytes(file, head, c, size);
            if (! bytes) return fail("a level cannot be read");
            std::vector<LevelPatch> patches;
            if (! ReadLevelPatches(file, c, &patches)) return fail("a level's variant patches are cut short");
            DecodedLevel level;
            if (! BuildLevel(c, head, std::move(bytes), size, std::move(patches), level))
                return fail("a level cannot be used");
            if (! kind) kind = level.kind;
            if (level.kind != *kind) {
                // A picture of a sheet that would begin with one has nothing to show.
                if (slot.mipmaps.empty()) return fail("a picture's levels are not of the first picture's kind");
                LOG_ERROR("texture \"%s\": a level is not of the first level's kind; it and the levels after it are dropped",
                          name.c_str());
                cut = true;
                continue;
            }

            if (p == 0 && slot.mipmaps.empty()) {
                if (level.kind == Kind::Picture) {
                    // Decoded pictures are unpadded: the decoded size is the allocated one.
                    header.format     = TextureFormat::RGBA8;
                    header.formatCode = 0;
                    if (i == 0) NoteFirstLevel(header, level.data.width, level.data.height);
                    if (level.sniffed != ImageType::UNKNOWN) header.type = level.sniffed;
                } else if (level.kind == Kind::Video) {
                    header.isVideo = true;
                    header.format     = TextureFormat::RGBA8;
                    header.formatCode = 0;
                }
            }
            if (slot.mipmaps.empty()) {
                slot.width  = level.data.width;
                slot.height = level.data.height;
                slot.depth  = level.data.depth;
            }
            slot.mipmaps.push_back(std::move(level.data));
        }
        image->slots.push_back(std::move(slot));
    }

    if (c.sprite()) ReadFrameTable(file, dims, header.spriteAnim);
    if (header.isVideo && ! image->slots.empty() && ! image->slots.front().mipmaps.empty()) {
        const auto& clip = image->slots.front().mipmaps.front();
        if (clip.data) {
            if (const auto meta = ProbeBytes(clip.data.get(), static_cast<i64>(clip.size)))
                header.durationSeconds = meta->duration_seconds;
        }
    }
    image->header = std::move(header);
    return image;
}
} // namespace

std::shared_ptr<Image> WPTexImageParser::Parse(const std::string& name) {
    // A picture of the user's own is not in the package, and probing the mount
    // for it logs a missing-file error for every slot on every load.
    if (IsHostAssetPath(name)) return ParseLooseAsset(name);
    if (name.empty() || m_vfs == nullptr) return nullptr;
    // A packaged container, when there is one, is the texture; a broken one is not
    // replaced by a loose picture of the same name.
    const std::string container = "/assets/materials/" + name + ".tex";
    if (m_vfs->Contains(container)) {
        auto stream = m_vfs->Open(container);
        return stream ? LoadContainer(std::move(stream), name, m_texture_surface_longest_side, m_variant_condition)
                      : nullptr;
    }
    return ParseLooseAsset(name);
}

ImageHeader WPTexImageParser::ParseHeader(const std::string& name) {
    if (IsHostAssetPath(name)) return ParseLooseAssetHeader(name);
    if (name.empty() || m_vfs == nullptr) return {};
    const std::string container = "/assets/materials/" + name + ".tex";
    if (m_vfs->Contains(container)) {
        auto stream = m_vfs->Open(container);
        return stream ? DescribeContainer(std::move(stream), m_variant_condition) : ImageHeader {};
    }
    return ParseLooseAssetHeader(name);
}

namespace
{
ImageHeader VideoHeader(const video::VideoMetadata& meta)
{
    ImageHeader h = LooseHeader(static_cast<i32>(meta.width), static_cast<i32>(meta.height), ImageType::UNKNOWN);
    h.isVideo         = true;
    h.sample.maxAnisotropy = 1; // a clip is an engine-made texture, not a file the sampler reads
    h.durationSeconds = meta.duration_seconds;
    return h;
}

// Where the clip is a file on the host disk: a path the user gave, or a file of a folder mount.
std::string HostPathOf(fs::VFS* vfs, const LooseFile& file)
{
    if (file.host) return file.path;
    std::string path;
    if (vfs != nullptr && vfs->PhysicalPath(file.path, &path)) return path;
    return {};
}

// The clip on the host disk, measured where it lies.
std::optional<video::VideoMetadata> ProbeHostFile(const std::string& path)
{
    media::Error error;
    auto         source = media::OpenFileByteSource(path, &error);
    if (! source || source->size() == 0) return std::nullopt;
    return video::ProbeVideoMetadataFromSource(source);
}

// A clip is played from a file. One that lies on the host disk (a path the user picked, or a
// file of a folder mount) is probed and opened there, and nothing is read through the file
// space. One inside a package is measured through its stream, then streamed in bounded pieces
// to a cache file named by its content.
std::shared_ptr<Image> ParseLooseVideo(fs::VFS* vfs, const std::string& name, const LooseFile& file)
{
    const auto fail = [&name]() -> std::shared_ptr<Image> {
        LOG_ERROR("texture \"%s\": the clip cannot be read", name.c_str());
        return nullptr;
    };
    auto image = std::make_shared<Image>();
    image->key = name;

    if (const std::string host = HostPathOf(vfs, file); ! host.empty()) {
        const auto meta = ProbeHostFile(host);
        if (! meta) return fail();
        image->header        = VideoHeader(*meta);
        image->videoFilePath = host;
        return image;
    }

    auto stream = OpenLoose(vfs, file);
    if (! stream || stream->Size() <= 0) return nullptr;
    const auto meta = ProbeStreamWindow(stream, 0, static_cast<u64>(stream->Size()));
    if (! meta) return fail();
    std::string cached = CacheVideoByContent(*stream, ExtensionOfName(file.path));
    if (cached.empty()) return fail();
    image->header        = VideoHeader(*meta);
    image->videoFilePath = std::move(cached);
    return image;
}
} // namespace

std::shared_ptr<Image> WPTexImageParser::ParseLooseAsset(const std::string& name)
{
    const auto found = ResolveLooseFile(m_vfs, name);
    if (! found) {
        LOG_ERROR("texture \"%s\" not found", name.c_str());
        // Neither a container nor a loose picture: named by the material folder it was looked for in.
        fs::ReportMissingFile("/assets/materials/" + name);
        return nullptr;
    }
    // A clip is never read whole: it is played where it lies, or from a cache file.
    if (found->video) return ParseLooseVideo(m_vfs, name, *found);

    auto stream = OpenLoose(m_vfs, *found);
    if (! stream || stream->Size() <= 0 || ! stream->SeekSet(0)) return nullptr;

    // The picture is read straight into the buffer it is decoded from.
    const i64 size = stream->Size();
    if (size > INT_MAX) return nullptr;
    Bytes bytes = MakeBytes(static_cast<u64>(size));
    if (! bytes || stream->Read(bytes.get(), static_cast<usize>(size)) != static_cast<usize>(size)) return nullptr;
    ImageData level;
    if (! DecodePicture(std::move(bytes), size, level)) {
        LOG_ERROR("texture \"%s\": the picture does not decode", name.c_str());
        return nullptr;
    }
    ImageHeader header = LooseHeader(level.width, level.height, TypeOfExtension(ExtensionOfName(found->path)));

    Image::Slot slot;
    slot.width  = level.width;
    slot.height = level.height;
    slot.mipmaps.push_back(std::move(level));

    auto image    = std::make_shared<Image>();
    image->key    = name;
    image->header = std::move(header);
    image->slots.push_back(std::move(slot));
    return image;
}

ImageHeader WPTexImageParser::ParseLooseAssetHeader(const std::string& name)
{
    const auto found = ResolveLooseFile(m_vfs, name);
    if (! found) {
        // The parse reads a texture's header only; the picture itself is loaded when drawn.
        fs::ReportMissingFile("/assets/materials/" + name);
        return {};
    }
    if (found->video) {
        if (const std::string host = HostPathOf(m_vfs, *found); ! host.empty()) {
            const auto meta = ProbeHostFile(host);
            return meta ? VideoHeader(*meta) : ImageHeader {};
        }
        auto stream = OpenLoose(m_vfs, *found);
        if (! stream) return {};
        const auto meta = ProbeStreamWindow(stream, 0, static_cast<u64>(stream->Size()));
        return meta ? VideoHeader(*meta) : ImageHeader {};
    }
    auto stream = OpenLoose(m_vfs, *found);
    if (! stream) return {};
    i32 width = 0, height = 0;
    if (! LoosePictureSize(*stream, width, height)) return {};
    return LooseHeader(width, height, TypeOfExtension(ExtensionOfName(found->path)));
}
