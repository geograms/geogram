/**
 * @file model_init.c
 * @brief LILYGO T-Dongle-S3 board initialization (NVS + ST7735 LCD)
 */

#include "model_init.h"
#include "model_config.h"
#include "esp_log.h"
#include "nvs_flash.h"

static const char *TAG = "model_tdongle_s3";

static st7735_handle_t s_lcd = NULL;

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

    // Initialize ST7735 LCD
    st7735_config_t lcd_cfg = {
        .mosi_pin = TDONGLE_LCD_MOSI_PIN,
        .sclk_pin = TDONGLE_LCD_SCLK_PIN,
        .cs_pin   = TDONGLE_LCD_CS_PIN,
        .dc_pin   = TDONGLE_LCD_DC_PIN,
        .rst_pin  = TDONGLE_LCD_RST_PIN,
        .bl_pin   = TDONGLE_LCD_BL_PIN,
    };
    ret = st7735_init(&lcd_cfg, &s_lcd);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "ST7735 LCD init failed: %s", esp_err_to_name(ret));
        // Non-fatal — board can still run without display
    } else {
        ESP_LOGI(TAG, "ST7735 LCD ready");
    }

    ESP_LOGI(TAG, "T-Dongle-S3 initialized");
    return ESP_OK;
}

void model_deinit(void)
{
    if (s_lcd) {
        st7735_deinit(s_lcd);
        s_lcd = NULL;
    }
    ESP_LOGI(TAG, "T-Dongle-S3 deinitialized");
}

st7735_handle_t model_get_lcd(void)
{
    return s_lcd;
}
