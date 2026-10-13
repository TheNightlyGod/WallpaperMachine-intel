cmake_minimum_required(VERSION 3.14)
project(wescene-renderer)

if(APPLE)
    enable_language(OBJCXX)
    add_compile_definitions(_LIBCPP_ENABLE_EXPERIMENTAL)
endif()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Restrict to Clang. The renderer + tests rely on Clang-specific behaviour
# (clang-format style, sanitizer flags wired in src/CMakeLists.txt, and
# observed glslang/FetchContent quirks) and we have no CI matrix for GCC.
# Override with -DWAYWALLEN_ALLOW_NONCLANG=ON if you know what you're doing.
if(NOT CMAKE_CXX_COMPILER_ID MATCHES "Clang" AND NOT WAYWALLEN_ALLOW_NONCLANG)
    message(FATAL_ERROR
        "wescene-renderer requires Clang (got ${CMAKE_CXX_COMPILER_ID}). "
        "Re-run cmake with `-DCMAKE_CXX_COMPILER=clang++ -DCMAKE_C_COMPILER=clang`, "
        "or pass -DWAYWALLEN_ALLOW_NONCLANG=ON to bypass this check.")
endif()

find_package(PkgConfig REQUIRED)

# Puts the FFmpeg headers pkg-config resolved ahead of every other include
# directory on `target`.
#
# Homebrew keeps each formula in its own cellar and links the default one into
# the shared `/opt/homebrew/include`, so a machine with both `ffmpeg` and
# `ffmpeg@8` installed offers two sets of libav* headers with different
# `AVFrame`/`AVCodecContext` layouts. Every other dependency (Eigen, freetype,
# nlohmann, quickjs) drags that shared prefix in, and because it is reached
# through a linked target it lands ahead of the cellar path pkg-config chose --
# so the build reads one major's struct offsets out of the other major's
# objects. The fields still line up far enough in for the compiler to accept
# it, and the damage shows up at runtime as silently wrong frame metadata.
#
# `prefix` selects the pkg_check_modules variable set to use (empty for the
# unprefixed one, `TEST_` for the suite's own).
function(wescene_prefer_ffmpeg_headers target prefix)
    target_include_directories(
        ${target} SYSTEM BEFORE PRIVATE
        ${${prefix}AVFORMAT_INCLUDE_DIRS}
        ${${prefix}AVCODEC_INCLUDE_DIRS}
        ${${prefix}AVUTIL_INCLUDE_DIRS}
        ${${prefix}SWRESAMPLE_INCLUDE_DIRS})
endfunction()

set(_wescene_is_top_level OFF)
if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
    set(_wescene_is_top_level ON)
endif()

include_directories(SYSTEM third_party)
add_subdirectory(third_party)

link_libraries(Eigen3::Eigen)

# Test suite — gated by BUILD_TESTS. Include CTest so
# gtest_discover_tests / add_test inside tests/ register with ctest.
set(_wescene_build_tests_default ${_wescene_is_top_level})
option(BUILD_TESTS "Build the wescene-renderer test suite" ${_wescene_build_tests_default})

set(_wescene_rust_shader_ffi_default OFF)
if(DEFINED RUST_SHADER_STATICLIB AND NOT "${RUST_SHADER_STATICLIB}" STREQUAL "")
    set(_wescene_rust_shader_ffi_default ON)
    if(NOT TARGET wescene_rust_shader)
        add_library(wescene_rust_shader INTERFACE IMPORTED GLOBAL)
        set_target_properties(
            wescene_rust_shader
            PROPERTIES INTERFACE_LINK_DEPENDS "${RUST_SHADER_STATICLIB}")
        if(APPLE)
            target_link_options(
                wescene_rust_shader
                INTERFACE "LINKER:-force_load,${RUST_SHADER_STATICLIB}")
        else()
            target_link_options(
                wescene_rust_shader
                INTERFACE
                    "LINKER:--whole-archive"
                    "${RUST_SHADER_STATICLIB}"
                    "LINKER:--no-whole-archive")
        endif()
    endif()
endif()
option(
    RUST_SHADER_FFI
    "Compile the Rust shader bridge against externally resolved rs_shader_* symbols"
    ${_wescene_rust_shader_ffi_default})

add_subdirectory(src)

if(BUILD_TESTS)
    include(CTest)
    add_subdirectory(tests)
endif()

# The waywallen host, QML helper and standalone viewer were removed from this
# vendored copy (macOS app embeds the library directly); see upstream/provenance.json.
