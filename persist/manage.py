#!/usr/bin/env python3
"""Offline driver rebuilds and owned package holds, adapted from asm64's persist/.

Never unload/reload a driver, change the boot kernel, or patch the Linux kernel.
The Debian kernel AND header hooks build before reboot. Boot checks report faults
instead of attempting to replace a driver that may already be in use.
"""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


def kernel_version(value):
    if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9._+-]*", value):
        raise ValueError("Invalid kernel version")
    return value


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def write(path, text, mode=0o644):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".cmpunlocker-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def write_json(path, data):
    write(path, json.dumps(data, indent=2, sort_keys=True) + "\n")


class Manager:
    # root/run injection is used by tests; the CLI always uses the real root.
    def __init__(self, root=Path("/"), run=subprocess.run):
        self.root = Path(root)
        self.run = run
        self.data = self.path("/var/lib/cmpunlocker")
        self.payload = self.data / "payload"
        self.state = self.data / "state"
        self.config_file = self.path("/etc/cmpunlocker/build.json")
        self.helper = self.path("/usr/lib/cmpunlocker/manage.py")

    def path(self, absolute):
        return self.root / absolute.lstrip("/")

    def command(self, args, **kwargs):
        kwargs.setdefault("check", True)
        return self.run(args, **kwargs)

    def output(self, args):
        return self.command(args, capture_output=True, text=True).stdout.strip()

    def modules(self, kver):
        return self.path(f"/lib/modules/{kernel_version(kver)}/updates/cmpunlocker")

    def config(self):
        config = json.loads(self.config_file.read_text())
        if (config.get("schema") != 1 or
                config.get("p2p") not in ("off", "bar1", "mailbox") or
                config.get("no_gen2") not in ("0", "1") or
                config.get("profile") not in ("8gb", "10gb", "mixed") or
                not isinstance(config.get("passthrough"), bool) or
                not re.fullmatch(r"\d+\.\d+\.\d+", config.get("version", ""))):
            raise ValueError("Invalid saved build configuration; re-run install.sh")
        return config

    def signature(self, config):
        return hashlib.sha256(json.dumps(config, sort_keys=True).encode()).hexdigest()

    def payload_digest(self, base):
        h = hashlib.sha256()
        for path in sorted(base.rglob("*")):
            if path.is_file() and not {".build", "__pycache__"} & set(path.relative_to(base).parts):
                h.update(str(path.relative_to(base)).encode())
                h.update(digest(path).encode())
        return h.hexdigest()

    def module_hashes(self, kver, config):
        folder = self.modules(kver)
        for name in ("nvidia", "nvidia-uvm"):
            if not (folder / (name + ".ko")).is_file():
                raise RuntimeError(f"Missing {name}.ko for {kver}")
        if config["passthrough"] and not (folder / "cmp_no_bus_reset.ko").is_file():
            raise RuntimeError(f"Missing passthrough module for {kver}")
        return {p.name: digest(p) for p in folder.glob("*.ko")}

    def check_resolution(self, kver, config):
        resolved = self.output(["modinfo", "-n", "-k", kver, "nvidia"])
        if Path(resolved).resolve() != (self.modules(kver) / "nvidia.ko").resolve():
            raise RuntimeError(f"Kernel {kver} resolves the wrong NVIDIA module: {resolved}")
        version = self.output(["modinfo", "-F", "version", "-k", kver, "nvidia"])
        if version != config["version"]:
            raise RuntimeError(f"NVIDIA module version {version} != saved {config['version']}")
        vermagic = self.output(["modinfo", "-F", "vermagic", "-k", kver, "nvidia"])
        if not vermagic or vermagic.split()[0] != kver:
            raise RuntimeError(f"NVIDIA module was not built for kernel {kver}: {vermagic}")

    def record(self, kver, config):
        self.check_resolution(kver, config)
        write_json(self.state / f"built-{kver}.json", {
            "configuration": self.signature(config),
            "modules": self.module_hashes(kver, config),
        })
        (self.state / f"failed-{kver}").unlink(missing_ok=True)

    def current(self, kver, config):
        try:
            stamp = json.loads((self.state / f"built-{kver}.json").read_text())
            self.check_resolution(kver, config)
            return (stamp["configuration"] == self.signature(config) and
                    stamp["modules"] == self.module_hashes(kver, config) and
                    not (self.state / f"failed-{kver}").exists())
        except (OSError, ValueError, KeyError, RuntimeError, subprocess.CalledProcessError):
            return False

    def hooks(self):
        return [self.path(p) for p in (
            "/etc/kernel/postinst.d/zz-cmpunlocker",
            "/etc/kernel/header_postinst.d/zz-cmpunlocker",
            "/etc/kernel/postrm.d/zz-cmpunlocker",
            "/etc/kernel/install.d/95-cmpunlocker.install",
            "/etc/pacman.d/hooks/95-cmpunlocker.hook",
        )]

    def remove_hooks(self):
        for path in self.hooks():
            path.unlink(missing_ok=True)
        self.command(["systemctl", "disable", "cmpunlocker-check.service"],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        self.path("/etc/systemd/system/cmpunlocker-check.service").unlink(missing_ok=True)
        self.command(["systemctl", "daemon-reload"])

    def install_hooks(self):
        # Hook failure is logged and visible at boot; do not wedge dpkg's kernel
        # transaction just because its headers have not yet been configured.
        helper = "/usr/bin/python3 /usr/lib/cmpunlocker/manage.py"
        rebuild = f'{helper} rebuild "$1" || echo "cmpunlocker: rebuild failed; inspect /var/log/cmpunlocker before reboot" >&2\nexit 0\n'
        if self.path("/etc/debian_version").exists():
            for path in self.hooks()[:2]:
                write(path, "#!/bin/sh\n" + rebuild, 0o755)
            write(self.hooks()[2], f'#!/bin/sh\n{helper} forget "$1"\n', 0o755)
        elif self.path("/etc/pacman.conf").exists():
            write(self.hooks()[4], "[Trigger]\nOperation = Install\nOperation = Upgrade\n"
                  "Type = Path\nTarget = usr/lib/modules/*/build/Makefile\n\n[Action]\n"
                  "Description = Rebuild cmpunlocker for installed kernels\nWhen = PostTransaction\n"
                  f"Exec = {helper} rebuild-all\n")
        else:
            write(self.hooks()[3], '#!/bin/sh\ncase "$1" in\n'
                  f'  add) {helper} rebuild "$2" || echo "cmpunlocker: rebuild failed; check logs" >&2 ;;\n'
                  f'  remove) {helper} forget "$2" ;;\nesac\nexit 0\n', 0o755)
        write(self.path("/etc/systemd/system/cmpunlocker-check.service"),
              "[Unit]\nDescription=Check cmpunlocker modules and BAR1 allocation\n"
              "After=systemd-modules-load.service gen2.service\n\n[Service]\nType=oneshot\n"
              f"ExecStart={helper} boot-check\nRemainAfterExit=yes\n\n[Install]\nWantedBy=multi-user.target\n")
        self.command(["systemctl", "daemon-reload"])
        self.command(["systemctl", "enable", "cmpunlocker-check.service"])

    def install(self, source, kver, persist=True, pin=True):
        source = Path(source).resolve()
        folder = self.modules(kver)
        # Read what was actually installed, not ambient shell defaults.
        config = {"schema": 1, "version": (folder / "driver_version").read_text().strip(),
                  "profile": (folder / "card_profile").read_text().strip(),
                  "p2p": (folder / "p2p_mode").read_text().strip(),
                  "no_gen2": (folder / "gen2_disabled").read_text().strip(),
                  "inventory": (folder / "gpu_inventory").read_text(),
                  "passthrough": (folder / "cmp_no_bus_reset.ko").is_file()}
        self.data.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix=".payload-", dir=self.data) as temp:
            stage = Path(temp) / "payload"
            for name in ("common", "tools", "persist"):
                shutil.copytree(source / name, stage / name,
                                ignore=shutil.ignore_patterns(".build", "__pycache__", "*.ko", "*.o", ".*.cmd"))
            (stage / "driver/passthrough").mkdir(parents=True)
            for name in ("build.sh", "VERSION", "passthrough/Makefile", "passthrough/cmp_no_bus_reset.c"):
                shutil.copy2(source / "driver" / name, stage / "driver" / name)
            shutil.copytree(source / "driver/patches", stage / "driver/patches")
            # One matching stock source archive suffices for offline rebuilds.
            archive = source / "driver/.build" / f"open-gpu-kernel-modules-{config['version']}.tar.gz"
            if not archive.is_file():
                raise RuntimeError(f"Missing cached driver archive: {archive}")
            (stage / "driver/.build").mkdir()
            shutil.copy2(archive, stage / "driver/.build" / archive.name)
            config["payload_hash"] = self.payload_digest(stage)
            if self.payload.exists():
                shutil.rmtree(self.payload)
            stage.rename(self.payload)
        write(self.helper, (source / "persist/manage.py").read_text(), 0o755)
        write_json(self.config_file, config)
        self.record(kver, config)
        self.remove_hooks()
        if persist:
            self.install_hooks()
        if pin:
            self.pin()
        else:
            self.unpin()
        print(f"Saved {config['p2p']} P2P, no-gen2={config['no_gen2']}, {config['profile']} for rebuilds.")
        print("Automatic kernel/header rebuilds " + ("enabled." if persist else "disabled."))
        print("After changing options, rebuild older kernels before using them: "
              "sudo python3 /usr/lib/cmpunlocker/manage.py rebuild <kernel-version>")

    def rebuild(self, kver):
        kver = kernel_version(kver)
        config = self.config()  # Missing config is an error, never silently use defaults.
        log = self.path(f"/var/log/cmpunlocker/rebuild-{kver}.log")
        try:
            if self.payload_digest(self.payload) != config["payload_hash"]:
                raise RuntimeError("Saved build payload changed; re-run install.sh")
            if self.current(kver, config):
                print(f"cmpunlocker: {kver} already has this exact build.")
                return
            if not self.path(f"/lib/modules/{kver}/build").is_dir():
                raise RuntimeError(f"Headers missing for {kver}; the header hook will retry")
            env = {k: v for k, v in os.environ.items() if not k.startswith("CMPUNLOCKER_")}
            env.update({"CMPUNLOCKER_KVER": kver, "CMPUNLOCKER_DRIVER_VERSION": config["version"],
                        "CMPUNLOCKER_CARD_PROFILE": config["profile"],
                        "CMPUNLOCKER_GPU_INVENTORY": config["inventory"],
                        "CMPUNLOCKER_P2P_MODE": config["p2p"],
                        "CMPUNLOCKER_DISABLE_GEN2": config["no_gen2"],
                        "CMPUNLOCKER_BUILD_PASSTHROUGH": "1" if config["passthrough"] else "0"})
            log.parent.mkdir(parents=True, exist_ok=True)
            print(f"cmpunlocker: building for {kver}; log: {log}", flush=True)
            with log.open("a") as stream:
                self.command(["bash", str(self.payload / "driver/build.sh")],
                             env=env, stdout=stream, stderr=subprocess.STDOUT)
            self.record(kver, config)
        except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
            write(self.state / f"failed-{kver}", f"{error}\nLog: {log}\n")
            raise
        print(f"cmpunlocker: modules ready for {kver}; the running driver was not reloaded.")
        if config["p2p"] == "bar1":
            print("BAR1 P2P: this rebuild does not port Linux PCI patches. Keep the working kernel; "
                  "the boot check must confirm full BAR1 on the new kernel before P2P workloads.")

    def boot_check(self, kver):
        config = self.config()
        if not self.current(kver, config):
            raise RuntimeError("Missing, stale or failed build. Run: sudo python3 "
                               "/usr/lib/cmpunlocker/manage.py rebuild; then cold boot")
        if config["p2p"] == "bar1":
            self.command([sys.executable, str(self.payload / "tools/check-bar1.py")])
        print("cmpunlocker: module files/selection and requested BAR1 allocation passed. "
              "Use verify.sh and p2p-test for runtime memory/transfer validation.")

    def pin(self):
        if not self.path("/etc/debian_version").exists():
            print("Package pinning currently supports apt only; pin the matching NVIDIA packages manually.")
            return
        rows = self.output(["dpkg-query", "-W", "-f=${binary:Package}\t${db:Status-Status}\n"])
        packages = set()
        for line in rows.splitlines():
            name, status = line.split("\t", 1)
            # Keep versioned nvidia-firmware-610-* (GSP) with the driver, but do
            # not hold independent linux-firmware packages.
            if (status == "installed" and "nvidia" in name.lower() and
                    not re.match(r"^(nvidia-gpu-firmware|firmware-nvidia|nvidia-firmware)(?::|$)", name)):
                packages.add(name)
        held = set(self.output(["apt-mark", "showhold"]).splitlines())
        ledger = self.state / "apt-holds.json"
        owned = set(json.loads(ledger.read_text())) if ledger.exists() else set()
        for package in sorted(packages - held):
            # Save intent before mutation, so interruption still leaves a way
            # to undo our holds. Existing user holds are never added here.
            owned.add(package)
            write_json(ledger, sorted(owned))
            self.command(["apt-mark", "hold", package])
        actual = set(self.output(["apt-mark", "showhold"]).splitlines())
        if not packages <= actual:
            raise RuntimeError("Some NVIDIA packages were not held")
        print(f"cmpunlocker: {len(packages)} NVIDIA packages held; existing user holds preserved.")

    def unpin(self):
        ledger = self.state / "apt-holds.json"
        if not ledger.exists():
            return
        owned = set(json.loads(ledger.read_text()))
        held = set(self.output(["apt-mark", "showhold"]).splitlines())
        for package in sorted(owned):
            if package in held:
                self.command(["apt-mark", "unhold", package])
            owned.remove(package)
            write_json(ledger, sorted(owned))
        ledger.unlink()

    def forget(self, kver):
        kver = kernel_version(kver)
        for name in (f"built-{kver}.json", f"failed-{kver}"):
            (self.state / name).unlink(missing_ok=True)

    def uninstall(self):
        self.remove_hooks()
        self.unpin()
        self.config_file.unlink(missing_ok=True)
        for name in ("payload", "state"):
            shutil.rmtree(self.data / name, ignore_errors=True)
        for name in ("/etc/depmod.d/cmpunlocker.conf", "/etc/modprobe.d/cmpunlocker.conf"):
            self.path(name).unlink(missing_ok=True)
        self.helper.unlink(missing_ok=True)
        print("Removed rebuild hooks and cmpunlocker's package holds; preserved logs and any custom dmem.bin.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("install", "uninstall", "rebuild", "rebuild-all", "boot-check",
                                           "forget", "pin", "unpin", "status"))
    parser.add_argument("kernel", nargs="?")
    parser.add_argument("--source", type=Path)
    parser.add_argument("--no-persist", action="store_true")
    parser.add_argument("--no-pin", action="store_true")
    args = parser.parse_args()
    if args.action != "status" and (os.geteuid() != 0 or sys.platform != "linux"):
        parser.error("Run as root on the target Linux machine")
    manager = Manager()
    kver = kernel_version(args.kernel or os.uname().release)
    manager.data.mkdir(parents=True, exist_ok=True)
    with (manager.data / "maintenance.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if args.action == "install":
            if args.source is None:
                parser.error("install requires --source")
            manager.install(args.source, kver, not args.no_persist, not args.no_pin)
        elif args.action == "rebuild-all":
            failures = []
            for directory in sorted(manager.path("/lib/modules").iterdir()):
                if (directory / "build").is_dir():
                    try:
                        manager.rebuild(directory.name)
                    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
                        failures.append(f"{directory.name}: {error}")
            if failures:
                raise RuntimeError("\n".join(failures))
        elif args.action in ("rebuild", "boot-check", "forget"):
            getattr(manager, args.action.replace("-", "_"))(kver)
        elif args.action == "status":
            print(json.dumps(manager.config(), indent=2))
            print("Current kernel build:", "OK" if manager.current(kver, manager.config()) else "NEEDS REBUILD")
            for marker in sorted(manager.state.glob("failed-*")):
                print(marker.name + ": " + marker.read_text())
        else:
            getattr(manager, args.action)()


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as exc:
        sys.exit(f"cmpunlocker: {exc}")
