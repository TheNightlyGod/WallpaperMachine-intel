# wmMedia: this project's own container readers (ISO-BMFF/MP4, Matroska/WebM).
#
# Pure C++17 with no Apple, FFmpeg or other third-party dependency, so the same
# sources can be compiled into the app, the sandboxed lock-screen extension and
# the test binaries. The engine build (Renderer/Engine/CMakeLists.txt) includes
# this directory for the library
# and Media/tests for the test executables; configuring this directory on its
# own (`cmake -S Renderer/Media`) builds both with a fetched googletest, which is
# how the sanitizer build in docs/testing/renderer.md is made.
set(_wm_media_standalone OFF)
if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
    cmake_minimum_required(VERSION 3.14)
    project(wmMedia CXX)
    set(_wm_media_standalone ON)
endif()

set(WM_MEDIA_SANITIZE "" CACHE STRING
    "Standalone builds only: sanitizer list for -fsanitize= (for example address,undefined)")

set(WM_MEDIA_SOURCES
    Av1/Av1SequenceHeader.cpp
    ByteSource.cpp
    Checked.cpp
    CodecConfig.cpp
    DisplayMatrix.cpp
    Error.cpp
    IsoBmff/IsoBmffReader.cpp
    Matroska/MatroskaReader.cpp
    Matroska/Vp9Header.cpp
    Rational.cpp
    SampleOrder.cpp
    VideoTypes.cpp
)

add_library(wmMedia STATIC ${WM_MEDIA_SOURCES})
set_target_properties(wmMedia PROPERTIES
    CXX_STANDARD 17
    CXX_STANDARD_REQUIRED ON
    CXX_EXTENSIONS OFF
    POSITION_INDEPENDENT_CODE ON)
# Includes are written as "Media/<Header>.hpp", relative to Renderer/.
target_include_directories(wmMedia PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/..")
target_compile_options(wmMedia PRIVATE
    -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion -Wshadow)

if(_wm_media_standalone)
    if(WM_MEDIA_SANITIZE)
        # Directory-wide options only reach targets created after them, so the library, which
        # exists already, is instrumented explicitly; gtest and the tests get the rest.
        target_compile_options(wmMedia PRIVATE -fsanitize=${WM_MEDIA_SANITIZE} -fno-omit-frame-pointer -g)
        add_compile_options(-fsanitize=${WM_MEDIA_SANITIZE} -fno-omit-frame-pointer -g)
        add_link_options(-fsanitize=${WM_MEDIA_SANITIZE})
    endif()
    enable_testing()
    include(FetchContent)
    if(NOT DEFINED FETCHCONTENT_SOURCE_DIR_GOOGLETEST)
        FetchContent_Declare(
            googletest
            GIT_REPOSITORY https://github.com/google/googletest.git
            GIT_TAG        v1.14.0
            GIT_SHALLOW    TRUE)
    else()
        FetchContent_Declare(googletest)
    endif()
    set(BUILD_GMOCK OFF CACHE INTERNAL "")
    set(INSTALL_GTEST OFF CACHE INTERNAL "")
    FetchContent_MakeAvailable(googletest)
    add_subdirectory(tests)
endif()
