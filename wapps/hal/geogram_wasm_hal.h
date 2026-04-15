/*
 * Geogram WASM HAL — Hardware Abstraction Layer
 *
 * Modules #include this header and call hal_* functions normally.
 * Each host platform (ESP32/Wasm3, Flutter/Wasmer, CLI/Wasmtime) provides
 * its own implementation of these imports.
 *
 * Buffer exchanges use (ptr, len) pairs into WASM linear memory.
 * Functions that need hardware return sentinel values when the capability
 * is absent — modules should check *_available_hw() before using.
 *
 * Copyright (c) geogram — Apache-2.0
 */

#ifndef GEOGRAM_WASM_HAL_H
#define GEOGRAM_WASM_HAL_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ── System ─────────────────────────────────────────────────────────── */

/* Monotonic milliseconds since host start */
__attribute__((import_module("hal"), import_name("time_ms")))
uint64_t hal_time_ms(void);

/* Unix epoch seconds (0 if no RTC) */
__attribute__((import_module("hal"), import_name("time_epoch")))
uint64_t hal_time_epoch(void);

/* Log a message. level: 0=debug, 1=info, 2=warn, 3=error */
__attribute__((import_module("hal"), import_name("log")))
void hal_log(int32_t level, const char *msg, uint32_t msg_len);

/* Yield to host scheduler (cooperative multitasking on ESP32) */
__attribute__((import_module("hal"), import_name("yield")))
void hal_yield(void);

/* Platform identifier written into buf. Returns bytes written. */
/* Platforms: "esp32", "android", "linux-desktop", "linux-cli" */
__attribute__((import_module("hal"), import_name("platform")))
uint32_t hal_platform(char *buf, uint32_t buf_len);

/* Free heap bytes available to this module */
__attribute__((import_module("hal"), import_name("heap_free")))
uint32_t hal_heap_free(void);

/* ── Storage (key-value, scoped per module ID) ──────────────────────── */

/* Get value for key. Returns bytes written to val_buf, 0 if not found. */
__attribute__((import_module("hal"), import_name("kv_get")))
uint32_t hal_kv_get(const char *key, uint32_t key_len,
                    char *val_buf, uint32_t val_buf_len);

/* Set key=value. Returns 0 on success, -1 on error. */
__attribute__((import_module("hal"), import_name("kv_set")))
int32_t hal_kv_set(const char *key, uint32_t key_len,
                   const char *val, uint32_t val_len);

/* Delete key. Returns 0 on success, -1 if not found. */
__attribute__((import_module("hal"), import_name("kv_delete")))
int32_t hal_kv_delete(const char *key, uint32_t key_len);

/* List keys matching prefix. Writes null-separated key names into buf.
 * Returns number of keys found (0 if none). */
__attribute__((import_module("hal"), import_name("kv_list")))
uint32_t hal_kv_list(const char *prefix, uint32_t prefix_len,
                     char *buf, uint32_t buf_len);

/* Check if key exists. Returns 1 if exists, 0 if not. */
__attribute__((import_module("hal"), import_name("kv_exists")))
int32_t hal_kv_exists(const char *key, uint32_t key_len);

/* Get size of value for key. Returns size in bytes, 0 if not found. */
__attribute__((import_module("hal"), import_name("kv_size")))
uint32_t hal_kv_size(const char *key, uint32_t key_len);

/* ── Internationalisation ───────────────────────────────────────────── */

/* Look up a translation key against the wapp's lang/<locale>.json
 * (merged with the English fallback). Writes up to out_cap bytes of
 * the localised string into out (NOT null-terminated). Returns the
 * number of bytes written. When the key is missing from both the
 * primary and fallback maps, returns 0 and out is untouched — the
 * caller should fall back to its hard-coded literal. */
__attribute__((import_module("hal"), import_name("i18n_get")))
uint32_t hal_i18n_get(const char *key, uint32_t key_len,
                      char *out, uint32_t out_cap);

/* ── Storage (file, scoped per module ID) ───────────────────────────── */

/* Open file. mode: 0=read, 1=write, 2=append. Returns handle or -1. */
__attribute__((import_module("hal"), import_name("file_open")))
int32_t hal_file_open(const char *path, uint32_t path_len, int32_t mode);

/* Read up to buf_len bytes. Returns bytes read, 0 on EOF, -1 on error. */
__attribute__((import_module("hal"), import_name("file_read")))
int32_t hal_file_read(int32_t handle, char *buf, uint32_t buf_len);

/* Write buf_len bytes. Returns bytes written or -1 on error. */
__attribute__((import_module("hal"), import_name("file_write")))
int32_t hal_file_write(int32_t handle, const char *buf, uint32_t buf_len);

/* Close file handle. */
__attribute__((import_module("hal"), import_name("file_close")))
void hal_file_close(int32_t handle);

/* ── Network (async polling) ────────────────────────────────────────── */

/* Start HTTP request. Returns request_id or -1 on error. */
/* method: 0=GET, 1=POST, 2=PUT, 3=DELETE */
__attribute__((import_module("hal"), import_name("http_request")))
int32_t hal_http_request(int32_t method,
                         const char *url, uint32_t url_len,
                         const char *body, uint32_t body_len);

/* Poll request status. Returns: 0=pending, 1=complete, -1=error */
__attribute__((import_module("hal"), import_name("http_poll")))
int32_t hal_http_poll(int32_t request_id);

/* Read response body. Returns bytes written to buf. */
__attribute__((import_module("hal"), import_name("http_read_response")))
int32_t hal_http_read_response(int32_t request_id, char *buf, uint32_t buf_len);

/* HTTP status code for completed request, or -1 if still pending. */
__attribute__((import_module("hal"), import_name("http_status")))
int32_t hal_http_status(int32_t request_id);

/* Free request resources. */
__attribute__((import_module("hal"), import_name("http_free")))
void hal_http_free(int32_t request_id);

/* ── LoRa ───────────────────────────────────────────────────────────── */

/* Returns 1 if LoRa hardware is present, 0 otherwise. */
__attribute__((import_module("hal"), import_name("lora_available_hw")))
int32_t hal_lora_available_hw(void);

/* Send packet. Returns 0 on success, -1 on error. */
__attribute__((import_module("hal"), import_name("lora_send")))
int32_t hal_lora_send(const char *data, uint32_t data_len);

/* Returns number of bytes available to read, 0 if none. */
__attribute__((import_module("hal"), import_name("lora_available")))
uint32_t hal_lora_available(void);

/* Read received packet into buf. Returns bytes read. */
__attribute__((import_module("hal"), import_name("lora_recv")))
uint32_t hal_lora_recv(char *buf, uint32_t buf_len);

/* ── BLE ────────────────────────────────────────────────────────────── */

/* Start BLE scan. Returns 0 on success. */
__attribute__((import_module("hal"), import_name("ble_scan_start")))
int32_t hal_ble_scan_start(void);

/* Stop BLE scan. */
__attribute__((import_module("hal"), import_name("ble_scan_stop")))
void hal_ble_scan_stop(void);

/* Read next scan result as JSON into buf. Returns bytes, 0 if none. */
__attribute__((import_module("hal"), import_name("ble_scan_read")))
uint32_t hal_ble_scan_read(char *buf, uint32_t buf_len);

/* Start BLE advertising with given payload. Returns 0 on success. */
__attribute__((import_module("hal"), import_name("ble_advertise")))
int32_t hal_ble_advertise(const char *data, uint32_t data_len);

/* Stop BLE advertising. */
__attribute__((import_module("hal"), import_name("ble_advertise_stop")))
void hal_ble_advertise_stop(void);

/* ── Sensors ────────────────────────────────────────────────────────── */

/* Temperature in centidegrees C (2500 = 25.00°C). INT32_MIN if N/A. */
__attribute__((import_module("hal"), import_name("sensor_temperature")))
int32_t hal_sensor_temperature(void);

/* Relative humidity in centipercent (6500 = 65.00%). INT32_MIN if N/A. */
__attribute__((import_module("hal"), import_name("sensor_humidity")))
int32_t hal_sensor_humidity(void);

/* Battery millivolts (3700 = 3.7V). INT32_MIN if N/A. */
__attribute__((import_module("hal"), import_name("sensor_battery")))
int32_t hal_sensor_battery(void);

/* GPS latitude * 1e7 (e.g. 377749000 = 37.7749°N). INT32_MIN if N/A. */
__attribute__((import_module("hal"), import_name("sensor_gps_lat")))
int32_t hal_sensor_gps_lat(void);

/* GPS longitude * 1e7. INT32_MIN if N/A. */
__attribute__((import_module("hal"), import_name("sensor_gps_lon")))
int32_t hal_sensor_gps_lon(void);

/* ── Display ────────────────────────────────────────────────────────── */

/* Display width in pixels. 0 if no display. */
__attribute__((import_module("hal"), import_name("display_width")))
uint32_t hal_display_width(void);

/* Display height in pixels. 0 if no display. */
__attribute__((import_module("hal"), import_name("display_height")))
uint32_t hal_display_height(void);

/* Clear display buffer. */
__attribute__((import_module("hal"), import_name("display_clear")))
void hal_display_clear(void);

/* Draw text at (x,y). color: 0=black, 1=white. */
__attribute__((import_module("hal"), import_name("display_text")))
void hal_display_text(int32_t x, int32_t y, int32_t color,
                      const char *text, uint32_t text_len);

/* Set single pixel. */
__attribute__((import_module("hal"), import_name("display_pixel")))
void hal_display_pixel(int32_t x, int32_t y, int32_t color);

/* Draw filled rectangle. */
__attribute__((import_module("hal"), import_name("display_rect")))
void hal_display_rect(int32_t x, int32_t y, int32_t w, int32_t h, int32_t color);

/* Flush buffer to physical display. */
__attribute__((import_module("hal"), import_name("display_flush")))
void hal_display_flush(void);

/* ── GPIO (ESP32 only, no-op elsewhere) ─────────────────────────────── */

/* Set pin mode. mode: 0=input, 1=output, 2=input_pullup. */
__attribute__((import_module("hal"), import_name("gpio_mode")))
void hal_gpio_mode(int32_t pin, int32_t mode);

/* Read digital pin value (0 or 1). */
__attribute__((import_module("hal"), import_name("gpio_read")))
int32_t hal_gpio_read(int32_t pin);

/* Write digital pin value (0 or 1). */
__attribute__((import_module("hal"), import_name("gpio_write")))
void hal_gpio_write(int32_t pin, int32_t value);

/* ── Messages (host <-> module JSON) ────────────────────────────────── */

/* Send JSON message to host. */
__attribute__((import_module("hal"), import_name("msg_send")))
void hal_msg_send(const char *json, uint32_t json_len);

/* Returns number of bytes in next pending message, 0 if none. */
__attribute__((import_module("hal"), import_name("msg_available")))
uint32_t hal_msg_available(void);

/* Read next pending message into buf. Returns bytes read. */
__attribute__((import_module("hal"), import_name("msg_recv")))
uint32_t hal_msg_recv(char *buf, uint32_t buf_len);

/* ── Library calls (cross-module RPC) ───────────────────────────────── */

/* Call a function in a loaded library module.
 * Returns bytes written to result on success, or negative error code:
 *   -1 = library not found, -2 = function not found,
 *   -3 = buffer too small, -4 = internal error. */
__attribute__((import_module("hal"), import_name("lib_call")))
int32_t hal_lib_call(const char *lib_id, uint32_t lib_id_len,
                     const char *fn_name, uint32_t fn_name_len,
                     const char *args, uint32_t args_len,
                     char *result, uint32_t result_len);

/* ── Events (topic-based pub/sub between modules) ───────────────────── */

/* Subscribe to a topic. Returns 0 on success, -1 on error. */
__attribute__((import_module("hal"), import_name("event_subscribe")))
int32_t hal_event_subscribe(const char *topic, uint32_t topic_len);

/* Unsubscribe from a topic. Returns 0 on success, -1 if not subscribed. */
__attribute__((import_module("hal"), import_name("event_unsubscribe")))
int32_t hal_event_unsubscribe(const char *topic, uint32_t topic_len);

/* Publish data to a topic. Returns number of subscribers notified. */
__attribute__((import_module("hal"), import_name("event_publish")))
int32_t hal_event_publish(const char *topic, uint32_t topic_len,
                          const char *data, uint32_t data_len);

/* Returns size of next pending event (topic_len + data_len), 0 if none. */
__attribute__((import_module("hal"), import_name("event_available")))
uint32_t hal_event_available(void);

/* Read next pending event. Writes topic into topic_buf, data into data_buf.
 * Returns bytes written to data_buf, 0 if no event available. */
__attribute__((import_module("hal"), import_name("event_recv")))
uint32_t hal_event_recv(char *topic_buf, uint32_t topic_buf_len,
                        char *data_buf, uint32_t data_buf_len);

#ifdef __cplusplus
}
#endif

#endif /* GEOGRAM_WASM_HAL_H */
