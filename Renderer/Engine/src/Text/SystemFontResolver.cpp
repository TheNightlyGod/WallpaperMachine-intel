// Clean-room implementation from the WallpaperMachine spec e5-text-audio-video-runtime.md; written without access to the original source.
#include "Text/SystemFontResolver.hpp"

#include <array>
#include <climits>
#include <chrono>
#include <filesystem>
#include <functional>
#include <mutex>
#include <string>
#include <string_view>
#include <unordered_map>

#ifdef __APPLE__
#    include <CoreFoundation/CoreFoundation.h>
#    include <CoreText/CoreText.h>
#endif

namespace wallpaper
{
namespace
{

/// One of Wallpaper Engine's eight font keys, and what draws it here.
///
/// Wallpaper Engine reads these from the Windows Fonts folder. Arial, Comic Sans MS,
/// Microsoft Sans Serif and Verdana are installed on every Mac as the same fonts, and
/// stand for themselves. Consolas, Cambria, Segoe UI and Calibri are not, and the face
/// that stands in for each is set to the real font's advances (`size_adjust`: the real
/// font's digit advance over the stand-in's, which a clock's width is made of) and sets
/// its rows in the real font's line metrics, which are the numbers its saved text cards
/// pin: Consolas 1.1709 em of line (digits 1126/2048 em wide), Cambria 1.170 (digits
/// 0.5542), Segoe UI 1.331 (digits 0.5369 to 0.5394, 441/2048 for the colon), Calibri
/// 1.2207 (digits 1038/2048). The stand-in for Consolas is Andale Mono because its
/// digits are as wide to as tall as Consolas's, so that at Consolas's advance they stand
/// 0.643 em tall, as Consolas's do in Wallpaper Engine's frames (Menlo's, fitted the same
/// way, stand 0.676). How each line is split between ascender and descender is the
/// font's tables; the sums are the saved cards', and Consolas's split is pinned by
/// Wallpaper Engine's own frame of a centred clock in it (a baseline half the ascender below
/// the origin, 0.743 em of ascender, so its digits stand within a pixel of where ours do).
/// For the others the split is remembered from the fonts' tables and unchecked.
struct SceneFont {
    std::string_view key;
    std::string_view family;
    SystemFontFit    fit;
};

constexpr SceneFont kSceneFonts[] = {
    { "systemfont_arial", "Arial", {} },
    { "systemfont_calibri", "PT Sans", { 0.930f, FontLineMetrics { 2048, 1536, 512, 452 } } },
    { "systemfont_cambria", "Charter", { 0.996f, FontLineMetrics { 2048, 1946, 455, 0 } } },
    { "systemfont_comicsans", "Comic Sans MS", {} },
    { "systemfont_consolas", "Andale Mono", { 0.916f, FontLineMetrics { 2048, 1521, 526, 351 } } },
    { "systemfont_sansserif", "Microsoft Sans Serif", {} },
    { "systemfont_segoe", "PT Sans", { 0.987f, FontLineMetrics { 2048, 2210, 514, 0 } } },
    { "systemfont_verdana", "Verdana", {} },
};

const SceneFont* FindSceneFont(std::string_view key) {
    for (const auto& font : kSceneFonts) {
        if (font.key == key) return &font;
    }
    return nullptr;
}

#ifdef __APPLE__
// RAII holder for a CoreFoundation object; releases it exactly once.
template<typename T>
class CfOwned {
public:
    explicit CfOwned(T ref = nullptr): m_ref(ref) {}
    CfOwned(const CfOwned&)            = delete;
    CfOwned& operator=(const CfOwned&) = delete;
    ~CfOwned() {
        if (m_ref != nullptr) CFRelease(m_ref);
    }
    T get() const { return m_ref; }
    explicit operator bool() const { return m_ref != nullptr; }

private:
    T m_ref;
};

std::string Utf8FromCf(CFStringRef text) {
    if (text == nullptr) return {};
    const CFIndex length = CFStringGetLength(text);
    const CFIndex size   = CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8) + 1;
    std::string   out(static_cast<std::size_t>(size), '\0');
    if (! CFStringGetCString(text, out.data(), size, kCFStringEncodingUTF8)) return {};
    out.resize(std::char_traits<char>::length(out.c_str()));
    return out;
}

SystemFontFace ResolveAppleFamily(std::string_view family) {
    if (family.empty()) return {};
    const CfOwned<CFStringRef> name { CFStringCreateWithBytes(
        kCFAllocatorDefault, reinterpret_cast<const UInt8*>(family.data()),
        static_cast<CFIndex>(family.size()), kCFStringEncodingUTF8, false) };
    if (! name) return {};

    const void*                    keys[]   = { kCTFontFamilyNameAttribute };
    const void*                    values[] = { name.get() };
    const CfOwned<CFDictionaryRef> attributes { CFDictionaryCreate(
        kCFAllocatorDefault, keys, values, 1, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks) };
    if (! attributes) return {};
    const CfOwned<CTFontDescriptorRef> descriptor { CTFontDescriptorCreateWithAttributes(
        attributes.get()) };
    if (! descriptor) return {};

    // The system answers a family it does not have with a fallback font; only the family
    // that was asked for counts.
    const CfOwned<CTFontRef> font { CTFontCreateWithFontDescriptor(descriptor.get(), 12.0, nullptr) };
    if (! font) return {};
    const CfOwned<CFStringRef> matched_family { CTFontCopyFamilyName(font.get()) };
    if (! matched_family ||
        CFStringCompare(matched_family.get(), name.get(), kCFCompareCaseInsensitive) != kCFCompareEqualTo) {
        return {};
    }

    const CfOwned<CFURLRef> url { static_cast<CFURLRef>(CTFontCopyAttribute(font.get(), kCTFontURLAttribute)) };
    if (! url || CFGetTypeID(url.get()) != CFURLGetTypeID()) return {};
    char path[PATH_MAX] {};
    if (! CFURLGetFileSystemRepresentation(url.get(), true, reinterpret_cast<UInt8*>(path), sizeof(path))) {
        return {};
    }
    SystemFontFace face;
    face.path = path;
    const CfOwned<CFStringRef> postscript { CTFontCopyPostScriptName(font.get()) };
    face.postscript_name = Utf8FromCf(postscript.get());
    return face;
}
#endif

// The faces found for a family, kept so that a layout, which asks for the faces of its
// fallback chain, does not run the system's font matching once per face per text change.
//
// A found face is kept while its file is there: some of the system's faces are
// downloadable assets (PingFang SC lives in a hash-named folder of the font assets), so
// an update can replace the file under the path that was found, and the next lookup
// finds the new one. A family that was not found is asked for again after
// `kMissingFamilyRetry`: it may be an asset that was not on the disk yet, and a family
// that is truly missing costs one lookup in that time, not one per layout.
constexpr auto kMissingFamilyRetry = std::chrono::seconds(30);

using FamilyLookup = std::function<SystemFontFace(std::string_view)>;

FamilyLookup& FamilyLookupFunction() {
    static FamilyLookup lookup = [](std::string_view family) {
#ifdef __APPLE__
        return ResolveAppleFamily(family);
#else
        (void)family;
        return SystemFontFace {};
#endif
    };
    return lookup;
}

struct FamilyEntry {
    SystemFontFace                        face;
    std::chrono::steady_clock::time_point looked_up;
};

std::mutex& FamilyMutex() {
    static std::mutex mutex;
    return mutex;
}

std::unordered_map<std::string, FamilyEntry>& FamilyEntries() {
    static std::unordered_map<std::string, FamilyEntry> found;
    return found;
}

SystemFontFace LookUpFamily(std::string_view family) {
    const std::string key(family);
    const auto        now = std::chrono::steady_clock::now();
    FamilyLookup      lookup;
    {
        const std::lock_guard lock { FamilyMutex() };
        if (const auto cached = FamilyEntries().find(key); cached != FamilyEntries().end()) {
            const auto& entry = cached->second;
            std::error_code failure;
            const bool      fresh = entry.face.path.empty()
                                        ? now - entry.looked_up < kMissingFamilyRetry
                                        : std::filesystem::exists(entry.face.path, failure);
            if (fresh) return entry.face;
        }
        lookup = FamilyLookupFunction();
    }
    SystemFontFace face = lookup(family);
    const std::lock_guard lock { FamilyMutex() };
    FamilyEntries().insert_or_assign(key, FamilyEntry { face, now });
    return face;
}

} // namespace

bool IsSceneFontKey(std::string_view key) { return FindSceneFont(key) != nullptr; }

SystemFontFace ResolveInstalledFamily(std::string_view family) { return LookUpFamily(family); }

#ifdef WESCENE_BUILD_TESTS
void SetInstalledFamilyLookupForTests(std::function<SystemFontFace(std::string_view)> lookup) {
    const std::lock_guard lock { FamilyMutex() };
    FamilyEntries().clear();
    FamilyLookupFunction() = lookup ? std::move(lookup) : [](std::string_view family) {
#    ifdef __APPLE__
        return ResolveAppleFamily(family);
#    else
        (void)family;
        return SystemFontFace {};
#    endif
    };
}

void ExpireMissingInstalledFamiliesForTests() {
    const std::lock_guard lock { FamilyMutex() };
    for (auto& [family, entry] : FamilyEntries()) {
        if (entry.face.path.empty()) entry.looked_up -= kMissingFamilyRetry + std::chrono::seconds(1);
    }
}
#endif

SystemFontFace ResolveSceneFont(std::string_view key) {
    const SceneFont* scene_font = FindSceneFont(key);
    if (scene_font != nullptr) {
        if (auto face = LookUpFamily(scene_font->family); ! face.path.empty()) {
            face.fit = scene_font->fit;
            return face;
        }
    }
    // A font Wallpaper Engine cannot load is Arial, and a key it does not know is a path to
    // a file that is not there.
    if (scene_font == nullptr || scene_font->key != kDefaultSceneFontKey) {
        return ResolveSceneFont(kDefaultSceneFontKey);
    }
    // Not even Arial: the faces every Mac has, in the order of most to least like it.
    for (const auto family : { "Helvetica", "Times" }) {
        if (auto face = LookUpFamily(family); ! face.path.empty()) return face;
    }
    return {};
}

} // namespace wallpaper
