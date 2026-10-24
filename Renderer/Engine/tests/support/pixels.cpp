#include "support/pixels.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>

namespace we_test
{
namespace
{

std::string Hex(Rgba value)
{
    char text[32];
    std::snprintf(text, sizeof(text), "(%u,%u,%u,%u)", value[0], value[1], value[2], value[3]);
    return text;
}

std::string Average(const std::array<double, 4>& value)
{
    char text[64];
    std::snprintf(text, sizeof(text), "(%.2f,%.2f,%.2f,%.2f)", value[0], value[1], value[2],
                  value[3]);
    return text;
}

// CRC-32 and Adler-32, the two checksums a PNG with a zlib stream needs.
uint32_t Crc32(const uint8_t* data, std::size_t size, uint32_t crc = 0)
{
    static const auto table = [] {
        std::array<uint32_t, 256> entries {};
        for (uint32_t n = 0; n < 256; ++n) {
            uint32_t c = n;
            for (int k = 0; k < 8; ++k) c = (c & 1u) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            entries[n] = c;
        }
        return entries;
    }();
    crc = ~crc;
    for (std::size_t i = 0; i < size; ++i) crc = table[(crc ^ data[i]) & 0xFFu] ^ (crc >> 8);
    return ~crc;
}

uint32_t Adler32(const std::vector<uint8_t>& data)
{
    uint32_t a = 1, b = 0;
    for (uint8_t byte : data) {
        a = (a + byte) % 65521u;
        b = (b + a) % 65521u;
    }
    return (b << 16) | a;
}

void PutBigEndian(std::string& out, uint32_t value)
{
    for (int shift = 24; shift >= 0; shift -= 8) out.push_back(static_cast<char>(value >> shift));
}

void PutChunk(std::string& out, const char (&type)[5], const std::string& body)
{
    PutBigEndian(out, static_cast<uint32_t>(body.size()));
    std::string typed(type, 4);
    typed += body;
    out += typed;
    PutBigEndian(out, Crc32(reinterpret_cast<const uint8_t*>(typed.data()), typed.size()));
}

} // namespace

Rgba Image::At(uint32_t x, uint32_t y) const
{
    const std::size_t at = (static_cast<std::size_t>(y) * width + x) * 4;
    return { rgba[at], rgba[at + 1], rgba[at + 2], rgba[at + 3] };
}

void Image::Set(uint32_t x, uint32_t y, Rgba value)
{
    const std::size_t at = (static_cast<std::size_t>(y) * width + x) * 4;
    std::copy(value.begin(), value.end(), rgba.begin() + static_cast<std::ptrdiff_t>(at));
}

Image Image::Solid(uint32_t width, uint32_t height, Rgba value)
{
    Image image { width, height, std::vector<uint8_t>(static_cast<std::size_t>(width) * height * 4) };
    for (uint32_t y = 0; y < height; ++y) {
        for (uint32_t x = 0; x < width; ++x) image.Set(x, y, value);
    }
    return image;
}

Image Image::Quadrants(uint32_t width, uint32_t height, Rgba top_left, Rgba top_right,
                       Rgba bottom_left, Rgba bottom_right)
{
    Image image = Solid(width, height, top_left);
    for (uint32_t y = 0; y < height; ++y) {
        for (uint32_t x = 0; x < width; ++x) {
            const bool right  = x >= width / 2;
            const bool bottom = y >= height / 2;
            image.Set(x, y,
                      bottom ? (right ? bottom_right : bottom_left)
                             : (right ? top_right : top_left));
        }
    }
    return image;
}

std::array<double, 4> RegionAverage(const Image& image, uint32_t x, uint32_t y, uint32_t width,
                                    uint32_t height)
{
    std::array<double, 4> sum {};
    uint64_t              count = 0;
    const uint32_t        x_end = std::min(image.width, x + width);
    const uint32_t        y_end = std::min(image.height, y + height);
    for (uint32_t row = y; row < y_end; ++row) {
        for (uint32_t column = x; column < x_end; ++column) {
            const Rgba pixel = image.At(column, row);
            for (int c = 0; c < 4; ++c) sum[static_cast<std::size_t>(c)] += pixel[static_cast<std::size_t>(c)];
            ++count;
        }
    }
    if (count == 0) return sum;
    for (double& lane : sum) lane /= static_cast<double>(count);
    return sum;
}

int MaxChannelDifference(const Image& a, const Image& b)
{
    if (a.width != b.width || a.height != b.height || a.rgba.size() != b.rgba.size()) return 256;
    int most = 0;
    for (std::size_t i = 0; i < a.rgba.size(); ++i) {
        most = std::max(most, std::abs(static_cast<int>(a.rgba[i]) - static_cast<int>(b.rgba[i])));
    }
    return most;
}

std::size_t CountDifferingPixels(const Image& a, const Image& b, int tolerance)
{
    if (a.width != b.width || a.height != b.height || a.rgba.size() != b.rgba.size()) {
        return std::max<std::size_t>(static_cast<std::size_t>(a.width) * a.height,
                                     static_cast<std::size_t>(b.width) * b.height);
    }
    std::size_t count = 0;
    for (std::size_t pixel = 0; pixel < a.rgba.size() / 4; ++pixel) {
        for (std::size_t c = 0; c < 4; ++c) {
            const std::size_t at = pixel * 4 + c;
            if (std::abs(static_cast<int>(a.rgba[at]) - static_cast<int>(b.rgba[at])) > tolerance) {
                ++count;
                break;
            }
        }
    }
    return count;
}

::testing::AssertionResult ExpectPixel(const Image& image, uint32_t x, uint32_t y, Rgba expected,
                                       int tolerance)
{
    if (x >= image.width || y >= image.height) {
        return ::testing::AssertionFailure()
               << "pixel (" << x << "," << y << ") is outside the " << image.width << "x"
               << image.height << " picture";
    }
    const Rgba actual = image.At(x, y);
    for (std::size_t c = 0; c < 4; ++c) {
        if (std::abs(static_cast<int>(actual[c]) - static_cast<int>(expected[c])) > tolerance) {
            return ::testing::AssertionFailure()
                   << "pixel (" << x << "," << y << ") of " << image.width << "x" << image.height
                   << " is " << Hex(actual) << ", expected " << Hex(expected) << " (tolerance "
                   << tolerance << ")";
        }
    }
    return ::testing::AssertionSuccess();
}

::testing::AssertionResult ExpectRegionAverage(const Image& image, uint32_t x, uint32_t y,
                                               uint32_t width, uint32_t height, Rgba expected,
                                               double tolerance)
{
    if (x >= image.width || y >= image.height) {
        return ::testing::AssertionFailure() << "region origin (" << x << "," << y
                                             << ") is outside the picture";
    }
    const auto average = RegionAverage(image, x, y, width, height);
    for (std::size_t c = 0; c < 4; ++c) {
        if (std::abs(average[c] - expected[c]) > tolerance) {
            return ::testing::AssertionFailure()
                   << "region " << width << "x" << height << " at (" << x << "," << y
                   << ") averages " << Average(average) << ", expected " << Hex(expected)
                   << " (tolerance " << tolerance << ")";
        }
    }
    return ::testing::AssertionSuccess();
}

std::string DescribeDifference(const Image& actual, const Image& expected, int tolerance)
{
    std::ostringstream text;
    if (actual.width != expected.width || actual.height != expected.height) {
        text << "sizes differ: " << actual.width << "x" << actual.height << " against "
             << expected.width << "x" << expected.height;
        return text.str();
    }
    const std::size_t differing = CountDifferingPixels(actual, expected, tolerance);
    if (differing == 0) return "identical";
    for (uint32_t y = 0; y < actual.height; ++y) {
        for (uint32_t x = 0; x < actual.width; ++x) {
            const Rgba a = actual.At(x, y);
            const Rgba b = expected.At(x, y);
            for (std::size_t c = 0; c < 4; ++c) {
                if (std::abs(static_cast<int>(a[c]) - static_cast<int>(b[c])) > tolerance) {
                    text << differing << " of " << static_cast<std::size_t>(actual.width) * actual.height
                         << " pixels differ by more than " << tolerance << "; first at (" << x << ","
                         << y << "): " << Hex(a) << " against " << Hex(b)
                         << "; largest channel difference " << MaxChannelDifference(actual, expected);
                    return text.str();
                }
            }
        }
    }
    return "identical";
}

::testing::AssertionResult ExpectSamePicture(const Image& actual, const Image& expected,
                                             int tolerance)
{
    if (actual.width == expected.width && actual.height == expected.height &&
        CountDifferingPixels(actual, expected, tolerance) == 0) {
        return ::testing::AssertionSuccess();
    }
    return ::testing::AssertionFailure() << DescribeDifference(actual, expected, tolerance);
}

bool KeepPicture(const std::string& name, const Image& image)
{
    const char* directory = std::getenv("WE_TEST_KEEP_PICTURES");
    if (directory == nullptr || *directory == '\0' || image.empty()) return false;
    std::error_code error;
    std::filesystem::create_directories(directory, error);
    std::ofstream out(std::filesystem::path(directory) / (name + ".png"), std::ios::binary);
    if (!out) return false;
    const std::string png = EncodePng(image);
    out.write(png.data(), static_cast<std::streamsize>(png.size()));
    return out.good();
}

std::string EncodePng(const Image& image)
{
    std::string png("\x89PNG\r\n\x1a\n", 8);

    std::string header;
    PutBigEndian(header, image.width);
    PutBigEndian(header, image.height);
    header += std::string("\x08\x06\x00\x00\x00", 5); // 8 bits, RGBA, no interlace
    PutChunk(png, "IHDR", header);

    // Each row starts with a filter byte; filter 0 leaves the bytes as they are.
    std::vector<uint8_t> raw;
    raw.reserve((static_cast<std::size_t>(image.width) * 4 + 1) * image.height);
    for (uint32_t y = 0; y < image.height; ++y) {
        raw.push_back(0);
        const auto row = image.rgba.begin() + static_cast<std::ptrdiff_t>(static_cast<std::size_t>(y) * image.width * 4);
        raw.insert(raw.end(), row, row + static_cast<std::ptrdiff_t>(image.width) * 4);
    }

    // A zlib stream of uncompressed ("stored") deflate blocks.
    std::string zlib("\x78\x01", 2);
    std::size_t offset = 0;
    do {
        const std::size_t length = std::min<std::size_t>(65535, raw.size() - offset);
        const bool        last   = offset + length == raw.size();
        zlib.push_back(last ? 1 : 0);
        zlib.push_back(static_cast<char>(length & 0xFF));
        zlib.push_back(static_cast<char>(length >> 8));
        zlib.push_back(static_cast<char>(~length & 0xFF));
        zlib.push_back(static_cast<char>((~length >> 8) & 0xFF));
        zlib.append(reinterpret_cast<const char*>(raw.data()) + offset, length);
        offset += length;
    } while (offset < raw.size());
    PutBigEndian(zlib, Adler32(raw));
    PutChunk(png, "IDAT", zlib);
    PutChunk(png, "IEND", "");
    return png;
}

} // namespace we_test
