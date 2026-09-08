#!/usr/bin/env python3
"""Compile the candidate's real guard code with synthetic MMIO, never hardware.

This is not a complete Linux driver build or a simulation of GSP/physical HBM.
The baseline is accepted as input so missing C0330C checks can be demonstrated.
"""

import argparse
from pathlib import Path
import subprocess
import tempfile

def block_containing(source, marker):
    if source.count(marker) != 1:
        raise ValueError(f"Expected exactly one source marker: {marker}")
    start = source.rfind("{", 0, source.index(marker))
    depth = 0
    for index in range(start, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise ValueError("Unclosed source block")



def make_harness(source):
    begin = "/* CMP_C0330C_R1 helpers begin */"
    end = "/* CMP_C0330C_R1 helpers end */"
    helpers = ""
    if begin in source:
        if source.count(begin) != 1 or source.count(end) != 1:
            raise ValueError("Candidate helper markers changed")
        helpers = source[source.index(begin):source.index(end) + len(end)]
    geometry = block_containing(source, "NvU32 cfg1Value;")
    capacity = block_containing(source, "GspStaticConfigInfo *pGSCI = &pKernelGsp->gspStaticInfo;")
    gate_start = source.index("_kgspSec2PostblTimingEnabled(OBJGPU *pGpu)")
    gate_end = source.index("\n}", gate_start) + 2
    gate = "static NvBool\n" + source[gate_start:gate_end]
    retry = ""
    retry_marker = "/* The experimental geometry is a one-shot cold-boot trial. */"
    if helpers:
        retry_start = source.index(retry_marker)
        retry = source[retry_start:source.index("\n\n", retry_start)]
        # Check the per-invocation handoff, not just helpers in isolation.
        if source.count("*pbC0330cGeometryReady = NV_FALSE;") != 1:
            raise ValueError("Boot-attempt readiness must be reset exactly once")
        if source.count("&bC0330cGeometryReady);") != 1:
            raise ValueError("Expected exactly one boot-attempt handoff")
    wrappers = r'''
static NV_STATUS geometry(OBJGPU *pGpu, NvBool *pbC0330cGeometryReady) {
    NV_STATUS status = NV_OK;
    (void)status;
    *pbC0330cGeometryReady = NV_FALSE;
    if (_kgspSec2PostblTimingEnabled(pGpu))
GEOMETRY
    return NV_OK;
}
static NV_STATUS publish(OBJGPU *pGpu, NvBool bC0330cGeometryReady,
                         KernelGsp *pKernelGsp) {
    NV_STATUS status = NV_OK;
    NvU32 devId = pGpu->idInfo.PCIDeviceID >> 16;
    (void)bC0330cGeometryReady;
    if (devId == SEC2_POSTBL_TIMING_CMP_170HX_8GB_PCI_DEVICE_ID ||
        devId == SEC2_POSTBL_TIMING_CMP_170HX_10GB_PCI_DEVICE_ID)
CAPACITY
    goto done;
done:
    return status;
}
static NvBool retry_after_geometry(NvBool bC0330cGeometryReady, NvBool bRetry) {
    (void)bC0330cGeometryReady;
RETRY
    return bRetry;
}
'''.replace("GEOMETRY", geometry).replace("CAPACITY", capacity).replace("RETRY", retry)
    fixture = Path(__file__).with_name("candidate_fixture.c").read_text()
    return fixture.replace("/* DRIVER_CODE */", gate + helpers + wrappers)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="Patched kernel_gsp.c")
    args = parser.parse_args()
    harness = make_harness(args.source.read_text())
    with tempfile.TemporaryDirectory(prefix="cmp-c0330c-replay-") as directory:
        root = Path(directory)
        c_file = root / "candidate.c"
        executable = root / "candidate"
        c_file.write_text(harness)
        subprocess.run(["cc", "-std=c99", "-Wall", "-Wextra", "-Werror",
                        "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                        str(c_file), "-o", str(executable)], check=True)
        raise SystemExit(subprocess.run([str(executable)]).returncode)


if __name__ == "__main__":
    main()
