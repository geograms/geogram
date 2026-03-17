# Only build for ePaper board (which has this humidity sensor)
if(CONFIG_GEOGRAM_BOARD_EPAPER_1IN54)
    idf_component_register(
        SRCS "shtc3.cpp"
        INCLUDE_DIRS "."
        REQUIRES geogram_i2c log
        PRIV_REQUIRES freertos
    )
else()
    # Register empty component for non-ESP32S3 targets
    idf_component_register()
endif()
