#!/usr/bin/env python3
"""ble_client — bleak-based reference client + BLE integration test driver
(docs/implementation.md §7.3). Doubles as the reference implementation of
the iOS app's transport layer.

Requires: pip install bleak   (and a BLE adapter on the test host)

Usage:
    ble_client.py scan
    ble_client.py status
    ble_client.py cat "FA;"                 # send one CAT command, print reply
    ble_client.py baud 38400
    ble_client.py failsafe "TX0;"
    ble_client.py echo --bytes 100000       # throughput/loss vs loopback rig
    ble_client.py storm --cycles 50         # connect/disconnect stress
"""

from __future__ import annotations

import argparse
import asyncio
import sys
import time

import catproto as cp

DEVICE_NAME_PREFIX = "CATBridge"
CAT_TIMEOUT_S = 0.5


class BridgeClient:
    """Async wrapper around one BLE connection to the bridge."""

    def __init__(self, address: str | None = None) -> None:
        self.address = address
        self.client = None
        self.cat_rx = bytearray()
        self.ctrl_rx = bytearray()
        self.ctrl_frames: list[cp.Frame] = []
        self.status: cp.Status | None = None
        self._cat_event = asyncio.Event()
        self._ctrl_event = asyncio.Event()

    async def discover(self) -> str:
        from bleak import BleakScanner

        dev = await BleakScanner.find_device_by_filter(
            lambda d, ad: cp.SVC_UUID.lower() in
            [u.lower() for u in (ad.service_uuids or [])]
            or (d.name or "").startswith(DEVICE_NAME_PREFIX),
            timeout=10.0,
        )
        if dev is None:
            raise RuntimeError("bridge not found (is it advertising?)")
        self.address = dev.address
        return dev.address

    async def __aenter__(self) -> "BridgeClient":
        from bleak import BleakClient

        if self.address is None:
            await self.discover()
        self.client = BleakClient(self.address)
        await self.client.__aenter__()
        await self.client.start_notify(cp.CHAR_CAT_TX, self._on_cat)
        await self.client.start_notify(cp.CHAR_CTRL, self._on_ctrl)
        await self.client.start_notify(cp.CHAR_STATUS, self._on_status)
        return self

    async def __aexit__(self, *exc) -> None:
        await self.client.__aexit__(*exc)

    # -- notification handlers --------------------------------------------

    def _on_cat(self, _h, data: bytearray) -> None:
        self.cat_rx += data
        self._cat_event.set()

    def _on_ctrl(self, _h, data: bytearray) -> None:
        self.ctrl_rx += data
        frames, rest = cp.decode_stream(bytes(self.ctrl_rx))
        self.ctrl_frames += frames
        self.ctrl_rx = bytearray(rest)
        if frames:
            self._ctrl_event.set()

    def _on_status(self, _h, data: bytearray) -> None:
        self.status = cp.Status.decode(bytes(data))

    # -- operations ---------------------------------------------------------

    async def cat_write(self, data: bytes) -> None:
        await self.client.write_gatt_char(cp.CHAR_CAT_RX, data, response=False)

    async def cat_command(self, cmd: str, timeout: float = CAT_TIMEOUT_S) -> bytes:
        """Send one ';'-terminated command; return bytes up to the next ';'."""
        self.cat_rx.clear()
        self._cat_event.clear()
        await self.cat_write(cmd.encode())
        deadline = time.monotonic() + timeout
        while b";" not in self.cat_rx:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"no reply to {cmd!r}")
            try:
                await asyncio.wait_for(self._cat_event.wait(), remaining)
            except asyncio.TimeoutError:
                raise TimeoutError(f"no reply to {cmd!r}") from None
            self._cat_event.clear()
        return bytes(self.cat_rx)

    async def ctrl_command(self, frame: bytes,
                           timeout: float = 1.0) -> cp.Frame:
        """Send a CTRL frame; return its single reply frame (§4.1)."""
        want_op = frame[0]
        n_before = len(self.ctrl_frames)
        self._ctrl_event.clear()
        await self.client.write_gatt_char(cp.CHAR_CTRL, frame, response=True)
        deadline = time.monotonic() + timeout
        while True:
            for f in self.ctrl_frames[n_before:]:
                if f.op in (cp.Op.ACK, cp.Op.NAK) and f.payload[0] == want_op:
                    return f
                if f.op == want_op:  # GET_STATUS answers with its own opcode
                    return f
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"no ACK/NAK for op 0x{want_op:02x}")
            try:
                await asyncio.wait_for(self._ctrl_event.wait(), remaining)
            except asyncio.TimeoutError:
                raise TimeoutError(f"no ACK/NAK for op 0x{want_op:02x}") from None
            self._ctrl_event.clear()

    async def read_status(self) -> cp.Status:
        reply = await self.ctrl_command(cp.get_status())
        if reply.op != cp.Op.GET_STATUS:
            raise RuntimeError(f"unexpected reply {reply}")
        return cp.Status.decode(reply.payload)


# --- subcommands ------------------------------------------------------------

async def cmd_scan(_args) -> int:
    from bleak import BleakScanner

    print("scanning 10 s ...")
    for d in await BleakScanner.discover(timeout=10.0):
        print(f"  {d.address}  rssi={getattr(d, 'rssi', '?'):>4}  {d.name}")
    return 0


async def cmd_status(args) -> int:
    async with BridgeClient(args.address) as bc:
        st = await bc.read_status()
        print(st)
    return 0


async def cmd_cat(args) -> int:
    async with BridgeClient(args.address) as bc:
        reply = await bc.cat_command(args.command)
        print(reply.decode(errors="replace"))
    return 0


async def cmd_baud(args) -> int:
    async with BridgeClient(args.address) as bc:
        reply = await bc.ctrl_command(cp.set_baud(args.baud))
        ok = reply.op == cp.Op.ACK
        print("ACK" if ok else f"NAK err={cp.Err(reply.payload[1]).name}")
        return 0 if ok else 1


async def cmd_failsafe(args) -> int:
    async with BridgeClient(args.address) as bc:
        reply = await bc.ctrl_command(cp.set_failsafe(args.string.encode()))
        print("ACK" if reply.op == cp.Op.ACK else "NAK")
    return 0


async def cmd_echo(args) -> int:
    """Throughput/loss test against the loopback or radio_sim rig."""
    async with BridgeClient(args.address) as bc:
        payload = bytes(i & 0xFF for i in range(args.bytes))
        bc.cat_rx.clear()
        t0 = time.monotonic()
        for off in range(0, len(payload), args.chunk):
            await bc.cat_write(payload[off : off + args.chunk])
        while len(bc.cat_rx) < len(payload):
            before = len(bc.cat_rx)
            await asyncio.sleep(0.5)
            if len(bc.cat_rx) == before:
                break  # stalled
        dt = time.monotonic() - t0
        got = bytes(bc.cat_rx)
        lost = len(payload) - len(got)
        intact = got == payload[: len(got)]
        print(f"sent={len(payload)} recv={len(got)} lost={lost} "
              f"intact={intact} goodput={len(got) / dt:.0f} B/s")
        return 0 if lost == 0 and intact else 1


async def cmd_spectrum(args) -> int:
    """Panadapter bench view (docs/qmx-panadapter.md M2): enable the
    stream and print one ASCII trace line per frame."""
    async with BridgeClient(args.address) as bc:
        frames: list[cp.SpectrumFrame] = []
        reasm = cp.SpectrumReassembler()

        def on_spectrum(_h, data: bytearray) -> None:
            frame = reasm.ingest(bytes(data))
            if frame:
                frames.append(frame)

        await bc.client.start_notify(cp.CHAR_SPECTRUM, on_spectrum)
        reply = await bc.ctrl_command(
            cp.set_spectrum(True, args.bins, args.fps))
        if reply.op != cp.Op.ACK:
            print(f"NAK err={cp.Err(reply.payload[1]).name} "
                  "(old firmware or bad args?)")
            return 1
        deadline = time.monotonic() + args.seconds
        shown = 0
        glyphs = " .:-=+*#%@"
        try:
            while time.monotonic() < deadline:
                await asyncio.sleep(0.05)
                while shown < len(frames):
                    frame = frames[shown]
                    shown += 1
                    step = max(1, len(frame.bins) // 64)
                    row = "".join(
                        glyphs[min(9, (255 - frame.bins[i]) // 26)]
                        for i in range(0, len(frame.bins), step))
                    print(f"{frame.sequence:3d} |{row}|")
        finally:
            await bc.ctrl_command(cp.set_spectrum(False))
        lost = reasm.sequence_gaps + reasm.frames_dropped
        print(f"frames={shown} lost={lost}")
        return 0 if shown else 1


async def cmd_storm(args) -> int:
    """Connect/disconnect cycles; §7.3 requires advertising resume ≤ 2 s."""
    addr = args.address
    for i in range(args.cycles):
        t0 = time.monotonic()
        async with BridgeClient(addr) as bc:
            addr = bc.address  # reuse discovered addr for speed
            await bc.read_status()
        print(f"cycle {i + 1}/{args.cycles}: {time.monotonic() - t0:.2f}s")
    print("storm complete")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--address", default=None, help="BLE address (else scan)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("scan")
    sub.add_parser("status")
    p = sub.add_parser("cat")
    p.add_argument("command")
    p = sub.add_parser("baud")
    p.add_argument("baud", type=int)
    p = sub.add_parser("failsafe")
    p.add_argument("string")
    p = sub.add_parser("echo")
    p.add_argument("--bytes", type=int, default=100_000)
    p.add_argument("--chunk", type=int, default=180)
    p = sub.add_parser("spectrum")
    p.add_argument("--bins", type=int, default=256)
    p.add_argument("--fps", type=int, default=15)
    p.add_argument("--seconds", type=float, default=5.0)
    p = sub.add_parser("storm")
    p.add_argument("--cycles", type=int, default=50)
    args = ap.parse_args()

    handler = globals()[f"cmd_{args.cmd}"]
    return asyncio.run(handler(args))


if __name__ == "__main__":
    sys.exit(main())
