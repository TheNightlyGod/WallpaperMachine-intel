// Shared fixture of the text-object behaviour tests: a scratch world, the parsed scene and
// short accessors over it. Not a test file.
#pragma once

#include "support/text_scene.hpp"

#include "Image.hpp"
#include "Interface/IImageParser.h"
#include "Scene/Scene.h"
#include "Text/TextLayer.hpp"

#include <gtest/gtest.h>

#include <memory>
#include <string>

namespace we_test
{

class TextSceneTest : public ::testing::Test {
protected:
    // `world` is declared first so it outlives the scene whose mounts it backs.
    TextWorld                         world;
    std::shared_ptr<wallpaper::Scene> scene;

    /// Parses `document`; a scene or runtime that is null is a failure.
    bool Load(const Json& document, wallpaper::ProjectProperties properties = {})
    {
        scene = world.Load(document, std::move(properties));
        return scene != nullptr && scene->runtime != nullptr;
    }

    wallpaper::SceneRuntimeContext& Runtime() { return *scene->runtime; }

    wallpaper::SceneNode* Node(std::string_view name) { return RootChild(*scene, name); }

    /// The texture of a layer's card, parsed.
    std::shared_ptr<wallpaper::Image> CardImage(std::string_view layer)
    {
        auto* node = Node(layer);
        if (node == nullptr) return nullptr;
        return scene->imageParser->Parse(CardTexture(*node));
    }

    static constexpr double kFrame = 1.0 / 60.0;
};

/// An `update` script that always returns the given JavaScript expression.
inline std::string UpdateReturning(const std::string& expression)
{
    return "export function update(value) { return " + expression + "; }";
}

} // namespace we_test
