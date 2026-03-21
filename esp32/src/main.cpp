#include <stdio.h>
#include <string.h>
#include <time.h>
#include <sys/time.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"
#include "esp_sntp.h"
#include "app_config.h"

// Station API
#include "station.h"
#include "geogram_ble.h"

// NOSTR keys (for callsign)
#include "nostr_keys.h"

// Serial console
#include "console.h"

// Telnet server
#include "telnet_server.h"

// SSH server
#include "geogram_ssh.h"

// DNS server for captive portal
#include "dns_server.h"

// IP geolocation for timezone
#include "geoloc.h"

// Plain log helper (no ANSI)
#include "geogram_log_plain.h"

// Mesh networking (optional, enabled via CONFIG_GEOGRAM_MESH_ENABLED)
#ifdef CONFIG_GEOGRAM_MESH_ENABLED
#include "mesh_bsp.h"
#include "esp_netif.h"
#include "lwip/ip4_addr.h"
#endif

// Include board-specific model initialization
#if BOARD_MODEL == MODEL_ESP32S3_EPAPER_1IN54
    #include "model_config.h"
    #include "model_init.h"
    #include "board_power.h"
    #include "button_bsp.h"
    #include "epaper_1in54.h"
    #include "shtc3.h"
    #include "pcf85063.h"
    #include "lvgl_port.h"
    #include "geogram_ui.h"
    #include "wifi_bsp.h"
    #include "http_server.h"
    #include "sdcard.h"
    #include "tiles.h"
    #include "updates.h"
    #include "ftp_server.h"
#elif BOARD_MODEL == MODEL_ESP32C3_MINI
    #include "model_config.h"
    #include "model_init.h"
    #include "wifi_bsp.h"
    #include "http_server.h"
    #if HAS_LED
    #include "led_bsp.h"
    #endif
#elif BOARD_MODEL == MODEL_KV4P
    #include "model_config.h"
    #include "model_init.h"
    #include "wifi_bsp.h"
    #include "esp_wifi.h"
    #include "http_server.h"
    #include "ble_aprs.h"
    #include "radio_tx.h"
    #if HAS_LED
    #include "led_bsp.h"
    #endif
#elif BOARD_MODEL == MODEL_TDONGLE_S3
    #include "model_config.h"
    #include "model_init.h"
    #include "tdongle_ui.h"
    #include "ble_hello.h"
    #include "nostr_keys.h"
    #include "wifi_bsp.h"
    #include "http_server.h"
#elif BOARD_MODEL == MODEL_HELTEC_V3
    #include "model_config.h"
    #include "model_init.h"
    #include "ssd1306.h"
    #include "sx1262.h"
    #include "wifi_bsp.h"
    #include "http_server.h"
#elif BOARD_MODEL == MODEL_HELTEC_V2 || BOARD_MODEL == MODEL_HELTEC_V1
    #include "model_config.h"
    #include "model_init.h"
    #include "ssd1306.h"
    #include "sx1276.h"
    #include "wifi_bsp.h"
    #include "http_server.h"
#elif BOARD_MODEL == MODEL_ESP32_GENERIC
    #include "model_config.h"
    #include "model_init.h"
    #include "wifi_bsp.h"
    #include "http_server.h"
#else
    #error "Invalid BOARD_MODEL defined!"
#endif

static const char *TAG = "geogram";

// ============================================================================
// Mesh Networking Support (optional)
// ============================================================================

#ifdef CONFIG_GEOGRAM_MESH_ENABLED
static bool s_mesh_mode = false;
static bool s_mesh_connected = false;
static bool s_mesh_services_started = false;
static bool s_http_server_started = false;  // Track if HTTP server started early

static esp_err_t start_dns_for_softap(const char *context)
{
    esp_netif_t *ap_netif = esp_netif_get_handle_from_ifkey("WIFI_AP_DEF");
    if (!ap_netif) {
        ESP_LOGW(TAG, "DNS start skipped (%s): SoftAP netif not available", context);
        return ESP_ERR_INVALID_STATE;
    }

    esp_netif_ip_info_t ip_info;
    esp_err_t ip_ret = esp_netif_get_ip_info(ap_netif, &ip_info);
    if (ip_ret != ESP_OK || ip_info.ip.addr == 0) {
        ESP_LOGW(TAG, "DNS start skipped (%s): SoftAP IP not ready (%s)",
                 context,
                 ip_ret == ESP_OK ? "invalid state" : esp_err_to_name(ip_ret));
        return ip_ret == ESP_OK ? ESP_ERR_INVALID_STATE : ip_ret;
    }

    esp_err_t dns_ret = dns_server_start(ip_info.ip.addr);
    if (dns_ret != ESP_OK) {
        ESP_LOGW(TAG, "DNS server start failed (%s): %s", context, esp_err_to_name(dns_ret));
    }
    return dns_ret;
}

static void start_mesh_services(void)
{
    if (s_mesh_services_started) {
        return;
    }

    const char *ap_ssid = "geogram";
    esp_err_t ap_ret = geogram_mesh_start_external_ap(
        ap_ssid, "", CONFIG_GEOGRAM_MESH_EXTERNAL_AP_MAX_CONN);
    if (ap_ret != ESP_OK) {
        ESP_LOGW(TAG, "Deferring mesh services, external AP not ready: %s", esp_err_to_name(ap_ret));
        return;
    }
    ESP_LOGI(TAG, "External AP: %s (open)", ap_ssid);

    // Always derive DNS response IP from the live SoftAP netif.
    start_dns_for_softap("mesh services");

    // Only start HTTP server if not already started early
    if (!s_http_server_started) {
        station_init();
        esp_err_t http_ret = http_server_start_ex(NULL, true);
        if (http_ret == ESP_OK) {
            s_http_server_started = true;
            ESP_LOGI(TAG, "Station API started on mesh node");
        } else {
            ESP_LOGE(TAG, "Failed to start Station API on mesh node: %s", esp_err_to_name(http_ret));
        }
    } else {
        ESP_LOGI(TAG, "HTTP server already running (started early)");
    }

#if BOARD_MODEL == MODEL_KV4P
    // KV4P runs mesh + BLE + SA818 APRS on no-PSRAM ESP32; keep telnet off by default
    // to preserve heap for radio and BLE operation.
    ESP_LOGI(TAG, "Telnet auto-start disabled on KV4P (serial console remains available)");
#else
    if (telnet_server_start(TELNET_DEFAULT_PORT) == ESP_OK) {
        ESP_LOGI(TAG, "Telnet server started on port %d", TELNET_DEFAULT_PORT);
    }
#endif

    s_mesh_services_started = true;
}

/**
 * @brief Mesh event callback
 */
static void mesh_event_cb(geogram_mesh_event_t event, void *event_data)
{
    switch (event) {
        case GEOGRAM_MESH_EVENT_CONNECTED:
            ESP_LOGI(TAG, "Mesh connected, layer: %d", geogram_mesh_get_layer());
            ESP_LOGI(TAG, "Mesh nodes: %zu, role: %s",
                     geogram_mesh_get_node_count(),
                     geogram_mesh_is_root() ? "root" : "child");
            s_mesh_connected = true;

#if (BOARD_MODEL == MODEL_ESP32C3_MINI || BOARD_MODEL == MODEL_KV4P) && HAS_LED
            // System OK - solid green LED
            led_set_state(LED_STATE_OK);
#endif

            start_mesh_services();

            // Enable IP bridging
            geogram_mesh_enable_bridge();

            break;

        case GEOGRAM_MESH_EVENT_DISCONNECTED:
            ESP_LOGW(TAG, "Mesh disconnected");
            ESP_LOGI(TAG, "Mesh nodes now: %zu", geogram_mesh_get_node_count());
            s_mesh_connected = false;

#if (BOARD_MODEL == MODEL_ESP32C3_MINI || BOARD_MODEL == MODEL_KV4P) && HAS_LED
            // Error state - blinking red LED
            led_set_state(LED_STATE_ERROR);
#endif

            // Stop services
            telnet_server_stop();
            http_server_stop();
            s_http_server_started = false;
            geogram_mesh_disable_bridge();
            geogram_mesh_stop_external_ap();
            s_mesh_services_started = false;
            break;

        case GEOGRAM_MESH_EVENT_ROOT_CHANGED:
            ESP_LOGI(TAG, "Root status changed: %s",
                     geogram_mesh_is_root() ? "I am ROOT" : "I am CHILD");
            break;

        case GEOGRAM_MESH_EVENT_EXTERNAL_STA_CONNECTED:
            ESP_LOGI(TAG, "Phone connected to mesh AP (%d total)",
                     geogram_mesh_get_external_ap_client_count());
            break;

        case GEOGRAM_MESH_EVENT_EXTERNAL_STA_DISCONNECTED:
            ESP_LOGI(TAG, "Phone disconnected from mesh AP (%d remaining)",
                     geogram_mesh_get_external_ap_client_count());
            break;

        default:
            break;
    }
}

/**
 * @brief Start mesh networking mode
 */
static void start_mesh_mode(void)
{
    ESP_LOGI(TAG, "Starting mesh networking mode");

    // Initialize mesh subsystem
    esp_err_t ret = geogram_mesh_init();
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Mesh init failed: %s", esp_err_to_name(ret));
#if (BOARD_MODEL == MODEL_ESP32C3_MINI || BOARD_MODEL == MODEL_KV4P) && HAS_LED
        led_set_state(LED_STATE_ERROR);
#endif
        return;
    }

    // Configure mesh network
    geogram_mesh_config_t mesh_cfg = {
        .mesh_id = {'g', 'e', 'o', 'm', 's', 'h'},  // "geomsh"
        .password = "",
        .channel = CONFIG_GEOGRAM_MESH_CHANNEL,
        .max_layer = CONFIG_GEOGRAM_MESH_MAX_LAYER,
        .allow_root = true,
        .callback = mesh_event_cb
    };

    ret = geogram_mesh_start(&mesh_cfg);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Mesh start failed: %s", esp_err_to_name(ret));
#if (BOARD_MODEL == MODEL_ESP32C3_MINI || BOARD_MODEL == MODEL_KV4P) && HAS_LED
        led_set_state(LED_STATE_ERROR);
#endif
        return;
    }

    s_mesh_mode = true;
    ESP_LOGI(TAG, "Mesh mode started, scanning for network...");

    // Mesh CONNECTED event can arrive before geogram_mesh_start() finishes.
    // If services were deferred, start them now that mesh startup returned.
    if (s_mesh_connected && !s_mesh_services_started) {
        start_mesh_services();
    }

    // Start HTTP server immediately for SoftAP clients
    // (Don't wait for mesh NODE_JOIN event which may never fire for root-only nodes)
    station_init();

    // Log the SoftAP IP for debugging and start DNS server for captive portal
    esp_netif_t *ap_netif = esp_netif_get_handle_from_ifkey("WIFI_AP_DEF");
    if (ap_netif) {
        esp_netif_ip_info_t ip_info;
        if (esp_netif_get_ip_info(ap_netif, &ip_info) == ESP_OK) {
            ESP_LOGI(TAG, "SoftAP IP: " IPSTR ", Gateway: " IPSTR,
                     IP2STR(&ip_info.ip), IP2STR(&ip_info.gw));

            // Start DNS server immediately for captive portal
            // All DNS queries will resolve to the SoftAP IP
            esp_err_t dns_ret = start_dns_for_softap("mesh mode early start");
            if (dns_ret == ESP_OK) {
                ESP_LOGI(TAG, "DNS server started for captive portal");
            }
        }
    } else {
        ESP_LOGW(TAG, "Could not get SoftAP netif handle");
    }

    esp_err_t http_ret = http_server_start_ex(NULL, true);
    if (http_ret == ESP_OK) {
        s_http_server_started = true;
        ESP_LOGI(TAG, "HTTP server started for SoftAP clients");
    } else {
        ESP_LOGE(TAG, "Failed to start HTTP server: %s", esp_err_to_name(http_ret));
    }

}
#endif  // CONFIG_GEOGRAM_MESH_ENABLED

// ============================================================================
// T-Dongle-S3 WiFi Support
// ============================================================================

#if BOARD_MODEL == MODEL_TDONGLE_S3

/**
 * @brief WiFi event callback for T-Dongle-S3
 */
static void tdongle_wifi_event_cb(geogram_wifi_status_t status, void *event_data)
{
    char ip_str[16];

    switch (status) {
        case GEOGRAM_WIFI_STATUS_GOT_IP:
            geogram_wifi_get_ip(ip_str);
            ESP_LOGI(TAG, "T-Dongle STA connected, IP: %s", ip_str);
            tdongle_ui_set_ip(ip_str);
            break;

        case GEOGRAM_WIFI_STATUS_DISCONNECTED:
            ESP_LOGW(TAG, "T-Dongle STA disconnected, showing AP IP");
            tdongle_ui_set_ip("192.168.4.1");
            break;

        case GEOGRAM_WIFI_STATUS_AP_STARTED:
            ESP_LOGI(TAG, "T-Dongle AP started");
            tdongle_ui_set_ip("192.168.4.1");
            break;

        default:
            break;
    }
}

/**
 * @brief WiFi credentials received via captive portal
 */
static void tdongle_wifi_config_received(const char *ssid, const char *password)
{
    ESP_LOGI(TAG, "WiFi credentials received for SSID: %s", ssid);
    geogram_wifi_connect_sta(ssid, password);
}

#endif  // BOARD_MODEL == MODEL_TDONGLE_S3

#if BOARD_MODEL == MODEL_ESP32S3_EPAPER_1IN54

// Sensor update interval (ms)
#define SENSOR_UPDATE_INTERVAL  30000
#define DISPLAY_REFRESH_INTERVAL 60000

// WiFi configuration
#define WIFI_AP_PASSWORD    ""  // Open network for easy setup
#define WIFI_AP_CHANNEL     1
#define WIFI_AP_MAX_CONN    4

static bool s_wifi_connected = false;
static char s_current_ip[16] = {0};
static bool s_ntp_synced = false;
static pcf85063_handle_t s_rtc_handle = NULL;
static bool s_ap_mode_active = false;
static TaskHandle_t s_network_services_task = NULL;
static epaper_1in54_handle_t s_display_handle = NULL;
static button_handle_t s_power_button = NULL;

// Flag to trigger shutdown from main loop (avoids blocking button callback)
static volatile bool s_shutdown_requested = false;

/**
 * @brief Perform device shutdown - clear display and enter deep sleep
 */
static void device_shutdown(void)
{
    ESP_LOGI(TAG, "Shutdown initiated - clearing display and entering deep sleep");

    // Turn on backlight so user can see the shutdown message
    board_power_backlight_on();

    // Show shutdown message
    geogram_ui_show_status("Powering off...");
    geogram_ui_refresh(false);

    // Give time for partial refresh to show the message
    vTaskDelay(pdMS_TO_TICKS(1000));

    // Now blank the e-paper display completely
    if (s_display_handle != NULL) {
        ESP_LOGI(TAG, "Blanking e-paper display...");

        // Re-initialize display for full refresh mode (needed for clean blank)
        epaper_1in54_init(s_display_handle);

        // Clear buffer to all white
        epaper_1in54_clear(s_display_handle);

        // Send to display with full refresh (this does a proper e-paper clear cycle)
        epaper_1in54_refresh(s_display_handle);

        // Wait for the e-paper refresh to complete
        vTaskDelay(pdMS_TO_TICKS(2000));

        ESP_LOGI(TAG, "Display blanked");
    }

    // Turn off backlight
    board_power_backlight_off();

    // Turn off peripherals
    board_power_epd_off();
    board_power_audio_off();

    ESP_LOGI(TAG, "Entering deep sleep - press power button to wake");

    // Enter deep sleep with power button wake-up (0 = external wake only)
    board_power_deep_sleep(0);
}

/**
 * @brief Power button event callback
 */
static void power_button_callback(gpio_num_t gpio, button_event_t event, void *user_data)
{
    switch (event) {
        case BUTTON_EVENT_LONG_PRESS:
            ESP_LOGI(TAG, "Power button long press detected - requesting shutdown");
            s_shutdown_requested = true;  // Handle in main loop to avoid blocking callback
            break;

        case BUTTON_EVENT_CLICK:
            ESP_LOGI(TAG, "Power button click - toggling backlight");
            board_power_backlight_timed(3000);  // Turn on backlight for 3 seconds
            break;

        case BUTTON_EVENT_DOUBLE_CLICK:
            ESP_LOGI(TAG, "Power button double click - force display refresh");
            geogram_ui_refresh(true);  // Full refresh
            break;

        default:
            break;
    }
}

/**
 * @brief NTP time sync notification callback
 */
static void ntp_sync_notification_cb(struct timeval *tv)
{
    ESP_LOGI(TAG, "NTP time synchronized");
    s_ntp_synced = true;

    // Get the current time
    time_t now = tv->tv_sec;
    struct tm timeinfo;
    localtime_r(&now, &timeinfo);

    ESP_LOGI(TAG, "Current time: %04d-%02d-%02d %02d:%02d:%02d",
             timeinfo.tm_year + 1900, timeinfo.tm_mon + 1, timeinfo.tm_mday,
             timeinfo.tm_hour, timeinfo.tm_min, timeinfo.tm_sec);

    // Update RTC with NTP time if RTC is available
    if (s_rtc_handle != NULL) {
        pcf85063_datetime_t datetime = {
            .year = (uint16_t)(timeinfo.tm_year + 1900),
            .month = (uint8_t)(timeinfo.tm_mon + 1),
            .day = (uint8_t)timeinfo.tm_mday,
            .hour = (uint8_t)timeinfo.tm_hour,
            .minute = (uint8_t)timeinfo.tm_min,
            .second = (uint8_t)timeinfo.tm_sec,
            .weekday = (uint8_t)timeinfo.tm_wday
        };

        if (pcf85063_set_datetime(s_rtc_handle, &datetime) == ESP_OK) {
            ESP_LOGI(TAG, "RTC updated with NTP time");
        } else {
            ESP_LOGW(TAG, "Failed to update RTC");
        }
    }
}

/**
 * @brief Initialize SNTP for time synchronization
 */
static void init_sntp(void)
{
    ESP_LOGI(TAG, "Initializing SNTP");

    esp_sntp_setoperatingmode(SNTP_OPMODE_POLL);
    esp_sntp_setservername(0, "pool.ntp.org");
    esp_sntp_setservername(1, "time.nist.gov");
    esp_sntp_set_time_sync_notification_cb(ntp_sync_notification_cb);
    esp_sntp_init();
}

/**
 * @brief Background task for network services (geolocation, NTP)
 *
 * This task runs slow network operations in the background to avoid
 * blocking the main boot process and WiFi event handlers.
 */
static void network_services_task(void *pvParameter)
{
    ESP_LOGI(TAG, "Starting network services (background)...");

    // Small delay to let WiFi stack stabilize
    vTaskDelay(pdMS_TO_TICKS(500));

    // Step 1: Fetch geolocation (sets timezone)
    ESP_LOGI(TAG, "[Background] Fetching geolocation...");
    geogram_ui_show_status("Getting location...");
    geogram_ui_refresh(false);

    geoloc_data_t geoloc;
    if (geoloc_fetch(&geoloc) == ESP_OK) {
        geoloc_apply_timezone();
        ESP_LOGI(TAG, "[Background] Location: %s, %s", geoloc.city, geoloc.country);

        // Update station with location data for API
        station_set_location(geoloc.latitude, geoloc.longitude,
                            geoloc.city, geoloc.country, geoloc.timezone);
    } else {
        ESP_LOGW(TAG, "[Background] Geolocation failed, using UTC");
        setenv("TZ", "UTC0", 1);
        tzset();
    }

    // Step 2: Initialize NTP (now that timezone is set)
    ESP_LOGI(TAG, "[Background] Initializing NTP...");
    geogram_ui_show_status("Syncing time...");
    geogram_ui_refresh(false);

    init_sntp();

    // Wait a bit for NTP to sync (non-blocking check)
    for (int i = 0; i < 10 && !s_ntp_synced; i++) {
        vTaskDelay(pdMS_TO_TICKS(500));
    }

    if (s_ntp_synced) {
        ESP_LOGI(TAG, "[Background] NTP synced successfully");
    } else {
        ESP_LOGW(TAG, "[Background] NTP sync pending (will complete in background)");
    }

    // Done - show connected status
    geogram_ui_show_status("Connected");
    geogram_ui_refresh(false);

    ESP_LOGI(TAG, "Network services initialization complete");

    // Task complete, delete self
    s_network_services_task = NULL;
    vTaskDelete(NULL);
}

// Forward declaration
static void start_ap_mode(void);

/**
 * @brief WiFi event callback
 */
static void wifi_event_cb(geogram_wifi_status_t status, void *event_data)
{
    switch (status) {
        case GEOGRAM_WIFI_STATUS_GOT_IP:
            ESP_LOGI(TAG, "WiFi connected with IP");
            s_wifi_connected = true;
            s_ap_mode_active = false;
            geogram_wifi_get_ip(s_current_ip);
            geogram_ui_update_wifi(UI_WIFI_STATUS_CONNECTED, s_current_ip, NULL);
            geogram_ui_show_status("WiFi Connected");
            geogram_ui_refresh(false);

            // Stop DNS server (used in AP mode)
            dns_server_stop();

            // Stop AP mode HTTP server and start Station API server
            http_server_stop();

            // Initialize and start Station API
            station_init();
            http_server_start_ex(NULL, true);  // Station API enabled
            ESP_LOGI(TAG, "Station API started - callsign: %s", station_get_callsign());

            // Start Telnet server for remote CLI access
            if (telnet_server_start(TELNET_DEFAULT_PORT) == ESP_OK) {
                ESP_LOGI(TAG, "Telnet server started on port %d", TELNET_DEFAULT_PORT);
            }

            // SSH server disabled for now (libssh init issues)
            // TODO: Re-enable once libssh threading is properly configured
            // if (geogram_ssh_start(GEOGRAM_SSH_DEFAULT_PORT) == ESP_OK) {
            //     ESP_LOGI(TAG, "SSH server started on port %d", GEOGRAM_SSH_DEFAULT_PORT);
            // }

            // Start update mirror polling (check GitHub every hour, first check after 1 minute)
            if (updates_is_available()) {
                updates_start_polling(60 * 60);  // 1 hour
                ESP_LOGI(TAG, "Update mirror polling started (hourly)");
            }

            // Start FTP server if SD card is mounted
            if (sdcard_is_mounted()) {
                if (ftp_server_start(FTP_DEFAULT_PORT) == ESP_OK) {
                    ESP_LOGI(TAG, "FTP server started on port %d", FTP_DEFAULT_PORT);
                }
            }

            // Start network services in background (geolocation, NTP)
            // This avoids blocking the WiFi callback with slow HTTP requests
            if (s_network_services_task == NULL) {
                xTaskCreate(network_services_task, "net_services", 4096, NULL, 3, &s_network_services_task);
            }
            break;

        case GEOGRAM_WIFI_STATUS_DISCONNECTED:
            // Note: WiFi layer now auto-reconnects up to 10 times before calling this
            ESP_LOGW(TAG, "WiFi disconnected (after retries exhausted)");
            s_wifi_connected = false;
            s_current_ip[0] = '\0';
            geogram_ui_update_wifi(UI_WIFI_STATUS_DISCONNECTED, NULL, NULL);
            geogram_ui_show_status("WiFi Failed");
            geogram_ui_refresh(false);

            // Stop Telnet server (SSH disabled)
            telnet_server_stop();
            // geogram_ssh_stop();

            // Stop FTP server
            ftp_server_stop();

            // Stop update polling
            updates_stop_polling();

            // Fall back to AP mode if not already active
            if (!s_ap_mode_active) {
                ESP_LOGW(TAG, "WiFi connection failed, starting AP mode for configuration");
                start_ap_mode();
            }
            break;

        case GEOGRAM_WIFI_STATUS_AP_STARTED: {
            ESP_LOGI(TAG, "AP mode started");
            s_ap_mode_active = true;
            geogram_wifi_get_ap_ip(s_current_ip);

            // Build AP SSID for display
            char ap_ssid[32];
            const char *callsign = nostr_keys_get_callsign();
            if (callsign && strlen(callsign) > 0) {
                snprintf(ap_ssid, sizeof(ap_ssid), "geogram-%s", callsign);
            } else {
                snprintf(ap_ssid, sizeof(ap_ssid), "geogram-setup");
            }

            geogram_ui_update_wifi(UI_WIFI_STATUS_AP_MODE, s_current_ip, ap_ssid);
            geogram_ui_show_status("Setup Mode");
            geogram_ui_refresh(false);

            // Start DNS server for captive portal (resolves callsign to AP IP)
            uint32_t ap_ip = 0;
            if (geogram_wifi_get_ap_ip_addr(&ap_ip) == ESP_OK) {
                dns_server_start(ap_ip);
            }
            break;
        }

        default:
            break;
    }
}

/**
 * @brief Callback when WiFi credentials are submitted via HTTP
 */
static void wifi_config_received(const char *ssid, const char *password)
{
    ESP_LOGI(TAG, "WiFi credentials received for SSID: %s", ssid);

    geogram_ui_show_status("Connecting...");
    geogram_ui_refresh(false);

    // Stop AP mode
    geogram_wifi_stop_ap();

    // Connect to the configured network
    geogram_wifi_config_t config = {};
    strncpy(config.ssid, ssid, sizeof(config.ssid) - 1);
    strncpy(config.password, password, sizeof(config.password) - 1);
    config.callback = wifi_event_cb;

    geogram_wifi_connect(&config);
}

/**
 * @brief Start WiFi in AP mode for configuration
 */
static void start_ap_mode(void)
{
    ESP_LOGI(TAG, "Starting AP mode for WiFi configuration");

    // Ensure station identity is available for chat/API responses
    station_init();

    // Build SSID with callsign: "geogram-X3ABCD"
    char ap_ssid[32];
    const char *callsign = nostr_keys_get_callsign();
    if (callsign && strlen(callsign) > 0) {
        snprintf(ap_ssid, sizeof(ap_ssid), "geogram-%s", callsign);
    } else {
        snprintf(ap_ssid, sizeof(ap_ssid), "geogram-setup");
    }

    geogram_wifi_ap_config_t ap_config = {};
    strncpy(ap_config.ssid, ap_ssid, sizeof(ap_config.ssid) - 1);
    strncpy(ap_config.password, WIFI_AP_PASSWORD, sizeof(ap_config.password) - 1);
    ap_config.channel = WIFI_AP_CHANNEL;
    ap_config.max_connections = WIFI_AP_MAX_CONN;
    ap_config.callback = wifi_event_cb;

    geogram_wifi_start_ap(&ap_config);

    // Start HTTP server with chat/API endpoints
    http_server_start_ex(wifi_config_received, true);
}

/**
 * @brief Try to connect with saved credentials
 */
static bool try_saved_credentials(void)
{
    char ssid[33] = {0};
    char password[65] = {0};

    if (geogram_wifi_load_credentials(ssid, password) == ESP_OK && strlen(ssid) > 0) {
        ESP_LOGI(TAG, "Found saved credentials for SSID: %s", ssid);

        geogram_ui_show_status("Connecting...");
        geogram_ui_update_wifi(UI_WIFI_STATUS_CONNECTING, NULL, ssid);
        geogram_ui_refresh(false);

        geogram_wifi_config_t config = {};
        strncpy(config.ssid, ssid, sizeof(config.ssid) - 1);
        strncpy(config.password, password, sizeof(config.password) - 1);
        config.callback = wifi_event_cb;

        geogram_wifi_connect(&config);
        return true;
    }

    return false;
}

/**
 * @brief Sensor reading task
 */
static void sensor_task(void *pvParameter)
{
    shtc3_handle_t sensor = (shtc3_handle_t)pvParameter;
    shtc3_data_t data;
    uint32_t refresh_counter = 0;
    bool first_reading = true;

    while (1) {
        if (shtc3_read(sensor, &data) == ESP_OK) {
            ESP_LOGI(TAG, "Temp: %.1f C, Humidity: %.1f %%",
                     data.temperature, data.humidity);
            geogram_ui_update_sensor(data.temperature, data.humidity);

            // Trigger immediate display update on first reading
            if (first_reading) {
                first_reading = false;
                geogram_ui_refresh(false);
            }
        } else {
            ESP_LOGW(TAG, "Failed to read sensor");
        }

        // Refresh display periodically
        refresh_counter += SENSOR_UPDATE_INTERVAL;
        if (refresh_counter >= DISPLAY_REFRESH_INTERVAL) {
            geogram_ui_refresh(false);
            refresh_counter = 0;
        }

        vTaskDelay(pdMS_TO_TICKS(SENSOR_UPDATE_INTERVAL));
    }
}

/**
 * @brief RTC and uptime update task
 */
static void rtc_task(void *pvParameter)
{
    pcf85063_handle_t rtc = (pcf85063_handle_t)pvParameter;
    pcf85063_datetime_t datetime;
    uint8_t last_minute = 255;
    uint32_t uptime_seconds = 0;
    uint32_t last_uptime_minute = 0;
    bool first_reading = true;

    while (1) {
        if (pcf85063_get_datetime(rtc, &datetime) == ESP_OK) {
            // Update time display on first read or when minute changes
            if (first_reading || datetime.minute != last_minute) {
                geogram_ui_update_time(datetime.hour, datetime.minute);
                geogram_ui_update_date(datetime.year, datetime.month, datetime.day);
                last_minute = datetime.minute;

                if (first_reading) {
                    first_reading = false;
                    geogram_ui_refresh(false);
                }
            }
        }

        // Update uptime every minute
        uptime_seconds++;
        uint32_t current_minute = uptime_seconds / 60;
        if (current_minute != last_uptime_minute) {
            geogram_ui_update_uptime(uptime_seconds);
            last_uptime_minute = current_minute;
        }

        vTaskDelay(pdMS_TO_TICKS(1000));  // Check every second
    }
}

#endif  // BOARD_MODEL == MODEL_ESP32S3_EPAPER_1IN54

// ============================================================================
// BlueAPRS bridge callbacks (KV4P + T-Dongle-S3)
// ============================================================================

#if BOARD_MODEL == MODEL_KV4P
#include "aprs_store.h"

/** BLE RX → SA818 radio TX queue */
static void kv4p_ble_aprs_rx(const char *tnc2, int rssi, void *ctx)
{
    (void)ctx;
    ESP_LOGI(TAG, "BlueAPRS RX (rssi=%d): %s", rssi, tnc2);

    /* Parse TNC2 "FROM>TO:message" into radio_tx_item_t */
    radio_tx_item_t item = {0};
    const char *gt = strchr(tnc2, '>');
    const char *colon = strchr(tnc2, ':');
    if (!gt || !colon || colon <= gt) {
        ESP_LOGW(TAG, "BlueAPRS: malformed TNC2 frame");
        return;
    }

    int from_len = gt - tnc2;
    int to_len = colon - gt - 1;
    if (from_len >= RADIO_TX_MAX_CALLSIGN) from_len = RADIO_TX_MAX_CALLSIGN - 1;
    if (to_len >= RADIO_TX_MAX_CALLSIGN) to_len = RADIO_TX_MAX_CALLSIGN - 1;

    memcpy(item.from, tnc2, from_len);
    item.from[from_len] = '\0';
    memcpy(item.to, gt + 1, to_len);
    item.to[to_len] = '\0';
    strncpy(item.message, colon + 1, RADIO_TX_MAX_MESSAGE - 1);
    item.message[RADIO_TX_MAX_MESSAGE - 1] = '\0';

    if (radio_tx_queue_send(&item)) {
        ESP_LOGI(TAG, "BlueAPRS→radio: %s -> %s", item.from, item.to);
    } else {
        ESP_LOGW(TAG, "BlueAPRS→radio: TX queue full");
    }
}

/** SA818 RX (via aprs_store) → BLE TX advertisement */
static void kv4p_aprs_to_ble(const char *from, const char *to,
                              const char *msg, void *ctx)
{
    (void)ctx;
    char tnc2[BLE_APRS_MAX_TNC2_LEN];
    int len = snprintf(tnc2, sizeof(tnc2), "%s>%s:%s", from, to, msg);
    if (len > 0 && len < (int)sizeof(tnc2)) {
        ble_aprs_advertise(tnc2, 2000);
    }
}
#endif  /* MODEL_KV4P */

#if BOARD_MODEL == MODEL_TDONGLE_S3
/* (BLE callbacks will be re-added later) */
#endif  /* MODEL_TDONGLE_S3 */

extern "C" void app_main(void)
{
    ESP_LOGI(TAG, "=====================================");
    geogram_log_plain(TAG, "  Offline-First Communication");
    geogram_log_plain(TAG, "   · · · ·   ───   · ── ·   ·");
    geogram_log_plain(TAG, "    Wi-Fi  ·  BLE  ·  NOSTR");
    ESP_LOGI(TAG, "  Geogram Firmware v%s", GEOGRAM_VERSION);
    ESP_LOGI(TAG, "  Board: %s", BOARD_NAME);
    ESP_LOGI(TAG, "  Model: %s", MODEL_NAME);
    ESP_LOGI(TAG, "=====================================");

    // Initialize board-specific hardware
    esp_err_t ret = model_init();
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Board initialization failed: %s", esp_err_to_name(ret));
        return;
    }

    ESP_LOGI(TAG, "Board initialized successfully");

#if BOARD_MODEL == MODEL_ESP32S3_EPAPER_1IN54
    // Initialize tile cache if SD card is available
    if (sdcard_is_mounted()) {
        ret = tiles_init();
        if (ret == ESP_OK) {
            ESP_LOGI(TAG, "Tile cache initialized");
        } else {
            ESP_LOGW(TAG, "Tile cache init failed: %s", esp_err_to_name(ret));
        }

        // Initialize update mirror service
        ret = updates_init();
        if (ret == ESP_OK) {
            ESP_LOGI(TAG, "Update mirror service initialized");
        } else {
            ESP_LOGW(TAG, "Update mirror init failed: %s", esp_err_to_name(ret));
        }
    }
#endif

    // Initialize serial console
    ret = console_init();
    if (ret != ESP_OK) {
        ESP_LOGW(TAG, "Failed to initialize console: %s", esp_err_to_name(ret));
    } else {
        ESP_LOGI(TAG, "Serial console initialized");
    }

#if BOARD_MODEL == MODEL_ESP32C3_MINI
    // Ensure station identity is available for BLE handshakes.
    station_init();

    ret = geogram_ble_init();
    if (ret == ESP_OK) {
        geogram_ble_start();
        ESP_LOGI(TAG, "BLE service initialized");
    } else if (ret == ESP_ERR_NOT_SUPPORTED) {
        ESP_LOGW(TAG, "BLE is disabled in this firmware configuration");
    } else {
        ESP_LOGW(TAG, "BLE init failed: %s", esp_err_to_name(ret));
    }
#elif BOARD_MODEL == MODEL_KV4P
    // KV4P: station init (BLE observer+broadcaster added after HTTP server)
    station_init();
#elif BOARD_MODEL == MODEL_TDONGLE_S3
    // T-Dongle-S3: display + BLE HELLO + WiFi AP + captive portal
    {
        st7735_handle_t lcd = model_get_lcd();
        if (lcd) {
            ret = tdongle_ui_init(lcd);
            if (ret == ESP_OK) {
                ESP_LOGI(TAG, "T-Dongle LCD UI started");
            } else {
                ESP_LOGW(TAG, "T-Dongle UI init failed: %s", esp_err_to_name(ret));
            }
        }

        // Init nostr keys (for callsign) and BLE HELLO
        nostr_keys_init();
        const char *callsign = nostr_keys_get_callsign();
        ret = ble_hello_init(callsign);
        if (ret == ESP_OK) {
            ESP_LOGI(TAG, "BLE HELLO active — callsign: %s", callsign);
        } else {
            ESP_LOGW(TAG, "BLE HELLO init failed: %s", esp_err_to_name(ret));
        }

        // Start WiFi AP (same pattern as KV4P standalone mode)
        ret = geogram_wifi_init();
        if (ret != ESP_OK) {
            ESP_LOGE(TAG, "T-Dongle WiFi init failed: %s", esp_err_to_name(ret));
        } else {
            geogram_wifi_ap_config_t ap_config = {};
            strncpy(ap_config.ssid, "geogram", sizeof(ap_config.ssid) - 1);
            ap_config.password[0] = '\0';  // Open network
            ap_config.channel = 1;
            ap_config.max_connections = 4;
            ap_config.callback = tdongle_wifi_event_cb;

            ret = geogram_wifi_start_ap(&ap_config);
            if (ret == ESP_OK) {
                ESP_LOGI(TAG, "WiFi AP started: geogram (open)");
                tdongle_ui_set_ip("192.168.4.1");

                // Auto-connect STA if saved credentials exist (5s delay)
                {
                    char saved_ssid[33] = {0};
                    char saved_pass[65] = {0};
                    if (geogram_wifi_load_credentials(saved_ssid, saved_pass) == ESP_OK
                        && strlen(saved_ssid) > 0) {
                        ESP_LOGI(TAG, "Will auto-connect to saved WiFi in 5 s: %s", saved_ssid);
                        vTaskDelay(pdMS_TO_TICKS(5000));
                        ESP_LOGI(TAG, "Auto-connecting to saved WiFi: %s", saved_ssid);
                        geogram_wifi_connect_sta(saved_ssid, saved_pass);
                    }
                }

                // DNS server for captive portal
                uint32_t ap_ip = 0;
                if (geogram_wifi_get_ap_ip_addr(&ap_ip) == ESP_OK) {
                    dns_server_start(ap_ip);
                }

                // HTTP server with WiFi config UI
                station_init();
                http_server_start_ex(tdongle_wifi_config_received, true);
                ESP_LOGI(TAG, "HTTP server + captive portal started");
            } else {
                ESP_LOGE(TAG, "Failed to start WiFi AP: %s", esp_err_to_name(ret));
            }
        }
    }
#endif

#ifdef CONFIG_GEOGRAM_MESH_ENABLED
    geogram_log_plain(TAG, "Mesh support: ENABLED");
#else
    geogram_log_plain(TAG, "Mesh support: DISABLED in this build");
#endif

#if defined(CONFIG_GEOGRAM_MESH_ENABLED) && (BOARD_MODEL == MODEL_ESP32C3_MINI)
    geogram_log_plain(TAG, "Starting mesh mode by default");
    start_mesh_mode();
#endif

#if defined(CONFIG_GEOGRAM_MESH_ENABLED) && (BOARD_MODEL == MODEL_KV4P)
    geogram_log_plain(TAG, "KV4P: mesh auto-start disabled (using standalone AP mode)");
#endif

#if defined(CONFIG_GEOGRAM_MESH_ENABLED) && (BOARD_MODEL == MODEL_TDONGLE_S3)
    geogram_log_plain(TAG, "Starting mesh mode on T-Dongle-S3");
    start_mesh_mode();
#endif

#if BOARD_MODEL == MODEL_ESP32S3_EPAPER_1IN54
    // Get hardware handles
    epaper_1in54_handle_t display = model_get_display();
    shtc3_handle_t env_sensor = model_get_env_sensor();
    pcf85063_handle_t rtc = model_get_rtc();

    // Store handles for callbacks
    s_rtc_handle = rtc;
    s_display_handle = display;

    if (display == NULL) {
        ESP_LOGE(TAG, "Failed to get display handle");
        return;
    }

    // Initialize power button for shutdown on long press
    button_config_t pwr_btn_config = {
        .gpio = BTN_PIN_POWER,
        .active_low = true,
        .debounce_ms = 30,
        .long_press_ms = 2000,  // 2 second long press for shutdown
    };
    ret = button_create(&pwr_btn_config, power_button_callback, NULL, &s_power_button);
    if (ret != ESP_OK) {
        ESP_LOGW(TAG, "Failed to create power button: %s", esp_err_to_name(ret));
    } else {
        ESP_LOGI(TAG, "Power button initialized (long press to shutdown)");
    }

    ESP_LOGI(TAG, "E-paper display: %dx%d",
             epaper_1in54_get_width(display),
             epaper_1in54_get_height(display));

    // Initialize LVGL with e-paper display
    ret = lvgl_port_init(display);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to initialize LVGL: %s", esp_err_to_name(ret));
        return;
    }

    // Initialize UI
    ret = geogram_ui_init();
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to initialize UI: %s", esp_err_to_name(ret));
        return;
    }

    // Initial display refresh
    geogram_ui_show_status("Starting...");
    geogram_ui_refresh(true);  // Full refresh on startup

    // Initialize NOSTR keys early (needed for AP SSID with callsign)
    ret = nostr_keys_init();
    if (ret != ESP_OK) {
        ESP_LOGW(TAG, "Failed to initialize NOSTR keys: %s", esp_err_to_name(ret));
    } else {
        ESP_LOGI(TAG, "Station callsign: %s", nostr_keys_get_callsign());
    }

    // Initialize WiFi
    ret = geogram_wifi_init();
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to initialize WiFi: %s", esp_err_to_name(ret));
        geogram_ui_show_status("WiFi Init Failed");
        geogram_ui_refresh(false);
    } else {
        // Try to connect with saved credentials, otherwise start AP mode
        if (!try_saved_credentials()) {
            start_ap_mode();
        }
    }

    // Start sensor reading task
    if (env_sensor != NULL) {
        xTaskCreate(sensor_task, "sensor_task", 4096, env_sensor, 5, NULL);
    }

    // Start RTC update task
    if (rtc != NULL) {
        xTaskCreate(rtc_task, "rtc_task", 2048, rtc, 4, NULL);
    }

#endif  // BOARD_MODEL == MODEL_ESP32S3_EPAPER_1IN54

#if ((BOARD_MODEL == MODEL_ESP32C3_MINI) && !defined(CONFIG_GEOGRAM_MESH_ENABLED)) || (BOARD_MODEL == MODEL_KV4P)
    // Standalone WiFi AP mode for KV4P and for minimal ESP32 boards when mesh
    // is disabled. KV4P mesh disconnect event kills the HTTP server, making
    // the device unreachable — keep KV4P in standalone AP+STA mode.

    // Initialize NOSTR keys (needed for AP SSID with callsign)
    ret = nostr_keys_init();
    if (ret != ESP_OK) {
        ESP_LOGW(TAG, "Failed to initialize NOSTR keys: %s", esp_err_to_name(ret));
    } else {
        ESP_LOGI(TAG, "Station callsign: %s", nostr_keys_get_callsign());
    }

    // Initialize WiFi
    ret = geogram_wifi_init();
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to initialize WiFi: %s", esp_err_to_name(ret));
#if HAS_LED
        led_set_state(LED_STATE_ERROR);
#endif
    } else {
        // Start WiFi AP mode
        geogram_wifi_ap_config_t ap_config = {};
        strncpy(ap_config.ssid, "geogram", sizeof(ap_config.ssid) - 1);
        ap_config.password[0] = '\0';  // Open network
        ap_config.channel = 1;
        ap_config.max_connections = 4;
        ap_config.callback = NULL;

        ret = geogram_wifi_start_ap(&ap_config);
        if (ret == ESP_OK) {
            ESP_LOGI(TAG, "WiFi AP started: geogram");

            // Try to auto-connect STA with saved WiFi credentials.
            // Delay 5 s so the AP and DHCP server are fully stable before STA
            // scanning disrupts the radio.
            {
                char saved_ssid[33] = {0};
                char saved_pass[65] = {0};
                if (geogram_wifi_load_credentials(saved_ssid, saved_pass) == ESP_OK
                    && strlen(saved_ssid) > 0) {
                    ESP_LOGI(TAG, "Will auto-connect to saved WiFi in 5 s: %s", saved_ssid);
                    vTaskDelay(pdMS_TO_TICKS(5000));
                    ESP_LOGI(TAG, "Auto-connecting to saved WiFi: %s", saved_ssid);
                    geogram_wifi_connect_sta(saved_ssid, saved_pass);
                }
            }

            // Start DNS server for captive portal
            uint32_t ap_ip = 0;
            if (geogram_wifi_get_ap_ip_addr(&ap_ip) == ESP_OK) {
                dns_server_start(ap_ip);
            }

            // Initialize Station API and HTTP server
            station_init();
            http_server_start_ex(NULL, true);
            ESP_LOGI(TAG, "HTTP server started");

            // BlueAPRS: observer+broadcaster BLE (no GATT, no connections)
            ESP_LOGI(TAG, "Free heap before BlueAPRS: %lu",
                     (unsigned long)esp_get_free_heap_size());
            {
                esp_err_t ble_ret = ble_aprs_init(kv4p_ble_aprs_rx, NULL);
                if (ble_ret == ESP_OK) {
                    aprs_store_set_rx_notify(kv4p_aprs_to_ble, NULL);
                    ESP_LOGI(TAG, "BlueAPRS active (free heap: %lu)",
                             (unsigned long)esp_get_free_heap_size());
                } else {
                    ESP_LOGW(TAG, "BlueAPRS failed: %s (continuing without)",
                             esp_err_to_name(ble_ret));
                }
            }

            // Telnet disabled on KV4P — heap too tight with BLE+WiFi APSTA+APRS
            ESP_LOGI(TAG, "Telnet disabled on KV4P (use serial console)");

#if HAS_LED
            led_set_state(LED_STATE_OK);
#endif
        } else {
            ESP_LOGE(TAG, "Failed to start WiFi AP: %s", esp_err_to_name(ret));
#if HAS_LED
            led_set_state(LED_STATE_ERROR);
#endif
        }
    }
#endif  // Minimal ESP32 boards and !CONFIG_GEOGRAM_MESH_ENABLED

#if BOARD_MODEL == MODEL_HELTEC_V3
    // Heltec V3: OLED display + SX1262 LoRa + WiFi AP

    // Get device handles
    ssd1306_handle_t display = model_get_display();
    sx1262_handle_t lora = model_get_lora();

    // Show boot splash on OLED
    if (display) {
        ssd1306_clear(display);
        ssd1306_draw_string(display, 16, 0, "== GEOGRAM ==", true);
        ssd1306_draw_string(display, 22, 12, "v" GEOGRAM_VERSION, true);
        ssd1306_draw_string(display, 0, 28, BOARD_NAME, true);
        if (lora) {
            ssd1306_draw_string(display, 0, 40, "LoRa: OK", true);
        } else {
            ssd1306_draw_string(display, 0, 40, "LoRa: FAIL", true);
        }
        ssd1306_draw_string(display, 0, 52, "Starting WiFi...", true);
        ssd1306_display(display);
    }

    // Brief LED flash to indicate boot
    model_led_on();
    vTaskDelay(pdMS_TO_TICKS(200));
    model_led_off();

    // Initialize NOSTR keys (needed for AP SSID with callsign)
    ret = nostr_keys_init();
    if (ret != ESP_OK) {
        ESP_LOGW(TAG, "Failed to initialize NOSTR keys: %s", esp_err_to_name(ret));
    } else {
        ESP_LOGI(TAG, "Station callsign: %s", nostr_keys_get_callsign());
    }

    // Initialize WiFi
    ret = geogram_wifi_init();
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to initialize WiFi: %s", esp_err_to_name(ret));
        if (display) {
            ssd1306_clear(display);
            ssd1306_draw_string(display, 0, 28, "WiFi FAILED", true);
            ssd1306_display(display);
        }
    } else {
        // Build SSID with callsign
        char ap_ssid[32];
        const char *callsign = nostr_keys_get_callsign();
        if (callsign && strlen(callsign) > 0) {
            snprintf(ap_ssid, sizeof(ap_ssid), "geogram-%s", callsign);
        } else {
            snprintf(ap_ssid, sizeof(ap_ssid), "geogram");
        }

        // Start WiFi AP mode
        geogram_wifi_ap_config_t ap_config = {};
        strncpy(ap_config.ssid, ap_ssid, sizeof(ap_config.ssid) - 1);
        ap_config.password[0] = '\0';
        ap_config.channel = 1;
        ap_config.max_connections = 4;
        ap_config.callback = NULL;

        ret = geogram_wifi_start_ap(&ap_config);
        if (ret == ESP_OK) {
            ESP_LOGI(TAG, "WiFi AP started: %s", ap_ssid);

            // Start DNS server for captive portal
            uint32_t ap_ip = 0;
            if (geogram_wifi_get_ap_ip_addr(&ap_ip) == ESP_OK) {
                dns_server_start(ap_ip);
            }

            // Initialize Station API and HTTP server
            station_init();
            http_server_start_ex(NULL, true);
            ESP_LOGI(TAG, "HTTP server started");

            // Start Telnet server
            if (telnet_server_start(TELNET_DEFAULT_PORT) == ESP_OK) {
                ESP_LOGI(TAG, "Telnet server started on port %d", TELNET_DEFAULT_PORT);
            }

            // Update OLED with connection info
            if (display) {
                char ip_str[16];
                geogram_wifi_get_ap_ip(ip_str);

                ssd1306_clear(display);
                ssd1306_draw_string(display, 0, 0, "== GEOGRAM ==", true);
                ssd1306_draw_string(display, 0, 12, ap_ssid, true);
                ssd1306_draw_string(display, 0, 24, ip_str, true);
                if (lora) {
                    ssd1306_draw_string(display, 0, 40, "LoRa: Ready", true);
                }
                ssd1306_draw_string(display, 0, 52, "v" GEOGRAM_VERSION, true);
                ssd1306_display(display);
            }

            model_led_on();  // LED on = system ready
        } else {
            ESP_LOGE(TAG, "Failed to start WiFi AP: %s", esp_err_to_name(ret));
        }
    }
#endif  // BOARD_MODEL == MODEL_HELTEC_V3

#if BOARD_MODEL == MODEL_HELTEC_V2 || BOARD_MODEL == MODEL_HELTEC_V1
    // Heltec V1/V2: OLED display + SX1276 LoRa + WiFi AP

    // Get device handles
    ssd1306_handle_t display = model_get_display();
    sx1276_handle_t lora = model_get_lora();

    // Show boot splash on OLED
    if (display) {
        ssd1306_clear(display);
        ssd1306_draw_string(display, 16, 0, "== GEOGRAM ==", true);
        ssd1306_draw_string(display, 22, 12, "v" GEOGRAM_VERSION, true);
        ssd1306_draw_string(display, 0, 28, BOARD_NAME, true);
        if (lora) {
            ssd1306_draw_string(display, 0, 40, "LoRa: OK", true);
        } else {
            ssd1306_draw_string(display, 0, 40, "LoRa: FAIL", true);
        }
        ssd1306_draw_string(display, 0, 52, "Starting WiFi...", true);
        ssd1306_display(display);
    }

    // Brief LED flash to indicate boot
    model_led_on();
    vTaskDelay(pdMS_TO_TICKS(200));
    model_led_off();

    // Initialize NOSTR keys (needed for AP SSID with callsign)
    ret = nostr_keys_init();
    if (ret != ESP_OK) {
        ESP_LOGW(TAG, "Failed to initialize NOSTR keys: %s", esp_err_to_name(ret));
    } else {
        ESP_LOGI(TAG, "Station callsign: %s", nostr_keys_get_callsign());
    }

    // Initialize WiFi
    ret = geogram_wifi_init();
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to initialize WiFi: %s", esp_err_to_name(ret));
        if (display) {
            ssd1306_clear(display);
            ssd1306_draw_string(display, 0, 28, "WiFi FAILED", true);
            ssd1306_display(display);
        }
    } else {
        // Build SSID with callsign
        char ap_ssid[32];
        const char *callsign = nostr_keys_get_callsign();
        if (callsign && strlen(callsign) > 0) {
            snprintf(ap_ssid, sizeof(ap_ssid), "geogram-%s", callsign);
        } else {
            snprintf(ap_ssid, sizeof(ap_ssid), "geogram");
        }

        // Start WiFi AP mode
        geogram_wifi_ap_config_t ap_config = {};
        strncpy(ap_config.ssid, ap_ssid, sizeof(ap_config.ssid) - 1);
        ap_config.password[0] = '\0';
        ap_config.channel = 1;
        ap_config.max_connections = 4;
        ap_config.callback = NULL;

        ret = geogram_wifi_start_ap(&ap_config);
        if (ret == ESP_OK) {
            ESP_LOGI(TAG, "WiFi AP started: %s", ap_ssid);

            // Start DNS server for captive portal
            uint32_t ap_ip = 0;
            if (geogram_wifi_get_ap_ip_addr(&ap_ip) == ESP_OK) {
                dns_server_start(ap_ip);
            }

            // Initialize Station API and HTTP server
            station_init();
            http_server_start_ex(NULL, true);
            ESP_LOGI(TAG, "HTTP server started");

            // Start Telnet server
            if (telnet_server_start(TELNET_DEFAULT_PORT) == ESP_OK) {
                ESP_LOGI(TAG, "Telnet server started on port %d", TELNET_DEFAULT_PORT);
            }

            // Update OLED with connection info
            if (display) {
                char ip_str[16];
                geogram_wifi_get_ap_ip(ip_str);

                ssd1306_clear(display);
                ssd1306_draw_string(display, 0, 0, "== GEOGRAM ==", true);
                ssd1306_draw_string(display, 0, 12, ap_ssid, true);
                ssd1306_draw_string(display, 0, 24, ip_str, true);
                if (lora) {
                    ssd1306_draw_string(display, 0, 40, "LoRa: Ready", true);
                }
                ssd1306_draw_string(display, 0, 52, "v" GEOGRAM_VERSION, true);
                ssd1306_display(display);
            }

            model_led_on();  // LED on = system ready
        } else {
            ESP_LOGE(TAG, "Failed to start WiFi AP: %s", esp_err_to_name(ret));
        }
    }
#endif  // BOARD_MODEL == MODEL_HELTEC_V2 || MODEL_HELTEC_V1

    // Main loop
    ESP_LOGI(TAG, "Entering main loop...");

#if BOARD_MODEL == MODEL_TDONGLE_S3
    // T-Dongle-S3: main loop drives display + polls BLE device count
    {
        uint32_t last_count_ms = 0;
        while (1) {
            tdongle_ui_update();

            // Update device count on display every ~5 seconds
            uint32_t now_ms = esp_log_timestamp();
            if (now_ms - last_count_ms > 5000) {
                tdongle_ui_set_device_count(ble_hello_device_count());
                last_count_ms = now_ms;
            }

            vTaskDelay(pdMS_TO_TICKS(5));
        }
    }
#else
    while (1) {
#if BOARD_MODEL == MODEL_ESP32S3_EPAPER_1IN54
        // Check for shutdown request (from power button long press)
        if (s_shutdown_requested) {
            s_shutdown_requested = false;
            device_shutdown();
            // If we get here, deep sleep failed - reset the flag
        }
#endif
        vTaskDelay(pdMS_TO_TICKS(100));  // Check more frequently for responsiveness
    }
#endif
}
