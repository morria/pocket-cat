#include "led.h"

#include "driver/gpio.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#define LED_GPIO 21 /* XIAO ESP32S3 user LED, active-low */

/* §5.6 patterns, sampled at 100 ms resolution over a 3 s cycle. */
static bool pattern_bit(bridge_t *b, uint32_t slot)
{
    uint8_t usb = atomic_load(&b->usb_state);
    bool ble = atomic_load(&b->ble_connected);

#if !CONFIG_BRIDGE_BLE_REQUIRE_BONDING
    /* Debug-open build: triple-blink burst overlay every 3 s (§5.6). */
    if (slot < 6) {
        return (slot % 2) == 0;
    }
#endif
    if (usb == (uint8_t)CTRL_USB_ERROR) {
        return (slot % 2) == 0; /* fast blink 5 Hz */
    }
    if (ble && usb == (uint8_t)CTRL_USB_ENUMERATED) {
        return true; /* solid: bridge live */
    }
    if (usb == (uint8_t)CTRL_USB_ENUMERATED) {
        return (slot % 10) < 2 && (slot % 10) != 1; /* double-blink-ish */
    }
    return (slot % 10) < 5; /* slow blink 1 Hz: idle */
}

static void led_task(void *arg)
{
    bridge_t *b = arg;
    uint32_t slot = 0;
    while (true) {
        gpio_set_level(LED_GPIO, pattern_bit(b, slot) ? 0 : 1); /* active-low */
        slot = (slot + 1) % 30;
        vTaskDelay(pdMS_TO_TICKS(100));
    }
}

void led_start(bridge_t *bridge)
{
    gpio_config_t cfg = {
        .pin_bit_mask = 1ULL << LED_GPIO,
        .mode = GPIO_MODE_OUTPUT,
    };
    gpio_config(&cfg);
    xTaskCreate(led_task, "led", 2048, bridge, 2, NULL);
}
