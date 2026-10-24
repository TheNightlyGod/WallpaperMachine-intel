# wmSurface: this project's own surface-level pieces of the renderer that are not
# drawing. Today that is the still preview a wallpaper that cannot be drawn shows
# instead of an empty layer (StillPreview, with the project-folder rule that picks
# the file in PreviewPath).
#
# PreviewPath is pure C++17. StillPreview is ObjC++ over ImageIO and Core
# Animation, so it is only built on macOS. The engine's CMake adds this
# directory; the headers are included as "Surface/<Header>.hpp".
set(WM_SURFACE_SOURCES PreviewPath.cpp)
if(APPLE)
    list(APPEND WM_SURFACE_SOURCES StillPreview.mm)
endif()

add_library(wmSurface STATIC ${WM_SURFACE_SOURCES})
set_target_properties(wmSurface PROPERTIES
    CXX_STANDARD 17
    CXX_STANDARD_REQUIRED ON
    CXX_EXTENSIONS OFF
    OBJCXX_STANDARD 17
    OBJCXX_STANDARD_REQUIRED ON
    POSITION_INDEPENDENT_CODE ON)
target_include_directories(wmSurface PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/..")
if(APPLE)
    target_link_libraries(wmSurface PUBLIC
        "-framework Foundation" "-framework CoreGraphics" "-framework ImageIO"
        "-framework QuartzCore")
    target_compile_options(wmSurface PRIVATE
        $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
endif()
target_compile_options(wmSurface PRIVATE
    -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion -Wshadow)
