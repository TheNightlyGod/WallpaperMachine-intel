// What the scene runtime does with raw pointer input: the state it publishes to scripts
// (position, window flag, button masks), how window-normalized input maps into scene units,
// and which cursor callbacks a scene-level script hears. Headless: a runtime without a scene.

#include "Runtime/SceneRuntimeContext.hpp"
#include "Scene/SceneNode.h"
#include "Scripting/ScriptEngine.hpp"

#include <gtest/gtest.h>

#include <cmath>
#include <functional>
#include <initializer_list>
#include <limits>
#include <memory>
#include <string>
#include <vector>

using namespace wallpaper;

namespace
{

constexpr int kCanvasWidth  = 1920;
constexpr int kCanvasHeight = 1080;

std::unique_ptr<SceneRuntimeContext> NewRuntime() {
    auto runtime = CreateSceneRuntimeContext(
        SceneRuntimeBootstrap { .canvas_width = kCanvasWidth, .canvas_height = kCanvasHeight });
    EXPECT_NE(runtime, nullptr);
    return runtime;
}

// The three button masks the host publishes, in one comparable value.
struct Buttons {
    uint32_t down;
    uint32_t pressed;
    uint32_t released;
    bool     operator==(const Buttons&) const = default;
};

Buttons ButtonsOf(const SceneRuntimeContext& runtime) {
    const ScriptHostContext& host = runtime.hostContext();
    return { host.mouse_buttons_down, host.mouse_buttons_pressed, host.mouse_buttons_released };
}

::testing::AssertionResult ButtonsAre(const SceneRuntimeContext& runtime, Buttons expected) {
    const Buttons got = ButtonsOf(runtime);
    if (got == expected) return ::testing::AssertionSuccess();
    return ::testing::AssertionFailure()
           << "down/pressed/released = " << got.down << "/" << got.pressed << "/" << got.released
           << ", expected " << expected.down << "/" << expected.pressed << "/" << expected.released;
}

// A hidden scene node the test can find again by name; scripts reveal it through
// `scene.getObject(name).visible`.
class Probes {
public:
    explicit Probes(SceneRuntimeContext& runtime) : m_runtime(runtime) {}

    void Add(const std::string& name) {
        auto node = std::make_shared<SceneNode>();
        node->SetVisible(false);
        m_runtime.RegisterNode(name, node.get());
        m_nodes.push_back(std::move(node));
    }

    bool Shown(const std::string& name) const { return m_runtime.NodeVisible(name); }

private:
    SceneRuntimeContext&                     m_runtime;
    std::vector<std::shared_ptr<SceneNode>> m_nodes;
};

const std::string kHandlerNames[] = { "enter", "leave", "move", "down", "up", "click" };

// Probe names are "<handler>_<n>": shown while that handler has run exactly n times.
std::string ProbeName(const std::string& handler, int times) {
    return handler + "_" + std::to_string(times);
}

// A scene script that counts each cursor handler. `down`, `up` and `click` only count when
// the event names button 0; `down` and `move` also demand that the script reads the pointer
// at (0.25, 0.75). A delivery that fails those checks lands in `bad`, shown by probe "bad".
std::string CountingScript(std::initializer_list<int> shown_counts) {
    std::string counts = "[";
    for (int n : shown_counts) counts += std::to_string(n) + ",";
    counts += "]";
    return R"(
let n = { enter: 0, leave: 0, move: 0, down: 0, up: 0, click: 0 };
let bad = 0;
const atExpectedSpot = () =>
    input.cursorPosition.x === 0.25 && input.cursorPosition.y === 0.75;
export function cursorEnter() { n.enter++; }
export function cursorLeave() { n.leave++; }
export function cursorMove() { if (atExpectedSpot()) n.move++; else bad++; }
export function cursorDown(event) {
    if (event.button === 0 && atExpectedSpot()) n.down++; else bad++;
}
export function cursorUp(event) { if (event.button === 0) n.up++; else bad++; }
export function cursorClick(event) { if (event.button === 0) n.click++; else bad++; }
export function update() {
    for (const handler of Object.keys(n)) {
        for (const times of )" + counts + R"() {
            scene.getObject(handler + "_" + times).visible = n[handler] === times;
        }
    }
    scene.getObject("bad").visible = bad > 0;
}
)";
}

} // namespace

// MI-01
TEST(CursorInputState, PublishesPositionWindowFlagAndButtonMasksThroughAPressFrameAndRelease) {
    auto runtime = NewRuntime();
    ASSERT_NE(runtime, nullptr);
    const ScriptHostContext& host = runtime->hostContext();

    runtime->SetCursorInput(0.25f, 0.75f);
    runtime->SetCursorEnter(true);
    runtime->SetCursorButton(0, true);
    EXPECT_EQ(host.cursor_normalized_position.x(), 0.25f);
    EXPECT_EQ(host.cursor_normalized_position.y(), 0.75f);
    EXPECT_TRUE(host.cursor_in_window);
    EXPECT_TRUE(ButtonsAre(*runtime, { 1, 1, 0 })) << "after the press";

    runtime->BeginFrame();
    EXPECT_EQ(host.cursor_normalized_position.x(), 0.25f);
    EXPECT_EQ(host.cursor_normalized_position.y(), 0.75f);
    EXPECT_TRUE(host.cursor_in_window);
    EXPECT_TRUE(ButtonsAre(*runtime, { 1, 0, 0 })) << "a new frame keeps the button held";

    runtime->SetCursorButton(0, false);
    EXPECT_EQ(host.cursor_normalized_position.x(), 0.25f);
    EXPECT_EQ(host.cursor_normalized_position.y(), 0.75f);
    EXPECT_TRUE(host.cursor_in_window);
    EXPECT_TRUE(ButtonsAre(*runtime, { 0, 0, 1 })) << "after the release";

    runtime->SetCursorEnter(false);
    EXPECT_EQ(host.cursor_normalized_position.x(), 0.25f);
    EXPECT_EQ(host.cursor_normalized_position.y(), 0.75f);
    EXPECT_FALSE(host.cursor_in_window);
    EXPECT_TRUE(ButtonsAre(*runtime, { 0, 0, 1 })) << "leaving does not touch the edges";

    runtime->BeginFrame();
    EXPECT_TRUE(ButtonsAre(*runtime, { 0, 0, 0 })) << "the release edge lasts one frame";
}

// MI-02
TEST(CursorInputState, PressAndReleaseEdgesFollowRealStateChanges) {
    {
        auto runtime = NewRuntime();
        ASSERT_NE(runtime, nullptr);
        runtime->SetCursorButton(0, true);
        runtime->BeginFrame();
        runtime->SetCursorButton(0, true);
        EXPECT_TRUE(ButtonsAre(*runtime, { 1, 0, 0 })) << "a repeated press is no new edge";

        runtime->SetCursorButton(0, false);
        runtime->BeginFrame();
        runtime->SetCursorButton(0, false);
        EXPECT_TRUE(ButtonsAre(*runtime, { 0, 0, 0 })) << "a repeated release is no new edge";
    }
    {
        auto runtime = NewRuntime();
        ASSERT_NE(runtime, nullptr);
        runtime->SetCursorButton(1, false);
        EXPECT_TRUE(ButtonsAre(*runtime, { 0, 0, 0 })) << "releasing a button that was never down";
    }
    {
        auto runtime = NewRuntime();
        ASSERT_NE(runtime, nullptr);
        runtime->SetCursorButton(0, true);
        runtime->SetCursorButton(1, true);
        EXPECT_TRUE(ButtonsAre(*runtime, { 3, 3, 0 })) << "two buttons in one frame";
        runtime->SetCursorButton(0, false);
        EXPECT_TRUE(ButtonsAre(*runtime, { 2, 3, 1 })) << "releasing the first of the two";
    }
    {
        auto runtime = NewRuntime();
        ASSERT_NE(runtime, nullptr);
        runtime->SetCursorButton(-1, true);
        runtime->SetCursorButton(32, true);
        EXPECT_TRUE(ButtonsAre(*runtime, { 0, 0, 0 })) << "indices outside 0..31 are ignored";
    }
}

// MI-03
TEST(CursorInputState, ClampsNormalizedInputAndTurnsNonFiniteValuesIntoZero) {
    auto runtime = NewRuntime();
    ASSERT_NE(runtime, nullptr);
    const ScriptHostContext& host = runtime->hostContext();

    runtime->SetCursorInput(-0.25f, 1.25f);
    EXPECT_EQ(host.cursor_normalized_position.x(), 0.0f);
    EXPECT_EQ(host.cursor_normalized_position.y(), 1.0f);
    EXPECT_EQ(host.cursor_world_position.x(), 0.0f);
    EXPECT_EQ(host.cursor_world_position.y(), 0.0f);

    runtime->SetCursorInput(1.5f, -3.0f);
    EXPECT_EQ(host.cursor_normalized_position.x(), 1.0f);
    EXPECT_EQ(host.cursor_normalized_position.y(), 0.0f);
    EXPECT_EQ(host.cursor_world_position.x(), 1920.0f);
    EXPECT_EQ(host.cursor_world_position.y(), 1080.0f);

    runtime->SetCursorInput(std::numeric_limits<float>::quiet_NaN(),
                            std::numeric_limits<float>::infinity());
    EXPECT_EQ(host.cursor_normalized_position.x(), 0.0f);
    EXPECT_EQ(host.cursor_normalized_position.y(), 0.0f) << "infinity is not clamped to 1";
    EXPECT_EQ(host.cursor_world_position.x(), 0.0f);
    EXPECT_EQ(host.cursor_world_position.y(), 1080.0f);
}

// MI-04
TEST(CursorInputState, WorldPositionRunsUpwardFromTheBottomOfTheViewport) {
    auto runtime = NewRuntime();
    ASSERT_NE(runtime, nullptr);
    const ScriptHostContext& host = runtime->hostContext();

    runtime->SetCursorInput(0.25f, 0.25f);
    const linalg::Vector3f high = host.cursor_world_position;
    EXPECT_EQ(high.x(), 480.0f);
    EXPECT_EQ(high.y(), 810.0f);

    runtime->SetCursorInput(0.25f, 0.75f);
    const linalg::Vector3f low = host.cursor_world_position;
    EXPECT_EQ(low.x(), 480.0f);
    EXPECT_EQ(low.y(), 270.0f);
    EXPECT_GT(high.y(), low.y()) << "higher on the screen means a larger y";

    const struct {
        float x, y, world_x, world_y;
    } corners[] = {
        { 0.0f, 0.0f, 0.0f, 1080.0f },
        { 1.0f, 1.0f, 1920.0f, 0.0f },
        { 0.5f, 0.5f, 960.0f, 540.0f },
    };
    for (const auto& c : corners) {
        SCOPED_TRACE(testing::Message() << "input (" << c.x << ", " << c.y << ")");
        runtime->SetCursorInput(c.x, c.y);
        EXPECT_EQ(host.cursor_world_position.x(), c.world_x);
        EXPECT_EQ(host.cursor_world_position.y(), c.world_y);
    }

    // A window that shows only part of the canvas maps onto that part.
    runtime->SetCursorViewport(CursorViewport { .origin         = { 100.0f, 50.0f },
                                                .size           = { 800.0f, 600.0f },
                                                .content_origin = { 100.0f, 50.0f },
                                                .content_size   = { 800.0f, 600.0f } });
    runtime->SetCursorInput(0.5f, 0.5f);
    EXPECT_EQ(host.cursor_world_position.x(), 500.0f);
    EXPECT_EQ(host.cursor_world_position.y(), 350.0f);
    runtime->SetCursorInput(0.0f, 1.0f);
    EXPECT_EQ(host.cursor_world_position.x(), 100.0f);
    EXPECT_EQ(host.cursor_world_position.y(), 50.0f);
}

// MI-05
TEST(CursorInputState, SceneScriptHearsEveryDirectDispatchExactlyOnce) {
    auto runtime = NewRuntime();
    ASSERT_NE(runtime, nullptr);
    Probes probes(*runtime);
    for (const auto& handler : kHandlerNames) {
        probes.Add(ProbeName(handler, 1));
        probes.Add(ProbeName(handler, 2));
    }
    probes.Add("bad");

    runtime->RegisterSceneScript(CountingScript({ 1, 2 }), "");
    ASSERT_EQ(runtime->sceneScriptCount(), 1u);

    // One visit of the pointer: it arrives, presses, lifts and leaves, with each direct
    // dispatcher called once at the point where the host would call it.
    SceneRuntimeContext& rt = *runtime;
    const std::vector<std::function<void()>> visit = {
        [&rt] { rt.SetCursorInput(0.25f, 0.75f); },
        [&rt] { rt.SetCursorEnter(true); },
        [&rt] { rt.SetCursorButton(0, true); },
        [&rt] { rt.DispatchCursorEnter(); },
        [&rt] { rt.DispatchCursorMove(); },
        [&rt] { rt.DispatchCursorDown(0); },
        [&rt] { rt.DispatchCursorClick(0); },
        [&rt] { rt.SetCursorButton(0, false); },
        [&rt] { rt.DispatchCursorUp(0); },
        [&rt] { rt.SetCursorEnter(false); },
        [&rt] { rt.DispatchCursorLeave(); },
    };
    const auto run_round = [&] {
        for (const auto& step : visit) step();
        rt.Tick(1.0 / 60.0);
    };

    for (int round = 1; round <= 2; ++round) {
        SCOPED_TRACE(testing::Message() << "round " << round);
        run_round();
        for (const auto& handler : kHandlerNames) {
            EXPECT_TRUE(probes.Shown(ProbeName(handler, round)))
                << handler << " should have run exactly " << round << " time(s)";
            EXPECT_FALSE(probes.Shown(ProbeName(handler, 3 - round)))
                << handler << " ran the wrong number of times";
        }
        EXPECT_FALSE(probes.Shown("bad")) << "a handler saw the wrong button or pointer position";
        EXPECT_EQ(runtime->scriptErrorCount(), 0u);
    }
}

// MI-06
TEST(CursorInputState, SceneScriptStillGetsTheReleaseAfterThePointerLeftTheWindow) {
    auto runtime = NewRuntime();
    ASSERT_NE(runtime, nullptr);
    Probes probes(*runtime);
    for (const auto& handler : kHandlerNames) {
        probes.Add(ProbeName(handler, 0));
        probes.Add(ProbeName(handler, 1));
        probes.Add(ProbeName(handler, 2));
    }
    probes.Add("bad");

    runtime->RegisterSceneScript(CountingScript({ 0, 1, 2 }), "");
    ASSERT_EQ(runtime->sceneScriptCount(), 1u);

    // Frame 1: the pointer arrives and presses.
    runtime->SetCursorInput(0.25f, 0.75f);
    runtime->SetCursorEnter(true);
    runtime->SetCursorButtons(1, 1, 0);
    bool in_window = runtime->DispatchCursorFrameEvents(false);
    EXPECT_TRUE(in_window);

    // Frame 2: it leaves and the button comes up outside.
    runtime->SetCursorEnter(false);
    runtime->SetCursorButtons(0, 0, 1);
    in_window = runtime->DispatchCursorFrameEvents(in_window);
    EXPECT_FALSE(in_window);

    runtime->Tick(1.0 / 60.0);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
    EXPECT_TRUE(probes.Shown(ProbeName("down", 1))) << "the press edge inside";
    EXPECT_TRUE(probes.Shown(ProbeName("leave", 1))) << "the pointer left";
    EXPECT_TRUE(probes.Shown(ProbeName("up", 1))) << "the release, though outside";
    EXPECT_TRUE(probes.Shown(ProbeName("enter", 1)));
    EXPECT_TRUE(probes.Shown(ProbeName("click", 1)));
    EXPECT_FALSE(probes.Shown("bad"));
}

TEST(CursorInputState, FrameDispatcherSendsEnterOnceMovesEveryFrameAndNoPressOutsideTheWindow) {
    auto runtime = NewRuntime();
    ASSERT_NE(runtime, nullptr);
    Probes probes(*runtime);
    for (const auto& handler : kHandlerNames) {
        for (int n = 0; n <= 2; ++n) probes.Add(ProbeName(handler, n));
    }
    probes.Add("bad");
    runtime->RegisterSceneScript(CountingScript({ 0, 1, 2 }), "");
    ASSERT_EQ(runtime->sceneScriptCount(), 1u);

    runtime->SetCursorInput(0.25f, 0.75f);
    runtime->SetCursorEnter(true);
    bool in_window = runtime->DispatchCursorFrameEvents(false);
    ASSERT_TRUE(in_window);
    in_window = runtime->DispatchCursorFrameEvents(in_window);
    ASSERT_TRUE(in_window);
    runtime->Tick(1.0 / 60.0);
    EXPECT_TRUE(probes.Shown(ProbeName("enter", 1))) << "an unchanged frame is no second enter";
    EXPECT_TRUE(probes.Shown(ProbeName("move", 2))) << "inside, every frame carries a move";
    EXPECT_TRUE(probes.Shown(ProbeName("down", 0)));

    // A press edge reported while the window flag is down reaches nobody.
    runtime->SetCursorEnter(false);
    runtime->SetCursorButtons(1, 1, 0);
    in_window = runtime->DispatchCursorFrameEvents(in_window);
    EXPECT_FALSE(in_window);
    runtime->Tick(1.0 / 60.0);
    EXPECT_TRUE(probes.Shown(ProbeName("down", 0))) << "no cursorDown while outside";
    EXPECT_TRUE(probes.Shown(ProbeName("click", 0)));
    EXPECT_TRUE(probes.Shown(ProbeName("leave", 1)));
    EXPECT_FALSE(probes.Shown("bad"));
}

// Which button an event reports: the direct dispatchers take it as an argument and the frame
// dispatcher reads it from the masks.
TEST(CursorInputState, ButtonEventsNameTheButtonThatWasPressed) {
    auto runtime = NewRuntime();
    ASSERT_NE(runtime, nullptr);
    Probes probes(*runtime);
    for (const char* handler : { "down", "up", "click" }) {
        for (int button : { 1, 2 }) probes.Add(std::string(handler) + "_" + std::to_string(button));
    }
    runtime->RegisterSceneScript(R"(
let last = { down: -1, up: -1, click: -1 };
export function cursorDown(event) { last.down = event.button; }
export function cursorUp(event) { last.up = event.button; }
export function cursorClick(event) { last.click = event.button; }
export function update() {
    for (const handler of Object.keys(last)) {
        for (const button of [1, 2]) {
            scene.getObject(handler + "_" + button).visible = last[handler] === button;
        }
    }
}
)", "");
    ASSERT_EQ(runtime->sceneScriptCount(), 1u);

    runtime->DispatchCursorDown(1);
    runtime->DispatchCursorClick(1);
    runtime->DispatchCursorUp(1);
    runtime->Tick(1.0 / 60.0);
    for (const char* handler : { "down", "up", "click" }) {
        EXPECT_TRUE(probes.Shown(std::string(handler) + "_1")) << handler << " by direct dispatch";
    }

    // Button 2 through the frame dispatcher: bit 1 << 2 of the masks.
    runtime->SetCursorEnter(true);
    runtime->SetCursorButtons(4, 4, 0);
    bool in_window = runtime->DispatchCursorFrameEvents(true);
    runtime->SetCursorButtons(0, 0, 4);
    in_window = runtime->DispatchCursorFrameEvents(in_window);
    runtime->Tick(1.0 / 60.0);
    for (const char* handler : { "down", "up", "click" }) {
        EXPECT_TRUE(probes.Shown(std::string(handler) + "_2")) << handler << " by frame dispatch";
        EXPECT_FALSE(probes.Shown(std::string(handler) + "_1"));
    }
}
