# Oercel GPU engine (see README.md)
#   make            -> oercel_gpu  (CUDA build, needs nvcc; ARCH=sm_75 by default = Quadro RTX 8000 / Turing)
#   make emu        -> oercel_emu  (CPU emulation build of the same source: g++ + OpenMP, no CUDA needed)
#   make ARCH="sm_75 sm_86"        several GPU architectures in one binary (+ PTX of the last one)
#   make NVCC=/path/to/nvcc CCBIN=g++-12   choose compiler / host compiler for nvcc
#   make test       -> kernel self-tests (--forcetest) of whatever builds exist
NVCC  ?= nvcc
CXX   ?= g++
ARCH  ?= sm_75
CCBIN ?=
# nvcc older than 12.4 does not accept gcc 13+ as host compiler: use g++-12 if it exists
ifeq ($(CCBIN),)
  NVCC_MINOR := $(shell $(NVCC) --version 2>/dev/null | sed -n 's/.*release 12\.\([0-9]*\).*/\1/p')
  GXX_MAJOR  := $(shell $(CXX) -dumpversion 2>/dev/null | cut -d. -f1)
  ifneq ($(NVCC_MINOR),)
    ifeq ($(shell [ $(NVCC_MINOR) -lt 4 ] && [ "$(GXX_MAJOR)" -ge 13 ] 2>/dev/null && echo old),old)
      ifneq ($(shell command -v g++-12 2>/dev/null),)
        CCBIN := g++-12
      endif
    endif
  endif
endif
CCBIN_FLAG := $(if $(CCBIN),-ccbin $(CCBIN),)
GENCODE := $(foreach a,$(ARCH),-gencode arch=compute_$(a:sm_%=%),code=$(a)) \
           -gencode arch=compute_$(lastword $(ARCH:sm_%=%)),code=compute_$(lastword $(ARCH:sm_%=%))
NVFLAGS ?= -O3 -std=c++17 --extended-lambda -lineinfo
# include/lib dirs next to nvcc (needed for the relocatable toolkit that setup_wsl.sh downloads)
CUDA_HOME ?= $(abspath $(dir $(shell command -v $(NVCC) 2>/dev/null))..)
ifneq ($(CUDA_HOME),/usr)
NVFLAGS += $(if $(wildcard $(CUDA_HOME)/include/cuda_runtime.h),-I$(CUDA_HOME)/include -L$(CUDA_HOME)/lib64 -L$(CUDA_HOME)/lib,)
endif
# host code: no fp contraction (exact TwoSum accumulation); never -ffast-math
CXXFLAGS ?= -O3 -march=native
CXXFLAGS += -std=c++17 -ffp-contract=off -fopenmp -Wall -Wextra -Wno-unused-parameter

all: oercel_gpu

oercel_gpu: oercel_gpu.cu
	$(NVCC) $(CCBIN_FLAG) $(NVFLAGS) $(GENCODE) -Xcompiler -fopenmp,-ffp-contract=off -o $@ $< -lgomp

emu: oercel_emu
oercel_emu: oercel_gpu.cu
	$(CXX) $(CXXFLAGS) -x c++ -o $@ $<

# compile-only check of the CUDA build with register/stack report
check-cuda: oercel_gpu.cu
	$(NVCC) $(CCBIN_FLAG) $(NVFLAGS) $(GENCODE) -Xptxas -v -Xcompiler -fopenmp,-ffp-contract=off -o oercel_gpu $< -lgomp 2>&1 | grep -E "error|warning|registers|stack" || true

test:
	@for b in ./oercel_emu ./oercel_gpu; do [ -x $$b ] || continue; for L in 9 12.5 23.7; do $$b --forcetest $$L | tail -1; done; \
	  for a in pi y bola; do $$b --forcetest 12.5 $$a | tail -1; done; done

clean:
	rm -f oercel_gpu oercel_emu

.PHONY: all emu test clean check-cuda
