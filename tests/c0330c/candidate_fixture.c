/* Synthetic registers only. No /dev, PCI, firmware or driver access. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef uint32_t NvU32;
typedef unsigned long long NvU64;
typedef uint8_t NvBool;
typedef int NV_STATUS;
#define NV_OK 0
#define NV_ERR_INVALID_STATE 1
#define NV_TRUE 1
#define NV_FALSE 0
#define SEC2_POSTBL_TIMING_CMP_170HX_8GB_PCI_DEVICE_ID 0x20C2U
#define SEC2_POSTBL_TIMING_CMP_170HX_10GB_PCI_DEVICE_ID 0x2082U
#define NV2080_CTRL_CMD_FB_GET_FB_REGION_INFO_MAX_ENTRIES 16

typedef struct {
    NvU64 base, limit, reserved;
    NvU32 performance;
    NvBool supportCompressed, supportISO;
} NV2080_CTRL_CMD_FB_GET_FB_REGION_FB_REGION_INFO;
typedef struct {
    NvU32 numFBRegions;
    NV2080_CTRL_CMD_FB_GET_FB_REGION_FB_REGION_INFO fbRegion[16];
} NV2080_CTRL_CMD_FB_GET_FB_REGION_INFO_PARAMS;
typedef struct {
    NvU64 fb_length;
    NV2080_CTRL_CMD_FB_GET_FB_REGION_INFO_PARAMS fbRegionInfoParams;
} GspStaticConfigInfo;
typedef struct { GspStaticConfigInfo gspStaticInfo; } KernelGsp;
typedef struct {
    struct { NvU32 PCIDeviceID; } idInfo;
    NvU32 boot, fbp, mask, fbio, lmr;
    NvU32 broadcast_cfg, broadcast_mib, broadcast_hbm;
    NvU32 cfg[24], mib[24], hbm[24];
    NvU32 writes[8], values[8], write_count, candidate_mib;
    int dropped_cfg_index, drop_lmr;
    NvU32 read_count[24];
} OBJGPU;

static const unsigned active[] = {0,1,4,5,6,7,10,11,14,15,16,17,18,19,20,21};
static unsigned checks, scenarios;
#define CHECK(test) do { checks++; if (!(test)) { \
    fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #test); exit(1); } } while (0)
static void fixture_log(const char *format, ...) { (void)format; }
#define NV_PRINTF(level, ...) fixture_log(__VA_ARGS__)

static OBJGPU fresh(void) {
    OBJGPU gpu;
    memset(&gpu, 0, sizeof(gpu));
    gpu.idInfo.PCIDeviceID = 0x20C210DEU;
    gpu.boot = 0x170000a1U;
    gpu.fbp = 0x852U;
    gpu.mask = gpu.fbio = 0x00c0330cU;
    gpu.lmr = 0x208U;
    gpu.broadcast_cfg = 0x02449000U;
    gpu.broadcast_mib = 0x200U;
    gpu.broadcast_hbm = 0xa7U;
    gpu.candidate_mib = 0x1000U;
    gpu.dropped_cfg_index = -1;
    for (unsigned i = 0; i < 24; i++) {
        gpu.cfg[i] = 0x02449000U;
        gpu.mib[i] = 0x200U;
        gpu.hbm[i] = 0xa7U;
    }
    return gpu;
}

static KernelGsp stock_info(void) {
    KernelGsp gsp;
    memset(&gsp, 0, sizeof(gsp));
    /* Actual user-supplied stock GSP trace, not inferred from candidate code. */
    gsp.gspStaticInfo.fb_length = 0x200000000ULL;
    gsp.gspStaticInfo.fbRegionInfoParams.numFBRegions = 5;
    gsp.gspStaticInfo.fbRegionInfoParams.fbRegion[4].base = 0x1f7800000ULL;
    gsp.gspStaticInfo.fbRegionInfoParams.fbRegion[4].limit = 0x1ffffffffULL;
    gsp.gspStaticInfo.fbRegionInfoParams.fbRegion[4].reserved = 0x8800000ULL;
    return gsp;
}

static NvU32 rd(OBJGPU *gpu, NvU32 address) {
    switch (address) {
        case 0: return gpu->boot;
        case 0x00820364U: return gpu->fbp;
        case 0x00820368U: return gpu->mask;
        case 0x0082036cU: return gpu->fbio;
        case 0x00100ce0U: return gpu->lmr;
        case 0x009a0204U: return gpu->broadcast_cfg;
        case 0x009a020cU: return gpu->broadcast_mib;
        case 0x009a038cU: return gpu->broadcast_hbm;
        case 0x0082381cU: return 0x88888888U;
        case 0x00823820U: return 8;
    }
    if (address >= 0x900000U && address < 0x960000U) {
        NvU32 i = (address - 0x900000U) / 0x4000U;
        NvU32 offset = (address - 0x900000U) % 0x4000U;
        CHECK(!(gpu->mask & (1U << i))); /* Disabled apertures must never be read. */
        gpu->read_count[i]++;
        if (offset == 0x204U) return gpu->cfg[i];
        if (offset == 0x20cU) return gpu->mib[i];
        if (offset == 0x38cU) return gpu->hbm[i];
    }
    fprintf(stderr, "Unexpected MMIO read 0x%x\n", address);
    exit(2);
}

static void wr(OBJGPU *gpu, NvU32 address, NvU32 value) {
    /* These compute writes already exist upstream; never count as geometry. */
    if (address == 0x0082381cU || address == 0x00823820U) return;
    CHECK(gpu->write_count < 8);
    gpu->writes[gpu->write_count] = address;
    gpu->values[gpu->write_count++] = value;
    if (address == 0x009a0204U) {
        gpu->broadcast_cfg = value;
        gpu->broadcast_mib = gpu->candidate_mib;
        for (unsigned i = 0; i < 24; i++) {
            if ((gpu->mask & (1U << i)) || (int)i == gpu->dropped_cfg_index) continue;
            gpu->cfg[i] = value;
            gpu->mib[i] = gpu->candidate_mib;
        }
    } else if (address == 0x00100ce0U) {
        if (!gpu->drop_lmr) gpu->lmr = value;
    } else {
        fprintf(stderr, "Forbidden MMIO write 0x%x\n", address);
        exit(2); /* Including rank, floorsweep and per-instance geometry writes. */
    }
}
#define GPU_REG_RD32(gpu, address) rd(gpu, address)
#define GPU_REG_WR32(gpu, address, value) wr(gpu, address, value)

/* DRIVER_CODE */

static void success(void) {
    OBJGPU gpu = fresh();
    KernelGsp gsp = stock_info();
    NvBool ready = NV_FALSE;
    CHECK(geometry(&gpu, &ready) == NV_OK);
    CHECK(ready);
    CHECK(gpu.write_count == 2);
    CHECK(gpu.writes[0] == 0x009a0204U && gpu.values[0] == 0x02779000U);
    CHECK(gpu.writes[1] == 0x00100ce0U && gpu.values[1] == 0x20bU);
    CHECK(publish(&gpu, ready, &gsp) == NV_OK);
    CHECK(gsp.gspStaticInfo.fb_length == 0x1000000000ULL);
    CHECK(gsp.gspStaticInfo.fbRegionInfoParams.fbRegion[4].limit == 0xfffffffffULL);
    CHECK(gpu.write_count == 2); /* Publication cannot change registers. */
    for (unsigned n = 0; n < sizeof(active)/sizeof(active[0]); n++)
        CHECK(gpu.read_count[active[n]] >= 12); /* Four complete three-register passes. */
    scenarios++;
}

static void preflight_failures(void) {
    for (unsigned n = 0; n < sizeof(active)/sizeof(active[0]); n++) {
        for (unsigned kind = 0; kind < 4; kind++) {
            OBJGPU gpu = fresh();
            NvBool ready = NV_TRUE; /* A previous attempt cannot donate readiness. */
            if (kind == 0) gpu.cfg[active[n]] ^= 0x100U;
            if (kind == 1) gpu.mib[active[n]] = 0x800U;
            if (kind == 2) gpu.hbm[active[n]] = 0xa6U;
            if (kind == 3) gpu.cfg[active[n]] = 0xbadf1100U;
            CHECK(geometry(&gpu, &ready) == NV_ERR_INVALID_STATE);
            CHECK(!ready && gpu.write_count == 0);
            scenarios++;
        }
    }
    for (unsigned kind = 0; kind < 6; kind++) {
        OBJGPU gpu = fresh();
        NvBool ready = NV_FALSE;
        if (kind == 0) gpu.idInfo.PCIDeviceID = 0x20c21234U;
        if (kind == 1) gpu.boot ^= 1U;
        if (kind == 2) gpu.fbp ^= 1U;
        if (kind == 3) gpu.fbio ^= 1U;
        if (kind == 4) gpu.lmr = 0x20bU;
        if (kind == 5) gpu.boot = 0xffffffffU;
        CHECK(geometry(&gpu, &ready) == NV_ERR_INVALID_STATE);
        CHECK(!ready && gpu.write_count == 0);
        scenarios++;
    }
}

static void write_failures(void) {
    for (unsigned n = 0; n < sizeof(active)/sizeof(active[0]); n++) {
        OBJGPU gpu = fresh();
        NvBool ready = NV_FALSE;
        gpu.dropped_cfg_index = (int)active[n];
        CHECK(geometry(&gpu, &ready) == NV_ERR_INVALID_STATE);
        CHECK(!ready && gpu.write_count == 1 && gpu.lmr == 0x208U);
        scenarios++;
    }
    {
        OBJGPU gpu = fresh();
        NvBool ready = NV_FALSE;
        gpu.candidate_mib = 0x800U; /* Real geometry limit might be 32 GiB. */
        CHECK(geometry(&gpu, &ready) == NV_ERR_INVALID_STATE);
        CHECK(!ready && gpu.write_count == 1 && gpu.lmr == 0x208U);
        scenarios++;
    }
    {
        OBJGPU gpu = fresh();
        NvBool ready = NV_FALSE;
        gpu.drop_lmr = 1;
        CHECK(geometry(&gpu, &ready) == NV_ERR_INVALID_STATE);
        CHECK(!ready && gpu.write_count == 2 && gpu.lmr == 0x208U);
        scenarios++;
    }
}

static void expect_no_publish(OBJGPU *gpu, NvBool ready, KernelGsp *gsp) {
    KernelGsp before = *gsp;
    NvU32 writes = gpu->write_count;
    CHECK(publish(gpu, ready, gsp) == NV_ERR_INVALID_STATE);
    CHECK(memcmp(gsp, &before, sizeof(*gsp)) == 0);
    CHECK(gpu->write_count == writes);
    scenarios++;
}

static void handoff_failures(void) {
    for (unsigned n = 0; n < sizeof(active)/sizeof(active[0]); n++) {
        for (unsigned kind = 0; kind < 3; kind++) {
            OBJGPU gpu = fresh();
            KernelGsp gsp = stock_info();
            NvBool ready;
            CHECK(geometry(&gpu, &ready) == NV_OK);
            if (kind == 0) gpu.cfg[active[n]] = 0x02449000U;
            if (kind == 1) gpu.mib[active[n]] = 0x200U;
            if (kind == 2) gpu.hbm[active[n]] = 0xa6U;
            expect_no_publish(&gpu, ready, &gsp);
        }
    }
    for (unsigned kind = 0; kind < 8; kind++) {
        OBJGPU gpu = fresh();
        KernelGsp gsp = stock_info();
        NvBool ready;
        CHECK(geometry(&gpu, &ready) == NV_OK);
        if (kind == 0) ready = NV_FALSE;
        if (kind == 1) gpu.mask = 0x003fc000U; /* Must not fall into legacy allowlist. */
        if (kind == 2) gpu.fbio ^= 1U;
        if (kind == 3) gpu.lmr = 0x208U;
        if (kind == 4) gpu.mask = 0xffffffffU;
        if (kind == 5) gpu.broadcast_cfg = 0x02449000U;
        if (kind == 6) gpu.broadcast_mib = 0x200U;
        if (kind == 7) gpu.broadcast_hbm = 0xa6U;
        expect_no_publish(&gpu, ready, &gsp);
    }
    for (unsigned kind = 0; kind < 6; kind++) {
        OBJGPU gpu = fresh();
        KernelGsp gsp = stock_info();
        NvBool ready;
        CHECK(geometry(&gpu, &ready) == NV_OK);
        if (kind == 0) gsp.gspStaticInfo.fbRegionInfoParams.numFBRegions = 0;
        if (kind == 1) gsp.gspStaticInfo.fbRegionInfoParams.numFBRegions = 17;
        if (kind == 2) gsp.gspStaticInfo.fb_length = 0x800000000ULL;
        if (kind == 3) gsp.gspStaticInfo.fbRegionInfoParams.fbRegion[4].reserved--;
        if (kind == 4) gsp.gspStaticInfo.fbRegionInfoParams.fbRegion[4].limit--;
        if (kind == 5) gsp.gspStaticInfo.fbRegionInfoParams.fbRegion[4].base = 0x200000000ULL;
        expect_no_publish(&gpu, ready, &gsp);
    }
}

static void isolation_and_legacy(void) {
    const NvU32 masks[] = {0x003fc000U, 0x00000cf3U, 0x003fc000U, 0x00c0330dU};
    const NvU32 ids[] = {0x20c210deU, 0x20c210deU, 0x208210deU, 0x20c210deU};
    const NvU32 cfgs[] = {0x02779000U, 0x02779000U, 0x02669000U, 0x02779000U};
    const NvU32 lmrs[] = {0x20bU, 0x20aU, 0x28aU, 0x20bU};
    const NvU64 sizes[] = {65536, 32768, 40960, 65536};
    for (unsigned n = 0; n < 4; n++) {
        OBJGPU gpu = fresh();
        KernelGsp gsp = stock_info();
        NvBool ready = NV_TRUE;
        gpu.mask = masks[n];
        gpu.idInfo.PCIDeviceID = ids[n];
        CHECK(geometry(&gpu, &ready) == NV_OK);
        CHECK(!ready);
        CHECK(gpu.broadcast_cfg == cfgs[n] && gpu.lmr == lmrs[n]);
        CHECK(publish(&gpu, ready, &gsp) == NV_OK);
        CHECK(gsp.gspStaticInfo.fb_length >> 20 == sizes[n]);
        CHECK(gpu.write_count == 2U);
        scenarios++;
    }
    {
        OBJGPU gpu = fresh(), display = fresh();
        KernelGsp gsp = stock_info(), display_gsp = stock_info();
        NvBool ready;
        display.idInfo.PCIDeviceID = 0xffff10deU; /* Non-CMP/display-GPU surrogate. */
        CHECK(geometry(&gpu, &ready) == NV_OK);
        CHECK(publish(&display, NV_FALSE, &display_gsp) == NV_OK);
        CHECK(display.write_count == 0 && display_gsp.gspStaticInfo.fb_length == 0x200000000ULL);
        CHECK(geometry(&display, &ready) == NV_OK && !ready);
        CHECK(display.write_count == 0);
        /* Neither a previous GPU nor a skipped preflight can authorize this one. */
        OBJGPU other = fresh();
        expect_no_publish(&other, ready, &gsp);
        CHECK(geometry(&gpu, &ready) == NV_ERR_INVALID_STATE); /* Warm repeat. */
        CHECK(!ready && gpu.write_count == 2);
        CHECK(!retry_after_geometry(NV_TRUE, NV_TRUE));
        CHECK(retry_after_geometry(NV_FALSE, NV_TRUE));
        scenarios++;
    }
}

int main(void) {
    success();
    preflight_failures();
    write_failures();
    handoff_failures();
    isolation_and_legacy();
    printf("PASS: %u synthetic scenarios, %u assertions; actual C guards, ASan/UBSan.\n", scenarios, checks);
    puts("Physical capacity, GSP boot and complete Linux module build remain untested.");
    return 0;
}
