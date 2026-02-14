if(CONFIG_GEOGRAM_BOARD_HELTEC_V1 OR CONFIG_GEOGRAM_BOARD_HELTEC_V2 OR CONFIG_GEOGRAM_BOARD_HELTEC_V3)
    idf_component_register(
        SRCS "ssd1306.c"
        INCLUDE_DIRS "."
        REQUIRES driver log geogram_i2c
        PRIV_REQUIRES freertos
    )
else()
    idf_component_register()
endif()
