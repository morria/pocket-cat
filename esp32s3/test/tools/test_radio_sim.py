"""pytest suite for radio_sim: personality cores (pure) + a real serial
round-trip through a pty pair (no hardware required)."""

import os
import pty
import threading
import time

import pytest

from radio_sim import Ft891, Ftx1, Qmx, apply_fault, serve


# --- FT-891 personality -----------------------------------------------------

def test_ft891_id():
    assert Ft891().feed(b"ID;") == b"ID0650;"


def test_ft891_freq_set_get():
    r = Ft891()
    assert r.feed(b"FA;") == b"FA014074000;"
    assert r.feed(b"FA014250000;") == b""  # set: no reply
    assert r.feed(b"FA;") == b"FA014250000;"


def test_ft891_mode():
    r = Ft891()
    assert r.feed(b"MD0;") == b"MD03;"
    assert r.feed(b"MD02;") == b""
    assert r.feed(b"MD0;") == b"MD02;"


def test_ft891_ptt():
    r = Ft891()
    assert r.feed(b"TX;") == b"TX0;"
    r.feed(b"TX1;")
    assert r.tx is True
    assert r.feed(b"TX;") == b"TX1;"
    r.feed(b"TX0;")
    assert r.tx is False


def test_ft891_invalid_command():
    assert Ft891().feed(b"ZZ99;") == b"?;"


def test_ft891_if_contains_freq_and_terminator():
    r = Ft891()
    resp = r.feed(b"IF;")
    assert resp.startswith(b"IF")
    assert resp.endswith(b";")
    assert b"014074000" in resp


def test_ft891_split_command_across_feeds():
    r = Ft891()
    assert r.feed(b"F") == b""
    assert r.feed(b"A") == b""
    assert r.feed(b";") == b"FA014074000;"


def test_ft891_multiple_commands_one_feed():
    r = Ft891()
    resp = r.feed(b"ID;FA;TX;")
    assert resp == b"ID0650;FA014074000;TX0;"


def test_journal_records_everything():
    r = Ft891()
    r.feed(b"ID;")
    r.feed(b"FA;")
    assert bytes(r.rx_journal) == b"ID;FA;"


def test_runaway_garbage_resync():
    r = Ft891()
    assert r.feed(b"\x00" * 300) == b""  # no ';' — buffer bounded, no crash
    # Like a real Yaesu, the residual garbage corrupts the FIRST command
    # (→ "?;", resyncing on its ';'), after which the link is clean again.
    assert r.feed(b"ID;") == b"?;"
    assert r.feed(b"ID;") == b"ID0650;"


# --- FTX-1 ------------------------------------------------------------------

def test_ftx1_distinct_id_same_dialect():
    r = Ftx1()
    assert r.feed(b"ID;") == b"ID0800;"
    assert r.feed(b"FA;") == b"FA014074000;"


# --- QMX (Kenwood dialect) --------------------------------------------------

def test_qmx_id():
    assert Qmx().feed(b"ID;") == b"ID020;"


def test_qmx_kenwood_11_digit_freq():
    r = Qmx()
    assert r.feed(b"FA;") == b"FA00014074000;"
    assert r.feed(b"FA00007074000;") == b""
    assert r.feed(b"FA;") == b"FA00007074000;"


def test_qmx_ptt_tx_rx_semantics():
    r = Qmx()
    r.feed(b"TX;")  # Kenwood: TX; keys (no argument)
    assert r.tx is True
    r.feed(b"RX;")
    assert r.tx is False


def test_qmx_if_reflects_tx_state():
    r = Qmx()
    rx_if = r.feed(b"IF;")
    r.feed(b"TX;")
    tx_if = r.feed(b"IF;")
    assert rx_if != tx_if
    assert rx_if.startswith(b"IF00014074000")


# --- fault injection --------------------------------------------------------

def test_fault_mute():
    r = Ft891()
    apply_fault(r, "mute")
    assert r.feed(b"ID;") == b""
    assert bytes(r.rx_journal) == b"ID;"  # still journaled


def test_fault_stall():
    r = Ft891()
    apply_fault(r, "stall:3")
    assert r.feed(b"ID;") == b"ID0"  # partial then silence
    assert r.feed(b"ID;") == b"ID0650;"  # one-shot


def test_fault_garbage():
    r = Ft891()
    apply_fault(r, "garbage")
    resp = r.feed(b"ID;")
    assert resp.endswith(b"ID0650;")
    assert len(resp) == 16 + 7


def test_fault_split_flag():
    assert apply_fault(Ft891(), "split") is True
    assert apply_fault(Ft891(), None) is False


def test_fault_unknown_rejected():
    with pytest.raises(SystemExit):
        apply_fault(Ft891(), "no-such-fault")


# --- end-to-end through a real serial device (pty pair) ---------------------

@pytest.mark.timeout(10)
def test_serve_over_pty_roundtrip():
    """Run serve() on a pty slave; talk to it from the master like the
    ESP32 would talk over the CP210x — a true serial round-trip."""
    master_fd, slave_fd = pty.openpty()
    slave_name = os.ttyname(slave_fd)
    radio = Ft891()
    t = threading.Thread(target=serve, args=(slave_name, radio, 38400),
                         daemon=True)
    t.start()
    time.sleep(0.3)  # let serve() open the port

    def command(cmd: bytes, expect_reply: bool = True) -> bytes:
        os.write(master_fd, cmd)
        buf = b""
        deadline = time.monotonic() + 3.0
        while expect_reply and not buf.endswith(b";"):
            if time.monotonic() > deadline:
                raise TimeoutError(f"no reply to {cmd!r}: {buf!r}")
            try:
                buf += os.read(master_fd, 64)
            except BlockingIOError:
                time.sleep(0.01)
        return buf

    assert command(b"ID;") == b"ID0650;"
    assert command(b"FA;") == b"FA014074000;"
    os.write(master_fd, b"FA014250000;")  # set, no reply
    assert command(b"FA;") == b"FA014250000;"
    os.close(master_fd)


# --- power / settings / menu (references: yaesu-cat-ft891.md, qmx-cat.md) ---

def test_ft891_power_read_set():
    r = Ft891()
    assert r.feed(b"PC;") == b"PC100;"
    assert r.feed(b"PC050;") == b""
    assert r.feed(b"PC;") == b"PC050;"


def test_ft891_settings_read_set():
    r = Ft891()
    assert r.feed(b"AG0;") == b"AG0128;"
    assert r.feed(b"AG0200;") == b""
    assert r.feed(b"AG0;") == b"AG0200;"
    assert r.feed(b"KS;") == b"KS020;"
    assert r.feed(b"BI1;") == b""
    assert r.feed(b"BI;") == b"BI1;"
    assert r.feed(b"SH0;") == b"SH012;"


def test_ft891_menu_read_set_unknown():
    r = Ft891()
    assert r.feed(b"EX0301;") == b"EX03015;"
    assert r.feed(b"EX03017;") == b""
    assert r.feed(b"EX0301;") == b"EX03017;"
    assert r.feed(b"EX9999;") == b"?;"


def test_qmx_power_getonly_smeter_keyer():
    r = Qmx()
    assert r.feed(b"PC;") == b"PC45;"  # tenths of a watt (4.5 W)
    assert r.feed(b"PC100;") == b"?;"  # GET-only (cat_1_02_006)
    assert r.feed(b"SM;") == b"SM12;"  # S-meter in dB
    assert r.feed(b"KS;") == b"KS020;"
    assert r.feed(b"KS025;") == b""
    assert r.feed(b"KS;") == b"KS025;"


def test_qmx_mode_subset():
    r = Qmx()
    assert r.feed(b"MD3;") == b""
    assert r.feed(b"MD;") == b"MD3;"
    assert r.feed(b"MD2;") == b"?;"  # no USB/LSB via MD on QMX
    assert r.feed(b"MD6;") == b""
