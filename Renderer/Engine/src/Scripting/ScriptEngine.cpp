// Clean-room implementation from the WallpaperMachine spec e3-scripting.md; written without access to the original source.
#include "Scripting/ScriptEngine.hpp"
#include "Scripting/ScriptLibraryCore.hpp"
#include "Scripting/ScriptLibraryPrograms.hpp"
#include "Scripting/ScriptLibraryScene.hpp"
#include "Scripting/ScriptModuleSyntax.hpp"

#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/ScalarAnimation.hpp"
#include "Utils/Logging.h"
#include "Utils/TimeOfDay.hpp"

#include <quickjs.h>

#if defined(__APPLE__)
#include <pthread.h>
#endif

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <initializer_list>
#include <map>
#include <string>
#include <unordered_map>
#include <vector>

namespace wallpaper
{
namespace
{
constexpr char kVectorBootstrap[] = R"JS(
(function() {
  var EPSILON = 0.00001;
  var DEG2RAD = Math.PI / 180;
  var RAD2DEG = 180 / Math.PI;

  // Methods are defined the way `class` bodies define them: writable,
  // configurable, and not enumerable, so `for (k in vector)` lists only the
  // components.
  function define(target, methods) {
    Object.keys(methods).forEach(function(name) {
      Object.defineProperty(target, name, {
        value: methods[name], writable: true, configurable: true, enumerable: false
      });
    });
  }

  // A plain object handed to a vector constructor (the host and older scripts
  // pass `{x, y, z}`) is read leniently: a missing or non-finite field is 0.
  function lenient(value) {
    return typeof value === 'number' && Number.isFinite(value) ? value : 0;
  }

  var Vec2, Vec3, Vec4;

  function defineVector(name, fields) {
    var size = fields.length;
    var Vector;

    function make(values) {
      var instance = new Vector();
      for (var i = 0; i < size; ++i) instance[fields[i]] = values[i];
      return instance;
    }

    // Component `index` of an operand that is a number (applies to every
    // component) or a vector. A Vec2 beside a Vec3 or Vec4 stands for the
    // components it has; `rest` is what the arithmetic leaves of the others.
    function component(other, index, rest) {
      if (typeof other === 'number') return other;
      var value = other[fields[index]];
      if (value === undefined && rest !== undefined && other instanceof Vec2 && index >= 2) return rest;
      return value;
    }

    function combine(self, other, rest, op) {
      var values = new Array(size);
      for (var i = 0; i < size; ++i) values[i] = op(self[fields[i]], component(other, i, rest));
      return make(values);
    }

    function each(self, op) {
      var values = new Array(size);
      for (var i = 0; i < size; ++i) values[i] = op(self[fields[i]]);
      return make(values);
    }

    // `op` receives each component, the lower and the upper bound.
    function bounded(self, low, high, op) {
      var values = new Array(size);
      for (var i = 0; i < size; ++i) {
        values[i] = op(self[fields[i]], component(low, i), component(high, i));
      }
      return make(values);
    }

    Vector = class {
      constructor(a, b, c, d) {
        if (typeof a === 'string') {
          var parts = a.trim().split(/[\s,]+/);
          for (var i = 0; i < size; ++i) this[fields[i]] = parseFloat(parts[i]);
        } else if (a !== null && typeof a === 'object') {
          // Another vector keeps its values as they are; a plain `{x, y, ...}`
          // is read leniently. What either lacks is zero.
          var isVector = a instanceof Vec2 || a instanceof Vec3 || a instanceof Vec4;
          for (var j = 0; j < size; ++j) {
            var source = a[fields[j]];
            this[fields[j]] = isVector ? (source === undefined ? 0 : source) : lenient(source);
          }
        } else if (a === undefined) {
          for (var k = 0; k < size; ++k) this[fields[k]] = 0;
        } else {
          // A lone number fills every component. With a second number, the
          // components the call does not name are zero, and a Vec4 given three
          // numbers repeats the third as its fourth.
          var third = a;
          if (typeof c === 'number') third = c;
          else if (typeof b === 'number') third = 0;
          var set = [a,
                     typeof b === 'number' ? b : a,
                     third,
                     typeof d === 'number' ? d : third];
          for (var m = 0; m < size; ++m) this[fields[m]] = set[m];
        }
      }
    };
    Object.defineProperty(Vector, 'name', { value: name, configurable: true });

    define(Vector.prototype, {
      length: function() { return Math.sqrt(this.lengthSqr()); },
      lengthSqr: function() {
        var sum = 0;
        for (var i = 0; i < size; ++i) sum += this[fields[i]] * this[fields[i]];
        return sum;
      },
      distance: function(v) { return Math.sqrt(this.distanceSqr(v)); },
      // Squared length of the componentwise difference (NaN where `v` lacks a component).
      distanceSqr: function(v) {
        return combine(this, v, undefined, function(a, b) { return a - b; }).lengthSqr();
      },
      normalize: function() { return this.divide(this.length()); },
      copy: function() { return each(this, function(value) { return value; }); },
      clone: function() { return this.copy(); },
      equals: function(other) {
        if (!(other instanceof Vector)) return false;
        for (var i = 0; i < size; ++i) {
          if (!(Math.abs(this[fields[i]] - other[fields[i]]) < EPSILON)) return false;
        }
        return true;
      },
      isFinite: function() {
        for (var i = 0; i < size; ++i) if (!Number.isFinite(this[fields[i]])) return false;
        return true;
      },
      negate: function() { return each(this, function(value) { return -value; }); },
      add: function(f) { return combine(this, f, 0, function(a, b) { return a + b; }); },
      subtract: function(f) { return combine(this, f, 0, function(a, b) { return a - b; }); },
      multiply: function(f) { return combine(this, f, 1, function(a, b) { return a * b; }); },
      divide: function(f) { return combine(this, f, 1, function(a, b) { return a / b; }); },
      dot: function(f) {
        var sum = 0;
        for (var i = 0; i < size; ++i) sum += this[fields[i]] * f[fields[i]];
        return sum;
      },
      reflect: function(normal) { return this.subtract(normal.multiply(this.dot(normal) * 2)); },
      // The part of this along `onto`; nothing when `onto` has no length.
      project: function(onto) {
        var lengthSquared = onto.lengthSqr();
        return lengthSquared === 0 ? each(this, function() { return 0; })
                                   : onto.multiply(this.dot(onto) / lengthSquared);
      },
      mix: function(other, amount) {
        var values = new Array(size);
        for (var i = 0; i < size; ++i) {
          var from = this[fields[i]];
          values[i] = from + (component(other, i) - from) * component(amount, i);
        }
        return make(values);
      },
      min: function(v) { return combine(this, v, undefined, function(a, b) { return Math.min(a, b); }); },
      max: function(v) { return combine(this, v, undefined, function(a, b) { return Math.max(a, b); }); },
      clamp: function(low, high) {
        return bounded(this, low, high, function(value, lo, hi) {
          return Math.max(lo, Math.min(hi, value));
        });
      },
      abs: function() { return each(this, Math.abs); },
      sign: function() { return each(this, Math.sign); },
      round: function() { return each(this, Math.round); },
      floor: function() { return each(this, Math.floor); },
      ceil: function() { return each(this, Math.ceil); },
      fract: function() { return each(this, function(value) { return value - Math.floor(value); }); },
      mod: function(v) {
        return combine(this, v, undefined, function(a, b) { return a - b * Math.floor(a / b); });
      },
      step: function(edge) {
        return combine(this, edge, undefined, function(a, b) { return a < b ? 0 : 1; });
      },
      smoothStep: function(low, high) {
        return bounded(this, low, high, function(value, lo, hi) {
          var t = Math.max(0, Math.min(1, (value - lo) / (hi - lo)));
          return t * t * (3 - 2 * t);
        });
      },
      toString: function() {
        var parts = new Array(size);
        for (var i = 0; i < size; ++i) parts[i] = String(this[fields[i]]);
        return parts.join(' ');
      },
      toConfigString: function() { return this.toString(); }
    });
    return Vector;
  }

  Vec2 = defineVector('Vec2', ['x', 'y']);
  Vec3 = defineVector('Vec3', ['x', 'y', 'z']);
  Vec4 = defineVector('Vec4', ['x', 'y', 'z', 'w']);

  define(Vec2.prototype, {
    perpendicular: function() { return new Vec2(this.y, -this.x); },
    angle: function() { return Math.atan2(this.y, this.x) * RAD2DEG; },
    // The signed angle from this vector to `v`: the cross product's z over the dot product.
    angleBetween: function(v) {
      var crossZ = this.x * v.y - this.y * v.x;
      var dotted = this.x * v.x + this.y * v.y;
      return Math.atan2(crossZ, dotted) * RAD2DEG;
    },
    rotate: function(degrees) {
      var turn = degrees * DEG2RAD;
      var cosine = Math.cos(turn);
      var sine = Math.sin(turn);
      return new Vec2(this.x * cosine - this.y * sine, this.x * sine + this.y * cosine);
    }
  });

  define(Vec3.prototype, {
    cross: function(v) {
      return new Vec3(this.y * v.z - this.z * v.y,
                      this.z * v.x - this.x * v.z,
                      this.x * v.y - this.y * v.x);
    },
    // Snell's law for a unit normal and a ratio of indices; zero past the
    // critical angle.
    refract: function(normal, eta) {
      var cosIncident = this.dot(normal);
      var radicand = 1 - eta * eta * (1 - cosIncident * cosIncident);
      return radicand < 0
          ? new Vec3(0, 0, 0)
          : normal.multiply(-(eta * cosIncident + Math.sqrt(radicand))).add(this.multiply(eta));
    },
    // The unsigned angle between the two; zero when either has no length.
    angleBetween: function(v) {
      var magnitude = Math.sqrt(this.lengthSqr() * v.lengthSqr());
      if (magnitude === 0) return 0;
      var cosine = Math.min(1, Math.max(-1, this.dot(v) / magnitude));
      return Math.acos(cosine) * RAD2DEG;
    },
    // (length, angle from +y, angle about +y from +x), in degrees.
    toSpherical: function() {
      var length = this.length();
      return length === 0
          ? new Vec3(0, 0, 0)
          : new Vec3(length, Math.acos(this.y / length) * RAD2DEG, Math.atan2(this.z, this.x) * RAD2DEG);
    }
  });
  define(Vec3, {
    fromSpherical: function(radius, polarDegrees, azimuthDegrees) {
      var polar = polarDegrees * DEG2RAD, azimuth = azimuthDegrees * DEG2RAD;
      var ring = radius * Math.sin(polar);
      return new Vec3(ring * Math.cos(azimuth), radius * Math.cos(polar), ring * Math.sin(azimuth));
    }
  });

  // ---- Matrices -------------------------------------------------------------
  // A matrix keeps its elements in `m`, column after column: in a matrix with
  // `side` rows and columns, the element in row r and column c is m[c * side + r].

  function identityArray(side) {
    var values = new Array(side * side).fill(0);
    for (var i = 0; i < side; ++i) values[i * side + i] = 1;
    return values;
  }

  function defineMatrix(name, side) {
    var count = side * side;
    var Matrix = class {
      // Another matrix, an array of the right length, or a string of numbers
      // gives its elements; anything else (or a wrong length) gives the identity.
      constructor(arg) {
        var elements = null;
        if (arg instanceof Matrix) elements = arg.m;
        else if (Array.isArray(arg)) elements = arg;
        else if (typeof arg === 'string') elements = arg.trim().split(/[\s,]+/).map(parseFloat);
        this.m = elements !== null && elements.length === count ? elements.slice() : identityArray(side);
      }
    };
    Object.defineProperty(Matrix, 'name', { value: name });
    return Matrix;
  }

  var Mat3 = defineMatrix('Mat3', 3);
  var Mat4 = defineMatrix('Mat4', 4);

  // The product a * b of two such arrays. Column c of the result combines the
  // columns of `a`, each weighted by the matching entry of column c of `b`.
  function product(a, b, side) {
    var out = new Array(side * side).fill(0);
    for (var col = 0; col < side; ++col) {
      for (var k = 0; k < side; ++k) {
        var weight = b[col * side + k];
        for (var row = 0; row < side; ++row) out[col * side + row] += a[k * side + row] * weight;
      }
    }
    return out;
  }

  // The array applied to a column of `side` numbers.
  function applyArray(array, side, column) {
    var out = new Array(side).fill(0);
    for (var col = 0; col < side; ++col) {
      for (var row = 0; row < side; ++row) out[row] += array[col * side + row] * column[col];
    }
    return out;
  }

  // Determinant of what is left of an n-by-n array when row `skipRow` and column
  // `skipColumn` are taken out (-1 takes out nothing), found by expanding along
  // the leftmost remaining column. `usedRows` is the set of rows already spent
  // by the columns to its left, as bits.
  function expand(a, n, column, skipColumn, usedRows) {
    if (column === skipColumn) column += 1;
    if (column >= n) return 1;
    var total = 0;
    var sign = 1;
    for (var row = 0; row < n; ++row) {
      if (usedRows & (1 << row)) continue;
      total += sign * a[column * n + row] * expand(a, n, column + 1, skipColumn, usedRows | (1 << row));
      sign = -sign;
    }
    return total;
  }

  function determinantOf(a, n) { return expand(a, n, 0, -1, 0); }

  // The inverse as the adjugate over the determinant: the element in row r and
  // column c is the minor that leaves out row c and column r, signed by the
  // parity of r + c, and divided by the determinant.
  function inverseOf(a, n) {
    var reciprocal = 1 / determinantOf(a, n);
    var out = new Array(n * n);
    for (var r = 0; r < n; ++r) {
      for (var c = 0; c < n; ++c) {
        var sign = (r + c) % 2 === 0 ? 1 : -1;
        out[c * n + r] = sign * expand(a, n, 0, r, 1 << c) * reciprocal;
      }
    }
    return out;
  }

  // The turn by `radians` about the coordinate axis k (0 x, 1 y, 2 z) of a
  // matrix with `side` rows. The other two axes follow k in cyclic order, and
  // the turn carries the first of them toward the second.
  function turnArray(side, k, radians) {
    var first = (k + 1) % 3;
    var second = (k + 2) % 3;
    var cosine = Math.cos(radians);
    var sine = Math.sin(radians);
    var out = identityArray(side);
    out[first * side + first] = cosine;
    out[second * side + second] = cosine;
    out[first * side + second] = sine;
    out[second * side + first] = -sine;
    return out;
  }

  // Column c of an array, as a Vec3 of its first three rows.
  function columnVec3(array, side, c) {
    return new Vec3(array[c * side], array[c * side + 1], array[c * side + 2]);
  }

  // A matrix with `scales` on its diagonal and ones where there are none.
  function diagonalArray(side, scales) {
    var out = identityArray(side);
    for (var i = 0; i < scales.length; ++i) out[i * side + i] = scales[i];
    return out;
  }

  // A matrix whose last column, above the corner, is `offset`.
  function offsetArray(side, offset) {
    var out = identityArray(side);
    for (var i = 0; i < offset.length; ++i) out[(side - 1) * side + i] = offset[i];
    return out;
  }

  // Methods that read the same for both sizes.
  function defineMatrixCommon(Matrix, side) {
    var count = side * side;
    define(Matrix.prototype, {
      add: function(other) {
        return new Matrix(this.m.map(function(value, i) { return value + other.m[i]; }));
      },
      subtract: function(other) {
        return new Matrix(this.m.map(function(value, i) { return value - other.m[i]; }));
      },
      copy: function() { return new Matrix(this); },
      equals: function(other) {
        return other instanceof Matrix &&
               this.m.every(function(value, i) { return Math.abs(value - other.m[i]) < EPSILON; });
      },
      transpose: function() {
        var result = new Matrix();
        for (var column = 0; column < side; ++column) {
          for (var row = 0; row < side; ++row) result.m[column * side + row] = this.m[row * side + column];
        }
        return result;
      },
      determinant: function() { return determinantOf(this.m, side); },
      inverse: function() { return new Matrix(inverseOf(this.m, side)); },
      toString: function() { return this.m.join(' '); },
      toConfigString: function() { return this.toString(); }
    });
    define(Matrix, {
      identity: function() { return new Matrix(); }
    });
  }
  defineMatrixCommon(Mat3, 3);
  defineMatrixCommon(Mat4, 4);

  // A scale argument is one number for every axis or a vector.
  var AXIS_NAMES = ['x', 'y', 'z'];
  function axisFactors(v, length) {
    var factors = [];
    for (var i = 0; i < length; ++i) factors.push(typeof v === 'number' ? v : v[AXIS_NAMES[i]]);
    return factors;
  }

  define(Mat3, {
    fromTranslation: function(v) { return new Mat3(offsetArray(3, [v.x, v.y])); },
    fromScale: function(v) { return new Mat3(diagonalArray(3, axisFactors(v, 2))); },
    fromRotation: function(degrees) { return new Mat3(turnArray(3, 2, degrees * DEG2RAD)); },
    fromBasis: function(right, up) {
      return new Mat3([right.x, right.y, 0, up.x, up.y, 0, 0, 0, 1]);
    },
    fromMat4: function(matrix) {
      var a = matrix.m;
      return new Mat3([a[0], a[1], a[2], a[4], a[5], a[6], a[8], a[9], a[10]]);
    },
    // Translate, then turn, then scale: T * R * S.
    compose: function(translation, rotation, scale) {
      var placed = product(offsetArray(3, [translation.x, translation.y]),
                           turnArray(3, 2, rotation * DEG2RAD), 3);
      return new Mat3(product(placed, diagonalArray(3, axisFactors(scale, 2)), 3));
    }
  });
  define(Mat3.prototype, {
    right: function() { return columnVec3(this.m, 3, 0); },
    up: function() { return columnVec3(this.m, 3, 1); },
    forward: function() { return columnVec3(this.m, 3, 2); },
    // With a Vec2 it sets the offset and answers the matrix; without, it answers the offset.
    translation: function(v) {
      if (!(v instanceof Vec2)) return new Vec2(this.m[6], this.m[7]);
      this.m.splice(6, 2, v.x, v.y);
      return this;
    },
    angle: function() { return Math.atan2(this.m[0], -this.m[1]) * RAD2DEG; },
    multiply: function(f) {
      if (f instanceof Mat3) return new Mat3(product(this.m, f.m, 3));
      if (f instanceof Vec3) {
        var moved = applyArray(this.m, 3, [f.x, f.y, f.z]);
        return new Vec3(moved[0], moved[1], moved[2]);
      }
      if (typeof f === 'number') return new Mat3(this.m.map(function(value) { return value * f; }));
    },
    translate: function(v) { return new Mat3(product(this.m, offsetArray(3, [v.x, v.y]), 3)); },
    rotate: function(degrees) { return new Mat3(product(this.m, turnArray(3, 2, degrees * DEG2RAD), 3)); },
    scale: function(v) { return new Mat3(product(this.m, diagonalArray(3, axisFactors(v, 2)), 3)); },
    transformPoint: function(v) {
      var moved = applyArray(this.m, 3, [v.x, v.y, 1]);
      return new Vec2(moved[0], moved[1]);
    },
    transformDirection: function(v) {
      var moved = applyArray(this.m, 3, [v.x, v.y, 0]);
      return new Vec2(moved[0], moved[1]);
    },
    // The x scale is negative when the upper 2x2 part mirrors the plane.
    decompose: function() {
      var m = this.m;
      var length = Math.hypot(m[0], m[1]);
      var xScale = expand(m, 3, 0, 2, 1 << 2) < 0 ? -length : length;
      return {
        translation: new Vec2(m[6], m[7]),
        rotation: xScale === 0 ? 0
                  : Math.atan2(xScale < 0 ? -m[1] : m[1], xScale < 0 ? -m[0] : m[0]) * RAD2DEG,
        scale: new Vec2(xScale, Math.hypot(m[3], m[4]))
      };
    }
  });

  define(Mat4, {
    fromTranslation: function(v) {
      var offset = [];
      if (v instanceof Vec3) offset = [v.x, v.y, v.z];
      else if (v instanceof Vec2) offset = [v.x, v.y];
      return new Mat4(offsetArray(4, offset));
    },
    fromScale: function(v) { return new Mat4(diagonalArray(4, axisFactors(v, 3))); },
    // Rotation by `degrees` about `axis`: cos * I + (1 - cos) * u u^T + sin * [u]x,
    // where u is the unit axis and [u]x the matrix that crosses a vector with it.
    fromRotation: function(degrees, axis) {
      var radians = degrees * DEG2RAD;
      var unit = axis.normalize();
      var u = [unit.x, unit.y, unit.z];
      var cosine = Math.cos(radians);
      var sine = Math.sin(radians);
      var crossing = [0, u[2], -u[1],  -u[2], 0, u[0],  u[1], -u[0], 0];
      var out = identityArray(4);
      for (var col = 0; col < 3; ++col) {
        for (var row = 0; row < 3; ++row) {
          out[col * 4 + row] = (row === col ? cosine : 0) + (1 - cosine) * u[row] * u[col] +
                               sine * crossing[col * 3 + row];
        }
      }
      return new Mat4(out);
    },
    // Turns about x, then y, then z, each about the fixed axes: Rz * Ry * Rx.
    fromEuler: function(x, y, z) {
      var angles = x instanceof Vec3 ? [x.x, x.y, x.z] : [x, y, z];
      var turned = identityArray(4);
      for (var axis = 2; axis >= 0; --axis) {
        turned = product(turned, turnArray(4, axis, angles[axis] * DEG2RAD), 4);
      }
      return new Mat4(turned);
    },
    fromBasis: function(right, up, forward) {
      return new Mat4([right.x, right.y, right.z, 0,
                       up.x, up.y, up.z, 0,
                       forward.x, forward.y, forward.z, 0,
                       0, 0, 0, 1]);
    },
    // The view matrix of a camera at `eye` looking at `center`: its rows are the
    // camera's side, above and (negated) ahead axes, then the eye moved to the origin.
    lookAt: function(eye, center, up) {
      var ahead = eye.multiply(-1).add(center).normalize();
      var side = ahead.cross(up).normalize();
      var above = side.cross(ahead);
      return new Mat4([side.x, above.x, -ahead.x, 0,
                       side.y, above.y, -ahead.y, 0,
                       side.z, above.z, -ahead.z, 0,
                       -side.dot(eye), -above.dot(eye), ahead.dot(eye), 1]);
    },
    // Translate, then turn, then scale: T * R * S.
    compose: function(translation, rotation, scale) {
      var placed = product(Mat4.fromTranslation(translation).m, Mat4.fromEuler(rotation).m, 4);
      return new Mat4(product(placed, diagonalArray(4, axisFactors(scale, 3)), 4));
    }
  });
  define(Mat4.prototype, {
    // With a Vec3 (or a Vec2, whose z is 0) it sets the offset and answers the
    // matrix; with anything else it answers the offset.
    translation: function(v) {
      if (!(v instanceof Vec3 || v instanceof Vec2)) return columnVec3(this.m, 4, 3);
      this.m.splice(12, 3, v.x, v.y, v instanceof Vec3 ? v.z : 0);
      return this;
    },
    right: function() { return columnVec3(this.m, 4, 0); },
    up: function() { return columnVec3(this.m, 4, 1); },
    forward: function() { return columnVec3(this.m, 4, 2); },
    multiply: function(f) {
      if (f instanceof Mat4) return new Mat4(product(this.m, f.m, 4));
      if (f instanceof Vec4) {
        var moved = applyArray(this.m, 4, [f.x, f.y, f.z, f.w]);
        return new Vec4(moved[0], moved[1], moved[2], moved[3]);
      }
      if (typeof f === 'number') return new Mat4(this.m.map(function(value) { return value * f; }));
    },
    translate: function(v) {
      var offset = [v.x, v.y, v instanceof Vec2 ? 0 : v.z];
      return new Mat4(product(this.m, offsetArray(4, offset), 4));
    },
    rotate: function(degrees, axis) { return this.multiply(Mat4.fromRotation(degrees, axis)); },
    scale: function(v) { return new Mat4(product(this.m, diagonalArray(4, axisFactors(v, 3)), 4)); },
    transformPoint: function(v) {
      var moved = applyArray(this.m, 4, [v.x, v.y, v.z, 1]);
      return new Vec3(moved[0], moved[1], moved[2]);
    },
    transformDirection: function(v) {
      var moved = applyArray(this.m, 4, [v.x, v.y, v.z, 0]);
      return new Vec3(moved[0], moved[1], moved[2]);
    },
    // The turns about x, y, z (degrees) that Mat4.fromEuler would compose into
    // this matrix, which is Rz * Ry * Rx. The x axis lands at (cos y cos z,
    // cos y sin z, -sin y), so z and y follow from the first column and the
    // length of the bottom row's other two entries. x is read after undoing the
    // turn about z: what remains is Ry * Rx, whose middle row is (0, cos x, -sin x),
    // and that stays defined where y is +-90 degrees and the bottom row vanishes.
    extractEuler: function() {
      var m = this.m;
      var yaw = Math.atan2(m[1], m[0]);
      var pitch = Math.atan2(-m[2], Math.hypot(m[6], m[10]));
      var rest = product(turnArray(4, 2, -yaw), m, 4);
      var roll = Math.atan2(-rest[9], rest[5]);
      return new Vec3(roll * RAD2DEG, pitch * RAD2DEG, yaw * RAD2DEG);
    },
    normalMatrix: function() { return Mat3.fromMat4(this).inverse().transpose(); },
    // Translation, Euler angles and scale. The x scale is negative when the
    // upper 3x3 part mirrors space.
    decompose: function() {
      var m = this.m;
      var scales = [];
      for (var col = 0; col < 3; ++col) scales.push(Math.hypot(m[col * 4], m[col * 4 + 1], m[col * 4 + 2]));
      if (expand(m, 4, 0, 3, 1 << 3) < 0) scales[0] = -scales[0];
      var rotation = new Mat4(this);
      for (var column = 0; column < 3; ++column) {
        if (scales[column] === 0) continue;
        for (var row = 0; row < 3; ++row) rotation.m[column * 4 + row] /= scales[column];
      }
      rotation.m[12] = 0; rotation.m[13] = 0; rotation.m[14] = 0;
      return {
        translation: new Vec3(m[12], m[13], m[14]),
        rotation: rotation.extractEuler(),
        scale: new Vec3(scales[0], scales[1], scales[2])
      };
    }
  });

  // The host builds its vectors and the layer matrices through these frozen
  // names, so a script that reassigns the global `Vec3` or `Mat4` cannot change
  // what the host hands back.
  var exposed = { Vec2: Vec2, Vec3: Vec3, Vec4: Vec4, Mat3: Mat3, Mat4: Mat4 };
  ['Vec2', 'Vec3', 'Vec4', 'Mat4'].forEach(function(key) {
    Object.defineProperty(globalThis, '__WE' + key, {
      value: exposed[key], configurable: false, writable: false
    });
  });
  Object.keys(exposed).forEach(function(key) {
    if (typeof globalThis[key] !== 'function') globalThis[key] = exposed[key];
  });
})();
)JS";



// ---------------------------------------------------------------------------
// Script front end: the text of a workshop script becomes the body of one function.
// ---------------------------------------------------------------------------

bool IsIdentifierByte(unsigned char c) {
    return std::isalnum(c) != 0 || c == '_' || c == '$' || c >= 0x80;
}

bool IsBlank(char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f'; }

// Words after which a `/` starts a regular expression rather than dividing.
bool RegexMayFollowWord(std::string_view word) {
    static constexpr std::string_view words[] = { "return", "typeof", "case",   "in",    "of",
                                                  "delete", "void",   "throw",  "new",   "else",
                                                  "do",     "instanceof", "yield", "await" };
    for (const auto candidate : words) {
        if (candidate == word) return true;
    }
    return false;
}

struct ImportStatement {
    bool        ok { false };
    std::size_t end { 0 };
    std::string code;
};

std::size_t SkipBlanks(std::string_view text, std::size_t at) {
    while (at < text.size() && IsBlank(text[at])) ++at;
    return at;
}

bool ReadWord(std::string_view text, std::size_t& at, std::string& word) {
    const std::size_t start = at;
    while (at < text.size() && IsIdentifierByte(static_cast<unsigned char>(text[at]))) ++at;
    word.assign(text.substr(start, at - start));
    return at > start;
}

bool ReadQuoted(std::string_view text, std::size_t& at, std::string& value) {
    if (at >= text.size() || (text[at] != '\'' && text[at] != '"')) return false;
    const char        quote = text[at];
    const std::size_t close = text.find(quote, at + 1);
    if (close == std::string_view::npos) return false;
    value.assign(text.substr(at + 1, close - at - 1));
    at = close + 1;
    return true;
}

std::string QuoteForScript(const std::string& value) {
    std::string out = "'";
    for (const char c : value) {
        if (c == '\'' || c == '\\') out += '\\';
        if (c == '\n' || c == '\r') continue;
        out += c;
    }
    out += '\'';
    return out;
}

// The forms of `import` a Wallpaper Engine script uses; `at` is just past the
// keyword. A form this does not know answers `ok == false` and the text stays.
ImportStatement ParseImport(std::string_view text, std::size_t at) {
    ImportStatement result;
    std::size_t     i = SkipBlanks(text, at);
    if (i >= text.size()) return result;
    std::string module;
    std::string code;
    const auto  finish = [&](std::size_t end, std::string statement) {
        // A statement ends at its semicolon, which belongs to it.
        std::size_t j = end;
        while (j < text.size() && (text[j] == ' ' || text[j] == '\t')) ++j;
        if (j < text.size() && text[j] == ';') end = j + 1;
        result.ok   = true;
        result.end  = end;
        result.code = std::move(statement);
        // Line numbers stay what the author wrote.
        for (std::size_t k = at; k < end; ++k) {
            if (text[k] == '\n') result.code += '\n';
        }
    };
    const auto expectFrom = [&](std::size_t& cursor) {
        cursor = SkipBlanks(text, cursor);
        if (text.substr(cursor, 4) != "from") return false;
        cursor = SkipBlanks(text, cursor + 4);
        return ReadQuoted(text, cursor, module);
    };
    if (text[i] == '\'' || text[i] == '"') {
        if (! ReadQuoted(text, i, module)) return result;
        finish(i, ";");
        return result;
    }
    if (text[i] == '*') {
        i = SkipBlanks(text, i + 1);
        if (text.substr(i, 2) != "as") return result;
        i = SkipBlanks(text, i + 2);
        std::string name;
        if (! ReadWord(text, i, name)) return result;
        if (! expectFrom(i)) return result;
        finish(i, "var " + name + " = __wmNs(" + QuoteForScript(module) + ");");
        return result;
    }
    if (text[i] == '{') {
        const std::size_t close = text.find('}', i);
        if (close == std::string_view::npos) return result;
        std::string members;
        std::size_t cursor = i + 1;
        while (true) {
            cursor = SkipBlanks(text, cursor);
            if (cursor >= close) break;
            std::string name;
            if (! ReadWord(text, cursor, name)) return result;
            std::string local = name;
            cursor            = SkipBlanks(text, cursor);
            if (text.substr(cursor, 2) == "as" && cursor + 2 < text.size() &&
                IsBlank(text[cursor + 2])) {
                cursor = SkipBlanks(text, cursor + 2);
                if (! ReadWord(text, cursor, local)) return result;
                cursor = SkipBlanks(text, cursor);
            }
            if (! members.empty()) members += ", ";
            members += name == local ? name : name + ": " + local;
            if (cursor < close && text[cursor] == ',') ++cursor;
        }
        std::size_t after = close + 1;
        if (! expectFrom(after)) return result;
        finish(after, "var {" + members + "} = __wmNamed(" + QuoteForScript(module) + ");");
        return result;
    }
    std::string name;
    if (ReadWord(text, i, name) && name != "type") {
        if (! expectFrom(i)) return result;
        finish(i, "var " + name + " = __wmNs(" + QuoteForScript(module) + ");");
    }
    return result;
}

// Module syntax is tolerated, not enforced: the imports bind the library's own
// modules, `export` disappears, and handlers end up as plain functions of the
// program's scope whether or not the author exported them. Strings, comments,
// template literals and regular expressions are left alone.
std::string NormalizeScript(std::string_view source) {
    if (source.substr(0, 3) == "\xEF\xBB\xBF") source.remove_prefix(3);
    enum class Mode
    {
        Code,
        LineComment,
        BlockComment,
        Single,
        Double,
        Template,
        Regex,
    };
    std::string      out;
    out.reserve(source.size() + 64);
    Mode             mode = Mode::Code;
    std::vector<int> templateDepths;
    int              braceDepth = 0;
    bool             inClass    = false; // inside a regex character class
    char             lastSignificant = 0;
    std::string      lastWord;
    std::string      currentWord;

    const auto endWord = [&] {
        if (! currentWord.empty()) {
            lastWord = currentWord;
            currentWord.clear();
        }
    };
    const auto regexAllowed = [&] {
        if (lastSignificant == 0) return true;
        if (IsIdentifierByte(static_cast<unsigned char>(lastSignificant))) {
            return RegexMayFollowWord(lastWord);
        }
        return lastSignificant != ')' && lastSignificant != ']' && lastSignificant != '}';
    };

    for (std::size_t i = 0; i < source.size();) {
        const char c = source[i];
        switch (mode) {
        case Mode::LineComment:
            out += c;
            ++i;
            if (c == '\n' || c == '\r') mode = Mode::Code;
            continue;
        case Mode::BlockComment:
            out += c;
            ++i;
            if (c == '*' && i < source.size() && source[i] == '/') {
                out += '/';
                ++i;
                mode = Mode::Code;
            }
            continue;
        case Mode::Single:
        case Mode::Double: {
            out += c;
            ++i;
            if (c == '\\' && i < source.size()) {
                out += source[i++];
            } else if ((mode == Mode::Single && c == '\'') || (mode == Mode::Double && c == '"') ||
                       c == '\n') {
                mode = Mode::Code;
            }
            continue;
        }
        case Mode::Template:
            out += c;
            ++i;
            if (c == '\\' && i < source.size()) {
                out += source[i++];
            } else if (c == '`') {
                mode = Mode::Code;
            } else if (c == '$' && i < source.size() && source[i] == '{') {
                out += '{';
                ++i;
                templateDepths.push_back(braceDepth);
                ++braceDepth;
                mode = Mode::Code;
            }
            continue;
        case Mode::Regex:
            out += c;
            ++i;
            if (c == '\\' && i < source.size()) {
                out += source[i++];
            } else if (c == '[') {
                inClass = true;
            } else if (c == ']') {
                inClass = false;
            } else if ((c == '/' && ! inClass) || c == '\n') {
                mode            = Mode::Code;
                lastSignificant = ')';
            }
            continue;
        case Mode::Code:
            break;
        }

        // Code.
        if (IsIdentifierByte(static_cast<unsigned char>(c))) {
            const bool wordStart = i == 0 || ! IsIdentifierByte(static_cast<unsigned char>(source[i - 1]));
            // `ExportKeywordAt` decides what may stand before the keyword, including the
            // non-ASCII whitespace whose bytes count as identifier bytes here.
            if (source[i] == 'e' && ExportKeywordAt(source, i) && (i == 0 || source[i - 1] != '.')) {
                const std::size_t next = i + 6;
                if (source.substr(SkipBlanks(source, next), 7) == "default" &&
                    ! IsIdentifierByte(static_cast<unsigned char>(
                        SkipBlanks(source, next) + 7 < source.size()
                            ? source[SkipBlanks(source, next) + 7]
                            : ' '))) {
                    std::size_t cursor = SkipBlanks(source, next) + 7;
                    const std::size_t token = SkipBlanks(source, cursor);
                    const bool declaration = source.substr(token, 8) == "function" ||
                                             source.substr(token, 5) == "class" ||
                                             source.substr(token, 5) == "async";
                    if (! declaration) out += "var __wmDefault =";
                    i = cursor;
                    continue;
                }
                const std::size_t token = SkipBlanks(source, next);
                if (token < source.size() && source[token] == '{') {
                    const std::size_t close = source.find('}', token);
                    if (close != std::string_view::npos) {
                        std::size_t end = close + 1;
                        std::size_t cursor = SkipBlanks(source, end);
                        std::string module;
                        if (source.substr(cursor, 4) == "from") {
                            cursor = SkipBlanks(source, cursor + 4);
                            if (ReadQuoted(source, cursor, module)) end = cursor;
                        }
                        out += ';';
                        for (std::size_t k = i; k < end; ++k) {
                            if (source[k] == '\n') out += '\n';
                        }
                        i = end;
                        continue;
                    }
                }
                i = next; // only the keyword goes; the separator after it stays
                continue;
            }
            if (wordStart && source.compare(i, 6, "import") == 0 &&
                (i + 6 >= source.size() || ! IsIdentifierByte(static_cast<unsigned char>(source[i + 6]))) &&
                (i == 0 || source[i - 1] != '.')) {
                const auto statement = ParseImport(source, i + 6);
                if (statement.ok) {
                    out += statement.code;
                    i = statement.end;
                    lastSignificant = ';';
                    endWord();
                    continue;
                }
            }
            currentWord += c;
            lastSignificant = c;
            out += c;
            ++i;
            continue;
        }
        endWord();
        if (c == '/' && i + 1 < source.size() && source[i + 1] == '/') {
            mode = Mode::LineComment;
            out += "//";
            i += 2;
            continue;
        }
        if (c == '/' && i + 1 < source.size() && source[i + 1] == '*') {
            mode = Mode::BlockComment;
            out += "/*";
            i += 2;
            continue;
        }
        if (c == '/' && regexAllowed()) {
            mode    = Mode::Regex;
            inClass = false;
            out += c;
            ++i;
            continue;
        }
        if (c == '\'') mode = Mode::Single;
        if (c == '"') mode = Mode::Double;
        if (c == '`') mode = Mode::Template;
        if (c == '{') ++braceDepth;
        if (c == '}') {
            --braceDepth;
            if (! templateDepths.empty() && braceDepth == templateDepths.back()) {
                templateDepths.pop_back();
                out += c;
                ++i;
                mode = Mode::Template;
                continue;
            }
        }
        if (! IsBlank(c)) lastSignificant = c;
        out += c;
        ++i;
    }
    return out;
}

// The names `Evaluate` and the dispatchers look for in the program's scope.
constexpr std::string_view kHandlerNames[] = {
    "init",
    "update",
    "applyUserProperties",
    "applyGeneralSettings",
    "resizeScreen",
    "cursorClick",
    "cursorDown",
    "cursorEnter",
    "cursorLeave",
    "cursorMove",
    "cursorUp",
    "mediaPlaybackChanged",
    "mediaPropertiesChanged",
    "mediaStatusChanged",
    "mediaTimelineChanged",
    "mediaThumbnailChanged",
    "animationEvent",
    "destroy",
};

// The first character of a "layer" reference that names the clock of one setting.
constexpr char kSettingMarker = '\x03';

// The script's text inside a function that hands back the handlers it defined.
// The prologue shares the first line with the text so line numbers stay the author's.
std::string WrapScript(const std::string& body) {
    std::string wrapped =
        "(function(thisLayer,thisObject,thisScene,createScriptProperties,scriptProperties,"
        "__wmNs,__wmNamed,__wmHooks){"
        "__wmHooks.wid=function(){try{return __workshopId}catch(__wmE){return undefined}};";
    wrapped += body;
    wrapped += "\n;return{";
    for (std::size_t i = 0; i < std::size(kHandlerNames); ++i) {
        const std::string name(kHandlerNames[i]);
        if (i != 0) wrapped += ',';
        wrapped += name + ":typeof " + name + "==='function'?" + name + ":void 0";
    }
    wrapped += "}})";
    return wrapped;
}



// ---------------------------------------------------------------------------
// The execution context of one engine.
// ---------------------------------------------------------------------------

enum LibFn : int
{
    kLibHostUpdate,
    kLibSetProps,
    kLibMake,
    kLibEvaluate,
    kLibStartScene,
    kLibTickScene,
    kLibCursorEvent,
    kLibAnimationEvent,
    kLibAnimationListeners,
    kLibMediaJson,
    kLibMediaThumbnail,
    kLibResizeProgram,
    kLibResizeListeners,
    kLibApplyProps,
    kLibDestroyProgram,
    kLibNotifyEnded,
    kLibNoticeLanguage,
    kLibResetTransient,
    kLibRunInit,
    kLibUserNotices,
    kLibFnCount,
};

constexpr const char* kLibFnNames[kLibFnCount] = {
    "hostUpdate",    "setProps",       "make",          "evaluate",       "startScene",
    "tickScene",     "cursorEvent",    "animationEvent", "animationListeners", "mediaJson",
    "mediaThumbnail", "resizeProgram", "resizeListeners", "applyProps",     "destroyProgram",
    "notifyEnded",   "noticeLanguage", "resetTransient", "runInit",      "userNotices",
};

#define SCRIPT_NATIVE_LIST(X)                                                                      \
    X(error) X(resolve) X(hasNode) X(layerCount) X(layerNameAt) X(layerIndex) X(sortLayer)        \
    X(layerById) X(authoredName) X(requestConfig) X(initialConfig) X(visible) X(setVisible)       \
    X(origin) X(setOrigin) X(scale) X(setScale) X(rotation) X(setRotation) X(size) X(color)       \
    X(setColor) X(alpha) X(setAlpha) X(text) X(setText) X(setAlignment) X(textStyle)              \
    X(setTextStyle) X(parent) X(setParent) X(setSize) X(parallax) X(setParallax) X(matrix)        \
    X(createFromTemplate) X(createText) X(nameLayer) X(destroyLayer) X(hasSound) X(soundPlay)     \
    X(soundPause) X(soundStop) X(soundPlaying) X(soundVolume) X(soundSetVolume) X(soundMuted)     \
    X(soundSetMuted) X(puppet) X(puppetName) X(timeline) X(sheet) X(sheetInfo) X(video)           \
    X(audioMark) X(audioGeneration) X(audio) X(shortcutValue) X(requestShortcut) X(timeOfDay)       \
    X(effectVisible) X(setEffectVisible) X(rotateObjectSpace)

enum NativeId : int
{
#define SCRIPT_NATIVE_ENUM(name) kNative_##name,
    SCRIPT_NATIVE_LIST(SCRIPT_NATIVE_ENUM)
#undef SCRIPT_NATIVE_ENUM
};

constexpr const char* kNativeNames[] = {
#define SCRIPT_NATIVE_NAME(name) #name,
    SCRIPT_NATIVE_LIST(SCRIPT_NATIVE_NAME)
#undef SCRIPT_NATIVE_NAME
};

thread_local ScriptStartupMetrics g_startup_metrics;

double MillisecondsSince(std::chrono::steady_clock::time_point start) {
    return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
}

std::string CompleteLibraryText() {
    std::string text;
    text.reserve(sizeof(script_library::kCore) + sizeof(script_library::kScene) +
                 sizeof(script_library::kPrograms));
    text += script_library::kCore;
    text += script_library::kScene;
    text += script_library::kPrograms;
    return text;
}

bool ProjectPropertiesEqual(const ProjectProperties& a, const ProjectProperties& b) {
    if (a.size() != b.size()) return false;
    for (const auto& [name, value] : a) {
        const auto other = b.find(name);
        if (other == b.end() || other->second.kind != value.kind) return false;
        switch (value.kind) {
        case RuntimeScalarValue::Kind::Bool:
            if (other->second.bool_value != value.bool_value) return false;
            break;
        case RuntimeScalarValue::Kind::Float:
            if (other->second.float_value != value.float_value) return false;
            break;
        case RuntimeScalarValue::Kind::String:
            if (other->second.string_value != value.string_value) return false;
            break;
        }
    }
    return true;
}

} // namespace

// The things one script program needs to be told apart from the others while it is
// being called: its consecutive interruptions, and whether it was switched off.
struct ScriptGuard {
    int         interrupts { 0 };
    bool        disabled { false };
    std::string name;
};

struct ScriptEngineContext : std::enable_shared_from_this<ScriptEngineContext> {
    ScriptLimits limits;
    JSRuntime*   rt { nullptr };
    JSContext*   ctx { nullptr };
    bool         ready { false };
    bool         broken { false };
    JSValue      lib[kLibFnCount];
    JSValue      vector_classes[3];
    struct Compiled {
        JSValue     factory { JS_UNDEFINED };
        std::string error;
    };
    std::unordered_map<std::string, Compiled> compiled;
    SceneRuntimeContext*                      runtime { nullptr };
    ScriptHostContext                         last_host;
    bool                                      have_host { false };
    ProjectProperties                         pushed_props;
    bool                                      have_pushed_props { false };
    uint64_t                                  next_program_id { 1 };
    int64_t                                   deadline_ns { 0 };
    bool                                      interrupted { false };
    // How many call scopes are open on this context; the outermost one is the host's entry.
    int                                       call_depth { 0 };
    struct LogRecord {
        int    logged { 0 };
        int    suppressed { 0 };
        double last_summary { 0.0 };
        bool   summarized { false };
    };
    std::unordered_map<std::string, LogRecord> log_records;

    explicit ScriptEngineContext(const ScriptLimits& configured);
    ~ScriptEngineContext();
    ScriptEngineContext(const ScriptEngineContext&)            = delete;
    ScriptEngineContext& operator=(const ScriptEngineContext&) = delete;

    void     ApplyLimits(const ScriptLimits& configured);
    // Points the script stack limit at the stack of the thread that is calling in now.
    void     AdoptThreadStack();
    // One interrupted call or step: its error, and a strike against the program.
    void     RecordInterrupt(ScriptGuard* guard, const char* entry, double budget_ms);
    // Script code that ran in the open scope outside `Call` (an accessor the script
    // defined, a getter on the value it returned) ran out of its budget.
    bool     Overran(ScriptGuard* guard, const char* entry, double budget_ms);
    bool     EnsureReady();
    int64_t  NowNanoseconds() const;
    double   LogSeconds() const;
    void     RefreshHost(const ScriptHostContext& host);
    void     PushProps(const ProjectProperties& props);
    void     ReportError(const std::string& entry, std::string message, const std::string& stack);
    // Compiles (once per kind and text) and returns the factory, or null with `error`.
    JSValue  Factory(bool scene, const std::string& source, std::string* error);
    // One host-initiated call into the library. False when it did not complete.
    bool     Call(ScriptGuard* guard, const char* entry, LibFn fn, std::initializer_list<JSValue> args,
                  double budget_ms, JSValue* result = nullptr);
    // Runs the queued promise jobs; true when one of them was interrupted.
    bool     PumpJobs();
    std::string TakeException(std::string* stack);

    JSValue  NewVector(int size, double x, double y, double z, double w);
    JSValue  ToJs(const DynamicValue& value, bool degrees);
    JSValue  PropsToJs(const ProjectProperties& props);
    // The script's answer as a value of the hint's type; null when it has none.
    DynamicValueUniquePtr FromJs(JSValueConst value, const DynamicValue& hint, bool degrees);

    JSValue NativeCall(int id, int argc, JSValueConst* argv);
};

namespace
{

// RAII: the call's wall-clock budget and the runtime its natives reach.
class CallScope {
public:
    CallScope(ScriptEngineContext& context, SceneRuntimeContext* runtime, double budget_ms)
        : m_context(context),
          m_previous_runtime(context.runtime),
          m_previous_deadline(context.deadline_ns),
          m_previous_interrupted(context.interrupted) {
        if (runtime != nullptr) context.runtime = runtime;
        // The host enters from the thread that loaded the scene and from the one that
        // ticks it; the limit follows the thread that is on the stack now.
        if (context.call_depth++ == 0) context.AdoptThreadStack();
        context.interrupted = false;
        const auto budget   = static_cast<int64_t>(budget_ms * 1.0e6);
        const auto deadline = budget > 0 ? context.NowNanoseconds() + budget : int64_t { 0 };
        // A nested call never outlives the call it runs inside.
        context.deadline_ns = (m_previous_deadline != 0 && deadline != 0)
                                  ? std::min(deadline, m_previous_deadline)
                                  : (deadline != 0 ? deadline : m_previous_deadline);
    }
    ~CallScope() {
        --m_context.call_depth;
        m_context.deadline_ns = m_previous_deadline;
        m_context.interrupted = m_previous_interrupted;
        if (m_previous_runtime != nullptr) m_context.runtime = m_previous_runtime;
    }
    CallScope(const CallScope&)            = delete;
    CallScope& operator=(const CallScope&) = delete;

private:
    ScriptEngineContext& m_context;
    SceneRuntimeContext* m_previous_runtime;
    int64_t              m_previous_deadline;
    bool                 m_previous_interrupted;
};

int InterruptHandler(JSRuntime*, void* opaque) {
    auto* context = static_cast<ScriptEngineContext*>(opaque);
    if (context->deadline_ns == 0) return 0;
    if (context->NowNanoseconds() < context->deadline_ns) return 0;
    context->interrupted = true;
    return 1;
}

JSValue NativeThunk(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv, int magic) {
    auto* context = static_cast<ScriptEngineContext*>(JS_GetContextOpaque(ctx));
    return context->NativeCall(magic, argc, argv);
}

} // namespace

ScriptEngineContext::ScriptEngineContext(const ScriptLimits& configured) : limits(configured) {
    for (auto& entry : lib) entry = JS_UNDEFINED;
    for (auto& entry : vector_classes) entry = JS_UNDEFINED;
    rt = JS_NewRuntime();
    if (rt == nullptr) {
        broken = true;
        return;
    }
    ctx = JS_NewContext(rt);
    if (ctx == nullptr) {
        broken = true;
        return;
    }
    JS_SetContextOpaque(ctx, this);
    JS_SetInterruptHandler(rt, InterruptHandler, this);
    ApplyLimits(configured);
}

ScriptEngineContext::~ScriptEngineContext() {
    if (ctx != nullptr) {
        for (auto& entry : lib) JS_FreeValue(ctx, entry);
        for (auto& entry : vector_classes) JS_FreeValue(ctx, entry);
        for (auto& [text, compiled_entry] : compiled) JS_FreeValue(ctx, compiled_entry.factory);
        compiled.clear();
        JS_FreeContext(ctx);
    }
    if (rt != nullptr) JS_FreeRuntime(rt);
}

void ScriptEngineContext::ApplyLimits(const ScriptLimits& configured) {
    limits = configured;
    if (rt == nullptr) return;
    JS_SetMemoryLimit(rt, limits.memory_limit_bytes);
    JS_SetMaxStackSize(rt, limits.stack_limit_bytes);
}

#if defined(__APPLE__)
namespace
{
// Where the calling thread's stack begins and how large it is, asked of the system once
// per thread: the main thread's answer is a system call, and this runs on every entry.
struct ThreadStackBounds {
    const char* top { nullptr };
    std::size_t total { 0 };
};

const ThreadStackBounds& BoundsOfThisThread() {
    thread_local const ThreadStackBounds bounds = [] {
        const pthread_t self = pthread_self();
        return ThreadStackBounds { static_cast<const char*>(pthread_get_stackaddr_np(self)),
                                   static_cast<std::size_t>(pthread_get_stacksize_np(self)) };
    }();
    return bounds;
}
} // namespace
#endif

void ScriptEngineContext::AdoptThreadStack() {
    if (rt == nullptr) return;
    std::size_t size = limits.stack_limit_bytes;
#if defined(__APPLE__)
    // The limit may not reach past the end of the stack of the thread that is running:
    // a secondary thread has far less than the configured size, and running off its
    // end is a crash where a deep script should get a RangeError.
    const auto&       bounds = BoundsOfThisThread();
    const char        here   = 0;
    const std::size_t used   = bounds.top > &here ? static_cast<std::size_t>(bounds.top - &here) : 0;
    const std::size_t room   = bounds.total > used ? bounds.total - used : 0;
    // What the host code a script call reaches (layer creation, parsing) needs.
    constexpr std::size_t kHostReserve = 128u * 1024u;
    constexpr std::size_t kLeastStack  = 16u * 1024u;
    size = std::min(size, room > kHostReserve + kLeastStack ? room - kHostReserve : kLeastStack);
#endif
    JS_SetMaxStackSize(rt, size);
    // The limit is measured from where the stack was when the runtime was told.
    JS_UpdateStackTop(rt);
}

int64_t ScriptEngineContext::NowNanoseconds() const {
    if (limits.clock_nanoseconds) return limits.clock_nanoseconds();
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
               std::chrono::steady_clock::now().time_since_epoch())
        .count();
}

double ScriptEngineContext::LogSeconds() const {
    if (limits.log_clock_seconds) return limits.log_clock_seconds();
    return static_cast<double>(NowNanoseconds()) / 1.0e9;
}

std::string ScriptEngineContext::TakeException(std::string* stack) {
    JSValue     exception = JS_GetException(ctx);
    std::string message;
    if (JS_IsObject(exception)) {
        JSValue text = JS_GetPropertyStr(ctx, exception, "message");
        if (! JS_IsUndefined(text)) {
            if (const char* c = JS_ToCString(ctx, text)) {
                message = c;
                JS_FreeCString(ctx, c);
            }
        }
        JS_FreeValue(ctx, text);
        if (stack != nullptr) {
            JSValue trace = JS_GetPropertyStr(ctx, exception, "stack");
            if (JS_IsString(trace)) {
                if (const char* c = JS_ToCString(ctx, trace)) {
                    *stack = c;
                    JS_FreeCString(ctx, c);
                }
            }
            JS_FreeValue(ctx, trace);
        }
    }
    if (message.empty()) {
        if (const char* c = JS_ToCString(ctx, exception)) {
            message = c;
            JS_FreeCString(ctx, c);
        } else {
            message = "unprintable error";
        }
    }
    if (JS_IsUncatchableError(exception)) JS_ClearUncatchableError(ctx, exception);
    JS_FreeValue(ctx, exception);
    // A failed conversion above may itself have thrown.
    if (JS_HasException(ctx)) JS_FreeValue(ctx, JS_GetException(ctx));
    return message;
}

bool ScriptEngineContext::PumpJobs() {
    while (JS_IsJobPending(rt)) {
        JSContext* job_context = nullptr;
        const int  status      = JS_ExecutePendingJob(rt, &job_context);
        if (status < 0 && job_context != nullptr) {
            std::string stack;
            const auto  message = TakeException(&stack);
            // A job that ran out of time is an interrupted call like any other.
            if (interrupted) return true;
            ReportError("job", message, stack);
        }
        if (status <= 0) break;
    }
    return false;
}

void ScriptEngineContext::ReportError(const std::string& entry, std::string message,
                                      const std::string& stack) {
    if (message.size() > limits.max_error_text_chars) {
        std::size_t cut = limits.max_error_text_chars;
        // Never in the middle of a UTF-8 sequence.
        while (cut > 0 && (static_cast<unsigned char>(message[cut]) & 0xC0u) == 0x80u) --cut;
        message.resize(cut);
    }
    const std::string record = entry + ": " + message;
    if (runtime != nullptr) runtime->RecordScriptError(record);

    // The first few errors of an entry point are logged in full; after that one
    // summary line per period says how many were held back.
    auto& log           = log_records[entry];
    const double now    = LogSeconds();
    if (log.logged < limits.log_full_count) {
        ++log.logged;
        LOG_ERROR("script error in %s", record.c_str());
        if (! stack.empty()) LOG_ERROR("%s", stack.c_str());
        return;
    }
    ++log.suppressed;
    if (! log.summarized || now - log.last_summary >= limits.log_summary_seconds) {
        LOG_ERROR("script errors in %s: %d more since the last report, latest: %s", entry.c_str(),
                  log.suppressed, record.c_str());
        log.summarized   = true;
        log.last_summary = now;
        log.suppressed   = 0;
    }
}

JSValue ScriptEngineContext::Factory(bool scene, const std::string& source, std::string* error) {
    std::string key = scene ? "S" : "V";
    key += source;
    auto found = compiled.find(key);
    if (found == compiled.end()) {
        ++g_startup_metrics.script_compiles;
        const auto strip_start = std::chrono::steady_clock::now();
        const auto body        = NormalizeScript(source);
        g_startup_metrics.module_strip_ms += MillisecondsSince(strip_start);
        const auto wrap_start = std::chrono::steady_clock::now();
        const auto wrapped    = WrapScript(body);
        g_startup_metrics.wrapper_build_ms += MillisecondsSince(wrap_start);
        const auto eval_start = std::chrono::steady_clock::now();
        Compiled   entry;
        JSValue    factory = JS_Eval(ctx, wrapped.data(), wrapped.size(), "<script>", JS_EVAL_TYPE_GLOBAL);
        if (JS_IsException(factory)) {
            entry.error = TakeException(nullptr);
            if (entry.error.empty()) entry.error = "script does not compile";
        } else {
            entry.factory = factory;
        }
        g_startup_metrics.eval_ms += MillisecondsSince(eval_start);
        found = compiled.emplace(std::move(key), std::move(entry)).first;
    }
    if (JS_IsUndefined(found->second.factory)) {
        if (error != nullptr) *error = found->second.error;
        return JS_UNDEFINED;
    }
    return found->second.factory;
}

void ScriptEngineContext::RecordInterrupt(ScriptGuard* guard, const char* entry, double budget_ms) {
    // A call that borrowed the budget of the scope around it names that one.
    const double shown   = budget_ms > 0.0 ? budget_ms : limits.call_budget_ms;
    const auto   message = "interrupted after " + std::to_string(static_cast<long long>(shown)) + " ms";
    // The interrupted call may have left transient script state behind. The budget it
    // ran out of may be the one of the scope still open, so this runs without one.
    if (! JS_IsUndefined(lib[kLibResetTransient])) {
        const int64_t open_deadline = deadline_ns;
        deadline_ns                 = 0;
        JSValue reset = JS_Call(ctx, lib[kLibResetTransient], JS_UNDEFINED, 0, nullptr);
        deadline_ns   = open_deadline;
        if (JS_IsException(reset)) TakeException(nullptr);
        JS_FreeValue(ctx, reset);
    }
    if (guard != nullptr && ++guard->interrupts >= limits.max_consecutive_interrupts && ! guard->disabled) {
        guard->disabled = true;
        ReportError(entry, message, "");
        ReportError("disabled", "script " + guard->name + " was interrupted on " +
                                    std::to_string(guard->interrupts) +
                                    " consecutive calls and is switched off",
                    "");
        return;
    }
    ReportError(entry, message, "");
}

bool ScriptEngineContext::Overran(ScriptGuard* guard, const char* entry, double budget_ms) {
    if (! interrupted) return false;
    interrupted = false;
    // The interrupt left its exception behind in whatever C call it stopped.
    if (JS_HasException(ctx)) TakeException(nullptr);
    RecordInterrupt(guard, entry, budget_ms);
    return true;
}

bool ScriptEngineContext::Call(ScriptGuard* guard, const char* entry, LibFn fn,
                               std::initializer_list<JSValue> args, double budget_ms,
                               JSValue* result) {
    JSValue argv[20];
    int     argc = 0;
    for (const JSValue value : args) argv[argc++] = value;
    // The call consumes its arguments whatever happens.
    JSValue answer = JS_UNDEFINED;
    bool    expired = false;
    {
        CallScope scope(*this, nullptr, budget_ms);
        answer = JS_Call(ctx, lib[fn], JS_UNDEFINED, argc, argv);
        if (! JS_IsException(answer) && PumpJobs()) {
            // The call itself finished, but a job it queued did not: the call counts as
            // interrupted and its answer is not used.
            JS_FreeValue(ctx, answer);
            answer = JS_EXCEPTION;
        }
        expired = interrupted;
    }
    for (int i = 0; i < argc; ++i) JS_FreeValue(ctx, argv[i]);
    if (JS_IsException(answer)) {
        if (expired) {
            // The interrupt's exception, if still pending, is of no interest.
            if (JS_HasException(ctx)) TakeException(nullptr);
            RecordInterrupt(guard, entry, budget_ms);
        } else {
            std::string stack;
            const auto  message = TakeException(&stack);
            ReportError(entry, message, stack);
        }
        return false;
    }
    if (guard != nullptr) guard->interrupts = 0;
    if (result != nullptr) {
        *result = answer;
    } else {
        JS_FreeValue(ctx, answer);
    }
    return true;
}

JSValue ScriptEngineContext::NewVector(int size, double x, double y, double z, double w) {
    JSValue argv[4] = { JS_NewFloat64(ctx, x), JS_NewFloat64(ctx, y), JS_NewFloat64(ctx, z),
                        JS_NewFloat64(ctx, w) };
    JSValue vector  = JS_CallConstructor(ctx, vector_classes[size - 2], size, argv);
    for (auto& entry : argv) JS_FreeValue(ctx, entry);
    if (JS_IsException(vector)) {
        // A script that tampered with the vector classes' prototypes made the constructor throw.
        if (JS_HasException(ctx)) JS_FreeValue(ctx, JS_GetException(ctx));
        return JS_UNDEFINED;
    }
    return vector;
}

JSValue ScriptEngineContext::ToJs(const DynamicValue& value, bool degrees) {
    using Type = DynamicValue::UnderlyingType;
    switch (value.getType()) {
    case Type::Null: return JS_NULL;
    case Type::Float: return JS_NewFloat64(ctx, static_cast<double>(value.getFloat()));
    case Type::Int: return JS_NewInt32(ctx, value.getInt());
    case Type::Boolean: return JS_NewBool(ctx, value.getBool());
    case Type::String:
        return JS_NewStringLen(ctx, value.getString().data(), value.getString().size());
    case Type::Vec2: return NewVector(2, value.getVec2().x(), value.getVec2().y(), 0, 0);
    case Type::Vec3: {
        const double scale = degrees ? 180.0 / 3.14159265358979323846 : 1.0;
        const auto&  v     = value.getVec3();
        return NewVector(3, static_cast<double>(v.x()) * scale, static_cast<double>(v.y()) * scale,
                         static_cast<double>(v.z()) * scale, 0);
    }
    case Type::Vec4:
        return NewVector(4, value.getVec4().x(), value.getVec4().y(), value.getVec4().z(),
                         value.getVec4().w());
    case Type::IVec2: return NewVector(2, value.getIVec2().x(), value.getIVec2().y(), 0, 0);
    case Type::IVec3:
        return NewVector(3, value.getIVec3().x(), value.getIVec3().y(), value.getIVec3().z(), 0);
    case Type::IVec4:
        return NewVector(4, value.getIVec4().x(), value.getIVec4().y(), value.getIVec4().z(),
                         value.getIVec4().w());
    }
    return JS_UNDEFINED;
}

JSValue ScriptEngineContext::PropsToJs(const ProjectProperties& props) {
    JSValue object = JS_NewObject(ctx);
    for (const auto& [name, value] : props) {
        JSValue js = JS_UNDEFINED;
        switch (value.kind) {
        case RuntimeScalarValue::Kind::Bool: js = JS_NewBool(ctx, value.bool_value); break;
        case RuntimeScalarValue::Kind::Float:
            js = JS_NewFloat64(ctx, static_cast<double>(value.float_value));
            break;
        case RuntimeScalarValue::Kind::String:
            js = JS_NewStringLen(ctx, value.string_value.data(), value.string_value.size());
            break;
        }
        JS_SetPropertyStr(ctx, object, name.c_str(), js);
    }
    return object;
}

void ScriptEngineContext::PushProps(const ProjectProperties& props) {
    if (have_pushed_props && ProjectPropertiesEqual(pushed_props, props)) return;
    pushed_props      = props;
    have_pushed_props = true;
    Call(nullptr, "setProps", kLibSetProps, { PropsToJs(props) }, 0.0);
}

void ScriptEngineContext::RefreshHost(const ScriptHostContext& host) {
    unsigned mask = 0;
    if (! have_host) {
        mask = 0xFFu;
    } else {
        const auto& last = last_host;
        if (host.canvas_size != last.canvas_size) mask |= 1u;
        if (host.screen_resolution != last.screen_resolution) mask |= 2u;
        if (host.frame_time != last.frame_time || host.runtime_seconds != last.runtime_seconds) mask |= 4u;
        if (host.cursor_normalized_position != last.cursor_normalized_position) mask |= 8u;
        if (host.cursor_world_position != last.cursor_world_position) mask |= 16u;
        if (host.mouse_buttons_down != last.mouse_buttons_down ||
            host.mouse_buttons_pressed != last.mouse_buttons_pressed ||
            host.mouse_buttons_released != last.mouse_buttons_released) {
            mask |= 32u;
        }
        if (host.cursor_in_window != last.cursor_in_window) mask |= 64u;
        if (host.language != last.language) mask |= 128u;
    }
    if (mask == 0) return;
    last_host = host;
    have_host = true;
    Call(nullptr, "hostUpdate", kLibHostUpdate,
         { JS_NewUint32(ctx, mask),
           JS_NewFloat64(ctx, host.canvas_size.x()),
           JS_NewFloat64(ctx, host.canvas_size.y()),
           JS_NewFloat64(ctx, host.screen_resolution.x()),
           JS_NewFloat64(ctx, host.screen_resolution.y()),
           JS_NewFloat64(ctx, host.frame_time),
           JS_NewFloat64(ctx, host.runtime_seconds),
           JS_NewFloat64(ctx, host.cursor_normalized_position.x()),
           JS_NewFloat64(ctx, host.cursor_normalized_position.y()),
           JS_NewFloat64(ctx, host.cursor_world_position.x()),
           JS_NewFloat64(ctx, host.cursor_world_position.y()),
           JS_NewFloat64(ctx, host.cursor_world_position.z()),
           JS_NewBool(ctx, host.cursor_in_window),
           JS_NewUint32(ctx, host.mouse_buttons_down),
           JS_NewUint32(ctx, host.mouse_buttons_pressed),
           JS_NewUint32(ctx, host.mouse_buttons_released),
           (mask & 128u) != 0 ? JS_NewStringLen(ctx, host.language.data(), host.language.size())
                              : JS_UNDEFINED },
         0.0);
}


DynamicValueUniquePtr ScriptEngineContext::FromJs(JSValueConst value, const DynamicValue& hint,
                                                  bool degrees) {
    using Type = DynamicValue::UnderlyingType;
    const Type hint_type = hint.getType();
    const bool integer_vector = hint_type == Type::IVec2 || hint_type == Type::IVec3 || hint_type == Type::IVec4;
    const bool vector_hint = integer_vector || hint_type == Type::Vec2 || hint_type == Type::Vec3 ||
                             hint_type == Type::Vec4;
    int hint_size = 3;
    if (hint_type == Type::Vec2 || hint_type == Type::IVec2) hint_size = 2;
    if (hint_type == Type::Vec4 || hint_type == Type::IVec4) hint_size = 4;

    const auto vector_of = [&](int size, double x, double y, double z, double w) -> DynamicValueUniquePtr {
        if (integer_vector) {
            const auto cast = [](double d) {
                return std::isfinite(d) ? static_cast<int>(std::clamp(d, -2147483648.0, 2147483647.0)) : 0;
            };
            if (size == 2) return std::make_unique<DynamicValue>(linalg::Vector2i(cast(x), cast(y)));
            if (size == 3) return std::make_unique<DynamicValue>(linalg::Vector3i(cast(x), cast(y), cast(z)));
            return std::make_unique<DynamicValue>(linalg::Vector4i(cast(x), cast(y), cast(z), cast(w)));
        }
        const auto f = [](double d) { return static_cast<float>(d); };
        if (size == 2) return std::make_unique<DynamicValue>(linalg::Vector2f(f(x), f(y)));
        if (size == 3) {
            const double scale = degrees ? 3.14159265358979323846 / 180.0 : 1.0;
            return std::make_unique<DynamicValue>(linalg::Vector3f(f(x * scale), f(y * scale), f(z * scale)));
        }
        return std::make_unique<DynamicValue>(linalg::Vector4f(f(x), f(y), f(z), f(w)));
    };

    if (JS_IsUndefined(value)) return nullptr;
    if (JS_IsBool(value)) return std::make_unique<DynamicValue>(JS_ToBool(ctx, value) > 0);
    if (JS_IsString(value)) {
        size_t      length = 0;
        const char* chars  = JS_ToCStringLen(ctx, &length, value);
        if (chars == nullptr) {
            if (JS_HasException(ctx)) JS_FreeValue(ctx, JS_GetException(ctx));
            return nullptr;
        }
        std::string text(chars, length);
        JS_FreeCString(ctx, chars);
        if (! vector_hint) return std::make_unique<DynamicValue>(std::move(text));
        double parts[4] = { 0, 0, 0, 0 };
        int    count    = 0;
        const char* cursor = text.c_str();
        while (count < 4) {
            while (*cursor == ' ' || *cursor == '\t' || *cursor == ',' || *cursor == '\n') ++cursor;
            if (*cursor == '\0') break;
            char* end = nullptr;
            const double parsed = std::strtod(cursor, &end);
            if (end == cursor) break;
            parts[count++] = std::isfinite(parsed) ? parsed : 0.0;
            cursor         = end;
        }
        return vector_of(hint_size, parts[0], parts[1], parts[2], parts[3]);
    }
    if (JS_IsObject(value) && ! JS_IsFunction(ctx, value)) {
        // An object where the property is a flag gives no value.
        if (hint_type == Type::Boolean) return nullptr;
        double components[4] = { 0, 0, 0, 0 };
        static constexpr const char* names[4] = { "x", "y", "z", "w" };
        for (int i = 0; i < 4; ++i) {
            JSValue field = JS_GetPropertyStr(ctx, value, names[i]);
            if (JS_IsNumber(field)) {
                double d = 0;
                if (JS_ToFloat64(ctx, &d, field) == 0) components[i] = d;
            }
            JS_FreeValue(ctx, field);
        }
        if (JS_HasException(ctx)) JS_FreeValue(ctx, JS_GetException(ctx));
        return vector_of(vector_hint ? hint_size : 3, components[0], components[1], components[2],
                         components[3]);
    }
    // A number, null, or anything else that converts to one.
    double number = 0.0;
    if (JS_IsNull(value)) {
        number = 0.0;
    } else if (JS_ToFloat64(ctx, &number, value) < 0) {
        if (JS_HasException(ctx)) JS_FreeValue(ctx, JS_GetException(ctx));
        return nullptr;
    }
    if (vector_hint) return vector_of(hint_size, number, number, number, number);
    if (std::isfinite(number) && number == std::trunc(number) && std::fabs(number) <= 2147483647.0) {
        if (hint_type == Type::Float) return std::make_unique<DynamicValue>(static_cast<float>(number));
        return std::make_unique<DynamicValue>(static_cast<int>(number));
    }
    return std::make_unique<DynamicValue>(static_cast<float>(number));
}

bool ScriptEngineContext::EnsureReady() {
    if (ready) return true;
    if (broken || ctx == nullptr) return false;
    AdoptThreadStack();
    const auto start = std::chrono::steady_clock::now();
    const auto fail  = [&](const char* stage) {
        const auto message = TakeException(nullptr);
        LOG_ERROR("script library %s failed: %s", stage, message.c_str());
        broken = true;
        return false;
    };
    {
        JSValue vectors = JS_Eval(ctx, kVectorBootstrap, std::strlen(kVectorBootstrap), "<vectors>",
                                  JS_EVAL_TYPE_GLOBAL);
        if (JS_IsException(vectors)) return fail("vector classes");
        JS_FreeValue(ctx, vectors);
    }
    JSValue global = JS_GetGlobalObject(ctx);
    static constexpr const char* class_names[3] = { "__WEVec2", "__WEVec3", "__WEVec4" };
    for (int i = 0; i < 3; ++i) vector_classes[i] = JS_GetPropertyStr(ctx, global, class_names[i]);
    JS_FreeValue(ctx, global);
    g_startup_metrics.bootstrap_build_ms += MillisecondsSince(start);

    const auto text = CompleteLibraryText();
    JSValue    factory = JS_Eval(ctx, text.data(), text.size(), "<library>", JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(factory)) return fail("script load");
    JSValue natives = JS_NewObject(ctx);
    for (std::size_t i = 0; i < std::size(kNativeNames); ++i) {
        JSValue function = JS_NewCFunctionMagic(ctx, NativeThunk, kNativeNames[i], 0,
                                                JS_CFUNC_generic_magic, static_cast<int>(i));
        JS_SetPropertyStr(ctx, natives, kNativeNames[i], function);
    }
    JSValue api = JS_Call(ctx, factory, JS_UNDEFINED, 1, &natives);
    JS_FreeValue(ctx, natives);
    JS_FreeValue(ctx, factory);
    if (JS_IsException(api)) return fail("start");
    for (int i = 0; i < kLibFnCount; ++i) lib[i] = JS_GetPropertyStr(ctx, api, kLibFnNames[i]);
    JS_FreeValue(ctx, api);
    for (int i = 0; i < kLibFnCount; ++i) {
        if (JS_IsFunction(ctx, lib[i])) continue;
        LOG_ERROR("script library lacks the entry point %s", kLibFnNames[i]);
        broken = true;
        return false;
    }
    ready = true;
    ++g_startup_metrics.bootstrap_installs;
    g_startup_metrics.bootstrap_build_ms += MillisecondsSince(start);
    return true;
}

JSValue ScriptEngineContext::NativeCall(int id, int argc, JSValueConst* argv) {
    SceneRuntimeContext* rt_ = runtime;
    const auto str = [&](int i) -> std::string {
        std::string out;
        if (i >= argc) return out;
        size_t      length = 0;
        const char* chars  = JS_ToCStringLen(ctx, &length, argv[i]);
        if (chars != nullptr) {
            out.assign(chars, length);
            JS_FreeCString(ctx, chars);
        } else if (JS_HasException(ctx)) {
            JS_FreeValue(ctx, JS_GetException(ctx));
        }
        return out;
    };
    const auto num = [&](int i) -> double {
        double d = 0.0;
        if (i < argc && JS_ToFloat64(ctx, &d, argv[i]) < 0) {
            d = 0.0;
            if (JS_HasException(ctx)) JS_FreeValue(ctx, JS_GetException(ctx));
        }
        return d;
    };
    const auto has = [&](int i) { return i < argc && ! JS_IsUndefined(argv[i]); };
    const auto flag = [&](int i) { return i < argc && JS_ToBool(ctx, argv[i]) > 0; };
    const auto text = [&](const std::string& value) {
        return JS_NewStringLen(ctx, value.data(), value.size());
    };
    const auto boolean = [&](bool value) { return JS_NewBool(ctx, value); };
    const auto number  = [&](double value) { return JS_NewFloat64(ctx, value); };
    const auto array   = [&](std::initializer_list<double> values) {
        JSValue   out   = JS_NewArray(ctx);
        uint32_t  index = 0;
        for (const double d : values) JS_SetPropertyUint32(ctx, out, index++, JS_NewFloat64(ctx, d));
        return out;
    };
    const auto vec3 = [&](int first) {
        return linalg::Vector3f(static_cast<float>(num(first)), static_cast<float>(num(first + 1)),
                                static_cast<float>(num(first + 2)));
    };
    // Only the calls that read a node's state ask whether it exists.
    const auto node_known = [&] { return rt_ != nullptr && argc > 0 && rt_->HasNodeNamed(str(0)); };

    switch (id) {
    case kNative_error: ReportError(str(0), str(1), str(2)); return JS_UNDEFINED;
    case kNative_resolve: {
        const auto name = str(0);
        return text(rt_ != nullptr ? rt_->ResolveLayerName(name) : name);
    }
    case kNative_hasNode: return boolean(node_known());
    case kNative_layerCount: return number(rt_ != nullptr ? static_cast<double>(rt_->LayerCount()) : 0.0);
    case kNative_layerNameAt: {
        const double index = num(0);
        return text(rt_ != nullptr && index >= 0 ? rt_->LayerNameAt(static_cast<std::size_t>(index))
                                                  : std::string());
    }
    case kNative_layerIndex: return number(rt_ != nullptr ? rt_->LayerIndex(str(0)) : -1);
    case kNative_sortLayer:
        return boolean(rt_ != nullptr && rt_->SortLayer(str(0), static_cast<int>(std::min(num(1), 1.0e9))));
    case kNative_layerById: {
        const double id = num(0);
        const bool   ok = rt_ != nullptr && id >= -2147483648.0 && id <= 2147483647.0;
        return text(ok ? rt_->LayerNameForId(static_cast<int32_t>(id)) : std::string());
    }
    case kNative_authoredName: {
        const auto key = str(0);
        return text(rt_ != nullptr ? rt_->LayerAuthoredName(key) : key);
    }
    case kNative_requestConfig:
        if (rt_ != nullptr) rt_->RequestInitialLayerConfig();
        return JS_UNDEFINED;
    case kNative_initialConfig:
        return text(rt_ != nullptr ? rt_->InitialLayerConfigJson(str(0)) : std::string());
    case kNative_visible: return boolean(node_known() && rt_->NodeVisible(str(0)));
    case kNative_setVisible:
        if (rt_ != nullptr) rt_->SetNodeVisible(str(0), flag(1));
        return JS_UNDEFINED;
    case kNative_origin: {
        const auto v = node_known() ? rt_->NodeTranslate(str(0)) : linalg::Vector3f(0, 0, 0);
        return array({ v.x(), v.y(), v.z() });
    }
    case kNative_setOrigin:
        if (rt_ != nullptr) rt_->SetNodeTranslate(str(0), vec3(1));
        return JS_UNDEFINED;
    case kNative_scale: {
        const auto v = node_known() ? rt_->NodeScale(str(0)) : linalg::Vector3f(1, 1, 1);
        return array({ v.x(), v.y(), v.z() });
    }
    case kNative_setScale:
        if (rt_ != nullptr) rt_->SetNodeScale(str(0), vec3(1));
        return JS_UNDEFINED;
    case kNative_rotation: {
        const auto v = node_known() ? rt_->NodeRotation(str(0)) : linalg::Vector3f(0, 0, 0);
        return array({ v.x(), v.y(), v.z() });
    }
    case kNative_setRotation:
        if (rt_ != nullptr) rt_->SetNodeRotation(str(0), vec3(1));
        return JS_UNDEFINED;
    case kNative_size: {
        const auto v = rt_ != nullptr ? rt_->NodeSize(str(0)) : linalg::Vector2f(0, 0);
        return array({ v.x(), v.y() });
    }
    case kNative_color: {
        const auto v = node_known() ? rt_->NodeColor(str(0)) : linalg::Vector3f(1, 1, 1);
        return array({ v.x(), v.y(), v.z() });
    }
    case kNative_setColor:
        if (rt_ != nullptr) rt_->SetNodeColor(str(0), vec3(1));
        return JS_UNDEFINED;
    case kNative_alpha: {
        if (rt_ == nullptr) return JS_UNDEFINED;
        const auto value = rt_->NodeAlpha(str(0));
        return value.has_value() ? number(static_cast<double>(*value)) : JS_UNDEFINED;
    }
    case kNative_setAlpha:
        if (rt_ != nullptr) rt_->SetNodeAlpha(str(0), static_cast<float>(num(1)));
        return JS_UNDEFINED;
    case kNative_text: return text(rt_ != nullptr ? rt_->NodeText(str(0)) : std::string());
    case kNative_setText:
        if (rt_ != nullptr) rt_->SetNodeText(str(0), str(1));
        return JS_UNDEFINED;
    case kNative_setAlignment:
        if (rt_ != nullptr) rt_->SetNodeAlignment(str(0), str(1));
        return JS_UNDEFINED;
    case kNative_textStyle: {
        if (rt_ == nullptr) return JS_UNDEFINED;
        const auto value = rt_->NodeTextStyle(str(0), str(1));
        return value.has_value() ? text(*value) : JS_UNDEFINED;
    }
    case kNative_setTextStyle:
        return boolean(rt_ != nullptr && rt_->SetNodeTextStyle(str(0), str(1), str(2)));
    case kNative_parent: return text(rt_ != nullptr ? rt_->NodeParentName(str(0)) : std::string());
    case kNative_setParent: return boolean(rt_ != nullptr && rt_->SetNodeParent(str(0), str(1)));
    case kNative_setSize:
        return boolean(rt_ != nullptr &&
                       rt_->SetNodeSize(str(0), linalg::Vector2f(static_cast<float>(num(1)),
                                                                  static_cast<float>(num(2)))));
    case kNative_parallax: {
        const auto v = rt_ != nullptr ? rt_->NodeParallaxDepth(str(0)) : linalg::Vector2f(0, 0);
        return array({ v.x(), v.y() });
    }
    case kNative_setParallax:
        if (rt_ != nullptr) {
            rt_->SetNodeParallaxDepth(str(0), linalg::Vector2f(static_cast<float>(num(1)),
                                                                static_cast<float>(num(2))));
        }
        return JS_UNDEFINED;
    case kNative_matrix: {
        const auto m = rt_ != nullptr ? rt_->NodeTransformMatrix(str(0)) : linalg::Matrix4d::Identity();
        JSValue out = JS_NewArray(ctx);
        for (uint32_t i = 0; i < 16; ++i) JS_SetPropertyUint32(ctx, out, i, JS_NewFloat64(ctx, m.data()[i]));
        return out;
    }
    case kNative_createFromTemplate:
        return text(rt_ != nullptr ? rt_->CreateLayerFromTemplate(str(0), str(1), str(2)) : std::string());
    case kNative_createText:
        return text(rt_ != nullptr ? rt_->CreateTextLayer(str(0), str(1)) : std::string());
    case kNative_nameLayer: return boolean(rt_ != nullptr && rt_->NameLayer(str(0), str(1)));
    case kNative_destroyLayer: {
        std::vector<std::string> destroyed;
        const bool               ok = rt_ != nullptr && rt_->DestroyLayer(str(0), &destroyed);
        JSValue out = JS_NewArray(ctx);
        JS_SetPropertyUint32(ctx, out, 0, boolean(ok));
        uint32_t index = 1;
        for (const auto& name : destroyed) JS_SetPropertyUint32(ctx, out, index++, text(name));
        return out;
    }
    case kNative_hasSound: return boolean(rt_ != nullptr && rt_->HasSoundLayer(str(0)));
    case kNative_soundPlay: return boolean(rt_ != nullptr && rt_->PlaySoundLayer(str(0)));
    case kNative_soundPause: return boolean(rt_ != nullptr && rt_->PauseSoundLayer(str(0)));
    case kNative_soundStop: return boolean(rt_ != nullptr && rt_->StopSoundLayer(str(0)));
    case kNative_soundPlaying: return boolean(rt_ != nullptr && rt_->SoundLayerPlaying(str(0)));
    case kNative_soundVolume:
        return number(rt_ != nullptr ? static_cast<double>(rt_->SoundLayerVolume(str(0))) : 0.0);
    case kNative_soundSetVolume:
        if (rt_ != nullptr) rt_->SetSoundLayerVolume(str(0), static_cast<float>(num(1)));
        return JS_UNDEFINED;
    case kNative_soundMuted: return boolean(rt_ != nullptr && rt_->SoundLayerMuted(str(0)));
    case kNative_soundSetMuted:
        if (rt_ != nullptr) rt_->SetSoundLayerMuted(str(0), flag(1));
        return JS_UNDEFINED;
    case kNative_puppet:
        return number(rt_ != nullptr ? rt_->PuppetAnimationControl(str(0), str(1), str(2), num(3), has(3))
                                     : 0.0);
    case kNative_puppetName: return text(rt_ != nullptr ? rt_->PuppetAnimationLayerName(str(0), str(1)) : std::string());
    case kNative_timeline: {
        if (rt_ == nullptr) return number(0);
        const auto layer = str(0);
        const auto name  = str(1);
        // A layer reference that starts with the setting marker is a setting's own clock.
        auto*      playback = layer.empty() ? rt_->FindAnimationByName(name)
                              : layer.front() == kSettingMarker ? rt_->FindSettingAnimation(layer.substr(1))
                                                                : rt_->FindScalarAnimation(layer, name);
        if (playback == nullptr) return number(0);
        const auto op = str(2);
        if (op == "fps") return number(playback->animation.fps);
        if (op == "frameCount") return number(playback->animation.FrameCount());
        if (op == "rate") return number(playback->rate);
        if (op == "setRate") { playback->rate = num(3); return number(1); }
        if (op == "play") { playback->Play(); return number(1); }
        if (op == "pause") { playback->playing = false; return number(1); }
        if (op == "stop") { playback->Stop(); return number(1); }
        if (op == "isPlaying") return number(playback->playing ? 1 : 0);
        if (op == "frame") return number(playback->frame);
        if (op == "setFrame") { playback->SetFrame(num(3)); return number(1); }
        return number(0);
    }
    case kNative_sheet: {
        if (rt_ == nullptr) return number(0);
        const auto key = str(0);
        const auto op  = str(1);
        if (op == "play") return number(rt_->PlayNodeTextureAnimation(key) ? 1 : 0);
        if (op == "pause") return number(rt_->PauseNodeTextureAnimation(key) ? 1 : 0);
        if (op == "stop") return number(rt_->StopNodeTextureAnimation(key) ? 1 : 0);
        if (op == "isPlaying") return number(rt_->NodeTextureAnimationPlaying(key) ? 1 : 0);
        if (op == "rate") return number(rt_->NodeTextureAnimationRate(key));
        if (op == "setRate") return number(rt_->SetNodeTextureAnimationRate(key, num(2)) ? 1 : 0);
        if (op == "frame") return number(rt_->NodeTextureAnimationFrame(key));
        if (op == "setFrame") return number(rt_->SetNodeTextureFrame(key, num(2)) ? 1 : 0);
        return number(0);
    }
    case kNative_sheetInfo: {
        if (rt_ == nullptr) return JS_UNDEFINED;
        const auto info = rt_->NodeTextureAnimation(str(0));
        if (! info.has_value()) return JS_UNDEFINED;
        JSValue out = JS_NewArray(ctx);
        JS_SetPropertyUint32(ctx, out, 0, text(info->name));
        JS_SetPropertyUint32(ctx, out, 1, number(static_cast<double>(info->frame_count)));
        JS_SetPropertyUint32(ctx, out, 2, number(info->duration));
        JS_SetPropertyUint32(ctx, out, 3, number(info->fps));
        return out;
    }
    case kNative_video: {
        const auto key = str(0);
        const auto op  = str(1);
        const bool present = rt_ != nullptr && rt_->NodeHasVideoTexture(key);
        if (op == "rate") return number(present ? static_cast<double>(rt_->NodeVideoTextureRate(key)) : 1.0);
        if (! present) return number(0);
        if (op == "play") return number(rt_->PlayNodeVideoTexture(key) ? 1 : 0);
        if (op == "pause") return number(rt_->PauseNodeVideoTexture(key) ? 1 : 0);
        if (op == "stop") {
            rt_->PauseNodeVideoTexture(key);
            return number(rt_->SetNodeVideoTextureCurrentTime(key, 0.0) ? 1 : 0);
        }
        if (op == "isPlaying") return number(rt_->NodeVideoTextureIsPlaying(key) ? 1 : 0);
        if (op == "time") return number(rt_->NodeVideoTextureCurrentTime(key));
        if (op == "setTime") return number(rt_->SetNodeVideoTextureCurrentTime(key, num(2)) ? 1 : 0);
        if (op == "duration") return number(rt_->NodeVideoTextureDuration(key));
        if (op == "setRate") return number(rt_->SetNodeVideoTextureRate(key, static_cast<float>(num(2))) ? 1 : 0);
        return number(0);
    }
    case kNative_audioMark:
        if (rt_ != nullptr) rt_->MarkSceneRequiresAudioResponse();
        return JS_UNDEFINED;
    case kNative_audioGeneration:
        return number(rt_ != nullptr ? static_cast<double>(rt_->CurrentAudioSpectrumSnapshot().generation)
                                     : 0.0);
    case kNative_audio: {
        const auto size = static_cast<int>(num(0));
        audio::AudioSpectrumSnapshot snapshot;
        if (rt_ != nullptr) snapshot = rt_->CurrentAudioSpectrumSnapshot();
        const float* bands[3] = { snapshot.left64.data(), snapshot.right64.data(), snapshot.average64.data() };
        if (size == 16) {
            bands[0] = snapshot.left16.data(); bands[1] = snapshot.right16.data(); bands[2] = snapshot.average16.data();
        } else if (size == 32) {
            bands[0] = snapshot.left32.data(); bands[1] = snapshot.right32.data(); bands[2] = snapshot.average32.data();
        }
        const int count = size == 16 ? 16 : (size == 32 ? 32 : 64);
        JSValue out = JS_NewArray(ctx);
        for (uint32_t channel = 0; channel < 3; ++channel) {
            JSValue values = JS_NewArray(ctx);
            for (int i = 0; i < count; ++i) {
                JS_SetPropertyUint32(ctx, values, static_cast<uint32_t>(i), number(static_cast<double>(bands[channel][i])));
            }
            JS_SetPropertyUint32(ctx, out, channel, values);
        }
        return out;
    }
    case kNative_shortcutValue: {
        if (rt_ == nullptr) return JS_UNDEFINED;
        const DynamicValue* property = rt_->FindPropertyValue(str(0));
        if (property == nullptr) return JS_UNDEFINED;
        return text(property->getType() == DynamicValue::String ? property->getString() : property->toString());
    }
    case kNative_requestShortcut: {
        if (rt_ == nullptr) return JS_UNDEFINED;
        const auto name  = str(0);
        const auto value = str(1);
        rt_->RequestUserShortcut(name, value);
        LOG_INFO("script asked for the user shortcut '%s' (bound to '%s')", name.c_str(), value.c_str());
        return JS_UNDEFINED;
    }
    case kNative_rotateObjectSpace:
        if (rt_ != nullptr) rt_->RotateNodeObjectSpace(str(0), vec3(1));
        return JS_UNDEFINED;
    case kNative_effectVisible: return boolean(rt_ != nullptr && rt_->EffectObjectVisible(str(0)));
    case kNative_setEffectVisible:
        if (rt_ != nullptr) rt_->SetEffectObjectVisible(str(0), flag(1));
        return JS_UNDEFINED;
    case kNative_timeOfDay: {
        const auto value = LocalTimeOfDay(std::chrono::system_clock::now());
        return number(value.value_or(0.0));
    }
    default: break;
    }
    return JS_UNDEFINED;
}


// ---------------------------------------------------------------------------
// Programs.
// ---------------------------------------------------------------------------

namespace
{

DynamicValueUniquePtr CopyOf(const DynamicValue& value) {
    auto copy = std::make_unique<DynamicValue>();
    copy->update(value);
    return copy;
}

constexpr const char* kCursorEntries[6] = { "cursorClick", "cursorDown", "cursorEnter",
                                            "cursorLeave", "cursorMove", "cursorUp" };

int CursorIndex(ScriptCursorEvent event) {
    switch (event) {
    case ScriptCursorEvent::Click: return 0;
    case ScriptCursorEvent::Down: return 1;
    case ScriptCursorEvent::Enter: return 2;
    case ScriptCursorEvent::Leave: return 3;
    case ScriptCursorEvent::Move: return 4;
    case ScriptCursorEvent::Up: return 5;
    }
    return 0;
}

// What both kinds of program keep: their record in the script world and the
// bookkeeping the native side needs to decide what a call may do.
struct ProgramCore {
    std::shared_ptr<ScriptEngineContext>      engine;
    SceneRuntimeContext*                      runtime { nullptr };
    JSValue                                   prog { JS_UNDEFINED };
    JSValue                                   params { JS_UNDEFINED };
    ScriptGuard                               guard;
    bool                                      valid { false };
    bool                                      started { false };
    bool                                      noticed { false };
    bool                                      destroyed { false };
    PropertyScriptValueSemantic               semantic { PropertyScriptValueSemantic::Generic };
    std::map<std::string, DynamicValue*>      props;
    std::unordered_map<std::string, uint64_t> param_generations;
    ProjectProperties                         snapshot;

    ~ProgramCore() {
        if (engine != nullptr && engine->ctx != nullptr) {
            JS_FreeValue(engine->ctx, prog);
            JS_FreeValue(engine->ctx, params);
        }
    }

    bool Usable() const { return valid && ! guard.disabled && engine != nullptr; }
    JSValue Prog() const { return JS_DupValue(engine->ctx, prog); }
};

bool IsVectorType(DynamicValue::UnderlyingType type) {
    using Type = DynamicValue::UnderlyingType;
    return type == Type::Vec2 || type == Type::Vec3 || type == Type::Vec4 || type == Type::IVec2 ||
           type == Type::IVec3 || type == Type::IVec4;
}

// The scene file's parameters go onto the script's parameter object by name:
// scalars every time, a vector only when the property changed since it was last given.
void WriteParams(ProgramCore& core) {
    auto& e = *core.engine;
    for (const auto& [name, value] : core.props) {
        if (value == nullptr) continue;
        if (IsVectorType(value->getType())) {
            const uint64_t generation = value->Generation();
            const auto     known      = core.param_generations.find(name);
            if (known != core.param_generations.end() && known->second == generation) continue;
            core.param_generations[name] = generation;
        }
        JSValue js = e.ToJs(*value, false);
        if (JS_SetPropertyStr(e.ctx, core.params, name.c_str(), js) < 0) {
            if (JS_HasException(e.ctx)) JS_FreeValue(e.ctx, JS_GetException(e.ctx));
            // A setter the script defined on its parameters ran out of time.
            if (e.interrupted) return;
        }
    }
}

bool CreateProgram(ProgramCore& core, bool scene, const std::string& source, const std::string& layer,
                   const ScriptHostContext& host, int animation_layer_index, int& capabilities,
                   const std::string& effect_reference = {}, const std::string& animation_reference = {}) {
    auto& e = *core.engine;
    CallScope scope(e, core.runtime, e.limits.creation_budget_ms);
    e.RefreshHost(host);
    if (scene) {
        e.PushProps(core.snapshot);
    } else if (core.runtime != nullptr) {
        e.PushProps(core.runtime->projectProperties());
    }
    // A script that asks for the scene's own object list makes the loader keep it.
    if (core.runtime != nullptr && source.find("getInitialLayerConfig") != std::string::npos) {
        core.runtime->RequestInitialLayerConfig();
    }
    std::string error;
    JSValue     factory = e.Factory(scene, source, &error);
    if (JS_IsUndefined(factory)) {
        e.ReportError("script load", error, "");
        return false;
    }
    JSValue record = JS_UNDEFINED;
    if (! e.Call(&core.guard, "script start", kLibMake,
                 { JS_DupValue(e.ctx, factory), JS_NewInt32(e.ctx, scene ? 1 : 0),
                   JS_NewStringLen(e.ctx, layer.data(), layer.size()),
                   JS_NewInt32(e.ctx, animation_layer_index),
                   JS_NewStringLen(e.ctx, effect_reference.data(), effect_reference.size()),
                   JS_NewStringLen(e.ctx, animation_reference.data(), animation_reference.size()) },
                 e.limits.creation_budget_ms, &record)) {
        return false;
    }
    core.prog   = record;
    core.params = JS_GetPropertyStr(e.ctx, record, "sp");
    JSValue caps = JS_GetPropertyStr(e.ctx, record, "caps");
    int32_t bits = 0;
    JS_ToInt32(e.ctx, &bits, caps);
    JS_FreeValue(e.ctx, caps);
    capabilities = bits;
    core.valid   = true;
    return true;
}

ScriptProgramCapabilities CapabilitiesOf(int bits) {
    ScriptProgramCapabilities caps;
    caps.update          = (bits & 1) != 0;
    caps.cursor_handlers = static_cast<uint8_t>((bits >> 1) & 63);
    caps.animation_event = (bits & 128) != 0;
    return caps;
}

void DispatchCursor(ProgramCore& core, const ScriptProgramCapabilities& caps, ScriptCursorEvent event,
                    const ScriptHostContext& host, bool needs_capability) {
    if (! core.Usable() || core.destroyed) return;
    const int index = CursorIndex(event);
    if (needs_capability && (caps.cursor_handlers & static_cast<uint8_t>(event)) == 0) return;
    auto& e = *core.engine;
    CallScope scope(e, core.runtime, e.limits.call_budget_ms);
    e.RefreshHost(host);
    e.Call(&core.guard, kCursorEntries[index], kLibCursorEvent,
           { core.Prog(), JS_NewInt32(e.ctx, index), JS_NewInt32(e.ctx, host.cursor_button) },
           e.limits.call_budget_ms);
}

void DispatchAnimationMarker(ProgramCore& core, const ScriptProgramCapabilities& caps,
                             const ScriptHostContext& host, std::string_view name, double frame) {
    if (! core.Usable() || core.destroyed || ! caps.animation_event) return;
    auto& e = *core.engine;
    CallScope scope(e, core.runtime, e.limits.call_budget_ms);
    e.RefreshHost(host);
    e.Call(&core.guard, "animationEvent", kLibAnimationEvent,
           { core.Prog(), JS_NewStringLen(e.ctx, name.data(), name.size()), JS_NewFloat64(e.ctx, frame) },
           e.limits.call_budget_ms);
}

void DispatchThumbnail(ProgramCore& core, const linalg::Vector3f& primary, const linalg::Vector3f& text) {
    if (! core.Usable() || core.destroyed) return;
    auto& e = *core.engine;
    CallScope scope(e, core.runtime, e.limits.call_budget_ms);
    e.Call(&core.guard, "mediaThumbnailChanged", kLibMediaThumbnail,
           { core.Prog(), JS_NewFloat64(e.ctx, primary.x()), JS_NewFloat64(e.ctx, primary.y()),
             JS_NewFloat64(e.ctx, primary.z()), JS_NewFloat64(e.ctx, text.x()),
             JS_NewFloat64(e.ctx, text.y()), JS_NewFloat64(e.ctx, text.z()) },
           e.limits.call_budget_ms);
}

void DispatchMedia(ProgramCore& core, std::string_view json) {
    if (! core.Usable() || core.destroyed || json.empty()) return;
    auto& e = *core.engine;
    CallScope scope(e, core.runtime, e.limits.call_budget_ms);
    e.Call(&core.guard, "media dispatch", kLibMediaJson,
           { core.Prog(), JS_NewStringLen(e.ctx, json.data(), json.size()) }, e.limits.call_budget_ms);
}

void DispatchResize(ProgramCore& core, const ScriptHostContext& host, bool needs_start) {
    if (! core.Usable() || core.destroyed || (needs_start && ! core.started)) return;
    auto& e = *core.engine;
    CallScope scope(e, core.runtime, e.limits.call_budget_ms);
    e.RefreshHost(host);
    e.Call(&core.guard, "resizeScreen", kLibResizeProgram, { core.Prog() }, e.limits.call_budget_ms);
}

void DispatchLanguage(ProgramCore& core, const ScriptHostContext& host, bool needs_start) {
    if (! core.Usable() || core.destroyed || (needs_start && ! core.started)) return;
    auto& e = *core.engine;
    CallScope scope(e, core.runtime, e.limits.call_budget_ms);
    e.RefreshHost(host);
    e.Call(&core.guard, "applyGeneralSettings", kLibNoticeLanguage, { core.Prog() },
           e.limits.call_budget_ms);
}

void EndProgram(ProgramCore& core, bool needs_start) {
    if (! core.valid || core.destroyed || (needs_start && ! core.started)) return;
    core.destroyed = true;
    if (! core.Usable()) return;
    auto& e = *core.engine;
    CallScope scope(e, core.runtime, e.limits.call_budget_ms);
    e.Call(&core.guard, "destroy", kLibDestroyProgram, { core.Prog() }, e.limits.call_budget_ms);
}

void DeliverChanges(ProgramCore& core, const ProjectProperties& changed) {
    if (changed.empty()) return;
    auto& e = *core.engine;
    e.Call(&core.guard, "applyUserProperties", kLibApplyProps, { core.Prog(), e.PropsToJs(changed) },
           e.limits.call_budget_ms);
}

std::shared_ptr<ScriptEngineContext> ContextOf(JSContext* context) {
    auto* raw = static_cast<ScriptEngineContext*>(JS_GetContextOpaque(context));
    return raw != nullptr ? raw->shared_from_this() : nullptr;
}

ScriptLimits& DefaultLimits() {
    static ScriptLimits limits;
    return limits;
}

} // namespace

// ----- value programs -------------------------------------------------------

struct PropertyScriptProgram::State : ProgramCore {};

PropertyScriptProgram::PropertyScriptProgram(
    SceneRuntimeContext* runtime, std::string script_source, std::string current_layer_name,
    std::map<std::string, DynamicValue*> script_properties, DynamicValue, ScriptHostContext host_context,
    JSRuntime*, JSContext* shared_context, std::string, std::string, PropertyScriptValueSemantic semantic,
    int animation_layer_index, std::string effect_reference, std::string setting_animation_reference)
    : m_animation_layer_index(animation_layer_index) {
    auto engine = ContextOf(shared_context);
    if (engine == nullptr) return;
    m_state          = std::make_unique<State>();
    m_state->engine  = std::move(engine);
    m_state->runtime = runtime;
    m_state->semantic = semantic;
    m_state->props   = std::move(script_properties);
    m_state->guard.name = current_layer_name.empty() ? "scene" : current_layer_name;
    int capabilities = 0;
    if (! CreateProgram(*m_state, false, script_source, current_layer_name, host_context,
                        animation_layer_index, capabilities, effect_reference,
                        setting_animation_reference)) {
        return;
    }
    m_capabilities = CapabilitiesOf(capabilities);
    auto&     e      = *m_state->engine;
    CallScope scope(e, runtime, e.limits.call_budget_ms);
    WriteParams(*m_state);
    // Parameter accessors the script defined must not hold the loader up either; a
    // program that cannot be given its parameters in time is not started.
    if (e.Overran(&m_state->guard, "script parameters", e.limits.call_budget_ms)) m_state->valid = false;
}

PropertyScriptProgram::~PropertyScriptProgram() = default;

bool PropertyScriptProgram::Valid() const { return m_state != nullptr && m_state->valid && ! m_state->guard.disabled; }

void PropertyScriptProgram::ApplyProjectProperties(const ProjectProperties& project_properties,
                                                   const ProjectProperties& changed_properties) {
    if (! Valid() || m_destroyed) return;
    auto& core = *m_state;
    auto& e    = *core.engine;
    CallScope scope(e, core.runtime, e.limits.call_budget_ms);
    e.PushProps(project_properties);
    WriteParams(core);
    if (e.Overran(&core.guard, "script parameters", e.limits.call_budget_ms)) return;
    if (core.started) DeliverChanges(core, changed_properties);
}

bool PropertyScriptProgram::Initialised() const noexcept { return m_state != nullptr && m_state->started; }

DynamicValueUniquePtr PropertyScriptProgram::RunInit(const ScriptHostContext& host_context,
                                                     const DynamicValue&      current_value) {
    if (! Valid() || m_destroyed || m_state->started) return nullptr;
    auto&        core   = *m_state;
    auto&        e      = *core.engine;
    const double budget = e.limits.call_budget_ms;
    CallScope    scope(e, core.runtime, budget);
    e.RefreshHost(host_context);
    if (core.runtime != nullptr) e.PushProps(core.runtime->projectProperties());
    WriteParams(core);
    const bool degrees  = core.semantic == PropertyScriptValueSemantic::AnglesDegrees;
    JSValue    argument = e.ToJs(current_value, degrees);
    if (e.Overran(&core.guard, "init", budget)) {
        JS_FreeValue(e.ctx, argument);
        return nullptr;
    }
    JSValue result = JS_UNDEFINED;
    core.started   = true;
    const bool completed =
        e.Call(&core.guard, "init", kLibRunInit, { core.Prog(), argument }, budget, &result);
    // What `init` returns is converted as the result of `update` is.
    DynamicValueUniquePtr answer;
    if (completed) answer = e.FromJs(result, current_value, degrees);
    JS_FreeValue(e.ctx, result);
    if (e.Overran(&core.guard, "init", budget)) answer.reset();
    return answer;
}

void PropertyScriptProgram::RunUserNotices(const ScriptHostContext& host_context) {
    if (! Valid() || m_destroyed || ! m_state->started || m_state->noticed) return;
    auto&     core = *m_state;
    auto&     e    = *core.engine;
    CallScope scope(e, core.runtime, e.limits.call_budget_ms);
    core.noticed = true;
    e.RefreshHost(host_context);
    if (core.runtime != nullptr) e.PushProps(core.runtime->projectProperties());
    e.Call(&core.guard, "applyUserProperties", kLibUserNotices,
           { core.Prog(), JS_NewBool(e.ctx, core.runtime != nullptr) }, e.limits.call_budget_ms);
}

DynamicValueUniquePtr PropertyScriptProgram::Evaluate(const ScriptHostContext& host_context,
                                                      const DynamicValue&      current_value) {
    m_update_returned_value = false;
    if (! Valid() || m_destroyed) return nullptr;
    // A program nobody has started yet starts here, in the order a scene starts all of them in:
    // `init` first, then the notices. Whoever owns the property it drives starts it with
    // `RunInit` itself when it wants what `init` returns (the scene's scripted values do); this
    // path only keeps a program that was handed straight to `Evaluate` working.
    if (! m_state->started) {
        (void)RunInit(host_context, current_value);
        RunUserNotices(host_context);
        if (! Valid() || m_destroyed) return nullptr;
    }
    const DynamicValue& basis = current_value;
    auto&               core   = *m_state;
    auto&               e      = *core.engine;
    const double        budget = e.limits.call_budget_ms;
    // One budget for everything the host does for this evaluation, so accessors the
    // script defined on its parameters or getters on what it returns are held to it too.
    CallScope scope(e, core.runtime, budget);
    e.RefreshHost(host_context);
    WriteParams(core);
    const bool degrees  = core.semantic == PropertyScriptValueSemantic::AnglesDegrees;
    JSValue    argument = e.ToJs(basis, degrees);
    if (e.Overran(&core.guard, "update", budget)) {
        JS_FreeValue(e.ctx, argument);
        return m_capabilities.update ? CopyOf(basis) : nullptr;
    }
    JSValue    result    = JS_UNDEFINED;
    const bool completed = e.Call(&core.guard, "update", kLibEvaluate,
                                  { core.Prog(), argument, JS_NewBool(e.ctx, core.runtime != nullptr) },
                                  budget, &result);
    DynamicValueUniquePtr answer;
    if (completed && m_capabilities.update) answer = e.FromJs(result, basis, degrees);
    JS_FreeValue(e.ctx, result);
    if (e.Overran(&core.guard, "update", budget)) answer.reset();
    if (! m_capabilities.update) return nullptr;
    if (answer != nullptr) {
        m_update_returned_value = true;
        return answer;
    }
    // No value from the script: the property keeps what it holds now, which includes
    // whatever the script wrote to its own layer while it ran.
    return CopyOf(basis);
}

void PropertyScriptProgram::DispatchCursorClick(const ScriptHostContext& host) {
    if (m_state) DispatchCursor(*m_state, m_capabilities, ScriptCursorEvent::Click, host, true);
}
void PropertyScriptProgram::DispatchCursorDown(const ScriptHostContext& host) {
    if (m_state) DispatchCursor(*m_state, m_capabilities, ScriptCursorEvent::Down, host, true);
}
void PropertyScriptProgram::DispatchCursorEnter(const ScriptHostContext& host) {
    if (m_state) DispatchCursor(*m_state, m_capabilities, ScriptCursorEvent::Enter, host, true);
}
void PropertyScriptProgram::DispatchCursorLeave(const ScriptHostContext& host) {
    if (m_state) DispatchCursor(*m_state, m_capabilities, ScriptCursorEvent::Leave, host, true);
}
void PropertyScriptProgram::DispatchCursorMove(const ScriptHostContext& host) {
    if (m_state) DispatchCursor(*m_state, m_capabilities, ScriptCursorEvent::Move, host, true);
}
void PropertyScriptProgram::DispatchCursorUp(const ScriptHostContext& host) {
    if (m_state) DispatchCursor(*m_state, m_capabilities, ScriptCursorEvent::Up, host, true);
}

void PropertyScriptProgram::DispatchAnimationEvent(const ScriptHostContext& host_context,
                                                   std::string_view event_name, double frame) {
    if (m_state) DispatchAnimationMarker(*m_state, m_capabilities, host_context, event_name, frame);
}

void PropertyScriptProgram::DispatchMediaThumbnailChanged(const linalg::Vector3f& primary_color,
                                                          const linalg::Vector3f& text_color) {
    if (m_state) DispatchThumbnail(*m_state, primary_color, text_color);
}

void PropertyScriptProgram::DispatchMediaEventJson(std::string_view event_json) {
    if (m_state) DispatchMedia(*m_state, event_json);
}

void PropertyScriptProgram::DispatchResizeScreen(const ScriptHostContext& host_context) {
    if (m_state) DispatchResize(*m_state, host_context, true);
}

void PropertyScriptProgram::DispatchGeneralSettings(const ScriptHostContext& host_context) {
    if (m_state) DispatchLanguage(*m_state, host_context, true);
}

void PropertyScriptProgram::Destroy() {
    if (! m_state) return;
    EndProgram(*m_state, true);
    m_destroyed = m_state->destroyed;
}

// ----- scene programs -------------------------------------------------------

struct SceneScriptProgram::State : ProgramCore {};

SceneScriptProgram::SceneScriptProgram(SceneRuntimeContext& runtime, std::string script_source,
                                       std::string current_layer_name,
                                       ProjectProperties project_properties,
                                       ScriptHostContext host_context, JSRuntime*,
                                       JSContext* shared_context, std::string)
    : m_layer_name(std::move(current_layer_name)) {
    auto engine = ContextOf(shared_context);
    if (engine == nullptr) return;
    m_state           = std::make_unique<State>();
    m_state->engine   = std::move(engine);
    m_state->runtime  = &runtime;
    m_state->snapshot = std::move(project_properties);
    m_state->guard.name = m_layer_name.empty() ? "scene" : m_layer_name;
    int capabilities = 0;
    if (! CreateProgram(*m_state, true, script_source, m_layer_name, host_context, -1, capabilities)) {
        return;
    }
    m_capabilities = CapabilitiesOf(capabilities);
    // The script's top level has run; now `init`, the notices and the `load` listeners.
    auto&     e = *m_state->engine;
    CallScope scope(e, &runtime, e.limits.creation_budget_ms);
    m_state->started = true;
    e.Call(&m_state->guard, "init", kLibStartScene, { m_state->Prog() }, e.limits.creation_budget_ms);
}

SceneScriptProgram::~SceneScriptProgram() = default;

bool SceneScriptProgram::Valid() const { return m_state != nullptr && m_state->valid && ! m_state->guard.disabled; }

const std::string& SceneScriptProgram::LayerName() const { return m_layer_name; }

void SceneScriptProgram::ApplyUserProperties(const ProjectProperties& property_changes) {
    if (! Valid() || m_destroyed) return;
    auto&     core = *m_state;
    auto&     e    = *core.engine;
    CallScope scope(e, core.runtime, e.limits.call_budget_ms);
    e.PushProps(core.snapshot);
    DeliverChanges(core, property_changes);
}

void SceneScriptProgram::ApplyProjectProperties(const ProjectProperties& project_properties,
                                                const ProjectProperties& changed_properties) {
    if (m_state == nullptr) return;
    m_state->snapshot = project_properties;
    ApplyUserProperties(changed_properties);
}

void SceneScriptProgram::Tick(const ScriptHostContext& host_context) {
    if (! Valid() || m_destroyed) return;
    auto&     core = *m_state;
    auto&     e    = *core.engine;
    CallScope scope(e, core.runtime, e.limits.call_budget_ms);
    e.RefreshHost(host_context);
    e.Call(&core.guard, "update", kLibTickScene, { core.Prog() }, e.limits.call_budget_ms);
}

void SceneScriptProgram::DispatchCursorClick(const ScriptHostContext& host) {
    if (m_state) DispatchCursor(*m_state, m_capabilities, ScriptCursorEvent::Click, host, false);
}
void SceneScriptProgram::DispatchCursorDown(const ScriptHostContext& host) {
    if (m_state) DispatchCursor(*m_state, m_capabilities, ScriptCursorEvent::Down, host, false);
}
void SceneScriptProgram::DispatchCursorEnter(const ScriptHostContext& host) {
    if (m_state) DispatchCursor(*m_state, m_capabilities, ScriptCursorEvent::Enter, host, false);
}
void SceneScriptProgram::DispatchCursorLeave(const ScriptHostContext& host) {
    if (m_state) DispatchCursor(*m_state, m_capabilities, ScriptCursorEvent::Leave, host, false);
}
void SceneScriptProgram::DispatchCursorMove(const ScriptHostContext& host) {
    if (m_state) DispatchCursor(*m_state, m_capabilities, ScriptCursorEvent::Move, host, false);
}
void SceneScriptProgram::DispatchCursorUp(const ScriptHostContext& host) {
    if (m_state) DispatchCursor(*m_state, m_capabilities, ScriptCursorEvent::Up, host, false);
}

void SceneScriptProgram::DispatchAnimationEvent(const ScriptHostContext& host_context,
                                                std::string_view event_name, double frame) {
    if (m_state) DispatchAnimationMarker(*m_state, m_capabilities, host_context, event_name, frame);
}

void SceneScriptProgram::DispatchMediaThumbnailChanged(const linalg::Vector3f& primary_color,
                                                       const linalg::Vector3f& text_color) {
    if (m_state) DispatchThumbnail(*m_state, primary_color, text_color);
}

void SceneScriptProgram::DispatchMediaEventJson(std::string_view event_json) {
    if (m_state) DispatchMedia(*m_state, event_json);
}

void SceneScriptProgram::DispatchResizeScreen(const ScriptHostContext& host_context) {
    if (m_state) DispatchResize(*m_state, host_context, false);
}

void SceneScriptProgram::DispatchGeneralSettings(const ScriptHostContext& host_context) {
    if (m_state) DispatchLanguage(*m_state, host_context, false);
}

void SceneScriptProgram::Destroy() {
    if (! m_state) return;
    EndProgram(*m_state, false);
    m_destroyed = m_state->destroyed;
}

// ----- the engine ------------------------------------------------------------

ScriptEngine::ScriptEngine() : m_context(std::make_shared<ScriptEngineContext>(DefaultLimits())) {}

ScriptEngine::~ScriptEngine() {
    // Programs that outlive the engine keep the context alive; the scene runtime
    // they reached is gone with the engine.
    if (m_context != nullptr) m_context->runtime = nullptr;
}

void ScriptEngine::SetLimits(const ScriptLimits& limits) {
    if (m_context != nullptr) m_context->ApplyLimits(limits);
}

ScriptLimits ScriptEngine::Limits() const {
    return m_context != nullptr ? m_context->limits : ScriptLimits {};
}

void ScriptEngine::ResetStartupMetrics() { g_startup_metrics = ScriptStartupMetrics {}; }

ScriptStartupMetrics ScriptEngine::GetStartupMetrics() { return g_startup_metrics; }

DynamicValueUniquePtr ScriptEngine::Evaluate(const std::string&                          script_source,
                                             const std::map<std::string, DynamicValue*>& script_properties,
                                             const DynamicValue&                         current_value,
                                             const ScriptHostContext&                    host_context) {
    auto program = CreatePropertyScriptProgram(nullptr, script_source, "", script_properties,
                                               current_value, host_context);
    if (program == nullptr) return CopyOf(current_value);
    auto result = program->Evaluate(host_context, current_value);
    return result != nullptr ? std::move(result) : CopyOf(current_value);
}

std::unique_ptr<PropertyScriptProgram> ScriptEngine::CreatePropertyScriptProgram(
    SceneRuntimeContext* runtime, std::string script_source, std::string current_layer_name,
    std::map<std::string, DynamicValue*> script_properties, DynamicValue initial_value,
    ScriptHostContext host_context, PropertyScriptValueSemantic semantic, int animation_layer_index,
    std::string effect_reference, std::string setting_animation_reference) {
    if (m_context == nullptr || ! m_context->EnsureReady()) return nullptr;
    const auto id = std::to_string(m_context->next_program_id++);
    auto program  = std::make_unique<PropertyScriptProgram>(
        runtime, std::move(script_source), std::move(current_layer_name), std::move(script_properties),
        std::move(initial_value), std::move(host_context), m_context->rt, m_context->ctx,
        "exports" + id, "scriptProperties" + id, semantic, animation_layer_index,
        std::move(effect_reference), std::move(setting_animation_reference));
    if (! program->Valid()) return nullptr;
    return program;
}

std::unique_ptr<SceneScriptProgram> ScriptEngine::CreateSceneScriptProgram(
    SceneRuntimeContext& runtime, std::string script_source, std::string current_layer_name,
    ProjectProperties project_properties, ScriptHostContext host_context) {
    if (m_context == nullptr || ! m_context->EnsureReady()) return nullptr;
    const auto id = std::to_string(m_context->next_program_id++);
    auto program  = std::make_unique<SceneScriptProgram>(
        runtime, std::move(script_source), std::move(current_layer_name), std::move(project_properties),
        std::move(host_context), m_context->rt, m_context->ctx, "exports" + id);
    if (! program->Valid()) return nullptr;
    return program;
}

void ScriptEngine::RunAnimationEventCallbacks(const ScriptHostContext& host_context,
                                              std::string_view event_name, double frame) {
    if (m_context == nullptr || ! m_context->ready) return;
    auto&     e = *m_context;
    CallScope scope(e, nullptr, e.limits.call_budget_ms);
    e.RefreshHost(host_context);
    e.Call(nullptr, "animationEvent", kLibAnimationListeners,
           { JS_NewStringLen(e.ctx, event_name.data(), event_name.size()), JS_NewFloat64(e.ctx, frame) },
           e.limits.call_budget_ms);
}

void ScriptEngine::RunResizeScreenCallbacks(const ScriptHostContext& host_context) {
    if (m_context == nullptr || ! m_context->ready) return;
    auto&     e = *m_context;
    CallScope scope(e, nullptr, e.limits.call_budget_ms);
    e.RefreshHost(host_context);
    e.Call(nullptr, "resizeScreen", kLibResizeListeners, {}, e.limits.call_budget_ms);
}

void ScriptEngine::NotifyAnimationLayerEnded(const ScriptHostContext& host_context,
                                             std::string_view layer_name, int animation_layer_index) {
    if (m_context == nullptr || ! m_context->ready) return;
    auto&     e = *m_context;
    CallScope scope(e, nullptr, e.limits.call_budget_ms);
    e.RefreshHost(host_context);
    e.Call(nullptr, "layer-ended notice", kLibNotifyEnded,
           { JS_NewStringLen(e.ctx, layer_name.data(), layer_name.size()),
             JS_NewInt32(e.ctx, animation_layer_index) },
           e.limits.call_budget_ms);
}

} // namespace wallpaper
