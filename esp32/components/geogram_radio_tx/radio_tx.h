/**
 * @file radio_tx.h
 * @brief Generic radio TX queue — decoupled from HTTP and BLE
 *
 * Provides a FreeRTOS queue + background task that dequeues items and
 * transmits them via an injected radio backend (function pointers).
 */

#ifndef GEOGRAM_RADIO_TX_H
#define GEOGRAM_RADIO_TX_H

#include <stdbool.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

#define RADIO_TX_MAX_CALLSIGN  10
#define RADIO_TX_MAX_MESSAGE   68

typedef struct {
    char from[RADIO_TX_MAX_CALLSIGN];
    char to[RADIO_TX_MAX_CALLSIGN];
    char message[RADIO_TX_MAX_MESSAGE];
} radio_tx_item_t;

/** Function that returns the current radio handle (may be NULL). */
typedef void *(*radio_tx_getter_t)(void);

/** Function that transmits a message via the radio handle. */
typedef esp_err_t (*radio_tx_send_fn_t)(void *handle, const char *from,
                                         const char *to, const char *message);

/** Set the radio handle getter and send function. */
void radio_tx_set_backend(radio_tx_getter_t getter, radio_tx_send_fn_t send_fn);

/** Init TX queue + background task. Safe to call multiple times. */
void radio_tx_queue_init(void);

/** Enqueue a message for radio TX. Returns true on success. */
bool radio_tx_queue_send(const radio_tx_item_t *item);

#ifdef __cplusplus
}
#endif

#endif // GEOGRAM_RADIO_TX_H
