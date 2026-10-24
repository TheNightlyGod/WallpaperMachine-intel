find_package(OpenGL REQUIRED)
find_package(Threads REQUIRED)
find_package(Freetype REQUIRED)
pkg_check_modules(LZ4 REQUIRED IMPORTED_TARGET liblz4)

include(TestBigEndian)
test_big_endian(ENDIAN)
if(ENDIAN)
  add_compile_definitions(WP_BIG_ENDIAN)
endif()

if(APPLE)
  # Each entry is <VARIABLE stem>:<framework>; the cache variable is <stem>_FRAMEWORK.
  foreach(entry
          ACCELERATE:Accelerate AUDIO_TOOLBOX:AudioToolbox AUDIO_UNIT:AudioUnit
          CORE_AUDIO:CoreAudio CORE_TEXT:CoreText CORE_GRAPHICS:CoreGraphics
          CORE_MEDIA:CoreMedia CORE_VIDEO:CoreVideo FOUNDATION:Foundation
          IOSURFACE:IOSurface METAL:Metal QUARTZ_CORE:QuartzCore
          VIDEOTOOLBOX:VideoToolbox)
    string(REPLACE ":" ";" entry_parts "${entry}")
    list(GET entry_parts 0 framework_stem)
    list(GET entry_parts 1 framework_name)
    find_library(${framework_stem}_FRAMEWORK ${framework_name} REQUIRED)
  endforeach()
endif()

set(warn_opts
    -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion -Wno-unused-variable
    # A command posted to a looper handler and missing from its switch compiles,
    # links, runs and does nothing: `CMD_SET_RENDER_SCALE` reached no handler
    # from the day it was added. The handler switches carry no `default`, so
    # this promotes exactly that omission to a build failure without promoting
    # unrelated warnings.
    -Werror=switch
    CACHE INTERNAL "")

include_directories(.)

set(PLATFORM_APPLE_SOURCES)
if(APPLE)
  list(APPEND PLATFORM_APPLE_SOURCES
       Platform/Apple/VideoFrameInterop.mm
       Platform/Apple/SceneWallpaperBindings.mm)
endif()

add_subdirectory(Fs)
add_subdirectory(Utils)
add_subdirectory(Audio)
add_subdirectory(Scene)
add_subdirectory(Looper)
add_subdirectory(Scene/Timer)
add_subdirectory(Scene/Particle)
add_subdirectory(Scene/RenderGraph)
add_subdirectory(Scene/RenderCommon)
add_subdirectory(Scene/MetalRender)

# Runtime, scripting, shader bridge and scene-parsing sources of the engine library.
set(WESCENE_CORE_SOURCES
  Runtime/SceneRuntimeContext.cpp Runtime/SceneSettingResolver.cpp Runtime/ScriptedDynamicValue.cpp
  Runtime/VirtualAssetRegistry.cpp
  Shader/RustShaderBridge.cpp Shader/SceneMetalVariants.cpp
  Text/SystemFontResolver.cpp Text/TextLayer.cpp
  Scripting/ScriptEngine.cpp Scripting/ScriptModuleSyntax.cpp
  Project/ProjectManifest.cpp Project/ProjectProperties.cpp
  Scene/SceneLayerReference.cpp Scene/WPShaderValueUpdater.cpp
  Scene/Parse/WPParticleParser.cpp Scene/Parse/WPShaderParser.cpp Scene/Parse/WPSceneParser.cpp
  Scene/Parse/WPTexImageParser.cpp Scene/Parse/WPVideoCache.cpp Scene/Parse/WPSoundParser.cpp
  Scene/Parse/WPMdlParser.cpp Scene/Parse/WPPuppet.cpp
  Scene/Parse/wpscene/WPImageObject.cpp Scene/Parse/wpscene/WPParticleObject.cpp
  Scene/Parse/wpscene/WPMaterial.cpp Scene/Parse/wpscene/WPScene.cpp
  Scene/Parse/wpscene/WPLightObject.cpp)

add_library(
  ${PROJECT_NAME} STATIC
  Scene/WPJson.cpp
  Scene/WPPkgFs.cpp
  Type.cpp
  Runtime/CameraPath.cpp
  Runtime/DynamicValue.cpp
  ${WESCENE_CORE_SOURCES}
  Video/ClockedVideoSource.cpp
  Video/VideoColorConversion.cpp
  Video/VideoContainerProbe.cpp
  Video/VideoDecodePump.cpp
  Video/VideoFramePacing.cpp
  Video/VideoMedia.cpp
  Video/NativeVideoBackend.cpp
  Video/VideoTextureSourceFactory.cpp
  ${PLATFORM_APPLE_SOURCES}
  SceneSourceResolver.cpp
  Scene/SceneWallpaper.cpp)

add_library(wescene::renderer ALIAS ${PROJECT_NAME})

# This target owns the looper handlers. Their switches carry no `default`, so a
# command that is posted and never dispatched — which is what happened to
# `CMD_SET_RENDER_SCALE` from the day it was added — stops the build instead of
# adding one more warning line nobody reads. Only this class is promoted; the
# rest of `warn_opts` is deliberately not applied to this target.
target_compile_options(${PROJECT_NAME} PRIVATE -Werror=switch)

set(InteralLib
    wpAudio
    wpLooper
    wpMetalRender
    wpRenderCommon
    wpFs
    wpScene
    wpRGraph
    wpParticle
    wpTimer)

# This project's own container readers (Renderer/Media), added by the top-level
# CMakeLists.txt from the repository checkout the engine now depends on.
if(NOT TARGET wmMedia)
  message(FATAL_ERROR "wescene-renderer needs Renderer/Media (target wmMedia): "
                      "configure it from a full WallpaperMachine checkout")
endif()
set(WESCENE_MEDIA_LIBS wmMedia)
if(APPLE)
  # The VideoToolbox layer of the same readers: format descriptions and a
  # decoder the native video backend plays through.
  if(NOT TARGET wmMediaApple)
    message(FATAL_ERROR "wescene-renderer needs Renderer/Media/Apple (target wmMediaApple)")
  endif()
  list(APPEND WESCENE_MEDIA_LIBS wmMediaApple)
endif()

# The still preview a wallpaper that cannot be drawn shows (Renderer/Surface).
if(NOT TARGET wmSurface)
  message(FATAL_ERROR "wescene-renderer needs Renderer/Surface (target wmSurface): "
                      "configure it from a full WallpaperMachine checkout")
endif()

target_link_libraries(
  ${PROJECT_NAME}
  PUBLIC wpUtils
  PRIVATE ${InteralLib} ${WESCENE_MEDIA_LIBS} wmSurface nlohmann_json::nlohmann_json quickjs::quickjs PkgConfig::LZ4
          Freetype::Freetype
          ${CMAKE_THREAD_LIBS_INIT} ${CMAKE_DL_LIBS})

if(APPLE)
  target_link_libraries(
    ${PROJECT_NAME}
    PUBLIC
      ${CORE_AUDIO_FRAMEWORK}
      ${AUDIO_TOOLBOX_FRAMEWORK}
      ${AUDIO_UNIT_FRAMEWORK}
      ${CORE_MEDIA_FRAMEWORK}
      ${CORE_TEXT_FRAMEWORK}
      ${CORE_VIDEO_FRAMEWORK}
      ${ACCELERATE_FRAMEWORK}
      ${FOUNDATION_FRAMEWORK}
      ${IOSURFACE_FRAMEWORK}
      ${METAL_FRAMEWORK}
      ${VIDEOTOOLBOX_FRAMEWORK})
endif()

target_include_directories(${PROJECT_NAME} PUBLIC .)
set_target_properties(${PROJECT_NAME} PROPERTIES OBJCXX_STANDARD 20 OBJCXX_STANDARD_REQUIRED YES
                                                  POSITION_INDEPENDENT_CODE ON)
# ARC applies to Objective-C++ translation units only.
target_compile_options(${PROJECT_NAME} PRIVATE "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>")

if(BUILD_TESTS)
  # Test binaries see the test-only declarations (e.g. CompileRustShaderProgramWithBridgeJson).
  target_compile_definitions(${PROJECT_NAME} PUBLIC WESCENE_BUILD_TESTS=1)
endif()
if(RUST_SHADER_FFI)
  target_compile_definitions(${PROJECT_NAME} PUBLIC WESCENE_HAS_RUST_SHADER_FFI=1)
endif()
if(TARGET wescene_rust_shader)
  target_link_libraries(${PROJECT_NAME} PUBLIC wescene_rust_shader)
endif()
