#include <ctype.h>
#include <limits.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "sa818_radio.h"
#include "soc/soc_caps.h"
#if CONFIG_IDF_TARGET_ESP32
#include "driver/i2s.h"
#include "driver/dac.h"
#endif
#if SOC_DAC_SUPPORTED
#include "driver/dac_oneshot.h"
#endif
#include "driver/gpio.h"
#include "esp_adc/adc_oneshot.h"
#include "esp_idf_version.h"
#include "esp_log.h"
#include "esp_rom_sys.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

static const char *TAG = "sa818_radio";

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#define SA818_RADIO_CMD_TIMEOUT_MS      1500
#define SA818_RADIO_RX_TASK_STACK       4096
#define SA818_RADIO_RX_TASK_PRIO        4
#define SA818_RADIO_AUDIO_BLOCK_SAMPLES 160
#define SA818_RADIO_RX_STATS_LOG        0
#define SA818_RADIO_IDLE_YIELD_US       100000LL
#define APRS_HDLC_FLAG                  0x7EU
#define APRS_HDLC_RESET                 0x7FU
#define APRS_AX25_ESC                   0x1BU
#define APRS_AX25_CRC_CORRECT           0xF0B8U
#define APRS_RX_FIFO_SIZE               768U

#define APRS_SAMPLE_RATE_HZ             9600U
#define APRS_SAMPLES_PER_BIT            (APRS_SAMPLE_RATE_HZ / APRS_BITRATE_BPS)
#define APRS_MARK_FREQ_HZ               1200.0f
#define APRS_SPACE_FREQ_HZ              2200.0f
#define APRS_BITRATE_BPS                1200U
#define APRS_DEMOD_DELAY_SAMPLES        ((APRS_SAMPLE_RATE_HZ + APRS_BITRATE_BPS) / (2U * APRS_BITRATE_BPS))
#define APRS_FIR_TAPS                   31U
#define APRS_PHASE_BITS                 8
#define APRS_PHASE_INC                  1
#define APRS_PHASE_MAX                  ((APRS_SAMPLE_RATE_HZ / APRS_BITRATE_BPS) * APRS_PHASE_BITS)
#define APRS_PHASE_THRESHOLD            (APRS_PHASE_MAX / 2)
#define APRS_PREAMBLE_FLAGS             350U
#define APRS_TAIL_FLAGS                 50U
#define APRS_TX_LEAD_MS                 250U
#define APRS_TX_TAIL_MS                 120U
#define APRS_MAX_FRAME_BYTES            330U
#define APRS_MAX_RAW_BITS               (APRS_MAX_FRAME_BYTES * 12U)
#define APRS_MAX_INFO_BYTES             120U
#define APRS_MAX_MESSAGE_SEQ            999U

#if CONFIG_IDF_TARGET_ESP32
#define APRS_I2S_SAMPLE_RATE_HZ         48000U
#define APRS_I2S_BITS_PER_SAMPLE        16
#define APRS_I2S_SAMPLES_PER_BIT        (APRS_I2S_SAMPLE_RATE_HZ / 1200U)
#define APRS_I2S_SIN_LEN                512U
#define APRS_I2S_TX_BLOCK_SAMPLES       320U
#define APRS_I2S_RF_LEVEL_SHIFT         7U
#define APRS_I2S_RF_LEVEL_OFFSET        10000U
#define APRS_I2S_PHASE_MARK_INC         ((uint16_t)(((APRS_I2S_SIN_LEN * APRS_MARK_FREQ_HZ) / APRS_I2S_SAMPLE_RATE_HZ) + 0.5f))
#define APRS_I2S_PHASE_SPACE_INC        ((uint16_t)(((APRS_I2S_SIN_LEN * APRS_SPACE_FREQ_HZ) / APRS_I2S_SAMPLE_RATE_HZ) + 0.5f))
#endif

#if CONFIG_IDF_TARGET_ESP32
// Quarter-wave table adapted from APRS-ESP LibAPRS_ESP32 (Afsk sin LUT path).
static const uint8_t s_aprs_sin_q[] = {
    128, 129, 131, 132, 134, 135, 137, 138, 140, 142, 143, 145, 146, 148, 149, 151,
    152, 154, 155, 157, 158, 160, 162, 163, 165, 166, 167, 169, 170, 172, 173, 175,
    176, 178, 179, 181, 182, 183, 185, 186, 188, 189, 190, 192, 193, 194, 196, 197,
    198, 200, 201, 202, 203, 205, 206, 207, 208, 210, 211, 212, 213, 214, 215, 217,
    218, 219, 220, 221, 222, 223, 224, 225, 226, 227, 228, 229, 230, 231, 232, 233,
    234, 234, 235, 236, 237, 238, 238, 239, 240, 241, 241, 242, 243, 243, 244, 245,
    245, 246, 246, 247, 248, 248, 249, 249, 250, 250, 250, 251, 251, 252, 252, 252,
    253, 253, 253, 253, 254, 254, 254, 254, 254, 255, 255, 255, 255, 255, 255, 255,
    255,
};

static inline uint8_t aprs_sin_sample(uint16_t phase)
{
    uint16_t idx = phase % (APRS_I2S_SIN_LEN / 2U);
    if (idx >= (APRS_I2S_SIN_LEN / 4U)) {
        idx = (APRS_I2S_SIN_LEN / 2U) - idx - 1U;
    }
    uint8_t s = s_aprs_sin_q[idx];
    return (phase >= (APRS_I2S_SIN_LEN / 2U)) ? (uint8_t)(255U - s) : s;
}
#endif

typedef struct {
    uint8_t rx_fifo[APRS_RX_FIFO_SIZE];
    size_t fifo_head;
    size_t fifo_tail;

    uint8_t frame[APRS_MAX_FRAME_BYTES];
    size_t ax25_frame_len;
    bool ax25_sync;
    bool ax25_escape;
    uint16_t ax25_crc_in;

    uint8_t hdlc_demod_bits;
    uint8_t hdlc_bit_index;
    uint8_t hdlc_current_byte;
    bool hdlc_receiving;

    int16_t delay_line[APRS_DEMOD_DELAY_SAMPLES];
    size_t delay_idx;

    int16_t lpf_coeff[APRS_FIR_TAPS];
    int16_t lpf_hist[APRS_FIR_TAPS];
    size_t lpf_index;
    int32_t discriminator_dc_q8;

    uint16_t sampled_bits;
    uint8_t actual_bits;
    int16_t current_phase;

    uint32_t nrzi_bits;
    uint32_t flag_seen;
    uint32_t frame_candidates;
    uint32_t crc_ok;
    uint32_t crc_fail;
    uint32_t fifo_overflow;
} aprs_decoder_state_t;

struct sa818_radio_dev {
    sa818_handle_t modem;
    sa818_radio_config_t cfg;

    bool powered;
    bool ptt_enabled;
    bool high_power;
    float tx_freq_mhz;
    float rx_freq_mhz;
    float aprs_freq_mhz;
    uint8_t squelch;
    uint8_t bandwidth;

    bool adc_ready;
    adc_oneshot_unit_handle_t adc_unit;
    adc_channel_t adc_channel;

#if SOC_DAC_SUPPORTED
    bool dac_ready;
    dac_oneshot_handle_t dac_handle;
#endif
#if CONFIG_IDF_TARGET_ESP32
    bool i2s_tx_ready;
#endif

    volatile bool rx_task_running;
    TaskHandle_t rx_task;
    sa818_radio_audio_rx_cb_t audio_rx_cb;
    void *audio_rx_ctx;

    sa818_aprs_rx_cb_t aprs_rx_cb;
    void *aprs_rx_ctx;
    aprs_decoder_state_t aprs_dec;
    uint16_t aprs_message_seq;

    SemaphoreHandle_t lock;
};

static inline uint16_t aprs_crc16_update(uint16_t crc, uint8_t data)
{
    crc ^= data;
    for (int i = 0; i < 8; i++) {
        if ((crc & 0x0001U) != 0U) {
            crc = (uint16_t)((crc >> 1) ^ 0x8408U);
        } else {
            crc >>= 1;
        }
    }
    return crc;
}

static uint16_t aprs_crc16(const uint8_t *data, size_t len)
{
    uint16_t crc = 0xFFFFU;
    for (size_t i = 0; i < len; i++) {
        crc = aprs_crc16_update(crc, data[i]);
    }
    return (uint16_t)~crc;
}

static bool parse_callsign_ssid(const char *input,
                                char *callsign_out,
                                size_t callsign_out_len,
                                uint8_t *ssid_out)
{
    if (!input || !callsign_out || callsign_out_len < 7 || !ssid_out) {
        return false;
    }

    const char *dash = strchr(input, '-');
    size_t call_len = dash ? (size_t)(dash - input) : strlen(input);
    if (call_len == 0 || call_len > 6) {
        return false;
    }

    memset(callsign_out, 0, callsign_out_len);
    for (size_t i = 0; i < call_len; i++) {
        unsigned char c = (unsigned char)input[i];
        if (!isalnum(c)) {
            return false;
        }
        callsign_out[i] = (char)toupper(c);
    }

    uint8_t ssid = 0;
    if (dash != NULL) {
        char *endptr = NULL;
        long ssid_val = strtol(dash + 1, &endptr, 10);
        if (endptr == dash + 1 || *endptr != '\0' || ssid_val < 0 || ssid_val > 15) {
            return false;
        }
        ssid = (uint8_t)ssid_val;
    }

    *ssid_out = ssid;
    return true;
}

static void encode_ax25_address(const char *callsign, uint8_t ssid, bool last, uint8_t out[7])
{
    char padded[6] = {' ', ' ', ' ', ' ', ' ', ' '};
    size_t call_len = strlen(callsign);
    if (call_len > 6) {
        call_len = 6;
    }

    for (size_t i = 0; i < call_len; i++) {
        padded[i] = (char)toupper((unsigned char)callsign[i]);
    }

    for (int i = 0; i < 6; i++) {
        out[i] = (uint8_t)(padded[i] << 1);
    }

    out[6] = (uint8_t)((ssid & 0x0FU) << 1);
    out[6] |= 0x60U;
    if (last) {
        out[6] |= 0x01U;
    }
}

static void decode_ax25_address(const uint8_t in[7], char *out, size_t out_len)
{
    char callsign[7];
    size_t n = 0;

    for (int i = 0; i < 6; i++) {
        char c = (char)(in[i] >> 1);
        if (c == ' ') {
            continue;
        }
        if (n < sizeof(callsign) - 1) {
            callsign[n++] = c;
        }
    }
    callsign[n] = '\0';

    uint8_t ssid = (uint8_t)((in[6] >> 1) & 0x0FU);
    if (ssid == 0) {
        snprintf(out, out_len, "%s", callsign);
    } else {
        snprintf(out, out_len, "%s-%u", callsign, ssid);
    }
}

static void trim_right_spaces(char *str)
{
    if (!str) {
        return;
    }

    size_t len = strlen(str);
    while (len > 0 && str[len - 1] == ' ') {
        str[len - 1] = '\0';
        len--;
    }
}

static void sanitize_message_text(const char *in, char *out, size_t out_len)
{
    if (!out || out_len == 0) {
        return;
    }
    out[0] = '\0';

    if (!in) {
        return;
    }

    size_t out_idx = 0;
    for (size_t i = 0; in[i] != '\0' && out_idx + 1 < out_len; i++) {
        unsigned char c = (unsigned char)in[i];
        if (c < 32 || c > 126) {
            continue;
        }
        if (c == '{' || c == '|' || c == '~') {
            c = ' ';
        }
        out[out_idx++] = (char)c;
    }
    out[out_idx] = '\0';
}

static esp_err_t sa818_radio_apply_group(sa818_radio_handle_t handle)
{
    if (!handle || !handle->modem) {
        return ESP_ERR_INVALID_ARG;
    }

    return sa818_set_group(handle->modem,
                           handle->bandwidth,
                           handle->tx_freq_mhz,
                           handle->rx_freq_mhz,
                           "0000",
                           handle->squelch,
                           "0000",
                           SA818_RADIO_CMD_TIMEOUT_MS);
}

static esp_err_t sa818_radio_configure_squelch_pin(sa818_radio_handle_t handle)
{
    if (!handle) {
        return ESP_ERR_INVALID_ARG;
    }

    if (handle->cfg.squelch_pin < 0) {
        return ESP_OK;
    }

    gpio_config_t io_conf = {
        .pin_bit_mask = (1ULL << handle->cfg.squelch_pin),
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    return gpio_config(&io_conf);
}

static esp_err_t sa818_radio_configure_adc(sa818_radio_handle_t handle)
{
    if (!handle) {
        return ESP_ERR_INVALID_ARG;
    }

    if (handle->cfg.audio_in_pin < 0) {
        return ESP_OK;
    }

    adc_unit_t unit = ADC_UNIT_1;
    adc_channel_t channel = ADC_CHANNEL_0;
    esp_err_t ret = adc_oneshot_io_to_channel(handle->cfg.audio_in_pin, &unit, &channel);
    if (ret != ESP_OK) {
        ESP_LOGW(TAG, "Audio in GPIO%d is not ADC-capable (%s)",
                 handle->cfg.audio_in_pin, esp_err_to_name(ret));
        return ret;
    }

    if (unit != ADC_UNIT_1) {
        ESP_LOGW(TAG, "Audio in GPIO%d uses unsupported ADC unit %d", handle->cfg.audio_in_pin, unit);
        return ESP_ERR_NOT_SUPPORTED;
    }

    adc_oneshot_unit_init_cfg_t unit_cfg = {
        .unit_id = unit,
        .ulp_mode = ADC_ULP_MODE_DISABLE,
    };
    ret = adc_oneshot_new_unit(&unit_cfg, &handle->adc_unit);
    if (ret != ESP_OK) {
        return ret;
    }

    adc_oneshot_chan_cfg_t chan_cfg = {
        .bitwidth = ADC_BITWIDTH_12,
        .atten = ADC_ATTEN_DB_12,
    };
    ret = adc_oneshot_config_channel(handle->adc_unit, channel, &chan_cfg);
    if (ret != ESP_OK) {
        adc_oneshot_del_unit(handle->adc_unit);
        handle->adc_unit = NULL;
        return ret;
    }

    handle->adc_channel = channel;
    handle->adc_ready = true;
    return ESP_OK;
}

#if CONFIG_IDF_TARGET_ESP32
static esp_err_t sa818_radio_configure_i2s_tx(sa818_radio_handle_t handle)
{
    if (!handle) {
        return ESP_ERR_INVALID_ARG;
    }
    if (handle->cfg.audio_out_pin != 25 && handle->cfg.audio_out_pin != 26) {
        return ESP_ERR_NOT_SUPPORTED;
    }

    // Match APRS-ESP behavior: keep I2S in stereo framing and mirror the same
    // sample on both channels, while enabling only the target DAC channel.
    i2s_channel_fmt_t channel_fmt = (handle->cfg.audio_out_pin == 25)
                                    ? I2S_CHANNEL_FMT_ALL_RIGHT
                                    : I2S_CHANNEL_FMT_ALL_LEFT;

    i2s_config_t i2s_cfg = {
        .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_TX | I2S_MODE_DAC_BUILT_IN),
        .sample_rate = APRS_I2S_SAMPLE_RATE_HZ,
        .bits_per_sample = I2S_BITS_PER_SAMPLE_16BIT,
        .channel_format = channel_fmt,
#if ESP_IDF_VERSION >= ESP_IDF_VERSION_VAL(4, 2, 0)
        .communication_format = I2S_COMM_FORMAT_STAND_MSB,
#else
        .communication_format = I2S_COMM_FORMAT_I2S_MSB,
#endif
        .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
        .dma_buf_count = 5,
        .dma_buf_len = 768,
        .use_apll = false,
        .tx_desc_auto_clear = true,
        .fixed_mclk = 0,
    };

    esp_err_t ret = i2s_driver_install(I2S_NUM_0, &i2s_cfg, 0, NULL);
    if (ret != ESP_OK) {
        return ret;
    }

    ret = i2s_set_pin(I2S_NUM_0, NULL);
    if (ret != ESP_OK) {
        i2s_driver_uninstall(I2S_NUM_0);
        return ret;
    }

    i2s_dac_mode_t dac_mode = (handle->cfg.audio_out_pin == 25) ? I2S_DAC_CHANNEL_RIGHT_EN : I2S_DAC_CHANNEL_LEFT_EN;
    ret = i2s_set_dac_mode(dac_mode);
    if (ret != ESP_OK) {
        i2s_driver_uninstall(I2S_NUM_0);
        return ret;
    }

    ret = i2s_zero_dma_buffer(I2S_NUM_0);
    if (ret != ESP_OK) {
        i2s_driver_uninstall(I2S_NUM_0);
        return ret;
    }

    dac_i2s_enable();

    handle->i2s_tx_ready = true;
    ESP_LOGI(TAG, "APRS TX using I2S+DAC on GPIO%d @ %u Hz", handle->cfg.audio_out_pin, APRS_I2S_SAMPLE_RATE_HZ);
    return ESP_OK;
}
#endif

#if SOC_DAC_SUPPORTED
static esp_err_t sa818_radio_configure_dac(sa818_radio_handle_t handle)
{
    if (!handle) {
        return ESP_ERR_INVALID_ARG;
    }

    if (handle->cfg.audio_out_pin < 0) {
        return ESP_OK;
    }

    dac_channel_t channel;
    if (handle->cfg.audio_out_pin == 25) {
        channel = DAC_CHAN_0;
    } else if (handle->cfg.audio_out_pin == 26) {
        channel = DAC_CHAN_1;
    } else {
        ESP_LOGW(TAG, "Audio out GPIO%d does not map to built-in DAC (supported: 25,26)",
                 handle->cfg.audio_out_pin);
        return ESP_ERR_NOT_SUPPORTED;
    }

    dac_oneshot_config_t cfg = {
        .chan_id = channel,
    };
    esp_err_t ret = dac_oneshot_new_channel(&cfg, &handle->dac_handle);
    if (ret != ESP_OK) {
        return ret;
    }

    handle->dac_ready = true;
    dac_oneshot_output_voltage(handle->dac_handle, 128);
    return ESP_OK;
}
#endif

static uint8_t aprs_count_ones_u8(uint8_t value)
{
    uint8_t count = 0;
    while (value != 0U) {
        value &= (uint8_t)(value - 1U);
        count++;
    }
    return count;
}

static inline bool aprs_signal_transitioned(uint16_t bits)
{
    return ((((bits) ^ (bits >> 2)) & 0x03U) == 0x03U);
}

static inline bool aprs_transition_found(uint8_t bits)
{
    return (((bits) ^ (bits >> 1)) & 0x01U) != 0U;
}

static float aprs_sinc(float x)
{
    if (fabsf(x) < 1e-6f) {
        return 1.0f;
    }
    return sinf(x) / x;
}

static float aprs_windowf(float x)
{
    return 0.54f + 0.46f * cosf(x);
}

static void aprs_design_fir_bandpass(int16_t coeffs[APRS_FIR_TAPS], float pass_hz, float cutoff_hz)
{
    const int taps = (int)APRS_FIR_TAPS;
    const int mid = (taps - 1) / 2;
    const float rp = pass_hz / (float)APRS_SAMPLE_RATE_HZ;
    const float rc = cutoff_hz / (float)APRS_SAMPLE_RATE_HZ;
    const float amplitude = 32767.0f;

    for (int n = -mid; n <= mid; n++) {
        float coeff = amplitude * 2.0f
                      * ((rc * aprs_sinc(2.0f * (float)M_PI * rc * (float)n))
                         - (rp * aprs_sinc(2.0f * (float)M_PI * rp * (float)n)))
                      * aprs_windowf((float)M_PI * (float)n / (float)mid);
        coeffs[n + mid] = (int16_t)lrintf(coeff);
    }
}

static void aprs_decoder_init_demod(aprs_decoder_state_t *dec)
{
    if (!dec) {
        return;
    }

    memset(dec->rx_fifo, 0, sizeof(dec->rx_fifo));
    dec->fifo_head = 0U;
    dec->fifo_tail = 0U;

    memset(dec->frame, 0, sizeof(dec->frame));
    dec->ax25_frame_len = 0U;
    dec->ax25_sync = false;
    dec->ax25_escape = false;
    dec->ax25_crc_in = 0xFFFFU;

    dec->hdlc_demod_bits = 0U;
    dec->hdlc_bit_index = 0U;
    dec->hdlc_current_byte = 0U;
    dec->hdlc_receiving = false;

    memset(dec->delay_line, 0, sizeof(dec->delay_line));
    dec->delay_idx = 0;
    memset(dec->lpf_hist, 0, sizeof(dec->lpf_hist));
    dec->lpf_index = 0;
    dec->discriminator_dc_q8 = 0;
    dec->sampled_bits = 0;
    dec->actual_bits = 0;
    dec->current_phase = 0;
    dec->nrzi_bits = 0;
    dec->flag_seen = 0;
    dec->frame_candidates = 0;
    dec->crc_ok = 0;
    dec->crc_fail = 0;
    dec->fifo_overflow = 0;

    aprs_design_fir_bandpass(dec->lpf_coeff, 0.0f, 1200.0f);
}

static int16_t aprs_decoder_filter_core(const int16_t coeffs[APRS_FIR_TAPS],
                                        int16_t hist[APRS_FIR_TAPS],
                                        size_t *index,
                                        int16_t sample)
{
    hist[*index] = sample;

    int32_t sum = 0;
    for (size_t i = 0; i < APRS_FIR_TAPS; i++) {
        size_t idx = (*index + i) % APRS_FIR_TAPS;
        sum += (int32_t)coeffs[i] * (int32_t)hist[idx];
    }

    *index = (*index + APRS_FIR_TAPS - 1U) % APRS_FIR_TAPS;
    return (int16_t)(sum >> 16);
}

typedef struct {
    char src[16];
    char dst[16];
    char path[80];
    char info[APRS_MAX_INFO_BYTES + 1];
} aprs_packet_t;

static bool aprs_decode_ax25_frame(const uint8_t *frame, size_t frame_len, aprs_packet_t *packet)
{
    if (!frame || !packet || frame_len < 18) {
        return false;
    }

    uint16_t expected_fcs = (uint16_t)(frame[frame_len - 2] | (frame[frame_len - 1] << 8));
    uint16_t computed_fcs = aprs_crc16(frame, frame_len - 2);
    if (computed_fcs != expected_fcs) {
        return false;
    }

    size_t idx = 0;
    const size_t payload_len = frame_len - 2;
    const uint8_t *addresses[8];
    size_t address_count = 0;
    bool last = false;

    while (!last) {
        if (idx + 7 > payload_len || address_count >= 8) {
            return false;
        }
        addresses[address_count] = &frame[idx];
        last = (frame[idx + 6] & 0x01U) != 0;
        idx += 7;
        address_count++;
    }

    if (address_count < 2 || idx + 2 > payload_len) {
        return false;
    }

    uint8_t control = frame[idx++];
    uint8_t pid = frame[idx++];
    if (control != 0x03U || pid != 0xF0U) {
        return false;
    }

    decode_ax25_address(addresses[0], packet->dst, sizeof(packet->dst));
    decode_ax25_address(addresses[1], packet->src, sizeof(packet->src));

    packet->path[0] = '\0';
    for (size_t i = 2; i < address_count; i++) {
        char hop[16];
        decode_ax25_address(addresses[i], hop, sizeof(hop));

        if (packet->path[0] != '\0') {
            strlcat(packet->path, ",", sizeof(packet->path));
        }
        strlcat(packet->path, hop, sizeof(packet->path));
    }

    size_t info_len = payload_len - idx;
    if (info_len > APRS_MAX_INFO_BYTES) {
        info_len = APRS_MAX_INFO_BYTES;
    }
    memcpy(packet->info, &frame[idx], info_len);
    packet->info[info_len] = '\0';
    return true;
}

static bool aprs_decoder_emit_frame(sa818_radio_handle_t handle,
                                    const uint8_t *frame,
                                    size_t frame_len)
{
    if (!handle || !frame) {
        return false;
    }

    aprs_packet_t packet;
    if (!aprs_decode_ax25_frame(frame, frame_len, &packet)) {
        return false;
    }

    char to_callsign[16];
    char message[APRS_MAX_INFO_BYTES + 1];
    snprintf(to_callsign, sizeof(to_callsign), "%s", packet.dst);
    snprintf(message, sizeof(message), "%s", packet.info);

    size_t info_len = strlen(packet.info);
    if (info_len >= 11 && packet.info[0] == ':' && packet.info[10] == ':') {
        char addressee[10];
        memcpy(addressee, &packet.info[1], 9);
        addressee[9] = '\0';
        trim_right_spaces(addressee);
        snprintf(to_callsign, sizeof(to_callsign), "%s", addressee);
        snprintf(message, sizeof(message), "%s", &packet.info[11]);
    }

    char raw_tnc2[256];
    if (packet.path[0] != '\0') {
        snprintf(raw_tnc2, sizeof(raw_tnc2), "%s>%s,%s:%s",
                 packet.src, packet.dst, packet.path, packet.info);
    } else {
        snprintf(raw_tnc2, sizeof(raw_tnc2), "%s>%s:%s",
                 packet.src, packet.dst, packet.info);
    }

    sa818_aprs_rx_cb_t cb = handle->aprs_rx_cb;
    if (cb != NULL) {
        cb(packet.src, to_callsign, message, raw_tnc2, handle->aprs_rx_ctx);
    }
    return true;
}

static inline bool aprs_decoder_fifo_is_empty(const aprs_decoder_state_t *dec)
{
    return dec->fifo_head == dec->fifo_tail;
}

static inline bool aprs_decoder_fifo_is_full(const aprs_decoder_state_t *dec)
{
    return ((dec->fifo_tail + 1U) % APRS_RX_FIFO_SIZE) == dec->fifo_head;
}

static void aprs_decoder_fifo_flush(aprs_decoder_state_t *dec)
{
    dec->fifo_head = 0U;
    dec->fifo_tail = 0U;
}

static bool aprs_decoder_fifo_push(aprs_decoder_state_t *dec, uint8_t c)
{
    if (aprs_decoder_fifo_is_full(dec)) {
        dec->fifo_overflow++;
        return false;
    }
    dec->rx_fifo[dec->fifo_tail] = c;
    dec->fifo_tail = (dec->fifo_tail + 1U) % APRS_RX_FIFO_SIZE;
    return true;
}

static int aprs_decoder_fifo_pop(aprs_decoder_state_t *dec)
{
    if (aprs_decoder_fifo_is_empty(dec)) {
        return -1;
    }
    uint8_t c = dec->rx_fifo[dec->fifo_head];
    dec->fifo_head = (dec->fifo_head + 1U) % APRS_RX_FIFO_SIZE;
    return (int)c;
}

static void aprs_decoder_poll_ax25(sa818_radio_handle_t handle)
{
    aprs_decoder_state_t *dec = &handle->aprs_dec;
    int c = 0;

    while ((c = aprs_decoder_fifo_pop(dec)) >= 0) {
        if (!dec->ax25_escape && (uint8_t)c == APRS_HDLC_FLAG) {
            if (dec->ax25_frame_len >= 18U) {
                dec->frame_candidates++;
                if (dec->ax25_crc_in == APRS_AX25_CRC_CORRECT &&
                    aprs_decoder_emit_frame(handle, dec->frame, dec->ax25_frame_len)) {
                    dec->crc_ok++;
                } else {
                    dec->crc_fail++;
                }
            }

            dec->ax25_sync = true;
            dec->ax25_crc_in = 0xFFFFU;
            dec->ax25_frame_len = 0U;
            continue;
        }

        if (!dec->ax25_escape && (uint8_t)c == APRS_HDLC_RESET) {
            dec->ax25_sync = false;
            dec->ax25_frame_len = 0U;
            continue;
        }

        if (!dec->ax25_escape && (uint8_t)c == APRS_AX25_ESC) {
            dec->ax25_escape = true;
            continue;
        }

        if (dec->ax25_sync) {
            if (dec->ax25_frame_len < APRS_MAX_FRAME_BYTES) {
                dec->frame[dec->ax25_frame_len++] = (uint8_t)c;
                dec->ax25_crc_in = aprs_crc16_update(dec->ax25_crc_in, (uint8_t)c);
            } else {
                dec->ax25_sync = false;
                dec->ax25_frame_len = 0U;
            }
        }

        dec->ax25_escape = false;
    }
}

static bool aprs_decoder_hdlc_parse(aprs_decoder_state_t *dec, bool bit)
{
    bool ret = true;

    dec->hdlc_demod_bits <<= 1;
    dec->hdlc_demod_bits |= bit ? 1U : 0U;

    if (dec->hdlc_demod_bits == APRS_HDLC_FLAG) {
        if (!aprs_decoder_fifo_push(dec, APRS_HDLC_FLAG)) {
            ret = false;
            dec->hdlc_receiving = false;
        } else {
            dec->hdlc_receiving = true;
            dec->flag_seen++;
        }
        dec->hdlc_current_byte = 0U;
        dec->hdlc_bit_index = 0U;
        return ret;
    }

    if ((dec->hdlc_demod_bits & APRS_HDLC_RESET) == APRS_HDLC_RESET) {
        dec->hdlc_receiving = false;
        return ret;
    }

    if (!dec->hdlc_receiving) {
        return ret;
    }

    if ((dec->hdlc_demod_bits & 0x3FU) == 0x3EU) {
        return ret;
    }

    if ((dec->hdlc_demod_bits & 0x01U) != 0U) {
        dec->hdlc_current_byte |= 0x80U;
    }

    if (++dec->hdlc_bit_index >= 8U) {
        if (dec->hdlc_current_byte == APRS_HDLC_FLAG ||
            dec->hdlc_current_byte == APRS_HDLC_RESET ||
            dec->hdlc_current_byte == APRS_AX25_ESC) {
            if (!aprs_decoder_fifo_push(dec, APRS_AX25_ESC)) {
                dec->hdlc_receiving = false;
                ret = false;
            }
        }

        if (!aprs_decoder_fifo_push(dec, dec->hdlc_current_byte)) {
            dec->hdlc_receiving = false;
            ret = false;
        }
        dec->hdlc_current_byte = 0U;
        dec->hdlc_bit_index = 0U;
    } else {
        dec->hdlc_current_byte >>= 1;
    }

    return ret;
}

static void aprs_decoder_process_nrzi_bit(sa818_radio_handle_t handle, uint8_t bit)
{
    aprs_decoder_state_t *dec = &handle->aprs_dec;
    dec->nrzi_bits++;
    if (!aprs_decoder_hdlc_parse(dec, bit != 0U)) {
        aprs_decoder_fifo_flush(dec);
        dec->ax25_sync = false;
        dec->ax25_escape = false;
        dec->ax25_crc_in = 0xFFFFU;
        dec->ax25_frame_len = 0U;
    }
    aprs_decoder_poll_ax25(handle);
}

static void aprs_decoder_feed_sample(sa818_radio_handle_t handle, int16_t sample)
{
    if (!handle) {
        return;
    }

    aprs_decoder_state_t *dec = &handle->aprs_dec;
    int16_t delayed = dec->delay_line[dec->delay_idx];
    dec->delay_line[dec->delay_idx] = sample;
    dec->delay_idx = (dec->delay_idx + 1U) % APRS_DEMOD_DELAY_SAMPLES;

    int32_t mixed = (int32_t)sample * (int32_t)delayed;
    int16_t discriminator = aprs_decoder_filter_core(dec->lpf_coeff, dec->lpf_hist, &dec->lpf_index, (int16_t)(mixed >> 7));
    int32_t discriminator_q8 = (int32_t)discriminator << 8;
    dec->discriminator_dc_q8 += (discriminator_q8 - dec->discriminator_dc_q8) >> 6;
    int16_t discriminator_centered = (int16_t)(discriminator - (int16_t)(dec->discriminator_dc_q8 >> 8));

    dec->sampled_bits <<= 1;
    dec->sampled_bits |= (discriminator_centered > 0) ? 1U : 0U;

    if (aprs_signal_transitioned(dec->sampled_bits)) {
        if (dec->current_phase < APRS_PHASE_THRESHOLD) {
            dec->current_phase += APRS_PHASE_INC;
        } else {
            dec->current_phase -= APRS_PHASE_INC;
        }
    }

    dec->current_phase += APRS_PHASE_BITS;
    if (dec->current_phase < APRS_PHASE_MAX) {
        return;
    }

    dec->current_phase %= APRS_PHASE_MAX;
    dec->actual_bits <<= 1;

    uint8_t bit_window = (uint8_t)(dec->sampled_bits & 0x1FU);
    if (aprs_count_ones_u8(bit_window) >= 3U) {
        dec->actual_bits |= 1U;
    }

    uint8_t nrzi_bit = (uint8_t)(!aprs_transition_found(dec->actual_bits));
    aprs_decoder_process_nrzi_bit(handle, nrzi_bit);
}

static void sa818_radio_rx_task(void *arg)
{
    sa818_radio_handle_t handle = (sa818_radio_handle_t)arg;
    const uint32_t sample_rate = handle->cfg.audio_sample_rate_hz;
    const uint32_t base_interval_us = (sample_rate > 0U) ? (1000000U / sample_rate) : 0U;
    const uint32_t interval_remainder = (sample_rate > 0U) ? (1000000U % sample_rate) : 0U;
    uint32_t interval_err = 0U;
    int64_t next_sample_us = esp_timer_get_time();
    int64_t idle_yield_at_us = next_sample_us + SA818_RADIO_IDLE_YIELD_US;
#if SA818_RADIO_RX_STATS_LOG
    int64_t stats_next_us = next_sample_us + 1000000LL;

    int32_t dc_estimate_q8 = 0;
    bool dc_initialized = false;
    uint32_t samples_this_second = 0U;
    int16_t min_demod_sample = INT16_MAX;
    int16_t max_demod_sample = INT16_MIN;
    uint32_t prev_nrzi_bits = 0U;
    uint32_t prev_flags = 0U;
    uint32_t prev_frames = 0U;
    uint32_t prev_crc_ok = 0U;
    uint32_t prev_crc_fail = 0U;
    uint32_t prev_fifo_overflow = 0U;
#else
    int32_t dc_estimate_q8 = 0;
    bool dc_initialized = false;
#endif

    int16_t block[SA818_RADIO_AUDIO_BLOCK_SAMPLES];
    size_t block_fill = 0;

    while (handle->rx_task_running) {
        int raw = 0;
        esp_err_t ret = adc_oneshot_read(handle->adc_unit, handle->adc_channel, &raw);
        if (ret == ESP_OK) {
            if (!dc_initialized) {
                dc_estimate_q8 = ((int32_t)raw << 8);
                dc_initialized = true;
            }
            int32_t raw_q8 = (int32_t)raw << 8;
            dc_estimate_q8 += (raw_q8 - dc_estimate_q8) >> 7;

            int centered = raw - (int)(dc_estimate_q8 >> 8);
            int16_t demod_sample = (int16_t)centered;
            int audio_scaled = centered << 4;
            if (audio_scaled > 32767) {
                audio_scaled = 32767;
            } else if (audio_scaled < -32768) {
                audio_scaled = -32768;
            }
            int16_t audio_sample = (int16_t)audio_scaled;
            aprs_decoder_feed_sample(handle, demod_sample);
#if SA818_RADIO_RX_STATS_LOG
            samples_this_second++;
            if (demod_sample < min_demod_sample) {
                min_demod_sample = demod_sample;
            }
            if (demod_sample > max_demod_sample) {
                max_demod_sample = demod_sample;
            }
#endif

            sa818_radio_audio_rx_cb_t cb = handle->audio_rx_cb;
            if (cb != NULL) {
                block[block_fill++] = audio_sample;
                if (block_fill >= SA818_RADIO_AUDIO_BLOCK_SAMPLES) {
                    cb(block, block_fill, handle->audio_rx_ctx);
                    block_fill = 0;
                }
            }
        }

        if (base_interval_us == 0U) {
            vTaskDelay(pdMS_TO_TICKS(1));
            continue;
        }

        uint32_t wait_us = base_interval_us;
        interval_err += interval_remainder;
        if (interval_err >= sample_rate) {
            interval_err -= sample_rate;
            wait_us += 1U;
        }

        next_sample_us += (int64_t)wait_us;
        int64_t now_us = esp_timer_get_time();
#if SA818_RADIO_RX_STATS_LOG
        if (now_us >= stats_next_us) {
            aprs_decoder_state_t *dec = &handle->aprs_dec;
            uint32_t bits_delta = dec->nrzi_bits - prev_nrzi_bits;
            uint32_t flags_delta = dec->flag_seen - prev_flags;
            uint32_t frames_delta = dec->frame_candidates - prev_frames;
            uint32_t crc_ok_delta = dec->crc_ok - prev_crc_ok;
            uint32_t crc_fail_delta = dec->crc_fail - prev_crc_fail;
            uint32_t fifo_overflow_delta = dec->fifo_overflow - prev_fifo_overflow;
            prev_nrzi_bits = dec->nrzi_bits;
            prev_flags = dec->flag_seen;
            prev_frames = dec->frame_candidates;
            prev_crc_ok = dec->crc_ok;
            prev_crc_fail = dec->crc_fail;
            prev_fifo_overflow = dec->fifo_overflow;

            ESP_LOGI(TAG, "APRS RX stats: %u sps demod=[%d,%d] offset=%d bits=%u flags=%u frames=%u ok=%u fail=%u ovf=%u",
                     (unsigned)samples_this_second,
                     (int)min_demod_sample,
                     (int)max_demod_sample,
                     (int)(dc_estimate_q8 >> 8),
                     (unsigned)bits_delta,
                     (unsigned)flags_delta,
                     (unsigned)frames_delta,
                     (unsigned)crc_ok_delta,
                     (unsigned)crc_fail_delta,
                     (unsigned)fifo_overflow_delta);
            samples_this_second = 0U;
            min_demod_sample = INT16_MAX;
            max_demod_sample = INT16_MIN;
            stats_next_us = now_us + 1000000LL;
        }
#endif

        if (next_sample_us > now_us) {
            esp_rom_delay_us((uint32_t)(next_sample_us - now_us));
        } else if ((now_us - next_sample_us) > 500000LL) {
            // Recover from long scheduler stalls.
            next_sample_us = now_us;
        }

        if (now_us >= idle_yield_at_us) {
            // Allow IDLE task to run so task watchdog does not trigger while
            // we keep this high-rate sampling loop active.
            vTaskDelay(pdMS_TO_TICKS(1));
            next_sample_us = esp_timer_get_time();
            idle_yield_at_us = next_sample_us + SA818_RADIO_IDLE_YIELD_US;
        }
    }

    handle->rx_task = NULL;
    vTaskDelete(NULL);
}

typedef struct {
#if CONFIG_IDF_TARGET_ESP32
    uint16_t phase_acc;
    uint16_t pcm_block[APRS_I2S_TX_BLOCK_SAMPLES];
    size_t pcm_fill;
    size_t i2s_bytes_written;
#endif
    float phase;
    int64_t next_sample_us;
} aprs_tx_stream_t;

static esp_err_t aprs_tx_stream_flush(sa818_radio_handle_t handle, aprs_tx_stream_t *stream)
{
#if CONFIG_IDF_TARGET_ESP32
    if (handle->i2s_tx_ready && stream->pcm_fill > 0) {
        size_t bytes_written = 0;
        esp_err_t ret = i2s_write(I2S_NUM_0,
                                  (const char *)stream->pcm_block,
                                  stream->pcm_fill * sizeof(uint16_t),
                                  &bytes_written,
                                  portMAX_DELAY);
        stream->i2s_bytes_written += bytes_written;
        stream->pcm_fill = 0;
        if (ret != ESP_OK) {
            return ret;
        }
    }
#else
    (void)handle;
    (void)stream;
#endif
    return ESP_OK;
}

static void aprs_tx_stream_init(sa818_radio_handle_t handle, aprs_tx_stream_t *stream)
{
    memset(stream, 0, sizeof(*stream));
#if SOC_DAC_SUPPORTED
    if (!handle->dac_ready) {
        return;
    }
#else
    (void)handle;
    return;
#endif
    stream->phase = 0.0f;
    stream->next_sample_us = esp_timer_get_time();
}

static esp_err_t aprs_tx_symbol(sa818_radio_handle_t handle,
                                bool mark_tone,
                                aprs_tx_stream_t *stream)
{
#if CONFIG_IDF_TARGET_ESP32
    if (handle->i2s_tx_ready) {
        const uint16_t phase_inc = mark_tone ? APRS_I2S_PHASE_MARK_INC : APRS_I2S_PHASE_SPACE_INC;
        for (size_t i = 0; i < APRS_I2S_SAMPLES_PER_BIT; i++) {
            uint8_t sample = aprs_sin_sample(stream->phase_acc);
            stream->phase_acc = (uint16_t)((stream->phase_acc + phase_inc) % APRS_I2S_SIN_LEN);
            // Match APRS-ESP RF scaling: avoid overdriving SA818 mic input.
            uint16_t pcm = (uint16_t)(((uint16_t)sample << APRS_I2S_RF_LEVEL_SHIFT) + APRS_I2S_RF_LEVEL_OFFSET);
            // In stereo-framed I2S mode, duplicate the sample across both slots.
            stream->pcm_block[stream->pcm_fill++] = pcm;
            stream->pcm_block[stream->pcm_fill++] = pcm;
            if (stream->pcm_fill >= APRS_I2S_TX_BLOCK_SAMPLES - 1U) {
                esp_err_t ret = aprs_tx_stream_flush(handle, stream);
                if (ret != ESP_OK) {
                    return ret;
                }
            }
        }
        return ESP_OK;
    }
#endif

#if SOC_DAC_SUPPORTED
    const float freq = mark_tone ? APRS_MARK_FREQ_HZ : APRS_SPACE_FREQ_HZ;
    const float step = (float)(2.0 * M_PI * freq / (double)APRS_SAMPLE_RATE_HZ);

    for (size_t i = 0; i < APRS_SAMPLES_PER_BIT; i++) {
        int sample = 128 + (int)(38.0f * sinf(stream->phase));
        if (sample < 0) {
            sample = 0;
        } else if (sample > 255) {
            sample = 255;
        }

        esp_err_t ret = dac_oneshot_output_voltage(handle->dac_handle, (uint8_t)sample);
        if (ret != ESP_OK) {
            return ret;
        }

        stream->phase += step;
        if (stream->phase >= (float)(2.0 * M_PI)) {
            stream->phase -= (float)(2.0 * M_PI);
        }

        stream->next_sample_us += (1000000U / APRS_SAMPLE_RATE_HZ);
        int64_t now_us = esp_timer_get_time();
        if (stream->next_sample_us > now_us) {
            esp_rom_delay_us((uint32_t)(stream->next_sample_us - now_us));
        } else {
            stream->next_sample_us = now_us;
        }
    }

    return ESP_OK;
#else
    return ESP_ERR_NOT_SUPPORTED;
#endif
}

static esp_err_t aprs_tx_nrzi_bit(sa818_radio_handle_t handle,
                                  uint8_t bit,
                                  bool *mark_state,
                                  aprs_tx_stream_t *stream)
{
    if ((bit & 0x01U) == 0U) {
        *mark_state = !(*mark_state);
    }
    return aprs_tx_symbol(handle, *mark_state, stream);
}

static esp_err_t aprs_tx_flag(sa818_radio_handle_t handle,
                              bool *mark_state,
                              aprs_tx_stream_t *stream)
{
    const uint8_t flag = 0x7EU;
    for (int bit = 0; bit < 8; bit++) {
        esp_err_t ret = aprs_tx_nrzi_bit(handle, (uint8_t)((flag >> bit) & 0x01U),
                                         mark_state, stream);
        if (ret != ESP_OK) {
            return ret;
        }
    }
    return ESP_OK;
}

static esp_err_t aprs_tx_data_with_stuffing(sa818_radio_handle_t handle,
                                            const uint8_t *data,
                                            size_t len,
                                            bool *mark_state,
                                            aprs_tx_stream_t *stream)
{
    uint8_t ones = 0;

    for (size_t i = 0; i < len; i++) {
        for (int bit = 0; bit < 8; bit++) {
            uint8_t b = (uint8_t)((data[i] >> bit) & 0x01U);
            esp_err_t ret = aprs_tx_nrzi_bit(handle, b, mark_state, stream);
            if (ret != ESP_OK) {
                return ret;
            }

            if (b != 0U) {
                ones++;
                if (ones == 5U) {
                    ret = aprs_tx_nrzi_bit(handle, 0U, mark_state, stream);
                    if (ret != ESP_OK) {
                        return ret;
                    }
                    ones = 0;
                }
            } else {
                ones = 0;
            }
        }
    }

    return ESP_OK;
}

static esp_err_t build_aprs_message_frame(const char *from_callsign,
                                          const char *to_callsign,
                                          const char *message_text,
                                          uint16_t message_seq,
                                          uint8_t *out_frame,
                                          size_t out_frame_len,
                                          size_t *out_len)
{
    if (!from_callsign || !to_callsign || !message_text || !out_frame || !out_len) {
        return ESP_ERR_INVALID_ARG;
    }

    char src_call[7];
    uint8_t src_ssid = 0;
    if (!parse_callsign_ssid(from_callsign, src_call, sizeof(src_call), &src_ssid)) {
        return ESP_ERR_INVALID_ARG;
    }

    char dst_msg_call[7];
    uint8_t dst_msg_ssid = 0;
    if (!parse_callsign_ssid(to_callsign, dst_msg_call, sizeof(dst_msg_call), &dst_msg_ssid)) {
        return ESP_ERR_INVALID_ARG;
    }

    char addressee[10];
    size_t addressee_len = 0;
    for (size_t i = 0; i < 6 && dst_msg_call[i] != '\0' && addressee_len < sizeof(addressee) - 1; i++) {
        addressee[addressee_len++] = dst_msg_call[i];
    }

    if (dst_msg_ssid != 0 && addressee_len + 2 < sizeof(addressee)) {
        addressee[addressee_len++] = '-';
        if (dst_msg_ssid >= 10) {
            addressee[addressee_len++] = (char)('0' + (dst_msg_ssid / 10));
            addressee[addressee_len++] = (char)('0' + (dst_msg_ssid % 10));
        } else {
            addressee[addressee_len++] = (char)('0' + dst_msg_ssid);
        }
    }
    addressee[addressee_len] = '\0';

    char cleaned_msg[APRS_MAX_INFO_BYTES + 1];
    sanitize_message_text(message_text, cleaned_msg, sizeof(cleaned_msg));

    char info[APRS_MAX_INFO_BYTES + 1];
    snprintf(info, sizeof(info), ":%-9.9s:%.67s{%03u",
             addressee, cleaned_msg, (unsigned)(message_seq % (APRS_MAX_MESSAGE_SEQ + 1U)));
    size_t info_len = strlen(info);

    size_t idx = 0;
    if (out_frame_len < 40 + info_len) {
        return ESP_ERR_INVALID_SIZE;
    }

    encode_ax25_address("APGEO1", 0, false, &out_frame[idx]);
    idx += 7;
    encode_ax25_address(src_call, src_ssid, false, &out_frame[idx]);
    idx += 7;
    encode_ax25_address("WIDE1", 1, false, &out_frame[idx]);
    idx += 7;
    encode_ax25_address("WIDE2", 1, true, &out_frame[idx]);
    idx += 7;

    out_frame[idx++] = 0x03U;
    out_frame[idx++] = 0xF0U;

    memcpy(&out_frame[idx], info, info_len);
    idx += info_len;

    uint16_t fcs = aprs_crc16(out_frame, idx);
    out_frame[idx++] = (uint8_t)(fcs & 0xFFU);
    out_frame[idx++] = (uint8_t)((fcs >> 8) & 0xFFU);

    *out_len = idx;
    return ESP_OK;
}

esp_err_t sa818_radio_create(const sa818_radio_config_t *config, sa818_radio_handle_t *out_handle)
{
    if (!config || !out_handle) {
        return ESP_ERR_INVALID_ARG;
    }

    struct sa818_radio_dev *dev = calloc(1, sizeof(struct sa818_radio_dev));
    if (!dev) {
        return ESP_ERR_NO_MEM;
    }

    dev->cfg = *config;
    dev->bandwidth = config->bandwidth ? 1 : 0;
    dev->squelch = config->squelch > 8 ? 8 : config->squelch;
    dev->high_power = config->high_power;
    dev->tx_freq_mhz = config->tx_freq_mhz > 0.0f ? config->tx_freq_mhz : SA818_RADIO_DEFAULT_APRS_FREQ_MHZ;
    dev->rx_freq_mhz = config->rx_freq_mhz > 0.0f ? config->rx_freq_mhz : SA818_RADIO_DEFAULT_APRS_FREQ_MHZ;
    dev->aprs_freq_mhz = config->aprs_freq_mhz > 0.0f ? config->aprs_freq_mhz : SA818_RADIO_DEFAULT_APRS_FREQ_MHZ;

    if (dev->cfg.audio_sample_rate_hz == 0 || dev->cfg.audio_sample_rate_hz != APRS_SAMPLE_RATE_HZ) {
        dev->cfg.audio_sample_rate_hz = APRS_SAMPLE_RATE_HZ;
    }
    if (dev->cfg.volume > 8) {
        dev->cfg.volume = 8;
    }

    dev->lock = xSemaphoreCreateMutex();
    if (!dev->lock) {
        free(dev);
        return ESP_ERR_NO_MEM;
    }

    esp_err_t ret = sa818_create(&dev->cfg.sa818, &dev->modem);
    if (ret != ESP_OK) {
        vSemaphoreDelete(dev->lock);
        free(dev);
        return ret;
    }

    ret = sa818_radio_configure_squelch_pin(dev);
    if (ret != ESP_OK) {
        sa818_delete(dev->modem);
        vSemaphoreDelete(dev->lock);
        free(dev);
        return ret;
    }

    ret = sa818_radio_configure_adc(dev);
    if (ret != ESP_OK && dev->cfg.audio_in_pin >= 0) {
        ESP_LOGW(TAG, "RX audio capture disabled: %s", esp_err_to_name(ret));
    }

#if CONFIG_IDF_TARGET_ESP32
    ret = sa818_radio_configure_i2s_tx(dev);
    if (ret != ESP_OK && dev->cfg.audio_out_pin >= 0) {
        ESP_LOGW(TAG, "I2S APRS TX unavailable, falling back to DAC oneshot: %s", esp_err_to_name(ret));
    }
#endif

#if SOC_DAC_SUPPORTED
    if (
#if CONFIG_IDF_TARGET_ESP32
        !dev->i2s_tx_ready &&
#endif
        dev->cfg.audio_out_pin >= 0) {
        ret = sa818_radio_configure_dac(dev);
        if (ret != ESP_OK) {
            ESP_LOGW(TAG, "APRS AFSK TX disabled: %s", esp_err_to_name(ret));
        }
    }
#endif

    aprs_decoder_init_demod(&dev->aprs_dec);

    ret = sa818_radio_power(dev, true);
    if (ret != ESP_OK) {
        if (dev->adc_ready && dev->adc_unit) {
            adc_oneshot_del_unit(dev->adc_unit);
        }
#if CONFIG_IDF_TARGET_ESP32
        if (dev->i2s_tx_ready) {
            i2s_driver_uninstall(I2S_NUM_0);
            dev->i2s_tx_ready = false;
        }
#endif
#if SOC_DAC_SUPPORTED
        if (dev->dac_ready && dev->dac_handle) {
            dac_oneshot_del_channel(dev->dac_handle);
        }
#endif
        sa818_delete(dev->modem);
        vSemaphoreDelete(dev->lock);
        free(dev);
        return ret;
    }

    *out_handle = dev;
    return ESP_OK;
}

esp_err_t sa818_radio_delete(sa818_radio_handle_t handle)
{
    if (!handle) {
        return ESP_ERR_INVALID_ARG;
    }

    sa818_radio_stop_audio_rx(handle);
    sa818_radio_power(handle, false);

    if (handle->adc_ready && handle->adc_unit != NULL) {
        adc_oneshot_del_unit(handle->adc_unit);
        handle->adc_unit = NULL;
        handle->adc_ready = false;
    }

#if SOC_DAC_SUPPORTED
    if (handle->dac_ready && handle->dac_handle != NULL) {
        dac_oneshot_del_channel(handle->dac_handle);
        handle->dac_handle = NULL;
        handle->dac_ready = false;
    }
#endif
#if CONFIG_IDF_TARGET_ESP32
    if (handle->i2s_tx_ready) {
        i2s_driver_uninstall(I2S_NUM_0);
        handle->i2s_tx_ready = false;
    }
#endif

    if (handle->modem != NULL) {
        sa818_delete(handle->modem);
        handle->modem = NULL;
    }

    if (handle->lock) {
        vSemaphoreDelete(handle->lock);
        handle->lock = NULL;
    }

    free(handle);
    return ESP_OK;
}

sa818_handle_t sa818_radio_get_modem(sa818_radio_handle_t handle)
{
    return handle ? handle->modem : NULL;
}

esp_err_t sa818_radio_power(sa818_radio_handle_t handle, bool enabled)
{
    if (!handle || !handle->modem) {
        return ESP_ERR_INVALID_ARG;
    }

    if (xSemaphoreTake(handle->lock, pdMS_TO_TICKS(1000)) != pdTRUE) {
        return ESP_ERR_TIMEOUT;
    }

    esp_err_t ret = ESP_OK;

    if (!enabled) {
        sa818_set_tx(handle->modem, false);
        ret = sa818_power(handle->modem, false);
        if (ret == ESP_OK) {
            handle->powered = false;
            handle->ptt_enabled = false;
        }
        xSemaphoreGive(handle->lock);
        return ret;
    }

    ret = sa818_power(handle->modem, true);
    if (ret != ESP_OK) {
        xSemaphoreGive(handle->lock);
        return ret;
    }

    ret = sa818_handshake(handle->modem, 2500);
    if (ret != ESP_OK) {
        xSemaphoreGive(handle->lock);
        return ret;
    }

    ret = sa818_set_tx(handle->modem, false);
    if (ret != ESP_OK) {
        xSemaphoreGive(handle->lock);
        return ret;
    }

    ret = sa818_set_high_power(handle->modem, handle->high_power);
    if (ret != ESP_OK) {
        xSemaphoreGive(handle->lock);
        return ret;
    }

    ret = sa818_set_volume(handle->modem, handle->cfg.volume, SA818_RADIO_CMD_TIMEOUT_MS);
    if (ret != ESP_OK) {
        xSemaphoreGive(handle->lock);
        return ret;
    }

    ret = sa818_set_filters(handle->modem, true, true, true, SA818_RADIO_CMD_TIMEOUT_MS);
    if (ret != ESP_OK) {
        xSemaphoreGive(handle->lock);
        return ret;
    }

    ret = sa818_set_tail(handle->modem, 0, SA818_RADIO_CMD_TIMEOUT_MS);
    if (ret != ESP_OK) {
        xSemaphoreGive(handle->lock);
        return ret;
    }

    ret = sa818_radio_apply_group(handle);
    if (ret == ESP_OK) {
        handle->powered = true;
        handle->ptt_enabled = false;
    }

    xSemaphoreGive(handle->lock);
    return ret;
}

bool sa818_radio_is_powered(sa818_radio_handle_t handle)
{
    return handle ? handle->powered : false;
}

esp_err_t sa818_radio_set_high_power(sa818_radio_handle_t handle, bool high_power)
{
    if (!handle || !handle->modem) {
        return ESP_ERR_INVALID_ARG;
    }

    handle->high_power = high_power;
    if (!handle->powered) {
        return ESP_OK;
    }
    return sa818_set_high_power(handle->modem, high_power);
}

bool sa818_radio_is_high_power(sa818_radio_handle_t handle)
{
    return handle ? handle->high_power : false;
}

esp_err_t sa818_radio_set_ptt(sa818_radio_handle_t handle, bool tx_enabled)
{
    if (!handle || !handle->modem) {
        return ESP_ERR_INVALID_ARG;
    }
    if (!handle->powered) {
        return ESP_ERR_INVALID_STATE;
    }

    esp_err_t ret = sa818_set_tx(handle->modem, tx_enabled);
    if (ret == ESP_OK) {
        handle->ptt_enabled = tx_enabled;
    }
    return ret;
}

bool sa818_radio_is_ptt_enabled(sa818_radio_handle_t handle)
{
    return handle ? handle->ptt_enabled : false;
}

esp_err_t sa818_radio_set_frequency(sa818_radio_handle_t handle, float tx_freq_mhz, float rx_freq_mhz)
{
    if (!handle || tx_freq_mhz <= 0.0f || rx_freq_mhz <= 0.0f) {
        return ESP_ERR_INVALID_ARG;
    }

    handle->tx_freq_mhz = tx_freq_mhz;
    handle->rx_freq_mhz = rx_freq_mhz;

    if (!handle->powered) {
        return ESP_OK;
    }
    return sa818_radio_apply_group(handle);
}

esp_err_t sa818_radio_get_frequency(sa818_radio_handle_t handle, float *tx_freq_mhz, float *rx_freq_mhz)
{
    if (!handle || !tx_freq_mhz || !rx_freq_mhz) {
        return ESP_ERR_INVALID_ARG;
    }

    *tx_freq_mhz = handle->tx_freq_mhz;
    *rx_freq_mhz = handle->rx_freq_mhz;
    return ESP_OK;
}

esp_err_t sa818_radio_set_squelch(sa818_radio_handle_t handle, uint8_t squelch)
{
    if (!handle) {
        return ESP_ERR_INVALID_ARG;
    }
    if (squelch > 8) {
        squelch = 8;
    }

    handle->squelch = squelch;
    if (!handle->powered) {
        return ESP_OK;
    }
    return sa818_radio_apply_group(handle);
}

esp_err_t sa818_radio_get_squelch(sa818_radio_handle_t handle, uint8_t *squelch)
{
    if (!handle || !squelch) {
        return ESP_ERR_INVALID_ARG;
    }

    *squelch = handle->squelch;
    return ESP_OK;
}

esp_err_t sa818_radio_get_squelch_state(sa818_radio_handle_t handle, bool *squelched)
{
    if (!handle || !squelched) {
        return ESP_ERR_INVALID_ARG;
    }
    if (handle->cfg.squelch_pin < 0) {
        return ESP_ERR_NOT_SUPPORTED;
    }

    int level = gpio_get_level((gpio_num_t)handle->cfg.squelch_pin);
    *squelched = (level != 0);
    return ESP_OK;
}

esp_err_t sa818_radio_start_audio_rx(sa818_radio_handle_t handle,
                                     sa818_radio_audio_rx_cb_t callback,
                                     void *user_ctx)
{
    if (!handle) {
        return ESP_ERR_INVALID_ARG;
    }
    if (!handle->adc_ready) {
        return ESP_ERR_NOT_SUPPORTED;
    }
    if (handle->rx_task_running) {
        return ESP_ERR_INVALID_STATE;
    }

    aprs_decoder_init_demod(&handle->aprs_dec);

    handle->audio_rx_cb = callback;
    handle->audio_rx_ctx = user_ctx;
    handle->rx_task_running = true;

    BaseType_t ok = xTaskCreate(sa818_radio_rx_task,
                                "sa818_rx",
                                SA818_RADIO_RX_TASK_STACK,
                                handle,
                                SA818_RADIO_RX_TASK_PRIO,
                                &handle->rx_task);
    if (ok != pdPASS) {
        handle->rx_task_running = false;
        handle->rx_task = NULL;
        return ESP_FAIL;
    }

    return ESP_OK;
}

esp_err_t sa818_radio_stop_audio_rx(sa818_radio_handle_t handle)
{
    if (!handle) {
        return ESP_ERR_INVALID_ARG;
    }
    if (!handle->rx_task_running) {
        return ESP_OK;
    }

    handle->rx_task_running = false;

    for (int i = 0; i < 50; i++) {
        if (handle->rx_task == NULL) {
            break;
        }
        vTaskDelay(pdMS_TO_TICKS(10));
    }

    if (handle->rx_task != NULL) {
        vTaskDelete(handle->rx_task);
        handle->rx_task = NULL;
    }

    handle->audio_rx_cb = NULL;
    handle->audio_rx_ctx = NULL;
    return ESP_OK;
}

bool sa818_radio_is_audio_rx_running(sa818_radio_handle_t handle)
{
    return handle ? handle->rx_task_running : false;
}

esp_err_t sa818_radio_set_aprs_frequency(sa818_radio_handle_t handle, float aprs_freq_mhz)
{
    if (!handle || aprs_freq_mhz <= 0.0f) {
        return ESP_ERR_INVALID_ARG;
    }

    handle->aprs_freq_mhz = aprs_freq_mhz;
    return sa818_radio_set_frequency(handle, aprs_freq_mhz, aprs_freq_mhz);
}

float sa818_radio_get_aprs_frequency(sa818_radio_handle_t handle)
{
    return handle ? handle->aprs_freq_mhz : 0.0f;
}

bool sa818_radio_is_aprs_tx_supported(sa818_radio_handle_t handle)
{
    if (!handle) {
        return false;
    }

    bool supported = false;
#if SOC_DAC_SUPPORTED
    supported = handle->dac_ready;
#endif
#if CONFIG_IDF_TARGET_ESP32
    supported = supported || handle->i2s_tx_ready;
#endif
    return supported;
}

bool sa818_radio_is_aprs_tx_i2s(sa818_radio_handle_t handle)
{
#if CONFIG_IDF_TARGET_ESP32
    return handle ? handle->i2s_tx_ready : false;
#else
    (void)handle;
    return false;
#endif
}

esp_err_t sa818_radio_set_aprs_rx_callback(sa818_radio_handle_t handle,
                                           sa818_aprs_rx_cb_t callback,
                                           void *user_ctx)
{
    if (!handle) {
        return ESP_ERR_INVALID_ARG;
    }

    handle->aprs_rx_cb = callback;
    handle->aprs_rx_ctx = user_ctx;
    return ESP_OK;
}

esp_err_t sa818_radio_send_aprs_message(sa818_radio_handle_t handle,
                                        const char *from_callsign,
                                        const char *to_callsign,
                                        const char *message_text)
{
    if (!handle || !from_callsign || !to_callsign || !message_text) {
        return ESP_ERR_INVALID_ARG;
    }
    if (!sa818_radio_is_aprs_tx_supported(handle)) {
        return ESP_ERR_NOT_SUPPORTED;
    }

    if (!handle->powered) {
        esp_err_t ret = sa818_radio_power(handle, true);
        if (ret != ESP_OK) {
            return ret;
        }
    }

    uint8_t frame[APRS_MAX_FRAME_BYTES];
    size_t frame_len = 0;
    uint16_t message_seq = handle->aprs_message_seq;
    handle->aprs_message_seq = (uint16_t)((handle->aprs_message_seq + 1U) % (APRS_MAX_MESSAGE_SEQ + 1U));
    esp_err_t ret = build_aprs_message_frame(from_callsign, to_callsign, message_text, message_seq,
                                             frame, sizeof(frame), &frame_len);
    if (ret != ESP_OK) {
        return ret;
    }

    ret = sa818_radio_set_frequency(handle, handle->aprs_freq_mhz, handle->aprs_freq_mhz);
    if (ret != ESP_OK) {
        return ret;
    }

#if CONFIG_IDF_TARGET_ESP32
    if (handle->i2s_tx_ready) {
        i2s_zero_dma_buffer(I2S_NUM_0);
    }
#endif

    ESP_LOGI(TAG, "APRS TX backend: %s",
             sa818_radio_is_aprs_tx_i2s(handle) ? "I2S+DAC" : "DAC oneshot");

    ret = sa818_radio_set_ptt(handle, true);
    if (ret != ESP_OK) {
        return ret;
    }

    vTaskDelay(pdMS_TO_TICKS(APRS_TX_LEAD_MS));

    bool mark_state = true;
    aprs_tx_stream_t stream;
    aprs_tx_stream_init(handle, &stream);

    for (size_t i = 0; i < APRS_PREAMBLE_FLAGS; i++) {
        ret = aprs_tx_flag(handle, &mark_state, &stream);
        if (ret != ESP_OK) {
            break;
        }
    }

    if (ret == ESP_OK) {
        ret = aprs_tx_data_with_stuffing(handle, frame, frame_len, &mark_state, &stream);
    }

    if (ret == ESP_OK) {
        for (size_t i = 0; i < APRS_TAIL_FLAGS; i++) {
            ret = aprs_tx_flag(handle, &mark_state, &stream);
            if (ret != ESP_OK) {
                break;
            }
        }
    }

    if (ret == ESP_OK) {
        ret = aprs_tx_stream_flush(handle, &stream);
    }

#if CONFIG_IDF_TARGET_ESP32
    if (ret == ESP_OK && handle->i2s_tx_ready) {
        uint16_t zeros[APRS_I2S_TX_BLOCK_SAMPLES];
        memset(zeros, 0, sizeof(zeros));
        for (int i = 0; i < 4; i++) {
            size_t bytes_written = 0;
            esp_err_t wr = i2s_write(I2S_NUM_0,
                                     (const char *)zeros,
                                     sizeof(zeros),
                                     &bytes_written,
                                     portMAX_DELAY);
            if (wr != ESP_OK) {
                ret = wr;
                break;
            }
        }
    }
    if (handle->i2s_tx_ready) {
        ESP_LOGI(TAG, "APRS TX I2S bytes written: %u", (unsigned)stream.i2s_bytes_written);
    }
#endif

#if SOC_DAC_SUPPORTED
    if (handle->dac_ready) {
        dac_oneshot_output_voltage(handle->dac_handle, 128);
    }
#endif
    vTaskDelay(pdMS_TO_TICKS(APRS_TX_TAIL_MS));
    sa818_radio_set_ptt(handle, false);

    return ret;
}
