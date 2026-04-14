/*
 * tools.geogram.widget-demo — minimal widget provider wapp.
 *
 * Declares itself as a provider for two widget IDs in manifest.json
 * (text.greet and text.shout). When the host's WidgetBroker receives
 * a widget.request for either of those IDs, it spins up a headless
 * instance of this wapp, injects the request into the inbox, and
 * drives module_handle_event once. The handler reads the request,
 * emits a widget.response with a fixed result, and the broker
 * delivers the response to the caller.
 *
 * This wapp demonstrates TWO things at once:
 *   - A single wapp providing multiple widgets (both text.greet and
 *     text.shout share this one main.c).
 *   - A stateless, synchronous provider — no UI, no args parsing,
 *     just a fixed payload per widget id.
 *
 * A UI-rendering provider (file picker etc) will need a different
 * pattern where the host opens the provider in a Navigator route.
 *
 * Build: cd wapps && ./build-archive.sh widget_demo
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

/* Extract the value of a JSON string field from [buf, buf+n). Writes
 * the value (without quotes) into [out, out+outmax) and returns the
 * number of bytes written, or -1 if the key isn't found. Assumes
 * well-formed single-line JSON without escaped quotes in the value —
 * good enough for the broker-emitted widget.request payload which we
 * generate ourselves. */
static int extract_string_field(const char *buf, unsigned n,
                                 const char *key,
                                 char *out, unsigned outmax) {
    /* Build the key token once: `"<key>"` */
    char keybuf[64];
    unsigned kpos = 0;
    keybuf[kpos++] = '"';
    unsigned kl = str_len(key);
    for (unsigned i = 0; i < kl && kpos + 2 < sizeof(keybuf); i++) {
        keybuf[kpos++] = key[i];
    }
    keybuf[kpos++] = '"';
    keybuf[kpos] = '\0';

    int key_idx = find_substr(buf, n, keybuf);
    if (key_idx < 0) return -1;

    /* Skip past key and find the next opening quote of the value. */
    unsigned i = (unsigned)key_idx + kpos;
    while (i < n && buf[i] != '"') i++;
    if (i >= n) return -1;
    i++; /* past opening quote */

    unsigned written = 0;
    while (i < n && buf[i] != '"' && written + 1 < outmax) {
        out[written++] = buf[i++];
    }
    out[written] = '\0';
    return (int)written;
}

/* ── Widget response emitter ──────────────────────────────────────── */

/*
 * Build and send a widget.response for the given req_id + result
 * payload. result_json should be a JSON object body like
 * `{"greeting":"..."}` — it is embedded as-is under the "result" key.
 */
static void send_widget_response(const char *req_id, unsigned rid_len,
                                 const char *result_json) {
    char buf[512];
    unsigned pos = 0;
    append_cstr(buf, sizeof(buf), &pos, "{\"type\":\"widget.response\",\"req_id\":\"");
    append_range(buf, sizeof(buf), &pos, req_id, rid_len);
    append_cstr(buf, sizeof(buf), &pos, "\",\"result\":");
    append_cstr(buf, sizeof(buf), &pos, result_json);
    append_cstr(buf, sizeof(buf), &pos, "}");
    hal_msg_send(buf, pos);
}

static void send_widget_error(const char *req_id, unsigned rid_len,
                              const char *error_msg) {
    char buf[384];
    unsigned pos = 0;
    append_cstr(buf, sizeof(buf), &pos, "{\"type\":\"widget.response\",\"req_id\":\"");
    append_range(buf, sizeof(buf), &pos, req_id, rid_len);
    append_cstr(buf, sizeof(buf), &pos, "\",\"error\":\"");
    append_cstr(buf, sizeof(buf), &pos, error_msg);
    append_cstr(buf, sizeof(buf), &pos, "\"}");
    hal_msg_send(buf, pos);
}

/* ── Module lifecycle ─────────────────────────────────────────────── */

void module_init(void) {
    hal_log(1, "[widget_demo] init", 18);
}

void module_tick(void) {
    /* Headless provider — no work on tick. */
}

void module_destroy(void) {
    hal_log(1, "[widget_demo] destroy", 21);
}

uint32_t module_tick_interval_ms(void) {
    return 5000;
}

void module_handle_event(void) {
    char buf[1024];
    while (hal_msg_available() != 0) {
        uint32_t n = hal_msg_recv(buf, sizeof(buf) - 1);
        if (n == 0) break;
        buf[n] = '\0';

        /* We only care about widget.request — ignore everything else. */
        if (find_substr(buf, n, "\"type\":\"widget.request\"") < 0) {
            continue;
        }

        /* Extract req_id and widget fields. */
        char req_id[128];
        int rid_len = extract_string_field(buf, n, "req_id",
                                           req_id, sizeof(req_id));
        if (rid_len < 0) continue;

        char widget[128];
        int wid_len = extract_string_field(buf, n, "widget",
                                           widget, sizeof(widget));
        if (wid_len < 0) {
            send_widget_error(req_id, (unsigned)rid_len,
                "missing widget field");
            continue;
        }

        /* Dispatch on widget id. Both widgets are stateless and
         * return fixed results — real providers would decode the
         * args and compute a response. */
        if (wid_len == 10 && str_eq_n(widget, "text.greet", 10)) {
            send_widget_response(req_id, (unsigned)rid_len,
                "{\"greeting\":\"Hello from widget_demo!\"}");
        } else if (wid_len == 10 && str_eq_n(widget, "text.shout", 10)) {
            send_widget_response(req_id, (unsigned)rid_len,
                "{\"loud\":\"WIDGET DEMO!\"}");
        } else {
            send_widget_error(req_id, (unsigned)rid_len,
                "unknown widget id");
        }
    }
}
