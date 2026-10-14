#include "Scripting/ScriptEngine.hpp"
#include "Scripting/ScriptModuleSyntax.hpp"

#include "Runtime/SceneRuntimeContext.hpp"
#include "Utils/Sha.hpp"
#include "Utils/Logging.h"
#include "Utils/TimeOfDay.hpp"

#include <algorithm>
#include <array>
#include <cctype>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <new>
#include <optional>
#include <sstream>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <vector>

extern "C" {
#include "quickjs.h"
}

namespace wallpaper
{
namespace
{
constexpr float kPi = 3.14159265358979323846f;

Eigen::Vector3f DegreesToRadians(const Eigen::Vector3f& value) { return value * (kPi / 180.0f); }

Eigen::Vector3f RadiansToDegrees(const Eigen::Vector3f& value) { return value * (180.0f / kPi); }

struct SceneScriptBridgeState {
    SceneRuntimeContext* runtime = nullptr;
};

SceneScriptBridgeState* GetBridgeState(JSContext* context);

enum class ScriptProgramMode
{
    Property,
    Scene,
};

struct ScriptFrontEndResult {
    std::string              transformed_body;
    std::vector<std::string> imported_globals;
};

struct RegisteredAudioBuffer {
    uint32_t resolution {64};
    std::array<JSValue, 3> arrays {JS_UNDEFINED, JS_UNDEFINED, JS_UNDEFINED};
    bool active {true};
};

struct ContextScriptCacheState {
    bool                                     shared_bindings_installed { false };
    bool                                     shared_bootstrap_installed { false };
    ScriptHostContext                        last_host_context {};
    bool                                     has_last_host_context { false };
    uint64_t                                 last_audio_generation { 0 };
    bool                                     has_last_audio_generation { false };
    std::unordered_map<std::string, JSValue> factories;
    std::vector<RegisteredAudioBuffer> audio_buffers;
};

constexpr uint32_t kScriptPipelineRevision = 1;

// Metrics are per parse thread: a wallpaper switch tears down the outgoing
// scene's JS context while the incoming scene compiles its scripts.
thread_local ScriptStartupMetrics                       g_script_startup_metrics;
std::mutex                                              g_context_script_caches_mutex;
std::unordered_map<JSContext*, ContextScriptCacheState> g_context_script_caches;

double MeasureElapsedMs(const std::chrono::steady_clock::time_point started) {
    return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started)
        .count();
}

std::string MakeScriptCacheKey(std::string_view source, ScriptProgramMode mode) {
    std::string key_material;
    key_material.reserve(source.size() + 32);
    key_material += "rev:";
    key_material += std::to_string(kScriptPipelineRevision);
    key_material += "\nmode:";
    key_material += mode == ScriptProgramMode::Property ? "property" : "scene";
    key_material += "\n";
    key_material.append(source.data(), source.size());
    return utils::genSha1(key_material);
}

// The map is shared by every scene's script thread; only the owning thread
// touches the state it points at, so the lock only needs to cover lookup,
// insertion and erasure of the node itself.
ContextScriptCacheState& GetContextScriptCache(JSContext* context) {
    const std::lock_guard<std::mutex> guard(g_context_script_caches_mutex);
    return g_context_script_caches[context];
}

void ReleaseContextScriptCache(JSContext* context) {
    ContextScriptCacheState state;
    {
        const std::lock_guard<std::mutex> guard(g_context_script_caches_mutex);
        const auto                        iterator = g_context_script_caches.find(context);
        if (iterator == g_context_script_caches.end()) return;
        state = std::move(iterator->second);
        g_context_script_caches.erase(iterator);
    }

    for (auto& [key, value] : state.factories) {
        (void)key;
        JS_FreeValue(context, value);
    }
    for (const auto& buffer : state.audio_buffers) {
        for (const auto array : buffer.arrays) JS_FreeValue(context, array);
    }
}

constexpr char kVectorBootstrap[] = R"JS(
(function() {
  function __vecNumber(value) {
    if (typeof value === 'number') return value;
    if (value === undefined || value === null) return 0;
    var numeric = Number(value);
    return Number.isFinite(numeric) ? numeric : 0;
  }

  function __defineVector(name, fields) {
    function Vector(a, b, c, d) {
      if (!(this instanceof Vector)) {
        return new Vector(a, b, c, d);
      }

      if (a !== null && typeof a === 'object') {
        for (var i = 0; i < fields.length; ++i) {
          this[fields[i]] = __vecNumber(a[fields[i]]);
        }
        return;
      }

      var input = [a, b, c, d];
      if (fields.length > 1 && typeof a === 'number' && b === undefined && c === undefined && d === undefined) {
        for (var i = 1; i < fields.length; ++i) input[i] = a;
      }
      for (var i = 0; i < fields.length; ++i) {
        this[fields[i]] = __vecNumber(input[i]);
      }
    }

    function createFromBinary(self, rhs, op) {
      var source = (rhs !== null && typeof rhs === 'object') ? rhs : null;
      var scalar = source === null ? __vecNumber(rhs) : 0;
      var values = [];
      for (var i = 0; i < fields.length; ++i) {
        var field = fields[i];
        var other = source === null ? scalar : __vecNumber(source[field]);
        values.push(op(__vecNumber(self[field]), other));
      }
      return new Vector(values[0], values[1], values[2], values[3]);
    }

    Vector.prototype.clone = function() {
      return createFromBinary(this, 0, function(lhs) { return lhs; });
    };
    Vector.prototype.copy = function() {
      return this.clone();
    };
    Vector.prototype.add = function(rhs) {
      return createFromBinary(this, rhs, function(lhs, other) { return lhs + other; });
    };
    Vector.prototype.subtract = function(rhs) {
      return createFromBinary(this, rhs, function(lhs, other) { return lhs - other; });
    };
    Vector.prototype.mix = function(rhs, amount) {
      return createFromBinary(this, rhs, function(lhs, other) { return lhs * (1 - amount) + other * amount; });
    };
    Vector.prototype.multiply = function(rhs) {
      return createFromBinary(this, rhs, function(lhs, other) { return lhs * other; });
    };
    Vector.prototype.divide = function(rhs) {
      return createFromBinary(this, rhs, function(lhs, other) { return lhs / other; });
    };
    Vector.prototype.length = function() {
      var sum = 0;
      for (var i = 0; i < fields.length; ++i) {
        var field = fields[i];
        var value = __vecNumber(this[field]);
        sum += value * value;
      }
      return Math.sqrt(sum);
    };
    Vector.prototype.normalize = function() {
      var len = this.length();
      return len === 0 ? this.clone() : this.divide(len);
    };
    Vector.prototype.toString = function() {
      var values = [];
      for (var i = 0; i < fields.length; ++i) {
        values.push(String(this[fields[i]]));
      }
      return values.join(', ');
    };

    Object.defineProperty(Vector, 'name', { value: name });
    return Vector;
  }

  Object.defineProperty(globalThis, '__WEVec2', {
    value: __defineVector('Vec2', ['x', 'y']),
    configurable: false,
    writable: false
  });
  Object.defineProperty(globalThis, '__WEVec3', {
    value: __defineVector('Vec3', ['x', 'y', 'z']),
    configurable: false,
    writable: false
  });
  Object.defineProperty(globalThis, '__WEVec4', {
    value: __defineVector('Vec4', ['x', 'y', 'z', 'w']),
    configurable: false,
    writable: false
  });

  if (typeof globalThis.Vec2 !== 'function') globalThis.Vec2 = globalThis.__WEVec2;
  if (typeof globalThis.Vec3 !== 'function') globalThis.Vec3 = globalThis.__WEVec3;
  if (typeof globalThis.Vec4 !== 'function') globalThis.Vec4 = globalThis.__WEVec4;
})();
)JS";

bool        InstallScriptPrimitives(JSContext* context);
JSValue     CreateJsVectorObject(JSContext* context, const char* constructor_name, int argc,
                                 const double* values);
JSValue     CreateJsVec2(JSContext* context, double x, double y);
JSValue     CreateJsVec3(JSContext* context, double x, double y, double z);
JSValue     CreateJsVec4(JSContext* context, double x, double y, double z, double w);
std::string QuoteJsString(const std::string& value);
void        UpdateScriptPropertiesObject(JSContext* context, JSValue target,
                                         const std::map<std::string, DynamicValue*>& script_properties);
JSValue     CallStoredExport(JSContext* context, const char* exports_object_name,
                             const char* export_name, int argc, JSValueConst* argv);
void        LogJsException(JSContext* context, const char* scope);

bool InstallScriptPrimitives(JSContext* context) {
    JSValue result = JS_Eval(context,
                             kVectorBootstrap,
                             sizeof(kVectorBootstrap) - 1,
                             "<script-primitives>",
                             JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(result)) {
        LogJsException(context, "InstallScriptPrimitives");
        JS_FreeValue(context, result);
        return false;
    }

    JS_FreeValue(context, result);
    return true;
}

JSValue CreateJsVectorObject(JSContext* context, const char* constructor_name, int argc,
                             const double* values) {
    JSValue global_object = JS_GetGlobalObject(context);
    JSValue constructor   = JS_GetPropertyStr(context, global_object, constructor_name);
    JS_FreeValue(context, global_object);

    auto make_plain_object = [&]() {
        JSValue object = JS_NewObject(context);
        if (argc > 0) JS_SetPropertyStr(context, object, "x", JS_NewFloat64(context, values[0]));
        if (argc > 1) JS_SetPropertyStr(context, object, "y", JS_NewFloat64(context, values[1]));
        if (argc > 2) JS_SetPropertyStr(context, object, "z", JS_NewFloat64(context, values[2]));
        if (argc > 3) JS_SetPropertyStr(context, object, "w", JS_NewFloat64(context, values[3]));
        return object;
    };

    if (! JS_IsFunction(context, constructor)) {
        JS_FreeValue(context, constructor);
        return make_plain_object();
    }

    std::array<JSValue, 4> argv {};
    for (int index = 0; index < argc; ++index) {
        argv[index] = JS_NewFloat64(context, values[index]);
    }

    JSValue instance = JS_CallConstructor(context, constructor, argc, argv.data());
    for (int index = 0; index < argc; ++index) {
        JS_FreeValue(context, argv[index]);
    }
    JS_FreeValue(context, constructor);

    if (JS_IsException(instance)) {
        LogJsException(context, "CreateJsVectorObject");
        JS_FreeValue(context, instance);
        return make_plain_object();
    }

    return instance;
}

JSValue CreateJsVec2(JSContext* context, double x, double y) {
    const double values[] = { x, y };
    return CreateJsVectorObject(context, "__WEVec2", 2, values);
}

JSValue CreateJsVec3(JSContext* context, double x, double y, double z) {
    const double values[] = { x, y, z };
    return CreateJsVectorObject(context, "__WEVec3", 3, values);
}

JSValue CreateJsVec4(JSContext* context, double x, double y, double z, double w) {
    const double values[] = { x, y, z, w };
    return CreateJsVectorObject(context, "__WEVec4", 4, values);
}

JSValue DynamicValueToJS(JSContext* context, const DynamicValue& value) {
    switch (value.getType()) {
    case DynamicValue::Float: return JS_NewFloat64(context, value.getFloat());
    case DynamicValue::Int: return JS_NewInt32(context, value.getInt());
    case DynamicValue::Boolean: return JS_NewBool(context, value.getBool());
    case DynamicValue::String: return JS_NewString(context, value.getString().c_str());
    case DynamicValue::Vec2: return CreateJsVec2(context, value.getVec2().x(), value.getVec2().y());
    case DynamicValue::Vec3:
        return CreateJsVec3(context, value.getVec3().x(), value.getVec3().y(), value.getVec3().z());
    case DynamicValue::Vec4:
        return CreateJsVec4(context,
                            value.getVec4().x(),
                            value.getVec4().y(),
                            value.getVec4().z(),
                            value.getVec4().w());
    case DynamicValue::IVec2:
        return CreateJsVec2(context, value.getIVec2().x(), value.getIVec2().y());
    case DynamicValue::IVec3:
        return CreateJsVec3(
            context, value.getIVec3().x(), value.getIVec3().y(), value.getIVec3().z());
    case DynamicValue::IVec4:
        return CreateJsVec4(context,
                            value.getIVec4().x(),
                            value.getIVec4().y(),
                            value.getIVec4().z(),
                            value.getIVec4().w());
    case DynamicValue::Null: return JS_NULL;
    }

    return JS_UNDEFINED;
}

JSValue RuntimeScalarValueToJS(JSContext* context, const RuntimeScalarValue& value) {
    switch (value.kind) {
    case RuntimeScalarValue::Kind::Bool: return JS_NewBool(context, value.asBool());
    case RuntimeScalarValue::Kind::Float: return JS_NewFloat64(context, value.asFloat());
    case RuntimeScalarValue::Kind::String: return JS_NewString(context, value.asString().c_str());
    }

    return JS_UNDEFINED;
}

bool FillDynamicValueFromJS(JSContext* context, JSValue value, DynamicValue::UnderlyingType hint,
                            DynamicValue& result) {
    result.update();

    if (JS_IsException(value)) return true;

    const int tag = JS_VALUE_GET_TAG(value);
    if (tag == JS_TAG_INT) {
        int32_t int_value = 0;
        JS_ToInt32(context, &int_value, value);
        if (hint == DynamicValue::Float) {
            result.update(static_cast<float>(int_value));
        } else {
            result.update(static_cast<int>(int_value));
        }
        return true;
    }
    if (tag == JS_TAG_BOOL) {
        result.update(static_cast<bool>(JS_ToBool(context, value)));
        return true;
    }
    if (JS_TAG_IS_FLOAT64(tag)) {
        double float_value = 0.0;
        JS_ToFloat64(context, &float_value, value);
        result.update(static_cast<float>(float_value));
        return true;
    }
    if (tag == JS_TAG_STRING) {
        const char* string_value = JS_ToCString(context, value);
        if (string_value != nullptr) {
            result.update(std::string(string_value));
            JS_FreeCString(context, string_value);
        }
        return true;
    }
    if (tag == JS_TAG_OBJECT) {
        const auto read_float = [&](const char* property_name) {
            JSValue property = JS_GetPropertyStr(context, value, property_name);
            double  scalar   = 0.0;
            if (! JS_IsException(property) && ! JS_IsUndefined(property)) {
                JS_ToFloat64(context, &scalar, property);
            }
            JS_FreeValue(context, property);
            return static_cast<float>(scalar);
        };

        const auto read_int = [&](const char* property_name) {
            JSValue property = JS_GetPropertyStr(context, value, property_name);
            int32_t scalar   = 0;
            if (! JS_IsException(property) && ! JS_IsUndefined(property)) {
                JS_ToInt32(context, &scalar, property);
            }
            JS_FreeValue(context, property);
            return static_cast<int>(scalar);
        };

        switch (hint) {
        case DynamicValue::Vec2:
            result.update(Eigen::Vector2f(read_float("x"), read_float("y")));
            break;
        case DynamicValue::Vec3:
            result.update(Eigen::Vector3f(read_float("x"), read_float("y"), read_float("z")));
            break;
        case DynamicValue::Vec4:
            result.update(Eigen::Vector4f(
                read_float("x"), read_float("y"), read_float("z"), read_float("w")));
            break;
        case DynamicValue::IVec2:
            result.update(Eigen::Vector2i(read_int("x"), read_int("y")));
            break;
        case DynamicValue::IVec3:
            result.update(Eigen::Vector3i(read_int("x"), read_int("y"), read_int("z")));
            break;
        case DynamicValue::IVec4:
            result.update(
                Eigen::Vector4i(read_int("x"), read_int("y"), read_int("z"), read_int("w")));
            break;
        default:
            result.update(Eigen::Vector3f(read_float("x"), read_float("y"), read_float("z")));
            break;
        }
        return true;
    }

    double float_value = 0.0;
    if (JS_ToFloat64(context, &float_value, value) == 0) {
        result.update(static_cast<float>(float_value));
    }
    return true;
}

DynamicValueUniquePtr JsToDynamicValue(JSContext* context, JSValue value,
                                       DynamicValue::UnderlyingType hint) {
    auto result = std::make_unique<DynamicValue>();
    FillDynamicValueFromJS(context, value, hint, *result);
    return result;
}

void LogJsException(JSContext* context, const char* scope) {
    JSValue exception = JS_GetException(context);
    if (! JS_IsNull(exception) && ! JS_IsUndefined(exception)) {
        const char* message     = JS_ToCString(context, exception);
        JSValue     stack_value = JS_GetPropertyStr(context, exception, "stack");
        const char* stack = JS_IsString(stack_value) ? JS_ToCString(context, stack_value) : nullptr;
        if (message != nullptr) {
            LOG_ERROR("ScriptEngine[%s]: %s", scope, message);
            if (stack != nullptr && std::strcmp(stack, message) != 0) {
                LOG_ERROR("ScriptEngine[%s] stack: %s", scope, stack);
            }
            auto* bridge_state = static_cast<SceneScriptBridgeState*>(JS_GetContextOpaque(context));
            if (bridge_state != nullptr && bridge_state->runtime != nullptr) {
                bridge_state->runtime->RecordScriptError(std::string(scope) + ": " +
                                                         std::string(message));
            }
            JS_FreeCString(context, message);
        }
        if (stack != nullptr) JS_FreeCString(context, stack);
        JS_FreeValue(context, stack_value);
    }
    JS_FreeValue(context, exception);
}

std::string TrimCopy(std::string_view value) {
    std::size_t begin = 0;
    while (begin < value.size() && std::isspace(static_cast<unsigned char>(value[begin])) != 0) {
        begin++;
    }

    std::size_t end = value.size();
    while (end > begin && std::isspace(static_cast<unsigned char>(value[end - 1])) != 0) {
        end--;
    }

    return std::string(value.substr(begin, end - begin));
}

bool StartsWith(std::string_view value, std::string_view prefix) {
    return value.size() >= prefix.size() &&
           std::memcmp(value.data(), prefix.data(), prefix.size()) == 0;
}

bool TryParseImportNamespace(std::string_view line, std::string* alias_name,
                             std::string* global_name) {
    if (! StartsWith(line, "import")) return false;

    std::size_t cursor = std::strlen("import");
    while (cursor < line.size() && std::isspace(static_cast<unsigned char>(line[cursor])) != 0) {
        cursor++;
    }
    if (cursor >= line.size() || line[cursor] != '*') return false;
    cursor++;
    while (cursor < line.size() && std::isspace(static_cast<unsigned char>(line[cursor])) != 0) {
        cursor++;
    }
    if (! StartsWith(line.substr(cursor), "as")) return false;
    cursor += 2;
    while (cursor < line.size() && std::isspace(static_cast<unsigned char>(line[cursor])) != 0) {
        cursor++;
    }

    std::size_t from_pos            = line.find(" from ", cursor);
    std::size_t from_keyword_offset = std::strlen(" from ");
    if (from_pos == std::string_view::npos) {
        from_pos            = line.find("from", cursor);
        from_keyword_offset = std::strlen("from");
    }
    if (from_pos == std::string_view::npos) return false;

    *alias_name           = TrimCopy(line.substr(cursor, from_pos - cursor));
    std::string specifier = TrimCopy(line.substr(from_pos + from_keyword_offset));
    if (! specifier.empty() && specifier.back() == ';') specifier.pop_back();
    specifier = TrimCopy(specifier);
    if (specifier.size() < 2) return false;
    if ((specifier.front() != '\'' && specifier.front() != '"') ||
        specifier.back() != specifier.front()) {
        return false;
    }

    *global_name = specifier.substr(1, specifier.size() - 2);
    return ! alias_name->empty() && ! global_name->empty();
}

bool TryParseImportNamed(std::string_view line, std::string* members, std::string* global_name) {
    if (! StartsWith(line, "import {")) return false;
    const std::size_t close_brace         = line.find('}');
    std::size_t       from_pos            = line.find(" from ", close_brace);
    std::size_t       from_keyword_offset = std::strlen(" from ");
    if (from_pos == std::string_view::npos) {
        from_pos            = line.find("from", close_brace);
        from_keyword_offset = std::strlen("from");
    }
    if (close_brace == std::string_view::npos || from_pos == std::string_view::npos) return false;

    *members =
        TrimCopy(line.substr(std::strlen("import {"), close_brace - std::strlen("import {")));
    std::string specifier = TrimCopy(line.substr(from_pos + from_keyword_offset));
    if (! specifier.empty() && specifier.back() == ';') specifier.pop_back();
    specifier = TrimCopy(specifier);
    if (specifier.size() < 2) return false;
    if ((specifier.front() != '\'' && specifier.front() != '"') ||
        specifier.back() != specifier.front()) {
        return false;
    }

    *global_name = specifier.substr(1, specifier.size() - 2);
    return ! members->empty() && ! global_name->empty();
}

bool IsSideEffectImport(std::string_view line) {
    if (! StartsWith(line, "import ")) return false;
    return line.find(" from ") == std::string_view::npos;
}

bool IsIdentifierPart(char character) {
    return std::isalnum(static_cast<unsigned char>(character)) != 0 || character == '_' ||
           character == '$';
}

bool IsIdentifierStart(char character) {
    return std::isalpha(static_cast<unsigned char>(character)) != 0 || character == '_' ||
           character == '$';
}

std::size_t SkipJsWhitespaceAndComments(std::string_view source, std::size_t position) {
    while (position < source.size()) {
        const char character = source[position];
        if (std::isspace(static_cast<unsigned char>(character)) != 0) {
            ++position;
            continue;
        }

        if (character == '/' && position + 1 < source.size()) {
            if (source[position + 1] == '/') {
                position += 2;
                while (position < source.size() && source[position] != '\n') ++position;
                continue;
            }
            if (source[position + 1] == '*') {
                position += 2;
                while (position + 1 < source.size() &&
                       ! (source[position] == '*' && source[position + 1] == '/')) {
                    ++position;
                }
                if (position + 1 < source.size()) position += 2;
                continue;
            }
        }

        break;
    }

    return position;
}

std::size_t SkipJsStringLiteral(std::string_view source, std::size_t position) {
    if (position >= source.size()) return position;
    const char quote = source[position];
    if (quote != '\'' && quote != '"' && quote != '`') return position;

    ++position;
    while (position < source.size()) {
        const char character = source[position++];
        if (character == '\\') {
            if (position < source.size()) ++position;
            continue;
        }
        if (character == quote) break;
    }
    return position;
}

bool ConsumeJsKeyword(std::string_view source, std::size_t* position, std::string_view keyword) {
    std::size_t current = SkipJsWhitespaceAndComments(source, *position);
    if (current + keyword.size() > source.size()) return false;
    if (source.compare(current, keyword.size(), keyword) != 0) return false;
    const std::size_t end = current + keyword.size();
    if (end < source.size() && IsIdentifierPart(source[end])) return false;
    *position = end;
    return true;
}

bool ParseJsIdentifier(std::string_view source, std::size_t* position, std::string* identifier) {
    std::size_t current = SkipJsWhitespaceAndComments(source, *position);
    if (current >= source.size() || ! IsIdentifierStart(source[current])) return false;

    const std::size_t start = current++;
    while (current < source.size() && IsIdentifierPart(source[current])) ++current;
    *identifier = std::string(source.substr(start, current - start));
    *position   = current;
    return true;
}

bool ParseJsStringLiteral(std::string_view source, std::size_t* position, std::string* literal) {
    std::size_t current = SkipJsWhitespaceAndComments(source, *position);
    if (current >= source.size() || (source[current] != '\'' && source[current] != '"'))
        return false;

    const std::size_t start = current;
    current                 = SkipJsStringLiteral(source, current);
    if (current <= start + 1 || current > source.size()) return false;

    *literal  = std::string(source.substr(start, current - start));
    *position = current;
    return true;
}

int HexDigitValue(char character) {
    if (character >= '0' && character <= '9') return character - '0';
    if (character >= 'a' && character <= 'f') return character - 'a' + 10;
    if (character >= 'A' && character <= 'F') return character - 'A' + 10;
    return -1;
}

bool TryReadHex(std::string_view source, std::size_t position, std::size_t digits,
                uint32_t* value) {
    uint32_t result = 0;
    for (std::size_t index = 0; index < digits; ++index) {
        if (position + index >= source.size()) return false;
        const int digit = HexDigitValue(source[position + index]);
        if (digit < 0) return false;
        result = (result << 4U) | static_cast<uint32_t>(digit);
    }
    *value = result;
    return true;
}

std::string DecodeJsStringLiteralForProperty(std::string_view literal) {
    if (literal.size() < 2) return std::string(literal);

    std::string output;
    output.reserve(literal.size() - 2);

    for (std::size_t position = 1; position + 1 < literal.size();) {
        const char character = literal[position++];
        if (character != '\\' || position + 1 >= literal.size()) {
            output.push_back(character);
            continue;
        }

        const char escaped = literal[position++];
        switch (escaped) {
        case '0': output.push_back('\0'); break;
        case 'b': output.push_back('\b'); break;
        case 'f': output.push_back('\f'); break;
        case 'n': output.push_back('\n'); break;
        case 'r': output.push_back('\r'); break;
        case 't': output.push_back('\t'); break;
        case 'v': output.push_back('\v'); break;
        case '\\': output.push_back('\\'); break;
        case '\'': output.push_back('\''); break;
        case '"': output.push_back('"'); break;
        case 'x': {
            uint32_t value = 0;
            if (TryReadHex(literal, position, 2, &value)) {
                output.push_back(static_cast<char>(value));
                position += 2;
            } else {
                output += "\\x";
            }
            break;
        }
        case 'u': {
            uint32_t value = 0;
            if (TryReadHex(literal, position, 4, &value) && value <= 0x7fU) {
                output.push_back(static_cast<char>(value));
                position += 4;
            } else {
                output += "\\u";
            }
            break;
        }
        default: output.push_back(escaped); break;
        }
    }

    return output;
}

std::size_t ConsumeImportStatementTail(std::string_view source, std::size_t position) {
    position = SkipJsWhitespaceAndComments(source, position);
    if (position < source.size() && source[position] == ';') return position + 1;
    return position;
}

bool TryTransformImportDeclaration(std::string_view source, std::size_t import_position,
                                   std::size_t* end_position, std::string* replacement) {
    const bool boundary_before =
        import_position == 0 || ! IsIdentifierPart(source[import_position - 1]);
    if (! boundary_before || import_position + std::strlen("import") > source.size() ||
        source.compare(import_position, std::strlen("import"), "import") != 0) {
        return false;
    }

    std::size_t current = import_position + std::strlen("import");
    if (current < source.size() && IsIdentifierPart(source[current])) return false;
    current = SkipJsWhitespaceAndComments(source, current);
    if (current >= source.size()) return false;

    std::string literal;
    if (source[current] == '\'' || source[current] == '"') {
        if (! ParseJsStringLiteral(source, &current, &literal)) return false;
        *end_position = ConsumeImportStatementTail(source, current);
        replacement->clear();
        return true;
    }

    if (source[current] == '*') {
        ++current;
        if (! ConsumeJsKeyword(source, &current, "as")) return false;

        std::string alias;
        if (! ParseJsIdentifier(source, &current, &alias)) return false;
        if (! ConsumeJsKeyword(source, &current, "from")) return false;
        if (! ParseJsStringLiteral(source, &current, &literal)) return false;

        *end_position = ConsumeImportStatementTail(source, current);
        *replacement  = "const " + alias + " = globalThis[" +
                       QuoteJsString(DecodeJsStringLiteralForProperty(literal)) + "];";
        return true;
    }

    if (source[current] == '{') {
        const std::size_t members_start = ++current;
        int               brace_depth   = 1;
        while (current < source.size() && brace_depth > 0) {
            if (source[current] == '\'' || source[current] == '"' || source[current] == '`') {
                current = SkipJsStringLiteral(source, current);
                continue;
            }
            if (source[current] == '{')
                ++brace_depth;
            else if (source[current] == '}')
                --brace_depth;
            ++current;
        }
        if (brace_depth != 0) return false;

        const std::size_t members_end = current - 1;
        if (! ConsumeJsKeyword(source, &current, "from")) return false;
        if (! ParseJsStringLiteral(source, &current, &literal)) return false;

        *end_position = ConsumeImportStatementTail(source, current);
        *replacement =
            "const {" + std::string(source.substr(members_start, members_end - members_start)) +
            "} = globalThis[" + QuoteJsString(DecodeJsStringLiteralForProperty(literal)) + "];";
        return true;
    }

    return false;
}

std::string TransformInlineImportDeclarations(std::string_view source) {
    std::string output;
    output.reserve(source.size());

    for (std::size_t position = 0; position < source.size();) {
        const char character = source[position];
        if (character == '\'' || character == '"' || character == '`') {
            const std::size_t end = SkipJsStringLiteral(source, position);
            output.append(source.substr(position, end - position));
            position = end;
            continue;
        }

        if (character == '/' && position + 1 < source.size()) {
            if (source[position + 1] == '/') {
                const std::size_t start = position;
                position += 2;
                while (position < source.size() && source[position] != '\n') ++position;
                output.append(source.substr(start, position - start));
                continue;
            }
            if (source[position + 1] == '*') {
                const std::size_t start = position;
                position += 2;
                while (position + 1 < source.size() &&
                       ! (source[position] == '*' && source[position + 1] == '/')) {
                    ++position;
                }
                if (position + 1 < source.size()) position += 2;
                output.append(source.substr(start, position - start));
                continue;
            }
        }

        std::size_t end_position = position;
        std::string replacement;
        if (TryTransformImportDeclaration(source, position, &end_position, &replacement)) {
            output += replacement;
            position = end_position;
            continue;
        }

        output.push_back(character);
        ++position;
    }

    return output;
}

ScriptFrontEndResult RunScriptFrontEnd(std::string_view source) {
    const auto started = std::chrono::steady_clock::now();

    std::string normalized(source);
    if (normalized.rfind("\xEF\xBB\xBF", 0) == 0) {
        normalized.erase(0, 3);
    }
    normalized.erase(std::remove(normalized.begin(), normalized.end(), '\r'), normalized.end());

    ScriptFrontEndResult result;
    std::ostringstream   output;
    std::istringstream   input(normalized);
    std::string          line;

    while (std::getline(input, line)) {
        const std::string trimmed = TrimCopy(line);
        if (trimmed.empty()) {
            output << '\n';
            continue;
        }

        if (trimmed == "'use strict';" || trimmed == "\"use strict\";") {
            continue;
        }

        std::string alias_name;
        std::string global_name;
        if (TryParseImportNamespace(trimmed, &alias_name, &global_name)) {
            global_name = DecodeJsStringLiteralForProperty("'" + global_name + "'");
            result.imported_globals.push_back(global_name);
            output << "const " << alias_name << " = globalThis[" << QuoteJsString(global_name)
                   << "];\n";
            continue;
        }

        std::string members;
        if (TryParseImportNamed(trimmed, &members, &global_name)) {
            global_name = DecodeJsStringLiteralForProperty("'" + global_name + "'");
            result.imported_globals.push_back(global_name);
            output << "const {" << members << "} = globalThis[" << QuoteJsString(global_name)
                   << "];\n";
            continue;
        }

        if (IsSideEffectImport(trimmed)) {
            continue;
        }

        // Only the keyword goes; the separator after it is whitespace to the
        // language and stays.
        if (ExportKeywordAt(trimmed, 0)) {
            output << trimmed.substr(std::strlen("export")) << '\n';
            continue;
        }

        output << line << '\n';
    }

    result.transformed_body = output.str();
    result.transformed_body = TransformInlineImportDeclarations(result.transformed_body);
    auto&       body       = result.transformed_body;
    std::size_t export_pos = 0;
    while ((export_pos = body.find("export", export_pos)) != std::string::npos) {
        if (! ExportKeywordAt(body, export_pos)) {
            export_pos += std::strlen("export");
            continue;
        }

        // Only the keyword: a line break after it may end a comment that
        // happens to finish with the word, and erasing the break would pull
        // the next line into that comment.
        body.erase(export_pos, std::strlen("export"));
    }
    g_script_startup_metrics.module_strip_ms += MeasureElapsedMs(started);
    return result;
}

void AppendScriptPropertiesBuilder(std::ostringstream& wrapper) {
    wrapper << "  function createScriptProperties() {\n"
            << "    var builder = {\n"
            << "      addSlider: function(opts) { if (!(opts.name in __props)) __props[opts.name] "
               "= opts.value; return builder; },\n"
            << "      addCheckbox: function(opts) { if (!(opts.name in __props)) "
               "__props[opts.name] = opts.value; return builder; },\n"
            << "      addCombo: function(opts) {\n"
            << "        if (!(opts.name in __props)) {\n"
            << "          if ('value' in opts) __props[opts.name] = opts.value;\n"
            << "          else if (opts.options && opts.options.length > 0) __props[opts.name] = "
               "opts.options[0].value;\n"
            << "          else __props[opts.name] = undefined;\n"
            << "        }\n"
            << "        return builder;\n"
            << "      },\n"
            << "      addColor: function(opts) {\n"
            << "        function convert(value) {\n"
            << "          if (typeof value === 'string') value = value.trim().split(/\\s+/).map(Number);\n"
            << "          if (Array.isArray(value)) return new globalThis.__WEVec3(value[0], value[1], value[2]);\n"
            << "          return value;\n"
            << "        }\n"
            << "        var color = convert(opts.name in __props ? __props[opts.name] : opts.value);\n"
            << "        Object.defineProperty(__props, opts.name, { enumerable: true, configurable: true,\n"
            << "          get: function() { return color; },\n"
            << "          set: function(value) { color = convert(value); }\n"
            << "        });\n"
            << "        return builder;\n"
            << "      },\n"
            << "      addText: function(opts) { if (!(opts.name in __props)) __props[opts.name] = "
               "opts.value; return builder; },\n"
            << "      finish: function() { return __props; }\n"
            << "    };\n"
            << "    return builder;\n"
            << "  }\n";
}

// The script's own scene view. Its `createLayer` passes on the `__workshopId`
// the editor writes into a script imported from the Workshop, which is how the
// runtime finds that item's assets. Read when called, from the script's own
// scope; `typeof` throws before the declaration has run, hence the guard.
void AppendThisScene(std::ostringstream& wrapper) {
    wrapper << "  function __declaredWorkshopId() {\n"
            << "    try { return typeof __workshopId === 'undefined' ? '' : String(__workshopId); }\n"
            << "    catch (error) { return ''; }\n"
            << "  }\n"
            << "  const thisScene = Object.create(globalThis.scene);\n"
            << "  Object.defineProperty(thisScene, 'createLayer', { value: function(configuration) { return "
               "globalThis.scene.__createLayerFor(__scriptContext.layerName, configuration, "
               "__declaredWorkshopId()); } });\n";
}

void AppendCommonHostBootstrap(std::ostringstream& wrapper) {
    const auto started = std::chrono::steady_clock::now();
    wrapper
        << "  var __consoleNoop = function() {};\n"
        << "  globalThis.console = globalThis.console || {\n"
        << "    log: __consoleNoop,\n"
        << "    error: __consoleNoop,\n"
        << "    warn: __consoleNoop,\n"
        << "    info: __consoleNoop,\n"
        << "    debug: __consoleNoop,\n"
        << "    trace: __consoleNoop,\n"
        << "    dir: __consoleNoop,\n"
        << "    assert: __consoleNoop,\n"
        << "    group: __consoleNoop,\n"
        << "    groupCollapsed: __consoleNoop,\n"
        << "    groupEnd: __consoleNoop\n"
        << "  };\n"
        << "  ['log','error','warn','info','debug','trace','dir','assert','group',"
           "'groupCollapsed','groupEnd'].forEach(function(name) {\n"
        << "    if (typeof globalThis.console[name] !== 'function') "
           "globalThis.console[name] = __consoleNoop;\n"
        << "  });\n"
        << "  globalThis.WEMath = globalThis.WEMath || {\n"
        << "    mix: function(x, y, a) { return x * (1 - a) + y * a; },\n"
        << "    lerp: function(x, y, a) { return x * (1 - a) + y * a; },\n"
        << "    clamp: function(value, min, max) { return Math.min(Math.max(value, min), max); },\n"
        << "    saturate: function(value) { return Math.min(Math.max(value, 0), 1); },\n"
        << "    step: function(edge, value) { return value < edge ? 0 : 1; },\n"
        << "    sign: function(value) { return Math.sign(value); },\n"
        << "    fract: function(value) { return value - Math.floor(value); },\n"
        << "    deg2rad: function(value) { return value * (Math.PI / 180); },\n"
        << "    rad2deg: function(value) { return value * (180 / Math.PI); },\n"
        << "    smoothstep: function(edge0, edge1, value) {\n"
        << "      var t = Math.min(Math.max((value - edge0) / (edge1 - edge0), 0), 1);\n"
        << "      return t * t * (3 - 2 * t);\n"
        << "    },\n"
        << "    smoothStep: function(edge0, edge1, value) {\n"
        << "      return globalThis.WEMath.smoothstep(edge0, edge1, value);\n"
        << "    }\n"
        << "  };\n"
        << "  globalThis.WEColor = globalThis.WEColor || {\n"
        << "    hsv2rgb: function(hsv) {\n"
        << "      var h = Number((hsv && hsv.x) || 0);\n"
        << "      var s = Math.min(Math.max(Number((hsv && hsv.y) || 0), 0), 1);\n"
        << "      var v = Number((hsv && hsv.z) || 0);\n"
        << "      h = h - Math.floor(h);\n"
        << "      var i = Math.floor(h * 6.0);\n"
        << "      var f = h * 6.0 - i;\n"
        << "      var p = v * (1.0 - s);\n"
        << "      var q = v * (1.0 - f * s);\n"
        << "      var t = v * (1.0 - (1.0 - f) * s);\n"
        << "      switch (i % 6) {\n"
        << "      case 0: return new Vec3(v, t, p);\n"
        << "      case 1: return new Vec3(q, v, p);\n"
        << "      case 2: return new Vec3(p, v, t);\n"
        << "      case 3: return new Vec3(p, q, v);\n"
        << "      case 4: return new Vec3(t, p, v);\n"
        << "      default: return new Vec3(v, p, q);\n"
        << "      }\n"
        << "    }\n"
        << "  };\n"
        << "  globalThis.WEVector = globalThis.WEVector || {\n"
        << "    angleVector2: function(angle) {\n"
        << "      var radians = Number(angle || 0) * Math.PI / 180.0;\n"
        << "      return new Vec2(Math.cos(radians), Math.sin(radians));\n"
        << "    }\n"
        << "  };\n"
        << "  globalThis.shared = globalThis.shared || {};\n"
        << "  globalThis.shared.STARTS_WITH = 0;\n"
        << "  globalThis.shared.END_WITH = 1;\n"
        << "  globalThis.MediaPlaybackEvent = globalThis.MediaPlaybackEvent || {\n"
        << "    PLAYBACK_PLAYING: 0,\n"
        << "    PLAYBACK_PAUSED: 1,\n"
        << "    PLAYBACK_STOPPED: 2\n"
        << "  };\n"
        << "  globalThis.shared.userPropertyCategories = globalThis.shared.userPropertyCategories "
           "|| new Map();\n"
        << "  globalThis.__localStorageData = globalThis.__localStorageData || "
           "Object.create(null);\n"
        << "  globalThis.localStorage = globalThis.localStorage || {\n"
        << "    get: function(key) { return globalThis.__localStorageData[String(key)]; },\n"
        << "    set: function(key, value) { globalThis.__localStorageData[String(key)] = value; "
           "return value; },\n"
        << "    remove: function(key) { delete globalThis.__localStorageData[String(key)]; },\n"
        << "    clear: function() { globalThis.__localStorageData = Object.create(null); }\n"
        << "  };\n"
        << "  globalThis.__callbacks = globalThis.__callbacks || Object.create(null);\n"
        << "  function __registerCallback(bucket, event, fn) {\n"
        << "    if (typeof event !== 'string' || typeof fn !== 'function') return;\n"
        << "    if (!bucket[event]) bucket[event] = [];\n"
        << "    bucket[event].push(fn);\n"
        << "  }\n"
        << "  if (typeof globalThis.shared.offsetedStartAni !== 'function') {\n"
        << "    globalThis.shared.offsetedStartAni = function(ani, percentage) {\n"
        << "      if (!ani) return;\n"
        << "      percentage = percentage === undefined ? 1 : percentage;\n"
        << "      if (typeof ani.play === 'function') ani.play();\n"
        << "      if (typeof ani.setFrame === 'function' && typeof ani.frameCount === 'number') {\n"
        << "        ani.setFrame(ani.frameCount * percentage);\n"
        << "      }\n"
        << "    };\n"
        << "  }\n"
        << "  if (typeof globalThis.shared.delayedStartAni !== 'function') {\n"
        << "    globalThis.shared.delayedStartAni = function(ani, delay) {\n"
        << "      if (ani && typeof ani.pause === 'function') ani.pause();\n"
        << "      var cancel = engine.setTimeout(function() {\n"
        << "        if (ani && typeof ani.play === 'function') ani.play();\n"
        << "      }, delay);\n"
        << "      return function() {\n"
        << "        cancel();\n"
        << "        if (ani && typeof ani.play === 'function') ani.play();\n"
        << "      };\n"
        << "    };\n"
        << "  }\n"
        << "  globalThis.isRunningInEditor = false;\n"
        << "  globalThis.MediaPlaybackEvent = Object.freeze({ PLAYBACK_PLAYING: 0, "
           "PLAYBACK_PAUSED: 1, PLAYBACK_STOPPED: 2 });\n"
        << "  engine.isScreensaver = engine.isScreensaver || function() { return false; };\n"
        << "  engine.isWallpaper = engine.isWallpaper || "
           "function() { return !engine.isScreensaver(); };\n"
        << "  engine.isDesktopDevice = engine.isDesktopDevice || function() { return true; };\n"
        << "  engine.isMobileDevice = engine.isMobileDevice || function() { return false; };\n"
        << "  globalThis.editorInfo = [];\n"
        << "  globalThis.debugMode = false;\n"
        << "  globalThis.logInterrupts = false;\n"
        << "  globalThis.tips = false;\n"
        << "  globalThis.canvasSize = engine.canvasSize;\n"
        << "  engine.screenResolution = engine.screenResolution || engine.canvasSize;\n"
        << "  engine.isPortrait = engine.isPortrait || function() {\n"
        << "    var size = engine.screenResolution || engine.canvasSize;\n"
        << "    return !!(size && size.y > size.x);\n"
        << "  };\n"
        << "  engine.isLandscape = engine.isLandscape || function() {\n"
        << "    var size = engine.screenResolution || engine.canvasSize;\n"
        << "    return !!(size && size.x >= size.y);\n"
        << "  };\n"
        << "  engine.on = engine.on || function(event, fn) { "
           "__registerCallback(globalThis.__callbacks, event, fn); };\n"
        << "  globalThis.input = globalThis.input || {};\n"
        << "  globalThis.input.cursorPosition = globalThis.__cursorPosition;\n"
        << "  globalThis.input.cursorWorldPosition = globalThis.__cursorWorldPosition;\n"
        << "  globalThis.input.cursorLocalPosition = globalThis.input.cursorLocalPosition || "
           "globalThis.__cursorWorldPosition;\n"
        << "  globalThis.input.cursorScreenPosition = globalThis.input.cursorScreenPosition || "
           "globalThis.__cursorWorldPosition;\n"
        << "  globalThis.input.mouseButtonsDown = globalThis.__mouseButtonsDown || 0;\n"
        << "  globalThis.input.mouseButtonsPressed = globalThis.__mouseButtonsPressed || 0;\n"
        << "  globalThis.input.mouseButtonsReleased = globalThis.__mouseButtonsReleased || 0;\n"
        << "  globalThis.input.inWindow = !!globalThis.__cursorInWindow;\n"
        << "  globalThis.__timeouts = globalThis.__timeouts || [];\n"
        << "  globalThis.__timeoutSeq = globalThis.__timeoutSeq || 1;\n"
        << "  engine.setTimeout = function(fn, delayMs) {\n"
        << "    var entry = {\n"
        << "      id: globalThis.__timeoutSeq++,\n"
        << "      deadline: engine.runtime + Math.max(0, Number(delayMs) || 0) / 1000.0,\n"
        << "      fn: fn,\n"
        << "      active: true\n"
        << "    };\n"
        << "    globalThis.__timeouts.push(entry);\n"
        << "    return function() { entry.active = false; };\n"
        << "  };\n"
        << "  engine.setInterval = function(fn, delayMs) {\n"
        << "    var interval = Math.max(0, Number(delayMs) || 0) / 1000.0;\n"
        << "    var entry = {\n"
        << "      id: globalThis.__timeoutSeq++,\n"
        << "      deadline: engine.runtime + interval,\n"
        << "      interval: interval,\n"
        << "      fn: fn,\n"
        << "      active: true\n"
        << "    };\n"
        << "    globalThis.__timeouts.push(entry);\n"
        << "    return function() { entry.active = false; };\n"
        << "  };\n"
        << "  engine.clearTimeout = function(handle) { if (typeof handle === 'function') handle(); };\n"
        << "  engine.clearInterval = engine.clearTimeout;\n"
        << "  globalThis.setTimeout = globalThis.setTimeout || function(fn, delayMs) { return engine.setTimeout(fn, delayMs); };\n"
        << "  globalThis.setInterval = globalThis.setInterval || function(fn, delayMs) { return engine.setInterval(fn, delayMs); };\n"
        << "  globalThis.clearTimeout = globalThis.clearTimeout || function(handle) { return engine.clearTimeout(handle); };\n"
        << "  globalThis.clearInterval = globalThis.clearInterval || function(handle) { return engine.clearInterval(handle); };\n"
        << "  globalThis.__processTimeouts = function() {\n"
        << "    if (globalThis.__timeouts.length === 0) return;\n"
        << "    var pending = [];\n"
        << "    var capturedError;\n"
        << "    for (var i = 0; i < globalThis.__timeouts.length; ++i) {\n"
        << "      var entry = globalThis.__timeouts[i];\n"
        << "      if (!entry || !entry.active) continue;\n"
        << "      if (engine.runtime + 1e-9 >= entry.deadline) {\n"
        << "        var repeating = entry.interval > 0;\n"
        << "        if (!repeating) entry.active = false;\n"
        << "        if (typeof entry.fn === 'function') {\n"
        << "          try {\n"
        << "            entry.fn();\n"
        << "          } catch (error) {\n"
        << "            if (capturedError === undefined) capturedError = error;\n"
        << "          }\n"
        << "        }\n"
        << "        if (repeating && entry.active) {\n"
        << "          do { entry.deadline += entry.interval; } while (engine.runtime + 1e-9 >= entry.deadline);\n"
        << "          pending.push(entry);\n"
        << "        }\n"
        << "      } else {\n"
        << "        pending.push(entry);\n"
        << "      }\n"
        << "    }\n"
        << "    globalThis.__timeouts = pending;\n"
        << "    if (capturedError !== undefined) throw capturedError;\n"
        << "  };\n"
        << "  globalThis.__layerCache = globalThis.__layerCache || Object.create(null);\n"
        << "  globalThis.__sceneAnimations = globalThis.__sceneAnimations || "
           "Object.create(null);\n"
        << "  globalThis.__layerOrder = globalThis.__layerOrder || [];\n"
        << "  globalThis.__videoTextureCache = globalThis.__videoTextureCache || "
           "Object.create(null);\n"
        << "  function __rememberLayer(name) {\n"
        << "    if (globalThis.__layerOrder.indexOf(name) < 0) "
           "globalThis.__layerOrder.push(name);\n"
        << "  }\n"
        << "  function __resolveLayerName(layerOrName) {\n"
        << "    if (typeof layerOrName === 'string') return layerOrName;\n"
        << "    if (layerOrName && typeof layerOrName.name === 'string') return layerOrName.name;\n"
        << "    return '';\n"
        << "  }\n"
        << "  function __makePuppetAnimation(layer, name) {\n"
        << "    var native = __puppetAnimationControl(layer, name, 'exists') !== 0;\n"
        << "    var control = function(op, value) { return native ? "
           "__puppetAnimationControl(layer, name, op, value) : 0; };\n"
        << "    return {\n"
        << "      name: name || '',\n"
        << "      get fps() { return control('fps'); },\n"
        << "      get frameCount() { return native ? control('frameCount') : 1; },\n"
        << "      get duration() { return this.fps > 0 ? this.frameCount / this.fps : 0; },\n"
        << "      get rate() { return native ? control('rate') : 1; },\n"
        << "      set rate(value) { control('setRate', Number(value)); },\n"
        << "      get blend() { return native ? control('blend') : 1; },\n"
        << "      set blend(value) { control('setBlend', Number(value)); },\n"
        << "      get visible() { return native ? control('visible') !== 0 : true; },\n"
        << "      set visible(value) { control('setVisible', value ? 1 : 0); },\n"
        << "      _endedCallbacks: [],\n"
        << "      play: function() { control('play'); },\n"
        << "      pause: function() { control('pause'); },\n"
        << "      stop: function() { control('stop'); },\n"
        << "      isPlaying: function() { return control('isPlaying') !== 0; },\n"
        << "      getFrame: function() { return control('frame'); },\n"
        << "      setFrame: function(frame) { control('setFrame', Number(frame) || 0); },\n"
        << "      getCurrentTime: function() { return this.fps > 0 ? control('frame') / "
           "this.fps : 0; },\n"
        << "      addEndedCallback: function(callback) { if (typeof callback === 'function') "
           "this._endedCallbacks.push(callback); },\n"
        << "      removeEndedCallback: function(callback) { this._endedCallbacks = "
           "this._endedCallbacks.filter(function(item) { return item !== callback; }); }\n"
        << "    };\n"
        << "  }\n"
        << "  function __makeAnimation(layer, name) {\n"
        << "    return {\n"
        << "      name: name,\n"
        << "      get fps() { return __animationControl(layer, name, 'fps'); },\n"
        << "      get frameCount() { return __animationControl(layer, name, 'frameCount'); },\n"
        << "      get duration() { return this.fps > 0 ? this.frameCount / this.fps : 0; },\n"
        << "      get rate() { return __animationControl(layer, name, 'rate'); },\n"
        << "      set rate(value) { __animationControl(layer, name, 'setRate', Number(value)); },\n"
        << "      play: function() { __animationControl(layer, name, 'play'); },\n"
        << "      pause: function() { __animationControl(layer, name, 'pause'); },\n"
        << "      stop: function() { __animationControl(layer, name, 'stop'); },\n"
        << "      isPlaying: function() { return !!__animationControl(layer, name, 'isPlaying'); },\n"
        << "      getFrame: function() { return __animationControl(layer, name, 'frame'); },\n"
        << "      setFrame: function(value) { __animationControl(layer, name, 'setFrame', Number(value)); }\n"
        << "    };\n"
        << "  }\n"
        << "  function __makeVideoTexture(name) {\n"
        << "    if (!globalThis.__videoTextureCache[name]) {\n"
        << "      globalThis.__videoTextureCache[name] = {\n"
        << "        play: function() { __videoPlay(name); },\n"
        << "        isPlaying: function() { return __videoIsPlaying(name); },\n"
        << "        pause: function() { __videoPause(name); },\n"
        << "        stop: function() { __videoPause(name); __videoSetCurrentTime(name, 0); },\n"
        << "        getCurrentTime: function() { return __videoGetCurrentTime(name); },\n"
        << "        setCurrentTime: function(value) { __videoSetCurrentTime(name, value); },\n"
        << "        get duration() { return __videoGetDuration(name); },\n"
        << "        get rate() { return __videoGetRate(name); },\n"
        << "        set rate(value) { __videoSetRate(name, value); }\n"
        << "      };\n"
        << "    }\n"
        << "    return globalThis.__videoTextureCache[name];\n"
        << "  }\n"
        << "  function __createLayer(name) {\n"
        << "    __rememberLayer(name);\n"
        << "    var state = {\n"
        << "      alpha: 1,\n"
        << "      animations: Object.create(null),\n"
        << "      animationLayers: Object.create(null),\n"
        << "      callbacks: Object.create(null),\n"
        << "      playing: false,\n"
        << "      volume: 1,\n"
        << "      muted: false\n"
        << "    };\n"
        << "    var originalOrigin = __layerGetOrigin(name);\n"
        << "    return {\n"
        << "      name: name,\n"
        << "      originalOrigin: originalOrigin,\n"
        << "      get visible() { return __layerGetVisible(name); },\n"
        << "      set visible(v) { __layerSetVisible(name, !!v); },\n"
        << "      get origin() { return __layerGetOrigin(name); },\n"
        << "      set origin(v) { __layerSetOrigin(name, v); },\n"
        << "      get scale() { return __layerGetScale(name); },\n"
        << "      set scale(v) { __layerSetScale(name, v); },\n"
        << "      get color() { return __layerGetColor(name); },\n"
        << "      set color(v) { __layerSetColor(name, v); },\n"
        << "      get alignment() { return state.alignment || 'center'; },\n"
        << "      set alignment(v) { state.alignment = String(v || 'center'); "
           "__layerSetAlignment(name, state.alignment); },\n"
        << "      get angles() { return __layerGetAngles(name); },\n"
        << "      set angles(v) { __layerSetAngles(name, v); },\n"
        << "      get size() { return __layerGetSize(name); },\n"
        << "      get text() { return __layerGetText(name); },\n"
        << "      set text(v) { __layerSetText(name, v); },\n"
        // Null means this layer owns no material the runtime can tint — a sound
        // layer, an empty group — so it keeps answering with what was written to
        // it, exactly as it did before the material had a say.
        << "      get alpha() {\n"
        << "        var live = __layerGetAlpha(name);\n"
        << "        return live === null ? state.alpha : live;\n"
        << "      },\n"
        << "      set alpha(v) {\n"
        << "        var numeric = Number(v);\n"
        << "        if (!Number.isFinite(numeric)) numeric = 0;\n"
        << "        state.alpha = numeric;\n"
        // A layer with no material of its own keeps the script-side value it
        // always kept, so reading back what was written still works there.
        << "        __layerSetAlpha(name, numeric);\n"
        << "      },\n"
        // The graph root has no name, so a top-level layer answers null rather
        // than a layer object standing in for the scene itself.
        << "      getParent: function() {\n"
        << "        var parent = __layerGetParentName(name);\n"
        << "        return parent ? globalThis.scene.getLayer(parent) : null;\n"
        << "      },\n"
        << "      play: function() {\n"
        << "        if (__soundKnown(name)) {\n"
        << "          __soundPlay(name);\n"
        << "          return;\n"
        << "        }\n"
        << "        state.playing = true;\n"
        << "      },\n"
        << "      pause: function() {\n"
        << "        if (__soundKnown(name)) {\n"
        << "          __soundPause(name);\n"
        << "          return;\n"
        << "        }\n"
        << "        state.playing = false;\n"
        << "      },\n"
        << "      stop: function() {\n"
        << "        if (__soundKnown(name)) {\n"
        << "          __soundStop(name);\n"
        << "          return;\n"
        << "        }\n"
        << "        state.playing = false;\n"
        << "      },\n"
        << "      isPlaying: function() { return __soundKnown(name) ? __soundIsPlaying(name) : "
           "!!state.playing; },\n"
        << "      on: function(event, fn) { __registerCallback(state.callbacks, event, fn); },\n"
        << "      emit: function(event, payload) {\n"
        << "        var callbacks = state.callbacks[event] || [];\n"
        << "        for (var i = 0; i < callbacks.length; ++i) callbacks[i](payload);\n"
        << "      },\n"
        << "      get volume() { return __soundKnown(name) ? __soundGetVolume(name) : "
           "state.volume; },\n"
        << "      set volume(v) {\n"
        << "        var numeric = Number(v);\n"
        << "        if (!Number.isFinite(numeric)) numeric = 0;\n"
        << "        if (__soundKnown(name)) {\n"
        << "          __soundSetVolume(name, numeric);\n"
        << "        } else {\n"
        << "          state.volume = numeric;\n"
        << "        }\n"
        << "      },\n"
        << "      get muted() { return __soundKnown(name) ? __soundGetMuted(name) : !!state.muted; "
           "},\n"
        << "      set muted(v) {\n"
        << "        if (__soundKnown(name)) {\n"
        << "          __soundSetMuted(name, !!v);\n"
        << "        } else {\n"
        << "          state.muted = !!v;\n"
        << "        }\n"
        << "      },\n"
        << "      getAnimation: function(animationName) {\n"
        << "        var key = String(animationName || '');\n"
        << "        if (!state.animations[key]) state.animations[key] = __makeAnimation(name, key);\n"
        << "        return state.animations[key];\n"
        << "      },\n"
        << "      getAnimationLayer: function(layerName) {\n"
        << "        var key = String(layerName);\n"
        << "        if (!state.animationLayers[key]) state.animationLayers[key] = "
           "__makePuppetAnimation(name, key);\n"
        << "        return state.animationLayers[key];\n"
        << "      },\n"
        << "      getAnimationLayerCount: function() { return "
           "Object.keys(state.animationLayers).length; },\n"
        << "      getTextureAnimation: function() {\n"
        << "        if (!state.textureAnimation) state.textureAnimation = {\n"
        << "          setFrame: function(frame) { __textureSetFrame(name, Number(frame)); },\n"
        << "          getFrame: function() { return __textureGetFrame(name); }\n"
        << "        };\n"
        << "        return state.textureAnimation;\n"
        << "      },\n"
        << "      getVideoTexture: function() { return __makeVideoTexture(name); }\n"
        << "    };\n"
        << "  }\n"
        << "  var __sceneBase = {\n"
        << "    on: function(event, fn) {\n"
        << "      __registerCallback(globalThis.__callbacks, event, fn);\n"
        << "    },\n"
        << "    getLayer: function(name) {\n"
        << "      name = __layerResolveName(String(name));\n"
        << "      if (!globalThis.__layerCache[name]) globalThis.__layerCache[name] = "
           "__createLayer(name);\n"
        << "      return globalThis.__layerCache[name];\n"
        << "    },\n"
        << "    getAnimation: function(animationName) {\n"
        << "      var key = String(animationName || '');\n"
        << "      if (!globalThis.__sceneAnimations[key]) globalThis.__sceneAnimations[key] = "
           "__makeAnimation(null, key);\n"
        << "      return globalThis.__sceneAnimations[key];\n"
        << "    },\n"
        << "    getObject: function(name) {\n"
        << "      return this.getLayer(name);\n"
        << "    },\n"
        << "    getSprite: function(name) {\n"
        << "      return this.getLayer(name);\n"
        << "    }\n"
        << "  };\n"
        << "  globalThis.scene = new Proxy(__sceneBase, {\n"
        << "    get: function(target, prop) {\n"
        << "      if (prop in target) return target[prop];\n"
        << "      var key = String(prop).toLowerCase();\n"
        << "      if (globalThis.__sceneProps && key in globalThis.__sceneProps) return "
           "globalThis.__sceneProps[key];\n"
        << "      return target[prop];\n"
        << "    },\n"
        << "    set: function(target, prop, value) { target[String(prop)] = value; return true; }\n"
        << "  });\n"
        << "  __sceneBase.getLayerIndex = function(layerOrName) {\n"
        << "    var name = __resolveLayerName(layerOrName);\n"
        << "    if (!name) return -1;\n"
        << "    if (!globalThis.__layerCache[name]) globalThis.__layerCache[name] = "
           "__createLayer(name);\n"
        << "    var nativeIndex = __layerGetIndex(name);\n"
        << "    if (nativeIndex >= 0) return nativeIndex;\n"
        << "    return globalThis.__layerOrder.indexOf(name);\n"
        << "  };\n"
        << "  function __layerConfigVector(value) {\n"
        << "    if (typeof value !== 'string') return value;\n"
        << "    var parts = value.trim().split(/\\s+/).map(Number);\n"
        << "    return new Vec3(parts[0], parts[1], parts[2]);\n"
        << "  }\n"
        << "  __sceneBase.__createLayerFor = function(currentLayerName, configuration, workshopId) {\n"
        << "    var options = typeof configuration === 'object' && configuration !== null ? configuration : null;\n"
        << "    var templateName = options ? String(options.image || '') : String(configuration || '');\n"
        << "    var generatedName = __layerCreate(templateName, String(currentLayerName || ''), "
           "String(workshopId || ''));\n"
        << "    if (!generatedName) throw new Error('Unable to create layer: ' + templateName);\n"
        << "    var generated = __createLayer(generatedName);\n"
        << "    generated.template = templateName;\n"
        << "    globalThis.__layerCache[generatedName] = generated;\n"
        << "    if (options) {\n"
        << "      if (options.origin !== undefined) generated.origin = __layerConfigVector(options.origin);\n"
        << "      if (options.scale !== undefined) generated.scale = __layerConfigVector(options.scale);\n"
        << "      if (options.angles !== undefined) generated.angles = __layerConfigVector(options.angles);\n"
        << "      if (options.color !== undefined) generated.color = __layerConfigVector(options.color);\n"
        << "      if (options.alpha !== undefined) generated.alpha = options.alpha;\n"
        << "      if (options.visible !== undefined) generated.visible = options.visible;\n"
        << "      if (options.alignment !== undefined) generated.alignment = options.alignment;\n"
        << "      generated.originalOrigin = generated.origin;\n"
        << "    }\n"
        << "    return generated;\n"
        << "  };\n"
        << "  __sceneBase.createLayer = function(sourcePath) {\n"
        << "    return this.__createLayerFor('', sourcePath);\n"
        << "  };\n"
        // Only a layer a script created is removed. The scene file's own
        // layers stay, as does a layer named by index (getLayer resolves no
        // index either), and the call answers false for them.
        << "  __sceneBase.destroyLayer = function(layerOrName) {\n"
        << "    var name = typeof layerOrName === 'string' ? __layerResolveName(layerOrName) : "
           "__resolveLayerName(layerOrName);\n"
        << "    if (!name || !__layerDestroy(name)) return false;\n"
        << "    delete globalThis.__layerCache[name];\n"
        << "    var order = globalThis.__layerOrder.indexOf(name);\n"
        << "    if (order >= 0) globalThis.__layerOrder.splice(order, 1);\n"
        << "    return true;\n"
        << "  };\n"
        << "  __sceneBase.sortLayer = function(layerOrName, index) {\n"
        << "    var name = __resolveLayerName(layerOrName);\n"
        << "    if (!name) return;\n"
        << "    if (!globalThis.__layerCache[name]) globalThis.__layerCache[name] = "
           "__createLayer(name);\n"
        << "    var currentIndex = globalThis.__layerOrder.indexOf(name);\n"
        << "    if (currentIndex >= 0) globalThis.__layerOrder.splice(currentIndex, 1);\n"
        << "    var requestedIndex = Math.floor(Number(index) || 0);\n"
        << "    if (requestedIndex < 0) requestedIndex = 0;\n"
        << "    var targetIndex = requestedIndex;\n"
        << "    if (targetIndex > globalThis.__layerOrder.length) targetIndex = "
           "globalThis.__layerOrder.length;\n"
        << "    globalThis.__layerOrder.splice(targetIndex, 0, name);\n"
        << "    __layerSort(name, requestedIndex);\n"
        << "  };\n"
        << "  globalThis.__runSceneCallbacks = function(event, payload) {\n"
        << "    var callbacks = globalThis.__callbacks[event] || [];\n"
        << "    for (var i = 0; i < callbacks.length; ++i) callbacks[i](payload);\n"
        << "  };\n";
    g_script_startup_metrics.bootstrap_build_ms += MeasureElapsedMs(started);
}

JSValue CreateCanvasSizeObject(JSContext* context, const ScriptHostContext& host_context) {
    return CreateJsVec2(context, host_context.canvas_size.x(), host_context.canvas_size.y());
}

JSValue CreateScreenResolutionObject(JSContext* context, const ScriptHostContext& host_context) {
    const float width  = host_context.screen_resolution.x() > 0.0f
                             ? host_context.screen_resolution.x()
                             : host_context.canvas_size.x();
    const float height = host_context.screen_resolution.y() > 0.0f
                             ? host_context.screen_resolution.y()
                             : host_context.canvas_size.y();
    return CreateJsVec2(context, width, height);
}

JSValue CreateCursorWorldPositionObject(JSContext* context, const ScriptHostContext& host_context) {
    return CreateJsVec3(context,
                        host_context.cursor_world_position.x(),
                        host_context.cursor_world_position.y(),
                        host_context.cursor_world_position.z());
}

JSValue CreateCursorPositionObject(JSContext* context, const ScriptHostContext& host_context) {
    return CreateJsVec2(context,
                        host_context.cursor_normalized_position.x(),
                        host_context.cursor_normalized_position.y());
}

SceneScriptBridgeState* GetBridgeState(JSContext* context);

JSValue CreateAudioArray(JSContext* context, uint32_t resolution) {
    JSValue length = JS_NewUint32(context, resolution);
    JSValue array = JS_NewTypedArray(context, 1, &length, JS_TYPED_ARRAY_FLOAT32);
    JS_FreeValue(context, length);
    return array;
}

JSValue CreateAudioBufferObject(JSContext* context, RegisteredAudioBuffer& registration) {
    JSValue buffer = JS_NewObject(context);
    if (JS_IsException(buffer)) return buffer;
    const std::array<const char*, 3> names {"left", "right", "average"};
    for (size_t index = 0; index < names.size(); ++index) {
        registration.arrays[index] = CreateAudioArray(context, registration.resolution);
        if (JS_IsException(registration.arrays[index]) ||
            JS_SetPropertyStr(context, buffer, names[index], JS_DupValue(context, registration.arrays[index])) < 0) {
            JS_FreeValue(context, buffer);
            return JS_EXCEPTION;
        }
    }
    if (JS_SetPropertyStr(context, buffer, "__resolution", JS_NewUint32(context, registration.resolution)) < 0) {
        JS_FreeValue(context, buffer);
        return JS_EXCEPTION;
    }
    return buffer;
}

/// `engine.openUserShortcut(name)` -- run the action this wallpaper's user
/// bound to one of its own `usershortcut` properties.
///
/// The scene names the property; the request carries that property's value,
/// which is the user's own choice and the only thing a host may act on. A
/// scene naming a property it does not declare gets a thrown error rather than
/// silence, because that is a wallpaper bug its author can see.
JSValue JsOpenUserShortcut(JSContext* context, JSValueConst, int argc, JSValueConst* argv) {
    if (argc < 1 || ! JS_IsString(argv[0])) {
        return JS_ThrowTypeError(context, "openUserShortcut expects a property name");
    }
    const char* raw = JS_ToCString(context, argv[0]);
    if (raw == nullptr) return JS_EXCEPTION;
    const std::string name(raw);
    JS_FreeCString(context, raw);

    auto* bridge = GetBridgeState(context);
    if (bridge == nullptr || bridge->runtime == nullptr) return JS_UNDEFINED;

    const auto* value = bridge->runtime->FindPropertyValue(name);
    if (value == nullptr) {
        return JS_ThrowReferenceError(
            context, "openUserShortcut names no property of this wallpaper: %s", name.c_str());
    }
    // A press is a rare, deliberate act, so saying what it resolved to costs
    // nothing and is the only way to tell an unbound button from one whose
    // request never reached the host.
    LOG_INFO("openUserShortcut %s -> \"%s\"", name.c_str(), value->toString().c_str());
    bridge->runtime->RequestUserShortcut(name, value->toString());
    return JS_UNDEFINED;
}

JSValue JsRegisterAudioBuffers(JSContext* context, JSValueConst, int argc, JSValueConst* argv) {
    uint32_t resolution = 64;
    if (argc > 0) {
        uint32_t requested = 64;
        if (JS_ToUint32(context, &requested, argv[0]) < 0) return JS_EXCEPTION;
        if (requested == 16 || requested == 32 || requested == 64) {
            resolution = requested;
        }
    }

    RegisteredAudioBuffer registration {.resolution = resolution};
    JSValue buffer = CreateAudioBufferObject(context, registration);
    if (JS_IsException(buffer)) {
        for (const auto array : registration.arrays) JS_FreeValue(context, array);
        return buffer;
    }
    try {
        auto& cache = GetContextScriptCache(context);
        cache.audio_buffers.push_back(registration);
        cache.has_last_audio_generation = false;
    } catch (const std::bad_alloc&) {
        for (const auto array : registration.arrays) JS_FreeValue(context, array);
        JS_FreeValue(context, buffer);
        return JS_ThrowOutOfMemory(context);
    }
    auto* bridge = GetBridgeState(context);
    if (bridge != nullptr && bridge->runtime != nullptr) bridge->runtime->MarkSceneRequiresAudioResponse();
    return buffer;
}

JSValue JsEngineIsRunningInEditor(JSContext* context, JSValueConst, int, JSValueConst*) {
    return JS_NewBool(context, false);
}

// `engine.timeOfDay` is read from the clock when a script asks for it, so the
// many scripts that never look at the hour cost nothing extra per frame.
JSValue JsEngineTimeOfDay(JSContext* context, JSValueConst, int, JSValueConst*) {
    return JS_NewFloat64(context,
                         LocalTimeOfDay(std::chrono::system_clock::now()).value_or(0.0));
}

JSValue JsRegisterAsset(JSContext* context, JSValueConst, int argc, JSValueConst* argv) {
    if (argc < 1) return JS_NewString(context, "");
    return JS_DupValue(context, argv[0]);
}

void UpdateScriptPropertiesObject(JSContext* context, JSValue target,
                                  const std::map<std::string, DynamicValue*>& script_properties) {
    for (const auto& [name, value] : script_properties) {
        if (value == nullptr) continue;
        JS_SetPropertyStr(context, target, name.c_str(), DynamicValueToJS(context, *value));
    }
}

std::string QuoteJsString(const std::string& value) {
    std::string result;
    result.reserve(value.size() + 2);
    result.push_back('"');
    for (char character : value) {
        switch (character) {
        case '\\': result += "\\\\"; break;
        case '"': result += "\\\""; break;
        case '\n': result += "\\n"; break;
        case '\r': result += "\\r"; break;
        case '\t': result += "\\t"; break;
        default: result.push_back(character); break;
        }
    }
    result.push_back('"');
    return result;
}

void PopulateEngineObject(JSContext* context, JSValue engine_object,
                          const ScriptHostContext& host_context) {
    JS_SetPropertyStr(
        context, engine_object, "canvasSize", CreateCanvasSizeObject(context, host_context));
    JS_SetPropertyStr(context,
                      engine_object,
                      "screenResolution",
                      CreateScreenResolutionObject(context, host_context));
    JS_SetPropertyStr(
        context, engine_object, "frametime", JS_NewFloat64(context, host_context.frame_time));
    JS_SetPropertyStr(
        context, engine_object, "runtime", JS_NewFloat64(context, host_context.runtime_seconds));
    const JSAtom time_of_day = JS_NewAtom(context, "timeOfDay");
    JS_DefinePropertyGetSet(context,
                            engine_object,
                            time_of_day,
                            JS_NewCFunction(context, JsEngineTimeOfDay, "timeOfDay", 0),
                            JS_UNDEFINED,
                            JS_PROP_CONFIGURABLE | JS_PROP_ENUMERABLE);
    JS_FreeAtom(context, time_of_day);
    JS_SetPropertyStr(context,
                      engine_object,
                      "isRunningInEditor",
                      JS_NewCFunction(context, JsEngineIsRunningInEditor, "isRunningInEditor", 0));
    JS_SetPropertyStr(context, engine_object, "userProperties", JS_NewObject(context));
    JS_SetPropertyStr(context, engine_object, "AUDIO_RESOLUTION_16", JS_NewInt32(context, 16));
    JS_SetPropertyStr(context, engine_object, "AUDIO_RESOLUTION_32", JS_NewInt32(context, 32));
    JS_SetPropertyStr(context, engine_object, "AUDIO_RESOLUTION_64", JS_NewInt32(context, 64));
    JS_SetPropertyStr(context,
                      engine_object,
                      "registerAudioBuffers",
                      JS_NewCFunction(context, JsRegisterAudioBuffers, "registerAudioBuffers", 1));
    JS_SetPropertyStr(context,
                      engine_object,
                      "registerAsset",
                      JS_NewCFunction(context, JsRegisterAsset, "registerAsset", 1));
    JS_SetPropertyStr(context,
                      engine_object,
                      "openUserShortcut",
                      JS_NewCFunction(context, JsOpenUserShortcut, "openUserShortcut", 1));
}

void UpdateEngineObject(JSContext* context, JSValue global_object,
                        const ScriptHostContext& host_context) {
    auto&      cache_state = GetContextScriptCache(context);
    const bool host_changed =
        ! cache_state.has_last_host_context ||
        std::abs(cache_state.last_host_context.frame_time - host_context.frame_time) > 1.0e-9 ||
        std::abs(cache_state.last_host_context.runtime_seconds - host_context.runtime_seconds) >
            1.0e-9 ||
        ! cache_state.last_host_context.canvas_size.isApprox(host_context.canvas_size, 1.0e-6f) ||
        ! cache_state.last_host_context.screen_resolution.isApprox(
            host_context.screen_resolution, 1.0e-6f) ||
        ! cache_state.last_host_context.cursor_normalized_position.isApprox(
            host_context.cursor_normalized_position, 1.0e-6f) ||
        ! cache_state.last_host_context.cursor_world_position.isApprox(
            host_context.cursor_world_position, 1.0e-6f) ||
        cache_state.last_host_context.cursor_in_window != host_context.cursor_in_window ||
        cache_state.last_host_context.mouse_buttons_down != host_context.mouse_buttons_down ||
        cache_state.last_host_context.mouse_buttons_pressed != host_context.mouse_buttons_pressed ||
        cache_state.last_host_context.mouse_buttons_released != host_context.mouse_buttons_released;

    JSValue engine_object = JS_GetPropertyStr(context, global_object, "engine");
    if (JS_IsObject(engine_object)) {
        if (host_changed) {
            JS_SetPropertyStr(context,
                              engine_object,
                              "canvasSize",
                              CreateCanvasSizeObject(context, host_context));
            JS_SetPropertyStr(context,
                              engine_object,
                              "screenResolution",
                              CreateScreenResolutionObject(context, host_context));
            JS_SetPropertyStr(context,
                              engine_object,
                              "frametime",
                              JS_NewFloat64(context, host_context.frame_time));
            JS_SetPropertyStr(context,
                              engine_object,
                              "runtime",
                              JS_NewFloat64(context, host_context.runtime_seconds));
        }
    }
    JS_FreeValue(context, engine_object);

    JSValue input_object = JS_GetPropertyStr(context, global_object, "input");
    if (JS_IsObject(input_object)) {
        if (host_changed) {
            JS_SetPropertyStr(context,
                              input_object,
                              "cursorPosition",
                              CreateCursorPositionObject(context, host_context));
            JS_SetPropertyStr(context,
                              input_object,
                              "cursorWorldPosition",
                              CreateCursorWorldPositionObject(context, host_context));
            JS_SetPropertyStr(context,
                              input_object,
                              "cursorLocalPosition",
                              CreateCursorWorldPositionObject(context, host_context));
            JS_SetPropertyStr(context,
                              input_object,
                              "cursorScreenPosition",
                              CreateCursorWorldPositionObject(context, host_context));
            JS_SetPropertyStr(context,
                              input_object,
                              "mouseButtonsDown",
                              JS_NewUint32(context, host_context.mouse_buttons_down));
            JS_SetPropertyStr(context,
                              input_object,
                              "mouseButtonsPressed",
                              JS_NewUint32(context, host_context.mouse_buttons_pressed));
            JS_SetPropertyStr(context,
                              input_object,
                              "mouseButtonsReleased",
                              JS_NewUint32(context, host_context.mouse_buttons_released));
            JS_SetPropertyStr(context,
                              input_object,
                              "inWindow",
                              JS_NewBool(context, host_context.cursor_in_window));
        }
    }
    JS_FreeValue(context, input_object);

    if (! cache_state.audio_buffers.empty()) {
        const auto* bridge = GetBridgeState(context);
        const auto snapshot = bridge != nullptr && bridge->runtime != nullptr
            ? bridge->runtime->CurrentAudioSpectrumSnapshot() : wallpaper::audio::AudioSpectrumSnapshot {};
        const bool audio_changed = ! cache_state.has_last_audio_generation ||
                                   cache_state.last_audio_generation != snapshot.generation;
        if (audio_changed) {
            for (auto& registration : cache_state.audio_buffers) {
                if (! registration.active) continue;
                const auto write_array = [&](size_t index, const auto& values) {
                    // The native registration owns both layout and original
                    // typed view. Script properties never select native bounds.
                    for (size_t band = 0; band < values.size(); ++band) {
                        const int result = JS_SetPropertyUint32(context, registration.arrays[index],
                            static_cast<uint32_t>(band), JS_NewFloat64(context, values[band]));
                        if (result <= 0) {
                            registration.active = false;
                            if (result < 0) LogJsException(context, "registered audio view update");
                            return false;
                        }
                    }
                    return true;
                };
                const auto write = [&](const auto& left, const auto& right, const auto& average) {
                    return write_array(0, left) && write_array(1, right) && write_array(2, average);
                };
                if (registration.resolution == 16) write(snapshot.left16, snapshot.right16, snapshot.average16);
                else if (registration.resolution == 32) write(snapshot.left32, snapshot.right32, snapshot.average32);
                else write(snapshot.left64, snapshot.right64, snapshot.average64);
            }
        }
        cache_state.last_audio_generation = snapshot.generation;
        cache_state.has_last_audio_generation = true;
    }

    if (host_changed) {
        JS_SetPropertyStr(context,
                          global_object,
                          "__cursorPosition",
                          CreateCursorPositionObject(context, host_context));
        JS_SetPropertyStr(context,
                          global_object,
                          "__cursorWorldPosition",
                          CreateCursorWorldPositionObject(context, host_context));

        JSValue canvas_size = CreateCanvasSizeObject(context, host_context);
        JS_SetPropertyStr(context, global_object, "canvasSize", JS_DupValue(context, canvas_size));
        JS_SetPropertyStr(context, global_object, "__canvasSize", canvas_size);
        JS_SetPropertyStr(context,
                          global_object,
                          "__mouseButtonsDown",
                          JS_NewUint32(context, host_context.mouse_buttons_down));
        JS_SetPropertyStr(context,
                          global_object,
                          "__mouseButtonsPressed",
                          JS_NewUint32(context, host_context.mouse_buttons_pressed));
        JS_SetPropertyStr(context,
                          global_object,
                          "__mouseButtonsReleased",
                          JS_NewUint32(context, host_context.mouse_buttons_released));
        JS_SetPropertyStr(context,
                          global_object,
                          "__cursorInWindow",
                          JS_NewBool(context, host_context.cursor_in_window));

        cache_state.last_host_context     = host_context;
        cache_state.has_last_host_context = true;
    }
}

JSValue CreateScenePropertiesObject(JSContext*               context,
                                    const ProjectProperties& project_properties) {
    JSValue object = JS_NewObject(context);
    for (const auto& [name, value] : project_properties) {
        std::string lowered = name;
        for (char& character : lowered) {
            character = static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
        }
        JS_SetPropertyStr(context, object, lowered.c_str(), RuntimeScalarValueToJS(context, value));
    }
    return object;
}

JSValue CreateUserPropertiesObject(JSContext*               context,
                                   const ProjectProperties& project_properties) {
    JSValue object = JS_NewObject(context);
    for (const auto& [name, value] : project_properties) {
        JS_SetPropertyStr(context, object, name.c_str(), RuntimeScalarValueToJS(context, value));
    }
    return object;
}

JSValue CreateChangedPropertiesObject(JSContext*               context,
                                      const ProjectProperties& project_properties) {
    JSValue object = JS_NewObject(context);
    for (const auto& [name, value] : project_properties) {
        JS_SetPropertyStr(context, object, name.c_str(), RuntimeScalarValueToJS(context, value));
    }
    return object;
}

void SetEngineUserProperties(JSContext* context, JSValue global_object,
                             const ProjectProperties& project_properties) {
    JSValue engine_object = JS_GetPropertyStr(context, global_object, "engine");
    if (JS_IsObject(engine_object)) {
        JS_SetPropertyStr(context,
                          engine_object,
                          "userProperties",
                          CreateUserPropertiesObject(context, project_properties));
    }
    JS_FreeValue(context, engine_object);
}

SceneScriptBridgeState* GetBridgeState(JSContext* context) {
    return static_cast<SceneScriptBridgeState*>(JS_GetContextOpaque(context));
}

JSValue CallStoredExport(JSContext* context, const char* exports_object_name,
                         const char* export_name, int argc, JSValueConst* argv) {
    JSValue global_object = JS_GetGlobalObject(context);
    JSValue exports       = JS_GetPropertyStr(context, global_object, exports_object_name);
    JSValue function      = JS_GetPropertyStr(context, exports, export_name);

    JSValue result = JS_UNDEFINED;
    if (JS_IsFunction(context, function)) {
        result = JS_Call(context, function, JS_UNDEFINED, argc, argv);
        if (JS_IsException(result)) {
            LogJsException(context, export_name);
        }
    }

    JS_FreeValue(context, function);
    JS_FreeValue(context, exports);
    JS_FreeValue(context, global_object);
    return result;
}

JSValue JsLayerResolveName(JSContext* context, JSValueConst, int argc, JSValueConst* argv) {
    if (argc < 1) return JS_NewString(context, "");
    auto* bridge = GetBridgeState(context);
    if (bridge == nullptr || bridge->runtime == nullptr) return JS_DupValue(context, argv[0]);
    const char* name = JS_ToCString(context, argv[0]);
    if (name == nullptr) return JS_EXCEPTION;
    const auto resolved = bridge->runtime->ResolveLayerName(name);
    JS_FreeCString(context, name);
    return JS_NewStringLen(context, resolved.data(), resolved.size());
}

JSValue JsLayerGetVisible(JSContext* context, JSValueConst, int argc, JSValueConst* argv) {
    if (argc < 1) return JS_NewBool(context, false);
    auto* bridge = GetBridgeState(context);
    if (bridge == nullptr || bridge->runtime == nullptr) return JS_NewBool(context, false);

    const char* layer_name = JS_ToCString(context, argv[0]);
    const bool  visible    = layer_name != nullptr && bridge->runtime->NodeVisible(layer_name);
    if (layer_name != nullptr) JS_FreeCString(context, layer_name);
    return JS_NewBool(context, visible);
}

JSValue JsLayerSetVisible(JSContext* context, JSValueConst, int argc, JSValueConst* argv) {
    if (argc < 2) return JS_UNDEFINED;
    auto* bridge = GetBridgeState(context);
    if (bridge == nullptr || bridge->runtime == nullptr) return JS_UNDEFINED;

    const char* layer_name = JS_ToCString(context, argv[0]);
    const bool  visible    = JS_ToBool(context, argv[1]) != 0;
    if (layer_name != nullptr) {
        bridge->runtime->SetNodeVisible(layer_name, visible);
        JS_FreeCString(context, layer_name);
    }
    return JS_UNDEFINED;
}

JSValue JsLayerGetOrigin(JSContext* context, JSValueConst, int argc, JSValueConst* argv) {
    if (argc < 1) return CreateJsVec3(context, 0.0, 0.0, 0.0);
    auto* bridge = GetBridgeState(context);
    if (bridge == nullptr || bridge->runtime == nullptr)
        return CreateJsVec3(context, 0.0, 0.0, 0.0);

    const char* layer_name = JS_ToCString(context, argv[0]);
    const auto  value      = layer_name != nullptr ? bridge->runtime->NodeTranslate(layer_name)
                                                   : Eigen::Vector3f::Zero();
    if (layer_name != nullptr) JS_FreeCString(context, layer_name);
    return CreateJsVec3(context, value.x(), value.y(), value.z());
}

JSValue JsLayerSetOrigin(JSContext* context, JSValueConst, int argc, JSValueConst* argv) {
    if (argc < 2) return JS_UNDEFINED;
    auto* bridge = GetBridgeState(context);
    if (bridge == nullptr || bridge->runtime == nullptr) return JS_UNDEFINED;

    const char* layer_name = JS_ToCString(context, argv[0]);
    JSValue     value_arg  = JS_DupValue(context, argv[1]);
    auto        value      = JsToDynamicValue(context, value_arg, DynamicValue::Vec3);
    JS_FreeValue(context, value_arg);

    if (layer_name != nullptr && value != nullptr) {
        bridge->runtime->SetNodeTranslate(layer_name, value->getVec3());
    }
    if (layer_name != nullptr) JS_FreeCString(context, layer_name);
    return JS_UNDEFINED;
}

JSValue JsLayerGetScale(JSContext* context, JSValueConst, int argc, JSValueConst* argv) {
    if (argc < 1) return CreateJsVec3(context, 1.0, 1.0, 1.0);
    auto* bridge = GetBridgeState(context);
    if (bridge == nullptr || bridge->runtime == nullptr)
        return CreateJsVec3(context, 1.0, 1.0, 1.0);

    const char* layer_name = JS_ToCString(context, argv[0]);
    const auto  value =
        layer_name != nullptr ? bridge->runtime->NodeScale(layer_name) : Eigen::Vector3f::Ones();
    if (layer_name != nullptr) JS_FreeCString(context, layer_name);
    return CreateJsVec3(context, value.x(), value.y(), value.z());
}

JSValue JsLayerSetScale(JSContext* context, JSValueConst, int argc, JSValueConst* argv) {
    if (argc < 2) return JS_UNDEFINED;
    auto* bridge = GetBridgeState(context);
    if (bridge == nullptr || bridge->runtime == nullptr) return JS_UNDEFINED;

    const char* layer_name = JS_ToCString(context, argv[0]);
    JSValue     value_arg  = JS_DupValue(context, argv[1]);
    auto        value      = JsToDynamicValue(context, value_arg, DynamicValue::Vec3);
    JS_FreeValue(context, value_arg);

    if (layer_name != nullptr && value != nullptr) {
        bridge->runtime->SetNodeScale(layer_name, value->getVec3());
    }
    if (layer_name != nullptr) JS_FreeCString(context, layer_name);
    return JS_UNDEFINED;
}

JSValue JsLayerGetColor(JSContext* context, JSValueConst, int argc, JSValueConst* argv) {
    auto* bridge = GetBridgeState(context);
    if (argc < 1 || bridge == nullptr || bridge->runtime == nullptr)
        return CreateJsVec3(context, 1.0, 1.0, 1.0);
    const char* name = JS_ToCString(context, argv[0]);
    const Eigen::Vector3f color = name != nullptr ? bridge->runtime->NodeColor(name)
                                                  : Eigen::Vector3f::Ones();
    if (name != nullptr) JS_FreeCString(context, name);
    return CreateJsVec3(context, color.x(), color.y(), color.z());
}

JSValue JsLayerSetColor(JSContext* context, JSValueConst, int argc, JSValueConst* argv) {
    auto* bridge = GetBridgeState(context);
    if (argc < 2 || bridge == nullptr || bridge->runtime == nullptr) return JS_UNDEFINED;
    const char* name = JS_ToCString(context, argv[0]);
    DynamicValue color;
    FillDynamicValueFromJS(context, argv[1], DynamicValue::Vec3, color);
    if (name != nullptr && color.getType() == DynamicValue::Vec3)
        bridge->runtime->SetNodeColor(name, color.getVec3());
    if (name != nullptr) JS_FreeCString(context, name);
    return JS_UNDEFINED;
}

JSValue JsLayerSetAlignment(JSContext* context, JSValueConst, int argc, JSValueConst* argv) {
    if (argc < 2) return JS_UNDEFINED;
    auto* bridge = GetBridgeState(context);
    if (bridge == nullptr || bridge->runtime == nullptr) return JS_UNDEFINED;

    const char* layer_name = JS_ToCString(context, argv[0]);
    const char* alignment  = JS_ToCString(context, argv[1]);
    if (layer_name != nullptr && alignment != nullptr) {
        bridge->runtime->SetNodeAlignment(layer_name, std::string(alignment));
    }
    if (alignment != nullptr) JS_FreeCString(context, alignment);
    if (layer_name != nullptr) JS_FreeCString(context, layer_name);
    return JS_UNDEFINED;
}

JSValue JsLayerGetAngles(JSContext* context, JSValueConst, int argc, JSValueConst* argv) {
    if (argc < 1) return CreateJsVec3(context, 0.0, 0.0, 0.0);
    auto* bridge = GetBridgeState(context);
    if (bridge == nullptr || bridge->runtime == nullptr)
        return CreateJsVec3(context, 0.0, 0.0, 0.0);

    const char* layer_name = JS_ToCString(context, argv[0]);
    const auto  value      = layer_name != nullptr
                                 ? RadiansToDegrees(bridge->runtime->NodeRotation(layer_name))
                                 : Eigen::Vector3f::Zero();
    if (layer_name != nullptr) JS_FreeCString(context, layer_name);
    return CreateJsVec3(context, value.x(), value.y(), value.z());
}

JSValue JsLayerSetAngles(JSContext* context, JSValueConst, int argc, JSValueConst* argv) {
    if (argc < 2) return JS_UNDEFINED;
    auto* bridge = GetBridgeState(context);
    if (bridge == nullptr || bridge->runtime == nullptr) return JS_UNDEFINED;

    const char* layer_name = JS_ToCString(context, argv[0]);
    JSValue     value_arg  = JS_DupValue(context, argv[1]);
    auto        value      = JsToDynamicValue(context, value_arg, DynamicValue::Vec3);
    JS_FreeValue(context, value_arg);

    if (layer_name != nullptr && value != nullptr) {
        bridge->runtime->SetNodeRotation(layer_name, DegreesToRadians(value->getVec3()));
    }
    if (layer_name != nullptr) JS_FreeCString(context, layer_name);
    return JS_UNDEFINED;
}

JSValue JsLayerGetSize(JSContext* context, JSValueConst, int argc, JSValueConst* argv) {
    if (argc < 1) return CreateJsVec2(context, 0.0, 0.0);
    auto* bridge = GetBridgeState(context);
    if (bridge == nullptr || bridge->runtime == nullptr) return CreateJsVec2(context, 0.0, 0.0);

    const char* layer_name = JS_ToCString(context, argv[0]);
    const auto  value =
        layer_name != nullptr ? bridge->runtime->NodeSize(layer_name) : Eigen::Vector2f::Zero();
    if (layer_name != nullptr) JS_FreeCString(context, layer_name);
    return CreateJsVec2(context, value.x(), value.y());
}

JSValue JsLayerGetParentName(JSContext* context, JSValueConst, int argc, JSValueConst* argv) {
    if (argc < 1) return JS_NewString(context, "");
    auto* bridge = GetBridgeState(context);
    if (bridge == nullptr || bridge->runtime == nullptr) return JS_NewString(context, "");

    const char* layer_name = JS_ToCString(context, argv[0]);
    const auto  parent =
        layer_name != nullptr ? bridge->runtime->NodeParentName(layer_name) : std::string();
    if (layer_name != nullptr) JS_FreeCString(context, layer_name);
    return JS_NewString(context, parent.c_str());
}

JSValue JsLayerGetAlpha(JSContext* context, JSValueConst, int argc, JSValueConst* argv) {
    if (argc < 1) return JS_NULL;
    auto* bridge = GetBridgeState(context);
    if (bridge == nullptr || bridge->runtime == nullptr) return JS_NULL;

    const char* layer_name = JS_ToCString(context, argv[0]);
    const std::optional<float> value = layer_name != nullptr
                                           ? bridge->runtime->NodeAlpha(layer_name)
                                           : std::optional<float> {};
    if (layer_name != nullptr) JS_FreeCString(context, layer_name);
    return value ? JS_NewFloat64(context, *value) : JS_NULL;
}

JSValue JsLayerSetAlpha(JSContext* context, JSValueConst, int argc, JSValueConst* argv) {
    if (argc < 2) return JS_NewBool(context, false);
    auto* bridge = GetBridgeState(context);
    if (bridge == nullptr || bridge->runtime == nullptr) return JS_NewBool(context, false);

    const char* layer_name = JS_ToCString(context, argv[0]);
    double      value      = 1.0;
    bool        applied    = false;
    if (JS_ToFloat64(context, &value, argv[1]) == 0 && layer_name != nullptr) {
        applied = bridge->runtime->SetNodeAlpha(layer_name, static_cast<float>(value));
    }
    if (layer_name != nullptr) JS_FreeCString(context, layer_name);
    return JS_NewBool(context, applied);
}

JSValue JsLayerGetText(JSContext* context, JSValueConst, int argc, JSValueConst* argv) {
    if (argc < 1) return JS_NewString(context, "");
    auto* bridge = GetBridgeState(context);
    if (bridge == nullptr || bridge->runtime == nullptr) return JS_NewString(context, "");

    const char* layer_name = JS_ToCString(context, argv[0]);
    const auto  value =
        layer_name != nullptr ? bridge->runtime->NodeText(layer_name) : std::string();
    if (layer_name != nullptr) JS_FreeCString(context, layer_name);
    return JS_NewStringLen(context, value.data(), value.size());
}

JSValue JsLayerSetText(JSContext* context, JSValueConst, int argc, JSValueConst* argv) {
    if (argc < 2) return JS_UNDEFINED;
    auto* bridge = GetBridgeState(context);
    if (bridge == nullptr || bridge->runtime == nullptr) return JS_UNDEFINED;

    const char* layer_name = JS_ToCString(context, argv[0]);
    const char* text       = JS_ToCString(context, argv[1]);
    if (layer_name != nullptr && text != nullptr) {
        bridge->runtime->SetNodeText(layer_name, std::string(text));
    }
    if (text != nullptr) JS_FreeCString(context, text);
    if (layer_name != nullptr) JS_FreeCString(context, layer_name);
    return JS_UNDEFINED;
}

JSValue JsLayerCreate(JSContext* context, JSValueConst, int argc, JSValueConst* argv) {
    if (argc < 2) return JS_NewString(context, "");
    auto* bridge = GetBridgeState(context);
    if (bridge == nullptr || bridge->runtime == nullptr) return JS_NewString(context, "");

    const char* template_name      = JS_ToCString(context, argv[0]);
    const char* current_layer_name = JS_ToCString(context, argv[1]);
    const char* workshop_id        = argc >= 3 ? JS_ToCString(context, argv[2]) : nullptr;
    std::string generated_name;
    if (template_name != nullptr) {
        generated_name = bridge->runtime->CreateLayerFromTemplate(
            template_name,
            current_layer_name != nullptr ? current_layer_name : "",
            workshop_id != nullptr ? workshop_id : "");
    }
    if (template_name != nullptr) JS_FreeCString(context, template_name);
    if (current_layer_name != nullptr) JS_FreeCString(context, current_layer_name);
    if (workshop_id != nullptr) JS_FreeCString(context, workshop_id);
    return JS_NewString(context, generated_name.c_str());
}

JSValue JsLayerDestroy(JSContext* context, JSValueConst, int argc, JSValueConst* argv) {
    if (argc < 1) return JS_NewBool(context, false);
    auto* bridge = GetBridgeState(context);
    if (bridge == nullptr || bridge->runtime == nullptr) return JS_NewBool(context, false);

    const char* layer_name = JS_ToCString(context, argv[0]);
    const bool  destroyed  = layer_name != nullptr && bridge->runtime->DestroyLayer(layer_name);
    if (layer_name != nullptr) JS_FreeCString(context, layer_name);
    return JS_NewBool(context, destroyed);
}

JSValue JsLayerGetIndex(JSContext* context, JSValueConst, int argc, JSValueConst* argv) {
    if (argc < 1) return JS_NewInt32(context, -1);
    auto* bridge = GetBridgeState(context);
    if (bridge == nullptr || bridge->runtime == nullptr) return JS_NewInt32(context, -1);

    const char* layer_name = JS_ToCString(context, argv[0]);
    const int   index = layer_name != nullptr ? bridge->runtime->NodeSiblingIndex(layer_name) : -1;
    if (layer_name != nullptr) JS_FreeCString(context, layer_name);
    return JS_NewInt32(context, index);
}

JSValue JsLayerSort(JSContext* context, JSValueConst, int argc, JSValueConst* argv) {
    if (argc < 2) return JS_UNDEFINED;
    auto* bridge = GetBridgeState(context);
    if (bridge == nullptr || bridge->runtime == nullptr) return JS_UNDEFINED;

    const char* layer_name = JS_ToCString(context, argv[0]);
    int32_t     index      = 0;
    JS_ToInt32(context, &index, argv[1]);
    if (layer_name != nullptr) {
        bridge->runtime->SortNode(layer_name, static_cast<int>(index));
        JS_FreeCString(context, layer_name);
    }
    return JS_UNDEFINED;
}

JSValue JsSoundKnown(JSContext* context, JSValueConst, int argc, JSValueConst* argv) {
    auto* bridge = GetBridgeState(context);
    if (bridge == nullptr || bridge->runtime == nullptr || argc < 1)
        return JS_NewBool(context, false);

    const char* layer_name = JS_ToCString(context, argv[0]);
    const bool  known      = layer_name != nullptr && bridge->runtime->HasSoundLayer(layer_name);
    if (layer_name != nullptr) JS_FreeCString(context, layer_name);
    return JS_NewBool(context, known);
}

JSValue JsSoundPlay(JSContext* context, JSValueConst, int argc, JSValueConst* argv) {
    auto* bridge = GetBridgeState(context);
    if (bridge == nullptr || bridge->runtime == nullptr || argc < 1)
        return JS_NewBool(context, false);

    const char* layer_name = JS_ToCString(context, argv[0]);
    const bool  played     = layer_name != nullptr && bridge->runtime->PlaySoundLayer(layer_name);
    if (layer_name != nullptr) JS_FreeCString(context, layer_name);
    return JS_NewBool(context, played);
}

JSValue JsSoundPause(JSContext* context, JSValueConst, int argc, JSValueConst* argv) {
    auto* bridge = GetBridgeState(context);
    if (bridge == nullptr || bridge->runtime == nullptr || argc < 1)
        return JS_NewBool(context, false);

    const char* layer_name = JS_ToCString(context, argv[0]);
    const bool  paused     = layer_name != nullptr && bridge->runtime->PauseSoundLayer(layer_name);
    if (layer_name != nullptr) JS_FreeCString(context, layer_name);
    return JS_NewBool(context, paused);
}

JSValue JsSoundStop(JSContext* context, JSValueConst, int argc, JSValueConst* argv) {
    auto* bridge = GetBridgeState(context);
    if (bridge == nullptr || bridge->runtime == nullptr || argc < 1)
        return JS_NewBool(context, false);

    const char* layer_name = JS_ToCString(context, argv[0]);
    const bool  stopped    = layer_name != nullptr && bridge->runtime->StopSoundLayer(layer_name);
    if (layer_name != nullptr) JS_FreeCString(context, layer_name);
    return JS_NewBool(context, stopped);
}

JSValue JsSoundIsPlaying(JSContext* context, JSValueConst, int argc, JSValueConst* argv) {
    auto* bridge = GetBridgeState(context);
    if (bridge == nullptr || bridge->runtime == nullptr || argc < 1)
        return JS_NewBool(context, false);

    const char* layer_name = JS_ToCString(context, argv[0]);
    const bool  playing = layer_name != nullptr && bridge->runtime->SoundLayerPlaying(layer_name);
    if (layer_name != nullptr) JS_FreeCString(context, layer_name);
    return JS_NewBool(context, playing);
}

JSValue JsSoundGetVolume(JSContext* context, JSValueConst, int argc, JSValueConst* argv) {
    auto* bridge = GetBridgeState(context);
    if (bridge == nullptr || bridge->runtime == nullptr || argc < 1)
        return JS_NewFloat64(context, 0.0);

    const char* layer_name = JS_ToCString(context, argv[0]);
    const float volume =
        layer_name != nullptr ? bridge->runtime->SoundLayerVolume(layer_name) : 0.0f;
    if (layer_name != nullptr) JS_FreeCString(context, layer_name);
    return JS_NewFloat64(context, volume);
}

JSValue JsSoundSetVolume(JSContext* context, JSValueConst, int argc, JSValueConst* argv) {
    auto* bridge = GetBridgeState(context);
    if (bridge == nullptr || bridge->runtime == nullptr || argc < 2)
        return JS_NewBool(context, false);

    const char* layer_name = JS_ToCString(context, argv[0]);
    double      volume     = 0.0;
    const bool  parsed     = JS_ToFloat64(context, &volume, argv[1]) == 0;
    const bool  updated =
        layer_name != nullptr && parsed &&
        bridge->runtime->SetSoundLayerVolume(layer_name, static_cast<float>(volume));
    if (layer_name != nullptr) JS_FreeCString(context, layer_name);
    return JS_NewBool(context, updated);
}

JSValue JsSoundGetMuted(JSContext* context, JSValueConst, int argc, JSValueConst* argv) {
    auto* bridge = GetBridgeState(context);
    if (bridge == nullptr || bridge->runtime == nullptr || argc < 1)
        return JS_NewBool(context, false);

    const char* layer_name = JS_ToCString(context, argv[0]);
    const bool  muted      = layer_name != nullptr && bridge->runtime->SoundLayerMuted(layer_name);
    if (layer_name != nullptr) JS_FreeCString(context, layer_name);
    return JS_NewBool(context, muted);
}

JSValue JsSoundSetMuted(JSContext* context, JSValueConst, int argc, JSValueConst* argv) {
    auto* bridge = GetBridgeState(context);
    if (bridge == nullptr || bridge->runtime == nullptr || argc < 2)
        return JS_NewBool(context, false);

    const char* layer_name = JS_ToCString(context, argv[0]);
    const bool  muted      = JS_ToBool(context, argv[1]) != 0;
    const bool  updated =
        layer_name != nullptr && bridge->runtime->SetSoundLayerMuted(layer_name, muted);
    if (layer_name != nullptr) JS_FreeCString(context, layer_name);
    return JS_NewBool(context, updated);
}

JSValue JsAnimationControl(JSContext* context, JSValueConst, int argc, JSValueConst* argv) {
    auto* bridge = GetBridgeState(context);
    if (bridge == nullptr || bridge->runtime == nullptr || argc < 3) return JS_UNDEFINED;
    // A null layer means `scene.getAnimation(name)`: the authored name is looked
    // up across the scene instead of inside one layer.
    const bool  scene_wide = JS_IsNull(argv[0]) || JS_IsUndefined(argv[0]);
    const char* layer      = scene_wide ? nullptr : JS_ToCString(context, argv[0]);
    const char* name       = JS_ToCString(context, argv[1]);
    const char* operation  = JS_ToCString(context, argv[2]);
    auto*       playback =
        name == nullptr ? nullptr
        : scene_wide    ? bridge->runtime->FindAnimationByName(name)
        : layer != nullptr ? bridge->runtime->FindScalarAnimation(layer, name)
                           : nullptr;
    double result = 0.0;
    if (playback != nullptr && operation != nullptr) {
        const std::string_view command(operation);
        double value = 0.0;
        const bool has_value = argc > 3 && JS_ToFloat64(context, &value, argv[3]) == 0 && std::isfinite(value);
        if (command == "play") playback->Play();
        else if (command == "pause") playback->playing = false;
        else if (command == "stop") playback->Stop();
        else if (command == "setFrame" && has_value) playback->SetFrame(value);
        else if (command == "setRate" && has_value) playback->rate = value;
        else if (command == "fps") result = playback->animation.fps;
        else if (command == "frameCount") result = playback->animation.FrameCount();
        else if (command == "rate") result = playback->rate;
        else if (command == "frame") result = playback->frame;
        else if (command == "isPlaying") result = playback->playing ? 1.0 : 0.0;
    }
    if (operation != nullptr) JS_FreeCString(context, operation);
    if (name != nullptr) JS_FreeCString(context, name);
    if (layer != nullptr) JS_FreeCString(context, layer);
    return JS_NewFloat64(context, result);
}

JSValue JsPuppetAnimationControl(JSContext* context, JSValueConst, int argc, JSValueConst* argv) {
    auto* bridge = GetBridgeState(context);
    if (bridge == nullptr || bridge->runtime == nullptr || argc < 3) return JS_NewFloat64(context, 0.0);
    const char* layer     = JS_ToCString(context, argv[0]);
    const char* name      = JS_ToCString(context, argv[1]);
    const char* operation = JS_ToCString(context, argv[2]);
    double      result    = 0.0;
    if (layer != nullptr && name != nullptr && operation != nullptr) {
        double     value     = 0.0;
        const bool has_value = argc > 3 && JS_ToFloat64(context, &value, argv[3]) == 0 &&
                               std::isfinite(value);
        result = bridge->runtime->PuppetAnimationControl(layer, name, operation, value, has_value);
    }
    if (operation != nullptr) JS_FreeCString(context, operation);
    if (name != nullptr) JS_FreeCString(context, name);
    if (layer != nullptr) JS_FreeCString(context, layer);
    return JS_NewFloat64(context, result);
}

JSValue JsTextureSetFrame(JSContext* context, JSValueConst, int argc, JSValueConst* argv) {
    auto* bridge = GetBridgeState(context);
    if (argc < 2 || bridge == nullptr || bridge->runtime == nullptr) return JS_UNDEFINED;
    double frame = 0;
    if (JS_ToFloat64(context, &frame, argv[1]) < 0) return JS_EXCEPTION;
    const char* name = JS_ToCString(context, argv[0]);
    if (name != nullptr) {
        bridge->runtime->SetNodeTextureFrame(name, frame);
        JS_FreeCString(context, name);
    }
    return JS_UNDEFINED;
}

JSValue JsTextureGetFrame(JSContext* context, JSValueConst, int argc, JSValueConst* argv) {
    auto* bridge = GetBridgeState(context);
    double frame = 0;
    if (argc > 0 && bridge != nullptr && bridge->runtime != nullptr) {
        const char* name = JS_ToCString(context, argv[0]);
        if (name != nullptr) {
            frame = bridge->runtime->NodeTextureFrame(name);
            JS_FreeCString(context, name);
        }
    }
    return JS_NewFloat64(context, frame);
}

JSValue JsVideoIsPlaying(JSContext* context, JSValueConst, int argc, JSValueConst* argv) {
    auto* bridge = GetBridgeState(context);
    bool playing = false;
    if (argc > 0 && bridge != nullptr && bridge->runtime != nullptr) {
        const char* name = JS_ToCString(context, argv[0]);
        if (name != nullptr) {
            playing = bridge->runtime->NodeVideoTextureIsPlaying(name);
            JS_FreeCString(context, name);
        }
    }
    return JS_NewBool(context, playing);
}

JSValue JsVideoPlay(JSContext* context, JSValueConst, int argc, JSValueConst* argv) {
    if (argc < 1) return JS_UNDEFINED;
    auto* bridge = GetBridgeState(context);
    if (bridge == nullptr || bridge->runtime == nullptr) return JS_UNDEFINED;

    const char* layer_name = JS_ToCString(context, argv[0]);
    if (layer_name != nullptr) {
        bridge->runtime->PlayNodeVideoTexture(layer_name);
        JS_FreeCString(context, layer_name);
    }
    return JS_UNDEFINED;
}

JSValue JsVideoPause(JSContext* context, JSValueConst, int argc, JSValueConst* argv) {
    if (argc < 1) return JS_UNDEFINED;
    auto* bridge = GetBridgeState(context);
    if (bridge == nullptr || bridge->runtime == nullptr) return JS_UNDEFINED;

    const char* layer_name = JS_ToCString(context, argv[0]);
    if (layer_name != nullptr) {
        bridge->runtime->PauseNodeVideoTexture(layer_name);
        JS_FreeCString(context, layer_name);
    }
    return JS_UNDEFINED;
}

JSValue JsVideoGetCurrentTime(JSContext* context, JSValueConst, int argc, JSValueConst* argv) {
    if (argc < 1) return JS_NewFloat64(context, 0.0);
    auto* bridge = GetBridgeState(context);
    if (bridge == nullptr || bridge->runtime == nullptr) return JS_NewFloat64(context, 0.0);

    const char* layer_name = JS_ToCString(context, argv[0]);
    double      seconds    = 0.0;
    if (layer_name != nullptr) {
        seconds = bridge->runtime->NodeVideoTextureCurrentTime(layer_name);
        JS_FreeCString(context, layer_name);
    }
    return JS_NewFloat64(context, seconds);
}

JSValue JsVideoSetCurrentTime(JSContext* context, JSValueConst, int argc, JSValueConst* argv) {
    if (argc < 2) return JS_UNDEFINED;
    auto* bridge = GetBridgeState(context);
    if (bridge == nullptr || bridge->runtime == nullptr) return JS_UNDEFINED;

    const char* layer_name = JS_ToCString(context, argv[0]);
    double      seconds    = 0.0;
    JS_ToFloat64(context, &seconds, argv[1]);
    if (layer_name != nullptr) {
        bridge->runtime->SetNodeVideoTextureCurrentTime(layer_name, seconds);
        JS_FreeCString(context, layer_name);
    }
    return JS_UNDEFINED;
}

JSValue JsVideoGetRate(JSContext* context, JSValueConst, int argc, JSValueConst* argv) {
    if (argc < 1) return JS_NewFloat64(context, 1.0);
    auto* bridge = GetBridgeState(context);
    if (bridge == nullptr || bridge->runtime == nullptr) return JS_NewFloat64(context, 1.0);

    const char* layer_name = JS_ToCString(context, argv[0]);
    double      rate       = 1.0;
    if (layer_name != nullptr) {
        rate = static_cast<double>(bridge->runtime->NodeVideoTextureRate(layer_name));
        JS_FreeCString(context, layer_name);
    }
    return JS_NewFloat64(context, rate);
}

JSValue JsVideoSetRate(JSContext* context, JSValueConst, int argc, JSValueConst* argv) {
    if (argc < 2) return JS_UNDEFINED;
    auto* bridge = GetBridgeState(context);
    if (bridge == nullptr || bridge->runtime == nullptr) return JS_UNDEFINED;

    const char* layer_name = JS_ToCString(context, argv[0]);
    double      rate       = 1.0;
    JS_ToFloat64(context, &rate, argv[1]);
    if (layer_name != nullptr) {
        bridge->runtime->SetNodeVideoTextureRate(layer_name, static_cast<float>(rate));
        JS_FreeCString(context, layer_name);
    }
    return JS_UNDEFINED;
}

JSValue JsVideoGetDuration(JSContext* context, JSValueConst, int argc, JSValueConst* argv) {
    if (argc < 1) return JS_NewFloat64(context, 0.0);
    auto* bridge = GetBridgeState(context);
    if (bridge == nullptr || bridge->runtime == nullptr) return JS_NewFloat64(context, 0.0);

    const char* layer_name = JS_ToCString(context, argv[0]);
    double      duration   = 0.0;
    if (layer_name != nullptr) {
        duration = bridge->runtime->NodeVideoTextureDuration(layer_name);
        JS_FreeCString(context, layer_name);
    }
    return JS_NewFloat64(context, duration);
}

void ProcessScheduledCallbacks(JSContext* context) {
    JSValue global_object = JS_GetGlobalObject(context);
    JSValue process       = JS_GetPropertyStr(context, global_object, "__processTimeouts");
    if (JS_IsFunction(context, process)) {
        JSValue result = JS_Call(context, process, JS_UNDEFINED, 0, nullptr);
        if (JS_IsException(result)) {
            LogJsException(context, "__processTimeouts");
        }
        JS_FreeValue(context, result);
    }
    JS_FreeValue(context, process);
    JS_FreeValue(context, global_object);
}

JSValue BuildCursorEventObject(JSContext* context, const ScriptHostContext& host_context) {
    JSValue event = JS_NewObject(context);
    JS_SetPropertyStr(context, event, "button", JS_NewInt32(context, host_context.cursor_button));
    JSValue world_position = CreateCursorWorldPositionObject(context, host_context);
    JS_SetPropertyStr(
        context, event, "normalizedPosition", CreateCursorPositionObject(context, host_context));
    JS_SetPropertyStr(context, event, "worldPosition", JS_DupValue(context, world_position));
    JS_SetPropertyStr(context, event, "position", world_position);
    return event;
}

void CallPropertyExport(JSContext* context, const char* export_name, int argc, JSValueConst* argv) {
    JSValue result = CallStoredExport(context, "__propertyExports", export_name, argc, argv);
    JS_FreeValue(context, result);
}

void CallSceneExport(JSContext* context, const char* export_name, int argc, JSValueConst* argv) {
    JSValue result = CallStoredExport(context, "__sceneExports", export_name, argc, argv);
    JS_FreeValue(context, result);
}

// The authored AnimationEvent carries the marker's name and its frame.
JSValue BuildAnimationEventObject(JSContext* context, std::string_view event_name, double frame) {
    JSValue event = JS_NewObject(context);
    JS_SetPropertyStr(context,
                      event,
                      "name",
                      JS_NewStringLen(context, event_name.data(), event_name.size()));
    JS_SetPropertyStr(context, event, "frame", JS_NewFloat64(context, frame));
    return event;
}

void RunSceneCallbacks(JSContext* context, const char* event_name,
                       JSValueConst payload = JS_UNDEFINED) {
    JSValue global_object = JS_GetGlobalObject(context);
    JSValue runner        = JS_GetPropertyStr(context, global_object, "__runSceneCallbacks");

    if (JS_IsFunction(context, runner)) {
        JSValue                     event = JS_NewString(context, event_name);
        std::array<JSValueConst, 2> argv { event, payload };
        JSValue                     result = JS_Call(context, runner, JS_UNDEFINED, 2, argv.data());
        if (JS_IsException(result)) {
            LogJsException(context, "__runSceneCallbacks");
        }
        JS_FreeValue(context, result);
        JS_FreeValue(context, event);
    }

    JS_FreeValue(context, runner);
    JS_FreeValue(context, global_object);
}

void CoerceMediaEventColorArrays(JSContext* context, JSValue event_object) {
    static constexpr const char* keys[] = {
        "primaryColor", "secondaryColor", "tertiaryColor", "textColor", "highContrastColor",
    };
    for (const char* key : keys) {
        JSValue value = JS_GetPropertyStr(context, event_object, key);
        if (JS_IsException(value)) {
            JS_FreeValue(context, value);
            continue;
        }
        if (JS_IsArray(value)) {
            JSValue x = JS_GetPropertyUint32(context, value, 0);
            JSValue y = JS_GetPropertyUint32(context, value, 1);
            JSValue z = JS_GetPropertyUint32(context, value, 2);
            double  dx = 0.0;
            double  dy = 0.0;
            double  dz = 0.0;
            JS_ToFloat64(context, &dx, x);
            JS_ToFloat64(context, &dy, y);
            JS_ToFloat64(context, &dz, z);
            JS_FreeValue(context, x);
            JS_FreeValue(context, y);
            JS_FreeValue(context, z);
            JS_SetPropertyStr(context, event_object, key, CreateJsVec3(context, dx, dy, dz));
        }
        JS_FreeValue(context, value);
    }
}

void DispatchMediaEventJsonToScript(JSContext* context, const std::string& exports_object_name,
                                    std::string_view event_json, bool run_scene_callbacks) {
    if (context == nullptr || event_json.empty()) return;

    JSValue event_object =
        JS_ParseJSON(context, event_json.data(), event_json.size(), "<media-event>");
    if (JS_IsException(event_object)) {
        LogJsException(context, "media event parse");
        JS_FreeValue(context, event_object);
        return;
    }
    CoerceMediaEventColorArrays(context, event_object);

    JSValue type_value = JS_GetPropertyStr(context, event_object, "type");
    if (JS_IsException(type_value)) {
        LogJsException(context, "media event type");
        JS_FreeValue(context, type_value);
        JS_FreeValue(context, event_object);
        return;
    }

    const char* type = JS_ToCString(context, type_value);
    if (type == nullptr && JS_HasException(context)) {
        LogJsException(context, "media event type");
        JS_FreeValue(context, type_value);
        JS_FreeValue(context, event_object);
        return;
    }
    if (type != nullptr && type[0] != '\0') {
        JSValueConst argv[] = { event_object };
        JSValue      result = CallStoredExport(context, exports_object_name.c_str(), type, 1, argv);
        JS_FreeValue(context, result);
        if (run_scene_callbacks) {
            RunSceneCallbacks(context, type, event_object);
        }
    }
    if (type != nullptr) JS_FreeCString(context, type);
    JS_FreeValue(context, type_value);
    JS_FreeValue(context, event_object);
}

std::string BuildCommonHostBootstrapSource() {
    std::ostringstream wrapper;
    wrapper << "(function() {\n";
    AppendCommonHostBootstrap(wrapper);
    wrapper << "})();\n";
    return wrapper.str();
}

std::string BuildPropertyScriptFactorySource(const ScriptFrontEndResult& front_end) {
    const auto         started = std::chrono::steady_clock::now();
    std::ostringstream wrapper;
    wrapper << "(function(__scriptContext) {\n"
            << "  var __props = globalThis[__scriptContext.propsName];\n";
    AppendScriptPropertiesBuilder(wrapper);
    AppendThisScene(wrapper);
    wrapper << "  let thisLayer = __scriptContext.layerName ? "
               "globalThis.scene.getLayer(__scriptContext.layerName) : undefined;\n"
            << "  let thisObject = thisLayer;\n"
            << front_end.transformed_body << "\n"
            << "  globalThis[__scriptContext.exportsName] = {\n"
            << "    init: (typeof init === 'function') ? init : null,\n"
            << "    update: (typeof update === 'function') ? update : null,\n"
            << "    cursorClick: (typeof cursorClick === 'function') ? cursorClick : null,\n"
            << "    cursorDown: (typeof cursorDown === 'function') ? cursorDown : null,\n"
            << "    cursorEnter: (typeof cursorEnter === 'function') ? cursorEnter : null,\n"
            << "    cursorLeave: (typeof cursorLeave === 'function') ? cursorLeave : null,\n"
            << "    cursorMove: (typeof cursorMove === 'function') ? cursorMove : null,\n"
            << "    cursorUp: (typeof cursorUp === 'function') ? cursorUp : null,\n"
            << "    animationEvent: (typeof animationEvent === 'function') ? animationEvent : "
               "null,\n"
            << "    mediaPlaybackChanged: (typeof mediaPlaybackChanged === 'function') ? "
               "mediaPlaybackChanged : null,\n"
            << "    mediaPropertiesChanged: (typeof mediaPropertiesChanged === 'function') ? "
               "mediaPropertiesChanged : null,\n"
            << "    mediaStatusChanged: (typeof mediaStatusChanged === 'function') ? "
               "mediaStatusChanged : null,\n"
            << "    mediaTimelineChanged: (typeof mediaTimelineChanged === 'function') ? "
               "mediaTimelineChanged : null,\n"
            << "    mediaThumbnailChanged: (typeof mediaThumbnailChanged === 'function') ? "
               "mediaThumbnailChanged : null,\n"
            << "    applyUserProperties: (typeof applyUserProperties === 'function') ? "
               "applyUserProperties : null\n"
            << "  };\n"
            << "})\n";

    auto result = wrapper.str();
    g_script_startup_metrics.wrapper_build_ms += MeasureElapsedMs(started);
    return result;
}

std::string BuildSceneScriptFactorySource(const ScriptFrontEndResult& front_end) {
    const auto         started = std::chrono::steady_clock::now();
    std::ostringstream wrapper;
    wrapper << "(function(__scriptContext) {\n"
            << "  var __props = globalThis.__scriptProps || {};\n";
    AppendScriptPropertiesBuilder(wrapper);
    AppendThisScene(wrapper);
    wrapper << "  let thisLayer = __scriptContext.layerName ? "
               "globalThis.scene.getLayer(__scriptContext.layerName) : undefined;\n"
            << "  let thisObject = thisLayer;\n"
            << front_end.transformed_body << "\n"
            << "  globalThis[__scriptContext.exportsName] = {\n"
            << "    init: (typeof init === 'function') ? init : null,\n"
            << "    update: (typeof update === 'function') ? update : null,\n"
            << "    cursorClick: (typeof cursorClick === 'function') ? cursorClick : null,\n"
            << "    cursorDown: (typeof cursorDown === 'function') ? cursorDown : null,\n"
            << "    cursorEnter: (typeof cursorEnter === 'function') ? cursorEnter : null,\n"
            << "    cursorLeave: (typeof cursorLeave === 'function') ? cursorLeave : null,\n"
            << "    cursorMove: (typeof cursorMove === 'function') ? cursorMove : null,\n"
            << "    cursorUp: (typeof cursorUp === 'function') ? cursorUp : null,\n"
            << "    animationEvent: (typeof animationEvent === 'function') ? animationEvent : "
               "null,\n"
            << "    applyUserProperties: (typeof applyUserProperties === 'function') ? "
               "applyUserProperties : null,\n"
            << "    mediaPlaybackChanged: (typeof mediaPlaybackChanged === 'function') ? "
               "mediaPlaybackChanged : null,\n"
            << "    mediaPropertiesChanged: (typeof mediaPropertiesChanged === 'function') ? "
               "mediaPropertiesChanged : null,\n"
            << "    mediaStatusChanged: (typeof mediaStatusChanged === 'function') ? "
               "mediaStatusChanged : null,\n"
            << "    mediaTimelineChanged: (typeof mediaTimelineChanged === 'function') ? "
               "mediaTimelineChanged : null,\n"
            << "    mediaThumbnailChanged: (typeof mediaThumbnailChanged === 'function') ? "
               "mediaThumbnailChanged : null\n"
            << "  };\n"
            << "})\n";

    auto result = wrapper.str();
    g_script_startup_metrics.wrapper_build_ms += MeasureElapsedMs(started);
    return result;
}

bool EnsureSharedHostBindings(JSContext* context, SceneRuntimeContext* runtime,
                              const ScriptHostContext& host_context,
                              const ProjectProperties* project_properties) {
    auto& cache_state  = GetContextScriptCache(context);
    auto* bridge_state = static_cast<SceneScriptBridgeState*>(JS_GetContextOpaque(context));
    if (bridge_state == nullptr) {
        bridge_state = new SceneScriptBridgeState {
            .runtime = runtime,
        };
        JS_SetContextOpaque(context, bridge_state);
    } else {
        bridge_state->runtime = runtime;
    }

    JSValue    global_object        = JS_GetGlobalObject(context);
    const auto registration_started = std::chrono::steady_clock::now();

    if (! cache_state.shared_bindings_installed) {
        JS_SetPropertyStr(context,
                          global_object,
                          "__layerResolveName",
                          JS_NewCFunction(context, JsLayerResolveName, "__layerResolveName", 1));
        JS_SetPropertyStr(context,
                          global_object,
                          "__layerGetVisible",
                          JS_NewCFunction(context, JsLayerGetVisible, "__layerGetVisible", 1));
        JS_SetPropertyStr(context,
                          global_object,
                          "__layerSetVisible",
                          JS_NewCFunction(context, JsLayerSetVisible, "__layerSetVisible", 2));
        JS_SetPropertyStr(context,
                          global_object,
                          "__layerGetOrigin",
                          JS_NewCFunction(context, JsLayerGetOrigin, "__layerGetOrigin", 1));
        JS_SetPropertyStr(context,
                          global_object,
                          "__layerSetOrigin",
                          JS_NewCFunction(context, JsLayerSetOrigin, "__layerSetOrigin", 2));
        JS_SetPropertyStr(context,
                          global_object,
                          "__layerGetScale",
                          JS_NewCFunction(context, JsLayerGetScale, "__layerGetScale", 1));
        JS_SetPropertyStr(context,
                          global_object,
                          "__layerSetScale",
                          JS_NewCFunction(context, JsLayerSetScale, "__layerSetScale", 2));
        JS_SetPropertyStr(context, global_object, "__layerGetColor",
                          JS_NewCFunction(context, JsLayerGetColor, "__layerGetColor", 1));
        JS_SetPropertyStr(context, global_object, "__layerSetColor",
                          JS_NewCFunction(context, JsLayerSetColor, "__layerSetColor", 2));
        JS_SetPropertyStr(context,
                          global_object,
                          "__layerSetAlignment",
                          JS_NewCFunction(context, JsLayerSetAlignment, "__layerSetAlignment", 2));
        JS_SetPropertyStr(context,
                          global_object,
                          "__layerGetAngles",
                          JS_NewCFunction(context, JsLayerGetAngles, "__layerGetAngles", 1));
        JS_SetPropertyStr(context,
                          global_object,
                          "__layerSetAngles",
                          JS_NewCFunction(context, JsLayerSetAngles, "__layerSetAngles", 2));
        JS_SetPropertyStr(context,
                          global_object,
                          "__layerGetSize",
                          JS_NewCFunction(context, JsLayerGetSize, "__layerGetSize", 1));
        JS_SetPropertyStr(
            context,
            global_object,
            "__layerGetParentName",
            JS_NewCFunction(context, JsLayerGetParentName, "__layerGetParentName", 1));
        JS_SetPropertyStr(context,
                          global_object,
                          "__layerGetAlpha",
                          JS_NewCFunction(context, JsLayerGetAlpha, "__layerGetAlpha", 1));
        JS_SetPropertyStr(context,
                          global_object,
                          "__layerSetAlpha",
                          JS_NewCFunction(context, JsLayerSetAlpha, "__layerSetAlpha", 2));
        JS_SetPropertyStr(context,
                          global_object,
                          "__layerGetText",
                          JS_NewCFunction(context, JsLayerGetText, "__layerGetText", 1));
        JS_SetPropertyStr(context,
                          global_object,
                          "__layerSetText",
                          JS_NewCFunction(context, JsLayerSetText, "__layerSetText", 2));
        JS_SetPropertyStr(context,
                          global_object,
                          "__layerCreate",
                          JS_NewCFunction(context, JsLayerCreate, "__layerCreate", 2));
        JS_SetPropertyStr(context,
                          global_object,
                          "__layerDestroy",
                          JS_NewCFunction(context, JsLayerDestroy, "__layerDestroy", 1));
        JS_SetPropertyStr(context,
                          global_object,
                          "__layerGetIndex",
                          JS_NewCFunction(context, JsLayerGetIndex, "__layerGetIndex", 1));
        JS_SetPropertyStr(context,
                          global_object,
                          "__layerSort",
                          JS_NewCFunction(context, JsLayerSort, "__layerSort", 2));
        JS_SetPropertyStr(context,
                          global_object,
                          "__soundKnown",
                          JS_NewCFunction(context, JsSoundKnown, "__soundKnown", 1));
        JS_SetPropertyStr(context,
                          global_object,
                          "__soundPlay",
                          JS_NewCFunction(context, JsSoundPlay, "__soundPlay", 1));
        JS_SetPropertyStr(context,
                          global_object,
                          "__soundPause",
                          JS_NewCFunction(context, JsSoundPause, "__soundPause", 1));
        JS_SetPropertyStr(context,
                          global_object,
                          "__soundStop",
                          JS_NewCFunction(context, JsSoundStop, "__soundStop", 1));
        JS_SetPropertyStr(context,
                          global_object,
                          "__soundIsPlaying",
                          JS_NewCFunction(context, JsSoundIsPlaying, "__soundIsPlaying", 1));
        JS_SetPropertyStr(context,
                          global_object,
                          "__soundGetVolume",
                          JS_NewCFunction(context, JsSoundGetVolume, "__soundGetVolume", 1));
        JS_SetPropertyStr(context,
                          global_object,
                          "__soundSetVolume",
                          JS_NewCFunction(context, JsSoundSetVolume, "__soundSetVolume", 2));
        JS_SetPropertyStr(context,
                          global_object,
                          "__soundGetMuted",
                          JS_NewCFunction(context, JsSoundGetMuted, "__soundGetMuted", 1));
        JS_SetPropertyStr(context,
                          global_object,
                          "__soundSetMuted",
                          JS_NewCFunction(context, JsSoundSetMuted, "__soundSetMuted", 2));
        JS_SetPropertyStr(context, global_object, "__animationControl",
                          JS_NewCFunction(context, JsAnimationControl, "__animationControl", 4));
        JS_SetPropertyStr(
            context,
            global_object,
            "__puppetAnimationControl",
            JS_NewCFunction(context, JsPuppetAnimationControl, "__puppetAnimationControl", 4));
        JS_SetPropertyStr(context,
                          global_object,
                          "__textureSetFrame",
                          JS_NewCFunction(context, JsTextureSetFrame, "__textureSetFrame", 2));
        JS_SetPropertyStr(context, global_object,
                          "__textureGetFrame",
                          JS_NewCFunction(context, JsTextureGetFrame, "__textureGetFrame", 1));
        JS_SetPropertyStr(context, global_object,
                          "__videoPlay",
                          JS_NewCFunction(context, JsVideoPlay, "__videoPlay", 1));
        JS_SetPropertyStr(context, global_object, "__videoIsPlaying",
                          JS_NewCFunction(context, JsVideoIsPlaying, "__videoIsPlaying", 1));
        JS_SetPropertyStr(context,
                          global_object,
                          "__videoPause",
                          JS_NewCFunction(context, JsVideoPause, "__videoPause", 1));
        JS_SetPropertyStr(
            context,
            global_object,
            "__videoGetCurrentTime",
            JS_NewCFunction(context, JsVideoGetCurrentTime, "__videoGetCurrentTime", 1));
        JS_SetPropertyStr(
            context,
            global_object,
            "__videoSetCurrentTime",
            JS_NewCFunction(context, JsVideoSetCurrentTime, "__videoSetCurrentTime", 2));
        JS_SetPropertyStr(context,
                          global_object,
                          "__videoGetRate",
                          JS_NewCFunction(context, JsVideoGetRate, "__videoGetRate", 1));
        JS_SetPropertyStr(context,
                          global_object,
                          "__videoSetRate",
                          JS_NewCFunction(context, JsVideoSetRate, "__videoSetRate", 2));
        JS_SetPropertyStr(context,
                          global_object,
                          "__videoGetDuration",
                          JS_NewCFunction(context, JsVideoGetDuration, "__videoGetDuration", 1));
        JSValue engine_object = JS_NewObject(context);
        PopulateEngineObject(context, engine_object, host_context);
        JS_SetPropertyStr(context, global_object, "engine", engine_object);
        cache_state.shared_bindings_installed = true;
    }

    UpdateEngineObject(context, global_object, host_context);
    const ProjectProperties empty_project_properties {};
    JS_SetPropertyStr(context,
                      global_object,
                      "__sceneProps",
                      CreateScenePropertiesObject(context,
                                                  project_properties != nullptr
                                                      ? *project_properties
                                                      : empty_project_properties));
    SetEngineUserProperties(context,
                            global_object,
                            project_properties != nullptr ? *project_properties
                                                          : empty_project_properties);

    g_script_startup_metrics.callback_registration_ms += MeasureElapsedMs(registration_started);

    if (! cache_state.shared_bootstrap_installed) {
        if (! InstallScriptPrimitives(context)) {
            JS_FreeValue(context, global_object);
            return false;
        }

        const std::string bootstrap_source = BuildCommonHostBootstrapSource();
        const auto        eval_started     = std::chrono::steady_clock::now();
        JSValue           bootstrap_result = JS_Eval(context,
                                           bootstrap_source.c_str(),
                                           bootstrap_source.size(),
                                           "<script-bootstrap>",
                                           JS_EVAL_TYPE_GLOBAL);
        g_script_startup_metrics.eval_ms += MeasureElapsedMs(eval_started);
        if (JS_IsException(bootstrap_result)) {
            LogJsException(context, "InstallSceneScriptBootstrap");
            JS_FreeValue(context, bootstrap_result);
            JS_FreeValue(context, global_object);
            return false;
        }
        JS_FreeValue(context, bootstrap_result);
        cache_state.shared_bootstrap_installed = true;
        g_script_startup_metrics.bootstrap_installs++;
    }

    JS_FreeValue(context, global_object);
    return true;
}

JSValue AcquireScriptFactory(JSContext* context, const std::string& script_source,
                             ScriptProgramMode mode) {
    auto&             context_cache = GetContextScriptCache(context);
    const std::string cache_key     = MakeScriptCacheKey(script_source, mode);

    if (const auto iterator = context_cache.factories.find(cache_key);
        iterator != context_cache.factories.end()) {
        return JS_DupValue(context, iterator->second);
    }

    // Factories are only ever cached per JSContext. A process-wide
    // `JS_WriteObject`/`JS_ReadObject` bytecode cache was tried and reverted:
    // bytecode serialized with `JS_WRITE_OBJ_STRIP_DEBUG` deserializes into a
    // function that misbehaves (observed: an endless `lre_exec` inside the
    // restored factory), so the second load of a scene in one process never
    // produced a first frame. Compiling from source is also not measurably
    // slower than restoring bytecode.
    ScriptFrontEndResult front_end      = RunScriptFrontEnd(script_source);
    const std::string    factory_source = mode == ScriptProgramMode::Property
                                              ? BuildPropertyScriptFactorySource(front_end)
                                              : BuildSceneScriptFactorySource(front_end);

    const auto compile_started = std::chrono::steady_clock::now();
    JSValue    compiled        = JS_Eval(context,
                               factory_source.c_str(),
                               factory_source.size(),
                               mode == ScriptProgramMode::Property ? "<property-script-factory>"
                                                                   : "<scene-script-factory>",
                               JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_COMPILE_ONLY);
    g_script_startup_metrics.eval_ms += MeasureElapsedMs(compile_started);
    if (JS_IsException(compiled)) {
        LogJsException(context,
                       mode == ScriptProgramMode::Property ? "PropertyScriptFactoryCompile"
                                                           : "SceneScriptFactoryCompile");
        return JS_EXCEPTION;
    }

    const auto eval_started = std::chrono::steady_clock::now();
    JSValue    factory      = JS_EvalFunction(context, compiled);
    g_script_startup_metrics.eval_ms += MeasureElapsedMs(eval_started);
    if (JS_IsException(factory)) {
        LogJsException(context,
                       mode == ScriptProgramMode::Property ? "PropertyScriptFactoryEval"
                                                           : "SceneScriptFactoryEval");
        return JS_EXCEPTION;
    }
    g_script_startup_metrics.script_compiles++;

    context_cache.factories.emplace(cache_key, JS_DupValue(context, factory));
    return factory;
}

bool ExecuteScriptFactory(JSContext* context, JSValue factory,
                          const std::string& exports_object_name,
                          const std::string& current_layer_name, const std::string_view props_name,
                          const char* scope) {
    JSValue script_context = JS_NewObject(context);
    JS_SetPropertyStr(
        context, script_context, "exportsName", JS_NewString(context, exports_object_name.c_str()));
    JS_SetPropertyStr(
        context, script_context, "layerName", JS_NewString(context, current_layer_name.c_str()));
    if (! props_name.empty()) {
        JS_SetPropertyStr(context,
                          script_context,
                          "propsName",
                          JS_NewStringLen(context, props_name.data(), props_name.size()));
    } else {
        JS_SetPropertyStr(context, script_context, "propsName", JS_NewString(context, ""));
    }

    JSValueConst argv[]       = { script_context };
    const auto   eval_started = std::chrono::steady_clock::now();
    JSValue      result       = JS_Call(context, factory, JS_UNDEFINED, 1, argv);
    g_script_startup_metrics.eval_ms += MeasureElapsedMs(eval_started);
    JS_FreeValue(context, script_context);
    if (JS_IsException(result)) {
        LogJsException(context, scope);
        JS_FreeValue(context, result);
        return false;
    }
    JS_FreeValue(context, result);
    return true;
}

ScriptProgramCapabilities ReadCompiledCapabilities(JSContext* context, const char* exports_name) {
    ScriptProgramCapabilities capabilities;
    JSValue global = JS_GetGlobalObject(context);
    JSValue exports = JS_GetPropertyStr(context, global, exports_name);
    JSValue update = JS_GetPropertyStr(context, exports, "update");
    capabilities.update = JS_IsFunction(context, update);
    JS_FreeValue(context, update);
    constexpr const char* cursor_exports[] = {
        "cursorClick", "cursorDown", "cursorEnter", "cursorLeave", "cursorMove", "cursorUp",
    };
    for (uint8_t index = 0; index < 6; ++index) {
        JSValue handler = JS_GetPropertyStr(context, exports, cursor_exports[index]);
        if (JS_IsFunction(context, handler)) capabilities.cursor_handlers |= uint8_t(1u << index);
        JS_FreeValue(context, handler);
    }
    JSValue animation_event = JS_GetPropertyStr(context, exports, "animationEvent");
    capabilities.animation_event = JS_IsFunction(context, animation_event);
    JS_FreeValue(context, animation_event);
    JS_FreeValue(context, exports);
    JS_FreeValue(context, global);
    return capabilities;
}

} // namespace

PropertyScriptProgram::PropertyScriptProgram(
    SceneRuntimeContext* runtime, std::string script_source, std::string current_layer_name,
    std::map<std::string, DynamicValue*> script_properties, DynamicValue initial_value,
    ScriptHostContext host_context, JSRuntime* shared_runtime, JSContext* shared_context,
    std::string exports_object_name, std::string script_properties_name,
    PropertyScriptValueSemantic semantic)
    : m_script_properties(std::move(script_properties)),
      m_runtime(runtime),
      m_current_layer_name(std::move(current_layer_name)),
      m_exports_object_name(std::move(exports_object_name)),
      m_script_properties_name(std::move(script_properties_name)),
      m_semantic(semantic) {
    auto* runtime_handle = shared_runtime;
    if (runtime_handle == nullptr) {
        LOG_ERROR("PropertyScriptProgram: failed to create JS runtime");
        return;
    }

    auto* context_handle = shared_context;
    if (context_handle == nullptr) {
        LOG_ERROR("PropertyScriptProgram: failed to create JS context");
        return;
    }

    m_impl_runtime = runtime_handle;
    m_impl_context = context_handle;
    m_owns_context = false;

    const ProjectProperties* project_properties =
        runtime != nullptr ? &runtime->projectProperties() : nullptr;
    if (! EnsureSharedHostBindings(context_handle, runtime, host_context, project_properties)) {
        return;
    }

    // Wallpaper Engine evaluates the module before it gives the layer its saved
    // values: code at the top level reads the defaults the script declares, and
    // the saved or user-bound values arrive before init. A script that records
    // where a property started there, and later moves by the difference, moves
    // by nothing if it already sees the final value.
    JSValue global_object = JS_GetGlobalObject(context_handle);
    JS_SetPropertyStr(
        context_handle, global_object, m_script_properties_name.c_str(), JS_NewObject(context_handle));

    JSValue factory =
        AcquireScriptFactory(context_handle, script_source, ScriptProgramMode::Property);
    if (JS_IsException(factory)) {
        JS_FreeValue(context_handle, global_object);
        return;
    }

    if (! ExecuteScriptFactory(context_handle,
                               factory,
                               m_exports_object_name,
                               m_current_layer_name,
                               m_script_properties_name,
                               "PropertyScriptProgram")) {
        JS_FreeValue(context_handle, factory);
        JS_FreeValue(context_handle, global_object);
        return;
    }
    JS_FreeValue(context_handle, factory);
    JS_FreeValue(context_handle, global_object);
    UpdateScriptProperties();

    m_capabilities = ReadCompiledCapabilities(context_handle, m_exports_object_name.c_str());
    m_valid = true;
}

PropertyScriptProgram::~PropertyScriptProgram() {
    auto* context_handle = static_cast<JSContext*>(m_impl_context);
    auto* runtime_handle = static_cast<JSRuntime*>(m_impl_runtime);
    if (m_owns_context && context_handle != nullptr) {
        auto* bridge_state =
            static_cast<SceneScriptBridgeState*>(JS_GetContextOpaque(context_handle));
        delete bridge_state;
        JS_FreeContext(context_handle);
    }
    if (m_owns_context && runtime_handle != nullptr) JS_FreeRuntime(runtime_handle);
}

bool PropertyScriptProgram::Valid() const { return m_valid; }

void PropertyScriptProgram::UpdateHostContext(const ScriptHostContext& host_context) {
    auto* context_handle = static_cast<JSContext*>(m_impl_context);
    if (context_handle == nullptr) return;

    JSValue global_object = JS_GetGlobalObject(context_handle);
    UpdateEngineObject(context_handle, global_object, host_context);
    JS_FreeValue(context_handle, global_object);
}

void PropertyScriptProgram::UpdateScriptProperties() {
    auto* context_handle = static_cast<JSContext*>(m_impl_context);
    if (context_handle == nullptr) return;

    JSValue global_object = JS_GetGlobalObject(context_handle);
    JSValue props_object =
        JS_GetPropertyStr(context_handle, global_object, m_script_properties_name.c_str());
    if (JS_IsObject(props_object)) {
        UpdateScriptPropertiesObject(context_handle, props_object, m_script_properties);
    }
    JS_FreeValue(context_handle, props_object);
    JS_FreeValue(context_handle, global_object);
}

void PropertyScriptProgram::ApplyProjectProperties(
    const ProjectProperties& project_properties, const ProjectProperties& changed_properties) {
    if (! m_valid) return;
    auto* context_handle = static_cast<JSContext*>(m_impl_context);
    if (context_handle == nullptr) return;
    JSValue global_object = JS_GetGlobalObject(context_handle);
    JS_SetPropertyStr(context_handle, global_object, "__sceneProps",
                      CreateScenePropertiesObject(context_handle, project_properties));
    SetEngineUserProperties(context_handle, global_object, project_properties);
    JS_FreeValue(context_handle, global_object);
    UpdateScriptProperties();
    // Lazy initialization delivers the full initial snapshot once, not an
    // additional changed-property event before the program has initialized.
    if (! m_init_called || changed_properties.empty()) return;
    JSValue changed = CreateChangedPropertiesObject(context_handle, changed_properties);
    JSValueConst argv[] = { changed };
    JSValue result = CallStoredExport(
        context_handle, m_exports_object_name.c_str(), "applyUserProperties", 1, argv);
    JS_FreeValue(context_handle, result);
    JS_FreeValue(context_handle, changed);
}

DynamicValueUniquePtr PropertyScriptProgram::Evaluate(const ScriptHostContext& host_context,
                                                      const DynamicValue&      current_value) {
    auto* context_handle = static_cast<JSContext*>(m_impl_context);
    if (! m_valid || context_handle == nullptr) return nullptr;

    UpdateHostContext(host_context);
    UpdateScriptProperties();
    ProcessScheduledCallbacks(context_handle);

    // Serialize only the payload; copying DynamicValue also copies its live subscriptions.
    const auto make_script_input = [&]() {
        if (m_semantic == PropertyScriptValueSemantic::AnglesDegrees &&
            current_value.getType() == DynamicValue::Vec3) {
            const auto angles = RadiansToDegrees(current_value.getVec3());
            return CreateJsVec3(context_handle, angles.x(), angles.y(), angles.z());
        }
        return DynamicValueToJS(context_handle, current_value);
    };

    if (! m_init_called) {
        JSValue      initial_value_js = make_script_input();
        JSValueConst init_argv[]      = { initial_value_js };
        JSValue      init_result =
            CallStoredExport(context_handle, m_exports_object_name.c_str(), "init", 1, init_argv);
        JS_FreeValue(context_handle, init_result);
        JS_FreeValue(context_handle, initial_value_js);
        if (m_runtime != nullptr) {
            JSValue changed_properties =
                CreateChangedPropertiesObject(context_handle, m_runtime->projectProperties());
            JSValueConst changed_argv[] = { changed_properties };
            JSValue      apply_result   = CallStoredExport(context_handle,
                                                    m_exports_object_name.c_str(),
                                                    "applyUserProperties",
                                                    1,
                                                    changed_argv);
            JS_FreeValue(context_handle, apply_result);
            JS_FreeValue(context_handle, changed_properties);
        }
        m_init_called = true;
    }

    if (! m_capabilities.update) return nullptr;

    JSValue      current_value_js = make_script_input();
    JSValueConst argv[]           = { current_value_js };
    JSValue      result =
        CallStoredExport(context_handle, m_exports_object_name.c_str(), "update", 1, argv);
    JS_FreeValue(context_handle, current_value_js);

    auto published = std::make_unique<DynamicValue>();
    if (JS_IsException(result) || JS_IsUndefined(result) ||
        (current_value.getType() == DynamicValue::Boolean &&
         JS_VALUE_GET_TAG(result) == JS_TAG_OBJECT)) {
        JS_FreeValue(context_handle, result);
        published->update(current_value);
        return published;
    }

    FillDynamicValueFromJS(context_handle, result, current_value.getType(), *published);
    if (m_semantic == PropertyScriptValueSemantic::AnglesDegrees &&
        published->getType() == DynamicValue::Vec3) {
        published->update(DegreesToRadians(published->getVec3()));
    }
    JS_FreeValue(context_handle, result);
    return published;
}

void PropertyScriptProgram::DispatchCursorClick(const ScriptHostContext& host_context) {
    if (! m_valid || !(m_capabilities.cursor_handlers & static_cast<uint8_t>(ScriptCursorEvent::Click))) return;
    auto* context_handle = static_cast<JSContext*>(m_impl_context);
    if (context_handle == nullptr) return;

    UpdateHostContext(host_context);
    JSValue      event_object = BuildCursorEventObject(context_handle, host_context);
    JSValueConst argv[]       = { event_object };
    JSValue      result =
        CallStoredExport(context_handle, m_exports_object_name.c_str(), "cursorClick", 1, argv);
    JS_FreeValue(context_handle, result);
    JS_FreeValue(context_handle, event_object);
}

void PropertyScriptProgram::DispatchCursorDown(const ScriptHostContext& host_context) {
    if (! m_valid || !(m_capabilities.cursor_handlers & static_cast<uint8_t>(ScriptCursorEvent::Down))) return;
    auto* context_handle = static_cast<JSContext*>(m_impl_context);
    if (context_handle == nullptr) return;

    UpdateHostContext(host_context);
    JSValue      event_object = BuildCursorEventObject(context_handle, host_context);
    JSValueConst argv[]       = { event_object };
    JSValue      result =
        CallStoredExport(context_handle, m_exports_object_name.c_str(), "cursorDown", 1, argv);
    JS_FreeValue(context_handle, result);
    JS_FreeValue(context_handle, event_object);
}

void PropertyScriptProgram::DispatchCursorEnter(const ScriptHostContext& host_context) {
    if (! m_valid || !(m_capabilities.cursor_handlers & static_cast<uint8_t>(ScriptCursorEvent::Enter))) return;
    auto* context_handle = static_cast<JSContext*>(m_impl_context);
    if (context_handle == nullptr) return;

    UpdateHostContext(host_context);
    JSValue      event_object = BuildCursorEventObject(context_handle, host_context);
    JSValueConst argv[]       = { event_object };
    JSValue      result =
        CallStoredExport(context_handle, m_exports_object_name.c_str(), "cursorEnter", 1, argv);
    JS_FreeValue(context_handle, result);
    JS_FreeValue(context_handle, event_object);
}

void PropertyScriptProgram::DispatchCursorLeave(const ScriptHostContext& host_context) {
    if (! m_valid || !(m_capabilities.cursor_handlers & static_cast<uint8_t>(ScriptCursorEvent::Leave))) return;
    auto* context_handle = static_cast<JSContext*>(m_impl_context);
    if (context_handle == nullptr) return;

    UpdateHostContext(host_context);
    JSValue      event_object = BuildCursorEventObject(context_handle, host_context);
    JSValueConst argv[]       = { event_object };
    JSValue      result =
        CallStoredExport(context_handle, m_exports_object_name.c_str(), "cursorLeave", 1, argv);
    JS_FreeValue(context_handle, result);
    JS_FreeValue(context_handle, event_object);
}

void PropertyScriptProgram::DispatchCursorMove(const ScriptHostContext& host_context) {
    if (! m_valid || !(m_capabilities.cursor_handlers & static_cast<uint8_t>(ScriptCursorEvent::Move))) return;
    auto* context_handle = static_cast<JSContext*>(m_impl_context);
    if (context_handle == nullptr) return;

    UpdateHostContext(host_context);
    JSValue      event_object = BuildCursorEventObject(context_handle, host_context);
    JSValueConst argv[]       = { event_object };
    JSValue      result =
        CallStoredExport(context_handle, m_exports_object_name.c_str(), "cursorMove", 1, argv);
    JS_FreeValue(context_handle, result);
    JS_FreeValue(context_handle, event_object);
}

void PropertyScriptProgram::DispatchCursorUp(const ScriptHostContext& host_context) {
    if (! m_valid || !(m_capabilities.cursor_handlers & static_cast<uint8_t>(ScriptCursorEvent::Up))) return;
    auto* context_handle = static_cast<JSContext*>(m_impl_context);
    if (context_handle == nullptr) return;

    UpdateHostContext(host_context);
    JSValue      event_object = BuildCursorEventObject(context_handle, host_context);
    JSValueConst argv[]       = { event_object };
    JSValue      result =
        CallStoredExport(context_handle, m_exports_object_name.c_str(), "cursorUp", 1, argv);
    JS_FreeValue(context_handle, result);
    JS_FreeValue(context_handle, event_object);
}

void PropertyScriptProgram::DispatchAnimationEvent(const ScriptHostContext& host_context,
                                                   std::string_view event_name, double frame) {
    if (! m_valid || ! m_capabilities.animation_event) return;
    auto* context_handle = static_cast<JSContext*>(m_impl_context);
    if (context_handle == nullptr) return;

    UpdateHostContext(host_context);
    JSValue      event_object = BuildAnimationEventObject(context_handle, event_name, frame);
    JSValueConst argv[]       = { event_object };
    JSValue      result =
        CallStoredExport(context_handle, m_exports_object_name.c_str(), "animationEvent", 1, argv);
    JS_FreeValue(context_handle, result);
    JS_FreeValue(context_handle, event_object);
}

void PropertyScriptProgram::DispatchMediaThumbnailChanged(const Eigen::Vector3f& primary_color,
                                                          const Eigen::Vector3f& text_color) {
    if (! m_valid) return;
    auto* context_handle = static_cast<JSContext*>(m_impl_context);
    if (context_handle == nullptr) return;

    JSValue event_object = JS_NewObject(context_handle);
    JS_SetPropertyStr(
        context_handle,
        event_object,
        "primaryColor",
        CreateJsVec3(context_handle, primary_color.x(), primary_color.y(), primary_color.z()));
    JS_SetPropertyStr(context_handle,
                      event_object,
                      "textColor",
                      CreateJsVec3(context_handle, text_color.x(), text_color.y(), text_color.z()));
    JS_SetPropertyStr(
        context_handle, event_object, "hasThumbnail", JS_NewBool(context_handle, true));

    JSValueConst argv[] = { event_object };
    JSValue      result = CallStoredExport(
        context_handle, m_exports_object_name.c_str(), "mediaThumbnailChanged", 1, argv);
    JS_FreeValue(context_handle, result);
    JS_FreeValue(context_handle, event_object);
}

void PropertyScriptProgram::DispatchMediaEventJson(std::string_view event_json) {
    if (! m_valid) return;
    auto* context_handle = static_cast<JSContext*>(m_impl_context);
    if (context_handle == nullptr) return;

    DispatchMediaEventJsonToScript(context_handle, m_exports_object_name, event_json, false);
}

SceneScriptProgram::SceneScriptProgram(SceneRuntimeContext& runtime, std::string script_source,
                                       std::string       current_layer_name,
                                       ProjectProperties project_properties,
                                       ScriptHostContext host_context, JSRuntime* shared_runtime,
                                       JSContext* shared_context, std::string exports_object_name)
    : m_runtime(&runtime),
      m_script_source(std::move(script_source)),
      m_current_layer_name(std::move(current_layer_name)),
      m_project_properties(std::move(project_properties)),
      m_exports_object_name(std::move(exports_object_name)) {
    auto* runtime_handle = shared_runtime;
    if (runtime_handle == nullptr) {
        LOG_ERROR("SceneScriptProgram: failed to create JS runtime");
        return;
    }

    auto* context_handle = shared_context;
    if (context_handle == nullptr) {
        LOG_ERROR("SceneScriptProgram: failed to create JS context");
        return;
    }

    m_impl_runtime = runtime_handle;
    m_impl_context = context_handle;
    m_owns_context = false;

    if (! EnsureSharedHostBindings(context_handle, &runtime, host_context, &m_project_properties)) {
        return;
    }

    JSValue global_object = JS_GetGlobalObject(context_handle);
    JSValue factory =
        AcquireScriptFactory(context_handle, m_script_source, ScriptProgramMode::Scene);
    if (JS_IsException(factory)) {
        JS_FreeValue(context_handle, global_object);
        return;
    }

    if (! ExecuteScriptFactory(context_handle,
                               factory,
                               m_exports_object_name,
                               m_current_layer_name,
                               {},
                               "SceneScriptProgram")) {
        JS_FreeValue(context_handle, factory);
        JS_FreeValue(context_handle, global_object);
        return;
    }
    JS_FreeValue(context_handle, factory);
    JS_FreeValue(context_handle, global_object);

    m_capabilities = ReadCompiledCapabilities(context_handle, m_exports_object_name.c_str());
    UpdateHostContext(host_context);
    JSValue init_result =
        CallStoredExport(context_handle, m_exports_object_name.c_str(), "init", 0, nullptr);
    JS_FreeValue(context_handle, init_result);
    ApplyUserProperties(m_project_properties);
    RunSceneCallbacks(context_handle, "load");
    m_valid = true;
}

SceneScriptProgram::~SceneScriptProgram() {
    auto* context_handle = static_cast<JSContext*>(m_impl_context);
    auto* runtime_handle = static_cast<JSRuntime*>(m_impl_runtime);
    if (m_owns_context && context_handle != nullptr) {
        auto* bridge_state =
            static_cast<SceneScriptBridgeState*>(JS_GetContextOpaque(context_handle));
        delete bridge_state;
        JS_FreeContext(context_handle);
    }
    if (m_owns_context && runtime_handle != nullptr) JS_FreeRuntime(runtime_handle);
}

bool SceneScriptProgram::Valid() const { return m_valid; }

void SceneScriptProgram::UpdateHostContext(const ScriptHostContext& host_context) {
    auto* context_handle = static_cast<JSContext*>(m_impl_context);
    if (context_handle == nullptr) return;

    JSValue global_object = JS_GetGlobalObject(context_handle);
    UpdateEngineObject(context_handle, global_object, host_context);
    JS_FreeValue(context_handle, global_object);
}

void SceneScriptProgram::ApplyUserProperties(const ProjectProperties& property_changes) {
    auto* context_handle = static_cast<JSContext*>(m_impl_context);
    if (context_handle == nullptr) return;

    JSValue global_object = JS_GetGlobalObject(context_handle);
    JS_SetPropertyStr(context_handle,
                      global_object,
                      "__sceneProps",
                      CreateScenePropertiesObject(context_handle, m_project_properties));
    SetEngineUserProperties(context_handle, global_object, m_project_properties);

    JSValue changed_properties = CreateChangedPropertiesObject(context_handle, property_changes);
    JSValueConst argv[]        = { changed_properties };
    JSValue      result        = CallStoredExport(
        context_handle, m_exports_object_name.c_str(), "applyUserProperties", 1, argv);
    JS_FreeValue(context_handle, result);
    JS_FreeValue(context_handle, changed_properties);
    JS_FreeValue(context_handle, global_object);
}

void SceneScriptProgram::ApplyProjectProperties(const ProjectProperties& project_properties,
                                                const ProjectProperties& changed_properties) {
    m_project_properties = project_properties;
    if (changed_properties.empty()) return;
    ApplyUserProperties(changed_properties);
}

void SceneScriptProgram::Tick(const ScriptHostContext& host_context) {
    if (! m_valid) return;
    auto* context_handle = static_cast<JSContext*>(m_impl_context);
    if (context_handle == nullptr) return;

    UpdateHostContext(host_context);
    ProcessScheduledCallbacks(context_handle);
    if (m_capabilities.update) {
        JSValue result =
            CallStoredExport(context_handle, m_exports_object_name.c_str(), "update", 0, nullptr);
        JS_FreeValue(context_handle, result);
    }
    RunSceneCallbacks(context_handle, "update");
}

void SceneScriptProgram::DispatchCursorClick(const ScriptHostContext& host_context) {
    if (! m_valid) return;
    auto* context_handle = static_cast<JSContext*>(m_impl_context);
    if (context_handle == nullptr) return;

    UpdateHostContext(host_context);
    JSValue      event_object = BuildCursorEventObject(context_handle, host_context);
    JSValueConst argv[]       = { event_object };
    JSValue      result =
        CallStoredExport(context_handle, m_exports_object_name.c_str(), "cursorClick", 1, argv);
    JS_FreeValue(context_handle, result);
    RunSceneCallbacks(context_handle, "cursorClick", event_object);
    JS_FreeValue(context_handle, event_object);
}

void SceneScriptProgram::DispatchCursorDown(const ScriptHostContext& host_context) {
    if (! m_valid) return;
    auto* context_handle = static_cast<JSContext*>(m_impl_context);
    if (context_handle == nullptr) return;

    UpdateHostContext(host_context);
    JSValue      event_object = BuildCursorEventObject(context_handle, host_context);
    JSValueConst argv[]       = { event_object };
    JSValue      result =
        CallStoredExport(context_handle, m_exports_object_name.c_str(), "cursorDown", 1, argv);
    JS_FreeValue(context_handle, result);
    RunSceneCallbacks(context_handle, "cursorDown", event_object);
    JS_FreeValue(context_handle, event_object);
}

void SceneScriptProgram::DispatchCursorEnter(const ScriptHostContext& host_context) {
    if (! m_valid) return;
    auto* context_handle = static_cast<JSContext*>(m_impl_context);
    if (context_handle == nullptr) return;

    UpdateHostContext(host_context);
    JSValue      event_object = BuildCursorEventObject(context_handle, host_context);
    JSValueConst argv[]       = { event_object };
    JSValue      result =
        CallStoredExport(context_handle, m_exports_object_name.c_str(), "cursorEnter", 1, argv);
    JS_FreeValue(context_handle, result);
    RunSceneCallbacks(context_handle, "cursorEnter", event_object);
    JS_FreeValue(context_handle, event_object);
}

void SceneScriptProgram::DispatchCursorLeave(const ScriptHostContext& host_context) {
    if (! m_valid) return;
    auto* context_handle = static_cast<JSContext*>(m_impl_context);
    if (context_handle == nullptr) return;

    UpdateHostContext(host_context);
    JSValue      event_object = BuildCursorEventObject(context_handle, host_context);
    JSValueConst argv[]       = { event_object };
    JSValue      result =
        CallStoredExport(context_handle, m_exports_object_name.c_str(), "cursorLeave", 1, argv);
    JS_FreeValue(context_handle, result);
    RunSceneCallbacks(context_handle, "cursorLeave", event_object);
    JS_FreeValue(context_handle, event_object);
}

void SceneScriptProgram::DispatchCursorMove(const ScriptHostContext& host_context) {
    if (! m_valid) return;
    auto* context_handle = static_cast<JSContext*>(m_impl_context);
    if (context_handle == nullptr) return;

    UpdateHostContext(host_context);
    JSValue      event_object = BuildCursorEventObject(context_handle, host_context);
    JSValueConst argv[]       = { event_object };
    JSValue      result =
        CallStoredExport(context_handle, m_exports_object_name.c_str(), "cursorMove", 1, argv);
    JS_FreeValue(context_handle, result);
    RunSceneCallbacks(context_handle, "cursorMove", event_object);
    JS_FreeValue(context_handle, event_object);
}

void SceneScriptProgram::DispatchCursorUp(const ScriptHostContext& host_context) {
    if (! m_valid) return;
    auto* context_handle = static_cast<JSContext*>(m_impl_context);
    if (context_handle == nullptr) return;

    UpdateHostContext(host_context);
    JSValue      event_object = BuildCursorEventObject(context_handle, host_context);
    JSValueConst argv[]       = { event_object };
    JSValue      result =
        CallStoredExport(context_handle, m_exports_object_name.c_str(), "cursorUp", 1, argv);
    JS_FreeValue(context_handle, result);
    RunSceneCallbacks(context_handle, "cursorUp", event_object);
    JS_FreeValue(context_handle, event_object);
}

void SceneScriptProgram::DispatchAnimationEvent(const ScriptHostContext& host_context,
                                                std::string_view event_name, double frame) {
    if (! m_valid || ! m_capabilities.animation_event) return;
    auto* context_handle = static_cast<JSContext*>(m_impl_context);
    if (context_handle == nullptr) return;

    // The global callback list is shared by every program on this context, so
    // the runtime runs it once per event instead of once per scene script.
    UpdateHostContext(host_context);
    JSValue      event_object = BuildAnimationEventObject(context_handle, event_name, frame);
    JSValueConst argv[]       = { event_object };
    JSValue      result =
        CallStoredExport(context_handle, m_exports_object_name.c_str(), "animationEvent", 1, argv);
    JS_FreeValue(context_handle, result);
    JS_FreeValue(context_handle, event_object);
}

void SceneScriptProgram::DispatchMediaThumbnailChanged(const Eigen::Vector3f& primary_color,
                                                       const Eigen::Vector3f& text_color) {
    if (! m_valid) return;
    auto* context_handle = static_cast<JSContext*>(m_impl_context);
    if (context_handle == nullptr) return;

    JSValue event_object = JS_NewObject(context_handle);
    JS_SetPropertyStr(
        context_handle,
        event_object,
        "primaryColor",
        CreateJsVec3(context_handle, primary_color.x(), primary_color.y(), primary_color.z()));
    JS_SetPropertyStr(context_handle,
                      event_object,
                      "textColor",
                      CreateJsVec3(context_handle, text_color.x(), text_color.y(), text_color.z()));
    JS_SetPropertyStr(
        context_handle, event_object, "hasThumbnail", JS_NewBool(context_handle, true));

    JSValueConst argv[] = { event_object };
    JSValue      result = CallStoredExport(
        context_handle, m_exports_object_name.c_str(), "mediaThumbnailChanged", 1, argv);
    JS_FreeValue(context_handle, result);
    RunSceneCallbacks(context_handle, "mediaThumbnailChanged", event_object);
    JS_FreeValue(context_handle, event_object);
}

void SceneScriptProgram::DispatchMediaEventJson(std::string_view event_json) {
    if (! m_valid) return;
    auto* context_handle = static_cast<JSContext*>(m_impl_context);
    if (context_handle == nullptr) return;

    DispatchMediaEventJsonToScript(context_handle, m_exports_object_name, event_json, true);
}

ScriptEngine::ScriptEngine() {
    m_runtime = JS_NewRuntime();
    if (m_runtime == nullptr) {
        LOG_ERROR("ScriptEngine: failed to create JS runtime");
        return;
    }

    m_context = JS_NewContext(m_runtime);
    if (m_context == nullptr) {
        LOG_ERROR("ScriptEngine: failed to create JS context");
        JS_FreeRuntime(m_runtime);
        m_runtime = nullptr;
    }
}

ScriptEngine::~ScriptEngine() {
    if (m_context != nullptr) {
        ReleaseContextScriptCache(m_context);
    }
    if (m_context != nullptr) {
        auto* bridge_state = static_cast<SceneScriptBridgeState*>(JS_GetContextOpaque(m_context));
        delete bridge_state;
        JS_SetContextOpaque(m_context, nullptr);
        JS_FreeContext(m_context);
    }
    if (m_runtime != nullptr) JS_FreeRuntime(m_runtime);
}

void ScriptEngine::ResetStartupMetrics() { g_script_startup_metrics = {}; }

ScriptStartupMetrics ScriptEngine::GetStartupMetrics() { return g_script_startup_metrics; }

DynamicValueUniquePtr
ScriptEngine::Evaluate(const std::string&                          script_source,
                       const std::map<std::string, DynamicValue*>& script_properties,
                       const DynamicValue& current_value, const ScriptHostContext& host_context) {
    auto program = CreatePropertyScriptProgram(
        nullptr, script_source, "", script_properties, current_value, host_context);
    if (program == nullptr || ! program->Valid()) {
        auto fallback = std::make_unique<DynamicValue>();
        fallback->update(current_value);
        return fallback;
    }

    auto result = program->Evaluate(host_context, current_value);
    if (! program->Capabilities().update) {
        auto fallback = std::make_unique<DynamicValue>();
        fallback->update(current_value);
        return fallback;
    }
    return result;
}

std::unique_ptr<PropertyScriptProgram> ScriptEngine::CreatePropertyScriptProgram(
    SceneRuntimeContext* runtime, std::string script_source, std::string current_layer_name,
    std::map<std::string, DynamicValue*> script_properties, DynamicValue initial_value,
    ScriptHostContext host_context, PropertyScriptValueSemantic semantic) {
    if (m_context == nullptr || m_runtime == nullptr) return nullptr;
    const auto program_id = ++m_next_program_id;
    auto       program =
        std::make_unique<PropertyScriptProgram>(runtime,
                                                std::move(script_source),
                                                std::move(current_layer_name),
                                                std::move(script_properties),
                                                std::move(initial_value),
                                                host_context,
                                                m_runtime,
                                                m_context,
                                                "__propertyExports_" + std::to_string(program_id),
                                                "__scriptProps_" + std::to_string(program_id),
                                                semantic);
    if (! program->Valid()) return nullptr;
    return program;
}

std::unique_ptr<SceneScriptProgram> ScriptEngine::CreateSceneScriptProgram(
    SceneRuntimeContext& runtime, std::string script_source, std::string current_layer_name,
    ProjectProperties project_properties, ScriptHostContext host_context) {
    if (m_context == nullptr || m_runtime == nullptr) return nullptr;
    const auto program_id = ++m_next_program_id;
    auto       program =
        std::make_unique<SceneScriptProgram>(runtime,
                                             std::move(script_source),
                                             std::move(current_layer_name),
                                             std::move(project_properties),
                                             host_context,
                                             m_runtime,
                                             m_context,
                                             "__sceneExports_" + std::to_string(program_id));
    if (! program->Valid()) return nullptr;
    return program;
}

void ScriptEngine::RunAnimationEventCallbacks(const ScriptHostContext& host_context,
                                              std::string_view event_name, double frame) {
    if (m_context == nullptr) return;
    // A global listener can be the only consumer of a marker, so `engine` is
    // refreshed here instead of relying on a program having run this tick.
    JSValue global_object = JS_GetGlobalObject(m_context);
    UpdateEngineObject(m_context, global_object, host_context);
    JS_FreeValue(m_context, global_object);
    JSValue event_object = BuildAnimationEventObject(m_context, event_name, frame);
    RunSceneCallbacks(m_context, "animationEvent", event_object);
    JS_FreeValue(m_context, event_object);
}

} // namespace wallpaper
