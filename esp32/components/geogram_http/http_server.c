/**
 * @file http_server.c
 * @brief HTTP server for WiFi configuration and APRS API (KV4P-only portal)
 */

#include <stdio.h>
#include <string.h>
#include "http_server.h"
#include "esp_http_server.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "esp_netif.h"
#include "esp_wifi.h"
#include "nvs_flash.h"
#include "nvs.h"
#include "station.h"
#include "app_config.h"

#if BOARD_MODEL == MODEL_ESP32S3_EPAPER_1IN54
#include "tiles.h"
#include "updates.h"
#include "ws_server.h"
#include "mesh_chat.h"
#include "mbedtls/base64.h"
#ifdef CONFIG_GEOGRAM_MESH_ENABLED
#include "mesh_bsp.h"
#endif
#endif

#if BOARD_MODEL == MODEL_KV4P
#include "aprs_store.h"
#include "sa818_radio.h"
#include "model_init.h"
#include "esp_ota_ops.h"
#include "esp_partition.h"
#include "wifi_bsp.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#endif

static const char *TAG = "http_server";

static httpd_handle_t s_server = NULL;
static wifi_config_callback_t s_config_callback = NULL;
static bool s_station_api_enabled = false;

#if BOARD_MODEL == MODEL_KV4P
// APRS TX queue — offloads radio transmission from the HTTP handler task
typedef struct {
    char from[APRS_MAX_CALLSIGN_LEN];
    char to[APRS_MAX_CALLSIGN_LEN];
    char message[APRS_MAX_MESSAGE_LEN];
} aprs_tx_item_t;

static QueueHandle_t s_aprs_tx_queue = NULL;

static void aprs_tx_task(void *arg)
{
    aprs_tx_item_t item;
    while (true) {
        if (xQueueReceive(s_aprs_tx_queue, &item, portMAX_DELAY) == pdTRUE) {
            sa818_radio_handle_t radio = model_get_sa818_radio();
            if (radio) {
                esp_err_t err = sa818_radio_send_aprs_message(radio, item.from, item.to, item.message);
                if (err != ESP_OK) {
                    ESP_LOGW(TAG, "APRS TX failed: %s", esp_err_to_name(err));
                }
            }
        }
    }
}

static void aprs_tx_queue_init(void)
{
    if (s_aprs_tx_queue == NULL) {
        s_aprs_tx_queue = xQueueCreate(4, sizeof(aprs_tx_item_t));
        if (s_aprs_tx_queue) {
            xTaskCreatePinnedToCore(aprs_tx_task, "aprs_tx", 8192, NULL, 5, NULL, 1);
        }
    }
}
#endif

/**
 * @brief Escape a string for JSON (handles quotes, backslashes, control chars)
 * @param dest Destination buffer (should be 2x src size + 1 for worst case)
 * @param dest_size Size of destination buffer
 * @param src Source string to escape
 */
static void json_escape_string(char *dest, size_t dest_size, const char *src)
{
    size_t di = 0;
    for (size_t si = 0; src[si] && di < dest_size - 1; si++) {
        char c = src[si];
        if (c == '"' || c == '\\') {
            if (di + 2 >= dest_size) break;
            dest[di++] = '\\';
            dest[di++] = c;
        } else if (c == '\n') {
            if (di + 2 >= dest_size) break;
            dest[di++] = '\\';
            dest[di++] = 'n';
        } else if (c == '\r') {
            if (di + 2 >= dest_size) break;
            dest[di++] = '\\';
            dest[di++] = 'r';
        } else if (c == '\t') {
            if (di + 2 >= dest_size) break;
            dest[di++] = '\\';
            dest[di++] = 't';
        } else if ((unsigned char)c < 32) {
            // Skip other control characters
            continue;
        } else {
            dest[di++] = c;
        }
    }
    dest[di] = '\0';
}

// ============================================================================
// APRS Page HTML (KV4P landing page)
// ============================================================================
#if BOARD_MODEL == MODEL_KV4P

static const char *APRS_PAGE_HTML =
    "<!DOCTYPE html>"
    "<html><head>"
    "<meta charset=\"utf-8\">"
    "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
    "<title>Geogram APRS</title>"
    "<style>"
    "*{box-sizing:border-box;margin:0;padding:0}"
    "body{font-family:monospace;background:#1a1a2e;color:#e0e0e0;padding:12px;max-width:600px;margin:0 auto}"
    "h1{color:#00d4ff;font-size:1.3em;margin-bottom:4px}"
    ".sub{color:#888;font-size:.85em;margin-bottom:12px}"
    ".bar{background:#16213e;padding:8px 12px;border-radius:6px;margin-bottom:12px;font-size:.85em;display:flex;justify-content:space-between;flex-wrap:wrap;gap:4px}"
    ".bar span{color:#0f0}"
    "#msgs{background:#0f0f23;border:1px solid #333;border-radius:6px;padding:8px;height:50vh;overflow-y:auto;margin-bottom:12px;font-size:.85em}"
    ".msg{padding:4px 0;border-bottom:1px solid #222}"
    ".msg .from{color:#00d4ff;font-weight:bold}"
    ".msg .to{color:#ff6b6b}"
    ".msg .ts{color:#666;font-size:.75em}"
    ".msg .body{color:#e0e0e0;word-break:break-word}"
    ".tx{background:#1a2a1a}"
    "form{display:flex;gap:6px;flex-wrap:wrap}"
    "input[type=text]{background:#16213e;border:1px solid #444;color:#fff;padding:8px;border-radius:4px;font-family:monospace}"
    "#to{width:90px}"
    "#message{flex:1;min-width:120px}"
    "button{background:#00d4ff;color:#000;border:none;padding:8px 16px;border-radius:4px;cursor:pointer;font-weight:bold;font-family:monospace}"
    "button:hover{background:#00b8d9}"
    "button:disabled{background:#555;color:#888}"
    ".nav{margin-top:12px;text-align:center}"
    ".nav a{color:#00d4ff;font-size:.85em}"
    "</style></head><body>"
    "<h1>Geogram APRS</h1>"
    "<div class=\"sub\" id=\"info\">Loading...</div>"
    "<div class=\"bar\" id=\"status\">Connecting...</div>"
    "<div id=\"msgs\"></div>"
    "<form id=\"sf\" onsubmit=\"return sendMsg()\">"
    "<input type=\"text\" id=\"to\" placeholder=\"TO call\" maxlength=\"9\" required>"
    "<input type=\"text\" id=\"message\" placeholder=\"Message\" maxlength=\"67\" required>"
    "<button type=\"submit\" id=\"btn\">SEND</button>"
    "</form>"
    "<div class=\"nav\"><a href=\"/setup\">WiFi Setup</a> | <a href=\"/ota\">Firmware Update</a></div>"
    "<script>"
    "var lastId=0,myCall='',polling=null,busy=false;"
    "function esc(s){var d=document.createElement('div');d.textContent=s;return d.innerHTML}"
    "function init(){"
    "poll();polling=setInterval(poll,2000);"
    "}"
    "function poll(){"
    "if(busy)return;busy=true;"
    "fetch('/api/aprs?since='+lastId).then(r=>r.json()).then(d=>{"
    "if(d.messages&&d.messages.length){"
    "var el=document.getElementById('msgs');"
    "d.messages.forEach(m=>{"
    "if(m.id>lastId)lastId=m.id;"
    "var div=document.createElement('div');"
    "div.className='msg'+(m.outgoing?' tx':'');"
    "var t=m.timestamp||0;var ts=Math.floor(t/60)+':'+(t%60<10?'0':'')+t%60;"
    "div.innerHTML='<span class=\"ts\">'+esc(ts)+'</span> '+"
    "'<span class=\"from\">'+esc(m.from||'?')+'</span> &rarr; '+"
    "'<span class=\"to\">'+esc(m.to||'?')+'</span><br>'+"
    "'<span class=\"body\">'+esc(m.message||'')+'</span>';"
    "el.appendChild(div);"
    "});"
    "el.scrollTop=el.scrollHeight;"
    "}"
    "return fetch('/api/aprs/status').then(r=>r.json()).then(s=>{"
    "if(!myCall){myCall=s.callsign||'NOCALL';document.getElementById('info').textContent=myCall+' | '+(s.frequency||'?')+' MHz';}"
    "document.getElementById('status').innerHTML="
    "'<span>RX: '+(s.total_rx||0)+'</span><span>TX: '+(s.total_tx||0)+'</span>'+"
    "'<span>'+(s.enabled?'Radio ON':'Radio OFF')+'</span>'+"
    "'<span>'+(s.tx_supported?'TX OK':'RX only')+'</span>';"
    "}).catch(()=>{if(!myCall)document.getElementById('info').textContent='Status unavailable';});"
    "}).catch(()=>{}).finally(()=>{busy=false;});"
    "}"
    "function sendMsg(){"
    "var to=document.getElementById('to').value.trim().toUpperCase();"
    "var msg=document.getElementById('message').value.trim();"
    "if(!to||!msg)return false;"
    "var btn=document.getElementById('btn');"
    "btn.disabled=true;btn.textContent='TX...';"
    "fetch('/api/aprs',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},"
    "body:'from='+encodeURIComponent(myCall)+'&to='+encodeURIComponent(to)+'&message='+encodeURIComponent(msg)"
    "}).then(r=>r.json()).then(d=>{"
    "if(d.ok){document.getElementById('message').value='';}"
    "else{alert('Send failed: '+(d.error||'unknown'));}"
    "}).catch(e=>{alert('Error: '+e);}).finally(()=>{btn.disabled=false;btn.textContent='SEND';});"
    "return false;"
    "}"
    "init();"
    "</script></body></html>";

#endif // MODEL_KV4P

// ============================================================================
// WiFi Setup Page HTML (scan-based network picker)
// ============================================================================

static const char *WIFI_SETUP_PAGE_HTML =
    "<!DOCTYPE html>"
    "<html><head>"
    "<meta charset=\"utf-8\">"
    "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
    "<title>Geogram WiFi Setup</title>"
    "<style>"
    "*{box-sizing:border-box;margin:0;padding:0}"
    "body{font-family:monospace;background:#1a1a2e;color:#e0e0e0;padding:12px;max-width:500px;margin:0 auto}"
    "h1{color:#00d4ff;font-size:1.3em;margin-bottom:12px}"
    "#nets{margin-bottom:12px}"
    ".net{background:#16213e;padding:10px 12px;border-radius:6px;margin-bottom:6px;cursor:pointer;display:flex;justify-content:space-between;align-items:center}"
    ".net:hover{background:#1a3a5e}"
    ".net.sel{border:2px solid #00d4ff}"
    ".net .ssid{font-weight:bold;word-break:break-all}"
    ".net .info{color:#888;font-size:.85em;text-align:right;white-space:nowrap;margin-left:8px}"
    ".lock::after{content:' \\1F512'}"
    "label{display:block;margin:10px 0 4px;color:#aaa;font-size:.9em}"
    "input[type=text],input[type=password],input[type=text].pw{width:100%;padding:10px;background:#16213e;border:1px solid #444;color:#fff;border-radius:4px;font-family:monospace;font-size:1em}"
    ".pw-row{position:relative}"
    ".pw-toggle{position:absolute;right:8px;top:50%;transform:translateY(-50%);background:none;border:none;color:#888;cursor:pointer;font-size:1.1em;padding:4px 8px;margin:0;width:auto}"
    "button{width:100%;padding:12px;background:#00d4ff;color:#000;border:none;border-radius:4px;cursor:pointer;font-weight:bold;font-size:1em;margin-top:12px;font-family:monospace}"
    "button:hover{background:#00b8d9}"
    "button:disabled{background:#555;color:#888}"
    ".loading{text-align:center;color:#888;padding:20px}"
    ".back{margin-top:12px;text-align:center}"
    ".back a{color:#00d4ff;font-size:.85em}"
    "#scanBtn{background:#333;color:#aaa;margin-bottom:8px}"
    "#result{margin-top:12px;padding:12px;border-radius:6px;display:none}"
    ".ok{background:#1a2a1a;border:1px solid #0f0;color:#0f0}"
    ".fail{background:#2a1a1a;border:1px solid #f66;color:#f66}"
    ".wait{background:#1a1a2e;border:1px solid #888;color:#aaa}"
    "</style></head><body>"
    "<h1>WiFi Setup</h1>"
    "<button id=\"scanBtn\" onclick=\"scan()\">Scan Networks</button>"
    "<div id=\"nets\"><div class=\"loading\">Scanning...</div></div>"
    "<form id=\"wf\" onsubmit=\"return doConnect()\">"
    "<label for=\"ssid\">Network Name (SSID)</label>"
    "<input type=\"text\" id=\"ssid\" name=\"ssid\" required maxlength=\"32\">"
    "<label for=\"password\">Password</label>"
    "<div class=\"pw-row\">"
    "<input type=\"password\" id=\"password\" name=\"password\" maxlength=\"64\">"
    "<button type=\"button\" class=\"pw-toggle\" onclick=\"togglePw()\" title=\"Show/hide password\">Show</button>"
    "</div>"
    "<button type=\"submit\" id=\"connBtn\">Connect</button>"
    "</form>"
    "<div id=\"result\"></div>"
    "<div class=\"back\"><a href=\"/\">APRS</a> | <a href=\"/ota\">Firmware Update</a></div>"
    "<script>"
    "function bars(r){if(r>-50)return'\\u2588\\u2588\\u2588\\u2588';if(r>-65)return'\\u2588\\u2588\\u2588\\u2591';if(r>-75)return'\\u2588\\u2588\\u2591\\u2591';return'\\u2588\\u2591\\u2591\\u2591';}"
    "function togglePw(){"
    "var p=document.getElementById('password'),b=event.target;"
    "if(p.type==='password'){p.type='text';b.textContent='Hide';}else{p.type='password';b.textContent='Show';}}"
    "function scan(){"
    "document.getElementById('nets').innerHTML='<div class=\"loading\">Scanning...</div>';"
    "fetch('/api/wifi/scan').then(r=>r.json()).then(d=>{"
    "var el=document.getElementById('nets');"
    "if(!d.networks||!d.networks.length){el.innerHTML='<div class=\"loading\">No networks found. Enter SSID manually.</div>';return;}"
    "el.innerHTML='';"
    "d.networks.forEach(n=>{"
    "var div=document.createElement('div');"
    "div.className='net';"
    "div.innerHTML='<span class=\"ssid\">'+esc(n.ssid)+'</span>'+"
    "'<span class=\"info\">'+(n.auth!=='OPEN'?'<span class=\"lock\"></span> ':'')+bars(n.rssi)+' '+n.rssi+'dBm</span>';"
    "div.onclick=function(){document.getElementById('ssid').value=n.ssid;"
    "document.querySelectorAll('.net').forEach(e=>e.classList.remove('sel'));"
    "div.classList.add('sel');document.getElementById('password').focus();};"
    "el.appendChild(div);"
    "});"
    "}).catch(()=>{document.getElementById('nets').innerHTML='<div class=\"loading\">Scan failed. Enter SSID manually.</div>';});"
    "}"
    "function showResult(cls,msg){var r=document.getElementById('result');r.className=cls;r.style.display='block';r.innerHTML=msg;}"
    "function doConnect(){"
    "var ssid=document.getElementById('ssid').value.trim();"
    "var pw=document.getElementById('password').value;"
    "if(!ssid)return false;"
    "var btn=document.getElementById('connBtn');"
    "btn.disabled=true;btn.textContent='Connecting...';"
    "showResult('wait','Sending credentials...');"
    "fetch('/connect',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},"
    "body:'ssid='+encodeURIComponent(ssid)+'&password='+encodeURIComponent(pw)"
    "}).then(r=>{if(!r.ok)throw new Error('HTTP '+r.status);"
    "showResult('wait','Connecting to '+esc(ssid)+'... (checking)');"
    "var tries=0,maxTries=15;"
    "var poll=setInterval(function(){"
    "tries++;"
    "fetch('/api/wifi/status').then(r=>r.json()).then(d=>{"
    "if(d.sta_connected&&d.sta_ip){"
    "clearInterval(poll);"
    "showResult('ok','Connected to <b>'+esc(ssid)+'</b><br>Device IP: <b>'+esc(d.sta_ip)+'</b><br><br>You can now reach the device at<br><a href=\"http://'+d.sta_ip+'/\" style=\"color:#0f0\">http://'+d.sta_ip+'/</a>');"
    "btn.textContent='Connected';}"
    "else if(tries>=maxTries){"
    "clearInterval(poll);"
    "showResult('fail','Failed to connect to <b>'+esc(ssid)+'</b>.<br>Check password and try again.');"
    "btn.disabled=false;btn.textContent='Connect';}"
    "else{showResult('wait','Connecting to '+esc(ssid)+'... ('+tries+'/'+maxTries+')');}"
    "}).catch(()=>{if(tries>=maxTries){clearInterval(poll);showResult('fail','Connection lost. Device may have restarted.');btn.disabled=false;btn.textContent='Connect';}});"
    "},2000);}).catch(e=>{showResult('fail','Error: '+e.message);btn.disabled=false;btn.textContent='Connect';});"
    "return false;}"
    "function esc(s){var d=document.createElement('div');d.textContent=s;return d.innerHTML;}"
    "scan();"
    "</script></body></html>";

// SUCCESS_PAGE_HTML removed — connect flow now uses JS polling with /api/wifi/status

// ============================================================================
// Utility functions
// ============================================================================

/**
 * @brief URL decode a string in-place
 */
static void url_decode(char *str)
{
    char *src = str;
    char *dst = str;

    while (*src) {
        if (*src == '%' && src[1] && src[2]) {
            char hex[3] = {src[1], src[2], 0};
            *dst++ = (char)strtol(hex, NULL, 16);
            src += 3;
        } else if (*src == '+') {
            *dst++ = ' ';
            src++;
        } else {
            *dst++ = *src++;
        }
    }
    *dst = '\0';
}

/**
 * @brief Extract value from form data
 */
static bool extract_form_value(const char *data, const char *key, char *value, size_t value_len)
{
    char search_key[64];
    snprintf(search_key, sizeof(search_key), "%s=", key);

    const char *start = strstr(data, search_key);
    if (start == NULL) {
        return false;
    }

    start += strlen(search_key);
    const char *end = strchr(start, '&');
    size_t len = end ? (size_t)(end - start) : strlen(start);

    if (len >= value_len) {
        len = value_len - 1;
    }

    strncpy(value, start, len);
    value[len] = '\0';
    url_decode(value);

    return true;
}

// ============================================================================
// Captive portal handlers
// ============================================================================

static bool get_softap_ip_string(char *out, size_t out_len)
{
    if (!out || out_len < 16) {
        return false;
    }

    esp_netif_t *ap_netif = esp_netif_get_handle_from_ifkey("WIFI_AP_DEF");
    if (!ap_netif) {
        return false;
    }

    esp_netif_ip_info_t ip_info;
    if (esp_netif_get_ip_info(ap_netif, &ip_info) != ESP_OK || ip_info.ip.addr == 0) {
        return false;
    }

    snprintf(out, out_len, IPSTR, IP2STR(&ip_info.ip));
    return true;
}

static void set_captive_redirect_headers(httpd_req_t *req)
{
    char ap_ip[16] = {0};
    char location[40] = "/";
    if (get_softap_ip_string(ap_ip, sizeof(ap_ip))) {
        snprintf(location, sizeof(location), "http://%s/", ap_ip);
    }

    httpd_resp_set_status(req, "302 Found");
    httpd_resp_set_hdr(req, "Location", location);
    httpd_resp_set_hdr(req, "Cache-Control", "no-cache, no-store, must-revalidate");
    httpd_resp_set_hdr(req, "Pragma", "no-cache");
    httpd_resp_set_hdr(req, "Expires", "0");
}

static esp_err_t captive_portal_handler(httpd_req_t *req)
{
    set_captive_redirect_headers(req);
    httpd_resp_send(req, NULL, 0);
    return ESP_OK;
}

/**
 * @brief Custom 404 handler - redirect unknown URIs to main page for captive portal
 */
static esp_err_t http_404_redirect_handler(httpd_req_t *req, httpd_err_code_t err)
{
    set_captive_redirect_headers(req);
    httpd_resp_send(req, NULL, 0);
    return ESP_FAIL;  // Close socket after redirect
}

// ============================================================================
// Page handlers
// ============================================================================

/**
 * @brief Handler for root page - serves APRS page on KV4P, landing page on others
 */
static esp_err_t root_get_handler(httpd_req_t *req)
{
#if BOARD_MODEL == MODEL_KV4P
    ESP_LOGI(TAG, "HTTP GET / (APRS page)");
    httpd_resp_set_type(req, "text/html");
    httpd_resp_send(req, APRS_PAGE_HTML, strlen(APRS_PAGE_HTML));
#else
    ESP_LOGI(TAG, "HTTP GET / (setup redirect)");
    httpd_resp_set_type(req, "text/html");
    httpd_resp_send(req, WIFI_SETUP_PAGE_HTML, strlen(WIFI_SETUP_PAGE_HTML));
#endif
    return ESP_OK;
}

/**
 * @brief Handler for setup page (WiFi scan-based picker)
 */
static esp_err_t setup_get_handler(httpd_req_t *req)
{
    httpd_resp_set_type(req, "text/html");
    httpd_resp_send(req, WIFI_SETUP_PAGE_HTML, strlen(WIFI_SETUP_PAGE_HTML));
    return ESP_OK;
}

/**
 * @brief Handler for WiFi configuration POST
 */
static esp_err_t connect_post_handler(httpd_req_t *req)
{
    char content[256];
    int ret;

    int total_len = req->content_len;
    if (total_len >= sizeof(content)) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Content too long");
        return ESP_FAIL;
    }

    ret = httpd_req_recv(req, content, total_len);
    if (ret <= 0) {
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "Failed to receive data");
        return ESP_FAIL;
    }
    content[total_len] = '\0';

    ESP_LOGI(TAG, "Received config: %s", content);

    char ssid[33] = {0};
    char password[65] = {0};

    if (!extract_form_value(content, "ssid", ssid, sizeof(ssid))) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Missing SSID");
        return ESP_FAIL;
    }

    extract_form_value(content, "password", password, sizeof(password));

    ESP_LOGI(TAG, "WiFi config received - SSID: %s", ssid);

    nvs_handle_t nvs;
    esp_err_t err = nvs_open("wifi_config", NVS_READWRITE, &nvs);
    if (err == ESP_OK) {
        nvs_set_str(nvs, "ssid", ssid);
        nvs_set_str(nvs, "password", password);
        nvs_commit(nvs);
        nvs_close(nvs);
        ESP_LOGI(TAG, "WiFi credentials saved to NVS");
    }

    if (s_config_callback != NULL) {
        s_config_callback(ssid, password);
        httpd_resp_set_type(req, "application/json");
        httpd_resp_send(req, "{\"ok\":true}", -1);
    } else {
        // No callback — attempt STA connection directly (KV4P standalone mode)
        ESP_LOGI(TAG, "Connecting to WiFi: %s", ssid);
        esp_err_t conn_err = geogram_wifi_connect_sta(ssid, password);
        httpd_resp_set_type(req, "application/json");
        if (conn_err != ESP_OK) {
            httpd_resp_send(req, "{\"ok\":false,\"error\":\"connect failed\"}", -1);
        } else {
            httpd_resp_send(req, "{\"ok\":true}", -1);
        }
    }

    return ESP_OK;
}

// ============================================================================
// Status handlers
// ============================================================================

static esp_err_t status_get_handler(httpd_req_t *req)
{
    char response[128];
    snprintf(response, sizeof(response), "{\"status\":\"ok\",\"device\":\"geogram\"}");

    httpd_resp_set_type(req, "application/json");
    httpd_resp_send(req, response, strlen(response));
    return ESP_OK;
}

static esp_err_t api_status_get_handler(httpd_req_t *req)
{
    char response[512];
    size_t len = station_build_status_json(response, sizeof(response));

    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    httpd_resp_send(req, response, len);
    return ESP_OK;
}

// ============================================================================
// WiFi Scan API Handler
// ============================================================================

/**
 * @brief Handler for GET /api/wifi/scan — scan for available WiFi networks
 */
static esp_err_t api_wifi_scan_get_handler(httpd_req_t *req)
{
    ESP_LOGI(TAG, "WiFi scan requested");

    // WiFi scan requires STA interface — switch to AP+STA mode if needed
    wifi_mode_t mode;
    esp_wifi_get_mode(&mode);
    if (mode == WIFI_MODE_AP) {
        ESP_LOGI(TAG, "Switching to APSTA mode for scan");
        esp_wifi_stop();
        esp_wifi_set_mode(WIFI_MODE_APSTA);
        esp_wifi_start();
    }

    wifi_scan_config_t scan_config = {
        .ssid = NULL,
        .bssid = NULL,
        .channel = 0,
        .show_hidden = false,
        .scan_type = WIFI_SCAN_TYPE_ACTIVE,
        .scan_time.active.min = 100,
        .scan_time.active.max = 300,
    };

    esp_err_t err = esp_wifi_scan_start(&scan_config, true);  // blocking
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "WiFi scan failed: %s", esp_err_to_name(err));
        httpd_resp_set_type(req, "application/json");
        httpd_resp_send(req, "{\"networks\":[]}", -1);
        return ESP_OK;
    }

    uint16_t ap_count = 0;
    esp_wifi_scan_get_ap_num(&ap_count);
    if (ap_count == 0) {
        httpd_resp_set_type(req, "application/json");
        httpd_resp_send(req, "{\"networks\":[]}", -1);
        return ESP_OK;
    }

    if (ap_count > 20) ap_count = 20;  // cap to save memory

    wifi_ap_record_t *ap_records = malloc(sizeof(wifi_ap_record_t) * ap_count);
    if (!ap_records) {
        esp_wifi_scan_get_ap_records(&ap_count, NULL);  // clear scan results
        httpd_resp_set_type(req, "application/json");
        httpd_resp_send(req, "{\"networks\":[]}", -1);
        return ESP_OK;
    }

    esp_wifi_scan_get_ap_records(&ap_count, ap_records);

    // Deduplicate by SSID and keep strongest signal
    // Simple O(n^2) dedup — fine for max 20 entries
    bool *skip = calloc(ap_count, sizeof(bool));
    if (skip) {
        for (int i = 0; i < ap_count; i++) {
            if (skip[i] || ap_records[i].ssid[0] == '\0') {
                skip[i] = true;
                continue;
            }
            for (int j = i + 1; j < ap_count; j++) {
                if (!skip[j] && strcmp((char *)ap_records[i].ssid, (char *)ap_records[j].ssid) == 0) {
                    // Keep the one with stronger signal
                    if (ap_records[j].rssi > ap_records[i].rssi) {
                        skip[i] = true;
                        break;
                    } else {
                        skip[j] = true;
                    }
                }
            }
        }
    }

    // Build JSON response
    const size_t buf_size = 2048;
    char *buf = malloc(buf_size);
    if (!buf) {
        free(ap_records);
        free(skip);
        httpd_resp_set_type(req, "application/json");
        httpd_resp_send(req, "{\"networks\":[]}", -1);
        return ESP_OK;
    }

    size_t pos = 0;
    pos += snprintf(buf + pos, buf_size - pos, "{\"networks\":[");

    bool first = true;
    for (int i = 0; i < ap_count && pos < buf_size - 100; i++) {
        if (skip && skip[i]) continue;
        if (ap_records[i].ssid[0] == '\0') continue;

        const char *auth_str;
        switch (ap_records[i].authmode) {
            case WIFI_AUTH_OPEN:            auth_str = "OPEN"; break;
            case WIFI_AUTH_WEP:             auth_str = "WEP"; break;
            case WIFI_AUTH_WPA_PSK:         auth_str = "WPA"; break;
            case WIFI_AUTH_WPA2_PSK:        auth_str = "WPA2"; break;
            case WIFI_AUTH_WPA_WPA2_PSK:    auth_str = "WPA/WPA2"; break;
            case WIFI_AUTH_WPA3_PSK:        auth_str = "WPA3"; break;
            case WIFI_AUTH_WPA2_WPA3_PSK:   auth_str = "WPA2/WPA3"; break;
            default:                        auth_str = "OTHER"; break;
        }

        char escaped_ssid[66];
        json_escape_string(escaped_ssid, sizeof(escaped_ssid), (const char *)ap_records[i].ssid);

        if (!first) pos += snprintf(buf + pos, buf_size - pos, ",");
        first = false;

        pos += snprintf(buf + pos, buf_size - pos,
            "{\"ssid\":\"%s\",\"rssi\":%d,\"auth\":\"%s\"}",
            escaped_ssid, ap_records[i].rssi, auth_str);
    }

    pos += snprintf(buf + pos, buf_size - pos, "]}");

    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    httpd_resp_send(req, buf, pos);

    free(buf);
    free(ap_records);
    free(skip);
    return ESP_OK;
}

/**
 * @brief Handler for GET /api/wifi/status — STA connection state and IP
 */
static esp_err_t api_wifi_status_get_handler(httpd_req_t *req)
{
    char buf[192];
    bool sta_connected = false;
    char ip_str[16] = "0.0.0.0";

    // Check if STA interface has an IP
    esp_netif_t *sta_netif = esp_netif_get_handle_from_ifkey("WIFI_STA_DEF");
    if (sta_netif) {
        esp_netif_ip_info_t ip_info;
        if (esp_netif_get_ip_info(sta_netif, &ip_info) == ESP_OK && ip_info.ip.addr != 0) {
            sta_connected = true;
            snprintf(ip_str, sizeof(ip_str), IPSTR, IP2STR(&ip_info.ip));
        }
    }

    int len = snprintf(buf, sizeof(buf),
        "{\"sta_connected\":%s,\"sta_ip\":\"%s\"}",
        sta_connected ? "true" : "false",
        ip_str);

    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    httpd_resp_send(req, buf, len);
    return ESP_OK;
}

// ============================================================================
// APRS API Handlers (KV4P only)
// ============================================================================
#if BOARD_MODEL == MODEL_KV4P

/**
 * @brief Handler for GET /api/aprs — list APRS messages since given ID
 */
static esp_err_t api_aprs_get_handler(httpd_req_t *req)
{
    char query[64] = {0};
    uint32_t since_id = 0;

    if (httpd_req_get_url_query_str(req, query, sizeof(query)) == ESP_OK) {
        char param[16];
        if (httpd_query_key_value(query, "since", param, sizeof(param)) == ESP_OK) {
            since_id = (uint32_t)strtoul(param, NULL, 10);
        }
    }

    const size_t buffer_size = 8192;
    char *buffer = malloc(buffer_size);
    if (!buffer) {
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "Out of memory");
        return ESP_FAIL;
    }

    size_t len = aprs_store_build_json(buffer, buffer_size, since_id);

    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    httpd_resp_send(req, buffer, len);

    free(buffer);
    return ESP_OK;
}

/**
 * @brief Handler for POST /api/aprs — send an APRS message
 */
static esp_err_t api_aprs_post_handler(httpd_req_t *req)
{
    char *content = malloc(512);
    if (!content) {
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "Out of memory");
        return ESP_FAIL;
    }

    int total_len = req->content_len;
    if (total_len >= 512) {
        free(content);
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Content too long");
        return ESP_FAIL;
    }

    int ret = httpd_req_recv(req, content, total_len);
    if (ret <= 0) {
        free(content);
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "Failed to receive data");
        return ESP_FAIL;
    }
    content[total_len] = '\0';

    char from[APRS_MAX_CALLSIGN_LEN] = {0};
    char to[APRS_MAX_CALLSIGN_LEN] = {0};
    char message[APRS_MAX_MESSAGE_LEN] = {0};

    if (!extract_form_value(content, "from", from, sizeof(from)) || from[0] == '\0') {
        free(content);
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "{\"error\":\"Missing 'from' parameter\"}");
        return ESP_FAIL;
    }
    if (!extract_form_value(content, "to", to, sizeof(to)) || to[0] == '\0') {
        free(content);
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "{\"error\":\"Missing 'to' parameter\"}");
        return ESP_FAIL;
    }
    if (!extract_form_value(content, "message", message, sizeof(message))) {
        free(content);
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "{\"error\":\"Missing 'message' parameter\"}");
        return ESP_FAIL;
    }

    free(content);

    // Queue TX for background task (don't block HTTP handler)
    sa818_radio_handle_t radio = model_get_sa818_radio();
    if (!radio || !s_aprs_tx_queue) {
        httpd_resp_set_type(req, "application/json");
        httpd_resp_send(req, "{\"ok\":false,\"error\":\"Radio not available\"}", -1);
        return ESP_OK;
    }

    {
        aprs_tx_item_t item;
        strncpy(item.from, from, sizeof(item.from) - 1);
        item.from[sizeof(item.from) - 1] = '\0';
        strncpy(item.to, to, sizeof(item.to) - 1);
        item.to[sizeof(item.to) - 1] = '\0';
        strncpy(item.message, message, sizeof(item.message) - 1);
        item.message[sizeof(item.message) - 1] = '\0';

        if (xQueueSend(s_aprs_tx_queue, &item, 0) != pdTRUE) {
            httpd_resp_set_type(req, "application/json");
            httpd_resp_send(req, "{\"ok\":false,\"error\":\"TX queue full\"}", -1);
            return ESP_OK;
        }
    }

    // Store in APRS history immediately (TX task handles radio)
    aprs_store_add_tx(from, to, message);

    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    httpd_resp_send(req, "{\"ok\":true}", 11);
    return ESP_OK;
}

/**
 * @brief Handler for GET /api/aprs/status — APRS radio status
 */
static esp_err_t api_aprs_status_get_handler(httpd_req_t *req)
{
    char buf[320];
    bool enabled = false;
    float freq = 0.0f;
    bool tx_supported = false;
    const char *callsign = "NOCALL";

    sa818_radio_handle_t radio = model_get_sa818_radio();
    if (radio) {
        enabled = sa818_radio_is_powered(radio);
        freq = sa818_radio_get_aprs_frequency(radio);
        tx_supported = sa818_radio_is_aprs_tx_supported(radio);
    }

    // Get callsign from station config
    const char *cfg_call = station_get_callsign();
    if (cfg_call && cfg_call[0]) {
        callsign = cfg_call;
    }

    int len = snprintf(buf, sizeof(buf),
        "{\"enabled\":%s,\"frequency\":%.3f,"
        "\"tx_supported\":%s,"
        "\"callsign\":\"%s\","
        "\"total_rx\":%lu,\"total_tx\":%lu}",
        enabled ? "true" : "false",
        (double)freq,
        tx_supported ? "true" : "false",
        callsign,
        (unsigned long)aprs_store_get_total_rx(),
        (unsigned long)aprs_store_get_total_tx());

    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    httpd_resp_send(req, buf, len);
    return ESP_OK;
}

/**
 * @brief Handler for GET /api/radio/diag — radio diagnostic info
 */
static esp_err_t api_radio_diag_get_handler(httpd_req_t *req)
{
    char buf[256];
    sa818_radio_handle_t radio = model_get_sa818_radio();
    esp_err_t init_err = model_get_radio_init_error();

    int len = snprintf(buf, sizeof(buf),
        "{\"radio_handle\":%s,"
        "\"init_error\":\"%s\","
        "\"init_error_code\":%d,"
        "\"powered\":%s,"
        "\"frequency\":%.3f}",
        radio ? "true" : "false",
        esp_err_to_name(init_err),
        (int)init_err,
        (radio && sa818_radio_is_powered(radio)) ? "true" : "false",
        radio ? (double)sa818_radio_get_aprs_frequency(radio) : 0.0);

    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    httpd_resp_send(req, buf, len);
    return ESP_OK;
}

/**
 * @brief Handler for POST /api/radio/retry — retry radio initialization
 */
static esp_err_t api_radio_retry_post_handler(httpd_req_t *req)
{
    char buf[128];
    esp_err_t ret = model_retry_radio_init();
    sa818_radio_handle_t radio = model_get_sa818_radio();

    int len = snprintf(buf, sizeof(buf),
        "{\"ok\":%s,\"error\":\"%s\",\"powered\":%s}",
        ret == ESP_OK ? "true" : "false",
        esp_err_to_name(ret),
        (radio && sa818_radio_is_powered(radio)) ? "true" : "false");

    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    httpd_resp_send(req, buf, len);
    return ESP_OK;
}

// ============================================================================
// OTA Update Page HTML (KV4P only)
// ============================================================================

static const char *OTA_PAGE_HTML =
    "<!DOCTYPE html>"
    "<html><head>"
    "<meta charset=\"utf-8\">"
    "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
    "<title>Geogram Firmware Update</title>"
    "<style>"
    "*{box-sizing:border-box;margin:0;padding:0}"
    "body{font-family:monospace;background:#1a1a2e;color:#e0e0e0;padding:12px;max-width:500px;margin:0 auto}"
    "h1{color:#00d4ff;font-size:1.3em;margin-bottom:12px}"
    ".info{background:#16213e;padding:10px 12px;border-radius:6px;margin-bottom:12px;font-size:.9em}"
    ".info span{color:#0f0}"
    "label{display:block;margin:12px 0 4px;color:#aaa;font-size:.9em}"
    "input[type=file]{width:100%;padding:10px;background:#16213e;border:1px solid #444;color:#fff;border-radius:4px;font-family:monospace}"
    "button{width:100%;padding:12px;background:#00d4ff;color:#000;border:none;border-radius:4px;cursor:pointer;font-weight:bold;font-size:1em;margin-top:12px;font-family:monospace}"
    "button:hover{background:#00b8d9}"
    "button:disabled{background:#555;color:#888}"
    ".progress{display:none;margin-top:12px}"
    ".progress-bar{background:#333;border-radius:4px;height:24px;overflow:hidden}"
    ".progress-fill{background:#00d4ff;height:100%;width:0;transition:width .3s;text-align:center;line-height:24px;color:#000;font-weight:bold;font-size:.85em}"
    "#status{margin-top:12px;padding:10px;border-radius:6px;display:none;font-size:.9em}"
    ".ok{background:#1a2a1a;border:1px solid #0f0;color:#0f0}"
    ".fail{background:#2a1a1a;border:1px solid #f66;color:#f66}"
    ".wait{background:#1a1a2e;border:1px solid #888;color:#aaa}"
    ".nav{margin-top:12px;text-align:center}"
    ".nav a{color:#00d4ff;font-size:.85em;margin:0 8px}"
    "</style></head><body>"
    "<h1>Firmware Update</h1>"
    "<div class=\"info\" id=\"info\">Loading...</div>"
    "<form id=\"uf\">"
    "<label for=\"fw\">Select firmware binary (.bin)</label>"
    "<input type=\"file\" id=\"fw\" accept=\".bin\" required>"
    "<button type=\"submit\" id=\"btn\">Upload &amp; Install</button>"
    "</form>"
    "<div class=\"progress\" id=\"prog\">"
    "<div class=\"progress-bar\"><div class=\"progress-fill\" id=\"pbar\">0%</div></div>"
    "</div>"
    "<div id=\"status\"></div>"
    "<div class=\"nav\"><a href=\"/\">APRS</a> | <a href=\"/setup\">WiFi Setup</a></div>"
    "<script>"
    "function showStatus(cls,msg){var s=document.getElementById('status');s.className=cls;s.style.display='block';s.innerHTML=msg;}"
    "function loadInfo(){"
    "fetch('/api/ota/status').then(r=>r.json()).then(d=>{"
    "document.getElementById('info').innerHTML="
    "'Version: <span>'+d.version+'</span> | Partition: <span>'+d.partition+'</span>';"
    "}).catch(()=>{document.getElementById('info').textContent='Could not load device info';});"
    "}"
    "document.getElementById('uf').onsubmit=function(e){"
    "e.preventDefault();"
    "var file=document.getElementById('fw').files[0];"
    "if(!file){alert('Select a file');return;}"
    "if(!file.name.endsWith('.bin')){alert('Must be a .bin file');return;}"
    "var btn=document.getElementById('btn');"
    "btn.disabled=true;btn.textContent='Uploading...';"
    "var prog=document.getElementById('prog');prog.style.display='block';"
    "var pbar=document.getElementById('pbar');"
    "var xhr=new XMLHttpRequest();"
    "xhr.open('POST','/api/ota',true);"
    "xhr.setRequestHeader('Content-Type','application/octet-stream');"
    "xhr.upload.onprogress=function(ev){"
    "if(ev.lengthComputable){var pct=Math.round(ev.loaded/ev.total*100);pbar.style.width=pct+'%';pbar.textContent=pct+'%';}"
    "};"
    "xhr.onload=function(){"
    "if(xhr.status===200){"
    "showStatus('wait','Firmware written. Device is rebooting...');"
    "btn.textContent='Rebooting...';"
    "setTimeout(function(){pollReboot(0);},3000);"
    "}else{"
    "var msg='Upload failed';try{msg=JSON.parse(xhr.responseText).error||msg;}catch(e){}"
    "showStatus('fail',msg);btn.disabled=false;btn.textContent='Upload & Install';}"
    "};"
    "xhr.onerror=function(){"
    "showStatus('wait','Connection lost — device may be rebooting...');"
    "btn.textContent='Rebooting...';"
    "setTimeout(function(){pollReboot(0);},3000);"
    "};"
    "xhr.send(file);"
    "};"
    "function pollReboot(n){"
    "if(n>20){showStatus('fail','Device did not come back. Check manually.');return;}"
    "fetch('/api/ota/status').then(r=>r.json()).then(d=>{"
    "showStatus('ok','Firmware updated!<br>Version: '+d.version+' | Partition: '+d.partition);"
    "document.getElementById('btn').textContent='Done';loadInfo();"
    "}).catch(()=>{setTimeout(function(){pollReboot(n+1);},2000);});"
    "}"
    "loadInfo();"
    "</script></body></html>";

// ============================================================================
// OTA Handlers (KV4P only)
// ============================================================================

/**
 * @brief Handler for GET /ota — firmware update web page
 */
static esp_err_t ota_page_get_handler(httpd_req_t *req)
{
    httpd_resp_set_type(req, "text/html");
    httpd_resp_send(req, OTA_PAGE_HTML, strlen(OTA_PAGE_HTML));
    return ESP_OK;
}

/**
 * @brief Handler for GET /api/ota/status — current firmware info
 */
static esp_err_t api_ota_status_get_handler(httpd_req_t *req)
{
    char buf[192];
    const esp_partition_t *running = esp_ota_get_running_partition();
    const char *part_label = running ? running->label : "unknown";

    // Check if OTA is possible (need at least one OTA partition)
    const esp_partition_t *next = esp_ota_get_next_update_partition(NULL);
    bool ota_ready = (next != NULL);

    int len = snprintf(buf, sizeof(buf),
        "{\"version\":\"%s\",\"partition\":\"%s\",\"ota_ready\":%s}",
        GEOGRAM_VERSION,
        part_label,
        ota_ready ? "true" : "false");

    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    httpd_resp_send(req, buf, len);
    return ESP_OK;
}

/**
 * @brief Handler for POST /api/ota — receive firmware binary and flash it
 */
static esp_err_t api_ota_post_handler(httpd_req_t *req)
{
    ESP_LOGI(TAG, "OTA update started, content_len=%d", req->content_len);

    if (req->content_len <= 0) {
        httpd_resp_set_type(req, "application/json");
        httpd_resp_send(req, "{\"error\":\"No data received\"}", -1);
        return ESP_FAIL;
    }

    const esp_partition_t *update_partition = esp_ota_get_next_update_partition(NULL);
    if (!update_partition) {
        ESP_LOGE(TAG, "No OTA partition available");
        httpd_resp_set_type(req, "application/json");
        httpd_resp_send(req, "{\"error\":\"No OTA partition available\"}", -1);
        return ESP_FAIL;
    }

    ESP_LOGI(TAG, "Writing to partition '%s' at offset 0x%lx, size 0x%lx",
             update_partition->label,
             (unsigned long)update_partition->address,
             (unsigned long)update_partition->size);

    if ((size_t)req->content_len > update_partition->size) {
        ESP_LOGE(TAG, "Firmware too large: %d > %lu",
                 req->content_len, (unsigned long)update_partition->size);
        httpd_resp_set_type(req, "application/json");
        httpd_resp_send(req, "{\"error\":\"Firmware too large for partition\"}", -1);
        return ESP_FAIL;
    }

    esp_ota_handle_t ota_handle = 0;
    esp_err_t err;

    // Allocate receive buffer
    const size_t buf_size = 4096;
    char *buf = malloc(buf_size);
    if (!buf) {
        httpd_resp_set_type(req, "application/json");
        httpd_resp_send(req, "{\"error\":\"Out of memory\"}", -1);
        return ESP_FAIL;
    }

    int remaining = req->content_len;
    bool first_chunk = true;
    int received_total = 0;

    while (remaining > 0) {
        int recv_len = httpd_req_recv(req, buf, (remaining < (int)buf_size) ? remaining : (int)buf_size);
        if (recv_len <= 0) {
            if (recv_len == HTTPD_SOCK_ERR_TIMEOUT) {
                continue;  // retry on timeout
            }
            ESP_LOGE(TAG, "OTA recv error: %d", recv_len);
            if (!first_chunk) {
                esp_ota_abort(ota_handle);
            }
            free(buf);
            httpd_resp_set_type(req, "application/json");
            httpd_resp_send(req, "{\"error\":\"Connection lost during upload\"}", -1);
            return ESP_FAIL;
        }

        if (first_chunk) {
            // Validate: ESP32 firmware starts with magic byte 0xE9
            if ((uint8_t)buf[0] != 0xE9) {
                ESP_LOGE(TAG, "Invalid firmware image (magic=0x%02x)", (uint8_t)buf[0]);
                free(buf);
                httpd_resp_set_type(req, "application/json");
                httpd_resp_send(req, "{\"error\":\"Invalid firmware image\"}", -1);
                return ESP_FAIL;
            }

            err = esp_ota_begin(update_partition, req->content_len, &ota_handle);
            if (err != ESP_OK) {
                ESP_LOGE(TAG, "esp_ota_begin failed: %s", esp_err_to_name(err));
                free(buf);
                httpd_resp_set_type(req, "application/json");
                char errbuf[96];
                snprintf(errbuf, sizeof(errbuf), "{\"error\":\"OTA begin failed: %s\"}", esp_err_to_name(err));
                httpd_resp_send(req, errbuf, -1);
                return ESP_FAIL;
            }
            first_chunk = false;
        }

        err = esp_ota_write(ota_handle, buf, recv_len);
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "esp_ota_write failed: %s", esp_err_to_name(err));
            esp_ota_abort(ota_handle);
            free(buf);
            httpd_resp_set_type(req, "application/json");
            httpd_resp_send(req, "{\"error\":\"Flash write failed\"}", -1);
            return ESP_FAIL;
        }

        remaining -= recv_len;
        received_total += recv_len;

        if (received_total % (64 * 1024) < recv_len) {
            ESP_LOGI(TAG, "OTA progress: %d / %d bytes", received_total, req->content_len);
        }
    }

    free(buf);

    err = esp_ota_end(ota_handle);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "esp_ota_end failed: %s", esp_err_to_name(err));
        httpd_resp_set_type(req, "application/json");
        char errbuf[96];
        snprintf(errbuf, sizeof(errbuf), "{\"error\":\"Validation failed: %s\"}", esp_err_to_name(err));
        httpd_resp_send(req, errbuf, -1);
        return ESP_FAIL;
    }

    err = esp_ota_set_boot_partition(update_partition);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "esp_ota_set_boot_partition failed: %s", esp_err_to_name(err));
        httpd_resp_set_type(req, "application/json");
        httpd_resp_send(req, "{\"error\":\"Failed to set boot partition\"}", -1);
        return ESP_FAIL;
    }

    ESP_LOGI(TAG, "OTA update successful (%d bytes), rebooting...", received_total);

    httpd_resp_set_type(req, "application/json");
    httpd_resp_send(req, "{\"ok\":true}", -1);

    // Give the HTTP response time to be sent before rebooting
    vTaskDelay(pdMS_TO_TICKS(500));
    esp_restart();

    return ESP_OK;  // unreachable
}

static const httpd_uri_t uri_ota_page = {
    .uri = "/ota",
    .method = HTTP_GET,
    .handler = ota_page_get_handler,
    .user_ctx = NULL
};

static const httpd_uri_t uri_api_ota_status = {
    .uri = "/api/ota/status",
    .method = HTTP_GET,
    .handler = api_ota_status_get_handler,
    .user_ctx = NULL
};

static const httpd_uri_t uri_api_ota_upload = {
    .uri = "/api/ota",
    .method = HTTP_POST,
    .handler = api_ota_post_handler,
    .user_ctx = NULL
};

static const httpd_uri_t uri_api_aprs = {
    .uri = "/api/aprs",
    .method = HTTP_GET,
    .handler = api_aprs_get_handler,
    .user_ctx = NULL
};

static const httpd_uri_t uri_api_aprs_send = {
    .uri = "/api/aprs",
    .method = HTTP_POST,
    .handler = api_aprs_post_handler,
    .user_ctx = NULL
};

static const httpd_uri_t uri_api_aprs_status = {
    .uri = "/api/aprs/status",
    .method = HTTP_GET,
    .handler = api_aprs_status_get_handler,
    .user_ctx = NULL
};

static const httpd_uri_t uri_api_radio_diag = {
    .uri = "/api/radio/diag",
    .method = HTTP_GET,
    .handler = api_radio_diag_get_handler,
    .user_ctx = NULL
};

static const httpd_uri_t uri_api_radio_retry = {
    .uri = "/api/radio/retry",
    .method = HTTP_POST,
    .handler = api_radio_retry_post_handler,
    .user_ctx = NULL
};

#endif // BOARD_MODEL == MODEL_KV4P

// ============================================================================
// URI definitions
// ============================================================================

static const httpd_uri_t uri_root = {
    .uri = "/",
    .method = HTTP_GET,
    .handler = root_get_handler,
    .user_ctx = NULL
};

static const httpd_uri_t uri_setup = {
    .uri = "/setup",
    .method = HTTP_GET,
    .handler = setup_get_handler,
    .user_ctx = NULL
};

static const httpd_uri_t uri_connect = {
    .uri = "/connect",
    .method = HTTP_POST,
    .handler = connect_post_handler,
    .user_ctx = NULL
};

static const httpd_uri_t uri_status = {
    .uri = "/status",
    .method = HTTP_GET,
    .handler = status_get_handler,
    .user_ctx = NULL
};

static const httpd_uri_t uri_api_status = {
    .uri = "/api/status",
    .method = HTTP_GET,
    .handler = api_status_get_handler,
    .user_ctx = NULL
};

static const httpd_uri_t uri_wifi_scan = {
    .uri = "/api/wifi/scan",
    .method = HTTP_GET,
    .handler = api_wifi_scan_get_handler,
    .user_ctx = NULL
};

static const httpd_uri_t uri_wifi_status = {
    .uri = "/api/wifi/status",
    .method = HTTP_GET,
    .handler = api_wifi_status_get_handler,
    .user_ctx = NULL
};

// Captive portal detection URIs
static const httpd_uri_t uri_generate_204 = {
    .uri = "/generate_204",
    .method = HTTP_GET,
    .handler = captive_portal_handler,
    .user_ctx = NULL
};

static const httpd_uri_t uri_hotspot_detect = {
    .uri = "/hotspot-detect.html",
    .method = HTTP_GET,
    .handler = captive_portal_handler,
    .user_ctx = NULL
};

// ============================================================================
// Server start/stop
// ============================================================================

esp_err_t http_server_start(wifi_config_callback_t callback)
{
    return http_server_start_ex(callback, false);
}

esp_err_t http_server_start_ex(wifi_config_callback_t callback, bool enable_station_api)
{
    if (s_server != NULL) {
        ESP_LOGW(TAG, "Server already running");
        return ESP_OK;
    }

    s_config_callback = callback;
    s_station_api_enabled = enable_station_api;

    httpd_config_t config = HTTPD_DEFAULT_CONFIG();
    config.lru_purge_enable = true;
    config.stack_size = 12288;
    config.max_uri_handlers = 18;
    config.max_open_sockets = 5;
    config.recv_wait_timeout = 5;
    config.send_wait_timeout = 5;

    ESP_LOGI(TAG, "Starting HTTP server on port %d (station_api=%d)", config.server_port, enable_station_api);

    esp_err_t ret = httpd_start(&s_server, &config);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to start HTTP server: %s", esp_err_to_name(ret));
        return ret;
    }

    // Register custom 404 handler for captive portal redirect
    httpd_register_err_handler(s_server, HTTPD_404_NOT_FOUND, http_404_redirect_handler);

    // Register base URI handlers
    httpd_register_uri_handler(s_server, &uri_root);
    httpd_register_uri_handler(s_server, &uri_setup);
    httpd_register_uri_handler(s_server, &uri_connect);
    httpd_register_uri_handler(s_server, &uri_status);
    httpd_register_uri_handler(s_server, &uri_wifi_scan);
    httpd_register_uri_handler(s_server, &uri_wifi_status);

    // Register captive portal handlers
    httpd_register_uri_handler(s_server, &uri_generate_204);
    httpd_register_uri_handler(s_server, &uri_hotspot_detect);

    // Register Station API handlers if enabled
    if (enable_station_api) {
        httpd_register_uri_handler(s_server, &uri_api_status);

#if BOARD_MODEL == MODEL_KV4P
        // Register APRS API endpoints and start TX task
        aprs_tx_queue_init();
        httpd_register_uri_handler(s_server, &uri_api_aprs);
        httpd_register_uri_handler(s_server, &uri_api_aprs_send);
        httpd_register_uri_handler(s_server, &uri_api_aprs_status);
        httpd_register_uri_handler(s_server, &uri_api_radio_diag);
        httpd_register_uri_handler(s_server, &uri_api_radio_retry);
        ESP_LOGI(TAG, "APRS API endpoints registered");

        // Register OTA update endpoints
        httpd_register_uri_handler(s_server, &uri_ota_page);
        httpd_register_uri_handler(s_server, &uri_api_ota_status);
        httpd_register_uri_handler(s_server, &uri_api_ota_upload);
        ESP_LOGI(TAG, "OTA update endpoints registered");
#endif

#if BOARD_MODEL == MODEL_ESP32S3_EPAPER_1IN54
        // Register tile server handler if SD card is available
        ret = tiles_register_http_handler(s_server);
        if (ret != ESP_OK) {
            ESP_LOGI(TAG, "Tile server not available (no SD card)");
        }

        // Register update mirror handlers if available
        ret = updates_register_http_handlers(s_server);
        if (ret != ESP_OK) {
            ESP_LOGI(TAG, "Update mirror not available (no SD card)");
        }

        // Register WebSocket handler
        ret = ws_server_register(s_server);
        if (ret != ESP_OK) {
            ESP_LOGW(TAG, "Failed to register WebSocket handler: %s", esp_err_to_name(ret));
        }
#endif

        ESP_LOGI(TAG, "Station API endpoints registered");
    }

    ESP_LOGI(TAG, "HTTP server started");
    return ESP_OK;
}

esp_err_t http_server_stop(void)
{
    if (s_server == NULL) {
        return ESP_OK;
    }

    esp_err_t ret = httpd_stop(s_server);
    s_server = NULL;
    s_config_callback = NULL;

    ESP_LOGI(TAG, "HTTP server stopped");
    return ret;
}

bool http_server_is_running(void)
{
    return s_server != NULL;
}

httpd_handle_t http_server_get_handle(void)
{
    return s_server;
}
