#include <stdio.h>
#include "model_init.h"
#include "model_config.h"
#include "esp_log.h"
#include "nvs_flash.h"

static const char *TAG = "model_init";
static sa818_handle_t s_sa818 = NULL;

sa818_handle_t model_get_sa818(void)
{
    return s_sa818;
}

esp_err_t model_init(void)
{
    ESP_LOGI(TAG, "Initializing %s (%s)", MODEL_NAME, MODEL_VARIANT);
    ESP_LOGI(TAG, "ESP32 LX6 @ 240MHz, 520KB SRAM, 4MB Flash");

    // Initialize NVS (required for WiFi and persistent settings)
    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_LOGW(TAG, "NVS partition was truncated, erasing...");
        ESP_ERROR_CHECK(nvs_flash_erase());
        ret = nvs_flash_init();
    }
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to initialize NVS: %s", esp_err_to_name(ret));
        return ret;
    }
    ESP_LOGI(TAG, "NVS initialized");

#if HAS_SA818
    sa818_config_t radio_cfg = {
        .uart_port = SA818_UART_PORT,
        .tx_pin = SA818_PIN_RF_TXD,
        .rx_pin = SA818_PIN_RF_RXD,
        .ptt_pin = SA818_PIN_PTT,
        .pd_pin = SA818_PIN_PD,
        .hl_pin = SA818_PIN_HL,
        .baud_rate = SA818_UART_BAUD_RATE,
    };

    ret = sa818_create(&radio_cfg, &s_sa818);
    if (ret != ESP_OK) {
        ESP_LOGW(TAG, "SA818 create failed: %s", esp_err_to_name(ret));
    } else {
        // Basic barebones bring-up for reuse in future KV4P workflows.
        sa818_set_tx(s_sa818, false);
        sa818_set_high_power(s_sa818, true);
        sa818_power(s_sa818, true);

        ret = sa818_handshake(s_sa818, 2500);
        if (ret != ESP_OK) {
            ESP_LOGW(TAG, "SA818 handshake failed: %s", esp_err_to_name(ret));
        } else {
            ESP_LOGI(TAG, "SA818 handshake OK");
            sa818_set_volume(s_sa818, SA818_VOLUME_DEFAULT, 1200);
            sa818_set_filters(s_sa818, false, false, false, 1200);
        }
    }
#endif

    ESP_LOGI(TAG, "Board initialization complete");
    return ESP_OK;
}

esp_err_t model_deinit(void)
{
    if (s_sa818 != NULL) {
        sa818_delete(s_sa818);
        s_sa818 = NULL;
    }

    ESP_LOGI(TAG, "Board deinitialization complete");
    return ESP_OK;
}
