#pragma once

#include <cstdint>
#include <string_view>

namespace wallpaper
{
class Scene;

/// Optional Metal program variants, compiled in the background.
///
/// A variant is never part of what a wallpaper needs to draw. The ordinary
/// program is compiled with the scene and is what the first frame uses; this
/// only ever adds a second program that a later frame may switch to. Nothing
/// here is on the path to a first frame, and a variant that fails, is still
/// compiling, or is never asked for leaves the wallpaper exactly as it was.

/// Submits this scene's candidate programs, or does nothing when `wanted` is
/// false.
///
/// Idempotent and cheap enough for a frame boundary: a program that already has
/// a variant, has one in flight, or has already failed is not submitted again,
/// so the same condition is never retried frame after frame. The first call
/// after the user turns the setting on is what starts the one bounded
/// preparation the feature is allowed.
///
/// `cache_root` is this installation's regenerable shader cache. A variant
/// whose translation is already stored there is restored from it instead of
/// being compiled again, on this launch and on every later one. It is only ever
/// consulted for a program that was going to be prepared anyway: nothing is
/// read, warmed or written while the setting is off.
void RequestSceneMetalVariants(Scene& scene, bool wanted, std::string_view cache_root);

/// Drops everything queued that has not started yet.
///
/// A compile already running in the Rust shader compiler is not interrupted --
/// there is no way to interrupt it, and pretending otherwise would be a lie
/// about what the process is doing. It finishes, publishes its result onto the
/// program it was compiled for, and that program is then dropped with the scene
/// that owned it.
void CancelSceneMetalVariants();

/// Stops the worker. Called when the renderer shuts down; a compile in flight
/// is waited for, because it is writing into memory this process owns.
void ShutdownSceneMetalVariants();

/// How many variant compiles have finished, successfully or not. Diagnostic
/// only: no scheduling decision reads it.
[[nodiscard]] uint64_t SceneMetalVariantCompileCount();

} // namespace wallpaper
