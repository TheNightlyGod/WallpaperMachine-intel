#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/SceneSettingResolver.hpp"
#include "Scene/SceneNode.h"
#include "WPSoundParser.hpp"

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include <cstdint>
#include <map>
#include <memory>
#include <vector>

namespace wallpaper
{
namespace
{

class FakeSoundStream final : public audio::SoundStream {
public:
    uint64_t NextPcmData(void*, uint32_t) override { return 0; }
    void     PassDesc(const Desc&) override {}
};

TEST(SceneScriptSoundLayerSmoke, ScriptControlsNativeSoundLayer) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .canvas_width  = 3840,
        .canvas_height = 2160,
    });
    ASSERT_NE(runtime, nullptr);

    WPSoundStream::StreamFactory factory = [](const audio::SoundStream::Desc&) {
        return std::make_shared<FakeSoundStream>();
    };
    auto sound_layer = std::make_shared<WPSoundStream>(
        std::vector<WPSoundStream::StreamFactory> { std::move(factory) },
        WPSoundStream::Config { .startsilent = true });

    runtime->RegisterSoundLayer("morningAudio", sound_layer);
    ASSERT_TRUE(runtime->HasSoundLayer("morningAudio"));
    ASSERT_FALSE(runtime->SoundLayerPlaying("morningAudio"));

    runtime->RegisterSceneScript(
        R"JS(
function update() {
  var morningAudio = scene.getObject('morningAudio');
  if (!morningAudio.isPlaying()) {
    morningAudio.play();
  }
}
)JS",
        "");
    ASSERT_EQ(runtime->sceneScriptCount(), 1u);

    runtime->Tick(1.0 / 60.0);

    EXPECT_TRUE(runtime->SoundLayerPlaying("morningAudio"));
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(SceneScriptSoundLayerSmoke, CursorClickSoundLayerDoesNotPlayOnHoverOnly) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .canvas_width  = 3840,
        .canvas_height = 2160,
    });
    ASSERT_NE(runtime, nullptr);

    WPSoundStream::StreamFactory factory = [](const audio::SoundStream::Desc&) {
        return std::make_shared<FakeSoundStream>();
    };
    auto sound_layer = std::make_shared<WPSoundStream>(
        std::vector<WPSoundStream::StreamFactory> { std::move(factory) },
        WPSoundStream::Config { .startsilent = true });

    runtime->RegisterSoundLayer("tapAudio", sound_layer);
    ASSERT_TRUE(runtime->HasSoundLayer("tapAudio"));
    ASSERT_FALSE(runtime->SoundLayerPlaying("tapAudio"));

    runtime->RegisterSceneScript(
        R"JS(
function cursorClick() {
  scene.getObject('tapAudio').play();
}
)JS",
        "");
    ASSERT_EQ(runtime->sceneScriptCount(), 1u);

    runtime->SetCursorInput(0.25f, 0.75f);
    runtime->SetCursorEnter(true);
    bool cursor_was_in_window = runtime->DispatchCursorFrameEvents(false);
    cursor_was_in_window      = runtime->DispatchCursorFrameEvents(cursor_was_in_window);
    runtime->Tick(1.0 / 60.0);

    EXPECT_TRUE(cursor_was_in_window);
    EXPECT_FALSE(runtime->SoundLayerPlaying("tapAudio"));
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(SceneScriptSoundLayerSmoke, CursorClickSoundLayerPlaysOnceOnTapEdge) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .canvas_width  = 3840,
        .canvas_height = 2160,
    });
    ASSERT_NE(runtime, nullptr);

    WPSoundStream::StreamFactory factory = [](const audio::SoundStream::Desc&) {
        return std::make_shared<FakeSoundStream>();
    };
    auto sound_layer = std::make_shared<WPSoundStream>(
        std::vector<WPSoundStream::StreamFactory> { std::move(factory) },
        WPSoundStream::Config { .startsilent = true });

    runtime->RegisterSoundLayer("tapAudio", sound_layer);
    ASSERT_TRUE(runtime->HasSoundLayer("tapAudio"));
    ASSERT_FALSE(runtime->SoundLayerPlaying("tapAudio"));

    runtime->RegisterSceneScript(
        R"JS(
var clickCount = 0;
function cursorClick() {
  clickCount++;
  scene.getObject('tapAudio').play();
}
function update() {
  if (clickCount > 1) {
    scene.getObject('tapAudio').stop();
  }
}
)JS",
        "");
    ASSERT_EQ(runtime->sceneScriptCount(), 1u);

    runtime->SetCursorInput(0.25f, 0.75f);
    runtime->SetCursorEnter(true);
    runtime->SetCursorButtons(0u, 1u, 1u);
    bool cursor_was_in_window = runtime->DispatchCursorFrameEvents(false);
    runtime->SetCursorButtons(0u, 0u, 0u);
    cursor_was_in_window = runtime->DispatchCursorFrameEvents(cursor_was_in_window);
    runtime->Tick(1.0 / 60.0);

    EXPECT_TRUE(cursor_was_in_window);
    EXPECT_TRUE(runtime->SoundLayerPlaying("tapAudio"));
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(SceneScriptSoundLayerSmoke, LayerSceneScriptIgnoresClicksOutsideOwningNode) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .canvas_width  = 400,
        .canvas_height = 300,
    });
    ASSERT_NE(runtime, nullptr);

    auto owner = std::make_shared<SceneNode>();
    owner->SetTranslate(Eigen::Vector3f(200.0f, 270.0f, 0.0f));
    runtime->RegisterNode("buttonLayer", owner.get());
    runtime->RegisterNodeSize("buttonLayer", Eigen::Vector2f(100.0f, 40.0f));

    WPSoundStream::StreamFactory factory = [](const audio::SoundStream::Desc&) {
        return std::make_shared<FakeSoundStream>();
    };
    auto sound_layer = std::make_shared<WPSoundStream>(
        std::vector<WPSoundStream::StreamFactory> { std::move(factory) },
        WPSoundStream::Config { .startsilent = true });

    runtime->RegisterSoundLayer("tapAudio", sound_layer);
    ASSERT_FALSE(runtime->SoundLayerPlaying("tapAudio"));

    runtime->RegisterSceneScript(
        R"JS(
function cursorClick() {
  thisScene.getObject('tapAudio').play();
}
)JS",
        "buttonLayer");

    runtime->SetCursorInput(0.5f, 0.9f);
    runtime->SetCursorEnter(true);
    runtime->SetCursorButtons(0u, 1u, 0u);
    bool cursor_was_in_window = runtime->DispatchCursorFrameEvents(false);
    runtime->Tick(1.0 / 60.0);

    EXPECT_TRUE(cursor_was_in_window);
    EXPECT_FALSE(runtime->SoundLayerPlaying("tapAudio"));

    runtime->SetCursorInput(0.5f, 0.1f);
    runtime->SetCursorButtons(0u, 1u, 0u);
    cursor_was_in_window = runtime->DispatchCursorFrameEvents(cursor_was_in_window);
    runtime->Tick(1.0 / 60.0);

    EXPECT_TRUE(cursor_was_in_window);
    EXPECT_TRUE(runtime->SoundLayerPlaying("tapAudio"));
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(SceneScriptSoundLayerSmoke, PropertyScriptIgnoresClicksOutsideOwningNode) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .canvas_width  = 400,
        .canvas_height = 300,
    });
    ASSERT_NE(runtime, nullptr);

    auto owner = std::make_shared<SceneNode>();
    owner->SetTranslate(Eigen::Vector3f(200.0f, 270.0f, 0.0f));
    runtime->RegisterNode("buttonLayer", owner.get());
    runtime->RegisterNodeSize("buttonLayer", Eigen::Vector2f(100.0f, 40.0f));

    WPSoundStream::StreamFactory factory = [](const audio::SoundStream::Desc&) {
        return std::make_shared<FakeSoundStream>();
    };
    auto sound_layer = std::make_shared<WPSoundStream>(
        std::vector<WPSoundStream::StreamFactory> { std::move(factory) },
        WPSoundStream::Config { .startsilent = true });

    runtime->RegisterSoundLayer("tapAudio", sound_layer);
    ASSERT_FALSE(runtime->SoundLayerPlaying("tapAudio"));

    auto visible = ResolveBoolSetting(*runtime,
                                      nlohmann::json {
                                          { "value", true },
                                          { "script", R"JS(
export function update(value) {
  return value;
}
export function cursorClick() {
  thisScene.getObject('tapAudio').play();
}
)JS" },
                                      },
                                      "buttonLayer");
    runtime->RegisterNodeVisibility("buttonLayer", owner.get(), std::move(visible));
    ASSERT_EQ(runtime->sceneScriptCount(), 1u);

    runtime->SetCursorInput(0.5f, 0.9f);
    runtime->SetCursorEnter(true);
    runtime->SetCursorButtons(0u, 1u, 0u);
    bool cursor_was_in_window = runtime->DispatchCursorFrameEvents(false);
    runtime->Tick(1.0 / 60.0);

    EXPECT_TRUE(cursor_was_in_window);
    EXPECT_FALSE(runtime->SoundLayerPlaying("tapAudio"));

    runtime->SetCursorInput(0.5f, 0.1f);
    runtime->SetCursorButtons(0u, 1u, 0u);
    cursor_was_in_window = runtime->DispatchCursorFrameEvents(cursor_was_in_window);
    runtime->Tick(1.0 / 60.0);

    EXPECT_TRUE(cursor_was_in_window);
    EXPECT_TRUE(runtime->SoundLayerPlaying("tapAudio"));
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(SceneScriptSoundLayerSmoke, DuplicateImageLayerScriptsHitTestOwnNode) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .canvas_width  = 400,
        .canvas_height = 300,
    });
    ASSERT_NE(runtime, nullptr);

    auto first = std::make_shared<SceneNode>();
    first->SetTranslate(Eigen::Vector3f(100.0f, 150.0f, 0.0f));
    auto second = std::make_shared<SceneNode>();
    second->SetTranslate(Eigen::Vector3f(300.0f, 150.0f, 0.0f));

    runtime->RegisterNode("__we_layer_20", first.get());
    runtime->RegisterNodeSize("__we_layer_20", Eigen::Vector2f(80.0f, 80.0f));
    runtime->RegisterNode("__we_layer_21", second.get());
    runtime->RegisterNodeSize("__we_layer_21", Eigen::Vector2f(80.0f, 80.0f));

    std::map<std::string, std::shared_ptr<WPSoundStream>> sounds;
    for (const auto& name : { "leftAudio", "rightAudio" }) {
        WPSoundStream::StreamFactory factory = [](const audio::SoundStream::Desc&) {
            return std::make_shared<FakeSoundStream>();
        };
        auto sound_layer = std::make_shared<WPSoundStream>(
            std::vector<WPSoundStream::StreamFactory> { std::move(factory) },
            WPSoundStream::Config { .startsilent = true });
        runtime->RegisterSoundLayer(name, sound_layer);
        sounds.emplace(name, sound_layer);
    }

    auto script_for = [](std::string_view sound_name) {
        return nlohmann::json {
            { "value", true },
            { "script", R"JS(
export var scriptProperties = createScriptProperties()
  .addText({ name: 'voice1', label: 'Voice1', value: 'Voice1' })
  .finish();
export function update(value) {
  return value;
}
export function cursorClick() {
  thisScene.getLayer(scriptProperties.voice1).play();
}
)JS" },
            { "scriptproperties",
              nlohmann::json {
                  { "voice1", std::string(sound_name) },
              } },
        };
    };
    runtime->RegisterNodeVisibility("__we_layer_20",
                                    first.get(),
                                    ResolveBoolSetting(
                                        *runtime, script_for("leftAudio"), "__we_layer_20"));
    runtime->RegisterNodeVisibility("__we_layer_21",
                                    second.get(),
                                    ResolveBoolSetting(
                                        *runtime, script_for("rightAudio"), "__we_layer_21"));

    runtime->SetCursorInput(0.25f, 0.5f);
    runtime->SetCursorEnter(true);
    bool cursor_was_in_window = runtime->DispatchCursorFrameEvents(false);
    runtime->Tick(1.0 / 60.0);

    EXPECT_TRUE(cursor_was_in_window);
    EXPECT_FALSE(runtime->SoundLayerPlaying("leftAudio"));
    EXPECT_FALSE(runtime->SoundLayerPlaying("rightAudio"));

    runtime->SetCursorButtons(0u, 1u, 0u);
    cursor_was_in_window = runtime->DispatchCursorFrameEvents(cursor_was_in_window);
    runtime->Tick(1.0 / 60.0);

    EXPECT_TRUE(cursor_was_in_window);
    EXPECT_TRUE(runtime->SoundLayerPlaying("leftAudio"));
    EXPECT_FALSE(runtime->SoundLayerPlaying("rightAudio"));
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(SceneScriptSoundLayerSmoke, PropertyScriptCursorEnterLeaveFollowOwningNodeHitTest) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .canvas_width  = 400,
        .canvas_height = 300,
    });
    ASSERT_NE(runtime, nullptr);

    auto owner = std::make_shared<SceneNode>();
    owner->SetVisible(false);
    owner->SetTranslate(Eigen::Vector3f(200.0f, 270.0f, 0.0f));
    runtime->RegisterNode("buttonLayer", owner.get());
    runtime->RegisterNodeSize("buttonLayer", Eigen::Vector2f(100.0f, 40.0f));

    auto visible = ResolveBoolSetting(*runtime,
                                      nlohmann::json {
                                          { "value", false },
                                          { "script", R"JS(
var entered = 0;
var left = 0;
export function update(value) {
  return entered === 1 && left === 1;
}
export function cursorEnter() {
  entered++;
}
export function cursorLeave() {
  left++;
}
)JS" },
                                      },
                                      "buttonLayer");
    runtime->RegisterNodeVisibility("buttonLayer", owner.get(), std::move(visible));

    runtime->SetCursorInput(0.5f, 0.9f);
    runtime->SetCursorEnter(true);
    bool cursor_was_in_window = runtime->DispatchCursorFrameEvents(false);
    runtime->Tick(1.0 / 60.0);
    EXPECT_FALSE(runtime->NodeVisible("buttonLayer"));

    runtime->SetCursorInput(0.5f, 0.1f);
    cursor_was_in_window = runtime->DispatchCursorFrameEvents(cursor_was_in_window);
    runtime->Tick(1.0 / 60.0);
    EXPECT_FALSE(runtime->NodeVisible("buttonLayer"));

    runtime->SetCursorInput(0.5f, 0.9f);
    cursor_was_in_window = runtime->DispatchCursorFrameEvents(cursor_was_in_window);
    runtime->Tick(1.0 / 60.0);
    EXPECT_TRUE(runtime->NodeVisible("buttonLayer"));
    EXPECT_TRUE(cursor_was_in_window);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

// A layer that took a press hears its release wherever the cursor has gone,
// even out of the window, or a script that clears its held state on the way
// up stays latched for good.
TEST(SceneScriptSoundLayerSmoke, LayerScriptReceivesCursorUpForItsPressAfterLeavingWindow) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .canvas_width  = 400,
        .canvas_height = 300,
    });
    ASSERT_NE(runtime, nullptr);

    auto owner = std::make_shared<SceneNode>();
    owner->SetVisible(false);
    owner->SetTranslate(Eigen::Vector3f(200.0f, 270.0f, 0.0f));
    runtime->RegisterNode("buttonLayer", owner.get());
    runtime->RegisterNodeSize("buttonLayer", Eigen::Vector2f(100.0f, 40.0f));

    runtime->RegisterSceneScript(
        R"JS(
var entered = 0;
var left = 0;
var down = 0;
var up = 0;
function cursorEnter() {
  entered++;
}
function cursorLeave() {
  left++;
}
function cursorDown() {
  down++;
}
function cursorUp() {
  up++;
}
function update() {
  scene.getObject('buttonLayer').visible = entered === 1 && left === 1 && down === 1 && up === 1;
}
)JS",
        "buttonLayer");

    runtime->SetCursorInput(0.5f, 0.1f);
    runtime->SetCursorEnter(true);
    runtime->SetCursorButtons(1u, 1u, 0u);
    bool cursor_was_in_window = runtime->DispatchCursorFrameEvents(false);
    runtime->Tick(1.0 / 60.0);

    runtime->SetCursorEnter(false);
    runtime->SetCursorButtons(0u, 0u, 1u);
    cursor_was_in_window = runtime->DispatchCursorFrameEvents(cursor_was_in_window);
    runtime->Tick(1.0 / 60.0);

    EXPECT_FALSE(cursor_was_in_window);
    EXPECT_TRUE(runtime->NodeVisible("buttonLayer"));
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

// A press that landed elsewhere is not the layer's, so once the cursor is out
// of the window the layer hears nothing of its release.
TEST(SceneScriptSoundLayerSmoke, LayerScriptDoesNotReceiveCursorUpForAnotherPressAfterLeavingWindow) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .canvas_width  = 400,
        .canvas_height = 300,
    });
    ASSERT_NE(runtime, nullptr);

    auto owner = std::make_shared<SceneNode>();
    owner->SetVisible(false);
    owner->SetTranslate(Eigen::Vector3f(200.0f, 270.0f, 0.0f));
    runtime->RegisterNode("buttonLayer", owner.get());
    runtime->RegisterNodeSize("buttonLayer", Eigen::Vector2f(100.0f, 40.0f));

    runtime->RegisterSceneScript(
        R"JS(
var entered = 0;
var left = 0;
var down = 0;
var up = 0;
function cursorEnter() {
  entered++;
}
function cursorLeave() {
  left++;
}
function cursorDown() {
  down++;
}
function cursorUp() {
  up++;
}
function update() {
  scene.getObject('buttonLayer').visible = entered === 1 && left === 1 && down === 0 && up === 0;
}
)JS",
        "buttonLayer");

    runtime->SetCursorInput(0.5f, 0.5f);
    runtime->SetCursorEnter(true);
    runtime->SetCursorButtons(1u, 1u, 0u);
    bool cursor_was_in_window = runtime->DispatchCursorFrameEvents(false);
    runtime->Tick(1.0 / 60.0);

    runtime->SetCursorInput(0.5f, 0.1f);
    runtime->SetCursorButtons(1u, 0u, 0u);
    cursor_was_in_window = runtime->DispatchCursorFrameEvents(cursor_was_in_window);
    runtime->Tick(1.0 / 60.0);

    runtime->SetCursorEnter(false);
    runtime->SetCursorButtons(0u, 0u, 1u);
    cursor_was_in_window = runtime->DispatchCursorFrameEvents(cursor_was_in_window);
    runtime->Tick(1.0 / 60.0);

    EXPECT_FALSE(cursor_was_in_window);
    EXPECT_TRUE(runtime->NodeVisible("buttonLayer"));
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

} // namespace
} // namespace wallpaper
