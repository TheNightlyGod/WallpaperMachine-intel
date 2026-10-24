#pragma once
#include <chrono>
#include <cstdint>
#include <random>
#include <type_traits>
#include <utility>

namespace wallpaper
{
// The scene engine's random source: one std::mt19937 per thread, drawn through
// the standard uniform distributions. seed() restarts the calling thread's
// stream with std::mt19937::seed, so a fixed WE_TEST_RANDOM_SEED replays the
// same sequence (tests/utils_known_answer_tests.cpp pins it).
class Random {
public:
    Random() = delete;

    static void seed(std::mt19937::result_type value) { Engine().seed(value); }

    // A value in [from, to], or [to, from] when the bounds are reversed. T picks
    // the distribution (integer or real) and its width, so callers must pass the
    // type they mean: a float pair and a double pair consume the engine differently.
    template<typename T>
    static T get(T from, T to) {
        static_assert(std::is_integral_v<T> || std::is_floating_point_v<T>,
                      "Random::get draws integers and floating-point numbers");
        static_assert(! std::is_same_v<T, bool>, "Random::get has no bool draw");
        if (! (from < to)) std::swap(from, to);
        if constexpr (std::is_floating_point_v<T>) {
            return std::uniform_real_distribution<T> { from, to }(Engine());
        } else {
            return std::uniform_int_distribution<T> { from, to }(Engine());
        }
    }

private:
    static std::mt19937& Engine() {
        thread_local std::mt19937 engine = MakeEngine();
        return engine;
    }

    static std::mt19937 MakeEngine() {
        // random_device alone repeats on some platforms, so mix in the clock.
        std::seed_seq seq {
            static_cast<std::uint_least32_t>(std::random_device {}()),
            static_cast<std::uint_least32_t>(
                std::chrono::steady_clock::now().time_since_epoch().count()),
        };
        return std::mt19937(seq);
    }
};
} // namespace wallpaper
