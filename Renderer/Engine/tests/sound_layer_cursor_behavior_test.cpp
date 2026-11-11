// Scripts that start and stop native sound layers, and which script hears which cursor event.
//
// Everything is driven straight through SceneRuntimeContext: no package, no scene file, no audio
// device (the sound streams produce no PCM). Cursor input is normalized against a canvas that
// is also the cursor viewport, so (x, y) lands at scene position (x * W, (1 - y) * H).

#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/SceneSettingResolver.hpp"
#include "Scene/SceneNode.h"
#include "WPSoundParser.hpp"

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include <algorithm>
#include <memory>
#include <string>
#include <vector>

namespace wallpaper
{
namespace
{

constexpr double kFrame = 1.0 / 60.0;

// A stream that never decodes anything.
class MuteStream final : public audio::SoundStream {
public:
    uint64_t NextPcmData(void*, uint32_t) override { return 0; }
    void     PassDesc(const Desc&) override {}
};

// A runtime plus everything the registry only holds weakly or by raw pointer.
class Stage {
public:
    Stage(int width, int height)
        : m_runtime(CreateSceneRuntimeContext(SceneRuntimeBootstrap { .canvas_width = width,
                                                                       .canvas_height = height }))
    {
    }

    SceneRuntimeContext* operator->() { return m_runtime.get(); }
    SceneRuntimeContext& rt() { return *m_runtime; }

    void AddSound(const std::string& name, bool startSilent = true)
    {
        WPSoundStream::Config config;
        config.startsilent = startSilent;
        auto stream = std::make_shared<WPSoundStream>(
            std::vector<WPSoundStream::StreamFactory> {
                [](const audio::SoundStream::Desc&) -> std::shared_ptr<audio::SoundStream> {
                    return std::make_shared<MuteStream>();
                } },
            config);
        m_runtime->RegisterSoundLayer(name, stream);
        m_sounds.push_back(stream);
    }

    // A layer node centred on (x, y) with the given box; registered but without any binding.
    SceneNode* AddNode(const std::string& name, float x, float y, float w, float h,
                       bool visible = true)
    {
        auto node = std::make_shared<SceneNode>();
        node->SetTranslate({ x, y, 0.0f });
        node->SetVisible(visible);
        m_runtime->RegisterNode(name, node.get());
        m_runtime->RegisterNodeSize(name, { w, h });
        m_nodes.push_back(node);
        return node.get();
    }

    // A layer whose visibility is a property script.
    SceneNode* AddScriptedNode(const std::string& name, float x, float y, float w, float h,
                               const nlohmann::json& setting, bool visible = true)
    {
        SceneNode* node = AddNode(name, x, y, w, h, visible);
        m_runtime->RegisterNodeVisibility(name, node, ResolveBoolSetting(*m_runtime, setting, name));
        return node;
    }

    // Cursor state for the coming frames. Edge masks persist until they are set again.
    void Cursor(float x, float y, bool entered, uint32_t down = 0, uint32_t pressed = 0,
                uint32_t released = 0)
    {
        m_runtime->SetCursorInput(x, y);
        m_runtime->SetCursorEnter(entered);
        m_runtime->SetCursorButtons(down, pressed, released);
    }

    // One delivery pass; the in-window answer is threaded into the next pass.
    bool Dispatch()
    {
        m_inWindow = m_runtime->DispatchCursorFrameEvents(m_inWindow);
        return m_inWindow;
    }
    void Tick() { m_runtime->Tick(kFrame); }
    bool Frame()
    {
        const bool result = Dispatch();
        Tick();
        return result;
    }

    bool Playing(const std::string& name) { return m_runtime->SoundLayerPlaying(name); }

private:
    std::unique_ptr<SceneRuntimeContext>    m_runtime;
    std::vector<std::shared_ptr<WPSoundStream>> m_sounds;
    std::vector<std::shared_ptr<SceneNode>> m_nodes;
    bool                                    m_inWindow { false };
};

// Property-script setting with a boolean value.
nlohmann::json VisibilitySetting(const std::string& module, bool value,
                                 nlohmann::json properties = nullptr)
{
    nlohmann::json setting = { { "value", value }, { "script", module } };
    if (!properties.is_null()) {
        setting["scriptproperties"] = std::move(properties);
    }
    return setting;
}

// ---- geometry of the 400x300 button fixture ---------------------------------------------

// Button box: x 150..250, y 250..290 (scene y grows upward).
constexpr float kButtonX = 200.0f, kButtonY = 270.0f, kButtonW = 100.0f, kButtonH = 40.0f;
// Normalized cursor positions: inside the box, far above it, in the middle, right of it.
constexpr float kInsideX = 0.5f, kInsideY = 0.1f;
constexpr float kOutsideX = 0.5f, kOutsideY = 0.9f;
constexpr float kMidX = 0.5f, kMidY = 0.5f;

Stage ButtonStage()
{
    return Stage(400, 300);
}

const char* kPlayOnClickModule = R"js(
export function update(value) { return value; }
export function cursorClick() { thisScene.getObject('clickSound').play(); }
)js";

// ---------------------------------------------------------------------------------------

TEST(SoundLayerScripts, ASceneScriptStartsASoundLayerThatIsNotPlaying)
{
    Stage stage(3840, 2160);
    stage.AddSound("music");
    stage.AddSound("bystander");
    ASSERT_TRUE(stage->HasSoundLayer("music"));
    EXPECT_FALSE(stage.Playing("music"));

    stage->RegisterSceneScript(R"js(
        function update() {
            var layer = scene.getObject('music');
            if (!layer.isPlaying()) { layer.play(); }
        }
    )js", "");
    EXPECT_EQ(stage->sceneScriptCount(), 1u);

    stage.Tick();
    EXPECT_TRUE(stage.Playing("music"));
    EXPECT_EQ(stage->scriptErrorCount(), 0u);

    // The guard reads the native stream, so a further frame leaves it playing.
    stage.Tick();
    EXPECT_TRUE(stage.Playing("music"));
    EXPECT_EQ(stage->scriptErrorCount(), 0u);

    // Only the layer the script named was started.
    EXPECT_FALSE(stage.Playing("bystander"));
}

TEST(SoundLayerScripts, ASceneScriptSeesTheNativeStateOfALayerThatIsAlreadyPlaying)
{
    Stage stage(3840, 2160);
    stage.AddSound("music", /*startSilent=*/false);
    stage.AddNode("lamp", 100, 100, 10, 10, /*visible=*/false);
    ASSERT_TRUE(stage.Playing("music"));

    // The lamp is lit exactly while the script's view of the layer says it plays.
    stage->RegisterSceneScript(
        "function update() { scene.getObject('lamp').visible = scene.getObject('music').isPlaying(); }", "");
    stage.Tick();
    EXPECT_TRUE(stage->NodeVisible("lamp"));

    stage->StopSoundLayer("music");
    stage.Tick();
    EXPECT_FALSE(stage->NodeVisible("lamp"));
    EXPECT_EQ(stage->scriptErrorCount(), 0u);
}

TEST(SoundLayerScripts, HoveringTheSceneIsNotAClick)
{
    Stage stage(3840, 2160);
    stage.AddSound("clickSound");
    stage->RegisterSceneScript("function cursorClick() { scene.getObject('clickSound').play(); }", "");
    ASSERT_EQ(stage->sceneScriptCount(), 1u);

    stage.Cursor(0.25f, 0.75f, true);
    EXPECT_TRUE(stage.Dispatch());
    EXPECT_TRUE(stage.Dispatch());
    stage.Tick();
    EXPECT_FALSE(stage.Playing("clickSound"));
    EXPECT_EQ(stage->scriptErrorCount(), 0u);

    // Moving about and leaving the window does not click either.
    stage.Cursor(0.6f, 0.4f, true);
    stage.Frame();
    stage.Cursor(0.6f, 0.4f, false);
    stage.Frame();
    EXPECT_FALSE(stage.Playing("clickSound"));
    EXPECT_EQ(stage->scriptErrorCount(), 0u);
}

TEST(SoundLayerScripts, OnePressEdgeIsExactlyOneClick)
{
    Stage stage(3840, 2160);
    stage.AddSound("clickSound");
    stage->RegisterSceneScript(R"js(
        var clicks = 0;
        function cursorClick() { clicks += 1; scene.getObject('clickSound').play(); }
        function update() { if (clicks > 1) { scene.getObject('clickSound').stop(); } }
    )js", "");

    // A tap whose press and release edges both land in the first frame.
    stage.Cursor(0.25f, 0.75f, true, 0, 1, 1);
    stage.Dispatch();
    stage.Cursor(0.25f, 0.75f, true, 0, 0, 0);
    EXPECT_TRUE(stage.Dispatch());
    stage.Tick();
    EXPECT_TRUE(stage.Playing("clickSound")) << "one tap reached the script more than once";
    EXPECT_EQ(stage->scriptErrorCount(), 0u);

    // A second tap is the second click: the script's own guard now stops the layer.
    stage.Cursor(0.25f, 0.75f, true, 0, 1, 1);
    stage.Frame();
    EXPECT_FALSE(stage.Playing("clickSound"));
    EXPECT_EQ(stage->scriptErrorCount(), 0u);
}

TEST(SoundLayerScripts, APressWhileThePointerIsOutsideTheWindowIsNotDelivered)
{
    Stage stage(3840, 2160);
    stage.AddSound("clickSound");
    stage->RegisterSceneScript("function cursorClick() { scene.getObject('clickSound').play(); }", "");

    stage.Cursor(0.25f, 0.75f, false, 0, 1, 0);
    EXPECT_FALSE(stage.Frame());
    EXPECT_FALSE(stage.Playing("clickSound"));
    EXPECT_EQ(stage->scriptErrorCount(), 0u);
}

TEST(SoundLayerScripts, ALayerBoundSceneScriptIgnoresClicksOutsideItsLayer)
{
    const char* source = "function cursorClick() { thisScene.getObject('clickSound').play(); }";

    Stage stage = ButtonStage();
    stage.AddSound("clickSound");
    stage.AddNode("button", kButtonX, kButtonY, kButtonW, kButtonH);
    stage->RegisterSceneScript(source, "button");

    stage.Cursor(kOutsideX, kOutsideY, true, 0, 1, 1);
    EXPECT_TRUE(stage.Frame());
    EXPECT_FALSE(stage.Playing("clickSound"));

    stage.Cursor(kInsideX, kInsideY, true, 0, 1, 1);
    EXPECT_TRUE(stage.Frame());
    EXPECT_TRUE(stage.Playing("clickSound"));
    EXPECT_EQ(stage->scriptErrorCount(), 0u);

    // Right of the box (x = 280 > 250) is outside as well.
    Stage right = ButtonStage();
    right.AddSound("clickSound");
    right.AddNode("button", kButtonX, kButtonY, kButtonW, kButtonH);
    right->RegisterSceneScript(source, "button");
    right.Cursor(0.7f, kInsideY, true, 0, 1, 1);
    EXPECT_TRUE(right.Frame());
    EXPECT_FALSE(right.Playing("clickSound"));
    EXPECT_EQ(right->scriptErrorCount(), 0u);
}

TEST(SoundLayerScripts, APropertyScriptOnALayerIgnoresClicksOutsideIt)
{
    Stage stage = ButtonStage();
    stage.AddSound("clickSound");
    stage.AddScriptedNode("button", kButtonX, kButtonY, kButtonW, kButtonH,
                          VisibilitySetting(kPlayOnClickModule, true));
    EXPECT_EQ(stage->sceneScriptCount(), 1u);

    stage.Cursor(kOutsideX, kOutsideY, true, 0, 1, 1);
    EXPECT_TRUE(stage.Frame());
    EXPECT_FALSE(stage.Playing("clickSound"));

    stage.Cursor(kInsideX, kInsideY, true, 0, 1, 1);
    EXPECT_TRUE(stage.Frame());
    EXPECT_TRUE(stage.Playing("clickSound"));
    EXPECT_EQ(stage->scriptErrorCount(), 0u);

    // The script returned its argument untouched, so the layer is still shown.
    EXPECT_TRUE(stage->NodeVisible("button"));
}

TEST(SoundLayerScripts, IdenticalScriptsOnTwoLayersEachTestTheirOwnBox)
{
    const char* module = R"js(
        export var scriptProperties = createScriptProperties()
            .addText({ name: 'voice1', label: 'voice', value: '' })
            .finish();
        export function update(value) { return value; }
        export function cursorClick() { thisScene.getLayer(scriptProperties.voice1).play(); }
    )js";

    auto build = [&](Stage& stage) {
        stage.AddSound("soundA");
        stage.AddSound("soundB");
        stage.AddScriptedNode("__we_layer_20", 100, 150, 80, 80,
                              VisibilitySetting(module, true, { { "voice1", "soundA" } }));
        stage.AddScriptedNode("__we_layer_21", 300, 150, 80, 80,
                              VisibilitySetting(module, true, { { "voice1", "soundB" } }));
    };

    {
        Stage stage(400, 300);
        build(stage);
        EXPECT_EQ(stage->sceneScriptCount(), 2u);

        // (100, 150): inside the first box only.
        stage.Cursor(0.25f, 0.5f, true);
        EXPECT_TRUE(stage.Frame());
        EXPECT_FALSE(stage.Playing("soundA"));
        EXPECT_FALSE(stage.Playing("soundB"));

        stage.Cursor(0.25f, 0.5f, true, 0, 1, 1);
        stage.Frame();
        EXPECT_TRUE(stage.Playing("soundA"));
        EXPECT_FALSE(stage.Playing("soundB"));
        EXPECT_EQ(stage->scriptErrorCount(), 0u);
    }
    {
        // (300, 150): inside the second box only.
        Stage stage(400, 300);
        build(stage);
        stage.Cursor(0.75f, 0.5f, true, 0, 1, 1);
        stage.Frame();
        EXPECT_TRUE(stage.Playing("soundB"));
        EXPECT_FALSE(stage.Playing("soundA"));
        EXPECT_EQ(stage->scriptErrorCount(), 0u);
    }
    {
        // (200, 150): between the boxes.
        Stage stage(400, 300);
        build(stage);
        stage.Cursor(0.5f, 0.5f, true, 0, 1, 1);
        stage.Frame();
        EXPECT_FALSE(stage.Playing("soundA"));
        EXPECT_FALSE(stage.Playing("soundB"));
        EXPECT_EQ(stage->scriptErrorCount(), 0u);
    }
}

TEST(SoundLayerScripts, EnterAndLeaveFollowTheLayersBoxEvenForAHiddenNode)
{
    const char* module = R"js(
        var entered = 0;
        var left = 0;
        export function update(value) { return entered === 1 && left === 1; }
        export function cursorEnter() { entered += 1; }
        export function cursorLeave() { left += 1; }
    )js";

    Stage stage = ButtonStage();
    stage.AddScriptedNode("button", kButtonX, kButtonY, kButtonW, kButtonH,
                          VisibilitySetting(module, false), /*visible=*/false);

    stage.Cursor(kOutsideX, kOutsideY, true);
    stage.Frame();
    EXPECT_FALSE(stage->NodeVisible("button"));

    stage.Cursor(kInsideX, kInsideY, true);
    stage.Frame();
    EXPECT_FALSE(stage->NodeVisible("button")) << "entered once, not yet left";
    // Staying over the box is not entering again.
    stage.Frame();
    EXPECT_FALSE(stage->NodeVisible("button")) << "still entered once, not yet left";

    stage.Cursor(kOutsideX, kOutsideY, true);
    EXPECT_TRUE(stage.Frame());
    EXPECT_TRUE(stage->NodeVisible("button")) << "entered once and left once";
    EXPECT_EQ(stage->scriptErrorCount(), 0u);

    // Entering a second time breaks the "exactly once" condition again.
    stage.Cursor(kInsideX, kInsideY, true);
    stage.Frame();
    EXPECT_FALSE(stage->NodeVisible("button"));
    EXPECT_EQ(stage->scriptErrorCount(), 0u);
}

const char* kEventCountingScript = R"js(
    var entered = 0, left = 0, downs = 0, ups = 0;
    function cursorEnter() { entered += 1; }
    function cursorLeave() { left += 1; }
    function cursorDown() { downs += 1; }
    function cursorUp() { ups += 1; }
    function update() {
        scene.getObject('button').visible = %s;
    }
)js";

std::string CountingScript(const std::string& condition)
{
    std::string source = kEventCountingScript;
    source.replace(source.find("%s"), 2, condition);
    return source;
}

TEST(SoundLayerScripts, ALayerThatTookAPressHearsItsReleaseAfterThePointerLeftTheWindow)
{
    Stage stage = ButtonStage();
    stage.AddNode("button", kButtonX, kButtonY, kButtonW, kButtonH, /*visible=*/false);
    stage->RegisterSceneScript(
        CountingScript("entered === 1 && left === 1 && downs === 1 && ups === 1"), "button");

    stage.Cursor(kInsideX, kInsideY, true, 1, 1, 0);
    stage.Frame();
    EXPECT_FALSE(stage->NodeVisible("button")) << "the release has not arrived yet";

    // The window is left on the very frame the button is released.
    stage.Cursor(kInsideX, kInsideY, false, 0, 0, 1);
    EXPECT_FALSE(stage.Frame());
    EXPECT_TRUE(stage->NodeVisible("button"));
    EXPECT_EQ(stage->scriptErrorCount(), 0u);
}

TEST(SoundLayerScripts, ALayerThatDidNotTakeThePressHearsNothingOfItsRelease)
{
    const auto source = CountingScript("entered === 1 && left === 1 && downs === 0 && ups === 0");

    Stage stage = ButtonStage();
    stage.AddNode("button", kButtonX, kButtonY, kButtonW, kButtonH, /*visible=*/false);
    stage->RegisterSceneScript(source, "button");

    // Pressed away from the layer.
    stage.Cursor(kMidX, kMidY, true, 1, 1, 0);
    stage.Frame();
    // Dragged onto the layer with the button still held: an enter, but no press.
    stage.Cursor(kInsideX, kInsideY, true, 1, 0, 0);
    stage.Frame();
    // Released as the window is left.
    stage.Cursor(kInsideX, kInsideY, false, 0, 0, 1);
    EXPECT_FALSE(stage.Frame());
    EXPECT_TRUE(stage->NodeVisible("button"));
    EXPECT_EQ(stage->scriptErrorCount(), 0u);

    // The same drag released while still in the window, over the layer, is delivered by position.
    Stage inside = ButtonStage();
    inside.AddNode("button", kButtonX, kButtonY, kButtonW, kButtonH, /*visible=*/false);
    inside->RegisterSceneScript(source, "button");
    inside.Cursor(kMidX, kMidY, true, 1, 1, 0);
    inside.Frame();
    inside.Cursor(kInsideX, kInsideY, true, 0, 0, 1);
    inside.Frame();
    inside.Cursor(kInsideX, kInsideY, true, 0, 0, 0);
    inside.Frame();
    EXPECT_FALSE(inside->NodeVisible("button")) << "the release over the layer counted as an up";
    EXPECT_EQ(inside->scriptErrorCount(), 0u);
}

// A file of `frames` frames of 1.0, then the end.
class ToneStream final : public audio::SoundStream {
public:
    explicit ToneStream(uint64_t frames) : m_left(frames) {}
    uint64_t NextPcmData(void* data, uint32_t count) override {
        const uint64_t n = std::min<uint64_t>(count, m_left);
        auto*          out = static_cast<float*>(data);
        for (uint64_t i = 0; i < n; ++i) out[i] = 1.0f;
        m_left -= n;
        return n;
    }
    void PassDesc(const Desc&) override {}

private:
    uint64_t m_left;
};

// `mintime`/`maxtime` are plain fields of the sound layer (we_ss_reg_SoundLayer 0x1401F7090,
// decompiles/A-7j.md): a script's write decides the silence before the next random file.
TEST(ScriptSoundLayers, MaxTimeWriteChangesTheNextDelay)
{
    Stage stage(400, 200);
    WPSoundStream::Config config;
    config.mode = PlaybackMode::Random;
    config.mintime = 1.0f;
    config.maxtime = 1.0f;
    config.random_seed = 7;
    config.playbackmode_word = "random";
    auto stream = std::make_shared<WPSoundStream>(
        std::vector<WPSoundStream::StreamFactory> {
            [](const audio::SoundStream::Desc&) -> std::shared_ptr<audio::SoundStream> {
                return std::make_shared<ToneStream>(100);
            } },
        config);
    stream->PassDesc(audio::SoundStream::Desc { .channels = 1, .sampleRate = 1000 });
    stage->RegisterSoundLayer("bell", stream);
    stage.AddScriptedNode("bell", 0, 0, 1, 1, { { "value", true }, { "script", R"JS(
export function init(value) {
  if (thisLayer.maxtime !== 1 || thisLayer.playbackmode !== 'random' || thisLayer.spatialization !== false) {
    throw new Error('reads the layer');
  }
  thisLayer.mintime = 3;
  thisLayer.maxtime = 3;
  thisLayer.attenuation = 0.5;
  if (thisLayer.maxtime !== 3 || thisLayer.attenuation !== 0.5) throw new Error('reads back');
  return value;
}
)JS" } });
    stage.Tick();
    EXPECT_EQ(stage->scriptErrorCount(), 0u);
    std::vector<float> pcm(5000, 0.0f);
    stream->NextPcmData(pcm.data(), static_cast<uint32_t>(pcm.size()));
    std::size_t next = 100;
    while (next < pcm.size() && pcm[next] == 0.0f) ++next;
    EXPECT_EQ(next, 3100u) << "three seconds of silence after the first file";
}

} // namespace
} // namespace wallpaper
