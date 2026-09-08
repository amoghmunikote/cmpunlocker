#!/usr/bin/env python3
"""Prepare and build the C0330C trial without installation or GPU access."""
import argparse
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
import urllib.request

VERSION = '610.43.02'
KERNEL = '7.0.0-31-generic'
ARCHIVE_SHA = '62fbbe29527e30be32cb38b30dfad2e94db1ca87f77a58090e563c7669857e60'


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def run(args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-archive', type=Path, help='Optional cached NVIDIA archive; SHA-256 must match')
    parser.add_argument('--output-parent', type=Path, required=True, help='Existing writable directory for a fresh build')
    parser.add_argument('--prepare-only', action='store_true', help='Patch and test source only; permits macOS, never compiles modules')
    parser.add_argument('--patch', default='patch', help='Patch executable; GNU patch recommended')
    args = parser.parse_args()
    if sys.version_info < (3, 12):
        parser.error('Python 3.12 or newer is required')
    if os.geteuid() == 0:
        parser.error('Run without sudo/root')
    if not args.prepare_only:
        if sys.platform != 'linux' or os.uname().machine != 'x86_64' or os.uname().release != KERNEL:
            parser.error(f'This trial build requires Linux x86_64 running {KERNEL}')
        if not Path(f'/lib/modules/{KERNEL}/build/Makefile').is_file():
            parser.error('Matching kernel headers are missing')
    repo = Path(__file__).resolve().parents[2]
    build_text = (repo / 'driver/build.sh').read_text()
    order = re.search(r'PATCH_ORDER=\(\n(.*?)\n\)', build_text, re.S).group(1).split()
    if order.count('c0330c-geometry-checks.patch') != 1:
        parser.error('Expected C0330C patch exactly once in build order')
    names = ['driver/build.sh', 'driver/VERSION', 'common/constants.yaml',
             'common/lib.sh', 'tools/read-constants.py', 'tools/gsp-restore.py',
             'driver/passthrough/cmp_no_bus_reset.c', 'tools/passthrough.sh',
             'tools/passthrough-arm.sh']
    names += ['driver/patches/' + name for name in order]
    names += [str(p.relative_to(repo)) for p in sorted((repo / 'tests/c0330c').glob('*')) if p.is_file()]
    for command in ['git', args.patch, 'cc'] + ([] if args.prepare_only else ['make', 'gcc', 'modinfo']):
        if not shutil.which(command):
            parser.error(f'Missing required command: {command}')
    run([sys.executable, '-c', 'import yaml'])
    out = Path(tempfile.mkdtemp(prefix='cmp-c0330c-build-', dir=args.output_parent.resolve()))
    print(f'Build workspace: {out}', flush=True)
    snapshot = out / 'inputs'
    hashes = {name: sha(repo / name) for name in names}
    for name in names:
        target = snapshot / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(repo / name, target)
        if sha(target) != hashes[name] or sha(repo / name) != hashes[name]:
            raise RuntimeError('Source changed while snapshotting; restart from a stable checkout')
    manifest = ''.join(f'{hashes[name]}  {name}\n' for name in sorted(hashes))
    (out / 'INPUT_SHA256SUMS').write_text(manifest)
    # The parent commit alone does not identify an uncommitted PR working tree.
    metadata = {
        'status': 'PREPARING', 'driver_version': VERSION, 'target_kernel': KERNEL,
        'git_base': run(['git', '-C', str(repo), 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip(),
        'input_manifest_sha256': sha(out / 'INPUT_SHA256SUMS'),
        'source_archive_sha256': ARCHIVE_SHA, 'modules_built': False,
        'modules_installed': False, 'hardware_tested': False,
    }
    receipt = out / 'result.json'
    receipt.write_text(json.dumps(metadata, indent=2) + '\n')
    run([sys.executable, str(snapshot / 'tools/read-constants.py'),
         str(snapshot / 'common/constants.yaml'), str(snapshot / 'driver/patches'),
         str(snapshot / 'driver/build.sh'), '8gb'])
    archive = out / 'nvidia-source.tar.gz'
    if args.source_archive:
        shutil.copyfile(args.source_archive, archive)
    else:
        url = f'https://github.com/NVIDIA/open-gpu-kernel-modules/archive/refs/tags/{VERSION}.tar.gz'
        with urllib.request.urlopen(url, timeout=120) as response, archive.open('wb') as target:
            shutil.copyfileobj(response, target)
    if sha(archive) != ARCHIVE_SHA:
        raise RuntimeError('NVIDIA archive checksum mismatch')
    with tarfile.open(archive) as package:
        package.extractall(out, filter='data')
    source = out / f'open-gpu-kernel-modules-{VERSION}'
    for name in order:
        run([args.patch, '--batch', '--forward', '--fuzz=0', '-p1', '-d', str(source),
             '-i', str(snapshot / 'driver/patches' / name)])
    gsp = source / 'src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c'
    # Same runtime device-ID geometry as driver/build.sh, without its install path.
    for marker in ['0x02779000U', '0x02669000U', '0x0000001000000000ULL',
                   '0x0000000A00000000ULL', 'CMP_C0330C_R1 helpers begin']:
        if marker not in gsp.read_text():
            raise RuntimeError('Runtime geometry changed; review before building')
    run([sys.executable, '-B', str(snapshot / 'tests/c0330c/replay_candidate.py'), str(gsp)])
    metadata['patched_kernel_gsp_sha256'] = sha(gsp)
    if args.prepare_only:
        metadata['status'] = 'SOURCE_CHECKS_PASS'
    else:
        metadata['status'] = 'BUILDING'
        receipt.write_text(json.dumps(metadata, indent=2) + '\n')
        with (out / 'build.log').open('w') as log:
            run(['make', '-C', str(source), '-j4', 'modules', f'SYSSRC=/lib/modules/{KERNEL}/build', 'CC=gcc'],
                stdout=log, stderr=subprocess.STDOUT)
        modules = {}
        for name in ['nvidia', 'nvidia-modeset', 'nvidia-uvm', 'nvidia-drm', 'nvidia-peermem']:
            path = source / 'kernel-open' / (name + '.ko')
            version = run(['modinfo', '-F', 'version', str(path)], capture_output=True, text=True).stdout.strip()
            vermagic = run(['modinfo', '-F', 'vermagic', str(path)], capture_output=True, text=True).stdout.strip()
            if version != VERSION or vermagic.split()[0] != KERNEL:
                raise RuntimeError(f'Wrong version/kernel for {name}')
            modules[name] = {'sha256': sha(path), 'vermagic': vermagic, 'path': str(path)}
        metadata.update(status='BUILD_ONLY_PASS', modules_built=True, modules=modules,
                        build_log_sha256=sha(out / 'build.log'))
    # Recheck the snapshot whose identity will accompany the build receipt.
    if any(sha(snapshot / name) != digest for name, digest in hashes.items()):
        raise RuntimeError('Build inputs changed during validation')
    receipt.write_text(json.dumps(metadata, indent=2) + '\n')
    print(f'{metadata["status"]}: {receipt}\nNothing installed; no GPU workload started.', flush=True)


if __name__ == '__main__':
    main()
