// CUDA bandwidth benchmark via the driver API (dlopen libcuda) - no nvcc,
// no CUDA headers, no kernels. Measures:
//   DtoD  : VRAM copy bandwidth (internal GDDR6X)
//   HtoD  : host->device PCIe bandwidth (pinned)
//   DtoH  : device->host PCIe bandwidth (pinned)
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <dlfcn.h>
#include <time.h>

typedef int CUresult;
typedef void* CUcontext;
typedef int CUdevice;
typedef uint64_t CUdeviceptr;

static void* cuda;
#define SYM(name) static __typeof__(*(void(*)(void))0) *p##name; \
    void* s_##name
#define LOAD(name) s_##name = dlsym(cuda, #name); if (!s_##name) { \
    fprintf(stderr, "missing %s\n", #name); return 1; }

static double now(void)
{
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

int main(void)
{
    cuda = dlopen("libcuda.so.1", RTLD_NOW);
    if (!cuda) cuda = dlopen("libcuda.so", RTLD_NOW);
    if (!cuda) { fprintf(stderr, "no libcuda: %s\n", dlerror()); return 1; }

    void* sInit = dlsym(cuda, "cuInit");
    void* sDevGet = dlsym(cuda, "cuDeviceGet");
    void* sDevName = dlsym(cuda, "cuDeviceGetName");
    void* sPrimRetain = dlsym(cuda, "cuDevicePrimaryCtxRetain");
    void* sCtxSet = dlsym(cuda, "cuCtxSetCurrent");
    void* sMemAlloc = dlsym(cuda, "cuMemAlloc_v2");
    void* sMemAllocHost = dlsym(cuda, "cuMemAllocHost_v2");
    void* sDtoD = dlsym(cuda, "cuMemcpyDtoD_v2");
    void* sHtoD = dlsym(cuda, "cuMemcpyHtoD_v2");
    void* sDtoH = dlsym(cuda, "cuMemcpyDtoH_v2");
    void* sFree = dlsym(cuda, "cuMemFree_v2");
    void* sFreeHost = dlsym(cuda, "cuMemFreeHost");
    void* sGetErr = dlsym(cuda, "cuGetErrorString");
    void* sSync = dlsym(cuda, "cuCtxSynchronize");
    if (!sInit || !sDevGet || !sPrimRetain || !sCtxSet || !sMemAlloc ||
        !sMemAllocHost || !sDtoD || !sHtoD || !sDtoH || !sFree || !sFreeHost) {
        fprintf(stderr, "missing driver API symbols\n"); return 1;
    }
    #define CALL0(fn, ...) ((__typeof__((CUresult(*)(void))0)0), 0)
    #define CK(expr, what) do { CUresult _r = (CUresult)(expr); if (_r) { \
        const char* es = "?"; if (sGetErr) ((CUresult(*)(CUresult, const char**))sGetErr)(_r, &es); \
        fprintf(stderr, "%s failed: %s\n", what, es); return 1; } } while (0)

    CK(((CUresult(*)(unsigned))sInit)(0), "cuInit");
    CUdevice dev;
    CK(((CUresult(*)(CUdevice*, int))sDevGet)(&dev, 0), "cuDeviceGet");
    char name[256] = {0};
    if (sDevName) ((CUresult(*)(char*, int, CUdevice))sDevName)(name, sizeof name, dev);
    printf("device: %s\n", name);
    CUcontext ctx;
    CK(((CUresult(*)(CUcontext*, CUdevice))sPrimRetain)(&ctx, dev), "ctx retain");
    CK(((CUresult(*)(CUcontext))sCtxSet)(ctx), "ctx set");

    // ---------- DtoD: VRAM bandwidth ----------
    const size_t vram = 512ull << 20;   // 512 MiB per side
    CUdeviceptr dA, dB;
    CK(((CUresult(*)(CUdeviceptr*, size_t))sMemAlloc)(&dA, vram), "alloc A");
    CK(((CUresult(*)(CUdeviceptr*, size_t))sMemAlloc)(&dB, vram), "alloc B");
    // warmup
    ((CUresult(*)(CUdeviceptr, CUdeviceptr, size_t))sDtoD)(dA, dB, vram);
    int iters = 20;
    double t0 = now();
    for (int i = 0; i < iters; i++)
        ((CUresult(*)(CUdeviceptr, CUdeviceptr, size_t))sDtoD)(dA, dB, vram);
    if (sSync) ((CUresult(*)(void))sSync)();
    double dt = now() - t0;
    // DtoD moves vram bytes read + written; report read+write combined
    printf("VRAM DtoD  : %8.1f GB/s  (%.0f MiB x %d, %.2fs)\n",
           iters * 2.0 * vram / dt / 1e9, vram / 1048576.0, iters, dt);

    // ---------- PCIe: pinned host buffer ----------
    const size_t hsz = 256ull << 20;    // 256 MiB
    void* hbuf = 0;
    CK(((CUresult(*)(void**, size_t))sMemAllocHost)(&hbuf, hsz), "allocHost");
    memset(hbuf, 0x5a, hsz);
    iters = 30;
    ((CUresult(*)(CUdeviceptr, const void*, size_t))sHtoD)(dA, hbuf, hsz);
    t0 = now();
    for (int i = 0; i < iters; i++)
        ((CUresult(*)(CUdeviceptr, const void*, size_t))sHtoD)(dA, hbuf, hsz);
    if (sSync) ((CUresult(*)(void))sSync)();
    dt = now() - t0;
    printf("PCIe HtoD  : %8.1f GB/s  (%.0f MiB x %d, %.2fs)\n",
           iters * (double)hsz / dt / 1e9, hsz / 1048576.0, iters, dt);

    ((CUresult(*)(void*, CUdeviceptr, size_t))sDtoH)(hbuf, dA, hsz);
    t0 = now();
    for (int i = 0; i < iters; i++)
        ((CUresult(*)(void*, CUdeviceptr, size_t))sDtoH)(hbuf, dA, hsz);
    if (sSync) ((CUresult(*)(void))sSync)();
    dt = now() - t0;
    printf("PCIe DtoH  : %8.1f GB/s  (%.0f MiB x %d, %.2fs)\n",
           iters * (double)hsz / dt / 1e9, hsz / 1048576.0, iters, dt);

    ((CUresult(*)(CUdeviceptr))sFree)(dA);
    ((CUresult(*)(CUdeviceptr))sFree)(dB);
    ((CUresult(*)(void*))sFreeHost)(hbuf);
    return 0;
}
