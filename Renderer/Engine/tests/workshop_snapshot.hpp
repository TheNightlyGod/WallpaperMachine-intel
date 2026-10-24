// A deterministic JSON picture of what the engine's parsers make of one packed
// workshop item (a folder holding scene.pkg). The wpdump tool prints it; the
// corpus index and the corpus tests read it.
#pragma once

#include <iosfwd>
#include <string>

#include <nlohmann/json.hpp>

namespace wmsnap
{

// Environment variable: its mere presence adds sampled bone poses to the
// puppet rows (see the "poses" keys in snapshotWorkshop).
inline constexpr const char* kPoseEnv = "WE_TEST_DUMP_POSES";

// Parses the item in `dir` and describes the result. `err` is cleared first and
// is set when the item cannot be opened at all; the returned object then holds
// {"workshop_dir", "error"} and whatever was added before the failure.
nlohmann::json snapshotWorkshop(const std::string& dir, std::string& err);

// The command line behind wpdump, with the streams injected: `argv` is the
// whole vector including the program name. Returns the exit status.
int runWpdump(int argc, const char* const* argv, std::ostream& out, std::ostream& diag);

// The text wpdump prints for a snapshot (two-space indent, one final newline).
std::string renderSnapshot(const nlohmann::json& snapshot);

} // namespace wmsnap
