#!/usr/bin/env python3
"""Apply the full patch stack to a temporary source copy and replay C0330C checks.

Pass a pristine extracted NVIDIA source tree. Does not build/install a driver
or access hardware. Requires Python 3, patch and a C compiler with ASan/UBSan.
"""
import argparse
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('source', type=Path)
parser.add_argument('--patch', default='patch', help='patch executable (e.g. GNU patch)')
args = parser.parse_args()
repo = Path(__file__).resolve().parents[2]
gsp = Path('src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c')
if not (args.source / gsp).is_file():
    parser.error('source must be an extracted NVIDIA source tree')
order = re.search(r'PATCH_ORDER=\(\n(.*?)\n\)',
                  (repo / 'driver/build.sh').read_text(), re.S).group(1).split()
with tempfile.TemporaryDirectory(prefix='cmp-c0330c-check-') as tmp:
    source = Path(tmp) / 'source'
    shutil.copytree(args.source, source)
    for name in order:
        subprocess.run([args.patch, '--batch', '--forward', '--fuzz=0', '-p1',
                        '-d', str(source), '-i', str(repo / 'driver/patches' / name)],
                       check=True)
    subprocess.run([sys.executable, '-B', str(Path(__file__).with_name('replay_candidate.py')),
                    str(source / gsp)], check=True)
