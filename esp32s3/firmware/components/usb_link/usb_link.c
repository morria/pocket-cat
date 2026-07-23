#include "usb_link.h"

#include <string.h>

#include "esp_check.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "usb/cdc_acm_host.h"
#include "usb/usb_host.h"

#include "radio_detect.h"

static const char *TAG = "usb_link";

/* --- CP210x vendor requests (SiLabs AN571) -------------------------------- */
#define CP210X_REQTYPE_OUT     0x41 /* host→device, vendor, interface        */
#define CP210X_REQ_IFC_ENABLE  0x00
#define CP210X_REQ_SET_LINE_CTL 0x03
#define CP210X_REQ_SET_MHS     0x07
#define CP210X_REQ_PURGE       0x12
#define CP210X_REQ_SET_BAUDRATE 0x1E
#define CP210X_LINE_CTL_8N1    0x0800 /* 8 data, no parity, 1 stop           */
#define CP210X_MHS_MASK_BOTH   0x0300 /* DTR+RTS mask bits                   */

#define USB_LINK_TASK_STACK    4096
#define USB_LINK_TASK_PRIO     10
#define USB_HOST_TASK_STACK    4096
#define USB_HOST_TASK_PRIO     12
#define OPEN_RETRY_MAX         3
#define OPEN_RETRY_WINDOW_MS   10000
#define OPEN_BACKOFF_MS        5000

typedef enum {
    EVT_DEVICE_SEEN,   /* new_dev callback captured a profile              */
    EVT_DISCONNECTED,  /* CDC event: device gone                           */
    EVT_REQ_RESET,     /* CTRL USB_RESET: close + reopen                   */
} link_evt_type_t;

typedef struct {
    link_evt_type_t type;
    uint16_t vid;
    uint16_t pid;
    rd_profile_t profile;
} link_evt_t;

typedef struct {
    bridge_t *bridge;
    QueueHandle_t evq;
    cdc_acm_dev_hdl_t hdl;         /* open device, NULL when detached      */
    rd_profile_t profile;          /* profile of the open device           */
    uint16_t vid, pid;
    int open_failures;
    int64_t first_failure_ms;
} usb_link_t;

static usb_link_t s_link;

/* ---------------------------------------------------------------------- */
/* USB host library daemon                                                 */
/* ---------------------------------------------------------------------- */

static void usb_host_task(void *arg)
{
    (void)arg;
    while (true) {
        uint32_t flags;
        usb_host_lib_handle_events(portMAX_DELAY, &flags);
        if (flags & USB_HOST_LIB_EVENT_FLAGS_NO_CLIENTS) {
            usb_host_device_free_all();
        }
    }
}

/* ---------------------------------------------------------------------- */
/* Device detection (runs in CDC host driver context — no opening here)    */
/* ---------------------------------------------------------------------- */

static void on_new_device(usb_device_handle_t usb_dev)
{
    const usb_device_desc_t *dev_desc;
    const usb_config_desc_t *cfg_desc;
    if (usb_host_get_device_descriptor(usb_dev, &dev_desc) != ESP_OK ||
        usb_host_get_active_config_descriptor(usb_dev, &cfg_desc) != ESP_OK) {
        ESP_LOGE(TAG, "descriptor read failed");
        return;
    }

    /* Walk every interface for the per-interface match table (§5.2). */
    rd_iface_t ifaces[16];
    size_t n_ifaces = 0;
    int offset = 0;
    const usb_standard_desc_t *d = (const usb_standard_desc_t *)cfg_desc;
    while ((d = usb_parse_next_descriptor_of_type(
                d, cfg_desc->wTotalLength, USB_B_DESCRIPTOR_TYPE_INTERFACE,
                &offset)) != NULL) {
        const usb_intf_desc_t *intf = (const usb_intf_desc_t *)d;
        if (intf->bAlternateSetting != 0 || n_ifaces >= 16) {
            continue;
        }
        ifaces[n_ifaces++] = (rd_iface_t){
            .number = intf->bInterfaceNumber,
            .if_class = intf->bInterfaceClass,
            .if_subclass = intf->bInterfaceSubClass,
            .if_protocol = intf->bInterfaceProtocol,
        };
    }

    rd_device_t dev = {
        .vid = dev_desc->idVendor,
        .pid = dev_desc->idProduct,
        .ifaces = ifaces,
        .n_ifaces = n_ifaces,
    };
    link_evt_t evt = {
        .type = EVT_DEVICE_SEEN,
        .vid = dev.vid,
        .pid = dev.pid,
        .profile = radio_detect(&dev),
    };
    ESP_LOGI(TAG, "device %04x:%04x (%u ifaces) -> radio=%d driver=%d iface=%u",
             dev.vid, dev.pid, (unsigned)n_ifaces, evt.profile.radio,
             evt.profile.driver, evt.profile.cat_iface);
    xQueueSend(s_link.evq, &evt, 0);
}

/* ---------------------------------------------------------------------- */
/* CDC device callbacks                                                    */
/* ---------------------------------------------------------------------- */

static bool on_data(const uint8_t *data, size_t len, void *user_arg)
{
    bridge_t *b = user_arg;
    bridge_on_usb_rx(b, data, len); /* bounded ring write only (§5.1) */
    return true;
}

static void on_dev_event(const cdc_acm_host_dev_event_data_t *event,
                         void *user_ctx)
{
    (void)user_ctx;
    switch (event->type) {
    case CDC_ACM_HOST_DEVICE_DISCONNECTED: {
        link_evt_t evt = { .type = EVT_DISCONNECTED };
        xQueueSend(s_link.evq, &evt, 0);
        break;
    }
    case CDC_ACM_HOST_ERROR:
        ESP_LOGW(TAG, "device error %d", event->data.error);
        break;
    default:
        break;
    }
}

/* ---------------------------------------------------------------------- */
/* CP210x setup (vendor control transfers)                                 */
/* ---------------------------------------------------------------------- */

static esp_err_t cp210x_vendor(uint8_t req, uint16_t value, uint16_t len,
                               uint8_t *data)
{
    return cdc_acm_host_send_custom_request(
        s_link.hdl, CP210X_REQTYPE_OUT, req, value, s_link.profile.cat_iface,
        len, data);
}

static esp_err_t cp210x_set_baud(uint32_t baud)
{
    uint8_t b[4] = { (uint8_t)baud, (uint8_t)(baud >> 8),
                     (uint8_t)(baud >> 16), (uint8_t)(baud >> 24) };
    return cp210x_vendor(CP210X_REQ_SET_BAUDRATE, 0, sizeof b, b);
}

static esp_err_t cp210x_setup(uint32_t baud)
{
    esp_err_t err = cp210x_vendor(CP210X_REQ_IFC_ENABLE, 1, 0, NULL);
    if (err != ESP_OK) {
        return err;
    }
    err = cp210x_vendor(CP210X_REQ_SET_LINE_CTL, CP210X_LINE_CTL_8N1, 0, NULL);
    if (err != ESP_OK) {
        return err;
    }
    return cp210x_set_baud(baud);
}

static bool is_cp210x(void)
{
    return s_link.profile.driver == RD_DRIVER_CP210X;
}

/* ---------------------------------------------------------------------- */
/* Open / close                                                            */
/* ---------------------------------------------------------------------- */

static void report_error_backoff(void)
{
    int64_t now = (int64_t)xTaskGetTickCount() * portTICK_PERIOD_MS;
    if (s_link.open_failures == 0 ||
        now - s_link.first_failure_ms > OPEN_RETRY_WINDOW_MS) {
        s_link.first_failure_ms = now;
        s_link.open_failures = 0;
    }
    if (++s_link.open_failures >= OPEN_RETRY_MAX) {
        ESP_LOGE(TAG, "repeated open failures — backing off %d ms",
                 OPEN_BACKOFF_MS);
        bridge_on_usb_error(s_link.bridge); /* §5.5: report USB_ERROR */
        vTaskDelay(pdMS_TO_TICKS(OPEN_BACKOFF_MS));
        s_link.open_failures = 0;
    }
}

static void try_open(const link_evt_t *evt)
{
    if (s_link.hdl != NULL) {
        ESP_LOGW(TAG, "device already open — ignoring new device");
        return;
    }
    s_link.profile = evt->profile;
    s_link.vid = evt->vid;
    s_link.pid = evt->pid;

    if (evt->profile.driver == RD_DRIVER_NONE ||
        evt->profile.driver == RD_DRIVER_FTDI) {
        /* Unsupported (or not-yet-implemented FTDI): stay attached and
         * report so the app can tell the user (§5.2). */
        bridge_on_usb_connected(s_link.bridge, CTRL_RADIO_UNSUPPORTED, 0);
        return;
    }

    const cdc_acm_host_device_config_t cfg = {
        .connection_timeout_ms = 1000,
        .out_buffer_size = 256,
        .in_buffer_size = 512,
        .event_cb = on_dev_event,
        .data_cb = on_data,
        .user_arg = s_link.bridge,
    };
    esp_err_t err = cdc_acm_host_open(evt->vid, evt->pid,
                                      evt->profile.cat_iface, &cfg,
                                      &s_link.hdl);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "open %04x:%04x iface %u failed: %s", evt->vid,
                 evt->pid, evt->profile.cat_iface, esp_err_to_name(err));
        s_link.hdl = NULL;
        report_error_backoff();
        return;
    }

    /* Initial line coding: profile default (app renegotiates via SET_BAUD). */
    if (is_cp210x()) {
        err = cp210x_setup(evt->profile.default_baud);
    } else {
        cdc_acm_line_coding_t lc = {
            .dwDTERate = evt->profile.default_baud,
            .bCharFormat = 0, /* 1 stop bit */
            .bParityType = 0, /* none */
            .bDataBits = 8,
        };
        err = cdc_acm_host_line_coding_set(s_link.hdl, &lc);
    }
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "line coding setup failed: %s (continuing)",
                 esp_err_to_name(err));
    }

    s_link.open_failures = 0;
    bridge_on_usb_connected(s_link.bridge, evt->profile.radio,
                            evt->profile.default_baud);
    ESP_LOGI(TAG, "radio open: id=%d baud=%lu", evt->profile.radio,
             (unsigned long)evt->profile.default_baud);
}

static void do_close(void)
{
    if (s_link.hdl != NULL) {
        cdc_acm_host_close(s_link.hdl);
        s_link.hdl = NULL;
    }
    bridge_on_usb_disconnected(s_link.bridge);
}

/* ---------------------------------------------------------------------- */
/* Link task: serialized open/close/reset                                  */
/* ---------------------------------------------------------------------- */

static void usb_link_task(void *arg)
{
    (void)arg;
    link_evt_t evt;
    while (true) {
        if (xQueueReceive(s_link.evq, &evt, portMAX_DELAY) != pdTRUE) {
            continue;
        }
        switch (evt.type) {
        case EVT_DEVICE_SEEN:
            try_open(&evt);
            break;
        case EVT_DISCONNECTED:
            ESP_LOGI(TAG, "radio disconnected");
            do_close();
            break;
        case EVT_REQ_RESET:
            /* Soft reset: close and reopen with the stored identity. The
             * CDC driver re-detects the device; a hard port power-cycle
             * needs external VBUS control (future: docs §4.1 note). */
            ESP_LOGI(TAG, "USB_RESET: reopening device");
            if (s_link.hdl != NULL) {
                link_evt_t reopen = {
                    .type = EVT_DEVICE_SEEN,
                    .vid = s_link.vid,
                    .pid = s_link.pid,
                    .profile = s_link.profile,
                };
                do_close();
                vTaskDelay(pdMS_TO_TICKS(100));
                try_open(&reopen);
            }
            break;
        }
    }
}

/* ---------------------------------------------------------------------- */
/* bridge_ops_t implementations (called from the bridge task)              */
/* ---------------------------------------------------------------------- */

int usb_link_op_tx(void *ctx, const uint8_t *data, size_t len)
{
    (void)ctx;
    if (s_link.hdl == NULL) {
        return -1;
    }
    /* CAT is slow; 500 ms covers a worst-case 64-byte chunk at 4800 baud. */
    esp_err_t err = cdc_acm_host_data_tx_blocking(
        s_link.hdl, (uint8_t *)data, len, 500);
    return err == ESP_OK ? 0 : -1;
}

int usb_link_op_set_baud(void *ctx, uint32_t baud)
{
    (void)ctx;
    if (s_link.hdl == NULL) {
        return -1;
    }
    esp_err_t err;
    if (is_cp210x()) {
        err = cp210x_set_baud(baud);
    } else {
        cdc_acm_line_coding_t lc = {
            .dwDTERate = baud,
            .bCharFormat = 0,
            .bParityType = 0,
            .bDataBits = 8,
        };
        err = cdc_acm_host_line_coding_set(s_link.hdl, &lc);
    }
    return err == ESP_OK ? 0 : -1;
}

int usb_link_op_set_line(void *ctx, bool dtr, bool rts)
{
    (void)ctx;
    if (s_link.hdl == NULL) {
        return -1;
    }
    esp_err_t err;
    if (is_cp210x()) {
        uint16_t v = CP210X_MHS_MASK_BOTH | (dtr ? 1 : 0) | (rts ? 2 : 0);
        err = cp210x_vendor(CP210X_REQ_SET_MHS, v, 0, NULL);
    } else {
        err = cdc_acm_host_set_control_line_state(s_link.hdl, dtr, rts);
    }
    return err == ESP_OK ? 0 : -1;
}

int usb_link_op_reset(void *ctx)
{
    (void)ctx;
    if (s_link.hdl == NULL) {
        return -1;
    }
    link_evt_t evt = { .type = EVT_REQ_RESET };
    return xQueueSend(s_link.evq, &evt, 0) == pdTRUE ? 0 : -1;
}

/* ---------------------------------------------------------------------- */
/* Startup                                                                 */
/* ---------------------------------------------------------------------- */

esp_err_t usb_link_start(bridge_t *bridge)
{
    s_link.bridge = bridge;
    s_link.evq = xQueueCreate(8, sizeof(link_evt_t));
    if (s_link.evq == NULL) {
        return ESP_ERR_NO_MEM;
    }

    const usb_host_config_t host_cfg = {
        .skip_phy_setup = false,
        .intr_flags = ESP_INTR_FLAG_LEVEL1,
    };
    ESP_RETURN_ON_ERROR(usb_host_install(&host_cfg), TAG, "host install");

    if (xTaskCreate(usb_host_task, "usb_host", USB_HOST_TASK_STACK, NULL,
                    USB_HOST_TASK_PRIO, NULL) != pdTRUE) {
        return ESP_ERR_NO_MEM;
    }

    const cdc_acm_host_driver_config_t drv_cfg = {
        .driver_task_stack_size = 4096,
        .driver_task_priority = 11,
        .xCoreID = 0,
        .new_dev_cb = on_new_device,
    };
    ESP_RETURN_ON_ERROR(cdc_acm_host_install(&drv_cfg), TAG, "cdc install");

    if (xTaskCreate(usb_link_task, "usb_link", USB_LINK_TASK_STACK, NULL,
                    USB_LINK_TASK_PRIO, NULL) != pdTRUE) {
        return ESP_ERR_NO_MEM;
    }
    ESP_LOGI(TAG, "USB host up, waiting for radio");
    return ESP_OK;
}
