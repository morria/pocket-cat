"""pytest suite for catproto — including wire-format vectors that must match
the C implementation (ctrl_proto.c) byte for byte.

The golden vectors live in esp32s3/test/vectors/ctrlproto.json (single source
of truth, also embedded in the Swift package and byte-compared in CI)."""

import json
import pathlib
import struct

import pytest

import catproto as cp

VECTORS = json.loads(
    (pathlib.Path(__file__).parent.parent / "vectors" / "ctrlproto.json")
    .read_text())

# name → encoder producing the frame bytes, mirroring the JSON "frames" list.
FRAME_ENCODERS = {
    "set_baud_38400": lambda: cp.set_baud(38400),
    "set_baud_4800": lambda: cp.set_baud(4800),
    "get_status": cp.get_status,
    "usb_reset": cp.usb_reset,
    "set_line_dtr": lambda: cp.set_line(dtr=True),
    "set_line_rts": lambda: cp.set_line(rts=True),
    "set_line_both": lambda: cp.set_line(dtr=True, rts=True),
    "purge_usb_to_ble": lambda: cp.purge(usb_to_ble=True),
    "purge_ble_to_usb": lambda: cp.purge(ble_to_usb=True),
    "set_failsafe_tx0": lambda: cp.set_failsafe(b"TX0;"),
    "set_failsafe_rx": lambda: cp.set_failsafe(b"RX;"),
    "set_failsafe_disarm": lambda: cp.set_failsafe(b""),
    "set_spectrum_on_256_15": lambda: cp.set_spectrum(True, 256, 15),
    "set_spectrum_off": lambda: cp.set_spectrum(False, 0, 1),
}


@pytest.mark.parametrize("vec", VECTORS["frames"], ids=lambda v: v["name"])
def test_frame_vectors(vec):
    wire = bytes.fromhex(vec["wire_hex"])
    # Structural invariants for every vector.
    assert wire[0] == vec["op"]
    assert wire[2:] == bytes.fromhex(vec["payload_hex"])
    assert wire[1] == len(wire) - 2
    # Round-trips through the decoder.
    frames, rest = cp.decode_stream(wire)
    assert rest == b"" and len(frames) == 1
    assert frames[0].op == vec["op"]
    # Encoder vectors: our encoder must produce the exact bytes.
    if vec["name"] in FRAME_ENCODERS:
        assert FRAME_ENCODERS[vec["name"]]() == wire


@pytest.mark.parametrize("vec", VECTORS["status"], ids=lambda v: v["name"])
def test_status_vectors(vec):
    st = cp.Status.decode(bytes.fromhex(vec["wire_hex"]))
    d = vec["decoded"]
    assert st.usb_state == d["usb_state"]
    assert st.radio_id == d["radio_id"]
    assert st.baud == d["baud"]
    assert st.drops_usb_to_ble == d["drops_usb_to_ble"]
    assert st.drops_ble_to_usb == d["drops_ble_to_usb"]
    assert (st.fw_major, st.fw_minor) == (d["fw_major"], d["fw_minor"])
    assert st.reset_reason == d["reset_reason"]
    assert st.min_free_heap == d["min_free_heap"]


@pytest.mark.parametrize("vec", VECTORS["invalid_status"],
                         ids=lambda v: v["name"])
def test_invalid_status_vectors(vec):
    with pytest.raises(ValueError):
        cp.Status.decode(bytes.fromhex(vec["wire_hex"]))


def test_all_encoders_have_vectors():
    names = {v["name"] for v in VECTORS["frames"]}
    assert set(FRAME_ENCODERS) <= names


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


# --- Spectrum frame vectors (docs/qmx-panadapter.md 3.3) --------------------

@pytest.mark.parametrize("vec", VECTORS["spectrum_frames"],
                         ids=lambda v: v["name"])
def test_spectrum_frame_vectors(vec):
    r = cp.SpectrumReassembler()
    frame = None
    for frag_hex in vec["fragments_hex"]:
        frame = r.ingest(bytes.fromhex(frag_hex))
    assert frame is not None
    assert frame.sequence == vec["sequence"]
    assert frame.sample_rate_hz == vec["sample_rate_hz"]
    assert frame.bins == bytes.fromhex(vec["bins_hex"])
    assert len(frame.bins) == vec["bins_total"]
    assert r.frames_dropped == 0


def test_spectrum_missing_fragment_drops_then_recovers():
    vec = next(v for v in VECTORS["spectrum_frames"]
               if len(v["fragments_hex"]) > 1)
    frags = [bytes.fromhex(h) for h in vec["fragments_hex"]]
    r = cp.SpectrumReassembler()
    assert r.ingest(frags[0]) is None
    # New frame's frag 0 resets the pending one.
    assert r.ingest(frags[0]) is None
    for frag in frags[1:]:
        result = r.ingest(frag)
    assert result is not None
    assert r.frames_dropped == 1
