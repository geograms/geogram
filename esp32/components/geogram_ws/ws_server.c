/**
 * @file ws_server.c
 * @brief WebSocket server for P2P file sharing signaling
 *
 * Handles WebSocket connections for:
 * - File availability requests (broadcast "who has SHA1 X?")
 * - File availability announcements
 * - WebRTC signaling (offer/answer/ICE)
 * - Mesh network forwarding of file requests
 */

#include "ws_server.h"
#include <string.h>
#include <esp_log.h>
#include <esp_http_server.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>

#ifdef CONFIG_GEOGRAM_MESH_ENABLED
#include "mesh_bsp.h"
#include "esp_wifi.h"
#endif

static const char *TAG = "WS";

// Mesh file request magic number
#define WS_MESH_FILE_REQ_MAGIC  0x46494C45  // "FILE"

// Mesh file request wire format
typedef struct __attribute__((packed)) {
    uint32_t magic;         // WS_MESH_FILE_REQ_MAGIC
    uint8_t msg_type;       // 0=request, 1=available
    uint8_t sha1[20];       // File SHA1 hash
    uint8_t requester_ip[4]; // Requester IP for responses
    char requester_id[16];  // Requester client ID
} ws_mesh_file_msg_t;

// Connected clients
static ws_client_t s_clients[WS_MAX_CLIENTS];
static SemaphoreHandle_t s_mutex = NULL;
static httpd_handle_t s_server = NULL;

// Simple JSON helper to extract string value
static bool json_get_string(const char *json, const char *key, char *value, size_t value_len)
{
    char search[64];
    snprintf(search, sizeof(search), "\"%s\":\"", key);
    const char *pos = strstr(json, search);
    if (!pos) {
        // Try without quotes for non-string values
        snprintf(search, sizeof(search), "\"%s\":", key);
        pos = strstr(json, search);
        if (!pos) return false;
        pos += strlen(search);
        while (*pos == ' ') pos++;
        // Copy until comma, brace, or bracket
        size_t i = 0;
        while (*pos && *pos != ',' && *pos != '}' && *pos != ']' && i < value_len - 1) {
            value[i++] = *pos++;
        }
        value[i] = '\0';
        return i > 0;
    }

    pos += strlen(search);
    size_t i = 0;
    while (*pos && *pos != '"' && i < value_len - 1) {
        if (*pos == '\\' && pos[1]) {
            pos++;
        }
        value[i++] = *pos++;
    }
    value[i] = '\0';
    return true;
}

// Find client by fd
static int find_client_by_fd(int fd)
{
    for (int i = 0; i < WS_MAX_CLIENTS; i++) {
        if (s_clients[i].active && s_clients[i].fd == fd) {
            return i;
        }
    }
    return -1;
}

// Find client by ID
static int find_client_by_id(const char *id)
{
    for (int i = 0; i < WS_MAX_CLIENTS; i++) {
        if (s_clients[i].active && strcmp(s_clients[i].id, id) == 0) {
            return i;
        }
    }
    return -1;
}

// Add a new client
static int add_client(int fd)
{
    xSemaphoreTake(s_mutex, portMAX_DELAY);
    for (int i = 0; i < WS_MAX_CLIENTS; i++) {
        if (!s_clients[i].active) {
            s_clients[i].fd = fd;
            s_clients[i].id[0] = '\0';
            s_clients[i].active = true;
            ESP_LOGI(TAG, "Client added: fd=%d, slot=%d", fd, i);
            xSemaphoreGive(s_mutex);
            return i;
        }
    }
    xSemaphoreGive(s_mutex);
    ESP_LOGW(TAG, "No slots available for new client");
    return -1;
}

// Remove a client
static void remove_client(int fd)
{
    xSemaphoreTake(s_mutex, portMAX_DELAY);
    int idx = find_client_by_fd(fd);
    if (idx >= 0) {
        ESP_LOGI(TAG, "Client removed: fd=%d, id=%s", fd, s_clients[idx].id);
        s_clients[idx].active = false;
        s_clients[idx].fd = -1;
        s_clients[idx].id[0] = '\0';
    }
    xSemaphoreGive(s_mutex);
}

// Set client ID from hello message
static void set_client_id(int fd, const char *id)
{
    xSemaphoreTake(s_mutex, portMAX_DELAY);
    int idx = find_client_by_fd(fd);
    if (idx >= 0) {
        strncpy(s_clients[idx].id, id, sizeof(s_clients[idx].id) - 1);
        s_clients[idx].id[sizeof(s_clients[idx].id) - 1] = '\0';
        ESP_LOGI(TAG, "Client identified: fd=%d, id=%s", fd, id);
    }
    xSemaphoreGive(s_mutex);
}

// Parse message type from JSON
ws_message_type_t ws_parse_message_type(const char *data, size_t len)
{
    if (!data || len == 0) return WS_MSG_UNKNOWN;

    char type[32] = {0};
    if (!json_get_string(data, "type", type, sizeof(type))) {
        return WS_MSG_UNKNOWN;
    }

    if (strcmp(type, "hello") == 0) return WS_MSG_HELLO;
    if (strcmp(type, "file_request") == 0) return WS_MSG_FILE_REQUEST;
    if (strcmp(type, "file_available") == 0) return WS_MSG_FILE_AVAILABLE;
    if (strcmp(type, "file_fetch") == 0) return WS_MSG_FILE_FETCH;
    if (strcmp(type, "file_chunk") == 0) return WS_MSG_FILE_CHUNK;
    if (strcmp(type, "file_complete") == 0) return WS_MSG_FILE_COMPLETE;
    if (strcmp(type, "rtc_offer") == 0) return WS_MSG_RTC_OFFER;
    if (strcmp(type, "rtc_answer") == 0) return WS_MSG_RTC_ANSWER;
    if (strcmp(type, "rtc_ice") == 0) return WS_MSG_RTC_ICE;
    if (strcmp(type, "ping") == 0) return WS_MSG_PING;

    return WS_MSG_UNKNOWN;
}

// Send text to specific client
esp_err_t ws_send_text(httpd_handle_t server, int fd, const char *message, size_t len)
{
    if (!server || fd < 0 || !message) {
        return ESP_ERR_INVALID_ARG;
    }

    httpd_ws_frame_t ws_pkt = {
        .type = HTTPD_WS_TYPE_TEXT,
        .payload = (uint8_t *)message,
        .len = len
    };

    esp_err_t ret = httpd_ws_send_frame_async(server, fd, &ws_pkt);
    if (ret != ESP_OK) {
        ESP_LOGW(TAG, "Failed to send to fd=%d: %s", fd, esp_err_to_name(ret));
    }
    return ret;
}

// Send to client by ID
esp_err_t ws_send_to_client(httpd_handle_t server, const char *client_id, const char *message, size_t len)
{
    if (!server || !client_id || !message) {
        return ESP_ERR_INVALID_ARG;
    }

    xSemaphoreTake(s_mutex, portMAX_DELAY);
    int idx = find_client_by_id(client_id);
    if (idx < 0) {
        xSemaphoreGive(s_mutex);
        ESP_LOGW(TAG, "Client not found: %s", client_id);
        return ESP_ERR_NOT_FOUND;
    }
    int fd = s_clients[idx].fd;
    xSemaphoreGive(s_mutex);

    return ws_send_text(server, fd, message, len);
}

// Broadcast to all except sender (by fd, -1 to include all)
static void broadcast_except(httpd_handle_t server, int except_fd, const char *message, size_t len)
{
    xSemaphoreTake(s_mutex, portMAX_DELAY);
    for (int i = 0; i < WS_MAX_CLIENTS; i++) {
        if (s_clients[i].active && s_clients[i].fd != except_fd) {
            ws_send_text(server, s_clients[i].fd, message, len);
        }
    }
    xSemaphoreGive(s_mutex);
}

void ws_broadcast_text(httpd_handle_t server, const char *message, size_t len)
{
    broadcast_except(server, -1, message, len);
}

void ws_broadcast_all(httpd_handle_t server, const char *message, size_t len)
{
    broadcast_except(server, -2, message, len);  // -2 means include all
}

int ws_get_client_count(void)
{
    int count = 0;
    xSemaphoreTake(s_mutex, portMAX_DELAY);
    for (int i = 0; i < WS_MAX_CLIENTS; i++) {
        if (s_clients[i].active) count++;
    }
    xSemaphoreGive(s_mutex);
    return count;
}

// Parse SHA1 hex string to bytes
static bool parse_sha1_hex(const char *hex, uint8_t *out)
{
    if (strlen(hex) != 40) return false;
    for (int i = 0; i < 20; i++) {
        char byte_str[3] = {hex[i*2], hex[i*2+1], 0};
        char *endptr;
        out[i] = (uint8_t)strtol(byte_str, &endptr, 16);
        if (*endptr != '\0') return false;
    }
    return true;
}

#ifdef CONFIG_GEOGRAM_MESH_ENABLED
// Forward file request to all mesh nodes
static void forward_file_request_to_mesh(const char *sha1_hex, const char *from_id)
{
    if (!geogram_mesh_is_connected()) return;

    ws_mesh_file_msg_t msg = {
        .magic = WS_MESH_FILE_REQ_MAGIC,
        .msg_type = 0  // Request
    };

    if (!parse_sha1_hex(sha1_hex, msg.sha1)) {
        ESP_LOGW(TAG, "Invalid SHA1 hex for mesh forward");
        return;
    }

    // Get our external AP IP as requester address
    uint32_t ip = 0;
    geogram_mesh_get_external_ap_ip_addr(&ip);
    memcpy(msg.requester_ip, &ip, 4);

    if (from_id) {
        strncpy(msg.requester_id, from_id, sizeof(msg.requester_id) - 1);
    }

    // Send to all mesh nodes
    geogram_mesh_node_t nodes[20];
    size_t node_count = 0;
    geogram_mesh_get_nodes(nodes, 20, &node_count);

    uint8_t local_mac[6];
    esp_wifi_get_mac(WIFI_IF_STA, local_mac);

    for (size_t i = 0; i < node_count; i++) {
        if (memcmp(nodes[i].mac, local_mac, 6) != 0) {
            geogram_mesh_send_to_node(nodes[i].mac, &msg, sizeof(msg));
        }
    }

    ESP_LOGI(TAG, "File request forwarded to %zu mesh nodes", node_count > 0 ? node_count - 1 : 0);
}

// Handle file request from mesh network
void ws_handle_mesh_file_request(const uint8_t *src_mac, const void *data, size_t len)
{
    if (len < sizeof(ws_mesh_file_msg_t)) return;

    const ws_mesh_file_msg_t *msg = (const ws_mesh_file_msg_t *)data;
    if (msg->magic != WS_MESH_FILE_REQ_MAGIC) return;

    // Convert SHA1 to hex string
    char sha1_hex[41];
    for (int i = 0; i < 20; i++) {
        sprintf(sha1_hex + i * 2, "%02x", msg->sha1[i]);
    }
    sha1_hex[40] = '\0';

    if (msg->msg_type == 0) {
        // File request from mesh - broadcast to local WebSocket clients
        ESP_LOGI(TAG, "Mesh file request for %s", sha1_hex);

        char json[256];
        int json_len = snprintf(json, sizeof(json),
            "{\"type\":\"file_request\",\"sha1\":\"%s\",\"from_mesh\":true}",
            sha1_hex);

        if (s_server) {
            ws_broadcast_all(s_server, json, json_len);
        }
    } else if (msg->msg_type == 1) {
        // File available response from mesh
        ESP_LOGI(TAG, "Mesh file available: %s", sha1_hex);

        // Format IP address
        char ip_str[16];
        snprintf(ip_str, sizeof(ip_str), "%d.%d.%d.%d",
                 msg->requester_ip[0], msg->requester_ip[1],
                 msg->requester_ip[2], msg->requester_ip[3]);

        char json[256];
        int json_len = snprintf(json, sizeof(json),
            "{\"type\":\"file_available\",\"sha1\":\"%s\",\"from\":\"%s\",\"mesh_ip\":\"%s\"}",
            sha1_hex, msg->requester_id, ip_str);

        if (s_server) {
            ws_broadcast_all(s_server, json, json_len);
        }
    }
}
#endif

// Handle incoming WebSocket message
static void handle_ws_message(httpd_handle_t server, int fd, const char *data, size_t len)
{
    ws_message_type_t msg_type = ws_parse_message_type(data, len);
    char value[128];

    switch (msg_type) {
        case WS_MSG_HELLO:
            // Client identifies itself
            if (json_get_string(data, "id", value, sizeof(value))) {
                ESP_LOGI(TAG, "WS hello: id=%s fd=%d", value, fd);
                set_client_id(fd, value);
            }
            break;

        case WS_MSG_FILE_REQUEST:
            // Broadcast file request to all local clients
            {
                char sha1[64] = {0};
                char from_id[16] = {0};
                json_get_string(data, "sha1", sha1, sizeof(sha1));
                json_get_string(data, "from", from_id, sizeof(from_id));
                ESP_LOGI(TAG, "File request: sha1=%s from=%s", sha1[0] ? sha1 : "unknown",
                         from_id[0] ? from_id : "unknown");
            }
            broadcast_except(server, fd, data, len);

#ifdef CONFIG_GEOGRAM_MESH_ENABLED
            // Also forward to mesh network
            {
                char sha1[64] = {0};
                char from_id[16] = {0};
                if (json_get_string(data, "sha1", sha1, sizeof(sha1))) {
                    json_get_string(data, "from", from_id, sizeof(from_id));
                    forward_file_request_to_mesh(sha1, from_id);
                }
            }
#endif
            break;

        case WS_MSG_FILE_AVAILABLE:
            // Broadcast file availability to all clients
            {
                char sha1[64] = {0};
                char from_id[16] = {0};
                json_get_string(data, "sha1", sha1, sizeof(sha1));
                json_get_string(data, "from", from_id, sizeof(from_id));
                ESP_LOGI(TAG, "File available: sha1=%s from=%s", sha1[0] ? sha1 : "unknown",
                         from_id[0] ? from_id : "unknown");
            }
            broadcast_except(server, fd, data, len);
            break;

        case WS_MSG_FILE_FETCH:
        case WS_MSG_FILE_CHUNK:
        case WS_MSG_FILE_COMPLETE:
            if (json_get_string(data, "to", value, sizeof(value))) {
                char sha1[64] = {0};
                char from_id[16] = {0};
                char seq[16] = {0};
                json_get_string(data, "sha1", sha1, sizeof(sha1));
                json_get_string(data, "from", from_id, sizeof(from_id));
                if (msg_type == WS_MSG_FILE_CHUNK) {
                    json_get_string(data, "seq", seq, sizeof(seq));
                }
                ESP_LOGI(TAG, "File relay: type=%s sha1=%s from=%s to=%s seq=%s",
                         msg_type == WS_MSG_FILE_FETCH ? "fetch" :
                         msg_type == WS_MSG_FILE_CHUNK ? "chunk" : "complete",
                         sha1[0] ? sha1 : "unknown",
                         from_id[0] ? from_id : "unknown",
                         value,
                         msg_type == WS_MSG_FILE_CHUNK ? (seq[0] ? seq : "0") : "-");
                ws_send_to_client(server, value, data, len);
            }
            break;

        case WS_MSG_RTC_OFFER:
        case WS_MSG_RTC_ANSWER:
        case WS_MSG_RTC_ICE:
            // Route WebRTC signaling to specific client
            if (json_get_string(data, "to", value, sizeof(value))) {
                ESP_LOGI(TAG, "Routing %s to %s",
                         msg_type == WS_MSG_RTC_OFFER ? "offer" :
                         msg_type == WS_MSG_RTC_ANSWER ? "answer" : "ICE",
                         value);
                ws_send_to_client(server, value, data, len);
            } else {
                // No specific target, broadcast
                broadcast_except(server, fd, data, len);
            }
            break;

        case WS_MSG_PING:
            // Respond with pong
            ws_send_text(server, fd, "{\"type\":\"pong\"}", 15);
            break;

        default:
            ESP_LOGD(TAG, "Unknown message type");
            break;
    }
}

// WebSocket handler
static esp_err_t ws_handler(httpd_req_t *req)
{
    if (req->method == HTTP_GET) {
        // Initial WebSocket handshake
        ESP_LOGI(TAG, "WebSocket handshake request");
        int fd = httpd_req_to_sockfd(req);
        if (add_client(fd) < 0) {
            return ESP_FAIL;
        }
        return ESP_OK;
    }

    // Receive WebSocket frame
    httpd_ws_frame_t ws_pkt;
    memset(&ws_pkt, 0, sizeof(httpd_ws_frame_t));
    ws_pkt.type = HTTPD_WS_TYPE_TEXT;

    // First call to get frame length
    esp_err_t ret = httpd_ws_recv_frame(req, &ws_pkt, 0);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to get frame len: %s", esp_err_to_name(ret));
        return ret;
    }

    if (ws_pkt.len == 0) {
        return ESP_OK;
    }

    if (ws_pkt.len > WS_MAX_FRAME_SIZE) {
        ESP_LOGW(TAG, "Frame too large: %zu", ws_pkt.len);
        return ESP_ERR_NO_MEM;
    }

    // Allocate buffer and receive frame
    uint8_t *buf = malloc(ws_pkt.len + 1);
    if (!buf) {
        ESP_LOGE(TAG, "Failed to allocate buffer");
        return ESP_ERR_NO_MEM;
    }

    ws_pkt.payload = buf;
    ret = httpd_ws_recv_frame(req, &ws_pkt, ws_pkt.len);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to receive frame: %s", esp_err_to_name(ret));
        free(buf);
        return ret;
    }

    buf[ws_pkt.len] = '\0';

    // Handle text messages
    if (ws_pkt.type == HTTPD_WS_TYPE_TEXT) {
        int fd = httpd_req_to_sockfd(req);
        handle_ws_message(req->handle, fd, (char *)buf, ws_pkt.len);
    } else if (ws_pkt.type == HTTPD_WS_TYPE_CLOSE) {
        // Client disconnected
        int fd = httpd_req_to_sockfd(req);
        remove_client(fd);
    }

    free(buf);
    return ESP_OK;
}

// Async send callback for client closure detection
static void ws_async_send_callback(void *arg)
{
    // Not used currently
}

esp_err_t ws_server_register(httpd_handle_t server)
{
    if (!server) {
        return ESP_ERR_INVALID_ARG;
    }

    // Initialize mutex if needed
    if (!s_mutex) {
        s_mutex = xSemaphoreCreateMutex();
        if (!s_mutex) {
            return ESP_ERR_NO_MEM;
        }
    }

    // Clear client list
    memset(s_clients, 0, sizeof(s_clients));
    for (int i = 0; i < WS_MAX_CLIENTS; i++) {
        s_clients[i].fd = -1;
    }

    s_server = server;

    // Register WebSocket handler
    static const httpd_uri_t ws_uri = {
        .uri = "/ws",
        .method = HTTP_GET,
        .handler = ws_handler,
        .user_ctx = NULL,
        .is_websocket = true,
        .handle_ws_control_frames = true
    };

    esp_err_t ret = httpd_register_uri_handler(server, &ws_uri);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to register WebSocket handler: %s", esp_err_to_name(ret));
        return ret;
    }

    ESP_LOGI(TAG, "WebSocket server registered at /ws");
    return ESP_OK;
}
