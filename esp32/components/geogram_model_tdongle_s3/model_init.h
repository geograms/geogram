#ifndef GEOGRAM_MODEL_TDONGLE_S3_INIT_H
#define GEOGRAM_MODEL_TDONGLE_S3_INIT_H

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Initialize T-Dongle-S3 board hardware
 */
esp_err_t model_init(void);

/**
 * @brief Deinitialize T-Dongle-S3 board hardware
 */
void model_deinit(void);

#ifdef __cplusplus
}
#endif

#endif // GEOGRAM_MODEL_TDONGLE_S3_INIT_H
