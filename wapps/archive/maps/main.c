/*
 * maps — Geogram WASM Satellite Maps Module
 *
 * Manages map viewport state (center lat/lon, zoom) and pushes
 * viewport updates to the renderer via hal_msg_send().
 * The renderer handles tile fetching and display.
 *
 * Build: cd wapps/archive/maps && make
 */

#include "../../hal/geogram_wasm_hal.h"

/* ── Helpers ─────────────────────────────────────────────────────────── */

static unsigned str_len(const char *s) { unsigned n = 0; while (s[n]) n++; return n; }
static int str_eq(const char *a, const char *b) { while (*a && *b && *a == *b) { a++; b++; } return *a == *b; }
static void str_copy(char *d, const char *s, unsigned m) { unsigned i = 0; while (i < m - 1 && s[i]) { d[i] = s[i]; i++; } d[i] = '\0'; }
static void str_cat(char *d, const char *s, unsigned m) { unsigned l = str_len(d); unsigned i = 0; while (l + i < m - 1 && s[i]) { d[l + i] = s[i]; i++; } d[l + i] = '\0'; }

static const char *skip_spaces(const char *s) { while (*s == ' ' || *s == '\t') s++; return s; }
static const char *next_word(const char *s, char *w, unsigned m) {
    s = skip_spaces(s); unsigned i = 0;
    while (*s && *s != ' ' && *s != '\t' && i < m - 1) w[i++] = *s++;
    w[i] = '\0'; return s;
}

/* Simple double-to-string (6 decimal places) */
static void dbl_to_str(double v, char *buf, unsigned len) {
    if (len < 16) { buf[0] = '\0'; return; }
    int neg = 0;
    if (v < 0) { neg = 1; v = -v; }
    int whole = (int)v;
    int frac = (int)((v - (double)whole) * 1000000.0 + 0.5);
    if (frac >= 1000000) { whole++; frac -= 1000000; }
    unsigned i = 0;
    if (neg) buf[i++] = '-';
    /* whole part */
    char tmp[16]; unsigned t = 0;
    if (whole == 0) tmp[t++] = '0';
    else { int w = whole; while (w > 0 && t < 15) { tmp[t++] = '0' + (w % 10); w /= 10; } }
    while (t > 0 && i < len - 8) buf[i++] = tmp[--t];
    buf[i++] = '.';
    /* frac part (6 digits, zero-padded) */
    for (int d = 5; d >= 0; d--) {
        int pw = 1; for (int p = 0; p < d; p++) pw *= 10;
        buf[i++] = '0' + (frac / pw) % 10;
    }
    buf[i] = '\0';
}

/* Simple string-to-double */
static double str_to_dbl(const char *s) {
    int neg = 0;
    if (*s == '-') { neg = 1; s++; }
    double v = 0;
    while (*s >= '0' && *s <= '9') { v = v * 10 + (*s - '0'); s++; }
    if (*s == '.') {
        s++; double f = 0.1;
        while (*s >= '0' && *s <= '9') { v += (*s - '0') * f; f *= 0.1; s++; }
    }
    return neg ? -v : v;
}

static int str_to_int(const char *s) {
    int neg = 0, v = 0;
    if (*s == '-') { neg = 1; s++; }
    while (*s >= '0' && *s <= '9') { v = v * 10 + (*s - '0'); s++; }
    return neg ? -v : v;
}

/* ── State ───────────────────────────────────────────────────────────── */

static double center_lat = 38.7223;   /* Lisbon */
static double center_lon = -9.1393;
static int    zoom = 12;

static void load_state(void) {
    char buf[32];
    if (hal_kv_get("lat", 3, buf, sizeof(buf) - 1) > 0) center_lat = str_to_dbl(buf);
    if (hal_kv_get("lon", 3, buf, sizeof(buf) - 1) > 0) center_lon = str_to_dbl(buf);
    if (hal_kv_get("zoom", 4, buf, sizeof(buf) - 1) > 0) zoom = str_to_int(buf);
}

static void save_state(void) {
    char buf[32];
    dbl_to_str(center_lat, buf, sizeof(buf));
    hal_kv_set("lat", 3, buf, str_len(buf));
    dbl_to_str(center_lon, buf, sizeof(buf));
    hal_kv_set("lon", 3, buf, str_len(buf));
    char zbuf[8]; zbuf[0] = '0' + (zoom / 10); zbuf[1] = '0' + (zoom % 10); zbuf[2] = '\0';
    hal_kv_set("zoom", 4, zbuf, str_len(zbuf));
}

/* ── Viewport push ───────────────────────────────────────────────────── */

static void push_viewport(void) {
    char lat_s[24], lon_s[24];
    dbl_to_str(center_lat, lat_s, sizeof(lat_s));
    dbl_to_str(center_lon, lon_s, sizeof(lon_s));
    char zbuf[4]; zbuf[0] = '0' + (zoom / 10); zbuf[1] = '0' + (zoom % 10); zbuf[2] = '\0';

    char msg[256] = "{\"type\":\"ui.map.viewport\",\"lat\":";
    str_cat(msg, lat_s, sizeof(msg));
    str_cat(msg, ",\"lon\":", sizeof(msg));
    str_cat(msg, lon_s, sizeof(msg));
    str_cat(msg, ",\"zoom\":", sizeof(msg));
    str_cat(msg, zbuf, sizeof(msg));
    str_cat(msg, "}", sizeof(msg));
    hal_msg_send(msg, str_len(msg));
}

static void send_output(const char *text, const char *level) {
    char buf[512] = "{\"type\":\"ui.append\",\"target\":\"output\",\"item\":{\"text\":\"";
    unsigned len = str_len(buf);
    for (unsigned i = 0; text[i] && len < sizeof(buf) - 40; i++) {
        if (text[i] == '"') { buf[len++] = '\\'; buf[len++] = '"'; }
        else if (text[i] == '\\') { buf[len++] = '\\'; buf[len++] = '\\'; }
        else { buf[len++] = text[i]; }
    }
    str_copy(buf + len, "\",\"level\":\"", sizeof(buf) - len); len = str_len(buf);
    str_cat(buf + len, level, sizeof(buf) - len); len = str_len(buf);
    str_copy(buf + len, "\"}}", sizeof(buf) - len); len = str_len(buf);
    hal_msg_send(buf, len);
}

/* ── Pan helpers ──────────────────────────────────────────────────────── */

/* Degrees per pixel at a given zoom level (approx at equator) */
static double deg_per_tile(int z) {
    double tiles = 1.0;
    for (int i = 0; i < z; i++) tiles *= 2.0;
    return 360.0 / tiles;
}

static void do_pan(double dlat, double dlon) {
    center_lat += dlat;
    center_lon += dlon;
    if (center_lat > 85.0) center_lat = 85.0;
    if (center_lat < -85.0) center_lat = -85.0;
    while (center_lon > 180.0) center_lon -= 360.0;
    while (center_lon < -180.0) center_lon += 360.0;
    save_state();
    push_viewport();
}

/* ── Command dispatch ────────────────────────────────────────────────── */

static void dispatch(const char *input) {
    char cmd[32];
    const char *args = next_word(input, cmd, sizeof(cmd));

    if (cmd[0] == '\0') return;

    if (str_eq(cmd, "help")) {
        send_output("Map commands:", "info");
        send_output("  goto <lat> <lon>  Go to coordinates", "out");
        send_output("  zoom <level>      Set zoom (2-18)", "out");
        send_output("  zoom in/out       Zoom in or out", "out");
        send_output("  pan <n|s|e|w>     Pan in direction", "out");
        send_output("  where             Show current position", "out");
        send_output("  search <query>    Search for a location", "out");
        send_output("  help              Show this help", "out");
    }
    else if (str_eq(cmd, "goto")) {
        char lat_s[32], lon_s[32];
        args = next_word(args, lat_s, sizeof(lat_s));
        next_word(args, lon_s, sizeof(lon_s));
        if (lat_s[0] == '\0' || lon_s[0] == '\0') {
            send_output("Usage: goto <lat> <lon>", "err");
            return;
        }
        center_lat = str_to_dbl(lat_s);
        center_lon = str_to_dbl(lon_s);
        save_state();
        push_viewport();
        send_output("ok", "out");
    }
    else if (str_eq(cmd, "zoom")) {
        char arg[16];
        next_word(args, arg, sizeof(arg));
        if (str_eq(arg, "in")) {
            if (zoom < 18) zoom++;
        } else if (str_eq(arg, "out")) {
            if (zoom > 2) zoom--;
        } else {
            int z = str_to_int(arg);
            if (z >= 2 && z <= 18) zoom = z;
            else { send_output("Zoom range: 2-18", "err"); return; }
        }
        save_state();
        push_viewport();
    }
    else if (str_eq(cmd, "pan")) {
        char dir[8];
        next_word(args, dir, sizeof(dir));
        double step = deg_per_tile(zoom) * 0.5;
        if (str_eq(dir, "n") || str_eq(dir, "north")) do_pan(step, 0);
        else if (str_eq(dir, "s") || str_eq(dir, "south")) do_pan(-step, 0);
        else if (str_eq(dir, "e") || str_eq(dir, "east")) do_pan(0, step);
        else if (str_eq(dir, "w") || str_eq(dir, "west")) do_pan(0, -step);
        else send_output("Usage: pan <n|s|e|w>", "err");
    }
    else if (str_eq(cmd, "where")) {
        char lat_s[24], lon_s[24];
        dbl_to_str(center_lat, lat_s, sizeof(lat_s));
        dbl_to_str(center_lon, lon_s, sizeof(lon_s));
        char zbuf[4]; zbuf[0] = '0' + (zoom / 10); zbuf[1] = '0' + (zoom % 10); zbuf[2] = '\0';
        char msg[128] = "";
        str_cat(msg, lat_s, sizeof(msg));
        str_cat(msg, ", ", sizeof(msg));
        str_cat(msg, lon_s, sizeof(msg));
        str_cat(msg, " (zoom ", sizeof(msg));
        str_cat(msg, zbuf, sizeof(msg));
        str_cat(msg, ")", sizeof(msg));
        send_output(msg, "info");
    }
    else {
        /* Try handling as pan via JSON from renderer */
        send_output("Unknown command. Type 'help'.", "err");
    }
}

/* ── Module entry points ─────────────────────────────────────────────── */

void module_init(void) {
    hal_log(1, "[maps] init", 11);
    load_state();
    push_viewport();
}

void module_tick(void) {
    /* Nothing periodic */
}

void module_handle_event(void) {
    char buf[512];
    if (hal_msg_available() == 0) return;
    uint32_t n = hal_msg_recv(buf, sizeof(buf) - 1);
    if (n == 0) return;
    buf[n] = '\0';

    /* JSON messages from renderer */
    if (buf[0] == '{') {
        /* Check for "command" field */
        const char *key = "\"command\":\"";
        const char *p = buf;
        while (*p) {
            if (str_eq(p, key) == 0) {
                unsigned kl = str_len(key);
                int match = 1;
                for (unsigned i = 0; i < kl; i++) { if (p[i] != key[i]) { match = 0; break; } }
                if (match) {
                    p += kl;
                    char cmd[256]; unsigned i = 0;
                    while (*p && *p != '"' && i < sizeof(cmd) - 1) {
                        if (*p == '\\' && *(p + 1)) { p++; cmd[i++] = *p++; }
                        else { cmd[i++] = *p++; }
                    }
                    cmd[i] = '\0';
                    dispatch(cmd);
                    return;
                }
            }
            p++;
        }

        /* Check for viewport update from renderer: {"type":"pan","dx":...,"dy":...} */
        /* or {"type":"zoom","delta":...} */
        /* or {"type":"setViewport","lat":...,"lon":...,"zoom":...} */
        const char *type_key = "\"type\":\"";
        p = buf;
        while (*p) {
            unsigned tkl = str_len(type_key);
            int match = 1;
            for (unsigned i = 0; i < tkl; i++) { if (p[i] != type_key[i]) { match = 0; break; } }
            if (match) {
                p += tkl;
                char type[32]; unsigned i = 0;
                while (*p && *p != '"' && i < sizeof(type) - 1) type[i++] = *p++;
                type[i] = '\0';

                if (str_eq(type, "setViewport")) {
                    /* Parse lat, lon, zoom from JSON */
                    const char *latk = "\"lat\":";
                    const char *lonk = "\"lon\":";
                    const char *zoomk = "\"zoom\":";
                    const char *q;
                    q = buf;
                    while (*q) {
                        int m = 1;
                        for (unsigned j = 0; j < str_len(latk); j++) { if (q[j] != latk[j]) { m = 0; break; } }
                        if (m) { center_lat = str_to_dbl(q + str_len(latk)); break; }
                        q++;
                    }
                    q = buf;
                    while (*q) {
                        int m = 1;
                        for (unsigned j = 0; j < str_len(lonk); j++) { if (q[j] != lonk[j]) { m = 0; break; } }
                        if (m) { center_lon = str_to_dbl(q + str_len(lonk)); break; }
                        q++;
                    }
                    q = buf;
                    while (*q) {
                        int m = 1;
                        for (unsigned j = 0; j < str_len(zoomk); j++) { if (q[j] != zoomk[j]) { m = 0; break; } }
                        if (m) { zoom = str_to_int(q + str_len(zoomk)); break; }
                        q++;
                    }
                    save_state();
                    return;
                }
                break;
            }
            p++;
        }
    }
    /* Plain text fallback */
    dispatch(buf);
}

void module_destroy(void) {
    save_state();
    hal_log(1, "[maps] destroy", 14);
}

uint32_t module_tick_interval_ms(void) { return 1000; }
