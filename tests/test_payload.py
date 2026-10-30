import hashlib
import re
import shutil
import subprocess

import repo


def payload_source():
    patch = (repo.ROOT / "driver/patches/sec2-postbl-plm-ss-cfg.patch").read_text()
    return "\n".join(line[1:] for line in patch.splitlines()
                     if line.startswith("+") and not line.startswith("+++"))


def function(source, name):
    start = re.search(r"(?:static void|NV_STATUS)\n" + name + r"\(", source).start()
    end = source.index("\n}", start) + 2
    return source[start:end]


def test_payload_bounds(tmp_path):
    assert shutil.which("cc"), "a C compiler is required"
    source = payload_source()
    constants = "\n".join(re.findall(r"^#define SEC2_POSTBL_TIMING_(?:SIGNATURE_SIZE|FILL_DWORD)\s+.*$",
                                   source, re.M))
    functions = "\n".join(function(source, name) for name in (
        "_kgspSec2PostblTimingPutU32", "_kgspSec2PostblTimingFillPayload",
        "kgspSec2PostblTimingRefillPayload"))
    code = r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef uint8_t NvU8;
typedef uint32_t NvU32;
typedef uint64_t NvU64;
typedef int NV_STATUS;
typedef struct { int unused; } OBJGPU;
typedef struct { NvU64 size; NvU8 *data; } MEMORY_DESCRIPTOR;
typedef struct { NvU64 sysmemAddrOfSignature, sizeOfSignature; } WPR_META;
typedef struct {
    MEMORY_DESCRIPTOR *pSignatureMemdesc, *metaDesc;
    WPR_META *meta;
} KernelGsp;
#define NV_OK 0
#define NV_ERR_INVALID_STATE 1
#define NV_ERR_INSUFFICIENT_RESOURCES 2
#define TRANSFER_FLAGS_NONE 0
#define AT_GPU 0
#define NV_ASSERT_OR_RETURN_VOID(x) do { if (!(x)) return; } while (0)
#define SEC2_POSTBL_TIMING_WPR_META(k) ((k)->meta)
#define SEC2_POSTBL_TIMING_WPR_META_DESC(k) ((k)->metaDesc)
#define memdescGetSize(d) ((d)->size)
static unsigned maps, unmaps, flushes;
static NvU8 *memdescMapInternal(OBJGPU *g, MEMORY_DESCRIPTOR *d, int flags)
{ (void)g; (void)flags; maps++; return d->data; }
static void memdescUnmapInternal(OBJGPU *g, MEMORY_DESCRIPTOR *d, int flags)
{ (void)g; (void)d; (void)flags; unmaps++; }
static void memdescFlushCpuCaches(OBJGPU *g, MEMORY_DESCRIPTOR *d)
{ (void)g; (void)d; flushes++; }
static NvU64 memdescGetPhysAddr(MEMORY_DESCRIPTOR *d, int target, int offset)
{ (void)d; (void)target; (void)offset; return 0xabc000; }
'''
    main = r'''
static void unchanged(const NvU8 *data, size_t size)
{
    for (size_t i = 0; i < size; i++) assert(data[i] == 0xa5);
}
int main(void)
{
    const size_t sizes[] = {0, 1, 4096, SEC2_POSTBL_TIMING_SIGNATURE_SIZE - 1};
    OBJGPU gpu = {0};
    KernelGsp gsp = {0};
    assert(kgspSec2PostblTimingRefillPayload(&gpu, &gsp, 0, 0) == NV_ERR_INVALID_STATE);
    for (size_t i = 0; i < sizeof(sizes) / sizeof(sizes[0]); i++)
    {
        size_t allocated = sizes[i] ? sizes[i] : 1;
        NvU8 *data = malloc(allocated);
        assert(data);
        memset(data, 0xa5, allocated);
        _kgspSec2PostblTimingFillPayload(data, sizes[i], 0x9a0148, 0xffffffff);
        unchanged(data, allocated);
        MEMORY_DESCRIPTOR desc = {sizes[i], data};
        gsp.pSignatureMemdesc = &desc;
        assert(kgspSec2PostblTimingRefillPayload(&gpu, &gsp, 0, 0) == NV_ERR_INVALID_STATE);
        unchanged(data, allocated);
        free(data);
    }
    assert(maps == 0 && unmaps == 0 && flushes == 0);
    _kgspSec2PostblTimingFillPayload(NULL, SEC2_POSTBL_TIMING_SIGNATURE_SIZE, 0, 0);
    MEMORY_DESCRIPTOR desc = {SEC2_POSTBL_TIMING_SIGNATURE_SIZE, NULL};
    gsp.pSignatureMemdesc = &desc;
    assert(kgspSec2PostblTimingRefillPayload(&gpu, &gsp, 0, 0) == NV_ERR_INSUFFICIENT_RESOURCES);
    assert(maps == 1 && unmaps == 0 && flushes == 0);

    const size_t size = SEC2_POSTBL_TIMING_SIGNATURE_SIZE;
    NvU8 *data = malloc(size);
    NvU8 *larger = malloc(size + 32);
    assert(data && larger);
    desc.data = data;
    WPR_META meta = {0};
    MEMORY_DESCRIPTOR metaDesc = {sizeof(meta), (NvU8 *)&meta};
    gsp.meta = &meta;
    gsp.metaDesc = &metaDesc;
    assert(kgspSec2PostblTimingRefillPayload(&gpu, &gsp, 0x9a0148, 0xffffffff) == NV_OK);
    assert(maps == 2 && unmaps == 1 && flushes == 2);
    assert(meta.sysmemAddrOfSignature == 0xabc000 && meta.sizeOfSignature == size);
    assert(fwrite(data, 1, size, stdout) == size);
    memset(larger, 0xa5, size + 32);
    _kgspSec2PostblTimingFillPayload(larger, size + 32, 0x9a0148, 0xffffffff);
    assert(memcmp(data, larger, size) == 0);
    unchanged(larger + size, 32);
    _kgspSec2PostblTimingFillPayload(data, size, 0x1fa7cc, 0xfffff0ff);
    assert(fwrite(data, 1, size, stdout) == size);
    free(larger);
    free(data);
    return 0;
}
'''
    path = tmp_path / "payload.c"
    path.write_text(code + constants + "\n" + functions + main)
    binary = tmp_path / "payload"
    subprocess.run(["cc", "-std=c99", "-O1", "-g", "-Wall", "-Wextra", "-Werror",
                    "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                    str(path), "-o", str(binary)], check=True, capture_output=True)
    result = subprocess.run([str(binary)], capture_output=True)
    assert result.returncode == 0, result.stderr.decode()
    assert hashlib.sha256(result.stdout).hexdigest() == "5ddec711ac9c690c48a0ee67e199d871a3b4976f1ec652df85afff93cbbdb319"
