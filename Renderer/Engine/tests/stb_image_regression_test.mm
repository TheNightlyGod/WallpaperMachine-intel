#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>

#include <gtest/gtest.h>
#include "TestRequire.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <iostream>
#include <unordered_set>
#include <vector>

extern "C" unsigned char* stb_test_decode_scalar(const unsigned char*, int, int*, int*);
extern "C" unsigned char* stb_test_decode_neon(const unsigned char*, int, int*, int*);

namespace {
struct Allocations {
    size_t calls {0};
    size_t fail_at {std::numeric_limits<size_t>::max()};
    bool failed {false};
    std::unordered_set<void*> live;
};
thread_local Allocations* allocations = nullptr;
struct AllocationScope {
    explicit AllocationScope(Allocations& state) : previous(allocations) { allocations = &state; }
    ~AllocationScope() { allocations = previous; }
    Allocations* previous;
};

bool RefuseAllocation() {
    if (allocations == nullptr) return false;
    if (allocations->calls++ != allocations->fail_at) return false;
    allocations->failed = true;
    return true;
}
void* ImageMalloc(size_t size) {
    if (RefuseAllocation()) return nullptr;
    void* pointer = std::malloc(size);
    if (allocations != nullptr && pointer != nullptr) allocations->live.insert(pointer);
    return pointer;
}
void ImageFree(void* pointer) {
    if (pointer == nullptr) return;
    if (allocations != nullptr) EXPECT_EQ(allocations->live.erase(pointer), 1u);
    std::free(pointer);
}
void* ImageRealloc(void* pointer, size_t size) {
    if (RefuseAllocation()) return nullptr;
    void* result = std::realloc(pointer, size);
    if (allocations != nullptr && result != nullptr) {
        if (pointer != nullptr) EXPECT_EQ(allocations->live.erase(pointer), 1u);
        allocations->live.insert(result);
    }
    return result;
}
} // namespace

#define STB_IMAGE_STATIC
#define STBI_MALLOC ImageMalloc
#define STBI_REALLOC ImageRealloc
#define STBI_FREE ImageFree
#define STB_IMAGE_IMPLEMENTATION
#include <stb_image.h>

namespace {
using Bytes = std::vector<uint8_t>;

Bytes EncodeImage(CFStringRef format, int depth, size_t width = 4, size_t height = 3) {
    Bytes pixels(width * height * 4 * (depth / 8));
    for (size_t index = 0; index < width * height; ++index) {
        const std::array<uint16_t, 4> color {
            static_cast<uint16_t>(0x1000 + index * 0x111),
            static_cast<uint16_t>(0x5000 + index * 0x123),
            static_cast<uint16_t>(0x9000 + index * 0x101), 0xffff,
        };
        for (size_t channel = 0; channel < 4; ++channel) {
            if (depth == 16) std::memcpy(pixels.data() + (index * 4 + channel) * 2, &color[channel], 2);
            else pixels[index * 4 + channel] = static_cast<uint8_t>(color[channel] >> 8);
        }
    }
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGDataProviderRef provider = CGDataProviderCreateWithData(nullptr, pixels.data(), pixels.size(), nullptr);
    const auto info = static_cast<CGBitmapInfo>(kCGImageAlphaLast) |
                      static_cast<CGBitmapInfo>(depth == 16 ? kCGBitmapByteOrder16Little : kCGBitmapByteOrderDefault);
    CGImageRef image = CGImageCreate(width, height, depth, depth * 4, width * 4 * (depth / 8),
                                     space, info, provider, nullptr, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(space);
    REQUIRE(image != nullptr);
    CFMutableDataRef data = CFDataCreateMutable(kCFAllocatorDefault, 0);
    CGImageDestinationRef destination = CGImageDestinationCreateWithData(data, format, 1, nullptr);
    REQUIRE(destination != nullptr);
    CGImageDestinationAddImage(destination, image, nullptr);
    const bool encoded = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    CGImageRelease(image);
    Bytes bytes(CFDataGetBytePtr(data), CFDataGetBytePtr(data) + CFDataGetLength(data));
    CFRelease(data);
    REQUIRE(encoded);
    return bytes;
}

template<typename Decode>
void CheckEveryAllocation(const Bytes& bytes, Decode decode) {
    Allocations state;
    AllocationScope scope(state);
    int width = 0, height = 0, channels = 0;
    void* result = decode(bytes, &width, &height, &channels);
    ASSERT_NE(result, nullptr) << stbi_failure_reason();
    EXPECT_EQ(width, 4); EXPECT_EQ(height, 3);
    stbi_image_free(result);
    ASSERT_TRUE(state.live.empty());
    const size_t allocation_count = state.calls;
    ASSERT_GT(allocation_count, 0u);
    for (size_t failure = 0; failure < allocation_count; ++failure) {
        SCOPED_TRACE(failure);
        state.calls = 0;
        state.fail_at = failure;
        state.failed = false;
        result = decode(bytes, &width, &height, &channels);
        if (result != nullptr) stbi_image_free(result);
        EXPECT_TRUE(state.failed);
        EXPECT_TRUE(state.live.empty()) << "image allocations survive failure " << failure;
        // Cleanup only the test allocator's own outstanding pointers after a
        // failed assertion, so later cases remain isolated.
        for (void* leaked : state.live) std::free(leaked);
        state.live.clear();
    }
}

TEST(StbImageRegression, ValidJpegReturnsCleanlyAtEachAllocationFailure) {
    const auto jpeg = EncodeImage(CFSTR("public.jpeg"), 8);
    CheckEveryAllocation(jpeg, [](const Bytes& b, int* w, int* h, int* c) -> void* {
        return stbi_load_from_memory(b.data(), static_cast<int>(b.size()), w, h, c, 4);
    });
    Allocations state;
    state.fail_at = 0;
    AllocationScope scope(state);
    int w = 0, h = 0, c = 0;
    EXPECT_EQ(stbi_info_from_memory(jpeg.data(), static_cast<int>(jpeg.size()), &w, &h, &c), 0);
    EXPECT_TRUE(state.failed);
    EXPECT_TRUE(state.live.empty());
}

TEST(StbImageRegression, BitDepthConversionFailuresReleaseInputBeforeOptionalFlip) {
    const auto png8 = EncodeImage(CFSTR("public.png"), 8);
    const auto png16 = EncodeImage(CFSTR("public.png"), 16);
    ASSERT_TRUE(stbi_is_16_bit_from_memory(png16.data(), static_cast<int>(png16.size())));
    stbi_set_flip_vertically_on_load(1);
    CheckEveryAllocation(png16, [](const Bytes& b, int* w, int* h, int* c) -> void* {
        return stbi_load_from_memory(b.data(), static_cast<int>(b.size()), w, h, c, 4);
    });
    CheckEveryAllocation(png8, [](const Bytes& b, int* w, int* h, int* c) -> void* {
        return stbi_load_16_from_memory(b.data(), static_cast<int>(b.size()), w, h, c, 4);
    });
    stbi_set_flip_vertically_on_load(0);
}

Bytes Bmp(int depth) {
    constexpr size_t stride = 8;
    Bytes bytes(54 + stride * 2, 0);
    const auto u16 = [&](size_t offset, uint16_t value) { bytes[offset] = value; bytes[offset + 1] = value >> 8; };
    const auto u32 = [&](size_t offset, uint32_t value) {
        for (int byte = 0; byte < 4; ++byte) bytes[offset + byte] = value >> (byte * 8);
    };
    bytes[0] = 'B'; bytes[1] = 'M';
    u32(2, static_cast<uint32_t>(bytes.size())); u32(10, 54); u32(14, 40);
    u32(18, 2); u32(22, 2); u16(26, 1); u16(28, static_cast<uint16_t>(depth)); u32(34, stride * 2);
    for (size_t y = 0; y < 2; ++y) for (size_t x = 0; x < 2; ++x) {
        const size_t offset = 54 + y * stride + x * (depth / 8);
        bytes[offset] = static_cast<uint8_t>(30 + x * 90);
        bytes[offset + 1] = static_cast<uint8_t>(50 + y * 100);
        bytes[offset + 2] = 220;
        if (depth == 32) bytes[offset + 3] = 255;
    }
    return bytes;
}

TEST(StbImageRegression, BmpFileMemoryAndCallbacksReturnIdenticalPixels) {
    struct Reader { const Bytes& bytes; size_t offset {0}; };
    const stbi_io_callbacks callbacks {
        [](void* user, char* out, int count) {
            auto& reader = *static_cast<Reader*>(user);
            const auto copied = std::min(static_cast<size_t>(count), reader.bytes.size() - reader.offset);
            std::memcpy(out, reader.bytes.data() + reader.offset, copied);
            reader.offset += copied;
            return static_cast<int>(copied);
        },
        [](void* user, int count) {
            auto& reader = *static_cast<Reader*>(user);
            reader.offset = static_cast<size_t>(std::clamp<int64_t>(int64_t(reader.offset) + count, 0, reader.bytes.size()));
        },
        [](void* user) -> int { const auto& reader = *static_cast<Reader*>(user); return reader.offset == reader.bytes.size(); },
    };
    for (const int depth : {24, 32}) {
        SCOPED_TRACE(depth);
        const auto bytes = Bmp(depth);
        int w = 0, h = 0, c = 0;
        auto* memory = stbi_load_from_memory(bytes.data(), static_cast<int>(bytes.size()), &w, &h, &c, 4);
        ASSERT_NE(memory, nullptr) << stbi_failure_reason();
        ASSERT_EQ(w, 2); ASSERT_EQ(h, 2);
        const Bytes expected(memory, memory + w * h * 4);
        stbi_image_free(memory);
        EXPECT_EQ(expected, (Bytes {220, 150, 30, 255, 220, 150, 120, 255,
                                   220, 50, 30, 255, 220, 50, 120, 255}));
        Reader reader {bytes};
        auto* callback = stbi_load_from_callbacks(&callbacks, &reader, &w, &h, &c, 4);
        ASSERT_NE(callback, nullptr) << stbi_failure_reason();
        EXPECT_EQ(Bytes(callback, callback + w * h * 4), expected);
        stbi_image_free(callback);
        FILE* file = std::tmpfile();
        ASSERT_NE(file, nullptr);
        ASSERT_EQ(std::fwrite(bytes.data(), 1, bytes.size(), file), bytes.size());
        std::rewind(file);
        auto* disk = stbi_load_from_file(file, &w, &h, &c, 4);
        std::fclose(file);
        ASSERT_NE(disk, nullptr) << stbi_failure_reason();
        EXPECT_EQ(Bytes(disk, disk + w * h * 4), expected);
        stbi_image_free(disk);
    }
}

TEST(StbImageRegression, Arm64NeonJpegPixelsMatchTheScalarDecoder) {
#if !defined(__aarch64__) && !defined(__arm64__)
    GTEST_SKIP() << "NEON comparison requires arm64";
#endif
    for (const auto [width, height] : {std::pair {31, 17}, std::pair {640, 360}, std::pair {1920, 1080}}) {
        const auto jpeg = EncodeImage(CFSTR("public.jpeg"), 8, width, height);
        int sw = 0, sh = 0, nw = 0, nh = 0;
        auto* scalar = stb_test_decode_scalar(jpeg.data(), static_cast<int>(jpeg.size()), &sw, &sh);
        auto* neon = stb_test_decode_neon(jpeg.data(), static_cast<int>(jpeg.size()), &nw, &nh);
        ASSERT_NE(scalar, nullptr); ASSERT_NE(neon, nullptr);
        EXPECT_EQ(sw, width); EXPECT_EQ(sh, height);
        EXPECT_EQ(nw, sw); EXPECT_EQ(nh, sh);
        EXPECT_EQ(std::memcmp(scalar, neon, size_t(width) * height * 4), 0);
        std::free(scalar); std::free(neon);
    }
}

// Explicit-only benchmark: no latency threshold in routine regression runs.
TEST(StbImageRegression, DISABLED_Arm64NeonJpegDecodeBenchmark) {
#if !defined(__aarch64__) && !defined(__arm64__)
    GTEST_SKIP() << "NEON comparison requires arm64";
#endif
    using Decoder = unsigned char* (*)(const unsigned char*, int, int*, int*);
    uint64_t checksum = 0;
    for (const auto [width, height] : {std::pair {320, 180}, std::pair {1280, 720}, std::pair {1920, 1080}}) {
        const auto jpeg = EncodeImage(CFSTR("public.jpeg"), 8, width, height);
        const auto time = [&](Decoder decode) {
            int w = 0, h = 0;
            const auto start = std::chrono::steady_clock::now();
            auto* pixels = decode(jpeg.data(), static_cast<int>(jpeg.size()), &w, &h);
            const double elapsed = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
            REQUIRE(pixels != nullptr && w == width && h == height);
            checksum += pixels[(size_t(width) * height / 2) * 4];
            std::free(pixels);
            return elapsed;
        };
        const double scalar_first = time(stb_test_decode_scalar), neon_first = time(stb_test_decode_neon);
        std::vector<double> scalar, neon;
        for (int repeat = 0; repeat < 12; ++repeat) {
            if (repeat % 2) { neon.push_back(time(stb_test_decode_neon)); scalar.push_back(time(stb_test_decode_scalar)); }
            else { scalar.push_back(time(stb_test_decode_scalar)); neon.push_back(time(stb_test_decode_neon)); }
        }
        std::sort(scalar.begin(), scalar.end()); std::sort(neon.begin(), neon.end());
        std::cout << "{\"width\":" << width << ",\"height\":" << height
                  << ",\"scalar_first_ms\":" << scalar_first << ",\"neon_first_ms\":" << neon_first
                  << ",\"scalar_warm_median_ms\":" << scalar[scalar.size() / 2]
                  << ",\"neon_warm_median_ms\":" << neon[neon.size() / 2] << "}" << std::endl;
    }
    EXPECT_GT(checksum, 0u);
}
} // namespace
