/* This project's own code, written from the clean-room specification (no upstream code consulted).
 *
 * C interface of the shader layer: Wallpaper Engine shader text in, Metal Shading Language and
 * reflection out. The functions are exported unmangled by the static library built from the
 * `wm-shader` crate with the `ffi` feature (target/<profile>/libwm_shader.a).
 *
 * Ownership:
 *  - Every `const char*` an accessor returns is borrowed: NUL-terminated, owned by the program
 *    handle, identical across repeated calls, and valid until rs_shader_program_free().
 *    rs_shader_cache_identity() is valid for the life of the process.
 *    rs_shader_last_error() is valid until the calling thread's next
 *    rs_shader_compile_program().
 *  - A handle is immutable once returned. Accessors may run concurrently from any thread, and
 *    any thread may free a handle.
 *
 * Threading: rs_shader_compile_program() is reentrant and thread-safe for independent inputs.
 * The include callback runs on the calling thread, only during that call.
 *
 * No panic or exception crosses this interface. The callback must not throw or longjmp.
 */
#ifndef RS_SHADER_H
#define RS_SHADER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Status of rs_shader_compile_program(). */
#define RS_SHADER_OK 0
#define RS_SHADER_ERROR 1

/* Stage kinds; RS_SHADER_INVALID is returned for a null handle or a bad index. */
#define RS_SHADER_STAGE_VERTEX 0
#define RS_SHADER_STAGE_FRAGMENT 1
#define RS_SHADER_INVALID (-1)

/* Stage targets. Metal is the only one. The value 0 was the Vulkan-style target of an earlier
 * library. The value 0 is retired: never returned, never given another meaning. A caller that
 * still compares a stage target with 0 reads "retired"; 1 reads "Metal". The request key
 * "target" accepts "metal_msl" or no key at all; any other string is refused (status 1). */
#define RS_SHADER_TARGET_METAL 1

/* A compiled program. Declared incomplete: never dereferenced by callers. */
typedef struct RsShaderProgram RsShaderProgram;

/* Bytes an include provider hands over, returned by value.
 *  - ptr == NULL, len == 0: no such include.
 *  - ptr == NULL, len != 0: provider fault (an error).
 *  - ptr != NULL, len == 0: a legitimately empty include.
 * When both free and ptr are non-null the layer copies the bytes, then calls
 * free(ptr, len, free_user_data) exactly once (also when the bytes are not valid UTF-8). It
 * never keeps a pointer into the buffer after that. */
typedef struct RsShaderOwnedBytes {
    uint8_t* ptr;
    size_t len;
    void (*free)(uint8_t* ptr, size_t len, void* free_user_data); /* nullable */
    void* free_user_data;
} RsShaderOwnedBytes;

/* Reads an include. `path` is the text of the directive with backslashes turned into forward
 * slashes, not resolved against the including file. */
typedef RsShaderOwnedBytes (*RsShaderIncludeCallback)(const char* path, void* user_data);

/* Compiles one program from a request JSON document (NUL-terminated UTF-8).
 * Returns RS_SHADER_OK and writes a handle to *out_program, or returns RS_SHADER_ERROR, writes
 * NULL to *out_program (when out_program is non-null) and leaves the reason in
 * rs_shader_last_error(). `cb` may be NULL: every include that is reached then fails as not
 * found. */
int rs_shader_compile_program(const char* request_json, RsShaderIncludeCallback cb,
                              void* cb_user_data, RsShaderProgram** out_program);

/* Number of stages (2 on success); 0 for a null handle. */
size_t rs_shader_program_stage_count(const RsShaderProgram* program);
/* RS_SHADER_STAGE_VERTEX or RS_SHADER_STAGE_FRAGMENT; RS_SHADER_INVALID for null or a bad index.
 * Stage i is the stage at position i of the request's `stages` array. */
int rs_shader_program_stage_kind(const RsShaderProgram* program, size_t i);
/* RS_SHADER_TARGET_METAL (1) for every valid index; RS_SHADER_INVALID for null or a bad index.
 * Never 0 (retired, see above). There is no accessor for SPIR-V words: the layer compiles
 * for Metal alone and the library exports exactly the thirteen functions of this header. */
int rs_shader_program_stage_target(const RsShaderProgram* program, size_t i);
/* Metal source text of the stage; "" for null or a bad index. */
const char* rs_shader_program_stage_msl_source(const RsShaderProgram* program, size_t i);
/* Per-stage payload JSON (entry_point, language_version, bindings, conventions);
 * "{}" for null or a bad index. A binding record's `slot` is its Metal argument-table slot,
 * numbered per stage and per kind (buffers, textures, samplers each from 0); it normally
 * differs from `binding`, and a caller finds a resource by name and copies the `slot`. */
const char* rs_shader_program_stage_metal_json(const RsShaderProgram* program, size_t i);
/* Metadata JSON (combos, aliases, default_uniforms, default_textures, active_texture_slots);
 * "{}" for null. */
const char* rs_shader_program_metadata_json(const RsShaderProgram* program);
/* Reflection JSON (descriptor_bindings, uniform_blocks, vertex_inputs, active_texture_slots);
 * "{}" for null. */
const char* rs_shader_program_reflection_json(const RsShaderProgram* program);
/* Diagnostics JSON array; "[]" for null. */
const char* rs_shader_program_diagnostics_json(const RsShaderProgram* program);
/* Filename-safe cache key of the program; "" for null. */
const char* rs_shader_program_cache_key(const RsShaderProgram* program);
/* Releases a handle. Null is a no-op. */
void rs_shader_program_free(RsShaderProgram* program);

/* Human-readable text of the calling thread's last compile: "no shader error" before any
 * compile and after a successful one. */
const char* rs_shader_last_error(void);
/* Compiler identity for persistent caches. Valid for the life of the process. */
const char* rs_shader_cache_identity(void);

#ifdef __cplusplus
}
#endif

#endif /* RS_SHADER_H */
