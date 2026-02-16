#ifndef GEOBLUE_H
#define GEOBLUE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    GEOBLUE_FRAME_UNKNOWN = 0,
    GEOBLUE_FRAME_HELLO,
    GEOBLUE_FRAME_HELLO_ACK,
    GEOBLUE_FRAME_DATA,
    GEOBLUE_FRAME_BROADCAST,
    GEOBLUE_FRAME_ERROR,
} geoblue_frame_type_t;

const char *geoblue_frame_type_name(geoblue_frame_type_t type);
geoblue_frame_type_t geoblue_frame_type_from_name(const char *name);

/**
 * @brief Build a geoblue HELLO frame JSON string.
 *
 * Caller owns the returned heap string and must free it.
 */
char *geoblue_build_hello_frame(const char *id,
                                const char *callsign,
                                const char *npub,
                                const char *board,
                                const char **capabilities,
                                size_t capability_count);

/**
 * @brief Build a geoblue HELLO_ACK frame JSON string.
 *
 * Caller owns the returned heap string and must free it.
 */
char *geoblue_build_hello_ack_frame(const char *id,
                                    bool success,
                                    const char *callsign,
                                    const char *npub,
                                    const char *board,
                                    const char **capabilities,
                                    size_t capability_count,
                                    const char *message);

/**
 * @brief Build a geoblue DATA frame JSON string.
 *
 * Caller owns the returned heap string and must free it.
 */
char *geoblue_build_data_frame(const char *id,
                               const char *from,
                               const char *to,
                               const char *channel,
                               const char *content,
                               int64_t timestamp);

/**
 * @brief Build a geoblue BROADCAST frame JSON string.
 *
 * Caller owns the returned heap string and must free it.
 */
char *geoblue_build_broadcast_frame(const char *id,
                                    const char *from,
                                    const char *topic,
                                    const char *content,
                                    int64_t timestamp);

/**
 * @brief Locate one complete JSON object in a byte stream.
 *
 * This parser supports concatenated JSON objects and partial chunks.
 */
bool geoblue_find_json_object_bounds(const uint8_t *buffer,
                                     size_t len,
                                     size_t *json_start,
                                     size_t *json_end,
                                     size_t *discard_prefix,
                                     bool *incomplete);

#ifdef __cplusplus
}
#endif

#endif // GEOBLUE_H
