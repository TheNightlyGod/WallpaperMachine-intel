// ByteSource: the memory source shares ownership of its bytes, the file source
// reads through a window without ever reading past the end, and both shorten or
// refuse out-of-range requests instead of faulting.
#include "Media/ByteSource.hpp"

#include <gtest/gtest.h>

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <limits>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include <unistd.h>

namespace wallpaper::media
{
namespace
{

std::vector<std::uint8_t> Pattern(std::size_t size)
{
    std::vector<std::uint8_t> bytes(size);
    std::uint32_t state = 12345;
    for (auto& byte : bytes) {
        state = state * 1664525U + 1013904223U;
        byte  = static_cast<std::uint8_t>(state >> 24);
    }
    return bytes;
}

TEST(MemoryByteSource, ReadsRangesAndShortensAtTheEnd)
{
    const auto bytes  = Pattern(100);
    auto       source = MakeMemoryByteSource(bytes);
    EXPECT_EQ(source->size(), 100U);

    std::vector<std::uint8_t> out(20, 0xEE);
    EXPECT_EQ(source->readAt(10, out.data(), 20), 20U);
    EXPECT_EQ(std::vector<std::uint8_t>(bytes.begin() + 10, bytes.begin() + 30), out);

    // Crossing the end copies only what exists and leaves the rest untouched.
    out.assign(20, 0xEE);
    EXPECT_EQ(source->readAt(90, out.data(), 20), 10U);
    EXPECT_EQ(out[9], bytes[99]);
    EXPECT_EQ(out[10], 0xEE);

    EXPECT_EQ(source->readAt(100, out.data(), 20), 0U);
    EXPECT_EQ(source->readAt(std::numeric_limits<std::uint64_t>::max(), out.data(), 20), 0U);
    EXPECT_EQ(source->readAt(0, out.data(), 0), 0U);
    EXPECT_FALSE(source->ioFailed());
}

TEST(MemoryByteSource, ReadExactDistinguishesAShortRead)
{
    auto                      source = MakeMemoryByteSource(Pattern(16));
    std::vector<std::uint8_t> out(32);
    EXPECT_TRUE(ReadExact(*source, 0, out.data(), 16));
    EXPECT_FALSE(ReadExact(*source, 1, out.data(), 16));
    EXPECT_FALSE(ReadExact(*source, 16, out.data(), 1));
}

TEST(MemoryByteSource, ViewLendsBytesOnlyInsideTheInput)
{
    const auto bytes  = Pattern(64);
    auto       source = MakeMemoryByteSource(bytes);
    const std::uint8_t* view = source->view(8, 16);
    ASSERT_NE(view, nullptr);
    EXPECT_EQ(std::vector<std::uint8_t>(view, view + 16),
              std::vector<std::uint8_t>(bytes.begin() + 8, bytes.begin() + 24));
    EXPECT_NE(source->view(0, 64), nullptr);
    EXPECT_NE(source->view(64, 0), nullptr);
    EXPECT_EQ(source->view(60, 8), nullptr);
    EXPECT_EQ(source->view(65, 0), nullptr);
    EXPECT_EQ(source->view(std::numeric_limits<std::uint64_t>::max(), 2), nullptr);
    EXPECT_EQ(source->view(1, std::numeric_limits<std::size_t>::max()), nullptr);
}

TEST(MemoryByteSource, SharesOwnershipSoTheCallerMayDropItsBuffer)
{
    auto buffer = std::make_shared<std::vector<std::uint8_t>>(Pattern(48));
    const std::vector<std::uint8_t> expected = *buffer;
    std::weak_ptr<std::vector<std::uint8_t>> watcher = buffer;

    auto source = MakeMemoryByteSource(buffer, buffer->data(), buffer->size());
    buffer.reset();
    ASSERT_FALSE(watcher.expired()) << "the source must keep the bytes alive";

    std::vector<std::uint8_t> out(48);
    EXPECT_TRUE(ReadExact(*source, 0, out.data(), 48));
    EXPECT_EQ(out, expected);

    source.reset();
    EXPECT_TRUE(watcher.expired()) << "the last owner releases the bytes";
}

TEST(MemoryByteSource, AnAliasedSubrangeIsServedAsWhole)
{
    auto buffer = std::make_shared<std::vector<std::uint8_t>>(Pattern(40));
    auto source = MakeMemoryByteSource(buffer, buffer->data() + 10, 20);
    EXPECT_EQ(source->size(), 20U);
    std::uint8_t first = 0;
    EXPECT_TRUE(ReadExact(*source, 0, &first, 1));
    EXPECT_EQ(first, (*buffer)[10]);
    EXPECT_EQ(source->readAt(19, &first, 5), 1U);
}

TEST(MemoryByteSource, AnEmptySourceIsValid)
{
    auto source = MakeMemoryByteSource(std::vector<std::uint8_t> {});
    EXPECT_EQ(source->size(), 0U);
    std::uint8_t byte = 0;
    EXPECT_EQ(source->readAt(0, &byte, 1), 0U);
    EXPECT_EQ(source->view(0, 0), nullptr);
}

TEST(ReadVector, ReadsExactlyAndRefusesBeforeAllocating)
{
    const auto bytes  = Pattern(256);
    auto       source = MakeMemoryByteSource(bytes);
    std::vector<std::uint8_t> out;
    Error                     error;

    ASSERT_TRUE(ReadVector(*source, 100, 50, 1024, &out, &error));
    EXPECT_EQ(out, std::vector<std::uint8_t>(bytes.begin() + 100, bytes.begin() + 150));

    EXPECT_FALSE(ReadVector(*source, 0, 2000, 1024, &out, &error));
    EXPECT_EQ(error.kind, ErrorKind::LimitExceeded);

    // A length the file cannot hold fails as truncation without allocating it.
    EXPECT_FALSE(ReadVector(*source, 200, 100, 1U << 30, &out, &error));
    EXPECT_EQ(error.kind, ErrorKind::Truncated);
    EXPECT_EQ(error.offset, 200U);
    EXPECT_FALSE(ReadVector(*source, 1, std::numeric_limits<std::uint64_t>::max(), std::numeric_limits<std::uint64_t>::max(), &out, &error));
    EXPECT_EQ(error.kind, ErrorKind::Truncated);
    EXPECT_FALSE(ReadVector(*source, 300, 0, 10, &out, &error));
}

class FileByteSourceTest : public ::testing::Test {
protected:
    void SetUp() override
    {
        std::string pattern = (std::filesystem::temp_directory_path() / "wm-media-XXXXXX").string();
        ASSERT_NE(::mkdtemp(pattern.data()), nullptr);
        m_directory = pattern;
    }

    void TearDown() override
    {
        std::error_code ignored;
        std::filesystem::remove_all(m_directory, ignored);
    }

    std::string write(const std::string& name, const std::vector<std::uint8_t>& bytes)
    {
        const std::string path = (m_directory / name).string();
        std::ofstream     stream(path, std::ios::binary);
        stream.write(reinterpret_cast<const char*>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
        return path;
    }

    std::filesystem::path m_directory;
};

TEST_F(FileByteSourceTest, ReadsEveryOffsetAcrossWindowBoundaries)
{
    const auto  bytes = Pattern(200000);
    const auto  path  = write("a.bin", bytes);
    Error       error;
    auto        source = OpenFileByteSource(path, &error);
    ASSERT_NE(source, nullptr) << Describe(error);
    EXPECT_EQ(source->size(), bytes.size());

    // Short reads straddling the 64 KiB window and the 4 KiB alignment boundaries.
    for (std::uint64_t offset : { 0ULL, 1ULL, 4095ULL, 4096ULL, 65535ULL, 65536ULL, 65537ULL, 131070ULL, 199990ULL }) {
        for (std::size_t length : { std::size_t { 1 }, std::size_t { 7 }, std::size_t { 4096 }, std::size_t { 30000 } }) {
            std::vector<std::uint8_t> out(length, 0xEE);
            const std::size_t         expected = static_cast<std::size_t>(std::min<std::uint64_t>(length, bytes.size() - offset));
            ASSERT_EQ(source->readAt(offset, out.data(), length), expected) << offset << "+" << length;
            ASSERT_TRUE(std::equal(out.begin(), out.begin() + static_cast<std::ptrdiff_t>(expected),
                                   bytes.begin() + static_cast<std::ptrdiff_t>(offset)))
                << offset << "+" << length;
        }
    }
}

TEST_F(FileByteSourceTest, ALongReadBypassesTheWindowAndStaysCorrect)
{
    const auto bytes  = Pattern(300000);
    auto       source = OpenFileByteSource(write("b.bin", bytes), nullptr);
    ASSERT_NE(source, nullptr);
    std::vector<std::uint8_t> out(250000);
    EXPECT_EQ(source->readAt(10, out.data(), out.size()), out.size());
    EXPECT_TRUE(std::equal(out.begin(), out.end(), bytes.begin() + 10));
    // A long read that runs past the end is shortened.
    out.assign(250000, 0);
    EXPECT_EQ(source->readAt(100000, out.data(), out.size()), 200000U);
    EXPECT_TRUE(std::equal(out.begin(), out.begin() + 200000, bytes.begin() + 100000));
}

TEST_F(FileByteSourceTest, ReadsPastTheEndReturnNothing)
{
    auto source = OpenFileByteSource(write("c.bin", Pattern(1000)), nullptr);
    ASSERT_NE(source, nullptr);
    std::uint8_t byte = 0;
    EXPECT_EQ(source->readAt(1000, &byte, 1), 0U);
    EXPECT_EQ(source->readAt(std::numeric_limits<std::uint64_t>::max(), &byte, 1), 0U);
    EXPECT_EQ(source->readAt(0, &byte, 0), 0U);
    EXPECT_EQ(source->view(0, 1), nullptr);
    EXPECT_FALSE(source->ioFailed());
}

TEST_F(FileByteSourceTest, AnEmptyFileOpens)
{
    auto source = OpenFileByteSource(write("empty.bin", {}), nullptr);
    ASSERT_NE(source, nullptr);
    EXPECT_EQ(source->size(), 0U);
    std::uint8_t byte = 0;
    EXPECT_EQ(source->readAt(0, &byte, 1), 0U);
}

TEST_F(FileByteSourceTest, AFileTruncatedWhileOpenShortensTheReadInsteadOfFaulting)
{
    const auto bytes = Pattern(100000);
    const auto path  = write("d.bin", bytes);
    auto       source = OpenFileByteSource(path, nullptr);
    ASSERT_NE(source, nullptr);
    ASSERT_EQ(source->size(), bytes.size());

    ASSERT_EQ(::truncate(path.c_str(), 5000), 0);
    std::vector<std::uint8_t> out(100);
    EXPECT_EQ(source->readAt(4950, out.data(), 100), 50U);
    EXPECT_TRUE(std::equal(out.begin(), out.begin() + 50, bytes.begin() + 4950));
    EXPECT_EQ(source->readAt(90000, out.data(), 100), 0U);
    std::vector<std::uint8_t> big(80000);
    EXPECT_EQ(source->readAt(1000, big.data(), big.size()), 4000U);
    EXPECT_FALSE(source->ioFailed()) << "reaching the end early is not an I/O failure";
}

TEST_F(FileByteSourceTest, OpeningFailsCleanlyForAMissingPathAndForADirectory)
{
    Error error;
    EXPECT_EQ(OpenFileByteSource((m_directory / "missing.bin").string(), &error), nullptr);
    EXPECT_EQ(error.kind, ErrorKind::Io);
    EXPECT_FALSE(error.message.empty());

    error = {};
    EXPECT_EQ(OpenFileByteSource(m_directory.string(), &error), nullptr);
    EXPECT_EQ(error.kind, ErrorKind::Io);
    EXPECT_EQ(OpenFileByteSource("", nullptr), nullptr);
}

TEST_F(FileByteSourceTest, ATinyWindowIsRaisedToAPage)
{
    const auto bytes  = Pattern(20000);
    auto       source = OpenFileByteSource(write("e.bin", bytes), nullptr, 1);
    ASSERT_NE(source, nullptr);
    std::vector<std::uint8_t> out(3000);
    EXPECT_EQ(source->readAt(4000, out.data(), out.size()), out.size());
    EXPECT_TRUE(std::equal(out.begin(), out.end(), bytes.begin() + 4000));
}

TEST_F(FileByteSourceTest, ConcurrentReadersEachSeeTheirOwnBytes)
{
    const auto bytes  = Pattern(500000);
    auto       source = OpenFileByteSource(write("f.bin", bytes), nullptr);
    ASSERT_NE(source, nullptr);
    std::atomic<int> mismatches { 0 };
    std::vector<std::thread> threads;
    for (int worker = 0; worker < 4; ++worker) {
        threads.emplace_back([&, worker] {
            std::uint32_t state = static_cast<std::uint32_t>(worker) * 7919U + 1U;
            std::vector<std::uint8_t> out(5000);
            for (int round = 0; round < 400; ++round) {
                state = state * 1664525U + 1013904223U;
                const std::uint64_t offset = state % (bytes.size() - out.size());
                if (source->readAt(offset, out.data(), 1 + state % out.size()) != 1 + state % out.size() ||
                    ! std::equal(out.begin(), out.begin() + static_cast<std::ptrdiff_t>(1 + state % out.size()),
                                 bytes.begin() + static_cast<std::ptrdiff_t>(offset))) {
                    ++mismatches;
                }
            }
        });
    }
    for (auto& thread : threads) thread.join();
    EXPECT_EQ(mismatches.load(), 0);
}

TEST_F(FileByteSourceTest, ReadVectorOverAFileReportsTruncation)
{
    const auto bytes  = Pattern(1000);
    auto       source = OpenFileByteSource(write("g.bin", bytes), nullptr);
    ASSERT_NE(source, nullptr);
    std::vector<std::uint8_t> out;
    Error                     error;
    ASSERT_TRUE(ReadVector(*source, 990, 10, 100, &out, &error));
    EXPECT_FALSE(ReadVector(*source, 990, 11, 100, &out, &error));
    EXPECT_EQ(error.kind, ErrorKind::Truncated);
}

TEST(SpilledByteSource, ReadsBackWhatItWasGivenAndLeavesNoFile)
{
    const auto directory = std::filesystem::temp_directory_path() / ("wm-spill-" + std::to_string(::getpid()));
    std::filesystem::remove_all(directory);
    std::filesystem::create_directories(directory);
    const char* previous = std::getenv("TMPDIR");
    const std::string saved = previous != nullptr ? previous : "";
    ASSERT_EQ(setenv("TMPDIR", directory.c_str(), 1), 0);

    const auto bytes = Pattern(300000);
    Error      error;
    auto       source = MakeSpilledByteSource(bytes.data(), bytes.size(), &error);
    ASSERT_NE(source, nullptr) << Describe(error);
    EXPECT_EQ(source->size(), bytes.size());
    // Unlinked at once: nothing is visible while it is open.
    EXPECT_TRUE(std::filesystem::is_empty(directory));
    EXPECT_EQ(source->view(0, 10), nullptr);

    std::vector<std::uint8_t> out(bytes.size());
    ASSERT_EQ(source->readAt(0, out.data(), out.size()), out.size());
    EXPECT_EQ(out, bytes);
    std::vector<std::uint8_t> part(1000);
    ASSERT_EQ(source->readAt(123456, part.data(), part.size()), part.size());
    EXPECT_TRUE(std::equal(part.begin(), part.end(), bytes.begin() + 123456));
    EXPECT_EQ(source->readAt(bytes.size() - 4, part.data(), part.size()), 4u);
    EXPECT_EQ(source->readAt(bytes.size(), part.data(), part.size()), 0u);

    // The copy is independent of the buffer it came from.
    auto mutated = bytes;
    std::fill(mutated.begin(), mutated.end(), 0);
    ASSERT_EQ(source->readAt(0, out.data(), 16), 16u);
    EXPECT_TRUE(std::equal(out.begin(), out.begin() + 16, bytes.begin()));

    if (previous != nullptr) setenv("TMPDIR", saved.c_str(), 1);
    else unsetenv("TMPDIR");
    source.reset();
    std::filesystem::remove_all(directory);
}

TEST(SpilledByteSource, AnEmptyPayloadIsAnEmptySourceAndAnUnwritableDirectoryIsAnError)
{
    Error error;
    auto  empty = MakeSpilledByteSource(nullptr, 0, &error);
    ASSERT_NE(empty, nullptr) << Describe(error);
    EXPECT_EQ(empty->size(), 0u);

    const char* previous = std::getenv("TMPDIR");
    const std::string saved = previous != nullptr ? previous : "";
    ASSERT_EQ(setenv("TMPDIR", "/nonexistent-directory-for-wallpaper-machine-tests", 1), 0);
    const auto bytes = Pattern(10);
    EXPECT_EQ(MakeSpilledByteSource(bytes.data(), bytes.size(), &error), nullptr);
    EXPECT_EQ(error.kind, ErrorKind::Io);
    if (previous != nullptr) setenv("TMPDIR", saved.c_str(), 1);
    else unsetenv("TMPDIR");
}

} // namespace
} // namespace wallpaper::media
