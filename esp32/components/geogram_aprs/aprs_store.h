/**
 * @file aprs_store.h
 * @brief APRS message store with circular buffer and beacon deduplication
 *
 * Provides storage for received and transmitted APRS messages, independent
 * from mesh_chat. Designed for the KV4P board's SA818 radio with full
 * APRS TX/RX stack.
 */

#ifndef GEOGRAM_APRS_STORE_H
#define GEOGRAM_APRS_STORE_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

#define APRS_STORE_MAX_MESSAGES  128
#define APRS_MAX_CALLSIGN_LEN   10
#define APRS_MAX_MESSAGE_LEN    68
#define APRS_MAX_RAW_LEN        128   /**< TNC2 raw frame (from>to,path:info) */

typedef struct {
    uint32_t id;               /**< Monotonic counter (never resets) */
    uint32_t timestamp;        /**< Unix epoch seconds */
    char from[APRS_MAX_CALLSIGN_LEN];
    char to[APRS_MAX_CALLSIGN_LEN];
    char message[APRS_MAX_MESSAGE_LEN];
    char raw[APRS_MAX_RAW_LEN];  /**< Original TNC2 frame (RX only) */
    bool is_beacon;            /**< True if this is a repeated beacon */
    uint32_t beacon_count;     /**< Times this beacon was seen */
    uint32_t last_seen;        /**< Last time beacon was updated (timestamp) */
    bool is_outgoing;          /**< True if sent by us */
} aprs_message_t;

/**
 * @brief Initialize the APRS message store
 * @return ESP_OK on success
 */
esp_err_t aprs_store_init(void);

/**
 * @brief Add a received APRS message to the store
 * Handles beacon deduplication automatically.
 */
void aprs_store_add_rx(const char *from, const char *to,
                       const char *message, const char *raw_tnc2);

/**
 * @brief Add a transmitted APRS message to the store
 */
void aprs_store_add_tx(const char *from, const char *to, const char *message);

/**
 * @brief Get messages with id > since_id
 * @param out Output array
 * @param max Maximum messages to return
 * @param since_id Only return messages with id > since_id (0 for all)
 * @return Number of messages returned
 */
size_t aprs_store_get_messages(aprs_message_t *out, size_t max, uint32_t since_id);

/**
 * @brief Get the latest message ID
 * @return Latest message ID (0 if no messages)
 */
uint32_t aprs_store_get_latest_id(void);

/**
 * @brief Get total message count in store
 */
size_t aprs_store_get_count(void);

/**
 * @brief Build JSON response for APRS messages
 * @param buffer Output buffer
 * @param size Buffer size
 * @param since_id Only include messages with id > since_id
 * @return Number of bytes written
 */
size_t aprs_store_build_json(char *buffer, size_t size, uint32_t since_id);

/**
 * @brief APRS RX callback — register with sa818_radio_set_aprs_rx_callback()
 */
void aprs_store_rx_callback(const char *from, const char *to,
                            const char *message, const char *raw_tnc2,
                            void *ctx);

/**
 * @brief Get total number of received messages (including deduplicated beacons)
 */
uint32_t aprs_store_get_total_rx(void);

/**
 * @brief Get total number of transmitted messages
 */
uint32_t aprs_store_get_total_tx(void);

/**
 * @brief Get the epoch prefix letter (random A-Z, changes on each boot/reflash)
 */
char aprs_store_get_epoch(void);

/**
 * @brief Parse a prefixed ID string (e.g. "K5") into epoch char and numeric id.
 * @param str    Input string like "K5" or "5"
 * @param epoch  Output epoch character (or '\0' if none)
 * @param id     Output numeric id
 */
void aprs_store_parse_id(const char *str, char *epoch, uint32_t *id);

/**
 * @brief Callback fired after each RX message is stored
 */
typedef void (*aprs_store_rx_notify_cb_t)(const char *from, const char *to,
                                           const char *message, void *ctx);

/**
 * @brief Register an RX notification callback (e.g. for BLE push)
 */
void aprs_store_set_rx_notify(aprs_store_rx_notify_cb_t cb, void *ctx);

#ifdef __cplusplus
}
#endif

#endif // GEOGRAM_APRS_STORE_H
