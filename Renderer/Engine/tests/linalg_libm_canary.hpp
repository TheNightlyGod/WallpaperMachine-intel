// A handful of C library results that decide whether the bit-exact golden values of the
// cases that call trigonometry apply on this machine: different operating systems may
// round sin or atan2 differently in the last place, and a golden hash taken on one says
// nothing about another. The golden file records these bits from the machine it was
// captured on; where they differ, those golden checks are skipped (and the properties
// in linalg_tests.cpp, which hold on any libm, still run).
#pragma once

#include <cmath>
#include <cstdint>
#include <cstring>
#include <vector>

namespace linalg_cases
{

inline std::vector<std::uint64_t> LibmCanary() {
    std::vector<std::uint64_t> bits;
    const auto                 push = [&](double v) {
        std::uint64_t b;
        std::memcpy(&b, &v, sizeof b);
        bits.push_back(b);
    };
    const auto pushf = [&](float v) {
        push(static_cast<double>(v));
    };
    for (double x : { 0.1, 0.7, 1.3, 2.9, -0.45, 123.456 }) {
        push(std::sin(x));
        push(std::cos(x));
        push(std::tan(x));
    }
    for (double x : { 0.0, 0.3, 0.9, 0.99999, 1e-9 }) {
        push(std::acos(x));
        push(std::asin(x));
    }
    for (double y : { 0.3, -0.7, 1e-9 }) {
        for (double x : { 0.9, -1.1, 0.0 }) push(std::atan2(y, x));
    }
    for (float x : { 0.1f, 0.7f, 1.3f, 2.9f, -0.45f }) {
        pushf(std::sin(x));
        pushf(std::cos(x));
    }
    for (float x : { 0.3f, 0.9f, 0.99999f }) pushf(std::acos(x));
    for (float y : { 0.3f, -0.7f }) {
        for (float x : { 0.9f, -1.1f }) pushf(std::atan2(y, x));
    }
    return bits;
}

} // namespace linalg_cases
