#!/usr/bin/env python3
"""GPU-aware fan controller for the ASRock Rack ROMED8-2T BMC.

The BMC's own Smart Fan curve is driven by CPU and motherboard sensors only --
it has no idea the GPUs exist. On this host that left every fan parked at 30%
duty while a CMP 170HX sat at 84 C, because the CPU was reading 37 C. The cards
are passively cooled, so chassis airflow is the *only* thing moving heat off
them.

This daemon closes that loop: it reads GPU die temperatures with nvidia-smi and
drives the two GPU fan headers directly, via the ASRock Rack OEM IPMI commands.

    0x3a 0xd8 <16 bytes>   per-fan mode, 1 = manual, 0 = BMC auto
    0x3a 0xd6 <16 bytes>   per-fan duty, 0x00-0x64 (0-100%)
    0x3a 0xda              read back current duty

Byte index N addresses header FAN(N+1) -- index 3 is FAN4, index 6 is FAN7.
Verified empirically on this board; do not assume it holds on another model.

Only the GPU headers are switched to manual. FAN1/2/3 stay on the BMC's own
curve, so CPU and chassis cooling keep working normally (and keep working if
this daemon is not running).

Failure is always toward more cooling: if nvidia-smi stops answering, or the
daemon hits an unexpected error, the managed fans go to 100% rather than
staying wherever they happened to be. On a clean shutdown they are handed back
to the BMC.
"""

from __future__ import annotations

import argparse
import logging
import os
import signal
import subprocess
import sys
import time

# --- Fan topology ------------------------------------------------------------
# Byte index in the IPMI duty array -> the GPU indices that header cools.
# Determined by a differential cooling test (pin one fan high, the other low,
# and watch which dies respond), not by PCIe bus order: the slot layout does
# not follow bus enumeration on this chassis.
FAN_GROUPS: dict[int, list[int]] = {
    3: [0, 4, 5],  # FAN4
    6: [1, 2, 3],  # FAN7
}

FAN_NAMES = {3: "FAN4", 6: "FAN7"}

# --- Curve -------------------------------------------------------------------
# Duty is a straight line between these two points, clamped at both ends.
# TEMP_MAX is deliberately well under the 85 C limit: reaching 100% duty only
# at 85 C would mean the fans are still ramping while the card is already
# throttling. Hitting full speed by 75 C leaves headroom to actually stop the
# climb.
# Tuned to hold the cards under 40 C at idle. The first cut (40% floor, ramp
# starting at 45 C) left them at 40-49 C doing nothing, because a 40% floor is
# only ~1400 RPM on these fans and the ramp did not even begin until 45 C -- so
# a card sitting at 43 C got no more air than one at 30 C.
#
# The floor is now 60% (~1900 RPM, measured) and the ramp starts at 36 C, so any
# card drifting toward 40 C is already being pushed on. This is audibly louder
# at idle; that is the deliberate trade for the temperature target.
TEMP_IDLE = 36.0  # at or below this, hold DUTY_IDLE
TEMP_MAX = 68.0  # at or above this, run DUTY_MAX
DUTY_IDLE = 60  # idle floor
DUTY_MAX = 100

# A card above this while its fan is already at 100% is not a control problem --
# there is simply not enough airflow reaching it, and no duty value will fix it.
# Logged loudly so the deficit is attributable to a specific card rather than
# silently absorbed. GPU2 (45:00.0) does this on the current chassis layout.
TEMP_CRITICAL = 80.0

# Ramping up is immediate; ramping down is rate limited. Without this the duty
# oscillates audibly, because dropping the fan raises the die temperature within
# one interval, which raises the duty again.
FALL_STEP = 2  # max duty points shed per interval
INTERVAL = 5.0  # seconds between samples

# Consecutive nvidia-smi failures tolerated before going to DUTY_MAX.
FAULT_TOLERANCE = 3

DUTY_ARRAY_LEN = 16

log = logging.getLogger("gpu-fan")


class IpmiError(RuntimeError):
    pass


def _ipmi(*args: str) -> str:
    """Run an ipmitool command, returning stdout."""
    cmd = ["ipmitool", *args]
    try:
        proc = subprocess.run(
            cmd, capture_output=True, text=True, timeout=15, check=False
        )
    except subprocess.TimeoutExpired as exc:
        raise IpmiError(f"{' '.join(cmd)}: timed out") from exc
    if proc.returncode != 0:
        raise IpmiError(f"{' '.join(cmd)}: {proc.stderr.strip()}")
    return proc.stdout


def read_duty() -> list[int]:
    """Current per-fan duty as reported by the BMC."""
    out = _ipmi("raw", "0x3a", "0xda")
    vals = [int(tok, 16) for tok in out.split()]
    if len(vals) != DUTY_ARRAY_LEN:
        raise IpmiError(f"expected {DUTY_ARRAY_LEN} duty bytes, got {len(vals)}")
    return vals


def write_duty(duties: list[int]) -> None:
    _ipmi("raw", "0x3a", "0xd6", *(f"0x{d:02x}" for d in duties))


def set_modes(manual_indices: set[int]) -> None:
    """Put the named fans under manual control and leave every other fan on the
    BMC's own curve."""
    flags = [
        "0x01" if i in manual_indices else "0x00" for i in range(DUTY_ARRAY_LEN)
    ]
    _ipmi("raw", "0x3a", "0xd8", *flags)


def read_gpu_temps() -> dict[int, float]:
    """GPU index -> die temperature in C."""
    proc = subprocess.run(
        [
            "nvidia-smi",
            "--query-gpu=index,temperature.gpu",
            "--format=csv,noheader,nounits",
        ],
        capture_output=True,
        text=True,
        timeout=15,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"nvidia-smi failed: {proc.stderr.strip()}")

    temps: dict[int, float] = {}
    for line in proc.stdout.strip().splitlines():
        idx_s, _, temp_s = line.partition(",")
        try:
            temps[int(idx_s)] = float(temp_s)
        except ValueError:
            # A card that is falling off the bus reports [N/A]. Skip it here;
            # the caller treats a missing group member as a fault.
            log.warning("unparseable nvidia-smi row: %r", line)
    if not temps:
        raise RuntimeError("nvidia-smi returned no usable temperatures")
    return temps


def duty_for(temp: float) -> int:
    """Map the hottest die in a group to a duty percentage."""
    if temp <= TEMP_IDLE:
        return DUTY_IDLE
    if temp >= TEMP_MAX:
        return DUTY_MAX
    span = (temp - TEMP_IDLE) / (TEMP_MAX - TEMP_IDLE)
    return int(round(DUTY_IDLE + span * (DUTY_MAX - DUTY_IDLE)))


def clamp(duty: int) -> int:
    return max(0, min(DUTY_MAX, duty))


class Controller:
    def __init__(self, groups: dict[int, list[int]], dry_run: bool = False):
        self.groups = groups
        self.dry_run = dry_run
        self.applied: dict[int, int] = {i: DUTY_MAX for i in groups}
        self.faults = 0
        self._stop = False
        # start() parks the fans at 100% before the first reading lands. Once a
        # real temperature arrives we want to drop straight to the curve value
        # rather than crawl down at FALL_STEP per interval, which would spend
        # ~2.5 minutes at full noise on every restart.
        self._settled = False

    def request_stop(self, *_: object) -> None:
        self._stop = True

    # -- lifecycle -----------------------------------------------------------
    def start(self) -> None:
        if self.dry_run:
            log.info("dry run: not taking manual control")
            return
        set_modes(set(self.groups))
        log.info(
            "manual control taken for %s; other headers left on BMC auto",
            ", ".join(FAN_NAMES.get(i, f"idx{i}") for i in sorted(self.groups)),
        )
        # Start at full speed until the first good reading tells us otherwise.
        self.apply({i: DUTY_MAX for i in self.groups})

    def restore(self) -> None:
        """Hand the GPU headers back to the BMC."""
        if self.dry_run:
            return
        try:
            set_modes(set())
            log.info("restored all headers to BMC auto control")
        except IpmiError as exc:
            # Best effort: we are already on the way out. Leaving the fans at
            # whatever duty they hold is survivable; the BMC still enforces its
            # own failsafe if a fan stalls.
            log.error("could not restore BMC auto control: %s", exc)

    def panic(self) -> None:
        """Lost sight of the GPUs -- cool them as hard as we can."""
        if self.applied != {i: DUTY_MAX for i in self.groups}:
            log.error("fault threshold reached, forcing %d%%", DUTY_MAX)
        try:
            self.apply({i: DUTY_MAX for i in self.groups})
        except IpmiError as exc:
            # This is the failsafe path; it must not be what kills the daemon.
            # systemd restarts us, and start() re-asserts 100% on the way in.
            log.error("failsafe write failed: %s", exc)

    # -- control -------------------------------------------------------------
    def apply(self, targets: dict[int, int]) -> None:
        if self.dry_run:
            self.applied.update(targets)
            return
        duties = read_duty()
        changed = False
        for idx, duty in targets.items():
            duty = clamp(duty)
            if duties[idx] != duty:
                duties[idx] = duty
                changed = True
            self.applied[idx] = duty
        if changed:
            write_duty(duties)

    def step(self) -> None:
        try:
            temps = read_gpu_temps()
            self.faults = 0
        except Exception as exc:  # nvidia-smi gone, driver wedged, timeout
            self.faults += 1
            log.warning("temperature read failed (%d/%d): %s",
                        self.faults, FAULT_TOLERANCE, exc)
            if self.faults >= FAULT_TOLERANCE:
                self.panic()
            return

        targets: dict[int, int] = {}
        report = []
        for idx, gpus in self.groups.items():
            present = [temps[g] for g in gpus if g in temps]
            if len(present) != len(gpus):
                missing = [g for g in gpus if g not in temps]
                log.warning("GPU(s) %s missing from nvidia-smi; forcing %d%% on %s",
                            missing, DUTY_MAX, FAN_NAMES.get(idx, idx))
                targets[idx] = DUTY_MAX
                report.append(f"{FAN_NAMES.get(idx, idx)}=100%(fault)")
                continue

            # Track which card is driving the group, not just how hot it is --
            # on this chassis one card in a group can run ~19 C above its
            # neighbours, and that is invisible from the max alone.
            hot_gpu = max(gpus, key=lambda g: temps[g])
            hottest = temps[hot_gpu]
            want = duty_for(hottest)
            current = self.applied.get(idx, DUTY_MAX)
            if not self._settled:
                # First good reading after start: adopt the curve directly.
                duty = want
            else:
                # Rise at once, fall gently.
                duty = want if want >= current else max(want, current - FALL_STEP)
            targets[idx] = duty
            report.append(
                f"{FAN_NAMES.get(idx, idx)}: GPU{hot_gpu} {hottest:.0f}C -> {duty}%"
            )
            if duty >= DUTY_MAX and hottest >= TEMP_CRITICAL:
                log.error(
                    "%s is at %d%% and GPU%d is still %.0fC: cooling deficit, "
                    "not a control problem. Needs airflow or a lower power cap.",
                    FAN_NAMES.get(idx, idx), DUTY_MAX, hot_gpu, hottest,
                )

        try:
            self.apply(targets)
        except IpmiError as exc:
            log.error("failed to apply duty: %s", exc)
            return

        self._settled = True
        log.info("  ".join(report))

    def run(self) -> int:
        self.start()
        try:
            while not self._stop:
                self.step()
                # Sleep in slices so a signal is acted on promptly.
                waited = 0.0
                while waited < INTERVAL and not self._stop:
                    time.sleep(0.25)
                    waited += 0.25
        finally:
            self.restore()
        return 0


def parse_groups(spec: str) -> dict[int, list[int]]:
    """Parse "3:0,4,5 6:1,2,3" into {3: [0,4,5], 6: [1,2,3]}."""
    groups: dict[int, list[int]] = {}
    for chunk in spec.split():
        fan_s, _, gpus_s = chunk.partition(":")
        groups[int(fan_s)] = [int(g) for g in gpus_s.split(",") if g != ""]
    return groups


def main() -> int:
    # Declared up front: the argparse defaults below read these names, and
    # Python forbids `global` after a name is used in the same scope.
    global DUTY_IDLE, TEMP_IDLE, TEMP_MAX, INTERVAL

    ap = argparse.ArgumentParser(
        description="Drive ROMED8-2T GPU fan headers from GPU die temperature."
    )
    ap.add_argument(
        "--groups",
        default=None,
        help='Override fan map, e.g. "3:0,4,5 6:1,2,3" (fan byte index:GPUs)',
    )
    ap.add_argument("--idle-duty", type=int, default=DUTY_IDLE)
    ap.add_argument("--idle-temp", type=float, default=TEMP_IDLE)
    ap.add_argument("--max-temp", type=float, default=TEMP_MAX)
    ap.add_argument("--interval", type=float, default=INTERVAL)
    ap.add_argument(
        "--dry-run",
        action="store_true",
        help="Log the duty it would set without touching the BMC.",
    )
    ap.add_argument(
        "--once", action="store_true", help="Evaluate a single step and exit."
    )
    args = ap.parse_args()

    DUTY_IDLE = args.idle_duty
    TEMP_IDLE = args.idle_temp
    TEMP_MAX = args.max_temp
    INTERVAL = args.interval

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        stream=sys.stdout,
    )

    if not args.dry_run and os.geteuid() != 0:
        log.error("needs root for /dev/ipmi0 (run under sudo, or use --dry-run)")
        return 1

    groups = parse_groups(args.groups) if args.groups else FAN_GROUPS
    ctl = Controller(groups, dry_run=args.dry_run)

    if args.once:
        # Evaluate one step and hand the fans straight back, so a manual probe
        # never leaves the BMC pinned in manual mode.
        ctl.start()
        try:
            ctl.step()
        finally:
            ctl.restore()
        return 0

    signal.signal(signal.SIGTERM, ctl.request_stop)
    signal.signal(signal.SIGINT, ctl.request_stop)
    return ctl.run()


if __name__ == "__main__":
    sys.exit(main())
