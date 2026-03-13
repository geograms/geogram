#include <stdio.h>
#include <string.h>
#include "wifi_bsp.h"
#include "esp_wifi.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "nvs_flash.h"
#include "nvs.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_timer.h"

static const char *TAG = "wifi_bsp";

static geogram_wifi_status_t s_wifi_status = GEOGRAM_WIFI_STATUS_DISCONNECTED;
static geogram_wifi_event_cb_t s_sta_callback = NULL;
static geogram_wifi_event_cb_t s_ap_callback = NULL;
static esp_netif_t *s_sta_netif = NULL;
static esp_netif_t *s_ap_netif = NULL;
static uint32_t s_current_ip = 0;
static bool s_initialized = false;
static bool s_ap_active = false;
static bool s_sta_connecting = false;  // True when STA mode is active and should reconnect
static int s_retry_count = 0;
static const int MAX_RETRY_COUNT = 10;  // Max retries before giving up
static esp_timer_handle_t s_reconnect_timer = NULL;

static void reconnect_timer_cb(void *arg)
{
    (void)arg;
    esp_wifi_connect();
}

static void wifi_event_handler(void *arg, esp_event_base_t event_base,
                               int32_t event_id, void *event_data)
{
    if (event_base == WIFI_EVENT) {
        switch (event_id) {
            case WIFI_EVENT_STA_START:
                ESP_LOGI(TAG, "WiFi STA started, connecting...");
                s_wifi_status = GEOGRAM_WIFI_STATUS_CONNECTING;
                s_sta_connecting = true;
                s_retry_count = 0;
                esp_wifi_connect();
                break;

            case WIFI_EVENT_STA_CONNECTED:
                ESP_LOGI(TAG, "WiFi connected to AP");
                s_wifi_status = GEOGRAM_WIFI_STATUS_CONNECTED;
                s_retry_count = 0;  // Reset retry count on successful connection
                if (s_sta_callback) {
                    s_sta_callback(GEOGRAM_WIFI_STATUS_CONNECTED, event_data);
                }
                break;

            case WIFI_EVENT_STA_DISCONNECTED: {
                wifi_event_sta_disconnected_t *event = (wifi_event_sta_disconnected_t *)event_data;
                ESP_LOGW(TAG, "WiFi disconnected, reason: %d", event->reason);
                s_wifi_status = GEOGRAM_WIFI_STATUS_DISCONNECTED;
                s_current_ip = 0;

                // Auto-reconnect if we were in STA mode and haven't exceeded retries
                if (s_sta_connecting) {
                    // Reason 201 = NO_AP_FOUND — network not in range, don't retry
                    if (event->reason == 201) {
                        ESP_LOGW(TAG, "Network not found (reason 201), giving up STA");
                        s_sta_connecting = false;
                        if (s_sta_callback) {
                            s_sta_callback(GEOGRAM_WIFI_STATUS_DISCONNECTED, event_data);
                        }
                    } else {
                        s_retry_count++;
                        if (s_retry_count <= MAX_RETRY_COUNT) {
                            ESP_LOGI(TAG, "Reconnecting... (attempt %d/%d)", s_retry_count, MAX_RETRY_COUNT);
                            // Schedule reconnect via timer — never block the event handler
                            if (s_reconnect_timer) {
                                esp_timer_start_once(s_reconnect_timer, 1000000); // 1s
                            }
                        } else {
                            ESP_LOGE(TAG, "Max retry attempts reached, giving up");
                            s_sta_connecting = false;
                            if (s_sta_callback) {
                                s_sta_callback(GEOGRAM_WIFI_STATUS_DISCONNECTED, event_data);
                            }
                        }
                    }
                } else {
                    // Not in STA mode or AP is active, just notify
                    if (s_sta_callback) {
                        s_sta_callback(GEOGRAM_WIFI_STATUS_DISCONNECTED, event_data);
                    }
                }
                break;
            }

            case WIFI_EVENT_AP_START:
                ESP_LOGI(TAG, "WiFi AP started");
                s_ap_active = true;
                s_wifi_status = GEOGRAM_WIFI_STATUS_AP_STARTED;
                if (s_ap_callback) {
                    s_ap_callback(GEOGRAM_WIFI_STATUS_AP_STARTED, event_data);
                }
                break;

            case WIFI_EVENT_AP_STOP:
                ESP_LOGI(TAG, "WiFi AP stopped");
                s_ap_active = false;
                break;

            case WIFI_EVENT_AP_STACONNECTED:
                ESP_LOGI(TAG, "Station connected to AP");
                if (s_ap_callback) {
                    s_ap_callback(GEOGRAM_WIFI_STATUS_AP_STACONNECTED, event_data);
                }
                break;

            case WIFI_EVENT_AP_STADISCONNECTED:
                ESP_LOGI(TAG, "Station disconnected from AP");
                break;

            default:
                break;
        }
    } else if (event_base == IP_EVENT) {
        if (event_id == IP_EVENT_STA_GOT_IP) {
            ip_event_got_ip_t *event = (ip_event_got_ip_t *)event_data;
            s_current_ip = event->ip_info.ip.addr;
            ESP_LOGI(TAG, "Got IP: " IPSTR, IP2STR(&event->ip_info.ip));
            s_wifi_status = GEOGRAM_WIFI_STATUS_GOT_IP;
            if (s_sta_callback) {
                s_sta_callback(GEOGRAM_WIFI_STATUS_GOT_IP, event_data);
            }
        }
    }
}

esp_err_t geogram_wifi_init(void)
{
    if (s_initialized) {
        ESP_LOGW(TAG, "WiFi already initialized");
        return ESP_OK;
    }

    // Initialize NVS (may already be initialized by model_init)
    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES) {
        // Only erase if truly no free pages, not on version mismatch
        ESP_LOGW(TAG, "NVS no free pages, erasing...");
        ESP_ERROR_CHECK(nvs_flash_erase());
        ret = nvs_flash_init();
    }
    // Ignore already initialized error - this is expected
    if (ret != ESP_OK && ret != ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_LOGE(TAG, "NVS init failed: %s", esp_err_to_name(ret));
        return ret;
    }

    // Initialize TCP/IP stack
    ret = esp_netif_init();
    if (ret != ESP_OK && ret != ESP_ERR_INVALID_STATE) {
        ESP_LOGE(TAG, "esp_netif_init failed: %s", esp_err_to_name(ret));
        return ret;
    }

    // Create default event loop
    ret = esp_event_loop_create_default();
    if (ret != ESP_OK && ret != ESP_ERR_INVALID_STATE) {
        ESP_LOGE(TAG, "esp_event_loop_create_default failed: %s", esp_err_to_name(ret));
        return ret;
    }

    // Create default WiFi station (or reuse if already created by mesh)
    s_sta_netif = esp_netif_get_handle_from_ifkey("WIFI_STA_DEF");
    if (!s_sta_netif) {
        s_sta_netif = esp_netif_create_default_wifi_sta();
    } else {
        ESP_LOGI(TAG, "Reusing existing WIFI_STA_DEF netif");
    }

    // Initialize WiFi (may already be initialized by mesh)
    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ret = esp_wifi_init(&cfg);
    if (ret != ESP_OK && ret != ESP_ERR_WIFI_INIT_STATE) {
        ESP_LOGE(TAG, "esp_wifi_init failed: %s", esp_err_to_name(ret));
        return ret;
    }
    if (ret == ESP_ERR_WIFI_INIT_STATE) {
        ESP_LOGI(TAG, "WiFi already initialized, reusing");
    }

    // Register event handlers
    ESP_ERROR_CHECK(esp_event_handler_instance_register(WIFI_EVENT, ESP_EVENT_ANY_ID,
                                                        &wifi_event_handler, NULL, NULL));
    ESP_ERROR_CHECK(esp_event_handler_instance_register(IP_EVENT, IP_EVENT_STA_GOT_IP,
                                                        &wifi_event_handler, NULL, NULL));

    // Create one-shot timer for non-blocking STA reconnect
    const esp_timer_create_args_t timer_args = {
        .callback = reconnect_timer_cb,
        .name = "wifi_reconn",
    };
    esp_timer_create(&timer_args, &s_reconnect_timer);

    s_initialized = true;
    ESP_LOGI(TAG, "WiFi initialized");
    return ESP_OK;
}

esp_err_t geogram_wifi_deinit(void)
{
    if (!s_initialized) {
        return ESP_OK;
    }

    esp_wifi_stop();
    esp_wifi_deinit();

    if (s_sta_netif) {
        esp_netif_destroy_default_wifi(s_sta_netif);
        s_sta_netif = NULL;
    }

    s_initialized = false;
    s_wifi_status = GEOGRAM_WIFI_STATUS_DISCONNECTED;
    s_current_ip = 0;

    return ESP_OK;
}

esp_err_t geogram_wifi_connect(const geogram_wifi_config_t *config)
{
    if (!s_initialized) {
        ESP_LOGE(TAG, "WiFi not initialized");
        return ESP_ERR_INVALID_STATE;
    }

    if (config == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    s_sta_callback = config->callback;

    wifi_config_t wifi_config = {0};
    strncpy((char *)wifi_config.sta.ssid, config->ssid, sizeof(wifi_config.sta.ssid) - 1);
    strncpy((char *)wifi_config.sta.password, config->password, sizeof(wifi_config.sta.password) - 1);

    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &wifi_config));
    ESP_ERROR_CHECK(esp_wifi_start());

    ESP_LOGI(TAG, "Connecting to SSID: %s", config->ssid);
    return ESP_OK;
}

esp_err_t geogram_wifi_disconnect(void)
{
    if (!s_initialized) {
        return ESP_ERR_INVALID_STATE;
    }

    s_sta_connecting = false;  // Don't auto-reconnect after explicit disconnect
    esp_err_t ret = esp_wifi_disconnect();
    s_wifi_status = GEOGRAM_WIFI_STATUS_DISCONNECTED;
    s_current_ip = 0;
    return ret;
}

geogram_wifi_status_t geogram_wifi_get_status(void)
{
    return s_wifi_status;
}

esp_err_t geogram_wifi_get_ip(char *ip_str)
{
    if (ip_str == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    if (s_current_ip == 0) {
        ip_str[0] = '\0';
        return ESP_ERR_INVALID_STATE;
    }

    sprintf(ip_str, "%d.%d.%d.%d",
            (uint8_t)(s_current_ip),
            (uint8_t)(s_current_ip >> 8),
            (uint8_t)(s_current_ip >> 16),
            (uint8_t)(s_current_ip >> 24));

    return ESP_OK;
}

esp_err_t geogram_wifi_start_ap(const geogram_wifi_ap_config_t *config)
{
    if (!s_initialized) {
        ESP_LOGE(TAG, "WiFi not initialized");
        return ESP_ERR_INVALID_STATE;
    }

    if (config == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    // Reuse existing AP netif if already created (e.g., by mesh), otherwise create new
    if (s_ap_netif == NULL) {
        s_ap_netif = esp_netif_get_handle_from_ifkey("WIFI_AP_DEF");
        if (s_ap_netif) {
            ESP_LOGI(TAG, "Reusing existing WIFI_AP_DEF netif");
        } else {
            s_ap_netif = esp_netif_create_default_wifi_ap();
            ESP_LOGI(TAG, "Created new WIFI_AP_DEF netif");
        }
    }

    s_ap_callback = config->callback;

    wifi_config_t wifi_config = {0};
    strncpy((char *)wifi_config.ap.ssid, config->ssid, sizeof(wifi_config.ap.ssid) - 1);
    wifi_config.ap.ssid_len = strlen(config->ssid);
    strncpy((char *)wifi_config.ap.password, config->password, sizeof(wifi_config.ap.password) - 1);
    wifi_config.ap.channel = config->channel > 0 ? config->channel : 1;
    wifi_config.ap.max_connection = config->max_connections > 0 ? config->max_connections : 4;
    wifi_config.ap.authmode = strlen(config->password) > 0 ? WIFI_AUTH_WPA2_PSK : WIFI_AUTH_OPEN;

    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_AP));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_AP, &wifi_config));
    ESP_ERROR_CHECK(esp_wifi_start());

    // Set maximum TX power (80 = 20 dBm in 0.25 dBm units)
    esp_wifi_set_max_tx_power(80);
    int8_t actual_power = 0;
    esp_wifi_get_max_tx_power(&actual_power);
    ESP_LOGI(TAG, "WiFi AP started - SSID: %s, Channel: %d, TX power: %.1f dBm",
             config->ssid, wifi_config.ap.channel, actual_power * 0.25f);

    return ESP_OK;
}

esp_err_t geogram_wifi_stop_ap(void)
{
    if (!s_initialized) {
        return ESP_ERR_INVALID_STATE;
    }

    esp_wifi_stop();
    s_ap_active = false;
    s_ap_callback = NULL;
    s_sta_connecting = false;  // Reset STA state when stopping AP

    ESP_LOGI(TAG, "WiFi AP stopped");
    return ESP_OK;
}

bool geogram_wifi_is_ap_active(void)
{
    return s_ap_active;
}

esp_err_t geogram_wifi_get_ap_ip(char *ip_str)
{
    if (ip_str == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    if (s_ap_netif == NULL) {
        ip_str[0] = '\0';
        return ESP_ERR_INVALID_STATE;
    }

    esp_netif_ip_info_t ip_info;
    esp_err_t ret = esp_netif_get_ip_info(s_ap_netif, &ip_info);
    if (ret != ESP_OK) {
        ip_str[0] = '\0';
        return ret;
    }

    sprintf(ip_str, IPSTR, IP2STR(&ip_info.ip));
    return ESP_OK;
}

esp_err_t geogram_wifi_get_ap_ip_addr(uint32_t *ip_addr)
{
    if (ip_addr == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    if (s_ap_netif == NULL) {
        *ip_addr = 0;
        return ESP_ERR_INVALID_STATE;
    }

    esp_netif_ip_info_t ip_info;
    esp_err_t ret = esp_netif_get_ip_info(s_ap_netif, &ip_info);
    if (ret != ESP_OK) {
        *ip_addr = 0;
        return ret;
    }

    *ip_addr = ip_info.ip.addr;
    return ESP_OK;
}

esp_err_t geogram_wifi_load_credentials(char *ssid, char *password)
{
    if (ssid == NULL || password == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    nvs_handle_t nvs;
    esp_err_t err = nvs_open("wifi_config", NVS_READONLY, &nvs);
    if (err != ESP_OK) {
        return err;
    }

    size_t ssid_len = 33;
    size_t pass_len = 65;

    err = nvs_get_str(nvs, "ssid", ssid, &ssid_len);
    if (err != ESP_OK) {
        nvs_close(nvs);
        return err;
    }

    err = nvs_get_str(nvs, "password", password, &pass_len);
    if (err != ESP_OK) {
        // Password is optional for open networks
        password[0] = '\0';
    }

    nvs_close(nvs);
    ESP_LOGI(TAG, "Loaded WiFi credentials for SSID: %s", ssid);
    return ESP_OK;
}

esp_err_t geogram_wifi_connect_sta(const char *ssid, const char *password)
{
    if (!s_initialized) {
        ESP_LOGE(TAG, "WiFi not initialized");
        return ESP_ERR_INVALID_STATE;
    }
    if (ssid == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    ESP_LOGI(TAG, "Connecting STA to %s (keeping AP active)", ssid);

    // Disconnect any active STA connection (no-op if not connected)
    esp_wifi_disconnect();

    // Switch to APSTA mode without stopping the driver — this keeps the AP
    // and its DHCP server running uninterrupted.
    wifi_mode_t current_mode;
    esp_wifi_get_mode(&current_mode);
    if (current_mode != WIFI_MODE_APSTA) {
        esp_err_t err = esp_wifi_set_mode(WIFI_MODE_APSTA);
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "Failed to set APSTA mode: %s", esp_err_to_name(err));
            return err;
        }
        // Restart DHCP server — mode switch can leave it in a bad state
        if (s_ap_netif) {
            esp_netif_dhcps_stop(s_ap_netif);
            esp_netif_dhcps_start(s_ap_netif);
            ESP_LOGI(TAG, "DHCP server restarted after APSTA switch");
        }
    }

    wifi_config_t sta_cfg = {0};
    strncpy((char *)sta_cfg.sta.ssid, ssid, sizeof(sta_cfg.sta.ssid) - 1);
    if (password != NULL) {
        strncpy((char *)sta_cfg.sta.password, password, sizeof(sta_cfg.sta.password) - 1);
    }

    esp_err_t err = esp_wifi_set_config(WIFI_IF_STA, &sta_cfg);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Failed to set STA config: %s", esp_err_to_name(err));
        return err;
    }

    // Mark STA as connecting so the event handler will auto-reconnect
    s_sta_connecting = true;
    s_retry_count = 0;

    // If the mode changed (AP → APSTA), WIFI_EVENT_STA_START fires and the
    // event handler calls esp_wifi_connect().  If we were already in APSTA
    // mode, STA_START won't fire so we must connect explicitly.
    if (current_mode == WIFI_MODE_APSTA) {
        err = esp_wifi_connect();
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "Failed to connect: %s", esp_err_to_name(err));
            s_sta_connecting = false;
            return err;
        }
    }

    return ESP_OK;
}
