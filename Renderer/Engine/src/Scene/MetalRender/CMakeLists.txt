set(LIB_NAME wpMetalRender)

# The scene-side half of this library -- the capability gate, the blend
# mapping, the clip-space derivation, the pipeline key and the pass
# description -- is plain C++ and builds anywhere. Only the renderer itself is
# Objective-C++ and needs Metal, so it is the only source gated on Apple.
set(METAL_RENDER_SOURCES
    MetalBackendRouter.cpp
    MetalBlend.cpp
    MetalCapability.cpp
    MetalProjection.cpp
    MetalShaderReflection.cpp
    MetalVideoSupport.cpp
    ScenePassDescription.cpp)

if(APPLE)
  find_library(APPKIT_FRAMEWORK AppKit REQUIRED)
  list(APPEND METAL_RENDER_SOURCES
    MetalRender.mm
    MetalDisplayOutput.mm
    MetalBackdrop.mm
    MetalImageLevels.mm
    MetalPosterCapture.mm
    MetalSharedImages.mm
    MetalUpscaler.mm
    MetalVideoTextures.mm)
endif()

add_library(${LIB_NAME} STATIC ${METAL_RENDER_SOURCES})

# Depends on wpScene and on the shared render graph, never the other way
# round: wpScene must stay free of any renderer. The scene-side logic -- the
# `DynamicReason` vocabulary, static reuse, copy elision, the presentation
# layout, and the read-only description of a graph step -- lives in
# wpRenderCommon, plain C++ that builds without Metal.
target_link_libraries(${LIB_NAME}
PUBLIC
    wpUtils
    wpScene
    wpRenderCommon
PRIVATE
    wpParticle
    wpRGraph
    nlohmann_json::nlohmann_json)

target_include_directories(${LIB_NAME}
PUBLIC
    include
PRIVATE
    include/MetalRender
    .)

target_compile_features(${LIB_NAME} PUBLIC cxx_std_20)

if(BUILD_TESTS)
  target_compile_definitions(${LIB_NAME} PUBLIC WESCENE_BUILD_TESTS=1)
endif()

if(APPLE)
  set_target_properties(${LIB_NAME} PROPERTIES
    OBJCXX_STANDARD 20
    OBJCXX_STANDARD_REQUIRED YES)
  target_compile_options(${LIB_NAME} PRIVATE
    "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>")
  target_link_libraries(${LIB_NAME} PUBLIC
    ${METAL_FRAMEWORK}
    ${METAL_FX_FRAMEWORK}
    ${QUARTZ_CORE_FRAMEWORK}
    ${CORE_VIDEO_FRAMEWORK}
    ${FOUNDATION_FRAMEWORK}
    ${APPKIT_FRAMEWORK})
endif()

set_property(TARGET ${LIB_NAME} PROPERTY POSITION_INDEPENDENT_CODE ON)
