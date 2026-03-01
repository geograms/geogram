if(CONFIG_GEOGRAM_BOARD_KV4P)
    idf_component_register(
        SRCS "model_init.c"
        INCLUDE_DIRS "."
        REQUIRES driver log nvs_flash geogram_sa818 geogram_aprs
        PRIV_REQUIRES freertos
    )
else()
    idf_component_register()
endif()
