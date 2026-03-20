if(CONFIG_GEOGRAM_BOARD_TDONGLE_S3)
    idf_component_register(
        SRCS "model_init.c"
        INCLUDE_DIRS "."
        REQUIRES log nvs_flash geogram_st7735
    )
else()
    # Empty component for other boards
    idf_component_register()
endif()
