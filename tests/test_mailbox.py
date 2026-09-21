"""Exercise the actual patched C with mocked registers/RPCs, without hardware."""
import shutil
import subprocess

from test_patches import patched_source


def test_mailbox_restores_both_traps_on_success_and_failure(tmp_path):
    with patched_source("610.43.03", "mailbox") as src:
        code = (src / "src/nvidia/src/kernel/gpu/bus/arch/maxwell/kern_bus_gm200.c").read_text()
    helpers = code[code.index("#define CMP_REG_TRAP31_MATCH"):code.index("// Defines for PCIE P2P")]
    start = code.index("void\nkbusSetupMailboxes_GM200")
    setup = code[start:code.index("\nvoid\n", start + 1)]
    harness = r'''
#include <assert.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
typedef uint32_t NvU32;
typedef uint64_t NvU64;
typedef uint64_t RmPhysAddr;
typedef int NvBool;
typedef int NV_STATUS;
typedef void *PMEMORY_DESCRIPTOR;
typedef struct RM_API RM_API;
typedef struct {
    struct { NvU32 PCIDeviceID; } idInfo;
    NvU32 gpuId, hInternalClient, hInternalSubdevice, regs[7];
    RM_API *api;
} OBJGPU;
struct RM_API {
    NV_STATUS (*Control)(RM_API *, NvU32, NvU32, NvU32, void *, size_t);
    OBJGPU *gpu;
};
typedef struct {
    struct {
        struct {
            NvU32 remotePeerId;
            PMEMORY_DESCRIPTOR pRemoteWMBoxMemDesc, pRemoteP2PDomMemDesc;
        } busPeer[2];
        NvU64 writeMailboxBar1Addr;
    } p2pPcie;
} KernelBus;
typedef struct {
    NvU32 local2Remote, remote2Local;
    NvU64 localP2PDomainRemoteAddr, remoteP2PDomainLocalAddr, remoteWMBoxLocalAddr;
    NvU64 remoteWMBoxAddrU64, p2pWmbTag;
    NvBool bNeedWarBug999673;
} Params;
typedef Params NV2080_CTRL_CMD_INTERNAL_BUS_SETUP_P2P_MAILBOX_LOCAL_PARAMS;
typedef Params NV2080_CTRL_CMD_INTERNAL_BUS_SETUP_P2P_MAILBOX_REMOTE_PARAMS;
#define NV2080_CTRL_CMD_INTERNAL_BUS_SETUP_P2P_MAILBOX_LOCAL 0
#define NV2080_CTRL_CMD_INTERNAL_BUS_SETUP_P2P_MAILBOX_REMOTE 1
#define NV_TRUE 1
#define NV_FALSE 0
#define NV_OK 0
#define P2P_MAX_NUM_PEERS 2
#define PCIE_P2P_WRITE_MAILBOX_SIZE 65536
#define NV_PRINTF(...) ((void)0)
#define NV_ASSERT(c) assert(c)
#define NV_ASSERT_OR_RETURN_VOID(c) do { if (!(c)) return; } while (0)
#define GPU_GET_PHYSICAL_RMAPI(g) ((g)->api)
#define kbusNeedWarForBug999673_HAL(...) 0
#define kbusSetupMailboxAccess_HAL(...) 0x10000ULL
#define kbusSetupP2PDomainAccess_HAL(...) 0x20000ULL
static int fail_rpc, fail_write, controls, tags;
static int reg_index(NvU32 address) {
    assert(address >= 0x12247c && address <= 0x12277c);
    assert((address - 0x12247c) % 128 == 0);
    return (address - 0x12247c) / 128;
}
static NvU32 rd(OBJGPU *g, NvU32 address) { return g->regs[reg_index(address)]; }
static void wr(OBJGPU *g, NvU32 address, NvU32 value) {
    int i = reg_index(address);
    if (i == 2 && (int)g->gpuId == fail_write) {
        fail_write = -1; /* one failed arm write, then allow restoration */
        return;
    }
    g->regs[i] = value;
}
#define GPU_REG_RD32(g, a) rd(g, a)
#define GPU_REG_WR32(g, a, v) wr(g, a, v)
static int is_cmp(OBJGPU *g) {
    return (g->idInfo.PCIDeviceID >> 16) == 0x20c2 ||
           (g->idInfo.PCIDeviceID >> 16) == 0x2082;
}
static NV_STATUS control(RM_API *api, NvU32 client, NvU32 device, NvU32 cmd, void *ptr, size_t size) {
    OBJGPU *g = api->gpu;
    if (is_cmp(g)) {
        assert(g->regs[0] == 0x139000 && g->regs[1] == 0xfc000fff);
        assert(g->regs[2] == 0xc0000000 && g->regs[4] == 0x100000);
    }
    controls++;
    ((Params *)ptr)->p2pWmbTag = 123;
    return (int)g->gpuId == fail_rpc ? 1 : 0;
}
static void tag(OBJGPU *g, KernelBus *b, NvU32 peer, NvU64 value) {
    if (is_cmp(g)) assert(g->regs[4] == 0x100000);
    assert(value == 123);
    tags++;
}
#define kbusWriteP2PWmbTag_HAL tag
'''
    checks = r'''
static void check(int failure, int target, int noncmp) {
    OBJGPU g[2] = {0};
    KernelBus bus[2] = {0};
    RM_API api[2] = {0};
    NvU32 original[2][7];
    fail_rpc = failure == 1 ? target : -1;
    fail_write = failure == 2 ? target : -1;
    controls = tags = 0;
    for (int i = 0; i < 2; ++i) {
        g[i].gpuId = i;
        g[i].idInfo.PCIDeviceID = (noncmp ? 0x20b0U : i ? 0x2082U : 0x20c2U) << 16;
        for (int r = 0; r < 6; ++r) g[i].regs[r] = 0xabc + i*100 + r;
        g[i].regs[6] = failure == 3 && i == target ? 0 : 0xffffffffU;
        api[i].Control = control; api[i].gpu = &g[i]; g[i].api = &api[i];
        memcpy(original[i], g[i].regs, sizeof(original[i]));
    }
    kbusSetupMailboxes_GM200(&g[0], &bus[0], &g[1], &bus[1], 0, 0);
    for (int i = 0; i < 2; ++i)
        assert(memcmp(original[i], g[i].regs, sizeof(original[i])) == 0);
    assert(tags == (failure == 0 ? 1 : 0));
    if (failure == 0) assert(controls == 2);
    else if (failure == 1) assert(controls == target + 1);
    else assert(controls == target);
}
int main(void) {
    check(0, -1, 0); /* both CMP SKUs, complete setup */
    check(0, -1, 1); /* non-CMP registers untouched */
    for (int failure = 1; failure <= 3; ++failure)
        for (int gpu = 0; gpu < 2; ++gpu) check(failure, gpu, 0);
    return 0;
}
'''
    path = tmp_path / "mailbox.c"
    path.write_text(harness + helpers + setup + checks)
    compiler = shutil.which("cc") or shutil.which("clang")
    assert compiler, "C compiler required for the register/RPC failure test"
    subprocess.run([compiler, "-std=c99", str(path), "-o", str(tmp_path / "mailbox")], check=True)
    subprocess.run([str(tmp_path / "mailbox")], check=True)
