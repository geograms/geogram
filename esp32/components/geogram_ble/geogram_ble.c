#include "geogram_ble.h"

#include <ctype.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "app_config.h"
#include "cJSON.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "geoblue.h"
#include "mesh_chat.h"
#include "nostr_keys.h"
#include "station.h"

#if BOARD_MODEL == MODEL_KV4P
#include "aprs_store.h"
#include "radio_tx.h"
#endif

#if CONFIG_BT_ENABLED
#include "host/ble_att.h"
#include "host/ble_gap.h"
#include "host/ble_gatt.h"
#include "host/ble_hs.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"
#endif

static const char *TAG = "geogram_ble";

#define GEOGRAM_BLE_SERVICE_UUID16          0xFFE0
#define GEOGRAM_BLE_CHAR_WRITE_UUID16       0xFFF1
#define GEOGRAM_BLE_CHAR_NOTIFY_UUID16      0xFFF2
#define GEOGRAM_BLE_CHAR_STATUS_UUID16      0xFFF3

#define GEOGRAM_BLE_MARKER                  0x3E
#define GEOGRAM_BLE_COMPANY_ID              0xFFFF

// KV4P runs close to heap limits with mesh+radio+BLE active.
// Keep BLE peer buffers lean to preserve at least one stable connection.
#if BOARD_MODEL == MODEL_KV4P
#define GEOGRAM_BLE_MAX_CONNECTIONS         1
#define GEOGRAM_BLE_RX_BUFFER_SIZE          1024
#else
#define GEOGRAM_BLE_MAX_CONNECTIONS         2
#define GEOGRAM_BLE_RX_BUFFER_SIZE          4096
#endif
#define GEOGRAM_BLE_MAX_PATH_LEN            192
#define GEOGRAM_BLE_MAX_QUERY_LEN           192
#define GEOGRAM_BLE_MAX_ROOM_LEN            48
#define GEOGRAM_BLE_MAX_AUTHOR_LEN          24
#define GEOGRAM_BLE_MAX_MESSAGE_LEN         MESH_CHAT_MAX_MESSAGE_LEN
#define GEOGRAM_BLE_MAX_NOTIFY_CHUNK        180
// Avoid large heap allocations on low-memory boards (KV4P).
#define GEOGRAM_BLE_CHAT_FETCH_MAX          2
#define GEOGRAM_BLE_CHAT_JSON_MAX_LEN       1024

#define GEOBLUE_TEST_CAP_REVERSE            "geoblue_reverse_unicast_test"
#define GEOBLUE_CH_UNICAST_TEST             "geoblue_unicast_test"
#define GEOBLUE_CH_REVERSE_TEST             "geoblue_reverse_unicast_test"
#define GEOBLUE_CH_REVERSE_ECHO             "geoblue_reverse_unicast_test_echo"
#define GEOBLUE_CH_REVERSE_RESULT           "geoblue_reverse_unicast_test_result"
#define GEOBLUE_CH_BROADCAST_RECEIPT        "geoblue_broadcast_receipt"
#define GEOBLUE_TEST_PAYLOAD_LEN            1000

typedef struct {
    bool active;
    bool subscribed;
    uint16_t conn_handle;
    char callsign[STATION_CALLSIGN_LEN];
    uint8_t *rx_buffer;
    size_t rx_len;
#if BOARD_MODEL == MODEL_KV4P
    uint32_t aprs_last_tx_ms;  // esp_log_timestamp() of last BLE APRS TX
#endif
} geogram_ble_peer_t;

typedef struct {
    int status_code;
    char *body;
} geogram_ble_api_result_t;

static bool s_initialized = false;
static bool s_running = false;

static uint8_t s_addr_type = 0;
static uint16_t s_write_val_handle = 0;
static uint16_t s_notify_val_handle = 0;
static uint16_t s_status_val_handle = 0;

static geogram_ble_peer_t s_peers[GEOGRAM_BLE_MAX_CONNECTIONS];
static const char *s_geoblue_caps[] = {
    "chat",
    "hello",
    "data",
    "broadcast",
    GEOBLUE_TEST_CAP_REVERSE,
#if BOARD_MODEL == MODEL_KV4P
    "aprs",
#endif
};

#if CONFIG_BT_ENABLED
static const ble_uuid16_t s_service_uuid = BLE_UUID16_INIT(GEOGRAM_BLE_SERVICE_UUID16);
static const ble_uuid16_t s_write_uuid = BLE_UUID16_INIT(GEOGRAM_BLE_CHAR_WRITE_UUID16);
static const ble_uuid16_t s_notify_uuid = BLE_UUID16_INIT(GEOGRAM_BLE_CHAR_NOTIFY_UUID16);
static const ble_uuid16_t s_status_uuid = BLE_UUID16_INIT(GEOGRAM_BLE_CHAR_STATUS_UUID16);
#endif

static void ble_host_task(void *param);
static void ble_advertise_start(void);
static void ble_reset_all_peers(void);
static int ble_notify_json(uint16_t conn_handle, const char *json);

static geogram_ble_peer_t *ble_find_peer(uint16_t conn_handle)
{
    for (size_t i = 0; i < GEOGRAM_BLE_MAX_CONNECTIONS; i++) {
        if (s_peers[i].active && s_peers[i].conn_handle == conn_handle) {
            return &s_peers[i];
        }
    }
    return NULL;
}

static geogram_ble_peer_t *ble_alloc_peer(uint16_t conn_handle)
{
    geogram_ble_peer_t *peer = ble_find_peer(conn_handle);
    if (peer) {
        return peer;
    }

    for (size_t i = 0; i < GEOGRAM_BLE_MAX_CONNECTIONS; i++) {
        if (!s_peers[i].active) {
            memset(&s_peers[i], 0, sizeof(s_peers[i]));
            s_peers[i].rx_buffer = (uint8_t *)malloc(GEOGRAM_BLE_RX_BUFFER_SIZE);
            if (!s_peers[i].rx_buffer) {
                ESP_LOGW(TAG, "Failed to allocate BLE RX buffer");
                memset(&s_peers[i], 0, sizeof(s_peers[i]));
                return NULL;
            }
            s_peers[i].active = true;
            s_peers[i].conn_handle = conn_handle;
            return &s_peers[i];
        }
    }

    return NULL;
}

static void ble_free_peer(uint16_t conn_handle)
{
    geogram_ble_peer_t *peer = ble_find_peer(conn_handle);
    if (!peer) {
        return;
    }
    free(peer->rx_buffer);
    memset(peer, 0, sizeof(*peer));
}

static void ble_reset_all_peers(void)
{
    for (size_t i = 0; i < GEOGRAM_BLE_MAX_CONNECTIONS; i++) {
        free(s_peers[i].rx_buffer);
        memset(&s_peers[i], 0, sizeof(s_peers[i]));
    }
}

static uint8_t ble_compute_device_id(void)
{
    uint8_t mac[6] = {0};
    if (esp_read_mac(mac, ESP_MAC_BT) != ESP_OK) {
        if (esp_read_mac(mac, ESP_MAC_WIFI_STA) != ESP_OK) {
            return 1;
        }
    }

    uint32_t hash = 0;
    for (size_t i = 0; i < sizeof(mac); i++) {
        hash = (hash * 33U) ^ mac[i];
    }

    return (uint8_t)((hash % 15U) + 1U);
}

static const char *ble_station_callsign(void)
{
    const char *callsign = station_get_callsign();
    if (!callsign || callsign[0] == '\0') {
        callsign = "NOCALL";
    }
    return callsign;
}

static char *ble_strdup_local(const char *value)
{
    if (!value) {
        value = "";
    }
    size_t len = strlen(value);
    char *out = (char *)malloc(len + 1);
    if (!out) {
        return NULL;
    }
    memcpy(out, value, len);
    out[len] = '\0';
    return out;
}

static char *ble_json_to_string(cJSON *json)
{
    if (!json) {
        return ble_strdup_local("{}");
    }

    char *printed = cJSON_PrintUnformatted(json);
    if (!printed) {
        return ble_strdup_local("{}");
    }
    return printed;
}

static char *ble_build_status_body(void)
{
    const char *callsign = ble_station_callsign();
    if (!callsign || callsign[0] == '\0') {
        callsign = "ESP32";
    }

    char buffer[192] = {0};
    int written = snprintf(
        buffer,
        sizeof(buffer),
        "{\"service\":\"geogram-esp32\",\"status\":\"online\",\"callsign\":\"%s\",\"board\":\"%s\"}",
        callsign,
        BOARD_NAME
    );
    if (written <= 0 || (size_t)written >= sizeof(buffer)) {
        return ble_strdup_local("{\"status\":\"online\"}");
    }
    return ble_strdup_local(buffer);
}

static bool ble_parse_sha1_hex(const char *hex, uint8_t *out)
{
    if (!hex || strlen(hex) != 40 || !out) {
        return false;
    }

    for (int i = 0; i < 20; i++) {
        char tmp[3] = {hex[i * 2], hex[i * 2 + 1], '\0'};
        char *endptr = NULL;
        long value = strtol(tmp, &endptr, 16);
        if (!endptr || *endptr != '\0' || value < 0 || value > 255) {
            return false;
        }
        out[i] = (uint8_t)value;
    }

    return true;
}

static void ble_add_string_if_not_empty(cJSON *obj, const char *key, const char *value)
{
    if (!obj || !key || !value || value[0] == '\0') {
        return;
    }
    cJSON_AddStringToObject(obj, key, value);
}

static bool ble_payload_has_capability(cJSON *message, const char *capability)
{
    if (!message || !capability || capability[0] == '\0') {
        return false;
    }

    cJSON *payload = cJSON_GetObjectItemCaseSensitive(message, "payload");
    if (!cJSON_IsObject(payload)) {
        return false;
    }

    cJSON *caps = cJSON_GetObjectItemCaseSensitive(payload, "capabilities");
    if (!cJSON_IsArray(caps)) {
        return false;
    }

    cJSON *item = NULL;
    cJSON_ArrayForEach(item, caps) {
        if (cJSON_IsString(item) && item->valuestring &&
            strcmp(item->valuestring, capability) == 0) {
            return true;
        }
    }
    return false;
}

static void ble_build_test_payload(char *out, size_t payload_len)
{
    if (!out || payload_len == 0) {
        return;
    }

    const char *prefix = "GEOBLUE-UNICAST-ROUNDTRIP-";
    size_t pos = 0;

    for (size_t i = 0; prefix[i] != '\0' && pos < payload_len; i++) {
        out[pos++] = prefix[i];
    }

    for (int seg = 1; pos < payload_len; seg++) {
        char token[16] = {0};
        int written = snprintf(token, sizeof(token), "SEG%03d|", seg);
        if (written <= 0) {
            break;
        }
        for (int i = 0; i < written && pos < payload_len; i++) {
            out[pos++] = token[i];
        }
    }

    out[payload_len] = '\0';
}

static void ble_send_reverse_test_data(uint16_t conn_handle, const char *to_callsign)
{
    char payload[GEOBLUE_TEST_PAYLOAD_LEN + 1] = {0};
    ble_build_test_payload(payload, GEOBLUE_TEST_PAYLOAD_LEN);

    char message_id[48] = {0};
    snprintf(message_id, sizeof(message_id), "reverse-%lu", (unsigned long)esp_log_timestamp());

    char *json = geoblue_build_data_frame(
        message_id,
        ble_station_callsign(),
        to_callsign,
        GEOBLUE_CH_REVERSE_TEST,
        payload,
        (int64_t)time(NULL));
    if (!json) {
        return;
    }

    int rc = ble_notify_json(conn_handle, json);
    if (rc != 0) {
        ESP_LOGW(TAG, "reverse test data notify failed (rc=%d)", rc);
    } else {
        ESP_LOGI(TAG, "reverse test data sent (%u bytes)", (unsigned)strlen(payload));
    }
    free(json);
}

static void ble_send_reverse_test_result(uint16_t conn_handle, const char *to_callsign, bool ok)
{
    char message_id[48] = {0};
    snprintf(message_id, sizeof(message_id), "reverse-result-%lu", (unsigned long)esp_log_timestamp());

    const char *result = ok ? "ok" : "mismatch";
    char *json = geoblue_build_data_frame(
        message_id,
        ble_station_callsign(),
        to_callsign,
        GEOBLUE_CH_REVERSE_RESULT,
        result,
        (int64_t)time(NULL));
    if (!json) {
        return;
    }

    int rc = ble_notify_json(conn_handle, json);
    if (rc != 0) {
        ESP_LOGW(TAG, "reverse test result notify failed (rc=%d)", rc);
    }
    free(json);
}

static void ble_send_broadcast_receipt(uint16_t conn_handle,
                                       const char *to_callsign,
                                       const char *content)
{
    if (!to_callsign || to_callsign[0] == '\0' || !content || content[0] == '\0') {
        return;
    }

    char message_id[48] = {0};
    snprintf(message_id, sizeof(message_id), "broadcast-receipt-%lu",
             (unsigned long)esp_log_timestamp());

    char *json = geoblue_build_data_frame(
        message_id,
        ble_station_callsign(),
        to_callsign,
        GEOBLUE_CH_BROADCAST_RECEIPT,
        content,
        (int64_t)time(NULL));
    if (!json) {
        return;
    }

    int rc = ble_notify_json(conn_handle, json);
    if (rc != 0) {
        ESP_LOGW(TAG, "broadcast receipt notify failed (rc=%d)", rc);
    }
    free(json);
}

static cJSON *ble_build_hello_event(void)
{
    cJSON *event = cJSON_CreateObject();
    if (!event) {
        return NULL;
    }

    cJSON_AddNumberToObject(event, "kind", 0);
    cJSON_AddNumberToObject(event, "created_at", (double)time(NULL));

    const char *npub = nostr_keys_get_npub();
    if (npub && npub[0] != '\0') {
        cJSON_AddStringToObject(event, "pubkey", npub);
    } else {
        cJSON_AddStringToObject(event, "pubkey", "");
    }

    cJSON_AddStringToObject(event, "content", "");

    cJSON *tags = cJSON_CreateArray();
    if (!tags) {
        cJSON_Delete(event);
        return NULL;
    }

    cJSON *callsign_tag = cJSON_CreateArray();
    if (callsign_tag) {
        cJSON_AddItemToArray(callsign_tag, cJSON_CreateString("callsign"));
        cJSON_AddItemToArray(callsign_tag, cJSON_CreateString(ble_station_callsign()));
        cJSON_AddItemToArray(tags, callsign_tag);
    }

    cJSON *nickname_tag = cJSON_CreateArray();
    if (nickname_tag) {
        cJSON_AddItemToArray(nickname_tag, cJSON_CreateString("nickname"));
        cJSON_AddItemToArray(nickname_tag, cJSON_CreateString(BOARD_NAME));
        cJSON_AddItemToArray(tags, nickname_tag);
    }

    station_state_t *state = station_get_state();
    if (state && state->has_location) {
        char lat[32] = {0};
        char lon[32] = {0};
        snprintf(lat, sizeof(lat), "%.6f", state->latitude);
        snprintf(lon, sizeof(lon), "%.6f", state->longitude);

        cJSON *lat_tag = cJSON_CreateArray();
        if (lat_tag) {
            cJSON_AddItemToArray(lat_tag, cJSON_CreateString("latitude"));
            cJSON_AddItemToArray(lat_tag, cJSON_CreateString(lat));
            cJSON_AddItemToArray(tags, lat_tag);
        }

        cJSON *lon_tag = cJSON_CreateArray();
        if (lon_tag) {
            cJSON_AddItemToArray(lon_tag, cJSON_CreateString("longitude"));
            cJSON_AddItemToArray(lon_tag, cJSON_CreateString(lon));
            cJSON_AddItemToArray(tags, lon_tag);
        }
    }

    cJSON_AddItemToObject(event, "tags", tags);
    return event;
}

static bool ble_extract_callsign_from_event(cJSON *event, char *out_callsign, size_t out_len)
{
    if (!event || !out_callsign || out_len < 2) {
        return false;
    }

    cJSON *tags = cJSON_GetObjectItemCaseSensitive(event, "tags");
    if (!cJSON_IsArray(tags)) {
        return false;
    }

    cJSON *tag = NULL;
    cJSON_ArrayForEach(tag, tags) {
        if (!cJSON_IsArray(tag) || cJSON_GetArraySize(tag) < 2) {
            continue;
        }

        cJSON *key = cJSON_GetArrayItem(tag, 0);
        cJSON *value = cJSON_GetArrayItem(tag, 1);
        if (cJSON_IsString(key) && cJSON_IsString(value) &&
            key->valuestring && strcmp(key->valuestring, "callsign") == 0 && value->valuestring) {
            strlcpy(out_callsign, value->valuestring, out_len);
            return true;
        }
    }

    return false;
}

static bool ble_is_envelope_message(cJSON *message)
{
    if (!cJSON_IsObject(message)) {
        return false;
    }
    cJSON *version = cJSON_GetObjectItemCaseSensitive(message, "v");
    cJSON *payload = cJSON_GetObjectItemCaseSensitive(message, "payload");
    return cJSON_IsNumber(version) || cJSON_IsObject(payload);
}

static bool ble_query_get_long(const char *query, const char *key, long *value_out)
{
    if (!query || !key || !value_out) {
        return false;
    }

    char copy[GEOGRAM_BLE_MAX_QUERY_LEN] = {0};
    strlcpy(copy, query, sizeof(copy));

    char *saveptr = NULL;
    char *token = strtok_r(copy, "&", &saveptr);
    size_t key_len = strlen(key);

    while (token) {
        if (strncmp(token, key, key_len) == 0 && token[key_len] == '=') {
            char *endptr = NULL;
            long value = strtol(token + key_len + 1, &endptr, 10);
            if (endptr && *endptr == '\0') {
                *value_out = value;
                return true;
            }
        }
        token = strtok_r(NULL, "&", &saveptr);
    }

    return false;
}

static void ble_split_path_query(const char *input, char *path_out, size_t path_len,
                                 char *query_out, size_t query_len)
{
    if (!path_out || path_len == 0) {
        return;
    }

    path_out[0] = '\0';
    if (query_out && query_len > 0) {
        query_out[0] = '\0';
    }

    if (!input || input[0] == '\0') {
        strlcpy(path_out, "/", path_len);
        return;
    }

    char normalized[GEOGRAM_BLE_MAX_PATH_LEN] = {0};
    if (input[0] == '/') {
        strlcpy(normalized, input, sizeof(normalized));
    } else {
        snprintf(normalized, sizeof(normalized), "/%s", input);
    }

    char *prefix_slash = strchr(normalized + 1, '/');
    if (prefix_slash && strncmp(prefix_slash, "/api/", 5) == 0) {
        memmove(normalized, prefix_slash, strlen(prefix_slash) + 1);
    }

    char *query = strchr(normalized, '?');
    if (query) {
        *query = '\0';
        query++;
        if (query_out && query_len > 0) {
            strlcpy(query_out, query, query_len);
        }
    }

    if (normalized[0] == '\0') {
        strlcpy(path_out, "/", path_len);
    } else {
        strlcpy(path_out, normalized, path_len);
    }
}

static size_t ble_split_segments(char *path, char **segments, size_t max_segments)
{
    size_t count = 0;
    char *saveptr = NULL;
    char *token = strtok_r(path, "/", &saveptr);

    while (token && count < max_segments) {
        segments[count++] = token;
        token = strtok_r(NULL, "/", &saveptr);
    }

    return count;
}

static bool ble_is_chat_rooms_path(const char *path)
{
    if (!path) {
        return false;
    }

    return strcmp(path, "/api/chat/rooms") == 0 || strcmp(path, "/api/chat/rooms/") == 0;
}

static bool ble_parse_messages_path(const char *path, char *room_out, size_t room_len)
{
    if (!path || !room_out || room_len == 0) {
        return false;
    }

    room_out[0] = '\0';

    char copy[GEOGRAM_BLE_MAX_PATH_LEN] = {0};
    strlcpy(copy, path, sizeof(copy));

    char *segments[8] = {0};
    size_t count = ble_split_segments(copy, segments, 8);

    if (count == 3 && strcmp(segments[0], "api") == 0 && strcmp(segments[1], "chat") == 0 &&
        strcmp(segments[2], "messages") == 0) {
        strlcpy(room_out, "general", room_len);
        return true;
    }

    if (count == 4 && strcmp(segments[0], "api") == 0 && strcmp(segments[1], "chat") == 0 &&
        strcmp(segments[3], "messages") == 0) {
        strlcpy(room_out, segments[2], room_len);
        return true;
    }

    if (count == 5 && strcmp(segments[0], "api") == 0 && strcmp(segments[1], "chat") == 0 &&
        strcmp(segments[2], "rooms") == 0 && strcmp(segments[4], "messages") == 0) {
        strlcpy(room_out, segments[3], room_len);
        return true;
    }

    return false;
}

static bool ble_parse_files_list_path(const char *path, char *room_out, size_t room_len)
{
    if (!path || !room_out || room_len == 0) {
        return false;
    }

    room_out[0] = '\0';

    char copy[GEOGRAM_BLE_MAX_PATH_LEN] = {0};
    strlcpy(copy, path, sizeof(copy));

    char *segments[8] = {0};
    size_t count = ble_split_segments(copy, segments, 8);

    if (count == 4 && strcmp(segments[0], "api") == 0 && strcmp(segments[1], "chat") == 0 &&
        strcmp(segments[3], "files") == 0) {
        strlcpy(room_out, segments[2], room_len);
        return true;
    }

    if (count == 5 && strcmp(segments[0], "api") == 0 && strcmp(segments[1], "chat") == 0 &&
        strcmp(segments[2], "rooms") == 0 && strcmp(segments[4], "files") == 0) {
        strlcpy(room_out, segments[3], room_len);
        return true;
    }

    return false;
}

static bool ble_parse_files_get_path(const char *path, char *room_out, size_t room_len)
{
    if (!path || !room_out || room_len == 0) {
        return false;
    }

    room_out[0] = '\0';

    char copy[GEOGRAM_BLE_MAX_PATH_LEN] = {0};
    strlcpy(copy, path, sizeof(copy));

    char *segments[10] = {0};
    size_t count = ble_split_segments(copy, segments, 10);

    if (count == 5 && strcmp(segments[0], "api") == 0 && strcmp(segments[1], "chat") == 0 &&
        strcmp(segments[3], "files") == 0) {
        strlcpy(room_out, segments[2], room_len);
        return true;
    }

    if (count == 6 && strcmp(segments[0], "api") == 0 && strcmp(segments[1], "chat") == 0 &&
        strcmp(segments[2], "rooms") == 0 && strcmp(segments[4], "files") == 0) {
        strlcpy(room_out, segments[3], room_len);
        return true;
    }

    return false;
}

static bool ble_extract_message_from_event(cJSON *event,
                                           char *author, size_t author_len,
                                           char *text, size_t text_len,
                                           uint32_t *timestamp)
{
    if (!event || !text || text_len == 0) {
        return false;
    }

    if (author && author_len > 0) {
        ble_extract_callsign_from_event(event, author, author_len);
    }

    cJSON *content = cJSON_GetObjectItemCaseSensitive(event, "content");
    if (cJSON_IsString(content) && content->valuestring) {
        strlcpy(text, content->valuestring, text_len);
    }

    cJSON *created_at = cJSON_GetObjectItemCaseSensitive(event, "created_at");
    if (timestamp && cJSON_IsNumber(created_at) && created_at->valuedouble > 0) {
        *timestamp = (uint32_t)created_at->valuedouble;
    }

    return text[0] != '\0';
}

static cJSON *ble_parse_body_object(cJSON *body_item, bool *borrowed_out)
{
    if (borrowed_out) {
        *borrowed_out = false;
    }

    if (!body_item) {
        return NULL;
    }

    if (cJSON_IsObject(body_item) || cJSON_IsArray(body_item)) {
        cJSON *dup = cJSON_Duplicate(body_item, true);
        if (dup) {
            return dup;
        }

        // Under memory pressure, operate directly on the original request body.
        // Callers must avoid cJSON_Delete on borrowed objects.
        if (borrowed_out) {
            *borrowed_out = true;
        }
        return body_item;
    }

    if (cJSON_IsString(body_item) && body_item->valuestring) {
        return cJSON_Parse(body_item->valuestring);
    }

    return NULL;
}

static geogram_ble_api_result_t ble_api_result_make(int status_code, char *body)
{
    geogram_ble_api_result_t result = {
        .status_code = status_code,
        .body = body,
    };
    if (!result.body) {
        result.body = ble_strdup_local("{}");
    }
    return result;
}

static bool ble_json_buffer_appendf(char *buffer, size_t buffer_len, size_t *pos, const char *fmt, ...)
{
    if (!buffer || buffer_len == 0 || !pos || !fmt || *pos >= buffer_len) {
        return false;
    }

    va_list args;
    va_start(args, fmt);
    int written = vsnprintf(buffer + *pos, buffer_len - *pos, fmt, args);
    va_end(args);

    if (written < 0 || (size_t)written >= (buffer_len - *pos)) {
        return false;
    }

    *pos += (size_t)written;
    return true;
}

static bool ble_json_buffer_append_escaped(char *buffer, size_t buffer_len, size_t *pos, const char *input)
{
    if (!buffer || buffer_len == 0 || !pos) {
        return false;
    }

    if (!input) {
        input = "";
    }

    for (size_t i = 0; input[i] != '\0'; i++) {
        unsigned char c = (unsigned char)input[i];
        const char *replacement = NULL;

        switch (c) {
            case '\"':
                replacement = "\\\"";
                break;
            case '\\':
                replacement = "\\\\";
                break;
            case '\n':
                replacement = "\\n";
                break;
            case '\r':
                replacement = "\\r";
                break;
            case '\t':
                replacement = "\\t";
                break;
            default:
                break;
        }

        if (replacement) {
            if (!ble_json_buffer_appendf(buffer, buffer_len, pos, "%s", replacement)) {
                return false;
            }
        } else if (c >= 0x20) {
            if (*pos + 1 >= buffer_len) {
                return false;
            }
            buffer[*pos] = (char)c;
            (*pos)++;
            buffer[*pos] = '\0';
        }
    }

    return true;
}

static char *ble_build_chat_rooms_body(void)
{
    cJSON *root = cJSON_CreateObject();
    cJSON *rooms = cJSON_CreateArray();
    cJSON *room = cJSON_CreateObject();
    if (!root || !rooms || !room) {
        cJSON_Delete(root);
        cJSON_Delete(rooms);
        cJSON_Delete(room);
        return ble_strdup_local("{\"rooms\":[]}");
    }

    cJSON_AddStringToObject(room, "id", "general");
    cJSON_AddStringToObject(room, "name", "General");
    cJSON_AddStringToObject(room, "description", "Geogram local chat room");
    cJSON_AddStringToObject(room, "type", "public");
    cJSON_AddNumberToObject(room, "memberCount", 1);
    cJSON_AddNumberToObject(room, "messageCount", (double)mesh_chat_get_count());
    cJSON_AddBoolToObject(room, "isJoined", true);

    cJSON_AddItemToArray(rooms, room);
    cJSON_AddItemToObject(root, "rooms", rooms);

    char *out = ble_json_to_string(root);
    cJSON_Delete(root);
    return out;
}

static char *ble_build_chat_messages_body(const char *room, long since_ts, long limit)
{
    size_t max_messages = GEOGRAM_BLE_CHAT_FETCH_MAX;
    if (limit > 0 && (size_t)limit < max_messages) {
        max_messages = (size_t)limit;
    }
    if (max_messages == 0) {
        max_messages = 1;
    }

    uint32_t latest_id = mesh_chat_get_latest_id();
    uint32_t since_id = 0;
    if (latest_id > max_messages) {
        since_id = latest_id - (uint32_t)max_messages;
    }

    mesh_chat_message_t *messages = calloc(max_messages, sizeof(mesh_chat_message_t));
    if (!messages) {
        return ble_strdup_local("{\"messages\":[]}");
    }

    size_t count = mesh_chat_get_history(messages, max_messages, since_id);
    size_t selected_indices[GEOGRAM_BLE_CHAT_FETCH_MAX] = {0};
    size_t selected_count = 0;

    for (size_t i = 0; i < count && selected_count < GEOGRAM_BLE_CHAT_FETCH_MAX; i++) {
        if (since_ts > 0 && (long)messages[i].timestamp <= since_ts) {
            continue;
        }
        selected_indices[selected_count++] = i;
    }

    const char *effective_room = (room && room[0] != '\0') ? room : "general";
    ESP_LOGI(TAG, "chat messages GET room=%s since=%ld limit=%ld history=%u selected=%u",
             effective_room,
             since_ts,
             limit,
             (unsigned)count,
             (unsigned)selected_count);

    size_t start_index = 0;
    if (limit > 0 && selected_count > (size_t)limit) {
        start_index = selected_count - (size_t)limit;
    }

    size_t pos = 0;
    char *response = malloc(GEOGRAM_BLE_CHAT_JSON_MAX_LEN);
    if (!response) {
        free(messages);
        return ble_strdup_local("{\"messages\":[]}");
    }
    response[0] = '\0';

    if (!ble_json_buffer_appendf(response, GEOGRAM_BLE_CHAT_JSON_MAX_LEN, &pos, "{\"messages\":[")) {
        free(messages);
        free(response);
        return ble_strdup_local("{\"messages\":[]}");
    }

    bool first = true;
    for (size_t idx = start_index; idx < selected_count; idx++) {
        const mesh_chat_message_t *msg = &messages[selected_indices[idx]];

        if (!first) {
            if (!ble_json_buffer_appendf(response, GEOGRAM_BLE_CHAT_JSON_MAX_LEN, &pos, ",")) {
                free(messages);
                free(response);
                return ble_strdup_local("{\"messages\":[]}");
            }
        }

        if (!ble_json_buffer_appendf(response, GEOGRAM_BLE_CHAT_JSON_MAX_LEN, &pos,
                                     "{\"id\":\"%lu\",\"content\":\"",
                                     (unsigned long)msg->id)) {
            free(messages);
            free(response);
            return ble_strdup_local("{\"messages\":[]}");
        }
        if (!ble_json_buffer_append_escaped(response, GEOGRAM_BLE_CHAT_JSON_MAX_LEN, &pos, msg->text)) {
            free(messages);
            free(response);
            return ble_strdup_local("{\"messages\":[]}");
        }
        if (!ble_json_buffer_appendf(response, GEOGRAM_BLE_CHAT_JSON_MAX_LEN, &pos,
                                     "\",\"author\":\"")) {
            free(messages);
            free(response);
            return ble_strdup_local("{\"messages\":[]}");
        }
        if (!ble_json_buffer_append_escaped(response, GEOGRAM_BLE_CHAT_JSON_MAX_LEN, &pos, msg->callsign)) {
            free(messages);
            free(response);
            return ble_strdup_local("{\"messages\":[]}");
        }
        if (!ble_json_buffer_appendf(response, GEOGRAM_BLE_CHAT_JSON_MAX_LEN, &pos,
                                     "\",\"timestamp\":%lu,\"isEdited\":false,\"roomId\":\"",
                                     (unsigned long)msg->timestamp)) {
            free(messages);
            free(response);
            return ble_strdup_local("{\"messages\":[]}");
        }
        if (!ble_json_buffer_append_escaped(response, GEOGRAM_BLE_CHAT_JSON_MAX_LEN, &pos, effective_room)) {
            free(messages);
            free(response);
            return ble_strdup_local("{\"messages\":[]}");
        }
        if (!ble_json_buffer_appendf(response, GEOGRAM_BLE_CHAT_JSON_MAX_LEN, &pos, "\"")) {
            free(messages);
            free(response);
            return ble_strdup_local("{\"messages\":[]}");
        }

        if (msg->msg_type == MESH_CHAT_MSG_FILE) {
            char sha1_hex[41] = {0};
            for (int j = 0; j < 20; j++) {
                snprintf(sha1_hex + j * 2, sizeof(sha1_hex) - (j * 2), "%02x", msg->file.sha1[j]);
            }

            if (!ble_json_buffer_appendf(response, GEOGRAM_BLE_CHAT_JSON_MAX_LEN, &pos,
                                         ",\"file\":{\"sha1\":\"%s\",\"name\":\"", sha1_hex)) {
                free(messages);
                free(response);
                return ble_strdup_local("{\"messages\":[]}");
            }
            if (!ble_json_buffer_append_escaped(response, GEOGRAM_BLE_CHAT_JSON_MAX_LEN, &pos,
                                                msg->file.filename)) {
                free(messages);
                free(response);
                return ble_strdup_local("{\"messages\":[]}");
            }
            if (!ble_json_buffer_appendf(response, GEOGRAM_BLE_CHAT_JSON_MAX_LEN, &pos,
                                         "\",\"size\":%lu,\"mime\":\"",
                                         (unsigned long)msg->file.size)) {
                free(messages);
                free(response);
                return ble_strdup_local("{\"messages\":[]}");
            }
            if (!ble_json_buffer_append_escaped(response, GEOGRAM_BLE_CHAT_JSON_MAX_LEN, &pos,
                                                msg->file.mime_type)) {
                free(messages);
                free(response);
                return ble_strdup_local("{\"messages\":[]}");
            }
            if (!ble_json_buffer_appendf(response, GEOGRAM_BLE_CHAT_JSON_MAX_LEN, &pos, "\"}")) {
                free(messages);
                free(response);
                return ble_strdup_local("{\"messages\":[]}");
            }
        }

        if (!ble_json_buffer_appendf(response, GEOGRAM_BLE_CHAT_JSON_MAX_LEN, &pos, "}")) {
            free(messages);
            free(response);
            return ble_strdup_local("{\"messages\":[]}");
        }
        first = false;
    }

    if (!ble_json_buffer_appendf(response, GEOGRAM_BLE_CHAT_JSON_MAX_LEN, &pos,
                                 "],\"latest_id\":%lu,\"room\":\"",
                                 (unsigned long)latest_id)) {
        free(messages);
        free(response);
        return ble_strdup_local("{\"messages\":[]}");
    }
    if (!ble_json_buffer_append_escaped(response, GEOGRAM_BLE_CHAT_JSON_MAX_LEN, &pos, effective_room)) {
        free(messages);
        free(response);
        return ble_strdup_local("{\"messages\":[]}");
    }
    if (!ble_json_buffer_appendf(response, GEOGRAM_BLE_CHAT_JSON_MAX_LEN, &pos, "\"}")) {
        free(messages);
        free(response);
        return ble_strdup_local("{\"messages\":[]}");
    }

    free(messages);
    return response;
}

static geogram_ble_api_result_t ble_handle_chat_message_post(cJSON *body,
                                                              const char *fallback_author,
                                                              const char *room)
{
    char author[GEOGRAM_BLE_MAX_AUTHOR_LEN] = {0};
    char text[GEOGRAM_BLE_MAX_MESSAGE_LEN + 1] = {0};
    uint32_t timestamp = (uint32_t)time(NULL);

    if (fallback_author && fallback_author[0] != '\0') {
        strlcpy(author, fallback_author, sizeof(author));
    }

    bool body_obj_borrowed = false;
    cJSON *body_obj = ble_parse_body_object(body, &body_obj_borrowed);
    if (!body_obj) {
        if (cJSON_IsString(body) && body->valuestring) {
            size_t preview = strlen(body->valuestring);
            if (preview > 180) {
                preview = 180;
            }
            ESP_LOGW(TAG, "chat post: body parse failed, raw body preview: %.*s",
                     (int)preview, body->valuestring);
        } else {
            ESP_LOGW(TAG, "chat post: missing/invalid body (type=%d)",
                     body ? body->type : -1);
        }
    }
    if (body_obj) {
        cJSON *callsign = cJSON_GetObjectItemCaseSensitive(body_obj, "callsign");
        if (cJSON_IsString(callsign) && callsign->valuestring) {
            strlcpy(author, callsign->valuestring, sizeof(author));
        }

        cJSON *client_ts = cJSON_GetObjectItemCaseSensitive(body_obj, "client_ts");
        if (cJSON_IsNumber(client_ts) && client_ts->valuedouble > 0) {
            timestamp = (uint32_t)client_ts->valuedouble;
        }

        cJSON *content = cJSON_GetObjectItemCaseSensitive(body_obj, "text");
        if (!cJSON_IsString(content) || !content->valuestring) {
            content = cJSON_GetObjectItemCaseSensitive(body_obj, "content");
        }
        if (cJSON_IsString(content) && content->valuestring) {
            strlcpy(text, content->valuestring, sizeof(text));
        }

        cJSON *event = cJSON_GetObjectItemCaseSensitive(body_obj, "event");
        if (event) {
            cJSON *event_obj = NULL;
            if (cJSON_IsObject(event)) {
                event_obj = event;
            } else if (cJSON_IsString(event) && event->valuestring) {
                event_obj = cJSON_Parse(event->valuestring);
            }

            if (event_obj) {
                ble_extract_message_from_event(event_obj, author, sizeof(author), text, sizeof(text), &timestamp);
            }

            if (event_obj && event_obj != event) {
                cJSON_Delete(event_obj);
            }
        }
    }

    if (author[0] == '\0') {
        strlcpy(author, "BLE", sizeof(author));
    }

    if (text[0] == '\0') {
        char *debug_body = body_obj ? cJSON_PrintUnformatted(body_obj) : NULL;
        if (debug_body) {
            ESP_LOGW(TAG, "chat post: missing content after parse (room=%s, body=%s)",
                     room ? room : "general", debug_body);
            free(debug_body);
        } else {
            ESP_LOGW(TAG, "chat post: missing content after parse (room=%s)",
                     room ? room : "general");
        }
        if (body_obj && !body_obj_borrowed) {
            cJSON_Delete(body_obj);
        }
        return ble_api_result_make(400, ble_strdup_local("{\"error\":\"missing message content\"}"));
    }

    esp_err_t ret = mesh_chat_add_local_message_with_timestamp(author, text, timestamp, MESH_CHAT_CH_BLE);
    if (ret != ESP_OK) {
        if (body_obj && !body_obj_borrowed) {
            cJSON_Delete(body_obj);
        }
        return ble_api_result_make(500, ble_strdup_local("{\"error\":\"failed to store message\"}"));
    }

    cJSON *response = cJSON_CreateObject();
    if (!response) {
        if (body_obj && !body_obj_borrowed) {
            cJSON_Delete(body_obj);
        }
        return ble_api_result_make(200, ble_strdup_local("{\"ok\":true}"));
    }

    char id_str[24] = {0};
    snprintf(id_str, sizeof(id_str), "%lu", (unsigned long)mesh_chat_get_latest_id());

    cJSON_AddStringToObject(response, "id", id_str);
    cJSON_AddStringToObject(response, "content", text);
    cJSON_AddStringToObject(response, "author", author);
    cJSON_AddNumberToObject(response, "timestamp", (double)timestamp);
    ble_add_string_if_not_empty(response, "roomId", room);

    char *out = ble_json_to_string(response);
    cJSON_Delete(response);
    if (body_obj && !body_obj_borrowed) {
        cJSON_Delete(body_obj);
    }

    return ble_api_result_make(201, out);
}

static geogram_ble_api_result_t ble_handle_chat_file_post(cJSON *body, const char *fallback_author)
{
    bool body_obj_borrowed = false;
    cJSON *body_obj = ble_parse_body_object(body, &body_obj_borrowed);
    if (!body_obj) {
        return ble_api_result_make(400, ble_strdup_local("{\"error\":\"invalid body\"}"));
    }

    char author[GEOGRAM_BLE_MAX_AUTHOR_LEN] = {0};
    if (fallback_author && fallback_author[0] != '\0') {
        strlcpy(author, fallback_author, sizeof(author));
    }

    cJSON *callsign = cJSON_GetObjectItemCaseSensitive(body_obj, "callsign");
    if (cJSON_IsString(callsign) && callsign->valuestring) {
        strlcpy(author, callsign->valuestring, sizeof(author));
    }

    if (author[0] == '\0') {
        strlcpy(author, "BLE", sizeof(author));
    }

    const char *sha1_hex = NULL;
    cJSON *sha1 = cJSON_GetObjectItemCaseSensitive(body_obj, "sha1");
    if (cJSON_IsString(sha1) && sha1->valuestring) {
        sha1_hex = sha1->valuestring;
    }

    if (!sha1_hex) {
        if (!body_obj_borrowed) {
            cJSON_Delete(body_obj);
        }
        return ble_api_result_make(400, ble_strdup_local("{\"error\":\"missing sha1\"}"));
    }

    uint8_t sha1_bytes[20] = {0};
    if (!ble_parse_sha1_hex(sha1_hex, sha1_bytes)) {
        if (!body_obj_borrowed) {
            cJSON_Delete(body_obj);
        }
        return ble_api_result_make(400, ble_strdup_local("{\"error\":\"invalid sha1\"}"));
    }

    uint32_t size = 0;
    cJSON *size_item = cJSON_GetObjectItemCaseSensitive(body_obj, "size");
    if (cJSON_IsNumber(size_item) && size_item->valuedouble > 0) {
        size = (uint32_t)size_item->valuedouble;
    }

    if (size == 0) {
        if (!body_obj_borrowed) {
            cJSON_Delete(body_obj);
        }
        return ble_api_result_make(400, ble_strdup_local("{\"error\":\"invalid file size\"}"));
    }

    const char *text = "";
    cJSON *text_item = cJSON_GetObjectItemCaseSensitive(body_obj, "text");
    if (cJSON_IsString(text_item) && text_item->valuestring) {
        text = text_item->valuestring;
    }

    const char *filename = "";
    cJSON *filename_item = cJSON_GetObjectItemCaseSensitive(body_obj, "filename");
    if (cJSON_IsString(filename_item) && filename_item->valuestring) {
        filename = filename_item->valuestring;
    }

    const char *mime = "";
    cJSON *mime_item = cJSON_GetObjectItemCaseSensitive(body_obj, "mime");
    if (cJSON_IsString(mime_item) && mime_item->valuestring) {
        mime = mime_item->valuestring;
    }

    esp_err_t ret = mesh_chat_add_local_file_message(author, text, sha1_bytes, size, filename, mime, MESH_CHAT_CH_BLE);
    if (!body_obj_borrowed) {
        cJSON_Delete(body_obj);
    }

    if (ret != ESP_OK) {
        return ble_api_result_make(500, ble_strdup_local("{\"error\":\"failed to store file metadata\"}"));
    }

    return ble_api_result_make(200, ble_strdup_local("{\"ok\":true}"));
}

static geogram_ble_api_result_t ble_dispatch_api_request(const char *method,
                                                         const char *path,
                                                         const char *query,
                                                         cJSON *body,
                                                         const char *peer_callsign)
{
    if (!method || !path) {
        return ble_api_result_make(400, ble_strdup_local("{\"error\":\"invalid request\"}"));
    }

    if (strcmp(method, "GET") == 0 && strcmp(path, "/api/status") == 0) {
        return ble_api_result_make(200, ble_build_status_body());
    }

    if (strcmp(method, "GET") == 0 && ble_is_chat_rooms_path(path)) {
        return ble_api_result_make(200, ble_build_chat_rooms_body());
    }

    char room[GEOGRAM_BLE_MAX_ROOM_LEN] = {0};

    if (strcmp(method, "GET") == 0 && ble_parse_messages_path(path, room, sizeof(room))) {
        long since_ts = 0;
        long limit = 50;
        ble_query_get_long(query, "since", &since_ts);
        ble_query_get_long(query, "limit", &limit);
        return ble_api_result_make(200, ble_build_chat_messages_body(room, since_ts, limit));
    }

    if ((strcmp(method, "POST") == 0 || strcmp(method, "PUT") == 0) &&
        ble_parse_messages_path(path, room, sizeof(room))) {
        return ble_handle_chat_message_post(body, peer_callsign, room);
    }

    if (strcmp(method, "POST") == 0 && strcmp(path, "/api/chat/send") == 0) {
        return ble_handle_chat_message_post(body, peer_callsign, "general");
    }

    if (strcmp(method, "POST") == 0 && strcmp(path, "/api/chat/send-file") == 0) {
        return ble_handle_chat_file_post(body, peer_callsign);
    }

    if (strcmp(method, "POST") == 0 && strcmp(path, "/api/chat/client") == 0) {
        return ble_api_result_make(200, ble_strdup_local("{\"ok\":true}"));
    }

    if (strcmp(method, "GET") == 0 && ble_parse_files_list_path(path, room, sizeof(room))) {
        return ble_api_result_make(200, ble_strdup_local("{\"files\":[]}"));
    }

    if (strcmp(method, "GET") == 0 && ble_parse_files_get_path(path, room, sizeof(room))) {
        return ble_api_result_make(404, ble_strdup_local("{\"error\":\"file not found\"}"));
    }

    return ble_api_result_make(404, ble_strdup_local("{\"error\":\"endpoint not found\"}"));
}

static bool ble_find_json_bounds(const uint8_t *buffer,
                                 size_t len,
                                 size_t *json_start,
                                 size_t *json_end,
                                 size_t *discard_prefix,
                                 bool *incomplete)
{
    return geoblue_find_json_object_bounds(
        buffer,
        len,
        json_start,
        json_end,
        discard_prefix,
        incomplete);
}

#if CONFIG_BT_ENABLED
static int ble_notify_json(uint16_t conn_handle, const char *json)
{
    if (!json || json[0] == '\0' || s_notify_val_handle == 0) {
        return BLE_HS_EINVAL;
    }

    geogram_ble_peer_t *peer = ble_find_peer(conn_handle);
    if (!peer || !peer->active) {
        return BLE_HS_ENOTCONN;
    }

    if (!peer->subscribed) {
        ESP_LOGW(TAG, "BLE notify skipped (conn=%u not subscribed)", conn_handle);
        return BLE_HS_EBUSY;
    }

    size_t len = strlen(json);
    if (len == 0) {
        return 0;
    }

    uint16_t mtu = ble_att_mtu(conn_handle);
    size_t chunk_size = GEOGRAM_BLE_MAX_NOTIFY_CHUNK;
    if (mtu > 3) {
        size_t by_mtu = (size_t)(mtu - 3);
        if (by_mtu < chunk_size) {
            chunk_size = by_mtu;
        }
    }

    if (chunk_size == 0) {
        chunk_size = 20;
    }

    size_t offset = 0;
    while (offset < len) {
        size_t remaining = len - offset;
        size_t send_len = remaining > chunk_size ? chunk_size : remaining;

        struct os_mbuf *om = ble_hs_mbuf_from_flat(json + offset, send_len);
        if (!om) {
            return BLE_HS_ENOMEM;
        }

        int rc = ble_gatts_notify_custom(conn_handle, s_notify_val_handle, om);
        if (rc != 0) {
            ESP_LOGW(TAG, "BLE notify failed (conn=%u rc=%d offset=%u/%u)",
                     conn_handle, rc, (unsigned)offset, (unsigned)len);
            return rc;
        }

        offset += send_len;
    }

    return 0;
}

static void ble_send_error_envelope(uint16_t conn_handle, const char *request_id,
                                    const char *error, const char *code)
{
    cJSON *payload = cJSON_CreateObject();
    cJSON *envelope = cJSON_CreateObject();
    if (!payload || !envelope) {
        cJSON_Delete(payload);
        cJSON_Delete(envelope);
        return;
    }

    cJSON_AddStringToObject(payload, "error", error ? error : "Error");
    if (code && code[0] != '\0') {
        cJSON_AddStringToObject(payload, "code", code);
    }

    cJSON_AddNumberToObject(envelope, "v", 1);
    cJSON_AddStringToObject(envelope, "id", request_id ? request_id : "unknown");
    cJSON_AddStringToObject(envelope, "type", "error");
    cJSON_AddNumberToObject(envelope, "seq", 0);
    cJSON_AddNumberToObject(envelope, "total", 1);
    cJSON_AddItemToObject(envelope, "payload", payload);

    char *json = ble_json_to_string(envelope);
    if (json) {
        ble_notify_json(conn_handle, json);
        free(json);
    }

    cJSON_Delete(envelope);
}

static void ble_send_chat_ack(uint16_t conn_handle, const char *request_id, bool success, const char *error)
{
    cJSON *payload = cJSON_CreateObject();
    cJSON *envelope = cJSON_CreateObject();
    if (!payload || !envelope) {
        cJSON_Delete(payload);
        cJSON_Delete(envelope);
        return;
    }

    cJSON_AddBoolToObject(payload, "success", success);
    cJSON_AddStringToObject(payload, "message_id", request_id ? request_id : "");
    if (!success && error) {
        cJSON_AddStringToObject(payload, "error", error);
    }

    cJSON_AddNumberToObject(envelope, "v", 1);
    cJSON_AddStringToObject(envelope, "id", request_id ? request_id : "unknown");
    cJSON_AddStringToObject(envelope, "type", "chat_ack");
    cJSON_AddNumberToObject(envelope, "seq", 0);
    cJSON_AddNumberToObject(envelope, "total", 1);
    cJSON_AddItemToObject(envelope, "payload", payload);

    char *json = ble_json_to_string(envelope);
    if (json) {
        ble_notify_json(conn_handle, json);
        free(json);
    }

    cJSON_Delete(envelope);
}

static void ble_send_hello_proactive(uint16_t conn_handle)
{
    char request_id[48] = {0};
    snprintf(request_id, sizeof(request_id), "hello-%lu", (unsigned long)esp_log_timestamp());

    const char *callsign = ble_station_callsign();
    const char *npub = nostr_keys_get_npub();
    char *json = geoblue_build_hello_frame(
        request_id,
        callsign,
        npub,
        BOARD_NAME,
        s_geoblue_caps,
        sizeof(s_geoblue_caps) / sizeof(s_geoblue_caps[0]));
    if (!json) {
        return;
    }

    int rc = ble_notify_json(conn_handle, json);
    if (rc != 0) {
        ESP_LOGW(TAG, "proactive hello notify failed (conn=%u rc=%d)", conn_handle, rc);
    } else {
        ESP_LOGI(TAG, "proactive hello sent (conn=%u id=%s)", conn_handle, request_id);
    }
    free(json);
}

static void ble_send_hello_compact(uint16_t conn_handle)
{
    char request_id[40] = {0};
    snprintf(request_id, sizeof(request_id), "hello-%lu", (unsigned long)esp_log_timestamp());

    const char *callsign = ble_station_callsign();
    if (!callsign || callsign[0] == '\0') {
        callsign = "NOCALL";
    }

    char json[240] = {0};
    int written = snprintf(
        json,
        sizeof(json),
        "{\"v\":1,\"id\":\"%s\",\"type\":\"hello\",\"seq\":0,\"total\":1,"
        "\"payload\":{\"callsign\":\"%s\",\"capabilities\":[\"hello\",\"data\",\"broadcast\",\"%s\"]}}",
        request_id,
        callsign,
        GEOBLUE_TEST_CAP_REVERSE);
    if (written <= 0 || (size_t)written >= sizeof(json)) {
        return;
    }

    int rc = ble_notify_json(conn_handle, json);
    if (rc != 0) {
        ESP_LOGW(TAG, "compact hello notify failed (conn=%u rc=%d)", conn_handle, rc);
    }
}

static void ble_send_hello_ack(uint16_t conn_handle, const char *request_id)
{
    const char *id = (request_id && request_id[0] != '\0') ? request_id : "unknown";
    const char *callsign = ble_station_callsign();
    const char *npub = nostr_keys_get_npub();

    char *json = geoblue_build_hello_ack_frame(
        id,
        true,
        callsign,
        npub,
        BOARD_NAME,
        s_geoblue_caps,
        sizeof(s_geoblue_caps) / sizeof(s_geoblue_caps[0]),
        NULL);
    if (!json) {
        ESP_LOGW(TAG, "hello_ack build failed (id=%s)", id);
        return;
    }

    int rc = ble_notify_json(conn_handle, json);
    free(json);
    if (rc != 0) {
        ESP_LOGW(TAG, "hello_ack notify failed (id=%s rc=%d)", id, rc);
    } else {
        ESP_LOGI(TAG, "hello_ack sent (id=%s)", id);
    }
}

static void ble_send_hello_ack_legacy(uint16_t conn_handle)
{
#if CONFIG_BT_ENABLED
    cJSON *response = cJSON_CreateObject();
    cJSON *event = ble_build_hello_event();
    cJSON *caps = cJSON_CreateArray();
    if (!response || !event || !caps) {
        cJSON_Delete(response);
        cJSON_Delete(event);
        cJSON_Delete(caps);
        return;
    }

    cJSON_AddStringToObject(response, "type", "hello_ack");
    cJSON_AddBoolToObject(response, "success", true);
    cJSON_AddItemToObject(response, "event", event);
    cJSON_AddItemToArray(caps, cJSON_CreateString("chat"));
    cJSON_AddItemToObject(response, "capabilities", caps);

    char *json = ble_json_to_string(response);
    if (json) {
        int rc = ble_notify_json(conn_handle, json);
        if (rc != 0) {
            ESP_LOGW(TAG, "legacy hello_ack notify failed (rc=%d)", rc);
        }
        free(json);
    }

    cJSON_Delete(response);
#else
    (void)conn_handle;
#endif
}

static void ble_send_api_response(uint16_t conn_handle, const char *request_id,
                                  int status_code, const char *body)
{
    const char *id = request_id ? request_id : "unknown";
    const char *body_str = body ? body : "{}";

    // Build api_response directly to avoid cJSON allocation churn in the
    // NimBLE host callback path under constrained heap conditions.
    size_t id_len = strlen(id);
    size_t body_len = strlen(body_str);
    size_t capacity = id_len + body_len + 96;
    char *json = (char *)malloc(capacity);
    if (!json) {
        return;
    }

    int written = snprintf(
        json,
        capacity,
        "{\"type\":\"api_response\",\"id\":\"%s\",\"statusCode\":%d,\"body\":%s}",
        id,
        status_code,
        body_str
    );
    if (written > 0) {
        int rc = ble_notify_json(conn_handle, json);
        if (rc != 0) {
            ESP_LOGW(TAG, "api_response notify failed (id=%s status=%d rc=%d)",
                     id, status_code, rc);
        } else {
            ESP_LOGI(TAG, "api_response sent (id=%s status=%d body_len=%u)",
                     id, status_code, (unsigned)body_len);
        }
    }
    free(json);
}
#endif

static void ble_handle_api_request_object(uint16_t conn_handle,
                                          const char *peer_callsign,
                                          cJSON *request,
                                          const char *fallback_request_id)
{
#if CONFIG_BT_ENABLED
    if (!request || !cJSON_IsObject(request)) {
        ble_send_api_response(conn_handle,
                              fallback_request_id ? fallback_request_id : "unknown",
                              400,
                              "{\"error\":\"invalid api_request payload\"}");
        return;
    }

    cJSON *type_item = cJSON_GetObjectItemCaseSensitive(request, "type");
    cJSON *id_item = cJSON_GetObjectItemCaseSensitive(request, "id");
    cJSON *method_item = cJSON_GetObjectItemCaseSensitive(request, "method");
    cJSON *path_item = cJSON_GetObjectItemCaseSensitive(request, "path");
    cJSON *body_item = cJSON_GetObjectItemCaseSensitive(request, "body");

    const char *request_id = cJSON_IsString(id_item) && id_item->valuestring ?
        id_item->valuestring :
        (fallback_request_id ? fallback_request_id : "unknown");

    if (!cJSON_IsString(type_item) || !type_item->valuestring ||
        strcmp(type_item->valuestring, "api_request") != 0) {
        ble_send_api_response(conn_handle, request_id, 400,
                              "{\"error\":\"invalid api request type\"}");
        return;
    }

    const char *method_raw = cJSON_IsString(method_item) && method_item->valuestring ?
        method_item->valuestring : "GET";
    const char *path_raw = cJSON_IsString(path_item) && path_item->valuestring ?
        path_item->valuestring : "/";

    char method[8] = {0};
    for (size_t i = 0; i < sizeof(method) - 1 && method_raw[i] != '\0'; i++) {
        method[i] = (char)toupper((unsigned char)method_raw[i]);
    }

    char normalized_path[GEOGRAM_BLE_MAX_PATH_LEN] = {0};
    char query[GEOGRAM_BLE_MAX_QUERY_LEN] = {0};
    ble_split_path_query(path_raw, normalized_path, sizeof(normalized_path), query, sizeof(query));

    ESP_LOGI(TAG, "api request from %s: %s %s",
             peer_callsign ? peer_callsign : "BLE",
             method,
             normalized_path);

    geogram_ble_api_result_t result = ble_dispatch_api_request(
        method,
        normalized_path,
        query,
        body_item,
        peer_callsign);

    ble_send_api_response(conn_handle, request_id, result.status_code,
                          result.body ? result.body : "{}");

    if (result.body) {
        free(result.body);
    }

    return;
#else
    (void)conn_handle;
    (void)peer_callsign;
    (void)request;
    (void)fallback_request_id;
#endif
}

static void ble_handle_api_request(uint16_t conn_handle,
                                   const char *peer_callsign,
                                   const char *content,
                                   const char *fallback_request_id)
{
#if CONFIG_BT_ENABLED
    cJSON *request = NULL;
    if (content && content[0] != '\0') {
        request = cJSON_Parse(content);
    }

    if (!request || !cJSON_IsObject(request)) {
        size_t content_len = content ? strlen(content) : 0;
        if (content_len > 0) {
            size_t preview = content_len > 220 ? 220 : content_len;
            ESP_LOGW(TAG, "api_request parse failed (len=%u): %.*s",
                     (unsigned)content_len, (int)preview, content);
        } else {
            ESP_LOGW(TAG, "api_request parse failed: empty content");
        }
        cJSON_Delete(request);
        ble_send_api_response(conn_handle,
                              fallback_request_id ? fallback_request_id : "unknown",
                              400,
                              "{\"error\":\"invalid api_request payload\"}");
        return;
    }

    ble_handle_api_request_object(conn_handle, peer_callsign, request, fallback_request_id);
    cJSON_Delete(request);
#else
    (void)conn_handle;
    (void)peer_callsign;
    (void)content;
    (void)fallback_request_id;
#endif
}

static void ble_handle_hello(uint16_t conn_handle,
                             geogram_ble_peer_t *peer,
                             cJSON *message)
{
#if CONFIG_BT_ENABLED
    bool is_envelope = ble_is_envelope_message(message);
    cJSON *id_item = cJSON_GetObjectItemCaseSensitive(message, "id");
    const char *request_id = cJSON_IsString(id_item) && id_item->valuestring ?
        id_item->valuestring : "unknown";

    cJSON *payload = cJSON_GetObjectItemCaseSensitive(message, "payload");
    cJSON *event = NULL;
    if (payload) {
        event = cJSON_GetObjectItemCaseSensitive(payload, "event");
    }
    if (!event) {
        event = cJSON_GetObjectItemCaseSensitive(message, "event");
    }

    char extracted_callsign[STATION_CALLSIGN_LEN] = {0};
    if (event && ble_extract_callsign_from_event(event, extracted_callsign, sizeof(extracted_callsign))) {
        if (peer) {
            strlcpy(peer->callsign, extracted_callsign, sizeof(peer->callsign));
        }
    }

    ESP_LOGI(TAG, "BLE HELLO from %s",
             (peer && peer->callsign[0] != '\0') ? peer->callsign : "unknown");

    if (is_envelope) {
        ble_send_hello_ack(conn_handle, request_id);
    } else {
        ble_send_hello_ack_legacy(conn_handle);
    }

    // Symmetric geoblue handshake: after acknowledging peer HELLO,
    // also announce our own HELLO in compact single-frame form.
    ble_send_hello_compact(conn_handle);

    // Reverse unicast test mode: peer advertises the dedicated capability in
    // HELLO so ESP32 starts a deterministic 1000-byte data transfer.
    if (ble_payload_has_capability(message, GEOBLUE_TEST_CAP_REVERSE)) {
        const char *peer_callsign =
            (peer && peer->callsign[0] != '\0') ? peer->callsign : NULL;
        ble_send_reverse_test_data(conn_handle, peer_callsign);
    }
#else
    (void)conn_handle;
    (void)peer;
    (void)message;
#endif
}

static void ble_handle_hello_ack(uint16_t conn_handle,
                                 geogram_ble_peer_t *peer,
                                 cJSON *message)
{
#if CONFIG_BT_ENABLED
    cJSON *payload = cJSON_GetObjectItemCaseSensitive(message, "payload");
    if (!cJSON_IsObject(payload)) {
        payload = NULL;
    }

    char extracted_callsign[STATION_CALLSIGN_LEN] = {0};
    cJSON *profile = payload ? cJSON_GetObjectItemCaseSensitive(payload, "profile") : NULL;
    if (cJSON_IsObject(profile)) {
        cJSON *callsign_item = cJSON_GetObjectItemCaseSensitive(profile, "callsign");
        if (cJSON_IsString(callsign_item) && callsign_item->valuestring) {
            strlcpy(extracted_callsign, callsign_item->valuestring, sizeof(extracted_callsign));
        }
    }

    cJSON *event = payload ? cJSON_GetObjectItemCaseSensitive(payload, "event") : NULL;
    if (extracted_callsign[0] == '\0' && event) {
        ble_extract_callsign_from_event(event, extracted_callsign, sizeof(extracted_callsign));
    }

    if (peer && extracted_callsign[0] != '\0') {
        strlcpy(peer->callsign, extracted_callsign, sizeof(peer->callsign));
    }

    ESP_LOGI(TAG, "BLE HELLO_ACK from %s (conn=%u)",
             (peer && peer->callsign[0] != '\0') ? peer->callsign :
             (extracted_callsign[0] != '\0' ? extracted_callsign : "unknown"),
             conn_handle);
#else
    (void)conn_handle;
    (void)peer;
    (void)message;
#endif
}

// ============================================================================
// BLE APRS handlers (KV4P only)
// ============================================================================

#if BOARD_MODEL == MODEL_KV4P

#define BLE_APRS_RATE_LIMIT_MS  30000

/**
 * Handle incoming _aprs DATA frame from BLE client.
 * Parses BLEAprsPayload JSON, rate-limits, queues for radio TX,
 * stores in APRS history, and bridges to mesh_chat.
 */
static void ble_handle_aprs_data(uint16_t conn_handle,
                                  geogram_ble_peer_t *peer,
                                  const char *content,
                                  const char *from,
                                  uint32_t timestamp)
{
#if CONFIG_BT_ENABLED
    if (!content || content[0] == '\0') {
        ESP_LOGW(TAG, "BLE APRS: empty content");
        return;
    }

    // Parse content as JSON: {"to":"CALL","text":"msg","type":"message"}
    cJSON *json = cJSON_Parse(content);
    if (!json) {
        ESP_LOGW(TAG, "BLE APRS: invalid JSON");
        return;
    }

    cJSON *type_item = cJSON_GetObjectItemCaseSensitive(json, "type");
    const char *type = cJSON_IsString(type_item) ? type_item->valuestring : NULL;
    if (!type || strcmp(type, "message") != 0) {
        ESP_LOGD(TAG, "BLE APRS: ignoring type=%s", type ? type : "null");
        cJSON_Delete(json);
        return;
    }

    cJSON *to_item = cJSON_GetObjectItemCaseSensitive(json, "to");
    cJSON *text_item = cJSON_GetObjectItemCaseSensitive(json, "text");
    const char *to = cJSON_IsString(to_item) ? to_item->valuestring : NULL;
    const char *text = cJSON_IsString(text_item) ? text_item->valuestring : NULL;

    if (!to || to[0] == '\0' || !text || text[0] == '\0') {
        ESP_LOGW(TAG, "BLE APRS: missing to/text");
        cJSON_Delete(json);
        return;
    }

    // Rate limit per peer
    if (peer) {
        uint32_t now_ms = esp_log_timestamp();
        if (peer->aprs_last_tx_ms != 0 &&
            (now_ms - peer->aprs_last_tx_ms) < BLE_APRS_RATE_LIMIT_MS) {
            ESP_LOGW(TAG, "BLE APRS: rate limited (peer conn=%u)", conn_handle);
            cJSON_Delete(json);
            return;
        }
        peer->aprs_last_tx_ms = now_ms;
    }

    ESP_LOGI(TAG, "BLE APRS TX: %s -> %s: %.40s", from, to, text);

    // Queue for radio TX
    radio_tx_item_t item;
    strncpy(item.from, from, sizeof(item.from) - 1);
    item.from[sizeof(item.from) - 1] = '\0';
    strncpy(item.to, to, sizeof(item.to) - 1);
    item.to[sizeof(item.to) - 1] = '\0';
    strncpy(item.message, text, sizeof(item.message) - 1);
    item.message[sizeof(item.message) - 1] = '\0';
    radio_tx_queue_send(&item);

    // Store in APRS history
    aprs_store_add_tx(from, to, text);

    // Bridge to mesh_chat
    mesh_chat_add_local_message_with_timestamp(from, text, timestamp,
                                                MESH_CHAT_CH_APRS | MESH_CHAT_CH_BLE);

    cJSON_Delete(json);
#else
    (void)conn_handle; (void)peer; (void)content; (void)from; (void)timestamp;
#endif
}

/**
 * APRS RX notify callback — pushes received APRS messages to all BLE clients
 * on the _aprs channel as Geoblue DATA frames.
 */
static void ble_aprs_rx_notify(const char *from, const char *to,
                                const char *message, void *ctx)
{
#if CONFIG_BT_ENABLED
    (void)ctx;
    if (!message || message[0] == '\0') return;

    // Build JSON payload: {"from":"...","to":"...","text":"...","type":"message"}
    cJSON *obj = cJSON_CreateObject();
    if (!obj) return;
    cJSON_AddStringToObject(obj, "from", from ? from : "");
    cJSON_AddStringToObject(obj, "to", to ? to : "");
    cJSON_AddStringToObject(obj, "text", message);
    cJSON_AddStringToObject(obj, "type", "message");
    char *payload_str = cJSON_PrintUnformatted(obj);
    cJSON_Delete(obj);
    if (!payload_str) return;

    // Build Geoblue DATA frame
    char frame_id[48];
    snprintf(frame_id, sizeof(frame_id), "aprs-rx-%lu", (unsigned long)esp_log_timestamp());

    char *frame = geoblue_build_data_frame(
        frame_id,
        ble_station_callsign(),
        NULL,
        "_aprs",
        payload_str,
        (int64_t)time(NULL));
    free(payload_str);
    if (!frame) return;

    // Push to all connected BLE peers
    for (size_t i = 0; i < GEOGRAM_BLE_MAX_CONNECTIONS; i++) {
        if (s_peers[i].active && s_peers[i].subscribed) {
            ble_notify_json(s_peers[i].conn_handle, frame);
        }
    }
    free(frame);
#else
    (void)from; (void)to; (void)message; (void)ctx;
#endif
}

#endif // BOARD_MODEL == MODEL_KV4P

static void ble_handle_data(uint16_t conn_handle,
                            geogram_ble_peer_t *peer,
                            cJSON *message)
{
#if CONFIG_BT_ENABLED
    cJSON *id_item = cJSON_GetObjectItemCaseSensitive(message, "id");
    const char *request_id = cJSON_IsString(id_item) && id_item->valuestring ?
        id_item->valuestring : "unknown";

    cJSON *payload = cJSON_GetObjectItemCaseSensitive(message, "payload");
    if (!cJSON_IsObject(payload)) {
        return;
    }

    const char *from = NULL;
    const char *to = NULL;
    const char *content = NULL;
    const char *channel = "main";
    uint32_t timestamp = (uint32_t)time(NULL);

    cJSON *from_item = cJSON_GetObjectItemCaseSensitive(payload, "from");
    if (cJSON_IsString(from_item) && from_item->valuestring) {
        from = from_item->valuestring;
    }

    cJSON *content_item = cJSON_GetObjectItemCaseSensitive(payload, "content");
    if (cJSON_IsString(content_item) && content_item->valuestring) {
        content = content_item->valuestring;
    }

    cJSON *to_item = cJSON_GetObjectItemCaseSensitive(payload, "to");
    if (cJSON_IsString(to_item) && to_item->valuestring) {
        to = to_item->valuestring;
    }

    cJSON *channel_item = cJSON_GetObjectItemCaseSensitive(payload, "channel");
    if (cJSON_IsString(channel_item) && channel_item->valuestring) {
        channel = channel_item->valuestring;
    }

    cJSON *timestamp_item = cJSON_GetObjectItemCaseSensitive(payload, "timestamp");
    if (cJSON_IsNumber(timestamp_item) && timestamp_item->valuedouble > 0) {
        timestamp = (uint32_t)timestamp_item->valuedouble;
    }

    if (!from || from[0] == '\0') {
        if (peer && peer->callsign[0] != '\0') {
            from = peer->callsign;
        } else {
            from = "BLE";
        }
    }

    ESP_LOGI(TAG, "BLE DATA from %s to=%s channel=%s",
             from,
             (to && to[0] != '\0') ? to : "-",
             channel);

    if (strcmp(channel, "_api") == 0) {
        cJSON *api_item = cJSON_GetObjectItemCaseSensitive(payload, "api");
        if (cJSON_IsObject(api_item)) {
            ble_handle_api_request_object(conn_handle, from, api_item, request_id);
        } else {
            ble_handle_api_request(conn_handle, from, content, request_id);
        }
        return;
    }

#if BOARD_MODEL == MODEL_KV4P
    if (strcmp(channel, "_aprs") == 0) {
        ble_handle_aprs_data(conn_handle, peer, content, from, timestamp);
        return;
    }
#endif

    if (content && content[0] != '\0') {
        mesh_chat_add_local_message_with_timestamp(from, content, timestamp, MESH_CHAT_CH_BLE);
    }

    if (content && content[0] != '\0' && strcmp(channel, GEOBLUE_CH_UNICAST_TEST) == 0) {
        char response_id[48] = {0};
        snprintf(response_id, sizeof(response_id), "echo-%lu",
                 (unsigned long)esp_log_timestamp());

        char *echo = geoblue_build_data_frame(
            response_id,
            ble_station_callsign(),
            from,
            channel,
            content,
            (int64_t)time(NULL));
        if (echo) {
            int rc = ble_notify_json(conn_handle, echo);
            if (rc != 0) {
                ESP_LOGW(TAG, "unicast echo notify failed (rc=%d)", rc);
            } else {
                ESP_LOGI(TAG, "unicast echo sent (len=%u)", (unsigned)strlen(content));
            }
            free(echo);
        }
    }

    if (strcmp(channel, GEOBLUE_CH_REVERSE_ECHO) == 0) {
        char expected[GEOBLUE_TEST_PAYLOAD_LEN + 1] = {0};
        ble_build_test_payload(expected, GEOBLUE_TEST_PAYLOAD_LEN);

        bool ok = false;
        if (content) {
            ok = (strlen(content) == GEOBLUE_TEST_PAYLOAD_LEN &&
                  memcmp(content, expected, GEOBLUE_TEST_PAYLOAD_LEN) == 0);
        }

        ble_send_reverse_test_result(conn_handle, from, ok);
        ESP_LOGI(TAG, "reverse echo validation %s", ok ? "ok" : "mismatch");
    }
#else
    (void)conn_handle;
    (void)peer;
    (void)message;
#endif
}

static void ble_forward_broadcast(uint16_t source_conn_handle, const char *json)
{
#if CONFIG_BT_ENABLED
    if (!json || json[0] == '\0') {
        return;
    }

    for (size_t i = 0; i < GEOGRAM_BLE_MAX_CONNECTIONS; i++) {
        geogram_ble_peer_t *peer = &s_peers[i];
        if (!peer->active || !peer->subscribed) {
            continue;
        }
        if (peer->conn_handle == source_conn_handle) {
            continue;
        }
        ble_notify_json(peer->conn_handle, json);
    }
#else
    (void)source_conn_handle;
    (void)json;
#endif
}

static void ble_handle_broadcast(uint16_t conn_handle,
                                 geogram_ble_peer_t *peer,
                                 cJSON *message)
{
#if CONFIG_BT_ENABLED
    cJSON *payload = cJSON_GetObjectItemCaseSensitive(message, "payload");
    if (!cJSON_IsObject(payload)) {
        return;
    }

    const char *from = NULL;
    const char *topic = "general";
    const char *content = NULL;
    uint32_t timestamp = (uint32_t)time(NULL);

    cJSON *from_item = cJSON_GetObjectItemCaseSensitive(payload, "from");
    if (cJSON_IsString(from_item) && from_item->valuestring) {
        from = from_item->valuestring;
    } else if (peer && peer->callsign[0] != '\0') {
        from = peer->callsign;
    } else {
        from = "BLE";
    }

    cJSON *topic_item = cJSON_GetObjectItemCaseSensitive(payload, "topic");
    if (cJSON_IsString(topic_item) && topic_item->valuestring) {
        topic = topic_item->valuestring;
    }

    cJSON *content_item = cJSON_GetObjectItemCaseSensitive(payload, "content");
    if (cJSON_IsString(content_item) && content_item->valuestring) {
        content = content_item->valuestring;
    }

    cJSON *timestamp_item = cJSON_GetObjectItemCaseSensitive(payload, "timestamp");
    if (cJSON_IsNumber(timestamp_item) && timestamp_item->valuedouble > 0) {
        timestamp = (uint32_t)timestamp_item->valuedouble;
    }

    if (content && content[0] != '\0') {
        char line[GEOGRAM_BLE_MAX_MESSAGE_LEN + 1] = {0};
        snprintf(line, sizeof(line), "[%s] %s", topic, content);
        mesh_chat_add_local_message_with_timestamp(from, line, timestamp, MESH_CHAT_CH_BLE);

        // Confirm delivery to the broadcast sender over BLE.
        ble_send_broadcast_receipt(conn_handle, from, content);
    }

    char *json = cJSON_PrintUnformatted(message);
    if (json) {
        ble_forward_broadcast(conn_handle, json);
        free(json);
    }
#else
    (void)conn_handle;
    (void)peer;
    (void)message;
#endif
}

static void ble_handle_chat(uint16_t conn_handle,
                            geogram_ble_peer_t *peer,
                            cJSON *message)
{
#if CONFIG_BT_ENABLED
    cJSON *id_item = cJSON_GetObjectItemCaseSensitive(message, "id");
    const char *request_id = cJSON_IsString(id_item) && id_item->valuestring ?
        id_item->valuestring : "unknown";

    cJSON *payload = cJSON_GetObjectItemCaseSensitive(message, "payload");
    if (!cJSON_IsObject(payload)) {
        ble_send_chat_ack(conn_handle, request_id, false, "invalid payload");
        return;
    }

    const char *channel = "main";
    const char *author = NULL;
    const char *content = "";
    uint32_t timestamp = (uint32_t)time(NULL);

    cJSON *channel_item = cJSON_GetObjectItemCaseSensitive(payload, "channel");
    if (cJSON_IsString(channel_item) && channel_item->valuestring) {
        channel = channel_item->valuestring;
    }

    cJSON *author_item = cJSON_GetObjectItemCaseSensitive(payload, "author");
    if (cJSON_IsString(author_item) && author_item->valuestring) {
        author = author_item->valuestring;
    }

    cJSON *content_item = cJSON_GetObjectItemCaseSensitive(payload, "content");
    if (cJSON_IsString(content_item) && content_item->valuestring) {
        content = content_item->valuestring;
    }

    cJSON *timestamp_item = cJSON_GetObjectItemCaseSensitive(payload, "timestamp");
    if (cJSON_IsNumber(timestamp_item) && timestamp_item->valuedouble > 0) {
        timestamp = (uint32_t)timestamp_item->valuedouble;
    }

    char effective_author[GEOGRAM_BLE_MAX_AUTHOR_LEN] = {0};
    if (author && author[0] != '\0') {
        strlcpy(effective_author, author, sizeof(effective_author));
    } else if (peer && peer->callsign[0] != '\0') {
        strlcpy(effective_author, peer->callsign, sizeof(effective_author));
    } else {
        strlcpy(effective_author, "BLE", sizeof(effective_author));
    }

    if (peer && peer->callsign[0] == '\0' && effective_author[0] != '\0') {
        strlcpy(peer->callsign, effective_author, sizeof(peer->callsign));
    }

    if (strcmp(channel, "_api") == 0) {
        cJSON *api_item = cJSON_GetObjectItemCaseSensitive(payload, "api");
        if (cJSON_IsObject(api_item)) {
            // Compact API payload mode: parse structured object directly to
            // avoid nested JSON-string escaping/fragmentation issues.
            ble_handle_api_request_object(conn_handle, effective_author, api_item, request_id);
            return;
        }

        // API-over-chat is treated as RPC: reply only with api_response.
        // Sending an additional chat_ack triggers back-to-back notifications
        // and can crash NimBLE on ESP32.
        ble_handle_api_request(conn_handle, effective_author, content, request_id);
        return;
    }

    ble_send_chat_ack(conn_handle, request_id, true, NULL);

    if (content[0] == '\0') {
        return;
    }

    char text[GEOGRAM_BLE_MAX_MESSAGE_LEN + 1] = {0};
    strlcpy(text, content, sizeof(text));

    cJSON *content_json = cJSON_Parse(content);
    if (content_json) {
        cJSON *content_field = cJSON_GetObjectItemCaseSensitive(content_json, "content");
        if (cJSON_IsString(content_field) && content_field->valuestring) {
            strlcpy(text, content_field->valuestring, sizeof(text));
        }

        cJSON *created_at = cJSON_GetObjectItemCaseSensitive(content_json, "created_at");
        if (cJSON_IsNumber(created_at) && created_at->valuedouble > 0) {
            timestamp = (uint32_t)created_at->valuedouble;
        }

        cJSON *tags = cJSON_GetObjectItemCaseSensitive(content_json, "tags");
        if (cJSON_IsArray(tags)) {
            cJSON *tag = NULL;
            cJSON_ArrayForEach(tag, tags) {
                if (!cJSON_IsArray(tag) || cJSON_GetArraySize(tag) < 2) {
                    continue;
                }
                cJSON *key = cJSON_GetArrayItem(tag, 0);
                cJSON *value = cJSON_GetArrayItem(tag, 1);
                if (cJSON_IsString(key) && cJSON_IsString(value) &&
                    key->valuestring && strcmp(key->valuestring, "callsign") == 0 &&
                    value->valuestring) {
                    strlcpy(effective_author, value->valuestring, sizeof(effective_author));
                    break;
                }
            }
        }

        cJSON_Delete(content_json);
    }

    if (text[0] != '\0') {
        mesh_chat_add_local_message_with_timestamp(effective_author, text, timestamp, MESH_CHAT_CH_BLE);
    }
#else
    (void)conn_handle;
    (void)peer;
    (void)message;
#endif
}

static void ble_handle_message(uint16_t conn_handle,
                               geogram_ble_peer_t *peer,
                               cJSON *message)
{
#if CONFIG_BT_ENABLED
    cJSON *type_item = cJSON_GetObjectItemCaseSensitive(message, "type");
    const char *type = cJSON_IsString(type_item) && type_item->valuestring ?
        type_item->valuestring : NULL;

    if (!type) {
        ble_send_error_envelope(conn_handle, "unknown", "missing type", "PARSE_ERROR");
        return;
    }

    geoblue_frame_type_t frame_type = geoblue_frame_type_from_name(type);
    switch (frame_type) {
        case GEOBLUE_FRAME_HELLO:
            ble_handle_hello(conn_handle, peer, message);
            return;
        case GEOBLUE_FRAME_HELLO_ACK:
            ble_handle_hello_ack(conn_handle, peer, message);
            return;
        case GEOBLUE_FRAME_DATA:
            ble_handle_data(conn_handle, peer, message);
            return;
        case GEOBLUE_FRAME_BROADCAST:
            ble_handle_broadcast(conn_handle, peer, message);
            return;
        case GEOBLUE_FRAME_UNKNOWN:
        case GEOBLUE_FRAME_ERROR:
        default:
            break;
    }

    if (strcmp(type, "chat") == 0) {
        ble_handle_chat(conn_handle, peer, message);
        return;
    }

    cJSON *id_item = cJSON_GetObjectItemCaseSensitive(message, "id");
    const char *request_id = cJSON_IsString(id_item) && id_item->valuestring ?
        id_item->valuestring : "unknown";

    ble_send_error_envelope(conn_handle, request_id, "unsupported message type", "UNSUPPORTED");
#else
    (void)conn_handle;
    (void)peer;
    (void)message;
#endif
}

static void ble_process_peer_buffer(geogram_ble_peer_t *peer)
{
    if (!peer || !peer->active || !peer->rx_buffer) {
        return;
    }

    while (peer->rx_len > 0) {
        size_t json_start = 0;
        size_t json_end = 0;
        size_t discard_prefix = 0;
        bool incomplete = false;

        bool has_object = ble_find_json_bounds(
            peer->rx_buffer,
            peer->rx_len,
            &json_start,
            &json_end,
            &discard_prefix,
            &incomplete);

        if (!has_object) {
            if (discard_prefix > 0 && discard_prefix <= peer->rx_len) {
                memmove(peer->rx_buffer, peer->rx_buffer + discard_prefix, peer->rx_len - discard_prefix);
                peer->rx_len -= discard_prefix;
            }

            if (!incomplete) {
                peer->rx_len = 0;
            }
            return;
        }

        if (discard_prefix > 0) {
            memmove(peer->rx_buffer, peer->rx_buffer + discard_prefix, peer->rx_len - discard_prefix);
            peer->rx_len -= discard_prefix;
            json_end -= discard_prefix;
            json_start = 0;
        }

        size_t json_len = json_end - json_start + 1;
        char *json_str = malloc(json_len + 1);
        if (!json_str) {
            peer->rx_len = 0;
            return;
        }

        memcpy(json_str, peer->rx_buffer + json_start, json_len);
        json_str[json_len] = '\0';

        memmove(peer->rx_buffer, peer->rx_buffer + json_len, peer->rx_len - json_len);
        peer->rx_len -= json_len;

        cJSON *message = cJSON_Parse(json_str);
        if (message) {
            ble_handle_message(peer->conn_handle, peer, message);
            cJSON_Delete(message);
        }
        free(json_str);
    }
}

#if CONFIG_BT_ENABLED
static int ble_gatt_access_cb(uint16_t conn_handle, uint16_t attr_handle,
                              struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)arg;

    if (ctxt->op == BLE_GATT_ACCESS_OP_WRITE_CHR) {
        if (attr_handle != s_write_val_handle) {
            return BLE_ATT_ERR_UNLIKELY;
        }

        geogram_ble_peer_t *peer = ble_alloc_peer(conn_handle);
        if (!peer) {
            return BLE_ATT_ERR_INSUFFICIENT_RES;
        }
        peer->subscribed = true;

        size_t incoming_len = OS_MBUF_PKTLEN(ctxt->om);
        if (incoming_len == 0) {
            return 0;
        }

        uint8_t *incoming = malloc(incoming_len);
        if (!incoming) {
            return BLE_ATT_ERR_INSUFFICIENT_RES;
        }

        int rc = ble_hs_mbuf_to_flat(ctxt->om, incoming, incoming_len, NULL);
        if (rc != 0) {
            free(incoming);
            return BLE_ATT_ERR_UNLIKELY;
        }

        if (!peer->rx_buffer) {
            free(incoming);
            return BLE_ATT_ERR_UNLIKELY;
        }

        if (incoming_len > GEOGRAM_BLE_RX_BUFFER_SIZE) {
            ESP_LOGW(TAG, "BLE write chunk too large (%u > %u), dropping buffer",
                     (unsigned)incoming_len, (unsigned)GEOGRAM_BLE_RX_BUFFER_SIZE);
            peer->rx_len = 0;
            free(incoming);
            return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        }

        if (peer->rx_len + incoming_len > GEOGRAM_BLE_RX_BUFFER_SIZE) {
            ESP_LOGW(TAG, "BLE RX buffer overflow (%u + %u > %u), resetting buffer",
                     (unsigned)peer->rx_len, (unsigned)incoming_len,
                     (unsigned)GEOGRAM_BLE_RX_BUFFER_SIZE);
            peer->rx_len = 0;
        }

        memcpy(peer->rx_buffer + peer->rx_len, incoming, incoming_len);
        peer->rx_len += incoming_len;
        free(incoming);

        ble_process_peer_buffer(peer);
        return 0;
    }

    if (ctxt->op == BLE_GATT_ACCESS_OP_READ_CHR) {
        const char *status_json = "{\"status\":\"ready\"}";
        int rc = os_mbuf_append(ctxt->om, status_json, strlen(status_json));
        return rc == 0 ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
    }

    return BLE_ATT_ERR_UNLIKELY;
}

static const struct ble_gatt_svc_def s_gatt_svcs[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &s_service_uuid.u,
        .characteristics = (struct ble_gatt_chr_def[]) {
            {
                .uuid = &s_write_uuid.u,
                .access_cb = ble_gatt_access_cb,
                .flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_NO_RSP,
                .val_handle = &s_write_val_handle,
            },
            {
                .uuid = &s_notify_uuid.u,
                .access_cb = ble_gatt_access_cb,
                .flags = BLE_GATT_CHR_F_NOTIFY | BLE_GATT_CHR_F_READ,
                .val_handle = &s_notify_val_handle,
            },
            {
                .uuid = &s_status_uuid.u,
                .access_cb = ble_gatt_access_cb,
                .flags = BLE_GATT_CHR_F_READ,
                .val_handle = &s_status_val_handle,
            },
            {0}
        }
    },
    {0}
};

static int ble_gap_event_cb(struct ble_gap_event *event, void *arg)
{
    (void)arg;

    switch (event->type) {
        case BLE_GAP_EVENT_CONNECT:
            if (event->connect.status == 0) {
                geogram_ble_peer_t *peer = ble_alloc_peer(event->connect.conn_handle);
                if (!peer) {
                    ESP_LOGW(TAG, "No free BLE peer slot for conn=%u", event->connect.conn_handle);
                    ble_gap_terminate(event->connect.conn_handle, BLE_ERR_REM_USER_CONN_TERM);
                } else {
                    ESP_LOGI(TAG, "BLE connected: conn=%u", event->connect.conn_handle);
                }
            } else {
                ESP_LOGW(TAG, "BLE connect failed: status=%d", event->connect.status);
                ble_advertise_start();
            }
            return 0;

        case BLE_GAP_EVENT_DISCONNECT:
            ESP_LOGI(TAG, "BLE disconnected: conn=%u reason=%d",
                     event->disconnect.conn.conn_handle,
                     event->disconnect.reason);
            ble_free_peer(event->disconnect.conn.conn_handle);
            ble_advertise_start();
            return 0;

        case BLE_GAP_EVENT_SUBSCRIBE: {
            geogram_ble_peer_t *peer = ble_find_peer(event->subscribe.conn_handle);
            if (!peer) {
                peer = ble_alloc_peer(event->subscribe.conn_handle);
            }
            if (peer && event->subscribe.attr_handle == s_notify_val_handle) {
                bool became_subscribed = (!peer->subscribed && event->subscribe.cur_notify);
                peer->subscribed = event->subscribe.cur_notify;
                if (became_subscribed) {
                    ble_send_hello_proactive(event->subscribe.conn_handle);
                }
            }
            return 0;
        }

        case BLE_GAP_EVENT_ADV_COMPLETE:
            ble_advertise_start();
            return 0;

        case BLE_GAP_EVENT_MTU:
            ESP_LOGI(TAG, "BLE MTU update: conn=%u mtu=%u",
                     event->mtu.conn_handle,
                     event->mtu.value);
            return 0;

        default:
            return 0;
    }
}

static void ble_on_reset(int reason)
{
    ESP_LOGW(TAG, "BLE host reset: reason=%d", reason);
}

static void ble_on_sync(void)
{
    int rc = ble_hs_id_infer_auto(0, &s_addr_type);
    if (rc != 0) {
        ESP_LOGE(TAG, "ble_hs_id_infer_auto failed: rc=%d", rc);
        return;
    }

    uint8_t addr_val[6] = {0};
    rc = ble_hs_id_copy_addr(s_addr_type, addr_val, NULL);
    if (rc == 0) {
        ESP_LOGI(TAG, "BLE address: %02x:%02x:%02x:%02x:%02x:%02x",
                 addr_val[5], addr_val[4], addr_val[3], addr_val[2], addr_val[1], addr_val[0]);
    }

    ble_advertise_start();
    s_running = true;
}

static void ble_advertise_start(void)
{
    if (!s_initialized) {
        return;
    }

    struct ble_hs_adv_fields fields;
    memset(&fields, 0, sizeof(fields));

    uint8_t adv_payload[34] = {0};
    const char *callsign = ble_station_callsign();
    uint8_t device_id = ble_compute_device_id();
    size_t callsign_len = strlen(callsign);
    if (callsign_len > 18) {
        callsign_len = 18;
    }

    // Manufacturer data layout expected by Geogram clients:
    // [company_id_le(0xFFFF)][marker(0x3E)][device_id][callsign...]
    // NimBLE expects company ID embedded in mfg_data bytes.
    adv_payload[0] = 0xFF;
    adv_payload[1] = 0xFF;
    adv_payload[2] = GEOGRAM_BLE_MARKER;
    adv_payload[3] = device_id;
    memcpy(&adv_payload[4], callsign, callsign_len);

    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;

    ble_uuid16_t service_uuid = BLE_UUID16_INIT(GEOGRAM_BLE_SERVICE_UUID16);
    fields.uuids16 = &service_uuid;
    fields.num_uuids16 = 1;
    fields.uuids16_is_complete = 1;

    fields.mfg_data = adv_payload;
    fields.mfg_data_len = (uint8_t)(4 + callsign_len);

    fields.tx_pwr_lvl_is_present = 1;
    fields.tx_pwr_lvl = BLE_HS_ADV_TX_PWR_LVL_AUTO;

    int rc = ble_gap_adv_set_fields(&fields);
    if (rc != 0) {
        ESP_LOGE(TAG, "ble_gap_adv_set_fields failed: rc=%d", rc);
        return;
    }

    struct ble_gap_adv_params adv_params;
    memset(&adv_params, 0, sizeof(adv_params));
    adv_params.conn_mode = BLE_GAP_CONN_MODE_UND;
    adv_params.disc_mode = BLE_GAP_DISC_MODE_GEN;

    ble_gap_adv_stop();

    rc = ble_gap_adv_start(s_addr_type, NULL, BLE_HS_FOREVER, &adv_params, ble_gap_event_cb, NULL);
    if (rc != 0) {
        ESP_LOGE(TAG, "ble_gap_adv_start failed: rc=%d", rc);
        return;
    }

    ESP_LOGI(TAG, "BLE advertising: callsign=%s device_id=%u", callsign, device_id);
}

static void ble_host_task(void *param)
{
    (void)param;
    nimble_port_run();
    nimble_port_freertos_deinit();
}
#endif

esp_err_t geogram_ble_init(void)
{
#if !CONFIG_BT_ENABLED
    return ESP_ERR_NOT_SUPPORTED;
#else
    if (s_initialized) {
        return ESP_OK;
    }

    station_init();
    if (!nostr_keys_available()) {
        nostr_keys_init();
    }

    esp_err_t chat_ret = mesh_chat_init();
    if (chat_ret != ESP_OK) {
        ESP_LOGW(TAG, "mesh_chat_init failed: %s", esp_err_to_name(chat_ret));
    }

    esp_err_t ret = nimble_port_init();
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "nimble_port_init failed: %s", esp_err_to_name(ret));
        return ret;
    }

    int rc = 0;

    ble_hs_cfg.reset_cb = ble_on_reset;
    ble_hs_cfg.sync_cb = ble_on_sync;

    ble_svc_gap_init();
    ble_svc_gatt_init();

    rc = ble_svc_gap_device_name_set("Geogram");
    if (rc != 0) {
        ESP_LOGW(TAG, "ble_svc_gap_device_name_set failed: rc=%d", rc);
    }

    rc = ble_gatts_count_cfg(s_gatt_svcs);
    if (rc != 0) {
        ESP_LOGE(TAG, "ble_gatts_count_cfg failed: rc=%d", rc);
        return ESP_FAIL;
    }

    rc = ble_gatts_add_svcs(s_gatt_svcs);
    if (rc != 0) {
        ESP_LOGE(TAG, "ble_gatts_add_svcs failed: rc=%d", rc);
        return ESP_FAIL;
    }

    ble_reset_all_peers();
    s_initialized = true;

#if BOARD_MODEL == MODEL_KV4P
    aprs_store_set_rx_notify(ble_aprs_rx_notify, NULL);
#endif

    nimble_port_freertos_init(ble_host_task);

    ESP_LOGI(TAG, "Geogram BLE initialized");
    return ESP_OK;
#endif
}

esp_err_t geogram_ble_start(void)
{
#if !CONFIG_BT_ENABLED
    return ESP_ERR_NOT_SUPPORTED;
#else
    if (!s_initialized) {
        esp_err_t ret = geogram_ble_init();
        if (ret != ESP_OK) {
            return ret;
        }
    }

    ble_advertise_start();
    return ESP_OK;
#endif
}

esp_err_t geogram_ble_stop(void)
{
#if !CONFIG_BT_ENABLED
    return ESP_ERR_NOT_SUPPORTED;
#else
    if (!s_initialized) {
        return ESP_OK;
    }

    ble_gap_adv_stop();
    int rc = nimble_port_stop();
    if (rc != 0) {
        ESP_LOGW(TAG, "nimble_port_stop returned rc=%d", rc);
    }

    esp_err_t ret = nimble_port_deinit();
    if (ret != ESP_OK) {
        ESP_LOGW(TAG, "nimble_port_deinit failed: %s", esp_err_to_name(ret));
    }

    ble_reset_all_peers();
    s_initialized = false;
    s_running = false;

    ESP_LOGI(TAG, "Geogram BLE stopped");
    return ESP_OK;
#endif
}

bool geogram_ble_is_running(void)
{
    return s_running;
}
