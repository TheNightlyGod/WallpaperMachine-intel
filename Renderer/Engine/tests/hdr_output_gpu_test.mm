#include "support/gpu_scene.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Scene/Scene.h"
#include "Scene/SpecTexs.hpp"
#include "Scene/SceneCamera.h"
#include "Presentation/WallpaperScaling.hpp"
#include "MetalRender/MetalDisplayFraming.hpp"
#include "MetalRender/MetalRender.hpp"
#include "MetalRender/MetalUpscaling.hpp"
#include "../src/Scene/MetalRender/MetalDisplayOutput.hpp"

#include <gtest/gtest.h>
#include <array>
#include <cmath>
#include <iostream>
#include <map>
#include <memory>
#include <optional>
#include <thread>
#include <tuple>
#import <Metal/Metal.h>
#import <AppKit/AppKit.h>

namespace {
using namespace we_test;
using namespace wallpaper;

constexpr const char* kFullFrame =
    "attribute vec3 a_Position;\nattribute vec2 a_TexCoord;\nvarying vec2 v_TexCoord;\n"
    "void main(){gl_Position=vec4(a_Position,1.0);v_TexCoord=a_TexCoord;}\n";
constexpr const char* kLinearize =
    "vec3 lin(vec3 c){return mix(c/12.92,pow((c+0.055)/1.055,vec3(2.4, 2.4, 2.4)),step(vec3(0.04045, 0.04045, 0.04045),c));}\n";

void Utility(ScenePackage& p, const char* name, const std::string& fragment,
             bool two_textures = false, bool blend = false) {
    p.AddShader(name, kFullFrame, fragment);
    p.PutJson(std::string("materials/util/") + name + ".json", {{"passes",Json::array({{
        {"shader",name},{"blending",blend ? "translucent" : "normal"},
        {"depthtest","disabled"},{"depthwrite","disabled"},{"cullmode","nocull"},
        {"textures",two_textures ? Json::array({nullptr,nullptr}) : Json::array({nullptr})}}})}});
}

void HdrAssets(ScenePackage& p) {
    p.InstallStandardAssets();
    const std::string read = "uniform sampler2D g_Texture0;\nvarying vec2 v_TexCoord;\n";
    const std::string second = "uniform sampler2D g_Texture1;\n";
    Utility(p,"hdr_downsample_bloom",read+"void main(){gl_FragColor=vec4(0.0,0.0,0.0,1.0);}\n");
    for (const char* name : {"hdr_downsample","hdr_upsample","hdr_upsample_cubic"})
        Utility(p,name,read+"void main(){gl_FragColor=texSample2D(g_Texture0,v_TexCoord);}\n");
    Utility(p,"combine_hdr_upsample_linear",read+second+
        "void main(){gl_FragColor=vec4(clamp(texSample2D(g_Texture0,v_TexCoord).rgb+"
        "texSample2D(g_Texture1,v_TexCoord).rgb,vec3(0.0, 0.0, 0.0),vec3(1.0, 1.0, 1.0)),1.0);}\n",true);
    Utility(p,"combine_hdr_upsample",read+second+"uniform vec4 g_RenderVar0;\n"+kLinearize+
        "void main(){vec3 c=texSample2D(g_Texture0,v_TexCoord).rgb+texSample2D(g_Texture1,v_TexCoord).rgb;"
        "gl_FragColor=vec4(clamp(lin(max(c,vec3(0.0, 0.0, 0.0))),vec3(0.0, 0.0, 0.0),vec3(1.0, 1.0, 1.0))*g_RenderVar0.x,1.0);}\n",true);
    Utility(p,"combine_dhdr_upsample",read+second+"uniform vec4 g_RenderVar0;\n"+kLinearize+
        "void main(){vec3 c=clamp(texSample2D(g_Texture0,v_TexCoord).rgb,vec3(0.0, 0.0, 0.0),vec3(1.0, 1.0, 1.0))+"
        "texSample2D(g_Texture1,v_TexCoord).rgb;float f=g_RenderVar0.x+g_RenderVar0.y*"
        "smoothstep(1.0,5.0,dot(c,vec3(0.299,0.587,0.114)));gl_FragColor=vec4(lin(max(c,vec3(0.0, 0.0, 0.0)))*f,1.0);}\n",true);
    Utility(p,"combine_srgb",read+kLinearize+
        "void main(){vec4 c=texSample2D(g_Texture0,v_TexCoord);gl_FragColor=vec4(lin(max(c.rgb,vec3(0.0, 0.0, 0.0))),c.a);}\n");
    for (const char* name : {"downsample_quarter_bloom","downsample_eighth_blur_v","blur_h_bloom"})
        Utility(p,name,read+"void main(){gl_FragColor=vec4(0.0,0.0,0.0,1.0);}\n");
    Utility(p,"combine_ldr",read+"void main(){gl_FragColor=texSample2D(g_Texture0,v_TexCoord);}\n");
    Utility(p,"fade","uniform float g_Alpha;\nuniform vec3 color;\n"
        "void main(){gl_FragColor=vec4(color*0.7,g_Alpha);}\n",false,true);
}

void MakeHdrScene(ScenePackage& package, bool hdr, bool fade, bool edge = false) {
    HdrAssets(package);
    we_test::Image image = we_test::Image::Solid(4,4,{128,128,128,255});
    if (edge) {
        image=we_test::Image::Solid(4,4,{0,0,0,255});
        for(uint32_t y=0;y<4;++y)for(uint32_t x=2;x<4;++x)image.Set(x,y,{255,255,255,255});
    }
    ImageLayer tile;
    tile.model=package.AddImageModel("tile",package.AddTexture("input",image),{.blending="normal"});
    tile.origin={2,2,0};tile.size={4,4};
    SceneGeneral general;
    general.canvas_width=general.canvas_height=4;
    general.extra={{"hdr",hdr},{"bloom",true},{"bloomhdriterations",1},
        {"bloomhdrstrength",0},{"bloomstrength",0},{"camerafade",fade}};
    auto document=SceneJson(general,{ImageLayerJson(tile)});
    if(fade) {
        package.PutJson("path.json",{{"paths",Json::array({{{"duration",0.0001},
            {"transforms",Json::array({{{"timestamp",0},{"eye","0 0 0"},{"center","0 0 -1"},
                                      {"up","0 1 0"},{"zoom",1}}})}}})}});
        document["camera"]["paths"]=Json::array({"path.json"});
    }
    package.SetProject({{"schemecolor",ColorProperty("0.5 0.25 0.125")}});
    package.SetScene(document);
}

GpuSceneOptions Options() {
    GpuSceneOptions options;
    options.width=8;options.height=4;options.scene_optimization=false;
    options.quality.post_processing=static_cast<int>(PostProcessing::Ultra);
    return options;
}

TEST(HdrOutputGpu, DisplayClipsTheSceneBeforeBloomSamplesItsEdge) {
    WE_SKIP_WITHOUT_METAL();
    struct RestoreResolution {
        SceneResolution value {CurrentSceneResolution()};
        ~RestoreResolution() { SetSceneResolution(value); }
    } restore;
    SetSceneResolution(SceneResolution::Display);
    ScenePackage package;
    HdrAssets(package);
    auto image = we_test::Image::Solid(64,64,{0,0,0,255});
    for (uint32_t y=11;y<22;++y) for (uint32_t x=0;x<64;++x)
        image.Set(x,y,{64,64,64,255});
    ImageLayer tile;
    tile.model=package.AddImageModel("tile",package.AddTexture("stripe",image),{.blending="normal"});
    tile.origin={32,32,0};tile.size={64,64};
    SceneGeneral general;
    general.canvas_width=general.canvas_height=64;
    general.extra={{"hdr",true},{"bloom",true},{"bloomhdriterations",1}};
    package.SetProject();
    package.SetScene(SceneJson(general,{ImageLayerJson(tile)}));
    Utility(package,"hdr_downsample_bloom",
        "uniform sampler2D g_Texture0;\nuniform vec4 g_RenderVar0;\nvarying vec2 v_TexCoord;\n"
        "void main(){vec2 dy=vec2(0.0,g_RenderVar0.y);gl_FragColor="
        "(texSample2D(g_Texture0,v_TexCoord+dy)+texSample2D(g_Texture0,v_TexCoord-dy))*0.5;}\n");
    auto options=Options();options.width=96;options.height=64;
    GpuScene scene(package,options);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.renderer().SetWallpaperScalingMode(WallpaperScalingMode::FILL);
    ASSERT_TRUE(scene.Rebuild()) << scene.error();
    const auto picture=scene.Run(2);
    ASSERT_FALSE(picture.empty());
    const auto* frame=scene.scene().FindRenderTarget(SpecTex_Default);
    ASSERT_NE(frame,nullptr);
    EXPECT_EQ(frame->width,96);
    EXPECT_EQ(frame->height,64);
    // The top row of the visible stripe is clamped by the display boundary.
    // Filtering the full offscreen canvas first instead blends in black above it.
    EXPECT_TRUE(ExpectRegionAverage(picture,20,0,56,1,{128,128,128,255},1.0));
    SetSceneResolution(SceneResolution::Canvas);
    ASSERT_TRUE(scene.Rebuild());
    frame=scene.scene().FindRenderTarget(SpecTex_Default);
    ASSERT_NE(frame,nullptr);
    EXPECT_EQ(frame->width,64);
    EXPECT_EQ(frame->height,64);
}

void MakeFramingPattern(ScenePackage& package, bool hdr, int sampling_layer = 0) {
    HdrAssets(package);
    const auto image=we_test::Image::Quadrants(64,64,{200,40,20,255},{40,180,70,255},
                                               {10,40,170,255},{160,120,30,255});
    ImageLayer tile;
    tile.model=package.AddImageModel("tile",package.AddTexture("pattern",image),{.blending="normal"});
    tile.origin={32,32,0};tile.size={64,64};
    SceneGeneral general;
    general.canvas_width=general.canvas_height=64;
    general.extra={{"hdr",hdr},{"bloom",true},{"bloomhdriterations",1}};
    package.SetProject({{"schemecolor",ColorProperty("0.2 0.3 0.4")}});
    std::vector<Json> layers {ImageLayerJson(tile)};
    if (sampling_layer != 0) {
        ModelOptions model_options;
        if (sampling_layer == 2) {
            package.AddShader("passthrough",kFullFrame,
                "uniform sampler2D g_Texture0;\nvarying vec2 v_TexCoord;\n"
                "void main(){gl_FragColor=texSample2D(g_Texture0,v_TexCoord); }\n");
            model_options.shader="passthrough";
        }
        if (sampling_layer == 4) {
            // A compose layer's shader: its texture coordinates place the card in its own
            // buffer, and the screen position it samples comes through the projection.
            package.AddShader("composelayer",
                "uniform mat4 g_ModelViewProjectionMatrix;\nattribute vec3 a_Position;\n"
                "attribute vec2 a_TexCoord;\nvarying vec3 v_ScreenCoord;\n"
                "void main(){v_ScreenCoord=mul(vec4(a_Position,1.0),g_ModelViewProjectionMatrix).xyw;\n"
                "vec3 position=vec3(a_TexCoord,0.0);\n"
                "#ifdef HLSL\nposition.y=1.0-position.y;v_ScreenCoord.y=-v_ScreenCoord.y;\n#endif\n"
                "gl_Position=vec4(position.xy*2.0-1.0,0.0,1.0);}\n",
                "uniform sampler2D g_Texture0;\nvarying vec3 v_ScreenCoord;\n"
                "void main(){vec2 uv=v_ScreenCoord.xy/v_ScreenCoord.z*vec2(0.5,0.5)+0.5;\n"
                "gl_FragColor=texSample2D(g_Texture0,uv);}\n");
            model_options.shader="composelayer";
        }
        const auto model=package.AddImageModel("screen","_rt_FullFrameBuffer",model_options);
        if (sampling_layer == 4) {
            package.PutJson(model,{{"material","materials/screen.json"},{"passthrough",true},
                {"autosize",true},{"projectlayer",true}});
        } else {
            package.PutJson(model,{{"material","materials/screen.json"},{"passthrough",true},
                {"fullscreen",sampling_layer != 3},{"projectlayer",sampling_layer == 3}});
        }
        ImageLayer screen;
        screen.id=2;screen.model=model;screen.origin={32,32,0};screen.size={64,64};
        if (sampling_layer == 3) { screen.origin={24,28,0};screen.size={40,32}; }
        screen.effects={EffectUse(package.AddTintEffect("identity"),{{"tint","1 1 1"}},9)};
        layers.push_back(ImageLayerJson(screen));
    }
    package.SetScene(SceneJson(general,layers));
}

TEST(HdrOutputGpu, DisplayLayoutPreservesZoomPanFlipPointerAndBlurModeTransitions) {
    WE_SKIP_WITHOUT_METAL();
    struct RestoreResolution {
        SceneResolution value {CurrentSceneResolution()};
        ~RestoreResolution() { SetSceneResolution(value); }
    } restore;
    SetSceneResolution(SceneResolution::Display);
    ScenePackage hdr_package,sdr_package;
    MakeFramingPattern(hdr_package,true);
    MakeFramingPattern(sdr_package,false);
    auto options=Options();options.width=96;options.height=64;options.scene_optimization=true;
    GpuScene hdr(hdr_package,options),sdr(sdr_package,options);
    ASSERT_TRUE(hdr.ok()) << hdr.error();
    ASSERT_TRUE(sdr.ok()) << sdr.error();
    const auto camera=hdr.scene().cameras.at("global");
    const auto authored=camera->GetViewProjectionMatrix();
    struct Layout { WallpaperScalingMode mode; double zoom,x,y; bool flip; };
    const Layout layouts[] {
        {WallpaperScalingMode::FILL,1.0,0.5,0.5,false},
        {WallpaperScalingMode::FILL,1.3,0.15,0.8,true},
        {WallpaperScalingMode::FIT,1.0,0.2,0.8,true},
        {WallpaperScalingMode::STRETCH,1.0,0.5,0.5,false},
        {WallpaperScalingMode::NONE,1.0,0.2,0.8,true},
        {WallpaperScalingMode::FIT_BLURRED,1.3,0.2,0.7,true},
        {WallpaperScalingMode::FILL,1.0,0.5,0.5,false},
    };
    const Rgba palette[] {{200,40,20,255},{40,180,70,255},{10,40,170,255},
                           {160,120,30,255},{51,77,102,255}};
    uint64_t first_bytes=0;
    for (std::size_t index=0;index<std::size(layouts);++index) {
        SCOPED_TRACE(index);
        const auto& value=layouts[index];
        for (GpuScene* scene : {&hdr,&sdr}) {
            if (scene->renderer().SetWallpaperScalingMode(value.mode)) ASSERT_TRUE(scene->Rebuild());
            scene->renderer().SetWallpaperScalingFactor(value.zoom);
            scene->renderer().SetWallpaperFraming({value.x,value.y});
            scene->renderer().SetWallpaperHorizontalFlip(value.flip);
        }
        const auto reference=sdr.Run(2),picture=hdr.Run(2);
        ASSERT_FALSE(reference.empty());ASSERT_FALSE(picture.empty());
        int checked=0;
        for (uint32_t y : {5u,21u,43u,59u}) for (uint32_t x : {5u,25u,55u,85u}) {
            const auto expected=reference.At(x,y);
            bool flat=false;
            for (const auto& colour:palette) {
                int difference=0;
                for (std::size_t channel=0;channel<3;++channel)
                    difference=std::max(difference,std::abs(int(expected[channel])-int(colour[channel])));
                flat=flat || difference<=1;
            }
            if (!flat) continue; // Border interpolation/blur has a different HDR transfer domain.
            EXPECT_TRUE(ExpectPixel(picture,x,y,expected,1));
            ++checked;
        }
        EXPECT_GE(checked,8);
        EXPECT_TRUE(camera->GetViewProjectionMatrix().isApprox(authored));
        const auto* target=hdr.scene().FindRenderTarget(SpecTex_Default);
        ASSERT_NE(target,nullptr);
        EXPECT_EQ(target->width,96);
        EXPECT_EQ(target->height,value.mode==WallpaperScalingMode::FIT_BLURRED?96:64);
        if (hdr.scene().display_framed) {
            const auto layout=ComputeWallpaperScalingLayout(value.mode,64,64,96,64,1.0,
                                                              value.zoom,value.x,value.y);
            const auto mapping=hdr.renderer().CursorMapping(hdr.scene());
            ASSERT_TRUE(mapping.valid);
            constexpr double x=0.35,y=0.55;
            const double u=(x*96-layout.viewport_px.x)/layout.viewport_px.width;
            const double v=(y*64-layout.viewport_px.y)/layout.viewport_px.height;
            const double mirrored=value.flip?1.0-x:x;
            EXPECT_NEAR(mapping.origin_x+mirrored*mapping.size_x,64*(value.flip?1-u:u),1e-5);
            EXPECT_NEAR(mapping.origin_y+(1-y)*mapping.size_y,64*(1-v),1e-5);
        }
        const auto resident=hdr.renderer().RenderTargetBytesForTests();
        if (index==0) first_bytes=resident;
        if (index==std::size(layouts)-1) EXPECT_EQ(resident,first_bytes);
    }
}

TEST(HdrOutputGpu, DisplayFramingPreservesFullscreenAndLocalScreenCopies) {
    WE_SKIP_WITHOUT_METAL();
    struct RestoreResolution {
        SceneResolution value {CurrentSceneResolution()};
        ~RestoreResolution() { SetSceneResolution(value); }
    } restore;
    SetSceneResolution(SceneResolution::Display);
    auto options=Options();options.width=96;options.height=64;
    ScenePackage reference_package;
    MakeFramingPattern(reference_package,true);
    GpuScene reference(reference_package,options);
    ASSERT_TRUE(reference.ok()) << reference.error();
    // 4: a compose layer over the whole canvas, which samples the screen through the framed
    // projection; its card is not moved again by the framing.
    for (int kind : {1,2,3,4}) {
        SCOPED_TRACE(kind);
        ScenePackage package;
        MakeFramingPattern(package,true,kind);
        GpuScene copied(package,options);
        ASSERT_TRUE(copied.ok()) << copied.error();
        for (const auto mode : {WallpaperScalingMode::FILL,WallpaperScalingMode::FIT,
                                WallpaperScalingMode::FIT_BLURRED,WallpaperScalingMode::FILL}) {
            SCOPED_TRACE(static_cast<int>(mode));
            for (GpuScene* scene : {&reference,&copied}) {
                if (scene->renderer().SetWallpaperScalingMode(mode)) ASSERT_TRUE(scene->Rebuild());
                scene->renderer().SetWallpaperScalingFactor(1.2);
                scene->renderer().SetWallpaperFraming({0.2,0.8});
                scene->renderer().SetWallpaperHorizontalFlip(true);
            }
            const auto expected=reference.Run(2),picture=copied.Run(2);
            ASSERT_FALSE(expected.empty());ASSERT_FALSE(picture.empty());
            for (uint32_t y : {5u,21u,43u,59u}) for (uint32_t x : {5u,25u,65u,85u})
                EXPECT_TRUE(ExpectPixel(picture,x,y,expected.At(x,y),2));
            const auto layouts=copied.scene().runtime->PassthroughCardLayoutCount();
            ASSERT_FALSE(copied.Run(2).empty());
            EXPECT_EQ(copied.scene().runtime->PassthroughCardLayoutCount(),layouts);
        }
    }
}

// ---- SDR display framing (experimental, off by default): an SDR Display-resolution scene
// draws only the window of its canvas-cover raster that the composition reads.
// `GpuScene::Picture` composes through the poster path, the composition the drawable shares.

/// Frames or never frames for the scope, whatever the setting and the environment say, and
/// back.
struct SdrWindowSwitch {
    int previous;
    explicit SdrWindowSwitch(bool on)
        : previous(metal::MetalRender::SetSdrFramingOverrideForTests(on ? 1 : 0)) {}
    ~SdrWindowSwitch() { metal::MetalRender::SetSdrFramingOverrideForTests(previous); }
};

/// The setting decides for the scope (no override), starting from `on`, and back.
struct SdrFramingSetting {
    int  previous_override {metal::MetalRender::SetSdrFramingOverrideForTests(-1)};
    bool previous {metal::MetalSceneDisplayFramingEnabled()};
    explicit SdrFramingSetting(bool on) { metal::SetMetalSceneDisplayFramingEnabled(on); }
    ~SdrFramingSetting() {
        metal::SetMetalSceneDisplayFramingEnabled(previous);
        metal::MetalRender::SetSdrFramingOverrideForTests(previous_override);
    }
};

/// Sets the process-wide MetalFX upscaling setting for the scope, and back.
struct UpscalingSwitch {
    bool previous {metal::MetalUpscalingEnabled()};
    explicit UpscalingSwitch(bool on) { metal::SetMetalUpscalingEnabled(on); }
    ~UpscalingSwitch() { metal::SetMetalUpscalingEnabled(previous); }
};

/// A `width` x `height` canvas of four flat quadrants with a small bright tile in each, so
/// a misplaced or resampled window shows; bloom optional.
void MakeWideCanvas(ScenePackage& package, uint32_t width, uint32_t height, bool bloom) {
    HdrAssets(package);
    auto image=we_test::Image::Quadrants(width,height,{200,40,20,255},{40,180,70,255},
                                         {10,40,170,255},{160,120,30,255});
    for (uint32_t y=0;y<height;y+=7) for (uint32_t x=(y*3)%11;x<width;x+=11) image.Set(x,y,{250,250,250,255});
    ImageLayer tile;
    tile.model=package.AddImageModel("tile",package.AddTexture("pattern",image),{.blending="normal"});
    tile.origin={width*0.5f,height*0.5f,0};tile.size={float(width),float(height)};
    SceneGeneral general;
    general.canvas_width=width;general.canvas_height=height;
    general.extra={{"hdr",false},{"bloom",bloom},{"bloomstrength",bloom?2.0:0.0}};
    package.SetProject({{"schemecolor",ColorProperty("0.2 0.3 0.4")}});
    package.SetScene(SceneJson(general,{ImageLayerJson(tile)}));
}

struct Framing {
    WallpaperScalingMode mode {WallpaperScalingMode::FILL};
    double zoom {1.0}, x {0.5}, y {0.5};
    bool flip {false};
};

void Apply(GpuScene& scene, const Framing& framing) {
    if (scene.renderer().SetWallpaperScalingMode(framing.mode)) ASSERT_TRUE(scene.Rebuild());
    scene.renderer().SetWallpaperScalingFactor(framing.zoom);
    scene.renderer().SetWallpaperFraming({framing.x,framing.y});
    scene.renderer().SetWallpaperHorizontalFlip(framing.flip);
}

/// The same scene twice: drawn whole (switch off) and framed (switch on), each always under
/// its own setting.
struct WindowPair {
    std::unique_ptr<GpuScene> whole_scene, framed_scene;
    WindowPair(const ScenePackage& package, const GpuSceneOptions& options) {
        {
            SdrWindowSwitch off(false);
            whole_scene=std::make_unique<GpuScene>(package,options);
        }
        SdrWindowSwitch on(true);
        framed_scene=std::make_unique<GpuScene>(package,options);
    }
    GpuScene& whole() { return *whole_scene; }
    GpuScene& framed() { return *framed_scene; }
    std::pair<we_test::Image,we_test::Image> Run(const Framing& framing, int frames = 2) {
        we_test::Image a, b;
        {
            SdrWindowSwitch off(false);
            Apply(whole(),framing);
            a=whole().Run(frames);
        }
        {
            SdrWindowSwitch on(true);
            Apply(framed(),framing);
            b=framed().Run(frames);
        }
        return {a,b};
    }
};

/// Pixels farther than `margin` from the left and right edges that differ by more than one.
std::size_t InteriorDifferences(const we_test::Image& a, const we_test::Image& b, uint32_t margin) {
    if (a.width!=b.width || a.height!=b.height) return std::size_t(-1);
    std::size_t count=0;
    for (uint32_t y=0;y<a.height;++y) for (uint32_t x=margin;x+margin<a.width;++x) {
        const auto p=a.At(x,y), q=b.At(x,y);
        for (std::size_t c=0;c<3;++c) if (std::abs(int(p[c])-int(q[c]))>1) { ++count; break; }
    }
    return count;
}

struct DisplayResolutionScope {
    SceneResolution value {CurrentSceneResolution()};
    DisplayResolutionScope() { SetSceneResolution(SceneResolution::Display); }
    ~DisplayResolutionScope() { SetSceneResolution(value); }
};

TEST(SdrDisplayFraming, FillDrawsOnlyTheVisibleWindowAndComposesTheSamePicture) {
    WE_SKIP_WITHOUT_METAL();
    DisplayResolutionScope display;
    for (const bool bloom : {false,true}) {
        SCOPED_TRACE(bloom);
        ScenePackage package;
        MakeWideCanvas(package,96,48,bloom);
        auto options=Options();options.width=64;options.height=48;
        WindowPair pair(package,options);
        ASSERT_TRUE(pair.whole().ok()) << pair.whole().error();
        ASSERT_TRUE(pair.framed().ok()) << pair.framed().error();
        const auto [whole,framed]=pair.Run({});
        ASSERT_FALSE(whole.empty());ASSERT_FALSE(framed.empty());
        // The canvas fills the output 96 wide and the composition shows its middle 64.
        const auto state=pair.framed().renderer().RasterWindowStateForTests();
        EXPECT_TRUE(state.framed);
        EXPECT_EQ(state.cover_width,96u);
        EXPECT_EQ(state.x,16u);
        EXPECT_EQ(state.width,64u);
        EXPECT_EQ(state.height,48u);
        EXPECT_FALSE(pair.whole().renderer().RasterWindowStateForTests().framed);
        EXPECT_LT(pair.framed().renderer().RenderTargetBytesForTests(),
                  pair.whole().renderer().RenderTargetBytesForTests());
        // Only bloom's reach across the window's edge may differ.
        EXPECT_EQ(InteriorDifferences(whole,framed,bloom?12u:0u),0u);
        if (!bloom) EXPECT_TRUE(ExpectSamePicture(framed,whole,1));
    }
}

TEST(SdrDisplayFraming, AnOddCropOffsetComposesTheSamePicture) {
    WE_SKIP_WITHOUT_METAL();
    DisplayResolutionScope display;
    ScenePackage package;
    MakeWideCanvas(package,101,48,false);
    auto options=Options();options.width=64;options.height=48;
    WindowPair pair(package,options);
    ASSERT_TRUE(pair.whole().ok() && pair.framed().ok());
    const auto [whole,framed]=pair.Run({});
    const auto state=pair.framed().renderer().RasterWindowStateForTests();
    EXPECT_TRUE(state.framed);
    // 37 pixels overhang: 19 on the left (rounded away from zero), 18 on the right.
    EXPECT_EQ(state.x,19u);
    EXPECT_EQ(state.width,64u);
    EXPECT_TRUE(ExpectSamePicture(framed,whole,1));
}

TEST(SdrDisplayFraming, StretchFitAndBlurredFitDrawTheWholeRaster) {
    WE_SKIP_WITHOUT_METAL();
    DisplayResolutionScope display;
    ScenePackage package;
    MakeWideCanvas(package,96,48,false);
    auto options=Options();options.width=64;options.height=48;
    WindowPair pair(package,options);
    ASSERT_TRUE(pair.whole().ok() && pair.framed().ok());
    for (const auto mode : {WallpaperScalingMode::STRETCH,WallpaperScalingMode::FIT,
                            WallpaperScalingMode::FIT_BLURRED,WallpaperScalingMode::NONE,
                            WallpaperScalingMode::FILL}) {
        SCOPED_TRACE(static_cast<int>(mode));
        const auto [whole,framed]=pair.Run({.mode=mode});
        const auto state=pair.framed().renderer().RasterWindowStateForTests();
        // A mode that shows the whole canvas sizes the targets again before its first draw;
        // original size, one point per canvas unit, crops this canvas as Fill does.
        EXPECT_EQ(state.framed,mode==WallpaperScalingMode::FILL || mode==WallpaperScalingMode::NONE);
        EXPECT_FALSE(state.stale);
        EXPECT_TRUE(ExpectSamePicture(framed,whole,1));
    }
}

TEST(SdrDisplayFraming, ZoomPanAndFlipMoveTheWindowAndSizeItAtMostOnce) {
    WE_SKIP_WITHOUT_METAL();
    DisplayResolutionScope display;
    ScenePackage package;
    MakeWideCanvas(package,128,48,false);
    auto options=Options();options.width=64;options.height=48;
    WindowPair pair(package,options);
    ASSERT_TRUE(pair.whole().ok() && pair.framed().ok());
    (void)pair.Run({});
    const auto first=pair.framed().renderer().RasterWindowStateForTests();
    ASSERT_TRUE(first.framed);
    // A larger zoom shows part of what a zoom of 1 does: the window moves, never grows.
    for (const double zoom : {1.3,2.0,1.0}) {
        SCOPED_TRACE(zoom);
        const auto [whole,framed]=pair.Run({.zoom=zoom});
        EXPECT_EQ(pair.framed().renderer().RasterWindowStateForTests().width,first.width);
        EXPECT_TRUE(ExpectSamePicture(framed,whole,1));
    }
    // A move off the centre sizes the window once, with room for any further move.
    std::optional<uint32_t> moved_width;
    for (const auto& framing : {Framing{.x=0.1},Framing{.x=0.9,.flip=true},Framing{.x=0.0},
                                Framing{.zoom=1.4,.x=0.7,.y=0.2,.flip=true},Framing{.x=1.0}}) {
        const auto [whole,framed]=pair.Run(framing);
        const auto state=pair.framed().renderer().RasterWindowStateForTests();
        EXPECT_TRUE(state.framed);
        if (!moved_width) moved_width=state.width;
        EXPECT_EQ(state.width,*moved_width);
        EXPECT_TRUE(ExpectSamePicture(framed,whole,1));
    }
    EXPECT_LE(*moved_width,first.width+2);
    // A zoom below 1 shows more of the canvas with every step: the whole raster is drawn.
    const auto [whole,framed]=pair.Run({.zoom=0.8});
    EXPECT_FALSE(pair.framed().renderer().RasterWindowStateForTests().framed);
    EXPECT_TRUE(ExpectSamePicture(framed,whole,1));
}

TEST(SdrDisplayFraming, IsOffByDefaultAndARunningSceneTakesTheSettingAtItsNextFrame) {
    WE_SKIP_WITHOUT_METAL();
    DisplayResolutionScope display;
    // Off unless the user turns it on: the whole cover raster is drawn, as before.
    EXPECT_FALSE(metal::MetalSceneDisplayFramingEnabled());
    ScenePackage package;
    MakeWideCanvas(package,96,48,false);
    auto options=Options();options.width=64;options.height=48;
    SdrFramingSetting setting(false);
    GpuScene scene(package,options);
    ASSERT_TRUE(scene.ok()) << scene.error();
    const auto before=scene.Run(2);
    ASSERT_FALSE(before.empty());
    EXPECT_FALSE(scene.renderer().RasterWindowStateForTests().framed);
    const auto whole_bytes=scene.renderer().RenderTargetBytesForTests();
    // Turned on while it runs: the next frame sizes the targets for the window, in place.
    metal::SetMetalSceneDisplayFramingEnabled(true);
    const auto framed=scene.Run(2);
    const auto state=scene.renderer().RasterWindowStateForTests();
    EXPECT_TRUE(state.framed);
    EXPECT_FALSE(state.stale);
    EXPECT_EQ(state.width,64u);
    EXPECT_LT(scene.renderer().RenderTargetBytesForTests(),whole_bytes);
    EXPECT_TRUE(ExpectSamePicture(framed,before,1));
    // And off again: the whole raster, and the very picture it drew before.
    metal::SetMetalSceneDisplayFramingEnabled(false);
    const auto after=scene.Run(2);
    EXPECT_FALSE(scene.renderer().RasterWindowStateForTests().framed);
    EXPECT_EQ(scene.renderer().RenderTargetBytesForTests(),whole_bytes);
    EXPECT_TRUE(ExpectSamePicture(after,before));
}

TEST(SdrDisplayFraming, MetalFxUpscalingKeepsTheWholeRaster) {
    WE_SKIP_WITHOUT_METAL();
    DisplayResolutionScope display;
    ScenePackage package;
    MakeWideCanvas(package,96,48,false);
    auto options=Options();options.width=64;options.height=48;options.render_scale=0.75;
    UpscalingSwitch upscaling(true);
    WindowPair pair(package,options);
    ASSERT_TRUE(pair.whole().ok() && pair.framed().ok());
    // MetalFX would upscale the window on another grid than the whole raster's.
    auto [whole,framed]=pair.Run({});
    EXPECT_FALSE(pair.framed().renderer().RasterWindowStateForTests().framed);
    EXPECT_TRUE(ExpectSamePicture(framed,whole));
    // Without it the scene is framed at its next frame, and unframed again once it is back.
    metal::SetMetalUpscalingEnabled(false);
    std::tie(whole,framed)=pair.Run({});
    EXPECT_TRUE(pair.framed().renderer().RasterWindowStateForTests().framed);
    // Below render scale 1 the canvas's one-texel dots, point sampled, sit on sampling ties
    // the shifted projection can break the other way: close to the whole raster's picture,
    // not the same (the trade-off the setting states).
    EXPECT_LE(InteriorDifferences(whole,framed,0),std::size_t(whole.width*whole.height/50));
    metal::SetMetalUpscalingEnabled(true);
    std::tie(whole,framed)=pair.Run({});
    EXPECT_FALSE(pair.framed().renderer().RasterWindowStateForTests().framed);
    EXPECT_TRUE(ExpectSamePicture(framed,whole));
}

TEST(HdrOutputGpu, HdrFadeIsEncodedOnceAndSdrFadeKeepsItsExistingValues) {
    WE_SKIP_WITHOUT_METAL();
    for (bool hdr : {false,true}) {
        ScenePackage package;MakeHdrScene(package,hdr,true);
        GpuScene scene(package,Options());
        ASSERT_TRUE(scene.ok()) << scene.error();
        const auto picture=scene.Run(2);
        ASSERT_FALSE(picture.empty());
        EXPECT_TRUE(ExpectRegionAverage(picture,2,1,4,2,hdr?Rgba{160,116,83,255}:Rgba{89,45,22,255},1.0));
    }
}

TEST(HdrOutputGpu, BloomToggleKeepsGrayAndConvertsBeforePresentationFiltering) {
    WE_SKIP_WITHOUT_METAL();
    for(bool optimize:{false,true}) for(bool edge:{false,true}) {
        ScenePackage package;MakeHdrScene(package,true,false,edge);
        auto options=Options();options.scene_optimization=optimize;
        GpuScene scene(package,options);
        ASSERT_TRUE(scene.ok()) << scene.error();
        scene.renderer().SetWallpaperScalingMode(WallpaperScalingMode::FILL);
        const auto enabled=scene.Run(1);
        ASSERT_FALSE(enabled.empty());
        const std::array<float,1> disabled{0};
        ASSERT_TRUE(scene.runtime()->SetSceneGeneralValue("bloom",disabled));
        const auto without_bloom=scene.Run(1);
        ASSERT_FALSE(without_bloom.empty());
        if(edge) {
            // Interpolating linear black/white at one quarter gives sRGB137.
            // Decoding after the existing gamma-space bilinear sample gives64.
            EXPECT_TRUE(ExpectRegionAverage(without_bloom,3,1,1,2,{137,137,137,255},2.0));
        } else {
            EXPECT_TRUE(ExpectRegionAverage(enabled,2,1,4,2,{128,128,128,255},1.0));
            EXPECT_TRUE(ExpectRegionAverage(without_bloom,2,1,4,2,{128,128,128,255},1.0));
        }
        const auto counts=scene.LastFramePasses();
        EXPECT_EQ(counts.render_passes,2u);
        // The sRGB conversion's result goes back into the scene's image: a copy, or with scene
        // optimisation a trade of textures that copies nothing.
        EXPECT_EQ(counts.blit_passes,optimize?0u:1u);
        const auto resident=scene.renderer().RenderTargetBytesForTests();
        ASSERT_TRUE(scene.Step(2));
        const auto steady=scene.LastFramePasses();
        EXPECT_EQ(scene.renderer().RenderTargetBytesForTests(),resident);
        std::cout << "HDR_NO_BLOOM_STEADY optimized=" << optimize << " edge=" << edge
                  << " passes=" << steady.render_passes << " blits=" << steady.blit_passes << '\n';
        for (int toggle=0;toggle<3;++toggle) {
            const std::array<float,1> enabled_bloom{1};
            ASSERT_TRUE(scene.runtime()->SetSceneGeneralValue("bloom",enabled_bloom));
            ASSERT_TRUE(scene.Step());
            ASSERT_TRUE(scene.runtime()->SetSceneGeneralValue("bloom",disabled));
            ASSERT_TRUE(scene.Step());
            EXPECT_EQ(scene.renderer().RenderTargetBytesForTests(),resident);
        }
        std::cout << "HDR_NO_BLOOM_COST optimized=" << optimize << " edge=" << edge << " passes=" << counts.render_passes
                  << " blits=" << counts.blit_passes << " bytes=" << scene.renderer().RenderTargetBytesForTests() << '\n';
    }
}

TEST(HdrOutputGpu, ExtendedSurfaceKeepsLinearRadianceAndDeliversAnSdrPoster) {
    WE_SKIP_WITHOUT_METAL();
    ScenePackage package;MakeHdrScene(package,true,false);
    Utility(package,"hdr_downsample_bloom","void main(){gl_FragColor=vec4(1.5,1.5,1.5,1.0);}\n");
    int queries=0;
    std::map<uint32_t,metal::MetalDisplayCharacteristics> displays{{100,{1.0f,4.0f}},{200,{2.0f,2.0f}}};
    auto options=Options();
    options.quality.post_processing=static_cast<int>(PostProcessing::DisplayHdr);
    options.display_id=100;
    options.display_characteristics=[&](uint32_t identity) {++queries;return displays.at(identity);};
    GpuScene scene(package,options);
    ASSERT_TRUE(scene.ok()) << scene.error();
    const auto poster=scene.Run(2);
    ASSERT_FALSE(poster.empty());
    EXPECT_TRUE(ExpectRegionAverage(poster,2,1,4,2,{255,255,255,255},1.0));
    EXPECT_TRUE(scene.renderer().SurfaceEDREnabledForTests());
    EXPECT_EQ(scene.renderer().SurfacePixelFormatForTests(),uint32_t(MTLPixelFormatRGBA16Float));
    std::vector<uint8_t> rgba;
    std::vector<float> radiance;
    uint32_t width=0,height=0;
    ASSERT_TRUE(scene.renderer().ReadCompositionForTests(scene.scene(),uint32_t(MTLPixelFormatRGBA16Float),
        rgba,width,height,&radiance));
    const std::size_t sample=(std::size_t(height/2)*width+width/2)*4;
    ASSERT_GT(radiance.size(),sample);
    const float before=radiance[sample];
    EXPECT_GT(before,1.0f);
    const int queried=queries;
    ASSERT_TRUE(scene.Step(3));
    EXPECT_EQ(queries,queried) << "ordinary frames never poll screen headroom";
    displays.at(100).current_headroom=3.0f;
    [[NSNotificationCenter defaultCenter] postNotificationName:NSApplicationDidChangeScreenParametersNotification object:nil];
    ASSERT_TRUE(scene.Step());
    EXPECT_EQ(scene.scene().display_hdr_headroom,3.0f);
    ASSERT_TRUE(scene.renderer().ReadCompositionForTests(scene.scene(),uint32_t(MTLPixelFormatRGBA16Float),
        rgba,width,height,&radiance));
    EXPECT_GT(radiance[sample],before);
    scene.renderer().SetDisplayId(200);
    ASSERT_TRUE(scene.Step());
    EXPECT_EQ(scene.scene().display_hdr_headroom,2.0f);
    displays.at(200)={1.0f,1.0f};
    [[NSNotificationCenter defaultCenter] postNotificationName:NSApplicationDidChangeScreenParametersNotification object:nil];
    ASSERT_TRUE(scene.Step());
    EXPECT_FALSE(scene.renderer().SurfaceEDREnabledForTests());
    EXPECT_EQ(scene.renderer().SurfacePixelFormatForTests(),uint32_t(MTLPixelFormatBGRA8Unorm_sRGB));
    EXPECT_TRUE(scene.scene().display_hdr) << "surface capability does not rewrite processing quality";
}

TEST(HdrOutputGpu, LinearBackdropKeepsHighlightRadianceAndSharesTheSdrPosterContract) {
    WE_SKIP_WITHOUT_METAL();
    for (bool bright : {false,true}) {
        ScenePackage package;MakeHdrScene(package,true,false);
        if (bright) Utility(package,"hdr_downsample_bloom",
            "void main(){gl_FragColor=vec4(1.5,1.5,1.5,1.0); }\n");
        auto options=Options();
        options.quality.post_processing=static_cast<int>(PostProcessing::DisplayHdr);
        options.display_characteristics=[](uint32_t) {
            return metal::MetalDisplayCharacteristics{3.0f,4.0f};
        };
        GpuScene scene(package,options);
        ASSERT_TRUE(scene.ok()) << scene.error();
        scene.renderer().SetWallpaperScalingMode(WallpaperScalingMode::FIT_BLURRED);
        const auto poster=scene.Run(2);
        ASSERT_FALSE(poster.empty());
        const uint8_t expected=bright?255:109;
        EXPECT_TRUE(ExpectRegionAverage(poster,0,0,2,4,{expected,expected,expected,255},2.0));
        std::vector<uint8_t> bytes;
        std::vector<float> radiance;
        uint32_t width=0,height=0;
        ASSERT_TRUE(scene.renderer().ReadCompositionForTests(scene.scene(),
            uint32_t(MTLPixelFormatRGBA16Float),bytes,width,height,&radiance));
        const auto bar=(std::size_t(height/2)*width)*4;
        const auto middle=(std::size_t(height/2)*width+width/2)*4;
        ASSERT_GT(radiance.size(),middle);
        EXPECT_NEAR(radiance[bar],radiance[middle]*0.7f,0.01f);
        if (bright) EXPECT_GT(radiance[bar],1.0f);
        const auto resident=scene.renderer().RenderTargetBytesForTests();
        ASSERT_FALSE(scene.Picture().empty());
        EXPECT_EQ(scene.renderer().RenderTargetBytesForTests(),resident)
            << "switching between float output and SDR poster retains bounded backdrop images";
    }
}

TEST(HdrOutputGpu, SdrOnlySurfaceKeepsTheSavedDisplayHdrProcessingMode) {
    WE_SKIP_WITHOUT_METAL();
    ScenePackage package;MakeHdrScene(package,true,false);
    int queries=0;
    auto options=Options();
    options.quality.post_processing=static_cast<int>(PostProcessing::DisplayHdr);
    options.display_hdr_output_allowed=false;
    options.display_characteristics=[&](uint32_t) {++queries;return metal::MetalDisplayCharacteristics{3.0f,4.0f};};
    GpuScene scene(package,options);
    ASSERT_TRUE(scene.ok()) << scene.error();
    EXPECT_TRUE(scene.scene().display_hdr);
    EXPECT_EQ(queries,0);
    EXPECT_FALSE(scene.renderer().SurfaceEDREnabledForTests());
    EXPECT_EQ(scene.renderer().SurfacePixelFormatForTests(),uint32_t(MTLPixelFormatBGRA8Unorm_sRGB));
    const auto poster=scene.Run(1);
    EXPECT_TRUE(ExpectRegionAverage(poster,2,1,4,2,{128,128,128,255},1.0));
}

TEST(HdrOutputGpu, RetiredSurfaceOwnerCannotOverwriteANewerOwnerAndTheHostContractReturns) {
    WE_SKIP_WITHOUT_METAL();
    @autoreleasepool {
        CAMetalLayer* layer=[CAMetalLayer layer];
        layer.device=MTLCreateSystemDefaultDevice();
        layer.pixelFormat=MTLPixelFormatBGRA8Unorm;
        CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        layer.colorspace=space;
        layer.wantsExtendedDynamicRangeContent=NO;
        int queries=0;
        auto first=std::make_unique<metal::MetalDisplayOutput>(layer,[&](uint32_t) {
            ++queries;return metal::MetalDisplayCharacteristics{3.0f,4.0f};
        },[]{});
        first->Request(true);
        EXPECT_EQ(layer.pixelFormat,MTLPixelFormatRGBA16Float);
        EXPECT_TRUE(layer.wantsExtendedDynamicRangeContent);
        auto second=std::make_unique<metal::MetalDisplayOutput>(layer,
            std::function<metal::MetalDisplayCharacteristics(uint32_t)>{},[]{});
        second->Request(false);
        EXPECT_EQ(layer.pixelFormat,MTLPixelFormatBGRA8Unorm_sRGB);
        first.reset();
        EXPECT_EQ(layer.pixelFormat,MTLPixelFormatBGRA8Unorm_sRGB);
        second.reset();
        EXPECT_EQ(layer.pixelFormat,MTLPixelFormatBGRA8Unorm);
        EXPECT_FALSE(layer.wantsExtendedDynamicRangeContent);
        ASSERT_NE(layer.colorspace,nullptr);
        EXPECT_TRUE(CFEqual(layer.colorspace,space));
        const int stopped_queries=queries;
        [[NSNotificationCenter defaultCenter] postNotificationName:NSApplicationDidChangeScreenParametersNotification object:nil];
        EXPECT_EQ(queries,stopped_queries);
        CGColorSpaceRelease(space);
    }
}

TEST(HdrOutputGpu, OlderQueuedFirstAcquireCannotStealANewerLease) {
    WE_SKIP_WITHOUT_METAL();
    @autoreleasepool {
        CAMetalLayer* layer=[CAMetalLayer layer];
        layer.device=MTLCreateSystemDefaultDevice();
        layer.pixelFormat=MTLPixelFormatBGRA8Unorm;
        layer.wantsExtendedDynamicRangeContent=NO;
        int old_queries=0;
        auto old=std::make_unique<metal::MetalDisplayOutput>(layer,[&](uint32_t) {
            ++old_queries;return metal::MetalDisplayCharacteristics{3.0f,4.0f};
        },[]{});
        std::thread queued([&] {old->Request(true);});
        queued.join();
        auto newer=std::make_unique<metal::MetalDisplayOutput>(layer,
            std::function<metal::MetalDisplayCharacteristics(uint32_t)>{},[]{});
        newer->Request(false);
        EXPECT_EQ(layer.pixelFormat,MTLPixelFormatBGRA8Unorm_sRGB);
        CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.02,false);
        EXPECT_EQ(old_queries,0);
        EXPECT_EQ(layer.pixelFormat,MTLPixelFormatBGRA8Unorm_sRGB);
        newer.reset();
        EXPECT_EQ(layer.pixelFormat,MTLPixelFormatBGRA8Unorm);
        // An inactive newer lease is still a generation fence for this old owner.
        old->SetDisplayId(7);
        EXPECT_EQ(old_queries,0);
        EXPECT_EQ(layer.pixelFormat,MTLPixelFormatBGRA8Unorm);
        old.reset();
    }
}
TEST(HdrOutputGpu, ADecodeAfterBilinearSamplingDoesNotReplaceTheLinearIntermediate) {
    WE_SKIP_WITHOUT_METAL();
    ScenePackage package;MakeHdrScene(package,true,false,true);
    Utility(package,"combine_srgb","uniform sampler2D g_Texture0;\nvarying vec2 v_TexCoord;\n"
        "void main(){gl_FragColor=texSample2D(g_Texture0,v_TexCoord); }\n");
    GpuScene scene(package,Options());
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.renderer().SetWallpaperScalingMode(WallpaperScalingMode::FILL);
    const std::array<float,1> disabled{0};
    ASSERT_TRUE(scene.runtime()->SetSceneGeneralValue("bloom",disabled));
    ASSERT_TRUE(scene.Step());
    // Simulate fusing the decode into the final presentation sampler: the
    // intermediate still contains encoded black/white, so filtering yields .25
    // before decoding. The real conversion test gets137 at this pixel.
    scene.scene().output_linear=false;
    we_test::Image after_filter_decode;
    ASSERT_TRUE(scene.renderer().ReadCompositionForTests(scene.scene(),
        uint32_t(MTLPixelFormatBGRA8Unorm_sRGB),after_filter_decode.rgba,
        after_filter_decode.width,after_filter_decode.height));
    EXPECT_TRUE(ExpectRegionAverage(after_filter_decode,3,1,1,2,{64,64,64,255},2.0));
}

TEST(HdrOutputGpu, UnknownDisplayStaysSdrAndAStoppedLeaseDoesNotRestoreAnObsoleteHostContract) {
    WE_SKIP_WITHOUT_METAL();
    @autoreleasepool {
        CAMetalLayer* layer=[CAMetalLayer layer];
        layer.device=MTLCreateSystemDefaultDevice();
        layer.pixelFormat=MTLPixelFormatBGRA8Unorm;
        auto output=std::make_unique<metal::MetalDisplayOutput>(layer,
            std::function<metal::MetalDisplayCharacteristics(uint32_t)>{},[]{});
        output->Request(true);
        EXPECT_FALSE(output->Extended());
        EXPECT_FLOAT_EQ(output->Headroom(),1.0f);
        EXPECT_FALSE(layer.wantsExtendedDynamicRangeContent);
        EXPECT_EQ(layer.pixelFormat,MTLPixelFormatBGRA8Unorm_sRGB);
        output.reset();
        // A later host is free to select another contract after restoration.
        // The inactive generation fence must not revive the old one.
        layer.pixelFormat=MTLPixelFormatRGBA16Float;
        layer.wantsExtendedDynamicRangeContent=YES;
        CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearDisplayP3);
        layer.colorspace=space;
        output=std::make_unique<metal::MetalDisplayOutput>(layer,
            std::function<metal::MetalDisplayCharacteristics(uint32_t)>{},[]{});
        output->Request(false);
        output.reset();
        EXPECT_EQ(layer.pixelFormat,MTLPixelFormatRGBA16Float);
        EXPECT_TRUE(layer.wantsExtendedDynamicRangeContent);
        EXPECT_TRUE(CFEqual(layer.colorspace,space));
        CGColorSpaceRelease(space);
    }
}

} // namespace
