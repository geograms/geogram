#ifndef GEOGRAM_MODEL_TDONGLE_S3_INIT_H
#define GEOGRAM_MODEL_TDONGLE_S3_INIT_H

#include "esp_err.h"
#include "st7735.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Initialize T-Dongle-S3 board hardware (NVS + ST7735 LCD)
 */
esp_err_t model_init(void);

/**
 * @brief Deinitialize T-Dongle-S3 board hardware
 */
void model_deinit(void);

/**
 * @brief Get the LCD display handle (available after model_init)
 */
st7735_handle_t model_get_lcd(void);

#ifdef __cplusplus
}
#endif

#endif // GEOGRAM_MODEL_TDONGLE_S3_INIT_H
