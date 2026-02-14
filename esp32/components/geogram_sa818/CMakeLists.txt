if("${IDF_TARGET}" STREQUAL "esp32" OR "${IDF_TARGET}" STREQUAL "esp32s2" OR "${IDF_TARGET}" STREQUAL "esp32s3" OR "${IDF_TARGET}" STREQUAL "esp32c3")
    idf_component_register(
        SRCS "sa818.c"
        INCLUDE_DIRS "."
        REQUIRES driver log esp_timer
        PRIV_REQUIRES freertos
    )
else()
    idf_component_register()
endif()
