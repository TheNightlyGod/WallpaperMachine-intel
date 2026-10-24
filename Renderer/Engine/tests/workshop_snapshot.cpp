#include "workshop_snapshot.hpp"

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdlib>
#include <exception>
#include <filesystem>
#include <fstream>
#include <memory>
#include <ostream>
#include <string_view>
#include <unordered_map>
#include <vector>

#include "Fs/CBinaryStream.h"
#include "Fs/PhysicalFs.h"
#include "Fs/VFS.h"
#include "Image.hpp"
#include "WPMdlParser.hpp"
#include "WPPkgFs.hpp"
#include "WPTexImageParser.hpp"
#include "wpscene/WPImageObject.h"
#include "wpscene/WPLightObject.hpp"
#include "wpscene/WPObjectSchema.hpp"
#include "wpscene/WPParticleObject.h"
#include "wpscene/WPScene.h"
#include "wpscene/WPSoundObject.h"

namespace wmsnap
{
namespace
{

using nlohmann::json;
namespace ws = wallpaper::wpscene;

// ---- small value helpers ----------------------------------------------------------------------

// A float prints as the double it widens to, so a test can compare it exactly.
template<size_t N>
json floatList(const std::array<float, N>& values) {
    json out = json::array();
    for (float v : values) out.push_back(static_cast<double>(v));
    return out;
}

json floatList(const float* values, size_t n) {
    json out = json::array();
    for (size_t i = 0; i < n; ++i) out.push_back(static_cast<double>(values[i]));
    return out;
}

bool endsWith(const std::string& text, std::string_view tail) {
    return text.size() >= tail.size() && text.compare(text.size() - tail.size(), tail.size(), tail) == 0;
}

bool startsWith(const std::string& text, std::string_view head) {
    return text.compare(0, head.size(), head) == 0;
}

// What follows the last '/', or nothing when the path ends with one.
std::string lastComponent(const std::string& path) {
    const auto slash = path.find_last_of('/');
    return slash == std::string::npos ? path : path.substr(slash + 1);
}

// ---- the package table ------------------------------------------------------------------------

// The production reader keeps neither the version text nor the table, so the
// header is read once more here.
struct PackageTable {
    std::string              version;
    std::int32_t             declared { 0 };
    std::vector<std::string> names;
};

bool readPackageTable(const std::string& file, PackageTable& table) {
    const auto in = wallpaper::fs::CreateCBinaryStream(file);
    if (! in) return false;
    const std::int64_t total = in->Size();
    const auto         left  = [&] { return total - static_cast<std::int64_t>(in->Tell()); };

    const std::int32_t versionLength = in->ReadInt32();
    // A header whose version text cannot be real is left to the package reader to refuse.
    if (versionLength <= 0 || versionLength > 64 || versionLength > left()) return true;
    table.version.resize(static_cast<size_t>(versionLength));
    in->Read(table.version.data(), table.version.size());

    table.declared = in->ReadInt32();
    if (table.declared < 0) return false;
    for (std::int32_t i = 0; i < table.declared; ++i) {
        const std::int32_t nameLength = in->ReadInt32();
        if (nameLength < 0 || nameLength > left()) break;
        std::string name(static_cast<size_t>(nameLength), '\0');
        if (nameLength > 0) in->Read(name.data(), name.size());
        in->ReadInt32(); // offset
        in->ReadInt32(); // length
        table.names.push_back(std::move(name));
    }
    return true;
}

// ---- materials and effects --------------------------------------------------------------------

json textureList(const std::vector<std::string>& textures) {
    json out = json::array();
    for (const auto& t : textures) out.push_back(t);
    return out;
}

json comboObject(const std::unordered_map<std::string, std::int32_t>& combos) {
    json out = json::object();
    for (const auto& [name, value] : combos) out[name] = value;
    return out;
}

json shaderValues(const std::unordered_map<std::string, ws::WPConstantShaderValue>& values) {
    json out = json::object();
    for (const auto& [name, v] : values) {
        json list = json::array();
        for (float f : v.value) list.push_back(static_cast<double>(f));
        out[name] = { { "value", std::move(list) }, { "user", v.user } };
    }
    return out;
}

json materialRow(const ws::WPMaterial& m) {
    return {
        { "shader", m.shader },
        { "blending", m.blending },
        { "cullmode", m.cullmode },
        { "depthtest", m.depthtest },
        { "depthwrite", m.depthwrite },
        { "use_puppet", m.use_puppet },
        { "textures", textureList(m.textures) },
        { "combos", comboObject(m.combos) },
        { "constantshadervalues", shaderValues(m.constantshadervalues) },
    };
}

json passRow(const ws::WPMaterialPass& p) {
    json binds = json::array();
    for (const auto& b : p.bind) binds.push_back({ { "name", b.name }, { "index", b.index } });
    return {
        { "target", p.target },
        { "textures", textureList(p.textures) },
        { "combos", comboObject(p.combos) },
        { "constantshadervalues", shaderValues(p.constantshadervalues) },
        { "bind", std::move(binds) },
    };
}

json effectRow(const ws::WPImageEffect& e) {
    json materials = json::array(), passes = json::array(), fbos = json::array();
    for (const auto& m : e.materials) materials.push_back(materialRow(m));
    for (const auto& p : e.passes) passes.push_back(passRow(p));
    for (const auto& f : e.fbos) {
        fbos.push_back({ { "name", f.name }, { "format", f.format }, { "scale", f.scale } });
    }
    return {
        { "name", e.name },
        { "visible", e.visible },
        { "material_count", e.materials.size() },
        { "pass_count", e.passes.size() },
        { "fbo_count", e.fbos.size() },
        { "materials", std::move(materials) },
        { "passes", std::move(passes) },
        { "fbos", std::move(fbos) },
    };
}

// ---- scene objects ----------------------------------------------------------------------------

constexpr const char* kRawKeys[] = { "origin", "scale", "angles", "size", "parallaxDepth", "alignment" };

bool authoredVisible(const json& object) {
    const auto found = object.find("visible");
    if (found == object.end()) return true;
    if (found->is_boolean()) return found->get<bool>();
    if (found->is_object()) {
        const auto inner = found->find("value");
        if (inner != found->end() && inner->is_boolean()) return inner->get<bool>();
    }
    return true;
}

const char* kindOf(const json& object) {
    if (! object.is_object()) return "unknown";
    if (object.contains("image")) return "image";
    if (object.contains("light")) return "light";
    if (object.contains("particle")) return "particle";
    if (object.contains("sound")) return "sound";
    return "unknown";
}

json commonRow(const json& object) {
    json row = json::object();
    row["id"]      = -1;
    row["name"]    = "";
    row["visible"] = true;
    row["kind"]    = kindOf(object);
    if (! object.is_object()) return row;
    if (const auto id = object.find("id"); id != object.end() && id->is_number_integer()) {
        row["id"] = id->get<std::int64_t>();
    }
    if (const auto name = object.find("name"); name != object.end() && name->is_string()) {
        row["name"] = name->get<std::string>();
    }
    row["visible"] = authoredVisible(object);
    for (const char* key : kRawKeys) {
        if (const auto raw = object.find(key); raw != object.end()) row[key] = *raw;
    }
    return row;
}

void addImage(json& row, const json& object, wallpaper::fs::VFS& vfs) {
    ws::WPImageObject image;
    if (! image.FromJson(object, vfs)) {
        row["parsed"] = false;
        return;
    }
    json effects = json::array();
    for (const auto& e : image.effects) effects.push_back(effectRow(e));
    row["parsed"]          = true;
    row["image"]           = image.image;
    row["color"]           = floatList(image.color);
    row["colorBlendMode"]  = image.colorBlendMode;
    row["alpha"]           = static_cast<double>(image.alpha);
    row["brightness"]      = static_cast<double>(image.brightness);
    row["fullscreen"]      = image.fullscreen;
    row["nopadding"]       = image.nopadding;
    row["origin_parsed"]   = floatList(image.origin);
    row["scale_parsed"]    = floatList(image.scale);
    row["angles_parsed"]   = floatList(image.angles);
    row["size_parsed"]     = floatList(image.size);
    row["visible_parsed"]  = image.visible;
    row["alignment_parsed"] = image.alignment;
    row["puppet"]          = image.puppet;
    row["material"]        = materialRow(image.material);
    row["effect_count"]    = image.effects.size();
    row["effects"]         = std::move(effects);
}

void addLight(json& row, const json& object, wallpaper::fs::VFS& vfs) {
    ws::WPLightObject light;
    if (! light.FromJson(object, vfs)) {
        row["parsed"] = false;
        return;
    }
    row["parsed"]         = true;
    row["light"]          = light.light;
    row["color"]          = floatList(light.color);
    row["intensity"]      = static_cast<double>(light.intensity);
    row["radius"]         = static_cast<double>(light.radius);
    row["origin_parsed"]  = floatList(light.origin);
    row["scale_parsed"]   = floatList(light.scale);
    row["angles_parsed"]  = floatList(light.angles);
    row["visible_parsed"] = light.visible;
}

void addParticle(json& row, const json& object, wallpaper::fs::VFS& vfs) {
    ws::WPParticleObject particle;
    if (! particle.FromJson(object, vfs)) {
        row["parsed"] = false;
        return;
    }
    const auto& system     = particle.particleObj;
    row["parsed"]           = true;
    row["particle"]         = particle.particle;
    row["origin_parsed"]    = floatList(particle.origin);
    row["scale_parsed"]     = floatList(particle.scale);
    row["angles_parsed"]    = floatList(particle.angles);
    row["visible_parsed"]   = particle.visible;
    row["emitter_count"]    = system.emitters.size();
    row["initializer_count"] = system.initializers.size();
    row["operator_count"]   = system.operators.size();
    row["renderer_count"]   = system.renderers.size();
    row["controlpoint_count"] = system.controlpoints.size();
    row["child_count"]      = system.children.size();
    row["maxcount"]         = static_cast<int>(system.maxcount);
    row["starttime"]        = static_cast<int>(system.starttime);
    row["animationmode"]    = system.animationmode;
}

void addSound(json& row, const json& object, wallpaper::fs::VFS& vfs) {
    ws::WPSoundObject sound;
    if (! sound.FromJson(object, vfs)) {
        row["parsed"] = false;
        return;
    }
    row["parsed"]         = true;
    row["playbackmode"]   = sound.playbackmode;
    row["volume"]         = static_cast<double>(sound.volume);
    row["mintime"]        = static_cast<double>(sound.mintime);
    row["maxtime"]        = static_cast<double>(sound.maxtime);
    row["visible_parsed"] = sound.visible;
    row["sound_paths"]    = json(sound.sound);
}

json objectRow(const json& object, wallpaper::fs::VFS& vfs) {
    json row = commonRow(object);
    const std::string kind = row["kind"].get<std::string>();
    if (kind == "unknown") return row;
    // A row that fails to parse keeps only what is common to all kinds.
    try {
        json   detail = json::object();
        if (kind == "image") addImage(detail, object, vfs);
        else if (kind == "light") addLight(detail, object, vfs);
        else if (kind == "particle") addParticle(detail, object, vfs);
        else addSound(detail, object, vfs);
        if (detail.value("parsed", false)) {
            for (auto it = detail.begin(); it != detail.end(); ++it) row[it.key()] = std::move(it.value());
        } else {
            row["parsed"] = false;
        }
    } catch (const std::exception&) {
        row["parsed"] = false;
    }
    return row;
}

// ---- the scene --------------------------------------------------------------------------------

json sceneBlock(const std::string& text, wallpaper::fs::VFS& vfs) {
    json doc;
    if (! ws::ParseBoundedJson(text, doc)) {
        std::string why;
        try {
            json::parse(text);
            why = "the engine's reader refused the scene document";
        } catch (const std::exception& e) {
            why = e.what();
        }
        return { { "parsed", false }, { "error", why } };
    }

    ws::WPScene scene;
    json        block = json::object();
    block["parsed"]   = scene.FromJson(doc);
    const auto& g     = scene.general;
    block["is_ortho"] = g.isOrtho;
    block["ortho"]    = { { "width", g.orthogonalprojection.width }, { "height", g.orthogonalprojection.height } };
    block["camera"]   = { { "center", floatList(scene.camera.center) },
                          { "eye", floatList(scene.camera.eye) },
                          { "up", floatList(scene.camera.up) } };
    json general = {
        { "clearcolor", floatList(g.clearcolor) },
        { "ambientcolor", floatList(g.ambientcolor) },
        { "skylightcolor", floatList(g.skylightcolor) },
        { "cameraparallax", g.cameraparallax },
        { "zoom", static_cast<double>(g.zoom) },
        { "fov", static_cast<double>(g.fov) },
        { "nearz", static_cast<double>(g.nearz) },
        { "farz", static_cast<double>(g.farz) },
    };
    if (g.cameraparallax) {
        general["cameraparallaxamount"]         = static_cast<double>(g.cameraparallaxamount);
        general["cameraparallaxdelay"]          = static_cast<double>(g.cameraparallaxdelay);
        general["cameraparallaxmouseinfluence"] = static_cast<double>(g.cameraparallaxmouseinfluence);
    }
    block["general"] = std::move(general);

    std::vector<json> rows;
    if (const auto list = doc.find("objects"); doc.is_object() && list != doc.end() && list->is_array()) {
        for (const auto& object : *list) rows.push_back(objectRow(object, vfs));
    }
    std::stable_sort(rows.begin(), rows.end(), [](const json& a, const json& b) {
        return a["id"].get<std::int64_t>() < b["id"].get<std::int64_t>();
    });
    block["object_count"] = rows.size();
    block["objects"]      = json(rows);
    return block;
}

// ---- textures ---------------------------------------------------------------------------------

constexpr std::string_view kMaterialsDir = "/materials/";

int extraValue(const wallpaper::ImageHeader& h, const char* key) {
    const auto found = h.extraHeader.find(key);
    return found == h.extraHeader.end() ? 0 : found->second.val;
}

json textureRow(const std::string& path, wallpaper::fs::VFS& vfs) {
    // The parser takes the name below materials/, without the extension.
    const std::string name = path.substr(kMaterialsDir.size(), path.size() - kMaterialsDir.size() - 4);
    wallpaper::ImageHeader h;
    bool                   read = true;
    try {
        wallpaper::WPTexImageParser parser(&vfs);
        h = parser.ParseHeader(name);
    } catch (const std::exception&) {
        read = false;
        h    = {};
    }
    const int texv = read ? extraValue(h, "texv") : 0;
    json row = json::object();
    row["path"]  = path;
    row["ok"]    = read && texv > 0 && h.width > 0 && h.height > 0;
    row["texv"]  = texv;
    row["texi"]  = read ? extraValue(h, "texi") : 0;
    row["texb"]  = read ? extraValue(h, "texb") : 0;
    for (int i = 1; i <= 4; ++i) {
        const std::string key = "compo" + std::to_string(i);
        row[key] = read ? extraValue(h, key.c_str()) : 0;
    }
    row["format"]         = static_cast<int>(h.format);
    row["image_type"]     = static_cast<int>(h.type);
    row["width"]          = read ? h.width : 0;
    row["height"]         = read ? h.height : 0;
    row["map_width"]      = h.mapWidth;
    row["map_height"]     = h.mapHeight;
    row["count"]          = read ? h.count : 0;
    row["is_sprite"]      = h.isSprite;
    row["sprite_frames"]  = h.spriteAnim.numFrames();
    row["mipmap_pow2"]    = h.mipmap_pow2;
    row["mipmap_larger"]  = h.mipmap_larger;
    row["wrap_s"]         = static_cast<int>(h.sample.wrapS);
    row["wrap_t"]         = static_cast<int>(h.sample.wrapT);
    row["min_filter"]     = static_cast<int>(h.sample.minFilter);
    row["mag_filter"]     = static_cast<int>(h.sample.magFilter);
    return row;
}

// ---- puppets ----------------------------------------------------------------------------------

json vec3(const wallpaper::linalg::Vector3f& v) {
    return json::array({ static_cast<double>(v(0)), static_cast<double>(v(1)), static_cast<double>(v(2)) });
}

// The frames a pose dump keeps of one track: first, middle and last, once each.
json sampledFrames(const wallpaper::WPPuppet::Animation::BoneTrack& track) {
    json out = json::array();
    const size_t n = track.frames.size();
    if (n == 0) return out;
    std::vector<size_t> picks { 0, n / 2, n - 1 };
    picks.erase(std::unique(picks.begin(), picks.end()), picks.end());
    for (size_t i : picks) {
        const auto& f = track.frames[i];
        out.push_back({ { "position", vec3(f.position) }, { "angle", vec3(f.angle) }, { "scale", vec3(f.scale) } });
    }
    return out;
}

json puppetRow(const std::string& path, wallpaper::fs::VFS& vfs) {
    wallpaper::WPMdl mdl;
    bool             ok = false;
    try {
        ok = wallpaper::WPMdlParser::Parse(path.substr(1), vfs, mdl);
    } catch (const std::exception&) {
        ok = false;
    }
    const bool withPoses = std::getenv(kPoseEnv) != nullptr;

    json row = json::object();
    row["path"] = path;
    row["ok"]   = ok;
    row["mdlv"] = mdl.mdlv;
    row["mdls"] = mdl.mdls;
    row["mdla"] = mdl.mdla;
    const bool hasMesh = ! mdl.meshes.empty();
    row["mat_json_file"] = hasMesh ? mdl.meshes[0].mat_json_file : std::string();
    row["vertex_count"]  = hasMesh ? mdl.meshes[0].positions.size() : size_t { 0 };
    row["index_count"]   = hasMesh ? mdl.meshes[0].indices.size() : size_t { 0 };
    const auto& puppet   = mdl.puppet;
    row["bones"] = ok && puppet ? puppet->bones.size() : size_t { 0 };
    row["anims"] = ok && puppet ? puppet->anims.size() : size_t { 0 };
    if (! ok || ! puppet) return row;

    json tree = json::array();
    for (const auto& bone : puppet->bones) {
        json sums = json::array();
        for (int col = 0; col < 4; ++col) {
            double total = 0;
            for (int r = 0; r < 4; ++r) total += static_cast<double>(bone.local_bind(r, col));
            sums.push_back(total);
        }
        json entry = { { "parent", bone.parent }, { "transform_col_sums", std::move(sums) } };
        if (withPoses) {
            entry["name"]                = bone.name;
            entry["bind_parent"]         = bone.bind_parent;
            entry["anim_parent"]         = bone.anim_parent;
            entry["has_file_skin_pivot"] = bone.has_file_skin_pivot;
            entry["bind"]                = floatList(bone.local_bind.data(), 16);
            entry["skin"]                = floatList(bone.file_skin_mat.data(), 16);
            entry["pivot"]               = vec3(bone.file_skin_pivot);
            entry["centroid_offset"]     = vec3(bone.vertex_centroid_offset);
        }
        tree.push_back(std::move(entry));
    }
    json tracks = json::array();
    for (const auto& anim : puppet->anims) {
        size_t frames = 0;
        for (const auto& t : anim.bone_tracks) frames += t.frames.size();
        json entry = {
            { "id", anim.id },
            { "fps", anim.fps },
            { "length", anim.length },
            { "name", anim.name },
            { "mode", static_cast<int>(anim.mode) },
            { "bone_track_count", anim.bone_tracks.size() },
            { "total_bone_frames", frames },
        };
        if (withPoses) {
            json poses = json::array();
            for (const auto& t : anim.bone_tracks) poses.push_back(sampledFrames(t));
            entry["poses"] = std::move(poses);
        }
        tracks.push_back(std::move(entry));
    }
    row["bone_tree"]   = std::move(tree);
    row["anim_tracks"] = std::move(tracks);
    return row;
}

} // namespace

// ---- entry points -----------------------------------------------------------------------------

json snapshotWorkshop(const std::string& dir, std::string& err) {
    err.clear();
    json out = json::object();
    out["workshop_dir"] = lastComponent(dir);
    const auto fail = [&](std::string message) {
        err          = std::move(message);
        out["error"] = err;
        return out;
    };

    const std::string pkgFile = dir + "/scene.pkg";
    std::error_code   ignored;
    if (! std::filesystem::exists(pkgFile, ignored)) return fail("scene.pkg not found at " + pkgFile);

    PackageTable table;
    if (! readPackageTable(pkgFile, table)) return fail("failed to read pkg header");

    auto pkg = wallpaper::fs::WPPkgFs::CreatePkgFs(pkgFile);
    if (! pkg) return fail("WPPkgFs::CreatePkgFs failed");

    const bool hasScene = std::find(table.names.begin(), table.names.end(), "scene.json") != table.names.end();
    out["pkg"] = { { "version", table.version }, { "file_count", table.declared }, { "has_scene_json", hasScene } };

    // The package goes first and the folder on top of it, so a loose file beside
    // scene.pkg is seen by the parsers.
    wallpaper::fs::VFS vfs;
    vfs.Mount("/assets", std::move(pkg));
    if (auto folder = wallpaper::fs::CreatePhysicalFs(dir)) vfs.Mount("/assets", std::move(folder));

    if (hasScene) {
        const auto stream = vfs.Open("/assets/scene.json");
        out["scene"]      = sceneBlock(stream ? stream->ReadAllStr() : std::string(), vfs);
    }

    std::vector<std::string> texturePaths, modelPaths;
    for (const auto& name : table.names) {
        const std::string path = "/" + name;
        if (startsWith(path, kMaterialsDir) && endsWith(path, ".tex")) texturePaths.push_back(path);
        if (endsWith(path, ".mdl")) modelPaths.push_back(path);
    }
    std::stable_sort(texturePaths.begin(), texturePaths.end());
    std::stable_sort(modelPaths.begin(), modelPaths.end());

    out["textures"] = json::array();
    for (const auto& path : texturePaths) out["textures"].push_back(textureRow(path, vfs));
    out["puppets"] = json::array();
    for (const auto& path : modelPaths) out["puppets"].push_back(puppetRow(path, vfs));
    return out;
}

std::string renderSnapshot(const json& snapshot) {
    // Names in a package are not always UTF-8; replacing keeps the dump total and repeatable.
    return snapshot.dump(2, ' ', false, json::error_handler_t::replace) + "\n";
}

int runWpdump(int argc, const char* const* argv, std::ostream& out, std::ostream& diag) {
    if (argc != 2 && argc != 3) {
        diag << "usage: " << (argc > 0 ? argv[0] : "wpdump") << " <workshop_dir> [output.json]\n";
        return 2;
    }
    std::string     err;
    const json      snapshot = snapshotWorkshop(argv[1], err);
    if (! err.empty()) {
        diag << "wpdump: " << err << "\n";
        return 1;
    }
    const std::string text = renderSnapshot(snapshot);
    if (argc == 3) {
        std::ofstream file(argv[2], std::ios::binary | std::ios::trunc);
        if (! file) {
            diag << "wpdump: cannot open " << argv[2] << " for writing\n";
            return 1;
        }
        file << text;
        return 0;
    }
    out << text;
    return 0;
}

} // namespace wmsnap
