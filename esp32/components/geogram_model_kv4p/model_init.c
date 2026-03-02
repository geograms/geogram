#include <stdio.h>
#include "model_init.h"
#include "model_config.h"
#include "esp_log.h"
#include "nvs_flash.h"
#include "aprs_store.h"

static const char *TAG = "model_init";
static sa818_handle_t s_sa818 = NULL;
static sa818_radio_handle_t s_sa818_radio = NULL;
static esp_err_t s_radio_init_err = ESP_ERR_NOT_FINISHED;

sa818_handle_t model_get_sa818(void)
{
    return s_sa818;
}

sa818_radio_handle_t model_get_sa818_radio(void)
{
    return s_sa818_radio;
}

esp_err_t model_get_radio_init_error(void)
{
    return s_radio_init_err;
}

#if HAS_SA818
static bool s_aprs_store_ready = false;

static esp_err_t init_sa818_radio(void)
{
    if (s_sa818_radio != NULL) {
        return ESP_OK;  // already initialized
    }

    sa818_radio_config_t radio_cfg = {
        .sa818 = {
            .uart_port = SA818_UART_PORT,
            .tx_pin = SA818_PIN_RF_TXD,
            .rx_pin = SA818_PIN_RF_RXD,
            .ptt_pin = SA818_PIN_PTT,
            .pd_pin = SA818_PIN_PD,
            .hl_pin = SA818_PIN_HL,
            .baud_rate = SA818_UART_BAUD_RATE,
        },
        .squelch_pin = SA818_PIN_SQ,
        .audio_in_pin = SA818_PIN_AUDIO_IN,
        .audio_out_pin = SA818_PIN_AUDIO_OUT,
        .bandwidth = SA818_BANDWIDTH_DEFAULT,
        .squelch = SA818_SQUELCH_DEFAULT,
        .volume = SA818_VOLUME_DEFAULT,
        .high_power = true,
        .tx_freq_mhz = SA818_APRS_FREQ_DEFAULT_MHZ,
        .rx_freq_mhz = SA818_APRS_FREQ_DEFAULT_MHZ,
        .aprs_freq_mhz = SA818_APRS_FREQ_DEFAULT_MHZ,
        .audio_sample_rate_hz = 9600,
    };

    esp_err_t ret = sa818_radio_create(&radio_cfg, &s_sa818_radio);
    s_radio_init_err = ret;
    if (ret != ESP_OK) {
        ESP_LOGW(TAG, "SA818 radio init failed: %s", esp_err_to_name(ret));
        return ret;
    }

    s_sa818 = sa818_radio_get_modem(s_sa818_radio);
    ESP_LOGI(TAG, "SA818 radio module ready (APRS freq %.3f MHz)",
             (double)sa818_radio_get_aprs_frequency(s_sa818_radio));

    // Connect RX demodulator if APRS store is ready
    if (s_aprs_store_ready) {
        sa818_radio_set_aprs_rx_callback(s_sa818_radio, aprs_store_rx_callback, NULL);
        sa818_radio_start_audio_rx(s_sa818_radio, NULL, NULL);
        ESP_LOGI(TAG, "APRS RX enabled — demodulator active");
    }

    return ESP_OK;
}
#endif

esp_err_t model_retry_radio_init(void)
{
#if HAS_SA818
    if (s_sa818_radio != NULL) {
        return ESP_OK;  // already working
    }
    ESP_LOGI(TAG, "Retrying SA818 radio initialization...");
    return init_sa818_radio();
#else
    return ESP_ERR_NOT_SUPPORTED;
#endif
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
    // Always initialize APRS store (web API needs it even without radio)
    ret = aprs_store_init();
    if (ret != ESP_OK) {
        ESP_LOGW(TAG, "APRS store init failed: %s", esp_err_to_name(ret));
    } else {
        s_aprs_store_ready = true;
    }

    // Initialize SA818 radio (may fail transiently — retry via /api/radio/retry)
    init_sa818_radio();
#endif

    ESP_LOGI(TAG, "Board initialization complete");
    return ESP_OK;
}

esp_err_t model_deinit(void)
{
    if (s_sa818_radio != NULL) {
        sa818_radio_delete(s_sa818_radio);
        s_sa818_radio = NULL;
        s_sa818 = NULL;
    }

    ESP_LOGI(TAG, "Board deinitialization complete");
    return ESP_OK;
}
