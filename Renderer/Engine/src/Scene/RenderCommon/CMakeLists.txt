set(LIB_NAME wpRenderCommon)

# The scene-side logic the renderer draws from: the dynamic-reason vocabulary
# and static-subgraph reuse, copy elision, the unchanged-present gate, the
# scene-to-demand mapping, the presentation layout, the description of each
# render-graph step (ScenePass) and the builder that turns a scene into that
# graph (SceneToRenderGraph). Plain C++ with no GPU API in it, so it builds and
# is tested without Metal, and its process-wide counters are defined exactly
# once.
add_library(${LIB_NAME}
STATIC
CopyElision.cpp
SceneDemandMapping.cpp
ScenePass.cpp
SceneToRenderGraph.cpp
StaticSubgraphCache.cpp
# Presentation layout and cursor mapping: plain arithmetic.
../../Presentation/WallpaperScaling.cpp
# Where the blurred backdrop goes and how the picture is reduced for it.
../../Presentation/BackdropGeometry.cpp
)

target_link_libraries(${LIB_NAME}
PUBLIC
    wpScene
    wpRGraph
    wpUtils
)
target_include_directories(${LIB_NAME} PUBLIC include PRIVATE include/RenderCommon .)
target_compile_options(${LIB_NAME} PRIVATE ${warn_opts} -Wno-missing-field-initializers)
target_compile_features(${LIB_NAME} PUBLIC cxx_std_20)
set_property(TARGET ${LIB_NAME} PROPERTY POSITION_INDEPENDENT_CODE ON)
