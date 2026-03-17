/**
 * @file aprs_store.c
 * @brief APRS message store — circular buffer with beacon deduplication
 */

#include <string.h>
#include <stdio.h>
#include <time.h>
#include "aprs_store.h"
#include "mesh_chat.h"
#include "esp_log.h"
#include "esp_random.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"

static const char *TAG = "aprs_store";

static aprs_message_t *s_messages = NULL;  // Heap-allocated circular buffer
static size_t s_count = 0;       // Number of occupied slots
static size_t s_head = 0;        // Next write position (circular)
static uint32_t s_next_id = 1;   // Monotonic counter
static uint32_t s_total_rx = 0;  // Total RX (including dedup'd beacons)
static uint32_t s_total_tx = 0;  // Total TX
static char s_epoch_prefix = 'A'; // Random letter chosen at init — changes on reflash
static SemaphoreHandle_t s_mutex = NULL;
static aprs_store_rx_notify_cb_t s_rx_notify_cb = NULL;
static void *s_rx_notify_ctx = NULL;

/**
 * @brief Check if a "to" field looks like a generic APRS path (beacon indicator)
 */
static bool is_generic_destination(const char *to)
{
    if (!to || to[0] == '\0') return true;

    // Common generic APRS destinations
    if (strncmp(to, "APRS", 4) == 0) return true;   // APRS, APxxxx (digi IDs)
    if (strncmp(to, "AP", 2) == 0) return true;      // AP* device type IDs
    if (strncmp(to, "BEACON", 6) == 0) return true;
    if (strncmp(to, "CQ", 2) == 0) return true;
    if (strncmp(to, "QST", 3) == 0) return true;
    if (strncmp(to, "WIDE", 4) == 0) return true;    // WIDE1-1, WIDE2-1, etc.
    if (strncmp(to, "RELAY", 5) == 0) return true;
    if (strncmp(to, "TRACE", 5) == 0) return true;

    return false;
}

/**
 * @brief Get current unix timestamp (seconds)
 */
static uint32_t get_timestamp(void)
{
    time_t now;
    time(&now);
    return (uint32_t)now;
}

/**
 * @brief Find an existing beacon entry matching from+message for deduplication
 * @return Index into s_messages or -1 if not found
 */
static int find_beacon_match(const char *from, const char *message)
{
    for (size_t i = 0; i < s_count; i++) {
        aprs_message_t *m = &s_messages[i];
        if (!m->is_beacon) continue;
        if (strcmp(m->from, from) != 0) continue;
        if (strcmp(m->message, message) != 0) continue;
        return (int)i;
    }
    return -1;
}

/**
 * @brief Store a new message in the circular buffer
 */
static aprs_message_t *store_new_entry(void)
{
    aprs_message_t *slot = &s_messages[s_head];
    s_head = (s_head + 1) % APRS_STORE_MAX_MESSAGES;
    if (s_count < APRS_STORE_MAX_MESSAGES) {
        s_count++;
    }
    memset(slot, 0, sizeof(*slot));
    return slot;
}

esp_err_t aprs_store_init(void)
{
    s_mutex = xSemaphoreCreateMutex();
    if (!s_mutex) {
        ESP_LOGE(TAG, "Failed to create mutex");
        return ESP_ERR_NO_MEM;
    }

    size_t alloc_size = sizeof(aprs_message_t) * APRS_STORE_MAX_MESSAGES;
    s_messages = calloc(APRS_STORE_MAX_MESSAGES, sizeof(aprs_message_t));
    if (!s_messages) {
        ESP_LOGE(TAG, "Failed to allocate %u bytes for APRS store", (unsigned)alloc_size);
        vSemaphoreDelete(s_mutex);
        s_mutex = NULL;
        return ESP_ERR_NO_MEM;
    }

    s_count = 0;
    s_head = 0;
    s_next_id = 1;
    s_total_rx = 0;
    s_total_tx = 0;
    s_epoch_prefix = (char)('A' + (esp_random() % 26));

    ESP_LOGI(TAG, "APRS store initialized (epoch %c, max %d messages, %u bytes)",
             s_epoch_prefix, APRS_STORE_MAX_MESSAGES, (unsigned)alloc_size);
    return ESP_OK;
}

void aprs_store_add_rx(const char *from, const char *to,
                       const char *message, const char *raw_tnc2)
{
    if (!s_mutex) return;
    xSemaphoreTake(s_mutex, portMAX_DELAY);

    s_total_rx++;
    uint32_t now = get_timestamp();
    bool is_beacon = is_generic_destination(to);

    // Beacon deduplication: same from + same message content
    if (is_beacon && message && message[0] != '\0') {
        int idx = find_beacon_match(from, message);
        if (idx >= 0) {
            // Update existing beacon entry
            aprs_message_t *existing = &s_messages[idx];
            existing->beacon_count++;
            existing->last_seen = now;
            existing->id = s_next_id++;  // Bump ID so it appears "new" to polling clients

            ESP_LOGD(TAG, "Beacon dedup: %s (count=%lu)",
                     from, (unsigned long)existing->beacon_count);
            xSemaphoreGive(s_mutex);
            return;
        }
    }

    // New message
    aprs_message_t *slot = store_new_entry();
    slot->id = s_next_id++;
    slot->timestamp = now;
    slot->is_beacon = is_beacon;
    slot->beacon_count = 1;
    slot->last_seen = now;
    slot->is_outgoing = false;

    if (from) {
        strncpy(slot->from, from, APRS_MAX_CALLSIGN_LEN - 1);
        slot->from[APRS_MAX_CALLSIGN_LEN - 1] = '\0';
    }
    if (to) {
        strncpy(slot->to, to, APRS_MAX_CALLSIGN_LEN - 1);
        slot->to[APRS_MAX_CALLSIGN_LEN - 1] = '\0';
    }
    if (message) {
        strncpy(slot->message, message, APRS_MAX_MESSAGE_LEN - 1);
        slot->message[APRS_MAX_MESSAGE_LEN - 1] = '\0';
    }
    if (raw_tnc2) {
        strncpy(slot->raw, raw_tnc2, APRS_MAX_RAW_LEN - 1);
        slot->raw[APRS_MAX_RAW_LEN - 1] = '\0';
    }
    ESP_LOGI(TAG, "RX: %s -> %s: %.40s%s",
             slot->from, slot->to, slot->message,
             strlen(slot->message) > 40 ? "..." : "");

    xSemaphoreGive(s_mutex);
}

void aprs_store_add_tx(const char *from, const char *to, const char *message)
{
    if (!s_mutex) return;
    xSemaphoreTake(s_mutex, portMAX_DELAY);

    s_total_tx++;
    uint32_t now = get_timestamp();

    aprs_message_t *slot = store_new_entry();
    slot->id = s_next_id++;
    slot->timestamp = now;
    slot->is_beacon = false;
    slot->beacon_count = 0;
    slot->last_seen = now;
    slot->is_outgoing = true;

    if (from) {
        strncpy(slot->from, from, APRS_MAX_CALLSIGN_LEN - 1);
        slot->from[APRS_MAX_CALLSIGN_LEN - 1] = '\0';
    }
    if (to) {
        strncpy(slot->to, to, APRS_MAX_CALLSIGN_LEN - 1);
        slot->to[APRS_MAX_CALLSIGN_LEN - 1] = '\0';
    }
    if (message) {
        strncpy(slot->message, message, APRS_MAX_MESSAGE_LEN - 1);
        slot->message[APRS_MAX_MESSAGE_LEN - 1] = '\0';
    }

    ESP_LOGI(TAG, "TX: %s -> %s: %s", slot->from, slot->to, slot->message);

    xSemaphoreGive(s_mutex);
}

size_t aprs_store_get_messages(aprs_message_t *out, size_t max, uint32_t since_id)
{
    if (!s_mutex || !out || max == 0) return 0;
    xSemaphoreTake(s_mutex, portMAX_DELAY);

    size_t written = 0;
    for (size_t i = 0; i < s_count && written < max; i++) {
        if (s_messages[i].id > since_id) {
            out[written++] = s_messages[i];
        }
    }

    xSemaphoreGive(s_mutex);
    return written;
}

uint32_t aprs_store_get_latest_id(void)
{
    if (!s_mutex) return 0;
    xSemaphoreTake(s_mutex, portMAX_DELAY);
    uint32_t id = (s_next_id > 1) ? s_next_id - 1 : 0;
    xSemaphoreGive(s_mutex);
    return id;
}

size_t aprs_store_get_count(void)
{
    if (!s_mutex) return 0;
    xSemaphoreTake(s_mutex, portMAX_DELAY);
    size_t count = s_count;
    xSemaphoreGive(s_mutex);
    return count;
}

/**
 * @brief Escape a string for JSON output
 * @return Number of bytes written (not including null terminator)
 */
static size_t json_escape(char *dst, size_t dst_size, const char *src)
{
    size_t written = 0;
    for (const char *p = src; *p && written < dst_size - 1; p++) {
        switch (*p) {
            case '"':
            case '\\':
                if (written + 2 > dst_size - 1) goto done;
                dst[written++] = '\\';
                dst[written++] = *p;
                break;
            case '\n':
                if (written + 2 > dst_size - 1) goto done;
                dst[written++] = '\\';
                dst[written++] = 'n';
                break;
            case '\r':
                if (written + 2 > dst_size - 1) goto done;
                dst[written++] = '\\';
                dst[written++] = 'r';
                break;
            case '\t':
                if (written + 2 > dst_size - 1) goto done;
                dst[written++] = '\\';
                dst[written++] = 't';
                break;
            default:
                if ((unsigned char)*p < 0x20) {
                    // Skip other control chars
                } else {
                    dst[written++] = *p;
                }
                break;
        }
    }
done:
    dst[written] = '\0';
    return written;
}

size_t aprs_store_build_json(char *buffer, size_t size, uint32_t since_id)
{
    if (!s_mutex || !buffer || size < 2) return 0;
    xSemaphoreTake(s_mutex, portMAX_DELAY);

    uint32_t latest_id = (s_next_id > 1) ? s_next_id - 1 : 0;
    size_t msg_count = 0;

    // Count matching messages first
    for (size_t i = 0; i < s_count; i++) {
        if (s_messages[i].id > since_id) msg_count++;
    }

    int offset = snprintf(buffer, size,
        "{\"epoch\":\"%c\",\"latest_id\":\"%c%lu\",\"count\":%d,\"messages\":[",
        s_epoch_prefix, s_epoch_prefix,
        (unsigned long)latest_id, (int)msg_count);

    if (offset < 0 || (size_t)offset >= size) {
        xSemaphoreGive(s_mutex);
        return 0;
    }

    bool first = true;
    char esc_from[APRS_MAX_CALLSIGN_LEN * 2];
    char esc_to[APRS_MAX_CALLSIGN_LEN * 2];
    char esc_msg[APRS_MAX_MESSAGE_LEN * 2];
    char esc_raw[APRS_MAX_RAW_LEN * 2];

    for (size_t i = 0; i < s_count; i++) {
        aprs_message_t *m = &s_messages[i];
        if (m->id <= since_id) continue;

        json_escape(esc_from, sizeof(esc_from), m->from);
        json_escape(esc_to, sizeof(esc_to), m->to);
        json_escape(esc_msg, sizeof(esc_msg), m->message);
        json_escape(esc_raw, sizeof(esc_raw), m->raw);

        int n = snprintf(buffer + offset, size - offset,
            "%s{\"id\":\"%c%lu\",\"timestamp\":%lu,"
            "\"from\":\"%s\",\"to\":\"%s\","
            "\"message\":\"%s\","
            "\"raw\":\"%s\","
            "\"beacon\":%s,\"beacon_count\":%lu,"
            "\"outgoing\":%s}",
            first ? "" : ",",
            s_epoch_prefix, (unsigned long)m->id,
            (unsigned long)m->timestamp,
            esc_from, esc_to,
            esc_msg,
            esc_raw,
            m->is_beacon ? "true" : "false",
            (unsigned long)m->beacon_count,
            m->is_outgoing ? "true" : "false");

        if (n < 0 || offset + n >= (int)size - 2) {
            // Buffer full, stop adding messages
            break;
        }
        offset += n;
        first = false;
    }

    offset += snprintf(buffer + offset, size - offset, "]}");

    xSemaphoreGive(s_mutex);
    return (size_t)offset;
}

void aprs_store_rx_callback(const char *from, const char *to,
                            const char *message, const char *raw_tnc2,
                            void *ctx)
{
    (void)ctx;
    aprs_store_add_rx(from, to, message, raw_tnc2);

    // Bridge into mesh_chat so RX APRS messages appear in the unified chat
    if (message && message[0] != '\0') {
        mesh_chat_add_local_message_with_timestamp(from, message, 0, MESH_CHAT_CH_APRS);
    }

    // Fire RX notify hook (e.g. BLE push)
    if (s_rx_notify_cb) {
        s_rx_notify_cb(from, to, message, s_rx_notify_ctx);
    }
}

uint32_t aprs_store_get_total_rx(void)
{
    if (!s_mutex) return 0;
    xSemaphoreTake(s_mutex, portMAX_DELAY);
    uint32_t val = s_total_rx;
    xSemaphoreGive(s_mutex);
    return val;
}

uint32_t aprs_store_get_total_tx(void)
{
    if (!s_mutex) return 0;
    xSemaphoreTake(s_mutex, portMAX_DELAY);
    uint32_t val = s_total_tx;
    xSemaphoreGive(s_mutex);
    return val;
}

char aprs_store_get_epoch(void)
{
    return s_epoch_prefix;
}

void aprs_store_parse_id(const char *str, char *epoch, uint32_t *id)
{
    *epoch = '\0';
    *id = 0;
    if (!str || str[0] == '\0') return;

    if (str[0] >= 'A' && str[0] <= 'Z') {
        *epoch = str[0];
        *id = (uint32_t)strtoul(str + 1, NULL, 10);
    } else {
        *id = (uint32_t)strtoul(str, NULL, 10);
    }
}

void aprs_store_set_rx_notify(aprs_store_rx_notify_cb_t cb, void *ctx)
{
    s_rx_notify_cb = cb;
    s_rx_notify_ctx = ctx;
}
