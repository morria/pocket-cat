#include "ble_link.h"

#include <string.h>

#include "esp_check.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "nvs_flash.h"

#include "host/ble_hs.h"
#include "host/util/util.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

static const char *TAG = "ble_link";

#define DEVICE_NAME_PREFIX "CATBridge"

/*
 * Project 128-bit base UUID: 8f1dXXXX-52a4-4e1e-b34b-9d40b71d6e01
 * (must match test/tools/catproto.py). NimBLE stores the 16 bytes
 * least-significant first; the 16-bit id sits at value[12..13].
 */
#define BRIDGE_UUID128(id16)                                              \
    BLE_UUID128_INIT(0x01, 0x6e, 0x1d, 0xb7, 0x40, 0x9d, 0x4b, 0xb3,     \
                     0x1e, 0x4e, 0xa4, 0x52,                              \
                     (uint8_t)((id16) & 0xff), (uint8_t)((id16) >> 8),    \
                     0x1d, 0x8f)

static const ble_uuid128_t UUID_SVC = BRIDGE_UUID128(0x0001);
static const ble_uuid128_t UUID_CAT_RX = BRIDGE_UUID128(0x0002);
static const ble_uuid128_t UUID_CAT_TX = BRIDGE_UUID128(0x0003);
static const ble_uuid128_t UUID_CTRL = BRIDGE_UUID128(0x0004);
static const ble_uuid128_t UUID_STATUS = BRIDGE_UUID128(0x0005);
static const ble_uuid128_t UUID_SPECTRUM = BRIDGE_UUID128(0x0006);

typedef struct {
    bridge_t *bridge;
    uint16_t conn_handle;
    uint16_t h_cat_tx;
    uint16_t h_ctrl;
    uint16_t h_status;
    uint16_t h_spectrum;
    volatile bool ctrl_subscribed;
    volatile bool status_subscribed;
    uint8_t own_addr_type;
    char name[24];
} ble_link_t;

static ble_link_t s_ble = { .conn_handle = BLE_HS_CONN_HANDLE_NONE };

static void advertise_start(void);

/* ---------------------------------------------------------------------- */
/* Security helper                                                         */
/* ---------------------------------------------------------------------- */

static bool conn_permitted(uint16_t conn_handle)
{
#if CONFIG_BRIDGE_BLE_REQUIRE_BONDING
    /* Release policy (§4): no CAT/CTRL access without an encrypted link. */
    struct ble_gap_conn_desc desc;
    if (ble_gap_conn_find(conn_handle, &desc) != 0) {
        return false;
    }
    return desc.sec_state.encrypted;
#else
    (void)conn_handle;
    return true;
#endif
}

/* ---------------------------------------------------------------------- */
/* GATT access callbacks (NimBLE host task: bounded work only, §5.1)       */
/* ---------------------------------------------------------------------- */

static int chr_access_cb(uint16_t conn_handle, uint16_t attr_handle,
                         struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)arg;
    const ble_uuid_t *uuid = ctxt->chr->uuid;

    if (ctxt->op == BLE_GATT_ACCESS_OP_WRITE_CHR) {
        if (!conn_permitted(conn_handle)) {
            return BLE_ATT_ERR_INSUFFICIENT_AUTHEN;
        }
        /* Any legal ATT write payload fits: MTU is capped at 517 → ≤ 514. */
        uint8_t buf[COAL_BUF_SIZE + 2];
        uint16_t len = OS_MBUF_PKTLEN(ctxt->om);
        if (len > sizeof buf) {
            return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        }
        uint16_t copied = 0;
        if (ble_hs_mbuf_to_flat(ctxt->om, buf, sizeof buf, &copied) != 0) {
            return BLE_ATT_ERR_UNLIKELY;
        }

        if (ble_uuid_cmp(uuid, &UUID_CAT_RX.u) == 0) {
            bridge_on_ble_cat_write(s_ble.bridge, buf, copied); /* ring only */
            return 0;
        }
        if (ble_uuid_cmp(uuid, &UUID_CTRL.u) == 0) {
            if (copied > CTRL_MAX_FRAME) {
                return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
            }
            bridge_on_ctrl_write(s_ble.bridge, buf, copied); /* queue only */
            return 0;
        }
        return BLE_ATT_ERR_WRITE_NOT_PERMITTED;
    }

    if (ctxt->op == BLE_GATT_ACCESS_OP_READ_CHR &&
        ble_uuid_cmp(uuid, &UUID_STATUS.u) == 0) {
        uint8_t snap[CTRL_STATUS_SIZE];
        bridge_status_read(s_ble.bridge, snap, sizeof snap);
        return os_mbuf_append(ctxt->om, snap, sizeof snap) == 0
                   ? 0
                   : BLE_ATT_ERR_INSUFFICIENT_RES;
    }
    return BLE_ATT_ERR_UNLIKELY;
}

static const struct ble_gatt_svc_def gatt_svcs[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &UUID_SVC.u,
        .characteristics =
            (struct ble_gatt_chr_def[]){
                {
                    .uuid = &UUID_CAT_RX.u,
                    .access_cb = chr_access_cb,
                    .flags = BLE_GATT_CHR_F_WRITE |
                             BLE_GATT_CHR_F_WRITE_NO_RSP,
                },
                {
                    .uuid = &UUID_CAT_TX.u,
                    .access_cb = chr_access_cb,
                    .flags = BLE_GATT_CHR_F_NOTIFY,
                    .val_handle = &s_ble.h_cat_tx,
                },
                {
                    .uuid = &UUID_CTRL.u,
                    .access_cb = chr_access_cb,
                    .flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_NOTIFY,
                    .val_handle = &s_ble.h_ctrl,
                },
                {
                    .uuid = &UUID_STATUS.u,
                    .access_cb = chr_access_cb,
                    .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_NOTIFY,
                    .val_handle = &s_ble.h_status,
                },
                {
                    /* Panadapter frames (docs/qmx-panadapter.md §3.1). */
                    .uuid = &UUID_SPECTRUM.u,
                    .access_cb = chr_access_cb,
                    .flags = BLE_GATT_CHR_F_NOTIFY,
                    .val_handle = &s_ble.h_spectrum,
                },
                { 0 },
            },
    },
    { 0 },
};

/* ---------------------------------------------------------------------- */
/* GAP                                                                     */
/* ---------------------------------------------------------------------- */

static int gap_event_cb(struct ble_gap_event *event, void *arg)
{
    (void)arg;
    switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
        if (event->connect.status != 0) {
            ESP_LOGW(TAG, "connect failed (%d): re-advertising",
                     event->connect.status);
            advertise_start();
            break;
        }
        s_ble.conn_handle = event->connect.conn_handle;
        bridge_on_ble_connected(s_ble.bridge);
        ESP_LOGI(TAG, "central connected");
        /* Single central (§4): advertising stopped implicitly; ask for a
         * fast connection interval for CAT latency (iOS decides). */
        {
            struct ble_gap_upd_params params = {
                .itvl_min = 12, /* 15 ms */
                .itvl_max = 24, /* 30 ms */
                .latency = 0,
                .supervision_timeout = 400, /* 4 s */
            };
            ble_gap_update_params(event->connect.conn_handle, &params);
        }
        break;

    case BLE_GAP_EVENT_DISCONNECT:
        ESP_LOGI(TAG, "central disconnected (reason %d)",
                 event->disconnect.reason);
        s_ble.conn_handle = BLE_HS_CONN_HANDLE_NONE;
        s_ble.ctrl_subscribed = false;
        s_ble.status_subscribed = false;
        bridge_on_spectrum_subscribed(s_ble.bridge, false);
        bridge_on_ble_disconnected(s_ble.bridge); /* arms failsafe (§5.5) */
        advertise_start(); /* resume: this is the single-central policy */
        break;

    case BLE_GAP_EVENT_MTU:
        ESP_LOGI(TAG, "MTU %u", event->mtu.value);
        bridge_set_mtu(s_ble.bridge, event->mtu.value);
        break;

    case BLE_GAP_EVENT_SUBSCRIBE: {
        uint16_t h = event->subscribe.attr_handle;
        bool on = event->subscribe.cur_notify;
        if (h == s_ble.h_cat_tx) {
            bridge_on_ble_cat_subscribed(s_ble.bridge, on);
        } else if (h == s_ble.h_ctrl) {
            s_ble.ctrl_subscribed = on;
        } else if (h == s_ble.h_status) {
            s_ble.status_subscribed = on;
        } else if (h == s_ble.h_spectrum) {
            bridge_on_spectrum_subscribed(s_ble.bridge, on);
        }
        break;
    }

    case BLE_GAP_EVENT_ENC_CHANGE:
        ESP_LOGI(TAG, "encryption %s",
                 event->enc_change.status == 0 ? "on" : "failed");
        break;

    case BLE_GAP_EVENT_REPEAT_PAIRING: {
        /* Re-pairing from the bonded peer: delete the old bond and accept
         * (single-peer policy — a fresh phone re-bonds cleanly). */
        struct ble_gap_conn_desc desc;
        if (ble_gap_conn_find(event->repeat_pairing.conn_handle, &desc) == 0) {
            ble_store_util_delete_peer(&desc.peer_id_addr);
        }
        return BLE_GAP_REPEAT_PAIRING_RETRY;
    }

    default:
        break;
    }
    return 0;
}

static void advertise_start(void)
{
    struct ble_hs_adv_fields fields = { 0 };
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    /* Service UUID in the ADV payload for iOS background rediscovery (§6). */
    fields.uuids128 = (ble_uuid128_t *)&UUID_SVC;
    fields.num_uuids128 = 1;
    fields.uuids128_is_complete = 1;
    int rc = ble_gap_adv_set_fields(&fields);
    if (rc != 0) {
        ESP_LOGE(TAG, "adv_set_fields rc=%d", rc);
        return;
    }

    /* Device name goes in the scan response (no room next to a 128-bit
     * UUID in the 31-byte ADV PDU). */
    struct ble_hs_adv_fields rsp = { 0 };
    rsp.name = (const uint8_t *)s_ble.name;
    rsp.name_len = strlen(s_ble.name);
    rsp.name_is_complete = 1;
    rc = ble_gap_adv_rsp_set_fields(&rsp);
    if (rc != 0) {
        ESP_LOGE(TAG, "adv_rsp_set_fields rc=%d", rc);
    }

    struct ble_gap_adv_params adv = {
        .conn_mode = BLE_GAP_CONN_MODE_UND,
        .disc_mode = BLE_GAP_DISC_MODE_GEN,
    };
    rc = ble_gap_adv_start(s_ble.own_addr_type, NULL, BLE_HS_FOREVER, &adv,
                           gap_event_cb, NULL);
    if (rc != 0 && rc != BLE_HS_EALREADY) {
        ESP_LOGE(TAG, "adv_start rc=%d", rc);
    }
}

/* ---------------------------------------------------------------------- */
/* Host lifecycle                                                          */
/* ---------------------------------------------------------------------- */

static void on_sync(void)
{
    if (ble_hs_util_ensure_addr(0) != 0 ||
        ble_hs_id_infer_auto(0, &s_ble.own_addr_type) != 0) {
        ESP_LOGE(TAG, "no BLE address");
        return;
    }
    uint8_t addr[6];
    ble_hs_id_copy_addr(s_ble.own_addr_type, addr, NULL);
    snprintf(s_ble.name, sizeof s_ble.name, DEVICE_NAME_PREFIX "-%02X%02X",
             addr[1], addr[0]);
    ble_svc_gap_device_name_set(s_ble.name);
    ESP_LOGI(TAG, "advertising as %s", s_ble.name);
    advertise_start();
}

static void on_reset(int reason)
{
    ESP_LOGW(TAG, "host reset, reason=%d", reason);
}

static void nimble_host_task(void *arg)
{
    (void)arg;
    nimble_port_run(); /* returns only on nimble_port_stop() */
    nimble_port_freertos_deinit();
}

/* ---------------------------------------------------------------------- */
/* bridge_ops_t implementations (bridge task context)                      */
/* ---------------------------------------------------------------------- */

static int notify(uint16_t attr_handle, const uint8_t *data, size_t len)
{
    uint16_t conn = s_ble.conn_handle;
    if (conn == BLE_HS_CONN_HANDLE_NONE) {
        return -1;
    }
    struct os_mbuf *om = ble_hs_mbuf_from_flat(data, len);
    if (om == NULL) {
        return -1; /* out of mbufs: backpressure (§5.1) */
    }
    int rc = ble_gatts_notify_custom(conn, attr_handle, om);
    return rc == 0 ? 0 : -1;
}

int ble_link_op_notify_cat(void *ctx, const uint8_t *data, size_t len)
{
    (void)ctx;
    return notify(s_ble.h_cat_tx, data, len);
}

int ble_link_op_notify_ctrl(void *ctx, const uint8_t *data, size_t len)
{
    (void)ctx;
    if (!s_ble.ctrl_subscribed) {
        return -1; /* no subscriber: the central retries its command */
    }
    return notify(s_ble.h_ctrl, data, len);
}

int ble_link_op_notify_status(void *ctx, const uint8_t *data, size_t len)
{
    (void)ctx;
    if (!s_ble.status_subscribed) {
        return -1;
    }
    return notify(s_ble.h_status, data, len);
}

int ble_link_op_notify_spectrum(void *ctx, const uint8_t *data, size_t len)
{
    (void)ctx;
    /* Subscription is checked by the bridge (its atomic gates generation);
     * a failed notify here just drops the frame — never retried
     * (docs/qmx-panadapter.md §3.4). */
    return notify(s_ble.h_spectrum, data, len);
}

/* ---------------------------------------------------------------------- */
/* Startup                                                                 */
/* ---------------------------------------------------------------------- */

esp_err_t ble_link_start(bridge_t *bridge)
{
    s_ble.bridge = bridge;

    ESP_RETURN_ON_ERROR(nimble_port_init(), TAG, "nimble init");

    ble_hs_cfg.sync_cb = on_sync;
    ble_hs_cfg.reset_cb = on_reset;
    ble_hs_cfg.gatts_register_cb = NULL;
    ble_hs_cfg.store_status_cb = ble_store_util_status_rr;

    /* Security (§4): LE Secure Connections, Just Works bonding. */
    ble_hs_cfg.sm_io_cap = BLE_SM_IO_CAP_NO_IO;
    ble_hs_cfg.sm_sc = 1;
#if CONFIG_BRIDGE_BLE_REQUIRE_BONDING
    ble_hs_cfg.sm_bonding = 1;
    ble_hs_cfg.sm_mitm = 0;
    ble_hs_cfg.sm_our_key_dist = BLE_SM_PAIR_KEY_DIST_ENC |
                                 BLE_SM_PAIR_KEY_DIST_ID;
    ble_hs_cfg.sm_their_key_dist = BLE_SM_PAIR_KEY_DIST_ENC |
                                   BLE_SM_PAIR_KEY_DIST_ID;
#else
    ble_hs_cfg.sm_bonding = 0;
    ESP_LOGW(TAG, "*** BLE SECURITY DISABLED (debug build) ***");
#endif

    ble_svc_gap_init();
    ble_svc_gatt_init();

    int rc = ble_gatts_count_cfg(gatt_svcs);
    if (rc != 0) {
        return ESP_FAIL;
    }
    rc = ble_gatts_add_svcs(gatt_svcs);
    if (rc != 0) {
        return ESP_FAIL;
    }

    nimble_port_freertos_init(nimble_host_task);
    return ESP_OK;
}
