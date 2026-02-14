#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "sa818.h"
#include "driver/gpio.h"
#include "driver/uart.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "sa818";

#define SA818_DEFAULT_BAUD_RATE        9600
#define SA818_UART_RX_BUFFER_SIZE      256
#define SA818_RESPONSE_BUFFER_SIZE     256
#define SA818_DEFAULT_TIMEOUT_MS       1500

struct sa818_dev {
    sa818_config_t cfg;
    bool owns_uart_driver;
    bool powered;
};

static esp_err_t sa818_configure_output_pin(int pin, int initial_level)
{
    if (pin < 0) {
        return ESP_OK;
    }

    gpio_config_t gpio_cfg = {
        .pin_bit_mask = (1ULL << pin),
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    esp_err_t ret = gpio_config(&gpio_cfg);
    if (ret != ESP_OK) {
        return ret;
    }

    return gpio_set_level((gpio_num_t)pin, initial_level);
}

static esp_err_t sa818_write_command(sa818_handle_t handle, const char *command)
{
    if (!handle || !command) {
        return ESP_ERR_INVALID_ARG;
    }

    size_t command_len = strlen(command);
    bool has_line_ending = strchr(command, '\n') != NULL || strchr(command, '\r') != NULL;
    char command_buf[96];

    if (has_line_ending) {
        if (command_len >= sizeof(command_buf)) {
            return ESP_ERR_INVALID_SIZE;
        }
        snprintf(command_buf, sizeof(command_buf), "%s", command);
    } else {
        int written_len = snprintf(command_buf, sizeof(command_buf), "%s\r\n", command);
        if (written_len <= 0 || written_len >= (int)sizeof(command_buf)) {
            return ESP_ERR_INVALID_SIZE;
        }
    }

    uart_flush_input(handle->cfg.uart_port);

    int bytes_written = uart_write_bytes(handle->cfg.uart_port, command_buf, strlen(command_buf));
    if (bytes_written < 0) {
        return ESP_FAIL;
    }

    uart_wait_tx_done(handle->cfg.uart_port, pdMS_TO_TICKS(100));
    return ESP_OK;
}

static esp_err_t sa818_read_response(sa818_handle_t handle,
                                     char *response,
                                     size_t response_len,
                                     uint32_t timeout_ms)
{
    if (!handle || !response || response_len == 0) {
        return ESP_ERR_INVALID_ARG;
    }

    response[0] = '\0';
    size_t offset = 0;
    int64_t deadline_us = esp_timer_get_time() + ((int64_t)timeout_ms * 1000);

    while (esp_timer_get_time() < deadline_us && offset < (response_len - 1)) {
        int64_t now_us = esp_timer_get_time();
        int64_t remaining_us = deadline_us - now_us;
        if (remaining_us <= 0) {
            break;
        }

        uint32_t wait_ms = (uint32_t)(remaining_us / 1000);
        if (wait_ms == 0) {
            wait_ms = 1;
        } else if (wait_ms > 100) {
            wait_ms = 100;
        }

        int read_len = uart_read_bytes(
            handle->cfg.uart_port,
            (uint8_t *)&response[offset],
            response_len - 1 - offset,
            pdMS_TO_TICKS(wait_ms));

        if (read_len > 0) {
            offset += read_len;
            response[offset] = '\0';

            if (strstr(response, "\r\n") != NULL ||
                strstr(response, "\n") != NULL ||
                strstr(response, "ERROR") != NULL ||
                strstr(response, ":0") != NULL) {
                break;
            }
        }
    }

    if (offset == 0) {
        return ESP_ERR_TIMEOUT;
    }

    return ESP_OK;
}

esp_err_t sa818_create(const sa818_config_t *config, sa818_handle_t *handle)
{
    if (!config || !handle) {
        return ESP_ERR_INVALID_ARG;
    }

    if (config->ptt_pin < 0 || config->pd_pin < 0 || config->tx_pin < 0 || config->rx_pin < 0) {
        return ESP_ERR_INVALID_ARG;
    }

    struct sa818_dev *dev = calloc(1, sizeof(struct sa818_dev));
    if (!dev) {
        return ESP_ERR_NO_MEM;
    }

    dev->cfg = *config;
    if (dev->cfg.baud_rate <= 0) {
        dev->cfg.baud_rate = SA818_DEFAULT_BAUD_RATE;
    }

    esp_err_t ret = ESP_OK;
    if (!uart_is_driver_installed(dev->cfg.uart_port)) {
        ret = uart_driver_install(dev->cfg.uart_port, SA818_UART_RX_BUFFER_SIZE, 0, 0, NULL, 0);
        if (ret != ESP_OK) {
            free(dev);
            return ret;
        }
        dev->owns_uart_driver = true;
    }

    uart_config_t uart_cfg = {
        .baud_rate = dev->cfg.baud_rate,
        .data_bits = UART_DATA_8_BITS,
        .parity = UART_PARITY_DISABLE,
        .stop_bits = UART_STOP_BITS_1,
        .flow_ctrl = UART_HW_FLOWCTRL_DISABLE,
        .source_clk = UART_SCLK_DEFAULT,
    };

    ret = uart_param_config(dev->cfg.uart_port, &uart_cfg);
    if (ret != ESP_OK) {
        if (dev->owns_uart_driver) {
            uart_driver_delete(dev->cfg.uart_port);
        }
        free(dev);
        return ret;
    }

    ret = uart_set_pin(dev->cfg.uart_port, dev->cfg.tx_pin, dev->cfg.rx_pin,
                       UART_PIN_NO_CHANGE, UART_PIN_NO_CHANGE);
    if (ret != ESP_OK) {
        if (dev->owns_uart_driver) {
            uart_driver_delete(dev->cfg.uart_port);
        }
        free(dev);
        return ret;
    }

    ret = sa818_configure_output_pin(dev->cfg.ptt_pin, 1);
    if (ret != ESP_OK) {
        if (dev->owns_uart_driver) {
            uart_driver_delete(dev->cfg.uart_port);
        }
        free(dev);
        return ret;
    }

    ret = sa818_configure_output_pin(dev->cfg.pd_pin, 0);
    if (ret != ESP_OK) {
        if (dev->owns_uart_driver) {
            uart_driver_delete(dev->cfg.uart_port);
        }
        free(dev);
        return ret;
    }

    ret = sa818_configure_output_pin(dev->cfg.hl_pin, 1);
    if (ret != ESP_OK) {
        if (dev->owns_uart_driver) {
            uart_driver_delete(dev->cfg.uart_port);
        }
        free(dev);
        return ret;
    }

    ESP_LOGI(TAG, "SA818 initialized (UART%d TX=%d RX=%d PTT=%d PD=%d HL=%d)",
             dev->cfg.uart_port, dev->cfg.tx_pin, dev->cfg.rx_pin,
             dev->cfg.ptt_pin, dev->cfg.pd_pin, dev->cfg.hl_pin);

    *handle = dev;
    return ESP_OK;
}

esp_err_t sa818_delete(sa818_handle_t handle)
{
    if (!handle) {
        return ESP_ERR_INVALID_ARG;
    }

    sa818_power(handle, false);

    if (handle->owns_uart_driver) {
        uart_driver_delete(handle->cfg.uart_port);
    }

    free(handle);
    return ESP_OK;
}

esp_err_t sa818_power(sa818_handle_t handle, bool enabled)
{
    if (!handle) {
        return ESP_ERR_INVALID_ARG;
    }

    esp_err_t ret = gpio_set_level((gpio_num_t)handle->cfg.pd_pin, enabled ? 1 : 0);
    if (ret != ESP_OK) {
        return ret;
    }

    handle->powered = enabled;

    if (enabled) {
        vTaskDelay(pdMS_TO_TICKS(120));
    } else {
        vTaskDelay(pdMS_TO_TICKS(20));
    }

    return ESP_OK;
}

esp_err_t sa818_set_tx(sa818_handle_t handle, bool tx_enabled)
{
    if (!handle) {
        return ESP_ERR_INVALID_ARG;
    }

    return gpio_set_level((gpio_num_t)handle->cfg.ptt_pin, tx_enabled ? 0 : 1);
}

esp_err_t sa818_set_high_power(sa818_handle_t handle, bool high_power)
{
    if (!handle) {
        return ESP_ERR_INVALID_ARG;
    }

    if (handle->cfg.hl_pin < 0) {
        return ESP_OK;
    }

    return gpio_set_level((gpio_num_t)handle->cfg.hl_pin, high_power ? 0 : 1);
}

esp_err_t sa818_command(sa818_handle_t handle,
                        const char *command,
                        const char *expected_token,
                        char *response,
                        size_t response_len,
                        uint32_t timeout_ms)
{
    if (!handle || !command) {
        return ESP_ERR_INVALID_ARG;
    }

    char fallback_response[SA818_RESPONSE_BUFFER_SIZE];
    if (!response) {
        response = fallback_response;
        response_len = sizeof(fallback_response);
    }
    if (response_len == 0) {
        return ESP_ERR_INVALID_ARG;
    }

    if (timeout_ms == 0) {
        timeout_ms = SA818_DEFAULT_TIMEOUT_MS;
    }

    esp_err_t ret = sa818_write_command(handle, command);
    if (ret != ESP_OK) {
        return ret;
    }

    ret = sa818_read_response(handle, response, response_len, timeout_ms);
    if (ret != ESP_OK) {
        return ret;
    }

    if (strstr(response, "ERROR") != NULL) {
        ESP_LOGW(TAG, "SA818 command failed: %s -> %s", command, response);
        return ESP_FAIL;
    }

    if (expected_token && strstr(response, expected_token) == NULL) {
        ESP_LOGW(TAG, "SA818 unexpected response: %s -> %s", command, response);
        return ESP_ERR_INVALID_RESPONSE;
    }

    return ESP_OK;
}

esp_err_t sa818_handshake(sa818_handle_t handle, uint32_t timeout_ms)
{
    char response[SA818_RESPONSE_BUFFER_SIZE];
    esp_err_t ret = sa818_command(handle, "AT+DMOCONNECT", NULL, response, sizeof(response), timeout_ms);
    if (ret != ESP_OK) {
        return ret;
    }

    if (strstr(response, "DMOCONNECT:0") != NULL || strstr(response, "OK") != NULL) {
        return ESP_OK;
    }

    return ESP_ERR_INVALID_RESPONSE;
}

esp_err_t sa818_set_volume(sa818_handle_t handle, uint8_t volume, uint32_t timeout_ms)
{
    if (!handle) {
        return ESP_ERR_INVALID_ARG;
    }

    if (volume > 8) {
        volume = 8;
    }

    char command[32];
    snprintf(command, sizeof(command), "AT+DMOSETVOLUME=%u", volume);
    return sa818_command(handle, command, ":0", NULL, 0, timeout_ms);
}

esp_err_t sa818_set_filters(sa818_handle_t handle,
                            bool pre_emphasis,
                            bool high_pass,
                            bool low_pass,
                            uint32_t timeout_ms)
{
    if (!handle) {
        return ESP_ERR_INVALID_ARG;
    }

    char command[48];
    snprintf(command, sizeof(command), "AT+SETFILTER=%d,%d,%d",
             pre_emphasis ? 1 : 0,
             high_pass ? 1 : 0,
             low_pass ? 1 : 0);
    return sa818_command(handle, command, ":0", NULL, 0, timeout_ms);
}

esp_err_t sa818_set_tail(sa818_handle_t handle, uint8_t tail, uint32_t timeout_ms)
{
    if (!handle) {
        return ESP_ERR_INVALID_ARG;
    }

    char command[24];
    snprintf(command, sizeof(command), "AT+SETTAIL=%u", tail);
    return sa818_command(handle, command, ":0", NULL, 0, timeout_ms);
}

esp_err_t sa818_set_group(sa818_handle_t handle,
                          uint8_t bandwidth,
                          float tx_freq_mhz,
                          float rx_freq_mhz,
                          const char *tx_ctcss,
                          uint8_t squelch,
                          const char *rx_ctcss,
                          uint32_t timeout_ms)
{
    if (!handle) {
        return ESP_ERR_INVALID_ARG;
    }

    if (squelch > 8) {
        squelch = 8;
    }

    if (!tx_ctcss) {
        tx_ctcss = "0000";
    }
    if (!rx_ctcss) {
        rx_ctcss = "0000";
    }

    char command[96];
    snprintf(command, sizeof(command), "AT+DMOSETGROUP=%u,%.4f,%.4f,%s,%u,%s",
             bandwidth ? 1 : 0, tx_freq_mhz, rx_freq_mhz, tx_ctcss, squelch, rx_ctcss);

    return sa818_command(handle, command, ":0", NULL, 0, timeout_ms);
}

esp_err_t sa818_read_rssi(sa818_handle_t handle, int *rssi, uint32_t timeout_ms)
{
    if (!handle || !rssi) {
        return ESP_ERR_INVALID_ARG;
    }

    char response[64];
    esp_err_t ret = sa818_command(handle, "RSSI?", NULL, response, sizeof(response), timeout_ms);
    if (ret != ESP_OK) {
        return ret;
    }

    char *cursor = response;
    while (*cursor != '\0' && !isdigit((unsigned char)*cursor) && *cursor != '-') {
        cursor++;
    }

    if (*cursor == '\0') {
        return ESP_ERR_INVALID_RESPONSE;
    }

    *rssi = (int)strtol(cursor, NULL, 10);
    return ESP_OK;
}
