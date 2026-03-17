#ifndef APP_CONFIG_H
#define APP_CONFIG_H

// Application version
#ifndef GEOGRAM_VERSION
#define GEOGRAM_VERSION "1.0.0"
#endif

// Board model definitions
#define MODEL_ESP32S3_EPAPER_1IN54  1
#define MODEL_ESP32C3_MINI          2
#define MODEL_HELTEC_V3             3
#define MODEL_HELTEC_V2             4
#define MODEL_HELTEC_V1             5
#define MODEL_KV4P                  6
#define MODEL_TDONGLE_S3            7
#define MODEL_ESP32_GENERIC         99

// Validate board model is defined
#ifndef BOARD_MODEL
#error "BOARD_MODEL must be defined!"
#endif

// Board name fallback
#ifndef BOARD_NAME
#define BOARD_NAME "Unknown Board"
#endif

#endif // APP_CONFIG_H
