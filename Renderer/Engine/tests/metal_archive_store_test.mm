// The pipeline archive keeps one store per directory, with at most eight open at once. What the
// archive queue completes later (adding a compiled pipeline, publishing the file) must never
// bring an evicted store back, and must never touch a store that was opened again under the same
// directory after the one it was captured for was let go.
//
// The queue the completions run on is held back by the test, so "later" is a point in the test
// rather than a race. Everything is a private object of the default Metal device; archive files
// go to the system temp directory.
#include "support/gpu_scene.hpp"

#include "MetalRender/MetalRender.hpp"

#include <gtest/gtest.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <string>
#include <thread>
#include <vector>

#include <unistd.h>

using wallpaper::metal::MetalRender;
namespace disk = std::filesystem;

namespace
{

constexpr std::size_t kStoreBound = 8;

/// A fresh pipeline for every call, process-wide: the pipeline cache is keyed by it.
uint32_t NextVariant()
{
    static std::atomic<uint32_t> next { 1 };
    return next.fetch_add(1);
}

/// Archive directories under the system temp directory, removed with the object.
class Roots {
public:
    Roots()
    {
        static std::atomic<int> serial { 0 };
        base_ = disk::temp_directory_path() /
                ("wm-archive-store-test-" + std::to_string(::getpid()) + "-" + std::to_string(serial.fetch_add(1)));
        disk::create_directories(base_);
    }
    ~Roots()
    {
        std::error_code ignored;
        disk::remove_all(base_, ignored);
    }
    Roots(const Roots&)            = delete;
    Roots& operator=(const Roots&) = delete;

    [[nodiscard]] std::string At(int index) const { return (base_ / ("store" + std::to_string(index))).string(); }

private:
    disk::path base_;
};

/// Holds the archive queue for as long as it lives, and always lets it go.
class QueueHold {
public:
    QueueHold() { MetalRender::SuspendPipelineArchiveQueueForTests(true); }
    ~QueueHold() { Release(); }
    QueueHold(const QueueHold&)            = delete;
    QueueHold& operator=(const QueueHold&) = delete;
    void Release()
    {
        if (!released_) MetalRender::SuspendPipelineArchiveQueueForTests(false);
        released_ = true;
    }

private:
    bool released_ { false };
};

/// Opens `count` stores, `first` upwards, each with one pipeline.
void OpenStores(const Roots& roots, int first, int count)
{
    for (int index = first; index < first + count; ++index) {
        ASSERT_TRUE(MetalRender::BuildArchivedPipelineForTests(roots.At(index), NextVariant()))
            << "store " << index;
    }
}

} // namespace

TEST(MetalArchiveStores, AnEvictedStoreIsNotRevivedByItsLateCompletion)
{
    WE_SKIP_WITHOUT_METAL();
    Roots roots;
    {
        QueueHold hold;
        // Store 0's compile has finished; its addition to the archive waits on the held queue.
        OpenStores(roots, 0, 1);
        // Eight more stores push store 0 out.
        OpenStores(roots, 1, kStoreBound);
        ASSERT_FALSE(MetalRender::PipelineArchiveStoreForTests(roots.At(0)).open) << "store 0 is evicted by the ninth";
        ASSERT_LE(MetalRender::PipelineArchiveResidencyForTests().stores, kStoreBound);
        hold.Release();
        MetalRender::WaitForPipelineArchiveWritesForTests();
    }
    const auto residency = MetalRender::PipelineArchiveResidencyForTests();
    EXPECT_LE(residency.stores, kStoreBound) << "a late completion must not open a store again";
    EXPECT_LE(residency.generation_records, residency.stores) << "a record exists only for an open store";
    EXPECT_FALSE(MetalRender::PipelineArchiveStoreForTests(roots.At(0)).open);
    for (int index = 1; index <= static_cast<int>(kStoreBound); ++index) {
        const auto store = MetalRender::PipelineArchiveStoreForTests(roots.At(index));
        EXPECT_TRUE(store.open) << "store " << index;
        EXPECT_EQ(store.descriptors, 1u) << "store " << index << " keeps its own pipeline";
    }
}

TEST(MetalArchiveStores, ManyEvictionsKeepTheBookkeepingWithinTheBound)
{
    WE_SKIP_WITHOUT_METAL();
    Roots roots;
    {
        QueueHold hold;
        // Three times the bound, all completing late.
        OpenStores(roots, 0, static_cast<int>(kStoreBound) * 3);
        hold.Release();
        MetalRender::WaitForPipelineArchiveWritesForTests();
    }
    const auto residency = MetalRender::PipelineArchiveResidencyForTests();
    EXPECT_LE(residency.stores, kStoreBound);
    EXPECT_LE(residency.generation_records, residency.stores);
    for (int index = 0; index < static_cast<int>(kStoreBound) * 2; ++index) {
        EXPECT_FALSE(MetalRender::PipelineArchiveStoreForTests(roots.At(index)).open) << "store " << index;
    }
}

TEST(MetalArchiveStores, AnOldCompletionDoesNotFeedAStoreOpenedAgainUnderTheSamePath)
{
    WE_SKIP_WITHOUT_METAL();
    Roots roots;
    MetalRender::ArchiveStoreState reopened;
    {
        QueueHold hold;
        OpenStores(roots, 0, 1);
        const auto first = MetalRender::PipelineArchiveStoreForTests(roots.At(0));
        ASSERT_TRUE(first.open);
        OpenStores(roots, 1, kStoreBound); // store 0 goes
        ASSERT_FALSE(MetalRender::PipelineArchiveStoreForTests(roots.At(0)).open);
        OpenStores(roots, 0, 1); // and comes back as a new store, with a pipeline of its own
        reopened = MetalRender::PipelineArchiveStoreForTests(roots.At(0));
        ASSERT_TRUE(reopened.open);
        ASSERT_NE(reopened.collector, first.collector) << "a reopened store has a collector of its own";
        ASSERT_NE(reopened.identity, first.identity);
        hold.Release();
        MetalRender::WaitForPipelineArchiveWritesForTests();
    }
    const auto after = MetalRender::PipelineArchiveStoreForTests(roots.At(0));
    ASSERT_TRUE(after.open);
    EXPECT_EQ(after.descriptors, 1u) << "only the pipeline compiled for this store belongs to it";
    EXPECT_EQ(after.collector, reopened.collector) << "an old completion does not replace the collector";
    EXPECT_EQ(after.identity, reopened.identity);
    const auto residency = MetalRender::PipelineArchiveResidencyForTests();
    EXPECT_LE(residency.stores, kStoreBound);
    EXPECT_LE(residency.generation_records, residency.stores);
}

TEST(MetalArchiveStores, AnOldScheduledWriteDoesNotPublishAStoreOpenedAgain)
{
    WE_SKIP_WITHOUT_METAL();
    Roots roots;
    {
        // Store 0's addition completes and its write is scheduled (the archive waits a moment
        // to gather a burst of additions into one file).
        OpenStores(roots, 0, 1);
        std::this_thread::sleep_for(std::chrono::milliseconds(300));
        QueueHold hold;
        OpenStores(roots, 1, kStoreBound); // store 0 goes
        OpenStores(roots, 0, 1);           // and comes back; store 1 goes
        // The old write's moment comes while the queue is held, so it runs after the new
        // store's own addition has completed, which is when it would be mistaken for it.
        std::this_thread::sleep_for(std::chrono::milliseconds(2300));
        hold.Release();
        MetalRender::WaitForPipelineArchiveWritesForTests();
    }
    const auto store = MetalRender::PipelineArchiveStoreForTests(roots.At(0));
    ASSERT_TRUE(store.open);
    EXPECT_EQ(store.descriptors, 1u);
    EXPECT_EQ(store.writes, 1u) << "the new store is published once, by the write made for it";
    EXPECT_LE(MetalRender::PipelineArchiveResidencyForTests().stores, kStoreBound);
}
