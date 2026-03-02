#include "station.h"
#include "json_utils.h"
#include "nostr_keys.h"
#include "app_config.h"

#if BOARD_MODEL == MODEL_ESP32S3_EPAPER_1IN54
#include "tiles.h"
#endif

#if BOARD_MODEL == MODEL_KV4P
#include "model_init.h"
#include "sa818_radio.h"
#endif

#ifdef CONFIG_GEOGRAM_MESH_ENABLED
#include "mesh_bsp.h"
#endif

#include <esp_log.h>
#include <esp_wifi.h>
#include <esp_timer.h>
#include <string.h>
#include <time.h>

static const char *TAG = "Station";

// Singleton station state
static station_state_t s_station = {0};

void station_init(void) {
    if (s_station.initialized) {
        return;
    }

    memset(&s_station, 0, sizeof(s_station));

    // Initialize NOSTR keys and derive callsign
    esp_err_t ret = nostr_keys_init();
    if (ret == ESP_OK) {
        const char *callsign = nostr_keys_get_callsign();
        if (callsign) {
            strncpy(s_station.callsign, callsign, sizeof(s_station.callsign) - 1);
            s_station.callsign[sizeof(s_station.callsign) - 1] = '\0';
        }
    } else {
        ESP_LOGE(TAG, "Failed to initialize NOSTR keys: %s", esp_err_to_name(ret));
        // Fallback to a default callsign
        strncpy(s_station.callsign, "X3XXXX", sizeof(s_station.callsign));
    }

    // Set station name
    snprintf(s_station.name, sizeof(s_station.name), "Geogram ESP32 Station");

    // Record start time
    s_station.start_time = (uint32_t)(esp_timer_get_time() / 1000000);

    // Initialize client slots
    for (int i = 0; i < STATION_MAX_CLIENTS; i++) {
        s_station.clients[i].fd = -1;
    }

    s_station.initialized = true;

    ESP_LOGI(TAG, "Station initialized: %s (%s)", s_station.name, s_station.callsign);
}

station_state_t *station_get_state(void) {
    return &s_station;
}

const char *station_get_callsign(void) {
    return s_station.callsign;
}

uint32_t station_get_uptime(void) {
    uint32_t now = (uint32_t)(esp_timer_get_time() / 1000000);
    return now - s_station.start_time;
}

uint8_t station_get_client_count(void) {
    return s_station.client_count;
}

void station_set_location(double latitude, double longitude,
                          const char *city, const char *country,
                          const char *timezone) {
    s_station.latitude = latitude;
    s_station.longitude = longitude;

    if (city && country) {
        snprintf(s_station.location, sizeof(s_station.location), "%s, %s", city, country);
    } else if (city) {
        strncpy(s_station.location, city, sizeof(s_station.location) - 1);
    } else {
        s_station.location[0] = '\0';
    }

    if (timezone) {
        strncpy(s_station.timezone, timezone, sizeof(s_station.timezone) - 1);
        s_station.timezone[sizeof(s_station.timezone) - 1] = '\0';
    }

    s_station.has_location = true;

    ESP_LOGI(TAG, "Station location updated: %s (%.4f, %.4f) TZ: %s",
             s_station.location, latitude, longitude, s_station.timezone);
}

int station_add_client(int fd) {
    // Find empty slot
    for (int i = 0; i < STATION_MAX_CLIENTS; i++) {
        if (s_station.clients[i].fd == -1) {
            station_client_t *client = &s_station.clients[i];
            memset(client, 0, sizeof(station_client_t));
            client->fd = fd;
            client->connected_at = (uint32_t)(esp_timer_get_time() / 1000000);
            client->last_activity = client->connected_at;
            client->authenticated = false;
            s_station.client_count++;

            ESP_LOGI(TAG, "Client added: fd=%d (total: %d)", fd, s_station.client_count);
            return i;
        }
    }

    ESP_LOGW(TAG, "Client rejected: max clients reached (%d)", STATION_MAX_CLIENTS);
    return -1;
}

void station_remove_client(int fd) {
    for (int i = 0; i < STATION_MAX_CLIENTS; i++) {
        if (s_station.clients[i].fd == fd) {
            ESP_LOGI(TAG, "Client removed: fd=%d callsign=%s",
                     fd, s_station.clients[i].callsign[0] ? s_station.clients[i].callsign : "(none)");
            s_station.clients[i].fd = -1;
            s_station.client_count--;
            return;
        }
    }
}

station_client_t *station_find_client(int fd) {
    for (int i = 0; i < STATION_MAX_CLIENTS; i++) {
        if (s_station.clients[i].fd == fd) {
            return &s_station.clients[i];
        }
    }
    return NULL;
}

station_client_t *station_find_client_by_callsign(const char *callsign) {
    for (int i = 0; i < STATION_MAX_CLIENTS; i++) {
        if (s_station.clients[i].fd != -1 &&
            strcmp(s_station.clients[i].callsign, callsign) == 0) {
            return &s_station.clients[i];
        }
    }
    return NULL;
}

void station_client_set_info(station_client_t *client, const char *callsign,
                             const char *nickname, const char *platform) {
    if (!client) return;

    if (callsign) {
        strncpy(client->callsign, callsign, STATION_CALLSIGN_LEN - 1);
        client->callsign[STATION_CALLSIGN_LEN - 1] = '\0';
    }
    if (nickname) {
        strncpy(client->nickname, nickname, STATION_NICKNAME_LEN - 1);
        client->nickname[STATION_NICKNAME_LEN - 1] = '\0';
    }
    if (platform) {
        strncpy(client->platform, platform, STATION_PLATFORM_LEN - 1);
        client->platform[STATION_PLATFORM_LEN - 1] = '\0';
    }

    client->authenticated = true;
    station_client_activity(client);

    ESP_LOGI(TAG, "Client authenticated: %s (%s) on %s",
             client->callsign, client->nickname, client->platform);
}

void station_client_activity(station_client_t *client) {
    if (client) {
        client->last_activity = (uint32_t)(esp_timer_get_time() / 1000000);
    }
}

size_t station_build_status_json(char *buffer, size_t size) {
    geo_json_builder_t builder;
    geo_json_init(&builder, buffer, size);

    geo_json_object_start(&builder);

    // Core identification (matching p2p.radio format)
    geo_json_add_string(&builder, "service", "Geogram Station Server");
    geo_json_add_string(&builder, "name", s_station.name);
    geo_json_add_string(&builder, "version", STATION_VERSION);
    geo_json_add_string(&builder, "callsign", s_station.callsign);
    geo_json_add_string(&builder, "description", "Geogram ESP32 Station");
    geo_json_add_string(&builder, "platform", "esp32");

    // Station status
    geo_json_add_bool(&builder, "station_mode", true);
    geo_json_add_uint(&builder, "uptime", station_get_uptime());
    geo_json_add_int(&builder, "connected_devices", s_station.client_count);

    // Location data
    if (s_station.has_location) {
        geo_json_add_string(&builder, "location", s_station.location);
        geo_json_add_double(&builder, "latitude", s_station.latitude, 6);
        geo_json_add_double(&builder, "longitude", s_station.longitude, 6);
        geo_json_add_string(&builder, "timezone", s_station.timezone);
    }

    // Tile server (available when SD card is present)
#if BOARD_MODEL == MODEL_ESP32S3_EPAPER_1IN54
    bool tile_available = tiles_is_available();
    geo_json_add_bool(&builder, "tile_server", tile_available);
    geo_json_add_bool(&builder, "osm_fallback", !tile_available);
    geo_json_add_uint(&builder, "cache_size", tile_available ? tiles_get_cache_count() : 0);
    geo_json_add_uint(&builder, "cache_size_bytes", tile_available ? tiles_get_cache_size() : 0);
#else
    geo_json_add_bool(&builder, "tile_server", false);
    geo_json_add_bool(&builder, "osm_fallback", true);
    geo_json_add_uint(&builder, "cache_size", 0);
    geo_json_add_uint(&builder, "cache_size_bytes", 0);
#endif

    // Features
#if BOARD_MODEL == MODEL_KV4P
    {
        sa818_radio_handle_t _radio = model_get_sa818_radio();
        geo_json_add_bool(&builder, "enable_aprs", _radio ? sa818_radio_is_powered(_radio) : false);
    }
#else
    geo_json_add_bool(&builder, "enable_aprs", false);
#endif
    geo_json_add_int(&builder, "chat_rooms", 0);

    // Network ports
    geo_json_add_int(&builder, "http_port", 80);
    geo_json_add_bool(&builder, "https_enabled", false);
    geo_json_add_int(&builder, "https_port", 0);
    geo_json_add_bool(&builder, "https_running", false);

    // Mesh networking status
#ifdef CONFIG_GEOGRAM_MESH_ENABLED
    geo_json_add_bool(&builder, "mesh_enabled", true);
    geo_json_add_bool(&builder, "mesh_connected", geogram_mesh_is_connected());
    geo_json_add_bool(&builder, "mesh_is_root", geogram_mesh_is_root());
    geo_json_add_int(&builder, "mesh_layer", geogram_mesh_get_layer());
    geo_json_add_int(&builder, "mesh_nodes", geogram_mesh_get_node_count());
#else
    geo_json_add_bool(&builder, "mesh_enabled", false);
#endif

    geo_json_object_end(&builder);

    return geo_json_get_length(&builder);
}

size_t station_build_hello_ack_json(char *buffer, size_t size, bool success, const char *message) {
    geo_json_builder_t builder;
    geo_json_init(&builder, buffer, size);

    geo_json_object_start(&builder);
    geo_json_add_string(&builder, "type", "hello_ack");
    geo_json_add_bool(&builder, "success", success);
    geo_json_add_string(&builder, "station_id", s_station.callsign);
    geo_json_add_string(&builder, "message", message ? message : "Welcome to Geogram ESP32 Station");
    geo_json_add_string(&builder, "version", STATION_VERSION);
    geo_json_object_end(&builder);

    return geo_json_get_length(&builder);
}

size_t station_build_pong_json(char *buffer, size_t size) {
    geo_json_builder_t builder;
    geo_json_init(&builder, buffer, size);

    // Get current time in milliseconds
    int64_t timestamp = esp_timer_get_time() / 1000;

    geo_json_object_start(&builder);
    geo_json_add_string(&builder, "type", "PONG");
    geo_json_add_int64(&builder, "timestamp", timestamp);
    geo_json_object_end(&builder);

    return geo_json_get_length(&builder);
}

void station_foreach_client(station_client_callback_t callback, void *ctx) {
    for (int i = 0; i < STATION_MAX_CLIENTS; i++) {
        if (s_station.clients[i].fd != -1 && s_station.clients[i].authenticated) {
            callback(&s_station.clients[i], ctx);
        }
    }
}
