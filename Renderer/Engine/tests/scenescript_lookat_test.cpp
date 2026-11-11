#include "scenescript_scenes.hpp"
#include "Runtime/SceneRuntimeContext.hpp"

#include <gtest/gtest.h>

namespace {
using namespace we_test;
namespace linalg = wallpaper::linalg;

void MakeLookAtScene(ScenePackage& package, const std::string& call,
                     bool parented = false) {
    const auto model = package.AddImageModel("plain");
    std::vector<Json> objects;
    if (parented) objects.push_back(PlainImage(model, 1, "parent", {
        {"origin", "100 200 300"}, {"angles", "0.1 0.2 0.3"}, {"scale", "2 3 4"}}));
    auto layer = PlainImage(model, 2, "spin", {
        {"origin", "20 30 40"}, {"angles", "0.1 0.2 0.3"},
        {"alpha", ScriptedValue("var done=false; export function update(v){"
            "if(!done){done=true;" + call + "}return v;}", 1.0)}});
    if (parented) layer["parent"] = 1;
    objects.push_back(std::move(layer));
    Publish(package, objects);
}

linalg::Vector3f Facing(ScriptScene& scene) {
    const auto angles = scene.AnglesDegrees("spin");
    const double x = angles[0] * kPi / 180;
    const double y = angles[1] * kPi / 180;
    const double z = angles[2] * kPi / 180;
    // Third column of Rz * Ry * Rx; WE image lookAt faces positive Z.
    return {static_cast<float>(std::cos(z)*std::sin(y)*std::cos(x)+std::sin(z)*std::sin(x)),
            static_cast<float>(std::sin(z)*std::sin(y)*std::cos(x)-std::cos(z)*std::sin(x)),
            static_cast<float>(std::cos(y)*std::cos(x))};
}

TEST(ScriptLookAt, ImageFacesTheTargetInParentSpaceAndKeepsItsOrigin) {
    for (const bool parented : {false, true}) {
        ScenePackage package;
        MakeLookAtScene(package, "thisLayer.lookAt(new Vec3(25,37,49));", parented);
        ScriptScene scene(package);
        ASSERT_TRUE(scene.ok()) << scene.error();
        scene.Tick(2);
        EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
        EXPECT_LT((Facing(scene) - linalg::Vector3f(5,7,9).normalized()).norm(), 1e-5f);
        EXPECT_EQ(scene.Origin("spin"), (std::array<float,3>{20,30,40}));
    }
}

TEST(ScriptLookAt, ModelAndImageFaceTheSameTargetAxis) {
    ScenePackage package;
    MakeLookAtScene(package, "thisLayer.lookAt(new Vec3(25,37,49));");
    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.runtime().RegisterModelFlags("spin", false, false);
    scene.Tick(2);
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
    EXPECT_LT((Facing(scene) - linalg::Vector3f(5,7,9).normalized()).norm(), 1e-5f);
}

TEST(ScriptLookAt, YawRemovesTheComponentAlongTheChosenUpAxis) {
    ScenePackage package;
    MakeLookAtScene(package, "thisLayer.lookAtYaw(new Vec3(25,37,49),new Vec3(0,0,1));");
    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick(2);
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
    EXPECT_LT((Facing(scene) - linalg::Vector3f(5,7,0).normalized()).norm(), 1e-5f);
}

TEST(ScriptLookAt, ATargetInsideTheDirectionToleranceKeepsTheCurrentAngles) {
    ScenePackage package;
    MakeLookAtScene(package, "thisLayer.lookAt(new Vec3(20.0001,30,40));"
        "thisLayer.lookAtYaw(new Vec3(20,31,40));");
    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    const auto angles = scene.AnglesDegrees("spin");
    scene.Tick(2);
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
    EXPECT_EQ(scene.AnglesDegrees("spin"), angles);
}

TEST(ScriptLookAt, ACameraFacesTheTargetAlongItsNegativeZAxis) {
    ScenePackage package;
    auto document=SceneJson({}, {Json{{"id",1},{"name","spin"},{"camera","default"},
        {"origin",ScriptedValue("export function update(v){thisLayer.lookAt(new Vec3(5,7,19));return v;}","0 0 10")},
        {"angles","0 0 0"},{"visible",true}}});
    document["general"]["orthogonalprojection"]=nullptr;
    package.SetProject();package.SetScene(document);
    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick(2);
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
    EXPECT_LT((-Facing(scene)-linalg::Vector3f(5,7,9).normalized()).norm(),1e-5f);
}
} // namespace
