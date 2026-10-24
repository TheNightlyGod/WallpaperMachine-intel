# The engine's external libraries: the Homebrew packages it finds and the vendored C
# libraries under ThirdParty/ (WESCENE_THIRD_PARTY_DIR, set by the engine).
set(CMAKE_POLICY_DEFAULT_CMP0077 NEW)

find_package(PkgConfig REQUIRED)
find_package(nlohmann_json CONFIG REQUIRED)
find_package(argparse CONFIG REQUIRED)

if(NOT qjs_DIR)
    foreach(_prefix IN LISTS CMAKE_PREFIX_PATH)
        set(_quickjs_config_dir "${_prefix}/lib/cmake/quickjs")
        if(EXISTS "${_quickjs_config_dir}/qjsConfig.cmake")
            set(qjs_DIR "${_quickjs_config_dir}" CACHE PATH "Path to qjsConfig.cmake")
            break()
        endif()
    endforeach()
endif()

if(NOT qjs_DIR)
    find_path(_quickjs_include_dir
        NAMES quickjs.h
        PATHS ${CMAKE_PREFIX_PATH}
        PATH_SUFFIXES include include/quickjs)
    if(_quickjs_include_dir)
        if(_quickjs_include_dir MATCHES "/include/quickjs$")
            get_filename_component(_quickjs_prefix "${_quickjs_include_dir}/../.." ABSOLUTE)
        else()
            get_filename_component(_quickjs_prefix "${_quickjs_include_dir}/.." ABSOLUTE)
        endif()

        set(_quickjs_config_dir "${_quickjs_prefix}/lib/cmake/quickjs")
        if(EXISTS "${_quickjs_config_dir}/qjsConfig.cmake")
            set(qjs_DIR "${_quickjs_config_dir}" CACHE PATH "Path to qjsConfig.cmake")
        endif()
    endif()
endif()

find_package(qjs CONFIG REQUIRED)

function(promote_imported_target target_name)
    if(TARGET ${target_name})
        get_target_property(_is_imported ${target_name} IMPORTED)
        if(_is_imported)
            set_property(TARGET ${target_name} PROPERTY IMPORTED_GLOBAL TRUE)
        endif()
    endif()
endfunction()

promote_imported_target(nlohmann_json::nlohmann_json)
promote_imported_target(qjs)
promote_imported_target(qjs::qjs)

if(TARGET nlohmann_json::nlohmann_json AND NOT TARGET nlohmann_json)
    add_library(nlohmann_json INTERFACE)
    target_link_libraries(nlohmann_json INTERFACE nlohmann_json::nlohmann_json)
endif()

if(TARGET qjs AND NOT TARGET quickjs::quickjs)
    add_library(quickjs::quickjs ALIAS qjs)
elseif(TARGET qjs::qjs AND NOT TARGET quickjs::quickjs)
    add_library(quickjs::quickjs ALIAS qjs::qjs)
endif()

add_library(miniaudio INTERFACE)
target_include_directories(miniaudio SYSTEM INTERFACE ${WESCENE_THIRD_PARTY_DIR}/miniaudio)

# stb_vorbis 1.22 (public domain or MIT, unchanged): the Ogg Vorbis decoder behind
# scene sounds (Renderer/Sound/Vorbis). It decodes from memory with the pull API
# only, so the stdio and push-data parts are compiled out; the same definitions
# reach every user of the header-only declarations.
add_library(stb_vorbis STATIC ${WESCENE_THIRD_PARTY_DIR}/stb_vorbis/stb_vorbis.c)
target_compile_definitions(stb_vorbis PUBLIC STB_VORBIS_NO_STDIO STB_VORBIS_NO_PUSHDATA_API)
target_include_directories(stb_vorbis SYSTEM PUBLIC ${WESCENE_THIRD_PARTY_DIR}/stb_vorbis)
# Vendored code is built as shipped: its warnings are not ours to fix.
target_compile_options(stb_vorbis PRIVATE -w)
set_property(TARGET stb_vorbis PROPERTY POSITION_INDEPENDENT_CODE ON)
