idf_component_register(
    SRCS "radio_tx.c"
    INCLUDE_DIRS "."
    REQUIRES log
    PRIV_REQUIRES freertos
)
