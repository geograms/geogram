/**
 * @file dns_server.c
 * @brief Simple DNS server for captive portal
 *
 * This DNS server responds to all A record queries with the AP's IP address.
 * This allows users to access the device via any hostname (including the callsign).
 */

#include "dns_server.h"
#include "esp_log.h"
#include "lwip/sockets.h"
#include "lwip/netdb.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include <string.h>

static const char *TAG = "dns_server";

// DNS header structure
typedef struct __attribute__((packed)) {
    uint16_t id;
    uint16_t flags;
    uint16_t qd_count;  // Question count
    uint16_t an_count;  // Answer count
    uint16_t ns_count;  // Authority count
    uint16_t ar_count;  // Additional count
} dns_header_t;

// DNS flags
#define DNS_FLAG_QR     0x8000  // Query/Response flag
#define DNS_FLAG_AA     0x0400  // Authoritative Answer
#define DNS_FLAG_RD     0x0100  // Recursion Desired
#define DNS_FLAG_RA     0x0080  // Recursion Available

// DNS types
#define DNS_TYPE_A      1       // IPv4 address
#define DNS_CLASS_IN    1       // Internet class

#define DNS_MAX_PACKET  512
#define DNS_TASK_STACK  4096
#define DNS_TASK_PRIO   5

static int s_socket = -1;
static TaskHandle_t s_task = NULL;
static uint32_t s_ap_ip = 0;
static bool s_running = false;

/**
 * @brief Skip over a DNS name in the packet
 */
static int dns_skip_name(const uint8_t *data, int offset, int len)
{
    while (offset < len) {
        uint8_t label_len = data[offset];
        if (label_len == 0) {
            return offset + 1;  // End of name
        }
        if ((label_len & 0xC0) == 0xC0) {
            return offset + 2;  // Pointer (compressed)
        }
        offset += label_len + 1;
    }
    return -1;  // Error
}

/**
 * @brief Build DNS response packet
 */
static int dns_build_response(const uint8_t *query, int query_len, uint8_t *response, uint32_t ip)
{
    if (query_len < sizeof(dns_header_t)) {
        return -1;
    }

    const dns_header_t *q_header = (const dns_header_t *)query;
    dns_header_t *r_header = (dns_header_t *)response;

    // Copy query header and modify for response
    memcpy(response, query, query_len);

    // Set response flags
    r_header->flags = htons(DNS_FLAG_QR | DNS_FLAG_AA | DNS_FLAG_RD | DNS_FLAG_RA);
    r_header->an_count = htons(1);  // One answer

    // Skip past header and question to find where to add answer
    int offset = sizeof(dns_header_t);

    // Skip question name
    offset = dns_skip_name(query, offset, query_len);
    if (offset < 0) return -1;

    // Skip QTYPE and QCLASS
    offset += 4;

    int resp_len = offset;

    // Add answer section
    // Name pointer to question name (0xC00C points to offset 12, right after header)
    response[resp_len++] = 0xC0;
    response[resp_len++] = 0x0C;

    // Type: A (1)
    response[resp_len++] = 0x00;
    response[resp_len++] = DNS_TYPE_A;

    // Class: IN (1)
    response[resp_len++] = 0x00;
    response[resp_len++] = DNS_CLASS_IN;

    // TTL: 60 seconds
    response[resp_len++] = 0x00;
    response[resp_len++] = 0x00;
    response[resp_len++] = 0x00;
    response[resp_len++] = 60;

    // Data length: 4 (IPv4 address)
    response[resp_len++] = 0x00;
    response[resp_len++] = 0x04;

    // IP address (already in network byte order from esp_netif)
    response[resp_len++] = (ip >> 0) & 0xFF;
    response[resp_len++] = (ip >> 8) & 0xFF;
    response[resp_len++] = (ip >> 16) & 0xFF;
    response[resp_len++] = (ip >> 24) & 0xFF;

    return resp_len;
}

/**
 * @brief DNS server task
 */
static void dns_server_task(void *pvParameters)
{
    uint8_t rx_buffer[DNS_MAX_PACKET];
    uint8_t tx_buffer[DNS_MAX_PACKET];

    ESP_LOGI(TAG, "DNS server task started");

    while (s_running) {
        struct sockaddr_in client_addr;
        socklen_t addr_len = sizeof(client_addr);

        int len = recvfrom(s_socket, rx_buffer, sizeof(rx_buffer), 0,
                          (struct sockaddr *)&client_addr, &addr_len);

        if (len < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                continue;  // Timeout, check if still running
            }
            ESP_LOGE(TAG, "recvfrom failed: %d", errno);
            break;
        }

        if (len < (int)sizeof(dns_header_t)) {
            continue;  // Packet too short
        }

        // Build and send response
        int resp_len = dns_build_response(rx_buffer, len, tx_buffer, s_ap_ip);
        if (resp_len > 0) {
            sendto(s_socket, tx_buffer, resp_len, 0,
                   (struct sockaddr *)&client_addr, addr_len);
        }
    }

    ESP_LOGI(TAG, "DNS server task stopped");
    vTaskDelete(NULL);
}

esp_err_t dns_server_start(uint32_t ap_ip)
{
    if (ap_ip == 0) {
        ESP_LOGW(TAG, "Refusing to start DNS server with invalid AP IP 0.0.0.0");
        return ESP_ERR_INVALID_ARG;
    }

    if (s_running) {
        if (s_ap_ip != ap_ip) {
            s_ap_ip = ap_ip;
            ESP_LOGI(TAG, "DNS server already running, updated AP IP to %d.%d.%d.%d",
                     (uint8_t)(ap_ip), (uint8_t)(ap_ip >> 8),
                     (uint8_t)(ap_ip >> 16), (uint8_t)(ap_ip >> 24));
        } else {
            ESP_LOGW(TAG, "DNS server already running");
        }
        return ESP_OK;
    }

    s_ap_ip = ap_ip;

    // Create UDP socket
    s_socket = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (s_socket < 0) {
        ESP_LOGE(TAG, "Failed to create socket: %d", errno);
        return ESP_FAIL;
    }

    // Set socket timeout
    struct timeval timeout = { .tv_sec = 1, .tv_usec = 0 };
    setsockopt(s_socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));

    // Bind to DNS port
    struct sockaddr_in server_addr = {
        .sin_family = AF_INET,
        .sin_port = htons(DNS_SERVER_PORT),
        .sin_addr.s_addr = htonl(INADDR_ANY),
    };

    if (bind(s_socket, (struct sockaddr *)&server_addr, sizeof(server_addr)) < 0) {
        ESP_LOGE(TAG, "Failed to bind socket: %d", errno);
        close(s_socket);
        s_socket = -1;
        return ESP_FAIL;
    }

    s_running = true;

    // Start DNS server task
    BaseType_t ret = xTaskCreate(dns_server_task, "dns_server", DNS_TASK_STACK,
                                  NULL, DNS_TASK_PRIO, &s_task);
    if (ret != pdPASS) {
        ESP_LOGE(TAG, "Failed to create DNS server task");
        close(s_socket);
        s_socket = -1;
        s_running = false;
        return ESP_FAIL;
    }

    ESP_LOGI(TAG, "DNS server started on port %d, responding with %d.%d.%d.%d",
             DNS_SERVER_PORT,
             (uint8_t)(ap_ip), (uint8_t)(ap_ip >> 8),
             (uint8_t)(ap_ip >> 16), (uint8_t)(ap_ip >> 24));

    return ESP_OK;
}

esp_err_t dns_server_stop(void)
{
    if (!s_running) {
        return ESP_OK;
    }

    s_running = false;

    // Close socket to unblock recvfrom
    if (s_socket >= 0) {
        close(s_socket);
        s_socket = -1;
    }

    // Wait for task to finish
    vTaskDelay(pdMS_TO_TICKS(100));
    s_task = NULL;

    ESP_LOGI(TAG, "DNS server stopped");
    return ESP_OK;
}

bool dns_server_is_running(void)
{
    return s_running;
}
