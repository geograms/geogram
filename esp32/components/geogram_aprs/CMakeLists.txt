# Geogram APRS message store component
# Provides circular buffer storage and beacon deduplication for APRS messages
# Always compiled; only used on KV4P board at runtime

idf_component_register(
    SRCS "aprs_store.c"
    INCLUDE_DIRS "."
    REQUIRES log
    PRIV_REQUIRES freertos geogram_mesh
)
