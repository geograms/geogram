/**
 * @file ble_aprs.h
 * @brief BlueAPRS — APRS over BLE advertisements (observer+broadcaster)
 *
 * No GATT, no connections, no pairing. One device advertises a TNC2 frame
 * as manufacturer data, any nearby scanner picks it up.
 *
 * Advertisement format (ADV_IND manufacturer data):
 *   [0xFF 0xFF]  Company ID (unregistered)
 *   [0x3E]       Geogram marker
 *   [0x41]       BlueAPRS sub-type ('A')
 *   [seq]        uint8 dedup counter
 *   [flags]      bit0 = has SCAN_RSP continuation
 *   [tnc2...]    TNC2 frame bytes (up to 18 bytes)
 *
 * SCAN_RSP continuation (when flags bit0 set):
 *   [0xFF 0xFF]  Company ID
 *   [0x3E]       Geogram marker
 *   [0x42]       BlueAPRS continuation ('B')
 *   [seq]        same seq (for reassembly)
 *   [tnc2...]    continuation bytes (up to 21 bytes)
 */

#ifndef GEOGRAM_BLE_APRS_H
#define GEOGRAM_BLE_APRS_H

#include <stdbool.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

#define BLE_APRS_MAX_TNC2_LEN 48

/** Callback when a BlueAPRS frame is received via BLE scan. */
typedef void (*ble_aprs_rx_cb_t)(const char *tnc2, int rssi, void *ctx);

/**
 * @brief Initialize BlueAPRS (NimBLE observer+broadcaster, no GATT).
 * @param rx_cb  Callback for received frames (NULL to disable RX).
 * @param rx_ctx Opaque context passed to rx_cb.
 * @return ESP_OK on success.
 */
esp_err_t ble_aprs_init(ble_aprs_rx_cb_t rx_cb, void *rx_ctx);

/**
 * @brief Advertise a TNC2 frame as BLE manufacturer data.
 * Stops scanning, advertises for duration_ms, then resumes scanning.
 * @param tnc2        Null-terminated TNC2 string (max BLE_APRS_MAX_TNC2_LEN).
 * @param duration_ms How long to advertise (ms). 0 = single burst (~100ms).
 * @return ESP_OK on success.
 */
esp_err_t ble_aprs_advertise(const char *tnc2, uint32_t duration_ms);

/** Start passive+active scanning for BlueAPRS advertisements. */
esp_err_t ble_aprs_scan_start(void);

/** Stop scanning. */
void ble_aprs_scan_stop(void);

/** Returns true if BlueAPRS has been initialized successfully. */
bool ble_aprs_is_active(void);

#ifdef __cplusplus
}
#endif

#endif // GEOGRAM_BLE_APRS_H
