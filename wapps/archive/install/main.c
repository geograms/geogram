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

/* Forward declaration — defined later next to the sources state. */
static void send_sources_list(void);

/* ── Catalog entry ───────────────────────────────────────────────────── */

#define MAX_ENTRIES 64

typedef struct {
    char name[64];              /* folder name, e.g. "maps" */
    char id[128];               /* manifest id */
    char version[32];
    char description[128];
    char file[128];             /* relative path, e.g. "maps/maps-1.0.0.wapp" */
    uint32_t size;
    char source_raw[256];       /* the raw source URL/path this came from */
    char source_host[96];       /* extracted host part (or "local" for files) */
    char publisher_npub[80];    /* optional — from index.json, empty if unsigned */
} CatalogEntry;

static CatalogEntry catalog[MAX_ENTRIES];
static int catalog_count = 0;

/* ── Source config ───────────────────────────────────────────────────── */

/* Multi-source support: the Settings tab hands us a newline-separated
 * list of repositories (URLs or local paths). The wapp stores the raw
 * buffer in KV under the same "source" key used by the old
 * single-source build — the extra newlines are ignored by any older
 * consumer. A `list`/`refresh` command fetches each source sequentially
 * using a small state machine, accumulating catalog entries across
 * every source. */

#define MAX_SOURCES 16
#define SOURCES_RAW_CAP 4096

static char sources_raw[SOURCES_RAW_CAP] = "";
static char sources[MAX_SOURCES][256];
static int source_count = 0;

/* Current fetch state for the multi-source queue. */
static int fetching_idx = -1;           /* -1 = idle */
static char fetch_current_src[256] = "";
static char fetch_current_host[96] = "";

static int source_str_is_url(const char *s) {
    return str_starts(s, "http://") || str_starts(s, "https://");
}

/* Extract a short human-readable host label from a source string.
 * For URLs, this is the hostname (before any port / path). For file
 * paths, we use the literal string "local" so cards have something
 * to display. */
static void extract_host(const char *src, char *host, unsigned host_len) {
    const char *p = src;
    if (str_starts(p, "https://")) p += 8;
    else if (str_starts(p, "http://")) p += 7;
    else {
        str_copy(host, "local", host_len);
        return;
    }
    unsigned i = 0;
    while (*p && *p != '/' && *p != ':' && i < host_len - 1) {
        host[i++] = *p++;
    }
    host[i] = '\0';
    if (i == 0) str_copy(host, "local", host_len);
}

/* Parse the newline-separated sources_raw into the sources[] array. */
static void parse_sources_raw(void) {
    source_count = 0;
    const char *p = sources_raw;
    while (*p && source_count < MAX_SOURCES) {
        while (*p == '\n' || *p == '\r' || *p == ' ' || *p == '\t') p++;
        if (!*p) break;
        unsigned i = 0;
        while (*p && *p != '\n' && *p != '\r' && i < 255) {
            sources[source_count][i++] = *p++;
        }
        /* trim trailing whitespace */
        while (i > 0 && (sources[source_count][i - 1] == ' ' ||
                         sources[source_count][i - 1] == '\t')) {
            i--;
        }
        sources[source_count][i] = '\0';
        if (i > 0) source_count++;
    }
}

static void load_sources(void) {
    uint32_t n = hal_kv_get("source", 6, sources_raw, sizeof(sources_raw) - 1);
    if (n > 0) sources_raw[n] = '\0';
    else sources_raw[0] = '\0';
    parse_sources_raw();
}

static void save_sources(void) {
    hal_kv_set("source", 6, sources_raw, str_len(sources_raw));
    parse_sources_raw();
}

/* Emit the current sources[] list as a structured message so the
 * host can render a proper list UI (instead of guessing the state by
 * parsing text logs). Format:
 *   {"type":"store.sources","sources":["url1","url2",...]}
 * Sent on module_init and after every save_sources() call so the
 * settings tab stays in sync across add / remove cycles. */
static void send_sources_list(void) {
    char buf[SOURCES_RAW_CAP + 128];
    str_copy(buf, "{\"type\":\"store.sources\",\"sources\":[", sizeof(buf));
    unsigned len = str_len(buf);
    for (int i = 0; i < source_count; i++) {
        if (i > 0 && len < sizeof(buf) - 2) { buf[len++] = ','; }
        if (len < sizeof(buf) - 2) { buf[len++] = '"'; }
        for (unsigned j = 0; sources[i][j] && len < sizeof(buf) - 8; j++) {
            char c = sources[i][j];
            if (c == '"')      { buf[len++] = '\\'; buf[len++] = '"'; }
            else if (c == '\\'){ buf[len++] = '\\'; buf[len++] = '\\'; }
            else               { buf[len++] = c; }
        }
        if (len < sizeof(buf) - 2) { buf[len++] = '"'; }
    }
    if (len < sizeof(buf) - 3) { buf[len++] = ']'; buf[len++] = '}'; }
    buf[len] = '\0';
    hal_msg_send(buf, len);
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

/* Parse index.json buffer and APPEND entries to catalog[]. Each
 * appended entry is tagged with the current fetch's source_raw and
 * source_host so the host can render per-origin chips on the store
 * cards. The multi-source state machine calls this once per fetched
 * index and then advances to the next source without resetting
 * catalog_count — the caller resets the count only when a new
 * `list`/`refresh` command fires. */
static void parse_index(const char *json, unsigned json_len) {
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

        /* Zero the whole entry so leftover bytes from a previous
         * list don't leak into the new one. */
        for (unsigned i = 0; i < sizeof(*e); i++) ((char *)e)[i] = 0;

        json_find_str(obj_start, obj_end, "file", e->file, sizeof(e->file));
        json_find_str(obj_start, obj_end, "id", e->id, sizeof(e->id));
        json_find_str(obj_start, obj_end, "version", e->version, sizeof(e->version));
        json_find_str(obj_start, obj_end, "description", e->description, sizeof(e->description));
        json_find_str(obj_start, obj_end, "size", size_str, sizeof(size_str));
        json_find_str(obj_start, obj_end, "publisher_npub", e->publisher_npub, sizeof(e->publisher_npub));

        e->size = (uint32_t)str_to_int(size_str);
        extract_name(e->file, e->name, sizeof(e->name));
        str_copy(e->source_raw, fetch_current_src, sizeof(e->source_raw));
        str_copy(e->source_host, fetch_current_host, sizeof(e->source_host));

        if (e->name[0] && e->version[0]) {
            catalog_count++;
        }
    }
}

/* Forward declarations */
static void show_catalog(void);
static void advance_fetch_queue(void);

/* ── Fetch index ─────────────────────────────────────────────────────── */

/* Pending HTTP request for async fetch. */
static int32_t pending_req = -1;
static char index_buf[8192];

/* Kick off the fetch for sources[fetching_idx]. For URL sources the
 * HTTP request is started via hal_http and polled from module_tick.
 * For local paths we delegate to the host via a
 * {"type":"wapp.fetch_index",...} message and the response lands in
 * module_handle_event as `wapp.index`. Either way, on completion
 * advance_fetch_queue() is invoked to move to the next source. */
static void start_current_fetch(void) {
    if (fetching_idx < 0 || fetching_idx >= source_count) return;
    const char *src = sources[fetching_idx];
    str_copy(fetch_current_src, src, sizeof(fetch_current_src));
    extract_host(src, fetch_current_host, sizeof(fetch_current_host));

    char msg[256] = "Fetching ";
    str_cat(msg, fetch_current_host, sizeof(msg));
    str_cat(msg, "...", sizeof(msg));
    send_output(msg, "info");

    if (source_str_is_url(src)) {
        char url[600] = "";
        str_cat(url, src, sizeof(url));
        unsigned slen = str_len(src);
        if (slen < 5 || !str_eq(src + slen - 5, ".json")) {
            if (src[slen - 1] != '/') str_cat(url, "/", sizeof(url));
            str_cat(url, "index.json", sizeof(url));
        }
        pending_req = hal_http_request(0, url, str_len(url), "", 0);
        if (pending_req < 0) {
            send_output("  failed to start HTTP request", "err");
            advance_fetch_queue();
        }
    } else {
        char m[700] = "{\"type\":\"wapp.fetch_index\",\"source\":\"";
        str_cat(m, src, sizeof(m));
        str_cat(m, "\"}", sizeof(m));
        hal_msg_send(m, str_len(m));
    }
}

/* Called after a source's response is fully parsed (success or skip).
 * Moves to the next source in the queue, or finalises the catalog
 * display when every source has been consulted. */
static void advance_fetch_queue(void) {
    fetching_idx++;
    if (fetching_idx >= source_count) {
        fetching_idx = -1;
        show_catalog();
        return;
    }
    start_current_fetch();
}

/* Entry point for the `list`/`refresh` command. Wipes the catalog
 * and starts walking the sources[] array. */
static void begin_fetch_all(void) {
    if (source_count == 0) {
        send_output("No repositories configured. Add at least one URL or path in Settings.", "err");
        return;
    }
    catalog_count = 0;
    fetching_idx = 0;
    start_current_fetch();
}

/* ── Display ─────────────────────────────────────────────────────────── */

static void show_catalog(void) {
    if (catalog_count == 0) {
        send_output("No wapps found across the configured repositories.", "info");
        return;
    }

    char hdr[32];
    u64_to_str((uint64_t)catalog_count, hdr, sizeof(hdr));
    char msg[96] = "";
    str_cat(msg, hdr, sizeof(msg));
    str_cat(msg, " wapp(s) available across ", sizeof(msg));
    char src_hdr[16];
    u64_to_str((uint64_t)source_count, src_hdr, sizeof(src_hdr));
    str_cat(msg, src_hdr, sizeof(msg));
    str_cat(msg, " repo(s):", sizeof(msg));
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

        /* Source host chip: "    @host.example.com" */
        if (e->source_host[0]) {
            char host_line[160] = "    @";
            str_cat(host_line, e->source_host, sizeof(host_line));
            send_output(host_line, "out");
        }

        /* Publisher chip: "    by:npub1..." */
        if (e->publisher_npub[0]) {
            char pub_line[128] = "    by:";
            str_cat(pub_line, e->publisher_npub, sizeof(pub_line));
            send_output(pub_line, "out");
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

    /* Build install message for the renderer. The source is whatever
     * repository THIS entry came from, not a global — that way a
     * multi-repo catalog can still install each wapp from its own
     * origin without the user needing to toggle sources.
     *   {"type":"wapp.install","source":"<source>","file":"<file>",
     *    "name":"<name>","version":"<version>"} */
    char msg[1024] = "{\"type\":\"wapp.install\",\"source\":\"";
    str_cat(msg, e->source_raw, sizeof(msg));
    str_cat(msg, "\",\"file\":\"", sizeof(msg));
    str_cat(msg, e->file, sizeof(msg));
    str_cat(msg, "\",\"name\":\"", sizeof(msg));
    str_cat(msg, e->name, sizeof(msg));
    str_cat(msg, "\",\"version\":\"", sizeof(msg));
    str_cat(msg, e->version, sizeof(msg));
    str_cat(msg, "\"}", sizeof(msg));
    hal_msg_send(msg, str_len(msg));

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
    send_output("Wapp Store commands:", "info");
    send_output("  sources            List configured repositories", "out");
    send_output("  list               Fetch all repos and show catalog", "out");
    send_output("  install <name>     Install a wapp", "out");
    send_output("  update [name]      Update one or all wapps", "out");
    send_output("  remove <name>      Remove a wapp", "out");
    send_output("  installed          Show installed wapps", "out");
    send_output("  help               Show this help", "out");
}

static void dispatch(const char *input) {
    char cmd[32];
    const char *args = next_word(input, cmd, sizeof(cmd));
    (void)args;

    if (cmd[0] == '\0') return;

    if (str_eq(cmd, "help")) {
        cmd_help();
    }
    else if (str_eq(cmd, "sources") || str_eq(cmd, "source")) {
        if (source_count == 0) {
            send_output("No repositories configured. Add them in Settings.", "err");
            return;
        }
        char hdr[32];
        u64_to_str((uint64_t)source_count, hdr, sizeof(hdr));
        char msg[64] = "";
        str_cat(msg, hdr, sizeof(msg));
        str_cat(msg, " repositories:", sizeof(msg));
        send_output(msg, "info");
        for (int i = 0; i < source_count; i++) {
            char line[320] = "  ";
            str_cat(line, sources[i], sizeof(line));
            send_output(line, "out");
        }
    }
    else if (str_eq(cmd, "list") || str_eq(cmd, "refresh")) {
        begin_fetch_all();
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
    load_sources();
    send_sources_list();

    send_output("Wapp Store v2.0", "info");
    if (source_count > 0) {
        begin_fetch_all();
    } else {
        send_output("No repositories configured.", "info");
        send_output("Open Settings to add a URL or local path.", "info");
    }
}

void module_tick(void) {
    /* Check for pending HTTP response */
    if (pending_req >= 0) {
        int32_t status = hal_http_poll(pending_req);
        if (status == 0) return; /* still pending */

        if (status < 0) {
            char msg[96] = "HTTP request failed for ";
            str_cat(msg, fetch_current_host, sizeof(msg));
            send_output(msg, "err");
            hal_http_free(pending_req);
            pending_req = -1;
            advance_fetch_queue();
            return;
        }

        int32_t code = hal_http_status(pending_req);
        if (code < 200 || code >= 300) {
            char msg[96] = "HTTP error ";
            char code_buf[16];
            u64_to_str((uint64_t)(code > 0 ? code : 0), code_buf, sizeof(code_buf));
            str_cat(msg, code_buf, sizeof(msg));
            str_cat(msg, " from ", sizeof(msg));
            str_cat(msg, fetch_current_host, sizeof(msg));
            send_output(msg, "err");
            hal_http_free(pending_req);
            pending_req = -1;
            advance_fetch_queue();
            return;
        }

        int32_t n = hal_http_read_response(pending_req, index_buf,
                                            sizeof(index_buf) - 1);
        hal_http_free(pending_req);
        pending_req = -1;

        if (n <= 0) {
            send_output("  empty response", "err");
            advance_fetch_queue();
            return;
        }
        index_buf[n] = '\0';
        parse_index(index_buf, (unsigned)n);
        advance_fetch_queue();
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

                if (str_eq(action, "set_sources")) {
                    /* The host already validated each URL and hands
                     * us a pre-joined newline-separated list in the
                     * "source" field. The value is a JSON string
                     * that may contain escaped newlines (\\n); un-
                     * escape those back to real newlines before
                     * persisting. */
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
                            unsigned si = 0;
                            while (*q && *q != '"' &&
                                   si < sizeof(sources_raw) - 1) {
                                if (*q == '\\' && *(q + 1)) {
                                    q++;
                                    if (*q == 'n') sources_raw[si++] = '\n';
                                    else if (*q == 't') sources_raw[si++] = '\t';
                                    else if (*q == 'r') sources_raw[si++] = '\r';
                                    else sources_raw[si++] = *q;
                                    q++;
                                } else {
                                    sources_raw[si++] = *q++;
                                }
                            }
                            sources_raw[si] = '\0';
                            save_sources();
                            send_sources_list();
                            if (source_count > 0) {
                                begin_fetch_all();
                            } else {
                                catalog_count = 0;
                                show_catalog();
                            }
                            return;
                        }
                        q++;
                    }
                    /* save with no source field → just ack */
                    send_sources_list();
                    return;
                }
                return;
            }
            p++;
        }

        /* Check for wapp.installed confirmation from renderer */
        {
            const char *inst_key = "\"wapp.installed\"";
            const char *ip = buf;
            while (*ip) {
                int im = 1;
                unsigned ikl = str_len(inst_key);
                for (unsigned ii = 0; ii < ikl; ii++) {
                    if (ip[ii] != inst_key[ii]) { im = 0; break; }
                }
                if (im) {
                    /* Extract name and version */
                    char iname[64] = "", iver[32] = "";
                    json_find_str(buf, buf + n, "name", iname, sizeof(iname));
                    json_find_str(buf, buf + n, "version", iver, sizeof(iver));
                    if (iname[0] && iver[0]) {
                        set_installed_version(iname, iver);
                    }
                    return;
                }
                ip++;
            }
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
                        }
                        advance_fetch_queue();
                        return;
                    }
                    dq++;
                }
                advance_fetch_queue();
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
