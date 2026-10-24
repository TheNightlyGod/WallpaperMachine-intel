// The scene engine's own small linear-algebra library, in namespace
// `wallpaper::linalg`: fixed-size vectors and matrices (LinalgDense.hpp), and
// quaternions, angle-axis rotations, 3D transforms and a pivoted LU (LinalgGeometry.hpp).
//
// This is this project's own code, written from the mathematics. It is not derived
// from any other library's source; only the widely used method names are shared, so
// the engine's call sites keep their shape. Storage is column-major and standard
// layout, results are concrete values, and every operation has a fixed arithmetic
// order (see LinalgDense.hpp).
#pragma once

#include "Utils/LinalgDense.hpp"
#include "Utils/LinalgGeometry.hpp"
