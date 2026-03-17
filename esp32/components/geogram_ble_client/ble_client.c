/**
 * @file ble_client.c
 * @brief BLE central (GATT client) — connects to Geogram peripheral, exchanges APRS
 *
 * Protocol: both directions stream raw JSON bytes chunked by MTU.
 * Receiver reassembles by accumulating bytes in a buffer and extracting
 * complete JSON objects via brace-matching (geoblue_find_json_object_bounds).
 *
 * Flow: scan → connect → MTU exchange → discover service 0xFFE0 →
 *       discover chars → subscribe to 0xFFF2 notify → send HELLO on 0xFFF1 →
 *       exchange _aprs DATA frames.
 */

#include "ble_client.h"
#include "app_config.h"

#if CONFIG_BT_ENABLED

#include <string.h>
#include <stdio.h>
#include <time.h>
#include "cJSON.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/timers.h"
#include "geoblue.h"
#include "nostr_keys.h"
#include "station.h"

#include "host/ble_hs.h"
#include "host/ble_gap.h"
#include "host/ble_gatt.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

static const char *TAG = "ble_client";

// Geogram BLE UUIDs (must match geogram_ble.c)
#define GEOGRAM_SVC_UUID16       0xFFE0
#define GEOGRAM_CHAR_WRITE16     0xFFF1
#define GEOGRAM_CHAR_NOTIFY16    0xFFF2
#define GEOGRAM_BLE_MARKER       0x3E

// Connection state
static bool s_initialized = false;
static bool s_connected = false;
static bool s_scanning = false;
static bool s_hello_sent = false;
static uint16_t s_conn_handle = 0;
static uint16_t s_write_handle = 0;
static uint16_t s_notify_handle = 0;

// RX reassembly buffer — accumulates notification chunks until a complete
// JSON object (matched braces) is found, mirroring the server's rx_buffer.
#define RX_BUF_SIZE 2048
static uint8_t s_rx_buf[RX_BUF_SIZE];
static size_t s_rx_len = 0;

// Service discovery state
static uint16_t s_svc_start = 0;
static uint16_t s_svc_end = 0;

// Forward declarations
static void ble_client_scan_start(void);
static int ble_client_gap_event(struct ble_gap_event *event, void *arg);

// Timer for deferred scan restart (avoids blocking NimBLE host task)
static TimerHandle_t s_rescan_timer = NULL;

static void rescan_timer_cb(TimerHandle_t t)
{
    (void)t;
    ble_client_scan_start();
}

static void schedule_rescan(uint32_t delay_ms)
{
    if (!s_rescan_timer) {
        s_rescan_timer = xTimerCreate("rescan", pdMS_TO_TICKS(delay_ms),
                                       pdFALSE, NULL, rescan_timer_cb);
    }
    if (s_rescan_timer) {
        xTimerChangePeriod(s_rescan_timer, pdMS_TO_TICKS(delay_ms), 0);
        xTimerStart(s_rescan_timer, 0);
    }
}

// ============================================================================
// Helpers
// ============================================================================

static const char *client_callsign(void)
{
    const char *cs = station_get_callsign();
    return (cs && cs[0] != '\0') ? cs : "DONGLE";
}

/**
 * Write a JSON string to the GATT write characteristic, chunked at MTU.
 * Mirrors ble_notify_json() on the server side — raw byte chunks, no framing.
 */
static int ble_client_write_str(const char *json)
{
    if (!s_connected || s_write_handle == 0) return -1;

    size_t len = strlen(json);
    uint16_t mtu = ble_att_mtu(s_conn_handle);
    size_t chunk = (mtu > 3) ? (size_t)(mtu - 3) : 20;

    for (size_t offset = 0; offset < len; ) {
        size_t send_len = len - offset;
        if (send_len > chunk) send_len = chunk;

        int rc = ble_gattc_write_no_rsp_flat(s_conn_handle, s_write_handle,
                                              json + offset, send_len);
        if (rc != 0) {
            ESP_LOGW(TAG, "write failed at offset %u: rc=%d", (unsigned)offset, rc);
            return rc;
        }
        offset += send_len;
    }
    return 0;
}

static void ble_client_send_hello(void)
{
    const char *caps[] = {"chat", "hello", "data", "aprs"};
    char *json = geoblue_build_hello_frame(
        "dongle-hello-1",
        client_callsign(),
        NULL,
        "T-Dongle-S3",
        caps, 4);
    if (!json) return;

    ESP_LOGI(TAG, "HELLO TX (%u bytes)", (unsigned)strlen(json));
    int rc = ble_client_write_str(json);
    free(json);
    if (rc == 0) {
        s_hello_sent = true;
    }
}

// ============================================================================
// RX reassembly — mirrors ble_process_peer_buffer() from geogram_ble.c
// ============================================================================

static void process_rx_frame(const char *json, size_t len)
{
    cJSON *root = cJSON_ParseWithLength(json, len);
    if (!root) {
        ESP_LOGW(TAG, "RX: parse failed (%u bytes)", (unsigned)len);
        return;
    }

    cJSON *type_item = cJSON_GetObjectItemCaseSensitive(root, "type");
    const char *type = cJSON_IsString(type_item) ? type_item->valuestring : "";

    if (strcmp(type, "hello_ack") == 0 || strcmp(type, "HELLO_ACK") == 0) {
        cJSON *payload = cJSON_GetObjectItemCaseSensitive(root, "payload");
        cJSON *cs = payload ? cJSON_GetObjectItemCaseSensitive(payload, "callsign") : NULL;
        ESP_LOGI(TAG, "HELLO_ACK from %s",
                 cJSON_IsString(cs) ? cs->valuestring : "?");
    } else if (strcmp(type, "hello") == 0 || strcmp(type, "HELLO") == 0) {
        cJSON *payload = cJSON_GetObjectItemCaseSensitive(root, "payload");
        cJSON *cs = payload ? cJSON_GetObjectItemCaseSensitive(payload, "callsign") : NULL;
        ESP_LOGI(TAG, "HELLO from %s",
                 cJSON_IsString(cs) ? cs->valuestring : "?");
    } else if (strcmp(type, "data") == 0 || strcmp(type, "DATA") == 0) {
        cJSON *payload = cJSON_GetObjectItemCaseSensitive(root, "payload");
        if (payload) {
            cJSON *channel = cJSON_GetObjectItemCaseSensitive(payload, "channel");
            cJSON *from = cJSON_GetObjectItemCaseSensitive(payload, "from");
            cJSON *content = cJSON_GetObjectItemCaseSensitive(payload, "content");
            const char *ch = cJSON_IsString(channel) ? channel->valuestring : "?";
            const char *fr = cJSON_IsString(from) ? from->valuestring : "?";
            const char *ct = cJSON_IsString(content) ? content->valuestring : "";

            if (strcmp(ch, "_aprs") == 0 && ct[0] != '\0') {
                cJSON *aprs = cJSON_Parse(ct);
                if (aprs) {
                    cJSON *af = cJSON_GetObjectItemCaseSensitive(aprs, "from");
                    cJSON *at = cJSON_GetObjectItemCaseSensitive(aprs, "to");
                    cJSON *ax = cJSON_GetObjectItemCaseSensitive(aprs, "text");
                    ESP_LOGI(TAG, "APRS RX: %s -> %s: %s",
                             cJSON_IsString(af) ? af->valuestring : "?",
                             cJSON_IsString(at) ? at->valuestring : "?",
                             cJSON_IsString(ax) ? ax->valuestring : "");
                    cJSON_Delete(aprs);
                } else {
                    ESP_LOGI(TAG, "DATA [%s] from=%s: %s", ch, fr, ct);
                }
            } else {
                ESP_LOGI(TAG, "DATA [%s] from=%s", ch, fr);
            }
        }
    } else {
        ESP_LOGI(TAG, "RX type=%s (%u bytes)", type, (unsigned)len);
    }

    cJSON_Delete(root);
}

/**
 * Accumulate notification chunks and extract complete JSON objects.
 * Exact same algorithm as ble_process_peer_buffer() in geogram_ble.c.
 */
static void handle_rx_data(const uint8_t *data, size_t len)
{
    if (s_rx_len + len > RX_BUF_SIZE) {
        ESP_LOGW(TAG, "RX overflow (%u + %u > %u), reset",
                 (unsigned)s_rx_len, (unsigned)len, RX_BUF_SIZE);
        s_rx_len = 0;
    }
    memcpy(s_rx_buf + s_rx_len, data, len);
    s_rx_len += len;

    while (s_rx_len > 0) {
        size_t json_start = 0, json_end = 0, discard_prefix = 0;
        bool incomplete = false;

        bool found = geoblue_find_json_object_bounds(
            s_rx_buf, s_rx_len,
            &json_start, &json_end, &discard_prefix, &incomplete);

        if (!found) {
            if (discard_prefix > 0 && discard_prefix <= s_rx_len) {
                memmove(s_rx_buf, s_rx_buf + discard_prefix,
                        s_rx_len - discard_prefix);
                s_rx_len -= discard_prefix;
            }
            if (!incomplete) {
                s_rx_len = 0;
            }
            return;
        }

        // discard_prefix == json_start (bytes before the opening '{')
        if (discard_prefix > 0) {
            memmove(s_rx_buf, s_rx_buf + discard_prefix,
                    s_rx_len - discard_prefix);
            s_rx_len -= discard_prefix;
            json_end -= discard_prefix;
            json_start = 0;
        }

        // json_end is inclusive (index of closing '}')
        size_t json_len = json_end - json_start + 1;
        char *json_str = malloc(json_len + 1);
        if (!json_str) {
            s_rx_len = 0;
            return;
        }
        memcpy(json_str, s_rx_buf + json_start, json_len);
        json_str[json_len] = '\0';

        // Consume from buffer
        memmove(s_rx_buf, s_rx_buf + json_len, s_rx_len - json_len);
        s_rx_len -= json_len;

        process_rx_frame(json_str, json_len);
        free(json_str);
    }
}

// ============================================================================
// GATT client callbacks
// ============================================================================

static int on_subscribe(uint16_t conn_handle, const struct ble_gatt_error *error,
                        struct ble_gatt_attr *attr, void *arg)
{
    if (error->status == 0) {
        ESP_LOGI(TAG, "Subscribed to notifications");
        ble_client_send_hello();
    } else {
        ESP_LOGW(TAG, "Subscribe failed: %d", error->status);
    }
    return 0;
}

static int on_disc_chr(uint16_t conn_handle, const struct ble_gatt_error *error,
                       const struct ble_gatt_chr *chr, void *arg)
{
    if (error->status == 0 && chr) {
        uint16_t uuid16 = ble_uuid_u16(&chr->uuid.u);
        if (uuid16 == GEOGRAM_CHAR_WRITE16) {
            s_write_handle = chr->val_handle;
        } else if (uuid16 == GEOGRAM_CHAR_NOTIFY16) {
            s_notify_handle = chr->val_handle;
        }
    } else if (error->status == BLE_HS_EDONE) {
        ESP_LOGI(TAG, "Discovery done: write=%u notify=%u",
                 s_write_handle, s_notify_handle);
        if (s_notify_handle != 0) {
            uint8_t val[2] = {0x01, 0x00};  // Enable notifications (CCCD)
            ble_gattc_write_flat(conn_handle, s_notify_handle + 1,
                                 val, sizeof(val), on_subscribe, NULL);
        }
    }
    return 0;
}

static int svc_disc_cb(uint16_t conn_handle, const struct ble_gatt_error *error,
                       const struct ble_gatt_svc *service, void *arg)
{
    if (error->status == 0 && service) {
        uint16_t uuid16 = ble_uuid_u16(&service->uuid.u);
        if (uuid16 == GEOGRAM_SVC_UUID16) {
            s_svc_start = service->start_handle;
            s_svc_end = service->end_handle;
        }
    } else if (error->status == BLE_HS_EDONE) {
        if (s_svc_start > 0 && s_svc_end > 0) {
            ESP_LOGI(TAG, "Geogram service: handles %u-%u", s_svc_start, s_svc_end);
            ble_gattc_disc_all_chrs(conn_handle, s_svc_start, s_svc_end,
                                     on_disc_chr, NULL);
        } else {
            ESP_LOGW(TAG, "Geogram service 0x%04X not found", GEOGRAM_SVC_UUID16);
        }
    } else {
        ESP_LOGW(TAG, "svc_disc error: %d", error->status);
    }
    return 0;
}

// Post-connect task — runs service discovery off the NimBLE host stack
static void connect_task(void *arg)
{
    uint16_t conn = (uint16_t)(uintptr_t)arg;

    // Wait for MTU exchange to complete
    vTaskDelay(pdMS_TO_TICKS(300));

    if (!s_connected || s_conn_handle != conn) {
        vTaskDelete(NULL);
        return;
    }

    s_svc_start = 0;
    s_svc_end = 0;
    int rc = ble_gattc_disc_all_svcs(conn, svc_disc_cb, NULL);
    if (rc != 0) {
        ESP_LOGW(TAG, "disc_all_svcs rc=%d", rc);
    }

    vTaskDelete(NULL);
}

// ============================================================================
// GAP event handler — runs on NimBLE host task, must not block
// ============================================================================

static int ble_client_gap_event(struct ble_gap_event *event, void *arg)
{
    switch (event->type) {
    case BLE_GAP_EVENT_DISC: {
        struct ble_hs_adv_fields fields;
        if (ble_hs_adv_parse_fields(&fields, event->disc.data,
                                     event->disc.length_data) != 0) {
            break;
        }

        bool found = false;

        // Match by 16-bit service UUID
        for (int i = 0; i < fields.num_uuids16; i++) {
            if (ble_uuid_u16(&fields.uuids16[i].u) == GEOGRAM_SVC_UUID16) {
                found = true;
                break;
            }
        }

        // Match by manufacturer data marker
        if (!found && fields.mfg_data_len >= 3 &&
            fields.mfg_data[0] == 0xFF && fields.mfg_data[1] == 0xFF &&
            fields.mfg_data[2] == GEOGRAM_BLE_MARKER) {
            found = true;
        }

        // Match by name
        if (!found && fields.name_len >= 7 &&
            memcmp(fields.name, "Geogram", 7) == 0) {
            found = true;
        }

        if (found) {
            ESP_LOGI(TAG, "Found Geogram: " MACSTR " type=%d",
                     MAC2STR(event->disc.addr.val), event->disc.addr.type);
            ble_gap_disc_cancel();
            s_scanning = false;

            int rc = ble_gap_connect(BLE_OWN_ADDR_PUBLIC, &event->disc.addr,
                                     30000, NULL, ble_client_gap_event, NULL);
            if (rc != 0) {
                ESP_LOGW(TAG, "ble_gap_connect rc=%d", rc);
                schedule_rescan(2000);
            }
        }
        break;
    }

    case BLE_GAP_EVENT_CONNECT:
        if (event->connect.status == 0) {
            s_conn_handle = event->connect.conn_handle;
            s_connected = true;
            s_write_handle = 0;
            s_notify_handle = 0;
            s_hello_sent = false;
            s_rx_len = 0;

            ESP_LOGI(TAG, "Connected conn=%u", s_conn_handle);

            ble_att_set_preferred_mtu(512);
            ble_gattc_exchange_mtu(s_conn_handle, NULL, NULL);

            // Run discovery on a separate task to avoid blocking NimBLE host
            xTaskCreate(connect_task, "ble_disc", 4096,
                        (void *)(uintptr_t)s_conn_handle, 5, NULL);
        } else {
            ESP_LOGW(TAG, "Connect failed: %d", event->connect.status);
            s_connected = false;
            schedule_rescan(2000);
        }
        break;

    case BLE_GAP_EVENT_DISCONNECT:
        ESP_LOGW(TAG, "Disconnected reason=%d", event->disconnect.reason);
        s_connected = false;
        s_write_handle = 0;
        s_notify_handle = 0;
        s_hello_sent = false;
        s_rx_len = 0;
        schedule_rescan(2000);
        break;

    case BLE_GAP_EVENT_NOTIFY_RX: {
        uint16_t data_len = OS_MBUF_PKTLEN(event->notify_rx.om);
        if (data_len == 0) break;

        uint8_t *tmp = malloc(data_len);
        if (!tmp) break;
        os_mbuf_copydata(event->notify_rx.om, 0, data_len, tmp);
        handle_rx_data(tmp, data_len);
        free(tmp);
        break;
    }

    case BLE_GAP_EVENT_MTU:
        ESP_LOGI(TAG, "MTU: %u", event->mtu.value);
        break;

    case BLE_GAP_EVENT_DISC_COMPLETE:
        s_scanning = false;
        if (!s_connected) {
            schedule_rescan(1000);
        }
        break;

    default:
        break;
    }
    return 0;
}

// ============================================================================
// Scan
// ============================================================================

static void ble_client_scan_start(void)
{
    if (s_scanning || s_connected) return;

    struct ble_gap_disc_params params = {
        .filter_duplicates = 1,
        .passive = 0,
    };

    int rc = ble_gap_disc(BLE_OWN_ADDR_PUBLIC, 10000, &params,
                           ble_client_gap_event, NULL);
    if (rc == 0) {
        s_scanning = true;
        ESP_LOGI(TAG, "Scanning...");
    } else {
        ESP_LOGW(TAG, "Scan failed: rc=%d", rc);
    }
}

// ============================================================================
// NimBLE host callbacks
// ============================================================================

static void ble_client_on_sync(void)
{
    ESP_LOGI(TAG, "BLE synced");
    ble_client_scan_start();
}

static void ble_client_on_reset(int reason)
{
    ESP_LOGW(TAG, "BLE reset: %d", reason);
}

static void ble_host_task(void *param)
{
    nimble_port_run();
    nimble_port_freertos_deinit();
}

// ============================================================================
// Public API
// ============================================================================

esp_err_t ble_client_init(void)
{
    if (s_initialized) return ESP_OK;

    station_init();
    if (!nostr_keys_available()) {
        nostr_keys_init();
    }

    esp_err_t ret = nimble_port_init();
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "nimble_port_init: %s", esp_err_to_name(ret));
        return ret;
    }

    ble_hs_cfg.reset_cb = ble_client_on_reset;
    ble_hs_cfg.sync_cb = ble_client_on_sync;

    ble_svc_gap_init();
    ble_svc_gatt_init();
    ble_svc_gap_device_name_set("Geogram-Dongle");

    s_initialized = true;
    nimble_port_freertos_init(ble_host_task);

    ESP_LOGI(TAG, "BLE client ready");
    return ESP_OK;
}

esp_err_t ble_client_send_aprs(const char *to, const char *text)
{
    if (!s_connected || s_write_handle == 0 || !s_hello_sent) {
        return ESP_ERR_INVALID_STATE;
    }

    // Build APRS payload: {"to":"...","text":"...","type":"message"}
    cJSON *aprs = cJSON_CreateObject();
    if (!aprs) return ESP_ERR_NO_MEM;
    cJSON_AddStringToObject(aprs, "to", to);
    cJSON_AddStringToObject(aprs, "text", text);
    cJSON_AddStringToObject(aprs, "type", "message");
    char *payload_str = cJSON_PrintUnformatted(aprs);
    cJSON_Delete(aprs);
    if (!payload_str) return ESP_ERR_NO_MEM;

    // Wrap in Geoblue DATA frame on _aprs channel
    char frame_id[48];
    snprintf(frame_id, sizeof(frame_id), "aprs-%lu",
             (unsigned long)esp_log_timestamp());

    char *frame = geoblue_build_data_frame(
        frame_id, client_callsign(), NULL, "_aprs",
        payload_str, (int64_t)time(NULL));
    free(payload_str);
    if (!frame) return ESP_ERR_NO_MEM;

    ESP_LOGI(TAG, "APRS TX: %s -> %s: %s", client_callsign(), to, text);
    int rc = ble_client_write_str(frame);
    free(frame);

    return rc == 0 ? ESP_OK : ESP_FAIL;
}

bool ble_client_is_connected(void)
{
    return s_connected && s_write_handle != 0 && s_hello_sent;
}

#else // !CONFIG_BT_ENABLED

esp_err_t ble_client_init(void) { return ESP_ERR_NOT_SUPPORTED; }
esp_err_t ble_client_send_aprs(const char *to, const char *text) {
    (void)to; (void)text; return ESP_ERR_NOT_SUPPORTED;
}
bool ble_client_is_connected(void) { return false; }

#endif
