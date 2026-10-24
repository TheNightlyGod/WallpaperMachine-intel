/* This project's own code, written from the clean-room specification (no upstream code consulted).
 *
 * A C caller of the shader layer, built against include/rs_shader.h and linked with the static
 * library, run by tests/c_abi.rs. It checks what the header promises: status codes, null-handle
 * values, the include callback with its free routine, last-error text, borrowed pointers. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "rs_shader.h"

static int failures = 0;

#define CHECK(cond)                                                                   \
    do {                                                                              \
        if (!(cond)) {                                                                \
            fprintf(stderr, "check failed at line %d: %s\n", __LINE__, #cond);        \
            failures++;                                                               \
        }                                                                             \
    } while (0)

typedef struct Provider {
    int calls;
    int frees;
    char last_path[128];
} Provider;

static void release(uint8_t* ptr, size_t len, void* user_data) {
    Provider* provider = (Provider*)user_data;
    provider->frees++;
    memset(ptr, 0xFF, len); /* poison: the layer must have copied the bytes already */
    free(ptr);
}

static RsShaderOwnedBytes read_include(const char* path, void* user_data) {
    Provider* provider = (Provider*)user_data;
    RsShaderOwnedBytes none = {NULL, 0, NULL, NULL};
    provider->calls++;
    strncpy(provider->last_path, path, sizeof provider->last_path - 1);
    if (strcmp(path, "common/color.h") != 0) {
        return none;
    }
    const char* text = "#define MY_COLOR vec4(0.125, 0.5, 0.75, 1.0)\n";
    size_t len = strlen(text);
    uint8_t* copy = (uint8_t*)malloc(len);
    memcpy(copy, text, len);
    RsShaderOwnedBytes owned = {copy, len, release, user_data};
    return owned;
}

static const char* const request_plain =
    "{\"shader_name\":\"c\\\\smoke\",\"stages\":["
    "{\"kind\":\"vertex\",\"source\":\"attribute vec3 a_Position; void main() { gl_Position = vec4(a_Position, 1.0); }\"},"
    "{\"kind\":\"fragment\",\"source\":\"void main() { gl_FragColor = vec4(0.25, 0.5, 0.75, 1.0); }\"}]}";

static const char* const request_include =
    "{\"shader_name\":\"c/include\",\"future_key\":[1,2],\"stages\":["
    "{\"kind\":\"fragment\",\"source\":\"#include \\\"common\\\\color.h\\\"\\nvoid main() { gl_FragColor = MY_COLOR; }\"},"
    "{\"kind\":\"vertex\",\"source\":\"attribute vec3 a_Position; void main() { gl_Position = vec4(a_Position, 1.0); }\"}]}";

int main(void) {
    RsShaderProgram* program = NULL;

    /* The constants are the contract. */
    CHECK(RS_SHADER_OK == 0 && RS_SHADER_ERROR == 1);
    CHECK(RS_SHADER_STAGE_VERTEX == 0 && RS_SHADER_STAGE_FRAGMENT == 1 && RS_SHADER_INVALID == -1);
    CHECK(RS_SHADER_TARGET_METAL == 1);

    /* Before any compile on this thread. */
    CHECK(strcmp(rs_shader_last_error(), "no shader error") == 0);
    CHECK(strlen(rs_shader_cache_identity()) > 0);
    CHECK(rs_shader_cache_identity() == rs_shader_cache_identity());

    /* A plain compile, no callback. */
    CHECK(rs_shader_compile_program(request_plain, NULL, NULL, &program) == RS_SHADER_OK);
    CHECK(program != NULL);
    CHECK(rs_shader_program_stage_count(program) == 2);
    CHECK(rs_shader_program_stage_kind(program, 0) == RS_SHADER_STAGE_VERTEX);
    CHECK(rs_shader_program_stage_kind(program, 1) == RS_SHADER_STAGE_FRAGMENT);
    CHECK(rs_shader_program_stage_target(program, 1) == RS_SHADER_TARGET_METAL);
    CHECK(strstr(rs_shader_program_stage_msl_source(program, 0), "#include <metal_stdlib>") != NULL);
    CHECK(strstr(rs_shader_program_stage_metal_json(program, 1), "\"entry_point\":\"") != NULL);
    CHECK(strstr(rs_shader_program_metadata_json(program), "\"active_texture_slots\":[]") != NULL);
    CHECK(strstr(rs_shader_program_reflection_json(program), "\"vertex_inputs\":[") != NULL);
    CHECK(strstr(rs_shader_program_diagnostics_json(program), "\"Codegen\"") != NULL);
    CHECK(strlen(rs_shader_program_cache_key(program)) > 0);
    CHECK(strcmp(rs_shader_last_error(), "no shader error") == 0);
    CHECK(rs_shader_program_stage_msl_source(program, 0) == rs_shader_program_stage_msl_source(program, 0));

    /* Out-of-range and null values. */
    CHECK(rs_shader_program_stage_kind(program, 2) == RS_SHADER_INVALID);
    CHECK(rs_shader_program_stage_target(program, (size_t)-1) == RS_SHADER_INVALID);
    CHECK(strcmp(rs_shader_program_stage_msl_source(program, 9), "") == 0);
    CHECK(strcmp(rs_shader_program_stage_metal_json(NULL, 0), "{}") == 0);
    CHECK(rs_shader_program_stage_count(NULL) == 0);
    CHECK(rs_shader_program_stage_kind(NULL, 0) == RS_SHADER_INVALID);
    CHECK(strcmp(rs_shader_program_metadata_json(NULL), "{}") == 0);
    CHECK(strcmp(rs_shader_program_reflection_json(NULL), "{}") == 0);
    CHECK(strcmp(rs_shader_program_diagnostics_json(NULL), "[]") == 0);
    CHECK(strcmp(rs_shader_program_cache_key(NULL), "") == 0);
    rs_shader_program_free(NULL);
    rs_shader_program_free(program);

    /* The include callback: stage order follows the request, the buffer is freed once. */
    Provider provider;
    memset(&provider, 0, sizeof provider);
    program = NULL;
    CHECK(rs_shader_compile_program(request_include, read_include, &provider, &program) == RS_SHADER_OK);
    CHECK(program != NULL);
    CHECK(provider.calls == 1 && provider.frees == 1);
    CHECK(strcmp(provider.last_path, "common/color.h") == 0);
    CHECK(rs_shader_program_stage_kind(program, 0) == RS_SHADER_STAGE_FRAGMENT);
    CHECK(strstr(rs_shader_program_stage_msl_source(program, 0), "0.125") != NULL);
    rs_shader_program_free(program);

    /* A failure: null handle, text in the last error, replaced by the next success. */
    program = (RsShaderProgram*)0x1;
    CHECK(rs_shader_compile_program("{not json", NULL, NULL, &program) == RS_SHADER_ERROR);
    CHECK(program == NULL);
    CHECK(strstr(rs_shader_last_error(), "json") != NULL);
    CHECK(rs_shader_compile_program(NULL, NULL, NULL, &program) == RS_SHADER_ERROR);
    CHECK(strstr(rs_shader_last_error(), "request pointer") != NULL);
    CHECK(rs_shader_compile_program(request_plain, NULL, NULL, NULL) == RS_SHADER_ERROR);
    CHECK(strstr(rs_shader_last_error(), "out program pointer") != NULL);

    /* A missing include without a callback fails naming the path. */
    CHECK(rs_shader_compile_program(request_include, NULL, NULL, &program) == RS_SHADER_ERROR);
    CHECK(strstr(rs_shader_last_error(), "common/color.h") != NULL);
    CHECK(program == NULL);

    CHECK(rs_shader_compile_program(request_plain, NULL, NULL, &program) == RS_SHADER_OK);
    CHECK(strcmp(rs_shader_last_error(), "no shader error") == 0);
    rs_shader_program_free(program);

    if (failures != 0) {
        fprintf(stderr, "%d checks failed\n", failures);
        return 1;
    }
    printf("c abi ok\n");
    return 0;
}
