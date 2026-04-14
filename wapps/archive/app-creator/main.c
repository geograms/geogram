/*
 * tools.geogram.app-creator — in-app wapp authoring.
 *
 * Phase 2: the wapp now extracts field values from the inbox command
 * message and relays them to the host under dedicated
 * `type:"compile"` and `type:"install"` messages. The host-side
 * WappCompilerService + WappInstallerService then do the real work.
 *
 * Wire protocol — host → wapp (via hal_msg_recv):
 *   {"command":"compile","fields":{"source":"...", ...}}
 *   {"command":"install","fields":{"wapp_id":"...","wapp_name":"...",
 *                                  "wapp_description":"...", ...}}
 *
 * Wire protocol — wapp → host (via hal_msg_send):
 *   {"type":"compile","source":"<escaped source>"}
 *   {"type":"install","id":"...","name":"...","description":"..."}
 *
 * Build: WASI_SDK_PATH=$HOME/wasi-sdk make
 */

#include "../../hal/geogram_wasm_hal.h"

/* ── Minimal string helpers (no libc) ─────────────────────────────── */

static unsigned str_len(const char *s) {
    unsigned n = 0;
    while (s[n]) n++;
    return n;
}

static int str_eq_n(const char *a, const char *b, unsigned n) {
    for (unsigned i = 0; i < n; i++) {
        if (a[i] != b[i]) return 0;
    }
    return 1;
}

static int find_substr(const char *hay, unsigned hlen, const char *needle) {
    unsigned nl = str_len(needle);
    if (nl == 0 || hlen < nl) return -1;
    for (unsigned i = 0; i + nl <= hlen; i++) {
        if (str_eq_n(hay + i, needle, nl)) return (int)i;
    }
    return -1;
}

static void append_range(char *dst, unsigned max, unsigned *pos,
                         const char *src, unsigned slen) {
    for (unsigned i = 0; i < slen && *pos + 1 < max; i++) {
        dst[(*pos)++] = src[i];
    }
}

static void append_cstr(char *dst, unsigned max, unsigned *pos, const char *s) {
    append_range(dst, max, pos, s, str_len(s));
}

/*
 * Find `"<key>":"...value..."` anywhere in the JSON blob [hay, hay+hlen)
 * and copy the ESCAPED value (verbatim JSON characters, including any
 * backslash escapes) into `out`. The copied bytes remain valid JSON so
 * the host will jsonDecode them correctly when we re-embed them in an
 * outgoing message. Returns the number of bytes written, or -1 if the
 * key was not found. The buffer is always null-terminated.
 */
static int extract_json_string_field(
    const char *hay, unsigned hlen,
    const char *key,
    char *out, unsigned outmax
) {
    /* Build the token we search for: `"<key>":"` */
    char token[64];
    unsigned tp = 0;
    token[tp++] = '"';
    const unsigned kl = str_len(key);
    for (unsigned i = 0; i < kl && tp + 3 < sizeof(token); i++) {
        token[tp++] = key[i];
    }
    token[tp++] = '"';
    token[tp++] = ':';
    token[tp++] = '"';
    token[tp] = '\0';

    const int found = find_substr(hay, hlen, token);
    if (found < 0) {
        if (outmax > 0) out[0] = '\0';
        return -1;
    }

    unsigned i = (unsigned)found + tp;
    unsigned op = 0;
    while (i < hlen && op + 1 < outmax) {
        const char c = hay[i];
        if (c == '\\' && i + 1 < hlen) {
            /* Escape sequence — copy the backslash and the next char
             * verbatim. JSON only uses single-character escapes and
             * \uXXXX (six chars); we treat them all as "skip two" for
             * the purpose of finding the closing quote. */
            if (op + 2 >= outmax) break;
            out[op++] = c;
            out[op++] = hay[i + 1];
            i += 2;
        } else if (c == '"') {
            break;
        } else {
            out[op++] = c;
            i++;
        }
    }
    out[op] = '\0';
    return (int)op;
}

/* ── Module lifecycle ─────────────────────────────────────────────── */

void module_init(void) {
    hal_log(1, "[app-creator] init", 18);
}

void module_tick(void) {
    /* No periodic work — everything runs from button-click commands. */
}

void module_destroy(void) {
    hal_log(1, "[app-creator] destroy", 21);
}

uint32_t module_tick_interval_ms(void) {
    return 2000;
}

void module_handle_event(void) {
    /* The inbox buffer has to fit the full command envelope plus the
     * source code payload. 32 KB gives us headroom for ~24 KB of
     * JSON-escaped C source, which is plenty for a single-file wapp. */
    static char inbox[32 * 1024];
    static char source_buf[24 * 1024];
    static char field_buf[512];
    static char out_buf[32 * 1024];

    while (hal_msg_available() != 0) {
        uint32_t n = hal_msg_recv(inbox, sizeof(inbox) - 1);
        if (n == 0) break;
        inbox[n] = '\0';

        const int cmd_idx = find_substr(inbox, n, "\"command\"");
        if (cmd_idx < 0) continue;

        /* Find the opening quote of the value. */
        int qstart = -1;
        for (unsigned i = (unsigned)cmd_idx + 9; i < n; i++) {
            if (inbox[i] == '"') { qstart = (int)i + 1; break; }
        }
        if (qstart < 0) continue;
        int qend = -1;
        for (unsigned i = (unsigned)qstart; i < n; i++) {
            if (inbox[i] == '"') { qend = (int)i; break; }
        }
        if (qend < 0) continue;

        const char *cmd = inbox + qstart;
        const unsigned clen = (unsigned)(qend - qstart);

        if (clen == 7 && str_eq_n(cmd, "compile", 7)) {
            /* Extract source from fields. */
            const int src_len = extract_json_string_field(
                inbox, n, "source", source_buf, sizeof(source_buf));
            if (src_len < 0) {
                hal_msg_send(
                    "{\"type\":\"compile\",\"error\":\"no source field\"}",
                    42);
                continue;
            }
            /* Build {"type":"compile","source":"<escaped>"}. The source
             * is already JSON-escaped from the inbound message so we
             * copy it verbatim. */
            unsigned op = 0;
            append_cstr(out_buf, sizeof(out_buf), &op,
                        "{\"type\":\"compile\",\"source\":\"");
            append_range(out_buf, sizeof(out_buf), &op, source_buf,
                         (unsigned)src_len);
            append_cstr(out_buf, sizeof(out_buf), &op, "\"}");
            hal_msg_send(out_buf, op);
        } else if (clen == 7 && str_eq_n(cmd, "install", 7)) {
            /* Extract id, name, description from fields. */
            const int id_len = extract_json_string_field(
                inbox, n, "wapp_id", field_buf, sizeof(field_buf));
            if (id_len < 0) {
                hal_msg_send(
                    "{\"type\":\"install\",\"error\":\"no wapp_id\"}",
                    37);
                continue;
            }
            unsigned op = 0;
            append_cstr(out_buf, sizeof(out_buf), &op,
                        "{\"type\":\"install\",\"id\":\"");
            append_range(out_buf, sizeof(out_buf), &op, field_buf,
                         (unsigned)id_len);
            append_cstr(out_buf, sizeof(out_buf), &op, "\",\"name\":\"");
            const int name_len = extract_json_string_field(
                inbox, n, "wapp_name", field_buf, sizeof(field_buf));
            if (name_len > 0) {
                append_range(out_buf, sizeof(out_buf), &op, field_buf,
                             (unsigned)name_len);
            }
            append_cstr(out_buf, sizeof(out_buf), &op, "\",\"description\":\"");
            const int desc_len = extract_json_string_field(
                inbox, n, "wapp_description", field_buf, sizeof(field_buf));
            if (desc_len > 0) {
                append_range(out_buf, sizeof(out_buf), &op, field_buf,
                             (unsigned)desc_len);
            }
            append_cstr(out_buf, sizeof(out_buf), &op, "\"}");
            hal_msg_send(out_buf, op);
        }
    }
}
