#ifndef GEOGRAM_ST7735_H
#define GEOGRAM_ST7735_H

#include <stdint.h>
#include <stdbool.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/* T-Dongle-S3 ST7735 display: 160x80 pixels, RGB565 */
#define ST7735_WIDTH   160
#define ST7735_HEIGHT  80

/**
 * @brief ST7735 SPI pin configuration
 */
typedef struct {
    int mosi_pin;   // SDA / MOSI
    int sclk_pin;   // SCL / SCLK
    int cs_pin;     // Chip select
    int dc_pin;     // Data/Command
    int rst_pin;    // Reset (-1 if not used)
    int bl_pin;     // Backlight (-1 if not used)
} st7735_config_t;

/**
 * @brief Opaque display handle
 */
typedef struct st7735_dev *st7735_handle_t;

/**
 * @brief Create and initialize the ST7735 display
 */
esp_err_t st7735_init(const st7735_config_t *config, st7735_handle_t *out_handle);

/**
 * @brief Delete the display instance and free resources
 */
esp_err_t st7735_deinit(st7735_handle_t handle);

/**
 * @brief Fill a rectangular region with pixel data (RGB565, big-endian)
 */
esp_err_t st7735_flush(st7735_handle_t handle,
                       uint16_t x1, uint16_t y1,
                       uint16_t x2, uint16_t y2,
                       const uint16_t *data);

/**
 * @brief Fill the entire screen with a single RGB565 colour
 */
esp_err_t st7735_fill_color(st7735_handle_t handle, uint16_t color);

/**
 * @brief Turn backlight on/off
 */
void st7735_backlight(st7735_handle_t handle, bool on);

#ifdef __cplusplus
}
#endif

#endif /* GEOGRAM_ST7735_H */
