// Oercel: minimal end-to-end CUDA check used by pc/setup_wsl.sh.
// Lists the GPUs, runs a small double-precision kernel (a SAXPY-like update plus a block
// reduction) and compares the result with the CPU.  Prints "CUDA OK" and exits 0 on success.
// Build: nvcc -O2 -gencode arch=compute_75,code=[sm_75,compute_75] -o cuda_check cuda_check.cu
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <cuda_runtime.h>

#define CK(x)                                                                                    \
    do {                                                                                         \
        cudaError_t e_ = (x);                                                                    \
        if (e_ != cudaSuccess) {                                                                 \
            std::fprintf(stderr, "CUDA FOUT: %s (%s:%d: %s)\n", cudaGetErrorString(e_), __FILE__, \
                         __LINE__, #x);                                                          \
            return 1;                                                                            \
        }                                                                                        \
    } while (0)

__global__ void axpy_sum(int n, double a, const double *x, double *y, double *partial) {
    __shared__ double buf[256];
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    double v = 0.0;
    if (i < n) {
        y[i] = a * x[i] + y[i];
        v = y[i];
    }
    buf[threadIdx.x] = v;
    __syncthreads();
    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (threadIdx.x < s) buf[threadIdx.x] += buf[threadIdx.x + s];
        __syncthreads();
    }
    if (threadIdx.x == 0) partial[blockIdx.x] = buf[0];
}

int main() {
    int ndev = 0, drv = 0, rt = 0;
    CK(cudaGetDeviceCount(&ndev));
    CK(cudaDriverGetVersion(&drv));
    CK(cudaRuntimeGetVersion(&rt));
    std::printf("CUDA driver %d.%d, runtime %d.%d, %d GPU(s)\n", drv / 1000, (drv % 1000) / 10, rt / 1000,
                (rt % 1000) / 10, ndev);
    if (ndev < 1) {
        std::fprintf(stderr, "CUDA FOUT: geen GPU zichtbaar\n");
        return 1;
    }
    for (int d = 0; d < ndev; d++) {
        cudaDeviceProp p;
        CK(cudaGetDeviceProperties(&p, d));
        std::printf("GPU %d: %s, compute capability %d.%d, %.1f GB, %d SMs\n", d, p.name, p.major, p.minor,
                    p.totalGlobalMem / 1073741824.0, p.multiProcessorCount);
    }
    const int n = 1 << 20, bs = 256, nb = (n + bs - 1) / bs;
    double *hx = (double *)std::malloc(n * sizeof(double)), *hy = (double *)std::malloc(n * sizeof(double));
    double *hp = (double *)std::malloc(nb * sizeof(double));
    for (int i = 0; i < n; i++) {
        hx[i] = std::sin(0.001 * i);
        hy[i] = std::cos(0.002 * i);
    }
    double *dx, *dy, *dp;
    CK(cudaMalloc(&dx, n * sizeof(double)));
    CK(cudaMalloc(&dy, n * sizeof(double)));
    CK(cudaMalloc(&dp, nb * sizeof(double)));
    CK(cudaMemcpy(dx, hx, n * sizeof(double), cudaMemcpyHostToDevice));
    CK(cudaMemcpy(dy, hy, n * sizeof(double), cudaMemcpyHostToDevice));
    axpy_sum<<<nb, bs>>>(n, 0.5, dx, dy, dp);
    CK(cudaGetLastError());
    CK(cudaDeviceSynchronize());
    CK(cudaMemcpy(hp, dp, nb * sizeof(double), cudaMemcpyDeviceToHost));
    double gpu = 0.0, cpu = 0.0;
    for (int b = 0; b < nb; b++) gpu += hp[b];
    for (int i = 0; i < n; i++) cpu += 0.5 * hx[i] + hy[i];
    double err = std::fabs(gpu - cpu) / std::fmax(1.0, std::fabs(cpu));
    std::printf("kernel-test: som GPU %.12g, CPU %.12g, relatieve fout %.2e\n", gpu, cpu, err);
    cudaFree(dx);
    cudaFree(dy);
    cudaFree(dp);
    std::free(hx);
    std::free(hy);
    std::free(hp);
    if (err > 1e-9) {
        std::fprintf(stderr, "CUDA FOUT: GPU-resultaat wijkt af\n");
        return 1;
    }
    std::printf("CUDA OK\n");
    return 0;
}
