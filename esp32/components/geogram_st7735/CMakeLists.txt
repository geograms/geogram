if(CONFIG_GEOGRAM_BOARD_TDONGLE_S3)
    idf_component_register(
        SRCS "st7735.c"
        INCLUDE_DIRS "."
        REQUIRES driver log
        PRIV_REQUIRES freertos
    )
else()
    idf_component_register()
endif()
