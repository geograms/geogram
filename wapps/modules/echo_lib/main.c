/*
 * echo_lib — Geogram WASM Library Example
 *
 * Demonstrates the library module pattern: exports module_type(),
 * module_api_schema(), and module_invoke() instead of tick/event.
 *
 * Functions:
 *   echo  — returns its input unchanged
 *   upcase — returns input text uppercased
 *
 * Build: cd wapps/modules/echo_lib && make
 */

#include "../../hal/geogram_wasm_hal.h"

/* ── String helpers ─────────────────────────────────────────────────── */

static unsigned str_len(const char *s) {
    unsigned n = 0;
    while (s[n]) n++;
    return n;
}

static void mem_copy(char *dst, const char *src, unsigned n) {
    for (unsigned i = 0; i < n; i++) dst[i] = src[i];
}

static int str_eq(const char *a, unsigned a_len, const char *b, unsigned b_len) {
    if (a_len != b_len) return 0;
    for (unsigned i = 0; i < a_len; i++) {
        if (a[i] != b[i]) return 0;
    }
    return 1;
}

static char to_upper(char c) {
    return (c >= 'a' && c <= 'z') ? (char)(c - 32) : c;
}

/* ── API schema (static JSON) ──────────────────────────────────────── */

static const char SCHEMA[] =
    "{"
    "\"id\":\"radio.geogram.echo-lib\","
    "\"version\":\"1.0.0\","
    "\"description\":\"Echo library — demonstrates WASM library pattern\","
    "\"functions\":["
    "{"
    "\"name\":\"echo\","
    "\"description\":\"Returns the input text unchanged\","
    "\"params\":{\"text\":{\"type\":\"string\",\"description\":\"Text to echo back\"}},"
    "\"returns\":{\"text\":{\"type\":\"string\",\"description\":\"Echoed text\"}}"
    "},"
    "{"
    "\"name\":\"upcase\","
    "\"description\":\"Returns the input text converted to uppercase\","
    "\"params\":{\"text\":{\"type\":\"string\",\"description\":\"Text to convert\"}},"
    "\"returns\":{\"text\":{\"type\":\"string\",\"description\":\"Uppercased text\"}}"
    "}"
    "]"
    "}";

/* ── Module exports ────────────────────────────────────────────────── */

void module_init(void) {
    const char *msg = "[echo_lib] library loaded";
    hal_log(1, msg, str_len(msg));
}

void module_destroy(void) {
    const char *msg = "[echo_lib] library unloaded";
    hal_log(1, msg, str_len(msg));
}

/* Returns 1 = library (0 = app) */
uint32_t module_type(void) {
    return 1;
}

/* Write schema JSON into buf. Returns bytes written. */
uint32_t module_api_schema(char *buf, uint32_t buf_len) {
    unsigned schema_len = str_len(SCHEMA);
    unsigned n = schema_len < buf_len ? schema_len : buf_len;
    mem_copy(buf, SCHEMA, n);
    return n;
}

/* ── Minimal JSON field extraction ─────────────────────────────────── */

/* Extract the value of a "text" field from JSON like {"text":"value"}.
 * Returns length of extracted value, 0 if not found. */
static unsigned extract_text_field(
    const char *json, unsigned json_len,
    char *out, unsigned out_len
) {
    /* Find "text":" */
    const char *needle = "\"text\":\"";
    unsigned needle_len = str_len(needle);
    unsigned i = 0;

    while (i + needle_len < json_len) {
        unsigned match = 1;
        for (unsigned j = 0; j < needle_len; j++) {
            if (json[i + j] != needle[j]) { match = 0; break; }
        }
        if (match) {
            i += needle_len;
            /* Read until closing quote */
            unsigned out_i = 0;
            while (i < json_len && json[i] != '"' && out_i < out_len) {
                if (json[i] == '\\' && i + 1 < json_len) {
                    i++; /* skip escape */
                }
                out[out_i++] = json[i++];
            }
            return out_i;
        }
        i++;
    }
    return 0;
}

/* Build a JSON response: {"text":"<value>"} */
static unsigned build_text_response(
    const char *value, unsigned value_len,
    char *buf, unsigned buf_len
) {
    const char *prefix = "{\"text\":\"";
    const char *suffix = "\"}";
    unsigned prefix_len = str_len(prefix);
    unsigned suffix_len = str_len(suffix);
    unsigned total = prefix_len + value_len + suffix_len;

    if (total > buf_len) return 0;

    mem_copy(buf, prefix, prefix_len);
    mem_copy(buf + prefix_len, value, value_len);
    mem_copy(buf + prefix_len + value_len, suffix, suffix_len);
    return total;
}

/* ── module_invoke — generic RPC entry point ──────────────────────── */

int32_t module_invoke(
    const char *fn_name, uint32_t fn_name_len,
    const char *args, uint32_t args_len,
    char *result_buf, uint32_t result_len
) {
    /* Extract text field from args JSON */
    char text[1024];
    unsigned text_len = extract_text_field(args, args_len, text, sizeof(text));

    if (str_eq(fn_name, fn_name_len, "echo", 4)) {
        if (text_len == 0) {
            /* No text field — echo the raw args */
            if (args_len > result_len) return -3;
            mem_copy(result_buf, args, args_len);
            return (int32_t)args_len;
        }
        unsigned n = build_text_response(text, text_len, result_buf, result_len);
        if (n == 0) return -3;
        return (int32_t)n;
    }

    if (str_eq(fn_name, fn_name_len, "upcase", 6)) {
        char upper[1024];
        for (unsigned i = 0; i < text_len && i < sizeof(upper); i++) {
            upper[i] = to_upper(text[i]);
        }
        unsigned n = build_text_response(upper, text_len, result_buf, result_len);
        if (n == 0) return -3;
        return (int32_t)n;
    }

    return -1; /* unknown function */
}
