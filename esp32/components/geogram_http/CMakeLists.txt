# Geogram HTTP server component for WiFi configuration and Station API

# Base requirements for all boards
set(HTTP_REQUIRES esp_http_server esp_https_server nvs_flash log geogram_station geogram_ws geogram_common)

# Add tiles and updates for boards with SD card support
if(CONFIG_GEOGRAM_BOARD_EPAPER_1IN54)
    list(APPEND HTTP_REQUIRES geogram_tiles geogram_updates)
endif()

# Private requirements — APRS/SA818/model_kv4p are empty stubs on non-KV4P boards
set(HTTP_PRIV_REQUIRES esp_wifi geogram_aprs geogram_sa818 geogram_model_kv4p geogram_radio_tx)

# Add mesh and nostr components on targets that support ESP-MESH
# These are used conditionally via CONFIG_GEOGRAM_MESH_ENABLED
if("${IDF_TARGET}" STREQUAL "esp32" OR "${IDF_TARGET}" STREQUAL "esp32s2" OR "${IDF_TARGET}" STREQUAL "esp32s3" OR "${IDF_TARGET}" STREQUAL "esp32c3")
    list(APPEND HTTP_PRIV_REQUIRES geogram_mesh geogram_nostr)
endif()

idf_component_register(
    SRCS "http_server.c" "chat_page.c"
    INCLUDE_DIRS "."
    REQUIRES ${HTTP_REQUIRES}
    PRIV_REQUIRES ${HTTP_PRIV_REQUIRES}
)
