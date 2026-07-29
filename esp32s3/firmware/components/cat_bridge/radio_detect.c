#include "radio_detect.h"

/* First interface satisfying pred-style match, or NULL. */
static const rd_iface_t *find_iface_class(const rd_device_t *dev,
                                          uint8_t if_class)
{
    for (size_t i = 0; i < dev->n_ifaces; i++) {
        if (dev->ifaces[i].if_class == if_class) {
            return &dev->ifaces[i];
        }
    }
    return NULL;
}

static const rd_iface_t *find_cdc_acm_comm(const rd_device_t *dev)
{
    for (size_t i = 0; i < dev->n_ifaces; i++) {
        if (dev->ifaces[i].if_class == RD_CLASS_CDC_COMM &&
            dev->ifaces[i].if_subclass == RD_SUBCLASS_ACM) {
            return &dev->ifaces[i];
        }
    }
    return NULL;
}

rd_profile_t radio_detect(const rd_device_t *dev)
{
    rd_profile_t p = {
        .radio = CTRL_RADIO_UNSUPPORTED,
        .driver = RD_DRIVER_NONE,
        .cat_iface = 0,
        .default_baud = RD_DEFAULT_BAUD,
    };

    /* 1. CP2105 → Yaesu profile on the Enhanced (ECI) interface. The FTX-1
     * carries the same CP2105 behind an internal hub; behind a hub it is an
     * FTX-1 (generic Yaesu, any ID accepted), directly attached it is an
     * FT-891 (exact ID0650). Same chip, same CAT interface, same dialect —
     * only the reported model and the app's ID-probe strictness differ. */
    if (dev->vid == RD_VID_SILABS && dev->pid == RD_PID_CP2105) {
        p.radio = dev->via_hub ? CTRL_RADIO_GENERIC_CP210X
                               : CTRL_RADIO_FT891;
        p.driver = RD_DRIVER_CP210X;
        p.cat_iface = RD_FT891_CAT_IFACE;
        return p;
    }

    /* 2. Other SiLabs CP210x → generic Yaesu profile (FTX-1 candidate).
     * Composite-safe: pick the first vendor-specific interface (CP210x UARTs
     * are class 0xFF), skipping e.g. a UAC audio function. */
    if (dev->vid == RD_VID_SILABS) {
        const rd_iface_t *serial = find_iface_class(dev, RD_CLASS_VENDOR);
        p.radio = CTRL_RADIO_GENERIC_CP210X;
        p.driver = RD_DRIVER_CP210X;
        p.cat_iface = serial ? serial->number : 0;
        return p;
    }

    /* 3. Any CDC-ACM interface → QMX / generic-CDC profile. Class match, not
     * VID/PID: the QMX enumerates as a standard (composite) CDC device. */
    {
        const rd_iface_t *comm = find_cdc_acm_comm(dev);
        if (comm != NULL) {
            p.radio = CTRL_RADIO_QMX_CDC;
            p.driver = RD_DRIVER_CDC_ACM;
            p.cat_iface = comm->number;
            return p;
        }
    }

    /* 4. FTDI → fallback generic profile. */
    if (dev->vid == RD_VID_FTDI) {
        const rd_iface_t *serial = find_iface_class(dev, RD_CLASS_VENDOR);
        p.radio = CTRL_RADIO_GENERIC_FTDI;
        p.driver = RD_DRIVER_FTDI;
        p.cat_iface = serial ? serial->number : 0;
        return p;
    }

    /* 5. Unknown: stay attached, report over CTRL (§5.2). */
    return p;
}
