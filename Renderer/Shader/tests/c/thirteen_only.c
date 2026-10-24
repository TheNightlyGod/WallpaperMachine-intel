/* This project's own code, written from the clean-room specification (no upstream code consulted).
 *
 * A caller that declares only the thirteen functions of the contract itself, as the engine's own
 * declarations do, and no header of this project. It must link against the static library and
 * compile a plain textured quad (amendment a-contract R111). It declares nothing else: a caller
 * that still needed an accessor for SPIR-V words would fail to link here. Run by tests/c_abi.rs. */
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef struct RsShaderProgram RsShaderProgram;
typedef struct RsShaderOwnedBytes {
    uint8_t* ptr;
    size_t len;
    void (*free)(uint8_t*, size_t, void*);
    void* free_user_data;
} RsShaderOwnedBytes;
typedef RsShaderOwnedBytes (*RsShaderIncludeCallback)(const char*, void*);

int rs_shader_compile_program(const char*, RsShaderIncludeCallback, void*, RsShaderProgram**);
size_t rs_shader_program_stage_count(const RsShaderProgram*);
int rs_shader_program_stage_kind(const RsShaderProgram*, size_t);
int rs_shader_program_stage_target(const RsShaderProgram*, size_t);
const char* rs_shader_program_stage_msl_source(const RsShaderProgram*, size_t);
const char* rs_shader_program_stage_metal_json(const RsShaderProgram*, size_t);
const char* rs_shader_program_metadata_json(const RsShaderProgram*);
const char* rs_shader_program_reflection_json(const RsShaderProgram*);
const char* rs_shader_program_diagnostics_json(const RsShaderProgram*);
const char* rs_shader_program_cache_key(const RsShaderProgram*);
void rs_shader_program_free(RsShaderProgram*);
const char* rs_shader_last_error(void);
const char* rs_shader_cache_identity(void);

static const char* const quad =
    "{\"shader_name\":\"thirteen/quad\",\"textures\":[{\"slot\":0,\"enabled\":true}],\"stages\":["
    "{\"kind\":\"vertex\",\"source\":\"attribute vec3 a_Position; attribute vec2 a_TexCoord; varying vec2 v_TexCoord;"
    " uniform mat4 g_ModelViewProjectionMatrix;"
    " void main() { gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix); v_TexCoord = a_TexCoord; }\"},"
    "{\"kind\":\"fragment\",\"source\":\"varying vec2 v_TexCoord; uniform sampler2D g_Texture0;"
    " void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord); }\"}]}";

static int fail(const char* what) {
    fprintf(stderr, "failed: %s (%s)\n", what, rs_shader_last_error());
    return 1;
}

int main(void) {
    RsShaderProgram* program = NULL;
    if (rs_shader_compile_program(quad, NULL, NULL, &program) != 0 || program == NULL) return fail("compile");
    if (rs_shader_program_stage_count(program) != 2) return fail("stage count");
    for (size_t i = 0; i < 2; i++) {
        if (rs_shader_program_stage_target(program, i) != 1) return fail("target is Metal");
        if (strstr(rs_shader_program_stage_msl_source(program, i), "metal_stdlib") == NULL) return fail("msl");
    }
    if (strstr(rs_shader_program_reflection_json(program), "g_Texture0") == NULL) return fail("reflection");
    if (strstr(rs_shader_program_metadata_json(program), "\"active_texture_slots\":[0]") == NULL) return fail("slots");
    if (strstr(rs_shader_program_stage_metal_json(program, 1), "\"slot\":") == NULL) return fail("slot records");
    if (strlen(rs_shader_program_diagnostics_json(program)) < 3) return fail("diagnostics");
    if (strlen(rs_shader_program_cache_key(program)) == 0 || strlen(rs_shader_cache_identity()) == 0) return fail("keys");
    rs_shader_program_free(program);
    printf("thirteen ok\n");
    return 0;
}
