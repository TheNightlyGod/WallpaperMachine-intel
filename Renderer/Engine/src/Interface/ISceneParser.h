#pragma once
#include <cstdint>
#include <string>
#include <memory>
#include <functional>

#include "Project/ProjectProperties.hpp"
#include "Scene/Scene.h"

namespace wallpaper
{

namespace fs{ class VFS; }
namespace audio{ class SoundManager; }

struct SceneParseRequest
{
    static constexpr uint16_t kUnknownPkgVersion { 0 };

    std::string              scene_id {};
    std::string              project_path {};
    // The values the scene loads with: the project's defaults with the user's
    // saved choices over them.
    const ProjectProperties* project_properties { nullptr };
    // What the project itself declares, without those choices. A running scene
    // returns to this table when a property is reset or left out of a later
    // document, so a choice that was saved before the scene loaded can be
    // cleared again. Null means the table above is also the authored one.
    const ProjectProperties* authored_project_properties { nullptr };
    uint16_t                 pkg_version { kUnknownPkgVersion };
    // Scene quality (plan decision I1; `SceneQuality` lives in
    // Scene/SceneQuality.hpp so `Scene` can carry it without including this header).
    SceneQuality             quality {};
    // Where the scripts' `localStorage` lives (plan decision I3): empty = memory only.
    std::string              storage_directory {};
    std::string              storage_screen_key {};
    bool                     storage_read_only { false };
    // Wallpaper Engine's per-wallpaper options (plan decision I2): the colour /
    // LUT pass, mouse parallax. Flip and playback rate are applied by the host.
    WeUserOptions            user_options {};
    // Invoked once only for an MSAA request in a scene containing a model.
    // The host supplies its device choice; a parser-only caller can omit it.
    std::function<uint32_t(uint32_t)> select_msaa_samples;
};

class ISceneParser {
public:
	ISceneParser() = default;
	virtual ~ISceneParser() = default;
	virtual std::shared_ptr<Scene> Parse(const SceneParseRequest&, const std::string&, fs::VFS&, audio::SoundManager&) = 0;
};
}
