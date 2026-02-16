/**
 * @file mesh_bsp.c
 * @brief Geogram ESP-Mesh-Lite networking core implementation
 *
 * Uses ESP-Mesh-Lite for router-less mesh with native phone/laptop connectivity.
 * Each node has its own LWIP stack and can host external clients directly.
 */

#include "mesh_bsp.h"

#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/event_groups.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_wifi.h"
#include "esp_bridge.h"
#include "esp_mesh_lite.h"
#include "esp_netif.h"
#include "esp_event.h"
#include "nvs_flash.h"
#include "nvs.h"
#include "lwip/ip4_addr.h"

// ============================================================================
// NAPT stub - iot_bridge expects a patched LWIP with ip_napt_table_clear()
// This stub provides the missing function for PlatformIO builds without the patch
// ============================================================================
__attribute__((weak)) void ip_napt_table_clear(void)
{
    // Stub - patched LWIP has the real implementation
    // This function clears NAPT entries when the router interface changes
    ESP_LOGW("mesh_bsp", "ip_napt_table_clear stub called - LWIP NAPT patch not applied");
}

static const char *TAG = "mesh_bsp";

// ============================================================================
// SSID construction callback for ESP-Mesh-Lite peer discovery
// ============================================================================

/**
 * @brief Callback to construct SSID from MAC address for mesh peer discovery
 *
 * ESP-Mesh-Lite discovers peers via vendor IEs in beacon frames, but needs
 * to know the exact SSID to connect to. All nodes use the same SSID "geogram"
 * so phones can auto-connect. Mesh peers are distinguished by BSSID, not SSID.
 *
 * This callback is called during scan when a mesh peer is found via vendor IE.
 * It returns the common SSID for all peers - mesh-lite uses BSSID to connect
 * to the specific node.
 */
static const uint8_t* mesh_get_ssid_by_mac(const uint8_t *bssid)
{
    if (bssid == NULL) {
        return NULL;
    }

    // All nodes use the same SSID for phone auto-connect
    // Mesh discovery uses vendor IEs, connection uses BSSID
    static uint8_t ssid[33];
    snprintf((char *)ssid, sizeof(ssid), "%s", CONFIG_BRIDGE_SOFTAP_SSID);

    ESP_LOGI(TAG, "[MESH] Peer BSSID: %02x:%02x:%02x:%02x:%02x:%02x -> SSID: %s",
             bssid[0], bssid[1], bssid[2], bssid[3], bssid[4], bssid[5], ssid);
    return ssid;
}

// ============================================================================
// Configuration defaults
// ============================================================================

#ifndef CONFIG_GEOGRAM_MESH_CHANNEL
#define CONFIG_GEOGRAM_MESH_CHANNEL 1
#endif

#ifndef CONFIG_GEOGRAM_MESH_MAX_LAYER
#define CONFIG_GEOGRAM_MESH_MAX_LAYER 6
#endif

#ifndef CONFIG_GEOGRAM_MESH_EXTERNAL_AP_MAX_CONN
#define CONFIG_GEOGRAM_MESH_EXTERNAL_AP_MAX_CONN 4
#endif

// ============================================================================
// State variables
// ============================================================================

static bool s_initialized = false;
static bool s_started = false;
static geogram_mesh_status_t s_status = GEOGRAM_MESH_STATUS_STOPPED;
static geogram_mesh_event_cb_t s_event_callback = NULL;
static geogram_mesh_data_cb_t s_data_callback = NULL;

// Mesh configuration
static uint8_t s_mesh_id[6];
static uint8_t s_channel = CONFIG_GEOGRAM_MESH_CHANNEL;
static uint8_t s_max_layer = CONFIG_GEOGRAM_MESH_MAX_LAYER;
static bool s_is_root = false;
static uint8_t s_layer = 0;
static uint8_t s_subnet_id = 0;
static uint8_t s_parent_mac[6];
static bool s_has_parent = false;

// External AP state
static bool s_external_ap_running = false;
static char s_external_ap_ssid[33] = {0};
static uint8_t s_external_ap_clients = 0;

// NVS namespace
#define MESH_NVS_NAMESPACE "mesh_config"

// ============================================================================
// Forward declarations
// ============================================================================

static void mesh_lite_event_handler(void *arg, esp_event_base_t base,
                                    int32_t event_id, void *data);
static void wifi_event_handler(void *arg, esp_event_base_t event_base,
                               int32_t event_id, void *event_data);
static void ip_event_handler(void *arg, esp_event_base_t event_base,
                             int32_t event_id, void *event_data);
static uint8_t calculate_subnet_id(const uint8_t *mac);

// ============================================================================
// Initialization
// ============================================================================

esp_err_t geogram_mesh_init(void)
{
    if (s_initialized) {
        ESP_LOGW(TAG, "Mesh already initialized");
        return ESP_OK;
    }

    // Debug: Print build-time configuration values
    ESP_LOGI(TAG, "========================================");
    ESP_LOGI(TAG, "[CONFIG] Build-time configuration:");
    ESP_LOGI(TAG, "[CONFIG] CONFIG_FREERTOS_TIMER_TASK_STACK_DEPTH=%d",
             CONFIG_FREERTOS_TIMER_TASK_STACK_DEPTH);
    ESP_LOGI(TAG, "[CONFIG] CONFIG_ESP_TIMER_TASK_STACK_SIZE=%d",
             CONFIG_ESP_TIMER_TASK_STACK_SIZE);
    ESP_LOGI(TAG, "[CONFIG] CONFIG_ESP_MAIN_TASK_STACK_SIZE=%d",
             CONFIG_ESP_MAIN_TASK_STACK_SIZE);
    ESP_LOGI(TAG, "[CONFIG] CONFIG_ESP_SYSTEM_EVENT_TASK_STACK_SIZE=%d",
             CONFIG_ESP_SYSTEM_EVENT_TASK_STACK_SIZE);
    ESP_LOGI(TAG, "========================================");

    ESP_LOGI(TAG, "Initializing ESP-Mesh-Lite subsystem");

    esp_err_t ret;

    // Initialize NVS (may already be done)
    ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_LOGW(TAG, "[INIT] NVS needs erase, erasing...");
        ret = nvs_flash_erase();
        if (ret != ESP_OK) {
            ESP_LOGE(TAG, "[INIT] Failed to erase NVS: %s", esp_err_to_name(ret));
            return ret;
        }
        ret = nvs_flash_init();
    }
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "[INIT] Failed to init NVS: %s", esp_err_to_name(ret));
        return ret;
    }

    // Initialize TCP/IP stack (may already be initialized)
    ret = esp_netif_init();
    if (ret != ESP_OK && ret != ESP_ERR_INVALID_STATE) {
        ESP_LOGE(TAG, "[INIT] Failed to init netif: %s", esp_err_to_name(ret));
        return ret;
    }
    if (ret == ESP_ERR_INVALID_STATE) {
        ESP_LOGI(TAG, "[INIT] TCP/IP stack already initialized");
    }

    // Create default event loop (may already exist)
    ret = esp_event_loop_create_default();
    if (ret != ESP_OK && ret != ESP_ERR_INVALID_STATE) {
        ESP_LOGE(TAG, "[INIT] Failed to create event loop: %s", esp_err_to_name(ret));
        return ret;
    }
    if (ret == ESP_ERR_INVALID_STATE) {
        ESP_LOGI(TAG, "[INIT] Event loop already exists");
    }

    // Register event handlers
    ret = esp_event_handler_instance_register(
        WIFI_EVENT, ESP_EVENT_ANY_ID, &wifi_event_handler, NULL, NULL);
    if (ret != ESP_OK && ret != ESP_ERR_INVALID_STATE) {
        ESP_LOGE(TAG, "[INIT] Failed to register WiFi event handler: %s", esp_err_to_name(ret));
        return ret;
    }

    ret = esp_event_handler_instance_register(
        IP_EVENT, ESP_EVENT_ANY_ID, &ip_event_handler, NULL, NULL);
    if (ret != ESP_OK && ret != ESP_ERR_INVALID_STATE) {
        ESP_LOGE(TAG, "[INIT] Failed to register IP event handler: %s", esp_err_to_name(ret));
        return ret;
    }

    // Create all bridge network interfaces (STA + SoftAP)
    // This is required before WiFi and mesh-lite initialization
    esp_bridge_create_all_netif();
    ESP_LOGI(TAG, "[INIT] Bridge network interfaces created");

    // Initialize WiFi
    wifi_init_config_t wifi_cfg = WIFI_INIT_CONFIG_DEFAULT();
    ret = esp_wifi_init(&wifi_cfg);
    if (ret != ESP_OK && ret != ESP_ERR_WIFI_INIT_STATE) {
        ESP_LOGE(TAG, "[INIT] Failed to init WiFi: %s", esp_err_to_name(ret));
        return ret;
    }
    if (ret == ESP_ERR_WIFI_INIT_STATE) {
        ESP_LOGI(TAG, "[INIT] WiFi already initialized");
    }

    // Set WiFi storage and mode
    ESP_ERROR_CHECK(esp_wifi_set_storage(WIFI_STORAGE_RAM));
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_APSTA));

    // Start WiFi before mesh-lite init
    ESP_ERROR_CHECK(esp_wifi_start());

    // Debug: Dump timer task info to verify stack sizes
    TaskStatus_t *task_array;
    UBaseType_t task_count = uxTaskGetNumberOfTasks();
    task_array = pvPortMalloc(task_count * sizeof(TaskStatus_t));
    if (task_array) {
        task_count = uxTaskGetSystemState(task_array, task_count, NULL);
        ESP_LOGI(TAG, "[TASKS] Running tasks (%lu):", (unsigned long)task_count);
        for (UBaseType_t i = 0; i < task_count; i++) {
            if (strstr(task_array[i].pcTaskName, "Tmr") != NULL ||
                strstr(task_array[i].pcTaskName, "timer") != NULL ||
                strstr(task_array[i].pcTaskName, "esp_timer") != NULL) {
                ESP_LOGI(TAG, "[TASKS] %s: stack high water mark = %lu words",
                         task_array[i].pcTaskName,
                         (unsigned long)task_array[i].usStackHighWaterMark);
            }
        }
        vPortFree(task_array);
    }

    s_initialized = true;
    ESP_LOGI(TAG, "[INIT] Mesh subsystem initialized successfully");
    ESP_LOGI(TAG, "========================================");

    return ESP_OK;
}

esp_err_t geogram_mesh_deinit(void)
{
    if (!s_initialized) {
        return ESP_OK;
    }

    if (s_started) {
        geogram_mesh_stop();
    }

    esp_wifi_stop();
    esp_wifi_deinit();

    s_initialized = false;
    s_status = GEOGRAM_MESH_STATUS_STOPPED;

    ESP_LOGI(TAG, "Mesh subsystem deinitialized");
    return ESP_OK;
}

// ============================================================================
// Mesh Control
// ============================================================================

esp_err_t geogram_mesh_start(const geogram_mesh_config_t *config)
{
    if (!s_initialized) {
        ESP_LOGE(TAG, "[START] ERROR: Mesh not initialized");
        return ESP_ERR_INVALID_STATE;
    }

    if (s_started) {
        ESP_LOGW(TAG, "[START] Mesh already started");
        return ESP_OK;
    }

    if (!config) {
        ESP_LOGE(TAG, "[START] ERROR: Invalid config");
        return ESP_ERR_INVALID_ARG;
    }

    ESP_LOGI(TAG, "========================================");
    ESP_LOGI(TAG, "[START] Starting ESP-Mesh-Lite network");
    ESP_LOGI(TAG, "[START] Channel: %d", config->channel);
    ESP_LOGI(TAG, "[START] Max Layer: %d", config->max_layer);
    ESP_LOGI(TAG, "[START] Allow Root: %s", config->allow_root ? "YES" : "NO");
    ESP_LOGI(TAG, "[START] Mesh ID: %02X:%02X:%02X:%02X:%02X:%02X",
             config->mesh_id[0], config->mesh_id[1], config->mesh_id[2],
             config->mesh_id[3], config->mesh_id[4], config->mesh_id[5]);
    ESP_LOGI(TAG, "========================================");

    // Store configuration
    s_event_callback = config->callback;
    memcpy(s_mesh_id, config->mesh_id, 6);
    s_channel = config->channel;
    s_max_layer = config->max_layer;

    // Calculate this node's subnet ID from MAC address
    uint8_t mac[6];
    esp_wifi_get_mac(WIFI_IF_STA, mac);
    s_subnet_id = calculate_subnet_id(mac);
    ESP_LOGI(TAG, "This node's subnet ID: %d (192.168.%d.0/24)", s_subnet_id, 10 + s_subnet_id);

    // Register mesh-lite event handler
    esp_err_t ret = esp_event_handler_instance_register(
        ESP_MESH_LITE_EVENT, ESP_EVENT_ANY_ID, &mesh_lite_event_handler, NULL, NULL);
    if (ret != ESP_OK && ret != ESP_ERR_INVALID_STATE) {
        ESP_LOGE(TAG, "[START] Failed to register mesh-lite event handler: %s", esp_err_to_name(ret));
        return ret;
    }

    // Configure SoftAP SSID BEFORE mesh-lite init (following led_light example pattern)
    // Only set SSID and password, let bridge handle other config
    wifi_config_t wifi_cfg;
    memset(&wifi_cfg, 0x0, sizeof(wifi_config_t));
    snprintf((char *)wifi_cfg.ap.ssid, sizeof(wifi_cfg.ap.ssid), "%s", CONFIG_BRIDGE_SOFTAP_SSID);
    strlcpy((char *)wifi_cfg.ap.password, CONFIG_BRIDGE_SOFTAP_PASSWORD, sizeof(wifi_cfg.ap.password));
    esp_bridge_wifi_set_config(WIFI_IF_AP, &wifi_cfg);
    ESP_LOGI(TAG, "[START] SoftAP SSID configured: %s", CONFIG_BRIDGE_SOFTAP_SSID);

    // Configure ESP-Mesh-Lite using the default config from Kconfig
    esp_mesh_lite_config_t mesh_lite_config = ESP_MESH_LITE_DEFAULT_INIT();

    // Mesh-Lite's vendor_ie module emits repetitive connect warnings in
    // router-less mode (expected in Geogram). Keep only errors for this tag.
    esp_log_level_set("[vendor_ie]", ESP_LOG_ERROR);
    esp_log_level_set("vendor_ie", ESP_LOG_ERROR);

    // Initialize mesh-lite (returns void)
    esp_mesh_lite_init(&mesh_lite_config);
    ESP_LOGI(TAG, "[START] Mesh-lite initialized");

    // Override mesh_id from our config (use first byte - ESP-Mesh-Lite uses single byte)
    // This ensures all nodes with same config join the same mesh network
    esp_mesh_lite_set_mesh_id(config->mesh_id[0], false);
    ESP_LOGI(TAG, "[START] Mesh ID set to: 0x%02X ('%c')", config->mesh_id[0], config->mesh_id[0]);

    // Configure root/node behavior based on allow_root setting
    // ESP-Mesh-Lite requires explicit root designation in router-less mesh.
    //
    // Strategy for router-less auto-election:
    // - Use MAC address to deterministically elect root
    // - Node with LOWEST STA MAC becomes root (level 1 only)
    // - All other nodes become children (levels 2+)
    // - This ensures exactly one root in any mesh topology
    //
    if (config->allow_root) {
        // Get our STA MAC address for comparison
        uint8_t sta_mac[6];
        esp_wifi_get_mac(WIFI_IF_STA, sta_mac);

        // Use last 3 bytes of MAC as a simple unique identifier
        uint32_t my_id = (sta_mac[3] << 16) | (sta_mac[4] << 8) | sta_mac[5];

        // For deterministic root election: use static threshold
        // Node with MAC ID below threshold = root, above = child
        // 0xe2d800 is between node0 (0xe2d518) and node1 (0xe2dcd0)
        const uint32_t root_threshold = 0xe2d800;
        bool should_be_root = (my_id < root_threshold);

        if (should_be_root) {
            // This node becomes root (level 1 only)
            esp_mesh_lite_set_allowed_level(1);
            ESP_LOGI(TAG, "[START] Node elected as ROOT (level 1), MAC ID: 0x%06lX < threshold", (unsigned long)my_id);
        } else {
            // This node becomes child (level 2+)
            esp_mesh_lite_set_disallowed_level(1);
            ESP_LOGI(TAG, "[START] Node elected as CHILD (level 2+), MAC ID: 0x%06lX >= threshold", (unsigned long)my_id);
        }
    } else {
        // This node can only be a child, never root
        esp_mesh_lite_set_disallowed_level(1);
        ESP_LOGI(TAG, "[START] Node set as CHILD ONLY (levels 2-%d)", s_max_layer);
    }

    // Also set softap info for mesh-lite (after init, before start)
    esp_mesh_lite_set_softap_info(CONFIG_BRIDGE_SOFTAP_SSID, CONFIG_BRIDGE_SOFTAP_PASSWORD);

    // Register SSID callback for mesh peer discovery
    // This tells mesh-lite how to construct SSID from MAC when connecting to peers
    // whitelist=false means "this is how to generate SSID for any peer"
    esp_mesh_lite_get_ssid_by_mac_cb_register(mesh_get_ssid_by_mac, false);
    ESP_LOGI(TAG, "[START] Registered SSID-by-MAC callback for peer discovery");

    // Start mesh-lite (returns void)
    esp_mesh_lite_start();
    ESP_LOGI(TAG, "[START] Mesh-lite started");

    // Log the actual SoftAP SSID being used
    wifi_config_t current_ap_config;
    if (esp_wifi_get_config(WIFI_IF_AP, &current_ap_config) == ESP_OK) {
        ESP_LOGI(TAG, "[START] Actual SoftAP SSID: %s", (char*)current_ap_config.ap.ssid);
    }

    s_started = true;
    s_status = GEOGRAM_MESH_STATUS_STARTED;

    ESP_LOGI(TAG, "Mesh-lite started, scanning for network...");

    return ESP_OK;
}

esp_err_t geogram_mesh_stop(void)
{
    if (!s_started) {
        return ESP_OK;
    }

    ESP_LOGI(TAG, "Stopping mesh-lite network");

    // Stop external AP if running
    geogram_mesh_stop_external_ap();

    // Note: esp_mesh_lite doesn't have a stop function
    // The mesh will be stopped when WiFi is stopped

    s_started = false;
    s_status = GEOGRAM_MESH_STATUS_STOPPED;
    s_is_root = false;
    s_layer = 0;
    s_has_parent = false;

    if (s_event_callback) {
        s_event_callback(GEOGRAM_MESH_EVENT_STOPPED, NULL);
    }

    ESP_LOGI(TAG, "Mesh stopped");
    return ESP_OK;
}

// ============================================================================
// Status Queries
// ============================================================================

geogram_mesh_status_t geogram_mesh_get_status(void)
{
    return s_status;
}

bool geogram_mesh_is_connected(void)
{
    return s_status == GEOGRAM_MESH_STATUS_CONNECTED ||
           s_status == GEOGRAM_MESH_STATUS_ROOT;
}

bool geogram_mesh_is_root(void)
{
    return s_is_root;
}

uint8_t geogram_mesh_get_layer(void)
{
    return s_layer;
}

uint8_t geogram_mesh_get_subnet_id(void)
{
    return s_subnet_id;
}

esp_err_t geogram_mesh_get_parent_mac(uint8_t *mac)
{
    if (!mac) return ESP_ERR_INVALID_ARG;
    if (!s_has_parent) return ESP_ERR_NOT_FOUND;

    memcpy(mac, s_parent_mac, 6);
    return ESP_OK;
}

bool geogram_mesh_has_parent(void)
{
    return s_has_parent;
}

size_t geogram_mesh_get_peer_count(void)
{
    // Count mesh peers we're connected to:
    // - Child node (has parent): at least 1 peer (the parent)
    // - Root node: use esp_mesh_lite_get_mesh_node_number() which returns children count
    //
    // Note: esp_mesh_lite_get_mesh_node_number() counts nodes that REPORTED to root,
    // which means it returns the number of CHILDREN, not including root itself.
    // Requires CONFIG_MESH_LITE_NODE_INFO_REPORT=y to work.

    if (s_has_parent) {
        // This node is a child, connected to parent
        return 1;
    }

    if (s_is_root && s_status == GEOGRAM_MESH_STATUS_ROOT) {
        // This node is root - get count of children that reported
        uint32_t children = esp_mesh_lite_get_mesh_node_number();
        return children;  // Already excludes self
    }

    return 0;
}

// ============================================================================
// External SoftAP (for phones)
// ============================================================================

esp_err_t geogram_mesh_start_external_ap(const char *ssid, const char *password,
                                          uint8_t max_connections)
{
    if (!s_started) {
        ESP_LOGE(TAG, "Mesh not started");
        return ESP_ERR_INVALID_STATE;
    }

    if (s_external_ap_running) {
        ESP_LOGW(TAG, "External AP already running");
        return ESP_OK;
    }

    ESP_LOGI(TAG, "Starting external AP: %s", ssid);

    // In ESP-Mesh-Lite, each node has its own LWIP stack and can directly
    // serve external clients on its AP interface. The bridge component
    // handles the SoftAP configuration via Kconfig (CONFIG_BRIDGE_SOFTAP_*).

    // Store SSID for status queries
    strncpy(s_external_ap_ssid, ssid, sizeof(s_external_ap_ssid) - 1);
    s_external_ap_ssid[sizeof(s_external_ap_ssid) - 1] = '\0';

    s_external_ap_running = true;
    s_external_ap_clients = 0;

    // The SoftAP is already configured by the bridge component
    // Phones can connect to the SSID configured in Kconfig (CONFIG_BRIDGE_SOFTAP_SSID)
    ESP_LOGI(TAG, "External AP enabled (using bridge SoftAP)");

    return ESP_OK;
}

esp_err_t geogram_mesh_stop_external_ap(void)
{
    if (!s_external_ap_running) {
        return ESP_OK;
    }

    ESP_LOGI(TAG, "Stopping external AP");

    s_external_ap_running = false;
    s_external_ap_clients = 0;
    s_external_ap_ssid[0] = '\0';

    ESP_LOGI(TAG, "External AP stopped");
    return ESP_OK;
}

bool geogram_mesh_external_ap_is_running(void)
{
    return s_external_ap_running;
}

esp_err_t geogram_mesh_get_external_ap_ip(char *ip_str, size_t len)
{
    if (!ip_str || len < 16) return ESP_ERR_INVALID_ARG;
    if (!s_external_ap_running) return ESP_ERR_INVALID_STATE;

    esp_netif_t *ap_netif = esp_netif_get_handle_from_ifkey("WIFI_AP_DEF");
    if (!ap_netif) {
        ip_str[0] = '\0';
        return ESP_ERR_INVALID_STATE;
    }

    esp_netif_ip_info_t ip_info;
    esp_err_t ret = esp_netif_get_ip_info(ap_netif, &ip_info);
    if (ret != ESP_OK || ip_info.ip.addr == 0) {
        ip_str[0] = '\0';
        return ret == ESP_OK ? ESP_ERR_INVALID_STATE : ret;
    }

    snprintf(ip_str, len, IPSTR, IP2STR(&ip_info.ip));
    return ESP_OK;
}

esp_err_t geogram_mesh_get_external_ap_ip_addr(uint32_t *ip)
{
    if (!ip) return ESP_ERR_INVALID_ARG;
    if (!s_external_ap_running) return ESP_ERR_INVALID_STATE;

    esp_netif_t *ap_netif = esp_netif_get_handle_from_ifkey("WIFI_AP_DEF");
    if (!ap_netif) {
        *ip = 0;
        return ESP_ERR_INVALID_STATE;
    }

    esp_netif_ip_info_t ip_info;
    esp_err_t ret = esp_netif_get_ip_info(ap_netif, &ip_info);
    if (ret != ESP_OK || ip_info.ip.addr == 0) {
        *ip = 0;
        return ret == ESP_OK ? ESP_ERR_INVALID_STATE : ret;
    }

    *ip = ip_info.ip.addr;
    return ESP_OK;
}

uint8_t geogram_mesh_get_external_ap_client_count(void)
{
    return s_external_ap_clients;
}

// ============================================================================
// Node Discovery
// ============================================================================

esp_err_t geogram_mesh_get_nodes(geogram_mesh_node_t *nodes, size_t max_nodes,
                                  size_t *node_count)
{
    if (!nodes || !node_count) return ESP_ERR_INVALID_ARG;

    // In ESP-Mesh-Lite, we can get node info from the mesh-lite API
    size_t count = 0;

    // Add self to the list
    if (count < max_nodes) {
        uint8_t mac[6];
        esp_wifi_get_mac(WIFI_IF_STA, mac);
        memcpy(nodes[count].mac, mac, 6);
        nodes[count].subnet_id = s_subnet_id;
        nodes[count].layer = s_layer;
        nodes[count].rssi = 0;
        nodes[count].is_root = s_is_root;
        count++;
    }

    *node_count = count;
    return ESP_OK;
}

size_t geogram_mesh_get_node_count(void)
{
    // Return at least 1 for self
    return 1;
}

esp_err_t geogram_mesh_find_node_by_subnet(uint8_t subnet_id, geogram_mesh_node_t *node)
{
    if (!node) return ESP_ERR_INVALID_ARG;

    // Check if it's our own subnet
    if (subnet_id == s_subnet_id) {
        uint8_t mac[6];
        esp_wifi_get_mac(WIFI_IF_STA, mac);
        memcpy(node->mac, mac, 6);
        node->subnet_id = s_subnet_id;
        node->layer = s_layer;
        node->rssi = 0;
        node->is_root = s_is_root;
        return ESP_OK;
    }

    return ESP_ERR_NOT_FOUND;
}

// ============================================================================
// Data Transmission
// ============================================================================

esp_err_t geogram_mesh_send_to_node(const uint8_t *dest_mac, const void *data, size_t len)
{
    if (!dest_mac || !data || len == 0) {
        ESP_LOGE(TAG, "[TX] Invalid arguments");
        return ESP_ERR_INVALID_ARG;
    }
    if (!s_started || !geogram_mesh_is_connected()) {
        ESP_LOGE(TAG, "[TX] Mesh not connected");
        return ESP_ERR_INVALID_STATE;
    }

    ESP_LOGI(TAG, "[TX] Sending %zu bytes to " MACSTR,
             len, MAC2STR(dest_mac));

    // Use ESP-Mesh-Lite's ESP-NOW based messaging
    esp_err_t ret = esp_mesh_lite_espnow_send(
        ESPNOW_DATA_TYPE_RM_GROUP_CONTROL,
        (uint8_t *)dest_mac,
        (const uint8_t *)data,
        len
    );

    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "[TX] FAILED: %s", esp_err_to_name(ret));
    } else {
        ESP_LOGI(TAG, "[TX] SUCCESS");
    }

    return ret;
}

void geogram_mesh_register_data_callback(geogram_mesh_data_cb_t callback)
{
    s_data_callback = callback;
}

// ============================================================================
// Configuration Persistence
// ============================================================================

esp_err_t geogram_mesh_save_config(void)
{
    nvs_handle_t nvs;
    esp_err_t ret = nvs_open(MESH_NVS_NAMESPACE, NVS_READWRITE, &nvs);
    if (ret != ESP_OK) return ret;

    nvs_set_blob(nvs, "mesh_id", s_mesh_id, 6);
    nvs_set_u8(nvs, "channel", s_channel);
    nvs_set_u8(nvs, "max_layer", s_max_layer);

    nvs_commit(nvs);
    nvs_close(nvs);

    ESP_LOGI(TAG, "Mesh config saved to NVS");
    return ESP_OK;
}

esp_err_t geogram_mesh_load_config(geogram_mesh_config_t *config)
{
    if (!config) return ESP_ERR_INVALID_ARG;

    nvs_handle_t nvs;
    esp_err_t ret = nvs_open(MESH_NVS_NAMESPACE, NVS_READONLY, &nvs);
    if (ret != ESP_OK) return ret;

    size_t len = 6;
    nvs_get_blob(nvs, "mesh_id", config->mesh_id, &len);
    nvs_get_u8(nvs, "channel", &config->channel);
    nvs_get_u8(nvs, "max_layer", &config->max_layer);

    nvs_close(nvs);

    ESP_LOGI(TAG, "Mesh config loaded from NVS");
    return ESP_OK;
}

// ============================================================================
// Event Handlers
// ============================================================================

static void mesh_lite_event_handler(void *arg, esp_event_base_t base,
                                    int32_t event_id, void *data)
{
    switch (event_id) {
        case ESP_MESH_LITE_EVENT_CORE_STARTED:
            ESP_LOGI(TAG, "[EVENT] *** MESH-LITE STARTED ***");
            s_status = GEOGRAM_MESH_STATUS_STARTED;
            if (s_event_callback) {
                s_event_callback(GEOGRAM_MESH_EVENT_STARTED, NULL);
            }
            break;

        case ESP_MESH_LITE_EVENT_CORE_INHERITED_NET_SEGMENT_CHANGED:
            ESP_LOGI(TAG, "[EVENT] Network segment changed");
            break;

        case ESP_MESH_LITE_EVENT_CORE_ROUTER_INFO_CHANGED:
            ESP_LOGI(TAG, "[EVENT] Router info changed");
            break;

        case ESP_MESH_LITE_EVENT_NODE_JOIN: {
            ESP_LOGI(TAG, "========================================");
            ESP_LOGI(TAG, "[EVENT] *** NODE JOINED MESH ***");

            // Get current level
            s_layer = esp_mesh_lite_get_level();
            s_is_root = (s_layer == 1);

            ESP_LOGI(TAG, "[EVENT] Level: %d", s_layer);
            ESP_LOGI(TAG, "[EVENT] Is Root: %s", s_is_root ? "YES" : "NO");
            ESP_LOGI(TAG, "[EVENT] Subnet: 192.168.%d.0/24", 10 + s_subnet_id);
            ESP_LOGI(TAG, "========================================");

            s_status = s_is_root ? GEOGRAM_MESH_STATUS_ROOT : GEOGRAM_MESH_STATUS_CONNECTED;
            s_has_parent = !s_is_root;

            if (s_event_callback) {
                s_event_callback(GEOGRAM_MESH_EVENT_CONNECTED, NULL);
            }
            break;
        }

        case ESP_MESH_LITE_EVENT_NODE_LEAVE:
            ESP_LOGW(TAG, "========================================");
            ESP_LOGW(TAG, "[EVENT] *** NODE LEFT MESH ***");
            ESP_LOGW(TAG, "========================================");

            s_status = GEOGRAM_MESH_STATUS_DISCONNECTED;
            s_has_parent = false;
            s_layer = 0;

            if (s_event_callback) {
                s_event_callback(GEOGRAM_MESH_EVENT_DISCONNECTED, NULL);
            }
            break;

        case ESP_MESH_LITE_EVENT_NODE_CHANGE: {
            ESP_LOGI(TAG, "[EVENT] Topology changed");

            // Update level info
            uint8_t new_layer = esp_mesh_lite_get_level();
            bool new_is_root = (new_layer == 1);

            if (new_layer != s_layer || new_is_root != s_is_root) {
                s_layer = new_layer;
                s_is_root = new_is_root;
                s_status = s_is_root ? GEOGRAM_MESH_STATUS_ROOT : GEOGRAM_MESH_STATUS_CONNECTED;

                ESP_LOGI(TAG, "[EVENT] New level: %d, is_root: %s",
                         s_layer, s_is_root ? "YES" : "NO");

                if (s_event_callback) {
                    s_event_callback(GEOGRAM_MESH_EVENT_ROOT_CHANGED, NULL);
                }
            }
            break;
        }

        default:
            ESP_LOGD(TAG, "[EVENT] Unhandled mesh-lite event: %ld", event_id);
            break;
    }
}

static void wifi_event_handler(void *arg, esp_event_base_t event_base,
                               int32_t event_id, void *event_data)
{
    switch (event_id) {
        case WIFI_EVENT_AP_STACONNECTED: {
            wifi_event_ap_staconnected_t *event = (wifi_event_ap_staconnected_t *)event_data;
            ESP_LOGI(TAG, "[AP] Station connected: " MACSTR " (AID=%d)",
                     MAC2STR(event->mac), event->aid);
            s_external_ap_clients++;
            break;
        }

        case WIFI_EVENT_AP_STADISCONNECTED: {
            wifi_event_ap_stadisconnected_t *event = (wifi_event_ap_stadisconnected_t *)event_data;
            ESP_LOGI(TAG, "[AP] Station disconnected: " MACSTR " (AID=%d, reason=%d)",
                     MAC2STR(event->mac), event->aid, event->reason);
            if (s_external_ap_clients > 0) {
                s_external_ap_clients--;
            }
            break;
        }

        case WIFI_EVENT_STA_CONNECTED: {
            wifi_event_sta_connected_t *event = (wifi_event_sta_connected_t *)event_data;
            memcpy(s_parent_mac, event->bssid, 6);
            s_has_parent = true;
            ESP_LOGI(TAG, "[STA] Connected to parent AP: " MACSTR " (ch=%d)",
                     MAC2STR(event->bssid), event->channel);
            break;
        }

        case WIFI_EVENT_STA_DISCONNECTED: {
            wifi_event_sta_disconnected_t *event = (wifi_event_sta_disconnected_t *)event_data;
            ESP_LOGW(TAG, "[STA] Disconnected from parent AP (reason=%d)", event->reason);
            s_has_parent = false;
            memset(s_parent_mac, 0, 6);
            break;
        }

        default:
            break;
    }
}

static void ip_event_handler(void *arg, esp_event_base_t event_base,
                             int32_t event_id, void *event_data)
{
    switch (event_id) {
        case IP_EVENT_AP_STAIPASSIGNED: {
            ip_event_ap_staipassigned_t *event = (ip_event_ap_staipassigned_t *)event_data;
            ESP_LOGI(TAG, "Phone connected to AP, IP: " IPSTR,
                     IP2STR(&event->ip));

            if (s_event_callback) {
                geogram_mesh_external_sta_t sta = {0};
                memcpy(sta.mac, event->mac, 6);
                sta.ip = event->ip.addr;
                s_event_callback(GEOGRAM_MESH_EVENT_EXTERNAL_STA_CONNECTED, &sta);
            }
            break;
        }

        case IP_EVENT_STA_GOT_IP: {
            ip_event_got_ip_t *event = (ip_event_got_ip_t *)event_data;
            ESP_LOGI(TAG, "[STA] Got IP: " IPSTR, IP2STR(&event->ip_info.ip));
            break;
        }

        case IP_EVENT_STA_LOST_IP:
            ESP_LOGW(TAG, "[STA] Lost IP");
            break;

        default:
            break;
    }
}

// ============================================================================
// Helper Functions
// ============================================================================

static uint8_t calculate_subnet_id(const uint8_t *mac)
{
    // Use last byte of MAC, mapped to range 0-239
    // This gives subnet 192.168.{10+id}.0/24
    return mac[5] % 240;
}
