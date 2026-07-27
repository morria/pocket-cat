/*
 * ctrl_proto — control-channel TLV codec for the BLE CTRL characteristic.
 *
 * Frame format (docs/implementation.md §4.1):
 *   [opcode:1][len:1][payload:len]
 *
 * Pure C11, no ESP-IDF / FreeRTOS dependencies: unit-tested on the Linux host.
 * All multi-byte integers are little-endian on the wire.
 */
#ifndef CTRL_PROTO_H
#define CTRL_PROTO_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* --- Opcodes (central → peripheral) ------------------------------------- */
#define CTRL_OP_SET_BAUD     0x01u /* payload: u32 LE baud                   */
#define CTRL_OP_GET_STATUS   0x02u /* payload: none                          */
#define CTRL_OP_USB_RESET    0x03u /* payload: none                          */
#define CTRL_OP_SET_LINE     0x04u /* payload: u8 bitmap (bit0 DTR, bit1 RTS)*/
#define CTRL_OP_PURGE        0x05u /* payload: u8 mask (bit0 usb→ble, bit1 ble→usb) */
#define CTRL_OP_SET_FAILSAFE 0x06u /* payload: 0–32 raw bytes; empty = disarm */
#define CTRL_OP_SET_SPECTRUM 0x07u /* payload: [enable u8][bins u16 LE][fps u8]
                                    * enable=0 stops (other fields ignored);
                                    * enable=1 while running reconfigures.
                                    * Firmware without the DSP path answers
                                    * NAK CTRL_ERR_UNSUPPORTED
                                    * (docs/qmx-panadapter.md §3.2). */

/* --- Opcodes (peripheral → central) ------------------------------------- */
#define CTRL_OP_ACK          0x80u /* payload: [orig_opcode, err=0]          */
#define CTRL_OP_NAK          0x81u /* payload: [orig_opcode, err]            */
#define CTRL_OP_EVT_USB      0x82u /* payload: [usb_state, radio_id]         */
#define CTRL_OP_EVT_OVERFLOW 0x83u /* payload: [which, dropped u32 LE]       */

/* GET_STATUS is answered with a CTRL frame [CTRL_OP_GET_STATUS][n][status]
 * — the answer *is* the ack; no separate ACK frame follows it. */

/* --- Error codes (ACK/NAK second payload byte) --------------------------- */
#define CTRL_ERR_OK          0x00u
#define CTRL_ERR_BAD_LEN     0x01u /* payload length wrong for opcode        */
#define CTRL_ERR_BAD_ARG     0x02u /* payload value out of range             */
#define CTRL_ERR_NO_USB      0x03u /* no radio enumerated                    */
#define CTRL_ERR_UNSUPPORTED 0x04u /* valid op, not supported by this device */
#define CTRL_ERR_BUSY        0x05u /* try again                              */
#define CTRL_ERR_UNKNOWN_OP  0x06u /* opcode not recognised                  */

/* --- PURGE mask bits ------------------------------------------------------ */
#define CTRL_PURGE_USB_TO_BLE 0x01u
#define CTRL_PURGE_BLE_TO_USB 0x02u

/* --- SET_LINE bitmap bits ------------------------------------------------- */
#define CTRL_LINE_DTR 0x01u
#define CTRL_LINE_RTS 0x02u

/* --- Limits --------------------------------------------------------------- */
#define CTRL_MAX_PAYLOAD    255u
#define CTRL_FRAME_OVERHEAD 2u /* opcode + len */
#define CTRL_MAX_FRAME      (CTRL_FRAME_OVERHEAD + CTRL_MAX_PAYLOAD)
#define CTRL_FAILSAFE_MAX   32u

/* --- USB link states (STATUS.usb_state / EVT_USB) ------------------------- */
typedef enum {
    CTRL_USB_WAITING    = 0, /* host up, no device                           */
    CTRL_USB_ENUMERATED = 1, /* radio attached and CAT interface open        */
    CTRL_USB_ERROR      = 2, /* repeated enumeration/transfer failures       */
} ctrl_usb_state_t;

/* --- Radio identity (STATUS.radio_id / EVT_USB) --------------------------- */
typedef enum {
    CTRL_RADIO_NONE           = 0,
    CTRL_RADIO_FT891          = 1, /* CP2105, Yaesu CAT dialect              */
    CTRL_RADIO_GENERIC_CP210X = 2, /* FTX-1 candidate, Yaesu CAT dialect     */
    CTRL_RADIO_QMX_CDC        = 3, /* CDC-ACM, Kenwood TS-480 dialect        */
    CTRL_RADIO_GENERIC_FTDI   = 4,
    CTRL_RADIO_UNSUPPORTED    = 5,
} ctrl_radio_id_t;

/* --- Decoded frame -------------------------------------------------------- */
typedef struct {
    uint8_t op;
    uint8_t len;
    const uint8_t *payload; /* points into the caller's buffer */
} ctrl_frame_t;

/*
 * Decode one frame from buf[0..n). Returns the number of bytes consumed
 * (2 + len) on success, 0 if the buffer holds an incomplete frame, and -1
 * if n == 0. A frame whose opcode is unknown still decodes successfully —
 * dispatch decides how to answer (NAK CTRL_ERR_UNKNOWN_OP).
 */
int ctrl_decode(const uint8_t *buf, size_t n, ctrl_frame_t *out);

/*
 * Encode helpers. Each writes into out (capacity cap) and returns the frame
 * length, or -1 if cap is too small or the payload is over-size.
 */
int ctrl_encode(uint8_t op, const uint8_t *payload, uint8_t len,
                uint8_t *out, size_t cap);
int ctrl_encode_ack(uint8_t orig_op, uint8_t *out, size_t cap);
int ctrl_encode_nak(uint8_t orig_op, uint8_t err, uint8_t *out, size_t cap);
int ctrl_encode_evt_usb(ctrl_usb_state_t state, ctrl_radio_id_t radio,
                        uint8_t *out, size_t cap);
int ctrl_encode_evt_overflow(uint8_t which, uint32_t dropped,
                             uint8_t *out, size_t cap);

/* Little-endian u32 helpers (shared by status encode and SET_BAUD parse). */
uint32_t ctrl_get_u32le(const uint8_t *p);
void ctrl_put_u32le(uint8_t *p, uint32_t v);

/* --- STATUS characteristic payload ---------------------------------------
 * Versioned, packed, little-endian (docs/implementation.md §4).
 */
#define CTRL_STATUS_FMT_VERSION 1u
#define CTRL_STATUS_SIZE        22u

typedef struct {
    uint8_t usb_state;         /* ctrl_usb_state_t   */
    uint8_t radio_id;          /* ctrl_radio_id_t    */
    uint32_t baud;             /* current line coding */
    uint32_t drops_usb_to_ble; /* lifetime dropped bytes */
    uint32_t drops_ble_to_usb;
    uint8_t fw_major;
    uint8_t fw_minor;
    uint8_t reset_reason;      /* platform enum, 0 = unknown/power-on */
    uint32_t min_free_heap;    /* bytes; 0 on host builds */
} ctrl_status_t;

/* Returns CTRL_STATUS_SIZE, or -1 if cap < CTRL_STATUS_SIZE. */
int ctrl_status_encode(const ctrl_status_t *s, uint8_t *out, size_t cap);
/* Returns 0 on success, -1 on short buffer or version mismatch. */
int ctrl_status_decode(const uint8_t *buf, size_t n, ctrl_status_t *out);

#ifdef __cplusplus
}
#endif

#endif /* CTRL_PROTO_H */
