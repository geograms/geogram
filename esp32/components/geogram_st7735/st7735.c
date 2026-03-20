/**
 * @file st7735.c
 * @brief ST7735S TFT LCD driver for ESP-IDF (SPI).
 *
 * Tailored for the LILYGO T-Dongle-S3 (160x80, BGR, GREENTAB offset).
 */

#include "st7735.h"
#include <string.h>
#include <stdlib.h>
#include "driver/spi_master.h"
#include "driver/gpio.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "st7735";

/* Column/row offsets for the 160x80 GREENTAB variant in landscape (rotation=1).
 * Portrait offsets are col=26, row=1; rotation=1 swaps them. */
#define COL_OFFSET  1
#define ROW_OFFSET  26

struct st7735_dev {
    spi_device_handle_t spi;
    int dc_pin;
    int rst_pin;
    int bl_pin;
};

/* ---- low-level helpers -------------------------------------------------- */

static void st7735_cmd(st7735_handle_t h, uint8_t cmd)
{
    gpio_set_level(h->dc_pin, 0);
    spi_transaction_t t = {
        .length = 8,
        .tx_buffer = &cmd,
    };
    spi_device_polling_transmit(h->spi, &t);
}

static void st7735_data(st7735_handle_t h, const uint8_t *data, size_t len)
{
    if (len == 0) return;
    gpio_set_level(h->dc_pin, 1);
    spi_transaction_t t = {
        .length = len * 8,
        .tx_buffer = data,
    };
    spi_device_polling_transmit(h->spi, &t);
}

static void st7735_data8(st7735_handle_t h, uint8_t val)
{
    st7735_data(h, &val, 1);
}

static void st7735_set_window(st7735_handle_t h,
                              uint16_t x1, uint16_t y1,
                              uint16_t x2, uint16_t y2)
{
    x1 += COL_OFFSET; x2 += COL_OFFSET;
    y1 += ROW_OFFSET; y2 += ROW_OFFSET;

    uint8_t col[4] = { x1 >> 8, x1 & 0xFF, x2 >> 8, x2 & 0xFF };
    uint8_t row[4] = { y1 >> 8, y1 & 0xFF, y2 >> 8, y2 & 0xFF };

    st7735_cmd(h, 0x2A);  /* CASET */
    st7735_data(h, col, 4);

    st7735_cmd(h, 0x2B);  /* RASET */
    st7735_data(h, row, 4);

    st7735_cmd(h, 0x2C);  /* RAMWR */
}

/* ---- init sequence ------------------------------------------------------ */

static void st7735_hw_reset(st7735_handle_t h)
{
    if (h->rst_pin < 0) return;
    gpio_set_level(h->rst_pin, 0);
    vTaskDelay(pdMS_TO_TICKS(20));
    gpio_set_level(h->rst_pin, 1);
    vTaskDelay(pdMS_TO_TICKS(120));
}

static void st7735_init_sequence(st7735_handle_t h)
{
    /* ---- Rcmd1: reset + power/frame config (matches TFT_eSPI exactly) ---- */
    st7735_cmd(h, 0x01);  /* SWRESET */
    vTaskDelay(pdMS_TO_TICKS(150));

    st7735_cmd(h, 0x11);  /* SLPOUT */
    vTaskDelay(pdMS_TO_TICKS(500));

    /* Frame rate control (normal/idle/partial) */
    st7735_cmd(h, 0xB1);
    st7735_data8(h, 0x01); st7735_data8(h, 0x2C); st7735_data8(h, 0x2D);

    st7735_cmd(h, 0xB2);
    st7735_data8(h, 0x01); st7735_data8(h, 0x2C); st7735_data8(h, 0x2D);

    st7735_cmd(h, 0xB3);
    st7735_data8(h, 0x01); st7735_data8(h, 0x2C); st7735_data8(h, 0x2D);
    st7735_data8(h, 0x01); st7735_data8(h, 0x2C); st7735_data8(h, 0x2D);

    /* Display inversion control */
    st7735_cmd(h, 0xB4);
    st7735_data8(h, 0x07);

    /* Power control */
    st7735_cmd(h, 0xC0);
    st7735_data8(h, 0xA2); st7735_data8(h, 0x02); st7735_data8(h, 0x84);

    st7735_cmd(h, 0xC1);
    st7735_data8(h, 0xC5);

    st7735_cmd(h, 0xC2);
    st7735_data8(h, 0x0A); st7735_data8(h, 0x00);

    st7735_cmd(h, 0xC3);
    st7735_data8(h, 0x8A); st7735_data8(h, 0x2A);

    st7735_cmd(h, 0xC4);
    st7735_data8(h, 0x8A); st7735_data8(h, 0xEE);

    /* VCOM */
    st7735_cmd(h, 0xC5);
    st7735_data8(h, 0x0E);

    /* Inversion OFF (Rcmd1 default — overridden below for GREENTAB) */
    st7735_cmd(h, 0x20);

    /* Initial MADCTL: portrait MX|MY|BGR = 0xC8 (matches TFT_eSPI Rcmd1) */
    st7735_cmd(h, 0x36);
    st7735_data8(h, 0xC8);

    /* 16-bit colour (RGB565) */
    st7735_cmd(h, 0x3A);
    st7735_data8(h, 0x05);

    /* ---- Rcmd2green: column/row window (green-tab) ---- */
    st7735_cmd(h, 0x2A);  /* CASET */
    { uint8_t d[] = {0x00, 0x02, 0x00, 0x81}; st7735_data(h, d, 4); }

    st7735_cmd(h, 0x2B);  /* RASET */
    { uint8_t d[] = {0x00, 0x01, 0x00, 0xA0}; st7735_data(h, d, 4); }

    /* ---- GREENTAB160x80 specific: enable inversion ---- */
    st7735_cmd(h, 0x21);  /* INVON */

    /* ---- Rcmd3: gamma + display on ---- */
    st7735_cmd(h, 0xE0);
    { uint8_t d[] = {0x02,0x1C,0x07,0x12,0x37,0x32,0x29,0x2D,
                     0x29,0x25,0x2B,0x39,0x00,0x01,0x03,0x10}; st7735_data(h, d, 16); }

    st7735_cmd(h, 0xE1);
    { uint8_t d[] = {0x03,0x1D,0x07,0x06,0x2E,0x2C,0x29,0x2D,
                     0x2E,0x2E,0x37,0x3F,0x00,0x00,0x02,0x10}; st7735_data(h, d, 16); }

    st7735_cmd(h, 0x13);  /* NORON */
    vTaskDelay(pdMS_TO_TICKS(10));

    st7735_cmd(h, 0x29);  /* DISPON */
    vTaskDelay(pdMS_TO_TICKS(100));

    /* ---- Apply rotation=1 (landscape): MADCTL + swapped offsets ---- */
    st7735_cmd(h, 0x36);
    st7735_data8(h, 0xA8);   /* MV=1 MY=1 BGR=1 — landscape for GREENTAB160x80 */
}

/* ---- public API --------------------------------------------------------- */

esp_err_t st7735_init(const st7735_config_t *config, st7735_handle_t *out_handle)
{
    if (!config || !out_handle) return ESP_ERR_INVALID_ARG;

    st7735_handle_t h = calloc(1, sizeof(struct st7735_dev));
    if (!h) return ESP_ERR_NO_MEM;

    h->dc_pin  = config->dc_pin;
    h->rst_pin = config->rst_pin;
    h->bl_pin  = config->bl_pin;

    /* Configure GPIO */
    gpio_config_t io = {
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    io.pin_bit_mask = (1ULL << config->dc_pin);
    if (config->rst_pin >= 0) io.pin_bit_mask |= (1ULL << config->rst_pin);
    if (config->bl_pin >= 0)  io.pin_bit_mask |= (1ULL << config->bl_pin);
    gpio_config(&io);

    /* SPI bus */
    spi_bus_config_t buscfg = {
        .mosi_io_num = config->mosi_pin,
        .miso_io_num = -1,
        .sclk_io_num = config->sclk_pin,
        .quadwp_io_num = -1,
        .quadhd_io_num = -1,
        .max_transfer_sz = ST7735_WIDTH * ST7735_HEIGHT * 2,
    };
    esp_err_t ret = spi_bus_initialize(SPI2_HOST, &buscfg, SPI_DMA_CH_AUTO);
    if (ret != ESP_OK && ret != ESP_ERR_INVALID_STATE) {
        /* ESP_ERR_INVALID_STATE = bus already initialised (shared) */
        ESP_LOGE(TAG, "SPI bus init failed: %s", esp_err_to_name(ret));
        free(h);
        return ret;
    }

    spi_device_interface_config_t devcfg = {
        .clock_speed_hz = 40 * 1000 * 1000,   /* 40 MHz */
        .mode = 0,
        .spics_io_num = config->cs_pin,
        .queue_size = 7,
    };
    ret = spi_bus_add_device(SPI2_HOST, &devcfg, &h->spi);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "SPI add device failed: %s", esp_err_to_name(ret));
        free(h);
        return ret;
    }

    st7735_hw_reset(h);
    st7735_init_sequence(h);

    /* Turn on backlight */
    if (h->bl_pin >= 0) gpio_set_level(h->bl_pin, 0);  /* active-low on T-Dongle */

    ESP_LOGI(TAG, "ST7735 initialised (%dx%d)", ST7735_WIDTH, ST7735_HEIGHT);
    *out_handle = h;
    return ESP_OK;
}

esp_err_t st7735_deinit(st7735_handle_t handle)
{
    if (!handle) return ESP_ERR_INVALID_ARG;
    if (handle->bl_pin >= 0) gpio_set_level(handle->bl_pin, 1);
    spi_bus_remove_device(handle->spi);
    free(handle);
    return ESP_OK;
}

esp_err_t st7735_flush(st7735_handle_t handle,
                       uint16_t x1, uint16_t y1,
                       uint16_t x2, uint16_t y2,
                       const uint16_t *data)
{
    if (!handle || !data) return ESP_ERR_INVALID_ARG;

    st7735_set_window(handle, x1, y1, x2, y2);

    size_t len = (x2 - x1 + 1) * (y2 - y1 + 1) * 2;   /* bytes */
    gpio_set_level(handle->dc_pin, 1);
    spi_transaction_t t = {
        .length = len * 8,
        .tx_buffer = data,
    };
    return spi_device_polling_transmit(handle->spi, &t);
}

esp_err_t st7735_fill_color(st7735_handle_t handle, uint16_t color)
{
    if (!handle) return ESP_ERR_INVALID_ARG;

    /* Swap bytes for big-endian SPI */
    uint16_t c = (color >> 8) | (color << 8);

    /* Allocate a single-line buffer */
    uint16_t *line = malloc(ST7735_WIDTH * 2);
    if (!line) return ESP_ERR_NO_MEM;

    for (int i = 0; i < ST7735_WIDTH; i++) line[i] = c;

    st7735_set_window(handle, 0, 0, ST7735_WIDTH - 1, ST7735_HEIGHT - 1);
    gpio_set_level(handle->dc_pin, 1);

    for (int y = 0; y < ST7735_HEIGHT; y++) {
        spi_transaction_t t = {
            .length = ST7735_WIDTH * 16,
            .tx_buffer = line,
        };
        spi_device_polling_transmit(handle->spi, &t);
    }

    free(line);
    return ESP_OK;
}

void st7735_backlight(st7735_handle_t handle, bool on)
{
    if (!handle || handle->bl_pin < 0) return;
    gpio_set_level(handle->bl_pin, on ? 0 : 1);   /* active-low */
}
