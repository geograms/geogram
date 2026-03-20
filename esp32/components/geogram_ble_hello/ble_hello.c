/**
 * @file ble_hello.c
 * @brief Standalone BLE HELLO protocol — advertising, scanning, GATT.
 */

#include "ble_hello.h"

#include <string.h>
#include <stdio.h>

#include "esp_log.h"
#include "esp_mac.h"
#include "nvs_flash.h"

#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "host/ble_hs.h"
#include "host/ble_gap.h"
#include "host/ble_gatt.h"
#include "host/util/util.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"
#include "cJSON.h"

static const char *TAG = "ble_hello";

/* ---- Geogram BLE constants ---------------------------------------------- */

#define GEOGRAM_MARKER      0x3E        /* '>' */
#define COMPANY_ID_LO       0xFF        /* test company ID 0xFFFF */
#define COMPANY_ID_HI       0xFF
#define MAX_SEEN            16
#define EXPIRE_SEC          60

/* GATT UUIDs */
#define SVC_UUID            0xFFE0
#define CHR_WRITE_UUID      0xFFF1
#define CHR_NOTIFY_UUID     0xFFF2

/* ---- state -------------------------------------------------------------- */

static bool     s_active;
static char     s_callsign[8];          /* "X3XXXX\0" */
static uint8_t  s_device_id;            /* (MAC hash % 15) + 1 */

/* Manufacturer data: [company_lo, company_hi, marker, device_id, callsign...] */
static uint8_t  s_mfg_data[4 + 6];     /* max 10 bytes */
static uint8_t  s_mfg_len;

/* Seen devices (passive scan) */
typedef struct {
    uint8_t addr[6];
    uint32_t last_seen;                 /* seconds since boot */
} seen_entry_t;

static seen_entry_t s_seen[MAX_SEEN];
static int          s_seen_count;

/* GATT */
static uint16_t s_notify_handle;
static uint16_t s_conn_handle;
static bool     s_conn_active;

/* ---- helpers ------------------------------------------------------------ */

/* Forward declaration */
static int ble_hello_gap_event(struct ble_gap_event *event, void *arg);

static uint32_t now_sec(void)
{
    return (uint32_t)(esp_timer_get_time() / 1000000ULL);
}

static uint8_t compute_device_id(void)
{
    uint8_t mac[6];
    esp_read_mac(mac, ESP_MAC_BT);
    uint32_t h = 2166136261u;
    for (int i = 0; i < 6; i++) {
        h ^= mac[i];
        h *= 16777619u;
    }
    return (uint8_t)((h % 15) + 1);
}

static void build_mfg_data(void)
{
    s_mfg_data[0] = COMPANY_ID_LO;
    s_mfg_data[1] = COMPANY_ID_HI;
    s_mfg_data[2] = GEOGRAM_MARKER;
    s_mfg_data[3] = s_device_id;
    size_t cslen = strlen(s_callsign);
    if (cslen > 6) cslen = 6;
    memcpy(&s_mfg_data[4], s_callsign, cslen);
    s_mfg_len = (uint8_t)(4 + cslen);
}

/* ---- scan tracking ------------------------------------------------------ */

static void track_device(const uint8_t *addr)
{
    uint32_t t = now_sec();

    /* Update existing */
    for (int i = 0; i < s_seen_count; i++) {
        if (memcmp(s_seen[i].addr, addr, 6) == 0) {
            s_seen[i].last_seen = t;
            return;
        }
    }

    /* Add new — evict oldest if full */
    if (s_seen_count < MAX_SEEN) {
        memcpy(s_seen[s_seen_count].addr, addr, 6);
        s_seen[s_seen_count].last_seen = t;
        s_seen_count++;
    } else {
        int oldest = 0;
        for (int i = 1; i < MAX_SEEN; i++) {
            if (s_seen[i].last_seen < s_seen[oldest].last_seen) {
                oldest = i;
            }
        }
        memcpy(s_seen[oldest].addr, addr, 6);
        s_seen[oldest].last_seen = t;
    }
}

/* ---- advertising -------------------------------------------------------- */

static void start_advertise(void)
{
    struct ble_gap_adv_params adv_params = {0};
    adv_params.conn_mode = BLE_GAP_CONN_MODE_UND;  /* connectable for GATT */
    adv_params.disc_mode = BLE_GAP_DISC_MODE_GEN;

    struct ble_hs_adv_fields fields = {0};
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    fields.name = (uint8_t *)s_callsign;
    fields.name_len = strlen(s_callsign);
    fields.name_is_complete = 1;
    fields.mfg_data = s_mfg_data;
    fields.mfg_data_len = s_mfg_len;

    int rc = ble_gap_adv_set_fields(&fields);
    if (rc != 0) {
        ESP_LOGW(TAG, "adv_set_fields failed: %d", rc);
        return;
    }

    rc = ble_gap_adv_start(BLE_OWN_ADDR_PUBLIC, NULL, BLE_HS_FOREVER,
                           &adv_params, ble_hello_gap_event, NULL);
    if (rc != 0 && rc != BLE_HS_EALREADY) {
        ESP_LOGW(TAG, "adv_start failed: %d", rc);
    }
}

/* ---- passive scanning --------------------------------------------------- */

static void start_scan(void)
{
    struct ble_gap_disc_params params = {0};
    params.passive = 1;
    params.itvl = 0x0050;          /* 50 ms */
    params.window = 0x0030;        /* 30 ms */
    params.filter_duplicates = 0;  /* we do our own dedup */

    int rc = ble_gap_disc(BLE_OWN_ADDR_PUBLIC, BLE_HS_FOREVER,
                          &params, ble_hello_gap_event, NULL);
    if (rc != 0 && rc != BLE_HS_EALREADY) {
        ESP_LOGW(TAG, "scan start failed: %d", rc);
    } else {
        ESP_LOGI(TAG, "passive scan started");
    }
}

/* ---- GATT: hello_ack builder -------------------------------------------- */

static void send_hello_ack(uint16_t conn)
{
    cJSON *root = cJSON_CreateObject();
    cJSON_AddNumberToObject(root, "v", 1);
    cJSON_AddStringToObject(root, "type", "hello_ack");

    cJSON *payload = cJSON_AddObjectToObject(root, "payload");
    cJSON_AddBoolToObject(payload, "success", 1);
    cJSON_AddStringToObject(payload, "callsign", s_callsign);
    cJSON *caps = cJSON_AddArrayToObject(payload, "capabilities");
    cJSON_AddItemToArray(caps, cJSON_CreateString("hello"));
    cJSON_AddStringToObject(payload, "platform", "esp32");

    char *json = cJSON_PrintUnformatted(root);
    cJSON_Delete(root);

    if (!json) return;

    struct os_mbuf *om = ble_hs_mbuf_from_flat(json, strlen(json));
    if (om) {
        int rc = ble_gatts_notify_custom(conn, s_notify_handle, om);
        if (rc != 0) {
            ESP_LOGW(TAG, "notify failed: %d", rc);
        } else {
            ESP_LOGI(TAG, "HELLO_ACK sent to conn %d", conn);
        }
    }
    free(json);
}

/* ---- GATT callbacks ----------------------------------------------------- */

static int gatt_write_cb(uint16_t conn_handle, uint16_t attr_handle,
                         struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)attr_handle;
    (void)arg;

    if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR) return 0;

    uint16_t len = OS_MBUF_PKTLEN(ctxt->om);
    if (len == 0 || len > 512) return 0;

    char buf[513];
    uint16_t copied = 0;
    ble_hs_mbuf_to_flat(ctxt->om, buf, sizeof(buf) - 1, &copied);
    buf[copied] = '\0';

    cJSON *root = cJSON_Parse(buf);
    if (!root) return 0;

    cJSON *type = cJSON_GetObjectItem(root, "type");
    if (type && cJSON_IsString(type) && strcmp(type->valuestring, "hello") == 0) {
        ESP_LOGI(TAG, "HELLO received on conn %d", conn_handle);
        send_hello_ack(conn_handle);
    }
    cJSON_Delete(root);
    return 0;
}

static int gatt_notify_cb(uint16_t conn_handle, uint16_t attr_handle,
                          struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)conn_handle;
    (void)attr_handle;
    (void)ctxt;
    (void)arg;
    return 0;
}

/* GATT service definition */
static const struct ble_gatt_svc_def s_gatt_svcs[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = BLE_UUID16_DECLARE(SVC_UUID),
        .characteristics = (struct ble_gatt_chr_def[]) {
            {
                /* Write characteristic — client sends HELLO */
                .uuid = BLE_UUID16_DECLARE(CHR_WRITE_UUID),
                .access_cb = gatt_write_cb,
                .flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_NO_RSP,
            },
            {
                /* Notify characteristic — server sends HELLO_ACK */
                .uuid = BLE_UUID16_DECLARE(CHR_NOTIFY_UUID),
                .access_cb = gatt_notify_cb,
                .val_handle = &s_notify_handle,
                .flags = BLE_GATT_CHR_F_NOTIFY,
            },
            { 0 }, /* sentinel */
        },
    },
    { 0 }, /* sentinel */
};

/* ---- GAP event handler -------------------------------------------------- */

static int ble_hello_gap_event(struct ble_gap_event *event, void *arg)
{
    (void)arg;

    switch (event->type) {

    case BLE_GAP_EVENT_DISC: {
        /* Check manufacturer data for Geogram marker */
        struct ble_hs_adv_fields fields;
        if (ble_hs_adv_parse_fields(&fields, event->disc.data,
                                     event->disc.length_data) != 0) {
            break;
        }
        if (fields.mfg_data && fields.mfg_data_len >= 3 &&
            fields.mfg_data[0] == COMPANY_ID_LO &&
            fields.mfg_data[1] == COMPANY_ID_HI &&
            fields.mfg_data[2] == GEOGRAM_MARKER) {
            track_device(event->disc.addr.val);
        }
        break;
    }

    case BLE_GAP_EVENT_CONNECT:
        if (event->connect.status == 0) {
            s_conn_handle = event->connect.conn_handle;
            s_conn_active = true;
            ESP_LOGI(TAG, "connected — conn_handle=%d", s_conn_handle);
        } else {
            /* Connection failed — restart advertising */
            start_advertise();
        }
        break;

    case BLE_GAP_EVENT_DISCONNECT:
        s_conn_active = false;
        ESP_LOGI(TAG, "disconnected — reason=%d", event->disconnect.reason);
        start_advertise();
        break;

    case BLE_GAP_EVENT_ADV_COMPLETE:
        /* Restart advertising unless we're shutting down */
        if (s_active) {
            start_advertise();
        }
        break;

    default:
        break;
    }

    return 0;
}

/* ---- NimBLE host task + sync -------------------------------------------- */

static void on_sync(void)
{
    /* Use default public address */
    int rc = ble_hs_util_ensure_addr(0);
    if (rc != 0) {
        ESP_LOGE(TAG, "ensure_addr failed: %d", rc);
        return;
    }

    ESP_LOGI(TAG, "BLE host synced — starting adv + scan");
    start_advertise();
    start_scan();
}

static void on_reset(int reason)
{
    ESP_LOGW(TAG, "BLE host reset — reason=%d", reason);
}

static void nimble_host_task(void *param)
{
    (void)param;
    nimble_port_run();          /* blocks until nimble_port_stop() */
    nimble_port_freertos_deinit();
}

/* ---- public API --------------------------------------------------------- */

esp_err_t ble_hello_init(const char *callsign)
{
    if (s_active) return ESP_ERR_INVALID_STATE;
    if (!callsign || strlen(callsign) == 0) return ESP_ERR_INVALID_ARG;

    strncpy(s_callsign, callsign, sizeof(s_callsign) - 1);
    s_callsign[sizeof(s_callsign) - 1] = '\0';
    s_device_id = compute_device_id();
    build_mfg_data();

    memset(s_seen, 0, sizeof(s_seen));
    s_seen_count = 0;
    s_conn_active = false;

    /* NimBLE init */
    int rc = nimble_port_init();
    if (rc != ESP_OK) {
        ESP_LOGE(TAG, "nimble_port_init failed: %d", rc);
        return ESP_FAIL;
    }

    /* Host callbacks */
    ble_hs_cfg.reset_cb = on_reset;
    ble_hs_cfg.sync_cb = on_sync;

    /* GAP device name */
    ble_svc_gap_device_name_set(s_callsign);

    /* GATT init */
    ble_svc_gap_init();
    ble_svc_gatt_init();

    rc = ble_gatts_count_cfg(s_gatt_svcs);
    if (rc != 0) {
        ESP_LOGE(TAG, "gatts_count_cfg failed: %d", rc);
        return ESP_FAIL;
    }
    rc = ble_gatts_add_svcs(s_gatt_svcs);
    if (rc != 0) {
        ESP_LOGE(TAG, "gatts_add_svcs failed: %d", rc);
        return ESP_FAIL;
    }

    /* Start host task */
    nimble_port_freertos_init(nimble_host_task);

    s_active = true;
    ESP_LOGI(TAG, "BLE HELLO active — callsign: %s, device_id: %d", s_callsign, s_device_id);
    return ESP_OK;
}

void ble_hello_stop(void)
{
    if (!s_active) return;
    s_active = false;
    ble_gap_adv_stop();
    ble_gap_disc_cancel();
    nimble_port_stop();
    ESP_LOGI(TAG, "BLE HELLO stopped");
}

int ble_hello_device_count(void)
{
    uint32_t t = now_sec();
    int count = 0;
    for (int i = 0; i < s_seen_count; i++) {
        if ((t - s_seen[i].last_seen) <= EXPIRE_SEC) {
            count++;
        }
    }
    return count;
}

bool ble_hello_is_active(void)
{
    return s_active;
}
