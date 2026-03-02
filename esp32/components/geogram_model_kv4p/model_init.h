#ifndef MODEL_INIT_H
#define MODEL_INIT_H

#include "esp_err.h"
#include "sa818.h"
#include "sa818_radio.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Initialize KV4P board hardware.
 */
esp_err_t model_init(void);

/**
 * @brief Deinitialize KV4P board hardware.
 */
esp_err_t model_deinit(void);

/**
 * @brief Get SA818 radio handle created by model_init().
 */
sa818_handle_t model_get_sa818(void);

/**
 * @brief Get high-level SA818 radio module handle created by model_init().
 */
sa818_radio_handle_t model_get_sa818_radio(void);

/**
 * @brief Get the error code from the last SA818 radio init attempt.
 */
esp_err_t model_get_radio_init_error(void);

/**
 * @brief Retry SA818 radio initialization (if previous attempt failed).
 */
esp_err_t model_retry_radio_init(void);

#ifdef __cplusplus
}
#endif

#endif // MODEL_INIT_H
