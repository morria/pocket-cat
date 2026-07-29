/*
 * radio_detect — maps a USB device's descriptor summary to a radio profile
 * (docs/implementation.md §5.2, docs/references/usb-cp210x-cdc.md).
 *
 * Matching is PER-INTERFACE: modern rigs (FT-710 / expected FTX-1) enumerate
 * as composite devices (USB audio + serial), so the caller passes every
 * interface and the table skips non-serial ones.
 *
 * Pure C, host-testable. The profile selects driver, interface, and default
 * line coding — never protocol behavior (the remote owns the CAT dialect).
 */
#ifndef RADIO_DETECT_H
#define RADIO_DETECT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "ctrl_proto.h" /* ctrl_radio_id_t */

#ifdef __cplusplus
extern "C" {
#endif

/* Well-known IDs (see docs/references/usb-cp210x-cdc.md). */
#define RD_VID_SILABS 0x10C4u
#define RD_PID_CP2105 0xEA70u
#define RD_PID_CP2102 0xEA60u
#define RD_VID_FTDI   0x0403u

#define RD_CLASS_CDC_COMM  0x02u
#define RD_SUBCLASS_ACM    0x02u
#define RD_CLASS_CDC_DATA  0x0Au
#define RD_CLASS_VENDOR    0xFFu
#define RD_CLASS_AUDIO     0x01u

/* FT-891: CAT is on the CP2105 Enhanced (ECI) interface — interface #0.
 * UNVERIFIED against a real radio; confirm at bring-up (§7.5 item 1). */
#define RD_FT891_CAT_IFACE 0u

#define RD_DEFAULT_BAUD 4800u /* FT-891 factory default (menu 05-06) */

typedef struct {
    uint8_t number;      /* bInterfaceNumber */
    uint8_t if_class;    /* bInterfaceClass */
    uint8_t if_subclass; /* bInterfaceSubClass */
    uint8_t if_protocol; /* bInterfaceProtocol */
} rd_iface_t;

typedef struct {
    uint16_t vid;
    uint16_t pid;
    const rd_iface_t *ifaces;
    size_t n_ifaces;
    /* True when the device sits behind an external USB hub. The FTX-1
     * presents its CAT chip — a CP2105, same PID as the FT-891 — behind an
     * internal hub, so this is the only signal that tells the two apart
     * (docs/references/yaesu-cat-ftx1.md, confirmed at bring-up). */
    bool via_hub;
} rd_device_t;

typedef enum {
    RD_DRIVER_NONE = 0,
    RD_DRIVER_CP210X,
    RD_DRIVER_CDC_ACM,
    RD_DRIVER_FTDI,
} rd_driver_t;

typedef struct {
    ctrl_radio_id_t radio;
    rd_driver_t driver;
    uint8_t cat_iface;     /* interface number to open for CAT */
    uint32_t default_baud; /* initial line coding; app renegotiates */
} rd_profile_t;

/* Never fails: unknown devices yield CTRL_RADIO_UNSUPPORTED / RD_DRIVER_NONE. */
rd_profile_t radio_detect(const rd_device_t *dev);

#ifdef __cplusplus
}
#endif

#endif /* RADIO_DETECT_H */
