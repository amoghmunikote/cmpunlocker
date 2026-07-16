import glob
import logging
import os
import shutil
import sys
import time
from typing import Optional

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from payload.driver import (
    aggressive_unload, flr_reset, load_module, stop_display_manager, unload_modules,
)
from payload.gsp_patch import patch_gsp
from payload.build import build as build_payload

log = logging.getLogger(__name__)

_GSP_GLOB = "/lib/firmware/nvidia/*/gsp_tu10x.bin"


class _FlushingFileHandler(logging.FileHandler):

    def emit(self, record):
        super().emit(record)
        self.flush()
        # Best-effort fsync so the kernel doesn't buffer the write.
        try:
            os.fsync(self.stream.fileno())
        except OSError:
            pass


def _setup_file_logging() -> Optional[str]:

    path = os.environ.get("CMPUNLOCKER_LOG_FILE")
    if not path:
        log_dir = os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "logs"
        )
        os.makedirs(log_dir, exist_ok=True)
        from datetime import datetime
        path = os.path.join(log_dir, f"pipeline_{datetime.now():%Y%m%d_%H%M%S}.log")

    try:
        handler = _FlushingFileHandler(path, encoding="utf-8")
        handler.setLevel(logging.DEBUG)
        handler.setFormatter(
            logging.Formatter("%(asctime)s.%(msecs)03d %(levelname)-7s %(message)s",
                              datefmt="%H:%M:%S")
        )
        logging.getLogger().addHandler(handler)
        logging.getLogger().setLevel(logging.DEBUG)
        return path
    except OSError as exc:
        log.warning("Could not open pipeline log file %s: %s", path, exc)
        return None


def _find_gsp() -> str:
    paths = sorted(glob.glob(_GSP_GLOB), reverse=True)
    if not paths:
        raise FileNotFoundError(f"No GSP firmware found matching {_GSP_GLOB}")
    return paths[0]


def _ensure_backup(gsp_path: str, backup_path: str, pci_full: str) -> None:
    if not os.path.exists(backup_path):
        shutil.copy2(gsp_path, backup_path)
        log.info("[%s] GSP backup written to %s", pci_full, backup_path)
        return

    log.debug("[%s] GSP backup already exists: %s", pci_full, backup_path)


def _patch_and_flash_gsp(
    backup_path: str, payload: bytes, patched_path: str, gsp_path: str, pci_full: str
) -> None:
    log.info("[%s] [STEP] Patching GSP firmware", pci_full)
    patch_gsp(backup_path, payload, patched_path)
    shutil.copy2(patched_path, gsp_path)
    log.info("[%s] [STEP] GSP firmware patched and written", pci_full)


def _load_driver_and_settle(pci_full: str, settle_seconds: int) -> None:
    load_module()
    log.info("[%s] Sleeping %ds for firmware initialisation", pci_full, settle_seconds)
    time.sleep(settle_seconds)


def _reload_driver_and_settle(pci_full: str, settle_seconds: int) -> None:
    load_module()
    log.info("[%s] Sleeping %ds for driver reload", pci_full, settle_seconds)
    time.sleep(settle_seconds)


def _run_reset_cycle(pci_full: str) -> None:
    log.info("[%s] [STEP] FLR reset #1", pci_full)
    flr_reset(pci_full)
    log.info("[%s] [STEP] FLR reset #1 done", pci_full)

    log.info("[%s] [STEP] Aggressive driver unload", pci_full)
    aggressive_unload()
    log.info("[%s] [STEP] Aggressive unload done", pci_full)

    log.info("[%s] [STEP] FLR reset #2", pci_full)
    flr_reset(pci_full)
    log.info("[%s] [STEP] FLR reset #2 done", pci_full)


def run_full_unlock(pci_full: str, gsp_path: str = None) -> bool:
    if gsp_path is None:
        gsp_path = _find_gsp()

    backup_path = gsp_path + ".cmpunlocker.bak"
    patched_path = gsp_path + ".cmpunlocker.patched"

    log.info("[%s] [STEP] Pipeline start", pci_full)
    log.info("[%s] GSP firmware: %s", pci_full, gsp_path)
    log.debug("[%s] backup=%s patched=%s", pci_full, backup_path, patched_path)

    log.info("[%s] [STEP] Stopping display manager", pci_full)
    stop_display_manager()
    log.info("[%s] [STEP] Display manager stopped", pci_full)

    log.info("[%s] [STEP] Unloading NVIDIA modules", pci_full)
    unload_modules()
    log.info("[%s] [STEP] Modules unloaded", pci_full)

    _ensure_backup(gsp_path, backup_path, pci_full)

    log.info("[%s] [STEP] Building ROP payload", pci_full)
    payload = build_payload()
    log.info("[%s] [STEP] ROP payload built (%d bytes)", pci_full, len(payload))

    _patch_and_flash_gsp(backup_path, payload, patched_path, gsp_path, pci_full)

    log.info("[%s] [STEP] Loading patched driver (modprobe nvidia)", pci_full)
    _load_driver_and_settle(pci_full, 5)
    log.info("[%s] [STEP] Patched driver loaded", pci_full)

    _run_reset_cycle(pci_full)

    from unlock.compute import apply_unlock

    log.info("[%s] [STEP] Writing compute unlock registers (SS0/SS1)", pci_full)
    ok, msg = apply_unlock(pci_full)
    if ok:
        log.info("[%s] [STEP] Compute unlock registers written — success", pci_full)
    else:
        log.warning("[%s] [STEP] Compute unlock registers: %s", pci_full, msg)

    log.info("[%s] [STEP] Restoring original GSP firmware", pci_full)
    shutil.copy2(backup_path, gsp_path)
    log.info("[%s] [STEP] Original GSP firmware restored", pci_full)

    log.info("[%s] [STEP] Reloading driver (modprobe nvidia)", pci_full)
    _reload_driver_and_settle(pci_full, 3)
    log.info("[%s] [STEP] Driver reloaded", pci_full)

    log.info("[%s] [STEP] Pipeline complete — ok=%s", pci_full, ok)
    return ok


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )
    log_path = _setup_file_logging()
    if log_path:
        log.info("Pipeline log: %s", log_path)
    pci = sys.argv[1] if len(sys.argv) > 1 else None
    gsp = sys.argv[2] if len(sys.argv) > 2 else None
    if pci is None:
        from payload.gpu import find_gpu
        pci = find_gpu()
        if pci is None:
            print("ERROR: No compatible GPU found")
            sys.exit(1)
    run_full_unlock(pci, gsp)


if __name__ == "__main__":
    main()
