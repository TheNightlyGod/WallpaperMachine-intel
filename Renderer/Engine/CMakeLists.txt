cmake_minimum_required(VERSION 3.14)
project(wescene-renderer)

if(APPLE)
    enable_language(OBJCXX)
endif()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Only clang-family compilers are supported unless explicitly overridden.
if(NOT CMAKE_CXX_COMPILER_ID MATCHES "Clang" AND NOT WAYWALLEN_ALLOW_NONCLANG)
    message(
        FATAL_ERROR
        "Unsupported compiler '${CMAKE_CXX_COMPILER_ID}': configure with clang "
        "(-DCMAKE_CXX_COMPILER=clang++) or pass -DWAYWALLEN_ALLOW_NONCLANG=ON to accept the risk.")
endif()

find_package(PkgConfig REQUIRED)

# True when this directory is the root project (not pulled in with add_subdirectory).
set(_wescene_is_top_level OFF)
if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
    set(_wescene_is_top_level ON)
endif()

# The container readers (wmMedia), in Renderer/Media beside the engine: pure C++17
# with no dependency on anything else here. The engine links it, so it has to be
# configured from a full checkout.
get_filename_component(
    WESCENE_MEDIA_DIR "${CMAKE_CURRENT_LIST_DIR}/../Media" ABSOLUTE)
if(EXISTS "${WESCENE_MEDIA_DIR}/CMakeLists.txt")
    add_subdirectory("${WESCENE_MEDIA_DIR}" "${CMAKE_BINARY_DIR}/Renderer/Media")
    # Its Apple platform layer (ObjC++ over VideoToolbox) is a library of its own.
    if(APPLE AND EXISTS "${WESCENE_MEDIA_DIR}/Apple/CMakeLists.txt")
        add_subdirectory("${WESCENE_MEDIA_DIR}/Apple" "${CMAKE_BINARY_DIR}/Renderer/Media/Apple")
    endif()
endif()

# The sound path (wmSound): remixing, resampling, looping and the decoders behind
# scene sounds, in Renderer/Sound. It
# needs wmMedia's ByteSource, so it is only built where wmMedia is.
get_filename_component(
    WESCENE_SOUND_DIR "${CMAKE_CURRENT_LIST_DIR}/../Sound" ABSOLUTE)
if(TARGET wmMedia AND EXISTS "${WESCENE_SOUND_DIR}/CMakeLists.txt")
    add_subdirectory("${WESCENE_SOUND_DIR}" "${CMAKE_BINARY_DIR}/Renderer/Sound")
endif()

# The surface pieces (wmSurface): the still preview a wallpaper that cannot be
# drawn shows instead of an empty layer, in Renderer/Surface. Self-contained:
# ImageIO and Core Animation only.
get_filename_component(
    WESCENE_SURFACE_DIR "${CMAKE_CURRENT_LIST_DIR}/../Surface" ABSOLUTE)
if(EXISTS "${WESCENE_SURFACE_DIR}/CMakeLists.txt")
    add_subdirectory("${WESCENE_SURFACE_DIR}" "${CMAKE_BINARY_DIR}/Renderer/Surface")
endif()

# The vendored C libraries live in the repository's top-level ThirdParty/ (see
# ThirdParty/provenance.json); their headers are treated as system headers.
# Dependencies/ defines their targets and finds the Homebrew packages.
get_filename_component(
    WESCENE_THIRD_PARTY_DIR "${CMAKE_CURRENT_LIST_DIR}/../../ThirdParty" ABSOLUTE)
include_directories(SYSTEM "${WESCENE_THIRD_PARTY_DIR}" "${WESCENE_THIRD_PARTY_DIR}/stb_image")
add_subdirectory(Dependencies)

option(BUILD_TESTS "Build the wescene-renderer test suite" ${_wescene_is_top_level})

# A prebuilt Rust shader static library switches the FFI on and is linked whole,
# so every rs_shader_* symbol survives dead-stripping.
set(_wescene_rust_shader_ffi_default OFF)
if(DEFINED RUST_SHADER_STATICLIB AND NOT "${RUST_SHADER_STATICLIB}" STREQUAL "")
    set(_wescene_rust_shader_ffi_default ON)
    if(NOT TARGET wescene_rust_shader)
        add_library(wescene_rust_shader INTERFACE IMPORTED GLOBAL)
        set_property(TARGET wescene_rust_shader PROPERTY INTERFACE_LINK_DEPENDS
                                                         "${RUST_SHADER_STATICLIB}")
        if(APPLE)
            target_link_options(
                wescene_rust_shader INTERFACE "LINKER:-force_load,${RUST_SHADER_STATICLIB}")
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
    # wmMedia's tests use the googletest that tests/ just fetched.
    if(TARGET wmMedia)
        add_subdirectory("${WESCENE_MEDIA_DIR}/tests" "${CMAKE_BINARY_DIR}/Renderer/Media/tests")
    endif()
    if(TARGET wmSound)
        add_subdirectory("${WESCENE_SOUND_DIR}/tests" "${CMAKE_BINARY_DIR}/Renderer/Sound/tests")
    endif()
    if(TARGET wmSurface)
        add_subdirectory("${WESCENE_SURFACE_DIR}/tests" "${CMAKE_BINARY_DIR}/Renderer/Surface/tests")
    endif()
endif()

# The waywallen host, QML helper and standalone viewer were removed from this
# engine (macOS app embeds the library directly); see ThirdParty/provenance.json.
