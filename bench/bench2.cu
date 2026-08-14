#include <cstdio>
#include <cuda_runtime.h>
#include <cublas_v2.h>
#include <cuda_fp16.h>

#define CB(x) do{ cublasStatus_t s_=(x); if(s_!=CUBLAS_STATUS_SUCCESS){printf("  [cublas status %d @%d]\n",(int)s_,__LINE__); return -1.f;} }while(0)

// pure FMA throughput kernel: no memory traffic, measures raw SM issue rate
__global__ void fma32(float* out, int iters){
    float a=threadIdx.x*1.0f, b=1.000001f, c=0.5f, d=1.5f;
    float e=2.5f, f=3.5f, g=4.5f, h=5.5f;
    for(int i=0;i<iters;i++){
        a=fmaf(a,b,c); d=fmaf(d,b,c); e=fmaf(e,b,c); f=fmaf(f,b,c);
        g=fmaf(g,b,c); h=fmaf(h,b,c); a=fmaf(a,b,d); e=fmaf(e,b,f);
    }
    if(threadIdx.x==100000) out[0]=a+d+e+f+g+h;
}

static float gemmMs(cublasHandle_t hd, cublasComputeType_t ct, cudaDataType_t dt,
                    const void*alpha, const void*beta,
                    void*A, void*B, void*C, int n, int iters)
{
    cudaEvent_t s,e; cudaEventCreate(&s); cudaEventCreate(&e);
    for(int i=0;i<3;i++)
        CB(cublasGemmEx(hd,CUBLAS_OP_N,CUBLAS_OP_N,n,n,n,alpha,A,dt,n,B,dt,n,beta,C,dt,n,ct,CUBLAS_GEMM_DEFAULT));
    cudaDeviceSynchronize();
    cudaEventRecord(s);
    for(int i=0;i<iters;i++)
        CB(cublasGemmEx(hd,CUBLAS_OP_N,CUBLAS_OP_N,n,n,n,alpha,A,dt,n,B,dt,n,beta,C,dt,n,ct,CUBLAS_GEMM_DEFAULT));
    cudaEventRecord(e); cudaEventSynchronize(e);
    float ms; cudaEventElapsedTime(&ms,s,e);
    return ms/iters;
}

int main(int argc,char**argv){
    if(argc>1 && argv[1][0]=='s'){          // sustained-load mode for clock probing
        float* o; cudaMalloc(&o,4);
        for(int k=0;k<400;k++){ fma32<<<50*32,256>>>(o,20000); }
        cudaDeviceSynchronize(); return 0;
    }
    cudaDeviceProp p; cudaGetDeviceProperties(&p,0);
    double clk = p.clockRate*1000.0;
    double fp32_peak = p.multiProcessorCount*128.0*2.0*clk/1e12;

    // ---- raw FMA issue rate (no memory, no tensor cores) ----
    float* o; cudaMalloc(&o,4);
    int blocks=p.multiProcessorCount*32, thr=256, iters=20000;
    cudaEvent_t s,e; cudaEventCreate(&s); cudaEventCreate(&e);
    fma32<<<blocks,thr>>>(o,iters); cudaDeviceSynchronize();
    cudaEventRecord(s);
    for(int i=0;i<5;i++) fma32<<<blocks,thr>>>(o,iters);
    cudaEventRecord(e); cudaEventSynchronize(e);
    float ms; cudaEventElapsedTime(&ms,s,e); ms/=5;
    double fmaFlops = (double)blocks*thr*(double)iters*8.0*2.0;
    double fmaT = fmaFlops/(ms*1e-3)/1e12;
    printf("=== Raw FP32 FMA issue rate (no memory traffic) ===\n");
    printf("Achieved : %6.2f TFLOP/s   Theoretical: %6.2f TFLOP/s   -> %.1f%% of peak\n",
           fmaT, fp32_peak, 100.0*fmaT/fp32_peak);
    printf("Implied effective SM clock: %.0f MHz (vs %.0f MHz rated)\n\n",
           fmaT*1e12/(p.multiProcessorCount*128.0*2.0)/1e6, clk/1e6);

    cublasHandle_t hd; cublasCreate(&hd);
    int n=8192; size_t N=(size_t)n*n;
    void *A,*B,*C;
    cudaMalloc(&A,N*4); cudaMalloc(&B,N*4); cudaMalloc(&C,N*4);
    cudaMemset(A,0x3c,N*4); cudaMemset(B,0x3c,N*4);
    double flops=2.0*n*n*(double)n;

    printf("=== GEMM %d^3 ===\n",n);
    float af=1.f, bf=0.f;
    cublasSetMathMode(hd,CUBLAS_PEDANTIC_MATH);
    ms=gemmMs(hd,CUBLAS_COMPUTE_32F_PEDANTIC,CUDA_R_32F,&af,&bf,A,B,C,n,10);
    if(ms>0) printf("FP32 (CUDA cores)  : %8.2f ms  %7.2f TFLOP/s\n",ms,flops/(ms*1e-3)/1e12);

    cublasSetMathMode(hd,CUBLAS_DEFAULT_MATH);
    ms=gemmMs(hd,CUBLAS_COMPUTE_32F_FAST_TF32,CUDA_R_32F,&af,&bf,A,B,C,n,10);
    if(ms>0) printf("TF32 (tensor)      : %8.2f ms  %7.2f TFLOP/s\n",ms,flops/(ms*1e-3)/1e12);

    // FP16 in / FP32 accumulate -- the realistic inference path. alpha/beta are FLOAT for COMPUTE_32F.
    ms=gemmMs(hd,CUBLAS_COMPUTE_32F,CUDA_R_16F,&af,&bf,A,B,C,n,10);
    if(ms>0) printf("FP16 in/FP32 acc   : %8.2f ms  %7.2f TFLOP/s\n",ms,flops/(ms*1e-3)/1e12);

    // FP16 in / FP16 accumulate -- alpha/beta must be __half for COMPUTE_16F.
    __half ah=__float2half(1.f), bh=__float2half(0.f);
    ms=gemmMs(hd,CUBLAS_COMPUTE_16F,CUDA_R_16F,&ah,&bh,A,B,C,n,10);
    if(ms>0) printf("FP16 in/FP16 acc   : %8.2f ms  %7.2f TFLOP/s\n",ms,flops/(ms*1e-3)/1e12);
    return 0;
}
