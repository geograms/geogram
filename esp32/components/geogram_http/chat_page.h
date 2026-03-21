/**
 * @file chat_page.h
 * @brief Chat landing page and API handlers
 *
 * Extracted from http_server.c — serves the chat web UI and
 * provides REST endpoints for the mesh chat system.
 */

#ifndef GEOGRAM_CHAT_PAGE_H
#define GEOGRAM_CHAT_PAGE_H

#include "esp_http_server.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Serve the chat landing page via chunked HTTP response
 * @param req HTTP request handle
 * @return ESP_OK on success
 */
esp_err_t chat_page_serve(httpd_req_t *req);

/**
 * @brief Register chat page and API handlers on the HTTP server
 *
 * Initializes the mesh chat system and registers:
 * - GET  /api/chat/messages
 * - GET  /api/chat/session
 * - POST /api/chat/send
 * - POST /api/chat/send-file
 * - POST /api/chat/client
 *
 * @param server HTTP server handle
 * @return ESP_OK on success
 */
esp_err_t chat_page_register_handlers(httpd_handle_t server);

#ifdef __cplusplus
}
#endif

#endif // GEOGRAM_CHAT_PAGE_H
