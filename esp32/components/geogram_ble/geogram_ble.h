#ifndef GEOGRAM_BLE_H
#define GEOGRAM_BLE_H

#include <stdbool.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Initialize the Geogram BLE service.
 *
 * Initializes NimBLE host/controller and registers the Geogram GATT service.
 */
esp_err_t geogram_ble_init(void);

/**
 * @brief Start BLE advertising for the Geogram service.
 */
esp_err_t geogram_ble_start(void);

/**
 * @brief Stop BLE advertising and shutdown BLE host.
 */
esp_err_t geogram_ble_stop(void);

/**
 * @brief Check whether BLE service is running.
 */
bool geogram_ble_is_running(void);

#ifdef __cplusplus
}
#endif

#endif // GEOGRAM_BLE_H
