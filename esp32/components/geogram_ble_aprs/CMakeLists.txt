idf_component_register(
    SRCS "ble_aprs.c"
    INCLUDE_DIRS "."
    REQUIRES log bt
    PRIV_REQUIRES freertos
)
