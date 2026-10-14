#Test suite for wescene - renderer.
#
#Strategy : a single gtest binary indexes workshop/* once via DumpWorkshop
# (no on-disk fixtures) and uses TEST_P fixtures to register one test
# instance per (category, version) pair observed in the corpus. Each
# instance asserts category-specific structural invariants on the slice
# of assets matching its parameter.
#
# Adding a new workshop with a previously-unseen pkg/tex/mdl version
# automatically grows the test matrix on the next run — no allow-list
# bumps required, but the new instance must still satisfy the invariants
# in version_tests.cpp or it fails immediately.

include(FetchContent)

FetchContent_Declare(
    googletest
    GIT_REPOSITORY https://github.com/google/googletest.git
    GIT_TAG        v1.14.0
    GIT_SHALLOW    TRUE
)
set(BUILD_GMOCK OFF CACHE INTERNAL "")
set(INSTALL_GTEST OFF CACHE INTERNAL "")
FetchContent_MakeAvailable(googletest)
include(GoogleTest)

# Shared library for the dumper + corpus index. Used by the gtest binary
# and any future ad-hoc tools.
add_library(wpdump_lib STATIC dump.cpp corpus.cpp)
target_link_libraries(
    wpdump_lib
    PUBLIC
        ${PROJECT_NAME}
        wpFs
        wpScene
        nlohmann_json::nlohmann_json
)
target_include_directories(wpdump_lib PUBLIC .)
target_compile_features(wpdump_lib PUBLIC cxx_std_20)
target_compile_definitions(
    wpdump_lib PUBLIC
    "WAYWALLEN_WORKSHOP_DIR=\"${CMAKE_SOURCE_DIR}/workshop\""
    "WAYWALLEN_FIXTURE_DIR=\"${CMAKE_CURRENT_SOURCE_DIR}/fixtures\"")

add_executable(version_tests version_tests.cpp)
target_link_libraries(version_tests PRIVATE wpdump_lib GTest::gtest_main)

# The .tex fixtures this suite builds are lz4-compressed, and the renderer links
# lz4 privately, so the headers do not arrive with it.
pkg_check_modules(TEST_LZ4 REQUIRED IMPORTED_TARGET liblz4)
add_executable(tex_schema_tests tex_schema_tests.cpp)
target_link_libraries(tex_schema_tests PRIVATE ${PROJECT_NAME} wpFs wpScene PkgConfig::TEST_LZ4 GTest::gtest_main)
target_include_directories(tex_schema_tests PRIVATE .)
target_compile_features(tex_schema_tests PRIVATE cxx_std_20)
gtest_discover_tests(
    tex_schema_tests
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)

add_executable(scene_schema_tests scene_schema_tests.cpp)
target_link_libraries(scene_schema_tests PRIVATE ${PROJECT_NAME} wpAudio wpFs wpScene nlohmann_json::nlohmann_json GTest::gtest_main)
target_include_directories(scene_schema_tests PRIVATE .)
target_compile_features(scene_schema_tests PRIVATE cxx_std_20)
gtest_discover_tests(
    scene_schema_tests
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)

add_executable(mdl_schema_tests mdl_schema_tests.cpp)
target_link_libraries(mdl_schema_tests PRIVATE ${PROJECT_NAME} wpFs wpScene GTest::gtest_main)
target_include_directories(mdl_schema_tests PRIVATE .)
target_compile_features(mdl_schema_tests PRIVATE cxx_std_20)
gtest_discover_tests(
    mdl_schema_tests
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)

add_executable(scene_mesh_tests scene_mesh_tests.cpp)
target_link_libraries(scene_mesh_tests PRIVATE wpScene GTest::gtest_main)
target_include_directories(scene_mesh_tests PRIVATE . ${CMAKE_SOURCE_DIR}/src)
target_compile_features(scene_mesh_tests PRIVATE cxx_std_20)
gtest_discover_tests(
    scene_mesh_tests
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)

add_executable(sprite_animation_test sprite_animation_test.cpp)
target_link_libraries(sprite_animation_test PRIVATE wpScene GTest::gtest_main)
target_include_directories(sprite_animation_test PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_compile_features(sprite_animation_test PRIVATE cxx_std_20)
gtest_discover_tests(sprite_animation_test PROPERTIES TIMEOUT 30 DISCOVERY_TIMEOUT 60)

# CLI for fixture authoring: dumps a single workshop to a JSON file.
add_executable(wpdump wpdump_main.cpp)
target_link_libraries(wpdump PRIVATE wpdump_lib)

# Per-version deep tests live in tests/version/<category>_<version>_test.cpp.
# Each is a tiny gtest TU built into the same binary so the corpus + gtest
# fixture machinery is amortised across them.
file(GLOB version_test_srcs CONFIGURE_DEPENDS "version/*_test.cpp")
if(version_test_srcs)
    add_executable(deep_version_tests ${version_test_srcs})
    target_link_libraries(deep_version_tests PRIVATE wpdump_lib GTest::gtest_main)
    target_include_directories(deep_version_tests PRIVATE .)
endif()

# Use gtest_discover_tests so each TEST_P instance becomes its own ctest
# entry, runnable individually with `ctest -R ScenePkgVersionTest`.
add_executable(
    audio_tests
    audio/audio_response_mono_test.cpp
    audio/ffmpeg_sound_stream_test.cpp
    audio/audio_decode_pump_test.cpp
    fs/limited_binary_stream_test.cpp
    audio/sample_math_test.cpp
    audio/sound_layer_control_test.cpp
    audio/sound_output_lifecycle_test.cpp)
target_link_libraries(audio_tests PRIVATE ${PROJECT_NAME} wpAudio wpFs GTest::gtest_main)
target_include_directories(audio_tests PRIVATE . ${CMAKE_SOURCE_DIR}/src)
target_compile_features(audio_tests PRIVATE cxx_std_20)
gtest_discover_tests(
    audio_tests
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)
if(APPLE)
    add_executable(stb_image_regression_test stb_image_regression_test.mm)
    add_library(stb_scalar_test_decoder OBJECT stb_jpeg_variant.cpp)
    target_compile_definitions(stb_scalar_test_decoder PRIVATE STB_TEST_DECODE_NAME=stb_test_decode_scalar)
    add_library(stb_neon_test_decoder OBJECT stb_jpeg_variant.cpp)
    target_compile_definitions(stb_neon_test_decoder PRIVATE STB_TEST_DECODE_NAME=stb_test_decode_neon STB_TEST_USE_NEON=1)
    target_sources(stb_image_regression_test PRIVATE
        $<TARGET_OBJECTS:stb_scalar_test_decoder> $<TARGET_OBJECTS:stb_neon_test_decoder>)
    target_link_libraries(stb_image_regression_test PRIVATE GTest::gtest_main
        "-framework CoreGraphics" "-framework CoreFoundation" "-framework ImageIO")
    target_compile_features(stb_image_regression_test PRIVATE cxx_std_20)
    set_target_properties(stb_image_regression_test PROPERTIES OBJCXX_STANDARD 20 OBJCXX_STANDARD_REQUIRED YES)
    gtest_discover_tests(stb_image_regression_test PROPERTIES TIMEOUT 30 DISCOVERY_TIMEOUT 60)
    add_executable(playback_gpu_test playback_gpu_test.mm)
    target_link_libraries(playback_gpu_test PRIVATE
        ${PROJECT_NAME} wpScene wpVulkan wpVulkanRender wpRGraph
        nlohmann_json::nlohmann_json GTest::gtest_main)
    target_include_directories(playback_gpu_test PRIVATE
        . ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/src/Scene/VulkanRender)
    target_compile_features(playback_gpu_test PRIVATE cxx_std_20)
    set_target_properties(playback_gpu_test PROPERTIES
        OBJCXX_STANDARD 20 OBJCXX_STANDARD_REQUIRED YES)
    target_compile_options(playback_gpu_test PRIVATE $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
    gtest_discover_tests(playback_gpu_test PROPERTIES TIMEOUT 60 DISCOVERY_TIMEOUT 60)
    add_test(
        NAME audio_coreaudio_backend_config
        COMMAND
            ${CMAKE_COMMAND}
            -DHEADER=${CMAKE_SOURCE_DIR}/src/Audio/miniaudio-wrapper.hpp
            -P ${CMAKE_CURRENT_SOURCE_DIR}/audio/coreaudio_backend_config.cmake)
endif()
add_executable(shader_cache_metadata_test shader_cache_metadata_test.cpp)
target_link_libraries(shader_cache_metadata_test PRIVATE ${PROJECT_NAME} wpFs wpScene wpVulkan GTest::gtest_main)
target_include_directories(shader_cache_metadata_test PRIVATE .)
target_compile_features(shader_cache_metadata_test PRIVATE cxx_std_20)
gtest_discover_tests(
    shader_cache_metadata_test
    TEST_PREFIX shader_cache_metadata_test.
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)
add_executable(shader_preprocessor_compat_test shader_preprocessor_compat_test.cpp)
target_link_libraries(shader_preprocessor_compat_test PRIVATE ${PROJECT_NAME} wpFs wpScene wpVulkan GTest::gtest_main)
target_include_directories(shader_preprocessor_compat_test PRIVATE .)
target_compile_features(shader_preprocessor_compat_test PRIVATE cxx_std_20)
gtest_discover_tests(
    shader_preprocessor_compat_test
    TEST_PREFIX shader_preprocessor_compat_test.
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)

add_executable(rust_shader_bridge_test rust_shader_bridge_test.cpp)
target_link_libraries(
    rust_shader_bridge_test
    PRIVATE ${PROJECT_NAME} wpFs wpScene wpVulkan wpVulkanRender wpRGraph nlohmann_json::nlohmann_json GTest::gtest_main)
target_include_directories(rust_shader_bridge_test PRIVATE . ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/src/Scene/VulkanRender)
target_compile_features(rust_shader_bridge_test PRIVATE cxx_std_20)
if(DEFINED RUST_SHADER_STATICLIB AND NOT "${RUST_SHADER_STATICLIB}" STREQUAL "")
    target_link_libraries(rust_shader_bridge_test PRIVATE wescene_rust_shader)
endif()
gtest_discover_tests(
    rust_shader_bridge_test
    TEST_PREFIX rust_shader_bridge_test.
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)

add_executable(unpack_shader_compile_smoke unpack_shader_compile_smoke.cpp)
set(UNPACK_SHADER_COMPILE_SMOKE_CORPUS_ROOT
    "/Users/molyuu/Workspace/WallpaperEngine/unpack"
    CACHE PATH "Root directory containing unpacked Wallpaper Engine workshop scenes for shader smoke tests")
set(UNPACK_SHADER_COMPILE_SMOKE_COMMON_ASSETS
    "/Users/molyuu/Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets"
    CACHE PATH "Wallpaper Engine common assets directory for shader smoke tests")
target_link_libraries(
    unpack_shader_compile_smoke
    PRIVATE ${PROJECT_NAME} wpFs wpScene wpVulkan nlohmann_json::nlohmann_json GTest::gtest_main)
target_include_directories(unpack_shader_compile_smoke PRIVATE . ${CMAKE_SOURCE_DIR}/src)
target_compile_features(unpack_shader_compile_smoke PRIVATE cxx_std_20)
target_compile_definitions(
    unpack_shader_compile_smoke
    PRIVATE
        "UNPACK_SHADER_COMPILE_SMOKE_CORPUS_ROOT=\"${UNPACK_SHADER_COMPILE_SMOKE_CORPUS_ROOT}\""
        "UNPACK_SHADER_COMPILE_SMOKE_COMMON_ASSETS=\"${UNPACK_SHADER_COMPILE_SMOKE_COMMON_ASSETS}\"")
if(TARGET wescene_rust_shader)
    target_link_libraries(unpack_shader_compile_smoke PRIVATE wescene_rust_shader)
else()
    message(FATAL_ERROR
        "unpack_shader_compile_smoke requires the Rust shader static library target. "
        "Configure with -DRUST_SHADER_STATICLIB=<path-to-librust_shader.a>.")
endif()
gtest_discover_tests(
    unpack_shader_compile_smoke
    TEST_PREFIX unpack_shader_compile_smoke.
    PROPERTIES TIMEOUT 600
    DISCOVERY_TIMEOUT 120
)
add_executable(scenescript_sound_layer_smoke scenescript_sound_layer_smoke.cpp)
target_link_libraries(scenescript_sound_layer_smoke PRIVATE ${PROJECT_NAME} wpAudio wpScene nlohmann_json::nlohmann_json GTest::gtest_main)
target_include_directories(scenescript_sound_layer_smoke PRIVATE .)
target_compile_features(scenescript_sound_layer_smoke PRIVATE cxx_std_20)
gtest_discover_tests(
    scenescript_sound_layer_smoke
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)
add_executable(media_thumbnail_texture_smoke media_thumbnail_texture_smoke.cpp)
target_link_libraries(media_thumbnail_texture_smoke PRIVATE ${PROJECT_NAME} wpScene nlohmann_json::nlohmann_json GTest::gtest_main)
target_include_directories(media_thumbnail_texture_smoke PRIVATE .)
target_compile_features(media_thumbnail_texture_smoke PRIVATE cxx_std_20)
gtest_discover_tests(
    media_thumbnail_texture_smoke
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)
add_executable(scenescript_media_event_smoke scenescript_media_event_smoke.cpp)
target_link_libraries(scenescript_media_event_smoke PRIVATE ${PROJECT_NAME} wpScene nlohmann_json::nlohmann_json GTest::gtest_main)
target_include_directories(scenescript_media_event_smoke PRIVATE .)
target_compile_features(scenescript_media_event_smoke PRIVATE cxx_std_20)
gtest_discover_tests(
    scenescript_media_event_smoke
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)
add_executable(video_texture_submission_smoke video_texture_submission_smoke.cpp)
target_link_libraries(video_texture_submission_smoke PRIVATE wpVulkan GTest::gtest_main)
target_include_directories(video_texture_submission_smoke PRIVATE
    .
    ${CMAKE_SOURCE_DIR}/src
    ${CMAKE_SOURCE_DIR}/src/Vulkan/include
    ${CMAKE_SOURCE_DIR}/src/Utils/include
    ${CMAKE_SOURCE_DIR}/src/Scene/include
)
target_compile_features(video_texture_submission_smoke PRIVATE cxx_std_20)
gtest_discover_tests(
    video_texture_submission_smoke
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)
add_executable(script_runtime_compat_test script_runtime_compat_test.cpp)
target_link_libraries(script_runtime_compat_test PRIVATE ${PROJECT_NAME} wpScene wpFs wpVulkan nlohmann_json::nlohmann_json GTest::gtest_main)
target_include_directories(script_runtime_compat_test PRIVATE . ${CMAKE_SOURCE_DIR}/src)
target_compile_features(script_runtime_compat_test PRIVATE cxx_std_20)
gtest_discover_tests(
    script_runtime_compat_test
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)
# Explicit CLI diagnostic, not registered with ctest. Never creates a surface.
add_executable(render_target_lifetime_test render_target_lifetime_test.cpp)
target_link_libraries(render_target_lifetime_test PRIVATE ${PROJECT_NAME} wpScene wpVulkanRender wpVulkan wpRGraph nlohmann_json::nlohmann_json GTest::gtest_main)
target_include_directories(render_target_lifetime_test PRIVATE . ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/src/Scene/VulkanRender)
gtest_discover_tests(render_target_lifetime_test PROPERTIES TIMEOUT 30)

add_executable(offscreen_scene_probe offscreen_scene_probe.cpp)
target_link_libraries(offscreen_scene_probe PRIVATE ${PROJECT_NAME} wpAudio wpScene wpParticle wpFs wpVulkan wpVulkanRender wpRGraph nlohmann_json::nlohmann_json)
target_include_directories(offscreen_scene_probe PRIVATE . ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/src/Scene/VulkanRender)
target_compile_features(offscreen_scene_probe PRIVATE cxx_std_20)

# Explicit CLI diagnostic for cross-load state leaks, not registered with ctest.
add_executable(scene_reload_cycle_probe scene_reload_cycle_probe.cpp)
target_link_libraries(scene_reload_cycle_probe PRIVATE ${PROJECT_NAME} wpAudio wpScene wpParticle wpFs wpVulkan wpVulkanRender wpRGraph nlohmann_json::nlohmann_json)
target_include_directories(scene_reload_cycle_probe PRIVATE . ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/src/Scene/VulkanRender)
target_compile_features(scene_reload_cycle_probe PRIVATE cxx_std_20)

add_executable(text_object_runtime_test text_object_runtime_test.cpp)
target_link_libraries(text_object_runtime_test PRIVATE ${PROJECT_NAME} wpAudio wpScene wpFs wpVulkan wpVulkanRender wpRGraph nlohmann_json::nlohmann_json GTest::gtest_main)
target_include_directories(text_object_runtime_test PRIVATE . ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/src/Scene/VulkanRender)
target_compile_features(text_object_runtime_test PRIVATE cxx_std_20)
gtest_discover_tests(
    text_object_runtime_test
    TEST_PREFIX text_object_runtime_test.
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)
add_executable(mouse_input_test mouse_input_test.cpp)
target_link_libraries(mouse_input_test PRIVATE ${PROJECT_NAME} wpScene wpVulkan GTest::gtest_main)
target_include_directories(mouse_input_test PRIVATE . ${CMAKE_SOURCE_DIR}/src)
target_compile_features(mouse_input_test PRIVATE cxx_std_20)
gtest_discover_tests(
    mouse_input_test
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)
add_executable(wallpaper_scaling_test wallpaper_scaling_test.cpp)
target_link_libraries(wallpaper_scaling_test PRIVATE ${PROJECT_NAME} wpScene wpVulkan GTest::gtest_main)
target_include_directories(wallpaper_scaling_test PRIVATE . ${CMAKE_SOURCE_DIR}/src)
target_compile_features(wallpaper_scaling_test PRIVATE cxx_std_20)
gtest_discover_tests(
    wallpaper_scaling_test
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)
add_executable(particle_mouse_controlpoint_test particle_mouse_controlpoint_test.cpp)
target_link_libraries(particle_mouse_controlpoint_test PRIVATE ${PROJECT_NAME} wpScene wpParticle wpAudio nlohmann_json::nlohmann_json GTest::gtest_main)
target_include_directories(particle_mouse_controlpoint_test PRIVATE .)
target_compile_features(particle_mouse_controlpoint_test PRIVATE cxx_std_20)
gtest_discover_tests(
    particle_mouse_controlpoint_test
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)
add_executable(particle_rope_geometry_test particle_rope_geometry_test.cpp)
target_link_libraries(particle_rope_geometry_test PRIVATE ${PROJECT_NAME} wpScene wpParticle wpAudio nlohmann_json::nlohmann_json GTest::gtest_main)
target_include_directories(particle_rope_geometry_test PRIVATE .)
target_compile_features(particle_rope_geometry_test PRIVATE cxx_std_20)
gtest_discover_tests(
    particle_rope_geometry_test
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)
add_executable(layer_texture_reference_test layer_texture_reference_test.cpp)
target_link_libraries(layer_texture_reference_test PRIVATE ${PROJECT_NAME} wpVulkanRender wpVulkan wpRGraph wpScene wpAudio wpFs nlohmann_json::nlohmann_json GTest::gtest_main)
target_include_directories(layer_texture_reference_test PRIVATE . ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/src/Scene/VulkanRender ${CMAKE_SOURCE_DIR}/src/Scene/RenderGraph/include)
target_compile_features(layer_texture_reference_test PRIVATE cxx_std_20)
gtest_discover_tests(
    layer_texture_reference_test
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)
add_executable(project_property_preview_test project_property_preview_test.cpp)
target_link_libraries(project_property_preview_test PRIVATE ${PROJECT_NAME} wpVulkanRender wpVulkan wpRGraph wpScene wpAudio wpFs nlohmann_json::nlohmann_json GTest::gtest_main)
target_include_directories(project_property_preview_test PRIVATE . ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/src/Scene/VulkanRender ${CMAKE_SOURCE_DIR}/src/Scene/RenderGraph/include)
target_compile_features(project_property_preview_test PRIVATE cxx_std_20)
gtest_discover_tests(
    project_property_preview_test
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)
add_executable(vulkan_render_batch_planner_smoke vulkan_render_batch_planner_smoke.cpp)
target_link_libraries(vulkan_render_batch_planner_smoke PRIVATE wpVulkanRender wpVulkan)
target_include_directories(vulkan_render_batch_planner_smoke PRIVATE .)
target_compile_features(vulkan_render_batch_planner_smoke PRIVATE cxx_std_20)
target_compile_options(vulkan_render_batch_planner_smoke PRIVATE -UNDEBUG)
add_test(NAME vulkan_render_batch_planner_smoke COMMAND vulkan_render_batch_planner_smoke)
add_executable(vulkan_sample_count_smoke vulkan_sample_count_smoke.cpp)
target_link_libraries(vulkan_sample_count_smoke PRIVATE ${PROJECT_NAME} wpVulkanRender wpVulkan wpScene wpRGraph GTest::gtest_main)
target_include_directories(vulkan_sample_count_smoke PRIVATE
    .
    ${CMAKE_SOURCE_DIR}/src
    ${CMAKE_SOURCE_DIR}/src/Vulkan/include
    ${CMAKE_SOURCE_DIR}/src/Scene/RenderGraph/include
    ${CMAKE_SOURCE_DIR}/src/Scene/VulkanRender
    ${CMAKE_SOURCE_DIR}/src/Scene/VulkanRender/include
    ${CMAKE_SOURCE_DIR}/src/Utils/include
    ${CMAKE_SOURCE_DIR}/src/Scene/include
)
target_compile_features(vulkan_sample_count_smoke PRIVATE cxx_std_20)
add_test(NAME vulkan_sample_count_smoke COMMAND vulkan_sample_count_smoke)
add_executable(rendergraph_smoke rendergraph_smoke.cpp)
target_link_libraries(rendergraph_smoke PRIVATE ${PROJECT_NAME} wpVulkanRender wpVulkan wpRGraph wpScene wpAudio wpFs GTest::gtest_main)
target_include_directories(rendergraph_smoke PRIVATE . ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/src/Scene/VulkanRender)
target_compile_features(rendergraph_smoke PRIVATE cxx_std_20)
add_test(NAME rendergraph_smoke COMMAND rendergraph_smoke)
# The decode pump is codec-agnostic on purpose, so its state machine is tested
# without linking FFmpeg or opening a real stream.
add_executable(video_decode_pump_test
    video_decode_pump_test.cpp
    ${CMAKE_SOURCE_DIR}/src/Video/VideoDecodePump.cpp)
target_link_libraries(video_decode_pump_test PRIVATE GTest::gtest_main)
target_include_directories(video_decode_pump_test PRIVATE . ${CMAKE_SOURCE_DIR}/src)
target_compile_features(video_decode_pump_test PRIVATE cxx_std_20)
gtest_discover_tests(
    video_decode_pump_test
    TEST_PREFIX video_decode_pump_test.
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)

# Color conversion is pure arithmetic, so its known-pixel regressions need no
# GPU, no codec and no surface.
add_executable(video_color_conversion_test
    video_color_conversion_test.cpp
    ${CMAKE_SOURCE_DIR}/src/Video/VideoColorConversion.cpp)
target_link_libraries(video_color_conversion_test PRIVATE GTest::gtest_main)
target_include_directories(video_color_conversion_test PRIVATE . ${CMAKE_SOURCE_DIR}/src)
target_compile_features(video_color_conversion_test PRIVATE cxx_std_20)
gtest_discover_tests(
    video_color_conversion_test
    TEST_PREFIX video_color_conversion_test.
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)

# Frame pacing decides how often the clock has to wake for video content. The
# arithmetic and its evidence rules are independent of FFmpeg and the GPU, so
# the counter-examples run headless.
add_executable(video_frame_pacing_test
    video_frame_pacing_test.cpp
    ${CMAKE_SOURCE_DIR}/src/Video/VideoFramePacing.cpp)
target_link_libraries(video_frame_pacing_test PRIVATE GTest::gtest_main)
target_include_directories(video_frame_pacing_test PRIVATE . ${CMAKE_SOURCE_DIR}/src)
target_compile_features(video_frame_pacing_test PRIVATE cxx_std_20)
gtest_discover_tests(
    video_frame_pacing_test
    TEST_PREFIX video_frame_pacing_test.
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)

# What a surface says about its own frame loop. Header-only atomics with the
# clock passed in, so the counter-examples need no device, no renderer and no
# wall-clock wait.
add_executable(surface_health_test surface_health_test.cpp)
target_link_libraries(surface_health_test PRIVATE GTest::gtest_main)
target_include_directories(surface_health_test PRIVATE . ${CMAKE_SOURCE_DIR}/src)
target_compile_features(surface_health_test PRIVATE cxx_std_20)
gtest_discover_tests(
    surface_health_test
    TEST_PREFIX surface_health_test.
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)

# Conversion-destination budgeting is slot arithmetic, admission and an
# exhaustion policy over opaque handles, so its counter-examples need neither a
# Metal device nor a decoder.
add_executable(video_conversion_budget_test
    video_conversion_budget_test.cpp
    ${CMAKE_SOURCE_DIR}/src/Video/VideoConversionBudget.cpp)
target_link_libraries(video_conversion_budget_test PRIVATE GTest::gtest_main)
target_include_directories(video_conversion_budget_test PRIVATE . ${CMAKE_SOURCE_DIR}/src)
target_compile_features(video_conversion_budget_test PRIVATE cxx_std_20)
gtest_discover_tests(
    video_conversion_budget_test
    TEST_PREFIX video_conversion_budget_test.
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)

# A pure-video wallpaper's media is decode input, not a payload. The test drives
# the real construction path against media it encodes itself, so it links the
# renderer and FFmpeg rather than standing in a fake source.
pkg_check_modules(TEST_AVFORMAT REQUIRED IMPORTED_TARGET libavformat)
pkg_check_modules(TEST_AVCODEC REQUIRED IMPORTED_TARGET libavcodec)
pkg_check_modules(TEST_AVUTIL REQUIRED IMPORTED_TARGET libavutil)
if(APPLE)
    target_sources(playback_gpu_test PRIVATE apple_video_frame_test.mm)
    target_link_libraries(playback_gpu_test PRIVATE PkgConfig::TEST_AVUTIL)
    wescene_prefer_ffmpeg_headers(playback_gpu_test "TEST_")
endif()
add_executable(video_source_input_test video_source_input_test.cpp)
target_link_libraries(video_source_input_test PRIVATE ${PROJECT_NAME}
    PkgConfig::TEST_AVFORMAT PkgConfig::TEST_AVCODEC PkgConfig::TEST_AVUTIL GTest::gtest_main)
target_include_directories(video_source_input_test PRIVATE
    . ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/src/Scene/include)
wescene_prefer_ffmpeg_headers(video_source_input_test "TEST_")
target_compile_features(video_source_input_test PRIVATE cxx_std_20)
gtest_discover_tests(
    video_source_input_test
    TEST_PREFIX video_source_input_test.
    PROPERTIES TIMEOUT 120
    DISCOVERY_TIMEOUT 60
)

# One decoder serving several surfaces. Driven against media the test encodes,
# for the same reason as video_source_input_test: the thing under test is the
# real decoder's lifetime and frame ownership, which a fake source cannot show.
add_executable(shared_video_session_test shared_video_session_test.cpp)
target_link_libraries(shared_video_session_test PRIVATE ${PROJECT_NAME}
    PkgConfig::TEST_AVFORMAT PkgConfig::TEST_AVCODEC PkgConfig::TEST_AVUTIL GTest::gtest_main)
target_include_directories(shared_video_session_test PRIVATE
    . ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/src/Scene/include)
wescene_prefer_ffmpeg_headers(shared_video_session_test "TEST_")
target_compile_features(shared_video_session_test PRIVATE cxx_std_20)
gtest_discover_tests(
    shared_video_session_test
    TEST_PREFIX shared_video_session_test.
    PROPERTIES TIMEOUT 120
    DISCOVERY_TIMEOUT 60
)

# A frame that would repeat the picture already on the surface is not drawn,
# submitted or presented. Driven through the whole scene wallpaper on a Metal
# layer no window owns, against media the test encodes.
if(APPLE)
    add_executable(unchanged_present_test unchanged_present_test.mm)
    target_link_libraries(unchanged_present_test PRIVATE ${PROJECT_NAME}
        wpScene wpVulkan wpVulkanRender wpRGraph
        PkgConfig::TEST_AVFORMAT PkgConfig::TEST_AVCODEC PkgConfig::TEST_AVUTIL GTest::gtest_main)
    target_include_directories(unchanged_present_test PRIVATE
        . ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/src/Scene/include
        ${CMAKE_SOURCE_DIR}/src/Scene/VulkanRender/include)
    wescene_prefer_ffmpeg_headers(unchanged_present_test "TEST_")
    target_compile_features(unchanged_present_test PRIVATE cxx_std_20)
    set_target_properties(unchanged_present_test PROPERTIES
        OBJCXX_STANDARD 20 OBJCXX_STANDARD_REQUIRED YES)
    target_compile_options(unchanged_present_test PRIVATE
        $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
    gtest_discover_tests(unchanged_present_test PROPERTIES TIMEOUT 120 DISCOVERY_TIMEOUT 60)
endif()

# Render-target sizing only: no device, no surface, no GPU.
add_executable(render_scale_test render_scale_test.cpp)
target_link_libraries(render_scale_test PRIVATE ${PROJECT_NAME} wpScene wpVulkanRender wpVulkan wpRGraph nlohmann_json::nlohmann_json GTest::gtest_main)
target_include_directories(render_scale_test PRIVATE
    . ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/src/Scene/VulkanRender)
target_compile_features(render_scale_test PRIVATE cxx_std_20)
gtest_discover_tests(
    render_scale_test
    TEST_PREFIX render_scale_test.
    PROPERTIES TIMEOUT 60
    DISCOVERY_TIMEOUT 60
)

# Pure analysis: no device, no surface, no GPU.
add_executable(static_subgraph_cache_test static_subgraph_cache_test.cpp)
target_link_libraries(static_subgraph_cache_test PRIVATE wpVulkanRender wpVulkan wpScene wpRGraph nlohmann_json::nlohmann_json GTest::gtest_main)
target_include_directories(static_subgraph_cache_test PRIVATE
    . ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/src/Scene/VulkanRender/include)
target_compile_features(static_subgraph_cache_test PRIVATE cxx_std_20)
gtest_discover_tests(
    static_subgraph_cache_test
    TEST_PREFIX static_subgraph_cache_test.
    PROPERTIES TIMEOUT 60
    DISCOVERY_TIMEOUT 60
)

# Threads and a fake parser only: no device, no surface, no GPU.
add_executable(texture_prefetch_test texture_prefetch_test.cpp)
target_link_libraries(texture_prefetch_test PRIVATE ${PROJECT_NAME} wpVulkanRender wpVulkan wpRGraph wpScene wpAudio wpFs nlohmann_json::nlohmann_json GTest::gtest_main)
target_include_directories(texture_prefetch_test PRIVATE
    . ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/src/Scene/VulkanRender)
target_compile_features(texture_prefetch_test PRIVATE cxx_std_20)
gtest_discover_tests(
    texture_prefetch_test
    TEST_PREFIX texture_prefetch_test.
    PROPERTIES TIMEOUT 60
    DISCOVERY_TIMEOUT 60
)

add_executable(timer_tests timer/frame_timer_test.cpp)
target_link_libraries(timer_tests PRIVATE wpTimer GTest::gtest_main)
target_include_directories(timer_tests PRIVATE . ${CMAKE_SOURCE_DIR}/src)
target_compile_features(timer_tests PRIVATE cxx_std_20)
gtest_discover_tests(
    timer_tests
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)
#gtest_discover_tests(
#    version_tests
#    PROPERTIES TIMEOUT 30
#    DISCOVERY_TIMEOUT 60
#)
if(TARGET deep_version_tests)
    gtest_discover_tests(
        deep_version_tests
        PROPERTIES TIMEOUT 30
        DISCOVERY_TIMEOUT 60
    )
endif()

# Native Metal backend: capability gate, blend mapping, clip-space derivation
# and pipeline cache keys. No device needed for any of it; the one
# device-backed check skips visibly when no Metal device is present.
add_executable(metal_backend_test metal_backend_test.cpp)
target_link_libraries(metal_backend_test PRIVATE
    ${PROJECT_NAME} wpMetalRender wpVulkanRender wpVulkan wpScene wpRGraph wpParticle
    nlohmann_json::nlohmann_json GTest::gtest_main)
target_include_directories(metal_backend_test PRIVATE
    . ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/src/Scene/MetalRender/include)
target_compile_features(metal_backend_test PRIVATE cxx_std_20)
gtest_discover_tests(
    metal_backend_test
    TEST_PREFIX metal_backend_test.
    PROPERTIES TIMEOUT 60
    DISCOVERY_TIMEOUT 60
)

if(APPLE)
  # The first thing to feed translated Metal Shading Language to the Metal
  # compiler, and the first to draw an author layer with a render command
  # encoder. Creates only private textures and an offscreen layer.
  add_executable(metal_scene_draw_smoke metal_scene_draw_smoke.mm)
  target_link_libraries(metal_scene_draw_smoke PRIVATE
      ${PROJECT_NAME} wpMetalRender wpVulkanRender wpVulkan wpScene wpRGraph
      wpParticle wpAudio wpFs nlohmann_json::nlohmann_json GTest::gtest_main
      # The video-layer case needs a real decodable file, which the test
      # encodes for itself rather than shipping one.
      PkgConfig::TEST_AVFORMAT PkgConfig::TEST_AVCODEC PkgConfig::TEST_AVUTIL)
  target_include_directories(metal_scene_draw_smoke PRIVATE
      . ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/src/Scene/MetalRender/include
      ${CMAKE_SOURCE_DIR}/src/Scene/VulkanRender)
  wescene_prefer_ffmpeg_headers(metal_scene_draw_smoke "TEST_")
  target_compile_features(metal_scene_draw_smoke PRIVATE cxx_std_20)
  set_target_properties(metal_scene_draw_smoke PROPERTIES
      OBJCXX_STANDARD 20 OBJCXX_STANDARD_REQUIRED YES)
  target_compile_options(metal_scene_draw_smoke PRIVATE
      $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
  if(TARGET wescene_rust_shader)
      target_link_libraries(metal_scene_draw_smoke PRIVATE wescene_rust_shader)
  endif()
  gtest_discover_tests(
      metal_scene_draw_smoke
      TEST_PREFIX metal_scene_draw_smoke.
      PROPERTIES TIMEOUT 120
      DISCOVERY_TIMEOUT 60
  )

  # Desktop poster capture and scene video textures for the native backend.
  # Both draw into private offscreen textures only: no layer, no drawable.
  foreach(metal_module_test metal_poster_capture_test metal_video_texture_test)
    add_executable(${metal_module_test} ${metal_module_test}.mm)
    target_link_libraries(${metal_module_test} PRIVATE
        ${PROJECT_NAME} wpMetalRender wpVulkanRender wpVulkan wpScene wpRGraph
        wpParticle wpAudio wpFs nlohmann_json::nlohmann_json GTest::gtest_main
        ${METAL_FRAMEWORK} ${CORE_VIDEO_FRAMEWORK} ${IOSURFACE_FRAMEWORK}
        ${FOUNDATION_FRAMEWORK})
    target_include_directories(${metal_module_test} PRIVATE
        . ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/src/Scene/MetalRender
        ${CMAKE_SOURCE_DIR}/src/Scene/MetalRender/include)
    target_compile_features(${metal_module_test} PRIVATE cxx_std_20)
    set_target_properties(${metal_module_test} PROPERTIES
        OBJCXX_STANDARD 20 OBJCXX_STANDARD_REQUIRED YES)
    target_compile_options(${metal_module_test} PRIVATE
        $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
    if(TARGET wescene_rust_shader)
        target_link_libraries(${metal_module_test} PRIVATE wescene_rust_shader)
    endif()
    gtest_discover_tests(
        ${metal_module_test}
        TEST_PREFIX ${metal_module_test}.
        PROPERTIES TIMEOUT 120
        DISCOVERY_TIMEOUT 60
    )
  endforeach()
endif()

# Standalone miniaudio implementation with controlled CoreAudio/backend failures.
# This target never opens a real audio context or links the renderer's audio unit.
if(APPLE)
  add_executable(miniaudio_failure_paths_test miniaudio_failure_paths_test.cpp)
  target_include_directories(miniaudio_failure_paths_test PRIVATE ${CMAKE_SOURCE_DIR}/third_party)
  target_link_libraries(miniaudio_failure_paths_test PRIVATE GTest::gtest_main)
  target_compile_features(miniaudio_failure_paths_test PRIVATE cxx_std_20)
  gtest_discover_tests(miniaudio_failure_paths_test
      TEST_PREFIX miniaudio_failure_paths_test.
      PROPERTIES TIMEOUT 30
      DISCOVERY_TIMEOUT 30)
endif()
