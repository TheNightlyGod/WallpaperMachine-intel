#pragma once

#include <cstdint>
#include <limits>
#include <nlohmann/json.hpp>
#include <optional>
#include <unordered_map>
#include <vector>

namespace wallpaper {

// Parented layers ride the outermost parent's parallax, even when a child
// retains a stale depth in the file. Resolve once before building any material
// slots or effect cards; their existing uniform/reuse paths then agree.
inline void ResolveLayerParallax(nlohmann::json& objects) {
    if (!objects.is_array()) return;
    const auto none = objects.size();
    const auto read_id = [](const nlohmann::json& object, const char* field) -> std::optional<int32_t> {
        const auto value = object.find(field);
        if (value == object.end() || !value->is_number_integer()) return std::nullopt;
        // Unsigned JSON integers must be checked before any signed conversion.
        if (value->is_number_unsigned()) {
            if (value->get<uint64_t>() > static_cast<uint64_t>(std::numeric_limits<int32_t>::max()))
                return std::nullopt;
        } else {
            const auto wide = value->get<int64_t>();
            if (wide < std::numeric_limits<int32_t>::min() || wide > std::numeric_limits<int32_t>::max())
                return std::nullopt;
        }
        return value->get<int32_t>();
    };
    std::unordered_map<int32_t, std::size_t> by_id;
    for (std::size_t i = 0; i < objects.size(); ++i) {
        const auto& object = objects[i];
        const auto id = read_id(object, "id");
        if (!id || *id == 0) continue;
        auto [entry, inserted] = by_id.emplace(*id, i);
        if (!inserted) entry->second = none; // no unambiguous parent
    }

    std::vector<uint8_t> state(objects.size(), 0);
    std::vector<std::size_t> roots(objects.size(), none), path;
    for (std::size_t i = 0; i < objects.size(); ++i) {
        if (state[i] == 2) continue;
        path.clear();
        auto current = i;
        auto root = none;
        while (state[current] == 0) {
            state[current] = 1;
            path.push_back(current);
            const auto& object = objects[current];
            auto parent = by_id.end();
            if (const auto id = read_id(object, "parent")) parent = by_id.find(*id);
            if (parent == by_id.end() || parent->second == none) {
                root = current;
                break;
            }
            current = parent->second;
        }
        if (state[current] == 2) root = roots[current];
        // A cycle has no root. Leave its depths alone rather than inventing
        // an order-dependent inheritance or recursing indefinitely.
        for (const auto member : path) {
            roots[member] = root;
            state[member] = 2;
        }
    }
    for (std::size_t i = 0; i < objects.size(); ++i) {
        if (roots[i] == none || roots[i] == i) continue;
        // A root without the key has Wallpaper Engine's default depth.
        objects[i]["parallaxDepth"] = objects[roots[i]].value(
            "parallaxDepth", nlohmann::json::array({1.0f, 1.0f}));
    }
}

} // namespace wallpaper
