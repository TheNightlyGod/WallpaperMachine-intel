// `rotateObjectSpace` (item 5 of the SceneScript behaviour list): an Euler-angle increment in
// radians around the layer's own local axes, composed onto its orientation. Every expectation is
// worked out here from rotation matrices, independently of the engine's own composition.
//
// Headless: scenes are loaded for their runtime only (support/script_scene.hpp).

#include "scenescript_scenes.hpp"

#include "Runtime/SceneRuntimeContext.hpp"

#include <gtest/gtest.h>

#include <array>
#include <cmath>

namespace
{
using namespace we_test;

using Mat3 = std::array<std::array<double, 3>, 3>;
using Vec3d = std::array<double, 3>;

Mat3 Multiply(const Mat3& a, const Mat3& b)
{
    Mat3 out {};
    for (int row = 0; row < 3; ++row) {
        for (int column = 0; column < 3; ++column) {
            for (int k = 0; k < 3; ++k) out[row][column] += a[row][k] * b[k][column];
        }
    }
    return out;
}

Mat3 TurnX(double a) { return { { { 1, 0, 0 }, { 0, std::cos(a), -std::sin(a) }, { 0, std::sin(a), std::cos(a) } } }; }
Mat3 TurnY(double a) { return { { { std::cos(a), 0, std::sin(a) }, { 0, 1, 0 }, { -std::sin(a), 0, std::cos(a) } } }; }
Mat3 TurnZ(double a) { return { { { std::cos(a), -std::sin(a), 0 }, { std::sin(a), std::cos(a), 0 }, { 0, 0, 1 } } }; }

double Radians(double degrees) { return degrees * kPi / 180.0; }
double Degrees(double radians) { return radians * 180.0 / kPi; }

// The turn a scene file's angles (degrees) describe: z, then y, then x about the layer's axes,
// as a matrix Rz * Ry * Rx.
Mat3 FromAngles(const Vec3d& degrees)
{
    return Multiply(TurnZ(Radians(degrees[2])), Multiply(TurnY(Radians(degrees[1])), TurnX(Radians(degrees[0]))));
}

// An increment in radians: the same composition.
Mat3 FromIncrement(const Vec3d& radians)
{
    return Multiply(TurnZ(radians[2]), Multiply(TurnY(radians[1]), TurnX(radians[0])));
}

// Angles in degrees of Rz * Ry * Rx away from the pole: y from the bottom row, x and z from the
// entries the other two turns leave alone.
Vec3d ToAngles(const Mat3& m)
{
    return { Degrees(std::atan2(m[2][1], m[2][2])), Degrees(std::asin(-m[2][0])), Degrees(std::atan2(m[1][0], m[0][0])) };
}

// A driver whose `update` runs `calls[i]` on the i-th tick.
std::string Driver(const std::string& layer, const std::vector<std::string>& calls)
{
    std::string text = "var tick = 0;\nexport function update() {\n  var layer = thisScene.getLayer('" + layer + "');\n  tick += 1;\n";
    for (std::size_t i = 0; i < calls.size(); ++i) {
        text += "  if (tick === " + std::to_string(i + 1) + ") layer.rotateObjectSpace(" + calls[i] + ");\n";
    }
    return text + "}\n";
}

// A scene file's `angles` text for angles given in degrees (the file holds radians).
std::string FileAngles(double x, double y, double z)
{
    return std::to_string(Radians(x)) + " " + std::to_string(Radians(y)) + " " + std::to_string(Radians(z));
}

Json DriverLayer(const std::string& model, int id, const std::string& source)
{
    return PlainImage(model, id, "driver", { { "alpha", ScriptedValue(source, 1.0) } });
}

void ExpectAngles(const std::array<float, 3>& seen, const Vec3d& wanted, double tolerance = 5e-3)
{
    for (int axis = 0; axis < 3; ++axis) EXPECT_NEAR(seen[axis], wanted[axis], tolerance) << "axis " << axis;
}

class Rotation : public ::testing::Test {
protected:
    ScenePackage package_;
    std::string  model_ { package_.AddImageModel("plain") };
};
} // namespace

TEST_F(Rotation, AnIncrementAboutEachLocalAxisFromAKnownOrientation)
{
    struct Case {
        const char* call;
        Vec3d       increment;
    };
    const Vec3d start { 10.0, 20.0, 30.0 };
    for (const Case& test : { Case { "new Vec3(0.5, 0, 0)", { 0.5, 0, 0 } }, Case { "new Vec3(0, 0.3, 0)", { 0, 0.3, 0 } },
                              Case { "new Vec3(0, 0, -0.4)", { 0, 0, -0.4 } }, Case { "new Vec3(0.2, -0.3, 0.4)", { 0.2, -0.3, 0.4 } } }) {
        ScenePackage package;
        const auto   model = package.AddImageModel("plain");
        Publish(package, { PlainImage(model, 1, "spin", { { "angles", FileAngles(10, 20, 30) } }),
                           DriverLayer(model, 2, Driver("spin", { test.call })) });
        ScriptScene scene(package);
        ASSERT_TRUE(scene.ok()) << scene.error();
        scene.Tick(2);
        ExpectAngles(scene.AnglesDegrees("spin"), ToAngles(Multiply(FromAngles(start), FromIncrement(test.increment))));
        EXPECT_TRUE(scene.ScriptErrors().empty()) << test.call << ": " << Describe(scene.ScriptErrors());
    }
}

TEST_F(Rotation, AnIncrementIsInRadiansAndAnglesStayInDegrees)
{
    // 90 degrees about x, from the identity: radians in, degrees out.
    Publish(package_, { PlainImage(model_, 1, "spin"),
                        DriverLayer(model_, 2, Driver("spin", { "new Vec3(Math.PI / 2, 0, 0)" })) });
    ScriptScene scene(package_);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick(2);
    ExpectAngles(scene.AnglesDegrees("spin"), { 90.0, 0.0, 0.0 });
}

TEST_F(Rotation, SuccessiveCallsComposeOntoTheResultOfTheLast)
{
    Publish(package_, { PlainImage(model_, 1, "spin", { { "angles", FileAngles(0, 25, 0) } }),
                        DriverLayer(model_, 2, Driver("spin", { "new Vec3(0.3, 0, 0)", "new Vec3(0, 0, 0.5)", "new Vec3(0, 0.2, 0.1)" })) });
    ScriptScene scene(package_);
    ASSERT_TRUE(scene.ok()) << scene.error();

    Mat3 expected = FromAngles({ 0, 25, 0 });
    scene.Tick(1);
    expected = Multiply(expected, FromIncrement({ 0.3, 0, 0 }));
    ExpectAngles(scene.AnglesDegrees("spin"), ToAngles(expected));
    scene.Tick(1);
    expected = Multiply(expected, FromIncrement({ 0, 0, 0.5 }));
    ExpectAngles(scene.AnglesDegrees("spin"), ToAngles(expected));
    scene.Tick(1);
    expected = Multiply(expected, FromIncrement({ 0, 0.2, 0.1 }));
    ExpectAngles(scene.AnglesDegrees("spin"), ToAngles(expected));
    scene.Tick(2);
    ExpectAngles(scene.AnglesDegrees("spin"), ToAngles(expected));
}

TEST_F(Rotation, TwoCallsLandOnTheComposedRotation)
{
    const auto run = [&](const std::vector<std::string>& calls) {
        ScenePackage package;
        const auto   model = package.AddImageModel("plain");
        Publish(package, { PlainImage(model, 1, "spin", { { "angles", FileAngles(15, -10, 5) } }), DriverLayer(model, 2, Driver("spin", calls)) });
        ScriptScene scene(package);
        EXPECT_TRUE(scene.ok()) << scene.error();
        scene.Tick(4);
        return scene.AnglesDegrees("spin");
    };
    const auto twice = run({ "new Vec3(0.4, 0, 0)", "new Vec3(0, 0.6, 0)" });
    // Rx(0.4) and then Ry(0.6), both about the layer's own axes as they stand at each call.
    const Vec3d wanted = ToAngles(Multiply(Multiply(FromAngles({ 15, -10, 5 }), FromIncrement({ 0.4, 0, 0 })), FromIncrement({ 0, 0.6, 0 })));
    ExpectAngles(twice, wanted);
}

TEST_F(Rotation, UnderARotatedAndScaledParentTheIncrementIsAboutTheLayersOwnAxes)
{
    Json parent = GroupJson(5, "parent", { 128.0f, 72.0f, 0.0f });
    parent["angles"] = FileAngles(0, 0, 90);
    parent["scale"]  = "2 2 2";
    Publish(package_, { parent, PlainImage(model_, 1, "spin", { { "parent", 5 }, { "origin", "10 0 0" } }),
                        DriverLayer(model_, 2, Driver("spin", { "new Vec3(0.5, 0, 0)" })) });
    ScriptScene scene(package_);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick(2);

    // The layer's own angles carry the increment...
    ExpectAngles(scene.AnglesDegrees("spin"), { Degrees(0.5), 0.0, 0.0 });
    // ... and what the scene shows is the parent's turn followed by it: the columns of the
    // layer's world matrix, divided by the parent's scale of 2.
    const auto  world    = scene.runtime().NodeTransformMatrix("spin");
    const Mat3  expected = Multiply(FromAngles({ 0, 0, 90 }), FromIncrement({ 0.5, 0, 0 }));
    for (int row = 0; row < 3; ++row) {
        for (int column = 0; column < 3; ++column) {
            EXPECT_NEAR(world(row, column) / 2.0, expected[row][column], 1e-4) << row << "," << column;
        }
    }
}

TEST_F(Rotation, AMirroredLayerRotatesAboutItsOwnLocalAxes)
{
    struct Mirror {
        const char* scale;
        Vec3d       factors;
    };
    for (const Mirror& mirror : { Mirror { "-1 1 1", { -1, 1, 1 } }, Mirror { "1 -2 1", { 1, -2, 1 } }, Mirror { "1 1 -1", { 1, 1, -1 } } }) {
        ScenePackage package;
        const auto   model = package.AddImageModel("plain");
        Publish(package, { PlainImage(model, 1, "spin", { { "angles", FileAngles(20, -15, 40) }, { "scale", mirror.scale } }),
                           DriverLayer(model, 2, Driver("spin", { "new Vec3(0.3, 0.2, -0.1)" })) });
        ScriptScene scene(package);
        ASSERT_TRUE(scene.ok()) << scene.error();
        scene.Tick(2);
        const Mat3 turned = Multiply(FromAngles({ 20, -15, 40 }), FromIncrement({ 0.3, 0.2, -0.1 }));
        ExpectAngles(scene.AnglesDegrees("spin"), ToAngles(turned));
        // The scale is untouched and the world matrix is the turn followed by the mirror.
        const auto scale = scene.Scale("spin");
        for (int axis = 0; axis < 3; ++axis) EXPECT_FLOAT_EQ(scale[axis], static_cast<float>(mirror.factors[axis]));
        const auto world = scene.runtime().NodeTransformMatrix("spin");
        for (int row = 0; row < 3; ++row) {
            for (int column = 0; column < 3; ++column) {
                EXPECT_NEAR(world(row, column), turned[row][column] * mirror.factors[column], 1e-4) << mirror.scale;
            }
        }
    }
}

TEST_F(Rotation, AnAnchoredLayerKeepsItsAnchorWhereItWas)
{
    // `left`: the layer hangs from the middle of its left edge, which is its origin.
    Publish(package_, { PlainImage(model_, 1, "spin", { { "alignment", "left" }, { "scale", "2 2 1" }, { "angles", FileAngles(0, 0, 15) } }),
                        DriverLayer(model_, 2, Driver("spin", { "new Vec3(0, 0, 0.7)" })) });
    ScriptScene scene(package_);
    ASSERT_TRUE(scene.ok()) << scene.error();
    const auto before = scene.Origin("spin");
    scene.Tick(2);
    ExpectAngles(scene.AnglesDegrees("spin"), ToAngles(Multiply(FromAngles({ 0, 0, 15 }), FromIncrement({ 0, 0, 0.7 }))));
    const auto size  = scene.runtime().NodeSize("spin");
    const auto world = scene.runtime().NodeTransformMatrix("spin");
    // The middle of the left edge is (-size.x / 2, 0) in the layer's own plane.
    const double edge = -size.x() * 0.5;
    const double x    = world(0, 0) * edge + world(0, 3);
    const double y    = world(1, 0) * edge + world(1, 3);
    EXPECT_NEAR(x, before[0], 1e-3);
    EXPECT_NEAR(y, before[1], 1e-3);
    EXPECT_EQ(scene.Origin("spin"), before) << "the origin a script reads is the anchor";
}

TEST_F(Rotation, ALayerWithoutANodeIsLeftAlone)
{
    Publish(package_, { PlainImage(model_, 1, "spin"),
                        DriverLayer(model_, 2, "export function update() { thisScene.getLayer('nobody').rotateObjectSpace(new Vec3(1, 0, 0)); }") });
    ScriptScene scene(package_);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick(2);
    ExpectAngles(scene.AnglesDegrees("spin"), { 0, 0, 0 });
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
}

