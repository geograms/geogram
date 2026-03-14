/*
 * hello_world — Geogram WASM Module PoC
 *
 * Logs a greeting on init, prints the platform and time each tick,
 * and echoes back any host messages.
 *
 * Build: cd wapps/modules/hello_world && make
 * Expected output: < 16KB .wasm binary
 */

#include "../../hal/geogram_wasm_hal.h"

/* Minimal string helpers (no libc dependency for size) */
static unsigned str_len(const char *s) {
    unsigned n = 0;
    while (s[n]) n++;
    return n;
}

static void log_info(const char *msg) {
    hal_log(1, msg, str_len(msg));
}

static void log_debug(const char *msg) {
    hal_log(0, msg, str_len(msg));
}

/* Simple uint64 to decimal string */
static unsigned u64_to_str(uint64_t v, char *buf, unsigned buf_len) {
    char tmp[21];
    unsigned i = 0;
    if (v == 0) {
        tmp[i++] = '0';
    } else {
        while (v > 0 && i < 20) {
            tmp[i++] = '0' + (char)(v % 10);
            v /= 10;
        }
    }
    /* reverse into buf */
    unsigned out = 0;
    while (i > 0 && out < buf_len - 1) {
        buf[out++] = tmp[--i];
    }
    buf[out] = '\0';
    return out;
}

static uint32_t tick_count = 0;

void module_init(void) {
    log_info("[hello_world] module_init called");

    /* Log platform */
    char plat[32];
    uint32_t plen = hal_platform(plat, sizeof(plat) - 1);
    plat[plen] = '\0';

    char msg[64] = "  platform: ";
    unsigned mlen = str_len(msg);
    for (unsigned i = 0; i < plen && mlen < sizeof(msg) - 1; i++) {
        msg[mlen++] = plat[i];
    }
    msg[mlen] = '\0';
    log_info(msg);

    /* Log heap */
    uint32_t heap = hal_heap_free();
    char hbuf[64] = "  heap_free: ";
    unsigned hlen = str_len(hbuf);
    hlen += u64_to_str(heap, hbuf + hlen, sizeof(hbuf) - hlen);
    log_info(hbuf);
}

void module_tick(void) {
    tick_count++;

    /* Build tick message: "tick #N at Tms" */
    char buf[80] = "[hello_world] tick #";
    unsigned len = str_len(buf);
    len += u64_to_str(tick_count, buf + len, sizeof(buf) - len);

    const char *at = " at ";
    for (unsigned i = 0; at[i] && len < sizeof(buf) - 1; i++) {
        buf[len++] = at[i];
    }

    uint64_t ms = hal_time_ms();
    len += u64_to_str(ms, buf + len, sizeof(buf) - len);

    const char *suffix = "ms";
    for (unsigned i = 0; suffix[i] && len < sizeof(buf) - 1; i++) {
        buf[len++] = suffix[i];
    }
    buf[len] = '\0';
    log_debug(buf);
}

void module_handle_event(void) {
    char buf[256];
    uint32_t avail = hal_msg_available();
    if (avail == 0) return;

    uint32_t n = hal_msg_recv(buf, sizeof(buf) - 1);
    if (n == 0) return;
    buf[n] = '\0';

    /* Echo it back with prefix */
    char reply[300] = "{\"echo\":\"";
    unsigned rlen = str_len(reply);
    for (unsigned i = 0; i < n && rlen < sizeof(reply) - 3; i++) {
        /* Escape quotes in JSON */
        if (buf[i] == '"') {
            if (rlen < sizeof(reply) - 4) {
                reply[rlen++] = '\\';
                reply[rlen++] = '"';
            }
        } else {
            reply[rlen++] = buf[i];
        }
    }
    reply[rlen++] = '"';
    reply[rlen++] = '}';
    reply[rlen] = '\0';
    hal_msg_send(reply, rlen);
}

void module_destroy(void) {
    log_info("[hello_world] module_destroy called — goodbye!");
}

uint32_t module_tick_interval_ms(void) {
    return 5000; /* tick every 5 seconds */
}
