idf_component_register(
    SRCS "ble_client.c"
    INCLUDE_DIRS "."
    REQUIRES log bt nvs_flash json geogram_station geogram_nostr geoblue
)
