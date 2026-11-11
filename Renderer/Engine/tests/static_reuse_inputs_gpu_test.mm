// Static reuse of passes whose only per-frame input is the audio spectrum. Every case runs one
// layer whose chain rewrites its first buffer later in the frame, as an audio visualizer under a
// spinning effect does: the card into the first buffer, an audio effect from it into the second,
// a timed effect back into the first, and a closing pass onto the scene. Each run's pictures are
// compared, frame by frame, with the same frames drawn with scene optimisation off. Every GPU
// image is private to the process.

#include "support/gpu_scene.hpp"
#include "render_fixtures.hpp"
#include "Audio/AudioResponseService.h"
#include "MetalRender/MetalRender.hpp"
#include "RenderCommon/StaticSubgraphCache.hpp"
#include "Runtime/SceneRuntimeContext.hpp"

#include <gtest/gtest.h>

#include <functional>
#include <string>
#include <vector>

// Declared in no header: the audio library defines it for test builds only.
namespace wallpaper::audio
{
void SetAudioSpectrumSnapshotForTesting(const AudioSpectrumSnapshot& snapshot);
}

namespace
{
using namespace wallpaper;
using namespace we_test;
using namespace we_test::fixtures;

// Bars of the two bands it reads; it declares the chain's picture and never samples it, as
// Miyabi's visualizer (workshop 3605510527) does.
const char* kBarsIgnoringInput = R"(varying vec2 v_TexCoord;
uniform sampler2D g_Texture0;
uniform float g_AudioSpectrum16Left[16];
void main() {
    gl_FragColor = vec4(g_AudioSpectrum16Left[0], g_AudioSpectrum16Left[15], 0.25, 1.0);
}
)";

// The same bars over the chain's picture.
const char* kBarsOverInput = R"(varying vec2 v_TexCoord;
uniform sampler2D g_Texture0;
uniform float g_AudioSpectrum16Left[16];
void main() {
    gl_FragColor = texSample2D(g_Texture0, v_TexCoord) *
                   vec4(g_AudioSpectrum16Left[0], g_AudioSpectrum16Left[15], 0.25, 1.0);
}
)";

// Samples the chain's picture only in the variant its combo selects.
const char* kBarsOverInputWhenCombo(int on)
{
    static const std::string on_text = std::string(R"(// [COMBO] {"material":"Read input","combo":"READINPUT","type":"options","default":1}
)") + R"(varying vec2 v_TexCoord;
uniform sampler2D g_Texture0;
uniform float g_AudioSpectrum16Left[16];
void main() {
    vec4 bars = vec4(g_AudioSpectrum16Left[0], g_AudioSpectrum16Left[15], 0.25, 1.0);
#if READINPUT
    bars *= texSample2D(g_Texture0, v_TexCoord);
#endif
    gl_FragColor = bars;
}
)";
    static const std::string off_text = [] {
        std::string text = on_text;
        text.replace(text.find("\"default\":1"), 11, "\"default\":0");
        return text;
    }();
    return on ? on_text.c_str() : off_text.c_str();
}

// Reads the chain's picture through an element of a local array picked per fragment.
const char* kBarsThroughAnArray = R"(varying vec2 v_TexCoord;
uniform sampler2D g_Texture0;
uniform float g_AudioSpectrum16Left[16];
void main() {
    vec4 taps[2];
    taps[0] = vec4(g_AudioSpectrum16Left[0], g_AudioSpectrum16Left[15], 0.25, 1.0);
    taps[1] = texSample2D(g_Texture0, v_TexCoord);
    gl_FragColor = taps[int(step(0.5, v_TexCoord.x))];
}
)";

// A picture that changes every frame, so the buffer it writes is never reusable.
const char* kPulse = R"(varying vec2 v_TexCoord;
uniform sampler2D g_Texture0;
uniform float g_Time;
void main() {
    vec4 colour = texSample2D(g_Texture0, v_TexCoord);
    gl_FragColor = vec4(colour.rgb * (0.75 + 0.25 * sin(g_Time * 3.0)), 1.0);
}
)";

const char* kPassThrough = R"(varying vec2 v_TexCoord;
uniform sampler2D g_Texture0;
void main() {
    gl_FragColor = texSample2D(g_Texture0, v_TexCoord);
}
)";

/// The card, `bars`, a timed pulse and a closing pass, on a 64 by 64 canvas.
void VisualizerScene(ScenePackage& package, const char* bars)
{
    const auto bars_effect  = AddFragmentEffect(package, "bars", bars);
    const auto pulse_effect = AddFragmentEffect(package, "pulse", kPulse);
    const auto close_effect = AddFragmentEffect(package, "close", kPassThrough);
    ImageLayer card;
    card.id      = 1;
    card.origin  = { 32.0f, 32.0f, 0.0f };
    card.size    = { 64.0f, 64.0f };
    card.model   = package.AddImageModel("card", "util/white", { .blending = "disabled" });
    card.effects = { EffectUse(bars_effect, Json::object(), 7), EffectUse(pulse_effect, Json::object(), 8),
                     EffectUse(close_effect, Json::object(), 9) };
    SceneGeneral general;
    general.canvas_width  = 64;
    general.canvas_height = 64;
    package.SetProject();
    package.SetScene(SceneJson(general, { ImageLayerJson(card) }));
}

/// What one frame set the spectrum to.
using SpectrumStep = std::function<void(audio::AudioSpectrumSnapshot&)>;

struct Frame
{
    uint64_t skipped { 0 };
    we_test::Image picture;
};

struct Switches
{
    bool optimisation { true };
    bool audio_reuse { true };
};

struct AudioServiceReset
{
    ~AudioServiceReset() { audio::ResetAudioResponseServiceForTesting(); }
};

struct SwitchesRestored
{
    ~SwitchesRestored() { metal::MetalRender::SetAudioReuseForTests(true); }
};

/// Draws the scene once per step with that step's spectrum; frame N reads exactly the spectrum
/// step N left (the snapshot the service holds when the frame begins).
std::vector<Frame> DrawScript(const char* bars, const Switches& switches,
                              const std::vector<SpectrumStep>& steps, std::string* error)
{
    const AudioServiceReset reset;
    const SwitchesRestored  restored;
    metal::MetalRender::SetAudioReuseForTests(switches.audio_reuse);
    ScenePackage package;
    VisualizerScene(package, bars);
    GpuSceneOptions options;
    options.width              = 64;
    options.height             = 64;
    options.scene_optimization = switches.optimisation;
    std::vector<Frame> frames;
    audio::AudioSpectrumSnapshot spectrum {};
    audio::SetAudioSpectrumSnapshotForTesting(spectrum);
    GpuScene scene(package, options);
    if (! scene.ok()) {
        *error = scene.error();
        return frames;
    }
    if (scene.runtime() == nullptr) {
        *error = "the scene has no runtime to hear audio";
        return frames;
    }
    scene.runtime()->SetAudioResponseEnabled(true);
    if (! scene.runtime()->AudioResponseActive()) {
        *error = "the bars did not make the scene listen";
        return frames;
    }
    for (const auto& step : steps) {
        step(spectrum);
        ++spectrum.generation;
        audio::SetAudioSpectrumSnapshotForTesting(spectrum);
        const auto before = render::CurrentSceneOptimizationTotals();
        Frame      frame;
        frame.picture = scene.Run(1);
        if (frame.picture.empty()) {
            *error = scene.error();
            return frames;
        }
        const auto after = render::CurrentSceneOptimizationTotals();
        frame.skipped = after.skipped_passes - before.skipped_passes;
        frames.push_back(std::move(frame));
    }
    return frames;
}

/// Every picture equal to the one drawn with scene optimisation off.
void ExpectSamePictures(const std::vector<Frame>& frames, const std::vector<Frame>& reference)
{
    ASSERT_EQ(frames.size(), reference.size());
    for (std::size_t i = 0; i < frames.size(); ++i) {
        EXPECT_TRUE(frames[i].picture.rgba == reference[i].picture.rgba)
            << "frame " << i << " differs from the picture drawn with scene optimisation off";
    }
}

const SpectrumStep kKeep = [](audio::AudioSpectrumSnapshot&) {};
const SpectrumStep kSilence = [](audio::AudioSpectrumSnapshot& s) { s = audio::AudioSpectrumSnapshot { .generation = s.generation }; };
SpectrumStep FirstBand(float value)
{
    return [value](audio::AudioSpectrumSnapshot& s) { s.left16[0] = value; };
}
SpectrumStep LastBand(float value)
{
    return [value](audio::AudioSpectrumSnapshot& s) { s.left16[15] = value; };
}
/// An array the bars do not bind.
SpectrumStep OtherArray(float value)
{
    return [value](audio::AudioSpectrumSnapshot& s) { s.right64.fill(value); };
}

/// The script below with whether the audio pass may be reused on that frame: reused exactly
/// when nothing it binds changed since the frame before. The first frame draws everything.
struct Scripted
{
    std::vector<SpectrumStep> steps;
    std::vector<bool>         reusable;
};

Scripted SpectrumScript()
{
    Scripted script;
    const auto add = [&script](SpectrumStep step, bool reusable) {
        script.steps.push_back(std::move(step));
        script.reusable.push_back(reusable);
    };
    add(kSilence, false);           // first frame
    add(kKeep, true);               // silence again
    add(kKeep, true);
    add(FirstBand(0.5f), false);    // a band it reads
    add(kKeep, true);
    add(LastBand(0.75f), false);    // the other band it reads
    add(OtherArray(0.9f), true);    // only an array it does not bind
    add(kSilence, false);           // back to silence
    add(kKeep, true);
    add(FirstBand(0.125f), false);  // a new spectrum on every frame
    add(FirstBand(0.25f), false);
    add(FirstBand(0.375f), false);
    add(LastBand(0.5f), false);
    add(kKeep, true);
    return script;
}

class StaticReuseInputs : public ::testing::Test {
protected:
    void SetUp() override { WE_SKIP_WITHOUT_METAL(); }
};

} // namespace

TEST_F(StaticReuseInputs, AnAudioPassIsReusedExactlyWhileTheSpectrumItBindsIsUnchanged)
{
    const auto  script = SpectrumScript();
    std::string error;
    const auto  reference = DrawScript(kBarsIgnoringInput, { .optimisation = false }, script.steps, &error);
    ASSERT_EQ(reference.size(), script.steps.size()) << error;
    const auto frames = DrawScript(kBarsIgnoringInput, {}, script.steps, &error);
    ASSERT_EQ(frames.size(), script.steps.size()) << error;

    // Nothing else in the scene can be reused: the card's buffer is drawn again by the pulse,
    // which changes every frame, and the closing pass reads it.
    for (std::size_t i = 0; i < frames.size(); ++i) {
        EXPECT_EQ(frames[i].skipped, script.reusable[i] ? 1u : 0u)
            << "frame " << i << (script.reusable[i] ? ": an unchanged spectrum redrew the bars"
                                                    : ": a changed spectrum did not redraw the bars");
    }
    ExpectSamePictures(frames, reference);
    // The bars do show the spectrum: silence and a lit band are different pictures.
    EXPECT_FALSE(frames[2].picture.rgba == frames[4].picture.rgba);
}

TEST_F(StaticReuseInputs, WithAudioReuseOffAnAudioPassIsDrawnEveryFrame)
{
    const auto  script = SpectrumScript();
    std::string error;
    const auto  reference = DrawScript(kBarsIgnoringInput, { .optimisation = false }, script.steps, &error);
    ASSERT_EQ(reference.size(), script.steps.size()) << error;
    const auto frames = DrawScript(kBarsIgnoringInput, { .audio_reuse = false }, script.steps, &error);
    ASSERT_EQ(frames.size(), script.steps.size()) << error;
    for (std::size_t i = 0; i < frames.size(); ++i) EXPECT_EQ(frames[i].skipped, 0u) << "frame " << i;
    ExpectSamePictures(frames, reference);
}

TEST_F(StaticReuseInputs, AnAudioPassThatSamplesAChangingBufferIsNeverReused)
{
    // The negative half: each of these reads the card's buffer, which the pulse rewrites every
    // frame, so none may be reused in silence. Whether a slot is read is the compiled program's
    // answer: the variant whose combo compiles the read out is the control, and is reused.
    struct Case
    {
        const char* name;
        const char* fragment;
        bool        reads_input;
    };
    const Case cases[] = {
        { "sampled directly", kBarsOverInput, true },
        { "sampled in the variant its combo selects", kBarsOverInputWhenCombo(1), true },
        { "sampled through an array element", kBarsThroughAnArray, true },
        { "read compiled out by its combo", kBarsOverInputWhenCombo(0), false },
    };
    const std::vector<SpectrumStep> silence(5, kSilence);
    for (const auto& c : cases) {
        SCOPED_TRACE(c.name);
        std::string error;
        const auto  reference = DrawScript(c.fragment, { .optimisation = false }, silence, &error);
        ASSERT_EQ(reference.size(), silence.size()) << error;
        const auto frames = DrawScript(c.fragment, {}, silence, &error);
        ASSERT_EQ(frames.size(), silence.size()) << error;
        for (std::size_t i = 1; i < frames.size(); ++i)
            EXPECT_EQ(frames[i].skipped, c.reads_input ? 0u : 1u) << "frame " << i;
        ExpectSamePictures(frames, reference);
    }
}
