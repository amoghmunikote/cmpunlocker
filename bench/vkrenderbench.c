// Offscreen Vulkan rendering test for the headless CMP 90HX.
// Renders an NDC triangle (vertex shader) with a constant-orange fragment
// shader into a device-local VkImage via a render pass, copies it to a
// host-visible buffer, and verifies the pixels. No swapchain, no surface,
// no display. dlopen-based: builds without vulkan headers.
//
// usage: vkrenderbench <tri.spv> <solid.frag.spv> [instances] [frames]
// Times a fill-rate workload: vkCmdDraw(3, instances) x frames, one submit.
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <dlfcn.h>
#include <time.h>

#define W 256
#define H 256

typedef uint32_t u32; typedef int32_t i32; typedef uint64_t u64; typedef float f32;
typedef void* P;          // dispatchable handles
typedef u64 Hd;            // non-dispatchable handles

// ---- constants ----
#define ST_APPLICATION_INFO 0
#define ST_INSTANCE_CI 1
#define ST_DEVICE_QUEUE_CI 28
#define ST_DEVICE_CI 3
#define ST_MEM_ALLOC 5
#define ST_BUFFER_CI 12
#define ST_IMAGE_CI 14
#define ST_IMAGE_VIEW_CI 15
#define ST_SHADER_MODULE_CI 16
#define ST_SHADER_STAGE_CI 18
#define ST_VTX_INPUT_CI 19
#define ST_INPUT_ASM_CI 20
#define ST_VIEWPORT_CI 22
#define ST_RASTER_CI 23
#define ST_MULTISAMPLE_CI 24
#define ST_COLORBLEND_CI 26
#define ST_PIPELINE_LAYOUT_CI 30
#define ST_GRAPHICS_PIPELINE_CI 28
#define ST_FRAMEBUFFER_CI 37
#define ST_RENDERPASS_CI 38
#define ST_COMMAND_POOL_CI 39
#define ST_COMMAND_BUFFER_ALLOC 40
#define ST_COMMAND_BUFFER_BEGIN 42
#define ST_RENDERPASS_BEGIN 43
#define ST_IMAGE_MEM_BARRIER 44
#define ST_SUBMIT_INFO 4

#define FMT_RGBA8 37
#define LAYOUT_UNDEF 0
#define LAYOUT_COLOR_ATT 2
#define LAYOUT_TRANSFER_SRC 6
#define STAGE_COLOR_ATT_OUT 0x400
#define STAGE_TRANSFER 0x1000
#define ACCESS_COLOR_ATT_WRITE 0x100
#define ACCESS_TRANSFER_READ 0x800
#define QFAM_IGNORED 0xffffffffu

// ---- resolved symbols ----
static P vk;
#define RESOLVE(name) pvk##name = dlsym(vk, "vk"#name); if (!pvk##name) { fprintf(stderr, "missing vk%s\n", #name); return 1; }
static int (*pvkCreateInstance)(P, P, P);
static int (*pvkEnumeratePhysicalDevices)(P, u32*, P);
static void (*pvkGetPhysicalDeviceProperties)(P, P);
static void (*pvkGetPhysicalDeviceQueueFamilyProperties)(P, u32*, P);
static void (*pvkGetPhysicalDeviceMemoryProperties)(P, P);
static int (*pvkCreateDevice)(P, P, P, P);
static void (*pvkGetDeviceQueue)(P, u32, u32, P);
static int (*pvkCreateShaderModule)(P, P, P, Hd*);
static int (*pvkCreateRenderPass)(P, P, P, Hd*);
static int (*pvkCreateFramebuffer)(P, P, P, Hd*);
static int (*pvkCreateImage)(P, P, P, Hd*);
static void (*pvkGetImageMemoryRequirements)(P, Hd, P);
static int (*pvkAllocateMemory)(P, P, P, Hd*);
static int (*pvkBindImageMemory)(P, Hd, Hd, u64);
static int (*pvkCreateImageView)(P, P, P, Hd*);
static int (*pvkCreatePipelineLayout)(P, P, P, Hd*);
static int (*pvkCreateGraphicsPipelines)(P, Hd, u32, P, P, Hd*);
static int (*pvkCreateBuffer)(P, P, P, Hd*);
static void (*pvkGetBufferMemoryRequirements)(P, Hd, P);
static int (*pvkBindBufferMemory)(P, Hd, Hd, u64);
static int (*pvkCreateCommandPool)(P, P, P, Hd*);
static int (*pvkAllocateCommandBuffers)(P, P, P);
static int (*pvkBeginCommandBuffer)(P, P);
static void (*pvkCmdBeginRenderPass)(P, P, u32);
static void (*pvkCmdBindPipeline)(P, u32, Hd);
static void (*pvkCmdDraw)(P, u32, u32, u32, u32);
static void (*pvkCmdEndRenderPass)(P);
static void (*pvkCmdPipelineBarrier)(P, u32, u32, u32, u32, P, u32, P, u32, P);
static void (*pvkCmdCopyImageToBuffer)(P, Hd, u32, Hd, u32, P);
static int (*pvkEndCommandBuffer)(P);
static int (*pvkQueueSubmit)(P, u32, P, Hd);
static int (*pvkQueueWaitIdle)(P);
static int (*pvkMapMemory)(P, Hd, u64, u64, u32, P);
static void (*pvkUnmapMemory)(P, Hd);

static void* read_file(const char* path, size_t* sz)
{
    FILE* f = fopen(path, "rb");
    if (!f) { perror(path); exit(1); }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    void* b = malloc(n);
    if (fread(b, 1, n, f) != (size_t)n) { perror("read"); exit(1); }
    fclose(f); *sz = n; return b;
}

int main(int argc, char** argv)
{
    if (argc < 3) { fprintf(stderr, "usage: vkrenderbench tri.spv frag.spv [instances] [frames]\n"); return 2; }
    int instances = (argc > 3) ? atoi(argv[3]) : 2000;
    int frames = (argc > 4) ? atoi(argv[4]) : 400;
    vk = dlopen("libvulkan.so.1", RTLD_NOW);
    if (!vk) { fprintf(stderr, "no libvulkan: %s\n", dlerror()); return 1; }
    RESOLVE(CreateInstance); RESOLVE(EnumeratePhysicalDevices);
    RESOLVE(GetPhysicalDeviceProperties); RESOLVE(GetPhysicalDeviceQueueFamilyProperties);
    RESOLVE(GetPhysicalDeviceMemoryProperties); RESOLVE(CreateDevice); RESOLVE(GetDeviceQueue);
    RESOLVE(CreateShaderModule); RESOLVE(CreateRenderPass); RESOLVE(CreateFramebuffer);
    RESOLVE(CreateImage); RESOLVE(GetImageMemoryRequirements); RESOLVE(AllocateMemory);
    RESOLVE(BindImageMemory); RESOLVE(CreateImageView); RESOLVE(CreatePipelineLayout);
    RESOLVE(CreateGraphicsPipelines); RESOLVE(CreateBuffer); RESOLVE(GetBufferMemoryRequirements);
    RESOLVE(BindBufferMemory); RESOLVE(CreateCommandPool); RESOLVE(AllocateCommandBuffers);
    RESOLVE(BeginCommandBuffer); RESOLVE(CmdBeginRenderPass); RESOLVE(CmdBindPipeline);
    RESOLVE(CmdDraw); RESOLVE(CmdEndRenderPass); RESOLVE(CmdPipelineBarrier);
    RESOLVE(CmdCopyImageToBuffer); RESOLVE(EndCommandBuffer); RESOLVE(QueueSubmit);
    RESOLVE(QueueWaitIdle); RESOLVE(MapMemory); RESOLVE(UnmapMemory);

    int r;
    // ---- instance ----
    struct { u32 sType; P pNext; const char* appName; u32 appVer; const char* engName; u32 engVer; u32 apiVer; } app =
        { ST_APPLICATION_INFO, 0, "vkrender", 1, 0, 0, 1u<<22 };
    struct { u32 sType; P pNext; u32 flags; P pApp; u32 lc; P pl; u32 ec; P pe; } ici =
        { ST_INSTANCE_CI, 0, 0, &app, 0, 0, 0, 0 };
    P inst = 0;
    r = pvkCreateInstance(&ici, 0, &inst);
    if (r) { fprintf(stderr, "vkCreateInstance: %d\n", r); return 1; }

    // ---- pick NVIDIA device + graphics queue family ----
    u32 n = 0; pvkEnumeratePhysicalDevices(inst, &n, 0);
    P devs[8]; if (n > 8) n = 8;
    pvkEnumeratePhysicalDevices(inst, &n, devs);
    P gpu = 0; u32 qfam = 0;
    for (u32 i = 0; i < n && !gpu; i++) {
        union { struct { u32 a,b,v,d,t; char name[256]; } p; char buf[4096]; } u = {0};
        pvkGetPhysicalDeviceProperties(devs[i], &u);
        if (u.p.v != 0x10de) continue;
        gpu = devs[i];
        printf("device: %s\n", u.p.name);
        u32 nq = 0; pvkGetPhysicalDeviceQueueFamilyProperties(gpu, &nq, 0);
        struct { u32 flags, count, ts; u32 g[3]; } qf[16];
        pvkGetPhysicalDeviceQueueFamilyProperties(gpu, &nq, qf);
        for (u32 q = 0; q < nq; q++)
            if (qf[q].flags & 1) { qfam = q; break; }   // GRAPHICS bit
        printf("graphics queue family: %u\n", qfam);
    }
    if (!gpu) { fprintf(stderr, "no NVIDIA device\n"); return 1; }

    // memory properties (for heap type selection)
    struct { u32 mtCount; struct { u32 flags, heap; } mt[16]; u32 mhCount; struct { u64 size; u32 flags; u32 pad; } mh[16]; } mem;
    pvkGetPhysicalDeviceMemoryProperties(gpu, &mem);

    // ---- logical device ----
    f32 prio = 1.0f;
    struct { u32 sType; P pNext; u32 flags, fam, count; P prio; } dqci =
        { ST_DEVICE_QUEUE_CI, 0, 0, qfam, 1, &prio };
    struct { u32 sType; P pNext; u32 flags, qc; P pqc; u32 lc; P pl; u32 ec; P pe; P feat; } dci =
        { ST_DEVICE_CI, 0, 0, 1, &dqci, 0, 0, 0, 0, 0 };
    P dev = 0;
    r = pvkCreateDevice(gpu, &dci, 0, &dev);
    if (r) { fprintf(stderr, "vkCreateDevice: %d\n", r); return 1; }
    P queue = 0; pvkGetDeviceQueue(dev, qfam, 0, &queue);

    // ---- shaders ----
    size_t vsz, fsz; void *vspv = read_file(argv[1], &vsz), *fspv = read_file(argv[2], &fsz);
    Hd vsm = 0, fsm = 0;
    struct { u32 sType; P pNext; u32 flags; u64 codeSize; P pCode; } smci;
    smci.sType = ST_SHADER_MODULE_CI; smci.pNext = 0; smci.flags = 0;
    smci.codeSize = vsz; smci.pCode = vspv;
    r = pvkCreateShaderModule(dev, &smci, 0, &vsm);
    if (r) { fprintf(stderr, "VS vkCreateShaderModule: %d\n", r); return 1; }
    smci.codeSize = fsz; smci.pCode = fspv;
    r = pvkCreateShaderModule(dev, &smci, 0, &fsm);
    if (r) { fprintf(stderr, "FS vkCreateShaderModule: %d\n", r); return 1; }
    printf("shader modules OK (hand-assembled SPIR-V accepted)\n");

    // ---- render target image (device-local) ----
    Hd img = 0;
    struct { u32 sType; P pNext; u32 flags, imageType, format; u32 ex[3]; u32 mips, layers, samples, tiling, usage, sharing, qfCount; P pqf; u32 layout; } ici2 =
        { ST_IMAGE_CI, 0, 0, 1, FMT_RGBA8, {W, H, 1}, 1, 1, 1, 0, 0x11, 0, 0, 0, LAYOUT_UNDEF };
    r = pvkCreateImage(dev, &ici2, 0, &img);
    if (r) { fprintf(stderr, "vkCreateImage: %d\n", r); return 1; }
    struct { u64 size, align; u32 typeBits; u32 pad; } req;
    pvkGetImageMemoryRequirements(dev, img, &req);
    u32 imgMt = ~0u;
    for (u32 i = 0; i < mem.mtCount; i++)
        if ((req.typeBits & (1u << i)) && (mem.mt[i].flags & 1)) { imgMt = i; break; }  // DEVICE_LOCAL
    if (imgMt == ~0u) { fprintf(stderr, "no device-local memory type\n"); return 1; }
    Hd imgMem = 0;
    struct { u32 sType; P pNext; u64 size; u32 typeIndex; } mai = { ST_MEM_ALLOC, 0, req.size, imgMt };
    r = pvkAllocateMemory(dev, &mai, 0, &imgMem);
    if (r) { fprintf(stderr, "vkAllocateMemory(img): %d\n", r); return 1; }
    pvkBindImageMemory(dev, img, imgMem, 0);
    printf("render target: %llu bytes device-local (heap type %u)\n",
           (unsigned long long)req.size, imgMt);

    Hd view = 0;
    struct { u32 sType; P pNext; u32 flags; Hd image; u32 viewType, format; u32 comp[4]; u32 srr[5]; } ivci =
        { ST_IMAGE_VIEW_CI, 0, 0, img, 1, FMT_RGBA8, {0,0,0,0}, {1, 0, 1, 0, 1} };
    r = pvkCreateImageView(dev, &ivci, 0, &view);
    if (r) { fprintf(stderr, "vkCreateImageView: %d\n", r); return 1; }

    // ---- render pass: clear -> draw -> auto-transition to TRANSFER_SRC ----
    struct { u32 flags, format, samples, loadOp, storeOp, sLoad, sStore, iLayout, fLayout; } attach =
        { 0, FMT_RGBA8, 1, 0, 0, 1, 1, LAYOUT_UNDEF, LAYOUT_TRANSFER_SRC };
    struct { u32 attachment, layout; } colorRef = { 0, LAYOUT_COLOR_ATT };
    struct { u32 flags, bindPoint, inCount; P pIn; u32 colorCount; P pColor; P pResolve, pDepth; u32 preserveCount; P pPreserve; } subpass =
        { 0, 0, 0, 0, 1, &colorRef, 0, 0, 0, 0 };
    struct { u32 sType; P pNext; u32 flags, ac; P pa; u32 sc; P ps; u32 dc; P pd; } rpci =
        { ST_RENDERPASS_CI, 0, 0, 1, &attach, 1, &subpass, 0, 0 };
    Hd rp = 0;
    r = pvkCreateRenderPass(dev, &rpci, 0, &rp);
    if (r) { fprintf(stderr, "vkCreateRenderPass: %d\n", r); return 1; }

    struct { u32 sType; P pNext; u32 flags; Hd rp; u32 count; P pViews; u32 w, h, layers; } fbci =
        { ST_FRAMEBUFFER_CI, 0, 0, rp, 1, &view, W, H, 1 };
    Hd fb = 0;
    r = pvkCreateFramebuffer(dev, &fbci, 0, &fb);
    if (r) { fprintf(stderr, "vkCreateFramebuffer: %d\n", r); return 1; }

    // ---- pipeline ----
    Hd plLayout = 0;
    struct { u32 sType; P pNext; u32 flags, slc; P psl; u32 pcrc; P pcr; } plci =
        { ST_PIPELINE_LAYOUT_CI, 0, 0, 0, 0, 0, 0 };
    pvkCreatePipelineLayout(dev, &plci, 0, &plLayout);

    struct { u32 sType; P pNext; u32 flags, stage; Hd module; const char* name; P spec; } stages[2] = {
        { ST_SHADER_STAGE_CI, 0, 0, 1,    vsm, "main", 0 },
        { ST_SHADER_STAGE_CI, 0, 0, 0x10, fsm, "main", 0 },
    };
    struct { u32 sType; P pNext; u32 flags, bdc; P pbd; u32 adc; P pad; } vi = { ST_VTX_INPUT_CI, 0, 0, 0, 0, 0, 0 };
    struct { u32 sType; P pNext; u32 flags, topology, restart; } ia = { ST_INPUT_ASM_CI, 0, 0, 3, 0 };
    struct { f32 x, y, w, h, mn, mx; } vp = { 0, 0, W, H, 0, 1 };
    struct { struct { i32 x, y; } off; struct { u32 w, h; } ext; } sc = { {0, 0}, {W, H} };
    struct { u32 sType; P pNext; u32 flags, vpc; P pvp; u32 scc; P psc; } vps = { ST_VIEWPORT_CI, 0, 0, 1, &vp, 1, &sc };
    struct { u32 sType; P pNext; u32 flags, clamp, discard, poly, cull, front, biasEn; f32 b1, b2, b3, lw; } ras =
        { ST_RASTER_CI, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1.0f };
    struct { u32 sType; P pNext; u32 flags, samples, shadeEn; f32 minShade; P mask; u32 a2c, a2o; } ms =
        { ST_MULTISAMPLE_CI, 0, 0, 1, 0, 0, 0, 0, 0 };
    struct { u32 blendEn, srcC, dstC, opC, srcA, dstA, opA, mask; } cba = { 0, 1, 0, 0, 1, 0, 0, 0xf };
    struct { u32 sType; P pNext; u32 flags, logicEn, logicOp, ac; P pa; f32 bc[4]; } cb =
        { ST_COLORBLEND_CI, 0, 0, 0, 0, 1, &cba, {0,0,0,0} };
    struct { u32 sType; P pNext; u32 flags, stageCount; P pStages, pVI, pIA, pTess, pVP, pRas, pMS, pDS, pCB, pDyn;
             Hd layout, rp; u32 subpass; Hd base; i32 baseIdx; } gpci = {
        ST_GRAPHICS_PIPELINE_CI, 0, 0, 2, stages, &vi, &ia, 0, &vps, &ras, &ms, 0, &cb, 0,
        plLayout, rp, 0, 0, -1 };
    Hd pipeline = 0;
    r = pvkCreateGraphicsPipelines(dev, 0, 1, &gpci, 0, &pipeline);
    if (r) { fprintf(stderr, "vkCreateGraphicsPipelines: %d\n", r); return 1; }
    printf("graphics pipeline created (rasterizer path live)\n");

    // ---- readback buffer (host visible + coherent) ----
    Hd buf = 0;
    struct { u32 sType; P pNext; u32 flags; u64 size; u32 usage, sharing, qfc; P pqf; } bci =
        { ST_BUFFER_CI, 0, 0, W * H * 4, 2, 0, 0, 0 };
    pvkCreateBuffer(dev, &bci, 0, &buf);
    pvkGetBufferMemoryRequirements(dev, buf, &req);
    u32 bufMt = ~0u;
    for (u32 i = 0; i < mem.mtCount; i++)
        if ((req.typeBits & (1u << i)) && ((mem.mt[i].flags & 6) == 6)) { bufMt = i; break; }
    Hd bufMem = 0;
    struct { u32 sType; P pNext; u64 size; u32 typeIndex; } bai = { ST_MEM_ALLOC, 0, req.size, bufMt };
    pvkAllocateMemory(dev, &bai, 0, &bufMem);
    pvkBindBufferMemory(dev, buf, bufMem, 0);

    // ---- command buffer ----
    Hd pool = 0;
    struct { u32 sType; P pNext; u32 flags, qf; } cpci = { ST_COMMAND_POOL_CI, 0, 0, qfam };
    pvkCreateCommandPool(dev, &cpci, 0, &pool);
    P cmd = 0;
    struct { u32 sType; P pNext; Hd pool; u32 level, count; } cbai = { ST_COMMAND_BUFFER_ALLOC, 0, pool, 0, 1 };
    pvkAllocateCommandBuffers(dev, &cbai, &cmd);
    struct { u32 sType; P pNext; u32 flags; P inh; } cbi = { ST_COMMAND_BUFFER_BEGIN, 0, 0, 0 };
    pvkBeginCommandBuffer(cmd, &cbi);

    f32 clearCol[4] = { 0.04f, 0.08f, 0.16f, 1.0f };
    struct { u32 sType; P pNext; Hd rp, fb; struct { struct { i32 x, y; } off; struct { u32 w, h; } ext; } area;
             u32 clearCount; P pClear; } rpbi = { ST_RENDERPASS_BEGIN, 0, rp, fb, {{0,0},{W,H}}, 1, clearCol };
    pvkCmdBeginRenderPass(cmd, &rpbi, 0);
    pvkCmdBindPipeline(cmd, 0, pipeline);
    for (int f = 0; f < frames; f++)
        pvkCmdDraw(cmd, 3, instances, 0, 0);
    pvkCmdEndRenderPass(cmd);
    pvkEndCommandBuffer(cmd);

    struct { u32 sType; P pNext; u32 waitCount; P pWait, pMask; u32 cmdCount; P pCmd; u32 sigCount; P pSig; } si = {
        ST_SUBMIT_INFO, 0, 0, 0, 0, 1, &cmd, 0, 0 };
    struct timespec ts0, ts1;
    clock_gettime(CLOCK_MONOTONIC, &ts0);
    r = pvkQueueSubmit(queue, 1, &si, 0);
    if (r) { fprintf(stderr, "vkQueueSubmit: %d\n", r); return 1; }
    r = pvkQueueWaitIdle(queue);
    clock_gettime(CLOCK_MONOTONIC, &ts1);
    if (r) { fprintf(stderr, "vkQueueWaitIdle: %d\n", r); return 1; }
    double dt = (ts1.tv_sec - ts0.tv_sec) + (ts1.tv_nsec - ts0.tv_nsec) * 1e-9;
    double px = (double)frames * instances * 8192.0;   // 8192 px per triangle instance
    printf("frames=%d instances=%d  %.3fs  %.1f fps  %.2f Gpix/s\n",
           frames, instances, dt, frames / dt, px / dt / 1e9);
    return 0;
}
