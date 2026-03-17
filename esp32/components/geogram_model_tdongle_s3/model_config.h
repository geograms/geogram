#ifndef GEOGRAM_MODEL_TDONGLE_S3_CONFIG_H
#define GEOGRAM_MODEL_TDONGLE_S3_CONFIG_H

// Board identification
#define MODEL_NAME    "T-Dongle-S3"
#define MODEL_VARIANT "LILYGO ESP32-S3 USB Dongle"

// Feature flags
#ifndef HAS_DISPLAY
#define HAS_DISPLAY           0
#endif
#ifndef HAS_EPAPER_DISPLAY
#define HAS_EPAPER_DISPLAY    0
#endif
#ifndef HAS_RTC
#define HAS_RTC               0
#endif
#ifndef HAS_HUMIDITY_SENSOR
#define HAS_HUMIDITY_SENSOR   0
#endif
#ifndef HAS_PSRAM
#define HAS_PSRAM             0
#endif
#ifndef HAS_SDCARD
#define HAS_SDCARD            0
#endif
#ifndef HAS_LED
#define HAS_LED               0
#endif

#endif // GEOGRAM_MODEL_TDONGLE_S3_CONFIG_H
