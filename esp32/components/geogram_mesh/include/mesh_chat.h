/**
 * @file mesh_chat.h
 * @brief Mesh chat messaging system
 *
 * Provides a simple chat system for sending text messages between
 * mesh nodes. Messages are broadcast to all nodes and stored in
 * a circular buffer for retrieval by web clients.
 */

#ifndef GEOGRAM_MESH_CHAT_H
#define GEOGRAM_MESH_CHAT_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Maximum chat message text length (bytes)
 *
 * This limit ensures messages fit in a single mesh packet with room
 * for headers. ESP-MESH supports ~1460 bytes per packet.
 */
#define MESH_CHAT_MAX_MESSAGE_LEN   200

/**
 * @brief Maximum callsign length
 */
#define MESH_CHAT_MAX_CALLSIGN_LEN  16

/**
 * @brief Number of messages to keep in history
 */
#define MESH_CHAT_HISTORY_SIZE      100

/**
 * @brief Maximum filename length for file messages
 */
#define MESH_CHAT_MAX_FILENAME_LEN  64

/**
 * @brief Maximum MIME type length
 */
#define MESH_CHAT_MAX_MIME_LEN      32

/**
 * @brief Message types
 */
typedef enum {
    MESH_CHAT_MSG_TEXT = 0,   /**< Regular text message */
    MESH_CHAT_MSG_FILE = 1    /**< File metadata message */
} mesh_chat_msg_type_t;

/**
 * @brief Channel bitmask — how a message entered/left the system
 */
#define MESH_CHAT_CH_WIFI  (1 << 0)  // 0x01
#define MESH_CHAT_CH_BLE   (1 << 1)  // 0x02
#define MESH_CHAT_CH_MESH  (1 << 2)  // 0x04
#define MESH_CHAT_CH_APRS  (1 << 3)  // 0x08
#define MESH_CHAT_CH_LORA  (1 << 4)  // 0x10

/**
 * @brief File metadata for file messages
 */
typedef struct {
    uint8_t sha1[20];                              /**< SHA1 hash of file content */
    uint32_t size;                                 /**< File size in bytes */
    char filename[MESH_CHAT_MAX_FILENAME_LEN];    /**< Original filename */
    char mime_type[MESH_CHAT_MAX_MIME_LEN];       /**< MIME type (e.g., "image/jpeg") */
} mesh_chat_file_info_t;

/**
 * @brief Chat message structure
 */
typedef struct {
    uint32_t id;                                    /**< Unique message ID */
    uint32_t timestamp;                             /**< Unix timestamp (seconds) */
    char callsign[MESH_CHAT_MAX_CALLSIGN_LEN];     /**< Sender callsign */
    char text[MESH_CHAT_MAX_MESSAGE_LEN + 1];      /**< Message text */
    uint8_t sender_mac[6];                          /**< Sender MAC address */
    bool is_local;                                  /**< True if sent from this node */
    mesh_chat_msg_type_t msg_type;                 /**< Message type (text/file) */
    uint8_t channels;                              /**< Channel bitmask (MESH_CHAT_CH_*) */
    mesh_chat_file_info_t file;                    /**< File info (only if msg_type==FILE) */
} mesh_chat_message_t;

/**
 * @brief Callback for new chat messages
 * @param msg The received message
 */
typedef void (*mesh_chat_callback_t)(const mesh_chat_message_t *msg);

/**
 * @brief Initialize chat system
 * @return ESP_OK on success
 */
esp_err_t mesh_chat_init(void);

/**
 * @brief Deinitialize chat system
 */
void mesh_chat_deinit(void);

/**
 * @brief Send a chat message to all mesh nodes
 * @param text Message text (max MESH_CHAT_MAX_MESSAGE_LEN chars)
 * @return ESP_OK on success
 */
esp_err_t mesh_chat_send(const char *text);

/**
 * @brief Add a local-only chat message with a custom callsign
 * @param callsign Sender callsign (NULL or empty uses a default)
 * @param text Message text (max MESH_CHAT_MAX_MESSAGE_LEN chars)
 * @return ESP_OK on success
 */
esp_err_t mesh_chat_add_local_message(const char *callsign, const char *text, uint8_t channels);
/**
 * @brief Add a local-only chat message with a custom callsign and timestamp
 * @param callsign Sender callsign (optional)
 * @param text Message text
 * @param timestamp Unix timestamp (seconds). If 0, current device time is used.
 */
esp_err_t mesh_chat_add_local_message_with_timestamp(const char *callsign,
                                                     const char *text,
                                                     uint32_t timestamp,
                                                     uint8_t channels);

/**
 * @brief Add a local-only file metadata message with a custom callsign
 * @param callsign Sender callsign (optional)
 * @param text Optional caption text
 * @param sha1 SHA1 hash bytes (20 bytes)
 * @param size File size in bytes
 * @param filename File name (optional)
 * @param mime_type MIME type (optional)
 */
esp_err_t mesh_chat_add_local_file_message(const char *callsign,
                                           const char *text,
                                           const uint8_t *sha1,
                                           uint32_t size,
                                           const char *filename,
                                           const char *mime_type,
                                           uint8_t channels);

/**
 * @brief Send a file message to all mesh nodes
 * @param text Optional caption/description text
 * @param sha1 SHA1 hash of file content (20 bytes)
 * @param filename Original filename
 * @param size File size in bytes
 * @param mime_type MIME type string
 * @return ESP_OK on success
 */
esp_err_t mesh_chat_send_file(const char *text, const uint8_t *sha1,
                               const char *filename, uint32_t size,
                               const char *mime_type);

/**
 * @brief Get chat message history
 * @param messages Array to fill with messages
 * @param max_messages Maximum messages to return
 * @param since_id Only return messages with ID > since_id (0 for all)
 * @return Number of messages returned
 */
size_t mesh_chat_get_history(mesh_chat_message_t *messages, size_t max_messages, uint32_t since_id);

/**
 * @brief Get the latest message ID
 * @return Latest message ID (0 if no messages)
 */
uint32_t mesh_chat_get_latest_id(void);

/**
 * @brief Get total message count in history
 * @return Number of messages
 */
size_t mesh_chat_get_count(void);

/**
 * @brief Register callback for new messages
 * @param callback Function to call when message received
 */
void mesh_chat_register_callback(mesh_chat_callback_t callback);

/**
 * @brief Build JSON array of chat messages
 * @param buffer Output buffer
 * @param size Buffer size
 * @param since_id Only include messages with ID > since_id
 * @return Number of bytes written
 */
size_t mesh_chat_build_json(char *buffer, size_t size, uint32_t since_id);

/**
 * @brief Internal: Handle incoming mesh chat packet
 * Called by mesh data receive callback
 */
void mesh_chat_handle_packet(const uint8_t *src_mac, const void *data, size_t len);

#ifdef __cplusplus
}
#endif

#endif // GEOGRAM_MESH_CHAT_H
