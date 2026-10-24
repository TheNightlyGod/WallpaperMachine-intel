#pragma once

#include <cstdint>
#include <span>
#include <string>
#include <unordered_map>
#include <vector>

namespace wallpaper
{
namespace render
{

/// What a copy pass may be reduced to once the whole pass list is known.
enum class CopyElision : uint8_t
{
    /// The copy runs. Anything the analysis cannot prove falls here.
    None,
    /// Nothing ever reads the destination, so the copy produces a result with
    /// no consumer.
    Dead,
    /// The source is never written again and the destination is never written
    /// at all, so the destination can share the source's image instead of
    /// receiving a byte-for-byte duplicate of it.
    Alias,
};

/// Linearised description of one pass, reduced to what copy elision needs.
struct ElisionPassDesc
{
    enum class Kind : uint8_t
    {
        Custom,
        Copy,
        Clear,
        /// Presents the scene; its reads keep a target alive even though it
        /// produces no target of its own.
        Present,
    };

    Kind kind { Kind::Custom };
    std::string writes;
    std::vector<std::string> reads;

    /// Copy passes only.
    ///
    /// `copy_compatible` means the source and destination agree on every
    /// property the copy does not convert: extent, format, sample count and
    /// mip level count. `copy_generates_mipmaps` means the copy is also the
    /// step that fills the destination's mip chain, which sharing the source's
    /// image would not do.
    bool copy_compatible { false };
    bool copy_generates_mipmaps { false };
};

/// Decides, per pass, whether its copy can be removed. Entries for passes that
/// are not copies are always `None`.
///
/// The analysis is deliberately conservative: a single unexplained read or
/// write of either side keeps the copy. A copy that exists to break a feedback
/// loop always has a later writer of its source, so it is never elided.
std::vector<CopyElision> PlanCopyElision(std::span<const ElisionPassDesc> passes);

/// The key whose image an aliased destination actually names.
///
/// `Alias` leaves the destination with no writer of its own, so a later read of
/// it is really a read of the source. An analysis that does not follow the
/// chain sees a name nothing in the pass list produces, concludes the read
/// carries no dependency, and can then call a target reusable although the
/// pixels behind that name are redrawn every frame. Chains are followed to a
/// key that is not itself an alias, and the walk is bounded by the map size so
/// a cycle -- which the planner cannot produce -- still terminates.
std::string ResolveCopyAliasKey(const std::unordered_map<std::string, std::string>& aliases,
                                const std::string&                                 key);

} // namespace render
} // namespace wallpaper
