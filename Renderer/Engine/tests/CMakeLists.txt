# Test suite for wescene - renderer: one gtest executable per area, registered in
# scripts/check_renderer.py (REGRESSION_BINARIES).

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

# Containers, pictures, packages and scene sources built byte by byte (tex_fixtures.hpp).
add_executable(tex_container_tests tex_container_tests.cpp)
target_link_libraries(tex_container_tests PRIVATE ${PROJECT_NAME} wpFs wpScene PkgConfig::TEST_LZ4 GTest::gtest_main)
target_include_directories(tex_container_tests PRIVATE .)
target_compile_features(tex_container_tests PRIVATE cxx_std_20)
gtest_discover_tests(
    tex_container_tests
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)

# utils_known_answer_tests.cpp pins outputs of the utils the scene engine relies on bit for bit.
# linalg_tests.cpp does the same for Utils/Linalg.hpp (against linalg_golden.inc, and the
# behaviour its call sites rely on).
add_executable(scene_schema_tests scene_schema_tests.cpp utils_known_answer_tests.cpp
                                  linalg_tests.cpp material_contract_synthetic_tests.cpp)
target_link_libraries(scene_schema_tests PRIVATE ${PROJECT_NAME} wpAudio wpFs wpScene wpParticle nlohmann_json::nlohmann_json GTest::gtest_main)
target_include_directories(scene_schema_tests PRIVATE . ../src/Scene/RenderCommon/include)
target_compile_features(scene_schema_tests PRIVATE cxx_std_20)
gtest_discover_tests(
    scene_schema_tests
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)

# Scene-schema behaviour tests (the replacement for the tests that used to live in
# scene_schema_tests.cpp). Convention: every part of the study has its OWN executable,
# scene_schema_partNN_test, built from its own source file(s) and linked against the shared
# fixture library below (support/schema_fixtures.hpp). A part adds exactly one
# add_scene_schema_behavior_test() line to the list and one name to the registry at the top of
# scripts/check_renderer.py; it never edits another part's source or the support library.
add_library(scene_schema_support STATIC support/schema_fixtures.cpp)
target_link_libraries(scene_schema_support PUBLIC ${PROJECT_NAME} wpAudio wpFs wpScene wpParticle nlohmann_json::nlohmann_json)
target_include_directories(scene_schema_support PUBLIC . ../src/Scene/RenderCommon/include)
target_compile_features(scene_schema_support PUBLIC cxx_std_20)
function(add_scene_schema_behavior_test name)
    add_executable(${name} ${ARGN})
    target_link_libraries(${name} PRIVATE scene_schema_support GTest::gtest_main)
    gtest_discover_tests(${name} PROPERTIES TIMEOUT 30 DISCOVERY_TIMEOUT 60)
endfunction()
# --- append one line per part below -------------------------------------------------------
add_scene_schema_behavior_test(scene_schema_fixtures_selftest schema_fixtures_selftest.cpp)
add_scene_schema_behavior_test(scene_schema_part01_test
    scene_schema_part01_general_test.cpp
    scene_schema_part01_objects_test.cpp
    scene_schema_part01_model_layers_test.cpp
    scene_schema_part01_cameras_test.cpp)
add_scene_schema_behavior_test(scene_schema_part02_test
    scene_schema_part02_shots_test.cpp
    scene_schema_part02_lights_test.cpp
    scene_schema_part02_materials_test.cpp
    scene_schema_part02_graph_test.cpp)
add_scene_schema_behavior_test(scene_schema_part03_test
    scene_schema_part03_layout_test.cpp
    scene_schema_part03_tint_test.cpp)
add_scene_schema_behavior_test(scene_schema_part04_test
    scene_schema_part04_effects_test.cpp
    scene_schema_part04_cards_test.cpp
    scene_schema_part04_names_test.cpp)
add_scene_schema_behavior_test(scene_schema_part05_test scene_schema_part05_test.cpp)
add_scene_schema_behavior_test(scene_schema_part06_test scene_schema_part06_test.cpp)
add_scene_schema_behavior_test(scene_schema_part07_test scene_schema_part07_test.cpp)
add_scene_schema_behavior_test(scene_schema_part08_test scene_schema_part08_test.cpp)
add_scene_schema_behavior_test(scene_schema_part09_test
    scene_schema_part09_nodes_test.cpp
    scene_schema_part09_layers_test.cpp)
add_scene_schema_behavior_test(scene_schema_part10_test
    scene_schema_part10_colour_test.cpp
    scene_schema_part10_settings_test.cpp
    scene_schema_part10_camera_test.cpp
    scene_schema_part10_vector_test.cpp)
add_scene_schema_behavior_test(scene_schema_part11_test
    scene_schema_part11_timelines_test.cpp
    scene_schema_part11_audio_test.cpp)
# ------------------------------------------------------------------------------------------

add_executable(mdl_schema_tests mdl_schema_tests.cpp)
target_link_libraries(mdl_schema_tests PRIVATE ${PROJECT_NAME} wpFs wpScene GTest::gtest_main)
target_include_directories(mdl_schema_tests PRIVATE .)
target_compile_features(mdl_schema_tests PRIVATE cxx_std_20)
gtest_discover_tests(
    mdl_schema_tests
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)

# Model files built byte by byte (mdl_fixtures.hpp): mesh records, skeleton, optional blocks and the
# geometry generated from them.
add_executable(mdl_parse_tests mdl_mesh_tests.cpp mdl_skeleton_tests.cpp)
target_link_libraries(mdl_parse_tests PRIVATE ${PROJECT_NAME} wpFs wpScene GTest::gtest_main)
target_include_directories(mdl_parse_tests PRIVATE .)
target_compile_features(mdl_parse_tests PRIVATE cxx_std_20)
gtest_discover_tests(
    mdl_parse_tests
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)

# In-memory puppets: layer sampling, blending, playback controls and shared state.
add_executable(puppet_pose_tests puppet_pose_tests.cpp)
target_link_libraries(puppet_pose_tests PRIVATE ${PROJECT_NAME} wpFs wpScene GTest::gtest_main)
target_include_directories(puppet_pose_tests PRIVATE .)
target_compile_features(puppet_pose_tests PRIVATE cxx_std_20)
gtest_discover_tests(
    puppet_pose_tests
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)

add_executable(scene_mesh_tests scene_mesh_tests.cpp mesh_contract_tests.cpp)
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

# A headless gtest executable in one call: `name` is built from SOURCES, linked with LIBS (and
# gtest_main), sees INCLUDES, and every discovered test gets TIMEOUT seconds. PREFIX, when
# given, is put in front of the discovered test names.
function(wm_gtest_executable name)
    cmake_parse_arguments(WM "" "TIMEOUT;PREFIX" "SOURCES;LIBS;INCLUDES" ${ARGN})
    add_executable(${name} ${WM_SOURCES})
    target_link_libraries(${name} PRIVATE ${WM_LIBS} GTest::gtest_main)
    target_include_directories(${name} PRIVATE ${WM_INCLUDES})
    target_compile_features(${name} PRIVATE cxx_std_20)
    set(discover_prefix "")
    if(WM_PREFIX)
        set(discover_prefix TEST_PREFIX ${WM_PREFIX})
    endif()
    gtest_discover_tests(${name} ${discover_prefix}
        PROPERTIES TIMEOUT ${WM_TIMEOUT}
        DISCOVERY_TIMEOUT 60)
endfunction()

wm_gtest_executable(audio_tests
    TIMEOUT 30
    SOURCES
        audio/audio_response_mono_test.cpp
        audio/sound_stream_test.cpp
        fs/limited_binary_stream_test.cpp
        audio/sample_math_test.cpp
        audio/sound_layer_control_test.cpp
        audio/sound_layer_playback_test.cpp
        audio/audio_response_service_test.cpp
        audio/spectrum_export_128_test.cpp
        audio/sound_output_lifecycle_test.cpp
        support/allocation_tracking.cpp
    LIBS ${PROJECT_NAME} wpAudio wpFs
    INCLUDES . ${CMAKE_SOURCE_DIR}/src)
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
    # A script test: checks the CoreAudio backend switches of the miniaudio wrapper header.
    set(coreaudio_script ${CMAKE_CURRENT_SOURCE_DIR}/audio/coreaudio_backend_config.cmake)
    set(miniaudio_header ${CMAKE_SOURCE_DIR}/src/Audio/miniaudio-wrapper.hpp)
    add_test(NAME audio_coreaudio_backend_config
             COMMAND ${CMAKE_COMMAND} -DHEADER=${miniaudio_header} -P ${coreaudio_script})
endif()

wm_gtest_executable(shader_preprocessor_compat_test
    TIMEOUT 30
    PREFIX shader_preprocessor_compat_test.
    SOURCES shader_preprocessor_compat_test.cpp
    LIBS ${PROJECT_NAME} wpFs wpScene nlohmann_json::nlohmann_json
    INCLUDES .)
# The C++ side of the shader compiler. The engine library links the Rust compiler
# PUBLIC when it is configured, and these tests fail (not skip) without it.
add_executable(rust_shader_bridge_behavior_test rust_shader_bridge_behavior_test.cpp)
target_link_libraries(rust_shader_bridge_behavior_test PRIVATE ${PROJECT_NAME} wpFs wpScene wpRGraph nlohmann_json::nlohmann_json GTest::gtest_main)
if(DEFINED RUST_SHADER_STATICLIB AND NOT "${RUST_SHADER_STATICLIB}" STREQUAL "")
    target_link_libraries(rust_shader_bridge_behavior_test PRIVATE wescene_rust_shader)
endif()
target_include_directories(rust_shader_bridge_behavior_test PRIVATE . ${CMAKE_SOURCE_DIR}/src)
target_compile_features(rust_shader_bridge_behavior_test PRIVATE cxx_std_20)
gtest_discover_tests(
    rust_shader_bridge_behavior_test
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)
add_executable(shader_program_cache_behavior_test shader_program_cache_behavior_test.cpp)
target_link_libraries(shader_program_cache_behavior_test PRIVATE ${PROJECT_NAME} wpFs wpScene nlohmann_json::nlohmann_json GTest::gtest_main)
target_include_directories(shader_program_cache_behavior_test PRIVATE .)
target_compile_features(shader_program_cache_behavior_test PRIVATE cxx_std_20)
gtest_discover_tests(
    shader_program_cache_behavior_test
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)
add_executable(shader_dialect_compat_test shader_dialect_compat_test.cpp)
target_link_libraries(shader_dialect_compat_test PRIVATE ${PROJECT_NAME} wpFs wpScene nlohmann_json::nlohmann_json GTest::gtest_main)
target_include_directories(shader_dialect_compat_test PRIVATE .)
target_compile_features(shader_dialect_compat_test PRIVATE cxx_std_20)
gtest_discover_tests(
    shader_dialect_compat_test
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)
# How a scene becomes shader compile jobs (always run) and the opt-in whole-corpus
# compile sweep (DISABLED_ParsesCorpus). The unpack root default is compiled in; the
# environment overrides it at run time.
get_filename_component(_wescene_default_unpack_root "${CMAKE_CURRENT_SOURCE_DIR}/../../unpack" ABSOLUTE)
add_executable(shader_corpus_test shader_corpus_unit_test.cpp shader_corpus_sweep_test.cpp)
target_link_libraries(shader_corpus_test PRIVATE ${PROJECT_NAME} wpFs wpScene nlohmann_json::nlohmann_json GTest::gtest_main)
if(DEFINED RUST_SHADER_STATICLIB AND NOT "${RUST_SHADER_STATICLIB}" STREQUAL "")
    target_link_libraries(shader_corpus_test PRIVATE wescene_rust_shader)
endif()
target_include_directories(shader_corpus_test PRIVATE . ${CMAKE_SOURCE_DIR}/src)
target_compile_features(shader_corpus_test PRIVATE cxx_std_20)
target_compile_definitions(shader_corpus_test PRIVATE "WM_DEFAULT_UNPACK_ROOT=\"${_wescene_default_unpack_root}\"")
gtest_discover_tests(
    shader_corpus_test
    PROPERTIES TIMEOUT 600
    DISCOVERY_TIMEOUT 120
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
target_link_libraries(video_texture_submission_smoke PRIVATE GTest::gtest_main)
target_include_directories(video_texture_submission_smoke PRIVATE
    .
    ${CMAKE_SOURCE_DIR}/src
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
target_link_libraries(script_runtime_compat_test PRIVATE ${PROJECT_NAME} wpScene wpFs nlohmann_json::nlohmann_json GTest::gtest_main)
target_include_directories(script_runtime_compat_test PRIVATE . ${CMAKE_SOURCE_DIR}/src)
target_compile_features(script_runtime_compat_test PRIVATE cxx_std_20)
gtest_discover_tests(
    script_runtime_compat_test
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)
# SceneScript behaviour at the runtime level: what a script's value means to the property it
# drives, effect objects, start-up order, layer lists, local rotation. Scenes are loaded for their
# runtime only (support/script_scene.hpp): no device, no surface, no window.
add_executable(scenescript_behavior_test
    scenescript_values_test.cpp
    scenescript_objects_test.cpp
    scenescript_startup_test.cpp
    scenescript_rotation_test.cpp
    scenescript_layer_release_test.cpp
    support/pixels.cpp
    support/scene_package.cpp
    support/script_scene.cpp)
target_link_libraries(scenescript_behavior_test PRIVATE ${PROJECT_NAME} wpAudio wpScene wpFs nlohmann_json::nlohmann_json GTest::gtest_main)
target_include_directories(scenescript_behavior_test PRIVATE . ${CMAKE_SOURCE_DIR}/src)
target_compile_features(scenescript_behavior_test PRIVATE cxx_std_20)
if(TARGET wescene_rust_shader)
    target_link_libraries(scenescript_behavior_test PRIVATE wescene_rust_shader)
endif()
gtest_discover_tests(
    scenescript_behavior_test
    TEST_PREFIX scenescript_behavior_test.
    PROPERTIES TIMEOUT 60
    DISCOVERY_TIMEOUT 60
)
# Script, media and texture-slot behaviour driven straight through the runtime and the scene
# parser: no package, no device, no window. One executable per area.
function(add_runtime_behavior_test name)
    add_executable(${name} ${ARGN})
    target_link_libraries(${name} PRIVATE ${PROJECT_NAME} wpAudio wpScene wpFs nlohmann_json::nlohmann_json GTest::gtest_main)
    target_include_directories(${name} PRIVATE . ${CMAKE_SOURCE_DIR}/src)
    target_compile_features(${name} PRIVATE cxx_std_20)
    gtest_discover_tests(${name} PROPERTIES TIMEOUT 30 DISCOVERY_TIMEOUT 60)
endfunction()
add_runtime_behavior_test(sound_layer_cursor_behavior_test sound_layer_cursor_behavior_test.cpp)
add_runtime_behavior_test(media_event_behavior_test media_event_behavior_test.cpp)
add_runtime_behavior_test(texture_slot_behavior_test texture_slot_behavior_test.cpp)
add_runtime_behavior_test(material_constant_behavior_test material_constant_behavior_test.cpp)
add_runtime_behavior_test(create_layer_behavior_test create_layer_behavior_test.cpp)
add_runtime_behavior_test(script_host_behavior_test script_host_behavior_test.cpp)
add_runtime_behavior_test(shader_updater_behavior_test shader_updater_behavior_test.cpp)
# Explicit CLI diagnostic, not registered with ctest. Never creates a surface.
add_executable(render_target_lifetime_test render_target_lifetime_test.cpp)
target_link_libraries(render_target_lifetime_test PRIVATE ${PROJECT_NAME} wpScene wpRenderCommon wpRGraph nlohmann_json::nlohmann_json GTest::gtest_main)
target_include_directories(render_target_lifetime_test PRIVATE . ${CMAKE_SOURCE_DIR}/src)
gtest_discover_tests(render_target_lifetime_test PROPERTIES TIMEOUT 30)

if(APPLE)
  # Explicit CLI diagnostic, not registered with ctest. Draws one imported scene with Native
  # Metal into private images and an offscreen layer: no window, no drawable shown.
  add_executable(offscreen_scene_probe offscreen_scene_probe.mm)
  target_link_libraries(offscreen_scene_probe PRIVATE ${PROJECT_NAME} wpMetalRender wpAudio wpScene wpParticle wpFs wpRGraph wpRenderCommon nlohmann_json::nlohmann_json)
  target_include_directories(offscreen_scene_probe PRIVATE . ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/src/Scene/MetalRender/include)
  target_compile_features(offscreen_scene_probe PRIVATE cxx_std_20)
  set_target_properties(offscreen_scene_probe PROPERTIES OBJCXX_STANDARD 20 OBJCXX_STANDARD_REQUIRED YES)
  target_compile_options(offscreen_scene_probe PRIVATE $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
  if(TARGET wescene_rust_shader)
    target_link_libraries(offscreen_scene_probe PRIVATE wescene_rust_shader)
  endif()
endif()

# Explicit CLI diagnostic for cross-load state leaks, not registered with ctest.
add_executable(scene_reload_cycle_probe scene_reload_cycle_probe.cpp)
target_link_libraries(scene_reload_cycle_probe PRIVATE ${PROJECT_NAME} wpAudio wpScene wpParticle wpFs wpRGraph nlohmann_json::nlohmann_json)
target_include_directories(scene_reload_cycle_probe PRIVATE . ${CMAKE_SOURCE_DIR}/src)
target_compile_features(scene_reload_cycle_probe PRIVATE cxx_std_20)

# The text tests measure a font with FreeType itself, as the reference for the
# size the layout requests.
find_package(Freetype REQUIRED)
add_executable(text_object_runtime_test text_object_runtime_test.cpp)
target_link_libraries(text_object_runtime_test PRIVATE ${PROJECT_NAME} wpAudio wpScene wpFs wpRenderCommon wpRGraph Freetype::Freetype nlohmann_json::nlohmann_json GTest::gtest_main)
target_include_directories(text_object_runtime_test PRIVATE . ${CMAKE_SOURCE_DIR}/src)
target_compile_features(text_object_runtime_test PRIVATE cxx_std_20)
gtest_discover_tests(
    text_object_runtime_test
    TEST_PREFIX text_object_runtime_test.
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)
# Behaviour of text layers, written against the specification of the retired tests: parse,
# effect chains, runtime mutation, scripts and the FreeType raster. Headless.
add_executable(text_object_behavior_test
    text_parse_scene_test.cpp
    text_effect_chain_test.cpp
    text_runtime_cache_test.cpp
    text_script_raster_test.cpp
    support/text_scene.cpp
    support/pixels.cpp
    support/scene_package.cpp)
target_link_libraries(text_object_behavior_test PRIVATE ${PROJECT_NAME} wpAudio wpScene wpFs wpRenderCommon wpRGraph Freetype::Freetype nlohmann_json::nlohmann_json GTest::gtest_main)
target_include_directories(text_object_behavior_test PRIVATE . ${CMAKE_SOURCE_DIR}/src)
target_compile_features(text_object_behavior_test PRIVATE cxx_std_20)
if(TARGET wescene_rust_shader)
    target_link_libraries(text_object_behavior_test PRIVATE wescene_rust_shader)
endif()
gtest_discover_tests(
    text_object_behavior_test
    TEST_PREFIX text_object_behavior_test.
    PROPERTIES TIMEOUT 60
    DISCOVERY_TIMEOUT 60
)
add_executable(mouse_input_test mouse_input_test.cpp)
target_link_libraries(mouse_input_test PRIVATE ${PROJECT_NAME} wpScene nlohmann_json::nlohmann_json GTest::gtest_main)
target_include_directories(mouse_input_test PRIVATE . ${CMAKE_SOURCE_DIR}/src)
target_compile_features(mouse_input_test PRIVATE cxx_std_20)
gtest_discover_tests(
    mouse_input_test
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)
add_executable(cursor_input_state_test cursor_input_state_test.cpp)
target_link_libraries(cursor_input_state_test PRIVATE ${PROJECT_NAME} wpScene nlohmann_json::nlohmann_json GTest::gtest_main)
target_include_directories(cursor_input_state_test PRIVATE . ${CMAKE_SOURCE_DIR}/src)
target_compile_features(cursor_input_state_test PRIVATE cxx_std_20)
gtest_discover_tests(
    cursor_input_state_test
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)
add_executable(wallpaper_scaling_test wallpaper_scaling_test.cpp)
target_link_libraries(wallpaper_scaling_test PRIVATE ${PROJECT_NAME} wpScene GTest::gtest_main)
target_include_directories(wallpaper_scaling_test PRIVATE . ${CMAKE_SOURCE_DIR}/src)
target_compile_features(wallpaper_scaling_test PRIVATE cxx_std_20)
gtest_discover_tests(
    wallpaper_scaling_test
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)
# The arithmetic of Fit with blurred backdrop: the layout it reports, the rectangles the
# backdrop is drawn into and the plan that reduces the picture for it. No GPU.
add_executable(backdrop_geometry_test backdrop_geometry_test.cpp)
target_link_libraries(backdrop_geometry_test PRIVATE ${PROJECT_NAME} wpScene wpRenderCommon GTest::gtest_main)
target_include_directories(backdrop_geometry_test PRIVATE . ${CMAKE_SOURCE_DIR}/src)
target_compile_features(backdrop_geometry_test PRIVATE cxx_std_20)
gtest_discover_tests(
    backdrop_geometry_test
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
add_executable(particle_override_tint_test particle_override_tint_test.cpp)
target_link_libraries(particle_override_tint_test PRIVATE ${PROJECT_NAME} wpScene wpParticle wpAudio nlohmann_json::nlohmann_json GTest::gtest_main)
target_include_directories(particle_override_tint_test PRIVATE .)
target_compile_features(particle_override_tint_test PRIVATE cxx_std_20)
gtest_discover_tests(
    particle_override_tint_test
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)
add_executable(particle_billboard_size_test particle_billboard_size_test.cpp)
target_link_libraries(particle_billboard_size_test PRIVATE ${PROJECT_NAME} wpScene wpParticle wpAudio nlohmann_json::nlohmann_json GTest::gtest_main)
target_include_directories(particle_billboard_size_test PRIVATE .)
target_compile_features(particle_billboard_size_test PRIVATE cxx_std_20)
gtest_discover_tests(
    particle_billboard_size_test
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)
add_executable(particle_control_point_test particle_control_point_test.cpp)
target_link_libraries(particle_control_point_test PRIVATE ${PROJECT_NAME} wpScene wpParticle wpAudio nlohmann_json::nlohmann_json GTest::gtest_main)
target_include_directories(particle_control_point_test PRIVATE .)
target_compile_features(particle_control_point_test PRIVATE cxx_std_20)
gtest_discover_tests(
    particle_control_point_test
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)
add_executable(particle_override_test particle_override_test.cpp)
target_link_libraries(particle_override_test PRIVATE ${PROJECT_NAME} wpScene wpParticle wpAudio nlohmann_json::nlohmann_json GTest::gtest_main)
target_include_directories(particle_override_test PRIVATE .)
target_compile_features(particle_override_test PRIVATE cxx_std_20)
gtest_discover_tests(
    particle_override_test
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)
add_executable(particle_rope_pieces_test particle_rope_pieces_test.cpp)
target_link_libraries(particle_rope_pieces_test PRIVATE ${PROJECT_NAME} wpScene wpParticle wpAudio nlohmann_json::nlohmann_json GTest::gtest_main)
target_include_directories(particle_rope_pieces_test PRIVATE .)
target_compile_features(particle_rope_pieces_test PRIVATE cxx_std_20)
gtest_discover_tests(
    particle_rope_pieces_test
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)
add_executable(particle_parity_test particle_parity_test.cpp)
target_link_libraries(particle_parity_test PRIVATE ${PROJECT_NAME} wpScene wpParticle wpAudio wpFs nlohmann_json::nlohmann_json GTest::gtest_main)
target_include_directories(particle_parity_test PRIVATE .)
target_compile_features(particle_parity_test PRIVATE cxx_std_20)
gtest_discover_tests(
    particle_parity_test
    PROPERTIES TIMEOUT 60
    DISCOVERY_TIMEOUT 60
)
add_executable(layer_texture_reference_test layer_texture_reference_test.cpp)
target_link_libraries(layer_texture_reference_test PRIVATE ${PROJECT_NAME} wpRenderCommon wpRGraph wpScene wpAudio wpFs nlohmann_json::nlohmann_json GTest::gtest_main)
target_include_directories(layer_texture_reference_test PRIVATE . ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/src/Scene/RenderGraph/include)
target_compile_features(layer_texture_reference_test PRIVATE cxx_std_20)
gtest_discover_tests(
    layer_texture_reference_test
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)
add_executable(project_property_preview_test project_property_preview_test.cpp)
target_link_libraries(project_property_preview_test PRIVATE ${PROJECT_NAME} wpRGraph wpScene wpAudio wpFs nlohmann_json::nlohmann_json GTest::gtest_main)
target_include_directories(project_property_preview_test PRIVATE . ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/src/Scene/RenderGraph/include)
target_compile_features(project_property_preview_test PRIVATE cxx_std_20)
gtest_discover_tests(
    project_property_preview_test
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)
add_executable(rendergraph_smoke rendergraph_smoke.cpp graph_contract_cases.cpp)
target_link_libraries(rendergraph_smoke PRIVATE ${PROJECT_NAME} wpRenderCommon wpRGraph wpScene wpAudio wpFs GTest::gtest_main)
target_include_directories(rendergraph_smoke PRIVATE . ${CMAKE_SOURCE_DIR}/src)
target_compile_features(rendergraph_smoke PRIVATE cxx_std_20)
add_test(NAME rendergraph_smoke COMMAND rendergraph_smoke)
# The decode pump is codec-agnostic on purpose, so its state machine is tested
# without linking a codec or opening a real stream.
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
# arithmetic and its evidence rules are independent of any decoder and the GPU, so
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

# The synthetic media the video tests decode, in Renderer/Testing: a VideoToolbox
# encoder and an AVAssetWriter, so the
# files a decoder under test is shown were not produced by that decoder's
# library. `synthetic_video_test` checks the fixture itself, with AVFoundation.
get_filename_component(WESCENE_RENDERER_TESTING_DIR
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Testing" ABSOLUTE)
if(APPLE)
    add_subdirectory(${WESCENE_RENDERER_TESTING_DIR} ${CMAKE_CURRENT_BINARY_DIR}/synthetic_video)
    add_executable(synthetic_video_test
        ${WESCENE_RENDERER_TESTING_DIR}/synthetic_video_test.mm)
    target_link_libraries(synthetic_video_test PRIVATE
        wescene_testing_media GTest::gtest_main)
    target_include_directories(synthetic_video_test PRIVATE .)
    target_compile_features(synthetic_video_test PRIVATE cxx_std_20)
    set_target_properties(synthetic_video_test PROPERTIES
        OBJCXX_STANDARD 20 OBJCXX_STANDARD_REQUIRED YES)
    target_compile_options(synthetic_video_test PRIVATE
        $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
    gtest_discover_tests(synthetic_video_test
        TEST_PREFIX synthetic_video_test.
        PROPERTIES TIMEOUT 120
        DISCOVERY_TIMEOUT 60)
endif()

# The Apple adapter of the container readers (Renderer/Media/Apple), on real
# VideoToolbox decoding of the synthetic clips, registered here because the
# fixture library is built here.
if(APPLE)
    get_filename_component(WESCENE_MEDIA_APPLE_TESTS_DIR
        "${CMAKE_CURRENT_SOURCE_DIR}/../../Media/Apple/tests" ABSOLUTE)
    add_executable(vt_frame_decoder_test
        ${WESCENE_MEDIA_APPLE_TESTS_DIR}/vt_frame_decoder_test.mm)
    target_link_libraries(vt_frame_decoder_test PRIVATE
        wmMediaApple wmMedia wescene_testing_media GTest::gtest_main)
    target_include_directories(vt_frame_decoder_test PRIVATE .)
    target_compile_features(vt_frame_decoder_test PRIVATE cxx_std_20)
    set_target_properties(vt_frame_decoder_test PROPERTIES
        OBJCXX_STANDARD 20 OBJCXX_STANDARD_REQUIRED YES)
    target_compile_options(vt_frame_decoder_test PRIVATE
        $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
    gtest_discover_tests(vt_frame_decoder_test
        TEST_PREFIX vt_frame_decoder_test.
        PROPERTIES TIMEOUT 120
        DISCOVERY_TIMEOUT 60)
endif()

# WebMReader (Renderer/Media/Apple), the Objective-C face of the Matroska reader
# that the desktop player and the lock-screen extension play WebM through, on the
# embedded WebM and Matroska clips and the audio fixtures of Renderer/Sound/tests.
if(APPLE)
    add_executable(webm_reader_test
        ${WESCENE_MEDIA_APPLE_TESTS_DIR}/webm_reader_test.mm)
    target_link_libraries(webm_reader_test PRIVATE
        wmMediaApple wmMedia wmSound wescene_testing_media GTest::gtest_main)
    target_include_directories(webm_reader_test PRIVATE . ${WESCENE_MEDIA_APPLE_TESTS_DIR}/..)
    target_compile_features(webm_reader_test PRIVATE cxx_std_20)
    set_target_properties(webm_reader_test PROPERTIES
        OBJCXX_STANDARD 20 OBJCXX_STANDARD_REQUIRED YES)
    target_compile_options(webm_reader_test PRIVATE
        $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
    gtest_discover_tests(webm_reader_test
        TEST_PREFIX webm_reader_test.
        PROPERTIES TIMEOUT 120
        DISCOVERY_TIMEOUT 60)
endif()

# Reading a video's size and length from memory with the project's own container
# readers: the fixtures and, when there is a local wallpaper library, the video
# payloads inside its `.tex` files.
if(APPLE)
    pkg_check_modules(TEST_LZ4_PROBE REQUIRED IMPORTED_TARGET liblz4)
    add_executable(video_probe_test video_probe_test.cpp)
    target_link_libraries(video_probe_test PRIVATE ${PROJECT_NAME} wpFs wpScene
        wescene_testing_media PkgConfig::TEST_LZ4_PROBE GTest::gtest_main)
    target_include_directories(video_probe_test PRIVATE
        . ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/src/Scene/include)
    target_compile_features(video_probe_test PRIVATE cxx_std_20)
    gtest_discover_tests(
        video_probe_test
        TEST_PREFIX video_probe_test.
        PROPERTIES TIMEOUT 300
        DISCOVERY_TIMEOUT 60
    )
endif()

# A scene's video reaches the decoder without whole-file copies: where a loose clip lies, the
# cache file a packaged one is streamed to, and a clip packed into a texture.
if(APPLE)
    pkg_check_modules(TEST_LZ4_SCENE_VIDEO REQUIRED IMPORTED_TARGET liblz4)
    add_executable(scene_video_input_test scene_video_input_test.mm)
    target_link_libraries(scene_video_input_test PRIVATE ${PROJECT_NAME} wpFs wpScene wmMedia
        wescene_testing_media PkgConfig::TEST_LZ4_SCENE_VIDEO ${CORE_VIDEO_FRAMEWORK} GTest::gtest_main)
    target_include_directories(scene_video_input_test PRIVATE
        . ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/src/Scene ${CMAKE_SOURCE_DIR}/src/Scene/include
        ${CMAKE_SOURCE_DIR}/src/Scene/Parse)
    target_compile_features(scene_video_input_test PRIVATE cxx_std_20)
    set_target_properties(scene_video_input_test PROPERTIES OBJCXX_STANDARD 20 OBJCXX_STANDARD_REQUIRED YES)
    target_compile_options(scene_video_input_test PRIVATE $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
    gtest_discover_tests(
        scene_video_input_test
        TEST_PREFIX scene_video_input_test.
        PROPERTIES TIMEOUT 300
        DISCOVERY_TIMEOUT 60
    )
endif()

add_executable(video_source_input_test video_source_input_test.cpp)
target_link_libraries(video_source_input_test PRIVATE ${PROJECT_NAME}
    wmMedia wescene_testing_media GTest::gtest_main)
target_include_directories(video_source_input_test PRIVATE
    . ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/src/Scene/include)
target_compile_features(video_source_input_test PRIVATE cxx_std_20)
gtest_discover_tests(
    video_source_input_test
    TEST_PREFIX video_source_input_test.
    PROPERTIES TIMEOUT 120
    DISCOVERY_TIMEOUT 60
)

# A frame that would repeat the picture already on the surface is not drawn,
# submitted or presented. Driven through the whole scene wallpaper on a Metal
# layer no window owns, against media the fixture encodes.
if(APPLE)
    add_executable(unchanged_present_test unchanged_present_test.mm)
    target_link_libraries(unchanged_present_test PRIVATE ${PROJECT_NAME}
        wpScene wpRenderCommon wpRGraph
        wescene_testing_media GTest::gtest_main)
    target_include_directories(unchanged_present_test PRIVATE
        . ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/src/Scene/include
        ${CMAKE_SOURCE_DIR}/src/Scene/RenderCommon/include)
    target_compile_features(unchanged_present_test PRIVATE cxx_std_20)
    set_target_properties(unchanged_present_test PROPERTIES
        OBJCXX_STANDARD 20 OBJCXX_STANDARD_REQUIRED YES)
    target_compile_options(unchanged_present_test PRIVATE
        $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
    gtest_discover_tests(unchanged_present_test PROPERTIES TIMEOUT 120 DISCOVERY_TIMEOUT 60)
endif()

# What a scene does when the native backend cannot draw it and nothing else may:
# held on its last frame or its preview and reported, never drawn by anything
# else. The failures are forced where real ones strike.
if(APPLE)
    add_executable(scene_failure_policy_test scene_failure_policy_test.mm)
    target_link_libraries(scene_failure_policy_test PRIVATE ${PROJECT_NAME}
        wpScene wpRenderCommon wpRGraph GTest::gtest_main)
    target_include_directories(scene_failure_policy_test PRIVATE
        . ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/src/Scene/include
        ${CMAKE_SOURCE_DIR}/src/Scene/RenderCommon/include)
    target_compile_features(scene_failure_policy_test PRIVATE cxx_std_20)
    set_target_properties(scene_failure_policy_test PROPERTIES
        OBJCXX_STANDARD 20 OBJCXX_STANDARD_REQUIRED YES)
    target_compile_options(scene_failure_policy_test PRIVATE
        $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
    gtest_discover_tests(scene_failure_policy_test PROPERTIES TIMEOUT 120 DISCOVERY_TIMEOUT 60)
endif()

# A scene's sound while it loads: the volume and mute a wallpaper is meant to
# have are in force before its sounds are mounted. The output is miniaudio's
# null backend, so no audio device is opened.
if(APPLE)
    add_executable(scene_load_sound_test scene_load_sound_test.mm)
    target_link_libraries(scene_load_sound_test PRIVATE ${PROJECT_NAME}
        wpScene wpRenderCommon wpRGraph GTest::gtest_main)
    target_include_directories(scene_load_sound_test PRIVATE
        . ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/src/Scene/include
        ${CMAKE_SOURCE_DIR}/src/Scene/RenderCommon/include)
    target_compile_features(scene_load_sound_test PRIVATE cxx_std_20)
    set_target_properties(scene_load_sound_test PROPERTIES
        OBJCXX_STANDARD 20 OBJCXX_STANDARD_REQUIRED YES)
    target_compile_options(scene_load_sound_test PRIVATE
        $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
    gtest_discover_tests(scene_load_sound_test PROPERTIES TIMEOUT 120 DISCOVERY_TIMEOUT 60)
endif()

# Render-target sizing only: no device, no surface, no GPU.
add_executable(render_scale_test render_scale_test.cpp)
target_link_libraries(render_scale_test PRIVATE ${PROJECT_NAME} wpScene wpRenderCommon wpRGraph nlohmann_json::nlohmann_json GTest::gtest_main)
target_include_directories(render_scale_test PRIVATE
    . ${CMAKE_SOURCE_DIR}/src)
target_compile_features(render_scale_test PRIVATE cxx_std_20)
gtest_discover_tests(
    render_scale_test
    TEST_PREFIX render_scale_test.
    PROPERTIES TIMEOUT 60
    DISCOVERY_TIMEOUT 60
)

# Pure analysis: no device, no surface, no GPU.
add_executable(static_subgraph_cache_test static_subgraph_cache_test.cpp)
target_link_libraries(static_subgraph_cache_test PRIVATE wpRenderCommon wpScene wpRGraph nlohmann_json::nlohmann_json GTest::gtest_main)
target_include_directories(static_subgraph_cache_test PRIVATE
    . ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/src/Scene/RenderCommon/include)
target_compile_features(static_subgraph_cache_test PRIVATE cxx_std_20)
gtest_discover_tests(
    static_subgraph_cache_test
    TEST_PREFIX static_subgraph_cache_test.
    PROPERTIES TIMEOUT 60
    DISCOVERY_TIMEOUT 60
)

add_executable(timer_tests timer/frame_timer_test.cpp
                           timer/request_admission_contract_test.cpp)
target_link_libraries(timer_tests PRIVATE wpTimer GTest::gtest_main)
target_include_directories(timer_tests PRIVATE . ${CMAKE_SOURCE_DIR}/src)
target_compile_features(timer_tests PRIVATE cxx_std_20)
gtest_discover_tests(
    timer_tests
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)

add_executable(timer_delivery_benchmark timer/timer_delivery_benchmark.cpp)
target_link_libraries(timer_delivery_benchmark PRIVATE wpTimer)
target_include_directories(timer_delivery_benchmark PRIVATE . ${CMAKE_SOURCE_DIR}/src)
target_compile_features(timer_delivery_benchmark PRIVATE cxx_std_20)

# The workshop snapshot: what the engine's parsers make of one packed workshop item, as JSON.
# It is the library behind the wpdump tool, the dump tests and the corpus tests.
# WM_DEFAULT_CORPUS_ROOT is the folder the corpus tests read when WALLPAPER_MACHINE_WORKSHOP_ROOT
# is not set; neither ships with the repository.
add_library(workshop_snapshot STATIC workshop_snapshot.cpp workshop_corpus.cpp)
target_link_libraries(workshop_snapshot PUBLIC ${PROJECT_NAME} wpFs wpScene nlohmann_json::nlohmann_json)
target_include_directories(workshop_snapshot PUBLIC .)
target_compile_features(workshop_snapshot PUBLIC cxx_std_20)
target_compile_definitions(workshop_snapshot PUBLIC WM_DEFAULT_CORPUS_ROOT="${CMAKE_SOURCE_DIR}/workshop")

# Inspection tool, not a test: wpdump <workshop folder> [out.json].
add_executable(wpdump wpdump_main.cpp)
target_link_libraries(wpdump PRIVATE workshop_snapshot)
target_compile_features(wpdump PRIVATE cxx_std_20)

# Always-on: the dump tool and the corpus index, on items built in a scratch folder.
wm_gtest_executable(workshop_snapshot_test
    TIMEOUT 30
    SOURCES workshop_snapshot_test.cpp workshop_corpus_index_test.cpp
    LIBS workshop_snapshot ${PROJECT_NAME} wpFs wpScene PkgConfig::TEST_LZ4
    INCLUDES .)
target_compile_definitions(workshop_snapshot_test PRIVATE WPDUMP_EXE="$<TARGET_FILE:wpdump>")
add_dependencies(workshop_snapshot_test wpdump)

# Corpus-gated: one instance per version stamp found in the local workshop folder; skips
# (and instantiates nothing) when there is none. CPU only.
wm_gtest_executable(workshop_corpus_stamps_test
    TIMEOUT 30
    SOURCES workshop_corpus_stamps_test.cpp
    LIBS workshop_snapshot)

# Native Metal backend: capability gate, blend mapping, clip-space derivation
# and pipeline cache keys. No device needed for any of it; the one
# device-backed check skips visibly when no Metal device is present.
add_executable(metal_backend_test metal_backend_test.cpp)
target_link_libraries(metal_backend_test PRIVATE
    ${PROJECT_NAME} wpMetalRender wpScene wpRGraph wpParticle
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
      ${PROJECT_NAME} wpMetalRender wpScene wpRGraph
      wpParticle wpAudio wpFs nlohmann_json::nlohmann_json GTest::gtest_main
      # The video-layer case needs a real decodable file, which the fixture
      # encodes rather than shipping one.
      wescene_testing_media)
  target_include_directories(metal_scene_draw_smoke PRIVATE
      . ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/src/Scene/MetalRender/include)
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
        ${PROJECT_NAME} wpMetalRender wpScene wpRGraph
        wpParticle wpAudio wpFs nlohmann_json::nlohmann_json GTest::gtest_main
        ${METAL_FRAMEWORK} ${CORE_VIDEO_FRAMEWORK} ${IOSURFACE_FRAMEWORK}
        ${FOUNDATION_FRAMEWORK})
    # `hdr_reference.hpp`, the standards-derived CPU reference for the 10-bit
    # kernel, is header only and lives with the synthetic media.
    target_include_directories(${metal_module_test} PRIVATE
        . ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/src/Scene/MetalRender
        ${CMAKE_SOURCE_DIR}/src/Scene/MetalRender/include
        ${WESCENE_RENDERER_TESTING_DIR})
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

# The synthetic scene harness: a scratch wallpaper project, the engine's texture container,
# and a headless Metal run of it that returns the final picture and the named render targets.
# Test support only (see tests/support). Draws into private textures and a detached layer:
# no window, no drawable shown.
if(APPLE)
  add_library(scene_test_support STATIC
      support/pixels.cpp
      support/scene_package.cpp
      support/gpu_scene.mm)
  target_link_libraries(scene_test_support PUBLIC
      ${PROJECT_NAME} wpMetalRender wpScene wpRGraph wpRenderCommon
      wpParticle wpAudio wpFs nlohmann_json::nlohmann_json GTest::gtest)
  target_include_directories(scene_test_support PUBLIC
      . ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/src/Scene/MetalRender/include
      ${CMAKE_SOURCE_DIR}/src/Scene/include ${CMAKE_SOURCE_DIR}/src/Scene/RenderCommon/include)
  target_compile_features(scene_test_support PUBLIC cxx_std_20)
  set_target_properties(scene_test_support PROPERTIES
      OBJCXX_STANDARD 20 OBJCXX_STANDARD_REQUIRED YES)
  target_compile_options(scene_test_support PRIVATE
      $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
  if(TARGET wescene_rust_shader)
    target_link_libraries(scene_test_support PUBLIC wescene_rust_shader)
  endif()

  add_executable(scene_harness_selftest scene_harness_selftest.mm)
  target_link_libraries(scene_harness_selftest PRIVATE scene_test_support GTest::gtest_main)
  set_target_properties(scene_harness_selftest PROPERTIES
      OBJCXX_STANDARD 20 OBJCXX_STANDARD_REQUIRED YES)
  target_compile_options(scene_harness_selftest PRIVATE
      $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
  gtest_discover_tests(
      scene_harness_selftest
      TEST_PREFIX scene_harness_selftest.
      PROPERTIES TIMEOUT 120
      DISCOVERY_TIMEOUT 60
  )
  # Fit with blurred backdrop drawn by the native renderer, through the harness above.
  add_executable(backdrop_scene_test backdrop_scene_test.mm)
  target_link_libraries(backdrop_scene_test PRIVATE scene_test_support GTest::gtest_main)
  set_target_properties(backdrop_scene_test PROPERTIES
      OBJCXX_STANDARD 20 OBJCXX_STANDARD_REQUIRED YES)
  target_compile_options(backdrop_scene_test PRIVATE
      $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
  gtest_discover_tests(
      backdrop_scene_test
      TEST_PREFIX backdrop_scene_test.
      PROPERTIES TIMEOUT 240
      DISCOVERY_TIMEOUT 60
  )

  # The pointer follows the picture under the horizontal flip: the real host path on a detached
  # Metal layer, driven through the C bindings.
  add_executable(horizontal_flip_pointer_test horizontal_flip_pointer_test.mm)
  target_link_libraries(horizontal_flip_pointer_test PRIVATE scene_test_support GTest::gtest_main)
  set_target_properties(horizontal_flip_pointer_test PROPERTIES
      OBJCXX_STANDARD 20 OBJCXX_STANDARD_REQUIRED YES)
  target_compile_options(horizontal_flip_pointer_test PRIVATE
      $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
  gtest_discover_tests(
      horizontal_flip_pointer_test
      TEST_PREFIX horizontal_flip_pointer_test.
      PROPERTIES TIMEOUT 120
      DISCOVERY_TIMEOUT 60
  )

  # Scene layout: placeholder pictures, pass-through and fullscreen layers, layer size. Each draws
  # into private textures only, except the size test, which parses and never draws.
  foreach(layout_test
      scene_placeholder_picture_test
      scene_passthrough_layout_test
      scene_fullscreen_parallax_test)
    add_executable(${layout_test} ${layout_test}.mm)
    target_link_libraries(${layout_test} PRIVATE scene_test_support GTest::gtest_main)
    set_target_properties(${layout_test} PROPERTIES
        OBJCXX_STANDARD 20 OBJCXX_STANDARD_REQUIRED YES)
    target_compile_options(${layout_test} PRIVATE
        $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
    gtest_discover_tests(
        ${layout_test}
        TEST_PREFIX ${layout_test}.
        PROPERTIES TIMEOUT 180
        DISCOVERY_TIMEOUT 60
    )
  endforeach()

  # What a running wallpaper holds in memory: the pipeline-archive stores and the pictures
  # displays share. Private textures and archive files in the temp directory only.
  add_executable(metal_memory_test
      metal_archive_store_test.mm
      scene_shared_pictures_test.mm)
  target_link_libraries(metal_memory_test PRIVATE scene_test_support GTest::gtest_main)
  set_target_properties(metal_memory_test PROPERTIES
      OBJCXX_STANDARD 20 OBJCXX_STANDARD_REQUIRED YES)
  target_compile_options(metal_memory_test PRIVATE
      $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
  gtest_discover_tests(
      metal_memory_test
      TEST_PREFIX metal_memory_test.
      PROPERTIES TIMEOUT 240
      DISCOVERY_TIMEOUT 60
  )

  add_executable(scene_layer_size_test scene_layer_size_test.cpp)
  target_link_libraries(scene_layer_size_test PRIVATE scene_test_support GTest::gtest_main)
  gtest_discover_tests(
      scene_layer_size_test
      TEST_PREFIX scene_layer_size_test.
      PROPERTIES TIMEOUT 60
      DISCOVERY_TIMEOUT 60
  )

  # Scene rendering rules checked pixel by pixel through the same harness.
  foreach(scene_render_test
      layer_composite_render_test
      cover_slot_composite_test
      perspective_image_layer_test
      model_parallax_test
      unbound_texture_slot_test
      scene_lighting_fog_test)
    add_executable(${scene_render_test} ${scene_render_test}.mm)
    target_link_libraries(${scene_render_test} PRIVATE scene_test_support GTest::gtest_main)
    set_target_properties(${scene_render_test} PROPERTIES
        OBJCXX_STANDARD 20 OBJCXX_STANDARD_REQUIRED YES)
    target_compile_options(${scene_render_test} PRIVATE
        $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
    gtest_discover_tests(
        ${scene_render_test}
        TEST_PREFIX ${scene_render_test}.
        PROPERTIES TIMEOUT 240
        DISCOVERY_TIMEOUT 60
    )
  endforeach()
endif()

# Standalone miniaudio implementation with controlled CoreAudio/backend failures.
# This target never opens a real audio context or links the renderer's audio unit.
if(APPLE)
  add_executable(miniaudio_failure_paths_test miniaudio_failure_paths_test.cpp)
  target_include_directories(miniaudio_failure_paths_test PRIVATE ${WESCENE_THIRD_PARTY_DIR})
  target_link_libraries(miniaudio_failure_paths_test PRIVATE GTest::gtest_main)
  target_compile_features(miniaudio_failure_paths_test PRIVATE cxx_std_20)
  gtest_discover_tests(miniaudio_failure_paths_test
      TEST_PREFIX miniaudio_failure_paths_test.
      PROPERTIES TIMEOUT 30
      DISCOVERY_TIMEOUT 30)
endif()
