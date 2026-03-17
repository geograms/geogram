# This file was automatically generated for projects
# without default 'CMakeLists.txt' file.

FILE(GLOB_RECURSE app_sources ${CMAKE_SOURCE_DIR}/src/*.*)

set(APP_REQUIRES geogram_ble geogram_ble_aprs)

# FTP only on ePaper board (has SD card)
if(CONFIG_GEOGRAM_BOARD_EPAPER_1IN54)
    list(APPEND APP_REQUIRES geogram_ftp)
endif()

idf_component_register(
    SRCS ${app_sources}
    REQUIRES ${APP_REQUIRES}
)
