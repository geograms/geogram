/*
 * install — Geogram Wapp Installer / Shop
 *
 * Reads index.json from a configured source (URL or local path),
 * displays available wapps with versions, and sends install/remove
 * requests to the renderer.
 *
 * Commands:
 *   source [url|path]   Get/set repository source
 *   list / refresh      Fetch index and show available wapps
 *   install <name>      Install or update a wapp
 *   remove <name>       Remove an installed wapp
 *   installed           Show installed wapps
 *   update [name]       Update one or all outdated wapps
 *   help                Show this help
 *
 * The renderer handles the actual download and installation when it
 * receives a {"type":"wapp.install",...} or {"type":"wapp.remove",...}
 * message.
 *
 * Build: cd wapps/archive/install && make
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

static int str_starts(const char *s, const char *prefix) {
    while (*prefix) {
        if (*s != *prefix) return 0;
        s++; prefix++;
    }
    return 1;
}

static void str_copy(char *d, const char *s, unsigned m) {
    unsigned i = 0;
    while (i < m - 1 && s[i]) { d[i] = s[i]; i++; }
    d[i] = '\0';
}

static void str_cat(char *d, const char *s, unsigned m) {
    unsigned l = str_len(d);
    unsigned i = 0;
    while (l + i < m - 1 && s[i]) { d[l + i] = s[i]; i++; }
    d[l + i] = '\0';
}

static const char *skip_spaces(const char *s) {
    while (*s == ' ' || *s == '\t') s++;
    return s;
}

static const char *next_word(const char *s, char *w, unsigned m) {
    s = skip_spaces(s);
    unsigned i = 0;
    while (*s && *s != ' ' && *s != '\t' && i < m - 1) w[i++] = *s++;
    w[i] = '\0';
    return s;
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

static void send_output(const char *text, const char *level) {
    char buf[1024] = "{\"type\":\"ui.append\",\"target\":\"output-list\",\"item\":{\"text\":\"";
    unsigned len = str_len(buf);
    for (unsigned i = 0; text[i] && len < sizeof(buf) - 40; i++) {
        if (text[i] == '"')       { buf[len++] = '\\'; buf[len++] = '"'; }
        else if (text[i] == '\\') { buf[len++] = '\\'; buf[len++] = '\\'; }
        else if (text[i] == '\n') { buf[len++] = '\\'; buf[len++] = 'n'; }
        else                      { buf[len++] = text[i]; }
    }
    str_copy(buf + len, "\",\"level\":\"", sizeof(buf) - len); len = str_len(buf);
    str_cat(buf + len, level, sizeof(buf) - len); len = str_len(buf);
    str_copy(buf + len, "\"}}", sizeof(buf) - len); len = str_len(buf);
    hal_msg_send(buf, len);
}

/* ── Catalog entry ───────────────────────────────────────────────────── */

#define MAX_ENTRIES 32

typedef struct {
    char name[64];         /* folder name, e.g. "maps" */
    char id[128];          /* manifest id */
    char version[32];
    char description[128];
    char file[128];        /* relative path, e.g. "maps/maps-1.0.0.wapp" */
    uint32_t size;
} CatalogEntry;

static CatalogEntry catalog[MAX_ENTRIES];
static int catalog_count = 0;

/* ── Source config ───────────────────────────────────────────────────── */

static char source[512] = "";

static int source_is_url(void) {
    return str_starts(source, "http://") || str_starts(source, "https://");
}

static void load_source(void) {
    uint32_t n = hal_kv_get("source", 6, source, sizeof(source) - 1);
    if (n > 0) source[n] = '\0';
    else source[0] = '\0';
}

static void save_source(void) {
    hal_kv_set("source", 6, source, str_len(source));
}

/* ── Installed versions (stored in KV as "inst:<name>" = "<version>") ─ */

static void get_installed_version(const char *name, char *ver, unsigned ver_len) {
    char key[80] = "inst:";
    str_cat(key, name, sizeof(key));
    uint32_t n = hal_kv_get(key, str_len(key), ver, ver_len - 1);
    if (n > 0) ver[n] = '\0';
    else ver[0] = '\0';
}

static void set_installed_version(const char *name, const char *ver) {
    char key[80] = "inst:";
    str_cat(key, name, sizeof(key));
    hal_kv_set(key, str_len(key), ver, str_len(ver));
}

static void remove_installed_version(const char *name) {
    char key[80] = "inst:";
    str_cat(key, name, sizeof(key));
    hal_kv_delete(key, str_len(key));
}

/* ── Minimal JSON parsing for index.json ─────────────────────────────
 *
 * Expected format:
 * [
 *   {"file":"maps/maps-1.0.0.wapp","id":"...","version":"1.0.0",
 *    "size":7767,"description":"..."},
 *   ...
 * ]
 */

/* Find value for a string key in a JSON object substring.
 * Writes value into val (unquoted for strings, raw for numbers).
 * Returns pointer past the value, or NULL if not found. */
static const char *json_find_str(const char *obj, const char *obj_end,
                                  const char *key, char *val, unsigned val_len) {
    unsigned klen = str_len(key);
    val[0] = '\0';
    const char *p = obj;
    while (p < obj_end) {
        /* Look for "key" */
        if (*p == '"') {
            int match = 1;
            for (unsigned i = 0; i < klen; i++) {
                if (p[1 + i] != key[i]) { match = 0; break; }
            }
            if (match && p[1 + klen] == '"') {
                /* Found key, skip to colon and value */
                p += 2 + klen;
                while (p < obj_end && *p != ':') p++;
                if (p >= obj_end) return 0;
                p++; /* skip colon */
                while (p < obj_end && (*p == ' ' || *p == '\t')) p++;
                if (*p == '"') {
                    /* String value */
                    p++;
                    unsigned vi = 0;
                    while (p < obj_end && *p != '"' && vi < val_len - 1) {
                        val[vi++] = *p++;
                    }
                    val[vi] = '\0';
                    return p;
                } else {
                    /* Number or other */
                    unsigned vi = 0;
                    while (p < obj_end && *p != ',' && *p != '}' && *p != ' '
                           && vi < val_len - 1) {
                        val[vi++] = *p++;
                    }
                    val[vi] = '\0';
                    return p;
                }
            }
        }
        p++;
    }
    return 0;
}

/* Extract folder name from file path: "maps/maps-1.0.0.wapp" -> "maps" */
static void extract_name(const char *file, char *name, unsigned name_len) {
    unsigned i = 0;
    while (file[i] && file[i] != '/' && i < name_len - 1) {
        name[i] = file[i];
        i++;
    }
    name[i] = '\0';
}

static int str_to_int(const char *s) {
    int v = 0;
    while (*s >= '0' && *s <= '9') { v = v * 10 + (*s - '0'); s++; }
    return v;
}

/* Parse index.json buffer into catalog[]. */
static void parse_index(const char *json, unsigned json_len) {
    catalog_count = 0;
    const char *end = json + json_len;
    const char *p = json;

    while (p < end && catalog_count < MAX_ENTRIES) {
        /* Find next object start */
        while (p < end && *p != '{') p++;
        if (p >= end) break;
        const char *obj_start = p;

        /* Find matching close brace */
        int depth = 0;
        while (p < end) {
            if (*p == '{') depth++;
            else if (*p == '}') { depth--; if (depth == 0) { p++; break; } }
            p++;
        }
        const char *obj_end = p;

        CatalogEntry *e = &catalog[catalog_count];
        char size_str[16] = "";

        json_find_str(obj_start, obj_end, "file", e->file, sizeof(e->file));
        json_find_str(obj_start, obj_end, "id", e->id, sizeof(e->id));
        json_find_str(obj_start, obj_end, "version", e->version, sizeof(e->version));
        json_find_str(obj_start, obj_end, "description", e->description, sizeof(e->description));
        json_find_str(obj_start, obj_end, "size", size_str, sizeof(size_str));

        e->size = (uint32_t)str_to_int(size_str);
        extract_name(e->file, e->name, sizeof(e->name));

        if (e->name[0] && e->version[0]) {
            catalog_count++;
        }
    }
}

/* Forward declarations */
static void show_catalog(void);

/* ── Fetch index ─────────────────────────────────────────────────────── */

/* Pending HTTP request for async fetch. */
static int32_t pending_req = -1;

static void fetch_index_url(void) {
    char url[600] = "";
    str_cat(url, source, sizeof(url));
    /* Append /index.json if source doesn't end with .json */
    unsigned slen = str_len(source);
    if (slen < 5 || !str_eq(source + slen - 5, ".json")) {
        if (source[slen - 1] != '/') str_cat(url, "/", sizeof(url));
        str_cat(url, "index.json", sizeof(url));
    }

    send_output("Fetching catalog...", "info");
    pending_req = hal_http_request(0, url, str_len(url), "", 0);
    if (pending_req < 0) {
        send_output("Failed to start HTTP request.", "err");
    }
}

static char index_buf[8192];

static void fetch_index_file(void) {
    /* Local file access is sandboxed — ask the renderer to read the
     * index and send it back as a {"type":"wapp.index","data":"..."} message. */
    char msg[700] = "{\"type\":\"wapp.fetch_index\",\"source\":\"";
    str_cat(msg, source, sizeof(msg));
    str_cat(msg, "\"}", sizeof(msg));
    hal_msg_send(msg, str_len(msg));
    send_output("Loading catalog...", "info");
}

/* ── Display ─────────────────────────────────────────────────────────── */

static void show_catalog(void) {
    if (catalog_count == 0) {
        send_output("No wapps found in catalog.", "info");
        return;
    }

    char hdr[32];
    u64_to_str((uint64_t)catalog_count, hdr, sizeof(hdr));
    char msg[64] = "";
    str_cat(msg, hdr, sizeof(msg));
    str_cat(msg, " wapp(s) available:", sizeof(msg));
    send_output(msg, "info");

    for (int i = 0; i < catalog_count; i++) {
        CatalogEntry *e = &catalog[i];
        char inst_ver[32];
        get_installed_version(e->name, inst_ver, sizeof(inst_ver));

        char line[384] = "  ";
        str_cat(line, e->name, sizeof(line));

        /* Pad name to 16 chars */
        unsigned pad = str_len(line);
        while (pad < 18) { line[pad++] = ' '; line[pad] = '\0'; }

        str_cat(line, "v", sizeof(line));
        str_cat(line, e->version, sizeof(line));

        /* Size */
        char sz[16];
        if (e->size >= 1024) {
            u64_to_str((uint64_t)(e->size / 1024), sz, sizeof(sz));
            str_cat(line, "  (", sizeof(line));
            str_cat(line, sz, sizeof(line));
            str_cat(line, "KB)", sizeof(line));
        }

        /* Status */
        if (inst_ver[0]) {
            if (str_eq(inst_ver, e->version)) {
                str_cat(line, "  [installed]", sizeof(line));
            } else {
                str_cat(line, "  [update: ", sizeof(line));
                str_cat(line, inst_ver, sizeof(line));
                str_cat(line, " -> ", sizeof(line));
                str_cat(line, e->version, sizeof(line));
                str_cat(line, "]", sizeof(line));
            }
        }

        send_output(line, "out");

        /* Description on next line */
        if (e->description[0]) {
            char desc[200] = "    ";
            str_cat(desc, e->description, sizeof(desc));
            send_output(desc, "out");
        }
    }
}

/* ── Find catalog entry by name ──────────────────────────────────────── */

static CatalogEntry *find_entry(const char *name) {
    for (int i = 0; i < catalog_count; i++) {
        if (str_eq(catalog[i].name, name)) return &catalog[i];
    }
    return 0;
}

/* ── Install / remove / update ───────────────────────────────────────── */

static void do_install(const char *name) {
    CatalogEntry *e = find_entry(name);
    if (!e) {
        char msg[128] = "Not in catalog: ";
        str_cat(msg, name, sizeof(msg));
        str_cat(msg, ". Run 'list' first.", sizeof(msg));
        send_output(msg, "err");
        return;
    }

    /* Build install message for the renderer:
     * {"type":"wapp.install","source":"<source>","file":"<file>",
     *  "name":"<name>","version":"<version>"} */
    char msg[1024] = "{\"type\":\"wapp.install\",\"source\":\"";
    str_cat(msg, source, sizeof(msg));
    str_cat(msg, "\",\"file\":\"", sizeof(msg));
    str_cat(msg, e->file, sizeof(msg));
    str_cat(msg, "\",\"name\":\"", sizeof(msg));
    str_cat(msg, e->name, sizeof(msg));
    str_cat(msg, "\",\"version\":\"", sizeof(msg));
    str_cat(msg, e->version, sizeof(msg));
    str_cat(msg, "\"}", sizeof(msg));
    hal_msg_send(msg, str_len(msg));

    /* Mark as installed */
    set_installed_version(e->name, e->version);

    char out[128] = "Installing ";
    str_cat(out, e->name, sizeof(out));
    str_cat(out, " v", sizeof(out));
    str_cat(out, e->version, sizeof(out));
    str_cat(out, "...", sizeof(out));
    send_output(out, "info");
}

static void do_remove(const char *name) {
    char ver[32];
    get_installed_version(name, ver, sizeof(ver));
    if (!ver[0]) {
        char msg[128] = "Not installed: ";
        str_cat(msg, name, sizeof(msg));
        send_output(msg, "err");
        return;
    }

    /* Send remove message to renderer */
    char msg[256] = "{\"type\":\"wapp.remove\",\"name\":\"";
    str_cat(msg, name, sizeof(msg));
    str_cat(msg, "\"}", sizeof(msg));
    hal_msg_send(msg, str_len(msg));

    remove_installed_version(name);

    char out[128] = "Removed ";
    str_cat(out, name, sizeof(out));
    send_output(out, "info");
}

static void do_update(const char *name) {
    if (catalog_count == 0) {
        send_output("No catalog loaded. Run 'list' first.", "err");
        return;
    }

    if (name[0]) {
        /* Update specific wapp */
        CatalogEntry *e = find_entry(name);
        if (!e) {
            char msg[128] = "Not in catalog: ";
            str_cat(msg, name, sizeof(msg));
            send_output(msg, "err");
            return;
        }
        char inst_ver[32];
        get_installed_version(name, inst_ver, sizeof(inst_ver));
        if (!inst_ver[0]) {
            char msg[128] = "Not installed: ";
            str_cat(msg, name, sizeof(msg));
            str_cat(msg, ". Use 'install' instead.", sizeof(msg));
            send_output(msg, "err");
            return;
        }
        if (str_eq(inst_ver, e->version)) {
            char msg[128] = "";
            str_cat(msg, name, sizeof(msg));
            str_cat(msg, " is already up to date (v", sizeof(msg));
            str_cat(msg, inst_ver, sizeof(msg));
            str_cat(msg, ").", sizeof(msg));
            send_output(msg, "info");
            return;
        }
        do_install(name);
        return;
    }

    /* Update all outdated */
    int updated = 0;
    for (int i = 0; i < catalog_count; i++) {
        CatalogEntry *e = &catalog[i];
        char inst_ver[32];
        get_installed_version(e->name, inst_ver, sizeof(inst_ver));
        if (inst_ver[0] && !str_eq(inst_ver, e->version)) {
            do_install(e->name);
            updated++;
        }
    }
    if (updated == 0) {
        send_output("All installed wapps are up to date.", "info");
    }
}

static void show_installed(void) {
    char buf[2048];
    uint32_t count = hal_kv_list("inst:", 5, buf, sizeof(buf) - 1);
    if (count == 0) {
        send_output("No wapps installed.", "info");
        return;
    }

    char hdr[32];
    u64_to_str((uint64_t)count, hdr, sizeof(hdr));
    char msg[64] = "";
    str_cat(msg, hdr, sizeof(msg));
    str_cat(msg, " wapp(s) installed:", sizeof(msg));
    send_output(msg, "info");

    char *p = buf;
    for (uint32_t i = 0; i < count; i++) {
        /* Key is "inst:<name>", strip prefix */
        const char *name = p + 5; /* skip "inst:" */
        char ver[32];
        get_installed_version(name, ver, sizeof(ver));

        char line[128] = "  ";
        str_cat(line, name, sizeof(line));
        unsigned pad = str_len(line);
        while (pad < 18) { line[pad++] = ' '; line[pad] = '\0'; }
        str_cat(line, "v", sizeof(line));
        str_cat(line, ver, sizeof(line));
        send_output(line, "out");

        while (*p) p++;
        p++;
    }
}

/* ── Command dispatch ────────────────────────────────────────────────── */

static void cmd_help(void) {
    send_output("Wapp Installer commands:", "info");
    send_output("  source [url|path]  Get/set repository source", "out");
    send_output("  list               Fetch catalog and show wapps", "out");
    send_output("  install <name>     Install a wapp", "out");
    send_output("  update [name]      Update one or all wapps", "out");
    send_output("  remove <name>      Remove a wapp", "out");
    send_output("  installed          Show installed wapps", "out");
    send_output("  help               Show this help", "out");
}

static void dispatch(const char *input) {
    char cmd[32];
    const char *args = next_word(input, cmd, sizeof(cmd));

    if (cmd[0] == '\0') return;

    if (str_eq(cmd, "help")) {
        cmd_help();
    }
    else if (str_eq(cmd, "source")) {
        char arg[512];
        next_word(args, arg, sizeof(arg));
        if (arg[0]) {
            str_copy(source, arg, sizeof(source));
            save_source();
            char msg[256] = "Source set to: ";
            str_cat(msg, source, sizeof(msg));
            send_output(msg, "info");
        } else if (source[0]) {
            send_output(source, "out");
        } else {
            send_output("No source configured. Use: source <url-or-path>", "err");
        }
    }
    else if (str_eq(cmd, "list") || str_eq(cmd, "refresh")) {
        if (!source[0]) {
            send_output("No source configured. Use: source <url-or-path>", "err");
            return;
        }
        if (source_is_url()) {
            fetch_index_url();
        } else {
            fetch_index_file();
        }
    }
    else if (str_eq(cmd, "install")) {
        char name[64];
        next_word(args, name, sizeof(name));
        if (!name[0]) { send_output("Usage: install <name>", "err"); return; }
        do_install(name);
    }
    else if (str_eq(cmd, "update")) {
        char name[64];
        next_word(args, name, sizeof(name));
        do_update(name);
    }
    else if (str_eq(cmd, "remove")) {
        char name[64];
        next_word(args, name, sizeof(name));
        if (!name[0]) { send_output("Usage: remove <name>", "err"); return; }
        do_remove(name);
    }
    else if (str_eq(cmd, "installed")) {
        show_installed();
    }
    else {
        char msg[128] = "Unknown command: ";
        str_cat(msg, cmd, sizeof(msg));
        str_cat(msg, ". Type 'help'.", sizeof(msg));
        send_output(msg, "err");
    }
}

/* ── Module entry points ─────────────────────────────────────────────── */

void module_init(void) {
    hal_log(1, "[install] init", 14);
    load_source();

    send_output("Wapp Installer v1.0", "info");
    if (source[0]) {
        char msg[256] = "Source: ";
        str_cat(msg, source, sizeof(msg));
        send_output(msg, "out");
        send_output("Type 'list' to browse available wapps.", "info");
    } else {
        send_output("No source configured.", "info");
        send_output("Use: source <url-or-path-to-index.json-dir>", "info");
    }
}

void module_tick(void) {
    /* Check for pending HTTP response */
    if (pending_req >= 0) {
        int32_t status = hal_http_poll(pending_req);
        if (status == 0) return; /* still pending */

        if (status < 0) {
            send_output("HTTP request failed.", "err");
            hal_http_free(pending_req);
            pending_req = -1;
            return;
        }

        int32_t code = hal_http_status(pending_req);
        if (code < 200 || code >= 300) {
            char msg[64] = "HTTP error: ";
            char code_buf[16];
            u64_to_str((uint64_t)(code > 0 ? code : 0), code_buf, sizeof(code_buf));
            str_cat(msg, code_buf, sizeof(msg));
            send_output(msg, "err");
            hal_http_free(pending_req);
            pending_req = -1;
            return;
        }

        int32_t n = hal_http_read_response(pending_req, index_buf,
                                            sizeof(index_buf) - 1);
        hal_http_free(pending_req);
        pending_req = -1;

        if (n <= 0) {
            send_output("Empty response.", "err");
            return;
        }
        index_buf[n] = '\0';
        parse_index(index_buf, (unsigned)n);
        show_catalog();
    }
}

void module_handle_event(void) {
    char buf[2048];
    if (hal_msg_available() == 0) return;
    uint32_t n = hal_msg_recv(buf, sizeof(buf) - 1);
    if (n == 0) return;
    buf[n] = '\0';

    /* JSON messages: {"command":"..."} or {"type":"action","action":"save","fields":{...}} */
    if (buf[0] == '{') {
        /* Check for action (settings save) */
        const char *action_key = "\"action\":\"";
        const char *p = buf;
        while (*p) {
            int match = 1;
            unsigned akl = str_len(action_key);
            for (unsigned i = 0; i < akl; i++) {
                if (p[i] != action_key[i]) { match = 0; break; }
            }
            if (match) {
                p += akl;
                char action[32];
                unsigned ai = 0;
                while (*p && *p != '"' && ai < sizeof(action) - 1)
                    action[ai++] = *p++;
                action[ai] = '\0';

                if (str_eq(action, "save")) {
                    /* Extract source field from fields object */
                    const char *src_key = "\"source\":\"";
                    const char *q = buf;
                    while (*q) {
                        int m = 1;
                        unsigned skl = str_len(src_key);
                        for (unsigned i = 0; i < skl; i++) {
                            if (q[i] != src_key[i]) { m = 0; break; }
                        }
                        if (m) {
                            q += skl;
                            char new_source[512];
                            unsigned si = 0;
                            while (*q && *q != '"' && si < sizeof(new_source) - 1)
                                new_source[si++] = *q++;
                            new_source[si] = '\0';
                            if (new_source[0]) {
                                str_copy(source, new_source, sizeof(source));
                                save_source();
                                char msg[256] = "Source set to: ";
                                str_cat(msg, source, sizeof(msg));
                                send_output(msg, "info");
                            }
                            return;
                        }
                        q++;
                    }
                }
                return;
            }
            p++;
        }

        /* Check for wapp.index response from renderer */
        const char *idx_key = "\"wapp.index\"";
        const char *tp = buf;
        while (*tp) {
            int tm = 1;
            unsigned tkl = str_len(idx_key);
            for (unsigned ti = 0; ti < tkl; ti++) {
                if (tp[ti] != idx_key[ti]) { tm = 0; break; }
            }
            if (tm) {
                /* Find "data":" and extract the JSON array */
                const char *dk = "\"data\":";
                const char *dq = buf;
                while (*dq) {
                    int dm = 1;
                    unsigned dkl = str_len(dk);
                    for (unsigned di = 0; di < dkl; di++) {
                        if (dq[di] != dk[di]) { dm = 0; break; }
                    }
                    if (dm) {
                        dq += dkl;
                        while (*dq == ' ') dq++;
                        /* The rest until end of outer object is the index JSON */
                        unsigned dlen = str_len(dq);
                        /* Strip trailing } from outer wrapper */
                        if (dlen > 0 && dq[dlen - 1] == '}') dlen--;
                        if (dlen > 0 && dlen < sizeof(index_buf)) {
                            for (unsigned i = 0; i < dlen; i++)
                                index_buf[i] = dq[i];
                            index_buf[dlen] = '\0';
                            parse_index(index_buf, dlen);
                            show_catalog();
                        }
                        return;
                    }
                    dq++;
                }
                return;
            }
            tp++;
        }

        /* Check for command field */
        const char *key = "\"command\":\"";
        p = buf;
        while (*p) {
            int match = 1;
            unsigned kl = str_len(key);
            for (unsigned i = 0; i < kl; i++) {
                if (p[i] != key[i]) { match = 0; break; }
            }
            if (match) {
                p += kl;
                char cmd[512];
                unsigned ci = 0;
                while (*p && *p != '"' && ci < sizeof(cmd) - 1) {
                    if (*p == '\\' && *(p + 1)) { p++; cmd[ci++] = *p++; }
                    else { cmd[ci++] = *p++; }
                }
                cmd[ci] = '\0';
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
    if (pending_req >= 0) {
        hal_http_free(pending_req);
        pending_req = -1;
    }
    hal_log(1, "[install] destroy", 17);
}

uint32_t module_tick_interval_ms(void) { return 500; }
