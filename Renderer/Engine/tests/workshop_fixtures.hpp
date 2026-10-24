// Inputs for the workshop snapshot tests, all built in memory and written under a scratch folder:
// packed items (scene.pkg), .tex containers, .mdl files and the scene documents that go in them.
#pragma once

#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#include "mdl_fixtures.hpp"
#include "tex_fixtures.hpp"
#include "support/byte_fs.hpp"

namespace wmfix
{

using Blob = std::vector<uint8_t>;
using nlohmann::json;
using wallpaper::test::Bytes;

inline Blob textBlob(const std::string& text) { return Blob(text.begin(), text.end()); }
inline Blob jsonBlob(const json& doc) { return textBlob(doc.dump()); }

// ---- packages ---------------------------------------------------------------------------------

struct Entry {
    std::string name;
    Blob        payload;
    // Added to the stored offset, to point the entry outside the file.
    int32_t     shift { 0 };
};

inline Entry entry(std::string name, const std::string& text) { return { std::move(name), textBlob(text), 0 }; }
inline Entry entry(std::string name, const json& doc) { return { std::move(name), jsonBlob(doc), 0 }; }
inline Entry entry(std::string name, Blob bytes) { return { std::move(name), std::move(bytes), 0 }; }

struct PackageOptions {
    std::string version { "PKGV0001" };
};

// A scene.pkg: version text, entry table, payloads in table order.
inline Blob packageBytes(const std::vector<Entry>& entries, const PackageOptions& options = {}) {
    Bytes b;
    b.i32(static_cast<int32_t>(options.version.size())).raw(options.version.data(), options.version.size());
    b.i32(static_cast<int32_t>(entries.size()));
    int32_t offset = 0;
    for (const auto& e : entries) {
        b.i32(static_cast<int32_t>(e.name.size())).raw(e.name.data(), e.name.size());
        b.i32(offset + e.shift).i32(static_cast<int32_t>(e.payload.size()));
        offset += static_cast<int32_t>(e.payload.size());
    }
    for (const auto& e : entries) b.raw(e.payload);
    return b.data();
}

// A fresh folder under the system temp directory; removed with the object.
class Workspace {
public:
    Workspace(): m_dir("workshop-snapshot") {}

    // The folder `name` below the workspace, created, holding a scene.pkg of `entries`.
    std::string item(const std::string& name, const std::vector<Entry>& entries,
                     const PackageOptions& options = {}) {
        const std::string folder = m_dir.str(name);
        m_dir.write(name + "/scene.pkg", packageBytes(entries, options));
        return folder;
    }
    std::string folder(const std::string& name) {
        std::filesystem::create_directories(m_dir.path() / name);
        return m_dir.str(name);
    }
    std::string write(const std::string& relative, const Blob& bytes) { return m_dir.write(relative, bytes); }
    std::string write(const std::string& relative, const std::string& text) { return m_dir.write(relative, text); }
    std::string root() const { return m_dir.str(); }

private:
    textest::ScratchDir m_dir;
};

// ---- textures ---------------------------------------------------------------------------------

// The default container: texb 3, an 8x8 header, one 2x2 raw level.
inline Blob defaultTexture() {
    textest::Container c(3, { textest::rawLevel(2, 2, 0x55) });
    return textest::build(c);
}
inline Blob texture(int texb, int w, int h, uint32_t flags = 0) {
    textest::Container c(texb, { textest::rawLevel(texb == 2 ? 4 : 2, texb == 2 ? 1 : 2, 0x33) });
    c.width = c.mapWidth = w;
    c.height = c.mapHeight = h;
    c.flags = flags;
    return textest::build(c);
}

// ---- models -----------------------------------------------------------------------------------

inline void skeleton(Bytes& f, int version) {
    mdltest::writeSkeleton(f, version, { { "root", mdltest::kNone, { 1, 2, 3 } } });
}

inline Bytes meshOnly() {
    mdltest::MeshSpec m;
    m.flag = mdltest::kSkinned;
    return mdltest::mdlFile(21, { m });
}

// Skinned: one root bone bound at (1, 2, 3), MDLS 1, an empty MDLA 0.
inline Blob skinnedModel() {
    Bytes f = meshOnly();
    skeleton(f, 1);
    f.stamp("MDLA", 0).u8(0);
    return f.data();
}

// No skeleton blocks at all.
inline Blob staticModel() { return meshOnly().data(); }

struct Track {
    int frames { 1 };
};

// One version-6 animation: `tracks` bone tracks, each with its own number of frames. The
// first position word of frame k is id + 100 * k, so frames can be told apart.
inline void animationRecord(Bytes& b, int id, const std::string& name, float fps, int length,
                            const std::vector<Track>& tracks) {
    b.i32(id).u32(0).cstr(name).cstr("loop").f32(fps).i32(length).i32(0);
    b.u32(static_cast<uint32_t>(tracks.size()));
    for (const auto& t : tracks) {
        b.i32(0).u32(static_cast<uint32_t>(t.frames) * 36);
        for (int k = 0; k < t.frames; ++k) {
            b.f32(static_cast<float>(id + 100 * k)).f32(0).f32(0); // position
            b.f32(0).f32(0).f32(0);                                // angle
            b.f32(1).f32(1).f32(1);                                // scale
        }
    }
    b.u32(0);                          // no translation track
    b.u8(0);                           // no blend curves
    b.u8(0);                           // no timed events
    for (int i = 0; i < 6; ++i) b.f32(0.0f); // bounding box
    b.u8(0);                           // no scalar curves
    b.u32(0);                          // no events
}

// Skinned with MDLS 3 and an MDLA 6 block holding one animation.
inline Blob animatedModel(int id = 3, const std::vector<Track>& tracks = { Track { 1 }, Track { 1 } }) {
    Bytes f = meshOnly();
    skeleton(f, 3);
    const size_t end = mdltest::beginBlock(f, "MDLA", 6);
    f.u32(1);
    animationRecord(f, id, "walk", 30.0f, 10, tracks);
    mdltest::endBlock(f, end);
    return f.data();
}

inline Blob junkModel() { return textBlob("junk"); }

// ---- scenes -----------------------------------------------------------------------------------

inline json sceneDoc(json objects) {
    json doc = {
        { "camera", { { "center", { 0, 0, 0 } }, { "eye", { 0, 0, 1 } }, { "up", { 0, 1, 0 } } } },
        { "general",
          { { "ambientcolor", { 0.2, 0.2, 0.2 } },
            { "skylightcolor", { 0.3, 0.3, 0.3 } },
            { "clearcolor", { 0, 0, 0 } },
            { "cameraparallax", false },
            { "orthogonalprojection", { { "width", 64 }, { "height", 32 } } } } },
    };
    if (! objects.is_null()) doc["objects"] = std::move(objects);
    return doc;
}

// Asset files an image layer needs: image.json -> mat.json.
inline std::vector<Entry> imageAssets(int width = 64, int height = 32) {
    return {
        entry("image.json", json { { "width", width }, { "height", height }, { "material", "mat.json" } }),
        entry("mat.json", json { { "passes", { { { "blending", "translucent" },
                                                 { "cullmode", "nocull" },
                                                 { "depthtest", "disabled" },
                                                 { "depthwrite", "disabled" },
                                                 { "shader", "genericimage" },
                                                 { "textures", { "solid" } } } } } }),
    };
}

inline json onePassMaterial(const std::string& blending, const std::string& shader) {
    return { { "passes", { { { "blending", blending },
                             { "cullmode", "nocull" },
                             { "depthtest", "disabled" },
                             { "depthwrite", "disabled" },
                             { "shader", shader },
                             { "textures", { "solid" } } } } } };
}

// effects/e.json with its material.
inline std::vector<Entry> effectAssets() {
    return {
        entry("effects/e.json",
              json { { "name", "e" },
                     { "version", 1 },
                     { "passes", { { { "material", "materials/effects/e.json" },
                                     { "bind", { { { "name", "previous" }, { "index", 0 } } } } } } },
                     { "fbos", { { { "name", "_rt_a" }, { "format", "rgba8888" }, { "scale", 2 } } } } }),
        entry("materials/effects/e.json", onePassMaterial("normal", "genericimage")),
    };
}

inline json effectInstance() {
    return { { "file", "effects/e.json" },
             { "name", "wave" },
             { "visible", true },
             { "passes", { { { "constantshadervalues", { { "speed", 2 } } } } } } };
}

inline std::vector<Entry> particleAssets() {
    return {
        entry("particles/p.json",
              json { { "emitter", { { { "name", "boxrandom" }, { "rate", 5 } }, { { "name", "sphererandom" } } } },
                     { "initializer", { { { "name", "lifetimerandom" } } } },
                     { "operator", { { { "name", "movement" } }, { { "name", "alphafade" } }, { { "name", "colorchange" } } } },
                     { "renderer", { { { "name", "sprite" } } } },
                     { "controlpoint", { { { "flags", 0 } } } },
                     { "material", "materials/particle.json" },
                     { "maxcount", 123 },
                     { "starttime", 2.5 },
                     { "animationmode", "sequence" } }),
        entry("materials/particle.json", onePassMaterial("additive", "genericparticle")),
    };
}

inline json imageObject(int id, const std::string& name = "pic") {
    return { { "id", id }, { "name", name }, { "image", "image.json" } };
}
inline json lightObject(int id) {
    return { { "id", id }, { "name", "lamp" }, { "light", "point" } };
}
inline json particleObject(int id) {
    return { { "id", id }, { "name", "dust" }, { "particle", "particles/p.json" }, { "origin", "1 2 3" } };
}
inline json soundObject(int id) {
    return { { "id", id }, { "name", "snd" }, { "sound", { "sounds/a.mp3" } } };
}

inline void append(std::vector<Entry>& into, std::vector<Entry> more) {
    for (auto& e : more) into.push_back(std::move(e));
}

// An item with one of each object kind, textures and models.
inline std::vector<Entry> richItem() {
    json image   = imageObject(3);
    image["effects"] = json::array({ effectInstance() });
    json objects = json::array({ json { { "id", 5 }, { "name", "grp" } }, image, lightObject(1),
                                 particleObject(4), soundObject(2) });
    std::vector<Entry> entries { entry("scene.json", sceneDoc(objects)) };
    append(entries, imageAssets());
    append(entries, effectAssets());
    append(entries, particleAssets());
    entries.push_back(entry("materials/b.tex", defaultTexture()));
    entries.push_back(entry("materials/a.tex", texture(3, 4, 4)));
    entries.push_back(entry("models/m.mdl", skinnedModel()));
    entries.push_back(entry("models/static.mdl", staticModel()));
    return entries;
}

// ---- environment ------------------------------------------------------------------------------

// Sets (or clears) one environment variable for the life of the object.
class ScopedEnv {
public:
    ScopedEnv(const char* name, const char* value): m_name(name) {
        const char* old = std::getenv(name);
        m_had           = old != nullptr;
        if (m_had) m_old = old;
        if (value != nullptr) ::setenv(name, value, 1);
        else ::unsetenv(name);
    }
    ~ScopedEnv() {
        if (m_had) ::setenv(m_name.c_str(), m_old.c_str(), 1);
        else ::unsetenv(m_name.c_str());
    }
    ScopedEnv(const ScopedEnv&)            = delete;
    ScopedEnv& operator=(const ScopedEnv&) = delete;

private:
    std::string m_name, m_old;
    bool        m_had { false };
};

} // namespace wmfix
