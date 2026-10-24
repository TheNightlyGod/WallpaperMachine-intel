# wmMediaApple: the Apple platform layer of Renderer/Media. Takes what the
# container readers (wmMedia) report and turns it into VideoToolbox input and
# output: codec format descriptions, a VTDecompressionSession wrapper that
# delivers frames in display order, the pixel format decisions, and WebMReader,
# the Objective-C face of the Matroska reader that Swift (the app and the
# lock-screen extension) plays WebM files through.
#
# ObjC++ over Core Media, Core Video and VideoToolbox, with plain C++ headers
# so the scene engine's C++ sources can include them. Only the engine's CMake
# adds this directory (the readers' standalone build is pure C++).
find_library(CORE_FOUNDATION_FRAMEWORK CoreFoundation REQUIRED)
find_library(CORE_MEDIA_FRAMEWORK CoreMedia REQUIRED)
find_library(CORE_GRAPHICS_FRAMEWORK CoreGraphics REQUIRED)
find_library(CORE_VIDEO_FRAMEWORK CoreVideo REQUIRED)
find_library(FOUNDATION_FRAMEWORK Foundation REQUIRED)
find_library(VIDEOTOOLBOX_FRAMEWORK VideoToolbox REQUIRED)

add_library(wmMediaApple STATIC
    FormatDescription.mm
    VtFrameDecoder.mm
    WebMReader.mm
)
set_target_properties(wmMediaApple PROPERTIES
    CXX_STANDARD 17
    CXX_STANDARD_REQUIRED ON
    CXX_EXTENSIONS OFF
    OBJCXX_STANDARD 17
    OBJCXX_STANDARD_REQUIRED ON
    POSITION_INDEPENDENT_CODE ON)
# Includes are written as "Media/Apple/<Header>.hpp", relative to Renderer/.
target_include_directories(wmMediaApple PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/../..")
# wmSound (configured after this directory, resolved by name) decodes the audio track.
target_link_libraries(wmMediaApple PUBLIC wmMedia wmSound
    ${CORE_FOUNDATION_FRAMEWORK} ${CORE_GRAPHICS_FRAMEWORK} ${CORE_MEDIA_FRAMEWORK} ${CORE_VIDEO_FRAMEWORK}
    ${FOUNDATION_FRAMEWORK} ${VIDEOTOOLBOX_FRAMEWORK})
target_compile_options(wmMediaApple PRIVATE
    $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>
    -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion -Wshadow)
