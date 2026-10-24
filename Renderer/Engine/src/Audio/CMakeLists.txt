set(LIB_NAME wpAudio)

if(NOT TARGET wmSound)
    message(FATAL_ERROR "wpAudio needs wmSound (Renderer/Sound in this repository)")
endif()

add_library(${LIB_NAME}
    STATIC
    BinaryStreamByteSource.cpp
    PcmSoundStream.cpp
    AudioResponseAnalyzerVdsp.cpp
    AudioResponseService.cpp
    SoundManager.cpp
    SoundStreamFactory.cpp
)

target_link_libraries(${LIB_NAME}
PUBLIC
    wpUtils
    wmSound
PRIVATE
    wpFs
    miniaudio
)
target_include_directories(${LIB_NAME} PUBLIC include PRIVATE include/Audio)
target_compile_options(${LIB_NAME} PRIVATE ${warn_opts})
if(BUILD_TESTS)
    target_compile_definitions(${LIB_NAME} PRIVATE WESCENE_BUILD_TESTS=1)
endif()
set_property(TARGET ${LIB_NAME} PROPERTY POSITION_INDEPENDENT_CODE ON)
