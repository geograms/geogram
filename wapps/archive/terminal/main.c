/*
 * terminal — Geogram WASM Terminal Module
 *
 * Receives commands via hal_msg_recv(), parses and executes them using
 * HAL file/kv/http/system calls, and sends output back via hal_msg_send().
 *
 * Build: cd wapps/archive/terminal && make
 */

#include "../../hal/geogram_wasm_hal.h"

/* ── Helpers ─────────────────────────────────────────────────────────── */

static unsigned str_len(const char *s) {
    unsigned n = 0;
    while (s[n]) n++;
    return n;
}

static int str_eq(const char *a, const char *b) {
    while (*a && *b && *a == *b) { a++; b++; }
    return *a == *b;
}

static int str_neq(const char *a, const char *b, unsigned n) {
    for (unsigned i = 0; i < n; i++) {
        if (a[i] != b[i]) return 0;
        if (a[i] == '\0') return 1;
    }
    return 1;
}

static void str_copy(char *dst, const char *src, unsigned max) {
    unsigned i = 0;
    while (i < max - 1 && src[i]) { dst[i] = src[i]; i++; }
    dst[i] = '\0';
}

static void str_cat(char *dst, const char *src, unsigned max) {
    unsigned dlen = str_len(dst);
    unsigned i = 0;
    while (dlen + i < max - 1 && src[i]) { dst[dlen + i] = src[i]; i++; }
    dst[dlen + i] = '\0';
}

static unsigned u64_to_str(uint64_t v, char *buf, unsigned buf_len) {
    char tmp[21];
    unsigned i = 0;
    if (v == 0) { tmp[i++] = '0'; }
    else { while (v > 0 && i < 20) { tmp[i++] = '0' + (char)(v % 10); v /= 10; } }
    unsigned out = 0;
    while (i > 0 && out < buf_len - 1) buf[out++] = tmp[--i];
    buf[out] = '\0';
    return out;
}

/* ── Output ──────────────────────────────────────────────────────────── */

/* Send a JSON output message to the UI renderer.
 * level: "out" (normal), "err" (error), "cmd" (echoed command), "info" */
static void send_output(const char *text, const char *level) {
    char buf[2048] = "{\"type\":\"ui.append\",\"target\":\"output-list\",\"item\":{\"text\":\"";
    unsigned len = str_len(buf);

    /* Escape text for JSON */
    for (unsigned i = 0; text[i] && len < sizeof(buf) - 40; i++) {
        if (text[i] == '"')       { buf[len++] = '\\'; buf[len++] = '"'; }
        else if (text[i] == '\\') { buf[len++] = '\\'; buf[len++] = '\\'; }
        else if (text[i] == '\n') { buf[len++] = '\\'; buf[len++] = 'n'; }
        else if (text[i] == '\t') { buf[len++] = '\\'; buf[len++] = 't'; }
        else                      { buf[len++] = text[i]; }
    }

    str_copy(buf + len, "\",\"level\":\"", sizeof(buf) - len);
    len = str_len(buf);
    str_cat(buf + len, level, sizeof(buf) - len);
    len = str_len(buf);
    str_copy(buf + len, "\"}}", sizeof(buf) - len);
    len = str_len(buf);

    hal_msg_send(buf, len);
}

static void log_info(const char *msg) { hal_log(1, msg, str_len(msg)); }

/* ── CWD state ───────────────────────────────────────────────────────── */

static char cwd[512] = "/";

static void load_cwd(void) {
    uint32_t n = hal_kv_get("cwd", 3, cwd, sizeof(cwd) - 1);
    if (n > 0) { cwd[n] = '\0'; }
    else       { str_copy(cwd, "/", sizeof(cwd)); }
}

static void save_cwd(void) {
    hal_kv_set("cwd", 3, cwd, str_len(cwd));
}

/* ── Command handlers ────────────────────────────────────────────────── */

static const char *skip_spaces(const char *s) {
    while (*s == ' ' || *s == '\t') s++;
    return s;
}

/* Get first word and return pointer to rest */
static const char *next_word(const char *s, char *word, unsigned max) {
    s = skip_spaces(s);
    unsigned i = 0;
    while (*s && *s != ' ' && *s != '\t' && i < max - 1) word[i++] = *s++;
    word[i] = '\0';
    return s;
}

static void cmd_help(void) {
    send_output("Built-in commands:", "info");
    send_output("  help           Show this help", "out");
    send_output("  clear          Clear output", "out");
    send_output("  echo <text>    Print text", "out");
    send_output("  pwd            Print working directory", "out");
    send_output("  cd <dir>       Change directory", "out");
    send_output("  ls [path]      List directory", "out");
    send_output("  cat <file>     Show file contents", "out");
    send_output("  touch <file>   Create empty file", "out");
    send_output("  write <f> <t>  Write text to file", "out");
    send_output("  rm <file>      Delete file", "out");
    send_output("  mkdir <dir>    Create directory", "out");
    send_output("  stat <path>    File info", "out");
    send_output("  kv.get <key>   Read from KV store", "out");
    send_output("  kv.set <k> <v> Write to KV store", "out");
    send_output("  kv.del <key>   Delete from KV store", "out");
    send_output("  kv.list [pfx]  List KV keys", "out");
    send_output("  date           Current timestamp", "out");
    send_output("  uptime         Milliseconds since start", "out");
    send_output("  platform       Host platform", "out");
    send_output("  heap           Free heap bytes", "out");
    send_output("  fetch <url>    HTTP GET request", "out");
    send_output("  ping <host>    HTTP HEAD to host", "out");
}

static void cmd_echo(const char *args) {
    args = skip_spaces(args);
    send_output(*args ? args : "", "out");
}

static void cmd_pwd(void) {
    send_output(cwd, "out");
}

static void cmd_cd(const char *args) {
    char dir[256];
    next_word(args, dir, sizeof(dir));
    if (dir[0] == '\0' || str_eq(dir, "/")) {
        str_copy(cwd, "/", sizeof(cwd));
    } else if (str_eq(dir, "..")) {
        /* Go up one level */
        unsigned len = str_len(cwd);
        if (len > 1) {
            while (len > 1 && cwd[len - 1] == '/') len--;
            while (len > 1 && cwd[len - 1] != '/') len--;
            if (len == 0) len = 1;
            cwd[len] = '\0';
        }
    } else if (dir[0] == '/') {
        str_copy(cwd, dir, sizeof(cwd));
    } else {
        if (cwd[str_len(cwd) - 1] != '/') str_cat(cwd, "/", sizeof(cwd));
        str_cat(cwd, dir, sizeof(cwd));
    }
    save_cwd();
    send_output(cwd, "out");
}

static void cmd_cat(const char *args) {
    char path[256];
    next_word(args, path, sizeof(path));
    if (path[0] == '\0') { send_output("cat: missing operand", "err"); return; }

    int32_t fd = hal_file_open(path, str_len(path), 0);
    if (fd < 0) { send_output("cat: cannot open file", "err"); return; }

    char buf[1024];
    int32_t n;
    while ((n = hal_file_read(fd, buf, sizeof(buf) - 1)) > 0) {
        buf[n] = '\0';
        send_output(buf, "out");
    }
    hal_file_close(fd);
}

static void cmd_touch(const char *args) {
    char path[256];
    next_word(args, path, sizeof(path));
    if (path[0] == '\0') { send_output("touch: missing operand", "err"); return; }

    int32_t fd = hal_file_open(path, str_len(path), 1);
    if (fd < 0) { send_output("touch: cannot create file", "err"); return; }
    hal_file_close(fd);
}

static void cmd_write(const char *args) {
    char path[256];
    const char *rest = next_word(args, path, sizeof(path));
    rest = skip_spaces(rest);
    if (path[0] == '\0' || *rest == '\0') {
        send_output("write: usage: write <file> <text>", "err");
        return;
    }

    int32_t fd = hal_file_open(path, str_len(path), 1);
    if (fd < 0) { send_output("write: cannot open file", "err"); return; }
    hal_file_write(fd, rest, str_len(rest));
    hal_file_close(fd);
    send_output("ok", "out");
}

static void cmd_rm(const char *args) {
    char path[256];
    next_word(args, path, sizeof(path));
    if (path[0] == '\0') { send_output("rm: missing operand", "err"); return; }

    /* Try deleting as a KV key (file HAL has no delete yet) */
    int32_t fd = hal_file_open(path, str_len(path), 0);
    if (fd < 0) { send_output("rm: no such file", "err"); return; }
    hal_file_close(fd);
    /* Write empty to signal deletion — host handles it */
    fd = hal_file_open(path, str_len(path), 1);
    if (fd >= 0) hal_file_close(fd);
    send_output("ok", "out");
}

static void cmd_kv_get(const char *args) {
    char key[128];
    next_word(args, key, sizeof(key));
    if (key[0] == '\0') { send_output("kv.get: missing key", "err"); return; }

    char val[1024];
    uint32_t n = hal_kv_get(key, str_len(key), val, sizeof(val) - 1);
    if (n == 0) { send_output("(not found)", "err"); return; }
    val[n] = '\0';
    send_output(val, "out");
}

static void cmd_kv_set(const char *args) {
    char key[128];
    const char *rest = next_word(args, key, sizeof(key));
    rest = skip_spaces(rest);
    if (key[0] == '\0' || *rest == '\0') {
        send_output("kv.set: usage: kv.set <key> <value>", "err");
        return;
    }
    int32_t rc = hal_kv_set(key, str_len(key), rest, str_len(rest));
    send_output(rc == 0 ? "ok" : "kv.set: failed", rc == 0 ? "out" : "err");
}

static void cmd_kv_del(const char *args) {
    char key[128];
    next_word(args, key, sizeof(key));
    if (key[0] == '\0') { send_output("kv.del: missing key", "err"); return; }

    int32_t rc = hal_kv_delete(key, str_len(key));
    send_output(rc == 0 ? "ok" : "(not found)", rc == 0 ? "out" : "err");
}

static void cmd_kv_list(const char *args) {
    char prefix[128] = "";
    next_word(args, prefix, sizeof(prefix));

    char buf[2048];
    uint32_t count = hal_kv_list(prefix, str_len(prefix), buf, sizeof(buf) - 1);
    if (count == 0) { send_output("(no keys)", "out"); return; }

    /* Keys are null-separated */
    char num[16];
    u64_to_str(count, num, sizeof(num));
    char hdr[32] = "";
    str_cat(hdr, num, sizeof(hdr));
    str_cat(hdr, " key(s):", sizeof(hdr));
    send_output(hdr, "info");

    char *p = buf;
    for (uint32_t i = 0; i < count; i++) {
        send_output(p, "out");
        while (*p) p++;
        p++; /* skip null */
    }
}

static void cmd_date(void) {
    uint64_t epoch = hal_time_epoch();
    char buf[32];
    if (epoch == 0) {
        send_output("(no RTC)", "err");
    } else {
        u64_to_str(epoch, buf, sizeof(buf));
        char msg[64] = "epoch: ";
        str_cat(msg, buf, sizeof(msg));
        send_output(msg, "out");
    }
}

static void cmd_uptime(void) {
    uint64_t ms = hal_time_ms();
    char buf[32];
    u64_to_str(ms, buf, sizeof(buf));
    char msg[64] = "";
    str_cat(msg, buf, sizeof(msg));
    str_cat(msg, " ms", sizeof(msg));
    send_output(msg, "out");
}

static void cmd_platform(void) {
    char buf[64];
    uint32_t n = hal_platform(buf, sizeof(buf) - 1);
    buf[n] = '\0';
    send_output(buf, "out");
}

static void cmd_heap(void) {
    uint32_t free = hal_heap_free();
    char buf[32];
    u64_to_str(free, buf, sizeof(buf));
    char msg[64] = "";
    str_cat(msg, buf, sizeof(msg));
    str_cat(msg, " bytes free", sizeof(msg));
    send_output(msg, "out");
}

static void cmd_fetch(const char *args) {
    char url[512];
    next_word(args, url, sizeof(url));
    if (url[0] == '\0') { send_output("fetch: usage: fetch <url>", "err"); return; }

    int32_t req_id = hal_http_request(0, url, str_len(url), "", 0);
    if (req_id < 0) { send_output("fetch: request failed", "err"); return; }

    /* Poll (blocking for simplicity — ESP32 would use tick) */
    int32_t status;
    for (int i = 0; i < 200; i++) {
        status = hal_http_poll(req_id);
        if (status != 0) break;
        hal_yield();
    }

    if (status < 0) {
        send_output("fetch: request error", "err");
        hal_http_free(req_id);
        return;
    }

    int32_t http_code = hal_http_status(req_id);
    char code_buf[16];
    u64_to_str((uint64_t)(http_code > 0 ? http_code : 0), code_buf, sizeof(code_buf));
    char hdr[32] = "HTTP ";
    str_cat(hdr, code_buf, sizeof(hdr));
    send_output(hdr, "info");

    char body[2048];
    int32_t n = hal_http_read_response(req_id, body, sizeof(body) - 1);
    if (n > 0) {
        body[n] = '\0';
        send_output(body, "out");
    }
    hal_http_free(req_id);
}

static void cmd_ping(const char *args) {
    char host[256];
    next_word(args, host, sizeof(host));
    if (host[0] == '\0') { send_output("ping: usage: ping <host>", "err"); return; }

    /* Build URL: http://host/ */
    char url[320] = "http://";
    str_cat(url, host, sizeof(url));
    str_cat(url, "/", sizeof(url));

    uint64_t start = hal_time_ms();
    int32_t req_id = hal_http_request(0, url, str_len(url), "", 0);
    if (req_id < 0) { send_output("ping: request failed", "err"); return; }

    int32_t status;
    for (int i = 0; i < 200; i++) {
        status = hal_http_poll(req_id);
        if (status != 0) break;
        hal_yield();
    }

    uint64_t elapsed = hal_time_ms() - start;
    int32_t http_code = hal_http_status(req_id);
    hal_http_free(req_id);

    char msg[128] = "";
    str_cat(msg, host, sizeof(msg));
    str_cat(msg, ": ", sizeof(msg));
    if (status < 0) {
        str_cat(msg, "unreachable", sizeof(msg));
        send_output(msg, "err");
    } else {
        char code_buf[16], time_buf[16];
        u64_to_str((uint64_t)(http_code > 0 ? http_code : 0), code_buf, sizeof(code_buf));
        u64_to_str(elapsed, time_buf, sizeof(time_buf));
        str_cat(msg, "HTTP ", sizeof(msg));
        str_cat(msg, code_buf, sizeof(msg));
        str_cat(msg, " (", sizeof(msg));
        str_cat(msg, time_buf, sizeof(msg));
        str_cat(msg, "ms)", sizeof(msg));
        send_output(msg, "out");
    }
}

/* ── Command dispatch ────────────────────────────────────────────────── */

static void dispatch(const char *input) {
    char cmd[64];
    const char *args = next_word(input, cmd, sizeof(cmd));

    if (cmd[0] == '\0') return;

    /* Echo the command */
    char echo[300] = "$ ";
    str_cat(echo, input, sizeof(echo));
    send_output(echo, "cmd");

    if      (str_eq(cmd, "help"))     cmd_help();
    else if (str_eq(cmd, "echo"))     cmd_echo(args);
    else if (str_eq(cmd, "pwd"))      cmd_pwd();
    else if (str_eq(cmd, "cd"))       cmd_cd(args);
    else if (str_eq(cmd, "cat"))      cmd_cat(args);
    else if (str_eq(cmd, "touch"))    cmd_touch(args);
    else if (str_eq(cmd, "write"))    cmd_write(args);
    else if (str_eq(cmd, "rm"))       cmd_rm(args);
    else if (str_eq(cmd, "kv.get"))   cmd_kv_get(args);
    else if (str_eq(cmd, "kv.set"))   cmd_kv_set(args);
    else if (str_eq(cmd, "kv.del"))   cmd_kv_del(args);
    else if (str_eq(cmd, "kv.list"))  cmd_kv_list(args);
    else if (str_eq(cmd, "date"))     cmd_date();
    else if (str_eq(cmd, "uptime"))   cmd_uptime();
    else if (str_eq(cmd, "platform")) cmd_platform();
    else if (str_eq(cmd, "heap"))     cmd_heap();
    else if (str_eq(cmd, "fetch"))    cmd_fetch(args);
    else if (str_eq(cmd, "ping"))     cmd_ping(args);
    else {
        char msg[128] = "";
        str_cat(msg, cmd, sizeof(msg));
        str_cat(msg, ": command not found. Type 'help' for available commands.", sizeof(msg));
        send_output(msg, "err");
    }
}

/* ── Module entry points ─────────────────────────────────────────────── */

void module_init(void) {
    log_info("[terminal] init");
    load_cwd();
    send_output("Geogram Terminal v1.0", "info");
    send_output("Type 'help' for available commands.", "info");
}

void module_tick(void) {
    /* Nothing periodic — all work happens in module_handle_event */
}

void module_handle_event(void) {
    char buf[2048];
    uint32_t avail = hal_msg_available();
    if (avail == 0) return;

    uint32_t n = hal_msg_recv(buf, sizeof(buf) - 1);
    if (n == 0) return;
    buf[n] = '\0';

    /* Messages from the UI are JSON: {"command":"..."} or plain text */
    /* For simplicity, check if it starts with { and extract command field */
    if (buf[0] == '{') {
        /* Find "command":" */
        const char *key = "\"command\":\"";
        const char *p = buf;
        while (*p) {
            if (str_neq(p, key, str_len(key))) {
                p += str_len(key);
                char cmd[2048];
                unsigned i = 0;
                while (*p && *p != '"' && i < sizeof(cmd) - 1) {
                    if (*p == '\\' && *(p + 1)) { p++; cmd[i++] = *p++; }
                    else { cmd[i++] = *p++; }
                }
                cmd[i] = '\0';
                dispatch(cmd);
                return;
            }
            p++;
        }
    }
    /* Plain text fallback */
    dispatch(buf);
}

void module_destroy(void) {
    log_info("[terminal] destroy");
}

uint32_t module_tick_interval_ms(void) {
    return 500;
}
