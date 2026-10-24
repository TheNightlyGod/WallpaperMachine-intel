#include "RenderCommon/CopyElision.hpp"

#include <algorithm>

using namespace wallpaper::render;

namespace
{

bool ReadsKey(const ElisionPassDesc& pass, const std::string& key)
{
    return std::find(pass.reads.begin(), pass.reads.end(), key) != pass.reads.end();
}

} // namespace

std::vector<CopyElision> wallpaper::render::PlanCopyElision(std::span<const ElisionPassDesc> passes)
{
    std::vector<CopyElision> plan(passes.size(), CopyElision::None);

    for (std::size_t i = 0; i < passes.size(); ++i) {
        const auto& copy = passes[i];
        if (copy.kind != ElisionPassDesc::Kind::Copy) continue;
        if (copy.writes.empty() || copy.reads.size() != 1) continue;
        const auto& destination = copy.writes;
        const auto& source = copy.reads.front();
        if (destination == source) continue;

        bool read_anywhere = false;
        bool source_written_later = false;
        bool destination_written_elsewhere = false;
        bool destination_read_before = false;

        for (std::size_t j = 0; j < passes.size(); ++j) {
            if (j == i) continue;
            const auto& other = passes[j];
            if (ReadsKey(other, destination)) {
                read_anywhere = true;
                // A read placed before the copy consumes whatever the target
                // held beforehand, which after elision is no longer what the
                // copy would have left there.
                if (j < i) destination_read_before = true;
            }
            if (other.writes == destination) destination_written_elsewhere = true;
            if (j > i && other.writes == source) source_written_later = true;
        }

        if (! read_anywhere) {
            plan[i] = CopyElision::Dead;
            continue;
        }
        if (destination_read_before || destination_written_elsewhere) continue;
        if (source_written_later) continue;
        if (! copy.copy_compatible || copy.copy_generates_mipmaps) continue;
        plan[i] = CopyElision::Alias;
    }

    return plan;
}

std::string wallpaper::render::ResolveCopyAliasKey(
    const std::unordered_map<std::string, std::string>& aliases, const std::string& key)
{
    if (aliases.empty() || key.empty()) return key;
    std::string resolved = key;
    for (std::size_t step = 0; step <= aliases.size(); ++step) {
        const auto found = aliases.find(resolved);
        if (found == aliases.end()) return resolved;
        resolved = found->second;
    }
    return resolved;
}
