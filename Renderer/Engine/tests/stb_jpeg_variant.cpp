#if defined(STB_TEST_USE_NEON) && (defined(__aarch64__) || defined(__arm64__))
#define STBI_NEON
#else
#define STBI_NO_SIMD
#endif
#define STB_IMAGE_STATIC
#define STB_IMAGE_IMPLEMENTATION
#include <stb_image.h>

extern "C" unsigned char* STB_TEST_DECODE_NAME(const unsigned char* bytes, int length,
                                               int* width, int* height) {
    return stbi_load_from_memory(bytes, length, width, height, nullptr, 4);
}
