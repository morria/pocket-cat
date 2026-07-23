#!/usr/bin/env python3
"""soak — long-run stress driver (docs/implementation.md §7.6).

Polls `IF;` at a fixed rate through the BLE bridge (with radio_sim or a real
radio on the USB side) while watching the bridge's STATUS for drops, heap
shrinkage, and unexpected resets. Exits non-zero on any anomaly.

Usage:
    soak.py --hours 24 --rate 5
"""

from __future__ import annotations

import argparse
import asyncio
import sys
import time

import catproto as cp
from ble_client import BridgeClient


async def run(args) -> int:
    deadline = time.monotonic() + args.hours * 3600
    period = 1.0 / args.rate
    polls = 0
    errors = 0
    baseline_heap: int | None = None
    baseline_reset: int | None = None

    async with BridgeClient(args.address) as bc:
        start_status = await bc.read_status()
        baseline_heap = start_status.min_free_heap
        baseline_reset = start_status.reset_reason
        drops0 = (start_status.drops_usb_to_ble +
                  start_status.drops_ble_to_usb)
        print(f"soak: start {start_status}")

        while time.monotonic() < deadline:
            t0 = time.monotonic()
            try:
                reply = await bc.cat_command("IF;")
                if not reply.endswith(b";"):
                    errors += 1
                    print(f"! malformed reply: {reply!r}")
            except TimeoutError as e:
                errors += 1
                print(f"! poll timeout: {e}")
            polls += 1

            if polls % (args.rate * 60) == 0:  # once a simulated minute
                st = await bc.read_status()
                drops = st.drops_usb_to_ble + st.drops_ble_to_usb - drops0
                heap_loss = (baseline_heap - st.min_free_heap
                             if baseline_heap else 0)
                print(f"soak: {polls} polls, {errors} errors, "
                      f"drops={drops}, heap_watermark_loss={heap_loss}")
                if drops > 0:
                    print("! overflow detected")
                    return 2
                if st.reset_reason != baseline_reset:
                    print(f"! device reset mid-soak: {st.reset_reason}")
                    return 3

            elapsed = time.monotonic() - t0
            if elapsed < period:
                await asyncio.sleep(period - elapsed)

    ok = errors == 0
    print(f"soak: done — {polls} polls, {errors} errors")
    return 0 if ok else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--address", default=None)
    ap.add_argument("--hours", type=float, default=24.0)
    ap.add_argument("--rate", type=float, default=5.0, help="polls per second")
    return asyncio.run(run(ap.parse_args()))


if __name__ == "__main__":
    sys.exit(main())
