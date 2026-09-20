/*
 * Verify real peer reads and writes for every directed pair of selected GPUs.
 * Each GPU starts with a different pattern. Both endpoints are read back so
 * an incorrectly aliased local mapping cannot silently pass.
 *
 * nvcc -O2 -arch=sm_80 -o /tmp/cmpunlocker-test-p2p tools/test-p2p.cu
 * timeout 120s /tmp/cmpunlocker-test-p2p [gpu_id gpu_id ...]
 */
#include <cuda_runtime.h>
#include <algorithm>
#include <cerrno>
#include <climits>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

static void check(cudaError_t result, const char *expr, int line)
{
    if (result != cudaSuccess) {
        std::fprintf(stderr, "line %d: %s: %s\n", line, expr,
                     cudaGetErrorString(result));
        std::exit(1);
    }
}
#define CUDA(expr) check((expr), #expr, __LINE__)

__global__ static void peer_copy(unsigned *dst, const unsigned *src, size_t count)
{
    for (size_t i = blockIdx.x * blockDim.x + threadIdx.x; i < count;
         i += static_cast<size_t>(gridDim.x) * blockDim.x)
        dst[i] = src[i];
}

static std::vector<unsigned> pattern(size_t count, unsigned seed)
{
    std::vector<unsigned> data(count);
    for (size_t i = 0; i < count; ++i)
        data[i] = (static_cast<unsigned>(i) * 2654435761U) ^ seed;
    return data;
}

static bool verify(int device, unsigned *ptr, const std::vector<unsigned> &expected,
                   const char *label)
{
    std::vector<unsigned> actual(expected.size());
    CUDA(cudaSetDevice(device));
    CUDA(cudaMemcpy(actual.data(), ptr, actual.size() * sizeof(unsigned),
                    cudaMemcpyDeviceToHost));
    for (size_t i = 0; i < actual.size(); ++i) {
        if (actual[i] != expected[i]) {
            std::fprintf(stderr,
                         "%s GPU %d: mismatch at %zu (got %08x, expected %08x)\n",
                         label, device, i, actual[i], expected[i]);
            return false;
        }
    }
    return true;
}

static bool test_pair(int executor, int remote)
{
    int accessible = 0;
    CUDA(cudaDeviceCanAccessPeer(&accessible, executor, remote));
    if (!accessible) {
        std::fprintf(stderr, "GPU %d -> %d: peer access unavailable\n", executor, remote);
        return false;
    }

    const size_t count = 4U * 1024U * 1024U; // 16 MiB per endpoint
    const size_t bytes = count * sizeof(unsigned);
    const auto local_seed = pattern(count, 0x13579BDFU);
    const auto peer_seed = pattern(count, 0xECA86420U);
    unsigned *local = nullptr, *peer = nullptr;
    CUDA(cudaSetDevice(remote));
    CUDA(cudaMalloc(reinterpret_cast<void **>(&peer), bytes));
    CUDA(cudaMemcpy(peer, peer_seed.data(), bytes, cudaMemcpyHostToDevice));
    CUDA(cudaSetDevice(executor));
    CUDA(cudaMalloc(reinterpret_cast<void **>(&local), bytes));
    CUDA(cudaMemcpy(local, local_seed.data(), bytes, cudaMemcpyHostToDevice));
    cudaError_t enabled = cudaDeviceEnablePeerAccess(remote, 0);
    bool own_access = enabled == cudaSuccess;
    if (enabled == cudaErrorPeerAccessAlreadyEnabled)
        (void)cudaGetLastError();
    else
        CUDA(enabled);

    // Run on the executor: read the remote allocation into local memory.
    std::printf("GPU %d -> %d: peer read...\n", executor, remote);
    std::fflush(stdout);
    peer_copy<<<256, 256>>>(local, peer, count);
    CUDA(cudaGetLastError());
    CUDA(cudaDeviceSynchronize());
    bool passed = verify(executor, local, peer_seed, "peer read result");
    passed = verify(remote, peer, peer_seed, "peer read source") && passed;

    // Reset both endpoints; now write remote memory from the executor.
    CUDA(cudaSetDevice(remote));
    CUDA(cudaMemcpy(peer, peer_seed.data(), bytes, cudaMemcpyHostToDevice));
    CUDA(cudaSetDevice(executor));
    CUDA(cudaMemcpy(local, local_seed.data(), bytes, cudaMemcpyHostToDevice));
    std::printf("GPU %d -> %d: peer write...\n", executor, remote);
    std::fflush(stdout);
    peer_copy<<<256, 256>>>(peer, local, count);
    CUDA(cudaGetLastError());
    CUDA(cudaDeviceSynchronize());
    passed = verify(remote, peer, local_seed, "peer write result") && passed;
    passed = verify(executor, local, local_seed, "peer write source") && passed;

    CUDA(cudaSetDevice(executor));
    if (own_access)
        CUDA(cudaDeviceDisablePeerAccess(remote));
    CUDA(cudaFree(local));
    CUDA(cudaSetDevice(remote));
    CUDA(cudaFree(peer));
    std::printf("GPU %d -> %d: %s\n", executor, remote, passed ? "PASS" : "FAIL");
    return passed;
}

int main(int argc, char **argv)
{
    if (argc == 2 && (std::string(argv[1]) == "--help" || std::string(argv[1]) == "-h")) {
        std::printf("Usage: %s [gpu_id gpu_id ...]\nDefault: all visible CUDA GPUs.\n", argv[0]);
        return 0;
    }
    int count = 0;
    CUDA(cudaGetDeviceCount(&count));
    std::vector<int> devices;
    for (int i = 1; i < argc; ++i) {
        char *end = nullptr;
        errno = 0;
        long device = std::strtol(argv[i], &end, 10);
        if (errno || end == argv[i] || *end || device < 0 || device >= count || device > INT_MAX ||
            std::find(devices.begin(), devices.end(), device) != devices.end()) {
            std::fprintf(stderr, "Invalid or duplicate GPU index: %s\n", argv[i]);
            return 1;
        }
        devices.push_back(static_cast<int>(device));
    }
    if (argc == 1)
        for (int i = 0; i < count; ++i) devices.push_back(i);
    if (devices.size() < 2) {
        std::fprintf(stderr, "Select at least two visible CUDA GPUs.\n");
        return 1;
    }
    for (int device : devices) {
        char bus[32];
        CUDA(cudaDeviceGetPCIBusId(bus, sizeof(bus), device));
        std::printf("GPU %d: %s\n", device, bus);
    }
    unsigned failures = 0, pairs = 0;
    for (int executor : devices)
        for (int remote : devices)
            if (executor != remote) {
                ++pairs;
                if (!test_pair(executor, remote)) ++failures;
            }
    std::printf("%u/%u directed pairs passed real peer reads and writes.\n", pairs - failures, pairs);
    return failures ? 1 : 0;
}
