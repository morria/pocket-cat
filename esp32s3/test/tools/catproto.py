"""catproto — shared BLE control-protocol codec for the CAT bridge test tools.

Mirrors firmware/components/ctrl_proto/include/ctrl_proto.h exactly
(docs/implementation.md §4.1). Keep the two in sync; the pytest suite
cross-checks known vectors.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass
from enum import IntEnum

# --- Service / characteristic UUIDs (docs/protocol.md) ---------------------
# Project 128-bit base: 8f1dXXXX-52a4-4e1e-b34b-9d40b71d6e01. These literals
# are the source of truth shared with the firmware (ble_link.c).
SVC_UUID = "8f1d0001-52a4-4e1e-b34b-9d40b71d6e01"
CHAR_CAT_RX = "8f1d0002-52a4-4e1e-b34b-9d40b71d6e01"  # central→radio (write)
CHAR_CAT_TX = "8f1d0003-52a4-4e1e-b34b-9d40b71d6e01"  # radio→central (notify)
CHAR_CTRL = "8f1d0004-52a4-4e1e-b34b-9d40b71d6e01"    # control TLV (wr+notify)
CHAR_STATUS = "8f1d0005-52a4-4e1e-b34b-9d40b71d6e01"  # status (read+notify)


class Op(IntEnum):
    SET_BAUD = 0x01
    GET_STATUS = 0x02
    USB_RESET = 0x03
    SET_LINE = 0x04
    PURGE = 0x05
    SET_FAILSAFE = 0x06
    ACK = 0x80
    NAK = 0x81
    EVT_USB = 0x82
    EVT_OVERFLOW = 0x83


class Err(IntEnum):
    OK = 0x00
    BAD_LEN = 0x01
    BAD_ARG = 0x02
    NO_USB = 0x03
    UNSUPPORTED = 0x04
    BUSY = 0x05
    UNKNOWN_OP = 0x06


class UsbState(IntEnum):
    WAITING = 0
    ENUMERATED = 1
    ERROR = 2


class RadioId(IntEnum):
    NONE = 0
    FT891 = 1
    GENERIC_CP210X = 2
    QMX_CDC = 3
    GENERIC_FTDI = 4
    UNSUPPORTED = 5


PURGE_USB_TO_BLE = 0x01
PURGE_BLE_TO_USB = 0x02
LINE_DTR = 0x01
LINE_RTS = 0x02
FAILSAFE_MAX = 32
STATUS_FMT_VERSION = 1
STATUS_SIZE = 22


@dataclass
class Frame:
    op: int
    payload: bytes

    def encode(self) -> bytes:
        if len(self.payload) > 255:
            raise ValueError("payload too long")
        return bytes([self.op, len(self.payload)]) + self.payload


def encode(op: int, payload: bytes = b"") -> bytes:
    return Frame(op, payload).encode()


def decode_stream(buf: bytes) -> tuple[list[Frame], bytes]:
    """Decode all complete frames from buf; return (frames, remainder)."""
    frames: list[Frame] = []
    off = 0
    while len(buf) - off >= 2:
        length = buf[off + 1]
        if len(buf) - off < 2 + length:
            break
        frames.append(Frame(buf[off], bytes(buf[off + 2 : off + 2 + length])))
        off += 2 + length
    return frames, bytes(buf[off:])


# --- Command constructors ---------------------------------------------------

def set_baud(baud: int) -> bytes:
    return encode(Op.SET_BAUD, struct.pack("<I", baud))


def get_status() -> bytes:
    return encode(Op.GET_STATUS)


def usb_reset() -> bytes:
    return encode(Op.USB_RESET)


def set_line(dtr: bool = False, rts: bool = False) -> bytes:
    return encode(Op.SET_LINE,
                  bytes([(LINE_DTR if dtr else 0) | (LINE_RTS if rts else 0)]))


def purge(usb_to_ble: bool = False, ble_to_usb: bool = False) -> bytes:
    mask = (PURGE_USB_TO_BLE if usb_to_ble else 0) | (
        PURGE_BLE_TO_USB if ble_to_usb else 0)
    return encode(Op.PURGE, bytes([mask]))


def set_failsafe(data: bytes) -> bytes:
    if len(data) > FAILSAFE_MAX:
        raise ValueError(f"failsafe limited to {FAILSAFE_MAX} bytes")
    return encode(Op.SET_FAILSAFE, data)


# --- STATUS decode ----------------------------------------------------------

@dataclass
class Status:
    usb_state: UsbState
    radio_id: RadioId
    baud: int
    drops_usb_to_ble: int
    drops_ble_to_usb: int
    fw_major: int
    fw_minor: int
    reset_reason: int
    min_free_heap: int

    @classmethod
    def decode(cls, data: bytes) -> "Status":
        if len(data) < STATUS_SIZE:
            raise ValueError(f"status too short: {len(data)}")
        if data[0] != STATUS_FMT_VERSION:
            raise ValueError(f"unknown status version {data[0]}")
        (usb_state, radio_id) = data[1], data[2]
        (baud, d_u2b, d_b2u) = struct.unpack_from("<III", data, 3)
        (fw_major, fw_minor, reset_reason) = data[15], data[16], data[17]
        (min_free_heap,) = struct.unpack_from("<I", data, 18)
        return cls(UsbState(usb_state), RadioId(radio_id), baud, d_u2b,
                   d_b2u, fw_major, fw_minor, reset_reason, min_free_heap)
