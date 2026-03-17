/**
 * @file radio_tx.c
 * @brief Generic radio TX queue implementation
 */

#include "radio_tx.h"

#include <string.h>
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"

static const char *TAG = "radio_tx";

#define RADIO_TX_QUEUE_SIZE  12

static QueueHandle_t s_queue = NULL;
static radio_tx_getter_t s_getter = NULL;
static radio_tx_send_fn_t s_send_fn = NULL;

void radio_tx_set_backend(radio_tx_getter_t getter, radio_tx_send_fn_t send_fn)
{
    s_getter = getter;
    s_send_fn = send_fn;
}

static void radio_tx_task(void *arg)
{
    radio_tx_item_t item;
    while (true) {
        if (xQueueReceive(s_queue, &item, portMAX_DELAY) == pdTRUE) {
            ESP_LOGI(TAG, "dequeued %s -> %s", item.from, item.to);

            if (!s_getter || !s_send_fn) {
                ESP_LOGW(TAG, "no backend configured");
                continue;
            }

            void *handle = s_getter();
            if (!handle) {
                ESP_LOGW(TAG, "radio handle is NULL");
                continue;
            }

            esp_err_t err = s_send_fn(handle, item.from, item.to, item.message);
            if (err != ESP_OK) {
                ESP_LOGW(TAG, "TX failed: %s", esp_err_to_name(err));
            } else {
                ESP_LOGI(TAG, "TX complete OK");
            }
        }
    }
}

void radio_tx_queue_init(void)
{
    if (s_queue != NULL) {
        return;
    }

    s_queue = xQueueCreate(RADIO_TX_QUEUE_SIZE, sizeof(radio_tx_item_t));
    if (s_queue) {
        xTaskCreatePinnedToCore(radio_tx_task, "radio_tx", 8192, NULL, 5, NULL, 1);
        ESP_LOGI(TAG, "TX queue initialized (depth=%d)", RADIO_TX_QUEUE_SIZE);
    } else {
        ESP_LOGE(TAG, "Failed to create TX queue");
    }
}

bool radio_tx_queue_send(const radio_tx_item_t *item)
{
    if (!s_queue || !item) {
        return false;
    }
    return xQueueSend(s_queue, item, 0) == pdTRUE;
}
