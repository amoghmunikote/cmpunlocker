#include <cstdio>
#include <cuda_runtime.h>
#include <cublas_v2.h>
#include <cuda_fp16.h>

#define CK(x) do{ cudaError_t e=(x); if(e){printf("cuda err %s @%d\n",cudaGetErrorString(e),__LINE__);return 1;} }while(0)

static float timeGemm(cublasHandle_t h, cublasComputeType_t ct, cudaDataType_t dt,
                      void*A, void*B, void*C, int n, int iters)
{
    float alpha=1.f, beta=0.f;
    cudaEvent_t s,e; cudaEventCreate(&s); cudaEventCreate(&e);
    for(int i=0;i<5;i++)
        cublasGemmEx(h,CUBLAS_OP_N,CUBLAS_OP_N,n,n,n,&alpha,A,dt,n,B,dt,n,&beta,C,dt,n,ct,CUBLAS_GEMM_DEFAULT);
    cudaDeviceSynchronize();
    cudaEventRecord(s);
    for(int i=0;i<iters;i++)
        cublasGemmEx(h,CUBLAS_OP_N,CUBLAS_OP_N,n,n,n,&alpha,A,dt,n,B,dt,n,&beta,C,dt,n,ct,CUBLAS_GEMM_DEFAULT);
    cudaEventRecord(e); cudaEventSynchronize(e);
    float ms; cudaEventElapsedTime(&ms,s,e);
    return ms/iters;
}

__global__ void triad(float4* __restrict__ a, const float4* __restrict__ b, size_t n){
    size_t i = blockIdx.x*(size_t)blockDim.x + threadIdx.x;
    if(i<n){ float4 v=b[i]; v.x*=1.01f; v.y*=1.01f; v.z*=1.01f; v.w*=1.01f; a[i]=v; }
}

int main(){
    cudaDeviceProp p; CK(cudaGetDeviceProperties(&p,0));
    printf("GPU              : %s\n", p.name);
    printf("Compute capability: %d.%d\n", p.major, p.minor);
    printf("SM count         : %d\n", p.multiProcessorCount);
    printf("Clock (max)      : %.0f MHz\n", p.clockRate/1000.0);
    printf("Mem bus / clk    : %d-bit @ %.0f MHz\n", p.memoryBusWidth, p.memoryClockRate/1000.0);
    printf("Theoretical BW   : %.1f GB/s\n", 2.0*p.memoryClockRate*1000.0*(p.memoryBusWidth/8)/1e9);
    printf("Total VRAM       : %.0f MiB\n", p.totalGlobalMem/1048576.0);
    printf("L2 cache         : %d KiB\n\n", p.l2CacheSize/1024);

    // FP32 theoretical: SM * 128 lanes * 2 flop * clock
    double fp32_peak = p.multiProcessorCount*128.0*2.0*(p.clockRate*1000.0)/1e12;
    printf("Theoretical FP32 peak (SM*128*2*clk): %.1f TFLOP/s\n\n", fp32_peak);

    cublasHandle_t h; cublasCreate(&h);
    int n=8192; size_t N=(size_t)n*n;
    void *A,*B,*C;
    CK(cudaMalloc(&A,N*4)); CK(cudaMalloc(&B,N*4)); CK(cudaMalloc(&C,N*4));
    CK(cudaMemset(A,0x3c,N*4)); CK(cudaMemset(B,0x3c,N*4));
    double flops = 2.0*n*n*(double)n;

    printf("=== GEMM %dx%d (cuBLAS) ===\n", n, n);
    // FP32 (non-tensor)
    cublasSetMathMode(h, CUBLAS_PEDANTIC_MATH);
    float ms = timeGemm(h,CUBLAS_COMPUTE_32F_PEDANTIC,CUDA_R_32F,A,B,C,n,20);
    printf("FP32  (CUDA cores) : %8.2f ms  %7.2f TFLOP/s  (%.0f%% of theoretical)\n", ms, flops/(ms*1e-3)/1e12, 100.0*(flops/(ms*1e-3)/1e12)/fp32_peak);

    // TF32 tensor core
    ms = timeGemm(h,CUBLAS_COMPUTE_32F_FAST_TF32,CUDA_R_32F,A,B,C,n,20);
    printf("TF32  (tensor)     : %8.2f ms  %7.2f TFLOP/s\n", ms, flops/(ms*1e-3)/1e12);

    // FP16 tensor core
    ms = timeGemm(h,CUBLAS_COMPUTE_16F,CUDA_R_16F,A,B,C,n,20);
    printf("FP16  (tensor)     : %8.2f ms  %7.2f TFLOP/s\n", ms, flops/(ms*1e-3)/1e12);

    // memory bandwidth
    size_t bytes = 512ull<<20;
    float4 *ma,*mb; CK(cudaMalloc(&ma,bytes)); CK(cudaMalloc(&mb,bytes));
    CK(cudaMemset(mb,1,bytes));
    size_t nv = bytes/sizeof(float4);
    cudaEvent_t s,e; cudaEventCreate(&s); cudaEventCreate(&e);
    triad<<<(nv+255)/256,256>>>(ma,mb,nv); cudaDeviceSynchronize();
    cudaEventRecord(s);
    for(int i=0;i<50;i++) triad<<<(nv+255)/256,256>>>(ma,mb,nv);
    cudaEventRecord(e); cudaEventSynchronize(e);
    float mms; cudaEventElapsedTime(&mms,s,e); mms/=50;
    printf("\n=== Memory ===\nDevice copy BW     : %7.1f GB/s (read+write %zu MiB)\n", 2.0*bytes/(mms*1e-3)/1e9, bytes>>20);

    // clocks under load
    int sm=0,mem=0;
    printf("\n(run nvidia-smi during load for sustained clocks)\n");
    (void)sm;(void)mem;
    return 0;
}
