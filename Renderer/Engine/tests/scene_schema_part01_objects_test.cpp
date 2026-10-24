// Scene file schema, part 1: the object types (image, particle, text, model, camera) and the
// material pass they share. Each object is read straight from its JSON with a small in-memory
// asset set mounted; nothing is parsed into a scene.
#include "support/schema_fixtures.hpp"

#include "WPSceneParser.hpp"
#include "wpscene/WPImageObject.h"
#include "wpscene/WPMaterial.h"
#include "wpscene/WPMiscObject.hpp"
#include "wpscene/WPParticleObject.h"

#include <gtest/gtest.h>

#include <array>
#include <string>
#include <vector>

namespace
{

using namespace we_schema;
using namespace wallpaper::wpscene;

using Vec2 = std::array<float, 2>;
using Vec3 = std::array<float, 3>;

// A VFS with the basic object assets mounted (plus anything the test adds).
class ObjectSchema : public ::testing::Test {
protected:
    void SetUp() override { Mount(BasicAssets()); }

    void Mount(FileMap files)
    {
        vfs_ = std::make_unique<wallpaper::fs::VFS>();
        MountAssets(*vfs_, std::move(files));
    }

    wallpaper::fs::VFS& vfs() { return *vfs_; }

    // The image layer the instance tests use, `extra` set over it.
    static Json ImageLayer(const Json& extra = Json::object())
    {
        Json layer = { { "image", "image.json" }, { "id", 7 } };
        for (const auto& [key, value] : extra.items()) layer[key] = value;
        return layer;
    }

private:
    std::unique_ptr<wallpaper::fs::VFS> vfs_;
};

const Json kHexColour = "0.11765 0.11765 0.11765";

// ---- image object ------------------------------------------------------------------------

// R-1.04 / B-1.04
TEST_F(ObjectSchema, ImageObjectAbsorbsItsDependenciesInstanceAndBindings)
{
    const Json json = {
        { "image", "image.json" },
        { "id", 7 },
        { "name", "image layer" },
        { "dependencies", Json::array({ 1, 2 }) },
        { "origin", Json::array({ 1, 2, 3 }) },
        { "attachment", "hat_anchor" },
        { "alpha", { { "value", 0.5 }, { "animation", { { "c0", Json::array({ { { "frame", 0 }, { "value", 0.5 } } }) }, { "options", { { "fps", 30 } } } } } } },
        { "visible", { { "value", true }, { "script", "export function update() { return true; }" }, { "scriptproperties", { { "speed", { { "value", 1 } } } } } } },
        { "instance", { { "id", 42 },
                        { "combos", { { "BLENDMODE", 1 } } },
                        { "textures", Json::array({ "override.tex" }) },
                        { "usertextures", Json::array({ { { "name", "$mediaThumbnail" }, { "type", "system" } } }) } } },
        { "animationlayers", Json::array({ { { "animation", 11 }, { "blend", 0.75 }, { "rate", 1.25 }, { "visible", true }, { "id", 3 }, { "name", "blink" }, { "additive", true }, { "blendin", true }, { "blendout", true }, { "blendtime", 0.4 } } }) },
    };

    WPImageObject image;
    ASSERT_TRUE(image.FromJson(json, vfs()));

    EXPECT_EQ(image.id, 7);
    EXPECT_EQ(image.name, "image layer");
    EXPECT_EQ(image.dependencies, (std::vector<int32_t> { 1, 2 }));
    EXPECT_EQ(image.attachment, "hat_anchor");
    EXPECT_EQ(image.origin, (Vec3 { 1, 2, 3 }));

    ASSERT_FALSE(image.material.textures.empty());
    EXPECT_EQ(image.material.textures[0], "override.tex") << "the instance texture replaces slot 0 of the model's material";
    EXPECT_EQ(image.material.combos.at("BLENDMODE"), 1);
    ASSERT_EQ(image.material.usertextures.size(), 1u);
    EXPECT_EQ(image.material.usertextures[0].name, "$mediaThumbnail");
    EXPECT_EQ(image.material.usertextures[0].type, "system");

    std::vector<std::string> slots = image.material.textures;
    wallpaper::ApplySystemUserTextures(slots, image.material.usertextures);
    ASSERT_FALSE(slots.empty());
    EXPECT_EQ(slots[0], "$mediaThumbnail");

    ASSERT_EQ(image.puppet_layers.size(), 1u);
    const auto& layer = image.puppet_layers[0];
    EXPECT_EQ(layer.layer_id, 3);
    EXPECT_EQ(layer.name, "blink");
    EXPECT_TRUE(layer.additive);
    EXPECT_EQ(layer.id, 11);
    EXPECT_DOUBLE_EQ(layer.blend, 0.75);
    EXPECT_DOUBLE_EQ(layer.rate, 1.25);
    EXPECT_TRUE(layer.blendin);
    EXPECT_TRUE(layer.blendout);
    EXPECT_NEAR(layer.blendtime, 0.4, 1e-9);
    EXPECT_TRUE(layer.visible);

    EXPECT_TRUE(image.field_bindings.contains("alpha"));
    EXPECT_TRUE(image.field_bindings.contains("visible"));
    EXPECT_FALSE(image.field_bindings.contains("origin")) << "a plain array carries no binding";
    EXPECT_TRUE(image.dynamic_alpha) << "an animation member drives the alpha";
    EXPECT_TRUE(image.dynamic_visible) << "a script member drives the visibility";
    EXPECT_TRUE(image.visible) << "the wrapped value is read";
    EXPECT_FLOAT_EQ(image.alpha, 0.5f);
}

// B-1.04: a model or a material that cannot be loaded refuses the object.
TEST_F(ObjectSchema, ImageObjectNeedsItsModelAndMaterialFiles)
{
    WPImageObject missing_model;
    EXPECT_FALSE(missing_model.FromJson({ { "image", "nowhere.json" } }, vfs()));

    FileMap files = BasicAssets();
    PutJson(files, "/orphan.json", { { "material", "absent.json" } });
    PutJson(files, "/materialless.json", { { "width", 4 } });
    Mount(files);
    WPImageObject missing_material;
    EXPECT_FALSE(missing_material.FromJson({ { "image", "orphan.json" } }, vfs()));
    WPImageObject no_material_key;
    EXPECT_FALSE(no_material_key.FromJson({ { "image", "materialless.json" } }, vfs()));
    WPImageObject no_image_key;
    EXPECT_FALSE(no_image_key.FromJson({ { "id", 1 } }, vfs()));
}

// R-1.05 / B-1.05: row 1, a runtime picture replacing the white placeholder takes the tint with it.
TEST_F(ObjectSchema, ASystemPictureOverTheWhitePlaceholderDropsTheTint)
{
    const Json layer = ImageLayer({ { "color", kHexColour },
                                    { "instance", { { "id", 42 },
                                                    { "textures", Json::array({ "util/white" }) },
                                                    { "usertextures", Json::array({ { { "name", "$mediaThumbnail" }, { "type", "system" } } }) } } } });
    WPImageObject image;
    ASSERT_TRUE(image.FromJson(layer, vfs()));
    EXPECT_EQ(image.color, (Vec3 { 1.0f, 1.0f, 1.0f }));
    EXPECT_TRUE(image.colorIgnored);
}

// R-1.05 / B-1.05: row 2, a bare property name is not a picture the runtime supplies.
TEST_F(ObjectSchema, APropertyPictureKeepsTheTint)
{
    const Json layer = ImageLayer({ { "color", kHexColour },
                                    { "instance", { { "id", 42 },
                                                    { "textures", Json::array({ "util/white" }) },
                                                    { "usertextures", Json::array({ "backgroundimage" }) } } } });
    WPImageObject image;
    ASSERT_TRUE(image.FromJson(layer, vfs()));
    EXPECT_EQ(image.color, (Vec3 { 0.11765f, 0.11765f, 0.11765f }));
    EXPECT_FALSE(image.colorIgnored);
}

// R-1.05 / B-1.05: rows 3 and 4, the tint's property binding goes with a system picture and stays with a property one.
TEST_F(ObjectSchema, TheTintBindingIsDroppedWithASystemPictureAndKeptOtherwise)
{
    const Json bound = { { "user", "tint" }, { "value", kHexColour } };
    const auto layer = [&](const Json& usertexture) {
        return ImageLayer({ { "color", bound },
                            { "instance", { { "id", 42 },
                                            { "textures", Json::array({ "util/white" }) },
                                            { "usertextures", Json::array({ usertexture }) } } } });
    };

    WPImageObject system_picture;
    ASSERT_TRUE(system_picture.FromJson(layer({ { "name", "$mediaThumbnail" }, { "type", "system" } }), vfs()));
    EXPECT_FALSE(system_picture.field_bindings.contains("color"));
    EXPECT_EQ(system_picture.color, (Vec3 { 1.0f, 1.0f, 1.0f }));

    WPImageObject property_picture;
    ASSERT_TRUE(property_picture.FromJson(layer("backgroundimage"), vfs()));
    EXPECT_TRUE(property_picture.field_bindings.contains("color"));
    EXPECT_EQ(property_picture.color, (Vec3 { 0.11765f, 0.11765f, 0.11765f }));
}

// B-1.05: only the two cover names of type `system` count, and only over a white placeholder.
TEST_F(ObjectSchema, OnlyTheCoverPicturesOverWhiteDropTheTint)
{
    const auto read = [&](const std::string& slot_texture, const Json& usertexture) {
        const Json layer = ImageLayer({ { "color", kHexColour },
                                        { "instance", { { "id", 42 },
                                                        { "textures", Json::array({ slot_texture }) },
                                                        { "usertextures", Json::array({ usertexture }) } } } });
        WPImageObject image;
        EXPECT_TRUE(image.FromJson(layer, vfs()));
        return image;
    };
    const Vec3 kept { 0.11765f, 0.11765f, 0.11765f };

    EXPECT_EQ(read("util/white", { { "name", "$other" }, { "type", "system" } }).color, kept);
    EXPECT_EQ(read("util/white", { { "name", "$mediaThumbnail" }, { "type", "user" } }).color, kept);
    EXPECT_EQ(read("util/white", { { "name", "$mediaThumbnail" } }).color, kept);
    EXPECT_EQ(read("override.tex", { { "name", "$mediaThumbnail" }, { "type", "system" } }).color, kept)
        << "the slot's texture is not the white placeholder";

    const auto previous = read("util/white", { { "name", "$mediaPreviousThumbnail" }, { "type", "system" } });
    EXPECT_EQ(previous.color, (Vec3 { 1.0f, 1.0f, 1.0f }));
    EXPECT_TRUE(previous.colorIgnored);
}

// ---- material ----------------------------------------------------------------------------

// R-1.06 / B-1.06
TEST(MaterialSchema, ConstantShaderValueBindingsSurvivePassParsingAndMerging)
{
    const Json material_json = { { "passes", Json::array({ { { "blending", "translucent" },
                                                              { "cullmode", "nocull" },
                                                              { "depthtest", "disabled" },
                                                              { "depthwrite", "disabled" },
                                                              { "shader", "genericimage" },
                                                              { "textures", Json::array({ "a.tex" }) },
                                                              { "constantshadervalues", { { "Opacity", { { "user", "opacity_user" }, { "value", Json::array({ 0.25 }) } } }, { "Tint", { { "user", "tint_user" }, { "value", Json::array({ 0.1, 0.2, 0.3 }) } } } } } } }) } };
    WPMaterial material;
    ASSERT_TRUE(material.FromJson(material_json));
    ASSERT_TRUE(material.constantshadervalues.count("Opacity"));
    {
        const auto& opacity = material.constantshadervalues.at("Opacity");
        EXPECT_EQ(opacity.user, "opacity_user");
        ASSERT_EQ(opacity.value.size(), 1u);
        EXPECT_FLOAT_EQ(opacity.value[0], 0.25f);
    }

    WPMaterialPass pass;
    ASSERT_TRUE(pass.FromJson({ { "constantshadervalues", { { "Opacity", { { "user", "override_opacity" }, { "value", Json::array({ 0.75 }) } } } } } }));
    material.MergePass(pass);

    const auto& opacity = material.constantshadervalues.at("Opacity");
    EXPECT_EQ(opacity.user, "override_opacity");
    ASSERT_EQ(opacity.value.size(), 1u);
    EXPECT_FLOAT_EQ(opacity.value[0], 0.75f);

    ASSERT_TRUE(material.constantshadervalues.count("Tint")) << "a merge replaces by key, not the whole map";
    const auto& tint = material.constantshadervalues.at("Tint");
    EXPECT_EQ(tint.user, "tint_user");
    ASSERT_EQ(tint.value.size(), 3u);
    EXPECT_FLOAT_EQ(tint.value[0], 0.1f);
    EXPECT_FLOAT_EQ(tint.value[1], 0.2f);
    EXPECT_FLOAT_EQ(tint.value[2], 0.3f);
}

// B-1.06: the `{name, condition}` form of `user`, and a text value.
TEST(MaterialSchema, ConstantUserCanBeANameWithAConditionAndValueCanBeText)
{
    WPMaterialPass pass;
    ASSERT_TRUE(pass.FromJson({ { "constantshadervalues",
                                  { { "Flag", { { "user", { { "name", "p" }, { "condition", "c" } } }, { "value", 0 } } },
                                    { "Colour", { { "value", "1 2 3" } } },
                                    { "Plain", { { "user", "p" }, { "value", 1 } } } } } }));
    const auto& flag = pass.constantshadervalues.at("Flag");
    EXPECT_EQ(flag.user, "p");
    ASSERT_TRUE(flag.user_condition.has_value());
    EXPECT_EQ(*flag.user_condition, "c");

    const auto& colour = pass.constantshadervalues.at("Colour");
    ASSERT_EQ(colour.value.size(), 3u);
    EXPECT_FLOAT_EQ(colour.value[0], 1.0f);
    EXPECT_FLOAT_EQ(colour.value[1], 2.0f);
    EXPECT_FLOAT_EQ(colour.value[2], 3.0f);

    const auto& plain = pass.constantshadervalues.at("Plain");
    EXPECT_EQ(plain.user, "p");
    EXPECT_FALSE(plain.user_condition.has_value());
}

// ---- particle object ---------------------------------------------------------------------

// R-1.07 / B-1.07
TEST_F(ObjectSchema, ParticleObjectAbsorbsDependenciesOverrideBindingsAndItsChild)
{
    const Json json = { { "particle", "particle.json" },
                        { "id", 9 },
                        { "name", "particles" },
                        { "dependencies", Json::array({ 7 }) },
                        { "instanceoverride", { { "id", 5 }, { "alpha", 0.5 }, { "count", 2 }, { "color", Json::array({ 0.1, 0.2, 0.3 }) } } },
                        { "origin", { { "value", Json::array({ 0, 0, 0 }) }, { "scriptproperties", { { "x", { { "value", 1 } } } } } } },
                        { "visible", true } };
    WPParticleObject particle;
    ASSERT_TRUE(particle.FromJson(json, vfs()));

    EXPECT_EQ(particle.id, 9);
    EXPECT_EQ(particle.name, "particles");
    EXPECT_EQ(particle.dependencies, (std::vector<int32_t> { 7 }));
    EXPECT_TRUE(particle.instanceoverride.enabled);
    EXPECT_EQ(particle.instanceoverride.id, 5);
    EXPECT_TRUE(particle.instanceoverride.overColor);
    EXPECT_FALSE(particle.instanceoverride.overColorn);
    EXPECT_FLOAT_EQ(particle.instanceoverride.alpha, 0.5f);
    EXPECT_FLOAT_EQ(particle.instanceoverride.count, 2.0f);
    EXPECT_FLOAT_EQ(particle.instanceoverride.color[0], 0.1f);
    EXPECT_FLOAT_EQ(particle.instanceoverride.color[1], 0.2f);
    EXPECT_FLOAT_EQ(particle.instanceoverride.color[2], 0.3f);
    EXPECT_TRUE(particle.field_bindings.contains("origin"));
    EXPECT_FALSE(particle.field_bindings.contains("visible"));

    ASSERT_EQ(particle.particleObj.children.size(), 1u);
    const auto& child = particle.particleObj.children[0];
    EXPECT_EQ(child.name, "child_particle.json");
    EXPECT_EQ(child.type, "eventspawn");
    EXPECT_EQ(child.maxcount, 3);
    EXPECT_EQ(child.origin[1], 2.0f);
    ASSERT_EQ(child.obj.emitters.size(), 1u);
    EXPECT_EQ(child.obj.emitters[0].name, "child_emit");
}

// B-1.07: `colorn` is the same override on a 0..1 scale, and only when `color` is absent.
TEST_F(ObjectSchema, ParticleOverrideTakesColornWhenThereIsNoColor)
{
    WPParticleObject particle;
    ASSERT_TRUE(particle.FromJson({ { "particle", "particle.json" }, { "instanceoverride", { { "id", 5 }, { "colorn", Json::array({ 0.1, 0.2, 0.3 }) } } } }, vfs()));
    EXPECT_TRUE(particle.instanceoverride.overColorn);
    EXPECT_FALSE(particle.instanceoverride.overColor);
    EXPECT_FLOAT_EQ(particle.instanceoverride.colorn[2], 0.3f);
}

// B-1.07: a particle file that cannot be loaded refuses the object.
TEST_F(ObjectSchema, ParticleObjectNeedsItsParticleFile)
{
    WPParticleObject missing;
    EXPECT_FALSE(missing.FromJson({ { "particle", "nowhere.json" } }, vfs()));

    FileMap files = BasicAssets();
    PutJson(files, "/noemitter.json", { { "material", "mat.json" } });
    Mount(files);
    WPParticleObject unusable;
    EXPECT_FALSE(unusable.FromJson({ { "particle", "noemitter.json" } }, vfs())) << "a file with no emitter key is not a particle file";
}

// ---- text, model and camera objects ------------------------------------------------------

// R-1.08 / B-1.08: text
TEST_F(ObjectSchema, TextObjectReadsItsLayoutKeys)
{
    WPTextObject text;
    ASSERT_TRUE(text.FromJson({ { "id", 1 },
                                { "text", { { "value", "hello" } } },
                                { "font", "Arial" },
                                { "pointsize", 24 },
                                { "padding", 4 },
                                { "horizontalalign", "center" },
                                { "verticalalign", "middle" },
                                { "anchor", "center" },
                                { "maxrows", 2 },
                                { "maxwidth", 300 },
                                { "limitrows", true },
                                { "limitwidth", true },
                                { "limituseellipsis", true },
                                { "dependencies", Json::array({ 9 }) },
                                { "alpha", { { "script", "export function update() { return 1; }" } } } },
                              vfs()));
    EXPECT_EQ(text.id, 1);
    EXPECT_EQ(text.text.at("value").get<std::string>(), "hello");
    EXPECT_EQ(text.font.get<std::string>(), "Arial");
    EXPECT_FLOAT_EQ(text.pointsize, 24.0f);
    EXPECT_EQ(text.padding, (Vec2 { 4.0f, 4.0f })) << "a bare number fills both lanes";
    EXPECT_EQ(text.horizontalalign, "center");
    EXPECT_EQ(text.verticalalign, "middle");
    EXPECT_EQ(text.anchor, "center");
    EXPECT_EQ(text.maxrows, 2u);
    EXPECT_FLOAT_EQ(text.maxwidth, 300.0f);
    EXPECT_TRUE(text.limitrows);
    EXPECT_TRUE(text.limitwidth);
    EXPECT_TRUE(text.limituseellipsis);
    EXPECT_EQ(text.dependencies, (std::vector<int32_t> { 9 }));
    EXPECT_TRUE(text.field_bindings.contains("alpha"));
}

// B-1.08: text defaults when the keys are absent.
TEST_F(ObjectSchema, TextObjectKeepsItsDefaultsForAbsentKeys)
{
    WPTextObject text;
    ASSERT_TRUE(text.FromJson({ { "id", 1 } }, vfs()));
    EXPECT_FLOAT_EQ(text.pointsize, 32.0f);
    EXPECT_EQ(text.padding, (Vec2 { 32.0f, 32.0f }));
    EXPECT_EQ(text.maxrows, 1u);
    EXPECT_FLOAT_EQ(text.maxwidth, 500.0f);
    EXPECT_FALSE(text.limitrows);
    EXPECT_FALSE(text.limitwidth);
    EXPECT_FALSE(text.limituseellipsis);
    EXPECT_EQ(text.horizontalalign, "center");
    EXPECT_EQ(text.verticalalign, "center");
}

// B-1.08: the alignment words are kept as written; a word that is not a string reads as the
// first entry of the registry's list.
TEST_F(ObjectSchema, TextAlignmentWordsAreKeptAndNonStringsReadAsTheFirstEntry)
{
    WPTextObject written;
    ASSERT_TRUE(written.FromJson({ { "id", 1 }, { "horizontalalign", "right" }, { "verticalalign", "top" }, { "anchor", "topleft" } }, vfs()));
    EXPECT_EQ(written.horizontalalign, "right");
    EXPECT_EQ(written.verticalalign, "top");
    EXPECT_EQ(written.anchor, "topleft");

    WPTextObject numbers;
    ASSERT_TRUE(numbers.FromJson({ { "id", 1 }, { "horizontalalign", 3 }, { "verticalalign", nullptr }, { "anchor", 5 } }, vfs()));
    EXPECT_EQ(numbers.horizontalalign, "left");
    EXPECT_EQ(numbers.verticalalign, "center");
    EXPECT_EQ(numbers.anchor, "none");
}

// R-1.08 / B-1.08: model
TEST_F(ObjectSchema, ModelObjectReadsItsModelAndFlags)
{
    WPModelObject model;
    ASSERT_TRUE(model.FromJson({ { "id", 2 }, { "model", "model.mdl" }, { "attachment", "head" }, { "perspective", true }, { "dependencies", Json::array({ 1 }) } }, vfs()));
    EXPECT_EQ(model.id, 2);
    EXPECT_EQ(model.model, "model.mdl");
    EXPECT_EQ(model.attachment, "head");
    EXPECT_TRUE(model.perspective);
    EXPECT_EQ(model.dependencies, (std::vector<int32_t> { 1 }));
    EXPECT_TRUE(model.solid) << "layers are solid unless they say otherwise";
    EXPECT_FALSE(model.disablepropagation);
}

// B-1.08: an object with no model refuses to be a model object.
TEST_F(ObjectSchema, ModelObjectWithoutAModelIsRefused)
{
    WPModelObject model;
    EXPECT_FALSE(model.FromJson({ { "id", 2 }, { "perspective", true } }, vfs()));
    WPModelObject empty;
    EXPECT_FALSE(empty.FromJson({ { "id", 2 }, { "model", "" } }, vfs()));
}

// R-1.08 / B-1.08: camera
TEST_F(ObjectSchema, CameraObjectReadsItsLens)
{
    WPCameraObject camera;
    ASSERT_TRUE(camera.FromJson({ { "id", 3 }, { "camera", "main" }, { "path", "camera.json" }, { "fov", 80 }, { "zoom", 1.5 }, { "solid", true }, { "disablepropagation", true } }, vfs()));
    EXPECT_EQ(camera.id, 3);
    EXPECT_EQ(camera.camera, "main");
    EXPECT_EQ(camera.path, "camera.json");
    EXPECT_FLOAT_EQ(camera.fov, 80.0f);
    EXPECT_FLOAT_EQ(camera.zoom, 1.5f);
    EXPECT_TRUE(camera.solid);
    EXPECT_TRUE(camera.disablepropagation);
}

// B-1.08: camera defaults when the keys are absent.
TEST_F(ObjectSchema, CameraObjectDefaultsToTheSceneLens)
{
    WPCameraObject camera;
    ASSERT_TRUE(camera.FromJson({ { "id", 3 }, { "camera", "main" } }, vfs()));
    EXPECT_FALSE(camera.solid);
    EXPECT_FALSE(camera.disablepropagation);
    EXPECT_FLOAT_EQ(camera.fov, 0.0f);
    EXPECT_FLOAT_EQ(camera.zoom, 1.0f);
    EXPECT_TRUE(camera.path.empty());
}

} // namespace
