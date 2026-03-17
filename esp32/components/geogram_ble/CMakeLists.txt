idf_component_register(
    SRCS "geogram_ble.c"
    INCLUDE_DIRS "."
    REQUIRES log bt nvs_flash json geogram_station geogram_mesh geogram_nostr geoblue
    PRIV_REQUIRES geogram_aprs geogram_radio_tx
)
