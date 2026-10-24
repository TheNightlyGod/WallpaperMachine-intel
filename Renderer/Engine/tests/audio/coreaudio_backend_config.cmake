if(NOT DEFINED HEADER)
    message(FATAL_ERROR "HEADER must point to miniaudio-wrapper.hpp")
endif()

file(READ "${HEADER}" HEADER_CONTENT)

if(HEADER_CONTENT MATCHES "#[ \t]*define[ \t]+MA_NO_COREAUDIO")
    message(FATAL_ERROR "miniaudio CoreAudio backend must not be disabled on macOS")
endif()
