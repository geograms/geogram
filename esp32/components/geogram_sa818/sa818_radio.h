#ifndef SA818_RADIO_H
#define SA818_RADIO_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "esp_err.h"
#include "sa818.h"

#ifdef __cplusplus
extern "C" {
#endif

#define SA818_RADIO_DEFAULT_APRS_FREQ_MHZ  144.800f

typedef struct sa818_radio_dev *sa818_radio_handle_t;

typedef void (*sa818_radio_audio_rx_cb_t)(const int16_t *samples,
                                          size_t sample_count,
                                          void *user_ctx);

typedef void (*sa818_aprs_rx_cb_t)(const char *from_callsign,
                                   const char *to_callsign,
                                   const char *message_text,
                                   const char *raw_tnc2,
                                   void *user_ctx);

typedef struct {
    sa818_config_t sa818;
    int squelch_pin;              // Optional, -1 when unavailable.
    int audio_in_pin;             // Optional, -1 disables RX audio capture.
    int audio_out_pin;            // Optional, -1 disables APRS AFSK TX audio.
    uint8_t bandwidth;            // 0=narrow, 1=wide
    uint8_t squelch;              // 0-8
    uint8_t volume;               // 0-8
    bool high_power;              // true=high power when supported
    float tx_freq_mhz;            // Initial TX frequency
    float rx_freq_mhz;            // Initial RX frequency
    float aprs_freq_mhz;          // APRS default frequency
    uint32_t audio_sample_rate_hz;// Defaults to 9600 when 0
} sa818_radio_config_t;

esp_err_t sa818_radio_create(const sa818_radio_config_t *config, sa818_radio_handle_t *out_handle);
esp_err_t sa818_radio_delete(sa818_radio_handle_t handle);

sa818_handle_t sa818_radio_get_modem(sa818_radio_handle_t handle);

esp_err_t sa818_radio_power(sa818_radio_handle_t handle, bool enabled);
bool sa818_radio_is_powered(sa818_radio_handle_t handle);

esp_err_t sa818_radio_set_high_power(sa818_radio_handle_t handle, bool high_power);
bool sa818_radio_is_high_power(sa818_radio_handle_t handle);

esp_err_t sa818_radio_set_ptt(sa818_radio_handle_t handle, bool tx_enabled);
bool sa818_radio_is_ptt_enabled(sa818_radio_handle_t handle);

esp_err_t sa818_radio_set_frequency(sa818_radio_handle_t handle, float tx_freq_mhz, float rx_freq_mhz);
esp_err_t sa818_radio_get_frequency(sa818_radio_handle_t handle, float *tx_freq_mhz, float *rx_freq_mhz);

esp_err_t sa818_radio_set_squelch(sa818_radio_handle_t handle, uint8_t squelch);
esp_err_t sa818_radio_get_squelch(sa818_radio_handle_t handle, uint8_t *squelch);

esp_err_t sa818_radio_get_squelch_state(sa818_radio_handle_t handle, bool *squelched);

esp_err_t sa818_radio_start_audio_rx(sa818_radio_handle_t handle,
                                     sa818_radio_audio_rx_cb_t callback,
                                     void *user_ctx);
esp_err_t sa818_radio_stop_audio_rx(sa818_radio_handle_t handle);
bool sa818_radio_is_audio_rx_running(sa818_radio_handle_t handle);

esp_err_t sa818_radio_set_aprs_frequency(sa818_radio_handle_t handle, float aprs_freq_mhz);
float sa818_radio_get_aprs_frequency(sa818_radio_handle_t handle);
bool sa818_radio_is_aprs_tx_supported(sa818_radio_handle_t handle);
bool sa818_radio_is_aprs_tx_i2s(sa818_radio_handle_t handle);
esp_err_t sa818_radio_test_tone(sa818_radio_handle_t handle);

esp_err_t sa818_radio_set_aprs_rx_callback(sa818_radio_handle_t handle,
                                           sa818_aprs_rx_cb_t callback,
                                           void *user_ctx);

esp_err_t sa818_radio_send_aprs_message(sa818_radio_handle_t handle,
                                        const char *from_callsign,
                                        const char *to_callsign,
                                        const char *message_text);

typedef struct {
    uint32_t nrzi_bits;
    uint32_t flag_seen;
    uint32_t frame_candidates;
    uint32_t crc_ok;
    uint32_t crc_fail;
    uint32_t fifo_overflow;
} sa818_aprs_rx_stats_t;

void sa818_radio_get_aprs_rx_stats(sa818_radio_handle_t handle, sa818_aprs_rx_stats_t *out);

void sa818_radio_get_audio_capture(int16_t *out, size_t *out_len);

#ifdef __cplusplus
}
#endif

#endif // SA818_RADIO_H
