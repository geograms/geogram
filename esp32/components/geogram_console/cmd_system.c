/**
 * @file cmd_system.c
 * @brief System commands for serial console
 */

#include <stdio.h>
#include <string.h>
#include "console.h"
#include "esp_console.h"
#include "esp_system.h"
#include "esp_log.h"
#include "esp_chip_info.h"
#include "esp_flash.h"
#include "argtable3/argtable3.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "station.h"
#include "model_init.h"
#include "app_config.h"
#include "wifi_bsp.h"
#include "geogram_ble.h"

#if BOARD_MODEL == MODEL_ESP32S3_EPAPER_1IN54
#include "sdcard.h"
#include "shtc3.h"
#endif

static const char *TAG = "cmd_system";

// ============================================================================
// status command
// ============================================================================

static int cmd_status(int argc, char **argv)
{
    console_output_mode_t mode = console_get_output_mode();

    if (mode == CONSOLE_OUTPUT_JSON) {
        // Build JSON status using station API
        char json_buf[512];
        station_build_status_json(json_buf, sizeof(json_buf));
        printf("%s\n", json_buf);
    } else {
        // Human-readable status
        printf("\n=== Geogram Device Status ===\n\n");

        // Firmware info
        printf("Firmware: %s\n", GEOGRAM_VERSION);
        printf("Board: %s\n", BOARD_NAME);

        // Station info
        printf("Callsign: %s\n", station_get_callsign());

        // Uptime
        uint32_t uptime = station_get_uptime();
        uint32_t hours = uptime / 3600;
        uint32_t mins = (uptime % 3600) / 60;
        uint32_t secs = uptime % 60;
        printf("Uptime: %luh %lum %lus\n", (unsigned long)hours, (unsigned long)mins, (unsigned long)secs);

        // WiFi status
        geogram_wifi_status_t wifi_status = geogram_wifi_get_status();
        char ip_str[16] = {0};
        if (wifi_status == GEOGRAM_WIFI_STATUS_GOT_IP) {
            geogram_wifi_get_ip(ip_str);
            printf("\nWiFi: Connected (%s)\n", ip_str);
        } else if (geogram_wifi_is_ap_active()) {
            geogram_wifi_get_ap_ip(ip_str);
            printf("\nWiFi: AP Mode (%s)\n", ip_str);
        } else {
            printf("\nWiFi: Disconnected\n");
        }

        printf("BLE: %s\n", geogram_ble_is_running() ? "Advertising" : "Stopped");

        // Sensor data
#if BOARD_MODEL == MODEL_ESP32S3_EPAPER_1IN54
        shtc3_handle_t sensor = model_get_env_sensor();
        if (sensor != NULL) {
            shtc3_data_t data;
            if (shtc3_read(sensor, &data) == ESP_OK) {
                printf("\nSensors:\n");
                printf("  Temperature: %.1f C\n", data.temperature);
                printf("  Humidity: %.1f %%\n", data.humidity);
            }
        }
#endif

        // SD card
#if BOARD_MODEL == MODEL_ESP32S3_EPAPER_1IN54
        if (sdcard_is_mounted()) {
            printf("\nSD Card: Mounted (%.2f GB)\n", sdcard_get_capacity_gb());
        } else {
            printf("\nSD Card: Not mounted\n");
        }
#endif

        // Heap memory
        printf("Heap: %lu bytes free\n", (unsigned long)esp_get_free_heap_size());
        printf("\n");
    }

    return 0;
}

// ============================================================================
// version command
// ============================================================================

static int cmd_version(int argc, char **argv)
{
    console_printf("version", "%s", GEOGRAM_VERSION);
    if (console_get_output_mode() == CONSOLE_OUTPUT_TEXT) {
        printf("\n");
    }
    return 0;
}

// ============================================================================
// reboot command
// ============================================================================

static int cmd_reboot(int argc, char **argv)
{
    printf("Rebooting...\n");
    vTaskDelay(pdMS_TO_TICKS(100));
    esp_restart();
    return 0;  // Never reached
}

// ============================================================================
// heap command
// ============================================================================

static int cmd_heap(int argc, char **argv)
{
    size_t free_heap = esp_get_free_heap_size();
    size_t min_heap = esp_get_minimum_free_heap_size();

    if (console_get_output_mode() == CONSOLE_OUTPUT_JSON) {
        printf("{\"free\":%zu,\"minimum\":%zu}\n", free_heap, min_heap);
    } else {
        printf("Free heap: %zu bytes\n", free_heap);
        printf("Minimum free heap: %zu bytes\n", min_heap);
    }

    return 0;
}

// ============================================================================
// uptime command
// ============================================================================

static int cmd_uptime(int argc, char **argv)
{
    uint32_t uptime = station_get_uptime();

    if (console_get_output_mode() == CONSOLE_OUTPUT_JSON) {
        printf("{\"uptime\":%lu}\n", (unsigned long)uptime);
    } else {
        uint32_t days = uptime / 86400;
        uint32_t hours = (uptime % 86400) / 3600;
        uint32_t mins = (uptime % 3600) / 60;
        uint32_t secs = uptime % 60;

        if (days > 0) {
            printf("Uptime: %lud %luh %lum %lus\n",
                   (unsigned long)days, (unsigned long)hours,
                   (unsigned long)mins, (unsigned long)secs);
        } else if (hours > 0) {
            printf("Uptime: %luh %lum %lus\n",
                   (unsigned long)hours, (unsigned long)mins, (unsigned long)secs);
        } else if (mins > 0) {
            printf("Uptime: %lum %lus\n", (unsigned long)mins, (unsigned long)secs);
        } else {
            printf("Uptime: %lus\n", (unsigned long)secs);
        }
    }

    return 0;
}

// ============================================================================
// format command (set output format)
// ============================================================================

static struct {
    struct arg_str *format;
    struct arg_end *end;
} format_args;

static int cmd_format(int argc, char **argv)
{
    int nerrors = arg_parse(argc, argv, (void **)&format_args);
    if (nerrors != 0) {
        arg_print_errors(stderr, format_args.end, argv[0]);
        return 1;
    }

    if (format_args.format->count > 0) {
        const char *fmt = format_args.format->sval[0];
        if (strcmp(fmt, "json") == 0) {
            console_set_output_mode(CONSOLE_OUTPUT_JSON);
            printf("Output format set to JSON\n");
        } else if (strcmp(fmt, "text") == 0) {
            console_set_output_mode(CONSOLE_OUTPUT_TEXT);
            printf("Output format set to text\n");
        } else {
            printf("Unknown format: %s (use 'text' or 'json')\n", fmt);
            return 1;
        }
    } else {
        // Show current format
        console_output_mode_t mode = console_get_output_mode();
        printf("Current format: %s\n", mode == CONSOLE_OUTPUT_JSON ? "json" : "text");
    }

    return 0;
}

// ============================================================================
// log command (set log level)
// ============================================================================

static struct {
    struct arg_str *level;
    struct arg_end *end;
} log_args;

static int cmd_log(int argc, char **argv)
{
    int nerrors = arg_parse(argc, argv, (void **)&log_args);
    if (nerrors != 0) {
        arg_print_errors(stderr, log_args.end, argv[0]);
        return 1;
    }

    if (log_args.level->count > 0) {
        const char *level = log_args.level->sval[0];
        esp_log_level_t log_level;

        if (strcmp(level, "none") == 0) {
            log_level = ESP_LOG_NONE;
        } else if (strcmp(level, "error") == 0) {
            log_level = ESP_LOG_ERROR;
        } else if (strcmp(level, "warn") == 0) {
            log_level = ESP_LOG_WARN;
        } else if (strcmp(level, "info") == 0) {
            log_level = ESP_LOG_INFO;
        } else if (strcmp(level, "debug") == 0) {
            log_level = ESP_LOG_DEBUG;
        } else if (strcmp(level, "verbose") == 0) {
            log_level = ESP_LOG_VERBOSE;
        } else {
            printf("Unknown level: %s\n", level);
            printf("Valid levels: none, error, warn, info, debug, verbose\n");
            return 1;
        }

        esp_log_level_set("*", log_level);
        printf("Log level set to %s\n", level);
    } else {
        printf("Usage: log <level>\n");
        printf("Levels: none, error, warn, info, debug, verbose\n");
    }

    return 0;
}

// ============================================================================
// Register all system commands
// ============================================================================

void register_system_commands(void)
{
    // status
    const esp_console_cmd_t status_cmd = {
        .command = "status",
        .help = "Show full device status",
        .hint = NULL,
        .func = &cmd_status,
    };
    ESP_ERROR_CHECK(esp_console_cmd_register(&status_cmd));

    // version
    const esp_console_cmd_t version_cmd = {
        .command = "version",
        .help = "Show firmware version",
        .hint = NULL,
        .func = &cmd_version,
    };
    ESP_ERROR_CHECK(esp_console_cmd_register(&version_cmd));

    // reboot
    const esp_console_cmd_t reboot_cmd = {
        .command = "reboot",
        .help = "Reboot the device",
        .hint = NULL,
        .func = &cmd_reboot,
    };
    ESP_ERROR_CHECK(esp_console_cmd_register(&reboot_cmd));

    // heap
    const esp_console_cmd_t heap_cmd = {
        .command = "heap",
        .help = "Show free heap memory",
        .hint = NULL,
        .func = &cmd_heap,
    };
    ESP_ERROR_CHECK(esp_console_cmd_register(&heap_cmd));

    // uptime
    const esp_console_cmd_t uptime_cmd = {
        .command = "uptime",
        .help = "Show device uptime",
        .hint = NULL,
        .func = &cmd_uptime,
    };
    ESP_ERROR_CHECK(esp_console_cmd_register(&uptime_cmd));

    // format
    format_args.format = arg_str0(NULL, NULL, "<text|json>", "Output format");
    format_args.end = arg_end(1);
    const esp_console_cmd_t format_cmd = {
        .command = "format",
        .help = "Get/set output format (text or json)",
        .hint = NULL,
        .func = &cmd_format,
        .argtable = &format_args,
    };
    ESP_ERROR_CHECK(esp_console_cmd_register(&format_cmd));

    // log
    log_args.level = arg_str0(NULL, NULL, "<level>", "Log level");
    log_args.end = arg_end(1);
    const esp_console_cmd_t log_cmd = {
        .command = "log",
        .help = "Set log level (none/error/warn/info/debug/verbose)",
        .hint = NULL,
        .func = &cmd_log,
        .argtable = &log_args,
    };
    ESP_ERROR_CHECK(esp_console_cmd_register(&log_cmd));

    ESP_LOGI(TAG, "System commands registered");
}
