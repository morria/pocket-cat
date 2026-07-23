#include "ctrl_proto.h"

#include <string.h>

int ctrl_decode(const uint8_t *buf, size_t n, ctrl_frame_t *out)
{
    if (n == 0) {
        return -1;
    }
    if (n < CTRL_FRAME_OVERHEAD) {
        return 0; /* incomplete: have opcode but no length yet */
    }
    uint8_t len = buf[1];
    if (n < (size_t)(CTRL_FRAME_OVERHEAD + len)) {
        return 0; /* incomplete payload */
    }
    out->op = buf[0];
    out->len = len;
    out->payload = len ? &buf[2] : NULL;
    return (int)(CTRL_FRAME_OVERHEAD + len);
}

int ctrl_encode(uint8_t op, const uint8_t *payload, uint8_t len,
                uint8_t *out, size_t cap)
{
    if (cap < (size_t)(CTRL_FRAME_OVERHEAD + len)) {
        return -1;
    }
    out[0] = op;
    out[1] = len;
    if (len) {
        memcpy(&out[2], payload, len);
    }
    return (int)(CTRL_FRAME_OVERHEAD + len);
}

int ctrl_encode_ack(uint8_t orig_op, uint8_t *out, size_t cap)
{
    uint8_t p[2] = { orig_op, CTRL_ERR_OK };
    return ctrl_encode(CTRL_OP_ACK, p, sizeof p, out, cap);
}

int ctrl_encode_nak(uint8_t orig_op, uint8_t err, uint8_t *out, size_t cap)
{
    uint8_t p[2] = { orig_op, err };
    return ctrl_encode(CTRL_OP_NAK, p, sizeof p, out, cap);
}

int ctrl_encode_evt_usb(ctrl_usb_state_t state, ctrl_radio_id_t radio,
                        uint8_t *out, size_t cap)
{
    uint8_t p[2] = { (uint8_t)state, (uint8_t)radio };
    return ctrl_encode(CTRL_OP_EVT_USB, p, sizeof p, out, cap);
}

int ctrl_encode_evt_overflow(uint8_t which, uint32_t dropped,
                             uint8_t *out, size_t cap)
{
    uint8_t p[5];
    p[0] = which;
    ctrl_put_u32le(&p[1], dropped);
    return ctrl_encode(CTRL_OP_EVT_OVERFLOW, p, sizeof p, out, cap);
}

uint32_t ctrl_get_u32le(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) |
           ((uint32_t)p[3] << 24);
}

void ctrl_put_u32le(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)(v & 0xFF);
    p[1] = (uint8_t)((v >> 8) & 0xFF);
    p[2] = (uint8_t)((v >> 16) & 0xFF);
    p[3] = (uint8_t)((v >> 24) & 0xFF);
}

int ctrl_status_encode(const ctrl_status_t *s, uint8_t *out, size_t cap)
{
    if (cap < CTRL_STATUS_SIZE) {
        return -1;
    }
    out[0] = CTRL_STATUS_FMT_VERSION;
    out[1] = s->usb_state;
    out[2] = s->radio_id;
    ctrl_put_u32le(&out[3], s->baud);
    ctrl_put_u32le(&out[7], s->drops_usb_to_ble);
    ctrl_put_u32le(&out[11], s->drops_ble_to_usb);
    out[15] = s->fw_major;
    out[16] = s->fw_minor;
    out[17] = s->reset_reason;
    ctrl_put_u32le(&out[18], s->min_free_heap);
    return (int)CTRL_STATUS_SIZE;
}

int ctrl_status_decode(const uint8_t *buf, size_t n, ctrl_status_t *out)
{
    if (n < CTRL_STATUS_SIZE || buf[0] != CTRL_STATUS_FMT_VERSION) {
        return -1;
    }
    out->usb_state = buf[1];
    out->radio_id = buf[2];
    out->baud = ctrl_get_u32le(&buf[3]);
    out->drops_usb_to_ble = ctrl_get_u32le(&buf[7]);
    out->drops_ble_to_usb = ctrl_get_u32le(&buf[11]);
    out->fw_major = buf[15];
    out->fw_minor = buf[16];
    out->reset_reason = buf[17];
    out->min_free_heap = ctrl_get_u32le(&buf[18]);
    return 0;
}
