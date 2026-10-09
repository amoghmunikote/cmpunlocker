import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SecondPassTests(unittest.TestCase):
    def run_activation(self, count=1, width=16, mode="first", args=None):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            sysfs = base / "sysfs"
            sysfs.mkdir()
            driver = base / "drivers" / "nvidia"
            driver.mkdir(parents=True)
            (driver / "unbind").touch()
            for i in range(count):
                port = base / "pci" / f"0000:00:{i + 1:02x}.0"
                gpu = port / f"0000:{i + 1:02x}:00.0"
                gpu.mkdir(parents=True)
                (port / "class").write_text("0x060400\n")
                (gpu / "vendor").write_text("0x10de\n")
                (gpu / "device").write_text("0x20c2\n" if i % 2 == 0 else "0x2082\n")
                if mode != "no-flr":
                    (gpu / "reset").touch()
                (gpu / "driver").symlink_to(driver, target_is_directory=True)
                for device in (port, gpu):
                    (sysfs / device.name).symlink_to(device, target_is_directory=True)
            unsupported = sysfs / "0000:fe:00.0"
            unsupported.mkdir()
            (unsupported / "vendor").write_text("0x10de\n")
            (unsupported / "device").write_text("0x20b0\n")
            modules = base / "modules"
            modules.write_text("nvidia_uvm 1 0\nnvidia_drm 1 0\nnvidia_modeset 1 0\n")
            (base / "loads").write_text("0\n")
            commands = base / "bin"
            commands.mkdir()
            bodies = {
                "fuser": '''case $FIXTURE_MODE in
    busy) exit 0 ;;
    fuser-error) exit 2 ;;
    *) exit 1 ;;
esac''',
                "sleep": '''if [[ $1 == 2 && $FIXTURE_MODE == drop ]]; then
    for marker in "$FIXTURE_DIR"/gen2-*; do rm -f "$marker"; done
fi''',
                "nvidia-smi": '''printf 'SMI\\n' >> "$FIXTURE_DIR/calls"
[[ $FIXTURE_MODE != init-failed ]]''',
                "modprobe": '''printf 'modprobe %s\\n' "$*" >> "$FIXTURE_DIR/calls"
if [[ $1 == nvidia ]]; then
    loads=$(<"$FIXTURE_DIR/loads")
    printf '%s\\n' "$((loads + 1))" > "$FIXTURE_DIR/loads"
elif [[ $1 == -r ]]; then
    [[ " $* " != *" nvidia_peermem "* ]] || exit 96
fi''',
                "setpci": '''[[ $# == 3 && $1 == -s ]] || exit 98
device=$2
register=$3
printf '%s %s\\n' "$device" "$register" >> "$FIXTURE_DIR/calls"
case $register in
    CAP_EXP+0c.l) printf '00456102\\n' ;;
    CAP_EXP+12.w)
        [[ $FIXTURE_MODE != read-failed ]] || exit 97
        if [[ $FIXTURE_MODE == missing-device ]]; then printf 'ffff\\n'; exit 0; fi
        speed=1
        if [[ $FIXTURE_MODE == already || -f $FIXTURE_DIR/gen2-$device ]]; then speed=2; fi
        printf '%04x\\n' "$((0x1000 | (FIXTURE_WIDTH << 4) | speed))"
        ;;
    CAP_EXP+30.w)
        target=0xa002
        loads=$(<"$FIXTURE_DIR/loads")
        if [[ $FIXTURE_MODE == failed || $FIXTURE_MODE == no-flr ||
              ( $FIXTURE_MODE == second && $loads -lt 2 ) ]]; then target=0xa001; fi
        printf '%04x\\n' "$target"
        ;;
    CAP_EXP+30.w=0002:000f) [[ $FIXTURE_MODE != write-failed ]] ;;
    CAP_EXP+10.w=0020:0020) : > "$FIXTURE_DIR/gen2-$device" ;;
    *) exit 98 ;;
esac''',
            }
            for name, body in bodies.items():
                command = commands / name
                command.write_text("#!/bin/bash\nset -eu\n" + body + "\n")
                command.chmod(0o755)
            original = (ROOT / "tools/gen2-second-pass.sh").read_text()
            script = base / "activation.sh"
            script.write_text(original.replace(
                "[[ ${EUID} -eq 0 ]] || die 'run as root'", ": # fixture only"
            ).replace("/sys/bus/pci/devices", str(sysfs)).replace(
                "/run/cmp170-gen2-second-pass.lock", str(base / "activation.lock")
            ).replace("/dev/nvidia", str(base / "dev-nvidia")).replace(
                "/proc/modules", str(modules)
            ).replace("/var/log/gen2.log", str(base / "gen2.log")))
            result = subprocess.run(["bash", str(script), *(args or [])],
                env={**os.environ, "PATH": str(commands) + ":" + os.environ["PATH"],
                     "FIXTURE_DIR": str(base), "FIXTURE_MODE": mode,
                     "FIXTURE_WIDTH": str(width)}, capture_output=True, text=True, timeout=20)
            calls = (base / "calls").read_text().splitlines() if (base / "calls").exists() else []
            resets = [p.read_text() for p in sysfs.glob("*/reset")]
            return result, calls, resets

    def test_inventory_and_width_on_both_passes(self):
        for count in (1, 2, 4, 8):
            for width in (4, 8, 16):
                for mode in ("first", "second"):
                    with self.subTest(count=count, width=width, mode=mode):
                        result, calls, resets = self.run_activation(count, width, mode, ["auto"])
                        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                        self.assertIn(f"PASS: {count} detected CMP 170HX cards", result.stdout)
                        self.assertEqual("starting FLR" in result.stdout, mode == "second")
                        self.assertEqual(set(resets), {"1\n"} if mode == "second" else {""})
                        writes = [call.split()[1] for call in calls if "=" in call]
                        self.assertEqual(set(writes), {"CAP_EXP+30.w=0002:000f", "CAP_EXP+10.w=0020:0020"})
                        retrain = [c for c in calls if c.endswith("CAP_EXP+10.w=0020:0020")]
                        for endpoint, port in zip(retrain[::2], retrain[1::2]):
                            self.assertNotIn("0000:00:", endpoint)
                            self.assertIn("0000:00:", port)
                        self.assertFalse(any("0000:fe:00.0" in c for c in calls))
                        self.assertIn(f"status={0x1000 | (width << 4) | 2:04x}", result.stdout)
                        if mode == "second":
                            for module in ("nvidia_uvm", "nvidia_modeset", "nvidia_drm"):
                                self.assertIn("modprobe " + module, calls)

    def test_already_gen2_does_not_retrain_or_reset(self):
        result, calls, resets = self.run_activation(2, mode="already")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(any("=" in c or c.startswith("modprobe -r") for c in calls))
        self.assertEqual(set(resets), {""})

    def test_invalid_inventory_stops_before_driver_initialization(self):
        for count, args in ((0, []), (4, ["1"]), (1, ["0"]), (1, ["invalid"])):
            with self.subTest(count=count, args=args):
                result, calls, resets = self.run_activation(count, args=args)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(calls, [])
                self.assertTrue(all(not reset for reset in resets))

    def test_busy_or_unverifiable_clients_fail_closed(self):
        for mode in ("busy", "fuser-error"):
            result, calls, resets = self.run_activation(mode=mode)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(calls, [])
            self.assertEqual(resets, [""])

    def test_missing_flr_stops_before_unbind(self):
        result, calls, _ = self.run_activation(mode="no-flr")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FLR unavailable", result.stdout + result.stderr)
        self.assertNotIn("modprobe -r nvidia_uvm nvidia_drm nvidia_modeset nvidia", calls)

    def test_failed_second_pass_restores_driver_but_never_claims_success(self):
        result, calls, resets = self.run_activation(mode="failed")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("PASS:", result.stdout)
        self.assertEqual(resets, ["1\n"])
        self.assertIn("modprobe nvidia_uvm", calls)
        self.assertEqual(calls.count("modprobe nvidia"), 3)

    def test_stability_drop_is_not_success(self):
        result, _, _ = self.run_activation(mode="drop")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("dropped below Gen2", result.stdout + result.stderr)
        self.assertNotIn("PASS:", result.stdout)

    def test_failed_initialization_never_retrains(self):
        result, calls, resets = self.run_activation(mode="init-failed")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any("=" in c for c in calls))
        self.assertEqual(resets, [""])

    def test_pci_io_errors_do_not_reset_or_claim_success(self):
        for mode in ("read-failed", "write-failed", "missing-device"):
            with self.subTest(mode=mode):
                result, calls, resets = self.run_activation(mode=mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("PASS:", result.stdout)
                self.assertFalse(any(c.startswith("modprobe -r") for c in calls))
                self.assertEqual(resets, [""])

    def test_default_install_uses_second_pass_not_hammer(self):
        unit = (ROOT / "systemd/gen2.service").read_text()
        service = (ROOT / "tools/service.sh").read_text()
        self.assertIn("ExecStart=/usr/local/sbin/gen2-second-pass auto", unit)
        self.assertNotIn("gen2-hammer", unit)
        self.assertIn('"${SCRIPT_DIR}/gen2-second-pass.sh"', service)
        self.assertIn('flock -n 9', service)
        self.assertIn('systemctl is-active --quiet', service)
        self.assertNotIn("systemctl start", service)
        self.assertIn("/usr/local/sbin/gen2-second-pass", (ROOT / "remove.sh").read_text())


if __name__ == "__main__":
    unittest.main()
