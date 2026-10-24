#pragma once

// Scratch-folder and compiler-presence helpers shared by the shader behaviour tests.

#include <gtest/gtest.h>

#include <unistd.h>

#include <filesystem>
#include <fstream>
#include <iterator>
#include <sstream>
#include <string>

namespace wallpaper::shader_test
{

// A folder under the system temp directory named after the running test and this
// process. Cleared when created and again when the object goes away.
class ScratchFolder {
public:
    ScratchFolder() {
        const auto* info = ::testing::UnitTest::GetInstance()->current_test_info();
        std::ostringstream name;
        name << "wm-shader-" << info->test_suite_name() << "-" << info->name() << "-" << ::getpid();
        m_path = std::filesystem::temp_directory_path() / name.str();
        Wipe();
        std::filesystem::create_directories(m_path);
    }
    ScratchFolder(const ScratchFolder&)            = delete;
    ScratchFolder& operator=(const ScratchFolder&) = delete;
    ~ScratchFolder() { Wipe(); }

    const std::filesystem::path& path() const { return m_path; }
    std::filesystem::path        sub(const std::string& relative) const { return m_path / relative; }

private:
    void Wipe() {
        std::error_code ignored;
        std::filesystem::remove_all(m_path, ignored);
    }
    std::filesystem::path m_path;
};

inline void WriteFile(const std::filesystem::path& path, const std::string& text) {
    std::filesystem::create_directories(path.parent_path());
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    out << text;
}

inline std::string ReadFile(const std::filesystem::path& path) {
    std::ifstream in(path, std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
}

inline std::size_t CountOccurrences(const std::string& text, const std::string& needle) {
    std::size_t count = 0;
    for (std::size_t at = text.find(needle); at != std::string::npos; at = text.find(needle, at + needle.size())) {
        ++count;
    }
    return count;
}

} // namespace wallpaper::shader_test

// The shipped renderer always links the shader compiler, so a build without it
// has to fail loudly instead of passing by skipping.
#ifdef WESCENE_HAS_RUST_SHADER_FFI
#define REQUIRE_LINKED_COMPILER() static_cast<void>(0)
#else
#define REQUIRE_LINKED_COMPILER() \
    FAIL() << "the Rust shader compiler is not linked into this test binary (WESCENE_HAS_RUST_SHADER_FFI is undefined)"
#endif
