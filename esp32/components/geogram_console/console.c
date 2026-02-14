/**
 * @file console.c
 * @brief Serial console core implementation
 */

#include <stdio.h>
#include <string.h>
#include <stdarg.h>
#include <stdlib.h>
#include "console.h"
#include "esp_console.h"
#include "esp_vfs_dev.h"
#include "esp_log.h"
#include "driver/uart.h"
#include "linenoise/linenoise.h"
#include "nvs.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "console";

#define CONSOLE_UART_NUM    UART_NUM_0
#define CONSOLE_PROMPT      "geogram> "
#define MAX_CMDLINE_LENGTH  256
#define MAX_CMDLINE_ARGS    8
#define HISTORY_SIZE        30
#define HISTORY_NVS_NS      "console"
#define HISTORY_NVS_KEY     "history_v1"
#define HISTORY_BLOB_MAX    (HISTORY_SIZE * MAX_CMDLINE_LENGTH)
#define CONSOLE_TASK_STACK  4096
#define CONSOLE_TASK_PRIO   2

static TaskHandle_t s_console_task = NULL;
static bool s_running = false;
static console_output_mode_t s_output_mode = CONSOLE_OUTPUT_TEXT;
static char s_history[HISTORY_SIZE][MAX_CMDLINE_LENGTH];
static char s_history_blob[HISTORY_BLOB_MAX];
static size_t s_history_count = 0;

static void history_append_local(const char *line, bool dedupe_last)
{
    if (!line || line[0] == '\0') {
        return;
    }

    if (dedupe_last && s_history_count > 0) {
        const char *last = s_history[s_history_count - 1];
        if (strcmp(last, line) == 0) {
            return;
        }
    }

    if (s_history_count >= HISTORY_SIZE) {
        memmove(s_history[0], s_history[1], (HISTORY_SIZE - 1) * sizeof(s_history[0]));
        s_history_count = HISTORY_SIZE - 1;
    }

    strlcpy(s_history[s_history_count], line, sizeof(s_history[s_history_count]));
    s_history_count++;
}

static esp_err_t history_save_nvs(void)
{
    size_t blob_len = 0;

    for (size_t i = 0; i < s_history_count; i++) {
        size_t line_len = strnlen(s_history[i], MAX_CMDLINE_LENGTH - 1);
        if (line_len == 0) {
            continue;
        }
        if (blob_len + line_len + 1 > sizeof(s_history_blob)) {
            break;
        }
        memcpy(&s_history_blob[blob_len], s_history[i], line_len);
        blob_len += line_len;
        s_history_blob[blob_len++] = '\n';
    }

    nvs_handle_t nvs = 0;
    esp_err_t ret = nvs_open(HISTORY_NVS_NS, NVS_READWRITE, &nvs);
    if (ret != ESP_OK) {
        return ret;
    }

    if (blob_len == 0) {
        ret = nvs_erase_key(nvs, HISTORY_NVS_KEY);
        if (ret == ESP_ERR_NVS_NOT_FOUND) {
            ret = ESP_OK;
        }
    } else {
        ret = nvs_set_blob(nvs, HISTORY_NVS_KEY, s_history_blob, blob_len);
    }

    if (ret == ESP_OK) {
        ret = nvs_commit(nvs);
    }

    nvs_close(nvs);
    return ret;
}

static void history_load_nvs(void)
{
    nvs_handle_t nvs = 0;
    esp_err_t ret = nvs_open(HISTORY_NVS_NS, NVS_READONLY, &nvs);
    if (ret != ESP_OK) {
        if (ret != ESP_ERR_NVS_NOT_FOUND) {
            ESP_LOGW(TAG, "Cannot open NVS for history: %s", esp_err_to_name(ret));
        }
        return;
    }

    size_t blob_len = 0;
    ret = nvs_get_blob(nvs, HISTORY_NVS_KEY, NULL, &blob_len);
    if (ret == ESP_ERR_NVS_NOT_FOUND) {
        nvs_close(nvs);
        return;
    }
    if (ret != ESP_OK) {
        ESP_LOGW(TAG, "Cannot read console history length: %s", esp_err_to_name(ret));
        nvs_close(nvs);
        return;
    }
    if (blob_len == 0 || blob_len > HISTORY_BLOB_MAX) {
        ESP_LOGW(TAG, "Skipping invalid history size: %u", (unsigned)blob_len);
        nvs_close(nvs);
        return;
    }

    char *blob = calloc(1, blob_len + 1);
    if (!blob) {
        ESP_LOGW(TAG, "Out of memory loading console history");
        nvs_close(nvs);
        return;
    }

    ret = nvs_get_blob(nvs, HISTORY_NVS_KEY, blob, &blob_len);
    nvs_close(nvs);
    if (ret != ESP_OK) {
        ESP_LOGW(TAG, "Cannot read console history: %s", esp_err_to_name(ret));
        free(blob);
        return;
    }

    char *saveptr = NULL;
    char *line = strtok_r(blob, "\n", &saveptr);
    while (line != NULL) {
        if (line[0] != '\0') {
            linenoiseHistoryAdd(line);
            history_append_local(line, false);
        }
        line = strtok_r(NULL, "\n", &saveptr);
    }

    if (s_history_count > 0) {
        ESP_LOGI(TAG, "Loaded %u console history entries", (unsigned)s_history_count);
    }
    free(blob);
}

static void history_add_and_persist(const char *line)
{
    linenoiseHistoryAdd(line);
    history_append_local(line, true);

    esp_err_t ret = history_save_nvs();
    if (ret != ESP_OK) {
        ESP_LOGW(TAG, "Failed to persist console history: %s", esp_err_to_name(ret));
    }
}

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
            history_add_and_persist(line);

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

    // Use plain serial console mode: avoids ANSI probe/control sequences that
    // render as garbled characters in some monitors.
    linenoiseSetDumbMode(1);
    linenoiseSetMultiLine(0);

    // Configure linenoise history/input behavior
    linenoiseHistorySetMaxLen(HISTORY_SIZE);
    linenoiseAllowEmpty(false);
    history_load_nvs();

    // Register built-in help command
    esp_console_register_help_command();

    // Register our commands
    register_system_commands();
    register_wifi_commands();
    register_display_commands();
    register_config_commands();
    register_ssh_commands();
    register_ftp_commands();
    register_radio_commands();
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
