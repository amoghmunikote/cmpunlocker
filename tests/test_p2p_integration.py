"""Offline P2P integration checks; never builds/loads a real kernel module.

System-facing shell scripts run from a temporary copy with every system path
redirected under that directory and privileged external commands replaced by
test doubles. Patch composition uses reconstructed context fixtures, not a
complete NVIDIA release; it cannot establish release build compatibility.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
P2P_NAMES = (
    "0007-p2p-caps.patch", "0011-p2p-bar1.patch",
    "0013-skip-mailbox-peer-preinit.patch", "0015-bar1p2p-readcap-override.patch",
)


def hunks(path):
    """Read and validate unified-diff counts, returning each old/new context."""
    lines = path.read_text().splitlines(keepends=True)
    target = None
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.startswith("+++ "):
            target = line.split()[1].split("/", 1)[1]
        match = re.match(r"@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@", line)
        if not match:
            i += 1
            continue
        old_count, new_count = int(match[2] or 1), int(match[4] or 1)
        old, new = [], []
        i += 1
        while len(old) < old_count or len(new) < new_count:
            line = lines[i]
            # GNU patch also accepts an empty context line without its space.
            prefix, content = (" ", "\n") if line == "\n" else (line[0], line[1:])
            if prefix in " -":
                old.append(content)
            if prefix in " +":
                new.append(content)
            if prefix not in " +-\\":
                raise AssertionError(f"Malformed hunk in {path}: {line!r}")
            i += 1
        if len(old) != old_count or len(new) != new_count:
            raise AssertionError(f"Bad hunk counts in {path}")
        yield target, int(match[1]), old, new


MOCK = r'''import hashlib, json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
root = pathlib.Path(os.environ["TEST_ROOT"])
conf = root / "system/etc/modprobe.d/cmp-pcie-gen2.conf"
record = {"cmd": name, "args": sys.argv[1:],
          "config": conf.read_text() if conf.exists() else None}
payload = ""
if name == "patch":
    payload = sys.stdin.read()
    record["sha256"] = hashlib.sha256(payload.encode()).hexdigest()
with (root / "events.jsonl").open("a") as stream:
    stream.write(json.dumps(record) + "\n")
if name == "uname":
    print("p2p-test-kernel")
elif name == "patch":
    if os.environ.get("FAIL_PATCH") and os.environ["FAIL_PATCH"] in payload:
        sys.exit(1)
elif name == "make":
    out = pathlib.Path.cwd() / "kernel-open/nvidia.ko"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("mock module; not loadable\n")
elif name == "update-initramfs" and os.environ.get("FAIL_INITRAMFS"):
    sys.exit(1)
elif name == "modprobe" and "-n" in sys.argv:
    print("insmod " + str(root / "system/lib/modules/p2p-test-kernel/updates/cmpunlocker/nvidia.ko"))
elif name == "modinfo" and "srcversion" in sys.argv:
    print("MOCK")
elif name == "nvidia-smi":
    if "--query-gpu=driver_version" in sys.argv:
        print(os.environ["TEST_VERSION"])
    else:
        print("00000000:01:00.0, 8192\n00000000:02:00.0, 10240")
elif name == "lspci":
    print("01:00.0 3D controller: NVIDIA CMP [10de:20c2]")
    print("02:00.0 3D controller: NVIDIA CMP [10de:2082]")
elif name == "curl":
    sys.exit("Offline test unexpectedly attempted a download")
'''


class P2PIntegration(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix=".p2p-test-", dir=ROOT)
        self.addCleanup(self.temp.cleanup)
        self.tmp = Path(self.temp.name)
        self.project = self.tmp / "project"
        self.project.mkdir()
        for name in ("driver", "common", "tools"):
            shutil.copytree(ROOT / name, self.project / name,
                            ignore=shutil.ignore_patterns(".build", "__pycache__"))
        shutil.copy2(ROOT / "install.sh", self.project / "install.sh")
        for script in (self.project / "install.sh", self.project / "driver/build.sh"):
            text = script.read_text()
            for prefix in ("/lib/modules/", "/lib/firmware/", "/etc/", "/usr/local/",
                           "/proc/", "/sys/", "/boot/"):
                text = text.replace(prefix, str(self.tmp / "system") + prefix)
            # Only the isolated copy runs as simulated root. All paths and
            # system commands it can touch have already been redirected.
            text = text.replace('${EUID}', '${CMPUNLOCKER_TEST_EUID}')
            # Some restricted runners have no /dev/fd support. These fixture
            # producers always emit at least one line, so here-strings are
            # equivalent for their mapfile calls; production scripts stay intact.
            text = re.sub(r"mapfile -t (\w+) < <\((.*?)\)\n",
                          lambda m: 'mapfile -t ' + m[1] + ' <<< "$(' + m[2] + ')"\n',
                          text, flags=re.S)
            text = text.replace('exec > >(tee -a "${LOG_FILE}") 2>&1',
                                '# Output captured by the test subprocess.')
            script.write_text(text)
        self.moddir = self.tmp / "system/lib/modules/p2p-test-kernel/updates/cmpunlocker"
        (self.moddir.parents[1] / "build").mkdir(parents=True)
        (self.tmp / "system/proc").mkdir(parents=True)
        (self.tmp / "system/proc/modules").write_text("")
        self.conf = self.tmp / "system/etc/modprobe.d/cmp-pcie-gen2.conf"
        bindir = self.tmp / "bin"
        bindir.mkdir()
        for cmd in ("uname", "patch", "make", "modprobe", "modinfo", "systemctl",
                    "depmod", "update-initramfs", "lspci", "nvidia-smi", "dkms", "curl"):
            path = bindir / cmd
            path.write_text("#!" + sys.executable + "\n" + MOCK)
            path.chmod(0o755)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("CMPUNLOCKER_")}
        self.version = (ROOT / "driver/VERSION").read_text().splitlines()[0]
        self.env.update(PATH=str(bindir) + os.pathsep + os.environ["PATH"],
                        TEST_ROOT=str(self.tmp), TEST_VERSION=self.version,
                        CMPUNLOCKER_TEST_EUID="0", NO_COLOR="1")
        self.build_root = self.project / "driver/.build"
        self.build_root.mkdir()
        self.src_name = "open-gpu-kernel-modules-" + self.version
        source = self.tmp / "archive" / self.src_name
        gsp = source / "src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c"
        gsp.parent.mkdir(parents=True)
        # Simulates the result of the original unlock patch sequence. The
        # optional patches themselves are tested with real patch below.
        gsp.write_text("\n".join((
            "SEC2_POSTBL_TIMING_CMP_170HX_8GB_PCI_DEVICE_ID",
            "SEC2_POSTBL_TIMING_CMP_170HX_10GB_PCI_DEVICE_ID",
            "0x02779000U 0x02669000U",
            "0x0000001000000000ULL 0x0000000A00000000ULL")) + "\n")
        with tarfile.open(self.build_root / (self.src_name + ".tar.gz"), "w:gz") as tar:
            tar.add(source, arcname=self.src_name)

    def run_script(self, script="driver/build.sh", args=(), **env):
        merged = dict(self.env, **env)
        return subprocess.run(["bash", str(self.project / script), *args],
                              env=merged, text=True, capture_output=True, timeout=30)

    def events(self, clear=False):
        path = self.tmp / "events.jsonl"
        events = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
        if clear:
            path.write_text("")
        return events

    def successful_build(self, value=None, **env):
        if value is not None:
            env["CMPUNLOCKER_ENABLE_P2P"] = value
        result = self.run_script(**env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return self.events(clear=True)

    def test_default_and_empty_disable_all_p2p_patches(self):
        events = self.successful_build()
        self.assertEqual(sum(e["cmd"] == "patch" for e in events), 11)
        self.assertEqual((self.moddir / "p2p_enabled").read_text(), "0\n")
        self.assertEqual(self.conf.read_text(),
                         'options nvidia NVreg_RegistryDwords="RmForceEnableGen2=1;RMPcieLinkSpeed=0x1"\n')
        self.assertFalse(any(e["cmd"] == "patch" for e in self.successful_build("")))

    def test_toggle_invalidates_cache_and_config_precedes_initramfs(self):
        self.successful_build("0")
        stamp = self.build_root / self.src_name / ".cmpunlocker-stamp"
        disabled_stamp = stamp.read_text()
        events = self.successful_build("1")
        patches = [e for e in events if e["cmd"] == "patch"]
        self.assertEqual(len(patches), 15)
        for event, name in zip(patches[-4:], P2P_NAMES):
            data = (self.project / "driver/patches/p2p" / name).read_bytes()
            self.assertEqual(event["sha256"], hashlib.sha256(data).hexdigest())
            self.assertIn("--fuzz=0", event["args"])
        self.assertNotEqual(stamp.read_text(), disabled_stamp)
        self.assertEqual((self.moddir / "p2p_enabled").read_text(), "1\n")
        init = next(e for e in events if e["cmd"] == "update-initramfs")
        self.assertIn(";RMForceStaticBar1=1;RMPcieP2PType=1", init["config"])
        self.assertFalse(any(e["cmd"] == "modprobe" for e in events))
        self.assertFalse(any(e["cmd"] == "patch" for e in self.successful_build("1")))
        events = self.successful_build("0")
        self.assertEqual(sum(e["cmd"] == "patch" for e in events), 11)
        self.assertEqual(stamp.read_text(), disabled_stamp)
        self.assertNotIn("P2P", self.conf.read_text())
        self.assertNotIn("StaticBar1", self.conf.read_text())
        self.assertFalse(any(e["cmd"] == "modprobe" for e in events))

    def test_patch_edit_invalidates_cached_build(self):
        self.successful_build("1")
        patch = self.project / "driver/patches/p2p/0011-p2p-bar1.patch"
        patch.write_text("Fixture revision\n" + patch.read_text())
        events = self.successful_build("1")
        self.assertEqual(sum(e["cmd"] == "patch" for e in events), 15)

    def test_failed_patch_never_installs_or_stamps_partial_build(self):
        result = self.run_script(CMPUNLOCKER_ENABLE_P2P="1",
                                 FAIL_PATCH="skipping mailbox peer pre-registration")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.build_root / self.src_name / ".cmpunlocker-stamp").exists())
        self.assertFalse(self.conf.exists())
        self.assertFalse((self.moddir / "p2p_enabled").exists())
        self.assertFalse(any(e["cmd"] == "make" for e in self.events(clear=True)))
        events = self.successful_build("1")
        self.assertEqual(sum(e["cmd"] == "patch" for e in events), 15)

    def test_installer_flag_is_authoritative_and_preserves_mixed_inventory(self):
        options = ["--no-iommu", "--no-gen2-service", "--no-passthrough"]
        result = self.run_script("install.sh", options, CMPUNLOCKER_ENABLE_P2P="1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.moddir / "p2p_enabled").read_text(), "0\n")
        result = self.run_script("install.sh", options + ["--p2p", "--profile=10gb"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.moddir / "p2p_enabled").read_text(), "1\n")
        self.assertEqual((self.moddir / "card_profile").read_text(), "mixed\n")
        self.assertIn("20c2 8gb 65536", (self.moddir / "gpu_inventory").read_text())
        self.assertIn("2082 10gb 40960", (self.moddir / "gpu_inventory").read_text())
        self.assertIn("RMForceStaticBar1=1", self.conf.read_text())
        self.assertIn("--p2p", self.run_script("install.sh", ["--help"]).stdout)

    def test_initramfs_failure_reports_incomplete_p2p_install(self):
        result = self.run_script(CMPUNLOCKER_ENABLE_P2P="1", FAIL_INITRAMFS="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("initramfs was not rebuilt", result.stderr)
        self.assertNotIn("initramfs rebuilt", result.stdout)
        self.assertTrue(self.conf.exists())
        self.assertEqual((self.moddir / "p2p_enabled").read_text(), "1\n")
        self.assertFalse(any(e["cmd"] == "modprobe" for e in self.events(clear=True)))
        self.successful_build("1")

    def test_invalid_feature_values_fail_before_build(self):
        for value in ("2", "-1", "false", "on"):
            with self.subTest(value=value):
                result = self.run_script(CMPUNLOCKER_ENABLE_P2P=value)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("must be 0 or 1", result.stderr)
        self.assertFalse(self.conf.exists())
        self.assertFalse(any(e["cmd"] in ("patch", "make") for e in self.events()))

    def test_all_profiles_and_missing_optional_patch_manifest(self):
        for profile in ("8gb", "10gb", "mixed"):
            self.successful_build("1", CMPUNLOCKER_CARD_PROFILE=profile)
            self.assertEqual((self.moddir / "card_profile").read_text().strip(), profile)
        (self.project / "driver/patches/p2p/0011-p2p-bar1.patch").unlink()
        result = self.run_script(CMPUNLOCKER_ENABLE_P2P="0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("optional P2P patch missing", result.stderr)

    @unittest.skipUnless(shutil.which("patch"), "patch required for fixture composition")
    def test_p2p_patches_apply_without_disabled_debug_patches(self):
        directory = ROOT / "driver/patches"
        patches = [directory / "bar0-pramin-clamp.patch"]
        patches += [directory / "p2p" / name for name in P2P_NAMES]
        contexts = {}
        for patch in patches:
            for target, start, old, _ in hunks(patch):
                positions = contexts.setdefault(target, {})
                for offset, line in enumerate(old, start):
                    if offset in positions:
                        self.assertEqual(positions[offset], line)
                    positions[offset] = line
        fixture = self.tmp / "patch-context-fixture"
        for target, positions in contexts.items():
            file = fixture / target
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text("".join(positions.get(i, f"/* context gap {i} */\n")
                                    for i in range(1, max(positions) + 1)))
        for patch in patches:
            result = subprocess.run(["patch", "--batch", "--forward", "--fuzz=0", "-p1"],
                                    input=patch.read_text(), cwd=fixture,
                                    text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, str(patch) + result.stdout + result.stderr)
        text = (fixture / "src/nvidia/src/kernel/platform/p2p/p2p_caps.c").read_text()
        self.assertIn("forcing read cap OK", text)
        self.assertNotIn("hostsys commonSwitch=", text)

    @unittest.skipUnless(shutil.which("gcc"), "gcc required for isolated C guard check")
    def test_cmp_capability_guards(self):
        # Compile the inserted C blocks with minimal types and exercise the
        # actual device-ID guards, preserving arbitrary stock status values.
        def additions(name):
            lines = (ROOT / "driver/patches/p2p" / name).read_text().splitlines()
            return "\n".join(line[1:] for line in lines
                             if line.startswith("+") and not line.startswith("+++"))
        source = '''#include <assert.h>
typedef unsigned NvU32;
typedef struct { struct { NvU32 PCIDeviceID; } idInfo;
                 NvU32 pcieP2PReadCaps, pcieP2PWriteCaps; } OBJGPU;
#define NV0000_P2P_CAPS_STATUS_OK 0
#define NV_PRINTF(...) ((void)0)
void caps(OBJGPU *pGpu) {
''' + additions("0007-p2p-caps.patch") + '''
}
void readcap(OBJGPU *pGpu, NvU32 *pP2PReadCapStatus) {
''' + additions("0015-bar1p2p-readcap-override.patch") + '''
}
int main(void) {
    unsigned ids[] = {0x20c2, 0x2082, 0x20b0, 0x1234};
    for (unsigned i = 0; i < 4; ++i) {
        OBJGPU gpu = {{(ids[i] << 16) | 0x10de}, 7, 9};
        NvU32 status = 3;
        caps(&gpu); readcap(&gpu, &status);
        assert(gpu.pcieP2PReadCaps == (i < 2 ? 0 : 7));
        assert(gpu.pcieP2PWriteCaps == (i < 2 ? 0 : 9));
        assert(status == (i < 2 ? 0 : 3));
        status = 0; readcap(&gpu, &status); assert(status == 0);
    }
    return 0;
}
'''
        file = self.tmp / "guards.c"
        file.write_text(source)
        binary = self.tmp / "guards"
        result = subprocess.run(["gcc", "-std=c99", "-Wall", "-Wextra", "-Werror",
                                 str(file), "-o", str(binary)], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        subprocess.run([str(binary)], check=True, timeout=10)


if __name__ == "__main__":
    unittest.main()
