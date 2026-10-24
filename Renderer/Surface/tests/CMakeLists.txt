# Test executables for wmSurface. They need GTest::gtest_main, which the engine's
# tests/ directory fetches. Binaries land in <build>/tests next to the engine's
# own, where scripts/check_renderer.py runs them from.
include(GoogleTest)

function(wm_surface_test name)
    add_executable(${name} ${ARGN})
    target_link_libraries(${name} PRIVATE wmSurface GTest::gtest_main)
    set_target_properties(${name} PROPERTIES
        CXX_STANDARD 17
        CXX_STANDARD_REQUIRED ON
        CXX_EXTENSIONS OFF
        OBJCXX_STANDARD 17
        OBJCXX_STANDARD_REQUIRED ON
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/tests")
    target_compile_options(${name} PRIVATE
        -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion -Wshadow)
    gtest_discover_tests(${name} PROPERTIES TIMEOUT 60 DISCOVERY_TIMEOUT 60)
endfunction()

wm_surface_test(surface_path_tests preview_path_tests.cpp)
if(APPLE)
    wm_surface_test(surface_still_tests still_preview_tests.mm)
endif()
