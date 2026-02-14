/**
 * @file console.c
 * @brief Serial console core implementation
 */

#include <stdio.h>
#include <string.h>
#include <stdarg.h>
#include "console.h"
#include "esp_console.h"
#include "esp_vfs_dev.h"
#include "esp_log.h"
#include "driver/uart.h"
#include "linenoise/linenoise.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "console";

#define CONSOLE_UART_NUM    UART_NUM_0
#define CONSOLE_PROMPT      "geogram> "
#define MAX_CMDLINE_LENGTH  256
#define MAX_CMDLINE_ARGS    8
#define HISTORY_SIZE        8
#define CONSOLE_TASK_STACK  4096
#define CONSOLE_TASK_PRIO   2

static TaskHandle_t s_console_task = NULL;
static bool s_running = false;
static console_output_mode_t s_output_mode = CONSOLE_OUTPUT_TEXT;

console_output_mode_t console_get_output_mode(void)
{
    return s_output_mode;
}

void console_set_output_mode(console_output_mode_t mode)
{
    s_output_mode = mode;
    ESP_LOGI(TAG, "Output mode set to %s", mode == CONSOLE_OUTPUT_JSON ? "JSON" : "text");
}

void console_printf(const char *key, const char *fmt, ...)
{
    va_list args;
    va_start(args, fmt);

    if (s_output_mode == CONSOLE_OUTPUT_JSON && key != NULL) {
        printf("{\"%s\":\"", key);
        vprintf(fmt, args);
        printf("\"}\n");
    } else {
        vprintf(fmt, args);
    }

    va_end(args);
}

static void console_task(void *arg)
{
    char *line;

    ESP_LOGI(TAG, "Console task started");
    printf("\n");
    printf("Geogram Serial Console\n");
    printf("Type 'help' for available commands\n\n");

    while (s_running) {
        line = linenoise(CONSOLE_PROMPT);

        if (line == NULL) {
            // Timeout or error - just continue
            vTaskDelay(pdMS_TO_TICKS(10));
            continue;
        }

        if (strlen(line) > 0) {
            // Add to history
            linenoiseHistoryAdd(line);

            // Execute command
            int ret;
            esp_err_t err = esp_console_run(line, &ret);

            if (err == ESP_ERR_NOT_FOUND) {
                printf("Unknown command: %s\n", line);
                printf("Type 'help' for available commands\n");
            } else if (err == ESP_ERR_INVALID_ARG) {
                // Empty command - ignore
            } else if (err != ESP_OK) {
                printf("Error: %s\n", esp_err_to_name(err));
            }
        }

        linenoiseFree(line);
    }

    ESP_LOGI(TAG, "Console task stopped");
    vTaskDelete(NULL);
}

esp_err_t console_init(void)
{
    if (s_running) {
        ESP_LOGW(TAG, "Console already running");
        return ESP_OK;
    }

    ESP_LOGI(TAG, "Initializing serial console");

    // Disable buffering on stdin/stdout
    setvbuf(stdin, NULL, _IONBF, 0);
    setvbuf(stdout, NULL, _IONBF, 0);

    // Configure UART driver
    // Note: UART0 is typically already configured by ESP-IDF for logging
    // We just need to install the driver and set up VFS
    esp_err_t ret = uart_driver_install(CONSOLE_UART_NUM, 256, 0, 0, NULL, 0);
    if (ret == ESP_ERR_INVALID_STATE) {
        // Driver already installed - that's fine
        ESP_LOGI(TAG, "UART driver already installed");
    } else if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to install UART driver: %s", esp_err_to_name(ret));
        return ret;
    }

    // Tell VFS to use driver
    esp_vfs_dev_uart_use_driver(CONSOLE_UART_NUM);

    // Initialize esp_console
    esp_console_config_t console_config = {
        .max_cmdline_length = MAX_CMDLINE_LENGTH,
        .max_cmdline_args = MAX_CMDLINE_ARGS,
#if CONFIG_LOG_COLORS
        .hint_color = atoi(LOG_COLOR_CYAN),
        .hint_bold = 0,
#endif
    };
    ret = esp_console_init(&console_config);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to initialize console: %s", esp_err_to_name(ret));
        return ret;
    }

    // Probe terminal capabilities; pio device monitor often can't answer ANSI
    // cursor queries, so force dumb mode to keep the prompt usable.
    int probe_status = linenoiseProbe();
    if (probe_status != 0) {
        ESP_LOGW(TAG, "Terminal probe failed (%d), enabling dumb mode", probe_status);
        linenoiseSetDumbMode(1);
        linenoiseSetMultiLine(0);
    } else {
        linenoiseSetMultiLine(1);
    }

    // Configure linenoise history/input behavior
    linenoiseHistorySetMaxLen(HISTORY_SIZE);
    linenoiseAllowEmpty(false);

    // Register built-in help command
    esp_console_register_help_command();

    // Register our commands
    register_system_commands();
    register_wifi_commands();
    register_display_commands();
    register_config_commands();
    register_ssh_commands();
    register_ftp_commands();
#ifdef CONFIG_GEOGRAM_MESH_ENABLED
    register_mesh_commands();
#endif

    // Start console task
    s_running = true;
    BaseType_t task_ret = xTaskCreate(
        console_task,
        "console",
        CONSOLE_TASK_STACK,
        NULL,
        CONSOLE_TASK_PRIO,
        &s_console_task
    );

    if (task_ret != pdPASS) {
        ESP_LOGE(TAG, "Failed to create console task");
        s_running = false;
        esp_console_deinit();
        return ESP_FAIL;
    }

    ESP_LOGI(TAG, "Console initialized");
    return ESP_OK;
}

esp_err_t console_deinit(void)
{
    if (!s_running) {
        return ESP_OK;
    }

    s_running = false;

    // Wait for task to exit
    vTaskDelay(pdMS_TO_TICKS(100));

    if (s_console_task != NULL) {
        vTaskDelete(s_console_task);
        s_console_task = NULL;
    }

    esp_console_deinit();
    esp_vfs_dev_uart_use_nonblocking(CONSOLE_UART_NUM);
    uart_driver_delete(CONSOLE_UART_NUM);

    ESP_LOGI(TAG, "Console deinitialized");
    return ESP_OK;
}

bool console_is_running(void)
{
    return s_running;
}
