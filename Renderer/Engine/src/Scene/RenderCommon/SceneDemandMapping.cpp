#include "Scene/include/Scene/SceneUpdateDemand.hpp"

#include "RenderCommon/StaticSubgraphCache.hpp"

namespace wallpaper
{

uint32_t SceneDemandReasonsFromShaderInputs(uint32_t shader_reasons)
{
    // Maps the renderer's per-pass reflection vocabulary onto the scene-level
    // one. Three of the renderer's reasons are deliberately NOT carried over:
    //
    // - `PointerUniform`: a pointer-reactive scene is event-driven, not
    //   continuously changing. It sleeps until the pointer moves, and the
    //   pointer path wakes it.
    // - `RuntimeImage`: an image the runtime may swap is a change that arrives
    //   as an event, and the code that swaps it requests a frame.
    // - `EventMesh`: geometry the runtime rewrites when an event re-lays it
    //   out -- a text card. Between two relayouts the vertices are the same
    //   vertices; the relayout itself arrives as an event, and the frame it
    //   needs is requested by whatever delivered it.
    //
    // All three still make a render target ineligible for pixel reuse, which is
    // a different question answered elsewhere. Every other reason means
    // something advances on its own and the clock has to keep running.
    //
    // Dropping a bit here is the one mistake this mapping must not make by
    // accident, so each omission is named above rather than left to the
    // absence of a line.
    using render::DynamicReason;
    uint32_t reasons = 0;
    if (shader_reasons & DynamicReason::TimeUniform) reasons |= SceneDemandReason::TimeUniform;
    if (shader_reasons & DynamicReason::AudioUniform) reasons |= SceneDemandReason::AudioResponse;
    if (shader_reasons & DynamicReason::BoneUniform) reasons |= SceneDemandReason::Puppet;
    if (shader_reasons & DynamicReason::VideoInput) reasons |= SceneDemandReason::Video;
    if (shader_reasons & DynamicReason::DynamicMesh) reasons |= SceneDemandReason::DynamicMesh;
    if (shader_reasons & DynamicReason::AnimatedSprite) reasons |= SceneDemandReason::AnimatedSprite;
    if (shader_reasons & DynamicReason::Feedback) reasons |= SceneDemandReason::Feedback;
    if (shader_reasons & DynamicReason::UnknownInput) reasons |= SceneDemandReason::UnknownInput;
    return reasons;
}

bool SceneShaderInputsUsePointer(uint32_t shader_reasons)
{
    return shader_reasons & render::DynamicReason::PointerUniform;
}

} // namespace wallpaper
