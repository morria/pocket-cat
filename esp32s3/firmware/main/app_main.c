/*
 * CAT bridge firmware entry point (docs/implementation.md §5.1).
 *
 * Wires bridge_core to usb_link + ble_link and runs the bridge task
 * (the byte pump) in a dedicated task with the task watchdog attached.
 */
#include <stdio.h>

#include "esp_log.h"
#include "esp_system.h"
#include "esp_task_wdt.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "nvs_flash.h"

#include "ble_link.h"
#include "bridge_core.h"
#include "led.h"
#include "usb_link.h"

static const char *TAG = "app";

static bridge_t s_bridge;
static uint8_t s_rb_u2b[BRIDGE_RB_USB_TO_BLE_CAP];
static uint8_t s_rb_b2u[BRIDGE_RB_BLE_TO_USB_CAP];

static uint32_t op_now_ms(void *ctx)
{
    (void)ctx;
    return (uint32_t)(esp_timer_get_time() / 1000);
}

static void bridge_task(void *arg)
{
    (void)arg;
    ESP_ERROR_CHECK(esp_task_wdt_add(NULL));
    uint32_t housekeeping = 0;
    while (true) {
        bool did = bridge_poll(&s_bridge);
        esp_task_wdt_reset();

        /* Low-rate housekeeping: heap watermark for STATUS (§7.3). */
        if (++housekeeping >= 1000) {
            housekeeping = 0;
            s_bridge.min_free_heap = esp_get_minimum_free_heap_size();
        }
        /* 1 ms tick when active keeps CAT latency low; back off when idle. */
        vTaskDelay(pdMS_TO_TICKS(did ? 1 : 2));
    }
}

void app_main(void)
{
    /* NVS: NimBLE bond storage lives here. */
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES ||
        err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ESP_ERROR_CHECK(nvs_flash_init());
    }

    const bridge_ops_t ops = {
        .usb_tx = usb_link_op_tx,
        .ble_notify_cat = ble_link_op_notify_cat,
        .ble_notify_ctrl = ble_link_op_notify_ctrl,
        .ble_notify_status = ble_link_op_notify_status,
        .set_baud = usb_link_op_set_baud,
        .set_line = usb_link_op_set_line,
        .usb_reset = usb_link_op_reset,
        .now_ms = op_now_ms,
        .ctx = &s_bridge,
    };
    bridge_init(&s_bridge, &ops, s_rb_u2b, sizeof s_rb_u2b, s_rb_b2u,
                sizeof s_rb_b2u);
    s_bridge.reset_reason = (uint8_t)esp_reset_reason();
    s_bridge.min_free_heap = esp_get_minimum_free_heap_size();

    ESP_ERROR_CHECK(ble_link_start(&s_bridge));
    ESP_ERROR_CHECK(usb_link_start(&s_bridge));
    led_start(&s_bridge);

    ESP_LOGI(TAG, "CAT bridge fw %d.%d up (reset reason %d)",
             BRIDGE_FW_MAJOR, BRIDGE_FW_MINOR, s_bridge.reset_reason);

    xTaskCreate(bridge_task, "bridge", 4096, NULL, 9, NULL);
}
