#ifndef GEOGRAM_TDONGLE_UI_H
#define GEOGRAM_TDONGLE_UI_H

#include "esp_err.h"
#include "st7735.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Initialise the T-Dongle-S3 LVGL display UI.
 *
 * Sets up LVGL with the ST7735 driver and creates the three-zone layout:
 *   - Orange top bar   (uptime)
 *   - Black chat area  (last N messages, auto-scrolling)
 *   - Grey bottom bar  (device count + IP)
 *
 * @param lcd  Initialised ST7735 handle
 * @return ESP_OK on success
 */
esp_err_t tdongle_ui_init(st7735_handle_t lcd);

/**
 * @brief Call from the main loop — pumps LVGL and updates uptime/messages.
 *
 * Mirrors the old Arduino updateDisplay() pattern: lv_timer_handler()
 * first, then apply deferred label changes.
 */
void tdongle_ui_update(void);

/**
 * @brief Push a chat message onto the display.
 */
void tdongle_ui_push_message(const char *from, const char *text);

/**
 * @brief Update the device-count shown in the bottom-right corner.
 */
void tdongle_ui_set_device_count(int count);

/**
 * @brief Update the IP address shown in the bottom-left corner.
 */
void tdongle_ui_set_ip(const char *ip);

#ifdef __cplusplus
}
#endif

#endif /* GEOGRAM_TDONGLE_UI_H */
