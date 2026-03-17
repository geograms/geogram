/**
 * @file ble_client.h
 * @brief BLE central (client) for connecting to Geogram BLE peripherals
 *
 * Scans for Geogram BLE service, connects, performs Geoblue HELLO handshake,
 * and can send/receive APRS messages on the _aprs channel.
 */

#ifndef GEOGRAM_BLE_CLIENT_H
#define GEOGRAM_BLE_CLIENT_H

#include "esp_err.h"
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Initialize BLE client and start scanning for Geogram peripherals.
 * On connection, performs HELLO handshake automatically.
 */
esp_err_t ble_client_init(void);

/**
 * @brief Send an APRS message to the connected peripheral via _aprs channel.
 * @param to   Destination callsign
 * @param text Message text
 * @return ESP_OK if queued, ESP_ERR_INVALID_STATE if not connected
 */
esp_err_t ble_client_send_aprs(const char *to, const char *text);

/**
 * @brief Check if connected to a Geogram peripheral.
 */
bool ble_client_is_connected(void);

#ifdef __cplusplus
}
#endif

#endif // GEOGRAM_BLE_CLIENT_H
