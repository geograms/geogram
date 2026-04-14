/*
 * tools.geogram.tester — end-user test harness for host services.
 *
 * Screens:
 *  - Notifications: buttons that emit `{"type":"notify",...}` for every
 *    combination of level, body, and scope.
 *  - Events: buttons that call hal_event_subscribe / hal_event_publish /
 *    hal_event_unsubscribe against both local test topics and the
 *    system.* topics republished by the host's HostEventBridge. Every
 *    received event is then surfaced as an in-app notification so the
 *    pipeline is visible end-to-end.
 *
 * The Flutter-side GeoUI renderer forwards every non-save action name
 * to the wapp as a `{"command":"<name>"}` message; this wapp parses
 * the command and emits the matching HAL calls. Events that arrive in
 * the wapp's private queue are drained in both module_tick and
 * module_handle_event and surfaced via `{"type":"notify",...}`.
 *
 * Build: cd wapps && ./build-archive.sh tester
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

/* True iff [s, s+slen) equals the null-terminated literal [lit]. */
static int str_eq_literal(const char *s, unsigned slen, const char *lit) {
    unsigned ll = str_len(lit);
    if (slen != ll) return 0;
    return str_eq_n(s, lit, ll);
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

/* JSON-escape characters that would break the outer object when
 * embedding topic/data strings in a notification body. */
static void append_json_escaped(char *dst, unsigned max, unsigned *pos,
                                const char *src, unsigned slen) {
    for (unsigned i = 0; i < slen && *pos + 2 < max; i++) {
        char c = src[i];
        if (c == '\\' || c == '"') {
            if (*pos + 3 < max) dst[(*pos)++] = '\\';
            dst[(*pos)++] = c;
        } else if (c == '\n') {
            if (*pos + 3 < max) {
                dst[(*pos)++] = '\\';
                dst[(*pos)++] = 'n';
            }
        } else if ((unsigned char)c < 0x20) {
            /* Skip other control chars. */
        } else {
            dst[(*pos)++] = c;
        }
    }
}

/* ── Notification emitter ─────────────────────────────────────────── */

/*
 * Builds and sends a `{"type":"notify","level":"...","title":"...",
 * "body":"...","scope":"..."}` message. body/scope may be 0 to omit
 * those fields. body_is_escaped=1 means body is already JSON-safe.
 */
static void send_notify(const char *level, const char *title,
                        const char *body, const char *scope) {
    char buf[768];
    unsigned pos = 0;

    append_cstr(buf, sizeof(buf), &pos, "{\"type\":\"notify\",\"level\":\"");
    append_cstr(buf, sizeof(buf), &pos, level);
    append_cstr(buf, sizeof(buf), &pos, "\",\"title\":\"");
    append_cstr(buf, sizeof(buf), &pos, title);
    append_cstr(buf, sizeof(buf), &pos, "\"");
    if (body) {
        append_cstr(buf, sizeof(buf), &pos, ",\"body\":\"");
        append_cstr(buf, sizeof(buf), &pos, body);
        append_cstr(buf, sizeof(buf), &pos, "\"");
    }
    if (scope) {
        append_cstr(buf, sizeof(buf), &pos, ",\"scope\":\"");
        append_cstr(buf, sizeof(buf), &pos, scope);
        append_cstr(buf, sizeof(buf), &pos, "\"");
    }
    append_cstr(buf, sizeof(buf), &pos, "}");

    hal_msg_send(buf, pos);
}

/* Emit a notify for a received event. Topic + data are escaped into
 * the body so payload quotes don't break the outer JSON. */
static void send_event_notify(const char *topic, unsigned tlen,
                              const char *data, unsigned dlen) {
    char buf[1024];
    unsigned pos = 0;
    append_cstr(buf, sizeof(buf), &pos, "{\"type\":\"notify\",\"level\":\"info\",\"title\":\"Event: ");
    append_json_escaped(buf, sizeof(buf), &pos, topic, tlen);
    append_cstr(buf, sizeof(buf), &pos, "\",\"body\":\"");
    if (dlen == 0) {
        append_cstr(buf, sizeof(buf), &pos, "(no payload)");
    } else {
        append_json_escaped(buf, sizeof(buf), &pos, data, dlen);
    }
    append_cstr(buf, sizeof(buf), &pos, "\"}");
    hal_msg_send(buf, pos);
}

/* ── Event HAL helpers ────────────────────────────────────────────── */

static void event_subscribe(const char *topic) {
    hal_event_subscribe(topic, str_len(topic));
}

static void event_unsubscribe(const char *topic) {
    hal_event_unsubscribe(topic, str_len(topic));
}

static void event_publish(const char *topic, const char *data) {
    hal_event_publish(topic, str_len(topic), data, str_len(data));
}

/* Drain every pending event from this wapp's queue and surface each
 * one as an in-app notification. Called from both module_tick and
 * module_handle_event so events surface whether they arrived during a
 * command round-trip or between ticks. */
static void drain_events(void) {
    char topic[128];
    char data[512];
    while (hal_event_available() != 0) {
        /* The host null-terminates both buffers after writing (see
         * the halEventRecv WasmFunction in iwi/lib/wapp/wapp_engine.dart),
         * so we can strlen() them safely. The return value is bytes
         * written to the data buffer. */
        uint32_t dlen = hal_event_recv(topic, sizeof(topic),
                                       data, sizeof(data));
        unsigned tlen = str_len(topic);
        send_event_notify(topic, tlen, data, dlen);
    }
}

/* ── Module lifecycle ─────────────────────────────────────────────── */

void module_init(void) {
    hal_log(1, "[tester] init", 13);
}

void module_tick(void) {
    /* Pick up any events that arrived between command round-trips. */
    drain_events();
}

void module_destroy(void) {
    hal_log(1, "[tester] destroy", 16);
}

uint32_t module_tick_interval_ms(void) {
    /* 500 ms so events surface within a fraction of a second of
     * being published. Wapps without event handling should return a
     * larger interval to save CPU. */
    return 500;
}

void module_handle_event(void) {
    char buf[1024];
    while (hal_msg_available() != 0) {
        uint32_t n = hal_msg_recv(buf, sizeof(buf) - 1);
        if (n == 0) break;
        buf[n] = '\0';

        /* Find the "command" key — same pattern as the tasks wapp. */
        int key_idx = find_substr(buf, n, "\"command\"");
        if (key_idx < 0) continue;
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

        /* ── Notification tests ── */

        if (str_eq_literal(cmd, clen, "notify-info")) {
            send_notify("info", "Info test", 0, 0);
        } else if (str_eq_literal(cmd, clen, "notify-success")) {
            send_notify("success", "Success test", 0, 0);
        } else if (str_eq_literal(cmd, clen, "notify-warning")) {
            send_notify("warning", "Warning test", 0, 0);
        } else if (str_eq_literal(cmd, clen, "notify-error")) {
            send_notify("error", "Error test", 0, 0);
        } else if (str_eq_literal(cmd, clen, "notify-body")) {
            send_notify("info", "Info with body",
                "Multi-line notification body to verify how the "
                "card handles wrapping and layout.", 0);
        } else if (str_eq_literal(cmd, clen, "notify-error-body")) {
            send_notify("error", "Something broke",
                "The connection to the remote peer was lost. "
                "Will retry in 30 seconds.", 0);
        } else if (str_eq_literal(cmd, clen, "notify-system")) {
            send_notify("info", "System tray ping",
                "This notification goes only to the OS notification "
                "area, not the in-app overlay.", "system");
        } else if (str_eq_literal(cmd, clen, "notify-both")) {
            send_notify("success", "Both scopes",
                "Delivered in-app AND to the OS notification area.",
                "both");
        } else if (str_eq_literal(cmd, clen, "notify-stack")) {
            send_notify("info",    "Stack 1/5", 0, 0);
            send_notify("success", "Stack 2/5", 0, 0);
            send_notify("warning", "Stack 3/5", 0, 0);
            send_notify("error",   "Stack 4/5", 0, 0);
            send_notify("info",    "Stack 5/5",
                "All five should be visible in the overlay at once.",
                0);

        /* ── Event tests ── */

        } else if (str_eq_literal(cmd, clen, "event-sub-hello")) {
            event_subscribe("test.hello");
            send_notify("success", "Subscribed",
                "test.hello — publish to this topic to see it arrive.", 0);
        } else if (str_eq_literal(cmd, clen, "event-pub-hello")) {
            event_publish("test.hello", "greetings from Tester");
        } else if (str_eq_literal(cmd, clen, "event-unsub-hello")) {
            event_unsubscribe("test.hello");
            send_notify("warning", "Unsubscribed",
                "test.hello — subsequent publishes will not arrive.", 0);
        } else if (str_eq_literal(cmd, clen, "event-echo")) {
            event_subscribe("test.echo");
            event_publish("test.echo", "round-trip test");
        } else if (str_eq_literal(cmd, clen, "event-sub-wapp-loaded")) {
            event_subscribe("system.wapp.loaded");
            send_notify("success", "Subscribed",
                "system.wapp.loaded — open another wapp from the "
                "launcher to see it fire.", 0);
        } else if (str_eq_literal(cmd, clen, "event-sub-wapp-unloaded")) {
            event_subscribe("system.wapp.unloaded");
            send_notify("success", "Subscribed",
                "system.wapp.unloaded — close another wapp to see "
                "it fire.", 0);
        } else if (str_eq_literal(cmd, clen, "event-sub-error")) {
            event_subscribe("system.error");
            send_notify("success", "Subscribed",
                "system.error — any ErrorEvent on the host bus will "
                "surface here.", 0);
        }
    }

    /* After processing the command, immediately drain any events it
     * caused. This makes the "echo" flow surface its result within a
     * single handle_event call instead of waiting for the next tick. */
    drain_events();
}
