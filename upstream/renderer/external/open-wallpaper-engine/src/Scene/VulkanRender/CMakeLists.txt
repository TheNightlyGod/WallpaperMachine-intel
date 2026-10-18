set(LIB_NAME wpVulkanRender)

add_library(${LIB_NAME}
STATIC
CopyPass.cpp
CopyElision.cpp
StaticSubgraphCache.cpp
CustomShaderPass.cpp
FinPass.cpp
PrePass.cpp
SceneDemandMapping.cpp
SceneToRenderGraph.cpp
TexturePrefetch.cpp
VulkanRender.cpp
# Presentation layout is shared by both render backends and is written in
# Vulkan's viewport types, so it lives with the Vulkan-typed render code rather
# than in the top-level renderer target. Putting it there would make the native
# Metal backend depend on the target that already depends on it.
../../Presentation/WallpaperScaling.cpp
)

target_link_libraries(${LIB_NAME}
PRIVATE
	wpVulkan
    wpScene
    wpRGraph
    nlohmann_json::nlohmann_json
)
target_include_directories(${LIB_NAME} PUBLIC include PRIVATE include/VulkanRender .)
target_compile_options(${LIB_NAME} PRIVATE ${warn_opts} -Wno-missing-field-initializers)
set_property(TARGET ${LIB_NAME} PROPERTY POSITION_INDEPENDENT_CODE ON)
