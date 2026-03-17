# Only build for ePaper board
if(CONFIG_GEOGRAM_BOARD_EPAPER_1IN54)
    idf_component_register(
        SRCS "epaper_1in54.cpp"
        INCLUDE_DIRS "."
        REQUIRES driver log
        PRIV_REQUIRES heap freertos
    )
else()
    # Register empty component for non-ESP32S3 targets
    idf_component_register()
endif()
