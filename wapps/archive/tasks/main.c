/*
 * tools.geogram.tasks — Task Monitor wapp
 *
 * Polls the host every tick for the live MonitoredTask snapshot and
 * relays user button clicks (received as command messages from the
 * Flutter renderer) into system.tasks.* action messages. The host's
 * wapp_page.dart owns the snapshot state and the card rendering — this
 * wapp is a thin command/relay shell so the host stays the only place
 * that touches TaskMonitorService.
 *
 * Wire protocol — wapp → host (via hal_msg_send):
 *   {"type":"system.tasks.list"}
 *   {"type":"system.tasks.pause","id":"<id>"}
 *   {"type":"system.tasks.resume","id":"<id>"}
 *   {"type":"system.tasks.pause_all"}
 *   {"type":"system.tasks.resume_all"}
 *
 * Wire protocol — host → wapp (via hal_msg_recv, sent by the renderer
 * when the user clicks a button):
 *   {"command":"pause <id>"}
 *   {"command":"resume <id>"}
 *   {"command":"pause-all"}
 *   {"command":"resume-all"}
 *
 * Build: cd wapps && ./build-archive.sh tasks
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

/* Append [src, src+slen) into dst[*pos..max), null-terminated, no overflow. */
static void append_range(char *dst, unsigned max, unsigned *pos,
                         const char *src, unsigned slen) {
    for (unsigned i = 0; i < slen && *pos + 1 < max; i++) {
        dst[(*pos)++] = src[i];
    }
}

static void append_cstr(char *dst, unsigned max, unsigned *pos, const char *s) {
    append_range(dst, max, pos, s, str_len(s));
}

static void send_cstr(const char *s) {
    hal_msg_send(s, str_len(s));
}

/* ── HAL wire-format builders ─────────────────────────────────────── */

static const char REQ_LIST[] = "{\"type\":\"system.tasks.list\"}";

/* Send {"type":"system.tasks.<action>","id":"<id>"} (id is JSON-escaped). */
static void send_action_with_id(const char *action,
                                const char *id, unsigned id_len) {
    char buf[512];
    unsigned pos = 0;
    append_cstr(buf, sizeof(buf), &pos, "{\"type\":\"system.tasks.");
    append_cstr(buf, sizeof(buf), &pos, action);
    append_cstr(buf, sizeof(buf), &pos, "\",\"id\":\"");
    for (unsigned i = 0; i < id_len && pos + 2 < sizeof(buf); i++) {
        char c = id[i];
        if (c == '\\' || c == '"') {
            if (pos + 3 < sizeof(buf)) buf[pos++] = '\\';
        }
        buf[pos++] = c;
    }
    append_cstr(buf, sizeof(buf), &pos, "\"}");
    hal_msg_send(buf, pos);
}

/* Send {"type":"system.tasks.<action>"} with no id field. */
static void send_action_no_id(const char *action) {
    char buf[128];
    unsigned pos = 0;
    append_cstr(buf, sizeof(buf), &pos, "{\"type\":\"system.tasks.");
    append_cstr(buf, sizeof(buf), &pos, action);
    append_cstr(buf, sizeof(buf), &pos, "\"}");
    hal_msg_send(buf, pos);
}

/* ── Module lifecycle ─────────────────────────────────────────────── */

void module_init(void) {
    hal_log(1, "[tasks] init", 12);
    /* Kick off the first snapshot request immediately so the UI is
     * never blank for a full tick interval. */
    send_cstr(REQ_LIST);
}

void module_tick(void) {
    /* Poll the host for an updated snapshot every tick. The host
     * stashes it directly in WappPage state and rebuilds — this wapp
     * does not need to receive the response. */
    send_cstr(REQ_LIST);
}

void module_destroy(void) {
    hal_log(1, "[tasks] destroy", 15);
}

uint32_t module_tick_interval_ms(void) {
    return 1000;
}

/* Parse incoming command messages from the renderer and translate
 * them into system.tasks.* actions back to the host. */
void module_handle_event(void) {
    char buf[1024];
    while (hal_msg_available() != 0) {
        uint32_t n = hal_msg_recv(buf, sizeof(buf) - 1);
        if (n == 0) break;
        buf[n] = '\0';

        /* Find the "command" key. */
        int key_idx = find_substr(buf, n, "\"command\"");
        if (key_idx < 0) continue;

        /* Skip past the key, then find the opening quote of the value. */
        int qstart = -1;
        for (unsigned i = (unsigned)key_idx + 9; i < n; i++) {
            if (buf[i] == '"') { qstart = (int)i + 1; break; }
        }
        if (qstart < 0) continue;
        int qend = -1;
        for (unsigned i = (unsigned)qstart; i < n; i++) {
            if (buf[i] == '"') { qend = (int)i; break; }
        }
        if (qend < 0) continue;

        const char *cmd = buf + qstart;
        unsigned clen = (unsigned)(qend - qstart);

        /* Bulk actions first. */
        if (clen == 9 && str_eq_n(cmd, "pause-all", 9)) {
            send_action_no_id("pause_all");
            continue;
        }
        if (clen == 10 && str_eq_n(cmd, "resume-all", 10)) {
            send_action_no_id("resume_all");
            continue;
        }

        /* Per-id actions: "pause <id>", "resume <id>". */
        const char *action = 0;
        unsigned skip = 0;
        if (clen > 6 && str_eq_n(cmd, "pause ", 6)) {
            action = "pause"; skip = 6;
        } else if (clen > 7 && str_eq_n(cmd, "resume ", 7)) {
            action = "resume"; skip = 7;
        }
        if (action) {
            send_action_with_id(action, cmd + skip, clen - skip);
        }
    }
}
