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
#include "chat_page.h"

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
#include "mesh_chat.h"
#ifdef CONFIG_GEOGRAM_MESH_ENABLED
#include "mesh_bsp.h"
#endif
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "radio_tx.h"
#endif

static const char *TAG = "http_server";

static httpd_handle_t s_server = NULL;
static wifi_config_callback_t s_config_callback = NULL;
static bool s_station_api_enabled = false;

#if BOARD_MODEL == MODEL_KV4P
// Max input length for the HTTP POST body (split into 67-char APRS parts)
#define APRS_INPUT_MAX_LEN  500
// APRS message text limit per frame (APRS101 spec: 67 chars)
#define APRS_PART_MAX_LEN   67
// Part prefix like "[1/8] " = 6 chars; payload = 67 - 6 = 61
#define APRS_PART_PREFIX_LEN 6
#define APRS_PART_PAYLOAD   (APRS_PART_MAX_LEN - APRS_PART_PREFIX_LEN)
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
    "<div class=\"nav\"><a href=\"/\">Chat</a> | <a href=\"/setup\">WiFi Setup</a> | <a href=\"/ota\">Firmware Update</a></div>"
    "<script>"
    "var lastId='',myCall='',polling=null,busy=false;"
    "function esc(s){var d=document.createElement('div');d.textContent=s;return d.innerHTML}"
    "function poll(){"
    "if(busy)return;busy=true;"
    "fetch('/api/aprs?since='+lastId).then(function(r){if(!r.ok)throw new Error(r.status);return r.json();}).then(function(d){"
    "if(d.messages&&d.messages.length){"
    "var el=document.getElementById('msgs');"
    "d.messages.forEach(function(m){"
    "var div=document.createElement('div');"
    "div.className='msg'+(m.outgoing?' tx':'');"
    "var t=m.timestamp||0;var dt=new Date(t*1000);var ts=('0'+dt.getHours()).slice(-2)+':'+('0'+dt.getMinutes()).slice(-2);"
    "div.innerHTML='<span class=\"ts\">'+esc(ts)+'</span> '+"
    "'<span class=\"from\">'+esc(m.from||'?')+'</span> &rarr; '+"
    "'<span class=\"to\">'+esc(m.to||'?')+'</span><br>'+"
    "'<span class=\"body\">'+esc(m.message||'')+'</span>';"
    "el.appendChild(div);"
    "});"
    "el.scrollTop=el.scrollHeight;"
    "lastId=d.latest_id||lastId;"
    "}"
    "return fetch('/api/aprs/status').then(function(r){if(!r.ok)throw new Error(r.status);return r.json();}).then(function(s){"
    "if(!myCall||myCall==='NOCALL'){myCall=s.callsign||'NOCALL';document.getElementById('info').textContent=myCall+' | '+(s.frequency||'?')+' MHz';}"
    "document.getElementById('status').innerHTML="
    "'<span>RX: '+(s.total_rx||0)+'</span><span>TX: '+(s.total_tx||0)+'</span>'+"
    "'<span>'+(s.enabled?'Radio ON':'Radio OFF')+'</span>'+"
    "'<span>'+(s.tx_supported?'TX OK':'RX only')+'</span>';"
    "});"
    "}).catch(function(){if(!myCall)document.getElementById('info').textContent='Status unavailable';}).then(function(){busy=false;});"
    "}"
    "function sendMsg(){"
    "var to=document.getElementById('to').value.trim().toUpperCase();"
    "var msg=document.getElementById('message').value.trim();"
    "if(!to||!msg)return false;"
    "if(msg.length>67)msg=msg.substring(0,67);"
    "if(!myCall||myCall==='NOCALL'){alert('Waiting for radio status');return false;}"
    "var btn=document.getElementById('btn');"
    "btn.disabled=true;btn.textContent='TX...';"
    "clearInterval(polling);busy=true;"
    "fetch('/api/aprs',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},"
    "body:'from='+encodeURIComponent(myCall)+'&to='+encodeURIComponent(to)+'&message='+encodeURIComponent(msg)"
    "}).then(function(r){return r.json();}).then(function(d){"
    "if(d.ok){document.getElementById('message').value='';}"
    "else{alert('Send failed: '+(d.error||'unknown'));}"
    "}).catch(function(e){alert('Error: '+e);}).then(function(){"
    "btn.disabled=false;btn.textContent='SEND';"
    "busy=false;poll();polling=setInterval(poll,2000);"
    "});"
    "return false;"
    "}"
    "poll();polling=setInterval(poll,2000);"
    "</script></body></html>";

static const char *CHAT_PAGE_HTML =
    "<!DOCTYPE html>"
    "<html><head>"
    "<meta charset=\"utf-8\">"
    "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
    "<title>Geogram Chat</title>"
    "<style>"
    "*{box-sizing:border-box;margin:0;padding:0}"
    "body{font-family:monospace;background:#1a1a2e;color:#e0e0e0;padding:0;max-width:600px;margin:0 auto;height:100vh;display:flex;flex-direction:column}"
    "header{padding:8px 12px;display:flex;justify-content:space-between;align-items:center}"
    "header h1{color:#00d4ff;font-size:1.2em}"
    ".ham{background:none;border:none;color:#00d4ff;font-size:1.4em;cursor:pointer;padding:4px 8px}"
    ".menu{display:none;background:#16213e;border:1px solid #333;border-radius:6px;position:absolute;right:12px;top:40px;z-index:9;padding:8px 0}"
    ".menu.show{display:block}"
    ".menu a,.menu button{display:block;width:100%;text-align:left;padding:8px 16px;color:#e0e0e0;text-decoration:none;background:none;border:none;font-family:monospace;font-size:.9em;cursor:pointer}"
    ".menu a:hover,.menu button:hover{background:#1a3a5e}"
    "#msgs{flex:1;overflow-y:auto;padding:8px 12px;font-size:.85em}"
    ".msg{padding:6px 10px;margin-bottom:6px;border-radius:8px;max-width:85%;clear:both}"
    ".msg.remote{background:#1E2D3D;float:left;border-bottom-left-radius:2px}"
    ".msg.local{background:#2B5278;float:right;border-bottom-right-radius:2px;text-align:right}"
    ".msg .from{font-weight:bold;font-size:.8em}"
    ".msg .ts{color:#888;font-size:.7em}"
    ".msg .text{word-break:break-word;margin-top:2px}"
    ".clr{clear:both}"
    "@media(orientation:landscape){.msg{float:none!important;max-width:100%;text-align:left!important;border-radius:8px!important}}"
    ".send{padding:8px 12px;display:flex;gap:6px;background:#16213e;border-top:1px solid #333}"
    ".send input{background:#0f0f23;border:1px solid #444;color:#fff;padding:8px;border-radius:4px;font-family:monospace}"
    ".send #call{width:80px}"
    ".send #text{flex:1;min-width:80px}"
    ".send button{background:#00d4ff;color:#000;border:none;padding:8px 14px;border-radius:4px;cursor:pointer;font-weight:bold;font-family:monospace}"
    ".send button:disabled{background:#555;color:#888}"
    "footer{padding:6px 12px;text-align:center;color:#666;font-size:.75em}"
    "</style></head><body>"
    "<header><h1>Geogram</h1><button class=\"ham\" onclick=\"toggleMenu()\">&#9776;</button></header>"
    "<div class=\"menu\" id=\"menu\">"
    "<a href=\"/aprs\">APRS</a>"
    "<a href=\"/setup\">WiFi Setup</a>"
    "<a href=\"/ota\">Firmware Update</a>"
    "<button onclick=\"resetLocal()\">Reset local data</button>"
    "</div>"
    "<div id=\"msgs\"></div>"
    "<form class=\"send\" onsubmit=\"return sendMsg()\">"
    "<input type=\"text\" id=\"call\" placeholder=\"Call\" maxlength=\"15\">"
    "<input type=\"text\" id=\"text\" placeholder=\"Message\" maxlength=\"200\" required>"
    "<button type=\"submit\" id=\"btn\">Send</button>"
    "</form>"
    "<footer id=\"foot\">Connecting...</footer>"
    "<script>"
    "var lastId=0,P=null,busy=false,skip=0;"
    "function esc(s){var d=document.createElement('div');d.textContent=s;return d.innerHTML}"
    "function toggleMenu(){document.getElementById('menu').classList.toggle('show')}"
    "document.addEventListener('click',function(e){if(!e.target.closest('.ham')&&!e.target.closest('.menu'))document.getElementById('menu').classList.remove('show')});"
    "function resetLocal(){localStorage.removeItem('geo_callsign');document.getElementById('call').value='';"
    "document.getElementById('msgs').innerHTML='';skip=lastId;document.getElementById('menu').classList.remove('show')}"
    "function init(){var c=localStorage.getItem('geo_callsign');if(c)document.getElementById('call').value=c}"
    "function fmtTs(t){var d=new Date(t*1000);var Y=d.getFullYear(),M=('0'+(d.getMonth()+1)).slice(-2),D=('0'+d.getDate()).slice(-2);"
    "var h=('0'+d.getHours()).slice(-2),m=('0'+d.getMinutes()).slice(-2);return Y+'-'+M+'-'+D+' '+h+':'+m}"
    "function poll(){"
    "if(busy)return;busy=true;"
    "var sid=skip||lastId;"
    "fetch('/api/chat/messages?since='+sid).then(function(r){return r.json()}).then(function(d){"
    "if(d.messages&&d.messages.length){"
    "var el=document.getElementById('msgs');"
    "d.messages.forEach(function(m){"
    "var div=document.createElement('div');"
    "div.className='msg '+(m.local?'local':'remote');"
    "div.innerHTML='<span class=\"from\">'+esc(m.from||'?')+'</span> <span class=\"ts\">'+fmtTs(m.ts)+'</span>'+"
    "'<div class=\"text\">'+esc(m.text||'')+'</div>';"
    "el.appendChild(div);"
    "var br=document.createElement('div');br.className='clr';el.appendChild(br);"
    "});"
    "el.scrollTop=el.scrollHeight;"
    "}"
    "if(d.latest_id)lastId=d.latest_id;"
    "skip=0;"
    "if(d.my_callsign)document.getElementById('foot').textContent='Connected to station '+d.my_callsign;"
    "}).catch(function(){}).then(function(){busy=false})"
    "}"
    "function sendMsg(){"
    "var call=document.getElementById('call').value.trim();"
    "var text=document.getElementById('text').value.trim();"
    "if(!text)return false;"
    "if(call)localStorage.setItem('geo_callsign',call);"
    "var btn=document.getElementById('btn');"
    "btn.disabled=true;"
    "var body='text='+encodeURIComponent(text);"
    "if(call)body+='&callsign='+encodeURIComponent(call);"
    "body+='&client_ts='+Math.floor(Date.now()/1000);"
    "fetch('/api/chat/send',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:body"
    "}).then(function(r){return r.json()}).then(function(d){"
    "if(d.ok)document.getElementById('text').value='';"
    "}).catch(function(){}).then(function(){btn.disabled=false;poll()})"
    ";return false}"
    "init();poll();P=setInterval(poll,2000);"
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
    "<div class=\"back\"><a href=\"/\">Chat</a> | <a href=\"/aprs\">APRS</a> | <a href=\"/ota\">Firmware Update</a></div>"
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
    httpd_resp_set_hdr(req, "Connection", "close");
    httpd_resp_set_hdr(req, "Cache-Control", "no-cache, no-store, must-revalidate");
    httpd_resp_set_hdr(req, "Pragma", "no-cache");
    httpd_resp_set_hdr(req, "Expires", "0");
}

// CAPTIVE_LANDING_HTML removed — captive portal now serves the full chat page
// via chat_page_serve(). StorageProvider + SessionProvider in chat JS handle
// the sandboxed WebView environment (no localStorage/crypto).

/**
 * @brief Captive portal probe handler — serves the full chat page
 *
 * Android/iOS probe specific URLs to detect captive portals. Returning HTML
 * (not 204, not "Success") triggers the captive portal popup. The chat page
 * works directly inside the popup thanks to StorageProvider (cookie fallback
 * when localStorage is blocked) and SessionProvider (server-generated identity
 * when crypto.getRandomValues() is unavailable).
 */
static esp_err_t captive_portal_handler(httpd_req_t *req)
{
    httpd_resp_set_hdr(req, "Connection", "close");
    return chat_page_serve(req);
}

/**
 * @brief CORS preflight handler for cross-origin requests
 *
 * When the captive portal WebView is on connectivitycheck.gstatic.com and
 * fetch() URLs are rewritten to http://192.168.4.1/api/..., the browser
 * sends an OPTIONS preflight. Allow all origins/methods/headers.
 */
static esp_err_t cors_preflight_handler(httpd_req_t *req)
{
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Methods", "GET, POST, OPTIONS");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Headers", "Content-Type");
    httpd_resp_set_hdr(req, "Access-Control-Max-Age", "86400");
    httpd_resp_set_hdr(req, "Connection", "close");
    httpd_resp_set_status(req, "204 No Content");
    httpd_resp_send(req, NULL, 0);
    return ESP_OK;
}

/**
 * @brief Custom 404 handler - redirect unknown URIs to main page for captive portal
 *
 * Background apps (Facebook, WhatsApp, etc.) hit the ESP32 because captive
 * portal DNS resolves all domains to 192.168.4.1. Close connections immediately
 * to avoid exhausting the limited socket pool.
 */
static esp_err_t http_404_redirect_handler(httpd_req_t *req, httpd_err_code_t err)
{
    set_captive_redirect_headers(req);
    httpd_resp_set_hdr(req, "Connection", "close");
    httpd_resp_send(req, NULL, 0);
    return ESP_FAIL;  // Close socket after redirect
}

// ============================================================================
// Page handlers
// ============================================================================

/**
 * @brief Handler for root page - serves Chat page on KV4P, landing page on others
 */
static esp_err_t root_get_handler(httpd_req_t *req)
{
#if BOARD_MODEL == MODEL_KV4P || BOARD_MODEL == MODEL_TDONGLE_S3
    return chat_page_serve(req);
#else
    ESP_LOGI(TAG, "HTTP GET / (setup redirect)");
    httpd_resp_set_type(req, "text/html");
    httpd_resp_send(req, WIFI_SETUP_PAGE_HTML, strlen(WIFI_SETUP_PAGE_HTML));
    return ESP_OK;
#endif
}

#if BOARD_MODEL == MODEL_KV4P
/**
 * @brief Handler for /aprs page
 */
static esp_err_t aprs_page_get_handler(httpd_req_t *req)
{
    ESP_LOGI(TAG, "HTTP GET /aprs");
    httpd_resp_set_type(req, "text/html");
    httpd_resp_send(req, APRS_PAGE_HTML, strlen(APRS_PAGE_HTML));
    return ESP_OK;
}
#endif

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
#if BOARD_MODEL == MODEL_KV4P
        // No callback — attempt STA connection directly
        ESP_LOGI(TAG, "Connecting to WiFi: %s", ssid);
        esp_err_t conn_err = geogram_wifi_connect_sta(ssid, password);
        httpd_resp_set_type(req, "application/json");
        if (conn_err != ESP_OK) {
            httpd_resp_send(req, "{\"ok\":false,\"error\":\"connect failed\"}", -1);
        } else {
            httpd_resp_send(req, "{\"ok\":true}", -1);
        }
#else
        httpd_resp_set_type(req, "application/json");
        httpd_resp_send(req, "{\"ok\":false,\"error\":\"no config callback\"}", -1);
#endif
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
            char epoch;
            aprs_store_parse_id(param, &epoch, &since_id);
            // If client sends an epoch that doesn't match, reset to 0 (return all)
            if (epoch != '\0' && epoch != aprs_store_get_epoch()) {
                since_id = 0;
            }
        }
    }

    const size_t buffer_size = 2048;
    char *buffer = malloc(buffer_size);
    if (!buffer) {
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "Out of memory");
        return ESP_FAIL;
    }

    size_t len = aprs_store_build_json(buffer, buffer_size, since_id);

    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    httpd_resp_set_hdr(req, "Connection", "close");
    httpd_resp_send(req, buffer, len);

    free(buffer);
    return ESP_OK;
}

/**
 * @brief Handler for POST /api/aprs — send an APRS message
 */
static esp_err_t api_aprs_post_handler(httpd_req_t *req)
{
    char *content = malloc(1024);
    if (!content) {
        httpd_resp_set_type(req, "application/json");
        httpd_resp_set_hdr(req, "Connection", "close");
        httpd_resp_send(req, "{\"ok\":false,\"error\":\"Out of memory\"}", -1);
        return ESP_OK;
    }

    int total_len = req->content_len;
    if (total_len >= 1024) {
        free(content);
        httpd_resp_set_type(req, "application/json");
        httpd_resp_set_hdr(req, "Connection", "close");
        httpd_resp_send(req, "{\"ok\":false,\"error\":\"Content too long\"}", -1);
        return ESP_OK;
    }

    int ret = httpd_req_recv(req, content, total_len);
    if (ret <= 0) {
        free(content);
        httpd_resp_set_type(req, "application/json");
        httpd_resp_set_hdr(req, "Connection", "close");
        httpd_resp_send(req, "{\"ok\":false,\"error\":\"Failed to receive data\"}", -1);
        return ESP_OK;
    }
    content[total_len] = '\0';

    char from[APRS_MAX_CALLSIGN_LEN] = {0};
    char to[APRS_MAX_CALLSIGN_LEN] = {0};
    char message[APRS_INPUT_MAX_LEN + 1] = {0};

    if (!extract_form_value(content, "from", from, sizeof(from)) || from[0] == '\0') {
        free(content);
        httpd_resp_set_type(req, "application/json");
        httpd_resp_set_hdr(req, "Connection", "close");
        httpd_resp_send(req, "{\"ok\":false,\"error\":\"Missing 'from'\"}", -1);
        return ESP_OK;
    }
    if (!extract_form_value(content, "to", to, sizeof(to)) || to[0] == '\0') {
        free(content);
        httpd_resp_set_type(req, "application/json");
        httpd_resp_set_hdr(req, "Connection", "close");
        httpd_resp_send(req, "{\"ok\":false,\"error\":\"Missing 'to'\"}", -1);
        return ESP_OK;
    }
    if (!extract_form_value(content, "message", message, sizeof(message))) {
        free(content);
        httpd_resp_set_type(req, "application/json");
        httpd_resp_set_hdr(req, "Connection", "close");
        httpd_resp_send(req, "{\"ok\":false,\"error\":\"Missing 'message'\"}", -1);
        return ESP_OK;
    }

    free(content);

    size_t msg_len = strlen(message);

    // Split long messages into 67-char APRS parts with [1/N] prefix.
    // Single-part messages have no prefix. Multi-part get "[1/N] " prefix.
    int total_parts = 1;
    if (msg_len > APRS_PART_MAX_LEN) {
        total_parts = (int)((msg_len + APRS_PART_PAYLOAD - 1) / APRS_PART_PAYLOAD);
    }

    sa818_radio_handle_t radio = model_get_sa818_radio();
    int queued = 0;

    for (int part = 0; part < total_parts; part++) {
        char part_msg[APRS_MAX_MESSAGE_LEN];

        if (total_parts == 1) {
            // Single part — no prefix, use full 67 chars
            strncpy(part_msg, message, APRS_PART_MAX_LEN);
            part_msg[APRS_PART_MAX_LEN] = '\0';
        } else {
            // Multi-part — "[1/N] " prefix + payload
            size_t offset = (size_t)part * APRS_PART_PAYLOAD;
            size_t remaining = msg_len - offset;
            if (remaining > APRS_PART_PAYLOAD) remaining = APRS_PART_PAYLOAD;

            int prefix_len = snprintf(part_msg, sizeof(part_msg), "[%d/%d] ",
                                      part + 1, total_parts);
            memcpy(part_msg + prefix_len, message + offset, remaining);
            part_msg[prefix_len + remaining] = '\0';
        }

        // Store each part in APRS history
        aprs_store_add_tx(from, to, part_msg);

        // Queue TX for background task
        if (radio) {
            radio_tx_item_t item;
            strncpy(item.from, from, sizeof(item.from) - 1);
            item.from[sizeof(item.from) - 1] = '\0';
            strncpy(item.to, to, sizeof(item.to) - 1);
            item.to[sizeof(item.to) - 1] = '\0';
            strncpy(item.message, part_msg, sizeof(item.message) - 1);
            item.message[sizeof(item.message) - 1] = '\0';

            if (!radio_tx_queue_send(&item)) {
                ESP_LOGW(TAG, "APRS TX queue full at part %d/%d", part + 1, total_parts);
                break;
            }
            queued++;
        }
    }

    char resp[96];
    int resp_len = snprintf(resp, sizeof(resp),
        "{\"ok\":true,\"parts\":%d,\"queued\":%d}", total_parts, queued);

    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    httpd_resp_set_hdr(req, "Connection", "close");
    httpd_resp_send(req, resp, resp_len);
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
    httpd_resp_set_hdr(req, "Connection", "close");
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
    "<div class=\"nav\"><a href=\"/\">Chat</a> | <a href=\"/aprs\">APRS</a> | <a href=\"/setup\">WiFi Setup</a></div>"
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

// ============================================================================
// Self-documenting API index
// ============================================================================

static esp_err_t api_index_get_handler(httpd_req_t *req)
{
    static const char body[] =
        "{"
        "\"name\":\"Geogram KV4P API\","
        "\"endpoints\":{"

            "\"GET /api/\":{\"description\":\"This endpoint. Lists all available API endpoints and their parameters.\"},"

            "\"GET /api/status\":{\"description\":\"Device status: callsign, uptime, WiFi, sensors, heap.\"},"

            "\"GET /api/wifi/scan\":{\"description\":\"Scan for nearby WiFi networks. Returns array of SSIDs with RSSI.\"},"

            "\"GET /api/wifi/status\":{\"description\":\"Current WiFi connection state, SSID, IP address.\"},"

            "\"GET /api/aprs?since=<id>\":{\"description\":\"List APRS messages. IDs are epoch-prefixed strings (e.g. K1). Omit since to get all. If epoch letter changes after reboot, server returns all messages.\","
                "\"params\":{\"since\":\"optional, epoch-prefixed ID (e.g. K42)\"}},"

            "\"POST /api/aprs\":{\"description\":\"Send an APRS message via SA818 radio. Messages longer than 67 chars are split into parts with [1/N] prefix (max 500 chars, up to 9 parts).\","
                "\"content_type\":\"application/x-www-form-urlencoded\","
                "\"params\":{\"from\":\"sender callsign (required, max 16)\",\"to\":\"destination callsign (required, max 16)\",\"message\":\"message text (required, max 500 chars)\"}},"

            "\"GET /api/aprs/status\":{\"description\":\"APRS radio status: enabled, frequency, tx_supported, total_rx, total_tx, callsign.\"},"

            "\"GET /api/aprs/rx_stats\":{\"description\":\"Low-level RX demodulator stats: nrzi_bits, flags, frames, crc_ok, crc_fail, fifo_overflow.\"},"

            "\"GET /api/aprs/audio\":{\"description\":\"Raw audio capture (500 int16 LE samples, ~50ms at 10kHz). Returns application/octet-stream.\"},"

            "\"POST /api/aprs/test_tone\":{\"description\":\"Transmit a test tone via the SA818 radio. No parameters.\"},"

            "\"GET /api/radio/diag\":{\"description\":\"Radio diagnostic info: handle status, init error, powered state, frequency.\"},"

            "\"POST /api/radio/retry\":{\"description\":\"Retry radio initialization if it failed at boot. No parameters.\"},"

            "\"GET /api/ota/status\":{\"description\":\"Current firmware version, active partition, OTA readiness.\"},"

            "\"POST /api/ota\":{\"description\":\"Upload firmware binary for OTA update.\","
                "\"content_type\":\"application/octet-stream\","
                "\"body\":\"raw .bin file (max ~1.9MB)\"},"

            "\"GET /api/chat/messages?since=<id>\":{\"description\":\"List chat messages. Omit since to get all.\","
                "\"params\":{\"since\":\"optional, numeric message ID\"}},"

            "\"POST /api/chat/send\":{\"description\":\"Send a chat message. Broadcasts via mesh if connected, otherwise local only.\","
                "\"content_type\":\"application/x-www-form-urlencoded\","
                "\"params\":{\"text\":\"message text (required, max 200)\",\"callsign\":\"sender callsign (optional)\",\"client_ts\":\"unix timestamp (optional)\"}},"

            "\"POST /api/chat/send-file\":{\"description\":\"Send file metadata message (no binary stored).\","
                "\"content_type\":\"application/x-www-form-urlencoded\","
                "\"params\":{\"sha1\":\"hex SHA1 hash\",\"size\":\"file size bytes\",\"filename\":\"optional\",\"mime\":\"MIME type\",\"callsign\":\"optional\",\"text\":\"caption\"}},"

            "\"POST /api/chat/client\":{\"description\":\"Log client key/status info.\"}"
        "}"
        "}";

    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    httpd_resp_set_hdr(req, "Connection", "close");
    httpd_resp_send(req, body, sizeof(body) - 1);
    return ESP_OK;
}

static const httpd_uri_t uri_api_index = {
    .uri = "/api/",
    .method = HTTP_GET,
    .handler = api_index_get_handler,
    .user_ctx = NULL
};

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

static esp_err_t api_aprs_rx_stats_handler(httpd_req_t *req)
{
    char buf[256];
    sa818_radio_handle_t radio = model_get_sa818_radio();
    sa818_aprs_rx_stats_t stats = {0};
    if (radio) {
        sa818_radio_get_aprs_rx_stats(radio, &stats);
    }
    int len = snprintf(buf, sizeof(buf),
        "{\"nrzi_bits\":%lu,\"flags\":%lu,\"frames\":%lu,"
        "\"crc_ok\":%lu,\"crc_fail\":%lu,\"fifo_overflow\":%lu}",
        (unsigned long)stats.nrzi_bits, (unsigned long)stats.flag_seen,
        (unsigned long)stats.frame_candidates,
        (unsigned long)stats.crc_ok, (unsigned long)stats.crc_fail,
        (unsigned long)stats.fifo_overflow);
    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    httpd_resp_set_hdr(req, "Connection", "close");
    httpd_resp_send(req, buf, len);
    return ESP_OK;
}

static const httpd_uri_t uri_api_aprs_rx_stats = {
    .uri = "/api/aprs/rx_stats",
    .method = HTTP_GET,
    .handler = api_aprs_rx_stats_handler,
    .user_ctx = NULL
};

static esp_err_t api_aprs_audio_handler(httpd_req_t *req)
{
    /* Return last 500 centered ADC samples as comma-separated int16 values.
       500 samples at ~10kHz = 50ms of audio — enough for several AFSK cycles. */
    static int16_t samples[500];
    size_t n = 0;
    sa818_radio_get_audio_capture(samples, &n);
    /* Return as raw binary int16 LE. */
    httpd_resp_set_type(req, "application/octet-stream");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    httpd_resp_set_hdr(req, "Connection", "close");
    httpd_resp_send(req, (const char *)samples, n * sizeof(int16_t));
    return ESP_OK;
}

static const httpd_uri_t uri_api_aprs_audio = {
    .uri = "/api/aprs/audio",
    .method = HTTP_GET,
    .handler = api_aprs_audio_handler,
    .user_ctx = NULL
};

static esp_err_t api_aprs_test_tone_handler(httpd_req_t *req)
{
#if CONFIG_IDF_TARGET_ESP32
    sa818_radio_handle_t radio = model_get_sa818_radio();
    if (!radio) {
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "no radio");
        return ESP_FAIL;
    }
    esp_err_t err = sa818_radio_test_tone(radio);
    if (err != ESP_OK) {
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, esp_err_to_name(err));
        return ESP_FAIL;
    }
    httpd_resp_set_type(req, "application/json");
    httpd_resp_sendstr(req, "{\"ok\":true}");
    return ESP_OK;
#else
    httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "not supported");
    return ESP_FAIL;
#endif
}

static const httpd_uri_t uri_api_aprs_test_tone = {
    .uri = "/api/aprs/test_tone",
    .method = HTTP_POST,
    .handler = api_aprs_test_tone_handler,
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

static const httpd_uri_t uri_aprs_page = {
    .uri = "/aprs",
    .method = HTTP_GET,
    .handler = aprs_page_get_handler,
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

// CORS preflight for cross-origin captive portal requests
static const httpd_uri_t uri_cors_api = {
    .uri = "/api/*",
    .method = HTTP_OPTIONS,
    .handler = cors_preflight_handler,
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
    config.stack_size = 8192;
    config.max_uri_handlers = 30;
    config.max_open_sockets = 7;
    config.recv_wait_timeout = 2;
    config.send_wait_timeout = 2;

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

    // CORS preflight for cross-origin captive portal requests
    httpd_register_uri_handler(s_server, &uri_cors_api);

    // Register Station API handlers if enabled
    if (enable_station_api) {
        httpd_register_uri_handler(s_server, &uri_api_status);

#if BOARD_MODEL == MODEL_KV4P
        httpd_register_uri_handler(s_server, &uri_api_index);
        // Register APRS API endpoints and start TX task
        radio_tx_set_backend((radio_tx_getter_t)model_get_sa818_radio,
                             (radio_tx_send_fn_t)sa818_radio_send_aprs_message);
        radio_tx_queue_init();
        httpd_register_uri_handler(s_server, &uri_api_aprs);
        httpd_register_uri_handler(s_server, &uri_api_aprs_send);
        httpd_register_uri_handler(s_server, &uri_api_aprs_status);
        httpd_register_uri_handler(s_server, &uri_api_aprs_rx_stats);
        httpd_register_uri_handler(s_server, &uri_api_aprs_audio);
        httpd_register_uri_handler(s_server, &uri_api_aprs_test_tone);
        httpd_register_uri_handler(s_server, &uri_api_radio_diag);
        httpd_register_uri_handler(s_server, &uri_api_radio_retry);
        ESP_LOGI(TAG, "APRS API endpoints registered");

        httpd_register_uri_handler(s_server, &uri_aprs_page);

        // Register OTA update endpoints
        httpd_register_uri_handler(s_server, &uri_ota_page);
        httpd_register_uri_handler(s_server, &uri_api_ota_status);
        httpd_register_uri_handler(s_server, &uri_api_ota_upload);
        ESP_LOGI(TAG, "OTA update endpoints registered");
#endif

#if BOARD_MODEL == MODEL_KV4P || BOARD_MODEL == MODEL_TDONGLE_S3
        // Register Chat API endpoints and initialize chat system
        chat_page_register_handlers(s_server);
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
