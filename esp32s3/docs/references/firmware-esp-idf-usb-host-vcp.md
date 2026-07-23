# ESP-IDF USB Host + VCP Drivers — Firmware Reference

How the `usb_link` component drives the radio's serial interface. Targets
**ESP-IDF ≥ 5.2** and the Espressif **`esp-usb`** component registry.

> Sources: ESP-IDF USB Host Library docs (`docs.espressif.com`), `esp-usb`
> repo (`github.com/espressif/esp-usb`) and its `usb_host_vcp` /
> `usb_host_cp210x` / `usb_host_cdc_acm` / `usb_host_ftdi_sio` components on
> `components.espressif.com`. Registry/docs are egress-blocked here; pin exact
> versions from `idf_component.yml` at build time.

## Components (add to `main/idf_component.yml`)

```yaml
dependencies:
  espressif/usb_host_vcp: "^1"        # unified VCP interface (open-by-any)
  espressif/usb_host_cp210x: "^2"     # Silicon Labs CP210x (FT-891/FTX-1)
  espressif/usb_host_cdc_acm: "^2"    # CDC-ACM (QMX / generic)
  espressif/usb_host_ftdi: "^1"       # FTDI fallback (optional)
```

`usb_host_vcp` gives a `VCP::open()` that probes registered drivers by
descriptor and returns a `CdcAcmDevice`-style handle, so the datapath is
driver-agnostic. For explicit per-radio control (interface index, vendor
requests) the concrete `cp210x`/`cdc_acm` APIs are used directly.

## sdkconfig essentials

```
CONFIG_ESP_CONSOLE_UART_DEFAULT=y        # console on UART0 (native USB is host)
CONFIG_USB_HOST_CONTROL_TRANSFER_MAX_SIZE=256
CONFIG_FREERTOS_HZ=1000                   # 1 ms tick for tight flush timing
# NimBLE (see firmware-nimble-ble.md)
CONFIG_BT_ENABLED=y
CONFIG_BT_NIMBLE_ENABLED=y
```

## Host-library lifecycle

```c
// 1. Install the host library (usually in its own task)
usb_host_config_t host_cfg = { .intr_flags = ESP_INTR_FLAG_LEVEL1 };
usb_host_install(&host_cfg);

// 2. Daemon task: pump events + free devices
while (run) {
    uint32_t flags;
    usb_host_lib_handle_events(portMAX_DELAY, &flags);
    if (flags & USB_HOST_LIB_EVENT_FLAGS_NO_CLIENTS) usb_host_device_free_all();
}

// 3. Register the VCP client; on NEW_DEV, match descriptor → open driver
//    On connect: read device+config descriptors, run the radio-detect table,
//    open the CAT interface, apply default line coding, emit EVT_USB(enumerated).
```

Key APIs: `usb_host_install/uninstall`, `usb_host_client_register`,
`usb_host_lib_handle_events`, `usb_host_client_handle_events`,
`usb_host_device_open/close`, `usb_host_get_device_descriptor`,
`usb_host_get_active_config_descriptor`, `usb_host_device_free_all`.

## VCP receive → ring buffer (datapath in)

The VCP drivers deliver RX bytes via a callback in USB-driver task context.
**Do only a bounded copy into `rb_usb_to_ble`** — no parsing, no BLE calls:

```c
bool rx_cb(const uint8_t *data, size_t len, void *arg) {
    ring_write_drop_newest(&rb_usb_to_ble, data, len);  // counts drops (§5.4)
    return true;   // buffer consumed
}
```

## Line coding / control (maps to bridge CTRL opcodes)

```c
cdc_acm_line_coding_t lc = { .dwDTERate = baud, .bDataBits = 8,
                             .bParityType = 0, .bCharFormat = 0 };
vcp->line_coding_set(&lc);          // SET_BAUD  → SET_LINE_CODING / CP210x vendor
vcp->set_control_line_state(dtr,rts); // SET_LINE  → DTR/RTS
```

Wrap in the `usb_link` API so the bridge calls one function regardless of chip
(see `usb-cp210x-cdc.md` control-transfer table).

## Disconnect / recovery

- On `USB_HOST_CLIENT_EVENT_DEV_GONE`: **first flush the armed `SET_FAILSAFE`
  bytes if a BLE peer just dropped**, then close the driver, purge rings, emit
  `EVT_USB(detached)`, and return the daemon to waiting. Re-attach is automatic.
- On transfer error/stall/babble: one automatic port reset + re-enumerate; back
  off after 3 failures in 10 s and report `USB_ERROR` (LED fast-blink).
- Never block the host-lib event task; all heavy work is on the bridge task.

## Reference examples to mirror

- `esp-usb` → `host/class/cdc/usb_host_vcp` example (open-by-any + echo).
- `esp-idf` → `examples/peripherals/usb/host/cdc` (raw CDC-ACM lifecycle).
- Espressif "USB Host CDC" and "VCP" how-tos in the USB Host docs.
