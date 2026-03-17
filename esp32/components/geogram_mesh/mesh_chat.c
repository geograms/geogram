/**
 * @file mesh_chat.c
 * @brief Mesh chat messaging system implementation
 */

#include "mesh_chat.h"
#include "mesh_bsp.h"

#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <time.h>
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_timer.h"
#include "esp_wifi.h"

// LED notification for incoming chat messages (ESP32-C3)
#if CONFIG_IDF_TARGET_ESP32C3
#include "led_bsp.h"
#endif

static const char *TAG = "mesh_chat";

// ============================================================================
// Protocol Constants
// ============================================================================

#define CHAT_MSG_MAGIC      0x43484154  // "CHAT"
#define CHAT_MSG_VERSION    2           // v2 adds file message support

// ============================================================================
// Wire Protocol
// ============================================================================

typedef struct __attribute__((packed)) {
    uint32_t magic;                                 // CHAT_MSG_MAGIC
    uint8_t version;                                // Protocol version
    uint8_t msg_type;                               // 0=text, 1=file
    uint16_t text_len;                              // Text length
    uint32_t msg_id;                                // Message ID (from sender)
    uint32_t timestamp;                             // Unix timestamp
    char callsign[MESH_CHAT_MAX_CALLSIGN_LEN];     // Sender callsign
    // File fields (only valid if msg_type == 1)
    uint8_t sha1[20];                               // SHA1 hash
    uint32_t file_size;                             // File size in bytes
    char filename[MESH_CHAT_MAX_FILENAME_LEN];     // Filename
    char mime_type[MESH_CHAT_MAX_MIME_LEN];        // MIME type
    // Variable length text follows
    char text[];                                    // Message text (variable)
} chat_wire_msg_t;

// ============================================================================
// State
// ============================================================================

static bool s_initialized = false;
static SemaphoreHandle_t s_mutex = NULL;
static mesh_chat_message_t s_history[MESH_CHAT_HISTORY_SIZE];
static size_t s_history_head = 0;  // Next write position
static size_t s_history_count = 0;
static uint32_t s_next_msg_id = 1;
static mesh_chat_callback_t s_callback = NULL;
static uint8_t s_local_mac[6] = {0};

// ============================================================================
// Forward Declarations
// ============================================================================

static void add_message_to_history(const mesh_chat_message_t *msg);
static uint32_t get_timestamp(void);

// ============================================================================
// Initialization
// ============================================================================

esp_err_t mesh_chat_init(void)
{
    if (s_initialized) {
        return ESP_OK;
    }

    ESP_LOGI(TAG, "Initializing mesh chat system");
    ESP_LOGI(TAG, "Max message length: %d characters", MESH_CHAT_MAX_MESSAGE_LEN);
    ESP_LOGI(TAG, "History size: %d messages", MESH_CHAT_HISTORY_SIZE);

    // Create mutex
    s_mutex = xSemaphoreCreateMutex();
    if (!s_mutex) {
        ESP_LOGE(TAG, "Failed to create mutex");
        return ESP_ERR_NO_MEM;
    }

    // Clear history
    memset(s_history, 0, sizeof(s_history));
    s_history_head = 0;
    s_history_count = 0;
    s_next_msg_id = 1;

    // Get local MAC address
    esp_wifi_get_mac(WIFI_IF_STA, s_local_mac);

    s_initialized = true;
    ESP_LOGI(TAG, "Mesh chat initialized");

    return ESP_OK;
}

void mesh_chat_deinit(void)
{
    if (!s_initialized) {
        return;
    }

    if (s_mutex) {
        vSemaphoreDelete(s_mutex);
        s_mutex = NULL;
    }

    s_initialized = false;
    ESP_LOGI(TAG, "Mesh chat deinitialized");
}

// ============================================================================
// Send Message
// ============================================================================

esp_err_t mesh_chat_send(const char *text)
{
    if (!s_initialized) {
        ESP_LOGE(TAG, "Chat not initialized");
        return ESP_ERR_INVALID_STATE;
    }

    if (!text || strlen(text) == 0) {
        return ESP_ERR_INVALID_ARG;
    }

    size_t text_len = strlen(text);
    if (text_len > MESH_CHAT_MAX_MESSAGE_LEN) {
        ESP_LOGW(TAG, "Message too long (%zu > %d), truncating",
                 text_len, MESH_CHAT_MAX_MESSAGE_LEN);
        text_len = MESH_CHAT_MAX_MESSAGE_LEN;
    }

    // Get local callsign
    extern const char *nostr_keys_get_callsign(void);
    const char *callsign = nostr_keys_get_callsign();
    if (!callsign || strlen(callsign) == 0) {
        callsign = "UNKNOWN";
    }

    // Build wire message
    size_t wire_len = sizeof(chat_wire_msg_t) + text_len + 1;
    chat_wire_msg_t *wire_msg = malloc(wire_len);
    if (!wire_msg) {
        return ESP_ERR_NO_MEM;
    }

    memset(wire_msg, 0, sizeof(chat_wire_msg_t));
    wire_msg->magic = CHAT_MSG_MAGIC;
    wire_msg->version = CHAT_MSG_VERSION;
    wire_msg->msg_type = MESH_CHAT_MSG_TEXT;
    wire_msg->text_len = (uint16_t)text_len;
    wire_msg->timestamp = get_timestamp();

    xSemaphoreTake(s_mutex, portMAX_DELAY);
    wire_msg->msg_id = s_next_msg_id++;
    xSemaphoreGive(s_mutex);

    strncpy(wire_msg->callsign, callsign, MESH_CHAT_MAX_CALLSIGN_LEN - 1);
    memcpy(wire_msg->text, text, text_len);
    wire_msg->text[text_len] = '\0';

    ESP_LOGI(TAG, "[CHAT TX] Sending message #%lu: \"%.*s\"",
             (unsigned long)wire_msg->msg_id, (int)text_len, text);

    // Add to local history first
    mesh_chat_message_t local_msg = {
        .id = wire_msg->msg_id,
        .timestamp = wire_msg->timestamp,
        .is_local = true,
        .msg_type = MESH_CHAT_MSG_TEXT,
        .channels = MESH_CHAT_CH_WIFI
    };
    memset(&local_msg.file, 0, sizeof(local_msg.file));
    strncpy(local_msg.callsign, callsign, MESH_CHAT_MAX_CALLSIGN_LEN - 1);
    strncpy(local_msg.text, text, MESH_CHAT_MAX_MESSAGE_LEN);
    memcpy(local_msg.sender_mac, s_local_mac, 6);

    // Broadcast to all mesh nodes
    if (geogram_mesh_is_connected()) {
        // Get all nodes and send to each
        geogram_mesh_node_t nodes[20];
        size_t node_count = 0;
        geogram_mesh_get_nodes(nodes, 20, &node_count);

        int sent = 0;
        for (size_t i = 0; i < node_count; i++) {
            // Don't send to ourselves
            if (memcmp(nodes[i].mac, s_local_mac, 6) == 0) {
                continue;
            }

            esp_err_t ret = geogram_mesh_send_to_node(nodes[i].mac, wire_msg, wire_len);
            if (ret == ESP_OK) {
                sent++;
            } else {
                ESP_LOGW(TAG, "[CHAT TX] Failed to send to " MACSTR ": %s",
                         MAC2STR(nodes[i].mac), esp_err_to_name(ret));
            }
        }

        if (sent > 0) {
            local_msg.channels |= MESH_CHAT_CH_MESH;
        }

        ESP_LOGI(TAG, "[CHAT TX] Broadcast to %d/%zu nodes", sent, node_count);
    } else {
        ESP_LOGW(TAG, "[CHAT TX] Mesh not connected, message stored locally only");
    }

    add_message_to_history(&local_msg);

    // Notify callback
    if (s_callback) {
        s_callback(&local_msg);
    }

    free(wire_msg);
    return ESP_OK;
}

// ============================================================================
// Local-only Message (custom callsign)
// ============================================================================

esp_err_t mesh_chat_add_local_message(const char *callsign, const char *text, uint8_t channels)
{
    return mesh_chat_add_local_message_with_timestamp(callsign, text, 0, channels);
}

esp_err_t mesh_chat_add_local_message_with_timestamp(const char *callsign,
                                                     const char *text,
                                                     uint32_t timestamp,
                                                     uint8_t channels)
{
    if (!s_initialized) {
        ESP_LOGE(TAG, "Chat not initialized");
        return ESP_ERR_INVALID_STATE;
    }

    if (!text || strlen(text) == 0) {
        return ESP_ERR_INVALID_ARG;
    }

    size_t text_len = strlen(text);
    if (text_len > MESH_CHAT_MAX_MESSAGE_LEN) {
        text_len = MESH_CHAT_MAX_MESSAGE_LEN;
    }

    const char *sender = callsign && strlen(callsign) > 0 ? callsign : "GUEST";

    const uint32_t msg_timestamp = timestamp ? timestamp : get_timestamp();
    mesh_chat_message_t local_msg = {
        .timestamp = msg_timestamp,
        .is_local = true,
        .msg_type = MESH_CHAT_MSG_TEXT,
        .channels = channels
    };
    memset(&local_msg.file, 0, sizeof(local_msg.file));

    xSemaphoreTake(s_mutex, portMAX_DELAY);
    local_msg.id = s_next_msg_id++;
    xSemaphoreGive(s_mutex);

    strncpy(local_msg.callsign, sender, MESH_CHAT_MAX_CALLSIGN_LEN - 1);
    strncpy(local_msg.text, text, MESH_CHAT_MAX_MESSAGE_LEN);
    memcpy(local_msg.sender_mac, s_local_mac, 6);

    add_message_to_history(&local_msg);

    if (s_callback) {
        s_callback(&local_msg);
    }

    ESP_LOGI(TAG, "[CHAT RX] %s: %s", local_msg.callsign, local_msg.text);
    return ESP_OK;
}

esp_err_t mesh_chat_add_local_file_message(const char *callsign,
                                           const char *text,
                                           const uint8_t *sha1,
                                           uint32_t size,
                                           const char *filename,
                                           const char *mime_type,
                                           uint8_t channels)
{
    if (!s_initialized) {
        ESP_LOGE(TAG, "Chat not initialized");
        return ESP_ERR_INVALID_STATE;
    }

    if (!sha1 || size == 0) {
        return ESP_ERR_INVALID_ARG;
    }

    size_t text_len = text ? strlen(text) : 0;
    if (text_len > MESH_CHAT_MAX_MESSAGE_LEN) {
        text_len = MESH_CHAT_MAX_MESSAGE_LEN;
    }

    const char *sender = callsign && strlen(callsign) > 0 ? callsign : "GUEST";

    mesh_chat_message_t local_msg = {
        .timestamp = get_timestamp(),
        .is_local = true,
        .msg_type = MESH_CHAT_MSG_FILE,
        .channels = channels
    };
    memset(&local_msg.file, 0, sizeof(local_msg.file));

    xSemaphoreTake(s_mutex, portMAX_DELAY);
    local_msg.id = s_next_msg_id++;
    xSemaphoreGive(s_mutex);

    strncpy(local_msg.callsign, sender, MESH_CHAT_MAX_CALLSIGN_LEN - 1);
    if (text && text_len > 0) {
        memcpy(local_msg.text, text, text_len);
        local_msg.text[text_len] = '\0';
    } else {
        local_msg.text[0] = '\0';
    }
    memcpy(local_msg.sender_mac, s_local_mac, 6);

    memcpy(local_msg.file.sha1, sha1, 20);
    local_msg.file.size = size;
    if (filename) {
        strncpy(local_msg.file.filename, filename, MESH_CHAT_MAX_FILENAME_LEN - 1);
    }
    if (mime_type) {
        strncpy(local_msg.file.mime_type, mime_type, MESH_CHAT_MAX_MIME_LEN - 1);
    }

    add_message_to_history(&local_msg);

    if (s_callback) {
        s_callback(&local_msg);
    }

    return ESP_OK;
}

// ============================================================================
// Send File Message
// ============================================================================

esp_err_t mesh_chat_send_file(const char *text, const uint8_t *sha1,
                               const char *filename, uint32_t size,
                               const char *mime_type)
{
    if (!s_initialized) {
        ESP_LOGE(TAG, "Chat not initialized");
        return ESP_ERR_INVALID_STATE;
    }

    if (!sha1 || !filename || !mime_type) {
        return ESP_ERR_INVALID_ARG;
    }

    // Validate file size (100MB max)
    if (size > 100 * 1024 * 1024) {
        ESP_LOGE(TAG, "File too large: %lu bytes", (unsigned long)size);
        return ESP_ERR_INVALID_ARG;
    }

    size_t text_len = text ? strlen(text) : 0;
    if (text_len > MESH_CHAT_MAX_MESSAGE_LEN) {
        text_len = MESH_CHAT_MAX_MESSAGE_LEN;
    }

    // Get local callsign
    extern const char *nostr_keys_get_callsign(void);
    const char *callsign = nostr_keys_get_callsign();
    if (!callsign || strlen(callsign) == 0) {
        callsign = "UNKNOWN";
    }

    // Build wire message
    size_t wire_len = sizeof(chat_wire_msg_t) + text_len + 1;
    chat_wire_msg_t *wire_msg = malloc(wire_len);
    if (!wire_msg) {
        return ESP_ERR_NO_MEM;
    }

    memset(wire_msg, 0, sizeof(chat_wire_msg_t));
    wire_msg->magic = CHAT_MSG_MAGIC;
    wire_msg->version = CHAT_MSG_VERSION;
    wire_msg->msg_type = MESH_CHAT_MSG_FILE;
    wire_msg->text_len = (uint16_t)text_len;
    wire_msg->timestamp = get_timestamp();

    xSemaphoreTake(s_mutex, portMAX_DELAY);
    wire_msg->msg_id = s_next_msg_id++;
    xSemaphoreGive(s_mutex);

    strncpy(wire_msg->callsign, callsign, MESH_CHAT_MAX_CALLSIGN_LEN - 1);

    // Copy file metadata
    memcpy(wire_msg->sha1, sha1, 20);
    wire_msg->file_size = size;
    strncpy(wire_msg->filename, filename, MESH_CHAT_MAX_FILENAME_LEN - 1);
    strncpy(wire_msg->mime_type, mime_type, MESH_CHAT_MAX_MIME_LEN - 1);

    // Copy text if present
    if (text && text_len > 0) {
        memcpy(wire_msg->text, text, text_len);
    }
    wire_msg->text[text_len] = '\0';

    ESP_LOGI(TAG, "[CHAT TX] Sending file #%lu: %s (%lu bytes)",
             (unsigned long)wire_msg->msg_id, filename, (unsigned long)size);

    // Add to local history first
    mesh_chat_message_t local_msg = {
        .id = wire_msg->msg_id,
        .timestamp = wire_msg->timestamp,
        .is_local = true,
        .msg_type = MESH_CHAT_MSG_FILE,
        .channels = MESH_CHAT_CH_WIFI
    };
    strncpy(local_msg.callsign, callsign, MESH_CHAT_MAX_CALLSIGN_LEN - 1);
    if (text) {
        strncpy(local_msg.text, text, MESH_CHAT_MAX_MESSAGE_LEN);
    } else {
        local_msg.text[0] = '\0';
    }
    memcpy(local_msg.sender_mac, s_local_mac, 6);

    // Copy file info
    memcpy(local_msg.file.sha1, sha1, 20);
    local_msg.file.size = size;
    strncpy(local_msg.file.filename, filename, MESH_CHAT_MAX_FILENAME_LEN - 1);
    strncpy(local_msg.file.mime_type, mime_type, MESH_CHAT_MAX_MIME_LEN - 1);

    // Broadcast to all mesh nodes
    if (geogram_mesh_is_connected()) {
        geogram_mesh_node_t nodes[20];
        size_t node_count = 0;
        geogram_mesh_get_nodes(nodes, 20, &node_count);

        int sent = 0;
        for (size_t i = 0; i < node_count; i++) {
            if (memcmp(nodes[i].mac, s_local_mac, 6) == 0) {
                continue;
            }

            esp_err_t ret = geogram_mesh_send_to_node(nodes[i].mac, wire_msg, wire_len);
            if (ret == ESP_OK) {
                sent++;
            }
        }

        if (sent > 0) {
            local_msg.channels |= MESH_CHAT_CH_MESH;
        }

        ESP_LOGI(TAG, "[CHAT TX] File broadcast to %d/%zu nodes", sent, node_count);
    } else {
        ESP_LOGW(TAG, "[CHAT TX] Mesh not connected, file message stored locally only");
    }

    add_message_to_history(&local_msg);

    // Notify callback
    if (s_callback) {
        s_callback(&local_msg);
    }

    free(wire_msg);
    return ESP_OK;
}

// ============================================================================
// Receive Handler
// ============================================================================

void mesh_chat_handle_packet(const uint8_t *src_mac, const void *data, size_t len)
{
    if (!s_initialized || !data || len < sizeof(chat_wire_msg_t)) {
        return;
    }

    const chat_wire_msg_t *wire_msg = (const chat_wire_msg_t *)data;

    // Check magic
    if (wire_msg->magic != CHAT_MSG_MAGIC) {
        // Not a chat message, ignore silently
        return;
    }

    // Accept v1 (text only) and v2 (text + file) messages
    if (wire_msg->version < 1 || wire_msg->version > CHAT_MSG_VERSION) {
        ESP_LOGW(TAG, "[CHAT RX] Unsupported version: %d", wire_msg->version);
        return;
    }

    // Validate text length
    if (len < sizeof(chat_wire_msg_t) + wire_msg->text_len) {
        ESP_LOGW(TAG, "[CHAT RX] Invalid message length");
        return;
    }

    // Determine message type (v1 messages are always text)
    mesh_chat_msg_type_t msg_type = MESH_CHAT_MSG_TEXT;
    if (wire_msg->version >= 2) {
        msg_type = (mesh_chat_msg_type_t)wire_msg->msg_type;
    }

    ESP_LOGI(TAG, "[CHAT RX] ========================================");
    ESP_LOGI(TAG, "[CHAT RX] %s from %s",
             msg_type == MESH_CHAT_MSG_FILE ? "File" : "Message",
             wire_msg->callsign);
    ESP_LOGI(TAG, "[CHAT RX] MAC: " MACSTR, MAC2STR(src_mac));
    ESP_LOGI(TAG, "[CHAT RX] ID: %lu, Time: %lu",
             (unsigned long)wire_msg->msg_id, (unsigned long)wire_msg->timestamp);
    if (msg_type == MESH_CHAT_MSG_FILE) {
        ESP_LOGI(TAG, "[CHAT RX] File: %s (%lu bytes)",
                 wire_msg->filename, (unsigned long)wire_msg->file_size);
    }
    if (wire_msg->text_len > 0) {
        ESP_LOGI(TAG, "[CHAT RX] Text: \"%.*s\"",
                 (int)wire_msg->text_len, wire_msg->text);
    }
    ESP_LOGI(TAG, "[CHAT RX] ========================================");

    // Build message structure
    mesh_chat_message_t msg = {
        .id = wire_msg->msg_id,
        .timestamp = wire_msg->timestamp,
        .is_local = false,
        .msg_type = msg_type,
        .channels = MESH_CHAT_CH_MESH
    };
    memcpy(msg.sender_mac, src_mac, 6);
    strncpy(msg.callsign, wire_msg->callsign, MESH_CHAT_MAX_CALLSIGN_LEN - 1);
    msg.callsign[MESH_CHAT_MAX_CALLSIGN_LEN - 1] = '\0';

    size_t copy_len = wire_msg->text_len;
    if (copy_len > MESH_CHAT_MAX_MESSAGE_LEN) {
        copy_len = MESH_CHAT_MAX_MESSAGE_LEN;
    }
    memcpy(msg.text, wire_msg->text, copy_len);
    msg.text[copy_len] = '\0';

    // Copy file info if present
    if (msg_type == MESH_CHAT_MSG_FILE && wire_msg->version >= 2) {
        memcpy(msg.file.sha1, wire_msg->sha1, 20);
        msg.file.size = wire_msg->file_size;
        strncpy(msg.file.filename, wire_msg->filename, MESH_CHAT_MAX_FILENAME_LEN - 1);
        msg.file.filename[MESH_CHAT_MAX_FILENAME_LEN - 1] = '\0';
        strncpy(msg.file.mime_type, wire_msg->mime_type, MESH_CHAT_MAX_MIME_LEN - 1);
        msg.file.mime_type[MESH_CHAT_MAX_MIME_LEN - 1] = '\0';
    } else {
        memset(&msg.file, 0, sizeof(msg.file));
    }

    // Add to history
    add_message_to_history(&msg);

    // Notify callback
    if (s_callback) {
        s_callback(&msg);
    }

#if CONFIG_IDF_TARGET_ESP32C3
    // Blink blue LED 3 times to indicate incoming chat message
    led_notify_chat();
#endif
}

// ============================================================================
// History Access
// ============================================================================

size_t mesh_chat_get_history(mesh_chat_message_t *messages, size_t max_messages, uint32_t since_id)
{
    if (!s_initialized || !messages || max_messages == 0) {
        return 0;
    }

    xSemaphoreTake(s_mutex, portMAX_DELAY);

    size_t count = 0;

    // Iterate through history in order (oldest to newest)
    for (size_t i = 0; i < s_history_count && count < max_messages; i++) {
        size_t idx;
        if (s_history_count < MESH_CHAT_HISTORY_SIZE) {
            idx = i;
        } else {
            idx = (s_history_head + i) % MESH_CHAT_HISTORY_SIZE;
        }

        if (s_history[idx].id > since_id) {
            memcpy(&messages[count], &s_history[idx], sizeof(mesh_chat_message_t));
            count++;
        }
    }

    xSemaphoreGive(s_mutex);

    return count;
}

uint32_t mesh_chat_get_latest_id(void)
{
    if (!s_initialized) {
        return 0;
    }

    xSemaphoreTake(s_mutex, portMAX_DELAY);
    uint32_t latest = s_next_msg_id > 0 ? s_next_msg_id - 1 : 0;
    xSemaphoreGive(s_mutex);

    return latest;
}

size_t mesh_chat_get_count(void)
{
    if (!s_initialized) {
        return 0;
    }

    xSemaphoreTake(s_mutex, portMAX_DELAY);
    size_t count = s_history_count;
    xSemaphoreGive(s_mutex);

    return count;
}

void mesh_chat_register_callback(mesh_chat_callback_t callback)
{
    s_callback = callback;
}

// ============================================================================
// JSON Builder
// ============================================================================

static size_t channels_to_json(char *buf, size_t sz, uint8_t ch)
{
    size_t p = 0;
    p += snprintf(buf + p, sz - p, "[");
    int first = 1;
    if (ch & MESH_CHAT_CH_WIFI) { p += snprintf(buf + p, sz - p, "%s\"wifi\"", first ? "" : ","); first = 0; }
    if (ch & MESH_CHAT_CH_BLE)  { p += snprintf(buf + p, sz - p, "%s\"ble\"",  first ? "" : ","); first = 0; }
    if (ch & MESH_CHAT_CH_MESH) { p += snprintf(buf + p, sz - p, "%s\"mesh\"", first ? "" : ","); first = 0; }
    if (ch & MESH_CHAT_CH_APRS) { p += snprintf(buf + p, sz - p, "%s\"aprs\"", first ? "" : ","); first = 0; }
    if (ch & MESH_CHAT_CH_LORA) { p += snprintf(buf + p, sz - p, "%s\"lora\"", first ? "" : ","); first = 0; }
    p += snprintf(buf + p, sz - p, "]");
    return p;
}

size_t mesh_chat_build_json(char *buffer, size_t size, uint32_t since_id)
{
    if (!buffer || size < 64) {
        return 0;
    }

    // Limit batch size to reduce memory usage (especially on ESP32-C3)
    const size_t max_batch = 20;
    mesh_chat_message_t *messages = malloc(sizeof(mesh_chat_message_t) * max_batch);
    if (!messages) {
        ESP_LOGE("mesh_chat", "Failed to alloc messages, free heap: %lu",
                 (unsigned long)esp_get_free_heap_size());
        return 0;
    }
    size_t count = mesh_chat_get_history(messages, max_batch, since_id);

    // Get local callsign for identification
    extern const char *nostr_keys_get_callsign(void);
    const char *my_callsign = nostr_keys_get_callsign();
    if (!my_callsign) my_callsign = "";

    size_t pos = 0;
    pos += snprintf(buffer + pos, size - pos,
                    "{\"messages\":[");

    for (size_t i = 0; i < count; i++) {
        if (i > 0) {
            pos += snprintf(buffer + pos, size - pos, ",");
        }

        // Escape the text for JSON
        char escaped_text[MESH_CHAT_MAX_MESSAGE_LEN * 2 + 1];
        size_t esc_pos = 0;
        for (size_t j = 0; messages[i].text[j] && esc_pos < sizeof(escaped_text) - 2; j++) {
            char c = messages[i].text[j];
            if (c == '"' || c == '\\') {
                escaped_text[esc_pos++] = '\\';
            } else if (c == '\n') {
                escaped_text[esc_pos++] = '\\';
                c = 'n';
            } else if (c == '\r') {
                continue;
            }
            escaped_text[esc_pos++] = c;
        }
        escaped_text[esc_pos] = '\0';

        // Build message JSON with type
        if (messages[i].msg_type == MESH_CHAT_MSG_FILE) {
            // Convert SHA1 to hex string
            char sha1_hex[41];
            for (int j = 0; j < 20; j++) {
                sprintf(sha1_hex + j * 2, "%02x", messages[i].file.sha1[j]);
            }
            sha1_hex[40] = '\0';

            // Escape filename for JSON
            char escaped_filename[MESH_CHAT_MAX_FILENAME_LEN * 2 + 1];
            size_t fn_pos = 0;
            for (size_t j = 0; messages[i].file.filename[j] && fn_pos < sizeof(escaped_filename) - 2; j++) {
                char c = messages[i].file.filename[j];
                if (c == '"' || c == '\\') {
                    escaped_filename[fn_pos++] = '\\';
                }
                escaped_filename[fn_pos++] = c;
            }
            escaped_filename[fn_pos] = '\0';

            pos += snprintf(buffer + pos, size - pos,
                "{\"id\":%lu,\"ts\":%lu,\"from\":\"%s\",\"type\":\"file\",\"text\":\"%s\",\"local\":%s,"
                "\"file\":{\"sha1\":\"%s\",\"name\":\"%s\",\"size\":%lu,\"mime\":\"%s\"},\"channels\":",
                (unsigned long)messages[i].id,
                (unsigned long)messages[i].timestamp,
                messages[i].callsign,
                escaped_text,
                messages[i].is_local ? "true" : "false",
                sha1_hex,
                escaped_filename,
                (unsigned long)messages[i].file.size,
                messages[i].file.mime_type);
            pos += channels_to_json(buffer + pos, size - pos, messages[i].channels);
            pos += snprintf(buffer + pos, size - pos, "}");
        } else {
            pos += snprintf(buffer + pos, size - pos,
                "{\"id\":%lu,\"ts\":%lu,\"from\":\"%s\",\"type\":\"text\",\"text\":\"%s\",\"local\":%s,\"channels\":",
                (unsigned long)messages[i].id,
                (unsigned long)messages[i].timestamp,
                messages[i].callsign,
                escaped_text,
                messages[i].is_local ? "true" : "false");
            pos += channels_to_json(buffer + pos, size - pos, messages[i].channels);
            pos += snprintf(buffer + pos, size - pos, "}");
        }

        if (pos >= size - 1) break;
    }

    pos += snprintf(buffer + pos, size - pos,
                    "],\"latest_id\":%lu,\"my_callsign\":\"%s\",\"max_len\":%d}",
                    (unsigned long)mesh_chat_get_latest_id(),
                    my_callsign,
                    MESH_CHAT_MAX_MESSAGE_LEN);

    free(messages);
    return pos;
}

// ============================================================================
// Helper Functions
// ============================================================================

static void add_message_to_history(const mesh_chat_message_t *msg)
{
    if (!msg) return;

    xSemaphoreTake(s_mutex, portMAX_DELAY);

    // Check for duplicate: same callsign + same text + timestamp within 5s
    for (size_t i = 0; i < s_history_count && i < 10; i++) {
        size_t idx = (s_history_head - 1 - i + MESH_CHAT_HISTORY_SIZE) % MESH_CHAT_HISTORY_SIZE;
        mesh_chat_message_t *existing = &s_history[idx];
        if (strcmp(existing->callsign, msg->callsign) == 0 &&
            strcmp(existing->text, msg->text) == 0 &&
            abs((int)existing->timestamp - (int)msg->timestamp) <= 5) {
            existing->channels |= msg->channels;
            xSemaphoreGive(s_mutex);
            return;
        }
    }

    // Copy to circular buffer
    memcpy(&s_history[s_history_head], msg, sizeof(mesh_chat_message_t));

    // Advance head
    s_history_head = (s_history_head + 1) % MESH_CHAT_HISTORY_SIZE;

    // Update count
    if (s_history_count < MESH_CHAT_HISTORY_SIZE) {
        s_history_count++;
    }

    xSemaphoreGive(s_mutex);

    ESP_LOGD(TAG, "Message added to history (count: %zu)", s_history_count);
}

static uint32_t get_timestamp(void)
{
    time_t now;
    time(&now);
    return (uint32_t)now;
}
