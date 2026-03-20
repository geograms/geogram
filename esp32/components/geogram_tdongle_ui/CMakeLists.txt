if(CONFIG_GEOGRAM_BOARD_TDONGLE_S3)
    idf_component_register(
        SRCS "tdongle_ui.c"
        INCLUDE_DIRS "."
        REQUIRES log geogram_st7735 lvgl__lvgl esp_timer
    )
else()
    idf_component_register()
endif()
