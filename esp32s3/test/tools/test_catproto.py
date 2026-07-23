"""pytest suite for catproto — including wire-format vectors that must match
the C implementation (ctrl_proto.c) byte for byte."""

import struct

import pytest

import catproto as cp


def test_encode_set_baud_vector():
    # Must match ctrl_encode(CTRL_OP_SET_BAUD, u32le) in C.
    assert cp.set_baud(38400) == bytes([0x01, 4, 0x00, 0x96, 0x00, 0x00])
    assert cp.set_baud(4800) == bytes([0x01, 4, 0xC0, 0x12, 0x00, 0x00])


def test_encode_get_status_vector():
    assert cp.get_status() == bytes([0x02, 0])


def test_encode_set_line():
    assert cp.set_line(dtr=True) == bytes([0x04, 1, 0x01])
    assert cp.set_line(rts=True) == bytes([0x04, 1, 0x02])
    assert cp.set_line(dtr=True, rts=True) == bytes([0x04, 1, 0x03])


def test_encode_purge():
    assert cp.purge(usb_to_ble=True) == bytes([0x05, 1, 0x01])
    assert cp.purge(ble_to_usb=True) == bytes([0x05, 1, 0x02])


def test_encode_failsafe():
    assert cp.set_failsafe(b"TX0;") == bytes([0x06, 4]) + b"TX0;"
    assert cp.set_failsafe(b"") == bytes([0x06, 0])  # disarm
    with pytest.raises(ValueError):
        cp.set_failsafe(b"x" * 33)


def test_decode_stream_complete_and_partial():
    ack = bytes([0x80, 2, 0x01, 0x00])
    evt = bytes([0x82, 2, 0x01, 0x01])
    partial = bytes([0x83, 5, 0x00])  # EVT_OVERFLOW missing 3 bytes
    frames, rest = cp.decode_stream(ack + evt + partial)
    assert [f.op for f in frames] == [cp.Op.ACK, cp.Op.EVT_USB]
    assert frames[0].payload == bytes([0x01, 0x00])
    assert rest == partial
    # feeding the remainder later completes the frame (payload: which=0x00
    # already buffered + dropped u32le)
    frames2, rest2 = cp.decode_stream(rest + struct.pack("<I", 0x0001_002A))
    assert len(frames2) == 1 and frames2[0].op == cp.Op.EVT_OVERFLOW
    assert frames2[0].payload == bytes([0x00]) + struct.pack("<I", 0x0001_002A)
    assert rest2 == b""


def test_decode_stream_empty_and_garbage():
    frames, rest = cp.decode_stream(b"")
    assert frames == [] and rest == b""
    frames, rest = cp.decode_stream(bytes([0x42]))  # opcode only
    assert frames == [] and rest == bytes([0x42])


def test_status_decode_vector():
    # Byte-exact vector mirroring ctrl_status_encode() in C:
    # ver=1, usb=ENUMERATED, radio=FT891, baud=38400, drops=17/3,
    # fw=0.1, reset=2, heap=123456
    wire = bytes([1, 1, 1]) + struct.pack("<III", 38400, 17, 3) \
        + bytes([0, 1, 2]) + struct.pack("<I", 123456)
    assert len(wire) == cp.STATUS_SIZE
    st = cp.Status.decode(wire)
    assert st.usb_state == cp.UsbState.ENUMERATED
    assert st.radio_id == cp.RadioId.FT891
    assert st.baud == 38400
    assert st.drops_usb_to_ble == 17
    assert st.drops_ble_to_usb == 3
    assert (st.fw_major, st.fw_minor) == (0, 1)
    assert st.reset_reason == 2
    assert st.min_free_heap == 123456


def test_status_decode_rejects_bad():
    with pytest.raises(ValueError):
        cp.Status.decode(b"\x01" + b"\x00" * 5)  # short
    with pytest.raises(ValueError):
        cp.Status.decode(b"\x63" + b"\x00" * (cp.STATUS_SIZE - 1))  # bad ver


def test_frame_roundtrip():
    for op in cp.Op:
        for payload in (b"", b"x", bytes(range(255))):
            wire = cp.encode(op, payload)
            frames, rest = cp.decode_stream(wire)
            assert rest == b""
            assert len(frames) == 1
            assert frames[0].op == op
            assert frames[0].payload == payload


def test_uuid_shape():
    for u in (cp.SVC_UUID, cp.CHAR_CAT_RX, cp.CHAR_CAT_TX, cp.CHAR_CTRL,
              cp.CHAR_STATUS):
        parts = u.split("-")
        assert [len(p) for p in parts] == [8, 4, 4, 4, 12]
        int(u.replace("-", ""), 16)  # all hex
    # 4 distinct characteristic UUIDs under one service
    assert len({cp.SVC_UUID, cp.CHAR_CAT_RX, cp.CHAR_CAT_TX, cp.CHAR_CTRL,
                cp.CHAR_STATUS}) == 5
