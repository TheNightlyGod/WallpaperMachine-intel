set(LIB_NAME wpUtils)

add_library(${LIB_NAME}
STATIC
Logging.cpp
Algorism.cpp	
Linalg.cpp
Sha.cpp
)

target_link_libraries(${LIB_NAME}
PRIVATE
)
target_include_directories(${LIB_NAME} PUBLIC include)
target_compile_options(${LIB_NAME} PRIVATE ${warn_opts})
set_property(TARGET ${LIB_NAME} PROPERTY POSITION_INDEPENDENT_CODE ON)
