#ifndef MODEL_CONFIG_H
#define MODEL_CONFIG_H

#include "driver/gpio.h"

// ============================================================================
// Board Identification
// ============================================================================
#define MODEL_NAME                  "KV4P-HT"
#define MODEL_VARIANT               "ESP32-WROOM-32"

// ============================================================================
// Feature Flags - barebones profile (aligned with ESP32-C3 Mini flow)
// ============================================================================
#ifndef HAS_DISPLAY
#define HAS_DISPLAY                 0
#endif

#ifndef HAS_EPAPER_DISPLAY
#define HAS_EPAPER_DISPLAY          0
#endif

#ifndef HAS_RTC
#define HAS_RTC                     0
#endif

#ifndef HAS_HUMIDITY_SENSOR
#define HAS_HUMIDITY_SENSOR         0
#endif

#ifndef HAS_PSRAM
#define HAS_PSRAM                   0
#endif

#ifndef HAS_SDCARD
#define HAS_SDCARD                  0
#endif

#ifndef HAS_LED
#define HAS_LED                     0
#endif

#define HAS_SA818                   1

// ============================================================================
// KV4P GPIO Defaults (from kv4p-ht reference firmware)
// ============================================================================
// NeoPixel data pin used for status LED (WS2812)
#define LED_PIN                     GPIO_NUM_13

// Boot button
#define BTN_PIN_BOOT                GPIO_NUM_0
#define BTN_ACTIVE_LEVEL            0

// Optional future I2C usage
#define I2C_PIN_SDA                 GPIO_NUM_21
#define I2C_PIN_SCL                 GPIO_NUM_22

// SA818 interface
#define SA818_UART_PORT             2
#define SA818_PIN_RF_TXD            GPIO_NUM_17
#define SA818_PIN_RF_RXD            GPIO_NUM_16
#define SA818_UART_BAUD_RATE        9600

#define SA818_PIN_PTT               GPIO_NUM_18
#define SA818_PIN_PD                GPIO_NUM_19
#define SA818_PIN_HL                (-1)  // Optional, unused on default KV4P wiring

// Extra KV4P references for next iterations
#define SA818_PIN_SQ                GPIO_NUM_32
#define SA818_PIN_AUDIO_OUT         GPIO_NUM_26
#define SA818_PIN_AUDIO_IN          GPIO_NUM_34
#define SA818_PIN_PHYS_PTT1         GPIO_NUM_5
#define SA818_PIN_PHYS_PTT2         GPIO_NUM_33
#define SA818_VOLUME_DEFAULT        8
#define SA818_SQUELCH_DEFAULT       0     // APRS needs open squelch; CRC handles noise rejection
#define SA818_BANDWIDTH_DEFAULT     1     // 0=narrow, 1=wide
#define SA818_APRS_FREQ_DEFAULT_MHZ 144.800f

#endif // MODEL_CONFIG_H
