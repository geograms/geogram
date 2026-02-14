/**
 * @file console.h
 * @brief Serial console API for Geogram ESP32
 *
 * Provides a command-line interface over UART for device control,
 * configuration, and debugging.
 */

#ifndef GEOGRAM_CONSOLE_H
#define GEOGRAM_CONSOLE_H

#include <stdbool.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Console output format
 */
typedef enum {
    CONSOLE_OUTPUT_TEXT,    // Human-readable text
    CONSOLE_OUTPUT_JSON     // Machine-parseable JSON
} console_output_mode_t;

/**
 * @brief Initialize and start the serial console
 *
 * Initializes UART, registers all commands, and starts the console task.
 * Should be called after board initialization but can be before WiFi.
 *
 * @return ESP_OK on success
 */
esp_err_t console_init(void);

/**
 * @brief Stop the serial console
 *
 * Stops the console task and releases resources.
 *
 * @return ESP_OK on success
 */
esp_err_t console_deinit(void);

/**
 * @brief Check if console is running
 *
 * @return true if console task is active
 */
bool console_is_running(void);

/**
 * @brief Set output format mode
 *
 * @param mode Output format (text or JSON)
 */
void console_set_output_mode(console_output_mode_t mode);

/**
 * @brief Get current output format mode
 *
 * @return Current output mode
 */
console_output_mode_t console_get_output_mode(void);

/**
 * @brief Print a formatted response respecting output mode
 *
 * In text mode, prints directly. In JSON mode, wraps in JSON object.
 *
 * @param key Key for JSON mode (ignored in text mode)
 * @param fmt Printf format string
 * @param ... Format arguments
 */
void console_printf(const char *key, const char *fmt, ...);

// Command registration functions (called by console.c)
void register_system_commands(void);
void register_wifi_commands(void);
void register_display_commands(void);
void register_config_commands(void);
void register_ssh_commands(void);
void register_ftp_commands(void);
void register_radio_commands(void);
#ifdef CONFIG_GEOGRAM_MESH_ENABLED
void register_mesh_commands(void);
#endif

#ifdef __cplusplus
}
#endif

#endif // GEOGRAM_CONSOLE_H
