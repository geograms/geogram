idf_component_register(
    SRCS "ble_hello.c"
    INCLUDE_DIRS "."
    REQUIRES log bt nvs_flash json esp_timer
)
