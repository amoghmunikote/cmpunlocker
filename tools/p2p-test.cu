// Build: nvcc -O2 -arch=sm_80 -o /tmp/cmp-p2p-test tools/p2p-test.cu
// Run:   /tmp/cmp-p2p-test 3   (expected visible GPU count)
#include <cuda_runtime.h>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

#define CUDA(call) do { \
    cudaError_t error = (call); \
    if (error != cudaSuccess) { \
        std::fprintf(stderr, "%s:%d: %s: %s\n", __FILE__, __LINE__, #call, \
                     cudaGetErrorString(error)); \
        std::exit(1); \
    } \
} while (0)

constexpr size_t WORDS = 4 * 1024 * 1024; // 16 MiB per buffer

__host__ __device__ uint32_t pattern(size_t index, uint32_t tag)
{
    return (tag << 28) | ((static_cast<uint32_t>(index) * 2654435761U) & 0x0fffffffU);
}

__global__ void peer_read(uint32_t *local, const uint32_t *remote, size_t count)
{
    for (size_t i = blockIdx.x * blockDim.x + threadIdx.x;
         i < count; i += blockDim.x * gridDim.x)
        local[i] = remote[i];
}

__global__ void peer_write(uint32_t *remote, size_t count, uint32_t tag)
{
    for (size_t i = blockIdx.x * blockDim.x + threadIdx.x;
         i < count; i += blockDim.x * gridDim.x)
        remote[i] = pattern(i, tag);
}

static void seed(uint32_t *device, std::vector<uint32_t> &host, uint32_t tag)
{
    for (size_t i = 0; i < host.size(); ++i)
        host[i] = pattern(i, tag);
    CUDA(cudaMemcpy(device, host.data(), host.size() * sizeof(uint32_t), cudaMemcpyHostToDevice));
}

static bool verify(uint32_t *device, std::vector<uint32_t> &host, uint32_t tag,
                   const char *operation)
{
    CUDA(cudaMemcpy(host.data(), device, host.size() * sizeof(uint32_t), cudaMemcpyDeviceToHost));
    for (size_t i = 0; i < host.size(); ++i) {
        if (host[i] != pattern(i, tag)) {
            std::fprintf(stderr, "%s mismatch at word %zu: got %08x expected %08x\n",
                         operation, i, host[i], pattern(i, tag));
            return false;
        }
    }
    return true;
}

static bool test_pair(int accessor, int peer)
{
    int capable = 0;
    CUDA(cudaDeviceCanAccessPeer(&capable, accessor, peer));
    if (!capable) {
        std::fprintf(stderr, "GPU %d -> %d: peer access unavailable\n", accessor, peer);
        return false;
    }

    uint32_t *local = nullptr, *remote = nullptr;
    std::vector<uint32_t> host(WORDS);
    CUDA(cudaSetDevice(accessor));
    CUDA(cudaMalloc(&local, WORDS * sizeof(uint32_t)));
    seed(local, host, 0xA);
    CUDA(cudaDeviceEnablePeerAccess(peer, 0));
    CUDA(cudaSetDevice(peer));
    CUDA(cudaMalloc(&remote, WORDS * sizeof(uint32_t)));
    seed(remote, host, 0xB);

    CUDA(cudaSetDevice(accessor));
    CUDA(cudaMemcpyPeer(remote, peer, local, accessor, WORDS * sizeof(uint32_t)));
    CUDA(cudaDeviceSynchronize());
    bool copy_ok = verify(local, host, 0xA, "peer copy source guard");
    CUDA(cudaSetDevice(peer));
    CUDA(cudaDeviceSynchronize());
    copy_ok = verify(remote, host, 0xA, "peer copy destination") && copy_ok;
    seed(remote, host, 0xB);

    // Distinct tags make a peer mapping that aliases this GPU's local memory fail.
    CUDA(cudaSetDevice(accessor));
    peer_read<<<256, 256>>>(local, remote, WORDS);
    CUDA(cudaGetLastError());
    CUDA(cudaDeviceSynchronize());
    bool read_ok = verify(local, host, 0xB, "peer read");
    CUDA(cudaSetDevice(peer));
    read_ok = verify(remote, host, 0xB, "remote read guard") && read_ok;

    // Reset both sides; a successful local alias must not look like a peer write.
    seed(remote, host, 0xB);
    CUDA(cudaSetDevice(accessor));
    seed(local, host, 0xA);
    peer_write<<<256, 256>>>(remote, WORDS, 0xC);
    CUDA(cudaGetLastError());
    CUDA(cudaDeviceSynchronize());
    bool write_ok = verify(local, host, 0xA, "local write guard");
    CUDA(cudaSetDevice(peer));
    write_ok = verify(remote, host, 0xC, "peer write") && write_ok;

    CUDA(cudaSetDevice(accessor));
    CUDA(cudaDeviceDisablePeerAccess(peer));
    CUDA(cudaFree(local));
    CUDA(cudaSetDevice(peer));
    CUDA(cudaFree(remote));
    std::printf("GPU %d accesses GPU %d: copy=%s read=%s write=%s\n", accessor, peer,
                copy_ok ? "PASS" : "FAIL", read_ok ? "PASS" : "FAIL", write_ok ? "PASS" : "FAIL");
    return copy_ok && read_ok && write_ok;
}

int main(int argc, char **argv)
{
    int count = 0;
    CUDA(cudaGetDeviceCount(&count));
    if (argc != 2) {
        std::fprintf(stderr, "Usage: %s EXPECTED_GPU_COUNT\n", argv[0]);
        return 2;
    }
    char *end = nullptr;
    long expected = std::strtol(argv[1], &end, 10);
    if (*end || expected < 2 || expected != count) {
        std::fprintf(stderr, "Expected count must be >= 2 and equal visible GPU count (%d)\n", count);
        return 2;
    }
    for (int i = 0; i < count; ++i) {
        cudaDeviceProp prop;
        char bus[32];
        CUDA(cudaGetDeviceProperties(&prop, i));
        CUDA(cudaDeviceGetPCIBusId(bus, sizeof(bus), i));
        std::printf("GPU %d: %s at %s, %.1f GiB\n", i, prop.name, bus,
                    prop.totalGlobalMem / (1024.0 * 1024.0 * 1024.0));
    }
    int passed = 0;
    for (int i = 0; i < count; ++i) {
        for (int j = 0; j < count; ++j) {
            if (i == j) continue;
            std::printf("Testing GPU %d accesses GPU %d...\n", i, j);
            std::fflush(stdout);
            passed += test_pair(i, j);
        }
    }
    const int total = count * (count - 1);
    std::printf("%d/%d directed pairs passed peer copies, direct reads and writes.\n", passed, total);
    std::puts("Pairs were tested sequentially; validate your application's simultaneous peer usage separately.");
    return passed == total ? 0 : 1;
}
