/**
 * @file model_init.c
 * @brief LILYGO T-Dongle-S3 board initialization (minimal)
 */

#include "model_init.h"
#include "esp_log.h"
#include "nvs_flash.h"

static const char *TAG = "model_tdongle_s3";

esp_err_t model_init(void)
{
    ESP_LOGI(TAG, "Initializing T-Dongle-S3");

    // Initialize NVS (required for WiFi and BLE)
    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ret = nvs_flash_init();
    }
    ESP_ERROR_CHECK(ret);

    ESP_LOGI(TAG, "T-Dongle-S3 initialized");
    return ESP_OK;
}

void model_deinit(void)
{
    ESP_LOGI(TAG, "T-Dongle-S3 deinitialized");
}
