# Synthetic video for the renderer's tests: a VideoToolbox H.264 encoder and an
# AVAssetWriter passthrough writer, behind a header that is plain C++.
#
# It depends on Apple frameworks only, so the files it writes are not produced
# by the libraries the decoders under test are built from.
find_library(AVFOUNDATION_FRAMEWORK AVFoundation REQUIRED)
find_library(CORE_GRAPHICS_FRAMEWORK CoreGraphics REQUIRED)
find_library(CORE_MEDIA_FRAMEWORK CoreMedia REQUIRED)
find_library(CORE_VIDEO_FRAMEWORK CoreVideo REQUIRED)
find_library(FOUNDATION_FRAMEWORK Foundation REQUIRED)
find_library(VIDEOTOOLBOX_FRAMEWORK VideoToolbox REQUIRED)

add_library(wescene_testing_media STATIC synthetic_video.mm)
target_include_directories(wescene_testing_media PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(wescene_testing_media PUBLIC
    ${AVFOUNDATION_FRAMEWORK} ${CORE_GRAPHICS_FRAMEWORK} ${CORE_MEDIA_FRAMEWORK} ${CORE_VIDEO_FRAMEWORK}
    ${FOUNDATION_FRAMEWORK} ${VIDEOTOOLBOX_FRAMEWORK})
target_compile_features(wescene_testing_media PUBLIC cxx_std_20)
set_target_properties(wescene_testing_media PROPERTIES
    OBJCXX_STANDARD 20 OBJCXX_STANDARD_REQUIRED YES
    POSITION_INDEPENDENT_CODE ON)
target_compile_options(wescene_testing_media PRIVATE
    $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>
    -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion)
