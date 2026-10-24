// The rule that picks a project's preview file: a project may name one, and it
// may not name one outside its own folder.
#include "Surface/PreviewPath.hpp"

#include <gtest/gtest.h>

#include <filesystem>
#include <fstream>
#include <string>
#include <unistd.h>

namespace
{

namespace fs = std::filesystem;
using wallpaper::surface::PickPreviewFile;

class PreviewPathTest : public ::testing::Test {
protected:
    void SetUp() override
    {
        root_ = fs::temp_directory_path() / ("wm-surface-path-" + std::to_string(::getpid()) + "-" +
                                             ::testing::UnitTest::GetInstance()->current_test_info()->name());
        fs::remove_all(root_);
        fs::create_directories(root_ / "project");
        fs::create_directories(root_ / "elsewhere");
    }
    void TearDown() override { fs::remove_all(root_); }

    fs::path Write(const fs::path& path, const std::string& bytes = "x")
    {
        fs::create_directories(path.parent_path());
        std::ofstream(path, std::ios::binary) << bytes;
        return path;
    }

    fs::path root_;
};

TEST_F(PreviewPathTest, ADeclaredFileInsideTheProjectIsTheOneChosen)
{
    Write(root_ / "project/art/cover.png");
    Write(root_ / "project/preview.jpg");
    const auto picked = PickPreviewFile(root_ / "project", "art/cover.png");
    ASSERT_TRUE(picked.has_value());
    EXPECT_EQ(picked->filename(), "cover.png");
}

TEST_F(PreviewPathTest, WithoutADeclaredFileTheConventionalNamesAreTriedInOrder)
{
    Write(root_ / "project/preview.png");
    Write(root_ / "project/preview.gif");
    const auto picked = PickPreviewFile(root_ / "project", "");
    ASSERT_TRUE(picked.has_value());
    EXPECT_EQ(picked->filename(), "preview.png");
}

TEST_F(PreviewPathTest, ADeclaredFileThatDoesNotExistFallsThroughToTheConventionalName)
{
    Write(root_ / "project/preview.jpg");
    const auto picked = PickPreviewFile(root_ / "project", "missing.png");
    ASSERT_TRUE(picked.has_value());
    EXPECT_EQ(picked->filename(), "preview.jpg");
}

TEST_F(PreviewPathTest, ANameThatLeavesTheProjectIsNeverFollowed)
{
    Write(root_ / "elsewhere/secret.png");
    EXPECT_FALSE(PickPreviewFile(root_ / "project", "../elsewhere/secret.png").has_value());
    EXPECT_FALSE(
        PickPreviewFile(root_ / "project", (root_ / "elsewhere/secret.png").string()).has_value());
    // A sibling folder whose name merely starts with the project's is not inside it.
    Write(root_ / "project-evil/preview.png");
    EXPECT_FALSE(PickPreviewFile(root_ / "project", "../project-evil/preview.png").has_value());
}

TEST_F(PreviewPathTest, ASymbolicLinkOutOfTheProjectIsNeverFollowed)
{
    const auto target = Write(root_ / "elsewhere/secret.png");
    fs::create_symlink(target, root_ / "project/preview.png");
    EXPECT_FALSE(PickPreviewFile(root_ / "project", "preview.png").has_value());
    EXPECT_FALSE(PickPreviewFile(root_ / "project", "").has_value());
}

TEST_F(PreviewPathTest, AnEmptyFileAndAnOversizedFileAreNotPreviews)
{
    Write(root_ / "project/preview.jpg", "");
    EXPECT_FALSE(PickPreviewFile(root_ / "project", "").has_value());
    const auto big = root_ / "project/preview.png";
    {
        std::ofstream out(big, std::ios::binary);
        out.seekp(static_cast<std::streamoff>(wallpaper::surface::kMaxPreviewBytes));
        out.put('x');
    }
    EXPECT_FALSE(PickPreviewFile(root_ / "project", "preview.png").has_value());
}

TEST_F(PreviewPathTest, AProjectWithNoPreviewHasNone)
{
    EXPECT_FALSE(PickPreviewFile(root_ / "project", "").has_value());
    EXPECT_FALSE(PickPreviewFile(root_ / "does-not-exist", "preview.png").has_value());
}

} // namespace
