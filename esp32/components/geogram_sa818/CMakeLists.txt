if("${IDF_TARGET}" STREQUAL "esp32")
    idf_component_register(
        SRCS "sa818.c" "sa818_radio.c"
        INCLUDE_DIRS "."
        REQUIRES driver log esp_timer esp_adc
        PRIV_REQUIRES freertos
    )
else()
    idf_component_register()
endif()
