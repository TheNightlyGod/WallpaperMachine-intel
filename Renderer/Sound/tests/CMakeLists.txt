# Test executables for wmSound. They need GTest::gtest_main, which the engine's
# tests/ directory fetches. Binaries land in <build>/tests next to the engine's
# own, where scripts/check_renderer.py runs them from.
include(GoogleTest)

function(wm_sound_test name)
    add_executable(${name} ${ARGN})
    target_link_libraries(${name} PRIVATE wmSound GTest::gtest_main)
    set_target_properties(${name} PROPERTIES
        CXX_STANDARD 17
        CXX_STANDARD_REQUIRED ON
        CXX_EXTENSIONS OFF
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/tests")
    target_compile_options(${name} PRIVATE
        -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion -Wshadow)
    gtest_discover_tests(${name} PROPERTIES TIMEOUT 120 DISCOVERY_TIMEOUT 60)
endfunction()

wm_sound_test(sound_core_tests resampler_tests.cpp remix_tests.cpp pipeline_tests.cpp)
if(APPLE)
    wm_sound_test(sound_apple_tests apple_decoder_tests.cpp)
endif()
wm_sound_test(sound_vorbis_tests vorbis_decoder_tests.cpp)
wm_sound_test(sound_matroska_tests matroska_audio_tests.cpp)
