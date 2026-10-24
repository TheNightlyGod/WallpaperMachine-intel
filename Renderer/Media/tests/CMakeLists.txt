# Test executables for wmMedia. They need GTest::gtest_main, which the engine's
# tests/ directory fetches (or the standalone build in ../CMakeLists.txt does).
# Binaries land in <build>/tests next to the engine's own, where
# scripts/check_renderer.py runs them from.
include(GoogleTest)

# The repository root, so a test can read the bundled starter wallpaper.
get_filename_component(WM_MEDIA_REPO_ROOT "${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)

function(wm_media_test name)
    add_executable(${name} ${ARGN})
    target_link_libraries(${name} PRIVATE wmMedia GTest::gtest_main)
    target_compile_definitions(${name} PRIVATE WM_MEDIA_REPO_ROOT="${WM_MEDIA_REPO_ROOT}")
    set_target_properties(${name} PROPERTIES
        CXX_STANDARD 17
        CXX_STANDARD_REQUIRED ON
        CXX_EXTENSIONS OFF
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/tests")
    target_compile_options(${name} PRIVATE
        -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion -Wshadow)
    gtest_discover_tests(${name} PROPERTIES TIMEOUT 120 DISCOVERY_TIMEOUT 60)
endfunction()

wm_media_test(media_core_tests core_tests.cpp byte_source_tests.cpp sample_order_tests.cpp
              av1_sequence_header_tests.cpp)
wm_media_test(media_isobmff_tests isobmff_tests.cpp isobmff_corpus_tests.cpp)
wm_media_test(media_matroska_tests matroska_tests.cpp matroska_corpus_tests.cpp)
