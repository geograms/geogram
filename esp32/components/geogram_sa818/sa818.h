#ifndef SA818_H
#define SA818_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct sa818_dev *sa818_handle_t;

/**
 * @brief SA818 wiring and UART configuration.
 */
typedef struct {
    int uart_port;
    int tx_pin;
    int rx_pin;
    int ptt_pin;      // Active low: LOW=TX, HIGH=RX
    int pd_pin;       // Power-down pin: HIGH=ON, LOW=OFF
    int hl_pin;       // Optional high/low power pin, -1 when unused
    int baud_rate;    // Defaults to 9600 when 0
} sa818_config_t;

/**
 * @brief Create and initialize an SA818 device instance.
 */
esp_err_t sa818_create(const sa818_config_t *config, sa818_handle_t *handle);

/**
 * @brief Delete an SA818 device instance.
 */
esp_err_t sa818_delete(sa818_handle_t handle);

/**
 * @brief Toggle SA818 module power.
 */
esp_err_t sa818_power(sa818_handle_t handle, bool enabled);

/**
 * @brief Set module TX/RX state through PTT.
 */
esp_err_t sa818_set_tx(sa818_handle_t handle, bool tx_enabled);

/**
 * @brief Set module high/low power mode.
 *
 * Many SA818 boards use active-low HL pin:
 * LOW = high power, HIGH = low power.
 */
esp_err_t sa818_set_high_power(sa818_handle_t handle, bool high_power);

/**
 * @brief Send a raw command and optionally assert an expected token in response.
 */
esp_err_t sa818_command(sa818_handle_t handle,
                        const char *command,
                        const char *expected_token,
                        char *response,
                        size_t response_len,
                        uint32_t timeout_ms);

/**
 * @brief Perform module handshake (`AT+DMOCONNECT`).
 */
esp_err_t sa818_handshake(sa818_handle_t handle, uint32_t timeout_ms);

/**
 * @brief Set SA818 speaker volume (0-8).
 */
esp_err_t sa818_set_volume(sa818_handle_t handle, uint8_t volume, uint32_t timeout_ms);

/**
 * @brief Configure SA818 RX filters.
 */
esp_err_t sa818_set_filters(sa818_handle_t handle,
                            bool pre_emphasis,
                            bool high_pass,
                            bool low_pass,
                            uint32_t timeout_ms);

/**
 * @brief Configure SA818 tail elimination.
 */
esp_err_t sa818_set_tail(sa818_handle_t handle, uint8_t tail, uint32_t timeout_ms);

/**
 * @brief Configure SA818 channel group parameters.
 *
 * @param bandwidth 0=narrow, 1=wide
 * @param tx_freq_mhz Transmit frequency in MHz
 * @param rx_freq_mhz Receive frequency in MHz
 * @param tx_ctcss TX CTCSS code (e.g. "0000"), defaults to "0000" when NULL
 * @param squelch 0-8
 * @param rx_ctcss RX CTCSS code (e.g. "0000"), defaults to "0000" when NULL
 */
esp_err_t sa818_set_group(sa818_handle_t handle,
                          uint8_t bandwidth,
                          float tx_freq_mhz,
                          float rx_freq_mhz,
                          const char *tx_ctcss,
                          uint8_t squelch,
                          const char *rx_ctcss,
                          uint32_t timeout_ms);

/**
 * @brief Read module RSSI through `RSSI?`.
 */
esp_err_t sa818_read_rssi(sa818_handle_t handle, int *rssi, uint32_t timeout_ms);

#ifdef __cplusplus
}
#endif

#endif // SA818_H
