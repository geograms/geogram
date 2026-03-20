/**
 * @file ble_aprs.c
 * @brief BlueAPRS — APRS over BLE advertisements (observer+broadcaster)
 *
 * Uses NimBLE in non-connectable mode: no GATT server, no connection state,
 * minimal heap footprint (~8KB vs ~50KB for full GATT).
 */

#include "ble_aprs.h"

#include <string.h>
#include "esp_log.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "host/ble_hs.h"
#include "host/ble_gap.h"
#include "freertos/FreeRTOS.h"
#include "freertos/timers.h"

static const char *TAG = "ble_aprs";

/* --- Protocol constants --- */
#define GEOGRAM_MARKER    0x3E
#define SUBTYPE_PRIMARY   0x41  /* 'A' */
#define SUBTYPE_CONT      0x42  /* 'B' */
#define COMPANY_ID_LO     0xFF
#define COMPANY_ID_HI     0xFF

/* Header: company_id(2) + marker(1) + subtype(1) + seq(1) + flags(1) = 6 */
#define ADV_HEADER_LEN    6
/* Max BLE ADV manufacturer data = 24 bytes (31 - 2 len/type - 3 flags - 2 mfg type) */
#define ADV_MFG_MAX       24
#define ADV_PAYLOAD_MAX   (ADV_MFG_MAX - ADV_HEADER_LEN)  /* 18 bytes */

/* SCAN_RSP header: company_id(2) + marker(1) + subtype(1) + seq(1) = 5 */
#define RSP_HEADER_LEN    5
#define RSP_MFG_MAX       24
#define RSP_PAYLOAD_MAX   (RSP_MFG_MAX - RSP_HEADER_LEN)  /* 19 bytes */

/* Dedup ring */
#define DEDUP_RING_SIZE   16

/* Partial reassembly timeout */
#define PARTIAL_TIMEOUT_MS 500

/* --- State --- */
static ble_aprs_rx_cb_t s_rx_cb;
static void            *s_rx_ctx;
static bool             s_active;
static uint8_t          s_tx_seq;
static TimerHandle_t    s_adv_timer;
static bool             s_scanning;

/* Dedup ring: hash of BLE address + seq */
static struct {
    uint32_t hash;
    uint8_t  seq;
} s_dedup[DEDUP_RING_SIZE];
static int s_dedup_idx;

/* Partial frame waiting for SCAN_RSP continuation */
static struct {
    uint8_t  seq;
    uint8_t  addr_hash;  /* low byte of address hash */
    char     data[ADV_PAYLOAD_MAX + 1];
    int      len;
    TickType_t tick;
} s_partial;

/* --- Helpers --- */

static uint32_t addr_hash(const ble_addr_t *addr)
{
    /* Simple FNV-1a over 6-byte address */
    uint32_t h = 2166136261u;
    for (int i = 0; i < 6; i++) {
        h ^= addr->val[i];
        h *= 16777619u;
    }
    return h;
}

static bool dedup_check_and_add(const ble_addr_t *addr, uint8_t seq)
{
    uint32_t h = addr_hash(addr);
    for (int i = 0; i < DEDUP_RING_SIZE; i++) {
        if (s_dedup[i].hash == h && s_dedup[i].seq == seq) {
            return true;  /* duplicate */
        }
    }
    s_dedup[s_dedup_idx].hash = h;
    s_dedup[s_dedup_idx].seq = seq;
    s_dedup_idx = (s_dedup_idx + 1) % DEDUP_RING_SIZE;
    return false;
}

/* --- Scan handling --- */

static void deliver_frame(const char *tnc2, int len, int rssi)
{
    if (!s_rx_cb || len <= 0) return;

    char buf[BLE_APRS_MAX_TNC2_LEN + 1];
    if (len > BLE_APRS_MAX_TNC2_LEN) len = BLE_APRS_MAX_TNC2_LEN;
    memcpy(buf, tnc2, len);
    buf[len] = '\0';

    ESP_LOGI(TAG, "RX (rssi=%d): %s", rssi, buf);
    s_rx_cb(buf, rssi, s_rx_ctx);
}

/**
 * Parse manufacturer data looking for Geogram BlueAPRS marker.
 * Returns pointer to start of mfg data within the ad, or NULL.
 */
static const uint8_t *find_mfg_data(const uint8_t *ad, uint8_t ad_len, uint8_t *out_len)
{
    int i = 0;
    while (i + 1 < ad_len) {
        uint8_t field_len = ad[i];
        if (field_len == 0 || i + 1 + field_len > ad_len) break;

        uint8_t field_type = ad[i + 1];
        if (field_type == 0xFF && field_len >= 3) {
            /* Manufacturer Specific Data */
            const uint8_t *mfg = &ad[i + 2];
            uint8_t mfg_len = field_len - 1;  /* exclude type byte */
            if (out_len) *out_len = mfg_len;
            return mfg;
        }
        i += 1 + field_len;
    }
    return NULL;
}

static void handle_adv(const struct ble_gap_disc_desc *desc)
{
    uint8_t mfg_len = 0;
    const uint8_t *mfg = find_mfg_data(desc->data, desc->length_data, &mfg_len);
    if (!mfg || mfg_len < ADV_HEADER_LEN) return;

    /* Check Geogram marker */
    if (mfg[0] != COMPANY_ID_LO || mfg[1] != COMPANY_ID_HI || mfg[2] != GEOGRAM_MARKER) return;

    uint8_t subtype = mfg[3];
    uint8_t seq = mfg[4];

    if (subtype == SUBTYPE_PRIMARY) {
        uint8_t flags = mfg[5];
        int payload_len = mfg_len - ADV_HEADER_LEN;
        const uint8_t *payload = &mfg[ADV_HEADER_LEN];

        if (flags & 0x01) {
            /* Has continuation — stash partial, wait for SCAN_RSP */
            s_partial.seq = seq;
            s_partial.addr_hash = (uint8_t)(addr_hash(&desc->addr) & 0xFF);
            if (payload_len > ADV_PAYLOAD_MAX) payload_len = ADV_PAYLOAD_MAX;
            memcpy(s_partial.data, payload, payload_len);
            s_partial.len = payload_len;
            s_partial.tick = xTaskGetTickCount();
        } else {
            /* Complete frame in ADV_IND */
            if (dedup_check_and_add(&desc->addr, seq)) return;
            deliver_frame((const char *)payload, payload_len, desc->rssi);
        }
    } else if (subtype == SUBTYPE_CONT) {
        /* SCAN_RSP continuation */
        if (s_partial.len == 0) return;

        /* Check seq and address match */
        uint8_t ah = (uint8_t)(addr_hash(&desc->addr) & 0xFF);
        if (seq != s_partial.seq || ah != s_partial.addr_hash) return;

        /* Check timeout */
        if ((xTaskGetTickCount() - s_partial.tick) > pdMS_TO_TICKS(PARTIAL_TIMEOUT_MS)) {
            s_partial.len = 0;
            return;
        }

        if (dedup_check_and_add(&desc->addr, seq)) {
            s_partial.len = 0;
            return;
        }

        /* Reassemble */
        int cont_len = mfg_len - RSP_HEADER_LEN;
        const uint8_t *cont = &mfg[RSP_HEADER_LEN];

        char full[BLE_APRS_MAX_TNC2_LEN + 1];
        int total = s_partial.len + cont_len;
        if (total > BLE_APRS_MAX_TNC2_LEN) total = BLE_APRS_MAX_TNC2_LEN;

        memcpy(full, s_partial.data, s_partial.len);
        int copy2 = total - s_partial.len;
        if (copy2 > 0) memcpy(full + s_partial.len, cont, copy2);

        s_partial.len = 0;
        deliver_frame(full, total, desc->rssi);
    }
}

static int gap_event_cb(struct ble_gap_event *event, void *arg)
{
    switch (event->type) {
    case BLE_GAP_EVENT_DISC:
        handle_adv(&event->disc);
        break;
    case BLE_GAP_EVENT_DISC_COMPLETE:
        /* Scan finished — restart unless we're advertising */
        if (s_active && !ble_gap_adv_active()) {
            ble_aprs_scan_start();
        }
        break;
    default:
        break;
    }
    return 0;
}

/* --- Advertise --- */

static void adv_timer_cb(TimerHandle_t xTimer)
{
    (void)xTimer;
    ble_gap_adv_stop();
    ESP_LOGD(TAG, "ADV stopped, resuming scan");
    ble_aprs_scan_start();
}

esp_err_t ble_aprs_advertise(const char *tnc2, uint32_t duration_ms)
{
    if (!s_active) return ESP_ERR_INVALID_STATE;
    if (!tnc2) return ESP_ERR_INVALID_ARG;

    int tnc2_len = strlen(tnc2);
    if (tnc2_len > BLE_APRS_MAX_TNC2_LEN) tnc2_len = BLE_APRS_MAX_TNC2_LEN;

    uint8_t seq = s_tx_seq++;
    bool needs_cont = (tnc2_len > ADV_PAYLOAD_MAX);
    int first_len = needs_cont ? ADV_PAYLOAD_MAX : tnc2_len;

    /* Build ADV_IND manufacturer data */
    uint8_t adv_mfg[ADV_MFG_MAX];
    adv_mfg[0] = COMPANY_ID_LO;
    adv_mfg[1] = COMPANY_ID_HI;
    adv_mfg[2] = GEOGRAM_MARKER;
    adv_mfg[3] = SUBTYPE_PRIMARY;
    adv_mfg[4] = seq;
    adv_mfg[5] = needs_cont ? 0x01 : 0x00;
    memcpy(&adv_mfg[ADV_HEADER_LEN], tnc2, first_len);
    int adv_mfg_len = ADV_HEADER_LEN + first_len;

    /* Build AD fields for ADV_IND */
    struct ble_hs_adv_fields adv_fields = {0};
    adv_fields.flags = BLE_HS_ADV_F_BREDR_UNSUP;
    adv_fields.mfg_data = adv_mfg;
    adv_fields.mfg_data_len = adv_mfg_len;

    /* Build SCAN_RSP if needed */
    struct ble_hs_adv_fields rsp_fields = {0};
    uint8_t rsp_mfg[RSP_MFG_MAX];
    if (needs_cont) {
        int cont_len = tnc2_len - first_len;
        if (cont_len > RSP_PAYLOAD_MAX) cont_len = RSP_PAYLOAD_MAX;

        rsp_mfg[0] = COMPANY_ID_LO;
        rsp_mfg[1] = COMPANY_ID_HI;
        rsp_mfg[2] = GEOGRAM_MARKER;
        rsp_mfg[3] = SUBTYPE_CONT;
        rsp_mfg[4] = seq;
        memcpy(&rsp_mfg[RSP_HEADER_LEN], tnc2 + first_len, cont_len);

        rsp_fields.mfg_data = rsp_mfg;
        rsp_fields.mfg_data_len = RSP_HEADER_LEN + cont_len;
    }

    /* Stop scanning first (single radio) — brief delay for NimBLE to settle */
    ble_aprs_scan_stop();
    vTaskDelay(pdMS_TO_TICKS(10));

    int rc = ble_gap_adv_set_fields(&adv_fields);
    if (rc != 0) {
        ESP_LOGE(TAG, "adv_set_fields failed: %d", rc);
        ble_aprs_scan_start();
        return ESP_FAIL;
    }

    if (needs_cont) {
        rc = ble_gap_adv_rsp_set_fields(&rsp_fields);
        if (rc != 0) {
            ESP_LOGE(TAG, "adv_rsp_set_fields failed: %d", rc);
            ble_aprs_scan_start();
            return ESP_FAIL;
        }
    }

    /* Non-connectable advertising */
    struct ble_gap_adv_params adv_params = {0};
    adv_params.conn_mode = BLE_GAP_CONN_MODE_NON;
    if (needs_cont) {
        adv_params.disc_mode = BLE_GAP_DISC_MODE_GEN;  /* scannable for RSP */
    } else {
        adv_params.disc_mode = BLE_GAP_DISC_MODE_NON;
    }
    adv_params.itvl_min = BLE_GAP_ADV_ITVL_MS(100);
    adv_params.itvl_max = BLE_GAP_ADV_ITVL_MS(150);

    rc = ble_gap_adv_start(BLE_OWN_ADDR_RANDOM, NULL, BLE_HS_FOREVER,
                           &adv_params, NULL, NULL);
    if (rc != 0) {
        ESP_LOGE(TAG, "adv_start failed: %d", rc);
        ble_aprs_scan_start();
        return ESP_FAIL;
    }

    ESP_LOGI(TAG, "TX (seq=%u, len=%d): %.*s", seq, tnc2_len, tnc2_len, tnc2);

    /* Schedule stop + resume scan */
    if (duration_ms == 0) duration_ms = 100;
    xTimerChangePeriod(s_adv_timer, pdMS_TO_TICKS(duration_ms), portMAX_DELAY);
    xTimerStart(s_adv_timer, portMAX_DELAY);

    return ESP_OK;
}

/* --- Scan --- */

esp_err_t ble_aprs_scan_start(void)
{
    if (!s_active) return ESP_ERR_INVALID_STATE;
    if (s_scanning) return ESP_OK;

    struct ble_gap_disc_params scan_params = {0};
    scan_params.passive = 0;  /* active scan to get SCAN_RSP */
    scan_params.itvl = BLE_GAP_SCAN_ITVL_MS(100);
    scan_params.window = BLE_GAP_SCAN_WIN_MS(50);
    scan_params.filter_duplicates = 0;  /* we do our own dedup */
    scan_params.limited = 0;

    int rc = ble_gap_disc(BLE_OWN_ADDR_RANDOM, BLE_HS_FOREVER,
                          &scan_params, gap_event_cb, NULL);
    if (rc == 0) {
        s_scanning = true;
        ESP_LOGD(TAG, "Scan started");
    } else if (rc == BLE_HS_EALREADY) {
        s_scanning = true;
    } else {
        ESP_LOGW(TAG, "Scan start failed: %d", rc);
        return ESP_FAIL;
    }
    return ESP_OK;
}

void ble_aprs_scan_stop(void)
{
    if (s_scanning) {
        ble_gap_disc_cancel();
        s_scanning = false;
    }
}

bool ble_aprs_is_active(void)
{
    return s_active;
}

/* --- Init --- */

static void on_sync(void)
{
    /* Use random address (no public address needed for observer+broadcaster) */
    uint8_t addr_type = 0;
    int rc = ble_hs_id_infer_auto(1, &addr_type);
    if (rc != 0) {
        ESP_LOGW(TAG, "ble_hs_id_infer_auto failed: %d", rc);
    }

    ESP_LOGI(TAG, "BLE host synced — starting scan");
    ble_aprs_scan_start();
}

static void on_reset(int reason)
{
    ESP_LOGW(TAG, "BLE host reset: reason=%d", reason);
    s_scanning = false;
}

static void ble_host_task(void *param)
{
    (void)param;
    ESP_LOGI(TAG, "NimBLE host task started");
    nimble_port_run();
    nimble_port_freertos_deinit();
}

esp_err_t ble_aprs_init(ble_aprs_rx_cb_t rx_cb, void *rx_ctx)
{
    if (s_active) return ESP_OK;

    ESP_LOGI(TAG, "Initializing BlueAPRS (observer+broadcaster)");
    ESP_LOGI(TAG, "Free heap before init: %lu", (unsigned long)esp_get_free_heap_size());

    s_rx_cb = rx_cb;
    s_rx_ctx = rx_ctx;

    /* Create advertise-stop timer */
    s_adv_timer = xTimerCreate("ble_aprs_adv", pdMS_TO_TICKS(1000),
                               pdFALSE, NULL, adv_timer_cb);
    if (!s_adv_timer) {
        ESP_LOGE(TAG, "Failed to create adv timer");
        return ESP_ERR_NO_MEM;
    }

    /* Initialize NimBLE */
    esp_err_t ret = nimble_port_init();
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "nimble_port_init failed: %s", esp_err_to_name(ret));
        return ret;
    }

    /* Configure host — no GATT, no GAP service */
    ble_hs_cfg.sync_cb = on_sync;
    ble_hs_cfg.reset_cb = on_reset;

    /* Start NimBLE host task */
    nimble_port_freertos_init(ble_host_task);

    s_active = true;
    ESP_LOGI(TAG, "BlueAPRS active (free heap: %lu)", (unsigned long)esp_get_free_heap_size());

    return ESP_OK;
}
