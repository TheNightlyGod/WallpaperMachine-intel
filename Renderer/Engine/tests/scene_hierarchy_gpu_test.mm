#include "support/gpu_scene.hpp"
#include "Runtime/SceneRuntimeContext.hpp"

#include <gtest/gtest.h>

namespace {
using namespace we_test;

void MakeHierarchyPicture(ScenePackage& package, bool transformed) {
    SceneGeneral general;general.canvas_width=128;general.canvas_height=128;
    auto parent=GroupJson(1,"parent",{32,0,0});
    if (transformed) {
        parent["origin"]="20 15 0";parent["scale"]="1.4 1.4 1";parent["angles"]="0 0 0.2";
    }
    const auto texture=package.AddTexture("red",Image::Solid(1,1,{255,0,0,255}));
    ImageLayer child;child.id=2;child.name="child";child.origin={32,64,0};child.size={16,16};
    child.model=package.AddImageModel("red",texture,{.blending="normal"});
    package.SetProject();package.SetScene(SceneJson(general,{parent,ImageLayerJson(child)}));
}

TEST(SceneHierarchyGpu, ReparentMovesThePictureAndKeepWorldDetachKeepsItsPixels) {
    WE_SKIP_WITHOUT_METAL();
    ScenePackage package;MakeHierarchyPicture(package,false);
    GpuScene scene(package,{.width=128,.height=128});
    ASSERT_TRUE(scene.ok()) << scene.error();
    const auto before=scene.Run(1);
    EXPECT_TRUE(ExpectRegionAverage(before,28,60,8,8,{255,0,0,255},0));
    ASSERT_TRUE(scene.runtime()->SetNodeParent("child","parent"));
    const auto moved=scene.Run(1);
    EXPECT_TRUE(ExpectRegionAverage(moved,28,60,8,8,{0,0,0,255},0));
    EXPECT_TRUE(ExpectRegionAverage(moved,60,60,8,8,{255,0,0,255},0));
    EXPECT_EQ(scene.RebuildCount(),1);
    ASSERT_TRUE(scene.runtime()->SetNodeParent("child","",-1,true));
    EXPECT_TRUE(ExpectSamePicture(moved,scene.Run(1)));
    EXPECT_EQ(scene.RebuildCount(),2);
    ASSERT_TRUE(scene.runtime()->SetNodeParent("child","",-1,true));
    EXPECT_TRUE(ExpectSamePicture(moved,scene.Run(1)));
    EXPECT_EQ(scene.RebuildCount(),2);
}

TEST(SceneHierarchyGpu, KeepWorldUnderARotatedScaledParentPreservesTheRenderedPicture) {
    WE_SKIP_WITHOUT_METAL();
    ScenePackage package;MakeHierarchyPicture(package,true);
    GpuScene scene(package,{.width=128,.height=128});
    ASSERT_TRUE(scene.ok()) << scene.error();
    const auto before=scene.Run(1);
    ASSERT_TRUE(scene.runtime()->SetNodeParent("child","parent",-1,true));
    EXPECT_TRUE(ExpectSamePicture(before,scene.Run(1)));
    EXPECT_EQ(scene.RebuildCount(),1);
}

TEST(SceneHierarchyGpu, ADrawWithoutUniformsPublishesItsTextureProjectionOffset) {
    WE_SKIP_WITHOUT_METAL();
    ScenePackage package;
    package.AddShader("projection_without_uniforms",
        "attribute vec3 a_Position;\nvoid main(){gl_Position=vec4(a_Position.xy,0.0,1.0);}\n",
        "void main(){gl_FragColor=vec4(0.0,1.0,0.0,1.0);}\n");
    auto root=GroupJson(1,"root",{640,540,0});
    root["parallaxDepth"]="0.25 0.5";
    ImageLayer child;child.id=2;child.name="child";child.parent=1;
    child.origin={16,22,0};child.size={64,64};
    child.model=package.AddImageModel("projection","util/white",
        {.blending="normal",.shader="projection_without_uniforms"});
    child.extra=Json::object({{"parallaxDepth","1 1"}});
    ImageLayer receiver;receiver.id=3;receiver.name="receiver";
    receiver.origin={960,540,0};receiver.size={640,360};
    receiver.model=package.AddImageModel("receiver",
        package.AddTexture("transparent",Image::Solid(1,1,{0,0,0,0})));
    SceneGeneral general;general.canvas_width=1920;general.canvas_height=1080;
    general.parallax=true;general.parallax_amount=.7f;general.parallax_mouse_influence=1;
    package.SetProject();package.SetScene(SceneJson(general,
        {root,ImageLayerJson(child),ImageLayerJson(receiver)}));
    GpuScene scene(package,{.width=192,.height=108});
    ASSERT_TRUE(scene.ok()) << scene.error();
    ASSERT_TRUE(scene.runtime()->HasNodeNamed("child"));
    ASSERT_TRUE(scene.runtime()->HasNodeNamed("receiver"));
    ASSERT_GT(scene.runtime()->NodeSize("receiver").x(),0);
    scene.SetPointer(.5,.5);
    const auto expect_u=[&](double expected) {
        const auto projected=scene.runtime()->AttachmentToTexture("receiver","child",-1);
        ASSERT_TRUE(projected.has_value());
        EXPECT_NEAR((*projected)(0,2),expected,1e-6);
    };
    expect_u(.02421875);
    const auto picture=scene.Run(1);
    ASSERT_FALSE(picture.empty()) << scene.error();
    EXPECT_TRUE(ExpectRegionAverage(picture,94,52,4,4,{0,255,0,255},1));
    expect_u(-.06328125);
    ASSERT_TRUE(scene.runtime()->SetNodeTranslate("root",{800,540,0}));
    expect_u(.18671875); // querying a moved layer retains its last drawn offset
    ASSERT_TRUE(scene.Step());
    expect_u(.23046875);
    ASSERT_TRUE(scene.runtime()->SetNodeParallaxDepth("root",{0,0}));
    expect_u(.23046875);
    ASSERT_TRUE(scene.Step());
    expect_u(.27421875); // a zero-depth draw must publish zero, not retain the old offset
}
} // namespace
