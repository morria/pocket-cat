#!/usr/bin/env python3
"""radio_sim — CAT radio simulator for hardware-in-the-loop testing
(docs/implementation.md §7.4).

Runs on the test host attached to the ESP32's USB host port through a
CP2105 eval board (FT-891 path), CP2102 breakout (generic path), or a CDC
dev board (QMX path), and emulates each radio's CAT personality with
realistic per-character serial timing and fault injection.

The protocol core (`RadioPersonality` subclasses) is pure — bytes in,
bytes out — so pytest exercises it without any serial hardware.

Usage:
    radio_sim.py --port /dev/ttyUSB0 --radio ft891 --baud 4800
    radio_sim.py --port /dev/ttyUSB0 --radio qmx
    radio_sim.py --port /dev/ttyUSB0 --radio ft891 --fault mute
Faults:
    mute            swallow commands, never respond
    stall:N         emit only N bytes of the next response, then silence
    garbage         prepend a 16-byte binary burst to the next response
    split           release responses in 1-byte writes with 5 ms gaps
"""

from __future__ import annotations

import argparse
import sys
import time


class RadioPersonality:
    """Pure CAT responder: feed() bytes in, collect timed output bytes."""

    #: `ID;` response for this personality
    id_response = b"?;"

    def __init__(self) -> None:
        self._cmd = bytearray()
        self.tx = False  # PTT state
        # fault injection
        self.mute = False
        self.stall_after: int | None = None
        self.garbage_next = False
        # journal of every byte received (for §7.4 CRC/journal checks)
        self.rx_journal = bytearray()

    # -- protocol ----------------------------------------------------------

    def respond(self, cmd: bytes) -> bytes:
        raise NotImplementedError

    def feed(self, data: bytes) -> bytes:
        """Process incoming bytes; return response bytes to send."""
        out = bytearray()
        self.rx_journal += data
        for b in data:
            self._cmd.append(b)
            if b == ord(";"):
                cmd = bytes(self._cmd)
                self._cmd.clear()
                if self.mute:
                    continue
                resp = self.respond(cmd)
                if self.garbage_next and resp:
                    resp = bytes(range(0xF0, 0x100)) + resp
                    self.garbage_next = False
                if self.stall_after is not None:
                    resp = resp[: self.stall_after]
                    self.stall_after = None
                out += resp
            elif len(self._cmd) > 128:
                self._cmd.clear()  # runaway garbage: resync
        return bytes(out)


class Ft891(RadioPersonality):
    """Yaesu FT-891 personality (docs/references/yaesu-cat-ft891.md)."""

    id_response = b"ID0650;"

    def __init__(self) -> None:
        super().__init__()
        self.vfo_a = b"014074000"  # 9 digits, Hz
        self.vfo_b = b"007074000"
        self.mode = b"3"  # CW

    def respond(self, cmd: bytes) -> bytes:  # noqa: C901
        if cmd == b"ID;":
            return self.id_response
        if cmd == b"FA;":
            return b"FA" + self.vfo_a + b";"
        if cmd == b"FB;":
            return b"FB" + self.vfo_b + b";"
        if cmd.startswith(b"FA") and len(cmd) == 12 and cmd[2:11].isdigit():
            self.vfo_a = cmd[2:11]
            return b""
        if cmd.startswith(b"FB") and len(cmd) == 12 and cmd[2:11].isdigit():
            self.vfo_b = cmd[2:11]
            return b""
        if cmd == b"MD0;":
            return b"MD0" + self.mode + b";"
        if cmd.startswith(b"MD0") and len(cmd) == 5:
            self.mode = cmd[3:4]
            return b""
        if cmd == b"IF;":
            # FT-891 27-char IF payload (memch, freq, clar, mode, ...)
            return (b"IF001" + self.vfo_a + b"+0000" + b"00"
                    + self.mode + b"00" + b"000" + b"0;")
        if cmd == b"TX;":
            return b"TX1;" if self.tx else b"TX0;"
        if cmd == b"TX1;":
            self.tx = True
            return b""
        if cmd == b"TX0;":
            self.tx = False
            return b""
        if cmd == b"AI;":
            return b"AI0;"
        if cmd == b"SM0;":
            return b"SM0100;"
        return b"?;"  # Yaesu invalid-command reply


class Ftx1(Ft891):
    """FTX-1: same dialect as FT-891 for simulation purposes; distinct ID
    (placeholder until confirmed at bring-up — references/yaesu-cat-ftx1.md)."""

    id_response = b"ID0800;"

    def respond(self, cmd: bytes) -> bytes:
        if cmd == b"ID;":
            return self.id_response
        return super().respond(cmd)


class Qmx(RadioPersonality):
    """QMX personality: Kenwood TS-480 subset (docs/references/qmx-cat.md)."""

    id_response = b"ID020;"

    def __init__(self) -> None:
        super().__init__()
        self.vfo_a = b"00014074000"  # 11 digits, Hz
        self.vfo_b = b"00007074000"
        self.mode = b"3"

    def respond(self, cmd: bytes) -> bytes:
        if cmd == b"ID;":
            return self.id_response
        if cmd == b"FA;":
            return b"FA" + self.vfo_a + b";"
        if cmd == b"FB;":
            return b"FB" + self.vfo_b + b";"
        if cmd.startswith(b"FA") and len(cmd) == 14 and cmd[2:13].isdigit():
            self.vfo_a = cmd[2:13]
            return b""
        if cmd == b"MD;":
            return b"MD" + self.mode + b";"
        if cmd.startswith(b"MD") and len(cmd) == 4:
            self.mode = cmd[2:3]
            return b""
        if cmd == b"IF;":
            # Kenwood IF: 11-digit freq + fixed-width fields incl. TX flag
            txflag = b"1" if self.tx else b"0"
            return (b"IF" + self.vfo_a + b"     " + b"+0000" + b"0" * 5
                    + txflag + self.mode + b"0000000" + b" ;")
        if cmd == b"TX;":
            self.tx = True
            return b""
        if cmd == b"RX;":
            self.tx = False
            return b""
        return b"?;"


PERSONALITIES = {"ft891": Ft891, "ftx1": Ftx1, "qmx": Qmx}


def apply_fault(radio: RadioPersonality, fault: str | None) -> bool:
    """Returns True if responses should be split byte-wise (timing fault)."""
    if not fault:
        return False
    if fault == "mute":
        radio.mute = True
    elif fault.startswith("stall:"):
        radio.stall_after = int(fault.split(":", 1)[1])
    elif fault == "garbage":
        radio.garbage_next = True
    elif fault == "split":
        return True
    else:
        raise SystemExit(f"unknown fault: {fault}")
    return False


def serve(port: str, radio: RadioPersonality, baud: int,
          split: bool = False) -> None:
    import serial  # lazy: pytest for the core needs no pyserial

    ser = serial.Serial(port, baudrate=baud, timeout=0.05)
    per_char_s = 10.0 / baud  # 8-N-1: 10 bits per char
    print(f"radio_sim: {type(radio).__name__} on {port} @ {baud}")
    try:
        while True:
            data = ser.read(64)
            if not data:
                continue
            resp = radio.feed(data)
            if not resp:
                continue
            if split:
                for i in range(len(resp)):
                    ser.write(resp[i : i + 1])
                    time.sleep(0.005)
            else:
                # emulate serial pacing so the bridge sees realistic timing
                for i in range(0, len(resp), 8):
                    ser.write(resp[i : i + 8])
                    time.sleep(per_char_s * 8)
    except KeyboardInterrupt:
        print(f"\nradio_sim: bye ({len(radio.rx_journal)} bytes journaled)")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", required=True)
    ap.add_argument("--radio", choices=sorted(PERSONALITIES), default="ft891")
    ap.add_argument("--baud", type=int, default=4800)
    ap.add_argument("--fault", default=None)
    args = ap.parse_args()

    radio = PERSONALITIES[args.radio]()
    split = apply_fault(radio, args.fault)
    serve(args.port, radio, args.baud, split)


if __name__ == "__main__":
    sys.exit(main())
