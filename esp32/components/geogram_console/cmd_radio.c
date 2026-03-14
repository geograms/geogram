/**
 * @file cmd_radio.c
 * @brief KV4P SA818 radio + APRS commands for serial console
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "app_config.h"
#include "console.h"
#include "esp_console.h"
#include "esp_log.h"
#include "station.h"

#if BOARD_MODEL == MODEL_KV4P

#include "model_init.h"

static const char *TAG = "cmd_radio";

static sa818_radio_handle_t get_radio_or_print_error(void)
{
    sa818_radio_handle_t radio = model_get_sa818_radio();
    if (radio == NULL) {
        printf("Error: SA818 radio module is not initialized\n");
    }
    return radio;
}

static bool parse_on_off(const char *arg, bool *enabled)
{
    if (!arg || !enabled) {
        return false;
    }
    if (strcmp(arg, "on") == 0 || strcmp(arg, "1") == 0 || strcmp(arg, "true") == 0) {
        *enabled = true;
        return true;
    }
    if (strcmp(arg, "off") == 0 || strcmp(arg, "0") == 0 || strcmp(arg, "false") == 0) {
        *enabled = false;
        return true;
    }
    return false;
}

static void aprs_rx_console_cb(const char *from_callsign,
                               const char *to_callsign,
                               const char *message_text,
                               const char *raw_tnc2,
                               void *user_ctx)
{
    (void)user_ctx;
    printf("\n[APRS RX] %s -> %s: %s\n", from_callsign, to_callsign, message_text);
    printf("[APRS RX] %s\n", raw_tnc2);
    printf("geogram> ");
    fflush(stdout);
}

static int cmd_radio_status(int argc, char **argv)
{
    (void)argc;
    (void)argv;

    sa818_radio_handle_t radio = get_radio_or_print_error();
    if (!radio) {
        return 1;
    }

    float tx_mhz = 0.0f;
    float rx_mhz = 0.0f;
    uint8_t squelch = 0;
    bool squelched = false;
    const char *aprs_tx_backend = "none";
    if (sa818_radio_is_aprs_tx_i2s(radio)) {
        aprs_tx_backend = "i2s";
    } else if (sa818_radio_is_aprs_tx_supported(radio)) {
        aprs_tx_backend = "dac";
    }

    sa818_radio_get_frequency(radio, &tx_mhz, &rx_mhz);
    sa818_radio_get_squelch(radio, &squelch);
    esp_err_t sq_ret = sa818_radio_get_squelch_state(radio, &squelched);

    int rssi = 0;
    esp_err_t rssi_ret = ESP_FAIL;
    sa818_handle_t modem = model_get_sa818();
    if (modem != NULL && sa818_radio_is_powered(radio)) {
        rssi_ret = sa818_read_rssi(modem, &rssi, 800);
    }

    if (console_get_output_mode() == CONSOLE_OUTPUT_JSON) {
        printf("{\"powered\":%s,\"ptt\":%s,\"high_power\":%s,\"tx_freq\":%.3f,\"rx_freq\":%.3f,"
               "\"aprs_freq\":%.3f,\"aprs_tx_backend\":\"%s\",\"squelch\":%u,\"audio_rx\":%s",
               sa818_radio_is_powered(radio) ? "true" : "false",
               sa818_radio_is_ptt_enabled(radio) ? "true" : "false",
               sa818_radio_is_high_power(radio) ? "true" : "false",
               (double)tx_mhz, (double)rx_mhz,
               (double)sa818_radio_get_aprs_frequency(radio),
               aprs_tx_backend,
               (unsigned)squelch,
               sa818_radio_is_audio_rx_running(radio) ? "true" : "false");

        if (sq_ret == ESP_OK) {
            printf(",\"squelched\":%s", squelched ? "true" : "false");
        }
        if (rssi_ret == ESP_OK) {
            printf(",\"rssi\":%d", rssi);
        }
        printf("}\n");
        return 0;
    }

    printf("Radio power:    %s\n", sa818_radio_is_powered(radio) ? "ON" : "OFF");
    printf("PTT:            %s\n", sa818_radio_is_ptt_enabled(radio) ? "TX" : "RX");
    printf("Power level:    %s\n", sa818_radio_is_high_power(radio) ? "HIGH" : "LOW");
    printf("Frequency TX:   %.3f MHz\n", (double)tx_mhz);
    printf("Frequency RX:   %.3f MHz\n", (double)rx_mhz);
    printf("APRS frequency: %.3f MHz\n", (double)sa818_radio_get_aprs_frequency(radio));
    printf("APRS TX audio:  %s\n", sa818_radio_is_aprs_tx_i2s(radio) ? "I2S+DAC" :
                                (sa818_radio_is_aprs_tx_supported(radio) ? "DAC oneshot" : "UNAVAILABLE"));
    printf("Squelch level:  %u\n", (unsigned)squelch);
    if (sq_ret == ESP_OK) {
        printf("Squelch pin:    %s\n", squelched ? "CLOSED" : "OPEN");
    } else {
        printf("Squelch pin:    unavailable\n");
    }
    printf("Audio RX:       %s\n", sa818_radio_is_audio_rx_running(radio) ? "RUNNING" : "STOPPED");
    if (rssi_ret == ESP_OK) {
        printf("RSSI:           %d\n", rssi);
    }
    return 0;
}

static int cmd_radio_power(int argc, char **argv)
{
    if (argc != 2) {
        printf("Usage: radio_power <on|off>\n");
        return 1;
    }

    bool enabled = false;
    if (!parse_on_off(argv[1], &enabled)) {
        printf("Invalid value: %s (use on/off)\n", argv[1]);
        return 1;
    }

    sa818_radio_handle_t radio = get_radio_or_print_error();
    if (!radio) {
        return 1;
    }

    esp_err_t ret = sa818_radio_power(radio, enabled);
    if (ret != ESP_OK) {
        printf("Error: %s\n", esp_err_to_name(ret));
        return 1;
    }
    printf("Radio power %s\n", enabled ? "ON" : "OFF");
    return 0;
}

static int cmd_radio_freq(int argc, char **argv)
{
    sa818_radio_handle_t radio = get_radio_or_print_error();
    if (!radio) {
        return 1;
    }

    if (argc == 1) {
        float tx_mhz = 0.0f;
        float rx_mhz = 0.0f;
        sa818_radio_get_frequency(radio, &tx_mhz, &rx_mhz);
        printf("TX: %.3f MHz, RX: %.3f MHz\n", (double)tx_mhz, (double)rx_mhz);
        return 0;
    }

    if (argc != 2) {
        printf("Usage: radio_freq [mhz]\n");
        return 1;
    }

    char *endptr = NULL;
    float mhz = strtof(argv[1], &endptr);
    if (endptr == argv[1] || *endptr != '\0' || mhz <= 0.0f) {
        printf("Invalid frequency: %s\n", argv[1]);
        return 1;
    }

    esp_err_t ret = sa818_radio_set_frequency(radio, mhz, mhz);
    if (ret != ESP_OK) {
        printf("Error: %s\n", esp_err_to_name(ret));
        return 1;
    }

    printf("Radio frequency set to %.3f MHz\n", (double)mhz);
    return 0;
}

static int cmd_radio_squelch(int argc, char **argv)
{
    sa818_radio_handle_t radio = get_radio_or_print_error();
    if (!radio) {
        return 1;
    }

    if (argc == 1) {
        uint8_t squelch = 0;
        sa818_radio_get_squelch(radio, &squelch);
        printf("Squelch: %u\n", (unsigned)squelch);
        return 0;
    }

    if (argc != 2) {
        printf("Usage: radio_squelch [0-8]\n");
        return 1;
    }

    char *endptr = NULL;
    long level = strtol(argv[1], &endptr, 10);
    if (endptr == argv[1] || *endptr != '\0' || level < 0 || level > 8) {
        printf("Invalid squelch: %s\n", argv[1]);
        return 1;
    }

    esp_err_t ret = sa818_radio_set_squelch(radio, (uint8_t)level);
    if (ret != ESP_OK) {
        printf("Error: %s\n", esp_err_to_name(ret));
        return 1;
    }

    printf("Squelch set to %ld\n", level);
    return 0;
}

static int cmd_radio_ptt(int argc, char **argv)
{
    if (argc != 2) {
        printf("Usage: radio_ptt <on|off>\n");
        return 1;
    }

    bool tx_enabled = false;
    if (!parse_on_off(argv[1], &tx_enabled)) {
        printf("Invalid value: %s (use on/off)\n", argv[1]);
        return 1;
    }

    sa818_radio_handle_t radio = get_radio_or_print_error();
    if (!radio) {
        return 1;
    }

    esp_err_t ret = sa818_radio_set_ptt(radio, tx_enabled);
    if (ret != ESP_OK) {
        printf("Error: %s\n", esp_err_to_name(ret));
        return 1;
    }

    printf("PTT %s\n", tx_enabled ? "ON (TX)" : "OFF (RX)");
    return 0;
}

static int cmd_aprs_freq(int argc, char **argv)
{
    sa818_radio_handle_t radio = get_radio_or_print_error();
    if (!radio) {
        return 1;
    }

    if (argc == 1) {
        printf("APRS frequency: %.3f MHz\n", (double)sa818_radio_get_aprs_frequency(radio));
        return 0;
    }

    if (argc != 2) {
        printf("Usage: aprs_freq [mhz]\n");
        return 1;
    }

    char *endptr = NULL;
    float mhz = strtof(argv[1], &endptr);
    if (endptr == argv[1] || *endptr != '\0' || mhz <= 0.0f) {
        printf("Invalid frequency: %s\n", argv[1]);
        return 1;
    }

    esp_err_t ret = sa818_radio_set_aprs_frequency(radio, mhz);
    if (ret != ESP_OK) {
        printf("Error: %s\n", esp_err_to_name(ret));
        return 1;
    }

    printf("APRS frequency set to %.3f MHz\n", (double)mhz);
    return 0;
}

static int cmd_aprs_listen(int argc, char **argv)
{
    if (argc != 2) {
        printf("Usage: aprs_listen <on|off>\n");
        return 1;
    }

    bool enabled = false;
    if (!parse_on_off(argv[1], &enabled)) {
        printf("Invalid value: %s (use on/off)\n", argv[1]);
        return 1;
    }

    sa818_radio_handle_t radio = get_radio_or_print_error();
    if (!radio) {
        return 1;
    }

    esp_err_t ret = sa818_radio_set_aprs_rx_callback(radio, aprs_rx_console_cb, NULL);
    if (ret != ESP_OK) {
        printf("Error: %s\n", esp_err_to_name(ret));
        return 1;
    }

    if (enabled) {
        ret = sa818_radio_start_audio_rx(radio, NULL, NULL);
        if (ret != ESP_OK && ret != ESP_ERR_INVALID_STATE) {
            printf("Error: %s\n", esp_err_to_name(ret));
            return 1;
        }
        printf("APRS listening enabled\n");
    } else {
        ret = sa818_radio_stop_audio_rx(radio);
        if (ret != ESP_OK) {
            printf("Error: %s\n", esp_err_to_name(ret));
            return 1;
        }
        printf("APRS listening disabled\n");
    }

    return 0;
}

static int cmd_aprs_send(int argc, char **argv)
{
    if (argc < 3) {
        printf("Usage: aprs_send <callsign> <message...>\n");
        return 1;
    }

    sa818_radio_handle_t radio = get_radio_or_print_error();
    if (!radio) {
        return 1;
    }

    char msg[96];
    size_t offset = 0;
    msg[0] = '\0';
    for (int i = 2; i < argc; i++) {
        const char *part = argv[i];
        size_t part_len = strlen(part);
        if (offset + part_len + 2 >= sizeof(msg)) {
            break;
        }
        if (i > 2) {
            msg[offset++] = ' ';
        }
        memcpy(&msg[offset], part, part_len);
        offset += part_len;
        msg[offset] = '\0';
    }

    const char *from_callsign = station_get_callsign();
    if (!from_callsign || from_callsign[0] == '\0') {
        printf("Error: Source callsign is not configured\n");
        return 1;
    }

    esp_err_t ret = sa818_radio_send_aprs_message(radio, from_callsign, argv[1], msg);
    if (ret != ESP_OK) {
        printf("Error: %s\n", esp_err_to_name(ret));
        return 1;
    }

    ESP_LOGI(TAG, "APRS TX %s -> %s: %s", from_callsign, argv[1], msg);
    printf("APRS message sent (%s -> %s)\n", from_callsign, argv[1]);
    return 0;
}

static int cmd_test_tone(int argc, char **argv)
{
    (void)argc; (void)argv;
    sa818_radio_handle_t radio = get_radio_or_print_error();
    if (!radio) return 1;
    esp_err_t ret = sa818_radio_test_tone(radio);
    if (ret != ESP_OK) {
        printf("Error: %s\n", esp_err_to_name(ret));
        return 1;
    }
    printf("Test tone complete\n");
    return 0;
}

void register_radio_commands(void)
{
    const esp_console_cmd_t radio_cmd = {
        .command = "radio",
        .help = "Show SA818 radio status",
        .hint = NULL,
        .func = &cmd_radio_status,
    };
    ESP_ERROR_CHECK(esp_console_cmd_register(&radio_cmd));

    const esp_console_cmd_t radio_power_cmd = {
        .command = "radio_power",
        .help = "Power SA818 radio on/off",
        .hint = NULL,
        .func = &cmd_radio_power,
    };
    ESP_ERROR_CHECK(esp_console_cmd_register(&radio_power_cmd));

    const esp_console_cmd_t radio_freq_cmd = {
        .command = "radio_freq",
        .help = "Get/set SA818 TX+RX frequency in MHz",
        .hint = NULL,
        .func = &cmd_radio_freq,
    };
    ESP_ERROR_CHECK(esp_console_cmd_register(&radio_freq_cmd));

    const esp_console_cmd_t radio_squelch_cmd = {
        .command = "radio_squelch",
        .help = "Get/set SA818 squelch level (0-8)",
        .hint = NULL,
        .func = &cmd_radio_squelch,
    };
    ESP_ERROR_CHECK(esp_console_cmd_register(&radio_squelch_cmd));

    const esp_console_cmd_t radio_ptt_cmd = {
        .command = "radio_ptt",
        .help = "Set SA818 PTT state on/off",
        .hint = NULL,
        .func = &cmd_radio_ptt,
    };
    ESP_ERROR_CHECK(esp_console_cmd_register(&radio_ptt_cmd));

    const esp_console_cmd_t aprs_freq_cmd = {
        .command = "aprs_freq",
        .help = "Get/set default APRS frequency in MHz",
        .hint = NULL,
        .func = &cmd_aprs_freq,
    };
    ESP_ERROR_CHECK(esp_console_cmd_register(&aprs_freq_cmd));

    const esp_console_cmd_t aprs_listen_cmd = {
        .command = "aprs_listen",
        .help = "Enable/disable APRS reception pipeline",
        .hint = NULL,
        .func = &cmd_aprs_listen,
    };
    ESP_ERROR_CHECK(esp_console_cmd_register(&aprs_listen_cmd));

    const esp_console_cmd_t aprs_send_cmd = {
        .command = "aprs_send",
        .help = "Send APRS text: aprs_send <callsign> <message...>",
        .hint = NULL,
        .func = &cmd_aprs_send,
    };
    ESP_ERROR_CHECK(esp_console_cmd_register(&aprs_send_cmd));

    const esp_console_cmd_t test_tone_cmd = {
        .command = "test_tone",
        .help = "Output alternating 1200/2200 Hz test tone via radio",
        .hint = NULL,
        .func = &cmd_test_tone,
    };
    ESP_ERROR_CHECK(esp_console_cmd_register(&test_tone_cmd));

    ESP_LOGI(TAG, "Radio/APRS commands registered");
}

#else

void register_radio_commands(void)
{
}

#endif
